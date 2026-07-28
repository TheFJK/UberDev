#!/usr/bin/env python3
"""Append-only lifecycle manifest for instrumented UberDev agent runs.

The public CLI intentionally has three small operations:

* ``append`` validates one metadata-only lifecycle event and appends one compact
  JSONL record with one ``os.write`` call.
* ``verify`` validates every record and the route -> start -> terminal state
  machine, optionally requiring all started runs to be terminal.
* ``reconcile`` appends ``abandoned`` for orphans only after both their owner
  process and backend handle are proven not live.

Only the Python standard library is used.  Manifest directories and files are
made private before use, and direct symlink targets are rejected.
Kernel creation identities are supported on Linux, macOS, and native Windows;
other platforms fail closed instead of synthesizing a degraded fingerprint.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Callable, Iterable, NamedTuple

try:
    import fcntl as _fcntl
except ImportError:  # pragma: no cover - exercised by native Windows CI
    _fcntl = None

try:
    import msvcrt as _msvcrt
except ImportError:  # pragma: no cover - unavailable on POSIX
    _msvcrt = None


# v2 binds every new start to a kernel creation identity. v1 remains readable
# solely for manifests written before that field existed: it is never upgraded
# in place, never receives a synthesized identity, and reconciliation appends a
# terminal using the original lifecycle version. The public append boundary
# accepts only the current version, so compatibility cannot create new v1 data.
SCHEMA_VERSION = 2
READABLE_SCHEMA_VERSIONS = frozenset({1, SCHEMA_VERSION})
TERMINAL_EVENTS = frozenset(
    {"completed", "failed", "timed_out", "cancelled", "abandoned"}
)
LIFECYCLE_EVENTS = frozenset({"route_decided", "agent_started"}) | TERMINAL_EVENTS
SUPPORTED_PROCESS_IDENTITY_PLATFORMS = ("linux", "darwin", "windows")
_WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000
_WINDOWS_SYNCHRONIZE = 0x00100000
_WINDOWS_PROCESS_LIVENESS_ACCESS = (
    _WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION | _WINDOWS_SYNCHRONIZE
)
_WINDOWS_WAIT_OBJECT_0 = 0x00000000
_WINDOWS_WAIT_TIMEOUT = 0x00000102
_WINDOWS_WAIT_FAILED = 0xFFFFFFFF

# RFC 0013 section 13 fields plus the minimal process metadata required to
# reconcile an interrupted agent_started event.  This is deliberately closed:
# arbitrary keys are payload channels, not lifecycle metadata.
ALLOWED_FIELDS = frozenset(
    {
        "schema_version",
        "event",
        "timestamp",
        "run_id",
        "agent_id",
        "parent_run_id",
        "workflow",
        "phase",
        "role",
        "issue_or_pr",
        "backend",
        "task_tier",
        "routing_mode",
        "decision_logical_route",
        "decision_source",
        "decision_model",
        "decision_reasoning_effort",
        "effective_policy",
        "effective_logical_route",
        "effective_model",
        "effective_reasoning_effort",
        "effective_service_tier",
        "effective_sandbox",
        "enforcement_evidence",
        "risk_signals",
        "queue_ms",
        "duration_ms",
        "prompt_bytes",
        "result_bytes",
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "usage_source",
        "retry_count",
        "fallback_from",
        "fallback_reason",
        "cache_hit",
        "terminal_status",
        "error_class",
        "quality_gate",
        "owner_pid",
        "owner_process_identity",
        "backend_handle",
        "status_path",
        "timeout_s",
    }
)

_FORBIDDEN_EXACT = frozenset(
    {
        "prompt",
        "prompt_text",
        "prompt_body",
        "source",
        "source_code",
        "code",
        "body",
        "issue_body",
        "raw",
        "raw_content",
        "content",
        "credential",
        "credentials",
        "secret",
        "secrets",
        "password",
        "authorization",
        "cookie",
        "api_key",
        "access_token",
        "auth_token",
        "refresh_token",
        "private_key",
    }
)
_NONNEGATIVE_INTS = frozenset(
    {
        "queue_ms",
        "duration_ms",
        "prompt_bytes",
        "result_bytes",
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "retry_count",
    }
)
_ROUTING_MODES = frozenset({"adaptive", "forced", "inherit", "shadow"})
_EFFECTIVE_POLICIES = frozenset({"adaptive", "forced", "inherit"})
_ENFORCEMENT_EVIDENCE = frozenset(
    {"explicit_argv", "validated_profile", "provider_reported", "ambient_unverified"}
)
_TASK_TIERS = frozenset({"trivial", "small", "medium", "large"})
_REASONING_EFFORTS = frozenset({"low", "medium", "high", "max", "ultra"})
_SERVICE_TIERS = frozenset({"default", "fast", "flex"})
_LOGICAL_ROUTES = frozenset({"economy", "standard", "quality", "deep", "frontier", "ultra"})
_SANDBOXES = frozenset({"read-only", "workspace-write"})
_CODE_FIELDS = frozenset(
    {"decision_source", "fallback_reason", "error_class", "usage_source"}
)
_CODE_PATTERN = re.compile(r"[a-z][a-z0-9]*(?:[-_.:][a-z0-9]+)*")
_IDENTIFIER_FIELDS = frozenset(
    {
        "run_id",
        "agent_id",
        "parent_run_id",
        "workflow",
        "phase",
        "role",
        "backend",
        "decision_model",
        "effective_model",
    }
)
_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9$][A-Za-z0-9$._:/@+\-]{0,255}")
_PROCESS_IDENTITY_PATTERN = re.compile(
    r"([1-9][0-9]*)\|([1-9][0-9]*)\|([1-9][0-9]*)\|([0-9a-f]{64})"
)
_LEASE_IDENTITY_PATTERN = re.compile(
    r"(0|[1-9][0-9]{0,19}):(0|[1-9][0-9]{0,19})"
)
_SENSITIVE_VALUE_PATTERNS = tuple(
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"authorization\s*:",
        r"\bbearer\s+[A-Za-z0-9._~+/=-]+",
        r"\b(?:api[_-]?key|password|client[_-]?secret|access[_-]?token|refresh[_-]?token)\s*[:=]",
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"\bsk-[A-Za-z0-9_-]{16,}",
        r"\bAKIA[A-Z0-9]{16}\b",
    )
)
_STRING_OR_NULL_FIELDS = frozenset(
    ALLOWED_FIELDS
    - {
        "schema_version",
        "event",
        "timestamp",
        "run_id",
        "risk_signals",
        "cache_hit",
        "owner_pid",
        "backend_handle",
        "timeout_s",
        "issue_or_pr",
        "quality_gate",
    }
    - _NONNEGATIVE_INTS
)


class ManifestRejected(ValueError):
    """The caller supplied an invalid record, path, or lifecycle transition."""


class ManifestRuntimeError(RuntimeError):
    """The private manifest could not be safely read or written."""


_CLEANUP_DIAGNOSTIC_ATTRIBUTE = "_uberdev_manifest_cleanup_code"
_CLEANUP_DIAGNOSTIC_CODES = frozenset(
    {
        "artifact_capture_close_failed",
        "artifact_snapshot_close_failed",
        "windows_handle_close_failed",
    }
)


def _record_cleanup_diagnostic(primary: BaseException, code: str) -> None:
    if code in _CLEANUP_DIAGNOSTIC_CODES:
        setattr(primary, _CLEANUP_DIAGNOSTIC_ATTRIBUTE, code)


def _cleanup_diagnostic(primary: BaseException) -> dict[str, str] | None:
    code = getattr(primary, _CLEANUP_DIAGNOSTIC_ATTRIBUTE, None)
    if code not in _CLEANUP_DIAGNOSTIC_CODES:
        return None
    return {"code": code}


def _close_windows_handle(
    kernel32: Any,
    handle: Any,
    primary: BaseException | None = None,
) -> bool:
    if kernel32.CloseHandle(handle):
        return True
    if primary is not None:
        _record_cleanup_diagnostic(primary, "windows_handle_close_failed")
        return False
    raise ManifestRuntimeError("windows_handle_close_failed")


@dataclass
class RunState:
    route: dict[str, Any] | None = None
    started: dict[str, Any] | None = None
    terminal: dict[str, Any] | None = None
    last_timestamp: dt.datetime | None = None


def _compact_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _emit(value: Any) -> None:
    print(_compact_json(value))


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _utc_not_before(minimum: dt.datetime | None) -> str:
    """Return a canonical UTC timestamp that cannot regress before minimum."""

    current = dt.datetime.now(dt.timezone.utc)
    if minimum is not None and minimum > current:
        current = minimum
    return current.isoformat(timespec="microseconds").replace("+00:00", "Z")


def _is_plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _field_is_forbidden(key: str) -> bool:
    normalized = key.lower().replace("-", "_")
    if normalized in _FORBIDDEN_EXACT:
        return True
    if normalized.startswith("prompt_") and normalized != "prompt_bytes":
        return True
    if normalized.endswith("_body") or normalized.endswith("_content"):
        return True
    if "source_code" in normalized or "credential" in normalized or "secret" in normalized:
        return True
    return normalized.endswith("_password") or normalized.endswith("_api_key")


def _find_forbidden(value: Any, prefix: str = "") -> str | None:
    if isinstance(value, dict):
        for key in sorted(value):
            path = f"{prefix}.{key}" if prefix else str(key)
            if _field_is_forbidden(str(key)):
                return path
            nested = _find_forbidden(value[key], path)
            if nested is not None:
                return nested
    elif isinstance(value, list):
        for index, item in enumerate(value):
            nested = _find_forbidden(item, f"{prefix}[{index}]")
            if nested is not None:
                return nested
    return None


def _find_sensitive_value(value: Any, prefix: str = "") -> str | None:
    if isinstance(value, str):
        if any(pattern.search(value) for pattern in _SENSITIVE_VALUE_PATTERNS):
            return prefix or "<root>"
    elif isinstance(value, dict):
        for key in sorted(value):
            path = f"{prefix}.{key}" if prefix else str(key)
            nested = _find_sensitive_value(value[key], path)
            if nested is not None:
                return nested
    elif isinstance(value, list):
        for index, item in enumerate(value):
            nested = _find_sensitive_value(item, f"{prefix}[{index}]")
            if nested is not None:
                return nested
    return None


def _parse_timestamp(value: Any) -> dt.datetime | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(dt.timezone.utc)


def _valid_text(value: Any, *, maximum: int = 4096) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and "\x00" not in value
        and "\n" not in value
        and "\r" not in value
    )


def _pid_handle(value: Any) -> bool:
    """Return whether value is a positive PID handle.

    The ``pid:`` prefix is reserved: callers must reject prefixed values when
    this predicate is false instead of reinterpreting them as opaque handles.
    """

    if _is_plain_int(value):
        return value > 0
    if not isinstance(value, str):
        return False
    numeric = value[4:] if value.startswith("pid:") else value
    return numeric.isdigit() and int(numeric) > 0


def _numeric_pid(value: Any) -> int | None:
    if not _pid_handle(value):
        return None
    if isinstance(value, int):
        return value
    numeric = value[4:] if value.startswith("pid:") else value
    return int(numeric)


def _parse_process_identity(value: Any) -> tuple[int, int, int, str] | None:
    if not isinstance(value, str):
        return None
    match = _PROCESS_IDENTITY_PATTERN.fullmatch(value)
    if match is None:
        return None
    pid, pgid, sid, fingerprint = match.groups()
    return int(pid), int(pgid), int(sid), fingerprint


def _valid_identifier(value: Any) -> bool:
    return isinstance(value, str) and _IDENTIFIER_PATTERN.fullmatch(value) is not None


def _validate_event(event: Any) -> list[str]:
    if not isinstance(event, dict):
        return ["event_record_must_be_object"]

    forbidden = _find_forbidden(event)
    if forbidden is not None:
        return [f"forbidden_field: {forbidden}"]

    sensitive_value = _find_sensitive_value(event)
    if sensitive_value is not None:
        return [f"sensitive_value: {sensitive_value}"]

    unknown = sorted(set(event) - ALLOWED_FIELDS)
    if unknown:
        return [f"unknown_field: {field}" for field in unknown]

    errors: list[str] = []
    schema_version = event.get("schema_version")
    if not _is_plain_int(schema_version) or schema_version not in READABLE_SCHEMA_VERSIONS:
        errors.append("invalid_schema_version")

    event_name = event.get("event")
    if event_name not in LIFECYCLE_EVENTS:
        errors.append("invalid_event")

    if _parse_timestamp(event.get("timestamp")) is None:
        errors.append("invalid_timestamp")

    if not _valid_identifier(event.get("run_id")):
        errors.append("invalid_run_id")

    if "agent_id" in event and event["agent_id"] is not None and not _valid_identifier(
        event["agent_id"]
    ):
        errors.append("invalid_agent_id")

    if not _valid_identifier(event.get("backend")):
        errors.append("invalid_backend")

    for field in _IDENTIFIER_FIELDS - {"run_id", "agent_id", "backend"}:
        if field in event and event[field] is not None and not _valid_identifier(
            event[field]
        ):
            errors.append(f"invalid_{field}")

    for field in _STRING_OR_NULL_FIELDS:
        if field not in event or event[field] is None:
            continue
        if not _valid_text(event[field]):
            errors.append(f"invalid_{field}")

    for field in _NONNEGATIVE_INTS:
        if field not in event or event[field] is None:
            continue
        if not _is_plain_int(event[field]) or event[field] < 0:
            errors.append(f"invalid_{field}")

    if "owner_pid" in event and event["owner_pid"] is not None:
        if not _is_plain_int(event["owner_pid"]) or event["owner_pid"] <= 0:
            errors.append("invalid_owner_pid")

    if "owner_process_identity" in event and event["owner_process_identity"] is not None:
        identity = event["owner_process_identity"]
        parsed_identity = _parse_process_identity(identity)
        owner_pid = event.get("owner_pid")
        if (
            parsed_identity is None
            or not _is_plain_int(owner_pid)
            or parsed_identity[0] != owner_pid
        ):
            errors.append("invalid_owner_process_identity")

    if "backend_handle" in event and event["backend_handle"] is not None:
        handle = event["backend_handle"]
        if isinstance(handle, bool) or not isinstance(handle, (str, int)):
            errors.append("invalid_backend_handle")
        elif isinstance(handle, int) and handle <= 0:
            errors.append("invalid_backend_handle")
        elif isinstance(handle, str):
            reserved_pid_invalid = handle.startswith("pid:") and not _pid_handle(
                handle
            )
            numeric_pid_invalid = handle.isdigit() and not _pid_handle(handle)
            if (
                not _valid_identifier(handle)
                or reserved_pid_invalid
                or numeric_pid_invalid
            ):
                errors.append("invalid_backend_handle")

    if "status_path" in event and event["status_path"] is not None:
        if not _valid_text(event["status_path"]):
            errors.append("invalid_status_path")

    if "timeout_s" in event and event["timeout_s"] is not None:
        if not _is_plain_int(event["timeout_s"]) or event["timeout_s"] <= 0:
            errors.append("invalid_timeout_s")

    if "risk_signals" in event and event["risk_signals"] is not None:
        risks = event["risk_signals"]
        invalid_risks = not isinstance(risks, list) or len(risks) > 32
        if not invalid_risks:
            invalid_risks = any(
                not isinstance(item, str)
                or len(item) > 128
                or _CODE_PATTERN.fullmatch(item) is None
                for item in risks
            )
        if not invalid_risks:
            invalid_risks = len(risks) != len(set(risks))
        if invalid_risks:
            errors.append("invalid_risk_signals")

    if "cache_hit" in event and event["cache_hit"] is not None and not isinstance(
        event["cache_hit"], bool
    ):
        errors.append("invalid_cache_hit")

    if "issue_or_pr" in event and event["issue_or_pr"] is not None:
        issue = event["issue_or_pr"]
        if isinstance(issue, bool) or not isinstance(issue, (str, int)):
            errors.append("invalid_issue_or_pr")
        elif _is_plain_int(issue) and issue <= 0:
            errors.append("invalid_issue_or_pr")
        elif isinstance(issue, str) and (
            not _valid_text(issue, maximum=256)
            or re.fullmatch(
                r"(?:#?\d+|(?:issue|pr)[:#]?\d+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+)",
                issue,
                re.IGNORECASE,
            )
            is None
        ):
            errors.append("invalid_issue_or_pr")

    if "quality_gate" in event and event["quality_gate"] is not None:
        quality_gate = event["quality_gate"]
        if isinstance(quality_gate, bool):
            pass
        elif (
            not _valid_text(quality_gate, maximum=256)
            or _CODE_PATTERN.fullmatch(quality_gate) is None
        ):
            errors.append("invalid_quality_gate")

    for code_field in _CODE_FIELDS:
        code = event.get(code_field)
        if code is not None and (
            not isinstance(code, str)
            or len(code) > 256
            or _CODE_PATTERN.fullmatch(code) is None
        ):
            errors.append(f"invalid_{code_field}")

    if event_name == "agent_started" and (
        not _is_plain_int(event.get("owner_pid")) or event["owner_pid"] <= 0
    ):
        if "invalid_owner_pid" not in errors:
            errors.append("invalid_owner_pid")

    if (
        event_name == "agent_started"
        and _is_plain_int(schema_version)
        and schema_version >= 2
    ):
        owner_pid = event.get("owner_pid")
        owner_identity = _parse_process_identity(event.get("owner_process_identity"))
        if (
            owner_identity is None
            or not _is_plain_int(owner_pid)
            or owner_identity[0] != owner_pid
        ):
            if "invalid_owner_process_identity" not in errors:
                errors.append("invalid_owner_process_identity")

    if event_name == "agent_started":
        status_path = event.get("status_path")
        if status_path is not None and (
            not isinstance(status_path, str) or not os.path.isabs(status_path)
        ):
            if "invalid_status_path" not in errors:
                errors.append("invalid_status_path")
        backend_handle = event.get("backend_handle")
        if backend_handle not in (None, "") and not _pid_handle(backend_handle):
            if not isinstance(status_path, str) or not os.path.isabs(status_path):
                errors.append("opaque_backend_handle_requires_status_path")

    routing_mode = event.get("routing_mode")
    if routing_mode is not None and routing_mode not in _ROUTING_MODES:
        errors.append("invalid_routing_mode")
    enforcement = event.get("enforcement_evidence")
    if enforcement is not None and enforcement not in _ENFORCEMENT_EVIDENCE:
        errors.append("invalid_enforcement_evidence")
    task_tier = event.get("task_tier")
    if task_tier is not None and task_tier not in _TASK_TIERS:
        errors.append("invalid_task_tier")
    for effort_field in ("decision_reasoning_effort", "effective_reasoning_effort"):
        effort = event.get(effort_field)
        if effort is not None and effort not in _REASONING_EFFORTS:
            errors.append(f"invalid_{effort_field}")
    service_tier = event.get("effective_service_tier")
    if service_tier is not None and service_tier not in _SERVICE_TIERS:
        errors.append("invalid_effective_service_tier")
    for route_field in (
        "decision_logical_route",
        "effective_logical_route",
        "fallback_from",
    ):
        route = event.get(route_field)
        if route is not None and route not in _LOGICAL_ROUTES:
            errors.append(f"invalid_{route_field}")
    effective_sandbox = event.get("effective_sandbox")
    if effective_sandbox is not None and effective_sandbox not in _SANDBOXES:
        errors.append("invalid_effective_sandbox")

    effective_policy = event.get("effective_policy")
    if effective_policy is not None and effective_policy not in _EFFECTIVE_POLICIES:
        errors.append("invalid_effective_policy")
    if routing_mode == "shadow" and effective_policy != "inherit":
        errors.append("shadow_requires_inherit")
    fallback_reason = event.get("fallback_reason")
    if fallback_reason is not None and re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}", fallback_reason
    ) is None:
        errors.append("invalid_fallback_reason")
    if routing_mode in {"adaptive", "forced"}:
        if effective_policy != routing_mode:
            errors.append("routing_effective_policy_mismatch")
        if any(
            event.get(field) is None
            for field in (
                "decision_logical_route",
                "decision_model",
                "decision_reasoning_effort",
                "effective_logical_route",
                "effective_model",
                "effective_reasoning_effort",
            )
        ):
            errors.append("incomplete_route_metadata")
        for decision_field, effective_field, label in (
            ("decision_logical_route", "effective_logical_route", "route"),
            ("decision_model", "effective_model", "model"),
            (
                "decision_reasoning_effort",
                "effective_reasoning_effort",
                "reasoning_effort",
            ),
        ):
            decision_value = event.get(decision_field)
            effective_value = event.get(effective_field)
            if (
                decision_value is not None
                and effective_value is not None
                and decision_value != effective_value
            ):
                errors.append(f"decision_effective_{label}_mismatch")

    if routing_mode == "shadow" and any(
        event.get(field) is None
        for field in (
            "decision_logical_route",
            "decision_model",
            "decision_reasoning_effort",
        )
    ):
        errors.append("shadow_requires_decision")
    if routing_mode == "inherit" and effective_policy != "inherit":
        errors.append("inherit_requires_inherit_policy")

    inherit_effective = effective_policy == "inherit" or routing_mode == "inherit"
    if inherit_effective and enforcement != "provider_reported":
        if any(
            event.get(field) is not None
            for field in (
                "effective_logical_route",
                "effective_model",
                "effective_reasoning_effort",
            )
        ):
            errors.append("unreported_inherit_effective_route")

    if event_name in TERMINAL_EVENTS:
        if event.get("terminal_status") != event_name:
            errors.append("terminal_status_mismatch")
    elif event.get("terminal_status") is not None:
        errors.append("terminal_status_on_nonterminal")

    return errors


def _identity(event: dict[str, Any]) -> tuple[str, str]:
    return str(event["run_id"]), str(event.get("agent_id") or "")


def _identity_label(identity: tuple[str, str]) -> str:
    run_id, agent_id = identity
    return f"run {run_id}" if not agent_id else f"run {run_id} agent {agent_id}"


def _transition(
    state: RunState, event: dict[str, Any], line_number: int
) -> list[str]:
    errors: list[str] = []
    name = event["event"]
    timestamp = _parse_timestamp(event["timestamp"])
    if state.last_timestamp is not None and timestamp is not None and timestamp < state.last_timestamp:
        errors.append(f"line {line_number}: timestamp_regression")

    if name == "route_decided":
        if state.route is not None:
            errors.append(f"line {line_number}: duplicate_route_decided")
        elif state.started is not None or state.terminal is not None:
            errors.append(f"line {line_number}: route_decided_after_start")
        else:
            state.route = event
    elif name == "agent_started":
        if state.route is None:
            errors.append(f"line {line_number}: agent_started_before_route_decided")
        elif state.started is not None:
            errors.append(f"line {line_number}: duplicate_agent_started")
        elif state.terminal is not None:
            errors.append(f"line {line_number}: agent_started_after_terminal")
        else:
            state.started = event
            if state.route is not None and state.route["backend"] != event["backend"]:
                errors.append(f"line {line_number}: backend_mismatch")
    else:
        if state.started is None:
            errors.append(f"line {line_number}: terminal_before_agent_started")
        elif state.terminal is not None:
            errors.append(f"line {line_number}: duplicate_terminal")
        else:
            state.terminal = event
            if state.started["backend"] != event["backend"]:
                errors.append(f"line {line_number}: backend_mismatch")

    if not errors and timestamp is not None:
        state.last_timestamp = timestamp
    return errors


def _read_records_from_descriptor(
    descriptor: int,
) -> tuple[list[tuple[int, dict[str, Any]]], list[str]]:
    records: list[tuple[int, dict[str, Any]]] = []
    errors: list[str] = []
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        with os.fdopen(os.dup(descriptor), "r", encoding="utf-8") as handle:
            for line_number, raw in enumerate(handle, 1):
                if not raw.strip():
                    errors.append(f"line {line_number}: empty_record")
                    continue
                try:
                    value = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    errors.append(f"line {line_number}: malformed_json")
                    continue
                if not isinstance(value, dict):
                    errors.append(f"line {line_number}: event_record_must_be_object")
                    continue
                records.append((line_number, value))
    except (OSError, UnicodeError) as exc:
        raise ManifestRuntimeError(f"manifest_read_failed: {getattr(exc, 'errno', None)}") from exc
    return records, errors


def _read_records(path: str) -> tuple[list[tuple[int, dict[str, Any]]], list[str]]:
    if not os.path.lexists(path):
        return [], []
    descriptor = _secure_open_regular(path, os.O_RDONLY)
    try:
        return _read_records_from_descriptor(descriptor)
    finally:
        os.close(descriptor)


def _evaluate(
    records: Iterable[tuple[int, dict[str, Any]]], *, strict: bool
) -> tuple[dict[tuple[str, str], RunState], list[str], int]:
    states: dict[tuple[str, str], RunState] = {}
    errors: list[str] = []
    event_count = 0
    for line_number, event in records:
        event_count += 1
        schema_errors = _validate_event(event)
        if schema_errors:
            errors.extend(f"line {line_number}: {error}" for error in schema_errors)
            continue
        identity = _identity(event)
        state = states.setdefault(identity, RunState())
        errors.extend(_transition(state, event, line_number))

    if strict:
        for identity in sorted(states):
            state = states[identity]
            if state.started is not None and state.terminal is None:
                errors.append(f"{_identity_label(identity)}: missing_terminal")
    return states, errors, event_count


def _prepare_private_path(path: str) -> str:
    absolute = os.path.abspath(os.path.expanduser(path))
    parent = os.path.dirname(absolute)
    _reject_symlinked_ancestors(parent)
    try:
        os.makedirs(parent, mode=0o700, exist_ok=True)
        _reject_symlinked_ancestors(parent)
        parent_stat = os.lstat(parent)
    except OSError as exc:
        raise ManifestRuntimeError(f"manifest_parent_unavailable: {exc.errno}") from exc
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise ManifestRejected("manifest_parent_must_be_real_directory")
    if hasattr(os, "geteuid") and parent_stat.st_uid != os.geteuid():
        raise ManifestRejected("manifest_parent_not_owned_by_user")
    if os.name != "nt":
        parent_descriptor = _open_directory_fd(parent)
        try:
            os.fchmod(parent_descriptor, 0o700)
        except OSError as exc:
            raise ManifestRuntimeError(f"manifest_parent_chmod_failed: {exc.errno}") from exc
        finally:
            os.close(parent_descriptor)

    if os.path.lexists(absolute):
        try:
            target = os.lstat(absolute)
        except OSError as exc:
            raise ManifestRuntimeError(f"manifest_lstat_failed: {exc.errno}") from exc
        if stat.S_ISLNK(target.st_mode):
            raise ManifestRejected("manifest_symlink_rejected")
        if not stat.S_ISREG(target.st_mode):
            raise ManifestRejected("manifest_not_regular_file")
        if hasattr(os, "geteuid") and target.st_uid != os.geteuid():
            raise ManifestRejected("manifest_not_owned_by_user")
    return absolute


def _reject_symlinked_ancestors(path: str) -> None:
    absolute = os.path.abspath(path)
    drive, tail = os.path.splitdrive(absolute)
    current = drive + os.path.sep if drive else os.path.sep
    for component in tail.split(os.path.sep):
        if component in ("", "."):
            continue
        if component == "..":
            raise ManifestRejected("manifest_parent_path_traversal_rejected")
        current = os.path.join(current, component)
        if not os.path.lexists(current):
            break
        try:
            entry = os.lstat(current)
        except OSError as exc:
            raise ManifestRuntimeError(f"manifest_parent_lstat_failed: {exc.errno}") from exc
        if stat.S_ISLNK(entry.st_mode):
            # macOS exposes /var and /tmp as root-managed compatibility links.
            # They are stable platform roots, unlike caller-controlled links
            # below the state root.
            if sys.platform == "darwin" and current in {"/var", "/tmp"}:
                continue
            raise ManifestRejected("manifest_symlinked_ancestor_rejected")


def _linux_process_record(pid: int) -> tuple[int, int, int, str]:
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
            raw = stream.read()
    except FileNotFoundError as exc:
        raise ProcessLookupError(pid) from exc
    end = raw.rfind(")")
    if end < 0:
        raise OSError("malformed proc stat")
    fields = raw[end + 2 :].split()
    if len(fields) < 20:
        raise OSError("incomplete proc stat")
    if fields[0] == "Z":
        raise ProcessLookupError(pid)
    with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as stream:
        boot_id = stream.read().strip()
    if not boot_id:
        raise OSError("boot identity unavailable")
    return int(fields[1]), int(fields[2]), int(fields[3]), f"linux:{boot_id}:{fields[19]}"


class _DarwinProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("pbi_rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def _darwin_process_record(pid: int) -> tuple[int, int, int, str]:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int
    ]
    libproc.proc_pidinfo.restype = ctypes.c_int
    info = _DarwinProcBSDInfo()
    size = ctypes.sizeof(info)
    if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
        error = ctypes.get_errno()
        if error in {errno.ESRCH, errno.ENOENT}:
            raise ProcessLookupError(pid)
        raise OSError(error or errno.EIO, "proc_pidinfo failed")
    if info.pbi_status == 5:
        raise ProcessLookupError(pid)
    sid = os.getsid(pid)
    return (
        int(info.pbi_ppid), int(info.pbi_pgid), int(sid),
        f"darwin:{info.pbi_start_tvsec}:{info.pbi_start_tvusec}",
    )


def _windows_parent_pid(pid: int) -> int:
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    class ProcessEntry32(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_uint32), ("cntUsage", ctypes.c_uint32),
            ("th32ProcessID", ctypes.c_uint32), ("th32DefaultHeapID", ctypes.c_void_p),
            ("th32ModuleID", ctypes.c_uint32), ("cntThreads", ctypes.c_uint32),
            ("th32ParentProcessID", ctypes.c_uint32), ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", ctypes.c_uint32), ("szExeFile", ctypes.c_wchar * 260),
        ]

    kernel32.CreateToolhelp32Snapshot.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    kernel32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    kernel32.Process32FirstW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ProcessEntry32)]
    kernel32.Process32FirstW.restype = ctypes.c_int
    kernel32.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ProcessEntry32)]
    kernel32.Process32NextW.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
    invalid_handle = ctypes.c_void_p(-1).value
    if snapshot == invalid_handle:
        raise OSError(ctypes.get_last_error(), "CreateToolhelp32Snapshot failed")
    try:
        entry = ProcessEntry32()
        entry.dwSize = ctypes.sizeof(entry)
        found = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while found:
            if int(entry.th32ProcessID) == pid:
                return int(entry.th32ParentProcessID)
            found = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        _close_windows_handle(kernel32, snapshot, primary=sys.exc_info()[1])
    raise ProcessLookupError(pid)


@contextmanager
def _windows_live_process(
    pid: int,
) -> Iterable[tuple[int, Callable[[], None]]]:
    """Hold a validated live process handle while its identity is consumed."""

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    class FileTime(ctypes.Structure):
        _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]

    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.WaitForSingleObject.restype = ctypes.c_uint32
    kernel32.GetProcessTimes.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(FileTime), ctypes.POINTER(FileTime),
        ctypes.POINTER(FileTime), ctypes.POINTER(FileTime),
    ]
    kernel32.GetProcessTimes.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    handle = kernel32.OpenProcess(
        _WINDOWS_PROCESS_LIVENESS_ACCESS, False, pid
    )
    if not handle:
        error = ctypes.get_last_error()
        if error in {87, 1168}:
            raise ProcessLookupError(pid)
        raise OSError(error or errno.EIO, "OpenProcess failed")
    try:
        def require_still_active() -> None:
            wait_result = int(kernel32.WaitForSingleObject(handle, 0))
            if wait_result == _WINDOWS_WAIT_TIMEOUT:
                return
            if wait_result == _WINDOWS_WAIT_OBJECT_0:
                raise ProcessLookupError(pid)
            if wait_result == _WINDOWS_WAIT_FAILED:
                raise OSError(
                    ctypes.get_last_error() or errno.EIO,
                    "WaitForSingleObject failed",
                )
            raise OSError(
                errno.EIO, "WaitForSingleObject returned an unexpected status"
            )

        require_still_active()
        created, exited, kernel, user = FileTime(), FileTime(), FileTime(), FileTime()
        if not kernel32.GetProcessTimes(
            handle, ctypes.byref(created), ctypes.byref(exited),
            ctypes.byref(kernel), ctypes.byref(user)
        ):
            raise OSError(ctypes.get_last_error(), "GetProcessTimes failed")
        creation_ticks = (int(created.high) << 32) | int(created.low)
        if creation_ticks <= 0:
            raise OSError("process creation time unavailable")
        yield creation_ticks, require_still_active
        # Consumers may perform a process-table snapshot while this handle is
        # open. Refuse its result if the handle was signaled in that window.
        require_still_active()
    finally:
        _close_windows_handle(kernel32, handle, primary=sys.exc_info()[1])


def _windows_process_record(pid: int) -> tuple[int, int, int, str]:
    with _windows_live_process(pid) as (creation_ticks, _require_still_active):
        pass
    # Windows has no POSIX process groups or sessions. The PID is retained in
    # those schema slots while the kernel creation FILETIME provides the
    # authoritative anti-reuse identity.
    return pid, pid, pid, f"windows:{creation_ticks}"


def _windows_guarded_parent_record(
    pid: int,
    expected_creation_ticks: int | None = None,
) -> tuple[int, int]:
    with _windows_live_process(pid) as (
        child_creation_ticks,
        require_child_still_active,
    ):
        if (
            expected_creation_ticks is not None
            and child_creation_ticks != expected_creation_ticks
        ):
            raise ProcessLookupError(pid)
        try:
            parent_pid = _windows_parent_pid(pid)
        except ProcessLookupError as exc:
            # The process handle, nonsignaled state, and creation time were
            # validated before the snapshot. A later miss is unavailable
            # evidence rather than proof that the process is absent.
            raise OSError(
                errno.EAGAIN, "live process missing from Toolhelp snapshot"
            ) from exc
        require_child_still_active()
        try:
            with _windows_live_process(parent_pid) as (
                parent_creation_ticks,
                _require_parent_still_active,
            ):
                if parent_creation_ticks > child_creation_ticks:
                    raise OSError(
                        errno.EAGAIN,
                        "snapshot parent was created after its child",
                    )
        except ProcessLookupError as exc:
            raise OSError(
                errno.EAGAIN, "snapshot parent identity unavailable"
            ) from exc
        return parent_pid, parent_creation_ticks


def _process_identity_platform() -> str | None:
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    if os.name == "nt":
        return "windows"
    return None


def _uses_native_windows_filesystem() -> bool:
    """Return whether this interpreter requires native-Windows file APIs.

    Owner-depth model tests deliberately vary ``os.name``.  The interpreter's
    native platform remains authoritative for filesystem capabilities, so a
    Windows process must never enter the POSIX ``dir_fd`` walk while that model
    is active.
    """

    return os.name == "nt" or sys.platform == "win32"


def _unsupported_process_identity_platform() -> OSError:
    supported = ", ".join(SUPPORTED_PROCESS_IDENTITY_PLATFORMS)
    return OSError(
        f"unsupported process identity platform; supported platforms: {supported}"
    )


def _native_process_record(pid: int) -> tuple[int, int, int, str]:
    platform = _process_identity_platform()
    if platform == "linux":
        return _linux_process_record(pid)
    if platform == "darwin":
        return _darwin_process_record(pid)
    if platform == "windows":
        return _windows_process_record(pid)
    raise _unsupported_process_identity_platform()


def _native_parent_pid(pid: int) -> int:
    platform = _process_identity_platform()
    if platform == "linux":
        return _linux_process_record(pid)[0]
    if platform == "darwin":
        return _darwin_process_record(pid)[0]
    if platform == "windows":
        raise OSError(
            errno.ENOTSUP,
            "Windows parent traversal requires a bound creation identity",
        )
    raise _unsupported_process_identity_platform()


def _format_process_identity(
    pid: int,
    pgid: int,
    sid: int,
    creation_identity: str,
) -> str:
    digest = hashlib.sha256(creation_identity.encode()).hexdigest()
    return f"{pid}|{pgid}|{sid}|{digest}"


def _process_identity(
    pid: Any,
    cleanup_diagnostics: list[dict[str, str]] | None = None,
) -> tuple[str, str | None]:
    numeric_pid = _numeric_pid(pid)
    if numeric_pid is None:
        return "absent", None
    pid = numeric_pid
    try:
        _parent, pgid, sid, creation_identity = _native_process_record(pid)
        return "captured", _format_process_identity(
            pid, pgid, sid, creation_identity
        )
    except ProcessLookupError as exc:
        diagnostic = _cleanup_diagnostic(exc)
        if diagnostic is not None and cleanup_diagnostics is not None:
            cleanup_diagnostics.append(diagnostic)
        return "absent", None
    except (AttributeError, OSError, ValueError) as exc:
        diagnostic = _cleanup_diagnostic(exc)
        if diagnostic is not None and cleanup_diagnostics is not None:
            cleanup_diagnostics.append(diagnostic)
        return "unavailable", None


def _write_process_identity(mode: str, destination: str) -> None:
    self_pid = os.getppid()
    # The caller explicitly selects native-parent depth.  Do not infer it from
    # stdout: MSYS pipes are not reliably reported as FIFOs to native Python.
    owner_depth = {"direct": 0, "parent": 1}.get(mode)
    if owner_depth is None:
        raise ManifestRejected("invalid_process_identity_mode")
    if os.name == "nt":
        owner_depth += 1
    owner_pid = self_pid
    platform = _process_identity_platform()
    owner_creation_ticks: int | None = None
    try:
        if platform == "windows":
            for _ in range(owner_depth):
                owner_pid, owner_creation_ticks = (
                    _windows_guarded_parent_record(
                        owner_pid, owner_creation_ticks
                    )
                )
        else:
            for _ in range(owner_depth):
                owner_pid = _native_parent_pid(owner_pid)
    except ProcessLookupError as exc:
        raise ManifestRuntimeError("process_identity_parent_absent") from exc
    except (AttributeError, OSError, ValueError) as exc:
        raise ManifestRuntimeError("process_identity_parent_unavailable") from exc
    if platform == "windows":
        if owner_creation_ticks is None:
            raise ManifestRuntimeError("process_identity_parent_unavailable")
        identity = _format_process_identity(
            owner_pid,
            owner_pid,
            owner_pid,
            f"windows:{owner_creation_ticks}",
        )
    else:
        status, identity = _process_identity(owner_pid)
        if status != "captured" or identity is None:
            raise ManifestRuntimeError(f"process_identity_{status}")
    destination = os.path.abspath(destination)
    payload = f"{owner_pid}\n{identity}\n".encode("ascii")
    descriptor = _secure_open_regular(destination, os.O_WRONLY, 0o600)
    try:
        opened = os.fstat(descriptor)
        if opened.st_nlink != 1 or opened.st_size != 0:
            raise ManifestRejected("process_identity_candidate_invalid")
        if hasattr(os, "geteuid") and opened.st_uid != os.geteuid():
            raise ManifestRejected("process_identity_candidate_not_owned")
        if not _uses_native_windows_filesystem():
            os.fchmod(descriptor, 0o600)

        def rollback() -> None:
            try:
                os.ftruncate(descriptor, 0)
            except OSError as exc:
                raise ManifestRuntimeError(
                    "process_identity_rollback_failed"
                ) from exc

        try:
            written = os.write(descriptor, payload)
        except OSError as exc:
            rollback()
            raise ManifestRuntimeError("process_identity_short_write") from exc
        if written != len(payload):
            rollback()
            raise ManifestRuntimeError("process_identity_short_write")
        try:
            current = os.lstat(destination)
        except OSError as exc:
            rollback()
            raise ManifestRejected(
                "process_identity_candidate_replaced"
            ) from exc
        if (
            stat.S_ISLNK(current.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            rollback()
            raise ManifestRejected("process_identity_candidate_replaced")
    finally:
        os.close(descriptor)


def _pid_live(pid: Any, expected_identity: str | None = None) -> bool | None:
    numeric_pid = _numeric_pid(pid)
    if numeric_pid is None:
        return False
    pid = numeric_pid
    if expected_identity is not None:
        parsed_identity = _parse_process_identity(expected_identity)
        if parsed_identity is None or parsed_identity[0] != pid:
            return False
    probe_status, current_identity = _process_identity(pid)
    if probe_status == "unavailable":
        return None
    if probe_status != "captured":
        return False
    return expected_identity is None or current_identity == expected_identity


def _status_liveness(path: str) -> bool | None:
    """Return True/False for recognized status, None when no safe verdict exists."""
    verdict = probe_status_file(path)
    if verdict == "terminal":
        return False
    if verdict == "live":
        return True
    return None


def _open_directory_fd(path: str) -> int:
    """Open an existing directory without following caller-controlled links."""

    canonical = os.path.abspath(path)
    if sys.platform == "darwin":
        # Darwin exposes these two fixed, root-owned compatibility aliases.
        # Normalize only those known aliases; generic realpath() introduces a
        # check/use window where a caller-controlled ancestor can redirect the
        # subsequent descriptor walk.
        for alias, target in (("/var", "/private/var"), ("/tmp", "/private/tmp")):
            if canonical == alias or canonical.startswith(alias + os.path.sep):
                canonical = target + canonical[len(alias) :]
                break
    _reject_symlinked_ancestors(canonical)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(os.path.sep, flags)
        for component in canonical.split(os.path.sep)[1:]:
            if component in ("", "."):
                continue
            if component == "..":
                raise ManifestRejected("manifest_parent_path_traversal_rejected")
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        if "descriptor" in locals():
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise


def _secure_open_regular(path: str, flags: int, mode: int = 0o600) -> int:
    """Open a regular file relative to a no-follow parent directory handle."""

    absolute = os.path.abspath(path)
    if _uses_native_windows_filesystem():
        # Native Windows has no dir_fd/O_NOFOLLOW support.  Reject reparse-point
        # ancestors before opening, then bind the opened handle to the lstat
        # identity.  The containing user temp/state directory supplies the ACL.
        _reject_symlinked_ancestors(os.path.dirname(absolute))
        try:
            descriptor = os.open(
                absolute,
                flags | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOINHERIT", 0),
                mode,
            )
        except OSError as exc:
            raise ManifestRuntimeError(f"manifest_open_failed: {exc.errno}") from exc
        try:
            current = os.lstat(absolute)
            opened = os.fstat(descriptor)
            if (stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(opened.st_mode)
                    or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)):
                raise ManifestRejected("manifest_not_regular_file")
            return descriptor
        except Exception:
            os.close(descriptor)
            raise

    parent_descriptor = _open_directory_fd(os.path.dirname(absolute))
    try:
        descriptor = os.open(
            os.path.basename(path),
            flags | getattr(os, "O_NOFOLLOW", 0),
            mode,
            dir_fd=parent_descriptor,
        )
    except OSError as exc:
        raise ManifestRuntimeError(f"manifest_open_failed: {exc.errno}") from exc
    finally:
        os.close(parent_descriptor)
    target = os.fstat(descriptor)
    if not stat.S_ISREG(target.st_mode):
        os.close(descriptor)
        raise ManifestRejected("manifest_not_regular_file")
    return descriptor


class ArtifactIdentity(NamedTuple):
    device: int
    inode: int
    size: int
    mtime_ns: int
    identity_time_ns: int
    mode: int


class RawArtifactDescriptorState(NamedTuple):
    device: int
    inode: int
    size: int
    mtime_ns: int
    ctime_ns: int
    mode: int


def _artifact_raw_fd_state(entry: os.stat_result) -> RawArtifactDescriptorState:
    return RawArtifactDescriptorState(
        device=entry.st_dev,
        inode=entry.st_ino,
        size=entry.st_size,
        mtime_ns=getattr(
            entry, "st_mtime_ns", int(entry.st_mtime * 1_000_000_000)
        ),
        ctime_ns=getattr(
            entry, "st_ctime_ns", int(entry.st_ctime * 1_000_000_000)
        ),
        mode=entry.st_mode,
    )


def _artifact_identity(entry: os.stat_result) -> ArtifactIdentity:
    raw_state = _artifact_raw_fd_state(entry)
    if not _uses_native_windows_filesystem():
        return ArtifactIdentity(
            device=raw_state.device,
            inode=raw_state.inode,
            size=raw_state.size,
            mtime_ns=raw_state.mtime_ns,
            identity_time_ns=raw_state.ctime_ns,
            mode=raw_state.mode,
        )
    birthtime_ns = getattr(entry, "st_birthtime_ns", None)
    if birthtime_ns is None:
        birthtime = getattr(entry, "st_birthtime", None)
        birthtime_ns = (
            int(birthtime * 1_000_000_000)
            if birthtime is not None
            else raw_state.ctime_ns
        )
    execute_bits = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    return ArtifactIdentity(
        device=raw_state.device,
        inode=raw_state.inode,
        size=raw_state.size,
        mtime_ns=raw_state.mtime_ns,
        identity_time_ns=int(birthtime_ns),
        mode=raw_state.mode & ~execute_bits,
    )


def _artifact_descriptor_link_count_valid(
    entry: os.stat_result,
) -> bool:
    """Validate one still-open artifact descriptor's unique-carrier view."""

    if entry.st_nlink == 1:
        return True
    # Native Windows can expose st_nlink=0 through fstat() while an artifact
    # handle remains open. Every pathname snapshot must still report exactly
    # one link and bind to this descriptor identity.
    return _uses_native_windows_filesystem() and entry.st_nlink == 0


def secure_capture_regular(
    path: str, minimum_size: int, maximum_size: int
) -> tuple[bytes, ArtifactIdentity]:
    """Capture bounded bytes while proving one owned regular-file identity."""

    if (
        not isinstance(minimum_size, int)
        or isinstance(minimum_size, bool)
        or not isinstance(maximum_size, int)
        or isinstance(maximum_size, bool)
        or minimum_size < 0
        or maximum_size < minimum_size
    ):
        raise ManifestRejected("artifact_size_policy_invalid")
    absolute = os.path.abspath(path)
    try:
        before = os.lstat(absolute)
    except OSError as exc:
        raise ManifestRuntimeError("artifact_inspect_failed") from exc
    descriptor: int | None = None
    captured: tuple[bytes, ArtifactIdentity] | None = None
    failure: BaseException | None = None
    try:
        descriptor = _secure_open_regular(absolute, os.O_RDONLY)
        opened = os.fstat(descriptor)
        current = os.lstat(absolute)
        uid_fn = getattr(os, "geteuid", None)
        uid = uid_fn() if uid_fn is not None else None
        identity = _artifact_identity(opened)
        opened_raw_state = _artifact_raw_fd_state(opened)
        if _artifact_identity(before) != identity or _artifact_identity(current) != identity:
            raise ManifestRejected("artifact_replaced_during_capture")
        if (
            not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or before.st_nlink != 1
            or not _artifact_descriptor_link_count_valid(opened)
            or current.st_nlink != 1
            or (uid is not None and opened.st_uid != uid)
        ):
            raise ManifestRejected("artifact_not_owned_regular")
        if opened.st_size < minimum_size or opened.st_size > maximum_size:
            raise ManifestRejected("artifact_size_invalid")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65536))
            if not chunk:
                raise ManifestRejected("artifact_short_read")
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after_open = os.fstat(descriptor)
        after_path = os.lstat(absolute)
        if (
            _artifact_raw_fd_state(after_open) != opened_raw_state
            or _artifact_identity(after_path) != identity
        ):
            raise ManifestRejected("artifact_replaced_during_capture")
        if (
            not _artifact_descriptor_link_count_valid(after_open)
            or after_path.st_nlink != 1
        ):
            raise ManifestRejected("artifact_not_owned_regular")
        captured = payload, identity
    except (ManifestRejected, ManifestRuntimeError) as exc:
        failure = exc
    except OSError as exc:
        failure = ManifestRuntimeError("artifact_capture_failed")
        failure.__cause__ = exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                if failure is None:
                    failure = ManifestRuntimeError("artifact_capture_close_failed")
                    failure.__cause__ = exc
                else:
                    _record_cleanup_diagnostic(
                        failure, "artifact_capture_close_failed"
                    )
    if failure is not None:
        raise failure
    if captured is None:
        raise ManifestRuntimeError("artifact_capture_failed")
    return captured


def _artifact_inode_matches(
    entry: os.stat_result, identity: ArtifactIdentity
) -> bool:
    return entry.st_dev == identity.device and entry.st_ino == identity.inode


def secure_remove_published_regular(
    path: str, identity: ArtifactIdentity
) -> bool:
    """Refuse pathname-only rollback even when a snapshot still matches."""

    absolute = os.path.abspath(path)
    try:
        current = os.lstat(absolute)
    except FileNotFoundError:
        return True
    except OSError as exc:
        raise ManifestRuntimeError("artifact_cleanup_inspect_failed") from exc
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
        or not _artifact_inode_matches(current, identity)
    ):
        return False
    # POSIX and native Windows do not expose one portable primitive that means
    # "unlink this pathname iff it still names this descriptor."  A separate
    # unlink would re-open the check/use race.  Failed publications therefore
    # remain isolated under a unique attempt name and are never consumed.
    return False


def secure_remove_published_directory(
    path: str, identity: ArtifactIdentity
) -> bool:
    """Refuse pathname-only directory rollback even after an identity match."""

    absolute = os.path.abspath(path)
    try:
        current = os.lstat(absolute)
    except FileNotFoundError:
        return True
    except OSError as exc:
        raise ManifestRuntimeError("artifact_cleanup_inspect_failed") from exc
    if not stat.S_ISDIR(current.st_mode) or not _artifact_inode_matches(
        current, identity
    ):
        return False
    return False


def secure_capture_published(
    path: str,
    expected_digest: str,
    minimum_size: int,
    maximum_size: int,
) -> tuple[bytes, ArtifactIdentity]:
    """Capture published bytes and bind them to the caller's SHA-256 receipt."""

    if re.fullmatch(r"[0-9a-f]{64}", expected_digest or "") is None:
        raise ManifestRejected("artifact_digest_invalid")
    payload, identity = secure_capture_regular(path, minimum_size, maximum_size)
    if hashlib.sha256(payload).hexdigest() != expected_digest:
        raise ManifestRejected("artifact_digest_mismatch")
    return payload, identity


def _open_publication_attempt(
    requested_path: str, digest: str
) -> tuple[str, int]:
    for _ in range(16):
        token = secrets.token_hex(16)
        candidate = f"{requested_path}.attempt-{token}-{digest}"
        try:
            descriptor = _secure_open_regular(
                candidate, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600
            )
            return candidate, descriptor
        except ManifestRuntimeError as exc:
            if isinstance(exc.__cause__, FileExistsError):
                continue
            raise
    raise ManifestRuntimeError("artifact_attempt_collision")


def secure_publish_captured(
    path: str, payload: bytes
) -> tuple[str, ArtifactIdentity, str]:
    """Publish captured bytes under a unique, digest-qualified attempt path.

    The returned pathname is a carrier, not an immutable trust primitive.
    Every consumer must call ``secure_capture_published`` with the returned
    digest before interpreting its bytes.
    """

    if not isinstance(payload, bytes):
        raise ManifestRejected("artifact_payload_invalid")
    absolute = os.path.abspath(path)
    digest = hashlib.sha256(payload).hexdigest()
    candidate: str | None = None
    descriptor: int | None = None
    published_identity: ArtifactIdentity | None = None
    failure: BaseException | None = None
    try:
        candidate, descriptor = _open_publication_attempt(absolute, digest)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise ManifestRuntimeError("artifact_snapshot_short_write")
            offset += written
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not _artifact_descriptor_link_count_valid(opened)
            or opened.st_size != len(payload)
        ):
            raise ManifestRejected("artifact_snapshot_invalid")
        os.lseek(descriptor, 0, os.SEEK_SET)
        captured_chunks: list[bytes] = []
        remaining = len(payload)
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65536))
            if not chunk:
                raise ManifestRejected("artifact_snapshot_short_read")
            captured_chunks.append(chunk)
            remaining -= len(chunk)
        captured = b"".join(captured_chunks)
        if hashlib.sha256(captured).hexdigest() != digest:
            raise ManifestRejected("artifact_snapshot_digest_mismatch")
        # Native Windows keeps the successful carrier writable: trust comes
        # from descriptor capture plus the digest receipt, not a pathname
        # attribute.  Crucially, failed attempts were created writable too, so
        # Windows retries can never be wedged by a read-only partial target.
        if os.name != "nt":
            os.fchmod(descriptor, 0o400)
        finalized = os.fstat(descriptor)
        current = os.lstat(candidate)
        uid_fn = getattr(os, "geteuid", None)
        uid = uid_fn() if uid_fn is not None else None
        published_identity = _artifact_identity(finalized)
        if _artifact_identity(current) != published_identity:
            raise ManifestRejected("artifact_snapshot_identity_changed")
        if (
            not stat.S_ISREG(finalized.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or not _artifact_descriptor_link_count_valid(finalized)
            or current.st_nlink != 1
            or finalized.st_size != len(payload)
            or current.st_size != len(payload)
            or (uid is not None and finalized.st_uid != uid)
            or (uid is not None and current.st_uid != uid)
            or (
                os.name != "nt"
                and (
                    stat.S_IMODE(finalized.st_mode) != 0o400
                    or stat.S_IMODE(current.st_mode) != 0o400
                )
            )
        ):
            raise ManifestRejected("artifact_snapshot_invalid")
    except (ManifestRejected, ManifestRuntimeError) as exc:
        failure = exc
    except OSError as exc:
        failure = ManifestRuntimeError("artifact_snapshot_failed")
        failure.__cause__ = exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                if failure is None:
                    failure = ManifestRuntimeError("artifact_snapshot_close_failed")
                    failure.__cause__ = exc
                else:
                    _record_cleanup_diagnostic(
                        failure, "artifact_snapshot_close_failed"
                    )
    if failure is not None:
        raise failure
    if candidate is None or published_identity is None:
        raise ManifestRuntimeError("artifact_snapshot_failed")
    return candidate, published_identity, digest


def _lock_manifest_descriptor(descriptor: int) -> None:
    if _fcntl is not None:
        _fcntl.flock(descriptor, _fcntl.LOCK_EX)
        return
    if _msvcrt is None:
        raise ManifestRuntimeError("manifest_lock_unavailable")
    while True:
        os.lseek(descriptor, 0, os.SEEK_SET)
        try:
            _msvcrt.locking(descriptor, _msvcrt.LK_NBLCK, 1)
            return
        except OSError as exc:
            if exc.errno not in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                raise ManifestRuntimeError(
                    f"manifest_lock_failed: {exc.errno}"
                ) from exc
            time.sleep(0.05)


def _unlock_manifest_descriptor(descriptor: int) -> None:
    if _fcntl is not None:
        _fcntl.flock(descriptor, _fcntl.LOCK_UN)
        return
    if _msvcrt is None:
        return
    os.lseek(descriptor, 0, os.SEEK_SET)
    _msvcrt.locking(descriptor, _msvcrt.LK_UNLCK, 1)


@contextmanager
def _locked_manifest(path: str) -> Iterable[int]:
    """Hold an advisory inode lock while lifecycle state is checked and changed."""

    descriptor = _secure_open_regular(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if os.name != "nt":
            os.fchmod(descriptor, 0o600)
        _lock_manifest_descriptor(descriptor)
        yield descriptor
    finally:
        try:
            _unlock_manifest_descriptor(descriptor)
        finally:
            os.close(descriptor)


def _probe_status_snapshot(path: str) -> tuple[str, dict[str, Any] | None]:
    """Read one status atomically enough for liveness and terminal truth."""

    if not path:
        return "unknown", None
    parent_descriptor: int | None = None
    descriptor: int | None = None
    try:
        parent_descriptor = _open_directory_fd(os.path.dirname(os.path.abspath(path)))
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(os.path.basename(path), flags, dir_fd=parent_descriptor)
        target = os.fstat(descriptor)
        if not stat.S_ISREG(target.st_mode) or target.st_size > 65536:
            raise ManifestRejected("status_probe_invalid_file")
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = None
            raw = handle.read(65537)
    except (FileNotFoundError, PermissionError):
        # A launcher may publish the status path before the first atomic status
        # write, and may remove it during cleanup.  Absence is not structural
        # corruption; it is simply no evidence that an opaque backend is live.
        return "unknown", None
    except (OSError, UnicodeError, ManifestRuntimeError) as exc:
        raise ManifestRejected("status_probe_unreadable") from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if parent_descriptor is not None:
            try:
                os.close(parent_descriptor)
            except OSError:
                pass
    if len(raw) > 65536:
        raise ManifestRejected("status_probe_too_large")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestRejected("status_probe_malformed_json") from exc
    if not isinstance(parsed, dict):
        raise ManifestRejected("status_probe_not_object")
    canonical_keys = [
        key for key in ("state", "status", "terminal_status") if key in parsed
    ]
    if len(canonical_keys) != 1:
        raise ManifestRejected("status_probe_ambiguous_state")
    state: Any = parsed[canonical_keys[0]]
    if not isinstance(state, str) or not state.strip():
        raise ManifestRejected("status_probe_invalid_state")
    normalized = state.strip().lower()
    if normalized in TERMINAL_EVENTS:
        return "terminal", parsed
    if normalized in {"running", "busy", "starting", "working", "queued"}:
        return "live", parsed
    return "unknown", parsed


def probe_status_file(path: str) -> str:
    """Return live, terminal, or unknown from one canonical top-level state."""

    verdict, _ = _probe_status_snapshot(path)
    return verdict


def _terminal_truth_from_snapshot(
    started: dict[str, Any], verdict: str, snapshot: dict[str, Any] | None
) -> str | None:
    """Validate terminal truth without importing arbitrary status fields."""

    if verdict != "terminal" or snapshot is None:
        return None
    state_keys = [
        key for key in ("state", "status", "terminal_status") if key in snapshot
    ]
    if len(state_keys) != 1:
        return None
    terminal = str(snapshot[state_keys[0]]).strip().lower()
    if terminal not in {"completed", "failed", "timed_out", "cancelled"}:
        return None
    if snapshot.get("backend") != started.get("backend"):
        return None
    exit_code = snapshot.get("exit_code")
    if not _is_plain_int(exit_code):
        return None
    if terminal == "completed" and exit_code != 0:
        return None
    if terminal != "completed" and exit_code == 0:
        return None
    reported_keys = [key for key in ("pid", "backend_handle") if key in snapshot]
    if len(reported_keys) > 1:
        return None
    reported_identity = None
    if reported_keys:
        reported_identity = _canonical_backend_handle(snapshot[reported_keys[0]])
        if reported_identity is None:
            return None
    expected_handle = started.get("backend_handle")
    if expected_handle not in (None, "") and reported_identity is not None:
        expected_identity = _canonical_backend_handle(expected_handle)
        if expected_identity is None or reported_identity != expected_identity:
            return None
    return terminal


def _canonical_backend_handle(value: Any) -> str | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value) if value > 0 else None
    if not isinstance(value, str) or not value:
        return None
    numeric = value[4:] if value.startswith("pid:") else value
    if numeric.isdigit():
        return numeric if re.fullmatch(r"[1-9][0-9]*", numeric) else None
    return value if _IDENTIFIER_PATTERN.fullmatch(value) is not None else None


def validated_terminal_status(
    path: str, expected_backend: str, expected_handle: str | None
) -> str | None:
    """Return terminal truth only after the shared canonical status checks."""

    try:
        verdict, snapshot = _probe_status_snapshot(path)
    except (ManifestRejected, ManifestRuntimeError):
        return None
    started: dict[str, Any] = {"backend": expected_backend}
    if expected_handle not in (None, ""):
        started["backend_handle"] = expected_handle
    return _terminal_truth_from_snapshot(started, verdict, snapshot)


def _canonical_terminal_truth(started: dict[str, Any]) -> str | None:
    """Return validated provider terminal truth without importing status payload."""

    status_path = started.get("status_path")
    if not isinstance(status_path, str):
        return None
    verdict, snapshot = _probe_status_snapshot(status_path)
    return _terminal_truth_from_snapshot(started, verdict, snapshot)


def _reconciliation_status(
    started: dict[str, Any],
) -> tuple[bool | None, str | None, str | None, str | None]:
    """Classify one secure snapshot for reconciliation exactly once.

    Invalid, contradictory, missing, and unsafe snapshots are unavailable
    evidence. They never force a backend dead before its numeric handle probe.
    """

    status_path = started.get("status_path")
    if not isinstance(status_path, str):
        return None, None, None, None
    try:
        verdict, snapshot = _probe_status_snapshot(status_path)
    except (ManifestRejected, ManifestRuntimeError):
        return None, None, None, None
    terminal_truth = _terminal_truth_from_snapshot(started, verdict, snapshot)
    if terminal_truth is not None:
        return False, terminal_truth, None, None
    if snapshot is None:
        return None, None, None, None
    expected_backend = started.get("backend")
    reported_backend = snapshot.get("backend")
    if reported_backend is not None and reported_backend != expected_backend:
        return None, None, None, None
    recovered_identity = snapshot.get("process_identity")
    parsed_recovered_identity = _parse_process_identity(recovered_identity)
    if recovered_identity is not None and parsed_recovered_identity is None:
        return None, None, None, None
    recovered_handle: str | None = None
    needs_numeric_recovery = (
        started.get("backend_handle") in (None, "")
        and expected_backend in {"codex", "background"}
    )
    if needs_numeric_recovery:
        if reported_backend != expected_backend:
            return None, None, None, None
        reported_keys = [key for key in ("pid", "backend_handle") if key in snapshot]
        if len(reported_keys) == 1:
            candidate = _canonical_backend_handle(snapshot[reported_keys[0]])
            if candidate is not None and candidate.isdigit():
                recovered_handle = candidate
        if recovered_handle is None:
            return None, None, None, None
    if recovered_identity is not None:
        identity_handle = recovered_handle
        if identity_handle is None:
            identity_handle = _canonical_backend_handle(started.get("backend_handle"))
        if (
            identity_handle is None
            or not identity_handle.isdigit()
            or parsed_recovered_identity is None
            or parsed_recovered_identity[0] != int(identity_handle)
        ):
            return None, None, None, None
    if verdict == "live":
        return True, None, recovered_handle, recovered_identity
    return None, None, recovered_handle, recovered_identity


def _lease_generation(payload: bytes) -> str:
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeError as exc:
        raise ManifestRejected("lease_payload_not_utf8") from exc
    values = [line.split("=", 1)[1] for line in lines if line.startswith("generation=")]
    if len(values) != 1 or re.fullmatch(r"[0-9a-f]{32}", values[0]) is None:
        raise ManifestRejected("lease_generation_invalid")
    return values[0]


def _read_bounded_descriptor(descriptor: int, limit: int = 16384) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    payload = os.read(descriptor, limit + 1)
    if len(payload) > limit:
        raise ManifestRejected("lease_payload_too_large")
    return payload


def _validated_lease_capability_path(path: str, generation: str) -> tuple[str, str]:
    if (
        not isinstance(path, str)
        or not os.path.isabs(path)
        or any(character in path for character in ("\x00", "\n", "\r"))
    ):
        raise ManifestRejected("lease_path_must_be_absolute")
    if any(component in {".", ".."} for component in re.split(r"[\\/]", path)):
        raise ManifestRejected("lease_path_traversal_rejected")
    absolute = os.path.abspath(path)
    if not os.path.isabs(absolute):
        raise ManifestRejected("lease_path_must_be_absolute")
    name = os.path.basename(absolute)
    if (
        re.fullmatch(r"[0-9a-f]{64}\.lease", name) is None
        or re.fullmatch(r"[0-9a-f]{32}", generation) is None
        or not name.startswith(generation)
    ):
        raise ManifestRejected("lease_generation_mismatch")
    parent = os.path.dirname(absolute)
    _reject_symlinked_ancestors(parent)
    try:
        parent_entry = os.lstat(parent)
    except OSError as exc:
        raise ManifestRuntimeError("lease_parent_unavailable") from exc
    if stat.S_ISLNK(parent_entry.st_mode) or not stat.S_ISDIR(parent_entry.st_mode):
        raise ManifestRejected("lease_parent_not_directory")
    if hasattr(os, "geteuid") and parent_entry.st_uid != os.geteuid():
        raise ManifestRejected("lease_parent_not_owned_by_user")
    return absolute, name


def _parse_lease_identity(identity: str) -> tuple[int, int]:
    if not isinstance(identity, str):
        raise ManifestRejected("lease_identity_invalid")
    matched = _LEASE_IDENTITY_PATTERN.fullmatch(identity)
    if matched is None:
        raise ManifestRejected("lease_identity_invalid")
    device, inode = (int(value) for value in matched.groups())
    if device > (1 << 64) - 1 or inode > (1 << 64) - 1:
        raise ManifestRejected("lease_identity_invalid")
    return device, inode


def secure_lease_identity(path: str, generation: str) -> tuple[int, int]:
    """Return one native-Python identity for an exact capability lease."""

    absolute, name = _validated_lease_capability_path(path, generation)
    parent_descriptor: int | None = None
    descriptor: int | None = None
    try:
        if os.name == "nt":
            if not os.path.lexists(absolute):
                raise ManifestRuntimeError("lease_missing")
            descriptor = _secure_open_regular(absolute, os.O_RDONLY)
            current = os.lstat(absolute)
        else:
            parent_descriptor = _open_directory_fd(os.path.dirname(absolute))
            try:
                descriptor = os.open(
                    name,
                    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent_descriptor,
                )
            except FileNotFoundError as exc:
                raise ManifestRuntimeError("lease_missing") from exc
            current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(current.st_mode):
            raise ManifestRejected("lease_not_regular")
        if _lease_generation(_read_bounded_descriptor(descriptor)) != generation:
            raise ManifestRejected("lease_generation_mismatch")
        identity = (opened.st_dev, opened.st_ino)
        if (current.st_dev, current.st_ino) != identity:
            raise ManifestRejected("lease_replaced_during_identity")
        return identity
    except (ManifestRejected, ManifestRuntimeError):
        raise
    except OSError as exc:
        raise ManifestRuntimeError("lease_identity_unavailable") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent_descriptor is not None:
            os.close(parent_descriptor)


def secure_write_lease(path: str, payload: bytes) -> tuple[int, int]:
    """Publish a private lease and return its ``(device, inode)`` identity.

    POSIX publication holds the parent directory descriptor across the atomic
    replace. The native-Windows branch uses validated absolute paths because
    Python does not expose the required ``dir_fd`` operations there; its caller
    must supply a private parent directory with an already-validated ACL because
    this helper does not establish or audit that directory ACL.
    """

    if len(payload) > 16384 or not payload.endswith(b"\n"):
        raise ManifestRejected("lease_payload_invalid")
    name = os.path.basename(path)
    if re.fullmatch(r"[0-9a-f]{64}\.lease", name) is None:
        raise ManifestRejected("lease_name_invalid")
    generation = _lease_generation(payload)
    if not name.startswith(generation):
        raise ManifestRejected("lease_generation_mismatch")
    if os.name == "nt":
        absolute = os.path.abspath(path)
        parent = os.path.dirname(absolute)
        _reject_symlinked_ancestors(parent)
        temporary_path = os.path.join(parent, f".lease.tmp.{secrets.token_hex(16)}")
        descriptor: int | None = None
        try:
            if os.path.lexists(absolute):
                existing = _secure_open_regular(absolute, os.O_RDONLY)
                try:
                    if _lease_generation(_read_bounded_descriptor(existing)) != generation:
                        raise ManifestRejected("lease_generation_mismatch")
                finally:
                    os.close(existing)
            descriptor = _secure_open_regular(
                temporary_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
            )
            if os.write(descriptor, payload) != len(payload):
                raise ManifestRuntimeError("lease_short_write")
            os.close(descriptor)
            descriptor = None
            os.replace(temporary_path, absolute)
            published = os.stat(absolute, follow_symlinks=False)
            if not stat.S_ISREG(published.st_mode):
                raise ManifestRejected("lease_not_regular")
            return published.st_dev, published.st_ino
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass
    parent_descriptor = _open_directory_fd(os.path.dirname(os.path.abspath(path)))
    temporary = f".lease.tmp.{secrets.token_hex(16)}"
    descriptor: int | None = None
    try:
        try:
            existing = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_descriptor,
            )
        except FileNotFoundError:
            existing = None
        if existing is not None:
            try:
                if _lease_generation(_read_bounded_descriptor(existing)) != generation:
                    raise ManifestRejected("lease_generation_mismatch")
            finally:
                os.close(existing)
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        if os.name != "nt":
            os.fchmod(descriptor, 0o600)
        if os.write(descriptor, payload) != len(payload):
            raise ManifestRuntimeError("lease_short_write")
        published = os.fstat(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(
            temporary,
            name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (published.st_dev, published.st_ino):
            raise ManifestRejected("lease_replaced_after_publish")
        return published.st_dev, published.st_ino
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass
        os.close(parent_descriptor)


def secure_remove_lease(path: str, generation: str, identity: str) -> None:
    """Remove only the exact generation named by a capability lease path."""

    absolute, name = _validated_lease_capability_path(path, generation)
    expected_identity = _parse_lease_identity(identity)
    if os.name == "nt":
        if not os.path.lexists(absolute):
            return
        descriptor: int | None = None
        try:
            descriptor = _secure_open_regular(absolute, os.O_RDONLY)
            target = os.fstat(descriptor)
            if not stat.S_ISREG(target.st_mode):
                raise ManifestRejected("lease_not_regular")
            if (target.st_dev, target.st_ino) != expected_identity:
                raise ManifestRejected("lease_identity_mismatch")
            if _lease_generation(_read_bounded_descriptor(descriptor)) != generation:
                raise ManifestRejected("lease_generation_mismatch")
            current = os.lstat(absolute)
            if (
                not stat.S_ISREG(current.st_mode)
                or (current.st_dev, current.st_ino) != expected_identity
            ):
                raise ManifestRejected("lease_replaced_before_remove")
            os.close(descriptor)
            descriptor = None
            current = os.lstat(absolute)
            if (
                not stat.S_ISREG(current.st_mode)
                or (current.st_dev, current.st_ino) != expected_identity
            ):
                raise ManifestRejected("lease_replaced_before_remove")
            os.unlink(absolute)
            return
        except FileNotFoundError:
            return
        except (ManifestRejected, ManifestRuntimeError):
            raise
        except OSError as exc:
            raise ManifestRuntimeError("lease_remove_failed") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
    parent_descriptor = _open_directory_fd(os.path.dirname(absolute))
    descriptor: int | None = None
    try:
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_descriptor,
            )
        except FileNotFoundError:
            return
        target = os.fstat(descriptor)
        if not stat.S_ISREG(target.st_mode):
            raise ManifestRejected("lease_not_regular")
        if (target.st_dev, target.st_ino) != expected_identity:
            raise ManifestRejected("lease_identity_mismatch")
        if _lease_generation(_read_bounded_descriptor(descriptor)) != generation:
            raise ManifestRejected("lease_generation_mismatch")
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != expected_identity:
            raise ManifestRejected("lease_replaced_before_remove")
        os.unlink(name, dir_fd=parent_descriptor)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent_descriptor)


def _backend_live(
    started: dict[str, Any],
    status: bool | None = None,
    *,
    status_known: bool = False,
    expected_identity: str | None = None,
) -> bool | None:
    """Apply the shared backend-liveness matrix used by live-semaphore.sh.

    Terminal status is always dead. Status-only and opaque handles are live
    only from live status. Numeric and ``pid:<numeric>`` handles use the
    process probe exclusively, so stale live status cannot revive a dead PID.
    """

    if not status_known:
        status_path = started.get("status_path")
        if isinstance(status_path, str):
            status = _status_liveness(status_path)
    if status is False:
        return False
    handle = started.get("backend_handle")
    if handle in (None, ""):
        return status is True
    if _numeric_pid(handle) is not None:
        return _pid_live(handle, expected_identity)
    if isinstance(handle, str):
        if handle.startswith("pid:"):
            return False
        if status is True:
            return True
        # Opaque handles are valid only with a canonical status path.  If that
        # probe is now missing/unknown, it is not evidence of a live backend;
        # the separate owner PID still prevents premature abandonment.
        return False
    return False


def _atomic_append(
    path: str, event: dict[str, Any], locked_descriptor: int | None = None
) -> None:
    payload = (_compact_json(event) + "\n").encode("utf-8")
    if len(payload) > 65536:
        raise ManifestRejected("event_record_too_large")
    owns_descriptor = not (os.name == "nt" and locked_descriptor is not None)
    if owns_descriptor:
        flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY
        descriptor = _secure_open_regular(path, flags, 0o600)
    else:
        # Windows byte-range locks also block a second handle in this process.
        # Write through the handle that owns the lock; its critical section
        # serializes the seek-to-end plus the single write.
        descriptor = locked_descriptor
        assert descriptor is not None
        os.lseek(descriptor, 0, os.SEEK_END)
    original_length: int | None = None
    try:
        opened = os.fstat(descriptor)
        if locked_descriptor is not None:
            locked = os.fstat(locked_descriptor)
            if (locked.st_dev, locked.st_ino) != (opened.st_dev, opened.st_ino):
                raise ManifestRejected("manifest_replaced_during_append")
            original_length = locked.st_size
        else:
            original_length = opened.st_size
        if os.name != "nt":
            os.fchmod(descriptor, 0o600)
        try:
            written = os.write(descriptor, payload)
        except OSError as exc:
            try:
                os.ftruncate(descriptor, original_length)
            except OSError as rollback_exc:
                raise ManifestRuntimeError("manifest_rollback_failed") from rollback_exc
            raise ManifestRuntimeError("manifest_short_write") from exc
        if written != len(payload):
            try:
                os.ftruncate(descriptor, original_length)
            except OSError as exc:
                raise ManifestRuntimeError("manifest_rollback_failed") from exc
            raise ManifestRuntimeError("manifest_short_write")
    finally:
        if owns_descriptor:
            os.close(descriptor)


def _normalized_append_event(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ManifestRejected("event_record_must_be_object")
    event = dict(raw)
    event.setdefault("schema_version", SCHEMA_VERSION)
    if event.get("schema_version") != SCHEMA_VERSION:
        raise ManifestRejected("append_requires_current_schema")
    event.setdefault("timestamp", _utc_now())
    if event.get("event") in TERMINAL_EVENTS:
        event.setdefault("terminal_status", event["event"])
    errors = _validate_event(event)
    if errors:
        raise ManifestRejected(errors[0])
    if event.get("event") == "agent_started":
        backend_handle = event.get("backend_handle")
        if backend_handle not in (None, "") and not _pid_handle(backend_handle):
            status_path = event.get("status_path")
            assert isinstance(status_path, str)
            probe_status_file(status_path)
    return event


def append_event(path: str, raw_event: Any) -> dict[str, Any]:
    prepared = _prepare_private_path(path)
    event = _normalized_append_event(raw_event)
    with _locked_manifest(prepared) as descriptor:
        records, read_errors = _read_records_from_descriptor(descriptor)
        states, lifecycle_errors, _ = _evaluate(records, strict=False)
        del states
        if read_errors or lifecycle_errors:
            raise ManifestRejected((read_errors + lifecycle_errors)[0])
        line_number = records[-1][0] + 1 if records else 1
        _, new_errors, _ = _evaluate(records + [(line_number, event)], strict=False)
        if new_errors:
            raise ManifestRejected(new_errors[-1])
        _atomic_append(prepared, event, descriptor)
    return {"event": event["event"], "run_id": event["run_id"], "status": "appended"}


def verify_manifest(path: str, *, strict: bool) -> tuple[dict[str, Any], int]:
    absolute = os.path.abspath(os.path.expanduser(path))
    if not os.path.exists(absolute):
        return {"errors": ["manifest_not_found"], "status": "invalid"}, 1
    try:
        records, read_errors = _read_records(absolute)
        states, lifecycle_errors, count = _evaluate(records, strict=strict)
    except (ManifestRejected, ManifestRuntimeError) as exc:
        return {"errors": [str(exc)], "status": "invalid"}, 1
    errors = read_errors + lifecycle_errors
    if errors:
        return {"errors": errors, "status": "invalid"}, 1
    return {"events": count, "runs": len(states), "status": "ok"}, 0


def reconcile_manifest(path: str) -> dict[str, Any]:
    prepared = _prepare_private_path(path)
    abandoned_count = 0
    appended_count = 0
    with _locked_manifest(prepared) as descriptor:
        records, read_errors = _read_records_from_descriptor(descriptor)
        states, lifecycle_errors, _ = _evaluate(records, strict=False)
        errors = read_errors + lifecycle_errors
        if errors:
            raise ManifestRejected(errors[0])
        for identity in sorted(states):
            state = states[identity]
            if state.started is None or state.terminal is not None:
                continue
            (
                status_liveness,
                terminal_truth,
                recovered_handle,
                recovered_identity,
            ) = _reconciliation_status(state.started)
            if terminal_truth is not None:
                run_id, agent_id = identity
                terminal: dict[str, Any] = {
                    "schema_version": state.started["schema_version"],
                    "event": terminal_truth,
                    "timestamp": _utc_not_before(state.last_timestamp),
                    "run_id": run_id,
                    "backend": state.started["backend"],
                    "terminal_status": terminal_truth,
                }
                error_classes = {
                    "failed": "provider_failed",
                    "timed_out": "provider_timed_out",
                    "cancelled": "provider_cancelled",
                }
                if terminal_truth in error_classes:
                    terminal["error_class"] = error_classes[terminal_truth]
                if agent_id:
                    terminal["agent_id"] = agent_id
                for field in (
                    "parent_run_id",
                    "workflow",
                    "phase",
                    "role",
                    "issue_or_pr",
                ):
                    if state.started.get(field) is not None:
                        terminal[field] = state.started[field]
                validation_errors = _validate_event(terminal)
                if validation_errors:
                    raise ManifestRuntimeError(validation_errors[0])
                line_number = (records[-1][0] if records else 0) + appended_count + 1
                transition_errors = _transition(state, terminal, line_number)
                if transition_errors:
                    raise ManifestRuntimeError(transition_errors[0])
                _atomic_append(prepared, terminal, descriptor)
                appended_count += 1
                continue
            owner_live = _pid_live(
                state.started.get("owner_pid"),
                state.started.get("owner_process_identity"),
            )
            backend_state = state.started
            if recovered_handle is not None:
                backend_state = dict(state.started, backend_handle=recovered_handle)
            backend_live = _backend_live(
                backend_state,
                status_liveness,
                status_known=True,
                expected_identity=recovered_identity,
            )
            unavailable = []
            if owner_live is None:
                unavailable.append("owner")
            if backend_live is None:
                unavailable.append("backend")
            if unavailable:
                raise ManifestRuntimeError(
                    "process_identity_probe_unavailable: " + ",".join(unavailable)
                )
            if owner_live or backend_live:
                continue
            run_id, agent_id = identity
            terminal: dict[str, Any] = {
                "schema_version": state.started["schema_version"],
                "event": "abandoned",
                "timestamp": _utc_not_before(state.last_timestamp),
                "run_id": run_id,
                "backend": state.started["backend"],
                "terminal_status": "abandoned",
                "error_class": "orphaned",
            }
            if agent_id:
                terminal["agent_id"] = agent_id
            for field in ("parent_run_id", "workflow", "phase", "role", "issue_or_pr"):
                if state.started.get(field) is not None:
                    terminal[field] = state.started[field]
            validation_errors = _validate_event(terminal)
            if validation_errors:
                raise ManifestRuntimeError(validation_errors[0])
            line_number = (records[-1][0] if records else 0) + appended_count + 1
            transition_errors = _transition(state, terminal, line_number)
            if transition_errors:
                raise ManifestRuntimeError(transition_errors[0])
            _atomic_append(prepared, terminal, descriptor)
            abandoned_count += 1
            appended_count += 1
        open_count = sum(
            1
            for state in states.values()
            if state.started is not None and state.terminal is None
        )
    return {"abandoned": abandoned_count, "open": open_count, "status": "ok"}


def _read_event_argument(value: str) -> Any:
    try:
        raw = sys.stdin.read() if value == "-" else value
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestRejected("invalid_event_json") from exc


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="UberDev append-only agent lifecycle manifest")
    subparsers = parser.add_subparsers(dest="command", required=True)

    append_parser = subparsers.add_parser("append", help="validate and append one event")
    append_parser.add_argument("--manifest", "--path", dest="manifest", required=True)
    append_parser.add_argument(
        "--event-json", "--input-json", dest="event_json", required=True,
        help="event JSON object, or '-' to read stdin",
    )

    reconcile_parser = subparsers.add_parser("reconcile", help="append abandoned for dead orphans")
    reconcile_parser.add_argument("--manifest", "--path", dest="manifest", required=True)

    status_parser = subparsers.add_parser(
        "probe-status", help="validate and classify one canonical backend status file"
    )
    status_parser.add_argument("--status-path", required=True)

    terminal_parser = subparsers.add_parser("probe-terminal", help=argparse.SUPPRESS)
    terminal_parser.add_argument("--status-path", required=True)
    terminal_parser.add_argument("--expected-backend", required=True)
    terminal_parser.add_argument("--expected-handle")

    identity_parser = subparsers.add_parser("process-identity", help=argparse.SUPPRESS)
    identity_parser.add_argument("--pid", required=True)

    owner_parser = subparsers.add_parser("write-process-identity", help=argparse.SUPPRESS)
    owner_parser.add_argument("--mode", choices=("direct", "parent"), required=True)
    owner_parser.add_argument("--destination", required=True)

    lease_write_parser = subparsers.add_parser(
        "secure-write-lease", help=argparse.SUPPRESS
    )
    lease_write_parser.add_argument("--lease-path", required=True)

    lease_identity_parser = subparsers.add_parser(
        "secure-lease-identity", help=argparse.SUPPRESS
    )
    lease_identity_parser.add_argument("--lease-path", required=True)
    lease_identity_parser.add_argument("--generation", required=True)

    lease_remove_parser = subparsers.add_parser(
        "secure-remove-lease", help=argparse.SUPPRESS
    )
    lease_remove_parser.add_argument("--lease-path", required=True)
    lease_remove_parser.add_argument("--generation", required=True)
    lease_remove_parser.add_argument("--identity", required=True)

    verify_parser = subparsers.add_parser("verify", help="validate JSONL and lifecycle transitions")
    verify_parser.add_argument("--manifest", "--path", dest="manifest", required=True)
    verify_parser.add_argument("--strict", action="store_true", help="require a terminal for every start")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "append":
            _emit(append_event(args.manifest, _read_event_argument(args.event_json)))
            return 0
        if args.command == "reconcile":
            _emit(reconcile_manifest(args.manifest))
            return 0
        if args.command == "probe-status":
            print(probe_status_file(args.status_path))
            return 0
        if args.command == "probe-terminal":
            print(
                validated_terminal_status(
                    args.status_path, args.expected_backend, args.expected_handle
                )
                or "unknown"
            )
            return 0
        if args.command == "process-identity":
            cleanup_diagnostics: list[dict[str, str]] = []
            status, identity = _process_identity(
                args.pid, cleanup_diagnostics=cleanup_diagnostics
            )
            if cleanup_diagnostics:
                print(
                    _compact_json(
                        {
                            "cleanup_diagnostic": cleanup_diagnostics[0],
                            "process_identity_status": status,
                            "status": "warning",
                        }
                    ),
                    file=sys.stderr,
                )
            if status == "captured" and identity is not None:
                print(identity, end="")
                return 0
            return 1 if status == "absent" else 2
        if args.command == "write-process-identity":
            _write_process_identity(args.mode, args.destination)
            return 0
        if args.command == "secure-write-lease":
            device, inode = secure_write_lease(
                args.lease_path, sys.stdin.buffer.read(16385)
            )
            print(f"{device}:{inode}", end="")
            return 0
        if args.command == "secure-lease-identity":
            device, inode = secure_lease_identity(args.lease_path, args.generation)
            print(f"{device}:{inode}", end="")
            return 0
        if args.command == "secure-remove-lease":
            secure_remove_lease(args.lease_path, args.generation, args.identity)
            return 0
        result, return_code = verify_manifest(args.manifest, strict=args.strict)
        _emit(result)
        return return_code
    except ManifestRejected as exc:
        payload: dict[str, Any] = {"error": str(exc), "status": "rejected"}
        diagnostic = _cleanup_diagnostic(exc)
        if diagnostic is not None:
            payload["cleanup_diagnostic"] = diagnostic
        _emit(payload)
        return 2
    except ManifestRuntimeError as exc:
        payload = {"error": str(exc), "status": "error"}
        diagnostic = _cleanup_diagnostic(exc)
        if diagnostic is not None:
            payload["cleanup_diagnostic"] = diagnostic
        _emit(payload)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
