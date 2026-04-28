#!/usr/bin/env bash
# Asserts that the --turbo flag survives the full unattended pipeline:
#   /turbo → brainstorm → write-plan → subagent-driven-dev → finish-branch
# without any skill prompting the user.
#
# Skills are prompts — these tests assert the prompt contract that keeps
# `/uberdev:turbo` unattended. If a contributor edits one of these skills
# and removes turbo-awareness, the user-facing /turbo flow regresses to
# attended mode. These assertions lock that contract in.

set -u

# Resolve repo root regardless of where the test is invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRAINSTORM="$REPO_ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
WRITE_PLAN="$REPO_ROOT/plugins/uberdev/skills/write-plan/SKILL.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
FINISH_BRANCH="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
TURBO_CMD="$REPO_ROOT/plugins/uberdev/commands/turbo.md"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "== brainstorm propagates --turbo to write-plan =="
assert_grep "$BRAINSTORM" \
  'write-plan.*--turbo|--turbo.*write-plan' \
  "brainstorm names write-plan and --turbo together (propagation site)"

echo
echo "== write-plan has turbo-aware Execution Handoff =="
assert_grep "$WRITE_PLAN" \
  '--turbo.*subagent-driven-dev|subagent-driven-dev.*--turbo' \
  "write-plan auto-dispatches subagent-driven-dev with --turbo (no user prompt)"

echo
echo "== subagent-driven-dev forwards --turbo to finish-branch =="
assert_grep "$SUBAGENT_DRIVEN" \
  'finish-branch.*--turbo|--turbo.*finish-branch' \
  "subagent-driven-dev names finish-branch and --turbo together"

echo
echo "== finish-branch auto-selects PR option under --turbo =="
assert_grep "$FINISH_BRANCH" \
  '[Tt]urbo.*(Option 2|Push and [Cc]reate)|(Option 2|Push and [Cc]reate).*[Tt]urbo' \
  "finish-branch auto-selects Push and Create PR under turbo"

echo
echo "== /turbo command entry point invokes brainstorm --turbo =="
assert_grep "$TURBO_CMD" \
  'brainstorm --turbo|brainstorm.*--turbo' \
  "turbo command file invokes brainstorm with --turbo (chain entry point)"

echo
echo "== Default-mode paths preserved (regression canaries) =="
assert_grep "$WRITE_PLAN" \
  'Inline Execution|Subagent-Driven \(recommended\)' \
  "write-plan still offers the two-option default-mode prompt"
assert_grep "$FINISH_BRANCH" \
  'Merge back to|Push and create a Pull Request|Keep the branch as-is|Discard this work' \
  "finish-branch still presents the 4-option default-mode menu"
assert_grep "$BRAINSTORM" \
  'clarifying questions.*one at a time|[Aa]sk clarifying questions' \
  "brainstorm still describes the default clarifying-questions loop"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
