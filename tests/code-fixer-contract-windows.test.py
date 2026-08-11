#!/usr/bin/env python3
"""Native-Windows coverage for the code-fixer observational index lock."""

from __future__ import annotations

import contextlib
import importlib.util
import os
import pathlib
import shutil
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


@contextlib.contextmanager
def scratch_dir(prefix: str):
    """Scratch tree whose teardown cannot decide this file's exit status.

    Deliberate copy of the factory in tests/code-fixer-contract.test.sh: this
    is a standalone program and cannot import from that file's heredoc. Both
    copies are locked by the S1-S4 guard in the .sh, which scans this file's
    text. Rationale, tradeoff and the 3.10+/no-`setup-python` constraint are
    documented there (issue #428, run 31369242976). Teardown-on-open-handles
    fails far more readily on native Windows, which is the only platform this
    file runs on.
    """
    path = tempfile.mkdtemp(prefix=prefix)
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


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


with scratch_dir("code-fixer-contract-windows-") as temporary:
    repository = pathlib.Path(temporary) / "repo with spaces ü"
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

    raw_index = index_path.read_bytes()
    expected_tree = git(
        repository, "rev-parse", "HEAD^{tree}"
    ).stdout.decode("ascii").strip()
    assert module._index_tree_sha(str(repository)) == expected_tree
    assert index_path.read_bytes() == raw_index
    assert not tuple(index_path.parent.glob(".code-fixer-private-git-*"))

    previous_ambient_index = os.environ.get("GIT_INDEX_FILE")
    os.environ["GIT_INDEX_FILE"] = str(index_path)
    try:
        expect_reason(
            lambda: module._index_tree_sha(str(repository)),
            "index_tree_environment_invalid",
        )
    finally:
        if previous_ambient_index is None:
            os.environ.pop("GIT_INDEX_FILE", None)
        else:
            os.environ["GIT_INDEX_FILE"] = previous_ambient_index

    alternate_index = index_path.parent / "alternate index ü"
    alternate_index.write_bytes(raw_index)
    assert module._index_tree_sha(
        str(repository), extra_env={"GIT_INDEX_FILE": str(alternate_index)}
    ) == expected_tree
    assert alternate_index.read_bytes() == raw_index
    alternate_index.unlink()

    hardlink_index = index_path.parent / "alternate index hardlink"
    os.link(index_path, hardlink_index)
    try:
        expect_reason(
            lambda: module._index_tree_sha(
                str(repository),
                extra_env={"GIT_INDEX_FILE": str(hardlink_index)},
            ),
            "index_tree_environment_invalid",
        )
    finally:
        hardlink_index.unlink()

    invalid_index = index_path.parent / "invalid alternate index"
    invalid_index.write_bytes(raw_index[:-1] + bytes((raw_index[-1] ^ 1,)))
    try:
        expect_reason(
            lambda: module._index_tree_sha(
                str(repository), extra_env={"GIT_INDEX_FILE": str(invalid_index)}
            ),
            "index_tree_unreadable",
        )
    finally:
        invalid_index.unlink()
    assert not tuple(index_path.parent.glob(".code-fixer-private-git-*"))

    original_parse_raw_index = module._parse_raw_index
    replacement_index = index_path.parent / "replacement-index"
    source_write_denied: list[bool] = []
    source_replacement_denied: list[bool] = []

    def attempt_source_mutation(payload: bytes, *, split_overlay: bool):
        try:
            with index_path.open("r+b") as stream:
                stream.write(raw_index)
        except OSError:
            source_write_denied.append(True)
        else:
            source_write_denied.append(False)
        replacement_index.write_bytes(raw_index)
        try:
            os.replace(replacement_index, index_path)
        except OSError:
            source_replacement_denied.append(True)
        else:
            source_replacement_denied.append(False)
        return original_parse_raw_index(payload, split_overlay=split_overlay)

    module._parse_raw_index = attempt_source_mutation
    try:
        assert module._index_tree_sha(str(repository)) == expected_tree
    finally:
        module._parse_raw_index = original_parse_raw_index
    assert source_write_denied == [True]
    assert source_replacement_denied == [True]
    assert replacement_index.read_bytes() == raw_index
    replacement_index.unlink()
    assert index_path.read_bytes() == raw_index

    tracked_stat = tracked.stat()
    os.utime(
        tracked,
        ns=(tracked_stat.st_atime_ns, tracked_stat.st_mtime_ns + 2_000_000_000),
    )
    assert tracked.read_bytes() == git(repository, "show", ":tracked.txt").stdout
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
    original_create = module._windows_create_index_lock
    acquired_locks: list[tuple[str, int]] = []
    replacement_denied: list[bool] = []

    def capture_created_lock(lock_path: str) -> int:
        handle = original_create(lock_path)
        acquired_locks.append((lock_path, handle))
        return handle

    def attempt_replacement(repository_path: str, *arguments: str):
        if not arguments or arguments[0] != "diff":
            return original_run(repository_path, *arguments)
        assert len(acquired_locks) == 1
        lock_path, lock_handle = acquired_locks[0]
        assert os.path.normcase(os.path.abspath(lock_path)) == os.path.normcase(
            str(index_lock_path)
        )
        assert module._windows_index_lock_state(
            lock_handle, "test_lock_state_invalid"
        )
        replacement.write_bytes(replacement_payload)
        try:
            os.replace(replacement, index_lock_path)
        except OSError:
            replacement_denied.append(True)
        else:
            replacement_denied.append(False)
        return original_run(repository_path, *arguments)

    module._windows_create_index_lock = capture_created_lock
    module._run_observational_git = attempt_replacement
    try:
        (observed,) = module._observe_worktree_with_index_lock(
            str(repository), commands
        )
    finally:
        module._run_observational_git = original_run
        module._windows_create_index_lock = original_create
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
