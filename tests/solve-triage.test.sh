#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIAGE="$ROOT/plugins/uberdev/lib/solve_triage.py"
FIX="$ROOT/tests/fixtures/solve-routing"
PASS=0
assert_case() {
  local fixture="$1" expected="$2"; shift 2
  local out
  out="$(python3 -I "$TRIAGE" classify --snapshot "$FIX/$fixture" "$@")"
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

# Bounds are reject-not-truncate, and malformed/closed/oversized snapshots fail.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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

echo "solve-triage: $PASS passed"
