#!/usr/bin/env bash
# Tests for /uberdev:review-pr Phase 3 (CI Health). Two layers:
#
#   STRUCTURAL (S1-S14): aggressive grep/regex checks that lock every Phase 3
#     contract surface in the prose (commands/review-pr.md + agent files). The
#     plugin "runtime" is the LLM reading that prose, so these assert that the
#     load-bearing tokens, audit-event names, and dispatch shapes are present.
#
#   RUNTIME (S15): exercises the Phase-3 6c.1 PROBE bucket-classification
#     contract for real. It prepends tests/_fixtures/fake-gh to PATH, sets
#     FAKE_GH_MODE per scenario, runs
#     `gh pr checks ... --json name,state,bucket,link,event,workflow`
#     exactly as review-pr.md specifies, then applies the *prose's own* jq
#     verdict expression (extracted live from review-pr.md, so the test can
#     never drift from the documented logic) and asserts the resulting verdict.
#     It also locks the gh >= 2.83.1 field contract: probe output carries
#     name/state/bucket and NEVER the removed status/conclusion fields.
#
# The fake `gh` is required because the real one is unavailable in CI sandboxes
# (and we never make network calls in unit tests).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
CLASSIFIER="$REPO_ROOT/plugins/uberdev/agents/ci-failure-classifier.md"
CODE_FIXER_CI="$REPO_ROOT/plugins/uberdev/agents/ci-code-fixer.md"
REBASE_HANDLER="$REPO_ROOT/plugins/uberdev/agents/ci-rebase-handler.md"
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
RUN_TREE="$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
CONTRACT_PY="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"
# The three further surfaces that restate the CONFLICT arm's enumeration claim.
# S13.23 sweeps all five together — the claim was wrong in ten places at once
# (#398), which is what makes a per-file sweep worth more than one grep.
REVIEW_FLEET_SKILL="$REPO_ROOT/plugins/uberdev/skills/review-fleet/SKILL.md"
REVIEW_FLEET_WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/review-fleet/workflow.js"
REVIEW_FLEET_ARGS="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
# The Phase 3 wiring rows (S21-S31) address those same two files under their own
# names. Alias, never re-derive: one relocation must not leave half the suite
# pointing at a stale path while the other half still resolves.
WORKFLOW_JS="$REVIEW_FLEET_WORKFLOW"
ARGS_LIB_PHASE3="$REVIEW_FLEET_ARGS"

for f in "$REVIEW_PR" "$CLASSIFIER" "$CODE_FIXER_CI" "$REBASE_HANDLER" "$MERGE_SKILL" "$RUN_TREE" \
         "$CONTRACT_PY" "$REVIEW_FLEET_SKILL" "$REVIEW_FLEET_WORKFLOW" "$REVIEW_FLEET_ARGS"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

# Local assert_grep — matches the shape used by tests/review-pr.test.sh.
# The shared helpers in _lib_assert_structural.sh do not include assert_grep
# or assert_no_grep, so we define them here verbatim from the plan.
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

# Structural-assertion helpers (assert_count / assert_subagent_type / assert_in_section)
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

echo "== S1: green-skip fast path — skipped_no_checks → trust signal emitted =="
assert_grep "$REVIEW_PR" 'skipped_no_checks' \
  "S1.1 — skipped_no_checks outcome documented in Phase 3"
assert_grep "$REVIEW_PR" 'no checks reported on the' \
  "S1.2 — gh stderr 'no checks reported on the' empty-array case handled"
assert_grep "$REVIEW_PR" 'Phase 3 outcome.*skipped_no_checks|skipped_no_checks.*green predicate' \
  "S1.3 — skipped_no_checks counts toward GREEN predicate"

echo
echo "== S2: pending → green via MONITOR (no fixer dispatched) =="
assert_grep "$REVIEW_PR" 'gh pr checks.*--watch.*--interval 30' \
  "S2.1 — MONITOR uses --watch --interval 30"
assert_grep "$REVIEW_PR" \
  'CI_MONITOR_DEADLINE_SEC="\$\{CI_MONITOR_DEADLINE_SEC:-\$\(\( CI_MONITOR_STARTED_SEC \+ 1200 \)\)\}"' \
  "S2.2 — the 1200s (20-minute) budget is an absolute deadline, defaulted once"
# S2.2b/S2.2c — #302: the watch MUST NOT be one 1200s call. The Bash harness
# caps a single call at 600000 ms, so `timeout 1200 gh pr checks --watch` is
# killed by the harness (not by `timeout`) with a code that is neither 0 nor
# gh's documented 8 — which the old "non-zero non-8 ⇒ red" mapping turned into
# a fabricated CLASSIFY dispatch on CI that never failed.
assert_no_grep "$REVIEW_PR" \
  '^[[:space:]]*timeout 1200 gh pr checks' \
  "S2.2b — the single unbounded 1200s watch call is retired"
assert_grep "$REVIEW_PR" \
  'CI_MONITOR_PASS_SEC=[0-9]+' \
  "S2.2c — each watch pass is bounded by the /review-pr-owned CI_MONITOR_PASS_SEC"
assert_grep "$REVIEW_PR" \
  'timeout "\$CI_MONITOR_WINDOW_SEC" gh pr checks "\$PR_NUMBER" --watch --interval 30' \
  "S2.2d — each pass runs the watch under the fence-clamped CI_MONITOR_WINDOW_SEC"
# S2.2e (#302, second half) — bounding each `timeout` is NOT enough: a loop that
# accumulates 1200s of passes still spends them inside ONE harness call, so the
# harness still kills the fence on exactly the slow CI the fix targets, taking
# the fence-scoped verdict with it. The per-FENCE budget (plus one worst-case
# minimum-progress sleep) must therefore fit strictly under the 600s ceiling,
# and the total must travel across fences as a carried deadline. Assert the
# arithmetic, not just the presence of the names.
CI_MONITOR_PASS_CONST="$(head -n 1 <<<"$(grep -oE '^ *CI_MONITOR_PASS_SEC=[0-9]+' "$REVIEW_PR")" | cut -d= -f2)"
CI_MONITOR_FENCE_CONST="$(head -n 1 <<<"$(grep -oE '^ *CI_MONITOR_FENCE_SEC=[0-9]+' "$REVIEW_PR")" | cut -d= -f2)"
CI_MONITOR_MIN_CONST="$(head -n 1 <<<"$(grep -oE '^ *CI_MONITOR_MIN_PASS_SEC=[0-9]+' "$REVIEW_PR")" | cut -d= -f2)"
if [ -n "$CI_MONITOR_PASS_CONST" ] && [ -n "$CI_MONITOR_FENCE_CONST" ] && \
   [ -n "$CI_MONITOR_MIN_CONST" ] && \
   [ "$((CI_MONITOR_FENCE_CONST + CI_MONITOR_MIN_CONST))" -lt 600 ] && \
   [ "$CI_MONITOR_PASS_CONST" -le "$CI_MONITOR_FENCE_CONST" ]; then
  echo "  PASS  S2.2e — per-fence budget (${CI_MONITOR_FENCE_CONST}s + ${CI_MONITOR_MIN_CONST}s floor) stays under the 600s harness call ceiling"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S2.2e — per-fence MONITOR budget can exceed the 600s harness call ceiling"
  echo "        pass=${CI_MONITOR_PASS_CONST:-none} fence=${CI_MONITOR_FENCE_CONST:-none} min=${CI_MONITOR_MIN_CONST:-none}"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REVIEW_PR" \
  'CI_MONITOR_PASSES_USED="\$\{CI_MONITOR_PASSES_USED:-0\}"' \
  "S2.2f — the pass count is carried across fences, not reset per harness call"
assert_grep "$REVIEW_PR" \
  're-run this fence with CI_MONITOR_DEADLINE_SEC=\$CI_MONITOR_DEADLINE_SEC CI_MONITOR_PASSES_USED=\$CI_MONITOR_PASSES_USED' \
  "S2.2g — the resume path prints the cross-fence carry the orchestrator must rebind"
assert_grep "$REVIEW_PR" 'in_progress|pending' \
  "S2.3 — pending state surfaces from PROBE for MONITOR transition"

echo
echo "== S2-RUNTIME: bounded MONITOR passes never launder a truncated watch into red (#302) =="
# Slice the MONITOR loop out of review-pr.md itself and drive it with a scripted
# per-pass plan ("<elapsed>:<rc> ..."), a fake clock, and a `timeout` stub, so the
# contract under test is the documented one — not a re-implementation — and the
# suite never sleeps or touches the network.
CI_MONITOR_FIXTURE="$(mktemp)"
awk '
  /# BEGIN ci-monitor-bounded-loop-v1/ { active=1; next }
  /# END ci-monitor-bounded-loop-v1/ { exit }
  active { sub(/^    /, ""); print }
' "$REVIEW_PR" >"$CI_MONITOR_FIXTURE"
if [ -s "$CI_MONITOR_FIXTURE" ]; then
  echo "  PASS  S2-RT.0 — sliced the ci-monitor-bounded-loop-v1 region out of review-pr.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S2-RT.0 — could not slice ci-monitor-bounded-loop-v1 out of review-pr.md (markers renamed?)"
  FAIL=$((FAIL + 1))
fi

run_ci_monitor_case() {
  local name="$1" plan="$2" want="$3" want_audit="$4"
  # Optional cross-fence carry — exactly what the orchestrator rebinds when the
  # previous fence returned `resume`.
  local carry_deadline="${5:-}" carry_passes="${6:-}"
  local log got audit_line
  log="$(mktemp)"
  got="$(
    CI_MONITOR_PLAN="$plan" CI_MONITOR_LOG="$log" \
    CI_MONITOR_CARRY_DEADLINE="$carry_deadline" CI_MONITOR_CARRY_PASSES="$carry_passes" \
    bash -c '
      # `set -e`, not just `set -u`: the command fences run under it, so a
      # short-circuit like `[ x ] && continue` (rc 1 when the test is false)
      # would abort the whole MONITOR fence in production. Lock that here.
      set -eu
      audit(){ printf "%s\n" "$*" >>"$CI_MONITOR_LOG"; }
      OUTCOME=unset
      PR_NUMBER=73
      FAKE_NOW=0
      # `date +%s` is the loop'"'"'s only clock — drive it from the plan.
      date(){ printf "%s\n" "$FAKE_NOW"; }
      # The minimum-progress floor must ADVANCE the budget, not just idle: stub
      # `sleep` onto the same fake clock so a zero-elapsed pass still costs wall
      # time here exactly as it does in production.
      sleep(){ FAKE_NOW=$((FAKE_NOW + $1)); }
      # shellcheck disable=SC2206
      PLAN_ITEMS=($CI_MONITOR_PLAN)
      PLAN_INDEX=0
      timeout(){
        local item="${PLAN_ITEMS[$PLAN_INDEX]:-}"
        [ -n "$item" ] || { printf "monitor plan exhausted\n" >&2; exit 90; }
        PLAN_INDEX=$((PLAN_INDEX + 1))
        FAKE_NOW=$((FAKE_NOW + ${item%%:*}))
        return "${item##*:}"
      }
      [ -z "$CI_MONITOR_CARRY_DEADLINE" ] || CI_MONITOR_DEADLINE_SEC="$CI_MONITOR_CARRY_DEADLINE"
      [ -z "$CI_MONITOR_CARRY_PASSES" ] || CI_MONITOR_PASSES_USED="$CI_MONITOR_CARRY_PASSES"
      . "$1"
      printf "%s %s %s %s\n" "$CI_MONITOR_VERDICT" "$OUTCOME" \
        "$CI_MONITOR_PASSES_USED" "$CI_MONITOR_ELAPSED_SEC"
    ' _ "$CI_MONITOR_FIXTURE" 2>/dev/null
  )"
  audit_line="$(head -n 1 "$log" 2>/dev/null)"
  if [ "$got" = "$want" ] && [ "$audit_line" = "$want_audit" ]; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    echo "        plan:          $plan"
    echo "        want state:    $want   (verdict outcome passes elapsed)"
    echo "        got  state:    $got"
    echo "        want audit:    $want_audit"
    echo "        got  audit:    $audit_line"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$log"
}

if [ -s "$CI_MONITOR_FIXTURE" ]; then
  # THE #302 regression: pass 1 burns its FULL window and comes back with a code
  # that is neither 0 nor 8 (a harness kill reports its own code, not 124). That
  # is a truncated watch, not a failed check — it must NOT reach CLASSIFY.
  run_ci_monitor_case \
    "S2-RT.1 — full-window non-8 truncation is pending, next pass sees the green" \
    "240:137 45:0" "green green 2 285" "ci_monitor_green passes=2 elapsed_sec=285"
  run_ci_monitor_case \
    "S2-RT.2 — timeout's own 124 is pending, never red" \
    "240:124 60:0" "green green 2 300" "ci_monitor_green passes=2 elapsed_sec=300"
  run_ci_monitor_case \
    "S2-RT.3 — gh's documented 8 (checks pending) continues to the next pass" \
    "240:8 20:0" "green green 2 260" "ci_monitor_green passes=2 elapsed_sec=260"
  # Only an EARLY non-zero non-8 is gh reporting a genuinely failed check.
  run_ci_monitor_case \
    "S2-RT.4 — early non-zero non-8 is red and proceeds to CLASSIFY" \
    "12:1" "red unset 1 12" "ci_monitor_red passes=1 elapsed_sec=12 rc=1"
  # S2-RT.5 (#302, second half) — the fence spends its OWN 480s share and hands
  # back. It must NOT halt (1200s of budget remain) and must NOT emit a terminal
  # audit event: nothing terminal happened. This is the state the old
  # single-fence loop could never express — it just kept watching until the
  # harness killed the call and took the verdict with it.
  run_ci_monitor_case \
    "S2-RT.5 — a spent fence budget resumes (no halt, no terminal audit)" \
    "240:8 240:8" "resume unset 2 480" ""
  # Only when the carried TOTAL deadline is reached does it become halted —
  # budget exhaustion stays its own outcome, never a fabricated red.
  run_ci_monitor_case \
    "S2-RT.6 — a resumed fence that exhausts the carried 1200s budget halts" \
    "240:8" "pending halted 5 1200" \
    "ci_monitor_timeout subreason=monitor_timeout passes=5 elapsed_sec=1200" \
    240 4
  run_ci_monitor_case \
    "S2-RT.7 — an immediately green first pass short-circuits the loop" \
    "40:0" "green green 1 40" "ci_monitor_green passes=1 elapsed_sec=40"
  # S2-RT.8 — the hot-loop guard. Every pass returns in 0s with gh's rc 8; with
  # no minimum-progress floor the loop would never advance its clock and would
  # hammer the API forever. The floor makes each pass cost CI_MONITOR_MIN_PASS_SEC,
  # so exactly 16 passes fill the 480s fence share and the plan is consumed
  # exactly. Remove the floor and the plan runs dry (rc 90) instead.
  run_ci_monitor_case \
    "S2-RT.8 — zero-elapsed passes cannot hot-loop: the min-progress floor advances the budget" \
    "0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8 0:8" \
    "resume unset 16 480" ""
  # S2-RT.9 — the clock-independent backstop: even with the whole budget left,
  # a carried pass count at CI_MONITOR_PASSES_MAX terminates immediately rather
  # than invoking the watch again.
  run_ci_monitor_case \
    "S2-RT.9 — CI_MONITOR_PASSES_MAX is a hard cap, enforced before any watch" \
    "" "pending halted 48 0" \
    "ci_monitor_timeout subreason=monitor_timeout passes=48 elapsed_sec=0" \
    1200 48
fi
rm -f "$CI_MONITOR_FIXTURE"

echo
echo "== S3: pending → red → ci-code-fixer → green (full happy path) =="
assert_subagent_type "$REVIEW_PR" 'ci-code-fixer' \
  "S3.1 — review-pr.md dispatches uberdev:ci-code-fixer (Phase 3 ROUTE)"
assert_grep "$REVIEW_PR" 'green_after_fix' \
  "S3.2 — green_after_fix outcome documented"
assert_grep "$REVIEW_PR" 're-enter Phase 1|re-enter at Step 4|post-fix.*re-enter' \
  "S3.3 — post-fix HEAD re-enters Phase 1 fanout (Q4 invariant)"

echo
echo "== S4: 6 classification paths — classifier dispatched + ROUTE picks correct downstream =="
assert_subagent_type "$REVIEW_PR" 'ci-failure-classifier' \
  "S4.1 — review-pr.md dispatches uberdev:ci-failure-classifier (Phase 3 CLASSIFY)"
for cls in code_bug billing_quota platform_outage flaky env_drift stale_base; do
  assert_grep "$REVIEW_PR" "$cls" \
    "S4.cls.$cls — failure class $cls named in ROUTE prose"
done
assert_subagent_type "$REVIEW_PR" 'ci-rebase-handler' \
  "S4.2 — review-pr.md dispatches uberdev:ci-rebase-handler (stale_base ROUTE)"
assert_grep "$REVIEW_PR" 'gh run rerun' \
  "S4.3 — flaky path uses gh run rerun"
assert_grep "$REVIEW_PR" 'RERUN_FLAKY_CAP' \
  "S4.4 — flaky cap referenced by name (RERUN_FLAKY_CAP)"

echo
echo "== S5: loop-cap exhaustion — 3 iterations → loop_cap_exhausted → exit 1 =="
assert_grep "$REVIEW_PR" 'CI_FIX_LOOP_CAP' \
  "S5.1 — loop cap referenced by name (CI_FIX_LOOP_CAP)"
assert_grep "$REVIEW_PR" 'loop_cap_exhausted' \
  "S5.2 — loop_cap_exhausted outcome documented"
assert_grep "$REVIEW_PR" 'MUST NOT introduce any additional retry path|no extra retry path' \
  "S5.3 — anti-pattern guard against additional retry paths restated"
assert_grep "$REVIEW_PR" 'distinct.*commit SHA|HEAD SHA changed|distinct fix-and-push' \
  "S5.4 — counter increments only on distinct commit SHA change"
# S5.5/S5.6 (#302) — the loop-counter prose used to contradict itself and the
# executable setup: one block said the orchestrator "decrements" the counter
# while two others said increments, and 6c.7 claimed it "starts at 0" while
# setup binds `${CI_FIX_LOOP_ITER:-1}`. A reader implementing from either wrong
# statement gets an off-by-one iteration budget or a counter that runs backwards
# into negative instance IDs.
assert_no_grep "$REVIEW_PR" 'decrements the loop counter' \
  "S5.5 — no prose claims the CI-fix loop counter is decremented"
assert_no_grep "$REVIEW_PR" 'CI_FIX_LOOP_ITER` starts at `0`' \
  "S5.6 — 6c.7 no longer claims CI_FIX_LOOP_ITER starts at 0"
assert_grep "$REVIEW_PR" 'CI_FIX_LOOP_ITER="\$\{CI_FIX_LOOP_ITER:-1\}"' \
  "S5.7 — executable setup binds the 1-based CI_FIX_LOOP_ITER default"
assert_grep "$REVIEW_PR" 'CI_FIX_LOOP_ITER` starts at `1`' \
  "S5.8 — 6c.7 prose matches the executable 1-based default"

echo
echo "== S6: --no-ci-fix probe-only — no fixer/rebase/halt dispatch =="
assert_grep "$REVIEW_PR" 'argument-hint:.*--no-ci-fix|--no-ci-fix.*argument-hint' \
  "S6.1 — --no-ci-fix declared in argument-hint frontmatter"
assert_grep "$REVIEW_PR" 'CI_FIX_PHASE' \
  "S6.2 — CI_FIX_PHASE variable documented (mirrors SIMPLIFY_PHASE)"
assert_grep "$REVIEW_PR" 'CI_FIX_PHASE=0|--no-ci-fix.*probe' \
  "S6.3 — --no-ci-fix sets CI_FIX_PHASE=0 / probe-only"
# #383: the mode is ENFORCED IN SHELL now. CI_FIX_PHASE previously had no reader
# anywhere in this file, so "probe/monitor/classify run, ROUTE/POST-FIX/HALT are
# skipped" was orchestrator prose that nothing could hold the command to.
assert_grep "$REVIEW_PR" 'if \[ "\$\{CI_FIX_PHASE:-1\}" = 0 \]' \
  "S6.4 — --no-ci-fix is enforced by a real shell guard at the head of ROUTE"
assert_grep "$REVIEW_PR" 'ci_probe_only_skipped' \
  "S6.5 — the probe-only skip emits its own audit event"
assert_no_grep "$REVIEW_PR" '\-\-no-ci-fix.*supported mode' \
  "S6.6 — the --no-ci-fix-is-the-supported-mode language is gone (#383)"
assert_no_grep "$REVIEW_PR" 'ci_transport_unsupported' \
  "S6.7 — the Phase 3 transport refusal no longer exists"

echo
echo "== S7: --turbo on halt classes — no AskUserQuestion, exit 1, no trust signal =="
assert_grep "$REVIEW_PR" '--turbo.*does NOT (alter|mutate|change).*Phase 1 or Phase 2|Phase 1 or Phase 2.*--turbo' \
  "S7.1 — --turbo prose narrowed to 'Phase 1 or Phase 2' only"
assert_grep "$REVIEW_PR" 'Phase 3 halt classes.*--turbo|--turbo.*halt classes' \
  "S7.2 — Phase 3 halt-class carve-out documented for --turbo"
assert_grep "$REVIEW_PR" 'billing_quota.*platform_outage|platform_outage.*billing_quota' \
  "S7.3 — both halt classes named together in --turbo carve-out"
# S7.4 — no `AskUserQuestion(` call site lives inside the Turbo (--turbo
# present) branch of 6c.6 HALT. The original assertion used a perl-style
# negative lookahead `(?!...)` which is not in ERE — it triggered
# `grep: warning: ? at start of expression` on GNU grep (Linux CI),
# causing a false fail (and falsely passing on macOS BSD grep).
# This awk walk tracks "Turbo" vs "Interactive" subsections in 6c.6 HALT
# and flags any AskUserQuestion( call inside the Turbo region — which
# would defeat the carve-out's "no prompt under --turbo" contract.
S7_4_VIOLATIONS="$(awk '
  /\*\*Turbo \(.--turbo. present\):\*\*/ { in_turbo=1; next }
  /\*\*Interactive \(.--turbo. absent\):\*\*/ { in_turbo=0; next }
  /^### / { in_turbo=0 }
  in_turbo && /AskUserQuestion\(/ { print FILENAME ":" NR ": " $0 }
' "$REVIEW_PR")"
if [ -z "$S7_4_VIOLATIONS" ]; then
  echo "  PASS  S7.4 — --turbo branch does NOT call AskUserQuestion()"; PASS=$((PASS + 1))
else
  echo "  FAIL  S7.4 — --turbo branch contains an AskUserQuestion() call"
  printf '%s\n' "$S7_4_VIOLATIONS" | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi

echo
echo "== S7.5 (#97): hybrid TURBO detector — env-var path documented =="
assert_grep "$REVIEW_PR" \
  'UBERDEV_TURBO' \
  "S7.5 — review-pr documents UBERDEV_TURBO env-var as hybrid OR with --turbo arg"

echo
echo "== S8: gh outage carve-out — ci_probe_unreachable + Step 7 still runs =="
assert_grep "$REVIEW_PR" 'ci_probe_unreachable' \
  "S8.1 — ci_probe_unreachable audit event documented"
assert_grep "$REVIEW_PR" 'phases\.phase3.*omitted|omitted entirely.*gh.*unreachable|carve-out' \
  "S8.2 — phase3 audit JSON omitted on gh-unreachable carve-out"
assert_grep "$REVIEW_PR" 'rate_limit_low|gh api rate_limit' \
  "S8.3 — pre-flight rate-limit check documented (rate_limit_low subreason)"

echo
echo "== S9: 12 new AUDIT_EVENT_ENUM members all referenced in Phase 3 prose =="
for ev in ci_probe_started ci_probe_skipped_no_checks ci_probe_unreachable \
          ci_monitor_green ci_monitor_red ci_monitor_timeout \
          ci_classify_dispatched ci_classify_returned \
          ci_fix_dispatched ci_fix_pushed \
          ci_loop_cap_reached ci_phase_outcome; do
  assert_grep "$REVIEW_PR" "$ev" \
    "S9.$ev — Phase 3 prose references audit event $ev"
done

echo
echo "== S10: ci-failure-classifier agent shape =="
assert_grep "$CLASSIFIER" '^name: ci-failure-classifier$' \
  "S10.1 — frontmatter name"
assert_grep "$CLASSIFIER" '^model: inherit$' \
  "S10.2 — frontmatter model: inherit"
assert_grep "$CLASSIFIER" 'signal_anchor' \
  "S10.3 — return contract emits signal_anchor"
assert_no_grep "$CLASSIFIER" '^.*data\.quote' \
  "S10.4 — no data.quote field in return contract (secret-leak guard)"
assert_grep "$CLASSIFIER" 'CLASSIFIED.*AMBIGUOUS.*REFUSED|status: CLASSIFIED' \
  "S10.5 — refusal triggers + AMBIGUOUS path documented"
assert_grep "$REVIEW_PR" 'validate-ci-classification' \
  "S10.6 — controller validates classifier output before routing"
assert_no_grep "$REVIEW_PR" 'review_validate_ci_classification' \
  "S10.6b — the classifier predicate is no longer an LLM-rendered heredoc in the command file (#383)"
assert_grep "$CONTRACT_PY" '_parse_ci_classification' \
  "S10.6c — the classifier predicate lives in lib/code_fixer_contract.py, where it is testable"
assert_grep "$REVIEW_PR" 'ci_classify_returned.*contract_invalid' \
  "S10.7 — invalid class/anchor fails closed with an audit event"
assert_grep "$CONTRACT_PY" 'gh-run-\[1-9\]' \
  "S10.8 — blank and zero-line signal anchors are rejected (predicate now in the contract)"
assert_grep "$REVIEW_PR" 'CI_REFUSED_AGGREGATE_PATH.*RESEARCH_DIR_ABS/ci-refused-synthetic' \
  "S10.9 — CI refusal aggregate stays inside the run research directory"
assert_no_grep "$REVIEW_PR" 'tmp-synthetic-aggregate|freshly-created `mktemp`' \
  "S10.10 — CI refusal handoff no longer points at a system mktemp artifact"
assert_grep "$REVIEW_PR" 'capture-ci-terminal .*--edge-id review_pr\.ci\.classify|--edge-id review_pr\.ci\.classify' \
  "S10.10a — classifier evidence is frozen by capture-ci-terminal, which also re-pins the log bytes"
assert_grep "$REVIEW_PR" 'review_fleet_bind_ci review_pr\.ci\.classify ' \
  "S10.10a1 — the classify child is bound with the CI producer BEFORE the Workflow call"
assert_no_grep "$REVIEW_PR" 'review_child_single review_pr\.ci\.' \
  "S10.10a1b — no Phase 3 edge takes the routed adapter any more (#383)"
assert_grep "$REVIEW_PR" 'classifier_child_failed' \
  "S10.10a2 — classifier lifecycle failure is audited and halts routing"
assert_no_grep "$REVIEW_PR" 'CI_CLASSIFICATION_PATH="\$RESEARCH_DIR_ABS/ci-classification-' \
  "S10.10b — classifier validation does not read an artifact no child writes"
assert_grep "$REVIEW_PR" 'os\.write\(fd,payload\)' \
  "S10.10c — refusal aggregate serializes a concrete envelope and finding row"
assert_no_grep "$REVIEW_PR" 'review_pr\.ci\.classify.*log_path|log_path.*review_pr\.ci\.classify' \
  "S10.10d — classifier handoff carries no mutable log pathname"
assert_no_grep "$REVIEW_PR" 'CI_LOG_TRUNCATE_LINES|ci-log-run-|capture_path|capture_receipt|created_identity' \
  "S10.10d1 — classifier authority uses no named raw staging or producer receipt"
assert_grep "$REVIEW_PR" 'gh run view "\$CI_RUN_ID".*--log-failed' \
  "S10.10d2 — classifier authority streams only failed-job logs into its transformer"
assert_grep "$REVIEW_PR" 'review_pr\.ci\.classify.*log_content|log_content.*CI_LOG_AUTHORITY_JSON' \
  "S10.10e — classifier handoff carries the captured log bytes inline"
assert_grep "$REVIEW_PR" 'review_pr\.ci\.classify.*log_sha256|log_sha256.*CI_LOG_AUTHORITY_JSON' \
  "S10.10f — classifier handoff binds the exact captured log digest"
assert_grep "$REVIEW_PR" 'review_pr\.ci\.classify.*head_sha|head_sha.*CI_CLASSIFICATION_HEAD_SHA' \
  "S10.10g — classifier handoff binds the validated PR head"
assert_grep "$CLASSIFIER" 'log_sha256.*SHA-256|SHA-256.*log_sha256' \
  "S10.10h — classifier contract names the exact content digest"
if python3 -I -B - "$RUN_TREE" <<'PY'
import json,sys
required=json.load(open(sys.argv[1],encoding="utf-8"))["edges"]["review_pr.ci.classify"]["required_inputs"]
expected={
    "pr_number":"integer",
    "run_id":"string",
    "head_sha":"string",
    "log_content":"bounded_text",
    "log_sha256":"string",
}
if required!=expected or "log_path" in required:
    raise SystemExit("classifier authority is not closed over identity and bytes")
PY
then
  echo "  PASS  S10.10i — policy closes classifier authority over PR/run/head and bounded bytes"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S10.10i — policy closes classifier authority over PR/run/head and bounded bytes"
  FAIL=$((FAIL + 1))
fi

# RE-POINTED (#383). The lifecycle this asserts is unchanged -- a classifier
# child that does not produce provable evidence must audit
# `classifier_child_failed` with the real exit code and must block artifact
# discovery, routing and the fixer. Only the seam moved: the routed
# `review_child_single` dispatch became the ci-classify Workflow stage, and the
# lifecycle check is now the `capture-ci-terminal` return in the post-call
# fence. The fence is EXTRACTED AND RUN, not grepped.
CLASSIFY_LIFECYCLE_FIXTURE="$(mktemp)"
CLASSIFY_LIFECYCLE_LOG="$(mktemp)"
awk '
  /^[[:space:]]*CI_CLASSIFY_TERMINAL="\$\(python3/ { capture=1 }
  capture && /^[[:space:]]*CI_CLASSIFY_STATUS_SHA256=/ { exit }
  capture { sub(/^[[:space:]]{4}/,""); print }
' "$REVIEW_PR" >"$CLASSIFY_LIFECYCLE_FIXTURE"
cat >>"$CLASSIFY_LIFECYCLE_FIXTURE" <<'SH'
validate_classification() { printf 'validate\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
route_classifier() { printf 'routing\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
dispatch_fixer() { printf 'fixer\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
validate_classification
route_classifier
dispatch_fixer
SH
[ -s "$CLASSIFY_LIFECYCLE_FIXTURE" ] || {
  echo "  FAIL  S10.10a3 — the ci-classify capture fence could not be extracted"; FAIL=$((FAIL + 1))
}
set +e
CLASSIFY_LIFECYCLE_LOG="$CLASSIFY_LIFECYCLE_LOG" \
CODE_FIXER_CONTRACT=/nonexistent/contract.py \
CI_CLASSIFY_BINDING='{"backend":"workflow"}' \
bash -c '
  # Stand in for the real contract subprocess: a child whose evidence cannot be
  # captured exits 37, exactly as the real verb would exit non-zero.
  python3() { printf "child-capture\n" >>"$CLASSIFY_LIFECYCLE_LOG"; return 37; }
  audit() { printf "audit:%s:%s:%s\n" "$1" "$2" "$3" >>"$CLASSIFY_LIFECYCLE_LOG"; }
  . "$1"
' _ "$CLASSIFY_LIFECYCLE_FIXTURE"
CLASSIFY_LIFECYCLE_RC=$?
set +e
if [ "$CLASSIFY_LIFECYCLE_RC" -eq 1 ] \
    && grep -q '^child-capture$' "$CLASSIFY_LIFECYCLE_LOG" \
    && grep -q 'classifier_child_failed.*exit_code=37' "$CLASSIFY_LIFECYCLE_LOG" \
    && ! grep -Eq 'validate|routing|fixer' "$CLASSIFY_LIFECYCLE_LOG"; then
  echo "  PASS  S10.10a3 — classifier lifecycle failure records rc=37 and blocks discovery, routing, and fixer"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.10a3 — classifier lifecycle failure reached a downstream canary"; FAIL=$((FAIL + 1))
fi
rm -f "$CLASSIFY_LIFECYCLE_FIXTURE" "$CLASSIFY_LIFECYCLE_LOG"

CLASSIFY_HELPER="$(mktemp)"
CLASSIFY_CASE="$(mktemp)"
# RE-POINTED (#383). `review_validate_ci_classification` was a python heredoc
# inside commands/review-pr.md, which meant the predicate deciding whether a
# MUTATING fixer runs was LLM-rendered markdown with no test of its own. It now
# lives in lib/code_fixer_contract.py as `_parse_ci_classification`. The cases
# below are UNCHANGED and still run against real bytes -- only the callee moved,
# so no assertion is lost to the move. The tab-joined shim keeps the existing
# expectations byte-identical.
cat >"$CLASSIFY_HELPER" <<'SHIM'
review_validate_ci_classification() {
  python3 -I -B - "$1" "$2" "$2/plugins/uberdev/lib/code_fixer_contract.py" <<'PYSHIM'
import importlib.util, sys
case_path, root, contract = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("cfc_classify", contract)
module = importlib.util.module_from_spec(spec)
sys.modules["cfc_classify"] = module
spec.loader.exec_module(module)
payload = open(case_path, "rb").read()
# The shipped bound: validate_ci_classification captures the result through
# capture_expected(..., 1, CI_RESULT_LIMIT), so a document over the cap is
# refused before the parser ever sees it. Mirror that here or the byte-boundary
# case below would silently start passing on an oversized document.
if not payload or len(payload) > module.CI_CLASSIFICATION_RESULT_LIMIT:
    raise SystemExit(2)
try:
    parsed = module._parse_ci_classification(payload, root)
except module.ContractFailure as error:
    if str(error) == "ci_classification_refused":
        # The contract makes REFUSED terminal; the shell surface reported it as
        # a row. Re-derive the row from the same bytes so the historical
        # expectations keep exercising the same predicate.
        import re as _re
        body = _re.search(r"(?:^|\n)```yaml\r?\n(.*?)\r?\n```\r?\n?\Z",
                          payload.decode("utf-8"), _re.DOTALL).group(1)
        rationale = ""
        for line in body.splitlines():
            if line.startswith("rationale:"):
                rationale = module._ci_classifier_scalar(line.split(":", 1)[1].strip()) or ""
        print("REFUSED\t-\t-\t" + rationale)
        raise SystemExit(0)
    raise SystemExit(2)
if parsed["status"] == "AMBIGUOUS":
    print("AMBIGUOUS\tflaky\t-\t-")
else:
    print("CLASSIFIED\t" + parsed["failure_class"] + "\t" + parsed["signal_anchor"] + "\t-")
PYSHIM
}
SHIM
write_classifier_case() {
  local classifier_status="$1" failure_class="$2" signal_anchor="$3" rationale="$4"
  printf '```yaml\nstatus: %s\nfailure_class: %s\nsignal_anchor: %s\nrationale: %s\nrisks: []\n```\n' \
    "$classifier_status" "$failure_class" "$signal_anchor" "$rationale" > "$CLASSIFY_CASE"
}
write_classifier_case CLASSIFIED code_bug '"README.md:42"' '"repository test failure"'
CLASSIFY_SPLIT="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_SPLIT" = $'CLASSIFIED\tcode_bug\tREADME.md:42\t-' ]; then
  echo "  PASS  S10.11 — valid classifier output survives the controller read boundary"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11 — valid classifier output failed the controller read boundary: $CLASSIFY_SPLIT"; FAIL=$((FAIL + 1))
fi
printf 'bounded classifier explanation\n' > "$CLASSIFY_CASE"
printf '```yaml\nstatus: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrationale: "transient runner signal"\nrisks: []\n```\n' >> "$CLASSIFY_CASE"
CLASSIFY_WITH_PREFIX="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_WITH_PREFIX" = $'CLASSIFIED\tflaky\tgh-run-123:42\t-' ]; then
  echo "  PASS  S10.11a — controller extracts the contract-permitted final fenced document"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11a — controller rejected final fenced classifier output: $CLASSIFY_WITH_PREFIX"; FAIL=$((FAIL + 1))
fi
write_classifier_case REFUSED null null "'can''t reproduce runner failure'"
CLASSIFY_SINGLE_QUOTED="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_SINGLE_QUOTED" = $'REFUSED\t-\t-\tcan\'t reproduce runner failure' ]; then
  echo "  PASS  S10.11b — YAML doubled apostrophe decodes exactly in a single-quoted scalar"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11b — YAML single-quoted scalar was corrupted: $CLASSIFY_SINGLE_QUOTED"; FAIL=$((FAIL + 1))
fi
write_classifier_case CLASSIFIED code_bug "'tests/review-pr-phase3-ci.test.sh:42'" "'repository test failure'"
CLASSIFY_SINGLE_QUOTED_ANCHOR="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_SINGLE_QUOTED_ANCHOR" = $'CLASSIFIED\tcode_bug\ttests/review-pr-phase3-ci.test.sh:42\t-' ]; then
  echo "  PASS  S10.11b-anchor — YAML single-quoted signal anchor decodes exactly"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11b-anchor — YAML single-quoted signal anchor was corrupted: $CLASSIFY_SINGLE_QUOTED_ANCHOR"; FAIL=$((FAIL + 1))
fi
CLASSIFY_SINGLE_QUOTE_INVALID=0
for malformed_rationale in "'unterminated" "'can't reproduce runner failure'"; do
  write_classifier_case REFUSED null null "$malformed_rationale"
  if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
    CLASSIFY_SINGLE_QUOTE_INVALID=$((CLASSIFY_SINGLE_QUOTE_INVALID + 1))
  fi
done
if [ "$CLASSIFY_SINGLE_QUOTE_INVALID" -eq 0 ]; then
  echo "  PASS  S10.11c — unterminated and unpaired YAML single quotes fail closed"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11c — $CLASSIFY_SINGLE_QUOTE_INVALID malformed YAML single-quoted scalars were accepted"; FAIL=$((FAIL + 1))
fi
CLASSIFY_CONTROL_INVALID=0
for scalar_style in json single; do
  for control_code in 0 1 31 127; do
    python3 -I -B - "$CLASSIFY_CASE" "$scalar_style" "$control_code" <<'PY'
import json,pathlib,sys
path,style,code=sys.argv[1:]
value='bounded'+chr(int(code))+'rationale'
encoded=json.dumps(value) if style=='json' else "'"+value.replace("'","''")+"'"
pathlib.Path(path).write_text(
    '```yaml\nstatus: REFUSED\nfailure_class: null\nsignal_anchor: null\n'
    f'rationale: {encoded}\nrisks: []\n```\n', encoding='utf-8')
PY
    if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
      CLASSIFY_CONTROL_INVALID=$((CLASSIFY_CONTROL_INVALID + 1))
    fi
  done
done
if [ "$CLASSIFY_CONTROL_INVALID" -eq 0 ]; then
  echo "  PASS  S10.11d — decoded JSON and single-quoted C0/DEL controls fail closed"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11d — $CLASSIFY_CONTROL_INVALID decoded control scalars were accepted"; FAIL=$((FAIL + 1))
fi

python3 -I -B - "$CLASSIFY_CASE" 256 <<'PY'
import json,pathlib,sys
path,size=sys.argv[1],int(sys.argv[2])
pathlib.Path(path).write_text(
    '```yaml\nstatus: REFUSED\nfailure_class: null\nsignal_anchor: null\n'
    f'rationale: {json.dumps("x"*size)}\nrisks: []\n```\n', encoding='utf-8')
PY
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  echo "  PASS  S10.11e — exact 256-character scalar is accepted"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11e — exact 256-character scalar was rejected"; FAIL=$((FAIL + 1))
fi
python3 -I -B - "$CLASSIFY_CASE" 257 <<'PY'
import json,pathlib,sys
path,size=sys.argv[1],int(sys.argv[2])
pathlib.Path(path).write_text(
    '```yaml\nstatus: REFUSED\nfailure_class: null\nsignal_anchor: null\n'
    f'rationale: {json.dumps("x"*size)}\nrisks: []\n```\n', encoding='utf-8')
PY
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  echo "  FAIL  S10.11f — 257-character scalar was accepted"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S10.11f — 257-character scalar is rejected"; PASS=$((PASS + 1))
fi

CLASSIFY_DOCUMENT_INVALID=0
for document_size in 65536 65537; do
  python3 -I -B - "$CLASSIFY_CASE" "$document_size" <<'PY'
import pathlib,sys
path,size=sys.argv[1],int(sys.argv[2])
document=('```yaml\nstatus: REFUSED\nfailure_class: null\nsignal_anchor: null\n'
          'rationale: bounded\nrisks: []\n```\n')
prefix='x'*(size-len(document)-1)+'\n'
raw=(prefix+document).encode()
assert len(raw)==size
pathlib.Path(path).write_bytes(raw)
PY
  if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
    [ "$document_size" -eq 65536 ] || CLASSIFY_DOCUMENT_INVALID=$((CLASSIFY_DOCUMENT_INVALID + 1))
  else
    [ "$document_size" -eq 65537 ] || CLASSIFY_DOCUMENT_INVALID=$((CLASSIFY_DOCUMENT_INVALID + 1))
  fi
done
if [ "$CLASSIFY_DOCUMENT_INVALID" -eq 0 ]; then
  echo "  PASS  S10.11g — 65536-byte document is accepted and 65537 bytes is rejected"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11g — classifier document byte boundary drifted"; FAIL=$((FAIL + 1))
fi
CLASSIFY_INVALID=0
for invalid_anchor in ':121' 'file:0' '/absolute:1' '../README.md:1' 'missing.ts:1' ''; do
  write_classifier_case CLASSIFIED code_bug "\"$invalid_anchor\"" '"invalid anchor fixture"'
  if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
    CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
  fi
done
write_classifier_case CLASSIFIED code_bug '"gh-run-123:42"' '"invalid repository anchor fixture"'
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
fi
write_classifier_case CLASSIFIED unknown '"file.ts:12"' '"unknown class fixture"'
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
fi
write_classifier_case AMBIGUOUS null null '"no supported signal"'
CLASSIFY_AMBIGUOUS="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
write_classifier_case REFUSED null null '"input-malformed"'
CLASSIFY_REFUSED="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
write_classifier_case CLASSIFIED flaky '"gh-run-123:42"' '"transient runner signal"'
CLASSIFY_TELEMETRY="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_INVALID" -eq 0 ]; then
  echo "  PASS  S10.12 — blank, malformed, zero-line, and unknown classifier outputs fail closed"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.12 — $CLASSIFY_INVALID invalid classifier outputs were accepted"; FAIL=$((FAIL + 1))
fi
if [ "$CLASSIFY_AMBIGUOUS" = $'AMBIGUOUS\tflaky\t-\t-' ] \
    && [ "$CLASSIFY_REFUSED" = $'REFUSED\t-\t-\tinput-malformed' ] \
    && [ "$CLASSIFY_TELEMETRY" = $'CLASSIFIED\tflaky\tgh-run-123:42\t-' ]; then
  echo "  PASS  S10.13 — explicit ambiguous, refused, and telemetry-only variants preserve their invariants"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.13 — classifier union variants drifted: ambiguous=$CLASSIFY_AMBIGUOUS refused=$CLASSIFY_REFUSED telemetry=$CLASSIFY_TELEMETRY"; FAIL=$((FAIL + 1))
fi

CLASSIFY_STRICT_INVALID=0
for malformed_document in \
  $'```yaml\nstatus: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrisks: []\n```\n' \
  $'```yaml\nstatus: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrationale: "fixture"\n```\n' \
  $'```yaml\nstatus: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrationale: "fixture"\nrisks: []\nunknown: value\n```\n' \
  $'```yaml\nstatus: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrationale: "fixture"\nrisks: []\n```\ntrailing content\n' \
  $'```yaml\nstatus: CLASSIFIED\nstatus: AMBIGUOUS\nfailure_class: flaky\nsignal_anchor: "gh-run-123:42"\nrationale: "fixture"\nrisks: []\n```\n'; do
  printf '%s' "$malformed_document" > "$CLASSIFY_CASE"
  if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
    CLASSIFY_STRICT_INVALID=$((CLASSIFY_STRICT_INVALID + 1))
  fi
done
if [ "$CLASSIFY_STRICT_INVALID" -eq 0 ]; then
  echo "  PASS  S10.14 — classifier rejects incomplete, duplicate, unknown, and trailing out-of-fence content"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.14 — $CLASSIFY_STRICT_INVALID malformed classifier documents were accepted"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S10.14c — THE COMPARATOR. Two copies of the classifier predicate, one guard.
# ---------------------------------------------------------------------------
# #383 half one shipped `_parse_ci_classification` in
# plugins/uberdev/lib/code_fixer_contract.py as the tested form of the predicate
# the heredoc above carries — same fenced-document regex, same field regex, same
# scalar decoder, same class set, same anchor rules, written twice. That is the
# #370/#371 "one contract, N uncompared copies" shape, and the repo's
# CONTRACT: marker machinery cannot retire it: that comparator works on closed
# TOKEN SETS, and what is duplicated here is a PREDICATE.
#
# So the comparator is behavioural. One corpus, both implementations, byte-equal
# verdicts required. Every row above proves one copy; this row proves they are
# still the same copy. When the Phase 3 fence wiring deletes the heredoc and
# routes on the python, this section is what makes that deletion visible instead
# of silent — retire it in the SAME commit that removes the heredoc.
CLASSIFY_DIFF_DIR="$(mktemp -d)"
CLASSIFY_DIFF_DIR="$(cd "$CLASSIFY_DIFF_DIR" && pwd -P)"
python3 -I -B - "$CLASSIFY_DIFF_DIR" <<'PY'
import json, pathlib, sys

out = pathlib.Path(sys.argv[1])
def document(status, failure_class, anchor, rationale, risks="[]", extra=""):
    return (f"```yaml\nstatus: {status}\nfailure_class: {failure_class}\n"
            f"signal_anchor: {anchor}\nrationale: {rationale}\n"
            f"risks: {risks}\n{extra}```\n")

cases = [
    # accepted shapes
    document("CLASSIFIED", "code_bug", '"README.md:42"', '"repository failure"'),
    document("CLASSIFIED", "env_drift", "README.md:5", "bare scalar"),
    document("CLASSIFIED", "flaky", '"gh-run-123:42"', '"transient runner"'),
    document("CLASSIFIED", "stale_base", "gh-run-9:3", "base moved"),
    document("AMBIGUOUS", "null", "null", '"no supported signal"'),
    document("REFUSED", "null", "null", '"input-malformed"'),
    "prose before the fence\n\n" + document(
        "CLASSIFIED", "flaky", '"gh-run-123:42"', '"transient runner"'),
    # the single-quoted YAML decoder, both members
    document("REFUSED", "null", "null", "'can''t reproduce it'"),
    document("CLASSIFIED", "code_bug", "'README.md:42'", "'it''s red'"),
    document("REFUSED", "null", "null", "'unterminated"),
    document("REFUSED", "null", "null", "'can't reproduce it'"),
    document("REFUSED", "null", "null", "'"),
    # scalar bounds and decoded control characters
    document("REFUSED", "null", "null", json.dumps("x" * 256)),
    document("REFUSED", "null", "null", json.dumps("x" * 257)),
    document("REFUSED", "null", "null", json.dumps("boun\x00ded")),
    document("REFUSED", "null", "null", json.dumps("boun\x1fded")),
    document("REFUSED", "null", "null", json.dumps("boun\x7fded")),
    document("REFUSED", "null", "null", "'boun" + chr(1) + "ded'"),
    document("REFUSED", "null", "null", "boun@ded"),
    document("REFUSED", "null", "null", "null"),
    # anchors
    document("CLASSIFIED", "code_bug", '":121"', '"x"'),
    document("CLASSIFIED", "code_bug", '"README.md:0"', '"x"'),
    document("CLASSIFIED", "code_bug", '"/etc/passwd:1"', '"x"'),
    document("CLASSIFIED", "code_bug", '"../README.md:1"', '"x"'),
    document("CLASSIFIED", "code_bug", '"missing.ts:1"', '"x"'),
    document("CLASSIFIED", "code_bug", '""', '"x"'),
    document("CLASSIFIED", "code_bug", '"gh-run-123:42"', '"x"'),
    document("CLASSIFIED", "code_bug", '"tests:1"', '"x"'),
    # class set and field set
    document("CLASSIFIED", "vibes", '"README.md:12"', '"x"'),
    document("CLASSIFIED", "code_bug", '"README.md:1"', '"x"', extra="unknown: v\n"),
    document("CLASSIFIED", "code_bug", '"README.md:1"', '"x"', risks="[drop-tests]"),
    document("CLASSIFIED", "code_bug", '"README.md:1"', '"x"',
             extra="failure_class: flaky\n"),
    document("AMBIGUOUS", "code_bug", '"README.md:1"', '"x"'),
    # a fence that is not the LAST thing in the document
    document("CLASSIFIED", "code_bug", '"README.md:1"', '"x"') + "trailing content\n",
    # documents with no fence at all
    "no fenced document here\n",
    "```yaml\nstatus: CLASSIFIED\n",
]
for index, case in enumerate(cases, start=1):
    (out / f"case-{index:02d}.md").write_text(case, encoding="utf-8")
print(len(cases))
PY
CLASSIFY_DIFF_COUNT="$(ls "$CLASSIFY_DIFF_DIR" | grep -c '^case-')"
cat > "$CLASSIFY_DIFF_DIR/judge.py" <<'PY'
# The python copy, normalised onto the heredoc copy's stdout wire format.
import importlib.util, pathlib, re, sys

module_path, case_path, working_dir = sys.argv[1:]
spec = importlib.util.spec_from_file_location("uberdev_ci_contract", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

payload = pathlib.Path(case_path).read_bytes()
try:
    parsed = module._parse_ci_classification(payload, working_dir)
except module.ContractFailure as error:
    if str(error) != "ci_classification_refused":
        raise SystemExit(2)
    # The heredoc copy PRINTS the refusal rationale; this copy raises before
    # returning it, so re-decode it with the same scalar decoder rather than
    # comparing the two on a field only one of them emits.
    body = re.search(r"(?:^|\n)```yaml\r?\n(.*?)\r?\n```\r?\n?\Z",
                     payload.decode("utf-8"), re.DOTALL).group(1)
    rationale = ""
    for line in body.splitlines():
        if line.startswith("rationale:"):
            rationale = module._ci_classifier_scalar(line.split(":", 1)[1].strip()) or ""
    print("REFUSED\t-\t-\t" + rationale)
    raise SystemExit(0)
if parsed["status"] == "AMBIGUOUS":
    print("AMBIGUOUS\tflaky\t-\t-")
else:
    print("CLASSIFIED\t" + parsed["failure_class"] + "\t" + parsed["signal_anchor"] + "\t-")
PY
CLASSIFY_DIFF_MISMATCH=0
CLASSIFY_DIFF_FIRST=''
CLASSIFY_DIFF_ACCEPTED=0
for case_file in "$CLASSIFY_DIFF_DIR"/case-*.md; do
  HEREDOC_OUT="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3" 2>/dev/null' \
    _ "$CLASSIFY_HELPER" "$case_file" "$REPO_ROOT")" && HEREDOC_VERDICT="$HEREDOC_OUT" \
    || HEREDOC_VERDICT='<REFUSED-BY-CONTRACT>'
  PYTHON_OUT="$(python3 -I -B "$CLASSIFY_DIFF_DIR/judge.py" \
    "$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py" "$case_file" "$REPO_ROOT" 2>/dev/null)" \
    && PYTHON_VERDICT="$PYTHON_OUT" || PYTHON_VERDICT='<REFUSED-BY-CONTRACT>'
  [ "$HEREDOC_VERDICT" = '<REFUSED-BY-CONTRACT>' ] \
    || CLASSIFY_DIFF_ACCEPTED=$((CLASSIFY_DIFF_ACCEPTED + 1))
  if [ "$HEREDOC_VERDICT" != "$PYTHON_VERDICT" ]; then
    CLASSIFY_DIFF_MISMATCH=$((CLASSIFY_DIFF_MISMATCH + 1))
    [ -n "$CLASSIFY_DIFF_FIRST" ] || CLASSIFY_DIFF_FIRST="$(basename "$case_file"): heredoc='$HEREDOC_VERDICT' python='$PYTHON_VERDICT'"
  fi
done
# A corpus that is refused wholesale proves nothing — both copies would "agree"
# by refusing everything. Require real accepted shapes in it.
if [ "$CLASSIFY_DIFF_MISMATCH" -ne 0 ]; then
  echo "  FAIL  S10.14c — the two classifier predicates DIVERGED on $CLASSIFY_DIFF_MISMATCH/$CLASSIFY_DIFF_COUNT documents; first: $CLASSIFY_DIFF_FIRST"; FAIL=$((FAIL + 1))
elif [ "$CLASSIFY_DIFF_COUNT" -lt 30 ] || [ "$CLASSIFY_DIFF_ACCEPTED" -lt 8 ]; then
  echo "  FAIL  S10.14c — VACUOUS: $CLASSIFY_DIFF_COUNT cases, only $CLASSIFY_DIFF_ACCEPTED accepted by the live copy"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S10.14c — both copies of the classifier predicate agree on all $CLASSIFY_DIFF_COUNT corpus documents ($CLASSIFY_DIFF_ACCEPTED accepted)"; PASS=$((PASS + 1))
fi
rm -rf "$CLASSIFY_DIFF_DIR"

# RETIRED SURFACE, retained deliberately (#381). `review_child_result_path`'s
# sole caller is commands/review-pr.md:3319, which sits behind the unconditional
# workflow-only refusal at :3305 -- so on the shipped tree the function is
# unreachable in production, and every carrier value below is one production can
# no longer emit (`codex` was deleted from _UBERDEV_DISPATCH_BACKEND_ENUM;
# `wezterm`/`background` are refused by uberdev_dispatch_preflight_backend for
# /review-pr). The enum override below is therefore a FIXTURE enum, not the
# production one -- it is deliberately NOT narrowed to the live set, because
# narrowing it would turn the carrier-mismatch cases into vacuous passes exactly
# the way tests/agent-dispatch.test.sh:678-685 refuses to rename its own codex
# fixture. This block is kept against a future Workflow-native Phase 3 (RFC 0012
# §3.1), which is when the function becomes reachable again; retarget it THEN,
# with the production enum, rather than now against a gate nothing can pass.
RESULT_PATH_HELPER="$(mktemp)"
RESULT_PATH_TMP="$(mktemp -d)"
RESULT_PATH_TMP="$(cd "$RESULT_PATH_TMP" && pwd -P)"
export UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export UBERDEV_CARRIER_RUN_DIR="$RESULT_PATH_TMP/run"
export _UBERDEV_DISPATCH_BACKEND_ENUM='auto|wezterm|background|codex'
export UBERDEV_CARRIER_BACKEND=codex
awk '
  /^review_child_result_path\(\) \{/ { capture=1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$REVIEW_PR" > "$RESULT_PATH_HELPER"
mkdir -p "$RESULT_PATH_TMP/run/children/classifier"
RESULT_PATH="$RESULT_PATH_TMP/run/children/classifier/result.md"
RESULT_STATUS="$RESULT_PATH_TMP/run/children/classifier/status.json"
RESULT_LEDGER="$RESULT_PATH_TMP/classifier.launched"
write_classifier_case CLASSIFIED code_bug '"README.md:42"' '"repository test failure"'
cp "$CLASSIFY_CASE" "$RESULT_PATH"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"4242"}\n' > "$RESULT_STATUS"
printf '{"edge":"review_pr.ci.classify","result":"%s","status":"%s"}\n' "$RESULT_PATH" "$RESULT_STATUS" > "$RESULT_LEDGER"
RESULT_PATH_INVALID=0
if bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER"; then
  RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
fi
write_result_carrier_fixture() {
  local backend="$1"
  python3 -I -B - "$RESULT_LEDGER" "$RESULT_PATH" "$RESULT_STATUS" "$backend" <<'PY'
import json,pathlib,sys
ledger,result,status,backend=sys.argv[1:]
receipt={
 "schema_version":1,"edge_id":"review_pr.ci.classify","instance_id":"classifier",
 "backend":backend,"handle":"4242","state":"running",
 "result_file":result,"status_file":status,
}
row={
 "edge":"review_pr.ci.classify","instance":"classifier",
 "receipt":json.dumps(receipt,sort_keys=True,separators=(",",":")),
 "result":result,"status":status,
}
pathlib.Path(ledger).write_text(json.dumps(row,separators=(",",":"))+"\n")
pathlib.Path(status).write_text(json.dumps({
 "backend":backend,"state":"completed","exit_code":0,"pid":"4242",
},separators=(",",":"))+"\n")
PY
}
write_result_carrier_fixture codex
RESULT_PATH_RESOLVED="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER")"
[ "$RESULT_PATH_RESOLVED" != "$RESULT_PATH" ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ -f "$RESULT_PATH_RESOLVED" ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
cmp "$RESULT_PATH" "$RESULT_PATH_RESOLVED" >/dev/null || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
SNAPSHOT_CLASSIFICATION="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$RESULT_PATH_RESOLVED" "$REPO_ROOT")"
[ "$SNAPSHOT_CLASSIFICATION" = $'CLASSIFIED\tcode_bug\tREADME.md:42\t-' ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))

RESULT_REASON="$(env _UBERDEV_DISPATCH_BACKEND_ENUM='auto|codex|codex' \
  UBERDEV_CARRIER_BACKEND=codex \
  bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' \
    _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_carrier_mismatch ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
RESULT_REASON="$(env \
  _UBERDEV_DISPATCH_BACKEND_ENUM='auto|wezterm|background|codex' \
  UBERDEV_CARRIER_BACKEND=auto \
  bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' \
    _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_carrier_mismatch ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
write_result_carrier_fixture background
RESULT_REASON="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' \
  _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_receipt_mismatch ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
write_result_carrier_fixture codex

chmod 600 "$RESULT_PATH_RESOLVED"
# RE-POINTED (#383). The routed transport proved "the bytes cannot be replaced
# after discovery" through the digest embedded in the published
# `.trusted.md.attempt-<32hex>-<64hex>` filename. The Workflow transport proves
# the SAME property one layer down and more directly: capture-ci-terminal
# digests the result, and validate-ci-classification re-captures it against that
# digest, so any post-capture replacement refuses. Exercised on real bytes.
CLASSIFY_GOOD_DIGEST="$(python3 -I -B "$CONTRACT_PY" digest --path "$RESULT_PATH_RESOLVED" --minimum 1 --maximum 65536)"
write_classifier_case AMBIGUOUS null null '"replacement after discovery"'
cp "$CLASSIFY_CASE" "$RESULT_PATH_RESOLVED"
if python3 -I -B - "$CONTRACT_PY" "$RESULT_PATH_RESOLVED" "$CLASSIFY_GOOD_DIGEST" <<'RECAPTURE_PY'
import importlib.util, sys
contract, path, digest = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("cfc_recapture", contract)
module = importlib.util.module_from_spec(spec)
sys.modules["cfc_recapture"] = module
spec.loader.exec_module(module)
try:
    module.capture_expected(path, digest, 1, module.CI_CLASSIFICATION_RESULT_LIMIT)
except module.ContractFailure:
    raise SystemExit(1)
raise SystemExit(0)
RECAPTURE_PY
then
  RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
fi
python3 -I -B - "$RESULT_LEDGER" "$RESULT_PATH" "$RESULT_STATUS" <<'PY'
import json,pathlib,sys
ledger,result,status=sys.argv[1:]
receipt={"schema_version":1,"edge_id":"review_pr.ci.classify","instance_id":"foreign-instance",
         "backend":"codex","handle":"4242","state":"running",
         "result_file":result,"status_file":status}
row={"edge":"review_pr.ci.classify","instance":"classifier",
     "receipt":json.dumps(receipt,sort_keys=True,separators=(",",":")),
     "result":result,"status":status}
pathlib.Path(ledger).write_text(json.dumps(row,separators=(",",":"))+"\n")
PY
if bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER"; then
  RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
fi
FOREIGN_RESULT="$RESULT_PATH_TMP/foreign/children/classifier/result.md"
FOREIGN_STATUS="$RESULT_PATH_TMP/foreign/children/classifier/status.json"
mkdir -p "$(dirname "$FOREIGN_RESULT")"
cp "$RESULT_PATH" "$FOREIGN_RESULT"
cp "$RESULT_STATUS" "$FOREIGN_STATUS"
python3 -I -B - "$RESULT_LEDGER" "$FOREIGN_RESULT" "$FOREIGN_STATUS" <<'PY'
import json,pathlib,sys
ledger,result,status=sys.argv[1:]
receipt={"schema_version":1,"edge_id":"review_pr.ci.classify","instance_id":"classifier",
         "backend":"codex","handle":"4242","state":"running",
         "result_file":result,"status_file":status}
row={"edge":"review_pr.ci.classify","instance":"classifier",
     "receipt":json.dumps(receipt,sort_keys=True,separators=(",",":")),
     "result":result,"status":status}
pathlib.Path(ledger).write_text(json.dumps(row,separators=(",",":"))+"\n")
PY
if bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER"; then
  RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
fi
printf '{"edge":"review_pr.ci.classify","result":"%s","status":"%s"}\n{"edge":"review_pr.ci.classify","result":"%s","status":"%s"}\n' \
  "$RESULT_PATH" "$RESULT_STATUS" "$RESULT_PATH" "$RESULT_STATUS" > "$RESULT_LEDGER"
RESULT_REASON="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_ledger_duplicate ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
printf '{bad json\n' > "$RESULT_LEDGER"
RESULT_REASON="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_ledger_malformed ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
printf '[]\n' > "$RESULT_LEDGER"
RESULT_REASON="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_ledger_malformed ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
mkdir -p "$RESULT_PATH_TMP/run/children/missing"
MISSING_STATUS="$RESULT_PATH_TMP/run/children/missing/status.json"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"4242"}\n' > "$MISSING_STATUS"
python3 -I -B - "$RESULT_LEDGER" "$RESULT_PATH_TMP/run/children/missing/result.md" "$MISSING_STATUS" <<'PY'
import json,pathlib,sys
ledger,result,status=sys.argv[1:]
receipt={"schema_version":1,"edge_id":"review_pr.ci.classify","instance_id":"missing",
         "backend":"codex","handle":"4242","state":"running",
         "result_file":result,"status_file":status}
row={"edge":"review_pr.ci.classify","instance":"missing",
     "receipt":json.dumps(receipt,sort_keys=True,separators=(",",":")),
     "result":result,"status":status}
pathlib.Path(ledger).write_text(json.dumps(row,separators=(",",":"))+"\n")
PY
RESULT_REASON="$(bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" 2>/dev/null)" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
[ "$RESULT_REASON" = classification_artifact_missing ] || RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
mv "$RESULT_PATH" "$RESULT_PATH.real"
ln -s "$RESULT_PATH.real" "$RESULT_PATH"
printf '{"edge":"review_pr.ci.classify","result":"%s","status":"%s"}\n' "$RESULT_PATH" "$RESULT_STATUS" > "$RESULT_LEDGER"
bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
rm -f "$RESULT_PATH"
ln "$RESULT_PATH.real" "$RESULT_PATH"
bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
rm -f "$RESULT_PATH"
cp "$RESULT_PATH.real" "$RESULT_PATH"
printf '{"state":"failed","exit_code":9}\n' > "$RESULT_STATUS"
bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
printf '{"state":"completed","exit_code":7}\n' > "$RESULT_STATUS"
bash -c '. "$1"; review_child_result_path "$2" review_pr.ci.classify >/dev/null' _ "$RESULT_PATH_HELPER" "$RESULT_LEDGER" \
  && RESULT_PATH_INVALID=$((RESULT_PATH_INVALID + 1))
if [ "$RESULT_PATH_INVALID" -eq 0 ]; then
  echo "  PASS  S10.15 — classifier result ledger requires one canonical completed-zero child and rejects unsafe artifacts"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.15 — classifier result-path boundary accepted $RESULT_PATH_INVALID invalid cases"; FAIL=$((FAIL + 1))
fi
rm -rf "$RESULT_PATH_TMP"
rm -f "$RESULT_PATH_HELPER"
rm -f "$CLASSIFY_HELPER" "$CLASSIFY_CASE"

echo
echo "== S11: ci-code-fixer agent shape =="
assert_grep "$CODE_FIXER_CI" '^name: ci-code-fixer$' \
  "S11.1 — frontmatter name"
assert_grep "$CODE_FIXER_CI" 'forbidden-pattern' \
  "S11.2 — forbidden-pattern refusal vocabulary present"
assert_grep "$CODE_FIXER_CI" '\-\-no-verify' \
  "S11.3 — --no-verify forbidden pattern documented"
assert_grep "$CODE_FIXER_CI" 'fix\(ci\):.*chore\(deps\):|chore\(deps\):.*fix\(ci\):' \
  "S11.4 — both commit-type prefixes (fix(ci):, chore(deps):) documented"
assert_no_grep "$CODE_FIXER_CI" 'git push' \
  "S11.5 — agent never pushes (caller handles)"
assert_no_grep "$REVIEW_PR" 'CI_FIX_INPUTS=.*classification_path|classification_path.*CI_CLASSIFICATION_PATH' \
  "S11.6 — fixer handoff never carries the mutable classifier pathname"
assert_no_grep "$CODE_FIXER_CI" 'no classifier pathname crosses this boundary' \
  "S11.6a — fixer contract does not deny its validated classifier-derived signal anchor"
assert_grep "$CODE_FIXER_CI" '[Nn]o classifier (result|log) artifact pathname crosses this boundary' \
  "S11.6b — fixer contract excludes classifier result/log artifact pathnames specifically"
assert_grep "$CODE_FIXER_CI" 'signal_anchor.*intentionally crosses.*validated scalar' \
  "S11.6c — fixer contract names signal_anchor as the intentional validated scalar handoff"
assert_grep "$REVIEW_PR" 'CI_FIX_INPUTS=.*failure_class|failure_class.*review_json_string' \
  "S11.7 — fixer handoff carries the controller-validated failure class"
assert_grep "$REVIEW_PR" 'CI_FIX_INPUTS=.*signal_anchor|signal_anchor.*review_json_string' \
  "S11.8 — fixer handoff carries the controller-validated signal anchor"
assert_grep "$REVIEW_PR" 'CI_CLASSIFICATION_HEAD_SHA=.*review_capture_ci_classification_head' \
  "S11.9 — controller binds classifier authority before dispatch"
assert_grep "$REVIEW_PR" 'head_sha.*CI_CLASSIFICATION_HEAD_SHA' \
  "S11.10 — fixer handoff carries the original classification-bound head"
assert_no_grep "$REVIEW_PR" 'CI_HEAD_SHA="\$\(git rev-parse HEAD\)"' \
  "S11.11 — ROUTE never substitutes a freshly recaptured local head"
python3 -I -B - "$RUN_TREE" <<'PY'
import json,sys
edge=json.load(open(sys.argv[1],encoding="utf-8"))["edges"]["review_pr.ci.fix_code"]
required=edge["required_inputs"]
expected={
    "failure_class":"string",
    "signal_anchor":"string",
    "run_id":"string",
    "head_sha":"string",
    "working_dir":"directory",
    "pr_number":"integer",
}
if required!=expected or "classification_path" in required or "log_path" in required:
    raise SystemExit("ci fixer policy does not bind the validated scalar contract")
PY
if [ "$?" -eq 0 ]; then
  echo "  PASS  S11.12 — policy binds only validated classifier scalars and exact run/head metadata"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S11.12 — policy binds only validated classifier scalars and exact run/head metadata"
  FAIL=$((FAIL + 1))
fi

echo
echo "== S12: ci-rebase-handler agent shape =="
assert_grep "$REBASE_HANDLER" '^name: ci-rebase-handler$' \
  "S12.1 — frontmatter name"
assert_grep "$REBASE_HANDLER" 'force-with-lease=' \
  "S12.2 — explicit-form --force-with-lease=<branch>:<sha> documented"
assert_grep "$REBASE_HANDLER" 'force-if-includes' \
  "S12.3 — --force-if-includes paired with lease"
assert_grep "$REBASE_HANDLER" 'flock|ci-rebase\.lock' \
  "S12.4 — worktree lock file documented"
assert_grep "$REBASE_HANDLER" 'pr-already-merged|head-moved-since-classify|lease-mismatch' \
  "S12.5 — refusal triggers documented"

echo
echo "== S13: stale_base CONFLICT-resolve arm (#80) =="
# Issue #80: ci-rebase-handler returns status: CONFLICT, conflicted_files: [...]
# but commands/review-pr.md had no procedural arm to fan out conflict-resolver
# and resume the rebase under the original lease. The capability was tooled
# (ci-rebase-handler.md:57 + agents/conflict-resolver.md exist) but unwired.
# These assertions lock the procedural arm into the prose so a future edit
# can't silently regress it back to "POST-FIX assumes REBASED".
assert_grep "$REVIEW_PR" 'stage=ci-conflicts' \
  "S13.1 — review-pr.md dispatches the conflict fanout as the ci-conflicts Workflow stage"
assert_grep "$WORKFLOW_JS" 'uberdev:conflict-resolver' \
  "S13.1b — the ci-conflicts stage dispatches uberdev:conflict-resolver"
assert_grep "$REVIEW_PR" 'review_fleet_bind_ci_conflicts ' \
  "S13.1c — one CI binding per conflicted path is minted BEFORE the call"
# The rebase child returns a COUNT, not a path list -- the set a resolver may
# touch must not be chosen by the agent whose failure produced it. Asserting
# `conflicted_files` here would pass on the controller's own shell array of that
# name and so could not tell the two apart; these two assert the return shape
# and the rule that motivates it.
assert_grep "$REVIEW_PR" 'conflict_count' \
  "S13.2 — review-pr.md prose names the conflict_count field the rebase child actually returns"
assert_grep "$REVIEW_PR" 'COUNT, never a path list' \
  "S13.2a — and states why: the child never chooses its successors' scope"
assert_grep "$REVIEW_PR" 'status: CONFLICT' \
  "S13.3 — review-pr.md prose conditions on status: CONFLICT return"
assert_grep "$REVIEW_PR" 'SINGLE message|single message|single assistant message|single assistant turn|SINGLE assistant turn' \
  "S13.4 — single-message Task() invariant present in CONFLICT-resolve arm"
assert_grep "$REVIEW_PR" 'CONFLICT_RESOLVER_CAP' \
  "S13.5 — CONFLICT_RESOLVER_CAP wave-splitting cap referenced by name"
assert_grep "$REVIEW_PR" 'rebase_conflict_ambiguous' \
  "S13.6 — typed data.subreason rebase_conflict_ambiguous documented"
assert_grep "$REVIEW_PR" 'rebase_conflict_refused' \
  "S13.7 — typed data.subreason rebase_conflict_refused documented"
assert_grep "$REVIEW_PR" 'rebase_lease_mismatch' \
  "S13.8 — typed data.subreason rebase_lease_mismatch documented"
assert_grep "$REVIEW_PR" 'force-with-lease=' \
  "S13.9 — post-resolution push uses explicit-form --force-with-lease=<branch>:<sha>"
assert_grep "$REVIEW_PR" 'force-if-includes' \
  "S13.10 — post-resolution push pairs --force-with-lease with --force-if-includes"
assert_grep "$REVIEW_PR" 'CI_LEASE_SHA=.*rev-parse "refs/remotes/origin/\$CI_PR_HEAD_BRANCH"' \
  "S13.11 — the lease is the PR HEAD's prior tip, captured by the controller (never origin/<base>)"
assert_grep "$REVIEW_PR" 'read-ci-authority-member' \
  "S13.11a — the lease is read back through a DIGEST re-check, never with jq"
assert_no_grep "$REVIEW_PR" 'EXPECTED_OLD_SHA' \
  "S13.11b — the agent-held lease name is gone: the child no longer captures or holds it (#383)"
assert_no_grep "$REBASE_HANDLER" '^[^-]*git push [^i]' \
  "S13.11c — ci-rebase-handler proposes no push command"
# The agent file NAMES the retired lock in order to ban it (a future reader must
# not "restore" a lock that cannot work across fences), so strip the prose that
# does the banning before checking that no live recipe remains.
REBASE_HANDLER_LIVE="$(sed -n '/^## No lock file/,/^## Process/!p' "$REBASE_HANDLER")"
if grep -Eq 'exec 200|flock -n' <<<"$REBASE_HANDLER_LIVE"; then
  echo "  FAIL  S13.11d — a live flock recipe survives outside the deletion note"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S13.11d — the void fence-scoped flock lock is deleted, not ported"; PASS=$((PASS + 1))
fi
assert_grep "$REVIEW_PR" 'rebase --continue|git rebase --continue' \
  "S13.12 — RESOLVED path runs git rebase --continue before push"
assert_grep "$REVIEW_PR" 'rebase --abort|git rebase --abort' \
  "S13.13 — AMBIGUOUS / REFUSED arm aborts the in-progress rebase"
assert_grep "$REVIEW_PR" 'merge-pipeline/SKILL\.md.*Phase 3\.3|Phase 3\.3.*merge-pipeline/SKILL\.md' \
  "S13.14 — review-pr.md cross-references merge-pipeline/SKILL.md Phase 3.3 reference pattern"
assert_grep "$REVIEW_PR" 'Phase 3.*halt|halt Phase 3|OUTCOME=halted' \
  "S13.15 — AMBIGUOUS / REFUSED / lease-mismatch surfaces halt-with-OUTCOME=halted"
# Negative-regression guard: POST-FIX must NOT unconditionally assume rebase
# success. The original bug was Step 6c.5 silently falling through to Phase 1
# re-entry on a CONFLICT return. The procedural arm must explicitly gate
# POST-FIX on REBASED (or call the CONFLICT-resolve arm before fix-push).
#
# S13.16 USED TO BE `assert_grep "$REVIEW_PR" 'status: REBASED'`. That is the
# #370/#371 class in miniature: the only line it could match was the prose
# sentence "(the agent already pushed; new HEAD is on remote)", which was
# FACTUALLY WRONG — the agent had been demoted to preparer and nothing pushed
# on that path at all. The assertion was disjoint from the behaviour it named,
# so it stayed green over the bug AND would have stayed green over the fix.
# It now keys on the VALIDATED terminal scalar and on the routing target.
assert_grep "$REVIEW_PR" 'CI_FIXER_TERMINAL_STATUS=REBASED' \
  "S13.16 — POST-FIX branches on the VALIDATED rebase terminal, not the agent's self-report"
assert_grep "$REVIEW_PR" 'CI_FIXER_TERMINAL_STATUS=CONFLICT' \
  "S13.16b — the CONFLICT terminal has its own routing bullet"
assert_no_grep "$REVIEW_PR" 'the agent already pushed' \
  "S13.16c — the retired 'the agent already pushed' claim is gone (the agent has no remote-write tool)"
assert_grep "$REVIEW_PR" 'by_agent="ci-rebase-handler\+conflict-resolver"' \
  "S13.17 — ci_fix_pushed audit event names both contributing agents on conflict-resolve push success"

# Issue #398: the arm's own Step-4 re-bind disagreed with the judge that put it
# there. `mapfile -t conflicted_files < <(git status --porcelain | awk '/^UU /')`
# was two defects in one line — the two exact bytes `UU` against
# code_fixer_contract.py's seven-pair unmerged membership test (so an add/add
# conflict enumerated ZERO files and "all RESOLVED" was vacuously true), and a
# bash-only builtin in a fence the harness runs under /bin/zsh (so the array was
# empty there too, silently, with nothing consuming the 127). Both failure modes
# are INVISIBLE to a syntax gate: `bash -n` and `zsh -n` both parse that line
# happily. These rows are the gate.
assert_no_grep "$REVIEW_PR" 'mapfile|readarray' \
  "S13.18 — the bash-only array-slurp builtin never returns to this command file (its fences run under zsh)"
assert_no_grep "$REVIEW_PR" '\^UU' \
  "S13.19 — the narrow two-byte status pattern is gone from the CONFLICT arm"
assert_grep "$REVIEW_PR" 'review_fleet_unmerged_paths' \
  "S13.20 — the re-bind calls the shared enumerator instead of parsing porcelain itself"
assert_grep "$REVIEW_PR" 'git add -- ' \
  "S13.21 — the staging call carries the -- separator so a path named like a flag cannot be one"
assert_grep "$REVIEW_PR" 'rebase_enumerate_failed' \
  "S13.22 — a failed enumeration halts under its OWN subreason, not rebase_continue_failed"
# S13.23 — doc-drift sweep. The `UU` claim was restated in ten places across
# five files; correcting the code and leaving the prose is how the next reader
# re-derives the bug. One row per file so a regression names its own file.
for f_desc in \
  "$REVIEW_PR|commands/review-pr.md" \
  "$REBASE_HANDLER|agents/ci-rebase-handler.md" \
  "$REVIEW_FLEET_SKILL|skills/review-fleet/SKILL.md" \
  "$REVIEW_FLEET_WORKFLOW|skills/review-fleet/workflow.js" \
  "$REVIEW_FLEET_ARGS|lib/review-fleet-args.sh"; do
  assert_no_grep "${f_desc%%|*}" 'UU[ -](entries|enumeration|paths)|UU-enumeration' \
    "S13.23 — ${f_desc##*|} no longer describes the conflict set as the UU entries"
done

echo
echo "== S14: ci-code-fixer REFUSED halt path (Phase 3 6c.5) — locks post-O5 findings-to-issues dispatch shape =="

# S14.1 — Phase 3 6c.5 documents the REFUSED halt path with AskUserQuestion-less
# deterministic exit (mirrors 6c.6 HALT shape per RFC 0002 §3.2). Uses
# file-level assert_grep — patterns are sufficient to lock contract without
# section anchoring (mawk's awk-range against indented headings is unreliable).
assert_grep "$REVIEW_PR" \
  'REFUSED.*halt|halt.*REFUSED|ci-code-fixer.*REFUSED' \
  "S14.1 — Phase 3 6c.5 documents the ci-code-fixer REFUSED halt path"

# S14.2 — REFUSED → three-action sequence: file issue, emit halt prose, audit+exit
assert_grep "$REVIEW_PR" \
  'Three actions in order|three-action ordering|three actions in order' \
  "S14.2 — Phase 3 6c.5 documents three-action ordering on REFUSED (constraints [hard])"

# S14.3 — Action 1 is filing a CRITICAL-tier GH issue (mirrors findings-to-issues
# BLOCKER/CRITICAL shape per RFC 0002 §3.3.2).
assert_grep "$REVIEW_PR" \
  'CRITICAL-tier.*issue|File the failing test.*CRITICAL|CRITICAL.*GH issue' \
  "S14.3 — Phase 3 6c.5 action 1 is filing a CRITICAL-tier GH issue (RFC 0002 §3.3.2)"

# S14.4 (re-pinned post-O5) — Phase 3 6c.5 dispatches findings-to-issues
# with a synthetic single-row aggregate wrapped in
# <external-untrusted-input source="ci-refused-synthetic"> (RFC 0002 #116 O5).
# Pre-O5 pattern (`gh issue create --label review-pr-finding`) was correct for
# Wave 1 but is REPLACED here.
assert_grep "$REVIEW_PR" \
  'Task.*findings-to-issues.*ci-refused-synthetic|subagent_type.*findings-to-issues|<external-untrusted-input source="ci-refused-synthetic">' \
  "S14.4 — Phase 3 6c.5 dispatches findings-to-issues with synthetic aggregate (post-O5 dispatch shape; #116 O5)"

# S14.5 — tombstone: REFUSED branch MUST NOT retry (constraints [hard]:
# "REFUSED is a deterministic decision, not flake; retrying consumes 3 iterations").
# Negative: extract the REFUSED sub-block by line range and assert no retry-counter
# increment in that sub-block.
R_START=$(head -1 <<<"$(grep -n 'ci-code-fixer.*`status: REFUSED`' "$REVIEW_PR")" | cut -d: -f1)
R_END=$(awk -v s="${R_START:-0}" 'NR > s && /ci-rebase-handler.*`status: REBASED|ci-rebase-handler.*`status: CONFLICT|^### 6c\.6/ { print NR; exit }' "$REVIEW_PR")
if [[ -n "$R_START" && -n "$R_END" ]]; then
  RETRY_COUNT=$(sed -n "${R_START},${R_END}p" "$REVIEW_PR" | grep -cE 'CI_FIX_LOOP_CAP|loop-counter \+\+|retry_count\+\+|iteration\+\+')
  if [[ "$RETRY_COUNT" -eq 0 ]]; then
    echo "  PASS  S14.5 — REFUSED sub-block does NOT increment retry counter (constraints [hard]; tombstone)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S14.5 — REFUSED sub-block MUST NOT retry; found $RETRY_COUNT retry-increment patterns"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  S14.5 — could not locate REFUSED sub-block (R_START=$R_START R_END=$R_END)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== S15: field-contract structural guard — probe reads state + immutable run metadata =="
# Lock the gh >= 2.83.1 field contract in the prose so a future edit can't
# silently regress the probe back to the removed status,conclusion fields.
assert_grep "$REVIEW_PR" 'gh pr checks "\$PR_NUMBER" --json name,state,bucket,link,event,workflow' \
  "S15.1 — PROBE call reads state plus immutable run-selection metadata"
# The only text allowed AFTER `--interval 30` on the invocation line is the
# bounded-pass rc capture — a `--json` projection (or any other flag) must not
# creep in, because gh rejects `--watch` together with `--json`.
assert_grep "$REVIEW_PR" 'gh pr checks "\$PR_NUMBER" --watch --interval 30( \|\| CI_MONITOR_RC=\$\?)?$' \
  "S15.2 — MONITOR --watch call takes NO --json (gh forbids --watch with --json)"
# S15.2b — gh 2.83.1 rejects `--watch` together with `--json`
# ("cannot use --watch with --json flag", verified live). Scope this guard to
# actual `gh pr checks ... --watch` *command invocations* (not the prose that
# explains the constraint) by flagging only invocation lines that also carry
# --json. An invocation line is one where gh pr checks + --watch are not inside
# backtick-quoted prose: we approximate by requiring the line to NOT contain a
# backtick (command fences here are plain, prose references are backticked).
S15_2B_VIOLATIONS="$(awk '
  /gh pr checks/ && /--watch/ && /--json/ && $0 !~ /`/ { print FILENAME ":" NR ": " $0 }
' "$REVIEW_PR")"
if [ -z "$S15_2B_VIOLATIONS" ]; then
  echo "  PASS  S15.2b — no gh pr checks --watch invocation is combined with --json"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15.2b — a gh pr checks --watch invocation is combined with --json (gh rejects this)"
  printf '%s\n' "$S15_2B_VIOLATIONS" | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi
assert_no_grep "$REVIEW_PR" '\-\-json name,status,conclusion' \
  "S15.3 — no probe reads the removed --json name,status,conclusion field set"
assert_grep "$REVIEW_PR" 'bucket .* \{pass, skipping\}|bucket ∈ \{pass, skipping\}' \
  "S15.4 — green predicate keyed off bucket ∈ {pass, skipping}"
assert_grep "$REVIEW_PR" 'bucket ∈ \{fail, cancel\}|bucket .* \{fail, cancel\}' \
  "S15.5 — red predicate keyed off bucket ∈ {fail, cancel}"

echo
echo "== S15-RUNTIME: PROBE bucket-classification exercised against fake-gh =="
# Extract the PROBE verdict jq program *from review-pr.md itself* so this test
# exercises the documented contract, not a parallel re-implementation. If the
# prose jq changes, this re-extracts it and re-verifies behaviour.
JQ_VERDICT_PROG="$(awk '
  /PROBE_VERDICT="\$\(jq -r .$/ { capture=1; next }
  capture && /^[[:space:]]*.[[:space:]]*<<<"\$PROBE_JSON"/ { capture=0; exit }
  capture { print }
' "$REVIEW_PR")"

if [ -z "$JQ_VERDICT_PROG" ]; then
  echo "  FAIL  S15-RT.0 — could not extract PROBE_VERDICT jq program from review-pr.md"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S15-RT.0 — extracted PROBE_VERDICT jq program from review-pr.md prose"
  PASS=$((PASS + 1))
fi

FAKE_GH_DIR="$REPO_ROOT/tests/_fixtures/fake-gh"
if [ ! -x "$FAKE_GH_DIR/gh" ]; then
  echo "  FAIL  S15-RT.0b — fake-gh stub missing/not executable at $FAKE_GH_DIR/gh"
  FAIL=$((FAIL + 1))
fi

# Run the PROBE exactly as Phase 3 6c.1 specifies: fake gh on PATH, FAKE_GH_MODE
# set, `gh pr checks <n> --json name,state,bucket,link,event,workflow`. Echo the raw probe JSON on
# stdout so callers capture it in their own scope (a global set inside the $(...)
# command-substitution subshell would NOT propagate back to the caller).
_run_probe() {
  local mode="$1"
  PATH="$FAKE_GH_DIR:$PATH" FAKE_GH_MODE="$mode" \
    gh pr checks 999 --json name,state,bucket,link,event,workflow 2>/dev/null
}

assert_verdict() {
  local mode="$1" expected="$2" desc="$3"
  local probe got bucket_ok="no"
  probe="$(_run_probe "$mode")"
  got="$(jq -r "$JQ_VERDICT_PROG" <<<"$probe" 2>/dev/null)"
  # Guard against the silent-degradation class the issue pins: a probe whose
  # entries lack the `bucket` key would fall through the verdict jq's any()
  # tests to "green" — masking a broken field contract as a passing CI. So a
  # non-empty verdict is only trusted when every entry actually carries bucket.
  if printf '%s' "$probe" | jq -e 'type=="array" and length>0 and all(.[]; has("bucket"))' >/dev/null 2>&1; then
    bucket_ok="yes"
  fi
  if [ "$got" = "$expected" ] && [ "$bucket_ok" = "yes" ]; then
    echo "  PASS  $desc (mode=$mode → $got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        mode: $mode"; echo "        expected verdict: $expected (bucket-on-every-entry: yes)"; echo "        actual verdict:   $got (bucket-on-every-entry: $bucket_ok)"
    FAIL=$((FAIL + 1))
  fi
}

# S15-RT.1..4 — bucket classification, driven by the now-live ci-checks-* modes.
assert_verdict ci-checks-green   green   "S15-RT.1 — all bucket ∈ {pass,skipping} → green fast-path"
assert_verdict ci-checks-pending pending "S15-RT.2 — all bucket pending → MONITOR transition"
assert_verdict ci-checks-red     red     "S15-RT.3 — any bucket fail → red (CLASSIFY)"
assert_verdict ci-checks-mixed   red     "S15-RT.4 — fail+pending mix → red (red outranks pending)"

# S15-RT.5 — gh >= 2.83.1 field contract: the probe JSON the stub emits MUST
# carry state plus immutable run-selection metadata on every entry and NEVER the
# removed status/conclusion fields.
GREEN_PROBE="$(_run_probe ci-checks-green)"
if printf '%s' "$GREEN_PROBE" | jq -e 'type=="array" and length>0 and all(.[]; has("name") and has("state") and has("bucket") and has("link") and has("event") and has("workflow"))' >/dev/null 2>&1; then
  echo "  PASS  S15-RT.5a — stub probe entries carry state plus immutable run metadata"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.5a — stub probe entries missing run-selection metadata: $GREEN_PROBE"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$GREEN_PROBE" | jq -e 'all(.[]; (has("status")|not) and (has("conclusion")|not))' >/dev/null 2>&1; then
  echo "  PASS  S15-RT.5b — stub probe entries carry NO removed status/conclusion fields"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.5b — stub probe entries still carry removed status/conclusion: $GREEN_PROBE"; FAIL=$((FAIL + 1))
fi

# S15-RT.6 — no-checks fast path: empty array (and non-zero gh exit + 'no checks
# reported on the' stderr) maps to the `empty` verdict → skipped_no_checks.
EMPTY_PROBE="$(_run_probe ci-checks-no-checks)"
EMPTY_VERDICT="$(jq -r "$JQ_VERDICT_PROG" <<<"$EMPTY_PROBE" 2>/dev/null)"
if [ "$EMPTY_VERDICT" = "empty" ]; then
  echo "  PASS  S15-RT.6 — ci-checks-no-checks empty array → empty verdict (skipped_no_checks)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.6 — expected empty verdict, got '$EMPTY_VERDICT' (probe='$EMPTY_PROBE')"; FAIL=$((FAIL + 1))
fi

echo
echo "== S16: benign-cancel same-name dedupe (drop-only-cancel) + empty-checks settle window (#302) =="
# test.yml fires on push AND pull_request, so one head SHA carries two same-name
# check runs per job; once #309's concurrency group lands, every superseded push
# run reports bucket=cancel next to the authoritative completed run. The PROBE jq
# MUST dedupe same-name entries by DROPPING ONLY the benign `cancel` row when a
# non-cancel sibling exists (a sole cancel stays red), BEFORE the aggregate
# red/pending/green fold — else every superseded push manufactures a permanent RED.
# This is DELIBERATELY NOT best-state-wins: best-state-wins lets a completed push
# `pass` launder its still-running (`pending`) or failed (`fail`) pull_request
# sibling into the GREEN fast-path that skips MONITOR/CLASSIFY (re-opening the
# GREEN-describes-code-CI-never-validated window). fail/pending must stay
# un-maskable; only the benign cancel is dropped. #309 MUST land after this dedupe.
assert_grep "$REVIEW_PR" 'group_by\(\.name\)' \
  "S16.1 — PROBE verdict jq dedupes same-name check runs (group_by(.name))"
assert_grep "$REVIEW_PR" 'select\(\.bucket != "cancel"\)' \
  "S16.2 — dedupe drops ONLY benign cancel rows (select(.bucket != \"cancel\")), never fail/pending"
# Guard against silent reintroduction of best-state-wins laundering: the old
# rank/max_by construct must NOT come back (it let pass mask a fail/pending sibling).
if grep -Eq 'max_by\(rank\)|def rank:' "$REVIEW_PR"; then
  echo "  FAIL  S16.2b — best-state-wins laundering construct (max_by(rank)/def rank) reintroduced into PROBE jq"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S16.2b — no best-state-wins laundering construct (max_by(rank)/def rank) in PROBE jq"
  PASS=$((PASS + 1))
fi
assert_grep "$REVIEW_PR" 'CI_SETTLE_AGE_SEC = 120' \
  "S16.3a — settle threshold constant declared (CI_SETTLE_AGE_SEC = 120)"
assert_grep "$REVIEW_PR" 'CI_SETTLE_REPROBES = 3' \
  "S16.3b — settle re-probe cap constant declared (CI_SETTLE_REPROBES = 3)"
assert_grep "$REVIEW_PR" 'git show -s --format=%ct HEAD' \
  "S16.4a — settle window computes head age from the head commit timestamp"
assert_grep "$REVIEW_PR" 'SETTLE_REPROBES_USED' \
  "S16.4b — settle loop tracks SETTLE_REPROBES_USED"
assert_grep "$REVIEW_PR" 'subreason=settle_reprobe' \
  "S16.5 — settle re-probe audited via ci_probe_started subreason=settle_reprobe (no new enum member)"
assert_grep "$REVIEW_PR" 'settle window above is exhausted' \
  "S16.6 — skipped_no_checks terminal row gated on settle-window exhaustion"

echo
echo "== S16-RUNTIME: same-name dedupe exercised against the documented jq =="
# Reuses the JQ_VERDICT_PROG extracted live from review-pr.md in S15-RUNTIME, fed
# with inline probe JSON (the same-name shapes the fake-gh modes don't model).
assert_verdict_inline() {
  local json="$1" expected="$2" desc="$3"
  local got
  got="$(jq -r "$JQ_VERDICT_PROG" <<<"$json" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    echo "  PASS  $desc (→ $got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        expected: $expected"; echo "        actual:   $got"; echo "        json:     $json"
    FAIL=$((FAIL + 1))
  fi
}

if [ -z "$JQ_VERDICT_PROG" ]; then
  echo "  FAIL  S16-RT.0 — JQ_VERDICT_PROG empty (S15-RT.0 extraction failed); cannot exercise dedupe"
  FAIL=$((FAIL + 1))
else
  # S16-RT.1 — benign cancel: superseded same-name run cancelled, sibling passed → green.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"SUCCESS","bucket":"pass"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    green "S16-RT.1 — same-name cancel+pass dedupes to pass (benign cancel → green)"
  # S16-RT.2 — true cancel: cancel is the ONLY state for its name → still red.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.2 — sole-state cancel stays red (dedupe never launders a real cancel)"
  # S16-RT.3 — cancel + pending same name: the re-run is authoritative → MONITOR.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"QUEUED","bucket":"pending"}]' \
    pending "S16-RT.3 — same-name cancel+pending dedupes to pending (MONITOR transition)"
  # S16-RT.4 — fail outranks its own cancel sibling: a real failure stays red.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.4 — same-name fail+cancel dedupes to fail (red; dedupe never masks a failure)"
  # S16-RT.5 — distinct names untouched by dedupe (regression guard for S15-RT.4 semantics).
  assert_verdict_inline \
    '[{"name":"build","state":"SUCCESS","bucket":"pass"},{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"lint","state":"IN_PROGRESS","bucket":"pending"}]' \
    red "S16-RT.5 — distinct-name mix keeps red-outranks-pending (dedupe is per-name only)"
  # S16-RT.6 — THE LAUNDERING REGRESSION (#302 review-trust finding): a completed
  # push `pass` next to its FAILED pull_request sibling of the SAME name must NOT
  # be laundered green. best-state-wins (pass > fail) would have folded this to
  # green and skipped MONITOR/CLASSIFY; drop-only-cancel keeps both rows, so the
  # fail survives → red. The pull_request (merge-commit) run is authoritative.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"},{"name":"shape-checks-windows","state":"FAILURE","bucket":"fail"}]' \
    red "S16-RT.6 — same-name fail+pass stays red (pass NEVER launders a failed sibling)"
  # S16-RT.7 — same-name pass+pending: the still-running pull_request sibling must
  # still gate via MONITOR. best-state-wins (pass > pending) would have fast-pathed
  # green in the ~30s window before the pull_request run finishes; drop-only-cancel
  # keeps the pending row → MONITOR.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"},{"name":"shape-checks-windows","state":"IN_PROGRESS","bucket":"pending"}]' \
    pending "S16-RT.7 — same-name pass+pending stays pending (in-flight sibling still gates → MONITOR)"
  # S16-RT.8 — fail-safe: an unknown/contract-broken bucket folds to red, never
  # silently green (the `else "red"` arm). A pass sibling does not launder it.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"WEIRD","bucket":"mystery"},{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.8 — unknown bucket folds to red (fail-safe; broken field contract never downgrades the gate)"
fi

echo
echo "== S17-RUNTIME: classifier REFUSED is terminal before routing =="
CLASSIFIER_STATUS_FIXTURE="$(mktemp)"
awk '/^[[:space:]]*review_apply_ci_classification_status\(\) \{/{active=1} active{print} active && /^[[:space:]]*\}/{exit}' \
  "$REVIEW_PR" >"$CLASSIFIER_STATUS_FIXTURE"
CLASSIFIER_STATUS_LOG="$(mktemp)"
CLASSIFIER_STATUS_OUTPUT="$(
  CLASSIFIER_STATUS_LOG="$CLASSIFIER_STATUS_LOG" bash -c '
    . "$1"
    audit(){ printf "audit:%s\n" "$*" >>"$CLASSIFIER_STATUS_LOG"; }
    route(){ printf "route\n" >>"$CLASSIFIER_STATUS_LOG"; }
    push(){ printf "push\n" >>"$CLASSIFIER_STATUS_LOG"; }
    trust(){ printf "trust\n" >>"$CLASSIFIER_STATUS_LOG"; }
    OUTCOME=unknown
    if review_apply_ci_classification_status REFUSED "bounded refusal"; then
      route; push; trust
    fi
    printf "%s" "$OUTCOME"
  ' _ "$CLASSIFIER_STATUS_FIXTURE"
)"
if [ "$CLASSIFIER_STATUS_OUTPUT" = halted ] \
  && grep -q 'subreason=classifier_refused' "$CLASSIFIER_STATUS_LOG" \
  && ! grep -Eq '^(route|push|trust)$' "$CLASSIFIER_STATUS_LOG"; then
  echo "  PASS  S17-RT — valid classifier REFUSED halts with audit and no route/push/trust"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S17-RT — classifier REFUSED crossed the terminal controller gate"
  FAIL=$((FAIL + 1))
fi
rm -f "$CLASSIFIER_STATUS_FIXTURE" "$CLASSIFIER_STATUS_LOG"

echo
echo "== S18: selected Actions run is derived, event-bound, and refreshed =="
assert_no_grep "$REVIEW_PR" 'CI_RUN_ID="\$\{CI_RUN_ID:-0\}"' \
  "S18.1 — setup never treats sentinel run id 0 as authority"
assert_grep "$REVIEW_PR" 'review_select_failed_ci_run' \
  "S18.2 — failed Actions run is selected from check metadata"
assert_grep "$REVIEW_PR" 'review_clear_ci_run_selection' \
  "S18.3 — run selection has an explicit clear operation"
assert_grep "$REVIEW_PR" 'actions/runs/\$CI_RUN_ID|actions/runs/\$\{CI_RUN_ID\}' \
  "S18.4 — controller reads immutable Actions run metadata"
assert_grep "$REVIEW_PR" 'pull_requests.*PR_NUMBER|PR_NUMBER.*pull_requests' \
  "S18.5 — pull_request authority is bound through PR association"
S18_CLEAR_CALLS="$(grep -c 'review_clear_ci_run_selection' "$REVIEW_PR" || true)"
if [ "$S18_CLEAR_CALLS" -ge 3 ]; then
  echo "  PASS  S18.6 — run selection is cleared at definition, probe, and head-changing re-entry"; PASS=$((PASS + 1))
else
  echo "  FAIL  S18.6 — run selection clear is not wired at both probe and re-entry (count=$S18_CLEAR_CALLS)"; FAIL=$((FAIL + 1))
fi

echo
echo "== S18-RUNTIME: synthetic merge SHA, unset id, unrelated run, and reselection fixtures =="
CI_AUTHORITY_FIXTURE="$(mktemp)"
for function_name in review_clear_ci_run_selection review_select_failed_ci_run review_capture_ci_classification_head; do
  awk -v wanted="$function_name" '
    $0 ~ "^[[:space:]]*" wanted "\\(\\) \\{" { active=1 }
    active { print }
    active && /^    \}$/ { exit }
  ' "$REVIEW_PR" >>"$CI_AUTHORITY_FIXTURE"
done

if ! grep -q '^    review_clear_ci_run_selection() {' "$CI_AUTHORITY_FIXTURE" \
    || ! grep -q '^    review_select_failed_ci_run() {' "$CI_AUTHORITY_FIXTURE" \
    || ! grep -q '^    review_capture_ci_classification_head() {' "$CI_AUTHORITY_FIXTURE"; then
  echo "  FAIL  S18-RT.0 — could not extract all CI authority helpers from review-pr.md"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S18-RT.0 — extracted CI authority helpers from review-pr.md"
  PASS=$((PASS + 1))

  # Default/unset CI_RUN_ID is non-authoritative: the failed check's exact
  # Actions URL supplies the positive run id and event.
  SELECTION_PROBE="$(_run_probe ci-checks-red)"
  unset CI_RUN_ID
  IFS=$'\t' read -r CI_RUN_ID CI_RUN_EVENT CI_RUN_CHECK_LINK < <(
    bash -c '. "$1"; review_select_failed_ci_run "$2" owner/repo' \
      _ "$CI_AUTHORITY_FIXTURE" "$SELECTION_PROBE"
  )
  if [ "$CI_RUN_ID" = 991 ] && [ "$CI_RUN_EVENT" = pull_request ] \
      && [ "$CI_RUN_CHECK_LINK" = "https://github.com/owner/repo/actions/runs/991/job/1012" ]; then
    echo "  PASS  S18-RT.1 — unset run id is derived from the selected failed check"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.1 — unset run id was not derived exactly (id=$CI_RUN_ID event=$CI_RUN_EVENT link=$CI_RUN_CHECK_LINK)"; FAIL=$((FAIL + 1))
  fi
  CI_RUN_ID=0
  IFS=$'\t' read -r CI_RUN_ID CI_RUN_EVENT CI_RUN_CHECK_LINK < <(
    bash -c '. "$1"; review_select_failed_ci_run "$2" owner/repo' \
      _ "$CI_AUTHORITY_FIXTURE" "$SELECTION_PROBE"
  )
  if [ "$CI_RUN_ID" = 991 ]; then
    echo "  PASS  S18-RT.2 — sentinel run id 0 is replaced by check metadata"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.2 — sentinel run id survived selection (id=$CI_RUN_ID)"; FAIL=$((FAIL + 1))
  fi

  # A failed check URL from another repository is never accepted as the current
  # PR's Actions authority.
  UNRELATED_PROBE='[{"name":"test","state":"FAILURE","bucket":"fail","event":"pull_request","link":"https://github.com/other/repo/actions/runs/777/job/1","workflow":"Tests"}]'
  if bash -c '. "$1"; review_select_failed_ci_run "$2" owner/repo' \
      _ "$CI_AUTHORITY_FIXTURE" "$UNRELATED_PROBE" >/dev/null 2>&1; then
    echo "  FAIL  S18-RT.3 — unrelated repository run was selected"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  S18-RT.3 — unrelated repository run fails closed"; PASS=$((PASS + 1))
  fi

  run_capture_fixture() {
    local run_event="$1" run_json="$2" expected_head="${3:-}"
    local local_head="${4:-0123456789012345678901234567890123456789}"
    local live_head="${5:-$local_head}"
    CI_CAPTURE_RUN_EVENT="$run_event" CI_CAPTURE_RUN_JSON="$run_json" \
      CI_CAPTURE_EXPECTED_HEAD="$expected_head" CI_CAPTURE_LOCAL_HEAD="$local_head" \
      CI_CAPTURE_LIVE_HEAD="$live_head" \
      bash -c '
        . "$1"
        PR_NUMBER=73
        REVIEW_REPO_SLUG=owner/repo
        WORKTREE_ROOT=/worktree
        CI_RUN_ID=991
        CI_RUN_EVENT="$CI_CAPTURE_RUN_EVENT"
        LOCAL_HEAD="$CI_CAPTURE_LOCAL_HEAD"
        LIVE_HEAD="$CI_CAPTURE_LIVE_HEAD"
        LIVE_BRANCH=feature/current
        git() {
          [ "$1" = -C ] && [ "$2" = "$WORKTREE_ROOT" ] \
            && [ "$3" = rev-parse ] && [ "$4" = HEAD ] || return 2
          printf "%s\n" "$LOCAL_HEAD"
        }
        gh() {
          if [ "$1" = pr ] && [ "$2" = view ]; then
            printf "%s\t%s\n" "$LIVE_HEAD" "$LIVE_BRANCH"
            return 0
          fi
          if [ "$1" = api ] && [ "$2" = "repos/$REVIEW_REPO_SLUG/actions/runs/$CI_RUN_ID" ]; then
            printf "%s\n" "$CI_CAPTURE_RUN_JSON"
            return 0
          fi
          return 2
        }
        review_capture_ci_classification_head "$CI_CAPTURE_EXPECTED_HEAD"
      ' _ "$CI_AUTHORITY_FIXTURE"
  }

  SYNTHETIC_MERGE_JSON='{"id":991,"event":"pull_request","head_sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","head_branch":"feature/current","repository":{"full_name":"owner/repo"},"pull_requests":[{"number":73,"head":{"sha":"0123456789012345678901234567890123456789","ref":"feature/current"}}]}'
  SYNTHETIC_RESULT="$(run_capture_fixture pull_request "$SYNTHETIC_MERGE_JSON")"
  if [ "$SYNTHETIC_RESULT" = 0123456789012345678901234567890123456789 ]; then
    echo "  PASS  S18-RT.4 — authoritative pull_request accepts synthetic merge headSha via PR association"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.4 — synthetic merge headSha was rejected ($SYNTHETIC_RESULT)"; FAIL=$((FAIL + 1))
  fi

  UNRELATED_RUN_JSON='{"id":991,"event":"pull_request","head_sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","head_branch":"feature/other","repository":{"full_name":"owner/repo"},"pull_requests":[{"number":74,"head":{"sha":"0123456789012345678901234567890123456789","ref":"feature/other"}}]}'
  set +e
  UNRELATED_RESULT="$(run_capture_fixture pull_request "$UNRELATED_RUN_JSON")"
  UNRELATED_RC=$?
  set -e
  if [ "$UNRELATED_RC" -ne 0 ] && [ "$UNRELATED_RESULT" = classification_run_pr_mismatch ]; then
    echo "  PASS  S18-RT.5 — unrelated pull_request run fails closed"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.5 — unrelated pull_request run crossed the authority gate (rc=$UNRELATED_RC result=$UNRELATED_RESULT)"; FAIL=$((FAIL + 1))
  fi

  PUSH_STALE_JSON='{"id":991,"event":"push","head_sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","head_branch":"feature/current","repository":{"full_name":"owner/repo"},"pull_requests":[]}'
  set +e
  PUSH_STALE_RESULT="$(run_capture_fixture push "$PUSH_STALE_JSON")"
  PUSH_STALE_RC=$?
  set -e
  if [ "$PUSH_STALE_RC" -ne 0 ] && [ "$PUSH_STALE_RESULT" = classification_run_head_mismatch ]; then
    echo "  PASS  S18-RT.6 — stale push run still requires direct branch-SHA equality"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.6 — stale push run crossed the direct equality gate (rc=$PUSH_STALE_RC result=$PUSH_STALE_RESULT)"; FAIL=$((FAIL + 1))
  fi

  ORIGINAL_HEAD=0123456789012345678901234567890123456789
  MOVED_HEAD=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  LOCAL_MOVE_RESULT="$(run_capture_fixture pull_request "$SYNTHETIC_MERGE_JSON" "$ORIGINAL_HEAD" "$MOVED_HEAD" "$ORIGINAL_HEAD")" || true
  LIVE_MOVE_RESULT="$(run_capture_fixture pull_request "$SYNTHETIC_MERGE_JSON" "$ORIGINAL_HEAD" "$ORIGINAL_HEAD" "$MOVED_HEAD")" || true
  MOVED_ASSOCIATION_JSON='{"id":991,"event":"pull_request","head_sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","head_branch":"feature/current","repository":{"full_name":"owner/repo"},"pull_requests":[{"number":73,"head":{"sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","ref":"feature/current"}}]}'
  ASSOCIATION_MOVE_RESULT="$(run_capture_fixture pull_request "$MOVED_ASSOCIATION_JSON" "$ORIGINAL_HEAD")" || true
  if [ "$LOCAL_MOVE_RESULT" = classification_local_head_moved ] \
      && [ "$LIVE_MOVE_RESULT" = classification_live_head_moved ] \
      && [ "$ASSOCIATION_MOVE_RESULT" = classification_run_pr_moved ]; then
    echo "  PASS  S18-RT.7 — route-time local, live, and PR-association moves remain fail-closed"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.7 — route-time authority move escaped (local=$LOCAL_MOVE_RESULT live=$LIVE_MOVE_RESULT association=$ASSOCIATION_MOVE_RESULT)"; FAIL=$((FAIL + 1))
  fi

  # A head-changing push clears the old tuple, and the next probe selects the
  # new run rather than recycling the prior id.
  RESELECT_PROBE='[{"name":"test","state":"FAILURE","bucket":"fail","event":"pull_request","link":"https://github.com/owner/repo/actions/runs/992/job/1022","workflow":"Tests"}]'
  RESELECT_RESULT="$(
    bash -c '
      . "$1"
      CI_RUN_ID=991
      CI_RUN_EVENT=pull_request
      CI_RUN_CHECK_LINK=https://github.com/owner/repo/actions/runs/991/job/1012
      review_clear_ci_run_selection
      [ -z "$CI_RUN_ID$CI_RUN_EVENT$CI_RUN_CHECK_LINK" ] || exit 3
      review_select_failed_ci_run "$2" owner/repo
    ' _ "$CI_AUTHORITY_FIXTURE" "$RESELECT_PROBE"
  )"
  if [ "$RESELECT_RESULT" = $'992\tpull_request\thttps://github.com/owner/repo/actions/runs/992/job/1022' ]; then
    echo "  PASS  S18-RT.8 — post-push re-entry clears and reselects the new run"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.8 — post-push selection reused stale authority ($RESELECT_RESULT)"; FAIL=$((FAIL + 1))
  fi
fi
rm -f "$CI_AUTHORITY_FIXTURE"

echo
echo "== S19-RUNTIME: post-MONITOR refresh failure cannot downgrade observed red =="
POST_MONITOR_REFRESH_FIXTURE="$(mktemp)"
awk '
  /^    On a `red` MONITOR verdict, refresh the check projection before$/ { section=1 }
  section && /^    ```bash$/ { code=1; next }
  code && /^    ```$/ { exit }
  code {
    sub(/^    /, "")
    print
  }
' "$REVIEW_PR" >"$POST_MONITOR_REFRESH_FIXTURE"
POST_MONITOR_REFRESH_LOG="$(mktemp)"
set +e
POST_MONITOR_REFRESH_OUTPUT="$(
  POST_MONITOR_REFRESH_LOG="$POST_MONITOR_REFRESH_LOG" bash -c '
    audit(){ printf "%s\n" "$*" >>"$POST_MONITOR_REFRESH_LOG"; }
    gh(){
      printf "post-monitor metadata refresh unavailable\n" >&2
      return 1
    }
    PR_NUMBER=73
    OUTCOME=red
    trap '\''printf "outcome=%s\n" "$OUTCOME" >>"$POST_MONITOR_REFRESH_LOG"'\'' EXIT
    . "$1"
    printf "continued\n" >>"$POST_MONITOR_REFRESH_LOG"
  ' _ "$POST_MONITOR_REFRESH_FIXTURE"
)"
POST_MONITOR_REFRESH_RC=$?
set -e
if grep -q '^unset PROBE_RC$' "$POST_MONITOR_REFRESH_FIXTURE" \
    && [ "$POST_MONITOR_REFRESH_RC" -ne 0 ] \
    && grep -qxF 'ci_phase_outcome outcome=halted subreason=post_monitor_refresh_failed' \
      "$POST_MONITOR_REFRESH_LOG" \
    && grep -qxF 'outcome=halted' "$POST_MONITOR_REFRESH_LOG" \
    && ! grep -q 'ci_probe_unreachable' "$POST_MONITOR_REFRESH_LOG" \
    && ! grep -qxF 'continued' "$POST_MONITOR_REFRESH_LOG"; then
  echo "  PASS  S19-RT — post-MONITOR refresh failure preserves red as terminal halted"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S19-RT — post-MONITOR refresh failure downgraded observed red"
  echo "        rc: $POST_MONITOR_REFRESH_RC"
  echo "        output: $POST_MONITOR_REFRESH_OUTPUT"
  echo "        log: $(tr '\n' ' ' <"$POST_MONITOR_REFRESH_LOG")"
  FAIL=$((FAIL + 1))
fi
rm -f "$POST_MONITOR_REFRESH_FIXTURE" "$POST_MONITOR_REFRESH_LOG"

echo
echo "== S20-RUNTIME: direct bounded classifier-log stream =="
CI_LOG_STREAM_FIXTURE="$(mktemp)"
awk -v wanted="review_capture_ci_log_authority" '
  $0 ~ "^[[:space:]]*" wanted "\\(\\) \\{" { active=1 }
  active && /^    if CI_LOG_AUTHORITY_JSON=/ { exit }
  active { print }
' "$REVIEW_PR" >"$CI_LOG_STREAM_FIXTURE"

run_ci_log_stream_fixture() {
  local mode="$1"
  CI_LOG_STREAM_MODE="$mode" bash -c '
    . "$1"
    REVIEW_REPO_SLUG=owner/repo
    PR_NUMBER=73
    CI_RUN_ID=991
    CI_CLASSIFICATION_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
    gh() {
      [ "$#" -eq 6 ] \
        && [ "$1" = run ] \
        && [ "$2" = view ] \
        && [ "$3" = "$CI_RUN_ID" ] \
        && [ "$4" = --repo ] \
        && [ "$5" = "$REVIEW_REPO_SLUG" ] \
        && [ "$6" = --log-failed ] || return 97
      case "$CI_LOG_STREAM_MODE" in
        valid) printf "original & <failed assertion>\n" ;;
        gh-error) printf "partial failed log\n"; return 1 ;;
        invalid-utf8) printf "\377" ;;
        oversize) python3 -I -B -c '\''import sys; sys.stdout.write("x"*49153)'\'' ;;
        *) return 98 ;;
      esac
    }
    review_capture_ci_log_authority
  ' _ "$CI_LOG_STREAM_FIXTURE"
}

if ! grep -Eq 'capture_path|capture_receipt|created_identity|secure_capture_regular|os\.(open|lstat)' \
      "$CI_LOG_STREAM_FIXTURE" \
    && grep -q -- '--log-failed' "$CI_LOG_STREAM_FIXTURE" \
    && grep -q 'set -o pipefail' "$CI_LOG_STREAM_FIXTURE"; then
  echo "  PASS  S20-RT.1 — one pipefail-protected transformer has no named producer identity to mutate"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.1 — classifier capture still exposes a named mutable producer boundary"
  FAIL=$((FAIL + 1))
fi

if ! grep -Eq 'os\.unlink|unlink\(' "$CI_LOG_STREAM_FIXTURE"; then
  echo "  PASS  S20-RT.2 — classifier capture has no pathname unlink replacement race"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.2 — classifier capture still deletes through a mutable pathname"
  FAIL=$((FAIL + 1))
fi

set +e
CI_LOG_VALID_RESULT="$(run_ci_log_stream_fixture valid)"
CI_LOG_VALID_RC=$?
set -e
if [ "$CI_LOG_VALID_RC" -eq 0 ] && python3 -I -B - "$CI_LOG_VALID_RESULT" <<'PY'
import hashlib,json,sys
value=json.loads(sys.argv[1])
expected='<external-untrusted-input source="github-actions-log-pr-73-run-991">\noriginal &amp; &lt;failed assertion>\n</external-untrusted-input>\n'
assert value=={
    'head_sha':'0123456789abcdef0123456789abcdef01234567',
    'log_content':expected,
    'log_sha256':hashlib.sha256(expected.encode()).hexdigest(),
    'pr_number':73,
    'run_id':'991',
}
assert len(json.dumps(value,sort_keys=True,separators=(',',':')).encode())<=49152
PY
then
  echo "  PASS  S20-RT.3 — transformer emits exact canonical identity, envelope bytes, and digest"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.3 — valid failed-log stream did not produce canonical authority JSON"
  echo "        rc: $CI_LOG_VALID_RC"
  FAIL=$((FAIL + 1))
fi

set +e
CI_LOG_GH_ERROR_RESULT="$(run_ci_log_stream_fixture gh-error)"
CI_LOG_GH_ERROR_RC=$?
CI_LOG_UTF8_RESULT="$(run_ci_log_stream_fixture invalid-utf8)"
CI_LOG_UTF8_RC=$?
CI_LOG_OVERSIZE_RESULT="$(run_ci_log_stream_fixture oversize)"
CI_LOG_OVERSIZE_RC=$?
set -e
if [ "$CI_LOG_GH_ERROR_RC" -ne 0 ]; then
  echo "  PASS  S20-RT.4 — upstream gh failure fails the pipe closed"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.4 — upstream gh failure produced accepted authority"
  FAIL=$((FAIL + 1))
fi
if [ "$CI_LOG_UTF8_RC" -ne 0 ] \
    && [ "$CI_LOG_UTF8_RESULT" = classification_log_capture_invalid ]; then
  echo "  PASS  S20-RT.5 — invalid UTF-8 stream fails closed"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.5 — invalid UTF-8 stream escaped the transformer"
  FAIL=$((FAIL + 1))
fi
if [ "$CI_LOG_OVERSIZE_RC" -ne 0 ] \
    && [ "$CI_LOG_OVERSIZE_RESULT" = classification_log_input_oversize ]; then
  echo "  PASS  S20-RT.6 — oversized stream fails before authority publication"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S20-RT.6 — oversized stream escaped the immutable input ceiling"
  FAIL=$((FAIL + 1))
fi
rm -f "$CI_LOG_STREAM_FIXTURE"

# ---------------------------------------------------------------------------
# S21-S23 (#383) — the Workflow-native Phase 3 stage machine
# ---------------------------------------------------------------------------
echo "== S21: the ROUTE stage machine =="
assert_grep "$REVIEW_PR" 'CI_FIXER_EDGE_ID=review_pr\.ci\.fix_code' \
  "S21.1 — code_bug/env_drift routes to the fix_code edge"
assert_grep "$REVIEW_PR" 'CI_FIXER_EDGE_ID=review_pr\.ci\.rebase' \
  "S21.2 — stale_base routes to the rebase edge"
assert_grep "$REVIEW_PR" 'gh run rerun "\$CI_RUN_ID"' \
  "S21.3 — the flaky arm re-runs in Bash with the REAL run id"
assert_no_grep "$REVIEW_PR" 'gh run rerun <run-id>' \
  "S21.4 — the literal <run-id> placeholder that made the ROUTE fence unexecutable is gone"
assert_no_grep "$REVIEW_PR" 'jump to 6c\.6 HALT' \
  "S21.5 — the prose-inside-a-case that was a syntax error is gone"
assert_grep "$REVIEW_PR" 'stage=ci-classify' \
  "S21.6 — CLASSIFY is a Workflow stage"
assert_grep "$REVIEW_PR" 'stage=ci-fix' \
  "S21.7 — the routed fixer is a Workflow stage"
assert_grep "$REVIEW_PR" 'stage=ci-defer' \
  "S21.8 — the CI-REFUSED defer is a Workflow stage"
# The forward-reference bug: base_branch was bound only in the CONFLICT arm,
# which runs strictly AFTER ROUTE, so ROUTE either aborted under set -u or
# silently resolved `origin/` to nothing and poisoned base_sha.
# Comment-strip first: the ROUTE fence NAMES the old expression in order to
# record the bug, and a guard that punished the explanation would be unfixable.
REVIEW_PR_LIVE="$(grep -v '^[[:space:]]*#' "$REVIEW_PR")"
if grep -q 'git merge-base HEAD "origin/${base_branch}"' <<<"$REVIEW_PR_LIVE"; then
  echo "  FAIL  S21.9 — the forward-referenced base_branch merge-base is still live"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S21.9 — the forward-referenced base_branch merge-base is gone"; PASS=$((PASS + 1))
fi
assert_grep "$REVIEW_PR" 'CI_BASE_SHA=.*merge-base' \
  "S21.10 — the base SHA is derived from refs bound in the SAME fence"

echo "== S22: the rebase lease is controller-held =="
assert_grep "$REVIEW_PR" 'force-with-lease="\$CI_PR_HEAD_BRANCH":"\$CI_LEASE_SHA"' \
  "S22.1 — explicit-form lease against the PR head branch"
assert_grep "$REVIEW_PR" 'force-if-includes' \
  "S22.2 — paired with --force-if-includes"
# The bare shorthand uses @{upstream} and is forbidden; so is bare --force.
# Only EXECUTABLE lines: the prose deliberately names the forbidden shorthand in
# order to forbid it. A push line must carry the explicit `<branch>:<sha>` form.
# Executable push lines only: leading `git push` or a `git -C <dir> push`, never
# a prose sentence that merely mentions one (the trust-anchor section explains
# that it NEVER needs --force-with-lease, and that sentence must stay sayable).
PUSH_LINES="$(grep -E '^[[:space:]]*([A-Z_]+="\$\()?git( -C "[^"]+")? push ' \
  <<<"$REVIEW_PR_LIVE" || true)"
if grep -qE '\-\-force-with-lease([^=]|$)' <<<"$PUSH_LINES"; then
  echo "  FAIL  S22.3 — a bare --force-with-lease (the @{upstream} shorthand) reached a push command"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S22.3 — every --force-with-lease on a push carries an explicit <branch>:<sha>"; PASS=$((PASS + 1))
fi
if grep -qE '\-\-force([^-]|$)' <<<"$PUSH_LINES"; then
  echo "  FAIL  S22.4 — a bare --force push reached the command"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S22.4 — no bare --force push anywhere in the command"; PASS=$((PASS + 1))
fi

echo "== S22-RUNTIME: the lease really refuses a stale push (offline, two local repos) =="
LEASE_TMP="$(mktemp -d)"
LEASE_TMP="$(cd "$LEASE_TMP" && pwd -P)"
(
  set -e
  git init -q --bare "$LEASE_TMP/origin.git"
  git clone -q "$LEASE_TMP/origin.git" "$LEASE_TMP/work" 2>/dev/null
  cd "$LEASE_TMP/work"
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git checkout -qb feature 2>/dev/null || git checkout -q -b feature
  printf 'one\n' >file.txt
  git add file.txt
  git commit -qm "test: base"
  git push -q origin feature
) >/dev/null 2>&1
LEASE_SHA="$(git -C "$LEASE_TMP/work" rev-parse refs/remotes/origin/feature 2>/dev/null)"
# Case 1: a correctly captured lease pushes.
(
  cd "$LEASE_TMP/work"
  printf 'two\n' >file.txt
  git add file.txt
  git commit -qm "fix(ci): amend"
) >/dev/null 2>&1
LEASE_PUSH_STDERR="$(git -C "$LEASE_TMP/work" push origin feature \
  --force-with-lease=feature:"$LEASE_SHA" --force-if-includes 2>&1 1>/dev/null)"
LEASE_PUSH_RC=$?
# Case 2: a third party pushes behind the runner's back, so the captured lease
# is now stale. The SAME fence must fail, and its stderr must match the
# classifier that distinguishes rebase_lease_mismatch from rebase_push_failed.
(
  set -e
  git clone -q "$LEASE_TMP/origin.git" "$LEASE_TMP/other" 2>/dev/null
  cd "$LEASE_TMP/other"
  git config user.email other@example.invalid
  git config user.name Other
  git checkout -q feature
  printf 'three\n' >file.txt
  git add file.txt
  git commit -qm "fix: external"
  git push -q origin feature
) >/dev/null 2>&1
(
  cd "$LEASE_TMP/work"
  printf 'four\n' >file.txt
  git add file.txt
  git commit -qm "fix(ci): racing"
) >/dev/null 2>&1
STALE_PUSH_STDERR="$(git -C "$LEASE_TMP/work" push origin feature \
  --force-with-lease=feature:"$LEASE_SHA" --force-if-includes 2>&1 1>/dev/null)" \
  && STALE_PUSH_RC=0 || STALE_PUSH_RC=$?
# git writes its progress banner to stderr on success, so only the RC is
# meaningful for the happy case.
if [ "$LEASE_PUSH_RC" -eq 0 ] && [ "${STALE_PUSH_RC:-0}" -ne 0 ]; then
  echo "  PASS  S22-RT.1 — a correct lease pushes and a stale lease is rejected by git itself"; PASS=$((PASS + 1))
else
  echo "  FAIL  S22-RT.1 — lease behaviour drifted (ok_rc=$LEASE_PUSH_RC stale_rc=${STALE_PUSH_RC:-0})"; FAIL=$((FAIL + 1))
fi
if grep -qE '\[rejected\].*(stale info|fetch first|non-fast-forward)' <<<"$STALE_PUSH_STDERR"; then
  echo "  PASS  S22-RT.2 — the stale-lease stderr matches the command's rebase_lease_mismatch classifier"; PASS=$((PASS + 1))
else
  echo "  FAIL  S22-RT.2 — stale-lease stderr would mis-route to rebase_push_failed: $STALE_PUSH_STDERR"; FAIL=$((FAIL + 1))
fi
rm -rf "$LEASE_TMP"

echo "== S23: re-entry never re-mints RUN_ID, and BOTH counters advance =="
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_write_ci_state\(\)' \
  "S23.1 — the CI loop counters have an on-disk home"
assert_grep "$REVIEW_PR" 'review_fleet_read_ci_state "\$CI_LOOP_STATE" ci_loop_iter' \
  "S23.2 — the re-entry fence reads the counter back from disk"
# REVIEW_ITERATION advances ONLY when Phase 1 actually re-runs, so it keeps its
# single site. CI_FIX_LOOP_ITER now has TWO, because the multi-stage-rebase
# restage is a loop iteration too — the arm's own comment always said it was
# "bounded by CI_FIX_LOOP_CAP", and nothing advanced the counter, so wave 2
# recomputed wave 1's authority pathname and died on `authority_preexists`.
# The invariant that replaces "exactly one site" is: EVERY site that advances
# the counter must also cap-check it and persist it, or the next fresh shell
# reads the old value back and the advance never happened.
REVIEW_ITER_INCREMENTS="$(grep -c 'REVIEW_ITERATION=\$((REVIEW_ITERATION + 1))' "$REVIEW_PR")"
if [ "$REVIEW_ITER_INCREMENTS" = 1 ]; then
  echo "  PASS  S23.3 — exactly ONE site increments REVIEW_ITERATION (it tracks Phase 1 re-runs)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S23.3 — REVIEW_ITERATION increment sites: $REVIEW_ITER_INCREMENTS (want 1)"; FAIL=$((FAIL + 1))
fi
# Every CI_FIX_LOOP_ITER advance, in its own fence, followed by a cap check and
# an on-disk write. Checked per fence so a site that skipped either is named.
CI_ITER_FENCE_REPORT="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "CI_FIX_LOOP_ITER=$((") > 0) {
      sites += 1
      if (index(buf, "-gt 3") > 0 && index(buf, "review_fleet_write_ci_state") > 0) good += 1
    }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { printf "%d %d", sites, good }
' "$REVIEW_PR")"
CI_ITER_SITES="${CI_ITER_FENCE_REPORT% *}"
CI_ITER_GOOD="${CI_ITER_FENCE_REPORT#* }"
if [ "$CI_ITER_SITES" -ge 2 ] && [ "$CI_ITER_SITES" = "$CI_ITER_GOOD" ]; then
  echo "  PASS  S23.3b — all $CI_ITER_SITES CI_FIX_LOOP_ITER advance sites cap-check AND persist"; PASS=$((PASS + 1))
else
  echo "  FAIL  S23.3b — $CI_ITER_SITES advance site(s), only $CI_ITER_GOOD cap-check and persist"; FAIL=$((FAIL + 1))
fi
assert_grep "$REVIEW_PR" 'rebase_conflict_restage_cap' \
  "S23.3c — the restage path has its own cap terminal (it is not an unbounded re-entry)"
# THE TRAP THIS CLOSES: childDirAbs() keys on reviewIteration ALONE. Without the
# lockstep increment, iteration 2 rebinds iteration 1's result.md paths and the
# capture verbs freeze STALE bytes while every equality still passes.
# EXECUTABLE lines only, inside the Phase 3 byte range: the re-entry prose names
# both identifiers precisely in order to explain why neither may run again.
PHASE3_SLICE="$(awk '
  /^6c\. \*\*Phase 3 — CI Health\*\*/ { inphase = 1 }
  /^### Phase 3 audit JSON shape/ { if (inphase) exit }
  inphase && /^[ \t]*```bash/ { fence = 1; next }
  inphase && fence && /^[ \t]*```[ \t]*$/ { fence = 0; next }
  inphase && fence { print }
' "$REVIEW_PR")"
if grep -qE 'REVIEW_RUN_ID_REQUEST|review_reserve_run_directory' <<<"$PHASE3_SLICE"; then
  echo "  FAIL  S23.4 — Phase 3 re-mints RUN_ID; the evidence directory would fork mid-run"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S23.4 — Phase 3 never re-mints RUN_ID (re-entry goes to Step 4, not Step 1)"; PASS=$((PASS + 1))
fi

echo "== S23-RUNTIME: the counters survive a FRESH shell with a cleared environment =="
CI_STATE_TMP="$(mktemp -d)"
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci.json" 3 2 "[]" "[\"code_bug\"]"' \
  _ "$ARGS_LIB_PHASE3" "$CI_STATE_TMP" >/dev/null 2>&1
# env -i: an env-passing probe would MASK the whole class this exists to catch.
CI_STATE_READBACK="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_read_ci_state "$2/ci.json" ci_loop_iter' \
  _ "$ARGS_LIB_PHASE3" "$CI_STATE_TMP" 2>/dev/null)"
if [ "$CI_STATE_READBACK" = 3 ]; then
  echo "  PASS  S23-RT.1 — the cap check reads 3 in a shell that inherited nothing"; PASS=$((PASS + 1))
else
  echo "  FAIL  S23-RT.1 — the loop counter did not survive a fresh shell: '$CI_STATE_READBACK'"; FAIL=$((FAIL + 1))
fi
rm -rf "$CI_STATE_TMP"

echo "== S24: ONE push site, reachable from every terminal, self-contained =="
# The bug this block exists over: `ci-code-fixer` and `ci-rebase-handler` were
# BOTH demoted to preparers (neither has a remote-write tool), and the only
# `git push` in Phase 3 sat inside the CONFLICT-RESOLVE arm. So the two common
# terminals — a clean rebase and an APPLIED code fix — produced local commits
# that nothing published, the next 6c.1 PROBE re-derived the same red run off an
# unchanged remote head, and the loop burned to loop_cap_exhausted. The headline
# capability of the phase was absent while the prose claimed it was wired.
PHASE3_FENCES="$(awk '
  /^6c\. \*\*Phase 3 — CI Health\*\*/ { inphase = 1 }
  /^### Phase 3 audit JSON shape/ { if (inphase) exit }
  inphase && /^[ \t]*```bash/ { fence = 1; next }
  inphase && fence && /^[ \t]*```[ \t]*$/ { fence = 0; next }
  inphase && fence { print }
' "$REVIEW_PR")"
PHASE3_PUSH_SITES="$(grep -cE '^[^#]*git .*[^-]push ' <<<"$PHASE3_FENCES")"
if [ "$PHASE3_PUSH_SITES" = 1 ]; then
  echo "  PASS  S24.1 — Phase 3 has EXACTLY one executable push site"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.1 — Phase 3 has $PHASE3_PUSH_SITES executable push sites (want exactly 1)"; FAIL=$((FAIL + 1))
fi
if grep -qE 'push origin "\$\{NEW_HEAD_SHA\}:refs/heads/\$\{CI_PR_HEAD_BRANCH\}"' <<<"$PHASE3_FENCES"; then
  echo "  PASS  S24.2 — the push names an explicit SHA and an explicit ref, never symbolic HEAD"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.2 — the Phase 3 push does not publish an explicit sha:ref pair"; FAIL=$((FAIL + 1))
fi
assert_grep "$REVIEW_PR" '6c\.4w\.3' \
  "S24.3 — the single leased push is a NAMED step both fix arms can route to"
# Reachability, per terminal. A push nothing reaches is the bug this block is
# about, so each producing terminal must name the step by number.
for terminal in APPLIED REBASED; do
  if grep -qE "CI_FIXER_TERMINAL_STATUS=$terminal\b[^\`]*(\`|.)*6c\.4w\.3" "$REVIEW_PR"; then
    echo "  PASS  S24.4[$terminal] — the $terminal terminal routes to 6c.4w.3"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S24.4[$terminal] — the $terminal terminal does not route to the push step"; FAIL=$((FAIL + 1))
  fi
done
# The push fence must be SELF-CONTAINED: a fresh harness shell inherits nothing,
# and a lease read from an unset $CI_AUTHORITY_PATH degrades to
# `--force-with-lease=":"` against `origin ""`.
PUSH_FENCE="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "--force-with-lease=") > 0) { printf "%s", buf; found = 1; exit }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "$REVIEW_PR")" || PUSH_FENCE=""
PUSH_SELF_CONTAINED=ok
for token in 'review_fleet_read_sidecar' 'read-ci-authority-member' \
             'review_fleet_load_ci_counters' 'review_ci_push_abort()' \
             'review_fleet_read_ci_pointer' 'rev-parse HEAD'; do
  grep -qF -- "$token" <<<"$PUSH_FENCE" \
    || PUSH_SELF_CONTAINED="missing:$token"
done
if [ "$PUSH_SELF_CONTAINED" = ok ]; then
  echo "  PASS  S24.5 — the push fence re-derives binding, lease, branch, counters and HEAD itself"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.5 — the push fence depends on a dead shell ($PUSH_SELF_CONTAINED)"; FAIL=$((FAIL + 1))
fi
# ...and it must REFUSE an empty lease rather than force-push against nothing.
if grep -qF 'ci_authority_unreadable' <<<"$PUSH_FENCE"; then
  echo "  PASS  S24.6 — an unreadable/empty lease or branch halts instead of pushing"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.6 — the push fence does not refuse an empty lease"; FAIL=$((FAIL + 1))
fi
# The staged set: `git add --` with ZERO pathspecs exits 0 and stages nothing,
# so the `|| abort` guard is silent. The list must come off disk in the SAME
# fence that stages it.
STAGE_FENCE="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "add -- \"${conflicted_files[@]}\"") > 0) { printf "%s", buf; found = 1; exit }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "$REVIEW_PR")" || STAGE_FENCE=""
if grep -qF 'CONFLICT_PATHS_FILE' <<<"$STAGE_FENCE" \
   && grep -qF 'conflicted_files+=(' <<<"$STAGE_FENCE"; then
  echo "  PASS  S24.7 — the staging fence rebuilds conflicted_files from the on-disk list"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.7 — git add reads a shell array built in a different fence (stages nothing, exits 0)"; FAIL=$((FAIL + 1))
fi
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_write_conflict_paths\(\)' \
  "S24.8 — the conflicted-file set has an on-disk home"
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_write_ci_push\(\)' \
  "S24.9 — the pushed sha/agent pair has an on-disk home"
# 6c.4 ROUTE and 6c.4w.1 are different shells too. Every ROUTE scalar the mint
# fence consumes must land in something that FAILS CLOSED on an empty value —
# prepare-ci-authority's required-member table for most of them, and an explicit
# guard for the two it does not see.
MINT_FENCE="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "review_fleet_bind_ci \"$CI_FIXER_EDGE_ID\"") > 0) { printf "%s", buf; found = 1; exit }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "$REVIEW_PR")" || MINT_FENCE=""
# The guard's own case WORD must carry `${…:-}`. Under `set -u` the word is
# expanded BEFORE any arm is selected, so a bare `"$CI_FIXER_SLUG_BASE"` killed
# the fence with a raw unbound-variable message in exactly the case the `*)` arm
# documents — the guard could never fire for the value it exists to catch.
if grep -qF 'case "${CI_FIXER_SLUG_BASE:-}" in' <<<"$MINT_FENCE" \
   && grep -qF 'ci_fix_dispatch_slug_base_invalid' <<<"$MINT_FENCE"; then
  echo "  PASS  S24.10 — a lost CI_FIXER_SLUG_BASE halts instead of splitting the child directory"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.10 — CI_FIXER_SLUG_BASE is unchecked (or its case word is a bare expansion that dies under set -u)"; FAIL=$((FAIL + 1))
fi
if grep -qF "\${CI_FIXER_INPUTS:-}\" | jq -e 'type == \"object\"'" <<<"$MINT_FENCE"; then
  echo "  PASS  S24.11 — a lost CI_FIXER_INPUTS halts before it is pinned by digest as garbage"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.11 — CI_FIXER_INPUTS is written and digested without a set-u-safe shape check"; FAIL=$((FAIL + 1))
fi
# ...and the SAME guard on the FIRST Phase 3 stage, which shipped without one.
# `digest --minimum 1` accepts a lone newline, so an unset CI_CLASSIFY_INPUTS
# was pinned as garbage and `prepare-ci-authority` then died
# `ci_authority_invalid` rc=74 with NO audit event — the precise failure mode
# the counter fix removed everywhere else. Its two siblings both fail closed.
CLASSIFY_MINT_FENCE="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "review_fleet_bind_ci review_pr.ci.classify") > 0) { printf "%s", buf; found = 1; exit }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "$REVIEW_PR")" || CLASSIFY_MINT_FENCE=""
if grep -qF "\${CI_CLASSIFY_INPUTS:-}\" | jq -e 'type == \"object\"'" <<<"$CLASSIFY_MINT_FENCE" \
   && grep -qF 'classification_inputs_invalid' <<<"$CLASSIFY_MINT_FENCE"; then
  echo "  PASS  S24.11b — a lost CI_CLASSIFY_INPUTS halts with an audit event, like both siblings"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.11b — the classify mint fence writes and digests its inputs unchecked"; FAIL=$((FAIL + 1))
fi
# ...and the lease/branch half must be enforced by the CONTRACT, at mint, for
# BOTH mutating arms — not by prose asking the fence to remember them.
assert_grep "$CONTRACT_PY" '"review_pr\.ci\.fix_code": \("failure_class", "signal_anchor", "parent_sha",' \
  "S24.12 — the fix_code authority has a required-member list"
if python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cfc", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["cfc"] = m
spec.loader.exec_module(m)
for edge in ("review_pr.ci.fix_code", "review_pr.ci.rebase"):
    required = m.CI_AUTHORITY_REQUIRED_MEMBERS[edge]
    assert "lease_sha" in required and "pr_branch" in required, (edge, required)
' "$CONTRACT_PY" 2>/dev/null; then
  echo "  PASS  S24.13 — BOTH mutating arms refuse at mint without a lease and a branch"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24.13 — a mutating CI authority can be minted with no lease, then reach 6c.4w.3"; FAIL=$((FAIL + 1))
fi

echo "== S24-RUNTIME: the cross-fence records survive a shell that inherited nothing =="
S24_TMP="$(mktemp -d)"
# A path with a SPACE and one with a NEWLINE: git reports both, and a
# newline-split handoff silently truncates the set it is about to stage.
bash -c '. "$1"; review_fleet_write_conflict_paths "$2/paths.zlist" "src/a b.py" "src/plain.py"' \
  _ "$ARGS_LIB_PHASE3" "$S24_TMP" >/dev/null 2>&1
S24_READBACK="$(env -i PATH="$PATH" bash -c '
  count=0
  while IFS= read -r -d "" p; do count=$((count + 1)); last="$p"; done <"$1/paths.zlist"
  printf "%s|%s" "$count" "$last"' _ "$S24_TMP" 2>/dev/null)"
if [ "$S24_READBACK" = '2|src/plain.py' ]; then
  echo "  PASS  S24-RT.1 — the conflicted-path list round-trips (space-bearing path intact)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24-RT.1 — conflicted-path handoff drifted: '$S24_READBACK'"; FAIL=$((FAIL + 1))
fi
# An empty set must REFUSE to publish a list, or step 3 stages nothing again.
if bash -c '. "$1"; review_fleet_write_conflict_paths "$2/empty.zlist"' \
     _ "$ARGS_LIB_PHASE3" "$S24_TMP" >/dev/null 2>&1; then
  echo "  FAIL  S24-RT.2 — an empty conflicted-file set was accepted"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S24-RT.2 — an empty conflicted-file set is refused, not published"; PASS=$((PASS + 1))
fi
bash -c '. "$1"; review_fleet_write_ci_push "$2/push.json" "'"$(printf 'a%.0s' $(seq 40))"'" ci-rebase-handler' \
  _ "$ARGS_LIB_PHASE3" "$S24_TMP" >/dev/null 2>&1
S24_PUSH_SHA="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_read_ci_push "$2/push.json" sha' \
  _ "$ARGS_LIB_PHASE3" "$S24_TMP" 2>/dev/null)"
if [ "$S24_PUSH_SHA" = "$(printf 'a%.0s' $(seq 40))" ]; then
  echo "  PASS  S24-RT.3 — the pushed sha reaches the re-entry fence through a cleared environment"; PASS=$((PASS + 1))
else
  echo "  FAIL  S24-RT.3 — the push record did not survive a fresh shell: '$S24_PUSH_SHA'"; FAIL=$((FAIL + 1))
fi
if bash -c '. "$1"; review_fleet_write_ci_push "$2/bad.json" "" ci-rebase-handler' \
     _ "$ARGS_LIB_PHASE3" "$S24_TMP" >/dev/null 2>&1; then
  echo "  FAIL  S24-RT.4 — an empty sha was recorded as a push"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S24-RT.4 — an empty sha is refused, so fix_pushes can never name no commit"; PASS=$((PASS + 1))
fi
rm -rf "$S24_TMP"

echo "== S25: the ci-fix sidecar is FOUND, never recomputed =="
# The mint fence (6c.4w.1) writes `…-iter<R>-ci<C>.launch.json` under the
# counter it holds; the push fence (6c.4w.3) used to recompute that filename
# from the counter it read back off ci-loop-state.json. Those are the same
# number only until the CONFLICT arm's restage advances it — deliberately,
# because the restage IS a loop iteration and that is what bounds it. After any
# multi-stage rebase the push fence looked for `…-ci2.launch.json` while only
# `…-ci1.launch.json` had ever been written, aborted `ci_fixer_binding_unreadable`
# and ran `git rebase --abort`: every resolved conflict destroyed, nothing
# pushed. Recomputation cannot be made correct here; the writer publishes WHERE
# it wrote and every reader follows the pointer.
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_write_ci_pointer\(\)' \
  "S25.1 — the launch sidecar has a fixed-name pointer producer"
assert_grep "$REVIEW_PR" 'review_fleet_write_ci_pointer "\$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer\.txt"' \
  "S25.2 — the ci-fix mint fence publishes where it wrote the sidecar"
# EXACTLY ONE fence may derive that filename — the one that writes the sidecar
# and then publishes the pointer. Every other occurrence is a recomputation.
S25_DERIVATIONS="$(grep -c 'REVIEW_FLEET_CI_SIDECAR="\$REVIEW_FLEET_RUN_DIR/review-fleet-ci-fix-iter' "$REVIEW_PR" || true)"
if [ "$S25_DERIVATIONS" = 1 ]; then
  echo "  PASS  S25.3 — exactly one fence derives the ci-fix sidecar filename (the one that writes it)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S25.3 — $S25_DERIVATIONS fences derive the ci-fix sidecar filename (want exactly 1)"; FAIL=$((FAIL + 1))
fi
S25_PTR_READERS="$(grep -c 'review_fleet_read_ci_pointer "\$REVIEW_FLEET_RUN_DIR/ci-fix-launch-pointer\.txt"' "$REVIEW_PR")"
if [ "$S25_PTR_READERS" -ge 4 ]; then
  echo "  PASS  S25.4 — all four downstream readers (capture, push, conflict step 2, ci-defer) follow the pointer"; PASS=$((PASS + 1))
else
  echo "  FAIL  S25.4 — only $S25_PTR_READERS fence(s) follow the ci-fix launch pointer (want >= 4)"; FAIL=$((FAIL + 1))
fi

echo "== S25-RUNTIME: the restage that used to break the push =="
S25_TMP="$(mktemp -d)"
# Mint under ci1, exactly as 6c.4w.1 does.
bash -c '. "$1"
  review_fleet_write_sidecar "$2/review-fleet-ci-fix-iter1-ci1.launch.json" '"'"'{"edge_id":"review_pr.ci.rebase"}'"'"' "$2/child" inst 0000000000000000000000000000000000000000
  review_fleet_write_ci_pointer "$2/ci-fix-launch-pointer.txt" "$2/review-fleet-ci-fix-iter1-ci1.launch.json"' \
  _ "$ARGS_LIB_PHASE3" "$S25_TMP" >/dev/null 2>&1
# The CONFLICT arm's restage advances the counter and PERSISTS it.
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 2 1 "[]" "[]"' \
  _ "$ARGS_LIB_PHASE3" "$S25_TMP" >/dev/null 2>&1
# The OLD derivation, in a fresh shell that read the counters back: the file it
# names does not exist. If this ever stops being true the row below is vacuous.
S25_OLD="$(env -i PATH="$PATH" bash -c '. "$1"
  review_fleet_load_ci_counters "$2" || exit 9
  test -r "$2/review-fleet-ci-fix-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER}.launch.json" && echo found || echo missing' \
  _ "$ARGS_LIB_PHASE3" "$S25_TMP" 2>&1)"
S25_NEW="$(env -i PATH="$PATH" bash -c '. "$1"
  sidecar="$(review_fleet_read_ci_pointer "$2/ci-fix-launch-pointer.txt")" || exit 9
  review_fleet_read_sidecar "$sidecar" binding' _ "$ARGS_LIB_PHASE3" "$S25_TMP" 2>&1)"
if [ "$S25_OLD" = missing ] && [ "$S25_NEW" = '{"edge_id":"review_pr.ci.rebase"}' ]; then
  echo "  PASS  S25-RT.1 — after a restage the recomputed name is gone and the pointer still resolves"; PASS=$((PASS + 1))
else
  echo "  FAIL  S25-RT.1 — recomputed='$S25_OLD' pointer='$S25_NEW'"; FAIL=$((FAIL + 1))
fi
# A pointer naming a sidecar that is not there must REFUSE, never return "".
if bash -c '. "$1"
    review_fleet_write_ci_pointer "$2/dangling.txt" "$2/nothing-here.json"
    review_fleet_read_ci_pointer "$2/dangling.txt"' _ "$ARGS_LIB_PHASE3" "$S25_TMP" >/dev/null 2>&1; then
  echo "  FAIL  S25-RT.2 — a dangling pointer read as success"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S25-RT.2 — a pointer to a missing sidecar refuses instead of yielding an empty path"; PASS=$((PASS + 1))
fi
rm -rf "$S25_TMP"

echo "== S26: the rebase-state probe is answered by the WORKTREE, not the cwd =="
# `git -C <dir> rev-parse --git-path rebase-merge` prints `.git/rebase-merge` —
# RELATIVE to <dir>. `[ -d "$(…)" ]` therefore asked the question of whatever
# directory the harness shell happened to be in: from a plain subdirectory of
# the SAME repository it answers "no rebase" mid-rebase. At the push fence that
# silently bypassed `rebase_still_in_progress` and force-pushed the interior
# mid-rebase HEAD; at the three cleanup sites it made `git rebase --abort` a
# no-op. The Python twin has always joined the relative result with working_dir.
assert_no_grep "$REVIEW_PR" '\[ -d "\$\(git -C "\$WORKTREE_ROOT" rev-parse --git-path' \
  "S26.1 — no fence tests a relative --git-path result against its own cwd"
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_rebase_dir\(\)' \
  "S26.2 — ONE shell definition of \"is a rebase live\", next to the Python twin's"
S26_SITES="$(grep -c 'review_fleet_rebase_dir "\$WORKTREE_ROOT"' "$REVIEW_PR")"
if [ "$S26_SITES" -ge 4 ]; then
  echo "  PASS  S26.3 — all four rebase-state sites use the shared probe"; PASS=$((PASS + 1))
else
  echo "  FAIL  S26.3 — only $S26_SITES site(s) use review_fleet_rebase_dir (want >= 4)"; FAIL=$((FAIL + 1))
fi
# ...and "git could not answer" must not read as "no rebase" at the push fence.
assert_grep "$REVIEW_PR" 'ci_rebase_state_unreadable' \
  "S26.4 — an unreadable rebase state halts instead of licensing the push"

echo "== S26-RUNTIME: a real mid-rebase fixture, probed from three directories =="
S26_TMP="$(mktemp -d)"
(
  set -e
  cd "$S26_TMP"
  git init -q -b main repo
  cd repo
  git config user.email fixture@example.invalid
  git config user.name Fixture
  mkdir sub
  printf 'base\n' >f.txt
  git add -- f.txt
  git commit -qm 'test: base'
  git checkout -qb feat
  printf 'feat\n' >f.txt
  git commit -qam 'test: feat'
  git checkout -q main
  printf 'main\n' >f.txt
  git commit -qam 'test: main'
  git checkout -q feat
  git rebase main
) >/dev/null 2>&1 || true    # the fixture rebase MUST conflict; `set -e` is live here
S26_REPO="$S26_TMP/repo"
if [ -n "$(git -C "$S26_REPO" status --porcelain | grep '^UU ' || true)" ]; then
  S26_PROBE_OLD="$(cd "$S26_REPO/sub" && [ -d "$(git -C "$S26_REPO" rev-parse --git-path rebase-merge)" ] && echo detected || echo missed)"
  S26_PROBE_NEW="$(cd "$S26_REPO/sub" && bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null && echo detected || echo missed' _ "$ARGS_LIB_PHASE3" "$S26_REPO")"
  S26_PROBE_TMP="$(cd / && bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null && echo detected || echo missed' _ "$ARGS_LIB_PHASE3" "$S26_REPO")"
  if [ "$S26_PROBE_OLD" = missed ] && [ "$S26_PROBE_NEW" = detected ] && [ "$S26_PROBE_TMP" = detected ]; then
    echo "  PASS  S26-RT.1 — the old cwd-relative test MISSES a live rebase; the shared probe finds it from anywhere"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S26-RT.1 — old=$S26_PROBE_OLD new(subdir)=$S26_PROBE_NEW new(/)=$S26_PROBE_TMP"; FAIL=$((FAIL + 1))
  fi
  # rc must be THREE-valued: 1 for a clean repo, 2 when git cannot answer.
  S26_CLEAN_RC=0
  bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null' _ "$ARGS_LIB_PHASE3" "$REPO_ROOT" || S26_CLEAN_RC=$?
  S26_BROKEN_RC=0
  bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null' _ "$ARGS_LIB_PHASE3" "$S26_TMP/not-a-repo" || S26_BROKEN_RC=$?
  if [ "$S26_CLEAN_RC" = 1 ] && [ "$S26_BROKEN_RC" = 2 ]; then
    echo "  PASS  S26-RT.2 — no-rebase (rc 1) and probe-failed (rc 2) are distinguishable"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S26-RT.2 — clean rc=$S26_CLEAN_RC broken rc=$S26_BROKEN_RC (want 1 and 2)"; FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  S26-RT — the mid-rebase fixture did not conflict; the rows above would be vacuous"; FAIL=$((FAIL + 1))
fi
rm -rf "$S26_TMP"

echo "== S27: BOTH loop counters come off disk in every fence keyed on them =="
# Half of Phase 3 read the counters off ci-loop-state.json and half interpolated
# the fresh-shell defaults. Two sources of truth for one counter: on CI
# iteration 2 the classify mint fence recomputed
# `ci-authority-classify-iter1-ci1.json`, which iteration 1 had already
# published — and prepare-ci-authority publishes NO-CLOBBER, so it died
# `authority_preexists` with `return 74` and no audit event. CI_FIX_LOOP_CAP=3
# was unreachable in practice.
#
# REVIEW_ITERATION is the same defect one phase earlier, and it was left out of
# this section's first cut on the grounds that Phase 1/2 "run once". They do
# not: 6c.4w.3 pushes a CI fix, the re-entry fence advances BOTH counters, and
# Phase 1 re-runs. Its first fence is a fresh shell too, so REVIEW_ITERATION
# arrived either empty -- `review_fleet_child_dir` rejects it rc=2 and the
# Phase 3 -> Phase 1 loop cannot complete a second pass -- or as a stale
# inherited 1, which rebinds pass 2 onto pass 1's result.md paths and freezes
# STALE bytes while every equality still passes. That is the worse half: not a
# crash, a clean green built on the previous iteration's evidence.
assert_grep "$ARGS_LIB_PHASE3" 'review_fleet_load_ci_counters\(\)' \
  "S27.1 — ONE reader for the counter pair"
S27_VERDICT="$(python3 - "$REVIEW_PR" <<'PY_S27'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
fences, current, indent = [], None, 0
for line in lines:
    opening = re.match(r"^([ \t]*)```bash\b", line)
    if opening and current is None:
        current, indent = [], len(opening.group(1))
        continue
    if current is not None and re.match(r"^[ \t]*```[ \t]*$", line):
        fences.append("\n".join(current))
        current = None
        continue
    if current is not None:
        current.append(line)

# COMMENT-STRIPPED, the S13.11d/S21.9 precedent. Every one of these fences
# EXPLAINS why it reads the counters off disk, and several name
# `review_fleet_load_ci_counters` inside that explanation -- so a fence whose
# actual call was deleted stayed green on its own prose. Proven by mutation:
# removing the call from the CONFLICT arm's step-3 fence left this row at PASS
# until the strip below landed.
fences = [
    "\n".join(row for row in body.split("\n") if not row.lstrip().startswith("#"))
    for body in fences
]

# A fence that KEYS an artifact pathname on a loop counter must have read that
# counter off disk in the SAME fence -- there is no other way for it to be
# right on iteration 2.
# BOTH counters, because the re-entry fence advances both in lockstep and both
# are keyed on. CI_FIX_LOOP_ITER keys Phase 3's own authority and sidecar names;
# REVIEW_ITERATION keys the Phase 1/2 authority, applied-content, sidecar and
# instance-id names AND -- through `reviewIteration` and the `bind_*` binders --
# every child directory workflow.js derives, since childDirAbs() keys on
# reviewIteration ALONE.
ci_keyed = re.compile(
    r"(-ci\$\{CI_FIX_LOOP_ITER"
    r"|ci-refused-synthetic-\$\{CI_FIX_LOOP_ITER"
    r"|review_fleet_ci_slug [^\n]*\$\{CI_FIX_LOOP_ITER)"
)
review_keyed = re.compile(
    r"(-iter\$\{REVIEW_ITERATION\}"
    r"|reviewIteration=\"\$REVIEW_ITERATION\""
    r"|review_fleet_bind_[a-z_]+ [^\n]*\"\$REVIEW_ITERATION\""
    r"|review_fleet_child_dir [^\n]*\"\$REVIEW_ITERATION\")"
)
# THE SHARED READER, not "any spelling of reading". Accepting an open-coded
# `review_fleet_read_ci_state` pair is what let the CONFLICT arm's step-3 fence
# ship its own copy WITHOUT the else-branch default the helper supplies — and on
# the first CI iteration there is no ci-loop-state.json yet, so the very next
# line dereferenced `${REVIEW_ITERATION}` bare under `set -u`: rc=126, zero
# audit events, worktree left mid-rebase. Two spellings of "read the counters"
# IS the defect this section exists to end.
reads = re.compile(r"review_fleet_load_ci_counters")
offenders, ci_examined, review_examined = [], 0, 0
for body in fences:
    on_ci, on_review = bool(ci_keyed.search(body)), bool(review_keyed.search(body))
    if not (on_ci or on_review):
        continue
    ci_examined += on_ci
    review_examined += on_review
    if reads.search(body):
        continue
    first = next((row.strip() for row in body.split("\n") if row.strip()), "<empty>")
    offenders.append(first[:70])

# Anti-vacuity, PER COUNTER: if the detector stops FINDING counter-keyed fences
# it must fail, not go green on an empty set -- and one counter's spelling
# changing must not be masked by the other counter's fences still being found.
# That masking is not hypothetical: this section shipped scoped to CI_FIX_LOOP_ITER
# alone and read green across twelve REVIEW_ITERATION-keyed fences that had no
# reader at all.
if ci_examined < 8:
    print("VACUOUS:only %d CI-counter-keyed fence(s) found" % ci_examined)
elif review_examined < 18:
    print("VACUOUS:only %d REVIEW_ITERATION-keyed fence(s) found" % review_examined)
elif offenders:
    print("LEAKS:" + " | ".join(offenders))
else:
    print("OK:%d CI-keyed + %d REVIEW_ITERATION-keyed" % (ci_examined, review_examined))
PY_S27
)"
case "$S27_VERDICT" in
  OK:*)
    echo "  PASS  S27.2 — all ${S27_VERDICT#OK:} fences read the counters off disk first"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  S27.2 — $S27_VERDICT"
    FAIL=$((FAIL + 1))
    ;;
esac

echo "== S28: the conflict fanout's cap is a TOTAL, its wave is the concurrency knob =="
# `fanout_concurrency.conflict_resolver` is documented as a concurrency knob —
# "split into ceil(N / cap) sequential waves" — and it was forwarded as BOTH
# ciConflictCap and ciConflictWave. An 11-conflict PR therefore aborted
# `bad_ci_conflict_count` with zero resolvers dispatched, refusing the exact
# case dispatchRoster's wave loop exists to serve.
assert_grep "$REVIEW_PR" 'ciConflictWave="\$CONFLICT_RESOLVER_CAP"' \
  "S28.1 — the concurrency knob is the WAVE size"
assert_no_grep "$REVIEW_PR" 'ciConflictCap="\$CONFLICT_RESOLVER_CAP"' \
  "S28.2 — the concurrency knob is NOT the total ceiling"
assert_grep "$REVIEW_PR" 'ciConflictCap="\$REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP"' \
  "S28.3 — the total ceiling is its own named constant"
assert_grep "$REVIEW_PR" 'rebase_conflict_set_too_large' \
  "S28.4 — a set above the ceiling refuses with a reason that names the cause"
# The shell constant must equal the ceiling the engine EFFECTIVELY enforces, or
# the enumerator accepts a set the engine then refuses. That ceiling is
# `min(ciConflictCap clamp default, maxAgents clamp default)`, not the
# ciConflictCap literal: #383 wrapped the clamp in `Math.min(..., maxAgents)`
# because a cap above maxAgents passes the enumerator and is then refused by
# ceilingGate() with zero children dispatched. Comparing the ciConflictCap
# literal alone cannot see that drift -- the script's own comment above the
# Math.min says exactly that -- so this reads BOTH defaults and does the min.
S28_SHELL="$(bash -c '. "$1"; printf "%s" "$REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP"' _ "$ARGS_LIB_PHASE3" 2>/dev/null)"
S28_CLAMP="$(sed -nE 's/^const ciConflictCap = Math\.min\(clampInt\(CFG\.ciConflictCap, 1, [0-9]+, ([0-9]+)\), maxAgents\);$/\1/p' "$WORKFLOW_JS")"
S28_MAX="$(sed -nE 's/^const maxAgents = clampInt\(CFG\.maxAgents, 1, [0-9]+, ([0-9]+)\);$/\1/p' "$WORKFLOW_JS")"
if [ -n "$S28_CLAMP" ] && [ -n "$S28_MAX" ]; then
  if [ "$S28_CLAMP" -lt "$S28_MAX" ]; then S28_JS="$S28_CLAMP"; else S28_JS="$S28_MAX"; fi
else
  S28_JS=''
fi
if [ -n "$S28_SHELL" ] && [ "$S28_SHELL" = "$S28_JS" ]; then
  echo "  PASS  S28.5 — the controller ceiling ($S28_SHELL) and the engine's effective ceiling (min($S28_CLAMP,$S28_MAX)) agree"; PASS=$((PASS + 1))
else
  echo "  FAIL  S28.5 — ceiling drift: shell='$S28_SHELL' effective='$S28_JS' (ciConflictCap='$S28_CLAMP' maxAgents='$S28_MAX')"; FAIL=$((FAIL + 1))
fi

echo "== S29: the CONFLICT arm's fences are self-contained =="
# Step 2 was the one fence the on-disk-handoff treatment missed. Under `set -u`
# a nested `$(review_json_string "$CI_BASE_SHA")` kills only the INNER subshell
# — the parent stays rc=0 and pins an EMPTY value into the child's input.json
# with no error at all — while a bare `$CONFLICT_RESOLVER_CAP` in the argument
# list kills the fence with a raw "unbound variable", no audit, no cleanup.
CONFLICT_MINT_FENCE="$(awk '
  /^[ \t]*```bash/ { fence = 1; buf = ""; next }
  fence && /^[ \t]*```[ \t]*$/ {
    if (index(buf, "review_fleet_bind_ci_conflicts ") > 0) { printf "%s", buf; found = 1; exit }
    fence = 0; buf = ""; next
  }
  fence { buf = buf $0 "\n" }
  END { if (!found) exit 1 }
' "$REVIEW_PR")" || CONFLICT_MINT_FENCE=""
# COMMENT-STRIPPED, the S13.11d/S21.9 precedent. The fence's own prose block
# NAMES `read-ci-authority-member` in order to explain why it is used instead of
# `jq`, so the raw-text grep was satisfied by the explanation rather than by the
# code: deleting the entire six-scalar re-derivation loop — the whole fix — left
# this suite at `failed: 0`. The other three tokens were non-vacuous already;
# this makes all four judge code only.
CONFLICT_MINT_CODE="$(grep -v '^[[:space:]]*#' <<<"$CONFLICT_MINT_FENCE")"
S29_MISSING=""
for token in 'review_fleet_load_ci_counters' 'read-ci-authority-member' \
             'uberdev_read_int_in_range fanout_concurrency.conflict_resolver' \
             'lib/config-read.sh'; do
  grep -qF -- "$token" <<<"$CONFLICT_MINT_CODE" || S29_MISSING="$S29_MISSING $token"
done
# ...and the loop that reads those members back is judged as a LOOP, not as a
# lone token: five members, each bound to its own scalar, each refused when the
# pinned document hands back an empty value.
S29_LOOP_MISSING=""
for token in 'for CI_AUTHORITY_MEMBER in pr_branch base_branch base_sha run_id head_sha' \
             '--member "$CI_AUTHORITY_MEMBER"' \
             '[ -n "$CI_AUTHORITY_VALUE" ]'; do
  grep -qF -- "$token" <<<"$CONFLICT_MINT_CODE" || S29_LOOP_MISSING="$S29_LOOP_MISSING|$token"
done
if [ -z "$S29_LOOP_MISSING" ]; then
  echo "  PASS  S29.1b — the six-scalar re-derivation loop itself is present, not just its name"; PASS=$((PASS + 1))
else
  echo "  FAIL  S29.1b — the conflict mint fence lost its re-derivation loop:$S29_LOOP_MISSING"; FAIL=$((FAIL + 1))
fi
if [ -z "$S29_MISSING" ]; then
  echo "  PASS  S29.1 — the conflict mint fence re-derives its counters, refs and cap itself"; PASS=$((PASS + 1))
else
  echo "  FAIL  S29.1 — the conflict mint fence still inherits:$S29_MISSING"; FAIL=$((FAIL + 1))
fi
# ...and the per-resolver authority pin reaches the PROMPT as a per-resolver
# value, not as the last loop iteration's scalar shared by everyone.
assert_grep "$REVIEW_PR" 'ciConflictAuthorityPrefixAbs="\$CONFLICT_AUTHORITY_PREFIX"' \
  "S29.2 — the envelope carries the authority PREFIX, one spelling of the rule"
assert_no_grep "$REVIEW_PR" 'ciAuthorityPathAbs="\$CONFLICT_AUTHORITY_PATH"' \
  "S29.3 — no single authority path is forwarded for the whole conflict stage"
assert_grep "$WORKFLOW_JS" 'ciConflictAuthorityPrefixAbs \+ entry\.index' \
  "S29.4 — each resolver's prompt names its OWN authority"

echo "== S30: the single leased push refuses an unchanged HEAD =="
# `_validate_ci_fix_code_outcome` returns NO_CHANGE when head_after ==
# head_before, and 6c.5's "do NOT run 6c.4w.3" was prose with no reader. An
# orchestrator that ran the fence anyway pushed the unchanged HEAD, the lease
# matched, `git push` exited 0 ("Everything up-to-date"), and `ci_fix_pushed`
# recorded a commit that fixed nothing — Phase 1 then re-entered on identical
# code and the loop burned an iteration.
if grep -qF 'ci_fix_no_change' <<<"$PUSH_FENCE" \
   && grep -qF 'review_fleet_read_sidecar "$REVIEW_FLEET_CI_SIDECAR" head_before' <<<"$PUSH_FENCE"; then
  echo "  PASS  S30.1 — the push fence compares the HEAD it is about to push against the sidecar's head_before"; PASS=$((PASS + 1))
else
  echo "  FAIL  S30.1 — the NO_CHANGE rule is still prose with no reader in the push fence"; FAIL=$((FAIL + 1))
fi

echo "== S31: the ci-defer arm has a reachable trigger and a bound issue URL =="
# THE ARM HAD NO TRIGGER. `_validate_ci_fix_code_outcome` returned only APPLIED
# or NO_CHANGE, a refusing ci-code-fixer makes no commit (so head_after ==
# head_before), and 6c.5 mandates branching on the VALIDATED terminal — so
# REFUSED and NO_CHANGE were indistinguishable and an orchestrator following
# this file always took the NO_CHANGE bullet. Four fences, an authority edge and
# a Workflow arm were dead code on every documented path.
assert_grep "$CONTRACT_PY" '_ci_fix_code_declared_refusal' \
  "S31.1 — the contract can derive a REFUSED terminal at all"
assert_grep "$CONTRACT_PY" 'return \("REFUSED", rationale\) if rationale else \("NO_CHANGE", ""\)' \
  "S31.2 — the refusal is read ONLY when HEAD did not move (it can never authorise a push)"
assert_grep "$REVIEW_PR" 'CI_FIXER_TERMINAL_RATIONALE="\$\(review_ci_json_member "\$CI_MUTATION_OUTCOME" rationale\)"' \
  "S31.3 — 6c.4w.2 captures the sanitised rationale off the validated receipt"
assert_grep "$REVIEW_PR" 'CI_FIXER_TERMINAL_STATUS=REFUSED' \
  "S31.4 — 6c.5 routes the REFUSED terminal, not the agent's self-report"
assert_grep "$CODE_FIXER_CI" '^rationale:' \
  "S31.5 — the ci-code-fixer return contract documents the field the terminal depends on"
# ...and the URL the arm exists to hand the operator. CI_REFUSED_ISSUE_URL was
# assigned ONLY in the two MALFORMED branches, and the validated receipt carried
# no URL at all — so the halt prose's `filed issue:` line and the audit field
# `phases.phase3.ci_refused_issue_url` named an unbound variable exactly when
# the filing had WORKED.
assert_grep "$CONTRACT_PY" '"created_url": parsed\["created_url"\]' \
  "S31.6 — validate-ci-persistence-result returns the filed issue URL"
assert_grep "$REVIEW_PR" 'CI_REFUSED_ISSUE_URL="\$\(review_ci_json_member "\$CI_DEFER_RECEIPT" created_url\)"' \
  "S31.7 — the capture fence binds CI_REFUSED_ISSUE_URL on the SUCCESS path"
# The accumulated class comes off the digest-pinned authority, not from a
# soft-defaulted scalar three stages upstream: `${failure_class:-unknown}` made
# `phases.phase3.failure_classes_seen` read ["unknown"] on every single run.
assert_grep "$REVIEW_PR" '--member failure_class' \
  "S31.8 — the re-entry fence reads the class back out of the ci-fix authority"
assert_no_grep "$REVIEW_PR" '\-\-arg class "\$\{failure_class:-unknown\}"' \
  "S31.9 — no soft-defaulted class is recorded into the audit accumulator"

echo
echo "== S32: Phase 3's push target is same-repository-gated BEFORE the lease (#395) =="
# Numbered S32, not S21: this block and the ROUTE-stage-machine block above both
# arrived as "S21" (this one from #395, that one from #383 half two) and the two
# id spaces collided on the rebase. The Phase 3 wiring rows own S21-S31 because
# they are contiguous; the #395 rows moved to the next free number.
#
# Phase 3 used to bind its push target with a bare
# `gh pr view --json headRefName,baseRefName` and then fetch, lease and push
# `origin <headRefName>`. `origin` is the repository the PR was opened AGAINST:
# for a fork PR that branch name belongs to the CONTRIBUTOR's repository, so the
# push fails — or, worse, addresses an unrelated same-named branch in the base
# repo. Phase 1/2 have always refused that shape before publishing
# (`review_publish_same_repo_pr_head`); these rows are Phase 3's copy of the
# guarantee, and they are the fork-shaped regression cover issue #395 asks for.
PUSH_TARGET_LIB="$REPO_ROOT/plugins/uberdev/lib/review-push-target.sh"

if [ -r "$PUSH_TARGET_LIB" ]; then
  echo "  PASS  S32.1 — the resolver ships on disk (lib/review-push-target.sh)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S32.1 — missing resolver: $PUSH_TARGET_LIB"
  echo "        a helper that takes arguments cannot live in a rendered command"
  echo "        fence — the templater substitutes every positional (#404)"
  FAIL=$((FAIL + 1))
fi

assert_grep "$REVIEW_PR" 'lib/review-push-target\.sh' \
  "S32.2 — the Phase 3 arm sources the on-disk resolver"
assert_grep "$REVIEW_PR" 'review_resolve_same_repo_push_target' \
  "S32.3 — pr_head_branch/base_branch are bound through the resolver"
assert_no_grep "$REVIEW_PR" \
  'gh pr view "\$PR_NUMBER" --json headRefName,baseRefName' \
  "S32.4 — the ungated headRefName binding is gone"
assert_grep "$REVIEW_PR" 'ci_push_target_cross_repository' \
  "S32.5 — typed data.subreason ci_push_target_cross_repository documented"
assert_grep "$REVIEW_PR" 'ci_push_target_unresolved' \
  "S32.6 — typed data.subreason ci_push_target_unresolved documented"

# S32.7 — ORDER IS THE POINT. #395 asks for the check "before the lease is
# captured rather than after": a lease over a ref the run could not identify
# proves nothing, and `git fetch origin <fork-branch>` has already failed by
# then. Both the fetch and the lease capture must sit BELOW the gate in the file.
#
# The two probes are name-adapted to the wired Phase 3 (#383 half two): the
# lease scalar is `CI_LEASE_SHA`, captured with `rev-parse` inside the ROUTE
# fence, and the fetch may carry a `-C "$WORKTREE_ROOT"`. `EXPECTED_OLD_SHA` —
# what this row probed while the arm was still dead — is now BANNED from this
# file by S13.11b, so the old probe could only ever have gone silent. The
# `rev-parse` conjunct keeps the lease probe off the later authority read-back,
# which re-reads the same scalar through code_fixer_contract.py.
S32_GATE_LINE="$(awk '/review_resolve_same_repo_push_target/ {print NR; exit}' "$REVIEW_PR")"
S32_FETCH_LINE="$(awk '/^[[:space:]]*git .*fetch origin/ {print NR; exit}' "$REVIEW_PR")"
S32_LEASE_LINE="$(awk '/^[[:space:]]*CI_LEASE_SHA=/ && /rev-parse/ {print NR; exit}' "$REVIEW_PR")"
if [ -n "$S32_GATE_LINE" ] && [ -n "$S32_FETCH_LINE" ] && [ -n "$S32_LEASE_LINE" ] \
   && [ "$S32_GATE_LINE" -lt "$S32_FETCH_LINE" ] && [ "$S32_GATE_LINE" -lt "$S32_LEASE_LINE" ]; then
  echo "  PASS  S32.7 — the gate resolves before the fetch and before the lease capture"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S32.7 — gate/fetch/lease ordering is wrong or a site is missing"
  echo "        gate: ${S32_GATE_LINE:-<none>}  fetch: ${S32_FETCH_LINE:-<none>}  lease: ${S32_LEASE_LINE:-<none>}"
  FAIL=$((FAIL + 1))
fi

echo
echo "== S32-RT: the resolver refuses the fork shape for real (executed) =="
# Runtime cover, not prose cover. The resolver is sourced and CALLED with a
# stubbed `gh` and `git`, once per shape. The stub records every call, so the
# rows can also prove the negative that matters most: the resolver itself never
# fetches and never pushes — it answers "may Phase 3 push this, and under which
# names", and the caller does the pushing.
PUSH_TARGET_STUB="$(mktemp)"
PUSH_TARGET_LOG="$(mktemp)"
cat >"$PUSH_TARGET_STUB" <<'STUB'
. "$PUSH_TARGET_LIB"

gh() {
  printf 'gh %s\n' "$*" >>"$PUSH_TARGET_LOG"
  [ "$1" = pr ] && [ "$2" = view ] || return 90
  case "$SCENARIO" in
    same-repo)         printf 'fix/395-guard\nmain\nfalse\nowner/repo\n' ;;
    fork)              printf 'fix/395-guard\nmain\ntrue\ncontributor/repo\n' ;;
    fork-shadow-name)  printf 'main\nmain\ntrue\ncontributor/repo\n' ;;
    head-repo-drift)   printf 'fix/395-guard\nmain\nfalse\nattacker/repo\n' ;;
    empty-head-repo)   printf 'fix/395-guard\nmain\nfalse\n/\n' ;;
    gh-down)           return 91 ;;
    short-projection)  printf 'fix/395-guard\nmain\nfalse\n' ;;
    extra-field)       printf 'fix/395-guard\nmain\nfalse\nowner/repo\nsurprise\n' ;;
    unroutable-head)   printf 'bad branch\nmain\nfalse\nowner/repo\n' ;;
    unroutable-base)   printf 'fix/395-guard\nbad base\nfalse\nowner/repo\n' ;;
    *)                 return 92 ;;
  esac
}

git() {
  printf 'git %s\n' "$*" >>"$PUSH_TARGET_LOG"
  [ "$1" = -C ] && [ "$2" = /repo ] || return 91
  [ "$3" = check-ref-format ] && [ "$4" = --branch ] || return 93
  case "$5" in
    *' '*) return 1 ;;
    *)     return 0 ;;
  esac
}

review_resolve_same_repo_push_target "$@"
STUB

# push_target_case RUNNER SCENARIO ARGS… -> "<rc>|<stdout>"
push_target_case() {
  local runner="$1" scenario="$2"
  shift 2
  local out rc=0
  out="$(PUSH_TARGET_LIB="$PUSH_TARGET_LIB" PUSH_TARGET_LOG="$PUSH_TARGET_LOG" \
        SCENARIO="$scenario" "$runner" "$PUSH_TARGET_STUB" "$@" 2>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

push_target_row() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        expected: $expected"; echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

if [ -r "$PUSH_TARGET_LIB" ]; then
  : >"$PUSH_TARGET_LOG"
  push_target_row "S32-RT.1 — a same-repository PR resolves to its head and base branch" \
    "0|$(printf 'fix/395-guard\tmain')" \
    "$(push_target_case bash same-repo owner/repo 73 /repo)"

  push_target_row "S32-RT.2 — a fork PR is a NAMED refusal (rc 78), not a push attempt" \
    "78|" "$(push_target_case bash fork owner/repo 73 /repo)"

  push_target_row "S32-RT.3 — a fork branch that SHADOWS a base-repo branch name is refused too" \
    "78|" "$(push_target_case bash fork-shadow-name owner/repo 73 /repo)"

  push_target_row "S32-RT.4 — a head repository that is not the review repo is refused (rc 78)" \
    "78|" "$(push_target_case bash head-repo-drift owner/repo 73 /repo)"

  push_target_row "S32-RT.5 — an unidentifiable head repository is refused, never assumed same-repo" \
    "78|" "$(push_target_case bash empty-head-repo owner/repo 73 /repo)"

  push_target_row "S32-RT.6 — an unreachable gh halts the push path (rc 79), it does not proceed" \
    "79|" "$(push_target_case bash gh-down owner/repo 73 /repo)"

  push_target_row "S32-RT.7 — a short projection is refused, not silently mis-bound" \
    "79|" "$(push_target_case bash short-projection owner/repo 73 /repo)"

  push_target_row "S32-RT.8 — an over-long projection is refused" \
    "79|" "$(push_target_case bash extra-field owner/repo 73 /repo)"

  push_target_row "S32-RT.9 — an unroutable head branch name is refused" \
    "79|" "$(push_target_case bash unroutable-head owner/repo 73 /repo)"

  push_target_row "S32-RT.10 — an unroutable base branch name is refused" \
    "79|" "$(push_target_case bash unroutable-base owner/repo 73 /repo)"

  # Malformed caller arguments never reach the network at all.
  : >"$PUSH_TARGET_LOG"
  S32_ARG_RCS=""
  for bad_args in "owner/repo 73" "owner/repo 73 /repo extra" "owner/repo 0 /repo" \
                  "owner/repo 7x /repo" "owner 73 /repo" "owner/repo 73 relative/path"; do
    # shellcheck disable=SC2086
    S32_ARG_RCS="$S32_ARG_RCS$(push_target_case bash same-repo $bad_args) "
  done
  if [ "$S32_ARG_RCS" = "2| 2| 2| 2| 2| 2| " ] && [ ! -s "$PUSH_TARGET_LOG" ]; then
    echo "  PASS  S32-RT.11 — malformed arguments are rc 2 and never call gh"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S32-RT.11 — malformed arguments leaked past validation"
    echo "        rcs: $S32_ARG_RCS"
    echo "        calls: $(cat "$PUSH_TARGET_LOG")"
    FAIL=$((FAIL + 1))
  fi

  # The negative that matters: the resolver is read-only on the remote.
  : >"$PUSH_TARGET_LOG"
  S32_RO_OUT="$(push_target_case bash same-repo owner/repo 73 /repo)"
  S32_RO_LOG="$(cat "$PUSH_TARGET_LOG")"
  if [ "${S32_RO_OUT%%|*}" = 0 ] \
     && ! grep -qE '^git( -C [^[:space:]]+)? (push|fetch|rebase|commit)' <<<"$S32_RO_LOG"; then
    echo "  PASS  S32-RT.12 — the resolver never pushes, fetches, rebases or commits"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S32-RT.12 — the resolver mutated the repository or the remote"
    echo "        calls: $S32_RO_LOG"
    FAIL=$((FAIL + 1))
  fi

  # The fences execute under /bin/zsh, so the resolver must behave identically
  # there — this is the shell that turned an unbraced `$sha:refs/…` into a `:r`
  # modifier and killed every anchor push (R9.12b in review-pr.test.sh).
  if command -v zsh >/dev/null 2>&1; then
    S32_ZSH_OK=1
    [ "$(push_target_case zsh same-repo owner/repo 73 /repo)" = "0|$(printf 'fix/395-guard\tmain')" ] || S32_ZSH_OK=0
    [ "$(push_target_case zsh fork owner/repo 73 /repo)" = "78|" ] || S32_ZSH_OK=0
    [ "$(push_target_case zsh gh-down owner/repo 73 /repo)" = "79|" ] || S32_ZSH_OK=0
    if [ "$S32_ZSH_OK" = 1 ]; then
      echo "  PASS  S32-RT.13 — same verdicts under /bin/zsh, the shell the fences run in"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  S32-RT.13 — the resolver diverges under zsh"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  SKIP  S32-RT.13 — zsh unavailable on this runner"
  fi

  # S32-RT.14/15 — EXECUTE THE FENCE ITSELF, not a paraphrase of it. Every other
  # Phase 3 assertion in this file greps fence *text*; #394 documents four
  # arm-killing blockers that a 290-assertion green suite could not see for
  # exactly that reason. So the binding fence is extracted from review-pr.md
  # verbatim, sourced under `set -u` with a stubbed gh/git/audit, and asked what
  # it actually does with a fork PR.
  #
  # Two adaptations to the wired Phase 3 (#383 half two):
  #   * the fence opener now carries an info string (```bash uberdev-executable
  #     origin=review-pr), so the extractor keys on the ```bash PREFIX and picks
  #     the fence by its CROSS-REPOSITORY GATE marker, not by a bare opener;
  #   * the wiring renamed the bound scalars to CI_PR_HEAD_BRANCH/CI_BASE_BRANCH,
  #     so the driver reports whichever pair the gate actually binds.
  # What is NOT adapted away: the gate has to sit in a fence that can be sourced
  # on its own. That is the same self-containment property S29 asserts for the
  # CONFLICT arm — a gate welded into a fence that first needs child-dispatch.sh
  # and a dispatch table is a gate no test can execute, which is how #395 became
  # invisible in the first place.
  S32_FENCE="$(mktemp)"
  S32_DRIVER="$(mktemp)"
  S32_FENCE_LOG="$(mktemp)"
  awk '
    /^    ```bash/ { collecting = 1; buf = ""; next }
    collecting && /^    ```$/ {
      if (buf ~ /CROSS-REPOSITORY GATE/) { printf "%s", buf; exit }
      collecting = 0; next
    }
    collecting { line = $0; sub(/^    /, "", line); buf = buf line "\n" }
  ' "$REVIEW_PR" >"$S32_FENCE"
  cat >"$S32_DRIVER" <<'S32DRIVER'
set -u
audit() { printf 'audit %s\n' "$*" >>"$FENCE_LOG"; }
gh() {
  printf 'gh %s\n' "$*" >>"$FENCE_LOG"
  if [ "$1" = repo ]; then printf 'owner/repo\n'; return 0; fi
  [ "$1" = pr ] && [ "$2" = view ] || return 90
  case "$SCENARIO" in
    same-repo) printf 'fix/395-guard\nmain\nfalse\nowner/repo\n' ;;
    fork)      printf 'fix/395-guard\nmain\ntrue\ncontributor/repo\n' ;;
    *)         return 92 ;;
  esac
}
git() {
  printf 'git %s\n' "$*" >>"$FENCE_LOG"
  case "$1" in
    rev-parse) printf '/repo\n' ;;
    -C)
      case "${3:-}" in
        check-ref-format) : ;;
        rev-parse)        printf '%040d\n' 0 ;;
        fetch)            : ;;
        *)                return 93 ;;
      esac
      ;;
    *) return 93 ;;
  esac
}
PR_NUMBER=73
WORKTREE_ROOT=/repo
. "$FENCE_FIXTURE"
printf 'bound %s %s\n' \
  "${pr_head_branch:-${CI_PR_HEAD_BRANCH:-}}" \
  "${base_branch:-${CI_BASE_BRANCH:-}}" >>"$FENCE_LOG"
S32DRIVER

  # run_fence SHELL SCENARIO -> "<rc>" with the call log left in $S32_FENCE_LOG
  run_s32_fence() {
    local runner="$1" scenario="$2" rc=0
    : >"$S32_FENCE_LOG"
    FENCE_FIXTURE="$S32_FENCE" FENCE_LOG="$S32_FENCE_LOG" SCENARIO="$scenario" \
      UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
      "$runner" "$S32_DRIVER" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
  }

  if [ ! -s "$S32_FENCE" ]; then
    echo "  FAIL  S32-RT.14 — the cross-repository gate fence could not be extracted"
    echo "  FAIL  S32-RT.15 — no fence to execute"
    FAIL=$((FAIL + 2))
  else
    for s32_shell in bash zsh; do
      if ! command -v "$s32_shell" >/dev/null 2>&1; then
        echo "  SKIP  S32-RT.14/15 ($s32_shell) — shell unavailable on this runner"
        continue
      fi
      S32_OK_RC="$(run_s32_fence "$s32_shell" same-repo)"
      S32_OK_LOG="$(cat "$S32_FENCE_LOG")"
      if [ "$S32_OK_RC" = 0 ] && grep -qxF 'bound fix/395-guard main' <<<"$S32_OK_LOG"; then
        echo "  PASS  S32-RT.14 ($s32_shell) — the fence executes and binds the same-repo head/base pair"
        PASS=$((PASS + 1))
      else
        echo "  FAIL  S32-RT.14 ($s32_shell) — the fence bound neither pr_head_branch/base_branch nor CI_PR_HEAD_BRANCH/CI_BASE_BRANCH"
        echo "        rc: $S32_OK_RC"
        echo "        calls: $S32_OK_LOG"
        FAIL=$((FAIL + 1))
      fi

      S32_FORK_RC="$(run_s32_fence "$s32_shell" fork)"
      S32_FORK_LOG="$(cat "$S32_FENCE_LOG")"
      # The audit line is matched on its typed subreason rather than byte-for-byte:
      # the wiring is free to carry extra `data.*` fields, but it is NOT free to
      # halt anonymously. The negative below is the row's real property, and it
      # tolerates the wired form's `git -C "$WORKTREE_ROOT" fetch`.
      if [ "$S32_FORK_RC" = 1 ] \
         && grep -qE '^audit .*ci_phase_outcome.*data\.outcome=halted' <<<"$S32_FORK_LOG" \
         && grep -qF 'data.subreason=ci_push_target_cross_repository' <<<"$S32_FORK_LOG" \
         && ! grep -qE '^git( -C [^[:space:]]+)? (fetch|push|rebase)' <<<"$S32_FORK_LOG"; then
        echo "  PASS  S32-RT.15 ($s32_shell) — a fork PR halts with the typed audit event, before any fetch/lease/push"
        PASS=$((PASS + 1))
      else
        echo "  FAIL  S32-RT.15 ($s32_shell) — a fork PR was not refused as a named halt"
        echo "        rc: $S32_FORK_RC"
        echo "        calls: $S32_FORK_LOG"
        FAIL=$((FAIL + 1))
      fi
    done
  fi
  rm -f "$S32_FENCE" "$S32_DRIVER" "$S32_FENCE_LOG"
else
  echo "  FAIL  S32-RT.* — resolver missing, no runtime cover could execute"
  FAIL=$((FAIL + 1))
fi
rm -f "$PUSH_TARGET_STUB" "$PUSH_TARGET_LOG"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
