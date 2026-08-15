#!/usr/bin/env bash
# Direct coverage for plugins/uberdev/lib/atomic_move.py.
#
# WHY THIS FILE EXISTS (#381). The module's only direct fixture used to live in
# tests/worktree-receipts.test.sh, which #381 deleted along with the Codex
# distribution it existed to mirror-check. atomic_move.py itself is NOT
# codex-scoped: it still ships, it is still required by tools/prkit/manifest.txt,
# and lib/code_fixer_contract.py and lib/planning_research_output.py both load it
# for every artifact publication. Deleting the mirror check must not silently
# delete the primitive's coverage with it, so the ~80 atomic-move-only lines are
# ported here, verbatim in intent, with the mirror assertions dropped (there is
# one tree now) and the receipt fixtures dropped (this file needs none).
#
# What it locks: no-overwrite semantics and non-mutation on collision, the
# missing-source error class, `_native_call` errno normalization (a zero ctypes
# errno -> EIO, an unsupported flag -> ENOTSUP), cross-parent refusal, the
# `require_atomic_rename_noreplace_support()` capability preflight failing closed
# on an unsupported host, and the whole `_windows_move_noreplace` /
# `_mapped_windows_error` family (modeled on every host, and exercised for real
# on windows-latest).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ATOMIC="$ROOT/plugins/uberdev/lib/atomic_move.py"
. "$ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }
TMP="$(mktemp -d "$ROOT/tests/_fixtures/atomic-move.XXXXXX")"
trap '_floor_rc=$?; chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; uberdev_test_exit_floor atomic-move "$_floor_rc"' EXIT
chmod 700 "$TMP"

fail() { printf 'atomic-move: FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$ATOMIC" ] || fail 'atomic_move.py is missing'

python3 -I -B - "$ATOMIC" "$TMP" <<'PY'
import errno
import importlib.util
import pathlib
import sys

atomic_path, raw_root = sys.argv[1:]
root = pathlib.Path(raw_root)

PASS = 0


def ok(label):
    global PASS
    PASS += 1
    print(f"  PASS  {label}")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


atomic = load("atomic_move_contract", atomic_path)

UNSUPPORTED = {getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), errno.EOPNOTSUPP}

# A1 -- the shared primitive is genuinely no-overwrite and never mutates either
# carrier on collision.
move_dir = root / "atomic"
move_dir.mkdir()
source = move_dir / "source"
destination = move_dir / "destination"
source.write_bytes(b"source")
destination.write_bytes(b"destination")
try:
    atomic.atomic_rename_noreplace(str(source), str(destination))
except FileExistsError:
    pass
else:
    raise AssertionError("no-overwrite primitive replaced a collision")
assert source.read_bytes() == b"source"
assert destination.read_bytes() == b"destination"
ok("A1 collision raises FileExistsError and mutates neither carrier")

# A2 -- and it does move when the destination is free.
destination.unlink()
atomic.atomic_rename_noreplace(str(source), str(destination))
assert not source.exists() and destination.read_bytes() == b"source"
ok("A2 a free destination is moved atomically")

# A3 -- a missing source is FileNotFoundError, not a generic OSError.
try:
    atomic.atomic_rename_noreplace(
        str(move_dir / "missing"), str(move_dir / "missing-target")
    )
except FileNotFoundError:
    pass
else:
    raise AssertionError("missing atomic source did not fail closed")
ok("A3 a missing source raises FileNotFoundError")


class ZeroErrnoCall:
    def __call__(self, *_args):
        return -1


zero_call = ZeroErrnoCall()
saved_get_errno = atomic.ctypes.get_errno

# A4 -- a native failure that reports errno 0 must not read as success-shaped.
atomic.ctypes.get_errno = lambda: 0
try:
    try:
        atomic._native_call(zero_call, 0, "a", 0, "b", 1)
    except OSError as exc:
        assert exc.errno == errno.EIO
    else:
        raise AssertionError("zero ctypes errno was not normalized to EIO")
finally:
    atomic.ctypes.get_errno = saved_get_errno
ok("A4 _native_call normalizes a zero ctypes errno to EIO")

# A5 -- EINVAL/ENOSYS from the flag argument means "this kernel lacks the
# primitive", which must surface as ENOTSUP rather than as a caller error.
atomic.ctypes.get_errno = lambda: errno.EINVAL
try:
    try:
        atomic._native_call(zero_call, 0, "a", 0, "b", 1)
    except OSError as exc:
        assert exc.errno in UNSUPPORTED
    else:
        raise AssertionError("unsupported native rename flag was not normalized")
finally:
    atomic.ctypes.get_errno = saved_get_errno
ok("A5 _native_call normalizes an unsupported flag to ENOTSUP")

# A6 -- the two names must be siblings; a cross-parent move is refused before
# any native call, so no copy/unlink fallback can ever be reached.
other = root / "other"
other.mkdir()
(move_dir / "contained").write_bytes(b"contained")
try:
    atomic.atomic_rename_noreplace(str(move_dir / "contained"), str(other / "escape"))
except OSError as exc:
    assert exc.errno in {errno.EXDEV, errno.EINVAL}
else:
    raise AssertionError("cross-parent move was accepted")
ok("A6 a cross-parent move is refused with EXDEV/EINVAL")

# A7 -- capability preflight and the move itself both fail closed on a host
# whose platform family is not one of the three supported ones.
saved_platform = atomic.sys.platform
atomic.sys.platform = "unsupported-test-platform"
try:
    try:
        atomic.require_atomic_rename_noreplace_support()
    except OSError as exc:
        assert exc.errno in UNSUPPORTED
    else:
        raise AssertionError("unsupported host passed the capability preflight")
    try:
        atomic.atomic_rename_noreplace(
            str(move_dir / "contained"), str(move_dir / "unsupported")
        )
    except OSError as exc:
        assert exc.errno in UNSUPPORTED
    else:
        raise AssertionError("unsupported primitive did not fail closed")
finally:
    atomic.sys.platform = saved_platform
ok("A7 an unsupported platform family fails both preflight and move closed")

# A8 -- the real host DOES pass its own preflight. Without this, A7 would pass
# on a tree whose preflight always raised.
atomic.require_atomic_rename_noreplace_support()
ok("A8 this host passes require_atomic_rename_noreplace_support()")

# A9 -- Windows publication uses the native no-replace primitive with
# write-through durability. The flag contract is modeled on every host and the
# actual call is exercised by windows-latest.
windows_calls = []


class FakeMoveFileEx:
    def __call__(self, source_name, destination_name, flags):
        windows_calls.append((source_name, destination_name, flags))
        return 1


saved_windows_loader = atomic._windows_move_file_ex
saved_windows_get_error = atomic._windows_last_error
saved_windows_set_error = atomic._set_windows_last_error
atomic._windows_move_file_ex = lambda: FakeMoveFileEx()
atomic._windows_last_error = lambda: 0
atomic._set_windows_last_error = lambda _number: None
try:
    atomic._windows_move_noreplace("source", "destination")
finally:
    atomic._windows_move_file_ex = saved_windows_loader
    atomic._windows_last_error = saved_windows_get_error
    atomic._set_windows_last_error = saved_windows_set_error
assert windows_calls == [("source", "destination", 0x00000008)]
ok("A9 _windows_move_noreplace passes MOVEFILE_WRITE_THROUGH and no replace flag")

# A10 -- every mapped Windows native code keeps its errno class.
for native_code, expected_type, expected_errno in (
    (80, FileExistsError, errno.EEXIST),
    (3, FileNotFoundError, errno.ENOENT),
    (5, PermissionError, errno.EACCES),
    (32, BlockingIOError, errno.EBUSY),
    (112, OSError, errno.ENOSPC),
    (206, OSError, errno.ENAMETOOLONG),
    (50, OSError, getattr(errno, "ENOTSUP", errno.EOPNOTSUPP)),
    (0, OSError, errno.EIO),
):
    mapped = atomic._mapped_windows_error(native_code)
    assert isinstance(mapped, expected_type) and mapped.errno == expected_errno, (
        native_code,
        type(mapped),
        mapped.errno,
    )
ok("A10 _mapped_windows_error preserves the errno class for all 8 codes")

# A11 -- a Windows collision (ERROR_ALREADY_EXISTS) reaches the caller as
# FileExistsError, the same class the POSIX arm raises.
atomic._windows_move_file_ex = lambda: (lambda *_args: 0)
atomic._windows_last_error = lambda: 183
atomic._set_windows_last_error = lambda _number: None
try:
    try:
        atomic._windows_move_noreplace("source", "destination")
    except FileExistsError as exc:
        assert exc.errno == errno.EEXIST
    else:
        raise AssertionError("Windows collision was not normalized to EEXIST")
finally:
    atomic._windows_move_file_ex = saved_windows_loader
    atomic._windows_last_error = saved_windows_get_error
    atomic._set_windows_last_error = saved_windows_set_error
ok("A11 a Windows ERROR_ALREADY_EXISTS surfaces as FileExistsError")

print()
print("== Summary ==")
print(f"  passed: {PASS}")
print("  failed: 0")
PY

uberdev_test_exit_floor_reached
printf 'atomic-move: PASS\n'
