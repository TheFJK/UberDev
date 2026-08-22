#!/usr/bin/env bash
# tests/exit-floor.test.sh — the mechanism proof and the coverage set for
# tests/_lib_exit_floor.sh (#551).
#
# `supervision-smoke-macos` ran tests/child-dispatch.test.sh for 630 of its
# 1338 lines and still exited 0, so the job's `&&` chain continued and the
# whole runner reported green having executed under half the fixture. The abort
# was a `$BASHPID` expansion under `set -u` on macos-latest's bash 3.2. The
# reason it was invisible for two months is the second half: on bash 3.2 a
# `set -u` abort exits ZERO when `set -e` is also in force AND an EXIT trap is
# installed. All three together — which is every fixture in that job, because
# `set -euo pipefail` plus a cleanup trap is the shape this corpus is written
# in. Drop any one of the three and the abort exits 1 on both majors.
#
# Rows:
#   E1  the floor turns a `set -u` truncation into a non-zero status
#   E2  the floor turns any early zero-status exit into a non-zero status
#   E3  the floor is transparent on a completed run (it cannot red a green one)
#   E4  the floor preserves a genuine non-zero verdict verbatim (7 stays 7)
#   E5  characterisation of the UNFLOORED twin, per running bash major: 0 on
#       bash 3.2 (the #551 laundering, reproduced) and 1 on bash >= 4
#   E6  every fixture the supervision-smoke-macos job runs carries the floor,
#       with the detector's own polarity pinned
#
# Why this lives here and not in tests/test-harness-source-guards.test.sh: that
# file is the home of STATIC corpus-wide source conventions. E1-E5 are a
# runtime proof that the mechanism does what its name says on the shell in
# hand, and E6 is scoped to one CI job rather than the corpus. Splitting them
# would put the predicate and the proof of the predicate in different files.
#
# Portable: bash + awk + grep + sed + mktemp. No python, no ripgrep, no zsh.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
FLOOR_LIB="$THIS_DIR/_lib_exit_floor.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

if [ ! -r "$FLOOR_LIB" ]; then
  echo "FATAL: _lib_exit_floor.sh missing/unreadable: $FLOOR_LIB" >&2
  exit 2
fi
if [ ! -r "$WORKFLOW" ]; then
  echo "FATAL: workflow file missing or unreadable: $WORKFLOW" >&2
  exit 2
fi
if ! TMPD="$(mktemp -d)"; then
  echo "FATAL: mktemp -d failed; the fixture-driven rows cannot run" >&2
  exit 2
fi
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0

# The literal guard tail every source site of the floor library must carry.
# The exact FATAL wording is part of the contract — operators grep for it in CI
# logs — so paraphrases are not accepted. Same discipline as row A1 of
# tests/test-harness-source-guards.test.sh.
FLOOR_GUARD_FRAGMENT='|| { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }'

# ---------------------------------------------------------------------------
# Fixture pair. Same body, same abort modes; one arms the floor, one does not.
# PROBE_MODE selects the abort, so a single pair covers every row.
#
# The `set -euo pipefail` line in both fixtures is part of the reproduction, not
# boilerplate: the 3.2 laundering needs errexit AND nounset AND an EXIT trap
# together. Relax it to `set -u` and E5's 3.2 arm stops reproducing anything —
# the abort exits 1, and the row reds saying so.
# ---------------------------------------------------------------------------
FLOORED="$TMPD/floored.sh"
UNFLOORED="$TMPD/unfloored.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf '. "%s" %s\n' "$FLOOR_LIB" "$FLOOR_GUARD_FRAGMENT"
  printf 'PROBE_TMP="$(mktemp -d)"\n'
  printf "trap '_floor_rc=\$?; rm -rf \"\$PROBE_TMP\"; uberdev_test_exit_floor probe \"\$_floor_rc\"' EXIT\n"
  printf 'echo "probe: row 1 ran"\n'
  printf 'case "$PROBE_MODE" in\n'
  printf '  setu) echo "$PROBE_DELIBERATELY_UNSET" ;;\n'
  printf '  early0) exit 0 ;;\n'
  printf '  fail7) exit 7 ;;\n'
  printf 'esac\n'
  printf 'echo "probe: row 2 ran"\n'
  printf 'uberdev_test_exit_floor_reached\n'
  printf 'echo "probe: complete"\n'
} >"$FLOORED"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'PROBE_TMP="$(mktemp -d)"\n'
  printf "trap 'rm -rf \"\$PROBE_TMP\"' EXIT\n"
  printf 'echo "probe: row 1 ran"\n'
  printf 'case "$PROBE_MODE" in\n'
  printf '  setu) echo "$PROBE_DELIBERATELY_UNSET" ;;\n'
  printf '  early0) exit 0 ;;\n'
  printf '  fail7) exit 7 ;;\n'
  printf 'esac\n'
  printf 'echo "probe: row 2 ran"\n'
  printf 'echo "probe: complete"\n'
} >"$UNFLOORED"

# run_probe <script> <mode> — runs the fixture under the SHELL RUNNING THIS
# FILE and records status + combined output in PROBE_RC / PROBE_OUT.
#
# The status is captured from a plain command, never from a subshell used as a
# condition (row A5 of tests/test-harness-source-guards.test.sh: errexit is
# inert there, and so is any status you think you are reading).
run_probe() {
  PROBE_OUT="$(PROBE_MODE="$2" "${BASH:-bash}" "$1" 2>&1)" && PROBE_RC=0 || PROBE_RC=$?
}

BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
echo "## exit-floor mechanism proof (#551) — bash ${BASH_VERSION:-unknown}"
echo

# ---------------------------------------------------------------------------
echo "== E1: the floor turns a set -u truncation into a non-zero status =="
run_probe "$FLOORED" setu
e1_saw_marker=0
grep -q 'FATAL truncated run' <<<"$PROBE_OUT" && e1_saw_marker=1
e1_ran_row2=0
grep -q 'probe: row 2 ran' <<<"$PROBE_OUT" && e1_ran_row2=1
# The floor announces itself only where it is the thing producing the non-zero.
# On bash >= 4 the abort already carries rc=1 into the trap, so the marker must
# be ABSENT — that is the same transparency E3/E4 assert, on the abort path.
if [ "$BASH_MAJOR" -ge 4 ]; then e1_want_marker=0; else e1_want_marker=1; fi
if [ "$PROBE_RC" -ne 0 ] && [ "$e1_saw_marker" -eq "$e1_want_marker" ] && [ "$e1_ran_row2" -eq 0 ]; then
  echo "  PASS  E1 truncated at the unbound variable and left with rc=$PROBE_RC (floor announced: $e1_saw_marker)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E1 rc=$PROBE_RC marker=$e1_saw_marker (wanted $e1_want_marker) reached-row-2=$e1_ran_row2"
  echo "        A fixture that dies on an unbound variable must not report success."
  printf '        %s\n' "$PROBE_OUT"
  FAIL=$((FAIL + 1))
fi

echo
# ---------------------------------------------------------------------------
echo "== E2: the floor turns an early zero-status exit into a non-zero status =="
run_probe "$FLOORED" early0
e2_saw_marker=0
grep -q 'FATAL truncated run' <<<"$PROBE_OUT" && e2_saw_marker=1
if [ "$PROBE_RC" -ne 0 ] && [ "$e2_saw_marker" -eq 1 ]; then
  echo "  PASS  E2 an early exit 0 left with rc=$PROBE_RC and named itself"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E2 rc=$PROBE_RC marker=$e2_saw_marker — an early exit 0 was reported as success"
  echo "        This is the class no EXIT-trap status re-raise can catch: the shell is"
  echo "        already unwinding with zero, so only the completion flag can tell."
  printf '        %s\n' "$PROBE_OUT"
  FAIL=$((FAIL + 1))
fi

echo
# ---------------------------------------------------------------------------
# Anti-vacuity for E1/E2: a floor that failed everything would pass both.
echo "== E3: the floor is transparent on a completed run =="
run_probe "$FLOORED" clean
e3_complete=0
grep -q 'probe: complete' <<<"$PROBE_OUT" && e3_complete=1
if [ "$PROBE_RC" -eq 0 ] && [ "$e3_complete" -eq 1 ]; then
  echo "  PASS  E3 a completed run still exits 0"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E3 rc=$PROBE_RC complete=$e3_complete — the floor reds a green run"
  printf '        %s\n' "$PROBE_OUT"
  FAIL=$((FAIL + 1))
fi

echo
# ---------------------------------------------------------------------------
echo "== E4: the floor preserves a genuine non-zero verdict verbatim =="
run_probe "$FLOORED" fail7
if [ "$PROBE_RC" -eq 7 ]; then
  echo "  PASS  E4 an exit 7 stayed 7"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4 an exit 7 became rc=$PROBE_RC — the floor is rewriting real verdicts"
  printf '        %s\n' "$PROBE_OUT"
  FAIL=$((FAIL + 1))
fi

echo
# ---------------------------------------------------------------------------
# The #551 laundering itself, reproduced against the unfloored twin. The
# expected status is a function of the running bash, so this row asserts
# something on EVERY host instead of quietly standing down on one of them:
# bash 3.2 must launder (0) and bash >= 4 must not (1). If a future macOS
# runner ships a newer /bin/bash, this row flips and says so.
echo "== E5: the unfloored twin, characterised by bash major =="
run_probe "$UNFLOORED" setu
if [ "$BASH_MAJOR" -ge 4 ]; then
  e5_want=1
  e5_why="bash >= 4 propagates the set -u abort"
else
  e5_want=0
  e5_why="bash 3.2 launders the set -u abort to 0 under set -e with an EXIT trap installed (#551)"
fi
if [ "$PROBE_RC" -eq "$e5_want" ]; then
  echo "  PASS  E5 unfloored rc=$PROBE_RC as expected — $e5_why"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E5 unfloored rc=$PROBE_RC, expected $e5_want on bash ${BASH_VERSION:-unknown}"
  echo "        $e5_why"
  echo "        If /bin/bash on the runner changed, update this row deliberately — do not"
  echo "        relax it. The floor's reason to exist is written down in _lib_exit_floor.sh."
  printf '        %s\n' "$PROBE_OUT"
  FAIL=$((FAIL + 1))
fi

echo
# ---------------------------------------------------------------------------
# E6 — coverage. supervision-smoke-macos is the only job in the matrix that
# runs on a bash 3.2, so it is the job whose fixtures must all carry the floor.
# ---------------------------------------------------------------------------
echo "== E6: every supervision-smoke-macos fixture carries the exit floor =="

# floor_state <file> — one word describing how completely a fixture is floored.
#   armed       sources the library with the guard tail, calls the floor from a
#               trap, and marks completion
#   unsourced   no guarded source line
#   untrapped   sourced, but no EXIT trap that ends in the floor
#   unmarked    trapped, but nothing ever sets the completion flag
floor_state() {
  local file="$1"
  grep -qF -- "$FLOOR_GUARD_FRAGMENT" "$file" 2>/dev/null || { printf 'unsourced\n'; return 0; }
  grep -qE '^[[:space:]]*trap .*uberdev_test_exit_floor ' "$file" 2>/dev/null || { printf 'untrapped\n'; return 0; }
  grep -qE '^[[:space:]]*uberdev_test_exit_floor_reached[[:space:]]*$' "$file" 2>/dev/null || { printf 'unmarked\n'; return 0; }
  printf 'armed\n'
}

macos_block="$(awk '/^  supervision-smoke-macos:/,/^  shape-checks-windows:/' "$WORKFLOW")"
# COMMENT-STRIPPED BEFORE THE MATCH. This block carries the prose that documents
# its own harness, and that prose quotes invocation shapes -- so an unstripped
# scan reads a fixture out of a SENTENCE. It did: a comment reading "so
# `bash tests/x.test.sh` yields ..." was counted as a ninth macOS fixture and
# reported as missing, on a job that wires eight.
#
# The other direction is worse and is the reason this is a strip rather than a
# blocklist. `# dropped for speed: bash tests/dispatch-wezterm.test.sh` beside a
# deleted invocation would make E6 certify a fixture that no longer runs -- the
# forgeable-declaration shape ci-wiring W11 drives a mutation against. E6.3 below
# pins both directions.
macos_block_code="$(printf '%s\n' "$macos_block" | grep -v '^[[:space:]]*#')"
macos_fixtures="$(sed -n 's|.*bash tests/\([A-Za-z0-9._-]*\.test\.sh\).*|\1|p' <<<"$macos_block_code")"

e6_seen=0
e6_bad=""
while IFS= read -r fixture; do
  [ -n "$fixture" ] || continue
  e6_seen=$((e6_seen + 1))
  if [ ! -r "$REPO_ROOT/tests/$fixture" ]; then
    e6_bad="$e6_bad $fixture(missing)"
    continue
  fi
  state="$(floor_state "$REPO_ROOT/tests/$fixture")"
  [ "$state" = armed ] || e6_bad="$e6_bad $fixture($state)"
done <<EOF_E6
$macos_fixtures
EOF_E6

if [ "$e6_seen" -eq 0 ]; then
  echo "  FAIL  E6.0 the supervision-smoke-macos block yielded no fixtures — the scan is vacuous"
  echo "        Either the job was renamed or its run: block no longer uses \`bash tests/<f>\`."
  FAIL=$((FAIL + 1))
else
  echo "  PASS  E6.0 read $e6_seen fixture(s) from the supervision-smoke-macos block"
  PASS=$((PASS + 1))
fi

if [ -z "$e6_bad" ] && [ "$e6_seen" -gt 0 ]; then
  echo "  PASS  E6.1 all $e6_seen fixture(s) arm tests/_lib_exit_floor.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E6.1 unfloored fixture(s) on the only bash-3.2 job:$e6_bad"
  echo "        Each one must source tests/_lib_exit_floor.sh with the guard tail, end its"
  echo "        EXIT trap in \`uberdev_test_exit_floor <name> \"\$_floor_rc\"\`, and call"
  echo "        uberdev_test_exit_floor_reached on its last executable line."
  FAIL=$((FAIL + 1))
fi

# E6.2 — the detector's own polarity. E6.1's population is clean by design, so
# on its own it cannot tell "every fixture is floored" from "floor_state stopped
# matching". Both polarities are pinned against synthetic files.
e6_fx="$TMPD/e6"
mkdir -p "$e6_fx"
{
  printf '. "/dev/null" %s\n' "$FLOOR_GUARD_FRAGMENT"
  printf "trap '_floor_rc=\$?; uberdev_test_exit_floor probe \"\$_floor_rc\"' EXIT\n"
  printf 'uberdev_test_exit_floor_reached\n'
} >"$e6_fx/armed.test.sh"
printf 'echo nothing here\n' >"$e6_fx/unsourced.test.sh"
{
  printf '. "/dev/null" %s\n' "$FLOOR_GUARD_FRAGMENT"
  printf 'echo no trap\n'
} >"$e6_fx/untrapped.test.sh"
{
  printf '. "/dev/null" %s\n' "$FLOOR_GUARD_FRAGMENT"
  printf "trap '_floor_rc=\$?; uberdev_test_exit_floor probe \"\$_floor_rc\"' EXIT\n"
  printf 'echo no completion marker\n'
} >"$e6_fx/unmarked.test.sh"

e6_polarity="$(floor_state "$e6_fx/armed.test.sh")/$(floor_state "$e6_fx/unsourced.test.sh")/$(floor_state "$e6_fx/untrapped.test.sh")/$(floor_state "$e6_fx/unmarked.test.sh")"
if [ "$e6_polarity" = "armed/unsourced/untrapped/unmarked" ]; then
  echo "  PASS  E6.2 the floor detector discriminates all four states"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E6.2 the floor detector is not discriminating"
  echo "         expected 'armed/unsourced/untrapped/unmarked', got: $e6_polarity"
  FAIL=$((FAIL + 1))
fi

echo
# E6.3 — polarity for the comment strip, both directions, through the SAME
# extraction E6.0/E6.1 use. Without this the strip is an unverified claim: a
# regex that stopped matching entirely would also produce "no phantom".
e63_err=''
e63_forged="$(printf '%s\n        # dropped for speed: bash tests/phantom-fixture.test.sh\n' "$macos_block" \
  | grep -v '^[[:space:]]*#' \
  | sed -n 's|.*bash tests/\([A-Za-z0-9._-]*\.test\.sh\).*|\1|p' \
  | grep -c 'phantom-fixture.test.sh')"
e63_real="$(printf '%s\n' "$macos_block_code" \
  | sed -n 's|.*bash tests/\([A-Za-z0-9._-]*\.test\.sh\).*|\1|p' \
  | grep -c 'atomic-move.test.sh')"
if [ "$e63_forged" != "0" ]; then
  e63_err='a commented invocation still counts as wiring'
elif [ "$e63_real" = "0" ]; then
  e63_err='the strip ate a REAL invocation — atomic-move.test.sh vanished'
fi
if [ -z "$e63_err" ]; then
  echo "  PASS  E6.3 the scan reads invocations, not comments claiming them"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E6.3 $e63_err"
  FAIL=$((FAIL + 1))
fi

echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

# Executed-row floor. "Zero failures" is not the claim "the rows ran"; this
# file exists precisely because that difference is what shipped a green macOS
# job. E1-E5 plus E6.0/E6.1/E6.2/E6.3 are nine unconditional rows.
EXPECTED_ROWS=9
if [ "$((PASS + FAIL))" -ne "$EXPECTED_ROWS" ]; then
  echo "FATAL: executed $((PASS + FAIL)) rows, expected $EXPECTED_ROWS — this file asserted less than it claims" >&2
  exit 1
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "exit-floor: $PASS checks passed"
exit 0
