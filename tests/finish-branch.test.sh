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

PASS=0; FAIL=0
# shellcheck source=tests/_lib_assert_structural.sh
source "$THIS_DIR/_lib_assert_structural.sh"

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
F6_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
if ( CLAUDE_PLUGIN_ROOT="$F6_PLUGIN_ROOT" \
     bash -c '
       set -u
       source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
       # Test 1: clean input -> rc=0, no abort
       SCAN_DIAG=$(printf "%s" "clean code line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -eq 0 ] || exit 1
       # Test 2: AKIA leak -> rc!=0, abort should trigger
       SCAN_DIAG=$(printf "%s" "AKIAIOSFODNN7EXAMPLE" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       [ "$SCAN_RC" -ne 0 ] || exit 2
       # Test 3: SKILL.md caller idiom verbatim — assert abort decision triggers on leak
       SCAN_DIAG=$(printf "%s" "AKIAIOSFODNN7EXAMPLE" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null)
       SCAN_RC=$?
       if [ "$SCAN_RC" -eq 0 ]; then exit 3; fi
       # Test 4: diagnostic captures the matched line (anchors the abort message)
       [ -n "$SCAN_DIAG" ] || exit 4
       printf "%s" "$SCAN_DIAG" | grep -q AKIA || exit 5
       exit 0
     ' ); then
  echo "  PASS  F6 runtime: lib aborts on AKIA leak via SKILL.md caller idiom"; PASS=$((PASS+1))
else
  rc=$?
  echo "  FAIL  F6 runtime integration test failed (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
