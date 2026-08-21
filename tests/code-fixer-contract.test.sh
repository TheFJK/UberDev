#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/plugins/uberdev/lib/code_fixer_contract.py"

python3 -I -B - "$ROOT" "$HELPER" <<'PY'
import contextlib
import dataclasses
import hashlib
import importlib.util
import inspect
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
helper_path = pathlib.Path(sys.argv[2])
if not helper_path.is_file():
    raise SystemExit("code-fixer-contract: helper missing")

spec = importlib.util.spec_from_file_location("code_fixer_contract", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

workflow = (root / ".github/workflows/test.yml").read_text(encoding="utf-8")
windows_job_match = re.search(
    r"(?ms)^  shape-checks-windows:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow
)
assert windows_job_match is not None
windows_job = windows_job_match.group(0)
assert "    runs-on: windows-latest\n" in windows_job
assert "python -I -B tests/code-fixer-contract-windows.test.py" in windows_job
assert "continue-on-error: true" not in windows_job

# Guard S4-S6 (#428) — the teardown decoupling must not drift back.
#
# NARROWED BY #447. S1 (ban the raw constructor), S2 (exactly one factory) and
# S3 (exactly one suppression) moved to row A4 in
# tests/test-harness-source-guards.test.sh, which enforces them across all 124
# `tests/*.sh` ∪ `tests/*.py` files and on BOTH shape-check jobs — this block
# never reached `windows-latest`, because code-fixer-contract.test.sh is on the
# windows-skip-list. A4 also enforces the half S1-S3 never covered: that every
# factory is PAIRED with a suppressed teardown, not merely that one exists.
#
# What A4 deliberately does NOT carry, and is why this block survives:
#   S4  the per-file scratch CALL-SITE floors (30 / 1). A4's corpus-level
#       factory floor is a weaker ratchet — it counts factories, not the sites
#       routed through them, and S4 is the arm that caught the six scratch trees
#       #431 added to this suite.
#   S5  the exact crash-site literal from run 31369242976.
#   S6  the fixture-git gc/maintenance pins.
#
# The surviving needles are still assembled at runtime. This block reads the file
# it lives in, so a contiguous literal would count ITSELF and the presence checks
# would pass vacuously after the thing they guard was deleted. The program runs
# as `<stdin>` (piped to `python3 -I -B -`), so `inspect.getsource` on anything
# defined here raises — the guard must read file text from `root`.
NEEDLE_CALL_SITE = "with scratch" + "_dir("
NEEDLE_CRASH_SITE = 'scratch' + '_dir("code-fixer-ci-spaced-")'
for relative, floor in (
    ("tests/code-fixer-contract.test.sh", 30),   # 28 converted sites + S7 + S8
    ("tests/code-fixer-contract-windows.test.py", 1),
):
    text = (root / relative).read_text(encoding="utf-8")
    assert len(text) > 1000, f"S4 vacuity: {relative} unreadable or truncated"
    assert text.count(NEEDLE_CALL_SITE) >= floor, (
        f"S4 (#428): {relative} has {text.count(NEEDLE_CALL_SITE)} scratch "
        f"call sites, floor is {floor} — sites were deleted or unrouted"
    )
guarded = (root / "tests/code-fixer-contract.test.sh").read_text(encoding="utf-8")
assert NEEDLE_CRASH_SITE in guarded, (
    "S5 (#428): the exact block from run 31369242976 is no longer routed "
    "through the scratch factory"
)
NEEDLE_GC = "gc." + "auto=0"
NEEDLE_MAINTENANCE = "maintenance." + "auto=false"
assert NEEDLE_GC in guarded and NEEDLE_MAINTENANCE in guarded, (
    "S6 (#428): the fixture git() no longer pins gc/maintenance — the repos "
    "can start async work that outlives the `with` block and rewrites the "
    "object set the git_object_files before/after rows snapshot"
)

assert dataclasses.is_dataclass(module.FindingKey)
assert dataclasses.is_dataclass(module.RouteAuthority)
assert module.FindingKey.__dataclass_params__.frozen
assert module.RouteAuthority.__dataclass_params__.frozen
assert tuple(module.FindingKey.__dataclass_fields__) == (
    "finding_index", "location", "summary_sha256"
)
assert tuple(module.RouteAuthority.__dataclass_fields__) == (
    "edge_id", "policy_phase", "phase", "commit_type"
)
for name in (
    "bind_launch_receipt",
    "bind_fixer_launch_receipt",
    "bind_persistence_launch_receipt",
    "route_authority",
    "beneath",
    "capture_standalone_snapshot",
    "capture_standalone_terminal",
    "capture_review_terminal",
    "capture_persistence_terminal",
    "capture_expected",
    "consume_authority",
    "commit_review",
    "commit_standalone",
    "encode_aggregate",
    "parse_finding_keys",
    "prepare_authority",
    "prepare_standalone_authority",
    "publish_disposition",
    "publish_review_only_disposition",
    "publish_unapplied_terminal",
    "count_phase2_deferred_blockers",
    "project_verification_claims",
    "publish_verification",
    "validate_persistence_result",
    "validate_commit",
    "validate_failed_return",
    "validate_residue",
    "validate_standalone_outcome",
    "validate_review_outcome",
    "validate_staged",
):
    assert callable(getattr(module, name, None)), name
assert module.__all__ == (
    "Phase", "CommitType", "FindingKey", "RouteAuthority", "bind_launch_receipt",
    "bind_fixer_launch_receipt",
    "bind_persistence_launch_receipt",
    "route_authority", "beneath", "capture_standalone_snapshot",
    "capture_standalone_terminal", "capture_review_terminal", "capture_persistence_terminal", "capture_bound_child", "capture_expected", "consume_authority", "encode_aggregate", "parse_finding_keys",
    "prepare_authority", "prepare_standalone_authority", "publish_disposition",
    "publish_review_only_disposition", "publish_unapplied_terminal",
    "count_phase2_deferred_blockers", "project_verification_claims",
    "publish_verification", "validate_persistence_result",
    "commit_review", "commit_standalone", "validate_commit", "validate_failed_return", "validate_residue", "validate_standalone_outcome", "validate_review_outcome",
    "validate_staged",
)

assert tuple(inspect.signature(module.route_authority).parameters) == (
    "edge_id", "policy_phase"
)
assert tuple(inspect.signature(module.beneath).parameters) == ("root", "path")
assert tuple(inspect.signature(module.capture_expected).parameters) == (
    "path", "expected_sha256", "minimum", "maximum"
)
assert tuple(inspect.signature(module.parse_finding_keys).parameters) == (
    "payload", "phase"
)
assert tuple(inspect.signature(module.encode_aggregate).parameters) == (
    "value", "phase"
)
assert tuple(inspect.signature(module.capture_standalone_snapshot).parameters) == (
    "working_dir", "evidence_dir", "diff_path", "snapshot_path"
)
assert tuple(inspect.signature(module.capture_standalone_terminal).parameters) == (
    "launch_binding", "disposition_path", "applied_content_path",
)
assert tuple(inspect.signature(module.capture_review_terminal).parameters) == (
    "launch_binding", "disposition_path", "applied_content_path",
)
assert tuple(inspect.signature(module.capture_persistence_terminal).parameters) == (
    "launch_binding",
)
assert tuple(inspect.signature(module.prepare_authority).parameters) == (
    "edge_id", "policy_phase", "findings_path", "findings_sha256",
    "commit_range_path", "commit_range_sha256", "working_dir", "disposition_path",
    "authority_output_path",
)
assert tuple(inspect.signature(module.publish_disposition).parameters) == (
    "authority_path", "authority_sha256", "disposition_path", "candidate",
)
assert tuple(inspect.signature(module.publish_review_only_disposition).parameters) == (
    "findings_path", "findings_sha256", "snapshot_path", "snapshot_sha256",
    "working_dir", "disposition_path",
)
# #556 U1. `validate_review_outcome`'s argument list MINUS the four digests --
# this verb computes them, because it is the process that writes the two
# artifacts they cover. A digest taken as input here could only have been
# computed by the refusing child, which is the party whose claim is in doubt.
assert tuple(inspect.signature(module.publish_unapplied_terminal).parameters) == (
    "launch_binding", "authority_path", "authority_sha256", "disposition_path",
    "applied_content_path", "working_dir", "head_before", "head_after",
)
assert tuple(inspect.signature(module.count_phase2_deferred_blockers).parameters) == (
    "findings_path", "findings_sha256", "disposition_path", "disposition_sha256",
)
assert tuple(inspect.signature(module.validate_persistence_result).parameters) == (
    "launch_binding", "status_sha256", "result_sha256",
)
assert tuple(inspect.signature(module.bind_persistence_launch_receipt).parameters) == (
    "receipt", "edge_id", "instance_id", "result_path", "status_path",
    "working_dir", "aggregate_path", "aggregate_sha256", "disposition_path",
    "disposition_sha256", "expected_deferred_blockers", "require_clean",
)
assert tuple(inspect.signature(module.bind_fixer_launch_receipt).parameters) == (
    "receipt", "edge_id", "instance_id", "result_path", "status_path",
    "working_dir", "authority_path", "authority_sha256",
)
assert tuple(inspect.signature(module.consume_authority).parameters) == (
    "edge_id", "policy_phase", "authority_path", "authority_sha256",
    "findings_path", "findings_sha256", "working_dir", "disposition_path",
    "commit_range_path", "commit_range_sha256", "snapshot_path",
    "snapshot_sha256",
)
assert tuple(inspect.signature(module.commit_review).parameters) == (
    "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "applied_content_path", "applied_content_sha256",
    "working_dir",
)
assert tuple(inspect.signature(module.commit_standalone).parameters) == (
    "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "applied_content_path", "applied_content_sha256",
    "working_dir",
)
assert tuple(inspect.signature(module.prepare_standalone_authority).parameters) == (
    "edge_id", "policy_phase", "findings_path", "findings_sha256",
    "snapshot_path", "snapshot_sha256", "working_dir", "disposition_path",
)
assert tuple(inspect.signature(module.bind_launch_receipt).parameters) == (
    "receipt", "edge_id", "instance_id", "result_path", "status_path",
    "working_dir",
)
assert tuple(inspect.signature(module.validate_standalone_outcome).parameters) == (
    "launch_binding", "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "applied_content_path", "applied_content_sha256",
    "status_sha256", "result_sha256", "working_dir", "head_before", "head_after",
)
assert tuple(inspect.signature(module.validate_review_outcome).parameters) == (
    "launch_binding", "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "applied_content_path", "applied_content_sha256",
    "status_sha256", "result_sha256", "working_dir", "head_before", "head_after",
)
assert tuple(inspect.signature(module.validate_commit).parameters) == (
    "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "working_dir", "parent_sha", "commit_sha",
    "staged_tree_sha", "expected_message_sha256",
)
assert tuple(inspect.signature(module.validate_residue).parameters) == (
    "working_dir", "evidence_dir",
)
assert tuple(inspect.signature(module.validate_failed_return).parameters) == (
    "working_dir", "evidence_dir", "head_before", "snapshot_path",
    "snapshot_sha256",
)
assert tuple(inspect.signature(module.validate_staged).parameters) == (
    "authority_path", "authority_sha256", "disposition_path",
    "disposition_sha256", "working_dir",
)

assert module.route_authority("review_pr.fix.phase1", "review_fix") == (
    module.RouteAuthority("review_pr.fix.phase1", "review_fix", "phase1", "fix")
)
assert module.route_authority("review_pr.fix.phase2", "simplify_fix") == (
    module.RouteAuthority("review_pr.fix.phase2", "simplify_fix", "phase2", "refactor")
)
assert module.route_authority("simplify.fix.phase2", "simplify_fix") == (
    module.RouteAuthority("simplify.fix.phase2", "simplify_fix", "phase2", "refactor")
)
for edge, phase in (
    ("review_pr.fix.phase1", "simplify_fix"),
    ("review_pr.fix.phase2", "review_fix"),
    ("review_pr.fix.phase3", "review_fix"),
):
    try:
        module.route_authority(edge, phase)
    except module.ContractFailure:
        pass
    else:
        raise AssertionError((edge, phase))
for edge, phase in (([], "review_fix"), ("review_pr.fix.phase1", [])):
    try:
        module.route_authority(edge, phase)
    except module.ContractFailure:
        pass
    else:
        raise AssertionError((edge, phase))

assert module.beneath("/repo", "/repo/src/a.py")
assert not module.beneath("/repo", "/repo-evil/src/a.py")


def run(argv, *, stdin=None, expected=0):
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(helper_path), *argv],
        input=stdin,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
    if expected == 74:
        assert result.stdout == "", (argv, result.stdout)
        assert result.stderr.count("\n") == 1, (argv, result.stderr)
        reason = result.stderr.strip()
        assert reason and " " not in reason and "/" not in reason, reason
    else:
        assert result.stderr == "", (argv, result.stderr)
    return result.stdout


def run_bytes(argv, *, expected=0):
    """`run`, but byte-exact.

    `run` passes `text=True`, so the CLI's stdout comes back decoded and a NUL
    byte in it is indistinguishable from any other codepoint once Python has
    normalised newlines. `list-ci-unmerged-paths` is NUL-TERMINATED on purpose,
    so the rows that pin its payload have to read raw bytes. Returns the whole
    CompletedProcess rather than just stdout: the rc-74 row asserts on stderr's
    reason token too.
    """
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(helper_path), *argv],
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
    return result


@contextlib.contextmanager
def scratch_dir(prefix, parent=None):
    """A scratch tree whose TEARDOWN cannot decide this suite's verdict.

    Scaffolding only. Nothing in this file reads the tree after its `with`
    block ends — every `git_object_files` before/after pair is inside a body —
    so a failed unlink here is a false signal, not a finding.
    `TemporaryDirectory.__exit__` re-raises every OSError except
    PermissionError and FileNotFoundError, which turned an ENOTEMPTY race on
    `.git/objects` into a red `shape-checks` job on a PR whose diff never
    touched this file (issue #428, run 31369242976). Suppressing the unlink
    error is class-agnostic, so it holds whichever writer wins the race and the
    fix does not depend on identifying that writer.

    Tradeoff: a failed unlink leaves the tree behind. Harmless on ephemeral
    runners; on a dev box repeated runs can accumulate `code-fixer-*` dirs
    under $TMPDIR. mkdtemp plus rmtree is used instead of the stdlib context
    manager's 3.10+ cleanup-suppression kwarg because no workflow pins an
    interpreter (there is no `setup-python` step in .github/workflows), so the
    kwarg could TypeError on the very job it protects.

    This docstring is the canonical rationale for all 12 copies of the factory
    under tests/ (#447 spread it to the six sibling suites). `parent` carries
    the stdlib `dir=` kwarg one of those call sites needs; omitted, mkdtemp's
    `dir=None` is exactly the default, so one signature covers every site.
    """
    path = tempfile.mkdtemp(prefix=prefix, dir=parent)
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def git(repository, *args, check=True):
    # Fixture repos must not start work that outlives the `with` block. A
    # detached `gc --auto` / `maintenance run --auto` repack is the leading
    # candidate for the #428 ENOTEMPTY teardown race, and it would also rewrite
    # the object set the git_object_files before/after rows snapshot. Passed as
    # `-c` rather than written to repo config so a later git(repo, "config", …)
    # in a fixture cannot overwrite it — the same convention the shipped module
    # uses for `-c core.fsmonitor=false`.
    return subprocess.run(
        ["git", "-C", str(repository),
         "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args],
        capture_output=True,
        check=check,
    )


def git_object_files(repository):
    object_root = repository / ".git/objects"
    return tuple(
        sorted(
            str(path.relative_to(object_root))
            for path in object_root.rglob("*")
            if path.is_file()
        )
    )


def regular_snapshot(path):
    entry = os.lstat(path)
    assert stat.S_ISREG(entry.st_mode)
    return (
        path.read_bytes(),
        entry.st_dev,
        entry.st_ino,
        entry.st_size,
        stat.S_IMODE(entry.st_mode),
        entry.st_mtime_ns,
        entry.st_ctime_ns,
        entry.st_nlink,
    )


def digest(path):
    value = run([
        "digest", "--path", str(path), "--minimum", "1", "--maximum", "1048576"
    ])
    assert len(value) == 64 and value == value.lower()
    return value


for invalid_argv in (
    [],
    ["unknown"],
    ["digest", "--path", "/missing"],
    ["digest", "--path", "/missing", "--minimum", "not-an-int", "--maximum", "1"],
):
    run(invalid_argv, expected=74)


def prepare(repository, findings, findings_sha, commit_range, range_sha, disposition,
            *, edge="review_pr.fix.phase1", policy_phase="review_fix"):
    raw = run([
        "prepare-authority",
        "--edge-id", edge,
        "--policy-phase", policy_phase,
        "--findings-path", str(findings),
        "--findings-sha256", findings_sha,
        "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha,
        "--working-dir", str(repository),
        "--disposition-path", str(disposition),
    ])
    value = json.loads(raw)
    assert set(value) == {
        "authority_path", "authority_sha256", "phase", "commit_type", "target_paths"
    }
    return value


def candidate(authority, rows):
    return {
        "schema_version": 1,
        "phase": authority["phase"],
        "aggregate_sha256": authority["findings_sha256"],
        "findings_disposition": rows,
    }


PHASE1_CONTRIBUTORS = (
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
    "review_pr.review.convention",
)
PHASE2_CONTRIBUTORS = (
    "review_pr.simplify.reuse",
    "review_pr.simplify.quality",
    "review_pr.simplify.efficiency",
)


def aggregate(phase, rows=()):
    source = (
        "post-impl-review-aggregate" if phase == "phase1" else "simplify-aggregate"
    )
    roster = PHASE1_CONTRIBUTORS if phase == "phase1" else PHASE2_CONTRIBUTORS
    contributors = [
        {
            "confidence": "high" if phase == "phase1" else "n/a",
            "id": edge,
            "verdict": "APPROVE" if phase == "phase1" else "COMPLETE",
        }
        for edge in roster
    ]
    findings = []
    for sources, severity, path, line, summary, detail in rows:
        line_text = str(line)
        line_value = int(line_text) if len(line_text) <= 18 else line_text
        findings.append(
            {
                "detail": detail,
                "scope": {
                    "line": line_value,
                    "operation": "modify_existing",
                    "path": path,
                },
                "severity": severity,
                "source_edges": list(sources),
                "summary": summary,
            }
        )
        if phase == "phase1" and severity == "blocker":
            for contributor in contributors:
                if contributor["id"] in sources:
                    contributor["verdict"] = "REVISIONS_REQUIRED"
    value = {
        "contributors": contributors,
        "findings": findings,
        "phase": phase,
        "schema_version": 2,
    }
    canonical = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return (
        f'<external-untrusted-input source="{source}">\n{canonical}\n'
        "</external-untrusted-input>\n"
    ).encode()


def phase1_table(rows):
    converted = []
    edge_by_agent = {
        "code-reviewer": "review_pr.review.correctness",
        "code-reviewer (correctness lens)": "review_pr.review.correctness",
        "code-reviewer (general lens)": "review_pr.review.general",
        "silent-failure-hunter": "review_pr.review.silent_failures",
        "type-design-analyzer": "review_pr.review.types",
        "comment-analyzer": "review_pr.review.comments",
        "pr-test-analyzer": "review_pr.review.tests",
        "convention-compliance": "review_pr.review.convention",
    }
    for agent, severity, path, line, _disposition, summary, detail in rows:
        converted.append(((edge_by_agent[agent],), severity, path, line, summary, detail))
    return aggregate("phase1", converted)


def phase2_table(rows):
    converted = []
    for lens, severity, path, line, _disposition, summary in rows:
        sources = tuple(f"review_pr.simplify.{item}" for item in lens.split("+"))
        converted.append((sources, severity, path, line, summary, "bounded detail"))
    return aggregate("phase2", converted)


def expect_contract_failure(callback):
    try:
        callback()
    except module.ContractFailure:
        return
    raise AssertionError("expected closed contract refusal")


def expect_contract_reason(callback, reason):
    try:
        callback()
    except module.ContractFailure as error:
        assert str(error) == reason, (str(error), reason)
        return
    raise AssertionError(f"expected closed contract refusal: {reason}")


hostile_git_environment = {
    "git_object_directory": "/hostile/objects",
    "Git_Alternate_Object_Directories": "/hostile/alternates",
    "gIt_InDeX_fIlE": "/hostile/index",
}
for key, value in hostile_git_environment.items():
    os.environ[key] = value
try:
    scrubbed_environment = module._scrubbed_git_environment()
finally:
    for key in hostile_git_environment:
        os.environ.pop(key, None)
assert {
    key for key in scrubbed_environment if key.upper().startswith("GIT_")
} == {
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_SYSTEM",
    "GIT_NO_LAZY_FETCH",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_OPTIONAL_LOCKS",
}
assert scrubbed_environment["GIT_NO_LAZY_FETCH"] == "1"
assert scrubbed_environment["GIT_NO_REPLACE_OBJECTS"] == "1"
assert scrubbed_environment["GIT_OPTIONAL_LOCKS"] == "0"

expect_contract_reason(
    lambda: module._git_io(
        str(root),
        "rev-parse",
        "--git-dir",
        extra_env={"GIT_OBJECT_DIRECTORY": "/hostile/objects"},
    ),
    "git_environment_invalid",
)
expect_contract_reason(
    lambda: module._git_io(
        str(root),
        "rev-parse",
        "--git-dir",
        extra_env={"GIT_EDITOR": "hostile-editor"},
    ),
    "git_environment_invalid",
)


def ewah_payload(bit_size, words, current_rlw=0):
    return (
        bit_size.to_bytes(4, "big")
        + len(words).to_bytes(4, "big")
        + b"".join(word.to_bytes(8, "big") for word in words)
        + current_rlw.to_bytes(4, "big")
    )


expect_contract_reason(
    lambda: module._decode_ewah_bitmap(
        ewah_payload(1, [1 | (0xFFFFFFFF << 1)]), 0, 1
    ),
    "index_tree_unreadable",
)
expect_contract_reason(
    lambda: module._decode_ewah_bitmap(ewah_payload(1, [1 | (1 << 1)]), 0, 1),
    "index_tree_unreadable",
)
expect_contract_reason(
    lambda: module._decode_ewah_bitmap(
        ewah_payload(1, [1 << 33, 1 << 63]), 0, 1
    ),
    "index_tree_unreadable",
)
assert module._decode_ewah_bitmap(
    ewah_payload(64, [1 | (1 << 1)]), 0, 64
) == (set(range(64)), 20)


class InterruptingStdout:
    def __init__(self):
        self.closed = False

    def read(self, _maximum):
        raise KeyboardInterrupt("injected bounded-read interrupt")

    def close(self):
        self.closed = True


class ProvisionalProcess:
    def __init__(self):
        self.stdout = InterruptingStdout()
        self.killed = False
        self.waited = False

    def poll(self):
        return -9 if self.killed else None

    def kill(self):
        self.killed = True

    def wait(self):
        self.waited = True
        return -9


provisional_process = ProvisionalProcess()
try:
    module._read_bounded_process_stdout(
        provisional_process, 16, "temporary_index_failed"
    )
except KeyboardInterrupt as error:
    assert str(error) == "injected bounded-read interrupt"
else:
    raise AssertionError("bounded-read KeyboardInterrupt was swallowed")
assert provisional_process.stdout.closed
assert provisional_process.killed
assert provisional_process.waited


def persistence_result(status, *, halted=False, blocker_count=0,
                       halted_due_to_overflow=False, skipped_tiers=()):
    # `skipped_closed` rows carry the agent's own return shape (findings-to-issues
    # "Return contract"), so the tier token the parser counts is the token the
    # child actually emits -- not a shape invented here.
    skipped = "skipped_closed: []\n"
    if skipped_tiers:
        skipped = "skipped_closed:\n" + "".join(
            f'  - {{ url: "https://github.com/o/r/issues/{90 + index}", '
            f'file: "src/s{index}.py:{index + 1}", '
            f'fingerprint: "0123456789abcde{index}", tier: "{tier}" }}\n'
            for index, tier in enumerate(skipped_tiers)
        )
    return (
        "Persistence summary.\n\n```yaml\n"
        f"status: {status}\n"
        "created_urls: []\n"
        "commented_urls: []\n"
        f"{skipped}"
        "blocked_by_dedupe: []\n"
        "by_severity:\n"
        f"  blocker: {blocker_count}\n"
        "  critical: 0\n"
        "  major: 0\n"
        "overflow_count: 0\n"
        f"halted_due_to_overflow: {str(halted_due_to_overflow).lower()}\n"
        f"halted: {str(halted).lower()}\n"
        "author_lookup_failed: false\n"
        "label_provisioned: true\n"
        "rate_limit_remaining_at_start: 100\n"
        'rationale: ""\n'
        "```\n"
    )


# S7/S8 (#428) — the scratch factory's two load-bearing properties, asserted
# behaviourally rather than by spelling. S7: drop-in for the stdlib context
# manager (a str naming a live directory, gone after the block). S8: a teardown
# that CANNOT unlink must not raise — that is the whole point of the change.
with scratch_dir("code-fixer-scratch-probe-") as probe:
    assert isinstance(probe, str), type(probe)
    assert os.path.isdir(probe), probe
    assert os.path.basename(probe).startswith("code-fixer-scratch-probe-"), probe
assert not os.path.exists(probe), probe

# `os.geteuid` does not exist on Windows, so the platform test must come first
# and short-circuit. root ignores mode bits, so the row is meaningless there.
if os.name != "nt" and os.geteuid() != 0:
    with scratch_dir("code-fixer-scratch-undeletable-") as undeletable:
        os.mkdir(os.path.join(undeletable, "sub"))
        os.chmod(undeletable, 0o500)          # r-x: the child cannot be unlinked
    # Exiting the block above must have raised NOTHING. PermissionError is the
    # deterministic stand-in for the ENOTEMPTY of run 31369242976; the
    # suppression is class-agnostic, so one covers the other by construction.
    assert os.path.isdir(undeletable), undeletable
    assert os.path.isdir(os.path.join(undeletable, "sub"))
    os.chmod(undeletable, 0o700)
    shutil.rmtree(undeletable)
    assert not os.path.exists(undeletable), undeletable


with scratch_dir("code-fixer-persistence-result-") as temporary:
    working = pathlib.Path(temporary).resolve()
    result_path = working / "result.md"
    status_path = working / "status.json"
    aggregate0 = working / "simplify-empty.md"
    aggregate1 = working / "simplify-blocker.md"
    disposition0 = working / "phase2-empty-disposition.json"
    disposition1 = working / "phase2-blocker-disposition.json"
    aggregate0.write_bytes(aggregate("phase2"))
    aggregate1.write_bytes(aggregate("phase2", [(
        ("review_pr.simplify.quality",), "blocker", "src/a.py", "1",
        "persist the deferred blocker", "bounded persistence fixture",
    )]))
    aggregate0_sha = digest(aggregate0)
    aggregate1_sha = digest(aggregate1)
    disposition0.write_text(json.dumps({
        "schema_version":1, "phase":"phase2",
        "aggregate_sha256":aggregate0_sha, "findings_disposition":[],
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    blocker_key = dataclasses.asdict(
        module.parse_finding_keys(aggregate1.read_bytes(), "phase2")[0]
    )
    disposition1.write_text(json.dumps({
        "schema_version":1, "phase":"phase2",
        "aggregate_sha256":aggregate1_sha,
        "findings_disposition":[{
            **blocker_key, "disposition":"SKIPPED", "behavior_tag":"n/a",
            "reason":"deferred to a durable issue",
        }],
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    disposition0_sha = digest(disposition0)
    disposition1_sha = digest(disposition1)
    status_path.write_text(json.dumps({
        "backend":"background", "branch":"", "exit_code":0,
        "lease_generation":"0123456789abcdef0123456789abcdef", "pid":"34567",
        "process_identity":"34567|34567|34567|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "result":str(result_path), "state":"completed", "workspace_mode":"caller",
        "worktree":str(working),
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    receipt = json.dumps({
        "schema_version":1, "edge_id":"review_pr.defer.findings",
        "instance_id":"simplify-defer-findings-iter01-attempt01",
        "backend":"background", "handle":"34567", "state":"completed",
        "result_file":str(result_path), "status_file":str(status_path),
    },sort_keys=True,separators=(",",":")).encode()
    def persistence_binding(expected):
        aggregate_path = aggregate1 if expected else aggregate0
        aggregate_sha = aggregate1_sha if expected else aggregate0_sha
        disposition_path = disposition1 if expected else disposition0
        disposition_sha = disposition1_sha if expected else disposition0_sha
        return json.dumps(module.bind_persistence_launch_receipt(
            receipt=receipt, edge_id="review_pr.defer.findings",
            instance_id="simplify-defer-findings-iter01-attempt01",
            result_path=str(result_path), status_path=str(status_path),
            working_dir=str(working), aggregate_path=str(aggregate_path),
            aggregate_sha256=aggregate_sha,
            disposition_path=str(disposition_path),
            disposition_sha256=disposition_sha,
            expected_deferred_blockers=expected, require_clean=bool(expected),
        ),sort_keys=True,separators=(",",":")).encode()
    binding0 = persistence_binding(0)
    binding1 = persistence_binding(1)
    def validate_persistence(binding):
        terminal = module.capture_persistence_terminal(launch_binding=binding)
        return module.validate_persistence_result(
            launch_binding=binding,
            status_sha256=terminal["status_sha256"],
            result_sha256=terminal["result_sha256"],
        )
    result_path.write_text(persistence_result("DONE"), encoding="utf-8")
    terminal = module.capture_persistence_terminal(launch_binding=binding0)
    result_sha = terminal["result_sha256"]
    validated = validate_persistence(binding0)
    assert validated == {
        "aggregate_path": str(aggregate0),
        "aggregate_sha256": aggregate0_sha,
        "by_severity_blocker": 0,
        "disposition_path": str(disposition0),
        "disposition_sha256": disposition0_sha,
        "expected_deferred_blockers": 0,
        "halted": False,
        "halted_due_to_overflow": False,
        "require_clean": False,
        "result_sha256": result_sha,
        "status": "DONE",
    }
    assert json.loads(run([
        "validate-persistence-result", "--launch-binding-json", binding0.decode(),
        "--status-sha256", terminal["status_sha256"],
        "--result-sha256", result_sha,
    ])) == validated

    foreign_receipt = json.loads(receipt)
    foreign_receipt["handle"] = "99999"
    expect_contract_failure(lambda: module.bind_persistence_launch_receipt(
        receipt=json.dumps(
            foreign_receipt, sort_keys=True, separators=(",", ":")
        ).encode(),
        edge_id="review_pr.defer.findings",
        instance_id="simplify-defer-findings-iter01-attempt01",
        result_path=str(result_path), status_path=str(status_path),
        working_dir=str(working), aggregate_path=str(aggregate0),
        aggregate_sha256=aggregate0_sha, disposition_path=str(disposition0),
        disposition_sha256=disposition0_sha, expected_deferred_blockers=0,
        require_clean=False,
    ))
    status_before = status_path.read_bytes()
    status_document = json.loads(status_before)
    for field, replacement in (
        ("pid", "99999"),
        (
            "process_identity",
            "99999|99999|99999|abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        ),
        ("lease_generation", "abcdef0123456789abcdef0123456789"),
        ("result", str(working / "foreign-result.md")),
    ):
        changed = dict(status_document)
        changed[field] = replacement
        status_path.write_text(
            json.dumps(changed, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        changed_terminal = module.capture_persistence_terminal(
            launch_binding=binding0
        )
        expect_contract_failure(lambda changed_terminal=changed_terminal:
            module.validate_persistence_result(
                launch_binding=binding0,
                status_sha256=changed_terminal["status_sha256"],
                result_sha256=changed_terminal["result_sha256"],
            )
        )
    status_path.write_bytes(status_before)

    result_path.write_text(
        persistence_result("DONE_WITH_CONCERNS"), encoding="utf-8"
    )
    assert validate_persistence(binding0)["status"] == "DONE_WITH_CONCERNS"
    result_path.write_text(
        persistence_result(
            "DONE_WITH_CONCERNS", halted=True, blocker_count=1
        ), encoding="utf-8"
    )
    expect_contract_failure(lambda: validate_persistence(binding1))

    result_path.write_text(persistence_result("REFUSED"), encoding="utf-8")
    expect_contract_failure(lambda: validate_persistence(binding0))

    result_path.write_text(
        persistence_result("DONE", halted=True, blocker_count=1), encoding="utf-8"
    )
    halted_terminal = module.capture_persistence_terminal(launch_binding=binding1)
    halted = validate_persistence(binding1)
    assert halted["halted"] is True and halted["by_severity_blocker"] == 1
    result_path.write_text(result_path.read_text(encoding="utf-8") + "replaced\n")
    expect_contract_failure(lambda: module.validate_persistence_result(
        launch_binding=binding1,
        status_sha256=halted_terminal["status_sha256"],
        result_sha256=halted_terminal["result_sha256"],
    ))

    # #453 -- the blocker accounting spans MORE than the pinned population.
    # `expected_deferred_blockers` is recounted from the Phase 2 pair the
    # binding pins; `by_severity.blocker` and `skipped_closed` count rows the
    # filer wrote for Phase 1 AND Phase 2. The contract may therefore only
    # assert the direction the mismatch cannot forge: every pinned Phase 2
    # blocker is accounted for. Phase 1 rows raise the observed count and must
    # not fail the run.
    result_path.write_text(
        persistence_result("DONE", halted=True, blocker_count=1), encoding="utf-8"
    )
    phase1_only = validate_persistence(binding0)
    assert phase1_only["halted"] is True, phase1_only
    assert phase1_only["by_severity_blocker"] == 1, phase1_only
    assert phase1_only["expected_deferred_blockers"] == 0, phase1_only
    result_path.write_text(
        persistence_result("DONE", halted=True, blocker_count=2), encoding="utf-8"
    )
    both_phases = validate_persistence(binding1)
    assert both_phases["by_severity_blocker"] == 2, both_phases
    assert both_phases["expected_deferred_blockers"] == 1, both_phases

    # Under-accounting stays fatal: a child that files nothing for a deferred
    # Phase 2 blocker is exactly the run that would otherwise report
    # `halted: false` and emit a GREEN trust trail over an unfiled blocker.
    result_path.write_text(persistence_result("DONE"), encoding="utf-8")
    expect_contract_reason(
        lambda: validate_persistence(binding1),
        "persistence_result_authority_mismatch",
    )
    # A BLOCKER row the filer skipped because its issue is already closed is
    # accounting, not silence...
    result_path.write_text(
        persistence_result("DONE", skipped_tiers=("BLOCKER",)), encoding="utf-8"
    )
    skipped_blocker = validate_persistence(binding1)
    assert skipped_blocker["by_severity_blocker"] == 0, skipped_blocker
    # ...but a lower-tier skip accounts for nothing.
    result_path.write_text(
        persistence_result("DONE", skipped_tiers=("MAJOR",)), encoding="utf-8"
    )
    expect_contract_reason(
        lambda: validate_persistence(binding1),
        "persistence_result_authority_mismatch",
    )

    result_path.write_text(persistence_result("DONE"), encoding="utf-8")
    source_before = aggregate0.read_bytes()
    aggregate0.write_bytes(source_before + b"replacement\n")
    expect_contract_failure(lambda: validate_persistence(binding0))
    aggregate0.write_bytes(source_before)

    malformed_cases = (
        persistence_result("DONE").replace("status: DONE\n", "status: DONE\nstatus: DONE\n"),
        persistence_result("DONE", halted=True, blocker_count=0),
        persistence_result("DONE", halted=False, blocker_count=1),
        persistence_result("DONE").replace("```\n", "```\ntrailer\n"),
    )
    for malformed in malformed_cases:
        result_path.write_text(malformed, encoding="utf-8")
        expect_contract_failure(lambda: validate_persistence(binding0))


# The byte-shape oracles are the single production aggregate schema. Both
# phases use deterministic compact JSON inside their source-specific envelope.
phase1_oracle = (
    root / "tests/fixtures/findings-to-issues/post-impl-review-final.sample.md"
).read_bytes()
phase2_oracle = (
    root / "tests/fixtures/findings-to-issues/simplify-final.sample.md"
).read_bytes()
phase1_keys = module.parse_finding_keys(phase1_oracle, "phase1")
assert [item.location for item in phase1_keys] == [
    "src/auth.ts:42", "src/auth.ts:88", "src/log.ts:17", "src/api.ts:130",
    "src/util.ts:5",
]
assert phase1_keys[0].summary_sha256 == hashlib.sha256(
    b"Missing null check on req.user before .id access"
).hexdigest()
phase1_lens_row = phase1_table([
    ("code-reviewer (general lens)", "suggestion", "src/general.ts", "4",
     "DEFERRED", "general lens remains a known roster member", "not-in-scope"),
])
assert module.parse_finding_keys(phase1_lens_row, "phase1")[0].location == (
    "src/general.ts:4"
)
phase2_keys = module.parse_finding_keys(phase2_oracle, "phase2")
# The order is the Phase 2 writer's merge order -- first-seen (path,line) walked
# in roster order (reuse, quality, efficiency) -- so this oracle is a PRODUCER
# oracle, not only a parse oracle. `src/dup.ts:3` is second because the reuse
# lens is the first roster member and it reports both `src/api.ts:130` and
# `src/dup.ts:3`; `src/loop.ts:12` is first seen by the efficiency lens, last in
# the roster. Any writer that emits a different order fails byte comparison.
assert [item.location for item in phase2_keys] == [
    "src/api.ts:130", "src/dup.ts:3", "src/loop.ts:12",
]
assert phase2_keys[1].summary_sha256 == hashlib.sha256(
    b"Extract the duplicate implementation to the existing helper"
).hexdigest()
phase1_empty = aggregate("phase1")
phase2_empty = aggregate("phase2")
assert module.parse_finding_keys(phase1_empty, "phase1") == ()
assert module.parse_finding_keys(phase2_empty, "phase2") == ()
# #452 -- the phase->envelope derivation is ONE function, not a ternary copied
# into every procedure that needs it.
assert module._aggregate_source("phase1") == "post-impl-review-aggregate"
assert module._aggregate_source("phase2") == "simplify-aggregate"
expect_contract_reason(
    lambda: module._aggregate_source("phase3"), "findings_schema_invalid"
)
expect_contract_reason(
    lambda: module._aggregate_source(None), "findings_schema_invalid"
)
# Source-text ratchet: the two envelope literals must not re-multiply. Without
# it the single derivation can rot back into copies behind a green suite.
helper_text = helper_path.read_text(encoding="utf-8")
assert helper_text.count('"simplify-aggregate"') == 1, helper_text.count(
    '"simplify-aggregate"'
)
assert helper_text.count('"post-impl-review-aggregate"') == 1, helper_text.count(
    '"post-impl-review-aggregate"'
)
assert module.encode_aggregate(
    json.loads(phase1_empty.split(b"\n", 2)[1]), "phase1"
) == phase1_empty
phase2_record_bytes = aggregate("phase2", [(
    ("review_pr.simplify.reuse", "review_pr.simplify.quality"),
    "blocker", "src/escaped.ts", "7",
    "shared helper should preserve behavior",
    "extract through the existing port",
)])
phase2_record_keys = module.parse_finding_keys(phase2_record_bytes, "phase2")
assert [item.location for item in phase2_record_keys] == ["src/escaped.ts:7"]
phase2_record_injected = phase2_record_bytes.replace(b'"findings":', b'"owner":"injected","findings":')
expect_contract_failure(
    lambda: module.parse_finding_keys(phase2_record_injected, "phase2")
)
escaped_table = aggregate("phase2", [(
    ("review_pr.simplify.reuse", "review_pr.simplify.quality"),
    "blocker", "src/escaped.ts", "7",
    "Reuse: share helper | Quality: retain boundary", "bounded detail",
)])
escaped_key = module.parse_finding_keys(escaped_table, "phase2")[0]
assert escaped_key.summary_sha256 == hashlib.sha256(
    b"Reuse: share helper | Quality: retain boundary"
).hexdigest()
legacy_table = (
    b'<external-untrusted-input source="simplify-aggregate">\n'
    b"# Simplify aggregate (Phase 2)\n\n"
    b"| lens | severity | file | line | disposition | summary |\n"
    b"|---|---|---|---|---|---|\n"
    b"| reuse | suggestion | src/legacy.ts | 1 | DEFERRED | legacy |\n\n"
    b"</external-untrusted-input>\n"
)
legacy_yaml = (
    b'<external-untrusted-input source="simplify-aggregate">\n'
    b"findings: []\n</external-untrusted-input>\n"
)
expect_contract_failure(lambda: module.parse_finding_keys(legacy_table, "phase2"))
expect_contract_failure(lambda: module.parse_finding_keys(legacy_yaml, "phase2"))
for payload, phase in ((phase1_oracle, "phase1"), (phase2_oracle, "phase2")):
    injected = payload.replace(
        b"\n</external-untrusted-input>",
        b"\nunrelated\n</external-untrusted-input>",
    )
    expect_contract_failure(lambda payload=injected, phase=phase:
                            module.parse_finding_keys(payload, phase))
expect_contract_failure(lambda: module.parse_finding_keys(phase1_oracle, "phase2"))
expect_contract_failure(lambda: module.parse_finding_keys(phase2_oracle, "phase1"))


with scratch_dir("code-fixer-contract-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "src").mkdir()
    (repo / ".gitignore").write_text(
        "ignored.cfg\nnode_modules/\n", encoding="utf-8"
    )
    (repo / "ignored.cfg").write_text("LOCAL = 1\n", encoding="utf-8")
    (repo / "src/outside.py").write_text("OUTSIDE = 1\n", encoding="utf-8")
    (repo / "src/new.py").write_text("NEW = 0\n", encoding="utf-8")
    git(repo, "add", "--", ".gitignore", "src/outside.py", "src/new.py")
    git(repo, "commit", "-qm", "test: base fixture")
    base = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "src/a.py").write_text("A = 1\n", encoding="utf-8")
    (repo / "src/b.py").write_text("B = 1\n", encoding="utf-8")
    (repo / "src/c.py").write_text("C = 1\n", encoding="utf-8")
    (repo / "src/new.py").unlink()
    git(repo, "add", "--", "src/a.py", "src/b.py", "src/c.py", "src/new.py")
    git(repo, "commit", "-qm", "test: fixture")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()

    evidence = repo / ".uberdev/research/20260728-010203-abcdef0"
    evidence.mkdir(parents=True)
    findings = evidence / "post-impl-review-final.md"
    findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/a.py", "1", "DEFERRED",
         "correct alpha", "bounded"),
        ("comment-analyzer", "suggestion", "src/b.py", "1", "DEFERRED",
         "correct beta", "bounded"),
    ]))
    commit_range = evidence / "commit-range.txt"
    commit_range.write_text(f"{base}..{head}\n", encoding="ascii")
    findings_sha = digest(findings)
    range_sha = digest(commit_range)

    # Digest receipts bind the exact source bytes, not merely their path.
    original = findings.read_bytes()
    findings.write_bytes(original.replace(b"correct alpha", b"mutated alpha"))
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(findings),
        "--findings-sha256", findings_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(evidence / "phase1-disposition.json"),
    ], expected=74)
    findings.write_bytes(original)
    original_range = commit_range.read_bytes()
    commit_range.write_text(f"{'0' * 40}..{head}\n", encoding="ascii")
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(findings),
        "--findings-sha256", findings_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(evidence / "phase1-disposition.json"),
    ], expected=74)
    commit_range.write_bytes(original_range)

    # Dirty state refusals do not change HEAD or the cached bytes.
    dirty_disposition = evidence / "phase1-disposition.json"
    dirty_disposition.write_bytes(b"")
    out_of_range_findings = evidence / "out-of-range-final.md"
    out_of_range_findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/outside.py", "1", "DEFERRED",
         "valid row cannot authorize a file outside the reviewed range", "bounded"),
    ]))
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(out_of_range_findings),
        "--findings-sha256", digest(out_of_range_findings),
        "--commit-range-path", str(commit_range), "--commit-range-sha256", range_sha,
        "--working-dir", str(repo), "--disposition-path", str(dirty_disposition),
    ], expected=74)
    huge_line_findings = evidence / "huge-line-final.md"
    huge_line_findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/a.py", "9" * 5000, "DEFERRED",
         "bounded failure", "bounded"),
    ]))
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(huge_line_findings),
        "--findings-sha256", digest(huge_line_findings),
        "--commit-range-path", str(commit_range), "--commit-range-sha256", range_sha,
        "--working-dir", str(repo), "--disposition-path", str(dirty_disposition),
    ], expected=74)
    (repo / "src/b.py").write_text("B = 2\n", encoding="utf-8")
    git(repo, "add", "--", "src/b.py")
    cached_before = git(repo, "diff", "--cached", "--binary").stdout
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(findings),
        "--findings-sha256", findings_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(dirty_disposition),
    ], expected=74)
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert git(repo, "diff", "--cached", "--binary").stdout == cached_before
    git(repo, "restore", "--staged", "--worktree", "--", "src/b.py")

    # A zero-APPLIED disposition cannot authorize leftover target edits or a
    # newly-created untracked target.
    simplify_findings = evidence / "simplify-final.md"
    simplify_findings.write_bytes(phase2_table([
        ("quality", "blocker", "src/b.py", "1", "DEFERRED",
         "leave beta unchanged"),
        ("reuse", "suggestion", "src/new.py", "1", "DEFERRED",
         "do not create a file"),
    ]))
    phase2_disposition = evidence / "phase2-disposition.json"
    phase2_disposition.write_bytes(b"")
    phase2_receipt = prepare(
        repo,
        simplify_findings,
        digest(simplify_findings),
        commit_range,
        range_sha,
        phase2_disposition,
        edge="review_pr.fix.phase2",
        policy_phase="simplify_fix",
    )
    phase2_authority_path = pathlib.Path(phase2_receipt["authority_path"])
    phase2_authority = json.loads(phase2_authority_path.read_text(encoding="utf-8"))
    phase2_rows = [
        {
            **finding,
            "disposition": "SKIPPED",
            "behavior_tag": "n/a",
            "reason": "no safe change needed",
        }
        for finding in phase2_authority["finding_keys"]
    ]
    phase2_change_rows = json.loads(json.dumps(phase2_rows))
    phase2_change_rows[0]["disposition"] = "APPLIED"
    phase2_change_rows[0]["behavior_tag"] = "change"
    run([
        "publish-disposition",
        "--authority-path", str(phase2_authority_path),
        "--authority-sha256", phase2_receipt["authority_sha256"],
        "--disposition-path", str(phase2_disposition),
    ], stdin=json.dumps(candidate(phase2_authority, phase2_change_rows)), expected=74)
    assert phase2_disposition.stat().st_size == 0
    phase2_published = json.loads(run([
        "publish-disposition",
        "--authority-path", str(phase2_authority_path),
        "--authority-sha256", phase2_receipt["authority_sha256"],
        "--disposition-path", str(phase2_disposition),
    ], stdin=json.dumps(candidate(phase2_authority, phase2_rows))))
    phase2_validate = [
        "validate-staged",
        "--authority-path", str(phase2_authority_path),
        "--authority-sha256", phase2_receipt["authority_sha256"],
        "--disposition-path", str(phase2_disposition),
        "--disposition-sha256", phase2_published["disposition_sha256"],
        "--working-dir", str(repo),
    ]
    (repo / "src/b.py").write_text("B = 2\n", encoding="utf-8")
    run(phase2_validate, expected=74)
    (repo / "src/b.py").write_text("B = 1\n", encoding="utf-8")
    (repo / "src/c.py").write_text("C = 2\n", encoding="utf-8")
    run(phase2_validate, expected=74)
    (repo / "src/c.py").write_text("C = 1\n", encoding="utf-8")
    (repo / "src/new.py").write_text("NEW = 1\n", encoding="utf-8")
    run(phase2_validate, expected=74)
    (repo / "src/new.py").unlink()
    (repo / "src/untracked-outside.py").write_text("OUTSIDE = 1\n", encoding="utf-8")
    run(phase2_validate, expected=74)
    (repo / "src/untracked-outside.py").unlink()

    (repo / "src/a.py").write_text("A = 2\n", encoding="utf-8")
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(findings),
        "--findings-sha256", findings_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(dirty_disposition),
    ], expected=74)
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    (repo / "src/a.py").write_text("A = 1\n", encoding="utf-8")

    untracked_findings = evidence / "untracked-final.md"
    untracked_findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/new.py", "1", "DEFERRED",
         "no new file", "bounded"),
    ]))
    untracked_sha = digest(untracked_findings)
    (repo / "src/new.py").write_text("NEW = 1\n", encoding="utf-8")
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(untracked_findings),
        "--findings-sha256", untracked_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(dirty_disposition),
    ], expected=74)
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    (repo / "src/new.py").unlink()

    # A gitignored dependency tree, in place BEFORE the mint (#478). npm and
    # pnpm hardlink package files out of the global cache, so `st_nlink > 1` is
    # the ORDINARY shape under `node_modules` — and the owned-regular capture
    # that the untracked scan runs over every path it enumerates rejects
    # exactly that (`artifact_not_owned_regular`), as does any file past
    # `WORKTREE_FILE_LIMIT`. Enumerating ignored paths therefore made the mint
    # itself abort on a normal JavaScript checkout, before hashing ~62k paths
    # could even become the cost complaint.
    dependency_tree = repo / "node_modules/.cache"
    dependency_tree.mkdir(parents=True)
    (dependency_tree / "package.bin").write_bytes(b"cached-package\n")
    os.link(dependency_tree / "package.bin", dependency_tree / "linked.bin")

    # A clean preparation publishes one closed, deterministic authority snapshot.
    authority_receipt = prepare(
        repo, findings, findings_sha, commit_range, range_sha, dirty_disposition
    )
    assert authority_receipt["phase"] == "phase1"
    assert authority_receipt["commit_type"] == "fix"
    assert authority_receipt["target_paths"] == ["src/a.py", "src/b.py"]
    authority_path = pathlib.Path(authority_receipt["authority_path"])
    assert authority_path.name == "code-fixer-authority-phase1.json"
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    assert set(authority) == {
        "schema_version", "edge_id", "policy_phase", "phase", "commit_type",
        "findings_path", "findings_sha256", "commit_range_path",
        "commit_range_sha256", "working_dir", "disposition_path",
        "finding_keys", "target_paths", "parent_sha", "parent_tree_sha",
        "index_path", "index_tree_sha", "index_sha256", "index_size",
        "index_mode", "untracked",
    }
    assert authority["schema_version"] == 1
    # U0 is the NON-ignored untracked set. `ignored.cfg` and the dependency
    # tree above cannot enter the commit under review — the diff, the
    # target-path allowlist and `commit-review` all operate on tracked content
    # — so they are not baseline state and their churn is not drift.
    assert authority["untracked"] == [], authority["untracked"]
    assert authority["findings_sha256"] == findings_sha
    assert authority["commit_range_sha256"] == range_sha
    assert [row["finding_index"] for row in authority["finding_keys"]] == [1, 2]
    assert all(set(row) == {"finding_index", "location", "summary_sha256"}
               for row in authority["finding_keys"])

    # The controller binds the exact child identity and controller-created
    # authority immediately after dispatch, before any fixer edit or commit.
    review_result_path = evidence / "phase1-fixer-result.md"
    review_status_path = evidence / "phase1-fixer-status.json"
    review_process_identity = (
        "23456|23456|23456|"
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )
    review_lease = "0123456789abcdef0123456789abcdef"
    review_status_document = {
        "backend": "background",
        "branch": "",
        "exit_code": None,
        "lease_generation": review_lease,
        "pid": "23456",
        "process_identity": review_process_identity,
        "result": str(review_result_path.resolve()),
        "state": "running",
        "workspace_mode": "caller",
        "worktree": str(repo.resolve()),
    }
    review_status_path.write_text(
        json.dumps(review_status_document, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    review_instance_id = "review-fix-phase1-iter01-attempt01"
    review_launch_receipt = json.dumps(
        {
            "schema_version": 1,
            "edge_id": "review_pr.fix.phase1",
            "instance_id": review_instance_id,
            "backend": "background",
            "handle": "23456",
            "state": "running",
            "result_file": str(review_result_path.resolve()),
            "status_file": str(review_status_path.resolve()),
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    review_launch_binding = module.bind_fixer_launch_receipt(
        receipt=review_launch_receipt,
        edge_id="review_pr.fix.phase1",
        instance_id=review_instance_id,
        result_path=str(review_result_path.resolve()),
        status_path=str(review_status_path.resolve()),
        working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
    )
    review_launch_binding_bytes = json.dumps(
        review_launch_binding, sort_keys=True, separators=(",", ":")
    ).encode()
    authority_before = authority_path.read_bytes()
    run([
        "prepare-authority", "--edge-id", "review_pr.fix.phase1",
        "--policy-phase", "review_fix", "--findings-path", str(findings),
        "--findings-sha256", findings_sha, "--commit-range-path", str(commit_range),
        "--commit-range-sha256", range_sha, "--working-dir", str(repo),
        "--disposition-path", str(dirty_disposition),
    ], expected=74)
    assert authority_path.read_bytes() == authority_before

    rows = [
        {
            **authority["finding_keys"][0],
            "disposition": "APPLIED",
            "behavior_tag": "change",
            "reason": "minimal correction",
        },
        {
            **authority["finding_keys"][1],
            "disposition": "SKIPPED",
            "behavior_tag": "n/a",
            "reason": "false positive",
        },
    ]
    valid_candidate = candidate(authority, rows)

    def publish(raw, expected=74):
        return run([
            "publish-disposition", "--authority-path", str(authority_path),
            "--authority-sha256", authority_receipt["authority_sha256"],
            "--disposition-path", str(dirty_disposition),
        ], stdin=raw, expected=expected)

    # Ignored-path churn between mint and publication is judged at the one
    # publication below that SUCCEEDS, not here: with every APPLIED target
    # still clean, `review_applied_path_mismatch` refuses first, so an arm
    # placed here reports exit 74 whichever way the baseline is scanned.

    authority_swap = evidence / "authority-replacement.json"
    authority_swap.write_bytes(authority_before + b" ")
    authority_swap.chmod(0o400)
    os.replace(authority_swap, authority_path)
    publish(json.dumps(valid_candidate))
    assert dirty_disposition.exists() and dirty_disposition.stat().st_size == 0
    authority_swap.write_bytes(authority_before)
    authority_swap.chmod(0o400)
    os.replace(authority_swap, authority_path)

    malformed_cases = []
    malformed_cases.append('{"schema_version":1,"schema_version":1}')
    malformed_cases.append('{"schema_version":NaN}')
    malformed_cases.append(json.dumps(valid_candidate | {"extra": True}))
    wrong_phase = json.loads(json.dumps(valid_candidate)); wrong_phase["phase"] = "phase2"
    malformed_cases.append(json.dumps(wrong_phase))
    wrong_triple = json.loads(json.dumps(valid_candidate))
    wrong_triple["findings_disposition"][0]["location"] = "src/b.py:1"
    malformed_cases.append(json.dumps(wrong_triple))
    duplicate_row = json.loads(json.dumps(valid_candidate))
    duplicate_row["findings_disposition"][1] = duplicate_row["findings_disposition"][0]
    malformed_cases.append(json.dumps(duplicate_row))
    list_disposition = json.loads(json.dumps(valid_candidate))
    list_disposition["findings_disposition"][0]["disposition"] = []
    malformed_cases.append(json.dumps(list_disposition))
    list_behavior = json.loads(json.dumps(valid_candidate))
    list_behavior["findings_disposition"][0]["behavior_tag"] = []
    malformed_cases.append(json.dumps(list_behavior))
    for raw in malformed_cases:
        publish(raw)
        assert dirty_disposition.exists() and dirty_disposition.stat().st_size == 0

    (repo / "src/a.py").write_text("A = 2\n", encoding="utf-8")
    # The fixer is REQUIRED to run the suite between the authority mint and
    # `publish-disposition`, and a test run writes into ignored cache trees —
    # vitest drops `node_modules/.vite/vitest/<hash>/results.json` on every
    # run. A baseline that enumerated ignored paths counted those writes as
    # new untracked state, so publication refused `review_baseline_mismatch`:
    # a fixer that tested its own work invalidated its own authority. (#478)
    (repo / "ignored.cfg").write_text("LOCAL = attacker\n", encoding="utf-8")
    vitest_cache = repo / "node_modules/.vite/vitest/da39a3ee5e6b4b0d"
    vitest_cache.mkdir(parents=True)
    (vitest_cache / "results.json").write_text('{"version":1}\n', encoding="utf-8")
    published = json.loads(publish(json.dumps(valid_candidate), expected=0))
    assert set(published) == {
        "disposition_path", "disposition_sha256", "applied_paths",
        "applied_content_path", "applied_content_sha256",
    }
    assert published["disposition_path"] == str(dirty_disposition.resolve())
    assert published["applied_paths"] == ["src/a.py"]

    disposition_before = dirty_disposition.read_bytes()
    disposition_swap = evidence / "disposition-replacement.json"
    disposition_swap.write_bytes(disposition_before + b" ")
    disposition_swap.chmod(0o400)
    os.replace(disposition_swap, dirty_disposition)
    run([
        "validate-staged", "--authority-path", str(authority_path),
        "--authority-sha256", authority_receipt["authority_sha256"],
        "--disposition-path", str(dirty_disposition),
        "--disposition-sha256", published["disposition_sha256"],
        "--working-dir", str(repo),
    ], expected=74)
    disposition_swap.write_bytes(disposition_before)
    disposition_swap.chmod(0o400)
    os.replace(disposition_swap, dirty_disposition)

    baseline_index = pathlib.Path(authority["index_path"]).read_bytes()

    # Source evidence remains live authority until the helper-owned commit boundary.
    findings.write_bytes(original.replace(b"correct alpha", b"tampered alpha"))
    run([
        "commit-review", "--authority-path", str(authority_path),
        "--authority-sha256", authority_receipt["authority_sha256"],
        "--disposition-path", str(dirty_disposition),
        "--disposition-sha256", published["disposition_sha256"],
        "--applied-content-path", published["applied_content_path"],
        "--applied-content-sha256", published["applied_content_sha256"],
        "--working-dir", str(repo),
    ], expected=74)
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert pathlib.Path(authority["index_path"]).read_bytes() == baseline_index
    findings.write_bytes(original)

    # A lost HEAD CAS restores the exact raw index and publishes no commit.
    original_cas = module._cas_update_head
    module._cas_update_head = lambda *_args, **_kwargs: False
    try:
        expect_contract_failure(lambda: module.commit_review(
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(dirty_disposition),
            disposition_sha256=published["disposition_sha256"],
            applied_content_path=published["applied_content_path"],
            applied_content_sha256=published["applied_content_sha256"],
            working_dir=str(repo),
        ))
    finally:
        module._cas_update_head = original_cas
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert pathlib.Path(authority["index_path"]).read_bytes() == baseline_index
    assert not list(evidence.glob("review-commit-transaction-*"))
    assert not list(evidence.glob("review-index-backup-*"))

    # The helper owns staging, hooks, commit-object validation, index install,
    # and the HEAD CAS as one recoverable transaction.
    commit_validated = json.loads(run([
        "commit-review", "--authority-path", str(authority_path),
        "--authority-sha256", authority_receipt["authority_sha256"],
        "--disposition-path", str(dirty_disposition),
        "--disposition-sha256", published["disposition_sha256"],
        "--applied-content-path", published["applied_content_path"],
        "--applied-content-sha256", published["applied_content_sha256"],
        "--working-dir", str(repo),
    ]))
    committed = commit_validated["commit_sha"]
    expected_message = "fix: address authenticated fixer findings"
    expected_message_sha256 = hashlib.sha256(expected_message.encode()).hexdigest()
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == committed
    assert run([
        "commit-message-digest", "--working-dir", str(repo),
        "--commit-sha", committed,
    ]) == expected_message_sha256
    assert commit_validated["status"] == "commit_validated"
    assert commit_validated["phase"] == "phase1"
    assert commit_validated["commit_type"] == "fix"
    assert commit_validated["parent_sha"] == head
    assert commit_validated["message_sha256"] == expected_message_sha256
    assert commit_validated["disposition_sha256"] == published["disposition_sha256"]
    assert not list(evidence.glob("review-commit-transaction-*"))
    assert not list(evidence.glob("review-index-backup-*"))

    # The controller freezes terminal bytes and validates the result against
    # the launch-bound authority, child identity, disposition, content plan,
    # and exact before/after commit pair.
    review_result_lines = [
        "```yaml",
        "status: APPLIED",
        "phase: phase1",
        "commits:",
        f"  - sha: {committed}",
        "    type: fix",
        "    summary: bounded authenticated correction",
        "findings_disposition:",
    ]
    for row in rows:
        review_result_lines.extend(
            [
                f"  - finding_index: {row['finding_index']}",
                f"    location: {row['location']}",
                f"    summary_sha256: {row['summary_sha256']}",
                f"    disposition: {row['disposition']}",
                f"    behavior_tag: {row['behavior_tag']}",
                f"    reason: {row['reason']}",
            ]
        )
    review_result_lines.extend(["risks: []", "```"])
    review_result_bytes = ("\n".join(review_result_lines) + "\n").encode()
    review_result_path.write_bytes(review_result_bytes)
    review_status_document.update({"exit_code": 0, "state": "completed"})
    review_status_bytes = (
        json.dumps(review_status_document, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode()
    review_status_path.write_bytes(review_status_bytes)
    review_terminal = module.capture_review_terminal(
        launch_binding=review_launch_binding_bytes,
        disposition_path=str(dirty_disposition),
        applied_content_path=published["applied_content_path"],
    )
    review_outcome = module.validate_review_outcome(
        launch_binding=review_launch_binding_bytes,
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(dirty_disposition),
        disposition_sha256=review_terminal["disposition_sha256"],
        applied_content_path=review_terminal["applied_content_path"],
        applied_content_sha256=review_terminal["applied_content_sha256"],
        status_sha256=review_terminal["status_sha256"],
        result_sha256=review_terminal["result_sha256"],
        working_dir=str(repo),
        head_before=head,
        head_after=committed,
    )
    assert review_outcome["status"] == "APPLIED"
    assert review_outcome["declared_tip"] == committed
    assert review_outcome["commit"]["commit_type"] == "fix"
    assert json.loads(
        run(
            [
                "validate-review-outcome",
                "--launch-binding-json",
                review_launch_binding_bytes.decode(),
                "--authority-path",
                str(authority_path),
                "--authority-sha256",
                authority_receipt["authority_sha256"],
                "--disposition-path",
                str(dirty_disposition),
                "--disposition-sha256",
                review_terminal["disposition_sha256"],
                "--applied-content-path",
                review_terminal["applied_content_path"],
                "--applied-content-sha256",
                review_terminal["applied_content_sha256"],
                "--status-sha256",
                review_terminal["status_sha256"],
                "--result-sha256",
                review_terminal["result_sha256"],
                "--working-dir",
                str(repo),
                "--head-before",
                head,
                "--head-after",
                committed,
            ]
        )
    ) == review_outcome

    # Replacing either terminal artifact or forging the bound child identity
    # cannot be made coherent by supplying a new digest after the wait.
    review_result_path.write_bytes(review_result_bytes + b"replacement\n")
    expect_contract_failure(
        lambda: module.validate_review_outcome(
            launch_binding=review_launch_binding_bytes,
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(dirty_disposition),
            disposition_sha256=review_terminal["disposition_sha256"],
            applied_content_path=review_terminal["applied_content_path"],
            applied_content_sha256=review_terminal["applied_content_sha256"],
            status_sha256=review_terminal["status_sha256"],
            result_sha256=review_terminal["result_sha256"],
            working_dir=str(repo),
            head_before=head,
            head_after=committed,
        )
    )
    review_result_path.write_bytes(review_result_bytes)
    forged_status = dict(review_status_document)
    forged_status["pid"] = "99999"
    review_status_path.write_text(
        json.dumps(forged_status, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    forged_terminal = module.capture_review_terminal(
        launch_binding=review_launch_binding_bytes,
        disposition_path=str(dirty_disposition),
        applied_content_path=published["applied_content_path"],
    )
    expect_contract_failure(
        lambda: module.validate_review_outcome(
            launch_binding=review_launch_binding_bytes,
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(dirty_disposition),
            disposition_sha256=forged_terminal["disposition_sha256"],
            applied_content_path=forged_terminal["applied_content_path"],
            applied_content_sha256=forged_terminal["applied_content_sha256"],
            status_sha256=forged_terminal["status_sha256"],
            result_sha256=forged_terminal["result_sha256"],
            working_dir=str(repo),
            head_before=head,
            head_after=committed,
        )
    )
    review_status_path.write_bytes(review_status_bytes)

with scratch_dir("code-fixer-rename-") as temporary:
    # Rename/copy detection must not collapse an unapproved source path into an
    # approved destination. With detection disabled this is a D+A pair, both
    # of which are forbidden at the staged commit boundary.
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "src").mkdir()
    (repo / "src/source.py").write_text("VALUE = 1\n", encoding="utf-8")
    (repo / "src/renamed.py").write_text("OLD = 1\n", encoding="utf-8")
    git(repo, "add", "--", "src/source.py", "src/renamed.py")
    git(repo, "commit", "-qm", "test: rename fixture base")
    rename_base = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "src/renamed.py").unlink()
    git(repo, "add", "--", "src/renamed.py")
    git(repo, "commit", "-qm", "test: rename fixture head")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    rename_evidence = repo / ".uberdev/research/20260728-010204-abcdef0"
    rename_evidence.mkdir(parents=True)
    rename_findings = rename_evidence / "post-impl-review-final.md"
    rename_findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/renamed.py", "1", "DEFERRED",
         "rename destination must not hide its source", "bounded"),
    ]))
    rename_commit_range = rename_evidence / "commit-range.txt"
    rename_commit_range.write_text(f"{rename_base}..{head}\n", encoding="ascii")
    rename_disposition = rename_evidence / "phase1-disposition.json"
    rename_disposition.write_bytes(b"")
    rename_receipt = prepare(
        repo, rename_findings, digest(rename_findings), rename_commit_range,
        digest(rename_commit_range), rename_disposition,
    )
    rename_authority_path = pathlib.Path(rename_receipt["authority_path"])
    rename_authority = json.loads(rename_authority_path.read_text(encoding="utf-8"))
    rename_row = {
        **rename_authority["finding_keys"][0],
        "disposition": "APPLIED",
        "behavior_tag": "preserve",
        "reason": "bounded rename fixture",
    }
    run([
        "publish-disposition",
        "--authority-path", str(rename_authority_path),
        "--authority-sha256", rename_receipt["authority_sha256"],
        "--disposition-path", str(rename_disposition),
    ], stdin=json.dumps(candidate(rename_authority, [rename_row])), expected=74)
    assert rename_disposition.read_bytes() == b""
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head

with scratch_dir("code-fixer-index-tree-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "foo.bar").write_bytes(b"regular\n")
    (repo / "foo").mkdir()
    (repo / "foo/child").write_bytes(b"nested\n")
    (repo / "foo0").write_bytes(b"prefix ordering\n")
    executable = repo / "executable"
    executable.write_bytes(b"#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    symlink_supported = os.name != "nt"
    if symlink_supported:
        os.symlink("foo.bar", repo / "symlink")
    raw_name = b"raw-\xff"
    raw_path = os.path.join(os.fsencode(repo), raw_name)
    raw_path_supported = True
    try:
        raw_descriptor = os.open(
            raw_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
            0o600,
        )
    except (OSError, TypeError):
        raw_path_supported = False
    else:
        try:
            os.write(raw_descriptor, b"raw path\n")
        finally:
            os.close(raw_descriptor)
    git(repo, "add", "-A")
    gitlink_oid = "1" * 40
    git(
        repo,
        "update-index",
        "--add",
        "--cacheinfo",
        "160000",
        gitlink_oid,
        "gitlink",
    )
    git(repo, "commit", "-qm", "test: index tree shapes")
    raw_index_path = pathlib.Path(module._git_index_path(str(repo)))
    git_dir = raw_index_path.parent
    alternate = git_dir / "expected-tree-index"
    shutil.copyfile(raw_index_path, alternate)
    expected_environment = os.environ.copy()
    expected_environment["GIT_INDEX_FILE"] = str(alternate)
    expected_tree = subprocess.run(
        ["git", "-C", str(repo), "write-tree"],
        env=expected_environment,
        capture_output=True,
        check=True,
    ).stdout.decode("ascii").strip()
    alternate.unlink()
    raw_blob = subprocess.run(
        ["git", "-C", str(repo), "hash-object", "-w", "--stdin"],
        input=b"raw tree path\n",
        capture_output=True,
        check=True,
    ).stdout.strip()
    raw_tree = subprocess.run(
        ["git", "-C", str(repo), "mktree", "-z"],
        input=b"100644 blob " + raw_blob + b"\t" + raw_name + b"\x00",
        capture_output=True,
        check=True,
    ).stdout.decode("ascii").strip()
    assert module._tree_sha_from_stage_rows(
        str(repo),
        b"100644 " + raw_blob + b" 0\t" + raw_name + b"\x00",
    ) == raw_tree
    index_before = regular_snapshot(raw_index_path)
    objects_before = git_object_files(repo)
    assert module._index_tree_sha(str(repo)) == expected_tree
    assert regular_snapshot(raw_index_path) == index_before
    assert git_object_files(repo) == objects_before
    assert not tuple(git_dir.glob(".code-fixer-private-git-*"))
    listed = git(repo, "ls-files", "--stage", "-z").stdout
    assert b"100755 " in listed
    assert b"160000 " + gitlink_oid.encode("ascii") + b" 0\tgitlink\x00" in listed
    if raw_path_supported:
        assert b"\t" + raw_name + b"\x00" in listed
    if symlink_supported:
        assert b"120000 " in listed

    deep_index = git_dir / "deep-index"
    deep_environment = os.environ.copy()
    deep_environment["GIT_INDEX_FILE"] = str(deep_index)
    subprocess.run(
        ["git", "-C", str(repo), "read-tree", "--empty"],
        env=deep_environment,
        capture_output=True,
        check=True,
    )
    deep_path = ("a/" * 1000) + "z"
    subprocess.run(
        [
            "git", "-C", str(repo), "update-index", "--info-only", "--add",
            "--cacheinfo", "100644", raw_blob.decode("ascii"), deep_path,
        ],
        env=deep_environment,
        capture_output=True,
        check=True,
    )
    expected_deep_tree = subprocess.run(
        ["git", "-C", str(repo), "write-tree"],
        env=deep_environment,
        capture_output=True,
        check=True,
    ).stdout.decode("ascii").strip()
    assert module._index_tree_sha(
        str(repo), extra_env={"GIT_INDEX_FILE": str(deep_index)}
    ) == expected_deep_tree
    deep_index.unlink()

    replacement = git_dir / "same-byte-index-replacement"
    replacement.write_bytes(raw_index_path.read_bytes())
    original_parse_raw_index = module._parse_raw_index
    canonical_rebound = {"done": False}

    def rebind_canonical_index(payload, *, split_overlay):
        result = original_parse_raw_index(payload, split_overlay=split_overlay)
        if not canonical_rebound["done"]:
            os.replace(replacement, raw_index_path)
            canonical_rebound["done"] = True
        return result

    module._parse_raw_index = rebind_canonical_index
    try:
        expect_contract_reason(
            lambda: module._index_tree_sha(str(repo)),
            "index_observation_lock_recovery_failed",
        )
    finally:
        module._parse_raw_index = original_parse_raw_index
    assert canonical_rebound["done"]
    assert raw_index_path.read_bytes() == index_before[0]
    assert regular_snapshot(raw_index_path) != index_before
    assert not tuple(git_dir.glob(".code-fixer-private-git-*"))

    attacker_index_path = git_dir / "attacker-selected-index"
    attacker_environment = os.environ.copy()
    attacker_environment["GIT_INDEX_FILE"] = str(attacker_index_path)
    subprocess.run(
        ["git", "-C", str(repo), "read-tree", "HEAD"],
        env=attacker_environment,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        [
            "git", "-C", str(repo), "update-index", "--info-only", "--add",
            "--cacheinfo", "160000", "3" * 40, "attacker-selected",
        ],
        env=attacker_environment,
        capture_output=True,
        check=True,
    )
    attacker_index_payload = attacker_index_path.read_bytes()
    attacker_index_path.unlink()
    publication_index = git_dir / "publication-candidate"
    publication_payload = module._build_tree_index_candidate(
        str(repo), git(repo, "rev-parse", "HEAD").stdout.decode("ascii").strip(), {}
    )
    publication_index.write_bytes(publication_payload)
    observed_publication, publication_identity = module._capture_regular(
        str(publication_index), len(publication_payload), len(publication_payload)
    )
    assert observed_publication == publication_payload
    original_run_candidate_write_tree = module._run_candidate_write_tree
    post_mutation_rebound = {"done": False}

    def rebind_after_mutating_git(working_dir, index_path):
        result = original_run_candidate_write_tree(working_dir, index_path)
        if not post_mutation_rebound["done"]:
            replacement_index = pathlib.Path(index_path).with_suffix(".replacement")
            replacement_index.write_bytes(attacker_index_payload)
            os.replace(replacement_index, index_path)
            post_mutation_rebound["done"] = True
        return result

    module._run_candidate_write_tree = rebind_after_mutating_git
    try:
        expect_contract_reason(
            lambda: module._publish_index_tree_sha(
                str(repo),
                str(publication_index),
                publication_payload,
                publication_identity,
            ),
            "index_tree_unreadable",
        )
    finally:
        module._run_candidate_write_tree = original_run_candidate_write_tree
    assert post_mutation_rebound["done"]
    assert not publication_index.exists()
    quarantines = tuple(git_dir.glob(".code-fixer-index-quarantine-*"))
    assert len(quarantines) == 1
    assert quarantines[0].read_bytes() == attacker_index_payload
    quarantines[0].unlink()

    precapture_index = git_dir / "pre-capture-candidate"
    precapture_index.write_bytes(publication_payload)
    observed_precapture, precapture_identity = module._capture_regular(
        str(precapture_index), len(publication_payload), len(publication_payload)
    )
    assert observed_precapture == publication_payload
    precapture_replacement = git_dir / "pre-capture-replacement"
    precapture_replacement.write_bytes(attacker_index_payload)
    os.replace(precapture_replacement, precapture_index)
    expect_contract_reason(
        lambda: module._publish_index_tree_sha(
            str(repo),
            str(precapture_index),
            publication_payload,
            precapture_identity,
        ),
        "index_tree_unreadable",
    )
    assert not precapture_index.exists()
    quarantines = tuple(git_dir.glob(".code-fixer-index-quarantine-*"))
    assert len(quarantines) == 1
    assert quarantines[0].read_bytes() == attacker_index_payload
    quarantines[0].unlink()

with scratch_dir("code-fixer-index-refusal-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "base").write_bytes(b"base\n")
    git(repo, "add", "--", "base")
    git(repo, "commit", "-qm", "test: refusal base")
    raw_index_path = pathlib.Path(module._git_index_path(str(repo)))
    git_dir = raw_index_path.parent
    baseline = regular_snapshot(raw_index_path)

    (repo / "intent-to-add").write_bytes(b"")
    git(repo, "add", "-N", "--", "intent-to-add")
    ita_index = regular_snapshot(raw_index_path)
    expect_contract_reason(
        lambda: module._index_tree_sha(str(repo)), "index_tree_unreadable"
    )
    assert regular_snapshot(raw_index_path) == ita_index
    git(repo, "reset", "--mixed", "-q", "HEAD")
    (repo / "intent-to-add").unlink()
    baseline = regular_snapshot(raw_index_path)

    git(repo, "update-index", "--assume-unchanged", "--", "base")
    assume_unchanged = regular_snapshot(raw_index_path)
    expect_contract_reason(
        lambda: module._index_tree_sha(str(repo)), "index_tree_unreadable"
    )
    expect_contract_reason(
        lambda: module._build_index_candidate(
            str(repo), assume_unchanged[0], assume_unchanged[4], {}
        ),
        "index_tree_unreadable",
    )
    assert regular_snapshot(raw_index_path) == assume_unchanged
    git(repo, "update-index", "--no-assume-unchanged", "--", "base")

    git(repo, "update-index", "--skip-worktree", "--", "base")
    skip_worktree = regular_snapshot(raw_index_path)
    expect_contract_reason(
        lambda: module._index_tree_sha(str(repo)), "index_tree_unreadable"
    )
    expect_contract_reason(
        lambda: module._build_index_candidate(
            str(repo), skip_worktree[0], skip_worktree[4], {}
        ),
        "index_tree_unreadable",
    )
    assert regular_snapshot(raw_index_path) == skip_worktree
    git(repo, "update-index", "--no-skip-worktree", "--", "base")
    baseline = regular_snapshot(raw_index_path)

    null_index = bytearray(raw_index_path.read_bytes())
    assert null_index[:4] == b"DIRC"
    null_index[52:72] = b"\x00" * 20
    null_index[-20:] = hashlib.sha1(null_index[:-20]).digest()
    expect_contract_reason(
        lambda: module._validate_normalized_index(bytes(null_index)),
        "index_tree_unreadable",
    )

    blobs = []
    for payload in (b"ancestor\n", b"ours\n", b"theirs\n"):
        blobs.append(
            subprocess.run(
                ["git", "-C", str(repo), "hash-object", "-w", "--stdin"],
                input=payload,
                capture_output=True,
                check=True,
            ).stdout.decode("ascii").strip()
        )
    unmerged_index = git_dir / "unmerged-index"
    unmerged_environment = os.environ.copy()
    unmerged_environment["GIT_INDEX_FILE"] = str(unmerged_index)
    index_info = b"".join(
        f"100644 {oid} {stage}\tconflict\n".encode("ascii")
        for stage, oid in enumerate(blobs, start=1)
    )
    subprocess.run(
        ["git", "-C", str(repo), "update-index", "--index-info"],
        input=index_info,
        env=unmerged_environment,
        capture_output=True,
        check=True,
    )
    expect_contract_reason(
        lambda: module._index_tree_sha(
            str(repo), extra_env={"GIT_INDEX_FILE": str(unmerged_index)}
        ),
        "index_tree_unreadable",
    )
    unmerged_index.unlink()

    missing_index = git_dir / "missing-blob-index"
    missing_environment = os.environ.copy()
    missing_environment["GIT_INDEX_FILE"] = str(missing_index)
    subprocess.run(
        ["git", "-C", str(repo), "read-tree", "HEAD"],
        env=missing_environment,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        [
            "git", "-C", str(repo), "update-index", "--info-only", "--add",
            "--cacheinfo", "100644", "2" * 40, "missing-blob",
        ],
        env=missing_environment,
        capture_output=True,
        check=True,
    )
    expect_contract_reason(
        lambda: module._index_tree_sha(
            str(repo), extra_env={"GIT_INDEX_FILE": str(missing_index)}
        ),
        "index_tree_unreadable",
    )
    missing_index.unlink()
    assert regular_snapshot(raw_index_path) == baseline
    assert not tuple(git_dir.glob(".code-fixer-private-git-*"))

with scratch_dir("code-fixer-reuc-") as temporary:
    # #643 -- resolving ANY merge conflict makes git write a REUC (resolve-undo)
    # extension into .git/index, and this parser used to refuse the result
    # outright. That is the common case rather than a corner: /review-pr Phase 0
    # consolidates (so it resolves conflicts), then Phase 1's fixer calls
    # prepare-authority, which reads this very index. Resolve-undo is inert for
    # the staged tree -- measured below -- so the parser must READ a REUC index.
    # Pre-cleaning it with `git read-tree HEAD` at the call site was the field
    # workaround, not the fix, and is deliberately not what this asserts.
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    conflict = repo / "conflict"
    conflict.write_bytes(b"base\n")
    git(repo, "add", "--", conflict.name)
    git(repo, "commit", "-qm", "test: resolve-undo base")
    main_branch = git(repo, "branch", "--show-current").stdout.decode().strip()
    git(repo, "branch", "resolve-undo-side")
    conflict.write_bytes(b"main\n")
    git(repo, "commit", "-qam", "test: resolve-undo main")
    git(repo, "checkout", "-q", "resolve-undo-side")
    conflict.write_bytes(b"side\n")
    git(repo, "commit", "-qam", "test: resolve-undo side")
    git(repo, "checkout", "-q", main_branch)
    merge = git(repo, "merge", "resolve-undo-side", check=False)
    assert merge.returncode != 0
    assert git(repo, "ls-files", "--unmerged").stdout
    conflict.write_bytes(b"resolved\n")
    git(repo, "add", "--", conflict.name)
    assert git(repo, "ls-files", "--resolve-undo").stdout
    reuc_tree = git(repo, "write-tree").stdout.decode().strip()
    reuc_index_path = pathlib.Path(module._git_index_path(str(repo)))
    reuc_index = regular_snapshot(reuc_index_path)
    assert b"REUC" in reuc_index[0]

    def index_extension_spans(payload):
        offset, limit, _sparse = module._index_entry_layout(payload)
        spans = {}
        while offset < limit:
            signature = payload[offset : offset + 4]
            size = int.from_bytes(payload[offset + 4 : offset + 8], "big")
            spans[signature] = (offset, offset + 8 + size)
            offset += 8 + size
        assert offset == limit, (offset, limit)
        return spans

    def resealed(body):
        return body + hashlib.sha1(body).digest()

    def with_extension(payload, signature, body=b""):
        return resealed(
            payload[:-20] + signature + len(body).to_bytes(4, "big") + body
        )

    def index_probe(parent, signature, payload):
        parent.mkdir(exist_ok=True)
        probe = parent / ("index-" + signature.decode("ascii"))
        probe.write_bytes(payload)
        return probe

    def git_reads_index(index_path):
        environment = dict(os.environ)
        environment["GIT_INDEX_FILE"] = str(index_path)
        return subprocess.run(
            ["git", "-C", str(repo), "-c", "gc.auto=0",
             "-c", "maintenance.auto=false", "ls-files"],
            env=environment,
            capture_output=True,
        )

    reuc_spans = index_extension_spans(reuc_index[0])
    assert set(reuc_spans) >= {b"TREE", b"REUC"}, sorted(reuc_spans)

    # The parser reads it, records the extension, and lands on git's own tree.
    reuc_entries, reuc_extensions = module._parse_raw_index(
        reuc_index[0], split_overlay=False
    )
    assert reuc_extensions[b"REUC"], sorted(reuc_extensions)
    assert [row[3] for row in reuc_entries] == [conflict.name.encode("ascii")]
    assert module._index_tree_sha(str(repo)) == reuc_tree
    assert module._build_index_candidate(
        str(repo), reuc_index[0], reuc_index[4], {}
    )
    assert regular_snapshot(reuc_index_path) == reuc_index

    # The measurement #643 asks for, taken on the bytes git itself wrote:
    # deleting the resolve-undo extension leaves the tree bit-identical, which
    # is why refusing it was never protecting anything. REUC is the trailing
    # extension here, so the strip is a truncation plus a fresh SHA-1 trailer.
    reuc_start, reuc_end = reuc_spans[b"REUC"]
    assert reuc_end == len(reuc_index[0]) - 20, (reuc_end, len(reuc_index[0]))
    stripped_parent = pathlib.Path(temporary) / "no resolve undo"
    stripped_parent.mkdir()
    stripped_index = stripped_parent / "index"
    stripped_index.write_bytes(resealed(reuc_index[0][:reuc_start]))
    assert b"REUC" not in stripped_index.read_bytes()
    assert git_reads_index(stripped_index).returncode == 0
    stripped_environment = dict(os.environ)
    stripped_environment["GIT_INDEX_FILE"] = str(stripped_index)
    stripped_tree = subprocess.run(
        ["git", "-C", str(repo), "-c", "gc.auto=0",
         "-c", "maintenance.auto=false", "write-tree"],
        env=stripped_environment,
        capture_output=True,
        check=True,
    ).stdout.decode().strip()
    assert stripped_tree == reuc_tree, (stripped_tree, reuc_tree)
    assert module._index_tree_sha(
        str(repo), extra_env={"GIT_INDEX_FILE": str(stripped_index)}
    ) == reuc_tree

    # The extension policy, pinned to git's OWN rule rather than to a
    # transcription of it (gitformat-index, read_index_extension):
    #   first byte 'A'..'Z'  => OPTIONAL. git prints "ignoring <SIG> extension"
    #                           and reads on.
    #   any other first byte => MANDATORY. git refuses the whole index
    #                           ("index uses <sig> extension, which we do not
    #                           understand") and exits non-zero.
    probe_parent = pathlib.Path(temporary) / "extension probes"
    for signature, git_reads_on in ((b"ZZZZ", True), (b"zzzz", False)):
        probe = index_probe(
            probe_parent, signature, with_extension(reuc_index[0], signature)
        )
        observed = git_reads_index(probe)
        assert (observed.returncode == 0) is git_reads_on, (signature, observed)

    # Direction 1 -- an unknown OPTIONAL extension is recorded and skipped, not
    # refused. EOIE and IEOT are exactly this class: `index.threads` and
    # `feature.manyFiles` put them on the index of an ordinary checkout, so a
    # blanket refusal here would resurface #643 under a different config.
    optional_probe = index_probe(
        probe_parent, b"ZZZZ", with_extension(reuc_index[0], b"ZZZZ", b"opaque")
    )
    _optional_entries, optional_extensions = module._parse_raw_index(
        optional_probe.read_bytes(), split_overlay=False
    )
    assert optional_extensions[b"ZZZZ"] == b"opaque", sorted(optional_extensions)
    assert module._index_tree_sha(
        str(repo), extra_env={"GIT_INDEX_FILE": str(optional_probe)}
    ) == reuc_tree

    # Direction 2 -- MANDATORY extensions this parser does not implement stay
    # refused, and the refusal carries its own token. `sdir` is the deliberate
    # one: a sparse index lets a single entry stand for a whole subtree, so the
    # stage rows derived here would no longer describe the same tree. `zzzz`
    # stands for every unknown mandatory signature. `index_tree_unreadable` is
    # the wrong token for both -- the index was read perfectly, and #643 records
    # an operator sent hunting for corruption that was never there.
    for signature in (b"sdir", b"zzzz"):
        refused_probe = index_probe(
            probe_parent, signature, with_extension(reuc_index[0], signature)
        )
        expect_contract_reason(
            lambda payload=refused_probe.read_bytes(): module._parse_raw_index(
                payload, split_overlay=False
            ),
            "index_extension_refused",
        )
        expect_contract_reason(
            lambda path=refused_probe: module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(path)}
            ),
            "index_extension_refused",
        )

    assert regular_snapshot(reuc_index_path) == reuc_index
    assert not tuple(reuc_index_path.parent.glob(".code-fixer-private-git-*"))

with scratch_dir("code-fixer-split-linked-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "tracked").write_bytes(b"tracked\n")
    git(repo, "add", "--", "tracked")
    git(repo, "commit", "-qm", "test: split and linked base")
    expected_tree = git(repo, "rev-parse", "HEAD^{tree}").stdout.decode().strip()
    raw_index_path = pathlib.Path(module._git_index_path(str(repo)))
    git_dir = raw_index_path.parent
    git(repo, "config", "splitIndex.maxPercentChange", "0")
    git(repo, "config", "splitIndex.sharedIndexExpire", "never")
    split_result = git(repo, "update-index", "--split-index", check=False)
    if split_result.returncode == 0:
        split_payload = raw_index_path.read_bytes()
        shared_reference = module._index_shared_reference(split_payload)
        assert shared_reference is not None
        shared_name = shared_reference
        canonical_shared = git_dir / shared_name
        shared_before = regular_snapshot(canonical_shared)
        alternate_parent = pathlib.Path(temporary) / "alternate split index"
        alternate_parent.mkdir()
        alternate_index = alternate_parent / "index"
        alternate_shared = alternate_parent / shared_name
        shutil.copyfile(raw_index_path, alternate_index)
        shutil.copyfile(canonical_shared, alternate_shared)
        hidden_shared = git_dir / f"{shared_name}.hidden"
        os.replace(canonical_shared, hidden_shared)
        try:
            assert module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(alternate_index)}
            ) == expected_tree
        finally:
            os.replace(hidden_shared, canonical_shared)
        assert regular_snapshot(canonical_shared)[0] == shared_before[0]
        shared_replacement = alternate_parent / f"{shared_name}.replacement"
        shared_replacement.write_bytes(alternate_shared.read_bytes())
        original_capture_regular = module._capture_regular
        shared_rebound = {"done": False}

        def rebind_alternate_shared(path, minimum, maximum):
            captured = original_capture_regular(path, minimum, maximum)
            if pathlib.Path(path) == alternate_shared and not shared_rebound["done"]:
                os.replace(shared_replacement, alternate_shared)
                shared_rebound["done"] = True
            return captured

        module._capture_regular = rebind_alternate_shared
        try:
            expect_contract_reason(
                lambda: module._index_tree_sha(
                    str(repo), extra_env={"GIT_INDEX_FILE": str(alternate_index)}
                ),
                "index_tree_unreadable",
            )
        finally:
            module._capture_regular = original_capture_regular
        assert shared_rebound["done"]
        assert alternate_shared.read_bytes() == shared_before[0]
        assert not tuple(git_dir.glob(".code-fixer-private-git-*"))
        alternate_index.unlink()
        alternate_shared.unlink()
    else:
        assert b"split-index" in split_result.stderr

    git(repo, "branch", "linked-fixture")
    linked = pathlib.Path(temporary) / "linked worktree"
    git(repo, "worktree", "add", "-q", str(linked), "linked-fixture")
    linked_index = pathlib.Path(module._git_index_path(str(linked)))
    linked_before = regular_snapshot(linked_index)
    assert module._index_tree_sha(str(linked)) == expected_tree
    assert regular_snapshot(linked_index) == linked_before
    assert not tuple(linked_index.parent.glob(".code-fixer-private-git-*"))

exercised_split_versions = set()
for index_version in (2, 3, 4):
    with scratch_dir(f"code-fixer-split-v{index_version}-") as temporary:
        repo = pathlib.Path(temporary) / "repo"
        repo.mkdir()
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "fixture@example.invalid")
        git(repo, "config", "user.name", "Fixture")
        for name in ("a", "b", "c", "d"):
            (repo / name).write_bytes(f"{name}-base\n".encode("ascii"))
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", f"test: split v{index_version} base")
        git(repo, "config", "splitIndex.maxPercentChange", "100")
        git(repo, "config", "splitIndex.sharedIndexExpire", "never")
        git(repo, "update-index", "--index-version", str(index_version))
        split_result = git(repo, "update-index", "--split-index", check=False)
        assert split_result.returncode == 0, split_result.stderr
        (repo / "a").write_bytes(b"a-replaced\n")
        (repo / "c").unlink()
        (repo / "e").write_bytes(b"e-added\n")
        git(repo, "add", "-A")
        split_index_path = pathlib.Path(module._git_index_path(str(repo)))
        split_payload, split_identity = module._capture_regular(
            str(split_index_path), 1, module.INDEX_LIMIT
        )
        shared_name = module._index_shared_reference(split_payload)
        assert shared_name is not None
        shared_path = split_index_path.parent / shared_name
        shared_payload = shared_path.read_bytes()
        if index_version == 3 and int.from_bytes(split_payload[4:8], "big") == 2:
            assert int.from_bytes(shared_payload[4:8], "big") == 2
            shared_content = bytearray(shared_payload[:-20])
            shared_content[4:8] = (3).to_bytes(4, "big")
            shared_digest = hashlib.sha1(shared_content).digest()
            shared_payload = bytes(shared_content) + shared_digest
            shared_path = split_index_path.parent / (
                "sharedindex." + shared_digest.hex()
            )
            shared_path.write_bytes(shared_payload)
            split_content = bytearray(split_payload[:-20])
            extension_offset, _content_limit, _sparse = module._index_entry_layout(
                split_payload
            )
            assert split_content[extension_offset : extension_offset + 4] == b"link"
            split_content[4:8] = (3).to_bytes(4, "big")
            split_content[extension_offset + 8 : extension_offset + 28] = shared_digest
            split_payload = bytes(split_content) + hashlib.sha1(split_content).digest()
            split_index_path.write_bytes(split_payload)
            split_payload, split_identity = module._capture_regular(
                str(split_index_path), len(split_payload), len(split_payload)
            )
        assert int.from_bytes(split_payload[4:8], "big") == index_version
        assert int.from_bytes(shared_payload[4:8], "big") == index_version
        shared_entries, _shared_extensions = module._parse_raw_index(
            shared_payload, split_overlay=False
        )
        overlay_entries, overlay_extensions = module._parse_raw_index(
            split_payload, split_overlay=True
        )
        link = overlay_extensions[b"link"]
        deleted, link_offset = module._decode_ewah_bitmap(
            link, 20, len(shared_entries)
        )
        replaced, link_offset = module._decode_ewah_bitmap(
            link, link_offset, len(shared_entries)
        )
        assert link_offset == len(link)
        assert deleted and replaced
        assert len(overlay_entries) > len(replaced)
        split_before = regular_snapshot(split_index_path)
        shared_before = regular_snapshot(shared_path)
        pure_rows = module._captured_index_stage_rows(
            str(repo), str(split_index_path), split_payload, split_identity
        )
        assert regular_snapshot(split_index_path) == split_before
        assert regular_snapshot(shared_path) == shared_before
        git_rows = git(repo, "ls-files", "--stage", "-z").stdout
        assert pure_rows == git_rows
        assert b"\ta\x00" in pure_rows
        assert b"\tc\x00" not in pure_rows
        assert b"\te\x00" in pure_rows
        exercised_split_versions.add(index_version)
assert exercised_split_versions == {2, 3, 4}

with scratch_dir("code-fixer-git-environment-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "original").write_bytes(b"original\n")
    git(repo, "add", "--", "original")
    git(repo, "commit", "-qm", "test: canonical environment base")
    original_commit = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    original_tree = git(repo, "rev-parse", "HEAD^{tree}").stdout.decode().strip()
    canonical_rows = module._read_tree_stage_rows(str(repo), original_commit)
    canonical_commit_payload = git(repo, "cat-file", "commit", original_commit).stdout

    (repo / "original").unlink()
    (repo / "replacement").write_bytes(b"replacement\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "test: hostile replacement commit")
    replacement_commit = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    git(repo, "reset", "--hard", "-q", original_commit)
    git(repo, "replace", original_commit, replacement_commit)
    assert b"replacement" in git(repo, "ls-tree", "-r", "-z", original_commit).stdout
    assert module._read_tree_stage_rows(str(repo), original_commit) == canonical_rows
    assert module._git(
        str(repo), "cat-file", "commit", original_commit
    ).stdout == canonical_commit_payload

    alternate_objects = pathlib.Path(temporary) / "alternate-objects"
    (alternate_objects / "info").mkdir(parents=True)
    (alternate_objects / "pack").mkdir()
    alternate_environment = os.environ.copy()
    alternate_environment["GIT_OBJECT_DIRECTORY"] = str(alternate_objects)
    alternate_only_oid = subprocess.run(
        ["git", "-C", str(repo), "hash-object", "-w", "--stdin"],
        input=b"alternate-only-object\n",
        env=alternate_environment,
        capture_output=True,
        check=True,
    ).stdout.decode().strip()
    assert (alternate_objects / alternate_only_oid[:2] / alternate_only_oid[2:]).is_file()
    assert module._git(
        str(repo), "cat-file", "-e", alternate_only_oid
    ).returncode != 0

    hostile_repository = pathlib.Path(temporary) / "hostile.git"
    subprocess.run(
        ["git", "init", "--bare", "-q", str(hostile_repository)], check=True
    )
    hostile_index = pathlib.Path(temporary) / "hostile-index"
    shutil.copyfile(module._git_index_path(str(repo)), hostile_index)
    hostile_global = pathlib.Path(temporary) / "hostile-global-config"
    hostile_global.write_text("[hostile]\n\tmarker = true\n", encoding="utf-8")
    hostile_values = {
        "GIT_OBJECT_DIRECTORY": str(alternate_objects),
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(alternate_objects),
        "GIT_INDEX_FILE": str(hostile_index),
        "GIT_CONFIG_GLOBAL": str(hostile_global),
        "GIT_DIR": str(hostile_repository),
        "GIT_WORK_TREE": str(pathlib.Path(temporary) / "hostile-worktree"),
        "GIT_COMMON_DIR": str(hostile_repository),
        "GIT_NO_REPLACE_OBJECTS": "0",
        "GIT_REPLACE_REF_BASE": "refs/replace",
    }
    missing_environment_value = object()
    previous_values = {
        key: os.environ.get(key, missing_environment_value) for key in hostile_values
    }
    os.environ.update(hostile_values)
    try:
        canonical_payload = b"canonical-object-store\n"
        canonical_object = module._git_io(
            str(repo), "hash-object", "-w", "--stdin", payload=canonical_payload
        )
        assert canonical_object.returncode == 0
        canonical_oid = canonical_object.stdout.decode().strip()
        canonical_object_path = repo / ".git/objects" / canonical_oid[:2] / canonical_oid[2:]
        assert canonical_object_path.is_file()
        assert not (
            alternate_objects / canonical_oid[:2] / canonical_oid[2:]
        ).exists()
        assert module._git(str(repo), "write-tree").stdout == (
            original_tree.encode("ascii") + b"\n"
        )
        assert module._git(
            str(repo), "config", "--global", "--get", "hostile.marker"
        ).returncode != 0
        ref_update = module._git_io(
            str(repo),
            "update-ref",
            "refs/heads/environment-proof",
            original_commit,
            "0" * 40,
        )
        assert ref_update.returncode == 0
    finally:
        for key, previous in previous_values.items():
            if previous is missing_environment_value:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
    assert git(
        repo, "rev-parse", "refs/heads/environment-proof"
    ).stdout.decode().strip() == original_commit
    assert git(
        hostile_repository,
        "show-ref",
        "--verify",
        "refs/heads/environment-proof",
        check=False,
    ).returncode != 0

with scratch_dir("code-fixer-partial-clone-") as temporary:
    source = pathlib.Path(temporary) / "source"
    source.mkdir()
    git(source, "init", "-q")
    git(source, "config", "user.email", "fixture@example.invalid")
    git(source, "config", "user.name", "Fixture")
    (source / "promised-a").write_bytes(b"promised-a\n")
    (source / "promised-b").write_bytes(b"promised-b\n")
    git(source, "add", "-A")
    git(source, "commit", "-qm", "test: promised blobs")
    remote = pathlib.Path(temporary) / "remote.git"
    subprocess.run(
        ["git", "clone", "--bare", "-q", str(source), str(remote)], check=True
    )
    git(remote, "config", "uploadpack.allowFilter", "true")
    partial = pathlib.Path(temporary) / "partial"
    clone = subprocess.run(
        [
            "git",
            "-c",
            "protocol.file.allow=always",
            "clone",
            "-q",
            "--filter=blob:none",
            "--no-checkout",
            remote.as_uri(),
            str(partial),
        ],
        capture_output=True,
        check=False,
    )
    assert clone.returncode == 0, clone.stderr
    assert git(
        partial, "config", "--get", "remote.origin.promisor"
    ).stdout == b"true\n"
    no_fetch_environment = os.environ.copy()
    no_fetch_environment["GIT_NO_LAZY_FETCH"] = "1"
    subprocess.run(
        ["git", "-C", str(partial), "read-tree", "HEAD"],
        env=no_fetch_environment,
        capture_output=True,
        check=True,
    )
    missing_before = subprocess.run(
        ["git", "-C", str(partial), "rev-list", "--objects", "--missing=print", "HEAD"],
        env=no_fetch_environment,
        capture_output=True,
        check=True,
    ).stdout
    assert b"?" in missing_before
    partial_index_path = pathlib.Path(module._git_index_path(str(partial)))
    partial_index = regular_snapshot(partial_index_path)
    partial_objects = git_object_files(partial)
    expect_contract_reason(
        lambda: module._index_tree_sha(str(partial)), "index_tree_unreadable"
    )
    missing_after = subprocess.run(
        ["git", "-C", str(partial), "rev-list", "--objects", "--missing=print", "HEAD"],
        env=no_fetch_environment,
        capture_output=True,
        check=True,
    ).stdout
    assert missing_after == missing_before
    assert regular_snapshot(partial_index_path) == partial_index
    assert git_object_files(partial) == partial_objects

with scratch_dir("code-fixer-sparse-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "included").mkdir()
    (repo / "included/file").write_bytes(b"included\n")
    (repo / "excluded").mkdir()
    (repo / "excluded/file").write_bytes(b"excluded\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "test: sparse base")
    sparse_result = git(repo, "sparse-checkout", "init", "--cone", "--sparse-index", check=False)
    if sparse_result.returncode == 0:
        git(repo, "sparse-checkout", "set", "included")
        sparse_index = pathlib.Path(module._git_index_path(str(repo)))
        sparse_before = regular_snapshot(sparse_index)
        sparse_rows = git(repo, "ls-files", "--sparse", "--stage", "-z").stdout
        assert b"040000 " in sparse_rows
        expect_contract_reason(
            lambda: module._index_tree_sha(str(repo)), "index_tree_unreadable"
        )
        assert regular_snapshot(sparse_index) == sparse_before
        assert not tuple(sparse_index.parent.glob(".code-fixer-private-git-*"))

with scratch_dir("code-fixer-sha256-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    sha256_init = subprocess.run(
        ["git", "init", "-q", "--object-format=sha256", str(repo)],
        capture_output=True,
        check=False,
    )
    if sha256_init.returncode == 0:
        git(repo, "config", "user.email", "fixture@example.invalid")
        git(repo, "config", "user.name", "Fixture")
        (repo / "tracked").write_bytes(b"sha256\n")
        git(repo, "add", "--", "tracked")
        git(repo, "commit", "-qm", "test: sha256 refusal")
        sha256_index = pathlib.Path(
            git(repo, "rev-parse", "--path-format=absolute", "--git-path", "index")
            .stdout.decode()
            .strip()
        )
        sha256_before = regular_snapshot(sha256_index)
        expect_contract_reason(
            lambda: module._index_tree_sha(str(repo)), "index_tree_unreadable"
        )
        assert regular_snapshot(sha256_index) == sha256_before
        assert not tuple(sha256_index.parent.glob(".code-fixer-private-git-*"))

with scratch_dir("code-fixer-standalone-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    git(repo, "config", "diff.autoRefreshIndex", "true")
    names = (
        "applied-staged", "applied-unstaged", "applied-both",
        "keep-staged", "keep-unstaged", "keep-both",
    )
    for name in names:
        (repo / name).write_text(f"{name}-H0\n", encoding="utf-8")
    git(repo, "add", "--", *names)
    git(repo, "commit", "-qm", "test: standalone base")
    parent = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "applied-staged").write_text("A1\n", encoding="utf-8")
    git(repo, "add", "--", "applied-staged")
    (repo / "applied-unstaged").write_text("B1\n", encoding="utf-8")
    (repo / "applied-both").write_text("C1\n", encoding="utf-8")
    git(repo, "add", "--", "applied-both")
    (repo / "applied-both").write_text("C2\n", encoding="utf-8")
    (repo / "keep-staged").write_text("D1\n", encoding="utf-8")
    git(repo, "add", "--", "keep-staged")
    (repo / "keep-unstaged").write_text("E1\n", encoding="utf-8")
    (repo / "keep-both").write_text("F1\n", encoding="utf-8")
    git(repo, "add", "--", "keep-both")
    (repo / "keep-both").write_text("F2\n", encoding="utf-8")
    (repo / "untracked.txt").write_text("U0\n", encoding="utf-8")
    keep_paths = ("keep-staged", "keep-unstaged", "keep-both")
    keep_cached = git(repo, "diff", "--cached", "--binary", "--", *keep_paths).stdout
    keep_worktree = git(repo, "diff", "--binary", "--", *keep_paths).stdout
    keep_bytes = {name: (repo / name).read_bytes() for name in keep_paths}
    git(repo, "config", "splitIndex.maxPercentChange", "0")
    git(repo, "config", "splitIndex.sharedIndexExpire", "never")
    split_index_result = git(repo, "update-index", "--split-index", check=False)
    split_index_supported = split_index_result.returncode == 0
    if not split_index_supported:
        assert b"split-index" in split_index_result.stderr
        assert b"unknown option" in split_index_result.stderr
    evidence = repo / ".uberdev/research/20260728-010206-abcdef0"
    evidence.mkdir(parents=True)
    diff_path = evidence / "pr-diff.md"
    diff_path.write_bytes(
        b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'
    )
    snapshot_path = evidence / "standalone-snapshot.json"
    snapshot_path.write_bytes(b"")
    snapshot_receipt = module.capture_standalone_snapshot(
        working_dir=str(repo), evidence_dir=str(evidence),
        diff_path=str(diff_path), snapshot_path=str(snapshot_path),
    )
    assert snapshot_receipt["head_sha"] == parent
    assert snapshot_receipt["target_eligible_paths"] == sorted(names)
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    raw_index_path = pathlib.Path(snapshot["index_path"])
    git_dir = raw_index_path.parent
    shared_indexes_before_observation = {
        path.name: regular_snapshot(path) for path in git_dir.glob("sharedindex.*")
    }
    if split_index_supported:
        assert shared_indexes_before_observation
    keep_staged_path = repo / "keep-staged"
    keep_staged_stat = keep_staged_path.stat()
    os.utime(
        keep_staged_path,
        ns=(keep_staged_stat.st_atime_ns, keep_staged_stat.st_mtime_ns + 2_000_000_000),
    )
    assert keep_staged_path.read_bytes() == git(repo, "show", ":keep-staged").stdout
    raw_index_baseline = raw_index_path.read_bytes()
    observed_after_mtime_touch = module._capture_repo_state(str(repo), str(evidence))
    logical_state_keys = (
        "head_sha", "head_tree_sha", "index_tree_sha", "target_eligible_paths",
        "tracked", "untracked",
    )
    assert {
        key: observed_after_mtime_touch[key] for key in logical_state_keys
    } == {
        key: snapshot[key] for key in logical_state_keys
    }
    assert raw_index_path.read_bytes() == raw_index_baseline
    assert {
        path.name: path.read_bytes() for path in git_dir.glob("sharedindex.*")
    } == {
        name: shared[0]
        for name, shared in shared_indexes_before_observation.items()
    }
    keep_staged_index_oid = git(
        repo, "rev-parse", ":keep-staged"
    ).stdout.decode().strip()
    git(
        repo,
        "update-index",
        "--add",
        "--cacheinfo",
        "100644",
        keep_staged_index_oid,
        "keep-staged",
    )
    invalid_cache_index = raw_index_path.read_bytes()
    invalid_cache_shared_indexes = {
        path.name: regular_snapshot(path) for path in git_dir.glob("sharedindex.*")
    }
    assert invalid_cache_index != raw_index_baseline
    git(repo, "config", "splitIndex.sharedIndexExpire", "now")
    assert module._index_tree_sha(str(repo)) == snapshot["index_tree_sha"]
    assert {
        path.name: regular_snapshot(path) for path in git_dir.glob("sharedindex.*")
    } == invalid_cache_shared_indexes
    git(repo, "config", "splitIndex.sharedIndexExpire", "never")
    observed_with_invalid_cache_tree = module._capture_repo_state(
        str(repo), str(evidence)
    )
    assert {
        key: observed_with_invalid_cache_tree[key] for key in logical_state_keys
    } == {
        key: snapshot[key] for key in logical_state_keys
    }
    assert raw_index_path.read_bytes() == invalid_cache_index
    assert {
        path.name: path.read_bytes() for path in git_dir.glob("sharedindex.*")
    } == {
        name: shared[0] for name, shared in invalid_cache_shared_indexes.items()
    }
    assert not tuple(git_dir.glob(".code-fixer-index-tree-*"))
    assert not tuple(git_dir.glob(".code-fixer-private-git-*"))

    previous_ambient_index = os.environ.get("GIT_INDEX_FILE")
    os.environ["GIT_INDEX_FILE"] = str(raw_index_path)
    try:
        expect_contract_reason(
            lambda: module._index_tree_sha(str(repo)),
            "index_tree_environment_invalid",
        )
    finally:
        if previous_ambient_index is None:
            os.environ.pop("GIT_INDEX_FILE", None)
        else:
            os.environ["GIT_INDEX_FILE"] = previous_ambient_index

    original_git_io = module._git_io
    direct_write_calls = []

    def record_direct_write(repository, *arguments, **kwargs):
        direct_write_calls.append((repository, arguments, kwargs))
        return subprocess.CompletedProcess(
            ["git", *arguments], 0, stdout=(b"0" * 40) + b"\n", stderr=b""
        )

    module._git_io = record_direct_write
    try:
        resolved_real_index = module._git_index_path(str(repo))
        assert os.path.normcase(os.path.realpath(resolved_real_index)) == os.path.normcase(
            os.path.realpath(raw_index_path)
        ), (resolved_real_index, str(raw_index_path))
        expect_contract_reason(
            lambda: module._index_tree_sha(str(repo), extra_env={}),
            "index_tree_environment_invalid",
        )
        expect_contract_reason(
            lambda: module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(raw_index_path)}
            ),
            "index_tree_environment_invalid",
        )
    finally:
        module._git_io = original_git_io
    assert direct_write_calls == []

    for removed_private_api in (
        "_PrivateGitDirectory",
        "_create_private_git_directory",
        "_cleanup_private_git_directory",
        "_run_private_git",
        "_private_index_tree",
    ):
        assert not hasattr(module, removed_private_api)
    assert not tuple(git_dir.glob(".code-fixer-private-git-*"))

    fsmonitor_marker = git_dir / "fsmonitor-executed"
    fsmonitor_hook = git_dir / "fsmonitor-hook"
    fsmonitor_hook.write_text(
        f"#!/bin/sh\nprintf invoked >\"{fsmonitor_marker}\"\nexit 0\n",
        encoding="utf-8",
    )
    fsmonitor_hook.chmod(0o755)
    git(repo, "config", "core.fsmonitor", str(fsmonitor_hook))
    git(repo, "update-index", "--fsmonitor")
    fsmonitor_marker.unlink(missing_ok=True)
    fsmonitor_index = regular_snapshot(raw_index_path)
    assert module._index_tree_sha(str(repo)) == snapshot["index_tree_sha"]
    assert not fsmonitor_marker.exists()
    assert regular_snapshot(raw_index_path) == fsmonitor_index
    git(repo, "config", "--unset", "core.fsmonitor")
    git(repo, "update-index", "--no-fsmonitor")

    alternate_index = git_dir / "alternate-index-hardlink"
    os.link(raw_index_path, alternate_index)
    try:
        expect_contract_reason(
            lambda: module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(alternate_index)}
            ),
            "index_tree_environment_invalid",
        )
    finally:
        alternate_index.unlink()

    alias_index = git_dir / "alternate-index-alias"
    alias_index.symlink_to(raw_index_path.name)
    try:
        expect_contract_reason(
            lambda: module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(alias_index)}
            ),
            "index_tree_environment_invalid",
        )
    finally:
        alias_index.unlink()

    rebound_index = git_dir / "alternate-index-rebound"
    rebound_index.write_bytes(raw_index_path.read_bytes())
    rebound_replacement = git_dir / "alternate-index-replacement"
    rebound_replacement.write_bytes(raw_index_path.read_bytes())
    original_capture_regular = module._capture_regular
    rebound_injected = {"done": False}

    def replace_alternate_after_capture(path, minimum, maximum):
        captured = original_capture_regular(path, minimum, maximum)
        if pathlib.Path(path) == rebound_index and not rebound_injected["done"]:
            rebound_index.unlink()
            os.replace(rebound_replacement, rebound_index)
            rebound_injected["done"] = True
        return captured

    module._capture_regular = replace_alternate_after_capture
    try:
        expect_contract_reason(
            lambda: module._index_tree_sha(
                str(repo), extra_env={"GIT_INDEX_FILE": str(rebound_index)}
            ),
            "index_tree_environment_invalid",
        )
    finally:
        module._capture_regular = original_capture_regular
        rebound_index.unlink(missing_ok=True)
        rebound_replacement.unlink(missing_ok=True)
    assert rebound_injected["done"]
    raw_index_path.write_bytes(raw_index_baseline)
    index_lock_path = pathlib.Path(f"{raw_index_path}.lock")
    assert not index_lock_path.exists()
    previous_umask = os.umask(0o777)
    try:
        (observed_with_restrictive_umask,) = module._observe_worktree_with_index_lock(
            str(repo),
            (("diff", "--name-status", "-z", "--no-renames", "--"),),
        )
    finally:
        os.umask(previous_umask)
    assert observed_with_restrictive_umask.returncode == 0
    assert not index_lock_path.exists()
    assert raw_index_path.read_bytes() == raw_index_baseline
    original_capture_regular = module._capture_regular

    def interrupt_acquisition_capture(path, minimum, maximum):
        if index_lock_path.exists():
            raise KeyboardInterrupt("injected acquisition interrupt")
        return original_capture_regular(path, minimum, maximum)

    module._capture_regular = interrupt_acquisition_capture
    try:
        try:
            module._capture_repo_state(str(repo), str(evidence))
        except KeyboardInterrupt as error:
            assert str(error) == "injected acquisition interrupt"
        else:
            raise AssertionError("acquisition KeyboardInterrupt was swallowed")
    finally:
        module._capture_regular = original_capture_regular
    assert not index_lock_path.exists(), (
        f"acquisition KeyboardInterrupt left stale lock: {index_lock_path}"
    )
    assert raw_index_path.read_bytes() == raw_index_baseline

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
            module._capture_repo_state(str(repo), str(evidence))
        except SystemExit as error:
            assert str(error) == "injected release interrupt"
        else:
            raise AssertionError("release SystemExit was swallowed")
    finally:
        module._capture_regular = original_capture_regular
    assert release_capture_calls["count"] == 2
    assert not index_lock_path.exists(), (
        f"release SystemExit left stale lock: {index_lock_path}"
    )
    assert raw_index_path.read_bytes() == raw_index_baseline

    original_run_observational_git = module._run_observational_git

    def fail_observation_diff(repository, *arguments):
        if not arguments or arguments[0] != "diff":
            return original_run_observational_git(repository, *arguments)
        return subprocess.CompletedProcess(
            ["git", *arguments], 2, stdout=b"", stderr=b"injected"
        )

    module._run_observational_git = fail_observation_diff
    try:
        expect_contract_reason(
            lambda: module._capture_repo_state(str(repo), str(evidence)),
            "git_state_unreadable",
        )
    finally:
        module._run_observational_git = original_run_observational_git
    assert not index_lock_path.exists()
    assert raw_index_path.read_bytes() == raw_index_baseline

    foreign_index_lock = b"foreign-index-lock\n"
    index_lock_path.write_bytes(foreign_index_lock)
    expect_contract_reason(
        lambda: module._capture_repo_state(str(repo), str(evidence)),
        "index_observation_lock_unavailable",
    )
    assert index_lock_path.read_bytes() == foreign_index_lock
    assert raw_index_path.read_bytes() == raw_index_baseline
    index_lock_path.unlink()

    replacement_index_lock = b"replacement-index-lock\n"
    def replace_observation_lock(repository, *arguments):
        if not arguments or arguments[0] != "diff":
            return original_run_observational_git(repository, *arguments)
        assert index_lock_path.read_bytes() == b""
        index_lock_path.unlink()
        index_lock_path.write_bytes(replacement_index_lock)
        return original_run_observational_git(repository, *arguments)

    module._run_observational_git = replace_observation_lock
    try:
        expect_contract_reason(
            lambda: module._capture_repo_state(str(repo), str(evidence)),
            "index_observation_lock_recovery_failed",
        )
    finally:
        module._run_observational_git = original_run_observational_git
    assert index_lock_path.read_bytes() == replacement_index_lock
    assert raw_index_path.read_bytes() == raw_index_baseline
    index_lock_path.unlink()
    assert not index_lock_path.exists()

    original_atomic_rename_noreplace = module.atomic_rename_noreplace
    between_quarantine_payload = b"between-quarantine-and-verification\n"
    preserved_owned_lock = git_dir / "preserved-owned-observation-lock"
    quarantine_replaced = {"done": False}

    def replace_quarantine_before_verification(source, destination, **kwargs):
        result = original_atomic_rename_noreplace(source, destination, **kwargs)
        if (
            not quarantine_replaced["done"]
            and os.path.abspath(os.fspath(source)) == os.path.abspath(index_lock_path)
            and ".code-fixer-index-lock-retired-" in os.path.basename(destination)
        ):
            os.replace(destination, preserved_owned_lock)
            pathlib.Path(destination).write_bytes(between_quarantine_payload)
            quarantine_replaced["done"] = True
        return result

    module.atomic_rename_noreplace = replace_quarantine_before_verification
    try:
        expect_contract_reason(
            lambda: module._capture_repo_state(str(repo), str(evidence)),
            "index_observation_lock_recovery_failed",
        )
    finally:
        module.atomic_rename_noreplace = original_atomic_rename_noreplace
    assert quarantine_replaced["done"]
    assert preserved_owned_lock.read_bytes() == b""
    assert index_lock_path.read_bytes() == between_quarantine_payload
    preserved_owned_lock.unlink()
    index_lock_path.unlink()

    after_verification_payload = b"after-quarantine-verification\n"
    after_verification_source = git_dir / "after-verification-source"
    observed_quarantine = {"path": None, "replaced": False}
    original_close = module.os.close

    def capture_quarantine(source, destination, **kwargs):
        result = original_atomic_rename_noreplace(source, destination, **kwargs)
        if (
            os.path.abspath(os.fspath(source)) == os.path.abspath(index_lock_path)
            and ".code-fixer-index-lock-retired-" in os.path.basename(destination)
            and observed_quarantine["path"] is None
        ):
            observed_quarantine["path"] = pathlib.Path(destination)
        return result

    def replace_quarantine_after_verification(descriptor):
        quarantine = observed_quarantine["path"]
        if quarantine is not None and not observed_quarantine["replaced"]:
            try:
                held = os.fstat(descriptor)
                visible = os.lstat(quarantine)
            except OSError:
                pass
            else:
                if (held.st_dev, held.st_ino) == (visible.st_dev, visible.st_ino):
                    original_close(descriptor)
                    after_verification_source.write_bytes(after_verification_payload)
                    os.replace(after_verification_source, quarantine)
                    observed_quarantine["replaced"] = True
                    return
        original_close(descriptor)

    module.atomic_rename_noreplace = capture_quarantine
    module.os.close = replace_quarantine_after_verification
    try:
        module._capture_repo_state(str(repo), str(evidence))
    finally:
        module.os.close = original_close
        module.atomic_rename_noreplace = original_atomic_rename_noreplace
    assert observed_quarantine["replaced"]
    assert observed_quarantine["path"].read_bytes() == after_verification_payload
    assert not index_lock_path.exists()

    findings = evidence / "simplify-final.md"
    findings.write_bytes(aggregate("phase2", [
        (("review_pr.simplify.reuse",), "suggestion", "applied-staged", "1", "refine A", "detail A"),
        (("review_pr.simplify.quality",), "suggestion", "applied-unstaged", "1", "refine B", "detail B"),
        (("review_pr.simplify.efficiency",), "suggestion", "applied-both", "1", "refine C", "detail C"),
    ]))
    disposition = evidence / "phase2-disposition.json"
    disposition.write_bytes(b"")
    authority_receipt = module.prepare_standalone_authority(
        edge_id="simplify.fix.phase2", policy_phase="simplify_fix",
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    )
    authority_path = pathlib.Path(authority_receipt["authority_path"])
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    (repo / "applied-staged").write_text("A2\n", encoding="utf-8")
    (repo / "applied-unstaged").write_text("B2\n", encoding="utf-8")
    (repo / "applied-both").write_text("C3\n", encoding="utf-8")
    rows = [
        {
            **finding,
            "disposition": "APPLIED",
            "behavior_tag": "preserve",
            "reason": "bounded standalone refinement",
        }
        for finding in authority["finding_keys"]
    ]
    applied_content_path = evidence / "standalone-applied-content.json"
    mismatched_index = bytearray(raw_index_baseline)
    mismatch_width = 20
    mismatched_index[12] ^= 1
    mismatched_index[-mismatch_width:] = hashlib.sha1(
        mismatched_index[:-mismatch_width]
    ).digest()
    raw_index_path.write_bytes(mismatched_index)
    assert raw_index_path.read_bytes() != raw_index_baseline
    assert raw_index_path.stat().st_size == len(raw_index_baseline)
    expect_contract_reason(lambda: module.publish_disposition(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        candidate=json.dumps(candidate(authority, rows)).encode(),
    ), "standalone_index_mismatch")
    assert disposition.read_bytes() == b""
    assert not applied_content_path.exists()
    raw_index_path.write_bytes(raw_index_baseline)
    assert raw_index_path.read_bytes() == raw_index_baseline
    original_secure_publish = module.secure_publish_captured
    publication_calls = {"count": 0}

    def fail_applied_content(path, payload):
        publication_calls["count"] += 1
        if publication_calls["count"] == 2:
            module.secure_publish_captured = original_secure_publish
            module.fail("injected_applied_content_publication_failure")
        return original_secure_publish(path, payload)

    module.secure_publish_captured = fail_applied_content
    try:
        expect_contract_reason(lambda: module.publish_disposition(
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(disposition),
            candidate=json.dumps(candidate(authority, rows)).encode(),
        ), "injected_applied_content_publication_failure")
    finally:
        module.secure_publish_captured = original_secure_publish
    assert publication_calls["count"] == 2
    assert disposition.read_bytes() == b""
    assert not applied_content_path.exists()
    assert raw_index_path.read_bytes() == raw_index_baseline

    replacement = b"foreign-disposition-replacement\n"
    publication_calls["count"] = 0

    def replace_disposition_then_fail_content(path, payload):
        publication_calls["count"] += 1
        if publication_calls["count"] == 2:
            disposition.unlink()
            disposition.write_bytes(replacement)
            module.secure_publish_captured = original_secure_publish
            module.fail("injected_applied_content_publication_failure")
        return original_secure_publish(path, payload)

    module.secure_publish_captured = replace_disposition_then_fail_content
    try:
        expect_contract_reason(lambda: module.publish_disposition(
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(disposition),
            candidate=json.dumps(candidate(authority, rows)).encode(),
        ), "disposition_transaction_recovery_failed")
    finally:
        module.secure_publish_captured = original_secure_publish
    assert publication_calls["count"] == 2
    assert disposition.read_bytes() == replacement
    assert not applied_content_path.exists()
    assert raw_index_path.read_bytes() == raw_index_baseline
    disposition.unlink()
    disposition.write_bytes(b"")
    published = module.publish_disposition(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        candidate=json.dumps(candidate(authority, rows)).encode(),
    )
    assert set(published) == {
        "disposition_path", "disposition_sha256", "applied_paths",
        "applied_content_path", "applied_content_sha256",
    }
    (repo / "applied-staged").write_text("A3-after-publication\n", encoding="utf-8")
    expect_contract_failure(lambda: module.commit_standalone(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        applied_content_path=published["applied_content_path"],
        applied_content_sha256=published["applied_content_sha256"],
        working_dir=str(repo),
    ))
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    (repo / "applied-staged").write_text("A2\n", encoding="utf-8")
    raw_index_before = raw_index_path.read_bytes()
    hook_dir = evidence / "hooks"
    hook_dir.mkdir()
    git(repo, "config", "core.hooksPath", str(hook_dir))
    pre_commit = hook_dir / "pre-commit"
    pre_commit.write_text(
        "#!/bin/sh\ngit update-index --force-remove -- applied-staged\n",
        encoding="utf-8",
    )
    pre_commit.chmod(0o755)
    expect_contract_failure(lambda: module.commit_standalone(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        applied_content_path=published["applied_content_path"],
        applied_content_sha256=published["applied_content_sha256"],
        working_dir=str(repo),
    ))
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    assert raw_index_path.read_bytes() == raw_index_before
    pre_commit.unlink()
    pre_commit.write_text(
        "#!/bin/sh\n"
        "real_index=\"$(git rev-parse --absolute-git-dir)/index\"\n"
        "GIT_INDEX_FILE=\"$real_index\" git update-index --force-remove -- applied-staged\n",
        encoding="utf-8",
    )
    pre_commit.chmod(0o755)
    expect_contract_failure(lambda: module.commit_standalone(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        applied_content_path=published["applied_content_path"],
        applied_content_sha256=published["applied_content_sha256"],
        working_dir=str(repo),
    ))
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    assert raw_index_path.read_bytes() == raw_index_before
    pre_commit.unlink()
    commit_msg = hook_dir / "commit-msg"
    commit_msg.write_text(
        "#!/bin/sh\nprintf 'mutated by hook\\n' >\"$1\"\n",
        encoding="utf-8",
    )
    commit_msg.chmod(0o755)
    expect_contract_failure(lambda: module.commit_standalone(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        applied_content_path=published["applied_content_path"],
        applied_content_sha256=published["applied_content_sha256"],
        working_dir=str(repo),
    ))
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    assert raw_index_path.read_bytes() == raw_index_before
    commit_msg.unlink()
    hook_order = evidence / "hook-order"
    for hook_name in ("pre-commit", "prepare-commit-msg", "commit-msg"):
        hook = hook_dir / hook_name
        hook.write_text(
            "#!/bin/sh\n"
            + ("[ -n \"$GIT_INDEX_FILE\" ] || exit 9\n" if hook_name == "pre-commit" else "")
            + f"printf '%s\\n' '{hook_name}' >>'{hook_order}'\n",
            encoding="utf-8",
        )
        hook.chmod(0o755)
    original_cas = module._cas_update_head
    module._cas_update_head = lambda *_args, **_kwargs: False
    try:
        expect_contract_failure(lambda: module.commit_standalone(
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(disposition),
            disposition_sha256=published["disposition_sha256"],
            applied_content_path=published["applied_content_path"],
            applied_content_sha256=published["applied_content_sha256"],
            working_dir=str(repo),
        ))
    finally:
        module._cas_update_head = original_cas
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    assert raw_index_path.read_bytes() == raw_index_before
    assert not (evidence / "standalone-commit-transaction.json").exists()
    assert not (evidence / "standalone-index-backup.bin").exists()
    hook_order.unlink()

    def interrupt_before_cas(*_args, **_kwargs):
        raise KeyboardInterrupt("injected before CAS")
    module._cas_update_head = interrupt_before_cas
    try:
        try:
            module.commit_standalone(
                authority_path=str(authority_path),
                authority_sha256=authority_receipt["authority_sha256"],
                disposition_path=str(disposition),
                disposition_sha256=published["disposition_sha256"],
                applied_content_path=published["applied_content_path"],
                applied_content_sha256=published["applied_content_sha256"],
                working_dir=str(repo),
            )
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("pre-CAS interruption was not injected")
    finally:
        module._cas_update_head = original_cas
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == parent
    assert raw_index_path.read_bytes() != raw_index_before
    assert (evidence / "standalone-commit-transaction.json").is_file()
    assert (evidence / "standalone-index-backup.bin").is_file()

    original_post_cas = module._validate_standalone_commit_state
    def interrupt_after_cas(*_args, **_kwargs):
        raise KeyboardInterrupt("injected after CAS")
    module._validate_standalone_commit_state = interrupt_after_cas
    try:
        try:
            module.commit_standalone(
                authority_path=str(authority_path),
                authority_sha256=authority_receipt["authority_sha256"],
                disposition_path=str(disposition),
                disposition_sha256=published["disposition_sha256"],
                applied_content_path=published["applied_content_path"],
                applied_content_sha256=published["applied_content_sha256"],
                working_dir=str(repo),
            )
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("post-CAS interruption was not injected")
    finally:
        module._validate_standalone_commit_state = original_post_cas
    interrupted_tip = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert interrupted_tip != parent
    assert (evidence / "standalone-commit-transaction.json").is_file()
    assert (evidence / "standalone-index-backup.bin").is_file()

    committed = module.commit_standalone(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        applied_content_path=published["applied_content_path"],
        applied_content_sha256=published["applied_content_sha256"],
        working_dir=str(repo),
    )
    tip = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert hook_order.read_text(encoding="utf-8").splitlines() == [
        "pre-commit", "prepare-commit-msg", "commit-msg",
        "pre-commit", "prepare-commit-msg", "commit-msg",
    ]
    assert not (evidence / "standalone-commit-transaction.json").exists()
    assert not (evidence / "standalone-index-backup.bin").exists()
    assert committed["parent_sha"] == parent and committed["commit_sha"] == tip
    assert git(repo, "diff", "--name-only", f"{parent}..{tip}").stdout.decode().splitlines() == [
        "applied-both", "applied-staged", "applied-unstaged"
    ]
    for name, value in {
        "applied-staged": b"A2\n",
        "applied-unstaged": b"B2\n",
        "applied-both": b"C3\n",
    }.items():
        assert git(repo, "show", f"HEAD:{name}").stdout == value
        assert (repo / name).read_bytes() == value
        assert git(repo, "diff", "--quiet", "--", name).returncode == 0
        assert git(repo, "diff", "--cached", "--quiet", "--", name).returncode == 0
    assert git(repo, "diff", "--cached", "--binary", "--", *keep_paths).stdout == keep_cached
    assert git(repo, "diff", "--binary", "--", *keep_paths).stdout == keep_worktree
    assert {name: (repo / name).read_bytes() for name in keep_paths} == keep_bytes
    assert (repo / "untracked.txt").read_bytes() == b"U0\n"

    result_path = evidence / "fixer-result.md"
    result_lines = [
        "```yaml", "status: APPLIED", "phase: phase2", "commits:",
        f"  - sha: {tip}", "    type: refactor",
        "    summary: bounded authenticated refactor", "findings_disposition:",
    ]
    for row in rows:
        result_lines.extend([
            f"  - finding_index: {row['finding_index']}",
            f"    location: {row['location']}",
            f"    summary_sha256: {row['summary_sha256']}",
            f"    disposition: {row['disposition']}",
            f"    behavior_tag: {row['behavior_tag']}",
            f"    reason: {row['reason']}",
        ])
    result_lines.extend(["risks: []", "```"])
    result_path.write_text("\n".join(result_lines) + "\n", encoding="utf-8")
    status_path = evidence / "fixer-status.json"
    status_path.write_text(
        json.dumps(
            {"backend": "background", "branch": "", "state": "completed",
             "exit_code": 0, "pid": "12345",
             "process_identity": "12345|12345|12345|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
             "lease_generation": "0123456789abcdef0123456789abcdef",
             "result": str(result_path.resolve()), "workspace_mode": "caller",
             "worktree": str(repo.resolve())},
            sort_keys=True, separators=(",", ":"),
        ) + "\n",
        encoding="utf-8",
    )
    launch_receipt = json.dumps(
        {
            "schema_version": 1, "edge_id": "simplify.fix.phase2",
            "instance_id": "simplify-fix-phase2-iter01-attempt01",
            "backend": "background", "handle": "12345",
            "state": "completed", "result_file": str(result_path.resolve()),
            "status_file": str(status_path.resolve()),
        },
        sort_keys=True, separators=(",", ":"),
    ).encode()
    launch_binding = module.bind_fixer_launch_receipt(
        receipt=launch_receipt, edge_id="simplify.fix.phase2",
        instance_id="simplify-fix-phase2-iter01-attempt01",
        result_path=str(result_path.resolve()), status_path=str(status_path.resolve()),
        working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
    )
    launch_binding_bytes = json.dumps(
        launch_binding, sort_keys=True, separators=(",", ":")
    ).encode()
    terminal = module.capture_standalone_terminal(
        launch_binding=launch_binding_bytes,
        disposition_path=str(disposition),
        applied_content_path=published["applied_content_path"],
    )
    outcome = module.validate_standalone_outcome(
        launch_binding=launch_binding_bytes,
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=terminal["disposition_sha256"],
        applied_content_path=terminal["applied_content_path"],
        applied_content_sha256=terminal["applied_content_sha256"],
        status_sha256=terminal["status_sha256"],
        result_sha256=terminal["result_sha256"],
        working_dir=str(repo), head_before=parent, head_after=tip,
    )
    assert outcome["status"] == "APPLIED" and outcome["declared_tip"] == tip
    result_path.write_text(result_path.read_text() + "replaced\n", encoding="utf-8")
    expect_contract_failure(lambda: module.validate_standalone_outcome(
        launch_binding=launch_binding_bytes,
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=terminal["disposition_sha256"],
        applied_content_path=terminal["applied_content_path"],
        applied_content_sha256=terminal["applied_content_sha256"],
        status_sha256=terminal["status_sha256"],
        result_sha256=terminal["result_sha256"],
        working_dir=str(repo), head_before=parent, head_after=tip,
    ))

with scratch_dir("code-fixer-review-only-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "clean.txt").write_text("H0\n", encoding="utf-8")
    (repo / ".gitignore").write_text(
        "ignored.cfg\nnode_modules/\n", encoding="utf-8"
    )
    git(repo, "add", "--", "clean.txt", ".gitignore")
    git(repo, "commit", "-qm", "test: review-only base")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    index_before = (repo / ".git/index").read_bytes()
    (repo / "untracked.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (repo / "untracked.sh").chmod(0o644)
    (repo / "ignored.cfg").write_text("secret-local-state\n", encoding="utf-8")
    # The same hardlinked dependency tree the review-mode fixture models: the
    # standalone snapshot mints U0 through the identical scan, so it aborted
    # on the identical `artifact_not_owned_regular` before #478.
    review_only_tree = repo / "node_modules/.cache"
    review_only_tree.mkdir(parents=True)
    (review_only_tree / "package.bin").write_bytes(b"cached-package\n")
    os.link(review_only_tree / "package.bin", review_only_tree / "linked.bin")
    objects_before = git_object_files(repo)
    evidence = repo / ".uberdev/research/20260728-010206-abcdef1"
    evidence.mkdir(parents=True)
    diff_path = evidence / "pr-diff.md"
    diff_path.write_bytes(
        b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'
    )
    snapshot_path = evidence / "standalone-snapshot.json"
    snapshot_path.write_bytes(b"")
    snapshot_receipt = module.capture_standalone_snapshot(
        working_dir=str(repo), evidence_dir=str(evidence),
        diff_path=str(diff_path), snapshot_path=str(snapshot_path),
    )
    assert snapshot_receipt["target_eligible_paths"] == []
    assert git_object_files(repo) == objects_before
    snapshot_document = json.loads(snapshot_path.read_text(encoding="utf-8"))
    assert snapshot_document["index_sha256"] == hashlib.sha256(index_before).hexdigest()
    assert snapshot_document["index_size"] == len(index_before)
    assert pathlib.Path(snapshot_document["index_backup_path"]).read_bytes() == index_before
    assert snapshot_document["untracked"] == [
        {
            "git_mode": "100644",
            "kind": "regular",
            "path": "untracked.sh",
            "sha256": hashlib.sha256(b"#!/bin/sh\nexit 0\n").hexdigest(),
            "size": len(b"#!/bin/sh\nexit 0\n"),
        },
    ]
    findings = evidence / "simplify-final.md"
    findings.write_bytes(aggregate("phase2", [(
        ("review_pr.simplify.quality",), "blocker", "clean.txt", "1",
        "Review-only blocker", "The clean scoped path needs follow-up.",
    )]))
    disposition = evidence / "phase2-disposition.json"
    disposition.write_bytes(b"")
    # Ignored churn is not drift, and it is deliberately NOT restored: every
    # remaining arm of this block — including the publication at the end that
    # must SUCCEED — runs with a mutated ignored file and a vitest result cache
    # written after the mint, exactly as a fixer that ran the suite leaves
    # them. (#478)
    (repo / "ignored.cfg").write_text("mutated-secret-state\n", encoding="utf-8")
    vitest_cache = repo / "node_modules/.vite/vitest/da39a3ee5e6b4b0d"
    vitest_cache.mkdir(parents=True)
    (vitest_cache / "results.json").write_text('{"version":1}\n', encoding="utf-8")
    assert module._capture_repo_state(str(repo), str(evidence))["untracked"] == (
        snapshot_document["untracked"]
    )
    # A non-ignored untracked path is still baseline state: a mode flip on it
    # is drift, and it names the drift rather than any of the other closed
    # refusals this verb can reach.
    (repo / "untracked.sh").chmod(0o755)
    expect_contract_reason(lambda: module.publish_review_only_disposition(
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    ), "standalone_baseline_mismatch")
    (repo / "untracked.sh").chmod(0o644)
    mutated_index = bytearray(index_before)
    mutated_index[12] ^= 1
    mutated_index[-20:] = hashlib.sha1(mutated_index[:-20]).digest()
    (repo / ".git/index").write_bytes(mutated_index)
    expect_contract_failure(lambda: module.publish_review_only_disposition(
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    ))
    (repo / ".git/index").write_bytes(index_before)
    for failure_mode in ("findings", "snapshot", "state"):
        original_capture = module.capture_expected
        original_load = module._load_snapshot
        original_require = module._require_snapshot_current
        findings_calls = {"count": 0}
        snapshot_calls = {"count": 0}
        state_calls = {"count": 0}
        injected = {"done": False}

        def fail_review_only_findings(path, expected_sha256, minimum, maximum):
            if pathlib.Path(path).resolve() == findings.resolve():
                findings_calls["count"] += 1
                if failure_mode == "findings" and findings_calls["count"] == 2:
                    injected["done"] = True
                    module.fail("artifact_capture_failed")
            return original_capture(path, expected_sha256, minimum, maximum)

        def fail_review_only_snapshot(path, expected_sha256):
            snapshot_calls["count"] += 1
            if failure_mode == "snapshot" and snapshot_calls["count"] == 2:
                injected["done"] = True
                module.fail("snapshot_capture_failed")
            return original_load(path, expected_sha256)

        def fail_review_only_state(snapshot):
            state_calls["count"] += 1
            if failure_mode == "state" and state_calls["count"] == 2:
                injected["done"] = True
                module.fail("snapshot_state_drift")
            return original_require(snapshot)

        module.capture_expected = fail_review_only_findings
        module._load_snapshot = fail_review_only_snapshot
        module._require_snapshot_current = fail_review_only_state
        try:
            try:
                module.publish_review_only_disposition(
                    findings_path=str(findings), findings_sha256=digest(findings),
                    snapshot_path=str(snapshot_path),
                    snapshot_sha256=snapshot_receipt["snapshot_sha256"],
                    working_dir=str(repo), disposition_path=str(disposition),
                )
            except module.ContractFailure:
                pass
            else:
                raise AssertionError(
                    f"expected {failure_mode} recapture refusal: "
                    f"findings={findings_calls['count']} "
                    f"snapshot={snapshot_calls['count']} state={state_calls['count']}"
                )
        finally:
            module.capture_expected = original_capture
            module._load_snapshot = original_load
            module._require_snapshot_current = original_require
        assert injected["done"], failure_mode
        assert disposition.read_bytes() == b"", failure_mode
        assert not list(evidence.glob("*.attempt-*")), failure_mode
    published = module.publish_review_only_disposition(
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    )
    assert set(published) == {
        "disposition_path", "disposition_sha256", "applied_paths",
    }
    assert published["applied_paths"] == []
    document = json.loads(disposition.read_text(encoding="utf-8"))
    assert document["phase"] == "phase2"
    assert document["aggregate_sha256"] == digest(findings)
    assert document["findings_disposition"] == [{
        "finding_index": 1,
        "location": "clean.txt:1",
        "summary_sha256": hashlib.sha256(b"Review-only blocker").hexdigest(),
        "disposition": "REFUSED",
        "behavior_tag": "n/a",
        "reason": "no-eligible-baseline-path",
    }]
    findings_sha = digest(findings)
    assert module.count_phase2_deferred_blockers(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
    ) == 1
    assert run([
        "count-phase2-deferred-blockers", "--findings-path", str(findings),
        "--findings-sha256", findings_sha,
        "--disposition-path", str(disposition),
        "--disposition-sha256", published["disposition_sha256"],
    ]) == "1"
    applied_document = json.loads(disposition.read_text(encoding="utf-8"))
    applied_document["findings_disposition"][0].update({
        "disposition": "APPLIED", "behavior_tag": "preserve",
        "reason": "authenticated-test-application",
    })
    applied_disposition = evidence / "phase2-applied-disposition.json"
    applied_disposition.write_text(
        json.dumps(applied_document, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    applied_sha = hashlib.sha256(applied_disposition.read_bytes()).hexdigest()
    assert module.count_phase2_deferred_blockers(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(applied_disposition),
        disposition_sha256=applied_sha,
    ) == 0
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert (repo / ".git/index").read_bytes() == index_before
    assert git(repo, "status", "--porcelain", "--untracked-files=no").stdout == b""

with scratch_dir("code-fixer-standalone-empty-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "kept.txt").write_text("H0\n", encoding="utf-8")
    git(repo, "add", "--", "kept.txt")
    git(repo, "commit", "-qm", "test: empty aggregate base")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "kept.txt").write_text("I0\n", encoding="utf-8")
    git(repo, "add", "--", "kept.txt")
    (repo / "kept.txt").write_text("W0\n", encoding="utf-8")
    cached_before = git(repo, "diff", "--cached", "--binary").stdout
    worktree_before = git(repo, "diff", "--binary").stdout
    evidence = repo / ".uberdev/research/20260728-010207-abcdef0"
    evidence.mkdir(parents=True)
    diff_path = evidence / "pr-diff.md"
    diff_path.write_bytes(
        b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'
    )
    snapshot_path = evidence / "standalone-snapshot.json"
    snapshot_path.write_bytes(b"")
    snapshot_receipt = module.capture_standalone_snapshot(
        working_dir=str(repo), evidence_dir=str(evidence),
        diff_path=str(diff_path), snapshot_path=str(snapshot_path),
    )
    findings = evidence / "simplify-final.md"
    findings.write_bytes(phase2_empty)
    disposition = evidence / "phase2-disposition.json"
    disposition.write_bytes(b"")
    authority_receipt = module.prepare_standalone_authority(
        edge_id="simplify.fix.phase2", policy_phase="simplify_fix",
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    )
    authority_path = pathlib.Path(authority_receipt["authority_path"])
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    published = module.publish_disposition(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        candidate=json.dumps(candidate(authority, [])).encode(),
    )
    assert published["applied_paths"] == []
    validated = module.validate_staged(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
        working_dir=str(repo),
    )
    assert validated["status"] == "validated"
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert git(repo, "diff", "--cached", "--binary").stdout == cached_before
    assert git(repo, "diff", "--binary").stdout == worktree_before
    result_path = evidence / "fixer-result.md"
    result_path.write_text(
        "```yaml\nstatus: NO_FIXES_NEEDED\nphase: phase2\ncommits: []\n"
        "findings_disposition: []\nrisks: []\n```\n",
        encoding="utf-8",
    )
    status_path = evidence / "fixer-status.json"
    status_path.write_text(json.dumps({
        "backend":"background", "branch":"", "exit_code":0,
        "lease_generation":"abcdef0123456789abcdef0123456789", "pid":"23456",
        "process_identity":"23456|23456|23456|abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "result":str(result_path.resolve()), "state":"completed",
        "workspace_mode":"caller", "worktree":str(repo.resolve()),
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    launch_receipt = json.dumps(
        {
            "schema_version": 1, "edge_id": "simplify.fix.phase2",
            "instance_id": "simplify-empty-iter01-attempt01",
            "backend": "background", "handle": "23456", "state": "completed",
            "result_file": str(result_path.resolve()),
            "status_file": str(status_path.resolve()),
        },
        sort_keys=True, separators=(",", ":"),
    ).encode()
    binding = module.bind_fixer_launch_receipt(
        receipt=launch_receipt, edge_id="simplify.fix.phase2",
        instance_id="simplify-empty-iter01-attempt01",
        result_path=str(result_path.resolve()), status_path=str(status_path.resolve()),
        working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
    )
    binding_bytes = json.dumps(
        binding, sort_keys=True, separators=(",", ":")
    ).encode()
    terminal = module.capture_standalone_terminal(
        launch_binding=binding_bytes, disposition_path=str(disposition),
        applied_content_path=published["applied_content_path"],
    )
    outcome = module.validate_standalone_outcome(
        launch_binding=binding_bytes, authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=terminal["disposition_sha256"],
        applied_content_path=terminal["applied_content_path"],
        applied_content_sha256=terminal["applied_content_sha256"],
        status_sha256=terminal["status_sha256"],
        result_sha256=terminal["result_sha256"], working_dir=str(repo),
        head_before=head, head_after=head,
    )
    assert outcome["status"] == "NO_FIXES_NEEDED"
    assert outcome["declared_tip"] == "" and outcome["commit"] is None
    assert git(repo, "diff", "--cached", "--binary").stdout == cached_before
    assert git(repo, "diff", "--binary").stdout == worktree_before

with scratch_dir("code-fixer-residue-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "tracked.py").write_text("VALUE = 1\n", encoding="utf-8")
    git(repo, "add", "--", "tracked.py")
    git(repo, "commit", "-qm", "test: residue fixture")
    evidence = repo / ".uberdev/research/20260728-010205-abcdef0"
    evidence.mkdir(parents=True)
    (evidence / "allowed.json").write_text("{}\n", encoding="utf-8")
    assert module.validate_residue(
        working_dir=str(repo), evidence_dir=str(evidence)
    ) == {"status": "clean"}
    leaked_temp = evidence / ".standalone-message-leaked"
    leaked_temp.write_text("sensitive temporary bytes\n", encoding="utf-8")
    expect_contract_failure(
        lambda: module.validate_residue(
            working_dir=str(repo), evidence_dir=str(evidence)
        )
    )
    leaked_temp.unlink()
    cleanup_target = evidence / ".standalone-index-cleanup"
    cleanup_target.write_bytes(b"index bytes")
    original_unlink = module.os.unlink
    module.os.unlink = lambda path: (
        (_ for _ in ()).throw(PermissionError("injected unlink failure"))
        if pathlib.Path(path) == cleanup_target else original_unlink(path)
    )
    try:
        expect_contract_failure(
            lambda: module._cleanup_temporary_paths(str(cleanup_target))
        )
    finally:
        module.os.unlink = original_unlink
    cleanup_target.unlink()
    descriptor_path = evidence / ".standalone-message-descriptor"
    descriptor = os.open(descriptor_path, os.O_WRONLY | os.O_CREAT, 0o600)
    original_close = module.os.close
    module.os.close = lambda value: (
        (_ for _ in ()).throw(OSError("injected close failure"))
        if value == descriptor else original_close(value)
    )
    try:
        expect_contract_failure(
            lambda: module._close_temporary_descriptor(descriptor)
        )
    finally:
        module.os.close = original_close
    os.close(descriptor)
    descriptor_path.unlink()
    assert json.loads(run([
        "validate-residue", "--working-dir", str(repo),
        "--evidence-dir", str(evidence),
    ])) == {"status": "clean"}
    root_evidence_link = repo / "evidence-link"
    root_evidence_link.symlink_to(evidence, target_is_directory=True)
    expect_contract_failure(
        lambda: module.validate_residue(
            working_dir=str(repo), evidence_dir=str(evidence)
        )
    )
    root_evidence_link.unlink()
    nested_evidence_link = evidence / "tracked-link.py"
    nested_evidence_link.symlink_to(repo / "tracked.py")
    assert module.validate_residue(
        working_dir=str(repo), evidence_dir=str(evidence)
    ) == {"status": "clean"}
    (repo / "tracked.py").write_text("VALUE = 2\n", encoding="utf-8")
    expect_contract_failure(
        lambda: module.validate_residue(
            working_dir=str(repo), evidence_dir=str(evidence)
        )
    )
    git(repo, "add", "--", "tracked.py")
    expect_contract_failure(
        lambda: module.validate_residue(
            working_dir=str(repo), evidence_dir=str(evidence)
        )
    )
    git(repo, "restore", "--staged", "--worktree", "--", "tracked.py")
    (repo / "foreign.txt").write_text("foreign\n", encoding="utf-8")
    expect_contract_failure(
        lambda: module.validate_residue(
            working_dir=str(repo), evidence_dir=str(evidence)
        )
    )

with scratch_dir("code-fixer-failed-return-guard-") as temporary:
    guard_root = pathlib.Path(temporary)
    review_repo = guard_root / "review"
    review_repo.mkdir()
    git(review_repo, "init", "-q")
    git(review_repo, "config", "user.email", "fixture@example.invalid")
    git(review_repo, "config", "user.name", "Fixture")
    (review_repo / "tracked.txt").write_text("baseline\n", encoding="utf-8")
    git(review_repo, "add", "--", "tracked.txt")
    git(review_repo, "commit", "-qm", "test: failed-return review baseline")
    review_head = git(review_repo, "rev-parse", "HEAD").stdout.decode().strip()
    review_evidence = review_repo / ".uberdev" / "research" / "guard-review"
    review_evidence.mkdir(parents=True)
    (review_evidence / "terminal.json").write_text("{}\n", encoding="utf-8")
    assert module.validate_failed_return(
        working_dir=str(review_repo),
        evidence_dir=str(review_evidence),
        head_before=review_head,
    ) == {"status": "clean"}
    (review_repo / "tracked.txt").write_text("residual\n", encoding="utf-8")
    expect_contract_failure(
        lambda: module.validate_failed_return(
            working_dir=str(review_repo),
            evidence_dir=str(review_evidence),
            head_before=review_head,
        )
    )
    (review_repo / "tracked.txt").write_text("baseline\n", encoding="utf-8")
    git(review_repo, "commit", "--allow-empty", "-qm", "test: unexpected fixer tip")
    expect_contract_failure(
        lambda: module.validate_failed_return(
            working_dir=str(review_repo),
            evidence_dir=str(review_evidence),
            head_before=review_head,
        )
    )

    standalone_repo = guard_root / "standalone"
    standalone_repo.mkdir()
    git(standalone_repo, "init", "-q")
    git(standalone_repo, "config", "user.email", "fixture@example.invalid")
    git(standalone_repo, "config", "user.name", "Fixture")
    (standalone_repo / "tracked.txt").write_text("head\n", encoding="utf-8")
    git(standalone_repo, "add", "--", "tracked.txt")
    git(standalone_repo, "commit", "-qm", "test: failed-return standalone baseline")
    standalone_head = git(
        standalone_repo, "rev-parse", "HEAD"
    ).stdout.decode().strip()
    (standalone_repo / "tracked.txt").write_text("dirty-baseline\n", encoding="utf-8")
    standalone_evidence = (
        standalone_repo / ".uberdev" / "research" / "guard-standalone"
    )
    standalone_evidence.mkdir(parents=True)
    diff_path = standalone_evidence / "pr-diff.md"
    snapshot_path = standalone_evidence / "standalone-snapshot.json"
    diff_path.write_bytes(
        b'<external-untrusted-input source="pr-diff">\n'
        b'</external-untrusted-input>\n'
    )
    snapshot_path.write_bytes(b"")
    diff_seed = diff_path.read_bytes()
    index_backup_path = standalone_evidence / "standalone-index-baseline.bin"
    canonical_snapshot_path = str(snapshot_path.resolve())
    for failure_mode in ("fsync", "capture", "identity"):
        original_fsync = module._fsync_directory
        original_capture = module.capture_expected
        original_lstat = module.os.lstat
        fsync_calls = {"count": 0}
        lstat_calls = {"count": 0}
        injected = {"done": False}

        def fail_snapshot_fsync(path):
            fsync_calls["count"] += 1
            if failure_mode == "fsync" and fsync_calls["count"] == 3:
                injected["done"] = True
                module.fail("transaction_sync_failed")
            return original_fsync(path)

        def fail_snapshot_capture(path, expected_sha256, minimum, maximum):
            if (
                failure_mode == "capture"
                and str(path) == canonical_snapshot_path
                and not injected["done"]
            ):
                injected["done"] = True
                module.fail("artifact_capture_failed")
            return original_capture(path, expected_sha256, minimum, maximum)

        def fail_snapshot_identity(path):
            entry = original_lstat(path)
            if (
                failure_mode == "identity"
                and str(path) == canonical_snapshot_path
            ):
                lstat_calls["count"] += 1
                if lstat_calls["count"] == 2:
                    injected["done"] = True
                    fields = list(entry)
                    fields[1] += 1
                    return os.stat_result(fields)
            return entry

        module._fsync_directory = fail_snapshot_fsync
        module.capture_expected = fail_snapshot_capture
        module.os.lstat = fail_snapshot_identity
        try:
            try:
                module.capture_standalone_snapshot(
                    working_dir=str(standalone_repo),
                    evidence_dir=str(standalone_evidence),
                    diff_path=str(diff_path),
                    snapshot_path=str(snapshot_path),
                )
            except module.ContractFailure:
                pass
            else:
                raise AssertionError(
                    f"expected {failure_mode} snapshot refusal: "
                    f"fsync={fsync_calls['count']} lstat={lstat_calls['count']}"
                )
        finally:
            module._fsync_directory = original_fsync
            module.capture_expected = original_capture
            module.os.lstat = original_lstat
        assert injected["done"], failure_mode
        assert not index_backup_path.exists(), failure_mode
        assert diff_path.read_bytes() == diff_seed, failure_mode
        assert snapshot_path.read_bytes() == b"", failure_mode
        assert not list(standalone_evidence.glob("*.attempt-*")), failure_mode

    original_secure_publish = module.secure_publish_captured
    replacement = b"foreign-diff-replacement\n"

    def replace_diff_then_fail_snapshot(path, payload):
        if str(path) == canonical_snapshot_path:
            diff_path.unlink()
            diff_path.write_bytes(replacement)
            module.fail("injected_snapshot_publication_failure")
        return original_secure_publish(path, payload)

    module.secure_publish_captured = replace_diff_then_fail_snapshot
    try:
        expect_contract_reason(lambda: module.capture_standalone_snapshot(
            working_dir=str(standalone_repo),
            evidence_dir=str(standalone_evidence),
            diff_path=str(diff_path),
            snapshot_path=str(snapshot_path),
        ), "snapshot_transaction_recovery_failed")
    finally:
        module.secure_publish_captured = original_secure_publish
    assert diff_path.read_bytes() == replacement
    assert snapshot_path.read_bytes() == b""
    assert not index_backup_path.exists()
    diff_path.unlink()
    diff_path.write_bytes(diff_seed)
    snapshot_receipt = module.capture_standalone_snapshot(
        working_dir=str(standalone_repo),
        evidence_dir=str(standalone_evidence),
        diff_path=str(diff_path),
        snapshot_path=str(snapshot_path),
    )
    snapshot_sha = snapshot_receipt["snapshot_sha256"]
    assert module.validate_failed_return(
        working_dir=str(standalone_repo),
        evidence_dir=str(standalone_evidence),
        head_before=standalone_head,
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_sha,
    ) == {"status": "clean"}
    (standalone_repo / "tracked.txt").write_text("residual\n", encoding="utf-8")
    expect_contract_failure(
        lambda: module.validate_failed_return(
            working_dir=str(standalone_repo),
            evidence_dir=str(standalone_evidence),
            head_before=standalone_head,
            snapshot_path=str(snapshot_path),
            snapshot_sha256=snapshot_sha,
        )
    )

with scratch_dir("code-fixer-atomic-publication-") as temporary:
    publication_dir = pathlib.Path(temporary)
    artifact = publication_dir / "snapshot.json"
    artifact.write_bytes(b"seed\n")
    original_replace = module.os.replace
    observed_existing_destination = []

    def observing_replace(source, destination):
        observed_existing_destination.append(pathlib.Path(destination).exists())
        return original_replace(source, destination)

    module.os.replace = observing_replace
    try:
        published_path, published_sha = module._replace_exact_artifact(
            str(artifact), b"seed\n", b"published\n", maximum=1024
        )
    finally:
        module.os.replace = original_replace
    assert observed_existing_destination == [True]
    assert pathlib.Path(published_path).read_bytes() == b"published\n"
    assert published_sha == hashlib.sha256(b"published\n").hexdigest()

    disposition = publication_dir / "phase2-disposition.json"
    disposition.write_bytes(b"")
    _empty, empty_identity = module._capture_regular(str(disposition), 0, 0)
    observed_existing_destination.clear()
    module.os.replace = observing_replace
    try:
        module._replace_empty_exact(
            str(disposition), empty_identity, b'{"schema_version":1}\n'
        )
    finally:
        module.os.replace = original_replace
    assert observed_existing_destination == [True]
    assert disposition.read_bytes() == b'{"schema_version":1}\n'

    retained = publication_dir / "retained.json"
    retained.write_bytes(b"retained\n")

    def refusing_replace(_source, destination):
        assert pathlib.Path(destination).read_bytes() == b"retained\n"
        raise PermissionError("injected atomic replace refusal")

    module.os.replace = refusing_replace
    try:
        expect_contract_failure(
            lambda: module._replace_exact_artifact(
                str(retained), b"retained\n", b"never-visible\n", maximum=1024
            )
        )
    finally:
        module.os.replace = original_replace
    assert retained.read_bytes() == b"retained\n"
    assert not list(publication_dir.glob("*.attempt-*"))

    # Once replacement has made the new inode visible, a failed durability or
    # verification step must restore the authenticated predecessor. Otherwise
    # the reported failure wedges every retry on a non-seed artifact.
    for failure_mode in ("fsync", "capture"):
        recoverable = publication_dir / f"recoverable-{failure_mode}.json"
        recoverable.write_bytes(b"seed\n")
        original_fsync = module._fsync_directory
        original_capture = module.capture_expected
        injected = {"done": False}

        def fail_once_fsync(path):
            if failure_mode == "fsync" and not injected["done"]:
                injected["done"] = True
                module.fail("transaction_sync_failed")
            return original_fsync(path)

        def fail_once_capture(path, expected_sha256, minimum, maximum):
            if (
                failure_mode == "capture"
                and pathlib.Path(path) == recoverable
                and expected_sha256 == hashlib.sha256(b"published\n").hexdigest()
                and not injected["done"]
            ):
                injected["done"] = True
                module.fail("artifact_capture_failed")
            return original_capture(path, expected_sha256, minimum, maximum)

        module._fsync_directory = fail_once_fsync
        module.capture_expected = fail_once_capture
        try:
            expect_contract_failure(
                lambda: module._replace_exact_artifact(
                    str(recoverable), b"seed\n", b"published\n", maximum=1024
                )
            )
        finally:
            module._fsync_directory = original_fsync
            module.capture_expected = original_capture
        assert injected["done"]
        assert recoverable.read_bytes() == b"seed\n"
        assert not list(publication_dir.glob("*.attempt-*"))
        module._replace_exact_artifact(
            str(recoverable), b"seed\n", b"published\n", maximum=1024
        )
        assert recoverable.read_bytes() == b"published\n"

    for failure_mode in ("fsync", "capture"):
        recoverable = publication_dir / f"recoverable-disposition-{failure_mode}.json"
        recoverable.write_bytes(b"")
        _empty, recoverable_identity = module._capture_regular(
            str(recoverable), 0, 0
        )
        original_fsync = module._fsync_directory
        original_capture = module.capture_expected
        injected = {"done": False}
        disposition_payload = b'{"schema_version":1}\n'

        def fail_once_fsync(path):
            if failure_mode == "fsync" and not injected["done"]:
                injected["done"] = True
                module.fail("transaction_sync_failed")
            return original_fsync(path)

        def fail_once_capture(path, expected_sha256, minimum, maximum):
            if (
                failure_mode == "capture"
                and pathlib.Path(path) == recoverable
                and expected_sha256 == hashlib.sha256(disposition_payload).hexdigest()
                and not injected["done"]
            ):
                injected["done"] = True
                module.fail("artifact_capture_failed")
            return original_capture(path, expected_sha256, minimum, maximum)

        module._fsync_directory = fail_once_fsync
        module.capture_expected = fail_once_capture
        try:
            expect_contract_failure(
                lambda: module._replace_empty_exact(
                    str(recoverable), recoverable_identity, disposition_payload
                )
            )
        finally:
            module._fsync_directory = original_fsync
            module.capture_expected = original_capture
        assert injected["done"]
        assert recoverable.read_bytes() == b""
        assert not list(publication_dir.glob("*.attempt-*"))
        _empty, retry_identity = module._capture_regular(str(recoverable), 0, 0)
        module._replace_empty_exact(
            str(recoverable), retry_identity, disposition_payload
        )
        assert recoverable.read_bytes() == disposition_payload

    for failure_mode in ("fsync", "capture"):
        transaction = publication_dir / f"transaction-{failure_mode}.json"
        transaction_payload = b'{"state":"prepared"}\n'
        original_fsync = module._fsync_directory
        original_capture = module.capture_expected
        injected = {"done": False}

        def fail_once_fsync(path):
            if failure_mode == "fsync" and not injected["done"]:
                injected["done"] = True
                module.fail("transaction_sync_failed")
            return original_fsync(path)

        def fail_once_capture(path, expected_sha256, minimum, maximum):
            if (
                failure_mode == "capture"
                and pathlib.Path(path) == transaction
                and not injected["done"]
            ):
                injected["done"] = True
                module.fail("artifact_capture_failed")
            return original_capture(path, expected_sha256, minimum, maximum)

        module._fsync_directory = fail_once_fsync
        module.capture_expected = fail_once_capture
        try:
            expect_contract_failure(
                lambda: module._publish_transaction_file(
                    str(transaction), transaction_payload, 1024
                )
            )
        finally:
            module._fsync_directory = original_fsync
            module.capture_expected = original_capture
        assert injected["done"]
        assert not transaction.exists()
        assert not list(publication_dir.glob("*.attempt-*"))
        assert module._publish_transaction_file(
            str(transaction), transaction_payload, 1024
        ) == hashlib.sha256(transaction_payload).hexdigest()

    persistent_fsync = publication_dir / "persistent-fsync.json"
    persistent_fsync.write_bytes(b"seed\n")
    original_fsync = module._fsync_directory
    module._fsync_directory = lambda _path: module.fail("transaction_sync_failed")
    try:
        expect_contract_reason(
            lambda: module._replace_exact_artifact(
                str(persistent_fsync), b"seed\n", b"published\n", maximum=1024
            ),
            "artifact_recovery_failed",
        )
    finally:
        module._fsync_directory = original_fsync
    assert persistent_fsync.read_bytes() == b"seed\n"

    persistent_transaction = publication_dir / "persistent-transaction.json"
    module._fsync_directory = lambda _path: module.fail("transaction_sync_failed")
    try:
        expect_contract_reason(
            lambda: module._publish_transaction_file(
                str(persistent_transaction), b'{"state":"prepared"}\n', 1024
            ),
            "transaction_cleanup_failed",
        )
    finally:
        module._fsync_directory = original_fsync
    assert not persistent_transaction.exists()

# === P1/#381: workflow-backend child status binds on a nonce, not a PID ===
#
# A Workflow-native child is awaited in-process. It has no pid, no process
# group and no lease, so `process_identity` / `lease_generation` / `pid` cannot
# be populated. The detached triple defends against a status file written by a
# different or recycled process, or by a stale detached agent — neither of which
# can occur for an awaited call. A single-use nonce the controller mints and the
# relay agent echoes back carries the same binding.
#
# The load-bearing assertion is the NEGATIVE one: the triple must be ABSENT.
# Accepting a fabricated pid would leave the binding looking correct while
# proving nothing.
WORKFLOW_NONCE = "f" * 64

workflow_binding = {
    "backend": "workflow",
    "run_nonce": WORKFLOW_NONCE,
    "workspace_mode": "caller",
    "worktree": "/repo",
    "branch": "feat/x",
    "result_path": "/run/children/i1/result.md",
}


def workflow_status(**overrides):
    document = {
        "backend": "workflow",
        "state": "completed",
        "exit_code": 0,
        "run_nonce": WORKFLOW_NONCE,
        "workspace_mode": "caller",
        "worktree": "/repo",
        "branch": "feat/x",
        "result": "/run/children/i1/result.md",
    }
    for key, value in overrides.items():
        if value is _ABSENT:
            document.pop(key, None)
        else:
            document[key] = value
    return json.dumps(document).encode()


_ABSENT = object()

# Happy path: nonce matches, triple absent.
module._validate_bound_child_status(workflow_binding, workflow_status())

# A wrong nonce is a different run's status file.
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        workflow_binding, workflow_status(run_nonce="a" * 64)
    ),
    "child_status_invalid",
)

# A missing nonce leaves the status unbound entirely.
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        workflow_binding, workflow_status(run_nonce=_ABSENT)
    ),
    "child_status_invalid",
)

# Fabricated detached-supervision fields must be REFUSED, not tolerated.
for fabricated in (
    {"pid": 4242},
    {"process_identity": "1|1|1|" + "0" * 64},
    {"lease_generation": "0" * 32},
):
    expect_contract_reason(
        lambda f=fabricated: module._validate_bound_child_status(
            workflow_binding, workflow_status(**f)
        ),
        "child_status_invalid",
    )

# A non-terminal or failed child never binds.
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        workflow_binding, workflow_status(state="running")
    ),
    "child_status_invalid",
)
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        workflow_binding, workflow_status(exit_code=1)
    ),
    "child_status_invalid",
)

# Workspace identity is still bound.
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        workflow_binding, workflow_status(worktree="/elsewhere")
    ),
    "child_status_invalid",
)

# And the reverse guard: a DETACHED backend must not smuggle a nonce in place
# of the triple it is still required to carry.
expect_contract_reason(
    lambda: module._validate_bound_child_status(
        {**workflow_binding, "backend": "background", "handle": "9",
         "process_identity": "9|9|9|" + "0" * 64, "lease_generation": "0" * 32},
        workflow_status(backend="background"),
    ),
    "child_status_invalid",
)

# === P1/#381 part 2: the launch-binding chain must REACH the nonce validator ===
#
# The chain is producer -> loader -> validator. P1 landed only the validator, so
# the whole nonce path was dead: bind_launch_receipt requires a pid,
# process_identity and lease_generation from the launch STATUS file, and
# _load_launch_binding requires set(value) == LAUNCH_BINDING_KEYS, a set with no
# run_nonce. A workflow child has none of the three, so no binding could be
# produced and none could be re-loaded.
#
# There is also no dispatch receipt to derive from -- a Workflow() call issues
# none -- so the workflow producer takes the controller-minted nonce directly and
# is callable BEFORE dispatch, which is when the controller actually mints it.
WF_EDGE = "review_pr.fix.phase1"
WF_INSTANCE = "review-pr-run-fix-phase1-iter1-attempt01"
WF_RUN = str(publication_dir / "run")
os.makedirs(os.path.join(WF_RUN, "children", "i1"), exist_ok=True)
WF_RESULT = os.path.join(WF_RUN, "children", "i1", "result.md")
WF_STATUS = os.path.join(WF_RUN, "children", "i1", "status.json")

wf_binding = module.bind_workflow_launch(
    edge_id=WF_EDGE,
    instance_id=WF_INSTANCE,
    run_nonce=WORKFLOW_NONCE,
    result_path=WF_RESULT,
    status_path=WF_STATUS,
    working_dir=str(publication_dir),
)

# The producer must carry the nonce and must NOT invent the detached triple.
assert wf_binding["backend"] == "workflow", wf_binding
assert wf_binding["run_nonce"] == WORKFLOW_NONCE, wf_binding
assert not ({"pid", "process_identity", "lease_generation"} & set(wf_binding)), wf_binding

# The loader must accept exactly what the producer emits — this is the link that
# was missing, and a round-trip is the only honest way to assert it.
reloaded = module._load_launch_binding(module._canonical_json(wf_binding), WF_EDGE)
assert reloaded == wf_binding, reloaded

# ...and the reloaded binding must reach the validator P1 wrote.
module._validate_bound_child_status(
    reloaded,
    json.dumps({
        "backend": "workflow",
        "state": "completed",
        "exit_code": 0,
        "run_nonce": WORKFLOW_NONCE,
        "workspace_mode": reloaded["workspace_mode"],
        "worktree": reloaded["worktree"],
        "branch": reloaded["branch"],
        # The binding CANONICALIZES every path (_absolute_input resolves
        # symlinks, so /var becomes /private/var on macOS). The status must be
        # compared against the canonical form, which is why this reads the
        # binding rather than reusing the path that was passed in.
        "result": reloaded["result_path"],
    }).encode(),
)

# A nonce that is not 64 lowercase hex is not a binding token.
for bad_nonce in ("", "g" * 64, "F" * 64, "f" * 63):
    expect_contract_reason(
        lambda n=bad_nonce: module.bind_workflow_launch(
            edge_id=WF_EDGE, instance_id=WF_INSTANCE, run_nonce=n,
            result_path=WF_RESULT, status_path=WF_STATUS,
            working_dir=str(publication_dir),
        ),
        "launch_binding_invalid",
    )

# Cross-contamination in BOTH directions must be refused by the loader.
smuggled_triple = dict(wf_binding)
smuggled_triple["process_identity"] = "1|1|1|" + "0" * 64
expect_contract_reason(
    lambda: module._load_launch_binding(
        module._canonical_json(smuggled_triple), WF_EDGE),
    "launch_binding_invalid",
)

detached_with_nonce = {
    "schema_version": 1, "receipt_sha256": "0" * 64, "edge_id": WF_EDGE,
    "instance_id": WF_INSTANCE, "backend": "background", "handle": "123",
    "launch_status_sha256": "0" * 64,
    "process_identity": "1|1|1|" + "0" * 64, "lease_generation": "0" * 32,
    "result_path": WF_RESULT, "status_path": WF_STATUS,
    "workspace_mode": "caller", "worktree": str(publication_dir), "branch": "",
    "run_nonce": WORKFLOW_NONCE,
}
expect_contract_reason(
    lambda: module._load_launch_binding(
        module._canonical_json(detached_with_nonce), WF_EDGE),
    "launch_binding_invalid",
)

# The edge id is still bound.
expect_contract_reason(
    lambda: module._load_launch_binding(
        module._canonical_json(wf_binding), "review_pr.fix.phase2"),
    "launch_binding_invalid",
)

# === #381 STEP 1: the review roster can be bound, and a bound child captured ===
#
# Two gaps kept a Workflow-dispatched REVIEW stage from proving its own
# evidence, and neither was in the aggregate writers:
#
#   1. bind_workflow_launch's edge allowlist was the three FIXER edges only, so
#      no reviewer or lens child could be bound at all.
#   2. all three capture-*-terminal verbs are fixer/defer-shaped (they demand a
#      disposition and an applied-content artifact a reviewer never writes), so
#      there was no verb that could consume a reviewer child of ANY backend.

# 1. Every contributor edge the Phase-1/Phase-2 aggregates re-validate is
#    bindable, and the allowlist is still closed.
for contributor_edge in (
    module.PHASE_CONTRIBUTORS["phase1"] + module.PHASE_CONTRIBUTORS["phase2"]
):
    bound = module.bind_workflow_launch(
        edge_id=contributor_edge, instance_id="correctness-iter01",
        run_nonce=WORKFLOW_NONCE, result_path=WF_RESULT, status_path=WF_STATUS,
        working_dir=str(publication_dir),
    )
    assert bound["edge_id"] == contributor_edge, bound
    assert module._load_launch_binding(
        module._canonical_json(bound), contributor_edge) == bound, bound
for rejected_edge in ("review_pr.defer.findings", "review_pr.review.unknown", ""):
    expect_contract_reason(
        lambda e=rejected_edge: module.bind_workflow_launch(
            edge_id=e, instance_id=WF_INSTANCE, run_nonce=WORKFLOW_NONCE,
            result_path=WF_RESULT, status_path=WF_STATUS,
            working_dir=str(publication_dir),
        ),
        "launch_binding_invalid",
    )

# 2. capture_bound_child over a real reviewer child.
BC_EDGE = "review_pr.review.correctness"
BC_CHILD = os.path.join(WF_RUN, "children", "correctness-iter01")
os.makedirs(BC_CHILD, exist_ok=True)
BC_RESULT = os.path.join(BC_CHILD, "result.md")
BC_STATUS = os.path.join(BC_CHILD, "status.json")
BC_RESULT_BYTES = b"## Findings\n\nnone\n"
with open(BC_RESULT, "wb") as handle:
    handle.write(BC_RESULT_BYTES)
bc_binding = module.bind_workflow_launch(
    edge_id=BC_EDGE, instance_id="correctness-iter01", run_nonce=WORKFLOW_NONCE,
    result_path=BC_RESULT, status_path=BC_STATUS,
    working_dir=str(publication_dir),
)


def write_bound_status(**overrides):
    document = {
        "backend": "workflow", "state": "completed", "exit_code": 0,
        "run_nonce": WORKFLOW_NONCE,
        "workspace_mode": bc_binding["workspace_mode"],
        "worktree": bc_binding["worktree"], "branch": bc_binding["branch"],
        "result": bc_binding["result_path"],
    }
    document.update(overrides)
    for key, value in list(document.items()):
        if value is None:
            del document[key]
    payload = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
    with open(BC_STATUS, "wb") as status_handle:
        status_handle.write(payload)
    return payload


bc_status_bytes = write_bound_status()
captured = module.capture_bound_child(
    launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE)
# Both digests are computed by the contract from bytes IT read. No caller-supplied
# digest is accepted anywhere in this verb -- that is the whole point of it.
assert captured == {
    "edge_id": BC_EDGE,
    "instance_id": "correctness-iter01",
    "status_path": bc_binding["status_path"],
    "status_sha256": hashlib.sha256(bc_status_bytes).hexdigest(),
    "result_path": bc_binding["result_path"],
    "result_sha256": hashlib.sha256(BC_RESULT_BYTES).hexdigest(),
}, captured

# A fabricated pid must not buy an accept. This is the single most important
# negative in the whole nonce protocol: a synthetic supervision handle would
# leave every downstream equality looking correct while proving nothing.
write_bound_status(pid=4242)
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE),
    "child_status_invalid",
)
for smuggled in ({"process_identity": "1|1|1|" + "0" * 64},
                 {"lease_generation": "0" * 32}):
    write_bound_status(**smuggled)
    expect_contract_reason(
        lambda: module.capture_bound_child(
            launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE),
        "child_status_invalid",
    )

# A nonce the controller never minted binds nothing.
write_bound_status(run_nonce="b" * 64)
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE),
    "child_status_invalid",
)

# An unfinished child is not a captured child.
for unfinished in ({"state": "running"}, {"exit_code": 1}):
    write_bound_status(**unfinished)
    expect_contract_reason(
        lambda: module.capture_bound_child(
            launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE),
        "child_status_invalid",
    )

write_bound_status()
# The edge is bound: a binding minted for one reviewer cannot be replayed as
# another's evidence.
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(bc_binding),
        edge_id="review_pr.review.types"),
    "launch_binding_invalid",
)
# The verb is workflow-only. A detached binding has a supervision triple to
# check and must go through the verbs that check it.
detached_reviewer = {
    "schema_version": 1, "receipt_sha256": "0" * 64, "edge_id": BC_EDGE,
    "instance_id": "correctness-iter01", "backend": "background", "handle": "123",
    "launch_status_sha256": "0" * 64,
    "process_identity": "1|1|1|" + "0" * 64, "lease_generation": "0" * 32,
    "result_path": BC_RESULT, "status_path": BC_STATUS,
    "workspace_mode": "caller", "worktree": str(publication_dir), "branch": "",
}
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(detached_reviewer), edge_id=BC_EDGE),
    "launch_binding_invalid",
)

# --- #645: the captured result must be the one that status ATTESTS TO --------
#
# `review_fleet_bind_roster` runs in a controller fence the orchestrator
# executes ONCE PER ITERATION, while the `Workflow` dispatch that consumes its
# binding is a SEPARATE call that may be REPEATED (a resume after a transient
# agent failure). The per-child nonce is therefore identical across every
# re-dispatch of one iteration, and `childDirAbs()` keys on the iteration alone,
# so a retry writes into the SAME `children/<slug>-iter<NN>/` directory. A retry
# that published its `result.md` and then died before publishing its status
# leaves the COMPLETED attempt's `status.json` sitting on top of the DEAD
# attempt's result -- and every equality above still passes, because the status
# document carries nothing that names which result bytes it attests to.
#
# Observed live on PR #641 (run 20260820-084203-72187372fac35d0d, iteration 2):
# the `tests` lens's verdict flipped REVISIONS_REQUIRED -> APPROVE and a blocker
# became a suggestion, with the capture reporting no refusal at all.
#
# The discriminator is the WRITE ORDER the bound-child protocol mandates:
# skills/review-fleet/workflow.js `boundChildProtocol` steps 1-2 publish the
# result, step 3 publishes the status. A result strictly NEWER than the status
# attesting to it cannot come from one honest attempt. Re-measured over all 42
# children of that run: 41 healthy children have status >= result (tightest
# margin +0.005s), and the one corrupted child is the sole exception at -696.5s.
write_bound_status()
bc_status_mtime = os.stat(BC_STATUS).st_mtime_ns
BC_SUBSTITUTED_BYTES = b"## Findings\n\nAPPROVE -- no blockers\n"
with open(BC_RESULT, "wb") as handle:
    handle.write(BC_SUBSTITUTED_BYTES)
os.utime(BC_RESULT, ns=(bc_status_mtime + 696_000_000_000,) * 2)
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE),
    "child_result_rewritten_after_status",
)
# The refusal is its OWN token, not a reused `child_status_invalid`: the
# operator has to learn "this child's result was rewritten after it completed",
# which is a different investigation from "this child never bound itself".
assert (
    "child_result_rewritten_after_status"
    in inspect.getsource(module.capture_bound_child)
), "the ordering refusal must be raised inside capture_bound_child itself"

# Same-tick writes are NOT a refusal. A coarse filesystem clock can stamp both
# files identically, so the rule is "strictly newer", never "not older" -- and a
# rule that red healthy runs would be worse than the hole it closes.
os.utime(BC_RESULT, ns=(bc_status_mtime,) * 2)
assert module.capture_bound_child(
    launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE
)["result_sha256"] == hashlib.sha256(BC_SUBSTITUTED_BYTES).hexdigest()
# ...and an OLDER result is the ordinary healthy case, which the 41 measured
# children all present.
os.utime(BC_RESULT, ns=(bc_status_mtime - 8_000_000_000,) * 2)
assert module.capture_bound_child(
    launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE
)["result_sha256"] == hashlib.sha256(BC_SUBSTITUTED_BYTES).hexdigest()

# An honest re-run republishes BOTH files in protocol order and captures
# cleanly: the refusal is a statement about ORDERING, not a poisoned directory.
with open(BC_RESULT, "wb") as handle:
    handle.write(BC_RESULT_BYTES)
bc_status_bytes = write_bound_status()
assert module.capture_bound_child(
    launch_binding=module._canonical_json(bc_binding), edge_id=BC_EDGE) == {
    "edge_id": BC_EDGE,
    "instance_id": "correctness-iter01",
    "status_path": bc_binding["status_path"],
    "status_sha256": hashlib.sha256(bc_status_bytes).hexdigest(),
    "result_path": bc_binding["result_path"],
    "result_sha256": hashlib.sha256(BC_RESULT_BYTES).hexdigest(),
}

# 3. Both verbs must be REACHABLE from the CLI. A function with no subparser is
#    exactly the dead code #381 found the first time.
cli = module._parser()
for verb, argv in (
    ("bind-workflow-launch", [
        "bind-workflow-launch", "--edge-id", BC_EDGE,
        "--instance-id", "correctness-iter01", "--run-nonce", WORKFLOW_NONCE,
        "--result-path", BC_RESULT, "--status-path", BC_STATUS,
        "--working-dir", str(publication_dir)]),
    ("capture-bound-child", [
        "capture-bound-child", "--edge-id", BC_EDGE,
        "--launch-binding-json", module._canonical_json(bc_binding).decode()]),
):
    parsed = cli.parse_args(argv)
    assert parsed.command == verb, parsed

# === #655: the post-fix reviewer edge, proved on BOTH binding gates ==========
#
# `review_pr.postfix.correctness` is minted by bind_workflow_launch (which
# reads WORKFLOW_BOUND_EDGE_IDS) and consumed by capture_bound_child (which
# keys on a SEPARATE union). Two `assert edge in SET` lines cannot see the
# failure that matters here: widening only the MINT side satisfies both of them
# and still produces a binding the capture verb refuses -- after the single-use
# nonce has already been burnt, so the run cannot retry. That is the trap
# WORKFLOW_VERIFIER_EDGE_IDS' own comment was written to warn about, and the
# only proof that binds the pair is to MINT on the new edge and feed THAT
# binding to the capture verb.
#
# So every claim below is EXECUTED, and the two one-sided MUTANTS are what make
# the execution a discriminator rather than a demonstration: each patches ONE
# gate of an independently-loaded copy of the module and shows this block reds.
# Measured on the tree this change starts from (3654f0fb) the whole block reds
# at the first mint, with `launch_binding_invalid`.

POSTFIX_EDGE = "review_pr.postfix.correctness"
POSTFIX_NONCE = "b7" * 32
assert re.fullmatch(r"[0-9a-f]{64}", POSTFIX_NONCE)
assert POSTFIX_NONCE != WORKFLOW_NONCE

# 1. Its OWN single-member frozenset, folded into no other roster. Joining
#    WORKFLOW_REVIEWER_EDGE_IDS is the silent failure this separation exists to
#    prevent: that set is DERIVED from PHASE_CONTRIBUTORS, so the post-fix child
#    would become a contributor every _validate_aggregate call then demands a
#    verdict from -- a child that contributes to no aggregate at all.
assert module.WORKFLOW_POSTFIX_EDGE_IDS == frozenset((POSTFIX_EDGE,)), (
    module.WORKFLOW_POSTFIX_EDGE_IDS
)
for foreign_roster in (
    module.WORKFLOW_REVIEWER_EDGE_IDS,
    module.WORKFLOW_VERIFIER_EDGE_IDS,
    module.WORKFLOW_FIXER_EDGE_IDS,
    module.WORKFLOW_PERSISTENCE_EDGE_IDS,
    module.WORKFLOW_CI_EDGE_IDS,
):
    assert POSTFIX_EDGE not in foreign_roster, foreign_roster
# The mint side as a SET claim. It is the weak half deliberately: step 2 is the
# execution of it, and the mutants below prove the set claim alone is not what
# is carrying this block.
assert module.WORKFLOW_POSTFIX_EDGE_IDS <= module.WORKFLOW_BOUND_EDGE_IDS


def load_contract_copy(name):
    """A second, independently-loaded copy of the module under test.

    Registering in sys.modules BEFORE exec_module is load-bearing, not
    housekeeping: the module defines frozen dataclasses, and
    `dataclasses._is_type` resolves `cls.__module__` through sys.modules, so
    omitting it kills the import inside @dataclass -- nowhere this block could
    interpret, and on 3.14 it is an AttributeError rather than an ImportError.
    Mirrors the registration the suite header already performs for `module`.
    """
    copy_spec = importlib.util.spec_from_file_location(name, helper_path)
    assert copy_spec is not None and copy_spec.loader is not None
    copy_module = importlib.util.module_from_spec(copy_spec)
    sys.modules[copy_spec.name] = copy_module
    copy_spec.loader.exec_module(copy_module)
    return copy_module


with scratch_dir("code-fixer-postfix-") as temporary:
    postfix_child = os.path.join(
        temporary, "children", "postfix-correctness-phase1-iter01")
    os.makedirs(postfix_child)
    POSTFIX_RESULT = os.path.join(postfix_child, "result.md")
    POSTFIX_STATUS = os.path.join(postfix_child, "status.json")
    POSTFIX_RESULT_BYTES = b"## Findings\n\nnone\n"
    with open(POSTFIX_RESULT, "wb") as handle:
        handle.write(POSTFIX_RESULT_BYTES)

    def postfix_mint(active, edge_id=POSTFIX_EDGE):
        return active.bind_workflow_launch(
            edge_id=edge_id,
            instance_id="postfix-correctness-phase1-iter01",
            run_nonce=POSTFIX_NONCE, result_path=POSTFIX_RESULT,
            status_path=POSTFIX_STATUS, working_dir=temporary,
        )

    def postfix_publish_status(binding):
        # The result is already on disk, so the status is published SECOND --
        # the write order capture_bound_child enforces (#645). Nothing in the
        # document names the edge, which is why one status file serves every
        # roster edge below.
        document = {
            "backend": "workflow", "state": "completed", "exit_code": 0,
            "run_nonce": POSTFIX_NONCE,
            "workspace_mode": binding["workspace_mode"],
            "worktree": binding["worktree"], "branch": binding["branch"],
            "result": binding["result_path"],
        }
        payload = json.dumps(
            document, sort_keys=True, separators=(",", ":")).encode()
        with open(POSTFIX_STATUS, "wb") as status_handle:
            status_handle.write(payload)
        return payload

    def postfix_expected_capture(binding, status_bytes):
        # The two paths come from the BINDING, not from the strings passed in:
        # the mint canonicalises them, and a scratch tree under $TMPDIR is
        # exactly where that matters (/var -> /private/var on macOS). Both
        # digests are recomputed here from the bytes this test wrote, so the
        # capture is compared against evidence rather than against itself.
        return {
            "edge_id": binding["edge_id"],
            "instance_id": "postfix-correctness-phase1-iter01",
            "status_path": binding["status_path"],
            "status_sha256": hashlib.sha256(status_bytes).hexdigest(),
            "result_path": binding["result_path"],
            "result_sha256": hashlib.sha256(POSTFIX_RESULT_BYTES).hexdigest(),
        }

    # 2. THE PAIR PROOF: mint on the new edge, then capture THAT SAME binding.
    postfix_binding = postfix_mint(module)
    assert postfix_binding["edge_id"] == POSTFIX_EDGE, postfix_binding
    postfix_status_bytes = postfix_publish_status(postfix_binding)
    postfix_captured = module.capture_bound_child(
        launch_binding=module._canonical_json(postfix_binding),
        edge_id=POSTFIX_EDGE)
    assert postfix_captured == postfix_expected_capture(
        postfix_binding, postfix_status_bytes), postfix_captured

    # 3. MUTANT A -- THE MINT-ONLY TREE, which is the trap itself.
    #    Narrowing WORKFLOW_POSTFIX_EDGE_IDS on a fresh copy narrows only the
    #    CAPTURE gate, because WORKFLOW_BOUND_EDGE_IDS is a union computed at
    #    import time and therefore already holds the edge. That is exactly the
    #    tree where somebody widened the mint and forgot the capture.
    postfix_mint_only = load_contract_copy("code_fixer_contract_655_mint_only")
    postfix_mint_only.WORKFLOW_POSTFIX_EDGE_IDS = frozenset()
    assert POSTFIX_EDGE in postfix_mint_only.WORKFLOW_BOUND_EDGE_IDS, (
        "mutant A no longer isolates the capture gate: WORKFLOW_BOUND_EDGE_IDS "
        "has stopped being an import-time snapshot, so this row can no longer "
        "tell the two gates apart. Rebuild the mutant, do not relax the row."
    )
    postfix_mutant_binding = postfix_mint(postfix_mint_only)
    assert postfix_mutant_binding == postfix_binding, postfix_mutant_binding
    try:
        # NOT expect_contract_reason: a separately-loaded copy raises its OWN
        # ContractFailure class, which `module.ContractFailure` does not catch.
        postfix_mint_only.capture_bound_child(
            launch_binding=postfix_mint_only._canonical_json(
                postfix_mutant_binding),
            edge_id=POSTFIX_EDGE)
    except postfix_mint_only.ContractFailure as error:
        assert str(error) == "bound_child_edge_unsupported", error
    else:
        raise AssertionError(
            "the mint-only mutant was NOT detected: this block would pass on a "
            "tree where only WORKFLOW_BOUND_EDGE_IDS was widened, which is the "
            "exact failure it exists to catch"
        )

    # 4. MUTANT B -- the capture-only tree. Narrowing the mint snapshot leaves
    #    the capture gate wide, and the refusal moves to the mint. Both
    #    assertions matter: the second attributes the refusal to the mint gate
    #    and to nothing else.
    postfix_capture_only = load_contract_copy(
        "code_fixer_contract_655_capture_only")
    postfix_capture_only.WORKFLOW_BOUND_EDGE_IDS = (
        postfix_capture_only.WORKFLOW_BOUND_EDGE_IDS
        - postfix_capture_only.WORKFLOW_POSTFIX_EDGE_IDS
    )
    assert POSTFIX_EDGE in postfix_capture_only.WORKFLOW_POSTFIX_EDGE_IDS
    try:
        postfix_mint(postfix_capture_only)
    except postfix_capture_only.ContractFailure as error:
        assert str(error) == "launch_binding_invalid", error
    else:
        raise AssertionError(
            "the capture-only mutant was NOT detected: this block would pass "
            "on a tree where the mint gate never learned the edge"
        )
    assert postfix_capture_only.capture_bound_child(
        launch_binding=postfix_capture_only._canonical_json(postfix_binding),
        edge_id=POSTFIX_EDGE) == postfix_captured

    # 5. The pair invariant over the WHOLE mintable roster, EXECUTED rather
    #    than re-spelled. Re-typing `REVIEWER | VERIFIER | POSTFIX` into an
    #    assertion here would be a copy of the capture gate, and a copy passes
    #    on mutant A above. Minting and capturing every edge cannot: an
    #    eleventh edge widened on one side only reds here even if nobody writes
    #    an edge-specific row for it.
    postfix_roster = sorted(
        module.WORKFLOW_BOUND_EDGE_IDS - module.WORKFLOW_FIXER_EDGE_IDS)
    assert POSTFIX_EDGE in postfix_roster, postfix_roster
    for roster_edge in postfix_roster:
        roster_binding = postfix_mint(module, edge_id=roster_edge)
        roster_status_bytes = postfix_publish_status(roster_binding)
        assert module.capture_bound_child(
            launch_binding=module._canonical_json(roster_binding),
            edge_id=roster_edge
        ) == postfix_expected_capture(roster_binding, roster_status_bytes), roster_edge
    # ...and the fixer deny-list still bites, driven on a REAL binding rather
    # than on the edge string alone. `capture_bound_child:8281` is a DENY list,
    # not a third gate: a postfix edge must not be added to it.
    for denied_edge in sorted(module.WORKFLOW_FIXER_EDGE_IDS):
        expect_contract_reason(
            lambda e=denied_edge: module.capture_bound_child(
                launch_binding=module._canonical_json(postfix_binding),
                edge_id=e),
            "bound_child_edge_unsupported",
        )

# 6. The machinery this change must NOT have moved.
#    The second line is the one that catches a future PHASE_CONTRIBUTORS
#    ["postfix"]: the reviewer roster is DERIVED from the contributor table, so
#    adding a third key there silently enlists the post-fix child as an
#    aggregate contributor.
assert set(module.PHASE_CONTRIBUTORS) == {"phase1", "phase2"}, (
    module.PHASE_CONTRIBUTORS
)
assert module.WORKFLOW_REVIEWER_EDGE_IDS == frozenset(
    module.PHASE_CONTRIBUTORS["phase1"] + module.PHASE_CONTRIBUTORS["phase2"]
), module.WORKFLOW_REVIEWER_EDGE_IDS
assert POSTFIX_EDGE not in module.WORKFLOW_REVIEWER_EDGE_IDS
assert not (module.WORKFLOW_CI_EDGE_IDS & module.WORKFLOW_BOUND_EDGE_IDS)

# 7. The two predicates the design forbids widening, EXECUTED over their own
#    domains. Both range over `finding x disposition`; the post-fix pass ranges
#    over `git diff BEFORE..AFTER`, so it is an ADDED path, not a widened
#    predicate -- and transcribing either function's source into an assertion
#    would prove only that somebody copied it correctly.
POSTFIX_ELIGIBILITY = (
    ("blocker", "SKIPPED", True),
    ("blocker", "REFUSED", True),
    ("blocker", "APPLIED", False),
    ("suggestion", "SKIPPED", False),
    ("suggestion", "APPLIED", False),
)
assert module._eligible_verification_rows(
    {"findings": [
        {"severity": severity} for severity, _, _ in POSTFIX_ELIGIBILITY]},
    {"findings_disposition": [
        {"disposition": disposition}
        for _, disposition, _ in POSTFIX_ELIGIBILITY]},
    tuple(range(len(POSTFIX_ELIGIBILITY))),
) == [
    (index, {"severity": row[0]})
    for index, row in enumerate(POSTFIX_ELIGIBILITY) if row[2]
], "the verification roster is no longer exactly blocker-and-not-APPLIED"

POSTFIX_AUTHORITY = {
    "phase": "phase1",
    "findings_sha256": "0" * 64,
    "finding_keys": [
        {"finding_index": 1, "location": "src/a.py:1",
         "summary_sha256": "1" * 64},
    ],
}


def postfix_disposition_document(disposition, behavior_tag):
    return {
        "schema_version": 1,
        "phase": "phase1",
        "aggregate_sha256": "0" * 64,
        "findings_disposition": [{
            "finding_index": 1, "location": "src/a.py:1",
            "summary_sha256": "1" * 64, "disposition": disposition,
            "behavior_tag": behavior_tag, "reason": "fixture",
        }],
    }


assert module._validate_disposition(
    postfix_disposition_document("SKIPPED", "n/a"), POSTFIX_AUTHORITY) == ()
assert module._validate_disposition(
    postfix_disposition_document("REFUSED", "n/a"), POSTFIX_AUTHORITY) == ()
assert module._validate_disposition(
    postfix_disposition_document("APPLIED", "change"), POSTFIX_AUTHORITY
) == ("src/a.py",)
# DEFERRED is the post-fix ROW's inline disposition (agents/findings-to-issues.md
# Step 3). It must NOT have leaked into the FIXER's vocabulary: a fixer claiming
# DEFERRED would be asserting a routing decision it does not own, and the three
# published values are what publish_disposition and every reader agree on.
expect_contract_reason(
    lambda: module._validate_disposition(
        postfix_disposition_document("DEFERRED", "n/a"), POSTFIX_AUTHORITY),
    "disposition_schema_invalid",
)

# === #381 STEP 2: fix / simplify / defer get a workflow-shaped capture ========
#
# Blocker A. capture_review_terminal and capture_standalone_terminal load a
# FIXER binding, and _load_persistence_binding rebuilt the detached
# LAUNCH_BINDING_KEYS base before delegating. All three assumed the detached key
# set unconditionally, so a workflow binding -- which carries a run_nonce and
# none of the receipt/handle/supervision members -- could reach NONE of them.
# The fix, simplify and defer stages consequently had no capture at all.
#
# What is required is PARITY, not a cheaper path. A fixer child owes a
# disposition artifact and an applied-content artifact on top of the status and
# result a reviewer owes; every one of those proofs is exercised below on a
# workflow binding, and the defer and simplify stages are driven all the way
# through their outcome verbs so the capture is proved to be reachable, not
# merely callable.

# 1. The two launch shapes are structurally mutually exclusive, in BOTH
#    directions. That exclusivity is what makes dispatching on the DECLARED
#    backend sound: no binding can satisfy both key sets, so a mis-declared
#    backend cannot be re-read as the other shape, it can only be refused.
assert module.DETACHED_ONLY_BINDING_KEYS == {
    "receipt_sha256", "handle", "launch_status_sha256",
    "process_identity", "lease_generation",
}, module.DETACHED_ONLY_BINDING_KEYS
assert module.WORKFLOW_ONLY_BINDING_KEYS == {"run_nonce"}, (
    module.WORKFLOW_ONLY_BINDING_KEYS
)
assert module.DETACHED_ONLY_BINDING_KEYS.isdisjoint(
    module.WORKFLOW_ONLY_BINDING_KEYS
)
assert module.DETACHED_ONLY_BINDING_KEYS == (
    module.LAUNCH_BINDING_KEYS - module.WORKFLOW_LAUNCH_BINDING_KEYS
)
assert module.WORKFLOW_ONLY_BINDING_KEYS == (
    module.WORKFLOW_LAUNCH_BINDING_KEYS - module.LAUNCH_BINDING_KEYS
)
# The fixer and persistence shapes add the SAME members to whichever base they
# sit on, so the obligations differ only in how the launch is identified.
for detached_keys, workflow_keys, extra in (
    (module.FIXER_LAUNCH_BINDING_KEYS,
     module.WORKFLOW_FIXER_LAUNCH_BINDING_KEYS,
     module.FIXER_BINDING_EXTRA_KEYS),
    (module.PERSISTENCE_BINDING_KEYS,
     module.WORKFLOW_PERSISTENCE_BINDING_KEYS,
     module.PERSISTENCE_BINDING_EXTRA_KEYS),
):
    assert detached_keys == module.LAUNCH_BINDING_KEYS | extra, extra
    assert workflow_keys == module.WORKFLOW_LAUNCH_BINDING_KEYS | extra, extra
    assert detached_keys != workflow_keys, extra
    assert module.DETACHED_ONLY_BINDING_KEYS.isdisjoint(workflow_keys), extra
    assert module.WORKFLOW_ONLY_BINDING_KEYS.isdisjoint(detached_keys), extra

WORKFLOW_NONCE_OTHER = "a1" * 32
assert WORKFLOW_NONCE_OTHER != WORKFLOW_NONCE
assert re.fullmatch(r"[0-9a-f]{64}", WORKFLOW_NONCE_OTHER)

# 2. review_pr.fix.phase1 -- the authority-derived disposition and
#    applied-content paths are still bound, and all four artifacts are frozen.
with scratch_dir("code-fixer-workflow-review-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "src").mkdir()
    (repo / "src/a.py").write_text("A = 0\n", encoding="utf-8")
    git(repo, "add", "--", "src/a.py")
    git(repo, "commit", "-qm", "test: workflow review base")
    base = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "src/a.py").write_text("A = 1\n", encoding="utf-8")
    git(repo, "add", "--", "src/a.py")
    git(repo, "commit", "-qm", "test: workflow review head")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    evidence = repo / ".uberdev/research/20260804-010203-abcdef0"
    evidence.mkdir(parents=True)
    findings = evidence / "post-impl-review-final.md"
    findings.write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/a.py", "1", "DEFERRED",
         "correct alpha", "bounded"),
    ]))
    commit_range = evidence / "commit-range.txt"
    commit_range.write_text(f"{base}..{head}\n", encoding="ascii")
    disposition = evidence / "phase1-disposition.json"
    disposition.write_bytes(b"")
    authority_receipt = prepare(
        repo, findings, digest(findings), commit_range, digest(commit_range),
        disposition,
    )
    authority_path = pathlib.Path(authority_receipt["authority_path"])
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    published = module.publish_disposition(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        candidate=json.dumps(candidate(authority, [{
            **authority["finding_keys"][0], "disposition": "SKIPPED",
            "behavior_tag": "n/a", "reason": "deferred to a durable issue",
        }])).encode(),
    )
    result_path = evidence / "phase1-fixer-result.md"
    result_path.write_bytes(
        b"```yaml\nstatus: NO_FIXES_NEEDED\nphase: phase1\ncommits: []\n"
        b"findings_disposition: []\nrisks: []\n```\n"
    )
    status_path = evidence / "phase1-fixer-status.json"
    review_instance = "review-pr-run-fix-phase1-iter01-attempt01"
    wf_review_binding = module.bind_workflow_fixer_launch(
        edge_id="review_pr.fix.phase1", instance_id=review_instance,
        run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
        status_path=str(status_path), working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
    )
    status_path.write_text(json.dumps({
        "backend": "workflow", "branch": "", "exit_code": 0,
        "result": wf_review_binding["result_path"],
        "run_nonce": WORKFLOW_NONCE, "state": "completed",
        "workspace_mode": "caller", "worktree": wf_review_binding["worktree"],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")

    assert set(wf_review_binding) == module.WORKFLOW_FIXER_LAUNCH_BINDING_KEYS
    assert wf_review_binding["backend"] == "workflow"
    assert wf_review_binding["run_nonce"] == WORKFLOW_NONCE
    assert not (module.DETACHED_ONLY_BINDING_KEYS & set(wf_review_binding))
    wf_review_bytes = module._canonical_json(wf_review_binding)
    assert module._load_fixer_launch_binding(
        wf_review_bytes, "review_pr.fix.phase1") == wf_review_binding

    review_terminal = module.capture_review_terminal(
        launch_binding=wf_review_bytes,
        disposition_path=str(disposition),
        applied_content_path=published["applied_content_path"],
    )
    # Every proof a detached fixer capture produces, produced here from bytes
    # THIS process read off disk -- no caller-supplied digest is accepted.
    assert set(review_terminal) == {
        "status_path", "status_sha256", "result_path", "result_sha256",
        "disposition_path", "disposition_sha256",
        "applied_content_path", "applied_content_sha256",
    }, review_terminal
    for path_key, sha_key, on_disk in (
        ("status_path", "status_sha256", status_path),
        ("result_path", "result_sha256", result_path),
        ("disposition_path", "disposition_sha256", disposition),
        ("applied_content_path", "applied_content_sha256",
         pathlib.Path(published["applied_content_path"])),
    ):
        assert review_terminal[sha_key] == hashlib.sha256(
            on_disk.read_bytes()).hexdigest(), path_key

    # The authority-derived applied-content path is still the only one accepted.
    foreign_content = evidence / "review-applied-content-forged.json"
    foreign_content.write_bytes(pathlib.Path(
        published["applied_content_path"]).read_bytes())
    expect_contract_reason(
        lambda: module.capture_review_terminal(
            launch_binding=wf_review_bytes,
            disposition_path=str(disposition),
            applied_content_path=str(foreign_content)),
        "validation_authority_mismatch",
    )
    expect_contract_reason(
        lambda: module.capture_review_terminal(
            launch_binding=wf_review_bytes,
            disposition_path=str(evidence / "phase2-disposition.json"),
            applied_content_path=published["applied_content_path"]),
        "validation_authority_mismatch",
    )

    # Cross-backend smuggling is refused in BOTH directions. This pair is the
    # load-bearing negative: without the exclusion guard a workflow binding
    # carrying the supervision triple would be re-read as a detached one (and
    # vice versa), which is exactly how an unproved child gets frozen.
    smuggled_triple = {
        **wf_review_binding,
        "process_identity": "1|1|1|" + "0" * 64,
    }
    expect_contract_reason(
        lambda: module._load_fixer_launch_binding(
            module._canonical_json(smuggled_triple), "review_pr.fix.phase1"),
        "fixer_binding_invalid",
    )
    detached_fixer = {
        "schema_version": 1, "receipt_sha256": "0" * 64,
        "edge_id": "review_pr.fix.phase1", "instance_id": review_instance,
        "backend": "background", "handle": "23456", "launch_status_sha256": "0" * 64,
        "process_identity": "23456|23456|23456|" + "0" * 64,
        "lease_generation": "0" * 32,
        "result_path": wf_review_binding["result_path"],
        "status_path": wf_review_binding["status_path"],
        "workspace_mode": "caller", "worktree": wf_review_binding["worktree"],
        "branch": "",
        "authority_path": wf_review_binding["authority_path"],
        "authority_sha256": wf_review_binding["authority_sha256"],
    }
    assert set(detached_fixer) == module.FIXER_LAUNCH_BINDING_KEYS
    assert module._load_fixer_launch_binding(
        module._canonical_json(detached_fixer),
        "review_pr.fix.phase1") == detached_fixer
    smuggled_nonce = {**detached_fixer, "run_nonce": WORKFLOW_NONCE}
    expect_contract_reason(
        lambda: module._load_fixer_launch_binding(
            module._canonical_json(smuggled_nonce), "review_pr.fix.phase1"),
        "fixer_binding_invalid",
    )

    # The edge id, the nonce shape, and the authority binding are all still
    # enforced by the workflow producer.
    # ...and refused identically for both shapes, from the shared base loader.
    for shaped in (wf_review_binding, detached_fixer):
        expect_contract_reason(
            lambda b=shaped: module._load_fixer_launch_binding(
                module._canonical_json(b), "review_pr.fix.phase2"),
            "launch_binding_invalid",
        )
    for bad_nonce in ("", "g" * 64, "F" * 64, "f" * 63):
        expect_contract_reason(
            lambda n=bad_nonce: module.bind_workflow_fixer_launch(
                edge_id="review_pr.fix.phase1", instance_id=review_instance,
                run_nonce=n, result_path=str(result_path),
                status_path=str(status_path), working_dir=str(repo),
                authority_path=str(authority_path),
                authority_sha256=authority_receipt["authority_sha256"]),
            "launch_binding_invalid",
        )
    # A reviewer edge owes no disposition; it must not be mintable as a fixer.
    for rejected_edge in (
        "review_pr.review.correctness", "review_pr.defer.findings", "",
    ):
        expect_contract_reason(
            lambda e=rejected_edge: module.bind_workflow_fixer_launch(
                edge_id=e, instance_id=review_instance,
                run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
                status_path=str(status_path), working_dir=str(repo),
                authority_path=str(authority_path),
                authority_sha256=authority_receipt["authority_sha256"]),
            "fixer_binding_invalid",
        )
    # The authority must belong to the edge and the worktree being bound.
    expect_contract_reason(
        lambda: module.bind_workflow_fixer_launch(
            edge_id="review_pr.fix.phase2", instance_id=review_instance,
            run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
            status_path=str(status_path), working_dir=str(repo),
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"]),
        "fixer_binding_invalid",
    )

# 3. review_pr.defer.findings -- capture AND outcome, end to end, on a workflow
#    binding. The defer stage carries an aggregate and a disposition pin, and
#    both survive the backend switch.
with scratch_dir("code-fixer-workflow-defer-") as temporary:
    working = pathlib.Path(temporary).resolve()
    result_path = working / "result.md"
    status_path = working / "status.json"
    defer_aggregate = working / "simplify-empty.md"
    defer_disposition = working / "phase2-empty-disposition.json"
    defer_aggregate.write_bytes(aggregate("phase2"))
    defer_aggregate_sha = digest(defer_aggregate)
    defer_disposition.write_text(json.dumps({
        "schema_version": 1, "phase": "phase2",
        "aggregate_sha256": defer_aggregate_sha, "findings_disposition": [],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    defer_disposition_sha = digest(defer_disposition)
    result_path.write_text(persistence_result("DONE"), encoding="utf-8")
    defer_binding = module.bind_workflow_persistence_launch(
        instance_id="review-pr-defer-findings-iter01-attempt01",
        run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
        status_path=str(status_path), working_dir=str(working),
        aggregate_path=str(defer_aggregate),
        aggregate_sha256=defer_aggregate_sha,
        disposition_path=str(defer_disposition),
        disposition_sha256=defer_disposition_sha,
        expected_deferred_blockers=0, require_clean=False,
    )
    assert set(defer_binding) == module.WORKFLOW_PERSISTENCE_BINDING_KEYS
    assert defer_binding["edge_id"] == "review_pr.defer.findings"
    assert not (module.DETACHED_ONLY_BINDING_KEYS & set(defer_binding))
    defer_bytes = module._canonical_json(defer_binding)
    assert module._load_persistence_binding(defer_bytes) == defer_binding

    def defer_status(**overrides):
        document = {
            "backend": "workflow", "branch": "", "exit_code": 0,
            "result": defer_binding["result_path"],
            "run_nonce": WORKFLOW_NONCE, "state": "completed",
            "workspace_mode": "caller", "worktree": defer_binding["worktree"],
        }
        document.update(overrides)
        status_path.write_text(
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    defer_status()
    defer_terminal = module.capture_persistence_terminal(
        launch_binding=defer_bytes)
    assert defer_terminal["status_sha256"] == hashlib.sha256(
        status_path.read_bytes()).hexdigest()
    assert defer_terminal["result_sha256"] == hashlib.sha256(
        result_path.read_bytes()).hexdigest()
    defer_validated = module.validate_persistence_result(
        launch_binding=defer_bytes,
        status_sha256=defer_terminal["status_sha256"],
        result_sha256=defer_terminal["result_sha256"],
    )
    assert defer_validated["status"] == "DONE", defer_validated
    assert defer_validated["aggregate_sha256"] == defer_aggregate_sha

    # A status file from a DIFFERENT launch is refused: the nonce is the whole
    # binding for a workflow child, exactly as the triple is for a detached one.
    for forgery in (
        {"run_nonce": WORKFLOW_NONCE_OTHER},
        {"pid": "23456"},
        {"worktree": str(working / "elsewhere")},
        {"result": str(working / "foreign-result.md")},
    ):
        defer_status(**forgery)
        forged_terminal = module.capture_persistence_terminal(
            launch_binding=defer_bytes)
        expect_contract_reason(
            lambda t=forged_terminal: module.validate_persistence_result(
                launch_binding=defer_bytes,
                status_sha256=t["status_sha256"],
                result_sha256=t["result_sha256"]),
            "child_status_invalid",
        )
    defer_status()

    # Cross-backend smuggling, both directions, on the persistence shape.
    expect_contract_reason(
        lambda: module._load_persistence_binding(module._canonical_json({
            **defer_binding, "process_identity": "1|1|1|" + "0" * 64})),
        "persistence_binding_invalid",
    )
    detached_defer = {
        "schema_version": 1, "receipt_sha256": "0" * 64,
        "edge_id": "review_pr.defer.findings",
        "instance_id": "review-pr-defer-findings-iter01-attempt01",
        "backend": "background", "handle": "34567", "launch_status_sha256": "0" * 64,
        "process_identity": "34567|34567|34567|" + "0" * 64,
        "lease_generation": "0" * 32,
        "result_path": defer_binding["result_path"],
        "status_path": defer_binding["status_path"],
        "workspace_mode": "caller", "worktree": defer_binding["worktree"],
        "branch": "",
        "aggregate_path": defer_binding["aggregate_path"],
        "aggregate_sha256": defer_aggregate_sha,
        "disposition_path": defer_binding["disposition_path"],
        "disposition_sha256": defer_disposition_sha,
        "expected_deferred_blockers": 0, "require_clean": False,
    }
    assert set(detached_defer) == module.PERSISTENCE_BINDING_KEYS
    assert module._load_persistence_binding(
        module._canonical_json(detached_defer)) == detached_defer
    expect_contract_reason(
        lambda: module._load_persistence_binding(module._canonical_json({
            **detached_defer, "run_nonce": WORKFLOW_NONCE})),
        "persistence_binding_invalid",
    )
    # The deferred-blocker pin is not weakened by the backend switch.
    expect_contract_reason(
        lambda: module.bind_workflow_persistence_launch(
            instance_id="review-pr-defer-findings-iter01-attempt01",
            run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
            status_path=str(status_path), working_dir=str(working),
            aggregate_path=str(defer_aggregate),
            aggregate_sha256=defer_aggregate_sha,
            disposition_path=str(defer_disposition),
            disposition_sha256=defer_disposition_sha,
            expected_deferred_blockers=1, require_clean=True),
        "persistence_binding_invalid",
    )

# 4. simplify.fix.phase2 -- capture AND outcome, end to end, on a workflow
#    binding, including the applied-content plan the fixer alone owes.
with scratch_dir("code-fixer-workflow-simplify-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "kept.txt").write_text("H0\n", encoding="utf-8")
    git(repo, "add", "--", "kept.txt")
    git(repo, "commit", "-qm", "test: workflow simplify base")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    evidence = repo / ".uberdev/research/20260804-010204-abcdef0"
    evidence.mkdir(parents=True)
    diff_path = evidence / "pr-diff.md"
    diff_path.write_bytes(
        b'<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n'
    )
    snapshot_path = evidence / "standalone-snapshot.json"
    snapshot_path.write_bytes(b"")
    snapshot_receipt = module.capture_standalone_snapshot(
        working_dir=str(repo), evidence_dir=str(evidence),
        diff_path=str(diff_path), snapshot_path=str(snapshot_path),
    )
    findings = evidence / "simplify-final.md"
    findings.write_bytes(phase2_empty)
    disposition = evidence / "phase2-disposition.json"
    disposition.write_bytes(b"")
    authority_receipt = module.prepare_standalone_authority(
        edge_id="simplify.fix.phase2", policy_phase="simplify_fix",
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    )
    authority_path = pathlib.Path(authority_receipt["authority_path"])
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    published = module.publish_disposition(
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        candidate=json.dumps(candidate(authority, [])).encode(),
    )
    result_path = evidence / "fixer-result.md"
    result_path.write_text(
        "```yaml\nstatus: NO_FIXES_NEEDED\nphase: phase2\ncommits: []\n"
        "findings_disposition: []\nrisks: []\n```\n",
        encoding="utf-8",
    )
    status_path = evidence / "fixer-status.json"
    simplify_binding = module.bind_workflow_fixer_launch(
        edge_id="simplify.fix.phase2",
        instance_id="simplify-fix-phase2-iter01-attempt01",
        run_nonce=WORKFLOW_NONCE, result_path=str(result_path),
        status_path=str(status_path), working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
    )
    status_path.write_text(json.dumps({
        "backend": "workflow", "branch": "", "exit_code": 0,
        "result": simplify_binding["result_path"],
        "run_nonce": WORKFLOW_NONCE, "state": "completed",
        "workspace_mode": "caller", "worktree": simplify_binding["worktree"],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    simplify_bytes = module._canonical_json(simplify_binding)
    simplify_terminal = module.capture_standalone_terminal(
        launch_binding=simplify_bytes, disposition_path=str(disposition),
        applied_content_path=published["applied_content_path"],
    )
    simplify_outcome = module.validate_standalone_outcome(
        launch_binding=simplify_bytes, authority_path=str(authority_path),
        authority_sha256=authority_receipt["authority_sha256"],
        disposition_path=str(disposition),
        disposition_sha256=simplify_terminal["disposition_sha256"],
        applied_content_path=simplify_terminal["applied_content_path"],
        applied_content_sha256=simplify_terminal["applied_content_sha256"],
        status_sha256=simplify_terminal["status_sha256"],
        result_sha256=simplify_terminal["result_sha256"],
        working_dir=str(repo), head_before=head, head_after=head,
    )
    assert simplify_outcome["status"] == "NO_FIXES_NEEDED", simplify_outcome
    # The outcome's tie back to its launch is the NONCE, under its own key. It
    # is not relabelled as a receipt digest -- a consumer written to check a
    # dispatch receipt must not silently accept a workflow outcome instead.
    assert set(simplify_outcome) == {
        "status", "declared_tip", "run_nonce", "status_sha256", "result_sha256",
        "disposition_sha256", "applied_content_sha256", "commit",
    }, simplify_outcome
    assert simplify_outcome["run_nonce"] == WORKFLOW_NONCE
    # A status file that does not echo the minted nonce fails the outcome.
    status_path.write_text(json.dumps({
        "backend": "workflow", "branch": "", "exit_code": 0,
        "result": simplify_binding["result_path"],
        "run_nonce": WORKFLOW_NONCE_OTHER, "state": "completed",
        "workspace_mode": "caller", "worktree": simplify_binding["worktree"],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    forged_terminal = module.capture_standalone_terminal(
        launch_binding=simplify_bytes, disposition_path=str(disposition),
        applied_content_path=published["applied_content_path"],
    )
    expect_contract_reason(
        lambda: module.validate_standalone_outcome(
            launch_binding=simplify_bytes, authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(disposition),
            disposition_sha256=forged_terminal["disposition_sha256"],
            applied_content_path=forged_terminal["applied_content_path"],
            applied_content_sha256=forged_terminal["applied_content_sha256"],
            status_sha256=forged_terminal["status_sha256"],
            result_sha256=forged_terminal["result_sha256"],
            working_dir=str(repo), head_before=head, head_after=head),
        "child_status_invalid",
    )

# 5. Both producers must be REACHABLE from the CLI. A minter with no subparser
#    is dead code, which is what #381 found the first time.
workflow_cli = module._parser()
for verb, argv in (
    ("bind-workflow-fixer-launch", [
        "bind-workflow-fixer-launch", "--edge-id", "review_pr.fix.phase1",
        "--instance-id", "review-pr-run-fix-phase1-iter01-attempt01",
        "--run-nonce", WORKFLOW_NONCE, "--result-path", "/tmp/result.md",
        "--status-path", "/tmp/status.json", "--working-dir", "/tmp",
        "--authority-path", "/tmp/authority.json",
        "--authority-sha256", "0" * 64]),
    ("bind-workflow-persistence-launch", [
        "bind-workflow-persistence-launch",
        "--instance-id", "review-pr-defer-findings-iter01-attempt01",
        "--run-nonce", WORKFLOW_NONCE, "--result-path", "/tmp/result.md",
        "--status-path", "/tmp/status.json", "--working-dir", "/tmp",
        "--aggregate-path", "/tmp/aggregate.md",
        "--aggregate-sha256", "0" * 64,
        "--disposition-path", "/tmp/disposition.json",
        "--disposition-sha256", "0" * 64,
        "--expected-deferred-blockers", "0", "--require-clean", "0"]),
):
    parsed = workflow_cli.parse_args(argv)
    assert parsed.command == verb, parsed

# === #383: the Phase 3 CI edges get their OWN producer and their OWN capture ==
#
# The whole point of this block is that they did NOT join WORKFLOW_BOUND_EDGE_IDS.
# A CI child's authority is a GitHub Actions log or a synthetic aggregate -- bytes
# this run fetched once that no later reader can re-derive -- so the fourth shape
# pins that input alongside the child's two outputs. Freezing only the outputs
# would prove the child wrote something and prove nothing about what it read.

CI_EDGES = (
    "review_pr.ci.classify",
    "review_pr.ci.fix_code",
    "review_pr.ci.rebase",
    "review_pr.ci.defer_refusal",
    "review_pr.ci.resolve_conflict",
)
assert module.WORKFLOW_CI_EDGE_IDS == frozenset(CI_EDGES), module.WORKFLOW_CI_EDGE_IDS
# NOT a widening: the ci edges must stay OUT of every shipped roster, or the old
# verbs would silently accept them and drop the input pin.
assert not (module.WORKFLOW_CI_EDGE_IDS & module.WORKFLOW_BOUND_EDGE_IDS)
assert not (module.WORKFLOW_CI_EDGE_IDS & module.WORKFLOW_PERSISTENCE_EDGE_IDS)
assert module.CI_BINDING_EXTRA_KEYS == frozenset(
    ("ci_authority_path", "ci_authority_sha256")
), module.CI_BINDING_EXTRA_KEYS
# Deliberately NOT authority_path/authority_sha256: those two carry the
# AUTHORITY_KEYS document shape, and _load_fixer_launch_binding would
# _load_authority() a CI authority and reject it. Distinct names make a CI
# binding structurally unreadable as a fixer binding and vice versa.
assert not (module.CI_BINDING_EXTRA_KEYS & module.FIXER_BINDING_EXTRA_KEYS)

# The coverage hole #383 found: `bound_child_edge_unsupported` had NO test at
# all, so adding a ci edge to any roster would have passed every existing case.
# These two lock the refusal in both directions.
for unsupported in ("review_pr.ci.classify", "review_pr.ci.fix_code"):
    expect_contract_reason(
        lambda e=unsupported: module.capture_bound_child(
            launch_binding=module._canonical_json(bc_binding), edge_id=e),
        "bound_child_edge_unsupported",
    )
expect_contract_reason(
    lambda: module.capture_bound_child(
        launch_binding=module._canonical_json(bc_binding),
        edge_id="review_pr.fix.phase1"),
    "bound_child_edge_unsupported",
)

CI_NONCE = "c3" * 32
CI_NONCE_OTHER = "d4" * 32


def ci_status_document(binding, **overrides):
    document = {
        "backend": "workflow", "branch": "", "exit_code": 0,
        "result": binding["result_path"], "run_nonce": binding["run_nonce"],
        "state": "completed", "workspace_mode": "caller",
        "worktree": binding["worktree"],
    }
    document.update(overrides)
    for key, value in list(document.items()):
        if value is None:
            del document[key]
    return json.dumps(document, sort_keys=True, separators=(",", ":")).encode() + b"\n"


with scratch_dir("code-fixer-ci-edges-") as temporary:
    ci_repo = pathlib.Path(temporary) / "repo"
    ci_repo.mkdir()
    git(ci_repo, "init", "-q")
    git(ci_repo, "config", "user.email", "fixture@example.invalid")
    git(ci_repo, "config", "user.name", "Fixture")
    (ci_repo / "src").mkdir()
    (ci_repo / "src/app.py").write_text("APP = 1\n", encoding="utf-8")
    (ci_repo / "package-lock.json").write_text("{}\n", encoding="utf-8")
    # A tracked file OUTSIDE the anchor set that already exists at the pinned
    # parent. The scope rows below must be able to model a commit that DELETES
    # such a path, and a fix commit is required to be a single commit off
    # `ci_head` — so the deletion's source has to be in the base tree or the
    # rename-escape row cannot be written at all.
    (ci_repo / "src/security_guard.py").write_text(
        "GUARD = 1\nALLOWLIST = ()\n", encoding="utf-8")
    git(ci_repo, "add", "--",
        "src/app.py", "package-lock.json", "src/security_guard.py")
    git(ci_repo, "commit", "-qm", "test: ci fixture base")
    ci_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    ci_tree = git(ci_repo, "rev-parse", "HEAD^{tree}").stdout.decode().strip()

    ci_evidence = ci_repo / ".uberdev/research/20260806-000000-cafe000"
    ci_evidence.mkdir(parents=True)
    ci_children = ci_evidence / "children"
    ci_children.mkdir()

    ci_log = ci_evidence / "ci-log-authority-iter01-ci01.md"
    ci_log_bytes = (
        b'<external-untrusted-input source="github-actions-log-pr-41-run-77">\n'
        b"FAIL src/app.py::test_alpha\n"
        b"</external-untrusted-input>\n"
    )
    ci_log.write_bytes(ci_log_bytes)
    ci_log_sha = hashlib.sha256(ci_log_bytes).hexdigest()

    def ci_child_dir(slug):
        target = ci_children / slug
        target.mkdir(exist_ok=True)
        return target

    # ---- prepare-ci-authority: the read shape ------------------------------
    classify_authority_path = ci_evidence / "ci-authority-classify-iter01-ci01.json"
    classify_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
        head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
        input_sha256=ci_log_sha,
        authority_output_path=str(classify_authority_path),
    )
    assert set(classify_receipt) == {
        "authority_path", "authority_sha256", "edge_id", "phase"
    }, classify_receipt
    assert classify_receipt["phase"] == "ci", classify_receipt
    classify_authority = module._load_ci_authority(
        classify_receipt["authority_path"], classify_receipt["authority_sha256"])
    assert set(classify_authority) == set(module.CI_READ_AUTHORITY_KEYS), classify_authority

    # A read edge carries no git identity at all -- there is no slot for one.
    assert "lease_sha" not in classify_authority

    # The mint is no-clobber: a second mint onto the same path refuses rather
    # than replacing an authority a binding may already pin.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha,
            authority_output_path=str(classify_authority_path)),
        "authority_preexists",
    )

    # ---- prepare-ci-authority: per-edge required members -------------------
    # A rebase authority with no lease is refused AT MINT, so the Workflow call
    # is never made rather than made and then judged.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, base_sha=ci_head, lease_sha="",
            pr_branch="fix/383", base_branch="main",
            authority_output_path=str(ci_evidence / "ci-authority-rebase-iter01-ci09.json")),
        "ci_authority_invalid",
    )
    # #438 — the BASE TIP is a member of the mutating authority, and a REQUIRED
    # one for the rebase edge. `base_sha` is a MERGE-BASE, and once the base
    # branch is itself force-pushed that merge-base collapses to the fork point
    # every candidate rebase target already contains; the tip is the only pinned
    # value that can tell a correct rebase from a stack-detaching one. Required,
    # not optional, for the same reason `lease_sha` is: the value crosses a dead
    # shell between 6c.4 ROUTE and 6c.4w.1 MINT, and a soft default there is the
    # #418/#419 class re-opened inside the fix for #438.
    assert "base_tip_sha" in module.CI_MUTATION_AUTHORITY_KEYS, (
        module.CI_MUTATION_AUTHORITY_KEYS)
    assert "base_tip_sha" not in module.CI_READ_AUTHORITY_KEYS, (
        module.CI_READ_AUTHORITY_KEYS)
    assert "base_tip_sha" in module.CI_AUTHORITY_REQUIRED_MEMBERS[
        "review_pr.ci.rebase"], module.CI_AUTHORITY_REQUIRED_MEMBERS
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, base_sha=ci_head, lease_sha="b" * 40,
            base_tip_sha="",
            pr_branch="fix/383", base_branch="main",
            authority_output_path=str(ci_evidence / "ci-authority-rebase-iter01-ci10.json")),
        "ci_authority_invalid",
    )
    # ...and a non-SHA1 tip is refused by the shape check, not carried as prose
    # into a `merge-base --is-ancestor` argument.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, base_sha=ci_head, lease_sha="b" * 40,
            base_tip_sha="origin/main",
            pr_branch="fix/383", base_branch="main",
            authority_output_path=str(ci_evidence / "ci-authority-rebase-iter01-ci11.json")),
        "ci_authority_invalid",
    )
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.fix_code", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, failure_class="code_bug", signal_anchor="",
            parent_sha=ci_head, parent_tree_sha=ci_tree,
            authority_output_path=str(ci_evidence / "ci-authority-fix-code-iter01-ci09.json")),
        "ci_authority_invalid",
    )
    # An unknown failure class cannot be minted into an authority at all.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.fix_code", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, failure_class="vibes",
            signal_anchor="src/app.py:1", parent_sha=ci_head,
            parent_tree_sha=ci_tree,
            authority_output_path=str(ci_evidence / "ci-authority-fix-code-iter01-ci08.json")),
        "ci_authority_invalid",
    )
    # The pinned input bytes must really be there under that digest at mint time.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256="0" * 64,
            authority_output_path=str(ci_evidence / "ci-authority-classify-iter01-ci07.json")),
        "artifact_digest_mismatch",
    )

    # ---- bind-workflow-ci-launch -------------------------------------------
    classify_child = ci_child_dir("ci-classify-ci01-iter01")
    classify_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.classify", instance_id="ci-classify-ci01-iter01",
        run_nonce=CI_NONCE, result_path=str(classify_child / "result.md"),
        status_path=str(classify_child / "status.json"), working_dir=str(ci_repo),
        ci_authority_path=classify_receipt["authority_path"],
        ci_authority_sha256=classify_receipt["authority_sha256"],
    )
    assert set(classify_binding) == set(
        module.WORKFLOW_CI_LAUNCH_BINDING_KEYS), classify_binding
    # A CI binding is structurally unreadable as a fixer or reviewer binding.
    expect_contract_reason(
        lambda: module._load_fixer_launch_binding(
            module._canonical_json(classify_binding), "review_pr.ci.classify"),
        "fixer_binding_invalid",
    )
    # The producer's allowlist is the CI roster alone.
    expect_contract_reason(
        lambda: module.bind_workflow_ci_launch(
            edge_id="review_pr.fix.phase1", instance_id="x-iter01",
            run_nonce=CI_NONCE, result_path=str(classify_child / "result.md"),
            status_path=str(classify_child / "status.json"),
            working_dir=str(ci_repo),
            ci_authority_path=classify_receipt["authority_path"],
            ci_authority_sha256=classify_receipt["authority_sha256"]),
        "ci_binding_invalid",
    )
    # The authority must name THIS edge: a classify authority cannot license a
    # rebase child.
    expect_contract_reason(
        lambda: module.bind_workflow_ci_launch(
            edge_id="review_pr.ci.rebase", instance_id="ci-rebase-ci01-iter01",
            run_nonce=CI_NONCE, result_path=str(classify_child / "result.md"),
            status_path=str(classify_child / "status.json"),
            working_dir=str(ci_repo),
            ci_authority_path=classify_receipt["authority_path"],
            ci_authority_sha256=classify_receipt["authority_sha256"]),
        "ci_binding_invalid",
    )

    # ---- capture-ci-terminal ------------------------------------------------
    classify_result_bytes = (
        b"CI classification\n\n```yaml\n"
        b"status: CLASSIFIED\n"
        b"failure_class: code_bug\n"
        b"signal_anchor: src/app.py:1\n"
        b"rationale: assertion failed in test_alpha\n"
        b"risks: []\n"
        b"```\n"
    )
    (classify_child / "result.md").write_bytes(classify_result_bytes)
    (classify_child / "status.json").write_bytes(ci_status_document(classify_binding))
    classify_binding_bytes = module._canonical_json(classify_binding)
    ci_terminal = module.capture_ci_terminal(
        launch_binding=classify_binding_bytes, edge_id="review_pr.ci.classify")
    assert ci_terminal == {
        "edge_id": "review_pr.ci.classify",
        "instance_id": "ci-classify-ci01-iter01",
        "status_path": classify_binding["status_path"],
        "status_sha256": hashlib.sha256(
            ci_status_document(classify_binding)).hexdigest(),
        "result_path": classify_binding["result_path"],
        "result_sha256": hashlib.sha256(classify_result_bytes).hexdigest(),
        "input_path": os.path.realpath(str(ci_log)),
        "input_sha256": ci_log_sha,
    }, ci_terminal
    assert re.fullmatch(r"[0-9a-f]{64}", ci_terminal["status_sha256"])
    assert re.fullmatch(r"[0-9a-f]{64}", ci_terminal["result_sha256"])

    # The detached supervision triple must be ABSENT. A synthesised pid would
    # make every downstream equality look verified while proving nothing.
    for smuggled in ({"pid": 4242},
                     {"process_identity": "1|1|1|" + "0" * 64},
                     {"lease_generation": "0" * 32}):
        (classify_child / "status.json").write_bytes(
            ci_status_document(classify_binding, **smuggled))
        expect_contract_reason(
            lambda: module.capture_ci_terminal(
                launch_binding=classify_binding_bytes,
                edge_id="review_pr.ci.classify"),
            "child_status_invalid",
        )
    for unbound in ({"run_nonce": CI_NONCE_OTHER}, {"state": "running"},
                    {"exit_code": 1}):
        (classify_child / "status.json").write_bytes(
            ci_status_document(classify_binding, **unbound))
        expect_contract_reason(
            lambda: module.capture_ci_terminal(
                launch_binding=classify_binding_bytes,
                edge_id="review_pr.ci.classify"),
            "child_status_invalid",
        )
    (classify_child / "status.json").write_bytes(ci_status_document(classify_binding))

    # Two distinct artifacts, never one file reached by two names. The refusal
    # is layered and the OUTER layer fires first, which is the correct order:
    # a symlinked status.json fails to canonicalise to itself at binding load
    # (launch_binding_invalid), and a hard-linked one is refused by the bounded
    # reader's st_nlink check (artifact_not_owned_regular) before
    # capture_ci_terminal's own status_identity == result_identity guard is even
    # reached. Both spellings are asserted so a future edit cannot delete the
    # outer layer and leave only the guard nobody exercises.
    (classify_child / "status.json").unlink()
    try:
        os.symlink(str(classify_child / "result.md"),
                   str(classify_child / "status.json"))
    except (NotImplementedError, OSError):
        pass
    else:
        expect_contract_reason(
            lambda: module.capture_ci_terminal(
                launch_binding=classify_binding_bytes,
                edge_id="review_pr.ci.classify"),
            "launch_binding_invalid",
        )
        (classify_child / "status.json").unlink()
    try:
        os.link(str(classify_child / "result.md"),
                str(classify_child / "status.json"))
    except (NotImplementedError, OSError):
        pass
    else:
        expect_contract_reason(
            lambda: module.capture_ci_terminal(
                launch_binding=classify_binding_bytes,
                edge_id="review_pr.ci.classify"),
            "artifact_not_owned_regular",
        )
        (classify_child / "status.json").unlink()
    (classify_child / "status.json").write_bytes(
        ci_status_document(classify_binding))

    # THE PIN THAT MAKES THIS A FOURTH SHAPE: swapping the log bytes after the
    # mint must break the capture. capture_bound_child would never have noticed.
    ci_log.write_bytes(ci_log_bytes.replace(b"test_alpha", b"test_omega"))
    expect_contract_reason(
        lambda: module.capture_ci_terminal(
            launch_binding=classify_binding_bytes,
            edge_id="review_pr.ci.classify"),
        "artifact_digest_mismatch",
    )
    ci_log.write_bytes(ci_log_bytes)

    # read_ci_authority_member re-checks the AUTHORITY digest on every read.
    # That is the whole reason the controller does not reach for jq: jq would
    # read the file without re-proving it, and the member being read is the
    # lease SHA a force-push is about to be authorised against.
    assert module.read_ci_authority_member(
        authority_path=classify_receipt["authority_path"],
        authority_sha256=classify_receipt["authority_sha256"],
        member="run_id") == "77"
    authority_file = pathlib.Path(classify_receipt["authority_path"])
    authority_original = authority_file.read_bytes()
    os.chmod(authority_file, 0o600)
    authority_file.write_bytes(authority_original.replace(b'"77"', b'"78"'))
    expect_contract_reason(
        lambda: module.read_ci_authority_member(
            authority_path=classify_receipt["authority_path"],
            authority_sha256=classify_receipt["authority_sha256"],
            member="run_id"),
        "artifact_digest_mismatch",
    )
    # And every verb that loads the binding refuses too, because the binding
    # pins the authority by digest rather than by pathname.
    expect_contract_reason(
        lambda: module.capture_ci_terminal(
            launch_binding=classify_binding_bytes,
            edge_id="review_pr.ci.classify"),
        "artifact_digest_mismatch",
    )
    authority_file.write_bytes(authority_original)
    # A member the authority does not carry is not silently empty.
    expect_contract_reason(
        lambda: module.read_ci_authority_member(
            authority_path=classify_receipt["authority_path"],
            authority_sha256=classify_receipt["authority_sha256"],
            member="lease_sha"),
        "ci_authority_member_invalid",
    )

    # ---- validate-ci-classification ----------------------------------------
    ci_classification = module.validate_ci_classification(
        launch_binding=classify_binding_bytes,
        status_sha256=ci_terminal["status_sha256"],
        result_sha256=ci_terminal["result_sha256"],
    )
    assert ci_classification["status"] == "CLASSIFIED", ci_classification
    assert ci_classification["failure_class"] == "code_bug", ci_classification
    assert ci_classification["signal_anchor"] == "src/app.py:1", ci_classification
    # The outcome is tied to THE launch by the nonce, under its own key.
    assert ci_classification["run_nonce"] == CI_NONCE, ci_classification
    assert "receipt_sha256" not in ci_classification, ci_classification


    def reclassify_raw(payload):
        (classify_child / "result.md").write_bytes(payload)
        return module.capture_ci_terminal(
            launch_binding=classify_binding_bytes, edge_id="review_pr.ci.classify")

    def reclassify(body):
        return reclassify_raw(b"CI classification\n\n```yaml\n" + body + b"```\n")

    # An anchor that names no repository file cannot license a code_bug fix.
    bad = reclassify(
        b"status: CLASSIFIED\nfailure_class: code_bug\n"
        b"signal_anchor: src/nope.py:1\nrationale: x\nrisks: []\n")
    expect_contract_reason(
        lambda: module.validate_ci_classification(
            launch_binding=classify_binding_bytes,
            status_sha256=bad["status_sha256"], result_sha256=bad["result_sha256"]),
        "ci_classification_contract_invalid",
    )
    # `:121` / `file:0` / absolute / traversal anchors are contract violations.
    for hostile in (b":121", b"src/app.py:0", b"/etc/passwd:1", b"../x/app.py:1"):
        bad = reclassify(
            b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: "
            + hostile + b"\nrationale: x\nrisks: []\n")
        expect_contract_reason(
            lambda b=bad: module.validate_ci_classification(
                launch_binding=classify_binding_bytes,
                status_sha256=b["status_sha256"], result_sha256=b["result_sha256"]),
            "ci_classification_contract_invalid",
        )
    # An unknown class is never repaired into flaky or platform_outage.
    bad = reclassify(
        b"status: CLASSIFIED\nfailure_class: vibes\nsignal_anchor: src/app.py:1\n"
        b"rationale: x\nrisks: []\n")
    expect_contract_reason(
        lambda: module.validate_ci_classification(
            launch_binding=classify_binding_bytes,
            status_sha256=bad["status_sha256"], result_sha256=bad["result_sha256"]),
        "ci_classification_contract_invalid",
    )
    # REFUSED is terminal, and it is NOT mislabelled contract_invalid.
    bad = reclassify(
        b"status: REFUSED\nfailure_class: null\nsignal_anchor: null\n"
        b"rationale: log truncated\nrisks: []\n")
    expect_contract_reason(
        lambda: module.validate_ci_classification(
            launch_binding=classify_binding_bytes,
            status_sha256=bad["status_sha256"], result_sha256=bad["result_sha256"]),
        "ci_classification_refused",
    )
    # AMBIGUOUS keeps its shipped routing: the controller maps it to flaky after
    # its dedicated audit event, so the verb reports rather than halts.
    ambiguous = reclassify(
        b"status: AMBIGUOUS\nfailure_class: null\nsignal_anchor: null\n"
        b"rationale: no regex matched\nrisks: []\n")
    ambiguous_outcome = module.validate_ci_classification(
        launch_binding=classify_binding_bytes,
        status_sha256=ambiguous["status_sha256"],
        result_sha256=ambiguous["result_sha256"])
    assert ambiguous_outcome["status"] == "AMBIGUOUS", ambiguous_outcome
    assert ambiguous_outcome["failure_class"] == "flaky", ambiguous_outcome

    # ---- the classifier PREDICATE's own edge cases --------------------------
    #
    # Everything above reaches _parse_ci_classification through reclassify(),
    # which only ever emits BARE unquoted scalars (`code_bug`, `src/app.py:1`,
    # `x`, `null`). That leaves five guard clauses with zero behavioural
    # coverage: the 256-character scalar cap, the C0/DEL rejection, the
    # single-quoted YAML decoder, the closed field set + `risks: []`, and the
    # duplicate-field refusal — plus the 65,536-byte document limit. Each was
    # verified by mutation: gutting the length/control test, replacing the
    # single-quote branch with `raw.startswith("'")` / `raw[1:-1]`, turning the
    # field-set check into `if False`, and deleting the duplicate-key check ALL
    # left this suite green before these rows existed.
    #
    # Driven against the predicate directly rather than through reclassify():
    # the document limit is the only row that needs the capture round-trip, and
    # paying for one per hostile scalar would add ~40 subprocess git repos.
    def classify_bytes(body: bytes) -> bytes:
        return b"CI classification\n\n```yaml\n" + body + b"```\n"

    def parse_classification(body: bytes):
        return module._parse_ci_classification(classify_bytes(body), str(ci_repo))

    def expect_classification_invalid(body: bytes):
        expect_contract_reason(
            lambda: parse_classification(body),
            "ci_classification_contract_invalid",
        )

    def refused_body(rationale: bytes) -> bytes:
        return (b"status: REFUSED\nfailure_class: null\nsignal_anchor: null\n"
                b"rationale: " + rationale + b"\nrisks: []\n")

    # The 256-character cap is a real boundary: 256 is legal, 257 is not.
    expect_contract_reason(
        lambda: parse_classification(
            refused_body(json.dumps("x" * 256).encode("utf-8"))),
        "ci_classification_refused",
    )
    expect_classification_invalid(
        refused_body(json.dumps("x" * 257).encode("utf-8")))
    # A DECODED control character is the one an unquoted-scalar regex cannot
    # see: it arrives through the JSON escape or the single-quote branch.
    for control in (0, 1, 31, 127):
        hostile_scalar = "boun" + chr(control) + "ded"
        expect_classification_invalid(
            refused_body(json.dumps(hostile_scalar).encode("utf-8")))
        expect_classification_invalid(
            refused_body(
                ("'" + hostile_scalar.replace("'", "''") + "'").encode("utf-8")))
    # The single-quoted branch DECODES: a doubled apostrophe is one apostrophe,
    # in the rationale and in the anchor alike.
    expect_contract_reason(
        lambda: parse_classification(refused_body(b"'can''t reproduce it'")),
        "ci_classification_refused",
    )
    single_quoted_anchor = parse_classification(
        b"status: CLASSIFIED\nfailure_class: code_bug\n"
        b"signal_anchor: 'src/app.py:42'\nrationale: 'it''s red'\nrisks: []\n")
    assert single_quoted_anchor["signal_anchor"] == "src/app.py:42", single_quoted_anchor
    assert single_quoted_anchor["rationale"] == "it's red", single_quoted_anchor
    # ...and it is a real YAML single-quoted scalar or nothing. An unterminated
    # quote and an unpaired inner apostrophe are both contract violations; a
    # naive `raw[1:-1]` accepts the first and mis-decodes the second.
    for malformed in (b"'unterminated", b"'can't reproduce it'", b"'"):
        expect_classification_invalid(refused_body(malformed))
    # The bare-scalar charset is closed too — `@` is not in it.
    expect_classification_invalid(refused_body(b"boun@ded"))
    # The field set is CLOSED, `risks` must be the empty list, and a repeated
    # key is a violation rather than a last-writer-wins overwrite.
    expect_classification_invalid(
        b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: src/app.py:1\n"
        b"rationale: x\nrisks: []\nextra: smuggled\n")
    expect_classification_invalid(
        b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: src/app.py:1\n"
        b"risks: []\n")
    expect_classification_invalid(
        b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: src/app.py:1\n"
        b"rationale: x\nrisks: [drop-tests]\n")
    expect_classification_invalid(
        b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: src/app.py:1\n"
        b"rationale: x\nrisks: []\nfailure_class: flaky\n")
    # REFUSED without a rationale is a violation, not a refusal: the halt prose
    # and the filed issue both quote it.
    expect_classification_invalid(
        b"status: REFUSED\nfailure_class: null\nsignal_anchor: null\n"
        b"rationale: null\nrisks: []\n")
    # The 65,536-byte document limit bounds the LAST-fence scan over bytes an
    # agent chose. This one needs the capture round-trip, because the limit is
    # applied by validate-ci-classification, not by the predicate.
    classification_document = classify_bytes(
        b"status: REFUSED\nfailure_class: null\nsignal_anchor: null\n"
        b"rationale: bounded\nrisks: []\n")
    for document_size, expected_reason in (
        (module.CI_CLASSIFICATION_RESULT_LIMIT, "ci_classification_refused"),
        (module.CI_CLASSIFICATION_RESULT_LIMIT + 1, "artifact_size_invalid"),
    ):
        padding = b"x" * (document_size - len(classification_document) - 1) + b"\n"
        sized = reclassify_raw(padding + classification_document)
        assert len(padding + classification_document) == document_size
        expect_contract_reason(
            lambda s=sized: module.validate_ci_classification(
                launch_binding=classify_binding_bytes,
                status_sha256=s["status_sha256"],
                result_sha256=s["result_sha256"]),
            expected_reason,
        )

    reclassify(
        b"status: CLASSIFIED\nfailure_class: code_bug\nsignal_anchor: src/app.py:1\n"
        b"rationale: assertion failed in test_alpha\nrisks: []\n")

    # ---- validate-ci-mutation-outcome: fix_code ----------------------------
    fix_authority_path = ci_evidence / "ci-authority-fix-code-iter01-ci01.json"
    fix_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.fix_code", pr_number=41, run_id="77",
        head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
        input_sha256=ci_log_sha, failure_class="code_bug",
        signal_anchor="src/app.py:1", parent_sha=ci_head, parent_tree_sha=ci_tree,
        lease_sha="b" * 40, pr_branch="fix/383-phase3",
        authority_output_path=str(fix_authority_path),
    )
    # The lease is REQUIRED on this edge too: the fix_code terminal reaches the
    # same single leased push the rebase terminal does, so an authority minted
    # without one would send the controller to a push with nothing to lease
    # against. Refused AT MINT, before the child runs.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.fix_code", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, failure_class="code_bug",
            signal_anchor="src/app.py:1", parent_sha=ci_head,
            parent_tree_sha=ci_tree, lease_sha="", pr_branch="fix/383-phase3",
            authority_output_path=str(
                ci_evidence / "ci-authority-fix-code-iter01-ci06.json")),
        "ci_authority_invalid",
    )
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.fix_code", pr_number=41, run_id="77",
            head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
            input_sha256=ci_log_sha, failure_class="code_bug",
            signal_anchor="src/app.py:1", parent_sha=ci_head,
            parent_tree_sha=ci_tree, lease_sha="b" * 40, pr_branch="",
            authority_output_path=str(
                ci_evidence / "ci-authority-fix-code-iter01-ci05.json")),
        "ci_authority_invalid",
    )
    fix_child = ci_child_dir("ci-fix-code-ci01-iter01")
    fix_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.fix_code", instance_id="ci-fix-code-ci01-iter01",
        run_nonce=CI_NONCE, result_path=str(fix_child / "result.md"),
        status_path=str(fix_child / "status.json"), working_dir=str(ci_repo),
        ci_authority_path=fix_receipt["authority_path"],
        ci_authority_sha256=fix_receipt["authority_sha256"],
    )
    (fix_child / "result.md").write_bytes(b"fixed the assertion\n")
    (fix_child / "status.json").write_bytes(ci_status_document(fix_binding))
    fix_binding_bytes = module._canonical_json(fix_binding)
    fix_terminal = module.capture_ci_terminal(
        launch_binding=fix_binding_bytes, edge_id="review_pr.ci.fix_code")

    def fix_outcome(head_after, **overrides):
        arguments = dict(
            launch_binding=fix_binding_bytes,
            status_sha256=fix_terminal["status_sha256"],
            result_sha256=fix_terminal["result_sha256"],
            working_dir=str(ci_repo), head_before=ci_head, head_after=head_after,
            remote_head_sha="",
        )
        arguments.update(overrides)
        return module.validate_ci_mutation_outcome(**arguments)

    # No commit at all is a legitimate terminal, and it is derived from git.
    no_change = fix_outcome(ci_head)
    assert no_change["status"] == "NO_CHANGE", no_change
    assert no_change["run_nonce"] == CI_NONCE, no_change
    assert no_change["rationale"] == "", no_change

    # ---- the REFUSED terminal, which git cannot express -------------------
    # A refusing ci-code-fixer makes no commit, so head_after == head_before and
    # the git-derived terminal is NO_CHANGE — byte-identical to a fixer that
    # simply found nothing to change. 6c.5 branches on the VALIDATED terminal
    # only, so with those two conflated the whole ci-defer stage (four fences,
    # an authority edge, a Workflow arm) was unreachable on the documented path:
    # a REFUSED fixer halted `ci_fix_no_change` and no CRITICAL issue was ever
    # filed. The declaration is read HERE, controller-side, out of the child's
    # digest-pinned result bytes — and it can only ever downgrade a no-commit
    # terminal into a halt, never authorise a push.
    refused_child = ci_child_dir("ci-fix-code-ci09-iter01")
    refused_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.fix_code", instance_id="ci-fix-code-ci09-iter01",
        run_nonce=CI_NONCE, result_path=str(refused_child / "result.md"),
        status_path=str(refused_child / "status.json"), working_dir=str(ci_repo),
        ci_authority_path=fix_receipt["authority_path"],
        ci_authority_sha256=fix_receipt["authority_sha256"],
    )
    (refused_child / "status.json").write_bytes(ci_status_document(refused_binding))
    refused_binding_bytes = module._canonical_json(refused_binding)

    def refused_outcome(result_text, head_after=ci_head):
        (refused_child / "result.md").write_text(result_text, encoding="utf-8")
        terminal = module.capture_ci_terminal(
            launch_binding=refused_binding_bytes, edge_id="review_pr.ci.fix_code")
        return module.validate_ci_mutation_outcome(
            launch_binding=refused_binding_bytes,
            status_sha256=terminal["status_sha256"],
            result_sha256=terminal["result_sha256"],
            working_dir=str(ci_repo), head_before=ci_head, head_after=head_after,
            remote_head_sha="")

    refused = refused_outcome(
        "the forbidden-pattern guard fired\n\n"
        "```yaml\n"
        "status: REFUSED\n"
        "failure_class: code_bug\n"
        "rationale: forbidden-pattern-no-verify\n"
        "risks: []\n"
        "```\n"
    )
    assert refused["status"] == "REFUSED", refused
    assert refused["rationale"] == "forbidden-pattern-no-verify", refused
    # A rationale outside the documented shape still refuses — it just cannot
    # smuggle arbitrary bytes into `data.subreason=ci_fixer_refused_<rationale>`.
    unspecified = refused_outcome(
        "```yaml\nstatus: REFUSED\nrationale: Ceci n'est pas un rationale\n```\n")
    assert unspecified["status"] == "REFUSED", unspecified
    assert unspecified["rationale"] == "unspecified", unspecified
    # A missing rationale is still a refusal, not a silent NO_CHANGE.
    bare = refused_outcome("```yaml\nstatus: REFUSED\n```\n")
    assert bare["status"] == "REFUSED", bare
    assert bare["rationale"] == "unspecified", bare
    # ...and the child NEVER gets to talk its way OUT of a real commit or INTO
    # one. `status: APPLIED` over an unmoved HEAD is still NO_CHANGE.
    still_no_change = refused_outcome(
        "```yaml\nstatus: APPLIED\nrationale: trust me\n```\n")
    assert still_no_change["status"] == "NO_CHANGE", still_no_change
    unfenced = refused_outcome("status: REFUSED\nrationale: not-in-a-fence\n")
    assert unfenced["status"] == "NO_CHANGE", unfenced

    (ci_repo / "src/app.py").write_text("APP = 2\n", encoding="utf-8")
    git(ci_repo, "add", "--", "src/app.py")
    git(ci_repo, "commit", "-qm", "fix(ci): correct the alpha assertion")
    fix_applied_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    applied = fix_outcome(fix_applied_head)
    assert applied["status"] == "APPLIED", applied

    # head_before must be the pinned parent. A caller that hands a different
    # one is describing a different run.
    expect_contract_reason(
        lambda: fix_outcome(fix_applied_head, head_before="not-a-sha"),
        "commit_identity_invalid",
    )
    expect_contract_reason(
        lambda: fix_outcome(fix_applied_head, head_before=fix_applied_head),
        "ci_fix_head_moved_unexpectedly",
    )

    # A subject outside the two permitted forms is refused by the CONTROLLER,
    # not merely asked of the agent.
    git(ci_repo, "commit", "-q", "--amend", "-m", "chore: quietly change things")
    bad_subject_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    expect_contract_reason(
        lambda: fix_outcome(bad_subject_head),
        "ci_fix_commit_subject_invalid",
    )

    # Scope: only the anchor's own file plus at most one lockfile.
    git(ci_repo, "reset", "-q", "--hard", ci_head)
    (ci_repo / "src/app.py").write_text("APP = 3\n", encoding="utf-8")
    (ci_repo / "src/other.py").write_text("OTHER = 1\n", encoding="utf-8")
    git(ci_repo, "add", "--", "src/app.py", "src/other.py")
    git(ci_repo, "commit", "-qm", "fix(ci): touch a file the anchor never named")
    escape_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    expect_contract_reason(lambda: fix_outcome(escape_head), "ci_fix_scope_escape")

    # A single lockfile alongside the anchor is permitted; two is the churn
    # forbidden-pattern, enforced here instead of asked of the agent.
    git(ci_repo, "reset", "-q", "--hard", ci_head)
    (ci_repo / "src/app.py").write_text("APP = 4\n", encoding="utf-8")
    (ci_repo / "package-lock.json").write_text('{"v":2}\n', encoding="utf-8")
    git(ci_repo, "add", "--", "src/app.py", "package-lock.json")
    git(ci_repo, "commit", "-qm", "chore(deps): refresh the lockfile")
    one_lock_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert fix_outcome(one_lock_head)["status"] == "APPLIED"
    git(ci_repo, "reset", "-q", "--hard", ci_head)
    (ci_repo / "src/app.py").write_text("APP = 5\n", encoding="utf-8")
    (ci_repo / "package-lock.json").write_text('{"v":3}\n', encoding="utf-8")
    (ci_repo / "poetry.lock").write_text("# lock\n", encoding="utf-8")
    git(ci_repo, "add", "--", "src/app.py", "package-lock.json", "poetry.lock")
    git(ci_repo, "commit", "-qm", "chore(deps): churn two lockfiles at once")
    two_lock_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    expect_contract_reason(lambda: fix_outcome(two_lock_head), "ci_fix_multi_lockfile")

    # A RENAME out of the anchor set is a DELETION the scope check must see.
    # git's rename detection is on by default, and it collapses a rename to its
    # DESTINATION path alone — so `src/security_guard.py -> Cargo.lock` alongside
    # a legitimate anchor edit reported `['Cargo.lock', 'src/app.py']`: one
    # anchor plus one lockfile, exactly the permitted shape. `ci_fix_scope_escape`
    # never fired, the terminal was APPLIED, and the arbitrary deletion rode the
    # leased force-push. The source path has to be enumerated for the loop below
    # it to have anything to refuse, which is what `--no-renames` buys.
    git(ci_repo, "reset", "-q", "--hard", ci_head)
    (ci_repo / "src/app.py").write_text("APP = 6\n", encoding="utf-8")
    git(ci_repo, "mv", "src/security_guard.py", "Cargo.lock")
    git(ci_repo, "add", "--", "src/app.py")
    git(ci_repo, "commit", "-qm", "chore(deps): hide a deletion behind a rename")
    renamed_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()
    expect_contract_reason(lambda: fix_outcome(renamed_head), "ci_fix_scope_escape")
    git(ci_repo, "reset", "-q", "--hard", ci_head)

    # ---- validate-ci-mutation-outcome: rebase (the lease) ------------------
    lease_sha = "b" * 40
    rebase_authority_path = ci_evidence / "ci-authority-rebase-iter01-ci01.json"
    rebase_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
        head_sha=ci_head, working_dir=str(ci_repo), input_path=str(ci_log),
        input_sha256=ci_log_sha, base_sha=ci_head, base_tip_sha=ci_head,
        lease_sha=lease_sha,
        pr_branch="fix/383-phase3", base_branch="main",
        authority_output_path=str(rebase_authority_path),
    )
    rebase_child = ci_child_dir("ci-rebase-ci01-iter01")
    rebase_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.rebase", instance_id="ci-rebase-ci01-iter01",
        run_nonce=CI_NONCE, result_path=str(rebase_child / "result.md"),
        status_path=str(rebase_child / "status.json"), working_dir=str(ci_repo),
        ci_authority_path=rebase_receipt["authority_path"],
        ci_authority_sha256=rebase_receipt["authority_sha256"],
    )
    (rebase_child / "result.md").write_bytes(b"rebased onto origin/main\n")
    (rebase_child / "status.json").write_bytes(ci_status_document(rebase_binding))
    rebase_binding_bytes = module._canonical_json(rebase_binding)
    rebase_terminal = module.capture_ci_terminal(
        launch_binding=rebase_binding_bytes, edge_id="review_pr.ci.rebase")

    # THE LEASE. It never enters the script and is never taken from the child:
    # it is read back out of the pinned authority and compared to the remote tip
    # the CONTROLLER observed, BEFORE the controller pushes.
    assert module.read_ci_authority_member(
        authority_path=rebase_receipt["authority_path"],
        authority_sha256=rebase_receipt["authority_sha256"],
        member="lease_sha") == lease_sha
    (ci_repo / "src/app.py").write_text("APP = 9\n", encoding="utf-8")
    git(ci_repo, "add", "--", "src/app.py")
    git(ci_repo, "commit", "-qm", "fix(ci): rebased tip")
    rebased_head = git(ci_repo, "rev-parse", "HEAD").stdout.decode().strip()

    def rebase_outcome(**overrides):
        arguments = dict(
            launch_binding=rebase_binding_bytes,
            status_sha256=rebase_terminal["status_sha256"],
            result_sha256=rebase_terminal["result_sha256"],
            working_dir=str(ci_repo), head_before=ci_head,
            head_after=rebased_head, remote_head_sha=lease_sha,
        )
        arguments.update(overrides)
        return module.validate_ci_mutation_outcome(**arguments)

    assert rebase_outcome()["status"] == "REBASED", rebase_outcome()
    # If the child pushed anyway, the remote tip no longer equals the lease and
    # the controller refuses BEFORE its own push. This is what makes the
    # agent's demotion from pusher to preparer enforceable, not aspirational.
    expect_contract_reason(
        lambda: rebase_outcome(remote_head_sha="c" * 40),
        "ci_rebase_remote_moved_during_child",
    )
    expect_contract_reason(
        lambda: rebase_outcome(head_after=ci_head),
        "ci_rebase_head_did_not_move",
    )
    git(ci_repo, "reset", "-q", "--hard", ci_head)

    # ---- CLI reachability: a verb with no subparser is dead code ------------
    ci_cli = module._parser()
    for verb, argv in (
        ("prepare-ci-authority", [
            "prepare-ci-authority", "--edge-id", "review_pr.ci.classify",
            "--pr-number", "41", "--run-id", "77", "--head-sha", ci_head,
            "--working-dir", str(ci_repo), "--input-path", str(ci_log),
            "--input-sha256", ci_log_sha,
            "--authority-output-path", str(ci_evidence / "x.json")]),
        ("bind-workflow-ci-launch", [
            "bind-workflow-ci-launch", "--edge-id", "review_pr.ci.classify",
            "--instance-id", "ci-classify-ci01-iter01", "--run-nonce", CI_NONCE,
            "--result-path", str(classify_child / "result.md"),
            "--status-path", str(classify_child / "status.json"),
            "--working-dir", str(ci_repo),
            "--ci-authority-path", classify_receipt["authority_path"],
            "--ci-authority-sha256", classify_receipt["authority_sha256"]]),
        ("capture-ci-terminal", [
            "capture-ci-terminal", "--edge-id", "review_pr.ci.classify",
            "--launch-binding-json", classify_binding_bytes.decode()]),
        ("read-ci-authority-member", [
            "read-ci-authority-member",
            "--authority-path", classify_receipt["authority_path"],
            "--authority-sha256", classify_receipt["authority_sha256"],
            "--member", "run_id"]),
        ("validate-ci-classification", [
            "validate-ci-classification",
            "--launch-binding-json", classify_binding_bytes.decode(),
            "--status-sha256", "0" * 64, "--result-sha256", "0" * 64]),
        ("validate-ci-mutation-outcome", [
            "validate-ci-mutation-outcome",
            "--launch-binding-json", fix_binding_bytes.decode(),
            "--status-sha256", "0" * 64, "--result-sha256", "0" * 64,
            "--working-dir", str(ci_repo), "--head-before", ci_head,
            "--head-after", ci_head, "--remote-head-sha", ""]),
        ("validate-ci-persistence-result", [
            "validate-ci-persistence-result",
            "--launch-binding-json", classify_binding_bytes.decode(),
            "--status-sha256", "0" * 64, "--result-sha256", "0" * 64]),
    ):
        parsed = ci_cli.parse_args(argv)
        assert parsed.command == verb, parsed

# === #383 follow-up: the CONFLICT arm judged against a REAL conflicted rebase ==
#
# Everything above judges the rebase arm on a repository that is NOT mid-rebase,
# which is the one state the CONFLICT terminal never occupies. That is why the
# arm shipped unreachable: `_validate_ci_rebase_outcome` ended in
# `_ci_require_residue_closed`, and the mid-rebase index the design REQUIRES the
# child to leave behind (agents/ci-rebase-handler.md Step 5: "leave the rebase
# IN PROGRESS") is `index_dirty` by that predicate. So this block builds the
# real thing — two divergent commits over one line, `git rebase` run to its
# actual conflict — and drives the PUBLIC verb over it.
#
# The evidence directory is deliberately NOT ignored here. The uberdev
# repository lists `.uberdev/` in its own .gitignore, so `ls-files --others`
# returns nothing and every untracked-path check is vacuous against it. A
# consumer repository has no such line, and that is the shape these rows model.
with scratch_dir("code-fixer-ci-conflict-") as temporary:
    cf_repo = pathlib.Path(temporary) / "repo"
    cf_repo.mkdir()
    git(cf_repo, "init", "-q", "-b", "main")
    git(cf_repo, "config", "user.email", "fixture@example.invalid")
    git(cf_repo, "config", "user.name", "Fixture")
    (cf_repo / "src").mkdir()
    (cf_repo / "src/app.py").write_text("APP = 0\n", encoding="utf-8")
    # A SECOND tracked file neither side touches. Without one, "a tracked path
    # edited outside the conflict set" cannot be modelled at all: the only
    # tracked file would be the unmerged one.
    (cf_repo / "src/keep.py").write_text("KEEP = 1\n", encoding="utf-8")
    # A THIRD tracked file, at the repository root, whose name carries a SPACE
    # AT OFFSET 2. The branch renames it, so `git status --porcelain -z` emits
    # `R  renamed.md\0my file.md\0` mid-rebase — two NUL-terminated fields for
    # one entry, the second a bare pathname with no XY prefix. A parser that
    # splits on NUL alone reads `my file.md` as a status record: X='m', Y='y',
    # offset 2 is the space every real record has there, and the dirty-path set
    # gains `file.md` — a path that does not exist. The whole CONFLICT arm then
    # refuses `ci_rebase_conflict_scope_escape` on a clean conflicted rebase.
    (cf_repo / "my file.md").write_text("RENAME ME\n", encoding="utf-8")
    git(cf_repo, "add", "--", "src/app.py", "src/keep.py", "my file.md")
    git(cf_repo, "commit", "-qm", "test: conflict fixture base")
    cf_fork = git(cf_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # main advances over the same line the branch will touch.
    (cf_repo / "src/app.py").write_text("APP = 'main'\n", encoding="utf-8")
    git(cf_repo, "commit", "-qam", "test: main advances")
    cf_base = git(cf_repo, "rev-parse", "HEAD").stdout.decode().strip()
    git(cf_repo, "checkout", "-q", "-b", "fix/383-conflict", cf_fork)
    (cf_repo / "src/app.py").write_text("APP = 'branch'\n", encoding="utf-8")
    # The rename rides the SAME commit as the conflicting edit, so it is part of
    # what `git rebase` replays and is present in the porcelain stream at the
    # moment every CONFLICT-terminal predicate below reads it.
    git(cf_repo, "mv", "my file.md", "renamed.md")
    git(cf_repo, "commit", "-qam", "test: branch diverges")
    cf_head = git(cf_repo, "rev-parse", "HEAD").stdout.decode().strip()

    cf_evidence = cf_repo / ".uberdev/research/20260806-111111-beef111"
    (cf_evidence / "children").mkdir(parents=True)

    def cf_child(slug):
        target = cf_evidence / "children" / slug
        target.mkdir(exist_ok=True)
        return target

    def cf_input(child, payload):
        path = child / "input.json"
        path.write_bytes(payload)
        return str(path), hashlib.sha256(payload).hexdigest()

    def cf_bind(edge, slug, authority_receipt):
        child = cf_child(slug)
        binding = module.bind_workflow_ci_launch(
            edge_id=edge, instance_id=slug, run_nonce=CI_NONCE,
            result_path=str(child / "result.md"),
            status_path=str(child / "status.json"), working_dir=str(cf_repo),
            ci_authority_path=authority_receipt["authority_path"],
            ci_authority_sha256=authority_receipt["authority_sha256"])
        (child / "result.md").write_bytes(b"child report\n")
        (child / "status.json").write_bytes(ci_status_document(binding))
        payload = module._canonical_json(binding)
        terminal = module.capture_ci_terminal(launch_binding=payload, edge_id=edge)
        return payload, terminal

    # ---- the rebase arm's CONFLICT terminal --------------------------------
    rb_child = cf_child("ci-rebase-ci01-iter01")
    rb_input, rb_input_sha = cf_input(rb_child, b'{"edge":"rebase"}\n')
    rb_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
        head_sha=cf_head, working_dir=str(cf_repo), input_path=rb_input,
        input_sha256=rb_input_sha, base_sha=cf_base, base_tip_sha=cf_base,
        lease_sha=cf_head,
        pr_branch="fix/383-conflict", base_branch="main",
        authority_output_path=str(
            cf_evidence / "ci-authority-rebase-iter01-ci01.json"))
    rb_binding_bytes, rb_terminal = cf_bind(
        "review_pr.ci.rebase", "ci-rebase-ci01-iter01", rb_receipt)

    rebase_run = git(cf_repo, "rebase", "main", check=False)
    assert rebase_run.returncode != 0, "the fixture rebase was expected to conflict"
    cf_mid_head = git(cf_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert b"UU src/app.py" in git(
        cf_repo, "status", "--porcelain").stdout, "no unmerged path in the fixture"
    # The fixture must really produce the two-field rename entry, or every row
    # that depends on it below is vacuous.
    cf_porcelain = git(cf_repo, "status", "--porcelain", "-z").stdout
    assert b"my file.md\x00" in cf_porcelain, cf_porcelain
    assert b"R" == cf_porcelain[:1], cf_porcelain
    assert module._ci_worktree_dirty_paths(str(cf_repo)) == (), (
        "a rename ORIGIN path was parsed as a status record")
    assert module._ci_unmerged_paths(str(cf_repo)) == ("src/app.py",), (
        module._ci_unmerged_paths(str(cf_repo)))

    def rb_outcome(**overrides):
        arguments = dict(
            launch_binding=rb_binding_bytes,
            status_sha256=rb_terminal["status_sha256"],
            result_sha256=rb_terminal["result_sha256"],
            working_dir=str(cf_repo), head_before=cf_head,
            head_after=cf_mid_head, remote_head_sha=cf_head)
        arguments.update(overrides)
        return module.validate_ci_mutation_outcome(**arguments)

    # THE regression: the terminal the whole CONFLICT-RESOLVE arm hangs off.
    conflict_terminal = rb_outcome()
    assert conflict_terminal["status"] == "CONFLICT", conflict_terminal
    # The lease is NOT relaxed mid-rebase. A child that pushed anyway is still
    # refused before the controller's own push, conflicts or not.
    expect_contract_reason(
        lambda: rb_outcome(remote_head_sha="c" * 40),
        "ci_rebase_remote_moved_during_child",
    )
    # ci_rebase_base_not_ancestor — the ONLY ancestry proof before a force-push,
    # and it had zero assertions anywhere. `cf_fork` predates the pinned base, so
    # a HEAD sitting there is not the result of rebasing onto it. Ordered before
    # the CONFLICT short-circuit on purpose: a mid-rebase state must not buy an
    # exemption from ancestry.
    expect_contract_reason(
        lambda: rb_outcome(head_after=cf_fork), "ci_rebase_base_not_ancestor")

    # ---- the CONFLICT terminal's own residue proof -------------------------
    # It returns BEFORE _ci_require_residue_closed (a conflicted rebase has
    # unmerged index entries by construction, which that predicate calls
    # index_dirty), and for one revision that left the CONFLICT path as the only
    # mutating CI terminal with NO worktree proof at all — while ending in the
    # same leased force-push as the other two. Two halves, both sound mid-rebase.
    (cf_repo / "src/dropped.py").write_text("DROPPED = 1\n", encoding="utf-8")
    expect_contract_reason(rb_outcome, "ci_rebase_conflict_scope_escape")
    (cf_repo / "src/dropped.py").unlink()
    assert rb_outcome()["status"] == "CONFLICT"
    # A TRACKED file edited outside the conflict set: git's replay STAGES every
    # path it merged cleanly, so a worktree-vs-index divergence outside the
    # unmerged entries is somebody's hand edit — the one that used to ride
    # `rebase --continue` onto the remote with every equality still verified.
    cf_keep_bytes = (cf_repo / "src/keep.py").read_bytes()
    (cf_repo / "src/keep.py").write_text("KEEP = 'tampered'\n", encoding="utf-8")
    expect_contract_reason(rb_outcome, "ci_rebase_conflict_scope_escape")
    (cf_repo / "src/keep.py").write_bytes(cf_keep_bytes)
    assert rb_outcome()["status"] == "CONFLICT"
    # ...and the UU path itself is NEVER the escapee: the resolver rewrites it
    # in place and never stages it, so a predicate that read `UU` as "dirty"
    # would refuse every correct resolution.
    cf_app_conflicted = (cf_repo / "src/app.py").read_bytes()
    (cf_repo / "src/app.py").write_text("APP = 'resolved'\n", encoding="utf-8")
    assert rb_outcome()["status"] == "CONFLICT"
    (cf_repo / "src/app.py").write_bytes(cf_app_conflicted)

    # ---- one resolver, resolved IN PLACE and deliberately NOT staged -------
    # agents/conflict-resolver.md and the ci-conflicts prompt both forbid
    # `git add`; the controller stages only after this judgement returns. A
    # validator that refused an unmerged index would therefore refuse every
    # resolver that obeyed its instructions.
    rs_child = cf_child("ci-conflict-01-ci01")
    rs_input, rs_input_sha = cf_input(rs_child, b'{"file":"src/app.py"}\n')
    rs_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.resolve_conflict", pr_number=41, run_id="77",
        head_sha=cf_head, working_dir=str(cf_repo), input_path=rs_input,
        input_sha256=rs_input_sha, base_sha=cf_base,
        pr_branch="fix/383-conflict", base_branch="main",
        target_paths=("src/app.py",),
        authority_output_path=str(
            cf_evidence / "ci-authority-resolve-conflict-iter01-ci01-1.json"))
    rs_binding_bytes, rs_terminal = cf_bind(
        "review_pr.ci.resolve_conflict", "ci-conflict-01-ci01", rs_receipt)

    def rs_outcome():
        return module.validate_ci_mutation_outcome(
            launch_binding=rs_binding_bytes,
            status_sha256=rs_terminal["status_sha256"],
            result_sha256=rs_terminal["result_sha256"],
            working_dir=str(cf_repo), head_before=cf_mid_head,
            head_after=cf_mid_head, remote_head_sha="")

    # Still carrying git's markers: unresolved, whatever the child claimed.
    assert b"<<<<<<<" in (cf_repo / "src/app.py").read_bytes()
    expect_contract_reason(rs_outcome, "ci_conflict_unresolved")

    (cf_repo / "src/app.py").write_text("APP = 'merged'\n", encoding="utf-8")
    resolved = rs_outcome()
    assert resolved["status"] == "RESOLVED", resolved
    assert resolved["run_nonce"] == CI_NONCE, resolved
    # And the run's own untracked evidence tree is NOT scope escape: every path
    # above lives under .uberdev/research/<run>/ and none of it is ignored here.
    assert git(cf_repo, "ls-files", "--others", "--exclude-standard",
               "--", ".uberdev").stdout, "the fixture evidence tree is not untracked"

    # `conflict-marker-size` is a per-path gitattribute, so seven is a DEFAULT
    # and not a guarantee. At size 10 git writes `<<<<<<<<<< HEAD`, and a
    # boundary test pinned to a fixed seven-character marker read offset 7 as
    # `<` rather than a space — so the predicate said "no markers", the arm
    # returned RESOLVED for a file still holding a raw conflict hunk, and the
    # controller staged it and force-pushed it.
    (cf_repo / "src/app.py").write_text(
        "<" * 10 + " HEAD\n"
        "APP = 'ours'\n"
        + "=" * 10 + "\n"
        "APP = 'theirs'\n"
        + ">" * 10 + " fix/383-conflict\n",
        encoding="utf-8",
    )
    expect_contract_reason(rs_outcome, "ci_conflict_unresolved")
    (cf_repo / "src/app.py").write_text("APP = 'merged'\n", encoding="utf-8")
    assert rs_outcome()["status"] == "RESOLVED"

    # A resolver that deleted its file has not resolved it.
    (cf_repo / "src/app.py").unlink()
    expect_contract_reason(rs_outcome, "ci_conflict_unresolved")
    (cf_repo / "src/app.py").write_text("APP = 'merged'\n", encoding="utf-8")
    assert rs_outcome()["status"] == "RESOLVED"

    # A NEW untracked file outside the evidence tree is still scope escape.
    (cf_repo / "src/invented.py").write_text("INVENTED = 1\n", encoding="utf-8")
    expect_contract_reason(rs_outcome, "ci_conflict_scope_escape")
    (cf_repo / "src/invented.py").unlink()
    assert rs_outcome()["status"] == "RESOLVED"

    # A BINARY conflict has no liveness signal at all. git records `UU` for it
    # but writes the "ours" blob to the worktree with NO markers, so the marker
    # scan judges a resolver that did nothing identical to one that resolved —
    # and conflict-resolver.md cannot merge a binary either. Passing it RESOLVED
    # staged "ours", committed it, and force-pushed the base branch's version of
    # the binary silently discarded. The honest terminal is a refusal.
    (cf_repo / "src/app.py").write_bytes(b"\x89PNG\r\x1a\n\x00\x00\x00binary\n")
    expect_contract_reason(rs_outcome, "ci_conflict_binary_unresolvable")
    (cf_repo / "src/app.py").write_text("APP = 'merged'\n", encoding="utf-8")
    assert rs_outcome()["status"] == "RESOLVED"

    # ---- and the clean-rebase terminal is unchanged ------------------------
    # Widening the rebase arm must not turn a NON-conflicted rebase into a
    # CONFLICT, and must not stop refusing a dirty index outside a rebase. This
    # row doubles as the evidence-exemption proof for the CLEAN path: the whole
    # .uberdev/research tree above is untracked and NOT ignored here, so a
    # residue predicate that exempted only the child's own directory would
    # refuse a perfectly clean rebase over a sibling child's `input.json`.
    git(cf_repo, "rebase", "--abort", check=False)
    git(cf_repo, "checkout", "-q", "-B", "fix/383-clean", cf_fork)
    (cf_repo / "src/other.py").write_text("OTHER = 1\n", encoding="utf-8")
    git(cf_repo, "add", "--", "src/other.py")
    git(cf_repo, "commit", "-qm", "test: a non-conflicting branch commit")
    git(cf_repo, "rebase", "main")
    cf_clean_head = git(cf_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert not module._ci_rebase_dir(str(cf_repo)), "the clean rebase left state behind"
    clean = rb_outcome(head_after=cf_clean_head)
    assert clean["status"] == "REBASED", clean
    (cf_repo / "src/other.py").write_text("OTHER = 2\n", encoding="utf-8")
    git(cf_repo, "add", "--", "src/other.py")
    expect_contract_reason(
        lambda: rb_outcome(head_after=cf_clean_head), "index_dirty")
    git(cf_repo, "reset", "-q", "--hard", cf_clean_head)
    # An untracked file outside the evidence tree still fails the clean path.
    (cf_repo / "src/stray.py").write_text("STRAY = 1\n", encoding="utf-8")
    expect_contract_reason(
        lambda: rb_outcome(head_after=cf_clean_head), "worktree_untracked")
    (cf_repo / "src/stray.py").unlink()

    # ---- ci_conflict_not_mid_rebase ---------------------------------------
    # The ONLY thing stopping a resolver terminal from being judged after the
    # rebase has been aborted or completed — and it had zero assertions
    # anywhere, so reordering the CONFLICT terminal above it, or dropping the
    # `_ci_rebase_dir` precondition, left the whole suite green. The rebase was
    # aborted above; the very same binding must now refuse.
    assert not module._ci_rebase_dir(str(cf_repo)), "the fixture is still mid-rebase"
    expect_contract_reason(rs_outcome, "ci_conflict_not_mid_rebase")

    # ---- ci_mutation_edge_unsupported -------------------------------------
    # A read-only CI edge routed into the MUTATING verb. Also uncovered.
    cy_child = cf_child("ci-classify-ci01-iter01")
    cy_input, cy_input_sha = cf_input(cy_child, b'{"edge":"classify"}\n')
    cy_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
        head_sha=cf_head, working_dir=str(cf_repo), input_path=cy_input,
        input_sha256=cy_input_sha,
        authority_output_path=str(
            cf_evidence / "ci-authority-classify-iter01-ci01.json"))
    cy_binding_bytes, cy_terminal = cf_bind(
        "review_pr.ci.classify", "ci-classify-ci01-iter01", cy_receipt)
    expect_contract_reason(
        lambda: module.validate_ci_mutation_outcome(
            launch_binding=cy_binding_bytes,
            status_sha256=cy_terminal["status_sha256"],
            result_sha256=cy_terminal["result_sha256"],
            working_dir=str(cf_repo), head_before=cf_head,
            head_after=cf_clean_head, remote_head_sha=""),
        "ci_mutation_edge_unsupported",
    )

    # ---- the remaining CI terminals nothing asserted anywhere --------------
    # Every one of these was reachable and correct, and every one of them could
    # have been deleted without reddening a single row.
    expect_contract_reason(
        lambda: module.capture_ci_terminal(
            launch_binding=cy_binding_bytes, edge_id="review_pr.fix.phase1"),
        "ci_terminal_edge_unsupported",
    )
    expect_contract_reason(
        lambda: module.validate_ci_mutation_outcome(
            launch_binding=rb_binding_bytes,
            status_sha256=rb_terminal["status_sha256"],
            result_sha256=rb_terminal["result_sha256"],
            working_dir="", head_before=cf_head, head_after=cf_clean_head,
            remote_head_sha=cf_head),
        "working_dir_invalid",
    )
    expect_contract_reason(
        lambda: module.validate_residue(
            working_dir=str(cf_repo), evidence_dir=str(cf_repo)),
        "evidence_dir_invalid",
    )
    # An authority pathname outside the worktree, and one whose basename does
    # not carry the edge/iteration key the whole run tree is indexed by.
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
            head_sha=cf_head, working_dir=str(cf_repo), input_path=cy_input,
            input_sha256=cy_input_sha,
            authority_output_path=str(pathlib.Path(temporary) / "outside.json")),
        "ci_authority_path_invalid",
    )
    expect_contract_reason(
        lambda: module.prepare_ci_authority(
            edge_id="review_pr.ci.classify", pr_number=41, run_id="77",
            head_sha=cf_head, working_dir=str(cf_repo), input_path=cy_input,
            input_sha256=cy_input_sha,
            authority_output_path=str(cf_evidence / "ci-authority-classify.json")),
        "ci_authority_path_invalid",
    )
    # ci_classification_log_mismatch — the classifier's pinned input IS the
    # fetched GH-Actions log, and a GH-Actions log is fetched once and is
    # unreachable afterwards. If those bytes moved, the classification was made
    # against something other than what the controller froze.
    cy_status_sha = module.capture_ci_terminal(
        launch_binding=cy_binding_bytes,
        edge_id="review_pr.ci.classify")["status_sha256"]
    cy_result_sha = module.capture_ci_terminal(
        launch_binding=cy_binding_bytes,
        edge_id="review_pr.ci.classify")["result_sha256"]
    pathlib.Path(cy_input).write_bytes(b'{"edge":"classify-TAMPERED"}\n')
    expect_contract_reason(
        lambda: module.validate_ci_classification(
            launch_binding=cy_binding_bytes,
            status_sha256=cy_status_sha, result_sha256=cy_result_sha),
        "ci_classification_log_mismatch",
    )
    pathlib.Path(cy_input).write_bytes(b'{"edge":"classify"}\n')

    # ---- validate_ci_persistence_result: the fifth edge's own terminal -----
    # It shipped with argparse reachability only (`parse_args(...).command ==
    # verb`), so the suite could not tell a correct judge from one that returned
    # DONE for a REFUSED child — which is exactly what the controller routes the
    # CI-REFUSED halt on. `persistence_result_refused` had 0 mentions in any
    # test.
    dr_child = cf_child("ci-defer-ci01-iter01")
    dr_input, dr_input_sha = cf_input(dr_child, b'{"edge":"defer"}\n')
    dr_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.defer_refusal", pr_number=41, run_id="77",
        head_sha=cf_head, working_dir=str(cf_repo), input_path=dr_input,
        input_sha256=dr_input_sha,
        authority_output_path=str(
            cf_evidence / "ci-authority-defer-refusal-iter01-ci01.json"))
    dr_binding_bytes, _dr_terminal = cf_bind(
        "review_pr.ci.defer_refusal", "ci-defer-ci01-iter01", dr_receipt)

    def dr_outcome(document):
        result_path = cf_child("ci-defer-ci01-iter01") / "result.md"
        payload = document.encode("utf-8")
        result_path.write_bytes(payload)
        terminal = module.capture_ci_terminal(
            launch_binding=dr_binding_bytes, edge_id="review_pr.ci.defer_refusal")
        return module.validate_ci_persistence_result(
            launch_binding=dr_binding_bytes,
            status_sha256=terminal["status_sha256"],
            result_sha256=terminal["result_sha256"])

    dr_done = dr_outcome(persistence_result("DONE"))
    assert dr_done["status"] == "DONE", dr_done
    # realpath on both sides: prepare_ci_authority canonicalises, and macOS
    # resolves /var -> /private/var under a mktemp fixture.
    assert (os.path.realpath(dr_done["aggregate_path"])
            == os.path.realpath(dr_input)), dr_done
    assert dr_done["run_nonce"] == CI_NONCE, dr_done
    dr_halted = dr_outcome(persistence_result("DONE", halted=True, blocker_count=2))
    assert dr_halted["halted"] is True and dr_halted["by_severity_blocker"] == 2, dr_halted
    expect_contract_reason(
        lambda: dr_outcome(persistence_result("REFUSED")),
        "persistence_result_refused")
    # ...and it must NOT inherit validate_persistence_result's schema-v2
    # blocker recount: this stage's aggregate is the one-row ci-refused-synthetic
    # envelope, which that recount cannot parse. A document with no fence is
    # still malformed, though.
    expect_contract_reason(
        lambda: dr_outcome("no fence at all\n"), "persistence_result_malformed")

    # ---- created_urls[0].url, the ci-defer arm's ONE output ----------------
    # The ci-defer prose says "the caller captures … CI_REFUSED_ISSUE_URL from
    # created_urls[0].url", and this receipt carried no URL at all — so the only
    # two sites that ever assigned it were the arm's MALFORMED branches. The
    # halt prose's `filed issue:` line and `phases.phase3.ci_refused_issue_url`
    # therefore named an unbound variable exactly when the filing had WORKED.
    assert dr_done["created_url"] == "", dr_done

    def dr_with_urls(entries):
        return dr_outcome(
            persistence_result("DONE", halted=True, blocker_count=0).replace(
                "created_urls: []\n", "created_urls:\n" + entries, 1
            ).replace("halted: true", "halted: false")
        )

    filed = dr_with_urls(
        '  - { url: "https://github.com/TheFJK/TurboDev/issues/383", '
        'file: "src/app.py:1", fingerprint: "abc1234567890def", tier: "CRITICAL" }\n'
    )
    assert filed["created_url"] == "https://github.com/TheFJK/TurboDev/issues/383", filed
    # FIRST entry, not last: the arm files exactly one issue and the prose says
    # `created_urls[0]`.
    two = dr_with_urls(
        '  - { url: "https://github.com/TheFJK/TurboDev/issues/383", tier: "CRITICAL" }\n'
        '  - { url: "https://github.com/TheFJK/TurboDev/issues/999", tier: "CRITICAL" }\n'
    )
    assert two["created_url"] == "https://github.com/TheFJK/TurboDev/issues/383", two
    # The value reaches operator-facing halt prose and the audit JSON from a
    # child that read untrusted CI logs, so anything but a real GitHub issue URL
    # is dropped rather than rendered.
    for hostile in (
        '  - { url: "javascript:alert(1)", tier: "CRITICAL" }\n',
        '  - { url: "https://evil.example/TheFJK/TurboDev/issues/1", tier: "CRITICAL" }\n',
        '  - { url: "https://github.com/TheFJK/TurboDev/issues/0", tier: "CRITICAL" }\n',
        '  - { url: "https://github.com/../../issues/1", tier: "CRITICAL" }\n',
    ):
        assert dr_with_urls(hostile)["created_url"] == "", hostile

# === #438: the rebase guard was BASE-TIP-BLIND ================================
#
# `_validate_ci_rebase_outcome` asserted `merge-base --is-ancestor
# authority["base_sha"] head_after`, and `base_sha` is the MERGE-BASE that
# commands/review-pr.md 6c.4 ROUTE pins before dispatch. That is the wrong noun.
# The child's own instruction is `git rebase "origin/$base_branch"`
# (agents/ci-rebase-handler.md Step 4), so the value that proves where the
# rebase LANDED is the base branch's TIP.
#
# The difference only becomes visible once the base branch is itself rewritten —
# which is exactly the state the missing dependent-PR gate (#438 half one) lets
# Phase 3 manufacture. After `fix/a` is force-pushed, merge-base(fix/b, fix/a)
# collapses to the shared `main` fork point, and EVERY candidate rebase target
# contains that fork point. The assertion is then satisfied unconditionally: a
# rebase onto `main` — which detaches `fix/b` from its stack and duplicates
# `fix/a`'s commits into its diff — passes identically to the correct one.
#
# This fixture reproduces that topology exactly and drives the PUBLIC verb over
# both outcomes with the SAME authority. The base-tip assertion is what has to
# discriminate; `base_sha` ancestry must still be checked ALONGSIDE it, never
# replaced by it, so the row below asserts the old refusal still fires too.
with scratch_dir("code-fixer-ci-stack438-") as temporary:
    st_repo = pathlib.Path(temporary) / "repo"
    st_repo.mkdir()
    git(st_repo, "init", "-q", "-b", "main")
    git(st_repo, "config", "user.email", "fixture@example.invalid")
    git(st_repo, "config", "user.name", "Fixture")
    (st_repo / "m.txt").write_text("m0\n", encoding="utf-8")
    git(st_repo, "add", "--", "m.txt")
    git(st_repo, "commit", "-qm", "test: m0")
    st_m0 = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    (st_repo / "m.txt").write_text("m1\n", encoding="utf-8")
    git(st_repo, "commit", "-qam", "test: m1")
    st_fork = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # fix/a — the base branch of the PR under repair. Two commits, on their own
    # file, so nothing below conflicts and every refusal is about ANCESTRY.
    git(st_repo, "checkout", "-q", "-b", "fix/a", st_fork)
    (st_repo / "a.txt").write_text("A1\n", encoding="utf-8")
    git(st_repo, "add", "--", "a.txt")
    git(st_repo, "commit", "-qm", "test: A1")
    (st_repo / "a.txt").write_text("A2\n", encoding="utf-8")
    git(st_repo, "commit", "-qam", "test: A2")
    st_a_old = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # fix/b — the PR Phase 3 is repairing. It is STACKED on fix/a.
    git(st_repo, "checkout", "-q", "-b", "fix/b", st_a_old)
    (st_repo / "b.txt").write_text("B1\n", encoding="utf-8")
    git(st_repo, "add", "--", "b.txt")
    git(st_repo, "commit", "-qm", "test: B1")
    st_b_before = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # THE STACK-BREAKING REWRITE. main advances, fix/a is rebased onto it — the
    # push #438 half one refuses to make, modelled here as the state half two
    # must be able to police.
    git(st_repo, "checkout", "-q", "main")
    (st_repo / "m.txt").write_text("m2\n", encoding="utf-8")
    git(st_repo, "commit", "-qam", "test: m2")
    st_main_tip = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    git(st_repo, "checkout", "-q", "fix/a")
    git(st_repo, "rebase", "-q", "main")
    # A commit that exists ONLY on the rewritten fix/a. Without it the fixture is
    # a coin flip: rebasing fix/b onto main replays A1 and A2 onto the same
    # parent, with the same trees, author and (usually) the same committer
    # second — so the replayed commits can hash IDENTICALLY to fix/a's own, and
    # the tip becomes an ancestor of the detached head by accident. The row below
    # asserts the topology it depends on, so that can never silently return.
    (st_repo / "a.txt").write_text("A3\n", encoding="utf-8")
    git(st_repo, "commit", "-qam", "test: A3, only on the rewritten fix/a")
    st_a_tip = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert st_a_tip != st_a_old, "the fixture rewrite did not move fix/a"
    # The merge-base has now collapsed to the shared main fork point, which is
    # the whole defect. Assert it, or every row below is vacuous.
    st_merge_base = git(
        st_repo, "merge-base", "fix/b", "fix/a").stdout.decode().strip()
    assert st_merge_base == st_fork, (st_merge_base, st_fork, st_a_tip)

    st_evidence = st_repo / ".uberdev/research/20260810-121212-438f438"
    st_child = st_evidence / "children" / "ci-rebase-ci01-iter01"
    st_child.mkdir(parents=True)
    st_input = st_child / "input.json"
    st_input_bytes = b'{"edge":"rebase"}\n'
    st_input.write_bytes(st_input_bytes)
    st_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.rebase", pr_number=438, run_id="77",
        head_sha=st_b_before, working_dir=str(st_repo), input_path=str(st_input),
        input_sha256=hashlib.sha256(st_input_bytes).hexdigest(),
        # EXACTLY what review-pr.md:4166 pins — a merge-base, not a tip.
        base_sha=st_merge_base, base_tip_sha=st_a_tip, lease_sha=st_b_before,
        pr_branch="fix/b", base_branch="fix/a",
        authority_output_path=str(
            st_evidence / "ci-authority-rebase-iter01-ci01.json"))
    # Both proofs are readable back out of the digest-pinned document, and they
    # are DIFFERENT values — the pin the shell reads at 6c.4w.3 is the tip.
    assert module.read_ci_authority_member(
        authority_path=st_receipt["authority_path"],
        authority_sha256=st_receipt["authority_sha256"],
        member="base_tip_sha") == st_a_tip
    assert module.read_ci_authority_member(
        authority_path=st_receipt["authority_path"],
        authority_sha256=st_receipt["authority_sha256"],
        member="base_sha") == st_merge_base
    st_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.rebase", instance_id="ci-rebase-ci01-iter01",
        run_nonce=CI_NONCE, result_path=str(st_child / "result.md"),
        status_path=str(st_child / "status.json"), working_dir=str(st_repo),
        ci_authority_path=st_receipt["authority_path"],
        ci_authority_sha256=st_receipt["authority_sha256"])
    (st_child / "result.md").write_bytes(b"rebased\n")
    (st_child / "status.json").write_bytes(ci_status_document(st_binding))
    st_binding_bytes = module._canonical_json(st_binding)
    st_terminal = module.capture_ci_terminal(
        launch_binding=st_binding_bytes, edge_id="review_pr.ci.rebase")

    def st_outcome(**overrides):
        arguments = dict(
            launch_binding=st_binding_bytes,
            status_sha256=st_terminal["status_sha256"],
            result_sha256=st_terminal["result_sha256"],
            working_dir=str(st_repo), head_before=st_b_before,
            remote_head_sha=st_b_before)
        arguments.update(overrides)
        return module.validate_ci_mutation_outcome(**arguments)

    # CASE 1 — the CORRECT rebase: fix/b onto the real base branch's tip.
    git(st_repo, "checkout", "-q", "fix/b")
    git(st_repo, "rebase", "-q", "fix/a")
    st_correct = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert git(
        st_repo, "rev-list", "--count", f"fix/a..{st_correct}"
    ).stdout.decode().strip() == "1", "the correct rebase should replay ONE commit"
    assert st_outcome(head_after=st_correct)["status"] == "REBASED", st_outcome(
        head_after=st_correct)

    # CASE 2 — the STACK-DETACHING rebase: fix/b onto main. It satisfies the
    # collapsed merge-base identically, moves HEAD, keeps the lease, leaves a
    # clean worktree, and duplicates fix/a's commits into the PR's own diff.
    git(st_repo, "checkout", "-q", "-B", "fix/b", st_b_before)
    git(st_repo, "rebase", "-q", "main")
    st_detached = git(st_repo, "rev-parse", "HEAD").stdout.decode().strip()
    assert git(
        st_repo, "rev-list", "--count", f"main..{st_detached}"
    ).stdout.decode().strip() == "3", (
        "the detaching rebase should replay A1+A2+B1 — three commits")
    # The OLD predicate cannot see it: base_sha ancestry passes for both.
    assert module._git(
        str(st_repo), "merge-base", "--is-ancestor", st_merge_base, st_detached
    ).returncode == 0, "the fixture no longer reproduces the collapsed merge-base"
    # ...and the topology the NEW one relies on really holds, so a replayed
    # commit that happened to hash back onto fix/a cannot make the row vacuous.
    assert module._git(
        str(st_repo), "merge-base", "--is-ancestor", st_a_tip, st_detached
    ).returncode != 0, "the detaching head still contains fix/a's tip"
    # The NEW one discriminates.
    expect_contract_reason(
        lambda: st_outcome(head_after=st_detached),
        "ci_rebase_base_tip_not_ancestor",
    )
    # ...and the merge-base proof is still CHECKED, not replaced: a head that
    # predates the pinned merge-base is still refused under its OWN reason, and
    # ordered FIRST, so the two proofs stay independently attributable in the
    # audit trail rather than collapsing into one.
    expect_contract_reason(
        lambda: st_outcome(head_after=st_m0), "ci_rebase_base_not_ancestor")

# === #383 follow-up: "unmerged" meant two different sets in one file ==========
#
# The block above conflicts on a path BOTH sides already tracked, which git
# records as `UU` — the one porcelain pair `_ci_unmerged_paths` recognised. Every
# other unmerged pair (`AA`, `DD`, `AU`, `UA`, `DU`, `UD`) was invisible to it,
# while `_ci_worktree_dirty_paths` ten lines away already knew the full set. So
# for an add/add rebase conflict the CONFLICT guard saw no unmerged paths at all,
# fell through to `_ci_require_residue_closed`, and refused `index_dirty` — the
# exact failure the CONFLICT terminal exists to prevent, and whose caller then
# runs `git rebase --abort` and destroys the mid-rebase state the CONFLICT-RESOLVE
# arm needs. A fresh repository rather than a new branch in the fixture above:
# the add/add conflict must be the ONLY unmerged entry, or a stray `UU` alongside
# it makes the row pass for the wrong reason.
with scratch_dir("code-fixer-ci-addadd-") as temporary:
    aa_repo = pathlib.Path(temporary) / "repo"
    aa_repo.mkdir()
    git(aa_repo, "init", "-q", "-b", "main")
    git(aa_repo, "config", "user.email", "fixture@example.invalid")
    git(aa_repo, "config", "user.name", "Fixture")
    (aa_repo / "src").mkdir()
    (aa_repo / "src/keep.py").write_text("KEEP = 1\n", encoding="utf-8")
    git(aa_repo, "add", "--", "src/keep.py")
    git(aa_repo, "commit", "-qm", "test: add/add fixture base")
    aa_fork = git(aa_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # BOTH sides create the same path with different content: neither side has a
    # common ancestor blob for it, which is what makes git record `AA` instead of
    # `UU`.
    (aa_repo / "src/collide.py").write_text("COLLIDE = 'main'\n", encoding="utf-8")
    git(aa_repo, "add", "--", "src/collide.py")
    git(aa_repo, "commit", "-qm", "test: main adds the colliding path")
    aa_base = git(aa_repo, "rev-parse", "HEAD").stdout.decode().strip()
    git(aa_repo, "checkout", "-q", "-b", "fix/383-addadd", aa_fork)
    (aa_repo / "src/collide.py").write_text("COLLIDE = 'branch'\n", encoding="utf-8")
    git(aa_repo, "add", "--", "src/collide.py")
    git(aa_repo, "commit", "-qm", "test: the branch adds it too")
    aa_head = git(aa_repo, "rev-parse", "HEAD").stdout.decode().strip()

    aa_evidence = aa_repo / ".uberdev/research/20260806-222222-face222"
    aa_child = aa_evidence / "children" / "ci-rebase-ci01-iter01"
    aa_child.mkdir(parents=True)
    aa_input = aa_child / "input.json"
    aa_input_bytes = b'{"edge":"rebase"}\n'
    aa_input.write_bytes(aa_input_bytes)
    aa_receipt = module.prepare_ci_authority(
        edge_id="review_pr.ci.rebase", pr_number=41, run_id="77",
        head_sha=aa_head, working_dir=str(aa_repo), input_path=str(aa_input),
        input_sha256=hashlib.sha256(aa_input_bytes).hexdigest(),
        base_sha=aa_base, base_tip_sha=aa_base, lease_sha=aa_head,
        pr_branch="fix/383-addadd", base_branch="main",
        authority_output_path=str(
            aa_evidence / "ci-authority-rebase-iter01-ci01.json"))
    aa_binding = module.bind_workflow_ci_launch(
        edge_id="review_pr.ci.rebase", instance_id="ci-rebase-ci01-iter01",
        run_nonce=CI_NONCE, result_path=str(aa_child / "result.md"),
        status_path=str(aa_child / "status.json"), working_dir=str(aa_repo),
        ci_authority_path=aa_receipt["authority_path"],
        ci_authority_sha256=aa_receipt["authority_sha256"])
    (aa_child / "result.md").write_bytes(b"left the rebase in progress\n")
    (aa_child / "status.json").write_bytes(ci_status_document(aa_binding))
    aa_binding_bytes = module._canonical_json(aa_binding)
    aa_terminal = module.capture_ci_terminal(
        launch_binding=aa_binding_bytes, edge_id="review_pr.ci.rebase")

    aa_rebase = git(aa_repo, "rebase", "main", check=False)
    assert aa_rebase.returncode != 0, "the add/add fixture rebase was expected to conflict"
    aa_mid_head = git(aa_repo, "rev-parse", "HEAD").stdout.decode().strip()
    # The fixture must really produce `AA`, and NO `UU` anywhere: a single `UU`
    # in the status satisfies the old two-byte filter too, which would make the
    # row below pass for the wrong reason. (`?? .uberdev/` is the run's own
    # untracked evidence tree, exempted by the residue half of the terminal.)
    aa_porcelain = git(aa_repo, "status", "--porcelain").stdout
    assert b"AA src/collide.py\n" in aa_porcelain, aa_porcelain
    assert b"UU " not in aa_porcelain, aa_porcelain
    assert module._ci_unmerged_paths(str(aa_repo)) == ("src/collide.py",), (
        module._ci_unmerged_paths(str(aa_repo)))

    aa_outcome = module.validate_ci_mutation_outcome(
        launch_binding=aa_binding_bytes,
        status_sha256=aa_terminal["status_sha256"],
        result_sha256=aa_terminal["result_sha256"],
        working_dir=str(aa_repo), head_before=aa_head,
        head_after=aa_mid_head, remote_head_sha=aa_head)
    assert aa_outcome["status"] == "CONFLICT", aa_outcome

    # === #398: the CONTROLLER's enumerator has to reach the same set ==========
    #
    # The judge above says CONFLICT for this `AA`. The shell side of the
    # CONFLICT-RESOLVE arm was hand-rolling `git status --porcelain | awk
    # '/^UU /'` to decide WHICH files to hand to conflict-resolver, so it
    # enumerated zero here and the arm resolved nothing. P1/P2 pin the CLI verb
    # that closes that gap. They live INSIDE this block, before the
    # `rebase --abort` below: after the abort the unmerged set is empty and both
    # rows would assert on `b""` and pass for the wrong reason. The block's own
    # `AA ... in aa_porcelain` / `UU  not in aa_porcelain` asserts above are
    # what keep them honest.
    #
    # P1 — the payload is exactly the one conflicted path, NUL-TERMINATED.
    assert run_bytes(
        ["list-ci-unmerged-paths", "--working-dir", str(aa_repo)]
    ).stdout == b"src/collide.py\x00"
    # P2 — and it is the SAME set the judge used, not a second opinion that
    # happens to agree today. This is the row that reds if anyone re-forks the
    # unmerged-pair vocabulary into the transport.
    assert run_bytes(
        ["list-ci-unmerged-paths", "--working-dir", str(aa_repo)]
    ).stdout == "".join(
        entry + "\x00" for entry in module._ci_unmerged_paths(str(aa_repo))
    ).encode("utf-8")

    git(aa_repo, "rebase", "--abort", check=False)


def conflicting_repo(root, colliding_path):
    """An add/add rebase left IN PROGRESS, colliding on `colliding_path`.

    Same recipe as the block above (both sides create the path, so there is no
    common ancestor blob and git records `AA`, not `UU`), reduced to just the
    git state: these rows exercise the enumerator, not the authority envelope.
    """
    repository = pathlib.Path(root) / "repo"
    repository.mkdir()
    git(repository, "init", "-q", "-b", "main")
    git(repository, "config", "user.email", "fixture@example.invalid")
    git(repository, "config", "user.name", "Fixture")
    (repository / "src").mkdir()
    (repository / "src/keep.py").write_text("KEEP = 1\n", encoding="utf-8")
    git(repository, "add", "--", "src/keep.py")
    git(repository, "commit", "-qm", "test: base")
    fork = git(repository, "rev-parse", "HEAD").stdout.decode().strip()
    (repository / colliding_path).write_text("COLLIDE = 'main'\n", encoding="utf-8")
    git(repository, "add", "--", colliding_path)
    git(repository, "commit", "-qm", "test: main adds the colliding path")
    git(repository, "checkout", "-q", "-b", "fix/398-collide", fork)
    (repository / colliding_path).write_text("COLLIDE = 'branch'\n", encoding="utf-8")
    git(repository, "add", "--", colliding_path)
    git(repository, "commit", "-qm", "test: the branch adds it too")
    rebase = git(repository, "rebase", "main", check=False)
    assert rebase.returncode != 0, "the add/add fixture rebase was expected to conflict"
    return repository


# P3 — a conflicted path containing a SPACE survives as ONE record. The retired
# `awk … {print $c2}` shape got this doubly wrong: non-`-z` porcelain C-QUOTES a
# spaced path (`AA "src/a b.py"`, asserted below) precisely because ` ` would
# otherwise be ambiguous with the rename arrow, and whitespace-splitting that
# line yields `"src/a`. The arm then handed a nonexistent pathspec to `git add`.
# `-z` porcelain — what `_ci_porcelain_entries` reads — is unquoted and
# unambiguous, which is why the answer has to come from there.
with scratch_dir("code-fixer-ci-spaced-") as temporary:
    spaced_repo = conflicting_repo(temporary, "src/a b.py")
    assert b'AA "src/a b.py"\n' in git(spaced_repo, "status", "--porcelain").stdout
    assert b"AA src/a b.py\x00" in git(spaced_repo, "status", "--porcelain", "-z").stdout
    assert run_bytes(
        ["list-ci-unmerged-paths", "--working-dir", str(spaced_repo)]
    ).stdout == b"src/a b.py\x00"
    git(spaced_repo, "rebase", "--abort", check=False)

# P4 — the empty set is the EMPTY payload, at rc 0. Terminated rather than
# joined precisely so this case has no representation of its own to confuse with
# "one empty path".
with scratch_dir("code-fixer-ci-clean-") as temporary:
    clean_repo = pathlib.Path(temporary) / "repo"
    clean_repo.mkdir()
    git(clean_repo, "init", "-q", "-b", "main")
    git(clean_repo, "config", "user.email", "fixture@example.invalid")
    git(clean_repo, "config", "user.name", "Fixture")
    (clean_repo / "keep.py").write_text("KEEP = 1\n", encoding="utf-8")
    git(clean_repo, "add", "--", "keep.py")
    git(clean_repo, "commit", "-qm", "test: base")
    assert git(clean_repo, "status", "--porcelain").stdout == b""
    assert run_bytes(
        ["list-ci-unmerged-paths", "--working-dir", str(clean_repo)]
    ).stdout == b""

# P5 — an unreadable git state fails LOUD. The whole point of routing the set
# through the contract is that "git could not answer" must not arrive at the
# shell wearing the same clothes as "no conflicts to resolve", so the one shape
# this must never produce is `(0, b"")`.
with scratch_dir("code-fixer-ci-nonrepo-") as temporary:
    unreadable = run_bytes(
        ["list-ci-unmerged-paths", "--working-dir", temporary], expected=74)
    assert unreadable.stdout == b"", unreadable.stdout
    assert unreadable.stderr == b"git_state_unreadable\n", unreadable.stderr
    # ...and through `run`, which owns the one-line/space-free/slash-free stderr
    # diagnostic shape every other rc-74 verb is held to.
    run(["list-ci-unmerged-paths", "--working-dir", temporary], expected=74)

# ---------------------------------------------------------------------------
# The fixer-result full-file boundary (#474)
# ---------------------------------------------------------------------------
#
# THE ACCEPTANCE CRITERION OF #474 ITSELF, which nothing pinned. `re.fullmatch`
# over the whole file is the ONLY thing between a fixer's titled report and a
# MUTATED_BLOCKED run: the child commits BEFORE its result is parsed, so a
# refusal here is not a retry, it is unattributable history plus an operator
# repair. The one pre-existing `fixer_result_invalid` row in the suite
# (tests/simplify-standalone-flow.test.sh) covers CRLF, so relaxing this
# `re.fullmatch` to `re.search` reopened #474 exactly, with CI fully green.
#
# THE DOCUMENT IS INSTANTIATED FROM THE SHIPPED CONTRACT, never retyped.
# shared/code-fixer-output-v1.md is what the child is told to obey, and on the
# ROUTED transport lib/child-dispatch.sh appends its bytes with no inline
# reinforcement while the contract claims it overrides the agent file's own
# sample. So a hand-written sample that agreed with the parser while the doc
# disagreed would be a green row sitting on top of the live defect — which is
# what shipped: the doc printed its document in a BARE fence the parser can
# never accept.
FIXER_CONTRACT_DOC = (root / "plugins/uberdev/shared/code-fixer-output-v1.md").read_text(
    encoding="utf-8"
)
fixer_fences = re.findall(r"(?m)^```(.*)$", FIXER_CONTRACT_DOC)
assert len(fixer_fences) == 2, f"expected one fenced block, saw {fixer_fences!r}"
assert fixer_fences[0] == "yaml", (
    "#474: the contract prints its own document in a ```"
    f"{fixer_fences[0]} fence, which _parse_fixer_result can never accept"
)
assert fixer_fences[1] == "", f"the closing fence carries an info string: {fixer_fences[1]!r}"
fixer_template = re.search(
    r"(?ms)^```yaml\n(.*?)\n```$", FIXER_CONTRACT_DOC
).group(1).split("\n")
# Exact line -> the concrete line that stands in for it. A template line that is
# neither literal nor listed here is a FAILURE, not a skip: that is what keeps
# this row honest when the contract's document grows a field.
FIXER_CONCRETE = {
    "status: APPLIED | NO_FIXES_NEEDED | REFUSED": "status: APPLIED",
    "phase: phase1 | phase2": "phase: phase2",
    "  - sha: <40-hex>": "  - sha: " + "a" * 40,
    "    type: fix | refactor": "    type: refactor",
    "    summary: <one-line>": "    summary: bounded authenticated refactor",
    "  - finding_index: <positive integer, 1-based, contiguous, in aggregate order>":
        "  - finding_index: 1",
    "    location: <path>:<line>": "    location: src/app.py:1",
    "    summary_sha256: <64-hex>": "    summary_sha256: " + "b" * 64,
    "    disposition: APPLIED | SKIPPED | REFUSED": "    disposition: APPLIED",
    "    behavior_tag: preserve | change | n/a": "    behavior_tag: preserve",
    "    reason: <short single-line prose, non-empty, no leading or trailing space>":
        "    reason: applied as scoped",
}
fixer_body_lines = []
for template_line in fixer_template:
    if template_line in FIXER_CONCRETE:
        fixer_body_lines.append(FIXER_CONCRETE[template_line])
        continue
    assert "<" not in template_line and " | " not in template_line, (
        f"#474: the contract's document grew an uninstantiated line: {template_line!r}"
    )
    fixer_body_lines.append(template_line)
assert len(FIXER_CONCRETE) == len(set(fixer_template) & set(FIXER_CONCRETE)), (
    "#474: a placeholder in FIXER_CONCRETE no longer appears in the contract — "
    "the substitution table has drifted from the document it instantiates"
)
FIXER_GOOD = "```yaml\n" + "\n".join(fixer_body_lines) + "\n```\n"
fixer_parsed = module._parse_fixer_result(
    FIXER_GOOD.encode("utf-8"), "phase2", "refactor"
)
assert fixer_parsed["status"] == "APPLIED", fixer_parsed
assert fixer_parsed["commits"][0]["sha"] == "a" * 40, fixer_parsed
assert fixer_parsed["rows"] == [
    {
        "finding_index": 1, "location": "src/app.py:1",
        "summary_sha256": "b" * 64, "disposition": "APPLIED",
        "behavior_tag": "preserve", "reason": "applied as scoped",
    }
], fixer_parsed
# THE RATCHET. Every one of these is accepted by `re.search` and refused by
# `re.fullmatch`, so each is a row that reds the instant the boundary is
# loosened. Trailing prose is the shape both observed #474 violations took;
# leading prose is the symmetric case the contract's own wording forbids
# ("nothing before the opening fence"); the bare opener is the shape the
# contract itself was printing.
for fixer_case, fixer_payload in (
    ("trailing-prose", FIXER_GOOD + "\nThat is the full set of changes.\n"),
    ("trailing-heading", FIXER_GOOD + "## Notes\n"),
    ("leading-prose", "# Refactor report\n\n" + FIXER_GOOD),
    ("leading-blank", "\n" + FIXER_GOOD),
    ("bare-opening-fence", FIXER_GOOD.replace("```yaml\n", "```\n", 1)),
):
    expect_contract_reason(
        lambda payload=fixer_payload: module._parse_fixer_result(
            payload.encode("utf-8"), "phase2", "refactor"
        ),
        "fixer_result_invalid",
    )

# ---------------------------------------------------------------------------
# The Phase 1 finding-verification gate (#431)
# ---------------------------------------------------------------------------
assert tuple(inspect.signature(module.project_verification_claims).parameters) == (
    "findings_path", "findings_sha256", "disposition_path", "disposition_sha256",
    "claims_dir",
)
assert tuple(inspect.signature(module.publish_verification).parameters) == (
    "findings_path", "findings_sha256", "disposition_path", "disposition_sha256",
    "verification_path", "threshold", "candidate",
)
# The claim card MUST NOT be able to carry the reviewer's reasoning, and the
# finding schema MUST NOT grow a sixth key to make room for a score.
assert module.CLAIM_KEYS == {"finding_index", "location", "summary"}
assert module.FINDING_KEYS == {
    "detail", "scope", "severity", "source_edges", "summary"
}
assert module.VERIFICATION_VERDICTS == {"SURVIVES", "CULLED"}
assert module.VERIFICATION_REASONS == {
    "reproduced-from-diff", "contradicted-by-diff", "pre-existing",
    "out-of-scope-line", "linter-domain", "gate-disabled",
    "over-cap-unverified", "verifier-unavailable",
}
assert not (module.VERIFICATION_CHILD_REASONS & module.VERIFICATION_CONTROLLER_REASONS)


def verification_fixture(temporary):
    """A Phase 1 aggregate + paired disposition with a known eligible roster."""
    evidence = pathlib.Path(temporary) / ".uberdev/research/20260810-101500-abcdef0"
    evidence.mkdir(parents=True)
    # Two eligible blockers (SKIPPED + REFUSED), one APPLIED blocker (not
    # eligible: already fixed in the branch), one suggestion (never a /goal
    # recursion target). Every detail carries the reviewer's own confidence
    # prefix, which is exactly the string the card must not leak.
    rows = [
        ("code-reviewer (correctness lens)", "blocker", "src/a.py", "42",
         "SKIPPED", "Unchecked index reads past the buffer",
         "confidence: 93 - the loop bound is len(rows) but the index is i + 1"),
        ("silent-failure-hunter", "blocker", "src/b.py", "7",
         "APPLIED", "Swallowed OSError hides a missing config",
         "confidence: 93 - the bare except returns None and the caller cannot tell"),
        ("comment-analyzer", "suggestion", "src/c.py", "9",
         "DEFERRED", "Comment describes the old signature",
         "confidence: 93 - the parameter was renamed two commits ago"),
        ("pr-test-analyzer", "blocker", "src/d.py", "13",
         "REFUSED", "New branch has no test",
         "confidence: 93 - the early-return path is unexercised"),
    ]
    findings = evidence / "post-impl-review-final.md"
    findings.write_bytes(phase1_table(rows))
    findings_sha = digest(findings)
    keys = module.parse_finding_keys(findings.read_bytes(), "phase1")
    dispositions = ["SKIPPED", "APPLIED", "SKIPPED", "REFUSED"]
    document = {
        "schema_version": 1,
        "phase": "phase1",
        "aggregate_sha256": findings_sha,
        "findings_disposition": [
            {
                "finding_index": key.finding_index,
                "location": key.location,
                "summary_sha256": key.summary_sha256,
                "disposition": state,
                "behavior_tag": "change" if state == "APPLIED" else "n/a",
                "reason": "fixture",
            }
            for key, state in zip(keys, dispositions, strict=True)
        ],
    }
    disposition = evidence / "phase1-disposition.json"
    disposition.write_text(
        json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return evidence, findings, findings_sha, disposition, digest(disposition)


with scratch_dir("code-fixer-verify-claims-") as temporary:
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )
    aggregate_before = findings.read_bytes()
    claims_dir = evidence / "verification-claims"
    receipt = module.project_verification_claims(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        claims_dir=str(claims_dir),
    )
    # Roster scope: blocker AND not APPLIED. The APPLIED blocker and the
    # suggestion are both absent.
    assert receipt["verify_count"] == 2, receipt
    assert [item["finding_index"] for item in receipt["claims"]] == [1, 4], receipt
    assert receipt["aggregate_sha256"] == findings_sha
    # AC 14: the aggregate is read, never rewritten.
    assert findings.read_bytes() == aggregate_before
    card_bytes = b""
    for item in receipt["claims"]:
        card_path = pathlib.Path(item["claim_path"])
        # The receipt reports the CANONICAL path, so compare resolved parents:
        # on macOS the temp root is a symlink and the two spellings differ.
        assert card_path.parent.resolve() == claims_dir.resolve(), item
        raw = card_path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == item["claim_sha256"]
        card_bytes += raw
        card = json.loads(raw)
        assert set(card) == {"finding_index", "location", "summary"}, card
        # Canonical compact-sorted JSON, so the bytes are re-derivable.
        assert raw == module._canonical_json(card) + b"\n"
    assert json.loads(pathlib.Path(receipt["claims"][0]["claim_path"]).read_bytes()) == {
        "finding_index": 1,
        "location": "src/a.py:42",
        "summary": "Unchecked index reads past the buffer",
    }
    # THE withholding assertion: neither the reviewer's confidence prefix, the
    # reasoning itself, nor the source_edges reach the verifier as bytes.
    assert b"confidence: 93" not in card_bytes
    assert b"the loop bound is len(rows)" not in card_bytes
    assert b"review_pr.review" not in card_bytes
    assert b"severity" not in card_bytes
    # Republishing over an existing card is refused rather than silently
    # overwriting somebody else's claim.
    expect_contract_failure(lambda: module.project_verification_claims(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        claims_dir=str(claims_dir),
    ))
    # A digest that does not match the bytes is a typed refusal, not a re-read.
    expect_contract_failure(lambda: module.project_verification_claims(
        findings_path=str(findings), findings_sha256="0" * 64,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        claims_dir=str(evidence / "other-claims"),
    ))
    # A non-canonical aggregate is refused.
    tampered = evidence / "tampered.md"
    tampered.write_bytes(aggregate_before.replace(b"schema_version", b"schema_versioN"))
    expect_contract_failure(lambda: module.project_verification_claims(
        findings_path=str(tampered), findings_sha256=digest(tampered),
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        claims_dir=str(evidence / "tampered-claims"),
    ))

# #452 -- the phase axis, pinned at every layer it is decided on. Before this
# block there was ONE pair-loading procedure per phase (two divergent copies of
# the same twelve steps), and the Phase-2-only verb carried an all-phase name
# that no assert contradicted.
with scratch_dir("code-fixer-phase-axis-") as temporary:
    working = pathlib.Path(temporary).resolve()
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )
    # The Phase 2 half of the axis: empty aggregate + empty canonical
    # disposition, the same shape the workflow-defer block binds.
    p2_aggregate = working / "simplify-final.md"
    p2_aggregate.write_bytes(aggregate("phase2"))
    p2_sha = digest(p2_aggregate)
    p2_disposition = working / "phase2-disposition.json"
    p2_disposition.write_text(json.dumps({
        "schema_version": 1, "phase": "phase2",
        "aggregate_sha256": p2_sha, "findings_disposition": [],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    p2_disposition_sha = digest(p2_disposition)

    # ONE procedure, parameterised by phase -- both phases reach it.
    p1_pair = module._load_verification_pair(
        phase="phase1", findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
    )
    assert len(p1_pair) == 4, p1_pair
    assert p1_pair[0]["phase"] == "phase1", p1_pair[0]
    assert p1_pair[1]["phase"] == "phase1", p1_pair[1]
    assert len(p1_pair[2]) == 4, p1_pair[2]
    p2_pair = module._load_verification_pair(
        phase="phase2", findings_path=str(p2_aggregate), findings_sha256=p2_sha,
        disposition_path=str(p2_disposition),
        disposition_sha256=p2_disposition_sha,
    )
    assert p2_pair[0]["phase"] == "phase2", p2_pair[0]
    assert p2_pair[1]["phase"] == "phase2", p2_pair[1]
    assert p2_pair[2] == (), p2_pair[2]

    # A pair from the OTHER phase is refused on its envelope, both directions,
    # and an unknown phase is refused on the derivation itself.
    expect_contract_reason(
        lambda: module._load_verification_pair(
            phase="phase2", findings_path=str(findings),
            findings_sha256=findings_sha, disposition_path=str(disposition),
            disposition_sha256=disposition_sha),
        "findings_envelope_invalid",
    )
    expect_contract_reason(
        lambda: module._load_verification_pair(
            phase="phase1", findings_path=str(p2_aggregate),
            findings_sha256=p2_sha, disposition_path=str(p2_disposition),
            disposition_sha256=p2_disposition_sha),
        "findings_envelope_invalid",
    )
    expect_contract_reason(
        lambda: module._load_verification_pair(
            phase="phase3", findings_path=str(p2_aggregate),
            findings_sha256=p2_sha, disposition_path=str(p2_disposition),
            disposition_sha256=p2_disposition_sha),
        "findings_schema_invalid",
    )

    # The Phase 2 verb refuses a Phase 1 pair BY NAME, at the Python layer and
    # through the CLI. Asserted nowhere before #452.
    expect_contract_reason(
        lambda: module.count_phase2_deferred_blockers(
            findings_path=str(findings), findings_sha256=findings_sha,
            disposition_path=str(disposition),
            disposition_sha256=disposition_sha),
        "findings_envelope_invalid",
    )
    # `run` only shape-checks the reason token; this row pins the exact string.
    phase1_through_phase2 = subprocess.run(
        [sys.executable, "-I", "-B", str(helper_path),
         "count-phase2-deferred-blockers",
         "--findings-path", str(findings), "--findings-sha256", findings_sha,
         "--disposition-path", str(disposition),
         "--disposition-sha256", disposition_sha],
        text=True, capture_output=True, check=False,
    )
    assert phase1_through_phase2.returncode == 74, (
        phase1_through_phase2.returncode, phase1_through_phase2.stdout,
        phase1_through_phase2.stderr,
    )
    assert phase1_through_phase2.stderr.strip() == "findings_envelope_invalid", (
        phase1_through_phase2.stderr
    )
    assert phase1_through_phase2.stdout == "", phase1_through_phase2.stdout
    # ...and the retired all-phase spelling is gone from the CLI vocabulary.
    # The name is ASSEMBLED here so this file never carries it contiguously:
    # the retirement is pinned repo-wide by a grep that would otherwise count
    # this very row.
    retired_verb = "count-" + "deferred-blockers"
    retired = subprocess.run(
        [sys.executable, "-I", "-B", str(helper_path), retired_verb,
         "--findings-path", str(p2_aggregate), "--findings-sha256", p2_sha,
         "--disposition-path", str(p2_disposition),
         "--disposition-sha256", p2_disposition_sha],
        text=True, capture_output=True, check=False,
    )
    assert retired.returncode == 74, (
        retired.returncode, retired.stdout, retired.stderr
    )
    # argparse's own error is mapped into the module's closed vocabulary, so an
    # unknown verb is refused by NAME rather than by an unmapped exit 2.
    assert retired.stderr.strip() == "arguments_invalid", retired.stderr
    assert retired.stdout == "", retired.stdout

    # Neither persistence producer is widened by the rename: a Phase 1 pair is
    # refused even when expected_deferred_blockers matches its TRUE Phase 1
    # count, and the token is the envelope refusal (the scalar pre-checks all
    # pass, then the recount refuses).
    axis_result = working / "result.md"
    axis_status = working / "status.json"
    axis_result.write_text(persistence_result("DONE"), encoding="utf-8")
    axis_status.write_text(json.dumps({
        "backend": "background", "branch": "", "exit_code": 0,
        "lease_generation": "0123456789abcdef0123456789abcdef", "pid": "34567",
        "process_identity": "34567|34567|34567|" + "0123456789abcdef" * 4,
        "result": str(axis_result), "state": "completed",
        "workspace_mode": "caller", "worktree": str(working),
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    axis_receipt = json.dumps({
        "schema_version": 1, "edge_id": "review_pr.defer.findings",
        "instance_id": "review-pr-defer-findings-iter01-attempt01",
        "backend": "background", "handle": "34567", "state": "completed",
        "result_file": str(axis_result), "status_file": str(axis_status),
    }, sort_keys=True, separators=(",", ":")).encode()
    # Positive control: the SAME producer arguments with the Phase 2 pair bind.
    axis_detached = module.bind_persistence_launch_receipt(
        receipt=axis_receipt, edge_id="review_pr.defer.findings",
        instance_id="review-pr-defer-findings-iter01-attempt01",
        result_path=str(axis_result), status_path=str(axis_status),
        working_dir=str(working), aggregate_path=str(p2_aggregate),
        aggregate_sha256=p2_sha, disposition_path=str(p2_disposition),
        disposition_sha256=p2_disposition_sha,
        expected_deferred_blockers=0, require_clean=False,
    )
    assert axis_detached["edge_id"] == "review_pr.defer.findings", axis_detached
    expect_contract_reason(
        lambda: module.bind_persistence_launch_receipt(
            receipt=axis_receipt, edge_id="review_pr.defer.findings",
            instance_id="review-pr-defer-findings-iter01-attempt01",
            result_path=str(axis_result), status_path=str(axis_status),
            working_dir=str(working), aggregate_path=str(findings),
            aggregate_sha256=findings_sha, disposition_path=str(disposition),
            disposition_sha256=disposition_sha,
            expected_deferred_blockers=1, require_clean=True),
        "findings_envelope_invalid",
    )
    axis_workflow = module.bind_workflow_persistence_launch(
        instance_id="review-pr-defer-findings-iter01-attempt01",
        run_nonce=WORKFLOW_NONCE, result_path=str(axis_result),
        status_path=str(axis_status), working_dir=str(working),
        aggregate_path=str(p2_aggregate), aggregate_sha256=p2_sha,
        disposition_path=str(p2_disposition),
        disposition_sha256=p2_disposition_sha,
        expected_deferred_blockers=0, require_clean=False,
    )
    assert axis_workflow["edge_id"] == "review_pr.defer.findings", axis_workflow
    expect_contract_reason(
        lambda: module.bind_workflow_persistence_launch(
            instance_id="review-pr-defer-findings-iter01-attempt01",
            run_nonce=WORKFLOW_NONCE, result_path=str(axis_result),
            status_path=str(axis_status), working_dir=str(working),
            aggregate_path=str(findings), aggregate_sha256=findings_sha,
            disposition_path=str(disposition),
            disposition_sha256=disposition_sha,
            expected_deferred_blockers=1, require_clean=True),
        "findings_envelope_invalid",
    )

with scratch_dir("code-fixer-verify-none-") as temporary:
    # A suggestions-only aggregate produces zero cards and zero directories.
    evidence = pathlib.Path(temporary) / ".uberdev/research/20260810-101500-abcdef1"
    evidence.mkdir(parents=True)
    findings = evidence / "post-impl-review-final.md"
    findings.write_bytes(phase1_table([
        ("comment-analyzer", "suggestion", "src/only.py", "3",
         "DEFERRED", "Stale comment", "confidence: 84 - renamed parameter"),
    ]))
    findings_sha = digest(findings)
    keys = module.parse_finding_keys(findings.read_bytes(), "phase1")
    disposition = evidence / "phase1-disposition.json"
    disposition.write_text(json.dumps({
        "schema_version": 1, "phase": "phase1", "aggregate_sha256": findings_sha,
        "findings_disposition": [{
            "finding_index": keys[0].finding_index,
            "location": keys[0].location,
            "summary_sha256": keys[0].summary_sha256,
            "disposition": "SKIPPED", "behavior_tag": "n/a", "reason": "fixture",
        }],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    claims_dir = evidence / "verification-claims"
    receipt = module.project_verification_claims(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=digest(disposition),
        claims_dir=str(claims_dir),
    )
    assert receipt["verify_count"] == 0 and receipt["claims"] == []
    assert not claims_dir.exists()

with scratch_dir("code-fixer-verify-publish-") as temporary:
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )

    def publish(opinions, threshold=80, target=None, expect_reason=None):
        path = target if target is not None else evidence / "phase1-verification.json"
        if not path.exists():
            path.write_bytes(b"")
        call = lambda: module.publish_verification(
            findings_path=str(findings), findings_sha256=findings_sha,
            disposition_path=str(disposition), disposition_sha256=disposition_sha,
            verification_path=str(path), threshold=threshold,
            candidate=json.dumps(opinions).encode("utf-8"),
        )
        if expect_reason is None:
            return call()
        expect_contract_reason(call, expect_reason)
        # Fail closed: a refused publication leaves the target empty.
        assert path.read_bytes() == b"", (expect_reason, path.read_bytes())
        return None

    survives = [
        {"finding_index": 1, "score": 93, "reason": "reproduced-from-diff"},
        {"finding_index": 4, "score": 79, "reason": "pre-existing"},
    ]
    receipt = publish(survives)
    sidecar = evidence / "phase1-verification.json"
    document = json.loads(sidecar.read_text(encoding="utf-8"))
    assert set(document) == {
        "schema_version", "phase", "aggregate_sha256", "threshold",
        "findings_verification",
    }
    assert document["phase"] == "phase1"
    assert document["aggregate_sha256"] == findings_sha
    assert document["threshold"] == 80
    # Canonical bytes, so the sidecar is re-derivable and diffable.
    assert sidecar.read_bytes() == module._canonical_json(document) + b"\n"
    assert hashlib.sha256(sidecar.read_bytes()).hexdigest() == (
        receipt["verification_sha256"]
    )
    assert receipt["verified"] == 2 and receipt["culled"] == 1
    assert [row["verdict"] for row in document["findings_verification"]] == [
        "SURVIVES", "CULLED",
    ]
    # The row carries the same (finding_index, location, summary_sha256) triple
    # the disposition binds, so the two artifacts describe the same findings.
    keys = module.parse_finding_keys(findings.read_bytes(), "phase1")
    by_index = {key.finding_index: key for key in keys}
    for row in document["findings_verification"]:
        key = by_index[row["finding_index"]]
        assert row["location"] == key.location
        assert row["summary_sha256"] == key.summary_sha256
    # A non-empty pre-existing target is refused.
    publish(survives, expect_reason="artifact_size_invalid") if False else None
    try:
        module.publish_verification(
            findings_path=str(findings), findings_sha256=findings_sha,
            disposition_path=str(disposition), disposition_sha256=disposition_sha,
            verification_path=str(sidecar), threshold=80,
            candidate=json.dumps(survives).encode("utf-8"),
        )
    except module.ContractFailure:
        pass
    else:
        raise AssertionError("expected refusal on a non-empty verification target")
    assert json.loads(sidecar.read_text(encoding="utf-8")) == document

with scratch_dir("code-fixer-verify-threshold-") as temporary:
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )

    def publish_at(threshold, opinions, name):
        path = evidence / name
        path.mkdir(parents=True, exist_ok=True)
        target = path / "phase1-verification.json"
        target.write_bytes(b"")
        # The sidecar must be a sibling of the disposition; a different
        # directory is a typed refusal, so the fixture copies both.
        local_findings = path / findings.name
        local_findings.write_bytes(findings.read_bytes())
        local_disposition = path / disposition.name
        local_disposition.write_bytes(disposition.read_bytes())
        return module.publish_verification(
            findings_path=str(local_findings), findings_sha256=findings_sha,
            disposition_path=str(local_disposition),
            disposition_sha256=disposition_sha,
            verification_path=str(target), threshold=threshold,
            candidate=json.dumps(opinions).encode("utf-8"),
        ), target

    borderline = [
        {"finding_index": 1, "score": 93, "reason": "reproduced-from-diff"},
        {"finding_index": 4, "score": 79, "reason": "pre-existing"},
    ]
    # SAME child bytes, opposite verdicts: the threshold is applied entirely
    # controller-side, which is what makes recorded scores re-thresholdable.
    strict_receipt, strict_target = publish_at(80, borderline, "at-80")
    loose_receipt, loose_target = publish_at(79, borderline, "at-79")
    strict = json.loads(strict_target.read_text(encoding="utf-8"))
    loose = json.loads(loose_target.read_text(encoding="utf-8"))
    assert [row["verdict"] for row in strict["findings_verification"]] == [
        "SURVIVES", "CULLED",
    ]
    assert [row["verdict"] for row in loose["findings_verification"]] == [
        "SURVIVES", "SURVIVES",
    ]
    assert [row["score"] for row in strict["findings_verification"]] == [93, 79]
    assert strict_receipt["culled"] == 1 and loose_receipt["culled"] == 0

    # Fail toward keeping: no child opinion NEVER culls, whatever the reason.
    for reason in ("verifier-unavailable", "over-cap-unverified"):
        unavailable = [
            {"finding_index": 1, "reason": reason},
            {"finding_index": 4, "score": 12, "reason": "contradicted-by-diff"},
        ]
        _receipt, target = publish_at(80, unavailable, f"unavailable-{reason}")
        rows = json.loads(target.read_text(encoding="utf-8"))["findings_verification"]
        assert rows[0]["verdict"] == "SURVIVES" and rows[0]["score"] is None, rows
        assert rows[0]["reason"] == reason
        assert rows[1]["verdict"] == "CULLED", rows

    # Kill switch: threshold 0 records every eligible row SURVIVES/gate-disabled.
    disabled = [
        {"finding_index": 1, "reason": "gate-disabled"},
        {"finding_index": 4, "reason": "gate-disabled"},
    ]
    receipt, target = publish_at(0, disabled, "disabled")
    rows = json.loads(target.read_text(encoding="utf-8"))["findings_verification"]
    assert receipt["culled"] == 0 and receipt["verified"] == 2
    assert all(row["verdict"] == "SURVIVES" and row["score"] is None for row in rows)
    assert all(row["reason"] == "gate-disabled" for row in rows)

with scratch_dir("code-fixer-verify-refuse-") as temporary:
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )

    def refuse(opinions, threshold=80, name="refuse", **overrides):
        path = evidence / name
        path.mkdir(parents=True, exist_ok=True)
        target = path / "phase1-verification.json"
        target.write_bytes(b"")
        local_findings = path / findings.name
        local_findings.write_bytes(findings.read_bytes())
        local_disposition = path / disposition.name
        local_disposition.write_bytes(disposition.read_bytes())
        arguments = {
            "findings_path": str(local_findings), "findings_sha256": findings_sha,
            "disposition_path": str(local_disposition),
            "disposition_sha256": disposition_sha,
            "verification_path": str(target), "threshold": threshold,
            "candidate": json.dumps(opinions).encode("utf-8"),
        }
        arguments.update(overrides)
        expect_contract_failure(lambda: module.publish_verification(**arguments))
        # Rollback: a refused transaction leaves the sidecar empty, never
        # half-written.
        assert target.read_bytes() == b"", (name, target.read_bytes())

    good = [
        {"finding_index": 1, "score": 93, "reason": "reproduced-from-diff"},
        {"finding_index": 4, "score": 79, "reason": "pre-existing"},
    ]
    # Roster mismatch: too few, too many, wrong index, wrong order.
    refuse(good[:1], name="short")
    refuse(good + [{"finding_index": 9, "score": 1, "reason": "pre-existing"}],
           name="long")
    refuse([{"finding_index": 2, "score": 93, "reason": "reproduced-from-diff"}, good[1]],
           name="wrong-index")
    refuse([good[1], good[0]], name="reversed")
    # A controller reason may not carry a score, and a child reason must.
    refuse([{"finding_index": 1, "score": 50, "reason": "verifier-unavailable"}, good[1]],
           name="scored-controller-reason")
    refuse([{"finding_index": 1, "reason": "reproduced-from-diff"}, good[1]],
           name="unscored-child-reason")
    # Closed vocabularies.
    refuse([{"finding_index": 1, "score": 93, "reason": "looks-fine"}, good[1]],
           name="unknown-reason")
    refuse([{"finding_index": 1, "score": 101, "reason": "pre-existing"}, good[1]],
           name="score-too-high")
    refuse([{"finding_index": 1, "score": -1, "reason": "pre-existing"}, good[1]],
           name="score-negative")
    refuse([{"finding_index": 1, "score": True, "reason": "pre-existing"}, good[1]],
           name="score-bool")
    refuse([{"finding_index": 1, "score": "93", "reason": "pre-existing"}, good[1]],
           name="score-string")
    # A verdict is the controller's to assign; a caller may not smuggle one in.
    refuse([dict(good[0], verdict="SURVIVES"), good[1]], name="caller-verdict")
    # At threshold 0 no verifier runs, so a scored row cannot have come from one.
    refuse(good, threshold=0, name="disabled-with-scores")
    # The threshold itself is bounded.
    refuse(good, threshold=101, name="threshold-high")
    refuse(good, threshold=-1, name="threshold-low")
    # The sidecar must be the disposition's sibling, under its exact basename.
    stray = evidence / "stray"
    stray.mkdir(parents=True, exist_ok=True)
    (stray / "phase1-verification.json").write_bytes(b"")
    expect_contract_failure(lambda: module.publish_verification(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        verification_path=str(stray / "phase1-verification.json"), threshold=80,
        candidate=json.dumps(good).encode("utf-8"),
    ))
    misnamed = evidence / "verification.json"
    misnamed.write_bytes(b"")
    expect_contract_failure(lambda: module.publish_verification(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition), disposition_sha256=disposition_sha,
        verification_path=str(misnamed), threshold=80,
        candidate=json.dumps(good).encode("utf-8"),
    ))
    # A digest that does not pin the bytes on disk is refused before any write.
    refuse(good, name="bad-aggregate-digest", findings_sha256="0" * 64)
    refuse(good, name="bad-disposition-digest", disposition_sha256="0" * 64)

with scratch_dir("code-fixer-verify-cli-") as temporary:
    # Both verbs are reachable through the shipped CLI, which is how
    # /review-pr's Step 6b.0 fence calls them.
    evidence, findings, findings_sha, disposition, disposition_sha = (
        verification_fixture(temporary)
    )
    claims_dir = evidence / "verification-claims"
    claims_receipt = json.loads(run([
        "project-verification-claims",
        "--findings-path", str(findings), "--findings-sha256", findings_sha,
        "--disposition-path", str(disposition),
        "--disposition-sha256", disposition_sha,
        "--claims-dir", str(claims_dir),
    ]))
    assert claims_receipt["verify_count"] == 2, claims_receipt
    target = evidence / "phase1-verification.json"
    target.write_bytes(b"")
    verification_receipt = json.loads(run([
        "publish-verification",
        "--findings-path", str(findings), "--findings-sha256", findings_sha,
        "--disposition-path", str(disposition),
        "--disposition-sha256", disposition_sha,
        "--verification-path", str(target), "--threshold", "80",
    ], stdin=json.dumps([
        {"finding_index": 1, "score": 93, "reason": "reproduced-from-diff"},
        {"finding_index": 4, "score": 12, "reason": "contradicted-by-diff"},
    ])))
    assert verification_receipt["culled"] == 1, verification_receipt
    assert verification_receipt["threshold"] == 80

# === #556: the fixer terminal that applies NOTHING publishes its own evidence =
#
# Observed on the consolidated review of PR #553 (run 20260814-074622, iter 2).
# The Phase 1 code-fixer returned `status: REFUSED`: it had prepared and
# verified fixes, its own publication step refused `review_index_mismatch`, and
# it correctly restored the worktree to HEAD. A textbook clean refusal -- and it
# wrote NEITHER of the two artifacts the controller binds by path. The
# applied-content document was never created and the disposition was left at
# ZERO bytes, so `capture-review-terminal` could not freeze the terminal at all
# (`--applied-content-path` is required and the file did not exist) and Phase
# 2.5 refused `input-malformed` on the zero-byte disposition. Six BLOCKER rows
# were consequently never filed as issues.
#
# A refusal is the one terminal where the findings most need to survive:
# nothing was applied, so every finding is still outstanding.
# `publish_unapplied_terminal` is the missing publisher. It proves nothing was
# applied, then writes the disposition -- every row exactly as the child
# declared it -- plus an empty applied-content plan, which is the shape both
# consumers already expect, so neither consumer changes.

UNAPPLIED_NONCE = "5c" * 32
assert re.fullmatch(r"[0-9a-f]{64}", UNAPPLIED_NONCE)
UNAPPLIED_FINDING_POOL = (
    ("code-reviewer", "src/a.py", "alpha is asserted but never proved"),
    ("silent-failure-hunter", "src/b.py", "beta swallows the decode error"),
)
UNAPPLIED_LENS_POOL = ("quality", "reuse")
# The receipt `review_promote_validated_fixer_outcome` accepts -- spelled as
# the fence spells it, plus the launch identity every bound verb returns. The
# rows below assert against this one set instead of re-spelling it, so there is
# no second copy to drift out of agreement with the fence.
UNAPPLIED_RECEIPT_KEYS = {
    "status", "declared_tip", "status_sha256", "result_sha256",
    "disposition_sha256", "applied_content_sha256", "commit",
} | {"run_nonce"}


def unapplied_row_block(row):
    """The six result lines one findings row renders to -- the ONE renderer.

    `build_unapplied` emits its rows through this, and the forgery rows below
    substitute whole blocks through it, so there is no second copy of the layout
    to drift: a change here moves the fixture and the forgeries together, and a
    forgery that no longer matches fails its own `in text` assertion loudly
    instead of silently rewriting nothing.
    """
    return "".join(f"{line}\n" for line in (
        f"  - finding_index: {row['finding_index']}",
        f"    location: {row['location']}",
        f"    summary_sha256: {row['summary_sha256']}",
        f"    disposition: {row['disposition']}",
        f"    behavior_tag: {row['behavior_tag']}",
        f"    reason: {row['reason']}",
    ))


def build_unapplied(temporary, *, edge="review_pr.fix.phase1", rows=None,
                    status=None, commits_line="commits: []", nonce=None):
    """One complete REFUSED fixer terminal, in the state #556 left behind.

    Everything the verb READS and nothing it WRITES: the disposition is left at
    exactly zero bytes and the applied-content path is left absent, because
    those two files are this verb's output. `publish_disposition` is
    deliberately never called -- it consumes the same zero-byte seed, so a
    fixture that called it could not then be handed to the verb under test.
    That is why every row below builds its own fixture instead of sharing one.

    `rows` sizes the aggregate as well as the result: `len(rows)` findings are
    taken from the pool, so `rows=[]` builds the zero-finding authority.
    """
    phase = "phase1" if edge == "review_pr.fix.phase1" else "phase2"
    policy_phase = "review_fix" if phase == "phase1" else "simplify_fix"
    nonce = nonce or UNAPPLIED_NONCE
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "src").mkdir()
    (repo / "src/a.py").write_text("A = 0\n", encoding="utf-8")
    (repo / "src/b.py").write_text("B = 0\n", encoding="utf-8")
    git(repo, "add", "--", "src/a.py", "src/b.py")
    git(repo, "commit", "-qm", "test: unapplied terminal base")
    base = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    (repo / "src/a.py").write_text("A = 1\n", encoding="utf-8")
    (repo / "src/b.py").write_text("B = 1\n", encoding="utf-8")
    git(repo, "add", "--", "src/a.py", "src/b.py")
    git(repo, "commit", "-qm", "test: unapplied terminal head")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    evidence = repo / ".uberdev/research/20260814-074622-b2421484c09"
    evidence.mkdir(parents=True)
    if rows is None:
        rows = [
            {"disposition": "REFUSED", "behavior_tag": "n/a",
             "reason": "prepared and verified; publication gate refused"}
            for _entry in UNAPPLIED_FINDING_POOL
        ]
    pool = UNAPPLIED_FINDING_POOL[:len(rows)]
    if phase == "phase1":
        findings = evidence / "post-impl-review-final.md"
        findings.write_bytes(phase1_table([
            (agent, "blocker", path, "1", "DEFERRED", summary, "bounded detail")
            for agent, path, summary in pool
        ]))
    else:
        findings = evidence / "simplify-final.md"
        findings.write_bytes(phase2_table([
            (lens, "blocker", path, "1", "DEFERRED", summary)
            for lens, (_agent, path, summary) in zip(
                UNAPPLIED_LENS_POOL, pool, strict=False)
        ]))
    commit_range = evidence / "commit-range.txt"
    commit_range.write_text(f"{base}..{head}\n", encoding="ascii")
    disposition = evidence / f"{phase}-disposition.json"
    disposition.write_bytes(b"")
    receipt = prepare(
        repo, findings, digest(findings), commit_range, digest(commit_range),
        disposition, edge=edge, policy_phase=policy_phase,
    )
    authority_path = pathlib.Path(receipt["authority_path"])
    authority = json.loads(authority_path.read_text(encoding="utf-8"))
    authority["authority_path"] = str(authority_path)
    full_rows = [
        {**finding, **row}
        for finding, row in zip(authority["finding_keys"], rows, strict=True)
    ]
    if status is None:
        status = (
            "REFUSED"
            if any(row["disposition"] == "REFUSED" for row in full_rows)
            else "NO_FIXES_NEEDED"
        )
    lines = ["```yaml", f"status: {status}", f"phase: {phase}"]
    lines.extend(commits_line.format(head=head).split("\n"))
    if full_rows:
        lines.append("findings_disposition:")
        for row in full_rows:
            lines.extend(unapplied_row_block(row).splitlines())
    else:
        lines.append("findings_disposition: []")
    lines.extend(["risks: []", "```"])
    result_path = evidence / f"{phase}-fixer-result.md"
    result_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    status_path = evidence / f"{phase}-fixer-status.json"
    binding = module.bind_workflow_fixer_launch(
        edge_id=edge,
        instance_id=f"review-pr-run-fix-{phase}-iter02-attempt01",
        run_nonce=nonce, result_path=str(result_path),
        status_path=str(status_path), working_dir=str(repo),
        authority_path=str(authority_path),
        authority_sha256=receipt["authority_sha256"],
    )
    status_path.write_text(json.dumps({
        "backend": "workflow", "branch": "", "exit_code": 0,
        "result": binding["result_path"], "run_nonce": nonce,
        "state": "completed", "workspace_mode": "caller",
        "worktree": binding["worktree"],
    }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    content_path = evidence / authority_path.name.replace(
        "code-fixer-authority-", "review-applied-content-")
    assert not content_path.exists(), content_path
    assert disposition.stat().st_size == 0
    return {
        "repo": repo, "evidence": evidence, "findings": findings,
        "commit_range": commit_range, "disposition": disposition,
        "authority_path": authority_path, "authority": authority,
        "authority_sha256": receipt["authority_sha256"],
        "result_path": result_path, "status_path": status_path,
        "binding": binding, "binding_bytes": module._canonical_json(binding),
        "content_path": content_path, "rows": full_rows, "phase": phase,
        "base": base, "head": head, "nonce": nonce,
    }


def call_unapplied(fixture, **overrides):
    arguments = {
        "launch_binding": fixture["binding_bytes"],
        "authority_path": str(fixture["authority_path"]),
        "authority_sha256": fixture["authority_sha256"],
        "disposition_path": str(fixture["disposition"]),
        "applied_content_path": str(fixture["content_path"]),
        "working_dir": str(fixture["repo"]),
        "head_before": fixture["head"],
        "head_after": fixture["head"],
    }
    arguments.update(overrides)
    return module.publish_unapplied_terminal(**arguments)


def assert_nothing_published(fixture):
    assert fixture["disposition"].stat().st_size == 0
    assert not fixture["content_path"].exists(), fixture["content_path"]


# U1. Reachable as a module attribute, as an exported name, and -- the half
# #381 found dead the first time -- through the shipped CLI.
assert callable(getattr(module, "publish_unapplied_terminal", None))
assert "publish_unapplied_terminal" in module.__all__
assert module._parser().parse_args([
    "publish-unapplied-terminal",
    "--launch-binding-json", "{}",
    "--authority-path", "/authority.json",
    "--authority-sha256", "0" * 64,
    "--disposition-path", "/phase1-disposition.json",
    "--applied-content-path", "/review-applied-content.json",
    "--working-dir", "/repo",
    "--head-before", "0" * 40,
    "--head-after", "0" * 40,
]).command == "publish-unapplied-terminal"

# U2. The refusal happy path, and its receipt.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    outcome = call_unapplied(fixture)
    assert set(outcome) == UNAPPLIED_RECEIPT_KEYS, outcome
    assert outcome["status"] == "REFUSED", outcome
    assert outcome["declared_tip"] == "", outcome
    assert outcome["commit"] is None, outcome
    assert outcome["run_nonce"] == fixture["nonce"], outcome
    for key, on_disk in (
        ("status_sha256", fixture["status_path"]),
        ("result_sha256", fixture["result_path"]),
        ("disposition_sha256", fixture["disposition"]),
        ("applied_content_sha256", fixture["content_path"]),
    ):
        assert outcome[key] == hashlib.sha256(
            on_disk.read_bytes()).hexdigest(), key

with scratch_dir("code-fixer-unapplied-") as temporary:
    # The CLI arm is the same call. It cannot be driven against the fixture
    # above -- the verb consumes that fixture's zero-byte seed -- so the two
    # documents are compared on every member that is not derived from the
    # scratch path, and the CLI's four digests are re-proved against its own
    # bytes on disk.
    fixture = build_unapplied(temporary)
    cli_outcome = json.loads(run([
        "publish-unapplied-terminal",
        "--launch-binding-json", fixture["binding_bytes"].decode(),
        "--authority-path", str(fixture["authority_path"]),
        "--authority-sha256", fixture["authority_sha256"],
        "--disposition-path", str(fixture["disposition"]),
        "--applied-content-path", str(fixture["content_path"]),
        "--working-dir", str(fixture["repo"]),
        "--head-before", fixture["head"],
        "--head-after", fixture["head"],
    ]))
    assert set(cli_outcome) == UNAPPLIED_RECEIPT_KEYS, cli_outcome
    for key in ("status", "declared_tip", "commit", "run_nonce"):
        assert cli_outcome[key] == outcome[key], key
    for key, on_disk in (
        ("status_sha256", fixture["status_path"]),
        ("result_sha256", fixture["result_path"]),
        ("disposition_sha256", fixture["disposition"]),
        ("applied_content_sha256", fixture["content_path"]),
    ):
        assert cli_outcome[key] == hashlib.sha256(
            on_disk.read_bytes()).hexdigest(), key
    # The result and the disposition carry no scratch path, so their digests
    # are fixture-independent: the two runs published byte-identical rows.
    assert cli_outcome["result_sha256"] == outcome["result_sha256"]
    assert cli_outcome["disposition_sha256"] == outcome["disposition_sha256"]

# U3. The two published shapes, checked by the consumers that read them.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    outcome = call_unapplied(fixture)
    disposition_bytes = fixture["disposition"].read_bytes()
    published = json.loads(disposition_bytes)
    assert published == {
        "schema_version": 1,
        "phase": "phase1",
        "aggregate_sha256": fixture["authority"]["findings_sha256"],
        "findings_disposition": fixture["rows"],
    }, published
    assert disposition_bytes == json.dumps(
        published, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode() + b"\n"
    # Publishing FROM the parsed result rows is what makes
    # `fixer_result_disposition_mismatch` true by construction: there is no
    # second copy of the rows to drift.
    parsed_rows = module._parse_fixer_result(
        fixture["result_path"].read_bytes(),
        fixture["authority"]["phase"],
        fixture["authority"]["commit_type"],
    )["rows"]
    assert published["findings_disposition"] == parsed_rows, parsed_rows
    assert module._validate_disposition(published, fixture["authority"]) == ()
    content_bytes = fixture["content_path"].read_bytes()
    assert json.loads(content_bytes) == {
        "applied": [],
        "authority_sha256": fixture["authority_sha256"],
        "disposition_sha256": outcome["disposition_sha256"],
        "schema_version": 1,
    }, content_bytes
    assert fixture["content_path"].parent == fixture["findings"].parent
    assert fixture["content_path"].name == fixture["authority_path"].name.replace(
        "code-fixer-authority-", "review-applied-content-")
    assert module._load_applied_content_plan(
        str(fixture["content_path"]),
        outcome["applied_content_sha256"],
        fixture["authority"],
        fixture["authority_sha256"],
        outcome["disposition_sha256"],
        (),
    ) == json.loads(content_bytes)

# U4. The status line is DERIVED from the rows, exactly as
# `validate_review_outcome` derives it; a result whose own `status:` disagrees
# is refused, and so is a row claiming APPLIED on a terminal that applied
# nothing. (A result that declares `status: APPLIED` cannot reach this arm:
# `_parse_fixer_result` couples that status to a commit row, so it is U5's
# fixture, not this one's.)
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(
        temporary,
        rows=[
            {"disposition": "REFUSED", "behavior_tag": "n/a",
             "reason": "publication gate refused"},
            {"disposition": "SKIPPED", "behavior_tag": "n/a",
             "reason": "deferred to a durable issue"},
        ],
        status="NO_FIXES_NEEDED",
    )
    expect_contract_reason(
        lambda: call_unapplied(fixture), "fixer_result_status_mismatch")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(
        temporary,
        rows=[
            {"disposition": "APPLIED", "behavior_tag": "change",
             "reason": "rewrote the guard"},
            {"disposition": "REFUSED", "behavior_tag": "n/a",
             "reason": "publication gate refused"},
        ],
        status="REFUSED",
    )
    # The derived value AGREES with the declared one here, so only the explicit
    # "no row is APPLIED" guard can catch it.
    expect_contract_reason(
        lambda: call_unapplied(fixture), "fixer_result_status_mismatch")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # The aggregate the authority was minted over is re-read before anything is
    # published, so rewriting the findings after the mint cannot re-point the
    # rows at other findings. The refusal is the DIGEST one, not
    # `findings_authority_mismatch`: `_recapture_sources` pins the bytes first,
    # so its finding-key comparison is only reachable for bytes that hash to
    # the authority's own digest -- which cannot carry different findings.
    fixture = build_unapplied(temporary)
    fixture["findings"].write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/a.py", "1", "DEFERRED",
         "a different alpha claim", "bounded detail"),
        ("silent-failure-hunter", "blocker", "src/b.py", "1", "DEFERRED",
         "beta swallows the decode error", "bounded detail"),
    ]))
    expect_contract_reason(
        lambda: call_unapplied(fixture), "artifact_digest_mismatch")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # And the sources are re-read BEFORE the first byte is written, not only
    # after. The closing bookend (U20) sees this same drift and rolls the
    # records back, so both calls end on the same token and the same clean
    # tree -- a token assertion cannot tell them apart, which is why deleting
    # the pre-write re-read leaves the suite green and makes it read as
    # redundant. What separates them is whether any byte was written at all,
    # so this row counts the publisher's calls instead of reading its token.
    fixture = build_unapplied(temporary)
    fixture["findings"].write_bytes(phase1_table([
        ("code-reviewer", "blocker", "src/a.py", "1", "DEFERRED",
         "a different alpha claim", "bounded detail"),
        ("silent-failure-hunter", "blocker", "src/b.py", "1", "DEFERRED",
         "beta swallows the decode error", "bounded detail"),
    ]))
    original_replace_empty = module._replace_empty_exact_record
    writes = {"count": 0}

    def count_replace_empty(*arguments, _writes=writes,
                            _original=original_replace_empty):
        _writes["count"] += 1
        return _original(*arguments)

    module._replace_empty_exact_record = count_replace_empty
    try:
        expect_contract_reason(
            lambda: call_unapplied(fixture), "artifact_digest_mismatch")
    finally:
        module._replace_empty_exact_record = original_replace_empty
    assert writes["count"] == 0, writes
    assert_nothing_published(fixture)

# U5. A commit row is a claim that something WAS applied. `_parse_fixer_result`
# admits one only under `status: APPLIED`, so this single fixture is both the
# "declares APPLIED" and the "carries a commit" shape.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(
        temporary,
        status="APPLIED",
        commits_line=(
            "commits:\n"
            "  - sha: {head}\n"
            "    type: fix\n"
            "    summary: bounded authenticated correction"
        ),
    )
    expect_contract_reason(
        lambda: call_unapplied(fixture), "fixer_result_commit_mismatch")
    assert_nothing_published(fixture)

# U6. HEAD moved -- by a real commit, or by the caller's own claim about it.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    (fixture["repo"] / "src/c.py").write_text("C = 0\n", encoding="utf-8")
    git(fixture["repo"], "add", "--", "src/c.py")
    git(fixture["repo"], "commit", "-qm", "test: an extra commit")
    moved = git(
        fixture["repo"], "rev-parse", "HEAD").stdout.decode().strip()
    assert moved != fixture["head"]
    expect_contract_reason(
        lambda: call_unapplied(fixture, head_before=moved, head_after=moved),
        "unapplied_terminal_state_invalid",
    )
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # An EMPTY commit moves HEAD and nothing else: same tree, same index tree,
    # nothing tracked, nothing untracked. The only clause that can see it is
    # the live `head_sha` read -- so this row is what proves the verb reads git
    # rather than believing the caller's `head_before` / `head_after` claim.
    fixture = build_unapplied(temporary)
    git(fixture["repo"], "commit", "-q", "--allow-empty", "-m", "test: empty")
    empty_head = git(
        fixture["repo"], "rev-parse", "HEAD").stdout.decode().strip()
    current = module._capture_repo_state(
        str(fixture["repo"]), str(fixture["evidence"]))
    assert empty_head != fixture["head"]
    assert current["head_tree_sha"] == fixture["authority"]["parent_tree_sha"]
    assert current["index_tree_sha"] == fixture["authority"]["index_tree_sha"]
    assert current["tracked"] == [] and current["untracked"] == (
        fixture["authority"]["untracked"])
    expect_contract_reason(
        lambda: call_unapplied(fixture), "unapplied_terminal_state_invalid")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    expect_contract_reason(
        lambda: call_unapplied(fixture, head_after=fixture["base"]),
        "unapplied_terminal_state_invalid",
    )
    expect_contract_reason(
        lambda: call_unapplied(
            fixture, head_before=fixture["base"], head_after=fixture["base"]),
        "unapplied_terminal_state_invalid",
    )
    # A malformed pair is an argument fault, not a state fault.
    expect_contract_reason(
        lambda: call_unapplied(fixture, head_after="not-a-sha"),
        "commit_identity_invalid",
    )
    assert_nothing_published(fixture)

# U7. A target left modified in the worktree is exactly what a refusal must
# NOT leave behind.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    (fixture["repo"] / "src/a.py").write_text("A = 2\n", encoding="utf-8")
    current = module._capture_repo_state(
        str(fixture["repo"]), str(fixture["evidence"]))
    assert [row["path"] for row in current["tracked"]] == ["src/a.py"], current
    assert current["index_tree_sha"] == fixture["authority"]["index_tree_sha"]
    expect_contract_reason(
        lambda: call_unapplied(fixture), "unapplied_terminal_state_invalid")
    assert_nothing_published(fixture)

# U8. An untracked file OUTSIDE the evidence dir is residue too. Inside it is
# not: the child's own status and result live there.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    (fixture["repo"] / "src/leftover.py").write_text("L = 0\n", encoding="utf-8")
    current = module._capture_repo_state(
        str(fixture["repo"]), str(fixture["evidence"]))
    assert current["untracked"] != fixture["authority"]["untracked"], current
    expect_contract_reason(
        lambda: call_unapplied(fixture), "unapplied_terminal_state_invalid")
    assert_nothing_published(fixture)

# U9. Staged bytes with a clean worktree. The `tracked` set alone would not be
# enough here on every git; `index_tree_sha` is the clause that names it.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    (fixture["repo"] / "src/a.py").write_text("A = 2\n", encoding="utf-8")
    git(fixture["repo"], "add", "--", "src/a.py")
    (fixture["repo"] / "src/a.py").write_text("A = 1\n", encoding="utf-8")
    assert module._index_tree_sha(
        str(fixture["repo"])) != fixture["authority"]["index_tree_sha"]
    expect_contract_reason(
        lambda: call_unapplied(fixture), "unapplied_terminal_state_invalid")
    assert_nothing_published(fixture)

# U10. The disposition seed is consumed, exactly as `publish_disposition`
# consumes it: a file that already carries bytes is not a seed.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    fixture["disposition"].write_bytes(b"{}\n")
    expect_contract_reason(
        lambda: call_unapplied(fixture), "artifact_size_invalid")
    assert fixture["disposition"].read_bytes() == b"{}\n"
    assert not fixture["content_path"].exists()

# U11. An absent seed is not a seed either.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    fixture["disposition"].unlink()
    expect_contract_reason(
        lambda: call_unapplied(fixture), "artifact_capture_failed")
    assert not fixture["disposition"].exists()
    assert not fixture["content_path"].exists()

# U12. The two writes are ONE transaction. A pre-existing applied-content path
# refuses the second write after the first has landed, and the rollback arm
# puts the disposition back to the zero-byte seed it started from.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    squatter = b'{"applied":"squatter"}\n'
    fixture["content_path"].write_bytes(squatter)
    expect_contract_reason(
        lambda: call_unapplied(fixture), "authority_preexists")
    # The restored seed is asserted by SHAPE, not by (device, inode) identity:
    # rollback goes through `_restore_replaced_artifact`, which publishes a
    # fresh temporary and `os.replace`s it, so a new inode is the correct
    # outcome here and pinning the old one would assert the opposite.
    restored = os.lstat(fixture["disposition"])
    assert fixture["disposition"].read_bytes() == b""
    assert restored.st_size == 0 and restored.st_nlink == 1
    assert stat.S_ISREG(restored.st_mode)
    # The squatter is untouched: rollback removes only what this call published.
    assert fixture["content_path"].read_bytes() == squatter

# U13. The child's identity is proved before any of its claims are read. A
# status document that does not echo the minted nonce is not this child's.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    forged = json.loads(fixture["status_path"].read_text(encoding="utf-8"))
    forged["run_nonce"] = "a1" * 32
    assert forged["run_nonce"] != fixture["nonce"]
    fixture["status_path"].write_text(
        json.dumps(forged, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8")
    expect_contract_reason(
        lambda: call_unapplied(fixture), "child_status_invalid")
    assert_nothing_published(fixture)

# U14. THE INCIDENT, reproduced. The child is authorised to run `git status` /
# `git diff` while it works; doing so rewrites `.git/index` without touching
# HEAD, the index tree, the tracked set or the untracked set. That is what
# refused the child's own publication -- and this verb must survive it, or the
# refusal terminal is unreachable for exactly the reason it was reached.
#
# Both halves are asserted. Half (i) is the control: if the raw index-byte pin
# no longer fires, the row FAILS rather than passing on half (ii) alone.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    baseline_index = pathlib.Path(fixture["authority"]["index_path"]).read_bytes()
    assert hashlib.sha256(baseline_index).hexdigest() == (
        fixture["authority"]["index_sha256"])
    # Content untouched; only the stat data moves. The mtime is set BACKWARDS
    # an hour rather than to "now": git's index stores whole-second mtimes
    # unless it was built with USE_NSEC (macOS builds are not), so a same-second
    # touch is invisible to `ce_match_stat` and refreshes nothing, while a
    # future mtime makes the entry racily clean and git declines to cache the
    # new stat. An hour in the past is a plain, deterministic stat miss.
    target = fixture["repo"] / "src/a.py"
    target_before = target.read_bytes()
    target_stat = os.stat(target)
    os.utime(target, (target_stat.st_atime - 3600, target_stat.st_mtime - 3600))
    git(fixture["repo"], "status", "--porcelain")
    assert target.read_bytes() == target_before
    drifted_index = pathlib.Path(fixture["authority"]["index_path"]).read_bytes()
    assert drifted_index != baseline_index, (
        "U14 vacuity: the stat-only edit plus git status did not rewrite "
        ".git/index, so the refusal this row reproduces cannot occur"
    )
    assert len(drifted_index) == fixture["authority"]["index_size"], (
        "U14: the index SIZE moved, so half (i) would refuse "
        "artifact_size_invalid rather than review_index_mismatch -- "
        "investigate this git build before relaxing the row"
    )
    # (i) the control: the pinned raw index bytes still refuse the applied path.
    expect_contract_reason(
        lambda: module.publish_disposition(
            authority_path=str(fixture["authority_path"]),
            authority_sha256=fixture["authority_sha256"],
            disposition_path=str(fixture["disposition"]),
            candidate=json.dumps(candidate(fixture["authority"], [
                {**finding, "disposition": "SKIPPED", "behavior_tag": "n/a",
                 "reason": "deferred to a durable issue"}
                for finding in fixture["authority"]["finding_keys"]
            ])).encode(),
        ),
        "review_index_mismatch",
    )
    assert_nothing_published(fixture)
    # (ii) the unapplied terminal publishes anyway.
    outcome = call_unapplied(fixture)
    assert outcome["status"] == "REFUSED", outcome
    assert fixture["disposition"].stat().st_size > 0
    assert fixture["content_path"].exists()

# U15. NO_FIXES_NEEDED is the other unapplied terminal: every row skipped, or
# no findings at all.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary, rows=[
        {"disposition": "SKIPPED", "behavior_tag": "n/a",
         "reason": "deferred to a durable issue"},
        {"disposition": "SKIPPED", "behavior_tag": "n/a",
         "reason": "out of the reviewed range"},
    ])
    outcome = call_unapplied(fixture)
    assert outcome["status"] == "NO_FIXES_NEEDED", outcome
    assert outcome["declared_tip"] == "" and outcome["commit"] is None, outcome
    assert json.loads(
        fixture["disposition"].read_bytes())["findings_disposition"] == (
            fixture["rows"])

with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary, rows=[])
    outcome = call_unapplied(fixture)
    assert outcome["status"] == "NO_FIXES_NEEDED", outcome
    assert json.loads(
        fixture["disposition"].read_bytes())["findings_disposition"] == []
    assert json.loads(fixture["content_path"].read_bytes())["applied"] == []

# U16. Phase 2 is covered by construction: the binding loader accepts both fix
# edges, so the `review_pr.fix.phase2` refusal takes the same path.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary, edge="review_pr.fix.phase2")
    outcome = call_unapplied(fixture)
    assert outcome["status"] == "REFUSED", outcome
    published = json.loads(fixture["disposition"].read_bytes())
    assert published["phase"] == "phase2", published
    assert published["findings_disposition"] == fixture["rows"]
    assert json.loads(fixture["content_path"].read_bytes())["applied"] == []

# U17. The gate that refused the child is never re-run here. This is a source
# assertion on purpose: it fails the moment somebody "hardens" the new verb
# back into the hole #556 was, which no behavioural row can detect until a
# child happens to have run `git status`.
unapplied_source = inspect.getsource(module.publish_unapplied_terminal)
for banned in ("_require_review_index_current", "_require_review_edit_state"):
    assert banned not in unapplied_source, banned

# U18. The rows are published VERBATIM from the child's own result, so the pin
# to the authority's immutable (finding_index, location, summary_sha256)
# triples is the only thing between a forged result and the record
# `findings-to-issues` reads afterwards. `_parse_fixer_result` never sees the
# authority; `_validate_disposition` is where the triples are checked, and
# without it a child could invent, reorder or drop a finding and have the
# invention stamped into the disposition. Each forgery below is a WELL-FORMED
# result -- it has to be, or the parser refuses first and the row proves
# nothing about the pin.
with scratch_dir("code-fixer-unapplied-") as temporary:
    # Invent: a digest that is syntactically perfect and simply is not the
    # authority's, which is precisely what the parser cannot detect.
    fixture = build_unapplied(temporary, rows=[
        {"disposition": "REFUSED", "behavior_tag": "n/a",
         "reason": "publication gate refused", "summary_sha256": "b" * 64},
        {"disposition": "REFUSED", "behavior_tag": "n/a",
         "reason": "publication gate refused"},
    ])
    assert fixture["rows"][0]["summary_sha256"] == "b" * 64
    assert fixture["rows"][0]["summary_sha256"] != (
        fixture["authority"]["finding_keys"][0]["summary_sha256"])
    assert module._parse_fixer_result(
        fixture["result_path"].read_bytes(),
        fixture["authority"]["phase"],
        fixture["authority"]["commit_type"],
    )["rows"][0]["summary_sha256"] == "b" * 64
    expect_contract_reason(
        lambda: call_unapplied(fixture), "disposition_finding_mismatch")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # Reorder: the two findings swap their (location, summary_sha256) pairs
    # while `finding_index` stays 1, 2 -- the parser requires that sequence, so
    # a renumbered result never reaches the pin, but a re-POINTED one does.
    fixture = build_unapplied(temporary)
    first, second = fixture["rows"]
    assert first["location"] != second["location"]
    text = fixture["result_path"].read_text(encoding="utf-8")
    honest = unapplied_row_block(first) + unapplied_row_block(second)
    assert honest in text
    swapped = text.replace(honest, (
        unapplied_row_block({**first, "location": second["location"],
                             "summary_sha256": second["summary_sha256"]})
        + unapplied_row_block({**second, "location": first["location"],
                               "summary_sha256": first["summary_sha256"]})
    ))
    assert swapped != text
    fixture["result_path"].write_text(swapped, encoding="utf-8")
    expect_contract_reason(
        lambda: call_unapplied(fixture), "disposition_finding_mismatch")
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # Drop: the second finding is deleted from the result. Nothing else in the
    # verb counts the rows, so a dropped finding would otherwise be published
    # as a complete disposition and silently lost -- which is #556's own harm.
    fixture = build_unapplied(temporary)
    text = fixture["result_path"].read_text(encoding="utf-8")
    dropped = text.replace(unapplied_row_block(fixture["rows"][1]), "")
    assert dropped != text
    fixture["result_path"].write_text(dropped, encoding="utf-8")
    assert len(module._parse_fixer_result(
        fixture["result_path"].read_bytes(),
        fixture["authority"]["phase"],
        fixture["authority"]["commit_type"],
    )["rows"]) == 1 < len(fixture["authority"]["finding_keys"])
    expect_contract_reason(
        lambda: call_unapplied(fixture), "disposition_finding_mismatch")
    assert_nothing_published(fixture)

# U19. Every path this verb touches is DERIVED from the authority, never taken
# from the caller. It needs that harder than `capture_review_terminal` does:
# the sibling only READS the applied-content path, while this verb CREATES a
# file there, so an accepted caller path would write a
# `review-applied-content-*.json` wherever the process can reach and point the
# disposition at any unrelated zero-byte file.
#
# The four drivable clauses are below. The other two cannot be isolated in a
# fixture, and are mirrors rather than rot: `_load_fixer_launch_binding`
# already refuses a binding whose `worktree` is not its own authority's
# `working_dir`, and `_load_authority` verifies the caller's digest against the
# bytes at the caller's path -- so once the two authority PATHS agree, the two
# digests cannot disagree either.
with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    forged_content = fixture["evidence"] / "review-applied-content-forged.json"
    expect_contract_reason(
        lambda: call_unapplied(
            fixture, applied_content_path=str(forged_content)),
        "validation_authority_mismatch",
    )
    assert not forged_content.exists(), forged_content
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # A sibling phase's disposition is a seed of exactly the right shape --
    # zero bytes, same directory -- and still not the one the authority names.
    fixture = build_unapplied(temporary)
    foreign_disposition = fixture["evidence"] / "phase2-disposition.json"
    foreign_disposition.write_bytes(b"")
    assert foreign_disposition != fixture["disposition"]
    expect_contract_reason(
        lambda: call_unapplied(
            fixture, disposition_path=str(foreign_disposition)),
        "validation_authority_mismatch",
    )
    assert foreign_disposition.read_bytes() == b""
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    fixture = build_unapplied(temporary)
    elsewhere = pathlib.Path(temporary) / "elsewhere"
    elsewhere.mkdir()
    expect_contract_reason(
        lambda: call_unapplied(fixture, working_dir=str(elsewhere)),
        "validation_authority_mismatch",
    )
    assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # The authority path itself -- the clause a caller can reach with every
    # other clause of the six satisfied. `_load_authority` accepts ANY
    # `code-fixer-authority-<phase>(-iterN)?.json` sitting in the evidence
    # dir, so a BYTE-IDENTICAL copy under a second accepted name loads with
    # the same digest (the digest clause cannot fire) and derives an
    # applied-content path that matches it (the content clause cannot fire
    # either). Only the binding's own `authority_path` is left to refuse it,
    # and without that clause the verb publishes the content plan under a name
    # nothing binds while `review-applied-content-phase1.json` -- the path the
    # controller binds and `capture_review_terminal` derives -- never exists:
    # #556 in mirror image, with the disposition already written over.
    fixture = build_unapplied(temporary)
    # Derived from the AUTHORITY's own path, not from `fixture["evidence"]`:
    # the authority is stored canonicalised and the scratch tree is not (on
    # macOS `/var/folders` is a symlink to `/private/var/folders`), so a copy
    # built the other way sits in a directory `_load_authority` reads as
    # foreign and the row would prove `authority_path_invalid` instead.
    copied_authority = fixture["authority_path"].with_name(
        "code-fixer-authority-phase1-iter2.json")
    copied_authority.write_bytes(fixture["authority_path"].read_bytes())
    assert copied_authority != fixture["authority_path"]
    assert copied_authority.parent == fixture["authority_path"].parent
    # Both controls, or the row silently proves a different clause: the copy
    # is a fully-valid authority in its own right (so the refusal cannot be
    # `authority_path_invalid` from the loader) and it carries the binding's
    # digest unchanged (so it cannot be the digest clause).
    assert digest(copied_authority) == fixture["authority_sha256"]
    assert module._load_authority(
        str(copied_authority), fixture["authority_sha256"]
    ) == module._load_authority(
        str(fixture["authority_path"]), fixture["authority_sha256"])
    matching_content = copied_authority.with_name(
        "review-applied-content-phase1-iter2.json")
    expect_contract_reason(
        lambda: call_unapplied(
            fixture, authority_path=str(copied_authority),
            applied_content_path=str(matching_content)),
        "validation_authority_mismatch",
    )
    assert not matching_content.exists(), matching_content
    assert_nothing_published(fixture)

# U20. The transaction is bookended: once both artifacts have landed, the
# child's status and result, the two records just published, and the
# authority's own sources are all re-captured against the digests this call
# already pinned. Without that, anything that moved DURING the publish is
# published over and the receipt attests to bytes that are no longer there.
#
# Every statement of the bookend is driven separately, each by a shim around
# `_publish_new_exact_record` that performs the real write and then moves one
# file behind the verb's back -- the suite's established monkeypatch idiom
# (`module._capture_regular = ...` at the rows above), always restored in a
# `finally`. Whole-bookend coverage would leave four of the five statements
# individually deletable, which is the very shape #556 was filed about.
unapplied_drift_cases = (
    # (key in the fixture, whether the drifting file is one this call
    #  published, and therefore whether rollback can still undo it)
    ("status_path", False),
    ("result_path", False),
    ("disposition", True),
    ("content_path", True),
)
for drift_key, drift_is_published in unapplied_drift_cases:
    with scratch_dir("code-fixer-unapplied-") as temporary:
        fixture = build_unapplied(temporary)
        original_publish_new = module._publish_new_exact_record
        drift = {"count": 0}

        def drift_after_publish(path, payload, _key=drift_key,
                                _published=drift_is_published,
                                _fixture=fixture, _drift=drift,
                                _original=original_publish_new):
            published = _original(path, payload)
            _drift["count"] += 1
            target = _fixture[_key]
            drifted = target.read_bytes() + b"\n"
            if _published:
                # A published record is read-only, so a concurrent writer
                # cannot rewrite it in place -- it REPLACES it, which needs
                # only the directory. The replacement carries the record's own
                # mode, so the drift is purely in the bytes and the digest
                # clause is unambiguously what refuses it.
                replacement = target.with_name(f"{target.name}.concurrent")
                replacement.write_bytes(drifted)
                os.chmod(replacement, stat.S_IMODE(os.lstat(target).st_mode))
                os.replace(replacement, target)
            else:
                target.write_bytes(drifted)
            return published

        module._publish_new_exact_record = drift_after_publish
        try:
            expect_contract_reason(
                lambda: call_unapplied(fixture),
                # A drifting INPUT is caught by the bookend and undone
                # cleanly. A drifting OUTPUT cannot be undone -- rollback
                # refuses to restore bytes it no longer recognises -- so the
                # call fails LOUDLY on the recovery token instead of returning
                # a receipt over a record somebody else rewrote.
                "unapplied_terminal_transaction_recovery_failed"
                if drift_is_published else "artifact_digest_mismatch",
            )
        finally:
            module._publish_new_exact_record = original_publish_new
        assert drift["count"] == 1, (drift_key, drift)
        if drift_is_published:
            # Rollback declines to overwrite bytes it no longer recognises, so
            # the drifted record is still on disk -- untouched, and reported.
            assert fixture[drift_key].read_bytes().endswith(b"\n\n"), drift_key
        else:
            assert_nothing_published(fixture)

with scratch_dir("code-fixer-unapplied-") as temporary:
    # The fifth statement: the aggregate the authority was minted over drifts
    # after the write, and the closing `_recapture_sources` is what sees it.
    # The forgery is byte-length preserving, so the refusal comes from the
    # digest clause rather than from the size clause.
    fixture = build_unapplied(temporary)
    original_publish_new = module._publish_new_exact_record
    findings_drift = {"count": 0}
    honest_findings = fixture["findings"].read_bytes()
    drifted_findings = honest_findings.replace(
        b"bounded detail", b"bounded detaiL", 1)
    assert drifted_findings != honest_findings
    assert len(drifted_findings) == len(honest_findings)

    def drift_findings_after_publish(path, payload):
        published = original_publish_new(path, payload)
        findings_drift["count"] += 1
        fixture["findings"].write_bytes(drifted_findings)
        return published

    module._publish_new_exact_record = drift_findings_after_publish
    try:
        expect_contract_reason(
            lambda: call_unapplied(fixture), "artifact_digest_mismatch")
    finally:
        module._publish_new_exact_record = original_publish_new
    assert findings_drift["count"] == 1, findings_drift
    assert_nothing_published(fixture)

print("code-fixer-contract: authority, disposition, and staged-set closure passed")
PY
