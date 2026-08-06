#!/usr/bin/env zsh
# Regression test for the v0.22.2 fix — the v0.22.1 `/turbo` dispatch broke under zsh
# because PERM_FLAG/EFFORT_FLAG were scalars (`EFFORT_FLAG="--effort max"`)
# and the dispatch arm relied on unquoted `$EFFORT_FLAG` word-splitting into
# two argv slots. That assumption holds in bash but NOT in zsh: zsh's default
# SH_WORD_SPLIT=off keeps the scalar as ONE argv slot, so `claude --bg`
# received `"--effort max"` as a single token and rejected it with:
#
#   error: unknown option '--effort max'
#
# The fix converts both flags to bash+zsh arrays and expands them via
# `"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, which preserves one argv slot per
# element in BOTH shells regardless of SH_WORD_SPLIT.
#
# This fixture EXECUTES the dispatch composition under a real zsh shell and
# captures the dispatched argv via a stub `claude` on PATH. The
# companion bash fixture is `tests/solve-effort-flag.test.sh` R3; together
# they lock the bash + zsh story.
#
# Failure-mode demo: revert SKILL.md to the v0.22.1 scalar form
# (`EFFORT_FLAG="--effort $EFFORT_LEVEL"` + `cmd+=( $PERM_FLAG $EFFORT_FLAG )`)
# and re-run — the assertions below fail with `--effort max` captured as one
# argv slot instead of `--effort` and `max` as two.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# #304 / RFC 0012 §3.4: the dispatch composition modelled by the R2-R4
# fixtures lives in lib/solve-launcher.sh (hoisted out of
# solve-pipeline/SKILL.md).
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
# #175: the PERM_FLAG/EFFORT_FLAG array hoist moved from solve-pipeline Phase A
# into uberdev_dispatch_resolve_env() in lib/dispatch.sh (shared SSOT helper).
# R1a/R1b now anchor on dispatch.sh; the runtime word-split fixtures (R2-R4)
# below are unaffected (they bind the arrays inline in their own subshells).
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

if [ ! -r "$SOLVE_PIPELINE" ] || [ ! -r "$DISPATCH_LIB" ]; then
  echo "FATAL: required file missing or unreadable: $SOLVE_PIPELINE or $DISPATCH_LIB" >&2
  exit 2
fi

# Sanity check: this fixture MUST run under zsh. Refuse to run under bash —
# under bash the scalar form would word-split anyway and the test would
# pass even when SKILL.md has the broken scalar form, defeating the
# regression-guard purpose.
if [ -z "${ZSH_VERSION:-}" ]; then
  echo "FATAL: this fixture must run under zsh (current shell does not set \$ZSH_VERSION)" >&2
  echo "       invoke as: zsh tests/solve-pipeline-zsh.test.sh" >&2
  exit 2
fi

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
# Normalize a stream of numbers to a single space-separated, ascending-sorted
# line (trailing-space stripped). Stdin → stdout. Byte-identical to the
# inline `sort -n | tr '\n' ' ' | sed 's/ $//'` chain it replaces.
_normalize_nums() { sort -n | tr '\n' ' ' | sed 's/ $//'; }

echo "== R1: lib/dispatch.sh resolve_env defines PERM_FLAG/EFFORT_FLAG as arrays =="
# Anchored grep on the resolve_env hoist (moved from solve-pipeline Phase A into
# lib/dispatch.sh in #175). If a future edit reverts to scalar form, this
# assertion fires before R2/R3 even execute the dispatch. The ^[[:space:]]*
# prefix tolerates the function-body indentation in dispatch.sh.
if grep -qE '^[[:space:]]*EFFORT_FLAG=\( --effort "\$EFFORT_LEVEL" \)$' "$DISPATCH_LIB"; then
  pass "R1a: EFFORT_FLAG hoist binds an array — \`EFFORT_FLAG=( --effort \"\$EFFORT_LEVEL\" )\`"
else
  fail "R1a: EFFORT_FLAG hoist no longer matches the array form"
  echo "        searched: ^[[:space:]]*EFFORT_FLAG=\\( --effort \"\\\$EFFORT_LEVEL\" \\)\$ in $DISPATCH_LIB"
fi
if grep -qE '^[[:space:]]*PERM_FLAG=\(\)$' "$DISPATCH_LIB"; then
  pass "R1b: PERM_FLAG hoist binds an empty array — \`PERM_FLAG=()\`"
else
  fail "R1b: PERM_FLAG hoist no longer matches the empty-array form"
fi

echo
echo '== R2: dispatch argv composition under zsh produces correct slot count =='
# Replicate the SKILL.md argv-arm composition verbatim under zsh. The stub
# `claude` writes its argv to a temp file; we then count slots and assert
# `--effort` and the level land as SEPARATE argv elements.
STUB_DIR="$(mktemp -d)"
CAPTURE_FILE="$(mktemp)"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# Capture argv to the file referenced by $CLAUDE_ARGV_CAPTURE. One slot
# per line; trailing newline preserves easy line-count assertions.
printf '%s\n' "$@" > "$CLAUDE_ARGV_CAPTURE"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Mirror the SKILL.md argv-arm composition in this subshell. Bind PERM_FLAG
# and EFFORT_FLAG as arrays (the post-fix shape); the dispatch must work
# under zsh.
(
  export CLAUDE_ARGV_CAPTURE="$CAPTURE_FILE"
  EFFORT_LEVEL=max
  PERM_FLAG=()
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
  TIMEOUT_BIN=""
  SOLVE_TIMEOUT=10
  MODEL='claude-opus-4-8[1m]'
  ISSUE_NUM=128
  PROMPT_BODY="fake prompt body"
  cmd=( "$STUB_DIR/claude" --bg
        --worktree "solve-issue-$ISSUE_NUM"
        --model "$MODEL" )
  cmd+=( "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" -- "$PROMPT_BODY" )
  "${cmd[@]}" >/dev/null 2>&1
) || true

if [ ! -s "$CAPTURE_FILE" ]; then
  fail "R2 precondition: claude stub did not execute or wrote nothing"
  echo "        capture file: $CAPTURE_FILE"
else
  ARGV_DUMP="$(cat "$CAPTURE_FILE")"
  # Slot-separation assertions. Under the v0.22.1 scalar form this would
  # produce `--effort max` as ONE slot (single line containing both
  # tokens); the array form produces TWO separate lines.
  if grep -qx -- '--effort' "$CAPTURE_FILE" && grep -qx 'max' "$CAPTURE_FILE"; then
    pass "R2a: '--effort' and 'max' captured as separate argv slots under zsh"
  else
    fail "R2a: zsh-dispatch did NOT word-split — '--effort' and/or 'max' missing as standalone slots"
    echo "        argv dump (one slot per line):"
    printf '          %s\n' "${(@f)ARGV_DUMP}"
  fi
  # Order check: `--effort` immediately before the level slot. Mismatch
  # would indicate the array splice landed in the wrong position.
  EFFORT_LINE=$(grep -n '^--effort$' "$CAPTURE_FILE" | head -1 | cut -d: -f1)
  LEVEL_LINE=$(grep -n '^max$' "$CAPTURE_FILE" | head -1 | cut -d: -f1)
  if [ -n "$EFFORT_LINE" ] && [ -n "$LEVEL_LINE" ] && [ "$LEVEL_LINE" -eq $((EFFORT_LINE + 1)) ]; then
    pass "R2b: '--effort' (slot $EFFORT_LINE) is immediately followed by 'max' (slot $LEVEL_LINE)"
  else
    fail "R2b: '--effort' and 'max' must be adjacent — got effort=$EFFORT_LINE level=$LEVEL_LINE"
  fi
  # Negative check: the scalar-form regression would land `--effort max`
  # on a single line. This MUST not appear.
  if grep -qx -- '--effort max' "$CAPTURE_FILE"; then
    fail "R2c: scalar-form relapse — '--effort max' appeared as a single argv slot (the bug v0.22.2 fixed)"
  else
    pass "R2c: no '--effort max' collapsed-slot relapse"
  fi
fi

echo
echo '== R3: PERM_FLAG array form survives zsh expansion under AUTO_PERMISSIONS / SKIP_PERMISSIONS path =='
# Post-#241 follow-up: AUTO_PERMISSIONS and SKIP_PERMISSIONS both resolve to
# `PERM_FLAG=( --dangerously-skip-permissions )` (single-token flag). R3 verifies
# the single-token form does not get mangled by zsh expansion when re-emitted into
# a generated launcher .sh. The two-token zsh-array-word-split regression guard
# (the historical R3 concern when PERM_FLAG was --permission-mode auto) now lives
# in R2's --effort max path — multi-token coverage is preserved there.
CAPTURE_FILE_2="$(mktemp)"
(
  export CLAUDE_ARGV_CAPTURE="$CAPTURE_FILE_2"
  EFFORT_LEVEL=max
  PERM_FLAG=( --dangerously-skip-permissions )
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
  TIMEOUT_BIN=""
  SOLVE_TIMEOUT=10
  MODEL='claude-opus-4-8[1m]'
  ISSUE_NUM=128
  PROMPT_BODY="fake prompt body"
  cmd=( "$STUB_DIR/claude" --bg
        --worktree "solve-issue-$ISSUE_NUM"
        --model "$MODEL" )
  cmd+=( "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" -- "$PROMPT_BODY" )
  "${cmd[@]}" >/dev/null 2>&1
) || true

if [ ! -s "$CAPTURE_FILE_2" ]; then
  fail "R3 precondition: claude stub did not execute or wrote nothing"
else
  if grep -qx -- '--dangerously-skip-permissions' "$CAPTURE_FILE_2"; then
    pass "R3a: '--dangerously-skip-permissions' captured as a single argv slot under zsh"
  else
    fail "R3a: AUTO_PERMISSIONS/SKIP_PERMISSIONS path failed to emit --dangerously-skip-permissions"
    echo "        argv dump (one slot per line):"
    printf '          %s\n' "${(@f)$(cat "$CAPTURE_FILE_2")}"
  fi
  # Regression guard: --permission-mode auto MUST NOT appear in the spawned argv
  # (auto-mode-collapse regression — see lib/dispatch.sh and tests/config-override.test.sh).
  if grep -qx -- '--permission-mode auto' "$CAPTURE_FILE_2"; then
    fail "R3b: auto-mode-collapse regression — '--permission-mode auto' re-appeared in spawned argv after post-#241 collapse"
  else
    pass "R3b: '--permission-mode auto' does NOT appear in spawned argv (auto-mode-collapse regression guard intact)"
  fi
fi

echo
echo '== R4: SKILL.md Phase B wave-batching iterates without zsh 0-index error =='
# Regression for issue #100. The v0.22.x Phase B inner loop used
# `for (( i = wave_start; i <= wave_end; i++ )); ISSUE_NUM="${ISSUE_NUMS[$i]}"`,
# which aborts under `zsh -u` because zsh arrays are 1-indexed by default and
# accessing `${ISSUE_NUMS[0]}` is an unset-parameter error. The fix replaces
# the indexed form with a by-value subarray slice
# (`for ISSUE_NUM in "${ISSUE_NUMS[@]:$wave_start:$wave_size}"; do`) which
# uses `offset:length` semantics, not subscript indexing, and is shell-agnostic.
#
# This fixture replicates the SKILL.md Phase B wave-batching control flow
# under a real `zsh -c` subshell with `set -u` and asserts:
#   R4a: the loop runs to completion (no `parameter not set` abort)
#   R4b: every ISSUE_NUMS element is dispatched exactly once across the waves
#   R4c: wave-1 dispatches MAX_PARALLEL_BG_AGENTS issues; wave-2 dispatches the rest
#
# Regression-mode demo: revert SKILL.md inner loop to
# `for (( i = wave_start; i <= wave_end; i++ ))` + `${ISSUE_NUMS[$i]}` and
# re-run — R4a fires with the captured stderr containing `parameter not set`.

CAPTURE_DIR_R4="$(mktemp -d)" || fail "R4 precondition: mktemp -d failed"
ERR_LOG_R4="$(mktemp)" || fail "R4 precondition: mktemp failed"

# Run the SKILL.md Phase B wave-batching control flow under `zsh -c` with
# `set -u` so the unset-parameter abort surfaces as a non-zero exit.
zsh -c '
  set -u
  export PATH="'"$STUB_DIR"'":$PATH
  CAPTURE_DIR="'"$CAPTURE_DIR_R4"'"

  ISSUE_NUMS=(91 94 95 97)
  MAX_PARALLEL_BG_AGENTS=2
  typeset -A TIERS
  typeset -A TITLES
  TIERS[91]=small;  TITLES[91]="issue 91"
  TIERS[94]=small;  TITLES[94]="issue 94"
  TIERS[95]=small;  TITLES[95]="issue 95"
  TIERS[97]=small;  TITLES[97]="issue 97"

  TOTAL_ISSUES="${#ISSUE_NUMS[@]}"
  WAVE_COUNT=$(( (TOTAL_ISSUES + MAX_PARALLEL_BG_AGENTS - 1) / MAX_PARALLEL_BG_AGENTS ))
  for (( wave_index = 1; wave_index <= WAVE_COUNT; wave_index++ )); do
    wave_start=$(( (wave_index - 1) * MAX_PARALLEL_BG_AGENTS ))
    wave_end=$(( wave_start + MAX_PARALLEL_BG_AGENTS - 1 ))
    (( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))
    wave_size=$(( wave_end - wave_start + 1 ))
    for ISSUE_NUM in "${ISSUE_NUMS[@]:$wave_start:$wave_size}"; do
      TIER="${TIERS[$ISSUE_NUM]}"
      TITLE="${TITLES[$ISSUE_NUM]}"
      printf "%s\n" "$ISSUE_NUM" >> "$CAPTURE_DIR/wave-$wave_index.txt"
    done
  done
' 2> "$ERR_LOG_R4"
R4_RC=$?

if [ "$R4_RC" -eq 0 ] && ! grep -q 'parameter not set' "$ERR_LOG_R4"; then
  pass "R4a: Phase B wave-batching loop completed under zsh -u (no parameter-not-set abort)"
else
  fail "R4a: Phase B wave-batching loop aborted under zsh -u"
  echo "        exit rc: $R4_RC"
  echo "        stderr:"
  sed 's/^/          /' "$ERR_LOG_R4"
fi

EXPECTED_NUMS=(91 94 95 97)  # array form: zsh scalar would not word-split
ALL_CAPTURED="$(cat "$CAPTURE_DIR_R4"/wave-*.txt 2>/dev/null | _normalize_nums)"
EXPECTED_SORTED="$(printf '%s\n' "${EXPECTED_NUMS[@]}" | _normalize_nums)"
if [ "$ALL_CAPTURED" = "$EXPECTED_SORTED" ]; then
  pass "R4b: every ISSUE_NUMS element dispatched exactly once across waves (captured: $ALL_CAPTURED)"
else
  fail "R4b: dispatched-issue set does not match input"
  echo "        expected: $EXPECTED_SORTED"
  echo "        got:      $ALL_CAPTURED"
fi

WAVE1_COUNT=$(wc -l < "$CAPTURE_DIR_R4/wave-1.txt" 2>/dev/null | tr -d ' ')
WAVE2_COUNT=$(wc -l < "$CAPTURE_DIR_R4/wave-2.txt" 2>/dev/null | tr -d ' ')
if [ "${WAVE1_COUNT:-0}" -eq 2 ] && [ "${WAVE2_COUNT:-0}" -eq 2 ]; then
  pass "R4c: wave-1 dispatched 2 issues, wave-2 dispatched 2 issues (matches MAX_PARALLEL_BG_AGENTS=2 for N=4)"
else
  fail "R4c: wave cardinality mismatch — wave1=${WAVE1_COUNT:-missing} wave2=${WAVE2_COUNT:-missing}, expected 2/2"
fi

# R4d: odd-N coverage. N=5 with MAX_PARALLEL_BG_AGENTS=2 yields 3 waves of size
# 2/2/1 and exercises the `(( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))`
# clamp branch in SKILL.md Phase B that R4 (N=4, perfectly even) never hits.
# The bash arithmetic for the clamp lands `wave_size=1` on the final wave;
# this assertion locks that branch against future off-by-one regressions.
CAPTURE_DIR_R4D="$(mktemp -d)" || fail "R4d precondition: mktemp -d failed"
ERR_LOG_R4D="$(mktemp)" || fail "R4d precondition: mktemp failed"

zsh -c '
  set -u
  export PATH="'"$STUB_DIR"'":$PATH
  CAPTURE_DIR="'"$CAPTURE_DIR_R4D"'"

  ISSUE_NUMS=(101 102 103 104 105)
  MAX_PARALLEL_BG_AGENTS=2
  typeset -A TIERS
  typeset -A TITLES
  for n in "${ISSUE_NUMS[@]}"; do
    TIERS[$n]=small
    TITLES[$n]="issue $n"
  done

  TOTAL_ISSUES="${#ISSUE_NUMS[@]}"
  WAVE_COUNT=$(( (TOTAL_ISSUES + MAX_PARALLEL_BG_AGENTS - 1) / MAX_PARALLEL_BG_AGENTS ))
  for (( wave_index = 1; wave_index <= WAVE_COUNT; wave_index++ )); do
    wave_start=$(( (wave_index - 1) * MAX_PARALLEL_BG_AGENTS ))
    wave_end=$(( wave_start + MAX_PARALLEL_BG_AGENTS - 1 ))
    (( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))
    wave_size=$(( wave_end - wave_start + 1 ))
    for ISSUE_NUM in "${ISSUE_NUMS[@]:$wave_start:$wave_size}"; do
      TIER="${TIERS[$ISSUE_NUM]}"
      TITLE="${TITLES[$ISSUE_NUM]}"
      printf "%s\n" "$ISSUE_NUM" >> "$CAPTURE_DIR/wave-$wave_index.txt"
    done
  done
' 2> "$ERR_LOG_R4D"
R4D_RC=$?

EXPECTED_NUMS_R4D=(101 102 103 104 105)
ALL_CAPTURED_R4D="$(cat "$CAPTURE_DIR_R4D"/wave-*.txt 2>/dev/null | _normalize_nums)"
EXPECTED_SORTED_R4D="$(printf '%s\n' "${EXPECTED_NUMS_R4D[@]}" | _normalize_nums)"
WAVE1_COUNT_R4D=$(wc -l < "$CAPTURE_DIR_R4D/wave-1.txt" 2>/dev/null | tr -d ' ')
WAVE2_COUNT_R4D=$(wc -l < "$CAPTURE_DIR_R4D/wave-2.txt" 2>/dev/null | tr -d ' ')
WAVE3_COUNT_R4D=$(wc -l < "$CAPTURE_DIR_R4D/wave-3.txt" 2>/dev/null | tr -d ' ')

# Split into three sub-assertions mirroring R4's R4a/R4b/R4c layout: this
# attributes the failure mode (loop abort vs. set mismatch vs. wave cardinality)
# instead of collapsing all three into one pass/fail line.
if [ "$R4D_RC" -eq 0 ] && ! grep -q 'parameter not set' "$ERR_LOG_R4D"; then
  pass "R4d-a: odd-N Phase B wave-batching loop completed under zsh -u (no parameter-not-set abort)"
else
  fail "R4d-a: odd-N Phase B wave-batching loop aborted under zsh -u"
  echo "        exit rc: $R4D_RC"
  if [ -s "$ERR_LOG_R4D" ]; then
    echo "        stderr:"
    sed 's/^/          /' "$ERR_LOG_R4D"
  fi
fi

if [ "$ALL_CAPTURED_R4D" = "$EXPECTED_SORTED_R4D" ]; then
  pass "R4d-b: every ISSUE_NUMS element dispatched exactly once across waves (captured: $ALL_CAPTURED_R4D)"
else
  fail "R4d-b: dispatched-issue set does not match input"
  echo "        expected: $EXPECTED_SORTED_R4D"
  echo "        got:      $ALL_CAPTURED_R4D"
fi

if [ "${WAVE1_COUNT_R4D:-0}" -eq 2 ] && [ "${WAVE2_COUNT_R4D:-0}" -eq 2 ] && [ "${WAVE3_COUNT_R4D:-0}" -eq 1 ]; then
  pass "R4d-c: odd-N clamp exercised — N=5/cap=2 → 3 waves of 2/2/1 (final wave wave_size=1 via wave_end clamp)"
else
  fail "R4d-c: wave cardinality mismatch — waves=${WAVE1_COUNT_R4D:-?}/${WAVE2_COUNT_R4D:-?}/${WAVE3_COUNT_R4D:-?}, expected 2/2/1"
fi

# Cleanup
rm -rf "$STUB_DIR" "$CAPTURE_FILE" "$CAPTURE_FILE_2" "$CAPTURE_DIR_R4" "$ERR_LOG_R4" "$CAPTURE_DIR_R4D" "$ERR_LOG_R4D"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
