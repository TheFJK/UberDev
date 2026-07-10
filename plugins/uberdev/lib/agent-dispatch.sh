#!/usr/bin/env bash
# Instrumented detached-agent dispatch adapter (RFC 0013).
#
# Public API:
#   uberdev_agent_dispatch REQUEST_JSON PROMPT_FILE RESULT_FILE STATUS_FILE
#
# The caller supplies one provider boundary named
# `_uberdev_agent_dispatch_backend`.  lib/dispatch.sh owns the production
# boundary; tests replace it with a provider stub.  This file owns route
# resolution, lifecycle publication, and capacity leases, so provider arms can
# remain focused on preserving their existing launch semantics.

if [ "${_UBERDEV_AGENT_DISPATCH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

_uberdev_agent_dispatch_source_path() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    return 1
  fi
}

_UBERDEV_AGENT_DISPATCH_FILE="$(_uberdev_agent_dispatch_source_path)" || return 1
case "$_UBERDEV_AGENT_DISPATCH_FILE" in
  */*) _UBERDEV_AGENT_DISPATCH_DIR="${_UBERDEV_AGENT_DISPATCH_FILE%/*}" ;;
  *) _UBERDEV_AGENT_DISPATCH_DIR='.' ;;
esac
_UBERDEV_AGENT_DISPATCH_DIR="$(cd "$_UBERDEV_AGENT_DISPATCH_DIR" 2>/dev/null && pwd -P)" || return 1
_UBERDEV_AGENT_DISPATCH_ROOT="$(cd "$_UBERDEV_AGENT_DISPATCH_DIR/.." 2>/dev/null && pwd -P)" || return 1
_UBERDEV_AGENT_ROUTER="$_UBERDEV_AGENT_DISPATCH_DIR/model_routing.py"
_UBERDEV_AGENT_MANIFEST_TOOL="$_UBERDEV_AGENT_DISPATCH_DIR/run_manifest.py"
_UBERDEV_AGENT_POLICY="$_UBERDEV_AGENT_DISPATCH_ROOT/policy/model-routing-v1.json"

# shellcheck source=/dev/null
. "$_UBERDEV_AGENT_DISPATCH_DIR/live-semaphore.sh" || return 1
_UBERDEV_AGENT_DISPATCH_LOADED=1

# live-semaphore.sh is shared with standalone Bash callers and discovers its
# sibling through BASH_SOURCE. Pin the already-canonical adapter sibling so
# clean zsh execution does not resolve that helper relative to the caller cwd.
_uberdev_semaphore_manifest_tool() {
  printf '%s\n' "$_UBERDEV_AGENT_MANIFEST_TOOL"
}

_uberdev_agent_error() {
  printf 'uberdev agent dispatch: %s\n' "$1" >&2
}

_uberdev_agent_json_get() {
  local raw="$1" key="$2"
  python3 -I -c '
import json, sys
try:
    value = json.loads(sys.argv[1])
    for key in sys.argv[2].split("."):
        value = value[key]
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(3)
if value is None:
    raise SystemExit(3)
if isinstance(value, bool):
    print("true" if value else "false", end="")
elif isinstance(value, (str, int)) and not isinstance(value, bool):
    text = str(value)
    if not text or any(ch in text for ch in ("\r", "\n", "\0")):
        raise SystemExit(2)
    print(text, end="")
else:
    raise SystemExit(2)
' "$raw" "$key"
}

_uberdev_agent_validate_run_dir() {
  python3 -I -c '
import os, stat, sys
path = os.path.abspath(sys.argv[1])
if not os.path.isabs(sys.argv[1]) or not os.path.isdir(path):
    raise SystemExit(2)
resolved = os.path.realpath(path)
entry = os.stat(resolved)
if not stat.S_ISDIR(entry.st_mode):
    raise SystemExit(2)
print(resolved, end="")
' "$1"
}

_uberdev_agent_validate_paths() {
  local run_dir="$1" state_root="$2" prompt_arg="$3" result_arg="$4" status_arg="$5"
  python3 -I -c '
import json, os, stat, sys
run_dir, state_root, *requested = sys.argv[1:]
run_dir = os.path.realpath(run_dir)
state_lexical = os.path.abspath(state_root)
state_canonical = os.path.realpath(state_root)

def beneath(root, path):
    try:
        return os.path.commonpath((root, path)) == root
    except ValueError:
        return False

def inspect(path, mode):
    if not os.path.isabs(path):
        raise SystemExit(2)
    lexical = os.path.abspath(path)
    parent = os.path.realpath(os.path.dirname(lexical))
    canonical = os.path.join(parent, os.path.basename(lexical))
    if not beneath(run_dir, canonical):
        raise SystemExit(2)
    if beneath(state_lexical, lexical) or beneath(state_canonical, canonical):
        raise SystemExit(2)
    if os.path.lexists(lexical) and stat.S_ISLNK(os.lstat(lexical).st_mode):
        raise SystemExit(2)
    identity = None
    if os.path.exists(lexical):
        entry = os.stat(lexical, follow_symlinks=False)
        if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
            raise SystemExit(2)
        identity = (entry.st_dev, entry.st_ino)
    if mode == "input":
        if identity is None or not os.access(lexical, os.R_OK):
            raise SystemExit(2)
    elif mode == "output":
        if not os.path.isdir(parent):
            raise SystemExit(2)
    else:
        raise SystemExit(2)
    return {"lexical": lexical, "canonical": canonical, "identity": identity}

items = [inspect(requested[0], "input"), inspect(requested[1], "output"), inspect(requested[2], "output")]
for index, left in enumerate(items):
    for right in items[index + 1:]:
        if left["lexical"] == right["lexical"] or left["canonical"] == right["canonical"]:
            raise SystemExit(2)
        if left["identity"] is not None and left["identity"] == right["identity"]:
            raise SystemExit(2)
print(json.dumps({name: item["canonical"] for name, item in zip(("prompt", "result", "status"), items)}, sort_keys=True, separators=(",", ":")), end="")
' "$run_dir" "$state_root" "$prompt_arg" "$result_arg" "$status_arg"
}

_uberdev_agent_prepare_state_dir() {
  python3 -I -c '
import os, stat, sys
run_dir = sys.argv[1]
path = os.path.join(run_dir, f".agent-state-{os.geteuid()}")
try:
    os.mkdir(path, 0o700)
except FileExistsError:
    pass
entry = os.lstat(path)
if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode):
    raise SystemExit(2)
if entry.st_uid != os.geteuid():
    raise SystemExit(2)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    current = os.fstat(descriptor)
    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.geteuid():
        raise SystemExit(2)
    os.fchmod(descriptor, 0o700)
finally:
    os.close(descriptor)
print(path, end="")
' "$1"
}

_uberdev_agent_default_catalog() {
  local state_dir="$1" catalog="$state_dir/model-catalog-v1.json"
  python3 -I -c '
import json, os, stat, sys, tempfile
policy_path, destination = sys.argv[1:]
with open(policy_path, "r", encoding="utf-8") as handle:
    policy = json.load(handle)
routes = policy["routes"]
models = {}
ranked = []
available = []
service_tiers = {"default", "fast", "flex"}
for route, row in sorted(routes.items(), key=lambda item: item[1]["rank"]):
    provider = row["codex"]
    model, effort = provider["model"], provider["reasoning_effort"]
    models.setdefault(model, {"reasoning_efforts": []})["reasoning_efforts"].append(effort)
    ranked.append({
        "logical_route": route, "rank": row["rank"],
        "model": model, "reasoning_effort": effort,
    })
    available.append({"model": model, "reasoning_effort": effort})
    service_tiers.add(provider["service_tier"])
for row in models.values():
    row["reasoning_efforts"] = list(dict.fromkeys(row["reasoning_efforts"]))
catalog = {
    "schema_version": 1, "provider": "codex", "models": models,
    "ranked_pairs": ranked, "available_pairs": available,
    "service_tiers": sorted(service_tiers),
    "source_roles": sorted(policy["roles"]),
}
parent = os.path.dirname(destination)
fd, temporary = tempfile.mkstemp(prefix=".model-catalog.", dir=parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    if os.path.lexists(destination) and stat.S_ISLNK(os.lstat(destination).st_mode):
        raise RuntimeError("catalog destination is a symlink")
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
' "$_UBERDEV_AGENT_POLICY" "$catalog" || return 1
  printf '%s' "$catalog"
}

_uberdev_agent_catalog() {
  local state_dir="$1" injected="${UBERDEV_MODEL_CATALOG_FILE:-}"
  if [ -z "$injected" ]; then
    _uberdev_agent_default_catalog "$state_dir"
    return $?
  fi
  python3 -I -c '
import os, stat, sys
path = os.path.abspath(sys.argv[1])
if not os.path.isabs(sys.argv[1]) or not os.path.isfile(path):
    raise SystemExit(2)
if stat.S_ISLNK(os.lstat(path).st_mode):
    raise SystemExit(2)
print(path, end="")
' "$injected"
}

_uberdev_agent_non_codex_decision() {
  python3 -I -c '
import json, sys
request = json.loads(sys.argv[1])
parent = request.get("parent_run") or {}
service = request.get("explicit_service_tier") or "default"
if (any(request.get(key) not in (None, "") for key in ("explicit_route", "explicit_model", "explicit_effort"))
        or parent.get("forced") is True or service != "default"):
    print(json.dumps({"error":{"code":"route_unenforceable","detail":"Codex route pins cannot be enforced by this backend"}}, separators=(",", ":")), file=sys.stderr)
    raise SystemExit(2)
decision = {
    "schema_version": 1, "backend": request.get("backend"),
    "routing_mode": "inherit", "effective_policy": "inherit",
    "logical_route": None, "model": None, "reasoning_effort": None,
    "service_tier": service, "sandbox": None, "forced": False,
    "route_source": "backend-neutral-inherit", "risk_signals": request.get("risk_signals", []),
    "fallback_chain": [], "minimum_route": None,
}
print(json.dumps(decision, sort_keys=True, separators=(",", ":")))
' "$1"
}

_uberdev_agent_event_json() {
  local event="$1" request="$2" decision="$3" handle="${4:-}" status_path="${5:-}" rc="${6:-}" owner_pid="$$"
  python3 -I -c '
import json, sys
event_name, request_raw, decision_raw, handle, status_path, rc, owner_pid = sys.argv[1:]
request = json.loads(request_raw); decision = json.loads(decision_raw)
routing = decision.get("routing_mode", "inherit")
effective = decision.get("effective_policy", "inherit")
proposal = decision.get("adaptive_proposal") if routing == "shadow" else decision
if not isinstance(proposal, dict):
    proposal = decision
record = {
    "schema_version": 1, "event": event_name,
    "run_id": request["run_id"], "backend": request["backend"],
    "workflow": request.get("workflow"), "phase": request.get("phase"),
    "role": request.get("role"), "issue_or_pr": request.get("issue_or_pr"),
    "task_tier": request.get("task_tier"), "routing_mode": routing,
    "decision_logical_route": proposal.get("logical_route"),
    "decision_source": proposal.get("route_source"),
    "decision_model": proposal.get("model"),
    "decision_reasoning_effort": proposal.get("reasoning_effort"),
    "effective_policy": effective,
    "effective_logical_route": decision.get("logical_route") if effective != "inherit" else None,
    "effective_model": decision.get("model") if effective != "inherit" else None,
    "effective_reasoning_effort": decision.get("reasoning_effort") if effective != "inherit" else None,
    "effective_service_tier": decision.get("service_tier"),
    "effective_sandbox": decision.get("sandbox"),
    "enforcement_evidence": "explicit_argv" if effective != "inherit" else "ambient_unverified",
    "risk_signals": proposal.get("risk_signals", request.get("risk_signals", [])),
}
if request.get("parent_run_id") is not None: record["parent_run_id"] = request["parent_run_id"]
if request.get("agent_id") is not None: record["agent_id"] = request["agent_id"]
if event_name == "agent_started":
    record["owner_pid"] = int(owner_pid)
    record["timeout_s"] = int(request["timeout_s"])
    if handle: record["backend_handle"] = int(handle) if handle.isdigit() else handle
    if status_path: record["status_path"] = status_path
if event_name in {"completed", "failed", "timed_out", "cancelled", "abandoned"}:
    record["terminal_status"] = event_name
    if event_name == "failed": record["error_class"] = "provider_launch_failed"
print(json.dumps({key:value for key,value in record.items() if value is not None}, sort_keys=True, separators=(",", ":")))
' "$event" "$request" "$decision" "$handle" "$status_path" "$rc" "$owner_pid"
}

_uberdev_agent_append_event() {
  local manifest="$1" event_json="$2"
  python3 -I "$_UBERDEV_AGENT_MANIFEST_TOOL" append --manifest "$manifest" --event-json "$event_json" >/dev/null
}

_uberdev_agent_status_terminal_event() {
  python3 -I -c '
import json, os, stat, sys
path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    descriptor = os.open(path, flags)
    target = os.fstat(descriptor)
    if not stat.S_ISREG(target.st_mode) or target.st_size > 65536:
        raise SystemExit(1)
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
keys = [key for key in ("state", "status", "terminal_status") if key in value]
if len(keys) != 1 or not isinstance(value[keys[0]], str):
    raise SystemExit(1)
event = value[keys[0]].strip().lower()
if event not in {"completed", "failed", "timed_out", "cancelled", "abandoned"}:
    raise SystemExit(1)
print(event, end="")
' "$1"
}

_uberdev_agent_publish_status() {
  local status_path="$1" backend="$2" handle="$3" state="$4" exit_code="${5:-}" mode="${6:-replace}"
  python3 -I -c '
import json, os, stat, sys, tempfile
path, backend, handle, state, exit_code, mode = sys.argv[1:]
parent = os.path.dirname(path)
if not os.path.isdir(parent):
    raise SystemExit(2)
payload = {"backend": backend, "state": state, "exit_code": int(exit_code) if exit_code else None, "pid": handle}
fd, temporary = tempfile.mkstemp(prefix=".agent-status.", dir=parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    if mode == "create":
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            if stat.S_ISLNK(os.lstat(path).st_mode) or not os.path.isfile(path):
                raise SystemExit(2)
    else:
        if os.path.lexists(path) and stat.S_ISLNK(os.lstat(path).st_mode):
            raise SystemExit(2)
        os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
' "$status_path" "$backend" "$handle" "$state" "$exit_code" "$mode"
}

_uberdev_agent_claude_probe() {
  local handle="$1"
  claude agents --json 2>/dev/null | python3 -I -c '
import json, sys
short_id = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except (ValueError, UnicodeError):
    raise SystemExit(2)
if not isinstance(rows, list):
    raise SystemExit(2)
matched = [row for row in rows if isinstance(row, dict) and isinstance(row.get("sessionId"), str) and row["sessionId"].startswith(short_id)]
if not matched:
    print("absent", end="")
    raise SystemExit(0)
if len(matched) != 1:
    raise SystemExit(2)
status = str(matched[0].get("status") or "").strip().lower()
if status in {"busy", "running", "starting", "working", "queued"}:
    print("live", end="")
elif status in {"failed", "error"}:
    print("failed", end="")
elif status in {"timed_out", "timeout"}:
    print("timed_out", end="")
elif status in {"cancelled", "canceled"}:
    print("cancelled", end="")
elif status in {"completed", "complete", "done", "finished"}:
    print("completed", end="")
else:
    raise SystemExit(2)
' "$handle"
}

_uberdev_agent_lease_identity() {
  local lease="$1"
  python3 -I -c '
import os, stat, sys
path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    current = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        raise SystemExit(2)
    payload = os.read(descriptor, 65537)
    if len(payload) > 65536:
        raise SystemExit(2)
finally:
    os.close(descriptor)
try:
    rows = dict(line.split("=", 1) for line in payload.decode("utf-8").splitlines())
except (UnicodeError, ValueError):
    raise SystemExit(2)
generation = rows.get("generation", "")
if len(generation) != 32 or any(ch not in "0123456789abcdef" for ch in generation):
    raise SystemExit(2)
print(f"{opened.st_dev}:{opened.st_ino}:{generation}", end="")
' "$lease"
}

_uberdev_agent_release_exact_lease() {
  local lease="$1" identity="$2" scope rc
  _uberdev_semaphore_validate_lease_path "$lease" || return 2
  scope="$(dirname "$lease")"
  _uberdev_semaphore_mutex_acquire "$scope" || return $?
  python3 -I -c '
import os, stat, sys
path, identity = sys.argv[1:]
try:
    expected_device, expected_inode, expected_generation = identity.split(":", 2)
    expected = (int(expected_device), int(expected_inode))
except (TypeError, ValueError):
    raise SystemExit(2)
parent, name = os.path.dirname(path), os.path.basename(path)
parent_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
descriptor = None
try:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        raise SystemExit(0)
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != expected:
        raise SystemExit(3)
    payload = os.read(descriptor, 65537)
    if len(payload) > 65536:
        raise SystemExit(2)
    try:
        rows = dict(line.split("=", 1) for line in payload.decode("utf-8").splitlines())
    except (UnicodeError, ValueError):
        raise SystemExit(2)
    if rows.get("generation") != expected_generation:
        raise SystemExit(3)
    current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != expected:
        raise SystemExit(3)
    os.unlink(name, dir_fd=parent_descriptor)
finally:
    if descriptor is not None:
        os.close(descriptor)
    os.close(parent_descriptor)
' "$lease" "$identity"
  rc=$?
  _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
    [ "$rc" -ne 0 ] || rc=2
  }
  return "$rc"
}

_uberdev_agent_start_watcher() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" backend="$5" handle="$6" request_json="$7" decision="$8"
  local watcher_pid
  (
    local terminal_event='' probe='' absent_count=0 event_json=''
    while [ -d "$(dirname "$status_file")" ]; do
      terminal_event="$(_uberdev_agent_status_terminal_event "$status_file" 2>/dev/null || true)"
      [ -z "$terminal_event" ] || break
      if [ "$backend" = claude-bg ]; then
        probe="$(_uberdev_agent_claude_probe "$handle" 2>/dev/null)"
        case "$probe" in
          live) absent_count=0 ;;
          completed|failed|timed_out|cancelled) terminal_event="$probe"; break ;;
          absent)
            absent_count=$((absent_count + 1))
            if [ "$absent_count" -ge 3 ]; then terminal_event=completed; break; fi
            ;;
          *) absent_count=0 ;;
        esac
      else
        case "$handle" in
          ''|*[!0-9]*) ;;
          *)
            if ! kill -0 "$handle" 2>/dev/null; then
              terminal_event=failed
              break
            fi
            ;;
        esac
      fi
      sleep 1
    done
    [ -n "$terminal_event" ] || exit 0
    case "$terminal_event" in
      completed) terminal_rc=0 ;;
      *) terminal_rc=1 ;;
    esac
    if [ "$backend" = claude-bg ]; then
      _uberdev_agent_publish_status "$status_file" "$backend" "$handle" "$terminal_event" "$terminal_rc" replace || exit 0
    fi
    event_json="$(_uberdev_agent_event_json "$terminal_event" "$request_json" "$decision" "$handle" "$status_file" "$terminal_rc")" || exit 0
    _uberdev_agent_append_event "$manifest" "$event_json" || exit 0
    PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity" >/dev/null 2>&1 || true
  ) </dev/null >/dev/null 2>&1 &
  watcher_pid="$!"
  disown "$watcher_pid" 2>/dev/null || true
}

uberdev_agent_dispatch() {
  local request_json="${1:-}" prompt_requested="${2:-}" result_requested="${3:-}" status_requested="${4:-}"
  local run_dir run_id repository_id backend issue_num tier capacity timeout_s
  local prompt_file result_file status_file state_dir manifest catalog decision lease lease_identity event_json rc handle lease_handle terminal_event paths_json
  [ "$#" -eq 4 ] || { _uberdev_agent_error 'expected REQUEST_JSON PROMPT_FILE RESULT_FILE STATUS_FILE'; return 2; }
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt localoptions nullglob || return 2
  fi
  command -v python3 >/dev/null 2>&1 || { _uberdev_agent_error 'python3 is required'; return 2; }
  [ -r "$_UBERDEV_AGENT_ROUTER" ] && [ -r "$_UBERDEV_AGENT_POLICY" ] && [ -r "$_UBERDEV_AGENT_MANIFEST_TOOL" ] || {
    _uberdev_agent_error 'routing runtime is incomplete'; return 2;
  }
  run_dir="$(_uberdev_agent_json_get "$request_json" run_dir)" || { _uberdev_agent_error 'invalid run_dir'; return 2; }
  run_dir="$(_uberdev_agent_validate_run_dir "$run_dir")" || { _uberdev_agent_error 'unsafe run_dir'; return 2; }
  state_dir="$run_dir/.agent-state-$(python3 -I -c 'import os; print(os.geteuid())')" || return 2
  paths_json="$(_uberdev_agent_validate_paths "$run_dir" "$state_dir" "$prompt_requested" "$result_requested" "$status_requested")" || {
    _uberdev_agent_error 'unsafe or aliased caller paths'; return 2;
  }
  prompt_file="$(_uberdev_agent_json_get "$paths_json" prompt)" || return 2
  result_file="$(_uberdev_agent_json_get "$paths_json" result)" || return 2
  status_file="$(_uberdev_agent_json_get "$paths_json" status)" || return 2
  run_id="$(_uberdev_agent_json_get "$request_json" run_id)" || { _uberdev_agent_error 'invalid run_id'; return 2; }
  repository_id="$(_uberdev_agent_json_get "$request_json" repository_id)" || { _uberdev_agent_error 'invalid repository_id'; return 2; }
  backend="$(_uberdev_agent_json_get "$request_json" backend)" || { _uberdev_agent_error 'invalid backend'; return 2; }
  issue_num="$(_uberdev_agent_json_get "$request_json" issue_num)" || { _uberdev_agent_error 'invalid issue_num'; return 2; }
  tier="$(_uberdev_agent_json_get "$request_json" task_tier)" || { _uberdev_agent_error 'invalid task_tier'; return 2; }
  capacity="$(_uberdev_agent_json_get "$request_json" capacity)" || { _uberdev_agent_error 'invalid capacity'; return 2; }
  timeout_s="$(_uberdev_agent_json_get "$request_json" timeout_s)" || { _uberdev_agent_error 'invalid timeout_s'; return 2; }

  state_dir="$(_uberdev_agent_prepare_state_dir "$run_dir")" || {
    _uberdev_agent_error 'unsafe agent state directory'; return 2;
  }
  manifest="$state_dir/agent-lifecycle.jsonl"

  if [ "$backend" = codex ]; then
    catalog="$(_uberdev_agent_catalog "$state_dir")" || { _uberdev_agent_error 'cannot build provider catalog'; return 2; }
    if ! decision="$(python3 -I "$_UBERDEV_AGENT_ROUTER" resolve --policy "$_UBERDEV_AGENT_POLICY" --catalog "$catalog" --input-json "$request_json")"; then
      _uberdev_agent_error 'route resolution failed'
      return 2
    fi
  else
    decision="$(_uberdev_agent_non_codex_decision "$request_json")" || return $?
  fi

  event_json="$(_uberdev_agent_event_json route_decided "$request_json" "$decision")" || return 2
  _uberdev_agent_append_event "$manifest" "$event_json" || return 2

  lease="$(PYTHONPATH= PYTHONHOME= uberdev_semaphore_acquire "$state_dir" "$repository_id" "$backend" "$capacity" "$run_id" "$timeout_s")" || {
    rc=$?
    return "$rc"
  }

  # Register the canonical status path before the launch boundary.  It may be
  # absent until an opaque provider publishes its first probe; absence is
  # intentionally "unknown", never synthetic evidence that a backend is live.
  if ! PYTHONPATH= PYTHONHOME= uberdev_semaphore_set_handle "$lease" '' "$status_file"; then
    rc=2
    PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
    DISPATCH_RC="$rc"
    return "$rc"
  fi

  event_json="$(_uberdev_agent_event_json agent_started "$request_json" "$decision" '' "$status_file")" || {
    PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
    return 2
  }
  if ! _uberdev_agent_append_event "$manifest" "$event_json"; then
    PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
    return 2
  fi

  UBERDEV_AGENT_DECISION_JSON="$decision"
  UBERDEV_AGENT_RESULT_FILE="$result_file"
  UBERDEV_AGENT_STATUS_FILE="$status_file"
  export UBERDEV_AGENT_DECISION_JSON UBERDEV_AGENT_RESULT_FILE UBERDEV_AGENT_STATUS_FILE
  if _uberdev_agent_dispatch_backend "$backend" "$issue_num" "$tier" "$prompt_file" "$result_file" "$status_file" "$decision"; then
    rc=0
  else
    rc=$?
  fi
  handle="${DISPATCH_ID:-}"
  if [ "$rc" -ne 0 ] || [ -z "$handle" ]; then
    [ "$rc" -ne 0 ] || rc=1
    event_json="$(_uberdev_agent_event_json failed "$request_json" "$decision" '' "$status_file" "$rc")" || true
    [ -z "$event_json" ] || _uberdev_agent_append_event "$manifest" "$event_json" >/dev/null 2>&1 || true
    PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
    DISPATCH_RC="$rc"
    return "$rc"
  fi

  terminal_event="$(_uberdev_agent_status_terminal_event "$status_file" 2>/dev/null || true)"
  lease_handle="$handle"
  [ "$backend" != wezterm ] || lease_handle="pane:$handle"
  if ! PYTHONPATH= PYTHONHOME= uberdev_semaphore_set_handle "$lease" "$lease_handle" "$status_file"; then
    # The provider has already launched exactly once. Keep the status-only
    # lease instead of releasing capacity or retrying a live provider.
    return 2
  fi
  lease_identity="$(_uberdev_agent_lease_identity "$lease")" || return 2
  if [ -n "$terminal_event" ]; then
    event_json="$(_uberdev_agent_event_json "$terminal_event" "$request_json" "$decision" "$handle" "$status_file" 0)" || {
      PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
      return 2
    }
    if ! _uberdev_agent_append_event "$manifest" "$event_json"; then
      PYTHONPATH= PYTHONHOME= uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
      return 2
    fi
    PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity" >/dev/null 2>&1 || return 2
  else
    _uberdev_agent_publish_status "$status_file" "$backend" "$lease_handle" running '' create || return 2
    _uberdev_agent_start_watcher "$manifest" "$lease" "$lease_identity" "$status_file" "$backend" "$lease_handle" "$request_json" "$decision"
  fi
  DISPATCH_RC=0
  return 0
}
