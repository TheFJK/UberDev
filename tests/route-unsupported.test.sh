#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
PASS=0
for backend in wezterm background; do
  if uberdev_agent_resolve_request "{\"backend\":\"$backend\",\"workflow\":\"solve\",\"role\":\"lead\",\"task_tier\":\"small\",\"risk_signals\":[],\"explicit_route\":\"sol\"}" >/dev/null 2>"/tmp/route-unsupported.$$"; then
    echo "FAIL: $backend accepted concrete GPT route" >&2; exit 1
  fi
  grep -q route_unenforceable "/tmp/route-unsupported.$$"; PASS=$((PASS+1))
done
if uberdev_agent_resolve_request '{"backend":"background","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"adaptive"}' >/dev/null 2>"/tmp/route-unsupported.$$"; then
  echo "FAIL: adaptive routing silently inherited on a live backend" >&2; exit 1
fi
grep -q route_unenforceable "/tmp/route-unsupported.$$"; PASS=$((PASS+1))
rm -f "/tmp/route-unsupported.$$"
# #381: the `--effort=ultra` refusal is LIVE but its diagnostic was reworded.
# It used to read 'ultra is Codex-only' and was conditional on the resolved
# backend NOT being codex. `ultra` was an exact Codex route field with no Claude
# equivalent, so deleting the transport did not make it resolvable -- it made it
# unresolvable everywhere, and the refusal became unconditional
# (lib/solve-launcher.sh:669-673). Assert the guard that actually ships.
grep -q 'error: --effort=ultra has no provider on any surviving backend' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"; PASS=$((PASS+1))
# RETIRED SURFACE: nothing outside a comment may name the transport again --
# a re-introduced `codex` arm here is how the refusal would silently become
# conditional a second time.
! grep -qE '^[^#]*\bcodex\b' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"; PASS=$((PASS+1))
grep -q 'no claims written; no agents dispatched' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"; PASS=$((PASS+1))
echo "route-unsupported: $PASS passed"
