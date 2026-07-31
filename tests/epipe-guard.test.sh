#!/usr/bin/env bash
# tests/epipe-guard.test.sh — issue #313, the class fix the M49.1 patch never
# generalised.
#
# ROOT CAUSE. Under `set -o pipefail`, a shape assertion written as
#
#     <writer> "$VAR" | grep -q PATTERN
#
# is a RACE, not a test. `grep -q` exits the instant it matches, closing the
# read end of the pipe. The writer's remaining chunked writes then take EPIPE.
# On a normal interactive shell the writer dies by SIGPIPE and bash reports the
# pipeline's rc from the LAST command (grep, rc=0) — so the bug is invisible
# locally. On GitHub Actions the Node runner starts the job shell with SIGPIPE
# ignored; an ignored disposition is inherited across fork/exec, so the writer
# does not die — it returns rc=1 with `write error: Broken pipe`, and pipefail
# promotes that 1 over grep's 0. The assertion FAILS even though its pattern
# MATCHED, and it fails more often the earlier the match and the bigger the
# payload.
#
# Reproduced deterministically with `trap "" PIPE` + pipefail + a 200 KB
# payload whose match is in the first chunk: 40/40 false FAILs for the piped
# form, 0/40 for `grep -q PATTERN <<<"$VAR"`. The herestring feeds grep from a
# temp file — there is no writer process, so there is no rc for pipefail to
# poison. Both forms present exactly one trailing newline, so the match
# semantics are identical.
#
# INVERTED POLARITY is the worse half of the class: written as
# `<writer> "$V" | grep -q BAD && fail ...`, an EPIPE after a MATCH makes the
# pipeline rc non-zero, the `&&` short-circuits, and a genuine defect is
# reported as a PASS. That shape masks failures instead of inventing them.
#
# THIS GUARD. `tests/status.test.sh` S1.15 already forbids the idiom, but only
# inside `plugins/uberdev/lib/status.sh` — it never inspects the test suite,
# which is where the idiom actually lives and where it kept spreading (110
# test files today, 86 of them running under pipefail). This file is the
# repo-wide, auto-discovering half: every `tests/*.test.sh` that sets pipefail
# must be free of the idiom. Files that do NOT set pipefail are not exposed —
# the pipeline's rc is grep's rc — so they are out of scope by construction,
# and the day one of them adds `set -o pipefail` this guard reds on every site
# it just exposed. That is the intended trigger.
#
# Comment-only lines are skipped so the class can still be DESCRIBED in prose
# (this header does exactly that). Quoted strings are NOT skipped: several
# suites (`ck`/`check`/`expect` helpers in uberscan*.test.sh,
# lib-assert-count.test.sh) `eval` their assertion strings, so a string in this
# suite is executable code and must obey the same rule.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

if [ ! -d "$TESTS_DIR" ]; then
  echo "FATAL: tests/ directory missing: $TESTS_DIR" >&2
  exit 2
fi

PASS=0
FAIL=0

# A file is exposed only when it turns pipefail on: `set -o pipefail`,
# `set -euo pipefail`, and every other flag spelling of the same switch.
PIPEFAIL_RE='set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail'

# The forbidden shape, assembled from fragments so this guard's own source can
# never match the pattern it enforces (same trick as the ripgrep guard in
# tests/test-harness-source-guards.test.sh). Reader flags are matched loosely
# (-q, -qE, -Fq, -qiE, -Fxq ...) because only `-q` early-exit matters; a plain
# `grep`, `grep -c` or `grep -o` drains its input and is not part of the class.
_EPIPE_WRITER='(echo|printf)'
_EPIPE_PIPE='[^|]*[|][[:space:]]*'
_EPIPE_READER='grep[[:space:]]+-[A-Za-z]*q[A-Za-z]*([[:space:]]|$)'
EPIPE_RE="${_EPIPE_WRITER}${_EPIPE_PIPE}${_EPIPE_READER}"

# Print `lineno:line` for every offending line in $1, skipping comment-only
# lines. The inner `grep -v` drains its input, so this helper is not itself an
# instance of the class it hunts.
_epipe_hits() {
  grep -nE -e "$EPIPE_RE" "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

echo "## EPIPE class guard (#313) — pipefail-exposed tests must use herestrings"

echo
echo "== E1: no pipefail-setting tests/*.test.sh feeds a writer into 'grep -q' =="
SCANNED=0
for f in "$TESTS_DIR"/*.test.sh; do
  grep -qE -e "$PIPEFAIL_RE" "$f" 2>/dev/null || continue
  SCANNED=$((SCANNED + 1))
  HITS="$(_epipe_hits "$f")"
  [ -n "$HITS" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "  FAIL  $(basename "$f"):${hit%%:*} pipes a writer into an early-exiting 'grep -q' under pipefail"
    echo "        line:   ${hit#*:}"
    echo "        expect: grep -q PATTERN <<<\"\$VAR\"   (herestring — no writer, no EPIPE)"
    FAIL=$((FAIL + 1))
  done <<<"$HITS"
done
if [ "$FAIL" -eq 0 ]; then
  echo "  PASS  all $SCANNED pipefail-setting test files are herestring-clean"
  PASS=$((PASS + 1))
fi

echo
echo "== E2: the detector actually detects (no vacuous green) =="
# Assemble the offending line at RUNTIME from split tokens; the literal must
# never appear contiguously in this file, or E1 would flag the guard itself.
_w='ec''ho'
_r='gr''ep'
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
{
  printf 'set -o pipefail\n'
  printf '%s "$V" | %s -q PATTERN\n' "$_w" "$_r"
} >"$TMPD/dirty.test.sh"
{
  printf 'set -o pipefail\n'
  printf '%s -q PATTERN <<<"$V"\n' "$_r"
  printf '# %s "$V" | %s -q PATTERN   (described in prose, not executed)\n' "$_w" "$_r"
} >"$TMPD/clean.test.sh"

if [ -n "$(_epipe_hits "$TMPD/dirty.test.sh")" ]; then
  echo "  PASS  E2.1 detector flags a known-bad fixture"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E2.1 detector missed a known-bad fixture — E1 above proves nothing"
  FAIL=$((FAIL + 1))
fi
if [ -z "$(_epipe_hits "$TMPD/clean.test.sh")" ]; then
  echo "  PASS  E2.2 detector accepts the herestring form and ignores prose comments"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E2.2 detector false-positives on the herestring form or on a comment"
  FAIL=$((FAIL + 1))
fi

echo
echo "== E3: the scan reached a representative share of the suite =="
# A path/glob regression that scanned zero (or a handful of) files would make
# E1 green while checking nothing. The suite is ~110 files, ~86 under pipefail.
if [ "$SCANNED" -ge 40 ]; then
  echo "  PASS  E3.1 scanned $SCANNED pipefail-setting test files"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E3.1 only $SCANNED pipefail-setting test files scanned — glob or gate regressed"
  FAIL=$((FAIL + 1))
fi

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
