#!/usr/bin/env python3
"""Create, inspect, and permanently retire Codex worktree ownership receipts."""

from __future__ import annotations

import argparse
import errno
import hashlib
import importlib.util
import json
import os
import posixpath
import re
import secrets
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, NamedTuple, NoReturn


SCHEMA_VERSION = 1
MAX_RECEIPT_BYTES = 65536
PRIVATE_FILE_MODE = 0o600
_TOKEN_PATTERN = re.compile(r"[0-9a-f]{32}:[0-9a-f]{40}")
_HEAD_PATTERN = re.compile(r"[0-9a-f]{40}")
_STAGE_DOMAIN = b"uberdev.worktree-owner.stage-v1"
_STAGE_PREFIX = ".worktree-owner.stage-v1-"
_TOMBSTONE_DOMAIN = b"uberdev.worktree-owner.retired-v1"
_TOMBSTONE_PREFIX = ".worktree-owner.retired-v1-"
_REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
_CAPABILITY_ERRNOS = {
    getattr(errno, name)
    for name in ("ENOTSUP", "EOPNOTSUPP", "ENOSYS")
    if hasattr(errno, name)
}
_TRANSIENT_ERRNOS = {
    getattr(errno, name)
    for name in (
        "EAGAIN",
        "EBUSY",
        "EDQUOT",
        "EINTR",
        "EIO",
        "EMFILE",
        "ENFILE",
        "ENOMEM",
        "ENOSPC",
        "ESTALE",
        "ETIMEDOUT",
    )
    if hasattr(errno, name)
}
_TERMINAL_ERRNOS = {
    getattr(errno, name)
    for name in (
        "EACCES",
        "EEXIST",
        "EISDIR",
        "EINVAL",
        "ELOOP",
        "ENAMETOOLONG",
        "ENOENT",
        "ENOTDIR",
        "EPERM",
        "EROFS",
        "EXDEV",
    )
    if hasattr(errno, name)
}


class TerminalReceiptError(Exception):
    """The authority is malformed, ambiguous, or no longer safe to use."""


class TransientReceiptError(Exception):
    """An operating-system or Git operation may succeed on a later attempt."""


class PublishedTransientReceiptError(TransientReceiptError):
    """Publication succeeded but its durability confirmation did not."""

    def __init__(self, token: str) -> None:
        super().__init__()
        self.token = token


class CapabilityReceiptError(Exception):
    """The host cannot provide a mandatory filesystem safety primitive."""


class InternalReceiptError(Exception):
    """A dependency or programming defect prevents safe operation."""


class _Carrier(NamedTuple):
    raw: bytes
    digest: str
    identity: tuple[int, int, int, int, int, int]
    raw_state: tuple[int, int, int, int, int, int]
    descriptor: int | None


def _load_atomic_move_helpers():
    helper_path = Path(__file__).resolve().with_name("atomic_move.py")
    spec = importlib.util.spec_from_file_location(
        "uberdev_worktree_receipt_atomic_move", helper_path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("atomic move helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    helper = getattr(module, "atomic_rename_noreplace", None)
    support = getattr(module, "require_atomic_rename_noreplace_support", None)
    if not callable(helper) or not callable(support):
        raise RuntimeError("atomic move helper unavailable")
    return helper, support


def _unavailable_atomic_rename(
    _source: Any, _destination: Any, *, dir_fd: int | None = None
) -> NoReturn:
    del dir_fd
    raise OSError(getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), "unsupported")


def _unavailable_atomic_support() -> NoReturn:
    raise RuntimeError("atomic move helper unavailable")


try:
    atomic_rename_noreplace, require_atomic_rename_noreplace_support = (
        _load_atomic_move_helpers()
    )
except Exception:
    atomic_rename_noreplace = _unavailable_atomic_rename
    require_atomic_rename_noreplace_support = _unavailable_atomic_support
    _ATOMIC_MOVE_AVAILABLE = False
else:
    _ATOMIC_MOVE_AVAILABLE = True


def _terminal() -> NoReturn:
    raise TerminalReceiptError()


def _transient() -> NoReturn:
    raise TransientReceiptError()


def _capability() -> NoReturn:
    raise CapabilityReceiptError()


def _internal() -> NoReturn:
    raise InternalReceiptError()


def _raise_os_failure(exc: OSError) -> NoReturn:
    number = exc.errno
    if number in _CAPABILITY_ERRNOS:
        _capability()
    if number in _TRANSIENT_ERRNOS:
        _transient()
    if number in _TERMINAL_ERRNOS:
        _terminal()
    _internal()


def _native_windows() -> bool:
    return os.name == "nt" and sys.platform == "win32"


def _canonical_absolute_input(value: Any) -> str:
    if not isinstance(value, str) or not os.path.isabs(value):
        _terminal()
    if _native_windows():
        alternate_separator = os.path.altsep
        normalized = (
            value.replace(alternate_separator, os.path.sep)
            if alternate_separator is not None
            else value
        )
        canonical = os.path.abspath(value)
        if normalized != canonical:
            _terminal()
        return canonical
    if os.path.abspath(value) != value:
        _terminal()
    return value


def _canonical_windows_final_spelling(value: str) -> str:
    try:
        canonical = os.path.realpath(value)
    except OSError as exc:
        _raise_os_failure(exc)
    if canonical != value:
        _terminal()
    return canonical


def _canonical_windows_existing_directory(value: str) -> str:
    try:
        before = os.lstat(value)
    except OSError as exc:
        _raise_os_failure(exc)
    if _is_link_or_reparse(value, before) or not stat.S_ISDIR(before.st_mode):
        _terminal()
    canonical = _canonical_windows_final_spelling(value)
    try:
        after = os.lstat(canonical)
    except OSError as exc:
        _raise_os_failure(exc)
    if (
        _is_link_or_reparse(canonical, after)
        or not stat.S_ISDIR(after.st_mode)
        or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
    ):
        _terminal()
    return canonical


def _require_atomic_move() -> None:
    if not _ATOMIC_MOVE_AVAILABLE:
        _internal()
    try:
        require_atomic_rename_noreplace_support()
    except OSError as exc:
        _raise_os_failure(exc)


def _descriptor_link_count_valid(entry: os.stat_result, native_windows: bool) -> bool:
    return entry.st_nlink == 1 or (native_windows and entry.st_nlink == 0)


def _pathname_link_count_valid(entry: os.stat_result) -> bool:
    return entry.st_nlink == 1


def _owned(entry: os.stat_result) -> bool:
    uid_function = getattr(os, "geteuid", None)
    return uid_function is None or entry.st_uid == uid_function()


def _is_link_or_reparse(path: str, entry: os.stat_result) -> bool:
    return (
        os.path.islink(path)
        or stat.S_ISLNK(entry.st_mode)
        or bool(getattr(entry, "st_file_attributes", 0) & _REPARSE_POINT)
    )


def _identity(
    entry: os.stat_result, native_windows: bool
) -> tuple[int, int, int, int, int, int]:
    identity_time = getattr(entry, "st_birthtime_ns", None)
    if identity_time is None:
        birthtime = getattr(entry, "st_birthtime", None)
        identity_time = (
            int(birthtime * 1_000_000_000)
            if birthtime is not None
            else (entry.st_ctime_ns if native_windows else 0)
        )
    mode = entry.st_mode
    if native_windows:
        mode &= ~(stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return (
        entry.st_dev,
        entry.st_ino,
        entry.st_size,
        entry.st_mtime_ns,
        int(identity_time),
        mode,
    )


def _raw_descriptor_state(entry: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        entry.st_dev,
        entry.st_ino,
        entry.st_size,
        entry.st_mtime_ns,
        entry.st_ctime_ns,
        entry.st_mode,
    )


def _windows_rename_stable_identity(
    identity: tuple[int, int, int, int, int, int],
) -> tuple[int, int, int, int, int]:
    return identity[:4] + identity[5:]


def _windows_rename_carriers_match(before: _Carrier, after: _Carrier) -> bool:
    return (
        before.raw == after.raw
        and before.digest == after.digest
        and _windows_rename_stable_identity(before.identity)
        == _windows_rename_stable_identity(after.identity)
    )


def _canonical_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def _valid_token(token: str, start_head: str) -> bool:
    return (
        isinstance(token, str)
        and _TOKEN_PATTERN.fullmatch(token) is not None
        and _HEAD_PATTERN.fullmatch(start_head) is not None
        and token.rsplit(":", 1)[1] == start_head
    )


def _tombstone_name(token: str) -> str:
    digest = hashlib.sha256(
        _TOMBSTONE_DOMAIN + b"\0" + token.encode("ascii")
    ).hexdigest()
    return f"{_TOMBSTONE_PREFIX}{digest}.json"


def _tombstone_path(receipt: str, token: str) -> str:
    return os.path.join(os.path.dirname(receipt), _tombstone_name(token))


def _stage_name(token: str) -> str:
    digest = hashlib.sha256(_STAGE_DOMAIN + b"\0" + token.encode("ascii")).hexdigest()
    return f"{_STAGE_PREFIX}{digest}.json"


def _stage_path(receipt: str, token: str) -> str:
    return os.path.join(os.path.dirname(receipt), _stage_name(token))


def _expected_payload(
    repo: str,
    relative: str,
    branch: str,
    receipt: str,
    start_head: str,
    token: str,
) -> dict[str, Any]:
    del receipt
    worktree = os.path.abspath(os.path.join(repo, *relative.split("/")))
    return {
        "branch": branch,
        "branch_absent_at_receipt": True,
        "path_absent_at_receipt": True,
        "relative": relative,
        "repo": repo,
        "schema_version": SCHEMA_VERSION,
        "start_head": start_head,
        "token": token,
        "worktree": worktree,
    }


def _validated_context(
    repo: str,
    relative: str,
    branch: str,
    receipt: str,
    start_head: str,
    token: str,
) -> tuple[str, str, str, bytes]:
    canonical_repo_input = _canonical_absolute_input(repo)
    canonical_receipt = _canonical_absolute_input(receipt)
    if _native_windows():
        canonical_repo = _canonical_windows_existing_directory(canonical_repo_input)
        receipt_parent = os.path.dirname(canonical_receipt)
        canonical_receipt_parent = _canonical_windows_existing_directory(receipt_parent)
        final_receipt = os.path.join(
            canonical_receipt_parent, os.path.basename(canonical_receipt)
        )
        if final_receipt != canonical_receipt:
            _terminal()
        canonical_receipt = final_receipt
    else:
        canonical_repo = os.path.realpath(canonical_repo_input)
    if (
        os.path.normpath(canonical_receipt) != canonical_receipt
        or not os.path.basename(canonical_receipt)
        or not _valid_token(token, start_head)
    ):
        _terminal()
    try:
        repo_entry = os.lstat(canonical_repo)
    except OSError as exc:
        _raise_os_failure(exc)
    if _is_link_or_reparse(canonical_repo, repo_entry) or not stat.S_ISDIR(
        repo_entry.st_mode
    ):
        _terminal()
    normalized = posixpath.normpath(relative)
    basename = posixpath.basename(normalized)
    if (
        normalized != relative
        or posixpath.isabs(relative)
        or not normalized.startswith(".claude/worktrees/solve-issue-")
        or posixpath.dirname(normalized) != ".claude/worktrees"
        or branch != "worktree-" + basename
    ):
        _terminal()
    root = os.path.abspath(os.path.join(canonical_repo, ".claude", "worktrees"))
    target = os.path.abspath(os.path.join(canonical_repo, *relative.split("/")))
    try:
        contained = os.path.commonpath((root, target)) == root
    except ValueError:
        contained = False
    if not contained:
        _terminal()
    expected = _expected_payload(
        canonical_repo, normalized, branch, canonical_receipt, start_head, token
    )
    return (
        canonical_repo,
        canonical_receipt,
        _tombstone_path(canonical_receipt, token),
        _canonical_bytes(expected),
    )


def _read_descriptor(descriptor: int, expected_size: int) -> bytes:
    if expected_size < 0 or expected_size > MAX_RECEIPT_BYTES:
        _terminal()
    chunks: list[bytes] = []
    remaining = expected_size
    while remaining:
        try:
            chunk = os.read(descriptor, min(remaining, 65536))
        except OSError as exc:
            _raise_os_failure(exc)
        if not chunk:
            _terminal()
        chunks.append(chunk)
        remaining -= len(chunk)
    try:
        extra = os.read(descriptor, 1)
    except OSError as exc:
        _raise_os_failure(exc)
    if extra:
        _terminal()
    return b"".join(chunks)


def _validate_parent_entry(path: str, entry: os.stat_result, private: bool) -> None:
    if (
        _is_link_or_reparse(path, entry)
        or not stat.S_ISDIR(entry.st_mode)
        or not _owned(entry)
        or (private and stat.S_IMODE(entry.st_mode) & 0o077)
    ):
        _terminal()


def _close_after_error(descriptor: int) -> None:
    try:
        os.close(descriptor)
    except OSError:
        pass


def _open_posix_parent(path: str) -> tuple[int, str, str, tuple[int, int]]:
    parent = os.path.dirname(path)
    name = os.path.basename(path)
    if not parent or not name:
        _terminal()
    directory = getattr(os, "O_DIRECTORY", None)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if directory is None or nofollow is None:
        _capability()
    try:
        before = os.lstat(parent)
    except OSError as exc:
        _raise_os_failure(exc)
    _validate_parent_entry(parent, before, True)
    descriptor: int | None = None
    try:
        descriptor = os.open(
            parent,
            os.O_RDONLY | directory | nofollow | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        current = os.lstat(parent)
    except OSError as exc:
        if descriptor is not None:
            _close_after_error(descriptor)
        _raise_os_failure(exc)
    _validate_parent_entry(parent, opened, True)
    _validate_parent_entry(parent, current, True)
    identity = (opened.st_dev, opened.st_ino)
    if identity != (before.st_dev, before.st_ino) or identity != (
        current.st_dev,
        current.st_ino,
    ):
        _close_after_error(descriptor)
        _terminal()
    return descriptor, parent, name, identity


def _validate_open_posix_parent(
    descriptor: int, parent: str, identity: tuple[int, int]
) -> None:
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(parent)
    except OSError as exc:
        _raise_os_failure(exc)
    _validate_parent_entry(parent, opened, True)
    _validate_parent_entry(parent, current, True)
    if identity != (opened.st_dev, opened.st_ino) or identity != (
        current.st_dev,
        current.st_ino,
    ):
        _terminal()


def _open_posix_carrier(directory_fd: int, name: str) -> _Carrier | None:
    try:
        before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as exc:
        _raise_os_failure(exc)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        _capability()
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or not _pathname_link_count_valid(before)
        or not _owned(before)
        or stat.S_IMODE(before.st_mode) != PRIVATE_FILE_MODE
    ):
        _terminal()
    descriptor: int | None = None
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_fd,
        )
        opened = os.fstat(descriptor)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        if descriptor is not None:
            _close_after_error(descriptor)
        _raise_os_failure(exc)
    identity = _identity(opened, False)
    if (
        not stat.S_ISREG(opened.st_mode)
        or not _descriptor_link_count_valid(opened, False)
        or not _owned(opened)
        or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE_MODE
        or _identity(before, False) != identity
        or _identity(current, False) != identity
        or not _pathname_link_count_valid(current)
    ):
        _close_after_error(descriptor)
        _terminal()
    raw_state = _raw_descriptor_state(opened)
    try:
        raw = _read_descriptor(descriptor, opened.st_size)
    except Exception:
        _close_after_error(descriptor)
        raise
    try:
        after = os.fstat(descriptor)
        after_path = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        _close_after_error(descriptor)
        _raise_os_failure(exc)
    if (
        _raw_descriptor_state(after) != raw_state
        or _identity(after_path, False) != identity
        or not _descriptor_link_count_valid(after, False)
        or not _pathname_link_count_valid(after_path)
    ):
        _close_after_error(descriptor)
        _terminal()
    return _Carrier(
        raw,
        hashlib.sha256(raw).hexdigest(),
        identity,
        _raw_descriptor_state(after),
        descriptor,
    )


def _validate_posix_carrier_path(
    directory_fd: int, name: str, carrier: _Carrier
) -> None:
    if carrier.descriptor is None:
        _terminal()
    try:
        held = os.fstat(carrier.descriptor)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        _raise_os_failure(exc)
    if (
        not stat.S_ISREG(held.st_mode)
        or not stat.S_ISREG(current.st_mode)
        or not _descriptor_link_count_valid(held, False)
        or not _pathname_link_count_valid(current)
        or not _owned(held)
        or stat.S_IMODE(held.st_mode) != PRIVATE_FILE_MODE
        or _identity(held, False) != carrier.identity
        or _identity(current, False) != carrier.identity
        or _raw_descriptor_state(held) != carrier.raw_state
    ):
        _terminal()


def _close_carrier(carrier: _Carrier | None) -> None:
    if carrier is not None and carrier.descriptor is not None:
        try:
            os.close(carrier.descriptor)
        except OSError as exc:
            _raise_os_failure(exc)


def _close_posix_resources(
    carriers: tuple[_Carrier | None, ...], directory_fd: int
) -> None:
    active_error = sys.exc_info()[0] is not None
    first_error: OSError | None = None
    closed: set[int] = set()
    for carrier in carriers:
        descriptor = None if carrier is None else carrier.descriptor
        if descriptor is None or descriptor in closed:
            continue
        closed.add(descriptor)
        try:
            os.close(descriptor)
        except OSError as exc:
            if first_error is None:
                first_error = exc
    if directory_fd not in closed:
        try:
            os.close(directory_fd)
        except OSError as exc:
            if first_error is None:
                first_error = exc
    if first_error is not None and not active_error:
        _raise_os_failure(first_error)


def _require_absent_posix(directory_fd: int, name: str) -> None:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        _raise_os_failure(exc)
    _terminal()


def _windows_parent(
    path: str, expected: tuple[int, int] | None = None
) -> tuple[str, tuple[int, int]]:
    parent = os.path.dirname(path)
    if not parent or not os.path.basename(path):
        _terminal()
    try:
        entry = os.lstat(parent)
    except OSError as exc:
        _raise_os_failure(exc)
    _validate_parent_entry(parent, entry, False)
    identity = (entry.st_dev, entry.st_ino)
    if expected is not None and identity != expected:
        _terminal()
    return parent, identity


def _require_absent_windows(path: str, parent_identity: tuple[int, int]) -> None:
    _windows_parent(path, parent_identity)
    try:
        entry = os.lstat(path)
    except FileNotFoundError:
        _windows_parent(path, parent_identity)
        return
    except OSError as exc:
        _raise_os_failure(exc)
    if _is_link_or_reparse(path, entry):
        _terminal()
    _terminal()


def _open_windows_carrier(
    path: str, parent_identity: tuple[int, int]
) -> _Carrier | None:
    _windows_parent(path, parent_identity)
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        _windows_parent(path, parent_identity)
        return None
    except OSError as exc:
        _raise_os_failure(exc)
    if (
        _is_link_or_reparse(path, before)
        or not stat.S_ISREG(before.st_mode)
        or not _pathname_link_count_valid(before)
        or not _owned(before)
    ):
        _terminal()
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOINHERIT", 0),
        )
        opened = os.fstat(descriptor)
        current = os.lstat(path)
    except OSError as exc:
        if descriptor is not None:
            _close_after_error(descriptor)
        _raise_os_failure(exc)
    identity = _identity(opened, True)
    if (
        not stat.S_ISREG(opened.st_mode)
        or not _descriptor_link_count_valid(opened, True)
        or not _owned(opened)
        or _identity(before, True) != identity
        or _identity(current, True) != identity
        or _is_link_or_reparse(path, current)
        or not _pathname_link_count_valid(current)
    ):
        _close_after_error(descriptor)
        _terminal()
    raw_state = _raw_descriptor_state(opened)
    try:
        raw = _read_descriptor(descriptor, opened.st_size)
    except Exception:
        _close_after_error(descriptor)
        raise
    try:
        after = os.fstat(descriptor)
        after_path = os.lstat(path)
    except OSError as exc:
        _close_after_error(descriptor)
        _raise_os_failure(exc)
    if (
        _raw_descriptor_state(after) != raw_state
        or not _descriptor_link_count_valid(after, True)
        or _identity(after_path, True) != identity
        or _is_link_or_reparse(path, after_path)
        or not _pathname_link_count_valid(after_path)
    ):
        _close_after_error(descriptor)
        _terminal()
    try:
        os.close(descriptor)
    except OSError as exc:
        _raise_os_failure(exc)
    _windows_parent(path, parent_identity)
    return _Carrier(
        raw,
        hashlib.sha256(raw).hexdigest(),
        identity,
        _raw_descriptor_state(after),
        None,
    )


def _validate_windows_carrier_path(
    path: str, parent_identity: tuple[int, int], carrier: _Carrier
) -> None:
    current = _open_windows_carrier(path, parent_identity)
    if (
        current is None
        or current.raw != carrier.raw
        or current.digest != carrier.digest
        or current.identity != carrier.identity
        or current.raw_state != carrier.raw_state
    ):
        _terminal()
    _windows_parent(path, parent_identity)


def _validate_posix_pair(
    directory_fd: int,
    anchor_name: str,
    anchor: _Carrier,
    sibling_name: str,
    sibling: _Carrier | None,
) -> None:
    """Bind an authority carrier around its captured sibling state."""

    _validate_posix_carrier_path(directory_fd, anchor_name, anchor)
    if sibling is None:
        _require_absent_posix(directory_fd, sibling_name)
    else:
        _validate_posix_carrier_path(directory_fd, sibling_name, sibling)
    _validate_posix_carrier_path(directory_fd, anchor_name, anchor)


def _validate_windows_pair(
    anchor_path: str,
    anchor: _Carrier,
    sibling_path: str,
    sibling: _Carrier | None,
    parent_identity: tuple[int, int],
) -> None:
    """Bind an authority carrier around its captured sibling state."""

    _validate_windows_carrier_path(anchor_path, parent_identity, anchor)
    if sibling is None:
        _require_absent_windows(sibling_path, parent_identity)
    else:
        _validate_windows_carrier_path(sibling_path, parent_identity, sibling)
    _validate_windows_carrier_path(anchor_path, parent_identity, anchor)


def _require_exact(carrier: _Carrier, expected_raw: bytes) -> None:
    if (
        carrier.raw != expected_raw
        or carrier.digest != hashlib.sha256(expected_raw).hexdigest()
    ):
        _terminal()


def _foreign_public_valid(
    carrier: _Carrier,
    repo: str,
    relative: str,
    branch: str,
    receipt: str,
    old_token: str,
) -> bool:
    try:
        value = json.loads(carrier.raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(value, dict):
        return False
    token = value.get("token")
    start_head = value.get("start_head")
    if (
        not isinstance(token, str)
        or not isinstance(start_head, str)
        or token == old_token
        or not _valid_token(token, start_head)
    ):
        return False
    expected = _expected_payload(repo, relative, branch, receipt, start_head, token)
    return carrier.raw == _canonical_bytes(expected)


def _inspect_posix(
    repo: str,
    relative: str,
    branch: str,
    public: str,
    tombstone: str,
    token: str,
    expected_raw: bytes,
) -> dict[str, str]:
    directory_fd, parent, public_name, parent_identity = _open_posix_parent(public)
    tombstone_name = os.path.basename(tombstone)
    public_carrier = tombstone_carrier = None
    try:
        public_carrier = _open_posix_carrier(directory_fd, public_name)
        tombstone_carrier = _open_posix_carrier(directory_fd, tombstone_name)
        _validate_open_posix_parent(directory_fd, parent, parent_identity)
        if tombstone_carrier is not None:
            _require_exact(tombstone_carrier, expected_raw)
            if public_carrier is not None and not _foreign_public_valid(
                public_carrier, repo, relative, branch, public, token
            ):
                _terminal()
            _validate_posix_pair(
                directory_fd,
                tombstone_name,
                tombstone_carrier,
                public_name,
                public_carrier,
            )
            _validate_open_posix_parent(directory_fd, parent, parent_identity)
            _validate_posix_pair(
                directory_fd,
                tombstone_name,
                tombstone_carrier,
                public_name,
                public_carrier,
            )
            return {"state": "retired"}
        if public_carrier is None:
            _terminal()
        _require_exact(public_carrier, expected_raw)
        _validate_posix_pair(
            directory_fd,
            public_name,
            public_carrier,
            tombstone_name,
            None,
        )
        _validate_open_posix_parent(directory_fd, parent, parent_identity)
        _validate_posix_pair(
            directory_fd,
            public_name,
            public_carrier,
            tombstone_name,
            None,
        )
        payload = json.loads(expected_raw)
        return {
            "start_head": payload["start_head"],
            "state": "active",
            "worktree": payload["worktree"],
        }
    finally:
        _close_posix_resources((public_carrier, tombstone_carrier), directory_fd)


def _inspect_windows(
    repo: str,
    relative: str,
    branch: str,
    public: str,
    tombstone: str,
    token: str,
    expected_raw: bytes,
) -> dict[str, str]:
    parent, parent_identity = _windows_parent(public)
    if os.path.dirname(tombstone) != parent:
        _terminal()
    public_carrier = _open_windows_carrier(public, parent_identity)
    tombstone_carrier = _open_windows_carrier(tombstone, parent_identity)
    _windows_parent(public, parent_identity)
    if tombstone_carrier is not None:
        _require_exact(tombstone_carrier, expected_raw)
        if public_carrier is not None and not _foreign_public_valid(
            public_carrier, repo, relative, branch, public, token
        ):
            _terminal()
        _validate_windows_pair(
            tombstone,
            tombstone_carrier,
            public,
            public_carrier,
            parent_identity,
        )
        _windows_parent(public, parent_identity)
        _validate_windows_pair(
            tombstone,
            tombstone_carrier,
            public,
            public_carrier,
            parent_identity,
        )
        return {"state": "retired"}
    if public_carrier is None:
        _terminal()
    _require_exact(public_carrier, expected_raw)
    _validate_windows_pair(
        public,
        public_carrier,
        tombstone,
        None,
        parent_identity,
    )
    _windows_parent(public, parent_identity)
    _validate_windows_pair(
        public,
        public_carrier,
        tombstone,
        None,
        parent_identity,
    )
    payload = json.loads(expected_raw)
    return {
        "start_head": payload["start_head"],
        "state": "active",
        "worktree": payload["worktree"],
    }


def inspect_receipt(
    *, repo: str, relative: str, branch: str, receipt: str, start_head: str, token: str
) -> dict[str, str]:
    _require_atomic_move()
    canonical_repo, public, tombstone, expected_raw = _validated_context(
        repo, relative, branch, receipt, start_head, token
    )
    if _native_windows():
        return _inspect_windows(
            canonical_repo,
            relative,
            branch,
            public,
            tombstone,
            token,
            expected_raw,
        )
    return _inspect_posix(
        canonical_repo,
        relative,
        branch,
        public,
        tombstone,
        token,
        expected_raw,
    )


def _write_all(descriptor: int, raw: bytes) -> None:
    offset = 0
    while offset < len(raw):
        try:
            written = os.write(descriptor, raw[offset:])
        except OSError as exc:
            _raise_os_failure(exc)
        if written <= 0:
            _internal()
        offset += written


def _sync_stage_descriptor(descriptor: int) -> None:
    try:
        os.fsync(descriptor)
    except OSError as exc:
        if exc.errno == errno.EINVAL:
            _capability()
        raise


def _stage_fstat(descriptor: int) -> os.stat_result:
    return os.fstat(descriptor)


def _close_stage_descriptor(descriptor: int) -> None:
    os.close(descriptor)


def _sync_posix_directory(
    descriptor: int, parent: str, identity: tuple[int, int]
) -> None:
    _validate_open_posix_parent(descriptor, parent, identity)
    try:
        os.fsync(descriptor)
    except OSError as exc:
        if exc.errno == errno.EINVAL:
            _capability()
        _raise_os_failure(exc)
    _validate_open_posix_parent(descriptor, parent, identity)


def _validate_create_git(repo: str, branch: str, start_head: str, target: str) -> None:
    try:
        root_probe = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--show-toplevel"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        head_probe = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        branch_probe = subprocess.run(
            [
                "git",
                "-C",
                repo,
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/" + branch,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        _internal()
    except OSError as exc:
        if exc.errno in _TRANSIENT_ERRNOS:
            _transient()
        _internal()
    if root_probe.returncode != 0 or head_probe.returncode != 0:
        _terminal()
    if (
        os.path.realpath(root_probe.stdout.strip()) != repo
        or head_probe.stdout.strip() != start_head
        or branch_probe.returncode not in (0, 1)
    ):
        _terminal()
    if branch_probe.returncode == 0 or os.path.lexists(target):
        _terminal()


def _create_posix(
    public: str, tombstone: str, stage: str, raw: bytes, token: str
) -> None:
    directory_fd, parent, public_name, parent_identity = _open_posix_parent(public)
    tombstone_name = os.path.basename(tombstone)
    stage_name = os.path.basename(stage)
    descriptor: int | None = None
    stage_carrier: _Carrier | None = None
    public_carrier: _Carrier | None = None
    published = False
    try:
        _require_absent_posix(directory_fd, tombstone_name)
        _require_absent_posix(directory_fd, public_name)
        _require_absent_posix(directory_fd, stage_name)
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )
        try:
            descriptor = os.open(
                stage_name, flags, PRIVATE_FILE_MODE, dir_fd=directory_fd
            )
            os.fchmod(descriptor, PRIVATE_FILE_MODE)
        except FileExistsError:
            _terminal()
        except OSError as exc:
            _raise_os_failure(exc)
        _write_all(descriptor, raw)
        try:
            _sync_stage_descriptor(descriptor)
            opened = _stage_fstat(descriptor)
            current = os.stat(stage_name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as exc:
            _raise_os_failure(exc)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not _descriptor_link_count_valid(opened, False)
            or not _pathname_link_count_valid(current)
            or not _owned(opened)
            or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE_MODE
            or _identity(opened, False) != _identity(current, False)
            or opened.st_size != len(raw)
        ):
            _terminal()
        created_identity = _identity(opened, False)
        created_state = _raw_descriptor_state(opened)
        try:
            _close_stage_descriptor(descriptor)
        except OSError as exc:
            _raise_os_failure(exc)
        descriptor = None

        stage_carrier = _open_posix_carrier(directory_fd, stage_name)
        if stage_carrier is None:
            _terminal()
        _require_exact(stage_carrier, raw)
        if (
            stage_carrier.identity != created_identity
            or stage_carrier.raw_state != created_state
        ):
            _terminal()
        _validate_open_posix_parent(directory_fd, parent, parent_identity)
        _sync_posix_directory(directory_fd, parent, parent_identity)
        try:
            atomic_rename_noreplace(stage_name, public_name, dir_fd=directory_fd)
        except OSError as exc:
            try:
                held = os.fstat(stage_carrier.descriptor)
            except OSError as held_exc:
                _raise_os_failure(held_exc)
            public_carrier = _open_posix_carrier(directory_fd, public_name)
            if public_carrier is not None:
                _require_exact(public_carrier, raw)
                if (
                    _descriptor_link_count_valid(held, False)
                    and _identity(held, False) == stage_carrier.identity
                    and public_carrier.identity == stage_carrier.identity
                    and public_carrier.digest == stage_carrier.digest
                ):
                    published = True
                    raise PublishedTransientReceiptError(token) from exc
                _terminal()
            if isinstance(exc, (FileExistsError, FileNotFoundError)):
                _terminal()
            _raise_os_failure(exc)
        published = True

        if stage_carrier.descriptor is None:
            _internal()
        try:
            held = os.fstat(stage_carrier.descriptor)
        except OSError as exc:
            _raise_os_failure(exc)
        if (
            not _descriptor_link_count_valid(held, False)
            or _identity(held, False) != stage_carrier.identity
        ):
            _terminal()
        public_carrier = _open_posix_carrier(directory_fd, public_name)
        if public_carrier is None:
            _terminal()
        _require_exact(public_carrier, raw)
        if (
            public_carrier.identity != stage_carrier.identity
            or public_carrier.digest != stage_carrier.digest
        ):
            _terminal()
        _validate_posix_carrier_path(directory_fd, public_name, public_carrier)
        _sync_posix_directory(directory_fd, parent, parent_identity)
        _validate_posix_carrier_path(directory_fd, public_name, public_carrier)

        _close_carrier(public_carrier)
        public_carrier = None
        _close_carrier(stage_carrier)
        stage_carrier = None
        try:
            os.close(directory_fd)
        except OSError as exc:
            _raise_os_failure(exc)
        directory_fd = -1
    except PublishedTransientReceiptError:
        raise
    except TransientReceiptError as exc:
        if published:
            raise PublishedTransientReceiptError(token) from exc
        raise
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        for carrier in (public_carrier, stage_carrier):
            if carrier is not None and carrier.descriptor is not None:
                try:
                    os.close(carrier.descriptor)
                except OSError:
                    pass
        if directory_fd >= 0:
            try:
                os.close(directory_fd)
            except OSError:
                pass


def _create_windows(
    public: str, tombstone: str, stage: str, raw: bytes, token: str
) -> None:
    parent, parent_identity = _windows_parent(public)
    _require_absent_windows(tombstone, parent_identity)
    _require_absent_windows(public, parent_identity)
    _require_absent_windows(stage, parent_identity)
    descriptor: int | None = None
    published = False
    try:
        try:
            descriptor = os.open(
                stage,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_BINARY", 0)
                | getattr(os, "O_NOINHERIT", 0),
                PRIVATE_FILE_MODE,
            )
            _write_all(descriptor, raw)
            _sync_stage_descriptor(descriptor)
            opened = _stage_fstat(descriptor)
            current = os.lstat(stage)
        except FileExistsError:
            _terminal()
        except OSError as exc:
            _raise_os_failure(exc)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not _descriptor_link_count_valid(opened, True)
            or not _pathname_link_count_valid(current)
            or _is_link_or_reparse(stage, current)
            or _identity(opened, True) != _identity(current, True)
            or opened.st_size != len(raw)
        ):
            _terminal()
        created_identity = _identity(opened, True)
        created_state = _raw_descriptor_state(opened)
        try:
            _close_stage_descriptor(descriptor)
        except OSError as exc:
            _raise_os_failure(exc)
        descriptor = None

        _windows_parent(public, parent_identity)
        staged = _open_windows_carrier(stage, parent_identity)
        if staged is None:
            _terminal()
        _require_exact(staged, raw)
        if staged.identity != created_identity or staged.raw_state != created_state:
            _terminal()
        try:
            atomic_rename_noreplace(stage, public)
        except OSError as exc:
            captured = _open_windows_carrier(public, parent_identity)
            if captured is not None:
                _require_exact(captured, raw)
                if _windows_rename_carriers_match(staged, captured):
                    published = True
                    raise PublishedTransientReceiptError(token) from exc
                _terminal()
            if isinstance(exc, (FileExistsError, FileNotFoundError)):
                _terminal()
            _raise_os_failure(exc)
        published = True
        _windows_parent(public, parent_identity)
        captured = _open_windows_carrier(public, parent_identity)
        if captured is None:
            _terminal()
        _require_exact(captured, raw)
        if not _windows_rename_carriers_match(staged, captured):
            _terminal()
        _validate_windows_carrier_path(public, parent_identity, captured)
    except PublishedTransientReceiptError:
        raise
    except TransientReceiptError as exc:
        if published:
            raise PublishedTransientReceiptError(token) from exc
        raise
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def create_receipt(
    *, repo: str, relative: str, branch: str, receipt: str, start_head: str
) -> dict[str, str]:
    _require_atomic_move()
    if _HEAD_PATTERN.fullmatch(start_head or "") is None:
        _terminal()
    token = secrets.token_hex(16) + ":" + start_head
    canonical_repo, public, tombstone, raw = _validated_context(
        repo, relative, branch, receipt, start_head, token
    )
    stage = _stage_path(public, token)
    payload = json.loads(raw)
    _validate_create_git(canonical_repo, branch, start_head, payload["worktree"])
    if _native_windows():
        _create_windows(public, tombstone, stage, raw, token)
    else:
        _create_posix(public, tombstone, stage, raw, token)
    return {"state": "active", "token": token}


def _retire_posix(
    repo: str,
    relative: str,
    branch: str,
    public: str,
    tombstone: str,
    token: str,
    expected_raw: bytes,
) -> dict[str, str]:
    directory_fd, parent, public_name, parent_identity = _open_posix_parent(public)
    tombstone_name = os.path.basename(tombstone)
    source = existing_tombstone = moved = new_public = None
    try:
        source = _open_posix_carrier(directory_fd, public_name)
        existing_tombstone = _open_posix_carrier(directory_fd, tombstone_name)
        if existing_tombstone is not None:
            _require_exact(existing_tombstone, expected_raw)
            if source is not None and not _foreign_public_valid(
                source, repo, relative, branch, public, token
            ):
                _terminal()
            _validate_posix_pair(
                directory_fd,
                tombstone_name,
                existing_tombstone,
                public_name,
                source,
            )
            _sync_posix_directory(directory_fd, parent, parent_identity)
            _validate_posix_pair(
                directory_fd,
                tombstone_name,
                existing_tombstone,
                public_name,
                source,
            )
            return {"state": "retired"}
        if source is None:
            _terminal()
        _require_exact(source, expected_raw)
        _sync_posix_directory(directory_fd, parent, parent_identity)
        try:
            atomic_rename_noreplace(public_name, tombstone_name, dir_fd=directory_fd)
        except (FileExistsError, FileNotFoundError):
            _terminal()
        except OSError as exc:
            _raise_os_failure(exc)
        try:
            held = os.fstat(source.descriptor)
        except OSError as exc:
            _raise_os_failure(exc)
        if (
            not _descriptor_link_count_valid(held, False)
            or _identity(held, False) != source.identity
        ):
            _terminal()
        moved = _open_posix_carrier(directory_fd, tombstone_name)
        if moved is None:
            _terminal()
        _require_exact(moved, expected_raw)
        if moved.identity != source.identity or moved.digest != source.digest:
            _terminal()
        new_public = _open_posix_carrier(directory_fd, public_name)
        if new_public is not None and not _foreign_public_valid(
            new_public, repo, relative, branch, public, token
        ):
            _terminal()
        _validate_posix_pair(
            directory_fd,
            tombstone_name,
            moved,
            public_name,
            new_public,
        )
        _sync_posix_directory(directory_fd, parent, parent_identity)
        _validate_posix_pair(
            directory_fd,
            tombstone_name,
            moved,
            public_name,
            new_public,
        )
        return {"state": "retired"}
    finally:
        _close_posix_resources(
            (source, existing_tombstone, moved, new_public), directory_fd
        )


def _retire_windows(
    repo: str,
    relative: str,
    branch: str,
    public: str,
    tombstone: str,
    token: str,
    expected_raw: bytes,
) -> dict[str, str]:
    parent, parent_identity = _windows_parent(public)
    if os.path.dirname(tombstone) != parent:
        _terminal()
    source = _open_windows_carrier(public, parent_identity)
    existing_tombstone = _open_windows_carrier(tombstone, parent_identity)
    if existing_tombstone is not None:
        _require_exact(existing_tombstone, expected_raw)
        if source is not None and not _foreign_public_valid(
            source, repo, relative, branch, public, token
        ):
            _terminal()
        _validate_windows_pair(
            tombstone,
            existing_tombstone,
            public,
            source,
            parent_identity,
        )
        _windows_parent(public, parent_identity)
        _validate_windows_pair(
            tombstone,
            existing_tombstone,
            public,
            source,
            parent_identity,
        )
        return {"state": "retired"}
    if source is None:
        _terminal()
    _require_exact(source, expected_raw)
    _windows_parent(public, parent_identity)
    try:
        atomic_rename_noreplace(public, tombstone)
    except (FileExistsError, FileNotFoundError):
        _terminal()
    except OSError as exc:
        _raise_os_failure(exc)
    _windows_parent(public, parent_identity)
    moved = _open_windows_carrier(tombstone, parent_identity)
    if moved is None:
        _terminal()
    _require_exact(moved, expected_raw)
    if not _windows_rename_carriers_match(source, moved):
        _terminal()
    new_public = _open_windows_carrier(public, parent_identity)
    if new_public is not None and not _foreign_public_valid(
        new_public, repo, relative, branch, public, token
    ):
        _terminal()
    _validate_windows_pair(
        tombstone,
        moved,
        public,
        new_public,
        parent_identity,
    )
    _windows_parent(public, parent_identity)
    _validate_windows_pair(
        tombstone,
        moved,
        public,
        new_public,
        parent_identity,
    )
    return {"state": "retired"}


def retire_receipt(
    *, repo: str, relative: str, branch: str, receipt: str, start_head: str, token: str
) -> dict[str, str]:
    _require_atomic_move()
    canonical_repo, public, tombstone, expected_raw = _validated_context(
        repo, relative, branch, receipt, start_head, token
    )
    if _native_windows():
        return _retire_windows(
            canonical_repo,
            relative,
            branch,
            public,
            tombstone,
            token,
            expected_raw,
        )
    return _retire_posix(
        canonical_repo,
        relative,
        branch,
        public,
        tombstone,
        token,
        expected_raw,
    )


class _ClosedParser(argparse.ArgumentParser):
    def error(self, _message: str) -> NoReturn:
        _terminal()


def _parser() -> argparse.ArgumentParser:
    parser = _ClosedParser(add_help=False)
    parser.add_argument("operation", choices=("create", "inspect", "retire"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--relative", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--start-head", required=True)
    parser.add_argument("--token")
    return parser


def _emit(value: dict[str, str]) -> None:
    sys.stdout.write(
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    )


def main() -> int:
    try:
        args = _parser().parse_args()
        common = {
            "repo": args.repo,
            "relative": args.relative,
            "branch": args.branch,
            "receipt": args.receipt,
            "start_head": args.start_head,
        }
        if args.operation == "create":
            if args.token is not None:
                _terminal()
            result = create_receipt(**common)
        else:
            if args.token is None:
                _terminal()
            common["token"] = args.token
            result = (
                inspect_receipt(**common)
                if args.operation == "inspect"
                else retire_receipt(**common)
            )
        _emit(result)
    except PublishedTransientReceiptError as exc:
        if _TOKEN_PATTERN.fullmatch(exc.token or "") is None:
            sys.stderr.write("uberdev worktree receipt: internal failure\n")
            return 3
        try:
            _emit({"state": "active_unconfirmed", "token": exc.token})
        except Exception:
            sys.stderr.write("uberdev worktree receipt: internal failure\n")
            return 3
        sys.stderr.write("uberdev worktree receipt: operation failed\n")
        return 2
    except TerminalReceiptError:
        sys.stderr.write("uberdev worktree receipt: invalid authority\n")
        return 3
    except TransientReceiptError:
        sys.stderr.write("uberdev worktree receipt: operation failed\n")
        return 2
    except CapabilityReceiptError:
        sys.stderr.write("uberdev worktree receipt: unsupported capability\n")
        return 3
    except InternalReceiptError:
        sys.stderr.write("uberdev worktree receipt: internal failure\n")
        return 3
    except Exception:
        sys.stderr.write("uberdev worktree receipt: internal failure\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
