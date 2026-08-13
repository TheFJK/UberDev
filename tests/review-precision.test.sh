#!/usr/bin/env bash
# tests/review-precision.test.sh — issue #432, RFC 0018.
#
# WHAT THIS GUARDS. `tools/eval/review-precision.py` turns the closed
# `review-pr-finding` corpus into a PUBLISHED precision claim. A published number
# that is wrong is worse than no number at all, so every property that makes the
# claim honest is asserted here:
#
#   * the adjudication ladder is total and disjoint, and a closed-COMPLETED
#     finding with no verdict label is `unadjudicated` — NEVER a true positive
#     (that single mapping would publish a near-1.0 precision measuring issue
#     hygiene rather than reviewer quality);
#   * `code-reviewer` is dispatched TWICE, so its two edges must render as two
#     rows and must never be averaged into one meaningless number;
#   * the publication floor (n=20) and the threshold floor (n=50) hold in BOTH
#     directions — a one-directional boundary test passes on a constant;
#   * pre-instrumentation rows are quarantined out of every ratio;
#   * the freshness comparator really detects a changed byte (anti-vacuity), and
#     refuses a missing or 0-byte artifact instead of certifying it;
#   * the ratchet arms only above the publication floor and respects a noise
#     floor;
#   * the prompt-provenance stamp holds in BOTH directions — a roster lens with
#     no mapped prompt file raises instead of silently shipping unstamped, and a
#     digest recorded under a key that is no longer a surface reds instead of
#     sitting in the baseline looking like coverage;
#   * a surface with no recorded digest reds unless `pending[]` says why, which
#     is how a prompt file that POSTDATES `measured_at` is declared rather than
#     stamped with bytes the numbers were never measured against;
#   * (#467) that declaration is BOUNDED rather than exempt — a declared-unmeasured
#     surface carries its current bytes in `unmeasured_digests`, so a
#     post-declaration edit still reds, a declaration with no recorded bytes at
#     all fails closed, and a path in both digest maps is refused as ambiguous;
#   * (#467) the lens->FILE map the stamp digests agrees, in both directions,
#     with `REVIEW_ROSTER[].agentFile` in the review fleet — and the comparator
#     FAILS rather than passes when it extracts nothing;
#   * the miner is repo-agnostic, does not copy the lens roster, and needs no
#     network for anything except --refresh.
#
# HERMETICITY. CI runs with `permissions: contents: read`, no secrets and no
# `gh`. Every row below except RP17/RP18 drives a FIXTURE tree through the
# --corpus/--baseline/--report/--plugin-root/--now injection seams, so nothing
# here mutates the committed artifacts and nothing depends on the wall clock.
#
# Conventions: `set -u` + `set -o pipefail`, never `set -e`, manual PASS/FAIL
# counters, herestrings instead of `| grep -q` (tests/epipe-guard.test.sh).

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
MINER="$REPO_ROOT/tools/eval/review-precision.py"
FIX="$THIS_DIR/fixtures/eval"
NOW="2026-08-10T00:00:00Z"
LATER="2026-10-10T00:00:00Z"

# Keep the checkout free of __pycache__ residue: this suite imports
# lib/report_primitives.py from inside the shipped tree, and a stray .pyc under
# plugins/ is noise in `git status` even though .gitignore covers it.
export PYTHONDONTWRITEBYTECODE=1
PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "FATAL: neither python3 nor python is on PATH" >&2
  exit 2
fi
for required in "$MINER" "$FIX/corpus-classes.json" "$FIX/corpus-families.json" \
                "$FIX/corpus-legacy.json" "$FIX/corpus-multi-edge.json"; do
  [ -r "$required" ] || { echo "FATAL: required input missing/unreadable: $required" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
no()  { echo "  FAIL  $1"; shift; for detail in "$@"; do echo "        $detail"; done; FAIL=$((FAIL + 1)); }

# `pwd -P` normalises the path. macOS exports TMPDIR WITH a trailing slash, so the
# raw mktemp result carries a `//` that Python's Path() collapses — and a
# diagnostic-names-the-file assertion would then never match its own temp path.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-precision.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "## review-precision eval harness (#432, RFC 0018)"

# --- helpers ----------------------------------------------------------------

# mk_corpus <out.json> <spec-json>
# spec rows: {"edge": "<edge id>" | null, "attr": "trailer|agent-line|none",
#             "tp": N, "fp": N, "unadj": N, "pending": N, "stale": N,
#             "not_planned": N, "edges": [..]}
# Bulk corpora are GENERATED rather than committed: fifty near-identical rows
# carry no semantics a reviewer could check, while the four committed fixtures
# in tests/fixtures/eval/ are exactly the ones that do.
mk_corpus() {
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
out, spec = sys.argv[1], json.loads(sys.argv[2])
rows, counter = [], 0
def push(edges, attr, labels, state, reason, created):
    global counter
    counter += 1
    rows.append({
        "number": 1000 + counter,
        "state": state,
        "state_reason": reason,
        "created_at": created,
        "closed_at": "2026-07-02T00:00:00Z" if state == "CLOSED" else "",
        "labels": sorted(set(labels + ["review-pr-finding"])),
        "slug": "review-pr",
        "edges": edges,
        "path": f"generated-{counter}.sh",
        "line": counter,
        "severity": "blocker",
        "tier": "BLOCKER",
        "attribution_source": attr,
        "fingerprint": f"{counter:016x}",
    })
for item in spec:
    attr = item.get("attr", "trailer")
    edges = item.get("edges")
    if edges is None:
        edges = [item["edge"]] if item.get("edge") else []
    for _ in range(item.get("tp", 0)):
        push(edges, attr, ["finding:true-positive"], "CLOSED", "COMPLETED", "2026-07-01T00:00:00Z")
    for _ in range(item.get("fp", 0)):
        push(edges, attr, ["finding:false-positive"], "CLOSED", "COMPLETED", "2026-07-01T00:00:00Z")
    for _ in range(item.get("not_planned", 0)):
        push(edges, attr, ["finding:false-positive"], "CLOSED", "NOT_PLANNED", "2026-07-01T00:00:00Z")
    for _ in range(item.get("unadj", 0)):
        push(edges, attr, [], "CLOSED", "COMPLETED", "2026-07-01T00:00:00Z")
    for _ in range(item.get("pending", 0)):
        push(edges, attr, [], "OPEN", "", "2026-08-01T00:00:00Z")
    for _ in range(item.get("stale", 0)):
        push(edges, attr, [], "OPEN", "", "2026-01-01T00:00:00Z")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "schema_version": 1,
        "repo": "fixture-owner/fixture-repo",
        "label": "review-pr-finding",
        "limit": 200,
        "generated_at": "2026-08-10T00:00:00Z",
        "corpus_path_hint": out,
        "rows": rows,
    }, fh, indent=2, sort_keys=True)
PYEOF
}

# surfaces_of -> the prompt surfaces the stamp digests, one per line, ASKED OF
# THE MINER rather than retyped here. A hand-listed fixture is a second roster:
# it keeps passing while the real surface set grows, which is exactly how the
# convention lens shipped unstamped. Derived, a new lens turns up in every plugin
# root this suite builds — and RP12/RP14/RP20-25 red until it is stamped.
surfaces_of() {
  "$PY" - "$MINER" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("review_precision", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("\n".join(module.prompt_surfaces()))
PYEOF
}

# mk_plugin_root <dir> — a synthetic plugin tree carrying every reviewer prompt
# surface the re-affirmation stamp digests. Synthetic so RP23 can mutate one
# without touching the shipped tree.
mk_plugin_root() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$1/$(dirname "$rel")"
    printf 'fixture reviewer prompt: %s\n' "$rel" > "$1/$rel"
  done <<<"$(surfaces_of)"
}

# mk_baseline <out.json> <plugin_root> <lenses-json> <pending-json> [unmeasured-json]
# The stamped surface set comes from the miner for the same reason mk_plugin_root
# derives it: a fixture baseline missing a surface would exercise a stamp
# narrower than the shipped one and report that as green.
#
# `unmeasured_digests` is emitted ALWAYS, empty by default (#467). The shipped
# baseline carries the key, so a fixture that omitted it would exercise a
# baseline shape narrower than the one the checker describes — the same
# "fixture derived from a subset of the contract" defect this row set is about.
# The 5th argument seeds it for the rows that need a pre-populated map; every
# existing call site is unchanged.
#
# The default is bound to a NAMED local, not written inline as `${5:-{}}`: that
# idiom silently corrupts every supplied value, because the shell closes the
# parameter expansion at the first `}` and leaves the second as a literal
# suffix. It reads as correct precisely because the UNSET branch is accidentally
# right — the stray `}` completes the `{` into `{}` — while `mk_baseline … '[]'`
# hands python `[]}` and dies in json.loads.
mk_baseline() {
  local unmeasured_json="${5-}"
  [ -n "$unmeasured_json" ] || unmeasured_json='{}'
  "$PY" - "$1" "$2" "$3" "$4" "$MINER" "$unmeasured_json" <<'PYEOF'
import hashlib, importlib.util, json, pathlib, sys
out, root, lenses, pending = sys.argv[1], pathlib.Path(sys.argv[2]), json.loads(sys.argv[3]), json.loads(sys.argv[4])
unmeasured = json.loads(sys.argv[6])
spec = importlib.util.spec_from_file_location("review_precision", sys.argv[5])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
digests = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in module.prompt_surfaces()}
with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "schema_version": 1,
        "measured_at": "2026-08-10T00:00:00Z",
        "lenses": lenses,
        "prompt_digests": digests,
        "pending": pending,
        "unmeasured_digests": unmeasured,
    }, fh, indent=2, sort_keys=True)
PYEOF
}

# cell_of <report> <edge> -> the precision cell of that lens row.
cell_of() {
  awk -F'|' -v edge="$2" '
    BEGIN { key = "| `" edge "` |" }
    index($0, key) == 1 { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }
  ' "$1"
}

# metric_of <report> <appendix metric label>
metric_of() {
  awk -F'|' -v m="$2" '
    BEGIN { key = "| " m " |" }
    index($0, key) == 1 { gsub(/[ \t]/, "", $3); print $3; exit }
  ' "$1"
}

sum_rows_matching() {
  awk -F'|' -v prefix="$2" '
    index($0, prefix) == 1 { gsub(/[ \t]/, "", $3); total += $3 }
    END { print total + 0 }
  ' "$1"
}

render_to() { # render_to <report> <corpus> <baseline> [now]
  "$PY" "$MINER" --render --corpus "$2" --baseline "$3" --report "$1" --now "${4:-$NOW}" >/dev/null 2>&1
}

# --- RP1–RP2: the ladder is total, disjoint, and refuses the COMPLETED shortcut

echo
echo "### Ladder"
CLASSES_REPORT="$TMP/classes.md"
BASE_PLUGIN="$TMP/plugin"
mk_plugin_root "$BASE_PLUGIN"
mk_baseline "$TMP/baseline-empty.json" "$BASE_PLUGIN" '{}' '[]'
if render_to "$CLASSES_REPORT" "$FIX/corpus-classes.json" "$TMP/baseline-empty.json"; then
  CLASS_SUM="$(sum_rows_matching "$CLASSES_REPORT" '| rows classified ')"
  CLASS_TOTAL="$(metric_of "$CLASSES_REPORT" 'rows total')"
  if [ "$CLASS_SUM" = "$CLASS_TOTAL" ] && [ "$CLASS_TOTAL" = "6" ]; then
    ok "RP1 the ladder is total and disjoint — class counts sum to the row count ($CLASS_SUM/$CLASS_TOTAL)"
  else
    no "RP1 the ladder is total and disjoint" "class sum=$CLASS_SUM rows total=$CLASS_TOTAL (expected 6/6)"
  fi
else
  no "RP1 the ladder is total and disjoint" "render failed for $FIX/corpus-classes.json"
fi

mk_corpus "$TMP/corpus-completed.json" '[{"edge":"review_pr.review.tests","unadj":3}]'
COMPLETED_REPORT="$TMP/completed.md"
render_to "$COMPLETED_REPORT" "$TMP/corpus-completed.json" "$TMP/baseline-empty.json"
RP2_UNADJ="$(metric_of "$COMPLETED_REPORT" 'rows classified `unadjudicated`')"
RP2_TP="$(metric_of "$COMPLETED_REPORT" 'rows classified `true-positive`')"
RP2_CELL="$(cell_of "$COMPLETED_REPORT" review_pr.review.tests)"
if [ "$RP2_UNADJ" = "3" ] && [ "$RP2_TP" = "0" ] && [ "$RP2_CELL" = "insufficient-data (n=0)" ]; then
  ok "RP2 closed-COMPLETED with no verdict label is unadjudicated, never a true positive"
else
  no "RP2 closed-COMPLETED with no verdict label is unadjudicated" \
     "unadjudicated=$RP2_UNADJ true-positive=$RP2_TP cell=$RP2_CELL"
fi

# --- RP3: the two code-reviewer dispatches never collapse into one number -----

echo
echo "### Per-lens separation"
mk_corpus "$TMP/corpus-two-code-reviewer-edges.json" \
  '[{"edge":"review_pr.review.correctness","tp":18,"fp":2},{"edge":"review_pr.review.general","tp":10,"fp":10}]'
TWO_REPORT="$TMP/two-edges.md"
render_to "$TWO_REPORT" "$TMP/corpus-two-code-reviewer-edges.json" "$TMP/baseline-empty.json"
RP3_CORRECTNESS="$(cell_of "$TWO_REPORT" review_pr.review.correctness)"
RP3_GENERAL="$(cell_of "$TWO_REPORT" review_pr.review.general)"
RP3_AVERAGED=0
while IFS= read -r line; do
  case "$line" in "0.700"*) RP3_AVERAGED=1 ;; esac
done <<<"$(awk -F'|' 'index($0, "| `review_pr.") == 1 { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }' "$TWO_REPORT")"
case "$RP3_CORRECTNESS:$RP3_GENERAL:$RP3_AVERAGED" in
  "0.900 (95% CI"*":0.500 (95% CI"*":0")
    ok "RP3 the two code-reviewer edges render as two distinct rows, never their average" ;;
  *)
    no "RP3 the two code-reviewer edges render as two distinct rows" \
       "correctness=$RP3_CORRECTNESS" "general=$RP3_GENERAL" "averaged(0.700) seen=$RP3_AVERAGED" ;;
esac

# --- RP4–RP5: family partition and the pre-instrumentation quarantine ---------

echo
echo "### Partition and quarantine"
FAM_REPORT="$TMP/families.md"
render_to "$FAM_REPORT" "$FIX/corpus-families.json" "$TMP/baseline-empty.json"
FAM_SUM="$(sum_rows_matching "$FAM_REPORT" '| rows in section ')"
FAM_TOTAL="$(metric_of "$FAM_REPORT" 'rows total')"
FAM_HEADLINE="$(metric_of "$FAM_REPORT" 'rows in section `headline`')"
FAM_PHASE2="$(metric_of "$FAM_REPORT" 'rows in section `phase2`')"
FAM_OTHER="$(metric_of "$FAM_REPORT" 'rows in section `other`')"
FAM_UNATTR="$(metric_of "$FAM_REPORT" 'rows in section `unattributed`')"
if [ "$FAM_SUM" = "$FAM_TOTAL" ] && [ "$FAM_TOTAL" = "4" ] \
   && [ "$FAM_HEADLINE" = "1" ] && [ "$FAM_PHASE2" = "1" ] \
   && [ "$FAM_OTHER" = "1" ] && [ "$FAM_UNATTR" = "1" ]; then
  ok "RP4 all four families partition the corpus and nothing is silently dropped"
else
  no "RP4 all four families partition the corpus" \
     "sections sum=$FAM_SUM total=$FAM_TOTAL headline=$FAM_HEADLINE phase2=$FAM_PHASE2 other=$FAM_OTHER unattributed=$FAM_UNATTR"
fi

LEGACY_REPORT="$TMP/legacy.md"
render_to "$LEGACY_REPORT" "$FIX/corpus-legacy.json" "$TMP/baseline-empty.json"
RP5_PRE="$(metric_of "$LEGACY_REPORT" 'rows in section `pre-instrumentation`')"
RP5_HEADLINE="$(metric_of "$LEGACY_REPORT" 'rows in section `headline`')"
RP5_CELL="$(cell_of "$LEGACY_REPORT" review_pr.review.correctness)"
if [ "$RP5_PRE" = "3" ] && [ "$RP5_HEADLINE" = "0" ] && [ "$RP5_CELL" = "insufficient-data (n=0)" ]; then
  ok "RP5 agent-line/none rows are quarantined out of the headline entirely"
else
  no "RP5 agent-line/none rows are quarantined out of the headline" \
     "pre-instrumentation=$RP5_PRE headline=$RP5_HEADLINE correctness cell=$RP5_CELL"
fi

# --- RP6–RP8: both floors, both directions, and the interval ------------------

echo
echo "### Publication floor, threshold floor, Wilson interval"
mk_corpus "$TMP/corpus-n19.json" '[{"edge":"review_pr.review.tests","tp":15,"fp":4}]'
mk_corpus "$TMP/corpus-n20.json" '[{"edge":"review_pr.review.tests","tp":16,"fp":4}]'
render_to "$TMP/n19.md" "$TMP/corpus-n19.json" "$TMP/baseline-empty.json"
render_to "$TMP/n20.md" "$TMP/corpus-n20.json" "$TMP/baseline-empty.json"
RP6_LOW="$(cell_of "$TMP/n19.md" review_pr.review.tests)"
RP6_HIGH="$(cell_of "$TMP/n20.md" review_pr.review.tests)"
if [ "$RP6_LOW" = "insufficient-data (n=19)" ] && [ "${RP6_HIGH#0.800 }" != "$RP6_HIGH" ]; then
  ok "RP6 the publication floor holds in BOTH directions (n=19 refuses, n=20 publishes)"
else
  no "RP6 the publication floor holds in both directions" "n=19 -> $RP6_LOW" "n=20 -> $RP6_HIGH"
fi

# RP8's expected bounds are the textbook Wilson 95% interval for 16/20 —
# (0.584, 0.919) — computed independently of this implementation.
if [ "$RP6_HIGH" = "0.800 (95% CI 0.584–0.919, n=20)" ]; then
  ok "RP8 the Wilson 95% interval for tp=16/n=20 is 0.800 (0.584–0.919)"
else
  no "RP8 the Wilson 95% interval for tp=16/n=20" "got: $RP6_HIGH" \
     "expected: 0.800 (95% CI 0.584–0.919, n=20)"
fi

mk_corpus "$TMP/corpus-n49.json" '[{"edge":"review_pr.review.tests","tp":40,"fp":9}]'
mk_corpus "$TMP/corpus-n50.json" '[{"edge":"review_pr.review.tests","tp":41,"fp":9}]'
render_to "$TMP/n49.md" "$TMP/corpus-n49.json" "$TMP/baseline-empty.json"
render_to "$TMP/n50.md" "$TMP/corpus-n50.json" "$TMP/baseline-empty.json"
threshold_of() {
  awk -F'|' -v edge="$2" '
    BEGIN { key = "| `" edge "` |"; seen = 0 }
    index($0, key) == 1 { seen++; if (seen == 2) { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit } }
  ' "$1"
}
RP7_LOW="$(threshold_of "$TMP/n49.md" review_pr.review.tests)"
RP7_HIGH="$(threshold_of "$TMP/n50.md" review_pr.review.tests)"
case "$RP7_LOW:$RP7_HIGH" in
  "insufficient-data (n=49):0."*)
    ok "RP7 the threshold floor holds in BOTH directions (n=49 derives none, n=50 derives one)" ;;
  *)
    no "RP7 the threshold floor holds in both directions" "n=49 -> $RP7_LOW" "n=50 -> $RP7_HIGH" ;;
esac

RP9_ROW="$(awk -F'|' 'index($0, "| `review_pr.review.tests` |") == 1 { print; exit }' "$TMP/n20.md")"
RP9_HEADER="$(awk 'index($0, "| Lens | Precision |") == 1 { print; exit }' "$TMP/n20.md")"
RP9_OK=1
for token in 'tp' 'fp' 'not planned' 'unadjudicated'; do
  case "$RP9_HEADER" in *"$token"*) ;; *) RP9_OK=0 ;; esac
done
case "$RP9_ROW" in *"| 16 | 4 | 0 |"*) ;; *) RP9_OK=0 ;; esac
if [ "$RP9_OK" -eq 1 ]; then
  ok "RP9 each published row exposes raw tp, fp and not-planned counts, not only the ratio"
else
  no "RP9 each published row exposes raw tp/fp/not-planned counts" "header: $RP9_HEADER" "row: $RP9_ROW"
fi

# --- RP10–RP11: repo-agnostic, roster imported not copied --------------------

echo
echo "### Repo-agnostic + single-source roster"
RP10_HITS=''
if grep -qE 'TheFJK|TurboDev' "$MINER"; then RP10_HITS="repo-identity literal"; fi
if grep -qE '/(repos|projects)/[0-9]+' "$MINER"; then
  RP10_HITS="${RP10_HITS}${RP10_HITS:+; }numeric project/repo id path"
fi
if [ -z "$RP10_HITS" ] && grep -q 'nameWithOwner' "$MINER"; then
  ok "RP10 the miner hardcodes no repo identity and resolves the slug through gh repo view"
else
  no "RP10 the miner hardcodes no repo identity" "${RP10_HITS:-no gh repo view --json nameWithOwner seam found}"
fi

MINER_ROSTER_COPY=0
grep -q 'review_pr\.review\.' "$MINER" && MINER_ROSTER_COPY=1
SHELL_ROSTER="$(bash -c "source '$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh' && review_fleet_roster review" | cut -f2)"
PY_ROSTER="$("$PY" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/plugins/uberdev/lib')
from report_primitives import PHASE1_CONTRIBUTORS
print('\n'.join(PHASE1_CONTRIBUTORS))
")"
if [ "$MINER_ROSTER_COPY" -eq 0 ] && [ "$SHELL_ROSTER" = "$PY_ROSTER" ]; then
  ok "RP11 the roster is imported, not copied — and the shell/python copies still agree in wire order"
else
  no "RP11 the roster is imported, not copied" \
     "roster literal in miner: $MINER_ROSTER_COPY" \
     "shell roster: $(printf '%s' "$SHELL_ROSTER" | tr '\n' ' ')" \
     "python roster: $(printf '%s' "$PY_ROSTER" | tr '\n' ' ')"
fi

# --- RP12: hermeticity, proven by a gh shim that must never be reached --------

echo
echo "### Hermeticity"
SHIM_DIR="$TMP/shim"
SENTINEL="$TMP/gh-was-called"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/gh" <<SHIMEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 97
SHIMEOF
chmod +x "$SHIM_DIR/gh"
HERMETIC_REPORT="$TMP/hermetic.md"
render_to "$HERMETIC_REPORT" "$FIX/corpus-families.json" "$TMP/baseline-empty.json"
HERMETIC_RC=0
env -u GH_TOKEN -u GITHUB_TOKEN PATH="$SHIM_DIR:$PATH" \
  "$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" \
  --baseline "$TMP/baseline-empty.json" --report "$HERMETIC_REPORT" \
  --plugin-root "$BASE_PLUGIN" --now "$NOW" >/dev/null 2>&1 || HERMETIC_RC=$?
if [ "$HERMETIC_RC" -eq 0 ] && [ ! -e "$SENTINEL" ]; then
  ok "RP12 --check is hermetic — rc=0 with a poisoned gh on PATH and no token, and gh was never invoked"
else
  no "RP12 --check is hermetic" "rc=$HERMETIC_RC" \
     "gh sentinel present: $([ -e "$SENTINEL" ] && echo yes || echo no)"
fi

# --- RP13: the clock is injected, not read from the wall ---------------------

echo
echo "### Clock injection"
render_to "$TMP/classes-now.md" "$FIX/corpus-classes.json" "$TMP/baseline-empty.json" "$NOW"
render_to "$TMP/classes-later.md" "$FIX/corpus-classes.json" "$TMP/baseline-empty.json" "$LATER"
RP13_PENDING_NOW="$(metric_of "$TMP/classes-now.md" 'rows classified `pending`')"
RP13_STALE_NOW="$(metric_of "$TMP/classes-now.md" 'rows classified `stale-open`')"
RP13_PENDING_LATER="$(metric_of "$TMP/classes-later.md" 'rows classified `pending`')"
RP13_STALE_LATER="$(metric_of "$TMP/classes-later.md" 'rows classified `stale-open`')"
if [ "$RP13_PENDING_NOW" = "1" ] && [ "$RP13_STALE_NOW" = "1" ] \
   && [ "$RP13_PENDING_LATER" = "0" ] && [ "$RP13_STALE_LATER" = "2" ]; then
  ok "RP13 --now is honoured — the same corpus flips one row pending -> stale-open at a later clock"
else
  no "RP13 --now is honoured" \
     "at $NOW: pending=$RP13_PENDING_NOW stale-open=$RP13_STALE_NOW" \
     "at $LATER: pending=$RP13_PENDING_LATER stale-open=$RP13_STALE_LATER"
fi

# RP13b — WITHOUT --now the clock comes from the corpus's own `generated_at`,
# never the wall. If it came from the wall, the committed report would drift by
# itself the moment an OPEN finding crossed STALE_DAYS and red the freshness
# gate in CI with nothing having changed. The corpus used here carries a
# `pending` row precisely so a wall-clock render would produce different bytes.
"$PY" "$MINER" --render --corpus "$FIX/corpus-classes.json" \
  --baseline "$TMP/baseline-empty.json" --report "$TMP/classes-noclock.md" >/dev/null 2>&1
RP13B_RC=0
"$PY" "$MINER" --check --corpus "$FIX/corpus-classes.json" \
  --baseline "$TMP/baseline-empty.json" --report "$TMP/classes-noclock.md" \
  --plugin-root "$BASE_PLUGIN" >/dev/null 2>&1 || RP13B_RC=$?
if [ "$RP13B_RC" -eq 0 ] && cmp -s "$TMP/classes-noclock.md" "$TMP/classes-now.md"; then
  ok "RP13b with no --now the clock is read from the corpus, so the report cannot drift on the wall clock"
else
  no "RP13b with no --now the clock is read from the corpus" \
     "check rc=$RP13B_RC" \
     "wall-clock render differs from the corpus-clock render: $(cmp "$TMP/classes-noclock.md" "$TMP/classes-now.md" 2>&1)"
fi

# --- RP14–RP16: freshness, anti-vacuity, and the vacuous-artifact guard -------

echo
echo "### Freshness comparator"
FRESH_REPORT="$TMP/fresh.md"
render_to "$FRESH_REPORT" "$FIX/corpus-families.json" "$TMP/baseline-empty.json"
check_fixture() { # check_fixture <corpus> <report>
  "$PY" "$MINER" --check --corpus "$1" --baseline "$TMP/baseline-empty.json" \
    --report "$2" --plugin-root "$BASE_PLUGIN" --now "$NOW" 2>&1
}
RP14_OUT="$(check_fixture "$FIX/corpus-families.json" "$FRESH_REPORT")"; RP14_RC=$?
if [ "$RP14_RC" -eq 0 ]; then
  ok "RP14 a freshly rendered report passes --check"
else
  no "RP14 a freshly rendered report passes --check" "rc=$RP14_RC" "$RP14_OUT"
fi

printf 'x' >> "$FRESH_REPORT"
RP15_OUT="$(check_fixture "$FIX/corpus-families.json" "$FRESH_REPORT")"; RP15_RC=$?
if [ "$RP15_RC" -eq 1 ] && grep -qF "$FRESH_REPORT" <<<"$RP15_OUT"; then
  ok "RP15 anti-vacuity — one appended byte reds --check and the diagnostic names the report"
else
  no "RP15 anti-vacuity — one appended byte reds --check" "rc=$RP15_RC" "$RP15_OUT"
fi

RP16_FAILS=''
RP16_OUT="$(check_fixture "$FIX/corpus-families.json" "$TMP/does-not-exist.md")"; RP16_RC=$?
if [ "$RP16_RC" -ne 1 ] || ! grep -qF 'does-not-exist.md' <<<"$RP16_OUT"; then
  RP16_FAILS="missing-report rc=$RP16_RC out=$RP16_OUT"
fi
: > "$TMP/empty.md"
RP16_OUT="$(check_fixture "$FIX/corpus-families.json" "$TMP/empty.md")"; RP16_RC=$?
if [ "$RP16_RC" -ne 1 ] || ! grep -qF 'empty.md' <<<"$RP16_OUT"; then
  RP16_FAILS="${RP16_FAILS}${RP16_FAILS:+; }zero-byte-report rc=$RP16_RC out=$RP16_OUT"
fi
RP16_OUT="$(check_fixture "$TMP/no-such-corpus.json" "$FRESH_REPORT")"; RP16_RC=$?
if [ "$RP16_RC" -ne 2 ] || ! grep -qF 'no-such-corpus.json' <<<"$RP16_OUT"; then
  RP16_FAILS="${RP16_FAILS}${RP16_FAILS:+; }unreadable-corpus rc=$RP16_RC out=$RP16_OUT"
fi
if [ -z "$RP16_FAILS" ]; then
  ok "RP16 a missing, 0-byte or uncomparable artifact fails loudly and names the offending file"
else
  no "RP16 a missing, 0-byte or uncomparable artifact fails loudly" "$RP16_FAILS"
fi

# --- RP17–RP19: the committed artifacts ---------------------------------------

echo
echo "### Committed artifacts"
RP17_OUT="$("$PY" "$MINER" --check 2>&1)"; RP17_RC=$?
if [ "$RP17_RC" -eq 0 ]; then
  ok "RP17 the committed corpus, baseline and report agree (freshness + ratchet + prompt digests)"
else
  no "RP17 the committed corpus, baseline and report agree" "rc=$RP17_RC" "$RP17_OUT"
fi

RP18_FAILS=''
git -C "$REPO_ROOT" ls-files --error-unmatch docs/eval/review-precision.md >/dev/null 2>&1 \
  || RP18_FAILS="docs/eval/review-precision.md is not git-tracked"
if git -C "$REPO_ROOT" check-ignore -q docs/eval/review-precision.md 2>/dev/null; then
  RP18_FAILS="${RP18_FAILS}${RP18_FAILS:+; }docs/eval/review-precision.md is git-ignored"
fi
if [ -z "$RP18_FAILS" ]; then
  ok "RP18 the published report is git-tracked and no longer swept up by the docs/* ignore"
else
  no "RP18 the published report is git-tracked and un-ignored" "$RP18_FAILS"
fi

# RP19 scans the committed DATA artifacts, never the parser: the miner has to
# name the marker prefix to recognise it, while a corpus row or a rendered table
# carrying that literal means a raw issue body leaked into the tree, where the
# same fail-CLOSED dedupe and refusal paths read it (RFC 0018 §2.1/§4).
RP19_SCANNED=0
RP19_LEAKED=''
while IFS= read -r artifact; do
  [ -f "$artifact" ] || continue
  RP19_SCANNED=$((RP19_SCANNED + 1))
  if grep -qF -e '<!-- uberdev:' -e '<!-- uberdev-finding-meta' "$artifact"; then
    RP19_LEAKED="${RP19_LEAKED}${RP19_LEAKED:+; }$artifact"
  fi
done <<<"$(printf '%s\n' \
  "$REPO_ROOT/tools/eval/corpus.json" \
  "$REPO_ROOT/tools/eval/precision-baseline.json" \
  "$FIX/corpus-classes.json" "$FIX/corpus-families.json" \
  "$FIX/corpus-legacy.json" "$FIX/corpus-multi-edge.json"
  find "$REPO_ROOT/docs/eval" -type f 2>/dev/null)"
if [ "$RP19_SCANNED" -lt 7 ]; then
  no "RP19 no committed eval artifact carries a fingerprint marker" \
     "only $RP19_SCANNED artifacts were scanned — refusing a vacuous pass (expected the corpus, the baseline, 4 fixtures and the report)"
elif [ -n "$RP19_LEAKED" ]; then
  no "RP19 no committed eval artifact carries a fingerprint marker" \
     "a raw body leaked into the tree — it can forge the fail-CLOSED dedupe (RFC 0018 §2.1)" \
     "$RP19_LEAKED"
else
  ok "RP19 none of the $RP19_SCANNED committed eval artifacts carries a marker (raw bodies are never stored)"
fi

# --- RP20–RP22: the ratchet ---------------------------------------------------

echo
echo "### Precision ratchet"
ratchet_case() { # ratchet_case <corpus-spec> <baseline-lenses>
  mk_corpus "$TMP/ratchet-corpus.json" "$1"
  mk_baseline "$TMP/ratchet-baseline.json" "$BASE_PLUGIN" "$2" '[]'
  render_to "$TMP/ratchet.md" "$TMP/ratchet-corpus.json" "$TMP/ratchet-baseline.json"
  "$PY" "$MINER" --check --corpus "$TMP/ratchet-corpus.json" \
    --baseline "$TMP/ratchet-baseline.json" --report "$TMP/ratchet.md" \
    --plugin-root "$BASE_PLUGIN" --now "$NOW" 2>&1
}

RP20_OUT="$(ratchet_case \
  '[{"edge":"review_pr.review.correctness","tp":20,"fp":20}]' \
  '{"review_pr.review.correctness":{"tp":36,"fp":4,"n":40}}')"; RP20_RC=$?
if [ "$RP20_RC" -eq 1 ] && grep -qF 'review_pr.review.correctness' <<<"$RP20_OUT"; then
  ok "RP20 an armed lens dropping 0.900 -> 0.500 at n=40 reds --check and the diagnostic names the lens"
else
  no "RP20 an armed lens dropping 0.900 -> 0.500 reds --check" "rc=$RP20_RC" "$RP20_OUT"
fi

RP21_OUT="$(ratchet_case \
  '[{"edge":"review_pr.review.correctness","tp":22,"fp":3}]' \
  '{"review_pr.review.correctness":{"tp":36,"fp":4,"n":40}}')"; RP21_RC=$?
if [ "$RP21_RC" -eq 0 ]; then
  ok "RP21 noise floor — a 0.900 -> 0.880 drop whose CI upper bound still covers the baseline does not red"
else
  no "RP21 noise floor — a within-noise drop must not red" "rc=$RP21_RC" "$RP21_OUT"
fi

RP22_OUT="$(ratchet_case \
  '[{"edge":"review_pr.review.correctness","fp":5}]' \
  '{"review_pr.review.correctness":{"tp":5,"fp":0,"n":5}}')"; RP22_RC=$?
if [ "$RP22_RC" -eq 0 ]; then
  ok "RP22 the ratchet is unarmed below the publication floor — a 1.000 -> 0.000 drop at n=5 does not red"
else
  no "RP22 the ratchet is unarmed below the publication floor" "rc=$RP22_RC" "$RP22_OUT"
fi

# --- RP23–RP25: the prompt-digest re-affirmation stamp -----------------------

echo
echo "### Prompt-provenance stamp"
STAMP_PLUGIN="$TMP/stamp-plugin"
mk_plugin_root "$STAMP_PLUGIN"
mk_baseline "$TMP/stamp-baseline.json" "$STAMP_PLUGIN" '{}' '[]'
render_to "$TMP/stamp.md" "$FIX/corpus-families.json" "$TMP/stamp-baseline.json"
stamp_check() { # stamp_check <baseline>
  "$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" --baseline "$1" \
    --report "$TMP/stamp.md" --plugin-root "$STAMP_PLUGIN" --now "$NOW" 2>&1
}

printf 'mutated by the test\n' >> "$STAMP_PLUGIN/agents/code-reviewer.md"
RP23_OUT="$(stamp_check "$TMP/stamp-baseline.json")"; RP23_RC=$?
if [ "$RP23_RC" -eq 1 ] && grep -qF 'agents/code-reviewer.md' <<<"$RP23_OUT"; then
  ok "RP23 an edited reviewer prompt reds --check and the diagnostic names the path"
else
  no "RP23 an edited reviewer prompt reds --check" "rc=$RP23_RC" "$RP23_OUT"
fi

mk_baseline "$TMP/stamp-declared.json" "$STAMP_PLUGIN" '{}' '[]'
"$PY" - "$TMP/stamp-baseline.json" "$TMP/stamp-declared.json" <<'PYEOF'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
record["pending"] = [{"path": "agents/code-reviewer.md", "reason": "re-measure deferred to the next refresh"}]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
RP24_OUT="$(stamp_check "$TMP/stamp-declared.json")"; RP24_RC=$?
RP24_FAILS=''
[ "$RP24_RC" -eq 0 ] || RP24_FAILS="declared drift still reds: rc=$RP24_RC $RP24_OUT"
printf 'second undeclared mutation\n' >> "$STAMP_PLUGIN/agents/comment-analyzer.md"
RP24_OUT2="$(stamp_check "$TMP/stamp-declared.json")"; RP24_RC2=$?
if [ "$RP24_RC2" -ne 1 ] || ! grep -qF 'agents/comment-analyzer.md' <<<"$RP24_OUT2"; then
  RP24_FAILS="${RP24_FAILS}${RP24_FAILS:+; }second undeclared drift not caught: rc=$RP24_RC2 $RP24_OUT2"
fi
if [ -z "$RP24_FAILS" ]; then
  ok "RP24 a declared pending[] entry clears exactly one path — a second undeclared drift still reds"
else
  no "RP24 a declared pending[] entry clears exactly one path" "$RP24_FAILS"
fi

CLEAN_PLUGIN="$TMP/clean-plugin"
mk_plugin_root "$CLEAN_PLUGIN"
mk_baseline "$TMP/clean-baseline.json" "$CLEAN_PLUGIN" '{}' \
  '[{"path":"agents/code-reviewer.md","reason":"parked with no actual drift"}]'
render_to "$TMP/clean.md" "$FIX/corpus-families.json" "$TMP/clean-baseline.json"
RP25_OUT="$("$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" \
  --baseline "$TMP/clean-baseline.json" --report "$TMP/clean.md" \
  --plugin-root "$CLEAN_PLUGIN" --now "$NOW" 2>&1)"; RP25_RC=$?
if [ "$RP25_RC" -eq 1 ] && grep -qF 'stale declaration, path does not diverge' <<<"$RP25_OUT"; then
  ok "RP25 anti-parking — a pending[] entry naming an undrifted path reds instead of exempting it forever"
else
  no "RP25 anti-parking — an undrifted pending[] entry must red" "rc=$RP25_RC" "$RP25_OUT"
fi

# --- RP26: the multi-edge counting rule is disclosed, not hidden --------------

echo
echo "### Multi-edge accounting"
MULTI_REPORT="$TMP/multi.md"
render_to "$MULTI_REPORT" "$FIX/corpus-multi-edge.json" "$TMP/baseline-empty.json"
RP26_ROWS="$(metric_of "$MULTI_REPORT" 'rows total')"
RP26_MULTI="$(metric_of "$MULTI_REPORT" 'multi-edge rows')"
RP26_OBS="$(metric_of "$MULTI_REPORT" 'edge observations')"
if [ "$RP26_ROWS" = "2" ] && [ "$RP26_MULTI" = "1" ] && [ "$RP26_OBS" = "3" ]; then
  ok "RP26 a k-edge row counts once per edge and the appendix discloses the arithmetic (2 rows, 3 observations)"
else
  no "RP26 a k-edge row counts once per edge and is disclosed" \
     "rows=$RP26_ROWS multi_edge_rows=$RP26_MULTI edge_observations=$RP26_OBS (expected 2/1/3)"
fi

# --- RP27–RP29: the stamp's OTHER direction ----------------------------------
#
# WHY THESE EXIST. RP23–RP25 all walk prompt_surfaces() — and so does the code
# they drive. A guard whose predicate is DERIVED from the same set it is meant to
# police cannot see a defect that changes the set itself: unmap a lens and the
# surface loop simply stops visiting its prompt, quietly. Worse, mk_plugin_root
# and mk_baseline above BOTH derive from prompt_surfaces() (deliberately — see
# their comments), so a fixture built that way moves both sides together and
# stays green through exactly that mutation. Verified, not assumed: deleting the
# unmapped-lens raise and dropping one LENS_PROMPT_FILES entry left `--check`
# at rc=0 and this suite at PASS=27 FAIL=0. The three rows below are the ones
# that red for it.

echo
echo "### Prompt-provenance stamp — the other direction"

# unmapped_lens_probe — prompt_surfaces() with one roster edge that has no
# LENS_PROMPT_FILES entry. PHASE1_CONTRIBUTORS is monkeypatched ON THE MODULE
# (prompt_surfaces reads the global by name) so nothing under plugins/ is
# touched, and the probe edge is BUILT from a real roster id's prefix rather
# than typed here — a literal would be the roster copy the miner's import exists
# to prevent. Prints RAISED/NO-RAISE/PRE-RAISE and exits 0 only on RAISED.
unmapped_lens_probe() {
  "$PY" - "$MINER" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("review_precision", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.prompt_surfaces()
except module.InputError as exc:
    print("PRE-RAISE the shipped roster already fails: " + str(exc))
    sys.exit(2)
probe = module.PHASE1_CONTRIBUTORS[0].rpartition(".")[0] + ".unmapped_probe"
module.PHASE1_CONTRIBUTORS = tuple(module.PHASE1_CONTRIBUTORS) + (probe,)
try:
    surfaces = module.prompt_surfaces()
except module.InputError as exc:
    print("RAISED " + " ".join(str(exc).split()))
    sys.exit(0)
print("NO-RAISE " + " ".join(surfaces))
sys.exit(1)
PYEOF
}
RP27_OUT="$(unmapped_lens_probe 2>&1)"; RP27_RC=$?
RP27_FAILS=''
[ "$RP27_RC" -eq 0 ] || RP27_FAILS="rc=$RP27_RC out=$RP27_OUT"
grep -qF 'unmapped_probe' <<<"$RP27_OUT" || \
  RP27_FAILS="${RP27_FAILS}${RP27_FAILS:+; }diagnostic does not name the offending edge: $RP27_OUT"
grep -qF 'LENS_PROMPT_FILES' <<<"$RP27_OUT" || \
  RP27_FAILS="${RP27_FAILS}${RP27_FAILS:+; }diagnostic does not name the map to fix: $RP27_OUT"
if [ -z "$RP27_FAILS" ]; then
  ok "RP27 a Phase 1 lens with no mapped prompt file RAISES — it never ships unstamped by skipping"
else
  no "RP27 a Phase 1 lens with no mapped prompt file raises" "$RP27_FAILS"
fi

# add_orphan_digest <baseline> — record a digest under a key prompt_surfaces()
# does not yield. This is precisely what a retired, renamed or unmapped lens
# leaves behind, and the surface-side loop is blind to it by construction.
add_orphan_digest() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
record["prompt_digests"]["agents/retired-lens.md"] = "0" * 64
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
}
ORPHAN_PLUGIN="$TMP/orphan-plugin"
mk_plugin_root "$ORPHAN_PLUGIN"
mk_baseline "$TMP/orphan-baseline.json" "$ORPHAN_PLUGIN" '{}' '[]'
render_to "$TMP/orphan.md" "$FIX/corpus-families.json" "$TMP/orphan-baseline.json"
orphan_check() {
  "$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" \
    --baseline "$TMP/orphan-baseline.json" --report "$TMP/orphan.md" \
    --plugin-root "$ORPHAN_PLUGIN" --now "$NOW" 2>&1
}
RP28_CLEAN_OUT="$(orphan_check)"; RP28_CLEAN_RC=$?
add_orphan_digest "$TMP/orphan-baseline.json"
RP28_OUT="$(orphan_check)"; RP28_RC=$?
RP28_FAILS=''
# Both directions: a stamp that reds on the orphan but also on the pristine
# baseline is a broken predicate, not a guard.
[ "$RP28_CLEAN_RC" -eq 0 ] || RP28_FAILS="pristine baseline already reds: rc=$RP28_CLEAN_RC $RP28_CLEAN_OUT"
if [ "$RP28_RC" -ne 1 ] || ! grep -qF 'agents/retired-lens.md' <<<"$RP28_OUT"; then
  RP28_FAILS="${RP28_FAILS}${RP28_FAILS:+; }orphaned digest not caught: rc=$RP28_RC $RP28_OUT"
fi
if [ -z "$RP28_FAILS" ]; then
  ok "RP28 a digest recorded for a path that is no longer a surface reds — the stamp is compared in both directions"
else
  no "RP28 a digest recorded for a non-surface reds" "$RP28_FAILS"
fi

# drop_digest <baseline> <rel> [reason] — unstamp one surface. With no reason
# it is simply missing; with one, pending[] declares it. That declaration is the
# committed baseline's own shape for `agents/convention-compliance.md` and
# `shared/finding-confidence-rubric-v1.md`: both files were CREATED after
# `measured_at`, so no digest of them can be a measured digest and stamping the
# current bytes would assert a measurement that never happened.
drop_digest() {
  "$PY" - "$1" "$2" "${3:-}" <<'PYEOF'
import json, sys
path, rel, reason = sys.argv[1], sys.argv[2], sys.argv[3]
record = json.load(open(path, encoding="utf-8"))
record["prompt_digests"].pop(rel, None)
record["pending"] = [{"path": rel, "reason": reason}] if reason else []
with open(path, "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
}
# set_unmeasured <baseline> <rel> <plugin_root> — record the LIVE sha256 of
# <rel> under `unmeasured_digests` (#467). This is the TETHER for a surface that
# has no measured bytes to stamp: unlike prompt_digests[rel] it says nothing
# about what the published numbers were measured against, only "these are the
# bytes that were current when the declaration was written" — so a later edit of
# a declared-unmeasured prompt still reds. drop_digest above keeps its own
# semantics unchanged (pop the digest, replace pending[]) precisely so it stays
# the producer of the FAILS-CLOSED fixture RP32 needs.
set_unmeasured() {
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import hashlib, json, pathlib, sys
path, rel, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
record = json.load(open(path, encoding="utf-8"))
record.setdefault("unmeasured_digests", {})[rel] = hashlib.sha256((root / rel).read_bytes()).hexdigest()
with open(path, "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
}
UNSTAMPED_PLUGIN="$TMP/unstamped-plugin"
mk_plugin_root "$UNSTAMPED_PLUGIN"
mk_baseline "$TMP/unstamped-baseline.json" "$UNSTAMPED_PLUGIN" '{}' '[]'
render_to "$TMP/unstamped.md" "$FIX/corpus-families.json" "$TMP/unstamped-baseline.json"
unstamped_check() {
  "$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" \
    --baseline "$TMP/unstamped-baseline.json" --report "$TMP/unstamped.md" \
    --plugin-root "$UNSTAMPED_PLUGIN" --now "$NOW" 2>&1
}
drop_digest "$TMP/unstamped-baseline.json" 'agents/comment-analyzer.md'
RP29_BARE_OUT="$(unstamped_check)"; RP29_BARE_RC=$?
drop_digest "$TMP/unstamped-baseline.json" 'agents/comment-analyzer.md' \
  'the file postdates measured_at, so there are no measured bytes to stamp'
# #467: a declaration alone no longer clears the surface — it must also be
# BOUNDED by an unmeasured_digests entry, or nothing would ever notice the
# declared file changing again. RP32 below is the row that pins the bare
# (unbounded) declaration as a red.
set_unmeasured "$TMP/unstamped-baseline.json" 'agents/comment-analyzer.md' "$UNSTAMPED_PLUGIN"
RP29_DECL_OUT="$(unstamped_check)"; RP29_DECL_RC=$?
RP29_FAILS=''
if [ "$RP29_BARE_RC" -ne 1 ] || ! grep -qF 'agents/comment-analyzer.md' <<<"$RP29_BARE_OUT"; then
  RP29_FAILS="undeclared unstamped surface not caught: rc=$RP29_BARE_RC $RP29_BARE_OUT"
fi
[ "$RP29_DECL_RC" -eq 0 ] || \
  RP29_FAILS="${RP29_FAILS}${RP29_FAILS:+; }declared unstamped surface still reds: rc=$RP29_DECL_RC $RP29_DECL_OUT"
if [ -z "$RP29_FAILS" ]; then
  ok "RP29 an unstamped surface reds undeclared and clears only once pending[] states why the bytes were never measured"
else
  no "RP29 an unstamped surface reds unless pending[] declares it" "$RP29_FAILS"
fi

# --- RP30/RP30b: the lens->file mapping is COMPARED, not merely copied -------
#
# WHY THIS EXISTS (#467). v0.45.13 made the lens SET derived — prompt_surfaces()
# walks PHASE1_CONTRIBUTORS — but the derivation stops one step short of the
# bytes actually digested: the lens->FILE map (LENS_PROMPT_FILES) is a
# hand-maintained copy of REVIEW_ROSTER[].agentFile in the review fleet, and
# nothing compared them. Proven on the shipped tree: repoint one roster
# `agentFile:` to another existing agent file, leave the miner alone, then drift
# the newly-dispatched file — `--check` stays rc=0. The stamp watches a file the
# fleet no longer dispatches and never watches the one it does. (A repoint to a
# NON-existent file already fails closed through `reviewer prompt surface is
# missing`; only repoint-to-an-existing-file was silent.)
#
# The comparison lives here rather than inside the miner deliberately: parsing
# workflow.js from review-precision.py would make `--check` fail with a JS
# PARSING diagnostic on a brace reflow, and would make prompt_surfaces()
# plugin-root-dependent — every fixture tree mk_plugin_root builds would then
# need a synthetic workflow.js. R-roster-complete in tests/post-impl-review.test.sh
# set the precedent of comparing copies test-side for exactly this reason.

echo
echo "### The lens->file mapping is compared, not just copied (#467)"

REVIEW_FLEET_JS="$REPO_ROOT/plugins/uberdev/skills/review-fleet/workflow.js"

# roster_pairs <workflow.js> — extract {edge-last-segment: agentFile} from the
# REVIEW_ROSTER block and compare it BOTH WAYS with the miner's
# LENS_PROMPT_FILES. Takes the JS path as an ARGUMENT so RP30b can drive it
# against a scratch copy without ever mutating the shipped file.
#
# Four mechanics carry the anti-vacuity weight:
#   * the roster is sliced to its own BLOCK, so LENS_ROSTER can gain an
#     `agentFile` field later without silently re-pairing anything;
#   * records are split on `{ ... }` rather than paired positionally, so a
#     reflow to one line per record cannot mis-pair an edge with another
#     record's file;
#   * the key is the last dot segment of `edge:` (`silent_failures`), NEVER
#     `slug:` — the slug is hyphenated (`silent-failures`) and joining on it
#     would yield a permanently-empty intersection that passes forever;
#   * the miner side is IMPORTED, never regexed out of the .py, which would
#     itself be a new uncompared copy of the map's syntax.
# Pairs are compared as SETS OF PAIRS, not as file lists: code-reviewer.md is
# mapped by two edges, so a value-set compare sees 6 files for 7 edges and a
# repoint between two mapped files would slip through.
roster_pairs() {
  "$PY" - "$MINER" "$1" <<'PYEOF'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("review_precision", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    source = open(sys.argv[2], encoding="utf-8").read()
except OSError as exc:
    print(f"UNREADABLE roster: {exc}")
    sys.exit(2)
start = source.find("const REVIEW_ROSTER = [")
end = source.find("\n];", start) if start >= 0 else -1
if start < 0 or end < 0:
    # A renamed or reshaped constant must FAIL this row, never vacuously pass
    # it: a guard that silently extracts nothing is the vacuous-scan defect,
    # not a guard.
    print("NO-BLOCK the REVIEW_ROSTER block was not found or has no `\\n];` terminator")
    sys.exit(1)
block = source[start:end]
records = re.findall(r"\{([^{}]*)\}", block, re.S)
problems, pairs = [], {}
for record in records:
    edge = re.search(r'edge:\s*"([^"]*)"', record)
    agent_file = re.search(r'agentFile:\s*"([^"]*)"', record)
    if edge is None or agent_file is None:
        problems.append("roster record lacks edge or agentFile: " + " ".join(record.split()))
        continue
    pairs[edge.group(1).rpartition(".")[2]] = agent_file.group(1)
if not pairs:
    problems.append(f"extracted ZERO roster pairs from {len(records)} record(s) — refusing a vacuous pass")
declared_files = block.count("agentFile:")
if len(pairs) != declared_files:
    problems.append(
        f"extracted {len(pairs)} pair(s) but the block contains {declared_files} "
        "`agentFile:` occurrence(s) — a record was skipped or double-counted"
    )
mined = dict(module.LENS_PROMPT_FILES)
only_roster = sorted(set(pairs.items()) - set(mined.items()))
only_miner = sorted(set(mined.items()) - set(pairs.items()))
if only_roster or only_miner:
    problems.append(
        "REVIEW_ROSTER[].agentFile and LENS_PROMPT_FILES disagree; "
        f"in the roster only: {only_roster}; in the miner only: {only_miner}"
    )
if problems:
    print("PAIRS-FAIL " + " | ".join(problems))
    sys.exit(1)
print(f"PAIRS-OK {len(pairs)} lens->file pair(s) agree in both directions")
sys.exit(0)
PYEOF
}

RP30_FAILS=''
if [ ! -r "$REVIEW_FLEET_JS" ]; then
  # An unreadable roster is a FAIL, not a skip: the comparison did not run.
  RP30_FAILS="the review fleet roster is missing or unreadable: $REVIEW_FLEET_JS"
else
  RP30_OUT="$(roster_pairs "$REVIEW_FLEET_JS" 2>&1)"; RP30_RC=$?
  [ "$RP30_RC" -eq 0 ] || RP30_FAILS="rc=$RP30_RC $RP30_OUT"
fi
if [ -z "$RP30_FAILS" ]; then
  ok "RP30 every REVIEW_ROSTER edge->agentFile pair agrees with the miner's LENS_PROMPT_FILES, in both directions"
else
  no "RP30 the roster and the miner agree on which file each lens is dispatched with" "$RP30_FAILS"
fi

# RP30b — the anti-vacuity half, as a permanent row rather than a one-off manual
# proof. Rename the constant in a SCRATCH COPY (the shipped file is never
# touched) and require the comparator to FAIL: a scan that extracts nothing must
# not report agreement.
RP30B_JS="$TMP/renamed-roster-workflow.js"
sed 's/const REVIEW_ROSTER = \[/const REVIEW_ROSTER_RENAMED = [/' "$REVIEW_FLEET_JS" > "$RP30B_JS"
RP30B_OUT="$(roster_pairs "$RP30B_JS" 2>&1)"; RP30B_RC=$?
RP30B_FAILS=''
[ "$RP30B_RC" -ne 0 ] || \
  RP30B_FAILS="a renamed REVIEW_ROSTER constant still reported agreement (rc=0): $RP30B_OUT"
grep -qF 'NO-BLOCK' <<<"$RP30B_OUT" || \
  RP30B_FAILS="${RP30B_FAILS}${RP30B_FAILS:+; }the diagnostic does not say the block was not found: $RP30B_OUT"
if [ -z "$RP30B_FAILS" ]; then
  ok "RP30b the comparator FAILS when the roster constant is renamed — it cannot pass by extracting nothing"
else
  no "RP30b the comparator fails rather than passing vacuously" "$RP30B_FAILS"
fi

# --- RP31–RP35: the declared-unmeasured tether (#467) ------------------------
#
# WHY THESE EXIST. Until #467 the missing-digest arm `continue`d the moment
# pending[] named the path, so a surface with no measured bytes was exempt from
# BOTH comparisons — permanently, and silently. Proven on the shipped tree:
# appending one line to plugins/uberdev/agents/convention-compliance.md left
# `--check` at rc=0 with this suite green. The root cause is that
# `prompt_digests` carried two meanings in one field — "the bytes the published
# numbers were measured against" AND "the bytes we notice changing" — so a
# surface that could not honestly carry the first lost the second as well.
# `unmeasured_digests` gives the second meaning its own field, and the rows below
# drive every arm of it: bounded (clears), edited-after-declaration (reds),
# declared-but-unbounded (reds), both-fields (reds), orphan key (reds), and the
# schema arms (rc=2).

echo
echo "### Declared-unmeasured surfaces stay watched (#467)"

# check_with <baseline> <report> <plugin_root> — one --check against a
# caller-owned fixture triple. Every row below builds its OWN plugin root and
# baseline rather than sharing one: these rows MUTATE their fixture files, and a
# leaked mutation turns a later row's control arm into a false red.
check_with() {
  "$PY" "$MINER" --check --corpus "$FIX/corpus-families.json" --baseline "$1" \
    --report "$2" --plugin-root "$3" --now "$NOW" 2>&1
}

UNMEASURED_PLUGIN="$TMP/unmeasured-plugin"
mk_plugin_root "$UNMEASURED_PLUGIN"
mk_baseline "$TMP/unmeasured-baseline.json" "$UNMEASURED_PLUGIN" '{}' '[]'
render_to "$TMP/unmeasured.md" "$FIX/corpus-families.json" "$TMP/unmeasured-baseline.json"
drop_digest "$TMP/unmeasured-baseline.json" 'agents/comment-analyzer.md' \
  'the file postdates measured_at, so there are no measured bytes to stamp'
set_unmeasured "$TMP/unmeasured-baseline.json" 'agents/comment-analyzer.md' "$UNMEASURED_PLUGIN"
RP31_CTRL_OUT="$(check_with "$TMP/unmeasured-baseline.json" "$TMP/unmeasured.md" "$UNMEASURED_PLUGIN")"
RP31_CTRL_RC=$?
printf 'post-declaration edit\n' >> "$UNMEASURED_PLUGIN/agents/comment-analyzer.md"
RP31_OUT="$(check_with "$TMP/unmeasured-baseline.json" "$TMP/unmeasured.md" "$UNMEASURED_PLUGIN")"
RP31_RC=$?
RP31_FAILS=''
# Both directions: a rule that reds on the edited tree but ALSO on the bounded
# control is a broken predicate, not a guard.
[ "$RP31_CTRL_RC" -eq 0 ] || \
  RP31_FAILS="bounded declaration already reds: rc=$RP31_CTRL_RC $RP31_CTRL_OUT"
if [ "$RP31_RC" -ne 1 ]; then
  RP31_FAILS="${RP31_FAILS}${RP31_FAILS:+; }post-declaration edit not caught: rc=$RP31_RC $RP31_OUT"
fi
grep -qF 'agents/comment-analyzer.md' <<<"$RP31_OUT" || \
  RP31_FAILS="${RP31_FAILS}${RP31_FAILS:+; }diagnostic does not name the drifted path: $RP31_OUT"
grep -qF 'unmeasured_digests' <<<"$RP31_OUT" || \
  RP31_FAILS="${RP31_FAILS}${RP31_FAILS:+; }diagnostic does not name the field to re-record: $RP31_OUT"
if [ -z "$RP31_FAILS" ]; then
  ok "RP31 a declared-unmeasured surface edited after its declaration reds — the declaration is bounded, not an exemption"
else
  no "RP31 a declared-unmeasured surface edited after its declaration reds" "$RP31_FAILS"
fi

# RP32 — fails CLOSED. `drop_digest` with a reason and no set_unmeasured is
# exactly the pre-#467 baseline shape, and it must now red with a message that
# names the field the reader has to add. An absent `unmeasured_digests` key is
# read as {} — never as "nothing to check".
UNBOUNDED_PLUGIN="$TMP/unbounded-plugin"
mk_plugin_root "$UNBOUNDED_PLUGIN"
mk_baseline "$TMP/unbounded-baseline.json" "$UNBOUNDED_PLUGIN" '{}' '[]'
render_to "$TMP/unbounded.md" "$FIX/corpus-families.json" "$TMP/unbounded-baseline.json"
drop_digest "$TMP/unbounded-baseline.json" 'agents/comment-analyzer.md' \
  'declared, but with no recorded bytes of any kind'
RP32_OUT="$(check_with "$TMP/unbounded-baseline.json" "$TMP/unbounded.md" "$UNBOUNDED_PLUGIN")"
RP32_RC=$?
RP32_FAILS=''
[ "$RP32_RC" -eq 1 ] || RP32_FAILS="unbounded declaration did not red: rc=$RP32_RC $RP32_OUT"
grep -qF 'agents/comment-analyzer.md' <<<"$RP32_OUT" || \
  RP32_FAILS="${RP32_FAILS}${RP32_FAILS:+; }diagnostic does not name the path: $RP32_OUT"
grep -qF 'unmeasured_digests' <<<"$RP32_OUT" || \
  RP32_FAILS="${RP32_FAILS}${RP32_FAILS:+; }diagnostic does not name the field to add: $RP32_OUT"
if [ -z "$RP32_FAILS" ]; then
  ok "RP32 a pending[] declaration with no recorded bytes at all fails CLOSED and names the field to add"
else
  no "RP32 a declaration with no recorded bytes fails closed" "$RP32_FAILS"
fi

# RP33 — a path in BOTH maps. The ambiguity is the whole point: one field would
# mask the other (which digest is the check comparing against?), and that is a
# smaller copy of the one-field-two-jobs conflation `unmeasured_digests` exists
# to remove. A surface is either measured or declared-unmeasured, never both.
BOTH_PLUGIN="$TMP/both-maps-plugin"
mk_plugin_root "$BOTH_PLUGIN"
mk_baseline "$TMP/both-maps-baseline.json" "$BOTH_PLUGIN" '{}' '[]' \
  '{"agents/comment-analyzer.md":"0000000000000000000000000000000000000000000000000000000000000000"}'
render_to "$TMP/both-maps.md" "$FIX/corpus-families.json" "$TMP/both-maps-baseline.json"
RP33_OUT="$(check_with "$TMP/both-maps-baseline.json" "$TMP/both-maps.md" "$BOTH_PLUGIN")"
RP33_RC=$?
RP33_FAILS=''
[ "$RP33_RC" -eq 1 ] || RP33_FAILS="a path in both maps did not red: rc=$RP33_RC $RP33_OUT"
grep -qF 'agents/comment-analyzer.md' <<<"$RP33_OUT" || \
  RP33_FAILS="${RP33_FAILS}${RP33_FAILS:+; }diagnostic does not name the ambiguous path: $RP33_OUT"
if [ -z "$RP33_FAILS" ]; then
  ok "RP33 a path recorded in BOTH prompt_digests and unmeasured_digests reds — one field would mask the other"
else
  no "RP33 a path recorded in both maps reds" "$RP33_FAILS"
fi

# add_orphan_unmeasured <baseline> — the mirror of add_orphan_digest. A retired,
# renamed or unmapped lens leaves its key behind in whichever map held it, and
# the surface-side loop is blind to both by construction: it walks
# prompt_surfaces(), so a key that is no longer a surface is simply never
# visited while it sits in the baseline looking like coverage.
add_orphan_unmeasured() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
record.setdefault("unmeasured_digests", {})["agents/retired-lens.md"] = "0" * 64
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
}
ORPHAN_UNM_PLUGIN="$TMP/orphan-unmeasured-plugin"
mk_plugin_root "$ORPHAN_UNM_PLUGIN"
mk_baseline "$TMP/orphan-unmeasured-baseline.json" "$ORPHAN_UNM_PLUGIN" '{}' '[]'
render_to "$TMP/orphan-unmeasured.md" "$FIX/corpus-families.json" "$TMP/orphan-unmeasured-baseline.json"
RP34_CTRL_OUT="$(check_with "$TMP/orphan-unmeasured-baseline.json" "$TMP/orphan-unmeasured.md" "$ORPHAN_UNM_PLUGIN")"
RP34_CTRL_RC=$?
add_orphan_unmeasured "$TMP/orphan-unmeasured-baseline.json"
RP34_OUT="$(check_with "$TMP/orphan-unmeasured-baseline.json" "$TMP/orphan-unmeasured.md" "$ORPHAN_UNM_PLUGIN")"
RP34_RC=$?
RP34_FAILS=''
[ "$RP34_CTRL_RC" -eq 0 ] || \
  RP34_FAILS="pristine baseline already reds: rc=$RP34_CTRL_RC $RP34_CTRL_OUT"
if [ "$RP34_RC" -ne 1 ] || ! grep -qF 'agents/retired-lens.md' <<<"$RP34_OUT"; then
  RP34_FAILS="${RP34_FAILS}${RP34_FAILS:+; }orphaned unmeasured key not caught: rc=$RP34_RC $RP34_OUT"
fi
if [ -z "$RP34_FAILS" ]; then
  ok "RP34 an unmeasured digest recorded for a path that is no longer a surface reds — both maps are compared in both directions"
else
  no "RP34 an unmeasured digest recorded for a non-surface reds" "$RP34_FAILS"
fi

# RP35 — schema, all three arms. A malformed field is an INPUT error (rc=2), not
# a check failure (rc=1): the difference is "your baseline is unreadable" versus
# "your tree drifted", and collapsing them would send the reader hunting a drift
# that does not exist. Sub-case (c) is the anti-regression half — every legacy
# baseline predates this key.
drop_unmeasured_key() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
record.pop("unmeasured_digests", None)
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PYEOF
}
SCHEMA_PLUGIN="$TMP/schema-plugin"
mk_plugin_root "$SCHEMA_PLUGIN"
RP35_FAILS=''

mk_baseline "$TMP/schema-list-baseline.json" "$SCHEMA_PLUGIN" '{}' '[]' '[]'
render_to "$TMP/schema-list.md" "$FIX/corpus-families.json" "$TMP/schema-list-baseline.json"
RP35A_OUT="$(check_with "$TMP/schema-list-baseline.json" "$TMP/schema-list.md" "$SCHEMA_PLUGIN")"
RP35A_RC=$?
if [ "$RP35A_RC" -ne 2 ] || ! grep -qF 'unmeasured_digests' <<<"$RP35A_OUT"; then
  RP35_FAILS="(a) a list-valued unmeasured_digests did not raise InputError naming the field: rc=$RP35A_RC $RP35A_OUT"
fi

mk_baseline "$TMP/schema-int-baseline.json" "$SCHEMA_PLUGIN" '{}' '[]' \
  '{"agents/comment-analyzer.md":123}'
render_to "$TMP/schema-int.md" "$FIX/corpus-families.json" "$TMP/schema-int-baseline.json"
RP35B_OUT="$(check_with "$TMP/schema-int-baseline.json" "$TMP/schema-int.md" "$SCHEMA_PLUGIN")"
RP35B_RC=$?
if [ "$RP35B_RC" -ne 2 ] || ! grep -qF 'unmeasured_digests' <<<"$RP35B_OUT"; then
  RP35_FAILS="${RP35_FAILS}${RP35_FAILS:+; }(b) a non-string digest value did not raise InputError naming the field: rc=$RP35B_RC $RP35B_OUT"
fi

mk_baseline "$TMP/schema-absent-baseline.json" "$SCHEMA_PLUGIN" '{}' '[]'
render_to "$TMP/schema-absent.md" "$FIX/corpus-families.json" "$TMP/schema-absent-baseline.json"
drop_unmeasured_key "$TMP/schema-absent-baseline.json"
RP35C_OUT="$(check_with "$TMP/schema-absent-baseline.json" "$TMP/schema-absent.md" "$SCHEMA_PLUGIN")"
RP35C_RC=$?
if [ "$RP35C_RC" -ne 0 ]; then
  RP35_FAILS="${RP35_FAILS}${RP35_FAILS:+; }(c) a legacy baseline with the key absent and no declared-unmeasured surface did not pass: rc=$RP35C_RC $RP35C_OUT"
fi

if [ -z "$RP35_FAILS" ]; then
  ok "RP35 unmeasured_digests is schema-validated — a list or a non-string value is rc=2, and an absent key stays backward compatible"
else
  no "RP35 unmeasured_digests is schema-validated" "$RP35_FAILS"
fi

# RP36 — the WRITER and the READER must describe the same shape. `--refresh` is
# the only mode that writes a baseline and it is unrunnable here (it mines live
# GitHub), but the seam that decides the emitted shape is a pure function, so it
# is driven in-process instead. Without this row the two halves could diverge
# silently: a --refresh months from now would write a baseline whose shape the
# checker no longer fully describes, and nobody would find out until the next
# declared-unmeasured surface appeared.
seed_probe() { # seed_probe <corpus> <plugin_root>
  "$PY" - "$MINER" "$1" "$2" <<'PYEOF'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("review_precision", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
corpus = json.load(open(sys.argv[2], encoding="utf-8"))
root = pathlib.Path(sys.argv[3])
seeded = module.seed_baseline(corpus, root, module.parse_iso8601("2026-08-10T00:00:00Z"))
problems = []
if "unmeasured_digests" not in seeded:
    problems.append("seed_baseline() emits no `unmeasured_digests` key")
elif seeded["unmeasured_digests"] != {}:
    problems.append(f"seed_baseline()'s unmeasured_digests is not empty: {seeded['unmeasured_digests']!r}")
residual = module.check_prompt_digests(seeded, root)
if residual:
    problems.append("a freshly seeded baseline does not pass check_prompt_digests: " + "; ".join(residual))
print("SEED-OK" if not problems else "SEED-FAIL " + " | ".join(problems))
sys.exit(0 if not problems else 1)
PYEOF
}
SEED_PLUGIN="$TMP/seed-plugin"
mk_plugin_root "$SEED_PLUGIN"
RP36_OUT="$(seed_probe "$FIX/corpus-families.json" "$SEED_PLUGIN" 2>&1)"; RP36_RC=$?
if [ "$RP36_RC" -eq 0 ]; then
  ok "RP36 the baseline a --refresh writes is one --check accepts — seed_baseline() emits an empty unmeasured_digests"
else
  no "RP36 the baseline a --refresh writes is one --check accepts" "rc=$RP36_RC" "$RP36_OUT"
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
