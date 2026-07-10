#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"

[ -r "$LIB" ] || { echo "agent-dispatch: missing $LIB" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run"
STATE_DIR="$TMP/run/.agent-state-$(id -u)"
printf 'instrumented prompt\n' > "$TMP/run/prompt.txt"

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
  # The lifecycle start is durable before the one provider boundary is crossed.
  python3 - "$STATE_DIR/agent-lifecycle.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert [event["event"] for event in events[-2:]] == ["route_decided", "agent_started"], events[-2:]
PY
  python3 - "$UBERDEV_TEST_CAPTURE" "$@" <<'PY'
import json, sys
path, backend, issue, tier, prompt, result, status, decision = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "backend": backend, "issue": issue, "tier": tier,
        "prompt": prompt, "result": result, "status": status,
        "decision": json.loads(decision),
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
    *)
      printf '{"backend":"codex","state":"running","exit_code":null,"pid":"opaque:test-handle"}\n' > "$6"
      ;;
  esac
  return 0
}
export -f _uberdev_agent_dispatch_backend

# shellcheck source=/dev/null
. "$LIB"

uberdev_agent_dispatch "$REQUEST" \
  "$TMP/run/prompt.txt" "$TMP/run/result.md" "$TMP/run/status.json"

python3 - "$TMP/backend.json" "$STATE_DIR/agent-lifecycle.jsonl" "$TMP/run/status.json" "$$" <<'PY'
import json, pathlib, sys
capture = json.loads(pathlib.Path(sys.argv[1]).read_text())
decision = capture["decision"]
assert capture["backend"] == "codex"
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
PY

# Opaque handles remain live for reconciliation and retain their lease.
LEASES="$(find "$STATE_DIR" -name '*.lease' -type f | wc -l | tr -d ' ')"
[ "$LEASES" = 1 ] || { echo "expected one registered opaque lease, got $LEASES" >&2; exit 1; }

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
    request["routing_mode"] = "adaptive"
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

# An opaque provider without a status probe must remain unknown, not be
# synthesized as permanently running by the adapter. The lease still records
# the canonical path for a later provider write or dead-owner reconciliation.
NO_STATUS_REQUEST="$(variant_request agent-dispatch-no-status inherit)"
uberdev_agent_dispatch "$NO_STATUS_REQUEST" "$TMP/run/prompt.txt" "$TMP/run/no-status.md" "$TMP/run/no-status.json"
[ ! -e "$TMP/run/no-status.json" ] || {
  echo "adapter synthesized a permanently-live opaque status" >&2; exit 1;
}
grep -R -q "run_id=agent-dispatch-no-status" "$STATE_DIR/semaphore-v1" || {
  echo "opaque dispatch without current status was not registered" >&2; exit 1;
}

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

echo "agent-dispatch: PASS"
