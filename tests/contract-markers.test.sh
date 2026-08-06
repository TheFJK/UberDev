#!/usr/bin/env bash
# tests/contract-markers.test.sh — CI wrapper for the Half A closed-vocabulary
# drift guard (issue #370).
#
# The comparator itself lives in tests/contract_markers.py; this file is the
# `bash tests/*.test.sh` entry point CI wires into BOTH shape-check jobs, and it
# adds the two assertions a Python-only run cannot make on its own:
#
#   C1 — the extractor's own self-test passes (it is a producer too, and a
#        producer with no oracle is exactly the hole #361 fell through).
#   C2 — the live scan of plugins/uberdev/** finds
#        every registered contract at its registered site count and every site
#        agrees after its declared deltas are applied.
#   C3 — the guard is not vacuous: a mutation at ONE site must red. C3 proves
#        it in-process on a throwaway copy of the tree, so the anti-vacuity
#        property is asserted on every CI run rather than only in the PR that
#        introduced it.
#   C4 — a new `elif` arm written on ONE line must red. The first edition of
#        this test asserted the general claim "a NEW case/elif arm must red" and
#        proved only one spelling of it: its harvest regex required a literal
#        newline after the `:`, so `elif lifecycle == "paused": print("live")`
#        sailed through while C4 reported green. That is #370 rank 7 live —
#        `paused` live at the classifier, not-live at all three probes. C4 now
#        fires the spelling that defeated it.
#   C5 — a new `case` arm appended to a ONE-LINER `case … esac` must red. This
#        is the `!case-arm` mode, which C4 never exercised (C4's site is harvest
#        mode). Two such one-liners shipped with no region close at all, so
#        their region was a single line and an appended arm was invisible.
#   C6 — an UNMARKED copy of a whole vocabulary must red. The registry is
#        hand-maintained: the path ratchet proves the marked set never SHRINKS,
#        never that it was ever COMPLETE. This assertion was added with the twin
#        scan and went undocumented in this header for one round.
#
# Repo convention: `set -u` + `set -o pipefail` + manual PASS/FAIL counters
# (NOT `set -e`; see tests/install.test.sh header for the rationale).
# Portable: bash + a Python 3 interpreter. Runs on ubuntu-latest (python3) and
# windows-latest / Git Bash (python), so it is wired into both jobs.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/tests/contract_markers.py"

if [ ! -r "$GUARD" ]; then
  echo "FATAL: contract_markers.py missing/unreadable: $GUARD" >&2
  exit 2
fi

# Windows Git Bash ships `python`, not `python3`; ubuntu-latest ships both.
# Mirrors the portable interpreter resolver used across the suite.
if PY="$(command -v python3 2>/dev/null)" && [ -n "$PY" ]; then
  :
elif PY="$(command -v python 2>/dev/null)" && [ -n "$PY" ]; then
  :
else
  echo "FATAL: no python3/python interpreter on PATH" >&2
  exit 2
fi

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "## contract-markers — closed-vocabulary drift guard (#370 Half A)"

echo "== C1: extractor self-test =="
if "$PY" -I -B "$GUARD" --selftest > "$TMP/selftest.out" 2>&1; then
  echo "  PASS  C1 extractor self-test (span pick, anchor, harvest, deltas, negatives)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  C1 extractor self-test"
  cat "$TMP/selftest.out"
  FAIL=$((FAIL + 1))
fi

echo "== C2: every registered contract agrees across every declaration site =="
if "$PY" -I -B "$GUARD" --dump "$REPO_ROOT" > "$TMP/scan.out" 2>&1; then
  echo "  PASS  C2 all sites agree"
  PASS=$((PASS + 1))
  cat "$TMP/scan.out"
else
  echo "  FAIL  C2 contract drift (or a registry/site-count mismatch)"
  cat "$TMP/scan.out"
  FAIL=$((FAIL + 1))
fi

echo "== C3: the guard is not vacuous — a one-sided edit must red =="
# Copy the scanned tree, mutate ONE member at ONE site, and assert the
# scan turns red. Without this, a future refactor that quietly stopped finding
# markers would keep reporting green (the tests/component-token-schema.py
# failure mode #370 records: a guard that sits in CI and covers nothing).
MUT="$TMP/mutant"
mkdir -p "$MUT/plugins" "$MUT/tests"
cp -R "$REPO_ROOT/plugins/uberdev" "$MUT/plugins/uberdev"
cp "$GUARD" "$MUT/tests/contract_markers.py"

"$PY" -I -B - "$MUT/plugins/uberdev/lib/status.sh" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
old = "_UBERDEV_STATUS_TERMINAL_EVENTS='completed failed timed_out cancelled abandoned'"
new = "_UBERDEV_STATUS_TERMINAL_EVENTS='completed failed timed_out cancelled abandoned superseded'"
if old not in t:
    raise SystemExit("mutation anchor not found in lib/status.sh")
p.write_text(t.replace(old, new, 1), encoding="utf-8")
PY
MUT_SEED_RC=$?

if [ "$MUT_SEED_RC" -ne 0 ]; then
  echo "  FAIL  C3 could not seed the mutation (anchor moved — update this test)"
  FAIL=$((FAIL + 1))
elif "$PY" -I -B "$MUT/tests/contract_markers.py" "$MUT" > "$TMP/mutant.out" 2>&1; then
  echo "  FAIL  C3 mutated tree still reports GREEN — the guard is vacuous"
  cat "$TMP/mutant.out"
  FAIL=$((FAIL + 1))
else
  if grep -q "agent-terminal-event" "$TMP/mutant.out" && grep -q "superseded" "$TMP/mutant.out"; then
    echo "  PASS  C3 mutated tree reds and names the contract + the moved member"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  C3 mutated tree reds but the message does not name the contract and the member"
    cat "$TMP/mutant.out"
    FAIL=$((FAIL + 1))
  fi
fi

# assert_mutation_reds LABEL FILE PY_OLD PY_NEW GREP_A GREP_B
# Copies the scanned tree, applies one literal substitution, and requires the scan to
# red AND to name both grep terms. Each case gets its own copy so one mutation
# cannot mask another.
assert_mutation_reds() {
  local label="$1" target="$2" old="$3" new="$4" needle_a="$5" needle_b="$6"
  local mut="$TMP/mutant-$label"
  mkdir -p "$mut/plugins" "$mut/tests"
  cp -R "$REPO_ROOT/plugins/uberdev" "$mut/plugins/uberdev"
  cp "$GUARD" "$mut/tests/contract_markers.py"
  if ! OLD="$old" NEW="$new" "$PY" -I -B - "$mut/plugins/uberdev/$target" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in t:
    raise SystemExit("mutation anchor not found: " + old[:60])
p.write_text(t.replace(old, new, 1), encoding="utf-8")
PY
  then
    echo "  FAIL  $label could not seed the mutation (anchor moved — update this test)"
    FAIL=$((FAIL + 1))
    return
  fi
  if "$PY" -I -B "$mut/tests/contract_markers.py" "$mut" > "$TMP/$label.out" 2>&1; then
    echo "  FAIL  $label mutated tree still reports GREEN"
    cat "$TMP/$label.out"
    FAIL=$((FAIL + 1))
    return
  fi
  if grep -q "$needle_a" "$TMP/$label.out" && grep -q "$needle_b" "$TMP/$label.out"; then
    echo "  PASS  $label reds and names the contract + the moved member"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label reds but the message does not name $needle_a / $needle_b"
    cat "$TMP/$label.out"
    FAIL=$((FAIL + 1))
  fi
}

# C4 is RETIRED, not silently dropped. It seeded a one-line
# `elif lifecycle == "paused": print("live")` into the `agent-liveness-value`
# lifecycle CLASSIFIER and asserted the marker's bespoke harvest regex caught
# it. That classifier lived inside the detached-session liveness probe and was
# deleted with its backend (RFC 0015 section 7 as amended), taking the only
# regex-mode copy of this contract with it. No surviving site spells the arm
# that way, so re-seeding the mutation anywhere else would prove a claim about
# a shape this repo no longer contains. C5 below still covers `!case-arm` mode
# and C6 still covers the unmarked-copy scan; if a regex-mode marker is ever
# reintroduced, restore a C4 against it.

echo "== C5: a new arm on a ONE-LINER case must red (!case-arm mode) =="
# C4 exercises harvest mode only. `!case-arm` derives its region from case/esac
# depth precisely so a one-liner `case … esac` — which has nowhere to hang a
# closing marker — still sees an appended arm. Two such sites shipped blind.
assert_mutation_reds C5 lib/goal-state.sh \
  'case "$v" in workflow|wezterm|background) UBERDEV_RESOLVED_BACKEND="$v" ;; esac ;;' \
  'case "$v" in workflow|wezterm|background) UBERDEV_RESOLVED_BACKEND="$v" ;; podman) UBERDEV_RESOLVED_BACKEND="$v" ;; esac ;;' \
  dispatch-backend podman

echo "== C6: an UNMARKED copy of a whole vocabulary must red =="
# The registry is hand-maintained: the path ratchet proves the marked set never
# SHRINKS, never that it was ever COMPLETE. Adding a seventh dispatch backend to
# both marked sites while the launcher's copies stayed stale is #360 verbatim,
# and it passed green until the twin scan landed.
assert_mutation_reds C6 lib/status.sh \
  '_UBERDEV_STATUS_MAX_ROWS=25' \
  "_UBERDEV_STATUS_SHADOW='completed failed timed_out cancelled abandoned'
_UBERDEV_STATUS_MAX_ROWS=25" \
  'UNMARKED copy' agent-terminal-event

echo
echo "contract-markers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
