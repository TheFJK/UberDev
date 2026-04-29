#!/usr/bin/env bash
# Asserts that the per-task spec-reviewer dispatched by subagent-driven-dev
# is plan-aware:
#   1. spec-reviewer-prompt.md exposes a `Plan Task Description` placeholder
#      so the controller can plumb the plan entry into the reviewer's context.
#   2. spec-reviewer-prompt.md instructs the reviewer to flag `plan drift`
#      (structural deviation from the plan even when the spec is satisfied).
#   3. SKILL.md (step 4f) tells the controller to pass `plan_task_description`
#      alongside the existing dispatch parameters.
#
# Without these three pieces the per-task spec review only catches
# spec-vs-code drift and silently misses plan-vs-code drift (skipped steps,
# swapped libraries, merged tasks, reordered dependencies).
#
# Style mirrors tests/turbo-flow.test.sh and tests/post-impl-review.test.sh:
# grep-based structural assertions against the rendered prompt/skill files,
# no live agent invocation.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_REVIEWER_PROMPT="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/spec-reviewer-prompt.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"

# Pre-flight: refuse to run if the files we're asserting against are missing
# or unreadable — without this every assertion fails with a confusing
# "pattern not found" instead of the real cause.
for f in "$SPEC_REVIEWER_PROMPT" "$SUBAGENT_DRIVEN"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

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

echo "== spec-reviewer prompt exposes Plan Task Description placeholder =="
assert_grep "$SPEC_REVIEWER_PROMPT" \
  'Plan Task Description' \
  "spec-reviewer-prompt.md has a Plan Task Description section header"

echo
echo "== spec-reviewer prompt names plan drift in the DO list =="
assert_grep "$SPEC_REVIEWER_PROMPT" \
  'plan drift' \
  "spec-reviewer-prompt.md instructs reviewer to flag plan drift"

echo
echo "== SKILL.md plumbs plan_task_description into the dispatch =="
assert_grep "$SUBAGENT_DRIVEN" \
  'plan_task_description' \
  "subagent-driven-dev SKILL.md names plan_task_description as a spec-reviewer dispatch parameter"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
