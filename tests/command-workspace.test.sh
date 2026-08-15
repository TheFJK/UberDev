#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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

# #402 — declared-vs-consumed guard. CALLERS is the single source of truth for
# the workspace artifact vocabulary, but the artifact PATH GLOBALS it produces
# are consumed by hand-written command docs that CALLERS cannot see. The #402
# drift was exactly that gap: review-pr.md consumed $AGG_PATH while
# CALLERS["review-pr"] declared no "aggregate" artifact, so the prepare exported
# an empty string and every Phase 1 aggregation returned 70.
#
# CONTRACT: for each caller doc, referenced globals must be a SUBSET of the
# globals its caller declares. Subset only — do NOT tighten this to equality.
# Declaring an artifact a doc never expands by name is legitimate (review-pr
# declares "criteria" and hands CRITERIA_PATH to its child through the
# descriptor, not through a $CRITERIA_PATH expansion in its own prose), and an
# equality check would red on that.
python3 -I -B - "$HELPER" \
  "$ROOT/plugins/uberdev/commands/review-pr.md" \
  "$ROOT/plugins/uberdev/commands/simplify.md" \
  "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md" <<'PY'
import importlib.util
import pathlib
import re
import sys

module_path, review_doc, simplify_doc, post_impl_doc = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("command_workspace_vocabulary", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# The artifact-key -> shell-global map must be a module-level constant so this
# guard can read the same mapping main() uses, instead of a second copy.
mapping = module.NAME_TO_GLOBAL
declared_keys = set().union(*(set(caller["artifacts"]) for caller in module.CALLERS.values()))
missing_keys = sorted(declared_keys - set(mapping))
assert not missing_keys, f"CALLERS declares artifacts with no NAME_TO_GLOBAL entry: {missing_keys}"

for caller, doc_path in (
    ("review-pr", review_doc),
    ("simplify", simplify_doc),
    ("post-impl-review", post_impl_doc),
):
    declared = {mapping[key] for key in module.CALLERS[caller]["artifacts"]}
    if caller == "post-impl-review":
        # The child inherits every parent artifact global (main() overlays the
        # parent descriptor onto expected_globals), so its doc may reference the
        # full review-pr set as well.
        declared |= {mapping[key] for key in module.CALLERS["review-pr"]["artifacts"]}
    text = pathlib.Path(doc_path).read_text(encoding="utf-8")
    referenced = {
        global_name for global_name in mapping.values()
        if re.search(r"\$\{?" + global_name + r"\b", text)
    }
    undeclared = sorted(referenced - declared)
    assert not undeclared, (
        f"{caller} consumes artifact globals its CALLERS entry does not declare: {undeclared} "
        f"(an undeclared global is exported as the empty string)"
    )
PY

# #471 — "one comparator for 'same location'", made enforceable.
#
# The fix that introduced same_validated_path claimed the two call sites "cannot
# drift again". Nothing in CI held that claim: the only mentions of the name
# under tests/ were PROSE COMMENTS, which is precisely the state #370 exists to
# call out -- auditable by a human, enforced by nothing. This block is the
# producer that comment was not.
#
# WHY NOT A `CONTRACT:` MARKER. The #371 mechanism (tests/contract_markers.py)
# compares closed TOKEN VOCABULARIES: it extracts a member SET from a marked
# region and requires every marked site to yield the same set, with MIN_MEMBERS
# = 2. "Both call sites route through one function" is not a token set -- there
# is no vocabulary to extract, the extractor would find zero members and fail
# loudly, and a marker parked next to it would be decorative. A guard that sits
# in CI and covers nothing is `tests/component-token-schema.py`, the register's
# own cautionary tale. So this is the other option the convention allows: a real
# structural guard, in the test file that already owns this module.
#
# WHAT IT ASSERTS. Every comparison in command-workspace.py that asks "do two
# path spellings name one place" is registered here with the reason it is not
# same_validated_path. Detection is AST, in two rules, because one is not
# enough:
#   (a) a Compare that CALLS a canonicaliser -- realpath / abspath / normcase /
#       commonpath / samefile / portable_canonical / portable_directory /
#       same_portable_path / same_validated_path, local aliases resolved
#       (portable_canonical binds `normalize = os.path.normcase`);
#   (b) a Compare over a NAME BOUND from one earlier in the same function. Rule
#       (a) alone misses the third copy this guard was written for --
#       `git_toplevel == repo` in load_carrier, where the realpath is on the
#       assignment line, not in the comparison.
#
# LIMITS, stated rather than implied. The key is (function, canonicalisers,
# derived operands, operators), so an expression REPLACED by a different one
# with the same signature in the same function is invisible; behaviour is held
# by the executable rows below, not by this. Rule (b) is function-local, so a
# canonical spelling that crosses a function boundary is not tracked -- main()'s
# `repo` comes back from load_carrier and its descriptor comparison is byte
# equality between two values this helper itself produced, which is correct
# there and is why main() is legitimately absent from the registry.
python3 -I -B - "$HELPER" <<'PY'
import ast
import sys
from collections import Counter

# Functions that PRODUCE a canonical path spelling, or that ARE a spelling
# comparison. A Compare touching any of these is asking the guarded question.
CANONICALISERS = frozenset({
    "realpath", "abspath", "normcase", "commonpath", "samefile",
    "portable_canonical", "portable_directory",
    "same_portable_path", "same_validated_path",
})

# key: (function, canonicalisers, derived operands, operators) -> (count, reason)
# Every entry is a comparison that is NOT routed through same_validated_path,
# with the reason it asks a different question. Adding a hand-rolled copy adds a
# key (or bumps a count) and reds; deleting one drops a key and reds.
REGISTRY: dict[tuple, tuple[int, str]] = {
    ("same_validated_path", ("realpath",), (), ("Eq",)): (
        1,
        "THE comparator. descriptor_relative arm.",
    ),
    ("same_portable_path", ("abspath", "normcase"), (), ("Eq",)): (
        1,
        "THE comparator's portable_windows arm, called only by same_validated_path.",
    ),
    ("portable_canonical", ("normcase",), (), ("NotEq",)): (
        2,
        "A DIFFERENT question: 'is this spelling ALREADY canonical', asked of one "
        "path against its own abspath/realpath. Never compares two caller values.",
    ),
    ("load_carrier", ("normcase",), (), ("NotEq",)): (
        1,
        "A DIFFERENT question: is the state directory's BASENAME the per-uid name. "
        "Filename equality, not a location comparison.",
    ),
    ("load_carrier", (), ("repo",), ("NotEq",)): (
        1,
        "A DIFFERENT question: 'is repository_id ALREADY canonical', the "
        "descriptor_relative twin of portable_canonical's check (`repo = "
        "realpath(repo_raw)` then `repo != repo_raw`). Deliberately strict: the "
        "carrier's repository_id is AUTHORITY-BEARING, so an alias spelling is "
        "REFUSED here rather than normalised -- the opposite of what a preset, "
        "which carries no authority, needs.",
    ),
    ("load_carrier", ("abspath", "normcase"), (), ("Eq",)): (
        1,
        "UNENFORCED-INVARIANT RESIDUE (#471), registered rather than rewritten. "
        "This is the portable_windows arm of the same_toplevel check, and it is "
        "character-for-character what same_portable_path computes -- the same "
        "algebra written out a third time. It is CORRECT today, and load-bearing: "
        "Git for Windows spells --show-toplevel with forward slashes while "
        "portable_directory returned the abspath backslash spelling, so the "
        "normalisation is doing real work. It is also the copy that would drift, "
        "which is why it is pinned here. Not rewritten in this commit: it compares "
        "the helper's OWN probe of the repository, not a caller-supplied scalar, "
        "and same_validated_path now carries an isabs precondition and a mode "
        "dispatch neither operand needs. Rewriting a security check with no test "
        "that can tell the two versions apart is how the #471 traceback happened.",
    ),
    ("load_carrier", (), ("repo",), ("Eq",)): (
        1,
        "The descriptor_relative arm of that same same_toplevel expression, and "
        "the raw `git_toplevel == repo` a reviewer named as the third copy of the "
        "guarded question. No live defect is provable: the canonicality check "
        "above has already refused any repository_id that is not its own realpath, "
        "and git is invoked with `-C repo`, so both operands are canonical by the "
        "time this runs. The INVARIANT was still unenforced, which is what this "
        "registry fixes.",
    ),
    ("beneath", ("commonpath",), (), ("Eq",)): (
        1,
        "A DIFFERENT question: CONTAINMENT ('is path under root'), not identity.",
    ),
    ("portable_beneath", ("normcase",), (), ("Eq",)): (
        1,
        "The portable_windows twin of beneath. Containment, not identity.",
    ),
}

# The one comparator must be REACHED from both call sites; a registry of
# non-copies proves nothing if the comparator itself is dead code.
EXPECTED_CALLERS = {"validate_presets", "validate_requested_root"}

source = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(source)
lines = source.splitlines()


def called(node: ast.AST) -> set[str]:
    names: set[str] = set()
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call):
            func = sub.func
            if isinstance(func, ast.Attribute):
                names.add(func.attr)
            elif isinstance(func, ast.Name):
                names.add(func.id)
    return names


found: Counter = Counter()
where: dict[tuple, list[str]] = {}
callers_of_comparator: set[str] = set()

for fn in ast.walk(tree):
    if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
    if "same_validated_path" in called(fn) and fn.name != "same_validated_path":
        callers_of_comparator.add(fn.name)
    alias: dict[str, str] = {}
    derived: set[str] = set()
    for sub in ast.walk(fn):
        if not isinstance(sub, ast.Assign) or len(sub.targets) != 1:
            continue
        target, value = sub.targets[0], sub.value
        if (isinstance(target, ast.Name) and isinstance(value, ast.Attribute)
                and value.attr in CANONICALISERS):
            alias[target.id] = value.attr
        if isinstance(value, ast.Call) and called(value) & CANONICALISERS:
            if isinstance(target, ast.Name):
                derived.add(target.id)
            elif isinstance(target, ast.Tuple) and target.elts and isinstance(target.elts[0], ast.Name):
                # portable_directory returns (canonical_path, stat_result); only
                # element 0 is a spelling.
                derived.add(target.elts[0].id)
    for sub in ast.walk(fn):
        if not isinstance(sub, ast.Compare):
            continue
        via = tuple(sorted({alias.get(n, n) for n in called(sub)} & CANONICALISERS))
        operands = [sub.left, *sub.comparators]
        touched = tuple(sorted({
            node.id for node in operands
            if isinstance(node, ast.Name) and node.id in derived
        }))
        if not via and not touched:
            continue
        key = (fn.name, via, touched, tuple(type(op).__name__ for op in sub.ops))
        found[key] += 1
        where.setdefault(key, []).append(
            f"{fn.name}:{sub.lineno}: {lines[sub.lineno - 1].strip()}"
        )

expected = Counter({key: count for key, (count, _reason) in REGISTRY.items()})
if found != expected:
    report = ["command-workspace.py path-comparison registry is out of date.", ""]
    for key in sorted(set(found) | set(expected), key=repr):
        got, want = found.get(key, 0), expected.get(key, 0)
        if got == want:
            continue
        report.append(f"  {key}: registered {want}, found {got}")
        report.extend(f"      {site}" for site in where.get(key, ()))
    report += [
        "",
        "Every comparison asking 'do two path spellings name one place' must",
        "either route through same_validated_path or be registered above with",
        "the reason it asks a DIFFERENT question. A new unregistered copy is the",
        "#370 drift class -- one invariant, N uncompared expressions -- which is",
        "what produced the preset_mismatch blocker #471 fixed.",
    ]
    raise SystemExit("\n".join(report))

# Neither validator may hold a comparison of its own: that is the whole claim.
for owner in EXPECTED_CALLERS:
    assert not [key for key in found if key[0] == owner], (
        f"{owner} hand-rolls a path comparison instead of calling same_validated_path"
    )
assert callers_of_comparator == EXPECTED_CALLERS, (
    "same_validated_path is called by "
    f"{sorted(callers_of_comparator)}, expected {sorted(EXPECTED_CALLERS)} -- a "
    "registry of non-copies proves nothing if the one comparator is unreached."
)
print("command-workspace-path-comparison-registry-ok")
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

    # #471 — the preset check and the requested-root check must answer the SAME
    # question the same way. They did not: validate_requested_root normalised,
    # validate_presets byte-compared, so on a native Windows runner the one
    # inherited scalar the review-pr fence forwards ($WORKTREE_ROOT) passed the
    # first and was refused by the second, and /review-pr, /simplify and
    # post-impl-review all died on `preset_mismatch` before allocating anything.
    #
    # The divergence is SEPARATOR SPELLING, and it is structural, not incidental:
    # `repository_id` arrives from `git rev-parse --show-toplevel`, which Git for
    # Windows spells with forward slashes, while portable_canonical hands back
    # ntpath.abspath's backslash spelling. load_carrier already normcase-compares
    # those two for exactly this reason -- validate_presets was the one place
    # that did not. Simulated with ntpath here because the module is exercised on
    # a POSIX runner; ntpath.normcase is `s.replace("/", "\\").lower()`, which is
    # the whole of the algebra under test.
    #
    # The two spellings are written out LITERALLY rather than derived from the
    # fixture path. Deriving them (`str(repo).replace(os.sep, "/")`) is vacuous
    # on a POSIX runner -- os.sep is already "/" there, so both sides come out
    # byte-identical and the row passes with the defect fully restored.
    # validate_presets compares strings and touches no filesystem, so a synthetic
    # drive-letter pair is the honest input; `RUNNER~1` is the real 8.3 %TEMP%
    # spelling windows-latest hands the job.
    forward_spelled = "C:/Users/RUNNER~1/AppData/Local/Temp/uberdev/repository"
    windows_repo = ntpath.abspath(forward_spelled)
    assert "\\" in windows_repo and windows_repo != forward_spelled, windows_repo
    windows_workspace = ntpath.join(
        windows_repo, ".uberdev", "research", f"20260727-01020{index}-abcdef0"
    )
    real_normcase = module.os.path.normcase
    real_abspath = module.os.path.abspath
    # isabs BELONGS to the simulated arm: same_validated_path refuses a relative
    # candidate, and posixpath.isabs("C:/Users/...") is False, so leaving the real
    # one in place would refuse a perfectly good Windows spelling and make this
    # row assert the opposite of what it claims. On a native Windows runner
    # os.path IS ntpath, so patching all three is what "simulate that runner"
    # means -- patching two of them simulates a machine that does not exist.
    real_isabs = module.os.path.isabs
    module.os.path.normcase = ntpath.normcase
    module.os.path.abspath = ntpath.abspath
    module.os.path.isabs = ntpath.isabs
    try:
        module.validate_presets(
            {"WORKTREE_ROOT": forward_spelled},
            {},
            windows_repo,
            windows_workspace,
            "portable_windows",
        )
        # #471 follow-up: absoluteness is part of the question on BOTH arms.
        #
        # The CWD is rigged to the repository's PARENT, which is what makes this
        # row non-vacuous rather than a restatement of the row above. ntpath's
        # POSIX abspath is `normpath(join(os.getcwd(), path))`, so with getcwd
        # pointing there the relative spelling `repository` resolves to exactly
        # windows_repo and same_portable_path would say YES. Left unrigged, a
        # POSIX cwd can never join to a `C:\` path, the comparison fails for the
        # wrong reason, and the row passes with the defect fully restored --
        # the same vacuity trap the forward/backslash pair above documents.
        # A setup fence whose CWD sits in the repository tree is the ordinary
        # case, not a contrived one.
        real_getcwd = module.os.getcwd
        module.os.getcwd = lambda: ntpath.dirname(windows_repo)
        try:
            assert ntpath.normcase(ntpath.abspath("repository")) == ntpath.normcase(
                windows_repo
            ), "cwd rig failed -- the relative spelling no longer resolves to the repo"
            expect_failure(
                module,
                "preset_mismatch:WORKTREE_ROOT",
                lambda: module.validate_presets(
                    {"WORKTREE_ROOT": "repository"},
                    {},
                    windows_repo,
                    windows_workspace,
                    "portable_windows",
                ),
            )
        finally:
            module.os.getcwd = real_getcwd
        # Non-vacuous: a genuinely different location is still refused, and the
        # refusal now NAMES the disagreeing scalar. One anonymous word for nine
        # values is what made the Windows log unattributable in the first place.
        expect_failure(
            module,
            "preset_mismatch:WORKTREE_ROOT",
            lambda: module.validate_presets(
                {"WORKTREE_ROOT": ntpath.join(windows_repo, "elsewhere")},
                {},
                windows_repo,
                windows_workspace,
                "portable_windows",
            ),
        )
        # A preset key this caller never declared can never name "the same
        # location", so it stays refused rather than being skipped as unknown.
        expect_failure(
            module,
            "preset_mismatch:UNDECLARED_PATH",
            lambda: module.validate_presets(
                {"UNDECLARED_PATH": windows_repo},
                {},
                windows_repo,
                windows_workspace,
                "portable_windows",
            ),
        )
    finally:
        module.os.path.normcase = real_normcase
        module.os.path.abspath = real_abspath
        module.os.path.isabs = real_isabs

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
  # #381: `codex` is gone from the backend enum and `routing_mode:"adaptive"`
  # is now refused with route_unenforceable, so a carrier can no longer be
  # sealed from either. This fixture is about workspace identity, not routing --
  # `workflow` with no routing_mode is the shape a real /review-pr carrier has.
  request="$(jq -cn --arg run "$run" --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{schema_version:1,run_dir:$run,run_id:$run_id,repository_id:$repo,backend:"workflow",workflow:$workflow,phase:"review",role:"lead",task_tier:"medium",risk_signals:[],issue_or_pr:$issue,issue_num:$issue,capacity:6,timeout_s:600}')"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(jq -cn --arg repo "$repo" --arg workflow "$workflow" --arg run_id "root-$workflow" --argjson issue "$issue" \
    '{run_id:$run_id,repository_id:$repo,workflow:$workflow,backend:"workflow",issue_num:$issue,task_tier:"medium",risk_signals:[]}')"
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
# #402 — the review-pr caller owns the Phase 1 aggregate. Without this
# declaration child-dispatch.sh exported AGG_PATH="" and the Phase 1 fence
# handed an empty destination to post_review_write_aggregate_v2, which returns
# unsafe-output; the fence then returned 70 on every run and Phase 2 never ran.
[ "$AGG_PATH" = "$EXPECTED/post-impl-review-final.md" ]
for path in "$DIFF_ARTIFACT_PATH" "$CRITERIA_PATH" "$COMMIT_RANGE_PATH" "$PHASE1_DISPOSITION_PATH" "$PHASE2_DISPOSITION_PATH" "$AGG_PATH"; do
  [ "$(file_mode "$path")" = 600 ]
  [ "$(file_link_count "$path")" = 1 ]
done
[ ! -s "$PHASE1_DISPOSITION_PATH" ]
[ ! -s "$PHASE2_DISPOSITION_PATH" ]
[ ! -s "$AGG_PATH" ]
grep -q '^<external-untrusted-input source="pr-diff">$' "$DIFF_ARTIFACT_PATH"
jq -e '.caller=="review-pr" and .carrier_workflow=="solve" and .repository_root==$repo and .research_dir==$research and (.artifacts|keys)==["aggregate","commit_range","criteria","diff","phase1_disposition","phase2_disposition"]' \
  --arg repo "$REPO" --arg research "$EXPECTED" <<<"$UBERDEV_COMMAND_WORKSPACE_JSON" >/dev/null

# Re-entry preserves safe existing bytes.
printf 'preserve-me\n' >"$CRITERIA_PATH"; chmod 600 "$CRITERIA_PATH"
printf 'agg-preserve-me\n' >"$AGG_PATH"; chmod 600 "$AGG_PATH"
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null
grep -qx 'preserve-me' "$CRITERIA_PATH"
# A re-prepare must never truncate an aggregate Phase 1 already wrote.
grep -qx 'agg-preserve-me' "$AGG_PATH"
[ "$(file_mode "$AGG_PATH")" = 600 ]

# Artifact globals are output-only; a mismatched preset fails without touching it.
OUTSIDE="$TMP/outside-sentinel"
printf 'sentinel\n' >"$OUTSIDE"
DIFF_ARTIFACT_PATH="$OUTSIDE"
if uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null 2>&1; then
  echo 'mismatched artifact override accepted' >&2; exit 1
fi
grep -qx sentinel "$OUTSIDE"
DIFF_ARTIFACT_PATH="$EXPECTED/pr-diff.md"

# #471 — the descriptor_relative half of same_validated_path, on the real arm
# this runner executes.
#
# Callers forward whatever $WORKTREE_ROOT the invoking session exported;
# review-pr.md, simplify.md and post-impl-review/SKILL.md all pass it through
# untouched. `$REPO/.` and `$REPO//` name the repository as surely as `$REPO`
# does, and validate_requested_root -- which runs one step EARLIER on the very
# same string -- accepts them, because it realpath()s. validate_presets used raw
# `!=`, so it refused them: the same pair of values, two comparators, opposite
# verdicts (#370 class). On macOS that made every logical $TMPDIR spelling fail
# under the /var -> /private/var symlink, and tests/review-pr.test.sh papered
# over it with `pwd -P` instead of fixing it here.
for SPELLING in "$REPO/." "$REPO//" "$REPO/./"; do
  unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
  WORKTREE_ROOT="$SPELLING"
  uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$SPELLING" >/dev/null \
    || { echo "equivalent WORKTREE_ROOT spelling refused: $SPELLING" >&2; exit 1; }
  # The descriptor still publishes the ONE canonical spelling, so accepting an
  # alias grants it no authority -- child-dispatch.sh rebinds every scalar from
  # this output. That is what makes the normalising comparator safe here.
  [ "$WORKTREE_ROOT" = "$REPO" ] || { echo "alias spelling leaked into the descriptor: $WORKTREE_ROOT" >&2; exit 1; }
done
# Non-vacuous: a scalar naming a DIFFERENT directory is still refused, and the
# refusal names the scalar rather than saying `preset_mismatch` for all nine.
unset UBERDEV_COMMAND_WORKSPACE_JSON WORKTREE_ROOT RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
WORKTREE_ROOT="$REPO/.uberdev"
PRESET_REFUSAL="$(uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" 2>&1 >/dev/null)" && {
  echo 'a WORKTREE_ROOT naming a different directory was accepted' >&2; exit 1; }
case "$PRESET_REFUSAL" in
  *preset_mismatch:WORKTREE_ROOT*) ;;
  *) echo "preset refusal did not name the disagreeing scalar: $PRESET_REFUSAL" >&2; exit 1 ;;
esac
unset WORKTREE_ROOT || true
uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" >/dev/null

# #471 follow-up — a RELATIVE preset spelling is refused even when the process
# CWD makes it name the right directory.
#
# The first edition of same_validated_path left os.path.isabs() behind in
# validate_requested_root, so the two call sites STILL did not ask the same
# question: requested-root refused a relative spelling, presets realpath'd it
# against the process CWD and accepted it. Run from inside the repository,
# WORKTREE_ROOT="." resolved to $REPO and returned rc 0 -- accepted where the
# pre-#471 byte comparison had refused it. The value is discarded either way, so
# nothing was exploitable; the defect is that the answer depended on state this
# helper neither controls nor validates, which is a WEAKER question, not the
# same one. This row runs the fence FROM $REPO so a comparator that resolves
# against CWD gets every chance to say yes.
RELATIVE_REFUSAL="$(
  cd "$REPO" || exit 3
  unset UBERDEV_COMMAND_WORKSPACE_JSON RESEARCH_DIR_ABS DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH STANDALONE_SNAPSHOT_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH || true
  WORKTREE_ROOT=.
  uberdev_command_workspace_prepare review-pr 77 medium '[]' "$RUN_ID" "$REPO" 2>&1 >/dev/null
)" && { echo 'a relative WORKTREE_ROOT was resolved against the process CWD and accepted' >&2; exit 1; }
case "$RELATIVE_REFUSAL" in
  *preset_mismatch:WORKTREE_ROOT*) ;;
  *) echo "relative preset refusal did not name the scalar: $RELATIVE_REFUSAL" >&2; exit 1 ;;
esac

# #471 follow-up — every ILL-SHAPED preset value is a typed refusal, never a
# traceback.
#
# validate_presets hands each value straight to os.path, which raises TypeError
# on a non-str and ValueError on an embedded NUL. Neither is a Failure, and
# cli() catches Failure only, so both escaped as a Python traceback on rc 1 --
# printing this install's absolute paths -- where every other refusal on this
# untrusted-argv surface is rc 2 plus one reason word.
#
# Driven through the HELPER, not through uberdev_command_workspace_prepare: that
# wrapper builds the JSON from nine shell scalars, which are str by construction
# and cannot carry a NUL (execve forbids it in argv), so it cannot express these
# inputs at all. The hand-built payload is the reachable one and therefore the
# one that matters -- `--presets-json` is argv on a security boundary.
#
# The NUL is written as the JSON escape \u0000. A literal NUL byte in a shell
# script is not portable and does not survive most editors; json.loads decodes
# the escape into the real character, which is what reaches Python.
#
# The LONE SURROGATE \ud800 is the ninth shape, and the reason this list is not
# just "non-str plus NUL". It IS a str and carries no NUL, so it passes both of
# those tests and still raises UnicodeEncodeError inside os.path.realpath -- the
# identical untyped escape on the identical surface. A gate that refuses eight
# of nine shapes reads exactly like a complete one, so the ninth is pinned here
# rather than left for the type check to imply.
#
# Its counterpart \udcff is deliberately NOT in this list, because it must be
# ACCEPTED: a raw invalid UTF-8 byte in a real pathname arrives that way through
# PEP 383 surrogateescape and round-trips back through os.fsencode. Refusing
# every surrogate would make a legal POSIX repository path unusable.
SHAPE_RUN_ID=20260710-010209-abcdef0
for BAD_PRESET in \
  '{"WORKTREE_ROOT": 5}' \
  '{"WORKTREE_ROOT": ["a"]}' \
  '{"WORKTREE_ROOT": {"a": 1}}' \
  '{"WORKTREE_ROOT": true}' \
  '{"WORKTREE_ROOT": "\u0000/tmp"}' \
  '{"WORKTREE_ROOT": "/tmp/\ud800"}'; do
  SHAPE_ERR="$TMP/preset-shape.stderr"
  SHAPE_RC=0
  python3 -I -B "$HELPER" --caller review-pr --carrier-json "$SOLVE_CARRIER" \
    --run-id "$SHAPE_RUN_ID" --presets-json "$BAD_PRESET" >/dev/null 2>"$SHAPE_ERR" \
    || SHAPE_RC=$?
  # rc 2 is the typed-refusal contract; an uncaught Python exception exits 1.
  [ "$SHAPE_RC" = 2 ] || {
    echo "ill-shaped preset $BAD_PRESET exited $SHAPE_RC, not 2:" >&2; cat "$SHAPE_ERR" >&2; exit 1; }
  grep -q '^uberdev command workspace: invalid_presets:WORKTREE_ROOT$' "$SHAPE_ERR" || {
    echo "ill-shaped preset $BAD_PRESET did not name the scalar:" >&2; cat "$SHAPE_ERR" >&2; exit 1; }
  # Asserted separately from the rc: a future refactor could keep rc 2 while
  # printing a traceback alongside the reason, and that still leaks paths.
  ! grep -q 'Traceback (most recent call last)' "$SHAPE_ERR" || {
    echo "ill-shaped preset $BAD_PRESET printed a traceback:" >&2; cat "$SHAPE_ERR" >&2; exit 1; }
  # Fails CLOSED: the shape gate runs before allocate_workspace, so a refused
  # payload leaves no workspace behind for the next caller to re-enter.
  [ ! -e "$REPO/.uberdev/research/$SHAPE_RUN_ID" ] || {
    echo "ill-shaped preset $BAD_PRESET allocated a workspace" >&2; exit 1; }
done
# Non-vacuous: the SAME run id, same carrier, well-shaped values -> rc 0. Without
# this the loop above would still pass if the helper refused every payload.
python3 -I -B "$HELPER" --caller review-pr --carrier-json "$SOLVE_CARRIER" \
  --run-id "$SHAPE_RUN_ID" --presets-json "$(jq -cn --arg r "$REPO" '{WORKTREE_ROOT:$r}')" >/dev/null
[ -d "$REPO/.uberdev/research/$SHAPE_RUN_ID" ]

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

# THE ARITY. `uberdev_command_workspace_prepare` hard-refuses anything but six
# arguments (`[ "$#" -eq 6 ]`, above), so a call site that passes none aborts
# rc=2 on its own line before it derives RESEARCH_DIR_ABS or WORKTREE_ROOT.
# `commands/review-pr.md` shipped twelve zero-argument calls — one at the head
# of every Phase 3 fence — and every one of them killed its fence before any
# counter, authority, sidecar or push logic ran. Nothing caught it: the runtime
# rows above always pass six arguments, and the prose rows above only assert the
# NAME appears. This row parses each markdown call site's own argument list.
workspace_arity_of() {
  # One call line -> its argument count, honouring quoted arguments that
  # contain spaces (`"${WORKTREE_ROOT:-}"`, `'[]'`) and stopping at a trailing
  # redirection or `||`. Emits the count, or `bad` when the line is unparseable.
  python3 -I -B - "$1" <<'PY'
import re, shlex, sys
line = sys.argv[1].strip()
line = re.split(r'\s(?:\|\||&&|[0-9]?>|\|)', line, maxsplit=1)[0]
try:
    fields = shlex.split(line, comments=False)
except ValueError:
    print('bad'); raise SystemExit(0)
if not fields or fields[0] != 'uberdev_command_workspace_prepare':
    print('bad'); raise SystemExit(0)
print(len(fields) - 1)
PY
}
workspace_call_sites() {
  # One markdown file -> every line that CALLS the helper, as `LINE:TEXT`, with
  # comment rows dropped so prose about the helper is never parsed as a call.
  # This lives in a function so the fixture probe below greps with the very
  # pattern the corpus rows grep with: two copies of the regex would let the
  # probe stay green while the corpus row silently rotted past it. Optional `$2`
  # lets that probe replay the identical pattern under a second grep
  # implementation without duplicating the pattern.
  #
  # The terminator is `([[:space:]]|$)`, never a bare `[[:space:]]`: a
  # zero-argument call ends the line right after the name, so a space-only
  # terminator cannot match the one shape this whole row exists to catch. With
  # it, the grep returned nothing, the caller's `while` body never ran,
  # `WORKSPACE_ARITY_BAD` stayed 0, and the guard passed while blind to its own
  # motivating bug.
  local matcher="${2:-grep}"
  "$matcher" -nE '(^|[^_[:alnum:]])uberdev_command_workspace_prepare([[:space:]]|$)' "$1" \
    | "$matcher" -v '^[0-9]*:[[:space:]]*#' || true
}
WORKSPACE_ARITY_BAD=0
for doc in "$ROOT/plugins/uberdev/commands/review-pr.md" "$ROOT/plugins/uberdev/commands/simplify.md" "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hit_line="${hit%%:*}"
    hit_text="${hit#*:}"
    arity="$(workspace_arity_of "$hit_text")"
    if [ "$arity" != 6 ]; then
      echo "workspace prepare arity is $arity, expected 6: $doc:$hit_line" >&2
      WORKSPACE_ARITY_BAD=1
    fi
  done <<EOF_WORKSPACE_ARITY
$(workspace_call_sites "$doc")
EOF_WORKSPACE_ARITY
done
[ "$WORKSPACE_ARITY_BAD" -eq 0 ] || { echo 'a markdown call site does not pass CALLER SUBJECT TIER RISK_JSON RUN_ID REQUESTED_ROOT' >&2; exit 1; }

# Anti-vacuity: the parser must actually count, and it must actually red on the
# zero-argument shape that shipped.
[ "$(workspace_arity_of 'uberdev_command_workspace_prepare review-pr "$PR_NUMBER" medium "$RISK_JSON" "$RUN_ID" "${WORKTREE_ROOT:-}" >/dev/null || {')" = 6 ]
[ "$(workspace_arity_of '    uberdev_command_workspace_prepare || return 2')" = 0 ]
[ "$(workspace_arity_of "uberdev_command_workspace_prepare simplify 0 medium '[]' \"\$RUN_ID\" \"\${WORKTREE_ROOT:-}\" >/dev/null || {")" = 6 ]

# Anti-vacuity for the GREP, not just the parser. The three rows above hand
# `workspace_arity_of` a hand-built string, so they exercise the parser and never
# the corpus grep — and the zero-argument one among them ends in ` || return 2`,
# so the only reason it looks covered is that trailing space. A real bare call
# ends the line at the name, and a terminator of `[[:space:]]` alone cannot match
# end-of-line: the `while` body never runs, `WORKSPACE_ARITY_BAD` stays 0, and
# the corpus row passes while blind to the exact twelve-call shape it was written
# for. So mint that shape in a fixture and require the pipeline itself to surface
# it. `workspace_arity_of` is asserted on the same hit so a grep that matched but
# handed the parser a truncated line still reds.
workspace_grep_fixture_probe() {
  # `$1` is the grep binary to replay the corpus pattern with.
  local hits bare
  hits="$(workspace_call_sites "$WORKSPACE_FIXTURE_DOC" "$1")"
  bare="$(printf '%s\n' "$hits" | grep '^2:' || true)"
  [ -n "$bare" ] || { echo "$1: corpus grep is blind to a bare zero-argument call at end of line" >&2; return 1; }
  [ "$(workspace_arity_of "${bare#*:}")" = 0 ] || { echo "$1: bare call parsed as $(workspace_arity_of "${bare#*:}") arguments, expected 0" >&2; return 1; }
  # Herestrings, not `printf | grep -q`: `-q` exits at the first match and the
  # writer takes SIGPIPE, which is the shape tests/epipe-guard.test.sh forbids
  # anywhere in a `pipefail` file. A herestring has no writer process at all.
  grep -q '^1:' <<<"$hits" || { echo "$1: corpus grep lost an ordinary six-argument call" >&2; return 1; }
  if grep -q '^3:' <<<"$hits"; then
    echo "$1: corpus grep now reads a commented-out call as a call site" >&2; return 1
  fi
}
WORKSPACE_FIXTURE_DOC="$TMP/workspace-arity-fixture.md"
printf '%s\n' \
  'uberdev_command_workspace_prepare review-pr "$PR_NUMBER" medium "$RISK_JSON" "$RUN_ID" "${WORKTREE_ROOT:-}" >/dev/null || {' \
  '  uberdev_command_workspace_prepare' \
  '# uberdev_command_workspace_prepare review-pr 0 medium "[]" "$RUN_ID" ""' \
  >"$WORKSPACE_FIXTURE_DOC"
workspace_grep_fixture_probe grep
# Replay under the vendor grep as well, unconditionally rather than only when it
# differs from the PATH one. An end-of-line alternation is precisely the ERE
# where a drop-in grep can disagree, and which binary `grep` names is decided by
# the caller's PATH, not by this file: interactive shells here resolve it to
# ugrep while `bash tests/...` resolves it to /usr/bin/grep, so a "skip when they
# look identical" branch silently drops the second dialect on the very host that
# has two. Pinning the vendor path costs one redundant grep when they are the
# same file and buys a dialect assertion that always fires. The existence guard
# is for shells that ship no /usr/bin/grep at all — those skip the extra dialect
# instead of reding the suite.
if [ -x /usr/bin/grep ]; then
  workspace_grep_fixture_probe /usr/bin/grep
fi
rm -f "$WORKSPACE_FIXTURE_DOC"

echo 'command-workspace: PASS'
