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
assert v["raw_tier"] in {"trivial","small","medium"}
assert v["risk_signals"] == sorted(set(v["risk_signals"]))
assert json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False)==sys.argv[1]
PY
  PASS=$((PASS+1))
}

assert_case trivial.json trivial
assert_case small.json small
assert_case bare-refactor.json medium
assert_case multi-component-refactor.json medium
assert_case high-risk-cross-component.json medium
assert_case trivial.json small --floor small
assert_case multi-component-refactor.json small --ceiling small
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
assert_case "$TMP/modules.json" medium

# Inverted clamps are ignored as a pair, matching config-read's contract.
INVERTED="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/trivial.json" --floor medium --ceiling small)"
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
python3 - "$FIX/multi-component-refactor.json" "$TMP/no-downgrade.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=list(v["labels"])+[{"name":"uberdev:tier-small"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/no-downgrade.json" medium
DOWN="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/no-downgrade.json")"
python3 - "$DOWN" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="medium", v
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
             {"name":"uberdev:tier-medium"},{"name":"uberdev:tier-trivial"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/multi-tier.json" medium
MULTI="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/multi-tier.json")"
python3 - "$MULTI" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="medium", v
tokens=[r for r in v["matched_rules"] if r.startswith("escalation-label:")]
assert tokens==["escalation-label:medium"], tokens
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
# and three of them crossed the rung between one solver agent and a full design
# fleet. This repo REQUIRES its issue writers to anchor claims with `path:line`
# evidence, so the house style guaranteed the verdict: the top rung on EVERY
# open issue (40 of 40 when #614 was filed, 43 of 43 when this landed), i.e. a
# cost gate with no discriminating power. Every row below is a property of the
# replacement: a declared scope block is read as fact, and the fallback counts
# only paths the prose marks as change targets.
#
# #619 deleted the `large:three-files` TOKEN these rows used to read, so each
# assertion now states the same fact in the surviving vocabulary: the rule fired
# on `len(files) >= 3`, so "no token" is `file_count < 3` and, where the count is
# already pinned above it, the tier that count decides.

# S1 -- THE BUG, in one pair. The same one-line typo fix, priced twice: the
# bodies differ only in how many files the prose mentions, and the second one
# explicitly says the extra two are not to be touched. Before the fix, A was
# `trivial` (1 agent) and B was the top rung (33 agents) on `large:three-files`.
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
assert b["file_count"] < 3, b
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
assert v["tier"]=="small", v
PY
PASS=$((PASS+1))

# S3 -- the declaration is not a one-way discount: a declared THREE-file scope
# prices at the design rung on prose that cites nothing at all. Without this the
# block would only ever be able to make an issue cheaper. Asserted as a PAIR,
# because `medium` is also the fallback rung: the same body declaring TWO files
# is `small`, so it is the declared count that moved the tier, not the default.
python3 - "$TMP" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
for name, declared in (("declared-three", "lib/a.sh,lib/b.sh,lib/c.sh"),
                       ("declared-two", "lib/a.sh,lib/b.sh")):
    body = ("The retry ceiling is duplicated in three places and they disagree.\n"
            f"<!-- uberdev-scope v=1 files={declared} -->")
    (tmp / f"{name}.json").write_text(json.dumps(
        {"number": 12, "title": "Retry ceiling disagrees across copies", "state": "OPEN",
         "body": body, "labels": [{"name": "bug"}]}))
PY
assert_case "$TMP/declared-three.json" medium
assert_case "$TMP/declared-two.json" small
DECLARED_THREE="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/declared-three.json")"
python3 - "$DECLARED_THREE" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/a.sh","lib/b.sh","lib/c.sh"], v
assert v["file_count"]>=3 and v["tier"]=="medium", v
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
assert v["tier"]=="small", v
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
assert v["tier"]=="small", v
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
assert v["tier"]=="small", v
PY
PASS=$((PASS+1))

# S7 -- POSITIVE CONTROL. Without this the whole section is satisfied by a
# scope extractor that always returns nothing, which would gut the ladder rather
# than sharpen it: three MARKED change targets still hold the design rung.
cat >"$TMP/marked-three.json" <<'JSON'
{"number":16,"title":"Retry ceiling disagrees across copies","state":"OPEN","body":"Update lib/a.sh, lib/b.sh and lib/c.sh so the three retry ceilings agree.","labels":[{"name":"bug"}]}
JSON
assert_case "$TMP/marked-three.json" medium
MARKED="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/marked-three.json")"
python3 - "$MARKED" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["files"]==["lib/a.sh","lib/b.sh","lib/c.sh"], v
assert v["file_count"]>=3 and v["tier"]=="medium", v
PY
PASS=$((PASS+1))

# S8 -- the house style itself: a `path:line` evidence wall with no change-target
# marking is NOT scope. This is the corpus shape behind the all-top-rung verdict.
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
assert v["tier"]=="small", v
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
assert v["tier"]=="small", v
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

# --- L: the `large` rung is COLLAPSED into `medium` (#619) -------------------
# Four tier names resolved to exactly two behaviours. No ceremony consumer ever
# told `medium` from `large`: lib/solve-launcher.sh branches trivial / small /
# catch-all with no `large)` arm, and solve-fleet's DESIGN_TIERS held both. So
# EIGHT rules -- `large:three-files`, `large:multi-component-high-risk`,
# `large:cross-cutting-refactor` and five `large-label:*` -- were computed,
# declared in TRIAGE_RULE_TOKENS, mirrored into the closed `allowed_rule`
# alternation lib/agent-dispatch.sh validates against, fixtured, and then
# discarded. #619 deletes the rung; `medium` is now the ceiling.
#
# COLLAPSING A RUNG MUST MOVE AN ISSUE AT MOST ONE RUNG. The eight rules split
# into two halves that earn that very differently, and only one half is safe to
# delete:
#   * TWO were BOUND-keyed, and the arms that remain subsume them.
#     `large:three-files` fired on `len(files) >= 3`, and BOTH lighter arms
#     require the opposite (`small` needs <= 2, `trivial` needs <= 1), so a
#     three-file issue can only ever reach the fallback rung -- L3 pins it.
#     `large:multi-component-high-risk` required a risk signal, and both lighter
#     arms are guarded by `not risks` -- L4 pins it. These two are DELETED.
#   * SIX were LABEL-keyed -- five design labels (`epic`, `needs-discussion`,
#     `architectural`, `architecture`, `infrastructure`) and `refactor` plus
#     breadth -- and NOTHING subsumes them. A labelled issue that also carries a
#     `bug` label or a reproduction satisfies the `small` arm on its own, so
#     deleting them outright drops it TWO rungs; `needs-discussion` on a short
#     `docs` body drops THREE, to `trivial`. These six are RE-TARGETED at
#     `medium` -- same predicate, new ceiling -- and emit `medium-label:*` /
#     `medium:cross-cutting-refactor`.
#
# L5 and L8 therefore pin the FLOOR those six establish, on a base body built to
# reach `small` on its own. That distinction is the whole point of the rows: an
# earlier cut of this change asserted label INERTNESS instead (same tier with and
# without the labels), which a correct classifier and a classifier that dropped
# the rules satisfy EQUALLY -- and which is how the two-rung downgrade shipped
# green. A floor assertion is red for exactly one of the two.

# L1 -- the vocabulary itself. Asserted on the MODULE, not on a classification:
# a leftover token no fixture happens to emit is still a token
# tests/triage-rule-vocabulary.py has to keep in lockstep with the validator.
python3 -I - "$TRIAGE" <<'PY_L1'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("solve_triage_under_test", sys.argv[1])
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)
assert st.TIERS == ("trivial", "small", "medium"), st.TIERS
leftover = sorted(token for token in st.TRIAGE_RULE_TOKENS if "large" in token)
assert not leftover, f"the deleted rung survives in the rule vocabulary: {leftover}"
assert not hasattr(st, "LARGE_LABELS"), "LARGE_LABELS survives the collapse"
# The five design labels did not go away with the rung -- they were re-pointed at
# it. A classifier that dropped them passes every `large`-shaped grep above while
# under-pricing every issue that carries one, so name the set here too.
assert st.DESIGN_LABELS == {"epic", "needs-discussion", "architectural",
                            "architecture", "infrastructure"}, st.DESIGN_LABELS
# `medium` is the ceiling, so it is also the highest escalation target. Compared
# as a SET: the retired `uberdev:tier-large` key aliases onto `medium` (L9), so
# the values list carries it twice by design.
assert sorted(set(st.ESCALATION_LABELS.values())) == ["medium", "small"], st.ESCALATION_LABELS
assert st.ESCALATION_LABELS[st.ESCALATION_LABEL_PREFIX + "large"] == "medium", st.ESCALATION_LABELS
PY_L1
PASS=$((PASS+1))

# L2 -- the CLI's tier vocabulary moved with it. `--floor large` used to be a
# legal clamp; accepting it now would hand lib/config-read.sh a tier with no
# rank, and uberdev_clamp_tier passes an unrankable clamp through in SILENCE --
# an operator's explicit floor would simply stop applying.
for L_FLAG in --floor --ceiling --override; do
  RC=0
  python3 -I "$TRIAGE" classify --snapshot "$FIX/trivial.json" "$L_FLAG" large \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
  if [ "$RC" -eq 0 ]; then
    echo "FAIL: classify $L_FLAG large was accepted — the collapsed rung is still a legal clamp" >&2
    exit 1
  fi
  grep -q 'expected trivial|small|medium$' "$TMP/err"
  PASS=$((PASS+1))
done

# L3 -- three declared change targets still price at the design rung. This is
# the arm that used to emit `large:three-files`; with the rule gone the tier has
# to fall out of the lighter arms' own file bounds, not out of a rule.
cat >"$TMP/collapse-three-files.json" <<'JSON'
{"number":20,"title":"Retry ceiling disagrees across copies","state":"OPEN","body":"Update lib/a.sh, lib/b.sh and lib/c.sh so the three retry ceilings agree.","labels":[{"name":"bug"}]}
JSON
assert_case "$TMP/collapse-three-files.json" medium
COLLAPSE_FILES="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/collapse-three-files.json")"
python3 - "$COLLAPSE_FILES" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["file_count"]==3, v
assert v["raw_tier"]=="medium", v
assert v["matched_rules"]==["medium:fallback"], v
PY
PASS=$((PASS+1))

# L4 -- a risk signal across components still prices at the design rung, for the
# same reason: `not risks` guards both lighter arms.
COLLAPSE_RISK="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/high-risk-cross-component.json")"
python3 - "$COLLAPSE_RISK" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["risk_signals"] and v["component_count"]>1, v
assert v["raw_tier"]=="medium", v
assert v["matched_rules"]==["medium:fallback"], v
PY
PASS=$((PASS+1))

# L5 -- the five design labels pin a FLOOR at the new ceiling. The base body is
# built to reach `small` ON ITS OWN (a `bug` label plus a reproduction), so the
# label is the only thing that can hold the issue higher: this row reds if the
# rule stops firing AND if it was deleted. A same-tier-with-and-without
# differential cannot do that -- see the section header.
python3 - "$TMP" <<'PY_L5'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
base = {"number": 21, "title": "Split the dispatcher", "state": "OPEN",
        "body": "The dispatcher grew three responsibilities and needs splitting. "
                "It fails today: expected one owner, actual three.",
        "assignees": [], "comments": []}
(tmp / "no-design-label.json").write_text(json.dumps(dict(base, labels=[{"name": "bug"}])))
for name in ("epic", "needs-discussion", "architectural", "architecture", "infrastructure"):
    (tmp / f"design-{name}.json").write_text(
        json.dumps(dict(base, labels=[{"name": "bug"}, {"name": name}])))
PY_L5
# The control FIRST: without a design label this body genuinely computes `small`.
# Without it the rows below would pass against a classifier that priced
# everything at the ceiling.
assert_case "$TMP/no-design-label.json" small
L_CONTROL="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/no-design-label.json")"
python3 - "$L_CONTROL" <<'PY_L5C'
import json, sys
v = json.loads(sys.argv[1])
assert v["matched_rules"] == ["small:concrete-reproduction"], v
PY_L5C
PASS=$((PASS+1))
for L_LABEL in epic needs-discussion architectural architecture infrastructure; do
  assert_case "$TMP/design-$L_LABEL.json" medium
  L_DESIGN="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/design-$L_LABEL.json")"
  python3 - "$L_DESIGN" "$L_LABEL" <<'PY_L5D'
import json, sys
v, label = json.loads(sys.argv[1]), sys.argv[2]
TIERS = ("trivial", "small", "medium")
assert TIERS.index(v["raw_tier"]) >= TIERS.index("medium"), (label, v)
assert f"medium-label:{label}" in v["matched_rules"], (label, v)
# Re-targeted, not renamed onto a rung that no longer exists.
assert not [r for r in v["matched_rules"] if "large" in r], (label, v)
PY_L5D
  PASS=$((PASS+1))
done

# L8 -- `refactor` plus real breadth pins the same floor, by either of the two
# routes that predicate has always had: >= 2 named components, or an explicit
# cross-cutting phrase. Same construction as L5 -- the base reaches `small` on
# its own, so only the rule can hold it at the design rung.
python3 - "$TMP" <<'PY_L8'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
base = {"number": 22, "title": "Straighten out error handling", "state": "OPEN",
        "assignees": [], "comments": [],
        "labels": [{"name": "refactor"}, {"name": "bug"}]}
(tmp / "refactor-components.json").write_text(json.dumps(dict(base,
    body="The dispatcher and scheduler modules disagree. It fails today: "
         "expected one convention, actual two.")))
(tmp / "refactor-cross-cutting.json").write_text(json.dumps(dict(base,
    body="This is a cross-cutting change. It fails today: expected one "
         "convention, actual two.")))
(tmp / "refactor-narrow.json").write_text(json.dumps(dict(base,
    body="The dispatcher module alone disagrees. It fails today: expected one "
         "convention, actual two.")))
PY_L8
for L_CASE in refactor-components refactor-cross-cutting; do
  assert_case "$TMP/$L_CASE.json" medium
  L_REFACTOR="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/$L_CASE.json")"
  python3 - "$L_REFACTOR" "$L_CASE" <<'PY_L8A'
import json, sys
v, case = json.loads(sys.argv[1]), sys.argv[2]
assert v["raw_tier"] == "medium", (case, v)
assert "medium:cross-cutting-refactor" in v["matched_rules"], (case, v)
PY_L8A
  PASS=$((PASS+1))
done
# The negative control: the `refactor` LABEL is not breadth on its own. Without
# this row the two above would pass against a rule that fired on the label alone,
# which would over-price every narrow cleanup in the backlog.
assert_case "$TMP/refactor-narrow.json" small
L_NARROW="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/refactor-narrow.json")"
python3 - "$L_NARROW" <<'PY_L8B'
import json, sys
v = json.loads(sys.argv[1])
assert v["component_count"] == 1, v
assert v["matched_rules"] == ["small:concrete-reproduction"], v
PY_L8B
PASS=$((PASS+1))

# L6 -- the one-way ratchet still works, and now tops out at `medium`. A
# retired `uberdev:tier-large` label aliases onto the new ceiling (L9), so beside
# a known `uberdev:tier-medium` it is redundant rather than contradictory -- and
# either way it must not suppress the highest label that IS known.
python3 - "$FIX/escalated-trivial.json" "$TMP/ceiling-tier.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=[{"name":"docs"},{"name":"uberdev:tier-small"},
             {"name":"uberdev:tier-large"},{"name":"uberdev:tier-medium"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/ceiling-tier.json" medium
CEILING_TIER="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/ceiling-tier.json")"
python3 - "$CEILING_TIER" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="medium", v
tokens=[r for r in v["matched_rules"] if r.startswith("escalation-label:")]
assert tokens==["escalation-label:medium"], tokens
PY
PASS=$((PASS+1))

# L7 -- and the rung below still escalates. Without this the collapse could be
# "satisfied" by an escalation channel that stopped working altogether: `medium`
# is the ceiling for the DISPATCHED tier, not a ban on moving up to it.
python3 - "$FIX/escalated-trivial.json" "$TMP/small-escalation.json" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"]=[{"name":"docs"},{"name":"uberdev:tier-small"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY
assert_case "$TMP/small-escalation.json" small
SMALL_ESC="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/small-escalation.json")"
python3 - "$SMALL_ESC" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
assert v["raw_tier"]=="small" and v["source"]=="computed", v
assert "escalation-label:small" in v["matched_rules"], v
assert "trivial:bounded-explicit-signal" in v["matched_rules"], v
PY
PASS=$((PASS+1))

# L9 -- a `uberdev:tier-large` label written by a PRE-#619 solver still lifts the
# issue, ALONE. This is the migration case L6 cannot see: L6 parks the retired
# name beside a live `uberdev:tier-medium`, so the tier is carried by the known
# label and the retired one could be dropped entirely with the row still green.
#
# It matters because the ratchet is a durable, one-way record. lib/solve-launcher.sh
# tells all four dispatch briefs to `gh label create uberdev:tier-<to> --force`
# and states "Nothing downgrades mid-task"; RFC 0019 records the channel as
# upgrade-only by construction. Any issue a solver escalated before this release
# still carries the retired name and nothing else, so treating it as an unknown
# tier would silently discard the recorded mis-triage and re-dispatch the issue at
# whatever its body computes -- `trivial`, for this fixture. A three-rung drop,
# with no audit row.
python3 - "$FIX/escalated-trivial.json" "$TMP/legacy-escalation.json" <<'PY_L9'
import json, pathlib, sys
v = json.loads(pathlib.Path(sys.argv[1]).read_text())
v["labels"] = [{"name": "docs"}, {"name": "uberdev:tier-large"}]
pathlib.Path(sys.argv[2]).write_text(json.dumps(v))
PY_L9
assert_case "$TMP/legacy-escalation.json" medium
LEGACY_ESC="$(python3 -I "$TRIAGE" classify --snapshot "$TMP/legacy-escalation.json")"
python3 - "$LEGACY_ESC" <<'PY_L9A'
import json, sys
v = json.loads(sys.argv[1])
assert v["raw_tier"] == "medium", v
# The alias resolves to the CEILING, so the token stays inside the declared
# vocabulary rather than naming a rung that no longer exists.
assert [r for r in v["matched_rules"] if r.startswith("escalation-label:")] \
    == ["escalation-label:medium"], v
assert not [r for r in v["matched_rules"] if "large" in r], v
# The computed signal survives beside it, exactly as for a live label.
assert "trivial:bounded-explicit-signal" in v["matched_rules"], v
PY_L9A
PASS=$((PASS+1))

# L10 (#606) -- the JUSTIFICATION beside the highest-only escalation emission,
# EXECUTED rather than asserted. The comment used to say that emitting one token
# per label "would be a dispatch failure rather than merely noisy". Nothing in
# the tree makes that true, and these rows are why:
#
#   L10a  both emitters dedupe with `dict.fromkeys(...)` on the statement BEFORE
#         they call assert_rule_tokens, so a duplicate token never reaches the
#         local validator at all;
#   L10b  the routing-context validator's duplicate check and length cap in
#         lib/agent-dispatch.sh read the ALREADY-deduped list this module
#         returns, so they cannot see one either;
#   L10c  and per-label emission could not reach that cap regardless -- after
#         #619 ESCALATION_LABELS spans two distinct tiers, so the worst case is
#         two tokens against a cap of 32. Inert duplicates, never a refusal.
#
# The prose row is DERIVED: the cap comes out of lib/agent-dispatch.sh and the
# tier span out of this module, so re-capping the validator or re-opening a rung
# reds this row rather than leaving a third retyped figure behind. That is the
# whole class -- #606 was a justification that named a mechanism which does not
# fire, and no row in this suite had ever read it.
python3 - "$TRIAGE" "$ROOT/plugins/uberdev/lib/agent-dispatch.sh" <<'PY_L10'
import importlib.util, pathlib, re, sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
dispatch = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
spec = importlib.util.spec_from_file_location("solve_triage_l10", sys.argv[1])
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
lines = source.splitlines()

# L10a -- the dedupe is the statement immediately before every validator call.
calls = [i for i, line in enumerate(lines)
         if "assert_rule_tokens(" in line and not line.lstrip().startswith("def ")]
assert len(calls) == 2, calls
for i in calls:
    assert "dict.fromkeys(" in lines[i - 1], (i, lines[i - 1])

# L10b -- and the routing-context validator reads that deduped list, so its own
# duplicate check and cap sit downstream of the dedupe, not upstream of it.
caps = re.findall(r"len\(rules\)>(\d+)", dispatch)
assert caps and len(set(caps)) == 1, caps
cap = int(caps[0])
assert "len(rules)!=len(set(rules))" in dispatch

# L10c -- the whole label vocabulary spans this many distinct tiers, so per-label
# emission adds at most this many tokens. Derived from the module, never typed.
span = len(set(st.ESCALATION_LABELS.values()))
assert span == 2, sorted(set(st.ESCALATION_LABELS.values()))
assert span < cap, (span, cap)

# L10d -- the comment states that reason, and no longer the refuted one. The
# contiguous block immediately above the highest-only selection.
anchor = [i for i, line in enumerate(lines) if "highest = max(labelled" in line]
assert len(anchor) == 1, anchor
i = anchor[0]; block = []
while i > 0 and lines[i - 1].lstrip().startswith("#"):
    i -= 1; block.append(lines[i])
# Anti-vacuity: a renamed selection line yields an EMPTY block, and every
# containment check below would then pass on nothing at all.
assert len(block) >= 3, block
comment = " ".join(re.sub(r"^\s*#\s?", "", line) for line in reversed(block))
comment = re.sub(r"\s+", " ", comment).strip()
assert "dispatch failure" not in comment, comment
for needle in ("dict.fromkeys", "assert_rule_tokens",
               "cap of %d" % cap, "%d distinct tiers" % span):
    assert needle in comment, (needle, comment)
PY_L10
PASS=$((PASS+1))

echo "solve-triage: $PASS passed"
