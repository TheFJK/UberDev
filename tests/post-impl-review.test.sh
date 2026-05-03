#!/usr/bin/env bash
# Asserts that uberdev:post-impl-review skill exists, dispatches all 5
# reviewer agents in a single message, and is referenced from both the
# /solve trivial/small inline prompt and subagent-driven-dev.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POST_IMPL="$REPO_ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

for f in "$POST_IMPL" "$SOLVE_CMD" "$SUBAGENT_DRIVEN" "$SOLVE_PIPELINE"; do
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

echo "== post-impl-review skill exists with frontmatter =="
assert_grep "$POST_IMPL" '^name: post-impl-review' "frontmatter has name: post-impl-review"

echo
echo "== 5 reviewer agents named in single message =="
assert_grep "$POST_IMPL" 'code-reviewer' "code-reviewer named"
assert_grep "$POST_IMPL" 'code-simplifier|simplifier' "code-simplifier named"
assert_grep "$POST_IMPL" 'silent-failure-hunter' "silent-failure-hunter named"
assert_grep "$POST_IMPL" 'type-design-analyzer' "type-design-analyzer named"
assert_grep "$POST_IMPL" 'comment-analyzer' "comment-analyzer named"
assert_grep "$POST_IMPL" 'single message|SINGLE message|one assistant turn|ONE assistant turn' \
  "single-message-fanout invariant documented"

echo
echo "== Skill referenced from both call sites =="
assert_grep "$SOLVE_PIPELINE" 'post-impl-review|uberdev:post-impl-review' \
  "solve-pipeline skill references post-impl-review (trivial/small inline prompt; gated on AUTO_MODE=0)"
assert_grep "$SUBAGENT_DRIVEN" 'post-impl-review|uberdev:post-impl-review' \
  "subagent-driven-dev references post-impl-review (end-of-issue invocation)"

echo
echo "== End-of-issue post-impl-review wording is canonical in subagent-driven-dev =="
assert_grep "$SUBAGENT_DRIVEN" 'End-of-issue post-impl-review' \
  "subagent-driven-dev step 5 codifies the consolidated end-of-issue invocation"
assert_grep "$SUBAGENT_DRIVEN" 'WAVE.*final|WAVE: .final.' \
  "subagent-driven-dev passes WAVE=final to post-impl-review (drives -wave-final.md filename)"
assert_grep "$SUBAGENT_DRIVEN" 'BASELINE_SHA=.*git rev-parse HEAD' \
  "subagent-driven-dev captures BASELINE_SHA at start of step 4 for robust commit_range"

echo
echo "== Anti-regression: per-wave post-impl-review wording is GONE from subagent-driven-dev wave-loop =="
# Whole-file count of "per-wave" inside the wave-loop region must be 0. The line 311 Red Flag
# uses "post-wave full-test-suite" (different phrase, about the full-test-suite run that stays
# in the loop — unrelated to the relocation), so we anchor on the wave-loop section only.
WAVE_LOOP_REGION=$(awk '/^### High-Level Flow/,/^### Parallel Dispatch Pattern/' "$SUBAGENT_DRIVEN")
# `grep -c` always prints the count to stdout (even 0), but exits 1 on zero matches.
# `|| true` keeps the count clean (avoids "0\n0" from `|| echo 0`) and tolerates the non-zero exit.
WAVE_LOOP_HITS=$(grep -cE "per-wave|after each wave" <<<"$WAVE_LOOP_REGION" || true)
if [[ "$WAVE_LOOP_HITS" -eq 0 ]]; then
  echo "  PASS  per-wave / after-each-wave wording removed from wave-loop region"
  PASS=$((PASS + 1))
else
  echo "  FAIL  per-wave / after-each-wave wording must be 0 in wave-loop region (got $WAVE_LOOP_HITS)"
  FAIL=$((FAIL + 1))
fi

# Obsolete step 5 prose must be fully gone
if grep -qE "per-wave post-impl-review has already covered" "$SUBAGENT_DRIVEN"; then
  echo "  FAIL  obsolete step 5 wording 'per-wave post-impl-review has already covered' must be removed"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  obsolete step 5 wording removed"
  PASS=$((PASS + 1))
fi

echo
echo "== post-impl-review/SKILL.md prose updated for end-of-issue invocation =="
assert_grep "$POST_IMPL" 'end-of-issue from subagent-driven-dev' \
  "frontmatter description names end-of-issue caller"
assert_grep "$POST_IMPL" 'once after all waves complete' \
  "When to invoke section names once-at-end-of-issue semantics"
assert_grep "$POST_IMPL" 'post-impl-review-wave-final\.md' \
  "output artifact docstring names the canonical -final.md filename"
if grep -qE 'after each wave commits' "$POST_IMPL"; then
  echo "  FAIL  obsolete 'after each wave commits' wording must be removed from post-impl-review When-to-invoke"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  obsolete 'after each wave commits' wording removed"
  PASS=$((PASS + 1))
fi

echo
echo "== orchestrator tier-profile table reflects end-of-issue (via SDD) for medium and large =="
ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
if [ ! -r "$ORCHESTRATOR" ]; then
  echo "  FAIL  orchestrator SKILL.md missing or unreadable"
  FAIL=$((FAIL + 1))
else
  # See note above: `|| true` (not `|| echo "0"`) to avoid "0\n0" when grep finds zero matches.
  END_OF_ISSUE_CELLS=$(grep -cE 'end-of-issue \(via SDD\)' "$ORCHESTRATOR" || true)
  if [[ "$END_OF_ISSUE_CELLS" -eq 2 ]]; then
    echo "  PASS  tier-profile table has 2 end-of-issue (via SDD) cells (medium + large)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  tier-profile table must have 2 'end-of-issue (via SDD)' cells (got $END_OF_ISSUE_CELLS)"
    FAIL=$((FAIL + 1))
  fi
  if grep -qE 'per-wave \(via SDD\)' "$ORCHESTRATOR"; then
    echo "  FAIL  obsolete 'per-wave (via SDD)' cells must be removed from tier-profile table"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  obsolete 'per-wave (via SDD)' cells removed"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "== code-simplifier agent self-trigger guard drops 'post-wave' wording =="
CODE_SIMPLIFIER="$REPO_ROOT/plugins/uberdev/agents/code-simplifier.md"
if [ ! -r "$CODE_SIMPLIFIER" ]; then
  echo "  FAIL  code-simplifier.md missing or unreadable"
  FAIL=$((FAIL + 1))
else
  if grep -q "post-wave" "$CODE_SIMPLIFIER"; then
    echo "  FAIL  'post-wave' must be removed from code-simplifier.md self-trigger guard"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  'post-wave' wording removed from code-simplifier.md"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "== Negative guard: turbo (AUTO_MODE==1) trivial+small heredoc BODIES omit post-impl-review (#15) =="
# pr-test-analyzer Gap #1: positive grep above asserts the SKILL references
# post-impl-review somewhere; this asserts the turbo-mode heredoc BODIES don't,
# preserving the spec's documented /solve-vs-/turbo behavioral asymmetry.
# Awk extracts content between `<< EOF` and `EOF` markers inside the AUTO_MODE==1
# (else) branch only — comments outside the heredoc don't count.
TURBO_BODIES=$(awk '
  /^if \[\[ "\$AUTO_MODE" != "1" \]\]; then$/ { in_solve=1; next }
  in_solve && /^else$/ { in_solve=0; in_turbo=1; next }
  in_turbo && /^fi$/ { in_turbo=0; next }
  in_turbo && /<< EOF$/ { in_heredoc=1; next }
  in_turbo && in_heredoc && /^EOF$/ { in_heredoc=0; next }
  in_turbo && in_heredoc { print }
' "$SOLVE_PIPELINE")
if grep -qE 'post-impl-review|uberdev:post-impl-review' <<<"$TURBO_BODIES"; then
  echo "  FAIL  turbo (AUTO_MODE==1) trivial/small heredoc BODIES MUST NOT mention post-impl-review (asymmetry preserved per #15)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  turbo (AUTO_MODE==1) trivial/small heredoc bodies correctly omit post-impl-review"
  PASS=$((PASS + 1))
fi

echo
echo "== Anti-loop guard: skill MUST NOT re-invoke brainstorm or write-plan =="
if grep -qE 'invoke[[:space:]]+(uberdev:)?brainstorm|invoke[[:space:]]+(uberdev:)?write-plan' "$POST_IMPL"; then
  echo "  FAIL  post-impl-review skill must not invoke brainstorm or write-plan"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  post-impl-review skill does not invoke brainstorm or write-plan"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
