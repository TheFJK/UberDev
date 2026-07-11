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
BASH_FENCE = re.compile(r"^[ \t]*```bash([^\n]*)\n(.*?)^[ \t]*```[ \t]*$", re.MULTILINE | re.DOTALL)
EDGE_LITERAL = re.compile(r"(?<![a-z0-9_.])((?:brainstorm|orchestrator|sdd|review_pr)\.[a-z0-9_.]+)")
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


def _payload_keys(command: str) -> set[str]:
    """Extract keys from the actual Python/jq object constructor in a command."""
    python_object = re.search(r"json\.dumps\(\{(.*?)\},\s*separators=", command, re.DOTALL)
    if python_object:
        return set(re.findall(r"[\"']([a-z][a-z0-9_]*)[\"']\s*:", python_object.group(1)))
    if "jq -cn" in command:
        return set(re.findall(r"(?:\{|,)\s*([a-z][a-z0-9_]*)\s*:", command))
    return set()


def _literal_payloads(fences: list[tuple[str, str]]) -> dict[str, set[str]]:
    """Resolve literal edge dispatches to the payload variables they consume."""
    variables: dict[str, set[str]] = {}
    bodies = "\n".join(body for _info, body in fences)
    for line in bodies.splitlines():
        assignment = re.match(r"\s*([A-Z][A-Z0-9_]*)=", line)
        keys = _payload_keys(line)
        if assignment and keys:
            variables[assignment.group(1)] = keys

    payloads: dict[str, set[str]] = {}
    for line in bodies.splitlines():
        edges = EDGE_LITERAL.findall(line)
        referenced = {
            variable
            for variable in re.findall(r"\$\{?([A-Z][A-Z0-9_]*)", line)
            if variable in variables
        }
        if len(edges) == 1 and len(referenced) == 1:
            edge = edges[0]
            keys = variables[next(iter(referenced))]
            previous = payloads.get(edge)
            if previous is not None and previous != keys:
                fail(f"{edge}: conflicting executable payload constructors")
            payloads[edge] = keys
    return payloads


def _sdd_payloads(bash: str) -> dict[str, set[str]]:
    function = re.search(
        r"sdd_inputs_for_task\(\)\s*\{.*?case \"\$edge_id\" in(.*?)^\s*esac",
        bash,
        re.MULTILINE | re.DOTALL,
    )
    if not function:
        fail("subagent-driven-dev: missing executable payload switch")
    payloads: dict[str, set[str]] = {}
    branch = re.compile(
        r"^\s*(sdd\.[a-z0-9_.]+)\)\s*(.*?)(?=^\s*(?:sdd\.[a-z0-9_.]+\)|\*\)))",
        re.MULTILINE | re.DOTALL,
    )
    for edge, body in branch.findall(function.group(1)):
        keys = _payload_keys(body)
        if not keys:
            fail(f"{edge}: missing executable payload constructor")
        payloads[edge] = keys
    return payloads


def _post_review_payloads(bash: str, declared: set[str]) -> dict[str, set[str]]:
    array = re.search(r"REVIEW_EDGES=\((.*?)\)", bash, re.DOTALL)
    conditional = re.search(
        r'if \[ "\$EDGE_ID" = review_pr\.review\.general \]; then(.*?)^\s*else(.*?)^\s*fi',
        bash,
        re.MULTILINE | re.DOTALL,
    )
    if not array or not conditional:
        fail("post-impl-review: missing executable review enumeration/payload branch")
    enumerated = set(EDGE_LITERAL.findall(array.group(1)))
    if enumerated != declared:
        fail(f"post-impl-review: dynamic edge mismatch declared={sorted(declared)} executable={sorted(enumerated)}")
    general = _payload_keys(conditional.group(1))
    standard = _payload_keys(conditional.group(2))
    if not general or not standard:
        fail("post-impl-review: missing executable review payload constructor")
    return {edge: general if edge == "review_pr.review.general" else standard for edge in enumerated}


def _simplify_payloads(bash: str, declared: set[str]) -> dict[str, set[str]]:
    loops = re.finditer(r"for LENS in ([^;\n]+); do\n(.*?)^\s*done", bash, re.MULTILINE | re.DOTALL)
    selected: tuple[list[str], str] | None = None
    for loop in loops:
        body = loop.group(2)
        if 'EDGE_ID="review_pr.simplify.$LENS"' in body:
            lenses = loop.group(1).split()
            if not lenses or len(lenses) != len(set(lenses)) or any(not re.fullmatch(r"[a-z0-9_]+", lens) for lens in lenses):
                fail("review-pr: malformed dynamic simplify enumeration")
            selected = (lenses, body)
            break
    if selected is None:
        fail("review-pr: missing dynamic simplify loop")
    lenses, body = selected
    executable = {f"review_pr.simplify.{lens}" for lens in lenses}
    if executable != declared:
        fail(f"review-pr: dynamic edge mismatch declared={sorted(declared)} executable={sorted(executable)}")
    markers = set(re.findall(r"#\s*routed-provider-edge:\s*(review_pr\.simplify\.[a-z0-9_]+)", bash))
    invalid_markers = markers - executable
    if invalid_markers:
        fail(f"review-pr: dynamic marker mismatch: {sorted(invalid_markers)}")
    keys = _payload_keys(body)
    if not keys:
        fail("review-pr: missing dynamic simplify payload constructor")
    return {edge: keys for edge in executable}


def executable_payloads(relative: str, text: str, raw_rows: dict[str, Any]) -> dict[str, set[str]]:
    fences = BASH_FENCE.findall(text)
    bash = "\n".join(body for _info, body in fences)
    payloads = _literal_payloads(fences)
    declared = set(raw_rows)
    if relative.endswith("subagent-driven-dev/SKILL.md"):
        payloads.update(_sdd_payloads(bash))
    elif relative.endswith("post-impl-review/SKILL.md"):
        payloads.update(_post_review_payloads(bash, declared))
    elif relative.endswith("commands/review-pr.md"):
        simplify = {edge for edge in declared if edge.startswith("review_pr.simplify.")}
        payloads.update(_simplify_payloads(bash, simplify))
    if set(payloads) != declared:
        fail(
            f"{relative}: executable edge mismatch "
            f"missing={sorted(declared - set(payloads))} extra={sorted(set(payloads) - declared)}"
        )
    return payloads


def _load_contract_block(relative: str, text: str) -> dict[str, Any]:
    matches = CONTRACT_BLOCK.findall(text)
    if len(matches) != 1:
        fail(f"{relative}: expected exactly one child-callsite-contracts-v1 block")
    try:
        raw_rows = json.loads(matches[0])
    except Exception as error:
        fail(f"{relative}: invalid contract JSON: {error}")
    if not isinstance(raw_rows, dict) or not raw_rows:
        fail(f"{relative}: contract block must be a non-empty object")
    return raw_rows


def parse_source(relative: str, text: str) -> tuple[dict[str, dict[str, Any]], set[str]]:
    raw_rows = _load_contract_block(relative, text)
    payloads = executable_payloads(relative, text, raw_rows)
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
        actual = payloads[edge]
        allowed = set(required) | set(optional)
        if not set(required) <= actual or not actual <= allowed:
            fail(
                f"{edge}: executable payload mismatch "
                f"required={sorted(required)} optional={sorted(optional)} actual={sorted(actual)}"
            )
        reachable.add(edge)
    return rows, reachable


def collect_sources(root: Path, overrides: dict[str, str] | None = None) -> tuple[list[dict[str, Any]], set[str]]:
    overrides = overrides or {}
    source_texts: dict[str, str] = {}
    declared_count = 0
    for relative in SOURCE_FILES:
        text = overrides.get(relative)
        if text is None:
            text = (root / relative).read_text(encoding="utf-8")
        source_texts[relative] = text
        declared_count += len(_load_contract_block(relative, text))
    if declared_count != 40:
        fail(f"source contract count: expected 40, got {declared_count}")

    merged: dict[str, dict[str, Any]] = {}
    reachable: set[str] = set()
    for relative in SOURCE_FILES:
        rows, source_reachable = parse_source(relative, source_texts[relative])
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
