#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
[ -r "$LIB" ] || { echo "RED: child wait runtime missing" >&2; exit 1; }
. "$LIB"
mkdir -p "$TMP/run/children/worker-0001" "$TMP/run/.agent-state-$(id -u)"
HANDOFF="$TMP/run/children/worker-0001/handoff.v1.json"
printf '{"schema_version":1,"instance_id":"worker-0001"}\n' >"$HANDOFF"
RESULT="$TMP/run/children/worker-0001/result.md"; STATUS="$TMP/run/children/worker-0001/status.json"
MANIFEST="$TMP/run/.agent-state-$(id -u)/agent-lifecycle.jsonl"
terminal_manifest() {
  local terminal="$1"
  printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
  printf '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >>"$MANIFEST"
  printf '{"schema_version":1,"event":"%s","timestamp":"2026-07-10T00:00:02.000Z","run_id":"worker-0001"}\n' "$terminal" >>"$MANIFEST"
}
printf 'completed result\n' >"$RESULT"; printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest completed
uberdev_wait_child "$STATUS" "$RESULT" 2 >/dev/null

: >"$RESULT"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf x >"$RESULT"; printf '{bad\n' >"$STATUS"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"completed","exit_code":1,"pid":"321"}\n' >"$STATUS"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"failed","exit_code":1,"pid":"321"}\n' >"$STATUS"; terminal_manifest failed; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest failed; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1

# Timeout terminates a supported numeric handle, records timed_out, and never succeeds.
( trap 'exit 0' TERM; while :; do sleep 1; done ) & SLEEP_PID=$!
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$SLEEP_PID" >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
for _ in 1 2 3 4 5; do ! kill -0 "$SLEEP_PID" 2>/dev/null && break; sleep .1; done
! kill -0 "$SLEEP_PID" 2>/dev/null
python3 - "$STATUS" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['state']=='timed_out' and s['exit_code']!=0
PY

# Paths must be the canonical owned child pair and timeout must be bounded.
! uberdev_wait_child "$TMP/outside-status" "$RESULT" 1 >/dev/null 2>&1
! uberdev_wait_child "$STATUS" "$TMP/outside-result" 1 >/dev/null 2>&1
! uberdev_wait_child "$STATUS" "$RESULT" 0 >/dev/null 2>&1
echo 'child-wait: 12 checks passed'
