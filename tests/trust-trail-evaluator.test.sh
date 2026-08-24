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

# assert_all_in_section <file> <section_start> <section_end> <desc> <pattern>...
#
# Section-scoped, MULTI-token, non-empty-guarded (#347). Two weaknesses of the
# single-pattern `assert_in_section` this replaces at the load-bearing sites:
#   * one incidental token anywhere in the range satisfied an assertion whose
#     description promises a whole contract (e.g. "declares absent | legacy |
#     current | malformed | indeterminate" passed on any ONE of the five), and
#   * an anchor typo yielding an EMPTY range is indistinguishable from a
#     genuinely missing clause — it just fails, so nobody notices the assertion
#     stopped inspecting anything real. Here an empty range is its own loud
#     failure, distinct from "pattern absent".
# `grep -qE PAT <<<"$V"` throughout, never `printf | grep -q`: a pipe into a -q
# grep can EPIPE-race under `set -o pipefail` on Linux CI.
# String accumulator, not an array — bash 3.2 errors on an empty array
# expansion under `set -u`.
assert_all_in_section() {
  local file="$1" section_start="$2" section_end="$3" desc="$4"
  shift 4
  local section missing="" pattern
  if [ ! -r "$file" ]; then
    echo "  FAIL  $desc (file missing/unreadable: $file)"
    FAIL=$((FAIL + 1)); return
  fi
  section="$(awk "/$section_start/,/$section_end/" "$file")"
  if [ -z "$section" ]; then
    echo "  FAIL  $desc (section $section_start..$section_end is EMPTY — refusing a vacuous verdict)"
    FAIL=$((FAIL + 1)); return
  fi
  for pattern in "$@"; do
    if ! grep -qE -e "$pattern" <<<"$section"; then
      missing="$missing
        missing: $pattern"
    fi
  done
  if [ -z "$missing" ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file: $file  section: $section_start..$section_end$missing"
    FAIL=$((FAIL + 1))
  fi
}

echo "## trust-trail-evaluator structural coverage (RFC 0002 §3.6 Phase 2.5 gate)"

# TT1 — agent mentions the Phase 2.5 gate by name in Step 1.5
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Phase 2\.5 gate|RFC 0002 §3\.6|phase2_5 inputs' \
  'TT1 — agent documents Phase 2.5 gate in Process section (RFC 0002 §3.6)'

# TT2 — caller-composed audit identity is explicit and six-state. Every one of
# the six states must be named, not just whichever one happens to appear first.
assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'TT2 — audit_state input declares ALL of absent | legacy | current | malformed | indeterminate | not_applicable' \
  '`audit_state`' \
  '"absent"' \
  '"legacy"' \
  '"current"' \
  '"malformed"' \
  '"indeterminate"' \
  '"not_applicable"'

# TT2a — absent telemetry is not legacy: skip only Phase 2.5 and continue
# through the immutable structural proof.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Absent audit.*audit_state.*absent.*fall through to Step 2|audit_state.*absent.*skip.*Phase 2\.5.*structural' \
  'TT2a — absent audit skips only Phase 2.5 telemetry and continues structural proof'

# TT2d — not_applicable is its own state, and its meaning is written down. Reusing
# `absent` here would let a stale review-pr artifact for the same PR number apply
# /review-pr halt semantics to a trail /review-pr never wrote.
assert_all_in_section "$AGENT_MD" '^### Phase 2.5 inputs' '^## Tools authorised' \
  'TT2d — not_applicable is declared and distinguished from absent' \
  'not_applicable' \
  'NOT a synonym for'
# TT2e — the instrument is a declared, validated input with a closed domain.
assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'TT2e — trust_instrument is a declared input over a closed set' \
  'trust_instrument' \
  'review-pr' \
  'premerge'
# TT2f — the arm exists, and it relaxes ONLY the reviewer-identity check. The
# structural proof staying load-bearing is the whole reason this relaxation is
# safe, so it is asserted rather than assumed — and it is asserted INSIDE the arm.
#
# Scoping this row to `^## Process` ... `^## Refusal triggers` (the obvious
# anchors, and the ones every neighbouring row here uses) is VACUOUS, measured:
# `not_applicable` also appears in Step 1's validation list, the instrument /
# audit-state coherence rule, the non-current default tuple and the malformed arm,
# while `structural primitives` also appears in Step 1.5's own heading, the absent
# arm and the all-current-gates-pass arm. Deleting this entire arm from the card
# left the row GREEN and the suite reporting `FAIL=0`. Ending the range at the
# blank line after the arm — rather than at the NEXT arm, which awk would include
# — is what makes the two shared tokens discriminate.
assert_all_in_section "$AGENT_MD" '\*\*Not applicable' '^$' \
  'TT2f — the not_applicable arm skips only the Phase 2.5 gate' \
  'not_applicable' \
  'structural primitives' \
  'load-bearing'

# TT2b — STALE verdict on a present legacy audit.
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'Legacy audit.*audit_state.*legacy.*STALE|audit_state.*legacy.*STALE' \
  'TT2b — legacy audit remains STALE'

# TT2c — STALE rationale string contains the RFC reference + v0.26.0 cite
# (constraints [hard]: "Rationale string must contain 'RFC 0002 v0.26.0'").
assert_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  'RFC 0002 v0\.26\.0|RFC 0002.*v0\.26\.0' \
  'TT2c — STALE rationale cites "RFC 0002 v0.26.0" (constraints [hard])'

# TT3 — current audits retain the Phase 2.5 halted + by_severity inputs. All
# three, plus the override reason and all three acceptance flags: a single-token
# alternation here passed while two of the six were missing.
assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'TT3 — every Phase 2.5 input is declared (halted, both counts, override, three flags)' \
  '`phase2_5_halted`' \
  '`phase2_5_blocker_count`' \
  '`phase2_5_critical_count`' \
  '`phase2_5_override_reason`' \
  '`accept_blocker_deferred_flag`' \
  '`accept_critical_deferred_flag`' \
  '`i_know_what_im_doing_flag`'
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
  && ! grep -qE 'return.*verdict|verdict: (PASS|STALE|INVALID|FORCE_PUSHED)' <<<"$ABSENT_BRANCH"; then
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

# TT15 — the return contract enumerates every verdict AND every INVALID
# subreason. The old single-token check passed on the word
# `structural_probe_failed` appearing once anywhere below the heading, which
# said nothing about the other four subreasons or the four verdicts.
# ('EOF' matches no line in this file, so the range runs to end-of-file — the
# non-empty guard makes that explicit rather than silently vacuous.)
assert_all_in_section "$AGENT_MD" '^## Return contract' 'EOF' \
  'TT15 — return contract enumerates all four verdicts and all five INVALID subreasons' \
  'verdict: PASS \| STALE \| INVALID \| FORCE_PUSHED' \
  'input_malformed' \
  'trailer_sha_not_in_local_clone' \
  'structural_probe_failed' \
  'phase2_5_blocker_deferred' \
  'phase2_5_override_unacknowledged'

# TT16 — blocker and critical are independent acceptance domains. `halted=true`
# may be caused by blocker/overflow state, but it must never suppress a
# simultaneously serialized critical count. The combined matrix therefore
# requires both flags when both counts are positive.
CURRENT_AUDIT_BLOCK=$(awk '/\*\*Current audit/,/\*\*Malformed, indeterminate/' "$AGENT_MD")
if [[ -z "$CURRENT_AUDIT_BLOCK" ]]; then
  # Without this guard both branches below would report a plain FAIL, which
  # reads as "the contract regressed" when the truth is "the anchors no longer
  # match anything and these two assertions stopped inspecting the file".
  echo "  FAIL  TT16 — the **Current audit** block is EMPTY (section anchors drifted; refusing a vacuous verdict)"
  FAIL=$((FAIL + 2))
else
if grep -qE 'phase2_5_critical_count > 0.*accept_critical_deferred_flag == "false"' <<<"$CURRENT_AUDIT_BLOCK" \
  && ! grep -qE 'Critical-deferred gate.*phase2_5_halted == "false"|phase2_5_critical_count > 0.*phase2_5_halted == "false"' <<<"$CURRENT_AUDIT_BLOCK"; then
  echo "  PASS  TT16a — critical acceptance gate is independent of halted"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT16a — critical_count>0 MUST require accept_critical_deferred even when halted=true"
  FAIL=$((FAIL + 1))
fi
if grep -qE 'blocker.*critical.*both.*accept_blocker_deferred_flag.*accept_critical_deferred_flag|both counts.*both acceptance flags|combined.*both.*accept_' <<<"$CURRENT_AUDIT_BLOCK" \
  && grep -qE 'halted.*true.*critical|critical.*halted.*true' <<<"$CURRENT_AUDIT_BLOCK"; then
  echo "  PASS  TT16b — combined halted/blocker/critical matrix requires both independent acknowledgments"
  PASS=$((PASS + 1))
else
  echo "  FAIL  TT16b — current-audit paragraph MUST state the combined both-counts/both-flags matrix"
  FAIL=$((FAIL + 1))
fi
fi

# TT17 — PR-state corroborators are dispatch INPUTS, never a fresh fetch (#303).
# Re-fetching cost two API round-trips per PR and, worse, sampled GitHub at a
# LATER instant than the head_ref_oid the structural probes are bound to.
assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  'TT17a — corroborator inputs are declared and bound to the caller projection' \
  '`status_check_rollup`' \
  '`commit_shas`' \
  'pr_view_projection' \
  'MUST NOT re-fetch'
assert_all_in_section "$AGENT_MD" '^## Tools authorised' '^## Process' \
  'TT17b — the agent has no gh tool authorisation left' \
  'git merge-base' \
  'No `gh`'
# Negative contract: the retired probe commands must not reappear anywhere.
for TT17_FORBIDDEN in \
  'gh pr view <N> --json statusCheckRollup' \
  'gh api repos/:owner/:repo/pulls/<N>/commits'
do
  if grep -qF -e "$TT17_FORBIDDEN" "$AGENT_MD"; then
    echo "  FAIL  TT17c — agent MUST NOT re-fetch corroborators: found '$TT17_FORBIDDEN'"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  TT17c — agent does not re-fetch: '$TT17_FORBIDDEN' absent"
    PASS=$((PASS + 1))
  fi
done

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
