#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
PACKAGED="$ROOT/codex/uberdev-codex/lib/agent-dispatch.sh"
DISPATCH="$ROOT/plugins/uberdev/lib/dispatch.sh"

[ -r "$SOURCE" ] || { echo "missing source agent-dispatch.sh" >&2; exit 1; }
[ -r "$PACKAGED" ] || { echo "missing packaged agent-dispatch.sh" >&2; exit 1; }
cmp -s "$SOURCE" "$PACKAGED" || { echo "agent-dispatch runtime copies drifted" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import json, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
resolver = root / "plugins/uberdev/lib/model_routing.py"
policy = root / "plugins/uberdev/policy/model-routing-v1.json"
catalog = root / "tests/fixtures/model-routing/catalog-gpt-5.6.json"

def resolve(request, selected_catalog=catalog):
    result = subprocess.run([
        sys.executable, str(resolver), "resolve", "--policy", str(policy),
        "--catalog", str(selected_catalog), "--input-json",
        json.dumps(request, sort_keys=True, separators=(",", ":")),
    ], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

base = {
    "backend": "codex", "workflow": "solve", "phase": "review",
    "role": "code-simplifier", "task_tier": "medium", "risk_signals": [],
}
adaptive = resolve({**base, "routing_mode": "adaptive"})
assert (adaptive["model"], adaptive["reasoning_effort"]) == ("gpt-5.6-sol", "medium")
inherit = resolve({**base, "routing_mode": "inherit"})
assert inherit["model"] is None and inherit["reasoning_effort"] is None
forced = resolve({**base, "explicit_route": "sol-ultra"})
assert forced["forced"] and (forced["model"], forced["reasoning_effort"]) == ("gpt-5.6-sol", "ultra")
child = resolve({**base, "parent_run": {
    "forced": True, "logical_route": forced["logical_route"],
    "model": forced["model"], "reasoning_effort": forced["reasoning_effort"],
}})
assert child["route_source"] == "forced-parent" and child["reasoning_effort"] == "ultra"

# Availability fallback is decided from catalog evidence before launch and
# never crosses the role/risk floor. Explicit pairs remain fail-closed.
with tempfile.TemporaryDirectory() as temporary:
    unavailable = json.loads(catalog.read_text())
    unavailable["available_pairs"] = [
        pair for pair in unavailable["available_pairs"]
        if not (pair["model"] == "gpt-5.6-sol" and pair["reasoning_effort"] == "max")
    ]
    path = pathlib.Path(temporary) / "catalog.json"
    path.write_text(json.dumps(unavailable))
    fallback = resolve({
        **base, "role": "trust-trail-evaluator", "routing_mode": "adaptive",
        "adaptive_fallback": True,
    }, path)
    assert fallback["logical_route"] == "deep", fallback
    assert fallback["minimum_route"] == "deep", fallback
PY

# The public solve dispatch must pass through the adapter, and the adapter's
# provider boundary must retain non-Codex arms without Codex-only argv.
grep -q 'uberdev_agent_dispatch' "$DISPATCH"
grep -q '_uberdev_dispatch_claude_bg' "$DISPATCH"
grep -q '_uberdev_dispatch_background' "$DISPATCH"
grep -q '_uberdev_dispatch_wezterm' "$DISPATCH"

echo "dispatch-routing-parity: PASS"
