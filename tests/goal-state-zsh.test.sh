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

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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
if grep -qiE 'bad substitution|read-only variable' <<<"$Z2_LINE"; then
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
# RFC 0015 §5 — the executable /goal body moved out of the SKILL.md fences
# into these scripts. Structural asserts below follow the code to its new home.
GOAL_P0="$REPO_ROOT/plugins/uberdev/lib/goal-phase0.sh"
GOAL_WATCH="$REPO_ROOT/plugins/uberdev/lib/goal-watch.sh"
for _f in "$GOAL_P0" "$GOAL_WATCH"; do
  [ -r "$_f" ] || { printf 'FATAL: required file missing or unreadable: %s\n' "$_f" >&2; exit 2; }
done
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
if grep -qE '^goal goal-z3abcd01: cycles=3/8 prs_merged=0 prs_held=0 issues_resolved=0 prs_partial=0 wall_secs=3600$' <<<"$Z3_OUT"; then
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
# #345 finding 2 — the fixtures below carry REAL lowercase 40-hex object names.
# They used to be `abc123`, which pinned this path loose: a 6-char string can
# never equal a 40-char head, so the "mismatch" leg passed for the wrong reason
# and the "match" leg only worked because the stub echoed the same 6 chars back.
# With true object names the assertion exercises the shape the producer actually
# writes, and the new `.sha` shape gate stays silent on them (asserted below).
Z7_SHA='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'
Z7_SHA_OTHER='0f1e2d3c4b5a6978869504132435465768798a0b'
Z7_TMP="$(mktemp -d)"
Z7_OUT="$(
  export UBERDEV_TMPDIR="$Z7_TMP"
  vf="$Z7_TMP/verdict.json"
  printf '{"pr":42,"sha":"%s","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}\n' \
    "$Z7_SHA" > "$vf"
  gh() { case "$1 $2" in ("pr view") printf '%s' "$Z7_SHA";; esac; }
  m="$(uberdev_goal_read_trust_signal "$vf" 2>/dev/null)"
  gh() { case "$1 $2" in ("pr view") printf '%s' "$Z7_SHA_OTHER";; esac; }
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

# #345 finding 2 — the shape gate itself, under the LIVE shell. It is written
# with a length probe plus a `case` glob precisely because this file also runs
# under zsh, where a `[[ =~ ]]` capture would silently misbehave.
Z7B_TMP="$(mktemp -d)"
Z7B_OUT="$(
  export UBERDEV_TMPDIR="$Z7B_TMP"
  bad="$Z7B_TMP/short.json"
  good="$Z7B_TMP/good.json"
  printf '{"pr":42,"sha":"abc123","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}\n' > "$bad"
  printf '{"pr":42,"sha":"%s","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}\n' \
    "$Z7_SHA" > "$good"
  gh() { case "$1 $2" in ("pr view") printf '%s' "$Z7_SHA";; esac; }
  bad_err="$(uberdev_goal_read_trust_signal "$bad" 2>&1 >/dev/null)"
  bad_sig="$(uberdev_goal_read_trust_signal "$bad" 2>/dev/null)"
  good_err="$(uberdev_goal_read_trust_signal "$good" 2>&1 >/dev/null)"
  warned=no; quiet=no
  grep -q 'malformed .sha anchor' <<<"$bad_err" && warned=yes
  grep -q 'malformed .sha anchor' <<<"$good_err" || quiet=yes
  printf 'warned=%s quiet=%s sig=%s\n' "$warned" "$quiet" "$bad_sig"
)"
case "$Z7B_OUT" in
  *"warned=yes quiet=yes sig=stale"*)
    pass "Z7b: malformed .sha is diagnosed and still fails closed to stale under $RUN_SHELL (#345)" ;;
  *)
    fail "Z7b: .sha shape gate wrong (#345 — got: [$Z7B_OUT]; expect warned=yes quiet=yes sig=stale)" ;;
esac
rm -rf "$Z7B_TMP" 2>/dev/null || true
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
# Coverage note: Z10 exercises the ZERO-match path (the locator must not fatal).
# The complementary POSITIVE-match path — the locator FINDING a worktree-mirror
# verdict under zsh and the watch loop transitioning pushed-reviewing -> green —
# is covered by goal-pipeline-zsh.test.sh `W` (it seeds a verdict in a worktree
# mirror and runs the sliced step-2b loop). Together they lock both glob arms.
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
if grep -q 'CLEAN' <<<"$Z10_OUT" \
   && ! grep -qi 'no matches found' <<<"$Z10_OUT"; then
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
# Structural: the watch loop must carry the bounded-tick contract (exit 42
# still-active + exit 0 drained + the no-reaper-on-pause guarantee). These are
# the load-bearing exit codes the driver in skills/goal-pipeline/workflow.js
# branches on. RFC 0015 §5 moved the loop out of the SKILL.md fence into
# lib/goal-watch.sh; the contract is unchanged, so the asserts follow the code.
if grep -q 'bounded-tick exit 42' "$GOAL_WATCH"; then
  pass "Z11b: the watch loop emits the documented 'still-active, re-invoke' exit 42 (#299 finding 2)"
else
  fail "Z11b: the watch loop must exit 42 on a bounded tick with work in flight (#299 finding 2)"
fi
if grep -q 'bounded-tick exit 0' "$GOAL_WATCH"; then
  pass "Z11c: the watch loop emits the documented 'drained -> collect' exit 0 in bounded mode (#299 finding 2)"
else
  fail "Z11c: the watch loop must exit 0 on a bounded-mode drain (#299 finding 2)"
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
# Mutation guard: revert the lib/goal-phase0.sh generator to `GOAL_ID="goal-$(date …)…"`
# => Z12 RED (a goal-goal- file appears + the structural assert below fails).
Z12_TMP="$(mktemp -d)"
Z12_OUT="$(
  export UBERDEV_TMPDIR="$Z12_TMP"
  # Verbatim production generator (lib/goal-phase0.sh, post-#299-finding-3).
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
# Structural: the preflight generator must NOT emit a `goal-`-prefixed id.
if grep -qE 'GOAL_ID="goal-\$\(date' "$GOAL_P0"; then
  fail "Z12b: lib/goal-phase0.sh still generates a goal--prefixed GOAL_ID (produces goal-goal-… sidecars) — #299 finding 3 regression"
else
  pass "Z12b: the GOAL_ID generator no longer carries a leading goal- prefix (#299 finding 3)"
fi
if grep -qE 'GOAL_ID="\$\(date \+%s\)-\$\(mktemp' "$GOAL_P0"; then
  pass "Z12c: lib/goal-phase0.sh uses the prefix-free \$(date)-\$(mktemp) GOAL_ID form (#299 finding 3)"
else
  fail "Z12c: lib/goal-phase0.sh must use the prefix-free \$(date +%s)-\$(mktemp …) GOAL_ID form (#299 finding 3)"
fi

echo
echo "== Z13: sourced-file resolver loads discover.sh from an unrelated cwd =="
Z13_TMP="$(mktemp -d)"
if [ "$RUN_SHELL" = zsh ]; then
  Z13_SHELL="$(command -v zsh)"
else
  Z13_SHELL="$(command -v bash)"
fi
Z13_OUT="$(
  cd "$Z13_TMP" || exit 2
  "$Z13_SHELL" -c '
    set -u
    unset _UBERDEV_GOAL_STATE_LOADED _UBERDEV_MERGE_DISCOVER_LOADED
    . "$1"
    command -v discover_review_verdict_json
  ' _ "$GOAL_LIB" 2>&1
)"
Z13_RC=$?
if [ "$Z13_RC" -eq 0 ] && grep -q 'discover_review_verdict_json' <<<"$Z13_OUT"; then
  pass "Z13: $RUN_SHELL resolves goal-state.sh via BASH_SOURCE/%x outside the repository cwd"
else
  fail "Z13: $RUN_SHELL failed to load sibling discover.sh from unrelated cwd (rc=$Z13_RC out=[$Z13_OUT])"
fi
rm -rf "$Z13_TMP"

echo
echo "== Z14: closed-receipt colour matrix under the live shell (#347) =="
# The zsh mirror of tests/goal-verdict-receipt.test.sh section A. The colour
# decision is reached through a jq gate, a TSV `read` split on a literal tab and
# an arithmetic comparison — all three have bitten this project across shells
# (`local status` being read-only under zsh took out a whole circuit breaker in
# #270). Locking the matrix in BOTH shells is what stops a colour decision from
# silently differing between the CI runner and the Bash tool's /bin/zsh.
Z14_SHA='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'
Z14_SHA_OTHER='0f1e2d3c4b5a6978869504132435465768798a0b'
Z14_TMP="$(mktemp -d)"
Z14_OUT="$(
  export UBERDEV_TMPDIR="$Z14_TMP"
  cd "$Z14_TMP" || exit 2
  mkdir -p .uberdev/runs/20260401-101112-deadbeef
  mint() {
    # #440 — a `current` audit names BOTH endpoints of the reviewed delta.
    printf '{"pr":%s,"sha":"%s","base":{"sha":"dddddddddddddddddddddddddddddddddddddddd","ref":"main"},"phases":{"phase2_5":{"by_severity":{"blocker":%s,"critical":%s},"halted":%s}}}\n' \
      "$1" "$Z14_SHA" "$2" "$3" "$4" > .uberdev/runs/20260401-101112-deadbeef/review-pr-verdict.json
    uberdev_goal_locate_review_pr_audit_by_pr "$1" 2>/dev/null
  }
  r_green="$(mint 5101 0 0 false)"
  r_yellow="$(mint 5102 0 2 false)"
  r_red="$(mint 5103 1 0 false)"
  gh() { case "$1 $2" in ("pr view") printf '%s\n' "$Z14_SHA";; esac; }
  g="$(uberdev_goal_read_trust_signal "$r_green" 2>/dev/null)"
  y="$(uberdev_goal_read_trust_signal "$r_yellow" 2>/dev/null)"
  r="$(uberdev_goal_read_trust_signal "$r_red" 2>/dev/null)"
  gh() { case "$1 $2" in ("pr view") printf '%s\n' "$Z14_SHA_OTHER";; esac; }
  st="$(uberdev_goal_read_trust_signal "$r_green" 2>/dev/null)"
  gh() { case "$1 $2" in ("pr view") printf '%s\n' "$Z14_SHA";; esac; }
  # A receipt whose closed shape is violated must be `missing`, never a colour.
  bad="$(printf '%s' "$r_green" | sed 's/"audit_state":"current"/"audit_state":"malformed"/')"
  m="$(uberdev_goal_read_trust_signal "$bad" 2>/dev/null)"
  legacy="$(printf '%s' "$r_green" | sed 's/"audit_state":"current"/"audit_state":"legacy"/')"
  l="$(uberdev_goal_read_trust_signal "$legacy" 2>/dev/null)"
  printf 'g=%s y=%s r=%s stale=%s missing=%s legacy=%s\n' "$g" "$y" "$r" "$st" "$m" "$l"
)"
case "$Z14_OUT" in
  *"g=green y=yellow r=red stale=stale missing=missing legacy=stale"*)
    pass "Z14a: receipt colour matrix (green/yellow/red + SHA-stale + shape-missing + legacy-stale) correct under $RUN_SHELL (#347)" ;;
  *)
    fail "Z14a: receipt colour matrix wrong under $RUN_SHELL (#347 — got: [$Z14_OUT]; expect g=green y=yellow r=red stale=stale missing=missing legacy=stale)" ;;
esac
rm -rf "$Z14_TMP" 2>/dev/null || true

echo
echo "== Z15: verdict-discovery classification survives the live shell (#348) =="
# The classification travels on DISK because every caller invokes the locator
# inside a command substitution — a subshell, whose globals die on the way out.
# That is a cross-shell claim, so prove it in both shells.
Z15_TMP="$(mktemp -d)"
Z15_OUT="$(
  export UBERDEV_TMPDIR="$Z15_TMP" UBERDEV_GOAL_ID="goaltestz15"
  discover_review_verdict_json() { return 2; }
  review_verdict_discovery_state() { printf 'indeterminate\n'; }
  recapture_review_verdict_snapshot() { printf 'unexpected-recapture\n'; }
  cleanup_review_verdict_snapshot() { return 0; }
  out="$(uberdev_goal_locate_review_pr_audit_by_pr 515 2>/dev/null)"
  printf 'state=%s empty=%s\n' \
    "$(uberdev_goal_last_verdict_state 515)" \
    "$([ -z "$out" ] && printf yes || printf no)"
)"
case "$Z15_OUT" in
  *"state=indeterminate empty=yes"*)
    pass "Z15a: indeterminate is recorded distinctly (not folded into absent/missing) under $RUN_SHELL (#348)" ;;
  *)
    fail "Z15a: verdict classification wrong under $RUN_SHELL (#348 — got: [$Z15_OUT]; expect state=indeterminate empty=yes)" ;;
esac
rm -rf "$Z15_TMP" 2>/dev/null || true

echo
echo "== Z16: the workflow backend is a first-class value in every backend case (#301/RFC 0015) =="
# RFC 0015 added `workflow` to the dispatch enum. Every `case
# "$UBERDEV_RESOLVED_BACKEND"` in this lib had to learn it in the same change:
# an unlisted value falls into a default arm that probes `claude agents --json`
# for liveness and PID-reaps for cleanup — both wrong, and both silent.
Z16_TMP="$(mktemp -d)"
Z16_OUT="$(
  export UBERDEV_TMPDIR="$Z16_TMP" UBERDEV_GOAL_ID="goaltestz16" UBERDEV_RESOLVED_BACKEND=workflow
  uberdev_goal_state_init "goaltestz16" >/dev/null 2>&1
  printf '900\t42\t1700000000\tPENDING\n' > "$Z16_TMP/goal-goaltestz16-batch-prs.tsv"
  # A stale PID stash from an EARLIER detached run: the pre-fix reaper would read
  # it and signal whatever process now owns that pid.
  printf '{"pid":1,"issue":42}\n' > "$Z16_TMP/solve-bg-status-42.json"
  # The `busy=no` / `infl=no` legs alone are NOT discriminating: the pre-RFC-0015
  # default arm reaches `claude agents --json`, and a stub that merely `return 1`s
  # answers "not busy / not in flight" too — so both legs pass with the workflow
  # arms deleted. The load-bearing assertion is therefore that the claude-agents
  # probe is NEVER REACHED. Record each invocation to a FILE (a >&2 breadcrumb
  # from inside `$(…)` is not visible to the assertion, and the call sites
  # redirect stderr to /dev/null anyway), then assert the file stays empty.
  claude() { printf 'CLAUDE-AGENTS-PROBED %s\n' "$*" >> "$Z16_TMP/claude-probe.log"; return 1; }
  busy=no;  uberdev_goal_agent_busy_for_issue 42 2>/dev/null && busy=yes
  infl=no;  uberdev_goal_review_pr_in_flight 900 2>/dev/null && infl=yes
  _uberdev_goal_reap_zombies >/dev/null 2>&1
  skipped=no
  grep -q 'runtime_owned_lifecycle' "$Z16_TMP/goal-goaltestz16.jsonl" 2>/dev/null && skipped=yes
  probed=no
  [ -s "$Z16_TMP/claude-probe.log" ] && probed=yes
  printf 'busy=%s infl=%s reap_skipped=%s claude_probed=%s\n' "$busy" "$infl" "$skipped" "$probed"
)"
case "$Z16_OUT" in
  *"busy=no infl=no reap_skipped=yes claude_probed=no"*)
    pass "Z16a: backend=workflow gets explicit liveness + reaper arms under $RUN_SHELL (the claude-agents probe is never reached, no PID reap)" ;;
  *)
    fail "Z16a: backend=workflow still falls into a default arm under $RUN_SHELL (got: [$Z16_OUT]; expect busy=no infl=no reap_skipped=yes claude_probed=no)" ;;
esac
rm -rf "$Z16_TMP" 2>/dev/null || true

echo
echo "== Z17: the partial-chain ledger records ONE ROW PER CSV MEMBER (#592) =="
# The repo's recurring zsh field-splitting bug, in a new place: `for n in $csv`
# iterates ONCE over the whole string under zsh (it killed EFFORT_FLAG in
# v0.22.1 and the #470 exclusion vocabulary). uberdev_goal_record_partial_prs is
# written from the watch lane, which runs under whichever shell the goal-pipeline
# fence gets — so a bash-only split records one garbage row, every
# uberdev_goal_pr_is_partial lookup then misses, and the merge gate flags
# nothing while looking entirely healthy.
Z17_TMP="$(mktemp -d)"
Z17_OUT="$(
  export UBERDEV_TMPDIR="$Z17_TMP" UBERDEV_GOAL_ID="goaltestz17"
  cycle=2
  uberdev_goal_state_init "goaltestz17" >/dev/null 2>&1
  uberdev_goal_record_partial_prs "goaltestz17" "901,902,903" >/dev/null 2>&1
  Z17_RC=$?
  Z17_TSV="$Z17_TMP/goal-goaltestz17-partial-prs.tsv"
  printf 'rc=%s rows=%s prs=%s\n' "$Z17_RC" \
    "$(awk 'END{print NR+0}' "$Z17_TSV" 2>/dev/null)" \
    "$(awk -F'\t' '{printf "%s|", $1}' "$Z17_TSV" 2>/dev/null)"
)"
case "$Z17_OUT" in
  *"rc=0 rows=3 prs=901|902|903|"*)
    pass "Z17a: CSV split yields one row per member under $RUN_SHELL (#592)" ;;
  *)
    fail "Z17a: CSV split wrong under $RUN_SHELL (#592 — got: [$Z17_OUT]; expect rc=0 rows=3 prs=901|902|903|)" ;;
esac

# The cycle column resolves through a NESTED default (`${3:-${cycle:-0}}`): the
# explicit argument first, the watch lane's ambient scalar second, 0 last. Both
# halves need a cross-shell guard — the fallback is what keeps the helper usable
# from a `set -u` caller with no cycle in scope, and the argument is what a
# caller outside the watch lane uses instead of hoping one is ambient.
Z17B_TMP="$(mktemp -d)"
Z17B_OUT="$(
  export UBERDEV_TMPDIR="$Z17B_TMP" UBERDEV_GOAL_ID="goaltestz17b"
  cycle=2
  uberdev_goal_state_init "goaltestz17b" >/dev/null 2>&1
  uberdev_goal_record_partial_prs "goaltestz17b" "911" 5 >/dev/null 2>&1
  uberdev_goal_state_init "goaltestz17c" >/dev/null 2>&1
  ( unset cycle; uberdev_goal_record_partial_prs "goaltestz17c" "912" >/dev/null 2>&1 )
  printf 'arg=%s ambient_absent=%s\n' \
    "$(awk -F'\t' 'NR==1{print $2}' "$Z17B_TMP/goal-goaltestz17b-partial-prs.tsv" 2>/dev/null)" \
    "$(awk -F'\t' 'NR==1{print $2}' "$Z17B_TMP/goal-goaltestz17c-partial-prs.tsv" 2>/dev/null)"
)"
case "$Z17B_OUT" in
  *"arg=5 ambient_absent=0"*)
    pass "Z17b: cycle resolves argument-then-ambient-then-0 under $RUN_SHELL (#592)" ;;
  *)
    fail "Z17b: cycle resolution wrong under $RUN_SHELL (#592 — got: [$Z17B_OUT]; expect arg=5 ambient_absent=0)" ;;
esac
rm -rf "$Z17_TMP" "$Z17B_TMP" 2>/dev/null || true

echo
echo "== Z18: count_partial_prs prints exactly 0 with no ledger on disk (#592) =="
# The count is interpolated straight into the goal_converged audit payload, so
# an EMPTY value there is an unparseable JSON row, not a cosmetic zero. The
# absent-file path is live rather than theoretical: lib/goal-phase0.sh:307 skips
# uberdev_goal_state_init on --resume, so a goal started before this ledger
# existed reaches the counter with every other sidecar present and this one not.
Z18_TMP="$(mktemp -d)"
Z18_OUT="$(
  export UBERDEV_TMPDIR="$Z18_TMP" UBERDEV_GOAL_ID="goaltestz18"
  Z18_VAL="$(uberdev_goal_count_partial_prs "goaltestz18" 2>/dev/null)"
  printf 'rc=%s out=[%s]\n' "$?" "$Z18_VAL"
)"
case "$Z18_OUT" in
  *"rc=0 out=[0]"*)
    pass "Z18a: absent ledger counts as exactly 0, rc 0, under $RUN_SHELL (#592)" ;;
  *)
    fail "Z18a: absent-ledger count wrong under $RUN_SHELL (#592 — got: [$Z18_OUT]; expect rc=0 out=[0])" ;;
esac
rm -rf "$Z18_TMP" 2>/dev/null || true

echo
echo "== Z19: print_summary reports the partial-chain count from the ledger (#592) =="
# The ONE line an unattended /goal leaves behind is print_summary's. Recording a
# partial chain in the sidecar buys the operator nothing if the summary still
# reads like a clean run, so the count has to reach THIS line — Z3d above pins
# the zero case (and is the ratchet that reds if the field is dropped again);
# this row proves the number is actually READ from the ledger rather than
# hardcoded. Under zsh because print_summary runs in whichever shell the
# goal-pipeline fence gets, and its `$(uberdev_goal_count_partial_prs …)`
# capture is the same dual-shell surface as the rest of this fixture.
Z19_TMP="$(mktemp -d)"
Z19_OUT="$(
  GOAL_ID="goal-z19abcd1"
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  export UBERDEV_TMPDIR="$Z19_TMP"
  MAX_CYCLES=8
  watch_start=1729000000
  date() { case "${1:-}" in +%s) printf '%s\n' 1729003600;; *) command date "$@";; esac; }
  uberdev_goal_state_init "$GOAL_ID" >/dev/null 2>&1
  uberdev_goal_record_partial_prs "$GOAL_ID" "901,902" 1 >/dev/null 2>&1
  print_summary 3 2>&1
)"
if grep -qE '^goal goal-z19abcd1: cycles=3/8 prs_merged=0 prs_held=0 issues_resolved=0 prs_partial=2 wall_secs=3600$' <<<"$Z19_OUT"; then
  pass "Z19a: print_summary reports prs_partial=2 off a two-row ledger under $RUN_SHELL (#592)"
else
  fail "Z19a: print_summary partial count wrong under $RUN_SHELL (#592 — got: [$Z19_OUT]; expect prs_partial=2)"
fi
rm -rf "$Z19_TMP" 2>/dev/null || true

# Cleanup
rm -rf "$Z2_TMP" "$Z3_TMP" "$Z4_TMP" 2>/dev/null || true

echo
echo "== Summary =="
echo "  shell:  $RUN_SHELL"
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
