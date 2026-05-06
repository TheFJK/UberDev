#!/usr/bin/env bash
# Asserts that the new code-fixer agent (per #73) is structurally complete
# (frontmatter, inputs, process, return contract, refusal triggers, output
# rules) AND that the three caller files (review-pr.md Phase 1, review-pr.md
# Phase 2, simplify.md Phase 3) actually dispatch it via subagent_type.
# Tools allowlist + denylist invariants are also locked here so a future
# implementer cannot quietly broaden the agent's authority.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODE_FIXER="$REPO_ROOT/plugins/uberdev/agents/code-fixer.md"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY="$REPO_ROOT/plugins/uberdev/commands/simplify.md"

for f in "$CODE_FIXER" "$REVIEW_PR" "$SIMPLIFY"; do
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

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

# Structural-assertion helpers (assert_count / assert_subagent_type / assert_in_section)
. "$REPO_ROOT/tests/_lib_assert_structural.sh"

echo "== code-fixer.md frontmatter =="
assert_grep "$CODE_FIXER" '^name: code-fixer$' "frontmatter has name: code-fixer"
assert_grep "$CODE_FIXER" '^model: inherit$' "frontmatter pins model: inherit (tracks parent session model — high-quality fixes use whatever Opus/Sonnet the user runs)"
assert_grep "$CODE_FIXER" '^color: yellow$' "frontmatter has color: yellow"
assert_grep "$CODE_FIXER" '^description: ' "frontmatter has description"
# Description references the trust envelope tag (so the agent's role is unambiguously named)
assert_grep "$CODE_FIXER" 'external-untrusted-input source="post-impl-review-aggregate"' \
  "description names the trust envelope tag"
# Description names both Phase 1 + Phase 2 dispatch sites
assert_grep "$CODE_FIXER" '/uberdev:review-pr Phase 1.*Phase 2|Phase 1.*Phase 2.*/uberdev:simplify' \
  "description names Phase 1, Phase 2, and /uberdev:simplify dispatch sites"

echo
echo "== code-fixer.md ## Inputs section names all required inputs =="
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`findings_path`' "Inputs names findings_path"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`findings_aggregate`' "Inputs names findings_aggregate"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`commit_range`' "Inputs names commit_range"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`working_dir`' "Inputs names working_dir"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`pr_number`' "Inputs names pr_number"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`phase`' "Inputs names phase"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`commit_type_prefix`' "Inputs names commit_type_prefix"
# findings_aggregate is wrapped in trust envelope (load-bearing)
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' \
  'wrapped in `<external-untrusted-input source="post-impl-review-aggregate">' \
  "Inputs documents trust-envelope wrapping for findings_aggregate"

echo
echo "== code-fixer.md ## Tools authorised — allowlist + denylist =="
# Allowlist (the only authorised tools)
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  '\bRead\b' "Tools allowlist contains Read"
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  '\bEdit\b' "Tools allowlist contains Edit"
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  '\bBash\b' "Tools allowlist contains Bash (limited)"
# Bash sub-allowlist
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'git add|git commit|git diff|git log|git rev-parse' \
  "Bash limited to git add/commit/diff/log/rev-parse + realpath"
# Bash denylist (regression guards — these MUST NOT be in the allowlist prose)
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'no .git reset.|no .git push.|no .git checkout.|no .git rebase.' \
  "Bash denies git reset/push/checkout/rebase"
# Tool denylist (explicit refusals)
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'WebFetch' "Denylist names WebFetch"
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'WebSearch' "Denylist names WebSearch"
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'Task .no re-entrant fanout.|Task..no re-entrant' \
  "Denylist names Task (no re-entrant fanout)"

echo
echo "== code-fixer.md ## Process — six-step sequence with security defenses =="
# Step 1: Validate inputs (trust envelope + worktree check)
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'Validate inputs.*git -C.*rev-parse --is-inside-work-tree' \
  "Process Step 1: validates working_dir is inside a git worktree"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'trust envelope|external-untrusted-input source="post-impl-review-aggregate"' \
  "Process Step 1: checks trust envelope on findings_aggregate"
# Step 3b: Realpath-prefix-check
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  '[Rr]ealpath-prefix-check|realpath -m .working_dir|path-traversal-blocked' \
  "Process Step 3b: realpath-prefix-check against working_dir"
# Step 4: Heredoc commit (single-quoted EOF — second-order injection defense)
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  "<<'EOF'" \
  "Process Step 4: heredoc commit uses single-quoted EOF (no shell expansion)"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'NEVER .git add -A.|NEVER .git add -a.|NEVER `git add -A`' \
  "Process Step 4: never use git add -A/-a"
# Step 5: Single Phase 2 commit (R8.6 invariant)
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'Phase 2 specifically: ONE .refactor:. commit only|R8\.6.s separate-commit invariant' \
  "Process Step 5: Phase 2 emits ONE refactor: commit (R8.6 invariant)"
# Step 6: No git operations beyond add+commit
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'Do NOT push, fetch, reset, or rebase|never push|do not push' \
  "Process Step 6: NO git push/fetch/reset/rebase"

echo
echo "== code-fixer.md ## Refusal triggers + ## Return contract =="
# Refusal triggers
assert_in_section "$CODE_FIXER" '^## Refusal triggers' '^## Return contract' \
  'refused-malformed-envelope|refused-not-a-worktree|refused-empty-aggregate' \
  "Refusal triggers names malformed-envelope / not-a-worktree / empty-aggregate"
# Return contract YAML shape
assert_in_section "$CODE_FIXER" '^## Return contract' '^## Output Rules' \
  '^status: APPLIED \| NO_FIXES_NEEDED \| REFUSED' \
  "Return contract YAML: status enum"
assert_in_section "$CODE_FIXER" '^## Return contract' '^## Output Rules' \
  '^phase: phase1 \| phase2' \
  "Return contract YAML: phase enum"
assert_in_section "$CODE_FIXER" '^## Return contract' '^## Output Rules' \
  '^commits:' \
  "Return contract YAML: commits[] list"
assert_in_section "$CODE_FIXER" '^## Return contract' '^## Output Rules' \
  '^findings_disposition:' \
  "Return contract YAML: findings_disposition[] list"
assert_in_section "$CODE_FIXER" '^## Return contract' '^## Output Rules' \
  'sha: <40-hex>|sha:.*40-hex' \
  "Return contract YAML: commits[].sha is 40-hex"

echo
echo "== code-fixer.md ## Output Rules — secret-leak prevention =="
# No-quoting rule (mirrors the reviewer agents)
assert_grep "$CODE_FIXER" '[Dd]o not quote|[Nn]ever quote|no[ -]quoting' \
  "code-fixer.md retains no-quoting output rule (secret-leak prevention)"

echo
echo "== Dispatch sites: review-pr.md Phase 1 (Step 5) + Phase 2 (Step 6b) =="
# Each dispatch site uses subagent_type: uberdev:code-fixer
assert_subagent_type "$REVIEW_PR" 'code-fixer' \
  "review-pr.md dispatches uberdev:code-fixer (subagent_type)"
# Phase 1 dispatch: phase=phase1
assert_grep "$REVIEW_PR" 'phase=phase1' \
  "review-pr.md Phase 1 dispatch carries phase=phase1"
# Phase 2 dispatch: phase=phase2 + commit_type_prefix=refactor:
assert_grep "$REVIEW_PR" 'phase=phase2' \
  "review-pr.md Phase 2 dispatch carries phase=phase2"
assert_grep "$REVIEW_PR" 'commit_type_prefix=refactor:' \
  "review-pr.md Phase 2 dispatch carries commit_type_prefix=refactor:"
# Count: ≥ 2 distinct subagent_type: uberdev:code-fixer references
REVIEW_DISPATCH_COUNT=$(grep -cE 'subagent_type: uberdev:code-fixer' "$REVIEW_PR" || true)
if [[ "$REVIEW_DISPATCH_COUNT" -ge 2 ]]; then
  echo "  PASS  review-pr.md dispatches code-fixer ≥ 2 times (Phase 1 + Phase 2; got $REVIEW_DISPATCH_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  review-pr.md must dispatch code-fixer ≥ 2 times (got $REVIEW_DISPATCH_COUNT)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Dispatch site: simplify.md Phase 3 =="
assert_subagent_type "$SIMPLIFY" 'code-fixer' \
  "simplify.md Phase 3 dispatches uberdev:code-fixer (subagent_type)"
assert_grep "$SIMPLIFY" 'phase=phase2' \
  "simplify.md Phase 3 dispatch carries phase=phase2 (per #73 design)"
assert_grep "$SIMPLIFY" 'commit_type_prefix=refactor:' \
  "simplify.md Phase 3 dispatch carries commit_type_prefix=refactor:"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
