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
ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
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
echo "== /turbo command entry point dispatches --turbo into the pipeline =="
# After the orchestrator landed (PR #8), medium/large /turbo enters via
# /uberdev:orchestrator --turbo; small/trivial tiers skip brainstorm entirely.
# Either entry-point name + --turbo proves the dispatch contract.
assert_grep "$TURBO_CMD" \
  'orchestrator --turbo|brainstorm --turbo|--turbo.*orchestrator|--turbo.*brainstorm' \
  "turbo command file dispatches --turbo into the pipeline (orchestrator or brainstorm entry)"

echo
echo "== orchestrator forwards --turbo into subagent-driven-dev =="
# Orchestrator → subagent-driven-dev is the medium/large /turbo handoff site.
# Without --turbo here, finish-branch still prompts at the end of the pipeline.
assert_grep "$ORCHESTRATOR" \
  '--turbo.*subagent-driven-dev|subagent-driven-dev.*--turbo|pass.*--turbo|with `--turbo`' \
  "orchestrator Phase 5 forwards --turbo to subagent-driven-dev"

echo
echo "== Default-mode paths preserved (regression canaries) =="
assert_grep "$WRITE_PLAN" \
  'Default path \(subagent-driven\)|Inline override' \
  "write-plan default-mode handoff still names both subagent-driven (default) and inline override paths"
assert_grep "$FINISH_BRANCH" \
  'Merge back to|Push and create a Pull Request|Keep the branch as-is|Discard this work' \
  "finish-branch still presents the 4-option default-mode menu"
assert_grep "$BRAINSTORM" \
  'clarifying questions.*one at a time|[Aa]sk clarifying questions' \
  "brainstorm still describes the default clarifying-questions loop"

echo
echo "== orchestrator wires always-on reviewers =="
assert_grep "$ORCHESTRATOR" 'questions\.md' \
  "orchestrator writes questions.md under --turbo"
assert_grep "$ORCHESTRATOR" 'spec-reviewer' \
  "spec-reviewer wired in orchestrator"
# Old --paranoid gate REMOVED — assert the new always-on prose is present and the gate prose is absent.
assert_grep "$ORCHESTRATOR" 'always run for medium AND large|always-on for medium and large' \
  "spec-reviewer documented as always-on for medium+large"
if grep -qE 'tier == .?medium.? AND .?--paranoid' "$ORCHESTRATOR"; then
  echo "  FAIL  old --paranoid gate prose still present"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  old --paranoid gate prose removed"
  PASS=$((PASS + 1))
fi
assert_grep "$ORCHESTRATOR" 'plan-reviewer' \
  "plan-reviewer wired in orchestrator (Phase 4.5)"
assert_grep "$ORCHESTRATOR" 'post-impl-review' \
  "post-impl-review skill referenced from orchestrator"
assert_grep "$ORCHESTRATOR" 'pr-test-analyzer' \
  "pr-test-analyzer wired for large tier (Phase 5.5)"

echo
echo "== subagent-driven-dev invokes post-impl-review after each wave =="
assert_grep "$SUBAGENT_DRIVEN" 'post-impl-review' \
  "post-impl-review skill referenced from subagent-driven-dev"

echo
echo "== finish-branch composes new PR-body sections =="
assert_grep "$FINISH_BRANCH" 'Open questions answered by /turbo' \
  "finish-branch PR body has Open questions answered by /turbo section"
assert_grep "$FINISH_BRANCH" 'Reviewer findings summary' \
  "finish-branch PR body has Reviewer findings summary section"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
