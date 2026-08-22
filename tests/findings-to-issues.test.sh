#!/usr/bin/env bash
# tests/findings-to-issues.test.sh — fixture suites for the new agent + command wire-up.
# 5 core suites + 4 bonus suites.
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
FIX="$THIS_DIR/fixtures/findings-to-issues"
AGENT_MD="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
REVIEW_PR_MD="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY_MD="$REPO_ROOT/plugins/uberdev/commands/simplify.md"

PASS=0; FAIL=0
source "$THIS_DIR/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

# Local assert_no_grep — the shared helpers in _lib_assert_structural.sh do not
# include this negation form; match the inline shape used by sibling tests
# (tests/simplify.test.sh, tests/review-pr-phase3-ci.test.sh).
assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

# Local assert_grep — mirrors the inline form used by sibling tests
# (tests/simplify.test.sh). Section-agnostic positive grep.
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "## findings-to-issues fixture suites"

# NOTE: this suite is intentionally mock-free. The findings-to-issues runtime is
# the agent .md interpreted by a dispatched Claude agent (no extracted shell
# helper to source), so every behavioural contract here is locked structurally
# against the agent .md / command .md prose. An earlier `gh()` argv-capture mock
# fed a single L4 "two --force calls" assertion that exercised only the stub and
# never production — a tautology (issue #276). It was removed along with the mock
# scaffolding it solely existed to serve; the real label-idempotency contract
# stays locked by the structural L1 assert (Suite 3).

### Suite 1: Parser ----------
echo
echo "### Suite 1: Parser (deferred-critical extraction)"

# Source the (eventually-extracted) parser helper. For now this is a structural
# assertion against the agent .md, NOT a runtime call — the agent runtime is
# dispatched by /review-pr; here we assert that the parser logic is present.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'route_by_severity' 'P1 agent defines route_by_severity helper (renamed from is_deferred_critical in RFC 0002 §3.3.1)'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'blocker|critical' 'P2 helper enumerates blocker|critical severities'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'disposition.*=.*APPLIED|APPLIED.*disposition' 'P3 helper excludes disposition==APPLIED (RFC 0002: `[ "$disposition" = "APPLIED" ] && return 1`)'
# P4 (RFC 0002 §3.1) — three-tier output (BLOCKER/CRITICAL/MAJOR) replaces the
# pre-v0.26.0 binary deferred-critical/no-issue split. Locks the tier enum
# against future drift.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="BLOCKER"' 'P4 route_by_severity emits BLOCKER tier on severity=blocker'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="CRITICAL"' 'P5 route_by_severity emits CRITICAL tier on severity=critical'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="MAJOR"' 'P6 route_by_severity emits MAJOR tier on severity=important|major'

# --- #454: route_by_severity's disposition domain -------------------------
#
# P1-P6 above prove the helper is PRESENT. They cannot prove its branch labels
# are REACHABLE — a presence grep passes just as happily on a branch no writer
# can ever satisfy, which is exactly how `[ "$disposition" = "REJECTED" ]`
# survived from RFC 0002 §3.1 into shipped policy. P7-P12b pin the helper's
# inbound domain against the producer's published enum instead.
#
# The slice is built here, not grepped file-wide, because REJECTED and REFUSED
# differ by one letter and REFUSED is legitimately all over this agent as its
# own return status. `tr -d '\r'` + the [[:space:]]* closer anchor keep the
# slice at 11 lines on the windows job too (Git Bash checks this tree out with
# core.autocrlf=true; a bare `$` after `}` never matches there and the slice
# would silently run to EOF).
FENCE_SLICE="$(mktemp)"
awk '/route_by_severity\(\)/{inside=1} inside{print} inside && /^   [}][[:space:]]*$/{exit}' \
  "$AGENT_MD" | tr -d '\r' > "$FENCE_SLICE"

# P7 — tombstone over the helper BODY. assert_no_grep_nonempty (not the
# file-local assert_no_grep) because it FAILs on an empty slice instead of
# passing while inspecting nothing (#347) — the anchors above are exactly the
# kind of thing a future rename moves.
assert_no_grep_nonempty "$FENCE_SLICE" 'REJECTED' \
  'P7 route_by_severity body carries no REJECTED guard (#454)'

# P8 — tombstone over the whole Step-4 SECTION, which also covers the comment
# block above the fence (P7's slice starts at the `route_by_severity() {` line).
# assert_count cannot detect an empty-but-valid range; that hazard is
# neutralised by construction here, because P1-P6 are positive asserts over the
# SAME range and would all FAIL if it emptied. Do not "harden" this into
# something else on that account.
assert_count "$AGENT_MD" '^## Process' '^## Issue body shape' 'REJECTED' 0 \
  'P8 Step 4 names no REJECTED disposition (#454)'

# P9 — exactly ONE disposition guard. Shrinking the helper is the fix; growing
# it back (a CULLED arm, a re-pointed REJECTED) is what this row forbids.
if [ ! -s "$FENCE_SLICE" ]; then
  echo "  FAIL  P9 route_by_severity slice is empty — anchors moved, refusing vacuous PASS"
  echo "        file: $AGENT_MD"
  FAIL=$((FAIL + 1))
else
  DISP_GUARDS="$(grep -cE '\[ "\$disposition" =' "$FENCE_SLICE")"
  if [ "$DISP_GUARDS" -eq 1 ]; then
    echo "  PASS  P9 route_by_severity has exactly one disposition guard (got $DISP_GUARDS)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  P9 route_by_severity must have exactly one disposition guard (got $DISP_GUARDS)"
    echo "        file: $FENCE_SLICE"
    FAIL=$((FAIL + 1))
  fi
fi

# P10 — the class-level pin: every branch label the consumer compares against
# must be a real disposition. The producer's enum is READ from the shipped
# contract document rather than retyped, so this row inherits that document's
# own drift-lock (tests/code-fixer-contract.test.sh) instead of duplicating it.
# `∪ {DEFERRED}` is the Step-3 empty-path default — the helper's inbound domain
# is FOUR values, not the producer's three; P11 below is what stops that +1
# decaying into an unexplained fudge constant.
FIXER_DOC="$REPO_ROOT/plugins/uberdev/shared/code-fixer-output-v1.md"
CONSUMER_LABELS="$(sed -n 's/.*\[ "\$disposition" = "\([A-Z_]*\)".*/\1/p' "$FENCE_SLICE")"
PRODUCER_LINES="$(sed -n 's/^ *disposition: \(.*\)$/\1/p' "$FIXER_DOC" | tr -d '\r')"
PRODUCER_LINE_COUNT="$(printf '%s\n' "$PRODUCER_LINES" | grep -c .)"
PRODUCER_ENUM="$(printf '%s\n' "$PRODUCER_LINES" | tr '|' '\n' | sed 's/[[:space:]]//g' | grep -E '^[A-Z_]+$')"
if [ -z "$CONSUMER_LABELS" ] || [ -z "$PRODUCER_ENUM" ] || [ "$PRODUCER_LINE_COUNT" -ne 1 ]; then
  echo "  FAIL  P10 disposition-vocabulary extraction is vacuous — refusing to compare nothing"
  echo "        consumer labels: [$CONSUMER_LABELS]"
  echo "        producer lines:  $PRODUCER_LINE_COUNT  enum: [$PRODUCER_ENUM]"
  FAIL=$((FAIL + 1))
else
  ALLOWED_DISPOSITIONS="$(printf '%s\nDEFERRED\n' "$PRODUCER_ENUM")"
  BAD_LABELS=''
  while IFS= read -r disp_label; do
    [ -n "$disp_label" ] || continue
    grep -qxF -- "$disp_label" <<<"$ALLOWED_DISPOSITIONS" \
      || BAD_LABELS="${BAD_LABELS}${BAD_LABELS:+ }$disp_label"
  done <<<"$CONSUMER_LABELS"
  if [ -z "$BAD_LABELS" ]; then
    echo "  PASS  P10 every route_by_severity branch label is a published disposition (#454)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  P10 route_by_severity branches on non-disposition label(s): $BAD_LABELS"
    echo "        allowed: $(printf '%s ' $ALLOWED_DISPOSITIONS)"
    echo "        oracle:  $FIXER_DOC"
    FAIL=$((FAIL + 1))
  fi
fi

# P11 — anchors P10's `∪ {DEFERRED}` term to the behaviour it exists for.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'default to .DEFERRED' \
  'P11 empty disposition path still defaults to DEFERRED (why P10 allows a fourth value)'

# P12a/P12b — the domain is STATED, not left to be re-derived from the silence
# the deletion leaves behind. Both phrases must sit on ONE line each in the
# helper's comment block; grep is line-based.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'only value that suppresses filing' \
  'P12a helper comment names APPLIED as the sole suppressor (#454)'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'SKIPPED, REFUSED and DEFERRED' \
  'P12b helper comment names the three issue-eligible dispositions (#454)'

# P13 (#556) — THE EMPTY STRING STAYS RESERVED FOR "NO FIXER RAN".
#
# A fixer that returns REFUSED writes neither of the artifacts the controller
# binds by path, and the cheap-looking repair is to hand this agent the empty
# string for that run. It type-checks and it never refuses — and it files every
# BLOCKER the fixer refused as DEFERRED, which is a WRONG RECORD, not a lossy
# one: nothing was deferred, a fixer looked at each row and declined it. The
# real repair publishes a record whose rows say REFUSED, which P10/P12b above
# already show is issue-eligible on its own terms.
#
# So the guard is the two-state binding itself, asserted as ONE row because
# either half alone is re-interpretable: the input contract offers a path or an
# empty string and nothing else, and the empty one means the rows DEFAULT —
# i.e. no fixer disposition exists to read, not "a fixer said no". Re-purposing
# the empty string for refusals cannot be done without rewriting one of these
# two sentences, and then this row reds and asks why.
#
# PROSE LOCK, and deliberately only that. What stops the producer passing "" on
# a real refusal is W-UNAP-E2E in tests/review-pr-workflow.test.sh, which drives
# the shipped defer fences and asserts they forward the REAL disposition path.
#
# Both sentences are matched against a FLATTENED slice — newlines folded to
# single spaces — because both are prose that wraps, and grep is line-based. A
# line-anchored pattern here would red on a pure re-wrap, which is the failure
# mode that teaches people to delete the assertion instead of reading it.
#
# The four heading anchors are checked FOR EXISTENCE first, not just for a
# non-empty slice: an awk range whose END anchor was renamed runs to EOF, so the
# slice stays fat and both greps go on matching text from sections this row
# never meant to read. A non-empty slice is therefore no evidence the range is
# still bounded where it claims to be.
#
# `tr -d '\r'` comes BEFORE the flatten, for the same reason the
# `route_by_severity` fence slice above strips it —
# this agent doc is outside the `plugins/uberdev/hooks/**` scope `.gitattributes`
# pins to `eol=lf`, so the windows job checks it out CRLF. Order is the whole
# point: flattening first turns each line-ending CR into an INTERIOR byte that
# `tr -s ' '` cannot squeeze (it squeezes spaces, not CRs), and the Process
# needle below spans a source line break — it would read `disposition\r path`
# and never match. Stripping first is also why a CR-blind grep cannot make this
# row vacuously green: there is no CR left for either grep to disagree about.
P13_ANCHORS_OK=1
for p13_anchor in '^## Inputs' '^## Tools authorised' '^## Process' '^## Issue body shape'; do
  grep -qE -e "$p13_anchor" "$AGENT_MD" || P13_ANCHORS_OK=0
done
P13_INPUTS_SLICE="$(awk '/^## Inputs/,/^## Tools authorised/' "$AGENT_MD" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"
P13_PROCESS_SLICE="$(awk '/^## Process/,/^## Issue body shape/' "$AGENT_MD" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"
if [ "$P13_ANCHORS_OK" -ne 1 ] || [ -z "$P13_INPUTS_SLICE" ] || [ -z "$P13_PROCESS_SLICE" ]; then
  echo "  FAIL  P13 could not slice the agent doc between its four heading anchors — refusing a vacuous PASS"
  echo "        file: $AGENT_MD"
  FAIL=$((FAIL + 1))
elif ! grep -qE -e '`phase1_disposition_path` — Phase 1 fixer disposition path, or an empty string\.' <<<"$P13_INPUTS_SLICE"; then
  echo "  FAIL  P13 the phase1_disposition_path binding no longer offers exactly {a path, the empty string} (#556)"
  echo "        file: $AGENT_MD  section: ## Inputs"
  FAIL=$((FAIL + 1))
elif ! grep -qE -e 'An empty disposition path means all matching rows default to `DEFERRED`' <<<"$P13_PROCESS_SLICE"; then
  echo "  FAIL  P13 the empty disposition path no longer means \"no fixer disposition to read\" (#556)"
  echo "        file: $AGENT_MD  section: ## Process"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  P13 the empty disposition path stays reserved for \"no fixer ran\" — a refusal travels as REFUSED rows, never as DEFERRED (#556)"
  PASS=$((PASS + 1))
fi

rm -f "$FENCE_SLICE"
# --- end #454 ------------------------------------------------------------

### Suite 2: Dedupe-fingerprint ----------
echo
echo "### Suite 2: Dedupe-fingerprint (cross-lens collapse to single issue)"

assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'sha256.*16|sha256sum.*16' 'D1 agent computes 16-char sha256 prefix as fingerprint'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'normalised_summary|normalized_summary' 'D2 agent normalises summary before hash'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'also_flagged_by|Also flagged by' 'D3 cross-lens merge appends Also flagged by line'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'gh issue list .*--search.*\$FP|gh issue list .*--search.*fingerprint=' 'D4 dedupe queries fingerprint in:body'

### Suite 3: Label-provision idempotency ----------
echo
echo "### Suite 3: Label-provision idempotency"

assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'gh label create --force.*review-pr-finding' 'L1 agent uses gh label create --force'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'fail-soft|fail soft|fail_soft' 'L2 label provisioning is fail-soft'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'd93f0b' 'L3 label uses red color d93f0b'

# (L4 removed — issue #276. It re-invoked the test's own gh() mock and asserted the
# mock logged two --force tokens: a tautology that exercised the stub, never
# production code. The idempotency contract is locked by the structural L1 assert
# above; the agent .md prose at Step 7 documents `gh label create --force` is
# idempotent.)

### Suite 4: Opt-out flag ----------
echo
echo "### Suite 4: --no-defer-issues short-circuits the dispatch"

# Structural: review-pr.md must declare the flag and short-circuit Phase 2.5.
assert_in_section "$REVIEW_PR_MD" '^---' '^$' \
  'no-defer-issues' 'O1 review-pr.md argument-hint advertises --no-defer-issues'
assert_in_section "$REVIEW_PR_MD" 'Argument Parsing' 'Phase 2.5|Phase 1' \
  'DEFER_ISSUES_PHASE|defer.*issues' 'O2 review-pr.md parses the flag into a phase variable'
assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'DEFER_ISSUES_PHASE.*0|--no-defer-issues' 'O3 Phase 2.5 short-circuits on flag'

### Suite 5: Config override ----------
echo
echo "### Suite 5: defer_issues_enabled=false short-circuits identically"

assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'uberdev_read_enum.*defer_issues_enabled|defer_issues_enabled.*uberdev_read_enum' \
  'C1 review-pr.md reads defer_issues_enabled via uberdev_read_enum'
assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'effective.*enabled|both.*ON|CLI.*AND.*config' \
  'C2 effective-enabled gate is AND of CLI flag and config key'
assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'blocker.*critical.*important.*major|blocker.*critical.*major.*important' \
  'C2b Phase 2.5 documents every issue-eligible severity'
assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'blocker.*halt|halt.*blocker' \
  'C2c Phase 2.5 documents blocker-driven parent halt'
assert_in_section "$REVIEW_PR_MD" 'Phase 2.5|findings-to-issues' 'Phase 3|Final Aggregation' \
  'critical/blocker overflow|overflow.*BLOCKER/CRITICAL|BLOCKER/CRITICAL.*overflow' \
  'C2d Phase 2.5 documents the critical/blocker overflow halt'

assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'review_pr\.defer\.findings.*exact|exact.*review_pr\.defer\.findings' \
  'C2e findings agent declares the exact routed review input contract'
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'derive.*repo_slug|repo_slug.*derive' \
  'C2f findings agent derives repository identity instead of trusting absent handoff fields'

# Runtime smoke: source lib/config-read.sh in fixture context with key absent, then with key=false.
if [[ -f "$REPO_ROOT/plugins/uberdev/lib/config-read.sh" ]]; then
  pushd "$REPO_ROOT" >/dev/null
  UBERDEV_CONFIG_FILE="$FIX/uberdev.local.default.md" \
    bash -c 'source plugins/uberdev/lib/config-read.sh && uberdev_read_enum defer_issues_enabled UBERDEV_DEFER_ISSUES_ENABLED "true|false" "true"' \
    | grep -q '^true$' \
    && { echo "  PASS  C3 default config reads enabled=true"; PASS=$((PASS+1)); } \
    || { echo "  FAIL  C3 default config did not read true"; FAIL=$((FAIL+1)); }

  UBERDEV_CONFIG_FILE="$FIX/uberdev.local.optout.md" \
    bash -c 'source plugins/uberdev/lib/config-read.sh && uberdev_read_enum defer_issues_enabled UBERDEV_DEFER_ISSUES_ENABLED "true|false" "true"' \
    | grep -q '^false$' \
    && { echo "  PASS  C4 opt-out config reads enabled=false"; PASS=$((PASS+1)); } \
    || { echo "  FAIL  C4 opt-out config did not read false"; FAIL=$((FAIL+1)); }
  popd >/dev/null
fi

### Suite 6: Fail-CLOSED dedupe ----------
echo
echo "### Suite 6: Fail-CLOSED dedupe (gh issue list rc!=0 blocks write)"
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'fail-CLOSED|fail closed|fail_closed' 'B1 agent declares fail-CLOSED dedupe semantics'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'blocked_by_dedupe' 'B2 agent populates blocked_by_dedupe[] on lookup failure'

### Suite 7: MAX_NEW cap ----------
echo
echo "### Suite 7: MAX_NEW=10 cap"
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'MAX_NEW|max_new.*10|max_new=10' 'B3 agent caps at MAX_NEW=10 default'
assert_in_section "$AGENT_MD" '^## Process' '^## Return contract' \
  'overflow_count' 'B4 agent emits overflow_count in return'

### Suite 8: Secret-scan integration ----------
echo
echo "### Suite 8: Secret-scan body block"
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'uberdev_run_secret_scan_stdin' 'B5 agent pipes candidate body through secret-scan'
# B6 lives in either `## Process` (step 8d) or `## Failure-mode summary` (last section).
# Use inline grep across the whole file because BSD awk range with a multi-alternation
# end-anchor is unreliable when one alternative is at EOF.
if grep -qE 'secret-scan-hit' "$AGENT_MD"; then
  echo "  PASS  B6 secret-scan hit appends to blocked_by_dedupe"; PASS=$((PASS+1))
else
  echo "  FAIL  B6 secret-scan hit appends to blocked_by_dedupe"; FAIL=$((FAIL+1))
fi

### Suite 9: Fingerprint-marker reject ----------
echo
echo "### Suite 9: Fingerprint-marker forge-protection"
# B7 lives in either `## Process` (step 8e refusal carve-out) or `## Sanitiser steps`.
# Same EOF-anchor rationale as B6 — inline grep is the robust shape.
if grep -qE 'finding-contains-fingerprint-marker' "$AGENT_MD"; then
  echo "  PASS  B7 finding containing the marker is refused"; PASS=$((PASS+1))
else
  echo "  FAIL  B7 finding containing the marker is refused"; FAIL=$((FAIL+1))
fi

### Suite 10: RFC 0002 return-contract + overflow guard locks ----------
echo
echo "### Suite 10: RFC 0002 return-contract + overflow guard locks (T3, T6)"

# T3.1 — by_severity block in return contract
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'by_severity' 'T3.1 — return contract documents by_severity block (RFC 0002 §3.3.3)'

# T3.2 — halted field with true|false values
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'halted:.*true|false|halted: bool|halted.*true.*false' \
  'T3.2 — return contract documents halted: bool (RFC 0002 §3.3.5; load-bearing)'

# T3.3 — halted_due_to_overflow field
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'halted_due_to_overflow' 'T3.3 — return contract documents halted_due_to_overflow (RFC 0002 §3.3.4)'

# T3.4 — halt semantic rule ("halted is set only when ... iff ...")
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'halted.*set only when|halted.*iff|set only when.*halted' \
  'T3.4 — halt semantic rule documented (RFC 0002 §3.3.5)'

# T3.5 — per-URL tier field on created_urls / commented_urls / skipped_closed
# (RFC 0002 §3.3.3 — tier annotation on every URL row).
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'tier: "BLOCKER"|tier: "CRITICAL"|tier: "MAJOR"|tier:.*BLOCKER|CRITICAL|MAJOR' \
  'T3.5 — per-URL tier annotation on created_urls / commented_urls / skipped_closed (RFC 0002 §3.3.3)'

# T3-tombstone — the old "NEVER causes /review-pr or /simplify to exit
# non-zero" clause MUST be ABSENT (constraints [hard]: RFC 0002 §3.3.5
# intentionally inverts the pre-RFC contract).
assert_no_grep "$AGENT_MD" \
  'NEVER causes /review-pr or /simplify to exit non-zero' \
  'T3-tombstone — pre-v0.26.0 NEVER-halts clause is removed (RFC 0002 §3.3.5)'

# T6.1 — process step 6 documents the broken-feature overflow guard
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'Broken-feature overflow guard|broken-feature overflow|broken_feature_overflow' \
  'T6.1 — Process step 6 documents the broken-feature overflow guard (RFC 0002 §3.3.4)'

# T6.2 — guard fires when a truncated row is BLOCKER or CRITICAL tier
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'truncated.*row.*BLOCKER|truncated.*row.*CRITICAL|BLOCKER.*CRITICAL.*truncated' \
  'T6.2 — overflow guard fires on truncated BLOCKER/CRITICAL tier rows (constraints [hard])'

# T6.3 — halted_due_to_overflow == true implies halted == true
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'halted_due_to_overflow.*true.*halted.*true|halted=true.*halted_due_to_overflow|halted_due_to_overflow == true' \
  'T6.3 — halted_due_to_overflow == true implies halted == true (RFC 0002 §3.3.5)'

### Suite 11: O2/O4 observability locks ----------
echo
echo "### Suite 11: O2 author_lookup_failed + O4 is_transient (RFC 0002 observability)"

# O2.1 — return contract documents author_lookup_failed: bool
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'author_lookup_failed' \
  'O2.1 — return contract documents author_lookup_failed field (#116 O2)'

# O2.2 — integer regex guard on $pr_number (defence-in-depth per security Note A)
assert_grep "$AGENT_MD" \
  'pr_number.*=~.*\^\[1-9\]\[0-9\]\*\$|=~ \^\[1-9\]\[0-9\]\*\$' \
  'O2.2 — agent enforces integer regex guard on $pr_number before gh pr view (security Note A)'

# O4.1 — return contract documents is_transient on blocked_by_dedupe[] entries
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'is_transient' \
  'O4.1 — return contract documents is_transient field on blocked_by_dedupe[] (#116 O4)'

# O4.2 — 200-char truncation runs BEFORE is_transient classifier (security Note B)
# Locate the truncation literal and the classifier grep; assert truncation precedes.
# Alternation tolerates either ordering of TRUNCATED_OUTPUT and 'head -c 200' on a single line — but the truncate-precedes-classify invariant (L_TRUNC < L_CLASSIFY) is what we actually assert.
L_TRUNC=$(grep -n 'TRUNCATED_OUTPUT.*head -c 200\|head -c 200.*TRUNCATED_OUTPUT' "$AGENT_MD" | head -n 1 | cut -d: -f1)
L_CLASSIFY=$(grep -n 'is_transient=true\|HTTP 429.*rate limit' "$AGENT_MD" | head -n 1 | cut -d: -f1)
if [[ -n "$L_TRUNC" && -n "$L_CLASSIFY" && "$L_TRUNC" -lt "$L_CLASSIFY" ]]; then
  PASS=$((PASS+1)); echo "  PASS  O4.2 — 200-char truncation precedes is_transient classifier (security Note B; L_TRUNC=$L_TRUNC < L_CLASSIFY=$L_CLASSIFY)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  O4.2 — truncation MUST precede classifier (L_TRUNC=$L_TRUNC L_CLASSIFY=$L_CLASSIFY)"
fi

# O4.3 — classifier transient-triggers documented (rc=429 OR stderr 5xx/rate-limit)
assert_grep "$AGENT_MD" \
  'rc.*-eq 429|HTTP 5\[0-9\]\[0-9\]|rate limit|secondary rate' \
  'O4.3 — is_transient classifier triggers documented (design decision D9)'

### Suite 12: Allow-list extension lock (S7 — #116 review-pr finding) ----------
echo
echo "### Suite 12: ci-refused-synthetic allow-list lock (#116 O5)"

# O5.1 — Step 1 accepted-source allow-list extended with ci-refused-synthetic.
# Locks the closed-set extension performed in #116 / O5 so future refactors do
# not silently drop the synthetic-aggregate path that wires CI-REFUSED issue
# creation through this agent.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'ci-refused-synthetic' \
  'O5.1 — Step 1 accepted-source allow-list includes ci-refused-synthetic (#116 O5)'

### Suite 13: ubersimplify-aggregate source accepted ----------
echo
echo "### Suite 13: ubersimplify-aggregate accepted-source lock"
F2I="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
assert_grep "$F2I" 'ubersimplify-aggregate' 'closed-set lists ubersimplify-aggregate'
assert_grep "$F2I" 'uberscan-aggregate' 'closed-set still lists uberscan-aggregate'

### Suite 14: testers-aggregate source accepted (#182) ----------
echo
echo "### Suite 14: testers-aggregate accepted-source lock"
# /uberdev:testers' Phase-5 report.py wraps its findings-to-issues aggregate in
# the envelope source "testers-aggregate" (skills/testers-pipeline/report.py).
# Lock that source INSIDE the Step-1 closed allow-list (## Process section) so the
# command never again refuses every dispatch (input-malformed) and silently files
# ZERO issues (#182 — uberscan blocker finding). Section-scoped like Suite 12 so a
# future refactor cannot satisfy the guard by leaving the token in unrelated prose.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'testers-aggregate' \
  'S14 — Step 1 accepted-source allow-list includes testers-aggregate (#182)'

### Suite 15: ACCEPTED_SOURCES SSOT (#198) ----------
echo
echo "### Suite 15: ACCEPTED_SOURCES SSOT (#198)"
# Make the findings-to-issues accepted-source allow-list a single source of truth
# (lib/report_primitives.py:ACCEPTED_SOURCES) with an emit-time assert in
# envelope(), preventing the #182-class drift where a pipeline emits a source not
# in the allow-list → findings-to-issues silently files ZERO issues.

LIB_DIR="$REPO_ROOT/plugins/uberdev/lib"
# The canonical 9-set, sorted (used as the byte-equality oracle for checks 1+2).
# `postfix-aggregate` (#655) is the eighth: the /uberdev:review-pr command fence
# `review_write_postfix_aggregate` envelopes one post-fix reviewer child's
# findings under it, and Step 1's closed allow-list has to admit it or every
# post-fix dispatch refuses `input-malformed` and files ZERO issues — the #182
# class this whole suite exists to prevent.
# `premerge-aggregate` (RFC 0021) is the ninth: `lib/premerge-findings.py`
# envelopes /uberdev:premerge's deferred cleanup findings under it. It is the
# only source that carries `suggestion` rows meant to be FILED rather than
# dropped, which is why it could not borrow `simplify-aggregate`.
EXPECTED_SOURCES_SORTED=$(printf '%s\n' \
  post-impl-review-aggregate simplify-aggregate ci-refused-synthetic \
  uberscan-aggregate ubersimplify-aggregate testers-aggregate uberthink-aggregate \
  postfix-aggregate premerge-aggregate \
  | LC_ALL=C sort)

# S15.1 — Python frozenset is importable + has exactly the 9 members.
# Capture stderr (NOT 2>/dev/null) so an import/syntax error in report_primitives.py
# surfaces in the FAIL message instead of being swallowed — fitting for the very
# anti-silent-failure fix this suite guards.
S15_PY_ERR="$(mktemp)"
# Cross-platform import (#268 CI): `cd` into the lib dir (bash resolves the
# absolute path on Git Bash/Windows too) and let `python3 -c` find the module
# via cwd — passing an absolute BASH path to native-Windows python's sys.path
# (e.g. /d/a/...) raises ModuleNotFoundError. No path argument reaches python.
# `tr -d '\r'`: native-Windows python writes CRLF to stdout, so the multi-line
# join carries \r that breaks the LF-based string compare below (the \r is a
# no-op on Linux/macOS where output is already LF) — #268 CI.
PY_SOURCES_SORTED=$( (cd "$LIB_DIR" && python3 -c "from report_primitives import ACCEPTED_SOURCES; print('\n'.join(sorted(ACCEPTED_SOURCES)))") 2>"$S15_PY_ERR" | tr -d '\r')
if [[ "$PY_SOURCES_SORTED" == "$EXPECTED_SOURCES_SORTED" ]]; then
  echo "  PASS  S15.1 ACCEPTED_SOURCES frozenset imports with the 9 expected members"; PASS=$((PASS+1))
else
  echo "  FAIL  S15.1 ACCEPTED_SOURCES frozenset mismatch"
  echo "        expected: $(echo "$EXPECTED_SOURCES_SORTED" | tr '\n' ' ')"
  echo "        got:      $(echo "$PY_SOURCES_SORTED" | tr '\n' ' ')"
  [[ -s "$S15_PY_ERR" ]] && echo "        python stderr: $(tr '\n' ' ' < "$S15_PY_ERR")"
  FAIL=$((FAIL+1))
fi
rm -f "$S15_PY_ERR"

# S15.2 — Spec closed-set (agents/findings-to-issues.md Step 1) == ACCEPTED_SOURCES.
# Extract the {...} closed set, split on `,`, trim whitespace/backticks, sort.
# Anchor on the literal phrase `closed set` immediately before the `{...}` so the
# greedy `.*{` does not run past it to a later same-line `${CLAUDE_PLUGIN_ROOT}`
# interpolation (which would capture the wrong braces).
SPEC_SOURCES_SORTED=$(grep -E 'closed set' "$AGENT_MD" | grep -F '{' \
  | grep -oE 'closed set `\{[^}]*\}`' \
  | sed -E 's/.*\{([^}]*)\}.*/\1/' \
  | tr ',' '\n' \
  | sed -E 's/[`[:space:]]//g' \
  | grep -v '^$' \
  | LC_ALL=C sort)
if [[ "$SPEC_SOURCES_SORTED" == "$PY_SOURCES_SORTED" ]]; then
  echo "  PASS  S15.2 agents/findings-to-issues.md Step-1 closed set == ACCEPTED_SOURCES"; PASS=$((PASS+1))
else
  echo "  FAIL  S15.2 spec closed-set diverges from ACCEPTED_SOURCES"
  echo "        spec: $(echo "$SPEC_SOURCES_SORTED" | tr '\n' ' ')"
  echo "        py:   $(echo "$PY_SOURCES_SORTED" | tr '\n' ' ')"
  FAIL=$((FAIL+1))
fi

# S15.3 — Every emitter envelope() source literal ∈ ACCEPTED_SOURCES.
# Grep the 2nd positional string arg of envelope(fh, "X", ...) across the
# emitter .py files, then assert each is a member of the python frozenset.
EMITTER_SOURCES=$(grep -rhoE 'envelope\([^,]+,[[:space:]]*"[^"]+"' "$REPO_ROOT"/plugins/uberdev/skills/*/*.py \
  | sed -E 's/.*"([^"]+)".*/\1/' | LC_ALL=C sort -u)
S15_3_OK=1
while IFS= read -r src; do
  [[ -z "$src" ]] && continue
  if ! ( cd "$LIB_DIR" && python3 -c "import sys; from report_primitives import ACCEPTED_SOURCES; sys.exit(0 if '$src' in ACCEPTED_SOURCES else 1)" ) 2>/dev/null; then
    echo "        emitter source NOT in ACCEPTED_SOURCES: $src"
    S15_3_OK=0
  fi
done <<< "$EMITTER_SOURCES"
if [[ "$S15_3_OK" -eq 1 && -n "$EMITTER_SOURCES" ]]; then
  echo "  PASS  S15.3 every skills/*/*.py envelope() source literal ∈ ACCEPTED_SOURCES ($(echo "$EMITTER_SOURCES" | tr '\n' ' '))"; PASS=$((PASS+1))
else
  echo "  FAIL  S15.3 an emitter envelope() source is not in ACCEPTED_SOURCES (or none found)"; FAIL=$((FAIL+1))
fi

# S15.4 — Behavioral: envelope() RAISES ValueError on a bad source, ACCEPTS a good one.
# Use an explicit stdout marker (RAISED/OK) rather than relying on the process exit
# code alone: a bare `2>/dev/null` + rc check would conflate "envelope raised
# ValueError" (the contract) with "python errored for another reason" (e.g. a broken
# import), which would FALSELY pass S15.4a. The marker only prints on the intended
# control path, so an import/syntax error yields neither marker → both checks FAIL.
S15_4A_OUT=$( (cd "$LIB_DIR" && python3 -c "
import sys
from report_primitives import envelope
import io
try:
    envelope(io.StringIO(), 'not-a-real-source', 'x')
except ValueError:
    print('RAISED'); sys.exit(0)
sys.exit(1)
") 2>/dev/null | tr -d '\r')
if [[ "$S15_4A_OUT" == "RAISED" ]]; then
  echo "  PASS  S15.4a envelope() raises ValueError on an un-accepted source"; PASS=$((PASS+1))
else
  echo "  FAIL  S15.4a envelope() did not raise ValueError on an un-accepted source (marker='$S15_4A_OUT')"; FAIL=$((FAIL+1))
fi
S15_4B_OUT=$( (cd "$LIB_DIR" && python3 -c "
from report_primitives import envelope
import io
envelope(io.StringIO(), 'testers-aggregate', 'x')
print('OK')
") 2>/dev/null | tr -d '\r')
if [[ "$S15_4B_OUT" == "OK" ]]; then
  echo "  PASS  S15.4b envelope() accepts a valid source (testers-aggregate)"; PASS=$((PASS+1))
else
  echo "  FAIL  S15.4b envelope() rejected a valid source or errored (marker='$S15_4B_OUT')"; FAIL=$((FAIL+1))
fi

### Suite 16: Refusal-triggers documents BOTH rate-limit buckets (#276) ----------
echo
echo "### Suite 16: rate-limit-budget-insufficient enumerates both buckets (#276)"
# Process Step 2 probes TWO rate-limit buckets and fails CLOSED on EITHER:
#   CORE_REMAINING  < (2 * max_new + 50)   — funds gh issue create/comment/label/api
#   SEARCH_REMAINING < (max_new + 5)        — funds the gh issue list --search dedupe
# The canonical "Refusal triggers" section MUST enumerate BOTH conditions (and use
# the Step-2 variable NAMES), else an implementer reading only the refusal list
# re-introduces the silent-skip hole where Search exhaustion maps every dedupe
# lookup into blocked_by_dedupe[] with no issues filed. Lock both, plus the
# absence of the pre-#276 bare-`REMAINING` single-bucket form.

# S16.1 — core-bucket guard present with its real Step-2 variable name + threshold.
assert_in_section "$AGENT_MD" '^## Refusal triggers' '^## Failure-mode summary' \
  'CORE_REMAINING < \(2 \* max_new \+ 50\)' \
  'S16.1 — Refusal-triggers names the CORE_REMAINING < (2*max_new+50) guard (Step 2)'

# S16.2 — search-bucket guard present (the condition #276 found missing).
assert_in_section "$AGENT_MD" '^## Refusal triggers' '^## Failure-mode summary' \
  'SEARCH_REMAINING < \(max_new \+ 5\)' \
  'S16.2 — Refusal-triggers names the SEARCH_REMAINING < (max_new+5) guard (Step 2)'

# S16.3 — the stale single bare-`REMAINING` threshold form (no CORE_/SEARCH_
# prefix) MUST be gone, so the refusal list cannot drift back to one bucket.
assert_no_grep "$AGENT_MD" \
  '`REMAINING < \(2 \* max_new \+ 50\)`' \
  'S16.3 — stale bare-REMAINING single-bucket threshold removed (#276)'

assert_grep "$AGENT_MD" 'RATE_LIMIT_JSON=\$\(gh api /rate_limit' \
  'S16.4 — one canonical rate-limit response feeds both bucket checks'
assert_grep "$AGENT_MD" 'jq -er.*resources\.core\.remaining.*type == "number"' \
  'S16.5 — core remaining is parsed locally as an integer'
assert_grep "$AGENT_MD" 'jq -er.*resources\.search\.remaining.*type == "number"' \
  'S16.6 — search remaining is parsed locally as an integer'
assert_in_section "$AGENT_MD" '^2\. \*\*Rate-limit pre-flight' '^3\. \*\*Parse aggregates' \
  'rationale: "rate-limit-probe-failed"' \
  'S16.7 — probe or parse failure has a distinct typed rationale'
assert_in_section "$AGENT_MD" '^## Refusal triggers' '^## Failure-mode summary' \
  'rate-limit-probe-failed.*probe.*empty/non-numeric' \
  'S16.8 — refusal contract separates probe failure from low numeric budget'
assert_no_grep "$AGENT_MD" 'Search bucket \(30 req/min, 1000/hr authenticated\)' \
  'S16.9 — Search prose does not conflate the separate code-search hourly limit'

### Suite 17: routed origin variants + exact PR binding ----------
echo
echo "### Suite 17: routed origin variants and exact PR binding"
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'review_pr\.ci\.defer_refusal.*exact three-field|exact three-field.*review_pr\.ci\.defer_refusal' \
  'S17.1 — CI-refusal dispatch has a discriminated exact input contract'
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'review_pr\.defer\.findings.*review_pr\.ci\.defer_refusal|discriminated union' \
  'S17.2 — normal and CI-refusal inputs share one discriminated origin contract'
assert_grep "$AGENT_MD" 'gh pr view.*--repo.*repo_slug.*headRefOid' \
  'S17.3 — live PR head lookup is explicitly repository-bound'
assert_grep "$AGENT_MD" 'pr_commit_sha.*=.*local_head|local_head.*pr_commit_sha' \
  'S17.4 — live PR head must equal reviewed local HEAD'
assert_no_grep "$AGENT_MD" '\[ -n "\$pr_number" \]' \
  'S17.5 — PR-only body branches do not treat standalone zero as a PR'
assert_grep "$AGENT_MD" '\[ "\$pr_number" -gt 0 \]' \
  'S17.6 — PR-only body branches require pr_number greater than zero'
assert_grep "$AGENT_MD" '/\*\|\[A-Za-z\]:\[\\\\/\]\*' \
  'S17.6a — origin validation accepts POSIX and Windows drive-root worktree paths'
assert_grep "$AGENT_MD" '"\$git_root" -ef "\$canonical_root"' \
  'S17.6b — origin validation compares worktree roots by file identity instead of path spelling'
assert_no_grep "$AGENT_MD" 'realpath "\$git_root".*canonical_root' \
  'S17.6c — origin validation does not compare platform-specific canonical root strings'

ORIGIN_TMP="$(mktemp -d)"
ORIGIN_REPO="$ORIGIN_TMP/repo"
mkdir -p "$ORIGIN_REPO"
git -C "$ORIGIN_REPO" init -q
git -C "$ORIGIN_REPO" config user.email fixture@example.invalid
git -C "$ORIGIN_REPO" config user.name Fixture
printf 'fixture\n' >"$ORIGIN_REPO/file"
git -C "$ORIGIN_REPO" add file
git -C "$ORIGIN_REPO" commit -qm fixture
ORIGIN_HEAD="$(git -C "$ORIGIN_REPO" rev-parse HEAD)"

extract_origin_helper() {
  local source="$1" output="$2"
  awk '/^findings_derive_review_origin\(\) \{/{active=1} active{print} active && /^\}/{exit}' "$source" >"$output"
}
extract_origin_helper "$AGENT_MD" "$ORIGIN_TMP/canonical.sh"

ORIGIN_RUNTIME_FAILURES=0
for helper in "$ORIGIN_TMP/canonical.sh"; do
  ORIGIN_GH_LOG="$ORIGIN_TMP/$(basename "$helper").gh"
  : >"$ORIGIN_GH_LOG"
  set +e
  ORIGIN_OUTPUT="$(
    ORIGIN_HEAD="$ORIGIN_HEAD" ORIGIN_GH_LOG="$ORIGIN_GH_LOG" \
    bash -c '
      . "$1"
      gh() {
        printf "%s\n" "$*" >>"$ORIGIN_GH_LOG"
        case "${ORIGIN_MODE:-match}" in
          match) printf "%s\n" "$ORIGIN_HEAD" ;;
          mismatch) printf "%040d\n" 0 ;;
          malformed) printf "not-a-sha\n" ;;
        esac
      }
      findings_derive_review_origin "$2" 7 20260726-010203-abcdef0 owner/repo review-pr 7 review_pr.defer.findings
    ' _ "$helper" "$ORIGIN_REPO"
  )"
  ORIGIN_MATCH_RC=$?
  ORIGIN_MODE=mismatch ORIGIN_HEAD="$ORIGIN_HEAD" ORIGIN_GH_LOG="$ORIGIN_GH_LOG" \
    bash -c '. "$1"; gh(){ printf "%s\n" "$*" >>"$ORIGIN_GH_LOG"; printf "%040d\n" 0; }; findings_derive_review_origin "$2" 7 20260726-010203-abcdef0 owner/repo review-pr 7 review_pr.defer.findings' _ "$helper" "$ORIGIN_REPO"
  ORIGIN_MISMATCH_RC=$?
  ORIGIN_MODE=malformed ORIGIN_HEAD="$ORIGIN_HEAD" ORIGIN_GH_LOG="$ORIGIN_GH_LOG" \
    bash -c '. "$1"; gh(){ printf "%s\n" "$*" >>"$ORIGIN_GH_LOG"; printf "not-a-sha\n"; }; findings_derive_review_origin "$2" 7 20260726-010203-abcdef0 owner/repo review-pr 7 review_pr.defer.findings' _ "$helper" "$ORIGIN_REPO"
  ORIGIN_MALFORMED_RC=$?
  set +e
  printf '%s' "$ORIGIN_OUTPUT" | jq -e --arg sha "$ORIGIN_HEAD" \
    '.origin_kind=="pr" and .repo_slug=="owner/repo" and .pr_commit_sha==$sha and .source_ref==""' >/dev/null \
    || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
  [ "$ORIGIN_MATCH_RC" -eq 0 ] || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
  [ "$ORIGIN_MISMATCH_RC" -ne 0 ] || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
  [ "$ORIGIN_MALFORMED_RC" -ne 0 ] || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
  grep -q 'pr view 7 --repo owner/repo --json headRefOid --jq .headRefOid' "$ORIGIN_GH_LOG" \
    || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
  ! grep -Eq 'issue (create|comment)|label create' "$ORIGIN_GH_LOG" \
    || ORIGIN_RUNTIME_FAILURES=$((ORIGIN_RUNTIME_FAILURES + 1))
done
if [ "$ORIGIN_RUNTIME_FAILURES" -eq 0 ]; then
  echo "  PASS  S17.7 — the canonical origin accepts exact head, rejects mismatch/malformed, and performs no writes"; PASS=$((PASS + 1))
else
  echo "  FAIL  S17.7 — origin runtime failures=$ORIGIN_RUNTIME_FAILURES"; FAIL=$((FAIL + 1))
fi

ORIGIN_MATRIX_FAILURES=0
for helper in "$ORIGIN_TMP/canonical.sh"; do
  for row in \
    '0 simplify 0 review_pr.defer.findings standalone' \
    '7 review-pr 7 review_pr.defer.findings pr' \
    '7 solve 7 review_pr.defer.findings pr' \
    '7 turbo 7 review_pr.ci.defer_refusal pr' \
    '7 premerge 7 premerge.defer.findings pr' \
    '0 legacy-uberscan 0 legacy.uberscan standalone' \
    '0 legacy-ubersimplify 0 legacy.ubersimplify standalone' \
    '7 legacy-ubersimplify 7 legacy.ubersimplify pr' \
    '0 legacy-testers 0 legacy.testers standalone' \
    '0 legacy-uberthink 0 legacy.uberthink standalone'; do
    read -r matrix_pr matrix_workflow matrix_issue matrix_edge matrix_kind <<<"$row"
    MATRIX_OUTPUT="$(ORIGIN_HEAD="$ORIGIN_HEAD" bash -c '
      . "$1"
      gh(){ printf "%s\n" "$ORIGIN_HEAD"; }
      findings_derive_review_origin "$2" "$3" 20260726-010203-abcdef0 owner/repo "$4" "$5" "$6"
    ' _ "$helper" "$ORIGIN_REPO" "$matrix_pr" "$matrix_workflow" "$matrix_issue" "$matrix_edge")"
    MATRIX_RC=$?
    [ "$MATRIX_RC" -eq 0 ] || ORIGIN_MATRIX_FAILURES=$((ORIGIN_MATRIX_FAILURES + 1))
    printf '%s' "$MATRIX_OUTPUT" | jq -e --arg kind "$matrix_kind" '.origin_kind==$kind' >/dev/null 2>&1 \
      || ORIGIN_MATRIX_FAILURES=$((ORIGIN_MATRIX_FAILURES + 1))
  done
  for bad_row in \
    '7 simplify 0 review_pr.defer.findings' \
    '0 review-pr 7 review_pr.defer.findings' \
    '8 solve 7 review_pr.defer.findings' \
    '7 simplify 7 review_pr.ci.defer_refusal' \
    '7 premerge 6 premerge.defer.findings' \
    '7 review-pr 7 premerge.defer.findings' \
    '0 legacy-testers 0 review_pr.defer.findings'; do
    read -r matrix_pr matrix_workflow matrix_issue matrix_edge <<<"$bad_row"
    if ORIGIN_HEAD="$ORIGIN_HEAD" bash -c '
      . "$1"; gh(){ printf "%s\n" "$ORIGIN_HEAD"; }
      findings_derive_review_origin "$2" "$3" 20260726-010203-abcdef0 owner/repo "$4" "$5" "$6"
    ' _ "$helper" "$ORIGIN_REPO" "$matrix_pr" "$matrix_workflow" "$matrix_issue" "$matrix_edge" >/dev/null 2>&1; then
      ORIGIN_MATRIX_FAILURES=$((ORIGIN_MATRIX_FAILURES + 1))
    fi
  done
done
if [ "$ORIGIN_MATRIX_FAILURES" -eq 0 ]; then
  echo "  PASS  S17.8 — review, simplify, CI, and all four legacy origin variants are carrier-bound; mixed variants refuse"; PASS=$((PASS + 1))
else
  echo "  FAIL  S17.8 — carrier origin matrix failures=$ORIGIN_MATRIX_FAILURES"; FAIL=$((FAIL + 1))
fi

# --- #685: the suggestion-tier gate must survive the subshell Step 1 mandates -
#
# S17.1-S17.8 here, and P5/P5b in tests/premerge.test.sh, are grep-shaped: they
# read the agent markdown and pass on text. That is exactly what stayed green
# while the RFC 0021 §5 gate was assigned INSIDE
# `findings_derive_review_origin`. Step 1 mandates calling that function and
# parsing its stdout, which makes every real call a command substitution — a
# subshell — so the assignment died at that boundary, `route_by_severity` read
# the closed default, every `suggestion` row routed out, and a stock /premerge
# run returned `status: DONE` with empty arrays, indistinguishable from "the
# code-review pass found nothing". The rows below EXECUTE the shipped helpers
# across that exact boundary instead of reading them.
GATE_FAILURES=0
awk '/^findings_arm_suggestion_tier\(\) \{/{active=1} active{print} active && /^\}/{exit}' \
  "$AGENT_MD" >"$ORIGIN_TMP/arm.sh"
awk '/^   route_by_severity\(\) \{/{active=1} active{print} active && /^   [}][[:space:]]*$/{exit}' \
  "$AGENT_MD" >"$ORIGIN_TMP/route.sh"
# Refuse a vacuous PASS: an empty slice means an anchor moved, and every
# assertion below would then be evaluated against nothing at all.
for gate_slice in "$ORIGIN_TMP/canonical.sh" "$ORIGIN_TMP/arm.sh" "$ORIGIN_TMP/route.sh"; do
  if [ ! -s "$gate_slice" ]; then
    echo "        S17.9 slice missing or empty — refusing vacuous PASS: $gate_slice"
    GATE_FAILURES=$((GATE_FAILURES + 1))
  fi
done

# Drive one carrier end to end and report the facts the contract turns on.
gate_probe() {
  ORIGIN_HEAD="$ORIGIN_HEAD" bash -c '
    . "$1"; . "$2"; . "$3"
    gh(){ printf "%s\n" "$ORIGIN_HEAD"; }
    # EXACTLY what Step 1 mandates: call the derivation and parse its stdout.
    # That is a command substitution, so anything the function assigns to a
    # variable is discarded before the next line runs.
    ORIGIN_JSON="$(findings_derive_review_origin "$4" 7 20260726-010203-abcdef0 owner/repo "$5" 7 "$6")" || exit 3
    findings_arm_suggestion_tier "$ORIGIN_JSON"
    printf "gate=%s\n" "${SUGGESTION_TIER_ENABLED:-unset}"
    if route_by_severity suggestion DEFERRED; then printf "suggestion=%s\n" "$row_tier"; else printf "suggestion=DROPPED\n"; fi
    if route_by_severity blocker DEFERRED; then printf "blocker=%s\n" "$row_tier"; else printf "blocker=DROPPED\n"; fi
    printf "keys=%s\n" "$(printf "%s" "$ORIGIN_JSON" | jq -c "keys_unsorted")"
  ' _ "$ORIGIN_TMP/canonical.sh" "$ORIGIN_TMP/arm.sh" "$ORIGIN_TMP/route.sh" "$ORIGIN_REPO" "$1" "$2"
}
gate_expect() {
  case "$1" in
    *"$2"*) ;;
    *) echo "        S17.9 expected [$2] — got: $(printf '%s' "$1" | tr '\n' ' ')"
       GATE_FAILURES=$((GATE_FAILURES + 1)) ;;
  esac
}

GATE_PREMERGE="$(gate_probe premerge premerge.defer.findings)" || GATE_FAILURES=$((GATE_FAILURES + 1))
GATE_REVIEW="$(gate_probe review-pr review_pr.defer.findings)" || GATE_FAILURES=$((GATE_FAILURES + 1))

# The /premerge carrier arms the tier IN THE CALLER and files its suggestions.
gate_expect "$GATE_PREMERGE" 'gate=1'
gate_expect "$GATE_PREMERGE" 'suggestion=SUGGESTION'
gate_expect "$GATE_PREMERGE" 'blocker=BLOCKER'
gate_expect "$GATE_PREMERGE" 'keys=["origin_kind","repo_slug","pr_commit_sha","source_ref","suggestion_tier"]'
# Every other carrier is byte-identical to shipped: four keys, tier closed,
# suggestions dropped, blockers still filed.
gate_expect "$GATE_REVIEW" 'gate=0'
gate_expect "$GATE_REVIEW" 'suggestion=DROPPED'
gate_expect "$GATE_REVIEW" 'blocker=BLOCKER'
gate_expect "$GATE_REVIEW" 'keys=["origin_kind","repo_slug","pr_commit_sha","source_ref"]'

if [ "$GATE_FAILURES" -eq 0 ]; then
  echo "  PASS  S17.9 — the suggestion tier crosses the mandated command substitution and arms in the caller (#685)"; PASS=$((PASS + 1))
else
  echo "  FAIL  S17.9 — suggestion-tier gate failures=$GATE_FAILURES"; FAIL=$((FAIL + 1))
fi

# Shape lock scoped to the FUNCTION BODY, not the whole file: the whole-file
# count in tests/premerge.test.sh:241 is satisfied by an assignment anywhere,
# including back inside the derivation where #685 put it.
assert_no_grep_nonempty "$ORIGIN_TMP/canonical.sh" 'SUGGESTION_TIER_ENABLED' \
  'S17.10 — the derivation never assigns a gate it cannot carry out of the subshell (#685)'

rm -rf "$ORIGIN_TMP"

### Suite 18: disposition artifacts are aggregate-bound ----------
echo
echo "### Suite 18: disposition artifact binding"
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'same canonical run directory|same canonical run' \
  'S18.1 — disposition path is constrained to the aggregate run directory'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'phase1-disposition\.json' \
  'S18.2 — disposition basenames are phase-specific'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'phase2-disposition\.json' \
  'S18.2b — phase-2 disposition basename is fixed'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'aggregate_sha256' \
  'S18.3 — disposition schema binds digest and finding triples'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'finding_index.*location.*summary_sha256' \
  'S18.3b — disposition join triple is explicit'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'device,inode,size,mtime_ns|device.*inode.*size.*mtime' \
  'S18.4 — replacement is rejected by stable file identity'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'never re-read|already validated in-memory bytes' \
  'S18.5 — validated aggregate/disposition bytes are not re-read mutably'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'schema_version.*2|schema v2' \
  'S18.6 — review Phase 1/2 aggregates use schema v2'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'contributors.*findings.*phase.*schema_version' \
  'S18.7 — v2 top-level key set is exact'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'detail.*scope.*severity.*source_edges.*summary' \
  'S18.8 — v2 finding key set is exact'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'scope\.path.*sole|only.*scope\.path|authority.*scope\.path' \
  'S18.9 — issue location authority comes only from structured scope.path'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'summary.*detail.*context-only|context-only.*summary.*detail' \
  'S18.10 — summary/detail are context-only and never path authority'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'findings.*\[\].*DONE|zero findings.*DONE|empty findings.*DONE' \
  'S18.11 — valid v2 empty findings returns DONE'
assert_in_section "$AGENT_MD" '^3\. \*\*Parse aggregates' '^4\. \*\*Route by severity' \
  'no GitHub writes|zero GitHub writes|before.*rate-limit.*label' \
  'S18.12 — valid v2 empty findings short-circuits before GitHub writes'

echo
echo "### Suite 19: legacy fleet callers select explicit variants"
assert_grep "$REPO_ROOT/plugins/uberdev/skills/scan-fleet/workflow.js" \
  'variant=legacy\..*ubersimplify.*uberscan|variant=legacy\.' \
  'S19.1 — scan fleet selects explicit uberscan/ubersimplify variants'
assert_grep "$REPO_ROOT/plugins/uberdev/skills/testers-pipeline/workflow.js" \
  'variant=legacy\.testers' \
  'S19.2 — testers selects the legacy.testers variant'
assert_grep "$REPO_ROOT/plugins/uberdev/skills/ubersimplify-pipeline/SKILL.md" \
  'variant=legacy\.ubersimplify' \
  'S19.3 — standalone ubersimplify selects its explicit variant'
assert_grep "$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/SKILL.md" \
  'variant=legacy\.uberthink' \
  'S19.4 — uberthink selects the legacy.uberthink variant'

echo
echo "### Suite 20: findings publication refusal is fail-closed in every executor contract"
for contract in "$AGENT_MD"; do
  assert_grep "$contract" \
    'REFUSED.*infrastructure failure|infrastructure failure.*REFUSED' \
    "S20.1 — $(basename "$contract") classifies REFUSED publication as infrastructure failure"
  assert_grep "$contract" \
    'terminate.*before.*trust|before.*trust.*terminate' \
    "S20.2 — $(basename "$contract") terminates before trust on REFUSED/malformed publication"
  assert_no_grep "$contract" \
    'REFUSED.*information for the final summary.*not a parent-process halt' \
    "S20.3 — $(basename "$contract") contains no stale fail-open REFUSED rule"
done

### Suite 21: machine-readable lens provenance + verdict-label ritual (#432) ----------
#
# RFC 0018. Per-lens precision needs two facts the pipeline never recorded:
# WHICH lens produced a finding (knowable only at dispatch) and WHETHER the
# finding was real (knowable only at close). S21.1–S21.3 are the anti-regression
# half — they must hold BEFORE and AFTER #432, proving the trailer was bolted on
# beside the fingerprint machinery rather than through it. S21.4–S21.12 are the
# new contract.
#
# Windows-safe by construction: structural greps only, and the one length
# measurement strips CR before counting (Git Bash checks this file out with
# core.autocrlf=true, so a trailing \r would inflate every count by one).
echo
echo "### Suite 21: finding provenance trailer + verdict labels (#432, RFC 0018)"

# --- anti-regression: the pre-#432 body contract is untouched ---
for field in 'Origin' 'Agent' 'File' 'Severity' 'Disposition' 'Tier'; do
  assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
    "\\*\\*${field}:\\*\\*" \
    "S21.1 — issue body template still renders **${field}:**"
done
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  '\*\*File:\*\* .[{]file_path[}]:[{]line[}].' \
  'S21.2 — **File:** template is still `{file_path}:{line}`'
# S21.3 is the operational form of "the fingerprint is unchanged": a test has no
# copy of the pre-#432 bytes, so it locks the exact marker template AND the exact
# recipe substring instead. Either one drifting is the regression.
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  '<!-- uberdev:[{]finding_marker_slug[}]-finding fingerprint=[{]16-char-hex[}] -->' \
  'S21.3 — fingerprint marker template is unchanged'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'sha256sum [|] awk .*substr[(][$]1,1,16[)]' \
  'S21.3b — fingerprint recipe (sha256 -> 16-hex prefix) is unchanged'

# --- the new meta trailer ---
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  '<!-- uberdev-finding-meta v=1 slug=[{]finding_marker_slug[}] edges=[{]comma-joined edges[}] severity=[{]severity[}] tier=[{]BLOCKER[|]CRITICAL[|]MAJOR[}] -->' \
  'S21.4 — meta trailer template carries v=1, slug=, edges=, severity=, tier='

# S21.5 — the trailer must be the line IMMEDIATELY AFTER the fingerprint marker.
# The miner reads the pair positionally, so an intervening blank line or a
# reordering silently strips provenance from every future issue. index()==1 is a
# fixed-string anchor: the template contains regex metacharacters ({, }, -) that
# an awk ERE would have to escape.
TRAILER_LINE="$(awk 'index($0, "<!-- uberdev:{finding_marker_slug}-finding fingerprint=") == 1 { getline nxt; print nxt; exit }' "$AGENT_MD")"
if grep -qE '^<!-- uberdev-finding-meta ' <<<"$TRAILER_LINE"; then
  echo "  PASS  S21.5 — meta trailer is the line immediately after the fingerprint marker"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S21.5 — meta trailer is the line immediately after the fingerprint marker"
  echo "        file: $AGENT_MD"
  echo "        line following the fingerprint marker: ${TRAILER_LINE:-<none>}"
  FAIL=$((FAIL + 1))
fi

assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'contributor-ordered union of the kept row' \
  'S21.6 — edges reproduces the contributor-ordered union incl. merged rows'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'NEVER derive .edges. from .summary. or .detail.' \
  'S21.6b — edges is never derived from summary/detail prose'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'legacy fleet variants.*carry no .source_edges' \
  'S21.7 — legacy variants fall back to their validated lens column'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'empty .edges=. is a recorded state' \
  'S21.7b — the empty-edges case is defined, not left to inference'

# --- forgery refusal covers BOTH literals ---
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'finding-contains-fingerprint-marker' \
  'S21.8 — step 8e keeps the fingerprint-marker refusal reason string'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  '<!-- uberdev-finding-meta' \
  'S21.8b — step 8e also refuses a forged meta trailer'
assert_in_section "$AGENT_MD" '^## Sanitiser steps' '^## Comment body shape' \
  '<!-- uberdev:.*-finding fingerprint=' \
  'S21.8c — sanitiser step 4 still names the fingerprint marker literal'
assert_in_section "$AGENT_MD" '^## Sanitiser steps' '^## Comment body shape' \
  '<!-- uberdev-finding-meta' \
  'S21.8d — sanitiser step 4 also names the meta-trailer literal'

# --- verdict labels (the ground-truth half) ---
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'gh label create --force finding:true-positive' \
  'S21.9 — finding:true-positive is provisioned via gh label create --force'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'gh label create --force finding:false-positive' \
  'S21.9b — finding:false-positive is provisioned via gh label create --force'

# S21.10 (every --description in this file measured against GitHub's 100 limit)
# was retired into tests/epipe-guard.test.sh L8 (#628). Two things changed with
# the move. The scope: L8 measures the whole shipped corpus, so the three
# descriptions here are still covered and so is every other one. And the UNIT:
# this row used `wc -m`, which counts CHARACTERS and is locale-dependent, while
# GitHub's limit is on BYTES — the repo's label prose is full of three-byte
# em-dashes, so a 40-character description can be 120 bytes and pass here while
# the API 422s. L8 uses `wc -c` and pins that exact discriminator in its
# polarity row.

assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'finding:true-positive' \
  'S21.11 — the To-resolve footer names finding:true-positive'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'finding:false-positive' \
  'S21.11b — the To-resolve footer names finding:false-positive'

# S21.12 — `conf=` stays OUT of the emitted trailer. A per-finding numeric
# confidence is #431's surface; emitting one here would change the exact finding
# key set that post-impl-review.test.sh and S18.8 above both lock. Scoped to the
# trailer line itself, because the prose deliberately names `conf=` as reserved.
if grep -qE 'conf=' <<<"$TRAILER_LINE"; then
  echo "  FAIL  S21.12 — the meta trailer must not emit conf= (reserved for #431)"
  echo "        trailer: $TRAILER_LINE"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  S21.12 — the meta trailer does not emit conf= (reserved for #431)"
  PASS=$((PASS + 1))
fi

### Suite 22: post-fix aggregate routing (#655) ----------
echo
echo "### Suite 22: post-fix aggregate routing (#655)"
# S15 above proves `postfix-aggregate` is an ACCEPTED source. Acceptance alone
# files nothing: #182 was an accepted-source hole, but the same zero-issues
# outcome is reachable from any of four later gates — the path never reaching
# the ONE Phase 2.5 dispatch, the Step 1 byte gate demanding a schema-v2
# document this source does not produce, a row bound to a disposition that
# does not exist, or a severity that routes to no tier. Each row below pins one
# of those, so an aggregate the fence wrote is provably still routable end to
# end rather than merely admitted at the door.
#
# Every row was measured against `git show 3654f0fb:` of the same file: all of
# the #655 rows match zero times there and once here, and the two "unchanged"
# rows at the end match exactly once in BOTH. A row that matched the base file
# would be locking prose this change did not add.

# --- the two optional inputs ride the existing single dispatch ---------------
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'postfix_phase1_path.*[*][(]optional[)][*]' \
  'S22.1 — postfix_phase1_path is declared OPTIONAL on review_pr.defer.findings'
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'postfix_phase2_path.*[*][(]optional[)][*]' \
  'S22.2 — postfix_phase2_path is declared OPTIONAL on review_pr.defer.findings'
# The shape is copied from `verification_path`, not invented: that is what makes
# "no second dispatch" a consequence rather than a promise.
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'same conditional-bind shape as' \
  'S22.3 — the two paths use verification_path'"'"'s conditional-bind shape'
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'SINGLE Phase 2.5 dispatch' \
  'S22.3b — they bind on the SINGLE Phase 2.5 dispatch, not a second call'
# A supplement cannot make an otherwise-absent input valid, so the shipped
# both-absent refusal is untouched — the arm that would have turned an optional
# path into a way to dispatch with no aggregate at all.
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'supplements, not substitutes' \
  'S22.4 — the post-fix paths are supplements, never substitutes'
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'input-malformed.* rule below is unchanged' \
  'S22.4b — the both-aggregates-absent input-malformed rule is unchanged'

# --- Step 1: the byte gate admits the envelope this source actually writes ---
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'postfix-aggregate. for either post-fix path' \
  'S22.5 — Step 1 accepts the postfix-aggregate envelope on either post-fix path'
# The exemption is the #182-class arm: applying the schema-v2 gate to a
# command-owned document no canonical encoder produced refuses EVERY post-fix
# dispatch, and a refusal at Step 1 files zero issues without halting anything.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'exempt from the exact-compact-sorted-JSON-schema-v2 requirement' \
  'S22.6 — postfix-aggregate is exempt from the schema-v2 byte gate'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'refuse every post-fix dispatch and silently file zero issues' \
  'S22.6b — Step 1 records WHY the exemption exists (#182 class)'

# --- Step 3: the row shape, and the disposition it carries inline ------------
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  '"disposition":"DEFERRED"' \
  'S22.7 — the post-fix row template carries disposition DEFERRED inline'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  '"source_edges":\["review_pr.postfix.correctness"\]' \
  'S22.8 — the row template carries the one-element source_edges array'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  '"severity":"blocker[|]suggestion"' \
  'S22.9 — the row severity vocabulary is exactly blocker|suggestion'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'are structurally unproducible on this' \
  'S22.9b — critical/major/important are unproducible on this source, not coerced'
# Binding by adjacency is the swap the (finding_index, location, summary_sha256)
# triple exists to prevent: a postfix row is in NEITHER phase aggregate, so
# there is no row for a disposition document to bind it to.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'carries no disposition artifact, and none binds it' \
  'S22.10 — a post-fix aggregate binds to no disposition document'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'no .postfix-disposition.json.' \
  'S22.10b — there is no postfix-disposition.json to bind'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'phase1_disposition_path. or .phase2_disposition_path' \
  'S22.10c — a postfix row inherits nothing from either phase disposition path'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'carries .disposition: "DEFERRED". inline' \
  'S22.11 — each postfix row carries DEFERRED inline, as ci-refused-synthetic does'
# DEFERRED is reused, not minted; SKIPPED is refused BY NAME because it asserts
# a fixer considered the finding, which is false for one no fixer has seen.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'do [*][*]not[*][*] reuse .SKIPPED.' \
  'S22.11b — SKIPPED is refused by name for post-fix rows'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  '.APPLIED. / .SKIPPED. / .REFUSED., unchanged' \
  'S22.11c — the fixer disposition vocabulary is unchanged'

# --- Step 4 / Step 6: same routing, same single cap --------------------------
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'row_tier=BLOCKER. and files' \
  'S22.12 — a post-fix blocker resolves row_tier=BLOCKER and files'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'single shared cap for the whole dispatch[*][*], and stays .10.' \
  'S22.13 — max_new is one shared cap for the whole dispatch and stays 10'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'post-fix rows get no separate budget' \
  'S22.13b — post-fix rows get no separate budget and no priority'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'the same Step 8 fingerprint' \
  'S22.14 — post-fix rows reuse the shipped Step 8 fingerprint/marker/dedupe'

# --- the trailer renders the edge, and the dedupe merge never erases it ------
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'A post-fix row carries a one-element .source_edges.' \
  'S22.15 — the body-shape contract names the one-element source_edges'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'edges=review_pr.postfix.correctness' \
  'S22.15b — a filed post-fix finding renders edges=review_pr.postfix.correctness'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'postfix edge [*][*]joins[*][*] the kept row' \
  'S22.16 — on a Step-5 merge the postfix edge JOINS the kept row'"'"'s edges'
assert_in_section "$AGENT_MD" '^## Issue body shape' '^## Sanitiser steps' \
  'it never replaces them' \
  'S22.16b — the merge never replaces or erases the review contributors'

# --- what this change must NOT have moved ------------------------------------
#
# These two are the ONLY rows in this suite that also match the base file, and
# deliberately so: they assert the shipped recipe and the shipped cap did not
# gain a post-fix variant. Counted rather than merely present — a SECOND copy
# of the fingerprint recipe, minted "for this source", is the drift this repo
# has shipped before, and a presence grep is blind to it.
assert_count "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'printf .%s:%s:%s. "[$]file_path" "[$]line" "[$]normalised_summary" [|] sha256sum' \
  1 \
  'S22.17 — exactly ONE sha256(path:line:normalised_summary) recipe, no post-fix variant'
assert_count "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'more than .MAX_NEW=10. deferred blocker/critical findings' \
  1 \
  'S22.18 — the MAX_NEW=10 broken-feature overflow threshold is unchanged'

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
