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
    return [p for p in out.stdout.splitlines() if p]


def keep(path):
    parts = set(path.split("/"))
    if parts & IGNORE_DIRS:
        return False
    if os.path.basename(path) in IGNORE_NAMES:
        return False
    if path.endswith(IGNORE_SUFFIXES):
        return False
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return False
    except OSError:
        return False
    return True


def chunk_files(paths, budget):
    """Group by directory for cohesion, then pack into budget-bounded chunks."""
    by_dir = {}
    for p in sorted(paths):
        by_dir.setdefault(os.path.dirname(p), []).append(p)
    chunks, cur, cur_bytes = [], [], 0
    for _dir in sorted(by_dir):
        for p in by_dir[_dir]:
            sz = os.path.getsize(p)
            if cur and cur_bytes + sz > budget:
                chunks.append((cur, cur_bytes))
                cur, cur_bytes = [], 0
            cur.append(p)
            cur_bytes += sz
    if cur:
        chunks.append((cur, cur_bytes))
    return chunks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", default=".")
    ap.add_argument("--budget-bytes", type=int, default=49152)
    ap.add_argument("--max-chunks", type=int, default=25)
    ap.add_argument("--run-id", default="")
    args = ap.parse_args()

    all_tracked = tracked_files(args.scope)
    kept = [p for p in all_tracked if keep(p)]
    skipped = len(all_tracked) - len(kept)
    chunks = chunk_files(kept, args.budget_bytes)
    overflow = len(chunks) > args.max_chunks
    emitted = chunks[: args.max_chunks] if overflow else chunks

    print(json.dumps({
        "run_id": args.run_id,
        "scope": "whole-repo" if args.scope == "." else args.scope,
        "chunk_budget_bytes": args.budget_bytes,
        "total_files": len(kept),
        "skipped_files": skipped,
        "total_chunks": len(chunks),
        "overflow": overflow,
        "chunks": [{"id": i + 1, "files": f, "bytes": b} for i, (f, b) in enumerate(emitted)],
    }, indent=2))


if __name__ == "__main__":
    main()
