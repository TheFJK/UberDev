#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ATOMIC="$ROOT/plugins/uberdev/lib/atomic_move.py"
RECEIPTS="$ROOT/plugins/uberdev/lib/worktree_receipts.py"
PLANNING="$ROOT/plugins/uberdev/lib/planning_research_output.py"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/worktree-receipts.XXXXXX")"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

fail() { printf 'worktree-receipts: FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$ATOMIC" ] || fail 'atomic_move.py is missing'
[ -f "$RECEIPTS" ] || fail 'worktree_receipts.py is missing'

python3 -I -B - "$ATOMIC" "$RECEIPTS" "$PLANNING" "$TMP" <<'PY'
import errno
import hashlib
import importlib.util
import io
import json
import ntpath
import os
import pathlib
import shutil
import stat
import subprocess
import sys
from types import SimpleNamespace

atomic_path, receipt_path, planning_path, raw_root = sys.argv[1:]
root = pathlib.Path(raw_root)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


atomic = load("atomic_move_contract", atomic_path)
receipts = load("worktree_receipts_contract", receipt_path)


def run(*args):
    return subprocess.run(
        [sys.executable, "-I", "-B", receipt_path, *map(str, args)],
        text=True,
        capture_output=True,
        check=False,
    )


def success(result, expected_state):
    if result.returncode != 0 or result.stderr:
        raise AssertionError((result.args, result.returncode, result.stdout, result.stderr))
    value = json.loads(result.stdout)
    if value.get("state") != expected_state:
        raise AssertionError(value)
    return value


def terminal(result):
    if result.returncode != 3:
        raise AssertionError((result.args, result.returncode, result.stdout, result.stderr))
    if result.stdout or result.stderr != "uberdev worktree receipt: invalid authority\n":
        raise AssertionError((result.stdout, result.stderr))


def fixture(label, basename="status.worktree-owner.json"):
    base = root / label
    repo = base / "repo"
    private = base / "private"
    repo.mkdir(parents=True)
    private.mkdir(mode=0o700)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Fixture"], check=True)
    (repo / "seed").write_text("seed\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "seed"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "seed"], check=True)
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    relative = ".claude/worktrees/solve-issue-42-agent-0123456789ab"
    branch = "worktree-solve-issue-42-agent-0123456789ab"
    public = private / basename
    common = [
        "--repo", str(repo.resolve()), "--relative", relative,
        "--branch", branch, "--receipt", str(public.resolve()),
        "--start-head", head,
    ]
    return repo.resolve(), private.resolve(), public.resolve(), head, relative, branch, common


# The shared primitive is genuinely no-overwrite and never mutates either
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
destination.unlink()
atomic.atomic_rename_noreplace(str(source), str(destination))
assert not source.exists() and destination.read_bytes() == b"source"
try:
    atomic.atomic_rename_noreplace(str(move_dir / "missing"), str(move_dir / "missing-target"))
except FileNotFoundError:
    pass
else:
    raise AssertionError("missing atomic source did not fail closed")

class ZeroErrnoCall:
    def __call__(self, *_args):
        return -1

zero_call = ZeroErrnoCall()
saved_get_errno = atomic.ctypes.get_errno
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

atomic.ctypes.get_errno = lambda: errno.EINVAL
try:
    try:
        atomic._native_call(zero_call, 0, "a", 0, "b", 1)
    except OSError as exc:
        assert exc.errno == getattr(errno, "ENOTSUP", errno.EOPNOTSUPP)
    else:
        raise AssertionError("unsupported native rename flag was not normalized")
finally:
    atomic.ctypes.get_errno = saved_get_errno

other = root / "other"
other.mkdir()
(move_dir / "contained").write_bytes(b"contained")
try:
    atomic.atomic_rename_noreplace(str(move_dir / "contained"), str(other / "escape"))
except OSError as exc:
    assert exc.errno in {errno.EXDEV, errno.EINVAL}
else:
    raise AssertionError("cross-parent move was accepted")

saved_platform = atomic.sys.platform
atomic.sys.platform = "unsupported-test-platform"
try:
    try:
        atomic.require_atomic_rename_noreplace_support()
    except OSError as exc:
        assert exc.errno in {getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), errno.EOPNOTSUPP}
    else:
        raise AssertionError("unsupported host passed the capability preflight")
    try:
        atomic.atomic_rename_noreplace(str(move_dir / "contained"), str(move_dir / "unsupported"))
    except OSError as exc:
        assert exc.errno in {getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), errno.EOPNOTSUPP}
    else:
        raise AssertionError("unsupported primitive did not fail closed")
finally:
    atomic.sys.platform = saved_platform

# All receipt operations preflight the actual native primitive before parsing
# or returning authority. Unsupported platforms therefore fail capability even
# when the sibling helper imported successfully.
old_support_check = receipts.require_atomic_rename_noreplace_support
old_validate_context = receipts._validated_context
context_reached = False
def unsupported_support_check():
    raise OSError(getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), "injected")
def mark_context(*_args, **_kwargs):
    global context_reached
    context_reached = True
    raise AssertionError("authority validation reached before capability preflight")
receipts.require_atomic_rename_noreplace_support = unsupported_support_check
receipts._validated_context = mark_context
try:
    try:
        receipts.inspect_receipt(
            repo="invalid", relative="invalid", branch="invalid",
            receipt="invalid", start_head="invalid", token="invalid",
        )
    except receipts.CapabilityReceiptError:
        pass
    else:
        raise AssertionError("unsupported receipt platform returned authority")
finally:
    receipts.require_atomic_rename_noreplace_support = old_support_check
    receipts._validated_context = old_validate_context
assert not context_reached

# Native Windows accepts Git Bash's alternate separators only when replacing
# '/' with '\\' yields the exact spelling returned by abspath. Python 3.13
# changed ntpath.isabs so a single leading slash is no longer absolute, while
# host-side ntpath.abspath cannot supply the current Windows drive. Pin both
# parts of the fake model so /tmp and /d/a aliases are rejected identically on
# every Python version without weakening native final-spelling checks.
class WindowsPathModel:
    sep = "\\"
    altsep = "/"
    current_drive = "C:"

    @staticmethod
    def isabs(value):
        drive, tail = ntpath.splitdrive(value)
        return bool(drive and tail.startswith(("\\", "/")))

    @staticmethod
    def abspath(value):
        drive, tail = ntpath.splitdrive(ntpath.normpath(value))
        if not drive and tail.startswith("\\"):
            return WindowsPathModel.current_drive + tail
        return ntpath.abspath(value)

    @staticmethod
    def realpath(value):
        resolved = WindowsPathModel.abspath(value)
        if resolved.startswith("c:"):
            resolved = "C:" + resolved[2:]
        if resolved.startswith("C:\\repo"):
            resolved = "C:\\Repo" + resolved[len("C:\\repo"):]
        resolved = resolved.replace("\\runtime", "\\Runtime", 1)
        return resolved


assert not WindowsPathModel.isabs("/tmp/Runtime/receipt.json")
assert WindowsPathModel.abspath("/tmp/Runtime/receipt.json") == (
    "C:\\tmp\\Runtime\\receipt.json"
)
assert WindowsPathModel.abspath("/d/a/UberDev/Runtime/receipt.json") == (
    "C:\\d\\a\\UberDev\\Runtime\\receipt.json"
)


saved_path_module = receipts.os.path
saved_native_windows = receipts._native_windows
receipts.os.path = WindowsPathModel
receipts._native_windows = lambda: True
try:
    for raw, expected in (
        ("C:\\Repo\\Runtime", "C:\\Repo\\Runtime"),
        ("C:/Repo\\Runtime/receipt.json", "C:\\Repo\\Runtime\\receipt.json"),
    ):
        assert receipts._canonical_absolute_input(raw) == expected
    for alias in (
        "Repo\\Runtime",
        "Repo/Runtime",
        "/tmp/Runtime/receipt.json",
        "/d/a/UberDev/Runtime/receipt.json",
        "C:\\Repo\\.\\Runtime",
        "C:/Repo/./Runtime",
        "C:\\Repo\\Runtime\\..\\Receipt",
        "C:/Repo\\Runtime/../Receipt",
        "C:\\Repo\\\\Runtime",
        "C:/Repo//Runtime",
        "C:\\Repo\\Runtime\\",
        "C:/Repo\\Runtime/",
    ):
        try:
            receipts._canonical_absolute_input(alias)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError(f"Windows path alias reached authority: {alias!r}")
    assert receipts._canonical_absolute_input("c:/Repo\\Runtime") == "c:\\Repo\\Runtime"
    for canonical in ("C:\\Repo", "C:\\Repo\\Runtime"):
        assert receipts._canonical_windows_final_spelling(canonical) == canonical
    for case_alias in (
        "c:\\Repo",
        "c:/Repo",
        "C:\\repo",
        "C:/repo",
        "C:\\Repo\\runtime",
        "C:/Repo/runtime",
    ):
        try:
            receipts._canonical_windows_final_spelling(case_alias)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError(
                f"Windows final-path case alias reached authority: {case_alias!r}"
            )
finally:
    receipts.os.path = saved_path_module
    receipts._native_windows = saved_native_windows

# Windows publication uses the native no-replace primitive with write-through
# durability. The flag contract is modeled on every host and the actual call is
# exercised by windows-latest.
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
    assert isinstance(mapped, expected_type) and mapped.errno == expected_errno
assert windows_calls == [("source", "destination", 0x00000008)]

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

# Modeled native-Windows descriptor carriers accept 0/1 links only. Every
# pathname snapshot is one-link-only on every platform.
for count in (0, 1):
    assert receipts._descriptor_link_count_valid(SimpleNamespace(st_nlink=count), True)
assert not receipts._descriptor_link_count_valid(SimpleNamespace(st_nlink=2), True)
assert not receipts._descriptor_link_count_valid(SimpleNamespace(st_nlink=0), False)
assert receipts._descriptor_link_count_valid(SimpleNamespace(st_nlink=1), False)
for count in (0, 2):
    assert not receipts._pathname_link_count_valid(SimpleNamespace(st_nlink=count))
assert receipts._pathname_link_count_valid(SimpleNamespace(st_nlink=1))
fake_reparse = SimpleNamespace(
    st_mode=stat.S_IFREG | 0o600,
    st_file_attributes=0x400,
)
assert receipts._is_link_or_reparse(str(root / "modeled-reparse"), fake_reparse)

rename_stable_base = dict(
    st_dev=1,
    st_ino=2,
    st_size=3,
    st_mtime_ns=4,
    st_mode=stat.S_IFREG | 0o600,
)
linux_before = SimpleNamespace(**rename_stable_base, st_ctime_ns=5)
linux_after = SimpleNamespace(**rename_stable_base, st_ctime_ns=6)
assert receipts._identity(linux_before, False) == receipts._identity(linux_after, False)
assert receipts._identity(linux_before, True) != receipts._identity(linux_after, True)

# NTFS filename tunneling may change only the creation-time component when an
# exact carrier crosses an atomic rename boundary. That field is not stable
# across the move; every other identity component and the exact raw/digest
# evidence remain mandatory.
modeled_raw = b"modeled Windows rename carrier\n"
modeled_digest = hashlib.sha256(modeled_raw).hexdigest()
modeled_before_identity = (1, 2, len(modeled_raw), 4, 5, stat.S_IFREG | 0o600)
modeled_after_identity = (1, 2, len(modeled_raw), 4, 6, stat.S_IFREG | 0o600)
modeled_before = receipts._Carrier(
    modeled_raw,
    modeled_digest,
    modeled_before_identity,
    (*modeled_before_identity[:4], 5, modeled_before_identity[5]),
    None,
)
modeled_after = receipts._Carrier(
    modeled_raw,
    modeled_digest,
    modeled_after_identity,
    (*modeled_after_identity[:4], 6, modeled_after_identity[5]),
    None,
)
windows_rename_carriers_match = getattr(
    receipts, "_windows_rename_carriers_match", lambda _before, _after: False
)
assert windows_rename_carriers_match(modeled_before, modeled_after)
for identity_index in (0, 1, 2, 3, 5):
    changed_identity = list(modeled_after_identity)
    changed_identity[identity_index] ^= (
        stat.S_IWUSR if identity_index == 5 else 1
    )
    changed = modeled_after._replace(identity=tuple(changed_identity))
    assert not windows_rename_carriers_match(modeled_before, changed)
changed_raw = b"different Windows rename carrier\n"
assert not windows_rename_carriers_match(
    modeled_before,
    modeled_after._replace(
        raw=changed_raw,
        digest=hashlib.sha256(changed_raw).hexdigest(),
    ),
)
assert not windows_rename_carriers_match(
    modeled_before, modeled_after._replace(digest="0" * 64)
)

# Route modeled Windows st_nlink values through the real secure-capture call
# site as well as the predicate. This prevents a stray direct `!= 1` check
# from rejecting legitimate Windows descriptors.
capture_parent = root / "modeled-windows-capture"
capture_parent.mkdir(mode=0o700)
capture_path = capture_parent / "receipt.json"
capture_path.write_bytes(b"{}\n")
os.chmod(capture_path, 0o600)
capture_parent_identity = (os.lstat(capture_parent).st_dev, os.lstat(capture_parent).st_ino)
real_fstat = receipts.os.fstat
class LinkView:
    def __init__(self, base, links):
        self._base = base
        self.st_nlink = links
    def __getattr__(self, name):
        return getattr(self._base, name)

receipts.os.fstat = lambda fd: LinkView(real_fstat(fd), 0)
try:
    assert receipts._open_windows_carrier(str(capture_path), capture_parent_identity).raw == b"{}\n"
finally:
    receipts.os.fstat = real_fstat
receipts.os.fstat = lambda fd: LinkView(real_fstat(fd), 2)
try:
    try:
        receipts._open_windows_carrier(str(capture_path), capture_parent_identity)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("Windows descriptor st_nlink=2 reached authority")
finally:
    receipts.os.fstat = real_fstat

# Create emits an exact compact receipt; active authority is the only state
# that returns deletion inputs. Retirement returns no target authority.
repo, private, public, head, relative, branch, common = fixture("lifecycle")
created = success(run("create", *common), "active")
token = created.get("token")
assert isinstance(token, str) and receipts._valid_token(token, head)
expected = receipts._expected_payload(str(repo), relative, branch, str(public), head, token)
assert public.read_bytes() == receipts._canonical_bytes(expected)
active = success(run("inspect", *common, "--token", token), "active")
assert active == {"start_head": head, "state": "active", "worktree": expected["worktree"]}
retired = success(run("retire", *common, "--token", token), "retired")
assert retired == {"state": "retired"}
tombstone = pathlib.Path(receipts._tombstone_path(str(public), token))
assert not public.exists() and tombstone.read_bytes() == receipts._canonical_bytes(expected)
assert success(run("inspect", *common, "--token", token), "retired") == {"state": "retired"}
assert success(run("retire", *common, "--token", token), "retired") == {"state": "retired"}

# Native NTFS regression: immediately reuse the public basename for a distinct
# generation after A retires, then prime and vacate B's tombstone basename
# before retiring B. Filename tunneling may preserve the vacated names'
# creation times, but both exact generations must retain independent authority.
if os.name == "nt":
    (
        tunnel_repo,
        _,
        tunnel_public,
        tunnel_head,
        tunnel_relative,
        tunnel_branch,
        tunnel_common,
    ) = fixture("windows-filename-tunneling")
    tunnel_a_token = success(run("create", *tunnel_common), "active")["token"]
    tunnel_a_raw = tunnel_public.read_bytes()
    tunnel_a_tomb = pathlib.Path(
        receipts._tombstone_path(str(tunnel_public), tunnel_a_token)
    )
    success(run("retire", *tunnel_common, "--token", tunnel_a_token), "retired")
    assert tunnel_a_tomb.read_bytes() == tunnel_a_raw

    tunnel_b_token = success(run("create", *tunnel_common), "active")["token"]
    assert tunnel_b_token != tunnel_a_token
    tunnel_b_raw = tunnel_public.read_bytes()
    tunnel_b_tomb = pathlib.Path(
        receipts._tombstone_path(str(tunnel_public), tunnel_b_token)
    )
    tunnel_b_prime = tunnel_b_tomb.with_name(tunnel_b_tomb.name + ".primed")
    tunnel_b_prime_raw = b"vacated tombstone basename\n"
    tunnel_b_tomb.write_bytes(tunnel_b_prime_raw)
    tunnel_b_tomb.rename(tunnel_b_prime)

    success(run("retire", *tunnel_common, "--token", tunnel_b_token), "retired")
    assert not tunnel_public.exists()
    assert tunnel_a_tomb.read_bytes() == tunnel_a_raw
    assert tunnel_b_tomb.read_bytes() == tunnel_b_raw
    assert tunnel_b_prime.read_bytes() == tunnel_b_prime_raw

# A missing sibling dependency must stay on each helper's fixed failure
# protocol; it may never emit a traceback containing local paths.
missing_dependency_dir = root / "missing-dependency"
missing_dependency_dir.mkdir()
isolated_receipts = missing_dependency_dir / "worktree_receipts.py"
isolated_planning = missing_dependency_dir / "planning_research_output.py"
shutil.copyfile(receipt_path, isolated_receipts)
shutil.copyfile(planning_path, isolated_planning)
missing_receipt_result = subprocess.run(
    [sys.executable, "-I", "-B", str(isolated_receipts), "create", *common],
    text=True,
    capture_output=True,
    check=False,
)
if (
    missing_receipt_result.returncode != 3
    or missing_receipt_result.stdout
    or missing_receipt_result.stderr != "uberdev worktree receipt: internal failure\n"
):
    raise AssertionError(missing_receipt_result)
planning_result = subprocess.run(
    [
        sys.executable, "-I", "-B", str(isolated_planning),
        "--operation", "validate", "--mode", "prewrite",
        "--summary-dir", str(private),
        "--output-path", str(private / "dependency-map.md"),
        "--expected-basename", "dependency-map.md",
    ],
    text=True,
    capture_output=True,
    check=False,
)
if planning_result.returncode != 2 or planning_result.stderr:
    raise AssertionError(planning_result)
planning_failure = json.loads(planning_result.stdout)
if planning_failure.get("status") != "invalid" or planning_failure.get("reason") != "platform_safety":
    raise AssertionError(planning_failure)

# Missing authority, wrong tokens, and simultaneous public/tombstone carriers
# are terminal and preserve every byte.
_, _, missing, missing_head, _, _, missing_common = fixture("missing")
terminal(run("inspect", *missing_common, "--token", "a" * 32 + ":" + missing_head))
terminal(run("retire", *missing_common, "--token", "a" * 32 + ":" + missing_head))
terminal(run("inspect", *common, "--token", "b" * 32 + ":" + head))
public.write_bytes(tombstone.read_bytes())
before_public, before_tomb = public.read_bytes(), tombstone.read_bytes()
terminal(run("inspect", *common, "--token", token))
terminal(run("retire", *common, "--token", token))
assert public.read_bytes() == before_public and tombstone.read_bytes() == before_tomb

# A pre-existing tombstone collision preserves source and destination.
_, _, collision_public, collision_head, _, _, collision_common = fixture("collision")
collision_created = success(run("create", *collision_common), "active")
collision_token = collision_created["token"]
collision_tomb = pathlib.Path(receipts._tombstone_path(str(collision_public), collision_token))
collision_tomb.write_bytes(b"foreign tombstone\n")
collision_source = collision_public.read_bytes()
terminal(run("retire", *collision_common, "--token", collision_token))
assert collision_public.read_bytes() == collision_source
assert collision_tomb.read_bytes() == b"foreign tombstone\n"

# Exact compact bytes are part of the authority. A semantically equivalent
# but noncanonical receipt is terminal and preserved.
_, _, malformed_public, malformed_head, _, _, malformed_common = fixture("malformed")
malformed_created = success(run("create", *malformed_common), "active")
malformed_token = malformed_created["token"]
malformed_value = json.loads(malformed_public.read_bytes())
malformed_public.write_text(json.dumps(malformed_value, indent=2) + "\n", encoding="utf-8")
malformed_before = malformed_public.read_bytes()
terminal(run("inspect", *malformed_common, "--token", malformed_token))
terminal(run("retire", *malformed_common, "--token", malformed_token))
assert malformed_public.read_bytes() == malformed_before

# Symlink and hard-link sources are never authority.
if os.name != "nt":
    _, _, linked_public, linked_head, _, _, linked_common = fixture("symlink")
    linked_created = success(run("create", *linked_common), "active")
    linked_token = linked_created["token"]
    original = linked_public.with_name("original.json")
    linked_public.rename(original)
    linked_public.symlink_to(original)
    terminal(run("inspect", *linked_common, "--token", linked_token))
    assert original.read_bytes()

_, _, hardlink_public, hardlink_head, _, _, hardlink_common = fixture("hardlink")
hardlink_created = success(run("create", *hardlink_common), "active")
hardlink_token = hardlink_created["token"]
hardlink_original = hardlink_public.with_name("original.json")
hardlink_public.rename(hardlink_original)
os.link(hardlink_original, hardlink_public)
terminal(run("inspect", *hardlink_common, "--token", hardlink_token))
assert hardlink_original.read_bytes() == hardlink_public.read_bytes()

# Junctions do not require Windows Developer Mode and provide a native reparse
# regression for the receipt parent boundary.
if os.name == "nt":
    _, junction_private, junction_public, _, _, _, junction_common = fixture("junction-parent")
    real_private = junction_private.with_name("private-real")
    junction_private.rename(real_private)
    junction = subprocess.run(
        ["cmd.exe", "/d", "/c", "mklink", "/J", str(junction_private), str(real_private)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if junction.returncode != 0:
        raise AssertionError((junction.stdout, junction.stderr))
    terminal(run("create", *junction_common))

    def make_junction(link, target):
        target.mkdir()
        result = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(link), str(target)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError((result.stdout, result.stderr))

    _, _, source_reparse, source_reparse_head, _, _, source_reparse_common = fixture("source-reparse")
    source_reparse_token = success(run("create", *source_reparse_common), "active")["token"]
    source_reparse.unlink()
    make_junction(source_reparse, source_reparse.with_name("source-reparse-target"))
    terminal(run("retire", *source_reparse_common, "--token", source_reparse_token))

    _, _, tomb_reparse_public, tomb_reparse_head, _, _, tomb_reparse_common = fixture("tomb-reparse")
    tomb_reparse_token = success(run("create", *tomb_reparse_common), "active")["token"]
    tomb_reparse = pathlib.Path(receipts._tombstone_path(str(tomb_reparse_public), tomb_reparse_token))
    make_junction(tomb_reparse, tomb_reparse.with_name("tomb-reparse-target"))
    source_before = tomb_reparse_public.read_bytes()
    terminal(run("retire", *tomb_reparse_common, "--token", tomb_reparse_token))
    assert tomb_reparse_public.read_bytes() == source_before and tomb_reparse.is_dir()

# Hostile paths and tokens never appear on the diagnostic channel.
hostile = run(
    "inspect", "--repo", "SECRET-REPO", "--relative", "SECRET-RELATIVE",
    "--branch", "SECRET-BRANCH", "--receipt", "SECRET-RECEIPT",
    "--start-head", "SECRET-HEAD", "--token", "SECRET-TOKEN",
)
terminal(hostile)

# The public basename is untrusted and may approach NAME_MAX; tombstone length
# and identity depend only on the fixed prefix plus a full digest.
hostile_name = "p" * 220 + ".json"
_, _, long_public, long_head, _, _, long_common = fixture("long-name", hostile_name)
long_created = success(run("create", *long_common), "active")
long_token = long_created["token"]
long_tomb = pathlib.Path(receipts._tombstone_path(str(long_public), long_token))
long_stage = pathlib.Path(receipts._stage_path(str(long_public), long_token))
assert len(long_tomb.name.encode()) < 255 and hostile_name not in long_tomb.name
assert len(long_stage.name.encode()) < 255 and hostile_name not in long_stage.name
success(run("retire", *long_common, "--token", long_token), "retired")
assert long_tomb.exists()

# Receipt creation is staged under a fixed token-derived sibling. Failures in
# every pre-publication I/O phase may retain only an inert stage carrier; they
# may never expose a malformed public receipt or create a tombstone.
def create_api_fixture(label):
    repo, private, public, head, relative, branch, _common = fixture(label)
    kwargs = dict(
        repo=str(repo), relative=relative, branch=branch,
        receipt=str(public), start_head=head,
    )
    return private, public, kwargs


def staged_entries(private):
    return sorted(private.glob(".worktree-owner.stage-v1-*.json"))


# Stage allocation itself is O_EXCL: a competitor that creates the fixed stage
# immediately after the absence probe is preserved byte-for-byte and can never
# be opened as the production staging descriptor.
private_excl, public_excl, kwargs_excl = create_api_fixture("stage-o-excl")
excl_token = "6" * 32 + ":" + kwargs_excl["start_head"]
excl_stage = pathlib.Path(receipts._stage_path(str(public_excl), excl_token))
excl_sentinel = b"foreign stage allocation\n"
old_token_hex = receipts.secrets.token_hex
receipts.secrets.token_hex = lambda _size: "6" * 32
if os.name == "nt":
    old_require_stage_absent = receipts._require_absent_windows
    def inject_windows_stage_after_absence(path, parent_identity):
        old_require_stage_absent(path, parent_identity)
        if pathlib.Path(path) == excl_stage:
            excl_stage.write_bytes(excl_sentinel)
            os.chmod(excl_stage, 0o600)
    receipts._require_absent_windows = inject_windows_stage_after_absence
else:
    old_require_stage_absent = receipts._require_absent_posix
    def inject_posix_stage_after_absence(directory_fd, name):
        old_require_stage_absent(directory_fd, name)
        if name == excl_stage.name:
            descriptor = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600,
                dir_fd=directory_fd,
            )
            os.write(descriptor, excl_sentinel)
            os.close(descriptor)
    receipts._require_absent_posix = inject_posix_stage_after_absence
try:
    try:
        receipts.create_receipt(**kwargs_excl)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("stage allocation collision was accepted")
finally:
    receipts.secrets.token_hex = old_token_hex
    if os.name == "nt":
        receipts._require_absent_windows = old_require_stage_absent
    else:
        receipts._require_absent_posix = old_require_stage_absent
assert not public_excl.exists()
assert excl_stage.read_bytes() == excl_sentinel
assert not list(private_excl.glob(".worktree-owner.retired-v1-*.json"))


failure_cases = []
old_write = receipts.os.write
failure_cases.append(("write", "os.write", lambda *_args: (_ for _ in ()).throw(OSError(errno.EIO, "injected"))))
failure_cases.append(("fsync", "_sync_stage_descriptor", lambda _fd: (_ for _ in ()).throw(OSError(errno.EIO, "injected"))))
failure_cases.append(("fstat", "_stage_fstat", lambda _fd: (_ for _ in ()).throw(OSError(errno.EIO, "injected"))))

def close_then_fail(fd):
    os.close(fd)
    raise OSError(errno.EIO, "injected")

failure_cases.append(("close", "_close_stage_descriptor", close_then_fail))
for index, (label, attribute, replacement) in enumerate(failure_cases):
    private_fail, public_fail, kwargs_fail = create_api_fixture(f"stage-{label}")
    old_value = receipts.os.write if attribute == "os.write" else getattr(receipts, attribute)
    if attribute == "os.write":
        receipts.os.write = replacement
    else:
        setattr(receipts, attribute, replacement)
    try:
        try:
            receipts.create_receipt(**kwargs_fail)
        except receipts.TransientReceiptError:
            pass
        else:
            raise AssertionError(f"injected {label} failure was accepted")
    finally:
        if attribute == "os.write":
            receipts.os.write = old_value
        else:
            setattr(receipts, attribute, old_value)
    assert not public_fail.exists()
    assert not list(private_fail.glob(".worktree-owner.retired-v1-*.json"))
    assert len(staged_entries(private_fail)) <= 1

# Exact bytes alone do not grant stage authority: replacing the validated
# carrier with an exact copy before secure recapture is terminal and preserves
# the replacement as an inert stage.
private_stage_swap, public_stage_swap, kwargs_stage_swap = create_api_fixture(
    "stage-identity-swap"
)
stage_swap_token = "f" * 32 + ":" + kwargs_stage_swap["start_head"]
stage_swap_path = pathlib.Path(
    receipts._stage_path(str(public_stage_swap), stage_swap_token)
)
old_token_hex = receipts.secrets.token_hex
receipts.secrets.token_hex = lambda _size: "f" * 32
if os.name == "nt":
    old_stage_open = receipts._open_windows_carrier
    stage_swapped = False
    def replace_windows_stage(path, parent_identity):
        global stage_swapped
        if not stage_swapped and pathlib.Path(path) == stage_swap_path:
            stage_swapped = True
            raw = stage_swap_path.read_bytes()
            stage_swap_path.unlink()
            stage_swap_path.write_bytes(raw)
            os.chmod(stage_swap_path, 0o600)
        return old_stage_open(path, parent_identity)
    receipts._open_windows_carrier = replace_windows_stage
else:
    old_stage_open = receipts._open_posix_carrier
    stage_swapped = False
    def replace_posix_stage(directory_fd, name):
        global stage_swapped
        if not stage_swapped and name == stage_swap_path.name:
            stage_swapped = True
            raw = stage_swap_path.read_bytes()
            os.unlink(name, dir_fd=directory_fd)
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory_fd)
            os.write(fd, raw)
            os.close(fd)
        return old_stage_open(directory_fd, name)
    receipts._open_posix_carrier = replace_posix_stage
try:
    try:
        receipts.create_receipt(**kwargs_stage_swap)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("exact stage carrier replacement was accepted")
finally:
    receipts.secrets.token_hex = old_token_hex
    if os.name == "nt":
        receipts._open_windows_carrier = old_stage_open
    else:
        receipts._open_posix_carrier = old_stage_open
assert stage_swapped and not public_stage_swap.exists()
assert stage_swap_path.exists()

# Replacing the exact stage at the atomic boundary is also detected after the
# move. The foreign replacement may become public, but its bytes are preserved
# and no token is returned as authority for that foreign inode.
private_move_swap, public_move_swap, kwargs_move_swap = create_api_fixture(
    "stage-move-identity-swap"
)
old_atomic = receipts.atomic_rename_noreplace
def replace_stage_at_publish(source_name, destination_name, *, dir_fd=None):
    source_path = pathlib.Path(source_name) if dir_fd is None else private_move_swap / source_name
    raw = source_path.read_bytes()
    source_path.unlink()
    source_path.write_bytes(raw)
    os.chmod(source_path, 0o600)
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
receipts.atomic_rename_noreplace = replace_stage_at_publish
try:
    try:
        receipts.create_receipt(**kwargs_move_swap)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("atomic-boundary stage replacement was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
assert public_move_swap.exists() and not staged_entries(private_move_swap)
assert not list(private_move_swap.glob(".worktree-owner.retired-v1-*.json"))

private_after_swap, public_after_swap, kwargs_after_swap = create_api_fixture(
    "public-after-publish-swap"
)
after_publish_sentinel = b"foreign after publication\n"
def replace_public_after_publish(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    destination_path = (
        pathlib.Path(destination_name)
        if dir_fd is None
        else private_after_swap / destination_name
    )
    destination_path.unlink()
    destination_path.write_bytes(after_publish_sentinel)
    os.chmod(destination_path, 0o600)
receipts.atomic_rename_noreplace = replace_public_after_publish
try:
    try:
        receipts.create_receipt(**kwargs_after_swap)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("post-publication replacement was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
assert public_after_swap.read_bytes() == after_publish_sentinel
assert not staged_entries(private_after_swap)
assert not list(private_after_swap.glob(".worktree-owner.retired-v1-*.json"))

# Atomic publication capability failures are terminal and leave the validated
# stage inert. A public collision introduced exactly at publication is retained
# byte-for-byte, proving there is no overwrite fallback on either platform.
private_cap, public_cap, kwargs_cap = create_api_fixture("stage-capability")
old_atomic = receipts.atomic_rename_noreplace
def fail_capability(_source, _destination, *, dir_fd=None):
    del dir_fd
    raise OSError(getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), "injected")
receipts.atomic_rename_noreplace = fail_capability
try:
    try:
        receipts.create_receipt(**kwargs_cap)
    except receipts.CapabilityReceiptError:
        pass
    else:
        raise AssertionError("unsupported publication capability was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
assert not public_cap.exists() and len(staged_entries(private_cap)) == 1

private_race, public_race, kwargs_race = create_api_fixture("publish-collision")
sentinel = b"foreign public receipt\n"
def collide_at_publish(source_name, destination_name, *, dir_fd=None):
    if dir_fd is None:
        pathlib.Path(destination_name).write_bytes(sentinel)
    else:
        fd = os.open(destination_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, sentinel)
        os.close(fd)
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
receipts.atomic_rename_noreplace = collide_at_publish
try:
    try:
        receipts.create_receipt(**kwargs_race)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("publication collision was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
assert public_race.read_bytes() == sentinel
assert len(staged_entries(private_race)) == 1
assert not list(private_race.glob(".worktree-owner.retired-v1-*.json"))

# If the native boundary committed the stage move but its wrapper reports an
# I/O failure, exact identity probing upgrades the result to safe reconciliation
# evidence instead of losing the only token for the now-public authority.
private_commit, public_commit, kwargs_commit = create_api_fixture(
    "publish-committed-error"
)
commit_token = "9" * 32 + ":" + kwargs_commit["start_head"]
old_token_hex = receipts.secrets.token_hex
receipts.secrets.token_hex = lambda _size: "9" * 32
def fail_after_publish(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    raise OSError(errno.EIO, "injected")
receipts.atomic_rename_noreplace = fail_after_publish
try:
    try:
        receipts.create_receipt(**kwargs_commit)
    except receipts.PublishedTransientReceiptError as exc:
        assert exc.token == commit_token
    else:
        raise AssertionError("committed publication error lost reconciliation state")
finally:
    receipts.atomic_rename_noreplace = old_atomic
    receipts.secrets.token_hex = old_token_hex
commit_expected = receipts._canonical_bytes(
    receipts._expected_payload(
        kwargs_commit["repo"], kwargs_commit["relative"], kwargs_commit["branch"],
        kwargs_commit["receipt"], kwargs_commit["start_head"], commit_token,
    )
)
assert public_commit.read_bytes() == commit_expected
assert not staged_entries(private_commit)
assert not list(private_commit.glob(".worktree-owner.retired-v1-*.json"))

# Unexpected programming defects are never advertised as retryable. The CLI's
# diagnostic is fixed and does not expose exception text or local paths.
def main_failure(exception):
    old_create = receipts.create_receipt
    old_argv = sys.argv
    old_stdout, old_stderr = sys.stdout, sys.stderr
    stdout, stderr = io.StringIO(), io.StringIO()
    receipts.create_receipt = lambda **_kwargs: (_ for _ in ()).throw(exception)
    sys.argv = [receipt_path, "create", *common]
    sys.stdout, sys.stderr = stdout, stderr
    try:
        code = receipts.main()
    finally:
        receipts.create_receipt = old_create
        sys.argv = old_argv
        sys.stdout, sys.stderr = old_stdout, old_stderr
    return code, stdout.getvalue(), stderr.getvalue()

for defect in (NameError("SECRET-NAME"), TypeError("SECRET-TYPE")):
    assert main_failure(defect) == (
        3, "", "uberdev worktree receipt: internal failure\n"
    )
assert main_failure(receipts.TransientReceiptError()) == (
    2, "", "uberdev worktree receipt: operation failed\n"
)
assert main_failure(receipts.CapabilityReceiptError()) == (
    3, "", "uberdev worktree receipt: unsupported capability\n"
)

old_create = receipts.create_receipt
old_emit = receipts._emit
old_argv = sys.argv
old_stdout, old_stderr = sys.stdout, sys.stderr
stdout, stderr = io.StringIO(), io.StringIO()
receipts.create_receipt = lambda **_kwargs: {"state": "active", "token": "unused"}
receipts._emit = lambda _value: (_ for _ in ()).throw(TypeError("SECRET-EMIT"))
sys.argv = [receipt_path, "create", *common]
sys.stdout, sys.stderr = stdout, stderr
try:
    emit_failure_code = receipts.main()
finally:
    receipts.create_receipt = old_create
    receipts._emit = old_emit
    sys.argv = old_argv
    sys.stdout, sys.stderr = old_stdout, old_stderr
assert (emit_failure_code, stdout.getvalue(), stderr.getvalue()) == (
    3, "", "uberdev worktree receipt: internal failure\n"
)

# POSIX publication and retirement each finish with a verified parent-directory
# durability barrier. A post-publication barrier failure reports a safe token
# without claiming active authority; retirement remains retryable from T.
if os.name != "nt":
    private_dir_cap, public_dir_cap, kwargs_dir_cap = create_api_fixture(
        "directory-sync-capability"
    )
    old_fsync = receipts.os.fsync
    def fail_directory_capability(descriptor):
        if stat.S_ISDIR(real_fstat(descriptor).st_mode):
            raise OSError(errno.EINVAL, "injected")
        return old_fsync(descriptor)
    receipts.os.fsync = fail_directory_capability
    try:
        try:
            receipts.create_receipt(**kwargs_dir_cap)
        except receipts.CapabilityReceiptError:
            pass
        else:
            raise AssertionError("unsupported directory barrier was accepted")
    finally:
        receipts.os.fsync = old_fsync
    assert not public_dir_cap.exists()
    assert len(staged_entries(private_dir_cap)) == 1
    assert not list(private_dir_cap.glob(".worktree-owner.retired-v1-*.json"))

    private_sync, public_sync, kwargs_sync = create_api_fixture("create-directory-sync")
    fixed_token = "d" * 32 + ":" + kwargs_sync["start_head"]
    old_token_hex = receipts.secrets.token_hex
    old_sync_directory = receipts._sync_posix_directory
    old_fsync = receipts.os.fsync
    sync_calls = 0
    def fail_second_sync(descriptor):
        global sync_calls
        if stat.S_ISDIR(real_fstat(descriptor).st_mode):
            sync_calls += 1
            if sync_calls == 2:
                raise OSError(errno.EIO, "injected")
        return old_fsync(descriptor)
    receipts.secrets.token_hex = lambda _size: "d" * 32
    receipts.os.fsync = fail_second_sync
    try:
        try:
            receipts.create_receipt(**kwargs_sync)
        except receipts.PublishedTransientReceiptError as exc:
            assert exc.token == fixed_token
        else:
            raise AssertionError("post-publication directory-sync failure was accepted")
    finally:
        receipts.os.fsync = old_fsync
        receipts.secrets.token_hex = old_token_hex
    assert public_sync.read_bytes() == receipts._canonical_bytes(
        receipts._expected_payload(
            kwargs_sync["repo"], kwargs_sync["relative"], kwargs_sync["branch"],
            kwargs_sync["receipt"], kwargs_sync["start_head"], fixed_token,
        )
    )
    assert not list(private_sync.glob(".worktree-owner.retired-v1-*.json"))

    old_create = receipts.create_receipt
    receipts.create_receipt = lambda **_kwargs: (_ for _ in ()).throw(
        receipts.PublishedTransientReceiptError(fixed_token)
    )
    try:
        assert main_failure(receipts.PublishedTransientReceiptError(fixed_token)) == (
            2,
            json.dumps(
                {"state": "active_unconfirmed", "token": fixed_token},
                ensure_ascii=True, separators=(",", ":"), sort_keys=True,
            ) + "\n",
            "uberdev worktree receipt: operation failed\n",
        )
    finally:
        receipts.create_receipt = old_create

    retire_kwargs = dict(kwargs_sync, token=fixed_token)
    retire_sync_calls = 0
    def fail_retire_second_sync(descriptor):
        global retire_sync_calls
        if stat.S_ISDIR(real_fstat(descriptor).st_mode):
            retire_sync_calls += 1
            if retire_sync_calls == 2:
                raise OSError(errno.EIO, "injected")
        return old_fsync(descriptor)
    receipts.os.fsync = fail_retire_second_sync
    try:
        try:
            receipts.retire_receipt(**retire_kwargs)
        except receipts.TransientReceiptError:
            pass
        else:
            raise AssertionError("retirement directory-sync failure was accepted")
    finally:
        receipts.os.fsync = old_fsync
    sync_tomb = pathlib.Path(receipts._tombstone_path(str(public_sync), fixed_token))
    assert not public_sync.exists() and sync_tomb.exists()
    retry_sync_calls = 0
    def count_retry_sync(directory_fd, parent, identity):
        global retry_sync_calls
        retry_sync_calls += 1
        return old_sync_directory(directory_fd, parent, identity)
    receipts._sync_posix_directory = count_retry_sync
    try:
        assert receipts.retire_receipt(**retire_kwargs) == {"state": "retired"}
    finally:
        receipts._sync_posix_directory = old_sync_directory
    assert retry_sync_calls >= 1

# Exercise the in-process race seams. A replacement moved at the atomic
# boundary is retained as the permanent tombstone and detected. A replacement
# after the move is likewise detected; no rollback is attempted.
def api_fixture(label):
    repo, _, public, head, relative, branch, common = fixture(label)
    token = success(run("create", *common), "active")["token"]
    kwargs = dict(repo=str(repo), relative=relative, branch=branch,
                  receipt=str(public), start_head=head, token=token)
    return public, token, kwargs


public_at_move, token_at_move, kwargs_at_move = api_fixture("replace-at-move")
old_atomic = receipts.atomic_rename_noreplace

unsupported_public, unsupported_token, unsupported_kwargs = api_fixture("unsupported-move")
unsupported_before = unsupported_public.read_bytes()
def unsupported_move(_source_name, _destination_name, *, dir_fd=None):
    del dir_fd
    raise OSError(getattr(errno, "ENOTSUP", errno.EOPNOTSUPP), "unsupported")
receipts.atomic_rename_noreplace = unsupported_move
try:
    try:
        receipts.retire_receipt(**unsupported_kwargs)
    except receipts.CapabilityReceiptError:
        pass
    else:
        raise AssertionError("unsupported retirement primitive was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
unsupported_tomb = pathlib.Path(receipts._tombstone_path(str(unsupported_public), unsupported_token))
assert unsupported_public.read_bytes() == unsupported_before and not unsupported_tomb.exists()

retire_commit_public, retire_commit_token, retire_commit_kwargs = api_fixture(
    "retire-committed-error"
)
retire_commit_raw = retire_commit_public.read_bytes()
def fail_after_retirement(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    raise OSError(errno.EIO, "injected")
receipts.atomic_rename_noreplace = fail_after_retirement
try:
    try:
        receipts.retire_receipt(**retire_commit_kwargs)
    except receipts.TransientReceiptError:
        pass
    else:
        raise AssertionError("committed retirement error was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
retire_commit_tomb = pathlib.Path(
    receipts._tombstone_path(str(retire_commit_public), retire_commit_token)
)
assert not retire_commit_public.exists()
assert retire_commit_tomb.read_bytes() == retire_commit_raw
assert receipts.retire_receipt(**retire_commit_kwargs) == {"state": "retired"}

def swap_at_move(source_name, destination_name, *, dir_fd=None):
    if dir_fd is None:
        os.unlink(source_name)
        pathlib.Path(source_name).write_bytes(b"replacement at move\n")
    else:
        os.unlink(source_name, dir_fd=dir_fd)
        fd = os.open(source_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, b"replacement at move\n")
        os.close(fd)
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
receipts.atomic_rename_noreplace = swap_at_move
try:
    try:
        receipts.retire_receipt(**kwargs_at_move)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("move-boundary replacement was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
move_tomb = pathlib.Path(receipts._tombstone_path(str(public_at_move), token_at_move))
assert move_tomb.read_bytes() == b"replacement at move\n"

public_after, token_after, kwargs_after = api_fixture("replace-after-move")
def swap_after_move(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    if dir_fd is None:
        os.unlink(destination_name)
        pathlib.Path(destination_name).write_bytes(b"replacement after move\n")
    else:
        os.unlink(destination_name, dir_fd=dir_fd)
        fd = os.open(destination_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, b"replacement after move\n")
        os.close(fd)
receipts.atomic_rename_noreplace = swap_after_move
try:
    try:
        receipts.retire_receipt(**kwargs_after)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("post-move replacement was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
after_tomb = pathlib.Path(receipts._tombstone_path(str(public_after), token_after))
assert after_tomb.read_bytes() == b"replacement after move\n"

# Substitute only after the moved tombstone was captured. The final pathname
# binding must still reject the replacement and leave it untouched.
if os.name != "nt":
    inspect_public, inspect_token, inspect_kwargs = api_fixture("inspect-after-capture")
    old_inspect_validate = receipts._validate_posix_carrier_path
    inspect_injected = False
    def replace_active_at_final_validation(directory_fd, name, carrier):
        global inspect_injected
        if not inspect_injected and name == inspect_public.name:
            inspect_injected = True
            os.unlink(name, dir_fd=directory_fd)
            descriptor = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600,
                dir_fd=directory_fd,
            )
            os.write(descriptor, b"replacement active after capture\n")
            os.close(descriptor)
        return old_inspect_validate(directory_fd, name, carrier)
    receipts._validate_posix_carrier_path = replace_active_at_final_validation
    try:
        try:
            receipts.inspect_receipt(**inspect_kwargs)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError("post-capture active replacement was accepted")
    finally:
        receipts._validate_posix_carrier_path = old_inspect_validate
    assert inspect_injected and inspect_public.read_bytes() == b"replacement active after capture\n"

    public_final, token_final, kwargs_final = api_fixture("replace-after-capture")
    final_tomb = pathlib.Path(receipts._tombstone_path(str(public_final), token_final))
    old_final_validate = receipts._validate_posix_carrier_path
    final_injected = False
    final_tomb_validations = 0
    def replace_at_final_validation(directory_fd, name, carrier):
        global final_injected, final_tomb_validations
        if name == final_tomb.name:
            final_tomb_validations += 1
        if not final_injected and final_tomb_validations == 3:
            final_injected = True
            os.unlink(name, dir_fd=directory_fd)
            descriptor = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600,
                dir_fd=directory_fd,
            )
            os.write(descriptor, b"replacement after capture\n")
            os.close(descriptor)
        return old_final_validate(directory_fd, name, carrier)
    receipts._validate_posix_carrier_path = replace_at_final_validation
    try:
        try:
            receipts.retire_receipt(**kwargs_final)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError("post-capture tombstone replacement was accepted")
    finally:
        receipts._validate_posix_carrier_path = old_final_validate
    assert final_injected and final_tomb_validations >= 3
    assert final_tomb.read_bytes() == b"replacement after capture\n"
else:
    inspect_public, inspect_token, inspect_kwargs = api_fixture("inspect-after-capture-windows")
    old_inspect_validate = receipts._validate_windows_carrier_path
    inspect_injected = False
    def replace_windows_active_at_final_validation(path, parent_identity, carrier):
        global inspect_injected
        if not inspect_injected and pathlib.Path(path) == inspect_public:
            inspect_injected = True
            inspect_public.unlink()
            inspect_public.write_bytes(b"replacement active after capture\n")
        return old_inspect_validate(path, parent_identity, carrier)
    receipts._validate_windows_carrier_path = replace_windows_active_at_final_validation
    try:
        try:
            receipts.inspect_receipt(**inspect_kwargs)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError("Windows post-capture active replacement was accepted")
    finally:
        receipts._validate_windows_carrier_path = old_inspect_validate
    assert inspect_injected and inspect_public.read_bytes() == b"replacement active after capture\n"

    public_final, token_final, kwargs_final = api_fixture("replace-after-capture-windows")
    final_tomb = pathlib.Path(receipts._tombstone_path(str(public_final), token_final))
    old_final_validate = receipts._validate_windows_carrier_path
    final_injected = False
    final_tomb_validations = 0
    def replace_at_windows_final_validation(path, parent_identity, carrier):
        global final_injected, final_tomb_validations
        if pathlib.Path(path) == final_tomb:
            final_tomb_validations += 1
        if not final_injected and final_tomb_validations == 3:
            final_injected = True
            final_tomb.unlink()
            final_tomb.write_bytes(b"replacement after capture\n")
        return old_final_validate(path, parent_identity, carrier)
    receipts._validate_windows_carrier_path = replace_at_windows_final_validation
    try:
        try:
            receipts.retire_receipt(**kwargs_final)
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError("Windows post-capture tombstone replacement was accepted")
    finally:
        receipts._validate_windows_carrier_path = old_final_validate
    assert final_injected and final_tomb_validations >= 3
    assert final_tomb.read_bytes() == b"replacement after capture\n"


# A sibling captured as absent is part of the state proof. If it appears only
# at the final boundary, active inspection and both retirement paths fail
# terminal while preserving the competing bytes. This runs through the native
# POSIX or Windows implementation in its corresponding CI job.
def expect_late_sibling_rejected(anchor_path, sibling_path, operation, sentinel):
    state = {"anchor_validations": 0, "injected": False}
    if os.name == "nt":
        old_validate = receipts._validate_windows_carrier_path
        def inject_after_final_anchor(path, parent_identity, carrier):
            result = old_validate(path, parent_identity, carrier)
            if pathlib.Path(path) == anchor_path:
                state["anchor_validations"] += 1
                if state["anchor_validations"] == 3:
                    sibling_path.write_bytes(sentinel)
                    os.chmod(sibling_path, 0o600)
                    state["injected"] = True
            return result
        receipts._validate_windows_carrier_path = inject_after_final_anchor
    else:
        old_validate = receipts._validate_posix_carrier_path
        def inject_after_final_anchor(directory_fd, name, carrier):
            result = old_validate(directory_fd, name, carrier)
            if name == anchor_path.name:
                state["anchor_validations"] += 1
                if state["anchor_validations"] == 3:
                    descriptor = os.open(
                        sibling_path.name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=directory_fd,
                    )
                    os.write(descriptor, sentinel)
                    os.close(descriptor)
                    state["injected"] = True
            return result
        receipts._validate_posix_carrier_path = inject_after_final_anchor
    try:
        try:
            operation()
        except receipts.TerminalReceiptError:
            pass
        else:
            raise AssertionError("late sibling appearance was accepted")
    finally:
        if os.name == "nt":
            receipts._validate_windows_carrier_path = old_validate
        else:
            receipts._validate_posix_carrier_path = old_validate
    assert state["injected"] and state["anchor_validations"] >= 3
    assert sibling_path.read_bytes() == sentinel


late_active_public, late_active_token, late_active_kwargs = api_fixture(
    "late-tombstone-active-inspect"
)
late_active_raw = late_active_public.read_bytes()
late_active_tomb = pathlib.Path(
    receipts._tombstone_path(str(late_active_public), late_active_token)
)
expect_late_sibling_rejected(
    late_active_public,
    late_active_tomb,
    lambda: receipts.inspect_receipt(**late_active_kwargs),
    b"late tombstone during active inspection\n",
)
assert late_active_public.read_bytes() == late_active_raw

late_retired_public, late_retired_token, late_retired_kwargs = api_fixture(
    "late-public-retired-inspect"
)
late_retired_raw = late_retired_public.read_bytes()
assert receipts.retire_receipt(**late_retired_kwargs) == {"state": "retired"}
late_retired_tomb = pathlib.Path(
    receipts._tombstone_path(str(late_retired_public), late_retired_token)
)
expect_late_sibling_rejected(
    late_retired_tomb,
    late_retired_public,
    lambda: receipts.inspect_receipt(**late_retired_kwargs),
    b"late public during retired inspection\n",
)
assert late_retired_tomb.read_bytes() == late_retired_raw

late_retry_public, late_retry_token, late_retry_kwargs = api_fixture(
    "late-public-retirement-retry"
)
late_retry_raw = late_retry_public.read_bytes()
assert receipts.retire_receipt(**late_retry_kwargs) == {"state": "retired"}
late_retry_tomb = pathlib.Path(
    receipts._tombstone_path(str(late_retry_public), late_retry_token)
)
expect_late_sibling_rejected(
    late_retry_tomb,
    late_retry_public,
    lambda: receipts.retire_receipt(**late_retry_kwargs),
    b"late public during retirement retry\n",
)
assert late_retry_tomb.read_bytes() == late_retry_raw

late_fresh_public, late_fresh_token, late_fresh_kwargs = api_fixture(
    "late-public-fresh-retirement"
)
late_fresh_raw = late_fresh_public.read_bytes()
late_fresh_tomb = pathlib.Path(
    receipts._tombstone_path(str(late_fresh_public), late_fresh_token)
)
expect_late_sibling_rejected(
    late_fresh_tomb,
    late_fresh_public,
    lambda: receipts.retire_receipt(**late_fresh_kwargs),
    b"late public during fresh retirement\n",
)
assert late_fresh_tomb.read_bytes() == late_fresh_raw


# The Windows final-binding helper is modeled on every host and runs natively
# on windows-latest.
windows_final_parent = root / "windows-final-binding"
windows_final_parent.mkdir(mode=0o700)
windows_final_path = windows_final_parent / "tombstone.json"
windows_final_path.write_bytes(b"original windows carrier\n")
os.chmod(windows_final_path, 0o600)
windows_parent_identity = (
    os.lstat(windows_final_parent).st_dev,
    os.lstat(windows_final_parent).st_ino,
)
windows_carrier = receipts._open_windows_carrier(
    str(windows_final_path), windows_parent_identity
)
windows_final_path.unlink()
windows_final_path.write_bytes(b"replacement windows carrier\n")
try:
    receipts._validate_windows_carrier_path(
        str(windows_final_path), windows_parent_identity, windows_carrier
    )
except receipts.TerminalReceiptError:
    pass
else:
    raise AssertionError("Windows post-capture replacement was accepted")

# A new exact receipt may claim the newly vacant public name after P->T. It is
# preserved, while the exact old tombstone proves retirement.
foreign_public, foreign_token, foreign_kwargs = api_fixture("new-generation")
old_payload = foreign_public.read_bytes()
new_token = "c" * 32 + ":" + foreign_kwargs["start_head"]
new_payload = receipts._expected_payload(
    foreign_kwargs["repo"], foreign_kwargs["relative"], foreign_kwargs["branch"],
    foreign_kwargs["receipt"], foreign_kwargs["start_head"], new_token,
)
def publish_new_generation(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    raw = receipts._canonical_bytes(new_payload)
    if dir_fd is None:
        pathlib.Path(source_name).write_bytes(raw)
    else:
        fd = os.open(source_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, raw)
        os.close(fd)
receipts.atomic_rename_noreplace = publish_new_generation
try:
    assert receipts.retire_receipt(**foreign_kwargs) == {"state": "retired"}
finally:
    receipts.atomic_rename_noreplace = old_atomic
foreign_tomb = pathlib.Path(receipts._tombstone_path(str(foreign_public), foreign_token))
assert foreign_tomb.read_bytes() == old_payload
assert foreign_public.read_bytes() == receipts._canonical_bytes(new_payload)
assert receipts.inspect_receipt(**foreign_kwargs) == {"state": "retired"}
assert receipts.retire_receipt(**foreign_kwargs) == {"state": "retired"}
assert foreign_tomb.read_bytes() == old_payload
assert foreign_public.read_bytes() == receipts._canonical_bytes(new_payload)

# A valid new generation swapped only after its context was captured must still
# fail final pathname binding. Both the exact old tombstone and the replacement
# public carrier are preserved.
late_public, late_token, late_kwargs = api_fixture("foreign-context-after-capture")
late_old_payload = late_public.read_bytes()
late_new_token = "7" * 32 + ":" + late_kwargs["start_head"]
late_valid_payload = receipts._expected_payload(
    late_kwargs["repo"], late_kwargs["relative"], late_kwargs["branch"],
    late_kwargs["receipt"], late_kwargs["start_head"], late_new_token,
)
late_bad_payload = dict(late_valid_payload)
late_bad_payload["repo"] = str(pathlib.Path(late_kwargs["repo"]).with_name("late-foreign-repo"))
late_bad_payload["relative"] = ".claude/worktrees/solve-issue-88-agent-abcdef123456"
late_bad_payload["branch"] = "worktree-solve-issue-88-agent-abcdef123456"
late_bad_payload["worktree"] = str(
    pathlib.Path(late_bad_payload["repo"]) / late_bad_payload["relative"]
)
late_valid_raw = receipts._canonical_bytes(late_valid_payload)
late_bad_raw = receipts._canonical_bytes(late_bad_payload)
def publish_late_generation(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    if dir_fd is None:
        pathlib.Path(source_name).write_bytes(late_valid_raw)
    else:
        fd = os.open(source_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, late_valid_raw)
        os.close(fd)

late_swapped = False
if os.name == "nt":
    old_late_validate = receipts._validate_windows_carrier_path
    late_public_validations = 0
    def swap_late_public(path, parent_identity, carrier):
        global late_swapped, late_public_validations
        if pathlib.Path(path) == late_public:
            late_public_validations += 1
        if not late_swapped and late_public_validations == 2:
            late_swapped = True
            late_public.unlink()
            late_public.write_bytes(late_bad_raw)
            os.chmod(late_public, 0o600)
        return old_late_validate(path, parent_identity, carrier)
    receipts._validate_windows_carrier_path = swap_late_public
else:
    old_late_validate = receipts._validate_posix_carrier_path
    late_public_validations = 0
    def swap_late_public(directory_fd, name, carrier):
        global late_swapped, late_public_validations
        if name == late_public.name:
            late_public_validations += 1
        if not late_swapped and late_public_validations == 2:
            late_swapped = True
            late_public.unlink()
            late_public.write_bytes(late_bad_raw)
            os.chmod(late_public, 0o600)
        return old_late_validate(directory_fd, name, carrier)
    receipts._validate_posix_carrier_path = swap_late_public
receipts.atomic_rename_noreplace = publish_late_generation
try:
    try:
        receipts.retire_receipt(**late_kwargs)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("post-capture foreign public replacement was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
    if os.name == "nt":
        receipts._validate_windows_carrier_path = old_late_validate
    else:
        receipts._validate_posix_carrier_path = old_late_validate
late_tomb = pathlib.Path(receipts._tombstone_path(str(late_public), late_token))
assert late_swapped and late_public_validations >= 2
assert late_tomb.read_bytes() == late_old_payload
assert late_public.read_bytes() == late_bad_raw
for operation in (receipts.inspect_receipt, receipts.retire_receipt):
    try:
        operation(**late_kwargs)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("late foreign context gained retired authority")
assert late_tomb.read_bytes() == late_old_payload
assert late_public.read_bytes() == late_bad_raw

# A canonical-looking foreign generation is accepted only when every bound
# context field still matches this receipt. A different repo/relative/branch/
# worktree tuple is preserved alongside the exact old tombstone and rejected.
mismatch_public, mismatch_token, mismatch_kwargs = api_fixture("foreign-context")
mismatch_old_payload = mismatch_public.read_bytes()
mismatch_token_new = "e" * 32 + ":" + mismatch_kwargs["start_head"]
alternate_repo = str(pathlib.Path(mismatch_kwargs["repo"]).with_name("alternate-repo"))
alternate_relative = ".claude/worktrees/solve-issue-77-agent-fedcba987654"
alternate_branch = "worktree-solve-issue-77-agent-fedcba987654"
mismatch_payload = receipts._expected_payload(
    alternate_repo,
    alternate_relative,
    alternate_branch,
    mismatch_kwargs["receipt"],
    mismatch_kwargs["start_head"],
    mismatch_token_new,
)
def publish_mismatched_generation(source_name, destination_name, *, dir_fd=None):
    old_atomic(source_name, destination_name, dir_fd=dir_fd)
    raw = receipts._canonical_bytes(mismatch_payload)
    if dir_fd is None:
        pathlib.Path(source_name).write_bytes(raw)
    else:
        fd = os.open(source_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        os.write(fd, raw)
        os.close(fd)
receipts.atomic_rename_noreplace = publish_mismatched_generation
try:
    try:
        receipts.retire_receipt(**mismatch_kwargs)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("foreign context mismatch was accepted")
finally:
    receipts.atomic_rename_noreplace = old_atomic
mismatch_tomb = pathlib.Path(
    receipts._tombstone_path(str(mismatch_public), mismatch_token)
)
assert mismatch_tomb.read_bytes() == mismatch_old_payload
assert mismatch_public.read_bytes() == receipts._canonical_bytes(mismatch_payload)
for operation in (receipts.inspect_receipt, receipts.retire_receipt):
    try:
        operation(**mismatch_kwargs)
    except receipts.TerminalReceiptError:
        pass
    else:
        raise AssertionError("foreign context mismatch gained retired authority")
assert mismatch_tomb.read_bytes() == mismatch_old_payload
assert mismatch_public.read_bytes() == receipts._canonical_bytes(mismatch_payload)

# Permanent tombstones are an absorbing state: production code contains no
# unlink, remove, replace, rollback, or restore operation targeting them.
source_text = pathlib.Path(receipt_path).read_text(encoding="utf-8")
for forbidden in ("os.unlink", ".unlink(", "os.remove", "os.replace", "rollback", "restore"):
    if forbidden in source_text:
        raise AssertionError(f"forbidden tombstone disposal surface: {forbidden}")

print("worktree-receipts: lifecycle, collision, race, and platform contracts passed")
PY

python3 -I -B - "$ATOMIC" "$RECEIPTS" "$PLANNING" <<'PY'
import ast
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    source = path.read_text(encoding="utf-8")
    ast.parse(source, filename=str(path), feature_version=(3, 10))
    compile(source, str(path), "exec")
PY
printf 'worktree-receipts: PASS\n'
