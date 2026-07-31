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

for f in "$REVIEW_PR" "$CLASSIFIER" "$CODE_FIXER_CI" "$REBASE_HANDLER" "$MERGE_SKILL" "$RUN_TREE"; do
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
CI_MONITOR_PASS_CONST="$(grep -oE '^ *CI_MONITOR_PASS_SEC=[0-9]+' "$REVIEW_PR" | head -n 1 | cut -d= -f2)"
CI_MONITOR_FENCE_CONST="$(grep -oE '^ *CI_MONITOR_FENCE_SEC=[0-9]+' "$REVIEW_PR" | head -n 1 | cut -d= -f2)"
CI_MONITOR_MIN_CONST="$(grep -oE '^ *CI_MONITOR_MIN_PASS_SEC=[0-9]+' "$REVIEW_PR" | head -n 1 | cut -d= -f2)"
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
assert_grep "$REVIEW_PR" 'review_validate_ci_classification' \
  "S10.6 — controller validates classifier output before routing"
assert_grep "$REVIEW_PR" 'ci_classify_returned.*contract_invalid' \
  "S10.7 — invalid class/anchor fails closed with an audit event"
assert_grep "$REVIEW_PR" 'gh-run-.*\[1-9\].*signal_anchor|signal_anchor.*positive integer' \
  "S10.8 — blank and zero-line signal anchors are rejected"
assert_grep "$REVIEW_PR" 'CI_REFUSED_AGGREGATE_PATH.*RESEARCH_DIR_ABS/ci-refused-synthetic' \
  "S10.9 — CI refusal aggregate stays inside the run research directory"
assert_no_grep "$REVIEW_PR" 'tmp-synthetic-aggregate|freshly-created `mktemp`' \
  "S10.10 — CI refusal handoff no longer points at a system mktemp artifact"
assert_grep "$REVIEW_PR" 'review_child_result_path.*ci-classify\.launched.*review_pr\.ci\.classify' \
  "S10.10a — classifier validation resolves the routed child's canonical result ledger"
assert_grep "$REVIEW_PR" 'if review_child_single review_pr\.ci\.classify' \
  "S10.10a1 — classifier lifecycle failure is checked before artifact discovery"
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

CLASSIFY_LIFECYCLE_FIXTURE="$(mktemp)"
CLASSIFY_LIFECYCLE_LOG="$(mktemp)"
awk '
  /^[[:space:]]*CI_CLASSIFY_INPUTS="/ { capture=1 }
  capture && /^[[:space:]]*CI_CLASSIFICATION_PATH="/ { exit }
  capture { sub(/^[[:space:]]{4}/,""); print }
' "$REVIEW_PR" >"$CLASSIFY_LIFECYCLE_FIXTURE"
cat >>"$CLASSIFY_LIFECYCLE_FIXTURE" <<'SH'
review_child_result_path() { printf 'result-discovery\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
route_classifier() { printf 'routing\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
dispatch_fixer() { printf 'fixer\n' >>"$CLASSIFY_LIFECYCLE_LOG"; }
review_child_result_path
route_classifier
dispatch_fixer
SH
set +e
CLASSIFY_LIFECYCLE_LOG="$CLASSIFY_LIFECYCLE_LOG" \
PR_NUMBER=1 CI_RUN_ID=123 RUN_ID=fixture \
CI_LOG_AUTHORITY_JSON='{"pr_number":1,"run_id":"123","head_sha":"0123456789abcdef0123456789abcdef01234567","log_content":"wrapped","log_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' \
CI_FIX_LOOP_ITER=2 RESEARCH_DIR_ABS=/tmp/research REVIEW_PR_TIMEOUT=9 \
bash -c '
  review_json_string() { printf "\"%s\"" "$1"; }
  review_json_member() { python3 -I -B -c '"'"'import json,sys; print(json.dumps(json.loads(sys.argv[1])[sys.argv[2]]),end="")'"'"' "$1" "$2"; }
  uberdev_child_inputs_build() { printf "{}"; }
  uberdev_child_instance_id() { printf "%s" "$1"; }
  review_child_single() { printf "child\n" >>"$CLASSIFY_LIFECYCLE_LOG"; return 37; }
  audit() { printf "audit:%s:%s:%s\n" "$1" "$2" "$3" >>"$CLASSIFY_LIFECYCLE_LOG"; }
  . "$1"
' _ "$CLASSIFY_LIFECYCLE_FIXTURE"
CLASSIFY_LIFECYCLE_RC=$?
set +e
if [ "$CLASSIFY_LIFECYCLE_RC" -eq 1 ] \
    && grep -q '^child$' "$CLASSIFY_LIFECYCLE_LOG" \
    && grep -q 'classifier_child_failed.*exit_code=37' "$CLASSIFY_LIFECYCLE_LOG" \
    && ! grep -Eq 'result-discovery|routing|fixer' "$CLASSIFY_LIFECYCLE_LOG"; then
  echo "  PASS  S10.10a3 — classifier lifecycle failure records rc=37 and blocks discovery, routing, and fixer"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.10a3 — classifier lifecycle failure reached a downstream canary"; FAIL=$((FAIL + 1))
fi
rm -f "$CLASSIFY_LIFECYCLE_FIXTURE" "$CLASSIFY_LIFECYCLE_LOG"

CLASSIFY_HELPER="$(mktemp)"
CLASSIFY_CASE="$(mktemp)"
awk '
  /^[[:space:]]*review_validate_ci_classification\(\) \{/ { capture=1 }
  capture { print }
  capture && /^[[:space:]]*\}$/ { exit }
' "$REVIEW_PR" > "$CLASSIFY_HELPER"
write_classifier_case() {
  local status="$1" failure_class="$2" signal_anchor="$3" rationale="$4"
  printf '```yaml\nstatus: %s\nfailure_class: %s\nsignal_anchor: %s\nrationale: %s\nrisks: []\n```\n' \
    "$status" "$failure_class" "$signal_anchor" "$rationale" > "$CLASSIFY_CASE"
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

RESULT_PATH_HELPER="$(mktemp)"
RESULT_PATH_TMP="$(mktemp -d)"
RESULT_PATH_TMP="$(cd "$RESULT_PATH_TMP" && pwd -P)"
export UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export UBERDEV_CARRIER_RUN_DIR="$RESULT_PATH_TMP/run"
export _UBERDEV_DISPATCH_BACKEND_ENUM='auto|claude-bg|wezterm|background|codex'
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
  _UBERDEV_DISPATCH_BACKEND_ENUM='auto|claude-bg|wezterm|background|codex' \
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
write_classifier_case AMBIGUOUS null null '"replacement after discovery"'
cp "$CLASSIFY_CASE" "$RESULT_PATH_RESOLVED"
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$RESULT_PATH_RESOLVED" "$REPO_ROOT"; then
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
assert_subagent_type "$REVIEW_PR" 'conflict-resolver' \
  "S13.1 — review-pr.md dispatches uberdev:conflict-resolver in Phase 3 CONFLICT path"
assert_grep "$REVIEW_PR" 'conflicted_files' \
  "S13.2 — review-pr.md prose names the conflicted_files YAML field from ci-rebase-handler return"
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
assert_grep "$REVIEW_PR" 'EXPECTED_OLD_SHA' \
  "S13.11 — original-lease SHA name (EXPECTED_OLD_SHA) referenced for resume push"
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
assert_grep "$REVIEW_PR" 'status: REBASED' \
  "S13.16 — POST-FIX path explicitly conditions on ci-rebase-handler status: REBASED"
assert_grep "$REVIEW_PR" 'by_agent="ci-rebase-handler\+conflict-resolver"' \
  "S13.17 — ci_fix_pushed audit event names both contributing agents on conflict-resolve push success"

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
R_START=$(grep -n 'ci-code-fixer.*`status: REFUSED`' "$REVIEW_PR" | head -1 | cut -d: -f1)
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

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
