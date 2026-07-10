#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/plugins/uberdev/lib/solve_triage.py"
PASS=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
parse() { python3 -I "$TOOL" parse-cli "$@"; }
expect_ok() {
  local out="$1" expr="$2"
  python3 - "$out" "$expr" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert eval(sys.argv[2],{}, {"v":v}),v
PY
  PASS=$((PASS+1))
}
expect_bad() {
  local needle="$1"; shift
  if parse "$@" > /tmp/solve-routing-out.$$ 2>/tmp/solve-routing-err.$$; then echo "FAIL accepted: $*" >&2; exit 1; fi
  grep -q "$needle" /tmp/solve-routing-err.$$
  rm -f /tmp/solve-routing-{out,err}.$$
  PASS=$((PASS+1))
}

OUT="$(parse 9 3 9 --routing-mode=adaptive --service-tier=fast)"
expect_ok "$OUT" 'v["issues"]==[9,3] and v["routing_mode"]=="adaptive" and v["service_tier"]=="fast"'
OUT="$(parse --backend=codex 9)"
expect_ok "$OUT" 'v["issues"]==[9] and v["backend"]=="codex"'
OUT="$(parse 1 --route=sol-ultra --fast)"
expect_ok "$OUT" 'v["route"]=="sol-ultra" and v["service_tier"]=="fast"'
OUT="$(parse 1 --fast --service-tier=fast)"
expect_ok "$OUT" 'v["service_tier"]=="fast"'
OUT="$(parse 1 --model=gpt-5.6-sol --effort=ultra --backend=codex)"
expect_ok "$OUT" 'v["model"]=="gpt-5.6-sol" and v["effort"]=="ultra"'

expect_bad routing_cli_duplicate 1 --route=sol --route=terra
expect_bad routing_cli_duplicate 1 --fast --fast
expect_bad routing_cli_conflict 1 --routing-mode=adaptive --route=sol
expect_bad routing_cli_conflict 1 --route=sol --effort=high
expect_bad routing_cli_conflict 1 --fast --service-tier=default
expect_bad routing_cli_invalid 1 --route=made-up
expect_bad routing_cli_invalid 1 --effort=extreme
expect_bad routing_cli_invalid 1 --service-tier=premium
expect_bad routing_cli_invalid 1 --routing-mode=shadow
expect_bad routing_cli_invalid 0
expect_bad routing_cli_unrecognized 1 --rout=sol

# Contract is visibly threaded through the executable launcher, not docs only.
grep -q 'solve_triage.py' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'parse-cli' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'UBERDEV_DISPATCH_ROUTING_MODE' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'no claims written; no agents dispatched' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
PASS=$((PASS+4))

# Root preparation resolves through the shared adapter and persists a verified
# context without invoking a provider.
RUN="$TMP/run"; mkdir -p "$RUN"
(
  export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" UBERDEV_TMPDIR="$RUN"
  export UBERDEV_RESOLVED_BACKEND=codex UBERDEV_DISPATCH_ROUTING_MODE=adaptive
  export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{"routing_mode":"inherit","issue_num":999}'
  # shellcheck source=/dev/null
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_dispatch_prepare_root 42 large '["security"]' turbo '{"schema_version":1,"issue":42,"raw_tier":"large","clamped_tier":"large","effective_tier":"large","tier":"large","source":"computed","matched_rules":["large-label:architectural","large:multi-component-high-risk"],"risk_signals":["security"],"files":["auth/a.py","api/b.py"],"components":["auth/a.py","api/b.py"]}'
) >"$TMP/prepared.json"
python3 - "$TMP/prepared.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r["workflow"]=="turbo" and r["issue_num"]==42 and r["task_tier"]=="large"
assert r["risk_signals"]==["security"]
assert pathlib.Path(r["context_file"]).is_file() and len(r["context_sha256"])==64
assert r["root_decision"]["backend"]=="codex"
context=json.loads(pathlib.Path(r["context_file"]).read_text())
triage=context["metadata"]["triage_decision"]
assert triage["matched_rules"]==["large-label:architectural","large:multi-component-high-risk"]
assert triage["raw_tier"]==triage["clamped_tier"]==triage["effective_tier"]=="large"
PY
PASS=$((PASS+1))

cmp "$ROOT/plugins/uberdev/lib/dispatch.sh" "$ROOT/codex/uberdev-codex/lib/dispatch.sh"
cmp "$ROOT/plugins/uberdev/lib/solve-launcher.sh" "$ROOT/codex/uberdev-codex/lib/solve-launcher.sh"
cmp "$ROOT/plugins/uberdev/lib/solve_triage.py" "$ROOT/codex/uberdev-codex/lib/solve_triage.py"
PASS=$((PASS+3))

# Default shared /tmp gets a private owned launch root; classification and
# context creation complete before the deliberately failing claim write.
FAKE="$TMP/bin"; mkdir "$FAKE"
cat >"$FAKE/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") printf '%s\n' 'owner/repo' ;;
  "issue view") printf '%s\n' '{"number":77,"title":"README typo","state":"OPEN","body":"Fix typo in README.md.","labels":[{"name":"docs"}],"assignees":[],"comments":[]}' ;;
  "label create") echo claim-write-attempt >>"$GH_MUTATIONS"; exit 1 ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
SH
cat >"$FAKE/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE/gh" "$FAKE/codex"
SHARED_TMP="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
BEFORE="$(find "$SHARED_TMP" -maxdepth 1 -type d -name "uberdev-solve-$(id -u)-*" 2>/dev/null | sort)"
set +e
PATH="$FAKE:$PATH" GH_MUTATIONS="$TMP/mutations" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 77 --backend=codex --routing-mode=adaptive >"$TMP/launch.out" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ]; grep -q "failed to provision" "$TMP/launch.out"; [ "$(cat "$TMP/mutations")" = claim-write-attempt ]
AFTER="$(find "$SHARED_TMP" -maxdepth 1 -type d -name "uberdev-solve-$(id -u)-*" 2>/dev/null | sort)"
NEW_ROOT="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | tail -1)"
[ -n "$NEW_ROOT" ]; python3 - "$NEW_ROOT" <<'PY'
import os,stat,sys
e=os.stat(sys.argv[1],follow_symlinks=False); assert e.st_uid==os.geteuid() and stat.S_IMODE(e.st_mode)==0o700
PY
find "$NEW_ROOT/.agent-state-$(id -u)" -name 'route-context-v1-*.json' -type f | grep -q .
[ ! -e /tmp/solve-validate-77.json ]
rm -rf "$NEW_ROOT"
PASS=$((PASS+1))

echo "solve-routing: $PASS passed"
