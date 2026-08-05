#!/usr/bin/env python3
"""Deterministic logical-route policy validator and classifier for UberDev.

This module loads and completely validates `policy/model-routing-v1.json` and
answers one question: given a task tier, a role and a set of risk signals, what
is the lowest *logical* capability rank the invocation is allowed to run at.

It deliberately stops there. Concrete per-rank routing -- turning a logical rank
into a provider model plus a reasoning effort, then negotiating fallbacks when a
pair is unavailable -- was only ever enforceable on a backend that owned the
provider invocation. Since #381 retired the last such backend, no shipped
dispatch path can reach a concrete resolver, so `resolve_route`,
`fallback_route`, `validate_catalog` and the JSON CLI that fronted them were
removed rather than left as a catalog nothing can enter. See RFC 0013
(2026-08-05 amendment).

The module is dependency-free, importable, and side-effect-free: it never
invokes a model, reads ambient configuration, or mutates runtime state.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping


PUBLIC_API = {
    "load_policy": "(Path) -> dict[str, object]",
    "classify_minimum_route": "(policy, request) -> str",
}
ROUTE_ERROR_FIELDS = ("code", "detail")

_ROUTING_MODES = {"adaptive", "inherit"}
_RISK_SCOPES = {"run", "subtask", "none"}
_CANONICAL_REASONING_EFFORTS = frozenset({"minimal", "low", "medium", "high", "xhigh", "max", "ultra"})
_SELECTABLE_SANDBOXES = {"read-only", "workspace-write"}


class RouteError(Exception):
    """Stable typed error returned by the resolver and its CLI."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


class _DuplicateKeyError(ValueError):
    pass


def _error(code: str, detail: str) -> RouteError:
    return RouteError(code, detail)


def _validate_reasoning_effort_token(value: object, error_code: str, source: str) -> str:
    if not isinstance(value, str) or value not in _CANONICAL_REASONING_EFFORTS:
        raise _error(error_code, f"{source} has unknown reasoning effort {value!r}")
    return value


def _as_mapping(value: object, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise _error("invalid_policy", f"{name} must be an object")
    return value


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise _DuplicateKeyError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def _strict_json_loads(raw: str, error_code: str, source: str) -> object:
    try:
        return json.loads(raw, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, _DuplicateKeyError) as exc:
        raise _error(error_code, f"cannot parse {source}: {exc}") from exc


def _json_load(path: Path, error_code: str) -> dict[str, object]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise _error(error_code, f"cannot load {path}: {exc}") from exc
    value = _strict_json_loads(raw, error_code, str(path))
    if not isinstance(value, dict):
        raise _error(error_code, f"{path} must contain a JSON object")
    return value


def load_policy(path: Path | str) -> dict[str, object]:
    """Load a routing policy without consulting ambient configuration."""

    policy = _json_load(Path(path), "invalid_policy")
    _validate_policy(policy)
    return policy


def _routes(policy: Mapping[str, Any]) -> Mapping[str, Mapping[str, Any]]:
    routes = _as_mapping(policy.get("routes"), "policy.routes")
    return routes  # type: ignore[return-value]


def _roles(policy: Mapping[str, Any]) -> Mapping[str, Mapping[str, Any]]:
    roles = _as_mapping(policy.get("roles"), "policy.roles")
    return roles  # type: ignore[return-value]


def _route_rank(policy: Mapping[str, Any], route: str) -> int:
    row = _routes(policy).get(route)
    if not isinstance(row, Mapping) or type(row.get("rank")) is not int:
        raise _error("invalid_policy", f"route {route!r} has no integer rank")
    return int(row["rank"])


def _max_route(policy: Mapping[str, Any], first: str, second: str) -> str:
    if _route_rank(policy, first) >= _route_rank(policy, second):
        return first
    return second


def _validate_policy(policy: Mapping[str, Any]) -> None:
    required_keys = {
        "schema_version",
        "policy_version",
        "release_default_mode",
        "default_sandbox",
        "routes",
        "aliases",
        "lead_routes",
        "high_risk_floor",
        "risk_signals",
        "reasoning_efforts",
        "fallback_order",
        "delegation_contracts",
        "roles",
    }
    if set(policy) != required_keys:
        missing = sorted(required_keys - set(policy))
        extra = sorted(set(policy) - required_keys)
        raise _error("invalid_policy", f"policy keys are not closed (missing={missing}, extra={extra})")
    if type(policy.get("schema_version")) is not int or policy.get("schema_version") != 1:
        raise _error("invalid_policy", "policy.schema_version must be 1")
    policy_version = policy.get("policy_version")
    if not isinstance(policy_version, str) or not policy_version.strip():
        raise _error("invalid_policy", "policy.policy_version must be a non-empty string")
    if policy.get("release_default_mode") not in _ROUTING_MODES:
        raise _error("invalid_policy", "policy.release_default_mode must be adaptive or inherit")

    routes = _routes(policy)
    if not routes:
        raise _error("invalid_policy", "policy.routes must not be empty")
    ranks: list[int] = []
    for name, raw_row in routes.items():
        # A route row is a logical capability rank and nothing else. The former
        # `codex` sub-object (model + reasoning_effort + service_tier) was the
        # concrete provider catalog; it is gone with the resolver that read it.
        if not isinstance(name, str) or not isinstance(raw_row, Mapping):
            raise _error("invalid_policy", "every route must be a named object")
        if set(raw_row) != {"rank"}:
            raise _error("invalid_policy", f"route {name!r} has unknown or missing fields")
        rank = raw_row.get("rank")
        if type(rank) is not int or rank < 0:
            raise _error("invalid_policy", f"route {name!r} must have a non-negative integer rank")
        ranks.append(rank)
    if len(set(ranks)) != len(ranks) or sorted(ranks) != list(range(len(ranks))):
        raise _error("invalid_policy", "route ranks must be unique and contiguous from zero")

    # The reasoning-effort vocabulary a project config may name. It used to be
    # scraped out of the per-route provider blocks; with those deleted it is
    # declared directly so the surviving consumer (lib/config-read.sh) still has
    # a single authoritative source rather than a hardcoded literal.
    reasoning_efforts = policy.get("reasoning_efforts")
    if (
        not isinstance(reasoning_efforts, list)
        or not reasoning_efforts
        or len(set(reasoning_efforts)) != len(reasoning_efforts)
    ):
        raise _error("invalid_policy", "reasoning_efforts must be a unique non-empty list")
    for effort in reasoning_efforts:
        _validate_reasoning_effort_token(effort, "invalid_policy", "policy.reasoning_efforts")

    aliases = _as_mapping(policy.get("aliases"), "policy.aliases")
    for alias, target in aliases.items():
        if not isinstance(alias, str) or alias in routes or not isinstance(target, str) or target not in routes:
            raise _error("invalid_policy", f"invalid route alias {alias!r}")

    lead_routes = _as_mapping(policy.get("lead_routes"), "policy.lead_routes")
    expected_tiers = {"trivial", "small", "medium", "large"}
    if set(lead_routes) != expected_tiers:
        raise _error("invalid_policy", "lead route tiers must be trivial, small, medium, and large")
    for tier, raw_row in lead_routes.items():
        row = _as_mapping(raw_row, f"policy.lead_routes.{tier}")
        if set(row) != {"default", "high_risk"}:
            raise _error("invalid_policy", f"lead tier {tier!r} must declare default and high_risk")
        for route in row.values():
            if not isinstance(route, str) or route not in routes:
                raise _error("invalid_policy", f"lead tier {tier!r} references an unknown route")

    risk_floor = policy.get("high_risk_floor")
    if not isinstance(risk_floor, str) or risk_floor not in routes:
        raise _error("invalid_policy", "high_risk_floor must reference a declared route")
    risk_signals = policy.get("risk_signals")
    if (
        not isinstance(risk_signals, list)
        or not risk_signals
        or any(not isinstance(signal, str) or not signal for signal in risk_signals)
        or len(set(risk_signals)) != len(risk_signals)
    ):
        raise _error("invalid_policy", "risk_signals must be a unique non-empty string list")

    fallback_order = policy.get("fallback_order")
    if (
        not isinstance(fallback_order, list)
        or any(not isinstance(route, str) for route in fallback_order)
        or len(fallback_order) != len(routes)
        or len(set(fallback_order)) != len(fallback_order)
        or set(fallback_order) != set(routes)
    ):
        raise _error("invalid_policy", "fallback_order must contain every route exactly once")
    expected_fallback = [name for name, _ in sorted(routes.items(), key=lambda item: int(item[1]["rank"]), reverse=True)]
    if fallback_order != expected_fallback:
        raise _error("invalid_policy", "fallback_order must descend by capability rank")

    contracts = _as_mapping(policy.get("delegation_contracts"), "policy.delegation_contracts")
    if set(contracts) != {"leaf"}:
        raise _error("invalid_leaf_contract", "only the leaf delegation contract is valid in policy v1")
    leaf = contracts.get("leaf")
    if leaf != {"features_multi_agent": False, "agents_max_depth": 0}:
        raise _error("invalid_leaf_contract", "leaf agents must disable multi-agent and set max depth to zero")

    default_sandbox = policy.get("default_sandbox")
    if default_sandbox not in _SELECTABLE_SANDBOXES:
        raise _error("invalid_policy", "default_sandbox must be read-only or workspace-write")

    roles = _roles(policy)
    for role, raw_row in roles.items():
        if not isinstance(role, str) or not isinstance(raw_row, Mapping):
            raise _error("invalid_policy", "every role must be a named object")
        base_role_fields = {"route", "risk_floor", "sandbox_ceiling", "delegation_mode", "risk_judgment"}
        role_fields = set(raw_row)
        # `high_risk_route` is the one conditional field left: classify_minimum_route
        # reads it below. plan-writer's per-tier `tier_routes` ladder was read only
        # by the concrete resolver and went with it (#381) rather than staying as
        # validated-but-unread policy data.
        conditional_fields = {"high_risk_route"}
        if role_fields - (base_role_fields | conditional_fields) or not base_role_fields.issubset(role_fields):
            raise _error("invalid_policy", f"role {role!r} has unknown or missing fields")
        if role != "plan-writer" and role_fields != base_role_fields:
            raise _error("invalid_policy", f"role {role!r} may not declare conditional routes")
        if role == "plan-writer":
            if role_fields != base_role_fields | conditional_fields:
                raise _error("invalid_policy", "plan-writer must declare high_risk_route")
            high_risk_route = raw_row.get("high_risk_route")
            if not isinstance(high_risk_route, str) or high_risk_route not in routes:
                raise _error("invalid_policy", "plan-writer high_risk_route must reference a declared route")
        route = raw_row.get("route")
        floor = raw_row.get("risk_floor")
        sandbox = raw_row.get("sandbox_ceiling")
        if not isinstance(route, str) or route not in routes:
            raise _error("invalid_policy", f"role {role!r} references an unknown route")
        if route == "ultra":
            raise _error("invalid_policy", f"role {role!r} may not default to ultra")
        if not isinstance(floor, str) or floor not in routes:
            raise _error("invalid_policy", f"role {role!r} has an unknown risk floor")
        if _route_rank(policy, route) < _route_rank(policy, floor):
            raise _error("invalid_policy", f"role {role!r} defaults below its risk floor")
        if sandbox not in _SELECTABLE_SANDBOXES:
            raise _error("invalid_policy", f"role {role!r} has an invalid sandbox ceiling")
        if raw_row.get("delegation_mode") != "leaf":
            raise _error("invalid_leaf_contract", f"role {role!r} must use the leaf delegation contract")
        if not isinstance(raw_row.get("risk_judgment"), bool):
            raise _error("invalid_policy", f"role {role!r} must declare risk_judgment")


def _canonical_risks(policy: Mapping[str, Any], request: Mapping[str, Any]) -> list[str]:
    raw_risks = request.get("risk_signals", [])
    if not isinstance(raw_risks, list):
        raise _error("invalid_risk_signal", "risk_signals must be a list")
    declared = set(policy.get("risk_signals", []))
    risks: set[str] = set()
    for raw in raw_risks:
        if not isinstance(raw, str):
            raise _error("invalid_risk_signal", "risk signals must be strings")
        normalized = raw if raw in declared else raw.replace("_", "-")
        if normalized not in declared:
            raise _error("invalid_risk_signal", f"risk signal {raw!r} is not declared")
        risks.add(normalized)
    return sorted(risks)


def classify_minimum_route(policy: Mapping[str, Any], request: Mapping[str, Any]) -> str:
    """Return the lowest logical capability allowed for this invocation."""

    _validate_policy(policy)
    tier = request.get("task_tier", "medium")
    lead_routes = _as_mapping(policy.get("lead_routes"), "policy.lead_routes")
    if not isinstance(tier, str) or tier not in lead_routes:
        raise _error("invalid_task_tier", f"task tier {tier!r} is not declared")
    risk_scope = request.get("risk_scope", "run")
    if risk_scope not in _RISK_SCOPES:
        raise _error("invalid_risk_scope", f"risk scope {risk_scope!r} must be run, subtask, or none")
    risks = _canonical_risks(policy, request)
    if risk_scope == "none" and risks:
        raise _error("risk_scope_mismatch", "risk scope 'none' requires empty risk_signals")
    risk_escalation = _environment(request).get(
        "UBERDEV_MODEL_ROUTING_RISK_ESCALATION",
        _project_routing_config(request).get("risk_escalation", True),
    )
    if not isinstance(risk_escalation, bool):
        raise _error("invalid_request", "project routing risk_escalation must be boolean")
    role = request.get("role", "lead")
    roles = _roles(policy)
    if role in (None, "", "lead"):
        row = _as_mapping(lead_routes[tier], f"policy.lead_routes.{tier}")
        selected = row["high_risk" if risks else "default"]
        if not isinstance(selected, str):
            raise _error("invalid_policy", f"lead tier {tier!r} has a non-string route")
        return selected
    if not isinstance(role, str):
        raise _error("invalid_request", "role must be a string")
    if role not in roles:
        raise _error("unknown_role", f"role {role!r} is not declared")
    row = _as_mapping(roles[role], f"policy.roles.{role}")
    floor = row.get("risk_floor")
    if not isinstance(floor, str):
        raise _error("invalid_policy", f"role {role!r} has no risk floor")
    if risks and risk_escalation and row.get("risk_judgment") is True:
        conditional = row.get("high_risk_route")
        if isinstance(conditional, str):
            return conditional
        high_risk_floor = policy.get("high_risk_floor")
        if not isinstance(high_risk_floor, str):
            raise _error("invalid_policy", "high_risk_floor must be a string")
        floor = _max_route(policy, floor, high_risk_floor)
    return floor


def _project_routing_config(request: Mapping[str, Any]) -> Mapping[str, Any]:
    if "project_routing" in request:
        project_routing = request.get("project_routing")
        if not isinstance(project_routing, Mapping):
            raise _error("invalid_request", "project_routing must be an object")
        return project_routing
    project = request.get("project_config", {})
    if not isinstance(project, Mapping):
        raise _error("invalid_request", "project_config must be an object")
    nested = project.get("model_routing")
    if nested is None:
        return project
    if not isinstance(nested, Mapping):
        raise _error("invalid_request", "project_config.model_routing must be an object")
    return nested


def _environment(request: Mapping[str, Any]) -> Mapping[str, Any]:
    environment = request.get("environment", {})
    if not isinstance(environment, Mapping):
        raise _error("invalid_request", "environment must be an object")
    return environment
