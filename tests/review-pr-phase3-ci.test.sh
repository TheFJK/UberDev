#!/usr/bin/env bash
# Functional integration tests for /uberdev:review-pr Phase 3 (CI Health).
# Scenarios 1-9 from spec Test Plan. Each scenario seeds FAKE_GH_MODE,
# invokes the structural-assert helpers against the prose contract, and
# asserts (a) which Task() subagent_type was dispatched and (b) which
# AUDIT_EVENT_ENUM members landed in the audit log.
#
# Note: this suite asserts STRUCTURAL contract presence in the prose
# (commands/review-pr.md + agent files), not runtime behaviour — the
# plugin runtime is the LLM, not bash. The assertions are aggressive
# grep/regex checks that lock every Phase 3 contract surface.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
CLASSIFIER="$REPO_ROOT/plugins/uberdev/agents/ci-failure-classifier.md"
CODE_FIXER_CI="$REPO_ROOT/plugins/uberdev/agents/ci-code-fixer.md"
REBASE_HANDLER="$REPO_ROOT/plugins/uberdev/agents/ci-rebase-handler.md"
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge/SKILL.md"

for f in "$REVIEW_PR" "$CLASSIFIER" "$CODE_FIXER_CI" "$REBASE_HANDLER" "$MERGE_SKILL"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

# Local assert_grep — matches the shape used by tests/review-pr.test.sh.
# The shared helpers in _lib_assert_structural.sh do not include assert_grep
# or assert_no_grep, so we define them here verbatim from the plan.
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

echo "== S1: green-skip fast path — skipped_no_checks → trust signal emitted =="
assert_grep "$REVIEW_PR" 'skipped_no_checks' \
  "S1.1 — skipped_no_checks outcome documented in Phase 3"
assert_grep "$REVIEW_PR" 'no checks reported on the' \
  "S1.2 — gh stderr 'no checks reported on the' empty-array case handled"
assert_grep "$REVIEW_PR" 'Phase 3 outcome.*skipped_no_checks|skipped_no_checks.*green predicate' \
  "S1.3 — skipped_no_checks counts toward GREEN predicate"

echo
echo "== S2: pending → green via MONITOR (no fixer dispatched) =="
assert_grep "$REVIEW_PR" 'gh pr checks.*--watch.*--interval 30' \
  "S2.1 — MONITOR uses --watch --interval 30"
assert_grep "$REVIEW_PR" 'timeout 1200|20[- ]minute.*wall.cap' \
  "S2.2 — MONITOR has 20-minute wall cap (timeout 1200)"
assert_grep "$REVIEW_PR" 'in_progress|pending' \
  "S2.3 — pending state surfaces from PROBE for MONITOR transition"

echo
echo "== S3: pending → red → ci-code-fixer → green (full happy path) =="
assert_subagent_type "$REVIEW_PR" 'ci-code-fixer' \
  "S3.1 — review-pr.md dispatches uberdev:ci-code-fixer (Phase 3 ROUTE)"
assert_grep "$REVIEW_PR" 'green_after_fix' \
  "S3.2 — green_after_fix outcome documented"
assert_grep "$REVIEW_PR" 're-enter Phase 1|re-enter at Step 4|post-fix.*re-enter' \
  "S3.3 — post-fix HEAD re-enters Phase 1 fanout (Q4 invariant)"

echo
echo "== S4: 6 classification paths — classifier dispatched + ROUTE picks correct downstream =="
assert_subagent_type "$REVIEW_PR" 'ci-failure-classifier' \
  "S4.1 — review-pr.md dispatches uberdev:ci-failure-classifier (Phase 3 CLASSIFY)"
for cls in code_bug billing_quota platform_outage flaky env_drift stale_base; do
  assert_grep "$REVIEW_PR" "$cls" \
    "S4.cls.$cls — failure class $cls named in ROUTE prose"
done
assert_subagent_type "$REVIEW_PR" 'ci-rebase-handler' \
  "S4.2 — review-pr.md dispatches uberdev:ci-rebase-handler (stale_base ROUTE)"
assert_grep "$REVIEW_PR" 'gh run rerun' \
  "S4.3 — flaky path uses gh run rerun"
assert_grep "$REVIEW_PR" 'RERUN_FLAKY_CAP' \
  "S4.4 — flaky cap referenced by name (RERUN_FLAKY_CAP)"

echo
echo "== S5: loop-cap exhaustion — 3 iterations → loop_cap_exhausted → exit 1 =="
assert_grep "$REVIEW_PR" 'CI_FIX_LOOP_CAP' \
  "S5.1 — loop cap referenced by name (CI_FIX_LOOP_CAP)"
assert_grep "$REVIEW_PR" 'loop_cap_exhausted' \
  "S5.2 — loop_cap_exhausted outcome documented"
assert_grep "$REVIEW_PR" 'MUST NOT introduce any additional retry path|no extra retry path' \
  "S5.3 — anti-pattern guard against additional retry paths restated"
assert_grep "$REVIEW_PR" 'distinct.*commit SHA|HEAD SHA changed|distinct fix-and-push' \
  "S5.4 — counter increments only on distinct commit SHA change"

echo
echo "== S6: --no-ci-fix probe-only — no fixer/rebase/halt dispatch =="
assert_grep "$REVIEW_PR" 'argument-hint:.*--no-ci-fix|--no-ci-fix.*argument-hint' \
  "S6.1 — --no-ci-fix declared in argument-hint frontmatter"
assert_grep "$REVIEW_PR" 'CI_FIX_PHASE' \
  "S6.2 — CI_FIX_PHASE variable documented (mirrors SIMPLIFY_PHASE)"
assert_grep "$REVIEW_PR" 'CI_FIX_PHASE=0|--no-ci-fix.*probe' \
  "S6.3 — --no-ci-fix sets CI_FIX_PHASE=0 / probe-only"

echo
echo "== S7: --turbo on halt classes — no AskUserQuestion, exit 1, no trust signal =="
assert_grep "$REVIEW_PR" '--turbo.*does NOT (alter|mutate|change).*Phase 1 or Phase 2|Phase 1 or Phase 2.*--turbo' \
  "S7.1 — --turbo prose narrowed to 'Phase 1 or Phase 2' only"
assert_grep "$REVIEW_PR" 'Phase 3 halt classes.*--turbo|--turbo.*halt classes' \
  "S7.2 — Phase 3 halt-class carve-out documented for --turbo"
assert_grep "$REVIEW_PR" 'billing_quota.*platform_outage|platform_outage.*billing_quota' \
  "S7.3 — both halt classes named together in --turbo carve-out"
# S7.4 — no `AskUserQuestion(` call site lives inside the Turbo (--turbo
# present) branch of 6c.6 HALT. The original assertion used a perl-style
# negative lookahead `(?!...)` which is not in ERE — it triggered
# `grep: warning: ? at start of expression` on GNU grep (Linux CI),
# causing a false fail (and falsely passing on macOS BSD grep).
# This awk walk tracks "Turbo" vs "Interactive" subsections in 6c.6 HALT
# and flags any AskUserQuestion( call inside the Turbo region — which
# would defeat the carve-out's "no prompt under --turbo" contract.
S7_4_VIOLATIONS="$(awk '
  /\*\*Turbo \(.--turbo. present\):\*\*/ { in_turbo=1; next }
  /\*\*Interactive \(.--turbo. absent\):\*\*/ { in_turbo=0; next }
  /^### / { in_turbo=0 }
  in_turbo && /AskUserQuestion\(/ { print FILENAME ":" NR ": " $0 }
' "$REVIEW_PR")"
if [ -z "$S7_4_VIOLATIONS" ]; then
  echo "  PASS  S7.4 — --turbo branch does NOT call AskUserQuestion()"; PASS=$((PASS + 1))
else
  echo "  FAIL  S7.4 — --turbo branch contains an AskUserQuestion() call"
  printf '%s\n' "$S7_4_VIOLATIONS" | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi

echo
echo "== S8: gh outage carve-out — ci_probe_unreachable + Step 7 still runs =="
assert_grep "$REVIEW_PR" 'ci_probe_unreachable' \
  "S8.1 — ci_probe_unreachable audit event documented"
assert_grep "$REVIEW_PR" 'phases\.phase3.*omitted|omitted entirely.*gh.*unreachable|carve-out' \
  "S8.2 — phase3 audit JSON omitted on gh-unreachable carve-out"
assert_grep "$REVIEW_PR" 'rate_limit_low|gh api rate_limit' \
  "S8.3 — pre-flight rate-limit check documented (rate_limit_low subreason)"

echo
echo "== S9: 12 new AUDIT_EVENT_ENUM members all referenced in Phase 3 prose =="
for ev in ci_probe_started ci_probe_skipped_no_checks ci_probe_unreachable \
          ci_monitor_green ci_monitor_red ci_monitor_timeout \
          ci_classify_dispatched ci_classify_returned \
          ci_fix_dispatched ci_fix_pushed \
          ci_loop_cap_reached ci_phase_outcome; do
  assert_grep "$REVIEW_PR" "$ev" \
    "S9.$ev — Phase 3 prose references audit event $ev"
done

echo
echo "== S10: ci-failure-classifier agent shape =="
assert_grep "$CLASSIFIER" '^name: ci-failure-classifier$' \
  "S10.1 — frontmatter name"
assert_grep "$CLASSIFIER" '^model: inherit$' \
  "S10.2 — frontmatter model: inherit"
assert_grep "$CLASSIFIER" 'signal_anchor' \
  "S10.3 — return contract emits signal_anchor"
assert_no_grep "$CLASSIFIER" '^.*data\.quote' \
  "S10.4 — no data.quote field in return contract (secret-leak guard)"
assert_grep "$CLASSIFIER" 'CLASSIFIED.*AMBIGUOUS.*REFUSED|status: CLASSIFIED' \
  "S10.5 — refusal triggers + AMBIGUOUS path documented"

echo
echo "== S11: ci-code-fixer agent shape =="
assert_grep "$CODE_FIXER_CI" '^name: ci-code-fixer$' \
  "S11.1 — frontmatter name"
assert_grep "$CODE_FIXER_CI" 'forbidden-pattern' \
  "S11.2 — forbidden-pattern refusal vocabulary present"
assert_grep "$CODE_FIXER_CI" '\-\-no-verify' \
  "S11.3 — --no-verify forbidden pattern documented"
assert_grep "$CODE_FIXER_CI" 'fix\(ci\):.*chore\(deps\):|chore\(deps\):.*fix\(ci\):' \
  "S11.4 — both commit-type prefixes (fix(ci):, chore(deps):) documented"
assert_no_grep "$CODE_FIXER_CI" 'git push' \
  "S11.5 — agent never pushes (caller handles)"

echo
echo "== S12: ci-rebase-handler agent shape =="
assert_grep "$REBASE_HANDLER" '^name: ci-rebase-handler$' \
  "S12.1 — frontmatter name"
assert_grep "$REBASE_HANDLER" 'force-with-lease=' \
  "S12.2 — explicit-form --force-with-lease=<branch>:<sha> documented"
assert_grep "$REBASE_HANDLER" 'force-if-includes' \
  "S12.3 — --force-if-includes paired with lease"
assert_grep "$REBASE_HANDLER" 'flock|ci-rebase\.lock' \
  "S12.4 — worktree lock file documented"
assert_grep "$REBASE_HANDLER" 'pr-already-merged|head-moved-since-classify|lease-mismatch' \
  "S12.5 — refusal triggers documented"

echo
echo "== S13: stale_base CONFLICT-resolve arm (#80) =="
# Issue #80: ci-rebase-handler returns status: CONFLICT, conflicted_files: [...]
# but commands/review-pr.md had no procedural arm to fan out conflict-resolver
# and resume the rebase under the original lease. The capability was tooled
# (ci-rebase-handler.md:57 + agents/conflict-resolver.md exist) but unwired.
# These assertions lock the procedural arm into the prose so a future edit
# can't silently regress it back to "POST-FIX assumes REBASED".
assert_subagent_type "$REVIEW_PR" 'conflict-resolver' \
  "S13.1 — review-pr.md dispatches uberdev:conflict-resolver in Phase 3 CONFLICT path"
assert_grep "$REVIEW_PR" 'conflicted_files' \
  "S13.2 — review-pr.md prose names the conflicted_files YAML field from ci-rebase-handler return"
assert_grep "$REVIEW_PR" 'status: CONFLICT' \
  "S13.3 — review-pr.md prose conditions on status: CONFLICT return"
assert_grep "$REVIEW_PR" 'SINGLE message|single message|single assistant message|single assistant turn|SINGLE assistant turn' \
  "S13.4 — single-message Task() invariant present in CONFLICT-resolve arm"
assert_grep "$REVIEW_PR" 'CONFLICT_RESOLVER_CAP' \
  "S13.5 — CONFLICT_RESOLVER_CAP wave-splitting cap referenced by name"
assert_grep "$REVIEW_PR" 'rebase_conflict_ambiguous' \
  "S13.6 — typed data.subreason rebase_conflict_ambiguous documented"
assert_grep "$REVIEW_PR" 'rebase_conflict_refused' \
  "S13.7 — typed data.subreason rebase_conflict_refused documented"
assert_grep "$REVIEW_PR" 'rebase_lease_mismatch' \
  "S13.8 — typed data.subreason rebase_lease_mismatch documented"
assert_grep "$REVIEW_PR" 'force-with-lease=' \
  "S13.9 — post-resolution push uses explicit-form --force-with-lease=<branch>:<sha>"
assert_grep "$REVIEW_PR" 'force-if-includes' \
  "S13.10 — post-resolution push pairs --force-with-lease with --force-if-includes"
assert_grep "$REVIEW_PR" 'EXPECTED_OLD_SHA' \
  "S13.11 — original-lease SHA name (EXPECTED_OLD_SHA) referenced for resume push"
assert_grep "$REVIEW_PR" 'rebase --continue|git rebase --continue' \
  "S13.12 — RESOLVED path runs git rebase --continue before push"
assert_grep "$REVIEW_PR" 'rebase --abort|git rebase --abort' \
  "S13.13 — AMBIGUOUS / REFUSED arm aborts the in-progress rebase"
assert_grep "$REVIEW_PR" 'merge/SKILL\.md.*Phase 3\.3|Phase 3\.3.*merge/SKILL\.md' \
  "S13.14 — review-pr.md cross-references merge/SKILL.md Phase 3.3 reference pattern"
assert_grep "$REVIEW_PR" 'Phase 3.*halt|halt Phase 3|OUTCOME=halted' \
  "S13.15 — AMBIGUOUS / REFUSED / lease-mismatch surfaces halt-with-OUTCOME=halted"
# Negative-regression guard: POST-FIX must NOT unconditionally assume rebase
# success. The original bug was Step 6c.5 silently falling through to Phase 1
# re-entry on a CONFLICT return. The procedural arm must explicitly gate
# POST-FIX on REBASED (or call the CONFLICT-resolve arm before fix-push).
assert_grep "$REVIEW_PR" 'status: REBASED' \
  "S13.16 — POST-FIX path explicitly conditions on ci-rebase-handler status: REBASED"
assert_grep "$REVIEW_PR" 'by_agent="ci-rebase-handler\+conflict-resolver"' \
  "S13.17 — ci_fix_pushed audit event names both contributing agents on conflict-resolve push success"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
