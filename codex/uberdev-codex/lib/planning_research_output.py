#!/usr/bin/env python3
"""Validate and atomically publish planning-research artifacts."""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import secrets
import stat
import sys
from pathlib import Path


ALLOWED_BASENAMES = frozenset(
    {
        "dependency-map.md",
        "test-map.md",
        "implementation-risk.md",
        "planning-security.md",
    }
)
READABLE_BITS = stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH
PRIVATE_MODE = stat.S_IRUSR | stat.S_IWUSR
TOKEN_LENGTH = 32
CAPABILITY_VERSION = "v1"


class ValidationFailure(Exception):
    """A stable, machine-readable validation failure."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class JsonArgumentParser(argparse.ArgumentParser):
    """Keep command-line failures on the same strict JSON channel."""

    def error(self, message: str) -> None:
        del message
        _emit(_invalid("arguments", "arguments"))
        raise SystemExit(2)


def _emit(payload: dict[str, object]) -> None:
    sys.stdout.write(
        json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    )
    sys.stdout.flush()


def _invalid(key: str, reason: str) -> dict[str, object]:
    return {
        "key": key,
        "output_path": "",
        "reason": reason,
        "status": "invalid",
    }


def _fail(reason: str) -> None:
    raise ValidationFailure(reason)


def _require(args: argparse.Namespace, *names: str) -> None:
    if any(getattr(args, name, None) is None for name in names):
        _fail("arguments")


def _resolve_summary(summary_text: str) -> Path:
    summary_input = Path(summary_text)
    if not summary_input.is_absolute():
        _fail("absolute")
    try:
        summary = summary_input.resolve(strict=True)
    except (OSError, RuntimeError):
        _fail("canonicalize")
    if not summary.is_dir():
        _fail("canonicalize")
    return summary


def _open_summary(summary: Path) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory is None:
        _fail("platform_safety")
    try:
        return os.open(summary, os.O_RDONLY | directory | nofollow)
    except OSError:
        _fail("canonicalize")


def _validate_basename(expected: str) -> None:
    if expected not in ALLOWED_BASENAMES:
        _fail("wrong_basename")


def _target_context(
    summary_text: str, output_text: str, expected: str
) -> tuple[Path, Path]:
    if not Path(output_text).is_absolute():
        _fail("absolute")
    _validate_basename(expected)
    output = Path(output_text)
    if output.name != expected:
        _fail("wrong_basename")
    summary = _resolve_summary(summary_text)
    try:
        parent = output.parent.resolve(strict=True)
    except (OSError, RuntimeError):
        _fail("canonicalize")
    if parent != summary:
        _fail("run_dir_confinement")
    return summary, output


def _validate_existing_target(
    summary: Path, output: Path, expected: str, mode: str
) -> None:
    if os.path.lexists(output) and output.is_symlink():
        _fail("run_dir_confinement")

    exists = output.exists()
    output_stat = None
    if exists:
        try:
            resolved_output = output.resolve(strict=True)
        except (OSError, RuntimeError):
            _fail("canonicalize")
        if resolved_output != summary / expected:
            _fail("run_dir_confinement")
        try:
            output_stat = output.stat()
            siblings = tuple(summary.iterdir())
        except OSError:
            _fail("canonicalize")
        if not stat.S_ISREG(output_stat.st_mode):
            _fail("output_type")
        if output_stat.st_nlink > 1:
            _fail("hardlink_alias")
        output_inode = (output_stat.st_dev, output_stat.st_ino)
        for sibling in siblings:
            if sibling.name == expected:
                continue
            try:
                sibling_stat = sibling.lstat()
            except OSError:
                _fail("canonicalize")
            if stat.S_ISREG(sibling_stat.st_mode) and (
                sibling_stat.st_dev,
                sibling_stat.st_ino,
            ) == output_inode:
                _fail("hardlink_alias")
    elif mode == "postwrite":
        _fail("missing")

    if mode == "postwrite":
        if output_stat is None:
            _fail("missing")
        if not output_stat.st_mode & READABLE_BITS or not os.access(output, os.R_OK):
            _fail("unreadable")


def _validate(args: argparse.Namespace) -> dict[str, object]:
    _require(args, "mode", "summary_dir", "output_path", "expected_basename")
    if args.mode not in ("prewrite", "postwrite"):
        _fail("arguments")
    summary, output = _target_context(
        args.summary_dir, args.output_path, args.expected_basename
    )
    _validate_existing_target(summary, output, args.expected_basename, args.mode)
    return {"output_path": args.output_path, "status": "valid"}


def _private_name(expected: str, purpose: str) -> str:
    return f".{expected}.{purpose}-{secrets.token_hex(TOKEN_LENGTH // 2)}"


def _create_private(dir_fd: int, expected: str, purpose: str) -> tuple[str, int]:
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        _fail("platform_safety")
    flags |= nofollow
    for _ in range(128):
        name = _private_name(expected, purpose)
        try:
            fd = os.open(name, flags, PRIVATE_MODE, dir_fd=dir_fd)
        except FileExistsError:
            continue
        except OSError:
            _fail("io")
        try:
            # os.open applies the caller's umask. Restore the invariant after
            # creation so even a restrictive ambient umask cannot produce an
            # unreadable staging file or final publication.
            os.fchmod(fd, PRIVATE_MODE)
        except OSError:
            os.close(fd)
            try:
                os.unlink(name, dir_fd=dir_fd)
            except OSError:
                pass
            _fail("io")
        return name, fd
    _fail("name_exhausted")


def _fsync_directory(dir_fd: int) -> None:
    try:
        os.fsync(dir_fd)
    except OSError:
        # Some otherwise-safe filesystems do not support directory fsync.
        pass


def _atomic_rename_noreplace(
    dir_fd: int, source_name: str, destination_name: str
) -> None:
    """Atomically rename one dirfd-relative entry without overwriting data."""

    libc = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(source_name)
    destination = os.fsencode(destination_name)
    ctypes.set_errno(0)

    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        rename_call = libc.renameatx_np
        rename_call.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        rename_call.restype = ctypes.c_int
        result = rename_call(dir_fd, source, dir_fd, destination, 0x00000004)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename_call = libc.renameat2
        rename_call.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        rename_call.restype = ctypes.c_int
        result = rename_call(dir_fd, source, dir_fd, destination, 0x00000001)
    else:
        _fail("platform_safety")

    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise FileExistsError(error_number, os.strerror(error_number))
    if error_number == errno.ENOENT:
        raise FileNotFoundError(error_number, os.strerror(error_number))
    raise OSError(error_number, os.strerror(error_number))


def _allocate(args: argparse.Namespace) -> dict[str, object]:
    _require(args, "summary_dir", "expected_basename")
    _validate_basename(args.expected_basename)
    summary = _resolve_summary(args.summary_dir)
    dir_fd = _open_summary(summary)
    staging_fd = None
    staging_name = None
    allocated = False
    try:
        staging_name, staging_fd = _create_private(
            dir_fd, args.expected_basename, "stage"
        )
        staging_stat = os.fstat(staging_fd)
        os.fsync(staging_fd)
        os.close(staging_fd)
        staging_fd = None
        _fsync_directory(dir_fd)
        allocated = True
    finally:
        if staging_fd is not None:
            os.close(staging_fd)
        if not allocated and staging_name is not None:
            try:
                os.unlink(staging_name, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
        os.close(dir_fd)
    if staging_name is None:
        _fail("io")
    return {
        "allocation_token": _allocation_token(
            staging_name, args.expected_basename, staging_stat
        ),
        "staging_path": str(summary / staging_name),
        "status": "allocated",
    }


def _validate_staging_name(staging: Path, expected: str) -> str:
    prefix = f".{expected}.stage-"
    name = staging.name
    token = name[len(prefix) :] if name.startswith(prefix) else ""
    if (
        len(token) != TOKEN_LENGTH
        or any(character not in "0123456789abcdef" for character in token)
    ):
        _fail("staging_name")
    return name


def _staging_nonce(staging_name: str, expected: str) -> str:
    prefix = f".{expected}.stage-"
    return staging_name[len(prefix) :]


def _allocation_token(
    staging_name: str, expected: str, staging_stat: os.stat_result
) -> str:
    nonce = _staging_nonce(staging_name, expected)
    return (
        f"{CAPABILITY_VERSION}:{staging_stat.st_dev:x}:"
        f"{staging_stat.st_ino:x}:{nonce}"
    )


def _parse_allocation_token(
    raw_token: str, staging_name: str, expected: str
) -> tuple[int, int]:
    parts = raw_token.split(":")
    if len(parts) != 4 or parts[0] != CAPABILITY_VERSION:
        _fail("allocation_token")
    dev_text, inode_text, nonce = parts[1:]
    if (
        not dev_text
        or not inode_text
        or any(character not in "0123456789abcdef" for character in dev_text)
        or any(character not in "0123456789abcdef" for character in inode_text)
        or nonce != _staging_nonce(staging_name, expected)
    ):
        _fail("allocation_token")
    try:
        expected_dev = int(dev_text, 16)
        expected_inode = int(inode_text, 16)
    except ValueError:
        _fail("allocation_token")
    if f"{expected_dev:x}" != dev_text or f"{expected_inode:x}" != inode_text:
        _fail("allocation_token")
    return expected_dev, expected_inode


def _allocated_staging_context(
    summary_text: str,
    staging_text: str,
    expected: str,
    allocation_token: str,
) -> tuple[Path, str, tuple[int, int]]:
    _validate_basename(expected)
    summary = _resolve_summary(summary_text)
    staging = Path(staging_text)
    if not staging.is_absolute():
        _fail("absolute")
    try:
        staging_parent = staging.parent.resolve(strict=True)
    except (OSError, RuntimeError):
        _fail("canonicalize")
    if staging_parent != summary:
        _fail("run_dir_confinement")
    staging_name = _validate_staging_name(staging, expected)
    allocation_inode = _parse_allocation_token(
        allocation_token, staging_name, expected
    )
    return summary, staging_name, allocation_inode


def _owned_staging_state(
    dir_fd: int, staging_name: str, allocation_inode: tuple[int, int]
) -> str:
    try:
        entry = os.stat(staging_name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "absent"
    except OSError:
        _fail("cleanup_failed")
    if (entry.st_dev, entry.st_ino) != allocation_inode:
        return "mismatch"
    return "owned"


def _unlink_owned_staging(
    dir_fd: int,
    staging_name: str,
    allocation_inode: tuple[int, int],
    expected: str,
) -> str:
    quarantine_name = None
    for _ in range(128):
        candidate = _private_name(expected, "quarantine")
        try:
            _atomic_rename_noreplace(dir_fd, staging_name, candidate)
        except FileExistsError:
            continue
        except FileNotFoundError:
            return "absent"
        except OSError:
            _fail("cleanup_failed")
        quarantine_name = candidate
        break
    if quarantine_name is None:
        _fail("name_exhausted")

    _fsync_directory(dir_fd)
    try:
        quarantined = os.stat(
            quarantine_name, dir_fd=dir_fd, follow_symlinks=False
        )
    except OSError:
        _fail("cleanup_failed")

    quarantine_inode = (quarantined.st_dev, quarantined.st_ino)
    opened_inode = None
    if stat.S_ISREG(quarantined.st_mode):
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if nofollow is None:
            _fail("platform_safety")
        quarantine_fd = None
        try:
            quarantine_fd = os.open(
                quarantine_name, os.O_RDONLY | nofollow, dir_fd=dir_fd
            )
            opened = os.fstat(quarantine_fd)
            opened_inode = (opened.st_dev, opened.st_ino)
        except PermissionError:
            # The inode capability plus private quarantine name still makes
            # disposal safe for an owned mode-000 staging entry.
            opened_inode = quarantine_inode
        except OSError:
            opened_inode = None
        finally:
            if quarantine_fd is not None:
                os.close(quarantine_fd)

    owned = (
        quarantine_inode == allocation_inode
        and opened_inode == allocation_inode
        and stat.S_ISREG(quarantined.st_mode)
        and quarantined.st_nlink >= 1
    )
    if owned:
        try:
            os.unlink(quarantine_name, dir_fd=dir_fd)
        except OSError:
            _fail("cleanup_failed")
        _fsync_directory(dir_fd)
        return "removed"

    restored = False
    if stat.S_ISREG(quarantined.st_mode):
        try:
            os.link(
                quarantine_name,
                staging_name,
                src_dir_fd=dir_fd,
                dst_dir_fd=dir_fd,
                follow_symlinks=False,
            )
            restored = True
        except OSError:
            restored = False
    elif stat.S_ISLNK(quarantined.st_mode):
        try:
            target = os.readlink(quarantine_name, dir_fd=dir_fd)
            os.symlink(target, staging_name, dir_fd=dir_fd)
            restored = True
        except OSError:
            restored = False

    if restored:
        try:
            os.unlink(quarantine_name, dir_fd=dir_fd)
        except OSError:
            # Both names now preserve the replacement; retain quarantine and
            # report the controlled mismatch instead of deleting either.
            return "mismatch_quarantined"
        _fsync_directory(dir_fd)
        return "mismatch"

    # Restoration was unsafe (unsupported type or destination collision).
    # Retain the high-entropy quarantine entry and fail closed without
    # exposing its name on the normal JSON channel.
    _fsync_directory(dir_fd)
    return "mismatch_quarantined"


def _copy_all(source_fd: int, destination_fd: int) -> None:
    while True:
        chunk = os.read(source_fd, 1024 * 1024)
        if not chunk:
            return
        offset = 0
        while offset < len(chunk):
            written = os.write(destination_fd, chunk[offset:])
            if written <= 0:
                _fail("io")
            offset += written


def _publish(args: argparse.Namespace) -> dict[str, object]:
    _require(
        args,
        "summary_dir",
        "output_path",
        "expected_basename",
        "staging_path",
        "allocation_token",
    )
    summary, staging_name, allocation_inode = _allocated_staging_context(
        args.summary_dir,
        args.staging_path,
        args.expected_basename,
        args.allocation_token,
    )
    dir_fd = _open_summary(summary)
    source_fd = None
    private_fd = None
    private_name = None
    try:
        state = _owned_staging_state(dir_fd, staging_name, allocation_inode)
        if state == "absent":
            _fail("staging_invalid")
        if state == "mismatch":
            _fail("allocation_mismatch")

        target_summary, output = _target_context(
            args.summary_dir, args.output_path, args.expected_basename
        )
        if target_summary != summary:
            _fail("run_dir_confinement")

        nofollow = getattr(os, "O_NOFOLLOW", None)
        if nofollow is None:
            _fail("platform_safety")
        try:
            source_fd = os.open(staging_name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
            staging_stat = os.fstat(source_fd)
            staging_entry = os.stat(
                staging_name, dir_fd=dir_fd, follow_symlinks=False
            )
        except OSError:
            _fail("staging_invalid")
        if (staging_stat.st_dev, staging_stat.st_ino) != allocation_inode:
            _fail("allocation_mismatch")
        if not stat.S_ISREG(staging_stat.st_mode):
            _fail("output_type")
        if staging_stat.st_nlink != 1:
            _fail("hardlink_alias")
        if stat.S_IMODE(staging_stat.st_mode) != PRIVATE_MODE:
            _fail("staging_mode")
        if not staging_stat.st_mode & READABLE_BITS:
            _fail("unreadable")
        if (staging_stat.st_dev, staging_stat.st_ino) != (
            staging_entry.st_dev,
            staging_entry.st_ino,
        ):
            _fail("staging_race")

        try:
            current_target = os.stat(
                args.expected_basename, dir_fd=dir_fd, follow_symlinks=False
            )
        except FileNotFoundError:
            current_target = None
        except OSError:
            _fail("io")
        if current_target is not None and stat.S_ISDIR(current_target.st_mode):
            _fail("output_type")

        # Unlink only after the open descriptor and directory entry are proven
        # to identify the same single-link file. The descriptor remains readable.
        if _unlink_owned_staging(
            dir_fd, staging_name, allocation_inode, args.expected_basename
        ) != "removed":
            _fail("staging_race")

        private_name, private_fd = _create_private(
            dir_fd, args.expected_basename, "publish"
        )
        _copy_all(source_fd, private_fd)
        os.fsync(private_fd)
        private_stat = os.fstat(private_fd)
        os.close(private_fd)
        private_fd = None

        # Replaces only this directory entry. A target swapped to a symlink or
        # hard link is unlinked; its referent/inode is never opened or mutated.
        try:
            os.replace(
                private_name,
                args.expected_basename,
                src_dir_fd=dir_fd,
                dst_dir_fd=dir_fd,
            )
        except OSError:
            _fail("publish_replace")
        private_name = None
        _fsync_directory(dir_fd)

        try:
            published = os.stat(
                args.expected_basename, dir_fd=dir_fd, follow_symlinks=False
            )
        except OSError:
            _fail("publish_verify")
        if (
            not stat.S_ISREG(published.st_mode)
            or published.st_nlink != 1
            or stat.S_IMODE(published.st_mode) != PRIVATE_MODE
            or published.st_size != staging_stat.st_size
            or (published.st_dev, published.st_ino)
            != (private_stat.st_dev, private_stat.st_ino)
        ):
            _fail("publish_verify")
    finally:
        if source_fd is not None:
            os.close(source_fd)
        if private_fd is not None:
            os.close(private_fd)
        if private_name is not None:
            try:
                os.unlink(private_name, dir_fd=dir_fd)
            except OSError:
                pass
        # Cleanup is capability-bound. Owned entries are removed on every
        # exit; an attacker-swapped inode or symlink is deliberately preserved.
        try:
            _unlink_owned_staging(
                dir_fd,
                staging_name,
                allocation_inode,
                args.expected_basename,
            )
        finally:
            os.close(dir_fd)

    return {
        "output_path": args.output_path,
        "staging_path": "",
        "status": "published",
    }


def _abort(args: argparse.Namespace) -> dict[str, object]:
    _require(
        args,
        "summary_dir",
        "expected_basename",
        "staging_path",
        "allocation_token",
    )
    summary, staging_name, allocation_inode = _allocated_staging_context(
        args.summary_dir,
        args.staging_path,
        args.expected_basename,
        args.allocation_token,
    )
    dir_fd = _open_summary(summary)
    try:
        state = _unlink_owned_staging(
            dir_fd, staging_name, allocation_inode, args.expected_basename
        )
        if state.startswith("mismatch"):
            _fail("allocation_mismatch")
    finally:
        os.close(dir_fd)
    return {"staging_path": "", "status": "aborted"}


def _parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument(
        "--operation",
        choices=("validate", "allocate", "abort", "publish"),
        required=True,
    )
    parser.add_argument("--mode", choices=("prewrite", "postwrite"))
    parser.add_argument("--summary-dir")
    parser.add_argument("--output-path")
    parser.add_argument("--expected-basename")
    parser.add_argument("--staging-path")
    parser.add_argument("--allocation-token")
    parser.add_argument("--key", default="output_path")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.operation == "validate":
            payload = _validate(args)
        elif args.operation == "allocate":
            payload = _allocate(args)
        elif args.operation == "abort":
            payload = _abort(args)
        else:
            payload = _publish(args)
    except ValidationFailure as exc:
        _emit(_invalid(args.key, exc.reason))
        return 2
    except Exception:
        _emit(_invalid(args.key, "io"))
        return 2

    _emit(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
