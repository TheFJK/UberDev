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
CLOSED_ERRORS = frozenset(
    {
        "build event must not include instance_id",
        "dispatch event requires instance_id",
        "duplicate inputs key",
        "handoff edge mismatch",
        "handoff event requires instance_id",
        "incomplete receipt append",
        "inputs must be a JSON object",
        "invalid edge_id",
        "invalid handoff JSON",
        "invalid inputs JSON",
        "invalid instance_id",
        "invalid receipt arguments",
        "invalid receipt command",
        "invalid receipt event",
        "invalid test source",
        "missing UBERDEV_CHILD_TEST_RECEIPT_FILE",
        "missing UBERDEV_CHILD_TEST_SOURCE",
        "receipt operation failed",
        "unsafe handoff directory",
        "unsafe handoff file",
        "unsafe receipt directory",
        "unsafe receipt file",
    }
)


class ReceiptFailure(Exception):
    """A closed receipt-contract violation safe to report to shell callers."""


@dataclass(frozen=True)
class ReceiptConfig:
    source: str
    path: str


def fail(message: str) -> NoReturn:
    closed = message if message in CLOSED_ERRORS else "receipt operation failed"
    raise ReceiptFailure(closed)


def current_uid() -> int | None:
    uid_fn = getattr(os, "geteuid", None)
    return uid_fn() if uid_fn is not None else None


def owned(entry: os.stat_result) -> bool:
    uid = current_uid()
    return uid is None or entry.st_uid == uid


def is_link_or_reparse(path: str, entry: os.stat_result) -> bool:
    attributes = getattr(entry, "st_file_attributes", 0)
    reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    return os.path.islink(path) or stat.S_ISLNK(entry.st_mode) or bool(attributes & reparse)


class ClosedArgumentParser(argparse.ArgumentParser):
    """Argparse boundary that never echoes hostile argument content."""

    def error(self, _message: str) -> NoReturn:
        fail("invalid receipt arguments")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail("duplicate inputs key")
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


def private_parent_fd(path: str, file_error: str, directory_error: str) -> int:
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        fail(file_error)
    parent = os.path.dirname(path)
    if not parent or not os.path.basename(path):
        fail(file_error)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if not nofollow or not directory:
        fail(directory_error)
    try:
        before = os.lstat(parent)
        fd = os.open(
            parent,
            os.O_RDONLY | directory | nofollow | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        fail(directory_error)
    try:
        opened = require_private_directory(fd, directory_error)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISDIR(before.st_mode)
            or before.st_dev != opened.st_dev
            or before.st_ino != opened.st_ino
        ):
            fail(directory_error)
    except BaseException:
        os.close(fd)
        raise
    return fd


def require_private_directory(fd: int, error: str) -> os.stat_result:
    opened = os.fstat(fd)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or not owned(opened)
        or stat.S_IMODE(opened.st_mode) & 0o077
    ):
        fail(error)
    return opened


def private_parent_path(path: str, file_error: str, directory_error: str) -> str:
    """Validate an absolute Windows parent without relying on dir_fd support."""

    if not os.path.isabs(path) or os.path.abspath(path) != path or os.path.normpath(path) != path:
        fail(file_error)
    parent = os.path.dirname(path)
    if not parent or not os.path.basename(path):
        fail(file_error)
    try:
        entry = os.lstat(parent)
    except OSError:
        fail(directory_error)
    if is_link_or_reparse(parent, entry) or not stat.S_ISDIR(entry.st_mode) or not owned(entry):
        fail(directory_error)
    return parent


def secure_windows_open(path: str, flags: int, file_error: str) -> tuple[int, os.stat_result]:
    """Open an existing Windows file and prove lstat/fstat identity."""

    descriptor: int | None = None
    try:
        before = os.lstat(path)
        if is_link_or_reparse(path, before) or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not owned(before):
            fail(file_error)
        descriptor = os.open(path, flags | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOINHERIT", 0))
        opened = os.fstat(descriptor)
    except ReceiptFailure:
        if descriptor is not None:
            os.close(descriptor)
        raise
    except OSError:
        if descriptor is not None:
            os.close(descriptor)
        fail(file_error)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or not owned(opened)
        or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
    ):
        os.close(descriptor)
        fail(file_error)
    return descriptor, opened


def append_record(path: str, record: bytes) -> None:
    if os.name == "nt":
        private_parent_path(path, "unsafe receipt file", "unsafe receipt directory")
        file_fd, opened = secure_windows_open(path, os.O_WRONLY | os.O_APPEND, "unsafe receipt file")
        try:
            current = os.lstat(path)
            if is_link_or_reparse(path, current) or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                fail("unsafe receipt file")
            written = os.write(file_fd, record)
            if written != len(record):
                fail("incomplete receipt append")
        finally:
            os.close(file_fd)
        return
    directory_fd = private_parent_fd(
        path,
        "unsafe receipt file",
        "unsafe receipt directory",
    )
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
            or not owned(opened)
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o077
        ):
            fail("unsafe receipt file")
        require_private_directory(directory_fd, "unsafe receipt directory")
        written = os.write(file_fd, record)
        if written != len(record):
            fail("incomplete receipt append")
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(directory_fd)


def safe_handoff(path: str) -> dict[str, Any]:
    if os.name == "nt":
        private_parent_path(path, "unsafe handoff file", "unsafe handoff directory")
        file_fd, opened = secure_windows_open(path, os.O_RDONLY, "unsafe handoff file")
        try:
            if opened.st_size > MAX_HANDOFF_BYTES:
                fail("unsafe handoff file")
            chunks: list[bytes] = []
            remaining = MAX_HANDOFF_BYTES + 1
            while remaining:
                chunk = os.read(file_fd, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            after = os.fstat(file_fd)
            current = os.lstat(path)
            if (
                is_link_or_reparse(path, current)
                or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                or (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            ):
                fail("unsafe handoff file")
        finally:
            os.close(file_fd)
        if len(raw) > MAX_HANDOFF_BYTES:
            fail("unsafe handoff file")
        return parse_handoff_json(raw)
    directory_fd = private_parent_fd(
        path,
        "unsafe handoff file",
        "unsafe handoff directory",
    )
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        os.close(directory_fd)
        fail("unsafe handoff file")
    file_fd: int | None = None
    try:
        name = os.path.basename(path)
        try:
            before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            file_fd = os.open(
                name,
                os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0),
                dir_fd=directory_fd,
            )
        except OSError:
            fail("unsafe handoff file")
        opened = os.fstat(file_fd)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or before.st_dev != opened.st_dev
            or before.st_ino != opened.st_ino
            or not owned(opened)
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o077
            or opened.st_size > MAX_HANDOFF_BYTES
        ):
            fail("unsafe handoff file")
        require_private_directory(directory_fd, "unsafe handoff directory")
        chunks: list[bytes] = []
        remaining = MAX_HANDOFF_BYTES + 1
        while remaining:
            chunk = os.read(file_fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        after = os.fstat(file_fd)
        if (
            (opened.st_dev, opened.st_ino, opened.st_size)
            != (after.st_dev, after.st_ino, after.st_size)
            or opened.st_mtime_ns != after.st_mtime_ns
            or opened.st_ctime_ns != after.st_ctime_ns
        ):
            fail("unsafe handoff file")
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(directory_fd)
    if len(raw) > MAX_HANDOFF_BYTES:
        fail("unsafe handoff file")
    return parse_handoff_json(raw)


def parse_handoff_json(raw: bytes) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object, parse_constant=reject_constant)
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
    root = ClosedArgumentParser(description=__doc__)
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
    except (OSError, UnicodeError, RecursionError):
        print("uberdev child receipts: receipt operation failed", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
