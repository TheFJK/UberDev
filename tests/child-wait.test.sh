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

# A running status without the exact lifecycle lease is not cancellation
# authority: never signal or synthesize timed_out.
( trap 'exit 0' TERM; while :; do sleep 1; done ) & SLEEP_PID=$!
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"%s"}\n' "$SLEEP_PID" >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
kill -0 "$SLEEP_PID"
python3 - "$STATUS" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['state']=='running' and s['exit_code'] is None
PY
kill -TERM "$SLEEP_PID"; wait "$SLEEP_PID" 2>/dev/null || true

# PID reuse/identity defense: wrong launch identity is rejected without a
# signal; the exact identity cancels and proves the process is gone.
( while :; do sleep 1; done ) & PID_GUARD=$!
IDENTITY="$(_uberdev_agent_process_identity "$PID_GUARD")"
! _uberdev_dispatch_cancel_backend codex "$PID_GUARD" "$PID_GUARD:reused-identity"
kill -0 "$PID_GUARD"
_uberdev_dispatch_cancel_backend codex "$PID_GUARD" "$IDENTITY"
! kill -0 "$PID_GUARD" 2>/dev/null

# Opaque Claude sessions cancel through an explicit provider capability hook
# and require an absent/terminal probe, never a fabricated local state.
mkdir "$TMP/bin"; printf '[{"sessionId":"abc12345-full","status":"running"}]\n' >"$TMP/claude-state"
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agents --json' ]; then cat "$CLAUDE_STATE"; exit 0; fi
exit 2
SH
chmod +x "$TMP/bin/claude"
_uberdev_dispatch_cancel_claude_bg() { printf '[]\n' >"$CLAUDE_STATE"; }
CLAUDE_STATE="$TMP/claude-state" PATH="$TMP/bin:$PATH" _uberdev_dispatch_cancel_backend claude-bg abc12345 ''

# The production Claude provider has no cancellation capability. A timeout
# therefore fails closed before mutating status, manifest, or the live lease.
_uberdev_dispatch_cancel_claude_bg() { return 2; }
GENERATION=abcdef0123456789abcdef0123456789
printf '{"backend":"claude-bg","state":"running","exit_code":null,"pid":"unsupported-session","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
LEASE_DIR="$TMP/run/.agent-state-$(id -u)/semaphore-v1/slots"; mkdir -p "$LEASE_DIR"
LEASE="$LEASE_DIR/unsupported.lease"
printf 'run_id=worker-0001\nstatus_path=%s\ngeneration=%s\n' "$STATUS" "$GENERATION" >"$LEASE"
STATUS_SHA="$(shasum -a 256 "$STATUS" | awk '{print $1}')"
MANIFEST_SHA="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
LEASE_SHA="$(shasum -a 256 "$LEASE" | awk '{print $1}')"
set +e
uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
WAIT_RC=$?
set -e
[ "$WAIT_RC" -eq 2 ]
[ "$WAIT_RC" -ne 124 ]
[ "$(shasum -a 256 "$STATUS" | awk '{print $1}')" = "$STATUS_SHA" ]
[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" = "$MANIFEST_SHA" ]
[ -f "$LEASE" ] && [ "$(shasum -a 256 "$LEASE" | awk '{print $1}')" = "$LEASE_SHA" ]

# CAS cannot overwrite a provider completion that wins the timeout race.
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"777","lease_generation":"0123456789abcdef0123456789abcdef"}\n' >"$STATUS"
OLD_SHA="$(shasum -a 256 "$STATUS" | awk '{print $1}')"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"777","lease_generation":"0123456789abcdef0123456789abcdef"}\n' >"$STATUS"
! _uberdev_child_timeout_cas "$STATUS" "$OLD_SHA" 777 0123456789abcdef0123456789abcdef >/dev/null 2>&1
grep -q '"state":"completed"' "$STATUS"

# zsh can source and execute the public wait API without colliding with its
# readonly `status` special parameter.
printf 'zsh result\n' >"$RESULT"; printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest completed
zsh -f -c '. "$1"; uberdev_wait_child "$2" "$3" 2' _ "$LIB" "$STATUS" "$RESULT" >/dev/null

# Paths must be the canonical owned child pair and timeout must be bounded.
! uberdev_wait_child "$TMP/outside-status" "$RESULT" 1 >/dev/null 2>&1
! uberdev_wait_child "$STATUS" "$TMP/outside-result" 1 >/dev/null 2>&1
! uberdev_wait_child "$STATUS" "$RESULT" 0 >/dev/null 2>&1
echo 'child-wait: 31 checks passed'
