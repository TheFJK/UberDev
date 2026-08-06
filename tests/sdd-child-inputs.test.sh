#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

RECEIPT_FILE="$TMP/receipts.jsonl"
: >"$RECEIPT_FILE"
chmod 600 "$RECEIPT_FILE"
export UBERDEV_CHILD_TEST_MODE=1
export UBERDEV_CHILD_TEST_SOURCE='plugins/uberdev/skills/subagent-driven-dev/SKILL.md'
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$RECEIPT_FILE"

python3 -I -B - "$SKILL" "$TMP/runtime.sh" "$TMP/batch-callsite.sh" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
runtime_pattern = re.compile(
    r"```bash\n(sdd_validate_instance_dimensions\(\).*?\n)```", re.DOTALL
)
batch_pattern = re.compile(
    r"Executable batch shape \(substitute the edge/role/stage from the table\):"
    r"\n\n```bash\n(.*?)\n```",
    re.DOTALL,
)

def exactly_one(pattern, value, label):
    matches = pattern.findall(value)
    if len(matches) != 1:
        raise SystemExit(f"SDD {label} fence count must be exactly one, found {len(matches)}")
    return matches[0]

runtime = exactly_one(runtime_pattern, text, "routed runtime")
batch = exactly_one(batch_pattern, text, "executable batch callsite")
Path(sys.argv[2]).write_text(runtime, encoding="utf-8")
Path(sys.argv[3]).write_text(batch + "\n", encoding="utf-8")

def assert_duplicate_rejected(pattern, duplicate, label):
    try:
        exactly_one(pattern, text + duplicate, label)
    except SystemExit:
        return
    raise SystemExit(f"SDD stale duplicate {label} fence was accepted")

assert_duplicate_rejected(runtime_pattern, f"\n```bash\n{runtime}```\n", "routed runtime")
assert_duplicate_rejected(
    batch_pattern,
    "\nExecutable batch shape (substitute the edge/role/stage from the table):"
    f"\n\n```bash\n{batch}\n```\n",
    "executable batch callsite",
)
PY

. "$LIB"
eval "$(declare -f uberdev_child_inputs_build | sed '1s/uberdev_child_inputs_build/uberdev_child_inputs_build_production/')"

BUILDER_LOG="$TMP/builder.log"
BUILDER_INPUTS_LOG="$TMP/builder-inputs.jsonl"
: >"$BUILDER_LOG"
: >"$BUILDER_INPUTS_LOG"
uberdev_child_inputs_build() {
  local output
  printf '%s\n' "$1" >>"$BUILDER_LOG"
  output="$(uberdev_child_inputs_build_production "$@")" || return $?
  printf '%s\n' "$output" >>"$BUILDER_INPUTS_LOG"
  printf '%s' "$output"
}

SDD_WORKTREE="$ROOT"
SDD_RISK_JSON='[]'
SDD_CHILD_TIMEOUT=5
. "$TMP/runtime.sh"
eval "$(declare -f sdd_canonicalize_owned_paths | sed '1s/sdd_canonicalize_owned_paths/sdd_canonicalize_owned_paths_production/')"
eval "$(declare -f uberdev_child_inputs_validate | sed '1s/uberdev_child_inputs_validate/uberdev_child_inputs_validate_production/')"

CANONICALIZE_LOG="$TMP/canonicalize.log"
VALIDATE_LOG="$TMP/validate.log"
VALIDATED_INPUTS_LOG="$TMP/validated-inputs.jsonl"
: >"$CANONICALIZE_LOG"
: >"$VALIDATE_LOG"
: >"$VALIDATED_INPUTS_LOG"
sdd_canonicalize_owned_paths() {
  printf '%s\n' "$edge_id" >>"$CANONICALIZE_LOG"
  sdd_canonicalize_owned_paths_production "$@"
}
uberdev_child_inputs_validate() {
  local output
  printf '%s\n' "$1" >>"$VALIDATE_LOG"
  output="$(uberdev_child_inputs_validate_production "$@")" || return $?
  printf '%s\n' "$output" >>"$VALIDATED_INPUTS_LOG"
  printf '%s' "$output"
}

make_context() {
  local run="$1" run_id="$2" request decision metadata
  mkdir -p "$run"
  request="$(python3 -I -B - "$run" "$run_id" <<'PY'
import json
import sys

run, run_id = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "run_dir": run,
    "run_id": run_id,
    "repository_id": "sdd-receipt-fixture",
    "backend": "background",
    "workflow": "solve",
    "phase": "lead",
    "role": "lead",
    "task_tier": "large",
    "risk_signals": [],
    "issue_or_pr": 42,
    "issue_num": 42,
    "capacity": 4,
    "timeout_s": 20,
}, separators=(",", ":")))
PY
)"
  decision="$(uberdev_agent_resolve_request "$request")"
  metadata="$(python3 -I -B - "$run_id" <<'PY'
import json
import sys

print(json.dumps({
    "run_id": sys.argv[1],
    "repository_id": "sdd-receipt-fixture",
    "workflow": "solve",
    "backend": "background",
    "issue_num": 42,
    "task_tier": "large",
    "risk_signals": [],
}, separators=(",", ":")))
PY
)"
  uberdev_agent_context_create "$run" "$request" "$decision" \
    '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
    "$metadata" '2026-07-11T00:00:00Z'
}

RUN_DIR="$TMP/run"
CONTEXT_OUTPUT="$(make_context "$RUN_DIR" sdd-receipt-root)"
SDD_WORKTREE="$RUN_DIR"
CONTEXT_FILE="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_file"],end="")' "$CONTEXT_OUTPUT")"
CONTEXT_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_sha256"],end="")' "$CONTEXT_OUTPUT")"
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B - "$CONTEXT_FILE" "$CONTEXT_SHA256" <<'PY'
import json
import sys

print(json.dumps({
    "schema_version": 1,
    "run_id": "sdd-receipt-root",
    "workflow": "solve",
    "issue_num": 42,
    "context_file": sys.argv[1],
    "context_sha256": sys.argv[2],
}, separators=(",", ":")))
PY
)"
export UBERDEV_RUN_CARRIER_JSON

INPUT_DIR="$RUN_DIR/inputs"
mkdir -p "$INPUT_DIR"
task_path="$INPUT_DIR/task \"quoted\" \\ path.md"
allowed_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:]),end="")' \
  'inputs/allowed "one".ts' 'inputs/allowed \ two.ts')"
denied_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:]),end="")' \
  'inputs/denied "sibling".ts')"
failure_fixture_path="$INPUT_DIR/failures/attempt \\ \"one\".md"
failure_path=''
attempt=007

spec_path="$INPUT_DIR/specs/design \"quoted\".md"
plan_path="$INPUT_DIR/plans/plan \\ wave.md"
commit_sha='abc123"quoted'
report_path="$INPUT_DIR/results/implementer \\ \"one\".md"

base_sha='base123\backslash'
head_sha='head123"quoted'

commit_range_path="$INPUT_DIR/run/commit range \"one\".txt"
acceptance_path="$INPUT_DIR/run/acceptance \\ criteria.md"
summary_path="$INPUT_DIR/run/summary \"one\".md"

for artifact in \
  "$task_path" \
  "$INPUT_DIR/allowed \"one\".ts" \
  "$INPUT_DIR/allowed \\ two.ts" \
  "$INPUT_DIR/denied \"sibling\".ts" \
  "$failure_fixture_path" \
  "$spec_path" \
  "$plan_path" \
  "$report_path" \
  "$commit_range_path" \
  "$acceptance_path" \
  "$summary_path"; do
  mkdir -p "$(dirname "$artifact")"
  printf 'sdd receipt fixture\n' >"$artifact"
  chmod 600 "$artifact"
done

PROVIDER_LOG="$TMP/provider.log"
PROVIDER_ARGS_LOG="$TMP/provider-args.jsonl"
: >"$PROVIDER_LOG"
: >"$PROVIDER_ARGS_LOG"
_uberdev_agent_dispatch_backend() {
  local instance
  [ "$#" -eq 7 ]
  instance="$(basename "$(dirname "$4")")"
  python3 -I -B - "$RECEIPT_FILE" "$UBERDEV_CHILD_TEST_SOURCE" "$instance" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert rows[-1]["event"] == "dispatch", rows[-1]
assert rows[-1]["source"] == sys.argv[2], rows[-1]
assert rows[-1]["instance_id"] == sys.argv[3], rows[-1]
PY
  python3 -I -B - "$PROVIDER_ARGS_LOG" "$instance" "$@" <<'PY'
import json
import sys
from pathlib import Path

path, instance, backend, issue, tier, prompt, result, status, decision_raw = sys.argv[1:]
decision = json.loads(decision_raw)
record = {
    "instance_id": instance,
    "backend": backend,
    "issue": int(issue),
    "tier": tier,
    "prompt": prompt,
    "result": result,
    "status": status,
    "decision": decision,
}
with Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
  printf '%s\n' "$instance" >>"$PROVIDER_LOG"
  printf 'completed %s\n' "$instance" >"$5"
  chmod 600 "$5"
  DISPATCH_ID="sdd-receipt-provider-$instance"
  printf '{"backend":"background","state":"completed","exit_code":0,"pid":"%s"}\n' \
    "$DISPATCH_ID" >"$6"
  chmod 600 "$6"
}

sdd_dispatch_case() {
  local edge_id="$1" task_ids="$2" stage="$3" raw_attempt="$4" output_name="$5"
  local wave=1 attempt="$raw_attempt" SDD_BATCH_TASK_IDS="$task_ids" task_inputs_json
  . "$TMP/batch-callsite.sh" >/dev/null
  printf -v "$output_name" '%s' "$task_inputs_json"
}

implement_json=
spec_json=
quality_json=
premerge_json=
sdd_dispatch_case sdd.task.implement '41 42' implement 7 implement_json
sdd_dispatch_case sdd.task.spec_review 43 spec-review 1 spec_json
sdd_dispatch_case sdd.task.quality_review 44 quality-review 1 quality_json
sdd_dispatch_case sdd.premerge.test_review 45 test-review 1 premerge_json

python3 -I -B - \
  "$implement_json" "$spec_json" "$quality_json" "$premerge_json" \
  "$task_path" "$SDD_WORKTREE" "$allowed_paths_json" "$denied_paths_json" "$failure_path" "$attempt" \
  "$spec_path" "$plan_path" "$commit_sha" "$report_path" "$base_sha" "$head_sha" \
  "$commit_range_path" "$acceptance_path" "$summary_path" <<'PY'
import json
import os
import sys

(
    implement_raw, spec_raw, quality_raw, premerge_raw,
    task_path, working_dir, allowed_raw, denied_raw, failure_path, attempt,
    spec_path, plan_path, commit_sha, report_path, base_sha, head_sha,
    commit_range_path, acceptance_path, summary_path,
) = sys.argv[1:]

assert json.loads(implement_raw) == {
    "task_path": task_path,
    "working_dir": working_dir,
    "allowed_paths": [os.path.realpath(os.path.join(working_dir, path)) for path in json.loads(allowed_raw)],
    "denied_paths": [os.path.realpath(os.path.join(working_dir, path)) for path in json.loads(denied_raw)],
    "failure_path": failure_path,
    "attempt": int(attempt),
}
assert json.loads(spec_raw) == {
    "spec_path": spec_path,
    "plan_path": plan_path,
    "commit_sha": commit_sha,
    "allowed_paths": [os.path.realpath(os.path.join(working_dir, path)) for path in json.loads(allowed_raw)],
    "report_path": report_path,
}
assert json.loads(quality_raw) == {
    "plan_path": plan_path,
    "base_sha": base_sha,
    "head_sha": head_sha,
    "allowed_paths": [os.path.realpath(os.path.join(working_dir, path)) for path in json.loads(allowed_raw)],
    "report_path": report_path,
}
assert json.loads(premerge_raw) == {
    "commit_range_path": commit_range_path,
    "spec_path": spec_path,
    "plan_path": plan_path,
    "acceptance_path": acceptance_path,
    "summary_path": summary_path,
}
PY

EXPECTED_EDGES="$(printf '%s\n' \
  sdd.task.implement \
  sdd.task.implement \
  sdd.task.spec_review \
  sdd.task.quality_review \
  sdd.premerge.test_review)"
[ "$(<"$BUILDER_LOG")" = "$EXPECTED_EDGES" ] || {
  printf 'SDD input builders were not used exactly once per routed edge\nexpected:\n%s\nactual:\n%s\n' \
    "$EXPECTED_EDGES" "$(<"$BUILDER_LOG")" >&2
  exit 1
}
[ "$(<"$CANONICALIZE_LOG")" = "$EXPECTED_EDGES" ] || {
  printf 'SDD production batch callsite did not canonicalize each routed edge\n' >&2
  exit 1
}
[ "$(<"$VALIDATE_LOG")" = "$EXPECTED_EDGES" ] || {
  printf 'SDD production batch callsite did not validate each routed edge\n' >&2
  exit 1
}

python3 -I -B - \
  "$RECEIPT_FILE" "$UBERDEV_CHILD_TEST_SOURCE" \
  "$BUILDER_INPUTS_LOG" "$VALIDATED_INPUTS_LOG" <<'PY'
import copy
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

path, source, builder_inputs_path, validated_inputs_path = sys.argv[1:]
rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
built_raw = Path(builder_inputs_path).read_text().splitlines()
validated_raw = Path(validated_inputs_path).read_text().splitlines()
cases = [
    ("sdd.implement.41", "sdd.task.implement", "sdd-w1-t41-implement-a7"),
    ("sdd.implement.42", "sdd.task.implement", "sdd-w1-t42-implement-a7"),
    ("sdd.spec_review", "sdd.task.spec_review", "sdd-w1-t43-spec-review-a1"),
    ("sdd.quality_review", "sdd.task.quality_review", "sdd-w1-t44-quality-review-a1"),
    ("sdd.pre_merge_test_analysis", "sdd.premerge.test_review", "sdd-w1-t45-test-review-a1"),
]
assert len(built_raw) == len(cases), built_raw
assert len(validated_raw) == len(cases), validated_raw

def inputs_digest(raw):
    canonical = json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()

def validate_shape(row):
    assert isinstance(row, dict), "incomplete receipt: row is not an object"
    event = row.get("event")
    assert event in {"build", "handoff", "dispatch"}, f"unknown receipt event: {event!r}"
    expected = {"schema_version", "event", "source", "edge_id", "inputs_sha256"}
    if event != "build":
        expected.add("instance_id")
    assert set(row) == expected, f"incomplete receipt fields: {row!r}"
    assert row["schema_version"] == 1, f"unknown receipt schema: {row!r}"
    assert row["source"] == source, f"unknown receipt source: {row!r}"
    assert re.fullmatch(r"[0-9a-f]{64}", row["inputs_sha256"]), (
        f"incomplete receipt digest: {row!r}"
    )

def validate_receipts(candidate_rows):
    for row in candidate_rows:
        validate_shape(row)
    expected = []
    expected_by_edge = defaultdict(list)
    for index, ((name, edge_id, instance_id), built, validated) in enumerate(
        zip(cases, built_raw, validated_raw)
    ):
        item = {
            "name": name,
            "edge_id": edge_id,
            "instance_id": instance_id,
            "built_digest": inputs_digest(built),
            "validated_digest": inputs_digest(validated),
        }
        if edge_id == "sdd.premerge.test_review":
            assert item["built_digest"] == item["validated_digest"], (
                f"{name}: unexpected input transformation"
            )
        else:
            assert item["built_digest"] != item["validated_digest"], (
                f"{name}: missing canonical input snapshot"
            )
        expected.append(item)
        expected_by_edge[edge_id].append(index)

    next_handoff = defaultdict(int)
    pending_builds = defaultdict(list)
    chains = {}
    for event_index, row in enumerate(candidate_rows):
        edge_id = row["edge_id"]
        assert edge_id in expected_by_edge, f"unknown receipt edge: {row!r}"
        if row["event"] == "build":
            pending_builds[edge_id].append((event_index, row["inputs_sha256"]))
            continue
        if row["event"] == "handoff":
            position = next_handoff[edge_id]
            assert position < len(expected_by_edge[edge_id]), (
                f"unmatched handoff event: {row!r}"
            )
            item = expected[expected_by_edge[edge_id][position]]
            next_handoff[edge_id] += 1
            assert row["instance_id"] == item["instance_id"], (
                f"{item['name']}: unmatched handoff instance: {row!r}"
            )
            snapshots = pending_builds.pop(edge_id, [])
            snapshot_digests = [digest for _, digest in snapshots]
            assert snapshot_digests, (
                f"{item['name']}: incomplete build snapshot chain: {snapshot_digests!r}"
            )
            assert snapshot_digests[-1] == item["validated_digest"], (
                f"{item['name']}: final build snapshot is not canonical"
            )
            assert len(snapshot_digests) >= 2, (
                f"{item['name']}: incomplete build snapshot chain: {snapshot_digests!r}"
            )
            assert snapshots[-1][0] == event_index - 1, (
                f"{item['name']}: final build snapshot was not immediately before handoff"
            )
            if item["built_digest"] == item["validated_digest"]:
                assert set(snapshot_digests) == {item["validated_digest"]}, (
                    f"{item['name']}: unknown duplicate build snapshot"
                )
            else:
                assert snapshot_digests[0] == item["built_digest"], (
                    f"{item['name']}: first build snapshot is not constructor output"
                )
                first_validated = snapshot_digests.index(item["validated_digest"])
                assert snapshot_digests == (
                    [item["built_digest"]] * first_validated
                    + [item["validated_digest"]] * (len(snapshot_digests) - first_validated)
                ), f"{item['name']}: build snapshots are out of order"
            assert row["inputs_sha256"] in snapshot_digests, (
                f"{item['name']}: unmatched validated digest: {row['inputs_sha256']}"
            )
            assert row["inputs_sha256"] == item["validated_digest"], (
                f"{item['name']}: handoff did not use validated canonical inputs"
            )
            chains[item["instance_id"]] = {
                **item,
                "snapshots": snapshot_digests,
                "handoff_digest": row["inputs_sha256"],
                "handoff_index": event_index,
                "dispatch_index": None,
            }
            continue

        instance_id = row["instance_id"]
        assert instance_id in chains, f"unmatched dispatch event: {row!r}"
        chain = chains[instance_id]
        assert chain["dispatch_index"] is None, f"duplicate dispatch event: {row!r}"
        assert edge_id == chain["edge_id"], f"{chain['name']}: dispatch edge mismatch"
        assert row["inputs_sha256"] in chain["snapshots"], (
            f"{chain['name']}: unmatched validated digest: {row['inputs_sha256']}"
        )
        assert row["inputs_sha256"] == chain["validated_digest"], (
            f"{chain['name']}: dispatch did not use validated canonical inputs"
        )
        assert row["inputs_sha256"] == chain["handoff_digest"], (
            f"{chain['name']}: handoff/dispatch digest mismatch"
        )
        chain["dispatch_index"] = event_index

    for edge_id, indexes in expected_by_edge.items():
        assert next_handoff[edge_id] == len(indexes), f"incomplete handoff events: {edge_id}"
        assert not pending_builds[edge_id], f"late build snapshots: {edge_id}"
    assert set(chains) == {item["instance_id"] for item in expected}, (
        "incomplete receipt chains"
    )
    for chain in chains.values():
        assert chain["dispatch_index"] is not None, (
            f"{chain['name']}: incomplete dispatch event"
        )
        assert chain["handoff_index"] < chain["dispatch_index"], (
            f"{chain['name']}: dispatch preceded handoff"
        )
    return chains

chains = validate_receipts(rows)
first_implement = chains["sdd-w1-t41-implement-a7"]
second_implement = chains["sdd-w1-t42-implement-a7"]
assert (
    first_implement["handoff_index"]
    < second_implement["handoff_index"]
    < first_implement["dispatch_index"]
), "two-task batch did not exercise non-contiguous dispatch correlation"

additional_snapshot = copy.deepcopy(rows)
first_handoff = next(
    index for index, row in enumerate(additional_snapshot)
    if row["edge_id"] == "sdd.task.implement" and row["event"] == "handoff"
)
additional_snapshot.insert(first_handoff, copy.deepcopy(additional_snapshot[first_handoff - 1]))
validate_receipts(additional_snapshot)

def assert_rejected(mutated, needle):
    try:
        validate_receipts(mutated)
    except AssertionError as error:
        assert needle in str(error), (needle, str(error))
    else:
        raise AssertionError(f"receipt mutation accepted: {needle}")

swapped = copy.deepcopy(rows)
implement_builds = [
    index for index, row in enumerate(swapped)
    if row["edge_id"] == "sdd.task.implement" and row["event"] == "build"
]
swapped[implement_builds[0]], swapped[implement_builds[1]] = (
    swapped[implement_builds[1]], swapped[implement_builds[0]]
)
assert_rejected(swapped, "final build snapshot is not canonical")

late = copy.deepcopy(rows)
first_handoff = next(
    index for index, row in enumerate(late)
    if row.get("instance_id") == "sdd-w1-t41-implement-a7" and row["event"] == "handoff"
)
late_snapshot = late.pop(first_handoff - 1)
late.insert(first_handoff, late_snapshot)
assert_rejected(late, "final build snapshot is not canonical")

unmatched = copy.deepcopy(rows)
for row in unmatched:
    if row["edge_id"] == "sdd.task.implement" and row["event"] in {"handoff", "dispatch"}:
        row["inputs_sha256"] = "0" * 64
assert_rejected(unmatched, "unmatched validated digest")

unknown = copy.deepcopy(rows)
unknown[0]["event"] = "launch"
assert_rejected(unknown, "unknown receipt event")

incomplete = copy.deepcopy(rows)
del incomplete[0]["source"]
assert_rejected(incomplete, "incomplete receipt")

missing_terminal = copy.deepcopy(rows[:-1])
assert_rejected(missing_terminal, "incomplete dispatch event")

raw_implement = json.loads(built_raw[0])
validated_implement = json.loads(validated_raw[0])
assert all(not os.path.isabs(path) for path in raw_implement["allowed_paths"])
assert all(not os.path.isabs(path) for path in raw_implement["denied_paths"])
assert all(os.path.isabs(path) for path in validated_implement["allowed_paths"])
assert all(os.path.isabs(path) for path in validated_implement["denied_paths"])
implement_inputs = validated_implement
assert implement_inputs["attempt"] == 7
assert implement_inputs["failure_path"] == ""
PY

[ "$(<"$PROVIDER_LOG")" = "$(printf '%s\n' \
  sdd-w1-t41-implement-a7 \
  sdd-w1-t42-implement-a7 \
  sdd-w1-t43-spec-review-a1 \
  sdd-w1-t44-quality-review-a1 \
  sdd-w1-t45-test-review-a1)" ] || {
  printf 'SDD runtime provider seam was not crossed exactly once per constructor\n' >&2
  exit 1
}

STATE_DIR="$RUN_DIR/.agent-state-$(id -u)"
python3 -I -B - \
  "$PROVIDER_ARGS_LOG" "$STATE_DIR/agent-lifecycle.jsonl" "$STATE_DIR/semaphore-v1" <<'PY'
import json
import re
import sys
from pathlib import Path

provider_path, lifecycle_path, semaphore_path = map(Path, sys.argv[1:])
provider_rows = [json.loads(line) for line in provider_path.read_text().splitlines()]
lifecycle_rows = [json.loads(line) for line in lifecycle_path.read_text().splitlines()]
expectations = {
    "sdd-w1-t41-implement-a7": ("quality", "standard", "medium", "workspace-write", "implementation-worker", "implementation"),
    "sdd-w1-t42-implement-a7": ("quality", "standard", "medium", "workspace-write", "implementation-worker", "implementation"),
    "sdd-w1-t43-spec-review-a1": ("deep", "deep", "high", "read-only", "spec-compliance-reviewer", "implementation_review"),
    "sdd-w1-t44-quality-review-a1": ("deep", "deep", "high", "read-only", "code-reviewer", "implementation_review"),
    "sdd-w1-t45-test-review-a1": ("deep", "deep", "high", "read-only", "pr-test-analyzer", "implementation_review"),
}
assert [row["instance_id"] for row in provider_rows] == list(expectations), provider_rows
decision_keys = {
    "adaptive_fallback", "adaptive_proposal", "backend", "effective_policy",
    "fallback_chain", "field_sources", "forced", "ignored_fields", "ignored_sources",
    "logical_route", "minimum_route", "model", "policy_version", "reason_codes",
    "reasoning_effort", "risk_scope", "risk_signals", "route_source", "routing_mode",
    "sandbox", "schema_version", "service_tier",
}
provider_by_instance = {}
for row in provider_rows:
    assert set(row) == {
        "instance_id", "backend", "issue", "tier", "prompt", "result", "status", "decision"
    }, row
    instance = row["instance_id"]
    route, minimum, effort, sandbox, _, _ = expectations[instance]
    assert (row["backend"], row["issue"], row["tier"]) == ("background", 42, "large")
    child = Path(row["prompt"]).parent
    assert child.name == instance
    assert Path(row["prompt"]).name == "prompt.txt" and Path(row["prompt"]).is_file()
    assert Path(row["result"]).parent == child and Path(row["result"]).name == "result.md"
    assert Path(row["status"]).parent == child and Path(row["status"]).name == "status.json"
    assert Path(row["result"]).is_file() and Path(row["status"]).is_file()
    decision = row["decision"]
    # #381 RULING 1: the adaptive per-rank decision this block used to assert
    # was produced ONLY for the codex backend. Every surviving backend takes
    # lib/agent-dispatch.sh's backend-neutral-inherit branch, whose decision is
    # a fixed, deliberately empty shape: no logical route, no model, no
    # reasoning_effort, no sandbox, no policy_version, no field_sources. The
    # per-role route/effort/sandbox expectations above are therefore no longer
    # decidable at this seam, and asserting them would assert an enforcement no
    # consumer honours. What IS still true, and what a child's authority
    # actually depends on, is that the decision is explicitly and completely
    # neutral -- so that is what is asserted, exactly, key for key.
    assert decision == {
        "schema_version": 1,
        "backend": "background",
        "routing_mode": "inherit",
        "effective_policy": "inherit",
        "route_source": "backend-neutral-inherit",
        "logical_route": None,
        "minimum_route": None,
        "model": None,
        "reasoning_effort": None,
        "sandbox": None,
        "service_tier": "default",
        "forced": False,
        "risk_signals": [],
        "fallback_chain": [],
    }, decision
    provider_by_instance[instance] = row

assert len(lifecycle_rows) == len(expectations) * 3, lifecycle_rows
assert {row["run_id"] for row in lifecycle_rows} == set(expectations), lifecycle_rows
for instance, (route, _, effort, sandbox, role, phase) in expectations.items():
    events = [row for row in lifecycle_rows if row["run_id"] == instance]
    assert [row["event"] for row in events] == ["route_decided", "agent_started", "completed"], events
    for row in events:
        assert row["agent_id"] == instance and row["backend"] == "background"
        assert row["workflow"] == "solve" and row["task_tier"] == "large"
        assert row["parent_run_id"] == "sdd-receipt-root"
        assert row["role"] == role and row["phase"] == phase
        # Same #381 RULING 1 consequence as the decision block above: the
        # lifecycle row relays whatever the decision carried, and the neutral
        # decision carries nothing. These must be absent-or-null rather than a
        # per-role route, or the guard would be re-asserting the retired
        # enforcement one layer out.
        assert row.get("decision_logical_route") in (None, ""), row
        assert row.get("decision_reasoning_effort") in (None, ""), row
        assert row.get("effective_logical_route") in (None, ""), row
        assert row.get("effective_reasoning_effort") in (None, ""), row
        assert row.get("effective_sandbox") in (None, ""), row
        assert row.get("effective_model") in (None, ""), row
    assert events[1]["status_path"] == provider_by_instance[instance]["status"]
    assert events[1]["timeout_s"] == 3600 and type(events[1]["owner_pid"]) is int
    assert events[2]["terminal_status"] == "completed"

leases = list(Path(semaphore_path).rglob("*.lease")) if Path(semaphore_path).exists() else []
assert leases == [], leases
PY

unset UBERDEV_CHILD_TEST_SOURCE UBERDEV_CHILD_TEST_RECEIPT_FILE
failure_path="$failure_fixture_path"

for zero_spelling in 00 000 000000; do
  builder_calls_before="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
  if sdd_validate_instance_dimensions 1 1 implement "$zero_spelling"; then
    printf 'all-zero attempt spelling was accepted: %s\n' "$zero_spelling" >&2
    exit 1
  fi
  builder_calls_after="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
  [ "$builder_calls_after" -eq "$builder_calls_before" ] || {
    printf 'all-zero attempt reached input construction: %s\n' "$zero_spelling" >&2
    exit 1
  }
done

for numeric_case in '007|7' '01|1' '00042|42' '10|10'; do
  attempt="${numeric_case%%|*}"
  expected_attempt="${numeric_case#*|}"
  sdd_validate_instance_dimensions 1 1 implement "$attempt"
  normalized_json="$(sdd_inputs_for_task sdd.task.implement 45)"
  python3 -I -B - "$normalized_json" "$expected_attempt" "$failure_path" <<'PY'
import json
import sys

inputs = json.loads(sys.argv[1])
actual = inputs["attempt"]
expected = int(sys.argv[2])
assert type(actual) is int
assert actual == expected, (actual, expected)
assert inputs["failure_path"] == sys.argv[3]
PY
done

grep -Fq 'task_inputs_json="$(uberdev_child_inputs_validate "$edge_id" "$task_inputs_json")" || return 2' "$SKILL"
! grep -Eq 'json\.dumps\(\{.*(task_path|spec_path|base_sha|commit_range_path)' "$TMP/runtime.sh"

echo 'sdd-child-inputs: PASS'
