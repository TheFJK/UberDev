#!/usr/bin/env python3
"""Native-Windows coverage for the code-fixer observational index lock."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile


if os.name != "nt":
    raise SystemExit("code-fixer-contract-windows requires native Windows")


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "plugins/uberdev/lib/code_fixer_contract.py"
SPEC = importlib.util.spec_from_file_location("code_fixer_contract_windows", HELPER)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


def git(repository: pathlib.Path, *arguments: str, check: bool = True):
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        capture_output=True,
        check=check,
    )


def expect_reason(callback, expected: str) -> None:
    try:
        callback()
    except module.ContractFailure as error:
        assert str(error) == expected, (str(error), expected)
    else:
        raise AssertionError(f"expected ContractFailure({expected})")


with tempfile.TemporaryDirectory(prefix="code-fixer-contract-windows-") as temporary:
    repository = pathlib.Path(temporary) / "repo"
    repository.mkdir()
    git(repository, "init", "-q")
    git(repository, "config", "user.email", "fixture@example.invalid")
    git(repository, "config", "user.name", "Fixture")
    git(repository, "config", "diff.autoRefreshIndex", "true")
    tracked = repository / "tracked.txt"
    tracked.write_bytes(b"baseline\n")
    git(repository, "add", "--", tracked.name)
    git(repository, "commit", "-qm", "test: native Windows lock fixture")

    rendered_index = git(
        repository, "rev-parse", "--git-path", "index"
    ).stdout.decode("utf-8").strip()
    index_path = pathlib.Path(rendered_index)
    if not index_path.is_absolute():
        index_path = repository / index_path
    index_path = index_path.resolve()
    index_lock_path = pathlib.Path(f"{index_path}.lock")
    commands = (("diff", "--name-status", "-z", "--no-renames", "--"),)

    tracked_stat = tracked.stat()
    os.utime(
        tracked,
        ns=(tracked_stat.st_atime_ns, tracked_stat.st_mtime_ns + 2_000_000_000),
    )
    assert tracked.read_bytes() == git(repository, "show", ":tracked.txt").stdout
    raw_index = index_path.read_bytes()
    (observed,) = module._observe_worktree_with_index_lock(
        str(repository), commands
    )
    assert observed.returncode == 0
    assert observed.stdout == b""
    assert index_path.read_bytes() == raw_index
    assert not index_lock_path.exists()

    original_capture_regular = module._capture_regular

    def interrupt_acquisition_capture(path, minimum, maximum):
        if index_lock_path.exists():
            raise KeyboardInterrupt("injected acquisition interrupt")
        return original_capture_regular(path, minimum, maximum)

    module._capture_regular = interrupt_acquisition_capture
    try:
        try:
            module._observe_worktree_with_index_lock(str(repository), commands)
        except KeyboardInterrupt as error:
            assert str(error) == "injected acquisition interrupt"
        else:
            raise AssertionError("acquisition KeyboardInterrupt was swallowed")
    finally:
        module._capture_regular = original_capture_regular
    assert index_path.read_bytes() == raw_index
    assert not index_lock_path.exists(), (
        f"acquisition KeyboardInterrupt left stale lock: {index_lock_path}"
    )

    release_capture_calls = {"count": 0}

    def interrupt_release_capture(path, minimum, maximum):
        if index_lock_path.exists():
            release_capture_calls["count"] += 1
            if release_capture_calls["count"] == 2:
                raise SystemExit("injected release interrupt")
        return original_capture_regular(path, minimum, maximum)

    module._capture_regular = interrupt_release_capture
    try:
        try:
            module._observe_worktree_with_index_lock(str(repository), commands)
        except SystemExit as error:
            assert str(error) == "injected release interrupt"
        else:
            raise AssertionError("release SystemExit was swallowed")
    finally:
        module._capture_regular = original_capture_regular
    assert release_capture_calls["count"] == 2
    assert index_path.read_bytes() == raw_index
    assert not index_lock_path.exists(), (
        f"release SystemExit left stale lock: {index_lock_path}"
    )

    foreign_lock = b"foreign-index-lock\n"
    index_lock_path.write_bytes(foreign_lock)
    expect_reason(
        lambda: module._observe_worktree_with_index_lock(
            str(repository), commands
        ),
        "index_observation_lock_unavailable",
    )
    assert index_lock_path.read_bytes() == foreign_lock
    assert index_path.read_bytes() == raw_index
    index_lock_path.unlink()

    replacement = index_path.parent / "replacement-index-lock"
    replacement_payload = b"replacement-must-survive\n"
    original_run = module._run_observational_git
    replacement_denied: list[bool] = []

    def attempt_replacement(repository_path: str, *arguments: str):
        replacement.write_bytes(replacement_payload)
        try:
            os.replace(replacement, index_lock_path)
        except OSError:
            replacement_denied.append(True)
        else:
            replacement_denied.append(False)
        return original_run(repository_path, *arguments)

    module._run_observational_git = attempt_replacement
    try:
        (observed,) = module._observe_worktree_with_index_lock(
            str(repository), commands
        )
    finally:
        module._run_observational_git = original_run
    assert observed.returncode == 0
    assert observed.stdout == b""
    assert replacement_denied == [True]
    assert replacement.read_bytes() == replacement_payload
    replacement.unlink()
    assert index_path.read_bytes() == raw_index
    assert not index_lock_path.exists()

    tracked.write_bytes(b"intentional-index-write\n")
    git(repository, "add", "--", tracked.name)
    assert git(repository, "diff", "--cached", "--quiet", check=False).returncode == 1
    assert not index_lock_path.exists()

print("code-fixer-contract-windows: native index-lock lifecycle passed")
