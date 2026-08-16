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
CONTRACT_HELPER="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
# The cross-fence helpers review-pr.md calls but no longer defines (#427): a
# fence body is reachable only from the shell that runs it, so they ship as code.
REVIEW_FENCES="$REPO_ROOT/plugins/uberdev/lib/review-fences.sh"
SIMPLIFY="$REPO_ROOT/plugins/uberdev/commands/simplify.md"

for f in "$CODE_FIXER" "$CONTRACT_HELPER" "$REVIEW_PR" "$SIMPLIFY"; do
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
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

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
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`findings_sha256`' "Inputs names findings_sha256"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`commit_range_path`' "Inputs names commit_range_path"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`commit_range_sha256`' "Inputs names commit_range_sha256"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`working_dir`' "Inputs names working_dir"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`pr_number`' "Inputs names pr_number"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`disposition_path`' "Inputs names disposition_path"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`authority_path`' "Inputs names controller authority_path"
assert_in_section "$CODE_FIXER" '^## Inputs' '^## Tools authorised' '`authority_sha256`' "Inputs names controller authority_sha256"
assert_no_grep "$CODE_FIXER" '`findings_aggregate`|`commit_type_prefix`' \
  "Inputs remove raw aggregate and prompt-only commit-type claims"

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
  'exact receipt parsing.*git diff.*git log' \
  "Bash is limited to the contract helper and read-only git inspection"
assert_in_section "$CODE_FIXER" '^## Tools authorised' '^## Process' \
  'No route runs `git add` or direct `git commit`' \
  "Bash denies child-owned staging and direct commits"
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
echo "== code-fixer.md ## Process — authenticated sequence with security defenses =="
# Step 1: consume authority created by the controller before dispatch.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'consume-authority' \
  "Process consumes controller-created routed authority before edits"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'create or replace authority inside the child' \
  "Process forbids child-side authority creation"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'findings_sha256.*commit_range_sha256|commit_range_sha256.*findings_sha256' \
  "Process Step 1: binds both immutable source digests"
# Component containment is owned by the executable helper, not a string prefix.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'os\.path\.commonpath|component containment|path-traversal-blocked' \
  "Process uses component-aware containment"
# Commit message remains single-quoted against second-order expansion.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  "<<'EOF'" \
  "Commit message uses single-quoted EOF (no shell expansion)"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'never stage anything and never invoke' \
  "Review terminal boundary forbids direct staging and commit"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'private index.*hooks.*fixed commit message' \
  "Review commit helper owns private index and HEAD CAS"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'publish-disposition' \
  "Disposition is published before the terminal helper"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'route-specific terminal boundary' \
  "Terminal commit is delegated to the route-specific authenticated helper"
# Both phases have exactly one commit on APPLIED.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'exactly ONE commit|ONE .*commit.*either phase|one-commit authority' \
  "APPLIED emits exactly one commit in either phase"
# No state-changing git operations are child-owned.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'Do NOT push, fetch, reset, checkout, or rebase|never push|do not push' \
  "Process denies git push/fetch/reset/rebase"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'no .*evidence.*after.*commit|After.*commit.*no.*evidence' \
  "No fallible evidence publication occurs after commit"

echo
echo "== code-fixer.md ## Refusal triggers + ## Return contract =="
# Refusal triggers
assert_in_section "$CODE_FIXER" '^## Refusal triggers' '^## Return contract' \
  'authority.*envelope.*canonical-schema.*disposition.*snapshot' \
  "Refusal triggers cover authority, envelope, schema, disposition, and snapshot failures"
assert_in_section "$CODE_FIXER" '^## Refusal triggers' '^## Return contract' \
  'exact `findings:\[\]` is valid|findings:\[\].*valid' \
  "Refusal triggers explicitly accept an exact empty aggregate"
# WHO OWNS THE ARTIFACTS OF A TERMINAL THAT APPLIED NOTHING (#556). A refusing
# child restores the worktree and stops, so it writes NEITHER the disposition
# nor the applied-content record; the controller publishes both on its behalf
# from the rows it returned. That ownership has to be DECLARED somewhere, and
# this is the one place. Note the reason is NOT the `Write` denylist asserted
# above — the child creates these very bytes on every successful run, through
# the authorised contract helper rather than through `Write`. It is that
# `publish-unapplied-terminal` is gated on the launch binding, which is never in
# the child's `## Inputs`, and that `publish-disposition` is pinned to the raw
# `.git/index` bytes its own authorised `git status` / `git diff` already moved
# (`plugins/uberdev/lib/code_fixer_contract.py`, the `publish_unapplied_terminal`
# docstring). A contract resting on the denylist instead would be falsifiable
# from `agents/code-fixer.md`'s own publish-disposition step, and the first
# reader to notice would "fix" it by granting the child `Write`.
#
# This row pins the declaration so it cannot drift back to "the child
# publishes". It is a PROSE lock, not the behavioural one: what actually
# publishes the record is `publish-unapplied-terminal`, driven through
# `review_fixer_terminal_outcome` and covered by the W-UNAP rows in
# tests/review-pr-workflow.test.sh and the U rows in
# tests/code-fixer-contract.test.sh.
assert_in_section "$CODE_FIXER" '^## Refusal triggers' '^## Return contract' \
  'controller publishes them on your behalf' \
  "Refusal triggers declare the controller — not the child — publishes a refused terminal's record (#556)"
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
# Phase/type authority comes only from the routed edge + manifest phase.
assert_no_grep "$REVIEW_PR" 'phase=phase[12] commit_type_prefix=' \
  "review-pr.md carries no prompt-only phase/type claim"
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
assert_no_grep "$SIMPLIFY" 'phase=phase[12] commit_type_prefix=' \
  "simplify.md carries no prompt-only phase/type claim"

echo
echo "== Controller-owned review commit boundary =="
assert_no_grep "$CODE_FIXER" 'code_fixer_commit_once|validation_receipt=.*validate-staged|post_commit_receipt=.*validate-commit' \
  "obsolete child-owned commit gate is absent"
assert_grep "$CODE_FIXER" 'commit-review --authority-path.*--authority-sha256.*--disposition-path.*--disposition-sha256.*--applied-content-path.*--applied-content-sha256.*--working-dir' \
  "review terminal call authenticates authority, disposition, content plan, and worktree"
assert_grep "$CODE_FIXER" 'fixed routed message is `fix: address authenticated fixer' \
  "review helper derives the phase1 fix subject"
assert_grep "$CODE_FIXER" 'phase1 or `refactor: address authenticated fixer findings`' \
  "review helper derives the phase2 refactor subject"
assert_grep "$CONTRACT_HELPER" '^def commit_review\(' \
  "executable helper owns the review commit transaction"
assert_grep "$CONTRACT_HELPER" '"commit-review"' \
  "helper CLI exposes the authenticated review commit boundary"
assert_grep "$REVIEW_FENCES" 'git -C .*rev-list --count.*before.*after|rev-list --count.*FIXER' \
  "controller proves APPLIED is exactly one commit"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
