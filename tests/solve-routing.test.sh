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
  # shellcheck source=/dev/null
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_dispatch_prepare_root 42 large '["security"]' turbo
) >"$TMP/prepared.json"
python3 - "$TMP/prepared.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r["workflow"]=="turbo" and r["issue_num"]==42 and r["task_tier"]=="large"
assert r["risk_signals"]==["security"]
assert pathlib.Path(r["context_file"]).is_file() and len(r["context_sha256"])==64
assert r["root_decision"]["backend"]=="codex"
PY
PASS=$((PASS+1))

cmp "$ROOT/plugins/uberdev/lib/dispatch.sh" "$ROOT/codex/uberdev-codex/lib/dispatch.sh"
cmp "$ROOT/plugins/uberdev/lib/solve-launcher.sh" "$ROOT/codex/uberdev-codex/lib/solve-launcher.sh"
cmp "$ROOT/plugins/uberdev/lib/solve_triage.py" "$ROOT/codex/uberdev-codex/lib/solve_triage.py"
PASS=$((PASS+3))

echo "solve-routing: $PASS passed"
