#!/usr/bin/env python3
"""Validate one managed path without following links or reparse points."""

from __future__ import annotations

import argparse
import ntpath
import os
import pathlib
import stat
import sys
from typing import Callable


REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
VALID_KINDS = frozenset(
    {
        "tree",
        "file",
        "required-tree",
        "required-file",
        "optional-sealed-tree",
        "sealed-tree",
    }
)
WINDOWS_RESERVED_STEMS = frozenset(
    {"CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"}
    | {f"COM{number}" for number in range(1, 10)}
    | {f"LPT{number}" for number in range(1, 10)}
    | {f"COM{number}" for number in "¹²³"}
    | {f"LPT{number}" for number in "¹²³"}
)
WINDOWS_ILLEGAL_CHARS = frozenset('<>:"/\\|?*')


class GuardError(ValueError):
    """The requested managed path is not safely contained by its root."""


def _is_link_or_reparse(metadata: os.stat_result) -> bool:
    attributes = getattr(metadata, "st_file_attributes", 0)
    return stat.S_ISLNK(metadata.st_mode) or bool(attributes & REPARSE_POINT)


def _lstat_or_none(
    path: pathlib.Path,
    lstat_fn: Callable[[os.PathLike[str]], os.stat_result],
) -> os.stat_result | None:
    try:
        return lstat_fn(path)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise GuardError(f"cannot lstat managed path component {path}: {exc}") from exc


def _relative_parts(relative: str | os.PathLike[str]) -> tuple[str, ...]:
    raw = os.fspath(relative)
    if not isinstance(raw, str):
        raise GuardError("managed relative path must be text")
    if not raw or "\0" in raw:
        raise GuardError("managed relative path is empty or contains NUL")
    if "\\" in raw:
        raise GuardError(f"managed relative path contains a backslash: {raw!r}")
    drive, _ = ntpath.splitdrive(raw)
    if drive or raw.startswith("/"):
        raise GuardError(f"managed path must be relative, not drive/UNC/absolute: {raw!r}")
    parts = tuple(raw.split("/"))
    if any(part in {"", ".", ".."} for part in parts):
        raise GuardError(f"managed relative path has an unsafe component: {raw!r}")
    is_reserved = getattr(ntpath, "isreserved", None)
    for part in parts:
        # Python 3.13+ knows the complete platform rule set. The explicit
        # fallback keeps the security contract on Python 3.10-3.12.
        stem = part.split(".", 1)[0].rstrip(" .").upper()
        fallback_reserved = (
            any(ord(character) < 32 for character in part)
            or any(character in WINDOWS_ILLEGAL_CHARS for character in part)
            or part.endswith((" ", "."))
            or stem in WINDOWS_RESERVED_STEMS
        )
        if fallback_reserved or (is_reserved is not None and is_reserved(part)):
            raise GuardError(f"managed path has a Windows-reserved component: {part!r}")
    return parts


def _validate_sealed_tree(
    tree: pathlib.Path,
    lstat_fn: Callable[[os.PathLike[str]], os.stat_result],
) -> None:
    """Reject every link/reparse/special descendant without following it."""

    pending = [tree]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    path = pathlib.Path(entry.path)
                    metadata = _lstat_or_none(path, lstat_fn)
                    if metadata is None:
                        raise GuardError(f"managed tree entry vanished during scan: {path}")
                    if _is_link_or_reparse(metadata):
                        raise GuardError(
                            f"managed tree contains a link or reparse point: {path}"
                        )
                    if stat.S_ISDIR(metadata.st_mode):
                        pending.append(path)
                    elif not stat.S_ISREG(metadata.st_mode):
                        raise GuardError(
                            f"managed tree contains a special/non-regular entry: {path}"
                        )
        except GuardError:
            raise
        except OSError as exc:
            raise GuardError(f"cannot scan managed tree {directory}: {exc}") from exc


def validate_managed_path(
    root: str | os.PathLike[str],
    relative: str | os.PathLike[str],
    kind: str,
    *,
    lstat_fn: Callable[[os.PathLike[str]], os.stat_result] = os.lstat,
) -> None:
    """Raise GuardError unless relative has the requested shape beneath root.

    ``tree``, ``file``, and ``optional-sealed-tree`` allow an absent final path.
    ``required-tree`` and ``required-file`` require it to exist with the named
    shape. Both sealed-tree kinds reject every existing descendant that is not
    a real directory or regular file. Every existing component (including root
    itself) must be neither a symbolic link nor a Windows junction/reparse point.
    """

    if kind not in VALID_KINDS:
        raise GuardError(f"unknown managed path kind: {kind!r}")

    root_path = pathlib.Path(root)
    if not root_path.is_absolute():
        raise GuardError(f"managed root must be absolute: {root_path}")
    root_metadata = _lstat_or_none(root_path, lstat_fn)
    if root_metadata is None:
        raise GuardError(f"managed root does not exist: {root_path}")
    if _is_link_or_reparse(root_metadata):
        raise GuardError(f"managed root is a link or reparse point: {root_path}")
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise GuardError(f"managed root is not a directory: {root_path}")

    parts = _relative_parts(relative)
    current = root_path
    for index, component in enumerate(parts):
        current /= component
        metadata = _lstat_or_none(current, lstat_fn)
        final = index == len(parts) - 1
        if metadata is None:
            if kind in {"required-tree", "required-file", "sealed-tree"}:
                raise GuardError(f"required managed path is missing: {relative}")
            return
        if _is_link_or_reparse(metadata):
            raise GuardError(f"managed component is a link or reparse point: {current}")
        if not final:
            if not stat.S_ISDIR(metadata.st_mode):
                raise GuardError(f"managed parent is not a directory: {current}")
            continue
        if kind in {
            "tree",
            "required-tree",
            "optional-sealed-tree",
            "sealed-tree",
        }:
            if not stat.S_ISDIR(metadata.st_mode):
                raise GuardError(f"managed tree is not a directory: {current}")
        elif not stat.S_ISREG(metadata.st_mode):
            raise GuardError(f"managed file is not regular: {current}")

    if kind in {"optional-sealed-tree", "sealed-tree"}:
        _validate_sealed_tree(current, lstat_fn)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("relative")
    parser.add_argument("kind", choices=sorted(VALID_KINDS))
    args = parser.parse_args(argv)
    try:
        validate_managed_path(args.root, args.relative, args.kind)
    except GuardError as exc:
        print(f"managed-path-guard: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
