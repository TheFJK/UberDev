#!/usr/bin/env python3
"""Allocate one carrier-bound private command workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from typing import Any

PRIVATE_DIR = 0o700
PRIVATE_FILE = 0o600
RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]+")
IDENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
CALLERS = {
    "review-pr": {
        "workflows": {"review-pr", "solve", "turbo"},
        "artifacts": {
            "diff": ("pr-diff.md", b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'),
            "criteria": ("review-criteria.md", b""),
            "commit_range": ("commit-range.txt", b""),
            "phase1_disposition": ("phase1-disposition.json", b"{}\n"),
            "phase2_disposition": ("phase2-disposition.json", b"{}\n"),
        },
    },
    "simplify": {
        "workflows": {"simplify"},
        "artifacts": {
            "diff": ("pr-diff.md", b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'),
            "aggregate": ("simplify-final.md", b""),
            "commit_range": ("commit-range.txt", b""),
            "phase1_disposition": ("phase1-disposition.json", b"{}\n"),
            "phase2_disposition": ("phase2-disposition.json", b"{}\n"),
        },
    },
    "post-impl-review": {
        "workflows": {"review-pr", "solve", "turbo"},
        "artifacts": {
            "diff": ("pr-diff.md", None),
            "criteria": ("review-criteria.md", None),
        },
    },
}
DESCRIPTOR_KEYS = {
    "schema_version", "caller", "carrier_workflow", "carrier_run_id",
    "context_file", "context_sha256", "repository_root", "carrier_run_dir",
    "research_dir", "artifacts",
}
_DIR_FD_FUNCTIONS = getattr(os, "supports_dir_fd", set())
_SECURE_DIR_FD = hasattr(os, "O_DIRECTORY") and all(
    function in _DIR_FD_FUNCTIONS
    for function in (os.open, os.stat, os.mkdir, os.unlink, os.rmdir)
)
WINDOWS_STATUS_OBJECT_NAME_COLLISION = 0xC0000035
WINDOWS_STATUS_SHARING_VIOLATION = 0xC0000043
WINDOWS_DIRECTORY_BIND_TIMEOUT_SECONDS = 2.0
WINDOWS_DIRECTORY_BIND_RETRY_INTERVAL_SECONDS = 0.01


class Failure(Exception):
    pass


class DirectoryBinding:
    __slots__ = ("handle", "handle_identity", "path_identity")

    def __init__(
        self,
        handle: int | None,
        handle_identity: tuple[int, int],
        path_identity: tuple[int, int],
    ) -> None:
        self.handle = handle
        self.handle_identity = handle_identity
        self.path_identity = path_identity


def native_windows() -> bool:
    return os.name == "nt"


def effective_uid() -> int | None:
    uid_function = getattr(os, "geteuid", None)
    return uid_function() if uid_function is not None else None


def secure_dir_fd_available() -> bool:
    return _SECURE_DIR_FD


def filesystem_mode() -> str:
    if native_windows():
        return "portable_windows"
    if effective_uid() is None or not secure_dir_fd_available():
        fail("unsupported_platform")
    return "descriptor_relative"


def state_directory_name() -> str:
    uid = effective_uid()
    if uid is not None:
        return f".agent-state-{uid}"
    if native_windows():
        return ".agent-state-0"
    fail("unsupported_platform")


def owned_by_current_user(entry: os.stat_result) -> bool:
    uid = effective_uid()
    return uid is not None and entry.st_uid == uid


def fail(reason: str) -> None:
    raise Failure(reason)


def beneath(root: str, path: str) -> bool:
    try:
        return os.path.commonpath((root, path)) == root
    except ValueError:
        return False


REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


def linked(entry: os.stat_result) -> bool:
    return stat.S_ISLNK(entry.st_mode) or bool(
        getattr(entry, "st_file_attributes", 0) & REPARSE_POINT
    )


def same_portable_path(left: str, right: str) -> bool:
    return os.path.normcase(os.path.abspath(left)) == os.path.normcase(
        os.path.abspath(right)
    )


def file_identity(entry: os.stat_result, reason: str) -> tuple[int, int]:
    identity = (entry.st_dev, entry.st_ino)
    if type(identity[0]) is not int or type(identity[1]) is not int or identity[1] == 0:
        fail(reason)
    return identity


def same_file(left: os.stat_result, right: os.stat_result, reason: str) -> bool:
    return file_identity(left, reason) == file_identity(right, reason)


def portable_canonical(path: str, reason: str) -> str:
    if not isinstance(path, str) or not os.path.isabs(path):
        fail(reason)
    lexical = os.path.abspath(path)
    normalize = os.path.normcase
    if normalize(path) != normalize(lexical):
        fail(reason)
    resolved = os.path.realpath(lexical)
    if normalize(resolved) != normalize(lexical):
        fail(reason)
    return lexical


def portable_directory(path: str, reason: str) -> tuple[str, os.stat_result]:
    canonical = portable_canonical(path, reason)
    try:
        first = os.lstat(canonical)
        current = os.lstat(canonical)
    except OSError:
        fail(reason)
    if (
        linked(first)
        or linked(current)
        or not stat.S_ISDIR(first.st_mode)
        or not stat.S_ISDIR(current.st_mode)
        or not same_file(first, current, reason)
    ):
        fail(reason)
    return canonical, current


def windows_handle_identity(handle: int, reason: str) -> tuple[int, int]:
    if os.name != "nt":
        fail("unsupported_platform")
    import ctypes
    from ctypes import wintypes

    class FileStandardInformation(ctypes.Structure):
        _fields_ = [
            ("allocation_size", ctypes.c_longlong),
            ("end_of_file", ctypes.c_longlong),
            ("number_of_links", wintypes.DWORD),
            ("delete_pending", ctypes.c_ubyte),
            ("directory", ctypes.c_ubyte),
        ]

    class FileAttributeTagInformation(ctypes.Structure):
        _fields_ = [
            ("file_attributes", wintypes.DWORD),
            ("reparse_tag", wintypes.DWORD),
        ]

    class FileId128(ctypes.Structure):
        _fields_ = [("identifier", ctypes.c_ubyte * 16)]

    class FileIdInformation(ctypes.Structure):
        _fields_ = [
            ("volume_serial_number", ctypes.c_ulonglong),
            ("file_id", FileId128),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    get_information = kernel32.GetFileInformationByHandleEx
    get_information.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    get_information.restype = wintypes.BOOL
    standard = FileStandardInformation()
    attributes = FileAttributeTagInformation()
    identity = FileIdInformation()
    for information_class, information in (
        (1, standard),  # FileStandardInfo
        (9, attributes),  # FileAttributeTagInfo
        (18, identity),  # FileIdInfo
    ):
        if not get_information(
            wintypes.HANDLE(handle),
            information_class,
            ctypes.byref(information),
            ctypes.sizeof(information),
        ):
            fail(reason)
    if (
        not standard.directory
        or standard.delete_pending
        or standard.number_of_links == 0
        or not attributes.file_attributes & stat.FILE_ATTRIBUTE_DIRECTORY
        or attributes.file_attributes & REPARSE_POINT
        or attributes.reparse_tag != 0
    ):
        fail(reason)
    file_index = int.from_bytes(bytes(identity.file_id.identifier), "little")
    if file_index == 0:
        fail(reason)
    return int(identity.volume_serial_number), file_index


def close_directory_binding(binding: DirectoryBinding) -> None:
    if binding.handle is None:
        return
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    close_handle.restype = wintypes.BOOL
    close_handle(wintypes.HANDLE(binding.handle))
    binding.handle = None


def windows_open_directory(
    path: str, reason: str, share_delete: bool = False
) -> tuple[int, tuple[int, int]]:
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    create_file = kernel32.CreateFileW
    create_file.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    create_file.restype = wintypes.HANDLE
    handle = create_file(
        path,
        0x00000080,  # FILE_READ_ATTRIBUTES
        0x00000001
        | 0x00000002
        | (0x00000004 if share_delete else 0),  # FILE_SHARE_*
        None,
        3,  # OPEN_EXISTING
        0x02000000 | 0x00200000,  # BACKUP_SEMANTICS | OPEN_REPARSE_POINT
        None,
    )
    invalid_handle = ctypes.c_void_p(-1).value
    if handle in (None, invalid_handle):
        fail(reason)
    numeric_handle = int(handle)
    try:
        identity = windows_handle_identity(numeric_handle, reason)
    except Exception:
        close_directory_binding(
            DirectoryBinding(numeric_handle, (0, 0), (0, 0))
        )
        raise
    return numeric_handle, identity


def windows_directory_access(disposition: int) -> tuple[int, int]:
    share_access = 0x00000001 | 0x00000002  # FILE_SHARE_READ | FILE_SHARE_WRITE
    if disposition == 2:  # FILE_CREATE
        return (
            0x00010000
            | 0x00000080
            | 0x00100000,  # DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE
            share_access,
        )
    if disposition == 1:  # FILE_OPEN
        return (
            0x00000080 | 0x00100000,  # FILE_READ_ATTRIBUTES | SYNCHRONIZE
            share_access,
        )
    fail("unsafe_directory")


def windows_tracker_access() -> tuple[int, int]:
    return (
        0x00000080 | 0x00100000,  # FILE_READ_ATTRIBUTES | SYNCHRONIZE
        0x00000001 | 0x00000002 | 0x00000004,  # FILE_SHARE_READ|WRITE|DELETE
    )


def windows_verifier_access(created: bool) -> tuple[int, int]:
    return (
        0x00000080 | 0x00100000,  # FILE_READ_ATTRIBUTES | SYNCHRONIZE
        0x00000001
        | 0x00000002
        | (0x00000004 if created else 0),  # FILE_SHARE_READ|WRITE[|DELETE]
    )


def windows_retry_delay(deadline: float, now: float) -> float:
    remaining = deadline - now
    if remaining <= 0:
        fail("unsafe_directory")
    return min(WINDOWS_DIRECTORY_BIND_RETRY_INTERVAL_SECONDS, remaining)


def windows_create_or_open_child(
    parent: DirectoryBinding, name: str, reason: str
) -> tuple[int, tuple[int, int], bool]:
    if parent.handle is None:
        fail(reason)
    import ctypes
    from ctypes import wintypes

    class UnicodeString(ctypes.Structure):
        _fields_ = [
            ("length", wintypes.USHORT),
            ("maximum_length", wintypes.USHORT),
            ("buffer", wintypes.LPWSTR),
        ]

    class ObjectAttributes(ctypes.Structure):
        _fields_ = [
            ("length", wintypes.ULONG),
            ("root_directory", wintypes.HANDLE),
            ("object_name", ctypes.POINTER(UnicodeString)),
            ("attributes", wintypes.ULONG),
            ("security_descriptor", wintypes.LPVOID),
            ("security_quality_of_service", wintypes.LPVOID),
        ]

    class IoStatusBlock(ctypes.Structure):
        _fields_ = [
            ("status", wintypes.LPVOID),
            ("information", ctypes.c_size_t),
        ]

    name_buffer = ctypes.create_unicode_buffer(name)
    object_name = UnicodeString(
        len(name.encode("utf-16-le")),
        ctypes.sizeof(name_buffer),
        ctypes.cast(name_buffer, wintypes.LPWSTR),
    )
    attributes = ObjectAttributes(
        ctypes.sizeof(ObjectAttributes),
        wintypes.HANDLE(parent.handle),
        ctypes.pointer(object_name),
        0x00000040,  # OBJ_CASE_INSENSITIVE
        None,
        None,
    )
    ntdll = ctypes.WinDLL("ntdll")
    create_file = ntdll.NtCreateFile
    create_file.argtypes = [
        ctypes.POINTER(wintypes.HANDLE),
        wintypes.ULONG,
        ctypes.POINTER(ObjectAttributes),
        ctypes.POINTER(IoStatusBlock),
        wintypes.LPVOID,
        wintypes.ULONG,
        wintypes.ULONG,
        wintypes.ULONG,
        wintypes.ULONG,
        wintypes.LPVOID,
        wintypes.ULONG,
    ]
    create_file.restype = wintypes.LONG

    def invoke(
        disposition: int, desired_access: int, share_access: int
    ) -> tuple[int, int]:
        handle = wintypes.HANDLE()
        io_status = IoStatusBlock()
        status = create_file(
            ctypes.byref(handle),
            desired_access,
            ctypes.byref(attributes),
            ctypes.byref(io_status),
            None,
            0x00000080,  # FILE_ATTRIBUTE_NORMAL
            share_access,
            disposition,
            0x00000001
            | 0x00000020
            | 0x00004000
            | 0x00200000,  # DIRECTORY | SYNC | BACKUP | OPEN_REPARSE_POINT
            None,
            0,
        )
        return int(status), int(handle.value or 0)

    create_access, create_share = windows_directory_access(2)
    status, handle = invoke(2, create_access, create_share)  # FILE_CREATE
    created = status >= 0
    bound_binding: DirectoryBinding
    identity: tuple[int, int]
    if not created:
        if (
            ctypes.c_uint32(status).value
            != WINDOWS_STATUS_OBJECT_NAME_COLLISION
        ):
            fail(reason)
        tracker_access, tracker_share = windows_tracker_access()
        tracker_status, tracker_handle = invoke(
            1, tracker_access, tracker_share
        )
        if tracker_status < 0 or tracker_handle == 0:
            fail(reason)
        tracker = DirectoryBinding(tracker_handle, (0, 0), (0, 0))
        guard: DirectoryBinding | None = None
        try:
            tracker_identity = windows_handle_identity(
                tracker_handle, reason
            )
            tracker.handle_identity = tracker_identity
            deadline = (
                time.monotonic() + WINDOWS_DIRECTORY_BIND_TIMEOUT_SECONDS
            )
            open_access, open_share = windows_directory_access(1)
            while True:
                guard_status, guard_handle = invoke(
                    1, open_access, open_share
                )
                if guard_status >= 0:
                    if guard_handle == 0:
                        fail(reason)
                    break
                if (
                    ctypes.c_uint32(guard_status).value
                    != WINDOWS_STATUS_SHARING_VIOLATION
                ):
                    fail(reason)
                delay = windows_retry_delay(deadline, time.monotonic())
                time.sleep(delay)
            guard = DirectoryBinding(guard_handle, (0, 0), (0, 0))
            try:
                identity = windows_handle_identity(guard_handle, reason)
                guard.handle_identity = identity
                if identity != tracker_identity:
                    fail(reason)
            except Exception:
                close_directory_binding(guard)
                raise
            bound_binding = guard
            handle = guard_handle
        finally:
            close_directory_binding(tracker)
    else:
        if handle == 0:
            fail(reason)
        bound_binding = DirectoryBinding(handle, (0, 0), (0, 0))
        try:
            identity = windows_handle_identity(handle, reason)
        except Exception:
            try:
                windows_mark_directory_for_deletion(bound_binding, reason)
            except Failure:
                pass
            close_directory_binding(bound_binding)
            raise
        bound_binding.handle_identity = identity
    verify_access, verify_share = windows_verifier_access(created)
    verify_status, verify_handle = invoke(1, verify_access, verify_share)
    if verify_status < 0 or verify_handle == 0:
        if created:
            try:
                windows_mark_directory_for_deletion(bound_binding, reason)
            except Failure:
                pass
        close_directory_binding(bound_binding)
        fail(reason)
    try:
        if windows_handle_identity(verify_handle, reason) != identity:
            fail(reason)
    except Exception:
        if created:
            try:
                windows_mark_directory_for_deletion(bound_binding, reason)
            except Failure:
                pass
        close_directory_binding(bound_binding)
        raise
    finally:
        close_directory_binding(
            DirectoryBinding(verify_handle, identity, (0, 0))
        )
    return handle, identity, created


def windows_mark_directory_for_deletion(
    binding: DirectoryBinding, reason: str
) -> None:
    if binding.handle is None:
        fail(reason)
    import ctypes
    from ctypes import wintypes

    class FileDispositionInformation(ctypes.Structure):
        _fields_ = [("delete_file", ctypes.c_ubyte)]

    disposition = FileDispositionInformation(True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    set_information = kernel32.SetFileInformationByHandle
    set_information.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    set_information.restype = wintypes.BOOL
    if not set_information(
        wintypes.HANDLE(binding.handle),
        4,  # FileDispositionInfo
        ctypes.byref(disposition),
        ctypes.sizeof(disposition),
    ):
        fail(reason)


def windows_binding_matches_path(
    path: str, binding: DirectoryBinding, reason: str
) -> bool:
    verify_handle, identity = windows_open_directory(
        path, reason, share_delete=True
    )
    verifier = DirectoryBinding(verify_handle, identity, (0, 0))
    try:
        return identity == binding.handle_identity
    finally:
        close_directory_binding(verifier)


def portable_bind_existing_directory(path: str, reason: str) -> DirectoryBinding:
    if os.name == "nt":
        handle, handle_identity = windows_open_directory(path, reason)
        try:
            _canonical, entry = portable_directory(path, reason)
            path_identity = file_identity(entry, reason)
        except Exception:
            close_directory_binding(
                DirectoryBinding(handle, handle_identity, (0, 0))
            )
            raise
        return DirectoryBinding(handle, handle_identity, path_identity)
    _canonical, entry = portable_directory(path, reason)
    identity = file_identity(entry, reason)
    return DirectoryBinding(None, identity, identity)


def portable_bind_or_create_child(
    parent_binding: DirectoryBinding, parent: str, name: str
) -> tuple[DirectoryBinding, bool]:
    if (
        not name
        or name in {".", ".."}
        or os.path.basename(name) != name
        or os.path.isabs(name)
    ):
        fail("unsafe_directory")
    path = os.path.join(parent, name)
    if os.name == "nt":
        handle, handle_identity, created = windows_create_or_open_child(
            parent_binding, name, "unsafe_directory"
        )
        try:
            _canonical, entry = portable_directory(path, "unsafe_directory")
            path_identity = file_identity(entry, "unsafe_directory")
        except Exception:
            binding = DirectoryBinding(handle, handle_identity, (0, 0))
            if created:
                try:
                    windows_mark_directory_for_deletion(
                        binding, "unsafe_directory"
                    )
                except Failure:
                    pass
            close_directory_binding(binding)
            raise
        return DirectoryBinding(handle, handle_identity, path_identity), created
    created = False
    try:
        os.mkdir(path, PRIVATE_DIR)
        created = True
    except FileExistsError:
        pass
    except OSError:
        fail("unsafe_directory")
    return portable_bind_existing_directory(path, "unsafe_directory"), created


def portable_read_regular(path: str, maximum: int, reason: str) -> bytes:
    canonical = portable_canonical(path, reason)
    parent, parent_before = portable_directory(os.path.dirname(canonical), reason)
    try:
        before = os.lstat(canonical)
    except OSError:
        fail(reason)
    if (
        linked(before)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size > maximum
    ):
        fail(reason)
    try:
        descriptor = os.open(canonical, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    except OSError:
        fail(reason)
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(canonical)
        if (
            linked(opened)
            or linked(current)
            or not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or opened.st_nlink != 1
            or current.st_nlink != 1
            or opened.st_size > maximum
            or not same_file(before, opened, reason)
            or not same_file(opened, current, reason)
        ):
            fail(reason)
        chunks: list[bytes] = []
        total = 0
        while total <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        raw = b"".join(chunks)
        final_opened = os.fstat(descriptor)
        final_current = os.lstat(canonical)
        if (
            len(raw) > maximum
            or linked(final_opened)
            or linked(final_current)
            or not stat.S_ISREG(final_opened.st_mode)
            or not stat.S_ISREG(final_current.st_mode)
            or final_opened.st_nlink != 1
            or final_current.st_nlink != 1
            or not same_file(opened, final_opened, reason)
            or not same_file(final_opened, final_current, reason)
        ):
            fail(reason)
    except OSError:
        fail(reason)
    finally:
        os.close(descriptor)
    _, parent_after = portable_directory(parent, reason)
    if not same_file(parent_before, parent_after, reason):
        fail(reason)
    return raw


def open_directory(path: str, private: bool = False) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    entry = os.fstat(fd)
    if (not stat.S_ISDIR(entry.st_mode) or not owned_by_current_user(entry)
            or (private and stat.S_IMODE(entry.st_mode) != PRIVATE_DIR)):
        os.close(fd)
        fail("unsafe_directory")
    return fd


def load_carrier(
    raw: str, caller: str
) -> tuple[dict[str, Any], dict[str, Any], str, str, tuple[int, int]]:
    try:
        carrier = json.loads(raw)
    except Exception:
        fail("invalid_carrier")
    keys = {"schema_version", "run_id", "workflow", "issue_num", "context_file", "context_sha256"}
    if not isinstance(carrier, dict) or set(carrier) != keys or carrier.get("schema_version") != 1:
        fail("invalid_carrier")
    workflow = carrier.get("workflow")
    if workflow not in CALLERS[caller]["workflows"]:
        fail("workflow_not_allowed")
    issue = carrier.get("issue_num")
    if type(issue) is not int or issue < 0 or (workflow != "simplify" and issue == 0):
        fail("invalid_carrier")
    if not IDENT.fullmatch(carrier.get("run_id", "")):
        fail("invalid_carrier")
    context_path = carrier.get("context_file")
    digest = carrier.get("context_sha256")
    if not isinstance(context_path, str) or not os.path.isabs(context_path) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("invalid_context")
    mode = filesystem_mode()
    state = os.path.dirname(context_path)
    if os.path.normcase(os.path.basename(state)) != os.path.normcase(state_directory_name()):
        fail("invalid_context")
    if mode == "portable_windows":
        state, _state_entry = portable_directory(state, "invalid_context")
        raw_context = portable_read_regular(context_path, 1048576, "invalid_context")
    else:
        state_fd = open_directory(state, private=True)
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            context_fd = os.open(os.path.basename(context_path), flags, dir_fd=state_fd)
            try:
                opened = os.fstat(context_fd)
                current = os.stat(os.path.basename(context_path), dir_fd=state_fd, follow_symlinks=False)
                raw_context = os.read(context_fd, 1048577)
            finally:
                os.close(context_fd)
        finally:
            os.close(state_fd)
        if (not stat.S_ISREG(opened.st_mode) or not owned_by_current_user(opened) or opened.st_nlink != 1
                or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
                or len(raw_context) > 1048576):
            fail("invalid_context")
    if hashlib.sha256(raw_context).hexdigest() != digest:
        fail("invalid_context")
    try:
        context = json.loads(raw_context)
        metadata = context["metadata"]
    except Exception:
        fail("invalid_context")
    if (metadata.get("run_id"), metadata.get("workflow"), metadata.get("issue_num")) != (carrier["run_id"], workflow, issue):
        fail("context_mismatch")
    repo_raw = metadata.get("repository_id")
    if not isinstance(repo_raw, str) or not os.path.isabs(repo_raw):
        fail("invalid_repository")
    if mode == "portable_windows":
        repo, verified_repo = portable_directory(repo_raw, "invalid_repository")
        repo_identity = file_identity(verified_repo, "invalid_repository")
        repo_fd = None
    else:
        repo = os.path.realpath(repo_raw)
        if repo != repo_raw:
            fail("invalid_repository")
        repo_fd = open_directory(repo)
        try:
            verified_repo = os.fstat(repo_fd)
        except OSError:
            os.close(repo_fd)
            fail("invalid_repository")
        repo_identity = (verified_repo.st_dev, verified_repo.st_ino)
    git_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git_env.update({
        "GIT_CONFIG_COUNT": "0",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
    })
    try:
        git_toplevel = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--show-toplevel"],
            check=True,
            env=git_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.rstrip("\n")
        if mode == "portable_windows":
            _, current_repo = portable_directory(repo, "invalid_repository")
        else:
            current_repo = os.stat(repo, follow_symlinks=False)
    except (OSError, subprocess.CalledProcessError):
        fail("invalid_repository")
    finally:
        if repo_fd is not None:
            os.close(repo_fd)
    same_toplevel = (
        os.path.normcase(os.path.abspath(git_toplevel))
        == os.path.normcase(os.path.abspath(repo))
        if mode == "portable_windows"
        else git_toplevel == repo
    )
    if not same_toplevel or file_identity(current_repo, "invalid_repository") != repo_identity:
        fail("invalid_repository")
    if mode == "portable_windows":
        carrier_run_dir, _run_entry = portable_directory(
            os.path.dirname(state), "invalid_context"
        )
    else:
        carrier_run_dir = os.path.realpath(os.path.dirname(state))
        run_fd = open_directory(carrier_run_dir)
        os.close(run_fd)
    return carrier, context, repo, carrier_run_dir, repo_identity


def open_or_create_dir(parent_fd: int, name: str, private: bool) -> tuple[int, bool]:
    created = False
    fd: int | None = None
    try:
        os.mkdir(name, PRIVATE_DIR, dir_fd=parent_fd)
        created = True
    except FileExistsError:
        pass
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(name, flags, dir_fd=parent_fd)
        entry = os.fstat(fd)
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (not stat.S_ISDIR(entry.st_mode) or not owned_by_current_user(entry)
                or (entry.st_dev, entry.st_ino) != (current.st_dev, current.st_ino)
                or (private and stat.S_IMODE(entry.st_mode) != PRIVATE_DIR)):
            fail("unsafe_directory")
        if created:
            os.fchmod(fd, PRIVATE_DIR)
        return fd, created
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if created:
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
        raise


def portable_beneath(root: str, path: str) -> bool:
    try:
        common = os.path.commonpath((root, path))
    except ValueError:
        return False
    return os.path.normcase(common) == os.path.normcase(root)


def portable_parent_unchanged(
    path: str, expected: os.stat_result, reason: str
) -> os.stat_result:
    _, current = portable_directory(path, reason)
    if not same_file(expected, current, reason):
        fail(reason)
    return current


def portable_open_or_create_dir(
    parent_binding: DirectoryBinding,
    parent: str,
    parent_entry: os.stat_result,
    name: str,
) -> tuple[str, os.stat_result, DirectoryBinding, bool]:
    portable_parent_unchanged(parent, parent_entry, "unsafe_directory")
    path = os.path.join(parent, name)
    binding: DirectoryBinding | None = None
    created = False
    try:
        binding, created = portable_bind_or_create_child(
            parent_binding, parent, name
        )
        canonical, entry = portable_directory(path, "unsafe_directory")
        if file_identity(entry, "unsafe_directory") != binding.path_identity:
            fail("unsafe_directory")
        portable_parent_unchanged(parent, parent_entry, "unsafe_directory")
        return canonical, entry, binding, created
    except Exception:
        if binding is not None:
            expected = binding.path_identity
            if created and os.name == "nt":
                try:
                    windows_mark_directory_for_deletion(
                        binding, "unsafe_directory"
                    )
                except Failure:
                    pass
            close_directory_binding(binding)
            if created and os.name != "nt":
                try:
                    current = os.lstat(path)
                    if (
                        not linked(current)
                        and stat.S_ISDIR(current.st_mode)
                        and file_identity(current, "unsafe_directory") == expected
                    ):
                        os.rmdir(path)
                except (Failure, OSError):
                    pass
        raise


def portable_regular_identity(
    path: str,
    before: os.stat_result,
    opened: os.stat_result,
    reason: str,
) -> os.stat_result:
    try:
        current = os.lstat(path)
    except OSError:
        fail(reason)
    if (
        linked(before)
        or linked(opened)
        or linked(current)
        or not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(opened.st_mode)
        or not stat.S_ISREG(current.st_mode)
        or before.st_nlink != 1
        or opened.st_nlink != 1
        or current.st_nlink != 1
        or not same_file(before, opened, reason)
        or not same_file(opened, current, reason)
    ):
        fail(reason)
    return current


def portable_create_or_validate_file(
    parent: str,
    parent_entry: os.stat_result,
    name: str,
    initial: bytes | None,
) -> tuple[str, os.stat_result, bool]:
    portable_parent_unchanged(parent, parent_entry, "unsafe_artifact")
    path = os.path.join(parent, name)
    if not portable_beneath(parent, path):
        fail("unsafe_artifact")
    descriptor: int | None = None
    created = False
    created_identity: tuple[int, int] | None = None
    try:
        try:
            descriptor = os.open(
                path,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_BINARY", 0),
                PRIVATE_FILE,
            )
            created = True
            opened = os.fstat(descriptor)
            created_identity = file_identity(opened, "unsafe_artifact")
            if (
                linked(opened)
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink != 1
            ):
                fail("unsafe_artifact")
            if initial is None:
                fail("required_artifact_missing")
            written = 0
            while written < len(initial):
                count = os.write(descriptor, initial[written:])
                if count <= 0:
                    fail("unsafe_artifact")
                written += count
            os.fsync(descriptor)
            final_opened = os.fstat(descriptor)
            if not same_file(opened, final_opened, "unsafe_artifact"):
                fail("unsafe_artifact")
            before = opened
        except FileExistsError:
            before = os.lstat(path)
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0))
            opened = os.fstat(descriptor)
            portable_regular_identity(path, before, opened, "unsafe_artifact")
        finally:
            if descriptor is not None:
                os.close(descriptor)
                descriptor = None
        current = portable_regular_identity(path, before, opened, "unsafe_artifact")
        portable_parent_unchanged(parent, parent_entry, "unsafe_artifact")
        return path, current, created
    except Exception as error:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if created and created_identity is not None:
            try:
                current = os.lstat(path)
                if (
                    not linked(current)
                    and stat.S_ISREG(current.st_mode)
                    and file_identity(current, "unsafe_artifact") == created_identity
                ):
                    os.unlink(path)
            except (Failure, OSError):
                pass
        if isinstance(error, OSError):
            fail("unsafe_artifact")
        raise


def allocate_workspace_portable(
    repo: str,
    run_id: str,
    artifacts: dict[str, tuple[str, bytes | None]],
    expected_repo_identity: tuple[int, int],
) -> tuple[str, dict[str, str]]:
    repo, initial_repo_entry = portable_directory(repo, "repository_changed")
    if (
        file_identity(initial_repo_entry, "repository_changed")
        != expected_repo_identity
    ):
        fail("repository_changed")
    repo_binding = portable_bind_existing_directory(repo, "repository_changed")
    repo, repo_entry = portable_directory(repo, "repository_changed")
    if (
        file_identity(repo_entry, "repository_changed") != expected_repo_identity
        or repo_binding.path_identity != expected_repo_identity
    ):
        close_directory_binding(repo_binding)
        fail("repository_changed")
    parents: list[tuple[str, os.stat_result]] = [(repo, repo_entry)]
    bindings: list[DirectoryBinding] = [repo_binding]
    created_dirs: list[
        tuple[str, tuple[int, int], DirectoryBinding]
    ] = []
    created_files: list[tuple[str, tuple[int, int]]] = []
    try:
        parent, parent_entry = parents[-1]
        for name in (".uberdev", "research", run_id):
            child, child_entry, child_binding, created = (
                portable_open_or_create_dir(
                    bindings[-1], parent, parent_entry, name
                )
            )
            if not portable_beneath(repo, child):
                fail("unsafe_directory")
            parents.append((child, child_entry))
            bindings.append(child_binding)
            if created:
                created_dirs.append(
                    (
                        child,
                        file_identity(child_entry, "unsafe_directory"),
                        child_binding,
                    )
                )
            parent, parent_entry = child, child_entry
        workspace = parent
        paths: dict[str, str] = {}
        for key, (name, initial) in artifacts.items():
            path, entry, created = portable_create_or_validate_file(
                workspace, parent_entry, name, initial
            )
            if created:
                created_files.append(
                    (path, file_identity(entry, "unsafe_artifact"))
                )
            paths[key] = path
        for path, expected in parents:
            _, current = portable_directory(path, "unsafe_directory")
            if file_identity(current, "unsafe_directory") != file_identity(
                expected, "unsafe_directory"
            ):
                fail("unsafe_directory")
        return workspace, paths
    except Exception:
        for path, expected in reversed(created_files):
            try:
                current = os.lstat(path)
                if (
                    not linked(current)
                    and stat.S_ISREG(current.st_mode)
                    and file_identity(current, "unsafe_artifact") == expected
                ):
                    os.unlink(path)
            except (Failure, OSError):
                pass
        if os.name == "nt":
            for path, _expected, binding in reversed(created_dirs):
                try:
                    if windows_binding_matches_path(
                        path, binding, "unsafe_directory"
                    ):
                        windows_mark_directory_for_deletion(
                            binding, "unsafe_directory"
                        )
                except Failure:
                    pass
                close_directory_binding(binding)
        else:
            for path, expected, _binding in reversed(created_dirs):
                try:
                    current = os.lstat(path)
                    if (
                        not linked(current)
                        and stat.S_ISDIR(current.st_mode)
                        and file_identity(current, "unsafe_directory") == expected
                    ):
                        os.rmdir(path)
                except (Failure, OSError):
                    pass
        raise
    finally:
        for binding in reversed(bindings):
            close_directory_binding(binding)


def allocate_workspace(
    repo: str,
    run_id: str,
    artifacts: dict[str, tuple[str, bytes | None]],
    expected_repo_identity: tuple[int, int],
) -> tuple[str, dict[str, str]]:
    if filesystem_mode() == "portable_windows":
        return allocate_workspace_portable(
            repo, run_id, artifacts, expected_repo_identity
        )
    repo_fd = open_directory(repo)
    opened_repo = os.fstat(repo_fd)
    if (opened_repo.st_dev, opened_repo.st_ino) != expected_repo_identity:
        os.close(repo_fd)
        fail("repository_changed")
    opened: list[int] = [repo_fd]
    created_dirs: list[tuple[int, str]] = []
    created_files: list[str] = []
    workspace_fd = -1
    try:
        parent_fd = repo_fd
        for index, name in enumerate((".uberdev", "research", run_id)):
            fd, created = open_or_create_dir(parent_fd, name, private=index == 2)
            opened.append(fd)
            if created:
                created_dirs.append((parent_fd, name))
            parent_fd = fd
        workspace_fd = parent_fd
        paths: dict[str, str] = {}
        workspace = os.path.join(repo, ".uberdev", "research", run_id)
        for key, (name, initial) in artifacts.items():
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            try:
                fd = os.open(name, flags, PRIVATE_FILE, dir_fd=workspace_fd)
                created_files.append(name)
                os.fchmod(fd, PRIVATE_FILE)
                if initial is None:
                    os.close(fd)
                    fail("required_artifact_missing")
                with os.fdopen(fd, "wb") as stream:
                    stream.write(initial)
                    stream.flush()
                    os.fsync(stream.fileno())
            except FileExistsError:
                fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=workspace_fd)
                try:
                    entry = os.fstat(fd)
                    current = os.stat(name, dir_fd=workspace_fd, follow_symlinks=False)
                finally:
                    os.close(fd)
                if (not stat.S_ISREG(entry.st_mode) or not owned_by_current_user(entry) or entry.st_nlink != 1
                        or stat.S_IMODE(entry.st_mode) != PRIVATE_FILE
                        or (entry.st_dev, entry.st_ino) != (current.st_dev, current.st_ino)):
                    fail("unsafe_artifact")
            paths[key] = os.path.join(workspace, name)
        try:
            os.fsync(workspace_fd)
        except OSError:
            pass
        return workspace, paths
    except Exception:
        if workspace_fd >= 0:
            for name in reversed(created_files):
                try:
                    os.unlink(name, dir_fd=workspace_fd)
                except OSError:
                    pass
        for parent_fd, name in reversed(created_dirs):
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
        raise
    finally:
        for fd in reversed(opened):
            try:
                os.close(fd)
            except OSError:
                pass


def validate_presets(presets: dict[str, Any], expected: dict[str, str], repo: str, workspace: str) -> None:
    mapping = {"WORKTREE_ROOT": repo, "RESEARCH_DIR_ABS": workspace, **expected}
    for key, value in presets.items():
        if value and mapping.get(key) != value:
            fail("preset_mismatch")


def validate_requested_root(
    requested: str,
    repo: str,
    repo_identity: tuple[int, int],
    mode: str,
) -> None:
    if not os.path.isabs(requested):
        fail("repository_mismatch")
    if mode == "portable_windows":
        requested, entry = portable_directory(
            requested, "repository_mismatch"
        )
        if (
            not same_portable_path(requested, repo)
            or file_identity(entry, "repository_mismatch") != repo_identity
        ):
            fail("repository_mismatch")
        return
    if os.path.realpath(requested) != repo:
        fail("repository_mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--caller", required=True, choices=tuple(CALLERS))
    parser.add_argument("--carrier-json", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--requested-root", default="")
    parser.add_argument("--parent-workspace-json", default="")
    parser.add_argument("--presets-json", required=True)
    args = parser.parse_args()
    if not RUN_ID.fullmatch(args.run_id):
        fail("invalid_run_id")
    carrier, _context, repo, carrier_run_dir, repo_identity = load_carrier(args.carrier_json, args.caller)
    if args.requested_root:
        validate_requested_root(
            args.requested_root, repo, repo_identity, filesystem_mode()
        )
    expected_workspace = os.path.join(repo, ".uberdev", "research", args.run_id)
    if args.caller == "post-impl-review":
        if not args.parent_workspace_json:
            fail("parent_workspace_required")
        try:
            parent = json.loads(args.parent_workspace_json)
        except Exception:
            fail("invalid_parent_workspace")
        if (not isinstance(parent, dict) or set(parent) != DESCRIPTOR_KEYS or parent.get("schema_version") != 1
                or parent.get("caller") != "review-pr" or parent.get("carrier_workflow") != carrier["workflow"]
                or parent.get("carrier_run_id") != carrier["run_id"] or parent.get("context_file") != carrier["context_file"]
                or parent.get("context_sha256") != carrier["context_sha256"] or parent.get("repository_root") != repo
                or parent.get("carrier_run_dir") != carrier_run_dir or parent.get("research_dir") != expected_workspace):
            fail("invalid_parent_workspace")
        expected_parent_artifacts = {
            key: os.path.join(expected_workspace, name)
            for key, (name, _initial) in CALLERS["review-pr"]["artifacts"].items()
        }
        if parent.get("artifacts") != expected_parent_artifacts:
            fail("invalid_parent_workspace")
    artifacts = CALLERS[args.caller]["artifacts"]
    expected_globals = {}
    name_to_global = {
        "diff": "DIFF_ARTIFACT_PATH", "criteria": "CRITERIA_PATH", "commit_range": "COMMIT_RANGE_PATH",
        "phase1_disposition": "PHASE1_DISPOSITION_PATH", "phase2_disposition": "PHASE2_DISPOSITION_PATH",
        "aggregate": "AGG_PATH",
    }
    for key, (name, _initial) in artifacts.items():
        expected_globals[name_to_global[key]] = os.path.join(expected_workspace, name)
    if args.caller == "post-impl-review":
        for key, path in parent["artifacts"].items():
            global_name = name_to_global.get(key)
            if global_name:
                expected_globals[global_name] = path
    try:
        presets = json.loads(args.presets_json)
    except Exception:
        fail("invalid_presets")
    if not isinstance(presets, dict):
        fail("invalid_presets")
    validate_presets(presets, expected_globals, repo, expected_workspace)
    workspace, paths = allocate_workspace(repo, args.run_id, artifacts, repo_identity)
    descriptor = {
        "schema_version": 1, "caller": args.caller, "carrier_workflow": carrier["workflow"],
        "carrier_run_id": carrier["run_id"], "context_file": carrier["context_file"],
        "context_sha256": carrier["context_sha256"], "repository_root": repo,
        "carrier_run_dir": carrier_run_dir, "research_dir": workspace, "artifacts": paths,
    }
    print(json.dumps(descriptor, sort_keys=True, separators=(",", ":")), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"uberdev command workspace: {error}", file=sys.stderr)
        raise SystemExit(2)
