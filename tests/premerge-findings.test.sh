#!/usr/bin/env bash
# tests/premerge-findings.test.sh — BEHAVIOUR gates for lib/premerge-findings.py
# (RFC 0021). Unix-only: it executes python3 against tempdirs.
#
# This file exists because tests/premerge.test.sh can only prove that the
# constants and verb names are SPELLED right. The properties that actually
# matter here — that a category overrules a contradicting controller severity,
# that fix waves group by file rather than by finding, that every gate fails
# closed — are only observable by running the module. A grep asserting
# "severity_contradicts_category appears in the source" passes just as happily
# over a branch that can never be reached.

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/plugins/uberdev/lib/premerge-findings.py"

[ -r "$LIB" ] || { echo "FATAL: required file missing or unreadable: $LIB" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required by ${0##*/}" >&2; exit 2; }

WORK="$(mktemp -d)"

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

RUN_ID="20260821-140000-abc123"

# write_input DIR JSON_FINDINGS -> DIR/in.json
write_input() {
  local dir="$1" findings="$2"
  python3 -I -B -c '
import json, sys
dir_, findings, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {"schema_version": 1, "level": "xhigh", "pr_number": 670,
       "run_id": run_id, "findings": json.loads(findings)}
with open(dir_ + "/in.json", "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
' "$dir" "$findings" "$RUN_ID"
}

# plan DIR -> runs the verb, leaves stdout in DIR/out.txt, returns its exit code
plan() {
  local dir="$1"
  python3 -I -B "$LIB" plan --input "$dir/in.json" --out-dir "$dir" \
    >"$dir/out.txt" 2>"$dir/err.txt"
}

new_case() { local d; d="$(mktemp -d "$WORK/case.XXXXXX")"; printf '%s' "$d"; }

# --------------------------------------------------------------------------
echo "== B1: plan happy path — the three severity provenances =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":10,"summary":"null deref","failure_scenario":"empty input crashes","category":"correctness","severity":"blocker"},
  {"file":"lib/b.sh","line":20,"summary":"dup helper","failure_scenario":"two copies drift","category":"reuse","severity":"suggestion"},
  {"file":"lib/c.sh","line":30,"summary":"off by one","failure_scenario":"last row skipped","severity":"blocker"}
]'
if plan "$D"; then ok "B1: plan exits 0 on a well-formed document"; else bad "B1: plan rejected a valid document: $(cat "$D/err.txt")"; fi

GOT="$(cat "$D/out.txt")"
case "$GOT" in
  "PREMERGE_TRIAGE TOTAL=3 BLOCKER=2 SUGGESTION=1 WAVES=1 CATEGORY_BACKED=2"*)
    ok "B1: the triage line reports the split and the category-backed count" ;;
  *) bad "B1: unexpected triage line: $GOT" ;;
esac

for artifact in classified.json fix-waves.json suggestions-aggregate.md; do
  if [ -s "$D/$artifact" ]; then ok "B1: wrote $artifact"; else bad "B1: missing $artifact"; fi
done

# The controller-judged finding must be marked as such, and the two
# category-carrying ones must not be. This is the field an operator reads to
# know how much of a run rested on judgement.
SRC="$(python3 -I -B -c '
import json, sys
d = json.load(open(sys.argv[1] + "/classified.json"))
rows = d["blockers"] + d["suggestions"]
print(",".join(sorted("%s=%s" % (r["file"], r["severity_source"]) for r in rows)))
' "$D")"
if [ "$SRC" = "lib/a.sh=category,lib/b.sh=category,lib/c.sh=controller" ]; then
  ok "B1: severity_source records which rows were machine-checked"
else
  bad "B1: severity_source wrong: $SRC"
fi

# --------------------------------------------------------------------------
echo "== B2: the anti-drift gate — category overrules the controller =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"dup helper","failure_scenario":"drift","category":"reuse","severity":"blocker"}
]'
if plan "$D"; then
  bad "B2: a blocker on a cleanup category was accepted"
else
  RC=$?
  if [ "$RC" -eq 74 ] && grep -q 'severity_contradicts_category' "$D/err.txt"; then
    ok "B2: contradicting severity refused with the stable token"
  else
    bad "B2: wrong refusal (rc=$RC): $(cat "$D/err.txt")"
  fi
fi

D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"crash","failure_scenario":"boom","category":"correctness","severity":"suggestion"}
]'
if plan "$D"; then
  bad "B2: a suggestion on a correctness category was accepted"
else
  ok "B2: the gate refuses in BOTH directions, not just the loud one"
fi

# --------------------------------------------------------------------------
echo "== B3: an unknown category resolves to blocker, not suggestion =="
# The asymmetry is deliberate: a novel cleanup slug costs one needless fixer
# dispatch, a novel correctness slug silently demoted ships the bug.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"x","failure_scenario":"y","category":"thermodynamics","severity":"blocker"}
]'
if plan "$D"; then ok "B3: unknown category accepts blocker"; else bad "B3: unknown category rejected blocker: $(cat "$D/err.txt")"; fi

D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"x","failure_scenario":"y","category":"thermodynamics","severity":"suggestion"}
]'
if plan "$D"; then bad "B3: unknown category accepted suggestion"; else ok "B3: unknown category refuses suggestion"; fi

# --------------------------------------------------------------------------
echo "== B4: input validation refuses rather than degrades =="
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"x","failure_scenario":"y"}]'
if plan "$D"; then bad "B4: accepted a finding with no severity"; else
  grep -q 'severity_missing' "$D/err.txt" && ok "B4: missing severity refused" || bad "B4: wrong token for missing severity"
fi

D="$(new_case)"
write_input "$D" '[{"file":"../etc/passwd","line":1,"summary":"x","failure_scenario":"y","severity":"blocker"}]'
if plan "$D"; then bad "B4: accepted a path escaping the repo"; else ok "B4: traversal path refused"; fi

D="$(new_case)"
write_input "$D" '[{"file":"/abs/path","line":1,"summary":"x","failure_scenario":"y","severity":"blocker"}]'
if plan "$D"; then bad "B4: accepted an absolute path"; else ok "B4: absolute path refused"; fi

D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":7,"summary":"x","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/a.sh","line":7,"summary":"z","failure_scenario":"w","severity":"blocker"}
]'
if plan "$D"; then bad "B4: accepted two findings at one (file,line)"; else
  grep -q 'findings_not_unique' "$D/err.txt" && ok "B4: duplicate location refused" || bad "B4: wrong token for duplicate location"
fi

D="$(new_case)"
printf 'not json at all' >"$D/in.json"
if plan "$D"; then bad "B4: accepted non-JSON input"; else
  grep -q 'input_not_json' "$D/err.txt" && ok "B4: non-JSON refused" || bad "B4: wrong token for non-JSON"
fi

D="$(new_case)"
if plan "$D"; then bad "B4: accepted a missing input file"; else
  grep -q 'input_unreadable' "$D/err.txt" && ok "B4: missing input refused" || bad "B4: wrong token for missing input"
fi

# --------------------------------------------------------------------------
echo "== B5: an empty findings array is a CLEAN run, not an error =="
D="$(new_case)"
write_input "$D" '[]'
if plan "$D"; then
  GOT="$(cat "$D/out.txt")"
  case "$GOT" in
    "PREMERGE_TRIAGE TOTAL=0 BLOCKER=0 SUGGESTION=0 WAVES=0 CATEGORY_BACKED=0"*)
      ok "B5: zero findings reports zero, and still writes every artifact" ;;
    *) bad "B5: unexpected line for the empty case: $GOT" ;;
  esac
  [ -s "$D/suggestions-aggregate.md" ] && ok "B5: the empty envelope is still published" \
    || bad "B5: no envelope written for the empty case"
else
  bad "B5: an empty findings array was treated as an error: $(cat "$D/err.txt")"
fi

# --------------------------------------------------------------------------
echo "== B6: fix waves group by FILE, never by finding =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"one","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/a.sh","line":2,"summary":"two","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/a.sh","line":3,"summary":"three","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/b.sh","line":1,"summary":"four","failure_scenario":"y","severity":"blocker"}
]'
plan "$D" || bad "B6: plan failed: $(cat "$D/err.txt")"
SHAPE="$(python3 -I -B -c '
import json, sys
d = json.load(open(sys.argv[1] + "/fix-waves.json"))
waves = d["waves"]
print("waves=%d agents=%s files=%s" % (
    len(waves),
    ",".join(str(len(w)) for w in waves),
    ",".join(sorted(e["file"] for w in waves for e in w))))
' "$D")"
if [ "$SHAPE" = "waves=1 agents=2 files=lib/a.sh,lib/b.sh" ]; then
  ok "B6: 4 findings over 2 files plan 2 agents, not 4"
else
  bad "B6: wave shape wrong: $SHAPE"
fi

# Disjointness is the property that makes it safe to run a wave concurrently
# against one worktree with no isolation. Assert it rather than trusting it.
DISJOINT="$(python3 -I -B -c '
import json, sys
d = json.load(open(sys.argv[1] + "/fix-waves.json"))
for wave in d["waves"]:
    files = [e["file"] for e in wave]
    if len(files) != len(set(files)):
        print("OVERLAP"); raise SystemExit(0)
print("DISJOINT")
' "$D")"
[ "$DISJOINT" = "DISJOINT" ] && ok "B6: files within a wave are pairwise disjoint" || bad "B6: $DISJOINT"

echo "== B6b: --max-per-wave bounds the wave, and is validated =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"a","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/b.sh","line":1,"summary":"b","failure_scenario":"y","severity":"blocker"},
  {"file":"lib/c.sh","line":1,"summary":"c","failure_scenario":"y","severity":"blocker"}
]'
python3 -I -B "$LIB" plan --input "$D/in.json" --out-dir "$D" --max-per-wave 2 \
  >"$D/out.txt" 2>"$D/err.txt" || bad "B6b: plan failed: $(cat "$D/err.txt")"
grep -q 'WAVES=2' "$D/out.txt" && ok "B6b: 3 files at 2 per wave plan 2 waves" || bad "B6b: $(cat "$D/out.txt")"

if python3 -I -B "$LIB" plan --input "$D/in.json" --out-dir "$D" --max-per-wave 0 \
     >/dev/null 2>"$D/err0.txt"; then
  bad "B6b: accepted --max-per-wave 0"
else
  grep -q 'bad_wave_size' "$D/err0.txt" && ok "B6b: a zero wave size is refused" || bad "B6b: wrong token for wave size 0"
fi

# --------------------------------------------------------------------------
echo "== B7: the deferred-findings envelope =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/b.sh","line":20,"summary":"dup helper","failure_scenario":"two copies drift","category":"reuse","severity":"suggestion"}
]'
plan "$D" || bad "B7: plan failed: $(cat "$D/err.txt")"
AGG="$D/suggestions-aggregate.md"
head -1 "$AGG" | grep -qF '<external-untrusted-input source="premerge-aggregate">' \
  && ok "B7: opens with the premerge-aggregate envelope tag" || bad "B7: wrong opening tag"
tail -1 "$AGG" | grep -qF '</external-untrusted-input>' \
  && ok "B7: closes the envelope" || bad "B7: missing closing tag"
LINES="$(wc -l <"$AGG" | tr -d ' ')"
[ "$LINES" = "3" ] && ok "B7: envelope is exactly open/body/close" || bad "B7: envelope has $LINES lines, want 3"

BODY="$(sed -n '2p' "$AGG")"
# Canonical means compact + sorted keys: re-encoding must be byte-identical, or
# a downstream reader that re-canonicalises would compute a different digest.
python3 -I -B -c '
import json, sys
body = sys.argv[1]
doc = json.loads(body)
assert json.dumps(doc, ensure_ascii=True, sort_keys=True, separators=(",", ":")) == body, "not canonical"
assert doc["phase"] == "premerge", doc["phase"]
assert doc["schema_version"] == 2, doc["schema_version"]
assert doc["findings"][0]["severity"] == "suggestion"
assert doc["findings"][0]["source_edges"] == ["premerge.review.code_review"]
assert doc["findings"][0]["scope"] == {"line": 20, "operation": "modify_existing", "path": "lib/b.sh"}
' "$BODY" 2>"$D/agg.err" && ok "B7: body is canonical JSON with the declared row shape" \
  || bad "B7: $(cat "$D/agg.err")"

# Blockers are FIXED, not filed — they must never reach the issue envelope.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"crash","failure_scenario":"boom","category":"correctness","severity":"blocker"}
]'
plan "$D" || bad "B7: plan failed: $(cat "$D/err.txt")"
COUNT="$(sed -n '2p' "$D/suggestions-aggregate.md" | python3 -I -B -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))')"
[ "$COUNT" = "0" ] && ok "B7: blockers are absent from the issue envelope" || bad "B7: $COUNT blockers leaked into the envelope"

# --------------------------------------------------------------------------
echo "== B8: assert-green =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/b.sh","line":20,"summary":"dup","failure_scenario":"drift","category":"reuse","severity":"suggestion"}
]'
plan "$D" || bad "B8: plan failed: $(cat "$D/err.txt")"
CLEAN="$D/classified.json"

gate() { python3 -I -B "$LIB" assert-green --classified "$CLEAN" "$@" >"$D/gate.txt" 2>"$D/gate.err"; }

gate --ci-state green --mergeable MERGEABLE --require-ci \
  && grep -q 'VERDICT=green' "$D/gate.txt" && ok "B8: clean + green + mergeable passes" || bad "B8: clean case did not pass"

gate --ci-state no_checks --mergeable MERGEABLE --require-ci \
  && ok "B8: a repo with no checks is not treated as red" || bad "B8: no_checks failed the gate"

if gate --ci-state red --mergeable MERGEABLE --require-ci; then
  bad "B8: red CI passed the gate"
else
  grep -q 'REASONS=ci=red' "$D/gate.txt" && ok "B8: red CI fails and names itself" || bad "B8: red CI reason wrong: $(cat "$D/gate.txt")"
fi

gate --ci-state red --mergeable MERGEABLE \
  && ok "B8: without --require-ci, CI is not a term" || bad "B8: CI gated despite --require-ci being absent"

if gate --ci-state green --mergeable CONFLICTING --require-ci; then
  bad "B8: a conflicting PR passed the gate"
else
  grep -q 'mergeable=CONFLICTING' "$D/gate.txt" && ok "B8: conflicting fails and names itself" || bad "B8: conflict reason wrong"
fi

if gate --ci-state pending --mergeable MERGEABLE --require-ci; then
  bad "B8: pending CI passed the gate"
else
  ok "B8: pending CI is not a pass"
fi

# Blockers remaining.
DB="$(new_case)"
write_input "$DB" '[{"file":"lib/a.sh","line":1,"summary":"crash","failure_scenario":"boom","severity":"blocker"}]'
plan "$DB" || bad "B8: plan failed: $(cat "$DB/err.txt")"
if python3 -I -B "$LIB" assert-green --classified "$DB/classified.json" \
     --ci-state green --mergeable MERGEABLE --require-ci >"$DB/gate.txt" 2>&1; then
  bad "B8: a surviving blocker passed the gate"
else
  grep -q 'blockers_remaining=1' "$DB/gate.txt" && ok "B8: a surviving blocker fails and is counted" || bad "B8: blocker reason wrong: $(cat "$DB/gate.txt")"
fi

echo "== B8b: the gate fails CLOSED on unreadable evidence =="
if python3 -I -B "$LIB" assert-green --classified "$D/nonexistent.json" \
     --ci-state green --mergeable MERGEABLE --require-ci >/dev/null 2>"$D/gc.err"; then
  bad "B8b: a missing classified.json returned green"
else
  RC=$?
  [ "$RC" -ne 0 ] && ok "B8b: unreadable evidence is never green (rc=$RC)" || bad "B8b: rc=0 on missing evidence"
fi

printf 'null' >"$D/garbage.json"
if python3 -I -B "$LIB" assert-green --classified "$D/garbage.json" \
     --ci-state green --mergeable MERGEABLE --require-ci >/dev/null 2>&1; then
  bad "B8b: a malformed classified.json returned green"
else
  ok "B8b: malformed evidence is never green"
fi

if python3 -I -B "$LIB" assert-green --classified "$CLEAN" \
     --ci-state banana --mergeable MERGEABLE >/dev/null 2>"$D/bad.err"; then
  bad "B8b: an unrecognised ci-state was accepted"
else
  grep -q 'bad_ci_state' "$D/bad.err" && ok "B8b: an unrecognised ci-state is refused, not defaulted" || bad "B8b: wrong token for bad ci-state"
fi

# --------------------------------------------------------------------------
rm -rf "$WORK"

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
