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
  "subagent-driven-dev references post-impl-review (per-wave invocation)"

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
