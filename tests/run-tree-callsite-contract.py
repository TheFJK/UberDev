#!/usr/bin/env python3
"""Verify the durable source-owned provider callsite contract."""

from __future__ import annotations

import argparse
import json
import re
import shlex
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


def _executable_bash(text: str) -> str:
    return "\n".join(body for _info, body in BASH_FENCE.findall(text))


def _prefix_expects_command(prefix: str) -> bool:
    try:
        lexer = shlex.shlex(prefix, posix=True, punctuation_chars=";&|(){}<>")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        tokens = list(lexer)
    except ValueError:
        return False
    at_start = True
    command_wrapper = False
    declaration = False
    assignment = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\+)?=.*", re.DOTALL)
    for token in tokens:
        if token and all(char in ";&|(){}<>" for char in token):
            if token.startswith(("<", ">")):
                at_start = False
                command_wrapper = False
            elif any(char in token for char in ";&|") or token in {"(", ")", "{"}:
                at_start = True
                command_wrapper = False
                declaration = False
            continue
        if declaration:
            at_start = False
            declaration = False
            continue
        if not at_start:
            continue
        if assignment.fullmatch(token):
            continue
        if token == "function":
            declaration = True
            continue
        if command_wrapper:
            if token == "--" or token == "-p":
                continue
            if token in {"-v", "-V"}:
                at_start = False
                command_wrapper = False
                continue
            at_start = False
            command_wrapper = False
            continue
        if token == "command":
            command_wrapper = True
            continue
        if token in {"!", "if", "then", "elif", "else", "while", "until", "do"}:
            continue
        if token in {"for", "select", "case"}:
            at_start = False
            continue
        at_start = False
    return at_start and not declaration


def _token_is_executable(line: str, offset: int, token_end: int, *, reject_declaration: bool = True) -> bool:
    """Recognize a command-position token without parsing shell grammar."""
    single = False
    double = False
    escaped = False
    substitutions: list[int] = []
    for index, char in enumerate(line[:offset]):
        if escaped:
            escaped = False
            continue
        if char == "\\" and not single:
            escaped = True
            continue
        if char == "'" and not double:
            single = not single
            continue
        if char == '"' and not single:
            double = not double
            continue
        if single:
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace() or line[index - 1] in ";|&()"):
            return False
        if char == "$" and index + 1 < offset and line[index + 1] == "(":
            substitutions.append(index + 2)
            continue
        if char == ")" and substitutions:
            substitutions.pop()
    if single:
        return False
    if double and not substitutions:
        return False
    if reject_declaration and re.match(r"[ \t]*\([ \t]*\)[ \t]*(?:\{|\()", line[token_end:]):
        return False
    prefix = line[substitutions[-1] if substitutions else 0 : offset].rstrip()
    return _prefix_expects_command(prefix)


def _heredoc_declarations(line: str) -> list[tuple[str, bool]]:
    """Return bounded heredoc delimiter/strip-tab declarations on one code line."""
    declarations: list[tuple[str, bool]] = []
    index = 0
    single = False
    double = False
    escaped = False
    while index < len(line):
        char = line[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\" and not single:
            escaped = True
            index += 1
            continue
        if char == "'" and not double:
            single = not single
            index += 1
            continue
        if char == '"' and not single:
            double = not double
            index += 1
            continue
        if single or double:
            index += 1
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace() or line[index - 1] in ";|&()"):
            break
        if line.startswith("<<<", index):
            index += 3
            continue
        if not line.startswith("<<", index):
            index += 1
            continue
        cursor = index + 2
        strip_tabs = cursor < len(line) and line[cursor] == "-"
        if strip_tabs:
            cursor += 1
        while cursor < len(line) and line[cursor] in " \t":
            cursor += 1
        if cursor >= len(line):
            break
        if line[cursor] in "'\"":
            quote = line[cursor]
            end = line.find(quote, cursor + 1)
            if end < 0:
                break
            delimiter = line[cursor + 1 : end]
            cursor = end + 1
        else:
            if line[cursor] == "\\":
                cursor += 1
            end = cursor
            while end < len(line) and not line[end].isspace() and line[end] not in ";|&()<>":
                end += 1
            delimiter = line[cursor:end]
            cursor = end
        if delimiter:
            declarations.append((delimiter, strip_tabs))
        index = max(cursor, index + 2)
    return declarations


def _executable_lines(text: str):
    pending: list[tuple[str, bool]] = []
    for line in text.splitlines():
        if pending:
            delimiter, strip_tabs = pending[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                pending.pop(0)
            continue
        yield line
        pending.extend(_heredoc_declarations(line))


def _has_executable_helper(text: str, helper: str) -> bool:
    token = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(helper)}(?![A-Za-z0-9_])")
    for line in _executable_lines(text):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for match in token.finditer(line):
            if _token_is_executable(line, match.start(), match.end()):
                return True
    return False


def _command(text: str, helper: str, argument: str) -> bool:
    pattern = re.compile(
        rf"(?<![A-Za-z0-9_]){re.escape(helper)}[ \t]+{re.escape(argument)}(?:[ \t\\]|$)"
    )
    for line in _executable_lines(text):
        if line.lstrip().startswith("#"):
            continue
        for match in pattern.finditer(line):
            helper_end = match.start() + len(helper)
            if _token_is_executable(line, match.start(), helper_end):
                return True
    return False


def _function_body(text: str, name: str) -> str:
    match = re.search(rf"^(?P<indent>[ \t]*){re.escape(name)}\(\)[ \t]*\{{[^\n]*\n", text, re.MULTILINE)
    if not match:
        fail(f"missing executable function: {name}")
    peer = re.search(
        rf"^{re.escape(match.group('indent'))}[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{{",
        text[match.end() :],
        re.MULTILINE,
    )
    end = match.end() + peer.start() if peer else len(text)
    return text[match.end() : end]


def _brace_delta(line: str) -> int:
    try:
        lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|(){}<>")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        tokens = list(lexer)
    except ValueError:
        return 0
    return sum(token.count("{") - token.count("}") for token in tokens if token and all(char in ";&|(){}<>" for char in token))


def _without_nested_functions(text: str) -> str:
    declaration = re.compile(
        r"(?<![A-Za-z0-9_])(?:"
        r"(?P<keyword>function)[ \t]+(?P<keyword_name>[A-Za-z_][A-Za-z0-9_]*)"
        r"(?:[ \t]*\([ \t]*\))?"
        r"|(?P<short_name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*\([ \t]*\)"
        r")[ \t]*\{"
    )
    kept: list[str] = []
    depth = 0
    for line in _executable_lines(text):
        if depth:
            depth += _brace_delta(line)
            continue
        if _heredoc_declarations(line):
            # _executable_lines already removed this declaration's body and
            # terminator; omit the opener so downstream scans cannot reopen it.
            continue
        nested = None
        for candidate in declaration.finditer(line):
            command_group = "keyword" if candidate.group("keyword") else "short_name"
            if _token_is_executable(
                line,
                candidate.start(command_group),
                candidate.end(command_group),
                reject_declaration=False,
            ):
                nested = candidate
                break
        if nested is None:
            kept.append(line)
            continue
        depth = _brace_delta(line[nested.start() :])
    return "\n".join(kept)


def _require_dispatch_chain(relative: str, bash: str) -> None:
    if "child-dispatch.sh" not in bash:
        fail(f"{relative}: missing production child-dispatch source")
    if relative.endswith("brainstorm/SKILL.md"):
        prepare_name, launch_name = "uberdev_brainstorm_dispatch", "uberdev_brainstorm_launch_batch"
    elif relative.endswith("orchestrator/SKILL.md"):
        prepare_name, launch_name = "uberdev_design_dispatch", "uberdev_design_launch_batch"
    elif relative.endswith("subagent-driven-dev/SKILL.md"):
        prepare_name, launch_name = "sdd_dispatch_prepared", "sdd_launch_prepared_batch"
    elif relative.endswith("post-impl-review/SKILL.md"):
        prepare_name = launch_name = "post_review_fanout"
    else:
        prepare_name = launch_name = "review_child_fanout"
    prepare = _without_nested_functions(_function_body(bash, prepare_name))
    launch = _without_nested_functions(_function_body(bash, launch_name))
    if not _has_executable_helper(prepare, "uberdev_create_child_handoff"):
        fail(f"{relative}: routed chain missing uberdev_create_child_handoff")
    if not _has_executable_helper(launch, "uberdev_dispatch_child"):
        fail(f"{relative}: routed chain missing uberdev_dispatch_child")


def _literal_dispatch(relative: str, bash: str, edge: str) -> bool:
    if relative.endswith("brainstorm/SKILL.md"):
        helpers = ("uberdev_brainstorm_dispatch",)
    elif relative.endswith("orchestrator/SKILL.md"):
        helpers = ("uberdev_design_dispatch",)
    else:
        helpers = ("review_child_single", "review_child_record")
    return any(_command(bash, helper, edge) for helper in helpers)


def _validate_sdd(relative: str, bash: str, declared: set[str]) -> set[str]:
    switch = re.search(r'sdd_inputs_for_task\(\).*?case "\$edge_id" in(.*?)^[ \t]*esac', bash, re.MULTILINE | re.DOTALL)
    if not switch:
        fail(f"{relative}: missing executable SDD input switch")
    owned = set(re.findall(r"^[ \t]*(sdd\.[a-z0-9_.]+)\)", switch.group(1), re.MULTILINE))
    if owned != declared:
        fail(f"{relative}: dynamic edge mismatch declared={sorted(declared)} executable={sorted(owned)}")
    for edge in owned:
        if not _command(switch.group(1), "uberdev_child_inputs_build", edge):
            fail(f"{edge}: builder edge mismatch")
    if not _command(bash, "uberdev_child_inputs_validate", '"$edge_id"'):
        fail(f"{relative}: missing production input validation")
    if not _command(bash, "sdd_dispatch_prepared", '"$edge_id"'):
        fail(f"{relative}: missing executable SDD dispatch")
    return owned


def _validate_post_review(relative: str, bash: str, declared: set[str]) -> set[str]:
    array = re.search(r"REVIEW_EDGES=\((.*?)\)", bash, re.DOTALL)
    if not array:
        fail(f"{relative}: missing dynamic review ownership")
    owned = set(EDGE.findall(array.group(1)))
    if owned != declared:
        fail(f"{relative}: dynamic edge mismatch declared={sorted(declared)} executable={sorted(owned)}")
    if not _command(bash, "uberdev_child_inputs_build", '"$EDGE_ID"'):
        fail(f"{relative}: missing dynamic builder call")
    if not _command(bash, "post_review_record", '"$EDGE_ID"'):
        fail(f"{relative}: missing executable review record")
    record = _function_body(bash, "post_review_record")
    if not _command(record, "uberdev_child_inputs_validate", '"$edge"'):
        fail(f"{relative}: missing production input validation")
    if not _command(bash, "uberdev_child_inputs_format_retry", '"$FAILED_REVIEW_EDGE"') or not _command(
        bash, "post_review_record", '"$FAILED_REVIEW_EDGE"'
    ):
        fail(f"{relative}: retry helper edge mismatch")
    return owned


def _validate_simplify(relative: str, bash: str, declared: set[str]) -> set[str]:
    simplify = {edge for edge in declared if edge.startswith("review_pr.simplify.")}
    loop = re.search(r"for LENS in ([^;\n]+); do\n(.*?)^[ \t]*done", bash, re.MULTILINE | re.DOTALL)
    if not loop or 'EDGE_ID="review_pr.simplify.$LENS"' not in loop.group(2):
        fail(f"{relative}: missing dynamic simplify loop")
    owned = {f"review_pr.simplify.{lens}" for lens in loop.group(1).split()}
    markers = set(re.findall(r"^[ \t]*# routed-provider-edge: (review_pr\.simplify\.[a-z0-9_]+)[ \t]*$", bash, re.MULTILINE))
    if owned != simplify:
        fail(f"{relative}: dynamic edge mismatch declared={sorted(simplify)} executable={sorted(owned)}")
    if markers != owned:
        fail(f"{relative}: dynamic marker mismatch expected={sorted(owned)} actual={sorted(markers)}")
    if not _command(loop.group(2), "uberdev_child_inputs_build", '"$EDGE_ID"'):
        fail(f"{relative}: missing dynamic builder call")
    if not _command(loop.group(2), "review_child_record", '"$EDGE_ID"'):
        fail(f"{relative}: missing executable simplify record")
    record = _function_body(bash, "review_child_record")
    if not _command(record, "uberdev_child_inputs_validate", '"$edge"'):
        fail(f"{relative}: missing production input validation")
    return owned


def _validate_retry_edges(relative: str, text: str, bash: str, expected: set[str]) -> None:
    literal: set[str] = set()
    for info, body in BASH_FENCE.findall(text):
        edge_match = re.search(r"(?:^|\s)edge=([a-z][a-z0-9_.-]+)(?:\s|$)", info)
        if "retry=format" not in info or not edge_match:
            continue
        edge = edge_match.group(1)
        if not _command(body, "uberdev_child_inputs_format_retry", edge):
            fail(f"{edge}: retry helper edge mismatch")
        if not _literal_dispatch(relative, body, edge):
            fail(f"{edge}: retry dispatch edge mismatch")
        literal.add(edge)
    if not literal <= expected:
        fail(f"{relative}: retry edge mismatch extra={sorted(literal - expected)}")
    dynamic = expected - literal
    if not dynamic:
        return
    if relative.endswith("brainstorm/SKILL.md") or relative.endswith("orchestrator/SKILL.md"):
        variable = '"$failed_edge"'
        dispatch = "uberdev_brainstorm_dispatch" if relative.endswith("brainstorm/SKILL.md") else "uberdev_design_dispatch"
        if not _command(bash, "uberdev_child_inputs_format_retry", variable) or not _command(bash, dispatch, variable):
            fail(f"{relative}: missing dynamic retry dispatch")
    elif relative.endswith("post-impl-review/SKILL.md"):
        # The owned enumeration and shared helper/record identity were checked together above.
        return
    else:
        fail(f"{relative}: retry edge mismatch missing={sorted(dynamic)}")


def _validate_source_reachability(relative: str, text: str, declared: set[str], retry_edges: set[str]) -> None:
    bash = _executable_bash(text)
    _require_dispatch_chain(relative, bash)
    dynamic: set[str] = set()
    if relative.endswith("subagent-driven-dev/SKILL.md"):
        dynamic = _validate_sdd(relative, bash, declared)
    elif relative.endswith("post-impl-review/SKILL.md"):
        dynamic = _validate_post_review(relative, bash, declared)
    elif relative.endswith("commands/review-pr.md"):
        dynamic = _validate_simplify(relative, bash, declared)
    for edge in declared - dynamic:
        if not _command(bash, "uberdev_child_inputs_build", edge):
            fail(f"{edge}: builder edge mismatch")
        if not _literal_dispatch(relative, bash, edge):
            fail(f"{edge}: executable edge mismatch")
    _validate_retry_edges(relative, text, bash, retry_edges)


def parse_source(relative: str, text: str) -> list[dict[str, Any]]:
    raw_rows = _load_contract(relative, text)
    rows: list[dict[str, Any]] = []
    retry_edges: set[str] = set()
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
        if FORMAT_INPUTS <= set(optional):
            retry_edges.add(edge)
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
    _validate_source_reachability(relative, text, set(raw_rows), retry_edges)
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


def _validate_runtime_helpers(root: Path) -> None:
    runtime = (root / "plugins/uberdev/lib/child-dispatch.sh").read_text(encoding="utf-8")
    for helper, action in (
        ("uberdev_child_inputs_build", "build"),
        ("uberdev_child_inputs_validate", "validate"),
        ("uberdev_child_inputs_format_retry", "format-retry"),
    ):
        body = _function_body(runtime, helper)
        if not _command(body, "_uberdev_child_inputs_run", action):
            fail(f"production helper is not reachable: {helper}")


def validate(root: Path, tree_path: Path, fixture_path: Path, overrides: dict[str, str] | None = None) -> list[dict[str, Any]]:
    _validate_runtime_helpers(root)
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
