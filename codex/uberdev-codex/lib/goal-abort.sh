#!/usr/bin/env bash
# plugins/uberdev/lib/goal-abort.sh
#
# Release the cross-process claims a /goal run is holding, then reap its
# run-state sidecars. EXECUTED (shebang), never sourced.
#
# WHY THIS EXISTS.
# /goal takes a real cross-process lock on every issue it dispatches: the
# `uberdev:active` GitHub label plus a self-assignment (goal-pipeline Phase 1,
# `_uberdev_goal_claim_issue`). The label is released on exactly two paths — a
# terminal non-merge transition inside the run, and merge-pipeline Step 3.4's
# post-merge cleanup. Neither of those runs when the RUN ITSELF disappears:
#
#   - RFC 0015 retired detached `claude --bg` as the default transport. A
#     Workflow-native fleet is owned by the calling session, so closing the
#     window, `/clear`, or a compact kills every in-flight solver mid-cycle.
#   - Even on a detached backend, an operator Ctrl-C between Phase 1's claim
#     and any terminal transition leaves the same residue.
#
# A stranded `uberdev:active` label is not cosmetic: it is the SETNX every
# future /goal cycle AND every manual /solve honours, so the affected issues
# become permanently un-dispatchable and the failure looks like "/solve silently
# skips my issue" with nothing on any stream explaining it (RFC 0015 §6 lists
# the owed sweep; project memory project_uberdev_label_desc_100char_limit
# records the last time this label broke claim/dispatch).
#
# CONTRACT.
#   usage: bash lib/goal-abort.sh [GOAL_ID] [--dry-run]
#     GOAL_ID  optional; otherwise $UBERDEV_GOAL_ID, otherwise the fixed-path
#              pointer $UBERDEV_TMPDIR/goal-active-id.txt written by
#              uberdev_goal_write_run_state.
#     --dry-run  print what WOULD be released and exit 0 without mutating
#                GitHub or removing any sidecar.
#   exit 0  every non-terminal claim released (or nothing to do / dry-run)
#   exit 1  at least one release failed, OR the issue-state ledger could not be
#           read/parsed (an unread ledger is NEVER reported as "nothing to
#           release") — the run-state is DELIBERATELY left in place so a re-run
#           can retry; the stranded issues are named on stderr
#   exit 2  usage error, or no resolvable goal run
#
# No audit rows are emitted. GOAL_AUDIT_EVENT_ENUM is a CLOSED set (RFC 0005
# D5 — new members require an RFC amendment) and none of its twelve members
# means "claims released by an out-of-band abort". Inventing a member here, or
# stretching goal_reaper_skipped to cover it, would corrupt the replay semantics
# every audit consumer depends on. The summary goes to stdout instead.

set -u

UBERDEV_GOAL_ABORT_DRY_RUN=0
UBERDEV_GOAL_ABORT_ID=""

for _tok in "$@"; do
  case "$_tok" in
    --dry-run) UBERDEV_GOAL_ABORT_DRY_RUN=1 ;;
    -h|--help)
      printf 'usage: goal-abort.sh [GOAL_ID] [--dry-run]\n'
      exit 0 ;;
    --*)
      printf 'goal-abort: unknown flag: %s\n' "$_tok" >&2
      exit 2 ;;
    *)
      if [ -n "$UBERDEV_GOAL_ABORT_ID" ]; then
        printf 'goal-abort: more than one GOAL_ID given (%s, %s)\n' "$UBERDEV_GOAL_ABORT_ID" "$_tok" >&2
        exit 2
      fi
      UBERDEV_GOAL_ABORT_ID="$_tok" ;;
  esac
done

_UBERDEV_GOAL_ABORT_LIB_DIR=""
case "${BASH_SOURCE[0]:-$0}" in
  */*) _UBERDEV_GOAL_ABORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" ;;
esac
if [ -z "$_UBERDEV_GOAL_ABORT_LIB_DIR" ] || [ ! -r "$_UBERDEV_GOAL_ABORT_LIB_DIR/goal-state.sh" ]; then
  printf 'goal-abort: cannot locate lib/goal-state.sh next to this script\n' >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_UBERDEV_GOAL_ABORT_LIB_DIR/goal-state.sh"

UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
export UBERDEV_TMPDIR

# Resolution order mirrors uberdev_goal_read_run_state's bootstrap: explicit
# argument, then the exported env var, then the fixed-path pointer. The pointer
# is the ONLY channel that survives a killed session, which is precisely the
# case this script exists for.
if [ -z "$UBERDEV_GOAL_ABORT_ID" ]; then
  UBERDEV_GOAL_ABORT_ID="${UBERDEV_GOAL_ID:-}"
fi
if [ -z "$UBERDEV_GOAL_ABORT_ID" ] && [ -r "$UBERDEV_TMPDIR/goal-active-id.txt" ]; then
  UBERDEV_GOAL_ABORT_ID="$(head -n1 "$UBERDEV_TMPDIR/goal-active-id.txt" 2>/dev/null)"
fi
if [ -z "$UBERDEV_GOAL_ABORT_ID" ]; then
  printf 'goal-abort: no goal run to abort (no GOAL_ID argument, no UBERDEV_GOAL_ID, no %s)\n' \
    "$UBERDEV_TMPDIR/goal-active-id.txt" >&2
  exit 2
fi
# The id indexes filesystem paths; validate before it ever reaches one (#156).
if ! _uberdev_goal_validate_id "$UBERDEV_GOAL_ABORT_ID"; then
  printf 'goal-abort: refusing unsafe GOAL_ID: %s\n' "$UBERDEV_GOAL_ABORT_ID" >&2
  exit 2
fi

GOAL_ID="$UBERDEV_GOAL_ABORT_ID"
export UBERDEV_GOAL_ID="$GOAL_ID"

ISSUE_TSV="$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv"
if [ ! -f "$ISSUE_TSV" ]; then
  printf 'goal-abort: no issue-state ledger for goal %s (%s) — nothing claimed, nothing to release\n' \
    "$GOAL_ID" "$ISSUE_TSV" >&2
  [ "$UBERDEV_GOAL_ABORT_DRY_RUN" = "1" ] || uberdev_goal_cleanup_run_state || true
  exit 0
fi

# Terminal issue states never hold a claim: `resolved` released it through the
# merge path, `resolved-by-no-action` and `failed` released it at their terminal
# transition. Everything else (input / dispatched / solving / pr-pushed) either
# holds the label right now or cannot be distinguished from holding it, and the
# release is idempotent + fail-soft, so releasing the superset is correct.
#
# awk reads the LAST row per issue: the ledger is append-only, so an issue that
# went solving -> failed must be judged on `failed`, not on `solving`.
#
# The awk rc is CHECKED, and an unreadable/unparseable ledger is fail-LOUD.
# `PENDING=""` from a crashed awk is byte-identical to `PENDING=""` from "every
# issue is terminal", and this script has no `pipefail`, so an unchecked
# pipeline would report `released=0 … run-state cleaned`, exit 0, release
# NOTHING and then DELETE the run-state + the fixed-path pointer — destroying
# the only channel a retry could resolve the run through, and stranding every
# `uberdev:active` claim permanently. That is the exact failure this script
# exists to prevent, so it takes the same exit-1/keep-run-state contract as a
# refused release.
_ledger_rc=0
PENDING_ROWS="$(awk -F'\t' '
  { last[$1] = $2 }
  END {
    for (issue in last) {
      s = last[issue]
      if (s != "resolved" && s != "resolved-by-no-action" && s != "failed") print issue "\t" s
    }
  }
' "$ISSUE_TSV")" || _ledger_rc=$?
if [ "$_ledger_rc" -ne 0 ]; then
  printf 'goal-abort: FAILED to read the issue-state ledger %s (awk rc=%s) — refusing to report "nothing to release" on an unread ledger; run-state KEPT so this can be retried\n' \
    "$ISSUE_TSV" "$_ledger_rc" >&2
  exit 1
fi
_sort_rc=0
PENDING="$(sort -n <<<"$PENDING_ROWS")" || _sort_rc=$?
if [ "$_sort_rc" -ne 0 ]; then
  printf 'goal-abort: FAILED to order the pending-claim rows (sort rc=%s) — same fail-loud contract as an unreadable ledger; run-state KEPT so this can be retried\n' \
    "$_sort_rc" >&2
  exit 1
fi

RELEASED=0
FAILED=0
SKIPPED=0
FAILED_ISSUES=""

if [ -n "$PENDING" ]; then
  while IFS=$'\t' read -r _issue _state; do
    [ -n "$_issue" ] || continue
    if ! _uberdev_goal_validate_int "$_issue"; then
      printf 'goal-abort: skipping non-numeric issue key in ledger: %s\n' "$_issue" >&2
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if [ "$UBERDEV_GOAL_ABORT_DRY_RUN" = "1" ]; then
      printf '  would release uberdev:active on issue #%s (state=%s)\n' "$_issue" "$_state"
      RELEASED=$((RELEASED + 1))
      continue
    fi
    # Combined remove-label + remove-assignee in one round-trip; gh fails the
    # mutation atomically, so a non-zero rc means NEITHER was removed and the
    # claim is genuinely still held. That is why this is fail-LOUD (unlike the
    # in-run best-effort releases): the whole point of this script is that
    # nothing else will ever come back to release it.
    _err="$(gh issue edit "$_issue" --remove-label "uberdev:active" --remove-assignee "@me" 2>&1 >/dev/null)"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      printf '  released uberdev:active on issue #%s (state=%s)\n' "$_issue" "$_state"
      RELEASED=$((RELEASED + 1))
    else
      printf 'goal-abort: FAILED to release uberdev:active on issue #%s (rc=%s): %s\n' "$_issue" "$_rc" "$_err" >&2
      FAILED=$((FAILED + 1))
      FAILED_ISSUES="$FAILED_ISSUES #$_issue"
    fi
  done <<EOF
$PENDING
EOF
fi

if [ "$UBERDEV_GOAL_ABORT_DRY_RUN" = "1" ]; then
  printf 'goal-abort: DRY RUN goal=%s would_release=%d skipped=%d (no GitHub mutation, run-state kept)\n' \
    "$GOAL_ID" "$RELEASED" "$SKIPPED"
  exit 0
fi

if [ "$FAILED" -gt 0 ]; then
  printf 'goal-abort: goal=%s released=%d FAILED=%d skipped=%d — run-state KEPT so this can be retried\n' \
    "$GOAL_ID" "$RELEASED" "$FAILED" "$SKIPPED"
  printf 'goal-abort: still claimed:%s — release by hand with `gh issue edit N --remove-label uberdev:active`\n' \
    "$FAILED_ISSUES" >&2
  exit 1
fi

uberdev_goal_cleanup_run_state || true
printf 'goal-abort: goal=%s released=%d skipped=%d run-state cleaned\n' "$GOAL_ID" "$RELEASED" "$SKIPPED"
exit 0
