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

# Cleanup
rm -rf "$Z2_TMP" "$Z3_TMP" "$Z4_TMP" 2>/dev/null || true

echo
echo "== Summary =="
echo "  shell:  $RUN_SHELL"
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
