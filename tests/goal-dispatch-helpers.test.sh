#!/usr/bin/env bash
# tests/goal-dispatch-helpers.test.sh
#
# Behavioral coverage for the lib/dispatch.sh dependency guards in
# lib/goal-state.sh's two dispatch helpers (issue #207).
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

# NEGATIVE: dispatch.sh withheld → both helpers must trip the preflight.
# Valid pr + valid UBERDEV_GOAL_ID so the int + id validates pass and the
# guard, not validation, is what trips. Counter-attempts TSV pre-seeded
# empty so `_uberdev_goal_count_review_pr_attempts` returns 0 < cap.

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

# POSITIVE: with dispatch.sh sourced (so the symbol exists) AND a same-
# session stub of uberdev_dispatch_one, both helpers must proceed past the
# guard, run their counter-write + mktemp, and reach the dispatch call.
# The stub records the call and returns 0 — we then assert the helper
# itself returns 0 and the stub got the expected (pr, "small", file) shape.

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
# TSV state-read helpers (issues #229/#230/#234/#237 — renderer-collision hoist).
# These pure readers source ONLY lib/goal-state.sh (dispatch.sh is not needed —
# no dispatch path is reached). Each helper runs in a fresh `bash -c` with
# UBERDEV_TMPDIR pointing at a seeded mktemp -d, mirroring the #195 fresh-shell
# pattern above. Rows are TAB-separated `key<TAB>state<TAB>ts`.
# ---------------------------------------------------------------------------
echo "== #229/#230/#234/#237: TSV state-read helpers (hoisted from SKILL.md) =="
HOIST_GOAL_ID="goaltesthoist"
hoist_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-hoist-%s' "$$")"

# Seed issue-states.tsv: issue 7 transitions solving@100 then pr-pushed@200
# (last-wins state = pr-pushed); resolved + resolved-by-no-action rows for the
# resolved-count assertion (issues 11 and 12).
issue_tsv="$hoist_dir/goal-$HOIST_GOAL_ID-issue-states.tsv"
printf '7\tsolving\t100\n7\tpr-pushed\t200\n11\tresolved\t300\n12\tresolved-by-no-action\t400\n' > "$issue_tsv"

# Seed pr-states.tsv: pr 42 merging@300 then merging@500 (last-wins ts = 500),
# pushed-reviewing@10 then @20 (first-wins ts = 10); distinct PRs = {42, 99} = 2.
pr_tsv="$hoist_dir/goal-$HOIST_GOAL_ID-pr-states.tsv"
printf '42\tpushed-reviewing\t10\n42\tpushed-reviewing\t20\n42\tmerging\t300\n42\tmerging\t500\n99\tdispatched\t50\n' > "$pr_tsv"

# Seed batch-prs.tsv: pr 42 present, pr 99 absent.
batch_tsv="$hoist_dir/goal-$HOIST_GOAL_ID-batch-prs.tsv"
printf '42\t7\t600\tpushed-reviewing\n' > "$batch_tsv"

# Helper to run one reader in a fresh shell sourcing only goal-state.sh.
_hoist_run() {
  UBERDEV_TMPDIR="$hoist_dir" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
    bash -c '. "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"; '"$1"
}

# uberdev_goal_get_issue_state — last-wins + absent.
got="$(_hoist_run 'uberdev_goal_get_issue_state '"$HOIST_GOAL_ID"' 7')"
assert_eq "$got" "pr-pushed" "#229 get_issue_state: last-wins (issue 7 → pr-pushed)"
got="$(_hoist_run 'uberdev_goal_get_issue_state '"$HOIST_GOAL_ID"' 55')"
assert_eq "$got" "" "#229 get_issue_state: absent issue → empty"

# uberdev_goal_issue_ts_in_state — present state ts + absent → 0.
got="$(_hoist_run 'uberdev_goal_issue_ts_in_state '"$HOIST_GOAL_ID"' 7 solving')"
assert_eq "$got" "100" "#230 issue_ts_in_state: issue 7 solving → 100"
got="$(_hoist_run 'uberdev_goal_issue_ts_in_state '"$HOIST_GOAL_ID"' 7 merging')"
assert_eq "$got" "0" "#230 issue_ts_in_state: issue 7 absent state → 0"

# uberdev_goal_pr_ts_in_state — LAST-wins (merging@500).
got="$(_hoist_run 'uberdev_goal_pr_ts_in_state '"$HOIST_GOAL_ID"' 42 merging')"
assert_eq "$got" "500" "#234 pr_ts_in_state: pr 42 merging LAST-wins → 500"

# uberdev_goal_pr_first_ts_in_state — FIRST-wins (pushed-reviewing@10).
got="$(_hoist_run 'uberdev_goal_pr_first_ts_in_state '"$HOIST_GOAL_ID"' 42 pushed-reviewing')"
assert_eq "$got" "10" "#234 pr_first_ts_in_state: pr 42 pushed-reviewing FIRST-wins → 10"

# uberdev_goal_batch_has_pr — present rc 0, absent rc 1, missing file rc 1.
_hoist_run 'uberdev_goal_batch_has_pr '"$HOIST_GOAL_ID"' 42' ; rc=$?
assert_eq "$rc" "0" "#237 batch_has_pr: present pr 42 → rc 0"
_hoist_run 'uberdev_goal_batch_has_pr '"$HOIST_GOAL_ID"' 99' ; rc=$?
assert_eq "$rc" "1" "#237 batch_has_pr: absent pr 99 → rc 1"
UBERDEV_TMPDIR="$hoist_dir" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  bash -c '. "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"; uberdev_goal_batch_has_pr nofilegoal 42' ; rc=$?
assert_eq "$rc" "1" "#237 batch_has_pr: missing registry file → rc 1"

# uberdev_goal_count_distinct_prs — {42, 99} → exact clean string "2" (no pad).
got="$(_hoist_run 'uberdev_goal_count_distinct_prs '"$HOIST_GOAL_ID")"
assert_eq "$got" "2" "#234 count_distinct_prs: distinct PRs = 2 (clean int, no leading space)"

# uberdev_goal_count_resolved_issues — resolved + resolved-by-no-action = 2.
got="$(_hoist_run 'uberdev_goal_count_resolved_issues '"$HOIST_GOAL_ID")"
assert_eq "$got" "2" "#234 count_resolved_issues: resolved + resolved-by-no-action → 2"

rm -rf "$hoist_dir"

# Summary
echo
echo "== Summary =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
