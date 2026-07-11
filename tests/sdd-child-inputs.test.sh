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
match = re.search(
    r"```bash\n(sdd_validate_instance_dimensions\(\).*?\n)```",
    text,
    re.DOTALL,
)
if not match:
    raise SystemExit("SDD routed runtime fence missing")
Path(sys.argv[2]).write_text(match.group(1), encoding="utf-8")
batch = re.search(
    r"Executable batch shape \(substitute the edge/role/stage from the table\):"
    r"\n\n```bash\n(.*?)\n```",
    text,
    re.DOTALL,
)
if not batch:
    raise SystemExit("SDD executable batch callsite fence missing")
Path(sys.argv[3]).write_text(batch.group(1) + "\n", encoding="utf-8")
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
: >"$CANONICALIZE_LOG"
: >"$VALIDATE_LOG"
sdd_canonicalize_owned_paths() {
  printf '%s\n' "$edge_id" >>"$CANONICALIZE_LOG"
  sdd_canonicalize_owned_paths_production "$@"
}
uberdev_child_inputs_validate() {
  printf '%s\n' "$1" >>"$VALIDATE_LOG"
  uberdev_child_inputs_validate_production "$@"
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
    "backend": "codex",
    "workflow": "solve",
    "phase": "lead",
    "role": "lead",
    "task_tier": "large",
    "risk_signals": [],
    "issue_or_pr": 42,
    "issue_num": 42,
    "capacity": 4,
    "timeout_s": 20,
    "routing_mode": "adaptive",
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
    "backend": "codex",
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
: >"$PROVIDER_LOG"
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
  printf '%s\n' "$instance" >>"$PROVIDER_LOG"
  printf 'completed %s\n' "$instance" >"$5"
  chmod 600 "$5"
  DISPATCH_ID="sdd-receipt-provider-$instance"
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s"}\n' \
    "$DISPATCH_ID" >"$6"
  chmod 600 "$6"
}

sdd_dispatch_case() {
  local edge_id="$1" task_id="$2" stage="$3" raw_attempt="$4" output_name="$5"
  local wave=1 attempt="$raw_attempt" SDD_BATCH_TASK_IDS="$task_id" task_inputs_json
  . "$TMP/batch-callsite.sh" >/dev/null
  printf -v "$output_name" '%s' "$task_inputs_json"
}

implement_json=
spec_json=
quality_json=
premerge_json=
sdd_dispatch_case sdd.task.implement 41 implement 7 implement_json
sdd_dispatch_case sdd.task.spec_review 42 spec-review 1 spec_json
sdd_dispatch_case sdd.task.quality_review 43 quality-review 1 quality_json
sdd_dispatch_case sdd.premerge.test_review 44 test-review 1 premerge_json

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
  "$RECEIPT_FILE" "$UBERDEV_CHILD_TEST_SOURCE" "$BUILDER_INPUTS_LOG" \
  "$implement_json" "$spec_json" "$quality_json" "$premerge_json" <<'PY'
import copy
import hashlib
import json
import os
import re
import sys
from pathlib import Path

path, source, builder_inputs_path, *inputs_raw = sys.argv[1:]
rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
built_raw = Path(builder_inputs_path).read_text().splitlines()
cases = [
    ("sdd.implement", "sdd.task.implement", "sdd-w1-t41-implement-a7"),
    ("sdd.spec_review", "sdd.task.spec_review", "sdd-w1-t42-spec-review-a1"),
    ("sdd.quality_review", "sdd.task.quality_review", "sdd-w1-t43-quality-review-a1"),
    ("sdd.pre_merge_test_analysis", "sdd.premerge.test_review", "sdd-w1-t44-test-review-a1"),
]
assert len(built_raw) == len(cases), built_raw

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
    cursor = 0
    for (name, edge_id, instance_id), built, validated in zip(cases, built_raw, inputs_raw):
        built_digest = inputs_digest(built)
        validated_digest = inputs_digest(validated)
        if edge_id == "sdd.premerge.test_review":
            assert built_digest == validated_digest, f"{name}: unexpected input transformation"
        else:
            assert built_digest != validated_digest, f"{name}: missing canonical input snapshot"
        snapshots = []
        while cursor < len(candidate_rows) and candidate_rows[cursor]["event"] == "build":
            row = candidate_rows[cursor]
            assert row["edge_id"] == edge_id, f"{name}: unmatched build edge: {row!r}"
            snapshots.append(row["inputs_sha256"])
            cursor += 1
        assert len(snapshots) >= 2, f"{name}: incomplete build snapshot chain: {snapshots!r}"
        expected_snapshots = {built_digest, validated_digest}
        assert set(snapshots) == expected_snapshots, (
            f"{name}: unknown build snapshot: expected={expected_snapshots!r} "
            f"actual={set(snapshots)!r}"
        )
        terminal = []
        for expected_event in ("handoff", "dispatch"):
            assert cursor < len(candidate_rows), f"{name}: incomplete {expected_event} event"
            row = candidate_rows[cursor]
            assert row["event"] == expected_event, (
                f"{name}: unknown receipt event order: expected={expected_event} actual={row!r}"
            )
            assert row["edge_id"] == edge_id, f"{name}: unmatched terminal edge: {row!r}"
            assert row["instance_id"] == instance_id, (
                f"{name}: unmatched terminal instance: {row!r}"
            )
            assert row["inputs_sha256"] in snapshots, (
                f"{name}: unmatched validated digest: {row['inputs_sha256']}"
            )
            assert row["inputs_sha256"] == validated_digest, (
                f"{name}: terminal receipt did not use validated canonical inputs: {row!r}"
            )
            terminal.append(row["inputs_sha256"])
            cursor += 1
        assert terminal[0] == terminal[1], f"{name}: handoff/dispatch digest mismatch"
    assert cursor == len(candidate_rows), f"unknown trailing receipt events: {candidate_rows[cursor:]!r}"

validate_receipts(rows)

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
validated_implement = json.loads(inputs_raw[0])
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
  sdd-w1-t42-spec-review-a1 \
  sdd-w1-t43-quality-review-a1 \
  sdd-w1-t44-test-review-a1)" ] || {
  printf 'SDD runtime provider seam was not crossed exactly once per constructor\n' >&2
  exit 1
}

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
