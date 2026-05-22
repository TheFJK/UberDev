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
