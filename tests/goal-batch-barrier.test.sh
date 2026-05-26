#!/usr/bin/env bash
# tests/goal-batch-barrier.test.sh — behavioral cross-shell tests for the
# /goal parallel cap + merge barrier (issue #211).
#
# Covers: batch registry CRUD, all_terminal predicate truth table, unblock_wait
# predicate dual condition, barrier_start_ts persist/rehydrate under
# fresh-shell-with-cleared-env, manifest-collision sequential merge integration.
#
# Run under bash >= 4 (the lib being exercised hard-requires bash 4 via the
# goal-pipeline preflight). zsh-incompatible; not invoked from solve-pipeline-zsh.test.sh.

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source the shared structural-assertion helpers (assert_count / assert_subagent_type / assert_in_section).
# assert_grep / assert_no_grep are defined inline below — they are local helpers in every test file
# that uses them (see merge-discovery-resilience.test.sh:75 for the canonical shape).
source "$REPO_ROOT/tests/_lib_assert_structural.sh"
GOAL_LIB="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

# CLAUDE_PLUGIN_ROOT is referenced by the libs; export it for the sourced helpers.
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT

# Hard-fail early if the libs aren't present.
for f in "$GOAL_LIB" "$DISPATCH_LIB"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export UBERDEV_TMPDIR="$TEST_TMPDIR"
export GOAL_ID="test-batch-barrier"

PASS=0
FAIL=0

# --- Inline helpers ---------------------------------------------------------
# Mirror the shape used by tests/merge-discovery-resilience.test.sh so the
# RED→GREEN signal is uniform across the suite.

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# B1 — batch registry CRUD (register, set-state, list-ordered, all-terminal).
# ---------------------------------------------------------------------------
echo "== B1: batch registry CRUD =="
# Source the libs under bash explicitly.
(
  . "$DISPATCH_LIB"
  . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID"  || { echo "B1.state-init FAIL"; exit 1; }
  # Register three PRs.
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 41   || { echo "B1.register-100 FAIL"; exit 1; }
  uberdev_goal_register_batch_pr "$GOAL_ID" 101 42   || { echo "B1.register-101 FAIL"; exit 1; }
  uberdev_goal_register_batch_pr "$GOAL_ID" 102 43   || { echo "B1.register-102 FAIL"; exit 1; }
  # All PENDING -> all_terminal must return 1.
  if uberdev_goal_batch_all_terminal "$GOAL_ID"; then echo "B1.all-pending-must-be-non-terminal FAIL"; exit 1; fi
  # Promote two of the three to GREEN.
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 GREEN || { echo "B1.set-100 FAIL"; exit 1; }
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 101 GREEN || { echo "B1.set-101 FAIL"; exit 1; }
  # Still one PENDING -> all_terminal returns 1.
  if uberdev_goal_batch_all_terminal "$GOAL_ID"; then echo "B1.partial-pending-must-fail FAIL"; exit 1; fi
  # Promote last -> all_terminal returns 0.
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 102 MERGE_FAILED || { echo "B1.set-102 FAIL"; exit 1; }
  if ! uberdev_goal_batch_all_terminal "$GOAL_ID"; then echo "B1.all-terminal-must-pass FAIL"; exit 1; fi
  # Green-PRs ordered returns 100 101 (102 is MERGE_FAILED, excluded).
  out="$(_uberdev_goal_batch_green_prs_ordered "$GOAL_ID" | tr '\n' ' ' | sed 's/  *$//')"
  [ "$out" = "100 101" ] || { echo "B1.green-prs-ordered got '$out' want '100 101' FAIL"; exit 1; }
  echo "B1 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B1 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B2 — unblock_wait predicate exists in lib.
# ---------------------------------------------------------------------------
echo "== B2: unblock_wait predicate exists in lib =="
assert_grep "$GOAL_LIB" "^uberdev_goal_batch_unblock_wait_clear\(\)" "B2.predicate-defined"
# Verify lib references both gating conditions (issue CLOSED + trust label review-pr:green).
assert_grep "$GOAL_LIB" 'CLOSED'                                    "B2.closed-issue-check"
assert_grep "$GOAL_LIB" 'review-pr:green'                           "B2.green-trust-label"

# ---------------------------------------------------------------------------
# B3 — barrier_start_ts persist/rehydrate under fresh-shell-with-cleared-env.
# ---------------------------------------------------------------------------
echo "== B3: barrier_start_ts persist/rehydrate (cleared-env) =="
# Write run-state in one shell, read in a fresh shell with env STRIPPED.
# This is the cross-shell trap from user memory project_uberdev_goal_runstate_crossshell_traps.md:
# env-passing tests pass while the underlying re-export is broken.
(
  . "$DISPATCH_LIB"
  . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID"
  uberdev_goal_register_batch_pr "$GOAL_ID" 200 60   # seeds barrier_start_ts
  cycle=1
  watch_start=$(_uberdev_goal_now_secs)
  MAX_CYCLES=5
  MAX_PARALLEL=3
  BARRIER_TIMEOUT_S=14400
  queue=()
  active_issues=()
  uberdev_goal_write_run_state || exit 1
) || { echo "B3.write FAIL"; FAIL=$((FAIL + 1)); }

# Fresh shell, env cleared except UBERDEV_TMPDIR (which the bootstrap pointer needs).
bash --noprofile --norc -c '
  set -u
  export UBERDEV_TMPDIR="'"$TEST_TMPDIR"'"
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state || exit 1
  [ -n "${barrier_start_ts:-}" ] || { echo "B3.barrier_start_ts-empty-after-rehydrate FAIL"; exit 1; }
  [ -n "${MAX_PARALLEL:-}" ]      || { echo "B3.MAX_PARALLEL-empty-after-rehydrate FAIL"; exit 1; }
  [ -n "${BARRIER_TIMEOUT_S:-}" ] || { echo "B3.BARRIER_TIMEOUT_S-empty-after-rehydrate FAIL"; exit 1; }
  echo "B3 PASS"
' || { FAIL=$((FAIL + 1)); echo "  FAIL  B3 fresh-shell rehydrate exited non-zero"; }

# ---------------------------------------------------------------------------
# B4 — manifest-collision rebase helper exists.
# ---------------------------------------------------------------------------
echo "== B4: manifest-collision rebase helper exists =="
assert_grep "$GOAL_LIB"   '^_uberdev_goal_rebase_collision_chain\(\)' "B4.helper-defined"
# `gh pr diff` (NOT `git diff --name-only origin/main..pr-N` — local `pr-N`
# refs don't exist in the clone, so the original `git diff` form was a silent
# no-op).
assert_grep "$GOAL_LIB"   'gh pr diff'                               "B4.path-set-intersection"
assert_grep "$GOAL_LIB"   'git fetch origin main'                    "B4.fresh-main-fetch"

# ---------------------------------------------------------------------------
# B5 — collision chain sequences green PRs in ascending order.
# ---------------------------------------------------------------------------
echo "== B5: collision chain sequences green PRs in ascending order =="
(
  . "$DISPATCH_LIB"
  . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID-b5"
  uberdev_goal_register_batch_pr "$GOAL_ID-b5" 301 70
  uberdev_goal_register_batch_pr "$GOAL_ID-b5" 300 71
  uberdev_goal_register_batch_pr "$GOAL_ID-b5" 302 72
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID-b5" 301 GREEN
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID-b5" 300 GREEN
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID-b5" 302 GREEN
  out="$(_uberdev_goal_batch_green_prs_ordered "$GOAL_ID-b5" | tr '\n' ' ' | sed 's/  *$//')"
  [ "$out" = "300 301 302" ] || { echo "B5.ascending-order FAIL got '$out'"; exit 1; }
  echo "B5 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B5 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B6 — lib uses atomic writes for batch-prs.tsv (no >> appends).
# ---------------------------------------------------------------------------
echo "== B6: lib uses atomic writes for batch-prs.tsv (no >> appends) =="
# The atomic-write rule from spec error-handling — concurrent printf >> would
# interleave bytes. Once the helpers exist, the lib MUST NOT contain `>>`
# redirects targeting *batch-prs.tsv*.
# Negative shape gate: no `>> .*batch-prs.tsv` pattern anywhere in the lib.
assert_no_grep "$GOAL_LIB" '>>[[:space:]]*[^[:space:]]*batch-prs\.tsv'   "B6.no-append-redirect-to-tsv"
# Positive: the standard atomic-write triad is used (mktemp + mv -f).
assert_grep "$GOAL_LIB" '_uberdev_dispatch_prepare_tmp_target'           "B6.uses-prepare-tmp-target-helper"

# ---------------------------------------------------------------------------
# B7 — barrier_start_ts seed survives write_run_state pre-population.
# ---------------------------------------------------------------------------
# Regression guard for the seed predicate: the previous `! grep -q
# '^barrier_start_ts='` arm was FALSE whenever Phase 0 had already written
# the run-state sidecar (the writer emits `barrier_start_ts=0` as a
# placeholder), so the seed never fired and the wall-clock barrier breaker
# (AC6 / D-211e) became dead code. Exercise the actual Phase 0 → register
# ordering and assert the in-file value is non-zero and within seconds of
# wall clock.
echo "== B7: barrier_start_ts seed survives write_run_state pre-population =="
(
  . "$DISPATCH_LIB"
  . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID-b7"   || { echo "B7.state-init FAIL"; exit 1; }
  # Phase 0 step 7 ordering: write_run_state runs BEFORE any register_batch_pr.
  GOAL_ID="$GOAL_ID-b7"
  cycle=0
  watch_start=$(_uberdev_goal_now_secs)
  MAX_CYCLES=5
  MAX_PARALLEL=3
  BARRIER_TIMEOUT_S=14400
  queue=()
  active_issues=()
  # barrier_start_ts intentionally UNSET — the writer's default arm
  # (`${barrier_start_ts:-0}`) will pre-populate `barrier_start_ts=0`.
  uberdev_goal_write_run_state || { echo "B7.write_run_state-pre-register FAIL"; exit 1; }
  sc="${UBERDEV_TMPDIR}/goal-${GOAL_ID}-runstate"
  pre_seed_line="$(grep '^barrier_start_ts=' "$sc" || true)"
  [ "$pre_seed_line" = "barrier_start_ts=0" ] || {
    echo "B7.precondition-placeholder-zero FAIL got '$pre_seed_line'"; exit 1;
  }
  # First registration — must promote the placeholder to a real epoch.
  pre_ts=$(_uberdev_goal_now_secs)
  uberdev_goal_register_batch_pr "$GOAL_ID" 700 90 || { echo "B7.register FAIL"; exit 1; }
  post_ts=$(_uberdev_goal_now_secs)
  seeded_line="$(grep '^barrier_start_ts=' "$sc" || true)"
  seeded_value="${seeded_line#barrier_start_ts=}"
  case "$seeded_value" in
    ''|*[!0-9]*) echo "B7.seeded-non-integer FAIL got '$seeded_value'"; exit 1 ;;
  esac
  [ "$seeded_value" -gt 0 ] || { echo "B7.seeded-must-be-positive FAIL got '$seeded_value'"; exit 1; }
  # Must be at most one barrier_start_ts= line (the awk rewrite drops the
  # placeholder rather than duplicating it).
  occurrences="$(grep -c '^barrier_start_ts=' "$sc" || true)"
  [ "$occurrences" = "1" ] || { echo "B7.exactly-one-barrier-line FAIL got $occurrences" ; exit 1; }
  # Within ±5s of wall clock (allow for slow CI hosts).
  if [ "$seeded_value" -lt "$pre_ts" ] || [ "$seeded_value" -gt "$((post_ts + 5))" ]; then
    echo "B7.seeded-not-near-now FAIL value=$seeded_value pre=$pre_ts post=$post_ts"; exit 1
  fi
  echo "B7 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B7 block exited non-zero"; }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
