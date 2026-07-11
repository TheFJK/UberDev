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

python3 -I -B - "$SKILL" "$TMP/runtime.sh" <<'PY'
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
PY

. "$LIB"
eval "$(declare -f uberdev_child_inputs_build | sed '1s/uberdev_child_inputs_build/uberdev_child_inputs_build_production/')"

BUILDER_LOG="$TMP/builder.log"
: >"$BUILDER_LOG"
uberdev_child_inputs_build() {
  printf '%s\n' "$1" >>"$BUILDER_LOG"
  uberdev_child_inputs_build_production "$@"
}

SDD_WORKTREE="$ROOT"
SDD_RISK_JSON='[]'
SDD_CHILD_TIMEOUT=5
. "$TMP/runtime.sh"

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
  "$INPUT_DIR/allowed \"one\".ts" "$INPUT_DIR/allowed \\ two.ts")"
denied_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:]),end="")' \
  "$INPUT_DIR/denied \"sibling\".ts")"
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
  local canonical_attempt instance_id task_inputs_json
  sdd_validate_instance_dimensions 1 "$task_id" "$stage" "$raw_attempt"
  canonical_attempt="$(sdd_json_decimal_integer "$raw_attempt")"
  instance_id="sdd-w1-t${task_id}-${stage}-a${canonical_attempt}"
  sdd_begin_batch
  task_inputs_json="$(sdd_inputs_for_task "$edge_id" "$task_id")"
  printf -v "$output_name" '%s' "$task_inputs_json"
  sdd_dispatch_prepared "$edge_id" "$instance_id" "$task_inputs_json" "$SDD_RISK_JSON" >/dev/null
  sdd_launch_prepared_batch >/dev/null
  sdd_wait_prepared_batch "$SDD_CHILD_TIMEOUT" >/dev/null
}

implement_json=
spec_json=
quality_json=
premerge_json=
sdd_dispatch_case sdd.task.implement 41 implement 007 implement_json
sdd_dispatch_case sdd.task.spec_review 42 spec-review 01 spec_json
sdd_dispatch_case sdd.task.quality_review 43 quality-review 0001 quality_json
sdd_dispatch_case sdd.premerge.test_review 44 test-review 1 premerge_json

python3 -I -B - \
  "$implement_json" "$spec_json" "$quality_json" "$premerge_json" \
  "$task_path" "$SDD_WORKTREE" "$allowed_paths_json" "$denied_paths_json" "$failure_path" "$attempt" \
  "$spec_path" "$plan_path" "$commit_sha" "$report_path" "$base_sha" "$head_sha" \
  "$commit_range_path" "$acceptance_path" "$summary_path" <<'PY'
import json
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
    "allowed_paths": json.loads(allowed_raw),
    "denied_paths": json.loads(denied_raw),
    "failure_path": failure_path,
    "attempt": int(attempt),
}
assert json.loads(spec_raw) == {
    "spec_path": spec_path,
    "plan_path": plan_path,
    "commit_sha": commit_sha,
    "allowed_paths": json.loads(allowed_raw),
    "report_path": report_path,
}
assert json.loads(quality_raw) == {
    "plan_path": plan_path,
    "base_sha": base_sha,
    "head_sha": head_sha,
    "allowed_paths": json.loads(allowed_raw),
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

python3 -I -B - \
  "$RECEIPT_FILE" "$UBERDEV_CHILD_TEST_SOURCE" \
  "$implement_json" "$spec_json" "$quality_json" "$premerge_json" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path, source, *inputs_raw = sys.argv[1:]
rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
cases = [
    ("sdd.implement", "sdd.task.implement", "sdd-w1-t41-implement-a7"),
    ("sdd.spec_review", "sdd.task.spec_review", "sdd-w1-t42-spec-review-a1"),
    ("sdd.quality_review", "sdd.task.quality_review", "sdd-w1-t43-quality-review-a1"),
    ("sdd.pre_merge_test_analysis", "sdd.premerge.test_review", "sdd-w1-t44-test-review-a1"),
]
assert len(rows) == len(cases) * 3, rows
for index, ((name, edge_id, instance_id), raw) in enumerate(zip(cases, inputs_raw)):
    chain = rows[index * 3:(index + 1) * 3]
    assert [row["event"] for row in chain] == ["build", "handoff", "dispatch"], (name, chain)
    canonical = json.dumps(
        json.loads(raw), sort_keys=True, separators=(",", ":")
    ).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    for row in chain:
        expected_keys = {"schema_version", "event", "source", "edge_id", "inputs_sha256"}
        if row["event"] != "build":
            expected_keys.add("instance_id")
        assert set(row) == expected_keys, (name, row)
        assert row["schema_version"] == 1, (name, row)
        assert row["source"] == source, (name, row)
        assert row["edge_id"] == edge_id, (name, row)
        assert row["inputs_sha256"] == digest, (name, row)
        if row["event"] != "build":
            assert row["instance_id"] == instance_id, (name, row)
implement_inputs = json.loads(inputs_raw[0])
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
