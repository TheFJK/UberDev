#!/usr/bin/env python3
"""Measure per-lens precision of the /uberdev:review-pr reviewer fleet.

Contract: docs/rfc/0018-review-precision-eval.md. Read it before changing any
constant in here — every floor below is a stated policy, not a tuning knob.

Shape: a thin `gh` shell (`--refresh`, the ONLY subprocess-touching mode) around
pure functions (`classify`, `wilson`, `family`, `aggregate`, `render`). Mirrors
tools/prkit/published-check.py: the check half must run in CI, which has
`permissions: contents: read`, no secrets and no `gh` on PATH.

Modes
  --refresh   mine live GitHub issues into the corpus, seed the baseline, render
  --render    render the report from corpus + baseline (writes the report)
  --check     re-render from the corpus and require byte equality, then run the
              precision ratchet and the prompt-digest re-affirmation stamp
              (default when no mode is given)

Exit codes
  0  everything agrees
  1  a check failed (freshness, ratchet, or prompt-digest drift)
  2  usage error, or an input that could not be read/parsed

Determinism: `--render` and `--check` classify against the corpus's own
`generated_at`, NOT the wall clock, so the committed report is a pure function
of the committed corpus. `--now` overrides it (that is how the ladder rows are
tested). Without this the `pending`/`stale-open` split would drift on its own and
red the freshness gate in CI days after the report was written.

Stated limitation: `--refresh` RE-BASELINES. It rewrites `precision-baseline.json`
from the freshly mined corpus, which clears any recorded drop and any declared
`pending[]`. The ratchet therefore guards the window BETWEEN refreshes, and a
refresh is a deliberate act visible in the diff — never a side effect of running
`--check`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT_DEFAULT = REPO_ROOT / "plugins" / "uberdev"
sys.path.insert(0, str(PLUGIN_ROOT_DEFAULT / "lib"))

# The lens rosters are IMPORTED, never copied. lib/report_primitives.py is the
# single source of truth and lib/review-fleet-args.sh mirrors its wire order;
# a local copy here would be a fourth uncompared duplicate of the same contract.
from report_primitives import (  # noqa: E402  (path insert must precede import)
    PHASE1_CONTRIBUTORS,
    PHASE2_CONTRIBUTORS,
)

# --- policy constants (RFC 0018 §3.3) ---------------------------------------
# Below this many ADJUDICATED rows a lens publishes `insufficient-data`, never a
# ratio. A precision computed from a handful of points is noise with a decimal
# point on it.
MIN_N_PUBLISH = 20
# Below this many adjudicated rows no per-lens threshold is derived at all. A
# threshold from noise is worse than the global default because it looks
# authoritative.
MIN_N_THRESHOLD = 50
# An open finding older than this is `stale-open` rather than `pending`.
STALE_DAYS = 30
# 95% two-sided normal quantile. Deliberately the conventional two-decimal form:
# the 15-digit expansion embeds a long digit run that trips the repo-identity
# guard in tests/review-precision.test.sh, and the extra digits buy nothing at
# these sample sizes.
Z = 1.96

SCHEMA_VERSION = 1
DEFAULT_LABEL = "review-pr-finding"
DEFAULT_LIMIT = 200

# The agent prompt FILE each Phase 1 lens is dispatched with, keyed by the last
# dot-separated segment of the lens id — never by the whole edge id, which would
# be the roster copy the import above exists to prevent (the suite greps this
# file for the roster's edge-id prefix).
#
# `correctness` and `general` share one file: code-reviewer is dispatched TWICE
# and the PROMPT, not the agent file, differentiates them (RFC 0018 §7), so the
# surface list below de-duplicates while the lens tables keep two rows.
LENS_PROMPT_FILES = {
    "correctness": "code-reviewer.md",
    "silent_failures": "silent-failure-hunter.md",
    "types": "type-design-analyzer.md",
    "comments": "comment-analyzer.md",
    "tests": "pr-test-analyzer.md",
    "general": "code-reviewer.md",
    "convention": "convention-compliance.md",
}
# Prompt bodies the lens files above pull in by reference. A lens's own file
# names them, so the roster cannot yield them and they stay literal — which makes
# each one a place drift can hide, hence a WHY per entry rather than a bare list:
#   * phase1-reviewer-output-v1.md — the serialization contract every Phase 1
#     reviewer emits through.
#   * finding-confidence-rubric-v1.md — #431 moved the 0-100 confidence anchors
#     OUT of agents/code-reviewer.md and into this file. The bytes that decide
#     every confidence score left the stamped set in the same commit that created
#     them; naming the file as a surface is what puts them back. It POSTDATES the
#     current measurement, so the baseline declares it in pending[] and records
#     its current bytes under `unmeasured_digests` rather than stamping a
#     prompt_digests entry the numbers were never measured against — the next
#     --refresh stamps it for real.
SHARED_PROMPT_SURFACES = (
    "shared/phase1-reviewer-output-v1.md",
    "shared/finding-confidence-rubric-v1.md",
)

ATTRIBUTION_SOURCES = ("trailer", "agent-line", "none")
CLASSES = (
    "true-positive",
    "false-positive",
    "conflicted",
    "pending",
    "stale-open",
    "unadjudicated",
)
SECTIONS = ("headline", "phase2", "other", "unattributed", "pre-instrumentation")

TRUE_POSITIVE_LABEL = "finding:true-positive"
FALSE_POSITIVE_LABEL = "finding:false-positive"

FINGERPRINT_MARKER_OPEN = "<!-- uberdev:"
META_TRAILER_OPEN = "<!-- uberdev-finding-meta "


class InputError(Exception):
    """An input could not be read or parsed — exit code 2, never a silent 0."""


# --- pure core ---------------------------------------------------------------


def parse_iso8601(value: str) -> datetime:
    """Parse a GitHub timestamp into an aware UTC datetime."""
    if not isinstance(value, str) or not value:
        raise InputError(f"not an ISO8601 timestamp: {value!r}")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise InputError(f"not an ISO8601 timestamp: {value!r} ({exc})") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def classify(row: dict, now: datetime) -> str:
    """First-match-wins adjudication ladder (RFC 0018 §3.1).

    Total and disjoint over every corpus row. `now` is injected so rows 4 and 5
    (`pending` vs `stale-open`) are a function of an argument, not of the wall
    clock — otherwise the classification suite flaps.
    """
    labels = set(row.get("labels") or [])
    has_tp = TRUE_POSITIVE_LABEL in labels
    has_fp = FALSE_POSITIVE_LABEL in labels
    if has_tp and has_fp:
        return "conflicted"
    if has_tp:
        return "true-positive"
    if has_fp:
        return "false-positive"
    if str(row.get("state", "")).upper() == "OPEN":
        created = parse_iso8601(row.get("created_at", ""))
        if now - created <= timedelta(days=STALE_DAYS):
            return "pending"
        return "stale-open"
    # Closed with no verdict label. `COMPLETED` alone is NOT evidence of a true
    # positive (RFC 0018 §1.1 A2) — it means somebody closed the issue, which is
    # issue hygiene, not reviewer correctness.
    return "unadjudicated"


def adjudicated(verdict: str) -> bool:
    """Only an explicit human verdict counts toward a published ratio."""
    return verdict in ("true-positive", "false-positive")


def wilson(tp: int, n: int) -> tuple[float, float]:
    """Wilson score interval, 95%. Pure arithmetic, no third-party dependency.

    Wilson rather than the normal approximation because the counts are small and
    the proportions sit near the boundaries, where the normal interval leaves the
    unit range entirely.
    """
    if n <= 0:
        raise InputError("wilson() needs n > 0")
    if tp < 0 or tp > n:
        raise InputError(f"wilson() needs 0 <= tp <= n (got tp={tp}, n={n})")
    p = tp / n
    z2 = Z * Z
    denominator = 1.0 + z2 / n
    centre = (p + z2 / (2 * n)) / denominator
    half = (Z * math.sqrt(p * (1.0 - p) / n + z2 / (4 * n * n))) / denominator
    return (max(0.0, centre - half), min(1.0, centre + half))


def family(edge: str) -> str:
    """Partition an edge id by roster MEMBERSHIP, never by string prefix.

    A `startswith(...)` test would require the roster prefix as a literal in this
    file, which is exactly the roster copy the import above exists to prevent.
    """
    if edge in PHASE1_CONTRIBUTORS:
        return "headline"
    if edge in PHASE2_CONTRIBUTORS:
        return "phase2"
    return "other"


def row_section(row: dict) -> str:
    """The single section a row is counted in — total and disjoint over rows.

    Quarantine first (RFC 0018 §3.2): only `trailer`-attributed rows can reach a
    published table at all. Then empty-edges, then the first family its edges
    touch, in headline > phase2 > other order.
    """
    if row.get("attribution_source") != "trailer":
        return "pre-instrumentation"
    edges = row.get("edges") or []
    if not edges:
        return "unattributed"
    families = {family(edge) for edge in edges}
    for candidate in ("headline", "phase2", "other"):
        if candidate in families:
            return candidate
    return "other"


def _empty_counts() -> dict:
    counts = {verdict: 0 for verdict in CLASSES}
    counts["rows"] = 0
    counts["not_planned"] = 0
    return counts


def aggregate(rows: list, now: datetime) -> dict:
    """Fold corpus rows into per-edge, per-section and per-attribution tallies.

    A row carrying k edges is counted ONCE PER EDGE in `edges` (each lens really
    did produce that finding), and once in `sections`. The two totals therefore
    differ whenever a cross-lens merge happened, so `multi_edge_rows` is
    published beside them and the arithmetic stays auditable.
    """
    per_edge: dict = {}
    per_section = {name: 0 for name in SECTIONS}
    per_attribution = {name: _empty_counts() for name in ATTRIBUTION_SOURCES}
    totals = _empty_counts()
    multi_edge_rows = 0
    edge_observations = 0

    for row in rows:
        verdict = classify(row, now)
        not_planned = 1 if str(row.get("state_reason", "")).upper() == "NOT_PLANNED" else 0

        totals["rows"] += 1
        totals[verdict] += 1
        totals["not_planned"] += not_planned

        source = row.get("attribution_source")
        if source not in per_attribution:
            raise InputError(
                f"row {row.get('number')} has attribution_source={source!r}; "
                f"expected one of {ATTRIBUTION_SOURCES}"
            )
        per_attribution[source]["rows"] += 1
        per_attribution[source][verdict] += 1
        per_attribution[source]["not_planned"] += not_planned

        per_section[row_section(row)] += 1

        if source != "trailer":
            continue
        edges = row.get("edges") or []
        if len(edges) > 1:
            multi_edge_rows += 1
        for edge in edges:
            edge_observations += 1
            bucket = per_edge.setdefault(edge, _empty_counts())
            bucket["rows"] += 1
            bucket[verdict] += 1
            bucket["not_planned"] += not_planned

    return {
        "edges": per_edge,
        "sections": per_section,
        "attribution": per_attribution,
        "totals": totals,
        "multi_edge_rows": multi_edge_rows,
        "edge_observations": edge_observations,
    }


def lens_stats(counts: dict) -> dict:
    """tp / fp / n / point estimate for one edge, with the publication floor."""
    tp = counts.get("true-positive", 0)
    fp = counts.get("false-positive", 0)
    n = tp + fp
    point = (tp / n) if n > 0 else None
    return {"tp": tp, "fp": fp, "n": n, "point": point}


def fmt_ratio(value: float) -> str:
    return f"{value:.3f}"


def precision_cell(counts: dict) -> str:
    stats = lens_stats(counts)
    if stats["n"] < MIN_N_PUBLISH:
        return f"insufficient-data (n={stats['n']})"
    low, high = wilson(stats["tp"], stats["n"])
    return (
        f"{fmt_ratio(stats['point'])} "
        f"(95% CI {fmt_ratio(low)}–{fmt_ratio(high)}, n={stats['n']})"
    )


def threshold_cell(counts: dict) -> str:
    """No per-lens threshold below MIN_N_THRESHOLD — the global default stands."""
    stats = lens_stats(counts)
    if stats["n"] < MIN_N_THRESHOLD:
        return f"insufficient-data (n={stats['n']})"
    low, _high = wilson(stats["tp"], stats["n"])
    return fmt_ratio(low)


# --- render ------------------------------------------------------------------

_LENS_HEADER = (
    "| Lens | Precision | tp | fp | not planned | unadjudicated | pending "
    "| stale-open | conflicted |"
)
_LENS_RULE = "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"


def _lens_row(edge: str, counts: dict) -> str:
    return (
        f"| `{edge}` | {precision_cell(counts)} | {counts['true-positive']} "
        f"| {counts['false-positive']} | {counts['not_planned']} "
        f"| {counts['unadjudicated']} | {counts['pending']} "
        f"| {counts['stale-open']} | {counts['conflicted']} |"
    )


def render(corpus: dict, baseline: dict, now: datetime) -> str:
    """Deterministic markdown. Byte equality with this output IS the freshness gate.

    Determinism rules: roster order for rosters, sorted keys everywhere else,
    fixed float formatting, `\\n` endings, exactly one trailing newline.
    """
    rows = corpus.get("rows") or []
    stats = aggregate(rows, now)
    per_edge = stats["edges"]
    lines: list[str] = []

    lines.append("# Measured reviewer precision")
    lines.append("")
    lines.append("<!-- GENERATED FILE — do not edit by hand.")
    lines.append("     regenerate: python3 tools/eval/review-precision.py --refresh")
    lines.append("     verify:     python3 tools/eval/review-precision.py --check")
    lines.append("     contract:   docs/rfc/0018-review-precision-eval.md")
    lines.append("-->")
    lines.append("")
    lines.append(
        f"Corpus: `{corpus.get('corpus_path_hint', 'tools/eval/corpus.json')}` — "
        f"{stats['totals']['rows']} rows carrying label "
        f"`{corpus.get('label', DEFAULT_LABEL)}` in `{corpus.get('repo', 'unknown')}`, "
        f"mined {corpus.get('generated_at', 'unknown')}."
    )
    lines.append(
        f"Baseline: measured {baseline.get('measured_at', 'unknown')}. "
        "Ladder, quarantine rule and every floor below are normative in RFC 0018."
    )
    lines.append("")
    lines.append(
        f"- `n` counts ADJUDICATED rows only — those carrying `{TRUE_POSITIVE_LABEL}` "
        f"or `{FALSE_POSITIVE_LABEL}`. A closed, unlabelled finding is "
        "`unadjudicated`, never a true positive."
    )
    lines.append(
        f"- Publication floor: below n={MIN_N_PUBLISH} a lens reports "
        "`insufficient-data`, never a ratio."
    )
    lines.append(
        f"- Threshold floor: below n={MIN_N_THRESHOLD} no per-lens threshold is "
        "derived and the global default stands."
    )
    lines.append(f"- Intervals are Wilson score, 95% (z={Z}).")
    lines.append(
        "- Only rows whose lens attribution came from the machine-readable "
        "`uberdev-finding-meta` trailer reach the tables below; everything else "
        "is quarantined in the pre-instrumentation section."
    )
    lines.append("")

    lines.append("## Phase 1 — reviewer lenses")
    lines.append("")
    lines.append(_LENS_HEADER)
    lines.append(_LENS_RULE)
    for edge in PHASE1_CONTRIBUTORS:
        lines.append(_lens_row(edge, per_edge.get(edge, _empty_counts())))
    lines.append("")

    lines.append("## Phase 2 — simplify lenses")
    lines.append("")
    lines.append(_LENS_HEADER)
    lines.append(_LENS_RULE)
    for edge in PHASE2_CONTRIBUTORS:
        lines.append(_lens_row(edge, per_edge.get(edge, _empty_counts())))
    lines.append("")

    lines.append("## Other edges")
    lines.append("")
    other_edges = sorted(edge for edge in per_edge if family(edge) == "other")
    if other_edges:
        lines.append(_LENS_HEADER)
        lines.append(_LENS_RULE)
        for edge in other_edges:
            lines.append(_lens_row(edge, per_edge[edge]))
    else:
        lines.append("_No findings attributed to an edge outside the two rosters._")
    lines.append("")

    lines.append("## Unattributed")
    lines.append("")
    lines.append(
        f"{stats['sections']['unattributed']} row(s) carry the trailer but record "
        "no edge. An empty `edges=` is a recorded state, not an invitation to "
        "guess a lens."
    )
    lines.append("")

    lines.append("## Pre-instrumentation (low confidence)")
    lines.append("")
    lines.append(
        "These rows predate the `uberdev-finding-meta` trailer, so their lens is "
        "either a display-only prose string or absent entirely. They are excluded "
        "from every ratio above and from the ratchet, and no precision is computed "
        "for them — reverse-engineering a lens from rendered prose is the "
        "inference the finding pipeline forbids everywhere else."
    )
    lines.append("")
    lines.append(
        "| Attribution source | rows | true-positive | false-positive "
        "| not planned | unadjudicated | pending | stale-open | conflicted |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for source in ATTRIBUTION_SOURCES:
        counts = stats["attribution"][source]
        lines.append(
            f"| `{source}` | {counts['rows']} | {counts['true-positive']} "
            f"| {counts['false-positive']} | {counts['not_planned']} "
            f"| {counts['unadjudicated']} | {counts['pending']} "
            f"| {counts['stale-open']} | {counts['conflicted']} |"
        )
    lines.append("")

    lines.append("## Derived per-lens thresholds")
    lines.append("")
    lines.append("| Lens | Threshold |")
    lines.append("| --- | --- |")
    for edge in PHASE1_CONTRIBUTORS:
        lines.append(f"| `{edge}` | {threshold_cell(per_edge.get(edge, _empty_counts()))} |")
    lines.append("")
    lines.append(
        "A threshold, once derivable, rides the dispatcher input keyed by edge id "
        "— never the agent prompt file, which one reviewer agent shares across two "
        "dispatches (RFC 0018 §7)."
    )
    lines.append("")

    lines.append("## Counts appendix")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("| --- | --- |")
    lines.append(f"| rows total | {stats['totals']['rows']} |")
    for section in SECTIONS:
        lines.append(f"| rows in section `{section}` | {stats['sections'][section]} |")
    for verdict in CLASSES:
        lines.append(f"| rows classified `{verdict}` | {stats['totals'][verdict]} |")
    lines.append(f"| rows closed as NOT_PLANNED | {stats['totals']['not_planned']} |")
    lines.append(f"| multi-edge rows | {stats['multi_edge_rows']} |")
    lines.append(f"| edge observations | {stats['edge_observations']} |")
    lines.append("")
    lines.append(
        "Section counts partition the corpus: every row lands in exactly one, so "
        "they sum to `rows total`. Edge observations count a k-edge row k times, "
        "which is why they can exceed the row count."
    )
    lines.append("")

    return "\n".join(lines) + "\n"


# --- io ----------------------------------------------------------------------


def read_json(path: Path, what: str) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InputError(f"cannot read {what}: {path} ({exc})") from exc
    if not text.strip():
        raise InputError(f"{what} is empty: {path}")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise InputError(f"{what} is not valid JSON: {path} ({exc})") from exc
    if not isinstance(parsed, dict):
        raise InputError(f"{what} is not a JSON object: {path}")
    return parsed


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prompt_surfaces() -> tuple[str, ...]:
    """The reviewer prompt surfaces the precision stamp watches.

    Editing one without re-measuring or declaring it in the baseline's
    `pending[]` fails --check (RFC 0018 §5). A declaration is not an exemption:
    a MEASURED surface keeps its `prompt_digests` entry and reds again the moment
    it stops diverging from it, and an UNMEASURED one must carry an
    `unmeasured_digests` entry that reds on any post-declaration edit.

    DERIVED from PHASE1_CONTRIBUTORS, never hand-listed. A second hand-written
    tuple is a second roster: it can lose an edge the lens tables still publish,
    and the re-affirmation gate then covers a different set from the one it
    exists to guard — the disjoint-predicate shape RFC 0018 §5 is about. That is
    exactly how the convention lens reached the published tables while its own
    prompt file went unstamped.

    A roster edge with no LENS_PROMPT_FILES entry raises rather than being
    skipped: an unmapped lens is an unstamped prompt, and silence there is the
    failure mode. Paths are relative to the plugin root so tests can point the
    stamp at a fixture tree.
    """
    surfaces: list[str] = []
    for edge in PHASE1_CONTRIBUTORS:
        agent_file = LENS_PROMPT_FILES.get(edge.rpartition(".")[2])
        if agent_file is None:
            raise InputError(
                f"Phase 1 lens {edge} has no entry in LENS_PROMPT_FILES — add "
                "one, or its reviewer prompt ships unstamped"
            )
        rel = f"agents/{agent_file}"
        if rel not in surfaces:
            surfaces.append(rel)
    surfaces.extend(SHARED_PROMPT_SURFACES)
    return tuple(surfaces)


def prompt_digests(plugin_root: Path) -> dict:
    digests = {}
    for rel in prompt_surfaces():
        target = plugin_root / rel
        if not target.is_file():
            raise InputError(f"reviewer prompt surface is missing: {target}")
        digests[rel] = sha256_file(target)
    return digests


# --- refresh (the only mode that touches the network) ------------------------


def gh_json(args: list) -> object:
    try:
        completed = subprocess.run(
            ["gh", *args], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        raise InputError(f"cannot execute gh: {exc}") from exc
    if completed.returncode != 0:
        raise InputError(
            f"gh {' '.join(args)} failed rc={completed.returncode}: "
            f"{completed.stderr.strip()[:200]}"
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise InputError(f"gh {' '.join(args)} did not return JSON ({exc})") from exc


def resolve_repo(explicit: str | None) -> str:
    """The repository slug is derived, never hardcoded — this tool is repo-agnostic."""
    if explicit:
        return explicit
    slug = gh_json(["repo", "view", "--json", "nameWithOwner"])
    if not isinstance(slug, dict) or not slug.get("nameWithOwner"):
        raise InputError("gh repo view did not return a nameWithOwner")
    return str(slug["nameWithOwner"])


def _find_line(body: str, prefix: str) -> str | None:
    for line in body.splitlines():
        if line.startswith(prefix):
            return line
    return None


def parse_meta_trailer(body: str) -> dict | None:
    """Parse the machine-authority trailer. Returns None when absent."""
    line = _find_line(body, META_TRAILER_OPEN)
    if line is None:
        return None
    inner = line[len(META_TRAILER_OPEN):]
    if inner.endswith("-->"):
        inner = inner[: -len("-->")]
    fields: dict = {}
    for token in inner.split():
        if "=" not in token:
            continue
        key, _, value = token.partition("=")
        fields[key] = value
    return fields


def parse_fingerprint(body: str) -> tuple[str, str]:
    """Return (slug, fingerprint) from the fingerprint marker, or ("", "")."""
    for line in body.splitlines():
        if not line.startswith(FINGERPRINT_MARKER_OPEN):
            continue
        rest = line[len(FINGERPRINT_MARKER_OPEN):]
        slug, _, tail = rest.partition("-finding fingerprint=")
        if not tail:
            continue
        return slug, tail.replace("-->", "").strip()
    return "", ""


def parse_location(body: str) -> tuple[str, int | None]:
    line = _find_line(body, "**File:**")
    if line is None:
        return "", None
    inside = line.partition("`")[2].rpartition("`")[0]
    location, _, line_no = inside.rpartition(":")
    if location and line_no.isdigit():
        return location, int(line_no)
    return inside, None


def _field_after(body: str, prefix: str) -> str:
    line = _find_line(body, prefix)
    if line is None:
        return ""
    return line[len(prefix):].strip()


def extract_row(issue: dict) -> dict:
    """Extract the recorded fields from one issue. The BODY IS DISCARDED.

    A raw body can carry a forged `<!-- uberdev:` marker into the tree, where the
    same fail-CLOSED dedupe and refusal paths read it (RFC 0018 §2.1/§4). Only
    the extracted, typed fields below are ever committed.
    """
    body = issue.get("body") or ""
    trailer = parse_meta_trailer(body)
    slug, fingerprint = parse_fingerprint(body)
    path, line_no = parse_location(body)

    if trailer is not None:
        attribution_source = "trailer"
        edges = [edge for edge in trailer.get("edges", "").split(",") if edge]
        slug = trailer.get("slug", slug)
        severity = trailer.get("severity", "")
        tier = trailer.get("tier", "")
    elif _find_line(body, "**Agent:**") is not None:
        attribution_source = "agent-line"
        edges = []
        severity = _field_after(body, "**Severity:**")
        tier = _field_after(body, "**Tier:**")
    else:
        attribution_source = "none"
        edges = []
        severity = _field_after(body, "**Severity:**")
        tier = _field_after(body, "**Tier:**")

    return {
        "number": issue.get("number"),
        "state": str(issue.get("state", "")).upper(),
        "state_reason": str(issue.get("stateReason") or "").upper(),
        "created_at": issue.get("createdAt") or "",
        "closed_at": issue.get("closedAt") or "",
        "labels": sorted(
            label.get("name", "") for label in (issue.get("labels") or [])
        ),
        "slug": slug,
        "edges": edges,
        "path": path,
        "line": line_no,
        "severity": severity,
        "tier": tier,
        "attribution_source": attribution_source,
        "fingerprint": fingerprint,
    }


def refresh(args, now: datetime) -> dict:
    repo = resolve_repo(args.repo)
    issues = gh_json(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--label",
            args.label,
            "--state",
            "all",
            "--limit",
            str(args.limit),
            "--json",
            "number,state,stateReason,createdAt,closedAt,labels,body",
        ]
    )
    if not isinstance(issues, list):
        raise InputError("gh issue list did not return a JSON array")
    if len(issues) >= args.limit:
        # A truncated mine would silently publish a precision computed on a
        # prefix of the corpus, which is worse than publishing nothing.
        raise InputError(
            f"gh returned {len(issues)} issues at --limit {args.limit}; the mine is "
            "probably truncated — raise --limit and re-run rather than publishing a "
            "number measured on a prefix of the corpus"
        )
    rows = sorted((extract_row(issue) for issue in issues), key=lambda r: r["number"])
    return {
        "schema_version": SCHEMA_VERSION,
        "repo": repo,
        "label": args.label,
        "limit": args.limit,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpus_path_hint": "tools/eval/corpus.json",
        "rows": rows,
    }


def seed_baseline(corpus: dict, plugin_root: Path, now: datetime) -> dict:
    stats = aggregate(corpus.get("rows") or [], now)
    lenses = {}
    for edge in (*PHASE1_CONTRIBUTORS, *PHASE2_CONTRIBUTORS):
        counts = stats["edges"].get(edge, _empty_counts())
        entry = lens_stats(counts)
        lenses[edge] = {"tp": entry["tp"], "fp": entry["fp"], "n": entry["n"]}
    return {
        "schema_version": SCHEMA_VERSION,
        "measured_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lenses": lenses,
        "prompt_digests": prompt_digests(plugin_root),
        "pending": [],
        # After a refresh EVERY surface is stamped, so this map is correctly
        # empty — but it is emitted as an empty map rather than left absent, so
        # the shape --refresh writes is one check_prompt_digests fully describes.
        "unmeasured_digests": {},
    }


# --- check -------------------------------------------------------------------


def check_freshness(report_path: Path, expected: str) -> list:
    """[-s] first: a missing or 0-byte report is a vacuous artifact, not a pass."""
    if not report_path.is_file():
        return [f"report is missing: {report_path}"]
    if report_path.stat().st_size == 0:
        return [f"report is 0 bytes: {report_path}"]
    actual = report_path.read_text(encoding="utf-8")
    if actual != expected:
        return [
            f"report is stale — it does not match a re-render of the corpus: "
            f"{report_path}"
        ]
    return []


def check_ratchet(corpus: dict, baseline: dict, now: datetime) -> list:
    """A lens is ARMED only when both sides have n >= MIN_N_PUBLISH.

    An armed lens reds iff the new point estimate is below the baseline point
    estimate AND the new Wilson upper bound is also below it. The second clause
    is the noise floor: a drop the interval cannot distinguish from sampling
    noise must not red CI.
    """
    problems = []
    stats = aggregate(corpus.get("rows") or [], now)
    lenses = baseline.get("lenses")
    if not isinstance(lenses, dict):
        raise InputError("baseline `lenses` is not an object")
    for edge in sorted(lenses):
        recorded = lenses[edge]
        if not isinstance(recorded, dict):
            raise InputError(f"baseline lens {edge} is not an object")
        base_tp = int(recorded.get("tp", 0))
        base_n = int(recorded.get("n", 0))
        if base_n < MIN_N_PUBLISH:
            continue
        current = lens_stats(stats["edges"].get(edge, _empty_counts()))
        if current["n"] < MIN_N_PUBLISH:
            continue
        base_point = base_tp / base_n
        _low, high = wilson(current["tp"], current["n"])
        if current["point"] < base_point and high < base_point:
            problems.append(
                f"precision ratchet: {edge} fell from {fmt_ratio(base_point)} "
                f"(n={base_n}) to {fmt_ratio(current['point'])} "
                f"(n={current['n']}, 95% CI upper {fmt_ratio(high)})"
            )
    return problems


def check_prompt_digests(baseline: dict, plugin_root: Path) -> list:
    """Re-affirmation stamp: an edited reviewer prompt must be declared or re-measured."""
    problems = []
    recorded = baseline.get("prompt_digests")
    if not isinstance(recorded, dict):
        raise InputError("baseline `prompt_digests` is not an object")
    pending = baseline.get("pending")
    if not isinstance(pending, list):
        raise InputError("baseline `pending` is not a list")
    declared = {}
    for entry in pending:
        if not isinstance(entry, dict) or set(entry) != {"path", "reason"}:
            raise InputError(
                "baseline `pending` entries must be {path, reason} objects "
                f"(got {entry!r})"
            )
        if not entry["reason"]:
            raise InputError(f"baseline `pending` entry has an empty reason: {entry['path']}")
        declared[entry["path"]] = entry["reason"]

    # ABSENT means {} — an empty watchlist, never "nothing to check". A baseline
    # written before this field existed and carrying no declared-unmeasured
    # surface stays valid; one that DOES carry such a surface fails closed
    # through the per-surface arm below, with the field named in the message.
    # PRESENT-but-malformed is an InputError (rc=2), matching how `prompt_digests`
    # and `pending` are already validated: "your baseline is unreadable" and
    # "your tree drifted" are different answers, and a malformed map that fell
    # through to the drift compare would send the reader hunting a drift that
    # does not exist.
    unmeasured = baseline.get("unmeasured_digests", {})
    if not isinstance(unmeasured, dict):
        raise InputError("baseline `unmeasured_digests` is not an object")
    for key, value in unmeasured.items():
        if not isinstance(value, str):
            raise InputError(
                f"baseline `unmeasured_digests` value for {key} is not a string"
            )

    live = prompt_digests(plugin_root)
    surfaces = prompt_surfaces()
    for rel in surfaces:
        if rel not in recorded:
            # A surface with NO recorded digest is honest in exactly one case:
            # the file postdates `measured_at`, so there are no measured bytes
            # to stamp and stamping the current ones would assert a measurement
            # that never happened. pending[] is where that gets SAID — the same
            # place a drifted-but-not-re-measured surface is declared. Silence
            # here is the unstamped-prompt hole the whole stamp exists to close,
            # so an undeclared omission still reds.
            if rel not in declared:
                problems.append(f"baseline records no digest for reviewer prompt: {rel}")
                continue
            # DELIBERATE ASYMMETRY (#467). A *measured* declaration needs no
            # second field: `prompt_digests[rel]` still holds the measured bytes,
            # so the anti-parking rule below reds the moment the path stops
            # diverging from them. An *unmeasured* declaration has no measured
            # bytes to return to, so anti-parking can never fire for it — which
            # is exactly why it needs a tether of its own. Before this arm
            # existed the branch simply `continue`d, and a declared-unmeasured
            # prompt was unwatched permanently: editing
            # agents/convention-compliance.md left --check at rc=0.
            # `unmeasured_digests[rel]` asserts nothing about what the published
            # numbers were measured against — only which bytes were current when
            # the declaration was written — so recording it is honest where
            # stamping a measured digest would not be.
            if rel not in unmeasured:
                problems.append(
                    f"declared-unmeasured reviewer prompt has no recorded bytes: {rel} "
                    "— record its current sha256 under `unmeasured_digests` so the "
                    "pending[] declaration is bounded"
                )
            elif unmeasured[rel] != live[rel]:
                problems.append(
                    f"declared-unmeasured reviewer prompt changed since it was "
                    f"declared: {rel} — re-record its `unmeasured_digests` entry and "
                    "restate the pending[] reason, or re-measure (--refresh)"
                )
            continue
        drifted = recorded[rel] != live[rel]
        if drifted and rel not in declared:
            problems.append(
                f"reviewer prompt changed since the numbers were measured: {rel} "
                "— re-measure (--refresh) or declare it in the baseline's pending[]"
            )
        if not drifted and rel in declared:
            problems.append(
                f"stale declaration, path does not diverge: {rel} "
                "— a pending[] entry must name a real drift, or it becomes a "
                "permanent exemption"
            )
    # The stamp's OTHER direction, and it is not symmetry for its own sake. The
    # loop above walks prompt_surfaces(), so a digest recorded under a key that
    # is NO LONGER a surface is never examined by it: drop a lens from
    # LENS_PROMPT_FILES and its prompt silently stops being watched while the
    # orphaned key sits in the baseline looking like coverage. That is a
    # predicate disjoint from the drift it has to find — the same shape RFC 0018
    # §5 is about, one level up. Comparing the recorded key set back against the
    # derived one is what closes it.
    for path in sorted(set(recorded) - set(surfaces)):
        problems.append(f"baseline records a digest for a non-surface: {path}")
    # The same orphan rule for the second map, for the same reason: the surface
    # loop above walks prompt_surfaces(), so a key that is no longer a surface is
    # never visited by it and sits in the baseline looking like coverage.
    for path in sorted(set(unmeasured) - set(surfaces)):
        problems.append(f"baseline records an unmeasured digest for a non-surface: {path}")
    # A path in BOTH maps is ambiguous about which digest the check compares
    # against, and whichever answer the code picked would let the other field
    # mask it. That is a smaller copy of the one-field-two-jobs conflation this
    # second map exists to remove, so it is refused rather than resolved: a
    # surface is either measured or declared-unmeasured, never both.
    for path in sorted(set(recorded) & set(unmeasured)):
        problems.append(
            f"{path} is recorded in BOTH prompt_digests and unmeasured_digests — one "
            "field would mask the other; a surface is either measured or "
            "declared-unmeasured, never both"
        )
    # Membership is tested against the DERIVED surface set, not against
    # `recorded`: a legitimately-unstamped surface (the postdates-measurement
    # case above) is absent from `recorded` while still being a real surface, so
    # `recorded` would reject exactly the declaration this check is meant to allow.
    for path in sorted(declared):
        if path not in surfaces:
            problems.append(f"pending names a path that is not a reviewer prompt surface: {path}")
    return problems


# --- cli ---------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="review-precision.py",
        description="Measure per-lens precision of the review-pr reviewer fleet (RFC 0018).",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true", help="mine live GitHub, then render")
    mode.add_argument("--render", action="store_true", help="render the report from the corpus")
    mode.add_argument("--check", action="store_true", help="freshness + ratchet + digest stamp")
    parser.add_argument("--corpus", default=None, help="corpus.json path override")
    parser.add_argument("--baseline", default=None, help="precision-baseline.json path override")
    parser.add_argument("--report", default=None, help="report markdown path override")
    parser.add_argument("--plugin-root", default=None, help="plugin root for prompt digests")
    parser.add_argument("--now", default=None, help="ISO8601 clock injection (default: system UTC)")
    parser.add_argument("--repo", default=None, help="OWNER/NAME override for --refresh")
    parser.add_argument("--label", default=DEFAULT_LABEL, help="issue label to mine")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="max issues to mine")
    return parser


def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    here = Path(__file__).resolve().parent
    corpus_path = Path(args.corpus) if args.corpus else here / "corpus.json"
    baseline_path = Path(args.baseline) if args.baseline else here / "precision-baseline.json"
    report_path = (
        Path(args.report) if args.report else REPO_ROOT / "docs" / "eval" / "review-precision.md"
    )
    plugin_root = Path(args.plugin_root) if args.plugin_root else PLUGIN_ROOT_DEFAULT

    try:
        mine_clock = parse_iso8601(args.now) if args.now else datetime.now(timezone.utc)

        if args.refresh:
            corpus = refresh(args, mine_clock)
            write_json(corpus_path, corpus)
            baseline = seed_baseline(corpus, plugin_root, mine_clock)
            write_json(baseline_path, baseline)
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(render(corpus, baseline, mine_clock), encoding="utf-8")
            print(f"refreshed {len(corpus['rows'])} rows -> {corpus_path}")
            print(f"seeded baseline -> {baseline_path}")
            print(f"rendered -> {report_path}")
            return 0

        corpus = read_json(corpus_path, "corpus")
        baseline = read_json(baseline_path, "baseline")
        # The render clock comes from the CORPUS, not the wall. `pending` vs
        # `stale-open` is a function of the clock, so a wall-clock render would
        # make the committed report drift by itself and red the freshness gate
        # in CI some days after it was written, with nothing having changed.
        # `--now` still overrides, which is how the ladder rows are tested.
        now = parse_iso8601(args.now) if args.now else parse_iso8601(
            corpus.get("generated_at") or mine_clock.strftime("%Y-%m-%dT%H:%M:%SZ")
        )

        if args.render:
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(render(corpus, baseline, now), encoding="utf-8")
            print(f"rendered -> {report_path}")
            return 0

        problems = check_freshness(report_path, render(corpus, baseline, now))
        problems.extend(check_ratchet(corpus, baseline, now))
        problems.extend(check_prompt_digests(baseline, plugin_root))
        if problems:
            for problem in problems:
                print(f"review-precision: {problem}", file=sys.stderr)
            return 1
        print("review-precision: report, ratchet and prompt digests all agree")
        return 0
    except InputError as exc:
        print(f"review-precision: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
