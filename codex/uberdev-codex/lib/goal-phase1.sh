#!/usr/bin/env bash
# lib/goal-phase1.sh — /uberdev:goal Phase 1 (CLAIM ONLY), RFC 0015 §5.
#
# WHAT THIS DOES, AND — MORE IMPORTANTLY — WHAT IT NO LONGER DOES.
# Pre-RFC-0015 this logic lived in a SKILL.md fence and ended with a
# `uberdev_dispatch_one` call per issue: one DETACHED `claude --bg` session per
# issue, running `/uberdev:orchestrator --turbo`. That is the last thing that
# kept the detached default transport on a default path. Both are gone.
#
# This script now does the *claim* half only:
#   - provision the `uberdev:active` label,
#   - acquire the cross-process claim per issue (real SETNX, issue #291),
#   - apply the per-cycle MAX_PARALLEL cap and roll the overflow into the next
#     cycle's queue (#211),
#   - write the `input -> dispatched` pre-arm state row (#236),
#   - print ONE compact JSON line describing the cycle.
#
# The SOLVING half is skills/goal-pipeline/workflow.js's job: it takes the
# `dispatch` list from this script's JSON, has its relay run
# lib/solve-launcher.sh --backend=workflow over exactly that set, and then makes
# ONE nested workflow() call into skills/solve-fleet/workflow.js for the whole
# cycle. There is no per-issue nested workflow and there must never be one: the
# runtime allows a single nesting level, and solve-fleet spends it on its own
# per-issue agents.
#
# CONTRACT
#   bash lib/goal-phase1.sh [--goal-id=<id>]
#       claim pass. exit 0 = JSON line printed; exit 1 = hard error (a claim
#       could not be taken because gh failed, or a state write failed).
#   bash lib/goal-phase1.sh --mark-solving=<csv> [--goal-id=<id>]
#       `dispatched -> solving` for the issues the fleet has just been armed
#       with. Run by the same relay, immediately after solve-launcher.sh
#       succeeds.
#   bash lib/goal-phase1.sh --mark-failed=<csv> [--goal-id=<id>]
#       `dispatched -> failed` + claim release, when arming the fleet failed.
#       Without this a stranded `dispatched` row would make the skip-check
#       above silently skip the issue for the whole goal lifetime.
#
# The two-step `dispatched` -> `solving` split is issue #236's guard, retargeted
# at the window that actually exists now: between the claim and the fleet being
# armed. A crash there still leaves a `dispatched` row that the next cycle's
# skip-check matches, so the issue is never silently re-claimed and double-solved.

set -u

# Plugin-root resolution. `CLAUDE_PLUGIN_ROOT` is always set under the Claude
# plugin, but the byte-identical Codex mirror of this file runs with
# `PLUGIN_ROOT` instead — and under `set -u` a bare ${CLAUDE_PLUGIN_ROOT} there
# is a FATAL unbound-variable abort, not a graceful missing-file skip. Resolve
# once, using the same fallback chain lib/dispatch.sh uses.
UBERDEV_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"

GOAL_ID_CLI=""
MARK_SOLVING=""
MARK_FAILED=""
for _arg in "$@"; do
  case "$_arg" in
    --goal-id=*)      GOAL_ID_CLI="${_arg#--goal-id=}" ;;
    --mark-solving=*) MARK_SOLVING="${_arg#--mark-solving=}" ;;
    --mark-failed=*)  MARK_FAILED="${_arg#--mark-failed=}" ;;
    *) echo "goal-phase1: unknown argument '$_arg'" >&2; exit 2 ;;
  esac
done

# >>> region: rehydrate
# Fresh-process rehydration — source the libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh"
[ -n "$GOAL_ID_CLI" ] && export UBERDEV_GOAL_ID="$GOAL_ID_CLI"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 1" >&2; exit 3; }
uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || exit 1   # re-derive backend/env (idempotent, D8); not persisted
# <<< region: rehydrate

UBERDEV_ACTIVE_LABEL='uberdev:active'
UBERDEV_ACTIVE_LABEL_COLOR='D93F0B'
UBERDEV_ACTIVE_LABEL_DESCRIPTION='Issue currently being worked on by a /solve or /turbo dispatcher. Auto-managed; do not edit.'

_uberdev_goal_release_claim() {
  # Best-effort release on a terminal non-merge transition. Combined
  # remove-label + remove-assignee (gh fails atomically); fail-soft because the
  # issue may already be closed / the label hand-removed (mirrors merge Step 3.4).
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 0
  gh issue edit "$issue" --remove-label "$UBERDEV_ACTIVE_LABEL" --remove-assignee "@me" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Mode: --mark-solving / --mark-failed (post-arm state reconciliation).
# ---------------------------------------------------------------------------
if [ -n "$MARK_SOLVING" ] || [ -n "$MARK_FAILED" ]; then
  _mark_rc=0
  _old_ifs="$IFS"; IFS=','
  for _issue in $MARK_SOLVING; do
    IFS="$_old_ifs"
    [ -n "$_issue" ] || continue
    _uberdev_goal_validate_int "$_issue" || { echo "goal: --mark-solving got a non-numeric issue '$_issue'" >&2; exit 2; }
    if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$_issue" dispatched solving; then
      printf 'goal: post-arm state write failed for issue %s (fleet armed, TSV-memory divergence)\n' "$_issue" >&2
      _mark_rc=1
    fi
    IFS=','
  done
  IFS="$_old_ifs"
  _old_ifs="$IFS"; IFS=','
  for _issue in $MARK_FAILED; do
    IFS="$_old_ifs"
    [ -n "$_issue" ] || continue
    _uberdev_goal_validate_int "$_issue" || { echo "goal: --mark-failed got a non-numeric issue '$_issue'" >&2; exit 2; }
    # The `dispatched` row must not survive as a zombie the skip-check would
    # match forever; and the cross-process claim must be released so a later
    # cycle (or a manual /solve) can pick the issue up.
    if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$_issue" dispatched failed; then
      printf 'goal: WARN cleanup transition dispatched->failed FAILED for issue %s (TSV-state corruption — manual recovery may be needed)\n' "$_issue" >&2
    fi
    _uberdev_goal_release_claim "$_issue"
    IFS=','
  done
  IFS="$_old_ifs"
  uberdev_goal_write_run_state || { echo "goal: failed to persist run-state after mark pass" >&2; exit 3; }
  printf '{"phase":"mark","goal_id":"%s","solving":"%s","failed":"%s","rc":%s}\n' \
    "$GOAL_ID" "$MARK_SOLVING" "$MARK_FAILED" "$_mark_rc"
  exit "$_mark_rc"
fi

# >>> region: cycle-ceiling
# Issue #288 #2 (CRITICAL) — cycle-ceiling backstop at the TOP of Phase 1.
# `cycle` is incremented + checked against MAX_CYCLES only inside
# lib/goal-phase3.sh, so the ceiling held ONLY if the driver re-ran Phase 3
# between cycles. A mis-sequenced re-entry that lands back on Phase 1 with an
# over-incremented `cycle` would otherwise run unbounded. Re-evaluate the
# ceiling here, reading the freshly-rehydrated `cycle` from run-state, so it
# holds regardless of which phase is re-entered. Strict `>`: entering Phase 1
# with cycle==MAX_CYCLES is the LEGITIMATE final cycle; cycle>MAX_CYCLES is a
# genuine over-run with no path to a valid Phase-3 gate, so halt here.
if [ "${cycle:-1}" -gt "${MAX_CYCLES:-0}" ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"max_cycles\",\"cycle\":$cycle,\"max\":$MAX_CYCLES,\"phase\":\"phase1_ceiling_backstop\"}"
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi
# <<< region: cycle-ceiling

# >>> region: claim
# Issue #291 #1 (CRITICAL) — cross-process issue claim (real SETNX), mirroring
# the canonical `uberdev:active` protocol in lib/solve-launcher.sh Step 4.5.
# /goal claims BEFORE it arms the solve-fleet, so two concurrent /goal runs (or
# /goal + a manual /solve) can never both work the same issue and produce
# duplicate PRs + duplicate version bumps. The label is a GitHub-side
# cross-process lock; the TSV is only in-process.
# `_uberdev_goal_claim_issue` is the label-absent-guarded add (read labels → if
# absent, --add-label): rc 0 = claim acquired (or already ours), rc 2 =
# collision (claimed by another process — soft-skip this cycle), rc 1 =
# gh/permission failure (hard error).
# `_uberdev_goal_release_claim` clears the label+assignee on a terminal NON-merge
# transition (failed / resolved-by-no-action). The merge path is released by
# merge-pipeline Step 3.4's post-merge cleanup (symmetric with /solve+/turbo).
#
# Provision the label once per run (idempotent --force; gh cannot auto-create a
# label from --add-label and fails that mutation atomically). Fail-soft: a
# provisioning failure is surfaced but the per-issue --add-label below is the
# load-bearing fail-loud gate.
gh label create --force "$UBERDEV_ACTIVE_LABEL" \
  --color "$UBERDEV_ACTIVE_LABEL_COLOR" \
  --description "$UBERDEV_ACTIVE_LABEL_DESCRIPTION" >/dev/null 2>&1 \
  || printf 'goal: WARN could not provision %s label (claim --add-label may fail) — check gh auth/scope\n' "$UBERDEV_ACTIVE_LABEL" >&2

_uberdev_goal_claim_issue() {
  # SETNX: rc 0 acquired/already-ours, rc 2 collision (held by another process),
  # rc 1 gh failure. Single read of labels (--json labels), then a guarded add.
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 1
  local labels_json present
  labels_json="$(gh issue view "$issue" --json labels --jq '[.labels[].name]' 2>/dev/null)" || return 1
  present="$(printf '%s' "$labels_json" | jq -r --arg l "$UBERDEV_ACTIVE_LABEL" 'index($l) // empty' 2>/dev/null)"
  if [ -n "$present" ]; then
    return 2   # already claimed by another process (or a prior, not-yet-released run)
  fi
  # Absent → acquire. --add-label + --add-assignee in one round-trip (gh fails
  # atomically on partial error), matching solve-launcher Step 4.5.
  gh issue edit "$issue" --add-label "$UBERDEV_ACTIVE_LABEL" --add-assignee "@me" >/dev/null 2>&1 || return 1
  return 0
}
# <<< region: claim

# >>> region: claim-loop
active_issues=()
# #211 — per-cycle parallel dispatch cap. Issues beyond MAX_PARALLEL roll over
# into remaining_queue, which becomes the next cycle's queue (flushed via
# uberdev_goal_write_run_state at the end of this script).
dispatched_this_cycle=0
remaining_queue=()
skipped_issues=()
# `${arr[@]+"${arr[@]}"}` rather than a bare `"${arr[@]}"`: bash 4.3 and older
# raise an unbound-variable error for the latter on an EMPTY array under
# `set -u`, and an empty queue is normal on a late cycle where every remaining
# issue is already in flight.
for ISSUE_NUM in ${queue[@]+"${queue[@]}"}; do
  current_state="$(uberdev_goal_get_issue_state "$GOAL_ID" "$ISSUE_NUM" 2>/dev/null)"
  # Issue #236 — `dispatched` is the pre-arm guard state written below. Adding
  # it to the skip-check closes the crash-before-solving double-claim surface:
  # a run that dies between the claim and the fleet being armed still leaves a
  # `dispatched` row, so the next cycle's skip-check matches and never silently
  # re-claims.
  case "$current_state" in
    dispatched|solving|pr-pushed) continue ;;
  esac

  # #211 — once the per-cycle cap is hit, defer every remaining eligible issue
  # to the next cycle by appending to remaining_queue. This MUST come AFTER the
  # already-dispatched skip-check above so re-entered/in-flight issues don't get
  # spuriously rolled over.
  if [ "$dispatched_this_cycle" -ge "$MAX_PARALLEL" ]; then
    remaining_queue+=("$ISSUE_NUM")
    continue
  fi

  # T5 provenance — the solve-fleet children (and their downstream /merge
  # dispatch via finish-branch -> /review-pr, if any) MUST inherit
  # UBERDEV_GOAL_ID so uberdev_goal_should_automerge can verify the merge is
  # coming from inside this /goal run. Without this env forwarding, the per-PR
  # attempt-counter cap would not gate a stray merge attempt and the
  # runaway-loop containment (R5) would silently fail open.
  export UBERDEV_GOAL_ID="$GOAL_ID"

  # Issue #291 #1 — acquire the cross-process `uberdev:active` claim BEFORE the
  # pre-arm TSV write. This is the outermost guard: a collision skips the issue
  # THIS cycle WITHOUT writing `dispatched` (so a later cycle can retry once the
  # other process releases). rc 2 = collision (soft-skip, mirrors D12); rc 1 =
  # gh/permission failure (hard error — the claim is the cross-process lock the
  # whole dedup rests on, so a silent failure would re-open the double-solve
  # surface the way the dead D12 path did).
  _uberdev_goal_claim_issue "$ISSUE_NUM"; _claim_rc=$?
  if [ "$_claim_rc" = "2" ]; then
    printf 'goal: issue %s skipped this cycle (uberdev:active claim held by another process)\n' "$ISSUE_NUM" >&2
    skipped_issues+=("$ISSUE_NUM")
    continue
  elif [ "$_claim_rc" != "0" ]; then
    printf 'goal: failed to acquire uberdev:active claim for issue %s (gh rc=%s) — check gh auth/scope\n' "$ISSUE_NUM" "$_claim_rc" >&2
    print_summary "$cycle"
    exit 1
  fi

  # Issue #236 — pre-arm state write. input -> dispatched MUST precede the
  # fleet being armed so any crash in that window cannot leave the TSV in
  # `input` state and trigger a silent re-claim on cycle N+1. A
  # transition-validator failure here is a hard error: the TSV is the SSOT for
  # in-flight tracking. On failure also RELEASE the claim acquired just above so
  # a TSV-write error does not strand the cross-process lock (which would block
  # every future cycle + manual /solve).
  if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$ISSUE_NUM" input dispatched; then
    printf 'goal: pre-arm state write failed for issue %s\n' "$ISSUE_NUM" >&2
    _uberdev_goal_release_claim "$ISSUE_NUM"
    print_summary "$cycle"
    exit 1
  fi

  active_issues+=("$ISSUE_NUM")
  dispatched_this_cycle=$(( dispatched_this_cycle + 1 ))
  # #211 — Note: batch-PR registration is deferred to lib/goal-watch.sh step 2a
  # once the PR number resolves. uberdev_goal_register_batch_pr requires a valid
  # integer PR number and the PR doesn't exist yet at claim-time.
done

# #211 — flush the rollover queue back into `queue` so the next cycle picks up
# the issues that exceeded MAX_PARALLEL. Empty remaining_queue is the happy path
# (queue fully drained this cycle); a non-empty rollover is the cap-saturation
# case and is the SSOT for "more issues to dispatch next cycle".
queue=(${remaining_queue[@]+"${remaining_queue[@]}"})

# #171 — flush the populated active_issues (+ rehydrated queue/scalars) so
# lib/goal-watch.sh (a fresh process) rehydrates the dispatched set. Without
# this, active_issues evaporates with this process and the watch loop polls
# nothing, emitting a false goal_converged on cycle 1.
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state after claim pass" >&2; exit 3; }
# <<< region: claim-loop

# ONE compact JSON line — the machine-readable contract the workflow driver's
# relay returns verbatim. `dispatch` is the set the solve-fleet must be armed
# with; `rollover` is what waits for the next cycle; `skipped` lost a claim race.
_json_csv() { local IFS=','; printf '%s' "$*"; }
printf '{"phase":"claim","goal_id":"%s","cycle":%s,"dispatch":"%s","rollover":"%s","skipped":"%s","claimed":%s,"rc":0}\n' \
  "$GOAL_ID" "${cycle:-1}" \
  "$(_json_csv "${active_issues[@]:-}")" \
  "$(_json_csv "${remaining_queue[@]:-}")" \
  "$(_json_csv "${skipped_issues[@]:-}")" \
  "${#active_issues[@]}"
exit 0
