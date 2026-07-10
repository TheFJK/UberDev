#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/plugins/uberdev/lib/run_manifest.py"
FIXTURES="$ROOT/tests/fixtures/run-manifest"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
CAPTURE_OUT=""
CAPTURE_RC=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
capture() {
  CAPTURE_OUT="$("$@" 2>&1)"
  CAPTURE_RC=$?
}
append_event() {
  python3 "$MANIFEST" append --manifest "$1" --event-json "$2"
}
mode_of() {
  local value
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

if [ ! -f "$MANIFEST" ]; then
  printf '  FAIL  run_manifest.py is missing: %s\n' "$MANIFEST"
  exit 1
fi

printf '== run manifest: fixture verification ==\n'
capture python3 "$MANIFEST" verify --manifest "$FIXTURES/valid.jsonl" --strict
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"events":3,"runs":1,"status":"ok"}' ]; then
  pass "valid lifecycle verifies deterministically"
else
  fail "valid lifecycle verifies deterministically" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/malformed.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && [ "$CAPTURE_OUT" = '{"errors":["line 2: malformed_json"],"status":"invalid"}' ]; then
  pass "malformed JSON is reported by line with rc=1"
else
  fail "malformed JSON is reported by line with rc=1" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/duplicate-terminal.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 4: duplicate_terminal'; then
  pass "duplicate terminal event is rejected"
else
  fail "duplicate terminal event is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/invalid-transition.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 1: agent_started_before_route_decided'; then
  pass "start before route decision is rejected"
else
  fail "start before route decision is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/missing-terminal.jsonl"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "non-strict verification permits a live started run"
else
  fail "non-strict verification permits a live started run" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" verify --manifest "$FIXTURES/missing-terminal.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'run run-open: missing_terminal'; then
  pass "strict verification rejects a missing terminal"
else
  fail "strict verification rejects a missing terminal" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/forbidden.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'forbidden_field: prompt_body'; then
  pass "verification detects forbidden payload fields"
else
  fail "verification detects forbidden payload fields" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/schema-float.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_schema_version'; then
  pass "schema version must be the integer 1, not a JSON float"
else
  fail "schema version must be the integer 1, not a JSON float" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/backend-mismatch.jsonl" --strict
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'line 2: backend_mismatch'; then
  pass "backend identity cannot drift within one lifecycle"
else
  fail "backend identity cannot drift within one lifecycle" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

for invalid_case in \
  'invalid-routing.jsonl:invalid_routing_mode' \
  'invalid-enforcement.jsonl:invalid_enforcement_evidence' \
  'shadow-contradiction.jsonl:shadow_requires_inherit' \
  'credential-value.jsonl:sensitive_value: decision_source' \
  'free-text-error.jsonl:invalid_fallback_reason' \
  'opaque-without-status.jsonl:opaque_backend_handle_requires_status_path'
do
  fixture="${invalid_case%%:*}"
  expected="${invalid_case#*:}"
  capture python3 "$MANIFEST" verify --manifest "$FIXTURES/$fixture"
  if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -Fq "$expected"; then
    pass "$fixture is rejected by closed manifest metadata rules"
  else
    fail "$fixture is rejected by closed manifest metadata rules" "rc=$CAPTURE_RC expected=$expected out=$CAPTURE_OUT"
  fi
done

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/null-owner.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_owner_pid'; then
  pass "agent_started requires a positive owner PID, not null"
else
  fail "agent_started requires a positive owner PID, not null" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/policy-mismatch.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'decision_effective_route_mismatch'; then
  pass "adaptive decision and effective route metadata must agree"
else
  fail "adaptive decision and effective route metadata must agree" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 "$MANIFEST" verify --manifest "$FIXTURES/sensitive-allowed-field.jsonl"
if [ "$CAPTURE_RC" -eq 1 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'sensitive_value: issue_or_pr'; then
  pass "sensitive content cannot smuggle through an allowed metadata key"
else
  fail "sensitive content cannot smuggle through an allowed metadata key" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '== run manifest: append schema, lifecycle, privacy, and atomicity ==\n'
APPEND_DIR="$TMP/private-manifest"
APPEND_PATH="$APPEND_DIR/events.jsonl"
ROUTE='{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:01:00Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","decision_source":"role-policy","usage_source":"provider","input_tokens":0}'
START="{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:01:01Z\",\"run_id\":\"run-append\",\"agent_id\":\"agent-append\",\"backend\":\"codex\",\"owner_pid\":$$,\"backend_handle\":null,\"timeout_s\":5}"
DONE='{"schema_version":1,"event":"completed","timestamp":"2026-07-10T00:01:02Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","terminal_status":"completed"}'

capture append_event "$APPEND_PATH" "$ROUTE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"event":"route_decided","run_id":"run-append","status":"appended"}' ]; then
  pass "append emits deterministic success JSON"
else
  fail "append emits deterministic success JSON" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture append_event "$APPEND_PATH" "$START"
[ "$CAPTURE_RC" -eq 0 ] && pass "agent_started appends after route_decided" || fail "agent_started appends after route_decided" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture append_event "$APPEND_PATH" "$DONE"
[ "$CAPTURE_RC" -eq 0 ] && pass "terminal appends after agent_started" || fail "terminal appends after agent_started" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

capture python3 "$MANIFEST" verify --manifest "$APPEND_PATH" --strict
[ "$CAPTURE_RC" -eq 0 ] && pass "appended lifecycle verifies strict" || fail "appended lifecycle verifies strict" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

if [ "$(mode_of "$APPEND_DIR")" = "700" ] && [ "$(mode_of "$APPEND_PATH")" = "600" ]; then
  pass "manifest parent is 0700 and file is 0600"
else
  fail "manifest parent is 0700 and file is 0600" "dir=$(mode_of "$APPEND_DIR") file=$(mode_of "$APPEND_PATH")"
fi

before_lines="$(wc -l < "$APPEND_PATH" | tr -d ' ')"
capture append_event "$APPEND_PATH" '{"schema_version":1,"event":"failed","timestamp":"2026-07-10T00:01:03Z","run_id":"run-append","agent_id":"agent-append","backend":"codex","terminal_status":"failed"}'
after_lines="$(wc -l < "$APPEND_PATH" | tr -d ' ')"
if [ "$CAPTURE_RC" -eq 2 ] && [ "$before_lines" -eq "$after_lines" ] && printf '%s' "$CAPTURE_OUT" | grep -q 'duplicate_terminal'; then
  pass "append rejects a second terminal without mutating the file"
else
  fail "append rejects a second terminal without mutating the file" "rc=$CAPTURE_RC lines=$before_lines/$after_lines out=$CAPTURE_OUT"
fi

capture append_event "$TMP/no-route/events.jsonl" '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:02:00Z","run_id":"run-no-route","backend":"codex","owner_pid":1}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'agent_started_before_route_decided'; then
  pass "append validates lifecycle transitions"
else
  fail "append validates lifecycle transitions" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

forbidden_fail_before="$FAIL"
for forbidden in prompt source body raw content issue_body source_code credentials secret api_key access_token; do
  path="$TMP/forbidden-$forbidden/events.jsonl"
  json="{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:03:00Z\",\"run_id\":\"run-$forbidden\",\"backend\":\"codex\",\"$forbidden\":\"sensitive\"}"
  capture append_event "$path" "$json"
  if [ "$CAPTURE_RC" -ne 2 ]; then
    fail "forbidden field $forbidden is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
done
if [ "$FAIL" -eq "$forbidden_fail_before" ]; then
  pass "prompt/source/body/raw and credential payload fields are rejected"
fi

capture append_event "$TMP/unknown/events.jsonl" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:04:00Z","run_id":"run-unknown","backend":"codex","message":"payload in disguise"}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'unknown_field: message'; then
  pass "unknown non-metadata fields are rejected"
else
  fail "unknown non-metadata fields are rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

payload_smuggling_fail_before="$FAIL"
for metadata_field in workflow phase role parent_run_id decision_model effective_model; do
  path="$TMP/payload-smuggling-$metadata_field/events.jsonl"
  json="{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-smuggling-$metadata_field\",\"backend\":\"codex\",\"$metadata_field\":\"function exfiltrate(){return document.cookie}\"}"
  capture append_event "$path" "$json"
  if [ "$CAPTURE_RC" -ne 2 ]; then
    fail "payload text in $metadata_field is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
done
capture append_event "$TMP/payload-smuggling-risks/events.jsonl" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:04:01Z","run_id":"run-smuggling-risks","backend":"codex","risk_signals":["copy the complete issue body into logs"]}'
if [ "$CAPTURE_RC" -ne 2 ]; then
  fail "payload text in risk_signals is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
if [ "$FAIL" -eq "$payload_smuggling_fail_before" ]; then
  pass "allowed metadata fields cannot smuggle source or prose payloads"
fi

LONG_RISK="$(printf '%0130d' 0 | tr '0' 'a')"
LONG_CODE="$(printf '%0300d' 0 | tr '0' 'a')"
capture append_event "$TMP/payload-smuggling-long-risk/events.jsonl" "{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-long-risk\",\"backend\":\"codex\",\"risk_signals\":[\"$LONG_RISK\"]}"
long_risk_rc="$CAPTURE_RC"
capture append_event "$TMP/payload-smuggling-long-code/events.jsonl" "{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:01Z\",\"run_id\":\"run-long-code\",\"backend\":\"codex\",\"decision_source\":\"$LONG_CODE\"}"
if [ "$long_risk_rc" -eq 2 ] && [ "$CAPTURE_RC" -eq 2 ]; then
  pass "code-shaped metadata remains tightly size-bounded"
else
  fail "code-shaped metadata remains tightly size-bounded" "risk_rc=$long_risk_rc code_rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture append_event "$TMP/non-string-risk/events.jsonl" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:04:01Z","run_id":"run-non-string-risk","backend":"codex","risk_signals":[{}]}'
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_risk_signals'; then
  pass "non-string risk metadata is rejected without a validator crash"
else
  fail "non-string risk metadata is rejected without a validator crash" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

OPAQUE_PAYLOAD_PATH="$TMP/payload-smuggling-handle/events.jsonl"
OPAQUE_PAYLOAD_STATUS="$TMP/payload-smuggling-handle/status.json"
mkdir -p "$(dirname "$OPAQUE_PAYLOAD_STATUS")"
printf '{"state":"running"}\n' > "$OPAQUE_PAYLOAD_STATUS"
append_event "$OPAQUE_PAYLOAD_PATH" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:04:02Z","run_id":"run-smuggling-handle","backend":"codex"}' >/dev/null
capture append_event "$OPAQUE_PAYLOAD_PATH" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:03Z\",\"run_id\":\"run-smuggling-handle\",\"backend\":\"codex\",\"owner_pid\":$$,\"backend_handle\":\"function steal(){return document.cookie}\",\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_backend_handle'; then
  pass "opaque backend handles are identifiers rather than payload channels"
else
  fail "opaque backend handles are identifiers rather than payload channels" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

INVALID_PID_HANDLE_PATH="$TMP/invalid-pid-handle/events.jsonl"
append_event "$INVALID_PID_HANDLE_PATH" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:04:02Z","run_id":"run-invalid-pid-handle","backend":"codex"}' >/dev/null
capture append_event "$INVALID_PID_HANDLE_PATH" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:03Z\",\"run_id\":\"run-invalid-pid-handle\",\"backend\":\"codex\",\"owner_pid\":$$,\"backend_handle\":0,\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
if [ "$CAPTURE_RC" -eq 2 ] && printf '%s' "$CAPTURE_OUT" | grep -q 'invalid_backend_handle'; then
  pass "numeric backend handles must be positive process IDs"
else
  fail "numeric backend handles must be positive process IDs" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

reserved_pid_failures=''
reserved_pid_index=0
for reserved_pid_handle in 'pid:' 'pid:0' 'pid:-1' 'pid:provider'; do
  reserved_pid_index=$((reserved_pid_index + 1))
  reserved_append_path="$TMP/reserved-pid-append-$reserved_pid_index/events.jsonl"
  reserved_route="{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:04:10Z\",\"run_id\":\"run-reserved-$reserved_pid_index\",\"backend\":\"codex\"}"
  reserved_start="{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:04:11Z\",\"run_id\":\"run-reserved-$reserved_pid_index\",\"backend\":\"codex\",\"owner_pid\":$$,\"backend_handle\":\"$reserved_pid_handle\",\"status_path\":\"$OPAQUE_PAYLOAD_STATUS\"}"
  append_event "$reserved_append_path" "$reserved_route" >/dev/null
  capture append_event "$reserved_append_path" "$reserved_start"
  append_reserved_rc="$CAPTURE_RC"
  append_reserved_out="$CAPTURE_OUT"

  reserved_verify_path="$TMP/reserved-pid-verify-$reserved_pid_index/events.jsonl"
  mkdir -p "$(dirname "$reserved_verify_path")"
  printf '%s\n%s\n' "$reserved_route" "$reserved_start" > "$reserved_verify_path"
  capture python3 "$MANIFEST" verify --manifest "$reserved_verify_path"
  verify_reserved_rc="$CAPTURE_RC"
  verify_reserved_out="$CAPTURE_OUT"
  reserved_lines_before="$(wc -l < "$reserved_verify_path" | tr -d ' ')"
  capture python3 "$MANIFEST" reconcile --manifest "$reserved_verify_path"
  reconcile_reserved_rc="$CAPTURE_RC"
  reconcile_reserved_out="$CAPTURE_OUT"
  reserved_lines_after="$(wc -l < "$reserved_verify_path" | tr -d ' ')"

  if [ "$append_reserved_rc" -ne 2 ] || ! printf '%s' "$append_reserved_out" | grep -q invalid_backend_handle \
     || [ "$verify_reserved_rc" -ne 1 ] || ! printf '%s' "$verify_reserved_out" | grep -q invalid_backend_handle \
     || [ "$reconcile_reserved_rc" -ne 2 ] || ! printf '%s' "$reconcile_reserved_out" | grep -q invalid_backend_handle \
     || [ "$reserved_lines_before" -ne "$reserved_lines_after" ]; then
    reserved_pid_failures="$reserved_pid_failures $reserved_pid_handle(append:$append_reserved_rc,verify:$verify_reserved_rc,reconcile:$reconcile_reserved_rc,lines:$reserved_lines_before/$reserved_lines_after)"
  fi
done
if [ -z "$reserved_pid_failures" ]; then
  pass "append, verify, and reconcile reserve pid: for positive decimal process IDs"
else
  fail "append, verify, and reconcile reserve pid: for positive decimal process IDs" "$reserved_pid_failures"
fi

ATOMIC_PATH="$TMP/atomic/events.jsonl"
pids=""
i=1
while [ "$i" -le 24 ]; do
  append_event "$ATOMIC_PATH" "{\"schema_version\":1,\"event\":\"route_decided\",\"timestamp\":\"2026-07-10T00:05:00Z\",\"run_id\":\"run-atomic-$i\",\"backend\":\"codex\"}" >/dev/null 2>&1 &
  pids="$pids $!"
  i=$((i + 1))
done
atomic_rc=0
for pid in $pids; do wait "$pid" || atomic_rc=1; done
capture python3 "$MANIFEST" verify --manifest "$ATOMIC_PATH"
atomic_lines="$(wc -l < "$ATOMIC_PATH" | tr -d ' ')"
if [ "$atomic_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ] && [ "$atomic_lines" -eq 24 ]; then
  pass "concurrent appends remain 24 complete JSONL records"
else
  fail "concurrent appends remain 24 complete JSONL records" "append_rc=$atomic_rc verify_rc=$CAPTURE_RC lines=$atomic_lines out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/open-flags/events.jsonl" <<'PY'
import importlib.util
import json
import os
import sys

module_path, manifest_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("run_manifest_flags", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

real_open = module.os.open
real_write = module.os.write
open_calls = []
write_calls = []

def tracked_open(path, flags, mode=0o777, *, dir_fd=None):
    open_calls.append((path, flags, mode, dir_fd))
    return real_open(path, flags, mode, dir_fd=dir_fd)

def tracked_write(fd, payload):
    write_calls.append(bytes(payload))
    return real_write(fd, payload)

module.os.open = tracked_open
module.os.write = tracked_write
module.append_event(manifest_path, {
    "schema_version": 1,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:30Z",
    "run_id": "run-open-flags",
    "backend": "codex",
})
append_opens = [call for call in open_calls if call[1] & os.O_APPEND]
assert len(append_opens) == 1, append_opens
_, flags, mode, _ = append_opens[0]
assert flags & os.O_CREAT and flags & os.O_WRONLY and flags & os.O_NOFOLLOW, flags
assert mode == 0o600, oct(mode)
assert len(write_calls) == 1, len(write_calls)
record = write_calls[0]
assert record.endswith(b"\n") and record.count(b"\n") == 1
json.loads(record)
print("secure-open-write-ok")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'secure-open-write-ok' ]; then
  pass "append fault probe observes secure flags, mode 0600, and exactly one write"
else
  fail "append fault probe observes secure flags, mode 0600, and exactly one write" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/short-write-rollback/events.jsonl" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, manifest_text = sys.argv[1:]
manifest = Path(manifest_text)
spec = importlib.util.spec_from_file_location("run_manifest_short_write", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

module.append_event(str(manifest), {
    "schema_version": 1,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:30Z",
    "run_id": "run-before-short-write",
    "backend": "codex",
})
before = manifest.read_bytes()
real_write = module.os.write
payload_writes = 0

def half_write(fd, payload):
    global payload_writes
    payload_writes += 1
    partial = payload[: max(1, len(payload) // 2)]
    return real_write(fd, partial)

module.os.write = half_write
try:
    module.append_event(str(manifest), {
        "schema_version": 1,
        "event": "route_decided",
        "timestamp": "2026-07-10T00:05:31Z",
        "run_id": "run-short-write",
        "backend": "codex",
    })
except module.ManifestRuntimeError as exc:
    assert str(exc) == "manifest_short_write", str(exc)
else:
    raise AssertionError("short write unexpectedly succeeded")
finally:
    module.os.write = real_write

assert payload_writes == 1, payload_writes
assert manifest.read_bytes() == before
result, return_code = module.verify_manifest(str(manifest), strict=False)
assert return_code == 0, result
assert result == {"events": 1, "runs": 1, "status": "ok"}, result
print("short-write-rolled-back")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'short-write-rolled-back' ]; then
  pass "short manifest write truncates back to the locked original length"
else
  fail "short manifest write truncates back to the locked original length" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/ancestor-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
victim = outside / "events.jsonl"
victim.write_text("unchanged\n", encoding="utf-8")
manifest = safe / "events.jsonl"

spec = importlib.util.spec_from_file_location("run_manifest_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    path_text = os.fspath(path)
    if not swapped and path_text == os.fspath(manifest):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
        return real_open(path, flags, mode, dir_fd=dir_fd)
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and path_text == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
try:
    module.append_event(str(manifest), {
        "schema_version": 1,
        "event": "route_decided",
        "timestamp": "2026-07-10T00:05:31Z",
        "run_id": "run-ancestor-swap",
        "backend": "codex",
    })
except (module.ManifestRejected, module.ManifestRuntimeError):
    pass
assert swapped
assert victim.read_text(encoding="utf-8") == "unchanged\n"
print("ancestor-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'ancestor-swap-contained' ]; then
  pass "manifest append contains an ancestor symlink replacement"
else
  fail "manifest append contains an ancestor symlink replacement" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/realpath-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
manifest = safe / "events.jsonl"

spec = importlib.util.spec_from_file_location("run_manifest_realpath_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_realpath = module.os.path.realpath

def attacked_realpath(path):
    if os.path.abspath(os.fspath(path)) == os.fspath(safe):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        try:
            return real_realpath(path)
        finally:
            safe.unlink()
            moved.rename(safe)
    return real_realpath(path)

module.os.path.realpath = attacked_realpath
module.append_event(str(manifest), {
    "schema_version": 1,
    "event": "route_decided",
    "timestamp": "2026-07-10T00:05:32Z",
    "run_id": "run-realpath-swap",
    "backend": "codex",
})
assert manifest.is_file()
assert not (outside / "events.jsonl").exists()
print("realpath-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'realpath-swap-contained' ]; then
  pass "manifest open cannot be redirected during path canonicalization"
else
  fail "manifest open cannot be redirected during path canonicalization" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/status-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
(safe / "status.json").write_text('{"state":"running"}\n', encoding="utf-8")
(outside / "status.json").write_text('{"state":"completed"}\n', encoding="utf-8")

spec = importlib.util.spec_from_file_location("run_manifest_status_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and os.fspath(path) == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
assert module.probe_status_file(str(safe / "status.json")) == "live"
assert swapped
print("status-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'status-swap-contained' ]; then
  pass "status probe contains an ancestor symlink replacement"
else
  fail "status probe contains an ancestor symlink replacement" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture python3 - "$MANIFEST" "$TMP/lease-swap" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, root_text = sys.argv[1:]
root = Path(root_text)
safe = root / "safe"
moved = root / "safe-original"
outside = root / "outside"
safe.mkdir(parents=True)
outside.mkdir()
generation = "a" * 32
name = generation + "b" * 32 + ".lease"
payload = (
    "version=1\n"
    f"generation={generation}\n"
    "run_id=run-swap\nowner_pid=1\nbackend_handle=\n"
    "start_epoch=1\ntimeout_s=5\nstatus_path=\n"
).encode()

spec = importlib.util.spec_from_file_location("run_manifest_lease_swap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_open = module.os.open
swapped = False

def attacked_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if not swapped and os.fspath(path) == safe.name and flags & getattr(os, "O_DIRECTORY", 0):
        safe.rename(moved)
        safe.symlink_to(outside, target_is_directory=True)
        swapped = True
    return fd

module.os.open = attacked_open
module.secure_write_lease(str(safe / name), payload)
assert swapped
assert not (outside / name).exists()
assert (moved / name).is_file()
print("lease-swap-contained")
PY
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 'lease-swap-contained' ]; then
  pass "lease publication contains an ancestor replacement around atomic rename"
else
  fail "lease publication contains an ancestor replacement around atomic rename" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

VICTIM="$TMP/manifest-victim"
printf 'unchanged\n' > "$VICTIM"
mkdir -p "$TMP/manifest-link"
ln -s "$VICTIM" "$TMP/manifest-link/events.jsonl"
capture append_event "$TMP/manifest-link/events.jsonl" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:06:00Z","run_id":"run-link","backend":"codex"}'
if [ "$CAPTURE_RC" -ne 0 ] && [ "$(cat "$VICTIM")" = "unchanged" ]; then
  pass "manifest symlink target is rejected"
else
  fail "manifest symlink target is rejected" "rc=$CAPTURE_RC victim=$(cat "$VICTIM")"
fi

mkdir "$TMP/manifest-ancestor-target"
ln -s "$TMP/manifest-ancestor-target" "$TMP/manifest-ancestor-link"
capture append_event "$TMP/manifest-ancestor-link/private/events.jsonl" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:06:01Z","run_id":"run-ancestor-link","backend":"codex"}'
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -e "$TMP/manifest-ancestor-target/private/events.jsonl" ]; then
  pass "manifest rejects a symlinked ancestor path"
else
  fail "manifest rejects a symlinked ancestor path" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '== run manifest: conservative orphan reconciliation ==\n'
sleep 0.01 & dead_pid=$!
wait "$dead_pid"
ORPHAN="$TMP/orphan/events.jsonl"
append_event "$ORPHAN" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:07:00Z","run_id":"run-orphan","backend":"codex"}' >/dev/null
append_event "$ORPHAN" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:01Z\",\"run_id\":\"run-orphan\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$ORPHAN"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "reconcile abandons when owner and backend handle are both dead"
else
  fail "reconcile abandons when owner and backend handle are both dead" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" reconcile --manifest "$ORPHAN"
terminal_count="$(grep -c '"event":"abandoned"' "$ORPHAN" || true)"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":0,"status":"ok"}' ] && [ "$terminal_count" -eq 1 ]; then
  pass "reconcile is idempotent and never duplicates a terminal"
else
  fail "reconcile is idempotent and never duplicates a terminal" "rc=$CAPTURE_RC terminals=$terminal_count out=$CAPTURE_OUT"
fi
capture python3 "$MANIFEST" verify --manifest "$ORPHAN" --strict
[ "$CAPTURE_RC" -eq 0 ] && pass "reconciled orphan has exactly one terminal" || fail "reconciled orphan has exactly one terminal" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

printf '== run manifest: canonical terminal status reconciliation ==\n'
TRUE_COMPLETED_STATUS="$TMP/true-completed/status.json"
TRUE_COMPLETED_MANIFEST="$TMP/true-completed/events.jsonl"
mkdir -p "$(dirname "$TRUE_COMPLETED_STATUS")"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s","ignored":"not-manifest-data"}\n' "$dead_pid" > "$TRUE_COMPLETED_STATUS"
append_event "$TRUE_COMPLETED_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:07:10Z","run_id":"run-true-completed","backend":"codex"}' >/dev/null
append_event "$TRUE_COMPLETED_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:11Z\",\"run_id\":\"run-true-completed\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$TRUE_COMPLETED_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_COMPLETED_MANIFEST"
completed_reconcile_rc="$CAPTURE_RC"
completed_reconcile_out="$CAPTURE_OUT"
completed_terminal="$(tail -n 1 "$TRUE_COMPLETED_MANIFEST")"
if [ "$completed_reconcile_rc" -eq 0 ] \
   && [ "$completed_reconcile_out" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && printf '%s' "$completed_terminal" | grep -q '"event":"completed"' \
   && ! printf '%s' "$completed_terminal" | grep -q 'ignored'; then
  pass "reconcile consumes canonical completed status without copying arbitrary fields"
else
  fail "reconcile consumes canonical completed status without copying arbitrary fields" "rc=$completed_reconcile_rc out=$completed_reconcile_out terminal=$completed_terminal"
fi

TRUE_FAILED_STATUS="$TMP/true-failed/status.json"
TRUE_FAILED_MANIFEST="$TMP/true-failed/events.jsonl"
mkdir -p "$(dirname "$TRUE_FAILED_STATUS")"
printf '{"backend":"codex","state":"failed","exit_code":17,"pid":"%s"}\n' "$dead_pid" > "$TRUE_FAILED_STATUS"
append_event "$TRUE_FAILED_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:07:20Z","run_id":"run-true-failed","backend":"codex"}' >/dev/null
append_event "$TRUE_FAILED_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:21Z\",\"run_id\":\"run-true-failed\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$TRUE_FAILED_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_FAILED_MANIFEST"
failed_reconcile_rc="$CAPTURE_RC"
failed_reconcile_out="$CAPTURE_OUT"
failed_terminal="$(tail -n 1 "$TRUE_FAILED_MANIFEST")"
if [ "$failed_reconcile_rc" -eq 0 ] \
   && [ "$failed_reconcile_out" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && printf '%s' "$failed_terminal" | grep -q '"event":"failed"' \
   && printf '%s' "$failed_terminal" | grep -q '"error_class":"provider_failed"'; then
  pass "reconcile consumes canonical failed status with validated nonzero exit"
else
  fail "reconcile consumes canonical failed status with validated nonzero exit" "rc=$failed_reconcile_rc out=$failed_reconcile_out terminal=$failed_terminal"
fi

before_true_terminal_lines="$(wc -l < "$TRUE_COMPLETED_MANIFEST" | tr -d ' ')"
capture python3 "$MANIFEST" reconcile --manifest "$TRUE_COMPLETED_MANIFEST"
after_true_terminal_lines="$(wc -l < "$TRUE_COMPLETED_MANIFEST" | tr -d ' ')"
if [ "$CAPTURE_RC" -eq 0 ] \
   && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":0,"status":"ok"}' ] \
   && [ "$before_true_terminal_lines" -eq "$after_true_terminal_lines" ]; then
  pass "canonical terminal reconciliation is idempotent"
else
  fail "canonical terminal reconciliation is idempotent" "rc=$CAPTURE_RC lines=$before_true_terminal_lines/$after_true_terminal_lines out=$CAPTURE_OUT"
fi

MALFORMED_TRUTH_STATUS="$TMP/malformed-truth/status.json"
MALFORMED_TRUTH_MANIFEST="$TMP/malformed-truth/events.jsonl"
mkdir -p "$(dirname "$MALFORMED_TRUTH_STATUS")"
printf '{not-json\n' > "$MALFORMED_TRUTH_STATUS"
append_event "$MALFORMED_TRUTH_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:07:30Z","run_id":"run-malformed-truth","backend":"codex"}' >/dev/null
append_event "$MALFORMED_TRUTH_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:31Z\",\"run_id\":\"run-malformed-truth\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$MALFORMED_TRUTH_STATUS\"}" >/dev/null
malformed_lines_before="$(wc -l < "$MALFORMED_TRUTH_MANIFEST" | tr -d ' ')"
capture python3 "$MANIFEST" reconcile --manifest "$MALFORMED_TRUTH_MANIFEST"
malformed_rc="$CAPTURE_RC"
malformed_lines_after="$(wc -l < "$MALFORMED_TRUTH_MANIFEST" | tr -d ' ')"

UNKNOWN_TRUTH_STATUS="$TMP/unknown-truth/status.json"
UNKNOWN_TRUTH_MANIFEST="$TMP/unknown-truth/events.jsonl"
mkdir -p "$(dirname "$UNKNOWN_TRUTH_STATUS")"
printf '{"backend":"codex","state":"future-state","exit_code":0}\n' > "$UNKNOWN_TRUTH_STATUS"
append_event "$UNKNOWN_TRUTH_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:07:40Z","run_id":"run-unknown-truth","backend":"codex"}' >/dev/null
append_event "$UNKNOWN_TRUTH_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:07:41Z\",\"run_id\":\"run-unknown-truth\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$UNKNOWN_TRUTH_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$UNKNOWN_TRUTH_MANIFEST"
unknown_terminal="$(tail -n 1 "$UNKNOWN_TRUTH_MANIFEST")"
if [ "$malformed_rc" -eq 2 ] \
   && [ "$malformed_lines_before" -eq "$malformed_lines_after" ] \
   && ! printf '%s' "$unknown_terminal" | grep -Eq '"event":"(completed|failed|timed_out|cancelled)"'; then
  pass "malformed and unknown status never fabricate provider terminal truth"
else
  fail "malformed and unknown status never fabricate provider terminal truth" "malformed_rc=$malformed_rc lines=$malformed_lines_before/$malformed_lines_after unknown=$unknown_terminal"
fi

FUTURE_TRUE_STATUS="$TMP/future-true/status.json"
FUTURE_TRUE_MANIFEST="$TMP/future-true/events.jsonl"
mkdir -p "$(dirname "$FUTURE_TRUE_STATUS")"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s"}\n' "$dead_pid" > "$FUTURE_TRUE_STATUS"
append_event "$FUTURE_TRUE_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2099-01-01T00:00:10Z","run_id":"run-future-true","backend":"codex"}' >/dev/null
append_event "$FUTURE_TRUE_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2099-01-01T00:00:11.999999Z\",\"run_id\":\"run-future-true\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$FUTURE_TRUE_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$FUTURE_TRUE_MANIFEST"
future_true_rc="$CAPTURE_RC"
capture python3 "$MANIFEST" verify --manifest "$FUTURE_TRUE_MANIFEST" --strict
future_true_terminal="$(tail -n 1 "$FUTURE_TRUE_MANIFEST")"
if [ "$future_true_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ] \
   && printf '%s' "$future_true_terminal" | grep -q '"event":"completed"'; then
  pass "reconciled provider terminal timestamp is never before agent start"
else
  fail "reconciled provider terminal timestamp is never before agent start" "reconcile_rc=$future_true_rc verify=$CAPTURE_RC/$CAPTURE_OUT terminal=$future_true_terminal"
fi

FUTURE_ORPHAN="$TMP/future-orphan/events.jsonl"
append_event "$FUTURE_ORPHAN" '{"schema_version":1,"event":"route_decided","timestamp":"2099-01-01T00:00:00Z","run_id":"run-future-orphan","backend":"codex"}' >/dev/null
append_event "$FUTURE_ORPHAN" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2099-01-01T00:00:01.999999Z\",\"run_id\":\"run-future-orphan\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$FUTURE_ORPHAN"
future_reconcile_rc="$CAPTURE_RC"
future_reconcile_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" verify --manifest "$FUTURE_ORPHAN" --strict
if [ "$future_reconcile_rc" -eq 0 ] \
   && [ "$future_reconcile_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$CAPTURE_RC" -eq 0 ]; then
  pass "reconcile never appends a terminal timestamp before a future-dated start"
else
  fail "reconcile never appends a terminal timestamp before a future-dated start" "reconcile=$future_reconcile_rc/$future_reconcile_out verify=$CAPTURE_RC/$CAPTURE_OUT"
fi

CONSERVATIVE="$TMP/conservative/events.jsonl"
sleep 5 & live_backend=$!
append_event "$CONSERVATIVE" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:08:00Z","run_id":"run-owner-live","backend":"codex"}' >/dev/null
append_event "$CONSERVATIVE" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:08:01Z\",\"run_id\":\"run-owner-live\",\"backend\":\"codex\",\"owner_pid\":$$,\"backend_handle\":\"$dead_pid\"}" >/dev/null
append_event "$CONSERVATIVE" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:08:02Z","run_id":"run-backend-live","backend":"codex"}' >/dev/null
append_event "$CONSERVATIVE" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:08:03Z\",\"run_id\":\"run-backend-live\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$live_backend\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$CONSERVATIVE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":0,"open":2,"status":"ok"}' ]; then
  pass "reconcile preserves a run when either owner or backend is live"
else
  fail "reconcile preserves a run when either owner or backend is live" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
kill "$live_backend" 2>/dev/null || true
wait "$live_backend" 2>/dev/null || true
capture python3 "$MANIFEST" reconcile --manifest "$CONSERVATIVE"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":1,"status":"ok"}' ]; then
  pass "backend-live orphan is abandoned only after its handle dies"
else
  fail "backend-live orphan is abandoned only after its handle dies" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

STALE_STATUS="$TMP/stale-running-status.json"
printf '{"state":"running"}\n' > "$STALE_STATUS"
STALE_STATUS_MANIFEST="$TMP/stale-status/events.jsonl"
append_event "$STALE_STATUS_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:09:00Z","run_id":"run-stale-status","backend":"codex"}' >/dev/null
append_event "$STALE_STATUS_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:09:01Z\",\"run_id\":\"run-stale-status\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"$dead_pid\",\"status_path\":\"$STALE_STATUS\"}" >/dev/null
capture python3 "$MANIFEST" reconcile --manifest "$STALE_STATUS_MANIFEST"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '{"abandoned":1,"open":0,"status":"ok"}' ]; then
  pass "stale running status cannot override failed owner and backend-handle probes"
else
  fail "stale running status cannot override failed owner and backend-handle probes" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

DELETED_STATUS="$TMP/deleted-status.json"
printf '{"state":"running"}\n' > "$DELETED_STATUS"
DELETED_STATUS_MANIFEST="$TMP/deleted-status/events.jsonl"
append_event "$DELETED_STATUS_MANIFEST" '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:10:00Z","run_id":"run-deleted-status","backend":"codex"}' >/dev/null
append_event "$DELETED_STATUS_MANIFEST" "{\"schema_version\":1,\"event\":\"agent_started\",\"timestamp\":\"2026-07-10T00:10:01Z\",\"run_id\":\"run-deleted-status\",\"backend\":\"codex\",\"owner_pid\":$dead_pid,\"backend_handle\":\"provider-job-123\",\"status_path\":\"$DELETED_STATUS\"}" >/dev/null
rm -f "$DELETED_STATUS"
capture python3 "$MANIFEST" reconcile --manifest "$DELETED_STATUS_MANIFEST"
deleted_reconcile_rc="$CAPTURE_RC"
deleted_reconcile_out="$CAPTURE_OUT"
capture python3 "$MANIFEST" verify --manifest "$DELETED_STATUS_MANIFEST" --strict
if [ "$deleted_reconcile_rc" -eq 0 ] \
   && [ "$deleted_reconcile_out" = '{"abandoned":1,"open":0,"status":"ok"}' ] \
   && [ "$CAPTURE_RC" -eq 0 ]; then
  pass "deleted opaque-backend status is unavailable evidence, not a recovery wedge"
else
  fail "deleted opaque-backend status is unavailable evidence, not a recovery wedge" "reconcile=$deleted_reconcile_rc/$deleted_reconcile_out verify=$CAPTURE_RC/$CAPTURE_OUT"
fi

printf '\nrun-manifest: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
