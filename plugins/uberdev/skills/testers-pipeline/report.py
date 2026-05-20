#!/usr/bin/env python3
"""Synthesize report.md and (optionally) a findings-to-issues aggregate
from per-wave aggregates in <waves-dir>/wave-*.yaml.

Filing rules:
- Only findings with severity in {blocker, critical, major} are emitted into
  the findings-to-issues aggregate.
- Verified flag is derived from cross_refs across waves: a finding is verified
  if >=2 distinct personas reported it across the wave history.

The aggregate is shaped to match the existing post-impl-review-final.md
contract that findings-to-issues consumes.
"""
import argparse
import glob
import os
import sys
import yaml


FILEABLE = {"blocker", "critical", "major"}


def load_waves(waves_dir: str) -> list[dict]:
    out = []
    for p in sorted(glob.glob(os.path.join(waves_dir, "wave-*.yaml"))):
        out.append(yaml.safe_load(open(p)))
    return out


def merge_findings(waves: list[dict]) -> dict[str, dict]:
    merged: dict[str, dict] = {}
    persona_per_finding: dict[str, set[str]] = {}
    for w in waves:
        for f in w.get("findings") or []:
            fid = f["id"]
            merged.setdefault(fid, f)
            persona_per_finding.setdefault(fid, set()).add(f.get("persona", "unknown"))
    for fid, f in merged.items():
        f["reproduced_by"] = sorted(persona_per_finding[fid])
        f["verified"] = len(persona_per_finding[fid]) >= 2
    return merged


def render_report(merged: dict[str, dict], run_id: str) -> str:
    lines = [f"# /uberdev:testers — Run {run_id}", ""]
    by_sev = {"blocker": [], "critical": [], "major": [], "important": [], "suggestion": []}
    for f in merged.values():
        by_sev.setdefault(f.get("severity", "suggestion"), []).append(f)
    lines.append("## Summary")
    for sev, items in by_sev.items():
        verified = sum(1 for x in items if x.get("verified"))
        lines.append(f"- **{sev}**: {len(items)} ({verified} verified)")
    lines.append("")
    for sev in ["blocker", "critical", "major", "important", "suggestion"]:
        items = by_sev[sev]
        if not items:
            continue
        lines.append(f"## {sev.upper()}")
        for f in items:
            v = "✓" if f.get("verified") else "?"
            lines.append(f"### [{v}] {f.get('summary', '(no summary)')}")
            lines.append(f"- **persona(s):** {', '.join(f.get('reproduced_by', []))}")
            lines.append(f"- **location:** `{f.get('location', '')}`")
            lines.append(f"- **invariant:** `{f.get('invariant_violated', '')}`")
            ev = f.get("evidence") or {}
            if ev.get("screenshot"):
                lines.append(f"- **screenshot:** `{ev['screenshot']}`")
            if ev.get("network_request"):
                nr = ev["network_request"]
                lines.append(f"- **network:** `{nr.get('method', '')} {nr.get('url', '')}` → `{nr.get('status', '')}`")
            if ev.get("repro_steps"):
                lines.append("- **repro_steps:**")
                for s in ev["repro_steps"]:
                    lines.append(f"  1. {s}")
            lines.append(f"- **observed:** {ev.get('observed', '')}")
            lines.append(f"- **expected:** {ev.get('expected', '')}")
            lines.append(f"- **detail:** {f.get('detail', '')}")
            lines.append("")
    return "\n".join(lines)


def render_findings_to_issues_aggregate(merged: dict[str, dict]) -> str:
    """Emit a markdown aggregate matching the post-impl-review-final.md shape
    that findings-to-issues consumes. Only fileable + verified findings."""
    out = [
        "# Testers Aggregate (for findings-to-issues)",
        "",
        "| persona | severity | location | invariant | summary |",
        "|---|---|---|---|---|",
    ]
    for f in merged.values():
        if f.get("severity") not in FILEABLE:
            continue
        if not f.get("verified"):
            continue
        summary = (f.get("summary", "") or "").replace("|", "\\|")
        out.append(
            f"| {f.get('persona', '?')} | {f.get('severity', '?')} | "
            f"`{f.get('location', '')}` | {f.get('invariant_violated', '')} | "
            f"{summary} |"
        )
    return "\n".join(out) + "\n"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--run-id", required=True)
    p.add_argument("--waves-dir", required=True)
    p.add_argument("--invariants", required=True)
    p.add_argument("--out")
    p.add_argument("--emit-findings-to-issues-aggregate")
    args = p.parse_args()

    waves = load_waves(args.waves_dir)
    merged = merge_findings(waves)

    if args.out:
        with open(args.out, "w") as fh:
            fh.write(render_report(merged, args.run_id))
    if args.emit_findings_to_issues_aggregate:
        with open(args.emit_findings_to_issues_aggregate, "w") as fh:
            fh.write(render_findings_to_issues_aggregate(merged))
    return 0


if __name__ == "__main__":
    sys.exit(main())
