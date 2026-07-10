#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
PASS=0
for backend in claude-bg wezterm background; do
  if uberdev_agent_resolve_request "{\"backend\":\"$backend\",\"workflow\":\"solve\",\"role\":\"lead\",\"task_tier\":\"small\",\"risk_signals\":[],\"explicit_route\":\"sol\"}" >/dev/null 2>"/tmp/route-unsupported.$$"; then
    echo "FAIL: $backend accepted concrete GPT route" >&2; exit 1
  fi
  grep -q route_unenforceable "/tmp/route-unsupported.$$"; PASS=$((PASS+1))
done
if uberdev_agent_resolve_request '{"backend":"background","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"adaptive"}' >/dev/null 2>"/tmp/route-unsupported.$$"; then
  echo "FAIL: non-Codex adaptive silently inherited" >&2; exit 1
fi
grep -q route_unenforceable "/tmp/route-unsupported.$$"; PASS=$((PASS+1))
rm -f "/tmp/route-unsupported.$$"
grep -q 'ultra is Codex-only' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"; PASS=$((PASS+1))
grep -q 'no claims written; no agents dispatched' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"; PASS=$((PASS+1))
echo "route-unsupported: $PASS passed"
