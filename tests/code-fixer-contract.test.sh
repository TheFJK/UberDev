#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/plugins/uberdev/lib/code_fixer_contract.py"

python3 -I -B - "$ROOT" "$HELPER" <<'PY'
import dataclasses
import hashlib
import importlib.util
import inspect
import json
import os
import pathlib
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
    "count_deferred_blockers",
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
    "capture_standalone_terminal", "capture_review_terminal", "capture_persistence_terminal", "capture_expected", "consume_authority", "encode_aggregate", "parse_finding_keys",
    "prepare_authority", "prepare_standalone_authority", "publish_disposition",
    "publish_review_only_disposition",
    "count_deferred_blockers", "validate_persistence_result",
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
assert tuple(inspect.signature(module.count_deferred_blockers).parameters) == (
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


def git(repository, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repository), *args],
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


def persistence_result(status, *, halted=False, blocker_count=0,
                       halted_due_to_overflow=False):
    return (
        "Persistence summary.\n\n```yaml\n"
        f"status: {status}\n"
        "created_urls: []\n"
        "commented_urls: []\n"
        "skipped_closed: []\n"
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


with tempfile.TemporaryDirectory(prefix="code-fixer-persistence-result-") as temporary:
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
        "backend":"codex", "branch":"", "exit_code":0,
        "lease_generation":"0123456789abcdef0123456789abcdef", "pid":"34567",
        "process_identity":"34567|34567|34567|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "result":str(result_path), "state":"completed", "workspace_mode":"caller",
        "worktree":str(working),
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    receipt = json.dumps({
        "schema_version":1, "edge_id":"review_pr.defer.findings",
        "instance_id":"simplify-defer-findings-iter01-attempt01",
        "backend":"codex", "handle":"34567", "state":"completed",
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
assert [item.location for item in phase2_keys] == [
    "src/api.ts:130", "src/loop.ts:12", "src/dup.ts:3",
]
assert phase2_keys[-1].summary_sha256 == hashlib.sha256(
    b"Extract the duplicate implementation to the existing helper"
).hexdigest()
phase1_empty = aggregate("phase1")
phase2_empty = aggregate("phase2")
assert module.parse_finding_keys(phase1_empty, "phase1") == ()
assert module.parse_finding_keys(phase2_empty, "phase2") == ()
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


with tempfile.TemporaryDirectory(prefix="code-fixer-contract-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "src").mkdir()
    (repo / ".gitignore").write_text("ignored.cfg\n", encoding="utf-8")
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
        "backend": "codex",
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
            "backend": "codex",
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

    ignored_before = (repo / "ignored.cfg").read_bytes()
    (repo / "ignored.cfg").write_text("LOCAL = attacker\n", encoding="utf-8")
    publish(json.dumps(valid_candidate))
    assert dirty_disposition.exists() and dirty_disposition.stat().st_size == 0
    (repo / "ignored.cfg").write_bytes(ignored_before)

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

with tempfile.TemporaryDirectory(prefix="code-fixer-rename-") as temporary:
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

with tempfile.TemporaryDirectory(prefix="code-fixer-standalone-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
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
    original_secure_publish = module.secure_publish_captured
    publication_calls = {"count": 0}

    def fail_applied_content(path, payload):
        publication_calls["count"] += 1
        if publication_calls["count"] == 2:
            module.fail("injected_applied_content_publication_failure")
        return original_secure_publish(path, payload)

    module.secure_publish_captured = fail_applied_content
    try:
        expect_contract_failure(lambda: module.publish_disposition(
            authority_path=str(authority_path),
            authority_sha256=authority_receipt["authority_sha256"],
            disposition_path=str(disposition),
            candidate=json.dumps(candidate(authority, rows)).encode(),
        ))
    finally:
        module.secure_publish_captured = original_secure_publish
    assert disposition.read_bytes() == b""
    assert not applied_content_path.exists()

    replacement = b"foreign-disposition-replacement\n"
    publication_calls["count"] = 0

    def replace_disposition_then_fail_content(path, payload):
        publication_calls["count"] += 1
        if publication_calls["count"] == 2:
            disposition.unlink()
            disposition.write_bytes(replacement)
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
    assert disposition.read_bytes() == replacement
    assert not applied_content_path.exists()
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
    raw_index_path = repo / ".git/index"
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
            {"backend": "codex", "branch": "", "state": "completed",
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
            "backend": "codex", "handle": "12345",
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

with tempfile.TemporaryDirectory(prefix="code-fixer-review-only-") as temporary:
    repo = pathlib.Path(temporary) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / "clean.txt").write_text("H0\n", encoding="utf-8")
    (repo / ".gitignore").write_text("ignored.cfg\n", encoding="utf-8")
    git(repo, "add", "--", "clean.txt", ".gitignore")
    git(repo, "commit", "-qm", "test: review-only base")
    head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    index_before = (repo / ".git/index").read_bytes()
    (repo / "untracked.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (repo / "untracked.sh").chmod(0o644)
    (repo / "ignored.cfg").write_text("secret-local-state\n", encoding="utf-8")
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
            "path": "ignored.cfg",
            "sha256": hashlib.sha256(b"secret-local-state\n").hexdigest(),
            "size": len(b"secret-local-state\n"),
        },
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
    (repo / "ignored.cfg").write_text("mutated-secret-state\n", encoding="utf-8")
    expect_contract_failure(lambda: module.publish_review_only_disposition(
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    ))
    (repo / "ignored.cfg").write_text("secret-local-state\n", encoding="utf-8")
    (repo / "untracked.sh").chmod(0o755)
    expect_contract_failure(lambda: module.publish_review_only_disposition(
        findings_path=str(findings), findings_sha256=digest(findings),
        snapshot_path=str(snapshot_path),
        snapshot_sha256=snapshot_receipt["snapshot_sha256"],
        working_dir=str(repo), disposition_path=str(disposition),
    ))
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
    assert module.count_deferred_blockers(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(disposition),
        disposition_sha256=published["disposition_sha256"],
    ) == 1
    assert run([
        "count-deferred-blockers", "--findings-path", str(findings),
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
    assert module.count_deferred_blockers(
        findings_path=str(findings), findings_sha256=findings_sha,
        disposition_path=str(applied_disposition),
        disposition_sha256=applied_sha,
    ) == 0
    assert git(repo, "rev-parse", "HEAD").stdout.decode().strip() == head
    assert (repo / ".git/index").read_bytes() == index_before
    assert git(repo, "status", "--porcelain", "--untracked-files=no").stdout == b""

with tempfile.TemporaryDirectory(prefix="code-fixer-standalone-empty-") as temporary:
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
        "backend":"codex", "branch":"", "exit_code":0,
        "lease_generation":"abcdef0123456789abcdef0123456789", "pid":"23456",
        "process_identity":"23456|23456|23456|abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "result":str(result_path.resolve()), "state":"completed",
        "workspace_mode":"caller", "worktree":str(repo.resolve()),
    },sort_keys=True,separators=(",",":"))+"\n", encoding="utf-8")
    launch_receipt = json.dumps(
        {
            "schema_version": 1, "edge_id": "simplify.fix.phase2",
            "instance_id": "simplify-empty-iter01-attempt01",
            "backend": "codex", "handle": "23456", "state": "completed",
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

with tempfile.TemporaryDirectory(prefix="code-fixer-residue-") as temporary:
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

with tempfile.TemporaryDirectory(prefix="code-fixer-failed-return-guard-") as temporary:
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

with tempfile.TemporaryDirectory(prefix="code-fixer-atomic-publication-") as temporary:
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

print("code-fixer-contract: authority, disposition, and staged-set closure passed")
PY
