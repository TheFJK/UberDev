#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/plugins/uberdev/lib/run_manifest.py"
FIXTURES="$ROOT/tests/fixtures/run-manifest"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
CAPTURE_OUT=""
CAPTURE_RC=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
capture() {
  CAPTURE_OUT="$("$@" 2>&1)"
  CAPTURE_RC=$?
}
append_event() {
  python3 "$MANIFEST" append --manifest "$1" --event-json "$2"
}
identity_for_pid() {
  printf '%s|%s|%s|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$1" "$1" "$1"
}
mode_of() {
  local value
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

if [ ! -f "$MANIFEST" ]; then
  printf '  FAIL  run_manifest.py is missing: %s\n' "$MANIFEST"
  exit 1
fi
SELF_IDENTITY="$(python3 "$MANIFEST" process-identity --pid "$$")" || exit 1

LINUX_IDENTITY_CLASSIFICATION="$(python3 -I -B - "$MANIFEST" "$ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import builtins
import errno
import importlib.util
import io
import pathlib
import sys
from unittest import mock

for index, module_path in enumerate(sys.argv[1:]):
    spec = importlib.util.spec_from_file_location(f"run_manifest_linux_identity_{index}", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module._native_process_record = module._linux_process_record

    def missing_stat(path, *args, **kwargs):
        if pathlib.Path(path) == pathlib.Path("/proc/424242/stat"):
            raise FileNotFoundError(errno.ENOENT, "vanished process", path)
        raise AssertionError(path)

    with mock.patch.object(builtins, "open", missing_stat):
        missing = module._process_identity(424242)[0]

    stat_fields = ["S", "1", "2", "3", *(["0"] * 15), "99"]
    stat_record = f"424242 (fixture) {' '.join(stat_fields)}"
    def failed_boot_id(path, *args, **kwargs):
        if pathlib.Path(path) == pathlib.Path("/proc/424242/stat"):
            return io.StringIO(stat_record)
        if pathlib.Path(path) == pathlib.Path("/proc/sys/kernel/random/boot_id"):
            raise OSError(errno.EIO, "boot id read failed")
        raise AssertionError(path)

    with mock.patch.object(builtins, "open", failed_boot_id):
        unavailable = module._process_identity(424242)[0]
    print(f"{missing}/{unavailable}")
PY
)"
if [ "$LINUX_IDENTITY_CLASSIFICATION" = $'absent/unavailable\nabsent/unavailable' ]; then
  pass "Linux vanished PIDs are absent while other identity I/O failures stay unavailable in both mirrors"
else
  fail "Linux process identity error classification" "$LINUX_IDENTITY_CLASSIFICATION"
fi

WINDOWS_PARENT_PROBE_SPLIT="$(python3 -I -B - "$MANIFEST" "$ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import errno
import importlib.util
import sys


class Function:
    def __init__(self, implementation):
        self.implementation = implementation

    def __call__(self, *args):
        return self.implementation(*args)


class Kernel32:
    def __init__(self):
        self.next_handle = 72
        self.open_handles = set()
        self.closed = []
        self.live = True
        self.exit_checks = []
        self.OpenProcess = Function(self.open_process)
        self.GetExitCodeProcess = Function(self.get_exit_code)
        self.GetProcessTimes = Function(self.get_process_times)
        self.CloseHandle = Function(self.close_handle)

    def open_process(self, _access, _inherit, _pid):
        self.next_handle += 1
        self.open_handles.add(self.next_handle)
        return self.next_handle

    def get_exit_code(self, handle, exit_code):
        assert handle in self.open_handles, handle
        self.exit_checks.append(self.live)
        exit_code._obj.value = 259 if self.live else 0
        return 1

    @staticmethod
    def get_process_times(_handle, created, _exited, _kernel, _user):
        created._obj.low = 41
        created._obj.high = 1
        return 1

    def close_handle(self, handle):
        assert handle in self.open_handles, handle
        self.open_handles.remove(handle)
        self.closed.append(handle)
        return 1


for index, module_path in enumerate(sys.argv[1:]):
    spec = importlib.util.spec_from_file_location(f"run_manifest_windows_parent_split_{index}", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    kernel32 = Kernel32()
    module.ctypes.WinDLL = lambda *_args, **_kwargs: kernel32
    parent_calls = []

    def snapshot_parent(pid):
        assert kernel32.open_handles, "parent snapshot ran without a live process handle"
        parent_calls.append(pid)
        return 17

    module._windows_parent_pid = snapshot_parent
    module._native_process_record = module._windows_process_record
    classification, identity = module._process_identity(424242)
    assert classification == "captured" and identity is not None, classification
    assert parent_calls == [], f"normal identity probe took a process-table snapshot: {parent_calls}"

    original_platform = module.sys.platform
    original_os_name = module.os.name
    try:
        module.sys.platform = "win32"
        module.os.name = "nt"
        parent, parent_creation_ticks = (
            module._windows_guarded_parent_record(424242)
        )
    finally:
        module.sys.platform = original_platform
        module.os.name = original_os_name
    assert parent == 17, parent
    assert parent_creation_ticks == (1 << 32) | 41, parent_creation_ticks
    assert parent_calls == [424242], parent_calls
    assert not kernel32.open_handles, kernel32.open_handles
    assert kernel32.closed == [73, 75, 74], kernel32.closed

    race_kernel32 = Kernel32()
    module.ctypes.WinDLL = lambda *_args, **_kwargs: race_kernel32

    def exiting_snapshot(pid):
        assert race_kernel32.open_handles, "snapshot ran without a live process handle"
        race_kernel32.live = False
        return 23

    module._windows_parent_pid = exiting_snapshot
    try:
        module.sys.platform = "win32"
        module.os.name = "nt"
        try:
            module._windows_guarded_parent_record(424242)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("parent accepted after guarded process exited")
    finally:
        module.sys.platform = original_platform
        module.os.name = original_os_name
    assert race_kernel32.exit_checks == [True, False], race_kernel32.exit_checks
    assert not race_kernel32.open_handles, race_kernel32.open_handles
    assert race_kernel32.closed == [73], race_kernel32.closed

    missing_kernel32 = Kernel32()
    module.ctypes.WinDLL = lambda *_args, **_kwargs: missing_kernel32

    def missing_snapshot(pid):
        assert missing_kernel32.open_handles, "snapshot ran without a live process handle"
        raise ProcessLookupError(pid)

    module._windows_parent_pid = missing_snapshot
    try:
        module.sys.platform = "win32"
        module.os.name = "nt"
        try:
            module._windows_guarded_parent_record(424242)
        except OSError as error:
            assert not isinstance(error, ProcessLookupError), type(error)
            assert error.errno == errno.EAGAIN, error
        else:
            raise AssertionError("snapshot disappearance was not unavailable evidence")
    finally:
        module.sys.platform = original_platform
        module.os.name = original_os_name
    assert missing_kernel32.exit_checks == [True], missing_kernel32.exit_checks
    assert not missing_kernel32.open_handles, missing_kernel32.open_handles
    assert missing_kernel32.closed == [73], missing_kernel32.closed
    assert missing_kernel32.closed.count(73) == 1, missing_kernel32.closed
    print("captured/guarded-parent/rechecked/snapshot-unavailable")
PY
)"
if [ "$WINDOWS_PARENT_PROBE_SPLIT" = $'captured/guarded-parent/rechecked/snapshot-unavailable\ncaptured/guarded-parent/rechecked/snapshot-unavailable' ]; then
  pass "Windows parent lookup rechecks liveness and closes snapshot misses exactly once"
else
  fail "Windows process identity/parent lookup split" "$WINDOWS_PARENT_PROBE_SPLIT"
fi

WINDOWS_PARENT_GENERATION_BINDING="$(python3 -I -B - "$MANIFEST" "$ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import hashlib
import importlib.util
import pathlib
import sys
import tempfile


class Function:
    def __init__(self, implementation):
        self.implementation = implementation

    def __call__(self, *args):
        return self.implementation(*args)


class Kernel32:
    def __init__(self, generations, parents, recycle_on_close=None):
        self.generations = dict(generations)
        self.parents = dict(parents)
        self.recycle_on_close = dict(recycle_on_close or {})
        self.next_handle = 72
        self.open_handles = {}
        self.open_calls = []
        self.closed = []
        self.snapshot_calls = []
        self.OpenProcess = Function(self.open_process)
        self.GetExitCodeProcess = Function(self.get_exit_code)
        self.GetProcessTimes = Function(self.get_process_times)
        self.CloseHandle = Function(self.close_handle)

    def open_process(self, _access, _inherit, pid):
        self.next_handle += 1
        self.open_handles[self.next_handle] = pid
        self.open_calls.append(pid)
        return self.next_handle

    def get_exit_code(self, handle, exit_code):
        assert handle in self.open_handles, handle
        exit_code._obj.value = 259
        return 1

    def get_process_times(self, handle, created, _exited, _kernel, _user):
        pid = self.open_handles[handle]
        ticks = self.generations[pid]
        created._obj.low = ticks & 0xFFFFFFFF
        created._obj.high = ticks >> 32
        return 1

    def close_handle(self, handle):
        pid = self.open_handles.pop(handle)
        self.closed.append(handle)
        replacement = self.recycle_on_close.get(pid)
        if replacement is not None:
            replacement_pid, replacement_ticks = replacement
            self.generations[replacement_pid] = replacement_ticks
        return 1

    def snapshot_parent(self, pid):
        assert pid in self.open_handles.values(), (
            "parent snapshot ran without the guarded child handle"
        )
        self.snapshot_calls.append(pid)
        return self.parents[pid]


def expected_identity(pid, creation_ticks):
    digest = hashlib.sha256(f"windows:{creation_ticks}".encode()).hexdigest()
    return f"{pid}|{pid}|{pid}|{digest}"


for index, module_path in enumerate(sys.argv[1:]):
    spec = importlib.util.spec_from_file_location(
        f"run_manifest_windows_parent_generation_{index}", module_path
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    original_platform = module.sys.platform
    original_os_name = module.os.name
    original_getppid = module.os.getppid
    had_windll = hasattr(module.ctypes, "WinDLL")
    original_windll = getattr(module.ctypes, "WinDLL", None)
    try:
        temporary_parent = pathlib.Path(tempfile.gettempdir()).resolve()
        with tempfile.TemporaryDirectory(dir=temporary_parent) as temporary:
            root = pathlib.Path(temporary)
            direct = root / "direct"
            parent = root / "parent"
            newer = root / "newer"
            direct.touch(mode=0o600)
            parent.touch(mode=0o600)
            newer.touch(mode=0o600)

            module.sys.platform = "win32"
            module.os.name = "nt"
            module.os.getppid = lambda: 100
            direct_kernel = Kernel32(
                {100: 300, 200: 200},
                {100: 200},
                {100: (200, 400)},
            )
            module.ctypes.WinDLL = lambda *_args, **_kwargs: direct_kernel
            module._windows_parent_pid = direct_kernel.snapshot_parent
            module._write_process_identity("direct", str(direct))
            expected = f"200\n{expected_identity(200, 200)}\n".encode()
            assert direct.read_bytes() == expected, direct.read_bytes()
            assert direct_kernel.open_calls == [100, 200], direct_kernel.open_calls
            assert direct_kernel.closed == [74, 73], direct_kernel.closed

            parent_kernel = Kernel32(
                {100: 300, 200: 200, 300: 100},
                {100: 200, 200: 300},
                {100: (200, 400)},
            )
            module.ctypes.WinDLL = lambda *_args, **_kwargs: parent_kernel
            module._windows_parent_pid = parent_kernel.snapshot_parent
            try:
                module._write_process_identity("parent", str(parent))
            except module.ManifestRuntimeError as error:
                assert str(error) == "process_identity_parent_absent", str(error)
            else:
                raise AssertionError("recycled parent generation was traversed")
            assert parent.read_bytes() == b""
            assert parent_kernel.snapshot_calls == [100], parent_kernel.snapshot_calls
            assert parent_kernel.open_calls == [100, 200, 200], parent_kernel.open_calls
            assert parent_kernel.closed == [74, 73, 75], parent_kernel.closed

            newer_kernel = Kernel32(
                {100: 300, 200: 400},
                {100: 200},
            )
            module.ctypes.WinDLL = lambda *_args, **_kwargs: newer_kernel
            module._windows_parent_pid = newer_kernel.snapshot_parent
            try:
                module._write_process_identity("direct", str(newer))
            except module.ManifestRuntimeError as error:
                assert str(error) == "process_identity_parent_unavailable", str(error)
            else:
                raise AssertionError("parent created after child was accepted")
            assert newer.read_bytes() == b""
            assert newer_kernel.open_calls == [100, 200], newer_kernel.open_calls
            assert newer_kernel.closed == [74, 73], newer_kernel.closed
    finally:
        module.sys.platform = original_platform
        module.os.name = original_os_name
        module.os.getppid = original_getppid
        if had_windll:
            module.ctypes.WinDLL = original_windll
        elif hasattr(module.ctypes, "WinDLL"):
            del module.ctypes.WinDLL
    print("bound/recycled-rejected/newer-rejected")
PY
)"
if [ "$WINDOWS_PARENT_GENERATION_BINDING" = $'bound/recycled-rejected/newer-rejected\nbound/recycled-rejected/newer-rejected' ]; then
  pass "Windows parent traversal carries and validates bound process generations"
else
  fail "Windows parent generation binding" "$WINDOWS_PARENT_GENERATION_BINDING"
fi

SUPPORTED_PLATFORM_POLICY="$(python3 -I -B - "$MANIFEST" "$ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import importlib.util
import sys

for index, module_path in enumerate(sys.argv[1:]):
    spec = importlib.util.spec_from_file_location(f"run_manifest_supported_platforms_{index}", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    assert module.SUPPORTED_PROCESS_IDENTITY_PLATFORMS == (
        "linux", "darwin", "windows"
    )
    original_platform = module.sys.platform
    original_os_name = module.os.name
    try:
        module.sys.platform = "freebsd14"
        module.os.name = "posix"
        try:
            module._native_process_record(424242)
        except OSError as error:
            assert str(error) == (
                "unsupported process identity platform; "
                "supported platforms: linux, darwin, windows"
            ), str(error)
        else:
            raise AssertionError("unsupported POSIX received a degraded identity")
        assert module._process_identity(424242) == ("unavailable", None)
    finally:
        module.sys.platform = original_platform
        module.os.name = original_os_name
    print(",".join(module.SUPPORTED_PROCESS_IDENTITY_PLATFORMS))
PY
)"
if [ "$SUPPORTED_PLATFORM_POLICY" = $'linux,darwin,windows\nlinux,darwin,windows' ]; then
  pass "process identity explicitly supports only Linux, macOS, and Windows"
else
  fail "process identity supported-platform policy" "$SUPPORTED_PLATFORM_POLICY"
fi
if grep -Fq \
    'Process-identity reconciliation is supported on Linux, macOS, and native Windows' \
    "$ROOT/README.md"; then
  pass "README states the process-identity supported-platform contract"
else
  fail "README process-identity supported-platform contract" "supported trio is undocumented"
fi

PROCESS_IDENTITY_CANDIDATE_SECURITY="$(python3 -I -B - "$MANIFEST" "$ROOT/codex/uberdev-codex/lib/run_manifest.py" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile

for index, module_path in enumerate(sys.argv[1:]):
    spec = importlib.util.spec_from_file_location(f"run_manifest_identity_candidate_{index}", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.os.getppid = lambda: 41
    module._process_identity = lambda pid: (
        "captured", f"{pid}|{pid}|{pid}|" + ("a" * 64)
    )

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        candidate = root / "owner-candidate"
        victim = root / "victim"
        victim.write_bytes(b"unchanged")
        candidate.symlink_to(victim)
        try:
            module._write_process_identity("direct", str(candidate))
        except (module.ManifestRejected, module.ManifestRuntimeError):
            pass
        else:
            raise AssertionError("symlinked process-identity candidate was accepted")
        assert victim.read_bytes() == b"unchanged"

        candidate.unlink()
        candidate.touch(mode=0o600)
        real_write = module.os.write
        real_ftruncate = module.os.ftruncate
        real_close = module.os.close
        replacement_descriptors = []
        replacement_close_offsets = []
        rollback_calls = []
        close_calls = []

        def replace_during_write(descriptor, payload):
            replacement_descriptors.append(descriptor)
            replacement_close_offsets.append(len(close_calls))
            candidate.unlink()
            candidate.symlink_to(victim)
            return real_write(descriptor, payload)

        def track_ftruncate(descriptor, length):
            rollback_calls.append((descriptor, length))
            return real_ftruncate(descriptor, length)

        def track_close(descriptor):
            close_calls.append(descriptor)
            return real_close(descriptor)

        module.os.write = replace_during_write
        module.os.ftruncate = track_ftruncate
        module.os.close = track_close
        try:
            try:
                module._write_process_identity("direct", str(candidate))
            except module.ManifestRejected as error:
                assert str(error) == "process_identity_candidate_replaced", str(error)
            else:
                raise AssertionError("replaced process-identity candidate was accepted")
        finally:
            module.os.write = real_write
            module.os.ftruncate = real_ftruncate
            module.os.close = real_close
        assert len(replacement_descriptors) == 1, replacement_descriptors
        original_descriptor = replacement_descriptors[0]
        assert rollback_calls == [(original_descriptor, 0)], rollback_calls
        assert close_calls[replacement_close_offsets[0]:] == [
            original_descriptor
        ], close_calls
        assert victim.read_bytes() == b"unchanged"

        candidate.unlink()
        candidate.touch(mode=0o600)
        real_write = module.os.write

        def short_write(descriptor, payload):
            return real_write(descriptor, payload[:1])

        module.os.write = short_write
        try:
            try:
                module._write_process_identity("direct", str(candidate))
            except module.ManifestRuntimeError as error:
                assert str(error) == "process_identity_short_write", str(error)
            else:
                raise AssertionError("short process-identity write succeeded")
        finally:
            module.os.write = real_write
        assert candidate.read_bytes() == b""
    print("candidate-secure")
PY
)"
if [ "$PROCESS_IDENTITY_CANDIDATE_SECURITY" = $'candidate-secure\ncandidate-secure' ]; then
  pass "process identity securely binds, verifies, and rolls back its pre-created candidate"
else
  fail "process identity candidate security" "$PROCESS_IDENTITY_CANDIDATE_SECURITY"
fi

printf '== run manifest: fixture verification ==\n'
capture python3 "$MANIFEST" verify --manifest "$FIXTURES/valid.jsonl" --strict
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"events":3,"runs":1,"status":"ok"}' ]; then
  pass "valid lifecycle verifies deterministically"
else
  fail "valid lifecycle verifies deterministically" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/malformed.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && [ "$CAPTURE_OUT" = '{"errors":["line 2: malformed_json"],"status":"invalid"}' ]; then
  pass "malformed JSON is reported by line with rc=1"
else
  fail "malformed JSON is reported by line with rc=1" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/duplicate-terminal.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 4: duplicate_terminal'; then
  pass "duplicate terminal event is rejected"
else
  fail "duplicate terminal event is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/invalid-transition.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 1: agent_started_before_route_decided'; then
  pass "start before route decision is rejected"
else
  fail "start before route decision is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/missing-terminal.jsonl"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "non-strict verification permits a live started run"
else
  fail "non-strict verification permits a live started run" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" verify --manifest "$FIXTURES/missing-terminal.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'run run-open: missing_terminal'; then
  pass "strict verification rejects a missing terminal"
else
  fail "strict verification rejects a missing terminal" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/forbidden.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'forbidden_field: prompt_body'; then
  pass "verification detects forbidden payload fields"
else
  fail "verification detects forbidden payload fields" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/schema-float.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_schema_version'; then
  pass "schema version must be a supported integer, not a JSON float"
else
  fail "schema version must be the integer 1, not a JSON float" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

INVALID_STARTED_SCHEMA="$TMP/invalid-started-schema.jsonl"
printf '%s\n' '{"schema_version":"2","event":"agent_started","timestamp":"2026-07-10T00:00:00Z","run_id":"run-invalid-started-schema","backend":"codex","owner_pid":1}' >"$INVALID_STARTED_SCHEMA"
capture python3 "$MANIFEST" verify --manifest "$INVALID_STARTED_SCHEMA"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_schema_version'; then
  pass "invalid agent_started schema is rejected without a validator crash"
else
  fail "invalid agent_started schema is rejected without a validator crash" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/backend-mismatch.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 2: backend_mismatch'; then
  pass "backend identity cannot drift within one lifecycle"
else
  fail "backend identity cannot drift within one lifecycle" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

for invalid_case in \
  'invalid-routing.jsonl:invalid_routing_mode' \
  'invalid-enforcement.jsonl:invalid_enforcement_evidence' \
  'shadow-contradiction.jsonl:shadow_requires_inherit' \
  'credential-value.jsonl:sensitive_value: decision_source' \
  'free-text-error.jsonl:invalid_fallback_reason' \
  'opaque-without-status.jsonl:opaque_backend_handle_requires_status_path'
do
  fixture="${invalid_case%%:*}"
  expected="${invalid_case#*:}"
  capture python3 "$MANIFEST" verify --manifest "$FIXTURES/$fixture"
  if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -Fq "$expected"; then
    pass "$fixture is rejected by closed manifest metadata rules"
  else
    fail "$fixture is rejected by closed manifest metadata rules" "rc=$CAPTURE_RC expected=$expected out=$CAPTURE_OUT"
  fi
done

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/null-owner.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_owner_pid'; then
  pass "agent_started requires a positive owner PID, not null"
else
  fail "agent_started requires a positive owner PID, not null" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

MISSING_OWNER_IDENTITY="$TMP/missing-owner-identity/events.jsonl"
append_event "$MISSING_OWNER_IDENTITY" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:00:00Z","run_id":"run-missing-owner-identity","backend":"codex"}' >/dev/null
capture append_event "$MISSING_OWNER_IDENTITY" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:00:01Z\",\"run_id\":\"run-missing-owner-identity\",\"backend\":\"codex\",\"owner_pid\":$$}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_owner_process_identity'; then
  pass "current agent_started records require owner process identity"
else
  fail "current agent_started records require owner process identity" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

LEGACY_V1="$TMP/legacy-v1/events.jsonl"
mkdir -p "$(dirname "$LEGACY_V1")"
printf '%s\n' \
  '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00Z","run_id":"run-legacy-v1","backend":"codex"}' \
  '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01Z","run_id":"run-legacy-v1","backend":"codex","owner_pid":2147483647,"backend_handle":"2147483647"}' >"$LEGACY_V1"
capture python3 "$MANIFEST" verify --manifest "$LEGACY_V1"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "legacy v1 lifecycle without owner identity remains readable"
else
  fail "legacy v1 lifecycle without owner identity remains readable" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" reconcile --manifest "$LEGACY_V1"
capture python3 "$MANIFEST" reconcile --manifest "$LEGACY_V1"
if [ "$CAPTURE_RC" -eq 0 ] && python3 -I - "$LEGACY_V1" <<'PY'
import json,pathlib,sys
rows=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert [row["event"] for row in rows] == ["route_decided", "agent_started", "abandoned"]
assert rows[-1]["schema_version"] == 1
assert "owner_process_identity" not in rows[1]
PY
then
  pass "legacy v1 recovery is schema-preserving and idempotent"
else
  fail "legacy v1 recovery is schema-preserving and idempotent" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

V1_APPEND_BYPASS="$TMP/v1-append-bypass/events.jsonl"
capture append_event "$V1_APPEND_BYPASS" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00Z","run_id":"run-v1-bypass","backend":"codex"}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'append_requires_current_schema'; then
  pass "append boundary rejects newly claimed legacy v1 records"
else
  fail "append boundary rejects newly claimed legacy v1 records" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

IDENTITY_PID_MISMATCH="$TMP/identity-pid-mismatch/events.jsonl"
append_event "$IDENTITY_PID_MISMATCH" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:00:00Z","run_id":"run-identity-pid-mismatch","backend":"codex"}' >/dev/null
capture append_event "$IDENTITY_PID_MISMATCH" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:00:01Z\",\"run_id\":\"run-identity-pid-mismatch\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$(( $$ + 1 ))|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_owner_process_identity'; then
  pass "owner process identity is bound to owner_pid"
else
  fail "owner process identity is bound to owner_pid" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

IDENTITY_PROBE_STATUS="$TMP/identity-probe-status.json"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s","process_identity":"1|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' \
  "$$" >"$IDENTITY_PROBE_STATUS"
capture python3 -I - "$MANIFEST" "$IDENTITY_PROBE_STATUS" <<'PY'
import importlib.util
import pathlib
import sys

manifest_path, status_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("run_manifest_probe_test", manifest_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

expected = "4242|1|1|" + ("a" * 64)
original_kill = module.os.kill
original_native_record = module._native_process_record
try:
    def forbidden_kill(pid, signal):
        raise AssertionError("liveness probe attempted to signal a process")

    module.os.kill = forbidden_kill
    module._native_process_record = lambda pid: (1, 1, 1, "fixture")
    captured = module.hashlib.sha256(b"fixture").hexdigest()
    assert module._pid_live(4242, f"4242|1|1|{captured}") is True

    def denied_native_record(pid):
        raise PermissionError()

    module._native_process_record = denied_native_record
    assert module._pid_live(4242, expected) is None
finally:
    module.os.kill = original_kill
    module._native_process_record = original_native_record

started = {"backend": "codex", "status_path": status_path}
assert module._reconciliation_status(started) == (None, None, None, None)
PY
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "native identity liveness never signals and probe failures stay unavailable"
else
  fail "native identity liveness never signals and probe failures stay unavailable" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/policy-mismatch.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'decision_effective_route_mismatch'; then
  pass "adaptive decision and effective route metadata must agree"
else
  fail "adaptive decision and effective route metadata must agree" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/sensitive-allowed-field.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'sensitive_value: issue_or_pr'; then
  pass "sensitive content cannot smuggle through an allowed metadata key"
else
  fail "sensitive content cannot smuggle through an allowed metadata key" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '== run manifest: append schema, lifecycle, privacy, and atomicity ==\n'
APPEND_DIR="$TMP/private-manifest"
APPEND_PATH="$APPEND_DIR/events.jsonl"
ROUTE='{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:01:00Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","decision_source":"role-policy","usage_source":"provider","input_tokens":0}'
START="{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:01:01Z\",\"run_id\":\"run-append\",\"agent_id\":\"agent-append\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$SELF_IDENTITY\",\"backend_handle\":null,\"timeout_s\":5}"
DONE='{"schema_version":2,"event":"completed","timestamp":"2026-07-10T00:01:02Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","terminal_status":"completed"}'

capture append_event "$APPEND_PATH" "$ROUTE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"event":"route_decided","run_id":"run-append","status":"appended"}' ]; then
  pass "append emits deterministic success JSON"
else
  fail "append emits deterministic success JSON" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture append_event "$APPEND_PATH" "$START"
[ "$CAPTURE_RC" -eq 0 ] && pass "agent_started appends after route_decided" || fail "agent_started appends after route_decided" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture append_event "$APPEND_PATH" "$DONE"
[ "$CAPTURE_RC" -eq 0 ] && pass "terminal appends after agent_started" || fail "terminal appends after agent_started" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

capture python3 "$MANIFEST" verify --manifest "$APPEND_PATH" --strict
[ "$CAPTURE_RC" -eq 0 ] && pass "appended lifecycle verifies strict" || fail "appended lifecycle verifies strict" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

if [ "$(mode_of "$APPEND_DIR")" = "700" ] && [ "$(mode_of "$APPEND_PATH")" = "600" ]; then
  pass "manifest parent is 0700 and file is 0600"
else
  fail "manifest parent is 0700 and file is 0600" "dir=$(mode_of "$APPEND_DIR") file=$(mode_of "$APPEND_PATH")"
fi

before_lines="$(wc -l < "$APPEND_PATH" | tr -d ' ')"
capture append_event "$APPEND_PATH" '{"schema_version":2,"event":"failed","timestamp":"2026-07-10T00:01:03Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","terminal_status":"failed"}'
after_lines="$(wc -l < "$APPEND_PATH" | tr -d ' ')"
if [ "$CAPTURE_RC" -eq 2 ] && [ "$before_lines" -eq "$after_lines" ] && printf '%s' "$CAPTURE_OUT" | grep -q 'duplicate_terminal'; then
  pass "append rejects a second terminal without mutating the file"
else
  fail "append rejects a second terminal without mutating the file" "rc=$CAPTURE_RC lines=$before_lines/$after_lines out=$CAPTURE_OUT"
fi

capture append_event "$TMP/no-route/events.jsonl" '{"schema_version":2,"event":"agent_started","timestamp":"2026-07-10T00:02:00Z","run_id":"run-no-route","backend":"codex","owner_pid":1,"owner_process_identity":"1|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'agent_started_before_route_decided'; then
  pass "append validates lifecycle transitions"
else
  fail "append validates lifecycle transitions" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

forbidden_fail_before="$FAIL"
for forbidden in prompt source body raw content issue_body source_code credentials secret api_key access_token; do
  path="$TMP/forbidden-$forbidden/events.jsonl"
  json="{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:03:00Z\",\"run_id\":\"run-$forbidden\",\"backend\":\"codex\",\"$forbidden\":\"sensitive\"}"
  capture append_event "$path" "$json"
  if [ "$CAPTURE_RC" -ne 2 ]; then
    fail "forbidden field $forbidden is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
done
if [ "$FAIL" -eq "$forbidden_fail_before" ]; then
  pass "prompt/source/body/raw and credential payload fields are rejected"
fi

capture append_event "$TMP/unknown/events.jsonl" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:04:00Z","run_id":"run-unknown","backend":"codex","message":"payload in disguise"}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'unknown_field: message'; then
  pass "unknown non-metadata fields are rejected"
else
  fail "unknown non-metadata fields are rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

payload_smuggling_fail_before="$FAIL"
for metadata_field in workflow phase role parent_run_id decision_model effective_model; do
  path="$TMP/payload-smuggling-$metadata_field/events.jsonl"
  json="{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-smuggling-$metadata_field\",\"backend\":\"codex\",\"$metadata_field\":\"function exfiltrate(){return document.cookie}\"}"
  capture append_event "$path" "$json"
  if [ "$CAPTURE_RC" -ne 2 ]; then
    fail "payload text in $metadata_field is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
done
capture append_event "$TMP/payload-smuggling-risks/events.jsonl" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:04:01Z","run_id":"run-smuggling-risks","backend":"codex","risk_signals":["copy the complete issue body into logs"]}'
if [ "$CAPTURE_RC" -ne 2 ]; then
  fail "payload text in risk_signals is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
if [ "$FAIL" -eq "$payload_smuggling_fail_before" ]; then
  pass "allowed metadata fields cannot smuggle source or prose payloads"
fi

LONG_RISK="$(printf '%0130d' 0 | tr '0' 'a')"
LONG_CODE="$(printf '%0300d' 0 | tr '0' 'a')"
capture append_event "$TMP/payload-smuggling-long-risk/events.jsonl" "{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-long-risk\",\"backend\":\"codex\",\"risk_signals\":[\"$LONG_RISK\"]}"
long_risk_rc="$CAPTURE_RC"
capture append_event "$TMP/payload-smuggling-long-code/events.jsonl" "{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-long-code\",\"backend\":\"codex\",\"decision_source\":\"$LONG_CODE\"}"
if [ "$long_risk_rc" -eq 2 ] && [ "$CAPTURE_RC" -eq 2 ]; then
  pass "code-shaped metadata remains tightly size-bounded"
else
  fail "code-shaped metadata remains tightly size-bounded" "risk_rc=$long_risk_rc code_rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture append_event "$TMP/non-string-risk/events.jsonl" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:04:01Z","run_id":"run-non-string-risk","backend":"codex","risk_signals":[{}]}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_risk_signals'; then
  pass "non-string risk metadata is rejected without a validator crash"
else
  fail "non-string risk metadata is rejected without a validator crash" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

OPAQUE_PAYLOAD_PATH="$TMP/payload-smuggling-handle/events.jsonl"
OPAQUE_PAYLOAD_STATUS="$TMP/payload-smuggling-handle/status.json"
mkdir -p "$(dirname "$OPAQUE_PAYLOAD_STATUS")"
printf '{"state":"running"}\n' > "$OPAQUE_PAYLOAD_STATUS"
append_event "$OPAQUE_PAYLOAD_PATH" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:04:02Z","run_id":"run-smuggling-handle","backend":"codex"}' >/dev/null
capture append_event "$OPAQUE_PAYLOAD_PATH" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:03Z\",\"run_id\":\"run-smuggling-handle\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$SELF_IDENTITY\",\"backend_handle\":\"function steal(){return document.cookie}\",\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_backend_handle'; then
  pass "opaque backend handles are identifiers rather than payload channels"
else
  fail "opaque backend handles are identifiers rather than payload channels" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

INVALID_PID_HANDLE_PATH="$TMP/invalid-pid-handle/events.jsonl"
append_event "$INVALID_PID_HANDLE_PATH" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:04:02Z","run_id":"run-invalid-pid-handle","backend":"codex"}' >/dev/null
capture append_event "$INVALID_PID_HANDLE_PATH" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:03Z\",\"run_id\":\"run-invalid-pid-handle\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$SELF_IDENTITY\",\"backend_handle\":0,\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_backend_handle'; then
  pass "numeric backend handles must be positive process IDs"
else
  fail "numeric backend handles must be positive process IDs" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

reserved_pid_failures=''
reserved_pid_index=0
for reserved_pid_handle in 'pid:' 'pid:0' 'pid:-1' 'pid:provider'; do
  reserved_pid_index=$((reserved_pid_index + 1))
  reserved_append_path="$TMP/reserved-pid-append-$reserved_pid_index/events.jsonl"
  reserved_route="{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:10Z\",\"run_id\":\"run-reserved-$reserved_pid_index\",\"backend\":\"codex\"}"
  reserved_start="{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:11Z\",\"run_id\":\"run-reserved-$reserved_pid_index\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$SELF_IDENTITY\",\"backend_handle\":\"$reserved_pid_handle\",\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
  append_event "$reserved_append_path" "$reserved_route" >/dev/null
  capture append_event "$reserved_append_path" "$reserved_start"
  append_reserved_rc="$CAPTURE_RC"
  append_reserved_out="$CAPTURE_OUT"

  reserved_verify_path="$TMP/reserved-pid-verify-$reserved_pid_index/events.jsonl"
  mkdir -p "$(dirname "$reserved_verify_path")"
  printf '%s\n%s\n' "$reserved_route" "$reserved_start" > "$reserved_verify_path"
  capture python3 "$MANIFEST" verify --manifest "$reserved_verify_path"
  verify_reserved_rc="$CAPTURE_RC"
  verify_reserved_out="$CAPTURE_OUT"
  reserved_lines_before="$(wc -l < "$reserved_verify_path" | tr -d ' ')"
  capture python3 "$MANIFEST" reconcile --manifest "$reserved_verify_path"
  reconcile_reserved_rc="$CAPTURE_RC"
  reconcile_reserved_out="$CAPTURE_OUT"
  reserved_lines_after="$(wc -l < "$reserved_verify_path" | tr -d ' ')"

  if [ "$append_reserved_rc" -ne 2 ] || ! printf '%s' "$append_reserved_out" | grep -q invalid_backend_handle \
     || [ "$verify_reserved_rc" -ne 1 ] || ! printf '%s' "$verify_reserved_out" | grep -q invalid_backend_handle \
     || [ "$reconcile_reserved_rc" -ne 2 ] || ! printf '%s' "$reconcile_reserved_out" | grep -q invalid_backend_handle \
     || [ "$reserved_lines_before" -ne "$reserved_lines_after" ]; then
    reserved_pid_failures="$reserved_pid_failures $reserved_pid_handle(append:$append_reserved_rc,verify:$verify_reserved_rc,reconcile:$reconcile_reserved_rc,lines:$reserved_lines_before/$reserved_lines_after)"
  fi
done
if [ -z "$reserved_pid_failures" ]; then
  pass "append, verify, and reconcile reserve pid: for positive decimal process IDs"
else
  fail "append, verify, and reconcile reserve pid: for positive decimal process IDs" "$reserved_pid_failures"
fi

ATOMIC_PATH="$TMP/atomic/events.jsonl"
pids=""
i=1
while [ "$i" -le 24 ]; do
  append_event "$ATOMIC_PATH" "{\"schema_version\":2,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:05:00Z\",\"run_id\":\"run-atomic-$i\",\"backend\":\"codex\"}" >/dev/null 2>&1 &
  pids="$pids $!"
  i=$((i + 1))
done
atomic_rc=0
for pid in $pids; do wait "$pid" || atomic_rc=1; done
capture python3 "$MANIFEST" verify --manifest "$ATOMIC_PATH"
atomic_lines="$(wc -l < "$ATOMIC_PATH" | tr -d ' ')"
if [ "$atomic_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ] && [ "$atomic_lines" -eq 24 ]; then
  pass "concurrent appends remain 24 complete JSONL records"
else
  fail "concurrent appends remain 24 complete JSONL records" "append_rc=$atomic_rc verify_rc=$CAPTURE_RC lines=$atomic_lines out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/windows-lock/events.jsonl" <<'PY'
import builtins
import glob
import importlib.util
import subprocess
import sys
import types

module_path, manifest_path = sys.argv[1:]
calls = []
fake_msvcrt = types.ModuleType("msvcrt")
fake_msvcrt.LK_NBLCK = 1
fake_msvcrt.LK_UNLCK = 2
fake_msvcrt.locking = lambda fd, mode, count: calls.append((fd, mode, count))
real_import = builtins.__import__

def windows_import(name, *args, **kwargs):
    if name == "fcntl":
        raise ImportError("native Windows has no fcntl")
    if name == "msvcrt":
        return fake_msvcrt
    return real_import(name, *args, **kwargs)

builtins.__import__ = windows_import
try:
    spec = importlib.util.spec_from_file_location("run_manifest_windows_lock", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
finally:
    builtins.__import__ = real_import

original_os_name = module.os.name
original_fchmod = getattr(module.os, "fchmod", None)
real_write = module.os.write
write_fds = []
def tracked_windows_write(fd, payload):
    write_fds.append(fd)
    return real_write(fd, payload)
module.os.write = tracked_windows_write
module.os.name = "nt"
if original_fchmod is not None:
    del module.os.fchmod
try:
    result = module.append_event(manifest_path, {
        "schema_version": 2,
        "event": "route_decided",
        "timestamp": "2026-07-10T00:05:15Z",
        "run_id": "run-windows-lock",
        "backend": "codex",
    })
    assert result["status"] == "appended", result
    assert [mode for _, mode, _ in calls] == [fake_msvcrt.LK_NBLCK, fake_msvcrt.LK_UNLCK], calls
    assert all(count == 1 for _, _, count in calls), calls
    assert write_fds == [calls[0][0]], (write_fds, calls)
    verified, rc = module.verify_manifest(manifest_path, strict=False)
    assert rc == 0 and verified["events"] == 1, (rc, verified)
    generation = "a" * 32
    lease_parent = module.os.path.dirname(manifest_path)
    lease = module.os.path.join(lease_parent, f"{generation}{'b' * 32}.lease")
    lease_payload = f"generation={generation}\nrun_id=windows-lease\n".encode()
    module.secure_write_lease(lease, lease_payload)
    module.secure_write_lease(lease, lease_payload)
    with open(lease, "rb") as handle:
        assert handle.read() == lease_payload
    assert not glob.glob(module.os.path.join(lease_parent, ".lease.tmp.*"))
finally:
    module.os.name = original_os_name
    module.os.write = real_write
    if original_fchmod is not None:
        module.os.fchmod = original_fchmod
print("windows-lock-fallback-ok")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'windows-lock-fallback-ok' ]; then
  pass "manifest imports and appends with the Windows msvcrt lock backend"
else
  fail "manifest imports and appends with the Windows msvcrt lock backend" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/open-flags/events.jsonl" <<'PY'
import importlib.util
import json
import os
import sys

module_path, manifest_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("run_manifest_flags", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

real_open = module.os.open
real_write = module.os.write
open_calls = []
write_calls = []

def tracked_open(path, flags, mode=0o777, *, dir_fd=None):
    open_calls.append((path, flags, mode, dir_fd))
    return real_open(path, flags, mode, dir_fd=dir_fd)

def tracked_write(fd, payload):
    write_calls.append(bytes(payload))
    return real_write(fd, payload)

module.os.open = tracked_open
module.os.write = tracked_write
module.append_event(manifest_path, {
    "schema_version": 2,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:30Z",
    "run_id": "run-open-flags",
    "backend": "codex",
})
append_opens = [call for call in open_calls if call[1] & os.O_APPEND]
assert len(append_opens) == 1, append_opens
_, flags, mode, _ = append_opens[0]
assert flags & os.O_CREAT and flags & os.O_WRONLY and flags & os.O_NOFOLLOW, flags
assert mode == 0o600, oct(mode)
assert len(write_calls) == 1, len(write_calls)
record = write_calls[0]
assert record.endswith(b"\n") and record.count(b"\n") == 1
json.loads(record)
print("secure-open-write-ok")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'secure-open-write-ok' ]; then
  pass "append fault probe observes secure flags, mode 0600, and exactly one write"
else
  fail "append fault probe observes secure flags, mode 0600, and exactly one write" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/short-write-rollback/events.jsonl" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, manifest_text = sys.argv[1:]
manifest = Path(manifest_text)
spec = importlib.util.spec_from_file_location("run_manifest_short_write", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

module.append_event(str(manifest), {
    "schema_version": 2,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:30Z",
    "run_id": "run-before-short-write",
    "backend": "codex",
})
before = manifest.read_bytes()
real_write = module.os.write
payload_writes = 0

def half_write(fd, payload):
    global payload_writes
    payload_writes += 1
    partial = payload[: max(1, len(payload) // 2)]
    return real_write(fd, partial)

module.os.write = half_write
try:
    module.append_event(str(manifest), {
        "schema_version": 2,
        "event": "route_decided",
        "timestamp": "2026-07-10T00:05:31Z",
        "run_id": "run-short-write",
        "backend": "codex",
    })
except module.ManifestRuntimeError as exc:
    assert str(exc) == "manifest_short_write", str(exc)
else:
    raise AssertionError("short write unexpectedly succeeded")
finally:
    module.os.write = real_write

assert payload_writes == 1, payload_writes
assert manifest.read_bytes() == before
result, return_code = module.verify_manifest(str(manifest), strict=False)
assert return_code == 0, result
assert result == {"events": 1, "runs": 1, "status": "ok"}, result
print("short-write-rolled-back")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'short-write-rolled-back' ]; then
  pass "short manifest write truncates back to the locked original length"
else
  fail "short manifest write truncates back to the locked original length" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/ancestor-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
victim = outside / "events.jsonl"
victim.write_text("unchanged\n", encoding="utf-8")
manifest = safe / "events.jsonl"

spec = importlib.util.spec_from_file_location("run_manifest_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    path_text = os.fspath(path)
    if not swapped and path_text == os.fspath(manifest):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
        return real_open(path, flags, mode, dir_fd=dir_fd)
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and path_text == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
try:
    module.append_event(str(manifest), {
        "schema_version": 2,
        "event": "route_decided",
        "timestamp": "2026-07-10T00:05:31Z",
        "run_id": "run-ancestor-swap",
        "backend": "codex",
    })
except (module.ManifestRejected, module.ManifestRuntimeError):
    pass
assert swapped
assert victim.read_text(encoding="utf-8") == "unchanged\n"
print("ancestor-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'ancestor-swap-contained' ]; then
  pass "manifest append contains an ancestor symlink replacement"
else
  fail "manifest append contains an ancestor symlink replacement" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/realpath-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
manifest = safe / "events.jsonl"

spec = importlib.util.spec_from_file_location("run_manifest_realpath_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_realpath = module.os.path.realpath

def attacked_realpath(path):
    if os.path.abspath(os.fspath(path)) == os.fspath(safe):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        try:
            return real_realpath(path)
        finally:
            safe.unlink()
            moved.rename(safe)
    return real_realpath(path)

module.os.path.realpath = attacked_realpath
module.append_event(str(manifest), {
    "schema_version": 2,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:32Z",
    "run_id": "run-realpath-swap",
    "backend": "codex",
})
assert manifest.is_file()
assert not (outside / "events.jsonl").exists()
print("realpath-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'realpath-swap-contained' ]; then
  pass "manifest open cannot be redirected during path canonicalization"
else
  fail "manifest open cannot be redirected during path canonicalization" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/status-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
(safe / "status.json").write_text('{"state":"running"}\n', encoding="utf-8")
(outside / "status.json").write_text('{"state":"completed"}\n', encoding="utf-8")

spec = importlib.util.spec_from_file_location("run_manifest_status_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and os.fspath(path) == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
assert module.probe_status_file(str(safe / "status.json")) == "live"
assert swapped
print("status-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'status-swap-contained' ]; then
  pass "status probe contains an ancestor symlink replacement"
else
  fail "status probe contains an ancestor symlink replacement" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/lease-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
generation = "a" * 32
name = generation + "b" * 32 + ".lease"
payload = (
    "version=1\n"
    f"generation={generation}\n"
    "run_id=run-swap\nowner_pid=1\nbackend_handle=\n"
    "start_epoch=1\ntimeout_s=5\nstatus_path=\n"
).encode()

spec = importlib.util.spec_from_file_location("run_manifest_lease_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and os.fspath(path) == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
module.secure_write_lease(str(safe / name), payload)
assert swapped
assert not (outside / name).exists()
assert (moved / name).is_file()
print("lease-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'lease-swap-contained' ]; then
  pass "lease publication contains an ancestor replacement around atomic rename"
else
  fail "lease publication contains an ancestor replacement around atomic rename" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

VICTIM="$TMP/manifest-victim"
printf 'unchanged\n' > "$VICTIM"
mkdir -p "$TMP/manifest-link"
ln -s "$VICTIM" "$TMP/manifest-link/events.jsonl"
capture append_event "$TMP/manifest-link/events.jsonl" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:06:00Z","run_id":"run-link","backend":"codex"}'
if [ "$CAPTURE_RC" -ne 0 ] && [ "$(cat "$VICTIM")" = "unchanged" ]; then
  pass "manifest symlink target is rejected"
else
  fail "manifest symlink target is rejected" "rc=$CAPTURE_RC victim=$(cat "$VICTIM")"
fi

mkdir "$TMP/manifest-ancestor-target"
ln -s "$TMP/manifest-ancestor-target" "$TMP/manifest-ancestor-link"
capture append_event "$TMP/manifest-ancestor-link/private/events.jsonl" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:06:01Z","run_id":"run-ancestor-link","backend":"codex"}'
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -e "$TMP/manifest-ancestor-target/private/events.jsonl" ]; then
  pass "manifest rejects a symlinked ancestor path"
else
  fail "manifest rejects a symlinked ancestor path" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '== run manifest: conservative orphan reconciliation ==\n'
sleep 0.01 & dead_pid=$!
wait "$dead_pid"
dead_identity="$(identity_for_pid "$dead_pid")"
ORPHAN="$TMP/orphan/events.jsonl"
append_event "$ORPHAN" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:00Z","run_id":"run-orphan","backend":"codex"}' >/dev/null
append_event "$ORPHAN" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:01Z\",\"run_id\":\"run-orphan\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$ORPHAN"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "reconcile abandons when owner and backend handle are both dead"
else
  fail "reconcile abandons when owner and backend handle are both dead" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" reconcile --manifest "$ORPHAN"
terminal_count="$(grep -c '"event":"abandoned"' "$ORPHAN" || true)"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":0,"status":"ok"}' ] && [ "$terminal_count" -eq 1 ]; then
  pass "reconcile is idempotent and never duplicates a terminal"
else
  fail "reconcile is idempotent and never duplicates a terminal" "rc=$CAPTURE_RC terminals=$terminal_count out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" verify --manifest "$ORPHAN" --strict
[ "$CAPTURE_RC" -eq 0 ] && pass "reconciled orphan has exactly one terminal" || fail "reconciled orphan has exactly one terminal" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

printf '== run manifest: canonical terminal status reconciliation ==\n'
TRUE_COMPLETED_STATUS="$TMP/true-completed/status.json"
TRUE_COMPLETED_MANIFEST="$TMP/true-completed/events.jsonl"
mkdir -p "$(dirname "$TRUE_COMPLETED_STATUS")"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s","ignored":"not-manifest-data"}\n' "$dead_pid" > "$TRUE_COMPLETED_STATUS"
append_event "$TRUE_COMPLETED_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:10Z","run_id":"run-true-completed","backend":"codex"}' >/dev/null
append_event "$TRUE_COMPLETED_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:11Z\",\"run_id\":\"run-true-completed\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$TRUE_COMPLETED_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_COMPLETED_MANIFEST"
completed_reconcile_rc="$CAPTURE_RC"
completed_reconcile_out="$CAPTURE_OUT"
completed_terminal="$(tail -n 1 "$TRUE_COMPLETED_MANIFEST")"
if [ "$completed_reconcile_rc" -eq 0 ] \
   && [ "$completed_reconcile_out" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && printf '%s' "$completed_terminal" | grep -q '"event":"completed"' \
   && ! printf '%s' "$completed_terminal" | grep -q 'ignored'; then
  pass "reconcile consumes canonical completed status without copying arbitrary fields"
else
  fail "reconcile consumes canonical completed status without copying arbitrary fields" "rc=$completed_reconcile_rc out=$completed_reconcile_out terminal=$completed_terminal"
fi

TRUE_FAILED_STATUS="$TMP/true-failed/status.json"
TRUE_FAILED_MANIFEST="$TMP/true-failed/events.jsonl"
mkdir -p "$(dirname "$TRUE_FAILED_STATUS")"
printf '{"backend":"codex","state":"failed","exit_code":17,"pid":"%s"}\n' "$dead_pid" > "$TRUE_FAILED_STATUS"
append_event "$TRUE_FAILED_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:20Z","run_id":"run-true-failed","backend":"codex"}' >/dev/null
append_event "$TRUE_FAILED_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:21Z\",\"run_id\":\"run-true-failed\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$TRUE_FAILED_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_FAILED_MANIFEST"
failed_reconcile_rc="$CAPTURE_RC"
failed_reconcile_out="$CAPTURE_OUT"
failed_terminal="$(tail -n 1 "$TRUE_FAILED_MANIFEST")"
if [ "$failed_reconcile_rc" -eq 0 ] \
   && [ "$failed_reconcile_out" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && printf '%s' "$failed_terminal" | grep -q '"event":"failed"' \
   && printf '%s' "$failed_terminal" | grep -q '"error_class":"provider_failed"'; then
  pass "reconcile consumes canonical failed status with validated nonzero exit"
else
  fail "reconcile consumes canonical failed status with validated nonzero exit" "rc=$failed_reconcile_rc out=$failed_reconcile_out terminal=$failed_terminal"
fi

HANDLELESS_TERMINAL_STATUS="$TMP/handleless-terminal/status.json"
mkdir -p "$(dirname "$HANDLELESS_TERMINAL_STATUS")"
invalid_handleless_terminal_cases=(
  'boolean-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":true}'
  'zero-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":0}'
  'negative-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":-1}'
  'float-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":1.5}'
  'empty-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":""}'
  'malformed-pid|{"backend":"codex","state":"completed","exit_code":0,"pid":"not a pid"}'
  'multiple-handles|{"backend":"codex","state":"completed","exit_code":0,"pid":"41","backend_handle":"41"}'
  'malformed-backend-handle|{"backend":"codex","state":"completed","exit_code":0,"backend_handle":{}}'
)
invalid_handleless_terminal_accepted=""
for invalid_handleless_terminal_case in "${invalid_handleless_terminal_cases[@]}"; do
  invalid_handleless_terminal_name="${invalid_handleless_terminal_case%%|*}"
  invalid_handleless_terminal_payload="${invalid_handleless_terminal_case#*|}"
  printf '%s\n' "$invalid_handleless_terminal_payload" > "$HANDLELESS_TERMINAL_STATUS"
  capture python3 "$MANIFEST" probe-terminal \
    --status-path "$HANDLELESS_TERMINAL_STATUS" --expected-backend codex
  if [ "$CAPTURE_RC" -ne 0 ] || [ "$CAPTURE_OUT" != unknown ]; then
    invalid_handleless_terminal_accepted="${invalid_handleless_terminal_accepted}${invalid_handleless_terminal_name}:${CAPTURE_RC}/${CAPTURE_OUT} "
  fi
done
if [ -z "$invalid_handleless_terminal_accepted" ]; then
  pass "handle-less starts reject every malformed reported terminal handle"
else
  fail "handle-less starts reject every malformed reported terminal handle" "$invalid_handleless_terminal_accepted"
fi

valid_handleless_terminal_results=""
for valid_handleless_terminal_case in \
  '{"backend":"codex","state":"completed","exit_code":0}' \
  '{"backend":"codex","state":"completed","exit_code":0,"pid":"41"}' \
  '{"backend":"codex","state":"completed","exit_code":0,"backend_handle":"provider-job-41"}'; do
  printf '%s\n' "$valid_handleless_terminal_case" > "$HANDLELESS_TERMINAL_STATUS"
  capture python3 "$MANIFEST" probe-terminal \
    --status-path "$HANDLELESS_TERMINAL_STATUS" --expected-backend codex
  valid_handleless_terminal_results="${valid_handleless_terminal_results}${CAPTURE_RC}/${CAPTURE_OUT} "
done
printf '%s\n' '{"backend":"codex","state":"completed","exit_code":0,"pid":"42"}' > "$HANDLELESS_TERMINAL_STATUS"
capture python3 "$MANIFEST" probe-terminal \
  --status-path "$HANDLELESS_TERMINAL_STATUS" --expected-backend codex \
  --expected-handle 41
if [ "$valid_handleless_terminal_results" = '0/completed 0/completed 0/completed ' ] \
   && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = unknown ]; then
  pass "valid missing, numeric, and opaque terminal handles work while mismatches reject"
else
  fail "valid missing, numeric, and opaque terminal handles work while mismatches reject" "valid=$valid_handleless_terminal_results mismatch=$CAPTURE_RC/$CAPTURE_OUT"
fi

before_true_terminal_lines="$(wc -l < "$TRUE_COMPLETED_MANIFEST" | tr -d ' ')"
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_COMPLETED_MANIFEST"
after_true_terminal_lines="$(wc -l < "$TRUE_COMPLETED_MANIFEST" | tr -d ' ')"
if [ "$CAPTURE_RC" -eq 0 ] \
   && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && [ "$before_true_terminal_lines" -eq "$after_true_terminal_lines" ]; then
  pass "canonical terminal reconciliation is idempotent"
else
  fail "canonical terminal reconciliation is idempotent" "rc=$CAPTURE_RC lines=$before_true_terminal_lines/$after_true_terminal_lines out=$CAPTURE_OUT"
fi

# Terminal-shaped status that fails backend or exit-code validation is
# unavailable evidence. It cannot override a proven-live numeric backend PID,
# but the orphan may be abandoned after that PID actually exits.
sleep 30 & invalid_terminal_backend=$!
INVALID_BACKEND_STATUS="$TMP/invalid-terminal-backend/status.json"
INVALID_BACKEND_MANIFEST="$TMP/invalid-terminal-backend/events.jsonl"
mkdir -p "$(dirname "$INVALID_BACKEND_STATUS")"
printf '{"backend":"background","state":"completed","exit_code":0,"pid":"%s"}\n' "$invalid_terminal_backend" > "$INVALID_BACKEND_STATUS"
append_event "$INVALID_BACKEND_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:25Z","run_id":"run-invalid-terminal-backend","backend":"codex"}' >/dev/null
append_event "$INVALID_BACKEND_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:26Z\",\"run_id\":\"run-invalid-terminal-backend\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$invalid_terminal_backend\",\"status_path\":\"$INVALID_BACKEND_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$INVALID_BACKEND_MANIFEST"
invalid_backend_live_rc="$CAPTURE_RC"
invalid_backend_live_out="$CAPTURE_OUT"
invalid_backend_live_lines="$(wc -l < "$INVALID_BACKEND_MANIFEST" | tr -d ' ')"
if [ "$invalid_backend_live_rc" -eq 0 ] \
   && [ "$invalid_backend_live_out" = '{"abandoned":0,"open":1,"status":"ok"}' ] \
   && [ "$invalid_backend_live_lines" -eq 2 ]; then
  pass "backend-mismatched terminal status cannot override a live numeric handle"
else
  fail "backend-mismatched terminal status cannot override a live numeric handle" "rc=$invalid_backend_live_rc out=$invalid_backend_live_out lines=$invalid_backend_live_lines"
fi

INVALID_EXIT_STATUS="$TMP/invalid-terminal-exit/status.json"
INVALID_EXIT_MANIFEST="$TMP/invalid-terminal-exit/events.jsonl"
mkdir -p "$(dirname "$INVALID_EXIT_STATUS")"
printf '{"backend":"codex","state":"completed","exit_code":9,"pid":"%s"}\n' "$invalid_terminal_backend" > "$INVALID_EXIT_STATUS"
append_event "$INVALID_EXIT_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:27Z","run_id":"run-invalid-terminal-exit","backend":"codex"}' >/dev/null
append_event "$INVALID_EXIT_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:28Z\",\"run_id\":\"run-invalid-terminal-exit\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$invalid_terminal_backend\",\"status_path\":\"$INVALID_EXIT_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$INVALID_EXIT_MANIFEST"
invalid_exit_live_rc="$CAPTURE_RC"
invalid_exit_live_out="$CAPTURE_OUT"
invalid_exit_live_lines="$(wc -l < "$INVALID_EXIT_MANIFEST" | tr -d ' ')"
if [ "$invalid_exit_live_rc" -eq 0 ] \
   && [ "$invalid_exit_live_out" = '{"abandoned":0,"open":1,"status":"ok"}' ] \
   && [ "$invalid_exit_live_lines" -eq 2 ]; then
  pass "contradictory completed exit code cannot override a live numeric handle"
else
  fail "contradictory completed exit code cannot override a live numeric handle" "rc=$invalid_exit_live_rc out=$invalid_exit_live_out lines=$invalid_exit_live_lines"
fi

kill "$invalid_terminal_backend" 2>/dev/null || true
wait "$invalid_terminal_backend" 2>/dev/null || true
capture python3 "$MANIFEST" reconcile --manifest "$INVALID_BACKEND_MANIFEST"
invalid_backend_dead_rc="$CAPTURE_RC"
invalid_backend_dead_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" reconcile --manifest "$INVALID_EXIT_MANIFEST"
invalid_exit_dead_rc="$CAPTURE_RC"
invalid_exit_dead_out="$CAPTURE_OUT"
if [ "$invalid_backend_dead_rc" -eq 0 ] \
   && [ "$invalid_backend_dead_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$invalid_exit_dead_rc" -eq 0 ] \
   && [ "$invalid_exit_dead_out" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "invalid terminal shapes become abandonable only after numeric handle death"
else
  fail "invalid terminal shapes become abandonable only after numeric handle death" "backend=$invalid_backend_dead_rc/$invalid_backend_dead_out exit=$invalid_exit_dead_rc/$invalid_exit_dead_out"
fi

printf '== run manifest: numeric handle recovery from canonical status ==\n'
sleep 30 & recovered_live_pid=$!
RECOVERED_LIVE_STATUS="$TMP/recovered-live/status.json"
RECOVERED_LIVE_MANIFEST="$TMP/recovered-live/events.jsonl"
mkdir -p "$(dirname "$RECOVERED_LIVE_STATUS")"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$recovered_live_pid" > "$RECOVERED_LIVE_STATUS"
append_event "$RECOVERED_LIVE_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:50Z","run_id":"run-recovered-live","backend":"codex"}' >/dev/null
append_event "$RECOVERED_LIVE_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:51Z\",\"run_id\":\"run-recovered-live\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"status_path\":\"$RECOVERED_LIVE_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_LIVE_MANIFEST"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":1,"status":"ok"}' ]; then
  pass "canonical numeric status handle keeps a live wrapper open"
else
  fail "canonical numeric status handle keeps a live wrapper open" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

RECOVERED_DEAD_STATUS="$TMP/recovered-dead/status.json"
RECOVERED_DEAD_MANIFEST="$TMP/recovered-dead/events.jsonl"
mkdir -p "$(dirname "$RECOVERED_DEAD_STATUS")"
printf '{"backend":"background","state":"running","exit_code":null,"pid":"%s"}\n' "$dead_pid" > "$RECOVERED_DEAD_STATUS"
append_event "$RECOVERED_DEAD_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:52Z","run_id":"run-recovered-dead","backend":"background"}' >/dev/null
append_event "$RECOVERED_DEAD_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:53Z\",\"run_id\":\"run-recovered-dead\",\"backend\":\"background\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"status_path\":\"$RECOVERED_DEAD_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_DEAD_MANIFEST"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "stale running status with a dead recovered wrapper is abandoned"
else
  fail "stale running status with a dead recovered wrapper is abandoned" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

RECOVERED_MISMATCH_STATUS="$TMP/recovered-mismatch/status.json"
RECOVERED_MISMATCH_MANIFEST="$TMP/recovered-mismatch/events.jsonl"
mkdir -p "$(dirname "$RECOVERED_MISMATCH_STATUS")"
printf '{"backend":"background","state":"running","exit_code":null,"pid":"%s"}\n' "$recovered_live_pid" > "$RECOVERED_MISMATCH_STATUS"
append_event "$RECOVERED_MISMATCH_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:54Z","run_id":"run-recovered-mismatch","backend":"codex"}' >/dev/null
append_event "$RECOVERED_MISMATCH_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:55Z\",\"run_id\":\"run-recovered-mismatch\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"status_path\":\"$RECOVERED_MISMATCH_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_MISMATCH_MANIFEST"
mismatch_handle_out="$CAPTURE_OUT"

RECOVERED_MALFORMED_STATUS="$TMP/recovered-malformed/status.json"
RECOVERED_MALFORMED_MANIFEST="$TMP/recovered-malformed/events.jsonl"
mkdir -p "$(dirname "$RECOVERED_MALFORMED_STATUS")"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":true}\n' > "$RECOVERED_MALFORMED_STATUS"
append_event "$RECOVERED_MALFORMED_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:56Z","run_id":"run-recovered-malformed","backend":"codex"}' >/dev/null
append_event "$RECOVERED_MALFORMED_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:57Z\",\"run_id\":\"run-recovered-malformed\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"status_path\":\"$RECOVERED_MALFORMED_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_MALFORMED_MANIFEST"
malformed_handle_out="$CAPTURE_OUT"
if [ "$mismatch_handle_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$malformed_handle_out" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "mismatched and malformed recovered handles are unavailable evidence"
else
  fail "mismatched and malformed recovered handles are unavailable evidence" "mismatch=$mismatch_handle_out malformed=$malformed_handle_out"
fi

kill "$recovered_live_pid" 2>/dev/null || true
wait "$recovered_live_pid" 2>/dev/null || true
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_LIVE_MANIFEST"
recovered_dead_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" reconcile --manifest "$RECOVERED_LIVE_MANIFEST"
if [ "$recovered_dead_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":0,"status":"ok"}' ]; then
  pass "recovered numeric wrapper abandons after death exactly once"
else
  fail "recovered numeric wrapper abandons after death exactly once" "first=$recovered_dead_out second=$CAPTURE_OUT"
fi

MALFORMED_TRUTH_STATUS="$TMP/malformed-truth/status.json"
MALFORMED_TRUTH_MANIFEST="$TMP/malformed-truth/events.jsonl"
mkdir -p "$(dirname "$MALFORMED_TRUTH_STATUS")"
printf '{not-json\n' > "$MALFORMED_TRUTH_STATUS"
append_event "$MALFORMED_TRUTH_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:30Z","run_id":"run-malformed-truth","backend":"codex"}' >/dev/null
append_event "$MALFORMED_TRUTH_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:31Z\",\"run_id\":\"run-malformed-truth\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$MALFORMED_TRUTH_STATUS\"}" >/dev/null
malformed_lines_before="$(wc -l < "$MALFORMED_TRUTH_MANIFEST" | tr -d ' ')"
capture python3 "$MANIFEST" reconcile --manifest "$MALFORMED_TRUTH_MANIFEST"
malformed_rc="$CAPTURE_RC"
malformed_lines_after="$(wc -l < "$MALFORMED_TRUTH_MANIFEST" | tr -d ' ')"
malformed_terminal="$(tail -n 1 "$MALFORMED_TRUTH_MANIFEST")"

UNKNOWN_TRUTH_STATUS="$TMP/unknown-truth/status.json"
UNKNOWN_TRUTH_MANIFEST="$TMP/unknown-truth/events.jsonl"
mkdir -p "$(dirname "$UNKNOWN_TRUTH_STATUS")"
printf '{"backend":"codex","state":"future-state","exit_code":0}\n' > "$UNKNOWN_TRUTH_STATUS"
append_event "$UNKNOWN_TRUTH_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:07:40Z","run_id":"run-unknown-truth","backend":"codex"}' >/dev/null
append_event "$UNKNOWN_TRUTH_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:41Z\",\"run_id\":\"run-unknown-truth\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$UNKNOWN_TRUTH_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$UNKNOWN_TRUTH_MANIFEST"
unknown_terminal="$(tail -n 1 "$UNKNOWN_TRUTH_MANIFEST")"
if [ "$malformed_rc" -eq 0 ] \
   && [ "$malformed_lines_after" -eq $((malformed_lines_before + 1)) ] \
   && printf '%s' "$malformed_terminal" | grep -q '"event":"abandoned"' \
   && ! printf '%s' "$unknown_terminal" | grep -Eq '"event":"(completed|failed|timed_out|cancelled)"'; then
  pass "malformed and unknown status are unavailable and never provider terminal truth"
else
  fail "malformed and unknown status are unavailable and never provider terminal truth" "malformed_rc=$malformed_rc lines=$malformed_lines_before/$malformed_lines_after malformed=$malformed_terminal unknown=$unknown_terminal"
fi

FUTURE_TRUE_STATUS="$TMP/future-true/status.json"
FUTURE_TRUE_MANIFEST="$TMP/future-true/events.jsonl"
mkdir -p "$(dirname "$FUTURE_TRUE_STATUS")"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s"}\n' "$dead_pid" > "$FUTURE_TRUE_STATUS"
append_event "$FUTURE_TRUE_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2099-01-01T00:00:10Z","run_id":"run-future-true","backend":"codex"}' >/dev/null
append_event "$FUTURE_TRUE_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2099-01-01T00:00:11.999999Z\",\"run_id\":\"run-future-true\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$FUTURE_TRUE_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$FUTURE_TRUE_MANIFEST"
future_true_rc="$CAPTURE_RC"
capture python3 "$MANIFEST" verify --manifest "$FUTURE_TRUE_MANIFEST" --strict
future_true_terminal="$(tail -n 1 "$FUTURE_TRUE_MANIFEST")"
if [ "$future_true_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ] \
   && printf '%s' "$future_true_terminal" | grep -q '"event":"completed"'; then
  pass "reconciled provider terminal timestamp is never before agent start"
else
  fail "reconciled provider terminal timestamp is never before agent start" "reconcile_rc=$future_true_rc verify=$CAPTURE_RC/$CAPTURE_OUT terminal=$future_true_terminal"
fi

FUTURE_ORPHAN="$TMP/future-orphan/events.jsonl"
append_event "$FUTURE_ORPHAN" '{"schema_version":2,"event":"route_decided","timestamp":"2099-01-01T00:00:00Z","run_id":"run-future-orphan","backend":"codex"}' >/dev/null
append_event "$FUTURE_ORPHAN" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2099-01-01T00:00:01.999999Z\",\"run_id\":\"run-future-orphan\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$FUTURE_ORPHAN"
future_reconcile_rc="$CAPTURE_RC"
future_reconcile_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" verify --manifest "$FUTURE_ORPHAN" --strict
if [ "$future_reconcile_rc" -eq 0 ] \
   && [ "$future_reconcile_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$CAPTURE_RC" -eq 0 ]; then
  pass "reconcile never appends a terminal timestamp before a future-dated start"
else
  fail "reconcile never appends a terminal timestamp before a future-dated start" "reconcile=$future_reconcile_rc/$future_reconcile_out verify=$CAPTURE_RC/$CAPTURE_OUT"
fi

CONSERVATIVE="$TMP/conservative/events.jsonl"
sleep 5 & live_backend=$!
append_event "$CONSERVATIVE" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:08:00Z","run_id":"run-owner-live","backend":"codex"}' >/dev/null
append_event "$CONSERVATIVE" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:08:01Z\",\"run_id\":\"run-owner-live\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$SELF_IDENTITY\",\"backend_handle\":\"$dead_pid\"}" >/dev/null
append_event "$CONSERVATIVE" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:08:02Z","run_id":"run-backend-live","backend":"codex"}' >/dev/null
append_event "$CONSERVATIVE" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:08:03Z\",\"run_id\":\"run-backend-live\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$live_backend\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$CONSERVATIVE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":2,"status":"ok"}' ]; then
  pass "reconcile preserves a run when either owner or backend is live"
else
  fail "reconcile preserves a run when either owner or backend is live" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
kill "$live_backend" 2>/dev/null || true
wait "$live_backend" 2>/dev/null || true
capture python3 "$MANIFEST" reconcile --manifest "$CONSERVATIVE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":1,"status":"ok"}' ]; then
  pass "backend-live orphan is abandoned only after its handle dies"
else
  fail "backend-live orphan is abandoned only after its handle dies" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

PID_REUSE_STATUS="$TMP/pid-reuse/status.json"
PID_REUSE_MANIFEST="$TMP/pid-reuse/events.jsonl"
mkdir -p "$(dirname "$PID_REUSE_STATUS")"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s","process_identity":"%s|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' \
  "$$" \
  "$$" >"$PID_REUSE_STATUS"
append_event "$PID_REUSE_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:08:10Z","run_id":"run-pid-reuse","backend":"codex"}' >/dev/null
append_event "$PID_REUSE_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:08:11Z\",\"run_id\":\"run-pid-reuse\",\"backend\":\"codex\",\"owner_pid\":$$,\"owner_process_identity\":\"$$|1|1|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"status_path\":\"$PID_REUSE_STATUS\"}" >/dev/null
PID_REUSE_BIN="$TMP/pid-reuse/bin"
mkdir -p "$PID_REUSE_BIN"
printf '#!/bin/sh\ncase "$2" in\n  stat=) printf "S\\n" ;;\n  lstart=) printf "Thu Jul 23 12:00:00 2026\\n" ;;\n  *) exit 2 ;;\nesac\n' >"$PID_REUSE_BIN/ps"
chmod 700 "$PID_REUSE_BIN/ps"
capture env PATH="$PID_REUSE_BIN:$PATH" python3 "$MANIFEST" reconcile --manifest "$PID_REUSE_MANIFEST"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "reconcile treats owner and backend PID identity mismatches as dead"
else
  fail "reconcile treats owner and backend PID identity mismatches as dead" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

STALE_STATUS="$TMP/stale-running-status.json"
printf '{"state":"running"}\n' > "$STALE_STATUS"
STALE_STATUS_MANIFEST="$TMP/stale-status/events.jsonl"
append_event "$STALE_STATUS_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:09:00Z","run_id":"run-stale-status","backend":"codex"}' >/dev/null
append_event "$STALE_STATUS_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:09:01Z\",\"run_id\":\"run-stale-status\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"$dead_pid\",\"status_path\":\"$STALE_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$STALE_STATUS_MANIFEST"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "stale running status cannot override failed owner and backend-handle probes"
else
  fail "stale running status cannot override failed owner and backend-handle probes" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

DELETED_STATUS="$TMP/deleted-status.json"
printf '{"state":"running"}\n' > "$DELETED_STATUS"
DELETED_STATUS_MANIFEST="$TMP/deleted-status/events.jsonl"
append_event "$DELETED_STATUS_MANIFEST" '{"schema_version":2,"event":"route_decided","timestamp":"2026-07-10T00:10:00Z","run_id":"run-deleted-status","backend":"codex"}' >/dev/null
append_event "$DELETED_STATUS_MANIFEST" "{\"schema_version\":2,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:10:01Z\",\"run_id\":\"run-deleted-status\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"owner_process_identity\":\"$dead_identity\",\"backend_handle\":\"provider-job-123\",\"status_path\":\"$DELETED_STATUS\"}" >/dev/null
rm -f "$DELETED_STATUS"
capture python3 "$MANIFEST" reconcile --manifest "$DELETED_STATUS_MANIFEST"
deleted_reconcile_rc="$CAPTURE_RC"
deleted_reconcile_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" verify --manifest "$DELETED_STATUS_MANIFEST" --strict
if [ "$deleted_reconcile_rc" -eq 0 ] \
   && [ "$deleted_reconcile_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$CAPTURE_RC" -eq 0 ]; then
  pass "deleted opaque-backend status is unavailable evidence, not a recovery wedge"
else
  fail "deleted opaque-backend status is unavailable evidence, not a recovery wedge" "reconcile=$deleted_reconcile_rc/$deleted_reconcile_out verify=$CAPTURE_RC/$CAPTURE_OUT"
fi

printf '\nrun-manifest: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
