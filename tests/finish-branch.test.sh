#!/usr/bin/env bash
# tests/finish-branch.test.sh — regression lock for the lib/secret-scan.sh extraction.
#
# Tests assert that finish-branch/SKILL.md sources the extracted library and
# no longer inlines run_secret_scan_stdin. Behaviour-preserving — pre-refactor
# state has the function inline; post-refactor state has the `source` line.
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
LIB="$REPO_ROOT/plugins/uberdev/lib/secret-scan.sh"
ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
MERGE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
COMMAND_WORKSPACE="$REPO_ROOT/plugins/uberdev/lib/command-workspace.py"

PASS=0; FAIL=0
# shellcheck source=tests/_lib_assert_structural.sh
source "$THIS_DIR/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

echo "## finish-branch lib/secret-scan extraction regression suite"

# F1: SKILL.md MUST contain the source line for the extracted library.
if grep -qF 'source "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"' "$SKILL"; then
  echo "  PASS  F1 SKILL.md sources lib/secret-scan.sh"; PASS=$((PASS+1))
else
  echo "  FAIL  F1 SKILL.md must source lib/secret-scan.sh"; FAIL=$((FAIL+1))
fi

# F2: SKILL.md MUST NOT define run_secret_scan_stdin inline anymore — the
# extraction is behaviour-preserving via the sourced library. Detects the
# function-definition line specifically (not a call site).
if grep -qE '^[[:space:]]*run_secret_scan_stdin\(\)[[:space:]]*\{' "$SKILL"; then
  echo "  FAIL  F2 SKILL.md still defines run_secret_scan_stdin inline (should be sourced from lib)"; FAIL=$((FAIL+1))
else
  echo "  PASS  F2 SKILL.md no longer inlines run_secret_scan_stdin definition"; PASS=$((PASS+1))
fi

# F3: lib/secret-scan.sh exists and defines uberdev_run_secret_scan_stdin.
if [[ ! -f "$LIB" ]]; then
  echo "  FAIL  F3 lib/secret-scan.sh missing"; FAIL=$((FAIL+1))
elif grep -qE '^[[:space:]]*uberdev_run_secret_scan_stdin\(\)[[:space:]]*\{' "$LIB"; then
  echo "  PASS  F3 lib/secret-scan.sh defines uberdev_run_secret_scan_stdin"; PASS=$((PASS+1))
else
  echo "  FAIL  F3 lib/secret-scan.sh missing function uberdev_run_secret_scan_stdin"; FAIL=$((FAIL+1))
fi

# F4: Source-time idempotency guard mirrors lib/config-read.sh:26-29.
if grep -qE '_UBERDEV_SECRET_SCAN_LOADED:?-?0[^a-zA-Z]+=.+1' "$LIB" 2>/dev/null \
   || grep -qF '_UBERDEV_SECRET_SCAN_LOADED=1' "$LIB" 2>/dev/null; then
  echo "  PASS  F4 lib/secret-scan.sh has _UBERDEV_SECRET_SCAN_LOADED guard"; PASS=$((PASS+1))
else
  echo "  FAIL  F4 lib/secret-scan.sh missing source-time idempotency guard"; FAIL=$((FAIL+1))
fi

# F5: The library MUST retain both the gitleaks primary and the regex fallback
# (fail-CLOSED on either) — behaviour parity with the pre-refactor function.
if grep -qF 'command -v gitleaks' "$LIB" && grep -qE 'AKIA|aws_access_key|BEGIN .* PRIVATE KEY' "$LIB"; then
  echo "  PASS  F5 lib/secret-scan.sh retains gitleaks primary + regex fallback"; PASS=$((PASS+1))
else
  echo "  FAIL  F5 lib/secret-scan.sh missing gitleaks primary or regex fallback patterns"; FAIL=$((FAIL+1))
fi

# F6: Runtime integration — pipe a known AKIA-bearing input through the lib
# using the SKILL.md caller idiom (`SCAN_DIAG=$(... 2>&1 >/dev/null); SCAN_RC=$?`)
# and assert the abort decision triggers. This is the regression that the
# structural-only F1-F5 assertions missed before; F6 plugs that gap.
#
# The canonical AWS example key is ASSEMBLED AT RUNTIME ("AKIA" + the rest) so
# the flaggable token never appears contiguously in these source bytes. That is
# not cosmetic: finish-branch's own pre-push scan runs over the to-be-pushed
# DIFF, so a contiguous literal on a changed (or merely adjacent context) line
# hard-aborts the push of this very file. Same rule as secret-scan.test.sh S2.
F6_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
if ( CLAUDE_PLUGIN_ROOT="$F6_PLUGIN_ROOT" \
     bash -c '
       set -u
       source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
       example_key="AKIA""IOSFODNN7EXAMPLE"
       # Test 1: clean input -> rc=0, no abort
       SCAN_DIAG=$(printf "%s" "clean code line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -eq 0 ] || exit 1
       # Test 2: AKIA leak -> rc!=0, abort should trigger
       SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -ne 0 ] || exit 2
       # Test 3: SKILL.md caller idiom verbatim — assert abort decision triggers on leak
       SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       if [ "$SCAN_RC" -eq 0 ]; then exit 3; fi
       # Test 4: diagnostic captures the matched line (anchors the abort message)
       [ -n "$SCAN_DIAG" ] || exit 4
       grep -q AKIA <<<"$SCAN_DIAG" || exit 5
       exit 0
     ' ); then
  echo "  PASS  F6 runtime: lib aborts on AKIA leak via SKILL.md caller idiom"; PASS=$((PASS+1))
else
  rc=$?
  echo "  FAIL  F6 runtime integration test failed (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# F7-F10 — run-id contract convergence (#345).
#
# finish-branch used to declare its OWN widened run-id dialect
# (^[0-9]{8}-[0-9]{6}-[0-9a-z]{4,40}$) so it would accept the `nohead` sentinel
# that orchestrator Phase 0 minted. Every other consumer validates the canonical
# RUN_ID_REGEX (^[0-9]{8}-[0-9]{6}-[a-f0-9]+$), so a `nohead` run resolved here
# and was rejected as invalid_run_id there. Nothing locked either literal, which
# is exactly how the two drifted apart. These four assertions are that lock.
# ---------------------------------------------------------------------------

# Canonical form, declared once here and cross-checked against every producer
# and consumer below.
CANONICAL_RUN_ID_REGEX='^[0-9]{8}-[0-9]{6}-[a-f0-9]+$'

# Extract, never re-type: the assertions must fail when the FILES drift, not
# when this test's copy of a literal drifts.
FB_RUN_ID_FORMAT="$(sed -nE "s/^RUN_ID_FORMAT='(.*)'\$/\1/p" "$SKILL" | head -1)"
ORCH_SENTINEL="$(sed -nE 's/.*git rev-parse --short HEAD 2>\/dev\/null \|\| echo ([A-Za-z0-9]+).*/\1/p' "$ORCHESTRATOR" | head -1)"

# F7: finish-branch declares the canonical regex — no local dialect.
if [[ "$FB_RUN_ID_FORMAT" == "$CANONICAL_RUN_ID_REGEX" ]]; then
  echo "  PASS  F7 finish-branch RUN_ID_FORMAT is the canonical RUN_ID_REGEX"; PASS=$((PASS+1))
else
  echo "  FAIL  F7 finish-branch RUN_ID_FORMAT drifted: got '$FB_RUN_ID_FORMAT' want '$CANONICAL_RUN_ID_REGEX'"; FAIL=$((FAIL+1))
fi

# F8: the cited source of truth still declares that same regex. If merge-pipeline
# renames or re-shapes RUN_ID_REGEX, this reds instead of letting finish-branch's
# comment silently become a lie.
if grep -qF "\`RUN_ID_REGEX\` | \`$CANONICAL_RUN_ID_REGEX\`" "$MERGE_PIPELINE" \
   && grep -qF 'RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")' "$COMMAND_WORKSPACE"; then
  echo "  PASS  F8 merge-pipeline RUN_ID_REGEX + command-workspace.py agree with F7"; PASS=$((PASS+1))
else
  echo "  FAIL  F8 canonical RUN_ID_REGEX missing from merge-pipeline/SKILL.md or lib/command-workspace.py"; FAIL=$((FAIL+1))
fi

# F9: the orchestrator Phase 0 mint must PRODUCE a run-id that F7's regex
# accepts. This is the root-cause assertion — it runs the actual sentinel token
# through the actual extracted regex, so any future sentinel that leaves the
# hex alphabet (as `nohead` did) reds here rather than in production.
F9_FAILURES=''
[[ -n "$ORCH_SENTINEL" ]] || F9_FAILURES="$F9_FAILURES sentinel-not-extractable"
[[ -n "$FB_RUN_ID_FORMAT" ]] || F9_FAILURES="$F9_FAILURES format-not-extractable"
if [[ -n "$ORCH_SENTINEL" && -n "$FB_RUN_ID_FORMAT" ]]; then
  [[ "20260101-120000-$ORCH_SENTINEL" =~ $FB_RUN_ID_FORMAT ]] \
    || F9_FAILURES="$F9_FAILURES sentinel-rejected:$ORCH_SENTINEL"
  # A real short SHA must still resolve, and the retired sentinel must not.
  [[ "20260101-120000-a1b2c3d" =~ $FB_RUN_ID_FORMAT ]] \
    || F9_FAILURES="$F9_FAILURES short-sha-rejected"
  [[ "20260101-120000-nohead" =~ $FB_RUN_ID_FORMAT ]] \
    && F9_FAILURES="$F9_FAILURES nohead-still-accepted"
fi
grep -qF '|| echo nohead' "$ORCHESTRATOR" && F9_FAILURES="$F9_FAILURES nohead-sentinel-still-minted"
if [[ -z "$F9_FAILURES" ]]; then
  echo "  PASS  F9 orchestrator sentinel '$ORCH_SENTINEL' satisfies finish-branch RUN_ID_FORMAT"; PASS=$((PASS+1))
else
  echo "  FAIL  F9 run-id producer/consumer disagree:$F9_FAILURES"; FAIL=$((FAIL+1))
fi

# F10: the PR TITLE is secret-scanned before it ships (#303). finish-branch used
# to enumerate exactly two scan targets (the push diff and the composed body)
# while `gh pr create --title` published a third, unscanned text.
F10_FAILURES=''
grep -qF 'abort_if_secret "composed PR title"' "$SKILL" || F10_FAILURES="$F10_FAILURES no-title-abort"
grep -qF 'PR_TITLE_VAR" | uberdev_run_secret_scan_stdin' "$SKILL" || F10_FAILURES="$F10_FAILURES title-not-piped-to-scanner"
# Order matters: the scan must precede the publish, not follow it.
L_TITLE_SCAN="$(grep -nF 'abort_if_secret "composed PR title"' "$SKILL" | head -1 | cut -d: -f1)"
L_PR_CREATE="$(grep -nF 'PR_URL=$(gh pr create --title' "$SKILL" | head -1 | cut -d: -f1)"
if [[ -n "$L_TITLE_SCAN" && -n "$L_PR_CREATE" && "$L_TITLE_SCAN" -lt "$L_PR_CREATE" ]]; then :; else
  F10_FAILURES="$F10_FAILURES scan-not-before-publish($L_TITLE_SCAN/$L_PR_CREATE)"
fi
# The abort message names the escape hatch by expanding the library's marker
# variable — never by re-typing the literal.
grep -qF 'UBERDEV_SECRET_SCAN_ALLOW_MARKER' "$SKILL" || F10_FAILURES="$F10_FAILURES abort-message-omits-allow-marker"
if [[ -z "$F10_FAILURES" ]]; then
  echo "  PASS  F10 PR title is scanned before gh pr create and the abort names the allowlist"; PASS=$((PASS+1))
else
  echo "  FAIL  F10 PR-title scan contract broken:$F10_FAILURES"; FAIL=$((FAIL+1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
