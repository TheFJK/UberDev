#!/usr/bin/env python3
"""Aggregate /ubersimplify lens findings.

Two modes:
  fixer  — dedup ONE chunk's lens findings by file:line (merging across lenses,
           mirroring commands/simplify.md Phase 3) and emit the per-chunk
           code-fixer input, wrapped in the post-impl-review-aggregate envelope.
  issues — collect fileable (blocker) findings across all chunks that code-fixer
           did NOT apply, and emit the findings-to-issues input, wrapped in the
           ubersimplify-aggregate envelope. --audit-only treats every fileable
           finding as deferred (no apply phase ran).
"""
import argparse, glob, os, re, sys, yaml

# Shared report primitives (issue #183): cell() neutralizes the
# </external-untrusted-input> close-tag with a ZWSP so attacker-influenceable
# code-simplifier prose (rendered over ARBITRARY repo files) cannot break out of
# the spotlighting envelope; envelope() writes the wrapper with the opening marker
# as the leading bytes. Imported in-process EXACTLY like the sibling reporters
# (skills/uberscan-pipeline/report.py, skills/testers-pipeline/report.py), anchored
# on THIS file's location (NOT cwd) so the import resolves regardless of where the
# pipeline is invoked from. A hand-rolled cell() that skipped the close-tag was the
# breakout this issue fixes — reuse the hardened shared primitive (no custom copy).
# skills/ubersimplify-pipeline/aggregate.py -> ../../lib/report_primitives.py
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from report_primitives import cell, envelope  # noqa: E402

SEV_RANK = {"blocker": 2, "suggestion": 1}
LENS_ORDER = {"Reuse": 0, "Quality": 1, "Efficiency": 2}
FILEABLE = {"blocker"}  # only blocker-tier lens findings are filed as issues


def _norm(s):
    return re.sub(r"\s+", " ", (s or "")).strip()


def _max_sev(a, b):
    return a if SEV_RANK.get(a, 0) >= SEV_RANK.get(b, 0) else b


def _lens_join(lenses):
    uniq = sorted(set(lenses), key=lambda L: LENS_ORDER.get(L, 99))
    return "+".join(uniq)


def load_lens_findings(path):
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as e:
        # Fail loud — a malformed chunk file must NOT silently shrink the run.
        print(f"error: failed to load {path}: {e}", file=sys.stderr)
        sys.exit(2)
    return doc.get("findings") or []


def dedupe_by_location(rows):
    """Merge findings sharing a file:line across lenses (mirrors simplify.md Phase 3
    dedup policy): lens -> '+'-joined in checklist order; summary/detail -> ' | '
    joined and lens-prefixed when >1 lens; severity -> max(blocker > suggestion)."""
    by_loc, order = {}, []
    for f in rows:
        loc = f.get("location", "")
        lens = f.get("lens", "")
        if loc not in by_loc:
            by_loc[loc] = {"severity": f.get("severity", "suggestion"),
                           "lenses": [lens],
                           "summaries": [(lens, f.get("summary", ""))],
                           "details": [(lens, f.get("detail", ""))]}
            order.append(loc)
        else:
            m = by_loc[loc]
            m["severity"] = _max_sev(m["severity"], f.get("severity", "suggestion"))
            m["lenses"].append(lens)
            m["summaries"].append((lens, f.get("summary", "")))
            m["details"].append((lens, f.get("detail", "")))
    merged = []
    for loc in order:
        m = by_loc[loc]
        sums = sorted(m["summaries"], key=lambda t: LENS_ORDER.get(t[0], 99))
        dets = sorted(m["details"], key=lambda t: LENS_ORDER.get(t[0], 99))
        merged.append({
            "location": loc,
            "severity": m["severity"],
            "lens": _lens_join(m["lenses"]),
            "summary": " | ".join(f"{L}: {_norm(s)}" for L, s in sums) if len(sums) > 1 else _norm(sums[0][1]),
            "detail": " | ".join(f"{L}: {_norm(d)}" for L, d in dets) if len(dets) > 1 else _norm(dets[0][1]),
        })
    return merged


def emit_fixer(lens_file, out):
    merged = dedupe_by_location(load_lens_findings(lens_file))
    # Build the YAML-list body, then wrap via the shared envelope(). Every field
    # passes through cell() so an injected </external-untrusted-input> in the
    # (attacker-influenceable) summary/detail prose cannot terminate the
    # post-impl-review-aggregate envelope early and inject into code-fixer.
    body = ""
    for f in merged:
        body += f"- location: {cell(f['location'])}\n"
        body += f"  severity: {cell(f['severity'])}\n"
        body += f"  lens: {cell(f['lens'])}\n"
        body += f"  summary: {cell(f['summary'])}\n"
        body += f"  detail: {cell(f['detail'])}\n"
    with open(out, "w") as fh:
        envelope(fh, "post-impl-review-aggregate", body)
    return len(merged)


def _applied_locations(chunks_dir):
    applied = set()
    for p in sorted(glob.glob(os.path.join(chunks_dir, "chunk-*-fixer-disposition.yaml"))):
        try:
            with open(p) as fh:
                doc = yaml.safe_load(fh) or {}
        except (OSError, yaml.YAMLError) as e:
            print(f"error: failed to load disposition {p}: {e}", file=sys.stderr)
            sys.exit(2)
        for d in doc.get("findings_disposition") or []:
            if d.get("disposition") == "APPLIED":
                applied.add(d.get("location", ""))
    return applied


def emit_issues(chunks_dir, out, audit_only):
    rows = []
    for lens_file in sorted(glob.glob(os.path.join(chunks_dir, "chunk-*-lens.yaml"))):
        rows.extend(dedupe_by_location(load_lens_findings(lens_file)))
    applied = set() if audit_only else _applied_locations(chunks_dir)
    issue_rows = [f for f in rows if f.get("severity") in FILEABLE and f.get("location") not in applied]
    # Build the markdown table body, then wrap via the shared envelope() so the
    # opening marker stays the leading bytes (findings-to-issues first-128-byte
    # invariant) and every cell passes through the hardened cell() (close-tag
    # neutralization + pipe escaping). Mirrors skills/uberscan-pipeline/report.py.
    body = "| severity | location | agent | disposition | summary | detail |\n"
    body += "|---|---|---|---|---|---|\n"
    for f in issue_rows:
        agent = f"code-simplifier ({f.get('lens', '')})"
        body += f"| {cell(f['severity'])} | {cell(f['location'])} | {cell(agent)} | DEFERRED | {cell(f['summary'])} | {cell(f['detail'])} |\n"
    with open(out, "w") as fh:
        envelope(fh, "ubersimplify-aggregate", body)
    return len(issue_rows)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    pf = sub.add_parser("fixer")
    pf.add_argument("--lens-file", required=True)
    pf.add_argument("--out", required=True)
    pi = sub.add_parser("issues")
    pi.add_argument("--chunks-dir", required=True)
    pi.add_argument("--out", required=True)
    pi.add_argument("--audit-only", action="store_true")
    args = ap.parse_args()
    if args.mode == "fixer":
        n = emit_fixer(args.lens_file, args.out)
        print(f"fixer aggregate: {n} merged findings -> {args.out}")
    else:
        n = emit_issues(args.chunks_dir, args.out, args.audit_only)
        print(f"issues aggregate: {n} fileable findings -> {args.out}")


if __name__ == "__main__":
    main()
