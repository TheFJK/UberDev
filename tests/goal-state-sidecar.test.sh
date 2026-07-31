#!/usr/bin/env bash
# tests/goal-state-sidecar.test.sh
#
# Behavioral coverage for the run-state sidecar helpers added to
# lib/goal-state.sh (issue #171): uberdev_goal_write_run_state /
# uberdev_goal_read_run_state / uberdev_goal_cleanup_run_state.
#
# These tests SOURCE the real libs and exercise the functions across a
# FRESH `bash -c` to prove cross-call survival — the exact failure mode
# #171 fixes. No `source`/`eval` of the sidecar is ever performed; the
# no-source guarantee is asserted directly.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT
GOAL_LIB="$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
DISPATCH_LIB="$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"

for f in "$GOAL_LIB" "$DISPATCH_LIB"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (got=[%s] want=[%s])\n' "$label" "$got" "$want" >&2
  fi
}
assert_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (path exists: %s)\n' "$label" "$path" >&2
  fi
}

# Isolated tmpdir so writes never collide with production state.
_t_tmpdir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-sidecar-%s' "$$")"
mkdir -p "$_t_tmpdir"
UBERDEV_TMPDIR="$_t_tmpdir"
export UBERDEV_TMPDIR
trap 'rm -rf "$_t_tmpdir"' EXIT

# shellcheck source=/dev/null
. "$DISPATCH_LIB"
# shellcheck source=/dev/null
. "$GOAL_LIB"

echo "== scalar round-trip across fresh bash -c =="
GOAL_ID="goal-test-12345678"; cycle=2; watch_start=1716400000
overflow_count=1; overflow_detected=0; MAX_CYCLES=5
UBERDEV_RESOLVED_BACKEND="claude-bg"
uberdev_goal_write_run_state
assert_eq "$?" "0" "write returns 0"

read_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-12345678" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    printf "%s|%s|%s|%s|%s|%s" "$GOAL_ID" "$cycle" "$watch_start" "$overflow_count" "$MAX_CYCLES" "$UBERDEV_RESOLVED_BACKEND"
  ')"
assert_eq "$read_out" "goal-test-12345678|2|1716400000|1|5|claude-bg" "fresh-shell read recovers all scalars"

echo "== reproduction-equivalence (no empty GOAL_ID, no command-not-found) =="
repro="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-12345678" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    [ -n "$GOAL_ID" ] || exit 8
    type uberdev_goal_audit >/dev/null 2>&1 || exit 7
    case "$GOAL_ID" in goal--*) exit 6 ;; esac   # mis-pathing guard
    printf "ok"
  ')"
assert_eq "$repro" "ok" "fresh shell: non-empty GOAL_ID + defined uberdev_goal_* fn"

echo "== #195: run-state writer preflight-guards its lib/dispatch.sh dependency =="
# uberdev_goal_write_run_state hard-depends on _uberdev_dispatch_prepare_tmp_target,
# which lives in lib/dispatch.sh — NOT in goal-state.sh. Before the #195 fix the
# header claimed NO external function was required and there was no guard, so a
# caller that sourced goal-state.sh WITHOUT dispatch.sh got a cryptic `command
# not found` plus a MISLEADING rc=3 (the documented write-failure code), instead
# of a loud contract diagnostic. The writer must now fail with a DISTINCT rc and
# a message naming the missing lib, and must never emit `command not found`.
#
# NEGATIVE: a fresh shell sources ONLY goal-state.sh (dispatch.sh withheld). A
# VALID GOAL_ID is used so validation passes and the dependency call is reached —
# the dependency guard, not id-validation, must be what trips.
g195_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-195-%s' "$$")"
g195_rc="$(UBERDEV_TMPDIR="$g195_dir" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-no195deps" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"   # dispatch.sh deliberately NOT sourced
    uberdev_goal_write_run_state 2>"$UBERDEV_TMPDIR/g195-err.txt"
    printf "%s" "$?"
  ')"
assert_eq "$g195_rc" "4" "#195 missing-dispatch: writer returns the distinct dependency rc (4), not the conflated write-fail rc (3)"
if grep -q 'requires lib/dispatch.sh' "$g195_dir/g195-err.txt" 2>/dev/null; then
  assert_eq "diag" "diag"    "#195 missing-dispatch: emits clear diagnostic naming lib/dispatch.sh"
else
  assert_eq "diag" "MISSING" "#195 missing-dispatch: emits clear diagnostic naming lib/dispatch.sh"
fi
if grep -qi 'command not found' "$g195_dir/g195-err.txt" 2>/dev/null; then
  assert_eq "no-cnf" "command-not-found-leaked" "#195 missing-dispatch: NO raw 'command not found' crash noise"
else
  assert_eq "no-cnf" "no-cnf"                   "#195 missing-dispatch: NO raw 'command not found' crash noise"
fi
# Guard must trip BEFORE mktemp, so no stray run-state temp sibling is leaked.
g195_stray="$(find "$g195_dir" -name 'goal-*runstate*' 2>/dev/null | head -1)"
assert_eq "${g195_stray:-none}" "none" "#195 missing-dispatch: no stray run-state temp file leaked"
#
# POSITIVE: with dispatch.sh sourced first the writer still succeeds (rc=0) — the
# guard is a precondition check, not a behavior change on the happy path.
g195_ok="$(UBERDEV_TMPDIR="$g195_dir" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-with195dep" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    cycle=1; watch_start=1; overflow_count=0; overflow_detected=0; MAX_CYCLES=5
    UBERDEV_RESOLVED_BACKEND=claude-bg; queue=(); active_issues=()
    uberdev_goal_write_run_state
    printf "%s" "$?"
  ')"
assert_eq "$g195_ok" "0" "#195 with dispatch.sh sourced: writer still returns 0 (guard is preflight-only)"
rm -rf "$g195_dir"

echo "== array round-trip (queue/active_issues) + empty-array =="
GOAL_ID="goal-test-arr00001"; cycle=1; watch_start=1716400000
overflow_count=0; overflow_detected=0; MAX_CYCLES=5; UBERDEV_RESOLVED_BACKEND="background"
queue=(101 202 303); active_issues=(404)
uberdev_goal_write_run_state
arr_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-arr00001" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    printf "%s;%s;%s" "${queue[*]}" "${#queue[@]}" "${#active_issues[@]}"
  ')"
assert_eq "$arr_out" "101 202 303;3;1" "queue+active_issues round-trip"

# empty-array case: write with empty queue, expect 0 elements (no phantom)
GOAL_ID="goal-test-arr00002"; queue=(); active_issues=()
uberdev_goal_write_run_state
empty_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-arr00002" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    printf "%s" "${#queue[@]}"
  ')"
assert_eq "$empty_out" "0" "empty queue yields zero elements (no phantom)"

echo "== validation rejects path-traversal GOAL_ID =="
forge_id="goal-test-forge001"
forged="$UBERDEV_TMPDIR/goal-$forge_id-runstate"
printf 'GOAL_ID=../pwned\ncycle=1\nwatch_start=1\noverflow_count=0\noverflow_detected=0\nMAX_CYCLES=5\nUBERDEV_RESOLVED_BACKEND=claude-bg\n' > "$forged"
trav_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="$forge_id" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state 2>/dev/null
    printf "%s" "$GOAL_ID"   # must NOT be ../pwned
  ')"
# GOAL_ID must remain the caller-provided value (or unknown sink), never the traversal
case "$trav_out" in
  *../*|*pwned*) assert_eq "rejected" "accepted" "path-traversal GOAL_ID rejected" ;;
  *)            assert_eq "rejected" "rejected" "path-traversal GOAL_ID rejected" ;;
esac

echo "== validation rejects non-int counter =="
ni_id="goal-test-nonint01"
ni="$UBERDEV_TMPDIR/goal-$ni_id-runstate"
printf 'GOAL_ID=%s\ncycle=not-a-number\nwatch_start=1716400000\noverflow_count=0\noverflow_detected=0\nMAX_CYCLES=5\nUBERDEV_RESOLVED_BACKEND=claude-bg\n' "$ni_id" > "$ni"
ni_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="$ni_id" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    cycle=SENTINEL
    uberdev_goal_read_run_state 2>/dev/null
    printf "%s" "$cycle"   # must NOT be the literal not-a-number
  ')"
case "$ni_out" in
  not-a-number) assert_eq "rejected" "accepted" "non-int cycle rejected" ;;
  *)            assert_eq "rejected" "rejected" "non-int cycle rejected" ;;
esac

echo "== no-source guarantee (read-not-source) =="
ns_id="goal-test-nosrc001"
ns="$UBERDEV_TMPDIR/goal-$ns_id-runstate"
marker="$UBERDEV_TMPDIR/PWNED"
rm -f "$marker"
# Deliberately malicious value; the validating reader must NOT eval/source it.
printf 'GOAL_ID=x; touch %s/PWNED\ncycle=1\nwatch_start=1\noverflow_count=0\noverflow_detected=0\nMAX_CYCLES=5\nUBERDEV_RESOLVED_BACKEND=claude-bg\n' "$UBERDEV_TMPDIR" > "$ns"
UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="$ns_id" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state 2>/dev/null || true
  ' >/dev/null 2>&1 || true
assert_absent "$marker" "metacharacter payload did not execute (no source/eval)"

echo "== fixed-path active-id bootstrap: fresh shell with NO GOAL_ID recovers from pointer (#171 AC2) =="
GOAL_ID="goal-test-boot00001"; cycle=3; watch_start=1716400000
overflow_count=0; overflow_detected=0; MAX_CYCLES=7; UBERDEV_RESOLVED_BACKEND="claude-bg"
queue=(501 601); active_issues=()
uberdev_goal_write_run_state
# Fresh shell: explicitly unset GOAL_ID + UBERDEV_GOAL_ID (mirrors a real
# Phase-1 Bash call where env + scalars evaporated). Must recover from the
# fixed-path pointer — this is the actual cross-call fix, not the env fallback.
boot_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    unset GOAL_ID UBERDEV_GOAL_ID
    uberdev_goal_read_run_state || exit 9
    printf "%s|%s|%s" "$GOAL_ID" "$cycle" "${queue[*]}"
  ')"
assert_eq "$boot_out" "goal-test-boot00001|3|501 601" "fresh shell with no env recovers GOAL_ID+state from active-id pointer"

echo "== active-id pointer path-traversal rejected (security) =="
# Forge the fixed-path pointer with a traversal payload; the bootstrap must
# reject it (validate_id gate) and NOT adopt it as GOAL_ID.
printf '../pwned\n' > "$UBERDEV_TMPDIR/goal-active-id.txt"
ptrav_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    unset GOAL_ID UBERDEV_GOAL_ID
    uberdev_goal_read_run_state 2>/dev/null
    printf "id=[%s]" "${GOAL_ID:-}"
  ')"
case "$ptrav_out" in
  *pwned*|*../*) assert_eq "rejected" "accepted" "active-id pointer traversal rejected" ;;
  *)            assert_eq "rejected" "rejected" "active-id pointer traversal rejected" ;;
esac

echo "== Phase0->1->2 hand-off: active_issues populated in Phase 1 survives to Phase 2 (separate fresh shells; #171 review gap) =="
# This is the end-to-end regression guard for the wave-2-review CRITICAL: Phase 0
# flushes run-state BEFORE active_issues exists (empty .active sidecar); Phase 1
# (a fresh shell) rehydrates, appends the dispatched issue, and MUST flush; Phase 2
# (another fresh shell) rehydrates and must see the Phase 1 mutation. Without the
# Phase 1 flush, Phase 2 reads an empty active_issues and false-converges on cycle 1.
GOAL_ID="goal-test-handoff01"; cycle=1; watch_start="$(date +%s)"
overflow_count=0; overflow_detected=0; MAX_CYCLES=5; UBERDEV_RESOLVED_BACKEND="claude-bg"
queue=(123); active_issues=()
uberdev_goal_write_run_state                      # Phase 0 flush (active_issues still empty)
# Phase 1 (fresh shell): rehydrate, simulate a dispatch populating active_issues, flush.
UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-handoff01" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    active_issues+=("201")          # simulate Phase 1 dispatch adding an active issue
    uberdev_goal_write_run_state || exit 8   # the flush the wave-2 review found missing
  ' || { FAIL=$((FAIL + 1)); printf "  FAIL  phase-1 hand-off sim errored\n" >&2; }
# Phase 2 (fresh shell): rehydrate, assert the Phase 1 active_issues mutation survived.
handoff_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-handoff01" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    printf "%s|%s" "${active_issues[*]}" "${#active_issues[@]}"
  ')"
assert_eq "$handoff_out" "201|1" "Phase 1 active_issues mutation survives to Phase 2 fresh shell"

echo "== read_run_state re-exports UBERDEV_GOAL_ID + UBERDEV_TMPDIR for fresh-shell helpers (#178 review blockers) =="
# Four uberdev_goal_* helpers gate on the UBERDEV_GOAL_ID *env var* (audit sink,
# should_automerge provenance, review-pr/merge dispatch); the goal-pipeline body
# interpolates bare $UBERDEV_TMPDIR/... paths and PR #129 helpers fall back to it.
# read_run_state MUST export BOTH so a rehydrated fresh shell doesn't mis-sink
# audit to goal-unknown.jsonl, refuse a GREEN PR auto-merge, or resolve state
# files under / or /tmp instead of the dir Phase 0 wrote.
GOAL_ID="goal-test-export01"; cycle=1; watch_start=1; overflow_count=0
overflow_detected=0; MAX_CYCLES=5; UBERDEV_RESOLVED_BACKEND="claude-bg"
queue=(); active_issues=()
uberdev_goal_write_run_state
# Fresh shell: TMPDIR set (so the helper fallback locates the sidecar) but BOTH
# UBERDEV_GOAL_ID and UBERDEV_TMPDIR unset — the two vars read_run_state must
# export. `env` lists only EXPORTED vars, so it distinguishes export from a bare
# scalar assignment (the exact bug: read_run_state set GOAL_ID but exported nothing).
export_out="$(TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  GOAL_ID="goal-test-export01" bash -c '
    unset UBERDEV_GOAL_ID UBERDEV_TMPDIR
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    g=FAIL; t=FAIL
    env | grep -q "^UBERDEV_GOAL_ID=goal-test-export01$" && g=OK
    env | grep -q "^UBERDEV_TMPDIR=." && t=OK
    printf "%s|%s" "$g" "$t"
  ')"
assert_eq "$export_out" "OK|OK" "read_run_state exports UBERDEV_GOAL_ID + UBERDEV_TMPDIR to the rehydrated shell env"

echo "== cleanup removes all three sidecars + the active-id pointer =="
GOAL_ID="goal-test-clean001"; cycle=1; watch_start=1; overflow_count=0
overflow_detected=0; MAX_CYCLES=5; UBERDEV_RESOLVED_BACKEND="claude-bg"
queue=(1 2); active_issues=(3)
uberdev_goal_write_run_state
sc="$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
uberdev_goal_cleanup_run_state
assert_eq "$?" "0" "cleanup returns 0"
assert_absent "$sc"          "runstate sidecar removed"
assert_absent "${sc}.queue"  "queue sidecar removed"
assert_absent "${sc}.active" "active sidecar removed"
assert_absent "${sc}.candidates" "candidates sidecar removed (#301)"
assert_absent "$UBERDEV_TMPDIR/goal-active-id.txt" "active-id pointer removed (names this goal)"
uberdev_goal_cleanup_run_state   # second call on already-gone files
assert_eq "$?" "0" "cleanup idempotent (non-fatal when absent)"

echo "== S-barrier-1: MAX_PARALLEL / BARRIER_TIMEOUT_S / barrier_start_ts survive cross-shell rehydrate (#211 wave-1) =="
# The batch-barrier scalars (MAX_PARALLEL, BARRIER_TIMEOUT_S, barrier_start_ts)
# must persist across the same fresh-shell boundary the existing watch_start
# round-trip exercises — otherwise Phase 1 sees an empty barrier_start_ts on
# rehydrate and the barrier-timeout circuit-breaker fires immediately (or
# never, depending on which side wins the empty-string comparison).
#
# Write the three barrier scalars alongside the required existing scalars,
# then re-enter a fresh `bash --noprofile --norc -c` with env CLEARED except
# UBERDEV_TMPDIR (the bootstrap pointer recovers GOAL_ID from the fixed-path
# active-id file; do NOT re-export GOAL_ID — that defeats the bootstrap test).
GOAL_ID="goal-test-barrier01"; cycle=1; watch_start=1700000000
overflow_count=0; overflow_detected=0; MAX_CYCLES=5
UBERDEV_RESOLVED_BACKEND="claude-bg"
queue=(); active_issues=()
MAX_PARALLEL=3
BARRIER_TIMEOUT_S=14400
barrier_start_ts=1700009999
uberdev_goal_write_run_state
barrier_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  bash --noprofile --norc -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_read_run_state || exit 9
    printf "MAX_PARALLEL=%s\nBARRIER_TIMEOUT_S=%s\nbarrier_start_ts=%s\n" \
      "${MAX_PARALLEL:-}" "${BARRIER_TIMEOUT_S:-}" "${barrier_start_ts:-}"
  ')"
mp_got="$(printf '%s\n' "$barrier_out" | grep '^MAX_PARALLEL=' | head -1 | cut -d= -f2-)"
bt_got="$(printf '%s\n' "$barrier_out" | grep '^BARRIER_TIMEOUT_S=' | head -1 | cut -d= -f2-)"
bs_got="$(printf '%s\n' "$barrier_out" | grep '^barrier_start_ts=' | head -1 | cut -d= -f2-)"
assert_eq "$mp_got" "3"          "S-barrier-1: MAX_PARALLEL survives fresh-shell rehydrate"
assert_eq "$bt_got" "14400"      "S-barrier-1: BARRIER_TIMEOUT_S survives fresh-shell rehydrate"
assert_eq "$bs_got" "1700009999" "S-barrier-1: barrier_start_ts survives fresh-shell rehydrate"

echo "== S4: REVIEW_GRACE_SECS round-trip + EXPORT survives fresh-bash (issue #220, AC ❶) =="
GOAL_ID=goal-test-s4abc1234; cycle=1; watch_start=$(date +%s)
overflow_count=0; overflow_detected=0; MAX_CYCLES=5
MAX_PARALLEL=3; BARRIER_TIMEOUT_S=14400; barrier_start_ts=$(date +%s)
UBERDEV_RESOLVED_BACKEND=background
REVIEW_GRACE_SECS=900
queue=(207 210); active_issues=()
uberdev_goal_write_run_state || { FAIL=$((FAIL+1)); echo "  FAIL  S4.write" >&2; }
s4_got="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null
  printf "REVIEW_GRACE_SECS=%s exported=%s\n" "${REVIEW_GRACE_SECS:-UNSET}" "$(env | grep -c "^REVIEW_GRACE_SECS=")"
')"
case "$s4_got" in
  "REVIEW_GRACE_SECS=900 exported=1")
    PASS=$((PASS+1)); echo "  PASS  S4.round-trip-and-exported" ;;
  *)
    FAIL=$((FAIL+1)); echo "  FAIL  S4.round-trip-and-exported (got [$s4_got])" >&2 ;;
esac

echo "== S5: PRIOR_LAST_ACTIVITY_<pid> per-pid sidecar key round-trip (issue #220, AC ❸) =="
# B4 (post-impl-review): the detector stores row_count (int) here; the
# fixture must use an int so the post-fix int-validate gate accepts the
# value on read-back. The earlier ISO-8601 fixture (timestamp string) would
# now be silently dropped by the gate, breaking the round-trip assertion.
PRIOR_LAST_ACTIVITY_12345="1234"; export PRIOR_LAST_ACTIVITY_12345
FIRST_DIALOG_TS_12345=1729000000; export FIRST_DIALOG_TS_12345
uberdev_goal_write_run_state || { FAIL=$((FAIL+1)); echo "  FAIL  S5.write" >&2; }
s5_got="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null
  printf "PRIOR_LAST_ACTIVITY_12345=%s FIRST_DIALOG_TS_12345=%s\n" \
    "${PRIOR_LAST_ACTIVITY_12345:-UNSET}" "${FIRST_DIALOG_TS_12345:-UNSET}"
')"
case "$s5_got" in
  "PRIOR_LAST_ACTIVITY_12345=1234 FIRST_DIALOG_TS_12345=1729000000")
    PASS=$((PASS+1)); echo "  PASS  S5.per-pid-keys-round-trip" ;;
  *)
    FAIL=$((FAIL+1)); echo "  FAIL  S5.per-pid-keys-round-trip (got [$s5_got])" >&2 ;;
esac
printf 'PRIOR_LAST_ACTIVITY_../../etc/passwd=evil\n' >> "$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
s5neg="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null
  # grep -c always prints the count (incl. 0) — no || echo 0 fallback needed.
  env | grep -c "^PRIOR_LAST_ACTIVITY_\\.\\." 2>/dev/null
  exit 0
')"
if [ "$s5neg" = "0" ]; then
  PASS=$((PASS+1)); echo "  PASS  S5.forged-suffix-refused"
else
  FAIL=$((FAIL+1)); echo "  FAIL  S5.forged-suffix-refused (got [$s5neg])" >&2
fi

echo "== S6: CIRCUIT_BREAKER_HALT allowlist + EXPORT round-trip (issue #220, AC ❸) =="
CIRCUIT_BREAKER_HALT=agent_stuck_on_dialog
uberdev_goal_write_run_state || { FAIL=$((FAIL+1)); echo "  FAIL  S6.write" >&2; }
s6_got="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null
  printf "CIRCUIT_BREAKER_HALT=%s exported=%s\n" "${CIRCUIT_BREAKER_HALT:-UNSET}" "$(env | grep -c "^CIRCUIT_BREAKER_HALT=")"
')"
case "$s6_got" in
  "CIRCUIT_BREAKER_HALT=agent_stuck_on_dialog exported=1")
    PASS=$((PASS+1)); echo "  PASS  S6.round-trip-and-exported" ;;
  *)
    FAIL=$((FAIL+1)); echo "  FAIL  S6.round-trip-and-exported (got [$s6_got])" >&2 ;;
esac
sed -i.bak 's/^CIRCUIT_BREAKER_HALT=.*/CIRCUIT_BREAKER_HALT=evil_breaker/' "$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
s6neg="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  unset CIRCUIT_BREAKER_HALT
  uberdev_goal_read_run_state >/dev/null
  printf "%s\n" "${CIRCUIT_BREAKER_HALT:-REFUSED}"
')"
if [ "$s6neg" = "REFUSED" ]; then
  PASS=$((PASS+1)); echo "  PASS  S6.forged-value-refused"
else
  FAIL=$((FAIL+1)); echo "  FAIL  S6.forged-value-refused (got [$s6neg])" >&2
fi

echo "== S7: two-process Phase-3 fence handoff — .candidates sidecar (#301, RFC 0012 §3.3 goal-R1 item 1) =="
# THE live false-converge BLOCKER reproduction: Phase-3 fence 1 builds
# new_candidates from the gh query and flushes at fence END; the fingerprint /
# terminal fences are SEPARATE fresh shells that must rehydrate the set from
# DISK. Every process below runs `env -i` with ONLY UBERDEV_TMPDIR + PATH —
# the fresh-shell-with-cleared-env style — because env-passing tests MASK
# cross-fence traps (the #178 class: an exported scalar smuggles state the
# real Bash-tool fence boundary would have dropped). Arrays can never ride
# env at all, so a passing S7 proves the sidecar is the carrier.
#
# P0 (Phase-0 analogue): seed run-state — cycle=4, only_mine=1, no candidates.
env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" GOAL_ID="goal-test-cand0001" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  cycle=4; watch_start=1716400000; overflow_count=0; overflow_detected=0
  MAX_CYCLES=5; UBERDEV_RESOLVED_BACKEND=claude-bg; only_mine=1
  queue=(); active_issues=(); new_candidates=()
  uberdev_goal_write_run_state
' || { FAIL=$((FAIL+1)); echo "  FAIL  S7.p0-seed errored" >&2; }
# P1 (Phase-3 fence-1 analogue, process 1): rehydrate via the bootstrap
# pointer (no GOAL_ID anywhere in env), build new_candidates as if from the
# gh query, flush at fence END — the exact flush #301 adds.
env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state || exit 9
  new_candidates=(311 412 513)
  uberdev_goal_write_run_state || exit 8
' || { FAIL=$((FAIL+1)); echo "  FAIL  S7.p1-fence1 errored" >&2; }
# P2 (fingerprint/terminal fence analogue, process 2): rehydrate; candidates
# AND the only_mine identity-filter flag must arrive from disk.
s7_got="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state || exit 9
  printf "%s|%s|%s" "${new_candidates[*]:-}" "${#new_candidates[@]}" "${only_mine:-UNSET}"
')"
assert_eq "$s7_got" "311 412 513|3|1" "S7: candidates + only_mine survive the two-process fence handoff via disk"

echo "== S7-neg: stale-cycle .candidates sidecar is REFUSED, not rehydrated (#301 cycle-tag gate) =="
# A Phase-3 fence that crashed between the gh query and its flush leaves a
# PRIOR-cycle .candidates file behind. read_run_state must yield an EMPTY set
# (fail-safe; the gh-rc breaker is the loud path) instead of feeding stale
# candidates into the terminal gates. Scalar cycle on disk is 4; forge tag 3.
s7sc="$UBERDEV_TMPDIR/goal-goal-test-cand0001-runstate"
printf 'cycle=3\n311\n412\n513\n' > "${s7sc}.candidates"
s7_stale="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state || exit 9
  printf "rc0|%s" "${#new_candidates[@]}"
')"
assert_eq "$s7_stale" "rc0|0" "S7-neg: cycle-tag mismatch yields empty candidates (read still rc 0)"
# Tag-less legacy/forged file (first line not cycle=N): same refusal.
printf '311\n412\n' > "${s7sc}.candidates"
s7_notag="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state || exit 9
  printf "rc0|%s" "${#new_candidates[@]}"
')"
assert_eq "$s7_notag" "rc0|0" "S7-neg: tag-less candidates file yields empty candidates (read still rc 0)"

echo "== S8: UBERDEV_RESOLVED_BACKEND=workflow round-trips the sidecar (RFC 0015) =="
# RFC 0015 added `workflow` to lib/dispatch.sh's _UBERDEV_DISPATCH_BACKEND_ENUM
# but NOT to read_run_state's allowlist. An unlisted value has no else arm — it
# is DROPPED — so a fresh-shell phase fence rehydrated an EMPTY backend and every
# backend `case` in goal-state.sh fell into its default arm: `claude agents
# --json` for liveness and the PID lane for the reaper. A Workflow run was
# therefore probed and reaped as if it were a detached `background` session.
#
# `env -i` with ONLY UBERDEV_TMPDIR + PATH is load-bearing, not stylistic: an
# env-passing test would smuggle UBERDEV_RESOLVED_BACKEND across the boundary and
# pass even with the allowlist unchanged, masking exactly the trap under test
# (the #178 re-export class — project memory
# project_uberdev_goal_runstate_crossshell_traps).
GOAL_ID="goal-test-wf0000001"; cycle=1; watch_start=1716400000
overflow_count=0; overflow_detected=0; MAX_CYCLES=5
UBERDEV_RESOLVED_BACKEND="workflow"
queue=(); active_issues=()
uberdev_goal_write_run_state || { FAIL=$((FAIL+1)); echo "  FAIL  S8.write" >&2; }
s8_got="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null || exit 9
  printf "%s" "${UBERDEV_RESOLVED_BACKEND:-DROPPED}"
')"
assert_eq "$s8_got" "workflow" "S8.workflow-backend-survives-a-cleared-env-fresh-shell"

# NEGATIVE control: a value outside the allowlist must still be dropped, so the
# widening is exactly one member and not a hole.
sed -i.bak 's/^UBERDEV_RESOLVED_BACKEND=.*/UBERDEV_RESOLVED_BACKEND=not-a-backend/' \
  "$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
s8neg="$(env -i UBERDEV_TMPDIR="$UBERDEV_TMPDIR" PATH="$PATH" bash -c '
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_read_run_state >/dev/null || exit 9
  printf "%s" "${UBERDEV_RESOLVED_BACKEND:-REFUSED}"
')"
assert_eq "$s8neg" "REFUSED" "S8-neg.a-value-outside-the-allowlist-is-still-dropped"

echo
printf 'goal-state-sidecar: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
