#!/usr/bin/env python3
"""Aggregate per-chunk findings + global passes; render report.md and the findings-to-issues aggregate."""
import argparse, glob, hashlib, os, re, sys, yaml

SEV_RANK = {"blocker": 4, "critical": 3, "major": 2, "important": 2, "suggestion": 1}
ISSUE_SEVERITIES = {"blocker", "critical", "major", "important"}  # suggestion is report-only


def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower().replace("`", "")).strip()


def fingerprint(loc, summary):
    return hashlib.sha256(f"{loc}:{norm(summary)}".encode()).hexdigest()[:16]


def load_findings(chunks_dir):
    rows = []
    for path in sorted(glob.glob(os.path.join(chunks_dir, "chunk-*-findings.yaml"))):
        doc = yaml.safe_load(open(path)) or {}
        for f in doc.get("findings") or []:
            rows.append(f)
    return rows


def dedupe(rows):
    """Collapse identical (location, summary) findings flagged by multiple reviewers."""
    seen, kept = {}, []
    for f in rows:
        fp = fingerprint(f.get("location", ""), f.get("summary", ""))
        if fp in seen:
            kept[seen[fp]].setdefault("also_flagged_by", []).append(f.get("agent", ""))
            continue
        seen[fp] = len(kept)
        kept.append(dict(f))
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--chunks-dir", required=True)
    ap.add_argument("--out")
    ap.add_argument("--emit-findings-to-issues-aggregate")
    args = ap.parse_args()

    rows = dedupe(load_findings(args.chunks_dir))
    totals = {}
    for f in rows:
        totals[f.get("severity", "?")] = totals.get(f.get("severity", "?"), 0) + 1

    if args.out:
        hotspots = {}
        for f in rows:
            fpath = f.get("location", "?").split(":")[0]
            hotspots[fpath] = hotspots.get(fpath, 0) + 1
        with open(args.out, "w") as fh:
            fh.write(f"# /uberscan report — {args.run_id}\n\n## Severity totals\n")
            for sev in sorted(totals, key=lambda s: -SEV_RANK.get(s, 0)):
                fh.write(f"- {sev}: {totals[sev]}\n")
            fh.write("\n## Hotspots\n")
            for path, n in sorted(hotspots.items(), key=lambda kv: -kv[1])[:15]:
                fh.write(f"- {path} — {n}\n")
            fh.write("\n## Findings\n| severity | location | agent | summary |\n|---|---|---|---|\n")
            for f in sorted(rows, key=lambda r: -SEV_RANK.get(r.get("severity", "?"), 0)):
                fh.write(f"| {f.get('severity')} | {f.get('location')} | {f.get('agent')} | {f.get('summary')} |\n")

    if args.emit_findings_to_issues_aggregate:
        issue_rows = [f for f in rows if f.get("severity") in ISSUE_SEVERITIES]
        with open(args.emit_findings_to_issues_aggregate, "w") as fh:
            fh.write('<external-untrusted-input source="uberscan-aggregate">\n')
            fh.write("| severity | location | agent | disposition | summary | detail |\n")
            fh.write("|---|---|---|---|---|---|\n")
            for f in issue_rows:
                fh.write(f"| {f.get('severity')} | {f.get('location')} | {f.get('agent')} | DEFERRED | {f.get('summary')} | {f.get('detail','')} |\n")
            fh.write("</external-untrusted-input>\n")


if __name__ == "__main__":
    main()
