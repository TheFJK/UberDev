#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
. "$TMP/runtime.sh"

task_path="$ROOT/task \"quoted\" \\ path.md"
allowed_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:]),end="")' \
  "$ROOT/src/allowed \"one\".ts" "$ROOT/src/allowed \\ two.ts")"
denied_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:]),end="")' \
  "$ROOT/src/denied \"sibling\".ts")"
failure_path="$ROOT/failures/attempt \\ \"one\".md"
attempt=7
implement_json="$(sdd_inputs_for_task sdd.task.implement 41)"

spec_path="$ROOT/specs/design \"quoted\".md"
plan_path="$ROOT/plans/plan \\ wave.md"
commit_sha='abc123"quoted'
report_path="$ROOT/results/implementer \\ \"one\".md"
spec_json="$(sdd_inputs_for_task sdd.task.spec_review 42)"

base_sha='base123\backslash'
head_sha='head123"quoted'
quality_json="$(sdd_inputs_for_task sdd.task.quality_review 43)"

commit_range_path="$ROOT/run/commit range \"one\".txt"
acceptance_path="$ROOT/run/acceptance \\ criteria.md"
summary_path="$ROOT/run/summary \"one\".md"
premerge_json="$(sdd_inputs_for_task sdd.premerge.test_review 44)"

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

for numeric_case in '007|7' '00|0' '00042|42' '10|10'; do
  attempt="${numeric_case%%|*}"
  expected_attempt="${numeric_case#*|}"
  sdd_validate_instance_dimensions 1 1 implement "$attempt"
  normalized_json="$(sdd_inputs_for_task sdd.task.implement 45)"
  python3 -I -B - "$normalized_json" "$expected_attempt" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])["attempt"]
expected = int(sys.argv[2])
assert type(actual) is int
assert actual == expected, (actual, expected)
PY
done

grep -Fq 'task_inputs_json="$(uberdev_child_inputs_validate "$edge_id" "$task_inputs_json")" || return 2' "$SKILL"
! grep -Eq 'json\.dumps\(\{.*(task_path|spec_path|base_sha|commit_range_path)' "$TMP/runtime.sh"

echo 'sdd-child-inputs: PASS'
