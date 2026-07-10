#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/live-semaphore.sh"
MANIFEST="$ROOT/plugins/uberdev/lib/run_manifest.py"
FIXTURES="$ROOT/tests/fixtures/live-semaphore"
TMP="$(mktemp -d)" || exit 1
backend_pid=""
owner_pid=""
cleanup() {
  [ -z "$backend_pid" ] || kill "$backend_pid" 2>/dev/null || true
  [ -z "$owner_pid" ] || kill "$owner_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

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
mode_of() {
  local value
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}
wait_for_file() {
  local path="$1" tries=0
  while [ ! -s "$path" ] && [ "$tries" -lt 200 ]; do
    sleep 0.01
    tries=$((tries + 1))
  done
  [ -s "$path" ]
}

if [ ! -f "$LIB" ]; then
  printf '  FAIL  live-semaphore.sh is missing: %s\n' "$LIB"
  exit 1
fi

printf '== live semaphore: source safety and validation ==\n'
trap_before="$(trap -p EXIT)"
# shellcheck source=/dev/null
. "$LIB"
trap_after="$(trap -p EXIT)"
if [ "$trap_before" = "$trap_after" ]; then
  pass "sourcing the library installs no caller traps"
else
  fail "sourcing the library installs no caller traps" "before=$trap_before after=$trap_after"
fi

capture uberdev_semaphore_acquire "relative/state" repo codex 1 run 5
[ "$CAPTURE_RC" -eq 2 ] && pass "relative state root is rejected" || fail "relative state root is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-cap" repo codex 0 run 5
[ "$CAPTURE_RC" -eq 2 ] && pass "zero cap is rejected" || fail "zero cap is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-cap-text" repo codex nope run 5
[ "$CAPTURE_RC" -eq 2 ] && pass "non-numeric cap is rejected" || fail "non-numeric cap is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-timeout" repo codex 1 run 0
[ "$CAPTURE_RC" -eq 2 ] && pass "zero timeout is rejected" || fail "zero timeout is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-backend" repo '../codex' 1 run 5
[ "$CAPTURE_RC" -eq 2 ] && pass "backend traversal input is rejected" || fail "backend traversal input is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-run" repo codex 1 '' 5
[ "$CAPTURE_RC" -eq 2 ] && pass "empty run id is rejected" || fail "empty run id is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
capture uberdev_semaphore_acquire "$TMP/invalid-run-newline" repo codex 1 $'run\nowner_pid=1' 5
[ "$CAPTURE_RC" -eq 2 ] && pass "lease-field newline injection is rejected" || fail "lease-field newline injection is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

capture /bin/bash -c '. "$1"; shasum() { return 1; }; uberdev_semaphore_acquire "$2" repo codex 1 run 5' \
  _ "$LIB" "$TMP/hash-tool-failure"
if [ "$CAPTURE_RC" -eq 2 ] && ! find "$TMP/hash-tool-failure" -name '.scope' -print 2>/dev/null | grep -q .; then
  pass "digest producer failure cannot collapse identities into an empty scope hash"
else
  fail "digest producer failure cannot collapse identities into an empty scope hash" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

capture /bin/bash -c '. "$1"; shasum() { printf "not-a-digest\\n"; }; uberdev_semaphore_acquire "$2" repo codex 1 run 5' \
  _ "$LIB" "$TMP/hash-tool-malformed"
if [ "$CAPTURE_RC" -eq 2 ] && ! find "$TMP/hash-tool-malformed" -name 'not-a-digest.scope' -print 2>/dev/null | grep -q .; then
  pass "malformed digest output is rejected before scope construction"
else
  fail "malformed digest output is rejected before scope construction" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

# Shared backend-liveness matrix:
#   terminal status -> dead for every handle
#   empty handle -> live only from live status
#   numeric or pid:<numeric> handle -> process probe only
#   opaque handle -> live only from live status
matrix_failures=''
check_liveness_matrix() {
  local handle="$1" status_kind="$2" expected="$3" label="$4"
  local shell_verdict python_verdict
  if _uberdev_semaphore_backend_live "$handle" "$status_kind"; then
    shell_verdict=live
  else
    shell_verdict=dead
  fi
  python_verdict="$(python3 - "$MANIFEST" "$handle" "$status_kind" <<'PY'
import importlib.util
import sys

module_path, handle, status_kind = sys.argv[1:]
spec = importlib.util.spec_from_file_location("run_manifest_liveness_matrix", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module._status_liveness = lambda _path: {
    "live": True,
    "terminal": False,
    "unknown": None,
}[status_kind]
started = {"backend_handle": handle, "status_path": "/status"}
print("live" if module._backend_live(started) else "dead")
PY
)"
  if [ "$shell_verdict" != "$expected" ] || [ "$python_verdict" != "$expected" ]; then
    matrix_failures="$matrix_failures $label=$shell_verdict/$python_verdict(expected:$expected)"
  fi
}
check_liveness_matrix '' live live status-only-live
check_liveness_matrix '' unknown dead status-only-unknown
check_liveness_matrix 999999 live dead numeric-dead-stale-status
check_liveness_matrix pid:999999 live dead prefixed-pid-dead-stale-status
check_liveness_matrix "$$" unknown live numeric-live
check_liveness_matrix "pid:$$" unknown live prefixed-pid-live
check_liveness_matrix provider-job live live opaque-live
check_liveness_matrix provider-job unknown dead opaque-unknown
check_liveness_matrix provider-job terminal dead opaque-terminal
check_liveness_matrix "$$" terminal dead numeric-terminal
if [ -z "$matrix_failures" ]; then
  pass "shell and manifest implement the same documented backend-liveness matrix"
else
  fail "shell and manifest implement the same documented backend-liveness matrix" "$matrix_failures"
fi

reserved_pid_failures=''
reserved_pid_index=0
for reserved_pid_handle in 'pid:' 'pid:0' 'pid:-1' 'pid:provider'; do
  reserved_pid_index=$((reserved_pid_index + 1))
  reserved_state="$TMP/reserved-pid-$reserved_pid_index"
  reserved_lease="$(uberdev_semaphore_acquire "$reserved_state" repo codex 1 "reserved-$reserved_pid_index" 30)"
  capture uberdev_semaphore_set_handle "$reserved_lease" "$reserved_pid_handle" "$FIXTURES/running-status.json"
  if [ "$CAPTURE_RC" -eq 2 ]; then
    shell_reserved_verdict=rejected
  else
    shell_reserved_verdict=accepted
  fi
  python_reserved_verdict="$(python3 - "$MANIFEST" "$reserved_pid_handle" "$FIXTURES/running-status.json" <<'PY'
import importlib.util
import sys

module_path, handle, status_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("run_manifest_reserved_pid", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
errors = module._validate_event({
    "schema_version": 1,
    "event": "agent_started",
    "timestamp": "2026-07-10T00:00:00Z",
    "run_id": "reserved-pid",
    "backend": "codex",
    "owner_pid": 1,
    "backend_handle": handle,
    "status_path": status_path,
})
print("rejected" if "invalid_backend_handle" in errors else "accepted")
PY
)"
  if [ "$shell_reserved_verdict" != rejected ] || [ "$python_reserved_verdict" != rejected ]; then
    reserved_pid_failures="$reserved_pid_failures $reserved_pid_handle=$shell_reserved_verdict/$python_reserved_verdict"
  fi
  rm -f "$reserved_lease"
done
if [ -z "$reserved_pid_failures" ]; then
  pass "shell setter and manifest reserve pid: for positive decimal process IDs"
else
  fail "shell setter and manifest reserve pid: for positive decimal process IDs" "$reserved_pid_failures"
fi

printf '== live semaphore: private collision-free scopes and atomic leases ==\n'
SCOPE_STATE="$TMP/scope-state"
capture uberdev_semaphore_acquire "$SCOPE_STATE" 'team/a' codex 1 'run/a' 5
lease_a="$CAPTURE_OUT"; rc_a="$CAPTURE_RC"
capture uberdev_semaphore_acquire "$SCOPE_STATE" 'team_a' codex 1 'run_a' 5
lease_b="$CAPTURE_OUT"; rc_b="$CAPTURE_RC"
scope_a="$(dirname "$lease_a")"
scope_b="$(dirname "$lease_b")"
base_a="$(basename "$scope_a")"
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] && [ "$scope_a" != "$scope_b" ] \
   && [[ "$base_a" =~ ^[0-9a-f]{64}\.scope$ ]] \
   && [ "${scope_a#"$SCOPE_STATE/semaphore-v1/"}" != "$scope_a" ]; then
  pass "repository/backend identities hash to collision-free in-root scopes"
else
  fail "repository/backend identities hash to collision-free in-root scopes" "rc=$rc_a/$rc_b scope=$scope_a/$scope_b"
fi
if [ "$(mode_of "$scope_a")" = "700" ] && [ "$(mode_of "$lease_a")" = "600" ]; then
  pass "scope is 0700 and lease is 0600"
else
  fail "scope is 0700 and lease is 0600" "scope=$(mode_of "$scope_a") lease=$(mode_of "$lease_a")"
fi
if grep -q '^version=1$' "$lease_a" \
   && grep -Eq '^generation=[0-9a-f]{32}$' "$lease_a" \
   && grep -q '^run_id=run/a$' "$lease_a" \
   && grep -q '^owner_pid=[0-9][0-9]*$' "$lease_a" \
   && grep -q '^backend_handle=$' "$lease_a" \
   && grep -q '^start_epoch=[0-9][0-9]*$' "$lease_a" \
   && grep -q '^timeout_s=5$' "$lease_a" \
   && grep -q '^status_path=$' "$lease_a"; then
  pass "lease records required lifecycle metadata"
else
  fail "lease records required lifecycle metadata" "lease=$(tr '\n' ' ' < "$lease_a")"
fi
if ! find "$scope_a" -name '*.tmp.*' -type f | grep -q .; then
  pass "lease publication leaves no same-directory temp files"
else
  fail "lease publication leaves no same-directory temp files" "temp file leaked"
fi
uberdev_semaphore_release "$lease_a" >/dev/null 2>&1 || fail "release first scoped lease" "release failed"
uberdev_semaphore_release "$lease_b" >/dev/null 2>&1 || fail "release second scoped lease" "release failed"

TRAVERSAL_STATE="$TMP/traversal-state"
capture uberdev_semaphore_acquire "$TRAVERSAL_STATE" '../../outside/repo' codex 1 '../run-id' 5
traversal_lease="$CAPTURE_OUT"
if [ "$CAPTURE_RC" -eq 0 ] && [ "${traversal_lease#"$TRAVERSAL_STATE/semaphore-v1/"}" != "$traversal_lease" ] && [ ! -e "$TMP/outside" ]; then
  pass "repository and run path text cannot escape hashed state paths"
else
  fail "repository and run path text cannot escape hashed state paths" "rc=$CAPTURE_RC lease=$traversal_lease"
fi
uberdev_semaphore_release "$traversal_lease" >/dev/null 2>&1 || true

HANDLE_STATE="$TMP/handle-state"
lease_handle="$(uberdev_semaphore_acquire "$HANDLE_STATE" repo codex 1 run-handle 5)"
status_path="$TMP/status path.json"
cp "$FIXTURES/running-status.json" "$status_path"
capture uberdev_semaphore_set_handle "$lease_handle" "$$" "$status_path"
if [ "$CAPTURE_RC" -eq 0 ] && grep -q "^backend_handle=$$\$" "$lease_handle" && grep -Fq "status_path=$status_path" "$lease_handle" \
   && [ "$(mode_of "$lease_handle")" = "600" ] \
   && ! find "$(dirname "$lease_handle")" -name '*.tmp.*' -type f | grep -q .; then
  pass "set_handle atomically updates a private lease"
else
  fail "set_handle atomically updates a private lease" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture uberdev_semaphore_set_handle "$lease_handle" "$$" "$TMP/status"$'\ntimeout_s=1'
if [ "$CAPTURE_RC" -eq 2 ] && ! grep -q '^timeout_s=1$' "$lease_handle"; then
  pass "status path newline injection cannot rewrite lease fields"
else
  fail "status path newline injection cannot rewrite lease fields" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
capture uberdev_semaphore_acquire "$HANDLE_STATE" repo codex 1 run-handle 5
if [ "$CAPTURE_RC" -ne 0 ]; then
  pass "duplicate live run id cannot replace its lease"
else
  fail "duplicate live run id cannot replace its lease" "second lease=$CAPTURE_OUT"
  uberdev_semaphore_release "$CAPTURE_OUT" >/dev/null 2>&1 || true
fi
capture uberdev_semaphore_release "$lease_handle"
first_release_rc="$CAPTURE_RC"
capture uberdev_semaphore_release "$lease_handle"
if [ "$first_release_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ]; then
  pass "release is cancellation-safe and idempotent"
else
  fail "release is cancellation-safe and idempotent" "rc=$first_release_rc/$CAPTURE_RC"
fi

printf '== live semaphore: lease generations prevent ABA ==\n'
ABA_STATE="$TMP/aba-state"
aba_old="$(uberdev_semaphore_acquire "$ABA_STATE" repo codex 1 same-run 30)"
old_generation="$(sed -n 's/^generation=//p' "$aba_old")"
uberdev_semaphore_release "$aba_old" >/dev/null || fail "release first ABA generation" "release failed"
aba_new="$(uberdev_semaphore_acquire "$ABA_STATE" repo codex 1 same-run 30)"
new_generation="$(sed -n 's/^generation=//p' "$aba_new")"
capture uberdev_semaphore_set_handle "$aba_old" 999999 ''
stale_set_rc="$CAPTURE_RC"
capture uberdev_semaphore_release "$aba_old"
stale_release_rc="$CAPTURE_RC"
if [ "$aba_old" != "$aba_new" ] && [ "$old_generation" != "$new_generation" ] \
   && [ "$stale_set_rc" -eq 2 ] && [ "$stale_release_rc" -eq 0 ] \
   && [ -f "$aba_new" ] && grep -q '^backend_handle=$' "$aba_new"; then
  pass "stale set_handle/release cannot affect a newer run generation"
else
  fail "stale set_handle/release cannot affect a newer run generation" "paths=$aba_old/$aba_new generations=$old_generation/$new_generation set=$stale_set_rc release=$stale_release_rc"
fi
uberdev_semaphore_release "$aba_new" >/dev/null 2>&1 || true

OPAQUE_STATE="$TMP/opaque-handle-state"
opaque_status="$TMP/opaque-status.json"
cp "$FIXTURES/running-status.json" "$opaque_status"
opaque_lease="$(uberdev_semaphore_acquire "$OPAQUE_STATE" repo claude-bg 1 opaque-run 5)"
capture uberdev_semaphore_set_handle "$opaque_lease" 'agent:opaque-123' "$opaque_status"
opaque_set_rc="$CAPTURE_RC"
printf '{"state":"completed"}\n' > "$opaque_status"
capture uberdev_semaphore_reconcile "$OPAQUE_STATE" repo claude-bg
if [ "$opaque_set_rc" -eq 0 ] && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$opaque_lease" ]; then
  pass "opaque backend handles use their canonical status path"
else
  fail "opaque backend handles use their canonical status path" "set_rc=$opaque_set_rc reconcile_rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

MISSING_STATUS_STATE="$TMP/missing-status-state"
MISSING_STATUS_LEASE_FILE="$TMP/missing-status-lease"
MISSING_STATUS_PATH="$TMP/status-never-created.json"
/bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo claude-bg 1 missing-status-run 30)" || exit 1
  uberdev_semaphore_set_handle "$lease" provider-job-123 "$3" || exit 1
  printf "%s\n" "$lease" > "$4"
' _ "$LIB" "$MISSING_STATUS_STATE" "$MISSING_STATUS_PATH" "$MISSING_STATUS_LEASE_FILE"
missing_status_lease="$(cat "$MISSING_STATUS_LEASE_FILE")"
capture uberdev_semaphore_reconcile "$MISSING_STATUS_STATE" repo claude-bg
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '1' ] && [ ! -e "$missing_status_lease" ]; then
  pass "dead owner with never-created opaque status eventually releases capacity"
else
  fail "dead owner with never-created opaque status eventually releases capacity" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

CORRUPT_STATE="$TMP/corrupt-state"
corrupt_lease="$(uberdev_semaphore_acquire "$CORRUPT_STATE" repo codex 1 corrupt-run 5)"
printf 'version=9\n' > "$corrupt_lease"
chmod 600 "$corrupt_lease"
capture uberdev_semaphore_set_handle "$corrupt_lease" 123 ''
corrupt_set_rc="$CAPTURE_RC"
capture uberdev_semaphore_reconcile "$CORRUPT_STATE" repo codex
if [ "$corrupt_set_rc" -eq 2 ] && [ "$CAPTURE_RC" -eq 2 ]; then
  pass "malformed lease failures propagate through update and reconciliation"
else
  fail "malformed lease failures propagate through update and reconciliation" "set_rc=$corrupt_set_rc reconcile_rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
uberdev_semaphore_release "$corrupt_lease" >/dev/null 2>&1 || true

lease_structure_failures=''
exercise_malformed_lease() {
  local lease_case="$1" lease_key="${2-}" mutation_kind="${3-}"
  local structure_state structure_lease structure_mutation existing_value
  structure_state="$TMP/lease-structure-$lease_case"
  structure_lease="$(uberdev_semaphore_acquire "$structure_state" repo codex 1 "run-$lease_case" 30)"
  structure_mutation="$structure_lease.mutation"
  case "$mutation_kind" in
    missing)
      awk -v lease_key="$lease_key" '$0 !~ ("^" lease_key "=")' \
        "$structure_lease" > "$structure_mutation"
      ;;
    duplicate)
      cp "$structure_lease" "$structure_mutation"
      existing_value="$(sed -n "s/^$lease_key=//p" "$structure_lease")"
      printf '%s=%s\n' "$lease_key" "$existing_value" >> "$structure_mutation"
      ;;
    opaque-without-status)
      awk '/^backend_handle=/{print "backend_handle=provider-job"; next} {print}' \
        "$structure_lease" > "$structure_mutation"
      ;;
    relative-status)
      awk '/^status_path=/{print "status_path=relative/status.json"; next} {print}' \
        "$structure_lease" > "$structure_mutation"
      ;;
  esac
  chmod 600 "$structure_mutation"
  mv "$structure_mutation" "$structure_lease"
  capture uberdev_semaphore_reconcile "$structure_state" repo codex
  if [ "$CAPTURE_RC" -ne 2 ] || [ ! -f "$structure_lease" ]; then
    lease_structure_failures="$lease_structure_failures $lease_case(rc:$CAPTURE_RC,exists:$([ -f "$structure_lease" ] && printf yes || printf no))"
  fi
  rm -f "$structure_lease"
}
for lease_key in version generation run_id owner_pid backend_handle start_epoch timeout_s status_path; do
  exercise_malformed_lease "missing-$lease_key" "$lease_key" missing
  exercise_malformed_lease "duplicate-$lease_key" "$lease_key" duplicate
done
for relationship_case in opaque-without-status relative-status; do
  exercise_malformed_lease "$relationship_case" '' "$relationship_case"
done
if [ -z "$lease_structure_failures" ]; then
  pass "lease parser requires every key once and validates handle/status relationships"
else
  fail "lease parser requires every key once and validates handle/status relationships" "$lease_structure_failures"
fi

WRITER_SPY_STATE="$TMP/secure-writer-spy"
WRITER_SPY_MARKER="$TMP/secure-writer-called"
capture /bin/bash -c '
  SPY_MARKER="$3"
  python3() {
    case " $* " in
      *" secure-write-lease "*)
        printf "called\n" > "$SPY_MARKER"
        cat >/dev/null
        return 97
        ;;
    esac
    command python3 "$@"
  }
  . "$1"
  uberdev_semaphore_acquire "$2" repo codex 1 writer-spy 30
' _ "$LIB" "$WRITER_SPY_STATE" "$WRITER_SPY_MARKER"
if [ "$CAPTURE_RC" -eq 2 ] && [ "$(cat "$WRITER_SPY_MARKER" 2>/dev/null)" = called ] \
   && ! find "$WRITER_SPY_STATE" -name '*.lease' -type f -print 2>/dev/null | grep -q .; then
  pass "production acquisition calls the secure writer and propagates its failure"
else
  fail "production acquisition calls the secure writer and propagates its failure" "rc=$CAPTURE_RC out=$CAPTURE_OUT marker=$(cat "$WRITER_SPY_MARKER" 2>/dev/null || true)"
fi

printf '== live semaphore: path and symlink attacks ==\n'
OUTSIDE="$TMP/outside-target"
mkdir "$OUTSIDE"
ln -s "$OUTSIDE" "$TMP/state-link"
capture uberdev_semaphore_acquire "$TMP/state-link" repo codex 1 run 5
if [ "$CAPTURE_RC" -eq 2 ] && [ -z "$(find "$OUTSIDE" -type f | head -n 1)" ]; then
  pass "symlink state root is rejected without touching its target"
else
  fail "symlink state root is rejected without touching its target" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

mkdir "$TMP/state-ancestor-target"
ln -s "$TMP/state-ancestor-target" "$TMP/state-ancestor-link"
capture uberdev_semaphore_acquire "$TMP/state-ancestor-link/private-state" repo codex 1 ancestor-run 5
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -e "$TMP/state-ancestor-target/private-state" ]; then
  pass "symlinked STATE_ROOT ancestor is rejected"
else
  fail "symlinked STATE_ROOT ancestor is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  [ "$CAPTURE_RC" -ne 0 ] || uberdev_semaphore_release "$CAPTURE_OUT" >/dev/null 2>&1 || true
fi

ATTACK_STATE="$TMP/attack-state"
attack_lease="$(uberdev_semaphore_acquire "$ATTACK_STATE" repo codex 1 run-attack 5)"
attack_scope="$(dirname "$attack_lease")"
uberdev_semaphore_release "$attack_lease" >/dev/null
VICTIM="$TMP/lease-victim"
printf 'unchanged\n' > "$VICTIM"
ln -s "$VICTIM" "$attack_lease"
capture uberdev_semaphore_set_handle "$attack_lease" 123 ''
set_link_rc="$CAPTURE_RC"
capture uberdev_semaphore_release "$attack_lease"
if [ "$set_link_rc" -eq 2 ] && [ "$CAPTURE_RC" -eq 2 ] && [ "$(cat "$VICTIM")" = "unchanged" ] && [ -L "$attack_lease" ]; then
  pass "symlink lease is rejected by update and release"
else
  fail "symlink lease is rejected by update and release" "set_rc=$set_link_rc release_rc=$CAPTURE_RC victim=$(cat "$VICTIM")"
fi
rm -f "$attack_lease"

STATUS_VICTIM="$TMP/status-victim"
printf '{"state":"completed"}\n' > "$STATUS_VICTIM"
ln -s "$STATUS_VICTIM" "$TMP/status-link"
status_attack_lease="$(uberdev_semaphore_acquire "$ATTACK_STATE" repo codex 1 run-status-attack 5)"
capture uberdev_semaphore_set_handle "$status_attack_lease" 123 "$TMP/status-link"
if [ "$CAPTURE_RC" -eq 2 ]; then
  pass "symlink status path is rejected"
else
  fail "symlink status path is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
uberdev_semaphore_release "$status_attack_lease" >/dev/null 2>&1 || true

rmdir "$attack_scope"
mkdir "$TMP/scope-symlink-target"
ln -s "$TMP/scope-symlink-target" "$attack_scope"
capture uberdev_semaphore_acquire "$ATTACK_STATE" repo codex 1 run-scope-link 5
if [ "$CAPTURE_RC" -eq 2 ]; then
  pass "symlink scope is rejected"
else
  fail "symlink scope is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
rm -f "$attack_scope"

UNSAFE_ACTIVE_STATE="$TMP/unsafe-active-state"
unsafe_active_lease="$(uberdev_semaphore_acquire "$UNSAFE_ACTIVE_STATE" repo codex 1 active-run 30)"
unsafe_victim="$TMP/unsafe-active-victim"
printf 'unchanged\n' > "$unsafe_victim"
rm -f "$unsafe_active_lease"
ln -s "$unsafe_victim" "$unsafe_active_lease"
capture uberdev_semaphore_acquire "$UNSAFE_ACTIVE_STATE" repo codex 1 second-run 5
unsafe_acquire_rc="$CAPTURE_RC"
unsafe_acquire_out="$CAPTURE_OUT"
if [ "$unsafe_acquire_rc" -eq 2 ] && [ "$(cat "$unsafe_victim")" = "unchanged" ]; then
  pass "unsafe lease in a scope fails closed instead of freeing capacity"
else
  fail "unsafe lease in a scope fails closed instead of freeing capacity" "rc=$unsafe_acquire_rc out=$unsafe_acquire_out"
  [ "$unsafe_acquire_rc" -ne 0 ] || uberdev_semaphore_release "$unsafe_acquire_out" >/dev/null 2>&1 || true
fi
rm -f "$unsafe_active_lease"

capture uberdev_semaphore_set_handle "$TMP/not-a-scope/arbitrary.lease" 123 ''
[ "$CAPTURE_RC" -eq 2 ] && pass "set_handle rejects arbitrary paths" || fail "set_handle rejects arbitrary paths" "rc=$CAPTURE_RC out=$CAPTURE_OUT"

printf '== live semaphore: eight-way cap race ==\n'
RACE_STATE="$TMP/race-state"
printf '0\n' > "$TMP/max"
record_max() {
  local current="$1" old tries=0
  while ! mkdir "$TMP/max.lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 1000 ] || return 1
    sleep 0.01
  done
  old="$(cat "$TMP/max")"
  [ "$current" -le "$old" ] || printf '%s\n' "$current" > "$TMP/max"
  rmdir "$TMP/max.lock"
}
pids=""
n=1
while [ "$n" -le 8 ]; do
  (
    # shellcheck source=/dev/null
    . "$LIB"
    lease="$(uberdev_semaphore_acquire "$RACE_STATE" race-repo codex 3 "run-$n" 5)" || exit 1
    [ -n "$lease" ] || exit 1
    active="$(find "$RACE_STATE" -name '*.lease' -type f | wc -l | tr -d ' ')"
    record_max "$active" || exit 1
    sleep 0.15
    uberdev_semaphore_release "$lease" || exit 1
  ) 2>"$TMP/race-$n.err" &
  pids="$pids $!"
  n=$((n + 1))
done
race_rc=0
for pid in $pids; do wait "$pid" || race_rc=1; done
observed_max="$(cat "$TMP/max")"
printf 'observed_max=%s\n' "$observed_max"
remaining="$(find "$RACE_STATE" -name '*.lease' -type f | wc -l | tr -d ' ')"
race_stderr="$(cat "$TMP"/race-*.err)"
if [ "$race_rc" -eq 0 ] && [ "$observed_max" -eq 3 ] && [ "$remaining" -eq 0 ] && [ -z "$race_stderr" ]; then
  pass "eight contenders eventually acquire/release without exceeding cap 3"
else
  fail "eight contenders eventually acquire/release without exceeding cap 3" "race_rc=$race_rc observed_max=$observed_max remaining=$remaining stderr=$race_stderr"
fi

printf '== live semaphore: killed owner, stale timeout, and backend liveness ==\n'
SUBSHELL_STATE="$TMP/subshell-killed-state"
SUBSHELL_PATH_FILE="$TMP/subshell-killed-lease-path"
(
  lease="$(uberdev_semaphore_acquire "$SUBSHELL_STATE" repo codex 1 subshell-owner 30)" || exit 1
  printf '%s\n' "$lease" > "$SUBSHELL_PATH_FILE"
  sleep 30
) &
subshell_owner_pid=$!
wait_for_file "$SUBSHELL_PATH_FILE" || true
subshell_killed_lease="$(cat "$SUBSHELL_PATH_FILE" 2>/dev/null || true)"
subshell_recorded_owner="$(sed -n 's/^owner_pid=//p' "$subshell_killed_lease" 2>/dev/null || true)"
kill -9 "$subshell_owner_pid" 2>/dev/null || true
wait "$subshell_owner_pid" 2>/dev/null || true
capture uberdev_semaphore_reconcile "$SUBSHELL_STATE" repo codex
if [ -n "$subshell_killed_lease" ] && [ "$subshell_recorded_owner" = "$subshell_owner_pid" ] \
   && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$subshell_killed_lease" ]; then
  pass "Bash 3.2 background worker identity is recorded and recovered after death"
else
  fail "Bash 3.2 background worker identity is recorded and recovered after death" "worker=$subshell_owner_pid recorded=$subshell_recorded_owner rc=$CAPTURE_RC removed=$CAPTURE_OUT lease=$subshell_killed_lease"
fi

printf '== live semaphore: canonical top-level status parsing ==\n'
NESTED_STATE="$TMP/nested-status-state"
NESTED_PATH_FILE="$TMP/nested-status-lease"
/bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo codex 1 nested-running 30)" || exit 1
  uberdev_semaphore_set_handle "$lease" provider-nested "$3" || exit 1
  printf "%s\n" "$lease" > "$4"
' _ "$LIB" "$NESTED_STATE" "$FIXTURES/nested-terminal-running.json" "$NESTED_PATH_FILE"
nested_lease="$(cat "$NESTED_PATH_FILE")"
capture uberdev_semaphore_reconcile "$NESTED_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = '0' ] && [ -f "$nested_lease" ]; then
  pass "nested terminal history cannot override top-level running state"
else
  fail "nested terminal history cannot override top-level running state" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi
uberdev_semaphore_release "$nested_lease" >/dev/null 2>&1 || true

for status_case in malformed-status.json ambiguous-status.json; do
  INVALID_STATUS_STATE="$TMP/invalid-status-$status_case"
  invalid_status_lease="$(uberdev_semaphore_acquire "$INVALID_STATUS_STATE" repo codex 1 "invalid-$status_case" 30)"
  uberdev_semaphore_set_handle "$invalid_status_lease" "$$" "$FIXTURES/$status_case" >/dev/null || true
  capture uberdev_semaphore_reconcile "$INVALID_STATUS_STATE" repo codex
  if [ "$CAPTURE_RC" -eq 2 ] && [ -f "$invalid_status_lease" ]; then
    pass "$status_case fails closed without releasing a live backend"
  else
    fail "$status_case fails closed without releasing a live backend" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
  uberdev_semaphore_release "$invalid_status_lease" >/dev/null 2>&1 || true
done

KILLED_STATE="$TMP/killed-state"
KILLED_PATH_FILE="$TMP/killed-lease-path"
/bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo codex 1 killed-owner 30)" || exit 1
  printf "%s\n" "$lease" > "$3"
  sleep 30
' _ "$LIB" "$KILLED_STATE" "$KILLED_PATH_FILE" &
owner_pid=$!
if wait_for_file "$KILLED_PATH_FILE"; then
  killed_lease="$(cat "$KILLED_PATH_FILE")"
else
  killed_lease=""
fi
kill -9 "$owner_pid" 2>/dev/null || true
wait "$owner_pid" 2>/dev/null || true
owner_pid=""
capture uberdev_semaphore_reconcile "$KILLED_STATE" repo codex
if [ -n "$killed_lease" ] && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$killed_lease" ]; then
  recovered="$(uberdev_semaphore_acquire "$KILLED_STATE" repo codex 1 recovered 5)"
  uberdev_semaphore_release "$recovered" >/dev/null
  pass "killed owner with no live backend releases capacity before timeout"
else
  fail "killed owner with no live backend releases capacity before timeout" "rc=$CAPTURE_RC removed=$CAPTURE_OUT lease=$killed_lease"
fi

BACKEND_STATE="$TMP/backend-live-state"
sleep 10 & backend_pid=$!
BACKEND_PATH_FILE="$TMP/backend-live-lease-path"
/bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo codex 1 backend-live 30)" || exit 1
  uberdev_semaphore_set_handle "$lease" "$3" "" || exit 1
  printf "%s\n" "$lease" > "$4"
' _ "$LIB" "$BACKEND_STATE" "$backend_pid" "$BACKEND_PATH_FILE"
backend_lease="$(cat "$BACKEND_PATH_FILE")"
capture uberdev_semaphore_reconcile "$BACKEND_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "0" ] && [ -f "$backend_lease" ]; then
  pass "dead owner lease is preserved while backend handle is live"
else
  fail "dead owner lease is preserved while backend handle is live" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi
kill "$backend_pid" 2>/dev/null || true
wait "$backend_pid" 2>/dev/null || true
backend_pid=""
capture uberdev_semaphore_reconcile "$BACKEND_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$backend_lease" ]; then
  pass "dead-owner capacity recovers after backend handle dies"
else
  fail "dead-owner capacity recovers after backend handle dies" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

STALE_STATE="$TMP/stale-state"
stale_lease="$(uberdev_semaphore_acquire "$STALE_STATE" repo codex 1 stale-run 1)"
uberdev_semaphore_set_handle "$stale_lease" 999999 ''
capture uberdev_semaphore_reconcile "$STALE_STATE" repo codex
pre_stale_out="$CAPTURE_OUT"; pre_stale_rc="$CAPTURE_RC"
sleep 2
capture uberdev_semaphore_reconcile "$STALE_STATE" repo codex
if [ "$pre_stale_rc" -eq 0 ] && [ "$pre_stale_out" = "0" ] && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$stale_lease" ]; then
  pass "live-owner lease is stale only after timeout plus failed backend liveness"
else
  fail "live-owner lease is stale only after timeout plus failed backend liveness" "before=$pre_stale_rc/$pre_stale_out after=$CAPTURE_RC/$CAPTURE_OUT"
fi

STALE_STATUS_STATE="$TMP/stale-status-state"
stale_running_status="$TMP/stale-running-status.json"
cp "$FIXTURES/running-status.json" "$stale_running_status"
stale_status_lease="$(uberdev_semaphore_acquire "$STALE_STATUS_STATE" repo codex 1 stale-status-run 1)"
uberdev_semaphore_set_handle "$stale_status_lease" 999999 "$stale_running_status"
sleep 2
capture uberdev_semaphore_reconcile "$STALE_STATUS_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$stale_status_lease" ]; then
  pass "stale running status cannot override a failed backend-handle probe"
else
  fail "stale running status cannot override a failed backend-handle probe" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

ALIVE_TIMEOUT_STATE="$TMP/alive-timeout-state"
sleep 10 & backend_pid=$!
alive_timeout_lease="$(uberdev_semaphore_acquire "$ALIVE_TIMEOUT_STATE" repo codex 1 alive-timeout 1)"
uberdev_semaphore_set_handle "$alive_timeout_lease" "$backend_pid" ''
sleep 2
capture uberdev_semaphore_reconcile "$ALIVE_TIMEOUT_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "0" ] && [ -f "$alive_timeout_lease" ]; then
  pass "timeout never evicts a live backend"
else
  fail "timeout never evicts a live backend" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi
kill "$backend_pid" 2>/dev/null || true
wait "$backend_pid" 2>/dev/null || true
backend_pid=""
capture uberdev_semaphore_reconcile "$ALIVE_TIMEOUT_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ]; then
  pass "expired lease recovers after backend liveness fails"
else
  fail "expired lease recovers after backend liveness fails" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

TERMINAL_STATE="$TMP/terminal-state"
terminal_status="$TMP/terminal-status.json"
cp "$FIXTURES/terminal-status.json" "$terminal_status"
terminal_lease="$(uberdev_semaphore_acquire "$TERMINAL_STATE" repo codex 1 terminal-run 30)"
uberdev_semaphore_set_handle "$terminal_lease" "$$" "$terminal_status"
capture uberdev_semaphore_reconcile "$TERMINAL_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = "1" ] && [ ! -e "$terminal_lease" ]; then
  pass "terminal status releases a lease even when its process still exists"
else
  fail "terminal status releases a lease even when its process still exists" "rc=$CAPTURE_RC removed=$CAPTURE_OUT"
fi

printf '== live semaphore: bounded and recoverable mutex ==\n'
MUTEX_STATE="$TMP/mutex-state"
mutex_lease="$(uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 seed 5)"
mutex_scope="$(dirname "$mutex_lease")"
uberdev_semaphore_release "$mutex_lease" >/dev/null
mkdir "$mutex_scope/.mutex"
printf '%s\n%s\n' "$$" '11111111111111111111111111111111' > "$mutex_scope/.mutex/owner_pid"
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
capture uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 bounded 5
unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
if [ "$CAPTURE_RC" -eq 75 ]; then
  pass "live mutex contention fails at a bounded retry limit"
else
  fail "live mutex contention fails at a bounded retry limit" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '== live semaphore: paused ownerless mutex publication ==\n'
PAUSE_STATE="$TMP/paused-mutex-state"
PAUSE_MARKER="$TMP/paused-mutex-marker"
PAUSE_CONTINUE="$TMP/paused-mutex-continue"
PAUSE_LEASE_FILE="$TMP/paused-mutex-lease"
(
  UBERDEV_SEMAPHORE_TESTING=1
  UBERDEV_SEMAPHORE_TEST_PAUSE_AFTER_MKDIR="$PAUSE_MARKER"
  UBERDEV_SEMAPHORE_TEST_CONTINUE_FILE="$PAUSE_CONTINUE"
  export UBERDEV_SEMAPHORE_TESTING UBERDEV_SEMAPHORE_TEST_PAUSE_AFTER_MKDIR UBERDEV_SEMAPHORE_TEST_CONTINUE_FILE
  lease="$(uberdev_semaphore_acquire "$PAUSE_STATE" repo codex 1 paused-holder 30)" || exit 1
  printf '%s\n' "$lease" > "$PAUSE_LEASE_FILE"
  uberdev_semaphore_release "$lease"
) &
paused_pid=$!
pause_seen=0
tries=0
while [ "$tries" -lt 200 ]; do
  if [ -s "$PAUSE_MARKER" ]; then pause_seen=1; break; fi
  kill -0 "$paused_pid" 2>/dev/null || break
  tries=$((tries + 1))
  sleep 0.01
done
pause_contender=''
if [ "$pause_seen" -eq 1 ]; then
  UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
  export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
  pause_contender="$(uberdev_semaphore_acquire "$PAUSE_STATE" repo codex 1 displaced-contender 5)"
  contender_rc=$?
  unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
  [ -z "$pause_contender" ] || uberdev_semaphore_release "$pause_contender" >/dev/null 2>&1 || true
  : > "$PAUSE_CONTINUE"
else
  contender_rc=1
fi
wait "$paused_pid" 2>/dev/null
paused_rc=$?
paused_pid=''
remaining_pause_mutexes="$(find "$PAUSE_STATE" -type d -name .mutex -print 2>/dev/null)"
if [ "$pause_seen" -eq 1 ] && [ "$contender_rc" -eq 0 ] && [ "$paused_rc" -eq 0 ] \
   && [ -s "$PAUSE_LEASE_FILE" ] && [ -z "$remaining_pause_mutexes" ]; then
  pass "ownerless mutex is quarantined and displaced live holder retries before entry"
else
  fail "ownerless mutex is quarantined and displaced live holder retries before entry" "pause=$pause_seen contender=$contender_rc holder=$paused_rc"
fi
rm -f "$mutex_scope/.mutex/owner_pid"
rmdir "$mutex_scope/.mutex"
mkdir "$mutex_scope/.mutex"
printf '%s\n%s\n' '999999' '22222222222222222222222222222222' > "$mutex_scope/.mutex/owner_pid"
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
capture uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 stale-mutex 5
unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
if [ "$CAPTURE_RC" -eq 0 ] && [ -f "$CAPTURE_OUT" ]; then
  stale_mutex_lease="$CAPTURE_OUT"
  uberdev_semaphore_release "$stale_mutex_lease" >/dev/null
  pass "dead mutex owner is reclaimed"
else
  fail "dead mutex owner is reclaimed" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

mkdir "$mutex_scope/.mutex"
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
capture uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 missing-mutex-owner 5
unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
if [ "$CAPTURE_RC" -eq 0 ] && [ -f "$CAPTURE_OUT" ]; then
  missing_owner_lease="$CAPTURE_OUT"
  uberdev_semaphore_release "$missing_owner_lease" >/dev/null
  pass "mutex abandoned before owner publication is reclaimed"
else
  fail "mutex abandoned before owner publication is reclaimed" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  rmdir "$mutex_scope/.mutex" 2>/dev/null || true
fi

for malformed_owner in empty not-a-pid; do
  mkdir "$mutex_scope/.mutex"
  if [ "$malformed_owner" = empty ]; then
    : > "$mutex_scope/.mutex/owner_pid"
  else
    printf '%s\n' "$malformed_owner" > "$mutex_scope/.mutex/owner_pid"
  fi
  UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
  export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
  capture uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 "malformed-owner-$malformed_owner" 5
  unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
  if [ "$CAPTURE_RC" -eq 0 ] && [ -f "$CAPTURE_OUT" ]; then
    malformed_owner_lease="$CAPTURE_OUT"
    uberdev_semaphore_release "$malformed_owner_lease" >/dev/null
    pass "stale $malformed_owner mutex owner record is reclaimed"
  else
    fail "stale $malformed_owner mutex owner record is reclaimed" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
    rm -f "$mutex_scope/.mutex/owner_pid" 2>/dev/null || true
    rmdir "$mutex_scope/.mutex" 2>/dev/null || true
  fi
done

MUTEX_SUBSHELL_READY="$TMP/mutex-subshell-ready"
(
  _uberdev_semaphore_mutex_acquire "$mutex_scope" || exit 1
  printf 'ready\n' > "$MUTEX_SUBSHELL_READY"
  sleep 30
) &
mutex_subshell_pid=$!
wait_for_file "$MUTEX_SUBSHELL_READY" || true
kill -9 "$mutex_subshell_pid" 2>/dev/null || true
wait "$mutex_subshell_pid" 2>/dev/null || true
UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=3
export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
capture uberdev_semaphore_acquire "$MUTEX_STATE" repo codex 1 killed-mutex-subshell 5
unset UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES
if [ "$CAPTURE_RC" -eq 0 ] && [ -f "$CAPTURE_OUT" ]; then
  killed_mutex_lease="$CAPTURE_OUT"
  uberdev_semaphore_release "$killed_mutex_lease" >/dev/null
  pass "Bash 3.2 killed background mutex holder is reclaimed"
else
  fail "Bash 3.2 killed background mutex holder is reclaimed" "worker=$mutex_subshell_pid rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

printf '\nlive-semaphore: PASS=%s FAIL=%s observed_max=%s\n' "$PASS" "$FAIL" "$observed_max"
[ "$FAIL" -eq 0 ]
