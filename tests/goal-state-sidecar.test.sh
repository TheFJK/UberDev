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
assert_absent "$UBERDEV_TMPDIR/goal-active-id.txt" "active-id pointer removed (names this goal)"
uberdev_goal_cleanup_run_state   # second call on already-gone files
assert_eq "$?" "0" "cleanup idempotent (non-fatal when absent)"

echo
printf 'goal-state-sidecar: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
