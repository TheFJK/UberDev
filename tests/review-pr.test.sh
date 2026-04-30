#!/usr/bin/env bash
# Asserts that /uberdev:review-pr names all 6 reviewer agents, dispatches
# them in parallel (single message), exposes the documented aspect arguments,
# and that each of the 6 agent files contains the no-quoting output rule
# (primary defense against secret leakage into PR bodies).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
AGENTS_DIR="$REPO_ROOT/plugins/uberdev/agents"
AGENT_FILES=(
  "$AGENTS_DIR/code-reviewer.md"
  "$AGENTS_DIR/pr-test-analyzer.md"
  "$AGENTS_DIR/comment-analyzer.md"
  "$AGENTS_DIR/silent-failure-hunter.md"
  "$AGENTS_DIR/type-design-analyzer.md"
  "$AGENTS_DIR/code-simplifier.md"
)

for f in "$REVIEW_PR" "${AGENT_FILES[@]}"; do
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
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "== /uberdev:review-pr command file present with frontmatter =="
assert_grep "$REVIEW_PR" '^description:' "frontmatter has description"
assert_grep "$REVIEW_PR" '^allowed-tools:' "frontmatter has allowed-tools"

echo
echo "== All 6 reviewer agents named in /uberdev:review-pr =="
assert_grep "$REVIEW_PR" 'code-reviewer'         "code-reviewer named"
assert_grep "$REVIEW_PR" 'pr-test-analyzer'      "pr-test-analyzer named"
assert_grep "$REVIEW_PR" 'comment-analyzer'      "comment-analyzer named"
assert_grep "$REVIEW_PR" 'silent-failure-hunter' "silent-failure-hunter named"
assert_grep "$REVIEW_PR" 'type-design-analyzer'  "type-design-analyzer named"
assert_grep "$REVIEW_PR" 'code-simplifier'       "code-simplifier named"

echo
echo "== Parallel-default invariant documented =="
assert_grep "$REVIEW_PR" 'single message|SINGLE message|one assistant turn|ONE assistant turn|single assistant turn' \
  "parallel-fanout invariant documented"

echo
echo "== Aspect arguments listed =="
assert_grep "$REVIEW_PR" 'comments' "aspect: comments"
assert_grep "$REVIEW_PR" 'tests'    "aspect: tests"
assert_grep "$REVIEW_PR" 'errors'   "aspect: errors"
assert_grep "$REVIEW_PR" 'types'    "aspect: types"
assert_grep "$REVIEW_PR" 'code'     "aspect: code"
assert_grep "$REVIEW_PR" 'simplify' "aspect: simplify"
assert_grep "$REVIEW_PR" 'all'      "aspect: all"

echo
echo "== No-quoting output rule present in each of the 6 reviewer agents =="
for f in "${AGENT_FILES[@]}"; do
  assert_grep "$f" '[Dd]o not quote|[Nn]ever quote|no[ -]quoting' \
    "$(basename "$f"): no-quoting output rule present"
done

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
