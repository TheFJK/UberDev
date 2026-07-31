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
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }
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
# Verify lib references the gating condition (issue CLOSED) + the CORRECT trust
# label. #289.1: the gate must read `uberdev-approved` (the label /review-pr
# actually writes), NOT the zero-producer `review-pr:green`. Assert the active
# jq label-select uses uberdev-approved; assert no LIVE gate reads review-pr:green.
assert_grep "$GOAL_LIB" 'CLOSED'                                    "B2.closed-issue-check"
assert_grep "$GOAL_LIB" 'select\(\. == "uberdev-approved"\)'        "B2.approved-trust-label"
# Negative: no executable `gh pr view ... select(. == "review-pr:green")` gate
# remains (the phantom-label bug). A comment mentioning the old name is fine;
# a live jq select on it is the regression.
assert_no_grep "$GOAL_LIB" 'select\(\. == "review-pr:green"\)'      "B2.no-phantom-green-label-gate"

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
# B8 — cap-rollover behavioral: with MAX_PARALLEL=3 and a 5-issue queue,
# exactly 3 entries land in the DISPATCH_LOG and 2 stay in the rollover
# queue. Mirrors SKILL.md Phase 1 dispatch-loop cap-slice inline (SKILL.md
# bash is LLM-directive text, not sourceable; this matches the BT5-BT11
# idiom in tests/goal.test.sh). Issue #214 AC1.
# ---------------------------------------------------------------------------
echo "== B8: cap-rollover behavioral — MAX_PARALLEL=3 vs 5-issue queue =="
(
  set -u
  SCRATCH_B8="$(mktemp -d -t uberdev-goal-b8.XXXXXX)"
  trap 'rm -rf "$SCRATCH_B8"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH_B8"
  export UBERDEV_GOAL_ID="b8-cap-rollover"
  DISPATCH_LOG="$SCRATCH_B8/dispatch.log"
  : > "$DISPATCH_LOG"

  . "$DISPATCH_LIB"
  . "$GOAL_LIB"

  # Stub uberdev_dispatch_one — appends DISPATCHED:<issue> to the log.
  uberdev_dispatch_one() { printf 'DISPATCHED:%s\n' "$1" >> "$DISPATCH_LOG"; }

  # Phase 1 cap-slice loop (behavioral equivalent of SKILL.md Phase 1 dispatch
  # loop — same cap semantics, rephrased to an if/else for in-test readability;
  # SKILL.md uses `(( dispatched_this_cycle >= MAX_PARALLEL ))` + `continue`).
  MAX_PARALLEL=3
  queue=(101 102 103 104 105)
  dispatched_this_cycle=0
  remaining_queue=()
  for n in "${queue[@]}"; do
    if [ "$dispatched_this_cycle" -lt "$MAX_PARALLEL" ]; then
      uberdev_dispatch_one "$n"
      dispatched_this_cycle=$((dispatched_this_cycle + 1))
    else
      remaining_queue+=("$n")
    fi
  done

  # Assertions.
  [ "$dispatched_this_cycle" = "3" ] || { echo "B8.dispatched-count FAIL got $dispatched_this_cycle"; exit 1; }
  [ "${#remaining_queue[@]}" = "2" ] || { echo "B8.remaining-count FAIL got ${#remaining_queue[@]}"; exit 1; }
  log_lines="$(wc -l < "$DISPATCH_LOG" | tr -d ' ')"
  [ "$log_lines" = "3" ] || { echo "B8.log-lines FAIL got $log_lines"; exit 1; }
  grep -qx 'DISPATCHED:101' "$DISPATCH_LOG" || { echo "B8.first-dispatched FAIL"; exit 1; }
  grep -qx 'DISPATCHED:103' "$DISPATCH_LOG" || { echo "B8.third-dispatched FAIL"; exit 1; }
  grep -qx 'DISPATCHED:104' "$DISPATCH_LOG" && { echo "B8.fourth-not-dispatched FAIL — 104 leaked through cap"; exit 1; }
  [ "${remaining_queue[0]}" = "104" ] || { echo "B8.rollover-first FAIL got '${remaining_queue[0]}'"; exit 1; }
  [ "${remaining_queue[1]}" = "105" ] || { echo "B8.rollover-second FAIL got '${remaining_queue[1]}'"; exit 1; }
  echo "B8 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B8 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B9 — wall-clock barrier-breaker behavioral. uberdev_goal_barrier_breaker_check
# fires (rc=0, emits audit) iff barrier_start_ts > 0 AND elapsed >= timeout.
# Mocks _uberdev_goal_now_secs by shell-function override (scopes to the
# subshell; no export -f needed). Asserts positive (fire), negative
# (under-threshold), and zero-start (no fire) cases. Issue #214 AC2 / AC3.
# ---------------------------------------------------------------------------
echo "== B9: wall-clock barrier-breaker behavioral — positive/negative/zero-start =="
(
  set -u
  SCRATCH_B9="$(mktemp -d -t uberdev-goal-b9.XXXXXX)"
  trap 'rm -rf "$SCRATCH_B9"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH_B9"
  export UBERDEV_GOAL_ID="b9-barrier-breaker"
  GOAL_ID="$UBERDEV_GOAL_ID"

  . "$DISPATCH_LIB"
  . "$GOAL_LIB"

  # Seed sidecar manually (deterministic — avoids real wall-clock noise).
  sc="$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
  cat > "$sc" <<EOF
GOAL_ID=$GOAL_ID
cycle=1
watch_start=1000
overflow_count=0
overflow_detected=0
MAX_CYCLES=10
UBERDEV_RESOLVED_BACKEND=claude-bg
MAX_PARALLEL=3
BARRIER_TIMEOUT_S=60
barrier_start_ts=1000
EOF

  # uberdev_goal_audit writes JSONL to $tmpdir/goal-<id>.jsonl (see
  # goal-state.sh:360). NOT a separate -audit.jsonl file.
  audit_log="$UBERDEV_TMPDIR/goal-$GOAL_ID.jsonl"

  # ---- POSITIVE case: elapsed = 65 ≥ 60 → fire (rc=0, audit emitted) ----
  # Mock now = barrier_start_ts(1000) + 65 → elapsed=65, threshold=60 → FIRE
  _uberdev_goal_now_secs() { echo 1065; }
  uberdev_goal_barrier_breaker_check "$GOAL_ID" 60
  rc_fire=$?
  [ "$rc_fire" = "0" ] || { echo "B9.fire-rc FAIL got rc=$rc_fire (expected 0)"; exit 1; }
  [ -r "$audit_log" ] || { echo "B9.fire-audit-log-missing FAIL"; exit 1; }
  grep -q '"reason":"stuck_loop"'           "$audit_log" || { echo "B9.fire-reason FAIL"; exit 1; }
  grep -q '"phase":"merge_barrier"'         "$audit_log" || { echo "B9.fire-phase FAIL"; exit 1; }
  grep -q '"elapsed_s":65'                  "$audit_log" || { echo "B9.fire-elapsed FAIL"; exit 1; }
  grep -q '"event":"goal_circuit_breaker"'  "$audit_log" || { echo "B9.fire-event FAIL"; exit 1; }
  pre_neg_audit_lines="$(wc -l < "$audit_log" | tr -d ' ')"

  # ---- NEGATIVE case: elapsed = 30 < 60 → no fire (rc=1, no new audit) ----
  # Mock now = barrier_start_ts(1000) + 30 → elapsed=30, threshold=60 → NO FIRE
  _uberdev_goal_now_secs() { echo 1030; }
  uberdev_goal_barrier_breaker_check "$GOAL_ID" 60
  rc_nofire=$?
  [ "$rc_nofire" = "1" ] || { echo "B9.nofire-rc FAIL got rc=$rc_nofire (expected 1)"; exit 1; }
  post_neg_audit_lines="$(wc -l < "$audit_log" | tr -d ' ')"
  [ "$pre_neg_audit_lines" = "$post_neg_audit_lines" ] || {
    echo "B9.nofire-no-new-audit FAIL pre=$pre_neg_audit_lines post=$post_neg_audit_lines"; exit 1;
  }

  # ---- ZERO-start case: barrier_start_ts=0 → no fire (rc=1) ----
  # Use awk (portable across BSD/GNU sed — macOS local + linux + windows git-bash)
  awk '/^barrier_start_ts=1000$/{print "barrier_start_ts=0"; next}1' "$sc" > "$sc.tmp" && mv "$sc.tmp" "$sc"
  uberdev_goal_barrier_breaker_check "$GOAL_ID" 60
  rc_zero=$?
  [ "$rc_zero" = "1" ] || { echo "B9.zerostart-rc FAIL got rc=$rc_zero (expected 1)"; exit 1; }

  echo "B9 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B9 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B10 — #289.3 (MAJOR) — batch_unblock_wait_clear requires ALL Blocks: issues
# CLOSED (the prior loop break-ed after the FIRST match). A held PR with two
# Blocks lines, only one closed, MUST keep gating the barrier (rc 1).
# ---------------------------------------------------------------------------
echo "== B10: unblock-wait requires ALL Blocks closed (#289.3) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b10"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD
  # PR body carries TWO Blocks lines; issue 201 CLOSED, issue 202 OPEN.
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201\nBlocks: #202';; *labels*) printf '0';; esac ;;
      "issue view") case "$3" in 201) printf 'CLOSED';; 202) printf 'OPEN';; esac ;;
    esac
  }
  if uberdev_goal_batch_unblock_wait_clear "$GOAL_ID"; then
    echo "B10.one-of-two-open-must-gate FAIL (returned rc0/clear)"; exit 1
  fi
  # Now BOTH closed → pseudo-terminal, no longer gates (rc0).
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201\nBlocks: #202';; *labels*) printf '0';; esac ;;
      "issue view") printf 'CLOSED' ;;
    esac
  }
  if ! uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" 2>/dev/null; then
    echo "B10.all-closed-must-clear FAIL (returned rc1/wait)"; exit 1
  fi
  echo "B10 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B10 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B11 — #289.1 (BLOCKER) — the rc-1-FOREVER phantom-label bug. A held PR whose
# (single) Blocks issue is CLOSED but which stays held (no uberdev-approved
# label) MUST be pseudo-terminal (rc 0 — does NOT gate co-batched GREEN PRs).
# The OLD code gated on the zero-producer `review-pr:green` and returned rc 1
# forever, blocking every co-batched GREEN PR until the 4h stuck_loop.
# ---------------------------------------------------------------------------
echo "== B11: held+blocker-closed+no-green-label is pseudo-terminal, not rc1-forever (#289.1) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b11"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD
  # Blocker CLOSED, but NO uberdev-approved label (length 0). Stays held.
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201';; *labels*) printf '0';; esac ;;
      "issue view") printf 'CLOSED' ;;
    esac
  }
  if ! uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" 2>/dev/null; then
    echo "B11.pseudo-terminal-must-clear FAIL (rc1 — the phantom-label deadlock)"; exit 1
  fi
  # While the blocker is still OPEN, it MUST gate (legitimate hold-and-unblock).
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201';; *labels*) printf '0';; esac ;;
      "issue view") printf 'OPEN' ;;
    esac
  }
  if uberdev_goal_batch_unblock_wait_clear "$GOAL_ID"; then
    echo "B11.blocker-open-must-gate FAIL (rc0 while blocker open)"; exit 1
  fi
  echo "B11 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B11 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B12 — #292.1 (MAJOR) — mutual Blocks cycle detection. PR100 blocks on issue
# 201 (closed by held PR101); PR101 blocks on issue 200 (closed by held PR100).
# detect_blocks_cycle MUST return rc 0 + both PRs. An acyclic graph returns rc 1.
# ---------------------------------------------------------------------------
echo "== B12: mutual-Blocks cycle detection (#292.1) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b12"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 101 201 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 101 HELD
  # PR100 body Blocks #201; PR101 body Blocks #200. find_pr: issue 200->PR100, 201->PR101.
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) case "$3" in 100) printf 'Blocks: #201';; 101) printf 'Blocks: #200';; esac ;; esac ;;
      "pr list")
        local jqf='.'; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jqf="$2"; shift; done
        printf '%s' '[{"number":100,"closingIssuesReferences":[{"number":200}],"headRefName":"feat/200-a"},{"number":101,"closingIssuesReferences":[{"number":201}],"headRefName":"feat/201-b"}]' | jq -r "$jqf" ;;
    esac
  }
  cyc="$(uberdev_goal_detect_blocks_cycle "$GOAL_ID")"; rc=$?
  [ "$rc" = "0" ] || { echo "B12.cycle-must-fire FAIL (rc=$rc)"; exit 1; }
  case "$cyc" in *100*) : ;; *) echo "B12.cycle-missing-100 FAIL got [$cyc]"; exit 1 ;; esac
  case "$cyc" in *101*) : ;; *) echo "B12.cycle-missing-101 FAIL got [$cyc]"; exit 1 ;; esac
  # Acyclic: PR100 held, blocks issue 999 which NO held PR closes.
  uberdev_goal_state_init "$GOAL_ID-acyc" >/dev/null
  export UBERDEV_GOAL_ID="$GOAL_ID-acyc"; GOAL_ID="$GOAL_ID-acyc"
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #999';; esac ;;
      "pr list") local jqf='.'; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jqf="$2"; shift; done; printf '[]' | jq -r "$jqf" ;;
    esac
  }
  if uberdev_goal_detect_blocks_cycle "$GOAL_ID" >/dev/null; then
    echo "B12.acyclic-must-not-fire FAIL"; exit 1
  fi
  echo "B12 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B12 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B13 — #292.2 (MAJOR) — per-PR merge-attempt counter reset. After 3 cumulative
# attempts should_automerge refuses; reset_merge_attempts re-allows it (held→
# green recovery). The counter must read 0 after the reset (last-write-wins).
# ---------------------------------------------------------------------------
echo "== B13: merge-attempt counter reset on held→green recovery (#292.2) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b13"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  # Simulate 3 accumulated merge attempts → at the cap.
  printf '%s\t%s\n' 100 3 > "$SCRATCH/goal-$GOAL_ID-merge-attempts.tsv"
  if uberdev_goal_should_automerge "$GOAL_ID" 100; then
    echo "B13.at-cap-must-refuse FAIL (should_automerge allowed at cap)"; exit 1
  fi
  uberdev_goal_reset_merge_attempts "$GOAL_ID" 100 || { echo "B13.reset-rc FAIL"; exit 1; }
  cnt="$(_uberdev_goal_count_merge_attempts "$GOAL_ID" 100)"
  [ "$cnt" = "0" ] || { echo "B13.count-after-reset FAIL got '$cnt' want 0"; exit 1; }
  if ! uberdev_goal_should_automerge "$GOAL_ID" 100; then
    echo "B13.after-reset-must-allow FAIL (still refusing post-reset)"; exit 1
  fi
  echo "B13 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B13 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B14 — #290.3 (MAJOR) — consecutive-gh-failure breaker. record bumps, reset
# clears, breaker fires only at/above threshold and emits gh_api_failed.
# ---------------------------------------------------------------------------
echo "== B14: consecutive gh-failure breaker (#290.3) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b14"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  # No failures yet → breaker does not fire.
  if uberdev_goal_gh_failure_breaker_check "$GOAL_ID" 3; then echo "B14.fresh-must-not-fire FAIL"; exit 1; fi
  _uberdev_goal_record_gh_failure; _uberdev_goal_record_gh_failure
  if uberdev_goal_gh_failure_breaker_check "$GOAL_ID" 3; then echo "B14.under-threshold-must-not-fire FAIL"; exit 1; fi
  _uberdev_goal_record_gh_failure   # now 3
  if ! uberdev_goal_gh_failure_breaker_check "$GOAL_ID" 3 >/dev/null; then echo "B14.at-threshold-must-fire FAIL"; exit 1; fi
  # The fire emits a gh_api_failed circuit-breaker audit row.
  audit="$SCRATCH/goal-$GOAL_ID.jsonl"
  grep -q '"reason":"gh_api_failed"' "$audit" || { echo "B14.audit-reason FAIL"; exit 1; }
  grep -q '"phase":"poll"'           "$audit" || { echo "B14.audit-phase FAIL"; exit 1; }
  # A success resets the counter → breaker no longer fires.
  _uberdev_goal_reset_gh_failure
  if uberdev_goal_gh_failure_breaker_check "$GOAL_ID" 3; then echo "B14.after-reset-must-not-fire FAIL"; exit 1; fi
  echo "B14 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B14 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B14b — #329 review — batch_unblock_wait_clear feeds the same consecutive
# gh-failure breaker as the main unblock checker. A transient `gh issue view`
# failure must tick the breaker; a healthy follow-up clears it.
# ---------------------------------------------------------------------------
echo "== B14b: batch unblock wait records transient gh issue failures (#329 review) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b14b"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201';; *labels*) printf '0';; esac ;;
      "issue view") printf 'network unavailable' >&2; return 1 ;;
    esac
  }
  err="$SCRATCH/b14b.err"
  if uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" >/dev/null 2>"$err"; then
    echo "B14b.transient-gh-error-must-gate FAIL"; exit 1
  fi
  grep -q 'goal-state: batch unblock PR 100 blocked by issue 201 gh issue view failed rc=1' "$err" \
    || { echo "B14b.transient-gh-error-breadcrumb FAIL (stderr=$(cat "$err"))"; exit 1; }
  grep -q 'network unavailable' "$err" \
    || { echo "B14b.transient-gh-error-stderr FAIL (stderr=$(cat "$err"))"; exit 1; }
  count="$(uberdev_goal_gh_failure_count "$GOAL_ID")"
  [ "$count" = "1" ] || { echo "B14b.transient-gh-error-must-record FAIL (count=$count)"; exit 1; }
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in *body*) printf 'Blocks: #201';; *labels*) printf '0';; esac ;;
      "issue view") printf 'CLOSED' ;;
    esac
  }
  if ! uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" >/dev/null 2>&1; then
    echo "B14b.healthy-gh-closed-must-clear FAIL"; exit 1
  fi
  count="$(uberdev_goal_gh_failure_count "$GOAL_ID")"
  [ "$count" = "0" ] || { echo "B14b.healthy-gh-must-reset FAIL (count=$count)"; exit 1; }
  echo "B14b PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B14b block exited non-zero"; }

# ---------------------------------------------------------------------------
# B15 — #290.4 (MAJOR) — find_pr_for_issue prefers the closingIssuesReferences
# match over the feat/N- head-ref heuristic, and scans --state open. The lib
# must use `--state open` (not `--state all`).
# ---------------------------------------------------------------------------
echo "== B15: find_pr prefers closes-match + scans open (#290.4) =="
assert_grep "$GOAL_LIB" 'gh pr list --state open'   "B15.scans-state-open"
assert_no_grep "$GOAL_LIB" 'gh pr list --state all' "B15.no-state-all"
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b15"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  # PR5 CLOSES issue 77; PR9 merely has a re-used feat/77- branch but closes 88.
  # The closes-match (5) must win over the head-ref distractor (9).
  gh() {
    local jqf='.'; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jqf="$2"; shift; done
    printf '%s' '[{"number":5,"closingIssuesReferences":[{"number":77}],"headRefName":"feat/77-real"},{"number":9,"closingIssuesReferences":[{"number":88}],"headRefName":"feat/77-reused"}]' | jq -r "$jqf"
  }
  got="$(uberdev_goal_find_pr_for_issue 77)"
  [ "$got" = "5" ] || { echo "B15.closes-preference FAIL got '$got' want 5"; exit 1; }
  # Head-ref fallback only when NO closes-match exists.
  gh() {
    local jqf='.'; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jqf="$2"; shift; done
    printf '%s' '[{"number":12,"closingIssuesReferences":[],"headRefName":"feat/77-x"}]' | jq -r "$jqf"
  }
  got2="$(uberdev_goal_find_pr_for_issue 77)"
  [ "$got2" = "12" ] || { echo "B15.head-ref-fallback FAIL got '$got2' want 12"; exit 1; }
  echo "B15 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B15 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B16 — #290.2 (CRITICAL) — read_merge_result reads the merge agent WORKTREE
# mirror (.claude/worktrees/*/.uberdev/audit.jsonl), not just the cwd-relative
# file. A pr_parked row written only in the worktree mirror must classify
# (conflict), where the OLD cwd-only read returned `missing`.
# ---------------------------------------------------------------------------
echo "== B16: read_merge_result anchors to merge worktree audit (#290.2) =="
(
  set -u
  WT="$(mktemp -d)"; trap 'rm -rf "$WT"' EXIT
  export UBERDEV_TMPDIR="$WT"   # (read_merge_result uses cwd-relative globs, not tmpdir)
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  mkdir -p "$WT/.claude/worktrees/merge-run/.uberdev"
  printf '%s\n' '{"event":"pr_parked","data":{"pr":777,"reason":"refused"}}' \
    > "$WT/.claude/worktrees/merge-run/.uberdev/audit.jsonl"
  gh() { case "$1 $2" in "pr view") printf 'OPEN';; esac; }   # not merged
  out="$(cd "$WT" && uberdev_goal_read_merge_result 777)"
  [ "$out" = "conflict" ] || { echo "B16.worktree-audit FAIL got '$out' want conflict"; exit 1; }
  # Cross-file: cwd has a stale parked row, worktree has the real merge_executed.
  # The worktree row (slurped LAST in glob order) wins → success.
  mkdir -p "$WT/.uberdev"
  printf '%s\n' '{"event":"pr_parked","data":{"pr":888,"reason":"refused"}}' > "$WT/.uberdev/audit.jsonl"
  printf '%s\n' '{"event":"merge_executed","data":{"pr":888}}' > "$WT/.claude/worktrees/merge-run/.uberdev/audit.jsonl"
  out2="$(cd "$WT" && uberdev_goal_read_merge_result 888)"
  [ "$out2" = "success" ] || { echo "B16.cross-file-worktree-wins FAIL got '$out2' want success"; exit 1; }
  echo "B16 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B16 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B17 — #289.2 (BLOCKER) — MERGING is a valid NON-terminal batch sentinel that
# excludes the PR from the green-ordered list and forces batch_all_terminal to
# rc 1 (the cross-pass serialization interlock). SKILL.md Phase 2c must use it.
# ---------------------------------------------------------------------------
echo "== B17: MERGING sentinel serializes merge dispatch (#289.2) =="
(
  set -u
  SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
  export UBERDEV_TMPDIR="$SCRATCH"; export UBERDEV_GOAL_ID="b17"
  GOAL_ID="$UBERDEV_GOAL_ID"
  . "$DISPATCH_LIB"; . "$GOAL_LIB"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null
  uberdev_goal_register_batch_pr "$GOAL_ID" 101 201 >/dev/null
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 GREEN
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 101 GREEN
  uberdev_goal_batch_all_terminal "$GOAL_ID" || { echo "B17.precondition-all-green-terminal FAIL"; exit 1; }
  # Dispatch lowest (100) → MERGING.
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 MERGING || { echo "B17.set-merging-rc FAIL"; exit 1; }
  if uberdev_goal_batch_all_terminal "$GOAL_ID"; then
    echo "B17.merging-must-block-all-terminal FAIL (barrier did not interlock)"; exit 1
  fi
  ordered="$(_uberdev_goal_batch_green_prs_ordered "$GOAL_ID" | tr '\n' ' ' | sed 's/  *$//')"
  [ "$ordered" = "101" ] || { echo "B17.merging-dropped-from-green FAIL got '$ordered' want 101"; exit 1; }
  echo "B17 PASS"
) || { FAIL=$((FAIL + 1)); echo "  FAIL  B17 block exited non-zero"; }

# ---------------------------------------------------------------------------
# B18 — #289.2 step-2c structural: the green-PR merge loop must take the LOWEST
# green PR (head -n 1) and flip it to the MERGING sentinel, NOT loop over all
# green PRs dispatching /merge in one async pass.
# RFC 0015 §5 moved that loop out of the SKILL.md fence into lib/goal-watch.sh;
# the serialization property is unchanged, so the asserts follow the code.
# ---------------------------------------------------------------------------
echo "== B18: step 2c dispatches lowest green PR + MERGING sentinel (#289.2 structural) =="
GOAL_WATCH="$REPO_ROOT/plugins/uberdev/lib/goal-watch.sh"
[ -r "$GOAL_WATCH" ] || { printf 'FATAL: required file missing or unreadable: %s\n' "$GOAL_WATCH" >&2; exit 2; }
assert_grep "$GOAL_WATCH" '_uberdev_goal_batch_green_prs_ordered "\$GOAL_ID" \| head -n 1' "B18.lowest-green-head1"
assert_grep "$GOAL_WATCH" '_uberdev_goal_set_batch_terminal_state "\$GOAL_ID" "\$pr" MERGING' "B18.flips-to-merging"
# The phantom-label gate must NOT appear as a live jq select in the lib.
assert_no_grep "$GOAL_LIB"  'select\(\. == "review-pr:green"\)'                              "B18.no-phantom-green-gate-in-lib"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
