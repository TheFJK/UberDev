#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SKILL" "$TMP/runtime.sh" <<'PY'
import re,sys
from pathlib import Path

text=Path(sys.argv[1]).read_text(encoding='utf-8')
match=re.search(r'```bash\n(sdd_validate_instance_dimensions\(\).*?\n)```',text,re.S)
if not match: raise SystemExit('SDD routed runtime fence missing')
Path(sys.argv[2]).write_text(match.group(1),encoding='utf-8')
PY

cat >"$TMP/two-batches.sh" <<'SH'
set -euo pipefail
SDD_WORKTREE="$1"
SDD_CHILD_TIMEOUT=17
dispatch_log="$2"
: >"$dispatch_log"
. "$3"

uberdev_create_child_handoff() {
  UBERDEV_CHILD_HANDOFF="/tmp/handoff|$2"
  UBERDEV_CHILD_HANDOFF_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest(),end="")' "$UBERDEV_CHILD_HANDOFF")"
  UBERDEV_CHILD_STATUS="/tmp/status|$2"
  UBERDEV_CHILD_RESULT="/tmp/result|$2"
}
uberdev_preflight_child_batch() { [ "$#" -gt 0 ] && [ $(( $# % 2 )) -eq 0 ]; }
uberdev_dispatch_child() {
  [ "$#" -eq 5 ] && [[ "$3" =~ ^[0-9a-f]{64}$ ]]
  printf '%s\n' "$1:$2:$3:$4:$5" >>"$dispatch_log"
}
uberdev_wait_child() { printf 'done\n' >"$2"; return 0; }
uberdev_unwind_child() { return 99; }

sdd_begin_batch
sdd_dispatch_prepared edge.one batch1-a '{}' '[]'
sdd_dispatch_prepared edge.one batch1-b '{}' '[]'
[ "${#SDD_PREPARED_HANDOFF_SHA256S[@]}" -eq 2 ]
[[ "${SDD_PREPARED_HANDOFF_SHA256S[0]}" =~ ^[0-9a-f]{64}$ ]]
[[ "${SDD_PREPARED_HANDOFF_SHA256S[1]}" =~ ^[0-9a-f]{64}$ ]]
sdd_launch_prepared_batch
sdd_wait_prepared_batch "$SDD_CHILD_TIMEOUT"

sdd_begin_batch
sdd_dispatch_prepared edge.two batch2-a '{}' '[]'
sdd_launch_prepared_batch
sdd_wait_prepared_batch "$SDD_CHILD_TIMEOUT"

[ "$(wc -l <"$dispatch_log" | tr -d ' ')" -eq 3 ]
[ "$(grep -c 'batch1-a' "$dispatch_log")" -eq 1 ]
[ "$(grep -c 'batch1-b' "$dispatch_log")" -eq 1 ]
[ "$(grep -c 'batch2-a' "$dispatch_log")" -eq 1 ]
[ "${#SDD_PREPARED_HANDOFFS[@]}" -eq 0 ]
[ "${#SDD_PREPARED_HANDOFF_SHA256S[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_INSTANCES[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_STATUSES[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_RESULTS[@]}" -eq 0 ]
SH

cat >"$TMP/wait-failure.sh" <<'SH'
set -euo pipefail
SDD_WORKTREE="$1"
SDD_CHILD_TIMEOUT=23
wait_log="$2"; unwind_log="$3"
: >"$wait_log"; : >"$unwind_log"
. "$4"

uberdev_create_child_handoff() {
  UBERDEV_CHILD_HANDOFF="/tmp/handoff|$2"
  UBERDEV_CHILD_HANDOFF_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest(),end="")' "$UBERDEV_CHILD_HANDOFF")"
  UBERDEV_CHILD_STATUS="/tmp/status|$2"
  UBERDEV_CHILD_RESULT="/tmp/result|$2"
}
uberdev_preflight_child_batch() { [ "$#" -gt 0 ] && [ $(( $# % 2 )) -eq 0 ]; }
uberdev_dispatch_child() { [ "$#" -eq 5 ] && [[ "$3" =~ ^[0-9a-f]{64}$ ]]; }
uberdev_wait_child() {
  printf '%s\n' "$1" >>"$wait_log"
  case "$1" in
    *wait-fails) return 7 ;;
    *sibling-running) return 9 ;;
    *) return 0 ;;
  esac
}
uberdev_unwind_child() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$unwind_log"
  return 0
}

sdd_begin_batch
sdd_dispatch_prepared edge.one first-ok '{}' '[]'
sdd_dispatch_prepared edge.one wait-fails '{}' '[]'
sdd_dispatch_prepared edge.one sibling-running '{}' '[]'
[ "${#SDD_PREPARED_HANDOFF_SHA256S[@]}" -eq 3 ]
sdd_launch_prepared_batch
rc=0
sdd_wait_prepared_batch "$SDD_CHILD_TIMEOUT" || rc=$?

[ "$rc" -eq 7 ]
[ "$(wc -l <"$wait_log" | tr -d ' ')" -eq 3 ]
[ "$(wc -l <"$unwind_log" | tr -d ' ')" -eq 2 ]
grep -Fq $'/tmp/status|wait-fails\t/tmp/result|wait-fails\t23' "$unwind_log"
grep -Fq $'/tmp/status|sibling-running\t/tmp/result|sibling-running\t23' "$unwind_log"
[ "${#SDD_PREPARED_HANDOFFS[@]}" -eq 0 ]
[ "${#SDD_PREPARED_HANDOFF_SHA256S[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_INSTANCES[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_STATUSES[@]}" -eq 0 ]
[ "${#SDD_RECEIPT_RESULTS[@]}" -eq 0 ]
SH

bash "$TMP/two-batches.sh" "$ROOT" "$TMP/dispatch.log" "$TMP/runtime.sh"
bash "$TMP/wait-failure.sh" "$ROOT" "$TMP/wait.log" "$TMP/unwind.log" "$TMP/runtime.sh"

echo 'sdd-routed-lifecycle: PASS'
