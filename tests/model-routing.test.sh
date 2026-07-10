#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MODEL_ROUTING_TEST_ROOT="$ROOT"
export PYTHONDONTWRITEBYTECODE=1

python3 - <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(os.environ["MODEL_ROUTING_TEST_ROOT"])
RESOLVER = ROOT / "plugins/uberdev/lib/model_routing.py"
POLICY_PATH = ROOT / "plugins/uberdev/policy/model-routing-v1.json"
FIXTURES = ROOT / "tests/fixtures/model-routing"
CATALOG_PATH = FIXTURES / "catalog-gpt-5.6.json"

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


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


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
        "backend": "codex",
        "workflow": "solve",
        "phase": "lead",
        "role": "lead",
        "task_tier": "small",
        "risk_signals": [],
        "routing_mode": "adaptive",
    }
    base.update(overrides)
    return base


def resolve(payload, catalog=None):
    return module.resolve_route(policy, catalog or catalog_valid, payload)


def cli(command, payload=None, catalog_path=CATALOG_PATH):
    args = [
        sys.executable,
        str(RESOLVER),
        command,
        "--policy",
        str(POLICY_PATH),
        "--catalog",
        str(catalog_path),
    ]
    if payload is not None:
        args.extend(["--input-json", json.dumps(payload, sort_keys=True, separators=(",", ":"))])
    return subprocess.run(args, text=True, capture_output=True, check=False)


def cli_raw(command, raw, policy_path=POLICY_PATH, catalog_path=CATALOG_PATH):
    return subprocess.run(
        [
            sys.executable,
            str(RESOLVER),
            command,
            "--policy",
            str(policy_path),
            "--catalog",
            str(catalog_path),
            "--input-json",
            raw,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


policy = module.load_policy(POLICY_PATH)
catalog_valid = read_json(CATALOG_PATH)
catalog_unavailable = read_json(FIXTURES / "catalog-unavailable.json")
catalog_mini_ultra = read_json(FIXTURES / "catalog-mini-ultra.json")
module.validate_catalog(policy, catalog_valid)
checks += 1

# Canonical route matrix, aliases, lead tiers, and API contract.
expected_routes = {
    "economy": (0, "gpt-5.6-luna", "low", "default"),
    "standard": (1, "gpt-5.6-terra", "medium", "default"),
    "quality": (2, "gpt-5.6-sol", "medium", "default"),
    "deep": (3, "gpt-5.6-sol", "high", "default"),
    "frontier": (4, "gpt-5.6-sol", "max", "default"),
    "ultra": (5, "gpt-5.6-sol", "ultra", "default"),
}
check(set(policy["routes"]) == set(expected_routes), "canonical route names drifted")
for route, expected in expected_routes.items():
    row = policy["routes"][route]
    actual = (row["rank"], row["codex"]["model"], row["codex"]["reasoning_effort"], row["codex"]["service_tier"])
    check(actual == expected, f"route row drifted: {route}: {actual!r}")
check(policy["aliases"] == {"luna": "economy", "terra": "standard", "sol": "quality", "sol-high": "deep", "sol-max": "frontier", "sol-ultra": "ultra"}, "alias set drifted")
check(policy["lead_routes"] == {
    "trivial": {"default": "standard", "high_risk": "deep"},
    "small": {"default": "standard", "high_risk": "deep"},
    "medium": {"default": "quality", "high_risk": "frontier"},
    "large": {"default": "frontier", "high_risk": "ultra"},
}, "lead route matrix drifted")
check(set(module.PUBLIC_API) == {"load_policy", "validate_catalog", "classify_minimum_route", "resolve_route", "fallback_route"}, "public API drifted")
check(module.ROUTE_ERROR_FIELDS == ("code", "detail"), "RouteError field contract drifted")

# Every canonical source agent has one complete leaf policy and no unknown policy exists.
source_roles = set()
for agent_path in sorted((ROOT / "plugins/uberdev/agents").glob("*.md")):
    role = None
    for line in agent_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("name: "):
            role = line.split(": ", 1)[1].strip()
            break
    source_roles.add(role or agent_path.stem)
check(len(source_roles) == 42, f"expected 42 canonical roles, got {len(source_roles)}")
check(set(policy["roles"]) == source_roles, "policy/source role inventory mismatch")
expected_route_groups = {
    "economy": {"triage-scout", "ci-failure-classifier", "merge-strategy-decider", "testers-monitor-primary", "testers-monitor-devils-advocate"},
    "standard": {"codebase-scout", "research-codebase", "research-constraints", "research-patterns", "research-prior-art", "research-test-coverage", "issue-similarity-analyzer", "comment-analyzer", "testers-a11y-critic", "testers-chaos-engineer", "testers-mobile-thumb", "testers-panicked-grandma", "testers-power-user"},
    "quality": {"code-simplifier", "spec-reviser", "uberthink-frame", "uberthink-generator", "uberthink-moderator"},
    "deep": {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "code-reviewer", "conflict-resolver", "findings-to-issues", "plan-reviewer", "plan-writer", "pr-test-analyzer", "research-security", "silent-failure-hunter", "spec-reviewer", "spec-writer", "testers-adversarial-security", "type-design-analyzer", "uberthink-falsifier", "uberthink-synthesizer"},
    "frontier": {"trust-trail-evaluator", "uberthink-arbiter"},
}
workspace_write_roles = {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "conflict-resolver", "plan-writer", "spec-reviser", "spec-writer"}
expected_floor = {"economy": "economy", "standard": "economy", "quality": "standard", "deep": "deep", "frontier": "deep"}
for route, roles in expected_route_groups.items():
    for role in roles:
        row = policy["roles"][role]
        check(row["route"] == route, f"wrong route for {role}")
        check(row["risk_floor"] == expected_floor[route], f"wrong floor for {role}")
        check(row["sandbox_ceiling"] == ("workspace-write" if role in workspace_write_roles else "read-only"), f"wrong sandbox for {role}")
        check(row["delegation_mode"] == "leaf", f"{role} must be leaf")
check(policy["delegation_contracts"]["leaf"] == {"features_multi_agent": False, "agents_max_depth": 0}, "leaf enforcement contract drifted")

# Policy/catalog schemas are closed and JSON duplicate keys never silently win.
missing_metadata = copy.deepcopy(policy)
missing_metadata.pop("policy_version")
expect_error("invalid_policy", lambda: module.validate_catalog(missing_metadata, catalog_valid))
bad_default_mode = copy.deepcopy(policy)
bad_default_mode["release_default_mode"] = "automatic-ish"
expect_error("invalid_policy", lambda: module.validate_catalog(bad_default_mode, catalog_valid))
bool_policy_rank = copy.deepcopy(policy)
bool_policy_rank["routes"]["economy"]["rank"] = False
expect_error("invalid_policy", lambda: module.validate_catalog(bool_policy_rank, catalog_valid))
bool_catalog_rank = copy.deepcopy(catalog_valid)
bool_catalog_rank["ranked_pairs"][0]["rank"] = False
expect_error("invalid_catalog", lambda: module.validate_catalog(policy, bool_catalog_rank))
null_availability = copy.deepcopy(catalog_valid)
null_availability["available_pairs"] = None
expect_error("invalid_catalog", lambda: module.validate_catalog(policy, null_availability))
duplicate_policy_pair = copy.deepcopy(policy)
duplicate_policy_pair["routes"]["standard"]["codex"]["model"] = "gpt-5.6-luna"
duplicate_policy_pair["routes"]["standard"]["codex"]["reasoning_effort"] = "low"
expect_error("invalid_policy", lambda: module.validate_catalog(duplicate_policy_pair, catalog_valid))
duplicate_catalog_pair = copy.deepcopy(catalog_valid)
duplicate_catalog_pair["ranked_pairs"][1]["model"] = "gpt-5.6-luna"
duplicate_catalog_pair["ranked_pairs"][1]["reasoning_effort"] = "low"
expect_error("incompatible_pair", lambda: module.validate_catalog(policy, duplicate_catalog_pair))
malformed_fallback_order = copy.deepcopy(policy)
malformed_fallback_order["fallback_order"] = [{"not": "a route"}]
expect_error("invalid_policy", lambda: module.validate_catalog(malformed_fallback_order, catalog_valid))
duplicate_fallback_order = copy.deepcopy(policy)
duplicate_fallback_order["fallback_order"].append("economy")
expect_error("invalid_policy", lambda: module.validate_catalog(duplicate_fallback_order, catalog_valid))
expect_error("invalid_policy", lambda: module.load_policy(FIXTURES / "policy-duplicate-key.json"))
duplicate_catalog = cli("validate-catalog", catalog_path=FIXTURES / "catalog-duplicate-key.json")
check(duplicate_catalog.returncode == 2 and json.loads(duplicate_catalog.stderr)["error"]["code"] == "invalid_catalog", "duplicate catalog key was not rejected deterministically")
duplicate_input = cli_raw(
    "resolve",
    '{"backend":"codex","backend":"claude","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"adaptive"}',
)
check(duplicate_input.returncode == 2 and json.loads(duplicate_input.stderr)["error"]["code"] == "invalid_request", "duplicate request key was not rejected deterministically")

# All declared aliases and all task tiers resolve exactly.
for alias, logical in policy["aliases"].items():
    decision = resolve(request(role="triage-scout", phase="triage", explicit_route=alias, routing_mode=None))
    check(decision["logical_route"] == logical and decision["forced"] is True, f"alias failed: {alias}")
    check(decision["field_sources"]["model"] == "cli-route", f"alias provenance failed: {alias}")
expect_error("unknown_route", lambda: resolve(request(explicit_route="Sol Ultra", routing_mode=None)))
for tier, expected in (("trivial", "standard"), ("small", "standard"), ("medium", "quality"), ("large", "frontier")):
    decision = resolve(request(task_tier=tier))
    check(decision["logical_route"] == expected, f"default tier route failed: {tier}")
    check(decision["minimum_route"] == expected, f"default tier floor failed: {tier}")
for tier, expected in (("trivial", "deep"), ("small", "deep"), ("medium", "frontier"), ("large", "ultra")):
    decision = resolve(request(task_tier=tier, risk_signals=["security"]))
    check(decision["logical_route"] == expected, f"high-risk tier route failed: {tier}")
    check(decision["minimum_route"] == expected, f"high-risk tier floor failed: {tier}")
check(module.classify_minimum_route(policy, request(task_tier="large", risk_signals=["security"])) == "ultra", "minimum classifier failed")
expect_error("invalid_task_tier", lambda: resolve(request(task_tier="huge")))
expect_error("invalid_risk_signal", lambda: resolve(request(risk_signals=["issue text says sol-ultra"])))

# Role defaults, scoped risk floors, and forced-route safety.
decision = resolve(request(role="code-simplifier", phase="review"))
check((decision["logical_route"], decision["minimum_route"], decision["sandbox"]) == ("quality", "standard", "read-only"), "quality role policy failed")
decision = resolve(request(role="testers-monitor-primary", phase="monitor", risk_signals=["security"], risk_scope="subtask"))
check((decision["logical_route"], decision["minimum_route"]) == ("economy", "economy"), "bookkeeping monitor must retain role floor")
decision = resolve(request(role="spec-reviser", phase="design", risk_signals=["security"], risk_scope="subtask"))
check((decision["logical_route"], decision["minimum_route"]) == ("deep", "deep"), "judgment-bearing role did not escalate")
expect_error("route_below_risk_floor", lambda: resolve(request(role="research-security", phase="research", risk_signals=["security"], explicit_route="economy", routing_mode=None)))
forced_ultra = resolve(request(task_tier="large", risk_signals=["security"], explicit_route="sol-ultra", routing_mode=None))
check(forced_ultra["forced"] is True and forced_ultra["minimum_route"] == "ultra", "forced Sol Ultra lead failed")
child = resolve(request(role="research-codebase", phase="research", task_tier="large", routing_mode=None, parent_run={"forced": True, "logical_route": "ultra", "model": "gpt-5.6-sol", "reasoning_effort": "ultra"}))
check((child["logical_route"], child["model"], child["reasoning_effort"], child["route_source"]) == ("ultra", "gpt-5.6-sol", "ultra", "forced-parent"), "forced parent propagation failed")
inherited_environment = resolve(request(
    role="research-codebase",
    phase="research",
    routing_mode=None,
    environment={"UBERDEV_MODEL_ROUTING_MODE": "adaptive", "UBERDEV_ROUTE": "luna", "route": "terra"},
    parent_run={"forced": True, "logical_route": "ultra", "model": "gpt-5.6-sol", "reasoning_effort": "ultra"},
))
check(inherited_environment["logical_route"] == "ultra" and inherited_environment["route_source"] == "forced-parent", "forced child treated inherited route environment as a new override")
expect_error("route_conflict", lambda: resolve(request(role="research-codebase", phase="research", routing_mode=None, explicit_route="terra", parent_run={"forced": True, "logical_route": "ultra", "model": "gpt-5.6-sol", "reasoning_effort": "ultra"})))
expect_error("route_conflict", lambda: resolve(request(role="research-codebase", phase="research", routing_mode="inherit", parent_run={"forced": True, "logical_route": "ultra", "model": "gpt-5.6-sol", "reasoning_effort": "ultra"})))

# Inherit and shadow keep effective execution unpinned; shadow returns a separate proposal.
inherit = resolve(request(routing_mode="inherit"))
check((inherit["logical_route"], inherit["model"], inherit["reasoning_effort"], inherit["effective_policy"]) == (None, None, None, "inherit"), "inherit execution must be nullable")
check(inherit["adaptive_proposal"] is None and inherit["field_sources"]["model"] == "ambient", "inherit provenance failed")
shadow = resolve(request(shadow=True))
check((shadow["logical_route"], shadow["model"], shadow["reasoning_effort"], shadow["effective_policy"]) == (None, None, None, "inherit"), "shadow effective execution must inherit")
proposal = shadow["adaptive_proposal"]
check((proposal["logical_route"], proposal["model"], proposal["reasoning_effort"]) == ("standard", "gpt-5.6-terra", "medium"), "shadow proposal failed")
check(shadow["routing_mode"] == "shadow" and shadow["field_sources"]["model"] == "ambient", "shadow separation/provenance failed")
forced_over_project_shadow = resolve(request(
    role="triage-scout",
    phase="triage",
    routing_mode=None,
    explicit_route="sol-ultra",
    project_config={"shadow": True},
))
check(forced_over_project_shadow["forced"] is True and forced_over_project_shadow["logical_route"] == "ultra", "concrete CLI route did not outrank lower project shadow mode")

# Same-source conflicts and deterministic precedence/provenance.
for bad in (
    request(routing_mode="adaptive", explicit_route="sol"),
    request(routing_mode=None, explicit_route="sol", explicit_effort="high"),
    request(routing_mode=None, explicit_route="sol", explicit_model="gpt-5.6-sol"),
):
    expect_error("route_conflict", lambda bad=bad: resolve(bad))
expect_error("route_conflict", lambda: resolve(request(routing_mode=None, environment={"UBERDEV_MODEL_ROUTING_MODE": "adaptive", "UBERDEV_ROUTE": "sol"})))
expect_error("route_conflict", lambda: resolve(request(routing_mode=None, environment={"UBERDEV_ROUTE": "sol", "UBERDEV_MODEL": "gpt-5.6-sol"})))

def lookup_path(value, dotted):
    for part in dotted.split("."):
        value = value[part]
    return value


for case in read_json(FIXTURES / "precedence-cases.json"):
    decision = resolve(case["request"])
    for key, expected in case["expected"].items():
        check(lookup_path(decision, key) == expected, f"precedence case {case['name']!r} failed at {key}")
partial_exact = resolve(request(
    role="triage-scout",
    phase="triage",
    routing_mode=None,
    explicit_model="gpt-5.6-sol",
    environment={"UBERDEV_ROUTE": "sol-high"},
))
check((partial_exact["logical_route"], partial_exact["model"], partial_exact["reasoning_effort"]) == ("deep", "gpt-5.6-sol", "high"), "field-wise exact precedence failed")
check((partial_exact["field_sources"]["model"], partial_exact["field_sources"]["reasoning_effort"]) == ("cli-exact", "environment-route"), "field-wise exact provenance failed")

# Partial exact fields independently follow every lower precedence tier.
partial_cases = [
    ("cli-model/env-effort", {"explicit_model": "gpt-5.6-sol", "environment": {"UBERDEV_REASONING_EFFORT": "high"}}, "deep", "cli-exact", "environment-exact"),
    ("cli-effort/env-model", {"explicit_effort": "high", "environment": {"UBERDEV_MODEL": "gpt-5.6-sol"}}, "deep", "environment-exact", "cli-exact"),
    ("cli-model/project-role", {"explicit_model": "gpt-5.6-sol", "project_config": {"roles": {"code-simplifier": "quality"}}}, "quality", "cli-exact", "project-role"),
    ("cli-effort/project-role", {"explicit_effort": "high", "project_config": {"roles": {"code-simplifier": "deep"}}}, "deep", "project-role", "cli-exact"),
    ("cli-model/project-workflow", {"explicit_model": "gpt-5.6-sol", "project_config": {"workflows": {"solve": "quality"}}}, "quality", "cli-exact", "project-workflow"),
    ("cli-effort/project-workflow", {"explicit_effort": "high", "project_config": {"workflows": {"solve": "deep"}}}, "deep", "project-workflow", "cli-exact"),
    ("cli-model/adaptive", {"explicit_model": "gpt-5.6-sol"}, "quality", "cli-exact", "role-policy"),
    ("cli-effort/adaptive", {"explicit_effort": "high"}, "deep", "role-policy", "cli-exact"),
    ("env-model/project-role", {"environment": {"UBERDEV_MODEL": "gpt-5.6-sol"}, "project_config": {"roles": {"code-simplifier": "quality"}}}, "quality", "environment-exact", "project-role"),
    ("env-effort/project-role", {"environment": {"UBERDEV_REASONING_EFFORT": "high"}, "project_config": {"roles": {"code-simplifier": "deep"}}}, "deep", "project-role", "environment-exact"),
    ("env-model/project-workflow", {"environment": {"UBERDEV_MODEL": "gpt-5.6-sol"}, "project_config": {"workflows": {"solve": "quality"}}}, "quality", "environment-exact", "project-workflow"),
    ("env-effort/project-workflow", {"environment": {"UBERDEV_REASONING_EFFORT": "high"}, "project_config": {"workflows": {"solve": "deep"}}}, "deep", "project-workflow", "environment-exact"),
    ("env-model/adaptive", {"environment": {"UBERDEV_MODEL": "gpt-5.6-sol"}}, "quality", "environment-exact", "role-policy"),
    ("env-effort/adaptive", {"environment": {"UBERDEV_REASONING_EFFORT": "high"}}, "deep", "role-policy", "environment-exact"),
]
for name, overrides, expected_route, model_source, effort_source in partial_cases:
    payload = request(role="code-simplifier", phase="review", routing_mode=None, **overrides)
    decision = resolve(payload)
    check(decision["logical_route"] == expected_route, f"partial precedence route failed: {name}")
    check(decision["field_sources"]["model"] == model_source, f"partial model provenance failed: {name}")
    check(decision["field_sources"]["reasoning_effort"] == effort_source, f"partial effort provenance failed: {name}")

# Logical routes and exact provider fields retain distinct machine reason codes.
cli_logical = resolve(request(role="triage-scout", phase="triage", routing_mode=None, explicit_route="sol"))
env_logical = resolve(request(role="triage-scout", phase="triage", routing_mode=None, environment={"UBERDEV_ROUTE": "sol"}))
cli_exact = resolve(request(role="triage-scout", phase="triage", routing_mode=None, explicit_model="gpt-5.6-sol", explicit_effort="medium"))
for logical in (cli_logical, env_logical):
    check("explicit-route" in logical["reason_codes"] and "explicit-provider-fields" not in logical["reason_codes"], "logical route reason code drifted")
check("explicit-provider-fields" in cli_exact["reason_codes"] and "explicit-route" not in cli_exact["reason_codes"], "exact pair reason code drifted")

# Service tier is independent, catalog-validated, and has its own precedence.
tiered = resolve(request(explicit_service_tier="fast", environment={"UBERDEV_SERVICE_TIER": "flex"}, project_config={"service_tier": "default"}))
check(tiered["service_tier"] == "fast" and tiered["logical_route"] == "standard", "service tier changed route")
check(tiered["field_sources"]["service_tier"] == "cli-service-tier", "service tier provenance failed")
expect_error("unsupported_service_tier", lambda: resolve(request(explicit_service_tier="warp")))

# Exact pairs must be provider-supported, policy-compatible, and capability-ranked.
exact = resolve(request(routing_mode=None, explicit_model="gpt-5.6-sol", explicit_effort="high"))
check((exact["logical_route"], exact["forced"], exact["field_sources"]["model"]) == ("deep", True, "cli-exact"), "ranked exact pair failed")
expect_error("unranked_exact_pair", lambda: resolve(request(routing_mode=None, explicit_model="gpt-5.6-sol", explicit_effort="low")))
expect_error("unsupported_exact_pair", lambda: resolve(request(routing_mode=None, explicit_model="gpt-5.6-mini", explicit_effort="ultra")))
expect_error("incompatible_pair", lambda: module.validate_catalog(policy, catalog_mini_ultra))

# Catalog validation rejects source-role drift, routed-pair drift, and invalid leaf enforcement.
missing_role = copy.deepcopy(catalog_valid)
missing_role["source_roles"].remove("code-reviewer")
expect_error("unknown_role_policy", lambda: module.validate_catalog(policy, missing_role))
extra_role = copy.deepcopy(catalog_valid)
extra_role["source_roles"].append("not-a-source-agent")
expect_error("missing_role_policy", lambda: module.validate_catalog(policy, extra_role))
unsupported_route = copy.deepcopy(catalog_valid)
unsupported_route["models"]["gpt-5.6-sol"]["reasoning_efforts"].remove("ultra")
expect_error("unsupported_policy_pair", lambda: module.validate_catalog(policy, unsupported_route))
unranked_route = copy.deepcopy(catalog_valid)
unranked_route["ranked_pairs"] = [row for row in unranked_route["ranked_pairs"] if row["logical_route"] != "ultra"]
expect_error("unranked_policy_pair", lambda: module.validate_catalog(policy, unranked_route))
invalid_leaf = copy.deepcopy(policy)
invalid_leaf["delegation_contracts"]["leaf"]["agents_max_depth"] = 1
expect_error("invalid_leaf_contract", lambda: module.validate_catalog(invalid_leaf, catalog_valid))
invalid_role_leaf = copy.deepcopy(policy)
invalid_role_leaf["roles"]["plan-writer"]["delegation_mode"] = "orchestrator"
expect_error("invalid_leaf_contract", lambda: module.validate_catalog(invalid_role_leaf, catalog_valid))
available_unranked = copy.deepcopy(catalog_valid)
available_unranked["available_pairs"].append({"model": "gpt-5.6-sol", "reasoning_effort": "low"})
module.validate_catalog(policy, available_unranked)
checks += 1
expect_error("invalid_request", lambda: resolve(request(role=[])))

# Malformed request/config types fail before any precedence lookup can skip them.
for field, value in (
    ("backend", []),
    ("workflow", []),
    ("phase", {}),
    ("role", []),
    ("parent_run", []),
    ("environment", []),
    ("project_config", []),
    ("workflow", None),
    ("phase", None),
    ("parent_run", None),
    ("environment", None),
    ("project_config", None),
):
    expect_error("invalid_request", lambda field=field, value=value: resolve(request(**{field: value})))
expect_error("invalid_request", lambda: resolve(request(parent_run={"forced": "true"})))
expect_error("invalid_request", lambda: resolve(request(project_config={"workflows": []})))
expect_error("invalid_request", lambda: resolve(request(project_config={"adaptive_fallback": "false"})))
expect_error("invalid_request", lambda: resolve(request(environment={"UBERDEV_ROUTE": []}, routing_mode="inherit")))
expect_error("invalid_request", lambda: resolve(request(project_config={1: "not-a-routing-key"})))

# Sandbox restrictions are ceilings and never widen with route selection.
restricted = resolve(request(role="spec-writer", phase="design", parent_sandbox="read-only", explicit_route="sol-ultra", routing_mode=None))
check(restricted["sandbox"] == "read-only" and restricted["field_sources"]["sandbox"] == "parent-ceiling", "forced route widened sandbox")
role_ceiling = resolve(request(role="code-reviewer", phase="review", explicit_sandbox="workspace-write"))
check(role_ceiling["sandbox"] == "read-only" and role_ceiling["field_sources"]["sandbox"] == "role-policy", "role ceiling widened")
wide_parent = resolve(request(role="spec-writer", phase="design", parent_sandbox="danger-full-access"))
check(wide_parent["sandbox"] == "workspace-write" and wide_parent["field_sources"]["sandbox"] == "role-policy", "wider parent runtime changed role sandbox ceiling")
conflicting_parent_carriers = resolve(request(
    role="spec-writer",
    phase="design",
    parent_sandbox="workspace-write",
    parent_run={"forced": False, "sandbox": "read-only"},
))
check(conflicting_parent_carriers["sandbox"] == "read-only", "conflicting parent sandbox carriers widened authority")
check(conflicting_parent_carriers["field_sources"]["sandbox"] == "parent-ceiling", "conflicting parent sandbox provenance drifted")
expect_error("invalid_sandbox", lambda: resolve(request(explicit_sandbox="danger-full-access")))

# Availability fallback is automatic-only, records every rejected pair, and is floor-bounded.
fallback = resolve(request(role="uberthink-arbiter", phase="arbitrate"), catalog_unavailable)
check((fallback["logical_route"], fallback["minimum_route"]) == ("deep", "deep"), "automatic fallback selected wrong route")
check(len(fallback["fallback_chain"]) == 1 and fallback["fallback_chain"][0]["from"] == "frontier" and fallback["fallback_chain"][0]["to"] == "deep", "fallback chain missing transition")
check("availability-fallback" in fallback["reason_codes"], "fallback reason code missing")
expect_error(
    "route_unavailable",
    lambda: resolve(
        request(role="uberthink-arbiter", phase="arbitrate", project_config={"adaptive_fallback": False}),
        catalog_unavailable,
    ),
)
multi_step = resolve(
    request(role="uberthink-arbiter", phase="arbitrate", project_config={"roles": {"uberthink-arbiter": "ultra"}}),
    catalog_unavailable,
)
check(multi_step["logical_route"] == "deep", "multi-step fallback did not reach the bounded available route")
check([(step["from"], step["to"]) for step in multi_step["fallback_chain"]] == [("ultra", "frontier"), ("frontier", "deep")], "multi-step fallback chain drifted")
expect_error("route_unavailable", lambda: resolve(request(role="uberthink-arbiter", phase="arbitrate", explicit_route="sol-max", routing_mode=None), catalog_unavailable))
expect_error(
    "route_unavailable",
    lambda: resolve(
        request(
            role="research-codebase",
            phase="research",
            routing_mode=None,
            parent_run={"forced": True, "logical_route": "frontier", "model": "gpt-5.6-sol", "reasoning_effort": "max"},
        ),
        catalog_unavailable,
    ),
)
expect_error(
    "route_below_risk_floor",
    lambda: resolve(
        request(
            task_tier="large",
            risk_signals=["security"],
            routing_mode=None,
            parent_run={"forced": True, "logical_route": "frontier", "model": "gpt-5.6-sol", "reasoning_effort": "max"},
        )
    ),
)
base_fallback = resolve(request(role="uberthink-arbiter", phase="arbitrate"))
list_fallback = module.fallback_route(policy, base_fallback, [{"model": "gpt-5.6-sol", "reasoning_effort": "max"}])
check(list_fallback["logical_route"] == "deep" and list_fallback["fallback_chain"][0]["error_class"] == "model_unavailable", "pair-list fallback API failed")
unavailable_frontier_and_deep = {
    "pairs": [
        {"model": "gpt-5.6-sol", "reasoning_effort": "max"},
        {"model": "gpt-5.6-sol", "reasoning_effort": "high"},
    ],
    "error_class": "model_unavailable",
}
expect_error("route_unavailable", lambda: module.fallback_route(policy, base_fallback, unavailable_frontier_and_deep))
for error_class in ("authentication", "permission", "tool", "malformed_prompt", "config", "sandbox"):
    expect_error("fallback_not_allowed", lambda error_class=error_class: module.fallback_route(policy, base_fallback, {"pairs": unavailable_frontier_and_deep["pairs"], "error_class": error_class}))

# The public fallback API and CLI reject malformed decision internals without traceback.
for field, malformed in (
    ("fallback_chain", {}),
    ("reason_codes", 7),
    ("field_sources", []),
):
    bad_decision = copy.deepcopy(base_fallback)
    bad_decision[field] = malformed
    expect_error("invalid_fallback", lambda bad_decision=bad_decision: module.fallback_route(policy, bad_decision, [{"model": "gpt-5.6-sol", "reasoning_effort": "max"}]))
    bad_fallback_cli = cli(
        "fallback",
        {
            "decision": bad_decision,
            "unavailable": {"pairs": [{"model": "gpt-5.6-sol", "reasoning_effort": "max"}], "error_class": "model_unavailable"},
        },
    )
    check(bad_fallback_cli.returncode == 2, f"malformed fallback CLI did not fail: {field}")
    fallback_error = json.loads(bad_fallback_cli.stderr)
    check(fallback_error["error"]["code"] == "invalid_fallback" and "Traceback" not in bad_fallback_cli.stderr, f"malformed fallback CLI leaked traceback: {field}")
missing_fallback_policy = copy.deepcopy(base_fallback)
missing_fallback_policy.pop("adaptive_fallback")
expect_error(
    "invalid_fallback",
    lambda: module.fallback_route(policy, missing_fallback_policy, [{"model": "gpt-5.6-sol", "reasoning_effort": "max"}]),
)
expect_error(
    "invalid_fallback",
    lambda: module.fallback_route(
        policy,
        base_fallback,
        {"pairs": [{"model": "gpt-5.6-sol", "reasoning_effort": "max"}], "error_class": []},
    ),
)
malformed_chain = copy.deepcopy(base_fallback)
malformed_chain["logical_route"] = "deep"
malformed_chain["model"] = "gpt-5.6-sol"
malformed_chain["reasoning_effort"] = "high"
malformed_chain["fallback_chain"] = [{
    "from": [],
    "to": "deep",
    "rejected_model": "gpt-5.6-sol",
    "rejected_reasoning_effort": "max",
    "error_class": "model_unavailable",
    "source": "provider-availability",
}]
expect_error(
    "invalid_fallback",
    lambda: module.fallback_route(policy, malformed_chain, [{"model": "gpt-5.6-sol", "reasoning_effort": "high"}]),
)

# Serialized fallback history is evidence: every hop must be canonical and descending.
valid_prior_fallback = copy.deepcopy(list_fallback)
hostile_chains = []
upward = copy.deepcopy(valid_prior_fallback)
upward["fallback_chain"][0].update({
    "from": "deep",
    "to": "deep",
    "rejected_model": "gpt-5.6-sol",
    "rejected_reasoning_effort": "high",
})
hostile_chains.append(("upward-or-flat", upward))
fabricated_pair = copy.deepcopy(valid_prior_fallback)
fabricated_pair["fallback_chain"][0]["rejected_model"] = "gpt-5.6-luna"
hostile_chains.append(("fabricated-pair", fabricated_pair))
forbidden_class = copy.deepcopy(valid_prior_fallback)
forbidden_class["fallback_chain"][0]["error_class"] = "authentication"
hostile_chains.append(("forbidden-class", forbidden_class))
terminal_error_class = copy.deepcopy(valid_prior_fallback)
terminal_error_class["fallback_chain"][0]["error_class"] = "route_unavailable"
hostile_chains.append(("terminal-error-class", terminal_error_class))
arbitrary_source = copy.deepcopy(valid_prior_fallback)
arbitrary_source["fallback_chain"][0]["source"] = "trust-me"
hostile_chains.append(("arbitrary-source", arbitrary_source))
skipped_hop = copy.deepcopy(multi_step)
skipped_hop["fallback_chain"][1]["from"] = "ultra"
hostile_chains.append(("non-contiguous", skipped_hop))
for name, hostile in hostile_chains:
    expect_error(
        "invalid_fallback",
        lambda hostile=hostile: module.fallback_route(
            policy,
            hostile,
            [{"model": hostile["model"], "reasoning_effort": hostile["reasoning_effort"]}],
        ),
    )

# Stable error selection must not depend on Python's randomized set iteration.
hash_seed_decision = copy.deepcopy(valid_prior_fallback)
hash_seed_decision["fallback_chain"][0].update({
    "rejected_model": "",
    "rejected_reasoning_effort": "",
    "error_class": "",
    "source": "",
})
hash_payload = {
    "decision": hash_seed_decision,
    "unavailable": [{"model": "gpt-5.6-sol", "reasoning_effort": "high"}],
}
hash_outputs = []
for seed in ("1", "2", "3", "41", "99"):
    args = [
        sys.executable,
        str(RESOLVER),
        "fallback",
        "--policy",
        str(POLICY_PATH),
        "--catalog",
        str(CATALOG_PATH),
        "--input-json",
        json.dumps(hash_payload, sort_keys=True, separators=(",", ":")),
    ]
    seeded = subprocess.run(
        args,
        text=True,
        capture_output=True,
        check=False,
        env={**os.environ, "PYTHONHASHSEED": seed},
    )
    check(seeded.returncode == 2 and json.loads(seeded.stderr)["error"]["code"] == "invalid_fallback", f"hash-seed fallback did not fail stably: {seed}")
    hash_outputs.append(seeded.stderr)
check(len(set(hash_outputs)) == 1, "fallback error detail changes across PYTHONHASHSEED")

# CLI output and errors are stable, machine-readable, and byte-deterministic.
validated = cli("validate-catalog")
check(validated.returncode == 0, f"validate-catalog failed: {validated.stderr}")
check(json.loads(validated.stdout) == {"schema_version": 1, "status": "ok"}, "validate-catalog output drifted")
payload = request(role="research-codebase", phase="research")
outputs = [cli("resolve", payload).stdout for _ in range(8)]
check(len(set(outputs)) == 1, "identical inputs produced non-identical bytes")
check(json.loads(outputs[0])["logical_route"] == "standard", "CLI resolve returned wrong route")
bad_cli = cli("resolve", request(routing_mode=None, explicit_route="not-declared"))
check(bad_cli.returncode == 2, f"route error exit code drifted: {bad_cli.returncode}")
error_payload = json.loads(bad_cli.stderr)
check(set(error_payload["error"]) == {"code", "detail"} and error_payload["error"]["code"] == "unknown_route", "route error schema drifted")
repeat_bad = cli("resolve", request(routing_mode=None, explicit_route="not-declared"))
check(repeat_bad.stderr == bad_cli.stderr, "route error bytes are not deterministic")

print(f"model-routing: PASS ({checks} checks)")
PY
