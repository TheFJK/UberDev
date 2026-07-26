#!/usr/bin/env python3
"""Verify the durable source-owned provider callsite contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SOURCE_FILES = (
    "plugins/uberdev/skills/brainstorm/SKILL.md",
    "plugins/uberdev/skills/orchestrator/SKILL.md",
    "plugins/uberdev/skills/subagent-driven-dev/SKILL.md",
    "plugins/uberdev/skills/post-impl-review/SKILL.md",
    "plugins/uberdev/commands/review-pr.md",
)
CONTRACT_BLOCK = re.compile(
    r"<!-- BEGIN child-callsite-contracts-v1 -->\s*```json\s*(.*?)\s*```\s*"
    r"<!-- END child-callsite-contracts-v1 -->",
    re.DOTALL,
)
EDGE = re.compile(r"[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+")
ROW_KEYS = {"inputs", "optional_inputs", "allowed_workflows", "risk_scope", "risk_argument"}
WORKFLOWS = {"review-pr", "simplify", "solve", "turbo"}
FORMAT_INPUTS = {"format_example_path", "format_retry"}
TYPE_MAP_KEYS = {"required_input_types", "optional_input_types"}
INPUT_TYPES = {
    "boolean",
    "directory",
    "integer",
    "optional_path",
    "optional_path_array",
    "optional_string",
    "path",
    "path_array",
    "repo_path_array",
    "string",
    "string_array",
}


class ContractFailure(Exception):
    pass


def fail(message: str) -> None:
    raise ContractFailure(message)


def _string_list(value: Any, label: str, *, nonempty: bool = False) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        fail(f"{label}: expected string list")
    if nonempty and not value:
        fail(f"{label}: empty list")
    if len(value) != len(set(value)):
        fail(f"{label}: duplicate value")
    return value


def _risk_argument(scope: str) -> Any:
    return {"none": [], "subtask": "subtask", "run": None}[scope]


def _load_contract(relative: str, text: str) -> dict[str, Any]:
    matches = CONTRACT_BLOCK.findall(text)
    if len(matches) != 1:
        fail(f"{relative}: expected exactly one child-callsite-contracts-v1 block")
    try:
        rows = json.loads(matches[0])
    except Exception as error:
        fail(f"{relative}: invalid contract JSON: {error}")
    if not isinstance(rows, dict) or not rows:
        fail(f"{relative}: contract block must be a non-empty object")
    return rows


def parse_source(relative: str, text: str) -> list[dict[str, Any]]:
    raw_rows = _load_contract(relative, text)
    rows: list[dict[str, Any]] = []
    for edge, raw in raw_rows.items():
        if not isinstance(edge, str) or not EDGE.fullmatch(edge) or not isinstance(raw, dict) or set(raw) != ROW_KEYS:
            fail(f"{relative}: invalid row schema for {edge!r}")
        required = _string_list(raw["inputs"], f"{edge}.inputs")
        optional = _string_list(raw["optional_inputs"], f"{edge}.optional_inputs")
        workflows = _string_list(raw["allowed_workflows"], f"{edge}.allowed_workflows", nonempty=True)
        if set(required) & set(optional):
            fail(f"{edge}: required/optional inputs overlap")
        if workflows != sorted(workflows) or not set(workflows) <= WORKFLOWS:
            fail(f"{edge}: allowed workflows must be sorted and closed")
        scope = raw["risk_scope"]
        if scope not in {"none", "subtask", "run"} or raw["risk_argument"] != _risk_argument(scope):
            fail(f"{edge}: risk scope/argument mismatch")
        rows.append(
            {
                "edge_id": edge,
                "source": relative,
                "required_inputs": sorted(required),
                "optional_inputs": sorted(optional),
                "allowed_workflows": workflows,
                "risk_scope": scope,
                "risk_argument": raw["risk_argument"],
            }
        )
    return rows


def collect_sources(root: Path, overrides: dict[str, str] | None = None) -> list[dict[str, Any]]:
    overrides = overrides or {}
    merged: dict[str, dict[str, Any]] = {}
    declared_count = 0
    for relative in SOURCE_FILES:
        text = overrides.get(relative, (root / relative).read_text(encoding="utf-8"))
        raw = _load_contract(relative, text)
        declared_count += len(raw)
        for row in parse_source(relative, text):
            edge = row["edge_id"]
            if edge in merged:
                fail(f"duplicate source edge: {edge}")
            merged[edge] = row
    if declared_count != 40 or len(merged) != 40:
        fail(f"source contract count: expected 40, got {declared_count} declared/{len(merged)} unique")
    return [merged[edge] for edge in sorted(merged)]


def emitted_fixture(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {"schema_version": 1, "contracts": rows, "pending_edges": []}


def _typed_fixture(rows: list[dict[str, Any]], fixture_path: Path) -> list[dict[str, Any]]:
    try:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    except Exception as error:
        fail(f"invalid fixture: {error}")
    if not isinstance(fixture, dict) or fixture.get("schema_version") != 1 or fixture.get("pending_edges") != []:
        fail("invalid fixture envelope")
    contracts = fixture.get("contracts")
    if not isinstance(contracts, list) or len(contracts) != 40:
        fail("invalid fixture contracts")
    source_rows: list[dict[str, Any]] = []
    for item in contracts:
        if not isinstance(item, dict) or not TYPE_MAP_KEYS <= set(item):
            fail("fixture contract missing input type maps")
        base = {key: value for key, value in item.items() if key not in TYPE_MAP_KEYS}
        required_types = item["required_input_types"]
        optional_types = item["optional_input_types"]
        if not isinstance(required_types, dict) or set(required_types) != set(base.get("required_inputs", [])):
            fail(f"fixture required input types mismatch: {base.get('edge_id')}")
        if not isinstance(optional_types, dict) or set(optional_types) != set(base.get("optional_inputs", [])):
            fail(f"fixture optional input types mismatch: {base.get('edge_id')}")
        if any(value not in INPUT_TYPES for value in (*required_types.values(), *optional_types.values())):
            fail(f"fixture unsupported input type: {base.get('edge_id')}")
        source_rows.append(base)
    if emitted_fixture(source_rows) != emitted_fixture(rows):
        fail("fixture differs from source-derived contracts")
    return contracts


def validate(root: Path, tree_path: Path, fixture_path: Path, overrides: dict[str, str] | None = None) -> list[dict[str, Any]]:
    rows = collect_sources(root, overrides)
    typed_rows = _typed_fixture(rows, fixture_path)
    try:
        tree = json.loads(tree_path.read_text(encoding="utf-8"))
    except Exception as error:
        fail(f"invalid run-tree manifest: {error}")
    providers = {edge: row for edge, row in tree.get("edges", {}).items() if row.get("kind") == "provider" and isinstance(row.get("role"), str)}
    source_edges = {row["edge_id"] for row in rows}
    if source_edges != set(providers):
        fail(f"source/manifest edge mismatch missing={sorted(set(providers)-source_edges)} extra={sorted(source_edges-set(providers))}")
    typed_by_edge = {item["edge_id"]: item for item in typed_rows}
    for item in rows:
        edge = item["edge_id"]
        manifest = providers[edge]
        manifest_contract = {
            "edge_id": edge,
            "source": manifest.get("source"),
            "required_inputs": sorted(manifest.get("required_inputs", {})),
            "optional_inputs": sorted(manifest.get("optional_inputs", {})),
            "allowed_workflows": manifest.get("allowed_workflows"),
            "risk_scope": manifest.get("risk_scope"),
            "risk_argument": _risk_argument(manifest.get("risk_scope")),
        }
        if item != manifest_contract:
            fail(f"source/manifest contract mismatch: {edge}")
        typed = typed_by_edge[edge]
        if typed["required_input_types"] != manifest.get("required_inputs") or typed["optional_input_types"] != manifest.get("optional_inputs"):
            fail(f"manifest input type mismatch: {edge}")
        has_retry = FORMAT_INPUTS <= set(item["optional_inputs"])
        retry = manifest.get("retry")
        if has_retry != (isinstance(retry, dict) and retry.get("format") == 1):
            fail(f"source/manifest format retry mismatch: {edge}")
        if has_retry and (manifest["optional_inputs"].get("format_retry") != "boolean" or manifest["optional_inputs"].get("format_example_path") != "path"):
            fail(f"source/manifest format retry schema mismatch: {edge}")
    return typed_rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "emit"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--tree", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    args = parser.parse_args()
    if args.action == "emit":
        rows = collect_sources(args.root)
        print(json.dumps(emitted_fixture(_typed_fixture(rows, args.fixture)), indent=2))
        return 0
    rows = validate(args.root, args.tree, args.fixture)
    print(f"run-tree-callsite-contract: {len(rows)} closed, 0 pending")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractFailure as error:
        print(f"run-tree-callsite-contract: {error}", file=sys.stderr)
        raise SystemExit(2)
