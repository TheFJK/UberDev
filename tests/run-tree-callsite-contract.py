#!/usr/bin/env python3
"""Extract and verify routed-provider callsite contracts from production docs."""

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
BASH_FENCE = re.compile(r"^[ \t]*```bash[^\n]*\n(.*?)^[ \t]*```[ \t]*$", re.MULTILINE | re.DOTALL)
ROW_KEYS = {"inputs", "optional_inputs", "allowed_workflows", "risk_scope", "risk_argument"}
WORKFLOWS = {"review-pr", "simplify", "solve", "turbo"}


class ContractFailure(Exception):
    pass


def fail(message: str) -> None:
    raise ContractFailure(message)


def _string_list(value: Any, label: str, *, allow_empty: bool = True) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        fail(f"{label}: expected string list")
    if not allow_empty and not value:
        fail(f"{label}: empty list")
    if len(value) != len(set(value)):
        fail(f"{label}: duplicate value")
    return value


def _risk_argument(scope: str) -> Any:
    return {"none": [], "subtask": "subtask", "run": None}[scope]


def parse_source(relative: str, text: str) -> tuple[dict[str, dict[str, Any]], set[str]]:
    matches = CONTRACT_BLOCK.findall(text)
    if len(matches) != 1:
        fail(f"{relative}: expected exactly one child-callsite-contracts-v1 block")
    try:
        raw_rows = json.loads(matches[0])
    except Exception as error:
        fail(f"{relative}: invalid contract JSON: {error}")
    if not isinstance(raw_rows, dict) or not raw_rows:
        fail(f"{relative}: contract block must be a non-empty object")
    bash = "\n".join(BASH_FENCE.findall(text))
    rows: dict[str, dict[str, Any]] = {}
    reachable: set[str] = set()
    for edge, raw in raw_rows.items():
        if not isinstance(edge, str) or not edge or not isinstance(raw, dict) or set(raw) != ROW_KEYS:
            fail(f"{relative}: invalid row schema for {edge!r}")
        required = _string_list(raw["inputs"], f"{edge}.inputs")
        optional = _string_list(raw["optional_inputs"], f"{edge}.optional_inputs")
        workflows = _string_list(raw["allowed_workflows"], f"{edge}.allowed_workflows", allow_empty=False)
        if set(required) & set(optional):
            fail(f"{edge}: required/optional inputs overlap")
        if workflows != sorted(workflows) or not set(workflows) <= WORKFLOWS:
            fail(f"{edge}: allowed workflows must be sorted and closed")
        scope = raw["risk_scope"]
        if scope not in {"none", "subtask", "run"} or raw["risk_argument"] != _risk_argument(scope):
            fail(f"{edge}: risk scope/argument mismatch")
        rows[edge] = {
            "edge_id": edge,
            "source": relative,
            "required_inputs": sorted(required),
            "optional_inputs": sorted(optional),
            "allowed_workflows": workflows,
            "risk_scope": scope,
            "risk_argument": raw["risk_argument"],
        }
        if edge in bash:
            reachable.add(edge)
    return rows, reachable


def collect_sources(root: Path, overrides: dict[str, str] | None = None) -> tuple[list[dict[str, Any]], set[str]]:
    overrides = overrides or {}
    merged: dict[str, dict[str, Any]] = {}
    reachable: set[str] = set()
    for relative in SOURCE_FILES:
        text = overrides.get(relative)
        if text is None:
            text = (root / relative).read_text(encoding="utf-8")
        rows, source_reachable = parse_source(relative, text)
        overlap = set(merged) & set(rows)
        if overlap:
            fail("duplicate source edge: " + ",".join(sorted(overlap)))
        merged.update(rows)
        reachable.update(source_reachable)
    if len(merged) != 40:
        fail(f"source contract count: expected 40, got {len(merged)}")
    missing = set(merged) - reachable
    if missing:
        fail("unreachable source edge: " + ",".join(sorted(missing)))
    return [merged[edge] for edge in sorted(merged)], reachable


def emitted_fixture(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {"schema_version": 1, "contracts": rows, "pending_edges": []}


def validate(
    root: Path,
    tree_path: Path,
    fixture_path: Path,
    overrides: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    rows, _reachable = collect_sources(root, overrides)
    expected = emitted_fixture(rows)
    try:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    except Exception as error:
        fail(f"invalid fixture: {error}")
    if fixture != expected:
        fail("fixture differs from source-derived contracts")
    try:
        tree = json.loads(tree_path.read_text(encoding="utf-8"))
    except Exception as error:
        fail(f"invalid run-tree manifest: {error}")
    providers = {
        edge: row
        for edge, row in tree.get("edges", {}).items()
        if row.get("kind") == "provider" and isinstance(row.get("role"), str)
    }
    source_edges = {row["edge_id"] for row in rows}
    if source_edges != set(providers):
        missing = sorted(set(providers) - source_edges)
        extra = sorted(source_edges - set(providers))
        fail(f"source/manifest edge mismatch missing={missing} extra={extra}")
    for item in rows:
        edge = item["edge_id"]
        manifest = providers[edge]
        expected_row = {
            "edge_id": edge,
            "source": manifest.get("source"),
            "required_inputs": sorted(manifest.get("required_inputs", {})),
            "optional_inputs": sorted(manifest.get("optional_inputs", {})),
            "allowed_workflows": manifest.get("allowed_workflows"),
            "risk_scope": manifest.get("risk_scope"),
            "risk_argument": _risk_argument(manifest.get("risk_scope")),
        }
        if item != expected_row:
            fail(f"source/manifest contract mismatch: {edge}")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "emit"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--tree", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    args = parser.parse_args()
    if args.action == "emit":
        rows, _reachable = collect_sources(args.root)
        print(json.dumps(emitted_fixture(rows), indent=2, sort_keys=False))
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
