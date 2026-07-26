#!/usr/bin/env bash
# Issue #335 end-to-end regression: a generated Codex review entrypoint creates
# one immutable Codex carrier and supervises the six Phase 1 reviewer children
# without touching Claude, colliding worktrees, or leaking capacity leases.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_GIT="$(command -v git)"
RUNTIME_ROOT="${SIX_CHILD_RUNTIME_ROOT:-$ROOT/codex/uberdev-codex}"
RUNTIME_NAMESPACE="${SIX_CHILD_RUNTIME_NAMESPACE:-uberdev}"
case "$RUNTIME_NAMESPACE" in
  uberdev) COMMAND_SKILL=uberdev-cmd-review-pr; POST_SKILL_DIR=post-impl-review ;;
  prkit) COMMAND_SKILL=prkit-cmd-review-pr; POST_SKILL_DIR=prkit-post-impl-review ;;
  *) echo "unknown SIX_CHILD_RUNTIME_NAMESPACE=$RUNTIME_NAMESPACE" >&2; exit 2 ;;
esac
SKILL="$RUNTIME_ROOT/skills/$COMMAND_SKILL/SKILL.md"
POST_SKILL="$RUNTIME_ROOT/skills/$POST_SKILL_DIR/SKILL.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

awk -v marker="$RUNTIME_NAMESPACE-executable setup=review-pr" '
  index($0,marker){active=1; next}
  active && /^```/{exit}
  active{print}
' "$SKILL" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"
python3 -I -B - "$POST_SKILL" "$TMP/post-setup.sh" "$TMP/post-boundary.sh" "$RUNTIME_NAMESPACE" <<'PY'
import pathlib,re,sys
source=pathlib.Path(sys.argv[1]).read_text()
namespace=sys.argv[4]
def one(marker):
    matches=re.findall(rf'^```bash {re.escape(marker)}\s*\n(.*?)^```\s*$',source,re.M|re.S)
    assert len(matches)==1,(marker,len(matches))
    return matches[0]
setup=one(f'{namespace}-executable setup=post-impl-review')
pathlib.Path(sys.argv[2]).write_text(setup)
pathlib.Path(sys.argv[3]).write_text(one(f'{namespace}-executable'))
PY

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

stress="${SIX_CHILD_GIT_MUTATION_STRESS:-0}"
is_common_probe=0
if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --git-common-dir ]; then
  is_common_probe=1
fi

# Hold cleanup immediately before mutex acquisition. Five non-timeout siblings
# must all be pending before any may proceed; the timed-out sixth arrives later.
# This proves genuine concurrent demand without widening the protected section.
if [ "$stress" = 1 ] && [ "$is_common_probe" -eq 1 ] \
    && [ -e "$CODEX_STUB_RELEASE_DIR/.all" ]; then
  pre="$SIX_CHILD_GIT_PREACQUIRE_DIR"
  mkdir -p "$pre"
  mkdir "$pre/arrival-$PPID" 2>/dev/null || true
  printf 'pending\towner=%s\n' "$PPID" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  arrivals="$(find "$pre" -mindepth 1 -maxdepth 1 -type d -name 'arrival-*' | wc -l | tr -d ' ')"
  if [ "$arrivals" -ge 5 ] && mkdir "$pre/released" 2>/dev/null; then
    printf 'barrier-release\tcount=%s\n' "$arrivals" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  fi
  tries=0
  while [ ! -d "$pre/released" ] && [ "$tries" -lt 2000 ]; do
    tries=$((tries + 1))
    sleep 0.01
  done
  if [ ! -d "$pre/released" ]; then
    printf 'barrier-timeout\towner=%s\tarrivals=%s\n' "$PPID" "$arrivals" \
      >>"$SIX_CHILD_GIT_COLLISION_LOG"
    exit 88
  fi
fi

if [ "$stress" != 1 ]; then
  exec "$SIX_CHILD_REAL_GIT" "$@"
fi

phase=''
case "${1:-}:${2:-}" in
  worktree:remove) phase=remove ;;
  worktree:list) phase=list ;;
  branch:-D) phase=branch ;;
esac
[ -n "$phase" ] || exec "$SIX_CHILD_REAL_GIT" "$@"

common_dir="$("$SIX_CHILD_REAL_GIT" rev-parse --git-common-dir)"
case "$common_dir" in /*) ;; *) common_dir="$PWD/$common_dir" ;; esac
common_dir="$(cd "$common_dir" && pwd -P)"
sentinel="$common_dir/.uberdev-six-child-git-critical"
owner_file="$sentinel/owner"

collision() {
  actual="$(cat "$owner_file" 2>/dev/null || printf missing)"
  printf 'overlap\towner=%s\tactual=%s\tphase=%s\targv=%s\n' \
    "$PPID" "$actual" "$phase" "$*" >>"$SIX_CHILD_GIT_COLLISION_LOG"
  exit 89
}

if [ "$phase" = remove ]; then
  if ! mkdir "$sentinel" 2>/dev/null; then collision "$@"; fi
  chmod 700 "$sentinel"
  printf '%s\n' "$PPID" >"$owner_file"
else
  [ -f "$owner_file" ] || collision "$@"
  [ "$(cat "$owner_file")" = "$PPID" ] || collision "$@"
fi
printf 'critical\towner=%s\tphase=%s\n' "$PPID" "$phase" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"

if "$SIX_CHILD_REAL_GIT" "$@"; then rc=0; else rc=$?; fi
if [ "$phase" = branch ]; then
  printf 'critical\towner=%s\tphase=release\n' "$PPID" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  rm -f "$owner_file"
  rmdir "$sentinel"
fi
exit "$rc"
SH
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
agent_instance="${UBERDEV_AGENT_INSTANCE_ID:-${PRKIT_AGENT_INSTANCE_ID:-missing}}"
agent_status_file="${UBERDEV_AGENT_STATUS_FILE:-${PRKIT_AGENT_STATUS_FILE:-}}"
printf '%s\t%s\t%s\n' "$agent_instance" "$PWD" "$argv" >>"$CODEX_STUB_LOG"
if [ -n "${CODEX_STUB_PRE_READY_FAIL_INSTANCE:-}" ] \
    && [ "$agent_instance" = "$CODEX_STUB_PRE_READY_FAIL_INSTANCE" ]; then
  exit 42
fi
case "$agent_instance" in
  post-review-*-attempt01)
    if [ "$agent_instance" != "${CODEX_STUB_SKIP_READY_INSTANCE:-}" ]; then
      : >"$CODEX_STUB_READY_DIR/$agent_instance"
    fi
    while [ ! -e "$CODEX_STUB_RELEASE_DIR/.all" ]; do sleep .05; done
    ;;
esac
if [ -n "${CODEX_STUB_HANG_INSTANCE:-}" ] \
    && [ "$agent_instance" = "$CODEX_STUB_HANG_INSTANCE" ]; then
  while :; do sleep 1; done
fi
case "$agent_instance" in
  *caller-fix*)
    printf 'caller repair\n' >>README.md
    git add README.md
    git commit -qm 'fix: exercise caller repair edge'
    printf '%s\n' '```yaml' 'status: APPLIED' 'commits:' "  - sha: $(git rev-parse HEAD)" 'findings_disposition: []' 'risks: []' '```' >"$result"
    ;;
  *format-retry-valid-attempt01*)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
      'confidence: high' '```' >"$result"
    ;;
  *format-retry-invalid*)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
      '  - severity: blocker' '    location: tests/example.test.sh:1' \
      '    summary: contradictory fixture' '    detail: malformed on purpose' \
      'confidence: high' '```' >"$result"
    ;;
  *)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' 'confidence: high' '```' >"$result"
    ;;
esac
stub_run_dir="$(dirname "$(dirname "$(dirname "$agent_status_file")")")"
while ! python3 -I -B - "$stub_run_dir" "$agent_status_file" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); expected=f"status_path={sys.argv[2]}"
for lease in root.glob('.agent-state-*/semaphore-v1/*.scope/*.lease'):
    try: lines=lease.read_text().splitlines()
    except OSError: continue
    if expected in lines and any(line.startswith('backend_identity=') and line!='backend_identity=' for line in lines):
        raise SystemExit(0)
raise SystemExit(1)
PY
do sleep .05; done
if [ -n "${CODEX_STUB_FAIL_INSTANCE:-}" ] \
  && [ "$agent_instance" = "$CODEX_STUB_FAIL_INSTANCE" ]; then
  exit 42
fi
exit 0
SH
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_STUB_LOG"
exit 97
SH
chmod +x "$TMP/bin/git" "$TMP/bin/codex" "$TMP/bin/claude"

cat >"$TMP/run-case.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case_name="$1"
repo="$2"
setup="$3"
post_setup="$4"
post_boundary="$5"
fail_instance="${6-}"
timeout_instance="${7-}"
skip_ready_instance="${8-}"
pre_ready_fail_instance="${9-}"
cd "$repo"
. "$setup"

# These are immutable command-owned artifacts consumed by all six reviewer
# handoffs. changed_paths deliberately remains repository-relative, including
# at the provider boundary.
printf 'diff fixture\n' >"$DIFF_ARTIFACT_PATH"
printf 'review criteria\n' >"$CRITERIA_PATH"

# Run the production review-wave executable boundary itself. A deterministic
# provider barrier proves all six dispatches happen before the first wait.
mkdir -p "$CODEX_STUB_READY_DIR" "$CODEX_STUB_RELEASE_DIR"
(
  barrier_timeout="${REVIEW_BARRIER_TIMEOUT_OVERRIDE:-60}"
  startup_timeout="${REVIEW_BARRIER_STARTUP_TIMEOUT_OVERRIDE:-60}"
  case "$barrier_timeout:$startup_timeout" in *[!0-9:]*|0:*|*:0) exit 2 ;; esac
  barrier_release() { : >"$CODEX_STUB_RELEASE_DIR/.all"; }
  trap barrier_release EXIT
  barrier_deadline=$(( $(date +%s) + startup_timeout ))
  fully_dispatched=0
  barrier_rc=0; barrier_reason=ready; ready_count=0; lease_count=0
  while :; do
    ready_count="$(find "$CODEX_STUB_READY_DIR" -type f | wc -l | tr -d ' ')"
    lease_count=0
    while IFS= read -r lease; do
      if grep -q '^backend_identity=.' "$lease" 2>/dev/null; then
        lease_count=$((lease_count + 1))
      fi
    done < <(find "$UBERDEV_CARRIER_RUN_DIR" -path '*/semaphore-v1/*.scope/*.lease' -type f 2>/dev/null)
    if [ "$ready_count" -eq 6 ] && [ "$lease_count" -eq 6 ]; then break; fi
    terminal=0
    while IFS= read -r status; do
      case "$status" in *.watcher-error.json) terminal=1; break ;; esac
      if grep -Eq '"state"[[:space:]]*:[[:space:]]*"(completed|failed|timed_out|cancelled)"' "$status"; then
        terminal=1; break
      fi
    done < <(find "$UBERDEV_CARRIER_RUN_DIR/children" -type f \
      \( -name status.json -o -name '*.watcher-error.json' \) 2>/dev/null)
    lifecycle="$UBERDEV_CARRIER_RUN_DIR/.agent-state-$(id -u)/agent-lifecycle.jsonl"
    if [ "$terminal" -eq 0 ] && [ -f "$lifecycle" ] && \
        grep -Eq '"event":"(failed|timed_out|cancelled|abandoned)".*"run_id":"post-review-' "$lifecycle"; then
      terminal=1
    fi
    if [ "$terminal" -eq 1 ]; then barrier_rc=70; barrier_reason=terminal-before-readiness; break; fi
    barrier_now="$(date +%s)"
    if [ "$lease_count" -eq 6 ] && [ "$fully_dispatched" -eq 0 ]; then
      barrier_deadline=$((barrier_now + barrier_timeout)); fully_dispatched=1
    fi
    if [ "$barrier_now" -ge "$barrier_deadline" ]; then
      barrier_rc=124; barrier_reason=readiness-timeout; break
    fi
    sleep .05
  done
  printf 'rc=%s reason=%s ready=%s leases=%s\n' \
    "$barrier_rc" "$barrier_reason" "$ready_count" "$lease_count" >"$CODEX_STUB_BARRIER_REPORT"
  exit "$barrier_rc"
) & readiness_coordinator=$!
CHANGED_PATHS_JSON='["README.md"]'
EMPHASIS_JSON='[]'
REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT_OVERRIDE:-10}"
set +e
. "$post_setup"
post_setup_rc=$?
if [ "$post_setup_rc" -eq 0 ]; then . "$post_boundary"; post_setup_rc=$?; fi
set -e
if wait "$readiness_coordinator"; then readiness_rc=0; else readiness_rc=$?; fi
if [ "$readiness_rc" -ne 0 ]; then
  printf 'readiness coordinator: %s\n' "$(cat "$CODEX_STUB_BARRIER_REPORT" 2>/dev/null || printf 'missing report')" >&2
fi
if [ -n "$pre_ready_fail_instance" ]; then
  [ "$readiness_rc" -eq 70 ]
  grep -Fq 'reason=terminal-before-readiness' "$CODEX_STUB_BARRIER_REPORT"
elif [ -n "$skip_ready_instance" ]; then
  [ "$readiness_rc" -eq 124 ]
  grep -Fq 'reason=readiness-timeout ready=5' "$CODEX_STUB_BARRIER_REPORT"
else
  [ "$readiness_rc" -eq 0 ]
fi
if [ -n "$fail_instance$timeout_instance$pre_ready_fail_instance" ]; then
  [ "$post_setup_rc" -eq 70 ]
else
  [ "$post_setup_rc" -eq 0 ]
fi

edges=(correctness silent_failures types comments tests general)
instances=(); results=(); statuses=()
while IFS= read -r row; do
  statuses+=("$(jq -r .status <<<"$row")")
  results+=("$(jq -r .result <<<"$row")")
  instance_path="$(jq -r .status <<<"$row")"
  instances+=("$(basename "$(dirname "$instance_path")")")
done <"$REVIEW_LAUNCHED"
[ "${#instances[@]}" -eq 6 ]

if [ -n "$timeout_instance" ]; then
  if [ "${REVIEW_WAIT_RC:-}" -ne 124 ]; then
    echo "production review timeout returned rc=${REVIEW_WAIT_RC:-missing}, expected 124" >&2
    while IFS= read -r timeout_row; do
      timeout_status="$(jq -r .status <<<"$timeout_row")"
      echo "$(jq -r .edge <<<"$timeout_row") state=$(jq -r .state "$timeout_status" 2>/dev/null || echo missing)" >&2
      [ ! -f "$timeout_status" ] || cat "$timeout_status" >&2
      timeout_log="$(jq -r '.log // empty' "$timeout_status" 2>/dev/null || true)"
      [ -z "$timeout_log" ] || [ ! -f "$timeout_log" ] || cat "$timeout_log" >&2
    done <"$REVIEW_LAUNCHED"
    exit 1
  fi
  timeout_index=-1
  for i in "${!instances[@]}"; do [ "${instances[$i]}" != "$timeout_instance" ] || timeout_index="$i"; done
  [ "$timeout_index" -ge 0 ] || { echo "timed-out instance missing from launch roster" >&2; exit 1; }
  timeout_state="$(jq -r .state "${statuses[$timeout_index]}")"
  [ "$timeout_state" = timed_out ] || { echo "timeout state was $timeout_state" >&2; exit 1; }
  ! kill -0 "$(jq -r .pid "${statuses[$timeout_index]}")" 2>/dev/null || {
    echo "timed-out provider remains live" >&2; exit 1;
  }
fi

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
  "$CLAUDE_STUB_LOG" "${fail_instance:-$pre_ready_fail_instance}" "$timeout_instance" "$repair_instance" "$before_repair" "$after_repair" "${instances[@]}" <<'PY'
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
    if instance == timed_out:
        assert status["state"] == "timed_out" and status["exit_code"] == 124, status
        continue
    worktrees.add(status["worktree"])
    branches.add(status["branch"])
    child_logs.add(status["log"])
    assert status["log"] == str(child / "status.json") + ".log", status
    assert pathlib.Path(status["log"]).is_file(), status["log"]
    worktree = pathlib.Path(status["worktree"])
    if not worktree.is_absolute():
        worktree = repo / worktree
    if worktree.exists():
        print(f"leaked child status: {json.dumps(status, sort_keys=True)}", file=sys.stderr)
        log = pathlib.Path(status["log"])
        if log.is_file():
            print(f"leaked child log ({log}):\n{log.read_text()}", file=sys.stderr)
        raise AssertionError(worktree)
    branch = status["branch"]
    probe = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        check=False,
    )
    assert probe.returncode != 0, branch

expected_workspace_records = 5 if timed_out else 6
assert len(worktrees) == len(branches) == len(child_logs) == expected_workspace_records, (worktrees, branches, child_logs)
assert not [path for path in (repo / ".claude" / "worktrees").glob("*") if path.exists()]
if failed:
    assert statuses.count("failed") == 1 and statuses.count("completed") == 5, statuses
elif timed_out:
    terminal = json.loads((run_dir / "children" / timed_out / "status.json").read_text())["state"]
    assert terminal == "timed_out", terminal
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
[ ! -s "$SIX_CHILD_GIT_COLLISION_LOG" ] || {
  echo "concurrent git metadata mutations escaped dispatch serialization:" >&2
  cat "$SIX_CHILD_GIT_COLLISION_LOG" >&2
  exit 1
}
if [ "${SIX_CHILD_GIT_MUTATION_STRESS:-0}" = 1 ]; then
  python3 -I -B - "$SIX_CHILD_GIT_ARRIVAL_LOG" <<'PY'
import collections,pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
pending=[line.split("owner=",1)[1] for line in lines if line.startswith("pending\towner=")]
assert len(pending)==len(set(pending))==6,pending
releases=[line for line in lines if line.startswith("barrier-release\tcount=")]
assert releases==["barrier-release\tcount=5"],releases
events=collections.defaultdict(list)
for line in lines:
    if not line.startswith("critical\t"): continue
    fields=dict(field.split("=",1) for field in line.split("\t")[1:])
    events[fields["owner"]].append(fields["phase"])
assert len(events)==6,events
assert all(phases==["remove","list","branch","release"] for phases in events.values()),events
PY
  [ ! -e "$repo/.git/.uberdev-six-child-git-critical" ]
fi

# The canonical reviewer boundary drives the existing one-shot format-retry
# edge. A repaired result is accepted; two contradictory documents remain
# fail-closed instead of reaching aggregation.
if [ "$case_name" = 1 ]; then
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
fi

expected_provider_launches=7
if [ "$case_name" = 1 ]; then expected_provider_launches=13; fi
[ "$(wc -l <"$CODEX_STUB_LOG" | tr -d ' ')" -eq "$expected_provider_launches" ] || {
  echo "case $case_name launched an unexpected number of providers" >&2
  exit 1
}
SH
RUN_CASE_SCRIPT="$TMP/run-case.sh"
if [ "$RUNTIME_NAMESPACE" = prkit ]; then
  RUN_CASE_SCRIPT="$TMP/run-case-prkit.sh"
  sed -e 's/uberdev_/prkit_/g' -e 's/UBERDEV_/PRKIT_/g' \
    "$TMP/run-case.sh" >"$RUN_CASE_SCRIPT"
fi
chmod +x "$RUN_CASE_SCRIPT"

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
  local name="$1" fail_instance="${2-}" timeout_instance="${3-}" skip_ready_instance="${4-}" pre_ready_fail_instance="${5-}"
  local repo runtime codex_log claude_log barrier_timeout=60 git_mutation_stress=0
  repo="$TMP/repo-$name"; runtime="$TMP/runtime-$name"
  codex_log="$TMP/codex-$name.log"; claude_log="$TMP/claude-$name.log"
  make_repo "$repo"
  mkdir -p "$runtime" "$runtime/git-preacquire"
  ready_dir="$runtime/ready"; release_dir="$runtime/release"
  [ -z "$skip_ready_instance" ] || barrier_timeout=2
  [ "$name" != 3 ] || git_mutation_stress=1
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    SIX_CHILD_REAL_GIT="$REAL_GIT" SIX_CHILD_GIT_COLLISION_LOG="$runtime/git-collisions.log" \
    SIX_CHILD_GIT_ARRIVAL_LOG="$runtime/git-arrivals.log" \
    SIX_CHILD_GIT_PREACQUIRE_DIR="$runtime/git-preacquire" \
    SIX_CHILD_GIT_MUTATION_STRESS="$git_mutation_stress" \
    PLUGIN_ROOT="$RUNTIME_ROOT" WORKTREE_ROOT="$repo" \
    UBERDEV_TMPDIR="$runtime" PRKIT_TMPDIR="$runtime" \
    CODEX_STUB_LOG="$codex_log" CLAUDE_STUB_LOG="$claude_log" \
    CODEX_STUB_READY_DIR="$ready_dir" CODEX_STUB_RELEASE_DIR="$release_dir" \
    CODEX_STUB_BARRIER_REPORT="$runtime/readiness-report.txt" \
    CODEX_STUB_FAIL_INSTANCE="$fail_instance" CODEX_STUB_HANG_INSTANCE="$timeout_instance" \
    CODEX_STUB_SKIP_READY_INSTANCE="$skip_ready_instance" \
    CODEX_STUB_PRE_READY_FAIL_INSTANCE="$pre_ready_fail_instance" \
    REVIEW_BARRIER_TIMEOUT_OVERRIDE="$barrier_timeout" \
    RUN_ID="20260716-00000${name}-abcdef0" \
    PR_NUMBER=335 ARGUMENTS='' SOLVE_TIMEOUT=120 UBERDEV_AGENT_CAPACITY=6 PRKIT_AGENT_CAPACITY=6 \
    bash "$RUN_CASE_SCRIPT" "$name" "$repo" "$TMP/setup.sh" \
      "$TMP/post-setup.sh" "$TMP/post-boundary.sh" "$fail_instance" "$timeout_instance" \
      "$skip_ready_instance" "$pre_ready_fail_instance"
}

case "${SIX_CHILD_CASE:-all}" in
  1) run_case 1 ;;
  2) run_case 2 post-review-20260716-000002-abcdef0-r3-iter1-attempt01 ;;
  3) run_case 3 '' post-review-20260716-000003-abcdef0-r4-iter1-attempt01 ;;
  4) run_case 4 '' '' post-review-20260716-000004-abcdef0-r2-iter1-attempt01 ;;
  5) run_case 5 '' '' '' post-review-20260716-000005-abcdef0-r5-iter1-attempt01 ;;
  all)
    run_case 1
    run_case 2 post-review-20260716-000002-abcdef0-r3-iter1-attempt01
    run_case 3 '' post-review-20260716-000003-abcdef0-r4-iter1-attempt01
    run_case 4 '' '' post-review-20260716-000004-abcdef0-r2-iter1-attempt01
    run_case 5 '' '' '' post-review-20260716-000005-abcdef0-r5-iter1-attempt01
    ;;
  *) echo "unknown SIX_CHILD_CASE=$SIX_CHILD_CASE" >&2; exit 2 ;;
esac

echo "review-pr Codex six-child integration tests passed"
