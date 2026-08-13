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

# #458: the allocation grammar is plan-scoped, so every expected instance ID in
# this file is derived from the fixture plan rather than hardcoded. The fixture
# plan lives under `mktemp -d`, so its realpath — and therefore its scope —
# differs on every run; a literal `sdd-p<hex>-…` would red permanently. The
# scope-value-free oracle for the fix is the two-plan disjointness block at the
# end of this file, which never mentions a scope value at all.
FIXTURE_SCOPE="$(sdd_plan_scope "$plan_path")"

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
  "$BUILDER_INPUTS_LOG" "$VALIDATED_INPUTS_LOG" "$FIXTURE_SCOPE" <<'PY'
import copy
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

path, source, builder_inputs_path, validated_inputs_path, scope = sys.argv[1:]
assert re.fullmatch(r"[0-9a-f]{12}", scope), scope
rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
built_raw = Path(builder_inputs_path).read_text().splitlines()
validated_raw = Path(validated_inputs_path).read_text().splitlines()
cases = [
    ("sdd.implement.41", "sdd.task.implement", f"sdd-p{scope}-w1-t41-implement-a7"),
    ("sdd.implement.42", "sdd.task.implement", f"sdd-p{scope}-w1-t42-implement-a7"),
    ("sdd.spec_review", "sdd.task.spec_review", f"sdd-p{scope}-w1-t43-spec-review-a1"),
    ("sdd.quality_review", "sdd.task.quality_review", f"sdd-p{scope}-w1-t44-quality-review-a1"),
    ("sdd.pre_merge_test_analysis", "sdd.premerge.test_review", f"sdd-p{scope}-w1-t45-test-review-a1"),
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
first_implement = chains[f"sdd-p{scope}-w1-t41-implement-a7"]
second_implement = chains[f"sdd-p{scope}-w1-t42-implement-a7"]
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
    if row.get("instance_id") == f"sdd-p{scope}-w1-t41-implement-a7" and row["event"] == "handoff"
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
  "sdd-p${FIXTURE_SCOPE}-w1-t41-implement-a7" \
  "sdd-p${FIXTURE_SCOPE}-w1-t42-implement-a7" \
  "sdd-p${FIXTURE_SCOPE}-w1-t43-spec-review-a1" \
  "sdd-p${FIXTURE_SCOPE}-w1-t44-quality-review-a1" \
  "sdd-p${FIXTURE_SCOPE}-w1-t45-test-review-a1")" ] || {
  printf 'SDD runtime provider seam was not crossed exactly once per constructor\n' >&2
  exit 1
}

STATE_DIR="$RUN_DIR/.agent-state-$(id -u)"
python3 -I -B - \
  "$PROVIDER_ARGS_LOG" "$STATE_DIR/agent-lifecycle.jsonl" "$STATE_DIR/semaphore-v1" \
  "$FIXTURE_SCOPE" <<'PY'
import json
import re
import sys
from pathlib import Path

provider_path, lifecycle_path, semaphore_path = map(Path, sys.argv[1:4])
scope = sys.argv[4]
assert re.fullmatch(r"[0-9a-f]{12}", scope), scope
provider_rows = [json.loads(line) for line in provider_path.read_text().splitlines()]
lifecycle_rows = [json.loads(line) for line in lifecycle_path.read_text().splitlines()]
expectations = {
    f"sdd-p{scope}-w1-t41-implement-a7": ("quality", "standard", "medium", "workspace-write", "implementation-worker", "implementation"),
    f"sdd-p{scope}-w1-t42-implement-a7": ("quality", "standard", "medium", "workspace-write", "implementation-worker", "implementation"),
    f"sdd-p{scope}-w1-t43-spec-review-a1": ("deep", "deep", "high", "read-only", "spec-compliance-reviewer", "implementation_review"),
    f"sdd-p{scope}-w1-t44-quality-review-a1": ("deep", "deep", "high", "read-only", "code-reviewer", "implementation_review"),
    f"sdd-p{scope}-w1-t45-test-review-a1": ("deep", "deep", "high", "read-only", "pr-test-analyzer", "implementation_review"),
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

# ── #459 — reviewer result paths survive the wait (AC-7) ──────────────────────
# `sdd_wait_prepared_batch` calls `sdd_reset_batch` on every exit path, so by the
# time the controller reads a reviewer verdict the per-instance result paths are
# gone. `sdd_snapshot_batch_results` is the only thing standing between the fix
# ledger's "verbatim findings" and being unimplementable. Drive it through the
# real batch callsite, with a task id that cannot collide with 41/42/43/44/45 —
# instance ids are never reused, and a repeat fires the receipt chain's
# `duplicate dispatch event` assertion above.
snapshot_json=
sdd_dispatch_case sdd.task.implement 51 implement 1 snapshot_json
[ "${#SDD_PREPARED_INSTANCES[@]}" -eq 0 ] || {
  printf 'wait did not reset SDD_PREPARED_INSTANCES (%s left)\n' \
    "${#SDD_PREPARED_INSTANCES[@]}" >&2
  exit 1
}
[ "${#SDD_BATCH_RESULT_INSTANCES[@]}" -eq 1 ] || {
  printf 'snapshot did not retain exactly one instance (got %s)\n' \
    "${#SDD_BATCH_RESULT_INSTANCES[@]}" >&2
  exit 1
}
[ "${#SDD_BATCH_RESULT_PATHS[@]}" -eq "${#SDD_BATCH_RESULT_INSTANCES[@]}" ] || {
  printf 'snapshot arrays are not pairwise aligned (%s instances, %s results)\n' \
    "${#SDD_BATCH_RESULT_INSTANCES[@]}" "${#SDD_BATCH_RESULT_PATHS[@]}" >&2
  exit 1
}
[ "${SDD_BATCH_RESULT_INSTANCES[0]}" = "sdd-p${FIXTURE_SCOPE}-w1-t51-implement-a1" ] || {
  printf 'snapshot instance mismatch: %s\n' "${SDD_BATCH_RESULT_INSTANCES[0]}" >&2
  exit 1
}
[ -f "${SDD_BATCH_RESULT_PATHS[0]}" ] || {
  printf 'snapshot result path is not a regular file: %s\n' \
    "${SDD_BATCH_RESULT_PATHS[0]}" >&2
  exit 1
}

# ── #459 — exhaustion stops dispatch, ledger rides as failure_path (AC-3/AC-5) ─
# The composition lock. Drive rounds 1..cap+1 through the production batch
# callsite: exactly `cap` builder calls may happen, the cap+1 round must add
# zero, and every fix dispatch must carry the ledger as `failure_path`. The
# ledger lives in the private run directory that already holds `task_path` —
# `uberdev_child_inputs_validate` rejects anything outside that scope, and the
# append must precede the dispatch because a non-empty path input has to exist.
LEDGER_T52="$INPUT_DIR/fix-ledger-t52.md"
FINDINGS_T52="$INPUT_DIR/findings-t52.md"
printf 'spec reviewer: missing edge case for empty input\n' >"$FINDINGS_T52"
chmod 600 "$FINDINGS_T52"

saved_failure_path="$failure_path"
failure_path="$LEDGER_T52"
builder_before_fix_loop="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
builder_at_cap=''
fix_json=
fix_round=1
while [ "$fix_round" -le 4 ]; do
  fix_round_rc=0
  sdd_round_permitted fix_rounds "$fix_round" || fix_round_rc=$?
  if [ "$fix_round_rc" -eq 0 ]; then
    sdd_append_fix_ledger "$LEDGER_T52" "$fix_round" fix_rounds spec-fix \
      "sdd-w1-t52-spec-review-a$fix_round" "$task_path" "$report_path" "$FINDINGS_T52"
    sdd_dispatch_case sdd.task.implement "5$((2 + fix_round))" spec-fix "$fix_round" fix_json
  else
    [ "$fix_round_rc" -eq 3 ] || {
      printf 'round breaker returned %s at round %s, expected 3\n' \
        "$fix_round_rc" "$fix_round" >&2
      exit 1
    }
    builder_at_cap="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
    sdd_note_cap_exhausted "$LEDGER_T52" fix_rounds "$fix_round"
  fi
  fix_round=$((fix_round + 1))
done
builder_after_fix_loop="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
[ -n "$builder_at_cap" ] || {
  printf 'round breaker never fired across rounds 1..4\n' >&2
  exit 1
}
[ "$((builder_after_fix_loop - builder_before_fix_loop))" -eq 3 ] || {
  printf 'fix loop built %s dispatches, expected exactly the fix_rounds cap (3)\n' \
    "$((builder_after_fix_loop - builder_before_fix_loop))" >&2
  exit 1
}
[ "$builder_after_fix_loop" -eq "$builder_at_cap" ] || {
  printf 'the cap+1 round still reached input construction (%s -> %s)\n' \
    "$builder_at_cap" "$builder_after_fix_loop" >&2
  exit 1
}
python3 -I -B - "$fix_json" "$LEDGER_T52" <<'PY'
import json
import sys

inputs = json.loads(sys.argv[1])
assert inputs["failure_path"] == sys.argv[2], inputs
PY
ledger_exhaustion_line="$(tail -n 1 "$LEDGER_T52")"
[ "$ledger_exhaustion_line" = '## cap exhausted | loop fix_rounds | round 4 | cap 3' ] || {
  printf 'cap exhaustion is not the last thing on the ledger: %s\n' \
    "$ledger_exhaustion_line" >&2
  exit 1
}
failure_path="$saved_failure_path"

unset UBERDEV_CHILD_TEST_SOURCE UBERDEV_CHILD_TEST_RECEIPT_FILE
failure_path="$failure_fixture_path"

# ===========================================================================
# #458 — the plan-scope mint's contract.
#
# `sdd_plan_scope` is the identity function the whole fix rests on: it turns a
# plan file into a 12-hex allocation scope that is deterministic per plan and
# disjoint across plans. Identity is realpath(plan) + NUL + plan bytes, so
# neither a shared basename (this repo's plans land at
# docs/uberdev/plans/YYYY-MM-DD-<slug>.md, and two same-day runs on one slug
# share one) nor a byte-identical copy at another path can collapse two plans
# into one scope.
# ===========================================================================
SCOPE_DIR="$TMP/scope"
mkdir -p "$SCOPE_DIR/twin"
chmod 700 "$SCOPE_DIR" "$SCOPE_DIR/twin"
PLAN_A="$SCOPE_DIR/plan-a.md"
PLAN_B="$SCOPE_DIR/plan-b.md"
PLAN_TWIN="$SCOPE_DIR/twin/plan-a.md"
PLAN_MUTABLE="$SCOPE_DIR/plan-mutable.md"
printf 'plan a: wave 1 / task 41 / implement\n' >"$PLAN_A"
printf 'plan b: wave 1 / task 41 / implement (different body)\n' >"$PLAN_B"
printf 'plan a: wave 1 / task 41 / implement\n' >"$PLAN_TWIN"
printf 'plan mutable: first body\n' >"$PLAN_MUTABLE"
chmod 600 "$PLAN_A" "$PLAN_B" "$PLAN_TWIN" "$PLAN_MUTABLE"

SCOPE_PLAN_A="$(sdd_plan_scope "$PLAN_A")"
SCOPE_PLAN_A_AGAIN="$(sdd_plan_scope "$PLAN_A")"
[ "$SCOPE_PLAN_A" = "$SCOPE_PLAN_A_AGAIN" ] || {
  printf 'plan scope is not deterministic: %s vs %s\n' "$SCOPE_PLAN_A" "$SCOPE_PLAN_A_AGAIN" >&2
  exit 1
}

SCOPE_PLAN_B="$(sdd_plan_scope "$PLAN_B")"
[ "$SCOPE_PLAN_A" != "$SCOPE_PLAN_B" ] || {
  printf 'two distinct plans collapsed into one scope: %s\n' "$SCOPE_PLAN_A" >&2
  exit 1
}

# Same basename AND identical bytes, different directory: a basename-keyed
# scheme (upstream superpowers keys the workspace on the plan basename) would
# collapse these two; the realpath term is what keeps them apart.
SCOPE_PLAN_TWIN="$(sdd_plan_scope "$PLAN_TWIN")"
[ "$SCOPE_PLAN_A" != "$SCOPE_PLAN_TWIN" ] || {
  printf 'byte-identical plans at different paths shared one scope: %s\n' "$SCOPE_PLAN_A" >&2
  exit 1
}

# Same path, different bytes: the bytes term is what keeps two same-day plans
# that reuse one filename apart.
SCOPE_MUTABLE_FIRST="$(sdd_plan_scope "$PLAN_MUTABLE")"
printf 'plan mutable: second body\n' >"$PLAN_MUTABLE"
SCOPE_MUTABLE_SECOND="$(sdd_plan_scope "$PLAN_MUTABLE")"
[ "$SCOPE_MUTABLE_FIRST" != "$SCOPE_MUTABLE_SECOND" ] || {
  printf 'rewritten plan bytes reused the previous scope: %s\n' "$SCOPE_MUTABLE_FIRST" >&2
  exit 1
}

# IDENT-legal shape: exactly 12 lowercase hex characters, so the composed
# instance ID stays inside the handoff schema's identifier grammar.
case "$SCOPE_PLAN_A" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *)
    printf 'plan scope is not 12 lowercase hex characters: %s\n' "$SCOPE_PLAN_A" >&2
    exit 1
    ;;
esac

assert_plan_scope_refused() {
  local label="$1" diagnostic="$2" refusal_err refusal_rc=0
  shift 2
  refusal_err="$(sdd_plan_scope "$@" 2>&1 >/dev/null)" || refusal_rc=$?
  [ "$refusal_rc" -ne 0 ] || {
    printf 'plan scope accepted a refused input: %s\n' "$label" >&2
    exit 1
  }
  [ -z "$diagnostic" ] || grep -q "$diagnostic" <<<"$refusal_err" || {
    printf 'plan scope refusal %s lacked diagnostic %s; stderr=[%s]\n' \
      "$label" "$diagnostic" "$refusal_err" >&2
    exit 1
  }
}

assert_plan_scope_refused relative-path plan_scope_path_not_absolute plan-a.md
assert_plan_scope_refused empty-path plan_scope_path_not_absolute ''
assert_plan_scope_refused missing-file plan_scope_unreadable "$SCOPE_DIR/missing.md"
assert_plan_scope_refused no-argument ''

# root reads a 0000 file, so this arm only proves anything for a non-root uid.
if [ "$(id -u)" -ne 0 ]; then
  PLAN_UNREADABLE="$SCOPE_DIR/plan-unreadable.md"
  printf 'plan unreadable\n' >"$PLAN_UNREADABLE"
  chmod 000 "$PLAN_UNREADABLE"
  assert_plan_scope_refused unreadable-file plan_scope_unreadable "$PLAN_UNREADABLE"
  chmod 600 "$PLAN_UNREADABLE"
fi

# ===========================================================================
# #458 — the plan scope is a MANDATORY fifth instance dimension.
#
# The positive control below is what keeps the all-zero loop that follows
# honest: without it, that loop would start passing on arity (four arguments
# against a five-argument validator) rather than on the zero it exists to
# reject.
# ===========================================================================
VALID_SCOPE="$SCOPE_PLAN_A"
sdd_validate_instance_dimensions 1 1 implement 7 "$VALID_SCOPE" || {
  printf 'a fully valid five-dimension instance was rejected\n' >&2
  exit 1
}

if sdd_validate_instance_dimensions 1 1 implement 7; then
  printf 'four-argument instance dimensions were accepted without a plan scope\n' >&2
  exit 1
fi

for malformed_scope in '' ABCDEF012345 0123456789ab0 xyz012345678 0123456789a; do
  builder_calls_before="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
  if sdd_validate_instance_dimensions 1 1 implement 7 "$malformed_scope"; then
    printf 'malformed plan scope was accepted: [%s]\n' "$malformed_scope" >&2
    exit 1
  fi
  builder_calls_after="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
  [ "$builder_calls_after" -eq "$builder_calls_before" ] || {
    printf 'malformed plan scope reached input construction: [%s]\n' "$malformed_scope" >&2
    exit 1
  }
done

for zero_spelling in 00 000 000000; do
  builder_calls_before="$(wc -l <"$BUILDER_LOG" | tr -d ' ')"
  if sdd_validate_instance_dimensions 1 1 implement "$zero_spelling" "$VALID_SCOPE"; then
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
  sdd_validate_instance_dimensions 1 1 implement "$attempt" "$VALID_SCOPE"
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

# ══ #459 — the loop caps become code, the fix loop gains a continuity carrier ══
# Everything below is pure-helper: no dispatch, so it is safe after the
# `UBERDEV_CHILD_TEST_SOURCE` unset above (the backend stub dereferences it).

sdd_rc() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# ── AC-1: the caps are readable by code ──────────────────────────────────────
for cap_case in 'fix_rounds|3' 'retest_rounds|2' 'context_rounds|2'; do
  cap_name="${cap_case%%|*}"
  cap_expected="${cap_case#*|}"
  cap_actual="$(sdd_loop_cap "$cap_name")"
  [ "$cap_actual" = "$cap_expected" ] || {
    printf 'sdd_loop_cap %s printed %s, expected %s\n' \
      "$cap_name" "$cap_actual" "$cap_expected" >&2
    exit 1
  }
done

for cap_reject in bogus '' spec_rounds fix_round; do
  cap_reject_rc=0
  cap_reject_out="$(sdd_loop_cap "$cap_reject")" || cap_reject_rc=$?
  [ "$cap_reject_rc" -eq 2 ] || {
    printf 'sdd_loop_cap accepted %s (rc %s)\n' "$cap_reject" "$cap_reject_rc" >&2
    exit 1
  }
  [ -z "$cap_reject_out" ] || {
    printf 'sdd_loop_cap printed %s for rejected token %s\n' \
      "$cap_reject_out" "$cap_reject" >&2
    exit 1
  }
done
cap_reject_rc=0
cap_reject_out="$(sdd_loop_cap)" || cap_reject_rc=$?
[ "$cap_reject_rc" -eq 2 ] && [ -z "$cap_reject_out" ] || {
  printf 'sdd_loop_cap with no argument returned rc %s / output %s\n' \
    "$cap_reject_rc" "$cap_reject_out" >&2
  exit 1
}

# ── AC-9a: the `## Loop caps` prose and sdd_loop_cap are the same vocabulary ──
# Extraction, not presence: a name-only guard would silently miss a value drift,
# so every extracted value is compared too. The count row is the anti-vacuity
# half — a regex that matched nothing would otherwise satisfy every claim here.
SKILL_CAP_PAIRS="$(python3 -I -B - "$SKILL" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
section = re.search(r"^## Loop caps\n(.*?)(?=^## )", text, re.DOTALL | re.MULTILINE)
if section is None:
    raise SystemExit("SKILL.md has no '## Loop caps' section")
for name, value in re.findall(
    r"^- \*\*`([a-z_]+)` = ([0-9]+)\*\*", section.group(1), re.MULTILINE
):
    print(name, value)
PY
)"
skill_cap_count="$(grep -c '^[a-z_][a-z_]* [0-9][0-9]*$' <<<"$SKILL_CAP_PAIRS" || true)"
[ "$skill_cap_count" -eq 3 ] || {
  printf 'extracted %s cap bullets from ## Loop caps, expected 3\n' "$skill_cap_count" >&2
  exit 1
}
while read -r prose_cap_name prose_cap_value; do
  [ -n "$prose_cap_name" ] || continue
  prose_cap_actual="$(sdd_loop_cap "$prose_cap_name")" || {
    printf 'sdd_loop_cap rejects documented cap %s\n' "$prose_cap_name" >&2
    exit 1
  }
  [ "$prose_cap_actual" = "$prose_cap_value" ] || {
    printf 'cap drift: ## Loop caps says %s = %s, sdd_loop_cap says %s\n' \
      "$prose_cap_name" "$prose_cap_value" "$prose_cap_actual" >&2
    exit 1
  }
done <<<"$SKILL_CAP_PAIRS"

# ── AC-2: the breaker is a call, not a sentence ──────────────────────────────
for permitted_case in 'fix_rounds 1' 'fix_rounds 2' 'fix_rounds 3' \
  'retest_rounds 1' 'retest_rounds 2' 'context_rounds 1' 'context_rounds 2'; do
  permitted_loop="${permitted_case%% *}"
  permitted_round="${permitted_case#* }"
  permitted_rc="$(sdd_rc sdd_round_permitted "$permitted_loop" "$permitted_round")"
  [ "$permitted_rc" -eq 0 ] || {
    printf 'sdd_round_permitted %s returned %s, expected 0\n' \
      "$permitted_case" "$permitted_rc" >&2
    exit 1
  }
done

# rc 3 is deliberately distinct from the repo-wide validation rc 2 so a caller
# can tell "cap fired, route BLOCKED" from "you called me wrong". `010` is the
# case where a raw `[ ]` compare (octal 8) would disagree with the fence's own
# base-10 normaliser — the fence must have exactly one arithmetic.
for exhausted_case in 'fix_rounds 4' 'fix_rounds 007' 'fix_rounds 010' \
  'retest_rounds 3' 'context_rounds 3'; do
  exhausted_loop="${exhausted_case%% *}"
  exhausted_round="${exhausted_case#* }"
  exhausted_rc="$(sdd_rc sdd_round_permitted "$exhausted_loop" "$exhausted_round")"
  [ "$exhausted_rc" -eq 3 ] || {
    printf 'sdd_round_permitted %s returned %s, expected 3\n' \
      "$exhausted_case" "$exhausted_rc" >&2
    exit 1
  }
done

for round_reject_case in 'fix_rounds 0' 'fix_rounds ' 'fix_rounds abc' \
  'fix_rounds -1' 'bogus 1'; do
  round_reject_loop="${round_reject_case%% *}"
  round_reject_round="${round_reject_case#* }"
  round_reject_rc="$(sdd_rc sdd_round_permitted "$round_reject_loop" "$round_reject_round")"
  [ "$round_reject_rc" -eq 2 ] || {
    printf 'sdd_round_permitted %s returned %s, expected 2\n' \
      "$round_reject_case" "$round_reject_rc" >&2
    exit 1
  }
done
round_reject_rc="$(sdd_rc sdd_round_permitted fix_rounds)"
[ "$round_reject_rc" -eq 2 ] || {
  printf 'sdd_round_permitted with one argument returned %s, expected 2\n' \
    "$round_reject_rc" >&2
  exit 1
}

# ── AC-5/AC-6: the fix ledger is a real file with a fixed byte shape ─────────
LEDGER_DIR="$INPUT_DIR/ledger"
mkdir -p "$LEDGER_DIR"
LEDGER="$LEDGER_DIR/task-9-fix-ledger.md"
FINDINGS="$LEDGER_DIR/findings-round-1.md"
printf 'reviewer: "quoted" \\ backslash — non-ASCII, no trailing newline' >"$FINDINGS"
chmod 600 "$FINDINGS"

sdd_append_fix_ledger "$LEDGER" 1 fix_rounds spec-fix sdd-w1-t9-spec-review-a1 \
  "$task_path" "$report_path" "$FINDINGS"

ledger_stat="$(python3 -I -B -c 'import os,stat,sys; entry=os.lstat(sys.argv[1]); print("%s %s %s" % (oct(stat.S_IMODE(entry.st_mode)), stat.S_ISREG(entry.st_mode), entry.st_nlink), end="")' "$LEDGER")"
[ "$ledger_stat" = '0o600 True 1' ] || {
  printf 'fix ledger is not a mode-0600 regular file with one link: %s\n' \
    "$ledger_stat" >&2
  exit 1
}

python3 -I -B - "$LEDGER" "$task_path" "$report_path" "$FINDINGS" <<'PY'
import sys
from pathlib import Path

ledger, task_brief, prior_result, findings = sys.argv[1:]
body = Path(findings).read_bytes()
if not body.endswith(b"\n"):
    body += b"\n"
expected = (
    "## round 1 | loop fix_rounds | stage spec-fix\n"
    "source_instance: sdd-w1-t9-spec-review-a1\n"
    "task_brief: %s\n"
    "prior_result: %s\n"
    "findings:\n" % (task_brief, prior_result)
).encode("utf-8") + body
actual = Path(ledger).read_bytes()
assert actual == expected, (actual, expected)
PY

ledger_bytes_round_one="$(wc -c <"$LEDGER" | tr -d ' ')"
sdd_append_fix_ledger "$LEDGER" 2 fix_rounds quality-fix sdd-w1-t9-quality-review-a1 \
  "$task_path" "$report_path" "$FINDINGS"
ledger_bytes_round_two="$(wc -c <"$LEDGER" | tr -d ' ')"
[ "$ledger_bytes_round_two" -gt "$ledger_bytes_round_one" ] || {
  printf 'second append did not grow the ledger (%s -> %s)\n' \
    "$ledger_bytes_round_one" "$ledger_bytes_round_two" >&2
  exit 1
}
ledger_round_one_entries="$(grep -c '^## round 1 | loop fix_rounds | stage spec-fix$' <<<"$(cat "$LEDGER")" || true)"
[ "$ledger_round_one_entries" -eq 1 ] || {
  printf 'round-1 entry count after the second append is %s, expected 1\n' \
    "$ledger_round_one_entries" >&2
  exit 1
}

LEDGER_SYMLINK="$LEDGER_DIR/ledger-symlink.md"
ln -s "$LEDGER" "$LEDGER_SYMLINK"
LEDGER_DIRECTORY="$LEDGER_DIR/ledger-directory"
mkdir -p "$LEDGER_DIRECTORY"
ledger_bytes_guard="$ledger_bytes_round_two"

assert_ledger_rejected() {
  local label="$1"
  shift
  local rc=0
  sdd_append_fix_ledger "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || {
    printf 'sdd_append_fix_ledger accepted %s (rc %s)\n' "$label" "$rc" >&2
    exit 1
  }
  local observed
  observed="$(wc -c <"$LEDGER" | tr -d ' ')"
  [ "$observed" -eq "$ledger_bytes_guard" ] || {
    printf 'sdd_append_fix_ledger wrote while rejecting %s (%s -> %s)\n' \
      "$label" "$ledger_bytes_guard" "$observed" >&2
    exit 1
  }
}

assert_ledger_rejected 'symlink ledger' "$LEDGER_SYMLINK" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'directory ledger' "$LEDGER_DIRECTORY" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'relative ledger' 'relative-ledger.md' 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'relative findings' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" 'relative-findings.md'
assert_ledger_rejected 'relative task brief' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 'relative-task.md' "$report_path" "$FINDINGS"
assert_ledger_rejected 'relative prior result' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" 'relative-result.md' "$FINDINGS"
assert_ledger_rejected 'unknown loop' "$LEDGER" 1 bogus_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'unknown stage' "$LEDGER" 1 fix_rounds resume-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'zero round' "$LEDGER" 0 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'non-decimal round' "$LEDGER" two fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'empty source instance' "$LEDGER" 1 fix_rounds spec-fix \
  '' "$task_path" "$report_path" "$FINDINGS"
assert_ledger_rejected 'seven arguments' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path"
assert_ledger_rejected 'nine arguments' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$FINDINGS" surplus
assert_ledger_rejected 'absent findings file' "$LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t9-spec-review-a3 "$task_path" "$report_path" "$LEDGER_DIR/absent.md"

# ── AC-4: cap exhaustion is bytes on disk, not a promise ─────────────────────
sdd_note_cap_exhausted "$LEDGER" fix_rounds 4
ledger_last_line="$(tail -n 1 "$LEDGER")"
[ "$ledger_last_line" = '## cap exhausted | loop fix_rounds | round 4 | cap 3' ] || {
  printf 'cap-exhaustion entry has the wrong shape: %s\n' "$ledger_last_line" >&2
  exit 1
}
ledger_bytes_guard="$(wc -c <"$LEDGER" | tr -d ' ')"

assert_exhaustion_rejected() {
  local label="$1"
  shift
  local rc=0
  sdd_note_cap_exhausted "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || {
    printf 'sdd_note_cap_exhausted accepted %s (rc %s)\n' "$label" "$rc" >&2
    exit 1
  }
  local observed
  observed="$(wc -c <"$LEDGER" | tr -d ' ')"
  [ "$observed" -eq "$ledger_bytes_guard" ] || {
    printf 'sdd_note_cap_exhausted wrote while rejecting %s (%s -> %s)\n' \
      "$label" "$ledger_bytes_guard" "$observed" >&2
    exit 1
  }
}

assert_exhaustion_rejected 'unknown loop' "$LEDGER" bogus_rounds 4
assert_exhaustion_rejected 'zero round' "$LEDGER" fix_rounds 0
assert_exhaustion_rejected 'non-decimal round' "$LEDGER" fix_rounds four
assert_exhaustion_rejected 'relative ledger' 'relative-ledger.md' fix_rounds 4
assert_exhaustion_rejected 'symlink ledger' "$LEDGER_SYMLINK" fix_rounds 4
assert_exhaustion_rejected 'two arguments' "$LEDGER" fix_rounds
assert_exhaustion_rejected 'four arguments' "$LEDGER" fix_rounds 4 surplus

# ── AC-9b: the accepted stage set is closed, and matches the prose ───────────
SKILL_STAGE_TOKENS="$(python3 -I -B - "$SKILL" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
joined = " ".join(text.split("\n"))
sentence = re.search(r"where stage is one of (.*?)\.\s", joined)
if sentence is None:
    raise SystemExit("SKILL.md has no 'where stage is one of ...' sentence")
for token in re.findall(r"`([a-z][a-z-]*)`", sentence.group(1)):
    print(token)
PY
)"
skill_stage_count="$(grep -c '^[a-z-]*$' <<<"$SKILL_STAGE_TOKENS" || true)"
[ "$skill_stage_count" -eq 6 ] || {
  printf 'extracted %s stage tokens from the prose, expected 6\n' "$skill_stage_count" >&2
  exit 1
}
while read -r prose_stage; do
  [ -n "$prose_stage" ] || continue
  prose_stage_rc="$(sdd_rc sdd_validate_instance_dimensions 1 1 "$prose_stage" 1)"
  [ "$prose_stage_rc" -eq 0 ] || {
    printf 'documented stage %s is rejected by sdd_validate_instance_dimensions (rc %s)\n' \
      "$prose_stage" "$prose_stage_rc" >&2
    exit 1
  }
done <<<"$SKILL_STAGE_TOKENS"
unregistered_stage_rc="$(sdd_rc sdd_validate_instance_dimensions 1 1 resume-fix 1)"
[ "$unregistered_stage_rc" -eq 2 ] || {
  printf 'unregistered stage resume-fix was accepted (rc %s)\n' "$unregistered_stage_rc" >&2
  exit 1
}

# ── AC-8: the prose names the mechanism it depends on ───────────────────────
IMPLEMENTER_PROMPT="$ROOT/plugins/uberdev/skills/subagent-driven-dev/implementer-prompt.md"

! grep -Fq 'A fresh `implementation-worker` child on the implementation edge fixes them' "$SKILL" || {
  printf 'SKILL.md still claims a fresh child fixes reviewer findings\n' >&2
  exit 1
}
REVIEWER_FINDINGS_BLOCK="$(awk '/^\*\*If reviewer finds issues:\*\*/,/^\*\*If subagent fails task:\*\*/' "$SKILL")"
[ -n "$REVIEWER_FINDINGS_BLOCK" ] || {
  printf 'could not extract the "If reviewer finds issues" block from SKILL.md\n' >&2
  exit 1
}
for reviewer_block_token in 'fix ledger' 'sdd_round_permitted'; do
  grep -Fq "$reviewer_block_token" <<<"$REVIEWER_FINDINGS_BLOCK" || {
    printf 'the "If reviewer finds issues" block does not name %s\n' \
      "$reviewer_block_token" >&2
    exit 1
  }
done

for guarded_step in e g h; do
  guarded_step_text="$(grep -E "^   $guarded_step\. " "$SKILL" || true)"
  [ -n "$guarded_step_text" ] || {
    printf 'step 4%s is missing from SKILL.md\n' "$guarded_step" >&2
    exit 1
  }
  grep -Fq 'sdd_round_permitted' <<<"$guarded_step_text" || {
    printf 'step 4%s does not call the round breaker before minting the next instance\n' \
      "$guarded_step" >&2
    exit 1
  }
done
NEEDS_CONTEXT_RUNG="$(grep -E '^\*\*NEEDS_CONTEXT:\*\*' "$SKILL" || true)"
[ -n "$NEEDS_CONTEXT_RUNG" ] || {
  printf 'the NEEDS_CONTEXT rung is missing from SKILL.md\n' >&2
  exit 1
}
grep -Fq 'sdd_round_permitted' <<<"$NEEDS_CONTEXT_RUNG" || {
  printf 'the NEEDS_CONTEXT rung does not call the round breaker\n' >&2
  exit 1
}

FIX_LEDGER_SECTION="$(awk '/^## Fix ledger$/,/^## Isolation: Pattern B is the opt-out$/' "$SKILL")"
[ -n "$FIX_LEDGER_SECTION" ] || {
  printf 'SKILL.md has no "## Fix ledger" section\n' >&2
  exit 1
}
for fix_ledger_token in 'sdd_append_fix_ledger' 'sdd_note_cap_exhausted' \
  'failure_path' '0600' 'run directory'; do
  grep -Fq "$fix_ledger_token" <<<"$FIX_LEDGER_SECTION" || {
    printf 'the "## Fix ledger" section does not name %s\n' "$fix_ledger_token" >&2
    exit 1
  }
done

IMPLEMENTER_FIX_ROUND_BLOCK="$(awk '/^    ## Fix Rounds/,/^    ## Before Reporting Back/' "$IMPLEMENTER_PROMPT")"
[ -n "$IMPLEMENTER_FIX_ROUND_BLOCK" ] || {
  printf 'implementer-prompt.md has no fix-round section\n' >&2
  exit 1
}
for implementer_fix_token in 'failure_path' 'ledger'; do
  grep -Fq "$implementer_fix_token" <<<"$IMPLEMENTER_FIX_ROUND_BLOCK" || {
    printf 'the implementer fix-round section does not name %s\n' \
      "$implementer_fix_token" >&2
    exit 1
  }
done
IMPLEMENTER_REPORT_BLOCK="$(awk '/^    ## Report Format$/,/^```$/' "$IMPLEMENTER_PROMPT")"
[ -n "$IMPLEMENTER_REPORT_BLOCK" ] || {
  printf 'implementer-prompt.md has no Report Format block\n' >&2
  exit 1
}
grep -Fq '## After Review Findings' <<<"$IMPLEMENTER_REPORT_BLOCK" || {
  printf 'the Report Format block has no "## After Review Findings" line\n' >&2
  exit 1
}

# ── AC-13: the fence stays zsh-clean, and the new helpers agree across shells ─
! grep -Eq 'type -t|BASH_REMATCH|declare -A|local -n' "$TMP/runtime.sh" || {
  printf 'the routed runtime fence grew a bashism\n' >&2
  exit 1
}
! grep -Eq '^[[:space:]]*(local|typeset|declare)[[:space:]]+([^#]*[^_[:alnum:]])?(path|status|argv|fpath|cdpath)([=[:space:]]|$)' "$TMP/runtime.sh" || {
  printf 'the routed runtime fence declares a zsh-tied name\n' >&2
  exit 1
}

if command -v zsh >/dev/null 2>&1; then
  SDD_PARITY_PROBE="$TMP/sdd-parity-probe.sh"
  cat >"$SDD_PARITY_PROBE" <<'PROBE'
. "$SDD_RUNTIME_FENCE"

emit() {
  local emit_rc=0 emit_out
  emit_out="$("$@" 2>/dev/null)" || emit_rc=$?
  printf '%s rc=%s out=%s\n' "$*" "$emit_rc" "$emit_out"
}

emit_quiet() {
  local quiet_label="$1" quiet_rc=0
  shift
  "$@" >/dev/null 2>&1 || quiet_rc=$?
  printf '%s rc=%s\n' "$quiet_label" "$quiet_rc"
}

emit sdd_loop_cap fix_rounds
emit sdd_loop_cap retest_rounds
emit sdd_loop_cap context_rounds
emit sdd_loop_cap bogus
emit sdd_round_permitted fix_rounds 3
emit sdd_round_permitted fix_rounds 4
emit sdd_round_permitted fix_rounds 007
emit sdd_round_permitted fix_rounds 010
emit sdd_round_permitted fix_rounds abc
emit sdd_round_permitted fix_rounds
emit sdd_round_permitted bogus 1
emit sdd_validate_instance_dimensions 1 1 spec-fix 1
emit sdd_validate_instance_dimensions 1 1 resume-fix 1
emit_quiet append-relative sdd_append_fix_ledger relative.md 1 fix_rounds spec-fix inst /a /b /c
emit_quiet exhaust-relative sdd_note_cap_exhausted relative.md fix_rounds 4
emit_quiet append-round-1 sdd_append_fix_ledger "$SDD_PARITY_LEDGER" 1 fix_rounds spec-fix \
  sdd-w1-t1-spec-review-a1 "$SDD_PARITY_TASK" "$SDD_PARITY_PRIOR" "$SDD_PARITY_FINDINGS"
emit_quiet append-round-2 sdd_append_fix_ledger "$SDD_PARITY_LEDGER" 2 fix_rounds quality-fix \
  sdd-w1-t1-quality-review-a1 "$SDD_PARITY_TASK" "$SDD_PARITY_PRIOR" "$SDD_PARITY_FINDINGS"
emit_quiet exhausted sdd_note_cap_exhausted "$SDD_PARITY_LEDGER" fix_rounds 4
cat "$SDD_PARITY_LEDGER"
PROBE
  export SDD_RUNTIME_FENCE="$TMP/runtime.sh"
  export SDD_PARITY_TASK="$task_path"
  export SDD_PARITY_PRIOR="$report_path"
  export SDD_PARITY_FINDINGS="$FINDINGS"
  bash_parity_output="$(SDD_PARITY_LEDGER="$LEDGER_DIR/parity-bash.md" bash "$SDD_PARITY_PROBE")"
  zsh_parity_output="$(SDD_PARITY_LEDGER="$LEDGER_DIR/parity-zsh.md" zsh -f "$SDD_PARITY_PROBE")"
  [ "$bash_parity_output" = "$zsh_parity_output" ] || {
    printf 'bash/zsh parity broke for the new SDD helpers\nbash:\n%s\nzsh:\n%s\n' \
      "$bash_parity_output" "$zsh_parity_output" >&2
    exit 1
  }
  [ -n "$bash_parity_output" ] || {
    printf 'the bash/zsh parity probe produced no output\n' >&2
    exit 1
  }
fi

# ===========================================================================
# #458 ORACLE — two plans, one run carrier, disjoint child allocations.
#
# This is the acceptance oracle for the whole issue and it is deliberately
# written WITHOUT ever naming a scope value: it asserts only that two plans
# executed at IDENTICAL plan-internal coordinates (w1 / t41 / implement / a7)
# both allocate, and that the three paths the runtime exports for them are
# pairwise different. It runs against the live carrier and the real
# lib/child-dispatch.sh — nothing is stubbed. Before the fix the second call
# here refused with `instance_exists`.
# ===========================================================================
edge_id=sdd.task.implement
SCOPE_INPUTS_JSON="$(sdd_inputs_for_task sdd.task.implement 41)"
SCOPE_INPUTS_JSON="$(sdd_canonicalize_owned_paths "$SCOPE_INPUTS_JSON")"
SCOPE_INPUTS_JSON="$(uberdev_child_inputs_validate sdd.task.implement "$SCOPE_INPUTS_JSON")"

ID_A="$(uberdev_child_instance_id "sdd-p${SCOPE_PLAN_A}-w1-t41-implement-a7")"
ID_B="$(uberdev_child_instance_id "sdd-p${SCOPE_PLAN_B}-w1-t41-implement-a7")"

uberdev_create_child_handoff sdd.task.implement "$ID_A" "$SCOPE_INPUTS_JSON" '[]' >/dev/null || {
  printf 'plan A was refused its allocation at w1/t41/implement/a7\n' >&2
  exit 1
}
A_HANDOFF="$UBERDEV_CHILD_HANDOFF"
A_RESULT="$UBERDEV_CHILD_RESULT"
A_STATUS="$UBERDEV_CHILD_STATUS"

uberdev_create_child_handoff sdd.task.implement "$ID_B" "$SCOPE_INPUTS_JSON" '[]' >/dev/null || {
  printf 'plan B was refused at the SAME coordinates plan A already used (#458)\n' >&2
  exit 1
}
B_HANDOFF="$UBERDEV_CHILD_HANDOFF"
B_RESULT="$UBERDEV_CHILD_RESULT"
B_STATUS="$UBERDEV_CHILD_STATUS"

[ "$A_HANDOFF" != "$B_HANDOFF" ] || {
  printf 'two plans shared one handoff path: %s\n' "$A_HANDOFF" >&2
  exit 1
}
[ "$A_RESULT" != "$B_RESULT" ] || {
  printf 'two plans shared one result path: %s\n' "$A_RESULT" >&2
  exit 1
}
[ "$A_STATUS" != "$B_STATUS" ] || {
  printf 'two plans shared one status path: %s\n' "$A_STATUS" >&2
  exit 1
}

# Concrete read-across proof: plan B can never open plan A's result artifact.
mkdir -p "$(dirname "$A_RESULT")"
printf 'plan a result sentinel\n' >"$A_RESULT"
chmod 600 "$A_RESULT"
[ ! -e "$B_RESULT" ] || {
  printf 'plan B resolved onto an artifact plan A already wrote: %s\n' "$B_RESULT" >&2
  exit 1
}
rm -f "$A_RESULT"

# The never-reuse contract is PRESERVED, not softened: the same plan at the
# same coordinates is still a hard refusal.
REUSE_RC=0
REUSE_ERR="$(uberdev_create_child_handoff sdd.task.implement "$ID_A" "$SCOPE_INPUTS_JSON" '[]' 2>&1 >/dev/null)" \
  || REUSE_RC=$?
[ "$REUSE_RC" -eq 2 ] || {
  printf 'reusing one plan-scoped instance was accepted (rc=%s)\n' "$REUSE_RC" >&2
  exit 1
}
grep -q 'instance_exists' <<<"$REUSE_ERR" || {
  printf 'instance reuse was refused without the instance_exists diagnostic: [%s]\n' "$REUSE_ERR" >&2
  exit 1
}

# Grammar shape. Not tautological: the regex is written here by hand, never
# derived from the code under test.
case "$ID_A" in
  sdd-p[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-w1-t41-implement-a7) ;;
  *)
    printf 'composed instance ID does not match sdd-p<12hex>-w<W>-t<T>-<STAGE>-a<A>: %s\n' "$ID_A" >&2
    exit 1
    ;;
esac

# Routing the composed ID through uberdev_child_instance_id bounds it to the
# handoff schema's IDENT grammar. This is a DEGRADATION improvement, not a
# security fix: an over-long task id already failed loudly as invalid_identity
# inside the handoff validator; it now degrades to prefix-plus-digest instead.
LONG_TASK_ID="$(python3 -I -B -c 'print("9"*200,end="")')"
BOUNDED_ID="$(uberdev_child_instance_id "sdd-p${SCOPE_PLAN_A}-w1-t${LONG_TASK_ID}-implement-a7")"
python3 -I -B -c 'import re,sys; raise SystemExit(0 if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",sys.argv[1]) else 1)' \
  "$BOUNDED_ID" || {
  printf 'bounded instance ID breaches IDENT: %s\n' "$BOUNDED_ID" >&2
  exit 1
}

# ===========================================================================
# #458 — Step 4.5's pre-created pr-test-analyzer artifact is plan-scoped too.
#
# First executable coverage of that fence. It is extracted with its own
# anchored regex (SDD_TEST_REVIEW_SCOPE=) so it can never silently match the
# routed runtime fence above.
# ===========================================================================
python3 -I -B - "$SKILL" "$TMP/step45.sh" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = re.compile(r"```bash\n(SDD_TEST_REVIEW_SCOPE=.*?\n)```", re.DOTALL)
matches = pattern.findall(text)
if len(matches) != 1:
    raise SystemExit(f"SDD step 4.5 fence count must be exactly one, found {len(matches)}")
Path(sys.argv[2]).write_text(matches[0], encoding="utf-8")
PY

STEP45_DIR="$TMP/step45-summary"
mkdir -p "$STEP45_DIR"
chmod 700 "$STEP45_DIR"

STEP45_A_RC=0
( set +e; plan_path="$PLAN_A"; summary_dir="$STEP45_DIR/"; . "$TMP/step45.sh" ) \
  2>"$TMP/step45-a.err" || STEP45_A_RC=$?
[ "$STEP45_A_RC" -eq 0 ] || {
  printf 'step 4.5 artifact creation failed for plan A (rc=%s): [%s]\n' \
    "$STEP45_A_RC" "$(<"$TMP/step45-a.err")" >&2
  exit 1
}

STEP45_B_RC=0
( set +e; plan_path="$PLAN_B"; summary_dir="$STEP45_DIR/"; . "$TMP/step45.sh" ) \
  2>"$TMP/step45-b.err" || STEP45_B_RC=$?
[ "$STEP45_B_RC" -eq 0 ] || {
  printf 'step 4.5 artifact creation failed for plan B at the shared summary_dir (rc=%s): [%s]\n' \
    "$STEP45_B_RC" "$(<"$TMP/step45-b.err")" >&2
  exit 1
}

python3 -I -B - "$STEP45_DIR" <<'PY'
import os
import stat
import sys
from pathlib import Path

directory = Path(sys.argv[1])
entries = sorted(directory.iterdir())
assert len(entries) == 2, f"two plans did not produce two artifacts: {entries!r}"
assert len({entry.name for entry in entries}) == 2, entries
for entry in entries:
    info = entry.lstat()
    assert stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode), (entry, info.st_mode)
    if callable(getattr(os, "geteuid", None)):
        assert stat.S_IMODE(info.st_mode) == 0o600, (entry, oct(stat.S_IMODE(info.st_mode)))
    entry.write_bytes(f"sentinel for {entry.name}\n".encode())
PY

# Re-running the SAME plan is a NAMED refusal, not an unhandled traceback, and
# it must not overwrite or truncate the artifact already on disk — O_EXCL is
# what keeps a loud collision from degrading into the stale-read bug #458 is
# about.
STEP45_REPEAT_RC=0
( set +e; plan_path="$PLAN_A"; summary_dir="$STEP45_DIR/"; . "$TMP/step45.sh" ) \
  2>"$TMP/step45-repeat.err" || STEP45_REPEAT_RC=$?
STEP45_REPEAT_ERR="$(<"$TMP/step45-repeat.err")"
[ "$STEP45_REPEAT_RC" -eq 2 ] || {
  printf 'repeated step 4.5 creation did not refuse with rc 2 (rc=%s)\n' "$STEP45_REPEAT_RC" >&2
  exit 1
}
grep -q 'test_review_artifact_exists' <<<"$STEP45_REPEAT_ERR" || {
  printf 'repeated step 4.5 creation lacked the test_review_artifact_exists diagnostic: [%s]\n' \
    "$STEP45_REPEAT_ERR" >&2
  exit 1
}
if grep -q 'Traceback (most recent call last)' <<<"$STEP45_REPEAT_ERR"; then
  printf 'repeated step 4.5 creation raised an unhandled traceback: [%s]\n' "$STEP45_REPEAT_ERR" >&2
  exit 1
fi

python3 -I -B - "$STEP45_DIR" <<'PY'
import sys
from pathlib import Path

directory = Path(sys.argv[1])
entries = sorted(directory.iterdir())
assert len(entries) == 2, f"the refused re-run changed the artifact set: {entries!r}"
for entry in entries:
    expected = f"sentinel for {entry.name}\n".encode()
    assert entry.read_bytes() == expected, f"refused re-run mutated {entry.name}"
PY

echo 'sdd-child-inputs: PASS'
