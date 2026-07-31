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

# ---------------------------------------------------------------------------
# lib/goal-abort.sh — release the `uberdev:active` claims a dead /goal run left
# behind (RFC 0015 §6 owed sweep).
#
# The claim is a real cross-process lock: every future /goal cycle AND every
# manual /solve honours it. It is released on two paths only, and neither runs
# when the RUN ITSELF disappears — which is the normal case now that the default
# transport is Workflow-native and dies with the session. A stranded label makes
# the issue permanently un-dispatchable and looks like "/solve silently skips my
# issue", so the sweep has to be right about WHICH issues still hold a claim.
#
# `gh` is stubbed via a PATH shim (not a shell function): goal-abort.sh runs as a
# separate PROCESS, so a function in this shell would never reach it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# #301 speedup finding 1 — per-pass PR snapshot.
#
# Phase 2a resolved every active issue with its OWN `gh pr list --state open
# --limit 200`, N identical round-trips per 60s pass. The snapshot pair replaces
# them with one fetch plus N in-process resolutions. Two properties must hold or
# the swap is a behaviour change, not a speedup: identical RANKING (closes-link
# wins over the feat/N- head heuristic, highest number wins within each), and
# identical FAIL-OPEN semantics (unresolvable => empty + rc 0, never an error the
# watch loop would mistake for "solver died").
# ---------------------------------------------------------------------------
echo "== #301: uberdev_goal_find_pr_for_issue_from_json — same ranking, zero network =="
SNAP='[{"number":100,"closingIssuesReferences":[{"number":42}],"headRefName":"feat/42-a"},
      {"number":140,"closingIssuesReferences":[{"number":42}],"headRefName":"chore/x"},
      {"number":900,"closingIssuesReferences":[],"headRefName":"feat/42-late"},
      {"number":200,"closingIssuesReferences":[],"headRefName":"feat/77-only-head"},
      {"number":210,"closingIssuesReferences":[{"number":88}],"headRefName":"feat/88-b"}]'
# `gh` is SHADOWED (not merely absent) for the whole probe: a shim that records
# its argv and exits 97 sits at the FRONT of PATH. `bash -c` inherits PATH, so
# "we didn't put gh there" would be no guarantee at all — the real gh stays
# resolvable and a regression back to the live finder would make a genuine
# network call and quietly pass. With the shim, any such call is both loud (rc
# 97) and RECORDED, which is what the zero-invocation assertion below reads.
SNAP_BIN="$(mktemp -d 2>/dev/null || printf '/tmp/goal-snap-%s' "$$")"
mkdir -p "$SNAP_BIN"
SNAP_GH_CALLS="$SNAP_BIN/gh-calls.txt"
cat > "$SNAP_BIN/gh" <<'SNAPGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SNAP_GH_CALLS"
printf 'gh: this probe must never reach the network\n' >&2
exit 97
SNAPGH
chmod +x "$SNAP_BIN/gh"
_snap_run() {
  UBERDEV_TMPDIR="${TMPDIR:-/tmp}" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" SNAP="$SNAP" \
    SNAP_GH_CALLS="$SNAP_GH_CALLS" PATH="$SNAP_BIN:$PATH" \
    bash -c '. "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"; '"$1"
}
got="$(_snap_run 'uberdev_goal_find_pr_for_issue_from_json 42 "$SNAP"')"
assert_eq "$got" "140" "#301 from_json: the closes-link match wins, highest number (140, NOT the 900 head-ref match)"
got="$(_snap_run 'uberdev_goal_find_pr_for_issue_from_json 77 "$SNAP"')"
assert_eq "$got" "200" "#301 from_json: falls back to the feat/N- head ref when no closes-link exists"
got="$(_snap_run 'uberdev_goal_find_pr_for_issue_from_json 99 "$SNAP"')"
assert_eq "$got" "" "#301 from_json: unknown issue resolves to empty (not the jq literal 'null')"
got="$(_snap_run 'uberdev_goal_find_pr_for_issue_from_json 42 ""')"
assert_eq "$got" "" "#301 from_json: an empty snapshot (failed fetch) resolves to empty, fail-open"
_snap_run 'uberdev_goal_find_pr_for_issue_from_json 42 ""' >/dev/null 2>&1
assert_eq "$?" "0" "#301 from_json: an empty snapshot is rc 0 — the caller must read it as 'keep waiting', not 'error'"
_snap_run 'uberdev_goal_find_pr_for_issue_from_json abc "$SNAP"' >/dev/null 2>&1
assert_eq "$?" "1" "#301 from_json: a non-integer issue is rejected rc 1 (the R3 gh-injection gate)"
got="$(_snap_run 'uberdev_goal_find_pr_for_issue_from_json 42 "not json"')"
assert_eq "$got" "" "#301 from_json: a malformed snapshot resolves to empty, never a jq error string"
# SSOT: both resolvers must run the SAME ranking program, or the snapshot path
# can silently disagree with the live path about which PR owns an issue.
got="$(_snap_run '_uberdev_goal_pr_for_issue_jq 42 | grep -c "closingIssuesReferences"')"
assert_eq "$got" "1" "#301 the shared ranking program is a single named helper (not duplicated inline)"
if grep -qF '_uberdev_goal_pr_for_issue_jq' "$GOAL_LIB"; then
  live_uses="$(grep -cF '_uberdev_goal_pr_for_issue_jq "$n"' "$GOAL_LIB")"
  assert_eq "$live_uses" "2" "#301 both the live finder and the snapshot finder call the shared ranking helper"
else
  assert_eq "helper" "MISSING" "#301 both the live finder and the snapshot finder call the shared ranking helper"
fi
# Zero network: the shim at the front of PATH was never invoked by ANY of the
# probes above. A regression back to `gh pr list` per resolution trips this.
assert_eq "$([ -e "$SNAP_GH_CALLS" ] && printf yes || printf no)" "no" \
  "#301 from_json: resolves with ZERO gh invocations (the PATH shim recorded nothing)"
rm -rf "$SNAP_BIN"

echo "== goal-abort.sh: releases only NON-terminal claims, then reaps run-state =="
ABORT_SH="$CLAUDE_PLUGIN_ROOT/lib/goal-abort.sh"
if [ ! -r "$ABORT_SH" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort: %s missing\n' "$ABORT_SH" >&2
else
  ab_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-abort-%s' "$$")"
  ab_bin="$ab_dir/bin"; mkdir -p "$ab_bin"
  cat > "$ab_bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Record every `gh issue edit` invocation; fail for issue 66 so the fail-loud
# path is exercised alongside the happy one.
printf '%s\n' "$*" >> "$GH_CALLS"
for a in "$@"; do
  if [ "$a" = "66" ]; then
    printf 'HTTP 403: Resource not accessible\n' >&2
    exit 1
  fi
done
exit 0
GHSTUB
  chmod +x "$ab_bin/gh"

  AB_GOAL_ID="goaltestabort"
  # Ledger: 11 is still solving (claim held), 22 was dispatched but never
  # progressed (claim held), 33 resolved via merge (released by the merge path),
  # 44 failed (released at its terminal transition), 55 resolved-by-no-action
  # (same). Only 11 and 22 may be touched.
  printf '11\tdispatched\t100\n11\tsolving\t150\n22\tdispatched\t120\n33\tsolving\t130\n33\tresolved\t900\n44\tsolving\t140\n44\tfailed\t910\n55\tresolved-by-no-action\t920\n' \
    > "$ab_dir/goal-$AB_GOAL_ID-issue-states.tsv"
  printf '%s\n' "$AB_GOAL_ID" > "$ab_dir/goal-active-id.txt"
  printf 'GOAL_ID=%s\ncycle=1\n' "$AB_GOAL_ID" > "$ab_dir/goal-$AB_GOAL_ID-runstate"

  # DRY RUN first: must mutate nothing and keep the run-state.
  ab_dry="$(GH_CALLS="$ab_dir/calls-dry.txt" PATH="$ab_bin:$PATH" UBERDEV_TMPDIR="$ab_dir" \
    bash "$ABORT_SH" --dry-run 2>&1)"
  assert_eq "$([ -e "$ab_dir/calls-dry.txt" ] && printf yes || printf no)" "no" \
    "goal-abort dry-run: no gh mutation at all"
  if grep -qF "would_release=2" <<<"$ab_dry"; then
    PASS=$((PASS + 1)); printf '  PASS  goal-abort dry-run: reports exactly the 2 non-terminal claims\n'
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort dry-run: expected would_release=2 (got: [%s])\n' "$ab_dry" >&2
  fi
  assert_eq "$([ -e "$ab_dir/goal-$AB_GOAL_ID-runstate" ] && printf yes || printf no)" "yes" \
    "goal-abort dry-run: run-state left intact"

  # REAL run, resolving the goal from the fixed-path pointer (the only channel
  # that survives a killed session — no GOAL_ID argument, no env var).
  ab_out="$(GH_CALLS="$ab_dir/calls.txt" PATH="$ab_bin:$PATH" UBERDEV_TMPDIR="$ab_dir" \
    bash "$ABORT_SH" 2>&1)"
  ab_rc=$?
  ab_calls="$(cat "$ab_dir/calls.txt" 2>/dev/null)"
  assert_eq "$(grep -c 'issue edit' <<<"$ab_calls")" "2" \
    "goal-abort: exactly 2 gh edits — terminal issues are NOT touched"
  if grep -qE 'issue edit 11 .*--remove-label uberdev:active .*--remove-assignee' <<<"$ab_calls"; then
    PASS=$((PASS + 1)); printf '  PASS  goal-abort: releases label AND assignee in one atomic gh call\n'
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort: expected a combined remove-label+remove-assignee edit (got: [%s])\n' "$ab_calls" >&2
  fi
  for terminal in 33 44 55; do
    if grep -qE "issue edit $terminal( |\$)" <<<"$ab_calls"; then
      FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort: touched terminal issue %s (its claim was already released)\n' "$terminal" >&2
    else
      PASS=$((PASS + 1)); printf '  PASS  goal-abort: leaves terminal issue %s alone\n' "$terminal"
    fi
  done
  assert_eq "$ab_rc" "0" "goal-abort: rc 0 when every release succeeded"
  assert_eq "$([ -e "$ab_dir/goal-active-id.txt" ] && printf yes || printf no)" "no" \
    "goal-abort: reaps the fixed-path active-id pointer on success"

  # FAIL-LOUD: a release that gh refuses must be rc 1 AND must keep the
  # run-state, so a re-run can retry instead of losing the record of what is
  # still claimed.
  printf '66\tsolving\t150\n' > "$ab_dir/goal-$AB_GOAL_ID-issue-states.tsv"
  printf '%s\n' "$AB_GOAL_ID" > "$ab_dir/goal-active-id.txt"
  printf 'GOAL_ID=%s\ncycle=1\n' "$AB_GOAL_ID" > "$ab_dir/goal-$AB_GOAL_ID-runstate"
  ab_fail_out="$(GH_CALLS="$ab_dir/calls-fail.txt" PATH="$ab_bin:$PATH" UBERDEV_TMPDIR="$ab_dir" \
    bash "$ABORT_SH" "$AB_GOAL_ID" 2>&1)"
  ab_fail_rc=$?
  assert_eq "$ab_fail_rc" "1" "goal-abort: rc 1 when a release fails (never a silent success)"
  if grep -qF "#66" <<<"$ab_fail_out"; then
    PASS=$((PASS + 1)); printf '  PASS  goal-abort: names the still-claimed issue so it can be released by hand\n'
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort: failure output must name the stranded issue (got: [%s])\n' "$ab_fail_out" >&2
  fi
  assert_eq "$([ -e "$ab_dir/goal-$AB_GOAL_ID-runstate" ] && printf yes || printf no)" "yes" \
    "goal-abort: keeps run-state after a failed release so the sweep can be retried"

  # UNREADABLE / UNPARSEABLE LEDGER: an empty pending-claim scan because awk
  # CRASHED is byte-identical to an empty scan because every issue is terminal.
  # The script has no `pipefail`, so an unchecked scan reported
  # `released=0 … run-state cleaned`, exited 0, released NOTHING and then DELETED
  # both the run-state sidecar and the fixed-path active-id pointer — destroying
  # the only channel a retry could resolve this run through and stranding every
  # `uberdev:active` claim permanently. That is the exact failure this script
  # exists to prevent, so it must take the fail-loud keep-run-state contract.
  #
  # An `awk` shim that exits non-zero reproduces it deterministically on every
  # platform; a chmod-000 ledger does not (no-op as root, ignored on Windows).
  cat > "$ab_bin/awk" <<'AWKSTUB'
#!/usr/bin/env bash
printf 'awk: simulated ledger read failure\n' >&2
exit 2
AWKSTUB
  chmod +x "$ab_bin/awk"
  printf '77\tsolving\t150\n' > "$ab_dir/goal-$AB_GOAL_ID-issue-states.tsv"
  printf '%s\n' "$AB_GOAL_ID" > "$ab_dir/goal-active-id.txt"
  printf 'GOAL_ID=%s\ncycle=1\n' "$AB_GOAL_ID" > "$ab_dir/goal-$AB_GOAL_ID-runstate"
  ab_led_out="$(GH_CALLS="$ab_dir/calls-ledger.txt" PATH="$ab_bin:$PATH" UBERDEV_TMPDIR="$ab_dir" \
    bash "$ABORT_SH" "$AB_GOAL_ID" 2>&1)"
  ab_led_rc=$?
  rm -f "$ab_bin/awk"
  assert_eq "$ab_led_rc" "1" \
    "goal-abort: an unreadable issue-state ledger is rc 1 — never a silent 'nothing to release' success"
  if grep -qF 'FAILED to read the issue-state ledger' <<<"$ab_led_out"; then
    PASS=$((PASS + 1)); printf '  PASS  goal-abort: names the unread ledger on stderr instead of reporting released=0\n'
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  goal-abort: expected an unread-ledger diagnostic (got: [%s])\n' "$ab_led_out" >&2
  fi
  assert_eq "$([ -e "$ab_dir/goal-$AB_GOAL_ID-runstate" ] && printf yes || printf no)" "yes" \
    "goal-abort: KEEPS the run-state when the ledger could not be read (a retry still has something to resolve)"
  assert_eq "$([ -e "$ab_dir/goal-active-id.txt" ] && printf yes || printf no)" "yes" \
    "goal-abort: KEEPS the fixed-path active-id pointer — the only channel a retry can find the run through"
  assert_eq "$([ -e "$ab_dir/calls-ledger.txt" ] && printf yes || printf no)" "no" \
    "goal-abort: attempts no gh mutation at all when the ledger is unread"

  # A path-traversal GOAL_ID must be refused before it indexes any file path.
  PATH="$ab_bin:$PATH" UBERDEV_TMPDIR="$ab_dir" bash "$ABORT_SH" '../pwned' >/dev/null 2>&1
  assert_eq "$?" "2" "goal-abort: refuses a path-traversal GOAL_ID (rc 2)"

  rm -rf "$ab_dir"
fi

# Summary
echo
echo "== Summary =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
