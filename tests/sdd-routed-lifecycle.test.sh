#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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

# ---------------------------------------------------------------------------
# L-A … L-G — the wave-disjointness refusal (#509).
#
# SDD's core principle inverts an explicit upstream prohibition: it dispatches
# every implementer of a wave in parallel into ONE shared worktree. What makes
# that safe is a strictly disjoint per-task file partition — and until this
# fixture existed, that partition was asserted in prose and checked by nothing at
# dispatch time. `sdd_assert_wave_disjoint` is the refusal; these rows are what
# make it falsifiable.
#
# The fixture takes <worktree> <dispatch_log> <runtime> <case> so the SAME file
# can be launched under bash and zsh, and it uses only constructs proven in both
# (`${@:N:1}`, `ARR+=(…)`, `${#ARR[@]}`, `[ … ]`, `case`) — no `[[ =~ ]]`, no
# `${ARR[$i]}`, no `type -t`, no `BASH_REMATCH`.
# ---------------------------------------------------------------------------
cat >"$TMP/wave-guard.sh" <<'SH'
set -u
SDD_WORKTREE="$1"
SDD_CHILD_TIMEOUT=11
dispatch_log="$2"
: >"$dispatch_log"
. "$3"
guard_case="$4"

# argv-only, so nothing this builds can be corrupted by shell quoting.
wave_inputs() {
  python3 -I -B -c 'import json,sys; print(json.dumps({"allowed_paths":sys.argv[1:]},separators=(",",":")),end="")' "$@"
}

uberdev_create_child_handoff() {
  UBERDEV_CHILD_HANDOFF="/tmp/handoff|${@:2:1}"
  UBERDEV_CHILD_HANDOFF_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest(),end="")' "$UBERDEV_CHILD_HANDOFF")"
  UBERDEV_CHILD_STATUS="/tmp/status|${@:2:1}"
  UBERDEV_CHILD_RESULT="/tmp/result|${@:2:1}"
}
uberdev_preflight_child_batch() { [ "$#" -gt 0 ] || return 2; }
uberdev_dispatch_child() {
  [ "$#" -eq 5 ] || return 2
  printf '%s\n' "${@:1:1}:${@:2:1}" >>"$dispatch_log"
}
uberdev_wait_child() { return 0; }
uberdev_unwind_child() { return 0; }

edge_under_test=sdd.task.implement
case "$guard_case" in
  disjoint)
    wave_a_json="$(wave_inputs "$SDD_WORKTREE/lib/a.sh")"
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/b.sh")"
    ;;
  identical)
    wave_a_json="$(wave_inputs "$SDD_WORKTREE/lib/same.sh")"
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/same.sh")"
    ;;
  containment)
    # The case a plain set intersection passes: A owns the directory, B owns a
    # file inside it. Two agents writing here race exactly as if they shared a
    # path.
    wave_a_json="$(wave_inputs "$SDD_WORKTREE/lib")"
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/x.sh")"
    ;;
  missing-key)
    wave_a_json='{"task_path":"/dev/null"}'
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/b.sh")"
    ;;
  missing-empty)
    wave_a_json='{"allowed_paths":[]}'
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/b.sh")"
    ;;
  reviewers)
    # Reviewers are read-only and deliberately share a scope; the guard must
    # discriminate on the edge id, not on the presence of allowed_paths.
    edge_under_test=sdd.task.spec_review
    wave_a_json="$(wave_inputs "$SDD_WORKTREE/lib/same.sh")"
    wave_b_json="$(wave_inputs "$SDD_WORKTREE/lib/same.sh")"
    ;;
  *)
    printf 'unknown wave-guard case: %s\n' "$guard_case" >&2
    exit 64
    ;;
esac

sdd_begin_batch || exit 65
sdd_dispatch_prepared "$edge_under_test" wave-a "$wave_a_json" '[]' || exit 66
sdd_dispatch_prepared "$edge_under_test" wave-b "$wave_b_json" '[]' || exit 67
launch_rc=0
sdd_launch_prepared_batch || launch_rc=$?
exit "$launch_rc"
SH

GUARD_RC=0
GUARD_ERR="$TMP/guard.err"
GUARD_LOG="$TMP/guard.log"
guard_fail() { printf 'sdd-routed-lifecycle: FAIL %s\n' "$*" >&2; exit 1; }
run_guard() {
  GUARD_RC=0
  "$1" "$TMP/wave-guard.sh" "$ROOT" "$GUARD_LOG" "$TMP/runtime.sh" "$2" \
    2>"$GUARD_ERR" || GUARD_RC=$?
}
guard_dispatch_lines() { wc -l <"$GUARD_LOG" | tr -d ' '; }

# L-A — the happy path. Two implementers owning disjoint files launch normally.
# bash-only: `sdd_launch_prepared_batch`'s dispatch loops read
# ${ARR[$index]} from index 0, which is empty under zsh (the fence documents
# this itself), so only the REFUSAL path is reproducible cross-shell.
run_guard bash disjoint
[ "$GUARD_RC" -eq 0 ] || guard_fail "L-A a disjoint wave was refused (rc $GUARD_RC): $(cat "$GUARD_ERR")"
[ "$(guard_dispatch_lines)" -eq 2 ] || guard_fail "L-A a disjoint wave dispatched $(guard_dispatch_lines) children, expected 2"

# L-B — the defect itself: two implementers claiming the same path. Nothing may
# be launched; "launched then complained" is not a refusal.
run_guard bash identical
[ "$GUARD_RC" -eq 3 ] || guard_fail "L-B an overlapping wave returned rc $GUARD_RC, expected 3: $(cat "$GUARD_ERR")"
[ "$(guard_dispatch_lines)" -eq 0 ] || guard_fail "L-B an overlapping wave still dispatched $(guard_dispatch_lines) children"
grep -q 'wave_paths_overlap' "$GUARD_ERR" || guard_fail "L-B refusal did not name wave_paths_overlap: $(cat "$GUARD_ERR")"
grep -q 'task_a=' "$GUARD_ERR" || guard_fail "L-B refusal did not name the first colliding task"
grep -q 'task_b=' "$GUARD_ERR" || guard_fail "L-B refusal did not name the second colliding task"

# L-C — directory containment. Set intersection reports these as disjoint.
run_guard bash containment
[ "$GUARD_RC" -eq 3 ] || guard_fail "L-C a directory-containment overlap returned rc $GUARD_RC, expected 3: $(cat "$GUARD_ERR")"
[ "$(guard_dispatch_lines)" -eq 0 ] || guard_fail "L-C a directory-containment overlap still dispatched $(guard_dispatch_lines) children"
grep -q 'wave_paths_overlap' "$GUARD_ERR" || guard_fail "L-C refusal did not name wave_paths_overlap: $(cat "$GUARD_ERR")"

# L-D — ownership absent entirely, in both spellings. rc 2 is already this
# function's "you called it wrong" code, so the TOKEN is the discriminator.
for guard_missing_case in missing-key missing-empty; do
  run_guard bash "$guard_missing_case"
  [ "$GUARD_RC" -eq 2 ] || guard_fail "L-D $guard_missing_case returned rc $GUARD_RC, expected 2: $(cat "$GUARD_ERR")"
  [ "$(guard_dispatch_lines)" -eq 0 ] || guard_fail "L-D $guard_missing_case still dispatched $(guard_dispatch_lines) children"
  grep -q 'wave_paths_missing' "$GUARD_ERR" || guard_fail "L-D $guard_missing_case did not name wave_paths_missing: $(cat "$GUARD_ERR")"
done

# L-E — the discriminator. Two spec reviewers sharing an identical read scope
# must launch: only the implement edge writes.
run_guard bash reviewers
[ "$GUARD_RC" -eq 0 ] || guard_fail "L-E a reviewer batch with a shared scope was refused (rc $GUARD_RC): $(cat "$GUARD_ERR")"
[ "$(guard_dispatch_lines)" -eq 2 ] || guard_fail "L-E a reviewer batch dispatched $(guard_dispatch_lines) children, expected 2"

# L-G — the refusal is reproducible cross-shell. Asserting rc 3 specifically is
# what makes this falsifiable: without the guard, zsh falls through to the
# bash-0-indexed dispatch loop and exits with a different rc and no token.
if command -v zsh >/dev/null 2>&1; then
  run_guard zsh identical
  [ "$GUARD_RC" -eq 3 ] || guard_fail "L-G zsh returned rc $GUARD_RC on an overlapping wave, expected 3: $(cat "$GUARD_ERR")"
  [ "$(guard_dispatch_lines)" -eq 0 ] || guard_fail "L-G zsh still dispatched $(guard_dispatch_lines) children on an overlapping wave"
  grep -q 'wave_paths_overlap' "$GUARD_ERR" || guard_fail "L-G zsh refusal did not name wave_paths_overlap: $(cat "$GUARD_ERR")"
else
  echo 'sdd-routed-lifecycle: SKIP: zsh not on PATH — the cross-shell refusal claim is unproven' >&2
fi

# L-F — regression. The pre-existing two-batch and wait-failure fixtures are
# byte-unchanged: a non-implement edge must not populate the accumulator, and
# the guard must not perturb the receipt/unwind lifecycle.
bash "$TMP/two-batches.sh" "$ROOT" "$TMP/dispatch.log" "$TMP/runtime.sh"
bash "$TMP/wait-failure.sh" "$ROOT" "$TMP/wait.log" "$TMP/unwind.log" "$TMP/runtime.sh"

echo 'sdd-routed-lifecycle: PASS'
