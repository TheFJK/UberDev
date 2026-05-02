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
echo "== Aspect arguments listed in Available Review Aspects =="
# Lock the documented bullet shape: bare-word grep would over-match prose;
# anchoring on '**name** -' fails loud if an aspect is dropped from the list.
assert_grep "$REVIEW_PR" '\*\*comments\*\*[[:space:]]+-' "aspect: comments listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*tests\*\*[[:space:]]+-'    "aspect: tests listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*errors\*\*[[:space:]]+-'   "aspect: errors listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*types\*\*[[:space:]]+-'    "aspect: types listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*code\*\*[[:space:]]+-'     "aspect: code listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*simplify\*\*[[:space:]]+-' "aspect: simplify listed in Available Review Aspects"
assert_grep "$REVIEW_PR" '\*\*all\*\*[[:space:]]+-'      "aspect: all listed in Available Review Aspects"

echo
echo "== No-quoting output rule present in each of the 6 reviewer agents =="
for f in "${AGENT_FILES[@]}"; do
  assert_grep "$f" '[Dd]o not quote|[Nn]ever quote|no[ -]quoting' \
    "$(basename "$f"): no-quoting output rule present"
done

echo
echo "== Mandatory simplify pass after review-and-fix loop (#30) =="
# /uberdev:review-pr is a true two-phase command: review fanout + fix loop,
# THEN a mandatory simplify-agent fanout (the three lenses from /simplify),
# THEN a final aggregation. Each assertion below shape-locks one acceptance
# criterion from issue #30.
# Anchor on the ordered arrow form "review fanout → fix loop → simplify
# fanout → final aggregation". The arrows are the load-bearing landmarks —
# without them, any prose mentioning the four words anywhere passes (the
# previous loose alternative was tautological).
assert_grep "$REVIEW_PR" \
  'review fanout.*fix loop.*simplify fanout.*final aggregation' \
  "phase ordering documented (review → fix → simplify → aggregation)"
assert_grep "$REVIEW_PR" \
  '[Cc]ode [Rr]euse|reuse[- ]review|reuse lens' \
  "simplify lens 1: reuse named"
assert_grep "$REVIEW_PR" \
  '[Cc]ode [Qq]uality|quality[- ]review|quality lens' \
  "simplify lens 2: quality named"
assert_grep "$REVIEW_PR" \
  '[Cc]ode [Ee]fficiency|efficiency[- ]review|efficiency lens' \
  "simplify lens 3: efficiency named"
# Case-insensitive collapses SINGLE/single and ONE/one — three alternatives
# instead of six.
if grep -qiE 'simplify.*single message|simplify.*one assistant turn|single message.*simplify' "$REVIEW_PR"; then
  echo "  PASS  simplify-phase agents dispatched in a single message"; PASS=$((PASS + 1))
else
  echo "  FAIL  simplify-phase agents dispatched in a single message"
  echo "        file: $REVIEW_PR"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REVIEW_PR" \
  'separate commit|distinct commit|separately from the review[- ]fix' \
  "auto-applied simplify edits commit separately from review-fix commits"
# Lock the conventional-commit TYPE (refactor:), not just "separately". A change
# from refactor: to chore:/fix:/feat: would otherwise pass the assertion above.
# The pattern requires "refactor:" within scanning distance of "simplify" so the
# bare token doesn't false-positive on unrelated prose mentioning refactor:.
assert_grep "$REVIEW_PR" \
  'simplify.*refactor:|refactor:.*simplify|[Aa]uto-apply simplify.*refactor:' \
  "auto-applied simplify edits commit as refactor: conventional commit"
assert_grep "$REVIEW_PR" \
  '--no-simplify' \
  "--no-simplify opt-out flag documented"
# Anchor advisory routing on the WHERE (Phase 2 / aggregation), not just the
# bare word "advisory" anywhere in the file.
assert_grep "$REVIEW_PR" \
  '[Aa]dvisory[- ]only.*surface|surface in the Phase 2 row|never silently dropped|advisory.*aggregation' \
  "advisory simplify findings appear in final aggregation"
# Anchor non-blocking on Phase 2 / simplify context, not just the bare word
# anywhere in the file.
assert_grep "$REVIEW_PR" \
  '[Ss]implify[- ]phase fanout itself fails|simplify.*do(es)? not undo|[Nn]on-blocking.*simplify|simplify.*[Nn]on-blocking|continues regardless of Phase 2' \
  "non-blocking: simplify-phase failure does not undo review-and-fix"
assert_grep "$REVIEW_PR" \
  'review[- ]phase.*simplify[- ]phase|simplify[- ]phase.*review[- ]phase|review-phase vs simplify-phase|distinguish.*phase' \
  "final aggregation distinguishes review-phase vs simplify-phase findings"

echo
echo "== R1–R6: SHA-bound trust signal (issue #40) =="

# R1 — green-run predicate codified (AC2). Anchor on both phase predicates so
# bare prose mentioning "APPROVE" doesn't false-positive.
assert_grep "$REVIEW_PR" \
  'Phase 1.*APPROVE.*Phase 2.*(ran/APPROVE|skipped)|GREEN.*Phase 1.*APPROVE.*Phase 2' \
  "R1 — green-run predicate prose present"

# R2 — label-emit gh command literal (AC1). Lock the verbatim gh subcommand
# so a future implementer can't quietly switch label-add to a different API.
assert_grep "$REVIEW_PR" \
  'gh pr edit.*--add-label uberdev-approved' \
  "R2 — label-emit gh command literal present"

# R3 — trailer-format prose with verbatim 40-char SHA (AC1, AC13). The
# downstream parser greps this exact form; test pins the literal.
assert_grep "$REVIEW_PR" \
  'Reviewed-by: uberdev/review-pr@' \
  "R3 — trailer-format prefix literal present"
assert_grep "$REVIEW_PR" \
  '40[- ]character|40-char|\[a-f0-9\]\{40\}' \
  "R3.sha-len — full 40-character SHA requirement called out"

# R4 — exit-code table 0 / 1 / 2 (AC3). Three asserts so a partial table
# (e.g. only 0 and 1) fails loudly.
assert_grep "$REVIEW_PR" \
  '\| `0` \|.*GREEN' \
  "R4.exit0 — exit code 0 row present (GREEN)"
assert_grep "$REVIEW_PR" \
  '\| `1` \|.*Phase 1.*(REJECT|REVISIONS_REQUIRED)' \
  "R4.exit1 — exit code 1 row present (REJECT/REVISIONS_REQUIRED)"
assert_grep "$REVIEW_PR" \
  '\| `2` \|.*Phase 2.*blocked' \
  "R4.exit2 — exit code 2 row present (blocked)"

# R5 — :82-83 prose distinguishes skipped (exit 0) from blocked (exit 2)
# (AC12). Anchor the new wording so the old "still exits successfully"
# prose cannot quietly resurface.
assert_grep "$REVIEW_PR" \
  '(ran/APPROVE|skipped).*eligible for green|skipped.*exit 0|blocked.*exit 2' \
  "R5.skipped-vs-blocked — Phase 2 status prose distinguishes skipped vs blocked"
if grep -qE 'still exits successfully' "$REVIEW_PR"; then
  echo "  FAIL  R5.no-old-prose — old 'still exits successfully' prose must be removed"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  R5.no-old-prose — old 'still exits successfully' prose removed"
  PASS=$((PASS + 1))
fi

# R6 — run-id regex constraint cited (AC11). Pin the exact regex so a
# future loosening (e.g. dropping the timestamp prefix) trips the test.
assert_grep "$REVIEW_PR" \
  '\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$' \
  "R6 — run-id regex literal present"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
