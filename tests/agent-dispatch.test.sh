#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"

[ -r "$LIB" ] || { echo "agent-dispatch: missing $LIB" >&2; exit 1; }

# Windows Python does not expose os.geteuid(). Every embedded ownership/state
# expression must use the same deterministic portable fallback.
python3 -I - "$LIB" <<'PY'
import os,pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
assert 'os.geteuid()' not in text
prepare=text.split('_uberdev_agent_prepare_state_dir() {',1)[1].split('\n}',1)[0]
assert 'if os.name == "nt":' in prepare
assert 'os.makedirs(path, exist_ok=True)' in prepare
assert prepare.index('if os.name == "nt":') < prepare.index('descriptor = os.open(path, flags)')
saved=getattr(os,'geteuid',None)
if saved is not None: del os.geteuid
try:
 uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
 assert f'.agent-state-{uid if uid is not None else 0}'=='.agent-state-0'
 assert uid is None  # ownership checks are intentionally skipped on Windows
finally:
 if saved is not None: os.geteuid=saved
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run"
STATE_DIR="$TMP/run/.agent-state-$(id -u)"
printf 'instrumented prompt\n' > "$TMP/run/prompt.txt"

python3 -I - "$LIB" "$TMP/run/windows-watcher-error.json" <<'PY'
import glob
import json
import os
import stat
import sys
import tempfile
import types

source_path, output_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as handle:
    source = handle.read()
function = source.index("_uberdev_agent_persist_watcher_error() {")
prefix = "<<'PY'\n"
start = source.index(prefix, function) + len(prefix)
end = source.index("\nPY\n}", start)
snippet = source[start:end]
original_name = os.name
original_fchmod = getattr(os, "fchmod", None)
os.name = "nt"
if original_fchmod is not None:
    del os.fchmod
try:
    sys.argv = ["watcher-error", output_path, "codex", "handle-1", "failed", "3"]
    exec(compile(snippet, "watcher-error-publisher", "exec"), {})
finally:
    os.name = original_name
    if original_fchmod is not None:
        os.fchmod = original_fchmod
with open(output_path, encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload["error"] == "terminal_finalize_failed" and payload["attempts"] == 3
assert not glob.glob(os.path.join(os.path.dirname(output_path), ".watcher-error.*"))
PY

python3 -I - "$LIB" "$TMP/run/windows-agent-status.json" <<'PY'
import glob
import json
import os
import stat
import sys
import tempfile
import types

source_path, output_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as handle:
    source = handle.read()
function = source.index("_uberdev_agent_publish_status_record() {")
prefix = "python3 -I -B - \"$@\" <<'PY'\n"
start = source.index(prefix, function) + len(prefix)
end = source.index("\nPY\n}", start)
snippet = source[start:end]
original_name = os.name
original_fchmod = getattr(os, "fchmod", None)
original_msvcrt = sys.modules.get("msvcrt")
os.name = "nt"
if original_fchmod is not None:
    del os.fchmod
sys.modules["msvcrt"] = types.SimpleNamespace(
    LK_NBLCK=1,
    LK_UNLCK=2,
    locking=lambda descriptor, mode, size: None,
)
try:
    sys.argv = ["agent-status", output_path, "create", "codex", "running", "", "handle-1", "", "", "", "", "", "", "", "", "", "", "0"]
    exec(compile(snippet, "agent-status-publisher", "exec"), {})
    sys.argv = ["agent-status", output_path, "create", "codex", "running", "", "handle-1", "", "", "", "", "", "", "", "", "", "", "0"]
    exec(compile(snippet, "agent-status-publisher", "exec"), {})
    sys.argv = ["agent-status", output_path, "replace", "codex", "completed", "0", "handle-1", "", "", "", "", "", "", "", "", "", "", "0"]
    exec(compile(snippet, "agent-status-publisher", "exec"), {})
finally:
    os.name = original_name
    if original_fchmod is not None:
        os.fchmod = original_fchmod
    if original_msvcrt is None:
        del sys.modules["msvcrt"]
    else:
        sys.modules["msvcrt"] = original_msvcrt
with open(output_path, encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload["state"] == "completed" and payload["exit_code"] == 0
assert not glob.glob(os.path.join(os.path.dirname(output_path), ".agent-status.*"))
PY

python3 -I - "$LIB" "$TMP/run" <<'PY'
import contextlib
import glob
import hashlib
import io
import json
import os
import re
import secrets
import stat
import sys
import tempfile

source_path, run_root = sys.argv[1:]
with open(source_path, encoding="utf-8") as handle:
    source = handle.read()
function = source.index("uberdev_agent_context_create() {")
prefix = "python3 -I -B -c '\n"
start = source.index(prefix, function) + len(prefix)
end = source.index("\n' \"$1\" \"$payload\"", start)
snippet = source[start:end]
payload = json.dumps({"metadata": {"run_id": "windows-route", "workflow": "solve"}}, sort_keys=True, separators=(",", ":"))
run_root = os.path.realpath(run_root)
original_name = os.name
original_fchmod = getattr(os, "fchmod", None)
os.name = "nt"
if original_fchmod is not None:
    del os.fchmod
try:
    sys.argv = ["route-context", run_root, payload]
    stdout = io.StringIO()
    try:
        with contextlib.redirect_stdout(stdout):
            exec(compile(snippet, "route-context-publisher", "exec"), {})
    except SystemExit as exc:
        assert exc.code == 0, exc.code
    result = json.loads(stdout.getvalue())
    destination = result["context_file"]
    with open(destination, encoding="utf-8") as handle:
        assert handle.read() == payload
    assert result["context_sha256"] == hashlib.sha256(payload.encode()).hexdigest()
    assert not glob.glob(os.path.join(os.path.dirname(destination), ".route-context.*"))
    sys.argv = ["route-context", run_root, payload]
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            exec(compile(snippet, "route-context-publisher", "exec"), {})
    except SystemExit as exc:
        assert exc.code == 2, exc.code
    else:
        raise AssertionError("immutable Windows route context was replaced")
    with open(destination, encoding="utf-8") as handle:
        assert handle.read() == payload
finally:
    os.name = original_name
    if original_fchmod is not None:
        os.fchmod = original_fchmod
PY

REQUEST="$(python3 - "$TMP/run" <<'PY'
import json, sys
run = sys.argv[1]
print(json.dumps({
    "schema_version": 1,
    "run_dir": run,
    "run_id": "agent-dispatch-test",
    "repository_id": "fixture-repository",
    "backend": "codex",
    "workflow": "solve",
    "phase": "review",
    "role": "code-simplifier",
    "task_tier": "medium",
    "risk_signals": [],
    "routing_mode": "adaptive",
    "issue_or_pr": "42",
    "issue_num": 42,
    "capacity": 20,
    "timeout_s": 30,
}, sort_keys=True, separators=(",", ":")))
PY
)"

export UBERDEV_AGENT_DISPATCH_ROOT="$ROOT/plugins/uberdev"
export UBERDEV_AGENT_DISPATCH_TEST_BACKEND=1
export UBERDEV_TEST_CAPTURE="$TMP/backend.json"

# The public adapter calls this provider boundary once.  Production dispatch.sh
# defines the same hook and selects exactly one existing backend arm.
_uberdev_agent_dispatch_backend() {
  [ "$#" -eq 7 ]
  count=0
  [ ! -r "$TMP/provider-count" ] || read -r count < "$TMP/provider-count"
  printf '%s\n' "$((count + 1))" > "$TMP/provider-count"
  # The lifecycle start is durable before the one provider boundary is crossed.
  python3 - "$STATE_DIR/agent-lifecycle.jsonl" "$6" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
status = str(pathlib.Path(sys.argv[2]).resolve())
started = [event for event in events if event.get("event") == "agent_started" and event.get("status_path") == status]
assert len(started) == 1, started
run_id = started[0]["run_id"]
actual = [event["event"] for event in events if event["run_id"] == run_id]
assert actual == ["route_decided", "agent_started"], actual
PY
  python3 - "$UBERDEV_TEST_CAPTURE" "$UBERDEV_AGENT_WORKSPACE_MODE" "$UBERDEV_AGENT_WORKSPACE_DIR" "$@" <<'PY'
import json, sys
path, workspace_mode, workspace_dir, backend, issue, tier, prompt, result, status, decision = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "backend": backend, "issue": issue, "tier": tier,
        "prompt": prompt, "result": result, "status": status,
        "decision": json.loads(decision),
        "workspace_mode": workspace_mode, "workspace_dir": workspace_dir,
    }, handle, sort_keys=True)
PY
  DISPATCH_RC=0
  DISPATCH_ID="opaque:test-handle"
  DISPATCH_LOG=""
  case "$5" in
    *sync-result.md)
      printf 'synchronous result\n' > "$5"
      printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *no-status.md)
      :
      ;;
    *async-terminal.md)
      printf '{"backend":"codex","state":"running","exit_code":null,"pid":"opaque:test-handle"}\n' > "$6"
      (
        sleep 1
        printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$6"
      ) &
      ;;
    *generation-race.md)
      printf '{"backend":"codex","state":"running","exit_code":null,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-invalid-backend-exit.md)
      printf '{"backend":"background","state":"completed","exit_code":9,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-backend-mismatch.md)
      printf '{"backend":"background","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-multiple-state.md)
      printf '{"backend":"codex","state":"completed","status":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-bool-exit.md)
      printf '{"backend":"codex","state":"completed","exit_code":true,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-string-exit.md)
      printf '{"backend":"codex","state":"completed","exit_code":"0","pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *terminal-handle-mismatch.md)
      printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:other-handle"}\n' > "$6"
      ;;
    *result.md)
      printf '{"backend":"codex","state":"running","exit_code":null,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
    *)
      printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
  esac
  # Provider status is a private lifecycle record. Production provider arms
  # precreate it 0600 and retain that mode across atomic replacements; keep
  # this boundary stub faithful to the same contract.
  [ ! -e "$6" ] || chmod 600 "$6"
  return 0
}
export -f _uberdev_agent_dispatch_backend

# shellcheck source=/dev/null
. "$LIB"

# Newly emitted starts require an owner creation identity. If that kernel probe
# is unavailable, dispatch fails before provider launch and releases the exact
# prelaunch lease instead of degrading the manifest to PID-only ownership.
OWNER_IDENTITY_RUN="$TMP/owner-identity-unavailable"
mkdir -p "$OWNER_IDENTITY_RUN"
printf 'owner identity unavailable prompt\n' >"$OWNER_IDENTITY_RUN/prompt.txt"
OWNER_IDENTITY_REQUEST="$(python3 -I -B - "$REQUEST" "$OWNER_IDENTITY_RUN" <<'PY'
import json,sys
value=json.loads(sys.argv[1]); value.update(run_dir=sys.argv[2],run_id='owner-identity-unavailable')
print(json.dumps(value,separators=(',',':')),end='')
PY
)"
eval "$(declare -f _uberdev_agent_process_identity | sed '1s/_uberdev_agent_process_identity/_real_owner_process_identity/')"
_uberdev_agent_process_identity() {
  [ "$1" != "$$" ] || return 2
  _real_owner_process_identity "$@"
}
owner_provider_before=0
[ ! -r "$TMP/provider-count" ] || read -r owner_provider_before <"$TMP/provider-count"
set +e
uberdev_agent_dispatch "$OWNER_IDENTITY_REQUEST" "$OWNER_IDENTITY_RUN/prompt.txt" \
  "$OWNER_IDENTITY_RUN/result.md" "$OWNER_IDENTITY_RUN/status.json" >/dev/null 2>&1
owner_identity_rc=$?
set -e
owner_provider_after=0
[ ! -r "$TMP/provider-count" ] || read -r owner_provider_after <"$TMP/provider-count"
eval "$(declare -f _real_owner_process_identity | sed '1s/_real_owner_process_identity/_uberdev_agent_process_identity/')"
[ "$owner_identity_rc" -eq 2 ]
[ "$owner_provider_after" -eq "$owner_provider_before" ]
grep -q '"state":"failed"' "$OWNER_IDENTITY_RUN/status.json"
! find "$OWNER_IDENTITY_RUN/.agent-state-$(id -u)/semaphore-v1" -name '*.lease' -type f | grep -q .

# Detached review fanout cannot rely on an interactive Claude permission
# prompt. The adapter must reject manual mode before capacity or provider state
# is created, while an explicit unattended opt-in remains accepted.
if SKIP_PERMISSIONS=0 AUTO_PERMISSIONS=0 \
    _uberdev_agent_claude_permissions_preflight review-pr >/dev/null 2>&1; then
  echo "agent-dispatch: Claude review permission preflight accepted manual mode" >&2
  exit 1
fi
SKIP_PERMISSIONS=0 AUTO_PERMISSIONS=1 \
  _uberdev_agent_claude_permissions_preflight review-pr
SKIP_PERMISSIONS=0 AUTO_PERMISSIONS=0 \
  _uberdev_agent_claude_permissions_preflight solve

# Exercise the public boundary, not only the helper: manual review mode must
# fail before provider invocation, lifecycle publication, status, or capacity.
PREFLIGHT_RUN="$TMP/preflight-review"
mkdir -p "$PREFLIGHT_RUN"
printf 'review preflight prompt\n' > "$PREFLIGHT_RUN/prompt.txt"
PREFLIGHT_REQUEST="$(python3 -I -B - "$REQUEST" "$PREFLIGHT_RUN" <<'PY'
import json,sys
request=json.loads(sys.argv[1]); request.update({
    'run_dir':sys.argv[2], 'run_id':'agent-dispatch-review-preflight',
    'backend':'claude-bg', 'workflow':'review-pr', 'phase':'review',
})
print(json.dumps(request,sort_keys=True,separators=(',',':')))
PY
)"
provider_before=0
[ ! -r "$TMP/provider-count" ] || read -r provider_before < "$TMP/provider-count"
if SKIP_PERMISSIONS=0 AUTO_PERMISSIONS=0 uberdev_agent_dispatch "$PREFLIGHT_REQUEST" \
    "$PREFLIGHT_RUN/prompt.txt" "$PREFLIGHT_RUN/result.md" "$PREFLIGHT_RUN/status.json" >/dev/null 2>&1; then
  echo "agent-dispatch public review preflight accepted manual Claude mode" >&2
  exit 1
fi
provider_after=0
[ ! -r "$TMP/provider-count" ] || read -r provider_after < "$TMP/provider-count"
[ "$provider_after" -eq "$provider_before" ] || { echo "review preflight reached provider" >&2; exit 1; }
[ ! -e "$PREFLIGHT_RUN/.agent-state-$(id -u)" ] \
  && [ ! -e "$PREFLIGHT_RUN/status.json" ] \
  && [ ! -e "$PREFLIGHT_RUN/result.md" ] || {
    echo "review preflight published lifecycle state before refusing" >&2; exit 1;
  }

for dead_helper in \
  _uberdev_agent_default_catalog \
  _uberdev_agent_catalog \
  _uberdev_agent_non_codex_decision
do
  if declare -F "$dead_helper" >/dev/null; then
    echo "agent-dispatch: dead helper remains defined: $dead_helper" >&2
    exit 1
  fi
done

grep -Fq 'UBERDEV_SEMAPHORE_OWNER_PID=$$ PYTHONPATH= PYTHONHOME= uberdev_semaphore_acquire' "$LIB" || {
  echo "agent-dispatch: known shell owner is not supplied to semaphore acquisition" >&2
  exit 1
}

wait_for_terminal_and_release() {
  local manifest="$1" state_dir="$2" run_id="$3" terminal="$4" attempts="${5:-80}" delay="${6:-0.1}" actual
  for _ in $(seq 1 "$attempts"); do
    if python3 -I - "$manifest" "$run_id" "$terminal" <<'PY'
import json, pathlib, sys
path, run_id, terminal = sys.argv[1:]
try:
    events = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines()]
except (FileNotFoundError, ValueError):
    raise SystemExit(1)
actual = [event.get("event") for event in events if event.get("run_id") == run_id]
raise SystemExit(0 if actual == ["route_decided", "agent_started", terminal] else 1)
PY
    then
      if ! grep -R -q "run_id=$run_id" "$state_dir/semaphore-v1" 2>/dev/null; then
        return 0
      fi
    fi
    command sleep "$delay"
  done
  actual="$(python3 -I - "$manifest" "$run_id" <<'PY'
import json, pathlib, sys
try: events=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
except Exception: events=[]
print([event.get("event") for event in events if event.get("run_id")==sys.argv[2]])
PY
)"
  echo "terminal invariant timeout: run_id=$run_id expected=$terminal actual=$actual lease=$(grep -R -l "run_id=$run_id" "$state_dir/semaphore-v1" 2>/dev/null | head -1)" >&2
  return 1
}

uberdev_agent_dispatch "$REQUEST" \
  "$TMP/run/prompt.txt" "$TMP/run/result.md" "$TMP/run/status.json"

python3 - "$TMP/backend.json" "$STATE_DIR/agent-lifecycle.jsonl" "$TMP/run/status.json" "$$" <<'PY'
import json, os, pathlib, stat, sys
capture = json.loads(pathlib.Path(sys.argv[1]).read_text())
decision = capture["decision"]
assert capture["backend"] == "codex"
assert capture["workspace_mode"] == "isolated" and capture["workspace_dir"] == ""
assert decision["logical_route"] == "quality", decision
assert decision["model"] == "gpt-5.6-sol", decision
assert decision["reasoning_effort"] == "medium", decision
assert decision["service_tier"] == "default", decision
assert decision["sandbox"] == "read-only", decision
events = [json.loads(line) for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
assert [event["event"] for event in events] == ["route_decided", "agent_started"], events
assert events[0]["effective_model"] == "gpt-5.6-sol"
assert "backend_handle" not in events[1]
assert events[1]["status_path"] == str(pathlib.Path(sys.argv[3]).resolve())
assert events[1]["owner_pid"] == int(sys.argv[4]), events[1]
if os.name != "nt":
    assert stat.S_IMODE(pathlib.Path(sys.argv[3]).stat().st_mode) == 0o600
PY

# Opaque handles remain live for reconciliation and retain their lease.
LEASES="$(find "$STATE_DIR" -name '*.lease' -type f | wc -l | tr -d ' ')"
[ "$LEASES" = 1 ] || { echo "expected one registered opaque lease, got $LEASES" >&2; exit 1; }
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$TMP/run/status.json"
for _ in 1 2 3 4 5; do
  ! grep -R -q 'run_id=agent-dispatch-test' "$STATE_DIR/semaphore-v1" 2>/dev/null && break
  sleep 1
done
if grep -R -q 'run_id=agent-dispatch-test' "$STATE_DIR/semaphore-v1" 2>/dev/null; then
  echo "terminalized opaque fixture retained its lease" >&2
  exit 1
fi

# Caller workspace metadata reaches the provider adapter but is excluded from
# the routing projection. Unsupported/mismatched workspace requests fail before
# any lifecycle state or provider call.
mkdir -p "$TMP/caller-repo"
CALLER_REPO="$(cd "$TMP/caller-repo" && pwd -P)"
CALLER_REQUEST="$(python3 -I - "$REQUEST" "$CALLER_REPO" <<'PY'
import json,sys
request=json.loads(sys.argv[1]); request['run_id']='agent-dispatch-caller'
request['repository_id']=sys.argv[2]; request['workspace_mode']='caller'; request['workspace_dir']=sys.argv[2]
print(json.dumps(request,sort_keys=True,separators=(',',':')))
PY
)"
uberdev_agent_dispatch "$CALLER_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/caller-result.md" "$TMP/run/caller-status.json"
python3 -I - "$TMP/backend.json" "$CALLER_REPO" <<'PY'
import json,pathlib,sys
capture=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert capture['workspace_mode']=='caller' and capture['workspace_dir']==sys.argv[2]
assert 'workspace_mode' not in capture['decision'] and 'workspace_dir' not in capture['decision']
PY
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$TMP/run/caller-status.json"
wait_for_terminal_and_release "$STATE_DIR/agent-lifecycle.jsonl" "$STATE_DIR" agent-dispatch-caller completed 80 0.1

workspace_provider_before="$(cat "$TMP/provider-count")"
for workspace_case in invalid missing mismatch unsupported unexpected; do
  invalid_run="$TMP/workspace-invalid-$workspace_case"; mkdir -p "$invalid_run"; printf 'prompt\n' > "$invalid_run/prompt.txt"
  invalid_request="$(python3 -I - "$REQUEST" "$invalid_run" "$CALLER_REPO" "$workspace_case" <<'PY'
import json,sys
request=json.loads(sys.argv[1]); request['run_dir']=sys.argv[2]; request['run_id']='workspace-invalid-'+sys.argv[4]
case=sys.argv[4]
if case=='invalid': request['workspace_mode']='shared'
elif case=='missing': request['workspace_mode']='caller'
elif case=='mismatch': request.update(workspace_mode='caller',workspace_dir=sys.argv[2],repository_id=sys.argv[3])
elif case=='unsupported': request.update(workspace_mode='caller',workspace_dir=sys.argv[3],repository_id=sys.argv[3],backend='background',routing_mode='inherit')
elif case=='unexpected': request.update(workspace_mode='isolated',workspace_dir=sys.argv[3])
print(json.dumps(request,sort_keys=True,separators=(',',':')))
PY
)"
  if uberdev_agent_dispatch "$invalid_request" "$invalid_run/prompt.txt" "$invalid_run/result.md" "$invalid_run/status.json" >/dev/null 2>&1; then
    echo "invalid workspace request accepted: $workspace_case" >&2; exit 1
  fi
  [ ! -e "$invalid_run/.agent-state-$(id -u)" ] || { echo "invalid workspace request created state: $workspace_case" >&2; exit 1; }
done
[ "$(cat "$TMP/provider-count")" = "$workspace_provider_before" ] || { echo 'invalid workspace request reached provider' >&2; exit 1; }

# Public issue identity is a canonical positive JSON integer and must agree
# with issue_or_pr before any private state or provider boundary exists.
ISSUE_SENTINEL="$TMP/outside-issue-sentinel"
printf 'unchanged\n' > "$ISSUE_SENTINEL"
issue_provider_before="$(cat "$TMP/provider-count")"
issue_validation_failures=''
while IFS='|' read -r issue_label issue_json issue_or_pr_json; do
  issue_run="$TMP/invalid-issue-$issue_label"
  mkdir -p "$issue_run"
  printf 'invalid issue prompt\n' > "$issue_run/prompt.txt"
  issue_request="$(python3 -I - "$REQUEST" "$issue_run" "$issue_label" "$issue_json" "$issue_or_pr_json" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
request["run_dir"] = sys.argv[2]
request["run_id"] = "invalid-issue-" + sys.argv[3]
request["issue_num"] = json.loads(sys.argv[4])
request["issue_or_pr"] = json.loads(sys.argv[5])
print(json.dumps(request, sort_keys=True, separators=(",", ":")))
PY
)"
  if uberdev_agent_dispatch "$issue_request" "$issue_run/prompt.txt" \
      "$issue_run/result.md" "$issue_run/status.json" >/dev/null 2>&1; then
    issue_validation_failures="$issue_validation_failures accepted:$issue_label"
  fi
  if [ -e "$issue_run/.agent-state-$(id -u)" ]; then
    issue_validation_failures="$issue_validation_failures state-created:$issue_label"
  fi
done <<'EOF_ISSUES'
traversal|"x/../../victim"|42
absolute|"/tmp/absolute-victim"|42
numeric-string|"42"|42
boolean|true|42
zero|0|0
negative|-1|-1
float|1.5|1.5
mismatch|42|43
EOF_ISSUES
if [ "$(cat "$TMP/provider-count")" != "$issue_provider_before" ]; then
  issue_validation_failures="$issue_validation_failures provider-called"
fi
if [ "$(cat "$ISSUE_SENTINEL")" != unchanged ]; then
  issue_validation_failures="$issue_validation_failures sentinel-clobbered"
fi
if [ -n "$issue_validation_failures" ]; then
  echo "issue identity validation failed:$issue_validation_failures" >&2
  exit 1
fi

# A detached status transition is consumed by the adapter-owned watcher: it
# appends the real terminal event and releases capacity without an abandoned
# reconciliation record.
ASYNC_REQUEST="${REQUEST/agent-dispatch-test/agent-dispatch-async}"
uberdev_agent_dispatch "$ASYNC_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/async-terminal.md" "$TMP/run/async-terminal.json"
wait_for_terminal_and_release "$STATE_DIR/agent-lifecycle.jsonl" "$STATE_DIR" agent-dispatch-async completed 150 0.1
python3 - "$STATE_DIR/agent-lifecycle.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
actual = [event["event"] for event in events if event["run_id"] == "agent-dispatch-async"]
assert actual == ["route_decided", "agent_started", "completed"], ("agent-dispatch-async", actual)
PY

variant_request() {
  python3 - "$REQUEST" "$1" "$2" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
request["run_id"] = sys.argv[2]
kind = sys.argv[3]
request.pop("routing_mode", None)
if kind == "inherit": request["routing_mode"] = "inherit"
elif kind == "ultra": request["explicit_route"] = "sol-ultra"
elif kind == "shadow": request["shadow"] = True
elif kind == "claude":
    request["backend"] = "claude-bg"
    request["routing_mode"] = "inherit"
elif kind == "claude-forced":
    request["backend"] = "claude-bg"
    request["explicit_route"] = "sol-ultra"
elif kind == "claude-fast":
    request["backend"] = "claude-bg"
    request["routing_mode"] = "inherit"
    request["explicit_service_tier"] = "fast"
print(json.dumps(request, sort_keys=True, separators=(",", ":")))
PY
}

# Terminal-shaped provider files are authoritative only after the full
# canonical backend/exit/state-carrier/handle validation succeeds.
terminal_validation_failures=''
for terminal_case in \
  invalid-backend-exit backend-mismatch multiple-state bool-exit string-exit handle-mismatch
do
  terminal_run_id="agent-dispatch-terminal-$terminal_case"
  terminal_request="$(variant_request "$terminal_run_id" inherit)"
  terminal_result="$TMP/run/terminal-$terminal_case.md"
  terminal_status="$TMP/run/terminal-$terminal_case.json"
  uberdev_agent_dispatch "$terminal_request" "$TMP/run/prompt.txt" "$terminal_result" "$terminal_status"
  if ! python3 -I - "$STATE_DIR/agent-lifecycle.jsonl" "$terminal_run_id" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
actual = [event["event"] for event in events if event["run_id"] == sys.argv[2]]
assert actual == ["route_decided", "agent_started"], (sys.argv[2], actual)
PY
  then
    terminal_validation_failures="$terminal_validation_failures terminal-appended:$terminal_case"
  fi
  if ! grep -R -q "run_id=$terminal_run_id" "$STATE_DIR/semaphore-v1" 2>/dev/null; then
    terminal_validation_failures="$terminal_validation_failures lease-released:$terminal_case"
  fi
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$terminal_status"
  for _ in 1 2 3 4 5; do
    ! grep -R -q "run_id=$terminal_run_id" "$STATE_DIR/semaphore-v1" 2>/dev/null && break
    sleep 1
  done
done
if [ -n "$terminal_validation_failures" ]; then
  echo "terminal status validation failed:$terminal_validation_failures" >&2
  exit 1
fi

SHADOW_REQUEST="$(variant_request agent-dispatch-shadow shadow)"
uberdev_agent_dispatch "$SHADOW_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/shadow.md" "$TMP/run/shadow.json"
python3 - "$TMP/backend.json" <<'PY'
import json, pathlib, sys
decision = json.loads(pathlib.Path(sys.argv[1]).read_text())["decision"]
assert decision["routing_mode"] == "shadow", decision
assert decision["effective_policy"] == "inherit", decision
assert decision["model"] is None, decision
assert decision["adaptive_proposal"]["model"] == "gpt-5.6-sol", decision
PY

INHERIT_REQUEST="$(variant_request agent-dispatch-inherit inherit)"
uberdev_agent_dispatch "$INHERIT_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/inherit.md" "$TMP/run/inherit.json"
python3 - "$TMP/backend.json" <<'PY'
import json, pathlib, sys
decision = json.loads(pathlib.Path(sys.argv[1]).read_text())["decision"]
assert decision["effective_policy"] == "inherit"
assert decision["model"] is None and decision["reasoning_effort"] is None
assert decision["service_tier"] == "default"
PY

ULTRA_REQUEST="$(variant_request agent-dispatch-ultra ultra)"
uberdev_agent_dispatch "$ULTRA_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/ultra.md" "$TMP/run/ultra.json"
python3 - "$TMP/backend.json" <<'PY'
import json, pathlib, sys
decision = json.loads(pathlib.Path(sys.argv[1]).read_text())["decision"]
assert decision["forced"] is True
assert (decision["logical_route"], decision["model"], decision["reasoning_effort"]) == ("ultra", "gpt-5.6-sol", "ultra")
PY

CLAUDE_REQUEST="$(variant_request agent-dispatch-claude claude)"
uberdev_agent_dispatch "$CLAUDE_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/claude.md" "$TMP/run/claude.json"
python3 - "$TMP/backend.json" <<'PY'
import json, pathlib, sys
capture = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert capture["backend"] == "claude-bg"
decision = capture["decision"]
assert decision["effective_policy"] == "inherit"
assert decision["model"] is None and decision["reasoning_effort"] is None
PY

# An opaque provider without an immediate status write is registered through
# the adapter watcher and later converges on the provider terminal status.
NO_STATUS_REQUEST="$(variant_request agent-dispatch-no-status inherit)"
uberdev_agent_dispatch "$NO_STATUS_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/no-status.md" "$TMP/run/no-status.json"
grep -q '"state":"running"' "$TMP/run/no-status.json" || {
  echo "opaque dispatch did not publish canonical running status" >&2; exit 1;
}
grep -R -q "run_id=agent-dispatch-no-status" "$STATE_DIR/semaphore-v1" || {
  echo "opaque dispatch without current status was not registered" >&2; exit 1;
}
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$TMP/run/no-status.json"
for _ in 1 2 3 4 5; do
  ! grep -R -q 'run_id=agent-dispatch-no-status' "$STATE_DIR/semaphore-v1" 2>/dev/null && break
  sleep 1
done
if grep -R -q 'run_id=agent-dispatch-no-status' "$STATE_DIR/semaphore-v1" 2>/dev/null; then
  echo "terminalized no-status fixture retained its lease" >&2
  exit 1
fi

# A watcher releases only the exact lease inode it registered. Replacing the
# path with a separately published record that copies the visible generation
# must not let the old watcher delete the replacement.
GENERATION_REQUEST="$(variant_request agent-dispatch-generation-race inherit)"
uberdev_agent_dispatch "$GENERATION_REQUEST" "$TMP/run/prompt.txt" \
  "$TMP/run/generation-race.md" "$TMP/run/generation-race.json"
generation_lease="$(grep -R -l '^run_id=agent-dispatch-generation-race$' "$STATE_DIR/semaphore-v1" | head -1)"
[ -n "$generation_lease" ] || { echo "generation-race lease missing" >&2; exit 1; }
python3 -I - "$generation_lease" <<'PY'
import os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
payload = path.read_text().replace(
    "run_id=agent-dispatch-generation-race\n",
    "run_id=replacement-generation-race\n",
)
assert "run_id=replacement-generation-race\n" in payload
descriptor, temporary = tempfile.mkstemp(prefix=".replacement-lease.", dir=path.parent)
try:
    if os.name != "nt":
        os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:test-handle"}\n' > "$TMP/run/generation-race.json"
for _ in 1 2 3 4 5; do
  grep -q 'agent-dispatch-generation-race.*"event":"completed"\|"event":"completed".*agent-dispatch-generation-race' \
    "$STATE_DIR/agent-lifecycle.jsonl" 2>/dev/null && break
  sleep 1
done
[ -f "$generation_lease" ] && grep -q '^run_id=replacement-generation-race$' "$generation_lease" || {
  echo "old watcher removed a replacement lease" >&2
  exit 1
}
rm -f "$generation_lease"

# A Codex-only forced route aimed at a Claude backend fails before launch.
cp "$TMP/backend.json" "$TMP/before-unsupported.json"
CLAUDE_FORCED_REQUEST="$(variant_request agent-dispatch-claude-forced claude-forced)"
if uberdev_agent_dispatch "$CLAUDE_FORCED_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/claude-forced.md" "$TMP/run/claude-forced.json" >/dev/null 2>&1; then
  echo "agent-dispatch pretended to enforce Codex pins on Claude" >&2
  exit 1
fi
cmp -s "$TMP/backend.json" "$TMP/before-unsupported.json" || {
  echo "unsupported forced route reached provider boundary" >&2; exit 1;
}

# All caller paths are one disjoint set outside private lifecycle state.
provider_before="$(cat "$TMP/provider-count")"
lease_path="$(find "$STATE_DIR/semaphore-v1" -name '*.lease' -type f | head -1)"
ln "$TMP/run/prompt.txt" "$TMP/run/prompt-hardlink.txt"
for paths in \
  "$TMP/run/prompt.txt|$TMP/run/prompt.txt|$TMP/run/equal-status.json" \
  "$TMP/run/prompt.txt|$TMP/run/./prompt.txt|$TMP/run/normalized-status.json" \
  "$TMP/run/prompt.txt|$TMP/run/prompt-hardlink.txt|$TMP/run/hardlink-status.json" \
  "$TMP/run/prompt.txt|$STATE_DIR/agent-lifecycle.jsonl|$TMP/run/manifest-status.json" \
  "$TMP/run/prompt.txt|$STATE_DIR/model-catalog-v1.json|$TMP/run/catalog-status.json" \
  "$TMP/run/prompt.txt|$lease_path|$TMP/run/lease-status.json"
do
  old_ifs="$IFS"; IFS='|'; set -- $paths; IFS="$old_ifs"
  alias_request="${REQUEST/agent-dispatch-test/agent-dispatch-alias-$RANDOM}"
  if uberdev_agent_dispatch "$alias_request" "$1" "$2" "$3" >/dev/null 2>&1; then
    echo "agent-dispatch accepted aliased/private caller paths: $paths" >&2
    exit 1
  fi
done
rm -f "$TMP/run/prompt-hardlink.txt"
[ "$(cat "$TMP/provider-count")" = "$provider_before" ] || {
  echo "path-alias rejection reached provider boundary" >&2; exit 1;
}
if grep -q 'agent-dispatch-alias-' "$STATE_DIR/agent-lifecycle.jsonl"; then
  echo "path-alias rejection recorded lifecycle events" >&2; exit 1
fi
python3 "$ROOT/plugins/uberdev/lib/run_manifest.py" verify \
  --manifest "$STATE_DIR/agent-lifecycle.jsonl" >/dev/null

CLAUDE_FAST_REQUEST="$(variant_request agent-dispatch-claude-fast claude-fast)"
if uberdev_agent_dispatch "$CLAUDE_FAST_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/claude-fast.md" "$TMP/run/claude-fast.json" >/dev/null 2>&1; then
  echo "agent-dispatch pretended to enforce Codex fast service on Claude" >&2
  exit 1
fi
cmp -s "$TMP/backend.json" "$TMP/before-unsupported.json" || {
  echo "unsupported Codex service tier reached provider boundary" >&2; exit 1;
}

# The private lifecycle root itself cannot be redirected through a symlink.
mkdir -p "$TMP/evil-run" "$TMP/redirect-target"
printf 'evil state root probe\n' > "$TMP/evil-run/prompt.txt"
ln -s "$TMP/redirect-target" "$TMP/evil-run/.agent-state-$(id -u)"
EVIL_REQUEST="$(python3 - "$REQUEST" "$TMP/evil-run" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
request["run_dir"] = sys.argv[2]
request["run_id"] = "agent-dispatch-state-symlink"
print(json.dumps(request, sort_keys=True, separators=(",", ":")))
PY
)"
if uberdev_agent_dispatch "$EVIL_REQUEST" "$TMP/evil-run/prompt.txt" "$TMP/evil-run/result.md" "$TMP/evil-run/status.json" >/dev/null 2>&1; then
  echo "agent-dispatch followed a symlinked lifecycle root" >&2
  exit 1
fi
[ -z "$(find "$TMP/redirect-target" -mindepth 1 -print -quit)" ] || {
  echo "agent-dispatch wrote through a symlinked lifecycle root" >&2; exit 1;
}

# A synchronously observable terminal status is recorded and its lease is
# released immediately instead of being left for reconciliation.
SYNC_REQUEST="$(variant_request agent-dispatch-sync inherit)"
uberdev_agent_dispatch "$SYNC_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/sync-result.md" "$TMP/run/sync-status.json"
python3 - "$STATE_DIR/agent-lifecycle.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
sync = [event for event in events if event["run_id"] == "agent-dispatch-sync"]
assert [event["event"] for event in sync] == ["route_decided", "agent_started", "completed"], sync
PY
if grep -R -q 'run_id=agent-dispatch-sync' "$STATE_DIR/semaphore-v1" 2>/dev/null; then
  echo "synchronously completed dispatch retained its lease" >&2
  exit 1
fi

# Every file argument must stay within the declared run directory.
if uberdev_agent_dispatch "$REQUEST" /etc/passwd "$TMP/run/second.md" "$TMP/run/second.json" >/dev/null 2>&1; then
  echo "agent-dispatch accepted a prompt outside run_dir" >&2
  exit 1
fi

# A prelaunch provider failure records a terminal failure and releases its lease.
_uberdev_agent_dispatch_backend() {
  count=0
  [ ! -r "$TMP/provider-failure-count" ] || read -r count < "$TMP/provider-failure-count"
  printf '%s\n' "$((count + 1))" > "$TMP/provider-failure-count"
  DISPATCH_RC=17
  DISPATCH_ID=""
  DISPATCH_LOG="provider failed"
  return 17
}
export -f _uberdev_agent_dispatch_backend
FAIL_REQUEST="${REQUEST/agent-dispatch-test/agent-dispatch-fail}"
if uberdev_agent_dispatch "$FAIL_REQUEST" \
  "$TMP/run/prompt.txt" "$TMP/run/fail-result.md" "$TMP/run/fail-status.json"; then
  echo "agent-dispatch hid provider failure" >&2
  exit 1
else
  rc=$?
  [ "$rc" -eq 17 ] || { echo "expected rc=17, got $rc" >&2; exit 1; }
fi
[ "$(cat "$TMP/provider-failure-count")" = 1 ] || {
  echo "provider failure triggered a second model launch" >&2; exit 1;
}
python3 - "$STATE_DIR/agent-lifecycle.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
failed = [event for event in events if event["run_id"] == "agent-dispatch-fail"]
assert [event["event"] for event in failed] == ["route_decided", "agent_started", "failed"], failed
assert failed[-1]["error_class"] == "provider_launch_failed"
PY
if grep -R -q 'run_id=agent-dispatch-fail' "$STATE_DIR/semaphore-v1" 2>/dev/null; then
  echo "provider launch failure retained its capacity lease" >&2
  exit 1
fi
FAIL_RELEASE_PROBE="$(uberdev_semaphore_acquire "$STATE_DIR" fixture-repository codex 20 provider-failure-release-probe 30)" || {
  echo "provider launch failure capacity could not be reacquired" >&2; exit 1;
}
uberdev_semaphore_release "$FAIL_RELEASE_PROBE"

# zsh NOMATCH must not explode the semaphore's empty `*.lease` loops, and the
# adapter must restore both NOMATCH and NULL_GLOB on success and failure.
ZRUN="$TMP/zsh-run"
mkdir -p "$ZRUN"
printf 'zsh prompt\n' > "$ZRUN/prompt.txt"
zsh -f -c '
  setopt nomatch
  unsetopt nullglob
  . "$1"
  make_request() {
    python3 -I -c '\''import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":sys.argv[2],"repository_id":"zsh-fixture","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":77,"issue_num":77,"capacity":2,"timeout_s":10},separators=(",",":")))'\'' "$1" "$2"
  }
  _uberdev_agent_dispatch_backend() {
    DISPATCH_ID="opaque:zsh"
    if [ "${ZSH_FAIL_PROVIDER:-0}" = 1 ]; then DISPATCH_RC=17; return 17; fi
    printf '\''{"state":"completed"}\n'\'' > "$6"
    chmod 600 "$6"
    DISPATCH_RC=0
    return 0
  }
  cancel_count=0
  _uberdev_dispatch_cancel_backend() {
    cancel_count=$((cancel_count + 1))
    return 0
  }
  before_nomatch=$options[nomatch]; before_null=$options[nullglob]
  request=$(make_request "$2" zsh-success)
  uberdev_agent_dispatch "$request" "$2/prompt.txt" "$2/result.md" "$2/status.json" || exit 91
  [ "$options[nomatch]" = "$before_nomatch" ] && [ "$options[nullglob]" = "$before_null" ]
  request=$(make_request "$2" zsh-failure)
  ZSH_FAIL_PROVIDER=1 uberdev_agent_dispatch "$request" "$2/prompt.txt" "$2/fail.md" "$2/fail.json"
  rc=$?
  [ "$rc" -eq 2 ] && [ "$cancel_count" -eq 1 ]
  [ "$options[nomatch]" = "$before_nomatch" ] && [ "$options[nullglob]" = "$before_null" ]
' _ "$LIB" "$ZRUN"

# Owner-exit reconciliation is proven independently for every async backend.
# A second process cannot take cap=1 while canonical status is live, can take
# it after terminal, and run-manifest reconciliation never invents abandoned.
. "$ROOT/plugins/uberdev/lib/dispatch.sh"
CROSS_BIN="$TMP/cross-bin"
mkdir -p "$CROSS_BIN"
cat > "$CROSS_BIN/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = agents ] && [ "${2:-}" = --all ] && [ "${3:-}" = --json ]; then
  if [ "${CROSS_CLAUDE_STOP_MODE:-}" = delayed ] && [ -r "${CROSS_CLAUDE_STOP_COUNT:-}" ]; then
    probes=0
    [ -z "${CROSS_CLAUDE_PROBE_COUNT:-}" ] || [ ! -r "$CROSS_CLAUDE_PROBE_COUNT" ] || read -r probes < "$CROSS_CLAUDE_PROBE_COUNT"
    probes=$((probes + 1))
    [ -z "${CROSS_CLAUDE_PROBE_COUNT:-}" ] || printf '%s\n' "$probes" > "$CROSS_CLAUDE_PROBE_COUNT"
    if [ "$probes" -ge 21 ]; then
      printf '[{"sessionId":"abc12345-full","state":"cancelled"}]\n'
      exit 0
    fi
  fi
  cat "$CROSS_CLAUDE_STATE"
  exit 0
fi
if [ "${1:-}" = stop ] && [ "${2:-}" = abc12345-full ]; then
  count=0
  [ -z "${CROSS_CLAUDE_STOP_COUNT:-}" ] || [ ! -r "$CROSS_CLAUDE_STOP_COUNT" ] || read -r count < "$CROSS_CLAUDE_STOP_COUNT"
  count=$((count + 1))
  [ -z "${CROSS_CLAUDE_STOP_COUNT:-}" ] || printf '%s\n' "$count" > "$CROSS_CLAUDE_STOP_COUNT"
  [ "${CROSS_CLAUDE_STOP_MODE:-}" != never ] || exit 2
  if [ "${CROSS_CLAUDE_STOP_MODE:-}" = once ] && [ "$count" -eq 1 ]; then exit 2; fi
  [ "${CROSS_CLAUDE_STOP_MODE:-}" != sticky ] || exit 0
  if [ "${CROSS_CLAUDE_STOP_MODE:-}" = delayed ]; then
    exit 0
  fi
  printf '[]\n' > "$CROSS_CLAUDE_STATE"
  exit 0
fi
exit 2
SH
chmod +x "$CROSS_BIN/claude"

# The short Claude handle must resolve to exactly one full session. A shared
# prefix is ambiguous and must remain unknown instead of selecting row order.
printf '[{"sessionId":"abc12345-one","state":"running"},{"sessionId":"abc12345-two","state":"completed"}]\n' \
  > "$TMP/ambiguous-claude-agents.json"
if CROSS_CLAUDE_STATE="$TMP/ambiguous-claude-agents.json" PATH="$CROSS_BIN:$PATH" \
    _uberdev_agent_claude_probe abc12345 >/dev/null 2>&1; then
  echo "Claude watcher accepted an ambiguous session prefix" >&2
  exit 1
fi
printf '[{"sessionId":"abc12345-one","state":"future-state"}]\n' \
  > "$TMP/unknown-claude-status.json"
if CROSS_CLAUDE_STATE="$TMP/unknown-claude-status.json" PATH="$CROSS_BIN:$PATH" \
    _uberdev_agent_claude_probe abc12345 >/dev/null 2>&1; then
  echo "Claude watcher treated an unknown status as completed" >&2
  exit 1
fi
printf '[{"sessionId":"abc12345-full","state":"blocked","blockedReason":"Permission approval required"}]\n' \
  > "$TMP/blocked-claude-status.json"
BLOCKED_PROBE="$(CROSS_CLAUDE_STATE="$TMP/blocked-claude-status.json" PATH="$CROSS_BIN:$PATH" \
  _uberdev_agent_claude_probe abc12345)"
[ "$BLOCKED_PROBE" = 'blocked:permission' ] || {
  echo "Claude watcher did not classify idle/blocked permission state: $BLOCKED_PROBE" >&2
  exit 1
}
printf '[{"sessionId":"abc12345-full","state":"idle"}]\n' > "$TMP/idle-claude-status.json"
IDLE_PROBE="$(CROSS_CLAUDE_STATE="$TMP/idle-claude-status.json" PATH="$CROSS_BIN:$PATH" \
  _uberdev_agent_claude_probe abc12345)"
[ "$IDLE_PROBE" = 'blocked:permission' ] || {
  echo "Claude watcher did not classify idle as an actionable permission block: $IDLE_PROBE" >&2
  exit 1
}
if CROSS_CLAUDE_STATE="$TMP/ambiguous-claude-agents.json" PATH="$CROSS_BIN:$PATH" \
    _uberdev_dispatch_cancel_claude_bg abc12345 >/dev/null 2>&1; then
  echo 'Claude cancellation accepted a non-unique session prefix' >&2
  exit 1
fi

cross_backend_case() {
  backend="$1"
  run="$TMP/cross-$backend"
  mkdir -p "$run"
  printf 'cross-process prompt\n' > "$run/prompt.txt"
  request="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"cross-"+sys.argv[2],"repository_id":"cross-repository","backend":sys.argv[2],"workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":88,"issue_num":88,"capacity":1,"timeout_s":20},separators=(",",":")))' "$run" "$backend")"
  state="$run/.agent-state-$(id -u)"
  if [ "$backend" = claude-bg ]; then
    printf '[{"sessionId":"abc12345-full","state":"running"}]\n' > "$run/claude-agents.json"
  fi
  (
    CROSS_BACKEND="$backend" CROSS_RUN="$run" CROSS_CLAUDE_STATE="$run/claude-agents.json" \
      PATH="$CROSS_BIN:$PATH" uberdev_agent_dispatch "$request" "$run/prompt.txt" "$run/result.md" "$run/status.json"
  )
  [ -r "$run/status.json" ] && grep -q '"state":"running"' "$run/status.json" || {
    echo "$backend did not publish live canonical status" >&2; return 1;
  }
  if UBERDEV_SEMAPHORE_ACQUIRE_MAX_TRIES=1 \
      probe="$(uberdev_semaphore_acquire "$state" cross-repository "$backend" 1 "probe-live-$backend" 20 2>/dev/null)"; then
    uberdev_semaphore_release "$probe" >/dev/null 2>&1 || true
    echo "$backend released capacity while provider status was live" >&2
    return 1
  fi
  python3 -I "$ROOT/plugins/uberdev/lib/run_manifest.py" reconcile \
    --manifest "$state/agent-lifecycle.jsonl" >/dev/null
  if [ "$backend" = claude-bg ]; then
    printf '[{"sessionId":"abc12345-full","state":"completed"}]\n' > "$run/claude-agents.json"
  else
    tmp_status="$run/status.json.tmp"
    if [ "$backend" = wezterm ]; then
      printf '{"backend":"wezterm","state":"completed","exit_code":0}\n' > "$tmp_status"
    else
      printf '{"backend":"%s","state":"completed","exit_code":0}\n' \
        "$backend" > "$tmp_status"
    fi
    chmod 600 "$tmp_status"
    mv "$tmp_status" "$run/status.json"
  fi
  for _ in 1 2 3 4 5 6; do
    grep -q '"state":"completed"' "$run/status.json" 2>/dev/null \
      && ! grep -R -q "run_id=cross-$backend" "$state/semaphore-v1" 2>/dev/null \
      && break
    sleep 1
  done
  probe="$(uberdev_semaphore_acquire "$state" cross-repository "$backend" 1 "probe-terminal-$backend" 20)" || {
    echo "$backend did not recover capacity after terminal" >&2; return 1;
  }
  uberdev_semaphore_release "$probe"
  python3 -I - "$state/agent-lifecycle.jsonl" "$backend" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
actual = [event["event"] for event in events if event["run_id"] == "cross-" + sys.argv[2]]
assert actual == ["route_decided", "agent_started", "completed"], ("cross-" + sys.argv[2], actual)
PY
}

_uberdev_agent_dispatch_backend() {
  backend="$1"; status_path="$6"
  DISPATCH_LOG=""
  case "$backend" in
    claude-bg)
      DISPATCH_ID=abc12345
      if [ "${CROSS_CLAUDE_DROP_AFTER_LIVE:-0}" = 1 ]; then
        nohup bash -c 'sleep 0.5; printf "[]\\n" > "$1"' _ "$CROSS_CLAUDE_STATE" >/dev/null 2>&1 &
      elif [ -n "${CROSS_CLAUDE_TERMINAL_AFTER_LIVE:-}" ]; then
        nohup bash -c 'sleep 0.5; printf "[{\"sessionId\":\"abc12345-full\",\"state\":\"%s\"}]\\n" "$2" > "$1"' \
          _ "$CROSS_CLAUDE_STATE" "$CROSS_CLAUDE_TERMINAL_AFTER_LIVE" >/dev/null 2>&1 &
      fi
      ;;
    wezterm)
      DISPATCH_ID=777
      printf '{"backend":"wezterm","state":"running","exit_code":null,"pid":"pane"}\n' > "$status_path"
      chmod 600 "$status_path"
      ;;
    codex|background)
      nohup sleep 5 >/dev/null 2>&1 &
      DISPATCH_ID="$!"
      printf '{"backend":"%s","state":"running","exit_code":null,"pid":"%s"}\n' "$backend" "$DISPATCH_ID" > "$status_path"
      chmod 600 "$status_path"
      ;;
  esac
  DISPATCH_RC=0
  return 0
}

claude_watcher_case() {
  mode="$1"
  run="$TMP/claude-watch-$mode"
  mkdir -p "$run"
  printf 'claude watcher prompt\n' > "$run/prompt.txt"
  state="$run/.agent-state-$(id -u)"
  request="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"claude-watch-"+sys.argv[2],"repository_id":"claude-watch-repository","backend":"claude-bg","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":89,"issue_num":89,"capacity":1,"timeout_s":1},separators=(",",":")))' "$run" "$mode")"
  case "$mode" in
    initial-absent) printf '[]\n' > "$run/claude-agents.json" ;;
    live-then-absent|explicit-completed) printf '[{"sessionId":"abc12345-full","state":"running"}]\n' > "$run/claude-agents.json" ;;
    blocked) printf '[{"sessionId":"abc12345-full","state":"blocked","blockedReason":"Permission approval required"}]\n' > "$run/claude-agents.json" ;;
    provider-blocked) printf '[{"sessionId":"abc12345-full","state":"blocked","blockedReason":"Provider queue is paused"}]\n' > "$run/claude-agents.json" ;;
    idle) printf '[{"sessionId":"abc12345-full","state":"idle"}]\n' > "$run/claude-agents.json" ;;
    ambiguous) printf '[{"sessionId":"abc12345-one","state":"running"},{"sessionId":"abc12345-two","state":"completed"}]\n' > "$run/claude-agents.json" ;;
    probe-error) printf '{not-json\n' > "$run/claude-agents.json" ;;
  esac
  (
    sleep() { command sleep 0.1; }
    drop=0
    [ "$mode" != live-then-absent ] || drop=1
    explicit=''
    [ "$mode" != explicit-completed ] || explicit=completed
    CROSS_CLAUDE_DROP_AFTER_LIVE="$drop" CROSS_CLAUDE_TERMINAL_AFTER_LIVE="$explicit" \
      CROSS_CLAUDE_STATE="$run/claude-agents.json" \
      PATH="$CROSS_BIN:$PATH" uberdev_agent_dispatch "$request" \
        "$run/prompt.txt" "$run/result.md" "$run/status.json"
  )
  case "$mode" in
    initial-absent|live-then-absent|explicit-completed|blocked|provider-blocked|idle)
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        grep -Eq '"state":"(completed|failed)"' "$run/status.json" 2>/dev/null && break
        command sleep 0.1
      done
      ;;
    ambiguous)
      command sleep 0.6
      ;;
    probe-error)
      # Exceed request timeout_s. Unknown probe evidence must still retain the
      # live lease and may not synthesize a terminal.
      command sleep 1.3
      ;;
  esac
  case "$mode" in
    initial-absent)
      grep -q '"state":"failed"' "$run/status.json" || {
        echo "initial Claude absence did not fail closed" >&2; return 1;
      }
      wait_for_terminal_and_release "$state/agent-lifecycle.jsonl" "$state" claude-watch-initial-absent failed 80 0.1 || return 1
      python3 -I - "$state/agent-lifecycle.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
actual = [event["event"] for event in events if event["run_id"] == "claude-watch-initial-absent"]
assert actual == ["route_decided", "agent_started", "failed"], ("claude-watch-initial-absent", actual)
PY
      ;;
    live-then-absent)
      grep -q '"state":"failed"' "$run/status.json" || {
        echo "observed-live Claude disappearance fabricated success" >&2; return 1;
      }
      ;;
    explicit-completed)
      grep -q '"state":"completed"' "$run/status.json" || {
        echo "explicit Claude completion did not complete" >&2; return 1;
      }
      ;;
    blocked|provider-blocked|idle)
      grep -q '"state":"failed"' "$run/status.json" || {
        echo "$mode Claude session did not terminalize" >&2; return 1;
      }
      wait_for_terminal_and_release "$state/agent-lifecycle.jsonl" "$state" "claude-watch-$mode" failed 80 0.1 || return 1
      python3 -I - "$state/agent-lifecycle.jsonl" "$mode" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
terminal = [event for event in events if event.get("run_id") == "claude-watch-"+sys.argv[2] and event.get("event") == "failed"]
expected = "provider_blocked" if sys.argv[2] == "provider-blocked" else "provider_permission_blocked"
assert len(terminal) == 1 and terminal[0].get("error_class") == expected, terminal
PY
      ;;
    ambiguous|probe-error)
      python3 -I - "$run/status.json.watcher-error.json" <<'PY'
import json,sys
row=json.load(open(sys.argv[1]))
assert row['error']=='provider_probe_failed' and row['attempts']==3,row
PY
      grep -q '"state":"running"' "$run/status.json" || {
        echo "$mode Claude probe did not remain nonterminal" >&2; return 1;
      }
      if grep -Eq '"event":"(completed|failed|timed_out|cancelled|abandoned)"' "$state/agent-lifecycle.jsonl"; then
        echo "$mode Claude probe fabricated a terminal event" >&2
        return 1
      fi
      grep -R -q "run_id=claude-watch-$mode" "$state/semaphore-v1" || {
        echo "$mode Claude probe released live capacity" >&2; return 1;
      }
      rm -rf "$run"
      command sleep 0.2
      ;;
  esac
}

claude_watcher_case initial-absent
claude_watcher_case live-then-absent
claude_watcher_case explicit-completed
claude_watcher_case blocked
claude_watcher_case provider-blocked
claude_watcher_case idle
claude_watcher_case ambiguous
claude_watcher_case probe-error

claude_cancel_retry_case() {
  mode="$1"
  run="$TMP/claude-cancel-$mode"
  mkdir -p "$run"
  printf 'Claude cancellation retry prompt\n' > "$run/prompt.txt"
  printf '[{"sessionId":"abc12345-full","state":"blocked","blockedReason":"Permission approval required"}]\n' > "$run/claude-agents.json"
  request="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"claude-cancel-"+sys.argv[2],"repository_id":"claude-cancel-repository","backend":"claude-bg","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":94,"issue_num":94,"capacity":1,"timeout_s":20},separators=(",",":")))' "$run" "$mode")"
  (
    sleep() { command sleep 0.1; }
    CROSS_CLAUDE_STATE="$run/claude-agents.json" \
      CROSS_CLAUDE_STOP_MODE="$mode" CROSS_CLAUDE_STOP_COUNT="$run/stop-count" \
      CROSS_CLAUDE_PROBE_COUNT="$run/probe-count" \
      PATH="$CROSS_BIN:$PATH" uberdev_agent_dispatch "$request" \
        "$run/prompt.txt" "$run/result.md" "$run/status.json"
  )
  state="$run/.agent-state-$(id -u)"
  if [ "$mode" = once ]; then
    wait_for_terminal_and_release "$state/agent-lifecycle.jsonl" "$state" claude-cancel-once failed 80 0.1 || return 1
    [ "$(cat "$run/stop-count")" -ge 2 ] || { echo "transient Claude stop failure was not retried" >&2; return 1; }
    return 0
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    [ -s "$run/status.json.watcher-error.json" ] && break
    command sleep 0.1
  done
  python3 -I - "$run/status.json.watcher-error.json" "$mode" <<'PY'
import json,sys
row=json.load(open(sys.argv[1]))
expected='provider_stop_failed' if sys.argv[2]=='never' else 'provider_cancel_unconfirmed'
assert row['error']=='provider_cancel_failed' and row['attempts']==3 and row['reason']==expected,row
PY
  if [ "$mode" = delayed ]; then
    wait_for_terminal_and_release "$state/agent-lifecycle.jsonl" "$state" claude-cancel-delayed cancelled 80 0.1 || return 1
    [ "$(cat "$run/stop-count")" -eq 1 ] || {
      echo "delayed Claude convergence reissued provider stop" >&2; return 1;
    }
    return 0
  fi
  stop_count="$(cat "$run/stop-count")"
  command sleep 0.5
  [ "$(cat "$run/stop-count")" = "$stop_count" ] || {
    echo "durable Claude cancellation failure reissued provider stop" >&2; return 1;
  }
  grep -q '"state":"running"' "$run/status.json" || { echo "failed Claude stop fabricated a terminal" >&2; return 1; }
  grep -R -q "run_id=claude-cancel-$mode" "$state/semaphore-v1" || { echo "failed Claude stop abandoned its lease" >&2; return 1; }
  rm -rf "$run"
  command sleep 0.2
}

claude_cancel_retry_case once
claude_cancel_retry_case delayed
claude_cancel_retry_case never
claude_cancel_retry_case sticky

# If both durable probe-error persistence and provider cancellation fail, the
# watcher must retry both parent-observable operations instead of marking the
# supervision failure as already reported after the first lost attempt.
claude_probe_persistence_retry_case() {
  local run="$TMP/claude-probe-persistence-retry" state request
  mkdir -p "$run"
  printf 'Claude probe persistence retry prompt\n' >"$run/prompt.txt"
  printf '{not-json\n' >"$run/claude-agents.json"
  request="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"claude-probe-persistence-retry","repository_id":"claude-probe-persistence-retry-repository","backend":"claude-bg","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":95,"issue_num":95,"capacity":1,"timeout_s":20},separators=(",",":")))' "$run")"
  (
    sleep() { command sleep 0.05; }
    eval "$(declare -f _uberdev_agent_persist_watcher_error_retry | sed '1s/_uberdev_agent_persist_watcher_error_retry/_real_probe_persist_retry/')"
    _uberdev_agent_persist_watcher_error_retry() {
      local count=0
      [ ! -r "$run/persist-count" ] || read -r count <"$run/persist-count"
      count=$((count + 1)); printf '%s\n' "$count" >"$run/persist-count"
      [ "$count" -ge 3 ] || return 29
      _real_probe_persist_retry "$@"
    }
    _uberdev_dispatch_cancel_backend() {
      local count=0
      [ ! -r "$run/cancel-count" ] || read -r count <"$run/cancel-count"
      printf '%s\n' $((count + 1)) >"$run/cancel-count"
      return 31
    }
    CROSS_CLAUDE_STATE="$run/claude-agents.json" PATH="$CROSS_BIN:$PATH" \
      uberdev_agent_dispatch "$request" "$run/prompt.txt" "$run/result.md" "$run/status.json"
  )
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$run/status.json.watcher-error.json" ] && break
    command sleep 0.1
  done
  [ "$(cat "$run/persist-count")" -ge 3 ]
  [ "$(cat "$run/cancel-count")" -ge 3 ]
  grep -q '"state":"running"' "$run/status.json"
  state="$run/.agent-state-$(id -u)"
  grep -R -q 'run_id=claude-probe-persistence-retry' "$state/semaphore-v1"
  rm -rf "$run"
  command sleep 0.2
}

claude_probe_persistence_retry_case

cross_backend_case codex
cross_backend_case background
cross_backend_case claude-bg
cross_backend_case wezterm

# A numeric provider that disappears before publishing a terminal snapshot is
# failed coherently: status, manifest, and capacity must agree.
DEAD_RUN="$TMP/dead-without-terminal"
mkdir -p "$DEAD_RUN"
printf 'dead provider prompt\n' > "$DEAD_RUN/prompt.txt"
DEAD_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-dead-without-terminal","repository_id":"adapter-death-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":91,"issue_num":91,"capacity":1,"timeout_s":20},separators=(",",":")))' "$DEAD_RUN")"
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,time; os.setsid(); time.sleep(1)' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" > "$6"
  chmod 600 "$6"
}
uberdev_agent_dispatch "$DEAD_REQUEST" "$DEAD_RUN/prompt.txt" "$DEAD_RUN/result.md" "$DEAD_RUN/status.json"
for _ in 1 2 3 4 5 6; do
  grep -q '"state":"failed"' "$DEAD_RUN/status.json" 2>/dev/null && break
  sleep 1
done
grep -q '"state":"failed"' "$DEAD_RUN/status.json" || { echo "dead provider retained running status" >&2; exit 1; }
python3 -I - "$DEAD_RUN/.agent-state-$(id -u)/agent-lifecycle.jsonl" <<'PY'
import json,pathlib,sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines()]
terminal=[x for x in rows if x.get('run_id')=='adapter-dead-without-terminal' and x.get('event')=='failed']
assert len(terminal)==1 and terminal[0].get('error_class')=='provider_execution_failed',terminal
PY
! grep -R -q 'run_id=adapter-dead-without-terminal' "$DEAD_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null

# Killing only the detached wrapper must not orphan its provider descendant or
# release capacity. The watcher preserves launch identity, terminates the exact
# owned process group, then publishes one failed lifecycle and releases the
# exact lease.
ORPHAN_RUN="$TMP/wrapper-death-with-live-provider"
mkdir -p "$ORPHAN_RUN"
printf 'wrapper death prompt\n' >"$ORPHAN_RUN/prompt.txt"
ORPHAN_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-wrapper-death","repository_id":"adapter-wrapper-death-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":99,"issue_num":99,"capacity":1,"timeout_s":20},separators=(",",":")))' "$ORPHAN_RUN")"
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,sys; os.setsid(); os.execvp("bash",["bash","-c","sleep 30 & echo $! > \"$1\"; wait","_",sys.argv[1]])' \
    "$ORPHAN_RUN/provider-child.pid" >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"
  printf '%s\n' "$DISPATCH_ID" >"$ORPHAN_RUN/wrapper.pid"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" >"$6"
  chmod 600 "$6"
}
uberdev_agent_dispatch "$ORPHAN_REQUEST" "$ORPHAN_RUN/prompt.txt" "$ORPHAN_RUN/result.md" "$ORPHAN_RUN/status.json"
ORPHAN_WRAPPER="$(cat "$ORPHAN_RUN/wrapper.pid")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$ORPHAN_RUN/provider-child.pid" ] && break; sleep .1; done
ORPHAN_CHILD="$(cat "$ORPHAN_RUN/provider-child.pid")"
kill -KILL "$ORPHAN_WRAPPER"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"state":"failed"' "$ORPHAN_RUN/status.json" 2>/dev/null && break
  sleep 1
done
grep -q '"state":"failed"' "$ORPHAN_RUN/status.json"
! _uberdev_dispatch_group_live "$ORPHAN_WRAPPER"
! kill -0 "$ORPHAN_CHILD" 2>/dev/null
python3 -I - "$ORPHAN_RUN/.agent-state-$(id -u)/agent-lifecycle.jsonl" <<'PY'
import json,pathlib,sys
rows=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
events=[row for row in rows if row.get('run_id')=='adapter-wrapper-death']
assert [row.get('event') for row in events]==['route_decided','agent_started','failed'],events
assert events[-1].get('error_class')=='provider_execution_failed',events[-1]
PY
! grep -R -q 'run_id=adapter-wrapper-death' "$ORPHAN_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null

# Before provider launch, exact-identity registration failure must reconcile a
# terminal and release only the generation acquired for this request.
. "$ROOT/plugins/uberdev/lib/dispatch.sh"
PRE_RUN="$TMP/pre-launch-identity-failure"
mkdir -p "$PRE_RUN"
printf 'pre-launch failure prompt\n' > "$PRE_RUN/prompt.txt"
PRE_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-pre-launch-identity-failure","repository_id":"adapter-prelaunch-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":95,"issue_num":95,"capacity":1,"timeout_s":20},separators=(",",":")))' "$PRE_RUN")"
eval "$(declare -f uberdev_semaphore_set_handle | sed '1s/uberdev_semaphore_set_handle/_real_prelaunch_set_handle/')"
uberdev_semaphore_set_handle() { return 23; }
rm -f "$PRE_RUN/provider-called"
_uberdev_agent_dispatch_backend() { : > "$PRE_RUN/provider-called"; return 0; }
if uberdev_agent_dispatch "$PRE_REQUEST" "$PRE_RUN/prompt.txt" "$PRE_RUN/result.md" "$PRE_RUN/status.json"; then
  echo "pre-launch identity failure was reported as success" >&2; exit 1
fi
[ ! -e "$PRE_RUN/provider-called" ] || { echo "pre-launch identity failure reached the provider seam" >&2; exit 1; }
grep -q '"state":"failed"' "$PRE_RUN/status.json"
python3 -I - "$PRE_RUN/.agent-state-$(id -u)/agent-lifecycle.jsonl" <<'PY'
import json,pathlib,sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines()]
terminal=[x for x in rows if x.get('run_id')=='adapter-pre-launch-identity-failure' and x.get('event')=='failed']
assert len(terminal)==1 and terminal[0].get('error_class')=='dispatch_setup_failed',terminal
PY
! grep -R -q 'run_id=adapter-pre-launch-identity-failure' "$PRE_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null
eval "$(declare -f _real_prelaunch_set_handle | sed '1s/_real_prelaunch_set_handle/uberdev_semaphore_set_handle/')"
PRE_REACQUIRED="$(uberdev_semaphore_acquire "$PRE_RUN/.agent-state-$(id -u)" adapter-prelaunch-repository codex 1 adapter-prelaunch-reacquired 20)"
uberdev_semaphore_release "$PRE_REACQUIRED"

# Event construction and manifest persistence fail before provider launch. The
# rollback must retry transient failures, publish one failed lifecycle, and
# release only the exact captured lease identity. If that exact release also
# fails, capacity stays fail-closed and sidecar persistence is retried.
eval "$(declare -f _uberdev_agent_event_json | sed '1s/_uberdev_agent_event_json/_real_prelaunch_event_json/')"
eval "$(declare -f _uberdev_agent_append_event | sed '1s/_uberdev_agent_append_event/_real_prelaunch_append_event/')"
eval "$(declare -f _uberdev_agent_release_exact_lease | sed '1s/_uberdev_agent_release_exact_lease/_real_prelaunch_exact_release/')"
eval "$(declare -f _uberdev_agent_persist_watcher_error | sed '1s/_uberdev_agent_persist_watcher_error/_real_prelaunch_persist_error/')"
eval "$(declare -f uberdev_semaphore_release | sed '1s/uberdev_semaphore_release/_real_prelaunch_generic_release/')"
PRE_EVENT_MODE=''
PRE_EVENT_COUNTER=''
PRE_RELEASE_COUNTER=''
PRE_SIDECAR_COUNTER=''
_uberdev_agent_event_json() {
  if [ "$PRE_EVENT_MODE" = event_json ] && [ "$1" = agent_started ] && [ ! -e "$PRE_EVENT_COUNTER" ]; then
    : >"$PRE_EVENT_COUNTER"
    return 29
  fi
  _real_prelaunch_event_json "$@"
}
_uberdev_agent_append_event() {
  if [ "$PRE_EVENT_MODE" = append_once ] && [[ "$2" == *'"event":"agent_started"'* ]] \
      && [ ! -e "$PRE_EVENT_COUNTER" ]; then
    : >"$PRE_EVENT_COUNTER"
    return 29
  fi
  if { [ "$PRE_EVENT_MODE" = append_always ] || [ "$PRE_EVENT_MODE" = append_release ]; } \
      && [[ "$2" == *'"event":"agent_started"'* ]]; then
    return 29
  fi
  _real_prelaunch_append_event "$@"
}
_uberdev_agent_release_exact_lease() {
  local count
  if [ "$PRE_EVENT_MODE" = append_release ]; then
    count=0; [ ! -r "$PRE_RELEASE_COUNTER" ] || read -r count < "$PRE_RELEASE_COUNTER"
    printf '%s\n' $((count + 1)) > "$PRE_RELEASE_COUNTER"
    return 29
  fi
  _real_prelaunch_exact_release "$@"
}
_uberdev_agent_persist_watcher_error() {
  local count
  if [ "$PRE_EVENT_MODE" = append_release ]; then
    count=0; [ ! -r "$PRE_SIDECAR_COUNTER" ] || read -r count < "$PRE_SIDECAR_COUNTER"
    count=$((count + 1)); printf '%s\n' "$count" > "$PRE_SIDECAR_COUNTER"
    [ "$count" -ge 3 ] || return 29
  fi
  _real_prelaunch_persist_error "$@"
}
uberdev_semaphore_release() { return 88; }

prelaunch_event_failure_case() {
  local mode="$1" suffix="$2" run request rc state manifest sidecar terminals
  run="$TMP/pre-launch-event-$suffix"
  mkdir -p "$run"
  printf 'pre-launch event failure prompt\n' >"$run/prompt.txt"
  request="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-prelaunch-event-"+sys.argv[2],"repository_id":"adapter-prelaunch-event-repository-"+sys.argv[2],"backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":96,"issue_num":96,"capacity":1,"timeout_s":20},separators=(",",":")))' "$run" "$suffix")"
  PRE_EVENT_MODE="$mode"
  PRE_EVENT_COUNTER="$run/failure-injected"
  PRE_RELEASE_COUNTER="$run/release-attempts"
  PRE_SIDECAR_COUNTER="$run/sidecar-attempts"
  rm -f "$PRE_EVENT_COUNTER" "$PRE_RELEASE_COUNTER" "$PRE_SIDECAR_COUNTER" "$run/provider-called"
  _uberdev_agent_dispatch_backend() { : >"$run/provider-called"; return 0; }
  set +e
  uberdev_agent_dispatch "$request" "$run/prompt.txt" "$run/result.md" "$run/status.json"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { echo "pre-launch $mode failure returned rc=$rc" >&2; return 1; }
  [ ! -e "$run/provider-called" ] || { echo "pre-launch $mode failure reached provider" >&2; return 1; }
  grep -q '"state":"failed"' "$run/status.json"
  state="$run/.agent-state-$(id -u)"
  manifest="$state/agent-lifecycle.jsonl"
  if [ "$mode" = append_release ]; then
    grep -R -q "run_id=adapter-prelaunch-event-$suffix" "$state/semaphore-v1"
    [ "$(cat "$PRE_RELEASE_COUNTER")" -eq 3 ]
    [ "$(cat "$PRE_SIDECAR_COUNTER")" -eq 3 ]
  else
    ! grep -R -q "run_id=adapter-prelaunch-event-$suffix" "$state/semaphore-v1" 2>/dev/null
  fi
  if [ "$mode" = append_always ] || [ "$mode" = append_release ]; then
    sidecar="$run/status.json.watcher-error.json"
    [ -f "$sidecar" ] || sidecar="$state/adapter-prelaunch-event-$suffix.watcher-error.json"
    python3 -I - "$sidecar" <<'PY'
import json,sys
row=json.load(open(sys.argv[1]))
assert row['error']=='launch_finalize_failed' and row['handle']=='' and row['attempts']==3,row
PY
  else
    terminals="$(python3 -I - "$manifest" "$suffix" <<'PY'
import json,pathlib,sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines()]
run_id='adapter-prelaunch-event-'+sys.argv[2]
events=[x.get('event') for x in rows if x.get('run_id')==run_id]
assert events==['route_decided','agent_started','failed'],events
print(events.count('failed'),end='')
PY
)"
    [ "$terminals" = 1 ]
  fi
}

prelaunch_event_failure_case event_json event-json
prelaunch_event_failure_case append_once append-once
prelaunch_event_failure_case append_always append-always
prelaunch_event_failure_case append_release append-release
eval "$(declare -f _real_prelaunch_event_json | sed '1s/_real_prelaunch_event_json/_uberdev_agent_event_json/')"
eval "$(declare -f _real_prelaunch_append_event | sed '1s/_real_prelaunch_append_event/_uberdev_agent_append_event/')"
eval "$(declare -f _real_prelaunch_exact_release | sed '1s/_real_prelaunch_exact_release/_uberdev_agent_release_exact_lease/')"
eval "$(declare -f _real_prelaunch_persist_error | sed '1s/_real_prelaunch_persist_error/_uberdev_agent_persist_watcher_error/')"
eval "$(declare -f _real_prelaunch_generic_release | sed '1s/_real_prelaunch_generic_release/uberdev_semaphore_release/')"
PRE_EVENT_REACQUIRED="$(uberdev_semaphore_acquire "$TMP/pre-launch-event-append-always/.agent-state-$(id -u)" adapter-prelaunch-event-repository-append-always codex 1 adapter-prelaunch-event-reacquired 20)"
uberdev_semaphore_release "$PRE_EVENT_REACQUIRED"

# Once launch succeeds, a failure to bind the exact handle must cancel that
# provider and reconcile a terminal instead of returning an unowned child.
POST_RUN="$TMP/post-launch-setup-failure"
mkdir -p "$POST_RUN"
printf 'post-launch failure prompt\n' > "$POST_RUN/prompt.txt"
POST_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-post-launch-failure","repository_id":"adapter-postlaunch-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":92,"issue_num":92,"capacity":1,"timeout_s":20},separators=(",",":")))' "$POST_RUN")"
eval "$(declare -f uberdev_semaphore_set_handle | sed '1s/uberdev_semaphore_set_handle/_real_postlaunch_set_handle/')"
POST_SET_CALLS_FILE="$POST_RUN/set-handle-calls"
printf '0\n' > "$POST_SET_CALLS_FILE"
uberdev_semaphore_set_handle() {
  POST_SET_CALLS="$(cat "$POST_SET_CALLS_FILE")"
  POST_SET_CALLS=$((POST_SET_CALLS + 1))
  printf '%s\n' "$POST_SET_CALLS" > "$POST_SET_CALLS_FILE"
  [ "$POST_SET_CALLS" -ne 2 ] || return 23
  _real_postlaunch_set_handle "$@"
}
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,time; os.setsid(); time.sleep(30)' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""; printf '%s\n' "$DISPATCH_ID" > "$POST_RUN/provider.pid"
  _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" > "$6"
  chmod 600 "$6"
}
if uberdev_agent_dispatch "$POST_REQUEST" "$POST_RUN/prompt.txt" "$POST_RUN/result.md" "$POST_RUN/status.json"; then
  echo "post-launch setup failure was reported as success" >&2; exit 1
fi
POST_PID="$(cat "$POST_RUN/provider.pid")"
for _ in 1 2 3 4 5; do kill -0 "$POST_PID" 2>/dev/null || break; sleep .1; done
wait "$POST_PID" 2>/dev/null || true
kill -0 "$POST_PID" 2>/dev/null && { echo "post-launch setup failure orphaned provider $POST_PID" >&2; exit 1; }
grep -q '"state":"failed"' "$POST_RUN/status.json"
! grep -R -q 'run_id=adapter-post-launch-failure' "$POST_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null
eval "$(declare -f _real_postlaunch_set_handle | sed '1s/_real_postlaunch_set_handle/uberdev_semaphore_set_handle/')"

# A nonterminal numeric backend must not be registered without a verified
# process identity. A transient capture failure fails dispatch and the cleanup
# path retries the identity probe before cancelling the exact provider.
IDENTITY_RUN="$TMP/post-launch-process-identity-failure"
mkdir -p "$IDENTITY_RUN"
printf 'process identity failure prompt\n' >"$IDENTITY_RUN/prompt.txt"
IDENTITY_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-process-identity-failure","repository_id":"adapter-process-identity-failure-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":96,"issue_num":96,"capacity":1,"timeout_s":20},separators=(",",":")))' "$IDENTITY_RUN")"
eval "$(declare -f _uberdev_agent_process_identity | sed '1s/_uberdev_agent_process_identity/_real_agent_process_identity/')"
printf '0\n' >"$IDENTITY_RUN/identity-probes"
_uberdev_agent_process_identity() {
  identity_provider_pid="$(cat "$IDENTITY_RUN/provider.pid" 2>/dev/null || true)"
  if [ -f "$IDENTITY_RUN/identity-capture-armed" ] \
      && [ -n "$identity_provider_pid" ] && [ "$1" = "$identity_provider_pid" ]; then
    identity_probes="$(cat "$IDENTITY_RUN/identity-probes")"
    identity_probes=$((identity_probes + 1))
    printf '%s\n' "$identity_probes" >"$IDENTITY_RUN/identity-probes"
    [ "$identity_probes" -ne 1 ] || return 2
  fi
  _real_agent_process_identity "$@"
}
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,time; os.setsid(); time.sleep(30)' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  printf '%s\n' "$DISPATCH_ID" >"$IDENTITY_RUN/provider.pid"
  _uberdev_dispatch_wait_owned_session "$DISPATCH_ID"
  : >"$IDENTITY_RUN/identity-capture-armed"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" >"$6"
  chmod 600 "$6"
}
set +e
uberdev_agent_dispatch "$IDENTITY_REQUEST" "$IDENTITY_RUN/prompt.txt" \
  "$IDENTITY_RUN/result.md" "$IDENTITY_RUN/status.json"
identity_dispatch_rc=$?
set -e
eval "$(declare -f _real_agent_process_identity | sed '1s/_real_agent_process_identity/_uberdev_agent_process_identity/')"
IDENTITY_PID="$(cat "$IDENTITY_RUN/provider.pid")"
if [ "$identity_dispatch_rc" -eq 0 ]; then
  kill "$IDENTITY_PID" 2>/dev/null || true
fi
for _ in 1 2 3 4 5; do kill -0 "$IDENTITY_PID" 2>/dev/null || break; sleep .1; done
wait "$IDENTITY_PID" 2>/dev/null || true
if [ "$identity_dispatch_rc" -eq 0 ] || kill -0 "$IDENTITY_PID" 2>/dev/null \
    || ! grep -q '"state":"failed"' "$IDENTITY_RUN/status.json" \
    || grep -R -q 'run_id=adapter-process-identity-failure' "$IDENTITY_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null; then
  identity_provider_live=0
  kill -0 "$IDENTITY_PID" 2>/dev/null && identity_provider_live=1
  identity_status="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$IDENTITY_RUN/status.json" 2>/dev/null || true)"
  identity_lease_count="$(find "$IDENTITY_RUN/.agent-state-$(id -u)/semaphore-v1" -name '*.lease' -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "numeric backend identity-capture failure was not closed coherently: rc=$identity_dispatch_rc live=$identity_provider_live status=${identity_status:-missing} leases=$identity_lease_count probes=$(cat "$IDENTITY_RUN/identity-probes")" >&2
  exit 1
fi

# A provider can return a handle and then exit before rollback samples process
# identity. Proven absence still terminalizes the run and releases its lease.
EXITED_RUN="$TMP/post-launch-provider-already-exited"
mkdir -p "$EXITED_RUN"
printf 'already exited provider prompt\n' >"$EXITED_RUN/prompt.txt"
EXITED_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-postlaunch-provider-already-exited","repository_id":"adapter-postlaunch-provider-already-exited-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":98,"issue_num":98,"capacity":1,"timeout_s":20},separators=(",",":")))' "$EXITED_RUN")"
_uberdev_agent_dispatch_backend() {
  python3 -I -c 'import os; os.setsid()' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  wait "$DISPATCH_ID"
  return 19
}
if uberdev_agent_dispatch "$EXITED_REQUEST" "$EXITED_RUN/prompt.txt" \
    "$EXITED_RUN/result.md" "$EXITED_RUN/status.json"; then
  echo "already-exited post-launch provider was reported as success" >&2; exit 1
fi
grep -q '"state":"failed"' "$EXITED_RUN/status.json"
python3 -I - "$EXITED_RUN/.agent-state-$(id -u)/agent-lifecycle.jsonl" <<'PY'
import json,pathlib,sys
rows=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
events=[row for row in rows if row.get('run_id')=='adapter-postlaunch-provider-already-exited']
assert [row.get('event') for row in events]==['route_decided','agent_started','failed'],events
assert events[-1].get('error_class')=='dispatch_setup_failed',events[-1]
PY
! grep -R -q 'run_id=adapter-postlaunch-provider-already-exited' \
  "$EXITED_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null

# Exercise the real atomic handle replacement failure path. The semaphore
# publishes a replacement inode, exact-identity validation then fails, and the
# injected rollback removal fails once. Dispatcher cleanup must consume the
# returned replacement capability, cancel the provider, and make cap=1
# immediately reacquirable.
REPLACEMENT_RUN="$TMP/post-launch-replacement-capability"
mkdir -p "$REPLACEMENT_RUN"
printf 'replacement capability prompt\n' > "$REPLACEMENT_RUN/prompt.txt"
REPLACEMENT_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-postlaunch-replacement","repository_id":"adapter-postlaunch-replacement-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":97,"issue_num":97,"capacity":1,"timeout_s":20},separators=(",",":")))' "$REPLACEMENT_RUN")"
eval "$(declare -f _uberdev_semaphore_path_identity | sed '1s/_uberdev_semaphore_path_identity/_real_replacement_path_identity/')"
eval "$(declare -f _uberdev_semaphore_remove_lease | sed '1s/_uberdev_semaphore_remove_lease/_real_replacement_remove_lease/')"
_uberdev_semaphore_path_identity() {
  case "$1" in
    *.lease)
      if [ -e "$REPLACEMENT_RUN/provider-launched" ] && [ ! -e "$REPLACEMENT_RUN/identity-failed" ]; then
        : > "$REPLACEMENT_RUN/identity-failed"
        return 29
      fi
      ;;
  esac
  _real_replacement_path_identity "$@"
}
_uberdev_semaphore_remove_lease() {
  if [ -e "$REPLACEMENT_RUN/identity-failed" ] && [ ! -e "$REPLACEMENT_RUN/rollback-failed" ]; then
    : > "$REPLACEMENT_RUN/rollback-failed"
    return 31
  fi
  _real_replacement_remove_lease "$@"
}
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,time; os.setsid(); time.sleep(30)' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  printf '%s\n' "$DISPATCH_ID" > "$REPLACEMENT_RUN/provider.pid"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" > "$6"
  chmod 600 "$6"
  : > "$REPLACEMENT_RUN/provider-launched"
}
if uberdev_agent_dispatch "$REPLACEMENT_REQUEST" "$REPLACEMENT_RUN/prompt.txt" \
    "$REPLACEMENT_RUN/result.md" "$REPLACEMENT_RUN/status.json"; then
  echo "replacement-capability failure was reported as success" >&2; exit 1
fi
REPLACEMENT_PID="$(cat "$REPLACEMENT_RUN/provider.pid")"
for _ in 1 2 3 4 5; do kill -0 "$REPLACEMENT_PID" 2>/dev/null || break; sleep .1; done
wait "$REPLACEMENT_PID" 2>/dev/null || true
kill -0 "$REPLACEMENT_PID" 2>/dev/null && {
  echo "replacement-capability cleanup orphaned provider $REPLACEMENT_PID" >&2; exit 1;
}
[ -e "$REPLACEMENT_RUN/identity-failed" ] && [ -e "$REPLACEMENT_RUN/rollback-failed" ]
! grep -R -q 'run_id=adapter-postlaunch-replacement' \
  "$REPLACEMENT_RUN/.agent-state-$(id -u)/semaphore-v1" 2>/dev/null
REPLACEMENT_REACQUIRED="$(uberdev_semaphore_acquire \
  "$REPLACEMENT_RUN/.agent-state-$(id -u)" adapter-postlaunch-replacement-repository \
  codex 1 adapter-postlaunch-replacement-reacquired 20)"
uberdev_semaphore_release "$REPLACEMENT_REACQUIRED"
eval "$(declare -f _real_replacement_path_identity | sed '1s/_real_replacement_path_identity/_uberdev_semaphore_path_identity/')"
eval "$(declare -f _real_replacement_remove_lease | sed '1s/_real_replacement_remove_lease/_uberdev_semaphore_remove_lease/')"

# A detached watcher finalization failure is durable and visible; it may not be
# redirected away while the lease silently remains live.
WATCH_RUN="$TMP/watcher-finalize-failure"
mkdir -p "$WATCH_RUN"
printf 'watcher failure prompt\n' > "$WATCH_RUN/prompt.txt"
WATCH_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-watcher-finalize-failure","repository_id":"adapter-watcher-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":93,"issue_num":93,"capacity":1,"timeout_s":20},separators=(",",":")))' "$WATCH_RUN")"
eval "$(declare -f _uberdev_agent_finalize_terminal | sed '1s/_uberdev_agent_finalize_terminal/_real_watcher_finalize_terminal/')"
_uberdev_agent_finalize_terminal() { return 29; }
_uberdev_agent_dispatch_backend() {
  nohup python3 -I -c 'import os,time; os.setsid(); time.sleep(5)' >/dev/null 2>&1 &
  DISPATCH_ID="$!"; DISPATCH_LOG=""
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$DISPATCH_ID" > "$6"; chmod 600 "$6"
  nohup bash -c 'sleep 1; printf '\''{"backend":"codex","state":"completed","exit_code":0,"pid":"%s"}\\n'\'' "$1" > "$2"; chmod 600 "$2"' _ "$DISPATCH_ID" "$6" >/dev/null 2>&1 &
}
uberdev_agent_dispatch "$WATCH_REQUEST" "$WATCH_RUN/prompt.txt" "$WATCH_RUN/result.md" "$WATCH_RUN/status.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WATCH_RUN/status.json.watcher-error.json" ] && break; sleep 1; done
python3 -I - "$WATCH_RUN/status.json.watcher-error.json" <<'PY'
import json,sys
row=json.load(open(sys.argv[1]))
assert row['error']=='terminal_finalize_failed' and row['attempts']==3,row
PY
eval "$(declare -f _real_watcher_finalize_terminal | sed '1s/_real_watcher_finalize_terminal/_uberdev_agent_finalize_terminal/')"

# Deterministic watcher/reconciler race: pause watcher registration, publish a
# canonical terminal, let manifest reconciliation consume it first, then run
# adapter finalization. The manifest keeps one true terminal and the exact
# dev:ino:generation lease is still released.
RACE_RUN="$TMP/reconcile-wins"
mkdir -p "$RACE_RUN"
printf 'reconcile race prompt\n' > "$RACE_RUN/prompt.txt"
RACE_REQUEST="$(python3 -I -c 'import json,sys; print(json.dumps({"schema_version":1,"run_dir":sys.argv[1],"run_id":"adapter-reconcile-wins","repository_id":"adapter-race-repository","backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"routing_mode":"inherit","issue_or_pr":90,"issue_num":90,"capacity":1,"timeout_s":20},separators=(",",":")))' "$RACE_RUN")"
_uberdev_agent_dispatch_backend() {
  DISPATCH_ID="opaque:race-handle"
  DISPATCH_LOG=""
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"opaque:race-handle"}\n' > "$6"
  chmod 600 "$6"
  DISPATCH_RC=0
  return 0
}
_uberdev_agent_start_watcher() {
  RACE_MANIFEST="$1"
  RACE_LEASE="$2"
  RACE_LEASE_IDENTITY="$3"
  RACE_STATUS="$4"
  RACE_BACKEND="$5"
  RACE_HANDLE="$6"
  RACE_REQUEST_CAPTURE="$7"
  RACE_DECISION="$8"
}
uberdev_agent_dispatch "$RACE_REQUEST" "$RACE_RUN/prompt.txt" "$RACE_RUN/result.md" "$RACE_RUN/status.json"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"opaque:race-handle"}\n' > "$RACE_RUN/status.json"
python3 -I "$ROOT/plugins/uberdev/lib/run_manifest.py" reconcile --manifest "$RACE_MANIFEST" >/dev/null
_uberdev_agent_finalize_terminal "$RACE_MANIFEST" "$RACE_LEASE" "$RACE_LEASE_IDENTITY" \
  "$RACE_STATUS" "$RACE_BACKEND" "$RACE_HANDLE" "$RACE_REQUEST_CAPTURE" "$RACE_DECISION" completed
python3 -I - "$RACE_MANIFEST" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
actual = [event["event"] for event in events if event["run_id"] == "adapter-reconcile-wins"]
assert actual == ["route_decided", "agent_started", "completed"], ("adapter-reconcile-wins", actual)
assert all(event["event"] != "abandoned" for event in events if event["run_id"] == "adapter-reconcile-wins")
PY
[ ! -e "$RACE_LEASE" ] || { echo "reconcile-winning watcher retained its exact lease" >&2; exit 1; }

echo "agent-dispatch: PASS"
