#!/usr/bin/env bash
# Tests for /uberdev:review-pr Phase 3 (CI Health). Two layers:
#
#   STRUCTURAL (S1-S14): aggressive grep/regex checks that lock every Phase 3
#     contract surface in the prose (commands/review-pr.md + agent files). The
#     plugin "runtime" is the LLM reading that prose, so these assert that the
#     load-bearing tokens, audit-event names, and dispatch shapes are present.
#
#   RUNTIME (S15): exercises the Phase-3 6c.1 PROBE bucket-classification
#     contract for real. It prepends tests/_fixtures/fake-gh to PATH, sets
#     FAKE_GH_MODE per scenario, runs `gh pr checks ... --json name,state,bucket`
#     exactly as review-pr.md specifies, then applies the *prose's own* jq
#     verdict expression (extracted live from review-pr.md, so the test can
#     never drift from the documented logic) and asserts the resulting verdict.
#     It also locks the gh >= 2.83.1 field contract: probe output carries
#     name/state/bucket and NEVER the removed status/conclusion fields.
#
# The fake `gh` is required because the real one is unavailable in CI sandboxes
# (and we never make network calls in unit tests).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_PR="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
CLASSIFIER="$REPO_ROOT/plugins/uberdev/agents/ci-failure-classifier.md"
CODE_FIXER_CI="$REPO_ROOT/plugins/uberdev/agents/ci-code-fixer.md"
REBASE_HANDLER="$REPO_ROOT/plugins/uberdev/agents/ci-rebase-handler.md"
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"

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
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

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
echo "== S7.5 (#97): hybrid TURBO detector — env-var path documented =="
assert_grep "$REVIEW_PR" \
  'UBERDEV_TURBO' \
  "S7.5 — review-pr documents UBERDEV_TURBO env-var as hybrid OR with --turbo arg"

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
assert_grep "$REVIEW_PR" 'review_validate_ci_classification' \
  "S10.6 — controller validates classifier output before routing"
assert_grep "$REVIEW_PR" 'ci_classify_returned.*contract_invalid' \
  "S10.7 — invalid class/anchor fails closed with an audit event"
assert_grep "$REVIEW_PR" 'gh-run-.*\[1-9\].*signal_anchor|signal_anchor.*positive integer' \
  "S10.8 — blank and zero-line signal anchors are rejected"
assert_grep "$REVIEW_PR" 'CI_REFUSED_AGGREGATE_PATH.*RESEARCH_DIR_ABS/ci-refused-synthetic' \
  "S10.9 — CI refusal aggregate stays inside the run research directory"
assert_no_grep "$REVIEW_PR" 'tmp-synthetic-aggregate|freshly-created `mktemp`' \
  "S10.10 — CI refusal handoff no longer points at a system mktemp artifact"
assert_grep "$REVIEW_PR" 'review_child_result_path.*ci-classify\.launched.*review_pr\.ci\.classify' \
  "S10.10a — classifier validation resolves the routed child's canonical result ledger"
assert_no_grep "$REVIEW_PR" 'CI_CLASSIFICATION_PATH="\$RESEARCH_DIR_ABS/ci-classification-' \
  "S10.10b — classifier validation does not read an artifact no child writes"
assert_grep "$REVIEW_PR" 'os\.write\(fd,payload\)' \
  "S10.10c — refusal aggregate serializes a concrete envelope and finding row"

CLASSIFY_HELPER="$(mktemp)"
CLASSIFY_CASE="$(mktemp)"
awk '
  /^[[:space:]]*review_validate_ci_classification\(\) \{/ { capture=1 }
  capture { print }
  capture && /^[[:space:]]*\}$/ { exit }
' "$REVIEW_PR" > "$CLASSIFY_HELPER"
printf 'status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: README.md:42\n' > "$CLASSIFY_CASE"
CLASSIFY_SPLIT="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_SPLIT" = $'CLASSIFIED\tcode_bug\tREADME.md:42\t-' ]; then
  echo "  PASS  S10.11 — valid classifier output survives the controller read boundary"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.11 — valid classifier output failed the controller read boundary: $CLASSIFY_SPLIT"; FAIL=$((FAIL + 1))
fi
CLASSIFY_INVALID=0
for invalid_anchor in ':121' 'file:0' '/absolute:1' '../README.md:1' 'missing.ts:1' ''; do
  printf 'status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: %s\n' "$invalid_anchor" > "$CLASSIFY_CASE"
  if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
    CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
  fi
done
printf 'status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: gh-run-123:42\n' > "$CLASSIFY_CASE"
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
fi
printf 'status: CLASSIFIED\nfailure_class: unknown\nsignal_anchor: file.ts:12\n' > "$CLASSIFY_CASE"
if bash -c '. "$1"; review_validate_ci_classification "$2" "$3" >/dev/null' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT"; then
  CLASSIFY_INVALID=$((CLASSIFY_INVALID + 1))
fi
printf 'status: AMBIGUOUS\nfailure_class: null\nsignal_anchor: null\n' > "$CLASSIFY_CASE"
CLASSIFY_AMBIGUOUS="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
printf 'status: REFUSED\nfailure_class: null\nsignal_anchor: null\nrationale: input-malformed\n' > "$CLASSIFY_CASE"
CLASSIFY_REFUSED="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
printf 'status: CLASSIFIED\nfailure_class: flaky\nsignal_anchor: gh-run-123:42\n' > "$CLASSIFY_CASE"
CLASSIFY_TELEMETRY="$(bash -c '. "$1"; review_validate_ci_classification "$2" "$3"' _ "$CLASSIFY_HELPER" "$CLASSIFY_CASE" "$REPO_ROOT")"
if [ "$CLASSIFY_INVALID" -eq 0 ]; then
  echo "  PASS  S10.12 — blank, malformed, zero-line, and unknown classifier outputs fail closed"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.12 — $CLASSIFY_INVALID invalid classifier outputs were accepted"; FAIL=$((FAIL + 1))
fi
if [ "$CLASSIFY_AMBIGUOUS" = $'AMBIGUOUS\tflaky\t-\t-' ] \
    && [ "$CLASSIFY_REFUSED" = $'REFUSED\t-\t-\tinput-malformed' ] \
    && [ "$CLASSIFY_TELEMETRY" = $'CLASSIFIED\tflaky\tgh-run-123:42\t-' ]; then
  echo "  PASS  S10.13 — explicit ambiguous, refused, and telemetry-only variants preserve their invariants"; PASS=$((PASS + 1))
else
  echo "  FAIL  S10.13 — classifier union variants drifted: ambiguous=$CLASSIFY_AMBIGUOUS refused=$CLASSIFY_REFUSED telemetry=$CLASSIFY_TELEMETRY"; FAIL=$((FAIL + 1))
fi
rm -f "$CLASSIFY_HELPER" "$CLASSIFY_CASE"

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
assert_grep "$REVIEW_PR" 'merge-pipeline/SKILL\.md.*Phase 3\.3|Phase 3\.3.*merge-pipeline/SKILL\.md' \
  "S13.14 — review-pr.md cross-references merge-pipeline/SKILL.md Phase 3.3 reference pattern"
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
echo "== S14: ci-code-fixer REFUSED halt path (Phase 3 6c.5) — locks post-O5 findings-to-issues dispatch shape =="

# S14.1 — Phase 3 6c.5 documents the REFUSED halt path with AskUserQuestion-less
# deterministic exit (mirrors 6c.6 HALT shape per RFC 0002 §3.2). Uses
# file-level assert_grep — patterns are sufficient to lock contract without
# section anchoring (mawk's awk-range against indented headings is unreliable).
assert_grep "$REVIEW_PR" \
  'REFUSED.*halt|halt.*REFUSED|ci-code-fixer.*REFUSED' \
  "S14.1 — Phase 3 6c.5 documents the ci-code-fixer REFUSED halt path"

# S14.2 — REFUSED → three-action sequence: file issue, emit halt prose, audit+exit
assert_grep "$REVIEW_PR" \
  'Three actions in order|three-action ordering|three actions in order' \
  "S14.2 — Phase 3 6c.5 documents three-action ordering on REFUSED (constraints [hard])"

# S14.3 — Action 1 is filing a CRITICAL-tier GH issue (mirrors findings-to-issues
# BLOCKER/CRITICAL shape per RFC 0002 §3.3.2).
assert_grep "$REVIEW_PR" \
  'CRITICAL-tier.*issue|File the failing test.*CRITICAL|CRITICAL.*GH issue' \
  "S14.3 — Phase 3 6c.5 action 1 is filing a CRITICAL-tier GH issue (RFC 0002 §3.3.2)"

# S14.4 (re-pinned post-O5) — Phase 3 6c.5 dispatches findings-to-issues
# with a synthetic single-row aggregate wrapped in
# <external-untrusted-input source="ci-refused-synthetic"> (RFC 0002 #116 O5).
# Pre-O5 pattern (`gh issue create --label review-pr-finding`) was correct for
# Wave 1 but is REPLACED here.
assert_grep "$REVIEW_PR" \
  'Task.*findings-to-issues.*ci-refused-synthetic|subagent_type.*findings-to-issues|<external-untrusted-input source="ci-refused-synthetic">' \
  "S14.4 — Phase 3 6c.5 dispatches findings-to-issues with synthetic aggregate (post-O5 dispatch shape; #116 O5)"

# S14.5 — tombstone: REFUSED branch MUST NOT retry (constraints [hard]:
# "REFUSED is a deterministic decision, not flake; retrying consumes 3 iterations").
# Negative: extract the REFUSED sub-block by line range and assert no retry-counter
# increment in that sub-block.
R_START=$(grep -n 'ci-code-fixer.*`status: REFUSED`' "$REVIEW_PR" | head -1 | cut -d: -f1)
R_END=$(awk -v s="${R_START:-0}" 'NR > s && /ci-rebase-handler.*`status: REBASED|ci-rebase-handler.*`status: CONFLICT|^### 6c\.6/ { print NR; exit }' "$REVIEW_PR")
if [[ -n "$R_START" && -n "$R_END" ]]; then
  RETRY_COUNT=$(sed -n "${R_START},${R_END}p" "$REVIEW_PR" | grep -cE 'CI_FIX_LOOP_CAP|loop-counter \+\+|retry_count\+\+|iteration\+\+')
  if [[ "$RETRY_COUNT" -eq 0 ]]; then
    echo "  PASS  S14.5 — REFUSED sub-block does NOT increment retry counter (constraints [hard]; tombstone)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S14.5 — REFUSED sub-block MUST NOT retry; found $RETRY_COUNT retry-increment patterns"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  S14.5 — could not locate REFUSED sub-block (R_START=$R_START R_END=$R_END)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== S15: field-contract structural guard — probe reads name,state,bucket (NOT status,conclusion) =="
# Lock the gh >= 2.83.1 field contract in the prose so a future edit can't
# silently regress the probe back to the removed status,conclusion fields.
assert_grep "$REVIEW_PR" 'gh pr checks "\$PR_NUMBER" --json name,state,bucket' \
  "S15.1 — PROBE call reads --json name,state,bucket"
assert_grep "$REVIEW_PR" 'gh pr checks "\$PR_NUMBER" --watch --interval 30$' \
  "S15.2 — MONITOR --watch call takes NO --json (gh forbids --watch with --json)"
# S15.2b — gh 2.83.1 rejects `--watch` together with `--json`
# ("cannot use --watch with --json flag", verified live). Scope this guard to
# actual `gh pr checks ... --watch` *command invocations* (not the prose that
# explains the constraint) by flagging only invocation lines that also carry
# --json. An invocation line is one where gh pr checks + --watch are not inside
# backtick-quoted prose: we approximate by requiring the line to NOT contain a
# backtick (command fences here are plain, prose references are backticked).
S15_2B_VIOLATIONS="$(awk '
  /gh pr checks/ && /--watch/ && /--json/ && $0 !~ /`/ { print FILENAME ":" NR ": " $0 }
' "$REVIEW_PR")"
if [ -z "$S15_2B_VIOLATIONS" ]; then
  echo "  PASS  S15.2b — no gh pr checks --watch invocation is combined with --json"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15.2b — a gh pr checks --watch invocation is combined with --json (gh rejects this)"
  printf '%s\n' "$S15_2B_VIOLATIONS" | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi
assert_no_grep "$REVIEW_PR" '\-\-json name,status,conclusion' \
  "S15.3 — no probe reads the removed --json name,status,conclusion field set"
assert_grep "$REVIEW_PR" 'bucket .* \{pass, skipping\}|bucket ∈ \{pass, skipping\}' \
  "S15.4 — green predicate keyed off bucket ∈ {pass, skipping}"
assert_grep "$REVIEW_PR" 'bucket ∈ \{fail, cancel\}|bucket .* \{fail, cancel\}' \
  "S15.5 — red predicate keyed off bucket ∈ {fail, cancel}"

echo
echo "== S15-RUNTIME: PROBE bucket-classification exercised against fake-gh =="
# Extract the PROBE verdict jq program *from review-pr.md itself* so this test
# exercises the documented contract, not a parallel re-implementation. If the
# prose jq changes, this re-extracts it and re-verifies behaviour.
JQ_VERDICT_PROG="$(awk '
  /PROBE_VERDICT="\$\(jq -r .$/ { capture=1; next }
  capture && /^[[:space:]]*.[[:space:]]*<<<"\$PROBE_JSON"/ { capture=0; exit }
  capture { print }
' "$REVIEW_PR")"

if [ -z "$JQ_VERDICT_PROG" ]; then
  echo "  FAIL  S15-RT.0 — could not extract PROBE_VERDICT jq program from review-pr.md"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S15-RT.0 — extracted PROBE_VERDICT jq program from review-pr.md prose"
  PASS=$((PASS + 1))
fi

FAKE_GH_DIR="$REPO_ROOT/tests/_fixtures/fake-gh"
if [ ! -x "$FAKE_GH_DIR/gh" ]; then
  echo "  FAIL  S15-RT.0b — fake-gh stub missing/not executable at $FAKE_GH_DIR/gh"
  FAIL=$((FAIL + 1))
fi

# Run the PROBE exactly as Phase 3 6c.1 specifies: fake gh on PATH, FAKE_GH_MODE
# set, `gh pr checks <n> --json name,state,bucket`. Echo the raw probe JSON on
# stdout so callers capture it in their own scope (a global set inside the $(...)
# command-substitution subshell would NOT propagate back to the caller).
_run_probe() {
  local mode="$1"
  PATH="$FAKE_GH_DIR:$PATH" FAKE_GH_MODE="$mode" \
    gh pr checks 999 --json name,state,bucket 2>/dev/null
}

assert_verdict() {
  local mode="$1" expected="$2" desc="$3"
  local probe got bucket_ok="no"
  probe="$(_run_probe "$mode")"
  got="$(jq -r "$JQ_VERDICT_PROG" <<<"$probe" 2>/dev/null)"
  # Guard against the silent-degradation class the issue pins: a probe whose
  # entries lack the `bucket` key would fall through the verdict jq's any()
  # tests to "green" — masking a broken field contract as a passing CI. So a
  # non-empty verdict is only trusted when every entry actually carries bucket.
  if printf '%s' "$probe" | jq -e 'type=="array" and length>0 and all(.[]; has("bucket"))' >/dev/null 2>&1; then
    bucket_ok="yes"
  fi
  if [ "$got" = "$expected" ] && [ "$bucket_ok" = "yes" ]; then
    echo "  PASS  $desc (mode=$mode → $got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        mode: $mode"; echo "        expected verdict: $expected (bucket-on-every-entry: yes)"; echo "        actual verdict:   $got (bucket-on-every-entry: $bucket_ok)"
    FAIL=$((FAIL + 1))
  fi
}

# S15-RT.1..4 — bucket classification, driven by the now-live ci-checks-* modes.
assert_verdict ci-checks-green   green   "S15-RT.1 — all bucket ∈ {pass,skipping} → green fast-path"
assert_verdict ci-checks-pending pending "S15-RT.2 — all bucket pending → MONITOR transition"
assert_verdict ci-checks-red     red     "S15-RT.3 — any bucket fail → red (CLASSIFY)"
assert_verdict ci-checks-mixed   red     "S15-RT.4 — fail+pending mix → red (red outranks pending)"

# S15-RT.5 — gh >= 2.83.1 field contract: the probe JSON the stub emits MUST
# carry name/state/bucket on every entry and NEVER the removed status/conclusion
# fields. This is the regression that the issue's "verified live" diagnosis pins.
GREEN_PROBE="$(_run_probe ci-checks-green)"
if printf '%s' "$GREEN_PROBE" | jq -e 'type=="array" and length>0 and all(.[]; has("name") and has("state") and has("bucket"))' >/dev/null 2>&1; then
  echo "  PASS  S15-RT.5a — stub probe entries carry name/state/bucket"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.5a — stub probe entries missing name/state/bucket: $GREEN_PROBE"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$GREEN_PROBE" | jq -e 'all(.[]; (has("status")|not) and (has("conclusion")|not))' >/dev/null 2>&1; then
  echo "  PASS  S15-RT.5b — stub probe entries carry NO removed status/conclusion fields"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.5b — stub probe entries still carry removed status/conclusion: $GREEN_PROBE"; FAIL=$((FAIL + 1))
fi

# S15-RT.6 — no-checks fast path: empty array (and non-zero gh exit + 'no checks
# reported on the' stderr) maps to the `empty` verdict → skipped_no_checks.
EMPTY_PROBE="$(_run_probe ci-checks-no-checks)"
EMPTY_VERDICT="$(jq -r "$JQ_VERDICT_PROG" <<<"$EMPTY_PROBE" 2>/dev/null)"
if [ "$EMPTY_VERDICT" = "empty" ]; then
  echo "  PASS  S15-RT.6 — ci-checks-no-checks empty array → empty verdict (skipped_no_checks)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S15-RT.6 — expected empty verdict, got '$EMPTY_VERDICT' (probe='$EMPTY_PROBE')"; FAIL=$((FAIL + 1))
fi

echo
echo "== S16: benign-cancel same-name dedupe (drop-only-cancel) + empty-checks settle window (#302) =="
# test.yml fires on push AND pull_request, so one head SHA carries two same-name
# check runs per job; once #309's concurrency group lands, every superseded push
# run reports bucket=cancel next to the authoritative completed run. The PROBE jq
# MUST dedupe same-name entries by DROPPING ONLY the benign `cancel` row when a
# non-cancel sibling exists (a sole cancel stays red), BEFORE the aggregate
# red/pending/green fold — else every superseded push manufactures a permanent RED.
# This is DELIBERATELY NOT best-state-wins: best-state-wins lets a completed push
# `pass` launder its still-running (`pending`) or failed (`fail`) pull_request
# sibling into the GREEN fast-path that skips MONITOR/CLASSIFY (re-opening the
# GREEN-describes-code-CI-never-validated window). fail/pending must stay
# un-maskable; only the benign cancel is dropped. #309 MUST land after this dedupe.
assert_grep "$REVIEW_PR" 'group_by\(\.name\)' \
  "S16.1 — PROBE verdict jq dedupes same-name check runs (group_by(.name))"
assert_grep "$REVIEW_PR" 'select\(\.bucket != "cancel"\)' \
  "S16.2 — dedupe drops ONLY benign cancel rows (select(.bucket != \"cancel\")), never fail/pending"
# Guard against silent reintroduction of best-state-wins laundering: the old
# rank/max_by construct must NOT come back (it let pass mask a fail/pending sibling).
if grep -Eq 'max_by\(rank\)|def rank:' "$REVIEW_PR"; then
  echo "  FAIL  S16.2b — best-state-wins laundering construct (max_by(rank)/def rank) reintroduced into PROBE jq"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S16.2b — no best-state-wins laundering construct (max_by(rank)/def rank) in PROBE jq"
  PASS=$((PASS + 1))
fi
assert_grep "$REVIEW_PR" 'CI_SETTLE_AGE_SEC = 120' \
  "S16.3a — settle threshold constant declared (CI_SETTLE_AGE_SEC = 120)"
assert_grep "$REVIEW_PR" 'CI_SETTLE_REPROBES = 3' \
  "S16.3b — settle re-probe cap constant declared (CI_SETTLE_REPROBES = 3)"
assert_grep "$REVIEW_PR" 'git show -s --format=%ct HEAD' \
  "S16.4a — settle window computes head age from the head commit timestamp"
assert_grep "$REVIEW_PR" 'SETTLE_REPROBES_USED' \
  "S16.4b — settle loop tracks SETTLE_REPROBES_USED"
assert_grep "$REVIEW_PR" 'subreason=settle_reprobe' \
  "S16.5 — settle re-probe audited via ci_probe_started subreason=settle_reprobe (no new enum member)"
assert_grep "$REVIEW_PR" 'settle window above is exhausted' \
  "S16.6 — skipped_no_checks terminal row gated on settle-window exhaustion"

echo
echo "== S16-RUNTIME: same-name dedupe exercised against the documented jq =="
# Reuses the JQ_VERDICT_PROG extracted live from review-pr.md in S15-RUNTIME, fed
# with inline probe JSON (the same-name shapes the fake-gh modes don't model).
assert_verdict_inline() {
  local json="$1" expected="$2" desc="$3"
  local got
  got="$(jq -r "$JQ_VERDICT_PROG" <<<"$json" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    echo "  PASS  $desc (→ $got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        expected: $expected"; echo "        actual:   $got"; echo "        json:     $json"
    FAIL=$((FAIL + 1))
  fi
}

if [ -z "$JQ_VERDICT_PROG" ]; then
  echo "  FAIL  S16-RT.0 — JQ_VERDICT_PROG empty (S15-RT.0 extraction failed); cannot exercise dedupe"
  FAIL=$((FAIL + 1))
else
  # S16-RT.1 — benign cancel: superseded same-name run cancelled, sibling passed → green.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"SUCCESS","bucket":"pass"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    green "S16-RT.1 — same-name cancel+pass dedupes to pass (benign cancel → green)"
  # S16-RT.2 — true cancel: cancel is the ONLY state for its name → still red.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.2 — sole-state cancel stays red (dedupe never launders a real cancel)"
  # S16-RT.3 — cancel + pending same name: the re-run is authoritative → MONITOR.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"QUEUED","bucket":"pending"}]' \
    pending "S16-RT.3 — same-name cancel+pending dedupes to pending (MONITOR transition)"
  # S16-RT.4 — fail outranks its own cancel sibling: a real failure stays red.
  assert_verdict_inline \
    '[{"name":"test","state":"CANCELLED","bucket":"cancel"},{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.4 — same-name fail+cancel dedupes to fail (red; dedupe never masks a failure)"
  # S16-RT.5 — distinct names untouched by dedupe (regression guard for S15-RT.4 semantics).
  assert_verdict_inline \
    '[{"name":"build","state":"SUCCESS","bucket":"pass"},{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"lint","state":"IN_PROGRESS","bucket":"pending"}]' \
    red "S16-RT.5 — distinct-name mix keeps red-outranks-pending (dedupe is per-name only)"
  # S16-RT.6 — THE LAUNDERING REGRESSION (#302 review-trust finding): a completed
  # push `pass` next to its FAILED pull_request sibling of the SAME name must NOT
  # be laundered green. best-state-wins (pass > fail) would have folded this to
  # green and skipped MONITOR/CLASSIFY; drop-only-cancel keeps both rows, so the
  # fail survives → red. The pull_request (merge-commit) run is authoritative.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"},{"name":"shape-checks-windows","state":"FAILURE","bucket":"fail"}]' \
    red "S16-RT.6 — same-name fail+pass stays red (pass NEVER launders a failed sibling)"
  # S16-RT.7 — same-name pass+pending: the still-running pull_request sibling must
  # still gate via MONITOR. best-state-wins (pass > pending) would have fast-pathed
  # green in the ~30s window before the pull_request run finishes; drop-only-cancel
  # keeps the pending row → MONITOR.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"},{"name":"shape-checks-windows","state":"IN_PROGRESS","bucket":"pending"}]' \
    pending "S16-RT.7 — same-name pass+pending stays pending (in-flight sibling still gates → MONITOR)"
  # S16-RT.8 — fail-safe: an unknown/contract-broken bucket folds to red, never
  # silently green (the `else "red"` arm). A pass sibling does not launder it.
  assert_verdict_inline \
    '[{"name":"shape-checks-windows","state":"WEIRD","bucket":"mystery"},{"name":"shape-checks-windows","state":"SUCCESS","bucket":"pass"}]' \
    red "S16-RT.8 — unknown bucket folds to red (fail-safe; broken field contract never downgrades the gate)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
