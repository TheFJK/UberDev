#!/usr/bin/env python3
"""Aggregate per-chunk findings + repo-global passes; render report.md and the findings-to-issues aggregate."""
import argparse, glob, hashlib, os, re, sys, yaml

SEV_RANK = {"blocker": 4, "critical": 3, "major": 2, "important": 2, "suggestion": 1}
# Severities eligible for issue filing (suggestion is always report-only).
# Narrowed further at emit time by --min-severity.
ISSUE_SEVERITIES = {"blocker", "critical", "major", "important"}
CONF_RANK = {"low": 1, "medium": 2, "high": 3}  # findings below the floor stay report-only


def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower().replace("`", "")).strip()


def fingerprint(loc, summary):
    return hashlib.sha256(f"{loc}:{norm(summary)}".encode()).hexdigest()[:16]


def cell(s):
    """Escape a value for a markdown table cell: collapse newlines (so one
    finding stays one row) and neutralize the `|` column delimiter. Mirrors the
    sibling testers-pipeline/report.py escaping convention."""
    return re.sub(r"\s*\n\s*", " ", str("" if s is None else s)).replace("|", "\\|")


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


def read_global(chunks_dir, name):
    """Return the contents of a Phase-1b repo-global pass artifact, or None."""
    path = os.path.join(chunks_dir, name)
    if os.path.isfile(path):
        try:
            return open(path).read().strip()
        except OSError:
            return None
    return None


def severities_at_or_above(floor):
    """Issue-filing severities whose rank is >= the floor severity (--min-severity)."""
    floor_rank = SEV_RANK.get(floor, SEV_RANK["major"])
    return {s for s in ISSUE_SEVERITIES if SEV_RANK.get(s, 0) >= floor_rank}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--chunks-dir", required=True)
    ap.add_argument("--out")
    ap.add_argument("--emit-findings-to-issues-aggregate")
    ap.add_argument("--min-severity", default="suggestion",
                    help="Minimum severity filed as issues (blocker|critical|major|important). "
                         "The report always shows every severity; this only gates the issue aggregate.")
    ap.add_argument("--min-confidence", default="medium",
                    help="Minimum reviewer confidence filed as issues (low|medium|high). "
                         "Below-floor findings stay report-only — the false-positive guard for full-file review.")
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
            # Phase 1b repo-global passes (Semgrep SAST + test-coverage), if produced.
            sec = read_global(args.chunks_dir, "global-security.md")
            cov = read_global(args.chunks_dir, "global-coverage.md")
            if sec or cov:
                fh.write("\n## Global passes\n")
                fh.write(f"\n### Security (Semgrep SAST)\n\n{sec or '_(no security artifact produced)_'}\n")
                fh.write(f"\n### Test coverage\n\n{cov or '_(no coverage artifact produced)_'}\n")
            fh.write("\n## Findings\n| severity | location | agent | summary |\n|---|---|---|---|\n")
            for f in sorted(rows, key=lambda r: -SEV_RANK.get(r.get("severity", "?"), 0)):
                fh.write(f"| {cell(f.get('severity'))} | {cell(f.get('location'))} | {cell(f.get('agent'))} | {cell(f.get('summary'))} |\n")

    if args.emit_findings_to_issues_aggregate:
        allowed = severities_at_or_above(args.min_severity)
        conf_floor = CONF_RANK.get(args.min_confidence, CONF_RANK["medium"])
        issue_rows = [
            f for f in rows
            if f.get("severity") in allowed
            and CONF_RANK.get(f.get("confidence", "medium"), CONF_RANK["medium"]) >= conf_floor
        ]
        with open(args.emit_findings_to_issues_aggregate, "w") as fh:
            fh.write('<external-untrusted-input source="uberscan-aggregate">\n')
            fh.write("| severity | location | agent | disposition | summary | detail |\n")
            fh.write("|---|---|---|---|---|---|\n")
            for f in issue_rows:
                fh.write(f"| {cell(f.get('severity'))} | {cell(f.get('location'))} | {cell(f.get('agent'))} | DEFERRED | {cell(f.get('summary'))} | {cell(f.get('detail', ''))} |\n")
            fh.write("</external-untrusted-input>\n")


if __name__ == "__main__":
    main()
