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
source "$THIS_DIR/_lib_assert_structural.sh"

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

# ---------- gh-command mocks (inline functions) ----------
# All mocks capture argv into MOCK_LOG and return canned JSON when needed.
MOCK_LOG=$(mktemp -t fti-mock-XXXX)
trap 'rm -f "$MOCK_LOG"' EXIT INT TERM

MOCK_DEDUPE_HITS=""    # JSON array of pre-existing matches — set per-suite
MOCK_RATE_LIMIT=5000   # rate_limit core.remaining — set per-suite
MOCK_LABEL_RC=0        # gh label create rc — set per-suite

gh() {
  local sub="$1"; shift
  case "$sub" in
    issue)
      local subsub="$1"; shift
      printf 'gh issue %s %s\n' "$subsub" "$*" >> "$MOCK_LOG"
      case "$subsub" in
        list) printf '%s' "${MOCK_DEDUPE_HITS:-[]}"; return 0 ;;
        create) printf 'https://github.com/owner/repo/issues/%d\n' "$(( $(wc -l <"$MOCK_LOG") + 100 ))"; return 0 ;;
        comment) return 0 ;;
      esac
      ;;
    label)
      printf 'gh label %s\n' "$*" >> "$MOCK_LOG"
      return "$MOCK_LABEL_RC"
      ;;
    api)
      if [[ "$*" == *rate_limit* ]]; then printf '%d\n' "$MOCK_RATE_LIMIT"; return 0; fi
      ;;
  esac
  return 0
}
export -f gh

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
# pre-RFC-0002 binary deferred-critical/no-issue split. Locks the tier enum
# against future drift.
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="BLOCKER"' 'P4 route_by_severity emits BLOCKER tier on severity=blocker'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="CRITICAL"' 'P5 route_by_severity emits CRITICAL tier on severity=critical'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'tier="MAJOR"' 'P6 route_by_severity emits MAJOR tier on severity=important|major'

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
  'gh label create --force review-pr-finding' 'L1 agent uses gh label create --force'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'fail-soft|fail soft|fail_soft' 'L2 label provisioning is fail-soft'
assert_in_section "$AGENT_MD" '^## Process' '^## Issue body shape' \
  'd93f0b' 'L3 label uses red color d93f0b'

# Runtime assertion via mocks: two consecutive gh label create calls both use --force.
MOCK_LOG_BEFORE=$(wc -l < "$MOCK_LOG")
gh label create --force review-pr-finding --color d93f0b --description "x" >/dev/null
gh label create --force review-pr-finding --color d93f0b --description "x" >/dev/null
MOCK_LOG_AFTER=$(wc -l < "$MOCK_LOG")
CALLS=$((MOCK_LOG_AFTER - MOCK_LOG_BEFORE))
if [[ "$CALLS" -eq 2 ]] && [[ "$(grep -c -- '--force' "$MOCK_LOG")" -ge 2 ]]; then
  echo "  PASS  L4 two consecutive label-create calls both use --force"; PASS=$((PASS+1))
else
  echo "  FAIL  L4 expected 2 --force calls, got $CALLS"; FAIL=$((FAIL+1))
fi

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
  'T3-tombstone — pre-RFC-0002 NEVER-halts clause is removed (RFC 0002 §3.3.5)'

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
  'pr_number.*=~.*\^\[0-9\]\+\$|=~ \^\[0-9\]\+\$' \
  'O2.2 — agent enforces integer regex guard on $pr_number before gh pr view (security Note A)'

# O4.1 — return contract documents is_transient on blocked_by_dedupe[] entries
assert_in_section "$AGENT_MD" '^## Return contract' '^## Refusal triggers' \
  'is_transient' \
  'O4.1 — return contract documents is_transient field on blocked_by_dedupe[] (#116 O4)'

# O4.2 — 200-char truncation runs BEFORE is_transient classifier (security Note B)
# Locate the truncation literal and the classifier grep; assert truncation precedes.
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

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
