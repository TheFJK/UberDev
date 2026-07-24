#!/usr/bin/env bash
# Issue #335 end-to-end regression: a generated Codex review entrypoint creates
# one immutable Codex carrier and supervises the six Phase 1 reviewer children
# without touching Claude, colliding worktrees, or leaking capacity leases.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$SKILL" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
result=''
argv="$*"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ] && [ "$#" -ge 2 ]; then result="$2"; shift 2; continue; fi
  shift
done
test -n "$result"
printf '%s\t%s\t%s\n' "${UBERDEV_AGENT_INSTANCE_ID:-missing}" "$PWD" "$argv" >>"$CODEX_STUB_LOG"
if [ -n "${CODEX_STUB_HANG_INSTANCE:-}" ] \
    && [ "${UBERDEV_AGENT_INSTANCE_ID:-}" = "$CODEX_STUB_HANG_INSTANCE" ]; then
  while :; do sleep 1; done
fi
sleep 0.4
case "${UBERDEV_AGENT_INSTANCE_ID:-}" in
  *caller-fix*)
    printf 'caller repair\n' >>README.md
    git add README.md
    git commit -qm 'fix: exercise caller repair edge'
    printf '%s\n' '```yaml' 'status: APPLIED' 'commits:' "  - sha: $(git rev-parse HEAD)" 'findings_disposition: []' 'risks: []' '```' >"$result"
    ;;
  *format-retry-valid-attempt01*|*format-retry-invalid*)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
      '  - severity: blocker' '    location: tests/example.test.sh:1' \
      '    summary: contradictory fixture' '    detail: malformed on purpose' \
      'confidence: high' '```' >"$result"
    ;;
  *)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' 'confidence: high' '```' >"$result"
    ;;
esac
if [ -n "${CODEX_STUB_FAIL_INSTANCE:-}" ] \
  && [ "${UBERDEV_AGENT_INSTANCE_ID:-}" = "$CODEX_STUB_FAIL_INSTANCE" ]; then
  exit 42
fi
exit 0
SH
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_STUB_LOG"
exit 97
SH
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

cat >"$TMP/run-case.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case_name="$1"
repo="$2"
setup="$3"
fail_instance="${4-}"
timeout_instance="${5-}"
cd "$repo"
. "$setup"

# These are immutable command-owned artifacts consumed by all six reviewer
# handoffs. changed_paths deliberately remains repository-relative, including
# at the provider boundary.
printf 'diff fixture\n' >"$DIFF_ARTIFACT_PATH"
printf 'review criteria\n' >"$CRITERIA_PATH"

edges=(correctness silent_failures types comments tests general)
handoffs=()
results=()
statuses=()
instances=()
for lens in "${edges[@]}"; do
  edge="review_pr.review.$lens"
  instance="review-pr-e2e-${case_name}-${lens}-iter1-attempt01"
  instances+=("$instance")
  if [ "$lens" = general ]; then
    inputs="$(uberdev_child_inputs_build "$edge" \
      changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" \
      emphasis '[]' lens '"general"')"
  else
    inputs="$(uberdev_child_inputs_build "$edge" \
      changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" \
      emphasis '[]')"
  fi
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" '[]' >/dev/null
  handoffs+=("$UBERDEV_CHILD_HANDOFF")
  results+=("$UBERDEV_CHILD_RESULT")
  statuses+=("$UBERDEV_CHILD_STATUS")
done

uberdev_preflight_child_batch "${handoffs[@]}"
for i in "${!edges[@]}"; do
  uberdev_dispatch_child "review_pr.review.${edges[$i]}" \
    "${handoffs[$i]}" "${results[$i]}" "${statuses[$i]}" >/dev/null
done

for i in "${!edges[@]}"; do
  if [ -n "$fail_instance" ] && [ "${instances[$i]}" = "$fail_instance" ]; then
    if uberdev_wait_child "${statuses[$i]}" "${results[$i]}" 20; then
      echo "expected failed child to return non-zero: $fail_instance" >&2
      exit 1
    fi
  elif [ -n "$timeout_instance" ] && [ "${instances[$i]}" = "$timeout_instance" ]; then
    set +e
    uberdev_wait_child "${statuses[$i]}" "${results[$i]}" 1
    timeout_rc=$?
    set -e
    case "$timeout_rc" in 1|124) ;; *) echo "timeout child returned unexpected rc=$timeout_rc" >&2; exit 1 ;; esac
    uberdev_unwind_child "${statuses[$i]}" "${results[$i]}" 20
  else
    uberdev_wait_child "${statuses[$i]}" "${results[$i]}" 20
    uberdev_child_validate_phase1_review_result "${results[$i]}"
  fi
done

# Dispatch one mutating repair through the same routed stack. It must advance
# the carrier-selected caller branch in place, without a disposable worktree,
# ownership receipt, or retained capacity lease.
FIX_FINDINGS="$RESEARCH_DIR_ABS/e2e-findings.md"
FIX_RANGE="$RESEARCH_DIR_ABS/e2e-commit-range.txt"
FIX_DISPOSITION="$RESEARCH_DIR_ABS/e2e-disposition.json"
printf '<external-untrusted-input source="post-impl-review-aggregate">\n</external-untrusted-input>\n' >"$FIX_FINDINGS"
printf 'HEAD^..HEAD\n' >"$FIX_RANGE"
printf '{}\n' >"$FIX_DISPOSITION"
repair_instance="review-pr-e2e-${case_name}-caller-fix-iter1-attempt01"
before_repair="$(git rev-parse HEAD)"
repair_inputs="$(uberdev_child_inputs_build review_pr.fix.phase1 \
  findings_path "$(review_json_string "$FIX_FINDINGS")" \
  commit_range_path "$(review_json_string "$FIX_RANGE")" \
  working_dir "$(review_json_string "$repo")" \
  pr_number "$PR_NUMBER" \
  disposition_path "$(review_json_string "$FIX_DISPOSITION")")"
uberdev_create_child_handoff review_pr.fix.phase1 "$repair_instance" "$repair_inputs" null >/dev/null
repair_result="$UBERDEV_CHILD_RESULT"
repair_status="$UBERDEV_CHILD_STATUS"
uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF"
uberdev_dispatch_child review_pr.fix.phase1 "$UBERDEV_CHILD_HANDOFF" "$repair_result" "$repair_status" >/dev/null
uberdev_wait_child "$repair_status" "$repair_result" 20
after_repair="$(git rev-parse HEAD)"
[ "$after_repair" != "$before_repair" ] || { echo "caller repair did not advance the branch" >&2; exit 1; }

python3 -I -B - "$UBERDEV_CARRIER_RUN_DIR" "$repo" "$CODEX_STUB_LOG" \
  "$CLAUDE_STUB_LOG" "$fail_instance" "$timeout_instance" "$repair_instance" "$before_repair" "$after_repair" "${instances[@]}" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

run_dir = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
codex_log = pathlib.Path(sys.argv[3])
claude_log = pathlib.Path(sys.argv[4])
failed = sys.argv[5]
timed_out = sys.argv[6]
repair = sys.argv[7]
before_repair = sys.argv[8]
after_repair = sys.argv[9]
instances = sys.argv[10:]
assert len(instances) == len(set(instances)) == 6, instances
assert before_repair != after_repair
assert subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip() == after_repair

lines = codex_log.read_text().splitlines()
assert len(lines) == 7, lines
launches = [line.split("\t", 2) for line in lines]
assert {row[0] for row in launches} == set(instances) | {repair}, launches
review_launches = [row for row in launches if row[0] != repair]
repair_launches = [row for row in launches if row[0] == repair]
assert len({row[1] for row in review_launches}) == 6, review_launches
assert len(repair_launches) == 1 and pathlib.Path(repair_launches[0][1]).resolve() == repo.resolve(), repair_launches
assert all("--ask-for-approval never" in row[2] for row in launches), launches
assert all("permission-mode" not in row[2] and "dangerously-skip-permissions" not in row[2] for row in launches)
assert not claude_log.exists() or not claude_log.read_text(), claude_log.read_text()

statuses = []
worktrees = set()
branches = set()
child_logs = set()
for instance in instances:
    child = run_dir / "children" / instance
    handoff = json.loads((run_dir / "handoffs" / f"{instance}.json").read_text())
    assert handoff["instance_id"] == instance
    assert handoff["inputs"]["changed_paths"] == ["README.md"]
    status = json.loads((child / "status.json").read_text())
    statuses.append(status["state"])
    assert status["backend"] == "codex", status
    worktrees.add(status["worktree"])
    branches.add(status["branch"])
    child_logs.add(status["log"])
    assert status["log"] == str(child / "status.json") + ".log", status
    assert pathlib.Path(status["log"]).is_file(), status["log"]
    worktree = pathlib.Path(status["worktree"])
    if not worktree.is_absolute():
        worktree = repo / worktree
    assert not worktree.exists(), worktree
    branch = status["branch"]
    probe = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        check=False,
    )
    assert probe.returncode != 0, branch

assert len(worktrees) == len(branches) == len(child_logs) == 6, (worktrees, branches, child_logs)
if failed:
    assert statuses.count("failed") == 1 and statuses.count("completed") == 5, statuses
elif timed_out:
    terminal = json.loads((run_dir / "children" / timed_out / "status.json").read_text())["state"]
    assert terminal in {"failed", "timed_out", "cancelled"}, terminal
    assert statuses.count("completed") == 5, statuses
else:
    assert statuses == ["completed"] * 6, statuses

repair_child = run_dir / "children" / repair
repair_status = json.loads((repair_child / "status.json").read_text())
assert repair_status["state"] == "completed" and repair_status["workspace_mode"] == "caller", repair_status
assert pathlib.Path(repair_status["worktree"]).resolve() == repo.resolve(), repair_status
assert repair_status["branch"] == "", repair_status
assert not pathlib.Path(str(repair_child / "status.json") + ".worktree-owner.json").exists()

uid_fn = getattr(os, "geteuid", None)
state = run_dir / f".agent-state-{uid_fn() if uid_fn is not None else 0}"
leases = list((state / "semaphore-v1").rglob("*.lease"))
assert not leases, leases
events = [json.loads(line) for line in (state / "agent-lifecycle.jsonl").read_text().splitlines() if line]
terminals = [row for row in events if row.get("event") in {"completed", "failed", "timed_out", "cancelled", "abandoned"}]
assert len(terminals) == 7, terminals
assert {row["run_id"] for row in terminals} == set(instances) | {repair}, terminals
PY

# The canonical reviewer boundary drives the existing one-shot format-retry
# edge. A repaired result is accepted; two contradictory documents remain
# fail-closed instead of reaching aggregation.
format_retry_case() {
  local outcome="$1" edge=review_pr.review.correctness inputs first_instance repair_instance
  local first_result first_status repair_inputs repair_result repair_status
  inputs="$(uberdev_child_inputs_build "$edge" \
    changed_paths '["README.md"]' \
    diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
    criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]')"
  first_instance="review-pr-e2e-${case_name}-format-retry-${outcome}-attempt01"
  uberdev_create_child_handoff "$edge" "$first_instance" "$inputs" '[]' >/dev/null
  first_result="$UBERDEV_CHILD_RESULT"; first_status="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child "$edge" "$UBERDEV_CHILD_HANDOFF" "$first_result" "$first_status" >/dev/null
  uberdev_wait_child "$first_status" "$first_result" 20
  ! uberdev_child_validate_phase1_review_result "$first_result"

  repair_inputs="$(uberdev_child_inputs_format_retry "$edge" "$inputs" "$CRITERIA_PATH")"
  repair_instance="review-pr-e2e-${case_name}-format-retry-${outcome}-attempt02"
  uberdev_create_child_handoff "$edge" "$repair_instance" "$repair_inputs" '[]' >/dev/null
  repair_result="$UBERDEV_CHILD_RESULT"; repair_status="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child "$edge" "$UBERDEV_CHILD_HANDOFF" "$repair_result" "$repair_status" >/dev/null
  uberdev_wait_child "$repair_status" "$repair_result" 20
  if [ "$outcome" = valid ]; then
    uberdev_child_validate_phase1_review_result "$repair_result"
  else
    ! uberdev_child_validate_phase1_review_result "$repair_result"
  fi
}
format_retry_case valid
format_retry_case invalid

# Preflight a complete six-reviewer wave, then fail the third child before any
# provider handle is published. The caller unwinds the two already-launched
# siblings and proves the batch leaves no lease, worktree, branch, or owner
# receipt behind.
eval "$(declare -f _uberdev_agent_dispatch_backend | sed '1s/_uberdev_agent_dispatch_backend/_real_prehandle_dispatch_backend/')"
_uberdev_agent_dispatch_backend() {
  case "${UBERDEV_AGENT_INSTANCE_ID:-}" in
    *prehandle-types*) DISPATCH_ID=''; DISPATCH_RC=86; return 86 ;;
    *) _real_prehandle_dispatch_backend "$@" ;;
  esac
}
pre_handoffs=(); pre_results=(); pre_statuses=(); pre_instances=()
for lens in "${edges[@]}"; do
  edge="review_pr.review.$lens"
  instance="review-pr-e2e-${case_name}-prehandle-${lens}-attempt01"
  pre_instances+=("$instance")
  if [ "$lens" = general ]; then
    inputs="$(uberdev_child_inputs_build "$edge" changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]' lens '"general"')"
  else
    inputs="$(uberdev_child_inputs_build "$edge" changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]')"
  fi
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" '[]' >/dev/null
  pre_handoffs+=("$UBERDEV_CHILD_HANDOFF"); pre_results+=("$UBERDEV_CHILD_RESULT"); pre_statuses+=("$UBERDEV_CHILD_STATUS")
done
uberdev_preflight_child_batch "${pre_handoffs[@]}"
launched_count=0
for i in "${!edges[@]}"; do
  if uberdev_dispatch_child "review_pr.review.${edges[$i]}" \
      "${pre_handoffs[$i]}" "${pre_results[$i]}" "${pre_statuses[$i]}" >/dev/null; then
    launched_count=$((launched_count + 1))
    continue
  else
    prehandle_rc=$?
  fi
  [ "${edges[$i]}" = types ] && [ "$prehandle_rc" -eq 86 ]
  break
done
[ "$launched_count" -eq 2 ]
for ((i=0; i<launched_count; i++)); do
  uberdev_unwind_child "${pre_statuses[$i]}" "${pre_results[$i]}" 20
done
eval "$(declare -f _real_prehandle_dispatch_backend | sed '1s/_real_prehandle_dispatch_backend/_uberdev_agent_dispatch_backend/')"
python3 -I -B - "$UBERDEV_CARRIER_RUN_DIR" "$repo" "${pre_statuses[2]}" <<'PY'
import json,os,pathlib,subprocess,sys
run_dir=pathlib.Path(sys.argv[1]); repo=pathlib.Path(sys.argv[2]); failed_status=pathlib.Path(sys.argv[3])
# A provider failure before handle publication has no canonical provider status
# snapshot; its durable terminal evidence is the lifecycle manifest below.
assert not failed_status.exists(),failed_status
state=run_dir/f".agent-state-{os.geteuid() if hasattr(os,'geteuid') else 0}"
assert not list((state/"semaphore-v1").rglob("*.lease"))
assert not list(repo.rglob("*.worktree-owner.json"))
assert not [path for path in (repo/".claude/worktrees").glob("*") if path.exists()]
branches=subprocess.check_output(["git","-C",str(repo),"branch","--format=%(refname:short)"],text=True).splitlines()
assert not [branch for branch in branches if "prehandle-" in branch],branches
events=[json.loads(line) for line in (state/"agent-lifecycle.jsonl").read_text().splitlines() if line]
failed=[row for row in events if row.get("run_id","").endswith("prehandle-types-attempt01") and row.get("event")=="failed"]
assert len(failed)==1,failed
PY
SH
chmod +x "$TMP/run-case.sh"

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'fixture\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
}

run_case() {
  local name="$1" fail_instance="${2-}" timeout_instance="${3-}" repo runtime codex_log claude_log
  repo="$TMP/repo-$name"; runtime="$TMP/runtime-$name"
  codex_log="$TMP/codex-$name.log"; claude_log="$TMP/claude-$name.log"
  make_repo "$repo"
  mkdir -p "$runtime"
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$repo" \
    UBERDEV_TMPDIR="$runtime" CODEX_STUB_LOG="$codex_log" CLAUDE_STUB_LOG="$claude_log" \
    CODEX_STUB_FAIL_INSTANCE="$fail_instance" CODEX_STUB_HANG_INSTANCE="$timeout_instance" \
    RUN_ID="20260716-00000${name}-abcdef0" \
    PR_NUMBER=335 ARGUMENTS='' SOLVE_TIMEOUT=20 UBERDEV_AGENT_CAPACITY=6 \
    bash "$TMP/run-case.sh" "$name" "$repo" "$TMP/setup.sh" "$fail_instance" "$timeout_instance"
}

run_case 1
run_case 2 review-pr-e2e-2-types-iter1-attempt01
run_case 3 '' review-pr-e2e-3-comments-iter1-attempt01

echo "review-pr Codex six-child integration tests passed"
