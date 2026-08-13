#!/usr/bin/env bash
# Vendored from obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6 (MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt — which is the base this file and its 10 sibling files in skills/systematic-debugging were copied from, and the SHA vendor.json records for the component; upstream search-expression fix adopted from obra/superpowers@3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9 (v6.2.0, MIT) — that hunk only, not a component re-baseline; local addition: (1) fail-loud exit 2 whenever the run cannot back a verdict — no matched test files, an incomplete file search, a runner that cannot execute, a matched path the file list could not carry intact, a pollution target already present, or fewer tests ran than were matched (the exit contract below is authoritative for this list — do not restate it partially); (2) whitespace- and glob-safe enumeration — upstream iterates the unquoted match string and counts its lines, this copy reads the matches into an array and counts the array (#430); (3) a pre-loop runner-capability probe (npm pkg get scripts.test) that refuses with [runner-incapable] when the project defines no test script npm could run, because such a project fails every 'npm test <file>' identically and upstream would count each one as a test that ran and failed (#476)
# Bisection script to find which test creates unwanted files/state
# Usage: ./find-polluter.sh <file_or_dir_to_check> <test_pattern>
# Example: ./find-polluter.sh '.git' 'src/**/*.test.ts'
# Exit: 0 = every matched test ran and none polluted; 1 = polluter found, or bad usage —
#           a deliberate carry-over fusion, see the note in tests/find-polluter.test.sh;
#       2 = verdict refused. Seven structurally different causes share this code, so every
#           exit-2 message carries a machine-readable reason token as the first bracketed
#           field of its first line. Branch on the token, never on the English prose:
#             [search-failed]    the file search was incomplete
#             [no-matches]       nothing matched the pattern
#             [runner-unusable]  the test runner could not be executed
#             [runner-incapable] the runner starts but the project defines no test script
#                                it could run
#             [dirty-start]      the pollution target was already present, so a test
#                                would not have run
#             [path-missing]     a matched path was gone when its turn came
#             [ran-lt-matched]   fewer tests ran than were matched

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
  echo "❌ [search-failed] The search for test files failed (exit $FIND_RC) - refusing to report a verdict." >&2
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
  echo "❌ [no-matches] No test files matched the pattern - refusing to report a verdict." >&2
  echo "   Searched: $SEARCHED_NESTED" >&2
  echo "   Searched: $SEARCHED_FLAT" >&2
  echo "   (both from $(pwd))" >&2
  echo "   A run that executed zero tests proves nothing. Fix the pattern and re-run." >&2
  exit 2
fi

# Preflight the runner once, before any test is attributed to it. What this buys
# is ONE whole-run diagnostic up front instead of a refusal partway through a
# bisection; the 126/127 check inside the loop is the mid-run backstop for a
# runner that is replaced or breaks after this point.
#
# PRESENCE IS NOT CAPABILITY, so this probe EXECUTES the runner rather than
# looking it up. A PATH lookup passes for a stale nvm/volta/asdf shim whose
# interpreter no longer exists — the file is there and carries the execute bit —
# and every subsequent invocation then fails with 126, which the loop below would
# have to catch instead. Running it here refuses on the whole class at once.
#
# Starting is not the same as being able to run a test, and the probe below is
# what covers the difference (#476).
if ! npm --version > /dev/null 2>&1; then
  echo "" >&2
  echo "❌ [runner-unusable] The test runner 'npm' could not be executed - refusing to report a verdict." >&2
  echo "   Matched: $TOTAL test files, none of which could be run." >&2
  echo "   Neither missing from PATH nor startable: check the runner and its interpreter." >&2
  echo "   A bisection that cannot run a single test proves nothing. Fix the runner and re-run." >&2
  exit 2
fi

# Then probe CAPABILITY, because a runner that starts is not yet a runner that
# can run a test. A project defining no `test` script makes `npm test <file>`
# exit 1 for every file, and the loop below deliberately reads a non-zero status
# as "the test ran and failed" (a failing test is a legitimate outcome — the
# pollution check is the verdict, not the runner's status). So every match was
# counted as run, the reconciliation was satisfied, and the run reached the clean
# verdict having executed nothing: the same vacuous green one layer down (#476).
#
# What the probe establishes is narrow and worth stating exactly: the runner can
# answer that THIS project defines the script it would run. Asking through npm
# rather than reading ./package.json is what makes probe and runner agree on
# WHICH manifest — npm resolves it the same way for `pkg` as for `test`, so a
# bisection driven from a nested subdirectory or a workspace package is judged
# against the manifest that will actually serve it, which a cwd-local
# `[ -f package.json ]` check would get wrong in both directions.
#
# Three things it deliberately does NOT do:
#   * A `test` script that exists but runs no tests ("test": "echo skipped") is
#     indistinguishable from a suite that passes without executing it, and is NOT
#     closed here — deciding it needs running the thing under test. ("test": ""
#     IS caught, as a free consequence of the predicate below.)
#   * An npm too old to answer `pkg` (npm < 7) and a project with no readable
#     manifest are both REFUSED, not assumed working. A script whose entire
#     subject is confident wrong answers must not carry an "assume it works"
#     branch; the refusal names what was asked so the reader can act on it.
#   * The probe does not run the suite to test capability. Executing a test here
#     would attribute nothing and could create the very pollution marker the
#     bisection is about to look for, turning the check into its own [dirty-start].
#
# stderr is DISCARDED here, deliberately, and NOT merged the way the runner
# invocation below merges it. The predicate is anchored to the answer's first and
# last byte, so any bytes npm wrote to stderr — a warning, a notice, anything a
# future version adds — would land inside the captured string, the answer would
# no longer START with a quote, and a perfectly capable project would be refused.
# The runner call wants everything npm said because it is building a diagnostic;
# this one wants only the VALUE npm returned, because it is making a decision.
# Nothing is lost: CAP_RC carries the failure and the answer itself is echoed in
# the refusal below.
CAP_RC=0
CAP_ANSWER="$(npm pkg get scripts.test 2>/dev/null)" || CAP_RC=$?
CAP_OK=no
if [ "$CAP_RC" -eq 0 ]; then
  # A non-empty JSON string on a zero exit is the only capable answer. Measured
  # against npm 10.8.2: a defined script answers `"vitest run"` (CAPABLE); no
  # `scripts.test`, no `scripts` key at all, and a `test:unit`-only project each
  # answer `{}`; an empty `"test": ""` answers with nothing; and a missing
  # manifest exits 254 with a multi-line JSON error envelope. Every one of those
  # fails this pattern, which needs at least three characters bounded by quotes —
  # and a JSON string value can never carry a raw newline, so the envelope cannot
  # sneak past it either.
  case "$CAP_ANSWER" in '"'?*'"') CAP_OK=yes ;; esac
fi
if [ "$CAP_OK" != "yes" ]; then
  echo "" >&2
  echo "❌ [runner-incapable] The test runner 'npm' starts but this project defines no test script it could run - refusing to report a verdict." >&2
  echo "   Matched: $TOTAL test files, none of which could have been run." >&2
  echo "   Asked: npm pkg get scripts.test (exit $CAP_RC)" >&2
  if [ -n "$CAP_ANSWER" ]; then
    echo "   Answered:" >&2
    head -n 5 <<< "$CAP_ANSWER" >&2 || true
  else
    echo "   Answered: nothing at all." >&2
  fi
  echo "   Without a runnable 'test' script every 'npm test <file>' fails identically, which is indistinguishable from a test that ran and failed - so every file would be counted as run and the verdict would be backed by nothing." >&2
  echo "   Wire the suite under 'test', run the bisection from the package directory that defines it, or drive your runner directly. A verdict needs tests that actually ran." >&2
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
    echo "❌ [dirty-start] Pollution already exists before test $COUNT/$TOTAL - refusing to report a verdict." >&2
    echo "   Present: $POLLUTION_CHECK" >&2
    echo "   Not run: $TEST_FILE" >&2
    echo "   A bisection that starts dirty cannot attribute the pollution. Remove it and re-run." >&2
    exit 2
  fi

  # Every matched path named something that existed at enumeration time, so an
  # entry that names nothing now means the file list and the tree disagree. Two
  # causes produce the identical state and neither can be told from the other
  # here: the newline-delimited list could not carry the path intact (a filename
  # containing a newline is torn into fragments, each counted as work while the
  # real file is never handed to the runner — the space-path false green in a
  # different character), or the path simply vanished between the walk and its
  # turn, removed or renamed by an earlier test in this same bisection, by a
  # cleanup task, or by anything else touching the tree. Either way the list no
  # longer describes what will be tested, so refuse instead of testing fragments
  # and calling the result clean.
  if [ ! -e "$TEST_FILE" ] && [ ! -L "$TEST_FILE" ]; then
    echo "" >&2
    echo "❌ [path-missing] Matched path $COUNT/$TOTAL does not exist - refusing to report a verdict." >&2
    echo "   Not found: $TEST_FILE" >&2
    echo "   The path vanished between enumeration and its turn, or a newline in a filename tore the file list. Either way it proves nothing." >&2
    exit 2
  fi

  echo "[$COUNT/$TOTAL] Testing: $TEST_FILE"

  # Run the test. A test that runs and fails is a legitimate outcome — the
  # pollution check below is the verdict, not the runner's status — but a runner
  # that could not be EXECUTED means this test never ran, and counting it would
  # let the reconciliation below certify a clean bill of health no test backs.
  #
  # BOTH halves of that shell failure family must be caught. 127 is "not found"
  # (a runner removed mid-run); 126 is "found but cannot exec" — a stale shim
  # whose interpreter is gone, a bad interpreter line, an exec-format error, or a
  # runner replaced by a non-executable file. Matching 127 alone let every 126
  # shape through: the status compared unequal, RAN was incremented for a test
  # that never ran, and the clean verdict was printed with rc 0 having executed
  # nothing — and because RAN was inflated on the same path, the end-of-loop
  # tripwire could not catch it either.
  #
  # The output is CAPTURED rather than discarded so the refusal can say what
  # actually went wrong; the passing path stays exactly as quiet as it was. That
  # also disambiguates the one case this predicate cannot: a 127 raised from
  # INSIDE a test whose own script invoked a missing binary looks identical here,
  # and the captured output is what tells the two apart.
  NPM_RC=0
  RUNNER_OUT="$(npm test "$TEST_FILE" 2>&1)" || NPM_RC=$?
  if [ "$NPM_RC" -eq 126 ] || [ "$NPM_RC" -eq 127 ]; then
    echo "" >&2
    echo "❌ [runner-unusable] The test runner could not be executed (exit $NPM_RC) at test $COUNT/$TOTAL - refusing to report a verdict." >&2
    echo "   Not run: $TEST_FILE" >&2
    if [ -n "$RUNNER_OUT" ]; then
      echo "   Runner output (last 20 lines):" >&2
      tail -n 20 <<< "$RUNNER_OUT" >&2 || true
    else
      echo "   The runner produced no output at all." >&2
    fi
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
  echo "❌ [ran-lt-matched] Only $RAN of $TOTAL matched tests ran - refusing to report a verdict." >&2
  exit 2
fi

echo ""
echo "✅ No polluter found - all tests clean!"
exit 0
