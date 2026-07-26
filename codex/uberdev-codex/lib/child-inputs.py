#!/usr/bin/env python3
"""Manifest-derived construction and validation for routed child inputs."""

import argparse
import json
import posixpath
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


SUPPORTED_TYPES = {
    "integer",
    "boolean",
    "string",
    "path",
    "directory",
    "optional_string",
    "optional_path",
    "string_array",
    "path_array",
    "optional_path_array",
    "repo_path_array",
}

# Leave deterministic headroom for carrier, identity, routing, and risk fields
# inside child-dispatch.sh's 64-KiB immutable handoff ceiling.
MAX_INPUT_BYTES = 49_152


class InputFailure(Exception):
    """A closed input-contract violation safe to report to shell callers."""


def fail(message: str) -> NoReturn:
    raise InputFailure(message)


def reject_constant(value: str) -> NoReturn:
    fail(f"invalid JSON constant: {value}")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def parse_json(raw: str, label: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except InputFailure:
        raise
    except (TypeError, ValueError, RecursionError) as error:
        fail(f"invalid {label} JSON: {error}")


def load_manifest(path: str) -> dict[str, Any]:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read child manifest: {error}")
    manifest = parse_json(raw, "manifest")
    if not isinstance(manifest, dict) or not isinstance(manifest.get("edges"), dict):
        fail("invalid child manifest")
    return manifest


def edge_schema(manifest: dict[str, Any], edge_id: str) -> tuple[dict[str, str], dict[str, str], dict[str, Any]]:
    row = manifest["edges"].get(edge_id)
    if not isinstance(row, dict) or row.get("kind") != "provider":
        fail(f"undeclared provider edge: {edge_id}")
    required = row.get("required_inputs")
    optional = row.get("optional_inputs")
    if not isinstance(required, dict) or not isinstance(optional, dict):
        fail(f"invalid input schema for edge: {edge_id}")
    if set(required) & set(optional):
        fail(f"overlapping input schema for edge: {edge_id}")
    for key, kind in {**required, **optional}.items():
        if not isinstance(key, str) or not isinstance(kind, str) or kind not in SUPPORTED_TYPES:
            fail(f"unsupported input schema for edge: {edge_id}")
    return required, optional, row


def validate_value(key: str, value: Any, kind: str) -> None:
    if kind == "integer":
        if type(value) is not int:
            fail(f"input {key} must be an integer")
        return
    if kind == "boolean":
        if type(value) is not bool:
            fail(f"input {key} must be a boolean")
        return
    if kind in {"string", "path", "directory"}:
        if not isinstance(value, str) or not value:
            fail(f"input {key} must be a non-empty {kind}")
        return
    if kind in {"optional_string", "optional_path"}:
        if not isinstance(value, str):
            fail(f"input {key} must be a string")
        return
    if kind == "repo_path_array":
        if not isinstance(value, list) or not value:
            fail(f"input {key} must be a non-empty array of repository-relative paths")
        for item in value:
            if (
                not isinstance(item, str)
                or not item
                or len(item) > 4096
                or item.startswith("/")
                or "\\" in item
                or any(ord(char) < 32 or ord(char) == 127 for char in item)
            ):
                fail(f"input {key} contains an unsafe repository path")
            parts = item.split("/")
            if (
                any(part in {"", ".", ".."} for part in parts)
                or re.match(r"^[A-Za-z]:", item)
                or posixpath.normpath(item) != item
            ):
                fail(f"input {key} contains an unsafe repository path")
        return
    if kind in {"string_array", "path_array", "optional_path_array"}:
        if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
            fail(f"input {key} must be an array of non-empty strings")
        return
    fail(f"unsupported type for input {key}")


def validate_inputs(manifest: dict[str, Any], edge_id: str, inputs: Any) -> dict[str, Any]:
    required, optional, _ = edge_schema(manifest, edge_id)
    if not isinstance(inputs, dict):
        fail("child inputs must be a JSON object")
    keys = set(inputs)
    missing = set(required) - keys
    extra = keys - set(required) - set(optional)
    if missing:
        fail("missing required inputs: " + ",".join(sorted(missing)))
    if extra:
        fail("undeclared inputs: " + ",".join(sorted(extra)))
    schema = {**required, **optional}
    for key, value in inputs.items():
        validate_value(key, value, schema[key])
    if len(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode("utf-8")) > MAX_INPUT_BYTES:
        fail("child inputs exceed immutable handoff budget")
    return inputs


def compact(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def build_inputs(manifest: dict[str, Any], edge_id: str, values: list[str]) -> dict[str, Any]:
    if len(values) % 2:
        fail("input arguments must be KEY JSON_VALUE pairs")
    inputs: dict[str, Any] = {}
    for index in range(0, len(values), 2):
        key, raw = values[index : index + 2]
        if key in inputs:
            fail(f"duplicate input key: {key}")
        inputs[key] = parse_json(raw, f"value for {key}")
    return validate_inputs(manifest, edge_id, inputs)


def format_retry(manifest: dict[str, Any], edge_id: str, raw_inputs: str, example_path: str) -> dict[str, Any]:
    _, optional, row = edge_schema(manifest, edge_id)
    retry = row.get("retry")
    if not isinstance(retry, dict) or type(retry.get("format")) is not int or retry["format"] != 1:
        fail(f"edge does not declare one format retry: {edge_id}")
    if optional.get("format_retry") != "boolean" or optional.get("format_example_path") != "path":
        fail(f"edge has invalid format retry inputs: {edge_id}")
    inputs = parse_json(raw_inputs, "base inputs")
    if not isinstance(inputs, dict):
        fail("child inputs must be a JSON object")
    if "format_retry" in inputs or "format_example_path" in inputs:
        fail("base inputs already contain format retry keys")
    augmented = dict(inputs)
    augmented["format_retry"] = True
    augmented["format_example_path"] = example_path
    return validate_inputs(manifest, edge_id, augmented)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(add_help=False)
    value.add_argument("--manifest", required=True)
    commands = value.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", add_help=False)
    build.add_argument("edge_id")
    build.add_argument("values", nargs="*")
    validate = commands.add_parser("validate", add_help=False)
    validate.add_argument("edge_id")
    validate.add_argument("inputs_json")
    retry = commands.add_parser("format-retry", add_help=False)
    retry.add_argument("edge_id")
    retry.add_argument("inputs_json")
    retry.add_argument("format_example_path")
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        manifest = load_manifest(args.manifest)
        if args.command == "build":
            output = build_inputs(manifest, args.edge_id, args.values)
        elif args.command == "validate":
            output = validate_inputs(manifest, args.edge_id, parse_json(args.inputs_json, "inputs"))
        else:
            output = format_retry(manifest, args.edge_id, args.inputs_json, args.format_example_path)
    except InputFailure as error:
        print(f"uberdev child inputs: {error}", file=sys.stderr)
        return 2
    print(compact(output), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
