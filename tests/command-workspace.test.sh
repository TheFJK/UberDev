#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
HELPER="$ROOT/plugins/uberdev/lib/command-workspace.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -I -B - "$HELPER" <<'PY'
import importlib.util
import sys
import typing

module_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("command_workspace_type_contract", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

assert getattr(module, "NoReturn", None) is typing.NoReturn, (
    f"NoReturn import is {getattr(module, 'NoReturn', None)!r}"
)
fail_hints = typing.get_type_hints(module.fail)
assert fail_hints["return"] is typing.NoReturn, (
    f"fail return is {fail_hints['return']!r}"
)
PY

. "$LIB"

file_mode() {
  local value
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

file_link_count() {
  local value
  value="$(stat -f '%l' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

# Exercise the complete no-dir-fd path on the host filesystem. Native Windows
# runs the same production branch again through review-child-handoff's wired
# --windows-path-only mode.
python3 -I -B - "$HELPER" "$TMP/portable" <<'PY'
import hashlib
import importlib.util
import json
import ntpath
import os
import pathlib
import subprocess
import sys
import ctypes


module_paths = sys.argv[1:2]
fixture_root = pathlib.Path(sys.argv[2])


def expect_failure(module, code, operation):
    try:
        operation()
    except module.Failure as error:
        assert str(error) == code, (str(error), code)
    else:
        raise AssertionError(f"{code} was accepted")


def fixture(module, name):
    root = fixture_root / name
    repo = root / "repo"
    run = root / "run"
    state = run / ".agent-state-0"
    repo.mkdir(parents=True)
    state.mkdir(parents=True)
    subprocess.run(["git", "-C", repo, "init", "-q"], check=True)
    context = state / f"route-context-v1-{name}.json"
    payload = json.dumps(
        {
            "metadata": {
                "run_id": f"root-{name}",
                "workflow": "review-pr",
                "issue_num": 91,
                "repository_id": str(repo.resolve()),
            }
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    context.write_bytes(payload)
    os.chmod(state, 0o700)
    os.chmod(context, 0o600)
    carrier = {
        "schema_version": 1,
        "run_id": f"root-{name}",
        "workflow": "review-pr",
        "issue_num": 91,
        "context_file": str(context.resolve()),
        "context_sha256": hashlib.sha256(payload).hexdigest(),
    }
    return root, repo.resolve(), state.resolve(), context.resolve(), carrier


for index, module_path in enumerate(module_paths):
    spec = importlib.util.spec_from_file_location(
        f"command_workspace_portable_{index}", module_path
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    module.native_windows = lambda: True
    module.effective_uid = lambda: None
    assert module.filesystem_mode() == "portable_windows"
    assert module.state_directory_name() == ".agent-state-0"
    assert module.windows_directory_access(2) == (
        0x00010000 | 0x00000080 | 0x00100000,
        0x00000001 | 0x00000002,
    )
    assert module.windows_directory_access(1) == (
        0x00010000 | 0x00000080 | 0x00100000,
        0x00000001 | 0x00000002,
    )
    assert module.windows_tracker_access() == (
        0x00000080 | 0x00100000,
        0x00000001 | 0x00000002 | 0x00000004,
    )
    assert module.windows_verifier_access() == (
        0x00000080 | 0x00100000,
        0x00000001 | 0x00000002 | 0x00000004,
    )
    try:
        module.windows_verifier_access(True)
    except TypeError:
        pass
    else:
        raise AssertionError("verifier access retained unused created-state input")
    assert module.WINDOWS_STATUS_OBJECT_NAME_COLLISION == 0xC0000035
    assert module.WINDOWS_STATUS_SHARING_VIOLATION == 0xC0000043
    assert (
        0
        < module.WINDOWS_DIRECTORY_BIND_RETRY_INTERVAL_SECONDS
        < module.WINDOWS_DIRECTORY_BIND_TIMEOUT_SECONDS
        <= 5
    )
    assert module.windows_retry_delay(2.0, 1.0) == min(
        module.WINDOWS_DIRECTORY_BIND_RETRY_INTERVAL_SECONDS, 1.0
    )
    assert module.windows_retry_delay(2.0, 1.999) > 0
    expect_failure(
        module,
        "unsafe_directory",
        lambda: module.windows_retry_delay(2.0, 2.0),
    )
    expect_failure(
        module,
        "unsafe_directory",
        lambda: module.windows_directory_access(3),
    )

    class SuccessfulCreateAndVerify:
        argtypes = None
        restype = None

        def __init__(self):
            self.calls = 0

        def __call__(self, handle_pointer, *_args):
            self.calls += 1
            handle_pointer._obj.value = 101 if self.calls == 1 else 202
            return 0

    class FailVerifierClose:
        argtypes = None
        restype = None

        def __init__(self):
            self.handles = []

        def __call__(self, handle):
            numeric = int(handle.value)
            self.handles.append(numeric)
            return 0 if numeric == 202 else 1

    create_and_verify = SuccessfulCreateAndVerify()
    selective_close = FailVerifierClose()

    class CreateAndVerifyNtdll:
        NtCreateFile = create_and_verify

    class SelectiveCloseKernel:
        CloseHandle = selective_close

    had_windll = hasattr(ctypes, "WinDLL")
    original_windll = getattr(ctypes, "WinDLL", None)
    ctypes.WinDLL = (
        lambda name, **_kwargs:
        CreateAndVerifyNtdll() if name == "ntdll" else SelectiveCloseKernel()
    )
    real_identity = module.windows_handle_identity
    real_disposition = module.windows_mark_directory_for_deletion
    dispositions = []
    module.windows_handle_identity = lambda _handle, _reason: (7, 9)
    module.windows_mark_directory_for_deletion = (
        lambda binding, _reason: dispositions.append(binding.handle)
    )
    try:
        try:
            module.windows_create_or_open_child(
                module.DirectoryBinding(55, (1, 1), (1, 1)),
                "child",
                "unsafe_directory",
            )
        except module.Failure as error:
            assert str(error) == "directory_handle_close_failed", str(error)
            assert module.cleanup_diagnostic(error) == {
                "artifact_classes": ["directory_handle"],
                "code": "workspace_rollback_failed",
            }
        else:
            raise AssertionError("verifier close failure was accepted")
        assert selective_close.handles == [202, 101], selective_close.handles
        assert dispositions == [101], dispositions
    finally:
        module.windows_handle_identity = real_identity
        module.windows_mark_directory_for_deletion = real_disposition
        if had_windll:
            ctypes.WinDLL = original_windll
        else:
            del ctypes.WinDLL

    class FalseClose:
        argtypes = None
        restype = None

        def __call__(self, _handle):
            return 0

    class FalseCloseKernel:
        CloseHandle = FalseClose()

    had_windll = hasattr(ctypes, "WinDLL")
    original_windll = getattr(ctypes, "WinDLL", None)
    ctypes.WinDLL = lambda *_args, **_kwargs: FalseCloseKernel()
    close_binding = module.DirectoryBinding(73, (1, 2), (1, 2))
    try:
        expect_failure(
            module,
            "directory_handle_close_failed",
            lambda: module.close_directory_binding(close_binding),
        )
        assert close_binding.handle == 73
        primary_close_error = module.Failure("unsafe_artifact")
        assert not module.close_directory_binding(
            close_binding, primary=primary_close_error
        )
        assert close_binding.handle == 73
        assert module.cleanup_diagnostic(primary_close_error) == {
            "artifact_classes": ["directory_handle"],
            "code": "workspace_rollback_failed",
        }

        verifier_binding = module.DirectoryBinding(79, (1, 3), (1, 3))
        real_disposition = module.windows_mark_directory_for_deletion
        module.windows_mark_directory_for_deletion = (
            lambda _binding, reason: module.fail(reason)
        )
        try:
            try:
                module.reject_windows_verifier_open(
                    verifier_binding, created=True, reason="unsafe_directory"
                )
            except module.Failure as error:
                assert str(error) == "unsafe_directory", str(error)
                assert module.cleanup_diagnostic(error) == {
                    "artifact_classes": ["directory", "directory_handle"],
                    "code": "workspace_rollback_failed",
                }
            else:
                raise AssertionError("verifier cleanup failures replaced the primary")
        finally:
            module.windows_mark_directory_for_deletion = real_disposition
        assert verifier_binding.handle == 79
    finally:
        if had_windll:
            ctypes.WinDLL = original_windll
        else:
            del ctypes.WinDLL

    root, repo, _state, context, carrier = fixture(module, f"valid-{index}")
    real_normcase = module.os.path.normcase
    module.os.path.normcase = ntpath.normcase
    try:
        assert module.same_portable_path(str(repo).swapcase(), str(repo))
    finally:
        module.os.path.normcase = real_normcase
    loaded = module.load_carrier(
        json.dumps(carrier, separators=(",", ":")), "review-pr"
    )
    module.validate_requested_root(
        str(repo), str(repo), loaded[4], "portable_windows"
    )
    expect_failure(
        module,
        "repository_mismatch",
        lambda: module.validate_requested_root(
            str(repo), str(repo), (loaded[4][0], loaded[4][1] + 1),
            "portable_windows",
        ),
    )
    workspace, artifacts = module.allocate_workspace(
        str(repo),
        f"20260727-01020{index}-abcdef0",
        module.CALLERS["review-pr"]["artifacts"],
        loaded[4],
    )
    assert pathlib.Path(workspace).is_dir()
    assert set(artifacts) == set(module.CALLERS["review-pr"]["artifacts"])
    assert all(pathlib.Path(path).is_file() for path in artifacts.values())
    assert all(
        os.path.commonpath((str(repo), path)) == str(repo)
        for path in artifacts.values()
    )

    _root, repo, _state, _context, mkdir_race_carrier = fixture(
        module, f"mkdir-replacement-{index}"
    )
    loaded = module.load_carrier(
        json.dumps(mkdir_race_carrier, separators=(",", ":")), "review-pr"
    )
    mkdir_race_run = f"20260727-01024{index}-abcdef0"
    replacement_root = repo / ".uberdev"
    displaced_root = repo / ".uberdev-created-by-helper"
    real_bind_child = module.portable_bind_or_create_child

    def replace_created_directory(parent_binding, parent, name):
        binding, created = real_bind_child(parent_binding, parent, name)
        if name == ".uberdev" and created:
            os.replace(replacement_root, displaced_root)
            replacement_root.mkdir()
            (replacement_root / "attacker-marker").write_bytes(
                b"replacement-must-not-receive-artifacts"
            )
        return binding, created

    module.portable_bind_or_create_child = replace_created_directory
    try:
        expect_failure(
            module,
            "unsafe_directory",
            lambda: module.allocate_workspace(
                str(repo),
                mkdir_race_run,
                module.CALLERS["review-pr"]["artifacts"],
                loaded[4],
            ),
        )
    finally:
        module.portable_bind_or_create_child = real_bind_child
    assert (replacement_root / "attacker-marker").read_bytes() == (
        b"replacement-must-not-receive-artifacts"
    )
    assert not (replacement_root / "research").exists()

    module.native_windows = lambda: False
    assert not module.owned_by_current_user(os.stat(repo))
    expect_failure(module, "unsupported_platform", module.filesystem_mode)
    module.effective_uid = lambda: 501
    module.secure_dir_fd_available = lambda: False
    expect_failure(module, "unsupported_platform", module.filesystem_mode)
    module.native_windows = lambda: True
    module.effective_uid = lambda: None

    _root, _repo, _state, _context, bad_name = fixture(
        module, f"bad-name-{index}"
    )
    bad_name["context_file"] = bad_name["context_file"].replace(
        ".agent-state-0", ".agent-state-999999"
    )
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(bad_name, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, state, context, noncanonical = fixture(
        module, f"noncanonical-{index}"
    )
    noncanonical["context_file"] = os.path.join(
        state, "..", state.name, context.name
    )
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(noncanonical, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, _state, context, hardlinked = fixture(
        module, f"hardlink-{index}"
    )
    os.link(context, context.with_name("context-hardlink"))
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(hardlinked, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, _state, context, symlinked = fixture(
        module, f"symlink-{index}"
    )
    backing = context.with_name("context-backing")
    os.replace(context, backing)
    os.symlink(backing, context)
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(symlinked, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, state, context, linked_state = fixture(
        module, f"linked-state-{index}"
    )
    state_backing = state.with_name("state-backing")
    os.replace(state, state_backing)
    os.symlink(state_backing, state, target_is_directory=True)
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(linked_state, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, _state, context, oversized = fixture(
        module, f"oversized-{index}"
    )
    oversized_payload = b"x" * 1048577
    context.write_bytes(oversized_payload)
    oversized["context_sha256"] = hashlib.sha256(oversized_payload).hexdigest()
    expect_failure(
        module,
        "invalid_context",
        lambda: module.load_carrier(
            json.dumps(oversized, separators=(",", ":")), "review-pr"
        ),
    )

    _root, _repo, _state, context, replaced = fixture(
        module, f"replacement-{index}"
    )
    replacement = context.with_name("context-replacement")
    replacement.write_bytes(context.read_bytes())
    os.chmod(replacement, 0o600)
    real_open = module.os.open

    def replacing_open(path, flags, *args, **kwargs):
        descriptor = real_open(path, flags, *args, **kwargs)
        if os.path.normcase(os.path.abspath(path)) == os.path.normcase(
            os.path.abspath(context)
        ):
            os.replace(replacement, context)
        return descriptor

    module.os.open = replacing_open
    try:
        expect_failure(
            module,
            "invalid_context",
            lambda: module.load_carrier(
                json.dumps(replaced, separators=(",", ":")), "review-pr"
            ),
        )
    finally:
        module.os.open = real_open

    for kind in ("hardlink", "symlink"):
        _root, repo, _state, _context, artifact_carrier = fixture(
            module, f"artifact-{kind}-{index}"
        )
        loaded = module.load_carrier(
            json.dumps(artifact_carrier, separators=(",", ":")), "review-pr"
        )
        run_id = f"20260727-01021{index}-{kind[:6]}"
        workspace = repo / ".uberdev" / "research" / run_id
        workspace.mkdir(parents=True)
        artifact = workspace / "pr-diff.md"
        target = workspace / "artifact-target"
        target.write_bytes(b"fixture")
        if kind == "hardlink":
            os.link(target, artifact)
        else:
            os.symlink(target, artifact)
        expect_failure(
            module,
            "unsafe_artifact",
            lambda: module.allocate_workspace(
                str(repo),
                run_id,
                module.CALLERS["review-pr"]["artifacts"],
                loaded[4],
            ),
        )

    _root, repo, _state, _context, rollback_carrier = fixture(
        module, f"rollback-replacement-{index}"
    )
    loaded = module.load_carrier(
        json.dumps(rollback_carrier, separators=(",", ":")), "review-pr"
    )
    rollback_run = f"20260727-01023{index}-abcdef0"
    rollback_artifact = (
        repo / ".uberdev" / "research" / rollback_run / "pr-diff.md"
    )
    real_write = module.os.write

    def replace_then_fail(descriptor, data):
        if rollback_artifact.exists():
            original = rollback_artifact.with_name("created-original")
            replacement = rollback_artifact.with_name("attacker-replacement")
            os.replace(rollback_artifact, original)
            replacement.write_bytes(b"replacement-must-survive")
            os.replace(replacement, rollback_artifact)
            raise OSError("injected write failure after replacement")
        return real_write(descriptor, data)

    module.os.write = replace_then_fail
    try:
        expect_failure(
            module,
            "unsafe_artifact",
            lambda: module.allocate_workspace(
                str(repo),
                rollback_run,
                module.CALLERS["review-pr"]["artifacts"],
                loaded[4],
            ),
        )
    finally:
        module.os.write = real_write
    assert rollback_artifact.read_bytes() == b"replacement-must-survive"

    def assert_rollback_cleanup_diagnostic(kind, expected_classes):
        _root, cleanup_repo, _state, _context, cleanup_carrier = fixture(
            module, f"rollback-{kind}-{index}"
        )
        cleanup_loaded = module.load_carrier(
            json.dumps(cleanup_carrier, separators=(",", ":")), "review-pr"
        )
        cleanup_run = f"20260727-01025{index}-{kind[:7]}"
        real_create = module.portable_create_or_validate_file
        real_unlink = module.os.unlink
        real_rmdir = module.os.rmdir
        real_name = module.os.name
        real_matches = module.windows_binding_matches_path
        real_disposition = module.windows_mark_directory_for_deletion
        calls = 0
        rollback_started = False
        primary = module.Failure("unsafe_artifact")

        def fail_after_first_artifact(*args, **kwargs):
            nonlocal calls, rollback_started
            calls += 1
            if calls == 2:
                rollback_started = True
                if kind == "disposition":
                    module.os.name = "nt"
                raise primary
            return real_create(*args, **kwargs)

        def injected_unlink(*args, **kwargs):
            if rollback_started and kind == "unlink":
                raise OSError("injected unlink failure")
            return real_unlink(*args, **kwargs)

        def injected_rmdir(*args, **kwargs):
            if rollback_started and kind == "rmdir":
                raise OSError("injected rmdir failure")
            return real_rmdir(*args, **kwargs)

        def injected_disposition(_binding, _reason):
            raise module.Failure("unsafe_directory")

        module.portable_create_or_validate_file = fail_after_first_artifact
        module.os.unlink = injected_unlink
        module.os.rmdir = injected_rmdir
        module.windows_binding_matches_path = lambda *_args: True
        module.windows_mark_directory_for_deletion = injected_disposition
        try:
            try:
                module.allocate_workspace(
                    str(cleanup_repo),
                    cleanup_run,
                    module.CALLERS["review-pr"]["artifacts"],
                    cleanup_loaded[4],
                )
            except module.Failure as error:
                assert error is primary, (error, primary)
                assert module.cleanup_diagnostic(error) == {
                    "artifact_classes": expected_classes,
                    "code": "workspace_rollback_failed",
                }
            else:
                raise AssertionError(f"{kind} rollback failure was hidden")
        finally:
            module.portable_create_or_validate_file = real_create
            module.os.unlink = real_unlink
            module.os.rmdir = real_rmdir
            module.os.name = real_name
            module.windows_binding_matches_path = real_matches
            module.windows_mark_directory_for_deletion = real_disposition

    assert_rollback_cleanup_diagnostic("unlink", ["directory", "file"])
    assert_rollback_cleanup_diagnostic("rmdir", ["directory"])
    assert_rollback_cleanup_diagnostic("disposition", ["directory"])

    _root, repo, _state, _context, directory_carrier = fixture(
        module, f"directory-link-{index}"
    )
    loaded = module.load_carrier(
        json.dumps(directory_carrier, separators=(",", ":")), "review-pr"
    )
    outside = repo.parent / "outside-workspace"
    outside.mkdir()
    os.symlink(outside, repo / ".uberdev", target_is_directory=True)
    expect_failure(
        module,
        "unsafe_directory",
        lambda: module.allocate_workspace(
            str(repo),
            f"20260727-01022{index}-abcdef0",
            module.CALLERS["review-pr"]["artifacts"],
            loaded[4],
        ),
    )
PY

python3 -I -B - "$HELPER" <<'PY'
import importlib.util
import pathlib
import subprocess
import sys
import textwrap

for index, module_path in enumerate(sys.argv[1:]):
    raw = pathlib.Path(module_path).read_text(encoding="utf-8")
    assert ".add_note(" not in raw
    assert "sys.exception(" not in raw
    program = textwrap.dedent(
        """
        import importlib.util
        import sys

        module_path = sys.argv[1]
        spec = importlib.util.spec_from_file_location("command_workspace_cli", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        primary = module.Failure("unsafe_artifact")
        module.add_cleanup_diagnostic(primary, {"file"})
        def injected_main():
            raise primary
        module.main = injected_main
        raise SystemExit(module.cli())
        """
    )
    completed = subprocess.run(
        [sys.executable, "-I", "-B", "-c", program, module_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    assert completed.returncode == 2, (index, completed.returncode)
    assert completed.stdout == "", (index, completed.stdout)
    assert completed.stderr == (
        "uberdev command workspace: unsafe_artifact\n"
        'uberdev command workspace cleanup: '
        '{"artifact_classes":["file"],"code":"workspace_rollback_failed"}\n'
    ), (index, completed.stderr)
print("command-workspace-cli-cleanup-diagnostic-ok")
PY

make_carrier() {
  local workflow="$1" issue="$2" repo="$3" run="$4" request decision metadata context_out context sha
  mkdir -p "$run"
  request="$(jq -cn --arg run "$run" --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{schema_version:1,run_dir:$run,run_id:$run_id,repository_id:$repo,backend:"codex",workflow:$workflow,phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:$issue,issue_num:$issue,capacity:6,timeout_s:600,routing_mode:"adaptive"}')"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(jq -cn --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{run_id:$run_id,repository_id:$repo,workflow:$workflow,backend:"codex",issue_num:$issue,task_tier:"medium",risk_signals:[]}')"
  context_out="$(uberdev_agent_context_create "$run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-10T00:00:00Z')"
  context="$(jq -r .context_file <<<"$context_out")"; sha="$(jq -r .context_sha256 <<<"$context_out")"
  jq -cn --arg workflow "$workflow" --arg run_id "root-$workflow" --arg context "$context" --arg sha "$sha" --argjson issue "$issue" \
    '{schema_version:1,run_id:$run_id,workflow:$workflow,issue_num:$issue,context_file:$context,context_sha256:$sha}'
}

REPO="$TMP/repo"
mkdir -p "$REPO"
REPO="$(cd "$REPO" && pwd -P)"
git -C "$REPO" init -q
RUNROOT="$TMP/run"
mkdir -p "$RUNROOT"
RUNROOT="$(cd "$RUNROOT" && pwd -P)"
SOLVE_CARRIER="$(make_carrier solve 41 "$REPO" "$RUNROOT/solve")"
TURBO_CARRIER="$(make_carrier turbo 42 "$REPO" "$RUNROOT/turbo")"
SIMPLIFY_CARRIER="$(make_carrier simplify 0 "$REPO" "$RUNROOT/simplify")"

# Repository identity is accepted only when already canonical and exactly a Git toplevel.
SECURITY_FAILURES=0
NON_GIT_REPO="$TMP/non-git-repo"
mkdir -p "$NON_GIT_REPO"
NON_GIT_REPO="$(cd "$NON_GIT_REPO" && pwd -P)"
NON_GIT_CARRIER="$(make_carrier solve 43 "$NON_GIT_REPO" "$RUNROOT/non-git")"
UBERDEV_RUN_CARRIER_JSON="$NON_GIT_CARRIER"
export UBERDEV_RUN_CARRIER_JSON
NON_GIT_RUN=20260710-010200-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$NON_GIT_CARRIER" --run-id "$NON_GIT_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-Git repository accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$NON_GIT_REPO/.uberdev/research/$NON_GIT_RUN" ]; then
  echo 'non-Git repository workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# Inherited Git environment cannot make a canonical non-Git directory appear
# to be the verified worktree.
MASQUERADE_RUN=20260710-010200-abcdeff
if GIT_DIR="$REPO/.git" GIT_WORK_TREE="$NON_GIT_REPO" \
  python3 "$HELPER" --caller review-pr --carrier-json "$NON_GIT_CARRIER" --run-id "$MASQUERADE_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'inherited Git environment masqueraded a non-Git repository' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$NON_GIT_REPO/.uberdev/research/$MASQUERADE_RUN" ]; then
  echo 'Git-environment masquerade wrote a workspace' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

REPO_LINK="$TMP/repo-link"
ln -s "$REPO" "$REPO_LINK"
SYMLINK_REPO_CARRIER="$(make_carrier solve 44 "$REPO_LINK" "$RUNROOT/symlink-repo")"
UBERDEV_RUN_CARRIER_JSON="$SYMLINK_REPO_CARRIER"
SYMLINK_REPO_RUN=20260710-010201-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$SYMLINK_REPO_CARRIER" --run-id "$SYMLINK_REPO_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-canonical symlink repository_id accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$REPO/.uberdev/research/$SYMLINK_REPO_RUN" ]; then
  echo 'symlink repository workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# The carrier context state directory itself must remain private.
WRONG_MODE_CARRIER="$(make_carrier solve 45 "$REPO" "$RUNROOT/wrong-mode")"
WRONG_MODE_CONTEXT="$(jq -r .context_file <<<"$WRONG_MODE_CARRIER")"
chmod 755 "$(dirname "$WRONG_MODE_CONTEXT")"
UBERDEV_RUN_CARRIER_JSON="$WRONG_MODE_CARRIER"
WRONG_MODE_RUN=20260710-010202-abcdef0
if python3 "$HELPER" --caller review-pr --carrier-json "$WRONG_MODE_CARRIER" --run-id "$WRONG_MODE_RUN" --presets-json '{}' >/dev/null 2>&1; then
  echo 'non-private context state directory accepted' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
if [ -e "$REPO/.uberdev/research/$WRONG_MODE_RUN" ]; then
  echo 'wrong-mode context workspace was written' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi

# Allocation remains bound to the exact repository inode verified by
# load_carrier, even if that pathname is replaced before the first mkdir.
RACE_REPO="$TMP/race-repo"
mkdir -p "$RACE_REPO"
RACE_REPO="$(cd "$RACE_REPO" && pwd -P)"
git -C "$RACE_REPO" init -q
RACE_CARRIER="$(make_carrier solve 46 "$RACE_REPO" "$RUNROOT/race-repo")"
RACE_RUN=20260710-010202-abcdeff
if ! python3 - "$HELPER" "$RACE_CARRIER" "$RACE_RUN" <<'PY'
import importlib.util
import json
import os
import sys

helper_path, carrier_raw, run_id = sys.argv[1:]
spec = importlib.util.spec_from_file_location("command_workspace", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
loaded = module.load_carrier(carrier_raw, "review-pr")
repo = loaded[2]
verified_identity = loaded[4]
current = os.stat(repo, follow_symlinks=False)
assert verified_identity == (current.st_dev, current.st_ino)
os.rename(repo, repo + ".verified")
os.mkdir(repo, 0o700)
rejected = False
try:
    module.allocate_workspace(
        repo,
        run_id,
        module.CALLERS["review-pr"]["artifacts"],
        expected_repo_identity=verified_identity,
    )
except module.Failure:
    rejected = True
workspace = os.path.join(repo, ".uberdev", "research", run_id)
if not rejected or os.path.lexists(workspace):
    raise SystemExit(1)
PY
then
  echo 'repository inode replacement was not rejected before writes' >&2
  SECURITY_FAILURES=$((SECURITY_FAILURES + 1))
fi
[ "$SECURITY_FAILURES" -eq 0 ]

# Every failure after a successful mkdir is locally transactional: the helper
# removes only the directory it created and leaves no workspace or artifacts.
if ! python3 - "$HELPER" "$TMP/transaction-cases" <<'PY'
import importlib.util
import os
import sys

helper_path, cases_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("command_workspace_transaction", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
os.mkdir(cases_root, 0o700)
failures = []

real_open = module.os.open
real_stat = module.os.stat
real_fchmod = module.os.fchmod

def run_case(stage):
    repo = os.path.join(cases_root, stage)
    os.mkdir(repo, 0o700)
    entry = os.stat(repo, follow_symlinks=False)
    identity = (entry.st_dev, entry.st_ino)

    def fault_open(path, flags, *args, **kwargs):
        if stage == "open" and path == ".uberdev" and kwargs.get("dir_fd") is not None:
            raise OSError("injected post-mkdir open failure")
        return real_open(path, flags, *args, **kwargs)

    def fault_stat(path, *args, **kwargs):
        if stage == "validation" and path == ".uberdev" and kwargs.get("dir_fd") is not None:
            raise OSError("injected post-mkdir validation failure")
        return real_stat(path, *args, **kwargs)

    def fault_fchmod(fd, mode):
        if stage == "chmod":
            raise OSError("injected post-mkdir chmod failure")
        return real_fchmod(fd, mode)

    module.os.open = fault_open
    module.os.stat = fault_stat
    module.os.fchmod = fault_fchmod
    rejected = False
    try:
        module.allocate_workspace(
            repo,
            "20260710-010202-acdeef0",
            module.CALLERS["review-pr"]["artifacts"],
            identity,
        )
    except OSError:
        rejected = True
    finally:
        module.os.open = real_open
        module.os.stat = real_stat
        module.os.fchmod = real_fchmod
    if not rejected or os.path.lexists(os.path.join(repo, ".uberdev")):
        failures.append(f"{stage} failure left residual workspace state")

for fault_stage in ("open", "validation", "chmod"):
    run_case(fault_stage)

# A failing open of an existing directory must never remove that directory.
repo = os.path.join(cases_root, "preexisting")
os.mkdir(repo, 0o700)
existing = os.path.join(repo, ".uberdev")
os.mkdir(existing, 0o700)
repo_entry = os.stat(repo, follow_symlinks=False)

def fail_existing_open(path, flags, *args, **kwargs):
    if path == ".uberdev" and kwargs.get("dir_fd") is not None:
        raise OSError("injected existing-directory open failure")
    return real_open(path, flags, *args, **kwargs)

module.os.open = fail_existing_open
try:
    module.allocate_workspace(
        repo,
        "20260710-010202-acdeef1",
        module.CALLERS["review-pr"]["artifacts"],
        (repo_entry.st_dev, repo_entry.st_ino),
    )
except OSError:
    pass
else:
    raise SystemExit("existing-directory failure was unexpectedly accepted")
finally:
    module.os.open = real_open
if not os.path.isdir(existing):
    failures.append("pre-existing directory was removed")
if failures:
    raise SystemExit("; ".join(failures))
PY
then
  echo 'post-mkdir transaction rollback failed' >&2
  exit 1
fi

RUN_ID=20260710-010203-abcdef0
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
export UBERDEV_RUN_CARRIER_JSON
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true

# Inherited solve review creates the exact runtime-owned workspace and artifacts.
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" '' >/dev/null
EXPECTED="$REPO/.uberdev/research/$RUN_ID"
[ "$WORKTREE_ROOT" = "$REPO" ]
[ "$RESEARCH_DIR_ABS" = "$EXPECTED" ]
[ "$(file_mode "$RESEARCH_DIR_ABS")" = 700 ]
[ "$DIFF_ARTIFACT_PATH" = "$EXPECTED/pr-diff.md" ]
[ "$CRITERIA_PATH" = "$EXPECTED/review-criteria.md" ]
[ "$COMMIT_RANGE_PATH" = "$EXPECTED/commit-range.txt" ]
[ "$PHASE1_DISPOSITION_PATH" = "$EXPECTED/phase1-disposition.json" ]
[ "$PHASE2_DISPOSITION_PATH" = "$EXPECTED/phase2-disposition.json" ]
for path in "$DIFF_ARTIFACT_PATH" "$CRITERIA_PATH" "$COMMIT_RANGE_PATH" "$PHASE1_DISPOSITION_PATH" "$PHASE2_DISPOSITION_PATH"; do
  [ "$(file_mode "$path")" = 600 ]
  [ "$(file_link_count "$path")" = 1 ]
done
[ ! -s "$PHASE1_DISPOSITION_PATH" ]
[ ! -s "$PHASE2_DISPOSITION_PATH" ]
grep -q '^<external-untrusted-input source="pr-diff">$' "$DIFF_ARTIFACT_PATH"
jq -e '.caller=="review-pr" and .carrier_workflow=="solve" and .repository_root==$repo and .research_dir==$research and (.artifacts|keys)==["commit_range","criteria","diff","phase1_disposition","phase2_disposition"]' \
  --arg repo "$REPO" --arg research "$EXPECTED" <<<"$UBERDEV_COMMAND_WORKSPACE_JSON" >/dev/null

# Re-entry preserves safe existing bytes.
printf 'preserve-me\n' >"$CRITERIA_PATH"; chmod 600 "$CRITERIA_PATH"
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null
grep -qx 'preserve-me' "$CRITERIA_PATH"

# Artifact globals are output-only; a mismatched preset fails without touching it.
OUTSIDE="$TMP/outside-sentinel"
printf 'sentinel\n' >"$OUTSIDE"
DIFF_ARTIFACT_PATH="$OUTSIDE"
if uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null 2>&1; then
  echo 'mismatched artifact override accepted' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"
DIFF_ARTIFACT_PATH="$EXPECTED/pr-diff.md"

# Review rejects an inherited simplify carrier before allocating its workspace.
BAD_RUN_ID=20260710-010204-abcdef0
UBERDEV_RUN_CARRIER_JSON="$SIMPLIFY_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare review-pr 77 medium '[]' "$BAD_RUN_ID" "$REPO" >/dev/null 2>&1; then
  echo 'review accepted simplify carrier' >&2; exit 1
fi
[ ! -e "$REPO/.uberdev/research/$BAD_RUN_ID" ]

# Review preserves inherited turbo lineage; simplify rejects solve/turbo carriers.
UBERDEV_RUN_CARRIER_JSON="$TURBO_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
TURBO_RUN=20260710-010204-abcdeff
uberdev_command_workspace_prepare review-pr 78 medium '[]' "$TURBO_RUN" '' >/dev/null
[ "$(jq -r .carrier_workflow <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = turbo ]
uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$TURBO_RUN" "$REPO" >/dev/null
[ "$(jq -r .carrier_workflow <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = turbo ]
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare simplify 0 medium '[]' 20260710-010204-acdeeff '' >/dev/null 2>&1; then
  echo 'simplify accepted inherited solve carrier' >&2; exit 1
fi

# Carrier mint failure is terminal and happens before any workspace write.
uberdev_prepare_run_carrier() { return 17; }
unset UBERDEV_RUN_CARRIER_JSON UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
MINT_FAIL_RUN=20260710-010204-acdeefa
rc=0
uberdev_command_workspace_prepare review-pr 79 medium '[]' "$MINT_FAIL_RUN" '' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 17 ]
[ ! -e "$REPO/.uberdev/research/$MINT_FAIL_RUN" ]

# Standalone simplify mints its carrier before allocation and owns exact artifacts.
STANDALONE_CARRIER="$SIMPLIFY_CARRIER"
mint_calls=0
uberdev_prepare_run_carrier() {
  mint_calls=$((mint_calls + 1))
  UBERDEV_RUN_CARRIER_JSON="$STANDALONE_CARRIER"
  export UBERDEV_RUN_CARRIER_JSON
}
unset UBERDEV_RUN_CARRIER_JSON UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
SIMPLIFY_RUN=20260710-010205-abcdef0
uberdev_command_workspace_prepare simplify 0 medium '[]' "$SIMPLIFY_RUN" '' >/dev/null
[ "$mint_calls" -eq 1 ]
[ "$AGG_PATH" = "$REPO/.uberdev/research/$SIMPLIFY_RUN/simplify-final.md" ]
[ "$(file_mode "$AGG_PATH")" = 600 ]
[ "$STANDALONE_SNAPSHOT_PATH" = "$REPO/.uberdev/research/$SIMPLIFY_RUN/standalone-snapshot.json" ]
[ "$(file_mode "$STANDALONE_SNAPSHOT_PATH")" = 600 ]
[ ! -s "$STANDALONE_SNAPSHOT_PATH" ]
[ ! -s "$PHASE1_DISPOSITION_PATH" ]
[ ! -s "$PHASE2_DISPOSITION_PATH" ]
jq -e '(.artifacts|keys)==["aggregate","diff","phase1_disposition","phase2_disposition","standalone_snapshot"]' \
  <<<"$UBERDEV_COMMAND_WORKSPACE_JSON" >/dev/null

# Post-review requires the inherited descriptor, attaches exactly, and preserves bytes.
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
POST_RUN=20260710-010206-abcdef0
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$POST_RUN" '' >/dev/null
printf 'parent-diff\n' >"$DIFF_ARTIFACT_PATH"; chmod 600 "$DIFF_ARTIFACT_PATH"
PARENT_DESCRIPTOR="$UBERDEV_COMMAND_WORKSPACE_JSON"
uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null
[ "$(jq -r .caller <<<"$UBERDEV_COMMAND_WORKSPACE_JSON")" = post-impl-review ]
grep -qx parent-diff "$DIFF_ARTIFACT_PATH"

unset UBERDEV_COMMAND_WORKSPACE_JSON
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review minted or attached without parent descriptor' >&2; exit 1
fi

# Existing symlink artifacts fail closed without mutating their target.
UBERDEV_COMMAND_WORKSPACE_JSON="$PARENT_DESCRIPTOR"
rm "$DIFF_ARTIFACT_PATH"
ln -s "$OUTSIDE" "$DIFF_ARTIFACT_PATH"
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review accepted symlink artifact' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"

rm "$DIFF_ARTIFACT_PATH"
ln "$OUTSIDE" "$DIFF_ARTIFACT_PATH"
if uberdev_command_workspace_prepare post-impl-review 0 medium '[]' "$POST_RUN" "$REPO" >/dev/null 2>&1; then
  echo 'post-review accepted hardlink artifact' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"

# A pre-existing symlink at the exact run directory is never followed.
SYMLINK_RUN=20260710-010207-abcdef0
OUTSIDE_DIR="$TMP/outside-dir"; mkdir -p "$OUTSIDE_DIR"
ln -s "$OUTSIDE_DIR" "$REPO/.uberdev/research/$SYMLINK_RUN"
UBERDEV_RUN_CARRIER_JSON="$SOLVE_CARRIER"
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
if uberdev_command_workspace_prepare review-pr 80 medium '[]' "$SYMLINK_RUN" '' >/dev/null 2>&1; then
  echo 'workspace followed a symlink run directory' >&2; exit 1
fi
[ -z "$(find "$OUTSIDE_DIR" -mindepth 1 -print -quit)" ]

# Markdown setups are thin runtime clients with no duplicate validator or writes.
for doc in "$ROOT/plugins/uberdev/commands/review-pr.md" "$ROOT/plugins/uberdev/commands/simplify.md" "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"; do
  grep -qF 'uberdev_command_workspace_prepare' "$doc"
  ! grep -nE 'UBERDEV_SETUP_BOUNDARY_JSON|mkdir -p "\$RESEARCH_DIR_ABS"|DIFF_ARTIFACT_PATH="\$\{DIFF_ARTIFACT_PATH|CRITERIA_PATH="\$\{CRITERIA_PATH' "$doc"
done

echo 'command-workspace: PASS'
