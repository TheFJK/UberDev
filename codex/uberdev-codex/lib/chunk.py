#!/usr/bin/env python3
"""Enumerate git-tracked source files in scope, filter, and pack into AT MOST
--areas byte-balanced areas (the fixed-fleet model for /uberscan + /ubersimplify:
one reviewer agent per area). The legacy --budget-bytes/--max-chunks chunking
mode was deleted (RFC 0012 scan-R4) — area mode is the only packer."""
import argparse, json, os, subprocess, sys

IGNORE_DIRS = {"node_modules", "vendor", "dist", "build", ".git", ".worktrees", "__pycache__"}
IGNORE_SUFFIXES = (".min.js", ".min.css", ".lock", ".map", ".png", ".jpg", ".jpeg",
                   ".gif", ".svg", ".ico", ".pdf", ".zip", ".gz", ".woff", ".woff2", ".ttf")
IGNORE_NAMES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock"}
# Per-file hard cap; oversized files are skipped AND their names are surfaced in
# the manifest (skipped_oversize) — an oversize skip is a coverage gap in a
# "whole-repo" audit, so it must never be a silent count.
MAX_FILE_BYTES = 256 * 1024


def tracked_files(scope):
    out = subprocess.run(["git", "ls-files", "--", scope], capture_output=True, text=True)
    if out.returncode != 0:
        # Fail loud — a git failure must NOT masquerade as an empty (clean) scope.
        print(f"error: git ls-files failed (rc={out.returncode}): {out.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [p for p in out.stdout.splitlines() if p]


def classify(path):
    """Classify a tracked path for packing. Returns (size, None) when the file
    should be audited, else (None, reason) with reason one of:
      "ignored"    — IGNORE_DIRS / IGNORE_NAMES / IGNORE_SUFFIXES match
                     (intentional exclusion; stays a silent count)
      "unreadable" — stat failed (e.g. tracked but deleted from disk)
      "oversize"   — size > MAX_FILE_BYTES (a COVERAGE GAP: main() surfaces
                     these names in the manifest's skipped_oversize list)
    Stats the file at most once — the returned size is reused by pack_areas
    (no second stat)."""
    parts = set(path.split("/"))
    if parts & IGNORE_DIRS:
        return None, "ignored"
    if os.path.basename(path) in IGNORE_NAMES:
        return None, "ignored"
    if path.endswith(IGNORE_SUFFIXES):
        return None, "ignored"
    try:
        sz = os.path.getsize(path)
    except OSError:
        return None, "unreadable"
    if sz > MAX_FILE_BYTES:
        return None, "oversize"
    return sz, None


def _ordered_by_dir(sized_paths):
    """Order (path, size) pairs so each directory's files are adjacent (cohesion),
    with directories visited in sorted order and files sorted within each. This is
    the layout pack_areas partitions over: because areas are CONTIGUOUS slices of
    this order, every directory's files span a contiguous run of areas and split
    points fall at directory boundaries whenever the byte balance allows."""
    by_dir = {}
    for p, sz in sorted(sized_paths):
        by_dir.setdefault(os.path.dirname(p), []).append((p, sz))
    return [ps for d in sorted(by_dir) for ps in by_dir[d]]


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
    ordered = _ordered_by_dir(sized_paths)
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
    ap.add_argument("--areas", type=int, required=True,
                    help="Pack files into AT MOST N byte-balanced areas (one "
                         "reviewer agent per area). Every kept file is covered "
                         "exactly once — overflow is always false (no file is "
                         "ever dropped).")
    ap.add_argument("--run-id", default="")
    args = ap.parse_args()

    if args.areas <= 0:
        print(f"error: --areas must be positive, got {args.areas}", file=sys.stderr)
        sys.exit(2)

    all_tracked = tracked_files(args.scope)
    kept, skipped_oversize = [], []
    skipped = 0
    for p in all_tracked:
        sz, reason = classify(p)
        if reason is None:
            kept.append((p, sz))
        else:
            skipped += 1
            if reason == "oversize":
                skipped_oversize.append(p)

    # Fixed-fleet: <= N byte-balanced areas, every file covered, never an
    # overflow-truncation. The agent-count ceiling is N, independent of repo size.
    areas = pack_areas(kept, args.areas)

    print(json.dumps({
        "run_id": args.run_id,
        "scope": "whole-repo" if args.scope == "." else args.scope,
        "mode": "area",
        "total_files": len(kept),
        "skipped_files": skipped,
        # Oversize skips BY NAME: these in-scope source files were excluded only
        # for exceeding MAX_FILE_BYTES, so a "whole-repo" audit has a visible —
        # not silent — coverage gap. Rule-based ignores (IGNORE_*) and unreadable
        # files remain count-only in skipped_files.
        "skipped_oversize": skipped_oversize,
        "total_chunks": len(areas),
        "overflow": False,
        "chunks": [{"id": i + 1, "files": f, "bytes": b} for i, (f, b) in enumerate(areas)],
    }, indent=2))


if __name__ == "__main__":
    main()
