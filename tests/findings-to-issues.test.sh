#!/usr/bin/env bash
# tests/findings-to-issues.test.sh — fixture suites for the new agent + command wire-up.
# 5 core suites + 4 bonus suites.
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
FIX="$THIS_DIR/fixtures/findings-to-issues"
AGENT_MD="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
PACKAGED_AGENT_TOML="$REPO_ROOT/codex/agents/uberdev-findings-to-issues.toml"
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
  'pr_number.*=~.*\^\[0-9\]\+\$|=~ \^\[0-9\]\+\$' \
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
# The canonical 7-set, sorted (used as the byte-equality oracle for checks 1+2).
EXPECTED_SOURCES_SORTED=$(printf '%s\n' \
  post-impl-review-aggregate simplify-aggregate ci-refused-synthetic \
  uberscan-aggregate ubersimplify-aggregate testers-aggregate uberthink-aggregate \
  | LC_ALL=C sort)

# S15.1 — Python frozenset is importable + has exactly the 7 members.
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
  echo "  PASS  S15.1 ACCEPTED_SOURCES frozenset imports with the 7 expected members"; PASS=$((PASS+1))
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
assert_no_grep "$PACKAGED_AGENT_TOML" 'Search bucket \(30 req/min, 1000/hr authenticated\)' \
  'S16.10 — packaged Codex agent preserves the corrected Search-bucket contract'

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
