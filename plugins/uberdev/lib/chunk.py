#!/usr/bin/env python3
"""Enumerate git-tracked source files in scope, filter, and pack into budget-bounded chunks."""
import argparse, json, os, subprocess, sys

IGNORE_DIRS = {"node_modules", "vendor", "dist", "build", ".git", ".worktrees", "__pycache__"}
IGNORE_SUFFIXES = (".min.js", ".min.css", ".lock", ".map", ".png", ".jpg", ".jpeg",
                   ".gif", ".svg", ".ico", ".pdf", ".zip", ".gz", ".woff", ".woff2", ".ttf")
IGNORE_NAMES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock"}
MAX_FILE_BYTES = 256 * 1024  # per-file hard cap; oversized files are skipped


def tracked_files(scope):
    out = subprocess.run(["git", "ls-files", "--", scope], capture_output=True, text=True)
    if out.returncode != 0:
        # Fail loud — a git failure must NOT masquerade as an empty (clean) scope.
        print(f"error: git ls-files failed (rc={out.returncode}): {out.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [p for p in out.stdout.splitlines() if p]


def keep_size(path):
    """Return the file's byte size if it should be audited, else None
    (ignored dir/name/suffix, oversized, or unreadable). Stats the file at most
    once — the returned size is reused by chunk_files (no second stat)."""
    parts = set(path.split("/"))
    if parts & IGNORE_DIRS:
        return None
    if os.path.basename(path) in IGNORE_NAMES:
        return None
    if path.endswith(IGNORE_SUFFIXES):
        return None
    try:
        sz = os.path.getsize(path)
    except OSError:
        return None
    return None if sz > MAX_FILE_BYTES else sz


def chunk_files(sized_paths, budget):
    """Group (path, size) pairs by directory for cohesion, then pack into
    budget-bounded chunks. Sizes are precomputed by keep_size — no re-stat."""
    by_dir = {}
    for p, sz in sorted(sized_paths):
        by_dir.setdefault(os.path.dirname(p), []).append((p, sz))
    chunks, cur, cur_bytes = [], [], 0
    for _dir in sorted(by_dir):
        for p, sz in by_dir[_dir]:
            if cur and cur_bytes + sz > budget:
                chunks.append((cur, cur_bytes))
                cur, cur_bytes = [], 0
            cur.append(p)
            cur_bytes += sz
    if cur:
        chunks.append((cur, cur_bytes))
    return chunks


def pack_areas(sized_paths, num_areas):
    """Pack (path, size) pairs into AT MOST num_areas byte-balanced areas — the
    fixed-fleet model for /uberscan + /ubersimplify (one reviewer agent per area).

    Decouples agent count from repo size: instead of `files × fleet` agents, the
    whole repo is reviewed by a bounded fleet of <= num_areas agents.

    Uses a binary-searched LINEAR (contiguous) partition over files laid out in
    directory-cohesive sorted order: it minimizes the largest area's byte sum
    subject to using <= num_areas contiguous parts. Two invariants this guarantees:
      * EVERY kept file lands in exactly one area — nothing is dropped (no
        overflow-truncation, so a whole-repo audit actually covers the whole repo).
      * Areas are byte-balanced (max area <= the optimal min-max), so no single
        agent gets a pathological context load.
    Files are ordered by directory so each directory's files stay adjacent and
    split points fall at directory boundaries whenever the byte balance allows."""
    by_dir = {}
    for p, sz in sorted(sized_paths):
        by_dir.setdefault(os.path.dirname(p), []).append((p, sz))
    ordered = [ps for d in sorted(by_dir) for ps in by_dir[d]]
    if not ordered:
        return []
    n = max(1, min(num_areas, len(ordered)))  # never more areas than files
    sizes = [s for _, s in ordered]

    def parts_needed(cap):
        parts, cur = 1, 0
        for s in sizes:
            if cur and cur + s > cap:
                parts += 1
                cur = 0
            cur += s
        return parts

    # The optimal min-max capacity is bounded below by both the largest single
    # file and the perfectly-even split; searching from there finds the optimum.
    lo = max(max(sizes), (sum(sizes) + n - 1) // n)
    hi = sum(sizes)
    while lo < hi:
        mid = (lo + hi) // 2
        if parts_needed(mid) <= n:
            hi = mid
        else:
            lo = mid + 1
    cap = lo

    areas, cur, cur_bytes = [], [], 0
    for p, s in ordered:
        if cur and cur_bytes + s > cap:
            areas.append((cur, cur_bytes))
            cur, cur_bytes = [], 0
        cur.append(p)
        cur_bytes += s
    if cur:
        areas.append((cur, cur_bytes))
    return areas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", default=".")
    ap.add_argument("--budget-bytes", type=int, default=49152)
    ap.add_argument("--max-chunks", type=int, default=25)
    ap.add_argument("--areas", type=int, default=None,
                    help="Area mode: pack files into AT MOST N byte-balanced areas "
                         "(one reviewer agent per area). When set, --budget-bytes and "
                         "--max-chunks are ignored and overflow is always false (no file "
                         "is ever dropped). Omit for legacy byte-budget chunking.")
    ap.add_argument("--run-id", default="")
    args = ap.parse_args()

    area_mode = args.areas is not None
    if area_mode:
        if args.areas <= 0:
            print(f"error: --areas must be positive, got {args.areas}", file=sys.stderr)
            sys.exit(2)
    else:
        if args.budget_bytes <= 0:
            print(f"error: --budget-bytes must be positive, got {args.budget_bytes}", file=sys.stderr)
            sys.exit(2)
        if args.max_chunks <= 0:
            print(f"error: --max-chunks must be positive, got {args.max_chunks}", file=sys.stderr)
            sys.exit(2)

    all_tracked = tracked_files(args.scope)
    kept = []
    for p in all_tracked:
        sz = keep_size(p)
        if sz is not None:
            kept.append((p, sz))
    skipped = len(all_tracked) - len(kept)

    if area_mode:
        # Fixed-fleet: <= N byte-balanced areas, every file covered, never an
        # overflow-truncation. The agent-count ceiling is N, independent of repo size.
        emitted = pack_areas(kept, args.areas)
        overflow = False
        total_groups = len(emitted)
    else:
        chunks = chunk_files(kept, args.budget_bytes)
        overflow = len(chunks) > args.max_chunks
        emitted = chunks[: args.max_chunks] if overflow else chunks
        total_groups = len(chunks)

    print(json.dumps({
        "run_id": args.run_id,
        "scope": "whole-repo" if args.scope == "." else args.scope,
        "mode": "area" if area_mode else "budget",
        "chunk_budget_bytes": None if area_mode else args.budget_bytes,
        "total_files": len(kept),
        "skipped_files": skipped,
        "total_chunks": total_groups,
        "overflow": overflow,
        "chunks": [{"id": i + 1, "files": f, "bytes": b} for i, (f, b) in enumerate(emitted)],
    }, indent=2))


if __name__ == "__main__":
    main()
