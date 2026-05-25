#!/usr/bin/env bash
# tests/secret-scan.test.sh — behavioral lock for lib/secret-scan.sh regex-fallback
# grep exit-code handling (#189).
#
# `grep` is TRI-STATE and the three cases are NOT interchangeable:
#   0  -> one or more patterns matched -> secret found -> return 1 (fail-CLOSED)
#   1  -> no line matched              -> clean        -> return 0
#   >=2 -> grep itself failed (a malformed pattern, I/O error, …) -> the SCANNER
#         is broken, NOT a secret match. It must fail-CLOSED on a non-zero code
#         that is DISTINCT from the plain match code 1, and emit a diagnostic
#         that names the scanner failure (never a silent "clean" nor a false
#         "secret found"). A broken scanner must be distinguishable from a real
#         match.
#
# Pre-#189 the fallback was `if printf | grep …; then return 1; fi; return 0`,
# which returned 0 (clean) on grep rc=2 — a broken scanner reported clean, with
# no diagnostic (fail-OPEN). S3 is the regression that locks the fix.
#
# Runtime tests source the lib inside a bash -c subshell (mirrors the
# finish-branch.test.sh F6 idiom) and drive the function via the SKILL.md caller
# contract: SCAN_DIAG=$(… | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

PASS=0; FAIL=0
echo "## secret-scan grep rc tri-state suite (#189)"

# S1 — clean input (regex fallback grep no-match, rc=1) -> return 0.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s" "just a clean line of code" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 1
    ' ); then
  echo "  PASS  S1 clean input -> rc=0 (no secret)"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S1 clean input must return 0 (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S2 — genuine match (canonical AWS example key) -> return EXACTLY 1 via whichever
# layer fires first: gitleaks (rc=1, when installed) takes precedence, else the
# regex fallback (grep rc=0 -> return 1). Either way the result is 1 and the
# diagnostic is a real match, NOT a scanner-failure message. The key is assembled
# at runtime ("AKIA" + the rest) so this fixture file does not itself trip the
# secret scanner — the flaggable token never appears contiguously in the source,
# yet the full key still reaches the function at runtime.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      example_key="AKIA""IOSFODNN7EXAMPLE"
      SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 1 ] || exit 1
      case "$SCAN_DIAG" in *"scanner failure"*) exit 2;; esac
    ' ); then
  echo "  PASS  S2 genuine match -> rc=1 (secret found), not a scanner-failure msg"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S2 genuine match must return exactly 1 and not be a scanner-failure msg (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S3 — scanner error: grep exits 2 on EVERY call (as a malformed future pattern
# would). The fallback MUST NOT silently pass NOR claim a secret. It must
# fail-CLOSED on a non-zero code DISTINCT from the plain match code 1, and emit a
# diagnostic that names the scanner failure (not "secret found"). This is the
# #189 regression lock.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      # Force every grep invocation to exit 2 (regex/I-O error). Shadows the
      # external grep only inside this subshell; the assertions below use case
      # (no grep) so they are unaffected by the shadow.
      grep() { return 2; }
      SCAN_DIAG=$(printf "%s" "plain text no secrets here" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      # (a) fail-CLOSED: must NOT be reported clean
      [ "$SCAN_RC" -ne 0 ] || exit 1
      # (b) distinct from a real match: must NOT be the plain match code 1
      [ "$SCAN_RC" -ne 1 ] || exit 2
      # (c) diagnostic names the scanner failure
      case "$SCAN_DIAG" in *"scanner failure"*) : ;; *) exit 3;; esac
      # (d) diagnostic surfaces the offending grep exit code
      case "$SCAN_DIAG" in *"grep exited"*) : ;; *) exit 4;; esac
      # (e) diagnostic must NOT falsely claim a secret was found
      case "$SCAN_DIAG" in *"secret found"*) exit 5;; esac
    ' ); then
  echo "  PASS  S3 grep rc>=2 -> distinct scanner-failure diagnostic + fail-CLOSED (not clean, not match)"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S3 scanner error must surface a distinct diagnostic and fail-CLOSED (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
