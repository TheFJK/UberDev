#!/usr/bin/env bash
# tests/trust-trail-evaluator.test.sh — structural-grep coverage for the
# Phase 2.5 gate added in RFC 0002 (v0.26.0). First test file for the agent.
#
# Based on tests/findings-to-issues.test.sh skeleton (set -u, _lib_assert_structural.sh,
# PASS=0; FAIL=0, [[ $FAIL -eq 0 ]] exit gate); adds `set -o pipefail` and a
# file-existence preflight that the mirror target lacks.
set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
AGENT_MD="$REPO_ROOT/plugins/uberdev/agents/trust-trail-evaluator.md"

for f in "$AGENT_MD"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0; FAIL=0
source "$THIS_DIR/_lib_assert_structural.sh"

echo "## trust-trail-evaluator structural coverage (RFC 0002 §3.6 Phase 2.5 gate)"

# TT1 — agent mentions the Phase 2.5 gate by name in Step 1.5
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Phase 2\.5 gate|RFC 0002 §3\.6|phase2_5 inputs' \
  'TT1 — agent documents Phase 2.5 gate in Process section (RFC 0002 §3.6)'

# TT2 — STALE verdict on legacy audit (phase2_5_present == "false")
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'STALE.*phase2_5_present.*false|phase2_5_present.*false.*STALE|Legacy audit' \
  'TT2 — STALE verdict on legacy audit (phase2_5_present == "false")'

# TT2b — STALE rationale string contains the RFC reference + v0.26.0 cite
# (constraints [hard]: "Rationale string must contain 'RFC 0002 v0.26.0'").
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'RFC 0002 v0\.26\.0|RFC 0002.*v0\.26\.0' \
  'TT2b — STALE rationale cites "RFC 0002 v0.26.0" (constraints [hard])'

# TT3 — Phase 2.5 gate reads halted + by_severity inputs from the audit JSON
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'phase2_5_halted|phase2_5_blocker_count|phase2_5_critical_count' \
  'TT3 — Phase 2.5 inputs (halted, blocker_count, critical_count) are declared'

# TT4 — INVALID verdict on phase2_5_blocker_deferred subreason
# (TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM member 1 of 2).
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'INVALID.*blocker.*deferred|blocker.*deferred.*INVALID|phase2_5 halted.*blocker' \
  'TT4 — INVALID verdict on phase2_5 blocker-deferred (subreason phase2_5_blocker_deferred)'

# TT5 — INVALID verdict requires --i-know-what-im-doing when override_reason
# is set (phase2_5_override_unacknowledged subreason).
# Per spec-reviewer Minor #2: sibling assertion locking the second
# TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM member.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'override_reason.*user-selected-emit-green-on-blocker-deferred|i_know_what_im_doing_flag.*false' \
  'TT5 — INVALID verdict on override-unacknowledged (subreason phase2_5_override_unacknowledged; sibling per spec-reviewer Minor #2)'

# TT5b — sibling check: the subreason name phase2_5_override_unacknowledged
# is the second hard-constraint member of TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM.
# The agent prose may not name the enum literally but MUST cover the gate; we
# accept either the literal subreason or the equivalent operator-acknowledgment
# phrase. (Hard-constraint enum membership is enforced by inspection at code review.)
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'operator-acknowledgment|explicit.*--i-know-what-im-doing|operator selected emit-GREEN' \
  'TT5b — agent documents operator-acknowledgment as the INVALID-override condition'

# TT6 — fail-open on probe failure: malformed booleans produce STALE, NOT INVALID
# (constraints [hard]: "Fail-open on probe failure ... treat as legacy-audit
# branch (phase2_5_present == 'false') and emit STALE").
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Fail-open|fail-open.*probe failure|malformed.*STALE|STALE.*malformed|truncated.*STALE' \
  'TT6 — fail-open on probe failure emits STALE not INVALID (constraints [hard])'

# TT7 — Step 1.5 ordering invariant: the Phase 2.5 gate runs BEFORE Step 2
# (structural primitives). Locate Step 1.5 and Step 2 by line number and
# assert ordering.
L_1_5=$(grep -n '^1\.5\.\|^1\.5 \|Step 1\.5' "$AGENT_MD" | head -1 | cut -d: -f1)
L_2=$(grep -n '^2\. Probe ancestry\|^2\.[[:space:]]\|Step 2' "$AGENT_MD" | head -1 | cut -d: -f1)
if [[ -n "$L_1_5" && -n "$L_2" && "$L_1_5" -lt "$L_2" ]]; then
  echo "  PASS  TT7 — Step 1.5 (Phase 2.5 gate) precedes Step 2 (structural primitives); L_1_5=$L_1_5 < L_2=$L_2"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT7 — Step 1.5 MUST precede Step 2 (L_1_5=$L_1_5 L_2=$L_2)"
  FAIL=$((FAIL + 1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
