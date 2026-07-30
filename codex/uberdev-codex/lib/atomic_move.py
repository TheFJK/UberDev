#!/usr/bin/env python3
"""Portable, atomic, same-parent rename without destination replacement."""

from __future__ import annotations

import ctypes
import errno
import os
import sys
from typing import Any


_RENAME_NOREPLACE = 0x00000001
_RENAME_EXCL = 0x00000004
_MOVEFILE_WRITE_THROUGH = 0x00000008


def _unsupported() -> OSError:
    number = getattr(errno, "ENOTSUP", errno.EOPNOTSUPP)
    return OSError(number, os.strerror(number))


def _invalid_parent() -> OSError:
    return OSError(errno.EXDEV, os.strerror(errno.EXDEV))


def _mapped_error(number: int) -> OSError:
    if number == 0:
        number = errno.EIO
    if number == errno.EEXIST:
        return FileExistsError(number, os.strerror(number))
    if number == errno.ENOENT:
        return FileNotFoundError(number, os.strerror(number))
    return OSError(number, os.strerror(number))


def _mapped_windows_error(number: int) -> OSError:
    if number in (80, 183):
        return FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST))
    if number in (2, 3):
        return FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT))
    if number == 17:
        return OSError(errno.EXDEV, os.strerror(errno.EXDEV))
    if number == 5:
        return PermissionError(errno.EACCES, os.strerror(errno.EACCES))
    if number in (32, 33):
        return BlockingIOError(errno.EBUSY, os.strerror(errno.EBUSY))
    if number == 112:
        return OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
    if number == 206:
        return OSError(errno.ENAMETOOLONG, os.strerror(errno.ENAMETOOLONG))
    if number in (87, 123):
        return OSError(errno.EINVAL, os.strerror(errno.EINVAL))
    if number in (1, 50, 120):
        return _unsupported()
    return OSError(errno.EIO, os.strerror(errno.EIO))


def _windows_move_file_ex() -> Any:
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    except (AttributeError, OSError) as exc:
        raise _unsupported() from exc
    try:
        function = kernel32.MoveFileExW
    except AttributeError as exc:
        raise _unsupported() from exc
    function.argtypes = (ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    return function


def _set_windows_last_error(number: int) -> None:
    setter = getattr(ctypes, "set_last_error", None)
    if setter is None:
        raise _unsupported()
    setter(number)


def _windows_last_error() -> int:
    getter = getattr(ctypes, "get_last_error", None)
    if getter is None:
        raise _unsupported()
    return int(getter())


def _windows_move_noreplace(source: str | bytes, destination: str | bytes) -> None:
    function = _windows_move_file_ex()
    _set_windows_last_error(0)
    result = function(
        os.fsdecode(source),
        os.fsdecode(destination),
        _MOVEFILE_WRITE_THROUGH,
    )
    if not result:
        raise _mapped_windows_error(_windows_last_error())


def _path_value(value: Any) -> str | bytes:
    path = os.fspath(value)
    if not isinstance(path, (str, bytes)) or not path:
        raise TypeError("path must be a non-empty str, bytes, or path-like value")
    if b"\x00" in path if isinstance(path, bytes) else "\x00" in path:
        raise ValueError("embedded null byte")
    return path


def _dirfd_name(value: str | bytes) -> bool:
    dot = b"." if isinstance(value, bytes) else "."
    dotdot = b".." if isinstance(value, bytes) else ".."
    if value in (dot, dotdot) or os.path.isabs(value):
        return False
    return os.path.dirname(value) in (b"" if isinstance(value, bytes) else "", dot)


def _same_parent(source: str | bytes, destination: str | bytes) -> bool:
    if isinstance(source, bytes) != isinstance(destination, bytes):
        return False
    source_parent = os.path.normcase(os.path.abspath(os.path.dirname(source)))
    destination_parent = os.path.normcase(os.path.abspath(os.path.dirname(destination)))
    return source_parent == destination_parent


def _platform_family() -> str:
    if sys.platform == "win32":
        return "windows" if os.name == "nt" else "unsupported"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    return "unsupported"


def _native_call(
    function: Any,
    source_fd: int,
    source: str | bytes,
    destination_fd: int,
    destination: str | bytes,
    flag: int,
) -> None:
    function.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(
        source_fd,
        os.fsencode(source),
        destination_fd,
        os.fsencode(destination),
        flag,
    )
    if result != 0:
        number = ctypes.get_errno()
        if number in (errno.EINVAL, getattr(errno, "ENOSYS", -1)):
            raise _unsupported()
        raise _mapped_error(number)


def require_atomic_rename_noreplace_support() -> None:
    """Fail unless this host exposes the required native move primitive."""

    family = _platform_family()
    if family == "unsupported":
        raise _unsupported()
    if family == "windows":
        _windows_move_file_ex()
        return
    if (
        getattr(os, "O_DIRECTORY", None) is None
        or getattr(os, "O_NOFOLLOW", None) is None
    ):
        raise _unsupported()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
    except OSError as exc:
        raise _unsupported() from exc
    symbol = "renameat2" if family == "linux" else "renameatx_np"
    if not hasattr(libc, symbol):
        raise _unsupported()


def atomic_rename_noreplace(
    source: Any,
    destination: Any,
    *,
    dir_fd: int | None = None,
) -> None:
    """Move ``source`` to ``destination`` atomically without overwriting.

    The two names must be siblings.  No copy, unlink, restore, or overwrite
    fallback exists: when the host lacks a safe native primitive, the call
    fails closed.
    """

    source_path = _path_value(source)
    destination_path = _path_value(destination)
    if isinstance(source_path, bytes) != isinstance(destination_path, bytes):
        raise TypeError("source and destination path types must match")

    family = _platform_family()
    if family == "unsupported":
        raise _unsupported()

    close_fd: int | None = None
    if dir_fd is not None:
        if (
            isinstance(dir_fd, bool)
            or not isinstance(dir_fd, int)
            or dir_fd < 0
            or not _dirfd_name(source_path)
            or not _dirfd_name(destination_path)
        ):
            raise _invalid_parent()
        source_fd = destination_fd = dir_fd
    else:
        if not _same_parent(source_path, destination_path):
            raise _invalid_parent()
        if family == "windows":
            source_fd = destination_fd = -1
        else:
            parent = os.path.dirname(os.path.abspath(source_path))
            directory = getattr(os, "O_DIRECTORY", None)
            nofollow = getattr(os, "O_NOFOLLOW", None)
            if directory is None or nofollow is None:
                raise _unsupported()
            try:
                close_fd = os.open(
                    parent,
                    os.O_RDONLY | directory | nofollow | getattr(os, "O_CLOEXEC", 0),
                )
            except OSError as exc:
                raise _mapped_error(exc.errno or errno.EIO) from exc
            source_fd = destination_fd = close_fd
            source_path = os.path.basename(source_path)
            destination_path = os.path.basename(destination_path)

    if family == "windows":
        if dir_fd is not None:
            raise _unsupported()
        _windows_move_noreplace(source_path, destination_path)
        return

    try:
        try:
            libc = ctypes.CDLL(None, use_errno=True)
        except OSError as exc:
            raise _unsupported() from exc
        if family == "linux":
            if not hasattr(libc, "renameat2"):
                raise _unsupported()
            _native_call(
                libc.renameat2,
                source_fd,
                source_path,
                destination_fd,
                destination_path,
                _RENAME_NOREPLACE,
            )
        else:
            if not hasattr(libc, "renameatx_np"):
                raise _unsupported()
            _native_call(
                libc.renameatx_np,
                source_fd,
                source_path,
                destination_fd,
                destination_path,
                _RENAME_EXCL,
            )
    except BaseException:
        if close_fd is not None:
            try:
                os.close(close_fd)
            except OSError:
                pass
        raise
    if close_fd is not None:
        try:
            os.close(close_fd)
        except OSError as exc:
            raise _mapped_error(exc.errno or errno.EIO) from exc


__all__ = ["atomic_rename_noreplace", "require_atomic_rename_noreplace_support"]
