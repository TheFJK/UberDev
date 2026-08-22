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
# The convergence loop (RFC 0021 Amendment A1).
#
# Everything below EXECUTES the module. The loop's whole safety argument rests
# on two predicates — "did this attempt change anything" and "is this the same
# blocker I already tried to fix" — and a grep proving the words STOP_NO_PROGRESS
# appear in the source passes just as happily over a branch that can never fire.
# --------------------------------------------------------------------------

# plan_at DIR ATTEMPT SHA [--carry-prior] -> runs plan with loop arguments
plan_at() {
  local dir="$1" attempt="$2" sha="$3"
  shift 3
  python3 -I -B "$LIB" plan --input "$dir/in.json" --out-dir "$dir" \
    --attempt "$attempt" --head-sha "$sha" "$@" \
    >"$dir/out.txt" 2>"$dir/err.txt"
}

# fp_of DIR ATTEMPT FILE -> the recorded fingerprint of that file's blocker
fp_of() {
  python3 -I -B -c '
import json, sys
doc = json.load(open("%s/classified-%02d.json" % (sys.argv[1], int(sys.argv[2]))))
for row in doc["blockers"] + doc["suggestions"]:
    if row["file"] == sys.argv[3]:
        print(row["fingerprint"]); break
' "$1" "$2" "$3"
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="cccccccccccccccccccccccccccccccccccccccc"

echo "== B9: the fingerprint is an identity that survives the loop's own edits =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":10,"summary":"the guard reads `status` after a pipe.","failure_scenario":"wrong exit code","severity":"blocker"},
  {"file":"lib/b.sh","line":20,"summary":"wave size is unbounded","failure_scenario":"64 agents at once","severity":"blocker"}
]'
plan_at "$D" 1 "$SHA_A" || bad "B9: plan attempt 1 failed: $(cat "$D/err.txt")"
FP_A1="$(fp_of "$D" 1 lib/a.sh)"

# The SAME finding after a fix moved it 83 lines and the reviewer re-worded the
# punctuation, the case and the backticks. This is the single most important
# property in the file: if it fails, every survivor reads as brand new, the loop
# sees infinite progress and STOP_NO_PROGRESS can never fire.
write_input "$D" '[
  {"file":"lib/a.sh","line":93,"summary":"The guard reads status after a pipe","failure_scenario":"wrong exit code","severity":"blocker"},
  {"file":"lib/b.sh","line":20,"summary":"wave size is unbounded","failure_scenario":"64 agents at once","severity":"blocker"}
]'
plan_at "$D" 2 "$SHA_B" || bad "B9: plan attempt 2 failed: $(cat "$D/err.txt")"
FP_A2="$(fp_of "$D" 2 lib/a.sh)"
if [ -n "$FP_A1" ] && [ "$FP_A1" = "$FP_A2" ]; then
  ok "B9: a moved, re-punctuated, re-cased finding keeps its identity"
else
  bad "B9: identity did not survive a line move (attempt1=$FP_A1 attempt2=$FP_A2)"
fi

case "$FP_A1" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ok "B9: the fingerprint is 16 lowercase hex characters" ;;
  *) bad "B9: fingerprint is not 16 lowercase hex: $FP_A1" ;;
esac

FP_B1="$(fp_of "$D" 1 lib/b.sh)"
if [ "$FP_A1" != "$FP_B1" ]; then
  ok "B9: two different findings do not collide"
else
  bad "B9: two different findings share a fingerprint"
fi

# Anti-substitution. agents/findings-to-issues.md Step 8a hashes
# file:line:normalised_summary because an ISSUE is about a location; this one
# must survive exactly the line movement that one is keyed on. A future reader
# who "unifies" them silently breaks whichever caller loses.
F2I_FP="$(python3 -I -B -c '
import hashlib
print(hashlib.sha256(b"lib/a.sh:10:the guard reads status after a pipe").hexdigest()[:16])
')"
if [ "$FP_A1" != "$F2I_FP" ]; then
  ok "B9: the loop fingerprint is NOT the findings-to-issues fingerprint"
else
  bad "B9: the two fingerprint schemes collided — one of them is now wrong"
fi

echo "== B10: per-attempt evidence is preserved, and the current pointer survives =="
if [ -s "$D/classified-01.json" ] && [ -s "$D/classified-02.json" ]; then
  ok "B10: each attempt keeps its own evidence"
else
  bad "B10: per-attempt evidence missing"
fi
if cmp -s "$D/classified.json" "$D/classified-02.json"; then
  ok "B10: the unsuffixed pointer holds the latest attempt"
else
  bad "B10: classified.json is not the latest attempt"
fi
if [ -s "$D/fix-waves-01.json" ] && [ -s "$D/fix-waves-02.json" ]; then
  ok "B10: fix waves are recorded per attempt too"
else
  bad "B10: per-attempt fix waves missing"
fi
STAMP="$(python3 -I -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print("%s %s" % (doc.get("attempt"), doc.get("head_sha")))
' "$D/classified-02.json")"
if [ "$STAMP" = "2 $SHA_B" ]; then
  ok "B10: the attempt index and reviewed head_sha are stamped into the evidence"
else
  bad "B10: evidence is not stamped (got '$STAMP')"
fi

echo "== B11: --carry-prior unions suggestions and never blockers =="
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"dup helper","failure_scenario":"two copies drift","category":"reuse","severity":"suggestion"},
  {"file":"lib/z.sh","line":9,"summary":"null deref","failure_scenario":"crash","severity":"blocker"}
]'
plan_at "$D" 1 "$SHA_A" || bad "B11: attempt 1 failed"
write_input "$D" '[
  {"file":"lib/b.sh","line":2,"summary":"dead branch","failure_scenario":"unreachable","category":"simplification","severity":"suggestion"}
]'
plan_at "$D" 2 "$SHA_B" --carry-prior || bad "B11: attempt 2 failed: $(cat "$D/err.txt")"
UNION="$(python3 -I -B -c '
import json, sys
line = open(sys.argv[1], encoding="utf-8").read().splitlines()[1]
doc = json.loads(line)
paths = sorted(f["scope"]["path"] for f in doc["findings"])
print(",".join(paths))
' "$D/suggestions-aggregate.md")"
if [ "$UNION" = "lib/a.sh,lib/b.sh" ]; then
  ok "B11: a suggestion raised only on an earlier attempt is still filed"
else
  bad "B11: the aggregate lost a carried suggestion (got '$UNION')"
fi
case "$UNION" in
  *lib/z.sh*) bad "B11: a blocker leaked into the issue aggregate" ;;
  *) ok "B11: blockers are still absent from the issue aggregate" ;;
esac
CARRIED="$(sed -n 's/.*CARRIED=\([0-9]*\).*/\1/p' "$D/out.txt")"
if [ "$CARRIED" = "1" ]; then
  ok "B11: the triage line reports how many suggestions were carried"
else
  bad "B11: CARRIED not reported (got '$CARRIED')"
fi

echo "== B12: the converge decision table =="
# decide DIR ATTEMPT MAX_REPAIRS VERDICT REASONS [WAIT] -> prints "<DECISION> <rc>"
#
# Both halves on one line on purpose: a command substitution runs in a subshell,
# so an rc stashed in a variable inside this function never reaches the caller.
# The exit status is half of what is being tested here — STOP_GREEN exits 1 — so
# losing it silently would leave every rc assertion below vacuous.
decide() {
  local dir="$1" attempt="$2" maxa="$3" verdict="$4" reasons="$5" wait_passes="${6:-0}"
  local line rc
  line="$(python3 -I -B "$LIB" converge --run-dir "$dir" --attempt "$attempt" \
    --max-repairs "$maxa" --verdict "$verdict" --reasons "$reasons" \
    --wait-passes "$wait_passes" 2>"$dir/conv.err")"
  rc=$?
  printf '%s %s' "$(printf '%s' "$line" | sed -n 's/.*DECISION=\([A-Z_]*\).*/\1/p')" "$rc"
}

expect_decision() {
  local result="$1" want="$2" want_rc="$3" what="$4"
  local got="${result%% *}" got_rc="${result##* }"
  if [ "$got" = "$want" ] && [ "$got_rc" = "$want_rc" ]; then
    ok "B12: $what -> $want (rc=$want_rc)"
  else
    bad "B12: $what -> got '$got' rc=$got_rc, wanted $want rc=$want_rc"
  fi
}

D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"},
                   {"file":"lib/b.sh","line":2,"summary":"beta","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup attempt 1 failed"
GOT="$(decide "$D" 1 3 not_green 'blockers_remaining=2')"
expect_decision "$GOT" CONTINUE 0 "two blockers on the first attempt"

# One fixed: strictly shrinking, so the loop keeps going even though the same
# named file is still failing.
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 2 "$SHA_B" || bad "B12: setup attempt 2 failed"
GOT="$(decide "$D" 2 3 not_green 'blockers_remaining=1')"
expect_decision "$GOT" CONTINUE 0 "one of two blockers fixed"

# Identical evidence twice: the attempt achieved nothing. This is the row that
# replaces RFC 0021's counter-of-one, and it must fire BEFORE the budget runs out.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
decide "$D" 1 6 not_green 'blockers_remaining=1' >/dev/null
plan_at "$D" 2 "$SHA_B" || bad "B12: setup failed"
GOT="$(decide "$D" 2 6 not_green 'blockers_remaining=1')"
expect_decision "$GOT" STOP_NO_PROGRESS 1 "an attempt that changed nothing, with budget to spare"

# Regression: our own fixes grew the set.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
decide "$D" 1 6 not_green 'blockers_remaining=1' >/dev/null
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"},
                   {"file":"lib/c.sh","line":3,"summary":"gamma","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 2 "$SHA_B" || bad "B12: setup failed"
GOT="$(decide "$D" 2 6 not_green 'blockers_remaining=2')"
expect_decision "$GOT" STOP_REGRESSED 1 "fixes that grew the blocker set"

# The backstop counts REPAIRS, not reviews, and this is the row that pins it.
# `--converge=1` must buy ONE repair and the re-review that verifies it — the
# pre-loop behaviour the flag is documented as reproducing. Count reviews instead
# and attempt 1 stops immediately, so the flag buys ZERO repairs: strictly worse
# than the pipeline it claims to reproduce.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
GOT="$(decide "$D" 1 1 not_green 'blockers_remaining=1')"
expect_decision "$GOT" CONTINUE 0 "--converge=1 still buying its one repair"
write_input "$D" '[{"file":"lib/q.sh","line":1,"summary":"quebec","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 2 "$SHA_B" || bad "B12: setup failed"
GOT="$(decide "$D" 2 1 not_green 'blockers_remaining=1')"
expect_decision "$GOT" STOP_EXHAUSTED 1 "--converge=1 stopping after its one repair was re-reviewed"

# And the budget is spent only once we are PAST it: 2 repairs means attempts
# 1 and 2 both repair, and attempt 3 is the verification that ends the run.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
decide "$D" 1 2 not_green 'blockers_remaining=1' >/dev/null
write_input "$D" '[{"file":"lib/q.sh","line":1,"summary":"quebec","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 2 "$SHA_B" || bad "B12: setup failed"
GOT="$(decide "$D" 2 2 not_green 'blockers_remaining=1')"
expect_decision "$GOT" CONTINUE 0 "the second of two repair rounds"
write_input "$D" '[{"file":"lib/r.sh","line":1,"summary":"romeo","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 3 "$SHA_C" || bad "B12: setup failed"
GOT="$(decide "$D" 3 2 not_green 'blockers_remaining=1')"
expect_decision "$GOT" STOP_EXHAUSTED 1 "a still-converging loop that ran out of repair budget"

D="$(new_case)"
write_input "$D" '[]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
GOT="$(decide "$D" 1 3 green none)"
expect_decision "$GOT" STOP_GREEN 1 "the gate passing"
GOT="$(decide "$D" 1 3 not_green 'ci=pending')"
expect_decision "$GOT" WAIT_CI 0 "a build that has not answered yet"
GOT="$(decide "$D" 1 3 not_green 'ci=no_checks_after_push')"
expect_decision "$GOT" WAIT_CI 0 "the settle window right after a push"
GOT="$(decide "$D" 1 3 not_green 'ci=pending' 8)"
expect_decision "$GOT" STOP_UNREADABLE 1 "a build that never settled"
GOT="$(decide "$D" 1 3 not_green 'stale_evidence,ci=red')"
expect_decision "$GOT" STOP_UNREADABLE 1 "evidence about code that has moved"

# WAIT_CI must not consume an attempt, and must not blind the progress detector.
# A tail-only ledger reader breaks exactly here: the WAIT_CI row it just wrote
# carries attempt N, so the lookback for N-1 finds nothing and STOP_NO_PROGRESS
# becomes unreachable for the rest of the run.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B12: setup failed"
decide "$D" 1 6 not_green 'blockers_remaining=1' >/dev/null
plan_at "$D" 2 "$SHA_B" || bad "B12: setup failed"
decide "$D" 2 6 not_green 'ci=pending' 1 >/dev/null
GOT="$(decide "$D" 2 6 not_green 'blockers_remaining=1')"
expect_decision "$GOT" STOP_NO_PROGRESS 1 "a stalled attempt whose ledger also holds a WAIT_CI row"

if [ -s "$D/converge.jsonl" ]; then
  ROWS="$(grep -c . "$D/converge.jsonl")"
  [ "$ROWS" = "3" ] && ok "B12: every decision appends exactly one ledger row" \
    || bad "B12: ledger has $ROWS rows, wanted 3"
else
  bad "B12: no converge.jsonl ledger was written"
fi

echo "== B13: converge fails CLOSED =="
D="$(new_case)"
write_input "$D" '[]'
plan_at "$D" 1 "$SHA_A" || bad "B13: setup failed"

if python3 -I -B "$LIB" converge --run-dir "$D" --attempt 1 --max-repairs 3 \
     --verdict green --reasons 'ci=red' >/dev/null 2>"$D/e1"; then
  bad "B13: a green verdict carrying failing reasons was accepted"
else
  grep -q 'verdict_contradicts_reasons' "$D/e1" \
    && ok "B13: a verdict that contradicts its own reasons is refused" \
    || bad "B13: wrong token for a contradicting verdict: $(cat "$D/e1")"
fi

if python3 -I -B "$LIB" converge --run-dir "$D" --attempt 3 --max-repairs 3 \
     --verdict not_green --reasons none >/dev/null 2>"$D/e2"; then
  bad "B13: an attempt with no evidence on disk was accepted"
else
  grep -q 'attempt_evidence_missing' "$D/e2" \
    && ok "B13: an attempt whose evidence is missing is refused, not treated as empty" \
    || bad "B13: wrong token for missing evidence: $(cat "$D/e2")"
fi

if python3 -I -B "$LIB" converge --run-dir "$D" --attempt 1 --max-repairs 99 \
     --verdict not_green --reasons none >/dev/null 2>"$D/e3"; then
  bad "B13: a repair budget above the ceiling was accepted"
else
  grep -q 'bad_max_repairs' "$D/e3" \
    && ok "B13: a repair budget above the runaway ceiling is refused, not clamped" \
    || bad "B13: wrong token for an out-of-range budget: $(cat "$D/e3")"
fi

# At attempt 2, because that is where the ledger is first READ — attempt 1 has no
# predecessor to compare against and correctly never opens it. The refusal fires
# the moment the corrupt data would be USED, which is the right moment.
plan_at "$D" 2 "$SHA_B" || bad "B13: setup attempt 2 failed"
printf 'not json at all\n' >"$D/converge.jsonl"
if python3 -I -B "$LIB" converge --run-dir "$D" --attempt 2 --max-repairs 3 \
     --verdict not_green --reasons none >/dev/null 2>"$D/e4"; then
  bad "B13: an unparseable ledger was treated as an empty one"
else
  grep -q 'input_not_json' "$D/e4" \
    && ok "B13: an unparseable ledger is refused, not read as 'no history'" \
    || bad "B13: wrong token for a corrupt ledger: $(cat "$D/e4")"
fi

# A blocker with no fingerprint cannot be compared, and "no match" would report a
# survivor as newly fixed. Refuse rather than answer wrongly.
rm -f "$D/converge.jsonl"
python3 -I -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
doc["blockers"] = [{"rank": 1, "file": "lib/a.sh", "line": 1, "summary": "alpha",
                    "failure_scenario": "crash", "category": None, "verdict": None,
                    "severity": "blocker", "severity_source": "controller"}]
json.dump(doc, open(sys.argv[1], "w"))
' "$D/classified-01.json"
if python3 -I -B "$LIB" converge --run-dir "$D" --attempt 1 --max-repairs 3 \
     --verdict not_green --reasons 'blockers_remaining=1' >/dev/null 2>"$D/e5"; then
  bad "B13: a blocker with no fingerprint was silently compared"
else
  grep -q 'fingerprint_missing' "$D/e5" \
    && ok "B13: an unfingerprinted blocker is refused, not counted as unmatched" \
    || bad "B13: wrong token for a missing fingerprint: $(cat "$D/e5")"
fi

echo "== B14: the gate's two new fail-closed terms =="
D="$(new_case)"
write_input "$D" '[]'
plan_at "$D" 1 "$SHA_A" || bad "B14: setup failed"
CLEAN="$D/classified-01.json"

GATE_OUT="$(python3 -I -B "$LIB" assert-green --classified "$CLEAN" --ci-state green \
  --mergeable MERGEABLE --require-ci --head-sha "$SHA_A" 2>&1)"
case "$GATE_OUT" in
  *"VERDICT=green"*) ok "B14: evidence matching the live head passes" ;;
  *) bad "B14: matching head_sha did not pass: $GATE_OUT" ;;
esac

GATE_OUT="$(python3 -I -B "$LIB" assert-green --classified "$CLEAN" --ci-state green \
  --mergeable MERGEABLE --require-ci --head-sha "$SHA_C" 2>&1)"
case "$GATE_OUT" in
  *"VERDICT=not_green"*"stale_evidence"*) ok "B14: evidence about a different SHA is never green" ;;
  *) bad "B14: stale evidence passed the gate: $GATE_OUT" ;;
esac

# An unstamped document under --head-sha is a refusal, not a pass: the whole
# point of the check is that a refused re-plan leaves a stale artifact behind.
python3 -I -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
doc.pop("head_sha", None)
json.dump(doc, open(sys.argv[2], "w"))
' "$CLEAN" "$D/unstamped.json"
if python3 -I -B "$LIB" assert-green --classified "$D/unstamped.json" --ci-state green \
     --mergeable MERGEABLE --require-ci --head-sha "$SHA_A" >/dev/null 2>"$D/e6"; then
  bad "B14: unstamped evidence passed a staleness check it could not perform"
else
  grep -q 'evidence_unstamped' "$D/e6" \
    && ok "B14: evidence with no head_sha is refused when a check is demanded" \
    || bad "B14: wrong token for unstamped evidence: $(cat "$D/e6")"
fi

GATE_OUT="$(python3 -I -B "$LIB" assert-green --classified "$CLEAN" --ci-state no_checks \
  --mergeable MERGEABLE --require-ci --after-push 2>&1)"
case "$GATE_OUT" in
  *"ci=no_checks_after_push"*) ok "B14: 'no checks' right after a push is not green" ;;
  *) bad "B14: the settle-window race still passes: $GATE_OUT" ;;
esac

GATE_OUT="$(python3 -I -B "$LIB" assert-green --classified "$CLEAN" --ci-state no_checks \
  --mergeable MERGEABLE --require-ci 2>&1)"
case "$GATE_OUT" in
  *"VERDICT=green"*) ok "B14: a repo with genuinely no checks is still not treated as red" ;;
  *) bad "B14: --after-push leaked into runs that pushed nothing: $GATE_OUT" ;;
esac

echo "== B15: the SKILL's decision table and the library's closed set agree =="
# EXECUTED, not transcribed. Two copies of a vocabulary that a human keeps in
# step by reading them is a vocabulary that has already drifted; this imports the
# module for one side and greps the shipped prose for the other.
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/SKILL.md"
if [ -r "$SKILL_FILE" ]; then
  DRIFT="$(python3 -I -B -c '
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
declared = set(module.CONVERGE_DECISIONS)
prose = set(re.findall(r"`(CONTINUE|WAIT_CI|STOP_[A-Z_]+)`", open(sys.argv[2], encoding="utf-8").read()))
missing = sorted(declared - prose)
invented = sorted(prose - declared)
print("missing=%s invented=%s" % (",".join(missing) or "-", ",".join(invented) or "-"))
' "$LIB" "$SKILL_FILE")"
  if [ "$DRIFT" = "missing=- invented=-" ]; then
    ok "B15: every declared decision is documented and the SKILL invents none"
  else
    bad "B15: decision vocabulary drift ($DRIFT)"
  fi
  # Anti-vacuity: the grep must actually find something, or a SKILL that stopped
  # mentioning decisions at all would pass the row above by matching nothing.
  FOUND="$(grep -cE '`(CONTINUE|WAIT_CI|STOP_[A-Z_]+)`' "$SKILL_FILE")"
  if [ "$FOUND" -ge 7 ]; then
    ok "B15: the SKILL really does document the decision set (${FOUND} mentions)"
  else
    bad "B15: only $FOUND decision mentions in the SKILL — the drift row above is vacuous"
  fi

  # B15b — the two ceilings. The SKILL restates them for the reader and the
  # library enforces them; the SKILL says outright that being prose does not make
  # them advisory, which is only true while the numbers agree. Same technique:
  # import one side, read the shipped bytes of the other.
  CEIL_DRIFT="$(python3 -I -B -c '
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text = open(sys.argv[2], encoding="utf-8").read()
bad = []
for name, value in (("PREMERGE_REPAIR_CEILING", module.CONVERGE_REPAIR_CEILING),
                    ("PREMERGE_WAIT_CI_CEILING", module.CONVERGE_WAIT_CI_CEILING)):
    found = re.search(r"^%s\s*=\s*(\d+)" % name, text, re.M)
    if found is None:
        bad.append("%s:absent" % name)
    elif int(found.group(1)) != value:
        bad.append("%s:skill=%s lib=%s" % (name, found.group(1), value))
print(";".join(bad) or "agree")
' "$LIB" "$SKILL_FILE")"
  if [ "$CEIL_DRIFT" = "agree" ]; then
    ok "B15b: the SKILL's restated ceilings match the library's enforced ones"
  else
    bad "B15b: ceiling drift ($CEIL_DRIFT)"
  fi

  # The SKILL's refusal message hardcodes the range...
  SKILL_RANGE="$(python3 -I -B -c '
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
skill = open(sys.argv[2], encoding="utf-8").read()
hits = re.findall(r"--converge must be 1\.\.(\d+)", skill)
print("no-refusal" if not hits else ("agree" if all(int(h) == module.CONVERGE_REPAIR_CEILING for h in hits) else "drift:" + ",".join(hits)))
' "$LIB" "$SKILL_FILE")"
  if [ "$SKILL_RANGE" = "agree" ]; then
    ok "B15b: the argument refusal quotes the ceiling the library enforces"
  else
    bad "B15b: the --converge refusal message disagrees with the library ($SKILL_RANGE)"
  fi

  # ...and so does the COMMAND file, in prose, which is what an operator reads
  # before invoking. This row used to be labelled "the command file's own
  # refusal" while passing $SKILL_FILE, so a ceiling raised in the library and
  # documented in the SKILL could leave commands/premerge.md advertising a range
  # three below what the pipeline accepts, undetected.
  CMD_FILE="$REPO_ROOT/plugins/uberdev/commands/premerge.md"
  if [ ! -r "$CMD_FILE" ]; then
    bad "B15b: commands/premerge.md is missing"
  else
    CMD_RANGE="$(python3 -I -B -c '
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text = open(sys.argv[2], encoding="utf-8").read()
ceiling = module.CONVERGE_REPAIR_CEILING
words = {1:"one",2:"two",3:"three",4:"four",5:"five",6:"six",7:"seven",8:"eight",9:"nine"}
hits = re.findall(r"`1` to `(\d+)`", text)
wordy = re.findall(r"ceiling of ([a-z]+)", text)
if not hits and not wordy:
    print("no-claim")
else:
    bad = [h for h in hits if int(h) != ceiling]
    bad += [w for w in wordy if w != words.get(ceiling)]
    print("agree" if not bad else "drift:" + ",".join(bad))
' "$LIB" "$CMD_FILE")"
    case "$CMD_RANGE" in
      agree)    ok "B15b: commands/premerge.md documents the ceiling the library enforces" ;;
      no-claim) bad "B15b: commands/premerge.md states no --converge range — this row is vacuous" ;;
      *)        bad "B15b: commands/premerge.md ceiling drift ($CMD_RANGE)" ;;
    esac
  fi
else
  bad "B15: the pipeline SKILL.md is missing"
fi

echo "== B19: the three failure modes an executing review found =="
# B19a — REGRESSION must mean "new blockers and we cleared none", not "the count
# went up". The built-in reviewer's output is capped and ranked most-severe-first,
# so clearing the top blockers routinely surfaces ones the cap had cut. A raw
# count test stops a loop that just succeeded and tells the operator the machine
# broke the stack at the moment it removed a blocker.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/b.sh","line":2,"summary":"beta","failure_scenario":"crash","severity":"blocker"}
]'
plan_at "$D" 1 "$SHA_A" || bad "B19a: setup failed"
decide "$D" 1 3 not_green 'blockers_remaining=2' >/dev/null
write_input "$D" '[
  {"file":"lib/b.sh","line":2,"summary":"beta","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/c.sh","line":3,"summary":"gamma","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/d.sh","line":4,"summary":"delta","failure_scenario":"crash","severity":"blocker"}
]'
plan_at "$D" 2 "$SHA_B" || bad "B19a: setup failed"
B19_RES="$(decide "$D" 2 3 not_green 'blockers_remaining=3')"
expect_decision "$B19_RES" CONTINUE 0 "cap churn: one fixed, two surfaced"

# The honest regression still stops: nothing fixed, something new appeared.
D="$(new_case)"
write_input "$D" '[{"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"}]'
plan_at "$D" 1 "$SHA_A" || bad "B19a: setup failed"
decide "$D" 1 3 not_green 'blockers_remaining=1' >/dev/null
write_input "$D" '[
  {"file":"lib/a.sh","line":1,"summary":"alpha","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/e.sh","line":9,"summary":"epsilon","failure_scenario":"crash","severity":"blocker"}
]'
plan_at "$D" 2 "$SHA_B" || bad "B19a: setup failed"
B19_RES="$(decide "$D" 2 3 not_green 'blockers_remaining=2')"
expect_decision "$B19_RES" STOP_REGRESSED 1 "a true regression: nothing fixed, something new broke"

# B19b — a FAILED mergeable probe must not read as a clean stack. The fence maps
# a failed `gh pr view` onto UNKNOWN, so accepting UNKNOWN made an outage
# indistinguishable from a mergeable branch — the one unreadable-evidence state
# the gate used to answer green on.
D="$(new_case)"
write_input "$D" '[]'
plan_at "$D" 1 "$SHA_A" || bad "B19b: setup failed"
B19_OUT="$(python3 -I -B "$LIB" assert-green --classified "$D/classified-01.json" \
  --ci-state green --mergeable UNKNOWN --require-ci --head-sha "$SHA_A" 2>&1)"
case "$B19_OUT" in
  *"VERDICT=not_green"*"mergeable=unknown"*)
    ok "B19b: an unreadable mergeable state is never green" ;;
  *) bad "B19b: mergeable=UNKNOWN passed the gate: $B19_OUT" ;;
esac
B19_RES="$(decide "$D" 1 3 not_green 'mergeable=unknown')"
expect_decision "$B19_RES" WAIT_CI 0 "an unreadable mergeable state re-probing rather than failing"

# B19c — two line-less findings in one file are two findings. `line` is optional
# in both reviewer contracts, and under the loop one refusal is unrecoverable:
# plan exits before writing, the gate reads a missing artifact, and converge
# aborts on attempt_evidence_missing. The whole run would die because the
# reviewer omitted a line number.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","summary":"first problem","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/a.sh","summary":"a different problem","failure_scenario":"hang","severity":"blocker"}
]'
if plan_at "$D" 1 "$SHA_A"; then
  ok "B19c: two distinct line-less findings in one file are accepted"
else
  bad "B19c: line-less findings still abort the run: $(cat "$D/err.txt")"
fi
# ...but a genuine duplicate still collides.
write_input "$D" '[
  {"file":"lib/a.sh","summary":"first problem","failure_scenario":"crash","severity":"blocker"},
  {"file":"lib/a.sh","summary":"first problem","failure_scenario":"crash","severity":"blocker"}
]'
if plan_at "$D" 2 "$SHA_B"; then
  bad "B19c: a genuine duplicate was accepted"
else
  grep -q 'findings_not_unique' "$D/err.txt" \
    && ok "B19c: a genuine duplicate is still refused" \
    || bad "B19c: wrong token: $(cat "$D/err.txt")"
fi

echo "== B16: the defer verb — the producer that did not exist =="
# Two /premerge promises had no writer behind them: un-applied lens findings, and
# blockers the loop stopped on. Both failed SILENTLY, which is why a row that
# executes the encoder matters more here than one that greps for the promise.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":10,"summary":"null deref","failure_scenario":"crash on empty","severity":"blocker"},
  {"file":"lib/b.sh","line":20,"summary":"dup helper","failure_scenario":"two copies drift","category":"reuse","severity":"suggestion"}
]'
plan_at "$D" 1 "$SHA_A" || bad "B16: setup failed"

cat >"$D/lens.json" <<'EOF_LENS'
[{"location":"lib/c.sh:42","severity":"suggestion","lens":"Reuse",
  "summary":"this helper already exists","detail":"three call sites duplicate it"}]
EOF_LENS

if python3 -I -B "$LIB" defer --run-dir "$D" --attempt 1 --include-blockers \
     --lens-findings "$D/lens.json" >"$D/defer.txt" 2>"$D/defer.err"; then
  ok "B16: defer encodes blockers and lens findings together"
else
  bad "B16: defer refused: $(cat "$D/defer.err")"
fi
case "$(cat "$D/defer.txt")" in
  "PREMERGE_DEFER TOTAL=3 BLOCKER=1 SUGGESTION=2 PATH="*)
    ok "B16: the defer line reports the split" ;;
  *) bad "B16: unexpected defer line: $(cat "$D/defer.txt")" ;;
esac

DEFER_ROWS="$(python3 -I -B -c '
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[1])
print(",".join(sorted("%s=%s" % (f["scope"]["path"], f["severity"]) for f in doc["findings"])))
' "$D/deferred-aggregate.md")"
if [ "$DEFER_ROWS" = "lib/a.sh=blocker,lib/b.sh=suggestion,lib/c.sh=suggestion" ]; then
  ok "B16: the surviving blocker keeps blocker severity; the lens row files as suggestion"
else
  bad "B16: wrong deferred rows: $DEFER_ROWS"
fi

# A lens finding filed as a blocker would HALT a run over a refactor suggestion.
cat >"$D/lens-blocker.json" <<'EOF_LENSB'
[{"location":"lib/d.sh:1","severity":"blocker","lens":"Quality",
  "summary":"nested conditionals","detail":"four levels deep"}]
EOF_LENSB
python3 -I -B "$LIB" defer --run-dir "$D" --attempt 1 --lens-findings "$D/lens-blocker.json" \
  >/dev/null 2>&1
LENS_SEV="$(python3 -I -B -c '
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[1])
print(",".join(f["severity"] for f in doc["findings"] if f["scope"]["path"] == "lib/d.sh"))
' "$D/deferred-aggregate.md")"
if [ "$LENS_SEV" = "suggestion" ]; then
  ok "B16: a lens finding cannot escalate itself to blocker"
else
  bad "B16: a lens row filed as '$LENS_SEV' — it can halt a run over a refactor"
fi

# The per-attempt cleanup aggregate must STAY blocker-free (B7 depends on it).
if python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
row = {"file": "lib/x.sh", "line": 1, "summary": "s", "failure_scenario": "d", "severity": "blocker"}
try:
    m._encode_aggregate([row], 1, "20260101-000000-ab")
except SystemExit as exc:
    sys.exit(0 if exc.code == 74 else 1)
sys.exit(1)
' "$LIB" 2>/dev/null; then
  ok "B16: only defer may put a blocker in the envelope; plan's encoder refuses"
else
  bad "B16: the cleanup encoder accepted a blocker row"
fi

if python3 -I -B "$LIB" defer --run-dir "$D" --attempt 3 >/dev/null 2>"$D/d3.err"; then
  bad "B16: defer accepted an attempt with no evidence"
else
  grep -q 'attempt_evidence_missing' "$D/d3.err" \
    && ok "B16: defer refuses an attempt whose evidence is missing" \
    || bad "B16: wrong token: $(cat "$D/d3.err")"
fi

echo "== B17: the WAIT_CI bound enforces itself =="
# Every fence is a fresh shell. A controller that never threads the counter
# passes --wait-passes 0 forever; if the ceiling only read that argument, WAIT_CI
# (which by design consumes no repair) would spin with no reachable backstop —
# an unbounded autonomous loop under a command that promises it will not.
D="$(new_case)"
write_input "$D" '[]'
plan_at "$D" 1 "$SHA_A" || bad "B17: setup failed"
B17_LAST=""
B17_ROUNDS=0
while [ "$B17_ROUNDS" -lt 15 ]; do
  B17_ROUNDS=$((B17_ROUNDS + 1))
  B17_RES="$(decide "$D" 1 3 not_green 'ci=pending' 0)"
  B17_LAST="${B17_RES%% *}"
  [ "${B17_RES##* }" = "0" ] || break
done
if [ "$B17_LAST" = "STOP_UNREADABLE" ] && [ "$B17_ROUNDS" -le 10 ]; then
  ok "B17: a forgetful caller still terminates, after $B17_ROUNDS rounds"
else
  bad "B17: ran $B17_ROUNDS rounds ending '$B17_LAST' — the bound is caller-supplied, not enforced"
fi

echo "== B18: two blockers sharing a summary are two blockers =="
# The fingerprint is line-independent on purpose, so two distinct blockers in one
# file with the same summary collide. As a SET they collapse to one element and
# fixing one leaves the set unchanged -> STOP_NO_PROGRESS on a successful attempt.
D="$(new_case)"
write_input "$D" '[
  {"file":"lib/a.sh","line":10,"summary":"the return value of write() is never checked","failure_scenario":"silent truncation","severity":"blocker"},
  {"file":"lib/a.sh","line":88,"summary":"the return value of write() is never checked","failure_scenario":"silent truncation","severity":"blocker"}
]'
plan_at "$D" 1 "$SHA_A" || bad "B18: setup failed"
decide "$D" 1 3 not_green 'blockers_remaining=2' >/dev/null
write_input "$D" '[
  {"file":"lib/a.sh","line":88,"summary":"the return value of write() is never checked","failure_scenario":"silent truncation","severity":"blocker"}
]'
plan_at "$D" 2 "$SHA_B" || bad "B18: setup failed"
B18_RES="$(decide "$D" 2 3 not_green 'blockers_remaining=1')"
expect_decision "$B18_RES" CONTINUE 0 "clearing one of two same-summary blockers"
B18_LINE="$(python3 -I -B "$LIB" converge --run-dir "$D" --attempt 2 --max-repairs 3 \
  --verdict not_green --reasons 'blockers_remaining=1' 2>/dev/null)"
case "$B18_LINE" in
  *"BLOCKERS=1 PREV=2 FIXED=1"*) ok "B18: the counts describe blockers, not distinct fingerprints" ;;
  *) bad "B18: wrong counts: $B18_LINE" ;;
esac

# --------------------------------------------------------------------------
rm -rf "$WORK"

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
