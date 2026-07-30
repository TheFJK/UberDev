#!/usr/bin/env python3
"""Deterministic 4-axis scoring + dossier render for /uberthink (spec §3, §6).

Pure scoring core: no LLM calls, no network. The Arbiter agent writes
`ranked.yaml` to disk; this module aggregates / cuts / ranks / renders.

Pattern mirrors `skills/uberscan-pipeline/report.py`: shared `cell()` /
`envelope()` from `lib/report_primitives.py` (anchored on this file's
location so the import resolves regardless of cwd), one CLI entry with
`--emit {dossier,aggregate,shortlist,floor-survivors}` switching the artifact
written to stdout (or to `--out`).

The two deterministic CUTS — the Wave-4 per-island Pareto shortlist and the
Wave-7 feasibility-floor survivor list — live HERE, as first-class CLI modes
with real exit codes. They used to be ad-hoc `python3 - <<'PY'` heredocs
inside the pipeline SKILL.md, each running under `2>/dev/null || true`: an
ImportError wrote no shortlist, the pipeline then counted zero falsifier
dispatches and tripped its non-convergence breaker, and a ~90-minute run
reported "the goal as framed admitted no feasible novel approach" — a tooling
crash rendered as a substantive verdict. A missing/unreadable input now raises
`ArtifactError` and exits non-zero so the caller can tell a CRASH from an
honestly-empty result.

Contract pinned by `tests/uberthink-report.test.sh` (spec §3): the names
`axis_score / feasibility_floor_fails / ambition_score / pareto_frontier /
moonshot_frontier / rank` and their signatures are stable, as are
`load_composite_designs / compute_shortlist / collect_wave7_designs /
compute_floor_survivors` and the `ArtifactError` exit-code mapping.
"""
from __future__ import annotations
import argparse
import glob
import os
import sys
from typing import Iterable, Sequence

import yaml

# skills/uberthink-pipeline/report.py -> ../../lib/report_primitives.py
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from report_primitives import cell, envelope  # noqa: E402

# Weighted sub-criteria per axis (spec §3). The Arbiter fills these sub-scores;
# axis_score() collapses them deterministically. Sub-criterion names are the
# stable wire contract between the Arbiter agent's YAML and this module.
NOVELTY_W = {
    "prior_art_distance": 0.30,
    "cross_domain_reach": 0.25,
    "non_obviousness": 0.25,
    "mechanism_originality": 0.20,
}
FEAS_W = {
    "hard_constraint": 0.30,
    "survives_adversary": 0.25,
    "buildability": 0.20,
    "premortem_resilience": 0.15,
    "deployment_reality": 0.10,
}
COMB_W = {
    "cross_consistency": 0.40,
    "synergy": 0.35,
    "coverage": 0.25,
}
IMPACT_W = {
    "transformative": 0.40,
    "generality": 0.30,
    "defensibility": 0.30,
}

# AmbitionScore = Novelty^ALPHA * Feasibility^BETA * Combination^GAMMA * Impact^DELTA.
# Exponents (spec §3) put Feasibility/Combination/Impact above raw Novelty so the
# crackpot guard (FEAS_FLOOR) is reinforced by the scalar ranking and a near-zero
# on any axis tanks the product. Tunable here, NOT in the agents.
ALPHA, BETA, GAMMA, DELTA = 1.0, 1.2, 1.3, 1.2
FEAS_FLOOR = 4.0

# ---- Scoring core ---------------------------------------------------------


def axis_score(subs: dict, weights: dict) -> float:
    """Weighted aggregate of an axis' sub-criteria into a 0..10 axis score.

    Missing sub-criteria default to 0 (a missed score is treated as a zero, not
    silently dropped); the weights determine the ceiling. `round(..., 6)` keeps
    the test contract (`abs(...) < 1e-9`) clean against float drift.
    """
    return round(sum(float(subs.get(k, 0)) * w for k, w in weights.items()), 6)


def feasibility_floor_fails(feas_axis: float, feas_subs: dict) -> bool:
    """Spec §3 hard feasibility floor (crackpot gate).

    A design is CUT if its Feasibility axis < 4.0 OR any single feasibility
    sub-criterion is exactly 0 — a physics-law violation or trivially-broken-
    by-the-Adversary signal that nothing else can compensate for.
    """
    return float(feas_axis) < FEAS_FLOOR or any(float(v) == 0 for v in feas_subs.values())


def ambition_score(novelty: float, feasibility: float, combination: float, impact: float) -> float:
    """AmbitionScore = N^ALPHA * F^BETA * C^GAMMA * I^DELTA (spec §3).

    Product form so a near-zero on any axis tanks the score — you can't win on
    novelty alone. Returns 0 if any input is 0 (kept implicit by the product).

    Each axis is clamped to non-negative (``max(0.0, float(x))``) BEFORE the
    fractional power. A negative base with a fractional exponent (BETA/GAMMA/
    DELTA = 1.2/1.3/1.2) does NOT raise in Python — it returns a ``complex``
    (e.g. ``(-2.0) ** 1.2`` is complex), which then makes ``round(...)`` raise
    ``TypeError`` here and, if it ever reached the caller, makes ``rank()``'s
    ``sorted(..., key=ambition)`` raise ``'<' not supported ... complex`` and
    abort the dossier render. ``feasibility_floor_fails()`` only cuts ``feas <
    4.0``, so a negative novelty/combination/impact from the Arbiter's
    ``ranked.yaml`` survives the floor and would otherwise reach the exponent.
    Clamping to 0 fails closed (a negative axis is worse than zero → product 0
    → ambition tanks → still sortable), matching the existing zero-floor
    semantics above.
    """
    return round(
        max(0.0, float(novelty)) ** ALPHA
        * max(0.0, float(feasibility)) ** BETA
        * max(0.0, float(combination)) ** GAMMA
        * max(0.0, float(impact)) ** DELTA,
        6,
    )


def _dominates(b: dict, a: dict, axes: Sequence[str]) -> bool:
    return all(b[x] >= a[x] for x in axes) and any(b[x] > a[x] for x in axes)


def pareto_frontier(designs: Iterable[dict], axes: Sequence[str] = ("novelty", "feasibility", "combination", "impact")) -> list[dict]:
    """Return designs not dominated by any other design on `axes` (higher is better).

    Stable order: iterates the input list once, keeping a design iff no OTHER
    design dominates it on all four axes (strictly better on at least one).
    """
    seq = list(designs)
    return [a for a in seq if not any(_dominates(b, a, axes) for b in seq if b is not a)]


def moonshot_frontier(designs: Iterable[dict]) -> list[dict]:
    """Pareto frontier on (Novelty, Impact) only — the spec §3 moonshot lane.

    A design that's audacious + high-impact but merely-adequate-feasibility still
    surfaces here even if its AmbitionScore isn't #1. This is the structural
    guarantee that wild ideas don't get buried by safe ideas.
    """
    return pareto_frontier(designs, axes=("novelty", "impact"))


def rank(designs: Iterable[dict]) -> list[dict]:
    """Cut feasibility-floor failures, annotate survivors with
    `ambition` / `on_frontier` / `moonshot`, return sorted by ambition desc.

    Designs may carry `feas_subs` (per-feasibility sub-criterion 0–10 scores from
    the falsifier). Survivors are flagged in-place; the input list itself is not
    reordered (a new sorted list is returned).
    """
    seq = list(designs)
    survivors = [
        d for d in seq
        if not feasibility_floor_fails(d.get("feasibility", 0), d.get("feas_subs", {}))
    ]
    # Identity-keyed frontier membership (not id-on-dict — same dict can appear in
    # both frontiers; we want the SAME instance identity to drive both flags).
    front_ids = {id(d) for d in pareto_frontier(survivors)}
    moon_ids = {id(d) for d in moonshot_frontier(survivors)}
    for d in survivors:
        d["ambition"] = ambition_score(
            d.get("novelty", 0),
            d.get("feasibility", 0),
            d.get("combination", 0),
            d.get("impact", 0),
        )
        d["on_frontier"] = id(d) in front_ids
        d["moonshot"] = id(d) in moon_ids
    return sorted(survivors, key=lambda d: d["ambition"], reverse=True)


# ---- Deterministic cuts: Wave-4 shortlist + Wave-7 floor survivors --------

SHORTLIST_TOP_DEFAULT = 7
PRELIM_AXES = ("novelty", "feasibility", "combination", "impact")


class ArtifactError(Exception):
    """An input artifact is missing, or every candidate input was unreadable.

    Raised INSTEAD of returning an empty result. "No composite cleared the
    frontier" and "the composites directory does not exist" are different
    outcomes with different remedies, and only the first one may ever reach the
    dossier as a substantive verdict. The CLI maps this to exit code 3.
    """


def _load_yaml_mapping(path: str) -> dict:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
    if doc is None:
        return {}
    if not isinstance(doc, dict):
        raise yaml.YAMLError("top level is not a mapping")
    return doc


def _prelim_axes(subs) -> dict:
    """Coerce a `prelim_subscores` mapping into the 4 float axes.

    A non-mapping or a non-numeric score raises (ValueError/TypeError) so the
    caller records the record as malformed rather than silently scoring it 0 —
    a silent 0 on `feasibility` is indistinguishable from a real crackpot cut.
    """
    if subs is None:
        subs = {}
    if not isinstance(subs, dict):
        raise TypeError("prelim_subscores is not a mapping")
    return {axis: float(subs.get(axis, 0) or 0) for axis in PRELIM_AXES}


def load_composite_designs(comp_dir: str) -> tuple[list[dict], list[str]]:
    """Load `comp-*.yaml` composites from `comp_dir` into scoreable designs.

    Returns `(designs, malformed)`. Raises `ArtifactError` when `comp_dir` does
    not exist, or when files exist but NONE of them yielded a design (a
    wholly-unreadable input set is a crash, not an empty frontier).
    """
    if not os.path.isdir(comp_dir):
        raise ArtifactError(f"composites directory missing: {comp_dir}")
    paths = sorted(glob.glob(os.path.join(comp_dir, "comp-*.yaml")))
    designs: list[dict] = []
    malformed: list[str] = []
    for path in paths:
        try:
            doc = _load_yaml_mapping(path)
        except (OSError, yaml.YAMLError) as e:
            malformed.append(f"{path}: {e}")
            continue
        for c in doc.get("composites") or []:
            if not isinstance(c, dict):
                malformed.append(f"{path}: a composites[] entry is not a mapping")
                continue
            try:
                axes = _prelim_axes(c.get("prelim_subscores"))
            except (TypeError, ValueError) as e:
                malformed.append(f"{path}: bad prelim_subscores ({e})")
                continue
            design = {
                "id": str(c.get("id") or os.path.basename(path)),
                "title": str(c.get("title") or ""),
                "composite_path": path,
            }
            design.update(axes)
            designs.append(design)
    if paths and not designs:
        raise ArtifactError(
            f"{len(paths)} composite file(s) under {comp_dir} but none yielded a scoreable "
            f"design: {'; '.join(malformed) or 'no composites[] entries'}"
        )
    return designs, malformed


def compute_shortlist(designs: Iterable[dict], top: int = SHORTLIST_TOP_DEFAULT) -> list[dict]:
    """Wave-4 cut: 4-axis Pareto frontier, then top-N by AmbitionScore."""
    front = pareto_frontier(list(designs))
    for d in front:
        d["ambition"] = ambition_score(d["novelty"], d["feasibility"], d["combination"], d["impact"])
    return sorted(front, key=lambda d: d["ambition"], reverse=True)[: max(0, int(top))]


def falsify_feasibility_subs(composite_path: str) -> dict:
    """Merge `feasibility_sub_scores` from every falsify dossier for a composite.

    Layout (spec §2.4): a composite at `<island>/composites/comp-NNN-<lens>.yaml`
    is attacked by `<island>/falsify/comp-NNN-<lens>-<falsify-lens>.yaml`. First
    non-null value per sub-criterion wins (the `physics` lens owns
    `hard_constraint`, `redteam` owns `survives_adversary`).
    """
    if not composite_path:
        return {}
    base = os.path.basename(composite_path)
    fal_dir = os.path.join(os.path.dirname(os.path.dirname(composite_path)), "falsify")
    merged: dict = {}
    for fal_path in sorted(glob.glob(os.path.join(fal_dir, base.replace(".yaml", "-*.yaml")))):
        try:
            fdoc = _load_yaml_mapping(fal_path)
        except (OSError, yaml.YAMLError):
            continue
        subs = fdoc.get("feasibility_sub_scores") or {}
        if not isinstance(subs, dict):
            continue
        for k, v in subs.items():
            if v is not None and merged.get(k) is None:
                merged[k] = v
    return merged


def collect_wave7_designs(run_dir: str) -> tuple[list[dict], list[str]]:
    """Every composite still in play at Wave 7: global cross-pollinated ones plus
    island finalists that never entered cross-pollination.

    Raises `ArtifactError` when neither source exists at all (nothing reached
    Wave 7 because an upstream wave never wrote its artifacts).
    """
    designs: list[dict] = []
    malformed: list[str] = []
    seen_paths: set[str] = set()

    global_paths = sorted(glob.glob(os.path.join(run_dir, "composites", "*.yaml")))
    shortlist_paths = sorted(glob.glob(os.path.join(run_dir, "island-*", "shortlist.yaml")))
    if not global_paths and not shortlist_paths:
        raise ArtifactError(
            f"no Wave-6 composites and no island shortlists under {run_dir} — "
            "no upstream wave produced a rankable artifact"
        )

    for path in global_paths:
        try:
            doc = _load_yaml_mapping(path)
        except (OSError, yaml.YAMLError) as e:
            malformed.append(f"{path}: {e}")
            continue
        for c in doc.get("composites") or []:
            if not isinstance(c, dict):
                malformed.append(f"{path}: a composites[] entry is not a mapping")
                continue
            try:
                axes = _prelim_axes(c.get("prelim_subscores"))
            except (TypeError, ValueError) as e:
                malformed.append(f"{path}: bad prelim_subscores ({e})")
                continue
            designs.append(dict(axes, id=str(c.get("id") or ""), composite_path=path))
        seen_paths.add(path)

    for path in shortlist_paths:
        try:
            doc = _load_yaml_mapping(path)
        except (OSError, yaml.YAMLError) as e:
            malformed.append(f"{path}: {e}")
            continue
        for d in doc.get("shortlist") or []:
            if not isinstance(d, dict):
                malformed.append(f"{path}: a shortlist[] entry is not a mapping")
                continue
            cp = str(d.get("composite_path") or "")
            if cp and (cp in seen_paths or any(x["composite_path"] == cp for x in designs)):
                continue
            try:
                axes = _prelim_axes({axis: d.get(axis, 0) for axis in PRELIM_AXES})
            except (TypeError, ValueError) as e:
                malformed.append(f"{path}: bad shortlist axes ({e})")
                continue
            designs.append(dict(axes, id=str(d.get("id") or ""), composite_path=cp))
    return designs, malformed


def compute_floor_survivors(designs: Iterable[dict]) -> list[str]:
    """Wave-7 pre-cut: ids whose Feasibility clears the spec §3 crackpot floor."""
    survivors: list[str] = []
    for d in designs:
        feas = float(d.get("feasibility", 0) or 0)
        if feasibility_floor_fails(feas, falsify_feasibility_subs(d.get("composite_path", ""))):
            continue
        survivors.append(d.get("id", ""))
    return survivors


# ---- Dossier render (spec §6) --------------------------------------------


def _fmt_score(v) -> str:
    try:
        return f"{float(v):.1f}"
    except (TypeError, ValueError):
        return cell(v)


def _frame_section(frame: dict) -> list[str]:
    lines = ["## Problem frame (locked)", ""]
    if frame.get("schema"):
        lines.append(f"- **Functional schema:** {cell(frame['schema'])}")
    if frame.get("assumptions"):
        joined = "; ".join(cell(a) for a in frame["assumptions"])
        lines.append(f"- **Inherited assumptions vs real laws:** {joined}")
    if frame.get("prior_art"):
        lines.append(f"- **Prior-art baseline:** {cell(frame['prior_art'])}")
    if frame.get("constraints"):
        lines.append(f"- **Constraint fence:** {cell(frame['constraints'])}")
    if frame.get("donor_domains"):
        joined = ", ".join(cell(d) for d in frame["donor_domains"])
        lines.append(f"- **Donor domains selected:** {joined}")
    lines.append("")
    return lines


def _moonshot_section(ranked: list[dict]) -> list[str]:
    """Spec §6 says the moonshot lane appears FIRST, before the ranked list,
    so a wild high-Novelty/high-Impact design leads even when AmbitionScore puts
    a safer design at the top. Header text uses the literal 🌙 (only emoji in
    the dossier per spec §6)."""
    moons = [d for d in ranked if d.get("moonshot")]
    lines = ["## 🌙 Moonshot lane (Novelty×Impact frontier)", ""]
    if not moons:
        lines.append("_(no moonshot candidates cleared the feasibility floor)_")
        lines.append("")
        return lines
    # Sort moonshots by (Novelty * Impact) desc — the dossier's audacity order.
    moons_sorted = sorted(
        moons,
        key=lambda d: float(d.get("novelty", 0)) * float(d.get("impact", 0)),
        reverse=True,
    )
    for d in moons_sorted:
        title = cell(d.get("title", d.get("id", "?")))
        nov, imp = _fmt_score(d.get("novelty")), _fmt_score(d.get("impact"))
        pitch = cell(d.get("pitch") or d.get("mechanism") or "")
        # The "one feasibility risk that gates it" is the first non-fatal
        # kill-cause if any, else the lowest feasibility sub-criterion as a hint.
        gate = ""
        for kc in d.get("kill_causes") or []:
            if isinstance(kc, dict):
                gate = cell(kc.get("cause", ""))
                if gate:
                    break
        if not gate and d.get("feas_subs"):
            try:
                low_k, low_v = min(d["feas_subs"].items(), key=lambda kv: float(kv[1]))
                gate = f"low {cell(low_k)} (score {_fmt_score(low_v)})"
            except (ValueError, TypeError):
                gate = ""
        lines.append(f"- **{title}** — Novelty {nov} / Impact {imp}")
        if pitch:
            lines.append(f"  - Why audacious: {pitch}")
        if gate:
            lines.append(f"  - Gating feasibility risk: {gate}")
    lines.append("")
    return lines


def _design_block(idx: int, d: dict) -> list[str]:
    """Render one ranked design per spec §6 layout."""
    title = cell(d.get("title", d.get("id", "?")))
    amb = _fmt_score(d.get("ambition", 0))
    front = "on-frontier" if d.get("on_frontier") else "dominated"
    moon = "yes" if d.get("moonshot") else "no"
    lines = [f"### {idx}. {title}  —  AmbitionScore {amb} · Pareto: {front} · Moonshot: {moon}", ""]
    if d.get("pitch"):
        lines.append(cell(d["pitch"]))
        lines.append("")
    if d.get("donor_domains"):
        joined = ", ".join(cell(x) for x in d["donor_domains"])
        lines.append(f"- **Donor domains:** {joined}")
    if d.get("mechanism"):
        lines.append(f"- **Mechanism:** {cell(d['mechanism'])}")
    # Narrative field uses `combination_narrative` to avoid colliding with the
    # `combination` numeric axis used by rank() / ambition_score (spec §3).
    if d.get("combination_narrative"):
        lines.append(f"- **How it combines:** {cell(d['combination_narrative'])}")
    nov, feas, comb, imp = (
        _fmt_score(d.get("novelty")),
        _fmt_score(d.get("feasibility")),
        _fmt_score(d.get("combination")),
        _fmt_score(d.get("impact")),
    )
    lines.append(f"- **Scores:** Novelty {nov} / Feasibility {feas} / Combination {comb} / Impact {imp}")
    # Sub-criteria table (one row per axis).
    subs_rows = []
    for axis_name, key, weights in (
        ("Novelty", "novelty_subs", NOVELTY_W),
        ("Feasibility", "feas_subs", FEAS_W),
        ("Combination", "comb_subs", COMB_W),
        ("Impact", "impact_subs", IMPACT_W),
    ):
        subs = d.get(key) or {}
        if subs:
            cells = " · ".join(f"{cell(k)}={_fmt_score(subs.get(k, 0))}" for k in weights)
            subs_rows.append(f"  - {axis_name}: {cells}")
    if subs_rows:
        lines.append("- **Sub-criteria:**")
        lines.extend(subs_rows)
    kc_list = d.get("kill_causes") or []
    if kc_list:
        lines.append("- **Kill-causes & mitigations:**")
        for kc in kc_list:
            if not isinstance(kc, dict):
                continue
            tag = "FATAL" if kc.get("fatal") else "fixable"
            cause = cell(kc.get("cause", ""))
            mit = cell(kc.get("mitigation", ""))
            piece = f"  - [{tag}] {cause}"
            if mit:
                piece += f" — mitigation: {mit}"
            lines.append(piece)
    if d.get("first_experiment"):
        lines.append(f"- **First experiment to validate:** {cell(d['first_experiment'])}")
    if idx == 1:
        lines.append("- **Next step →** `/uberdev:brainstorm`  (auto-invoked for #1 if `--handoff`)")
    lines.append("")
    return lines


def _culled_section(culled: list[dict]) -> list[str]:
    lines = ["## Culled ideas (appendix)", ""]
    if not culled:
        lines.append("_(no designs were culled — all entrants cleared the feasibility floor)_")
        lines.append("")
        return lines
    for c in culled:
        if not isinstance(c, dict):
            continue
        bits = [cell(c.get("title", c.get("id", "?")))]
        wave = c.get("died_at_wave")
        island = c.get("island")
        if wave is not None:
            bits.append(f"died at Wave {cell(wave)}")
        if island is not None:
            bits.append(f"island {cell(island)}")
        if c.get("reason"):
            bits.append(f"because {cell(c['reason'])}")
        lines.append(f"- {' — '.join(bits)}")
    lines.append("")
    return lines


def _metadata_section(run: dict) -> list[str]:
    lines = ["## Run metadata", ""]
    if run.get("agents_dispatched") is not None:
        lines.append(f"- Agents dispatched: {cell(run['agents_dispatched'])}")
    if run.get("loop_backs") is not None:
        lines.append(f"- Per-island loop-backs: {cell(run['loop_backs'])}")
    cbs = run.get("circuit_breakers_tripped") or []
    if cbs:
        joined = ", ".join(cell(x) for x in cbs)
        lines.append(f"- Circuit breakers tripped: {joined}")
    lines.append(f"- Partial run: {'yes' if run.get('partial') else 'no'}")
    lines.append("")
    return lines


def render_dossier(run: dict, ranked_designs: list[dict], culled: list[dict]) -> str:
    """Render `report.md` per spec §6 (moonshot lane FIRST, then ranked, then culled).

    `run` carries the header fields (goal, run_id, date, islands, loop_backs) plus
    the optional `frame` block. `ranked_designs` is the output of `rank()` (already
    sorted by AmbitionScore desc, with `on_frontier` / `moonshot` flags). `culled`
    is the appendix of designs that failed the floor or were killed during waves.
    """
    goal = cell(run.get("goal", ""))
    run_id = cell(run.get("run_id", "?"))
    date = cell(run.get("date", ""))
    islands = cell(run.get("islands", 1))
    loops = cell(run.get("loop_backs", 0))
    header = (
        f"# /uberthink — {goal}           "
        f"Run {run_id} · {date} · islands={islands} · loop-backs={loops}"
    )
    parts: list[str] = [header, ""]
    if run.get("frame"):
        parts.extend(_frame_section(run["frame"]))
    # Spec §6: moonshot lane appears BEFORE ranked approaches so wild ideas lead.
    parts.extend(_moonshot_section(ranked_designs))
    parts.append("## Ranked approaches (by AmbitionScore)")
    parts.append("")
    if not ranked_designs:
        parts.append("_(no designs cleared the feasibility floor — see the spec §4 CB-CONVERGE breaker note in run metadata)_")
        parts.append("")
    else:
        for i, d in enumerate(ranked_designs, start=1):
            parts.extend(_design_block(i, d))
    parts.extend(_culled_section(culled))
    parts.extend(_metadata_section(run))
    return "\n".join(parts).rstrip() + "\n"


# ---- findings-to-issues aggregate (spec §6 + uberscan mirror) -------------


def _severity_for(d: dict) -> str:
    """Map a ranked design's flags to a findings-to-issues severity.

    Filed designs are top-N picks the user explicitly asked for; rank #1 is
    `critical` (so @author mention fires + Blocks: backref renders); the rest
    are `major` (silent file). This matches `route_by_severity` in
    `findings-to-issues.md` Step 4.
    """
    return "critical" if d.get("_filed_rank", 99) == 1 else "major"


def emit_f2i_aggregate(ranked_designs: list[dict], max_new: int) -> str:
    """Render the `<external-untrusted-input source="uberthink-aggregate">` envelope.

    One row per top-`max_new` ranked design. Columns:
        severity · location · agent · disposition · summary · detail
    Matches the wire shape `uberscan-pipeline/report.py:emit_f2i_aggregate` emits
    (`uberscan-aggregate` envelope) so `findings-to-issues` parses it identically;
    only the `source` tag and the per-row content differ.
    """
    picks = list(ranked_designs[: max(0, int(max_new))])
    # Tag the rank position so `_severity_for` can map #1 -> critical, rest -> major.
    for i, d in enumerate(picks, start=1):
        d["_filed_rank"] = i

    body_lines = [
        "| severity | location | agent | disposition | summary | detail |",
        "|---|---|---|---|---|---|",
    ]
    for d in picks:
        sev = _severity_for(d)
        loc = cell(f"uberthink:idea:{d.get('id', '?')}")
        agent = cell("uberthink-arbiter")
        summary = cell(d.get("title") or d.get("id") or "?")
        detail_parts = []
        if d.get("pitch"):
            detail_parts.append(str(d["pitch"]))
        if d.get("mechanism"):
            detail_parts.append(f"Mechanism: {d['mechanism']}")
        if d.get("combination_narrative"):
            detail_parts.append(f"Combination: {d['combination_narrative']}")
        if d.get("donor_domains"):
            detail_parts.append("Donor domains: " + ", ".join(str(x) for x in d["donor_domains"]))
        amb = d.get("ambition")
        if amb is not None:
            detail_parts.append(f"AmbitionScore: {amb}")
        if d.get("first_experiment"):
            detail_parts.append(f"First experiment: {d['first_experiment']}")
        detail = cell(" · ".join(detail_parts))
        body_lines.append(
            f"| {cell(sev)} | {loc} | {agent} | DEFERRED | {summary} | {detail} |"
        )
    body = "\n".join(body_lines) + "\n"

    # The envelope helper writes to a file handle; emulate that into a string
    # buffer so the CLI can either print to stdout or write to a file uniformly.
    import io
    buf = io.StringIO()
    envelope(buf, "uberthink-aggregate", body)
    return buf.getvalue()


# ---- CLI ------------------------------------------------------------------


def _load_ranked_yaml(run_dir: str) -> dict:
    """Load `$RUN_DIR/ranked.yaml` (spec §2.4 artifact handle convention).

    Fail-loud on malformed YAML — same posture as uberscan: a silently-empty
    aggregate would file zero issues and dump a blank dossier on the user.
    """
    path = os.path.join(run_dir, "ranked.yaml")
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except OSError as e:
        print(f"error: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    except yaml.YAMLError as e:
        print(f"error: malformed YAML in {path}: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(doc, dict):
        print(f"error: {path} must be a mapping at the top level", file=sys.stderr)
        sys.exit(2)
    return doc


def _write_yaml_doc(doc: dict, out_path: str) -> None:
    """Write a YAML artifact to `out_path` (parent dirs are the caller's job).

    OSError propagates: a shortlist that could not be persisted must fail the
    process, never leave the caller believing an empty frontier was written.
    """
    with open(out_path, "w") as fh:
        yaml.safe_dump(doc, fh, sort_keys=False)


def _emit_shortlist(args) -> int:
    """Wave-4 per-island deterministic Pareto cut -> island-K/shortlist.yaml."""
    if args.island is None or args.island < 1:
        print("error: --emit shortlist requires --island <K> (1-based)", file=sys.stderr)
        return 2
    island_dir = os.path.join(args.run_dir, f"island-{args.island}")
    comp_dir = args.composites_dir or os.path.join(island_dir, "composites")
    out_path = args.out or os.path.join(island_dir, "shortlist.yaml")

    designs, malformed = load_composite_designs(comp_dir)
    for m in malformed:
        print(f"warning: skipped malformed composite record — {m}", file=sys.stderr)
    shortlist = compute_shortlist(designs, args.top)
    _write_yaml_doc(
        {
            "island_index": args.island,
            "designs_considered": len(designs),
            "skipped_malformed": len(malformed),
            "shortlist": [
                {
                    "id": d["id"],
                    "title": d.get("title", ""),
                    "novelty": d["novelty"],
                    "feasibility": d["feasibility"],
                    "combination": d["combination"],
                    "impact": d["impact"],
                    "ambition": d.get("ambition", 0),
                    "composite_path": d["composite_path"],
                }
                for d in shortlist
            ],
        },
        out_path,
    )
    print(
        f"shortlist: island={args.island} considered={len(designs)} "
        f"selected={len(shortlist)} malformed={len(malformed)} out={out_path}"
    )
    return 0


def _emit_floor_survivors(args) -> int:
    """Wave-7 deterministic feasibility-floor pre-cut -> floor-survivors.yaml."""
    out_path = args.out or os.path.join(args.run_dir, "floor-survivors.yaml")
    designs, malformed = collect_wave7_designs(args.run_dir)
    for m in malformed:
        print(f"warning: skipped malformed Wave-7 record — {m}", file=sys.stderr)
    survivors = compute_floor_survivors(designs)
    _write_yaml_doc(
        {
            "designs_considered": len(designs),
            "skipped_malformed": len(malformed),
            "floor_survivors": survivors,
        },
        out_path,
    )
    print(
        f"floor-survivors: {len(survivors)}/{len(designs)} cleared the floor "
        f"malformed={len(malformed)} out={out_path}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", required=True,
                    help="Run directory holding ranked.yaml / island-*/ (spec §2.4).")
    ap.add_argument("--emit", choices=["dossier", "aggregate", "shortlist", "floor-survivors"],
                    required=True,
                    help="dossier = report.md per spec §6; aggregate = findings-to-issues "
                         "envelope; shortlist = Wave-4 per-island Pareto cut; "
                         "floor-survivors = Wave-7 feasibility-floor pre-cut.")
    ap.add_argument("--max-new", type=int, default=3,
                    help="Max rows in the aggregate (top N by AmbitionScore). Default 3.")
    ap.add_argument("--island", type=int, default=None,
                    help="1-based island index (required by --emit shortlist).")
    ap.add_argument("--composites-dir", default="",
                    help="Override the composites dir scanned by --emit shortlist.")
    ap.add_argument("--top", type=int, default=SHORTLIST_TOP_DEFAULT,
                    help=f"Max designs kept by --emit shortlist. Default {SHORTLIST_TOP_DEFAULT}.")
    ap.add_argument("--out", default="",
                    help="Write the artifact to this path instead of the mode default "
                         "(shortlist/floor-survivors only; dossier/aggregate always use stdout).")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.run_dir):
        print(f"error: --run-dir is not a directory: {args.run_dir}", file=sys.stderr)
        return 2

    # The deterministic cuts run BEFORE ranked.yaml exists — they must not be
    # gated on it. Exit 3 marks "input artifact missing/unreadable", which the
    # caller reports as a TOOLING halt, never as a non-convergence verdict.
    if args.emit in ("shortlist", "floor-survivors"):
        try:
            return _emit_shortlist(args) if args.emit == "shortlist" else _emit_floor_survivors(args)
        except ArtifactError as e:
            print(f"error: {e}", file=sys.stderr)
            return 3
        except OSError as e:
            print(f"error: cannot write the {args.emit} artifact: {e}", file=sys.stderr)
            return 3

    doc = _load_ranked_yaml(args.run_dir)
    raw_ranked = doc.get("ranked") or []
    culled = doc.get("culled") or []

    # Re-rank in case the YAML carries un-flagged designs (defensive — the Arbiter
    # writes already-ranked YAML but we keep ranking deterministic on read so the
    # dossier is reproducible from a saved YAML alone).
    ranked_designs = rank(raw_ranked) if raw_ranked else []

    run_meta = {
        "goal": doc.get("goal", ""),
        "run_id": doc.get("run_id", os.path.basename(os.path.normpath(args.run_dir))),
        "date": doc.get("date", ""),
        "islands": doc.get("islands", 1),
        "loop_backs": doc.get("loop_backs", 0),
        "frame": doc.get("frame") or {},
        "agents_dispatched": doc.get("agents_dispatched"),
        "circuit_breakers_tripped": doc.get("circuit_breakers_tripped") or [],
        "partial": bool(doc.get("partial", False)),
    }

    if args.emit == "dossier":
        sys.stdout.write(render_dossier(run_meta, ranked_designs, culled))
    else:
        sys.stdout.write(emit_f2i_aggregate(ranked_designs, args.max_new))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
