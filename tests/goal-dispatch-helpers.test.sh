#!/usr/bin/env bash
# tests/goal-dispatch-helpers.test.sh
#
# Behavioral coverage for the lib/dispatch.sh dependency guards in
# lib/goal-state.sh's two dispatch helpers (issue #207):
#   _uberdev_goal_dispatch_review_pr
#   _uberdev_goal_dispatch_merge
#
# Both helpers call uberdev_dispatch_one — which lives in lib/dispatch.sh,
# NOT in goal-state.sh — without any preflight. A caller that sources
# goal-state.sh without dispatch.sh would otherwise hit a bare `command
# not found` mid-dispatch. The guards must:
#   - fail loud with rc=4 (matching the writer + register_batch_pr convention)
#   - emit a diagnostic naming lib/dispatch.sh + the missing symbol
#   - never let `command not found` leak through
#   - run AFTER cheap arg validation (so bad-arg rcs stay at 1) but BEFORE
#     mktemp (so no temp sibling leaks on the missing-dep path)
#
# Mirrors the #195 fresh-`bash -c` pattern in tests/goal-state-sidecar.test.sh.
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

_t_tmpdir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-disp-%s' "$$")"
mkdir -p "$_t_tmpdir"
UBERDEV_TMPDIR="$_t_tmpdir"
export UBERDEV_TMPDIR
trap 'rm -rf "$_t_tmpdir"' EXIT

# ---------------------------------------------------------------------------
# NEGATIVE: dispatch.sh withheld → both helpers must trip the preflight.
# Valid pr + valid UBERDEV_GOAL_ID so the int + id validates pass and the
# guard, not validation, is what trips. Counter-attempts TSV pre-seeded
# empty so `_uberdev_goal_count_review_pr_attempts` returns 0 < cap.
# ---------------------------------------------------------------------------

echo "== #207: _uberdev_goal_dispatch_review_pr preflights its lib/dispatch.sh dependency =="
g_dir_rpr="$(mktemp -d 2>/dev/null || printf '/tmp/goal-207-rpr-%s' "$$")"
g_rpr_rc="$(UBERDEV_TMPDIR="$g_dir_rpr" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  UBERDEV_GOAL_ID="goal-test-rpr00207" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"   # dispatch.sh deliberately NOT sourced
    _uberdev_goal_dispatch_review_pr 123 2>"$UBERDEV_TMPDIR/rpr-err.txt"
    printf "%s" "$?"
  ')"
assert_eq "$g_rpr_rc" "4" "#207 rpr missing-dispatch: returns the distinct dependency rc (4), not 1 or 127"
if grep -q 'requires lib/dispatch.sh' "$g_dir_rpr/rpr-err.txt" 2>/dev/null; then
  assert_eq "diag" "diag"    "#207 rpr missing-dispatch: emits diagnostic naming lib/dispatch.sh"
else
  assert_eq "diag" "MISSING" "#207 rpr missing-dispatch: emits diagnostic naming lib/dispatch.sh"
fi
if grep -q 'uberdev_dispatch_one' "$g_dir_rpr/rpr-err.txt" 2>/dev/null; then
  assert_eq "names-sym" "names-sym"    "#207 rpr missing-dispatch: diagnostic names the missing symbol"
else
  assert_eq "names-sym" "MISSING-SYM"  "#207 rpr missing-dispatch: diagnostic names the missing symbol"
fi
if grep -qi 'command not found' "$g_dir_rpr/rpr-err.txt" 2>/dev/null; then
  assert_eq "no-cnf" "command-not-found-leaked" "#207 rpr missing-dispatch: NO raw 'command not found' crash noise"
else
  assert_eq "no-cnf" "no-cnf"                   "#207 rpr missing-dispatch: NO raw 'command not found' crash noise"
fi
# Guard must trip BEFORE mktemp; no stray prompt-file sibling left behind.
# _uberdev_goal_dispatch_review_pr's mktemp is bare (no template), so the
# leak target is any newly-created file under $UBERDEV_TMPDIR. Empty
# isolated tmpdir means a hit here = leak.
rpr_stray="$(find "$g_dir_rpr" -maxdepth 1 -type f ! -name 'rpr-err.txt' 2>/dev/null | head -1)"
assert_eq "${rpr_stray:-none}" "none" "#207 rpr missing-dispatch: no stray prompt-file/temp sibling leaked"
rm -rf "$g_dir_rpr"

echo "== #207: _uberdev_goal_dispatch_merge preflights its lib/dispatch.sh dependency =="
g_dir_mrg="$(mktemp -d 2>/dev/null || printf '/tmp/goal-207-mrg-%s' "$$")"
g_mrg_rc="$(UBERDEV_TMPDIR="$g_dir_mrg" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  UBERDEV_GOAL_ID="goal-test-mrg00207" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"   # dispatch.sh deliberately NOT sourced
    _uberdev_goal_dispatch_merge 456 2>"$UBERDEV_TMPDIR/mrg-err.txt"
    printf "%s" "$?"
  ')"
assert_eq "$g_mrg_rc" "4" "#207 mrg missing-dispatch: returns the distinct dependency rc (4), not 1 or 127"
if grep -q 'requires lib/dispatch.sh' "$g_dir_mrg/mrg-err.txt" 2>/dev/null; then
  assert_eq "diag" "diag"    "#207 mrg missing-dispatch: emits diagnostic naming lib/dispatch.sh"
else
  assert_eq "diag" "MISSING" "#207 mrg missing-dispatch: emits diagnostic naming lib/dispatch.sh"
fi
if grep -q 'uberdev_dispatch_one' "$g_dir_mrg/mrg-err.txt" 2>/dev/null; then
  assert_eq "names-sym" "names-sym"    "#207 mrg missing-dispatch: diagnostic names the missing symbol"
else
  assert_eq "names-sym" "MISSING-SYM"  "#207 mrg missing-dispatch: diagnostic names the missing symbol"
fi
if grep -qi 'command not found' "$g_dir_mrg/mrg-err.txt" 2>/dev/null; then
  assert_eq "no-cnf" "command-not-found-leaked" "#207 mrg missing-dispatch: NO raw 'command not found' crash noise"
else
  assert_eq "no-cnf" "no-cnf"                   "#207 mrg missing-dispatch: NO raw 'command not found' crash noise"
fi
mrg_stray="$(find "$g_dir_mrg" -maxdepth 1 -type f ! -name 'mrg-err.txt' 2>/dev/null | head -1)"
assert_eq "${mrg_stray:-none}" "none" "#207 mrg missing-dispatch: no stray prompt-file/temp sibling leaked"
rm -rf "$g_dir_mrg"

# ---------------------------------------------------------------------------
# POSITIVE: with dispatch.sh sourced (so the symbol exists) AND a same-
# session stub of uberdev_dispatch_one, both helpers must proceed past the
# guard, run their counter-write + mktemp, and reach the dispatch call.
# The stub records the call and returns 0 — we then assert the helper
# itself returns 0 and the stub got the expected (pr, "small", file) shape.
# ---------------------------------------------------------------------------

echo "== #207: dispatch.sh sourced + uberdev_dispatch_one stub → both helpers reach the dispatch =="
g_dir_pos="$(mktemp -d 2>/dev/null || printf '/tmp/goal-207-pos-%s' "$$")"
pos_out="$(UBERDEV_TMPDIR="$g_dir_pos" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  UBERDEV_GOAL_ID="goal-test-pos00207" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    # Override the real dispatch entry-point AFTER sourcing — bash will use
    # this redefinition. The stub records its argv shape so the test can
    # assert the helper threaded the right tier+args.
    uberdev_dispatch_one() {
      printf "%s|%s|%s\n" "$1" "$2" "$3" > "$UBERDEV_TMPDIR/dispatch-call.txt"
      return 0
    }
    _uberdev_goal_dispatch_review_pr 789; rpr_rc=$?
    _uberdev_goal_dispatch_merge      890; mrg_rc=$?
    printf "rpr=%s mrg=%s\n" "$rpr_rc" "$mrg_rc"
    # Surface the recorded dispatch shape (last call wins).
    cat "$UBERDEV_TMPDIR/dispatch-call.txt" 2>/dev/null
  ')"
# rc=0 from both helpers (passed the guard, reached the stub, stub returned 0)
case "$pos_out" in
  *"rpr=0 mrg=0"*)
    assert_eq "happy" "happy" "#207 pos: both helpers return 0 when dispatch.sh is sourced + stub installed" ;;
  *)
    assert_eq "happy" "MISSING (got: $pos_out)" "#207 pos: both helpers return 0 when dispatch.sh is sourced + stub installed" ;;
esac
case "$pos_out" in
  *"890|small|"*)
    assert_eq "stub-shape" "stub-shape" "#207 pos: stub receives (pr, \"small\", prompt_file) — helper threaded tier correctly" ;;
  *)
    assert_eq "stub-shape" "MISSING (got: $pos_out)" "#207 pos: stub receives (pr, \"small\", prompt_file) — helper threaded tier correctly" ;;
esac
rm -rf "$g_dir_pos"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "== Summary =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
