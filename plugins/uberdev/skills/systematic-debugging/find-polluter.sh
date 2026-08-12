#!/usr/bin/env bash
# Vendored from obra/superpowers@3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9 (v6.2.0, MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt; local addition: (1) fail-loud exit 2 whenever the run cannot back a verdict — no matched test files, an incomplete file search, a runner that cannot execute, a matched path the file list could not carry intact, or a pollution target already present; (2) whitespace- and glob-safe enumeration — upstream iterates the unquoted match string and counts its lines, this copy reads the matches into an array and counts the array (#430)
# Bisection script to find which test creates unwanted files/state
# Usage: ./find-polluter.sh <file_or_dir_to_check> <test_pattern>
# Example: ./find-polluter.sh '.git' 'src/**/*.test.ts'
# Exit: 0 = every matched test ran and none polluted; 1 = polluter found (or bad usage);
#       2 = verdict refused — nothing matched, the file search was incomplete, the test
#           runner could not be executed, a matched path did not survive the file list
#           intact, the pollution target was already present so a test would not have
#           run, or fewer tests ran than were matched

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <file_to_check> <test_pattern>"
  echo "Example: $0 '.git' 'src/**/*.test.ts'"
  exit 1
fi

POLLUTION_CHECK="$1"
TEST_PATTERN="$2"

echo "🔍 Searching for test that creates: $POLLUTION_CHECK"
echo "Test pattern: $TEST_PATTERN"
echo ""

# Get list of test files (find . emits ./-prefixed paths, so accept the
# pattern written with or without a leading ./)
TEST_PATTERN="${TEST_PATTERN#./}"
# find -path can't match '**/' against zero directory levels, so a pattern
# like src/**/*.test.ts would skip src/top.test.ts; also try the pattern
# with '**/' collapsed to cover files directly under the base directory.
# Both forms are kept in variables so a refusal can print the exact search
# expressions that were executed. Those are normalised spellings of the
# caller's pattern, not the caller's literal input — the literal input is
# echoed verbatim on the "Test pattern:" line above, so between the two a
# reader can see both what was typed and what was actually searched.
SEARCHED_NESTED="./$TEST_PATTERN"
SEARCHED_FLAT="./${TEST_PATTERN//\*\*\//}"
# pipefail is set inside the substitution only. Without it the assignment sees
# sort's status, so a walk that could not read part of the tree (permissions,
# I/O errors, symlink or depth limits, a missing find) would hand a TRUNCATED
# list to a confident clean verdict — a false negative with no signal.
FIND_RC=0
TEST_LIST="$(set -o pipefail; find . \( -path "$SEARCHED_NESTED" -o -path "$SEARCHED_FLAT" \) | sort -u)" || FIND_RC=$?
if [ "$FIND_RC" -ne 0 ]; then
  echo "" >&2
  echo "❌ The search for test files failed (exit $FIND_RC) - refusing to report a verdict." >&2
  echo "   Searched: $SEARCHED_NESTED" >&2
  echo "   Searched: $SEARCHED_FLAT" >&2
  echo "   The enumeration is incomplete (see the search error above), so it proves nothing." >&2
  exit 2
fi

# Read into an array. The count used to be taken from the line count while the
# loop re-read the same string as IFS-split, glob-expanded words: a matched path
# containing a space was torn into fragments and one containing a glob
# metacharacter was replaced, both under an unchanged count and a green verdict.
TEST_FILES=()
while IFS= read -r TEST_FILE; do
  [ -n "$TEST_FILE" ] || continue
  TEST_FILES+=("$TEST_FILE")
done <<< "$TEST_LIST"
TOTAL=${#TEST_FILES[@]}

echo "Found $TOTAL test files"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  echo "" >&2
  echo "❌ No test files matched the pattern - refusing to report a verdict." >&2
  echo "   Searched: $SEARCHED_NESTED" >&2
  echo "   Searched: $SEARCHED_FLAT" >&2
  echo "   (both from $(pwd))" >&2
  echo "   A run that executed zero tests proves nothing. Fix the pattern and re-run." >&2
  exit 2
fi

# Preflight the runner once, before any test is attributed to it. A test that
# runs and fails is a legitimate outcome, so the invocation below deliberately
# swallows a non-zero status — which also makes "the runner is missing or
# cannot start" indistinguishable from "the test ran and passed". Without this
# check every match would be counted as run and the clean verdict below would
# certify a bisection that executed nothing: the same false negative this
# script refuses everywhere else.
if ! command -v npm > /dev/null 2>&1; then
  echo "" >&2
  echo "❌ The test runner 'npm' was not found on PATH - refusing to report a verdict." >&2
  echo "   Matched: $TOTAL test files, none of which could be run." >&2
  echo "   A bisection that cannot run a single test proves nothing. Fix the runner and re-run." >&2
  exit 2
fi

COUNT=0
RAN=0
for TEST_FILE in "${TEST_FILES[@]}"; do
  COUNT=$((COUNT + 1))

  # Refuse if pollution is already there. Skipping the test instead (as upstream
  # does) lets a run that executed nothing fall straight through to the clean
  # verdict below, and a marker present before the bisection starts makes the
  # whole run unattributable anyway.
  if [ -e "$POLLUTION_CHECK" ]; then
    echo "" >&2
    echo "❌ Pollution already exists before test $COUNT/$TOTAL - refusing to report a verdict." >&2
    echo "   Present: $POLLUTION_CHECK" >&2
    echo "   Not run: $TEST_FILE" >&2
    echo "   A bisection that starts dirty cannot attribute the pollution. Remove it and re-run." >&2
    exit 2
  fi

  # Every matched path names something that existed a moment ago, so an entry
  # that names nothing means the newline-delimited list could not carry the
  # path intact: a filename containing a newline is torn into fragments, each
  # counted as work while the real file is never handed to the runner. That is
  # the space-path false green again in a different character, so refuse
  # instead of testing fragments and calling the result clean.
  if [ ! -e "$TEST_FILE" ] && [ ! -L "$TEST_FILE" ]; then
    echo "" >&2
    echo "❌ Matched path $COUNT/$TOTAL does not exist - refusing to report a verdict." >&2
    echo "   Not found: $TEST_FILE" >&2
    echo "   The file list did not survive intact (a newline in a filename tears it), so it proves nothing." >&2
    exit 2
  fi

  echo "[$COUNT/$TOTAL] Testing: $TEST_FILE"

  # Run the test. A test that runs and fails is a legitimate outcome — the
  # pollution check below is the verdict, not the runner's status — but a
  # runner that could not start at all (127: not found, or removed mid-run)
  # means this test never ran, and counting it would let the reconciliation
  # below certify a clean bill of health no test backs.
  NPM_RC=0
  npm test "$TEST_FILE" > /dev/null 2>&1 || NPM_RC=$?
  if [ "$NPM_RC" -eq 127 ]; then
    echo "" >&2
    echo "❌ The test runner could not be executed (exit 127) at test $COUNT/$TOTAL - refusing to report a verdict." >&2
    echo "   Not run: $TEST_FILE" >&2
    echo "   A verdict needs tests that actually ran. Fix the runner and re-run." >&2
    exit 2
  fi
  RAN=$((RAN + 1))

  # Check if pollution appeared
  if [ -e "$POLLUTION_CHECK" ]; then
    echo ""
    echo "🎯 FOUND POLLUTER!"
    echo "   Test: $TEST_FILE"
    echo "   Created: $POLLUTION_CHECK"
    echo ""
    echo "Pollution details:"
    ls -la "$POLLUTION_CHECK"
    echo ""
    echo "To investigate:"
    echo "  npm test $TEST_FILE    # Run just this test"
    echo "  cat $TEST_FILE         # Review test code"
    exit 1
  fi
done

# Deliberate tripwire, not a tested invariant. Every path that would skip work
# refuses and exits above, so RAN cannot differ from TOTAL by the time control
# reaches here and no fixture can drive this branch — do not read a passing
# suite as evidence that it fires. It stays as the backstop for a future edit
# that introduces a skip path without its own refusal (the clean verdict is
# only worth the tests behind it), and its exit-2 shape is named in the header
# contract so whoever trips it does not meet an undocumented code.
if [ "$RAN" -ne "$TOTAL" ]; then
  echo "" >&2
  echo "❌ Only $RAN of $TOTAL matched tests ran - refusing to report a verdict." >&2
  exit 2
fi

echo ""
echo "✅ No polluter found - all tests clean!"
exit 0
