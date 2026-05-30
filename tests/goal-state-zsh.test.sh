#!/usr/bin/env bash
# Dual-shell runtime regression test for issue #270 — bash-only syntax in
# lib/goal-state.sh (and the finish-branch PR-number extraction) misfired under
# the zsh-backed Bash tool (/bin/zsh on macOS), where the goal-pipeline /
# finish-branch SKILL.md bash fences actually execute. CI runs the *.test.sh
# suite under bash, which is exactly why the zsh-only breakage escaped — so this
# fixture is written to run under BOTH bash and zsh:
#
#   bash tests/goal-state-zsh.test.sh   # proves the fix stays bash-safe
#   zsh  tests/goal-state-zsh.test.sh   # catches the zsh-only regressions
#
# It SOURCES lib/goal-state.sh under the live shell (exactly as each /goal phase
# fence does via `. ${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh`) and asserts the
# behaviours named in the #270 Verification section, plus the two structural
# must-dos (print_summary hoist; agent_stuck_on_dialog no `read-only`/`bad
# substitution`). The companion bash coverage lives in goal.test.sh BT2/BT79/G37
# and goal-state-sidecar.test.sh S5; together they lock the bash + zsh story.
#
# Failure-mode demo (revert any one fix and re-run under zsh):
#   - parse_blocks `${match[1]:-${BASH_REMATCH[1]}}` -> `${BASH_REMATCH[1]}`  => Z1 empty
#   - `local agent_status` -> `local status`                                 => Z2 `read-only variable: status`
#   - `_uberdev_goal_indirect_get` `${(P)..}` arm -> `${!..}` always          => Z2/Z4 `bad substitution`
#   - `env|grep` enumeration -> `compgen -v`                                  => Z4 zero samples persisted
#   - print_summary defined in the SKILL.md Phase-4 fence (not the lib)       => Z3 not in scope
#   - finish-branch `${PR_URL##*/}` -> a `[[ =~ ]]` BASH_REMATCH capture      => Z5 empty PR_NUM

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOAL_LIB="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
FINISH_BRANCH="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"

if [ ! -r "$GOAL_LIB" ] || [ ! -r "$DISPATCH_LIB" ] || [ ! -r "$FINISH_BRANCH" ]; then
  echo "FATAL: required file missing/unreadable: $GOAL_LIB / $DISPATCH_LIB / $FINISH_BRANCH" >&2
  exit 2
fi

# Report which shell we are exercising (the whole point: the SAME assertions
# must pass under bash AND zsh).
if [ -n "${ZSH_VERSION:-}" ]; then
  RUN_SHELL="zsh"
else
  RUN_SHELL="bash"
fi
echo "== goal-state-zsh.test.sh — running under: $RUN_SHELL =="

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Source dispatch.sh (goal-state.sh hard-requires _uberdev_dispatch_* symbols)
# then goal-state.sh, exactly as each goal-pipeline phase fence does. A parse
# error under zsh (e.g. a stray bashism at file scope) would abort here.
# shellcheck source=/dev/null
. "$DISPATCH_LIB"
# shellcheck source=/dev/null
. "$GOAL_LIB"

echo
echo "== Z1: _uberdev_goal_parse_blocks_line captures the PR number (BASH_REMATCH vs match) =="
# #270 finding 1: `${BASH_REMATCH[1]}` is empty under zsh (zsh fills `$match[1]`),
# and this is the ONLY `Blocks: #N` parser -> held-PR unblock never fired. The
# dual-shell `${match[1]:-${BASH_REMATCH[1]}}` reads whichever the live shell set.
Z1_OUT="$(_uberdev_goal_parse_blocks_line 'Blocks: #42')"
if [ "$Z1_OUT" = "42" ]; then
  pass "Z1a: parse_blocks 'Blocks: #42' -> 42 under $RUN_SHELL"
else
  fail "Z1a: parse_blocks yielded [$Z1_OUT], expected 42 (BASH_REMATCH empty under zsh?)"
fi
# Negative shapes still reject (the anchored-regex contract is shell-agnostic).
if [ -z "$(_uberdev_goal_parse_blocks_line 'Blocks: 42')" ]; then
  pass "Z1b: 'Blocks: 42' (no #) rejected"
else
  fail "Z1b: 'Blocks: 42' must be rejected (no leading #)"
fi
if [ -z "$(_uberdev_goal_parse_blocks_line ' Blocks: #42')" ]; then
  pass "Z1c: ' Blocks: #42' (leading space) rejected"
else
  fail "Z1c: ' Blocks: #42' must be rejected (leading space breaks the anchor)"
fi

echo
echo "== Z2: uberdev_goal_agent_stuck_on_dialog runs clean (no 'read-only'/'bad substitution') =="
# #270 findings 2 (+ the `local status` zsh special-parameter collision): the
# function aborted non-zero on its FIRST statement under zsh (`local status` =>
# `read-only variable: status`), and later `${!var}` => `bad substitution`, so
# the agent_stuck_on_dialog circuit breaker could NEVER fire. This mirrors
# goal.test.sh BT79 but RUNS UNDER THE LIVE SHELL and inspects stderr.
Z2_TMP="$(mktemp -d)"
(
  GOAL_ID="goal-z2abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  export UBERDEV_TMPDIR="$Z2_TMP"
  printf '%s\n' '{"event":"goal_dispatched"}' > "$UBERDEV_TMPDIR/goal-$GOAL_ID.jsonl"
  # Stub `claude agents --json` (busy) and `date +%s` (mockable clock).
  claude() { printf '%s\n' '[{"pid":12345,"status":"busy"}]'; }
  date() { case "${1:-}" in +%s) printf '%s\n' "${MOCK_NOW:-1729000000}";; *) command date "$@";; esac; }
  # First sample -> baseline persisted, rc=1 (not-yet-stuck).
  err1="$( { MOCK_NOW=1729000000 uberdev_goal_agent_stuck_on_dialog 12345; } 2>&1 1>/dev/null )"
  rc1=$?
  # Second sample 65s later, same audit row-count, still busy -> rc=0 (stuck).
  err2="$( { MOCK_NOW=1729000065 uberdev_goal_agent_stuck_on_dialog 12345; } 2>&1 1>/dev/null )"
  rc2=$?
  printf 'rc1=%s rc2=%s err1=[%s] err2=[%s]\n' "$rc1" "$rc2" "$err1" "$err2"
) > "$Z2_TMP/out.txt" 2>&1
Z2_LINE="$(cat "$Z2_TMP/out.txt")"
# Stderr must be free of the two zsh-runtime failure signatures on BOTH samples.
if printf '%s' "$Z2_LINE" | grep -qiE 'bad substitution|read-only variable'; then
  fail "Z2a: agent_stuck_on_dialog leaked a zsh-runtime error to stderr ($Z2_LINE)"
else
  pass "Z2a: agent_stuck_on_dialog ran clean — no 'bad substitution' / 'read-only variable' ($RUN_SHELL)"
fi
# Note: the rc1=1 -> rc2=0 state-machine transition is asserted in Z4 (where the
# two calls run in the SAME shell so the printf -v/export baseline survives —
# here Z2 runs each call in a `$(...)` stderr-capture subshell, which by design
# isolates the baseline, so we assert only the no-error contract here).

echo
echo "== Z3: print_summary is HOISTED into lib/goal-state.sh and in scope after sourcing =="
# #270 finding 3 + structural must-do (1): print_summary was DEFINED only in the
# Phase-4 bash fence but CALLED from Phase 1/2/3 fences. A shell function does not
# cross a fence boundary, so every non-Phase-4 exit hit `command not found`
# (rc 127). Hoisting it into goal-state.sh (re-sourced at every fence top) brings
# it into scope in every phase. Sourcing happened above; assert it is callable.
if command -v print_summary >/dev/null 2>&1; then
  pass "Z3a: print_summary is in scope after sourcing goal-state.sh (hoist succeeded)"
else
  fail "Z3a: print_summary NOT in scope — still stranded in the SKILL.md Phase-4 fence?"
fi
# It must also be ABSENT as a function definition from the goal-pipeline SKILL.md
# (the def was removed from the Phase-4 fence; only call sites remain).
GOAL_SKILL="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"
if grep -qE '^print_summary\(\)' "$GOAL_SKILL"; then
  fail "Z3b: print_summary() is still DEFINED in goal-pipeline/SKILL.md — the hoist must remove the inline def (it cannot cross a fence)"
else
  pass "Z3b: no print_summary() definition remains in goal-pipeline/SKILL.md (def lives in the lib)"
fi
# And it must be DEFINED exactly once in the lib.
if grep -qE '^print_summary\(\)' "$GOAL_LIB"; then
  pass "Z3c: print_summary() is defined in lib/goal-state.sh"
else
  fail "Z3c: print_summary() must be defined in lib/goal-state.sh"
fi
# End-to-end: a fresh shell that sources the lib and rehydrates the summary
# scalars can run print_summary and get the mandated one-line summary on stdout.
Z3_TMP="$(mktemp -d)"
Z3_OUT="$(
  GOAL_ID="goal-z3abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  export UBERDEV_TMPDIR="$Z3_TMP"
  MAX_CYCLES=8
  watch_start=1729000000
  date() { case "${1:-}" in +%s) printf '%s\n' 1729003600;; *) command date "$@";; esac; }
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  print_summary 3 2>&1
)"
if printf '%s' "$Z3_OUT" | grep -qE '^goal goal-z3abcd01: cycles=3/8 prs_merged=0 prs_held=0 issues_resolved=0 wall_secs=3600$'; then
  pass "Z3d: print_summary emits the mandated operator summary line under $RUN_SHELL"
else
  fail "Z3d: print_summary summary line malformed/missing (got: [$Z3_OUT])"
fi

echo
echo "== Z4: write_run_state enumerates + persists per-PID stuck samples (compgen vs env) =="
# #270 finding 4: `compgen -v PREFIX` (a bash builtin) returns NOTHING under zsh,
# so the per-PID PRIOR_LAST_ACTIVITY_/FIRST_DIALOG_TS_ samples were never written
# to the run-state sidecar across fences (compounding the dead detector). The
# replacement enumerates via `env` (portable) + a dual-shell indirect read. This
# runs the detector twice IN THE SAME SHELL (baseline survives) and asserts the
# rc1=1 -> rc2=0 transition AND that write_run_state round-trips the samples.
Z4_TMP="$(mktemp -d)"
Z4_OUT="$(
  GOAL_ID="goal-z4abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  export UBERDEV_TMPDIR="$Z4_TMP"
  MAX_CYCLES=8; watch_start=1729000000; cycle=1
  declare -a queue active_issues 2>/dev/null || true
  queue=(); active_issues=()
  claude() { printf '%s\n' '[{"pid":12345,"status":"busy"}]'; }
  date() { case "${1:-}" in +%s) printf '%s\n' "${MOCK_NOW:-1729000000}";; *) command date "$@";; esac; }
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  MOCK_NOW=1729000000 uberdev_goal_agent_stuck_on_dialog 12345; rc1=$?
  MOCK_NOW=1729000065 uberdev_goal_agent_stuck_on_dialog 12345; rc2=$?
  # Persist run-state: the env-based enumeration must find the exported
  # PRIOR_LAST_ACTIVITY_12345 / FIRST_DIALOG_TS_12345 keys and write them.
  uberdev_goal_write_run_state >/dev/null 2>&1
  sc="$UBERDEV_TMPDIR/goal-$GOAL_ID-runstate"
  prior_persisted=0; first_persisted=0
  grep -qE '^PRIOR_LAST_ACTIVITY_12345=' "$sc" 2>/dev/null && prior_persisted=1
  grep -qE '^FIRST_DIALOG_TS_12345='     "$sc" 2>/dev/null && first_persisted=1
  printf 'rc1=%s rc2=%s prior=%s first=%s\n' "$rc1" "$rc2" "$prior_persisted" "$first_persisted"
)"
case "$Z4_OUT" in
  *"rc1=1 rc2=0"*)
    pass "Z4a: stuck-detector state machine fires under $RUN_SHELL (first sample not-stuck -> 65s-later stuck)" ;;
  *)
    fail "Z4a: stuck-detector did not transition rc1=1 -> rc2=0 (got: [$Z4_OUT])" ;;
esac
case "$Z4_OUT" in
  *"prior=1 first=1"*)
    pass "Z4b: write_run_state persisted both per-PID samples via env-enumeration (compgen-free) under $RUN_SHELL" ;;
  *)
    fail "Z4b: write_run_state dropped the per-PID samples — compgen-under-zsh regression? (got: [$Z4_OUT])" ;;
esac

echo
echo "== Z5: finish-branch PR-number extraction yields a non-empty value (no BASH_REMATCH) =="
# #270 finding 5: finish-branch used `${BASH_REMATCH[1]}` to pull the PR number
# from PR_URL -> empty under zsh -> `gh pr edit "" --add-label review-pr:pending`
# failed (swallowed) and the #95 backstop label was never set on macOS. The fix
# sidesteps the regex entirely: `PR_NUM="${PR_URL##*/}"` on the already-validated
# URL. Z5a runs that exact expansion under the live shell; Z5b/Z5c guard the
# SKILL.md against a relapse to a capture-group match.
Z5_PR_URL="https://github.com/owner/repo/pull/12345"
Z5_PR_NUM="${Z5_PR_URL##*/}"
if [ -n "$Z5_PR_NUM" ] && [ "$Z5_PR_NUM" = "12345" ]; then
  pass "Z5a: \${PR_URL##*/} extracts '12345' (non-empty) under $RUN_SHELL"
else
  fail "Z5a: PR-number extraction yielded [$Z5_PR_NUM], expected non-empty 12345"
fi
# Structural: finish-branch must use the parameter-expansion form, NOT a
# BASH_REMATCH capture, for the PR-number extraction.
if grep -qE 'PR_NUM="\$\{PR_URL##\*/\}"' "$FINISH_BRANCH"; then
  pass "Z5b: finish-branch uses PR_NUM=\${PR_URL##*/} (regex-free, dual-shell-safe)"
else
  fail "Z5b: finish-branch must extract PR_NUM via \${PR_URL##*/} (the dual-shell-safe form)"
fi
if grep -qE 'PR_NUM="\$\{BASH_REMATCH\[1\]\}"' "$FINISH_BRANCH"; then
  fail "Z5c: finish-branch still pulls PR_NUM from \${BASH_REMATCH[1]} — empty under zsh, defeats the #95 backstop"
else
  pass "Z5c: no \${BASH_REMATCH[1]} PR-number extraction remains in finish-branch"
fi

echo
echo "== Z6: batch_unblock_wait_clear — ALL Blocks closed + uberdev-approved gate (#289.1/#289.3) =="
# Runs the barrier unblock-wait predicate UNDER THE LIVE SHELL. The lib uses
# indexed arrays + a per-blocker loop internally; this proves the #289 fix holds
# in BOTH bash and zsh (the rc1-forever phantom-label deadlock + the
# break-after-first-Blocks bug both surfaced from cross-shell-fragile code).
Z6_TMP="$(mktemp -d)"
Z6_OUT="$(
  GOAL_ID="goal-z6abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID" UBERDEV_TMPDIR="$Z6_TMP"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null 2>&1
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD >/dev/null 2>&1
  # Two Blocks; only one closed → must GATE (rc1).
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in (*body*) printf 'Blocks: #201\nBlocks: #202';; (*labels*) printf '0';; esac ;;
      "issue view") case "$3" in (201) printf 'CLOSED';; (202) printf 'OPEN';; esac ;;
    esac
  }
  uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" >/dev/null 2>&1 && r_partial=0 || r_partial=1
  # Both closed, no uberdev-approved → pseudo-terminal, must CLEAR (rc0).
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in (*body*) printf 'Blocks: #201\nBlocks: #202';; (*labels*) printf '0';; esac ;;
      "issue view") printf 'CLOSED' ;;
    esac
  }
  uberdev_goal_batch_unblock_wait_clear "$GOAL_ID" >/dev/null 2>&1 && r_allclosed=0 || r_allclosed=1
  printf 'partial=%s allclosed=%s\n' "$r_partial" "$r_allclosed"
)"
case "$Z6_OUT" in
  *"partial=1 allclosed=0"*)
    pass "Z6a: unblock-wait gates on one-of-two-open, clears (pseudo-terminal) on all-closed under $RUN_SHELL" ;;
  *)
    fail "Z6a: unblock-wait wrong (#289 — got: [$Z6_OUT]; expect partial=1 allclosed=0)" ;;
esac
# Structural: the live label gate reads uberdev-approved, NOT review-pr:green.
if grep -qE 'select\(\. == "uberdev-approved"\)' "$GOAL_LIB"; then
  pass "Z6b: unblock-wait label gate reads uberdev-approved (the producer label)"
else
  fail "Z6b: unblock-wait must read uberdev-approved (review-pr writes that, not review-pr:green)"
fi
if grep -qE 'select\(\. == "review-pr:green"\)' "$GOAL_LIB"; then
  fail "Z6c: a LIVE jq gate on the phantom review-pr:green label still remains (rc1-forever bug)"
else
  pass "Z6c: no live jq gate on the phantom review-pr:green label remains"
fi
rm -rf "$Z6_TMP" 2>/dev/null || true

echo
echo "== Z7: read_trust_signal SHA-binding under the live shell (#290.1) =="
Z7_TMP="$(mktemp -d)"
Z7_OUT="$(
  export UBERDEV_TMPDIR="$Z7_TMP"
  vf="$Z7_TMP/verdict.json"
  printf '%s\n' '{"pr":42,"sha":"abc123","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}' > "$vf"
  gh() { case "$1 $2" in ("pr view") printf 'abc123';; esac; }
  m="$(uberdev_goal_read_trust_signal "$vf" 2>/dev/null)"
  gh() { case "$1 $2" in ("pr view") printf 'def456';; esac; }
  s="$(uberdev_goal_read_trust_signal "$vf" 2>/dev/null)"
  gh() { return 1; }
  f="$(uberdev_goal_read_trust_signal "$vf" 2>/dev/null)"
  printf 'match=%s mismatch=%s failsafe=%s\n' "$m" "$s" "$f"
)"
case "$Z7_OUT" in
  *"match=green mismatch=stale failsafe=green"*)
    pass "Z7a: SHA-binding green/stale/fail-safe correct under $RUN_SHELL" ;;
  *)
    fail "Z7a: SHA-binding wrong (#290.1 — got: [$Z7_OUT]; expect match=green mismatch=stale failsafe=green)" ;;
esac
rm -rf "$Z7_TMP" 2>/dev/null || true

echo
echo "== Z8: detect_blocks_cycle finds a mutual Blocks cycle under the live shell (#292.1) =="
# The SCC detector uses indexed arrays + a reachability-closure fixpoint (NO
# associative arrays — those diverge between bash and zsh). This proves it works
# in both shells.
Z8_TMP="$(mktemp -d)"
Z8_OUT="$(
  GOAL_ID="goal-z8abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID" UBERDEV_TMPDIR="$Z8_TMP"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  uberdev_goal_register_batch_pr "$GOAL_ID" 100 200 >/dev/null 2>&1
  uberdev_goal_register_batch_pr "$GOAL_ID" 101 201 >/dev/null 2>&1
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 100 HELD >/dev/null 2>&1
  _uberdev_goal_set_batch_terminal_state "$GOAL_ID" 101 HELD >/dev/null 2>&1
  gh() {
    case "$1 $2" in
      "pr view") case "$*" in (*body*) case "$3" in (100) printf 'Blocks: #201';; (101) printf 'Blocks: #200';; esac ;; esac ;;
      "pr list")
        jqf='.'; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jqf="$2"; shift; done
        printf '%s' '[{"number":100,"closingIssuesReferences":[{"number":200}],"headRefName":"feat/200-a"},{"number":101,"closingIssuesReferences":[{"number":201}],"headRefName":"feat/201-b"}]' | jq -r "$jqf" ;;
    esac
  }
  cyc="$(uberdev_goal_detect_blocks_cycle "$GOAL_ID" 2>/dev/null)" && rc=0 || rc=1
  printf 'rc=%s cyc=[%s]\n' "$rc" "$cyc"
)"
case "$Z8_OUT" in
  *"rc=0"*100*101*|*"rc=0"*101*100*)
    pass "Z8a: detect_blocks_cycle fires on the mutual A↔B cycle under $RUN_SHELL (got: $Z8_OUT)" ;;
  *)
    fail "Z8a: detect_blocks_cycle missed the mutual cycle (#292.1 — got: [$Z8_OUT])" ;;
esac
rm -rf "$Z8_TMP" 2>/dev/null || true

echo
echo "== Z9: reset_merge_attempts re-allows should_automerge under the live shell (#292.2) =="
Z9_TMP="$(mktemp -d)"
Z9_OUT="$(
  GOAL_ID="goal-z9abcd01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID" UBERDEV_TMPDIR="$Z9_TMP"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  printf '%s\t%s\n' 100 3 > "$Z9_TMP/goal-$GOAL_ID-merge-attempts.tsv"
  uberdev_goal_should_automerge "$GOAL_ID" 100 && pre=allow || pre=refuse
  uberdev_goal_reset_merge_attempts "$GOAL_ID" 100 >/dev/null 2>&1
  cnt="$(_uberdev_goal_count_merge_attempts "$GOAL_ID" 100)"
  uberdev_goal_should_automerge "$GOAL_ID" 100 && post=allow || post=refuse
  printf 'pre=%s cnt=%s post=%s\n' "$pre" "$cnt" "$post"
)"
case "$Z9_OUT" in
  *"pre=refuse cnt=0 post=allow"*)
    pass "Z9a: merge-attempt cap resets on recovery (refuse@cap → reset → allow) under $RUN_SHELL" ;;
  *)
    fail "Z9a: reset_merge_attempts wrong (#292.2 — got: [$Z9_OUT]; expect pre=refuse cnt=0 post=allow)" ;;
esac
rm -rf "$Z9_TMP" 2>/dev/null || true

echo
echo "== Z10: verdict-locator + peer enumerators do NOT fatal on ZERO matches under zsh (#299 finding 1) =="
# #299 finding 1: the Phase-2 watch loop's verdict locator
# (uberdev_goal_locate_review_pr_audit_by_pr) and peer enumerators iterate the
# worktree-prefix globs via _uberdev_goal_glob_worktree. Under zsh a BARE
# unmatched glob FATALS (`no matches found`) — proven below — so any enumerator
# that expanded an unmatched glob WITHOUT the helper's `setopt localoptions
# nonomatch` + `${~pat}` guard would abort the whole watch fence. The issue
# reporter hit exactly this at uberdev 0.35.19. This locks the fix: every
# glob-iterating enumerator must return cleanly (rc 0, empty) on zero matches —
# NEVER fatal — even when run from a directory where NO .uberdev/runs/* exists.
#
# Mutation guard: revert _uberdev_goal_glob_worktree's zsh arm (`setopt
# localoptions nonomatch` removed, or `${~pat}` -> bare `$pat` with the loop
# expanding the literal directly) => Z10 goes RED with a leaked `no matches
# found` fatal.
Z10_TMP="$(mktemp -d)"
Z10_OUT="$(
  GOAL_ID="goal-z10abc01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID" UBERDEV_TMPDIR="$Z10_TMP"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  # cd to an EMPTY checkout: every worktree-mirror glob is UNMATCHED here, which
  # is the exact zero-verdict state at the start of a /goal watch pass. A bare
  # unmatched glob would FATAL here under zsh (`no matches found`); the
  # helper-routed enumerators below must NOT.
  cd "$Z10_TMP" || exit 9
  # Stub gh so uberdev_goal_locate_review_pr_audit (issue->PR path) and the
  # read_merge_result tier-1 gh probe never hit the network; both still drive the
  # unmatched-glob enumeration internally.
  gh() { return 1; }
  errfile="$Z10_TMP/err.txt"
  : > "$errfile"
  for spec in \
    "uberdev_goal_locate_review_pr_audit_by_pr 200" \
    "uberdev_goal_list_prs_in_state $GOAL_ID pushed-reviewing" \
    "uberdev_goal_read_merge_result 200" \
    "_uberdev_goal_locked_marker_for_pr_fresh 200 3600" \
    "uberdev_goal_locate_review_pr_audit 200"; do
    out="$(eval "$spec" 2>>"$errfile")"
    # A non-zero rc here is acceptable for the locked-marker probe (rc 1 = "no
    # fresh marker") and the locators (empty = no verdict); the FATAL we guard
    # against is the zsh `no matches found` abort, asserted on stderr below. A
    # non-empty stdout would mean a stray match leaked from the empty checkout.
    [ -n "$out" ] && printf 'UNEXPECTED-OUTPUT[%s]=%s\n' "$spec" "$out"
  done
  if grep -qi 'no matches found' "$errfile"; then
    printf 'NOMATCH-FATAL=[%s]\n' "$(tr -d '\n' < "$errfile")"
  else
    printf 'CLEAN\n'
  fi
)"
if printf '%s' "$Z10_OUT" | grep -q 'CLEAN' \
   && ! printf '%s' "$Z10_OUT" | grep -qi 'no matches found'; then
  pass "Z10a: all glob-iterating enumerators return cleanly on zero matches under $RUN_SHELL — no 'no matches found' fatal (#299 finding 1)"
else
  fail "Z10a: an enumerator FATALED on zero matches under $RUN_SHELL (got: [$Z10_OUT]) — verdict-locator glob regression (#299 finding 1)"
fi
rm -rf "$Z10_TMP" 2>/dev/null || true

echo
echo "== Z11: bounded-watch bound (WATCH_PASSES/WATCH_BUDGET) round-trips run-state under zsh (#299 finding 2) =="
# #299 finding 2: the Phase-2 watch loop honours a BOUNDED bound so an
# orchestrating harness can drive it tick-by-tick. WATCH_PASSES / WATCH_BUDGET
# are persisted by uberdev_goal_write_run_state and rehydrated + EXPORTed by
# uberdev_goal_read_run_state across the fresh-shell Phase-2 fences (exactly like
# REVIEW_GRACE_SECS / MAX_PARALLEL). This proves the persistence SSOT carries the
# bound in BOTH shells — if it did not, a bounded tick that re-invokes a fresh
# Phase-2 fence would silently lose the bound and revert to the unbounded loop.
Z11_TMP="$(mktemp -d)"
Z11_OUT="$(
  GOAL_ID="goal-z11abc01"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID" UBERDEV_TMPDIR="$Z11_TMP"
  cycle=1; watch_start=1729000000; MAX_CYCLES=5
  WATCH_PASSES=3; WATCH_BUDGET=540
  queue=(); active_issues=()
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  uberdev_goal_write_run_state >/dev/null 2>&1
  # Fresh shell #2: clear the bound scalars, then rehydrate from the sidecar
  # (the active-id pointer bootstraps GOAL_ID, mirroring a fresh Phase-2 fence).
  unset WATCH_PASSES WATCH_BUDGET GOAL_ID UBERDEV_GOAL_ID
  uberdev_goal_read_run_state >/dev/null 2>&1
  printf 'passes=%s budget=%s exported_passes=%s\n' \
    "${WATCH_PASSES:-UNSET}" "${WATCH_BUDGET:-UNSET}" \
    "$(env | grep -c '^WATCH_PASSES=3$')"
)"
case "$Z11_OUT" in
  *"passes=3 budget=540 exported_passes=1"*)
    pass "Z11a: WATCH_PASSES/WATCH_BUDGET persist + rehydrate + export across a fresh shell under $RUN_SHELL (#299 finding 2)" ;;
  *)
    fail "Z11a: bounded-watch bound did NOT round-trip run-state (got: [$Z11_OUT]; expect passes=3 budget=540 exported_passes=1)" ;;
esac
rm -rf "$Z11_TMP" 2>/dev/null || true
# Structural: the Phase-2 watch loop in SKILL.md must carry the bounded-tick
# contract (exit 42 still-active + exit 0 drained + the no-reaper-on-pause
# guarantee). These are the load-bearing exit codes the harness drives on.
if grep -q 'bounded-tick exit 42' "$GOAL_SKILL"; then
  pass "Z11b: Phase-2 watch loop emits the documented 'still-active, re-invoke' exit 42 (#299 finding 2)"
else
  fail "Z11b: Phase-2 watch loop must exit 42 on a bounded tick with work in flight (#299 finding 2)"
fi
if grep -q 'bounded-tick exit 0' "$GOAL_SKILL"; then
  pass "Z11c: Phase-2 watch loop emits the documented 'drained -> Phase 3' exit 0 in bounded mode (#299 finding 2)"
else
  fail "Z11c: Phase-2 watch loop must exit 0 on a bounded-mode drain (#299 finding 2)"
fi

echo
echo "== Z12: GOAL_ID generation yields a SINGLE goal- sidecar prefix (#299 finding 3) =="
# #299 finding 3: every per-goal sidecar path is formatted `goal-$GOAL_ID-…` in
# lib/goal-state.sh (~49 sites). A GOAL_ID that itself began with `goal-`
# produced `goal-goal-…` files on disk — a debugging foot-gun (the obvious
# `"$TMPDIR"/goal-<id>-*` search matched nothing). The fix generates the id
# WITHOUT the leading `goal-`, so files are single-`goal-`-prefixed. This runs
# the EXACT production generator from SKILL.md Phase-0 step 5 under the live
# shell, inits state, and asserts: (1) no `goal-goal-` file exists, (2) the
# `goal-<id>-*` glob now MATCHES (foot-gun resolved), (3) the id passes
# _uberdev_goal_validate_id, (4) the sidecar mis-pathing guard cannot trip.
# Mutation guard: revert the SKILL.md generator to `GOAL_ID="goal-$(date …)…"`
# => Z12 RED (a goal-goal- file appears + the structural assert below fails).
Z12_TMP="$(mktemp -d)"
Z12_OUT="$(
  export UBERDEV_TMPDIR="$Z12_TMP"
  # Verbatim production generator (SKILL.md Phase-0 step 5, post-#299-finding-3).
  GOAL_ID="$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  cycle=1; watch_start="$(date +%s)"; MAX_CYCLES=5; queue=(); active_issues=()
  uberdev_goal_write_run_state >/dev/null 2>&1
  dbl="$(ls "$Z12_TMP" 2>/dev/null | grep -c 'goal-goal-')"
  single="$(ls "$Z12_TMP"/goal-"$GOAL_ID"-runstate 2>/dev/null | grep -c .)"
  vid=0; _uberdev_goal_validate_id "$GOAL_ID" && vid=1
  guard=safe; case "$GOAL_ID" in goal--*) guard=trips ;; esac
  printf 'doubled=%s single=%s vid=%s guard=%s\n' "$dbl" "$single" "$vid" "$guard"
)"
case "$Z12_OUT" in
  *"doubled=0 single=1 vid=1 guard=safe"*)
    pass "Z12a: production GOAL_ID gen yields single-goal--prefixed sidecars (no goal-goal-), id valid, guard safe under $RUN_SHELL (#299 finding 3)" ;;
  *)
    fail "Z12a: GOAL_ID prefix wrong (#299 finding 3 — got: [$Z12_OUT]; expect doubled=0 single=1 vid=1 guard=safe)" ;;
esac
rm -rf "$Z12_TMP" 2>/dev/null || true
# Structural: the SKILL.md generator must NOT emit a `goal-`-prefixed id.
if grep -qE 'GOAL_ID="goal-\$\(date' "$GOAL_SKILL"; then
  fail "Z12b: SKILL.md still generates a goal--prefixed GOAL_ID (produces goal-goal-… sidecars) — #299 finding 3 regression"
else
  pass "Z12b: SKILL.md GOAL_ID generator no longer carries a leading goal- prefix (#299 finding 3)"
fi
if grep -qE 'GOAL_ID="\$\(date \+%s\)-\$\(mktemp' "$GOAL_SKILL"; then
  pass "Z12c: SKILL.md GOAL_ID generator uses the prefix-free \$(date)-\$(mktemp) form (#299 finding 3)"
else
  fail "Z12c: SKILL.md GOAL_ID generator must be the prefix-free \$(date +%s)-\$(mktemp …) form (#299 finding 3)"
fi

# Cleanup
rm -rf "$Z2_TMP" "$Z3_TMP" "$Z4_TMP" 2>/dev/null || true

echo
echo "== Summary =="
echo "  shell:  $RUN_SHELL"
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
