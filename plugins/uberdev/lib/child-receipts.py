#!/usr/bin/env python3
"""Test-only, payload-free execution receipts for routed child boundaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import stat
import sys
from dataclasses import dataclass
from typing import Any, NoReturn


MAX_INPUT_BYTES = 1_048_576
MAX_HANDOFF_BYTES = 65_536
EDGE_PATTERN = re.compile(
    r"[a-z][a-z0-9_-]{0,31}(?:\.[a-z][a-z0-9_-]{0,31}){0,3}"
)
INSTANCE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
SOURCE_PATTERN = re.compile(
    r"plugins/uberdev/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+"
)
EVENTS = {"build", "handoff", "dispatch"}


class ReceiptFailure(Exception):
    """A closed receipt-contract violation safe to report to shell callers."""


@dataclass(frozen=True)
class ReceiptConfig:
    source: str
    path: str


def fail(message: str) -> NoReturn:
    raise ReceiptFailure(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate inputs key: {key}")
        value[key] = item
    return value


def reject_constant(_value: str) -> NoReturn:
    fail("invalid inputs JSON")


def receipt_config() -> ReceiptConfig | None:
    """Return active receipt configuration without changing normal execution.

    ``UBERDEV_CHILD_TEST_MODE`` predates receipts and also gates manifest
    fixtures. Receipt collection therefore becomes active only when at least
    one receipt-specific variable is present; once requested, both are
    mandatory and every validation error fails the boundary closed.
    """

    if os.environ.get("UBERDEV_CHILD_TEST_MODE") != "1":
        return None
    source = os.environ.get("UBERDEV_CHILD_TEST_SOURCE")
    path = os.environ.get("UBERDEV_CHILD_TEST_RECEIPT_FILE")
    if source is None and path is None:
        return None
    if not source:
        fail("missing UBERDEV_CHILD_TEST_SOURCE")
    if not path:
        fail("missing UBERDEV_CHILD_TEST_RECEIPT_FILE")
    if (
        len(source) > 512
        or not SOURCE_PATTERN.fullmatch(source)
        or posixpath.normpath(source) != source
        or "\\" in source
    ):
        fail("invalid test source")
    return ReceiptConfig(source=source, path=path)


def parse_inputs(raw: str) -> dict[str, Any]:
    if len(raw.encode("utf-8", errors="surrogatepass")) > MAX_INPUT_BYTES:
        fail("invalid inputs JSON")
    try:
        value = json.loads(
            raw,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except ReceiptFailure:
        raise
    except (TypeError, ValueError, UnicodeError, RecursionError):
        fail("invalid inputs JSON")
    if not isinstance(value, dict):
        fail("inputs must be a JSON object")
    return value


def inputs_sha256(inputs: dict[str, Any]) -> str:
    try:
        canonical = json.dumps(
            inputs,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError, RecursionError):
        fail("invalid inputs JSON")
    return hashlib.sha256(canonical).hexdigest()


def validate_identity(event: str, edge_id: str, instance_id: str | None) -> None:
    if event not in EVENTS:
        fail("invalid receipt event")
    if not EDGE_PATTERN.fullmatch(edge_id):
        fail("invalid edge_id")
    if event == "build":
        if instance_id is not None:
            fail("build event must not include instance_id")
        return
    if instance_id is None:
        fail(f"{event} event requires instance_id")
    if not INSTANCE_PATTERN.fullmatch(instance_id):
        fail("invalid instance_id")


def build_record(
    config: ReceiptConfig,
    event: str,
    edge_id: str,
    instance_id: str | None,
    inputs: dict[str, Any],
) -> bytes:
    validate_identity(event, edge_id, instance_id)
    value: dict[str, Any] = {
        "schema_version": 1,
        "event": event,
        "source": config.source,
        "edge_id": edge_id,
        "inputs_sha256": inputs_sha256(inputs),
    }
    if instance_id is not None:
        value["instance_id"] = instance_id
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        + "\n"
    ).encode("utf-8")


def private_directory_fd(path: str) -> int:
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        fail("unsafe receipt file")
    parent = os.path.dirname(path)
    if not parent or not os.path.basename(path):
        fail("unsafe receipt file")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if not nofollow or not directory:
        fail("unsafe receipt directory")
    try:
        before = os.lstat(parent)
        fd = os.open(
            parent,
            os.O_RDONLY | directory | nofollow | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        fail("unsafe receipt directory")
    try:
        opened = os.fstat(fd)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or before.st_dev != opened.st_dev
            or before.st_ino != opened.st_ino
            or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) & 0o077
        ):
            fail("unsafe receipt directory")
    except BaseException:
        os.close(fd)
        raise
    return fd


def append_record(path: str, record: bytes) -> None:
    directory_fd = private_directory_fd(path)
    file_fd: int | None = None
    try:
        name = os.path.basename(path)
        try:
            before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            fail("unsafe receipt file")
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        try:
            file_fd = os.open(
                name,
                os.O_WRONLY
                | os.O_APPEND
                | nofollow
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=directory_fd,
            )
        except OSError:
            fail("unsafe receipt file")
        opened = os.fstat(file_fd)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or before.st_dev != opened.st_dev
            or before.st_ino != opened.st_ino
            or opened.st_uid != os.geteuid()
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o077
        ):
            fail("unsafe receipt file")
        written = os.write(file_fd, record)
        if written != len(record):
            fail("incomplete receipt append")
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(directory_fd)


def safe_handoff(path: str) -> dict[str, Any]:
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        fail("unsafe handoff file")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        fail("unsafe handoff file")
    try:
        before = os.lstat(path)
        fd = os.open(path, os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0))
    except OSError:
        fail("unsafe handoff file")
    try:
        opened = os.fstat(fd)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or before.st_dev != opened.st_dev
            or before.st_ino != opened.st_ino
            or opened.st_uid != os.geteuid()
            or opened.st_nlink != 1
            or opened.st_size > MAX_HANDOFF_BYTES
        ):
            fail("unsafe handoff file")
        raw = os.read(fd, MAX_HANDOFF_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > MAX_HANDOFF_BYTES:
        fail("unsafe handoff file")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except ReceiptFailure:
        fail("invalid handoff JSON")
    except (TypeError, ValueError, UnicodeError, RecursionError):
        fail("invalid handoff JSON")
    if not isinstance(value, dict):
        fail("invalid handoff JSON")
    return value


def append_from_inputs(args: argparse.Namespace, config: ReceiptConfig) -> None:
    inputs = parse_inputs(args.inputs_json)
    record = build_record(
        config,
        args.event,
        args.edge_id,
        args.instance_id,
        inputs,
    )
    append_record(config.path, record)


def append_from_handoff(args: argparse.Namespace, config: ReceiptConfig) -> None:
    if args.event not in {"handoff", "dispatch"}:
        fail("invalid receipt event")
    value = safe_handoff(args.handoff_file)
    if value.get("edge_id") != args.edge_id:
        fail("handoff edge mismatch")
    instance_id = value.get("instance_id")
    inputs = value.get("inputs")
    if not isinstance(instance_id, str) or not isinstance(inputs, dict):
        fail("invalid handoff JSON")
    record = build_record(config, args.event, args.edge_id, instance_id, inputs)
    append_record(config.path, record)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    append = commands.add_parser("append")
    append.add_argument("--event", required=True)
    append.add_argument("--edge-id", required=True)
    append.add_argument("--instance-id")
    append.add_argument("--inputs-json", required=True)

    handoff = commands.add_parser("append-handoff")
    handoff.add_argument("--event", required=True)
    handoff.add_argument("--edge-id", required=True)
    handoff.add_argument("--handoff-file", required=True)
    return root


def run(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    config = receipt_config()
    if config is None:
        return 0
    if args.command == "append":
        append_from_inputs(args, config)
    elif args.command == "append-handoff":
        append_from_handoff(args, config)
    else:  # argparse keeps this unreachable; retain a closed internal boundary.
        fail("invalid receipt command")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except ReceiptFailure as error:
        print(f"uberdev child receipts: {error}", file=sys.stderr)
        return 2
    except (OSError, UnicodeError, RecursionError) as error:
        print(f"uberdev child receipts: receipt append failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
