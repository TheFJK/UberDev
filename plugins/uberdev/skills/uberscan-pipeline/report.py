#!/usr/bin/env python3
"""Aggregate per-chunk findings + repo-global passes; render report.md and the findings-to-issues aggregate."""
import argparse, glob, hashlib, json, os, re, sys, yaml

# Shared report primitives (issue #166, D1): cell()/envelope()/sort_by_rank are
# the schema-agnostic mechanism, anchored on this file's location (NOT cwd) so
# the import resolves regardless of where the pipeline is invoked from.
# sort_by_rank is currently uberscan-only; available for future report consumers.
# skills/uberscan-pipeline/report.py -> ../../lib/report_primitives.py
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from report_primitives import cell, envelope, sort_by_rank  # noqa: E402

# Cap on per-file hotspot rows shown in the report and totals.json sidecar.
HOTSPOT_TOP_N = 15
SEV_RANK = {"blocker": 4, "critical": 3, "major": 2, "important": 2, "suggestion": 1}
# Severities eligible for issue filing (suggestion is always report-only).
# Narrowed further at emit time by --min-severity.
ISSUE_SEVERITIES = {"blocker", "critical", "major", "important"}
CONF_RANK = {"low": 1, "medium": 2, "high": 3}  # findings below the floor stay report-only


def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower().replace("`", "")).strip()


def fingerprint(loc, summary):
    return hashlib.sha256(f"{loc}:{norm(summary)}".encode()).hexdigest()[:16]


def agent_label(f):
    """Agent column annotated with cross-reviewer confirmations (also_flagged_by),
    so a finding flagged by multiple reviewers carries that signal into the report
    AND the issue aggregate (RFC 0007 §5 cross-reviewer confirmation)."""
    base = f.get("agent", "")
    also = f.get("also_flagged_by") or []
    return f"{base} (+{', '.join(str(a) for a in also)})" if also else base


def load_findings(chunks_dir: str) -> list[dict]:
    rows: list[dict] = []
    for path in sorted(glob.glob(os.path.join(chunks_dir, "chunk-*-findings.yaml"))):
        try:
            with open(path) as fh:
                doc = yaml.safe_load(fh) or {}
        except (OSError, yaml.YAMLError) as e:
            # Fail loud — a malformed/unreadable chunk file must NOT silently shrink
            # the audit into a false-clean result.
            print(f"error: failed to load findings from {path}: {e}", file=sys.stderr)
            sys.exit(2)
        for f in doc.get("findings") or []:
            if f.get("severity", "?") not in SEV_RANK:
                print(f"warning: unknown severity {f.get('severity')!r} in {path} — ranked lowest, excluded from issue filing", file=sys.stderr)
            if f.get("confidence", "medium") not in CONF_RANK:
                print(f"warning: unknown confidence {f.get('confidence')!r} in {path} — treated as medium", file=sys.stderr)
            rows.append(f)
    return rows


def dedupe(rows: list[dict]) -> list[dict]:
    """Collapse identical (location, summary) findings flagged by multiple reviewers."""
    seen: dict[str, int] = {}
    kept: list[dict] = []
    for f in rows:
        fp = fingerprint(f.get("location", ""), f.get("summary", ""))
        if fp in seen:
            kept[seen[fp]].setdefault("also_flagged_by", []).append(f.get("agent", ""))
            continue
        seen[fp] = len(kept)
        kept.append(dict(f))
    return kept


def read_global(chunks_dir, name):
    """Return the contents of a Phase-1b repo-global pass artifact, or None if absent/unreadable."""
    try:
        with open(os.path.join(chunks_dir, name)) as fh:
            return fh.read().strip()
    except OSError:
        return None


def severities_at_or_above(floor):
    """Issue-filing severities whose rank is >= the floor severity (--min-severity)."""
    floor_rank = SEV_RANK.get(floor, SEV_RANK["major"])
    return {s for s in ISSUE_SEVERITIES if SEV_RANK.get(s, 0) >= floor_rank}


def _top_hotspots(hotspots, limit=HOTSPOT_TOP_N):
    """Deterministic per-file hotspot ordering shared by the report Hotspots
    section and the totals.json sidecar: count desc, then path asc, capped at
    `limit` (Item 4 / AC4). Both consumers MUST use this so the report and
    totals.json never disagree."""
    return sorted(hotspots.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]


def _write_totals_sidecar(sidecar_path, run_id, totals, hotspots):
    """Write the machine-readable totals.json sidecar (D6) — the SSOT consumed by
    SKILL.md Phase 4 (incl. the --no-report path). `sidecar_path` is the explicit
    destination; callers pass the path next to --out, or the --emit-totals-json
    value. Hotspots use the same deterministic (count desc, path asc) order and
    cap as the report Hotspots section (Item 4 / AC4)."""
    top = _top_hotspots(hotspots)
    try:
        with open(sidecar_path, "w") as fh:
            json.dump({
                "run_id": run_id,
                "severities": totals,
                "total": sum(totals.values()),
                "hotspots": [{"location": p, "count": n} for p, n in top],
            }, fh, indent=2)
    except OSError as e:
        # SKILL.md Phase 4 reads this sidecar as the SSOT for severity totals;
        # a silent write failure would surface there as all-zero counts. Fail
        # loud with an actionable message instead of an opaque traceback.
        print(f"error: could not write totals sidecar to {sidecar_path}: {e}",
              file=sys.stderr)
        sys.exit(2)


def _global_rows(allowed, sec, cov):
    """Synthetic aggregate rows for the repo-global Phase-1b passes (Item 9 / D5):
    surface Semgrep SAST + test-coverage findings into the findings-to-issues
    aggregate so they get filed as issues, not just shown in the report. Each
    row is `important` severity at `repo:global`; emitted only when the artifact
    is non-empty AND `important` is in the allowed (--min-severity) set. `sec`/`cov`
    are the already-read global-security.md / global-coverage.md contents (read
    once by the caller — D6 read-once consistency). The raw artifact text rides in
    `detail` and is neutralized by cell() at render time (D7 — multi-line collapse
    + close-tag neutralization)."""
    # Ordered (text, agent, summary) table — security row MUST stay before the
    # coverage row (golden aggregate order). Each row is emitted only when its
    # artifact text is non-empty AND `important` is in the allowed set.
    specs = (
        (sec, "research-security", "Semgrep SAST findings (see report Global passes)"),
        (cov, "research-test-coverage", "Test-coverage gaps (see report Global passes)"),
    )
    rows = []
    if "important" in allowed:
        for text, agent, summary in specs:
            if text:
                rows.append({"severity": "important", "location": "repo:global",
                             "agent": agent, "summary": summary, "detail": text})
    return rows


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
    ap.add_argument("--emit-totals-json",
                    help="Write the totals.json sidecar to this path (SSOT for SKILL.md "
                         "Phase 4, incl. --no-report). Computed from the same deduped findings.")
    args = ap.parse_args()

    if not os.path.isdir(args.chunks_dir):
        print(f"error: --chunks-dir is not a directory: {args.chunks_dir}", file=sys.stderr)
        sys.exit(2)
    if args.min_severity not in SEV_RANK:
        print(f"error: --min-severity must be one of {sorted(SEV_RANK)}, got {args.min_severity!r}", file=sys.stderr)
        sys.exit(2)
    if args.min_confidence not in CONF_RANK:
        print(f"error: --min-confidence must be one of {sorted(CONF_RANK)}, got {args.min_confidence!r}", file=sys.stderr)
        sys.exit(2)

    rows = dedupe(load_findings(args.chunks_dir))

    # Compute severity totals + per-file hotspots ONCE (D6): the report body, the
    # totals.json sidecar next to --out, and the standalone --emit-totals-json
    # write all consume the same aggregation of the same deduped findings.
    totals = {}
    for f in rows:
        sev = f.get("severity", "?")
        totals[sev] = totals.get(sev, 0) + 1
    hotspots = {}
    for f in rows:
        fpath = f.get("location", "?").split(":")[0]
        hotspots[fpath] = hotspots.get(fpath, 0) + 1

    # Read the repo-global Phase-1b passes ONCE (D6 read-once consistency): both
    # the --out report body and the findings-to-issues aggregate consume them.
    global_sec = read_global(args.chunks_dir, "global-security.md")
    global_cov = read_global(args.chunks_dir, "global-coverage.md")

    if args.out:
        with open(args.out, "w") as fh:
            fh.write(f"# /uberscan report — {args.run_id}\n\n## Severity totals\n")
            for sev in sorted(totals, key=lambda s: -SEV_RANK.get(s, 0)):
                fh.write(f"- {sev}: {totals[sev]}\n")
            fh.write("\n## Hotspots\n")
            # deterministic hotspot order: count desc, then path asc (Item 4 / AC4)
            for path, n in _top_hotspots(hotspots):
                fh.write(f"- {path} — {n}\n")
            # Phase 1b repo-global passes (Semgrep SAST + test-coverage), if produced.
            if global_sec or global_cov:
                fh.write("\n## Global passes\n")
                fh.write(f"\n### Security (Semgrep SAST)\n\n{global_sec or '_(no security artifact produced)_'}\n")
                fh.write(f"\n### Test coverage\n\n{global_cov or '_(no coverage artifact produced)_'}\n")
            fh.write("\n## Findings\n| severity | location | agent | summary |\n|---|---|---|---|\n")
            for f in sort_by_rank(rows, SEV_RANK, lambda r: r.get("severity", "?")):
                fh.write(f"| {cell(f.get('severity'))} | {cell(f.get('location'))} | {cell(agent_label(f))} | {cell(f.get('summary'))} |\n")
        # totals.json sidecar next to the report (D6, NEVER /tmp).
        _write_totals_sidecar(
            os.path.join(os.path.dirname(os.path.abspath(args.out)), "totals.json"),
            args.run_id, totals, hotspots)

    # Standalone sidecar emit (SSOT) — lets --no-report callers still get totals.json.
    if args.emit_totals_json:
        _write_totals_sidecar(args.emit_totals_json, args.run_id, totals, hotspots)

    if args.emit_findings_to_issues_aggregate:
        allowed = severities_at_or_above(args.min_severity)
        conf_floor = CONF_RANK.get(args.min_confidence, CONF_RANK["medium"])
        issue_rows = [
            f for f in rows
            if f.get("severity") in allowed
            and CONF_RANK.get(f.get("confidence", "medium"), CONF_RANK["medium"]) >= conf_floor
        ]
        # Surface repo-global Semgrep + coverage findings into the aggregate so
        # SAST/coverage gaps get filed as issues, not just reported (Item 9 / D5).
        aggregate_rows = issue_rows + _global_rows(allowed, global_sec, global_cov)
        body = "| severity | location | agent | disposition | summary | detail |\n"
        body += "|---|---|---|---|---|---|\n"
        for f in aggregate_rows:
            body += f"| {cell(f.get('severity'))} | {cell(f.get('location'))} | {cell(agent_label(f))} | DEFERRED | {cell(f.get('summary'))} | {cell(f.get('detail', ''))} |\n"
        with open(args.emit_findings_to_issues_aggregate, "w") as fh:
            # Reuse the shared envelope so the opening marker stays the leading
            # bytes (findings-to-issues first-128-byte invariant) and every cell
            # has already passed through the hardened cell() (D7).
            envelope(fh, "uberscan-aggregate", body)


if __name__ == "__main__":
    main()
