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

assert_not_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern (should NOT match)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
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
assert_grep "$TURBO_CMD" \
  'argument-hint:.*<issue-number>.*\[<issue-number>' \
  "/turbo argument-hint documents multi-issue syntax"
assert_grep "$SOLVE_CMD" \
  'argument-hint:.*<issue-number>.*\[<issue-number>' \
  "/solve argument-hint documents multi-issue syntax"

echo
echo "== solve-pipeline accepts multiple issue numbers (multi-issue dispatch) =="
# /turbo 5 6 7 must spawn one agent per issue in parallel. The skill tokenizes
# $ARGUMENTS via a portable bash-and-zsh-safe pipeline (`tr ' ' '\n' | grep -E
# '^[0-9]+$' | awk '!seen[$0]++'`), validates every issue up front (Phase A),
# and only then spawns (Phase B). If any issue fails validation, the entire
# batch aborts with no agents dispatched.
#
# zsh footgun: a naive `for token in $ARGUMENTS; do …` does NOT word-split
# scalar parameters in zsh (SH_WORD_SPLIT off by default), so `/turbo 5 6 7`
# would die at the usage check. The pipeline avoids this — `arr=($(cmd))`
# word-splits the substitution output on $IFS in BOTH bash and zsh.
assert_grep "$SOLVE_PIPELINE" \
  "ISSUE_NUMS=\(\\\$\(echo .*ARGUMENTS" \
  "solve-pipeline declares ISSUE_NUMS via portable subshell pipeline"
assert_grep "$SOLVE_PIPELINE" \
  "tr ' ' '\\\\n'" \
  "solve-pipeline tokenizes \$ARGUMENTS via tr (portable across bash/zsh)"
assert_grep "$SOLVE_PIPELINE" \
  "grep -E '\^\[0-9\]\+\\\$'" \
  "solve-pipeline filters to purely-numeric tokens (anchored ^[0-9]+\$ rejects --terminal=foo123)"
assert_grep "$SOLVE_PIPELINE" \
  "awk '!seen\[\\\$0\]\+\+'" \
  "solve-pipeline dedupes via awk !seen[\$0]++ (preserves first-seen order, prevents same-issue worktree race)"
assert_grep "$SOLVE_PIPELINE" \
  'SH_WORD_SPLIT|word-split|word split' \
  "solve-pipeline comment explains the zsh word-split footgun (regression-prevention)"
assert_grep "$SOLVE_PIPELINE" \
  'no agents dispatched' \
  "solve-pipeline aborts before spawning if any issue fails Phase A validation"
assert_grep "$SOLVE_PIPELINE" \
  'printf .error: %s.*ERRORS\[@\]' \
  "Phase A prints ALL accumulated errors before abort (not just the last one)"
assert_grep "$SOLVE_PIPELINE" \
  'Phase A|validate.*all issues|validate-all-first' \
  "solve-pipeline names the Phase A validate-all-first contract"
assert_grep "$SOLVE_PIPELINE" \
  'for ISSUE_NUM in "\$\{ISSUE_NUMS\[@\]\}"' \
  "solve-pipeline loops Phase B over validated issues"
# TURBO MODE banner must be hoisted out of the per-issue loop and printed
# at most once per /turbo invocation. Locking both the dedup loop AND the
# `break` after the first medium-tier hit keeps it from regressing to
# per-spawn (which would stack N identical banners on a 3-medium batch).
assert_grep "$SOLVE_PIPELINE" \
  'TURBO MODE.*banner.*once|print once.*medium|once before.*loop' \
  "TURBO MODE banner documented as printed-once (not per-spawn)"
# Two single-line assertions (grep -E without -z does not match across newlines —
# a multi-line `.*\n.*` alternation half is dead code). Lock the dedup loop and
# the break-on-first-medium guard separately.
assert_grep "$SOLVE_PIPELINE" \
  'for n in "\$\{ISSUE_NUMS\[@\]\}"' \
  "TURBO MODE banner loops over ISSUE_NUMS to scan tiers (dedup mechanic)"
assert_grep "$SOLVE_PIPELINE" \
  'TIERS\[\$n\].*medium' \
  "TURBO MODE banner checks TIERS[\$n] == medium (with break after first hit)"
assert_grep "$SOLVE_PIPELINE" \
  'TERMINAL.*==.*ghostty.*\&\&.*ISSUE_NUMS|sleep 0\.6' \
  "solve-pipeline serializes Ghostty multi-spawn (keystroke race mitigation, sleep 0.6)"
assert_grep "$SOLVE_PIPELINE" \
  'SPAWNED\[@\]|\$\{#SPAWNED\[@\]\}' \
  "solve-pipeline emits a single summary notification (not per-spawn) using SPAWNED array"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCH_FAILED' \
  "Phase B tracks per-issue dispatch failures (no silent partial-batch failures)"
assert_grep "$SOLVE_PIPELINE" \
  'DISPATCH_RC=\$\?' \
  "Phase B captures dispatch exit status after the case statement"
# REAL_CLAUDE detection must be hoisted out of the per-issue loop (cosmetic
# optimization — same value across spawns). Anchor: it appears in Step 3
# (terminal detection) before the Phase B loop.
SP_REAL_CLAUDE_LINE=$(grep -n 'REAL_CLAUDE=\$(' "$SOLVE_PIPELINE" | head -1 | cut -d: -f1)
SP_PHASE_B_LINE=$(grep -n 'for ISSUE_NUM in "\${ISSUE_NUMS\[@\]}"' "$SOLVE_PIPELINE" | tail -1 | cut -d: -f1)
if [[ -n "$SP_REAL_CLAUDE_LINE" && -n "$SP_PHASE_B_LINE" && "$SP_REAL_CLAUDE_LINE" -lt "$SP_PHASE_B_LINE" ]]; then
  echo "  PASS  REAL_CLAUDE resolution hoisted before Phase B loop (line $SP_REAL_CLAUDE_LINE before $SP_PHASE_B_LINE)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  REAL_CLAUDE must be resolved once before the per-issue loop"
  echo "        REAL_CLAUDE line: ${SP_REAL_CLAUDE_LINE:-not found}"
  echo "        Phase B line:    ${SP_PHASE_B_LINE:-not found}"
  FAIL=$((FAIL + 1))
fi

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
echo "== /simplify runs ONCE in the chain — at /review-pr Phase 2, not pre-push =="
# Chain-level invariant: trivial/small heredocs MUST NOT call /simplify standalone
# before push. The canonical simplify pass is Phase 2 of /uberdev:review-pr,
# which sees the post-Phase-1 diff (full PR + review-fix commits) and is
# strictly more complete than any pre-push call. This guard fails loud if a
# future edit re-introduces the duplication. Anchored on the numbered-step form
# (`^[0-9]+\.\s+/simplify before push`) so the regression-prevention prose
# elsewhere in the same file (and the directive added to each heredoc) is not
# matched.
assert_not_grep "$SOLVE_PIPELINE" \
  '^[[:space:]]*[0-9]+\.[[:space:]]+/(uberdev:)?simplify[[:space:]]+before[[:space:]]+push' \
  "no /simplify-before-push numbered step in solve-pipeline heredocs"
# Positive lock: each of the 4 trivial/small heredocs (trivial-solve, trivial-turbo,
# small-solve, small-turbo) must explicitly tell the spawned agent NOT to run
# /simplify standalone. Anchoring the count at 4 catches both deletion and the
# subtler regression where one heredoc loses the directive while three keep it.
# `|| echo "0"` (not `|| true`) — `grep -c` exits 1 when count=0 (expected) but
# exits 2 on real errors (unreadable file, malformed regex); the echo fallback
# keeps the no-match path numeric while letting genuine errors surface via the
# stderr-redirected grep.
DIRECTIVE_COUNT=$(grep -cE 'Do NOT run /uberdev:simplify standalone before push' "$SOLVE_PIPELINE" 2>/dev/null || echo "0")
if [[ "$DIRECTIVE_COUNT" -eq 4 ]]; then
  echo "  PASS  all 4 trivial/small heredocs include the no-pre-push-simplify directive (count=4)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  all 4 trivial/small heredocs include the no-pre-push-simplify directive"
  echo "        file: $SOLVE_PIPELINE"
  echo "        expected count: 4 (trivial-solve, trivial-turbo, small-solve, small-turbo)"
  echo "        actual count:   $DIRECTIVE_COUNT"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REPO_ROOT/plugins/uberdev/commands/simplify.md" \
  'canonical place.*/simplify.*runs.*Phase 2|Phase 2 of .*review-pr' \
  "simplify.md names /review-pr Phase 2 as the canonical simplify run site"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
