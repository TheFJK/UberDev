#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
DISPATCH="$ROOT/plugins/uberdev/lib/dispatch.sh"

[ -r "$SOURCE" ] || { echo "missing source agent-dispatch.sh" >&2; exit 1; }

# RETIRED SURFACE (#381). This block used to shell out to
# `model_routing.py resolve` and assert adaptive/inherit/forced parity, parent
# pair inheritance, and catalog-evidence fallback. The resolver CLI is deleted:
# no shipped backend owns the provider invocation, so there is no concrete pair
# to be at parity with. LOST COVERAGE, named: adaptive model/effort selection,
# forced-parent inheritance (`route_source == "forced-parent"`), and the
# availability fallback that stopped at the role/risk floor.
# What replaces it below is the true statement -- the resolver seam every
# backend actually reaches resolves backend-neutral, and refuses rather than
# fabricates when a request names something concrete.
python3 - "$ROOT" <<'PY'
import importlib.util, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
resolver = root / "plugins/uberdev/lib/model_routing.py"
spec = importlib.util.spec_from_file_location("routing", resolver)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
for gone in ("resolve_route", "fallback_route", "validate_catalog", "main"):
    assert not hasattr(module, gone), f"{gone} is still exported"
assert set(module.PUBLIC_API) == {"load_policy", "classify_minimum_route"}, module.PUBLIC_API
# The module is library-only now: invoking it as a CLI must not resolve anything.
probe = subprocess.run([sys.executable, str(resolver), "resolve"], text=True, capture_output=True)
assert probe.returncode == 0 and not probe.stdout.strip(), (probe.returncode, probe.stdout, probe.stderr)
PY

# Every backend the enum admits resolves backend-neutral through the one live
# seam, and a concrete request is refused with a typed code.
# shellcheck source=/dev/null
. "$SOURCE"
for backend in workflow wezterm background; do
  decision="$(uberdev_agent_resolve_request "{\"backend\":\"$backend\",\"workflow\":\"solve\",\"phase\":\"review\",\"role\":\"code-simplifier\",\"task_tier\":\"medium\",\"risk_signals\":[]}")" \
    || { echo "backend $backend failed to resolve" >&2; exit 1; }
  python3 - "$decision" "$backend" <<'PY'
import json, sys
decision = json.loads(sys.argv[1])
assert decision["backend"] == sys.argv[2], decision
assert decision["route_source"] == "backend-neutral-inherit", decision
assert decision["model"] is None and decision["reasoning_effort"] is None, decision
assert decision["logical_route"] is None and decision["forced"] is False, decision
assert decision["service_tier"] == "default" and decision["fallback_chain"] == [], decision
PY
done
for concrete in '"explicit_route":"sol-ultra"' '"explicit_model":"gpt-5.6-sol"' '"explicit_effort":"ultra"' '"routing_mode":"adaptive"' '"explicit_service_tier":"flex"'; do
  err="$(uberdev_agent_resolve_request "{\"backend\":\"workflow\",\"workflow\":\"solve\",\"phase\":\"review\",\"role\":\"code-simplifier\",\"task_tier\":\"medium\",\"risk_signals\":[],$concrete}" 2>&1 >/dev/null)" && {
    echo "expected refusal for $concrete" >&2; exit 1; }
  case "$err" in
    *route_unenforceable*) : ;;
    *) echo "expected route_unenforceable for $concrete, got: $err" >&2; exit 1 ;;
  esac
done

# The public solve dispatch must pass through the adapter, and the adapter's
# provider boundary must retain non-Codex arms without Codex-only argv.
grep -q 'uberdev_agent_dispatch' "$DISPATCH"
grep -q '_uberdev_dispatch_background' "$DISPATCH"
grep -q '_uberdev_dispatch_wezterm' "$DISPATCH"
grep -q 'UBERDEV_DISPATCH_ROUTING_MODE' "$DISPATCH"
grep -q 'UBERDEV_AGENT_RISK_SIGNALS_JSON' "$DISPATCH"
grep -q 'UBERDEV_AGENT_PARENT_RUN_JSON' "$DISPATCH"
grep -q 'UBERDEV_ROUTING_PROVENANCE_JSON' "$DISPATCH"

echo "dispatch-routing-parity: PASS"
