#!/usr/bin/env bash
# lib/goal-watch.sh — /uberdev:goal Phase 2 (watch + merge lane), RFC 0015 §5.
#
# THE SHAPE OF THIS FILE IS THE POINT. It is one long polling loop that must run
# as ONE process: the EXIT/INT/TERM traps, the per-fence tick counters, the
# `made_transition` fast path and the `while true` itself are all per-SHELL
# state. While this lived in a SKILL.md ```bash fence, every re-invocation was a
# NEW shell — so a trap registered "for the run" died at the fence boundary and
# a counter "accumulated across passes" reset to zero. Moving it into a script
# is what makes those guards real rather than decorative.
#
# EXIT CONTRACT (documented, byte-stable, and consumed by
# skills/goal-pipeline/workflow.js):
#   0  — the watch loop DRAINED this cycle (step 2f: no active agents AND no
#        merging PRs) -> proceed to lib/goal-phase3.sh.
#   42 — the bound (pass count or wall-clock budget) was reached while work is
#        still in flight -> re-invoke this script to continue polling. The
#        solver agents are LEFT ALIVE: the reaper does NOT fire on a bounded
#        pause. A harness SIGTERM takes the SAME exit-42 contract (#301) — the
#        TERM trap persists run-state, emits a `goal_reaper_skipped` audit row
#        (reason=harness_term), and exits 42 WITHOUT reaping.
#   1  — a circuit breaker fired (the reaper DOES fire here), OR a fail-loud
#        run-state-flush failure at a bounded exit boundary (bg agents PRESERVED
#        on that path — distinct from a breaker exit 1, which reaps first).
#
# Operator abort is INT (Ctrl-C), which still reaps and exits 130.
#
# CONTRACT
#   bash lib/goal-watch.sh [--goal-id=<id>]
#
# Run it under bash >= 4: the verdict locator
# (uberdev_goal_locate_review_pr_audit_by_pr, lib/goal-state.sh) iterates
# unquoted globs that rely on bash's "unmatched glob -> literal" semantics; zsh
# fatals with `no matches found`. lib/goal-phase0.sh publishes a usable
# interpreter as $UBERDEV_GOAL_BASH for exactly this call.

set -u

# Plugin-root resolution. Keep the whole chain: it is `set -u` safety plus
# parity with lib/dispatch.sh's own resolution order, and BOTH still apply.
# Under `set -u` a bare ${CLAUDE_PLUGIN_ROOT} is a FATAL unbound-variable abort,
# not a graceful missing-file skip, and CLAUDE_PLUGIN_ROOT is unset whenever
# this file is sourced outside a plugin session (a direct `bash lib/goal-*.sh`,
# and every fixture that does the same). Do NOT "simplify" this to the single
# CLAUDE_PLUGIN_ROOT read. (#381 note: the reason this comment used to give —
# a byte-identical Codex mirror running with `PLUGIN_ROOT` — is void, that tree
# is deleted. The chain is not: it was always load-bearing for the above.)
UBERDEV_PLUGIN_ROOT="${UBERDEV_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"

GOAL_ID_CLI=""
for _arg in "$@"; do
  case "$_arg" in
    --goal-id=*) GOAL_ID_CLI="${_arg#--goal-id=}" ;;
    *) echo "goal-watch: unknown argument '$_arg'" >&2; exit 2 ;;
  esac
done
[ -n "$GOAL_ID_CLI" ] && export UBERDEV_GOAL_ID="$GOAL_ID_CLI"

# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 2" >&2; exit 3; }
uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || exit 1   # re-derive backend/env (idempotent, D8); not persisted

# ---------------------------------------------------------------------------
# CHILD TRANSPORT (RFC 0015 §5). The SOLVERS are Workflow agents, spawned by the
# session's Workflow tool from skills/goal-pipeline/workflow.js. The two
# children THIS script dispatches — `/merge` (step 2c) and `/review-pr` (step
# 2b) — are not: they are spawned by a shell polling loop, and the `workflow`
# backend has no provider arm by construction (lib/dispatch.sh refuses it
# loudly, which is correct — this library cannot call the Workflow tool).
#
# So a `workflow` run resolves a SEPARATE, EXPLICIT transport for those two
# children. This is deliberately NOT the retired
# `uberdev_dispatch_demote_workflow_to_detached` shim: that one re-resolved the
# WHOLE RUN back onto the per-OS matrix (so `auto` reached the since-removed
# detached default on the default path). This picks `background` — a
# first-class, file-polled transport that is exactly the right shape for a
# short-lived command a poller supervises — for these two dispatches only, and
# says so out loud. Override with UBERDEV_GOAL_CHILD_BACKEND.
#
# THE PIN IS PROCESS-GLOBAL, SO THE SOLVER BACKEND IS SAVED FIRST.
# `uberdev_dispatch_preflight` EXPORTs UBERDEV_RESOLVED_BACKEND for the whole
# process, and that variable is ALSO what the backend-aware solver-liveness
# probe (`uberdev_goal_agent_busy_for_issue`, lib/goal-state.sh) branches on.
# Left unsaved, the pin silently re-routes that probe down the `background`
# PID-file arm for solvers that are Workflow agents and never write a PID file
# — so a live fleet reads as dead, or a recycled PID reads as a live solver and
# holds the cycle open to its tick ceiling. UBERDEV_GOAL_SOLVER_BACKEND keeps
# the run-level answer, and `_uberdev_goal_watch_solver_busy` below is the only
# way this script asks the solver-liveness question.
UBERDEV_GOAL_SOLVER_BACKEND="${UBERDEV_GOAL_SOLVER_BACKEND:-${UBERDEV_RESOLVED_BACKEND:-}}"
export UBERDEV_GOAL_SOLVER_BACKEND
if [ "${UBERDEV_RESOLVED_BACKEND:-}" = "workflow" ]; then
  UBERDEV_DISPATCH_BACKEND_REQUESTED="${UBERDEV_GOAL_CHILD_BACKEND:-background}"
  export UBERDEV_DISPATCH_BACKEND_REQUESTED
  echo "goal: /merge + /review-pr children run on --backend=$UBERDEV_DISPATCH_BACKEND_REQUESTED (the watch loop dispatches them, not the session's Workflow tool); the solvers stay Workflow-native" >&2
  uberdev_dispatch_preflight || exit 1
  uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || exit 1
fi

# Solver liveness under the SOLVER's transport. Save/restore rather than an
# assignment-prefixed call: a prefixed assignment on a FUNCTION invocation
# persists after the call in POSIX mode, so the "temporary" override would leak
# the solver backend into the /merge + /review-pr dispatches — the exact
# mirror-image of the bug this closes.
_uberdev_goal_watch_solver_busy() {
  local _saved="${UBERDEV_RESOLVED_BACKEND:-}" _rc
  UBERDEV_RESOLVED_BACKEND="${UBERDEV_GOAL_SOLVER_BACKEND:-$_saved}"
  uberdev_goal_agent_busy_for_issue "$1"
  _rc=$?
  UBERDEV_RESOLVED_BACKEND="$_saved"
  return "$_rc"
}

# watch_start is set in Phase 0 (step 7) — goal-level wall-clock anchor.
# The 4h stuck-loop check below measures total goal wall-clock, not per-cycle.
# #301 — this EXIT trap covers THIS FENCE ONLY, and the reasoning that used to
# be written here was wrong in a way worth recording. It said: "bash supports ONE
# EXIT trap per shell, so register the combined cleanup for $gh_err AND
# $findings_err here (Phase 3 mktemps $findings_err later)". The one-handler rule
# is real, but it is a per-SHELL rule and every phase fence is a SEPARATE shell
# (project memory project_uberdev_pipeline_directive_emitter). A trap registered
# here therefore cannot possibly remove a file Phase 3 has not created yet — it
# dies at this fence's boundary — so Phase 3 leaked one tempfile per cycle while
# this line looked like it was cleaning up. `$findings_err` is initialised empty
# below so this fence's `rm -f ""` is a harmless no-op; Phase 3 now registers its
# OWN trap for the file it actually creates.
gh_err="$(mktemp)"
findings_err=""
trap 'rm -f "$gh_err" "$findings_err"' EXIT
# Issue #220 — INT/TERM are SEPARATE signal slots from EXIT. The existing EXIT
# trap above is NOT overwritten; bash supports one handler per signal slot.
# EXIT keeps tempfile cleanup running on every other exit path. NEVER chain the
# reaper into EXIT — that would force the reaper on graceful convergence (slow,
# wasteful).
#
# #301 (RFC 0012 §3.3 goal-R1 item 3) — TERM is NOT an operator abort. Under
# the Claude-Code Bash tool the 600s call cap delivers SIGTERM to a
# still-running fence; the pre-#301 TERM trap chained into
# _uberdev_goal_reap_zombies, so the HARNESS CAP (not a human) killed every
# live solver ~10 minutes into a healthy run. TERM cannot distinguish an
# operator `kill -TERM` from the harness cap, so TERM now uniformly takes the
# harness interpretation via _uberdev_goal_handle_harness_term (lib/
# goal-state.sh): persist run-state + emit a goal_reaper_skipped audit row
# (reason=harness_term, keeping the no-reap choice visible post-mortem) +
# exit 42 (the bounded-tick "still-active, re-invoke" contract) — NO reap.
# Operator stop = INT (Ctrl-C, still reaps below) or an explicit
# _uberdev_goal_reap_zombies invocation.
trap '_uberdev_goal_reap_zombies; exit 130' INT
trap '_uberdev_goal_handle_harness_term' TERM

# #299 finding 2 — bounded watch mode. WATCH_PASSES / WATCH_BUDGET are
# rehydrated by uberdev_goal_read_run_state above (default 0 = UNBOUNDED, the
# legacy `while true … sleep` loop). When EITHER is positive, this fence runs a
# BOUNDED number of poll passes (or until a per-fence wall-clock budget) and
# then exits 42 ("still-active, re-invoke") so an orchestrating harness can drive
# the loop tick-by-tick within its own call cap (e.g. the 600s Bash-tool cap).
# Exit 0 = drained -> proceed to Phase 3. Exit 1 = halt: a circuit breaker (reaps
# first) OR a fail-loud run-state-flush failure at a bounded exit boundary (#300
# Fix B — bg solver agents PRESERVED, no reap, distinct from a breaker exit 1).
# _tick_start is the PER-FENCE wall-clock anchor (fresh every invocation — NOT
# persisted, distinct from the goal-level watch_start that drives the 4h cap);
# _tick_passes counts poll passes completed in THIS fence invocation.
_tick_start="$(date +%s)"
_tick_passes=0
_watch_bounded=0
# #301 — consecutive sleep-skipping passes in THIS fence (see the fast-path gate
# at the bottom of the loop). Per-fence like _tick_passes, not persisted: the
# burst bound only needs to hold within one continuous run of passes.
_fast_passes=0
if [ "${WATCH_PASSES:-0}" -gt 0 ] || [ "${WATCH_BUDGET:-0}" -gt 0 ]; then
  _watch_bounded=1
fi

while true; do
  now="$(date +%s)"
  if (( now - watch_start >= _UBERDEV_GOAL_STUCK_SECS )); then
    uberdev_goal_audit goal_circuit_breaker \
      "{\"reason\":\"stuck_loop\",\"watch_secs\":$((now-watch_start))}"
    _uberdev_goal_reap_zombies || true
    print_summary "$cycle"
    exit 1
  fi

  any_active=0
  # #301 speedup finding 2 — did THIS pass apply a state transition? The poll
  # order is 2a…2f, so a PR that turns green in 2b is only picked up by 2c on
  # the NEXT pass, and a PR that lands in 2d only unblocks held PRs on the next
  # pass. With an unconditional 60s sleep between passes that is up to ~120s of
  # pure poll latency per merged PR, spent doing nothing. When a pass moved the
  # state machine, the next pass has real work waiting for it — go straight
  # there. (The counter below stops this from becoming a hot loop.)
  made_transition=0

  # 2a. Detect each solver's pushed PR via GitHub (issue #180 — CLI-version-
  # independent). The pre-2.1.150 stdout-marker probe (`backgrounded ·` +
  # `pushed PR #N`) is retired: on CLI 2.1.150 `claude --bg` detaches with a
  # banner-only stdout and `pushed PR #N` has zero producers, so the loop keying
  # on it never advanced. Authoritative completion signal = a PR that closes
  # issue N exists on GitHub (`closingIssuesReferences` / `feat/N-` head). When
  # no PR exists yet, `uberdev_goal_agent_busy_for_issue` disambiguates "solver
  # still working" from "solver died", bounded by _UBERDEV_GOAL_SOLVE_TIMEOUT.
  _uberdev_goal_phase2_release_claim() {
    local issue="$1" context="${2:-terminal}" release_err release_rc
    _uberdev_goal_validate_int "$issue" || return 0
    release_err="$(gh issue edit "$issue" --remove-label "uberdev:active" --remove-assignee "@me" 2>&1 >/dev/null)"
    release_rc=$?
    if [ "$release_rc" -ne 0 ]; then
      printf 'goal-pipeline: WARN release uberdev:active claim failed for issue %s (%s, rc=%d): %s\n' \
        "$issue" "$context" "$release_rc" "$release_err" >&2
    fi
    return 0
  }

  # #301 speedup finding 1 — ONE `gh pr list` per pass instead of one per active
  # issue. The response is issue-independent, so the per-issue calls were N
  # identical round-trips every 60s against exactly the API budget this loop is
  # most sensitive to (Phase 0 step 10 pre-flights the rate limit for this
  # reason). Fetching once also makes the pass internally CONSISTENT: every issue
  # is resolved against the same snapshot, instead of issue 1 seeing a GitHub
  # state that issue 6 no longer sees.
  #
  # The fetch is LAZY — taken inside the loop, on the first issue that actually
  # needs resolving — and that placement is load-bearing, not a style choice.
  # Hoisting it above the loop makes it UNCONDITIONAL, and an unconditional
  # healthy `gh pr list` calls _uberdev_goal_reset_gh_failure every pass. Once
  # every solver has pushed (the reviewing/merging steady state, and the longest
  # phase of a run) the `continue` below skips every issue, so this pass issues
  # NO gh call at all — exactly as the pre-#301 per-issue finder did — and the
  # #290.3 consecutive-failure counter is free to accumulate the 2c/2d
  # `gh pr view` failures that are the only gh traffic left. Reset it here every
  # pass and a sustained `gh pr view` outage is pinned at 1 forever: the
  # gh_api_failed breaker can never fire and /goal rides the 4h stuck_loop
  # instead of halting loudly in ~5 min. Lazy also keeps the steady-state API
  # cost at zero rather than one 200-PR page per pass (up to 6/min under the
  # made_transition fast path).
  pr_snapshot=""
  _pr_snapshot_taken=0

  for issue in "${active_issues[@]}"; do
    istate="$(uberdev_goal_get_issue_state "$GOAL_ID" "$issue" 2>/dev/null)"
    case "$istate" in pr-pushed|resolved|resolved-by-no-action|failed) continue ;; esac
    # First issue of the pass that needs a PR number pays for the snapshot; the
    # rest resolve against it in-process. An empty snapshot means the fetch
    # failed — uberdev_goal_pr_list_snapshot has already ticked the consecutive-
    # failure counter, so the `_gh_failure_count` guard below defers the no-PR
    # classification exactly as it did for a per-issue failure (and we do NOT
    # re-fetch for the remaining issues: one failed page per pass, not N).
    if [ "$_pr_snapshot_taken" = "0" ]; then
      pr_snapshot="$(uberdev_goal_pr_list_snapshot)"
      _pr_snapshot_taken=1
    fi
    # #301 — resolve against the per-pass snapshot; identical ranking (both
    # routes share _uberdev_goal_pr_for_issue_jq), zero extra network.
    pr_num="$(uberdev_goal_find_pr_for_issue_from_json "$issue" "$pr_snapshot")"
    _gh_failure_count="$(uberdev_goal_gh_failure_count "$GOAL_ID" 2>/dev/null || printf '0')"
    _uberdev_goal_validate_int "$_gh_failure_count" || _gh_failure_count=0
    if [ -z "$pr_num" ] && [ "$_gh_failure_count" -gt 0 ]; then
      printf 'goal-pipeline: PR lookup for issue %s is unavailable after gh failure count=%s — deferring no-PR classification\n' \
        "$issue" "$_gh_failure_count" >&2
      any_active=1
      continue
    fi
    if [ -n "$pr_num" ]; then
      # #211 — register the PR into the batch-PR registry once it's resolved.
      # Registration is deferred from Phase 1 (no PR number at dispatch-time)
      # to here, the first point at which uberdev_goal_find_pr_for_issue
      # returns a non-empty value. Idempotent guard: skip if a row for this
      # PR already exists in the TSV, so subsequent passes (and repeat 2a
      # resolutions in the same cycle) don't double-write. Best-effort:
      # warn-and-continue on rc != 0 — a transient registry write must not
      # fail the watch loop.
      if ! uberdev_goal_batch_has_pr "$GOAL_ID" "$pr_num"; then
        uberdev_goal_register_batch_pr "$GOAL_ID" "$pr_num" "$issue" \
          || printf 'goal: register_batch_pr deferred-call failed for PR=%s issue=%s (rc=%s)\n' "$pr_num" "$issue" "$?" >&2
      fi
      uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving pr-pushed
      uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" dispatched pushed-reviewing
      made_transition=1   # #301 — 2b can read this PR's verdict on the next pass
      if uberdev_goal_pr_is_merged "$pr_num"; then
        # Resume / human-merged: the PR already landed. Pre-stage it through the
        # valid path so step 2d finalizes it to `merged` next pass — no wasteful
        # /review-pr or /merge dispatch against an already-merged PR.
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing green
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" green merging
      fi
      any_active=1
      continue
    fi
    # No PR yet — is the solver still alive, or did it die? Probed through the
    # SOLVER's transport (see _uberdev_goal_watch_solver_busy above), never the
    # child transport this loop pinned for its own /merge + /review-pr children.
    if _uberdev_goal_watch_solver_busy "$issue"; then
      any_active=1
    else
      # #381: the Codex solver-status sidecar branch lived here. It read
      # solve-codex-status-<ISSUE>.json through uberdev_goal_codex_status_for_issue
      # so a failed `codex exec` failed the issue immediately instead of waiting
      # out SOLVE_TIMEOUT. It keyed on
      # UBERDEV_GOAL_SOLVER_BACKEND/UBERDEV_RESOLVED_BACKEND == "codex", which
      # _UBERDEV_DISPATCH_BACKEND_ENUM can no longer produce, and its helper was
      # deleted from lib/goal-state.sh. No replacement: `background` has no
      # equivalent sidecar and `workflow` reports through the Workflow runtime's
      # structured return, so both fall through to the closed-issue probe and the
      # SOLVE_TIMEOUT path below exactly as they did before.
      # Issue #249 — issue may have been legitimately closed without a PR
      # (orchestrator marked it stale / already-resolved / non-actionable —
      # concrete prior cases: #226 / #227). Probe GitHub state before falling
      # through to the SOLVE_TIMEOUT path. Non-zero rc is treated as no-signal
      # (RFC 0005 B6 — transient gh failures must not cascade into false
      # terminal transitions); the 150-min SOLVE_TIMEOUT remains the backstop.
      _uberdev_goal_validate_int "$issue" || continue          # defence in depth (T3)
      issue_state="$(gh issue view "$issue" --json state --jq '.state' 2>/dev/null)"
      gh_rc=$?
      if [ "$gh_rc" -eq 0 ] && [ "$issue_state" = "CLOSED" ]; then
        # Guard the audit emission + continue on the transition's rc. If the
        # transition fails (rc=1 unwritable tmpdir, rc=2 invalid arc), fall
        # through to the SOLVE_TIMEOUT backstop rather than emit a false-signal
        # audit row. The issue stays in `solving` (failed transition didn't
        # persist) and lands as `failed` after the 150-min timeout.
        if uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving resolved-by-no-action; then
          # Audit emission is best-effort telemetry; a write failure (tmpdir
          # unwritable, disk full) MUST NOT halt the surrounding loop, but the
          # operator needs to see why the audit row is missing if it ever
          # happens — emit a stderr breadcrumb so post-mortem isn't a guessing
          # game (per /review-pr 251 finding SF-001).
          uberdev_goal_audit goal_issue_closed_without_pr \
            "{\"goal_id\":\"$GOAL_ID\",\"issue\":$issue,\"detected_at\":$now}" || \
            printf 'goal-pipeline: WARN audit goal_issue_closed_without_pr failed for issue %s (rc=%d) — close-without-PR row may be missing from audit log\n' \
              "$issue" "$?" >&2
          # Issue #291 #1 — terminal non-merge transition: release the
          # cross-process `uberdev:active` claim via the Phase 2 local helper.
          # Phase 2 is a fresh shell, so the Phase-1 _uberdev_goal_release_claim
          # helper is not in scope; the local helper keeps the same fail-soft
          # semantics while surfacing release failures as breadcrumbs.
          _uberdev_goal_phase2_release_claim "$issue" "closed_without_pr"
          continue
        fi
      fi
      if [ "$gh_rc" -ne 0 ]; then
        _uberdev_goal_record_gh_failure
        printf 'goal-pipeline: gh issue view %s failed rc=%d — deferring no-PR classification until GitHub state probe succeeds\n' \
          "$issue" "$gh_rc" >&2
        any_active=1
        continue
      fi
      # #381: an `elif [ "$_codex_state" = completed ]` arm sat here. It failed
      # the issue immediately when the Codex sidecar reported a clean exit with
      # no PR and no closed issue. $_codex_state was only ever set by the
      # deleted sidecar branch above, so the arm was already unreachable; both
      # surviving backends fall through to the SOLVE_TIMEOUT backstop below.
      dispatch_ts="$(uberdev_goal_issue_ts_in_state "$GOAL_ID" "$issue" solving 2>/dev/null)"
      # RFC 0015 §5 — UBERDEV_GOAL_SOLVERS_SETTLED short-circuits the wait.
      # _UBERDEV_GOAL_SOLVE_TIMEOUT (150m) answers "is the DETACHED solver still
      # working, or did it die?" — a question that only exists when the solver
      # outlives the dispatcher. The Workflow-native fleet does not: the driver
      # AWAITS its nested workflow() call, so by the time this script runs every
      # solver in the cycle has already returned. An issue with no PR and no live
      # agent is therefore terminal NOW, and waiting 150 minutes to say so would
      # burn the whole watch-tick budget proving something already known.
      # The env var is set by the driver only after the fleet call has settled,
      # so an operator running this script by hand keeps the timeout semantics.
      if [ "${UBERDEV_GOAL_SOLVERS_SETTLED:-0}" = "1" ]; then
        printf 'goal-pipeline: issue %s FAILED (no PR, no live agent, and the solver fleet for this cycle has already returned)\n' \
          "$issue" >&2
        uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving failed
        _uberdev_goal_phase2_release_claim "$issue" "fleet_settled_no_pr"
      elif [ "$(( now - dispatch_ts ))" -lt "$_UBERDEV_GOAL_SOLVE_TIMEOUT" ]; then
        any_active=1
      else
        printf 'goal-pipeline: issue %s FAILED (no PR, agent idle, %ss elapsed)\n' \
          "$issue" "$(( now - dispatch_ts ))" >&2
        uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving failed
        # Issue #291 #1 — terminal non-merge transition (SOLVE_TIMEOUT, no PR):
        # the GitHub issue is still OPEN, so a stranded `uberdev:active` claim
        # would block every future /goal cycle AND any manual /solve retry on
        # this issue. Release it through the Phase 2 local helper.
        _uberdev_goal_phase2_release_claim "$issue" "solve_timeout"
      fi
    fi
  done

  # #290.3 — sustained-gh-outage breaker. find_pr_for_issue / pr_state_gh fail
  # OPEN on a gh error (so a transient blip just re-polls), but each failure now
  # ticks a consecutive-failure counter that any success resets. After
  # _UBERDEV_GOAL_MAX_GH_FAILURES consecutive failures the breaker fires
  # gh_api_failed — so a rate-limit / auth / network window that would otherwise
  # ride the 150m solve-timeout to a FALSE `failed` (or churn a merged PR) halts
  # the goal loudly instead. (gh_api_failed previously guarded only Phase 3's
  # `gh issue list`.) print_summary + exit on fire, mirroring the wall-clock
  # barrier breaker.
  if uberdev_goal_gh_failure_breaker_check "$GOAL_ID"; then
    _uberdev_goal_reap_zombies || true
    print_summary "$cycle"
    exit 1
  fi

  # 2b. Read the leaf /review-pr verdict for PRs in pushed-reviewing (file-based
  # verdict locator + trust signal — the unchanged, version-independent contract).
  # TIME-GRACED (issue #180): the leaf solver runs its OWN /review-pr ~20m after
  # pushing and frequently goes idle in that window, so "agent idle ⇒ review
  # done" is false (keying re-review on liveness fired 3 redundant reviews in
  # 4 min and prematurely red-held a PR whose GREEN verdict had not landed).
  # Instead wait REVIEW_GRACE_SECS for the leaf's verdict, re-reading
  # the verdict JSON every poll — it advances the instant the verdict lands,
  # with zero redundant reviews on the happy path; only after the grace lapses
  # do we dispatch our own /review-pr (bounded ×3).
  for pr_num in $(uberdev_goal_list_prs_in_state "$GOAL_ID" pushed-reviewing); do
    audit_json="$(uberdev_goal_locate_review_pr_audit_by_pr "$pr_num")"
    signal="$(uberdev_goal_read_trust_signal "$audit_json")"
    # !case-arm collects the arm heads of THIS case only — it tracks
    # case/esac depth, so the nested `case "$_verdict_state"` arms below are
    # excluded structurally rather than by an indentation anchor that any
    # reindent would break.
    # CONTRACT: trust-signal !case-arm
    case "$signal" in
      green)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing green
        made_transition=1   # #301 — 2c sits ABOVE 2b in pass order; without this
                            # the freshly-green PR waits a full 60s sleep before
                            # the merge barrier even looks at it.
        ;;
      yellow)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing yellow-held
        made_transition=1
        # Baseline audit for step 2e's poll loop — a NEWER audit means a
        # re-review fired, so the poll loop applies the next transition (#159).
        uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
        ;;
      red)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
        uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
        made_transition=1
        # B6/M14 — blocker-overflow handler (D13). Explicit branch on the jq rc
        # so a corrupted audit defaults to "no overflow" rather than silently
        # skipping; sets overflow_detected (gates the Phase 3 first-10
        # truncation) and accumulates the per-cycle count.
        #
        # `$audit_json` is the canonical selector's CLOSED CONTROLLER STATE (a
        # minified JSON value), not a pathname — `uberdev_goal_locate_review_pr_audit_by_pr`
        # stopped returning paths when the shared verdict selector landed. It must
        # therefore be parsed as a value: `gh_jq_or_jq` opens with `[ -f "$file" ]`,
        # so feeding it JSON made this branch fail on EVERY red PR, permanently
        # pinning overflow_detected at 0 and making the Phase 3 truncation dead
        # code. The field is read at its projected top-level name, not the
        # `.phases.phase2_5.*` shape of the raw on-disk verdict.
        if halted_overflow="$(jq -er '.phase2_5_halted_due_to_overflow // false' <<<"$audit_json" 2>/dev/null)"; then
          if [ "$halted_overflow" = "true" ]; then
            overflow_detected=1
            overflow_count=$(( ${overflow_count:-0} + 1 ))
            uberdev_goal_write_run_state || echo "goal: warning: run-state flush failed in Phase 2b" >&2
          fi
        else
          printf 'goal-pipeline: overflow check failed to read audit %s for PR %s; treating as no overflow this cycle\n' \
            "$audit_json" "$pr_num" >&2
        fi
        ;;
      stale|missing)
        # #348 finding 1+2 — SPLIT the non-recoverable discovery outcomes out of
        # this arm BEFORE the benign cascade below. `stale|missing` is the
        # "no verdict has landed YET" lane, and its whole recovery strategy is
        # "wait, then re-review". Two outcomes reach it that re-reviewing can
        # never fix, and until now were indistinguishable from a fresh PR:
        #
        #   indeterminate — the canonical selector found MULTIPLE candidate
        #     verdicts it cannot rank (e.g. a duplicate-timestamp tie), or an
        #     unreadable root made the scan non-exhaustive. Re-reviewing adds
        #     ANOTHER candidate; the tie gets worse, never better.
        #   tamper        — the private carrier this run selected did not survive
        #     digest/identity recapture: it was replaced, mutated, symlinked or
        #     re-owned. That is the strongest security signal this machinery
        #     produces, and it read exactly like "no review has run yet".
        #
        # Both are bounded HERE by their own per-PR counter, and both land the PR
        # in red-held with a reason that names the real cause. Pre-#348 the PR
        # instead burned the review-pr dispatch cap and was red-held as
        # `dispatch_cap_exhausted` — a label that sends the operator to look at
        # /review-pr dispatch, which is not where the problem is.
        _verdict_state="$(uberdev_goal_last_verdict_state "$pr_num")"
        case "$_verdict_state" in
          indeterminate|tamper)
            uberdev_goal_record_verdict_anomaly "$GOAL_ID" "$pr_num" "$_verdict_state" \
              || printf 'goal-pipeline: WARN could not record %s verdict anomaly for PR %s — the bound may not hold\n' "$_verdict_state" "$pr_num" >&2
            _anomaly_count="$(uberdev_goal_count_verdict_anomalies "$GOAL_ID" "$pr_num" "$_verdict_state")"
            _uberdev_goal_validate_int "$_anomaly_count" || _anomaly_count=0
            if [ "$_anomaly_count" -ge "${_UBERDEV_GOAL_MAX_VERDICT_ANOMALIES:-3}" ]; then
              if [ "$_verdict_state" = "tamper" ]; then
                _held_reason="verdict_tamper_detected"
              else
                _held_reason="verdict_indeterminate"
              fi
              uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
              uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
              uberdev_goal_audit goal_review_pr_deferred \
                "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr_num,\"reason\":\"$_held_reason\",\"action\":\"red_held\",\"observations\":$_anomaly_count,\"cap\":${_UBERDEV_GOAL_MAX_VERDICT_ANOMALIES:-3}}" || true
              printf 'goal-pipeline: PR %s held (%s) — the verdict artifact is unusable after %s observations; re-reviewing cannot resolve this, inspect .uberdev/runs/ by hand\n' \
                "$pr_num" "$_held_reason" "$_anomaly_count" >&2
              # Pseudo-terminal for convergence; do NOT hold any_active for it.
              continue
            fi
            # Under the bound: keep polling (a genuinely transient tie can clear
            # when the losing candidate is cleaned up) but never fall into the
            # benign cascade, which would spend the review-pr dispatch cap.
            any_active=1
            printf 'goal-pipeline: PR %s verdict discovery reported %s (%s/%s) — re-polling; NOT dispatching a re-review (it cannot fix this cause)\n' \
              "$pr_num" "$_verdict_state" "$_anomaly_count" "${_UBERDEV_GOAL_MAX_VERDICT_ANOMALIES:-3}" >&2
            continue
            ;;
        esac
        # No verdict yet. Cascade — marker → grace → in-flight → stuck → dispatch
        # (issue #220, Components 3.2-3.4). Order is load-bearing: each probe
        # short-circuits before the next, so the stuck-on-dialog circuit breaker
        # only fires when every benign explanation (marker present, grace not
        # lapsed, /review-pr legitimately in flight) is ruled out. seen_ts comes
        # from the pr-states TSV (FIRST pushed-reviewing transition for this PR).
        # D17: never assume GREEN.
        #
        # seen_ts = FIRST pushed-reviewing transition for this PR (first-wins is
        # load-bearing for the grace window — see uberdev_goal_pr_first_ts_in_state
        # doc + issue #222 B8). t+0 coerces absent → 0 so `$((now - seen_ts))` is
        # arithmetic-safe.
        seen_ts=$(uberdev_goal_pr_first_ts_in_state "$GOAL_ID" "$pr_num" pushed-reviewing 2>/dev/null)
        # Marker probe (Component 3.2)
        if _uberdev_goal_locked_marker_for_pr_fresh "$pr_num" "$REVIEW_GRACE_SECS"; then
          any_active=1
          uberdev_goal_audit goal_review_grace \
            "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr_num,\"note\":\"marker_present\"}"
        elif [ "$(( now - seen_ts ))" -lt "$REVIEW_GRACE_SECS" ]; then
          any_active=1
        # In-flight probe (Component 3.3)
        elif uberdev_goal_review_pr_in_flight "$pr_num"; then
          any_active=1
          uberdev_goal_audit goal_review_pr_deferred \
            "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr_num,\"reason\":\"in_flight\",\"in_flight_count\":1}"
        # Stuck-on-dialog probe (Component 3.4) — circuit-breaker fires HERE
        elif _uberdev_goal_any_attempt_stuck "$pr_num"; then
          _stuck_pid=""
          _stuck_status=""
          _stuck_last_activity=""
          _batch_tsv="$UBERDEV_TMPDIR/goal-$GOAL_ID-batch-prs.tsv"
          if [ -f "$_batch_tsv" ]; then
            while IFS=$'\t' read -r _row_pr _issue _ts _state; do
              [ "$_row_pr" = "$pr_num" ] || continue
              # R1 SSOT (issue #220 simplify pass): PID extraction via shared helper.
              # Helper returns rc=0 with PID on stdout iff every gate passes, else
              # rc=1 with empty stdout — `&& break` exits the loop on first valid PID.
              _stuck_pid="$(_uberdev_goal_pid_for_issue "$_issue")" && break
            done < "$_batch_tsv"
          fi
          if [ -n "$_stuck_pid" ]; then
            _sample="$(claude agents --json 2>/dev/null | jq -r --argjson pid "$_stuck_pid" \
              '.[]? | select(.pid? == $pid) | "\(.status // "")\t\(.lastActivityAt // "")"' 2>/dev/null || echo $'\t')"
            _stuck_status="${_sample%%$'\t'*}"
            _stuck_last_activity="${_sample##*$'\t'}"
          fi
          uberdev_goal_audit goal_circuit_breaker \
            "{\"reason\":\"agent_stuck_on_dialog\",\"pid\":${_stuck_pid:-0},\"pr\":$pr_num,\"status\":\"$_stuck_status\",\"lastActivityAt\":\"$_stuck_last_activity\"}"
          CIRCUIT_BREAKER_HALT="agent_stuck_on_dialog"
          uberdev_goal_write_run_state || true
          _uberdev_goal_reap_zombies || true
          print_summary "$cycle"
          exit 1
        else
          # #219 — surface a re-dispatch failure as a breadcrumb (mirrors the
          # register_batch_pr best-effort pattern above). The watch loop re-polls,
          # so a failed re-dispatch is retried next iteration rather than halting.
          #
          # #301 (RFC 0012 §3.3 goal-R1 item 4) — the helper returns the DISTINCT
          # rc 5 on cap exhaustion (pre-#301 it returned rc 0 there, identical to
          # a successful dispatch, so this arm kept any_active=1 and the PR spun
          # in pushed-reviewing until the 4h stuck_loop reaped every live
          # solver). On rc 5: every bounded re-review attempt is spent and no
          # verdict landed — transition pushed-reviewing → red-held
          # (pseudo-terminal for convergence; surfaced in print_summary's held
          # rows; step 2c's snapshot tags it HELD for the barrier; step 2e still
          # promotes it if a verdict ever lands) with a DISTINCT audit note, and
          # do NOT hold any_active for it.
          _uberdev_goal_dispatch_review_pr "$pr_num"
          _rpr_rc=$?
          if [ "$_rpr_rc" -eq 5 ]; then
            uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
            uberdev_goal_audit goal_review_pr_deferred \
              "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr_num,\"reason\":\"dispatch_cap_exhausted\",\"action\":\"red_held\",\"cap\":${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3}}" || true
          elif [ "$_rpr_rc" -ne 0 ]; then
            printf 'goal-pipeline: review-pr re-dispatch for PR %s failed (rc=%s) — will retry next poll\n' "$pr_num" "$_rpr_rc" >&2
            any_active=1
          else
            any_active=1
          fi
        fi
        ;;
    esac
  done

  # 2c. Barrier-gated merge dispatch (issue #211; barrier semantics #289).
  # The previous per-PR `if green; then /merge` body is replaced by a two-
  # predicate gate: ONLY dispatch /merge once (a) every PR in the batch is in
  # a terminal state (GREEN | HELD | MERGE_FAILED | MERGED — barrier-terminal,
  # NOT to be confused with the convergence-terminal set; MERGING is the
  # NON-terminal in-flight sentinel from #289.2) AND (b) the unblock wait is
  # clear. #289.1/#289.3: a HELD row gates the barrier ONLY while at least one
  # of its `Blocks: #N` issues is still OPEN (the legitimate hold-and-unblock
  # window); once ALL its blockers close it is PSEUDO-TERMINAL and no longer
  # gates co-batched GREEN PRs — whether or not the re-review cleared it green
  # (detected via the `uberdev-approved` label /review-pr actually writes, NOT
  # the zero-producer `review-pr:green`). Until both predicates hold the
  # per-cycle batch sits at the merge barrier — preventing the multi-PR
  # version-bump collision (the user_workflow_todo_queue memory +
  # project_uberdev_goal_version_bump_collision capture). #289.2: STRICT
  # lowest-first single-dispatch + the MERGING interlock keep the
  # manifest-touching PRs serialized (at most one merge in flight).
  #
  # B2 — only transition to `merging` on dispatch rc=0; a failed dispatch
  # (mktemp/prompt-write/session-refuse) leaves the PR in `green` for a
  # next-cycle retry (per-PR attempt counter, cap 3, bounds runaway retries).

  # Snapshot every barrier-relevant PR's state into the batch registry. This
  # is what feeds uberdev_goal_batch_all_terminal: rows tagged PENDING block
  # the barrier; rows tagged GREEN/HELD/MERGE_FAILED/MERGED clear it. Call
  # uberdev_goal_list_prs_in_state once per state (it takes a single state
  # argument) and tag with the matching terminal enum.
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" green); do
    _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" GREEN \
      || printf 'goal: set_batch_terminal_state(GREEN) failed for PR=%s (rc=%s); barrier may stall\n' "$pr" "$?" >&2
  done
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held; \
              uberdev_goal_list_prs_in_state "$GOAL_ID" red-held); do
    _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" HELD \
      || printf 'goal: set_batch_terminal_state(HELD) failed for PR=%s (rc=%s); barrier may stall\n' "$pr" "$?" >&2
  done
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" merge-failed); do
    _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" MERGE_FAILED \
      || printf 'goal: set_batch_terminal_state(MERGE_FAILED) failed for PR=%s (rc=%s); barrier may stall\n' "$pr" "$?" >&2
  done
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" merged); do
    _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" MERGED \
      || printf 'goal: set_batch_terminal_state(MERGED) failed for PR=%s (rc=%s); barrier may stall\n' "$pr" "$?" >&2
  done

  if uberdev_goal_batch_all_terminal "$GOAL_ID" && \
     uberdev_goal_batch_unblock_wait_clear "$GOAL_ID"; then
    # #289.2 (BLOCKER) — STRICTLY SERIALIZE version-bump merges. The prior loop
    # dispatched /merge for ALL green PRs in one async pass (each
    # _uberdev_goal_dispatch_merge → claude --bg returns immediately); the
    # collision-chain ran between dispatches but only fetched main + audited —
    # it never WAITED for the prior merge to land and never renumbered. So two
    # version-bump PRs both landed vN+1 and git silently ate the second bump
    # (project_uberdev_merge_version_collision).
    #
    # Fix: handle ONLY the lowest green PR per pass, then `break`. The instant
    # we dispatch its /merge we flip its batch row to MERGING (a non-terminal
    # sentinel — #289.2 in goal-state.sh). That makes uberdev_goal_batch_all_terminal
    # rc 1 on every subsequent pass, so the Phase-2c gate above stays FALSE and
    # NO further /merge can be dispatched until Phase 2d drives this PR to
    # MERGED. Only then does batch_all_terminal clear again and the NEXT-lowest
    # green PR — now rebased onto the just-landed vN+1 main, re-reviewed, and
    # renumbered to vN+2 by its own /merge — become eligible. The in-pass
    # `break` + the cross-pass MERGING interlock together guarantee at most one
    # manifest-touching merge is ever in flight.
    # >>> region: merge-dispatch-gate
    pr="$(_uberdev_goal_batch_green_prs_ordered "$GOAL_ID" | head -n 1)"
    if [ -n "$pr" ]; then
      if uberdev_goal_pr_is_merged "$pr"; then
        # Resume / human-merged — finalize via step 2d without re-dispatching
        # /merge against an already-landed PR. Flip the batch row to MERGING so
        # the barrier stays closed until 2d records MERGED.
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
        _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" MERGING \
          || printf 'goal: set_batch_terminal_state(MERGING) failed for PR=%s (rc=%s); barrier may not serialize\n' "$pr" "$?" >&2
        any_active=1
      # Phase 2c in-flight gate (issue #220, Component 3.3) — never dispatch
      # /merge while the lowest green PR still has a /review-pr in flight. Defer
      # the WHOLE merge step one poll tick (do NOT skip ahead to a higher PR —
      # that would let a higher-numbered version bump land before the lower one,
      # reintroducing the collision). Emits goal_merge_deferred for the audit.
      elif uberdev_goal_review_pr_in_flight "$pr"; then
        any_active=1
        uberdev_goal_audit goal_merge_deferred \
          "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"review_in_flight\",\"in_flight_count\":1}"
      elif uberdev_goal_should_automerge "$GOAL_ID" "$pr"; then
        # #364 — GUARANTEE THE VERSION BUMP BEFORE THE MERGE IS DISPATCHED.
        # The ORDER is the entire contract: the fleet solvers are forbidden from
        # bumping (N parallel solvers off one base all resolve the same next
        # version and the duplicate change auto-merges without a conflict), so
        # if nothing adds the bump HERE the PR lands with every version surface
        # still at the old value — CI stays green, the marketplace never serves
        # the update, and the failure is completely silent. This is also the
        # only strictly-serialized point in the run (one green PR per pass +
        # the MERGING interlock), so `origin/<base>` already carries the
        # previous landing's bump and sequential numbering is correct here and
        # nowhere earlier.
        #
        # FAIL CLOSED: a bump that could not be guaranteed leaves the PR in
        # `green` for a later pass and emits a goal_merge_deferred audit row.
        # Merging unbumped IS the bug, so merging is never the fallback.
        #
        # THREE-WAY exit status, not a boolean (#364 review):
        #   2 — bump PUSHED this pass -> the push restarted the PR's checks;
        #       dispatching now is a DETERMINISTIC /merge gate_fail on
        #       reason=ci_red (Step 1.4 reads any pending rollup entry as red,
        #       and its settle probe is bounded at 3x10s against a CI critical
        #       path of minutes). Three such passes exhaust
        #       _UBERDEV_GOAL_MAX_MERGE_ATTEMPTS, should_automerge starts
        #       returning 1, no arm is taken, and the PR sits in `green` until
        #       the 4h stuck_loop breaker — a hard stall of the whole run.
        #       Defer instead; the next pass sees already_bumped (rc 0).
        #   0 — already bumped / no ratchet -> fall through to the CI gate.
        #   anything else — fail closed. The `-ne 0` arm is deliberately the
        #       catch-all rather than a literal `-eq 1`: an exit status this
        #       lane does not recognise must NEVER reach the merge dispatch,
        #       so a future status added to the helper cannot silently become
        #       "merge it" here.
        _uberdev_goal_ensure_version_bump "$pr"
        version_bump_rc=$?
        if [ "$version_bump_rc" -eq 2 ]; then
          printf 'goal-pipeline: PR %s bumped and pushed this pass — deferring /merge until the restarted checks settle\n' \
            "$pr" >&2
          any_active=1
          uberdev_goal_audit goal_merge_deferred \
            "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"ci_restarted_by_version_bump\"}"
        elif [ "$version_bump_rc" -ne 0 ]; then
          printf 'goal-pipeline: PR %s NOT dispatched to /merge — its version bump could not be guaranteed (rc=%s; see the version_bump_failed audit row); staying green for a later pass\n' \
            "$pr" "$version_bump_rc" >&2
          any_active=1
        # CI-settle gate. Withholding only — it can never authorise a merge (a
        # gh failure or an unconfigured-checks repo returns rc 1 and falls
        # through to /merge, which owns the hard CI gate). The 4h stuck_loop
        # wall clock remains the backstop for a check that never completes.
        elif _uberdev_goal_pr_checks_pending "$pr"; then
          printf 'goal-pipeline: PR %s has checks still running — deferring /merge rather than burning a merge attempt on a pending rollup\n' \
            "$pr" >&2
          any_active=1
          uberdev_goal_audit goal_merge_deferred \
            "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"ci_pending\"}"
        elif _uberdev_goal_dispatch_merge "$pr"; then
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
          # Flip to the MERGING sentinel BEFORE the collision-chain so the very
          # next batch_all_terminal read (this PR no longer GREEN/terminal)
          # blocks re-entry — the cross-pass half of the serialization.
          _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$pr" MERGING \
            || printf 'goal: set_batch_terminal_state(MERGING) failed for PR=%s (rc=%s); barrier may not serialize\n' "$pr" "$?" >&2
          # Force-refresh main + flag any remaining green batch PRs that share
          # manifest paths so the NEXT pass's /merge dispatch rebases onto the
          # just-landed commit and renumbers its bump (collision-chain, R5).
          # Helper contract is "rc 0 always"; no `||` fallback needed.
          _uberdev_goal_rebase_collision_chain "$GOAL_ID" "$pr"
          any_active=1
        else
          printf 'goal-pipeline: _uberdev_goal_dispatch_merge failed for PR %s; staying in green for next-cycle retry\n' \
            "$pr" >&2
          any_active=1
        fi
      fi
      # No loop: exactly one green PR is acted on per pass (strict
      # lowest-first serialization, #289.2). The rest wait behind the MERGING
      # interlock until this one reaches MERGED in step 2d.
    fi
    # <<< region: merge-dispatch-gate
  else
    # Barrier NOT clear yet — at least one PR is PENDING or the unblock-wait
    # has unresolved blockers.
    #
    # #292.1 — mutual-Blocks DEADLOCK guard, checked BEFORE the wall-clock
    # cap. _uberdev_goal_check_unblock only re-reviews a held PR when ALL its
    # Blocks: issues close, with no cycle detection: A-blocks-B + B-blocks-A
    # would otherwise spin both held PRs to the 4h stuck_loop with no
    # diagnostic naming the cycle. uberdev_goal_detect_blocks_cycle finds an
    # SCC over the Blocks: edges across the batch's held PRs; on a hit, halt
    # NOW with a distinct stuck_loop/phase=blocks_cycle row + the cycle PR set
    # (D5 keeps GOAL_CIRCUIT_BREAKER_REASONS closed — the phase subfield
    # distinguishes this, mirroring phase=merge_barrier).
    cycle_prs="$(uberdev_goal_detect_blocks_cycle "$GOAL_ID")"
    if [ -n "$cycle_prs" ]; then
      uberdev_goal_audit goal_circuit_breaker \
        "$(printf '{"reason":"stuck_loop","phase":"blocks_cycle","cycle_prs":"%s"}' "$cycle_prs")"
      printf 'goal-pipeline: HALT — mutual Blocks: dependency cycle among held PRs (%s); no PR in the cycle can ever unblock\n' \
        "$cycle_prs" >&2
      _uberdev_goal_reap_zombies || true
      print_summary "$cycle"
      exit 1
    fi
    # Check the wall-clock circuit breaker against
    # BARRIER_TIMEOUT_S (default 4h, configurable via --barrier-timeout=N /
    # UBERDEV_GOAL_BARRIER_TIMEOUT_S / goal.barrier_timeout_s). The reason
    # field reuses the existing stuck_loop enum — D5 keeps GOAL_CIRCUIT_
    # BREAKER_REASONS closed; the phase=merge_barrier subfield distinguishes
    # this from the goal-level 4h watch-loop stuck_loop.
    # Wall-clock merge-barrier breaker: helper reads sidecar barrier_start_ts,
    # computes elapsed, fires goal_circuit_breaker on threshold breach.
    # Helper-extracted from inline math (issue #214). Payload + side-effects
    # verbatim-equivalent — `pending_prs` lookup against batch-prs.tsv is
    # internal to the helper.
    if uberdev_goal_barrier_breaker_check "$GOAL_ID" "$BARRIER_TIMEOUT_S"; then
      print_summary "$cycle"
      exit 1
    fi
    any_active=1
  fi

  # 2d. Drive merging → merged. Completion is authoritative via GitHub
  # (`gh pr view <pr> --json state == MERGED`, issue #180 — the
  # merge-bg-stdout-<pr>.log marker this step used to poll was NEVER written by
  # any dispatch backend, so the gate could not fire). For PRs that did NOT
  # merge, read_merge_result (gh-state-first, then the local audit) classifies
  # the failure: conflict / hook_failed halt the goal; CLOSED-without-merge is
  # a hard merge_failed; `missing` defers (re-poll) with a MERGE_TIMEOUT
  # fallback to `green` when the merge agent stalled.
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" merging); do
    # Read gh state ONCE per PR per poll and branch on it locally — the MERGED
    # gate and the CLOSED gate previously called uberdev_goal_pr_state_gh twice
    # (once via pr_is_merged), a redundant `gh pr view` round-trip every poll
    # while a /merge agent runs. Folding to one read cuts the steady-state merge
    # poll cost and the gh-failure breadcrumb noise in half (the rate-limit
    # exhaustion this loop is sensitive to). Behavior is identical: same MERGED /
    # CLOSED / else branch decisions.
    pr_state="$(uberdev_goal_pr_state_gh "$pr")"
    if [ "$pr_state" = "MERGED" ]; then
      uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" merging merged
      made_transition=1   # #301 — the merge just cleared the barrier for the
                          # next-lowest green PR; do not idle 60s before 2c sees it.
      # B4 — uberdev_goal_list_prs_in_state takes ONE state ($2); call twice
      # and concatenate so BOTH held sets get the unblock check.
      for held_pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held; \
                       uberdev_goal_list_prs_in_state "$GOAL_ID" red-held); do
        _uberdev_goal_check_unblock "$held_pr"
      done
      continue
    fi
    # Not merged — a CLOSED-without-merge PR is a hard merge failure.
    if [ "$pr_state" = "CLOSED" ]; then
      uberdev_goal_audit goal_circuit_breaker \
        "{\"reason\":\"merge_failed\",\"pr\":$pr,\"detail\":\"closed\"}"
      _uberdev_goal_reap_zombies || true
      print_summary "$cycle"
      exit 1
    fi
    result="$(uberdev_goal_read_merge_result "$pr")"
    case "$result" in
      success)
        # Audit says success but gh has not flipped to MERGED yet — a brief
        # write/state race; re-poll next iteration (pr_is_merged is the SSOT).
        any_active=1
        ;;
      conflict|hook_failed)
        uberdev_goal_audit goal_circuit_breaker \
          "{\"reason\":\"merge_failed\",\"pr\":$pr,\"result\":\"$result\"}"
        _uberdev_goal_reap_zombies || true
        print_summary "$cycle"
        exit 1
        ;;
      missing)
        # /merge agent still in flight, OR stalled. If past MERGE_TIMEOUT with
        # no live agent, fall back to `green` so step 2c retries (bounded by the
        # per-PR merge-attempt cap). Otherwise keep waiting.
        # NOTE the liveness probe is keyed on $pr (the PR number), not an issue
        # number: _uberdev_goal_dispatch_merge dispatches via
        # `uberdev_dispatch_one "$pr" …`, and uberdev_dispatch_one names every
        # worktree `solve-issue-<key>` (lib/dispatch.sh) — so a merge agent's cwd
        # is `solve-issue-<pr>` and `agent_busy_for_issue "$pr"` matches it
        # correctly. (The function name says "for_issue" because the SHARED
        # naming convention is solve-issue-<key>; the key here is a PR.)
        merge_ts="$(uberdev_goal_pr_ts_in_state "$GOAL_ID" "$pr" merging 2>/dev/null)"
        if [ "$(( now - merge_ts ))" -ge "$_UBERDEV_GOAL_MERGE_TIMEOUT" ] \
           && ! uberdev_goal_agent_busy_for_issue "$pr"; then
          printf 'goal-pipeline: PR %s merge stalled (%ss, agent idle) -> back to green for retry\n' \
            "$pr" "$(( now - merge_ts ))" >&2
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" merging green
        fi
        any_active=1
        ;;
      *)
        # B7 — defensive default. read_merge_result is contracted to return
        # success|conflict|hook_failed|missing; any other value is contract
        # drift — halt loudly rather than leave the PR stuck in `merging`.
        uberdev_goal_audit goal_circuit_breaker \
          "{\"reason\":\"unknown_merge_result\",\"pr\":$pr,\"result\":\"$result\"}"
        _uberdev_goal_reap_zombies || true
        print_summary "$cycle"
        exit 1
        ;;
    esac
  done

  # 2e. Poll held PRs for re-review completion (RFC 0005 §3.2.3 hold-and-
  # unblock completion-half; #159). When the unblock rule (step 2d) dispatches
  # a `/uberdev:review-pr` for a newly-unblocked PR, that re-review writes a
  # NEW audit JSON under `.uberdev/runs/<new-run-id>/`. Without this poll,
  # the dispatch is fire-and-forget — the held PR never exits the held state
  # because no phase examines the re-review's verdict. The poll uses
  # `uberdev_goal_get_last_held_audit` to compare the live latest-audit path
  # against the one consumed last cycle; a different path means a re-review
  # fired, so the trust signal is read and the next state transition applied.
  #
  # Transitions emitted from this step:
  #   - {yellow,red}-held → green when the new re-review is green
  #   - yellow-held → red-held when the new re-review escalates severity
  #   - red-held → yellow-held when the new re-review downgrades severity
  # Same-severity re-reviews and stale/missing signals leave state unchanged
  # (the operator or the next unblock chain handles those).
  #
  # Held-as-terminal classification (#160) means a held PR that no re-review
  # ever clears will still let the goal converge — Phase 3's terminal set
  # includes both held states. This poll is the optimistic exit path; the
  # convergence-as-terminal path is the pessimistic fallback.
  for held_pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held; \
                   uberdev_goal_list_prs_in_state "$GOAL_ID" red-held); do
    new_audit="$(uberdev_goal_locate_review_pr_audit_by_pr "$held_pr")"
    [ -n "$new_audit" ] || continue
    last_audit="$(uberdev_goal_get_last_held_audit "$GOAL_ID" "$held_pr")"
    [ "$new_audit" = "$last_audit" ] && continue

    held_signal="$(uberdev_goal_read_trust_signal "$new_audit")"
    held_current="$(uberdev_goal_get_pr_state "$GOAL_ID" "$held_pr")"
    # Record the audit ONLY when the signal is readable and produced a
    # decision (green/yellow/red). On stale|missing the audit is transiently
    # unreadable — recording it here would mark it "consumed" so the next
    # poll's `[ "$new_audit" = "$last_audit" ] && continue` guard would
    # short-circuit forever, defeating the explicit defer-to-next-poll
    # contract on the stale|missing arm (#159 post-impl-review B1).
    case "$held_signal" in
      green)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$held_pr" "$held_current" green
        uberdev_goal_record_held_audit "$GOAL_ID" "$held_pr" "$new_audit"
        made_transition=1
        # #292.2 — reset the per-PR merge-attempt counter on this held→green
        # recovery. The cap (uberdev_goal_should_automerge, default 3) is
        # otherwise per-PR-LIFETIME and never reset, so a PR blocked for ≥2
        # cycles can hit the cap from transient merge stalls accumulated across
        # its hold and never auto-merge again (stalling into
        # queue_empty_not_converged with a GREEN-but-unmergeable PR). Scoping
        # the cap to the PR's CURRENT green lifetime fixes that. Best-effort:
        # a counter-reset write failure must not block the recovery transition.
        uberdev_goal_reset_merge_attempts "$GOAL_ID" "$held_pr" \
          || printf 'goal: reset_merge_attempts failed for PR=%s (rc=%s); merge cap may not reset\n' \
             "$held_pr" "$?" >&2
        # #211 — update the batch registry so the next pass's step 2c
        # barrier sees this PR as GREEN (terminal-for-barrier) instead of
        # PENDING/HELD. Without this, a held→green transition is invisible
        # to uberdev_goal_batch_all_terminal and the barrier stalls until
        # the wall-clock breaker fires.
        _uberdev_goal_set_batch_terminal_state "$GOAL_ID" "$held_pr" GREEN \
          || printf 'goal: set_batch_terminal_state(GREEN) failed for PR=%s (rc=%s); barrier may stall\n' \
             "$held_pr" "$?" >&2
        # B1 — keep the watch loop alive for one more iteration so step 2c
        # (which runs ABOVE step 2e in cycle order) has a chance to pick this
        # freshly-green PR up on the next pass and dispatch /merge. Without
        # this, the held→green transition is invisible to step 2f's
        # termination check on the SAME iteration: `any_active` could already
        # be 0 from the active-issues walk, the merging set is empty, and the
        # loop breaks with a near-merged PR that Phase 3 then mis-classifies
        # as queue_empty_not_converged.
        any_active=1
        ;;
      yellow)
        if [ "$held_current" = "red-held" ]; then
          uberdev_goal_pr_state_transition "$GOAL_ID" "$held_pr" red-held yellow-held
        fi
        uberdev_goal_record_held_audit "$GOAL_ID" "$held_pr" "$new_audit"
        ;;
      red)
        if [ "$held_current" = "yellow-held" ]; then
          uberdev_goal_pr_state_transition "$GOAL_ID" "$held_pr" yellow-held red-held
        fi
        uberdev_goal_record_held_audit "$GOAL_ID" "$held_pr" "$new_audit"
        ;;
      stale|missing)
        # Re-review audit not yet readable (mid-write, or jq parse failed).
        # Do NOT re-dispatch a fresh /review-pr here — the unblock rule
        # already dispatched one; another dispatch would race against it.
        # Defer to the next poll cycle — explicit no-op, no record call
        # (see comment above the case statement).
        ;;
    esac
  done

  # 2f. Termination check (intra-cycle). DRAINED = no active agents AND no
  # merging PR. In the UNBOUNDED loop this `break`s out of `while true` and the
  # fence flows inline into Phase 3. In BOUNDED mode there is no inline Phase 3
  # (the harness re-invokes a separate Phase-3 fence), so persist run-state and
  # exit 0 — the documented "drained -> proceed to Phase 3" code (#299 finding 2).
  if [ "$any_active" = "0" ] && \
     [ -z "$(uberdev_goal_list_prs_in_state "$GOAL_ID" merging)" ]; then
    if [ "$_watch_bounded" = "1" ]; then
      # #300 Fix B (silent-failure-hunter CRITICAL) — fail LOUD on a run-state
      # flush failure at this bounded-exit boundary. write_run_state persists the
      # SOURCE-OF-TRUTH run-state (cycle/queue/active_issues + the WATCH_* bound);
      # degrading a failed flush to a warning and still `exit 0` would proceed to
      # Phase 3 on UNPERSISTED state. Halt with exit 1 instead. Do NOT reap here:
      # this is a fail-loud halt distinct from a circuit-breaker exit 1 (which
      # reaps first) — the bg solver agents must survive a transient persist blip.
      if ! uberdev_goal_write_run_state; then
        echo "goal: ERROR: run-state flush FAILED at drain boundary — halting (exit 1) rather than proceeding to Phase 3 on unpersisted state; bg solver agents left intact" >&2
        exit 1
      fi
      echo "goal: watch drained (no active agents, no merging PRs) -> proceed to Phase 3 [bounded-tick exit 0]" >&2
      exit 0
    fi
    break
  fi

  # #299 finding 2 — bounded-watch pass/budget gate. A pass just completed; count
  # it, then decide whether THIS fence's bound is reached. If so, persist
  # run-state and exit 42 ("still-active, re-invoke") WITHOUT reaping — the bg
  # solver agents must survive the paused tick (the reaper fires ONLY on a
  # circuit-breaker halt or an operator INT, never on a bounded pause; #301
  # routes harness-TERM through the same no-reap persist + exit 42 contract).
  # The UNBOUNDED path falls straight through to sleep.
  if [ "$_watch_bounded" = "1" ]; then
    _tick_passes=$(( _tick_passes + 1 ))
    _tick_now="$(date +%s)"
    _bound_hit=0
    if [ "${WATCH_PASSES:-0}" -gt 0 ] && [ "$_tick_passes" -ge "$WATCH_PASSES" ]; then
      _bound_hit=1
    fi
    # WATCH_BUDGET is a FLOOR-OF-ONE-PASS, not a hard ceiling: this gate is
    # reached only AFTER a full poll pass has completed, so a budget smaller than
    # one pass of gh-call latency still runs (and is billed for) exactly one pass.
    # The check bounds the SLEEP we are about to enter (it pre-adds one poll
    # interval so we never sleep PAST the budget), not the pass duration — size
    # the budget to leave headroom for one pass of gh latency under the harness
    # call cap.
    if [ "${WATCH_BUDGET:-0}" -gt 0 ] && \
       [ "$(( _tick_now - _tick_start + _UBERDEV_GOAL_POLL_SECS ))" -gt "$WATCH_BUDGET" ]; then
      _bound_hit=1
    fi
    if [ "$_bound_hit" = "1" ]; then
      # #300 Fix B (silent-failure-hunter CRITICAL) — fail LOUD on a run-state
      # flush failure at this bounded-exit boundary. write_run_state persists the
      # WATCH_PASSES/WATCH_BUDGET bound (+ cycle/queue/active_issues); if it fails
      # and we still `exit 42`, the harness re-invokes a fresh Phase-2 fence that
      # rehydrates from the UNWRITTEN sidecar -> WATCH_* default to 0 -> the loop
      # SILENTLY reverts to UNBOUNDED (then the 600s harness cap SIGTERMs it ->
      # reaper). Halt with exit 1 instead. Do NOT reap here: this is a fail-loud
      # halt distinct from a circuit-breaker exit 1 (which reaps first) — the bg
      # solver agents must survive a transient persist blip.
      if ! uberdev_goal_write_run_state; then
        echo "goal: ERROR: run-state flush FAILED at tick boundary — halting (exit 1) rather than re-inviting Phase 2 on a lost bound that would silently revert to unbounded; bg solver agents left intact" >&2
        exit 1
      fi
      echo "goal: watch bound reached (passes=$_tick_passes/${WATCH_PASSES:-0} budget=$(( _tick_now - _tick_start ))/${WATCH_BUDGET:-0}s); work still in flight -> re-invoke Phase 2 [bounded-tick exit 42]" >&2
      exit 42
    fi
  fi

  # #301 speedup finding 2 — skip the poll sleep when THIS pass moved the state
  # machine. The steps run 2a…2f in a fixed order, so a transition applied in a
  # later step is not consumed until the next pass; sleeping 60s first adds up
  # to ~120s of dead latency per merged PR for no benefit, because the work is
  # already sitting there waiting.
  #
  # The consecutive bound is the load-bearing half. An unbounded "transition =>
  # no sleep" rule is a hot loop the moment two PRs keep handing each other
  # work, and every pass costs a `gh pr view` per merging PR (plus the ONE
  # lazily-taken `gh pr list` page, and only while some issue still has no PR)
  # — i.e. exactly the rate-limit exhaustion Phase 0 step 10 warns about,
  # converted from a warning into a self-inflicted 403 storm. After
  # _UBERDEV_GOAL_MAX_FAST_PASSES back-to-back fast passes we sleep regardless
  # and reset, which keeps the burst bounded while still collapsing the common
  # 2-3 pass hand-off chains to a single poll interval.
  if [ "${made_transition:-0}" = "1" ] \
     && [ "${_fast_passes:-0}" -lt "${_UBERDEV_GOAL_MAX_FAST_PASSES:-5}" ]; then
    _fast_passes=$(( ${_fast_passes:-0} + 1 ))
    continue
  fi
  _fast_passes=0
  sleep "$_UBERDEV_GOAL_POLL_SECS"
done

# The UNBOUNDED loop `break`s out of `while true` on drain (step 2f). In the
# fence era that break flowed inline into the Phase-3 fence; now it is the
# process boundary, so make the drain explicit and honour the same exit-0 code
# the bounded arm uses. run-state is already persisted on every transition path
# above; flush once more so lib/goal-phase3.sh rehydrates the final PR set.
if ! uberdev_goal_write_run_state; then
  echo "goal: ERROR: run-state flush FAILED at unbounded drain boundary — halting (exit 1) rather than proceeding to Phase 3 on unpersisted state; bg solver agents left intact" >&2
  exit 1
fi
echo "goal: watch drained (no active agents, no merging PRs) -> proceed to Phase 3 [unbounded drain exit 0]" >&2
exit 0
