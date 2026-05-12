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
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

if [ ! -r "$SOLVE_PIPELINE" ]; then
  echo "FATAL: required file missing or unreadable: $SOLVE_PIPELINE" >&2
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

echo "== R1: SKILL.md Phase A hoist defines PERM_FLAG/EFFORT_FLAG as arrays =="
# Anchored grep on the SKILL.md hoist. If a future edit reverts to scalar
# form, this assertion fires before R2/R3 even execute the dispatch.
if grep -qE '^EFFORT_FLAG=\( --effort "\$EFFORT_LEVEL" \)$' "$SOLVE_PIPELINE"; then
  pass "R1a: EFFORT_FLAG hoist binds an array — \`EFFORT_FLAG=( --effort \"\$EFFORT_LEVEL\" )\`"
else
  fail "R1a: EFFORT_FLAG hoist no longer matches the array form"
  echo "        searched: ^EFFORT_FLAG=\\( --effort \"\\\$EFFORT_LEVEL\" \\)\$ in $SOLVE_PIPELINE"
fi
if grep -qE '^PERM_FLAG=\(\)$' "$SOLVE_PIPELINE"; then
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
  MODEL='claude-opus-4-7[1m]'
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
echo '== R3: PERM_FLAG array form preserves AUTO_PERMISSIONS-mode word-split =='
# Same composition but with PERM_FLAG populated. AUTO_PERMISSIONS=1 is the
# /solve --auto path; pre-PR-#88 this also broke under zsh, but the bug
# slept because most invocations leave AUTO_PERMISSIONS unset.
CAPTURE_FILE_2="$(mktemp)"
(
  export CLAUDE_ARGV_CAPTURE="$CAPTURE_FILE_2"
  EFFORT_LEVEL=max
  PERM_FLAG=( --permission-mode auto )
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
  TIMEOUT_BIN=""
  SOLVE_TIMEOUT=10
  MODEL='claude-opus-4-7[1m]'
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
  if grep -qx -- '--permission-mode' "$CAPTURE_FILE_2" && grep -qx 'auto' "$CAPTURE_FILE_2"; then
    pass "R3a: '--permission-mode' and 'auto' captured as separate argv slots under zsh"
  else
    fail "R3a: AUTO_PERMISSIONS path collapsed under zsh"
    echo "        argv dump (one slot per line):"
    printf '          %s\n' "${(@f)$(cat "$CAPTURE_FILE_2")}"
  fi
  if grep -qx -- '--permission-mode auto' "$CAPTURE_FILE_2"; then
    fail "R3b: scalar-form relapse — '--permission-mode auto' appeared as a single argv slot"
  else
    pass "R3b: no '--permission-mode auto' collapsed-slot relapse"
  fi
fi

# Cleanup
rm -rf "$STUB_DIR" "$CAPTURE_FILE" "$CAPTURE_FILE_2"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
