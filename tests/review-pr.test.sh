#!/usr/bin/env bash
# Asserts that /uberdev:review-pr names all 6 Phase 1 reviewer dispatch slots
# (5 distinct agent files; code-reviewer is dispatched twice — general lens +
# correctness lens), dispatches them in parallel (single message), exposes the
# documented aspect arguments, plumbs aspect_emphasis + sequential env-var,
# dispatches code-fixer for fix application in both Phase 1 + Phase 2, and
# that each of the 5 distinct agent files contains the no-quoting output rule
# (primary defense against secret leakage into PR bodies).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
AGENTS_DIR="$REPO_ROOT/plugins/uberdev/agents"
# Phase 1 reviewer files — code-simplifier moved to Phase 2 (named lens
# dispatcher per #73), so AGENT_FILES drops it. The simplify.md no-quoting
# assertion lives in tests/simplify.test.sh now (NEW per #73).
AGENT_FILES=(
  "$AGENTS_DIR/code-reviewer.md"
  "$AGENTS_DIR/pr-test-analyzer.md"
  "$AGENTS_DIR/comment-analyzer.md"
  "$AGENTS_DIR/silent-failure-hunter.md"
  "$AGENTS_DIR/type-design-analyzer.md"
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

# Negative-presence helper — mirrors `assert_no_grep` in
# tests/issue-causal-fanout.test.sh. Use for "must NOT match" assertions
# instead of inline `if grep ... ; then FAIL=... else PASS=... fi` blocks.
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

echo "== /uberdev:review-pr command file present with frontmatter =="
assert_grep "$REVIEW_PR" '^description:' "frontmatter has description"
assert_grep "$REVIEW_PR" '^allowed-tools:' "frontmatter has allowed-tools"

echo
# Note: post-#73 the 6 Phase 1 dispatch slots use 5 distinct agent files
# (code-reviewer x2 + pr-test-analyzer + silent-failure-hunter +
# type-design-analyzer + comment-analyzer). code-simplifier is in the
# Phase 2 lens dispatcher block, NOT Phase 1. Anchor on the canonical
# Agent Descriptions section so a bare prose mention elsewhere doesn't
# false-positive.
echo "== Phase 1 reviewer agents named in /uberdev:review-pr =="
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'code-reviewer' "code-reviewer named in Agent Descriptions"
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'pr-test-analyzer' "pr-test-analyzer named in Agent Descriptions (6th reviewer per #73)"
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'comment-analyzer' "comment-analyzer named in Agent Descriptions"
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'silent-failure-hunter' "silent-failure-hunter named in Agent Descriptions"
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'type-design-analyzer' "type-design-analyzer named in Agent Descriptions"
echo
echo "== Phase 2 lens dispatcher named (code-simplifier moved per #73) =="
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'code-simplifier' "code-simplifier named in Agent Descriptions (Phase 2 lens)"
echo
echo "== Apply-loop fixer named (code-fixer NEW per #73) =="
assert_in_section "$REVIEW_PR" '^## Agent Descriptions' '^## Tips' \
  'code-fixer' "code-fixer named in Agent Descriptions (apply-loop fixer)"

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
echo "== No-quoting output rule present in each of the 5 Phase 1 reviewer agents =="
for f in "${AGENT_FILES[@]}"; do
  assert_grep "$f" '[Dd]o not quote|[Nn]ever quote|no[ -]quoting' \
    "$(basename "$f"): no-quoting output rule present"
done
# F1: code-simplifier no-quoting rule has moved to tests/simplify.test.sh
# since it dropped out of AGENT_FILES. The no-quoting rule on code-fixer.md
# (NEW agent) lives in tests/code-fixer-dispatch.test.sh.

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
  '(review fanout|post-impl-review fanout).*fix loop.*simplify fanout.*final aggregation' \
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
# RFC 0002 §3.4 introduced tier-aware labels via $TRUST_LABEL — the assertion
# accepts EITHER the literal `uberdev-approved` form (legacy GREEN-only emission)
# OR the variable `"$TRUST_LABEL"` form (tier-aware GREEN/YELLOW emission post-v0.26.0).
assert_grep "$REVIEW_PR" \
  'gh pr edit.*--add-label uberdev-approved|gh pr edit.*--add-label "\$TRUST_LABEL"' \
  "R2 — label-emit gh command literal present (uberdev-approved OR \$TRUST_LABEL — RFC 0002 tier-aware)"

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
assert_no_grep "$REVIEW_PR" 'still exits successfully' \
  "R5.no-old-prose — old 'still exits successfully' prose removed"

# R6 — run-id regex constraint cited (AC11). Pin the exact regex so a
# future loosening (e.g. dropping the timestamp prefix) trips the test.
assert_grep "$REVIEW_PR" \
  '\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$' \
  "R6 — run-id regex literal present"

echo
echo "== R7: --turbo flag defined as acknowledged no-op (issue #52 Defect 2) =="

assert_grep "$REVIEW_PR" 'argument-hint:.*--turbo' \
  "R7.argument-hint — --turbo flag declared in argument-hint frontmatter"

assert_grep "$REVIEW_PR" '\-\-turbo.*no-op|no-op.*--turbo|acknowledged no-op|forwarder-compatibility.*--turbo' \
  "R7.acknowledged-noop — prose describes --turbo as an acknowledged no-op"

assert_grep "$REVIEW_PR" '[Dd]etect.*--turbo|--turbo.*strip|strip.*--turbo' \
  "R7.detection-strip — Step 1 (Determine Review Scope) detects and strips --turbo from aspect list"

assert_grep "$REVIEW_PR" '\-\-turbo.*does NOT (alter|mutate|change).*Phase 1 or Phase 2' \
  "R7.no-mutation — prose states --turbo does NOT mutate SIMPLIFY_PHASE / Phase 2 behavior"

echo
echo "== R8: Phase 1 invokes Skill(uberdev:post-impl-review) + reads canonical artifact + applies trust-boundary envelope (#67) =="

# R8.1 — Phase 1 invokes the post-impl-review skill via the Skill tool
assert_grep "$REVIEW_PR" \
  'Skill\(uberdev:post-impl-review\)|Skill tool.*uberdev:post-impl-review|uberdev:post-impl-review.*Skill tool' \
  "R8.1 — Phase 1 invokes uberdev:post-impl-review via the Skill tool"

# R8.2 — Phase 1 apply-loop reads the canonical findings artifact
assert_grep "$REVIEW_PR" \
  'post-impl-review-final\.md' \
  "R8.2 — Phase 1 apply-loop reads .uberdev/research/<RUN_ID>/post-impl-review-final.md"

# R8.3 — apply-loop wraps the read content in the trust-boundary envelope
assert_grep "$REVIEW_PR" \
  'external-untrusted-input source="post-impl-review-aggregate"' \
  "R8.3 — apply-loop wraps the read content in <external-untrusted-input source=\"post-impl-review-aggregate\">"

# R8.4 — Phase 1 generates its own RUN_ID (decoupled from any subagent-driven-dev RUN_ID)
assert_grep "$REVIEW_PR" \
  'RUN_ID="\$\(date \+%Y%m%d-%H%M%S\)-\$\(git rev-parse --short HEAD\)"' \
  "R8.4 — Phase 1 mints its own RUN_ID per the canonical /review-pr Run-ID format"

# R8.5 — fallback prose: missing/empty artifact → log warning + continue to Phase 2
assert_grep "$REVIEW_PR" \
  '[Mm]issing or empty.*[Pp]hase 2|all [0-9]+ reviewers returned .BLOCKED.|continue to Phase 2 with' \
  "R8.5 — Phase 1 falls back to Phase 2 with zero auto-applied fixes when artifact is missing/empty"

# R8.6 — separate-commit invariant preserved (Phase 1 fix: vs Phase 2 refactor:)
assert_grep "$REVIEW_PR" \
  'review-phase commits.*distinct from the Phase 2 simplify commit|Phase 1.*fix.*distinct from.*Phase 2|separate-commit invariant' \
  "R8.6 — Phase 1 vs Phase 2 separate-commit invariant preserved"

echo
echo "== R9: trust-trail-anchor empty-commit pattern (post-v0.18.1 — replaces per-simplify-commit trailer + amend) =="

# R9.1 — anchor-commit pattern named in /review-pr Trust-Signal Emission section
assert_grep "$REVIEW_PR" \
  'trust[- ]trail[- ]anchor|trust trail anchor' \
  "R9.1 — trust-trail-anchor commit pattern named"

# R9.2 — anchor commit uses git commit --allow-empty (NOT --amend); regression guard for the
# v0.18.0 trailer-on-simplify-commit bug where the trailer SHA pointed at the parent.
assert_grep "$REVIEW_PR" \
  'git commit --allow-empty' \
  "R9.2 — anchor commit literal git commit --allow-empty present"

# R9.3 — explicit prose that --amend is NEVER used in trust-signal emission so push never
# requires --force-with-lease. Pin the regression-guard prose so a future implementer can't
# silently re-introduce amend-and-force-push.
assert_grep "$REVIEW_PR" \
  '`git commit --amend` is \*\*NEVER\*\* used|amend is \*\*NEVER\*\* used|never requires `--force-with-lease`' \
  "R9.3 — anchor commit explicitly avoids --amend / force-push"

# R9.4 — trailer SHA references the anchor commit's parent (not the anchor's own SHA — the
# chicken-and-egg sidestep). PARENT_SHA capture variable must be the parent of the anchor.
assert_grep "$REVIEW_PR" \
  'PARENT_SHA="\$\(git rev-parse HEAD\)"|trailer pointing at its parent' \
  "R9.4 — trailer SHA captured as parent of the anchor (PARENT_SHA before --allow-empty)"

# R9.5 — anchor commit subject is chore(review-pr): trust trail anchor
assert_grep "$REVIEW_PR" \
  'chore\(review-pr\):.*trust trail anchor' \
  "R9.5 — anchor commit subject is chore(review-pr): trust trail anchor"

# R9.6 — Phase 2 simplify commit body does NOT carry the trailer (regression guard for the
# bug being fixed: trailer-on-simplify-commit landed parent SHA into the trailer body).
assert_grep "$REVIEW_PR" \
  "Phase 2's simplify commit body itself does \*\*NOT\*\* carry the .Reviewed-by:. trailer|simplify commit body itself does NOT carry|simplify commit body does .NOT. carry" \
  "R9.6 — Phase 2 simplify commit body does NOT carry the Reviewed-by trailer"

# R9.7 — anchor-commit failure path is explicit in artifact-emission failure prose
assert_grep "$REVIEW_PR" \
  'anchor commit fails|anchor commit.*fails' \
  "R9.7 — artifact-emission failure prose covers anchor commit failure"

# R9.8 (#78) — ANCHOR_SHA captured AFTER `git push origin HEAD` so the audit JSON `"sha"`
# field can reference the anchor commit's own SHA (== post-emission headRefOid). The
# pre-#78 recipe only named PARENT_SHA, leaving the producer agent to infer which SHA
# went into the JSON; the inferred value drifted, breaking /merge sub-condition (d).
assert_grep "$REVIEW_PR" \
  'ANCHOR_SHA="\$\(git rev-parse HEAD\)"' \
  "R9.8 — ANCHOR_SHA captured after the push (post-emission headRefOid for the audit JSON)"

# R9.9 (#78) — audit JSON `"sha"` field references ${ANCHOR_SHA} explicitly, not the
# pre-#78 ambiguous `<full-40-char-head-sha>` placeholder.
assert_grep "$REVIEW_PR" \
  '"sha":[[:space:]]*"\$\{ANCHOR_SHA\}"' \
  "R9.9 — audit JSON \"sha\" field uses \${ANCHOR_SHA} (post-emission headRefOid), not a placeholder"

# R9.10 (#78) — regression guard against the ambiguous `<full-40-char-head-sha>`
# placeholder that the pre-#78 recipe used. The placeholder must not return.
assert_no_grep "$REVIEW_PR" \
  '<full-40-char-head-sha>' \
  "R9.10 — ambiguous '<full-40-char-head-sha>' placeholder is not present in /review-pr (issue #78)"

# R9.11 (#78) — disambiguation prose: JSON sha is ANCHOR_SHA, NOT PARENT_SHA. The
# trailer payload references PARENT_SHA but the JSON references the anchor itself.
assert_grep "$REVIEW_PR" \
  'NOT[[:space:]]*\$\{PARENT_SHA\}|NOT.*PARENT_SHA|sha.*ANCHOR_SHA.*from artifact 1' \
  "R9.11 — disambiguation prose: JSON sha is ANCHOR_SHA, not PARENT_SHA"

# R9.12 (#79 follow-on) — push-failure guard: the recipe MUST guard `git push origin HEAD`
# with an explicit exit-code check before capturing ANCHOR_SHA. Without the guard, a push
# failure (network, auth, hook rejection) would leave ANCHOR_SHA pointing at a local-only
# HEAD; the audit JSON would then carry a SHA absent from the remote, and `/merge` would
# fail downstream with `trust_trail_agent_invalid_input` (subreason
# `trailer_sha_not_in_local_clone`). The spec at the artifact-emission-failure prose below
# already mandates exit 2 on push failure — this assertion pins the guard's *recipe* form
# so a future edit can't silently regress to a bare `git push origin HEAD` and re-create
# the silent-failure mode. Two-of-two alternatives so a reviewer can choose `if !` or
# `|| exit 2` style without false-failing.
assert_grep "$REVIEW_PR" \
  'if ! git push origin HEAD|git push origin HEAD \|\| .*exit 2' \
  "R9.12 — git push origin HEAD guarded with exit-code check before ANCHOR_SHA capture"

# R9.13 (#79 follow-on) — negative regression guard: the bare `git push origin HEAD` line
# (no guard, no `||`, no preceding `if !`) MUST NOT appear in the trust-signal-emission
# recipe. Anchored on the literal "git push origin HEAD" followed by end-of-line — i.e.,
# the exact pre-#79 unguarded form. With the guard in place, the literal `git push origin
# HEAD` only appears as the predicate inside `if ! git push origin HEAD; then`, so it's
# never EOL-bare. This pin defends against the F1 silent-failure class returning.
assert_no_grep "$REVIEW_PR" \
  '^[[:space:]]*git push origin HEAD[[:space:]]*$' \
  "R9.13 — bare 'git push origin HEAD' (unguarded, EOL-anchored) is not present"

# R9.14 (#79 simplify-pass follow-on) — label-add guard symmetry: artifact 2's
# `gh pr edit <N> --add-label uberdev-approved` MUST be guarded with the same
# `if ! …; then exit 2; fi` form as artifact 1's push guard (R9.12). Without it,
# a label-add failure (network, auth, rate limit, label-permission denial) leaves
# bash continuing silently while the audit JSON gets written; `/merge` Phase 1.4
# PATH_2 sub-condition (a) then fails downstream with `trust_trail_label_missing`.
# The spec at the artifact-emission-failure prose mandates exit 2 on `label add
# fails` — this assertion pins the guard's *recipe* form so a future edit can't
# silently regress to a bare `gh pr edit` and re-create the F1 silent-failure
# class. Two-of-two alternatives (`if !` or `|| exit 2`) so a reviewer can
# choose either style without false-failing.
# R9.14 — accepts either the legacy literal-label form OR the v0.26.0+
# tier-aware `$TRUST_LABEL` form (RFC 0002 §3.4 introduced GREEN/YELLOW tier
# labels via the same $TRUST_LABEL variable). Both forms must remain guarded
# by `if ! ... ; then exit 2; fi` per the artifact-emission-failure prose.
assert_grep "$REVIEW_PR" \
  'if ! gh pr edit.*--add-label uberdev-approved|gh pr edit.*--add-label uberdev-approved \|\| .*exit 2|if ! gh pr edit.*--add-label "\$TRUST_LABEL"|gh pr edit.*--add-label "\$TRUST_LABEL" \|\| .*exit 2' \
  "R9.14 — gh pr edit --add-label (uberdev-approved OR \$TRUST_LABEL) guarded with exit-code check (label-add symmetry to R9.12 push guard)"

# R9.15 (#79 simplify-pass follow-on) — negative regression guard: the bare
# `gh pr edit <N> --add-label uberdev-approved` line (no guard, no `||`, no
# preceding `if !`) MUST NOT appear at end-of-line in the trust-signal-emission
# recipe. With the guard in place from R9.14, the literal command only appears
# as the predicate inside `if ! gh pr edit …; then`, so it's never EOL-bare in
# a recipe block. The recipe-bullet prose (line ~441) still describes the
# command in inline-code form (followed by parenthetical "(idempotent — …)"),
# which is anchored on `(idempotent` and excluded from this regex. This pin
# defends against the F1 silent-failure class returning to artifact 2.
assert_no_grep "$REVIEW_PR" \
  '^[[:space:]]*gh pr edit <N> --add-label uberdev-approved[[:space:]]*$' \
  "R9.15 — bare 'gh pr edit <N> --add-label uberdev-approved' (unguarded, EOL-anchored, recipe form) is not present"

# R9.16 (#170) — trust-label provisioning. `gh pr edit --add-label` CANNOT
# auto-create a repo label and exits non-zero when it is missing, so on a fresh
# repo the GREEN/YELLOW trust-signal emission aborts at the --add-label (exit 2).
# The fix provisions $TRUST_LABEL via a fail-loud `gh label create --force`
# immediately before the add (same assume-label-exists class as #168). Assert
# the fail-loud provisioning is present AND the per-tier colour is set.
assert_grep "$REVIEW_PR" \
  'if ! gh label create --force "\$TRUST_LABEL" --color "\$TRUST_LABEL_COLOR"' \
  "R9.16 (#170) — trust label provisioned fail-loud via gh label create --force before --add-label"
assert_grep "$REVIEW_PR" \
  'TRUST_LABEL_COLOR="0E8A16"' \
  "R9.16b (#170) — per-tier TRUST_LABEL_COLOR set in the TRUST_LABEL case (GREEN=0E8A16)"

echo
echo "== R10 (#73): Sequential argument honored — env-var export + stderr notice =="

# R10.1 — sequential token detection in Step 1 / Argument Parsing block
assert_grep "$REVIEW_PR" '\bsequential\b.*ASPECT_LIST|ASPECT_LIST.*\bsequential\b|Detect .sequential. token|SEQUENTIAL=1' \
  "R10.1 — Step 1 detects the bare 'sequential' token and sets SEQUENTIAL"
# R10.2 — env-var export (the load-bearing behavioral effect)
assert_grep "$REVIEW_PR" 'export UBERDEV_FANOUT_POST_IMPL_REVIEW=1' \
  "R10.2 — sequential exports UBERDEV_FANOUT_POST_IMPL_REVIEW=1"
# R10.3 — stderr notice (the user-visible half — sequential-must-be-visible invariant)
assert_grep "$REVIEW_PR" 'notice: running post-impl-review sequentially via UBERDEV_FANOUT_POST_IMPL_REVIEW=1' \
  "R10.3 — sequential emits stderr notice on user terminal"
# R10.4 — old warn-and-continue prose removed (anti-regression)
assert_no_grep "$REVIEW_PR" 'Phase 1 still runs in parallel because the skill.s single-message contract is invariant' \
  "R10.4 — old 'still runs in parallel' warn-and-continue prose removed"

echo
echo "== R11 (#73): aspect_emphasis plumbing — Step 1 capture → Skill input → brief =="

# R11.1 — ASPECT_LIST captured in Step 1
assert_grep "$REVIEW_PR" 'ASPECT_LIST' \
  "R11.1 — Step 1 captures ASPECT_LIST from arguments"
# R11.2 — aspect_emphasis passed to Skill() in Step 4
assert_grep "$REVIEW_PR" 'aspect_emphasis=\$ASPECT_LIST|aspect_emphasis: \$ASPECT_LIST|aspect_emphasis,' \
  "R11.2 — Step 4 passes aspect_emphasis to Skill(uberdev:post-impl-review)"
# R11.3 — emphasis-section prose
assert_grep "$REVIEW_PR" '## Emphasis|## Additional Focus|aspect_emphasis' \
  "R11.3 — emphasis subsection plumbing prose present"
# R11.4 — single-message-fanout invariant explicitly preserved (aspect filters never gate)
assert_grep "$REVIEW_PR" 'always fan out|single-message-fanout invariant.*emphasis is advisory|emphasis is advisory, never gating' \
  "R11.4 — invariant preserved: aspect filters never gate dispatch"

echo
echo "== R12 (#73): code-fixer dispatched in Phase 1 (Step 5) AND Phase 2 (Step 6b) =="

# R12.1 — code-fixer dispatched at all
assert_subagent_type "$REVIEW_PR" 'code-fixer' \
  "R12.1 — review-pr.md dispatches uberdev:code-fixer (subagent_type)"
# R12.2 — count: at least 2 distinct subagent_type: uberdev:code-fixer references (Phase 1 + Phase 2)
CODE_FIXER_DISPATCH_COUNT=$(grep -cE 'subagent_type: uberdev:code-fixer' "$REVIEW_PR" || true)
if [[ "$CODE_FIXER_DISPATCH_COUNT" -ge 2 ]]; then
  echo "  PASS  R12.2 — code-fixer dispatched ≥ 2 times (Phase 1 + Phase 2 sites; got $CODE_FIXER_DISPATCH_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  R12.2 — code-fixer must be dispatched in Phase 1 + Phase 2 (≥ 2 subagent_type references; got $CODE_FIXER_DISPATCH_COUNT)"
  FAIL=$((FAIL + 1))
fi
# R12.3 — Phase 1 commit_type_prefix is fix:
assert_grep "$REVIEW_PR" 'commit_type_prefix=fix:|commit_type_prefix: fix:' \
  "R12.3 — Phase 1 code-fixer dispatch carries commit_type_prefix=fix:"
# R12.4 — Phase 2 commit_type_prefix is refactor: (locked by R8.6)
assert_grep "$REVIEW_PR" 'commit_type_prefix=refactor:|commit_type_prefix: refactor:' \
  "R12.4 — Phase 2 code-fixer dispatch carries commit_type_prefix=refactor: (R8.6 invariant)"
# R12.5 — phase= argument
assert_grep "$REVIEW_PR" 'phase=phase1' \
  "R12.5 — Phase 1 code-fixer dispatch carries phase=phase1"
assert_grep "$REVIEW_PR" 'phase=phase2' \
  "R12.6 — Phase 2 code-fixer dispatch carries phase=phase2"

echo
echo "== R13 (#73): Phase 2 lens dispatch uses subagent_type: uberdev:code-simplifier =="

# R13.1 — Phase 2 carries the named subagent_type
assert_subagent_type "$REVIEW_PR" 'code-simplifier' \
  "R13.1 — review-pr.md Phase 2 dispatch uses subagent_type: uberdev:code-simplifier"
# R13.2 — ## Lens emphasis: prose present (the parameterisation mechanism)
assert_grep "$REVIEW_PR" '## Lens emphasis:' \
  "R13.2 — Phase 2 documents ## Lens emphasis subsection (Reuse|Quality|Efficiency)"

echo
echo "== R14: Phase 3 inline block exists in /review-pr.md (#76) =="
assert_grep "$REVIEW_PR" '^## .*Phase 3|Step 6c|6c\.[0-9]' \
  "R14 — Phase 3 / Step 6c heading present"

echo
echo "== R15: GREEN predicate gains Phase 3 outcome conjunct (#76) =="
assert_grep "$REVIEW_PR" 'Phase 3 outcome.*green.*green_after_fix.*skipped_no_checks|green.*green_after_fix.*skipped_no_checks.*Phase 3' \
  "R15.1 — Phase 3 outcome ∈ {green, green_after_fix, skipped_no_checks} present in GREEN predicate"
assert_no_grep "$REVIEW_PR" '^GREEN := \(Phase 1 verdict == "APPROVE"\) AND \(Phase 2 status .* \{"ran/APPROVE", "skipped"\}\)$' \
  "R15.2 — old 2-conjunct GREEN predicate removed (no bare 2-conjunct line)"

echo
echo "== R16: --no-ci-fix documented in argument table + frontmatter (#76) =="
assert_grep "$REVIEW_PR" 'argument-hint:.*--no-ci-fix' \
  "R16.1 — --no-ci-fix in frontmatter argument-hint"
assert_grep "$REVIEW_PR" '\| `CI_FIX_PHASE` \|' \
  "R16.2 — CI_FIX_PHASE row present in Argument Parsing Summary table"
assert_grep "$REVIEW_PR" '[Dd]etect.*--no-ci-fix|--no-ci-fix.*strip|strip.*--no-ci-fix' \
  "R16.3 — --no-ci-fix detection + strip step documented (mirrors --no-simplify)"

echo
echo "== R17: exit-code contract reuses 1 for Phase 3 halts (#76) =="
assert_grep "$REVIEW_PR" 'Phase 3 outcome.*halted|halted.*loop_cap_exhausted' \
  "R17.1 — exit-1 row mentions Phase 3 halted/loop_cap_exhausted outcomes"
assert_no_grep "$REVIEW_PR" '\| `3` \|' \
  "R17.2 — no new exit code 3 row introduced (Q2 decision: reuse 1)"

echo
echo "== R18: --turbo prose narrows scope to Phase 1 or Phase 2 only (#76) =="
assert_grep "$REVIEW_PR" '--turbo.*does NOT (alter|mutate|change).*Phase 1 or Phase 2|Phase 1 or Phase 2.*--turbo' \
  "R18.1 — --turbo no-op narrowed to 'Phase 1 or Phase 2'"
assert_grep "$REVIEW_PR" 'Phase 3 halt classes.*billing_quota.*platform_outage|billing_quota.*platform_outage.*Phase 3' \
  "R18.2 — Phase 3 halt-class carve-out documented (billing_quota + platform_outage)"

echo
echo "== R19: merge-pipeline/SKILL.md AUDIT_EVENT_ENUM gains 12 new Phase 3 members (#76) =="
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
for ev in ci_probe_started ci_probe_skipped_no_checks ci_probe_unreachable \
          ci_monitor_green ci_monitor_red ci_monitor_timeout \
          ci_classify_dispatched ci_classify_returned \
          ci_fix_dispatched ci_fix_pushed \
          ci_loop_cap_reached ci_phase_outcome; do
  assert_grep "$MERGE_SKILL" "$ev" \
    "R19.$ev — AUDIT_EVENT_ENUM declares \`$ev\`"
done

echo
echo "== R20: merge-pipeline/SKILL.md Constants table declares the new CI_*_ENUM rows (#76) =="
assert_grep "$MERGE_SKILL" '\| `CI_STATUS_ENUM` \|' \
  "R20.1 — CI_STATUS_ENUM row present"
assert_grep "$MERGE_SKILL" '\| `CI_FAILURE_CLASS_ENUM` \|' \
  "R20.2 — CI_FAILURE_CLASS_ENUM row present"
assert_grep "$MERGE_SKILL" '\| `CI_OUTCOME_ENUM` \|' \
  "R20.3 — CI_OUTCOME_ENUM row present"
assert_grep "$MERGE_SKILL" '\| `CI_FIX_LOOP_CAP` \|' \
  "R20.4 — CI_FIX_LOOP_CAP row present (value 3)"
assert_grep "$MERGE_SKILL" '\| `RERUN_FLAKY_CAP` \|' \
  "R20.5 — RERUN_FLAKY_CAP row present (value 1)"
assert_grep "$MERGE_SKILL" '`code_bug`.*`billing_quota`.*`platform_outage`.*`flaky`.*`env_drift`.*`stale_base`' \
  "R20.6 — CI_FAILURE_CLASS_ENUM lists all 6 classes in canonical order"

echo "== R21: review-pr Trust-Signal Emission clears review-pr:pending label (#95) =="

# R21.1 — gh pr edit --remove-label review-pr:pending is present somewhere in review-pr.md
assert_grep "$REVIEW_PR" \
  'gh pr edit .*--remove-label review-pr:pending' \
  "R21.1 — gh pr edit --remove-label review-pr:pending present in review-pr.md (#95 spec C2)"

# R21.2 — prose paragraph references the named constant REVIEW_PR_PENDING_LABEL
assert_grep "$REVIEW_PR" \
  'REVIEW_PR_PENDING_LABEL' \
  "R21.2 — prose paragraph references REVIEW_PR_PENDING_LABEL constant by name (#95 spec C4)"

# R21.3 — the new remove-label block is fail-soft (no exit-2 guard around it)
# This is intentional per D4 — /uberdev:review-pr may be invoked directly outside
# a finish-branch chain, in which case the pending label legitimately does not exist.
# Negative shape-lock: extract the new bash block via line-range and assert no `exit 2`.
REMOVE_START=$(grep -n 'New (#95): clear the review-pr:pending backstop label' "$REVIEW_PR" | head -1 | cut -d: -f1)
REMOVE_END=$(awk -v s="$REMOVE_START" 'NR > s && /^[[:space:]]*fi$/ { print NR; exit }' "$REVIEW_PR")
if [[ -n "$REMOVE_START" && -n "$REMOVE_END" ]]; then
  EXIT2_COUNT=$(sed -n "${REMOVE_START},${REMOVE_END}p" "$REVIEW_PR" | grep -cE '^[[:space:]]*exit[[:space:]]+2')
  if [[ "$EXIT2_COUNT" -eq 0 ]]; then
    echo "  PASS  R21.3 — --remove-label block is fail-soft (no exit-2 guard; intentional per D4)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  R21.3 — --remove-label block MUST NOT use exit 2; found $EXIT2_COUNT exit-2 statement(s)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  R21.3 — could not locate --remove-label block (REMOVE_START=$REMOVE_START REMOVE_END=$REMOVE_END)"
  FAIL=$((FAIL + 1))
fi

# R21.4 — line order: the new --remove-label is in the Trust-Signal Emission section,
# which is after line 525 (## Trust-Signal Emission) and before line ~621 (## Exit-Code Contract).
L_REMOVE=$(grep -n -- '--remove-label review-pr:pending' "$REVIEW_PR" | head -1 | cut -d: -f1)
L_TS_HEADING=$(grep -n -E '^## Trust-Signal Emission' "$REVIEW_PR" | head -1 | cut -d: -f1)
L_EXIT_CODE_HEADING=$(grep -n -E '^## Exit-Code Contract' "$REVIEW_PR" | head -1 | cut -d: -f1)
if [[ -n "$L_REMOVE" && -n "$L_TS_HEADING" && -n "$L_EXIT_CODE_HEADING" && "$L_REMOVE" -gt "$L_TS_HEADING" && "$L_REMOVE" -lt "$L_EXIT_CODE_HEADING" ]]; then
  echo "  PASS  R21.4 — --remove-label is inside Trust-Signal Emission section (TS=$L_TS_HEADING < REMOVE=$L_REMOVE < ExitCode=$L_EXIT_CODE_HEADING)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  R21.4 — --remove-label MUST be inside Trust-Signal Emission section (TS=$L_TS_HEADING REMOVE=$L_REMOVE ExitCode=$L_EXIT_CODE_HEADING)"
  FAIL=$((FAIL + 1))
fi

# T1 — GREEN/YELLOW/RED predicate prose (RFC 0002 — locks Trust-Signal Emission)
# Anchor pair: ^## Trust-Signal Emission … ^## Exit-Code Contract (canonical
# per spec-reviewer Minor #1; the file has no ^## Inputs heading so the
# alternative anchor in the spec is unusable).
#
# Temporarily disable `pipefail` around T1/T2: the shared `assert_in_section`
# helper pipes `awk` to `grep -qE`, and `grep -q` exits early on first match.
# With pipefail on, awk receives SIGPIPE on its next write, the pipeline reports
# 141, and the helper's `if … ; then PASS else FAIL` branch takes FAIL even when
# the match was found. The Trust-Signal Emission section is ~239 lines (well
# larger than other sections previously asserted), so awk's buffered output
# almost always still has bytes to flush when grep exits — the race is
# deterministic, not flaky. Disabling pipefail for this block restores the
# helper's intended "did grep find it?" semantics without modifying the shared
# helper (which is co-owned by other parallel-task test files).
PIPEFAIL_PREV_T1T2=$(set -o | awk '/^pipefail/ {print $2}')
set +o pipefail
echo
echo "== T1: GREEN/YELLOW/RED predicate prose locks =="

# T1.1 — YELLOW predicate names by_severity.critical > 0 as the YELLOW signal
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'YELLOW.*by_severity\.critical.*>.*0|by_severity\.critical.*>.*0.*YELLOW' \
  "T1.1 — YELLOW predicate names by_severity.critical > 0"

# T1.2 — RED predicate is "NOT GREEN AND NOT YELLOW"
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'RED.*NOT GREEN.*NOT YELLOW|RED.*:=.*NOT GREEN' \
  "T1.2 — RED predicate is NOT GREEN AND NOT YELLOW (RFC 0002 §3.4)"

# T1.3 — OVERRIDE_GREEN predicate references PHASE2_5_HALT_CHOICE == "override"
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'OVERRIDE_GREEN.*PHASE2_5_HALT_CHOICE.*override|PHASE2_5_HALT_CHOICE.*override.*OVERRIDE_GREEN' \
  "T1.3 — OVERRIDE_GREEN predicate names PHASE2_5_HALT_CHOICE == \"override\" (RFC 0002 §3.5)"

# T1.4 — sole-cause rationale: override only suppresses RED when phase2_5 is
# the SOLE failing precondition.
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'SOLE cause|sole cause|sole_cause|phase2_5_only|would_have_been_RED_due_to_phase2_5_only' \
  "T1.4 — OVERRIDE_GREEN rationale documents sole-cause restriction (RFC 0002 §3.5)"

# T1.5 — tombstone: GREEN predicate explicitly requires critical == 0
# (constraints [hard] — GREEN requires critical == 0 to be syntactically
# mutually exclusive with YELLOW). Pattern allows either form `by_severity.critical`
# or the bare `critical` (the prose at the disambiguation paragraph uses the bare
# form: "GREEN explicitly requires `critical == 0`").
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'GREEN.*critical.*==.*0|critical.*==.*0.*GREEN' \
  "T1.5 — GREEN predicate requires critical == 0 (constraints [hard]; tombstone)"

echo
echo "== T2: phases.phase2_5 audit JSON block schema lock =="

# T2.1 — phases.phase2_5 named
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'phases\.phase2_5' \
  "T2.1 — phases.phase2_5 block is named in Trust-Signal prose"

# T2.2 — by_severity sub-object enumerates blocker, critical, major. Split into
# three separate assertions so the test actually enforces enumeration of all
# three keys (the prior alternation pattern passed if ANY one was named).
# Patterns accept either dot-form (`by_severity.<key>`) which appears in the
# predicate prose, OR JSON-quoted form (`"<key>":`) which appears in the
# audit-JSON block — both forms enumerate the key within the section.
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'by_severity.*blocker|"blocker":' \
  "T2.2a — phases.phase2_5.by_severity enumerates blocker"
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'by_severity.*critical|"critical":' \
  "T2.2b — phases.phase2_5.by_severity enumerates critical"
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'by_severity.*major|"major":' \
  "T2.2c — phases.phase2_5.by_severity enumerates major"

# T2.3 — halted field is documented
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'halted' \
  "T2.3 — phases.phase2_5.halted field is documented"

# T2.4 — override_reason field present with null baseline + user-selected value
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'override_reason' \
  "T2.4 — phases.phase2_5.override_reason field is documented"
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'user-selected-emit-green-on-blocker-deferred' \
  "T2.4b — override_reason value 'user-selected-emit-green-on-blocker-deferred' documented (RFC 0002 §3.5)"

# T2.5 — staleness prose
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'legacy audit JSON|pre-v0\.26\.0|STALE' \
  "T2.5 — staleness prose names legacy audit JSON without phase2_5 block as STALE"

# T2.6 — tombstone: phases.phase2_5 block must be present on every run where
# Phase 2.5 was reachable (constraints [hard]).
assert_in_section "$REVIEW_PR" '^## Trust-Signal Emission' '^## Exit-Code Contract' \
  'phase2_5.*reachable|Phase 2\.5 was reachable|phases\.phase2_5 block.*present' \
  "T2.6 — phases.phase2_5 block MUST be present on every run where Phase 2.5 was reachable (constraints [hard]; tombstone)"

# Restore pipefail to its pre-T1/T2 setting so a future appended block that
# relies on the file-wide `set -o pipefail` (line 11) sees the same shell
# options it expects.
if [ "$PIPEFAIL_PREV_T1T2" = "on" ]; then set -o pipefail; fi

echo
echo "== R23 (#286): Phase 2 (Step 6) lens dispatch wraps the diff in a pr-diff envelope (#271 follow-up) =="
# The Phase 2 lens dispatch passes the post-Phase-1 diff (`<<base_brief>>`) to
# all three uberdev:code-simplifier lenses inline. The diff is attacker-controllable
# (issue author → PR author) so it MUST be wrapped in
# <external-untrusted-input source="pr-diff">…</external-untrusted-input> per the
# orchestrator trust-boundary convention — mirroring the Phase-1 reviewer wrap in
# skills/post-impl-review/SKILL.md Step 1 (#271). Scope the open+close asserts to
# the lens-dispatch region (Phase 2 heading → the Step-6b "Auto-apply" marker) via
# awk range so they cannot be satisfied by the OTHER untrusted-input close tags in
# this file (the Step-6b `source="post-impl-review-aggregate"` aggregate→fixer wrap
# below, or the Phase-1 / Phase-3 envelopes) — which would make the close-tag assert
# a false PASS even if the lens-dispatch wrap were reverted. The trusted
# `## Lens emphasis:` directive stays OUTSIDE the envelope (only the diff is untrusted).
if ! grep -qE '^6\. \*\*Phase 2 — Mandatory Simplify Pass\*\*' "$REVIEW_PR" \
   || ! grep -qF 'Auto-apply simplify edits — Step 6b' "$REVIEW_PR"; then
  echo "  FAIL  setup error: Phase 2 heading / Step-6b 'Auto-apply' anchors not found in $REVIEW_PR — section renamed? Update the awk range in tests/review-pr.test.sh."
  FAIL=$((FAIL + 1))
else
  PHASE2_LENS_REGION=$(awk '/^6\. \*\*Phase 2 — Mandatory Simplify Pass\*\*/{f=1} f; /Auto-apply simplify edits — Step 6b/{f=0}' "$REVIEW_PR")
  if grep -qF '<external-untrusted-input source="pr-diff">' <<<"$PHASE2_LENS_REGION"; then
    echo "  PASS  R23.1 — Phase 2 lens dispatch opens an <external-untrusted-input source=\"pr-diff\"> envelope around the diff"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  R23.1 — Phase 2 lens dispatch must wrap <<base_brief>> in an <external-untrusted-input source=\"pr-diff\"> envelope (#286)"
    FAIL=$((FAIL + 1))
  fi
  if grep -qF '</external-untrusted-input>' <<<"$PHASE2_LENS_REGION"; then
    echo "  PASS  R23.2 — Phase 2 lens dispatch closes the <external-untrusted-input> envelope (inside the lens-dispatch region)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  R23.2 — Phase 2 lens dispatch must close the pr-diff <external-untrusted-input> envelope inside the lens-dispatch region (#286)"
    FAIL=$((FAIL + 1))
  fi
  # R23.3 — pin the load-bearing DISPATCH-LINE form (`prompt: <external-untrusted-input
  # source="pr-diff">…<<base_brief>>`) so a prose-only mention that left the actual
  # Task() prompt unwrapped cannot false-PASS the region asserts above.
  if grep -qF 'prompt: <external-untrusted-input source="pr-diff">' <<<"$PHASE2_LENS_REGION"; then
    echo "  PASS  R23.3 — the Task() prompt line itself opens the pr-diff envelope before <<base_brief>>"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  R23.3 — the Task() 'prompt:' line must open <external-untrusted-input source=\"pr-diff\"> before <<base_brief>> (not prose-only) (#286)"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
