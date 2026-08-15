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

# One file path is one component; explicit extensionless module lists count.
ONE="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/small.json")"
python3 - "$ONE" <<'PY'
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

echo "solve-triage: $PASS passed"
