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
STATUS_REAL="$(python3 -I -B -c 'import os,sys; print(os.path.realpath(sys.argv[1]),end="")' "$STATUS")"
MANIFEST="$TMP/run/.agent-state-$(id -u)/agent-lifecycle.jsonl"
TEST_OWNER_IDENTITY="$(_uberdev_agent_process_identity "$$")"
terminal_manifest() {
  local terminal="$1"
  printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
  printf '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >>"$MANIFEST"
  printf '{"schema_version":1,"event":"%s","timestamp":"2026-07-10T00:00:02.000Z","run_id":"worker-0001"}\n' "$terminal" >>"$MANIFEST"
}
printf 'completed result\n' >"$RESULT"; printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest completed
uberdev_wait_child "$STATUS" "$RESULT" 2 >/dev/null
uberdev_unwind_child "$STATUS" "$RESULT" 2

# A terminal manifest event is not sufficient success evidence while the exact
# lifecycle lease remains present. Wait until watcher finalization releases it.
TERMINAL_GENERATION=11111111111111111111111111111111
TERMINAL_LEASE_DIR="$TMP/run/.agent-state-$(id -u)/semaphore-v1/$(printf 'e%.0s' {1..64}).scope"
TERMINAL_LEASE="$TERMINAL_LEASE_DIR/${TERMINAL_GENERATION}$(printf 'f%.0s' {1..32}).lease"
mkdir -p "$TERMINAL_LEASE_DIR"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321","lease_generation":"%s"}\n' \
  "$TERMINAL_GENERATION" >"$STATUS"
terminal_manifest completed
printf 'version=1\ngeneration=%s\nrun_id=worker-0001\nowner_pid=%s\nowner_identity=%s\nbackend_handle=321\nbackend_identity=\nstart_epoch=1\ntimeout_s=30\nstatus_path=%s\n' \
  "$TERMINAL_GENERATION" "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >"$TERMINAL_LEASE"
chmod 600 "$TERMINAL_LEASE"
( sleep .2; rm -f "$TERMINAL_LEASE" ) & TERMINAL_RELEASE_PID=$!
set +e
uberdev_wait_child "$STATUS" "$RESULT" 2 >/dev/null
TERMINAL_WAIT_RC=$?
[ -e "$TERMINAL_LEASE" ]
TERMINAL_LEASE_RETAINED=$?
wait "$TERMINAL_RELEASE_PID"
set -e
[ "$TERMINAL_WAIT_RC" -eq 0 ]
[ "$TERMINAL_LEASE_RETAINED" -ne 0 ]
rmdir "$TERMINAL_LEASE_DIR"

# Terminal proof fails closed on a malformed lease entry instead of skipping it
# and reporting capacity as released. The diagnostic names only the bounded
# lease path; it never echoes attacker-controlled lease bytes.
MALFORMED_SCOPE="$TMP/run/.agent-state-$(id -u)/semaphore-v1/$(printf 'a%.0s' {1..64}).scope"
MALFORMED_LEASE="$MALFORMED_SCOPE/$(printf 'b%.0s' {1..64}).lease"
MALFORMED_LEASE_REAL="$(python3 -I -B -c 'import os,sys; print(os.path.realpath(sys.argv[1]),end="")' "$MALFORMED_LEASE")"
mkdir -p "$MALFORMED_SCOPE"
printf 'run_id=worker-0001\nstatus_path=%s\ngeneration=bad\n' "$STATUS" >"$MALFORMED_LEASE"
set +e
MALFORMED_LEASE_ERROR="$(_uberdev_child_terminal_lease_proof "$STATUS" 2>&1)"
MALFORMED_LEASE_RC=$?
set -e
[ "$MALFORMED_LEASE_RC" -ne 0 ]
printf '%s\n' "$MALFORMED_LEASE_ERROR" | grep -Fq "invalid lifecycle lease: $MALFORMED_LEASE_REAL"
! printf '%s\n' "$MALFORMED_LEASE_ERROR" | grep -Fq 'generation=bad'
rm -f "$MALFORMED_LEASE"; rmdir "$MALFORMED_SCOPE"

: >"$RESULT"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf x >"$RESULT"; printf '{bad\n' >"$STATUS"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"completed","exit_code":1,"pid":"321"}\n' >"$STATUS"; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"failed","exit_code":1,"pid":"321"}\n' >"$STATUS"; terminal_manifest failed; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest failed; ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1

# The status boundary has a closed backend enum and validates optional process
# identity / lease-generation fields before timeout or cancellation logic.
for malformed_status in \
  '{"backend":"unknown","state":"running","exit_code":null,"pid":"321"}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","process_identity":7}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","process_identity":"321|321|321|short"}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","lease_generation":9}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","lease_generation":"xyz"}'; do
  printf '%s\n' "$malformed_status" >"$STATUS"
  set +e
  uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
  MALFORMED_STATUS_RC=$?
  set -e
  [ "$MALFORMED_STATUS_RC" -eq 2 ]
done
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321","process_identity":"321|321|321|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","lease_generation":"0123456789abcdef0123456789abcdef"}\n' >"$STATUS"
terminal_manifest completed
uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null

# A detached watcher supervisory failure is actionable immediately. The
# waiting caller receives the specific class instead of timing out generically.
printf '{"backend":"claude-bg","state":"running","exit_code":null,"pid":"abc12345"}\n' >"$STATUS"
printf '{"schema_version":1,"error":"provider_probe_failed","backend":"claude-bg","handle":"abc12345","terminal":"provider_probe_failed","attempts":3}\n' >"$STATUS.watcher-error.json"
chmod 600 "$STATUS.watcher-error.json"
set +e
WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
WATCHER_WAIT_RC=$?
set -e
[ "$WATCHER_WAIT_RC" -eq 70 ]
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'provider supervision failed: provider_probe_failed'
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'backend=claude-bg; capacity=retained'
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'action=resolve the retained Claude session or retry with Codex'
rm -f "$STATUS.watcher-error.json"

# Owner identity capture is a launch-time supervisory failure with no reserved
# capacity. Exercise the exact producer helper and public waiter together so
# the writer and reader cannot silently drift on reason or attempt count.
rm -f "$STATUS" "$STATUS.watcher-error.json"
OWNER_CAPTURE_FALLBACK="$TMP/run/.agent-state-$(id -u)/worker-0001.watcher-error.json"
_uberdev_agent_fail_owner_capture "$STATUS" "$OWNER_CAPTURE_FALLBACK" codex
set +e
WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
WATCHER_WAIT_RC=$?
set -e
[ "$WATCHER_WAIT_RC" -eq 70 ]
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq \
  'provider supervision failed: owner_process_identity_unavailable'
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'backend=codex; capacity=not-reserved'
rm -f "$STATUS.watcher-error.json"

# The detached numeric-process watcher emits a distinct durable record when
# its kernel identity probe remains indeterminate. Exercise the producer and
# the public waiter together so their closed schemas cannot drift apart.
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"321"}\n' >"$STATUS"
_uberdev_agent_persist_watcher_error "$STATUS" codex 321 \
  process_identity_probe_unavailable 3
set +e
WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
WATCHER_WAIT_RC=$?
set -e
[ "$WATCHER_WAIT_RC" -eq 70 ]
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq \
  'provider supervision failed: process_identity_probe_failed'
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'capacity=retained'
rm -f "$STATUS.watcher-error.json"

# Timeout-capability recovery failures use their own closed supervisory phase.
# The waiter must surface them as retained-capacity failures rather than a
# generic terminal-finalization error.
_uberdev_agent_persist_watcher_error "$STATUS" codex 321 \
  timeout_intent_recovery_failed 1 '' timeout_intent_identity_unavailable
set +e
WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
WATCHER_WAIT_RC=$?
set -e
[ "$WATCHER_WAIT_RC" -eq 70 ]
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq \
  'provider supervision failed: timeout_intent_identity_unavailable'
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'capacity=retained'
rm -f "$STATUS.watcher-error.json"

# Timeout coordination is a short-lived waiter capability, not a same-handle
# flag. The marker binds the exact status snapshot and lease generation to one
# live waiter identity, and stale variants are classified without suppressing
# provider terminalization.
INTENT_GENERATION=1234567890abcdef1234567890abcdef
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"321","lease_generation":"%s"}\n' \
  "$INTENT_GENERATION" >"$STATUS"
INTENT_SNAPSHOT="$(shasum -a 256 "$STATUS" | awk '{print $1}')"
_uberdev_child_timeout_intent_write "$STATUS" 321 "$INTENT_GENERATION" "$INTENT_SNAPSHOT"
INTENT_PATH="$STATUS.timeout-intent-v1"
python3 -I -B - "$INTENT_PATH" <<'PY'
import json,re,sys,time
value=json.load(open(sys.argv[1]))
assert set(value)=={'schema_version','handle','lease_generation','snapshot_sha256','waiter_pid','waiter_process_identity','expires_epoch'},value
assert value['schema_version']==1 and value['handle']=='321'
assert re.fullmatch(r'[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}',value['waiter_process_identity'])
assert value['waiter_process_identity'].split('|',1)[0]==str(value['waiter_pid'])
assert int(time.time()) < value['expires_epoch'] <= int(time.time())+60
PY
[ "$(_uberdev_agent_timeout_intent_probe "$STATUS" 321 "$INTENT_GENERATION")" = valid ]

intent_mutate() {
  python3 -I -B - "$INTENT_PATH" "$1" <<'PY'
import json,sys
path,mode=sys.argv[1:]
value=json.load(open(path))
if mode=='expired': value['expires_epoch']=1
elif mode=='generation': value['lease_generation']='f'*32
elif mode=='snapshot': value['snapshot_sha256']='e'*64
elif mode=='orphan':
 value['waiter_pid']=999999
 value['waiter_process_identity']='999999|999999|999999|'+'d'*64
elif mode=='stale': value['waiter_process_identity']=value['waiter_process_identity'][:-64]+'c'*64
else: raise AssertionError(mode)
with open(path,'w') as stream: json.dump(value,stream,separators=(',',':'))
PY
}
for INTENT_STALE_CASE in expired generation snapshot orphan stale; do
  _uberdev_child_timeout_intent_remove "$STATUS"
  _uberdev_child_timeout_intent_write "$STATUS" 321 "$INTENT_GENERATION" "$INTENT_SNAPSHOT"
  intent_mutate "$INTENT_STALE_CASE"
  set +e
  INTENT_STALE_RESULT="$(_uberdev_agent_timeout_intent_probe "$STATUS" 321 "$INTENT_GENERATION")"
  INTENT_STALE_RC=$?
  set -e
  [ "$INTENT_STALE_RC" -eq 3 ]
  [ "$INTENT_STALE_RESULT" = "$INTENT_STALE_CASE" ]
done
printf '{bad\n' >"$INTENT_PATH"
set +e
INTENT_INVALID_RESULT="$(_uberdev_agent_timeout_intent_probe "$STATUS" 321 "$INTENT_GENERATION")"
INTENT_INVALID_RC=$?
set -e
[ "$INTENT_INVALID_RC" -eq 2 ]
[ "$INTENT_INVALID_RESULT" = invalid ]
rm -f "$INTENT_PATH"

# Producer-shaped cancellation and lease-acquisition failures carry a bounded
# reason. The child reports that reason without rejecting the closed schema.
for watcher_reason in provider_cancel_unconfirmed lease_acquire_rollback_failed; do
  if [ "$watcher_reason" = provider_cancel_unconfirmed ]; then
    watcher_payload="{\"schema_version\":1,\"error\":\"provider_cancel_failed\",\"backend\":\"claude-bg\",\"handle\":\"abc12345\",\"terminal\":\"blocked:permission\",\"attempts\":3,\"reason\":\"$watcher_reason\"}"
  else
    watcher_payload="{\"schema_version\":1,\"error\":\"launch_finalize_failed\",\"backend\":\"codex\",\"handle\":\"\",\"terminal\":\"launch:lease_identity\",\"attempts\":3,\"reason\":\"$watcher_reason\"}"
  fi
  printf '%s\n' "$watcher_payload" >"$STATUS.watcher-error.json"
  chmod 600 "$STATUS.watcher-error.json"
  set +e
  WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
  WATCHER_WAIT_RC=$?
  set -e
  [ "$WATCHER_WAIT_RC" -eq 70 ]
  printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq "provider supervision failed: ${watcher_reason}"
  printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'capacity=retained'
done
rm -f "$STATUS.watcher-error.json"

# If the child status directory becomes unwritable, the detached watcher uses
# the independently monitored controller-state fallback for the same union.
WATCHER_FALLBACK="$TMP/run/.agent-state-$(id -u)/worker-0001.watcher-error.json"
printf '{"schema_version":1,"error":"provider_probe_failed","backend":"claude-bg","handle":"abc12345","terminal":"provider_probe_failed","attempts":3}\n' >"$WATCHER_FALLBACK"
chmod 600 "$WATCHER_FALLBACK"
set +e
WATCHER_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
WATCHER_WAIT_RC=$?
set -e
[ "$WATCHER_WAIT_RC" -eq 70 ]
printf '%s\n' "$WATCHER_WAIT_ERROR" | grep -Fq 'provider supervision failed: provider_probe_failed'
rm -f "$WATCHER_FALLBACK"

for malformed_watcher_error in \
  '{"schema_version":1,"error":"provider_probe_failed","backend":"unknown","handle":"abc12345","terminal":"provider_probe_failed","attempts":3}' \
  '{"schema_version":1,"error":"provider_probe_failed","backend":"claude-bg","handle":"","terminal":"provider_probe_failed","attempts":3}' \
  '{"schema_version":1,"error":"provider_probe_failed","backend":"claude-bg","handle":"abc12345","terminal":"provider_probe_failed","attempts":0}' \
  '{"schema_version":1,"error":"provider_probe_failed","backend":"claude-bg","handle":"abc12345","terminal":"failed","attempts":3}' \
  '{"schema_version":1,"error":"provider_cancel_failed","backend":"claude-bg","handle":"abc12345","terminal":"provider_probe_failed","attempts":3}' \
  '{"schema_version":1,"error":"terminal_finalize_failed","backend":"codex","handle":"321","terminal":"failed","attempts":1,"reason":"owner_process_identity_unavailable"}' \
  '{"schema_version":1,"error":"provider_cancel_failed","backend":"claude-bg","handle":"abc12345","terminal":"blocked:permission","attempts":3,"reason":"not-in-the-closed-enum"}'; do
  printf '%s\n' "$malformed_watcher_error" >"$STATUS.watcher-error.json"
  chmod 600 "$STATUS.watcher-error.json"
  set +e
  INVALID_WATCHER_OUTPUT="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
  INVALID_WATCHER_RC=$?
  set -e
  if [ "$INVALID_WATCHER_RC" -ne 2 ] \
      || ! printf '%s\n' "$INVALID_WATCHER_OUTPUT" | grep -Fq 'invalid-supervisory-record' \
      || ! printf '%s\n' "$INVALID_WATCHER_OUTPUT" | grep -Fq "$STATUS.watcher-error.json" \
      || printf '%s\n' "$INVALID_WATCHER_OUTPUT" | grep -Fq 'schema_version'; then
    echo "child wait did not surface a bounded invalid-supervisory-record diagnostic" >&2
    exit 1
  fi
done
rm -f "$STATUS.watcher-error.json"

printf '{bad\n' >"$WATCHER_FALLBACK"
chmod 600 "$WATCHER_FALLBACK"
set +e
INVALID_WATCHER_OUTPUT="$(uberdev_wait_child "$STATUS" "$RESULT" 10 2>&1)"
INVALID_WATCHER_RC=$?
set -e
[ "$INVALID_WATCHER_RC" -eq 2 ]
printf '%s\n' "$INVALID_WATCHER_OUTPUT" | grep -Fq 'invalid-supervisory-record'
printf '%s\n' "$INVALID_WATCHER_OUTPUT" | grep -Fq "$WATCHER_FALLBACK"
rm -f "$WATCHER_FALLBACK"

# Reviewer results are validated at one deterministic boundary. In particular,
# a parseable APPROVE document may not carry blocker evidence.
VALID_REVIEW="$TMP/run/children/worker-0001/valid-review.md"
REJECT_REVIEW="$TMP/run/children/worker-0001/reject-review.md"
INVALID_REVIEW="$TMP/run/children/worker-0001/invalid-review.md"
EMPTY_REVIEW="$TMP/run/children/worker-0001/empty-review.md"
ADVISORY_ONE_REVIEW="$TMP/run/children/worker-0001/advisory-one-review.md"
ADVISORY_MULTI_REVIEW="$TMP/run/children/worker-0001/advisory-multi-review.md"
NULL_FINDINGS_REVIEW="$TMP/run/children/worker-0001/null-findings-review.md"
INVALID_SCALAR_REVIEW="$TMP/run/children/worker-0001/invalid-scalar-review.md"
DRIVE_RELATIVE_REVIEW="$TMP/run/children/worker-0001/drive-relative-review.md"
DRIVE_QUALIFIED_REVIEW="$TMP/run/children/worker-0001/drive-qualified-review.md"
BLOCK_SCALAR_REVIEW="$TMP/run/children/worker-0001/block-scalar-review.md"
ESCAPED_NEWLINE_REVIEW="$TMP/run/children/worker-0001/escaped-newline-review.md"
ESCAPED_NUL_REVIEW="$TMP/run/children/worker-0001/escaped-nul-review.md"
QUOTED_LEADING_SPACE_REVIEW="$TMP/run/children/worker-0001/quoted-leading-space-review.md"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'findings:' \
  '  - severity: blocker' '    location: tests/example.test.sh:1' \
  '    summary: bounded summary' '    detail: bounded detail' \
  'confidence: high' '```' >"$VALID_REVIEW"
printf '%s\n' '```yaml' 'verdict: REJECT' 'findings:' \
  '  - severity: blocker' '    location: tests/example.test.sh:1' \
  '    summary: bounded rejection' '    detail: bounded blocker detail' \
  'confidence: high' '```' >"$REJECT_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: blocker' '    location: tests/example.test.sh:1' \
  '    summary: contradictory summary' '    detail: contradictory detail' \
  'confidence: high' '```' >"$INVALID_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' \
  'confidence: high' '```' >"$EMPTY_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: one advisory finding' '    detail: bounded advisory detail' \
  'confidence: high' '```' >"$ADVISORY_ONE_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: first advisory finding' '    detail: first bounded detail' \
  '  - severity: suggestion' '    location: tests/example.test.sh:2' \
  '    summary: second advisory finding' '    detail: second bounded detail' \
  'confidence: medium' '```' >"$ADVISORY_MULTI_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  'confidence: high' '```' >"$NULL_FINDINGS_REVIEW"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: invalid: plain scalar' '    detail: bounded detail' \
  'confidence: high' '```' >"$INVALID_SCALAR_REVIEW"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'findings:' \
  '  - severity: suggestion' '    location: C:relative/path.ts:1' \
  '    summary: invalid drive-relative location' '    detail: bounded detail' \
  'confidence: high' '```' >"$DRIVE_RELATIVE_REVIEW"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'findings:' \
  '  - severity: suggestion' '    location: C:/repo/path.ts:1' \
  '    summary: invalid drive-qualified location' '    detail: bounded detail' \
  'confidence: high' '```' >"$DRIVE_QUALIFIED_REVIEW"
printf '%s\n' '```yaml' 'verdict: REVISIONS_REQUIRED' 'findings:' \
  '  - severity: blocker' '    location: tests/example.test.sh:1' \
  '    summary: block scalar is outside the documented grammar' '    detail: |' \
  '      multiple physical lines are rejected' \
  'confidence: high' '```' >"$BLOCK_SCALAR_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: "escaped\nnewline"' '    detail: bounded detail' \
  'confidence: high' '```' >"$ESCAPED_NEWLINE_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: "escaped\u0000nul"' '    detail: bounded detail' \
  'confidence: high' '```' >"$ESCAPED_NUL_REVIEW"
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
  '  - severity: suggestion' '    location: tests/example.test.sh:1' \
  '    summary: " leading space"' '    detail: bounded detail' \
  'confidence: high' '```' >"$QUOTED_LEADING_SPACE_REVIEW"
uberdev_child_validate_phase1_review_result "$VALID_REVIEW"
uberdev_child_validate_phase1_review_result "$REJECT_REVIEW"
uberdev_child_validate_phase1_review_result "$EMPTY_REVIEW"
uberdev_child_validate_phase1_review_result "$ADVISORY_ONE_REVIEW"
uberdev_child_validate_phase1_review_result "$ADVISORY_MULTI_REVIEW"
! uberdev_child_validate_phase1_review_result "$INVALID_REVIEW"
! uberdev_child_validate_phase1_review_result "$NULL_FINDINGS_REVIEW"
! uberdev_child_validate_phase1_review_result "$INVALID_SCALAR_REVIEW"
! uberdev_child_validate_phase1_review_result "$DRIVE_RELATIVE_REVIEW"
! uberdev_child_validate_phase1_review_result "$DRIVE_QUALIFIED_REVIEW"
! uberdev_child_validate_phase1_review_result "$BLOCK_SCALAR_REVIEW"
! uberdev_child_validate_phase1_review_result "$ESCAPED_NEWLINE_REVIEW"
! uberdev_child_validate_phase1_review_result "$ESCAPED_NUL_REVIEW"
! uberdev_child_validate_phase1_review_result "$QUOTED_LEADING_SPACE_REVIEW"

# Workspace metadata is a closed union whenever a provider reports it. Caller
# mode has one absolute execution directory and no branch; isolated mode has
# one absolute worktree and a non-empty dispatcher branch.
for malformed_workspace_status in \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","workspace_mode":"unknown","worktree":"/tmp/work","branch":"branch"}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","workspace_mode":"caller","worktree":"relative","branch":""}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","workspace_mode":"caller","worktree":"/tmp/work","branch":"unexpected"}' \
  '{"backend":"codex","state":"running","exit_code":null,"pid":"321","workspace_mode":"isolated","worktree":"/tmp/work","branch":""}'; do
  printf '%s\n' "$malformed_workspace_status" >"$STATUS"
  ! uberdev_wait_child "$STATUS" "$RESULT" 1 >/dev/null 2>&1
done

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

# Native Windows numeric identities do not carry verifiable POSIX process
# group/session authority. Model that OS class on every CI host and prove
# cancellation fails before even consulting the POSIX ownership probe.
eval "$(declare -f _uberdev_dispatch_os_class | sed '1s/_uberdev_dispatch_os_class/_real_cancel_os_class/')"
eval "$(declare -f _uberdev_dispatch_owned_group_state | sed '1s/_uberdev_dispatch_owned_group_state/_real_cancel_owned_group_state/')"
WINDOWS_CANCEL_PROBE="$TMP/windows-cancel-posix-probe"
_uberdev_dispatch_os_class() { printf 'windows-native'; }
_uberdev_dispatch_owned_group_state() { : >"$WINDOWS_CANCEL_PROBE"; return 1; }
set +e
_uberdev_dispatch_cancel_backend background 4242 \
  '4242|4242|4242|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
WINDOWS_CANCEL_RC=$?
set -e
[ "$WINDOWS_CANCEL_RC" -eq 2 ]
[ "$_UBERDEV_DISPATCH_CANCEL_REASON" = provider_cancel_unconfirmed ]
[ ! -e "$WINDOWS_CANCEL_PROBE" ]
eval "$(declare -f _real_cancel_os_class | sed '1s/_real_cancel_os_class/_uberdev_dispatch_os_class/')"
eval "$(declare -f _real_cancel_owned_group_state | sed '1s/_real_cancel_owned_group_state/_uberdev_dispatch_owned_group_state/')"

# PID/group reuse defense: launch an owned session whose wrapper has a live
# provider child. Wrong identity is rejected; exact cancellation proves the
# complete group is gone, not merely the wrapper.
python3 -I -c 'import os; os.setsid(); os.execvp("bash",["bash","-c","sleep 30 & wait"])' & PID_GUARD=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do PROVIDER_CHILD="$(pgrep -P "$PID_GUARD" | head -1 || true)"; [ -z "$PROVIDER_CHILD" ] || break; sleep .1; done
[ -n "$PROVIDER_CHILD" ] && kill -0 "$PROVIDER_CHILD"
IDENTITY="$(_uberdev_agent_process_identity "$PID_GUARD")"
! _uberdev_dispatch_cancel_backend codex "$PID_GUARD" 'reused-group-identity'
kill -0 "$PID_GUARD"
kill -0 "$PROVIDER_CHILD"
_uberdev_dispatch_cancel_backend codex "$PID_GUARD" "$IDENTITY"
! kill -0 "$PID_GUARD" 2>/dev/null
! kill -0 "$PROVIDER_CHILD" 2>/dev/null

# A provider descendant may deliberately ignore TERM. Cancellation escalates
# only after revalidating the exact owned process group/session, then proves no
# non-zombie members remain. A mismatched launch identity never signals either
# the wrapper or its resistant child.
python3 -I -c 'import os; os.setsid(); os.execvp("bash",["bash","-c","trap \"\" TERM; (trap \"\" TERM; while :; do :; done) & wait"])' & TERM_GUARD=$!
disown "$TERM_GUARD" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do TERM_CHILD="$(pgrep -P "$TERM_GUARD" | head -1 || true)"; [ -z "$TERM_CHILD" ] || break; done
[ -n "$TERM_CHILD" ] && kill -0 "$TERM_CHILD"
TERM_IDENTITY="$(_uberdev_agent_process_identity "$TERM_GUARD")"
! _uberdev_dispatch_cancel_backend background "$TERM_GUARD" "${TERM_IDENTITY%|*}|reused"
kill -0 "$TERM_GUARD" && kill -0 "$TERM_CHILD"
_uberdev_dispatch_cancel_backend background "$TERM_GUARD" "$TERM_IDENTITY"
! _uberdev_dispatch_group_live "$TERM_GUARD"
! kill -0 "$TERM_GUARD" 2>/dev/null
! kill -0 "$TERM_CHILD" 2>/dev/null

# Kernel identity uncertainty is not equivalent to proven process absence.
# Even if a numeric process group appears live, cancellation must fail closed
# before invoking TERM or KILL when the exact creation identity cannot be read.
eval "$(declare -f _uberdev_agent_process_identity | sed '1s/_uberdev_agent_process_identity/_real_unavailable_cancel_identity/')"
eval "$(declare -f _uberdev_dispatch_group_owned_session | sed '1s/_uberdev_dispatch_group_owned_session/_real_unavailable_cancel_group/')"
UNAVAILABLE_CANCEL_SIGNAL="$TMP/unavailable-cancel-signal"
_uberdev_agent_process_identity() { return 2; }
_uberdev_dispatch_group_owned_session() { return 0; }
kill() { : >"$UNAVAILABLE_CANCEL_SIGNAL"; return 0; }
set +e
_uberdev_dispatch_cancel_backend codex 4242 \
  '4242|4242|4242|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
UNAVAILABLE_CANCEL_RC=$?
set -e
unset -f kill
eval "$(declare -f _real_unavailable_cancel_identity | sed '1s/_real_unavailable_cancel_identity/_uberdev_agent_process_identity/')"
eval "$(declare -f _real_unavailable_cancel_group | sed '1s/_real_unavailable_cancel_group/_uberdev_dispatch_group_owned_session/')"
[ "$UNAVAILABLE_CANCEL_RC" -eq 2 ]
[ ! -e "$UNAVAILABLE_CANCEL_SIGNAL" ]

# Exact post-death partial cleanup never follows or removes attacker-controlled
# symlink/hardlink targets. It fails closed without globbing sibling files.
printf 'victim\n' >"$TMP/victim"
ln -s "$TMP/victim" "${RESULT}.partial.991"
! _uberdev_dispatch_cleanup_dead_partial_result "$RESULT" 991 >/dev/null 2>&1
[ "$(cat "$TMP/victim")" = victim ]
rm -f "${RESULT}.partial.991"
ln "$TMP/victim" "${RESULT}.partial.992"
! _uberdev_dispatch_cleanup_dead_partial_result "$RESULT" 992 >/dev/null 2>&1
[ "$(cat "$TMP/victim")" = victim ]
rm -f "${RESULT}.partial.992"

# A precreated private zero-byte status target is the normal delayed-wrapper
# race and must be atomically canonicalized, not parsed as malformed JSON.
ZERO_STATUS="$TMP/run/children/worker-0001/zero-status.json"
( umask 077; : >"$ZERO_STATUS" )
_uberdev_agent_publish_status "$ZERO_STATUS" codex 999 running '' create \
  '999|999|999|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  0123456789abcdef0123456789abcdef
python3 - "$ZERO_STATUS" <<'PY'
import json,stat,os,sys
s=json.load(open(sys.argv[1])); assert s['state']=='running' and s['pid']=='999' and s['lease_generation']=='0123456789abcdef0123456789abcdef'
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o600
PY

# A crashed transition owner cannot orphan the kernel-released status lock.
# The production writer blocks while the owner is live, then completes after
# the owner dies without deleting or repairing the persistent lock file.
LOCK_READY="$TMP/transition-lock.ready"
LOCK_RESULT="$TMP/transition-lock.writer-rc"
python3 -I -B - "$ZERO_STATUS.transition-lock-v2" "$LOCK_READY" <<'PY' &
import fcntl,os,sys,time
lock_path,ready_path=sys.argv[1:]
descriptor=os.open(lock_path,os.O_RDWR|os.O_CREAT,0o600)
fcntl.flock(descriptor,fcntl.LOCK_EX)
with open(ready_path,'w',encoding='utf-8') as ready:
 ready.write('ready\n'); ready.flush(); os.fsync(ready.fileno())
while True: time.sleep(60)
PY
LOCK_OWNER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$LOCK_READY" ] && break; sleep .1; done
[ -s "$LOCK_READY" ]
(
  set +e
  _uberdev_agent_publish_status "$ZERO_STATUS" codex 999 completed 0 replace \
    '999|999|999|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    0123456789abcdef0123456789abcdef
  printf '%s\n' "$?" >"$LOCK_RESULT"
) & LOCK_WRITER_PID=$!
sleep .1
[ ! -e "$LOCK_RESULT" ]
kill -KILL "$LOCK_OWNER_PID"
set +e
wait "$LOCK_OWNER_PID"
LOCK_OWNER_RC=$?
set -e
[ "$LOCK_OWNER_RC" -ne 0 ]
wait "$LOCK_WRITER_PID"
[ "$(cat "$LOCK_RESULT")" -eq 0 ]
grep -q '"state":"completed"' "$ZERO_STATUS"

# Opaque Claude sessions cancel through an explicit provider capability hook
# and require an absent/terminal probe, never a fabricated local state.
mkdir "$TMP/bin"; printf '[{"sessionId":"abc12345-full","state":"running"}]\n' >"$TMP/claude-state"
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2 $3" = 'agents --all --json' ]; then cat "$CLAUDE_STATE"; exit 0; fi
exit 2
SH
chmod +x "$TMP/bin/claude"
_uberdev_dispatch_cancel_claude_bg() { printf '[]\n' >"$CLAUDE_STATE"; }
CLAUDE_STATE="$TMP/claude-state" PATH="$TMP/bin:$PATH" _uberdev_dispatch_cancel_backend claude-bg abc12345 ''

# An unavailable or failed Claude cancellation hook must make timeout handling
# fail closed before mutating status, manifest, or the live lease.
_uberdev_dispatch_cancel_claude_bg() {
  _UBERDEV_DISPATCH_CANCEL_REASON=provider_stop_failed
  return 2
}
GENERATION=abcdef0123456789abcdef0123456789
printf '{"backend":"claude-bg","state":"running","exit_code":null,"pid":"unsupported-session","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
LEASE_DIR="$TMP/run/.agent-state-$(id -u)/semaphore-v1/$(printf '9%.0s' {1..64}).scope"; mkdir -p "$LEASE_DIR"
LEASE="$LEASE_DIR/${GENERATION}$(printf '8%.0s' {1..32}).lease"
printf 'version=1\ngeneration=%s\nrun_id=worker-0001\nowner_pid=%s\nowner_identity=%s\nbackend_handle=unsupported-session\nbackend_identity=\nstart_epoch=1\ntimeout_s=30\nstatus_path=%s\n' \
  "$GENERATION" "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >"$LEASE"
chmod 600 "$LEASE"
STATUS_SHA="$(shasum -a 256 "$STATUS" | awk '{print $1}')"
MANIFEST_SHA="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
LEASE_SHA="$(shasum -a 256 "$LEASE" | awk '{print $1}')"
set +e
UNSUPPORTED_CANCEL_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 1 2>&1)"
WAIT_RC=$?
set -e
[ "$WAIT_RC" -eq 2 ]
[ "$WAIT_RC" -ne 124 ]
printf '%s\n' "$UNSUPPORTED_CANCEL_ERROR" | grep -Fq \
  'provider cancellation failed: backend=claude-bg handle=unsupported-session reason=provider_stop_failed capacity=retained'
[ "$(shasum -a 256 "$STATUS" | awk '{print $1}')" = "$STATUS_SHA" ]
[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" = "$MANIFEST_SHA" ]
[ -f "$LEASE" ] && [ "$(shasum -a 256 "$LEASE" | awk '{print $1}')" = "$LEASE_SHA" ]

# Provider completion may win after the running snapshot but before the timeout
# path can find its lease. Re-probing the changed snapshot must observe the real
# terminal instead of reporting a supervisory failure.
eval "$(declare -f _uberdev_child_find_lease | sed '1s/_uberdev_child_find_lease/_real_child_find_lease/')"
printf 'race result\n' >"$RESULT"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"777","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
printf 'run_id=worker-0001\nstatus_path=%s\ngeneration=%s\n' "$STATUS" "$GENERATION" >"$LEASE"
_uberdev_child_find_lease() {
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"777","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
  terminal_manifest completed
  rm -f "$LEASE"
  return 2
}
uberdev_wait_child "$STATUS" "$RESULT" 1
eval "$(declare -f _real_child_find_lease | sed '1s/_real_child_find_lease/_uberdev_child_find_lease/')"

# The same completion race can land while cancellation is being attempted.
# A changed status snapshot wins; timeout must not overwrite it or retain the
# obsolete lease.
eval "$(declare -f _uberdev_agent_lease_identity | sed '1s/_uberdev_agent_lease_identity/_real_agent_lease_identity/')"
eval "$(declare -f _uberdev_dispatch_cancel_backend | sed '1s/_uberdev_dispatch_cancel_backend/_real_dispatch_cancel_backend/')"
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"778","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
printf 'run_id=worker-0001\nstatus_path=%s\ngeneration=%s\n' "$STATUS_REAL" "$GENERATION" >"$LEASE"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
_uberdev_agent_lease_identity() { printf 'fixture-identity'; }
_uberdev_dispatch_cancel_backend() {
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"778","lease_generation":"%s"}\n' "$GENERATION" >"$STATUS"
  terminal_manifest completed
  rm -f "$LEASE"
  return 2
}
uberdev_wait_child "$STATUS" "$RESULT" 1
eval "$(declare -f _real_agent_lease_identity | sed '1s/_real_agent_lease_identity/_uberdev_agent_lease_identity/')"
eval "$(declare -f _real_dispatch_cancel_backend | sed '1s/_real_dispatch_cancel_backend/_uberdev_dispatch_cancel_backend/')"

# CAS cannot overwrite a provider completion that wins the timeout race.
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"777","lease_generation":"0123456789abcdef0123456789abcdef"}\n' >"$STATUS"
OLD_SHA="$(shasum -a 256 "$STATUS" | awk '{print $1}')"
printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"777","lease_generation":"0123456789abcdef0123456789abcdef"}\n' >"$STATUS"
! _uberdev_child_timeout_cas "$STATUS" "$OLD_SHA" 777 0123456789abcdef0123456789abcdef >/dev/null 2>&1
grep -q '"state":"completed"' "$STATUS"

# Deterministically exercise both timeout/completion winner orderings through
# the public wait path. Each winner must converge status, exactly one terminal
# manifest event, and the exact lifecycle lease without test-side cleanup.
RACE_GENERATION=0123456789abcdef0123456789abcdef
RACE_SCOPE="$TMP/run/.agent-state-$(id -u)/semaphore-v1/$(printf 'c%.0s' {1..64}).scope"
RACE_LEASE="$RACE_SCOPE/${RACE_GENERATION}$(printf 'd%.0s' {1..32}).lease"
mkdir -p "$RACE_SCOPE"
eval "$(declare -f _uberdev_dispatch_cancel_backend | sed '1s/_uberdev_dispatch_cancel_backend/_race_real_cancel_backend/')"
eval "$(declare -f _uberdev_dispatch_cleanup_dead_partial_result | sed '1s/_uberdev_dispatch_cleanup_dead_partial_result/_race_real_partial_cleanup/')"

# Once timeout intent is public, a later recovery failure must revoke the
# capability before returning and persist the exact failed phase. A failed
# background partial-result cleanup therefore cannot leave an intent that a
# detached watcher could honor indefinitely.
printf 'version=1\ngeneration=%s\nrun_id=worker-0001\nowner_pid=%s\nowner_identity=%s\nbackend_handle=780\nbackend_identity=\nstart_epoch=1\ntimeout_s=30\nstatus_path=%s\n' \
  "$RACE_GENERATION" "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >"$RACE_LEASE"
chmod 600 "$RACE_LEASE"
printf '{"backend":"background","state":"running","exit_code":null,"pid":"780","lease_generation":"%s","process_identity":"780|780|780|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}\n' \
  "$RACE_GENERATION" >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001","backend":"background"}\n' >"$MANIFEST"
printf '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001","backend":"background","owner_pid":%s,"owner_process_identity":"%s","status_path":"%s","timeout_s":30}\n' \
  "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >>"$MANIFEST"
_uberdev_dispatch_cancel_backend() { return 0; }
_uberdev_dispatch_cleanup_dead_partial_result() { return 2; }
set +e
CLEANUP_FAILED_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 1 2>&1)"
CLEANUP_FAILED_RC=$?
set -e
[ "$CLEANUP_FAILED_RC" -eq 2 ]
[ ! -e "$STATUS.timeout-intent-v1" ]
[ -e "$RACE_LEASE" ]
[ "$(_uberdev_child_watcher_error "$STATUS" "$TMP/run/.agent-state-$(id -u)/worker-0001.watcher-error.json")" = \
  'timeout_partial_result_cleanup_failed; backend=background; capacity=retained; action=resolve the retained lifecycle lease before retrying' ]
rm -f "$STATUS.watcher-error.json" "$RACE_LEASE"

for RACE_WINNER in timeout completion; do
  printf 'version=1\ngeneration=%s\nrun_id=worker-0001\nowner_pid=%s\nowner_identity=%s\nbackend_handle=779\nbackend_identity=\nstart_epoch=1\ntimeout_s=30\nstatus_path=%s\n' \
    "$RACE_GENERATION" "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >"$RACE_LEASE"
  chmod 600 "$RACE_LEASE"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"779","lease_generation":"%s"}\n' \
    "$RACE_GENERATION" >"$STATUS"
  printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001","backend":"codex"}\n' >"$MANIFEST"
  printf '{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001","backend":"codex","owner_pid":%s,"owner_process_identity":"%s","status_path":"%s","timeout_s":30}\n' \
    "$$" "$TEST_OWNER_IDENTITY" "$STATUS_REAL" >>"$MANIFEST"
  _uberdev_dispatch_cancel_backend() {
    if [ "$RACE_WINNER" = completion ]; then
      printf 'completed race result\n' >"$RESULT"
      printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"779","lease_generation":"%s"}\n' \
        "$RACE_GENERATION" >"$STATUS"
      printf '{"schema_version":1,"event":"completed","timestamp":"2026-07-10T00:00:02.000Z","run_id":"worker-0001","backend":"codex","terminal_status":"completed"}\n' >>"$MANIFEST"
      _uberdev_agent_release_exact_lease "$RACE_LEASE" "$(_uberdev_agent_lease_identity "$RACE_LEASE")"
      return 2
    fi
    return 0
  }
  set +e
  RACE_WAIT_ERROR="$(uberdev_wait_child "$STATUS" "$RESULT" 1 2>&1)"
  RACE_WAIT_RC=$?
  set -e
  if [ "$RACE_WINNER" = timeout ]; then [ "$RACE_WAIT_RC" -eq 124 ]; else [ "$RACE_WAIT_RC" -eq 0 ]; fi
  python3 -I - "$STATUS" "$MANIFEST" "$RACE_LEASE" "$RACE_WINNER" <<'PY'
import json,pathlib,sys
status_path,manifest_path,lease_path,winner=sys.argv[1:]
status=json.load(open(status_path)); rows=[json.loads(line) for line in open(manifest_path) if line.strip()]
terminals=[row['event'] for row in rows if row.get('run_id')=='worker-0001' and row.get('event') in {'completed','failed','timed_out','cancelled','abandoned'}]
assert status['state']==('timed_out' if winner=='timeout' else 'completed'),status
assert terminals==[status['state']],terminals
assert not pathlib.Path(lease_path).exists(),lease_path
PY
done
eval "$(declare -f _race_real_cancel_backend | sed '1s/_race_real_cancel_backend/_uberdev_dispatch_cancel_backend/')"
eval "$(declare -f _race_real_partial_cleanup | sed '1s/_race_real_partial_cleanup/_uberdev_dispatch_cleanup_dead_partial_result/')"
rmdir "$RACE_SCOPE"

# zsh can source and execute the public wait API without colliding with its
# readonly `status` special parameter.
printf 'zsh result\n' >"$RESULT"; printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"; terminal_manifest completed
zsh -f -c '. "$1"; uberdev_wait_child "$2" "$3" 2' _ "$LIB" "$STATUS" "$RESULT" >/dev/null

# Zero is rejected: cleanup uses the bounded uberdev_unwind_child API. A normal
# positive wait still observes a delayed real terminal without fabrication.
printf '{"backend":"codex","state":"running","exit_code":null,"pid":"321"}\n' >"$STATUS"
printf '{"schema_version":1,"event":"route_decided","timestamp":"2026-07-10T00:00:00.000Z","run_id":"worker-0001"}\n{"schema_version":1,"event":"agent_started","timestamp":"2026-07-10T00:00:01.000Z","run_id":"worker-0001"}\n' >"$MANIFEST"
(
  sleep .2
  printf 'drained result\n' >"$RESULT"
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"321"}\n' >"$STATUS"
  terminal_manifest completed
) & DRAIN_WRITER=$!
! uberdev_wait_child "$STATUS" "$RESULT" 0 >/dev/null 2>&1
uberdev_wait_child "$STATUS" "$RESULT" 2 >/dev/null
wait "$DRAIN_WRITER"
grep -q '"state":"completed"' "$STATUS"
! grep -q 'timed_out\|cancel' "$STATUS"

# Paths must be the canonical owned child pair.
! uberdev_wait_child "$TMP/outside-status" "$RESULT" 1 >/dev/null 2>&1
! uberdev_wait_child "$STATUS" "$TMP/outside-result" 1 >/dev/null 2>&1
echo 'child-wait tests passed'
