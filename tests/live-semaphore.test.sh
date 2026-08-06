#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/live-semaphore.sh"
MANIFEST="$ROOT/plugins/uberdev/lib/run_manifest.py"
FIXTURES="$ROOT/tests/fixtures/live-semaphore"
TMP="$(mktemp -d)" || exit 1
backend_pid=""
owner_pid=""
race_pids=""
cleanup() {
  [ -z "$backend_pid" ] || kill "$backend_pid" 2>/dev/null || true
  [ -z "$owner_pid" ] || kill "$owner_pid" 2>/dev/null || true
  for race_pid in $race_pids; do kill "$race_pid" 2>/dev/null || true; done
  for race_pid in $race_pids; do wait "$race_pid" 2>/dev/null || true; done
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
if (
  cygpath() { [ "$1" = -u ] && printf '%s\n' "$TMP/windows-state"; }
  _uberdev_semaphore_reject_symlinked_ancestors 'C:\Users\runneradmin\state'
); then
  pass "native Windows state roots are normalized for ancestor validation"
else
  fail "native Windows state roots are normalized for ancestor validation" "drive path rejected"
fi
if grep -Fq '/*|[A-Za-z]:/*|[A-Za-z]:\\*)' "$LIB"; then
  pass "native Windows drive roots satisfy the absolute state-root guard"
else
  fail "native Windows drive roots satisfy the absolute state-root guard" "drive-root case missing"
fi
windows_scope="$(printf 'a%.0s' {1..64}).scope"
windows_lease="$(printf 'b%.0s' {1..64}).lease"
capture _uberdev_semaphore_validate_lease_path "C:\\state/semaphore-v1/$windows_scope/$windows_lease"
if [ "$CAPTURE_RC" -eq 2 ] && ! grep -q 'LEASE_PATH must be absolute' <<<"$CAPTURE_OUT"; then
  pass "native Windows lease paths advance past the absolute-path guard"
else
  fail "native Windows lease paths advance past the absolute-path guard" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
# `grep -Eq` decides PER LINE, so a `^…$`-anchored pattern accepts a MULTI-LINE
# value whenever ANY single line matches — while the variable still carries every
# line. LEASE_PATH is caller-supplied, so a scope or filename component that
# embeds a newline in front of a well-formed component used to clear both
# anchored patterns and be accepted verbatim. Every fixture below materialises
# the poisoned directory on disk so the pre-fix library returns 0 (accepted), not
# a coincidental 2 from some later existence check — the assertions therefore
# lock the guard, not the geometry.
#
# The TRAILING-newline pair is the case a per-component check cannot see at all:
# the guard has to run on the RAW argument because `$(dirname …)`/`$(basename …)`
# run through command substitution, which strips trailing newlines — a component
# literally named `<64hex>.scope\n` reduces to a well-formed `<64hex>.scope` in
# every derived variable while the raw path still traverses the newline-suffixed
# sibling.
poison_hex_scope="$(printf 'a%.0s' {1..64}).scope"
poison_hex_lease="$(printf 'b%.0s' {1..64}).lease"
poison_scope_dir="$TMP/poison-scope/semaphore-v1/evil"$'\n'"$poison_hex_scope"
mkdir -p "$poison_scope_dir"
capture _uberdev_semaphore_validate_lease_path "$poison_scope_dir/$poison_hex_lease"
if [ "$CAPTURE_RC" -eq 2 ] && grep -q 'LEASE_PATH must be single-line text' <<<"$CAPTURE_OUT"; then
  pass "multi-line lease scope component is rejected before the anchored match"
else
  fail "multi-line lease scope component is rejected before the anchored match" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
poison_lease_dir="$TMP/poison-lease/semaphore-v1/$poison_hex_scope"
mkdir -p "$poison_lease_dir"
capture _uberdev_semaphore_validate_lease_path "$poison_lease_dir/evil"$'\n'"$poison_hex_lease"
if [ "$CAPTURE_RC" -eq 2 ] && grep -q 'LEASE_PATH must be single-line text' <<<"$CAPTURE_OUT"; then
  pass "multi-line lease filename is rejected before the anchored match"
else
  fail "multi-line lease filename is rejected before the anchored match" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
# Trailing newline on the SCOPE component: `$scope` resolves to the legitimate
# stripped directory (so `[ ! -L "$scope" ]` sees a real dir and passes) while
# the raw path traverses the sibling SYMLINK named `<64hex>.scope\n`. Rejection
# is asserted together with the escape target staying empty, so the lock is
# about containment, not just about an exit code.
escape_root="$TMP/poison-trailing/escape"
trailing_version="$TMP/poison-trailing/semaphore-v1"
mkdir -p "$escape_root" "$trailing_version/$poison_hex_scope"
ln -s "$escape_root" "$trailing_version/$poison_hex_scope"$'\n'
trailing_scope_lease="$trailing_version/$poison_hex_scope"$'\n'"/$poison_hex_lease"
capture _uberdev_semaphore_validate_lease_path "$trailing_scope_lease"
if [ "$CAPTURE_RC" -eq 2 ] \
    && grep -q 'LEASE_PATH must be single-line text' <<<"$CAPTURE_OUT" \
    && [ ! -e "$escape_root/$poison_hex_lease" ]; then
  pass "trailing-newline scope component cannot escape the validated scope via a sibling symlink"
else
  fail "trailing-newline scope component cannot escape the validated scope via a sibling symlink" \
    "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
# Trailing newline on the FILENAME: `$(basename …)` strips it, so every derived
# check saw a well-formed `<64hex>.lease` while the published path was a
# different file.
capture _uberdev_semaphore_validate_lease_path "$trailing_version/$poison_hex_scope/$poison_hex_lease"$'\n'
if [ "$CAPTURE_RC" -eq 2 ] && grep -q 'LEASE_PATH must be single-line text' <<<"$CAPTURE_OUT"; then
  pass "trailing-newline lease filename is rejected"
else
  fail "trailing-newline lease filename is rejected" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
# Counterpart: a well-formed single-line path must still clear the new guard, so
# the assertions above cannot be passing because everything is now rejected.
mkdir -p "$trailing_version/$poison_hex_scope"
capture _uberdev_semaphore_validate_lease_path "$trailing_version/$poison_hex_scope/$poison_hex_lease"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "well-formed single-line lease path still validates"
else
  fail "well-formed single-line lease path still validates" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
# No library function may declare a local named after a zsh-TIED parameter.
# zsh ties `path` to `PATH`, `fpath` to `FPATH`, and so on, so `local path`
# empties the command search path for that entire function body and every
# external it calls stops resolving. That is not theoretical here: it silently
# broke `uname -s` inside _uberdev_semaphore_reject_symlinked_ancestors, which
# left the Darwin carve-out disabled and rejected every $TMPDIR-rooted state
# path on macOS as a symlinked ancestor. The /goal fences run under /bin/zsh;
# bash has no such tie, so no assertion in this bash suite can observe it.
zsh_tied_hits=''
for tied in path cdpath fpath manpath mailpath module_path psvar prompt status \
            argv options signals watch histchars fignore; do
  if grep -qE "^[[:space:]]*(local|typeset)([[:space:]]+[^[:space:]]+)*[[:space:]]+$tied([[:space:]=]|\$)" "$LIB"; then
    zsh_tied_hits="$zsh_tied_hits $tied"
  fi
done
if [ -z "$zsh_tied_hits" ]; then
  pass "no local shadows a zsh-tied parameter (PATH-clobber class)"
else
  fail "no local shadows a zsh-tied parameter (PATH-clobber class)" "tied locals:$zsh_tied_hits"
fi
# Behavioural counterpart, run under the real fence shell when one is available:
# a $TMPDIR-rooted ancestor walk must succeed identically under zsh and bash.
zsh_bin="$(command -v zsh 2>/dev/null || true)"
if [ -n "$zsh_bin" ]; then
  zsh_probe="$("$zsh_bin" -c '
    source "$1" >/dev/null 2>&1 || { echo "source=failed"; exit 0; }
    _uberdev_semaphore_reject_symlinked_ancestors "$2" >/dev/null 2>&1
    echo "rc=$?"' _ "$LIB" "$TMP/state")"
  if [ "$zsh_probe" = 'rc=0' ]; then
    pass "symlinked-ancestor walk accepts a \$TMPDIR-rooted state path under zsh"
  else
    fail "symlinked-ancestor walk accepts a \$TMPDIR-rooted state path under zsh" "$zsh_probe"
  fi
else
  fail "symlinked-ancestor walk accepts a \$TMPDIR-rooted state path under zsh" "zsh not found on PATH"
fi
absolute_failures=''
for candidate in '/tmp/state' 'C:/state' 'C:\state' 'C:/' 'C:\'; do
  _uberdev_semaphore_is_absolute_path "$candidate" || absolute_failures="$absolute_failures accepted:$candidate"
done
for candidate in 'relative/state' 'C:'; do
  ! _uberdev_semaphore_is_absolute_path "$candidate" || absolute_failures="$absolute_failures rejected:$candidate"
done
if [ -z "$absolute_failures" ]; then
  pass "one absolute-path predicate covers POSIX, Windows, relative, and drive-root paths"
else
  fail "one absolute-path predicate covers POSIX, Windows, relative, and drive-root paths" "$absolute_failures"
fi
windows_generation="$(printf 'c%.0s' {1..32})"
windows_status_lease="$TMP/${windows_generation}$(printf 'd%.0s' {1..32}).lease"
printf 'version=1\ngeneration=%s\nrun_id=windows-status-reread\nowner_pid=%s\nowner_identity=%s\nbackend_handle=\nbackend_identity=\nstart_epoch=1\ntimeout_s=5\nstatus_path=C:\\state\\status.json\n' \
  "$windows_generation" "$$" "$(_uberdev_semaphore_process_identity "$$")" > "$windows_status_lease"
if _uberdev_semaphore_read_lease "$windows_status_lease" \
    && [ "$_UBERDEV_LEASE_STATUS_PATH" = 'C:\state\status.json' ]; then
  pass "persisted native Windows status paths survive lease reread"
else
  fail "persisted native Windows status paths survive lease reread" "status=$_UBERDEV_LEASE_STATUS_PATH"
fi
mismatched_owner_generation="$(printf 'e%.0s' {1..32})"
mismatched_owner_lease="$TMP/${mismatched_owner_generation}$(printf 'f%.0s' {1..32}).lease"
printf 'version=1\ngeneration=%s\nrun_id=mismatched-owner-identity\nowner_pid=%s\nowner_identity=%s|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbackend_handle=\nbackend_identity=\nstart_epoch=1\ntimeout_s=5\nstatus_path=\n' \
  "$mismatched_owner_generation" "$$" "$(( $$ + 1 ))" >"$mismatched_owner_lease"
capture _uberdev_semaphore_read_lease "$mismatched_owner_lease"
if [ "$CAPTURE_RC" -eq 1 ]; then
  pass "lease owner identity is bound to owner_pid"
else
  fail "lease owner identity is bound to owner_pid" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
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

capture /bin/bash -c '
  . "$1"
  _uberdev_semaphore_prepare_scope() { return 2; }
  record=""
  uberdev_semaphore_acquire "$2" repo codex 1 reason-probe 5 exact-identity record
  rc=$?
  printf "rc=%s reason=%s\n" "$rc" "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}"
  [ "$rc" -eq 2 ] && [ "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" = lease_acquire_runtime_state_failed ]
' _ "$LIB" "$TMP/reason-probe"
if [ "$CAPTURE_RC" -eq 0 ] && grep -q 'reason=lease_acquire_runtime_state_failed' <<<"$CAPTURE_OUT"; then
  pass "acquisition exports a bounded runtime-state failure reason"
else
  fail "acquisition exports a bounded runtime-state failure reason" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

ATOMIC_STATE="$TMP/atomic-identity"
capture uberdev_semaphore_acquire "$ATOMIC_STATE" repo codex 1 atomic-run 5 exact-identity
IFS=$'\t' read -r atomic_lease atomic_identity <<<"$CAPTURE_OUT"
atomic_owner="$(sed -n 's/^owner_pid=//p' "$atomic_lease" 2>/dev/null || true)"
if [ "$CAPTURE_RC" -eq 0 ] && [ -f "$atomic_lease" ] \
    && [[ "$atomic_identity" =~ ^[0-9]+:[0-9]+:[0-9a-f]{32}$ ]] \
    && [ "$atomic_owner" = "$$" ]; then
  pass "command-substitution acquisition binds the live outer shell owner"
else
  fail "command-substitution acquisition binds the live outer shell owner" \
    "shell=$$ owner=$atomic_owner rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
uberdev_semaphore_release "$atomic_lease" >/dev/null 2>&1 || true

DIRECT_OWNER_STATE="$TMP/direct-owner"
direct_owner_record=''
if uberdev_semaphore_acquire "$DIRECT_OWNER_STATE" repo codex 1 direct-owner 5 \
    exact-identity direct_owner_record; then
  direct_owner_rc=0
else
  direct_owner_rc=$?
fi
IFS=$'\t' read -r direct_owner_lease direct_owner_identity <<<"$direct_owner_record"
direct_recorded_owner="$(sed -n 's/^owner_pid=//p' "$direct_owner_lease" 2>/dev/null || true)"
if [ "$direct_owner_rc" -eq 0 ] && [ -f "$direct_owner_lease" ] \
    && [[ "$direct_owner_identity" =~ ^[0-9]+:[0-9]+:[0-9a-f]{32}$ ]] \
    && [ "$direct_recorded_owner" = "$$" ]; then
  pass "output-variable acquisition binds the direct acquiring shell owner"
else
  fail "output-variable acquisition binds the direct acquiring shell owner" \
    "shell=$$ owner=$direct_recorded_owner rc=$direct_owner_rc record=$direct_owner_record"
fi
uberdev_semaphore_release "$direct_owner_lease" >/dev/null 2>&1 || true

capture /bin/bash -c '
  . "$1"
  eval "$(declare -f _uberdev_semaphore_lease_identity | sed '\''1s/_uberdev_semaphore_lease_identity/_real_identity/'\'')"
  _uberdev_semaphore_lease_identity() {
    case "$1" in *.lease) return 29 ;; *) _real_identity "$@" ;; esac
  }
  uberdev_semaphore_acquire "$2" repo codex 1 identity-failure 5 exact-identity
' _ "$LIB" "$TMP/atomic-identity-failure"
if [ "$CAPTURE_RC" -eq 2 ] \
    && ! find "$TMP/atomic-identity-failure" -name '*.lease' -type f -print 2>/dev/null | grep -q .; then
  pass "exact identity capture failure rolls back its acquired generation"
else
  fail "exact identity capture failure rolls back its acquired generation" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

# The secure writer can publish a valid generation and still report failure
# while delivering or validating its identity. Acquisition must roll that
# generation back while the mutex is held instead of leaking capacity.
capture /bin/bash -c '
  . "$1"
  eval "$(declare -f _uberdev_semaphore_publish_lease | sed '\''1s/_uberdev_semaphore_publish_lease/_real_publish_then_fail/'\'')"
  _uberdev_semaphore_publish_lease() {
    _real_publish_then_fail "$@" || return
    return 29
  }
  replacement=""
  uberdev_semaphore_acquire "$2" repo codex 1 publish-then-fail 30 exact-identity replacement
  rc=$?
  printf "rc=%s reason=%s replacement=%s\n" "$rc" "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" "$replacement"
  [ "$rc" -eq 2 ] && [ "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" = lease_acquire_publish_failed ] \
    && ! find "$2" -name '\''*.lease'\'' -type f -print 2>/dev/null | grep -q .
' _ "$LIB" "$TMP/publish-then-fail"
if [ "$CAPTURE_RC" -eq 0 ] && grep -q 'reason=lease_acquire_publish_failed' <<<"$CAPTURE_OUT"; then
  pass "post-publication writer failure rolls back the acquired generation"
else
  fail "post-publication writer failure rolls back the acquired generation" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

# If secure rollback itself fails, return the exact retained capability and
# classify it distinctly so the dispatcher reports reserved capacity honestly.
capture /bin/bash -c '
  . "$1"
  eval "$(declare -f _uberdev_semaphore_publish_lease | sed '\''1s/_uberdev_semaphore_publish_lease/_real_retained_publish/'\'')"
  _uberdev_semaphore_publish_lease() {
    _real_retained_publish "$@" || return
    return 29
  }
  _uberdev_semaphore_remove_lease() { return 31; }
  replacement=""
  uberdev_semaphore_acquire "$2" repo codex 1 retained-publish 30 exact-identity replacement
  rc=$?
  printf "rc=%s reason=%s replacement=%s\n" "$rc" "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" "$replacement"
  [ "$rc" -eq 2 ] && [ "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" = lease_acquire_rollback_failed ] \
    && [[ "$replacement" =~ ^/.+\.lease$'\''\t'\''[0-9]+:[0-9]+:[0-9a-f]{32}$ ]]
' _ "$LIB" "$TMP/publish-rollback-failure"
if [ "$CAPTURE_RC" -eq 0 ] && grep -q 'reason=lease_acquire_rollback_failed' <<<"$CAPTURE_OUT"; then
  pass "failed post-publication rollback returns the retained lease capability"
else
  fail "failed post-publication rollback returns the retained lease capability" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

# Primary acquisition failures must not swallow a secondary mutex-release
# failure or persist the primary reason after the lock itself remains held.
for release_stage in count allocation owner; do
  capture /bin/bash -c '
    . "$1"
    case "$3" in
      count) _uberdev_semaphore_count_locked() { return 29; } ;;
      allocation) _uberdev_semaphore_new_lease_path_locked() { return 29; } ;;
      owner) _uberdev_semaphore_capture_lease_owner() { return 29; } ;;
    esac
    _uberdev_semaphore_mutex_release() { return 31; }
    uberdev_semaphore_acquire "$2" repo codex 1 "release-$3" 30
    rc=$?
    printf "rc=%s reason=%s\n" "$rc" "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}"
    [ "$rc" -eq 2 ] \
      && [ "${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-}" = lease_acquire_mutex_release_failed ]
  ' _ "$LIB" "$TMP/release-failure-$release_stage" "$release_stage"
  if [ "$CAPTURE_RC" -eq 0 ] \
      && grep -q 'cannot release acquisition mutex' <<<"$CAPTURE_OUT" \
      && grep -q 'reason=lease_acquire_mutex_release_failed' <<<"$CAPTURE_OUT"; then
    pass "$release_stage failure preserves the mutex-release diagnostic and reason"
  else
    fail "$release_stage failure preserves the mutex-release diagnostic and reason" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
done

# If exact identity validation fails after atomic handle publication and the
# rollback remove is fault-injected to fail, the replacement capability is
# still returned so the caller can release that exact inode and generation.
capture /bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo codex 1 rollback-capability 30)" || exit
  eval "$(declare -f _uberdev_semaphore_lease_identity | sed '\''1s/_uberdev_semaphore_lease_identity/_real_set_identity/'\'')"
  eval "$(declare -f _uberdev_semaphore_remove_lease | sed '\''1s/_uberdev_semaphore_remove_lease/_real_set_remove/'\'')"
  identity_marker="$2/identity-failure-marker"
  _uberdev_semaphore_lease_identity() {
    case "$1" in
      *.lease)
        if [ ! -e "$identity_marker" ]; then
          : > "$identity_marker"
          return 29
        fi
        ;;
    esac
    _real_set_identity "$@"
  }
  _uberdev_semaphore_remove_lease() { return 31; }
  replacement=""
  uberdev_semaphore_set_handle "$lease" "$$" "$3" exact-identity replacement
  rc=$?
  printf "rc=%s lease=%s identity=%s reason=%s\n" "$rc" "$lease" "$replacement" "${_UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON:-}"
  [ "$rc" -eq 2 ] && [ -f "$lease" ] && [ -n "$replacement" ] \
    && [ "${_UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON:-}" = lease_handle_rollback_failed ]
' _ "$LIB" "$TMP/set-handle-rollback-capability" "$FIXTURES/running-status.json"
if [ "$CAPTURE_RC" -eq 0 ] && grep -q 'reason=lease_handle_rollback_failed' <<<"$CAPTURE_OUT"; then
  pass "failed handle rollback preserves the replacement lease capability"
else
  fail "failed handle rollback preserves the replacement lease capability" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

# GNU stat accepts `-f` as filesystem-report mode and may print colon-bearing
# output before rejecting the BSD format operand. The identity helper must try
# GNU `-c` first and accept only one numeric device:inode pair.
gnu_identity="$({
  stat() {
    if [ "$1" = -c ] && [ "$2" = '%d:%i' ]; then
      printf '123:456\n'
      return 0
    fi
    if [ "$1" = -f ]; then
      printf '  File: "%s"\n' "$3"
      return 1
    fi
    command stat "$@"
  }
  _uberdev_semaphore_path_identity "$TMP"
} 2>/dev/null)"
if [ "$gnu_identity" = '123:456' ]; then
  pass "path identity prefers GNU stat and rejects filesystem-report noise"
else
  fail "path identity prefers GNU stat and rejects filesystem-report noise" "identity=$gnu_identity"
fi

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

# Process fingerprints come from the kernel's native creation identity, not
# second-resolution `ps lstart` text. Both shell runtimes delegate to the same
# manifest implementation and therefore must produce exactly the same value.
semaphore_identity="$(_uberdev_semaphore_process_identity "$$")"
manifest_identity="$(python3 -I -B "$MANIFEST" process-identity --pid "$$")"
if [ "$semaphore_identity" = "$manifest_identity" ] \
    && grep -Eq "^$$\\|[0-9]+\\|[0-9]+\\|[0-9a-f]{64}$" <<<"$semaphore_identity"; then
  pass "semaphore and manifest share one kernel process identity"
else
  fail "shared kernel process identity" "semaphore=$semaphore_identity manifest=$manifest_identity"
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
   && grep -Eq '^owner_identity=[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}$' "$lease_a" \
   && grep -q '^backend_handle=$' "$lease_a" \
   && grep -q '^backend_identity=$' "$lease_a" \
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
# BACKEND_IDENTITY is the sibling injection vector: it is caller-supplied, is
# written verbatim as `backend_identity=%s` by _uberdev_semaphore_publish_lease,
# and — unlike every lease FIELD — never passes through the newline-free
# `IFS= read -r` loop that establishes single-line-ness for the readers. Its
# `grep -Eq` validation matches per line, so a well-formed first line used to
# smuggle arbitrary extra `key=value` records into the published lease, which
# then trips _uberdev_semaphore_reconcile_locked's fail-closed "malformed lease"
# abort and bricks the whole scope.
poison_backend_identity="$(_uberdev_semaphore_process_identity "$$")"$'\nowner_pid=999999'
capture uberdev_semaphore_set_handle "$lease_handle" "$$" "$status_path" '' '' "$poison_backend_identity"
if [ "$CAPTURE_RC" -eq 2 ] \
   && ! grep -q '^owner_pid=999999$' "$lease_handle" \
   && _uberdev_semaphore_read_lease "$lease_handle"; then
  pass "backend identity newline injection cannot forge lease records"
else
  fail "backend identity newline injection cannot forge lease records" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
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
opaque_lease="$(uberdev_semaphore_acquire "$OPAQUE_STATE" repo wezterm 1 opaque-run 5)"
capture uberdev_semaphore_set_handle "$opaque_lease" 'agent:opaque-123' "$opaque_status"
opaque_set_rc="$CAPTURE_RC"
printf '{"state":"completed"}\n' > "$opaque_status"
capture uberdev_semaphore_reconcile "$OPAQUE_STATE" repo wezterm
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
  lease="$(uberdev_semaphore_acquire "$2" repo wezterm 1 missing-status-run 30)" || exit 1
  uberdev_semaphore_set_handle "$lease" provider-job-123 "$3" || exit 1
  printf "%s\n" "$lease" > "$4"
' _ "$LIB" "$MISSING_STATUS_STATE" "$MISSING_STATUS_PATH" "$MISSING_STATUS_LEASE_FILE"
missing_status_lease="$(cat "$MISSING_STATUS_LEASE_FILE")"
capture uberdev_semaphore_reconcile "$MISSING_STATUS_STATE" repo wezterm
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
for lease_key in version generation run_id owner_pid owner_identity backend_handle backend_identity start_epoch timeout_s status_path; do
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
  . "$1"
  _uberdev_semaphore_python() {
    case " $* " in
      *" secure-write-lease "*)
        printf "called\n" > "$SPY_MARKER"
        cat >/dev/null
        return 97
        ;;
    esac
    command python3 "$@"
  }
  uberdev_semaphore_acquire "$2" repo codex 1 writer-spy 30
' _ "$LIB" "$WRITER_SPY_STATE" "$WRITER_SPY_MARKER"
if [ "$CAPTURE_RC" -eq 2 ] && [ "$(cat "$WRITER_SPY_MARKER" 2>/dev/null)" = called ] \
   && ! find "$WRITER_SPY_STATE" -name '*.lease' -type f -print 2>/dev/null | grep -q .; then
  pass "production acquisition calls the secure writer and propagates its failure"
else
  fail "production acquisition calls the secure writer and propagates its failure" "rc=$CAPTURE_RC out=$CAPTURE_OUT marker=$(cat "$WRITER_SPY_MARKER" 2>/dev/null || true)"
fi

PYTHON_ISOLATION_CALLS="$TMP/python-isolation-calls"
capture /bin/bash -c '
  . "$1"
  calls="$2"
  release_state="$3"
  lease="/tmp/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.lease"
  writer_mode=empty
  _uberdev_semaphore_manifest_tool() {
    printf "%s\n" "/fixture/run_manifest.py"
  }
  _uberdev_semaphore_python() {
    printf "%s\n" "$*" >>"$calls"
    case " $* " in
      *" probe-status "*)
        printf "%s\n" terminal
        return 0
        ;;
      *" secure-write-lease "*)
        cat >/dev/null
        [ "$writer_mode" != colonless ] || printf "%s\n" 123
        return 0
        ;;
      *" secure-lease-identity "*)
        printf "%s\n" 17:29
        return 0
        ;;
      *" secure-remove-lease "*)
        rm -f "$release_lease"
        return 0
        ;;
    esac
    return 99
  }
  status="$(_uberdev_semaphore_status_kind /abs/status.json)"
  status_rc=$?
  _uberdev_semaphore_publish_lease /tmp/scope "$lease" run 1 owner "" "" 1 5 ""
  empty_rc=$?
  writer_mode=colonless
  _uberdev_semaphore_publish_lease /tmp/scope "$lease" run 1 owner "" "" 1 5 ""
  colonless_rc=$?
  release_generation=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  release_scope="$release_state/semaphore-v1/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.scope"
  release_lease="$release_scope/${release_generation}cccccccccccccccccccccccccccccccc.lease"
  mkdir -p "$release_scope"
  printf "version=1\ngeneration=%s\nrun_id=release-isolation\nowner_pid=%s\nowner_identity=\nbackend_handle=\nbackend_identity=\nstart_epoch=1\ntimeout_s=5\nstatus_path=\n" \
    "$release_generation" "$$" >"$release_lease"
  chmod 700 "$release_state" "$release_state/semaphore-v1" "$release_scope"
  chmod 600 "$release_lease"
  _uberdev_semaphore_mutex_acquire() { return 0; }
  _uberdev_semaphore_mutex_release() { return 0; }
  uberdev_semaphore_release "$release_lease"
  release_rc=$?
  first_call="$(sed -n "1p" "$calls")"
  second_call="$(sed -n "2p" "$calls")"
  third_call="$(sed -n "3p" "$calls")"
  fourth_call="$(sed -n "4p" "$calls")"
  fifth_call="$(sed -n "5p" "$calls")"
  printf "status=%s status_rc=%s empty_rc=%s colonless_rc=%s release_rc=%s identity=%s first=%s second=%s third=%s fourth=%s fifth=%s\n" \
    "$status" "$status_rc" "$empty_rc" "$colonless_rc" "$release_rc" \
    "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" "$first_call" "$second_call" "$third_call" "$fourth_call" "$fifth_call"
  [ "$status" = terminal ] \
    && [ "$status_rc" -eq 0 ] \
    && [ "$empty_rc" -eq 2 ] \
    && [ "$colonless_rc" -eq 2 ] \
    && [ "$release_rc" -eq 0 ] \
    && [ ! -e "$release_lease" ] \
    && [ -z "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" ] \
    && [ "$first_call" = "-I -B /fixture/run_manifest.py probe-status --status-path /abs/status.json" ] \
    && [ "$second_call" = "-I -B /fixture/run_manifest.py secure-write-lease --lease-path $lease" ] \
    && [ "$third_call" = "$second_call" ] \
    && [ "$fourth_call" = "-I -B /fixture/run_manifest.py secure-lease-identity --lease-path $release_lease --generation $release_generation" ] \
    && [ "$fifth_call" = "-I -B /fixture/run_manifest.py secure-remove-lease --lease-path $release_lease --generation $release_generation --identity 17:29" ]
' _ "$LIB" "$PYTHON_ISOLATION_CALLS" "$TMP/python-isolation-release"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "status, lease publication, and release isolate Python with exact identity-bound commands"
else
  fail "status, lease publication, and release isolate Python with exact identity-bound commands" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
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
RACE_GATE="$TMP/race-release"
RACE_BARRIER_ERR="$TMP/race-barrier.err"
printf '0\n' > "$TMP/max"
: > "$RACE_BARRIER_ERR"
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
count_race_leases() {
  local scope_root="$RACE_STATE/semaphore-v1" scope lease count=0
  if [ ! -d "$scope_root" ]; then
    printf '0\n'
    return 0
  fi
  for scope in "$scope_root"/*.scope; do
    if [ ! -e "$scope" ] && [ ! -L "$scope" ]; then
      continue
    fi
    [ -d "$scope" ] && [ ! -L "$scope" ] || return 1
    for lease in "$scope"/*.lease; do
      if [ -L "$lease" ]; then
        return 1
      fi
      if [ -f "$lease" ]; then
        count=$((count + 1))
      elif [ -e "$lease" ]; then
        return 1
      fi
    done
  done
  printf '%s\n' "$count"
}

UNSAFE_COUNT_SCOPE="$RACE_STATE/semaphore-v1/unsafe-count.scope"
mkdir -p "$UNSAFE_COUNT_SCOPE"
printf 'unchanged\n' > "$TMP/unsafe-count-victim"
ln -s "$TMP/unsafe-count-victim" "$UNSAFE_COUNT_SCOPE/symlink.lease"
unsafe_count_out="$(count_race_leases 2>"$TMP/unsafe-count.err")"
unsafe_count_rc=$?
if [ "$unsafe_count_rc" -ne 0 ]; then
  pass "lease observation rejects a symlink named as a lease"
else
  fail "lease observation rejects a symlink named as a lease" \
    "rc=$unsafe_count_rc count=$unsafe_count_out stderr=$(cat "$TMP/unsafe-count.err")"
fi
rm -rf "$UNSAFE_COUNT_SCOPE"

mkdir -p "$UNSAFE_COUNT_SCOPE/directory.lease"
unsafe_count_out="$(count_race_leases 2>"$TMP/unsafe-count.err")"
unsafe_count_rc=$?
if [ "$unsafe_count_rc" -ne 0 ]; then
  pass "lease observation rejects a stable non-regular lease candidate"
else
  fail "lease observation rejects a stable non-regular lease candidate" \
    "rc=$unsafe_count_rc count=$unsafe_count_out stderr=$(cat "$TMP/unsafe-count.err")"
fi
rm -rf "$UNSAFE_COUNT_SCOPE"

# Simulate GNU find observing a mutex generation after it was selected for
# traversal but before it can be visited. Lease observation must remain valid
# because mutex generations are unrelated to the direct *.lease population.
OBSERVER_SCOPE="$RACE_STATE/semaphore-v1/observer.scope"
OBSERVER_FIND_BIN="$TMP/observer-find-bin"
mkdir -p "$OBSERVER_SCOPE/.mutex" "$OBSERVER_FIND_BIN"
printf 'lease\n' > "$OBSERVER_SCOPE/observer.lease"
observer_find="$OBSERVER_FIND_BIN/find"
# These variables are expanded by the generated shim, not this test process.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
  'scope=$1' \
  'while [ -d "$scope/.mutex" ]; do sleep 0.01; done' \
  'printf "find: %s/.mutex: No such file or directory\\n" "$scope" >&2' \
  'exit 1' > "$observer_find"
chmod +x "$observer_find"
(sleep 0.02; rm -rf "$OBSERVER_SCOPE/.mutex") &
observer_remover=$!
observer_count="$(PATH="$OBSERVER_FIND_BIN:$PATH" count_race_leases 2>"$TMP/observer-find.err")"
observer_rc=$?
wait "$observer_remover"
observer_remover_rc=$?
if [ "$observer_rc" -eq 0 ] && [ "$observer_count" -eq 1 ] \
   && [ "$observer_remover_rc" -eq 0 ] && [ ! -e "$OBSERVER_SCOPE/.mutex" ] \
   && [ ! -s "$TMP/observer-find.err" ]; then
  pass "lease observation ignores a concurrently removed mutex generation"
else
  fail "lease observation ignores a concurrently removed mutex generation" \
    "rc=$observer_rc remover_rc=$observer_remover_rc count=$observer_count stderr=$(cat "$TMP/observer-find.err")"
fi
rm -rf "$OBSERVER_SCOPE" "$OBSERVER_FIND_BIN"

race_pids=""
n=1
while [ "$n" -le 8 ]; do
  (
    UBERDEV_SEMAPHORE_ACQUIRE_MAX_TRIES=1000
    export UBERDEV_SEMAPHORE_ACQUIRE_MAX_TRIES
    # shellcheck source=/dev/null
    . "$LIB"
    lease="$(uberdev_semaphore_acquire "$RACE_STATE" race-repo codex 3 "run-$n" 5)" || exit 1
    [ -n "$lease" ] || exit 1
    active="$(count_race_leases)" || exit 1
    record_max "$active" || exit 1
    holder_slot=''
    slot=1
    while [ "$slot" -le 3 ]; do
      if mkdir "$TMP/race-holder-$slot" 2>/dev/null; then
        holder_slot="$slot"
        break
      fi
      slot=$((slot + 1))
    done
    if [ -n "$holder_slot" ]; then
      gate_tries=0
      while [ ! -f "$RACE_GATE" ] && [ "$gate_tries" -lt 1000 ]; do
        sleep 0.01
        gate_tries=$((gate_tries + 1))
      done
      if [ ! -f "$RACE_GATE" ]; then
        live_now="$(count_race_leases)" || {
          printf 'holder %s could not count live leases\n' "$holder_slot" >&2
          uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
          exit 1
        }
        printf 'holder %s timed out waiting for release gate (live=%s tries=%s)\n' \
          "$holder_slot" "$live_now" "$gate_tries" >&2
        uberdev_semaphore_release "$lease" >/dev/null 2>&1 || true
        exit 1
      fi
    fi
    uberdev_semaphore_release "$lease" || exit 1
  ) 2>"$TMP/race-$n.err" &
  race_pids="$race_pids $!"
  n=$((n + 1))
done
barrier_ready=0
barrier_tries=0
barrier_live=0
barrier_holders=0
while [ "$barrier_tries" -lt 500 ]; do
  barrier_live="$(count_race_leases)" || {
    printf 'parent could not count live leases (tries=%s)\n' \
      "$barrier_tries" > "$RACE_BARRIER_ERR"
    break
  }
  barrier_holders="$(find "$TMP" -maxdepth 1 -name 'race-holder-*' -type d | wc -l | tr -d ' ')"
  record_max "$barrier_live" || {
    printf 'parent could not record live lease count (live=%s tries=%s)\n' \
      "$barrier_live" "$barrier_tries" > "$RACE_BARRIER_ERR"
    break
  }
  if [ "$barrier_live" -eq 3 ] && [ "$barrier_holders" -eq 3 ]; then
    barrier_ready=1
    break
  fi
  if [ "$barrier_live" -gt 3 ]; then
    printf 'semaphore exceeded cap before barrier release (live=%s holders=%s tries=%s)\n' \
      "$barrier_live" "$barrier_holders" "$barrier_tries" > "$RACE_BARRIER_ERR"
    break
  fi
  sleep 0.01
  barrier_tries=$((barrier_tries + 1))
done
if [ "$barrier_ready" -ne 1 ] && [ ! -s "$RACE_BARRIER_ERR" ]; then
  printf 'parent timed out waiting for saturated barrier (live=%s holders=%s tries=%s)\n' \
    "$barrier_live" "$barrier_holders" "$barrier_tries" > "$RACE_BARRIER_ERR"
fi
: > "$RACE_GATE"
race_rc=0
for pid in $race_pids; do wait "$pid" || race_rc=1; done
race_pids=""
observed_max="$(cat "$TMP/max")"
printf 'observed_max=%s\n' "$observed_max"
remaining="$(count_race_leases)" || {
  remaining=count-error
  race_rc=1
}
race_stderr="$(cat "$TMP"/race-*.err "$RACE_BARRIER_ERR")"
if [ "$race_rc" -eq 0 ] && [ "$barrier_ready" -eq 1 ] && [ "$observed_max" -eq 3 ] \
   && [ "$remaining" -eq 0 ] && [ -z "$race_stderr" ]; then
  pass "eight contenders eventually acquire/release without exceeding cap 3"
else
  fail "eight contenders eventually acquire/release without exceeding cap 3" \
    "race_rc=$race_rc barrier_ready=$barrier_ready observed_max=$observed_max remaining=$remaining stderr=$race_stderr"
fi

# Releasing a mutex quarantines its directory generation. A racing observer
# must treat a legitimate generation replacement or owner disappearance as
# contention, while stable non-regular owner paths remain fail-closed above.
printf '== live semaphore: mutex generation replacement stress ==\n'
REPLACE_SCOPE="$TMP/mutex-replacement.scope"
mkdir -p "$REPLACE_SCOPE/.mutex"
printf '%s\n%s\n' "$$" '11111111111111111111111111111111' > "$REPLACE_SCOPE/.mutex/owner_pid"
replace_rc=0
replace_err="$TMP/mutex-replacement.err"
: > "$replace_err"
(
  round=0
  while [ "$round" -lt 400 ]; do
    old="$REPLACE_SCOPE/.old-$round"
    if mv "$REPLACE_SCOPE/.mutex" "$old" 2>/dev/null; then
      mkdir "$REPLACE_SCOPE/.mutex" || exit 1
      printf '%s\n%s\n' "$$" '11111111111111111111111111111111' > "$REPLACE_SCOPE/.mutex/owner_pid"
      rm -rf "$old"
    fi
    round=$((round + 1))
  done
) &
replace_writer=$!
round=0
while [ "$round" -lt 800 ]; do
  _uberdev_semaphore_mutex_reclaim_dead "$REPLACE_SCOPE" 0 2>>"$replace_err"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    replace_rc=1
    break
  fi
  round=$((round + 1))
done
wait "$replace_writer" || replace_rc=1
if [ "$replace_rc" -eq 0 ] && ! grep -q 'unsafe mutex owner path' "$replace_err"; then
  pass "mutex generation replacement remains ordinary contention"
else
  fail "mutex generation replacement remains ordinary contention" "$(cat "$replace_err")"
fi

printf '== live semaphore: mutex PID reuse identity ==\n'
PID_REUSE_SCOPE="$TMP/mutex-pid-reuse.scope"
mkdir -p "$PID_REUSE_SCOPE/.mutex"
printf '%s\n%s\n%s\n' "$$" '1|1|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '11111111111111111111111111111111' >"$PID_REUSE_SCOPE/.mutex/owner_pid"
eval "$(declare -f _uberdev_semaphore_process_identity | sed '1s/_uberdev_semaphore_process_identity/_real_semaphore_process_identity/')"
_uberdev_semaphore_process_identity() {
  printf '%s\n' "$$|$$|$$|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
capture _uberdev_semaphore_mutex_reclaim_dead "$PID_REUSE_SCOPE" 1
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -e "$PID_REUSE_SCOPE/.mutex" ]; then
  pass "reused live PID does not preserve a stale mutex generation"
else
  fail "reused live PID does not preserve a stale mutex generation" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
eval "$(declare -f _real_semaphore_process_identity | sed '1s/_real_semaphore_process_identity/_uberdev_semaphore_process_identity/')"

printf '== live semaphore: lifecycle lease PID reuse identity ==\n'
LEASE_IDENTITY_STATE="$TMP/lease-pid-reuse-state"
LEASE_IDENTITY_PATH_FILE="$TMP/lease-pid-reuse-path"
sleep 30 & backend_pid=$!
LEASE_BACKEND_IDENTITY="$(_uberdev_semaphore_process_identity "$backend_pid")"
/bin/bash -c '
  . "$1"
  lease="$(uberdev_semaphore_acquire "$2" repo codex 1 lease-pid-reuse 30)" || exit 1
  uberdev_semaphore_set_handle "$lease" "$3" "" exact-identity lease_identity "$4" || exit 1
  printf "%s\n" "$lease" >"$5"
' _ "$LIB" "$LEASE_IDENTITY_STATE" "$backend_pid" "$LEASE_BACKEND_IDENTITY" "$LEASE_IDENTITY_PATH_FILE"
lease_identity_path="$(cat "$LEASE_IDENTITY_PATH_FILE")"
capture uberdev_semaphore_reconcile "$LEASE_IDENTITY_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 0 ] && [ -f "$lease_identity_path" ]; then
  pass "matching backend identity retains lifecycle capacity"
else
  fail "matching backend identity retains lifecycle capacity" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
eval "$(declare -f _uberdev_semaphore_process_identity | sed '1s/_uberdev_semaphore_process_identity/_real_lease_process_identity/')"
_uberdev_semaphore_process_identity() {
  if [ "$1" = "$backend_pid" ]; then return 2; fi
  _real_lease_process_identity "$@"
}
capture uberdev_semaphore_reconcile "$LEASE_IDENTITY_STATE" repo codex
if [ "$CAPTURE_RC" -eq 2 ] && [ -f "$lease_identity_path" ] \
    && grep -q 'process identity probe unavailable' <<<"$CAPTURE_OUT"; then
  pass "unavailable backend identity probe retains lifecycle capacity with an error"
else
  fail "unavailable backend identity probe retains lifecycle capacity with an error" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi
_uberdev_semaphore_process_identity() {
  if [ "$1" = "$backend_pid" ]; then
    printf '%s\n' "$backend_pid|$backend_pid|$backend_pid|cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    return 0
  fi
  _real_lease_process_identity "$@"
}
if [ -f "$lease_identity_path" ]; then
  capture uberdev_semaphore_reconcile "$LEASE_IDENTITY_STATE" repo codex
  if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 1 ] && [ ! -e "$lease_identity_path" ]; then
    reacquired="$(uberdev_semaphore_acquire "$LEASE_IDENTITY_STATE" repo codex 1 lease-pid-reuse-reacquired 30)"
    uberdev_semaphore_release "$reacquired" >/dev/null 2>&1 || true
    pass "mismatched live backend identity releases the exact lifecycle lease"
  else
    fail "mismatched live backend identity releases the exact lifecycle lease" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
  fi
else
  fail "mismatched live backend identity releases the exact lifecycle lease" "lease was removed while identity evidence was unavailable"
fi
eval "$(declare -f _real_lease_process_identity | sed '1s/_real_lease_process_identity/_uberdev_semaphore_process_identity/')"
kill "$backend_pid" 2>/dev/null || true
wait "$backend_pid" 2>/dev/null || true
backend_pid=""

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

printf '== live semaphore: terminal pre-handle reconciliation ==\n'
PREHANDLE_STATE="$TMP/terminal-prehandle-state"
prehandle_status="$TMP/terminal-prehandle-status.json"
cp "$FIXTURES/terminal-status.json" "$prehandle_status"
prehandle_record=''
uberdev_semaphore_acquire "$PREHANDLE_STATE" repo codex 1 terminal-prehandle-live 30 \
  exact-identity prehandle_record || fail "acquire live terminal pre-handle lease" "acquisition failed"
IFS=$'\t' read -r prehandle_lease prehandle_identity <<EOF_PREHANDLE
$prehandle_record
EOF_PREHANDLE
prehandle_registered_identity=''
uberdev_semaphore_set_handle "$prehandle_lease" '' "$prehandle_status" \
  exact-identity prehandle_registered_identity \
  || fail "register live terminal pre-handle status" "registration failed"
capture uberdev_semaphore_reconcile "$PREHANDLE_STATE" repo codex
prehandle_live_rc="$CAPTURE_RC"
prehandle_live_out="$CAPTURE_OUT"
prehandle_bound_identity=''
if uberdev_semaphore_set_handle "$prehandle_lease" 'opaque:terminal-prehandle' "$prehandle_status" \
    exact-identity prehandle_bound_identity; then
  prehandle_bind_rc=0
else
  prehandle_bind_rc=$?
fi
capture uberdev_semaphore_reconcile "$PREHANDLE_STATE" repo codex
if [ "$prehandle_live_rc" -eq 0 ] && [ "$prehandle_live_out" = 0 ] \
    && [ "$prehandle_bind_rc" -eq 0 ] && [ -n "$prehandle_bound_identity" ] \
    && [ "${prehandle_identity##*:}" = "${prehandle_registered_identity##*:}" ] \
    && [ "${prehandle_identity##*:}" = "${prehandle_bound_identity##*:}" ] \
    && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 1 ] && [ ! -e "$prehandle_lease" ]; then
  pass "live unexpired terminal pre-handle survives reconciliation until its handle binds"
else
  fail "live unexpired terminal pre-handle survives reconciliation until its handle binds" \
    "reconcile=$prehandle_live_rc/$prehandle_live_out bind=$prehandle_bind_rc final=$CAPTURE_RC/$CAPTURE_OUT lease=$(test -e "$prehandle_lease" && printf present || printf absent)"
fi

PREHANDLE_DEAD_STATE="$TMP/terminal-prehandle-dead-state"
prehandle_dead_path_file="$TMP/terminal-prehandle-dead-path"
/bin/bash -c '
  . "$1"
  owner_pid="${BASHPID:-$$}"
  lease="$(UBERDEV_SEMAPHORE_OWNER_PID="$owner_pid" \
    uberdev_semaphore_acquire "$2" repo codex 1 terminal-prehandle-dead 1)" || exit 1
  uberdev_semaphore_set_handle "$lease" "" "$3" || exit 1
  printf "%s\n" "$lease" >"$4"
' _ "$LIB" "$PREHANDLE_DEAD_STATE" "$prehandle_status" "$prehandle_dead_path_file"
prehandle_dead_lease="$(cat "$prehandle_dead_path_file")"
capture uberdev_semaphore_reconcile "$PREHANDLE_DEAD_STATE" repo codex
prehandle_dead_fresh_rc="$CAPTURE_RC"
prehandle_dead_fresh_out="$CAPTURE_OUT"
prehandle_dead_fresh_present=0
[ ! -f "$prehandle_dead_lease" ] || prehandle_dead_fresh_present=1
sleep 2
capture uberdev_semaphore_reconcile "$PREHANDLE_DEAD_STATE" repo codex
if [ -n "$prehandle_dead_lease" ] && [ "$prehandle_dead_fresh_rc" -eq 0 ] \
    && [ "$prehandle_dead_fresh_out" = 0 ] && [ "$prehandle_dead_fresh_present" -eq 1 ] \
    && [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 1 ] && [ ! -e "$prehandle_dead_lease" ]; then
  pass "dead-owner terminal pre-handle is retained only until its deadline"
else
  fail "dead-owner terminal pre-handle is retained only until its deadline" \
    "fresh=$prehandle_dead_fresh_rc/$prehandle_dead_fresh_out/$prehandle_dead_fresh_present expired=$CAPTURE_RC/$CAPTURE_OUT lease=$(test -e "$prehandle_dead_lease" && printf present || printf absent)"
fi

PREHANDLE_EXPIRED_STATE="$TMP/terminal-prehandle-expired-state"
prehandle_expired_record=''
uberdev_semaphore_acquire "$PREHANDLE_EXPIRED_STATE" repo codex 1 terminal-prehandle-expired 1 \
  exact-identity prehandle_expired_record || fail "acquire expiring terminal pre-handle lease" "acquisition failed"
IFS=$'\t' read -r prehandle_expired_lease _ <<EOF_EXPIRED
$prehandle_expired_record
EOF_EXPIRED
uberdev_semaphore_set_handle "$prehandle_expired_lease" '' "$prehandle_status" >/dev/null \
  || fail "register expiring terminal pre-handle status" "registration failed"
sleep 2
capture uberdev_semaphore_reconcile "$PREHANDLE_EXPIRED_STATE" repo codex
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 1 ] && [ ! -e "$prehandle_expired_lease" ]; then
  pass "expired terminal pre-handle is reclaimed even while its owner is live"
else
  fail "expired terminal pre-handle is reclaimed even while its owner is live" \
    "rc=$CAPTURE_RC removed=$CAPTURE_OUT lease=$(test -e "$prehandle_expired_lease" && printf present || printf absent)"
fi

PREHANDLE_UNKNOWN_STATE="$TMP/terminal-prehandle-unknown-state"
prehandle_probe_sentinel="$TMP/terminal-prehandle-owner-probe-called"
prehandle_unknown_record=''
uberdev_semaphore_acquire "$PREHANDLE_UNKNOWN_STATE" repo codex 1 terminal-prehandle-unknown 30 \
  exact-identity prehandle_unknown_record || fail "acquire unknown-owner terminal pre-handle lease" "acquisition failed"
IFS=$'\t' read -r prehandle_unknown_lease _ <<EOF_UNKNOWN
$prehandle_unknown_record
EOF_UNKNOWN
uberdev_semaphore_set_handle "$prehandle_unknown_lease" '' "$prehandle_status" >/dev/null \
  || fail "register unknown-owner terminal pre-handle status" "registration failed"
capture /bin/bash -c '
  . "$1"
  probe_sentinel="$3"
  lease_owner="$(sed -n "s/^owner_pid=//p" "$4")"
  _uberdev_semaphore_process_identity() {
    if [ "$1" = "$lease_owner" ]; then
      printf "called\n" >"$probe_sentinel"
      return 2
    fi
    manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
    _uberdev_semaphore_python -I -B "$manifest_tool" process-identity --pid "$1"
  }
  uberdev_semaphore_reconcile "$2" repo codex
' _ "$LIB" "$PREHANDLE_UNKNOWN_STATE" "$prehandle_probe_sentinel" "$prehandle_unknown_lease"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$CAPTURE_OUT" = 0 ] \
    && [ -f "$prehandle_unknown_lease" ] && [ ! -e "$prehandle_probe_sentinel" ]; then
  pass "fresh terminal pre-handle retention does not consult owner liveness"
else
  fail "fresh terminal pre-handle retention does not consult owner liveness" \
    "rc=$CAPTURE_RC out=$CAPTURE_OUT probe=$(test -e "$prehandle_probe_sentinel" && printf called || printf untouched) lease=$(test -e "$prehandle_unknown_lease" && printf present || printf absent)"
fi
uberdev_semaphore_release "$prehandle_unknown_lease" >/dev/null 2>&1 || true

printf '== live semaphore: bounded and recoverable mutex ==\n'
PROBE_RECLAIM_SCOPE="$TMP/probe-reclaim-scope"
PROBE_RECLAIM_CALLS="$TMP/probe-reclaim-calls"
mkdir -p "$PROBE_RECLAIM_SCOPE/.mutex"
capture /bin/bash -c '
  . "$1"
  scope="$2"
  calls_file="$3"
  printf "0\n" >"$calls_file"
  _uberdev_semaphore_mutex_reclaim_dead() {
    current="$(cat "$calls_file")"
    current=$((current + 1))
    printf "%s\n" "$current" >"$calls_file"
    rmdir "$1/.mutex" || return 2
    mkdir "$1/.mutex" || return 2
    [ "$current" -lt 3 ] && return 0
    return 2
  }
  UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES=1
  UBERDEV_SEMAPHORE_MUTEX_PROBE_ONLY=1
  UBERDEV_SEMAPHORE_MUTEX_QUIET_BUSY=1
  export UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES UBERDEV_SEMAPHORE_MUTEX_PROBE_ONLY
  export UBERDEV_SEMAPHORE_MUTEX_QUIET_BUSY
  _uberdev_semaphore_mutex_acquire "$scope"
  rc=$?
  calls="$(cat "$calls_file")"
  printf "rc=%s calls=%s\n" "$rc" "$calls"
  [ "$rc" -eq 75 ] && [ "$calls" -eq 1 ] && [ -d "$scope/.mutex" ]
' _ "$LIB" "$PROBE_RECLAIM_SCOPE" "$PROBE_RECLAIM_CALLS"
if [ "$CAPTURE_RC" -eq 0 ]; then
  pass "probe-only reclaim consumes its single observation budget"
else
  fail "probe-only reclaim consumes its single observation budget" "rc=$CAPTURE_RC out=$CAPTURE_OUT"
fi

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
