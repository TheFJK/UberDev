#!/usr/bin/env bash
# Asserts that /uberdev:simplify Phase 2 dispatches three lenses with the
# named subagent_type (uberdev:code-simplifier), Phase 3 dispatches
# code-fixer with phase=phase2 + commit_type_prefix=refactor:, and that
# the iron-rule prose ("preserve behavior") is preserved. Also locks the
# F1 spec-reviewer feedback: code-simplifier.md retains the no-quoting
# output rule even though it dropped out of tests/review-pr.test.sh's
# AGENT_FILES array.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMPLIFY="$REPO_ROOT/plugins/uberdev/commands/simplify.md"
CODE_SIMPLIFIER="$REPO_ROOT/plugins/uberdev/agents/code-simplifier.md"
CODE_FIXER="$REPO_ROOT/plugins/uberdev/agents/code-fixer.md"

for f in "$SIMPLIFY" "$CODE_SIMPLIFIER" "$CODE_FIXER"; do
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

echo "== /uberdev:simplify command file present with frontmatter =="
assert_grep "$SIMPLIFY" '^description:' "frontmatter has description"
assert_grep "$SIMPLIFY" '^allowed-tools:' "frontmatter has allowed-tools"

echo
echo "== Phase 2: three lens dispatch with subagent_type: uberdev:code-simplifier (#73 Q4) =="

# P2.1 — Phase 2 uses the Task tool with the named subagent_type
assert_subagent_type "$SIMPLIFY" 'code-simplifier' \
  "P2.1 — Phase 2 dispatch uses subagent_type: uberdev:code-simplifier (named lens)"
# P2.2 — three lenses each have a Lens emphasis line
assert_grep "$SIMPLIFY" '## Lens emphasis: Reuse' \
  "P2.2 — Lens 1: ## Lens emphasis: Reuse"
assert_grep "$SIMPLIFY" '## Lens emphasis: Quality' \
  "P2.3 — Lens 2: ## Lens emphasis: Quality"
assert_grep "$SIMPLIFY" '## Lens emphasis: Efficiency' \
  "P2.4 — Lens 3: ## Lens emphasis: Efficiency"
# P2.5 — single-message-fanout invariant
assert_grep "$SIMPLIFY" 'single message|SINGLE message|one assistant turn|ONE assistant turn' \
  "P2.5 — single-message-fanout invariant documented"
# P2.6 — three Task() calls / three lenses prose
assert_grep "$SIMPLIFY" 'three agents|three lenses|three .Task. tool_use blocks|all three' \
  "P2.6 — three lenses dispatched concurrently"

echo
echo "== Phase 3: dispatch code-fixer subagent (#73 Q3) =="

# P3.1 — Phase 3 uses subagent_type: uberdev:code-fixer
assert_subagent_type "$SIMPLIFY" 'code-fixer' \
  "P3.1 — Phase 3 dispatch uses subagent_type: uberdev:code-fixer"
# P3.2 — phase=phase2 (Phase 3 of /simplify is the Phase 2 fixer per #73)
assert_grep "$SIMPLIFY" 'phase=phase2|phase: phase2' \
  "P3.2 — Phase 3 code-fixer dispatch carries phase=phase2"
# P3.3 — commit_type_prefix=refactor:
assert_grep "$SIMPLIFY" 'commit_type_prefix=refactor:|commit_type_prefix: refactor:' \
  "P3.3 — Phase 3 code-fixer dispatch carries commit_type_prefix=refactor:"
# P3.4 — refactor: as the conventional commit type (separate-commit invariant)
assert_grep "$SIMPLIFY" 'separate `refactor:` conventional commit|ONE `refactor:` commit|single `refactor:`' \
  "P3.4 — Phase 3 commits as a separate refactor: conventional commit"
# P3.5 — iron rule preserved
assert_grep "$SIMPLIFY" '[Pp]reserve behavior|[Bb]ehavior preservation|iron rule' \
  "P3.5 — iron rule (preserve behavior) prose preserved"
# P3.6 — apply-loop edits NO LONGER held in main turn (delegated to code-fixer)
assert_grep "$SIMPLIFY" 'no longer holds apply-loop edits in-context|delegated to .code-fixer.|fresh .code-fixer. subagent' \
  "P3.6 — apply-loop edits delegated to code-fixer subagent"
# P3.7 — anti-regression: old "fix each issue directly" prose must NOT remain (the fixer dispatches now)
assert_no_grep "$SIMPLIFY" 'Aggregate their findings and fix each issue directly' \
  "P3.7 — old in-context apply-loop prose removed (now dispatches code-fixer)"

echo
echo "== F1: code-simplifier no-quoting rule preserved (test moved from review-pr.test.sh #73) =="

# F1 — code-simplifier dropped out of tests/review-pr.test.sh's AGENT_FILES array
# because it's no longer in Phase 1's dispatch. The no-quoting output rule is still
# critical for secret-leak prevention; this test takes ownership of that assertion.
assert_grep "$CODE_SIMPLIFIER" '[Dd]o not quote|[Nn]ever quote|no[ -]quoting' \
  "F1 — code-simplifier.md retains no-quoting output rule"

echo
echo "== F2: code-simplifier frontmatter description updated for new role (#73) =="

# F2 — frontmatter description must reflect the Phase 2 lens / standalone roles
# rather than the stale "subagent-driven-dev skill's uberdev:post-impl-review fanout"
# wording (which referenced a retired call site).
assert_no_grep "$CODE_SIMPLIFIER" "subagent-driven-dev skill's .uberdev:post-impl-review. fanout" \
  "F2 — stale subagent-driven-dev fanout reference removed from description"
assert_grep "$CODE_SIMPLIFIER" 'Phase 2 lens|subagent_type: uberdev:code-simplifier|Lens emphasis' \
  "F2 — new Phase 2 lens / named-dispatcher prose present"
# Audit-only invariant preserved
assert_grep "$CODE_SIMPLIFIER" 'You do not modify files\.' \
  "F2 — audit-only invariant ('You do not modify files.') preserved"

echo
echo "== G1..G7: agent self-contained + command tightening =="

# G1 — agent owns the three lens checklists (self-contained, no command preamble required)
assert_grep "$CODE_SIMPLIFIER" '^## Lens checklists' \
  "G1 — agent file has top-level '## Lens checklists' section"
assert_in_section "$CODE_SIMPLIFIER" '^## Lens checklists' '^## Return contract' '^### Lens: Reuse' \
  "G1 — agent file has 'Lens: Reuse' subsection inside Lens checklists"
assert_in_section "$CODE_SIMPLIFIER" '^## Lens checklists' '^## Return contract' '^### Lens: Quality' \
  "G1 — agent file has 'Lens: Quality' subsection inside Lens checklists"
assert_in_section "$CODE_SIMPLIFIER" '^## Lens checklists' '^## Return contract' '^### Lens: Efficiency' \
  "G1 — agent file has 'Lens: Efficiency' subsection inside Lens checklists"
# G1 — command file no longer duplicates the lens checklist prose; it points at the agent
assert_no_grep "$SIMPLIFY" '^1\. \*\*Search for existing utilities and helpers\*\*' \
  "G1 — command file no longer restates the Reuse lens checklist (deduped to agent)"
assert_no_grep "$SIMPLIFY" '^1\. \*\*Redundant state\*\*' \
  "G1 — command file no longer restates the Quality lens checklist (deduped to agent)"
assert_no_grep "$SIMPLIFY" '^1\. \*\*Unnecessary work\*\*' \
  "G1 — command file no longer restates the Efficiency lens checklist (deduped to agent)"
assert_grep "$SIMPLIFY" 'plugins/uberdev/agents/code-simplifier\.md' \
  "G1 — command file points at agent file for canonical lens definitions"

# G2 — strict iron-rule prose mirrored into the agent
assert_grep "$CODE_SIMPLIFIER" 'function signatures, return types, thrown exception types' \
  "G2 — agent file carries the strict iron-rule prose (signatures/returns/exceptions/public API)"
assert_grep "$CODE_SIMPLIFIER" 'iron rule' \
  "G2 — agent file labels its iron-rule clause"

# G3 — RUN_ID minting recipe inlined in /simplify Phase 3 (matches review-pr)
assert_grep "$SIMPLIFY" 'RUN_ID="\$\(date \+%Y%m%d-%H%M%S\)-\$\(git rev-parse --short HEAD\)"' \
  "G3 — /simplify Phase 3 inlines the canonical RUN_ID recipe"
assert_grep "$SIMPLIFY" '\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$' \
  "G3 — /simplify Phase 3 validates RUN_ID against the canonical regex"

# G4 — simplify-final.md path anchored to git rev-parse --show-toplevel
assert_grep "$SIMPLIFY" 'git rev-parse --show-toplevel' \
  "G4 — /simplify Phase 3 anchors aggregate path with git rev-parse --show-toplevel"
assert_grep "$SIMPLIFY" 'WORKTREE_ROOT|AGG_PATH' \
  "G4 — /simplify Phase 3 builds aggregate path from worktree root variable"

# G5 — dedup policy across lenses specified
assert_grep "$SIMPLIFY" '[Dd]edup policy' \
  "G5 — /simplify Phase 3 documents dedup policy heading"
assert_grep "$SIMPLIFY" 'file:line' \
  "G5 — /simplify Phase 3 dedup keyed on file:line"
assert_grep "$SIMPLIFY" 'Reuse\+Quality|merged findings|merge into ONE finding' \
  "G5 — /simplify Phase 3 dedup merges overlapping findings (lens-prefixed)"

# G6 — per-lens output format pinned in agent return contract
assert_grep "$CODE_SIMPLIFIER" '^## Return contract' \
  "G6 — agent file has '## Return contract' section"
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'location:' \
  "G6 — return contract pins location field"
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'severity:' \
  "G6 — return contract pins severity field"
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'lens:' \
  "G6 — return contract pins lens field"
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'summary:' \
  "G6 — return contract pins summary field"
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'detail:' \
  "G6 — return contract pins detail field"

# G7 — Phase 1 fallback tightened: no session-history introspection, refuse on empty diff + empty args
assert_no_grep "$SIMPLIFY" 'most recently modified files that the user mentioned or that you edited earlier' \
  "G7 — old session-history fallback prose removed"
assert_grep "$SIMPLIFY" '/simplify needs either a non-empty git diff or an explicit scope hint via \$ARGUMENTS' \
  "G7 — /simplify Phase 1 carries the explicit refusal message"

echo
echo "== R1..R5: post-code-review hardening =="

# R1 — severity enum parity with canonical post-impl-review-aggregate schema (blocker|suggestion)
# pr-test-analyzer.md:57 and post-impl-review/SKILL.md:128 both use 'blocker | suggestion'.
# code-fixer.md:31 parses the same envelope. The simplifier MUST emit the same enum.
assert_in_section "$CODE_SIMPLIFIER" '^## Return contract' '^## Output Rules' 'severity: blocker \| suggestion' \
  "R1 — agent return contract uses canonical severity: blocker | suggestion"
assert_no_grep "$CODE_SIMPLIFIER" 'severity: critical \| important \| suggestion' \
  "R1 — agent return contract no longer uses non-canonical critical|important enum"

# R2 — code-fixer.md parser explicitly acknowledges the optional lens field carried
# by simplify aggregates. The Process Step 2 extraction list must include `lens`
# so the parser doesn't silently drop the field that the simplify aggregator
# uses to indicate which lens(es) flagged a finding (single or merged form).
CODE_FIXER="$REPO_ROOT/plugins/uberdev/agents/code-fixer.md"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  '\{severity, location.*lens|severity, location.*lens.*summary, detail|lens\?' \
  "R2 — code-fixer parser Step 2 extraction list includes optional lens field"

# R3 — cross-file consistency: each lens name in command file paired with the same name in agent file
# Catches the rename-one-without-the-other class of drift.
for lens in Reuse Quality Efficiency; do
  assert_grep "$SIMPLIFY" "Lens: $lens" \
    "R3 — command file references 'Lens: $lens' (must match agent section name)"
  assert_grep "$CODE_SIMPLIFIER" "^### Lens: $lens" \
    "R3 — agent file owns '### Lens: $lens' subsection"
done

# R4 — iron-rule strict invariants live ONLY in the agent file; command file cross-references them
assert_no_grep "$SIMPLIFY" 'function signatures, return types, thrown exception types' \
  "R4 — command file no longer restates strict iron-rule invariants verbatim (single source: agent)"
assert_grep "$SIMPLIFY" '[Ii]ron rule.*[Aa]gent|agents/code-simplifier\.md' \
  "R4 — command file's iron-rule clause cross-references agent file"

# R5 — Phase 1 refusal also carries machine-parseable YAML for callers (turbo, automation)
assert_grep "$SIMPLIFY" 'status: REFUSED' \
  "R5 — Phase 1 refusal includes machine-parseable status: REFUSED"
assert_grep "$SIMPLIFY" 'rationale: "empty-diff-and-empty-arguments"' \
  "R5 — Phase 1 refusal carries explicit rationale token"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
