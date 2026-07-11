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
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

echo "== /uberdev:simplify command file present with frontmatter =="
assert_grep "$SIMPLIFY" '^description:' "frontmatter has description"
assert_grep "$SIMPLIFY" '^allowed-tools:' "frontmatter has allowed-tools"

echo
echo "== Phase 2: three lens dispatch with subagent_type: uberdev:code-simplifier (#73 Q4) =="

# P2.1 — Phase 2 uses the routed manifest lens edges
assert_grep "$SIMPLIFY" 'uberdev_dispatch_child.*EDGE_ID' \
  "P2.1 — Phase 2 routes code-simplifier lenses through child-dispatch"
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

# P3.1-P3.3 — stable phase2 edge owns the code-fixer route and refactor contract
assert_grep "$SIMPLIFY" 'uberdev_dispatch_child review_pr\.fix\.phase2' \
  "P3.1 — Phase 3 routes code-fixer through child-dispatch"
assert_grep "$SIMPLIFY" 'review_pr\.fix\.phase2' \
  "P3.2 — Phase 3 code-fixer carries phase identity in edge_id"
assert_grep "$SIMPLIFY" 'ONE `refactor:` commit|single `refactor:`' \
  "P3.3 — Phase 3 code-fixer retains the refactor contract"
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

# G3 — RUN_ID is minted read-only from the current checkout before the shared
# runtime boundary verifies the carrier and atomically allocates exact paths.
assert_grep "$SIMPLIFY" 'RUN_ID="\$\{RUN_ID:-\$\(date \+%Y%m%d-%H%M%S\)-\$\(git rev-parse --short HEAD\)\}"' \
  "G3 — /simplify setup mints RUN_ID before workspace allocation"
assert_grep "$SIMPLIFY" 'uberdev_command_workspace_prepare simplify 0 medium' \
  "G3 — /simplify delegates repository verification and allocation to the runtime boundary"
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
echo "== Prompt-injection: Phase 2 lens dispatch wraps the diff in a pr-diff envelope (#286, #271 follow-up) =="
# The Phase 2 dispatch passes the full diff (`<<diff_brief>>`) to all three
# uberdev:code-simplifier lenses inline. The diff is attacker-controllable
# (issue author → PR author) so it MUST be wrapped in
# <external-untrusted-input source="pr-diff">…</external-untrusted-input> per
# the orchestrator trust-boundary convention — mirroring the Phase-1 reviewer
# wrap in skills/post-impl-review/SKILL.md Step 1 (#271). Scope the open+close
# asserts to the Phase 2 region via awk range so they cannot be satisfied by the
# PRE-EXISTING Phase 3 reader-side `source="post-impl-review-aggregate"` close
# tag (which would make the close-tag assert a false PASS even if the dispatch
# wrap were reverted). The trusted `## Lens emphasis:` / `## Additional Focus`
# directives stay OUTSIDE the envelope (only the diff is untrusted).
if ! grep -q '^## Phase 2: Launch Three Review Agents in Parallel' "$SIMPLIFY" || ! grep -q '^## Phase 3: ' "$SIMPLIFY"; then
  echo "  FAIL  setup error: Phase 2/Phase 3 anchors not found in $SIMPLIFY — section renamed? Update the awk range in tests/simplify.test.sh."
  FAIL=$((FAIL + 1))
else
  PHASE2_REGION=$(awk '/^## Phase 2: Launch Three Review Agents in Parallel/{f=1} f; /^## Phase 3: /{f=0}' "$SIMPLIFY")
  if grep -qF '<external-untrusted-input source="pr-diff">' <<<"$PHASE2_REGION"; then
    echo "  PASS  Phase 2 lens dispatch opens an <external-untrusted-input source=\"pr-diff\"> envelope around the diff"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  Phase 2 lens dispatch must wrap <<diff_brief>> in an <external-untrusted-input source=\"pr-diff\"> envelope (#286)"
    FAIL=$((FAIL + 1))
  fi
  if grep -qF '</external-untrusted-input>' <<<"$PHASE2_REGION"; then
    echo "  PASS  Phase 2 lens dispatch closes the <external-untrusted-input> envelope (inside the Phase 2 region)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  Phase 2 lens dispatch must close the pr-diff <external-untrusted-input> envelope inside the Phase 2 region (#286)"
    FAIL=$((FAIL + 1))
  fi
  # Pin the load-bearing DISPATCH-LINE form (`prompt: <external-untrusted-input
  # source="pr-diff">…<<diff_brief>>`) so a prose-only mention that left the actual
  # Task() prompt unwrapped cannot false-PASS the region asserts above.
  if grep -qF 'Pass only the diff artifact path' <<<"$PHASE2_REGION"; then
    echo "  PASS  routed handoff passes only the enveloped diff artifact path"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  routed handoff must pass only the enveloped diff artifact path (#286)"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== E1..E4: simplify-aggregate envelope-as-file-bytes + read-side no-re-wrap (#302 / RFC 0012 §3.1) =="
# Pre-#302 the Phase 3 aggregate was written bare and re-wrapped (under the
# WRONG phase-1 source token) only at dispatch time — so findings-to-issues'
# first-128-bytes validation refused every Phase 3.5 dispatch input-malformed.
# The writer now owns the simplify-aggregate envelope as the file's own bytes.
if ! grep -q '^## Phase 3: ' "$SIMPLIFY" || ! grep -q '^## Phase 3.5 ' "$SIMPLIFY"; then
  echo "  FAIL  setup error: Phase 3 / Phase 3.5 anchors not found in $SIMPLIFY — section renamed? Update the awk range in tests/simplify.test.sh."
  FAIL=$((FAIL + 1))
else
  PHASE3_REGION=$(awk '/^## Phase 3: /{f=1} f; /^## Phase 3.5 /{f=0}' "$SIMPLIFY")
  if grep -qF '<external-untrusted-input source="simplify-aggregate">' <<<"$PHASE3_REGION"; then
    echo "  PASS  E1.1 — Phase 3 writes the simplify-aggregate envelope into \$AGG_PATH"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  E1.1 — Phase 3 must write <external-untrusted-input source=\"simplify-aggregate\"> into \$AGG_PATH (#302)"
    FAIL=$((FAIL + 1))
  fi
  if grep -qE 'LEADING bytes' <<<"$PHASE3_REGION" && grep -qE 'TRAILING bytes' <<<"$PHASE3_REGION"; then
    echo "  PASS  E1.2 — Phase 3 pins the envelope as the file's LEADING/TRAILING bytes (first-128-bytes contract)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  E1.2 — Phase 3 must pin the envelope as the file's LEADING/TRAILING bytes (#302)"
    FAIL=$((FAIL + 1))
  fi
  if grep -qF 'never re-wrapped' <<<"$PHASE3_REGION"; then
    echo "  PASS  E1.3 — Phase 3 code-fixer dispatch passes path/enveloped bytes verbatim (never re-wrapped)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  E1.3 — Phase 3 code-fixer dispatch must pass the already-enveloped file verbatim (#302)"
    FAIL=$((FAIL + 1))
  fi
fi
# E2 — anti-regression: the dispatch no longer re-wraps the simplify aggregate
# under the phase-1 token (the bug that fed code-fixer a mislabeled envelope).
assert_no_grep "$SIMPLIFY" 'wraps simplify-final\.md under' \
  "E2 — old dispatch-time re-wrap of simplify-final.md removed (#302)"

echo
echo "== E3: severity-enum doc rot fixed against the pinned blocker|suggestion (RFC 0012 scan-R5) =="
# simplify.md:92/:119 described a critical/important enum the agent's Return
# contract (R1 above) never emits — dedup max-severity and the Phase 3.5 filter
# now speak the canonical two-member enum.
assert_no_grep "$SIMPLIFY" '`critical` > `important` > `suggestion`' \
  "E3.1 — rotted dedup severity rank (critical > important > suggestion) removed"
assert_grep "$SIMPLIFY" '`blocker` > `suggestion`' \
  "E3.2 — dedup max-severity rank uses the canonical blocker > suggestion"
assert_no_grep "$SIMPLIFY" 'severity == critical' \
  "E3.3 — Phase 3.5 filter no longer keyed on the non-emitted critical severity"
assert_grep "$SIMPLIFY" 'severity == blocker AND disposition != APPLIED' \
  "E3.4 — Phase 3.5 filter keyed on severity == blocker (canonical enum)"

echo
echo "== E4: code-fixer accepts the simplify-aggregate source for phase2 (closed two-member set) =="
# With the dispatch passing simplify-final.md's own file bytes (source=
# simplify-aggregate), code-fixer's Step-1 envelope validation must name that
# source for phase2 — still a closed set, still refusing any other source.
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'source="simplify-aggregate"' \
  "E4.1 — code-fixer Step 1 validation accepts simplify-aggregate for phase: phase2"
assert_grep "$CODE_FIXER" 'closed two-member source set' \
  "E4.2 — code-fixer documents the closed two-member source set (no open-ended sources)"
assert_in_section "$CODE_FIXER" '^## Process' '^## Refusal triggers' \
  'any other source attribute is malformed' \
  "E4.3 — code-fixer Step 1 still refuses non-member sources (input-malformed)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
