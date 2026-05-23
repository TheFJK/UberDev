#!/usr/bin/env python3
"""Synthesize report.md and (optionally) a findings-to-issues aggregate
from per-wave aggregates in <waves-dir>/wave-*.yaml.

Filing rules:
- Only findings with severity in {blocker, critical, major} are emitted into
  the findings-to-issues aggregate.
- Verified flag is sourced from monitor-primary's cross_refs entries (the
  SKILL.md schema contract). The aggregator falls back to >=2-distinct-persona
  cross-wave evidence when no cross_refs entry exists for a finding, so a
  monitor outage does not silently drop verification.

The aggregate is shaped to match the existing post-impl-review-final.md
contract that findings-to-issues consumes.
"""
import argparse
import glob
import os
import sys
import yaml

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from report_primitives import cell, envelope  # noqa: E402


FILEABLE = {"blocker", "critical", "major"}

# Severity rank used to keep the strongest evidence when the same stable-id
# appears in multiple waves. blocker > critical > major > important > suggestion.
_SEV_RANK = {"blocker": 4, "critical": 3, "major": 2, "important": 1, "suggestion": 0}


def _sev_rank(f: dict) -> int:
    return _SEV_RANK.get(f.get("severity"), -1)


def load_waves(waves_dir: str) -> list:
    """Load wave-*.yaml files in lexical order. Bad I/O on any wave file
    aborts (callers can't render a useful report without a complete set);
    parse errors on a single wave are logged but do not abort."""
    out = []
    for p in sorted(glob.glob(os.path.join(waves_dir, "wave-*.yaml"))):
        try:
            with open(p) as fh:
                doc = yaml.safe_load(fh)
        except (FileNotFoundError, PermissionError) as e:
            print(f"error: cannot read wave file {p}: {e}", file=sys.stderr)
            sys.exit(2)
        except yaml.YAMLError as e:
            print(f"warning: skipping malformed wave file {p}: {e}", file=sys.stderr)
            continue
        if doc is None:
            print(f"warning: empty wave file {p}, skipping", file=sys.stderr)
            continue
        out.append(doc)
    return out


def merge_findings(waves: list) -> dict:
    """Merge findings from all waves keyed by stable-id.

    When the same id appears in multiple waves we keep the highest-severity
    record (cross-wave divergence is information gain, not a duplicate to
    drop). `verified` is sourced from monitor-primary's cross_refs entries
    when present; otherwise it falls back to >=2-distinct-persona evidence
    across the wave history.
    """
    merged: dict = {}
    persona_per_finding: dict = {}
    cross_ref_verified: dict = {}
    # Single fused pass over waves: accumulate cross_ref verified flags AND
    # findings (highest-severity wins, persona attribution union) in one
    # iteration. The cross_ref_verified map is consulted in the post-pass
    # below (over merged.items()), so build order within a wave is irrelevant.
    for w in waves:
        for cr in w.get("cross_refs") or []:
            fid = cr.get("finding_id")
            if not fid:
                continue
            # Sticky-true: once a monitor marks a finding verified in any wave,
            # later waves can confirm but not silently unverify.
            cross_ref_verified[fid] = cross_ref_verified.get(fid, False) or bool(
                cr.get("verified")
            )
        for f in w.get("findings") or []:
            fid = f["id"]
            prior = merged.get(fid)
            if prior is None or _sev_rank(f) > _sev_rank(prior):
                merged[fid] = f
            persona_per_finding.setdefault(fid, set()).add(f.get("persona", "unknown"))
    for fid, f in merged.items():
        f["reproduced_by"] = sorted(persona_per_finding[fid])
        if fid in cross_ref_verified:
            f["verified"] = cross_ref_verified[fid]
        else:
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
            v = "verified" if f.get("verified") else "unverified"
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
    that findings-to-issues consumes. Only fileable + verified findings.

    Returns the inner table body WITHOUT a leading H1 header — the caller
    wraps this in the spotlighting envelope, and the envelope must be the
    leading bytes of the file (findings-to-issues 128-byte rule).
    """
    out = [
        "| persona | severity | location | invariant | summary |",
        "|---|---|---|---|---|",
    ]
    for f in merged.values():
        if f.get("severity") not in FILEABLE:
            continue
        if not f.get("verified"):
            continue
        out.append(
            f"| {cell(f.get('persona', '?'))} | {cell(f.get('severity', '?'))} | "
            f"`{cell(f.get('location', ''))}` | {cell(f.get('invariant_violated', ''))} | "
            f"{cell(f.get('summary', ''))} |"
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
        body = render_findings_to_issues_aggregate(merged)
        with open(args.emit_findings_to_issues_aggregate, "w") as fh:
            envelope(fh, "testers-aggregate", body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
