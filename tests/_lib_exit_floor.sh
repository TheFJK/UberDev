#!/usr/bin/env bash
# tests/_lib_exit_floor.sh — the anti-vacuity EXIT floor for test fixtures.
#
# Sourced, never executed. ONE implementation for the whole corpus: a fixture
# that dies halfway through must not be able to certify the assertions it never
# reached.
#
# WHY IT EXISTS (#551)
# --------------------
# `supervision-smoke-macos` ran tests/child-dispatch.test.sh for 630 of its
# 1338 lines and exited 0, so the `&&` chain continued and the job went green
# having executed under half the fixture. The abort was a `$BASHPID` expansion
# under `set -u` on the runner's bash 3.2; the reason nothing noticed was that
# the shell exited 0 anyway.
#
# THE MEASURED MECHANISM — bash 3.2.57(1) vs bash 5.3.3, same script
# -------------------------------------------------------------------
# Final exit status of a `set -euo pipefail` script that aborts mid-run:
#
#   abort               no EXIT trap   trap 'rm -rf "$T"' EXIT   trap 'rc=$?; …; exit $rc' EXIT
#   set -u unbound var  3.2: 1         3.2: 0                    3.2: 0
#                       5.x: 1         5.x: 1                    5.x: 1
#   set -e failure      both: 1        both: 1                   both: 1
#   explicit exit 7     both: 7        both: 7                   both: 7
#
# Two conclusions, both load-bearing and both contrary to the first reading of
# #551:
#
#   1. The laundering is `set -u` SPECIFIC. A `set -e` abort and an explicit
#      non-zero exit survive an EXIT trap intact on bash 3.2 — the trap body's
#      last command does NOT overwrite the status.
#   2. Capture-and-re-raise — `trap 'rc=$?; cleanup; exit $rc' EXIT`, the
#      obvious fix — DOES NOT WORK for the one cell that is broken. On bash 3.2
#      the EXIT trap is already handed `$? == 0` after a `set -u` abort, so the
#      re-raise faithfully re-raises a zero. Rewriting the corpus's ~90 EXIT
#      traps into that form would have been churn plus a false all-clear: a
#      guard whose predicate is disjoint from the drift it must find.
#
# So the floor never reads `$?` for its verdict. It reads a flag that only the
# fixture's own last executable line can set, which no abort path can forge.
#
# USAGE — three lines per fixture
# -------------------------------
#   . "$ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }
#   TMP="$(mktemp -d)"
#   trap '_floor_rc=$?; rm -rf "$TMP"; uberdev_test_exit_floor <name> "$_floor_rc"' EXIT
#   …the fixture…
#   uberdev_test_exit_floor_reached
#   echo '<name>: N checks passed'
#
# The floor is TRANSPARENT on a completed run (it exits with the status the
# fixture produced, zero or not) and only ever converts a 0 into a 1. It cannot
# turn a red run green.
#
# DECLARED BOUNDARY: the floor proves the fixture reached its last executable
# line. It does not prove any particular assertion ran — a fixture whose body
# is wrapped in a false conditional still reaches the marker. The per-file
# executed-row floor (see tests/ubersimplify-aggregate.test.sh) is the
# mechanism for that, and the two compose.

# Set at source time so a `set -u` fixture can read it before the first arm.
UBERDEV_TEST_EXIT_FLOOR_REACHED=0

# Call as the LAST executable statement of the fixture, immediately before its
# completion line.
uberdev_test_exit_floor_reached() {
  UBERDEV_TEST_EXIT_FLOOR_REACHED=1
}

# Call as the LAST command in the fixture's EXIT trap:
#   uberdev_test_exit_floor <fixture-name> <status-at-trap-entry>
#
# The status is passed in rather than read from `$?` here, because by this
# point `$?` is the status of the cleanup command that ran just before.
uberdev_test_exit_floor() {
  local name="${1:-fixture}" rc="${2:-0}"
  case "$rc" in
    ''|*[!0-9]*) rc=1 ;;
  esac
  if [ "$rc" -eq 0 ] && [ "${UBERDEV_TEST_EXIT_FLOOR_REACHED:-0}" -ne 1 ]; then
    printf '%s: FATAL truncated run — exited 0 without reaching its completion marker.\n' "$name" >&2
    printf '%s: on bash 3.2 a `set -u` abort exits 0 (this shell: %s); the floor makes that a 1. See #551.\n' \
      "$name" "${BASH_VERSION:-unknown}" >&2
    rc=1
  fi
  # `exit` from inside an EXIT trap is what makes bash 3.2 honour this status
  # instead of the one it was already unwinding with — measured, not assumed.
  exit "$rc"
}
