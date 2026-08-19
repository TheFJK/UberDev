#!/usr/bin/env bash
set -euo pipefail
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIAGE="$ROOT/plugins/uberdev/lib/solve_triage.py"
FIX="$ROOT/tests/fixtures/solve-routing"
PASS=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
assert_case() {
  local fixture="$1" expected="$2"; shift 2
  local out
  case "$fixture" in /*) snapshot="$fixture" ;; *) snapshot="$FIX/$fixture" ;; esac
  out="$(python3 -I "$TRIAGE" classify --snapshot "$snapshot" "$@")"
  python3 - "$out" "$expected" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); expected=sys.argv[2]
assert v["schema_version"] == 1
assert v["tier"] == expected, v
assert v["raw_tier"] in {"trivial","small","medium","large"}
assert v["risk_signals"] == sorted(set(v["risk_signals"]))
assert json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False)==sys.argv[1]
PY
  PASS=$((PASS+1))
}

assert_case trivial.json trivial
assert_case small.json small
assert_case bare-refactor.json medium
assert_case large-refactor.json large
assert_case high-risk-cross-component.json large
assert_case trivial.json small --floor small
assert_case large-refactor.json medium --ceiling medium
assert_case high-risk-cross-component.json trivial --override trivial

# Explicit override is applied last but cannot erase computed risk evidence.
OUT="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/high-risk-cross-component.json" --override trivial)"
python3 - "$OUT" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["source"]=="override"; assert "authorization" in v["risk_signals"] and "concurrency" in v["risk_signals"]
PY
PASS=$((PASS+1))

# A path cited purely as EVIDENCE is not scope (#614). small.json reads
# "Actual: error in lib/parser.py" — a symptom location, not a change target —
# so it contributes NO file and NO component, and the `bug`+reproduction rule
# still lands it on `small`. This assertion used to read `file_count==1`, which
# is precisely the defect: the counter could not tell a cited file from an
# edited one.
ONE="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/small.json")"
python3 - "$ONE" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["components"]==[] and v["component_count"]==0 and v["file_count"]==0,v
PY
PASS=$((PASS+1))
# One file path is one component; explicit extensionless module lists count.
# The body has to MARK the path as a change target for it to be scope at all,
# so this carries "Fix" — the property under test is the file→component
# collapse, not the scope extractor.
cat >"$TMP/one-component.json" <<'JSON'
{"number":10,"title":"Parser error on empty input","state":"OPEN","body":"Fix the empty-input branch in lib/parser.py.","labels":[{"name":"bug"}]}
JSON
ONE_COMPONENT="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/one-component.json")"
python3 - "$ONE_COMPONENT" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["components"]==["lib"] and v["component_count"]==1 and v["file_count"]==1,v
PY
PASS=$((PASS+1))
cat >"$TMP/same-component.json" <<'JSON'
{"number":9,"title":"Two auth files","state":"OPEN","body":"Expected fix in auth/a.py and auth/b.py. Actual error.","labels":[{"name":"bug"}]}
JSON
SAME="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/same-component.json")"
python3 - "$SAME" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["files"]==["auth/a.py","auth/b.py"] and v["file_count"]==2; assert v["components"]==["auth"] and v["component_count"]==1
PY
PASS=$((PASS+1))
cat >"$TMP/modules.json" <<'JSON'
{"number":8,"title":"Refactor module boundaries","state":"OPEN","body":"Refactor the auth, payments, and notifications modules.","labels":[{"name":"refactor"}]}
JSON
assert_case "$TMP/modules.json" large

# Inverted clamps are ignored as a pair, matching config-read's contract.
INVERTED="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/trivial.json" --floor large --ceiling small)"
python3 - "$INVERTED" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["raw_tier"]==v["clamped_tier"]==v["effective_tier"]=="trivial"; assert v["source"]=="computed"
PY
PASS=$((PASS+1))

if python3 -I "$TRIAGE" classify --snapshot "$FIX/trivial.json" --expected-issue 99 >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
grep -q triage_issue_mismatch "$TMP/err"; PASS=$((PASS+1))

SECURE="$TMP/secure"; mkdir "$SECURE"; chmod 700 "$SECURE"
cp "$FIX/trivial.json" "$SECURE/issue.json"; chmod 600 "$SECURE/issue.json"
python3 -I "$TRIAGE" classify --snapshot "$SECURE/issue.json" --secure-root "$SECURE" --expected-issue 1 >/dev/null; PASS=$((PASS+1))
python3 -I - "$TRIAGE" "$SECURE/issue.json" "$SECURE" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("solve_triage", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
original_geteuid = getattr(os, "geteuid", None)
if original_geteuid is not None:
    del os.geteuid
try:
    assert module.load_snapshot(sys.argv[2], sys.argv[3])["number"] == 1
finally:
    if original_geteuid is not None:
        os.geteuid = original_geteuid
PY
PASS=$((PASS+1))
ln "$SECURE/issue.json" "$SECURE/hard.json"
if python3 -I "$TRIAGE" classify --snapshot "$SECURE/issue.json" --secure-root "$SECURE" >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
grep -q triage_snapshot_unsafe "$TMP/err"; rm "$SECURE/hard.json"; PASS=$((PASS+1))
ln -s "$SECURE/issue.json" "$SECURE/link.json"
if python3 -I "$TRIAGE" classify --snapshot "$SECURE/link.json" --secure-root "$SECURE" >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
grep -q triage_snapshot_unsafe "$TMP/err"; PASS=$((PASS+1))

# Bounds are reject-not-truncate, and malformed/closed/oversized snapshots fail.
python3 - "$TMP" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
base={"number":1,"title":"ok","state":"OPEN","body":"","labels":[],"assignees":[],"comments":[]}
cases={
 "issue":dict(base,number=0), "title":dict(base,title="x"*257),
 "body":dict(base,body="x"*65537), "labels":dict(base,labels=[{"name":"x"}]*101),
 "label":dict(base,labels=[{"name":"x"*129}]), "closed":dict(base,state="CLOSED"),
}
for name,value in cases.items(): (p/f"{name}.json").write_text(json.dumps(value))
(p/"huge.json").write_bytes(b" "*(1048576-1)+b"{}")
PY
for bad in issue title body labels label closed huge; do
  if python3 -I "$TRIAGE" classify --snapshot "$TMP/$bad.json" >"$TMP/out" 2>"$TMP/err"; then
    echo "FAIL: $bad accepted" >&2; exit 1
  fi
  grep -Eq 'triage_(invalid|limit|closed|snapshot)' "$TMP/err"
  PASS=$((PASS+1))
done

# Batch validator: <=50 unique positive issues, deterministic de-duplication.
python3 -I "$TRIAGE" validate-issues 3 1 3 2 >"$TMP/issues"
[ "$(cat "$TMP/issues")" = '[3,1,2]' ]
PASS=$((PASS+1))
if python3 -I "$TRIAGE" validate-issues $(seq 1 51) >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
grep -q 'triage_limit_issues' "$TMP/err"; PASS=$((PASS+1))
if python3 -I "$TRIAGE" validate-issues 1 0 >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
grep -q 'triage_invalid_issue' "$TMP/err"; PASS=$((PASS+1))

# --- component tokens must satisfy the routing-context schema (regression) ----
# See tests/component-token-schema.py for the full rationale: a token carrying a
# dot made uberdev_agent_context_create fail with route_context_create_failed,
# and /solve, /turbo and /goal all refused the issue. Every open issue in this
# repo names a *.test.sh, so the entire backlog was undispatchable.
python3 -I "$ROOT/tests/component-token-schema.py" "$TRIAGE" "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
PASS=$((PASS+1))

# --- R0: matched_rules vocabulary must satisfy the routing-context schema -----
# Same class as the component-token guard above, one field over: `matched_rules`
# is validated against a closed `allowed_rule` alternation in agent-dispatch.sh,
# and a token the producer emits but that validator refuses aborts the ENTIRE
# batch with route_context_create_failed, not just the one issue. See
# tests/triage-rule-vocabulary.py for the full rationale.
python3 -I "$ROOT/tests/triage-rule-vocabulary.py" "$TRIAGE" "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
PASS=$((PASS+1))

# R1: the guard's exit contract, end to end at the CLI the launcher drives.
# Every other triage code above is asserted through the CLI; triage_rule_unknown
# rides the TriageError path __main__ already owns, so it must be the bare code
# on stderr with exit 2 exactly -- not a traceback, and not a new exit path.
# finalize reads matched_rules straight off --decision, so an undeclared token
# needs no fixture.
RC=0
python3 -I "$TRIAGE" finalize --decision '{"raw_tier":"small","matched_rules":["bogus:rule"]}' \
  --clamped small >"$TMP/out" 2>"$TMP/err" || RC=$?
if [ "$RC" -ne 2 ]; then
  echo "FAIL: finalize on an undeclared rule token exited $RC, expected 2" >&2; exit 1
fi
grep -q '^triage_rule_unknown$' "$TMP/err"
PASS=$((PASS+1))
# ...and it does not refuse a legitimate decision: same subcommand, declared
# tokens, exit 0 with the floor clamp applied.
python3 -I "$TRIAGE" finalize --decision '{"raw_tier":"small","matched_rules":["small:concrete-reproduction"]}' \
  --clamped medium >"$TMP/out"
grep -q '"source":"floor"' "$TMP/out"
PASS=$((PASS+1))

# --- E/F: the one-way tier ratchet (#532) ------------------------------------
# A solver that opens the code and finds the issue is structurally larger than
# triage said cannot re-classify itself mid-run: it labels the issue
# `uberdev:tier-<tier>` and the NEXT classification reads that label. The ratchet
# is UPGRADE-ONLY by construction -- a label naming a tier at or below the
# computed one is inert, so the same mechanism can never be used to shop for a
# lighter workflow. `trivial` is not an escalation target at all: escalating *to*
# trivial is an upgrade from nothing.
#
# escalated-trivial.json classifies `trivial` on its OWN signals (docs label, one
# named file, short body, no risk match) and carries `uberdev:tier-medium`. That
# separation is what makes E1 an escalation assertion rather than a restatement
# of the trivial rule: strip the label and the fixture still reads trivial.

# E1: the label raises raw_tier, and the raise is recorded as evidence.
assert_case escalated-trivial.json medium
ESC="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/escalated-trivial.json")"
python3 - "$ESC" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="medium", v
# A pure escalation is still a COMPUTED tier -- it moves `raw`, so the existing
# floor/ceiling/override machinery composes on top of it untouched.
assert v["source"]=="computed", v
assert "escalation-label:medium" in v["matched_rules"], v
# The computed signal survives beside it: the trail reads "computed trivial,
# escalated to medium", not "was always medium".
assert "trivial:bounded-explicit-signal" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# E2: one-way. A label BELOW the computed tier changes nothing and leaves no
# token -- the anti-label-shopping property, asserted rather than asserted-about.
python3 - "$FIX/large-refactor.json" "$TMP/no-downgrade.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=list(v["labels"])+[{"name":"uberdev:tier-small"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/no-downgrade.json" large
DOWN="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/no-downgrade.json")"
python3 - "$DOWN" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="large", v
assert not [r for r in v["matched_rules"] if r.startswith("escalation-label:")], v
PY
PASS=$((PASS+1))

# E3: a ceiling still wins over an escalation -- the operator's explicit clamp is
# not overridable by an issue label -- but the escalation evidence is preserved,
# so the ceiling is visibly a DECISION and not a missing signal.
assert_case escalated-trivial.json small --ceiling small
CEIL="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/escalated-trivial.json" --ceiling small)"
python3 - "$CEIL" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["tier"]=="small" and v["source"]=="ceiling", v
assert "escalation-label:medium" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# E4: same for an explicit override.
assert_case escalated-trivial.json trivial --override trivial
OVER="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/escalated-trivial.json" --override trivial)"
python3 - "$OVER" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["tier"]=="trivial" and v["source"]=="override", v
assert "escalation-label:medium" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# E5: a label naming no known tier is INERT -- it must not raise, not emit a
# token, and not fail the run. A solver typo cannot break the dispatch.
python3 - "$FIX/escalated-trivial.json" "$TMP/bogus-tier.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=[{"name":"docs"},{"name":"uberdev:tier-bogus"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/bogus-tier.json" trivial
BOGUS="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/bogus-tier.json")"
python3 - "$BOGUS" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="trivial", v
assert not [r for r in v["matched_rules"] if r.startswith("escalation-label:")], v
PY
PASS=$((PASS+1))

# E6: several tier labels at once resolve to EXACTLY ONE token, the highest --
# `matched_rules` is length-capped and duplicate-checked by the context
# validator, so an unbounded emitter here would be a dispatch failure, not just
# noise. `uberdev:tier-trivial` is not an escalation label at all.
python3 - "$FIX/escalated-trivial.json" "$TMP/multi-tier.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=[{"name":"docs"},{"name":"uberdev:tier-small"},
             {"name":"uberdev:tier-large"},{"name":"uberdev:tier-trivial"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/multi-tier.json" large
MULTI="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/multi-tier.json")"
python3 - "$MULTI" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="large", v
tokens=[r for r in v["matched_rules"] if r.startswith("escalation-label:")]
assert tokens==["escalation-label:large"], tokens
PY
PASS=$((PASS+1))

# F1: finalize round-trip -- first coverage of the launcher's actual two-step
# (classify -> shell clamp -> finalize). The escalated raw_tier has to survive
# the hand-off, because the launcher reads raw_tier off classify and it is
# finalize's output that reaches the routing context.
FIN="$(python3 -I "$TRIAGE" finalize --decision "$ESC" --clamped medium)"
python3 - "$FIN" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["clamped_tier"]=="medium" and v["effective_tier"]=="medium" and v["tier"]=="medium", v
assert v["source"]=="computed", v
assert v["schema_version"]==1, v
assert "escalation-label:medium" in v["matched_rules"], v
assert json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False)==sys.argv[1], \
    "finalize output is not canonical bytes"
PY
PASS=$((PASS+1))

# F2: an override at finalize keeps the escalation evidence, same as E4 does at
# classify -- the two entry points must not disagree about what is recorded.
FIN_OVER="$(python3 -I "$TRIAGE" finalize --decision "$ESC" --clamped medium --override trivial)"
python3 - "$FIN_OVER" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["tier"]=="trivial" and v["source"]=="override", v
assert "escalation-label:medium" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# --- S: the tier signal measures SCOPE, not citation density (#614) ----------
# The file rule used to scrape every filename-shaped token out of issue prose,
# so a file cited as EVIDENCE counted exactly like a file the fix will edit --
# and three of them is the `large` threshold, which gates a 33x cost difference
# (1 solver vs 33). This repo REQUIRES its issue writers to anchor claims with
# `path:line` evidence, so the house style guaranteed the verdict: `large` on
# EVERY open issue (40 of 40 when #614 was filed, 43 of 43 when this landed),
# i.e. a cost gate with no discriminating power. Every row below is a property
# of the replacement: a declared scope block is read as fact, and the fallback
# counts only paths the prose marks as change targets.

# S1 -- THE BUG, in one pair. The same one-line typo fix, priced twice: the
# bodies differ only in how many files the prose mentions, and the second one
# explicitly says the extra two are not to be touched. Before the fix, A was
# `trivial` (1 agent) and B was `large` (33 agents) on `large:three-files`.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
base = {"number": 1, "title": "Fix a typo in the dispatch helper", "state": "OPEN",
        "labels": [{"name": "typo"}], "assignees": [], "comments": []}
cite_a = "The word 'recieve' is misspelled in lib/dispatch.sh."
cite_b = (cite_a + " Same typo also appears in docs/readme.md and"
          " tests/foo.test.sh but those are fine to leave.")
(tmp / "cite-a.json").write_text(json.dumps(dict(base, body=cite_a)))
(tmp / "cite-b.json").write_text(json.dumps(dict(base, body=cite_b)))
PY
CITE_A="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/cite-a.json")"
CITE_B="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/cite-b.json")"
python3 - "$CITE_A" "$CITE_B" <<'PY'
import json,sys
a,b=(json.loads(x) for x in sys.argv[1:3])
assert a["tier"]==b["tier"], (a["tier"],b["tier"],
    "identical work, priced differently on citation count alone")
assert a["raw_tier"]==b["raw_tier"], (a["raw_tier"],b["raw_tier"])
assert a["file_count"]==b["file_count"], (a["file_count"],b["file_count"])
assert a["tier"]=="trivial", a
assert "large:three-files" not in b["matched_rules"], b
PY
PASS=$((PASS+1))

# S2 -- a producer-declared scope block is read as FACT and OUTRANKS the prose.
# Nine cited paths, one declared change target: the declaration wins, so a
# well-evidenced issue is no longer taxed as a big one.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
cited = " ".join(f"See lib/mod{n}.py:{n}0 for the same shape." for n in range(9))
body = ("The launcher drops the exit code.\n" + cited +
        "\n<!-- uberdev-scope v=1 files=lib/launcher.sh -->")
(tmp / "declared-one.json").write_text(json.dumps(
    {"number": 11, "title": "Launcher drops the exit code", "state": "OPEN",
     "body": body, "labels": [{"name": "bug"}]}))
PY
DECLARED_ONE="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/declared-one.json")"
python3 - "$DECLARED_ONE" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/launcher.sh"], v
assert v["file_count"]==1 and v["components"]==["lib"], v
assert "large:three-files" not in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S3 -- the declaration is not a one-way discount: a declared THREE-file scope
# fires `large:three-files` on prose that cites nothing at all. Without this the
# block would only ever be able to make an issue cheaper.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
body = ("The retry ceiling is duplicated in three places and they disagree.\n"
        "<!-- uberdev-scope v=1 files=lib/a.sh,lib/b.sh,lib/c.sh -->")
(tmp / "declared-three.json").write_text(json.dumps(
    {"number": 12, "title": "Retry ceiling disagrees across copies", "state": "OPEN",
     "body": body, "labels": [{"name": "bug"}]}))
PY
assert_case "$TMP/declared-three.json" large
DECLARED_THREE="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/declared-three.json")"
python3 - "$DECLARED_THREE" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/a.sh","lib/b.sh","lib/c.sh"], v
assert "large:three-files" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S4 -- an EMPTY declaration is a recorded state, never a licence to fall back
# to the guess (the `edges=` convention in agents/findings-to-issues.md). A
# writer that declares "this touches nothing yet" must not be re-heuristicked
# into a scope by the change-intent prose sitting right next to it.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
body = ("Fix lib/a.sh and lib/b.sh and lib/c.sh once the approach is decided.\n"
        "<!-- uberdev-scope v=1 files= -->")
(tmp / "declared-empty.json").write_text(json.dumps(
    {"number": 13, "title": "Decide the retry approach", "state": "OPEN",
     "body": body, "labels": [{"name": "bug"}]}))
PY
DECLARED_EMPTY="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/declared-empty.json")"
python3 - "$DECLARED_EMPTY" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==[] and v["file_count"]==0, v
assert "large:three-files" not in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S5 -- a scope block QUOTED inside a fenced code block is inert. Issues about
# the format (this one, for a start) carry the literal marker as an example;
# reading it as a declaration would let documentation re-price its own subject.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
body = ("Writers should emit the block. Example:\n\n"
        "```\n<!-- uberdev-scope v=1 files=lib/a.sh,lib/b.sh,lib/c.sh -->\n```\n\n"
        "Update lib/writer.sh to emit it.")
(tmp / "quoted-scope.json").write_text(json.dumps(
    {"number": 14, "title": "Writers should emit a scope block", "state": "OPEN",
     "body": body, "labels": [{"name": "bug"}]}))
PY
QUOTED="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/quoted-scope.json")"
python3 - "$QUOTED" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/writer.sh"], v
assert "large:three-files" not in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S6 -- an explicit exclusion clause suppresses its own paths even though it
# carries a change verb. "Do not touch X" reads as change intent to a bare verb
# scan, which is the exact shape body B in S1 uses.
cat >"$TMP/excluded.json" <<'JSON'
{"number":15,"title":"Wrong exit code on retry","state":"OPEN","body":"Update lib/a.sh so the retry exits non-zero. Do not touch lib/b.sh or lib/c.sh; they are fine as they are.","labels":[{"name":"bug"}]}
JSON
EXCLUDED="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/excluded.json")"
python3 - "$EXCLUDED" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/a.sh"], v
assert "large:three-files" not in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S7 -- POSITIVE CONTROL. Without this the whole section is satisfied by a
# scope extractor that always returns nothing, which would gut `large` rather
# than sharpen it: three MARKED change targets still classify `large`.
cat >"$TMP/marked-three.json" <<'JSON'
{"number":16,"title":"Retry ceiling disagrees across copies","state":"OPEN","body":"Update lib/a.sh, lib/b.sh and lib/c.sh so the three retry ceilings agree.","labels":[{"name":"bug"}]}
JSON
assert_case "$TMP/marked-three.json" large
MARKED="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/marked-three.json")"
python3 - "$MARKED" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/a.sh","lib/b.sh","lib/c.sh"], v
assert "large:three-files" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S8 -- the house style itself: a `path:line` evidence wall with no change-target
# marking is NOT scope. This is the corpus shape behind the all-`large` verdict.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
body = "\n".join(f"- `lib/mod{n}.py:{n}0` shows the same unchecked return." for n in range(9))
(tmp / "evidence-wall.json").write_text(json.dumps(
    {"number": 17, "title": "Unchecked return in the retry helper", "state": "OPEN",
     "body": "The retry helper drops errors.\n" + body, "labels": [{"name": "bug"}]}))
PY
WALL="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/evidence-wall.json")"
python3 - "$WALL" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==[] and v["file_count"]==0, v
assert "large:three-files" not in v["matched_rules"], v
assert v["tier"]!="large", v
PY
PASS=$((PASS+1))

# S9 -- the declaration is not forgeable from reviewer prose. This is the exact
# body `agents/findings-to-issues.md` files: a finding written by a reviewer
# agent, wrapped in the four-backtick `finding` fence, under the agent's own
# scope declaration. The fence strip runs before the marker search, so a scope
# block inside the finding is inert and only the agent's own declaration is
# read. Without that ordering, any reviewer could price its own issue.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
body = ("**File:** `lib/real.sh:42`\n\n"
        "````finding\n"
        "The helper swallows the error.\n"
        "<!-- uberdev-scope v=1 files=a.sh,b.sh,c.sh,d.sh -->\n"
        "````\n\n"
        "---\n"
        "<!-- uberdev-scope v=1 files=lib/real.sh -->\n"
        "<!-- uberdev:review-pr-finding fingerprint=0123456789abcdef -->\n")
(tmp / "forged-scope.json").write_text(json.dumps(
    {"number": 18, "title": "Unchecked return in the retry helper", "state": "OPEN",
     "body": body, "labels": [{"name": "bug"}]}))
PY
FORGED="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/forged-scope.json")"
python3 - "$FORGED" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/real.sh"], v
assert "large:three-files" not in v["matched_rules"], v
PY
PASS=$((PASS+1))

# S10 -- ONE producer for the file count. The launcher's `triage:` line used to
# run its own `grep -oE` over the issue body: a second, independent copy of a
# rule that lives in this module, kept in sync by nothing. It is the one signal
# an operator reads to sanity-check a tier, so a drifted copy does not merely
# print a stale number — it contradicts the tier printed beside it. Structural,
# because the behavioural path needs a live `gh`.
LAUNCHER="$ROOT/plugins/uberdev/lib/solve-launcher.sh"
if ! grep -q 'scope_files=\$TRIAGE_SCOPE_FILES' "$LAUNCHER"; then
  echo "FAIL: the launcher's triage: line no longer reports scope_files" >&2; exit 1
fi
if ! grep -q 'json.loads(sys.argv\[1\])\["file_count"\]' "$LAUNCHER"; then
  echo "FAIL: the launcher no longer reads file_count off the triage decision" >&2; exit 1
fi
if grep -qE 'TRIAGE_FILES=.*grep -oE|files_mentioned=' "$LAUNCHER"; then
  echo "FAIL: the launcher re-derives the file count with its own grep — that is a" >&2
  echo "      second, uncompared copy of the rule in lib/solve_triage.py" >&2
  exit 1
fi
PASS=$((PASS+1))

# S11 -- WRITER/READER DRIFT. The scope block is one contract written in three
# places: the regex here, and the literal each issue writer ships. Nothing
# compares them, which is the #370/#371 class -- and the failure is silent by
# construction, because an unparseable block is indistinguishable from no block
# at all: triage just falls back to the heuristic and prices the issue the old
# way. So parse every literal the writers ship THROUGH the reader, with the
# writer's own placeholder filled in.
python3 -I - "$TRIAGE" "$ROOT/plugins/uberdev/commands/issue.md" \
  "$ROOT/plugins/uberdev/agents/findings-to-issues.md" <<'PY'
import importlib.util, pathlib, re, sys
spec = importlib.util.spec_from_file_location("solve_triage_under_test", sys.argv[1])
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)
# Whole-line literals only: the prose in both files also names the block, and a
# sentence about it is not a thing any writer emits into an issue body.
line_re = re.compile(r"^<!-- uberdev-scope .*-->$", re.M)
found = 0
for path in sys.argv[2:]:
    for line in line_re.findall(pathlib.Path(path).read_text(encoding="utf-8")):
        found += 1
        # `{file_path}` is findings-to-issues' binding, substituted per row.
        parsed = st.declared_scope(line.replace("{file_path}", "lib/real.sh"))
        assert parsed, (
            f"{pathlib.Path(path).name} ships a scope block the reader does not "
            f"parse: {line!r} -> {parsed!r}. Triage would silently fall back to "
            "the prose heuristic.")
# 3 templates in commands/issue.md (bug / feat / chore) + 1 body shape in
# agents/findings-to-issues.md. A drop below that means an emitter was deleted
# and this guard stopped covering it.
assert found >= 4, f"only {found} scope-block literals found — the guard is vacuous"
PY
PASS=$((PASS+1))

# S12 -- PARTIAL unreadability is not a smaller honest declaration. The
# all-refused guard already refuses to report an unreadable declaration as the
# empty one, but it only fires when EVERY token is refused. Drop one token --
# the `:line` suffix both writers are told in prose to strip is the named,
# expected producer mistake -- and the survivors come back as a SHORTER list
# that is byte-indistinguishable from an honest declaration of that size. That
# is the under-price direction this module states everywhere it must never
# move in: three paths priced as two crosses the rung that decides between one
# solver agent and thirty-three.
python3 -I - "$TRIAGE" <<'PY_S12'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("solve_triage_under_test", sys.argv[1])
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

clean = "<!-- uberdev-scope v=1 files=lib/a.sh,lib/b.sh,lib/c.sh -->"
assert st.declared_scope(clean) == ["lib/a.sh", "lib/b.sh", "lib/c.sh"], st.declared_scope(clean)

# One token still carries the citation suffix. FILES_TOKEN_RE refuses it.
partial = "<!-- uberdev-scope v=1 files=lib/a.sh,lib/b.sh:42,lib/c.sh -->"
got = st.declared_scope(partial)
assert got is None, (
    "a partly unreadable declaration must read as UNDECLARED so the prose "
    f"heuristic still runs, not as a smaller complete one: got {got!r}")

# The two states the tri-state already encoded must not regress.
assert st.declared_scope("no block here at all") is None
assert st.declared_scope("<!-- uberdev-scope v=1 files= -->") == [], \
    "a deliberate empty declaration is still a declaration of no files"
assert st.declared_scope("<!-- uberdev-scope v=1 files=lib/a.sh:1,lib/b.sh:2 -->") is None, \
    "the all-refused case must keep answering undeclared"
PY_S12
PASS=$((PASS+1))

echo "solve-triage: $PASS passed"
