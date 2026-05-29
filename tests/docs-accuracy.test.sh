#!/usr/bin/env bash
# Guard against the documentation-drift class fixed in issue #273:
#   1. plugins/uberdev/docs/testing.md must describe the REAL harness
#      (tests/*.test.sh shape-checks + test.yml two-job matrix; marketplace key
#      uberdev@uberdev) — not verbatim upstream Superpowers (tests/claude-code/,
#      test-helpers.sh, analyze-token-usage.py, run-skill-tests.sh,
#      superpowers@superpowers-dev, "run FROM the superpowers directory").
#   2. CONTRIBUTING.md must not carry the dead [Repo layout](README.md#repo-layout)
#      link (README has no such anchor) nor the false "no behavioral tests" claim,
#      and must point at .github/workflows/test.yml as the test-set SSOT.
#   3. docs/rfc/ must have NO duplicate RFC numbers (the 0004 collision: the
#      alias RFC was renumbered to 0011; the dispatch RFC keeps 0004).
#   4. The dispatch RFC (0004) §4/§5 version refs must agree with its Status
#      line + the CHANGELOG: target v0.30.0, not v0.29.0.
#   5. The alias-RFC cross-refs in hooks/session-start + lib/aliases-sync.sh must
#      point at RFC 0011, and no stale 0004-alias-install path ref may survive.
#
# These are structural greps over the shipped docs/shell files — they exercise
# the source bytes, not a running session. Every assertion below FAILS on the
# pre-#273 tree and PASSES after the fix.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTING_MD="$REPO_ROOT/plugins/uberdev/docs/testing.md"
CONTRIBUTING_MD="$REPO_ROOT/CONTRIBUTING.md"
RFC_DIR="$REPO_ROOT/docs/rfc"
DISPATCH_RFC="$RFC_DIR/0004-cross-platform-dispatch-backends.md"
ALIAS_RFC="$RFC_DIR/0011-alias-install-reliability.md"
SESSION_START="$REPO_ROOT/plugins/uberdev/hooks/session-start"
ALIASES_SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
TEST_YML="$REPO_ROOT/.github/workflows/test.yml"

# Hard-fail (exit 2) on a missing input — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$TESTING_MD" "$CONTRIBUTING_MD" "$DISPATCH_RFC" "$ALIAS_RFC" \
         "$SESSION_START" "$ALIASES_SYNC" "$TEST_YML"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

PASS=0
FAIL=0

# Assert a regex IS present in a file.
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# Assert a fixed string is ABSENT from a file (grep -F: literal, no regex).
assert_absent_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        unexpected literal: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

echo "== testing.md describes the REAL harness, not vendored Superpowers =="
# Vendored-upstream tokens that must NOT survive (the whole pre-#273 file).
assert_absent_fixed "$TESTING_MD" "tests/claude-code/"        "T1.1 testing.md drops the upstream tests/claude-code/ path"
assert_absent_fixed "$TESTING_MD" "test-helpers.sh"           "T1.2 testing.md drops upstream test-helpers.sh"
assert_absent_fixed "$TESTING_MD" "analyze-token-usage.py"    "T1.3 testing.md drops upstream analyze-token-usage.py"
assert_absent_fixed "$TESTING_MD" "run-skill-tests.sh"        "T1.4 testing.md drops upstream run-skill-tests.sh"
assert_absent_fixed "$TESTING_MD" "superpowers@superpowers-dev" "T1.5 testing.md drops upstream superpowers@superpowers-dev marketplace key"
# Case-insensitive: kill any 'superpowers directory' instruction in any casing.
if grep -qiE 'superpowers (plugin )?directory' "$TESTING_MD"; then
  echo "  FAIL  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"
  echo "        file: $TESTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"; PASS=$((PASS + 1))
fi
# Real harness IS described.
assert_grep "$TESTING_MD" 'tests/\*\.test\.sh'              "T1.7 testing.md names the real tests/*.test.sh shape-checks"
assert_grep "$TESTING_MD" '\.github/workflows/test\.yml'    "T1.8 testing.md points at .github/workflows/test.yml"
assert_grep "$TESTING_MD" 'uberdev@uberdev'                 "T1.9 testing.md uses the real uberdev@uberdev marketplace key"
assert_grep "$TESTING_MD" 'shape-checks-windows|two-job|windows-latest' "T1.10 testing.md documents the two-job CI matrix"
assert_grep "$TESTING_MD" 'solve-pipeline-zsh\.test\.sh'    "T1.11 testing.md names the zsh-runtime fixture"

echo
echo "== CONTRIBUTING.md: no dead link, no false claim, test.yml is SSOT =="
assert_absent_fixed "$CONTRIBUTING_MD" "README.md#repo-layout" "T2.1 CONTRIBUTING drops the dead README.md#repo-layout link"
# The false 'no runtime behavioral tests' sentence must be gone.
if grep -qiE 'no runtime behavioral tests' "$CONTRIBUTING_MD"; then
  echo "  FAIL  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"
  echo "        file: $CONTRIBUTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"; PASS=$((PASS + 1))
fi
assert_grep "$CONTRIBUTING_MD" '\.github/workflows/test\.yml' "T2.3 CONTRIBUTING points at test.yml"
assert_grep "$CONTRIBUTING_MD" 'single source of truth|source of truth' "T2.4 CONTRIBUTING frames test.yml as the test-set SSOT"

echo
echo "== docs/rfc/: no duplicate RFC numbers =="
# Extract the leading 4-digit number from every docs/rfc/NNNN-*.md filename and
# assert each appears exactly once. Catches the 0004 collision (and any future
# one) dynamically, without hardcoding the current RFC set.
DUP_NUMS="$(
  for f in "$RFC_DIR"/[0-9][0-9][0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    echo "${base%%-*}"
  done | sort | uniq -d
)"
if [ -n "$DUP_NUMS" ]; then
  echo "  FAIL  T3.1 every docs/rfc/ number is unique"
  echo "        duplicate RFC number(s): $(echo "$DUP_NUMS" | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T3.1 every docs/rfc/ number is unique (no NNNN collision)"; PASS=$((PASS + 1))
fi
# The renumbered alias RFC exists at 0011 and self-identifies as RFC 0011.
assert_grep "$ALIAS_RFC" '^# RFC 0011 — Alias-Install Reliability' "T3.2 alias RFC header self-identifies as RFC 0011"
# The dispatch RFC keeps 0004.
assert_grep "$DISPATCH_RFC" '^# RFC 0004 — Cross-Platform Dispatch' "T3.3 dispatch RFC keeps RFC 0004 header"

echo
echo "== dispatch RFC 0004: internal version refs agree on v0.30.0 =="
# Status line is the anchor of truth (already v0.30.0); §4/§5 must match it.
assert_grep "$DISPATCH_RFC" 'Status.*Implemented — v0\.30\.0' "T4.1 dispatch RFC Status is v0.30.0"
# NOTE: the RFC uses a multibyte UTF-8 arrow (U+2192) between versions. Match
# it with `.*` (not a single `.`) so the pattern holds in a C/POSIX locale too
# (where `.` is one byte and the arrow is three) — env -i / Git Bash safe.
assert_grep "$DISPATCH_RFC" 'version bump .0\.29\.0.*0\.30\.0' "T4.2 §4 File-impact bump reads 0.29.0 -> 0.30.0"
assert_grep "$DISPATCH_RFC" 'CHANGELOG\.md.*## \[0\.30\.0\].*section' "T4.3 §5 Migration cites the [0.30.0] CHANGELOG section"
assert_grep "$DISPATCH_RFC" 'git tag .v0\.30\.0' "T4.4 §5 Migration cites tag v0.30.0"
# The wrong target version must be gone from §4/§5 (the contradiction). A bare
# 0.28.0/0.29.0 as the bump TARGET '-> 0.29.0' or tag 'v0.29.0' must not survive.
if grep -qE '0\.28\.0.*0\.29\.0|## \[0\.29\.0\] section|git tag .v0\.29\.0' "$DISPATCH_RFC"; then
  echo "  FAIL  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"
  echo "        file: $DISPATCH_RFC"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"; PASS=$((PASS + 1))
fi

echo
echo "== alias-RFC cross-refs repointed to RFC 0011; no stale 0004-alias path =="
assert_grep "$SESSION_START" 'RFC 0011' "T5.1 hooks/session-start cites RFC 0011"
assert_grep "$ALIASES_SYNC"  'RFC 0011' "T5.2 lib/aliases-sync.sh cites RFC 0011"
# The cross-ref files must no longer cite the alias work as 'RFC 0004' (the
# dispatch RFC owns 0004; neither of these two files references dispatch).
assert_absent_fixed "$SESSION_START" "RFC 0004" "T5.3 hooks/session-start no longer cites the (dispatch-owned) RFC 0004"
assert_absent_fixed "$ALIASES_SYNC"  "RFC 0004" "T5.4 lib/aliases-sync.sh no longer cites the (dispatch-owned) RFC 0004"
# No surviving path reference to the old alias-RFC filename anywhere in the two
# cross-ref files or the renamed RFC itself.
for f in "$SESSION_START" "$ALIASES_SYNC" "$ALIAS_RFC"; do
  assert_absent_fixed "$f" "0004-alias-install-reliability" "T5.5 no stale 0004-alias-install-reliability path in $(basename "$f")"
done

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
