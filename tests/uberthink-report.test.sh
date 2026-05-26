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
  "head -c 128 \"$TMP/agg.md\" | grep -q 'source=\"uberthink-aggregate\"'"
check "CLI: aggregate has closing envelope tag" \
  "grep -qF '</external-untrusted-input>' \"$TMP/agg.md\""
check "CLI: aggregate respects --max-new cap" \
  "[ \$(awk '/^\\|/ && !/^\\| *-+/{n++} END{print n}' \"$TMP/agg.md\") -le 4 ]"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
