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
#   C2 — the live scan of plugins/uberdev/** + codex/uberdev-codex/** finds
#        every registered contract at its registered site count and every site
#        agrees after its declared deltas are applied.
#   C3 — the guard is not vacuous: a mutation at ONE site must red. C3 proves
#        it in-process on a throwaway copy of the tree, so the anti-vacuity
#        property is asserted on every CI run rather than only in the PR that
#        introduced it.
#   C4 — a NEW `case`/`elif` arm must red. Regions default to ONE line, which
#        makes "add an arm" — the most likely real edit to a switch — invisible
#        unless the region is closed with `# /CONTRACT:` at its `esac`. C4 keeps
#        that wiring honest on every run.
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
# Mirrors the resolver in tests/dispatch-codex.test.sh:40-44.
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
# Copy only the two scanned trees, mutate ONE member at ONE site, and assert the
# scan turns red. Without this, a future refactor that quietly stopped finding
# markers would keep reporting green (the tests/component-token-schema.py
# failure mode #370 records: a guard that sits in CI and covers nothing).
MUT="$TMP/mutant"
mkdir -p "$MUT/plugins" "$MUT/codex" "$MUT/tests"
cp -R "$REPO_ROOT/plugins/uberdev" "$MUT/plugins/uberdev"
cp -R "$REPO_ROOT/codex/uberdev-codex" "$MUT/codex/uberdev-codex"
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

echo "== C4: a NEW case arm must red — the edit a one-line region cannot see =="
# The highest-value regression this guard has. `case`/`elif` regions default to
# ONE line, which makes "add an arm" invisible; every such region is closed with
# `# /CONTRACT:` at its `esac`. C4 keeps that wiring honest: adding a `paused`
# lifecycle arm to the classifier reproduces #370 rank 7 exactly (live at the
# classifier, not-live at all three goal-state probes), so it must never be green.
MUT4="$TMP/mutant4"
mkdir -p "$MUT4/plugins" "$MUT4/codex" "$MUT4/tests"
cp -R "$REPO_ROOT/plugins/uberdev" "$MUT4/plugins/uberdev"
cp -R "$REPO_ROOT/codex/uberdev-codex" "$MUT4/codex/uberdev-codex"
cp "$GUARD" "$MUT4/tests/contract_markers.py"

"$PY" -I -B - "$MUT4/plugins/uberdev/lib/agent-dispatch.sh" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
old = 'elif lifecycle in {"failed", "error"}:'
new = 'elif lifecycle == "paused":\n    print("live", end="")\nelif lifecycle in {"failed", "error"}:'
if old not in t:
    raise SystemExit("C4 mutation anchor not found in lib/agent-dispatch.sh")
p.write_text(t.replace(old, new, 1), encoding="utf-8")
PY
MUT4_SEED_RC=$?

if [ "$MUT4_SEED_RC" -ne 0 ]; then
  echo "  FAIL  C4 could not seed the mutation (anchor moved — update this test)"
  FAIL=$((FAIL + 1))
elif "$PY" -I -B "$MUT4/tests/contract_markers.py" "$MUT4" > "$TMP/mutant4.out" 2>&1; then
  echo "  FAIL  C4 a new case/elif arm is INVISIBLE — a region lost its /CONTRACT: close"
  cat "$TMP/mutant4.out"
  FAIL=$((FAIL + 1))
else
  if grep -q "agent-liveness-value" "$TMP/mutant4.out" && grep -q "paused" "$TMP/mutant4.out"; then
    echo "  PASS  C4 a new arm reds and names the contract + the new member"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  C4 reds but the message does not name the contract and the new member"
    cat "$TMP/mutant4.out"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "contract-markers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
