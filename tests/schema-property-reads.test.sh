#!/usr/bin/env bash
# tests/schema-property-reads.test.sh — CI wrapper for the generic
# "declared, requested, never read" schema-property guard (issue #513).
#
# The extractor lives in tests/schema_property_reads.py; this file is the
# `bash tests/*.test.sh` entry point CI wires into BOTH shape-check jobs, and it
# adds the assertions a Python-only run cannot make about itself:
#
#   S1  — the extractor's own self-test passes. It is a producer, and a producer
#         with no oracle is the hole #361 fell through.
#   S2  — the live scan of plugins/uberdev/skills/*/workflow.js is clean.
#   S3  — the corpus is the six expected scripts, named individually. A count
#         alone would survive one script being swapped for another.
#   S4  — the pinned ledger, floors and shadowed-name sets agree with reality.
#   S5  — ANTI-VACUITY. A new unread property seeded into a real workflow.js
#         must red and must name it. Without this the whole suite could go
#         green by finding nothing at all.
#   S6  — the exemption for solve-fleet's `intake.issues.items.contextFile` is
#         LOAD-BEARING: delete the marker and the scan reds. This is the anchor
#         row — it proves the carry rule does not already exempt the property,
#         so a future widening of that rule cannot silently make issue #513's
#         flagship instance invisible.
#   S7  — honesty row A: a marker on a line the harvest produced no property
#         from reds, so a marker cannot decorate an innocent line.
#   S8  — honesty row B: a marker on a property that IS read reds, so a stale
#         exemption cannot outlive the defect it excused.
#   S9  — the ledger pin reds in BOTH directions: a pin row removed while the
#         marker stays (the ledger GREW) and a pin row added with no marker
#         behind it (the ledger SHRANK).
#   S10 — the shadowed-name pin reds when the live set drifts.
#
# DECLARED LIMITS of the guard itself are stated in the extractor's header and
# repeated here so a reader of either file learns them: the read detector is
# NAME-SCOPED per file; the carry analysis is ONE-HOP and file-wide; readers
# living in SKILL.md prose or in a calling session are invisible; and the corpus
# is plugins/uberdev/skills/*/workflow.js only. Issue #513 cites seven
# instances — **this guard covers 2 of the 7** (solve-fleet
# `intake.issues.items.contextFile`; #507 and #514 made the two properties this
# file originally anchored on — `reviewed.blockingFindings` and review-fleet's
# `ciClassify.failureClass` — live, so the anchors moved rather than vanished). The
# other five sit outside `const S = {`, outside the corpus, or are a
# required-list-versus-prompt inversion rather than an unread property.
#
# Repo convention: `set -u` + `set -o pipefail` + manual PASS/FAIL counters
# (NOT `set -e`; see tests/install.test.sh header for the rationale). Every
# probe reads from a herestring, never a pipe: this file sets pipefail and
# `grep -q` exits on its first match, so a piped writer would take EPIPE
# (tests/epipe-guard.test.sh).
# Portable: bash + a Python 3 interpreter. Runs on ubuntu-latest (python3) and
# windows-latest / Git Bash (python), so it is wired into both jobs.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/tests/schema_property_reads.py"

if [ ! -r "$GUARD" ]; then
  echo "FATAL: schema_property_reads.py missing/unreadable: $GUARD" >&2
  exit 2
fi

# Windows Git Bash ships `python`, not `python3`; ubuntu-latest ships both.
# Mirrors the portable interpreter resolver in tests/contract-markers.test.sh.
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

# NEWLINE-delimited and read through a heredoc, never `for x in $SCALAR`: zsh
# does not word-split an unquoted scalar, so the space-delimited spelling runs
# the loop exactly once over the whole string. This file is executed under zsh
# as well as bash, and the space-delimited first draft reported all six scripts
# missing on the zsh run.
EXPECTED_CORPUS='goal-pipeline
review-fleet
scan-fleet
solve-fleet
testers-pipeline
uberthink-pipeline'

echo "## schema-property-reads — declared/requested/never-read guard (#513)"

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# seed_mutant LABEL — build $TMP/mut-LABEL holding a copy of the guard and of
# every corpus script, discovered by the SAME glob the guard uses so the mutant
# corpus can never drift from the real one. Echoes the mutant root.
seed_mutant() {
  local mut_root mut_src mut_dir
  mut_root="$TMP/mut-$1"
  mkdir -p "$mut_root/tests"
  cp "$GUARD" "$mut_root/tests/schema_property_reads.py"
  for mut_src in "$REPO_ROOT"/plugins/uberdev/skills/*/workflow.js; do
    [ -f "$mut_src" ] || continue
    mut_dir="$(basename "$(dirname "$mut_src")")"
    mkdir -p "$mut_root/plugins/uberdev/skills/$mut_dir"
    cp "$mut_src" "$mut_root/plugins/uberdev/skills/$mut_dir/workflow.js"
  done
  printf '%s' "$mut_root"
}

# substitute FILE OLD NEW — one literal replacement, failing loudly when the
# anchor has moved. Argv-heredoc, the shape tests/contract-markers.test.sh
# already ships green on Git Bash.
substitute() {
  OLD="$2" NEW="$3" "$PY" -I -B - "$1" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in text:
    raise SystemExit("mutation anchor not found: " + old[:70])
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
}

# assert_mutant_reds LABEL MUTANT_ROOT MODE NEEDLE_A NEEDLE_B — run the MUTANT
# copy of the guard against the mutant tree and require it to red AND to name
# both needles. A mutation that reds for the wrong reason is not evidence: the
# needles are what stop a corpus-floor FATAL (or any other unrelated red) from
# being read as proof that the seeded defect was detected.
assert_mutant_reds() {
  local am_label am_root am_mode am_a am_b am_out am_missing
  am_label="$1"; am_root="$2"; am_mode="$3"; am_a="$4"; am_b="$5"
  am_out="$TMP/$am_label.out"
  if "$PY" -I -B "$am_root/tests/schema_property_reads.py" "$am_mode" "$am_root" \
      > "$am_out" 2>&1; then
    echo "  FAIL  $am_label mutated tree still reports GREEN — the assertion is vacuous"
    cat "$am_out"
    FAIL=$((FAIL + 1))
    return
  fi
  am_missing=""
  grep -qF -- "$am_a" "$am_out" || am_missing="${am_missing} $am_a"
  grep -qF -- "$am_b" "$am_out" || am_missing="${am_missing} $am_b"
  if [ -z "$am_missing" ]; then
    echo "  PASS  $am_label reds and names $am_a / $am_b"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $am_label reds but the message does not name:$am_missing"
    cat "$am_out"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# S1 — the extractor's own oracle.
# ---------------------------------------------------------------------------
echo "== S1: extractor self-test =="
if "$PY" -I -B "$GUARD" --selftest > "$TMP/selftest.out" 2>&1; then
  echo "  PASS  S1 extractor self-test (normaliser, span, harvest, read, carry, markers, tripwires)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S1 extractor self-test"
  cat "$TMP/selftest.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S2 — the live scan.
# ---------------------------------------------------------------------------
echo "== S2: every declared schema property is read, carried or explicitly marked =="
SCAN_START="$SECONDS"
"$PY" -I -B "$GUARD" --scan "$REPO_ROOT" > "$TMP/scan.out" 2>&1
SCAN_RC=$?
SCAN_ELAPSED=$((SECONDS - SCAN_START))
if [ "$SCAN_RC" -eq 0 ]; then
  echo "  PASS  S2 live scan clean ($(cat "$TMP/scan.out"))"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S2 live scan reported findings (rc=$SCAN_RC)"
  cat "$TMP/scan.out"
  FAIL=$((FAIL + 1))
fi
# A budget row, not a stopwatch: the measured scan is well under a second, so a
# minute-scale ceiling catches a pathological regression (an accidental O(n^2)
# rescan) without flaking on a loaded Windows runner.
if [ "$SCAN_ELAPSED" -le 60 ]; then
  echo "  PASS  S2b scan wall time ${SCAN_ELAPSED}s is within the 60s budget"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S2b scan took ${SCAN_ELAPSED}s — over the 60s budget"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S3 — the corpus, named. A count alone survives a swap.
# ---------------------------------------------------------------------------
echo "== S3: the corpus is the six expected workflow scripts, each at or above its floor =="
"$PY" -I -B "$GUARD" --dump "$REPO_ROOT" > "$TMP/dump.out" 2>&1
DUMP_RC=$?
if [ "$DUMP_RC" -ne 0 ]; then
  echo "  FAIL  S3 --dump failed (rc=$DUMP_RC)"
  cat "$TMP/dump.out"
  FAIL=$((FAIL + 1))
else
  S3_MISSING=""
  S3_SEEN=0
  while IFS= read -r expected; do
    [ -n "$expected" ] || continue
    S3_SEEN=$((S3_SEEN + 1))
    grep -qF -- "plugins/uberdev/skills/$expected/workflow.js " "$TMP/dump.out" \
      || S3_MISSING="${S3_MISSING} $expected"
  done <<EOF_S3
$EXPECTED_CORPUS
EOF_S3
  if [ "$S3_SEEN" -ne 6 ]; then
    echo "  FAIL  S3 the expected-corpus list iterated $S3_SEEN time(s), not 6 — the row is vacuous"
    FAIL=$((FAIL + 1))
  elif [ -z "$S3_MISSING" ]; then
    echo "  PASS  S3 all six corpus scripts are anchored, harvested and at or above their floors"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  S3 corpus script(s) missing from the scan:$S3_MISSING"
    cat "$TMP/dump.out"
    FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------------------
# S4 — the pins.
# ---------------------------------------------------------------------------
echo "== S4: the pinned exempt ledger, floors and shadowed-name sets match reality =="
if "$PY" -I -B "$GUARD" --check-pins "$REPO_ROOT" > "$TMP/pins.out" 2>&1; then
  echo "  PASS  S4 pins agree with the live scan"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S4 a pin drifted from reality"
  cat "$TMP/pins.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S5 — anti-vacuity.
# ---------------------------------------------------------------------------
echo "== S5: a NEW unread property seeded into a real script must red =="
S5_ROOT="$(seed_mutant s5)"
if substitute "$S5_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js" \
    '      launcherRc: { type: "integer" },' \
    '      launcherRc: { type: "integer" },
      phantomProp: { type: "string" },' > "$TMP/s5-seed.out" 2>&1; then
  assert_mutant_reds S5 "$S5_ROOT" --scan "claim.phantomProp" "declared and never read"
else
  echo "  FAIL  S5 could not seed the mutation (anchor moved — update this test)"
  cat "$TMP/s5-seed.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S6 — the anchor row. #513's flagship instance must stay visible.
# ---------------------------------------------------------------------------
echo "== S6: the exemption on solve-fleet intake contextFile is load-bearing =="
if grep -qF -- "plugins/uberdev/skills/solve-fleet/workflow.js:intake.issues.items.contextFile" \
    "$TMP/dump.out"; then
  echo "  PASS  S6a intake contextFile is in the exempt inventory"
  PASS=$((PASS + 1))
else
  echo "  FAIL  S6a intake contextFile is NOT in the exempt inventory — either it "
  echo "         became live (drop the exemption and this row) or the harvest lost it"
  cat "$TMP/dump.out"
  FAIL=$((FAIL + 1))
fi
S6_ROOT="$(seed_mutant s6)"
if substitute "$S6_ROOT/plugins/uberdev/skills/solve-fleet/workflow.js" \
    ' // schema-prop-unread: an optional manifest field copied verbatim; the solver prompt is built from promptFile' \
    '' > "$TMP/s6-seed.out" 2>&1; then
  assert_mutant_reds S6b "$S6_ROOT" --scan "contextFile" "declared and never read"
else
  echo "  FAIL  S6b could not remove the marker (anchor moved — update this test)"
  cat "$TMP/s6-seed.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S7 — honesty row A.
# ---------------------------------------------------------------------------
echo "== S7: a marker on a line the harvest produced no property from must red =="
S7_ROOT="$(seed_mutant s7)"
if substitute "$S7_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js" \
    '  watch: {' \
    '  watch: { // schema-prop-unread: an innocent line decorated with a borrowed exemption' \
    > "$TMP/s7-seed.out" 2>&1; then
  assert_mutant_reds S7 "$S7_ROOT" --scan "produced no property from" "goal-pipeline"
else
  echo "  FAIL  S7 could not seed the mutation (anchor moved — update this test)"
  cat "$TMP/s7-seed.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S8 — honesty row B.
# ---------------------------------------------------------------------------
echo "== S8: a marker on a property that IS read must red =="
S8_ROOT="$(seed_mutant s8)"
if substitute "$S8_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js" \
    '      launcherRc: { type: "integer" },' \
    '      launcherRc: { type: "integer" }, // schema-prop-unread: a stale exemption left behind after the read landed' \
    > "$TMP/s8-seed.out" 2>&1; then
  assert_mutant_reds S8 "$S8_ROOT" --scan "is live now" "claim.launcherRc"
else
  echo "  FAIL  S8 could not seed the mutation (anchor moved — update this test)"
  cat "$TMP/s8-seed.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S9 — the ledger ratchet, both directions.
# ---------------------------------------------------------------------------
echo "== S9: the exempt-ledger pin reds in BOTH directions =="
S9A_ROOT="$(seed_mutant s9a)"
if substitute "$S9A_ROOT/tests/schema_property_reads.py" \
    '    "plugins/uberdev/skills/solve-fleet/workflow.js:intake.issues.items.contextFile",
' '' > "$TMP/s9a-seed.out" 2>&1; then
  assert_mutant_reds S9a "$S9A_ROOT" --check-pins "GREW" "contextFile"
else
  echo "  FAIL  S9a could not remove a pin row (anchor moved — update this test)"
  cat "$TMP/s9a-seed.out"
  FAIL=$((FAIL + 1))
fi
S9B_ROOT="$(seed_mutant s9b)"
if substitute "$S9B_ROOT/tests/schema_property_reads.py" \
    'EXEMPT_LEDGER = [' \
    'EXEMPT_LEDGER = [
    "plugins/uberdev/skills/goal-pipeline/workflow.js:claim.phantomPin",' \
    > "$TMP/s9b-seed.out" 2>&1; then
  assert_mutant_reds S9b "$S9B_ROOT" --check-pins "SHRANK" "claim.phantomPin"
else
  echo "  FAIL  S9b could not add a pin row (anchor moved — update this test)"
  cat "$TMP/s9b-seed.out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# S10 — the shadowed-name ratchet.
# ---------------------------------------------------------------------------
echo "== S10: the shadowed-name pin reds when the live set drifts =="
S10_ROOT="$(seed_mutant s10)"
if substitute "$S10_ROOT/tests/schema_property_reads.py" \
    '"plugins/uberdev/skills/goal-pipeline/workflow.js": ["note", "rc"],' \
    '"plugins/uberdev/skills/goal-pipeline/workflow.js": ["note"],' \
    > "$TMP/s10-seed.out" 2>&1; then
  assert_mutant_reds S10 "$S10_ROOT" --check-pins "shadowed-name set drifted" "goal-pipeline"
else
  echo "  FAIL  S10 could not seed the mutation (anchor moved — update this test)"
  cat "$TMP/s10-seed.out"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Summary =="
echo "schema-property-reads: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
