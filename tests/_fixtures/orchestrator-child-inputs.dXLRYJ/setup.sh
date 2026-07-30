set -euo pipefail
: "${UBERDEV_AGENT_PREPARED_REQUEST_JSON:?missing immutable routing context}"
UBERDEV_DESIGN_PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
. "$UBERDEV_DESIGN_PLUGIN_ROOT/lib/child-dispatch.sh"

UBERDEV_DESIGN_PREPARED_EDGES=()
UBERDEV_DESIGN_PREPARED_INSTANCES=()
UBERDEV_DESIGN_PREPARED_HANDOFFS=()
UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S=()
UBERDEV_DESIGN_PREPARED_RESULTS=()
UBERDEV_DESIGN_PREPARED_STATUSES=()
UBERDEV_DESIGN_DISPATCH_RECEIPTS=()
UBERDEV_DESIGN_RECEIPT_STATUSES=()
UBERDEV_DESIGN_RECEIPT_RESULTS=()
UBERDEV_DESIGN_WAITED_INSTANCES=()
UBERDEV_DESIGN_WAITED=0
UBERDEV_DESIGN_BATCH_LAUNCHED=0
UBERDEV_DESIGN_UNWIND_TIMEOUT="${UBERDEV_DESIGN_UNWIND_TIMEOUT:-600}"
case "$UBERDEV_DESIGN_UNWIND_TIMEOUT" in ''|*[!0-9]*|0) return 2 ;; esac

uberdev_design_json_string() {
  [ "$#" -eq 1 ] || return 2
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "${@:1:1}"
}

uberdev_design_reset_batch() {
  UBERDEV_DESIGN_PREPARED_EDGES=(); UBERDEV_DESIGN_PREPARED_INSTANCES=()
  UBERDEV_DESIGN_PREPARED_HANDOFFS=(); UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S=()
  UBERDEV_DESIGN_PREPARED_RESULTS=()
  UBERDEV_DESIGN_PREPARED_STATUSES=(); UBERDEV_DESIGN_DISPATCH_RECEIPTS=()
  UBERDEV_DESIGN_RECEIPT_STATUSES=(); UBERDEV_DESIGN_RECEIPT_RESULTS=()
  UBERDEV_DESIGN_WAITED_INSTANCES=()
  UBERDEV_DESIGN_WAITED=0; UBERDEV_DESIGN_BATCH_LAUNCHED=0
}

uberdev_unwind_child_receipts() {
  local index status result cleanup_rc=0
  for ((index=0; index<${#UBERDEV_DESIGN_DISPATCH_RECEIPTS[@]}; index++)); do
    status="${UBERDEV_DESIGN_RECEIPT_STATUSES[$index]}"
    result="${UBERDEV_DESIGN_RECEIPT_RESULTS[$index]}"
    if ! uberdev_unwind_child "$status" "$result" "$UBERDEV_DESIGN_UNWIND_TIMEOUT"; then
      cleanup_rc=1
    fi
  done
  uberdev_design_reset_batch
  return "$cleanup_rc"
}

uberdev_design_drain_after_wait_failure() {
  local index instance waited status result skip cleanup_rc=0
  for ((index=0; index<${#UBERDEV_DESIGN_DISPATCH_RECEIPTS[@]}; index++)); do
    instance="${UBERDEV_DESIGN_DISPATCH_RECEIPTS[$index]}"
    skip=0
    for waited in "${UBERDEV_DESIGN_WAITED_INSTANCES[@]}"; do
      [ "$instance" = "$waited" ] && skip=1 && break
    done
    [ "$skip" -eq 1 ] && continue
    status="${UBERDEV_DESIGN_RECEIPT_STATUSES[$index]}"
    result="${UBERDEV_DESIGN_RECEIPT_RESULTS[$index]}"
    if ! uberdev_unwind_child "$status" "$result" "$UBERDEV_DESIGN_UNWIND_TIMEOUT"; then
      cleanup_rc=1
    fi
  done
  uberdev_design_reset_batch
  return "$cleanup_rc"
}

uberdev_design_dispatch() {
  local edge="${@:1:1}" instance="${@:2:1}" role="${@:3:1}" phase="${@:4:1}" risk_scope="${@:5:1}" risks_json="${@:6:1}" inputs_json="${@:7:1}"
  local handoff handoff_sha256 result status create_rc cleanup_rc
  : "$role" "$phase" "$risk_scope" # edge manifest is the authority for these fields
  if uberdev_create_child_handoff "$edge" "$instance" "$inputs_json" "$risks_json"; then
    :
  else
    create_rc=$?; cleanup_rc=0
    uberdev_unwind_child_receipts || cleanup_rc=$?
    [ "$cleanup_rc" -eq 0 ] || echo "error: child receipt unwind failed after handoff edge=$edge instance=$instance" >&2
    return "$create_rc"
  fi
  handoff="$UBERDEV_CHILD_HANDOFF"
  handoff_sha256="$UBERDEV_CHILD_HANDOFF_SHA256"
  result="$UBERDEV_CHILD_RESULT"
  status="$UBERDEV_CHILD_STATUS"
  UBERDEV_DESIGN_PREPARED_EDGES+=("$edge")
  UBERDEV_DESIGN_PREPARED_INSTANCES+=("$instance")
  UBERDEV_DESIGN_PREPARED_HANDOFFS+=("$handoff")
  UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S+=("$handoff_sha256")
  UBERDEV_DESIGN_PREPARED_RESULTS+=("$result")
  UBERDEV_DESIGN_PREPARED_STATUSES+=("$status")
}

uberdev_design_launch_batch() {
  local index edge instance handoff handoff_sha256 result status dispatch_rc cleanup_rc
  local preflight_refs=()
  [ "${#UBERDEV_DESIGN_PREPARED_HANDOFFS[@]}" -gt 0 ] || return 2
  [ "${#UBERDEV_DESIGN_PREPARED_HANDOFFS[@]}" -eq "${#UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S[@]}" ] || return 2
  for ((index=0; index<${#UBERDEV_DESIGN_PREPARED_HANDOFFS[@]}; index++)); do
    preflight_refs+=("${UBERDEV_DESIGN_PREPARED_HANDOFFS[$index]}" "${UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S[$index]}")
  done
  uberdev_preflight_child_batch "${preflight_refs[@]}" || {
    dispatch_rc=$?; uberdev_design_reset_batch; return "$dispatch_rc"
  }
  for ((index=0; index<${#UBERDEV_DESIGN_PREPARED_HANDOFFS[@]}; index++)); do
    edge="${UBERDEV_DESIGN_PREPARED_EDGES[$index]}"
    instance="${UBERDEV_DESIGN_PREPARED_INSTANCES[$index]}"
    handoff="${UBERDEV_DESIGN_PREPARED_HANDOFFS[$index]}"
    handoff_sha256="${UBERDEV_DESIGN_PREPARED_HANDOFF_SHA256S[$index]}"
    result="${UBERDEV_DESIGN_PREPARED_RESULTS[$index]}"
    status="${UBERDEV_DESIGN_PREPARED_STATUSES[$index]}"
    if uberdev_dispatch_child "$edge" "$handoff" "$handoff_sha256" "$result" "$status" >/dev/null; then
      UBERDEV_DESIGN_DISPATCH_RECEIPTS+=("$instance")
      UBERDEV_DESIGN_RECEIPT_STATUSES+=("$status")
      UBERDEV_DESIGN_RECEIPT_RESULTS+=("$result")
    else
      dispatch_rc=$?; cleanup_rc=0
      uberdev_unwind_child_receipts || cleanup_rc=$?
      [ "$cleanup_rc" -eq 0 ] || echo "error: bounded child unwind failed after edge=$edge instance=$instance" >&2
      return "$dispatch_rc"
    fi
  done
  UBERDEV_DESIGN_BATCH_LAUNCHED=1
}

uberdev_design_wait() {
  local wanted="${@:1:1}" timeout_s="${@:2:1}" index instance status result wait_rc cleanup_rc
  if [ "$UBERDEV_DESIGN_BATCH_LAUNCHED" -eq 0 ]; then
    uberdev_design_launch_batch || return $?
  fi
  for ((index=0; index<${#UBERDEV_DESIGN_DISPATCH_RECEIPTS[@]}; index++)); do
    instance="${UBERDEV_DESIGN_DISPATCH_RECEIPTS[$index]}"
    if [ "$instance" = "$wanted" ]; then
      status="${UBERDEV_DESIGN_RECEIPT_STATUSES[$index]}"
      result="${UBERDEV_DESIGN_RECEIPT_RESULTS[$index]}"
      if uberdev_wait_child "$status" "$result" "$timeout_s"; then
        :
      else
        wait_rc=$?; cleanup_rc=0
        uberdev_design_drain_after_wait_failure || cleanup_rc=$?
        [ "$cleanup_rc" -eq 0 ] || echo "error: bounded sibling unwind failed after wait instance=$wanted" >&2
        return "$wait_rc"
      fi
      UBERDEV_DESIGN_WAITED_INSTANCES+=("$wanted")
      UBERDEV_DESIGN_WAITED=$((UBERDEV_DESIGN_WAITED + 1))
      if [ "$UBERDEV_DESIGN_WAITED" -eq "${#UBERDEV_DESIGN_DISPATCH_RECEIPTS[@]}" ]; then
        uberdev_design_reset_batch
      fi
      return 0
    fi
  done
  cleanup_rc=0
  uberdev_design_drain_after_wait_failure || cleanup_rc=$?
  [ "$cleanup_rc" -eq 0 ] || echo "error: bounded sibling unwind failed after missing receipt instance=$wanted" >&2
  return 2
}
