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
source "$THIS_DIR/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

echo "## trust-trail-evaluator structural coverage (RFC 0002 §3.6 Phase 2.5 gate)"

# TT1 — agent mentions the Phase 2.5 gate by name in Step 1.5
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Phase 2\.5 gate|RFC 0002 §3\.6|phase2_5 inputs' \
  'TT1 — agent documents Phase 2.5 gate in Process section (RFC 0002 §3.6)'

# TT2 — caller-composed audit identity is explicit and five-state.
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'audit_state.*absent.*legacy.*current.*malformed.*indeterminate|audit_state.*absent.*legacy.*current.*indeterminate.*malformed' \
  'TT2 — audit_state input declares absent | legacy | current | malformed | indeterminate'

# TT2a — absent telemetry is not legacy: skip only Phase 2.5 and continue
# through the immutable structural proof.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Absent audit.*audit_state.*absent.*fall through to Step 2|audit_state.*absent.*skip.*Phase 2\.5.*structural' \
  'TT2a — absent audit skips only Phase 2.5 telemetry and continues structural proof'

# TT2b — STALE verdict on a present legacy audit.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Legacy audit.*audit_state.*legacy.*STALE|audit_state.*legacy.*STALE' \
  'TT2b — legacy audit remains STALE'

# TT2c — STALE rationale string contains the RFC reference + v0.26.0 cite
# (constraints [hard]: "Rationale string must contain 'RFC 0002 v0.26.0'").
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'RFC 0002 v0\.26\.0|RFC 0002.*v0\.26\.0' \
  'TT2c — STALE rationale cites "RFC 0002 v0.26.0" (constraints [hard])'

# TT3 — current audits retain the Phase 2.5 halted + by_severity inputs.
assert_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'phase2_5_halted|phase2_5_blocker_count|phase2_5_critical_count' \
  'TT3 — Phase 2.5 inputs (halted, blocker_count, critical_count) are declared'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Current audit.*audit_state.*current|audit_state.*current.*Phase 2\.5' \
  'TT3b — current audit state evaluates the existing Phase 2.5 gates'

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

# TT6 — malformed, indeterminate, or unknown state is invalid input, never
# conflated with absent telemetry or a present legacy audit.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Malformed, indeterminate, or unknown.*audit_state.*INVALID.*input-malformed|audit_state.*indeterminate.*INVALID.*input-malformed|indeterminate.*malformed.*unknown.*INVALID' \
  'TT6 — malformed, indeterminate, or unknown audit_state emits INVALID / input-malformed'

# TT6b — make the absent branch's fall-through a negative contract too: it
# must not itself emit a terminal verdict before the structural probes.
PHASE_1_5_BLOCK=$(awk '/^1\.5\./,/^2\./' "$AGENT_MD")
ABSENT_BRANCH=$(printf '%s\n' "$PHASE_1_5_BLOCK" | awk '
  /\*\*Absent audit/ { in_absent=1 }
  /\*\*Legacy audit/ { in_absent=0 }
  in_absent
')
if [[ -n "$ABSENT_BRANCH" ]] \
  && ! printf '%s\n' "$ABSENT_BRANCH" | grep -qE 'return.*verdict|verdict: (PASS|STALE|INVALID|FORCE_PUSHED)'; then
  echo "  PASS  TT6b — absent audit branch has no pre-structural terminal verdict"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT6b — absent audit branch MUST fall through without STALE / INVALID / FORCE_PUSHED"
  FAIL=$((FAIL + 1))
fi

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

# TT8 — every dispatch field has an exact validated input domain before the
# audit branch or structural probes run.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'pr_number.*positive.*integer|pr_number.*\^\[1-9\]\[0-9\]\*\$' \
  'TT8a — pr_number is validated as a positive integer'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'working_dir.*absolute.*directory|working_dir.*absolute.*git worktree' \
  'TT8b — working_dir is validated as an absolute directory/worktree'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'phase2_5_halted.*true.*false|true\|false.*phase2_5_halted' \
  'TT8c — phase2_5_halted exact boolean-token domain is validated'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'phase2_5_(blocker|critical)_count.*non-negative.*integer|counts.*\^\(0\|\[1-9\]\[0-9\]\*\)\$' \
  'TT8d — Phase 2.5 counts are validated as non-negative integers'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'phase2_5_override_reason.*null.*user-selected-emit-green-on-blocker-deferred' \
  'TT8e — override_reason exact enum is validated'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'accept_blocker_deferred_flag.*accept_critical_deferred_flag.*i_know_what_im_doing_flag.*true.*false|all three.*flags.*true.*false' \
  'TT8f — all three override flags validate exact true|false tokens'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'pr_body_excerpt.*commit_messages_excerpt.*balanced.*external-untrusted-input|optional.*envelopes.*balanced' \
  'TT8g — optional untrusted-input envelopes are validated when present'

# TT9 — caller defaults preserve missing-field compatibility, while any
# incoherent non-current tuple is rejected.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'non-current.*phase2_5_halted.*false.*phase2_5_blocker_count.*0.*phase2_5_critical_count.*0.*phase2_5_override_reason.*null|absent.*legacy.*malformed.*indeterminate.*false.*0.*0.*null' \
  'TT9 — non-current audit states require the caller-default tuple false,0,0,null'

# TT10 — blocker evidence is controlling even if halted was serialized false.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'phase2_5_halted == "true".*(OR|\|\|).*phase2_5_blocker_count > 0|phase2_5_blocker_count > 0.*(OR|\|\|).*phase2_5_halted == "true"' \
  'TT10 — blocker gate fires on halted=true OR blocker_count>0'

# TT11–TT13 — command failure is not empty-success. Unexpected merge-base
# status and every nonzero diff/log status fail closed with one stable subreason.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'merge-base.*unexpected.*INVALID.*structural_probe_failed|Exit.*other than.*0.*1.*128.*structural_probe_failed' \
  'TT11 — unexpected merge-base rc emits INVALID / structural_probe_failed'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'git diff.*non-zero.*INVALID.*structural_probe_failed|diff.*exit.*nonzero.*structural_probe_failed' \
  'TT12 — nonzero diff rc emits INVALID / structural_probe_failed'
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'git log.*non-zero.*INVALID.*structural_probe_failed|log.*exit.*nonzero.*structural_probe_failed' \
  'TT13 — nonzero log rc emits INVALID / structural_probe_failed'

# TT14 — successful structural truth table remains unchanged.
for TT14_PATTERN in \
  'Empty diff AND SHAs equal.*PASS' \
  'Empty diff AND `?is_ancestor=true`?.*PASS' \
  'Empty diff AND `?is_ancestor=false`?.*PASS' \
  'Non-empty diff AND `?is_ancestor=true`?.*STALE' \
  'Non-empty diff AND `?is_ancestor=false`?.*FORCE_PUSHED'
do
  assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
    "$TT14_PATTERN" \
    "TT14 — successful structural row preserved: $TT14_PATTERN"
done

# TT15 — caller/audit mapping can distinguish structural probe failure.
assert_in_section "$AGENT_MD" '^## Return contract' 'EOF' \
  'structural_probe_failed' \
  'TT15 — INVALID subreason contract includes structural_probe_failed'

# TT16 — blocker and critical are independent acceptance domains. `halted=true`
# may be caused by blocker/overflow state, but it must never suppress a
# simultaneously serialized critical count. The combined matrix therefore
# requires both flags when both counts are positive.
CURRENT_AUDIT_BLOCK=$(awk '/\*\*Current audit/,/\*\*Malformed, indeterminate/' "$AGENT_MD")
if printf '%s\n' "$CURRENT_AUDIT_BLOCK" | grep -qE \
  'phase2_5_critical_count > 0.*accept_critical_deferred_flag == "false"' \
  && ! printf '%s\n' "$CURRENT_AUDIT_BLOCK" | grep -qE \
  'Critical-deferred gate.*phase2_5_halted == "false"|phase2_5_critical_count > 0.*phase2_5_halted == "false"'; then
  echo "  PASS  TT16a — critical acceptance gate is independent of halted"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT16a — critical_count>0 MUST require accept_critical_deferred even when halted=true"
  FAIL=$((FAIL + 1))
fi
if printf '%s\n' "$CURRENT_AUDIT_BLOCK" | grep -qE \
  'blocker.*critical.*both.*accept_blocker_deferred_flag.*accept_critical_deferred_flag|both counts.*both acceptance flags|combined.*both.*accept_' \
  && printf '%s\n' "$CURRENT_AUDIT_BLOCK" | grep -qE \
  'halted.*true.*critical|critical.*halted.*true'; then
  echo "  PASS  TT16b — combined halted/blocker/critical matrix requires both independent acknowledgments"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT16b — current-audit paragraph MUST state the combined both-counts/both-flags matrix"
  FAIL=$((FAIL + 1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
