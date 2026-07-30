#!/usr/bin/env bash
# Tests for the shared structural assertion helpers in
# tests/_lib_assert_structural.sh. Issue #275: assert_count must NOT pass an absence assertion
# (expected count 0) vacuously when its target file is missing or unreadable.
#
# Root cause: the old body was
#   actual=$(awk "/$s/,/$e/" "$file" | grep -cE -e "$pattern" || true)
# A missing $file makes awk emit nothing on stdout (and error on stderr),
# grep -c reads empty input and prints 0 (exit 1), and `|| true` swallows the
# whole failure → actual=0 → any caller with expected==0 PASSES vacuously even
# though the file it claims to inspect does not exist. All three current
# callers preflight, but assert_count is the SSOT used by 6+ files; a future
# caller's absence checks would silently pass. The fix adds a fail-loud
# `[ -r "$file" ]` preflight and captures awk's rc separately so a missing
# file or an awk crash is surfaced as a FAIL, never masked as a 0-count PASS.
#
# Same `set -u; set -o pipefail`, manual PASS/FAIL counter convention as the
# rest of the suite (NOT `set -e`; see test-harness-source-guards.test.sh).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/tests/_lib_assert_structural.sh"

if [ ! -r "$HELPER" ]; then
  echo "FATAL: _lib_assert_structural.sh missing/unreadable: $HELPER" >&2
  exit 2
fi

# Source the SSOT helper under test. assert_count mutates the caller's
# $PASS/$FAIL — so each scenario below runs assert_count inside a SUBSHELL
# that seeds its own PASS=0/FAIL=0 and echoes the resulting counters, which
# this outer harness then inspects. That keeps the inner assert_count's
# bookkeeping from polluting the outer harness's own PASS/FAIL totals.
# shellcheck source=tests/_lib_assert_structural.sh
. "$HELPER" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

PASS=0
FAIL=0

# Outer-harness assertion primitive (independent of assert_count).
expect() { # $1=label  $2=condition-string(eval'd)  $3=fail-detail
  if eval "$2"; then
    echo "  PASS  $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $1"; echo "        $3"; FAIL=$((FAIL + 1))
  fi
}

# run_assert_count <file> <start> <end> <pattern> <expected>
# Runs assert_count in a subshell with fresh inner counters and prints a
# single machine-readable line:  <inner_PASS> <inner_FAIL> :: <assert_count stdout...>
# so callers can assert which counter the inner call bumped AND inspect its
# message text.
#
# IMPORTANT: assert_count mutates PASS/FAIL in *its own* shell. We must NOT run
# it inside a `$(...)` command substitution (that spawns yet another subshell,
# so its counter bump is lost). Instead redirect its output to a temp file and
# read PASS/FAIL back in the SAME subshell that invoked it.
run_assert_count() {
  (
    PASS=0; FAIL=0
    local tmp; tmp="$(mktemp)"
    assert_count "$1" "$2" "$3" "$4" "$5" "lib-assert-count probe" >"$tmp" 2>&1
    printf '%s %s :: %s\n' "$PASS" "$FAIL" "$(cat "$tmp")"
    rm -f "$tmp"
  )
}

# run_assert_in_section <file> <start> <end> <pattern>
# Same counter-preserving probe for assert_in_section.
run_assert_in_section() {
  (
    PASS=0; FAIL=0
    local tmp; tmp="$(mktemp)"
    assert_in_section "$1" "$2" "$3" "$4" "lib-assert-in-section probe" >"$tmp" 2>&1
    printf '%s %s :: %s\n' "$PASS" "$FAIL" "$(cat "$tmp")"
    rm -f "$tmp"
  )
}

FIXTURE="$(mktemp)"
LARGE_FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE" "$LARGE_FIXTURE"' EXIT
cat >"$FIXTURE" <<'EOF'
START
match-line one
noise
match-line two
END
junk-after-end match-line three
EOF

echo "== AC1: present file, expected==N>0 — happy path still PASSES (regression) =="
RES="$(run_assert_count "$FIXTURE" '^START$' '^END$' '^match-line' 2)"
P="${RES%% *}"; rest="${RES#* }"; F="${rest%% *}"
expect "present file, count 2 inside section → inner PASS" \
  "[ \"\$P\" = 1 ] && [ \"\$F\" = 0 ]" \
  "expected inner PASS=1 FAIL=0, got [$RES]"

echo "== AC2: present file, genuine absence (expected==0) — PASSES, NOT masked (regression) =="
# Pattern that legitimately appears 0 times inside a present, readable file —
# this is the valid absence assertion that MUST keep passing. (grep -c exits 1
# here; the fix must treat that as a real 0, not as an error.)
RES="$(run_assert_count "$FIXTURE" '^START$' '^END$' '^this-pattern-is-absent$' 0)"
P="${RES%% *}"; rest="${RES#* }"; F="${rest%% *}"
expect "present file, legit 0-count → inner PASS (not error-masked)" \
  "[ \"\$P\" = 1 ] && [ \"\$F\" = 0 ]" \
  "expected inner PASS=1 FAIL=0, got [$RES]"

echo "== AC3: MISSING file with expected==0 — must FAIL LOUD, not pass vacuously (the bug) =="
MISSING="$REPO_ROOT/tests/__nonexistent_assert_count_fixture__.sh"
[ ! -e "$MISSING" ] || { echo "FATAL: test fixture path unexpectedly exists: $MISSING" >&2; exit 2; }
RES="$(run_assert_count "$MISSING" '^START$' '^END$' 'anything' 0)"
P="${RES%% *}"; rest="${RES#* }"; F="${rest%% *}"
expect "missing file + expected 0 → inner FAIL (no vacuous PASS)" \
  "[ \"\$P\" = 0 ] && [ \"\$F\" = 1 ]" \
  "VACUOUS-PASS BUG: missing file with expected==0 should bump FAIL, got [$RES]"
expect "missing-file FAIL message names unreadable/missing file" \
  "printf '%s' \"\$RES\" | grep -qiE 'unreadable|missing|not readable'" \
  "FAIL diagnostic should identify the unreadable/missing file, got [$RES]"

echo "== AC4: UNREADABLE file with expected==0 — must FAIL LOUD too =="
# Skip when running as root (chmod 000 is ineffective for uid 0).
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  AC4 unreadable-file case (running as root; chmod 000 is a no-op)"
else
  UNREADABLE="$(mktemp)"
  printf 'START\nEND\n' >"$UNREADABLE"
  chmod 000 "$UNREADABLE"
  RES="$(run_assert_count "$UNREADABLE" '^START$' '^END$' 'anything' 0)"
  chmod 644 "$UNREADABLE"; rm -f "$UNREADABLE"
  P="${RES%% *}"; rest="${RES#* }"; F="${rest%% *}"
  expect "unreadable file + expected 0 → inner FAIL (no vacuous PASS)" \
    "[ \"\$P\" = 0 ] && [ \"\$F\" = 1 ]" \
    "VACUOUS-PASS BUG: unreadable file with expected==0 should bump FAIL, got [$RES]"
fi

echo "== AC5: assert_in_section drains a large early-match section under pipefail =="
# A quiet grep may stop after the early match and close its read end while awk
# still has this deliberately large section to emit. Under a caller's
# `pipefail`, GNU awk/mawk then reports SIGPIPE (141) and turns a real match into
# a false failure. The matcher must consume the complete section instead.
{
  printf '%s\n' 'outside' '## SECTION START' 'EARLY_MATCH'
  awk 'BEGIN { for (i = 0; i < 250000; i++) printf "late-content-%06d-abcdefghijklmnopqrstuvwxyz0123456789\n", i }'
  printf '%s\n' '## SECTION END' 'outside-again'
} >"$LARGE_FIXTURE"

RES="$(run_assert_in_section "$LARGE_FIXTURE" '^## SECTION START$' '^## SECTION END$' '^EARLY_MATCH$')"
P="${RES%% *}"; rest="${RES#* }"; F="${rest%% *}"
expect "early match in a large section remains a PASS under pipefail" \
  "[ \"\$P\" = 1 ] && [ \"\$F\" = 0 ]" \
  "SIGPIPE BUG: expected inner PASS=1 FAIL=0, got [$RES]"

# Shape-lock the portability contract even on a platform where SIGPIPE happens
# not to reproduce for a particular fixture size.
ASSERT_IN_SECTION_BODY="$(sed -n '/^assert_in_section()/,/^}/p' "$HELPER")"
expect "assert_in_section uses a draining grep consumer" \
  "! grep -E 'grep[[:space:]]+(-[[:alnum:]]*q[[:alnum:]]*|--quiet)([[:space:]]|$)' >/dev/null <<<\"\$ASSERT_IN_SECTION_BODY\"" \
  "assert_in_section must not use quiet grep on an awk pipeline"

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
