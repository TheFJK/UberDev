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
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

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
assert_grep "$SOLVE_PIPELINE" \
  'orchestrator --turbo|brainstorm --turbo|--turbo.*orchestrator|--turbo.*brainstorm' \
  "solve-pipeline skill (medium tier) dispatches --turbo into the pipeline"

echo
echo "== Differential guard: AUTO_MODE!=1 medium dispatch dispatches WITHOUT --turbo (#15) =="
# pr-test-analyzer Gap #2: the positive --turbo assertion above asserts --turbo
# appears somewhere in the skill; this asserts the interactive (/solve) medium
# branch dispatches the orchestrator WITHOUT --turbo, so a future edit that
# accidentally hardcoded --turbo would break this test.
SOLVE_MEDIUM_DISPATCH=$(awk '
  /^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$/ { in_turbo=1; next }
  in_turbo && /^else$/ { in_turbo=0; in_solve=1; next }
  in_solve && /^fi$/ { in_solve=0; next }
  in_solve && /orchestrator.*solve GH issue/ { print }
' "$SOLVE_PIPELINE")
if grep -qE -- '--turbo' <<<"$SOLVE_MEDIUM_DISPATCH"; then
  echo "  FAIL  AUTO_MODE!=1 medium dispatch MUST NOT contain --turbo (interactive /solve regression)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  AUTO_MODE!=1 medium dispatch correctly omits --turbo (interactive /solve preserved)"
  PASS=$((PASS + 1))
fi

echo
echo "== thin /solve and /turbo wrappers invoke the solve-pipeline skill =="
SOLVE_PIPELINE_REF='uberdev:solve-pipeline|solve-pipeline skill'
assert_grep "$SOLVE_CMD" "$SOLVE_PIPELINE_REF" \
  "/solve thin wrapper invokes the solve-pipeline skill"
assert_grep "$TURBO_CMD" "$SOLVE_PIPELINE_REF" \
  "/turbo thin wrapper invokes the solve-pipeline skill"
assert_grep "$SOLVE_CMD" 'export AUTO_MODE=0' \
  "/solve thin wrapper sets AUTO_MODE=0 (interactive)"
assert_grep "$TURBO_CMD" 'export AUTO_MODE=1' \
  "/turbo thin wrapper sets AUTO_MODE=1 (unattended)"

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
# Q11 (issue #20): default mode no longer presents the menu — it auto-pushes.
# The 4-option menu is gated under --interactive only.
assert_grep "$FINISH_BRANCH" \
  '[Dd]efault.*[Aa]uto.*Option 2|[Dd]efault mode.*Option 2|always-PR' \
  "finish-branch default mode auto-pushes PR (no menu)"
assert_grep "$FINISH_BRANCH" \
  '--interactive.*Merge back to|--interactive.*4-option|--interactive.*4 option|interactive.*Push and create a Pull Request|interactive.*Keep the branch as-is' \
  "finish-branch --interactive restores 4-option menu"
assert_grep "$BRAINSTORM" \
  'clarifying questions.*one at a time|[Aa]sk clarifying questions' \
  "brainstorm still describes the default clarifying-questions loop"

echo
echo "== finish-branch chains into review-pr after PR creation (Q1) =="
assert_grep "$FINISH_BRANCH" \
  'Skill.*review-pr|Skill\("uberdev:review-pr"\)|uberdev:review-pr.*Skill' \
  "finish-branch invokes uberdev:review-pr via Skill tool after PR creation"

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
