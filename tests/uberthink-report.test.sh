#!/usr/bin/env bash
# Unit tests for /uberthink scoring core (plugins/uberdev/skills/uberthink-pipeline/report.py).
# Mirrors the shape of tests/uberscan-report.test.sh — bash wrapper around a python3 heredoc
# that imports report.py and asserts the spec §3 scoring contract.
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

echo "== /uberthink report.py scoring contract (spec §3) =="

# === Scoring core: the 6 spec §3 asserts (signatures pinned by the test file) ===
PYTHONPATH="$PIPELINE_DIR" python3 - <<'PY'
import report

NOV_W  = {"prior_art_distance":.30,"cross_domain_reach":.25,"non_obviousness":.25,"mechanism_originality":.20}
FEAS_W = {"hard_constraint":.30,"survives_adversary":.25,"buildability":.20,"premortem_resilience":.15,"deployment_reality":.10}
COMB_W = {"cross_consistency":.40,"synergy":.35,"coverage":.25}
IMP_W  = {"transformative":.40,"generality":.30,"defensibility":.30}

# 1. weighted axis aggregation
assert abs(report.axis_score({"prior_art_distance":10,"cross_domain_reach":10,"non_obviousness":10,"mechanism_originality":10}, NOV_W) - 10.0) < 1e-9
assert abs(report.axis_score({"transformative":10,"generality":0,"defensibility":0}, IMP_W) - 4.0) < 1e-9

# 2. feasibility floor: axis<4 cut; any sub==0 cut even if axis>=4
assert report.feasibility_floor_fails(3.9, {"hard_constraint":4,"survives_adversary":4,"buildability":4,"premortem_resilience":4,"deployment_reality":3}) is True
assert report.feasibility_floor_fails(6.0, {"hard_constraint":0,"survives_adversary":10,"buildability":10,"premortem_resilience":10,"deployment_reality":10}) is True
assert report.feasibility_floor_fails(6.0, {"hard_constraint":5,"survives_adversary":6,"buildability":6,"premortem_resilience":7,"deployment_reality":6}) is False

# 3. 4-term AmbitionScore product form tanks on a near-zero axis; zero on any axis => 0
assert report.ambition_score(10,10,10,0.1) < report.ambition_score(6,6,6,6)
assert abs(report.ambition_score(0,5,5,5)) < 1e-9

# 4. 4-axis Pareto dominance (higher better on all axes)
designs = [
  {"id":"A","novelty":5,"feasibility":5,"combination":5,"impact":5},
  {"id":"B","novelty":6,"feasibility":6,"combination":6,"impact":6},  # dominates A
  {"id":"C","novelty":9,"feasibility":2,"combination":4,"impact":9},  # incomparable to B
]
assert {d["id"] for d in report.pareto_frontier(designs)} == {"B","C"}

# 5. moonshot frontier uses ONLY novelty×impact -> a high-N/high-I but low-feasibility design still surfaces
moon = {d["id"] for d in report.moonshot_frontier(designs)}
assert "C" in moon  # C dominates on (novelty,impact) even though feasibility is low

# 6. rank(): cuts floor failures, sorts by ambition desc, flags on_frontier + moonshot
ranked = report.rank([
  {"id":"X","novelty":9,"feasibility":3.5,"combination":8,"impact":9,"feas_subs":{"hard_constraint":3,"survives_adversary":4,"buildability":4,"premortem_resilience":3,"deployment_reality":4}},  # cut
  {"id":"Y","novelty":7,"feasibility":7,"combination":7,"impact":6,"feas_subs":{"hard_constraint":7,"survives_adversary":7,"buildability":7,"premortem_resilience":7,"deployment_reality":7}},
  {"id":"Z","novelty":9,"feasibility":6,"combination":9,"impact":9,"feas_subs":{"hard_constraint":6,"survives_adversary":6,"buildability":6,"premortem_resilience":6,"deployment_reality":6}},
])
ids = [d["id"] for d in ranked]
assert "X" not in ids and ids[0] == "Z"
assert all({"ambition","on_frontier","moonshot"} <= set(d) for d in ranked)
print("ALL REPORT TESTS PASS")
PY
SCORING_RC=$?
check "scoring contract: all 6 spec §3 asserts pass" "[ $SCORING_RC -eq 0 ]"

# === Negative-axis clamp (issue #277): a negative axis must NOT become a Python
# complex and crash the dossier sort. Before the fix, ambition_score() applied a
# fractional exponent (BETA/GAMMA/DELTA = 1.2/1.3/1.2) to a negative base, which
# returns a complex; round(complex) raises TypeError inside ambition_score(), and
# any complex that escaped made rank()'s sorted(key=ambition) raise
# "'<' not supported between instances of 'complex' and 'complex'", aborting the
# Wave-7 render. The fix clamps each axis with max(0.0, float(x)) BEFORE the power
# so a negative axis fails closed to 0 (worse than zero -> product 0 -> sortable). ===
PYTHONPATH="$PIPELINE_DIR" python3 - <<'PY'
import report

# (a) ambition_score must return a real float (never complex) for a negative on
#     EVERY axis — including feasibility/combination/impact whose exponents are
#     fractional (the bases that previously went complex).
for axis, args in {
    "novelty":     (-2.0, 5.0, 5.0, 5.0),
    "feasibility": (5.0, -2.0, 5.0, 5.0),
    "combination": (5.0, 5.0, -2.0, 5.0),
    "impact":      (5.0, 5.0, 5.0, -2.0),
    "all":         (-1.0, -1.0, -1.0, -1.0),
}.items():
    v = report.ambition_score(*args)
    assert isinstance(v, float) and not isinstance(v, complex), \
        f"negative {axis}: ambition_score returned non-float {v!r} ({type(v).__name__})"
    # Clamp-to-zero on a negative axis means the product collapses to 0 (fail-closed).
    assert v == 0.0, f"negative {axis}: expected clamped 0.0, got {v!r}"

# (b) Positive/zero inputs are unchanged — the clamp is a no-op above zero, so the
#     existing scoring contract still holds (regression guard for the fix itself).
assert abs(report.ambition_score(6, 6, 6, 6)
           - round(6.0**1.0 * 6.0**1.2 * 6.0**1.3 * 6.0**1.2, 6)) < 1e-9
assert report.ambition_score(0, 5, 5, 5) == 0.0

# (c) rank() must NOT raise on a ranked.yaml carrying a negative axis that survives
#     the feasibility floor (feas >= 4.0, every feas_sub > 0). A negative COMBINATION
#     used to make ambition complex and crash the sort; now the design ranks last.
designs = [
    {"id": "NEG_COMB", "novelty": 7, "feasibility": 6, "combination": -3, "impact": 6,
     "feas_subs": {"hard_constraint": 6, "survives_adversary": 6, "buildability": 6,
                   "premortem_resilience": 6, "deployment_reality": 6}},
    {"id": "NEG_IMP", "novelty": 7, "feasibility": 6, "combination": 6, "impact": -3,
     "feas_subs": {"hard_constraint": 6, "survives_adversary": 6, "buildability": 6,
                   "premortem_resilience": 6, "deployment_reality": 6}},
    {"id": "OK", "novelty": 7, "feasibility": 7, "combination": 7, "impact": 7,
     "feas_subs": {"hard_constraint": 7, "survives_adversary": 7, "buildability": 7,
                   "premortem_resilience": 7, "deployment_reality": 7}},
]
ranked = report.rank(designs)   # must not raise TypeError
ids = [d["id"] for d in ranked]
assert ids[0] == "OK", f"positive design must rank first, got {ids}"
assert all(isinstance(d["ambition"], float) for d in ranked), \
    "every ranked design must carry a real-float ambition"
print("NEGATIVE-AXIS CLAMP OK")
PY
CLAMP_RC=$?
check "negative axis clamps to a real float (no complex -> no dossier sort crash) [#277]" "[ $CLAMP_RC -eq 0 ]"

# === CLI smoke: --emit dossier writes the spec §6 layout (moonshot lane FIRST) ===
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Stage the shared fixture as $RUN_DIR/ranked.yaml so the CLI loads it via the
# same path the real pipeline uses (.uberdev/think/<RUN_ID>/ranked.yaml).
cp "$PIPELINE_DIR/_fixtures/ranked-smoke.yaml" "$TMP/ranked.yaml"
python3 "$PIPELINE_DIR/report.py" --run-dir "$TMP" --emit dossier > "$TMP/report.md"
check "CLI: dossier written" "[ -s \"$TMP/report.md\" ]"
check "CLI: dossier H1 carries goal text" "grep -q '# /uberthink' \"$TMP/report.md\""
check "CLI: dossier surfaces Moonshot lane section" "grep -q 'Moonshot lane' \"$TMP/report.md\""
# Spec §6: moonshot lane MUST appear before the Ranked approaches section.
# Use awk to compute line numbers safely (empty file => 0 => fails the < check).
MOON_LN=$(awk '/Moonshot lane/{print NR; exit}' "$TMP/report.md")
RANK_LN=$(awk '/Ranked approaches/{print NR; exit}' "$TMP/report.md")
check "CLI: Moonshot lane appears BEFORE Ranked approaches (spec §6 order)" \
  "[ -n \"$MOON_LN\" ] && [ -n \"$RANK_LN\" ] && [ \"$MOON_LN\" -lt \"$RANK_LN\" ]"
check "CLI: Ranked approaches section present" "grep -q 'Ranked approaches' \"$TMP/report.md\""
check "CLI: Culled appendix present" "grep -q 'Culled' \"$TMP/report.md\""
check "CLI: top design appears in ranked section" "grep -q 'Stat-mech-shaped multipath' \"$TMP/report.md\""

# === CLI smoke: --emit aggregate writes the uberthink-aggregate envelope ===
python3 "$PIPELINE_DIR/report.py" --run-dir "$TMP" --emit aggregate --max-new 3 > "$TMP/agg.md"
check "CLI: aggregate written" "[ -s \"$TMP/agg.md\" ]"
check "CLI: aggregate has uberthink-aggregate envelope (leading 128 bytes)" \
  "grep -q 'source=\"uberthink-aggregate\"' <<<\"\$(head -c 128 \"$TMP/agg.md\")\""
check "CLI: aggregate has closing envelope tag" \
  "grep -qF '</external-untrusted-input>' \"$TMP/agg.md\""
check "CLI: aggregate respects --max-new cap" \
  "[ \$(awk '/^\\|/ && !/^\\| *-+/{n++} END{print n}' \"$TMP/agg.md\") -le 4 ]"

# === Deterministic cuts: --emit shortlist / --emit floor-survivors ==========
# These two used to be inline `python3 - <<'PY'` heredocs inside the pipeline
# SKILL.md, each running with stderr discarded and the exit status swallowed. A
# module-load failure therefore wrote no shortlist, the falsifier count fell to
# 0, CB-CONVERGE fired, and a ~90-minute run reported "the goal as framed
# admitted no feasible novel approach" — a tooling crash rendered as the verdict.
#
# The contract asserted here is the CRASH vs EMPTY discriminator:
#   exit 0 + empty result  = the frontier was honestly empty
#   exit 3                 = an input artifact was missing/unreadable
# They must never collapse into each other.
CUT="$TMP/cut"
mkdir -p "$CUT/island-1/composites" "$CUT/island-1/falsify" "$CUT/island-2" "$CUT/composites"

# Island 1: B dominates A on all four axes; C is incomparable to B.
cat > "$CUT/island-1/composites/comp-001-weave.yaml" <<'YAML'
composites:
  - id: A
    title: dominated design
    prelim_subscores: {novelty: 5, feasibility: 5, combination: 5, impact: 5}
  - id: B
    title: dominating design
    prelim_subscores: {novelty: 6, feasibility: 6, combination: 6, impact: 6}
YAML
cat > "$CUT/island-1/composites/comp-002-crossover.yaml" <<'YAML'
composites:
  - id: C
    title: audacious but fragile
    prelim_subscores: {novelty: 9, feasibility: 2, combination: 4, impact: 9}
YAML

python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit shortlist --island 1 \
  > "$TMP/shortlist.out" 2>"$TMP/shortlist.err"
SHORTLIST_RC=$?
check "shortlist: exits 0 on a healthy island" "[ $SHORTLIST_RC -eq 0 ]"
check "shortlist: writes island-1/shortlist.yaml" "[ -s \"$CUT/island-1/shortlist.yaml\" ]"
check "shortlist: keeps the Pareto frontier (B and C)" \
  "grep -q 'id: B' \"$CUT/island-1/shortlist.yaml\" && grep -q 'id: C' \"$CUT/island-1/shortlist.yaml\""
check "shortlist: drops the dominated design (A)" \
  "! grep -qE '^ *-? *id: A$' \"$CUT/island-1/shortlist.yaml\""
check "shortlist: rows carry composite_path back to the source artifact" \
  "grep -q 'composite_path:' \"$CUT/island-1/shortlist.yaml\""
check "shortlist: --top caps the selection" \
  "python3 \"$PIPELINE_DIR/report.py\" --run-dir \"$CUT\" --emit shortlist --island 1 --top 1 \
     --out \"$TMP/top1.yaml\" >/dev/null 2>&1 && [ \$(grep -cE '^ *-? *id: ' \"$TMP/top1.yaml\") -eq 1 ]"

# CRASH: island 2 has no composites/ directory at all.
python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit shortlist --island 2 \
  > "$TMP/missing.out" 2>"$TMP/missing.err"
MISSING_RC=$?
check "shortlist: a MISSING composites dir exits 3 (crash, not an empty frontier)" "[ $MISSING_RC -eq 3 ]"
check "shortlist: the missing-input failure names the directory on stderr" \
  "grep -q 'composites directory missing' \"$TMP/missing.err\""
check "shortlist: a crashed cut writes NO shortlist artifact" "[ ! -e \"$CUT/island-2/shortlist.yaml\" ]"

# ZERO-ARTIFACT: the directory EXISTS and holds no composite file. That is NOT an
# honestly-empty frontier — the pipeline preflight `mkdir -p`s island-K/composites
# eagerly, so the directory's existence carries no information at all. An empty
# input set means the Wave-3 combine wave wrote nothing (every synthesizer
# returned null / crashed), and reporting it at rc 0 produced an empty shortlist
# that the caller read as non-convergence and rendered as "the goal as framed
# admitted no feasible novel approach" — defect 2 in a different hat.
mkdir -p "$CUT/island-2/composites"
python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit shortlist --island 2 \
  > "$TMP/empty.out" 2>"$TMP/empty.err"
EMPTY_RC=$?
check "shortlist: a composites dir with ZERO comp-*.yaml exits 3 (crash, not an empty frontier)" \
  "[ $EMPTY_RC -eq 3 ]"
check "shortlist: the zero-artifact failure names the empty input on stderr" \
  "grep -q 'no composite artifacts' \"$TMP/empty.err\""
check "shortlist: the zero-artifact case writes NO shortlist artifact" \
  "[ ! -e \"$CUT/island-2/shortlist.yaml\" ]"

# A composites dir holding only unparseable files is a crash, not an empty frontier.
mkdir -p "$CUT/island-3/composites"
printf 'composites: [\n  - id: unterminated\n' > "$CUT/island-3/composites/comp-001-weave.yaml"
python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit shortlist --island 3 \
  > "$TMP/bad.out" 2>"$TMP/bad.err"
BAD_RC=$?
check "shortlist: composites that ALL fail to parse exit 3 (not a silent empty cut)" "[ $BAD_RC -eq 3 ]"

# --emit floor-survivors: the physics falsifier's hard_constraint=0 must cut a
# design whose feasibility axis alone would have cleared the floor.
cat > "$CUT/composites/global-001-crossover.yaml" <<'YAML'
composites:
  - id: SURVIVOR
    prelim_subscores: {novelty: 7, feasibility: 7, combination: 7, impact: 7}
  - id: LOWFEAS
    prelim_subscores: {novelty: 9, feasibility: 2, combination: 8, impact: 9}
YAML
cat > "$CUT/island-1/composites/comp-003-mutate.yaml" <<'YAML'
composites:
  - id: ZEROSUB
    prelim_subscores: {novelty: 8, feasibility: 8, combination: 8, impact: 8}
YAML
cat > "$CUT/island-1/falsify/comp-003-mutate-physics.yaml" <<'YAML'
composite_id: ZEROSUB
feasibility_sub_scores:
  hard_constraint: 0
  survives_adversary: 7
  buildability: 7
  premortem_resilience: 7
  deployment_reality: 7
YAML
python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit floor-survivors \
  > "$TMP/floor.out" 2>"$TMP/floor.err"
FLOOR_RC=$?
check "floor-survivors: exits 0" "[ $FLOOR_RC -eq 0 ]"
check "floor-survivors: writes floor-survivors.yaml" "[ -s \"$CUT/floor-survivors.yaml\" ]"
check "floor-survivors: keeps a design that clears the floor" \
  "grep -q 'SURVIVOR' \"$CUT/floor-survivors.yaml\""
check "floor-survivors: cuts a design whose feasibility axis is below 4" \
  "! grep -q 'LOWFEAS' \"$CUT/floor-survivors.yaml\""
check "floor-survivors: cuts a design whose physics hard_constraint sub-score is 0" \
  "! grep -q 'ZEROSUB' \"$CUT/floor-survivors.yaml\""

# CRASH: a run dir with neither global composites nor island shortlists.
mkdir -p "$TMP/barren"
python3 "$PIPELINE_DIR/report.py" --run-dir "$TMP/barren" --emit floor-survivors \
  > "$TMP/barren.out" 2>"$TMP/barren.err"
BARREN_RC=$?
check "floor-survivors: a run with no rankable artifact at all exits 3" "[ $BARREN_RC -eq 3 ]"
check "floor-survivors: a crashed cut writes NO floor-survivors artifact" \
  "[ ! -e \"$TMP/barren/floor-survivors.yaml\" ]"

# CRASH: the sources EXIST but none of them yields a rankable design. Same
# crash-vs-empty discriminator one wave later — "0/0 cleared the floor" is not a
# negative result about the goal, it means the floor cut ran on nothing.
mkdir -p "$TMP/hollow/island-1"
printf 'shortlist: []\n' > "$TMP/hollow/island-1/shortlist.yaml"
python3 "$PIPELINE_DIR/report.py" --run-dir "$TMP/hollow" --emit floor-survivors \
  > "$TMP/hollow.out" 2>"$TMP/hollow.err"
HOLLOW_RC=$?
check "floor-survivors: sources present but ZERO rankable designs exits 3" "[ $HOLLOW_RC -eq 3 ]"
check "floor-survivors: the hollow-input failure writes NO artifact" \
  "[ ! -e \"$TMP/hollow/floor-survivors.yaml\" ]"

# --emit shortlist without --island is a usage error, not a silent no-op.
python3 "$PIPELINE_DIR/report.py" --run-dir "$CUT" --emit shortlist >/dev/null 2>&1
NOISLAND_RC=$?
check "shortlist: omitting --island is a usage error (exit 2)" "[ $NOISLAND_RC -eq 2 ]"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
