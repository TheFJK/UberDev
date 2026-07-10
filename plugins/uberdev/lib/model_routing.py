#!/usr/bin/env python3
"""Deterministic GPT-5.6 route policy resolver for UberDev.

The module is intentionally dependency-free and side-effect-free except for its
small JSON CLI. Provider launchers consume the returned decision; this module
never invokes a model or mutates runtime state.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import sys
from typing import Any, Mapping, Sequence


PUBLIC_API = {
    "load_policy": "(Path) -> dict[str, object]",
    "validate_catalog": "(policy, catalog) -> None or RouteError",
    "classify_minimum_route": "(policy, request) -> str",
    "resolve_route": "(policy, catalog, request) -> dict[str, object]",
    "fallback_route": "(policy, decision, unavailable_pairs) -> dict[str, object]",
}
ROUTE_ERROR_FIELDS = ("code", "detail")

_ROUTING_MODES = {"adaptive", "inherit"}
_RISK_SCOPES = {"run", "subtask"}
_SANDBOX_RANK = {"read-only": 0, "workspace-write": 1, "danger-full-access": 2}
_SELECTABLE_SANDBOXES = {"read-only", "workspace-write"}
_FALLBACK_ERROR_CLASSES = {
    "effort_unavailable",
    "model_not_found",
    "model_unavailable",
    "unsupported_reasoning_effort",
}
_FALLBACK_STEP_FIELDS = (
    "from",
    "to",
    "rejected_model",
    "rejected_reasoning_effort",
    "error_class",
    "source",
)
_PARENT_STRING_FIELDS = (
    "logical_route",
    "model",
    "reasoning_effort",
    "service_tier",
    "sandbox",
)


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


def _as_mapping(value: object, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise _error("invalid_policy", f"{name} must be an object")
    return value


def _as_catalog_mapping(value: object, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise _error("invalid_catalog", f"{name} must be an object")
    return value


def _present(value: object) -> bool:
    return value is not None and value != ""


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

    return _json_load(Path(path), "invalid_policy")


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


def _route_provider(policy: Mapping[str, Any], route: str) -> Mapping[str, Any]:
    row = _routes(policy).get(route)
    if not isinstance(row, Mapping):
        raise _error("unknown_route", f"route {route!r} is not declared")
    provider = row.get("codex")
    if not isinstance(provider, Mapping):
        raise _error("invalid_policy", f"route {route!r} has no Codex mapping")
    return provider


def _normalize_route(policy: Mapping[str, Any], value: object) -> str:
    if not isinstance(value, str) or not value:
        raise _error("unknown_route", "route must be a non-empty declared name or alias")
    routes = _routes(policy)
    if value in routes:
        return value
    aliases = _as_mapping(policy.get("aliases"), "policy.aliases")
    target = aliases.get(value)
    if isinstance(target, str) and target in routes:
        return target
    raise _error("unknown_route", f"route {value!r} is not declared")


def _max_route(policy: Mapping[str, Any], first: str, second: str) -> str:
    if _route_rank(policy, first) >= _route_rank(policy, second):
        return first
    return second


def _canonical_pair(policy: Mapping[str, Any], route: str) -> tuple[str, str]:
    provider = _route_provider(policy, route)
    model = provider.get("model")
    effort = provider.get("reasoning_effort")
    if not isinstance(model, str) or not isinstance(effort, str):
        raise _error("invalid_policy", f"route {route!r} has an incomplete Codex pair")
    return model, effort


def _pair_key(value: Mapping[str, Any]) -> tuple[str, str] | None:
    model = value.get("model")
    effort = value.get("reasoning_effort")
    if isinstance(model, str) and isinstance(effort, str):
        return model, effort
    return None


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
    provider_pairs: set[tuple[str, str]] = set()
    for name, raw_row in routes.items():
        if not isinstance(name, str) or not isinstance(raw_row, Mapping):
            raise _error("invalid_policy", "every route must be a named object")
        if set(raw_row) != {"rank", "codex"}:
            raise _error("invalid_policy", f"route {name!r} has unknown or missing fields")
        rank = raw_row.get("rank")
        if type(rank) is not int or rank < 0:
            raise _error("invalid_policy", f"route {name!r} must have a non-negative integer rank")
        ranks.append(rank)
        provider = raw_row.get("codex")
        if not isinstance(provider, Mapping):
            raise _error("invalid_policy", f"route {name!r} must declare a Codex mapping")
        if set(provider) != {"model", "reasoning_effort", "service_tier"}:
            raise _error("invalid_policy", f"route {name!r} has unknown or missing Codex fields")
        for field in ("model", "reasoning_effort", "service_tier"):
            if not isinstance(provider.get(field), str) or not provider.get(field):
                raise _error("invalid_policy", f"route {name!r} has invalid Codex field {field!r}")
        pair = (str(provider["model"]), str(provider["reasoning_effort"]))
        if pair in provider_pairs:
            raise _error("invalid_policy", f"multiple routes map to provider pair {pair[0]}/{pair[1]}")
        provider_pairs.add(pair)
    if len(set(ranks)) != len(ranks) or sorted(ranks) != list(range(len(ranks))):
        raise _error("invalid_policy", "route ranks must be unique and contiguous from zero")

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
        if set(raw_row) != {"route", "risk_floor", "sandbox_ceiling", "delegation_mode", "risk_judgment"}:
            raise _error("invalid_policy", f"role {role!r} has unknown or missing fields")
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


def validate_catalog(policy: Mapping[str, Any], catalog: Mapping[str, Any]) -> None:
    """Validate provider capabilities and their one-to-one policy ranking."""

    _validate_policy(policy)
    required_catalog_keys = {
        "schema_version",
        "provider",
        "models",
        "ranked_pairs",
        "available_pairs",
        "service_tiers",
        "source_roles",
    }
    if set(catalog) != required_catalog_keys:
        missing = sorted(required_catalog_keys - set(catalog))
        extra = sorted(set(catalog) - required_catalog_keys)
        raise _error("invalid_catalog", f"catalog keys are not closed (missing={missing}, extra={extra})")
    if type(catalog.get("schema_version")) is not int or catalog.get("schema_version") != 1 or catalog.get("provider") != "codex":
        raise _error("invalid_catalog", "catalog must use schema version 1 and provider codex")

    models = _as_catalog_mapping(catalog.get("models"), "catalog.models")
    service_tiers = catalog.get("service_tiers")
    if (
        not isinstance(service_tiers, list)
        or any(not isinstance(tier, str) or not tier for tier in service_tiers)
        or len(set(service_tiers)) != len(service_tiers)
    ):
        raise _error("invalid_catalog", "catalog.service_tiers must be a unique string list")

    for model, raw_model in models.items():
        if not isinstance(model, str) or not isinstance(raw_model, Mapping):
            raise _error("invalid_catalog", "catalog models must be named objects")
        if set(raw_model) != {"reasoning_efforts"}:
            raise _error("invalid_catalog", f"model {model!r} has unknown or missing fields")
        efforts = raw_model.get("reasoning_efforts")
        if (
            not isinstance(efforts, list)
            or any(not isinstance(effort, str) or not effort for effort in efforts)
            or len(set(efforts)) != len(efforts)
        ):
            raise _error("invalid_catalog", f"model {model!r} must declare unique reasoning efforts")

    source_roles = catalog.get("source_roles")
    if not isinstance(source_roles, list) or any(not isinstance(role, str) for role in source_roles):
        raise _error("invalid_catalog", "catalog.source_roles must be a string list")
    if len(set(source_roles)) != len(source_roles):
        raise _error("invalid_catalog", "catalog.source_roles contains duplicates")
    policy_roles = set(_roles(policy))
    source_role_set = set(source_roles)
    unknown_policies = sorted(policy_roles - source_role_set)
    if unknown_policies:
        raise _error("unknown_role_policy", f"policy exists for unknown source role: {unknown_policies[0]}")
    missing_policies = sorted(source_role_set - policy_roles)
    if missing_policies:
        raise _error("missing_role_policy", f"source role has no policy: {missing_policies[0]}")

    raw_ranked = catalog.get("ranked_pairs")
    if not isinstance(raw_ranked, list):
        raise _error("invalid_catalog", "catalog.ranked_pairs must be a list")
    ranked: list[Mapping[str, Any]] = []
    ranked_pairs_seen: set[tuple[str, str]] = set()
    for index, raw_row in enumerate(raw_ranked):
        if not isinstance(raw_row, Mapping):
            raise _error("invalid_catalog", f"ranked pair {index} must be an object")
        route = raw_row.get("logical_route")
        rank = raw_row.get("rank")
        pair = _pair_key(raw_row)
        if set(raw_row) != {"logical_route", "rank", "model", "reasoning_effort"}:
            raise _error("invalid_catalog", f"ranked pair {index} has unknown or missing fields")
        if not isinstance(route, str) or type(rank) is not int or pair is None:
            raise _error("invalid_catalog", f"ranked pair {index} is incomplete")
        if pair in ranked_pairs_seen:
            raise _error("incompatible_pair", f"provider pair {pair[0]}/{pair[1]} has multiple logical ranks")
        ranked_pairs_seen.add(pair)
        ranked.append(raw_row)

    routes = _routes(policy)
    for route in routes:
        expected_pair = _canonical_pair(policy, route)
        expected_rank = _route_rank(policy, route)
        matching = [
            row
            for row in ranked
            if row.get("logical_route") == route
            and row.get("rank") == expected_rank
            and _pair_key(row) == expected_pair
        ]
        if not matching:
            raise _error("unranked_policy_pair", f"route {route!r} has no canonical ranked provider pair")
        if len(matching) > 1:
            raise _error("incompatible_pair", f"route {route!r} has duplicate canonical ranked pairs")

        model, effort = expected_pair
        model_row = models.get(model)
        efforts = model_row.get("reasoning_efforts") if isinstance(model_row, Mapping) else None
        if not isinstance(efforts, list) or effort not in efforts:
            raise _error("unsupported_policy_pair", f"route {route!r} maps to unsupported pair {model}/{effort}")
        service_tier = _route_provider(policy, route).get("service_tier")
        if service_tier not in service_tiers:
            raise _error("unsupported_policy_pair", f"route {route!r} maps to unsupported service tier {service_tier!r}")

    for row in ranked:
        route = row["logical_route"]
        if route not in routes:
            raise _error("incompatible_pair", f"catalog ranks undeclared logical route {route!r}")
        expected = _canonical_pair(policy, str(route))
        if row.get("rank") != _route_rank(policy, str(route)) or _pair_key(row) != expected:
            raise _error("incompatible_pair", f"ranked pair for {route!r} conflicts with the policy mapping")

    available = catalog.get("available_pairs")
    if not isinstance(available, list):
        raise _error("invalid_catalog", "catalog.available_pairs must be a list")
    seen: set[tuple[str, str]] = set()
    for index, raw_pair in enumerate(available):
        if not isinstance(raw_pair, Mapping) or _pair_key(raw_pair) is None:
            raise _error("invalid_catalog", f"available pair {index} is incomplete")
        if set(raw_pair) != {"model", "reasoning_effort"}:
            raise _error("invalid_catalog", f"available pair {index} has unknown or missing fields")
        pair = _pair_key(raw_pair)
        if pair is None:
            raise _error("invalid_catalog", f"available pair {index} is incomplete")
        if pair in seen:
            raise _error("invalid_catalog", f"available pair {pair[0]}/{pair[1]} is duplicated")
        seen.add(pair)
        model_row = models.get(pair[0])
        efforts = model_row.get("reasoning_efforts") if isinstance(model_row, Mapping) else None
        if not isinstance(efforts, list) or pair[1] not in efforts:
            raise _error("invalid_catalog", f"available pair {pair[0]}/{pair[1]} is unsupported")


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
        raise _error("invalid_risk_scope", f"risk scope {risk_scope!r} must be run or subtask")
    risks = _canonical_risks(policy, request)
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
    if risks and row.get("risk_judgment") is True:
        high_risk_floor = policy.get("high_risk_floor")
        if not isinstance(high_risk_floor, str):
            raise _error("invalid_policy", "high_risk_floor must be a string")
        floor = _max_route(policy, floor, high_risk_floor)
    return floor


def _project_routing_config(request: Mapping[str, Any]) -> Mapping[str, Any]:
    project = request.get("project_config", {})
    if not isinstance(project, Mapping):
        raise _error("invalid_request", "project_config must be an object")
    nested = project.get("model_routing")
    if nested is None:
        return project
    if not isinstance(nested, Mapping):
        raise _error("invalid_request", "project_config.model_routing must be an object")
    return nested


def _route_from_override(value: object, name: str) -> object:
    if isinstance(value, Mapping):
        return value.get("route")
    if value is None or isinstance(value, str):
        return value
    raise _error("invalid_request", f"{name} route override must be a string or object")


def _project_override_entry(config: Mapping[str, Any], scope: str, key: str) -> object:
    collection = config.get(scope, {})
    if collection is None:
        return None
    if not isinstance(collection, Mapping):
        raise _error("invalid_request", f"project {scope} overrides must be an object")
    return collection.get(key)


def _project_route(policy: Mapping[str, Any], request: Mapping[str, Any]) -> tuple[str, str] | None:
    config = _project_routing_config(request)
    role = request.get("role", "lead")
    workflow = request.get("workflow", "")
    if isinstance(role, str):
        role_entry = _project_override_entry(config, "roles", role)
        role_value = _route_from_override(role_entry, f"role {role!r}")
        if _present(role_value):
            return _normalize_route(policy, role_value), "project-role"
    if isinstance(workflow, str):
        workflow_entry = _project_override_entry(config, "workflows", workflow)
        workflow_value = _route_from_override(workflow_entry, f"workflow {workflow!r}")
        if _present(workflow_value):
            return _normalize_route(policy, workflow_value), "project-workflow"
    return None


def _project_mode(request: Mapping[str, Any]) -> object:
    config = _project_routing_config(request)
    return config.get("mode", config.get("routing_mode"))


def _environment(request: Mapping[str, Any]) -> Mapping[str, Any]:
    environment = request.get("environment", {})
    if not isinstance(environment, Mapping):
        raise _error("invalid_request", "environment must be an object")
    return environment


def _validate_optional_string(container: Mapping[str, Any], key: str, source: str) -> None:
    if key not in container or container.get(key) is None:
        return
    value = container.get(key)
    if not isinstance(value, str) or not value:
        raise _error("invalid_request", f"{source}.{key} must be a non-empty string")


def _validate_override_map(config: Mapping[str, Any], scope: str) -> None:
    if scope not in config:
        return
    values = config.get(scope)
    if not isinstance(values, Mapping):
        raise _error("invalid_request", f"project routing {scope} must be an object")
    for key, entry in values.items():
        if not isinstance(key, str) or not key:
            raise _error("invalid_request", f"project routing {scope} keys must be non-empty strings")
        if isinstance(entry, str):
            if not entry:
                raise _error("invalid_request", f"project routing {scope}.{key} route must not be empty")
            continue
        if not isinstance(entry, Mapping) or not entry or not set(entry).issubset({"route", "sandbox"}):
            raise _error("invalid_request", f"project routing {scope}.{key} must be a route string or route/sandbox object")
        for field in entry:
            _validate_optional_string(entry, field, f"project routing {scope}.{key}")


def _validate_request_types(request: Mapping[str, Any]) -> None:
    for key in ("backend", "workflow", "phase", "role", "task_tier", "risk_scope"):
        if key in request and (not isinstance(request.get(key), str) or not request.get(key)):
            raise _error("invalid_request", f"request.{key} must be a non-empty string")
    for key in (
        "routing_mode",
        "explicit_route",
        "explicit_model",
        "explicit_effort",
        "explicit_service_tier",
        "explicit_sandbox",
        "parent_sandbox",
    ):
        _validate_optional_string(request, key, "request")
    for key in ("fast", "shadow", "adaptive_fallback"):
        if key in request and not isinstance(request.get(key), bool):
            raise _error("invalid_request", f"request.{key} must be boolean")

    risks = request.get("risk_signals", [])
    if not isinstance(risks, list) or any(not isinstance(item, str) or not item for item in risks):
        raise _error("invalid_request", "request.risk_signals must be a list of non-empty strings")

    environment = _environment(request)
    for key in (
        "UBERDEV_MODEL_ROUTING_MODE",
        "UBERDEV_ROUTE",
        "UBERDEV_MODEL",
        "UBERDEV_REASONING_EFFORT",
        "UBERDEV_SERVICE_TIER",
    ):
        _validate_optional_string(environment, key, "environment")

    config = _project_routing_config(request)
    if any(not isinstance(key, str) for key in config):
        raise _error("invalid_request", "project routing keys must be strings")
    allowed_config = {
        "mode",
        "routing_mode",
        "service_tier",
        "risk_escalation",
        "adaptive_fallback",
        "shadow",
        "roles",
        "workflows",
    }
    unknown_config = set(config) - allowed_config
    if unknown_config:
        raise _error("invalid_request", f"unknown project routing keys: {sorted(unknown_config)}")
    if "mode" in config and "routing_mode" in config:
        raise _error("invalid_request", "project routing mode and routing_mode are mutually exclusive")
    for key in ("mode", "routing_mode", "service_tier"):
        _validate_optional_string(config, key, "project routing")
    for key in ("risk_escalation", "adaptive_fallback", "shadow"):
        if key in config and not isinstance(config.get(key), bool):
            raise _error("invalid_request", f"project routing {key} must be boolean")
    _validate_override_map(config, "roles")
    _validate_override_map(config, "workflows")

    parent = request.get("parent_run", {})
    if not isinstance(parent, Mapping):
        raise _error("invalid_request", "request.parent_run must be an object")
    if "forced" in parent and not isinstance(parent.get("forced"), bool):
        raise _error("invalid_request", "parent_run.forced must be boolean")
    for key in _PARENT_STRING_FIELDS:
        _validate_optional_string(parent, key, "parent_run")
    if parent.get("forced") is True:
        for key in ("logical_route", "model", "reasoning_effort"):
            if not isinstance(parent.get(key), str) or not parent.get(key):
                raise _error("invalid_request", f"forced parent_run requires {key}")


def _adaptive_fallback_enabled(request: Mapping[str, Any]) -> bool:
    if "adaptive_fallback" in request:
        value = request.get("adaptive_fallback")
    else:
        value = _project_routing_config(request).get("adaptive_fallback", True)
    if not isinstance(value, bool):
        raise _error("invalid_request", "adaptive_fallback must be boolean")
    return value


def _validate_mode(value: object, source: str) -> str:
    if not isinstance(value, str) or value not in _ROUTING_MODES:
        raise _error("invalid_routing_mode", f"{source} routing mode must be adaptive or inherit")
    return value


def _check_source_conflict(
    source: str,
    mode: object,
    route: object,
    model: object,
    effort: object,
) -> None:
    has_mode = _present(mode)
    has_route = _present(route)
    has_model = _present(model)
    has_effort = _present(effort)
    if has_mode and (has_route or has_model or has_effort):
        raise _error("route_conflict", f"{source} routing mode is mutually exclusive with route/model/effort")
    if has_route and (has_model or has_effort):
        raise _error("route_conflict", f"{source} route is mutually exclusive with exact model/effort")


def _ranked_exact_route(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    model: str,
    effort: str,
) -> str:
    models = _as_catalog_mapping(catalog.get("models"), "catalog.models")
    model_row = models.get(model)
    efforts = model_row.get("reasoning_efforts") if isinstance(model_row, Mapping) else None
    if not isinstance(efforts, list) or effort not in efforts:
        raise _error("unsupported_exact_pair", f"provider does not support exact pair {model}/{effort}")
    ranked = catalog.get("ranked_pairs", [])
    matches = [
        row
        for row in ranked
        if isinstance(row, Mapping) and row.get("model") == model and row.get("reasoning_effort") == effort
    ]
    if not matches:
        raise _error("unranked_exact_pair", f"supported pair {model}/{effort} has no logical capability rank")
    if len(matches) != 1 or not isinstance(matches[0].get("logical_route"), str):
        raise _error("incompatible_pair", f"exact pair {model}/{effort} does not have one logical route")
    return _normalize_route(policy, matches[0]["logical_route"])


def _resolve_service_tier(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
    route: str | None,
) -> tuple[str, str]:
    explicit = request.get("explicit_service_tier")
    fast = request.get("fast", False)
    if not isinstance(fast, bool):
        raise _error("invalid_request", "fast must be boolean")
    if fast:
        if _present(explicit) and explicit != "fast":
            raise _error("service_tier_conflict", "--fast conflicts with a non-fast explicit service tier")
        explicit = "fast"
    environment = _environment(request)
    config = _project_routing_config(request)
    if _present(explicit):
        tier, source = explicit, "cli-service-tier"
    elif _present(environment.get("UBERDEV_SERVICE_TIER")):
        tier, source = environment["UBERDEV_SERVICE_TIER"], "environment-service-tier"
    elif _present(config.get("service_tier")):
        tier, source = config["service_tier"], "project-service-tier"
    elif route is not None:
        tier, source = _route_provider(policy, route).get("service_tier"), "route-default"
    else:
        tier, source = "default", "default"
    if not isinstance(tier, str) or tier not in catalog.get("service_tiers", []):
        raise _error("unsupported_service_tier", f"service tier {tier!r} is not provider-supported")
    return tier, source


def _sandbox_from_entry(entry: object) -> object:
    if isinstance(entry, Mapping):
        return entry.get("sandbox")
    return None


def _resolve_sandbox(policy: Mapping[str, Any], request: Mapping[str, Any]) -> tuple[str, str]:
    role = request.get("role", "lead")
    roles = _roles(policy)
    if isinstance(role, str) and role in roles:
        base = roles[role].get("sandbox_ceiling")
        base_source = "role-policy"
    else:
        base = policy.get("default_sandbox")
        base_source = "policy-default"
    if base not in _SELECTABLE_SANDBOXES:
        raise _error("invalid_policy", "resolved policy sandbox is invalid")

    candidates: list[tuple[int, int, str, str]] = [(_SANDBOX_RANK[str(base)], 5, str(base), base_source)]
    config = _project_routing_config(request)
    workflow = request.get("workflow", "")
    if isinstance(workflow, str):
        workflow_sandbox = _sandbox_from_entry(_project_override_entry(config, "workflows", workflow))
        if _present(workflow_sandbox):
            if workflow_sandbox not in _SELECTABLE_SANDBOXES:
                raise _error("invalid_sandbox", f"project workflow sandbox {workflow_sandbox!r} is invalid")
            candidates.append((_SANDBOX_RANK[str(workflow_sandbox)], 4, str(workflow_sandbox), "project-workflow"))
    if isinstance(role, str):
        role_sandbox = _sandbox_from_entry(_project_override_entry(config, "roles", role))
        if _present(role_sandbox):
            if role_sandbox not in _SELECTABLE_SANDBOXES:
                raise _error("invalid_sandbox", f"project role sandbox {role_sandbox!r} is invalid")
            candidates.append((_SANDBOX_RANK[str(role_sandbox)], 3, str(role_sandbox), "project-role"))

    explicit = request.get("explicit_sandbox")
    if _present(explicit):
        if explicit not in _SELECTABLE_SANDBOXES:
            raise _error("invalid_sandbox", f"explicit sandbox {explicit!r} cannot be selected")
        candidates.append((_SANDBOX_RANK[str(explicit)], 2, str(explicit), "cli-sandbox"))

    parent_run = request.get("parent_run")
    parent_carriers = [request.get("parent_sandbox")]
    if isinstance(parent_run, Mapping):
        parent_carriers.append(parent_run.get("sandbox"))
    for parent in parent_carriers:
        if not _present(parent):
            continue
        if parent not in _SANDBOX_RANK:
            raise _error("invalid_sandbox", f"parent sandbox {parent!r} is invalid")
        candidates.append((_SANDBOX_RANK[str(parent)], 1, str(parent), "parent-ceiling"))

    _, _, sandbox, source = min(candidates, key=lambda item: (item[0], item[1]))
    return sandbox, source


def _adaptive_selection(
    policy: Mapping[str, Any],
    request: Mapping[str, Any],
    minimum: str,
) -> tuple[str, str, list[str]]:
    override = _project_route(policy, request)
    if override is not None:
        route, source = override
        if _route_rank(policy, route) < _route_rank(policy, minimum):
            raise _error("route_below_risk_floor", f"project route {route!r} is below minimum {minimum!r}")
        return route, source, [f"{source}-override"]

    role = request.get("role", "lead")
    roles = _roles(policy)
    if isinstance(role, str) and role in roles:
        role_route = roles[role].get("route")
        if not isinstance(role_route, str):
            raise _error("invalid_policy", f"role {role!r} has a non-string route")
        route = _max_route(policy, role_route, minimum)
        reasons = ["role-default"]
        if route != role_route:
            reasons.append("high-risk-floor")
        return route, "role-policy", reasons
    tier = request.get("task_tier", "medium")
    return minimum, "task-policy", [f"task-tier:{tier}"]


def _ignored_lower_sources(
    request: Mapping[str, Any],
    selected_level: str,
) -> list[str]:
    environment = _environment(request)
    config = _project_routing_config(request)
    ignored: list[str] = []
    level_order = {"cli": 0, "parent": 1, "environment": 2, "project": 3, "default": 4}
    selected_rank = level_order[selected_level]
    if selected_rank < level_order["environment"]:
        if any(
            _present(environment.get(key))
            for key in ("UBERDEV_MODEL_ROUTING_MODE", "UBERDEV_ROUTE", "UBERDEV_MODEL", "UBERDEV_REASONING_EFFORT")
        ):
            ignored.append("environment-routing")
    if selected_rank < level_order["project"]:
        if _present(config.get("mode", config.get("routing_mode"))):
            ignored.append("project-mode")
        role = request.get("role", "lead")
        workflow = request.get("workflow", "")
        if isinstance(role, str) and _project_override_entry(config, "roles", role) is not None:
            ignored.append("project-role")
        if isinstance(workflow, str) and _project_override_entry(config, "workflows", workflow) is not None:
            ignored.append("project-workflow")
    return ignored


def _decision_context(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
    minimum: str,
    service_route: str | None,
    ignored_sources: Sequence[str],
) -> dict[str, object]:
    service_tier, service_source = _resolve_service_tier(policy, catalog, request, service_route)
    sandbox, sandbox_source = _resolve_sandbox(policy, request)
    return {
        "schema_version": 1,
        "policy_version": policy.get("policy_version"),
        "backend": request.get("backend", "codex"),
        "service_tier": service_tier,
        "sandbox": sandbox,
        "field_sources": {
            "service_tier": service_source,
            "sandbox": sandbox_source,
        },
        "adaptive_fallback": _adaptive_fallback_enabled(request),
        "risk_signals": _canonical_risks(policy, request),
        "risk_scope": request.get("risk_scope", "run"),
        "minimum_route": minimum,
        "fallback_chain": [],
        "ignored_sources": list(ignored_sources),
    }


def _base_decision(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
    minimum: str,
    route: str,
    source: str,
    forced: bool,
    reason_codes: Sequence[str],
    ignored_sources: Sequence[str],
) -> dict[str, object]:
    model, effort = _canonical_pair(policy, route)
    decision = _decision_context(policy, catalog, request, minimum, route, ignored_sources)
    decision.update({
        "logical_route": route,
        "model": model,
        "reasoning_effort": effort,
        "routing_mode": "forced" if forced else "adaptive",
        "effective_policy": "forced" if forced else "adaptive",
        "route_source": source,
        "forced": forced,
        "reason_codes": list(reason_codes),
        "adaptive_proposal": None,
    })
    field_sources = dict(decision["field_sources"])
    field_sources.update({"model": source, "reasoning_effort": source})
    decision["field_sources"] = field_sources
    return decision


def _inherit_decision(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
    minimum: str,
    routing_mode: str,
    ignored_sources: Sequence[str],
    proposal: Mapping[str, Any] | None,
) -> dict[str, object]:
    decision = _decision_context(policy, catalog, request, minimum, None, ignored_sources)
    decision.update({
        "logical_route": None,
        "model": None,
        "reasoning_effort": None,
        "routing_mode": routing_mode,
        "effective_policy": "inherit",
        "route_source": "ambient",
        "forced": False,
        "reason_codes": ["shadow-proposal" if routing_mode == "shadow" else "ambient-inherit"],
        "adaptive_proposal": copy.deepcopy(proposal) if proposal is not None else None,
    })
    field_sources = dict(decision["field_sources"])
    field_sources.update({"model": "ambient", "reasoning_effort": "ambient"})
    decision["field_sources"] = field_sources
    return decision


def _catalog_available_pairs(policy: Mapping[str, Any], catalog: Mapping[str, Any]) -> set[tuple[str, str]]:
    available = catalog.get("available_pairs")
    if not isinstance(available, list):
        raise _error("invalid_catalog", "catalog.available_pairs must be a list")
    return {
        pair
        for row in available
        if isinstance(row, Mapping) and (pair := _pair_key(row)) is not None
    }


def _apply_catalog_availability(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    decision: dict[str, object],
) -> dict[str, object]:
    pair = (decision.get("model"), decision.get("reasoning_effort"))
    available = _catalog_available_pairs(policy, catalog)
    if pair in available:
        return decision
    if decision.get("forced") is True:
        raise _error("route_unavailable", f"forced pair {pair[0]}/{pair[1]} is unavailable")
    if decision.get("adaptive_fallback") is False:
        raise _error("route_unavailable", f"automatic pair {pair[0]}/{pair[1]} is unavailable and adaptive fallback is disabled")
    unavailable = [
        {"model": model, "reasoning_effort": effort}
        for route in _routes(policy)
        for model, effort in [_canonical_pair(policy, route)]
        if (model, effort) not in available
    ]
    return fallback_route(
        policy,
        decision,
        {"pairs": unavailable, "error_class": "model_unavailable"},
    )


def _concrete_field_selection(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
    minimum: str,
    cli_route: object,
    cli_model: object,
    cli_effort: object,
    env_route: object,
    env_model: object,
    env_effort: object,
    use_environment: bool,
) -> tuple[str, str, str, str, list[str]]:
    """Resolve model and effort independently, then rank the resulting pair."""

    model: object = None
    effort: object = None
    model_source: str | None = None
    effort_source: str | None = None
    reasons: list[str] = []

    if _present(cli_route):
        normalized = _normalize_route(policy, cli_route)
        model, effort = _canonical_pair(policy, normalized)
        model_source = effort_source = "cli-route"
    else:
        if _present(cli_model):
            if not isinstance(cli_model, str):
                raise _error("invalid_request", "CLI model must be a string")
            model, model_source = cli_model, "cli-exact"
        if _present(cli_effort):
            if not isinstance(cli_effort, str):
                raise _error("invalid_request", "CLI effort must be a string")
            effort, effort_source = cli_effort, "cli-exact"

    if use_environment and (model is None or effort is None):
        if _present(env_route):
            normalized = _normalize_route(policy, env_route)
            env_route_model, env_route_effort = _canonical_pair(policy, normalized)
            if model is None:
                model, model_source = env_route_model, "environment-route"
            if effort is None:
                effort, effort_source = env_route_effort, "environment-route"
        else:
            if model is None and _present(env_model):
                if not isinstance(env_model, str):
                    raise _error("invalid_request", "environment model must be a string")
                model, model_source = env_model, "environment-exact"
            if effort is None and _present(env_effort):
                if not isinstance(env_effort, str):
                    raise _error("invalid_request", "environment effort must be a string")
                effort, effort_source = env_effort, "environment-exact"

    if model is None or effort is None:
        base_route, base_source, base_reasons = _adaptive_selection(policy, request, minimum)
        base_model, base_effort = _canonical_pair(policy, base_route)
        if model is None:
            model, model_source = base_model, base_source
        if effort is None:
            effort, effort_source = base_effort, base_source
        reasons.extend(base_reasons)
    if not isinstance(model, str) or not isinstance(effort, str) or model_source is None or effort_source is None:
        raise _error("invalid_request", "model/effort precedence did not resolve a complete pair")
    route = _ranked_exact_route(policy, catalog, model, effort)
    route_source = model_source if model_source == effort_source else "mixed-exact"
    if route_source in {"cli-route", "environment-route"}:
        reasons.append("explicit-route")
    else:
        reasons.append("explicit-provider-fields")
    return route, route_source, model_source, effort_source, reasons


def _validate_fallback_decision(policy: Mapping[str, Any], decision: object) -> Mapping[str, Any]:
    if not isinstance(decision, Mapping):
        raise _error("invalid_fallback", "fallback decision must be an object")
    if type(decision.get("schema_version")) is not int or decision.get("schema_version") != 1:
        raise _error("invalid_fallback", "fallback decision schema_version must be 1")
    route = decision.get("logical_route")
    minimum = decision.get("minimum_route")
    if not isinstance(route, str) or route not in _routes(policy):
        raise _error("invalid_fallback", "fallback decision has no declared logical_route")
    if not isinstance(minimum, str) or minimum not in _routes(policy):
        raise _error("invalid_fallback", "fallback decision has no declared minimum_route")
    if _route_rank(policy, route) < _route_rank(policy, minimum):
        raise _error("invalid_fallback", "fallback decision is already below its minimum route")
    if not isinstance(decision.get("forced"), bool):
        raise _error("invalid_fallback", "fallback decision forced must be boolean")
    if not isinstance(decision.get("adaptive_fallback"), bool):
        raise _error("invalid_fallback", "fallback decision adaptive_fallback must be boolean")
    expected_model, expected_effort = _canonical_pair(policy, route)
    if decision.get("model") != expected_model or decision.get("reasoning_effort") != expected_effort:
        raise _error("invalid_fallback", "fallback decision model/effort does not match logical_route")

    reasons = decision.get("reason_codes")
    if not isinstance(reasons, list) or any(not isinstance(reason, str) or not reason for reason in reasons):
        raise _error("invalid_fallback", "fallback decision reason_codes must be a string list")
    field_sources = decision.get("field_sources")
    if not isinstance(field_sources, Mapping):
        raise _error("invalid_fallback", "fallback decision field_sources must be an object")
    for field in ("model", "reasoning_effort"):
        if not isinstance(field_sources.get(field), str) or not field_sources.get(field):
            raise _error("invalid_fallback", f"fallback decision field_sources.{field} must be a string")

    chain = decision.get("fallback_chain")
    if not isinstance(chain, list):
        raise _error("invalid_fallback", "fallback decision fallback_chain must be a list")
    fallback_order = policy.get("fallback_order")
    if not isinstance(fallback_order, list):
        raise _error("invalid_policy", "fallback_order must be a list")
    prior_to: str | None = None
    for index, step in enumerate(chain):
        if not isinstance(step, Mapping) or set(step) != set(_FALLBACK_STEP_FIELDS):
            raise _error("invalid_fallback", f"fallback_chain[{index}] is malformed")
        from_route = step.get("from")
        to_route = step.get("to")
        if (
            not isinstance(from_route, str)
            or not isinstance(to_route, str)
            or from_route not in _routes(policy)
            or to_route not in _routes(policy)
        ):
            raise _error("invalid_fallback", f"fallback_chain[{index}] references an unknown route")
        if prior_to is not None and from_route != prior_to:
            raise _error("invalid_fallback", f"fallback_chain[{index}] is not contiguous")
        from_index = fallback_order.index(from_route)
        if from_index + 1 >= len(fallback_order) or fallback_order[from_index + 1] != to_route:
            raise _error("invalid_fallback", f"fallback_chain[{index}] must descend exactly one route")
        for field in _FALLBACK_STEP_FIELDS[2:]:
            if not isinstance(step.get(field), str) or not step.get(field):
                raise _error("invalid_fallback", f"fallback_chain[{index}].{field} must be a string")
        rejected_model, rejected_effort = _canonical_pair(policy, from_route)
        if step.get("rejected_model") != rejected_model or step.get("rejected_reasoning_effort") != rejected_effort:
            raise _error("invalid_fallback", f"fallback_chain[{index}] rejected pair is not canonical")
        if step.get("error_class") not in _FALLBACK_ERROR_CLASSES:
            raise _error("invalid_fallback", f"fallback_chain[{index}] uses a forbidden error class")
        if step.get("source") != "provider-availability":
            raise _error("invalid_fallback", f"fallback_chain[{index}] source must be provider-availability")
        prior_to = to_route
    if prior_to is not None and prior_to != route:
        raise _error("invalid_fallback", "fallback_chain terminal route does not match decision")
    return decision


def fallback_route(
    policy: Mapping[str, Any],
    decision: object,
    unavailable_pairs: object,
) -> dict[str, object]:
    """Step an automatic route down within its already-resolved risk floor."""

    _validate_policy(policy)
    decision = _validate_fallback_decision(policy, decision)
    if isinstance(unavailable_pairs, Mapping):
        error_class = unavailable_pairs.get("error_class")
        raw_pairs = unavailable_pairs.get("pairs")
    elif isinstance(unavailable_pairs, list):
        error_class = "model_unavailable"
        raw_pairs = unavailable_pairs
    else:
        raise _error("invalid_fallback", "unavailable pairs must be a list or fallback object")
    if not isinstance(error_class, str):
        raise _error("invalid_fallback", "fallback error_class must be a string")
    if error_class not in _FALLBACK_ERROR_CLASSES:
        raise _error("fallback_not_allowed", f"error class {error_class!r} is not an availability failure")
    if decision.get("forced") is True:
        raise _error("route_unavailable", "forced decisions may not fall back")
    if decision.get("adaptive_fallback") is False:
        raise _error("route_unavailable", "adaptive fallback is disabled for this decision")
    route = decision.get("logical_route")
    minimum = decision.get("minimum_route")
    if not isinstance(route, str) or route not in _routes(policy):
        raise _error("route_unavailable", "decision has no concrete route to fall back")
    if not isinstance(minimum, str) or minimum not in _routes(policy):
        raise _error("route_unavailable", "decision has no valid minimum route")
    if not isinstance(raw_pairs, list):
        raise _error("invalid_fallback", "unavailable pairs must be a list")
    unavailable: set[tuple[str, str]] = set()
    for raw_pair in raw_pairs:
        if not isinstance(raw_pair, Mapping):
            raise _error("invalid_fallback", "each unavailable pair must contain model and reasoning_effort")
        if set(raw_pair) != {"model", "reasoning_effort"}:
            raise _error("invalid_fallback", "unavailable pair has unknown or missing fields")
        pair = _pair_key(raw_pair)
        if pair is None:
            raise _error("invalid_fallback", "each unavailable pair must contain model and reasoning_effort")
        unavailable.add(pair)

    if _canonical_pair(policy, route) not in unavailable:
        raise _error("invalid_fallback", "selected decision pair is not marked unavailable")

    result = copy.deepcopy(dict(decision))
    chain = list(result.get("fallback_chain", []))
    reasons = list(result.get("reason_codes", []))
    current = route
    minimum_rank = _route_rank(policy, minimum)
    routes_by_rank = sorted(_routes(policy), key=lambda name: _route_rank(policy, name), reverse=True)
    while _canonical_pair(policy, current) in unavailable:
        next_routes = [
            candidate
            for candidate in routes_by_rank
            if minimum_rank <= _route_rank(policy, candidate) < _route_rank(policy, current)
        ]
        if not next_routes:
            raise _error("route_unavailable", f"no available route remains at or above minimum {minimum!r}")
        next_route = next_routes[0]
        rejected_model, rejected_effort = _canonical_pair(policy, current)
        chain.append(
            {
                "from": current,
                "to": next_route,
                "rejected_model": rejected_model,
                "rejected_reasoning_effort": rejected_effort,
                "error_class": error_class,
                "source": "provider-availability",
            }
        )
        current = next_route

    model, effort = _canonical_pair(policy, current)
    result["logical_route"] = current
    result["model"] = model
    result["reasoning_effort"] = effort
    result["route_source"] = "availability-fallback"
    field_sources = dict(result.get("field_sources", {}))
    field_sources["model"] = "availability-fallback"
    field_sources["reasoning_effort"] = "availability-fallback"
    result["field_sources"] = field_sources
    result["fallback_chain"] = chain
    if "availability-fallback" not in reasons:
        reasons.append("availability-fallback")
    result["reason_codes"] = reasons
    return result


def resolve_route(
    policy: Mapping[str, Any],
    catalog: Mapping[str, Any],
    request: Mapping[str, Any],
) -> dict[str, object]:
    """Resolve one complete, deterministic provider decision."""

    if not isinstance(request, Mapping):
        raise _error("invalid_request", "request must be an object")
    _validate_request_types(request)
    validate_catalog(policy, catalog)
    backend = request.get("backend", "codex")
    if backend != "codex":
        raise _error("unsupported_backend", f"backend {backend!r} is not supported by this catalog")
    minimum = classify_minimum_route(policy, request)

    cli_mode = request.get("routing_mode")
    cli_route = request.get("explicit_route")
    cli_model = request.get("explicit_model")
    cli_effort = request.get("explicit_effort")
    environment = _environment(request)
    env_mode = environment.get("UBERDEV_MODEL_ROUTING_MODE")
    env_route = environment.get("UBERDEV_ROUTE")
    env_model = environment.get("UBERDEV_MODEL")
    env_effort = environment.get("UBERDEV_REASONING_EFFORT")
    project_mode = _project_mode(request)
    _check_source_conflict("CLI", cli_mode, cli_route, cli_model, cli_effort)

    cli_has_concrete = _present(cli_route) or _present(cli_model) or _present(cli_effort)
    env_has_concrete = _present(env_route) or _present(env_model) or _present(env_effort)
    cli_pair_complete = _present(cli_route) or (_present(cli_model) and _present(cli_effort))
    parent = request.get("parent_run", {})
    if parent is None:
        parent = {}
    if not isinstance(parent, Mapping):
        raise _error("invalid_request", "parent_run must be an object")
    parent_forced = parent.get("forced") is True

    # A forced parent is an immutable run-tree constraint. CLI descendants may
    # only restate matching fields; inherited environment is never re-parsed.
    if parent_forced:
        if _present(cli_mode):
            raise _error("route_conflict", "a descendant routing mode conflicts with its forced parent")
        parent_route = _normalize_route(policy, parent.get("logical_route"))
        parent_model, parent_effort = _canonical_pair(policy, parent_route)
        if parent.get("model") != parent_model or parent.get("reasoning_effort") != parent_effort:
            raise _error("route_unenforceable", "forced parent does not carry its canonical model and effort")
        if _present(cli_route) and _normalize_route(policy, cli_route) != parent_route:
            raise _error("route_conflict", "a descendant concrete route conflicts with its forced parent")
        if _present(cli_model) and cli_model != parent_model:
            raise _error("route_conflict", "a descendant model conflicts with its forced parent")
        if _present(cli_effort) and cli_effort != parent_effort:
            raise _error("route_conflict", "a descendant effort conflicts with its forced parent")
        if _route_rank(policy, parent_route) < _route_rank(policy, minimum):
            raise _error("route_below_risk_floor", f"forced parent route {parent_route!r} is below minimum {minimum!r}")
        decision = _base_decision(
            policy,
            catalog,
            request,
            minimum,
            parent_route,
            "forced-parent",
            True,
            ["forced-parent-propagation"],
            _ignored_lower_sources(request, "parent"),
        )
        return _apply_catalog_availability(policy, catalog, decision)

    # A complete higher-precedence CLI selection shadows environment routing.
    # Partial exact fields deliberately continue down the RFC's field-wise
    # precedence chain to obtain the missing half of the pair.
    use_environment = not _present(cli_mode) and not cli_pair_complete
    if use_environment:
        _check_source_conflict("environment", env_mode, env_route, env_model, env_effort)

    forced = cli_has_concrete or (use_environment and env_has_concrete)
    if cli_has_concrete:
        selected_level = "cli"
    elif use_environment and env_has_concrete:
        selected_level = "environment"
    elif _present(cli_mode):
        selected_level = "cli"
    elif _present(env_mode):
        selected_level = "environment"
    elif _present(project_mode):
        selected_level = "project"
    else:
        selected_level = "default"
    ignored = _ignored_lower_sources(request, selected_level)

    project_shadow = _project_routing_config(request).get("shadow", False)
    shadow_is_request_local = "shadow" in request
    shadow = request.get("shadow", project_shadow)
    if not isinstance(shadow, bool):
        raise _error("invalid_request", "shadow must be boolean")
    if shadow and forced:
        if shadow_is_request_local:
            raise _error("route_conflict", "same-source shadow execution is mutually exclusive with a forced route")
        shadow = False
        if "project-shadow" not in ignored:
            ignored.append("project-shadow")

    if forced:
        route, source, model_source, effort_source, reasons = _concrete_field_selection(
            policy,
            catalog,
            request,
            minimum,
            cli_route,
            cli_model,
            cli_effort,
            env_route,
            env_model,
            env_effort,
            use_environment,
        )
        used_sources = {model_source, effort_source}
        if any(item.startswith("environment-") for item in used_sources):
            ignored = [item for item in ignored if item != "environment-routing"]
        if "project-role" in used_sources:
            ignored = [item for item in ignored if item != "project-role"]
        if "project-workflow" in used_sources:
            ignored = [item for item in ignored if item != "project-workflow"]
        if _route_rank(policy, route) < _route_rank(policy, minimum):
            raise _error("route_below_risk_floor", f"forced route {route!r} is below minimum {minimum!r}")
        decision = _base_decision(
            policy,
            catalog,
            request,
            minimum,
            route,
            source,
            True,
            reasons,
            ignored,
        )
        field_sources = dict(decision["field_sources"])
        field_sources["model"] = model_source
        field_sources["reasoning_effort"] = effort_source
        decision["field_sources"] = field_sources
        return _apply_catalog_availability(policy, catalog, decision)

    if _present(cli_mode):
        mode = _validate_mode(cli_mode, "CLI")
    elif _present(env_mode):
        mode = _validate_mode(env_mode, "environment")
    elif _present(project_mode):
        mode = _validate_mode(project_mode, "project")
    else:
        mode = _validate_mode(policy.get("release_default_mode"), "release default")

    if shadow:
        proposal_route, proposal_source, proposal_reasons = _adaptive_selection(policy, request, minimum)
        proposal = _base_decision(
            policy,
            catalog,
            request,
            minimum,
            proposal_route,
            proposal_source,
            False,
            proposal_reasons,
            ignored,
        )
        proposal = _apply_catalog_availability(policy, catalog, proposal)
        return _inherit_decision(policy, catalog, request, minimum, "shadow", ignored, proposal)
    if mode == "inherit":
        return _inherit_decision(policy, catalog, request, minimum, "inherit", ignored, None)
    route, source, reason_codes = _adaptive_selection(policy, request, minimum)
    decision = _base_decision(
        policy,
        catalog,
        request,
        minimum,
        route,
        source,
        False,
        reason_codes,
        ignored,
    )
    return _apply_catalog_availability(policy, catalog, decision)


def _read_catalog(path: Path | str) -> dict[str, object]:
    return _json_load(Path(path), "invalid_catalog")


def _write_json(stream: Any, value: object) -> None:
    stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def _parse_input_json(raw: str | None) -> Mapping[str, Any]:
    if raw is None:
        raise _error("invalid_request", "--input-json is required for this command")
    value = _strict_json_loads(raw, "invalid_request", "input JSON")
    if not isinstance(value, Mapping):
        raise _error("invalid_request", "input JSON must be an object")
    return value


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("resolve", "validate-catalog", "fallback"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--policy", required=True, type=Path)
        command_parser.add_argument("--catalog", required=True, type=Path)
        command_parser.add_argument("--input-json")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        policy = load_policy(args.policy)
        catalog = _read_catalog(args.catalog)
        validate_catalog(policy, catalog)
        if args.command == "validate-catalog":
            result: object = {"schema_version": 1, "status": "ok"}
        elif args.command == "resolve":
            result = resolve_route(policy, catalog, _parse_input_json(args.input_json))
        else:
            payload = _parse_input_json(args.input_json)
            decision = payload.get("decision")
            unavailable = payload.get("unavailable")
            if not isinstance(decision, Mapping) or not isinstance(unavailable, (Mapping, list)):
                raise _error("invalid_fallback", "fallback input requires a decision object and unavailable object/list")
            result = fallback_route(policy, decision, unavailable)
        _write_json(sys.stdout, result)
        return 0
    except RouteError as exc:
        _write_json(sys.stderr, {"error": {"code": exc.code, "detail": exc.detail}})
        return 2
    except Exception:
        code = "invalid_fallback" if args.command == "fallback" else "invalid_request"
        _write_json(sys.stderr, {"error": {"code": code, "detail": "malformed input payload"}})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
