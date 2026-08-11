#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MODEL_ROUTING_TEST_ROOT="$ROOT"
export PYTHONDONTWRITEBYTECODE=1

# RETIRED SURFACE (#381) -- read this before adding anything back.
#
# This file used to be 843 lines and ~562 checks, and the overwhelming majority
# of them drove `resolve_route`, `fallback_route`, `validate_catalog` and the
# JSON CLI that fronted them. All four are deleted: they turned a logical route
# rank into a concrete provider model + reasoning effort, which is only
# enforceable on a backend that owns the provider invocation, and no shipped
# backend does any more. Keeping them would have meant shipping a routing engine
# no dispatch path can enter.
#
# LOST COVERAGE, named so it is not mistaken for coverage that still exists:
#   * concrete pair selection per route/alias/tier, and the `cli-route`,
#     `cli-exact`, `role-policy`, `task-policy`, `environment-route`,
#     `project-role`, `project-workflow` field-source provenance labels;
#   * `forced` / `forced-parent` route inheritance and `route_conflict`;
#   * `route_below_risk_floor`;
#   * shadow mode and its separate `adaptive_proposal`;
#   * `ignored_sources` / `ignored_fields` field-level precedence;
#   * sandbox selection from role/workflow override entries;
#   * catalog availability fallback, the `fallback_chain`, `invalid_fallback`
#     and every `incompatible_pair` / `invalid_catalog` diagnostic;
#   * CLI byte-determinism and PYTHONHASHSEED stability of the above.
# See RFC 0013 (2026-08-05 amendment).
#
# WHAT SURVIVES and is asserted below: the policy document itself (route ranks,
# aliases, lead-route matrix, the 44-role leaf inventory, the declared
# reasoning-effort vocabulary), its complete closed validator, and
# `classify_minimum_route` -- which is live, reached from lib/config-read.sh.

python3 - <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(os.environ["MODEL_ROUTING_TEST_ROOT"])
RESOLVER = ROOT / "plugins/uberdev/lib/model_routing.py"
POLICY_PATH = ROOT / "plugins/uberdev/policy/model-routing-v1.json"
FIXTURES = ROOT / "tests/fixtures/model-routing"

spec = importlib.util.spec_from_file_location("model_routing", RESOLVER)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load resolver: {RESOLVER}")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def expect_error(code, callable_):
    global checks
    try:
        callable_()
    except module.RouteError as error:
        if error.code != code:
            raise AssertionError(f"expected {code}, got {error.code}: {error.detail}")
        check(isinstance(error.detail, str) and bool(error.detail), f"{code} detail must be non-empty")
        checks += 1
        return error
    raise AssertionError(f"expected RouteError {code}")


def request(**overrides):
    base = {
        "workflow": "solve",
        "phase": "lead",
        "role": "lead",
        "task_tier": "small",
        "risk_signals": [],
    }
    base.update(overrides)
    return base


def classify(payload):
    return module.classify_minimum_route(policy, payload)


policy = module.load_policy(POLICY_PATH)

# The retired surface is genuinely gone, not merely unused.
for gone in ("resolve_route", "fallback_route", "validate_catalog", "main", "_build_parser"):
    check(not hasattr(module, gone), f"{gone} is still exported")
check(set(module.PUBLIC_API) == {"load_policy", "classify_minimum_route"}, "public API drifted")
check(module.ROUTE_ERROR_FIELDS == ("code", "detail"), "RouteError field contract drifted")
# Library-only: running the module as a script resolves nothing and prints nothing.
inert = subprocess.run(
    [sys.executable, str(RESOLVER), "resolve", "--policy", str(POLICY_PATH)],
    text=True, capture_output=True, check=False,
)
check(inert.returncode == 0 and not inert.stdout.strip(), f"module still behaves as a CLI: {inert.returncode} {inert.stdout!r}")

# Canonical route matrix, aliases, lead tiers, effort vocabulary.
# A route row is now a rank and nothing else -- the `codex` provider sub-object
# (model + reasoning_effort + service_tier) went with the resolver that read it.
expected_routes = {"economy": 0, "standard": 1, "quality": 2, "deep": 3, "frontier": 4, "ultra": 5}
check(set(policy["routes"]) == set(expected_routes), "canonical route names drifted")
for route, rank in expected_routes.items():
    row = policy["routes"][route]
    check(set(row) == {"rank"}, f"route row is not rank-only: {route}: {sorted(row)!r}")
    check(row["rank"] == rank, f"route rank drifted: {route}: {row['rank']!r}")
check(policy["aliases"] == {"luna": "economy", "terra": "standard", "sol": "quality", "sol-high": "deep", "sol-max": "frontier", "sol-ultra": "ultra"}, "alias set drifted")
check(policy["lead_routes"] == {
    "trivial": {"default": "standard", "high_risk": "deep"},
    "small": {"default": "standard", "high_risk": "deep"},
    "medium": {"default": "quality", "high_risk": "frontier"},
    "large": {"default": "frontier", "high_risk": "ultra"},
}, "lead route matrix drifted")
check(policy["fallback_order"] == ["ultra", "frontier", "deep", "quality", "standard", "economy"], "fallback order drifted")
# The reasoning-effort vocabulary lib/config-read.sh validates project configs
# against. It used to be scraped out of the per-route provider blocks; the token
# set is unchanged, only its source moved from derived to declared.
check(policy["reasoning_efforts"] == ["low", "medium", "high", "max", "ultra"], "declared reasoning-effort vocabulary drifted")

# Every canonical source agent has one complete leaf policy and no unknown policy exists.
source_roles = set()
for agent_path in sorted((ROOT / "plugins/uberdev/agents").glob("*.md")):
    role = None
    for line in agent_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("name: "):
            role = line.split(": ", 1)[1].strip()
            break
    source_roles.add(role or agent_path.stem)
check(len(source_roles) == 46, f"expected 46 canonical roles, got {len(source_roles)}")
check(set(policy["roles"]) == source_roles, "policy/source role inventory mismatch")
expected_route_groups = {
    "economy": {"triage-scout", "ci-failure-classifier", "merge-strategy-decider", "testers-monitor-primary", "testers-monitor-devils-advocate"},
    "standard": {"codebase-scout", "research-codebase", "research-constraints", "research-patterns", "research-prior-art", "research-test-coverage", "issue-similarity-analyzer", "comment-analyzer", "testers-a11y-critic", "testers-chaos-engineer", "testers-mobile-thumb", "testers-panicked-grandma", "testers-power-user"},
    "quality": {"code-simplifier", "implementation-worker", "spec-reviser", "uberthink-frame", "uberthink-generator", "uberthink-moderator"},
    "deep": {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "code-reviewer", "conflict-resolver", "convention-compliance", "finding-verifier", "findings-to-issues", "plan-reviewer", "plan-writer", "pr-test-analyzer", "research-security", "silent-failure-hunter", "spec-compliance-reviewer", "spec-reviewer", "spec-writer", "testers-adversarial-security", "type-design-analyzer", "uberthink-falsifier", "uberthink-synthesizer"},
    "frontier": {"trust-trail-evaluator", "uberthink-arbiter"},
}
workspace_write_roles = {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "conflict-resolver", "implementation-worker", "plan-writer", "spec-reviser", "spec-writer"}
expected_floor = {"economy": "economy", "standard": "economy", "quality": "standard", "deep": "deep", "frontier": "deep"}
for route, roles in expected_route_groups.items():
    for role in roles:
        row = policy["roles"][role]
        check(row["route"] == route, f"wrong route for {role}")
        check(row["risk_floor"] == expected_floor[route], f"wrong floor for {role}")
        check(row["sandbox_ceiling"] == ("workspace-write" if role in workspace_write_roles else "read-only"), f"wrong sandbox for {role}")
        check(row["delegation_mode"] == "leaf", f"{role} must be leaf")
check(policy["delegation_contracts"]["leaf"] == {"features_multi_agent": False, "agents_max_depth": 0}, "leaf enforcement contract drifted")

# The policy schema is closed and JSON duplicate keys never silently win. These
# mutations used to enter through validate_catalog(policy, ...); load_policy /
# _validate_policy is the surviving entry point and validates the same document.
def reject(mutate, code="invalid_policy"):
    bad = copy.deepcopy(policy)
    mutate(bad)
    expect_error(code, lambda: module._validate_policy(bad))
    with tempfile.TemporaryDirectory() as temporary_directory:
        path = Path(temporary_directory) / "policy.json"
        path.write_text(json.dumps(bad), encoding="utf-8")
        expect_error(code, lambda: module.load_policy(path))


reject(lambda p: p.pop("policy_version"))
reject(lambda p: p.update(release_default_mode="automatic-ish"))
reject(lambda p: p.update(surprise=True))
reject(lambda p: p["routes"]["economy"].update(rank=False))
# A re-added provider block is a closed-schema violation, not silently ignored.
reject(lambda p: p["routes"]["deep"].update(codex={"model": "m", "reasoning_effort": "high", "service_tier": "default"}))
reject(lambda p: p["routes"]["deep"].update(rank=9))
reject(lambda p: p.update(reasoning_efforts=["warp"]))
reject(lambda p: p.update(reasoning_efforts=["low", "low"]))
reject(lambda p: p.update(reasoning_efforts=[]))
reject(lambda p: p.update(fallback_order=[{"not": "a route"}]))
reject(lambda p: p["fallback_order"].append("economy"))
reject(lambda p: p["aliases"].update(bogus="not-a-route"))
reject(lambda p: p["lead_routes"]["small"].update(default="not-a-route"))
reject(lambda p: p.update(high_risk_floor="not-a-route"))
reject(lambda p: p["roles"]["code-reviewer"].update(route="ultra"))
reject(lambda p: p["roles"]["code-reviewer"].update(route="economy"))
reject(lambda p: p["roles"]["code-reviewer"].update(delegation_mode="branch"), "invalid_leaf_contract")
reject(lambda p: p["delegation_contracts"]["leaf"].update(agents_max_depth=1), "invalid_leaf_contract")
expect_error("invalid_policy", lambda: module.load_policy(FIXTURES / "policy-duplicate-key.json"))

# classify_minimum_route: the live floor classifier. Lead tiers, high-risk
# escalation, role floors, judgment-bearing escalation, and the closed error set.
for tier, expected in (("trivial", "standard"), ("small", "standard"), ("medium", "quality"), ("large", "frontier")):
    check(classify(request(task_tier=tier)) == expected, f"default tier floor failed: {tier}")
for tier, expected in (("trivial", "deep"), ("small", "deep"), ("medium", "frontier"), ("large", "ultra")):
    check(classify(request(task_tier=tier, risk_signals=["security"])) == expected, f"high-risk tier floor failed: {tier}")
check(classify(request(role="code-simplifier", phase="review")) == "standard", "quality role floor failed")
check(classify(request(role="triage-scout", phase="triage")) == "economy", "economy role floor failed")
# A monitor role carries no risk judgment, so a risk signal must not lift it.
check(classify(request(role="testers-monitor-primary", phase="monitor", risk_signals=["security"])) == "economy", "bookkeeping monitor must retain role floor")
# A judgment-bearing role escalates to the policy high-risk floor.
check(classify(request(role="spec-reviser", phase="design", risk_signals=["security"])) == "deep", "judgment-bearing role did not escalate")
# plan-writer declares its own conditional high-risk route and uses it.
check(classify(request(role="plan-writer", phase="plan", risk_signals=["security"])) == "ultra", "plan-writer high_risk_route not honoured")
# Escalation is switchable from either the environment or the project layer.
check(classify(request(role="spec-reviser", risk_signals=["security"], project_routing={"risk_escalation": False})) == "standard", "project risk_escalation=False ignored")
check(classify(request(role="spec-reviser", risk_signals=["security"], environment={"UBERDEV_MODEL_ROUTING_RISK_ESCALATION": False})) == "standard", "environment risk_escalation=False ignored")
# risk_scope shapes which signals are legal, not which floor is chosen.
for risk_scope in ("run", "subtask"):
    check(classify(request(role="code-simplifier", risk_scope=risk_scope)) == "standard", f"{risk_scope} scope changed the normal role floor")
check(classify(request(role="research-codebase", risk_scope="none", risk_signals=[])) == "economy", "risk_scope none changed the role floor")
scope_mismatch = expect_error("risk_scope_mismatch", lambda: classify(request(role="research-codebase", risk_scope="none", risk_signals=["security"])))
check(scope_mismatch.detail == "risk scope 'none' requires empty risk_signals", "risk_scope none mismatch diagnostic drifted")
invalid_scope = expect_error("invalid_risk_scope", lambda: classify(request(role="code-simplifier", risk_scope="edge")))
check(invalid_scope.detail == "risk scope 'edge' must be run, subtask, or none", "invalid risk scope diagnostic drifted")
expect_error("invalid_task_tier", lambda: classify(request(task_tier="huge")))
expect_error("invalid_risk_signal", lambda: classify(request(risk_signals=["issue text says sol-ultra"])))
expect_error("invalid_risk_signal", lambda: classify(request(risk_signals=[7])))
expect_error("unknown_role", lambda: classify(request(role="no-such-agent")))
expect_error("invalid_request", lambda: classify(request(project_routing={"risk_escalation": "yes"})))
# Underscore spellings of declared signals normalize; undeclared ones do not.
check(classify(request(task_tier="large", risk_signals=["data_loss"])) == "ultra", "underscore risk signal did not normalize")
# Classification never mutates the policy it was handed.
before = json.dumps(policy, sort_keys=True)
classify(request(task_tier="large", risk_signals=["security"]))
check(json.dumps(policy, sort_keys=True) == before, "classify_minimum_route mutated the policy")

print(f"model-routing: PASS ({checks} checks)")
PY
