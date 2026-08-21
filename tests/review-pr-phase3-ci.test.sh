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

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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
# The cross-fence helpers. review-pr.md calls them but defines none of them:
# a fence body is reachable only from the shell that ran it (#427), so they
# ship as code and every prologued fence loads them through rehydration.
REVIEW_FENCES="$REPO_ROOT/plugins/uberdev/lib/review-fences.sh"
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

# The MONITOR fence establishes its own run directory (#400) and reads the
# fix-push ledger out of it to decide WHICH green it reached. Every row below
# therefore needs a real directory on disk — `cd … && pwd -P` refuses a path
# that does not exist, which is the point: a garbage RUN_ID must be a hard
# failure, not a resolve-to-nothing that answers the silently-wrong `green`.
#
# `git rev-parse --show-toplevel` is STUBBED rather than backed by a real repo:
# the part carrying the bug is the `$ROOT/.uberdev/research/$RUN_ID`
# composition and the `cd` guard, not git itself, so the suite stays offline.
CI_MONITOR_RUN_ID_DEFAULT=20260809-000000-abc1234
CI_MONITOR_ROOTS="$(mktemp -d)"
# Builds a fixture repo root whose research dir contains the ledger described by
# $2: `none` (no file at all), `empty` (a real ledger recording zero pushes),
# `pushed` (one recorded ci-code-fixer push), `zero` (0-byte) or `garbage`.
make_ci_monitor_root() {
  local name="$1" kind="$2" run_id="${3:-$CI_MONITOR_RUN_ID_DEFAULT}"
  local root rundir sha40 fixture
  # #427 — the MONITOR fence resolves its own run now: it opens with the
  # rehydration prologue instead of reading RESEARCH_DIR_ABS out of a scalar an
  # exited shell bound. So the fake root is a REAL run (real repository, real
  # uberdev_command_workspace_prepare, real descriptor and reservation markers),
  # not a bare `mkdir -p`. The driver still stubs `git` — the fence's toplevel
  # lookup is faked so the path composition stays under test — but everything
  # the prologue reads off disk is now genuinely there.
  fixture="$(bash "$REPO_ROOT/tests/_lib_review_run_fixture.sh" --make-run \
    "$CI_MONITOR_ROOTS/$name" "$REPO_ROOT/plugins/uberdev" 73 "$run_id" 2>/dev/null)" || {
    echo "review-pr-phase3-ci: could not seed the CI monitor run fixture ($name)" >&2
    exit 1
  }
  root="$(printf '%s\n' "$fixture" | sed -n 1p)"
  rundir="$(printf '%s\n' "$fixture" | sed -n 3p)"
  [ -n "$root" ] && [ -n "$rundir" ] || {
    echo "review-pr-phase3-ci: CI monitor run fixture produced no paths ($name)" >&2
    exit 1
  }
  sha40="$(printf 'c%.0s' $(seq 40))"
  case "$kind" in
    none) : ;;
    empty)
      bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 1 1 "[]" "[]"' \
        _ "$ARGS_LIB_PHASE3" "$rundir" >/dev/null 2>&1 ;;
    pushed)
      bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 2 2 \
        "[{\"sha\":\"$3\",\"by_agent\":\"ci-code-fixer\"}]" "[\"code_bug\"]"' \
        _ "$ARGS_LIB_PHASE3" "$rundir" "$sha40" >/dev/null 2>&1 ;;
    zero) : >"$rundir/ci-loop-state.json" ;;
    garbage) printf 'not json' >"$rundir/ci-loop-state.json" ;;
  esac
  printf '%s\n' "$root"
}

CI_MONITOR_ROOT_NONE="$(make_ci_monitor_root noledger none)"
CI_MONITOR_ROOT_EMPTY="$(make_ci_monitor_root emptyledger empty)"
CI_MONITOR_ROOT_PUSHED="$(make_ci_monitor_root pushedledger pushed)"
CI_MONITOR_ROOT_ZERO="$(make_ci_monitor_root zeroledger zero)"
CI_MONITOR_ROOT_GARBAGE="$(make_ci_monitor_root garbageledger garbage)"

# The shared `bash -c` body both runners drive. Kept in one variable so the halt
# runner cannot drift from the state runner — they must exercise byte-identical
# stubs, or a halt row would be proving a different fence than the rows around it.
CI_MONITOR_DRIVER='
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
      # The fence recomputes its own working dir; only the toplevel lookup is
      # faked, so the path composition and the `cd` guard stay under test.
      git(){ printf "%s\n" "$CI_MONITOR_FAKE_ROOT"; }
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
      # Opt-in exactly like the carries: an EMPTY CI_MONITOR_RUN_ID leaves RUN_ID
      # genuinely unset, which is the fence-entered-without-its-carry case.
      [ -z "$CI_MONITOR_RUN_ID" ] || RUN_ID="$CI_MONITOR_RUN_ID"
      . "$1"
      printf "%s %s %s %s\n" "$CI_MONITOR_VERDICT" "$OUTCOME" \
        "$CI_MONITOR_PASSES_USED" "$CI_MONITOR_ELAPSED_SEC"
'

run_ci_monitor_case() {
  local name="$1" plan="$2" want="$3" want_audit="$4"
  # Optional cross-fence carry — exactly what the orchestrator rebinds when the
  # previous fence returned `resume`.
  local carry_deadline="${5:-}" carry_passes="${6:-}"
  # #400 bindings. `${8-…}` (no colon) so an explicit '' means "unset RUN_ID".
  local fake_root="${7:-$CI_MONITOR_ROOT_NONE}"
  local run_id="${8-$CI_MONITOR_RUN_ID_DEFAULT}" fix_phase="${9:-1}"
  local log got audit_line
  log="$(mktemp)"
  got="$(
    CI_MONITOR_PLAN="$plan" CI_MONITOR_LOG="$log" \
    CI_MONITOR_CARRY_DEADLINE="$carry_deadline" CI_MONITOR_CARRY_PASSES="$carry_passes" \
    CI_MONITOR_FAKE_ROOT="$fake_root" CI_MONITOR_RUN_ID="$run_id" \
    CI_FIX_PHASE="$fix_phase" \
    UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash -c "$CI_MONITOR_DRIVER" _ "$CI_MONITOR_FIXTURE" 2>/dev/null
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

# The halt paths cannot go through run_ci_monitor_case: they end in `exit 1` (or
# a `return 2` out of the sourced fence), which kills the whole `bash -c` before
# the state line is printed. Comparing an empty `$got` against a `want` string
# would "pass" for any reason at all, including the fence never running. Assert
# the rc and the audit event instead — and assert positively that no green
# leaked out, because the entire point of the halt is that an unreadable ledger
# must NOT resolve to an outcome.
run_ci_monitor_halt_case() {
  local name="$1" plan="$2" want_rc="$3" want_audit="$4"
  local fake_root="${5:-$CI_MONITOR_ROOT_NONE}"
  local run_id="${6-$CI_MONITOR_RUN_ID_DEFAULT}" fix_phase="${7:-1}"
  local log got rc audit_line
  log="$(mktemp)"
  got="$(
    CI_MONITOR_PLAN="$plan" CI_MONITOR_LOG="$log" \
    CI_MONITOR_CARRY_DEADLINE="" CI_MONITOR_CARRY_PASSES="" \
    CI_MONITOR_FAKE_ROOT="$fake_root" CI_MONITOR_RUN_ID="$run_id" \
    CI_FIX_PHASE="$fix_phase" \
    UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash -c "$CI_MONITOR_DRIVER" _ "$CI_MONITOR_FIXTURE" 2>/dev/null
  )"
  rc=$?
  audit_line="$(head -n 1 "$log" 2>/dev/null)"
  if [ "$rc" = "$want_rc" ] && [ "$audit_line" = "$want_audit" ] \
     && ! grep -q green <<<"$got"; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    echo "        plan:          $plan"
    echo "        want rc:       $want_rc"
    echo "        got  rc:       $rc"
    echo "        want audit:    $want_audit"
    echo "        got  audit:    $audit_line"
    echo "        got  stdout:   $got   (must contain no 'green')"
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
    "240:137 45:0" "green green 2 285" \
    "ci_monitor_green outcome=green passes=2 elapsed_sec=285"
  run_ci_monitor_case \
    "S2-RT.2 — timeout's own 124 is pending, never red" \
    "240:124 60:0" "green green 2 300" \
    "ci_monitor_green outcome=green passes=2 elapsed_sec=300"
  run_ci_monitor_case \
    "S2-RT.3 — gh's documented 8 (checks pending) continues to the next pass" \
    "240:8 20:0" "green green 2 260" \
    "ci_monitor_green outcome=green passes=2 elapsed_sec=260"
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
    "40:0" "green green 1 40" \
    "ci_monitor_green outcome=green passes=1 elapsed_sec=40"
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

  # ---- #400: WHICH green ----------------------------------------------------
  # A green from MONITOR is not one outcome, it is two: `green` (the head the
  # author pushed passed) and `green_after_fix` (an autopilot committed, rebased
  # and force-pushed, and THAT head passed). Before this, both serialised
  # identically into phases.phase3.outcome — seven readers, zero producers — so
  # a /merge trust-trail reader could not tell a rewritten head from a clean one.
  run_ci_monitor_case \
    "S2-RT.10 — a green with no ledger on disk is a plain green (first probe of the run)" \
    "40:0" "green green 1 40" \
    "ci_monitor_green outcome=green passes=1 elapsed_sec=40" \
    "" "" "$CI_MONITOR_ROOT_NONE"
  run_ci_monitor_case \
    "S2-RT.11 — a ledger recording zero fix pushes is still a plain green" \
    "40:0" "green green 1 40" \
    "ci_monitor_green outcome=green passes=1 elapsed_sec=40" \
    "" "" "$CI_MONITOR_ROOT_EMPTY"
  # S2-RT.12 is THE regression row: identical watch plan, identical verdict,
  # different ledger. It is the only thing separating the two enum members.
  run_ci_monitor_case \
    "S2-RT.12 — a green reached AFTER a recorded fix push is green_after_fix" \
    "40:0" "green green_after_fix 1 40" \
    "ci_monitor_green outcome=green_after_fix passes=1 elapsed_sec=40" \
    "" "" "$CI_MONITOR_ROOT_PUSHED"
  # S2-RT.13/14 — an unreadable ledger must HALT, not default. Folding a
  # truncated or crashed producer to "no fixes" is the `jq length … || echo 0`
  # masking class (#263/#265), and here it launders a rewritten head into a
  # clean one — precisely the signal being carried.
  run_ci_monitor_halt_case \
    "S2-RT.13 — a 0-byte ledger halts the green terminal instead of defaulting" \
    "40:0" 1 "ci_phase_outcome data.outcome=halted data.subreason=ci_loop_state_unreadable" \
    "$CI_MONITOR_ROOT_ZERO"
  run_ci_monitor_halt_case \
    "S2-RT.14 — a non-JSON ledger halts the green terminal instead of defaulting" \
    "40:0" 1 "ci_phase_outcome data.outcome=halted data.subreason=ci_loop_state_unreadable" \
    "$CI_MONITOR_ROOT_GARBAGE"
  # S2-RT.15 — RUN_ID is the primary cross-fence carry. Entered without it AND
  # without a recoverable active-run pointer, the ledger would resolve under a
  # path that does not exist, and "does not exist" is the answer `green` — a
  # wrong outcome indistinguishable from a right one. It must be a hard error
  # before any watch runs, with no audit event claiming a verdict the fence
  # never reached.
  #
  # #427 — the pointer is the SECOND channel, so the run root used here is one
  # whose pointer has been removed. A root that still carries its pointer is
  # covered by S2-RT.15b below: recovery is a feature, and this row must not
  # accidentally assert that it fails.
  CI_MONITOR_ROOT_NOPOINTER="$(make_ci_monitor_root nopointerledger pushed)"
  rm -f "$CI_MONITOR_ROOT_NOPOINTER/.uberdev/runs/.review-active-run.json"
  run_ci_monitor_halt_case \
    "S2-RT.15 — the fence refuses to run without RUN_ID and without a pointer (no silent green)" \
    "40:0" 2 "" "$CI_MONITOR_ROOT_NOPOINTER" ""
  run_ci_monitor_case \
    "S2-RT.15b — the fence recovers its run from the active-run pointer when RUN_ID is lost" \
    "40:0" "green green_after_fix 1 40" \
    "ci_monitor_green outcome=green_after_fix passes=1 elapsed_sec=40" \
    "" "" "$CI_MONITOR_ROOT_PUSHED" ""
  # S2-RT.16 — probe-only (`--no-ci-fix`) never upgrades: 6c.4 skips the fixer
  # arms, so a ledger left by an earlier run is not evidence about this head.
  run_ci_monitor_case \
    "S2-RT.16 — CI_FIX_PHASE=0 answers green even with a recorded push on disk" \
    "40:0" "green green 1 40" \
    "ci_monitor_green outcome=green passes=1 elapsed_sec=40" \
    "" "" "$CI_MONITOR_ROOT_PUSHED" "$CI_MONITOR_RUN_ID_DEFAULT" 0
  # S2-RT.17 — the ledger read must not leak into the non-green arms. Re-run the
  # red and resume plans against a NON-EMPTY ledger and require byte-identical
  # outcomes to S2-RT.4 / S2-RT.5.
  run_ci_monitor_case \
    "S2-RT.17a — a red verdict is unchanged by a non-empty ledger (matches S2-RT.4)" \
    "12:1" "red unset 1 12" "ci_monitor_red passes=1 elapsed_sec=12 rc=1" \
    "" "" "$CI_MONITOR_ROOT_PUSHED"
  run_ci_monitor_case \
    "S2-RT.17b — a resume is unchanged by a non-empty ledger (matches S2-RT.5)" \
    "240:8 240:8" "resume unset 2 480" "" \
    "" "" "$CI_MONITOR_ROOT_PUSHED"
fi
rm -f "$CI_MONITOR_FIXTURE"

echo
echo "== S2B-RUNTIME: the 6c.1 PROBE green terminal assigns an OUTCOME (#400) =="
# 6c.1's green row was PROSE — a terminal-mapping table cell reading `green`.
# Prose cannot assign an OUTCOME, and this is the arm a post-fix re-probe most
# often takes: after a fix push the flow re-enters at Step 4, Phase 1
# re-approves, and control returns HERE, where the fast path skips MONITOR
# entirely. So the one terminal most likely to see a rewritten head was the one
# with no executable terminal at all.
CI_PROBE_FIXTURE="$(mktemp)"
awk '
  /# BEGIN ci-probe-green-terminal-v1/ { active=1; next }
  /# END ci-probe-green-terminal-v1/ { exit }
  active { sub(/^    /, ""); print }
' "$REVIEW_PR" >"$CI_PROBE_FIXTURE"
if [ -s "$CI_PROBE_FIXTURE" ]; then
  echo "  PASS  S2B-RT.0 — sliced the ci-probe-green-terminal-v1 region out of review-pr.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S2B-RT.0 — could not slice ci-probe-green-terminal-v1 out of review-pr.md (markers missing/renamed?)"
  FAIL=$((FAIL + 1))
fi

CI_PROBE_DRIVER='
      set -eu
      audit(){ printf "%s\n" "$*" >>"$CI_PROBE_LOG"; }
      OUTCOME=unset
      git(){ printf "%s\n" "$CI_PROBE_FAKE_ROOT"; }
      [ -z "$CI_PROBE_RUN_ID" ] || RUN_ID="$CI_PROBE_RUN_ID"
      [ -z "$CI_PROBE_VERDICT_IN" ] || PROBE_VERDICT="$CI_PROBE_VERDICT_IN"
      . "$1"
      printf "%s\n" "$OUTCOME"
'

run_ci_probe_case() {
  local name="$1" verdict="$2" want="$3" want_audit="$4"
  local fake_root="${5:-$CI_MONITOR_ROOT_NONE}"
  local run_id="${6-$CI_MONITOR_RUN_ID_DEFAULT}" fix_phase="${7:-1}"
  local log got audit_line
  log="$(mktemp)"
  got="$(
    CI_PROBE_LOG="$log" CI_PROBE_FAKE_ROOT="$fake_root" \
    CI_PROBE_RUN_ID="$run_id" CI_PROBE_VERDICT_IN="$verdict" \
    CI_FIX_PHASE="$fix_phase" \
    UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash -c "$CI_PROBE_DRIVER" _ "$CI_PROBE_FIXTURE" 2>/dev/null
  )"
  audit_line="$(head -n 1 "$log" 2>/dev/null)"
  if [ "$got" = "$want" ] && [ "$audit_line" = "$want_audit" ]; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    echo "        PROBE_VERDICT: $verdict"
    echo "        want OUTCOME:  $want"
    echo "        got  OUTCOME:  $got"
    echo "        want audit:    $want_audit"
    echo "        got  audit:    $audit_line"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$log"
}

run_ci_probe_halt_case() {
  local name="$1" verdict="$2" want_rc="$3" want_audit="$4"
  local fake_root="${5:-$CI_MONITOR_ROOT_NONE}"
  local run_id="${6-$CI_MONITOR_RUN_ID_DEFAULT}" fix_phase="${7:-1}"
  local log got rc audit_line
  log="$(mktemp)"
  got="$(
    CI_PROBE_LOG="$log" CI_PROBE_FAKE_ROOT="$fake_root" \
    CI_PROBE_RUN_ID="$run_id" CI_PROBE_VERDICT_IN="$verdict" \
    CI_FIX_PHASE="$fix_phase" \
    UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    bash -c "$CI_PROBE_DRIVER" _ "$CI_PROBE_FIXTURE" 2>/dev/null
  )"
  rc=$?
  audit_line="$(head -n 1 "$log" 2>/dev/null)"
  if [ "$rc" = "$want_rc" ] && [ "$audit_line" = "$want_audit" ] \
     && ! grep -q green <<<"$got"; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    echo "        want rc:       $want_rc"
    echo "        got  rc:       $rc"
    echo "        want audit:    $want_audit"
    echo "        got  audit:    $audit_line"
    echo "        got  stdout:   $got   (must contain no 'green')"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$log"
}

if [ -s "$CI_PROBE_FIXTURE" ]; then
  run_ci_probe_case \
    "S2B-RT.1 — a green probe with no ledger records a plain green" \
    green green "ci_phase_outcome data.outcome=green" "$CI_MONITOR_ROOT_NONE"
  # S2B-RT.2 is the regression row for the fast path: same verdict, same probe,
  # different ledger.
  run_ci_probe_case \
    "S2B-RT.2 — a green probe after a recorded fix push records green_after_fix" \
    green green_after_fix "ci_phase_outcome data.outcome=green_after_fix" \
    "$CI_MONITOR_ROOT_PUSHED"
  run_ci_probe_case \
    "S2B-RT.3 — CI_FIX_PHASE=0 keeps the fast path at a plain green" \
    green green "ci_phase_outcome data.outcome=green" \
    "$CI_MONITOR_ROOT_PUSHED" "$CI_MONITOR_RUN_ID_DEFAULT" 0
  # S2B-RT.4 — the non-green verdicts are NON-TERMINAL here: they proceed to
  # MONITOR. This fence must leave OUTCOME alone and audit nothing, or a
  # still-running CI would be recorded as a phase outcome it never reached.
  run_ci_probe_case \
    "S2B-RT.4 — a pending probe assigns no OUTCOME and audits nothing" \
    pending unset "" "$CI_MONITOR_ROOT_PUSHED"
  run_ci_probe_halt_case \
    "S2B-RT.5 — a green probe over a malformed ledger halts instead of defaulting" \
    green 1 "ci_phase_outcome data.outcome=halted data.subreason=ci_loop_state_unreadable" \
    "$CI_MONITOR_ROOT_GARBAGE"
fi
rm -f "$CI_PROBE_FIXTURE"
rm -rf "$CI_MONITOR_ROOTS"

echo
echo "== S3: pending → red → ci-code-fixer → green (full happy path) =="
assert_subagent_type "$REVIEW_PR" 'ci-code-fixer' \
  "S3.1 — review-pr.md dispatches uberdev:ci-code-fixer (Phase 3 ROUTE)"
assert_grep "$REVIEW_PR" 'green_after_fix' \
  "S3.2 — green_after_fix outcome documented"
assert_grep "$REVIEW_PR" 're-enter Phase 1|re-enter at Step 4|post-fix.*re-enter' \
  "S3.3 — post-fix HEAD re-enters Phase 1 fanout (Q4 invariant)"
# S3.2a — S3.2 above greps for the WORD, which passed happily against a file
# where `green_after_fix` had seven readers and zero producers (#400). Documented
# is not produced. Pin the producer by name.
assert_grep "$REVIEW_PR" 'review_fleet_ci_green_outcome' \
  "S3.2a — the green_after_fix PRODUCER is called by name, not merely documented"
# S3.2b — BOTH reachable green terminals must call it. 6c.1's fast path (a
# post-fix re-probe that skips MONITOR entirely) is the one most likely to see a
# rewritten head; one terminal wired and one not is the same defect at half the
# blast radius.
S32B_CALLS="$(grep -cE 'OUTCOME="\$\(review_fleet_ci_green_outcome ' "$REVIEW_PR" || true)"
if [ "$S32B_CALLS" -ge 2 ]; then
  echo "  PASS  S3.2b — both reachable green terminals derive the outcome ($S32B_CALLS call sites)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S3.2b — expected >= 2 green terminals calling review_fleet_ci_green_outcome, found $S32B_CALLS"
  FAIL=$((FAIL + 1))
fi
# ...and no surviving claim that the member is dormant. The annotation was
# correct for as long as nothing produced the value; leaving it in place now
# would make the docs the last remaining source of the original confusion.
assert_no_grep "$REVIEW_PR" 'green_after_fix.*(DORMANT|never assigned|no fence assigns|UNREACHABLE)' \
  "S3.2c — review-pr.md carries no surviving dormancy claim for green_after_fix"

# S3.4 — exactly ONE literal `OUTCOME=green` assignment may survive, and it must
# be the probe-only arm. Every other green terminal has to defer to the library
# derivation; a second literal is a second answer to "which green", which is the
# defect itself. The pattern deliberately excludes `OUTCOME=green_after_fix`.
#
# COMMENT-STRIPPED and fence-scoped, for the same reason as S3.5: the surviving
# literal is the one the surrounding comment has to NAME in order to explain why
# it is allowed to stay. A raw line count reds on that explanation and teaches
# the next author to delete it.
S34_REPORT="$(python3 - "$REVIEW_PR" <<'PY_S34'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
fences, current = [], None
for line in lines:
    if re.match(r"^[ \t]*```bash\b", line) and current is None:
        current = []
        continue
    if current is not None and re.match(r"^[ \t]*```[ \t]*$", line):
        fences.append("\n".join(current))
        current = None
        continue
    if current is not None:
        current.append(line)

fences = [
    "\n".join(r for r in body.split("\n") if not r.lstrip().startswith("#"))
    for body in fences
]

literal = re.compile(r"OUTCOME=green([^_a-z]|$)")
total = sum(len(literal.findall(body)) for body in fences)
holders = [b for b in fences if literal.search(b)]
print("COUNT=%d" % total)
if len(holders) != 1:
    print("GUARD=expected exactly 1 bash fence holding a literal OUTCOME=green, found %d" % len(holders))
elif '[ "${CI_FIX_PHASE:-1}" = 0 ]' not in holders[0]:
    print("GUARD=the surviving literal OUTCOME=green is NOT inside the CI_FIX_PHASE=0 probe-only guard")
else:
    print("GUARD=OK")
PY_S34
)"
S34_COUNT="$(sed -n 's/^COUNT=//p' <<<"$S34_REPORT")"
S34_GUARD="$(sed -n 's/^GUARD=//p' <<<"$S34_REPORT")"
if [ "$S34_COUNT" = 1 ]; then
  echo "  PASS  S3.4a — exactly one executable literal OUTCOME=green survives in review-pr.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S3.4a — expected exactly 1 executable literal OUTCOME=green, found ${S34_COUNT:-none}"
  FAIL=$((FAIL + 1))
fi
if [ "$S34_GUARD" = OK ]; then
  echo "  PASS  S3.4b — the surviving literal sits inside the CI_FIX_PHASE=0 probe-only guard"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S3.4b — $S34_GUARD"
  FAIL=$((FAIL + 1))
fi

# S3.5 — regression guard on the masking idiom itself. `jq length … || echo 0`
# maps a crashed or 0-byte producer to "no fixes", which on THIS path launders a
# force-pushed autopilot head into a clean one (#263/#265).
#
# COMMENT-STRIPPED, and not negotiable: the code that must not use the idiom is
# precisely the code whose comments NAME the idiom in order to explain why it is
# banned. A bare `assert_no_grep` reds on the explanation and would push the next
# author to delete the reasoning rather than keep the guard.
S35_VERDICT="$(python3 - "$REVIEW_PR" "$ARGS_LIB_PHASE3" <<'PY_S35'
import re, sys

md, lib = sys.argv[1], sys.argv[2]

def strip_comments(body):
    return "\n".join(r for r in body.split("\n") if not r.lstrip().startswith("#"))

fences, current = [], None
for line in open(md, encoding="utf-8").read().split("\n"):
    if re.match(r"^[ \t]*```bash\b", line) and current is None:
        current = []
        continue
    if current is not None and re.match(r"^[ \t]*```[ \t]*$", line):
        fences.append("\n".join(current))
        current = None
        continue
    if current is not None:
        current.append(line)

masking = re.compile(r"\|\|\s*echo\s+0\b")
offenders = []
for i, body in enumerate(fences):
    if masking.search(strip_comments(body)):
        offenders.append("review-pr.md bash fence #%d" % (i + 1))
if masking.search(strip_comments(open(lib, encoding="utf-8").read())):
    offenders.append("lib/review-fleet-args.sh")

print("OK" if not offenders else "the `|| echo 0` masking idiom is LIVE in: " + ", ".join(offenders))
PY_S35
)"
if [ "$S35_VERDICT" = OK ]; then
  echo "  PASS  S3.5 — no executable line in Phase 3 folds a failed count to 0"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S3.5 — $S35_VERDICT"
  FAIL=$((FAIL + 1))
fi

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
' "$REVIEW_FENCES" > "$RESULT_PATH_HELPER"
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
echo "== S10F: formatter / linter gates classify as code_bug (#480) =="
# A `format:check` / `lint` gate is a DETERMINISTIC failure with a mechanical
# repair, and the classifier used to match none of its shapes: the run came back
# AMBIGUOUS, `validate-ci-classification` normalised that to `flaky`, and flaky
# routes to a bare `gh run rerun` that reproduces the same red.
#
# The classifier's regex table IS the runtime (an LLM reads that prose and
# matches it against the log), so these rows extract the prose's OWN regexes and
# run them against real gate output — the same technique S15 uses to run
# review-pr.md's own jq verdict expression instead of restating it. A grep for a
# literal token would pass on prose that cannot actually match a Prettier log.
CODE_BUG_SIGNAL_RES="$(
  sed -n 's/^.*`code_bug`[^`]*lines matching `\(.*\)`.*$/\1/p' "$CLASSIFIER"
)"
FORMATTER_SIGNAL_RE="$(
  sed -n 's/^.*formatter \/ linter gate[^`]*lines matching `\(.*\)`.*$/\1/p' "$CLASSIFIER"
)"

# Fixtures are verbatim gate output shapes. The Prettier one is the log from
# TheFJK/WAGYAI PR #657 that opened #480.
PRETTIER_FAIL_LOG='> app@0.1.0 format:check
> prettier --check .

Checking formatting...
[warn] src/ci-smoke/api-v1-auth.ci-smoke.test.ts
[warn] Code style issues found in the above file. Run Prettier with --write to fix.
##[error]Process completed with exit code 1.'
ESLINT_FAIL_LOG='> app@0.1.0 lint
> eslint .

/home/runner/work/app/app/src/index.ts
  12:7  error  Unexpected console statement  no-console

1 problem (1 error, 0 warnings)
##[error]Process completed with exit code 1.'
BLACK_FAIL_LOG='would reformat /home/runner/work/app/app/svc/main.py
Oh no! 1 file would be reformatted, 41 files would be left unchanged.
##[error]Process completed with exit code 1.'
RUSTFMT_FAIL_LOG='Diff in /home/runner/work/app/app/src/lib.rs at line 41:
 fn main() {
-    let x = 1;
+  let x = 1;
##[error]Process completed with exit code 1.'
# Negative controls. An over-broad signal row that matched these would classify
# a GREEN formatter gate (or an unrelated green suite) as a code bug and hand a
# mutating fixer a file with nothing wrong in it.
PRETTIER_GREEN_LOG='> app@0.1.0 format:check
> prettier --check .

Checking formatting...
All matched files use Prettier code style!'
GREEN_SUITE_LOG='Test Suites: 12 passed, 12 total
Tests:       248 passed, 248 total
Snapshots:   0 total
Time:        31.884 s'
# The `flaky` row is "AND no code_bug signal": a formatter row that also matched
# transient noise would take flake away from the one class that may re-run.
FLAKY_LOG='Error: connect ECONNRESET 140.82.121.4:443
The operation was canceled after a timeout of 360 seconds.
##[error]Process completed with exit code 1.'

# Union over every documented `code_bug` signal row: the invariant is "a
# formatter gate matches at least one code_bug signal", not "it matches the row
# added by #480". Merging the rows later must not red this.
code_bug_signal_matches() {
  local text="$1" re="" hit=1
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    if grep -qE -e "$re" <<<"$text"; then hit=0; fi
  done <<<"$CODE_BUG_SIGNAL_RES"
  return "$hit"
}

assert_code_bug_signal() {
  local desc="$1" text="$2" want="$3" got=no
  if code_bug_signal_matches "$text"; then got=yes; fi
  if [ "$got" = "$want" ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        expected code_bug match: $want, got: $got"
    FAIL=$((FAIL + 1))
  fi
}

if [ -n "$CODE_BUG_SIGNAL_RES" ]; then
  echo "  PASS  S10F.1 — classifier states its code_bug signal rows as extractable regexes"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10F.1 — no extractable code_bug signal regex in $CLASSIFIER"; FAIL=$((FAIL + 1))
fi
if [ -n "$FORMATTER_SIGNAL_RE" ]; then
  echo "  PASS  S10F.2 — a formatter / linter gate signal row exists"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10F.2 — no formatter / linter gate signal row in $CLASSIFIER"; FAIL=$((FAIL + 1))
fi
assert_code_bug_signal "S10F.3 — a Prettier --check failure matches a code_bug signal" \
  "$PRETTIER_FAIL_LOG" yes
assert_code_bug_signal "S10F.4 — an ESLint failure matches a code_bug signal" \
  "$ESLINT_FAIL_LOG" yes
assert_code_bug_signal "S10F.5 — a black --check failure matches a code_bug signal" \
  "$BLACK_FAIL_LOG" yes
assert_code_bug_signal "S10F.5b — a rustfmt --check failure matches a code_bug signal" \
  "$RUSTFMT_FAIL_LOG" yes
assert_code_bug_signal "S10F.6 — a GREEN Prettier gate matches no code_bug signal" \
  "$PRETTIER_GREEN_LOG" no
assert_code_bug_signal "S10F.7 — a green test suite matches no code_bug signal" \
  "$GREEN_SUITE_LOG" no
assert_code_bug_signal "S10F.7b — a transient connection failure matches no code_bug signal" \
  "$FLAKY_LOG" no
# The `flaky` row is defined as "AND no code_bug signal", so the formatter row
# has to count as one there too or the precedence table re-opens the same hole.
assert_grep "$CLASSIFIER" 'counts as a `code_bug` signal' \
  "S10F.8 — the formatter row counts as a code_bug signal wherever the table says so"
# Anchor derivation. code_bug REQUIRES <file>:<line> naming a real repository
# file; Prettier prints the path and no line, so the rule that turns
# `[warn] <path>` into `<path>:1` is what keeps the class routable.
assert_grep "$CLASSIFIER" '\[warn\] <path>' \
  "S10F.9 — Prettier's [warn] <path> line is named as an anchor source"
assert_grep "$CLASSIFIER" 'line component is `1`' \
  "S10F.10 — a formatter violation with no line number anchors at line 1 (whole-file repair)"
# The old rule made `(test_path):<line>` the ONLY anchor source, which forced
# every formatter failure back to AMBIGUOUS even once its class was matched.
# The claim is restated in ci-code-fixer.md, so BOTH copies are swept (#371).
assert_no_grep "$CLASSIFIER" 'If no `\(test_path\):<line>` pattern is detectable in the log, downgrade' \
  "S10F.11 — the classifier no longer treats a test-path stack frame as the only anchor source"
assert_no_grep "$CODE_FIXER_CI" 'if no `\(test_path\):<line>` pattern is detectable in the log, the classifier downgrades' \
  "S10F.12 — the fixer's restatement of the anchor rule tracks the classifier's"
assert_grep "$CODE_FIXER_CI" 'formatter' \
  "S10F.13 — the fixer contract knows the formatter / linter anchor source"
# Repair authority. Hand-formatting cannot reproduce a formatter's exact output,
# so the fixer needs the tool itself — scoped to the anchored path, because the
# controller refuses any commit that touches another file.
assert_grep "$CODE_FIXER_CI" 'ci_fix_scope_escape' \
  "S10F.14 — the fixer states why an unscoped formatter run is fatal"
assert_grep "$CODE_FIXER_CI" 'anchored path only' \
  "S10F.15 — formatter/linter repair is scoped to the anchored path only"
assert_no_grep "$CODE_FIXER_CI" '\-\-write \.|npm run format|--fix \.' \
  "S10F.16 — no whole-tree formatter invocation is documented as allowed"
assert_grep "$CODE_FIXER_CI" '\-\-no-install' \
  "S10F.17 — the formatter must already be installed in the repo (no network fetch)"
assert_grep "$CODE_FIXER_CI" 'formatter-unavailable' \
  "S10F.18 — a missing formatter is a documented refusal, not a hand-format"
# ...and that refusal token has to survive the controller's rationale predicate,
# which is what turns a REFUSED fixer into a diagnosis instead of `unspecified`.
FIXER_RATIONALE_RE="$(
  sed -n 's/^CI_FIXER_RATIONALE = re\.compile(r"\(.*\)")$/\1/p' "$CONTRACT_PY"
)"
if [ -n "$FIXER_RATIONALE_RE" ] \
  && grep -qE -e "^(${FIXER_RATIONALE_RE})\$" <<<"formatter-unavailable"; then
  echo "  PASS  S10F.19 — formatter-unavailable is a valid CI_FIXER_RATIONALE token"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10F.19 — formatter-unavailable is rejected by CI_FIXER_RATIONALE"; FAIL=$((FAIL + 1))
fi

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
assert_grep "$REVIEW_FENCES" 'actions/runs/\$CI_RUN_ID|actions/runs/\$\{CI_RUN_ID\}' \
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
    $0 == wanted "() {" { active=1 }
    active { print }
    active && $0 == "}" { exit }
  ' "$REVIEW_FENCES" >>"$CI_AUTHORITY_FIXTURE"
done

if ! grep -q '^review_clear_ci_run_selection() {' "$CI_AUTHORITY_FIXTURE" \
    || ! grep -q '^review_select_failed_ci_run() {' "$CI_AUTHORITY_FIXTURE" \
    || ! grep -q '^review_capture_ci_classification_head() {' "$CI_AUTHORITY_FIXTURE"; then
  echo "  FAIL  S18-RT.0 — could not extract all CI authority helpers from lib/review-fences.sh"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S18-RT.0 — extracted CI authority helpers from lib/review-fences.sh"
  PASS=$((PASS + 1))

  # Default/unset CI_RUN_ID is non-authoritative: the failed check's exact
  # Actions URL supplies the positive run id and event.
  #
  # FOUR columns since #418: the SELECTED row's check NAME leaves the selector
  # too. `check_name` had no producer anywhere in review-pr.md while the REFUSED
  # arm's aggregate consumed `${check_name:-unknown}` — so every CI-refusal issue
  # named `unknown` as the check that failed. The name is already the selector's
  # own tie-break key; emitting it is what makes the field producible at all.
  SELECTION_PROBE="$(_run_probe ci-checks-red)"
  unset CI_RUN_ID
  IFS=$'\t' read -r CI_RUN_ID CI_RUN_EVENT CI_RUN_CHECK_LINK CI_RUN_CHECK_NAME < <(
    bash -c '. "$1"; review_select_failed_ci_run "$2" owner/repo' \
      _ "$CI_AUTHORITY_FIXTURE" "$SELECTION_PROBE"
  )
  if [ "$CI_RUN_ID" = 991 ] && [ "$CI_RUN_EVENT" = pull_request ] \
      && [ "$CI_RUN_CHECK_LINK" = "https://github.com/owner/repo/actions/runs/991/job/1012" ] \
      && [ "${CI_RUN_CHECK_NAME:-}" = test ]; then
    echo "  PASS  S18-RT.1 — unset run id is derived from the selected failed check"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.1 — unset run id was not derived exactly (id=$CI_RUN_ID event=$CI_RUN_EVENT link=$CI_RUN_CHECK_LINK name=${CI_RUN_CHECK_NAME:-<none>})"; FAIL=$((FAIL + 1))
  fi
  CI_RUN_ID=0
  IFS=$'\t' read -r CI_RUN_ID CI_RUN_EVENT CI_RUN_CHECK_LINK CI_RUN_CHECK_NAME < <(
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
      CI_RUN_CHECK_NAME=test
      review_clear_ci_run_selection
      [ -z "$CI_RUN_ID$CI_RUN_EVENT$CI_RUN_CHECK_LINK$CI_RUN_CHECK_NAME" ] || exit 3
      review_select_failed_ci_run "$2" owner/repo
    ' _ "$CI_AUTHORITY_FIXTURE" "$RESELECT_PROBE"
  )"
  if [ "$RESELECT_RESULT" = $'992\tpull_request\thttps://github.com/owner/repo/actions/runs/992/job/1022\ttest' ]; then
    echo "  PASS  S18-RT.8 — post-push re-entry clears and reselects the new run"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S18-RT.8 — post-push selection reused stale authority ($RESELECT_RESULT)"; FAIL=$((FAIL + 1))
  fi

  # S18-RT.9 — the check name crosses a fence boundary now (#418), so a control
  # character in it would either truncate the carrier's single line or split its
  # own TSV column. The selector already rejects control characters in
  # event/link/workflow; the NAME had been exempt from that check while being
  # the one field with a free-text value the check author controls.
  CONTROL_NAME_PROBE='[{"name":"tes\tt","state":"FAILURE","bucket":"fail","event":"pull_request","link":"https://github.com/owner/repo/actions/runs/993/job/1","workflow":"Tests"}]'
  if bash -c '. "$1"; review_select_failed_ci_run "$2" owner/repo' \
      _ "$CI_AUTHORITY_FIXTURE" "$CONTROL_NAME_PROBE" >/dev/null 2>&1; then
    echo "  FAIL  S18-RT.9 — a control character in the check name was selected, not refused"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  S18-RT.9 — a control character in the check name fails closed"; PASS=$((PASS + 1))
  fi
fi
rm -f "$CI_AUTHORITY_FIXTURE"

echo
echo "== S19-RUNTIME: post-MONITOR refresh failure cannot downgrade observed red =="
POST_MONITOR_REFRESH_FIXTURE="$(mktemp)"
awk '
  /^    On a `red` MONITOR verdict, refresh the check projection before$/ { section=1 }
  section && /^    ```bash([[:space:]]|$)/ { code=1; next }
  code && /^    ```$/ { exit }
  # The rehydration prologue is a DEPENDENCY of this fence, not part of the
  # behaviour under test: the row installs its own `audit` sink and gh stub, and
  # a real review_fleet_rehydrate here would `return 2` out of the sourced
  # fixture before the refresh it exists to exercise ever ran.
  code && /lib\/review-fleet-args\.sh" \|\| return 2$/ { next }
  code && /^[[:space:]]*review_fleet_rehydrate \|\| return 2$/ { next }
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
# #438 adds two more obligations to the SAME fence, listed here so neither can
# be silently deleted: the dependent-PR gate (`gh pr list --repo`, pinned to the
# push target's own remote rather than resolved out of the cwd) and the base-tip
# ancestry proof read off the pinned authority (`base_tip_sha`).
for token in 'review_fleet_read_sidecar' 'read-ci-authority-member' \
             'review_fleet_load_ci_counters' 'review_ci_push_abort()' \
             'review_fleet_read_ci_pointer' 'rev-parse HEAD' \
             'gh pr list --repo' 'base_tip_sha'; do
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
# #438 — the base TIP crosses the SAME dead shell (6c.4 ROUTE -> 6c.4w.1 MINT)
# as the lease, so it gets the same fail-closed device rather than a
# `${CI_BASE_TIP_SHA:-}` default, which would re-open the #418 class inside the
# fix for #438.
assert "base_tip_sha" in m.CI_AUTHORITY_REQUIRED_MEMBERS["review_pr.ci.rebase"], (
    m.CI_AUTHORITY_REQUIRED_MEMBERS["review_pr.ci.rebase"])
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
  #     the fence by the resolver CALL it must contain, not by a bare opener.
  #     The key is the code token `review_resolve_same_repo_push_target`, not the
  #     gate's prose marker: keyed on prose, the FIRST fence that merely MENTIONS
  #     the gate wins, so a comment added anywhere earlier in the file silently
  #     re-points this cover at a fence that never resolves a push target — and
  #     the row then reports a fork PR "not refused" while the real gate is
  #     untested (#418 tripped exactly that, from a comment in 6c.1 PROBE);
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
      if (buf ~ /review_resolve_same_repo_push_target/) { printf "%s", buf; exit }
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
# #427 — the fence opens with review_fleet_rehydrate, which fills EMPTY carriers
# and leaves an established run alone. This row is about the cross-repository
# gate, and it runs against a fully stubbed `git` whose toplevel is a path that
# does not exist, so it establishes the run itself rather than leaving a partial
# set that would send the fence down the recovery path.
RUN_ID=20260809-000000-abc1234
RESEARCH_DIR_ABS=/repo/.uberdev/research/$RUN_ID
MARKER_DIR=/repo/.uberdev/runs/$RUN_ID
CODE_FIXER_CONTRACT="$UBERDEV_REVIEW_PLUGIN_ROOT/lib/code_fixer_contract.py"
DIFF_ARTIFACT_PATH="$RESEARCH_DIR_ABS/pr-diff.md"
CRITERIA_PATH="$RESEARCH_DIR_ABS/review-criteria.md"
COMMIT_RANGE_PATH="$RESEARCH_DIR_ABS/commit-range.txt"
PHASE1_DISPOSITION_PATH="$RESEARCH_DIR_ABS/phase1-disposition.json"
PHASE2_DISPOSITION_PATH="$RESEARCH_DIR_ABS/phase2-disposition.json"
AGG_PATH="$RESEARCH_DIR_ABS/post-impl-review-final.md"
UBERDEV_COMMAND_WORKSPACE_JSON='{"schema_version":1,"caller":"review-pr"}'
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
echo "== S33: the four values #418 left stranded across fence boundaries =="
# #399 put three cross-fence scalars onto run-dir carriers. FOUR more kept the
# `${name:-<default>}` spelling, which in a fresh harness shell reads the EMPTY
# string and takes the default every single time:
#
#   ${failure_class:-unknown} / ${check_name:-unknown} / ${signal_anchor:-unknown:1}
#       — the REFUSED arm's synthetic aggregate. Every CI-refusal issue the
#         autopilot filed recorded `unknown` / `unknown:1`: the classifier's
#         entire output erased at the moment it was written down.
#   ${PROBE_VERDICT:-unknown}
#       — ROUTE's probe-only arm. `--no-ci-fix` audited `state=unknown` and
#         forced OUTCOME=halted even when the probe had just seen green CI.
#
# A default is only legitimate where the ABSENCE is itself documented. None of
# these four has a documented default, so the fix is the carrier idiom plus a
# typed halt, never a friendlier-looking placeholder.
#
# COMMENT-STRIPPED and fence-scoped, for the same reason as S3.4/S3.5: the code
# that must not carry the placeholder is exactly the code whose comments have to
# NAME the placeholder to explain why it is gone. A raw grep reds on the
# explanation and teaches the next author to delete the reasoning.
S33_REPORT="$(python3 - "$REVIEW_PR" <<'PY_S33'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
fences, current = [], None
for line in lines:
    if re.match(r"^[ \t]*```bash\b", line) and current is None:
        current = []
        continue
    if current is not None and re.match(r"^[ \t]*```[ \t]*$", line):
        fences.append("\n".join(current))
        current = None
        continue
    if current is not None:
        current.append(line)

executable = "\n".join(
    "\n".join(r for r in body.split("\n") if not r.lstrip().startswith("#"))
    for body in fences
)

for token in ("${failure_class:-unknown}", "${check_name:-unknown}",
              "${signal_anchor:-unknown:1}", "${PROBE_VERDICT:-unknown}"):
    print("%d\t%s" % (executable.count(token), token))
PY_S33
)"
s33_placeholder_row() {
  local token="$1" desc="$2" seen
  seen="$(awk -F'\t' -v want="$token" '$2 == want { print $1 }' <<<"$S33_REPORT")"
  if [ "$seen" = 0 ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        executable occurrences of $token: ${seen:-<token not scanned>}"
    FAIL=$((FAIL + 1))
  fi
}
s33_placeholder_row '${failure_class:-unknown}' \
  "S33.1 — no executable line defaults failure_class to a placeholder"
s33_placeholder_row '${check_name:-unknown}' \
  "S33.2 — no executable line defaults check_name to a placeholder"
s33_placeholder_row '${signal_anchor:-unknown:1}' \
  "S33.3 — no executable line defaults signal_anchor to unknown:1"
s33_placeholder_row '${PROBE_VERDICT:-unknown}' \
  "S33.4 — no executable line defaults PROBE_VERDICT to a placeholder"
# ...and `check_name` must have a PRODUCER, not merely a non-defaulting reader:
# it was consumed in one place and bound in none, which is why the placeholder
# read as harmless prose for as long as it did.
assert_grep "$REVIEW_PR" 'CI_RUN_CHECK_NAME' \
  "S33.5 — the failed check's NAME is bound from the run selection (a producer exists)"
assert_no_grep "$REVIEW_PR" 'check_name: <from-ci-code-fixer-return>' \
  "S33.6 — the aggregate no longer claims check_name comes from the fixer's return"

for s33_fn in review_fleet_write_ci_probe_verdict review_fleet_read_ci_probe_verdict \
              review_fleet_write_ci_check_name review_fleet_read_ci_check_name \
              review_fleet_write_ci_classification review_fleet_read_ci_classification; do
  assert_grep "$ARGS_LIB_PHASE3" "^$s33_fn\(\) \{" \
    "S33.7.$s33_fn — the carrier primitive ships in lib/review-fleet-args.sh"
  assert_grep "$REVIEW_PR" "$s33_fn " \
    "S33.8.$s33_fn — Phase 3 calls it by name"
done

# Both halves of every carrier are typed: a write that cannot land halts where
# the answer was PAID FOR, and a read that cannot resolve halts rather than
# routing on a value it invented.
for s33_subreason in ci_probe_verdict_uncarried ci_probe_verdict_unreadable \
                     ci_check_name_uncarried ci_check_name_unreadable \
                     ci_classification_uncarried ci_classification_unreadable; do
  assert_grep "$REVIEW_PR" "data\.subreason=$s33_subreason" \
    "S33.9.$s33_subreason — the carrier failure is a typed halt, not a default"
done

echo
echo "== S33-RUNTIME: the #418 carriers survive a shell that inherited nothing =="
S33_TMP="$(mktemp -d)"
# Every case runs under `env -i`: the defect being fixed is invisible to any
# test that lets the writer's environment reach the reader (the env-passing trap
# that masked the goal-pipeline run-state bugs). A fresh interpreter with a
# cleared environment is the only shape that proves the value travels on DISK.
s33_case() {
  local name="$1" want="$2" script="$3" got rc=0 out
  out="$(env -i PATH="$PATH" bash -c "$script" _ "$ARGS_LIB_PHASE3" "$S33_TMP" 2>/dev/null)" || rc=$?
  got="$rc|$out"
  if [ "$got" = "$want" ]; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"; echo "        want rc|stdout: $want"; echo "        got  rc|stdout: $got"
    FAIL=$((FAIL + 1))
  fi
}

s33_case "S33-RT.1 — the probe verdict is written by 6c.1's shell" "0|" \
  '. "$1"; review_fleet_write_ci_probe_verdict "$2/verdict.txt" green'
s33_case "S33-RT.2 — ...and read back whole by ROUTE's" "0|green" \
  '. "$1"; review_fleet_read_ci_probe_verdict "$2/verdict.txt"'
s33_case "S33-RT.3 — a verdict outside the documented four is refused, never recorded" "2|" \
  '. "$1"; review_fleet_write_ci_probe_verdict "$2/rejected.txt" unknown'
if [ ! -e "$S33_TMP/rejected.txt" ]; then
  echo "  PASS  S33-RT.4 — the refused verdict left no carrier behind"; PASS=$((PASS + 1))
else
  echo "  FAIL  S33-RT.4 — a refused verdict still created $S33_TMP/rejected.txt"; FAIL=$((FAIL + 1))
fi
printf 'unknown\n' >"$S33_TMP/poisoned.txt"
s33_case "S33-RT.5 — the reader refuses the very placeholder the old default invented" "2|" \
  '. "$1"; review_fleet_read_ci_probe_verdict "$2/poisoned.txt"'
s33_case "S33-RT.6 — an absent verdict carrier is 'cannot tell', not a silent green" "2|" \
  '. "$1"; review_fleet_read_ci_probe_verdict "$2/never-written.txt"'

s33_case "S33-RT.7 — the failed check's name crosses the boundary intact (spaces kept)" "0|" \
  '. "$1"; review_fleet_write_ci_check_name "$2/check.txt" "shape-checks (pull_request)"'
s33_case "S33-RT.8 — ...and the REFUSED arm reads exactly what CLASSIFY selected" \
  "0|shape-checks (pull_request)" \
  '. "$1"; review_fleet_read_ci_check_name "$2/check.txt"'
s33_case "S33-RT.9 — an empty check name is refused, so no issue can name nothing" "2|" \
  '. "$1"; review_fleet_write_ci_check_name "$2/empty.txt" ""'
s33_case "S33-RT.10 — a newline-bearing name is refused, not silently truncated" "2|" \
  '. "$1"; review_fleet_write_ci_check_name "$2/multiline.txt" "$(printf "a\nb")"'

s33_case "S33-RT.11 — the classification is written by 6c.3w.2's shell" "0|" \
  '. "$1"; review_fleet_write_ci_classification "$2/class.json" code_bug "tests/foo.test.sh:12"'
s33_case "S33-RT.12 — ROUTE reads the class the classifier actually returned" "0|code_bug" \
  '. "$1"; review_fleet_read_ci_classification "$2/class.json" failure_class'
s33_case "S33-RT.13 — ...and the anchor, not unknown:1" "0|tests/foo.test.sh:12" \
  '. "$1"; review_fleet_read_ci_classification "$2/class.json" signal_anchor'
# The AMBIGUOUS shape is the one legitimate EMPTY anchor: validate-ci-classification
# reports `flaky` + "" so the caller can emit ci_classify_ambiguous_routing_as_flaky
# and re-run once. A writer that demanded a non-empty anchor would halt every
# AMBIGUOUS run — turning this fix into a new outage on the commonest red path.
s33_case "S33-RT.14 — the AMBIGUOUS shape (flaky + empty anchor) is carried, not refused" "0|" \
  '. "$1"; review_fleet_write_ci_classification "$2/ambiguous.json" flaky ""'
s33_case "S33-RT.15 — ...and its empty anchor reads back as empty, with rc 0" "0|" \
  '. "$1"; review_fleet_read_ci_classification "$2/ambiguous.json" signal_anchor'
s33_case "S33-RT.16 — a class outside CI_FAILURE_CLASS_ENUM is refused at the writer" "2|" \
  '. "$1"; review_fleet_write_ci_classification "$2/bad-class.json" unknown "tests/foo.test.sh:12"'
s33_case "S33-RT.17 — a member the record does not carry is rc 2, never an empty default" "2|" \
  '. "$1"; review_fleet_read_ci_classification "$2/class.json" check_name'
: >"$S33_TMP/zero-byte.json"
s33_case "S33-RT.18 — a 0-byte record halts the reader (the crashed-producer class)" "2|" \
  '. "$1"; review_fleet_read_ci_classification "$2/zero-byte.json" failure_class'
rm -rf "$S33_TMP"

echo
echo "== S33-FENCE: the two arms the carriers changed, EXECUTED (#418) =="
# The rows above prove the primitives. These execute the FENCES that call them,
# extracted from review-pr.md verbatim, because the two things most easily got
# wrong here are not primitive behaviour:
#
#   * ROUTE's probe-only arm must now answer `green` from the carrier, which is
#     the whole user-visible defect (`--no-ci-fix` reported a halt on green CI);
#   * 6c.1's write must NOT outrank the `ci_probe_unreachable` carve-out. That
#     branch does not exit the fence, so a `gh` outage reaches the carrier code
#     with NO verdict — and an unconditional persist-or-halt there would turn a
#     documented "Phase 3 omitted" into "Phase 3 failed". Structural greps and
#     primitive round-trips both report green on that mistake; only running the
#     fence catches it.
S33F_TMP="$(mktemp -d)"
S33F_ROUTE="$S33F_TMP/route.sh"
S33F_PROBE="$S33F_TMP/probe.sh"
# Keyed on the code each fence must contain, never on prose: see the S32-RT note.
awk '
  /^    ```bash/ { collecting = 1; buf = ""; next }
  collecting && /^    ```$/ {
    if (buf ~ /ci_route_run_dir_unreadable/) { printf "%s", buf; exit }
    collecting = 0; next
  }
  collecting { line = $0; sub(/^    /, "", line); buf = buf line "\n" }
' "$REVIEW_PR" >"$S33F_ROUTE"
awk '
  /^    ```bash/ { collecting = 1; buf = ""; next }
  collecting && /^    ```$/ {
    if (buf ~ /PROBE_VERDICT="\$\(jq -r/) { printf "%s", buf; exit }
    collecting = 0; next
  }
  collecting { line = $0; sub(/^    /, "", line); buf = buf line "\n" }
' "$REVIEW_PR" >"$S33F_PROBE"

cat >"$S33F_TMP/route-driver.sh" <<'S33F_ROUTE_DRIVER'
set -u
audit() { printf 'audit %s\n' "$*" >>"$S33F_LOG"; }
OUTCOME=unset
RESEARCH_DIR_ABS="$S33F_RUN"
UBERDEV_REVIEW_PLUGIN_ROOT="$S33F_PLUGIN"
# #427 -- the fence opens with review_fleet_rehydrate, which fills EMPTY carriers
# and leaves an established run alone. This section establishes the run itself
# (it is about the probe-verdict carrier round-trip, not run resolution, and it
# runs outside any repository), so it binds the whole set rather than a partial
# one that would send the fence down the recovery path.
RUN_ID=20260809-000000-abc1234
WORKTREE_ROOT="$S33F_RUN"
MARKER_DIR="$S33F_RUN"
CODE_FIXER_CONTRACT="$S33F_PLUGIN/lib/code_fixer_contract.py"
DIFF_ARTIFACT_PATH="$S33F_RUN/pr-diff.md"
CRITERIA_PATH="$S33F_RUN/review-criteria.md"
COMMIT_RANGE_PATH="$S33F_RUN/commit-range.txt"
PHASE1_DISPOSITION_PATH="$S33F_RUN/phase1-disposition.json"
PHASE2_DISPOSITION_PATH="$S33F_RUN/phase2-disposition.json"
AGG_PATH="$S33F_RUN/post-impl-review-final.md"
UBERDEV_COMMAND_WORKSPACE_JSON='{"schema_version":1,"caller":"review-pr"}'
. "$S33F_FENCE"
printf 'OUTCOME=%s\n' "$OUTCOME"
S33F_ROUTE_DRIVER

cat >"$S33F_TMP/probe-driver.sh" <<'S33F_PROBE_DRIVER'
set -u
audit() { printf 'audit %s\n' "$*" >>"$S33F_LOG"; }
OUTCOME=unset
PR_NUMBER=73
RESEARCH_DIR_ABS="$S33F_RUN"
UBERDEV_REVIEW_PLUGIN_ROOT="$S33F_PLUGIN"
# #427 -- the fence opens with review_fleet_rehydrate, which fills EMPTY carriers
# and leaves an established run alone. This section establishes the run itself
# (it is about the probe-verdict carrier round-trip, not run resolution, and it
# runs outside any repository), so it binds the whole set rather than a partial
# one that would send the fence down the recovery path.
RUN_ID=20260809-000000-abc1234
WORKTREE_ROOT="$S33F_RUN"
MARKER_DIR="$S33F_RUN"
CODE_FIXER_CONTRACT="$S33F_PLUGIN/lib/code_fixer_contract.py"
DIFF_ARTIFACT_PATH="$S33F_RUN/pr-diff.md"
CRITERIA_PATH="$S33F_RUN/review-criteria.md"
COMMIT_RANGE_PATH="$S33F_RUN/commit-range.txt"
PHASE1_DISPOSITION_PATH="$S33F_RUN/phase1-disposition.json"
PHASE2_DISPOSITION_PATH="$S33F_RUN/phase2-disposition.json"
AGG_PATH="$S33F_RUN/post-impl-review-final.md"
UBERDEV_COMMAND_WORKSPACE_JSON='{"schema_version":1,"caller":"review-pr"}'
# The documented outage shape: gh exits non-zero and prints stderr text where
# the JSON projection should be.
gh() { printf 'gh: connection refused\n'; return 1; }
. "$S33F_FENCE"
printf 'OUTCOME=%s\n' "$OUTCOME"
S33F_PROBE_DRIVER

# s33f_run DRIVER FENCE -> "<rc>|<stdout>", audit lines left in $S33F_TMP/audit.log
s33f_run() {
  local driver="$1" fence="$2" rc=0 out
  : >"$S33F_TMP/audit.log"
  out="$(
    S33F_LOG="$S33F_TMP/audit.log" S33F_RUN="$S33F_TMP/run" S33F_FENCE="$fence" \
    S33F_PLUGIN="$REPO_ROOT/plugins/uberdev" \
      bash "$driver" 2>/dev/null
  )" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

if [ ! -s "$S33F_ROUTE" ] || [ ! -s "$S33F_PROBE" ]; then
  echo "  FAIL  S33-FENCE.0 — could not extract the ROUTE and 6c.1 PROBE fences"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S33-FENCE.0 — extracted the ROUTE and 6c.1 PROBE fences from review-pr.md"
  PASS=$((PASS + 1))

  mkdir -p "$S33F_TMP/run"
  printf '0\n' >"$S33F_TMP/run/ci-fix-phase.txt"
  printf 'green\n' >"$S33F_TMP/run/ci-probe-verdict.txt"
  S33F_GREEN="$(s33f_run "$S33F_TMP/route-driver.sh" "$S33F_ROUTE")"
  S33F_GREEN_LOG="$(cat "$S33F_TMP/audit.log")"
  if [ "$S33F_GREEN" = "0|OUTCOME=green" ] \
     && grep -qxF 'audit ci_probe_only_skipped state=green' <<<"$S33F_GREEN_LOG"; then
    echo "  PASS  S33-FENCE.1 — --no-ci-fix over a green probe answers green, and audits state=green"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S33-FENCE.1 — the probe-only arm did not read the carrier"
    echo "        rc|stdout: $S33F_GREEN"
    echo "        audit:     $S33F_GREEN_LOG"
    FAIL=$((FAIL + 1))
  fi

  printf 'red\n' >"$S33F_TMP/run/ci-probe-verdict.txt"
  S33F_RED="$(s33f_run "$S33F_TMP/route-driver.sh" "$S33F_ROUTE")"
  S33F_RED_LOG="$(cat "$S33F_TMP/audit.log")"
  if [ "$S33F_RED" = "0|OUTCOME=halted" ] \
     && grep -qxF 'audit ci_probe_only_skipped state=red' <<<"$S33F_RED_LOG"; then
    echo "  PASS  S33-FENCE.2 — a red probe still halts probe-only, with the REAL state in the trail"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S33-FENCE.2 — the probe-only arm mis-answered a red probe"
    echo "        rc|stdout: $S33F_RED"
    echo "        audit:     $S33F_RED_LOG"
    FAIL=$((FAIL + 1))
  fi

  rm -f "$S33F_TMP/run/ci-probe-verdict.txt"
  S33F_MISSING="$(s33f_run "$S33F_TMP/route-driver.sh" "$S33F_ROUTE")"
  S33F_MISSING_LOG="$(cat "$S33F_TMP/audit.log")"
  if [ "$S33F_MISSING" = "1|" ] \
     && grep -qF 'data.subreason=ci_probe_verdict_unreadable' <<<"$S33F_MISSING_LOG" \
     && ! grep -qF 'state=unknown' <<<"$S33F_MISSING_LOG"; then
    echo "  PASS  S33-FENCE.3 — an absent verdict is a typed halt, never state=unknown"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S33-FENCE.3 — the probe-only arm guessed instead of halting"
    echo "        rc|stdout: $S33F_MISSING"
    echo "        audit:     $S33F_MISSING_LOG"
    FAIL=$((FAIL + 1))
  fi

  # THE CARVE-OUT. `gh` is down: the fence audits ci_probe_unreachable and keeps
  # going (that branch has no exit), so the carrier code runs with no verdict.
  # It must record a typed miss and leave the run's outcome alone -- Step 7 then
  # proceeds with the phases.phase3 block omitted, exactly as documented.
  S33F_OUTAGE="$(s33f_run "$S33F_TMP/probe-driver.sh" "$S33F_PROBE")"
  S33F_OUTAGE_LOG="$(cat "$S33F_TMP/audit.log")"
  if [ "$S33F_OUTAGE" = "0|OUTCOME=unset" ] \
     && grep -qF 'ci_probe_unreachable' <<<"$S33F_OUTAGE_LOG" \
     && grep -qF 'ci_probe_verdict_uncarried data.reason=no_verdict' <<<"$S33F_OUTAGE_LOG" \
     && ! grep -qF 'data.outcome=halted' <<<"$S33F_OUTAGE_LOG"; then
    echo "  PASS  S33-FENCE.4 — a gh outage stays the documented carve-out; the carry never halts it"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S33-FENCE.4 — the probe-verdict carry promoted a gh outage to a phase halt"
    echo "        rc|stdout: $S33F_OUTAGE"
    echo "        audit:     $S33F_OUTAGE_LOG"
    FAIL=$((FAIL + 1))
  fi
  if [ ! -e "$S33F_TMP/run/ci-probe-verdict.txt" ]; then
    echo "  PASS  S33-FENCE.5 — and it wrote no carrier for a probe that observed nothing"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S33-FENCE.5 — a verdict-less probe still left a carrier behind"
    FAIL=$((FAIL + 1))
  fi
fi
rm -rf "$S33F_TMP"

echo
echo "== S33-RT: cross-fence carriers, executed as TWO shells (#419) =="
# ---------------------------------------------------------------------------
# S33-RT — THE CARRIER RATCHET (#419).
#
# Every structural row above this one greps fence TEXT. A grep cannot observe a
# value that never crosses a shell boundary, so the four cross-fence carriers
# Phase 3's fix path is built on — `ci-fix-phase.txt`, `ci-push-target.tsv`,
# `ci-fixer-terminal.json` and the CONFLICT-RESOLVE arm's step 1 -> step 3 path
# set — could each be stranded and this suite would stay green. That is not
# hypothetical: #399 shipped three of them stranded behind a 290-assertion green
# run, and the whole fix path was unreachable from line one.
#
# S32-RT.14/15 established the only shape that CAN see it: extract the fence
# from review-pr.md verbatim and RUN it. This section extends that shape to the
# carriers themselves. The PRODUCING fence and the CONSUMING fence are executed
# as TWO SEPARATE shell invocations that share nothing but a run directory —
# which is exactly the boundary production crosses, since every `bash` block in
# commands/review-pr.md is a fresh shell. Each carrier gets two rows:
#
#   round-trip  — the consumer OBSERVES the value the producer wrote, proven by
#                 an effect only that value can produce (the branch names in the
#                 `git fetch` argv, the rationale bytes inside the synthetic
#                 aggregate, the conflicted pathnames in the `git add` argv).
#   fail-closed — with the carrier DELETED, the consumer halts under its
#                 documented `data.subreason` and performs no mutation.
#
# THREE FURTHER CARRIERS ARE SEEDED HERE, NOT COVERED HERE. `ci-probe-verdict.txt`,
# `ci-classification.json` and `ci-check-name.txt` (#424) are read by the same two
# consumers, ABOVE the carriers this section is about, so a row cannot reach its
# own subject without them — the rows seed them literally (s33_seed_ci_* below)
# and assert nothing about them. Their own coverage is elsewhere: S33-RUNTIME
# round-trips all three through their real primitives under `env -i`,
# S33-FENCE.1-5 round-trips the probe verdict against the real 6c.1 PROBE and
# 6c.4 ROUTE fences, and S33.9 pins all six typed halts.
#
# Only the fences' DEPENDENCIES are faked (the audit sink, the `gh`/`git` CLIs,
# `code_fixer_contract.py`, and child-dispatch.sh's input builder), never the
# fences: every byte executed below is review-pr.md's own, dedented and sourced.
# Both shells are exercised, because the harness runs these fences under
# /bin/zsh and the carriers move through `read`, `$'\t'` and array expansions
# that do not behave identically there.
# ---------------------------------------------------------------------------
S33_TMP="$(mktemp -d)" || { echo "FATAL: S33-RT could not create a scratch dir" >&2; exit 2; }
S33_LOG="$S33_TMP/fence.log"
S33_OUT="$S33_TMP/fence.out"
S33_ERR="$S33_TMP/fence.err"
S33_TRAIL="$S33_TMP/row.trail"
S33_WORKTREE="$S33_TMP/worktree"
S33_CONTRACT="$S33_TMP/contract.py"
S33_PRELUDE="$S33_TMP/prelude.sh"
S33_PLUGIN="$S33_TMP/plugin"
S33_SIDECAR="$S33_TMP/ci-fix-iter1-ci1.launch.json"
# The run identity every S33 row carries. Shape-valid so review_fleet_rehydrate
# accepts it as a carried RUN_ID rather than falling through to recovery.
S33_RUN_ID=20260809-000000-abc1234
mkdir -p "$S33_WORKTREE" "$S33_PLUGIN/lib" \
  || { echo "FATAL: S33-RT could not seed its scratch tree" >&2; exit 2; }
: >"$S33_TRAIL" || { echo "FATAL: S33-RT could not seed its scratch tree" >&2; exit 2; }

# s33_extract MARKER OUTFILE — the FIRST ```bash fence in review-pr.md whose
# BODY matches MARKER, dedented to column 0. Keyed on the body and not on the
# opener because Phase 3 mixes plain openers with info-string ones
# (```bash uberdev-executable origin=review-pr), and keyed on the opener's own
# indentation so a fence nested four or ten columns deep in a numbered list
# survives verbatim — including the column-0 heredoc bodies inside it.
s33_extract() {
  awk -v marker="$1" '
    !collecting && /^[[:space:]]*```bash([[:space:]]|$)/ {
      collecting = 1; indent = $0; sub(/```bash.*$/, "", indent); buf = ""; next
    }
    collecting && $0 == indent "```" {
      if (buf ~ marker) { printf "%s", buf; exit }
      collecting = 0; next
    }
    collecting {
      line = $0
      if (indent != "" && index(line, indent) == 1) line = substr(line, length(indent) + 1)
      buf = buf line "\n"
    }
  ' "$REVIEW_PR" >"$2"
  [ -s "$2" ]
}

# The shared driver prelude. Everything here is a DEPENDENCY of the fences, not
# a paraphrase of one: `audit` is the orchestrator's sink and `git`/`gh` are the
# CLIs. The fence helpers (`review_json_string`, `review_ci_json_member`,
# `review_ci_authority_digest`, ...) are appended REAL, from the same
# lib/review-fences.sh a prologued fence loads — stubbing them would let a
# carrier row pass over a helper that production cannot reach. Calls are logged
# one
# <angle-bracketed> argv element per token so an assertion on `git add -- a "b c"`
# cannot be satisfied by a differently-split argument list.
cat >"$S33_PRELUDE" <<'S33PRELUDE'
audit() { printf 'audit %s\n' "$*" >>"$FENCE_LOG"; }
s33_log_call() {
  local s33_name="$1" s33_arg
  shift
  printf '%s' "$s33_name" >>"$FENCE_LOG"
  for s33_arg in "$@"; do printf ' <%s>' "$s33_arg" >>"$FENCE_LOG"; done
  printf '\n' >>"$FENCE_LOG"
}
git() {
  local s33_verb=
  s33_log_call git "$@"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C | -c)
        shift
        if [ "$#" -gt 0 ]; then shift; fi
        ;;
      *) s33_verb="$1"; break ;;
    esac
  done
  case "$s33_verb" in
    fetch | add | rebase | check-ref-format) return 0 ;;
    merge-base) printf '%040d\n' 2 ;;
    rev-parse)
      case "${2:-}" in
        --show-toplevel) printf '/repo\n' ;;
        --git-path)      return 93 ;;
        *)               printf '%040d\n' 1 ;;
      esac
      ;;
    *) return 93 ;;
  esac
}
gh() {
  s33_log_call gh "$@"
  case "${1:-}" in
    repo) printf 'owner/repo\n' ;;
    pr)   printf 'fix/395-guard\nmain\nfalse\nowner/repo\n' ;;
    *)    return 90 ;;
  esac
}
S33PRELUDE
printf '. "%s" || return 1\n' "$REVIEW_FENCES" >>"$S33_PRELUDE"

# The child-dispatch adapter, reduced to the one helper the ROUTE fence calls.
# The real file loads the entire provider boundary; a carrier row must not be
# able to fail for that reason.
cat >"$S33_PLUGIN/lib/child-dispatch.sh" <<'S33CHILD'
uberdev_child_inputs_build() { printf '{"s33":"stub"}'; }
S33CHILD

# review-fleet-args.sh and review-push-target.sh are reached through the fixture
# root but are the REAL libraries: they own the carrier readers/writers
# (`review_fleet_load_ci_counters`, `review_fleet_read_sidecar`,
# `review_fleet_read_ci_pointer`, `review_fleet_unmerged_paths`) and the
# same-repository resolver whose output IS the ci-push-target carrier. Stubbing
# them would hide exactly the class this section exists to catch.
printf '. "%s" || return 1\n' "$REVIEW_FLEET_ARGS" >"$S33_PLUGIN/lib/review-fleet-args.sh"
printf '. "%s" || return 1\n' "$REPO_ROOT/plugins/uberdev/lib/review-push-target.sh" \
  >"$S33_PLUGIN/lib/review-push-target.sh"

# The code_fixer_contract.py verbs the fences shell out to, as a fixture. The
# real contract's judging logic has its own suite (code-fixer-contract.test.sh);
# what is under test HERE is whether the answer survives the shell boundary, so
# the answer is made deterministic and read from the environment.
cat >"$S33_CONTRACT" <<'S33PY'
import json, os, sys

verb = sys.argv[1] if len(sys.argv) > 1 else ""
if verb == "capture-ci-terminal":
    sys.stdout.write(json.dumps({"status_sha256": "a" * 64, "result_sha256": "b" * 64}))
elif verb == "validate-ci-mutation-outcome":
    sys.stdout.write(json.dumps({
        "status": os.environ.get("S33_TERMINAL_STATUS", "REFUSED"),
        "rationale": os.environ.get("S33_TERMINAL_RATIONALE", "forbidden-pattern"),
    }))
elif verb == "read-ci-authority-member":
    sys.stdout.write("s33-authority-member")
elif verb == "list-ci-unmerged-paths":
    for entry in os.environ.get("S33_UNMERGED_PATHS", "").split("\n"):
        if entry:
            sys.stdout.write(entry + "\0")
else:
    raise SystemExit(2)
S33PY

# The ci-fix launch sidecar 6c.4w.2 follows its pointer to. Written as literal
# bytes rather than through review_fleet_write_sidecar so the producer row is
# testing the READER, not a writer it also owns.
cat >"$S33_SIDECAR" <<'S33SIDECAR'
{"binding":"{\"edge_id\":\"review_pr.ci.fix_code\",\"ci_authority_path\":\"/s33/authority.json\",\"ci_authority_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}","child_dir":"children/s33","instance":"s33","head_before":"0000000000000000000000000000000000000000"}
S33SIDECAR

S33_FENCE_FLAG="$S33_TMP/fence-flag.sh"
S33_FENCE_GATE="$S33_TMP/fence-gate.sh"
S33_FENCE_ROUTE="$S33_TMP/fence-route.sh"
S33_FENCE_TERMINAL="$S33_TMP/fence-terminal.sh"
S33_FENCE_REFUSED="$S33_TMP/fence-refused.sh"
S33_FENCE_CONFLICT1="$S33_TMP/fence-conflict1.sh"
S33_FENCE_CONFLICT3="$S33_TMP/fence-conflict3.sh"

S33_MISSING=
s33_extract 'CI_FIX_PHASE_RUN_DIR'      "$S33_FENCE_FLAG"      || S33_MISSING="$S33_MISSING flag-producer"
s33_extract 'CROSS-REPOSITORY GATE'     "$S33_FENCE_GATE"      || S33_MISSING="$S33_MISSING gate-producer"
s33_extract 'CI_FIX_PHASE_CARRIER'      "$S33_FENCE_ROUTE"     || S33_MISSING="$S33_MISSING route-consumer"
s33_extract 'CI_MUTATION_OUTCOME'       "$S33_FENCE_TERMINAL"  || S33_MISSING="$S33_MISSING terminal-producer"
s33_extract 'CI_FIXER_TERMINAL_CARRIER' "$S33_FENCE_REFUSED"   || S33_MISSING="$S33_MISSING refused-consumer"
s33_extract 'CONFLICT_ENUM_RC'          "$S33_FENCE_CONFLICT1" || S33_MISSING="$S33_MISSING conflict-step1"
s33_extract 'CI_HEAD_BEFORE_CONTINUE'   "$S33_FENCE_CONFLICT3" || S33_MISSING="$S33_MISSING conflict-step3"

# The flag producer's own fence.
cat >"$S33_TMP/driver-flag.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# The CROSS-REPOSITORY GATE, run WITH a run dir bound so it takes the carrier
# branch (S32-RT.14/15 deliberately runs it without one).
cat >"$S33_TMP/driver-gate.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
PR_NUMBER=73
WORKTREE_ROOT=/repo
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# 6c.4 ROUTE — the consumer of BOTH ci-fix-phase.txt and ci-push-target.tsv.
cat >"$S33_TMP/driver-route.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
PR_NUMBER=73
WORKTREE_ROOT=/repo
PROBE_VERDICT=red
failure_class=code_bug
signal_anchor=tests/s33.test.sh:1
CI_RUN_ID=4242
CI_CLASSIFICATION_HEAD_SHA=00000000000000000000000000000000000000ff
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# 6c.4w.2 — the producer of ci-fixer-terminal.json.
cat >"$S33_TMP/driver-terminal.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
WORKTREE_ROOT=/repo
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# 6c.5's REFUSED arm — the consumer of ci-fixer-terminal.json.
cat >"$S33_TMP/driver-refused.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
WORKTREE_ROOT=/repo
failure_class=code_bug
check_name=shape-checks
signal_anchor=tests/s33.test.sh:1
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# CONFLICT-RESOLVE step 1 (enumerate) and step 3 (stage + continue).
cat >"$S33_TMP/driver-conflict1.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
PR_NUMBER=73
WORKTREE_ROOT="$S33_WORKTREE"
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

cat >"$S33_TMP/driver-conflict3.sh" <<'S33DRV'
set -u
. "$S33_PRELUDE"
WORKTREE_ROOT="$S33_WORKTREE"
. "$FENCE_FIXTURE"
printf 'fence-returned %s\n' "$?" >>"$FENCE_LOG"
S33DRV

# s33_run SHELL DRIVER FENCE RUN_DIR [KEY=VALUE...] -> rc, with the call log in
# $S33_LOG. `${@+"$@"}` and not `"$@"`: bash before 4.4 treats a bare `"$@"` with
# no positional parameters as an unbound expansion under `set -u`, and most of
# these runs pass no extra environment at all.
#
# EVERY invocation — producer runs included — is appended to $S33_TRAIL with its
# rc, its call log and its stderr. Only the CONSUMER's rc is asserted on (a
# producer that dies strands the carrier, which is what the consumer row is
# already the detector for), so without the trail a dead producer would surface
# as a red consumer row naming the wrong shell. Nothing is discarded silently.
s33_run() {
  local runner="$1" driver="$2" fence="$3" run_dir="$4" rc=0
  shift 4
  : >"$S33_LOG"
  : >"$S33_OUT"
  : >"$S33_ERR"
  # #427 — the fences open with `review_fleet_rehydrate`, which FILLS EMPTY
  # carriers and leaves an already-established run alone. This section
  # establishes the run explicitly (it is about Phase 3's on-disk carriers, not
  # about run resolution: `git rev-parse --show-toplevel` is stubbed to a
  # non-existent `/repo` on purpose so the path composition stays under test),
  # so it supplies the whole carrier set rather than a partial one. A partial
  # set would send the fence down the recovery path, which has no repository to
  # recover from here. The fresh-shell, nothing-bound proof of the same fences
  # lives in tests/review-pr.test.sh, where it belongs.
  env ${@+"$@"} \
    FENCE_FIXTURE="$fence" \
    FENCE_LOG="$S33_LOG" \
    RESEARCH_DIR_ABS="$run_dir" \
    RUN_ID="$S33_RUN_ID" \
    WORKTREE_ROOT="$S33_WORKTREE" \
    MARKER_DIR="$S33_WORKTREE/.uberdev/runs/$S33_RUN_ID" \
    DIFF_ARTIFACT_PATH="$run_dir/pr-diff.md" \
    CRITERIA_PATH="$run_dir/review-criteria.md" \
    COMMIT_RANGE_PATH="$run_dir/commit-range.txt" \
    PHASE1_DISPOSITION_PATH="$run_dir/phase1-disposition.json" \
    PHASE2_DISPOSITION_PATH="$run_dir/phase2-disposition.json" \
    AGG_PATH="$run_dir/post-impl-review-final.md" \
    UBERDEV_COMMAND_WORKSPACE_JSON='{"schema_version":1,"caller":"review-pr"}' \
    UBERDEV_REVIEW_PLUGIN_ROOT="$S33_PLUGIN" \
    CODE_FIXER_CONTRACT="$S33_CONTRACT" \
    S33_PRELUDE="$S33_PRELUDE" \
    S33_WORKTREE="$S33_WORKTREE" \
    "$runner" "$driver" >"$S33_OUT" 2>"$S33_ERR" || rc=$?
  {
    printf -- '--- %s %s rc=%s\n' "$runner" "${driver##*/}" "$rc"
    cat "$S33_LOG"
    cat "$S33_ERR"
  } >>"$S33_TRAIL"
  printf '%s' "$rc"
}

# s33_note LINE — fold a fact that lives on disk (a carrier's bytes, an
# artifact's bytes) into the same log the assertion reads, so one comparator
# covers "the consumer branched" and "the consumer wrote the value through".
s33_note() { printf '%s\n' "$1" >>"$S33_LOG"; }

# s33_seed_ci_classification DIR / s33_seed_ci_check_name DIR — the OTHER
# run-dir carriers a consumer fence reads on its way to the one a row is about.
# Neither is this section's subject; both are its PRECONDITION, because each
# consumer reads its carriers in a fixed order and every reader below the first
# miss is unreachable:
#
#   6c.4 ROUTE      ci-fix-phase.txt (review-pr.md:4059) -> ci-probe-verdict.txt
#                   (:4080, probe-only arm only) -> ci-classification.json
#                   (:4106,:4115) -> ci-push-target.tsv (:4146)
#   6c.5 REFUSED    ci-fixer-terminal.json (:4686) -> ci-classification.json
#                   (:4711-4712) -> ci-check-name.txt (:4713)
#
# So a row about ci-push-target.tsv never reaches the push target, and a row
# about ci-fixer-terminal.json never reaches the aggregate, unless the carriers
# ABOVE them exist. Seeding those restores the row's reach; it is the opposite
# of relaxing what the row asserts, which stays byte-identical.
#
# Literal bytes in the shapes their own writers emit
# (`review_fleet_write_ci_classification` / `review_fleet_write_ci_check_name`,
# lib/review-fleet-args.sh:839,798), for the same reason $S33_SIDECAR is
# literal: a seed built by a writer this section also owns would make the row
# depend on that writer. The values match the drivers' own decoy scalars, so
# what each row proves is unchanged from before these carriers existed —
# `code_bug` in particular keeps ROUTE on the fix_code arm it has always taken.
s33_seed_ci_classification() {
  printf '{"failure_class":"code_bug","signal_anchor":"tests/s33.test.sh:1"}\n' \
    >"$1/ci-classification.json"
}
s33_seed_ci_check_name() { printf 'shape-checks\n' >"$1/ci-check-name.txt"; }

# s33_assert DESC RC WANT_RC PRESENT_ERE ABSENT_ERE — empty pattern = not checked.
# Consumes the row's trail either way, so each row reports only its own runs.
# Herestrings, never `printf | grep -q`: an early-exiting reader on the right of
# a pipe poisons the pipeline rc under pipefail on CI (tests/epipe-guard.test.sh).
s33_assert() {
  local desc="$1" rc="$2" want_rc="$3" present="$4" absent="$5" log
  log="$(cat "$S33_LOG")"
  if [ "$rc" = "$want_rc" ] \
     && { [ -z "$present" ] || grep -qE -e "$present" <<<"$log"; } \
     && { [ -z "$absent" ] || ! grep -qE -e "$absent" <<<"$log"; }; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        consumer rc: $rc (want $want_rc)"
    [ -n "$present" ] && echo "        expected to match: $present"
    [ -n "$absent" ] && echo "        expected NOT to match: $absent"
    echo "        consumer log: $log"
    echo "        every run in this row (producers first):"
    cat "$S33_TRAIL"
    FAIL=$((FAIL + 1))
  fi
  : >"$S33_TRAIL"
}

if [ -n "$S33_MISSING" ]; then
  echo "  FAIL  S33-RT — fences could not be extracted from review-pr.md:$S33_MISSING"
  FAIL=$((FAIL + 1))
else
  for s33_shell in bash zsh; do
    if ! command -v "$s33_shell" >/dev/null 2>&1; then
      echo "  SKIP  S33-RT.* ($s33_shell) — shell unavailable on this runner"
      continue
    fi

    # --- ci-fix-phase.txt : Step 1 argument parsing -> 6c.4 ROUTE -------------
    # The flag that decides whether a code-mutating, force-pushing phase runs at
    # all. Held in a scalar it was gone before ROUTE read it, so `--no-ci-fix`
    # silently mutated and pushed on every run (#399).
    S33_DIR="$S33_TMP/flag-roundtrip-$s33_shell"
    mkdir -p "$S33_DIR"
    s33_run "$s33_shell" "$S33_TMP/driver-flag.sh" "$S33_FENCE_FLAG" "$S33_DIR" ARGUMENTS=--no-ci-fix >/dev/null
    # The probe-only arm this row drives ROUTE into is exactly the fence that
    # reads 6c.1's verdict carrier (review-pr.md:4080), so the carrier has to be
    # there for the arm to be reachable at all. Same seed shape as S33-FENCE.1,
    # which is the row that owns this carrier's own round-trip.
    printf 'green\n' >"$S33_DIR/ci-probe-verdict.txt"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-route.sh" "$S33_FENCE_ROUTE" "$S33_DIR")"
    s33_note "carrier <$(cat "$S33_DIR/ci-fix-phase.txt" 2>/dev/null)>"
    s33_assert "S33-RT.1 ($s33_shell) — --no-ci-fix crosses to ROUTE: probe-only, no fetch" \
      "$S33_RC" 0 '^audit ci_probe_only_skipped' '<fetch>|ci_fix_phase_unreadable'

    S33_DIR="$S33_TMP/flag-failclosed-$s33_shell"
    mkdir -p "$S33_DIR"
    s33_run "$s33_shell" "$S33_TMP/driver-flag.sh" "$S33_FENCE_FLAG" "$S33_DIR" ARGUMENTS=--no-ci-fix >/dev/null
    rm -f "$S33_DIR/ci-fix-phase.txt"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-route.sh" "$S33_FENCE_ROUTE" "$S33_DIR")"
    s33_assert "S33-RT.2 ($s33_shell) — carrier deleted: ROUTE halts ci_fix_phase_unreadable, mutates nothing" \
      "$S33_RC" 1 'data\.subreason=ci_fix_phase_unreadable' '<fetch>|fence-returned'

    # --- ci-push-target.tsv : CROSS-REPOSITORY GATE -> 6c.4 ROUTE ------------
    # The head/base pair. Read as `${pr_head_branch:-}` across the boundary it
    # was the empty string on every run, so ROUTE halted unconditionally and
    # fix_code / stale_base / the CONFLICT arm / the leased push were all
    # unreachable (#399). The proof it crossed is the fetch argv.
    S33_DIR="$S33_TMP/target-roundtrip-$s33_shell"
    mkdir -p "$S33_DIR"
    s33_run "$s33_shell" "$S33_TMP/driver-flag.sh" "$S33_FENCE_FLAG" "$S33_DIR" ARGUMENTS=--no-simplify >/dev/null
    s33_run "$s33_shell" "$S33_TMP/driver-gate.sh" "$S33_FENCE_GATE" "$S33_DIR" >/dev/null
    s33_seed_ci_classification "$S33_DIR"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-route.sh" "$S33_FENCE_ROUTE" "$S33_DIR")"
    s33_note "carrier <$(cat "$S33_DIR/ci-push-target.tsv" 2>/dev/null)>"
    s33_assert "S33-RT.3 ($s33_shell) — the resolver's head/base pair reaches ROUTE's fetch argv" \
      "$S33_RC" 0 '^git <-C> </repo> <fetch> <origin> <fix/395-guard> <main>$' \
      'ci_fix_dispatch_refs_unreadable|ci_probe_only_skipped'

    S33_DIR="$S33_TMP/target-failclosed-$s33_shell"
    mkdir -p "$S33_DIR"
    s33_run "$s33_shell" "$S33_TMP/driver-flag.sh" "$S33_FENCE_FLAG" "$S33_DIR" ARGUMENTS=--no-simplify >/dev/null
    s33_run "$s33_shell" "$S33_TMP/driver-gate.sh" "$S33_FENCE_GATE" "$S33_DIR" >/dev/null
    # Seeded, then the push target ALONE is deleted: with every carrier ROUTE
    # reads before it present, the halt below is attributable to this carrier's
    # absence and nothing else.
    s33_seed_ci_classification "$S33_DIR"
    rm -f "$S33_DIR/ci-push-target.tsv"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-route.sh" "$S33_FENCE_ROUTE" "$S33_DIR")"
    s33_assert "S33-RT.4 ($s33_shell) — carrier deleted: ROUTE halts ci_fix_dispatch_refs_unreadable, never fetches" \
      "$S33_RC" 1 '^audit ci_fix_dispatch_refs_unreadable$' '<fetch>|fence-returned'

    # --- ci-fixer-terminal.json : 6c.4w.2 -> 6c.5 REFUSED arm ----------------
    # The validated terminal and its rationale. Inherited as a variable the
    # rationale was ALWAYS `unspecified`, so every CI-refusal issue was filed
    # with the cause erased (#399). The proof it crossed is the rationale inside
    # the synthetic aggregate the arm writes.
    S33_DIR="$S33_TMP/terminal-roundtrip-$s33_shell"
    mkdir -p "$S33_DIR"
    printf '%s\n' "$S33_SIDECAR" >"$S33_DIR/ci-fix-launch-pointer.txt"
    s33_run "$s33_shell" "$S33_TMP/driver-terminal.sh" "$S33_FENCE_TERMINAL" "$S33_DIR" >/dev/null
    s33_seed_ci_classification "$S33_DIR"
    s33_seed_ci_check_name "$S33_DIR"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-refused.sh" "$S33_FENCE_REFUSED" "$S33_DIR")"
    s33_note "carrier <$(cat "$S33_DIR/ci-fixer-terminal.json" 2>/dev/null)>"
    s33_note "aggregate <$(tr -d '\n' <"$S33_DIR/ci-refused-synthetic-1.md" 2>/dev/null)>"
    s33_assert "S33-RT.5 ($s33_shell) — the validated terminal + rationale reach the REFUSED arm's aggregate" \
      "$S33_RC" 0 '^aggregate <.*"rationale":"forbidden-pattern".*>$' \
      'ci_fixer_terminal_uncarried|ci_fixer_terminal_mismatch'

    S33_DIR="$S33_TMP/terminal-failclosed-$s33_shell"
    mkdir -p "$S33_DIR"
    printf '%s\n' "$S33_SIDECAR" >"$S33_DIR/ci-fix-launch-pointer.txt"
    s33_run "$s33_shell" "$S33_TMP/driver-terminal.sh" "$S33_FENCE_TERMINAL" "$S33_DIR" >/dev/null
    # Seeded, then the terminal ALONE is deleted — same reason as S33-RT.4: the
    # arm's two later carrier reads are present, so ci_fixer_terminal_uncarried
    # is the halt this row's deletion caused.
    s33_seed_ci_classification "$S33_DIR"
    s33_seed_ci_check_name "$S33_DIR"
    rm -f "$S33_DIR/ci-fixer-terminal.json"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-refused.sh" "$S33_FENCE_REFUSED" "$S33_DIR")"
    s33_note "aggregate-exists <$([ -e "$S33_DIR/ci-refused-synthetic-1.md" ] && echo yes || echo no)>"
    s33_assert "S33-RT.6 ($s33_shell) — carrier deleted: the REFUSED arm halts ci_fixer_terminal_uncarried, files nothing" \
      "$S33_RC" 1 'data\.subreason=ci_fixer_terminal_uncarried' 'aggregate-exists <yes>|fence-returned'

    # --- ci-conflict-paths-*.zlist : CONFLICT-RESOLVE step 1 -> step 3 --------
    # The conflicted-path set. Held in a shell array it was EMPTY in step 3, and
    # `git add --` with zero pathspecs exits 0 — so "all RESOLVED" was vacuous
    # and the `rebase --continue` that followed failed on a still-unmerged index
    # forever. NUL transport is load-bearing: a conflicted path may contain a
    # space, so the set below carries one.
    S33_DIR="$S33_TMP/conflict-roundtrip-$s33_shell"
    mkdir -p "$S33_DIR"
    printf '{"binding":"{\\"edge_id\\":\\"review_pr.ci.resolve_conflict\\"}"}\n' \
      >"$S33_DIR/ci-conflicts-iter1-ci1.launched"
    s33_run "$s33_shell" "$S33_TMP/driver-conflict1.sh" "$S33_FENCE_CONFLICT1" "$S33_DIR" \
      S33_UNMERGED_PATHS='alpha.txt
beta gamma.txt' >/dev/null
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-conflict3.sh" "$S33_FENCE_CONFLICT3" "$S33_DIR")"
    s33_assert "S33-RT.7 ($s33_shell) — step 1's enumerated set reaches step 3's git add argv, spaces intact" \
      "$S33_RC" 0 '^git <-C> <.*> <add> <--> <alpha\.txt> <beta gamma\.txt>$' \
      'rebase_conflict_paths_missing|rebase_conflict_ledger_missing'

    S33_DIR="$S33_TMP/conflict-failclosed-$s33_shell"
    mkdir -p "$S33_DIR"
    printf '{"binding":"{\\"edge_id\\":\\"review_pr.ci.resolve_conflict\\"}"}\n' \
      >"$S33_DIR/ci-conflicts-iter1-ci1.launched"
    s33_run "$s33_shell" "$S33_TMP/driver-conflict1.sh" "$S33_FENCE_CONFLICT1" "$S33_DIR" \
      S33_UNMERGED_PATHS='alpha.txt
beta gamma.txt' >/dev/null
    rm -f "$S33_DIR/ci-conflict-paths-iter1-ci1.zlist"
    S33_RC="$(s33_run "$s33_shell" "$S33_TMP/driver-conflict3.sh" "$S33_FENCE_CONFLICT3" "$S33_DIR")"
    s33_assert "S33-RT.8 ($s33_shell) — carrier deleted: step 3 halts rebase_conflict_paths_missing, stages nothing" \
      "$S33_RC" 1 'data\.subreason=rebase_conflict_paths_missing' '<add>|fence-returned'
  done
fi
rm -rf "$S33_TMP"

echo
echo "== S34: Phase 3's leased push is STACK-SAFE (#438) =="
# Two halves of one defect, and they ship together because half one manufactures
# exactly the repository state half two cannot police.
#
#   HALF 1 — `--force-with-lease` + `--force-if-includes` protect only THIS PR's
#     head. They say nothing about who BASES on that branch. A leased push that
#     rewrites a branch another open PR is stacked on returns 0, collapses that
#     PR's merge-base, and silently grows its diff — with no audit event and no
#     halt. The gate is a `gh pr list --base <head branch>` query immediately
#     before the push, in the SAME fence.
#
#   HALF 2 — the rebase guard asserted ancestry against `base_sha`, which 6c.4
#     ROUTE pins as a MERGE-BASE. Once the base branch is force-pushed that
#     merge-base collapses to the main fork point, which every candidate rebase
#     target contains, so the assertion passes unconditionally. The base TIP is
#     the value that discriminates, and it travels on the SAME digest-pinned
#     authority channel the lease does.
assert_grep "$REVIEW_PR" 'CI_BASE_TIP_SHA="\$\(git -C "\$WORKTREE_ROOT" rev-parse "refs/remotes/origin/\$CI_BASE_BRANCH"\)"' \
  "S34.1 — 6c.4 ROUTE captures the base branch's TIP, not only the merge-base"
# ...and the capture must be a SEPARATE statement: S21.10 pins the merge-base
# spelling, and folding the two into one command would silently retire it.
assert_grep "$REVIEW_PR" 'CI_BASE_SHA=.*merge-base' \
  "S34.2 — the pre-rebase merge-base pin survives alongside the tip"
if grep -qF -- '--base-tip-sha "$CI_BASE_TIP_SHA"' <<<"$MINT_FENCE"; then
  echo "  PASS  S34.3 — the rebase mint pins the base tip into the authority"; PASS=$((PASS + 1))
else
  echo "  FAIL  S34.3 — the base tip never reaches the digest-pinned authority (it dies with ROUTE's shell)"; FAIL=$((FAIL + 1))
fi
# The typed halts, registered the way ci_push_target_cross_repository is: a
# doc-presence grep here, a runtime assertion on the audit line below.
for s34_subreason in ci_push_would_rewrite_stacked_base \
                     ci_dependent_pr_probe_unreadable \
                     ci_push_head_detached_from_base; do
  if grep -qF "review_ci_push_abort $s34_subreason" <<<"$PUSH_FENCE"; then
    echo "  PASS  S34.4.$s34_subreason — the halt is typed and lives in the push fence"; PASS=$((PASS + 1))
  else
    echo "  FAIL  S34.4.$s34_subreason — no typed halt for this state in the push fence"; FAIL=$((FAIL + 1))
  fi
done
# A gh outage is NOT the 6c.1 `ci_probe_unreachable` carve-out. That carve-out's
# whole justification is that a probe is READ-ONLY: an unreachable probe costs a
# trust signal, not a repository. This gate guards a FORCE-PUSH, and "gh is down"
# is a different answer from "no PR is stacked on this branch". Same precedent
# the cross-repository gate cites at 6c.4w.0: a probe that cannot read checks may
# proceed, a push that cannot name — or clear — its ref may not.
# Comment-stripped, like S29.1b: the fence is REQUIRED to explain why it does not
# take the carve-out, and a grep that cannot tell prose from code would forbid
# the explanation instead of the behaviour.
PUSH_FENCE_CODE="$(sed -e 's/[[:space:]]*#.*$//' <<<"$PUSH_FENCE")"
if ! grep -qF 'ci_probe_unreachable' <<<"$PUSH_FENCE_CODE"; then
  echo "  PASS  S34.5 — the push fence does not borrow the read-only probe's carve-out"; PASS=$((PASS + 1))
else
  echo "  FAIL  S34.5 — a gh outage can reach the force-push wearing ci_probe_unreachable"; FAIL=$((FAIL + 1))
fi
# BOTH ancestry proofs, never one replacing the other.
if grep -qF 'ci_rebase_base_not_ancestor' "$CONTRACT_PY" \
   && grep -qF 'ci_rebase_base_tip_not_ancestor' "$CONTRACT_PY"; then
  echo "  PASS  S34.6 — the judge keeps the merge-base proof AND gains the base-tip proof"; PASS=$((PASS + 1))
else
  echo "  FAIL  S34.6 — the rebase judge has only one ancestry predicate"; FAIL=$((FAIL + 1))
fi
# The gate refuses REWRITES, not pushes. `fix_code`'s terminal is pinned to a
# single commit on top of head_before, so its push is a fast-forward and cannot
# move any dependent PR's merge-base; gating it would disable Phase 3 CI autofix
# on every stacked branch for no safety gain. The discriminator has to be the
# push SHAPE — is the lease an ancestor of the new head — because the CONFLICT
# terminal re-enters this fence and the edge id alone cannot answer it.
if grep -qF 'merge-base --is-ancestor "$CI_LEASE_SHA" "$NEW_HEAD_SHA"' <<<"$PUSH_FENCE"; then
  echo "  PASS  S34.7 — the dependent-PR gate is asked only of a push that rewrites"; PASS=$((PASS + 1))
else
  echo "  FAIL  S34.7 — the gate refuses fast-forward pushes that rewrite nothing"; FAIL=$((FAIL + 1))
fi
# Unpinned, `gh` resolves a repository from the cwd's remotes on its own
# precedence (upstream > github > origin) and honours $GH_REPO and
# remote.<n>.gh-resolved — so it can return a well-formed empty array for a
# DIFFERENT repository. That is fail-OPEN inside a fail-closed gate, so the
# query must name the repository the push targets.
if grep -qF 'gh pr list --repo "$CI_PUSH_REPO_SLUG" --base "$CI_PR_HEAD_BRANCH" --state open --json number' <<<"$PUSH_FENCE" \
   && grep -qF 'git -C "$WORKTREE_ROOT" remote get-url origin' <<<"$PUSH_FENCE"; then
  echo "  PASS  S34.8 — the dependent-PR query is pinned to the push target's own remote"; PASS=$((PASS + 1))
else
  echo "  FAIL  S34.8 — the query lets gh pick a repository out of the cwd"; FAIL=$((FAIL + 1))
fi

echo
echo "== S34-FENCE: THE SINGLE LEASED PUSH, executed against a real remote (#438) =="
# Structural greps cannot answer "did it push?". These rows extract 6c.4w.3
# verbatim, hand it a real two-repository fixture, a real digest-pinned
# authority and a stubbed `gh`, and assert on the RECORDED GIT ARGV — the only
# evidence that distinguishes "halted before the push" from "halted after it".
S34_TMP="$(mktemp -d)"
S34_PLUGIN="$REPO_ROOT/plugins/uberdev"
S34_CONTRACT="$S34_PLUGIN/lib/code_fixer_contract.py"
S34_ARGS="$S34_PLUGIN/lib/review-fleet-args.sh"
awk '
  /^    ```bash/ { collecting = 1; buf = ""; next }
  collecting && /^    ```$/ {
    if (buf ~ /--force-with-lease=/) { printf "%s", buf; exit }
    collecting = 0; next
  }
  collecting { line = $0; sub(/^    /, "", line); buf = buf line "\n" }
' "$REVIEW_PR" >"$S34_TMP/push-fence.sh"

cat >"$S34_TMP/driver.sh" <<'S34DRIVER'
set -u
audit() { printf 'audit %s\n' "$*" >>"$S34_LOG"; }
# EVERY git invocation is recorded before it runs, so "no push happened" is an
# assertion about argv rather than about an exit code that a halt also produces.
git() { printf 'git %s\n' "$*" >>"$S34_GITLOG"; command git "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$S34_GITLOG"
  case "$S34_GH" in
    none)      printf '[]\n' ;;
    dependent) printf '[{"number":99}]\n' ;;
    outage)    printf 'gh: could not connect to api.github.com\n' >&2; return 1 ;;
    prose)     printf 'not json at all\n' ;;
    *)         return 90 ;;
  esac
}
OUTCOME=unset
PR_NUMBER=438
WORKTREE_ROOT="$S34_REPO"
RESEARCH_DIR_ABS="$S34_RUN"
CODE_FIXER_CONTRACT="$S34_CONTRACT_PY"
UBERDEV_REVIEW_PLUGIN_ROOT="$S34_PLUGIN_ROOT"
# #427 -- the fence opens with review_fleet_rehydrate, which fills EMPTY
# carriers and leaves an established run alone. This section establishes the
# run itself (it is about the guarded push, not run resolution), so it binds
# the whole set rather than a partial one that would send the fence down the
# recovery path.
RUN_ID=20260809-000000-abc1234
MARKER_DIR="$S34_RUN"
DIFF_ARTIFACT_PATH="$S34_RUN/pr-diff.md"
CRITERIA_PATH="$S34_RUN/review-criteria.md"
COMMIT_RANGE_PATH="$S34_RUN/commit-range.txt"
PHASE1_DISPOSITION_PATH="$S34_RUN/phase1-disposition.json"
PHASE2_DISPOSITION_PATH="$S34_RUN/phase2-disposition.json"
AGG_PATH="$S34_RUN/post-impl-review-final.md"
UBERDEV_COMMAND_WORKSPACE_JSON='{"schema_version":1,"caller":"review-pr"}'
. "$S34_FENCE"
printf 'OUTCOME=%s\n' "$OUTCOME"
S34DRIVER

# s34_build HEAD_MODE TIP_MODE -> rebuilds the fixture from scratch.
#   HEAD_MODE  stacked   = local fix/b descends from origin/fix/b (a FAST-FORWARD
#                          push: what the fix_code edge always produces)
#              rewritten = local fix/b was rebuilt off origin/fix/a's tip, so it
#                          still descends from the pinned base tip but NOT from
#                          the lease — a genuine history REWRITE
#              detached  = local fix/b was rebuilt off main instead
#   TIP_MODE   pinned   = the authority carries the real base tip
#              lost     = the authority carries an empty base_tip_sha
#
# `origin` deliberately lives at <owner>/<name>.git and a second `upstream`
# remote is deliberately present: the dependent-PR query must name the
# repository the PUSH targets, and an unpinned `gh` would resolve `upstream`
# first (gh's own remote precedence is upstream > github > origin).
s34_build() {
  local head_mode="$1" tip_mode="$2"
  rm -rf "$S34_TMP/fixture-owner" "$S34_TMP/other-owner" "$S34_TMP/repo" "$S34_TMP/run"
  mkdir -p "$S34_TMP/run" "$S34_TMP/fixture-owner" "$S34_TMP/other-owner"
  command git init -q --bare "$S34_TMP/fixture-owner/fixture-repo.git"
  command git init -q --bare "$S34_TMP/other-owner/other-repo.git"
  command git init -q -b main "$S34_TMP/repo"
  command git -C "$S34_TMP/repo" config user.email fixture@example.invalid
  command git -C "$S34_TMP/repo" config user.name Fixture
  printf 'm0\n' >"$S34_TMP/repo/m.txt"
  command git -C "$S34_TMP/repo" add -- m.txt
  command git -C "$S34_TMP/repo" commit -qm 'test: m0'
  command git -C "$S34_TMP/repo" checkout -q -b fix/a
  printf 'A1\n' >"$S34_TMP/repo/a.txt"
  command git -C "$S34_TMP/repo" add -- a.txt
  command git -C "$S34_TMP/repo" commit -qm 'test: A1'
  command git -C "$S34_TMP/repo" checkout -q -b fix/b
  printf 'B1\n' >"$S34_TMP/repo/b.txt"
  command git -C "$S34_TMP/repo" add -- b.txt
  command git -C "$S34_TMP/repo" commit -qm 'test: B1'
  command git -C "$S34_TMP/repo" remote add origin "$S34_TMP/fixture-owner/fixture-repo.git"
  command git -C "$S34_TMP/repo" remote add upstream "$S34_TMP/other-owner/other-repo.git"
  command git -C "$S34_TMP/repo" push -q origin main fix/a fix/b
  command git -C "$S34_TMP/repo" fetch -q origin
  S34_LEASE="$(command git -C "$S34_TMP/repo" rev-parse refs/remotes/origin/fix/b)"
  S34_BASE_TIP="$(command git -C "$S34_TMP/repo" rev-parse refs/remotes/origin/fix/a)"
  S34_MERGE_BASE="$(command git -C "$S34_TMP/repo" merge-base \
    refs/remotes/origin/fix/b refs/remotes/origin/fix/a)"
  if [ "$head_mode" = detached ]; then
    # What a rebase onto the WRONG target leaves behind: HEAD moved, the lease
    # still holds, the worktree is clean — and the PR is no longer descended
    # from the branch it is stacked on.
    command git -C "$S34_TMP/repo" checkout -q -B fix/b refs/remotes/origin/main
  elif [ "$head_mode" = rewritten ]; then
    # What a real rebase leaves behind: B1 is replaced, so the new head still
    # descends from the pinned base tip (origin/fix/a) but NOT from the lease
    # (origin/fix/b). This is the only push shape that can collapse a dependent
    # PR's merge-base, and therefore the only shape the gate may refuse.
    command git -C "$S34_TMP/repo" checkout -q -B fix/b refs/remotes/origin/fix/a
  fi
  # The fixer's own commit, so the fence's ci_fix_no_change guard passes.
  printf 'FIXED\n' >"$S34_TMP/repo/fix.txt"
  command git -C "$S34_TMP/repo" add -- fix.txt
  command git -C "$S34_TMP/repo" commit -qm 'test: the fixer commit'
  S34_NEW_HEAD="$(command git -C "$S34_TMP/repo" rev-parse HEAD)"

  local evidence="$S34_TMP/repo/.uberdev/research/20260810-131313-438f438"
  local child="$evidence/children/ci-rebase-ci01-iter01"
  mkdir -p "$child"
  printf '{"edge":"rebase"}\n' >"$child/input.json"
  local input_sha
  input_sha="$(python3 -I -B -c '
import hashlib, sys
sys.stdout.write(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$child/input.json")"
  S34_AUTHORITY="$evidence/ci-authority-rebase-iter01-ci01.json"
  local receipt
  receipt="$(python3 -I -B "$S34_CONTRACT" prepare-ci-authority \
    --edge-id review_pr.ci.rebase --pr-number 438 --run-id 77 \
    --head-sha "$S34_LEASE" --working-dir "$S34_TMP/repo" \
    --input-path "$child/input.json" --input-sha256 "$input_sha" \
    --base-sha "$S34_MERGE_BASE" --base-tip-sha "$S34_BASE_TIP" \
    --lease-sha "$S34_LEASE" --pr-branch fix/b --base-branch fix/a \
    --authority-output-path "$S34_AUTHORITY")" || return 2
  S34_AUTHORITY_SHA="$(jq -er .authority_sha256 <<<"$receipt")" || return 2
  local binding
  binding="$(python3 -I -B "$S34_CONTRACT" bind-workflow-ci-launch \
    --edge-id review_pr.ci.rebase --instance-id ci-rebase-ci01-iter01 \
    --run-nonce "$(printf '4%.0s' $(seq 64))" \
    --result-path "$child/result.md" --status-path "$child/status.json" \
    --working-dir "$S34_TMP/repo" \
    --ci-authority-path "$S34_AUTHORITY" \
    --ci-authority-sha256 "$S34_AUTHORITY_SHA")" || return 2
  if [ "$tip_mode" = lost ]; then
    # THE #418/#419 SHAPE. The value went missing between the fence that binds
    # it and the fence that force-pushes on it. The digest is re-pointed too, so
    # this is not a tampering row: it models the authority genuinely carrying no
    # tip, and asks whether the push fence defaults or halts.
    python3 -I -B -c '
import json, hashlib, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("cfc", sys.argv[2])
m = importlib.util.module_from_spec(spec)
# Registered BEFORE exec_module: @dataclass resolves its own module out of
# sys.modules, and an unregistered one dies AttributeError on 3.14.
sys.modules[spec.name] = m
spec.loader.exec_module(m)
doc = json.loads(open(sys.argv[1], "rb").read())
doc["base_tip_sha"] = ""
payload = m._canonical_json(doc) + b"\n"
# The publisher leaves the authority read-only on purpose, so the fixture
# replaces the file rather than writing through it.
os.chmod(sys.argv[1], 0o600)
os.unlink(sys.argv[1])
with open(sys.argv[1], "wb") as handle:
    handle.write(payload)
sys.stdout.write(hashlib.sha256(payload).hexdigest())
' "$S34_AUTHORITY" "$S34_CONTRACT" >"$S34_TMP/relost.txt" || return 2
    S34_AUTHORITY_SHA="$(cat "$S34_TMP/relost.txt")"
    binding="$(jq -c --arg d "$S34_AUTHORITY_SHA" '.ci_authority_sha256 = $d' <<<"$binding")" || return 2
  fi
  printf 'child report\n' >"$child/result.md"
  printf '{}\n' >"$child/status.json"
  bash -c '. "$1"; review_fleet_write_sidecar "$2" "$3" "$4" ci-rebase-ci01-iter01 "$5"' \
    _ "$S34_ARGS" "$S34_TMP/run/sidecar.json" "$binding" "$child" "$S34_LEASE" || return 2
  bash -c '. "$1"; review_fleet_write_ci_pointer "$2" "$3"' \
    _ "$S34_ARGS" "$S34_TMP/run/ci-fix-launch-pointer.txt" "$S34_TMP/run/sidecar.json" || return 2
}

# s34_run SHELL GH_MODE -> "<rc>|<stdout>"; audit in $S34_TMP/audit.log, argv in
# $S34_TMP/git.log
s34_run() {
  local runner="$1" gh_mode="$2" rc=0 out
  : >"$S34_TMP/audit.log"
  : >"$S34_TMP/git.log"
  out="$(
    S34_LOG="$S34_TMP/audit.log" S34_GITLOG="$S34_TMP/git.log" \
    S34_GH="$gh_mode" S34_REPO="$S34_TMP/repo" S34_RUN="$S34_TMP/run" \
    S34_FENCE="$S34_TMP/push-fence.sh" S34_CONTRACT_PY="$S34_CONTRACT" \
    S34_PLUGIN_ROOT="$S34_PLUGIN" \
      "$runner" "$S34_TMP/driver.sh" 2>/dev/null
  )" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# s34_pushed -> 0 when the recorded argv contains the leased push
s34_pushed() {
  grep -qE '^git( -C [^ ]+)? push origin [0-9a-f]{40}:refs/heads/fix/b' \
    <<<"$(cat "$S34_TMP/git.log")"
}

# s34_asked -> 0 when the dependent-PR query ran at all
s34_asked() {
  grep -qF 'gh pr list' <<<"$(cat "$S34_TMP/git.log")"
}

# s34_asked_pinned -> 0 when the query named the repository the push targets.
# `origin` is <owner>/<name>.git and a decoy `upstream` remote exists, so an
# unpinned gh would have answered about other-owner/other-repo.
s34_asked_pinned() {
  grep -qF 'gh pr list --repo fixture-owner/fixture-repo --base fix/b --state open --json number' \
    <<<"$(cat "$S34_TMP/git.log")"
}

if [ ! -s "$S34_TMP/push-fence.sh" ]; then
  echo "  FAIL  S34-FENCE.0 — could not extract 6c.4w.3 from review-pr.md"; FAIL=$((FAIL + 1))
else
  echo "  PASS  S34-FENCE.0 — extracted THE SINGLE LEASED PUSH fence"; PASS=$((PASS + 1))
  for s34_shell in bash zsh; do
    if ! command -v "$s34_shell" >/dev/null 2>&1; then
      echo "  SKIP  S34-FENCE.* ($s34_shell) — shell unavailable on this runner"
      continue
    fi

    # ROW 1 — THE NORMAL PATH IS UNCHANGED. No PR is based on this branch, so
    # the gate is silent and the leased push happens exactly as before.
    if s34_build rewritten pinned >/dev/null 2>&1; then
      S34_R="$(s34_run "$s34_shell" none)"
      S34_A="$(cat "$S34_TMP/audit.log")"
      if [ "${S34_R%%|*}" = 0 ] && s34_pushed \
         && grep -qF 'audit ci_fix_pushed' <<<"$S34_A" \
         && ! grep -qF 'data.outcome=halted' <<<"$S34_A"; then
        echo "  PASS  S34-FENCE.1 ($s34_shell) — with no dependent PR the leased push still happens"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.1 ($s34_shell) — the gate broke the normal push path"
        echo "        rc|stdout: $S34_R"
        echo "        audit:     $S34_A"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
      # ...and it asked the question of the repository the PUSH targets. An
      # unpinned `gh` would have resolved the decoy `upstream` remote and
      # answered, well-formed and empty, about a DIFFERENT repository — which is
      # fail-OPEN inside a fail-closed gate.
      if s34_asked_pinned; then
        echo "  PASS  S34-FENCE.1b ($s34_shell) — the dependent-PR query is pinned to the push target's repo"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.1b ($s34_shell) — the query let gh resolve a repository from the cwd"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  FAIL  S34-FENCE.1 ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
    fi

    # ROW 2 — THE DEFECT. An open PR is based on this PR's head branch and the
    # push REWRITES that branch. It would rewrite that PR's base out from under
    # it, collapsing its merge-base and growing its diff with commits its author
    # never wrote. Nothing may be pushed, and the halt must be typed.
    if s34_build rewritten pinned >/dev/null 2>&1; then
      S34_R="$(s34_run "$s34_shell" dependent)"
      S34_A="$(cat "$S34_TMP/audit.log")"
      if [ "${S34_R%%|*}" = 1 ] \
         && grep -qF 'data.subreason=ci_push_would_rewrite_stacked_base' <<<"$S34_A" \
         && grep -qF 'data.outcome=halted' <<<"$S34_A" \
         && ! s34_pushed; then
        echo "  PASS  S34-FENCE.2 ($s34_shell) — a stacked dependent PR halts the REWRITING push, and NOTHING is pushed"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.2 ($s34_shell) — the push rewrote a branch another open PR is based on"
        echo "        rc|stdout: $S34_R"
        echo "        audit:     $S34_A"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  FAIL  S34-FENCE.2 ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
    fi

    # ROW 2b — THE GATE MUST NOT BECOME A BLANKET REFUSAL. A fast-forward push
    # appends; the new commits are unreachable from a dependent PR's head, so
    # its merge-base and its diff are untouched. This is the shape the
    # `fix_code` edge ALWAYS produces (`_validate_ci_fix_code_outcome` pins its
    # terminal to one commit whose parent is head_before), so gating on the edge
    # rather than on the push shape would take Phase 3 CI autofix permanently
    # offline on exactly the stacked branches #438 exists to protect. The query
    # is not merely ignored here — it is never asked.
    if s34_build stacked pinned >/dev/null 2>&1; then
      S34_R="$(s34_run "$s34_shell" dependent)"
      S34_A="$(cat "$S34_TMP/audit.log")"
      if [ "${S34_R%%|*}" = 0 ] && s34_pushed \
         && grep -qF 'audit ci_fix_pushed' <<<"$S34_A" \
         && ! grep -qF 'data.outcome=halted' <<<"$S34_A" \
         && ! s34_asked; then
        echo "  PASS  S34-FENCE.2b ($s34_shell) — a fast-forward push with a dependent PR present is not gated"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.2b ($s34_shell) — an append-only push was refused as a stack rewrite"
        echo "        rc|stdout: $S34_R"
        echo "        audit:     $S34_A"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  FAIL  S34-FENCE.2b ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
    fi

    # ROW 3 — "I COULD NOT ASK" IS NOT "NOBODY IS STACKED". A gh outage gets its
    # OWN subreason so an audit consumer can tell the two apart, and it HALTS:
    # the read-only probe's carve-out does not extend to a force-push.
    for s34_broken in outage prose; do
      if s34_build rewritten pinned >/dev/null 2>&1; then
        S34_R="$(s34_run "$s34_shell" "$s34_broken")"
        S34_A="$(cat "$S34_TMP/audit.log")"
        if [ "${S34_R%%|*}" = 1 ] \
           && grep -qF 'data.subreason=ci_dependent_pr_probe_unreadable' <<<"$S34_A" \
           && ! grep -qF 'ci_push_would_rewrite_stacked_base' <<<"$S34_A" \
           && ! s34_pushed; then
          echo "  PASS  S34-FENCE.3.$s34_broken ($s34_shell) — an unanswerable dependent-PR probe halts under its own name"; PASS=$((PASS + 1))
        else
          echo "  FAIL  S34-FENCE.3.$s34_broken ($s34_shell) — a gh failure was read as 'no dependents'"
          echo "        rc|stdout: $S34_R"
          echo "        audit:     $S34_A"
          echo "        argv:      $(cat "$S34_TMP/git.log")"
          FAIL=$((FAIL + 1))
        fi
      else
        echo "  FAIL  S34-FENCE.3.$s34_broken ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
      fi
    done

    # ROW 4 — HALF TWO AT THE PUSH. The CONFLICT terminal reaches this fence a
    # SECOND time after `rebase --continue`, and the judge never re-runs, so the
    # controller proves base-tip ancestry itself. A head rebuilt off main keeps
    # the lease and moves HEAD — only the tip proof catches it.
    if s34_build detached pinned >/dev/null 2>&1; then
      S34_R="$(s34_run "$s34_shell" none)"
      S34_A="$(cat "$S34_TMP/audit.log")"
      if [ "${S34_R%%|*}" = 1 ] \
         && grep -qF 'data.subreason=ci_push_head_detached_from_base' <<<"$S34_A" \
         && ! s34_pushed; then
        echo "  PASS  S34-FENCE.4 ($s34_shell) — a head no longer descended from the pinned base tip is not pushed"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.4 ($s34_shell) — a stack-detached head reached the force-push"
        echo "        rc|stdout: $S34_R"
        echo "        audit:     $S34_A"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  FAIL  S34-FENCE.4 ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
    fi

    # ROW 5 — THE CARRIER DISCIPLINE (#418/#419). An authority that carries no
    # base tip is "cannot tell", and cannot degrade to a default that skips the
    # proof. It must halt, typed, with nothing pushed.
    if s34_build stacked lost >/dev/null 2>&1; then
      S34_R="$(s34_run "$s34_shell" none)"
      S34_A="$(cat "$S34_TMP/audit.log")"
      if [ "${S34_R%%|*}" = 1 ] \
         && grep -qE 'data\.subreason=ci_(authority_unreadable|push_head_detached_from_base)' <<<"$S34_A" \
         && ! s34_pushed; then
        echo "  PASS  S34-FENCE.5 ($s34_shell) — a missing base tip is a typed halt, never a skipped proof"; PASS=$((PASS + 1))
      else
        echo "  FAIL  S34-FENCE.5 ($s34_shell) — the base-tip proof defaulted itself away"
        echo "        rc|stdout: $S34_R"
        echo "        audit:     $S34_A"
        echo "        argv:      $(cat "$S34_TMP/git.log")"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  FAIL  S34-FENCE.5 ($s34_shell) — fixture build failed"; FAIL=$((FAIL + 1))
    fi
  done
fi
rm -rf "$S34_TMP"

echo
echo "== S35: the post-fix pass RE-ENTERS at iteration 2 without colliding (#655, AC #7) =="
# This suite owns the re-entry precedent: 6c.4w.3 pushes a CI fix, the re-entry
# fence advances both counters, and Phase 1 runs AGAIN. S27.2 already proves
# every counter-keyed fence reads the counters off disk. What it cannot prove is
# that the post-fix pass's five artifact families really SEPARATE under that
# second entry — a name keyed on a counter and a name keyed on a counter that is
# always 1 look identical to a structural scan.
#
# So this row RE-ENTERS. It drives the real producers twice, against two
# different fixer commits, and asserts that both iterations' evidence is on disk
# at once and that neither read the other's. The stale-counter failure RFC 0001
# records is not a crash: it is a clean green built on the previous iteration's
# bytes, with every equality still passing.
S35_TMP="$(mktemp -d)"
S35_REPORT="$S35_TMP/report.txt"
cat >"$S35_TMP/drive.sh" <<'S35DRIVER'
# S35 driver — run the post-fix pass's REAL artifact producers twice, once per
# REVIEW_ITERATION, against two DIFFERENT fixer commits, and report what landed.
# Emits `key=value` lines only; the parent scores.
set -u
say() { printf '%s=%s\n' "$1" "$2"; }

UBERDEV_REVIEW_PLUGIN_ROOT="$S35_PLUGIN"
export UBERDEV_REVIEW_PLUGIN_ROOT
. "$S35_PLUGIN/lib/review-fleet-args.sh" || { say load args-lib-failed; exit 0; }
review_fleet_load_fence_library || { say load carve-failed; exit 0; }
say load ok

REPO="$S35_TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name Fixture
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config core.eol lf
printf 'base\n' >"$REPO/file.txt"
git -C "$REPO" add -- file.txt
git -C "$REPO" commit -qm 'test: re-entry base'
S35_HEAD0="$(git -C "$REPO" rev-parse HEAD)"
printf 'base\niter1 fix\n' >"$REPO/file.txt"
git -C "$REPO" add -- file.txt
git -C "$REPO" commit -qm 'test: iteration 1 fixer commit'
S35_HEAD1="$(git -C "$REPO" rev-parse HEAD)"
printf 'base\niter1 fix\niter2 fix\n' >"$REPO/file.txt"
git -C "$REPO" add -- file.txt
git -C "$REPO" commit -qm 'test: iteration 2 fixer commit'
S35_HEAD2="$(git -C "$REPO" rev-parse HEAD)"

RESEARCH_DIR_ABS="$REPO/.uberdev/research/run"
mkdir -p "$RESEARCH_DIR_ABS"
WORKTREE_ROOT="$REPO"
CODE_FIXER_CONTRACT="$S35_PLUGIN/lib/code_fixer_contract.py"
export RESEARCH_DIR_ABS WORKTREE_ROOT CODE_FIXER_CONTRACT

# The controller's four artifact NAMES, lifted verbatim from review-pr.md rather
# than re-spelled here. A test that re-spelled them would agree with itself
# forever; these are the shipped bytes, evaluated.
REVIEW_FLEET_RUN_DIR="$RESEARCH_DIR_ABS"
: >"$S35_TMP/lifted.sh"
S35_LIFTED=0
for s35_name in POSTFIX_SIDECAR_PATH POSTFIX_DISPATCH_PATH POSTFIX_SUMMARISED_PATH POSTFIX_LAUNCH_SIDECAR; do
  s35_line="$(grep -m1 -E "^[[:space:]]*$s35_name=" "$S35_REVIEW_PR" 2>/dev/null)"
  [ -n "$s35_line" ] || continue
  S35_LIFTED=$((S35_LIFTED + 1))
  printf '%s\n' "$s35_line" >>"$S35_TMP/lifted.sh"
done
say lifted "$S35_LIFTED/4"
# Every copy of each assignment must be BYTE-IDENTICAL: the two passes carry
# four copies between them, and a copy that forgot the iteration key would rebind
# pass 2 onto pass 1's artifact with every equality downstream still passing.
for s35_name in POSTFIX_SIDECAR_PATH POSTFIX_DISPATCH_PATH POSTFIX_SUMMARISED_PATH POSTFIX_LAUNCH_SIDECAR; do
  say "copies_$s35_name" "$(grep -E "^[[:space:]]*$s35_name=" "$S35_REVIEW_PR" \
    | sed -e 's/^[[:space:]]*//' | sort -u | grep -c .)"
  say "count_$s35_name" "$(grep -cE "^[[:space:]]*$s35_name=" "$S35_REVIEW_PR")"
done

s35_pass() {  # ITER BEFORE AFTER PHASE
  local iter="$1" before="$2" after="$3" phase="$4" range counts
  REVIEW_ITERATION="$iter"
  export REVIEW_ITERATION
  POSTFIX_PHASE="$phase"
  VALIDATED_FIXER_HEAD_SHA="$before"
  review_track_validated_fixer_head APPLIED "$before" "$after" "$after" "$phase" \
    2>>"$S35_TMP/err" || { say "track_rc_$iter" "$?"; return 0; }
  say "track_rc_$iter" 0
  range="$(review_fleet_read_fixer_range \
    "$RESEARCH_DIR_ABS/fixer-range-${phase}-iter${iter}.txt" 2>>"$S35_TMP/err")" \
    || { say "range_rc_$iter" nonzero; return 0; }
  say "range_$iter" "$range"
  review_build_postfix_scope "$phase" "$range" 2>>"$S35_TMP/err" \
    || { say "scope_rc_$iter" "$?"; return 0; }
  say "scope_rc_$iter" 0
  say "scope_path_$iter" "$REVIEW_POSTFIX_DIFF_PATH"
  # The controller-owned names, from the lifted assignments.
  . "$S35_TMP/lifted.sh"
  say "sidecar_$iter" "$POSTFIX_SIDECAR_PATH"
  say "dispatch_$iter" "$POSTFIX_DISPATCH_PATH"
  say "summarised_$iter" "$POSTFIX_SUMMARISED_PATH"
  say "launch_$iter" "$POSTFIX_LAUNCH_SIDECAR"
  review_fleet_write_postfix_dispatch "$POSTFIX_DISPATCH_PATH" 1 2>>"$S35_TMP/err"
  printf '```yaml\nverdict: REVISIONS_REQUIRED\nfindings:\n  - severity: blocker\n    location: file.txt:%s\n    summary: iteration %s finding\n    detail: the pass that read iteration %s commits\nconfidence: high\n```\n' \
    "$iter" "$iter" "$iter" >"$S35_TMP/result-$iter.md"
  counts="$(review_write_postfix_aggregate "$phase" "$iter" "$S35_TMP/result-$iter.md" 2>>"$S35_TMP/err")" \
    || { say "aggregate_rc_$iter" "$?"; return 0; }
  say "aggregate_rc_$iter" 0
  say "aggregate_counts_$iter" "$counts"
  printf '{"status":"ran","iteration":%s}\n' "$iter" >"$POSTFIX_SIDECAR_PATH"
}

: >"$S35_TMP/err"
s35_pass 1 "$S35_HEAD0" "$S35_HEAD1" phase1
s35_pass 2 "$S35_HEAD1" "$S35_HEAD2" phase1

# What is on disk at the end. All FIVE artifact families, both iterations, and
# nothing overwritten: a re-entry that rebound pass 2 onto pass 1's names would
# leave five files instead of ten and freeze iteration 1's evidence.
S35_PRESENT=0
S35_MISSING=""
for s35_file in \
  fixer-range-phase1-iter1.txt fixer-range-phase1-iter2.txt \
  postfix-diff-phase1-iter1.md postfix-diff-phase1-iter2.md \
  postfix-dispatch-phase1-iter1.txt postfix-dispatch-phase1-iter2.txt \
  postfix-phase1-iter1.md postfix-phase1-iter2.md \
  postfix-phase1-iter1.json postfix-phase1-iter2.json; do
  if [ -f "$RESEARCH_DIR_ABS/$s35_file" ]; then
    S35_PRESENT=$((S35_PRESENT + 1))
  else
    S35_MISSING="$S35_MISSING $s35_file"
  fi
done
say present "$S35_PRESENT/10"
say missing "${S35_MISSING# }"
# Iteration 1's evidence must still be iteration 1's. Byte equality against what
# the first pass actually produced, not against a re-spelled expectation.
say range1 "$(cat "$RESEARCH_DIR_ABS/fixer-range-phase1-iter1.txt" 2>/dev/null)"
say range2 "$(cat "$RESEARCH_DIR_ABS/fixer-range-phase1-iter2.txt" 2>/dev/null)"
say want_range1 "$S35_HEAD0..$S35_HEAD1"
say want_range2 "$S35_HEAD1..$S35_HEAD2"
say agg1_finding "$(grep -c 'iteration 1 finding' "$RESEARCH_DIR_ABS/postfix-phase1-iter1.md" 2>/dev/null)"
say agg2_finding "$(grep -c 'iteration 2 finding' "$RESEARCH_DIR_ABS/postfix-phase1-iter2.md" 2>/dev/null)"
say agg1_has_iter2 "$(grep -c 'iteration 2 finding' "$RESEARCH_DIR_ABS/postfix-phase1-iter1.md" 2>/dev/null)"
say diff1_carries "$(grep -c 'iter1 fix' "$RESEARCH_DIR_ABS/postfix-diff-phase1-iter1.md" 2>/dev/null)"
say diff2_carries_iter2 "$(grep -c 'iter2 fix' "$RESEARCH_DIR_ABS/postfix-diff-phase1-iter2.md" 2>/dev/null)"
say diff1_carries_iter2 "$(grep -c 'iter2 fix' "$RESEARCH_DIR_ABS/postfix-diff-phase1-iter1.md" 2>/dev/null)"
say stderr "$(tr '\n' ' ' <"$S35_TMP/err" 2>/dev/null)"
exit 0
S35DRIVER
S35_TMP="$S35_TMP" S35_PLUGIN="$REPO_ROOT/plugins/uberdev" S35_REVIEW_PR="$REVIEW_PR" \
  bash "$S35_TMP/drive.sh" >"$S35_REPORT" 2>"$S35_TMP/drive.err"
S35_RC=$?
s35() { sed -n "s/^$1=//p" "$S35_REPORT"; }
s35_row() {  # DESC then KEY=WANT pairs
  local desc="$1" bad="" pair key want got
  shift
  for pair in "$@"; do
    key="${pair%%=*}"
    want="${pair#*=}"
    got="$(s35 "$key")"
    [ "$got" = "$want" ] || bad="$bad $key='$got'(want '$want')"
  done
  if [ -z "$bad" ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "       $bad"; FAIL=$((FAIL + 1))
  fi
}

if [ "$S35_RC" = 0 ]; then
  echo "  PASS  S35.0 — the re-entry driver ran to completion"; PASS=$((PASS + 1))
else
  echo "  FAIL  S35.0 — the re-entry driver exited $S35_RC; every row below is unreliable"
  echo "        stderr: $(tr '\n' ' ' <"$S35_TMP/drive.err" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
s35_row "S35.1 — the four controller-owned artifact names lift out of review-pr.md" \
  load=ok lifted=4/4
# ONE spelling across all four copies. The two passes carry four copies of each
# assignment between them (5p.1, 5p.2, 6p.1, 6p.2), and a single copy that
# dropped the iteration key would rebind that pass onto its predecessor's
# artifact while every downstream equality still held.
s35_row "S35.2 — each artifact name has exactly ONE spelling across all four fence copies" \
  copies_POSTFIX_SIDECAR_PATH=1 count_POSTFIX_SIDECAR_PATH=4 \
  copies_POSTFIX_DISPATCH_PATH=1 count_POSTFIX_DISPATCH_PATH=4 \
  copies_POSTFIX_SUMMARISED_PATH=1 count_POSTFIX_SUMMARISED_PATH=4 \
  copies_POSTFIX_LAUNCH_SIDECAR=1 count_POSTFIX_LAUNCH_SIDECAR=4
s35_row "S35.3 — both passes complete: the tracker, the scope builder and the aggregate writer all return 0" \
  track_rc_1=0 scope_rc_1=0 aggregate_rc_1=0 \
  track_rc_2=0 scope_rc_2=0 aggregate_rc_2=0 stderr=
# FIVE families x TWO iterations. Ten files, not five: the whole point.
s35_row "S35.4 — all five artifact families exist for BOTH iterations at once" \
  present=10/10 missing=
S35_SUFFIX_BAD=""
for s35_key in sidecar dispatch summarised launch scope_path; do
  for s35_iter in 1 2; do
    case "$(s35 "${s35_key}_${s35_iter}")" in
      *"-iter${s35_iter}."*) : ;;
      *) S35_SUFFIX_BAD="$S35_SUFFIX_BAD ${s35_key}_${s35_iter}='$(s35 "${s35_key}_${s35_iter}")'" ;;
    esac
  done
done
if [ -z "$S35_SUFFIX_BAD" ]; then
  echo "  PASS  S35.5 — every published name carries its own iteration, controller-owned and fence-owned alike"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S35.5 — a published name is not iteration-keyed:$S35_SUFFIX_BAD"
  FAIL=$((FAIL + 1))
fi
# And the evidence did not travel. Iteration 1's range is still the first
# fixer's commits, its aggregate still carries only its own finding, and its
# diff artifact never saw the second fixer's line.
S35_R1="$(s35 range1)"
S35_R2="$(s35 range2)"
if [ -n "$S35_R1" ] && [ "$S35_R1" = "$(s35 want_range1)" ] \
   && [ -n "$S35_R2" ] && [ "$S35_R2" = "$(s35 want_range2)" ] \
   && [ "$S35_R1" != "$S35_R2" ]; then
  echo "  PASS  S35.6 — each iteration's commit-range carrier names that iteration's own fixer commit"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S35.6 — a commit-range carrier was rebound: iter1='$S35_R1' iter2='$S35_R2'"
  FAIL=$((FAIL + 1))
fi
s35_row "S35.7 — iteration 1's aggregate and diff still hold iteration 1's evidence, not iteration 2's" \
  agg1_finding=1 agg1_has_iter2=0 diff1_carries=1 diff1_carries_iter2=0
s35_row "S35.8 — and iteration 2's hold its own" agg2_finding=1 diff2_carries_iter2=1
rm -rf "$S35_TMP"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
