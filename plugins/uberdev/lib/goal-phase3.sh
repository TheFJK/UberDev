#!/usr/bin/env bash
# lib/goal-phase3.sh — /uberdev:goal Phase 3 (collect next queue), RFC 0015 §5.
#
# Candidates -> fingerprint repeat check -> overflow truncation -> terminal
# gates. All four used to be SEPARATE SKILL.md fences, i.e. four separate
# shells, and that is precisely why `new_candidates` had to be round-tripped
# through a `.candidates` sidecar to survive between them: the array died at
# every boundary, and when the sidecar write was skipped the terminal gate read
# an EMPTY candidate set and emitted goal_converged with open BLOCKER findings
# still pending. As ONE process the array simply stays in scope. The sidecar
# flushes are KEPT — they are what lets skills/goal-pipeline/workflow.js hand
# the surviving queue to the next cycle, and what makes a crash resumable.
#
# EXIT CONTRACT (consumed by skills/goal-pipeline/workflow.js):
#   0  — converged (goal_converged emitted).
#   42 — loop back: goal_cycle_completed emitted, candidates merged into the
#        rollover queue, `cycle` bumped, merge barrier re-seeded.
#   1  — halt: a circuit breaker fired (max_cycles, nonconvergence,
#        solver_failed, queue_empty_not_converged, gh_api_failed).
#   3  — run-state could not be rehydrated or persisted.
#
# CONTRACT
#   bash lib/goal-phase3.sh [--goal-id=<id>]

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
    *) echo "goal-phase3: unknown argument '$_arg'" >&2; exit 2 ;;
  esac
done
[ -n "$GOAL_ID_CLI" ] && export UBERDEV_GOAL_ID="$GOAL_ID_CLI"

# >>> region: rehydrate
# Fresh-process rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${UBERDEV_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${UBERDEV_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${UBERDEV_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 3" >&2; exit 3; }
uberdev_dispatch_resolve_env "${UBERDEV_RESOLVED_BACKEND:-}" || exit 1   # re-derive backend/env (idempotent, D8); not persisted
# <<< region: rehydrate

# ONE EXIT slot, two jobs. As a single process there is exactly one EXIT trap
# available for the whole phase, so it must BOTH clean up $findings_err AND emit
# the machine-readable decision line the workflow driver's relay returns.
# Deriving the decision from `$?` (rather than setting a variable at each exit
# site) keeps every gate below byte-identical to the reviewed fence text.
findings_err=""
new_candidates=()
# `queue` is populated by uberdev_goal_read_run_state above; declare it
# defensively so the ${#queue[@]} reads below stay set -u-safe if a future
# run-state shape ever omits the key. Re-declaring an already-set array here
# would DESTROY the rollover, so the guard tests for unset first.
if [ -z "${queue+x}" ]; then queue=(); fi
_goal_phase3_on_exit() {
  local rc="${1:-0}" decision queue_csv
  [ -n "${findings_err:-}" ] && rm -f "$findings_err"
  case "$rc" in
    0)  decision="converged" ;;
    42) decision="loop" ;;
    3)  decision="state_error" ;;
    *)  decision="halt" ;;
  esac
  # The surviving queue is reported as a CSV, not just a count: the driver's
  # projected-agent gate sizes the NEXT cycle from it, and a count alone would
  # make that gate guess. `${queue[*]:-}` keeps the read set -u-safe on an
  # empty array across every bash the project supports.
  queue_csv="$(IFS=','; printf '%s' "${queue[*]:-}")"
  printf '{"phase":"collect","goal_id":"%s","cycle":%s,"decision":"%s","rc":%s,"candidates":%s,"queued":%s,"queue":"%s"}\n' \
    "${GOAL_ID:-}" "${cycle:-0}" "$decision" "$rc" \
    "${#new_candidates[@]}" "${#queue[@]}" "$queue_csv"
}
trap '_goal_phase3_on_exit "$?"' EXIT

# >>> region: collect
# Snapshot goal start for the createdAt filter — only consider findings filed
# during THIS goal run, not pre-existing review-pr-finding issues that pre-date
# the cycle. The TZ-Z timestamp lines up with gh's ISO-8601 createdAt format.
goal_start_iso="$(date -u -r "$watch_start" +%FT%TZ 2>/dev/null \
  || date -u -d "@$watch_start" +%FT%TZ)"

# In-process gh query — mirror discover.sh:152-183 mktemp/EXIT-trap stderr
# isolation pattern (no shell-piped --template, never an external jq pipe).
#
# #301 — $findings_err is created HERE and removed by the single process-wide
# EXIT handler registered above (_goal_phase3_on_exit). In the fence era each
# phase was its own SHELL, so this block had to register its own trap or the
# file leaked one tempfile per cycle until the OS cleared TMPDIR. As one process
# there is exactly ONE EXIT slot for the whole phase, so a second `trap ... EXIT`
# here would SILENTLY REPLACE the decision emitter — hence the shared handler.
findings_err="$(mktemp)"

# Build the optional --only-mine filter via env-injected GH_USER (gh resolves
# .author.login via env passthrough; --jq receives `env.GH_USER` literal).
# F14 simplify-lens — the filter projects directly to `.number` per matching
# row (newline-separated raw integers) so the downstream mapfile no longer
# needs a redundant `jq -r '.[]'` pass to flatten a `map(.number)` JSON array.
#
# Identity requirement (issue #291 #2). `--only-mine` filters strictly on
# `.author.login`, so it assumes the agent that FILES the `review-pr-finding`
# issues runs under the SAME `gh` identity as this watcher (`gh api user`). On a
# solo, single-identity setup — the default, and the only setup it was designed
# for — that holds. If the filing agent authenticates as a DIFFERENT identity
# (a CI service token while the operator is a human login), its findings carry
# that other author, `--only-mine` drops them, new_candidates comes back empty,
# and the goal can converge with open BLOCKER/CRITICAL findings still pending —
# with no breaker firing, because the empty set is "correct" per the filter.
# `--only-mine` is therefore safe ONLY when both sides share one `gh` identity;
# multi-identity setups must OMIT it and rely on the label as the coarse filter.
# It is opt-in and OFF by default, so the default loop is never exposed.
if [ "$only_mine" = "1" ]; then
  # B6 — surface gh api user failures instead of silently dropping into an
  # empty $GH_USER. Previously `GH_USER="$(gh api user --jq '.login')"` would
  # let a 401/403/network-flake produce `GH_USER=""`, the jq filter then
  # `select(.author.login == env.GH_USER)` matched zero issues (no author has
  # an empty login), candidates_json was empty, and Phase 3's terminal check
  # emitted goal_converged falsely. Now: capture stderr + rc; if gh failed,
  # halt with goal_circuit_breaker reason=gh_api_failed (same shape as the
  # gh issue list rc-check below at lines ~451-456) so the operator can
  # re-run /goal once the underlying auth/network issue clears.
  GH_USER_ERR="$(mktemp)"
  GH_USER="$(gh api user --jq '.login' 2>"$GH_USER_ERR")"
  GH_USER_RC=$?
  [ -s "$GH_USER_ERR" ] && cat "$GH_USER_ERR" >&2
  rm -f "$GH_USER_ERR"
  if [ "$GH_USER_RC" -ne 0 ] || [ -z "$GH_USER" ]; then
    uberdev_goal_audit goal_circuit_breaker \
      "{\"reason\":\"gh_api_failed\",\"step\":\"phase3_gh_api_user\",\"exit_code\":$GH_USER_RC}"
    _uberdev_goal_reap_zombies || true
    print_summary "$cycle"
    exit 1
  fi
  export GH_USER
  jq_filter='.[] | select(.body | test("\\*\\*Tier:\\*\\* (BLOCKER|CRITICAL)")) | select(.createdAt > $start) | select(.author.login == env.GH_USER) | .number'
else
  jq_filter='.[] | select(.body | test("\\*\\*Tier:\\*\\* (BLOCKER|CRITICAL)")) | select(.createdAt > $start) | .number'
fi

candidates_json="$(gh issue list --label "$FINDING_LABEL" --state open \
  --json number,body,createdAt,author --limit 100 \
  --jq "$jq_filter" --arg start "$goal_start_iso" 2>"$findings_err")"
gh_rc=$?
[ -s "$findings_err" ] && cat "$findings_err" >&2

# B6 — Surface gh failures instead of treating empty output as convergence.
# Previously `$gh_rc` was discarded, so a rate-limit 403 or transient network
# error returned empty candidates_json → the Phase 3 terminal check then saw
# "new_candidates empty AND all PRs terminal" and emitted goal_converged
# falsely. Now: non-zero rc emits a goal_circuit_breaker with reason=gh_api_failed
# and exits 1 so the operator can re-run /goal after the underlying issue
# clears. The findings_err contents already went to stderr above.
if [ "$gh_rc" -ne 0 ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"gh_api_failed\",\"step\":\"phase3_issue_list\",\"exit_code\":$gh_rc}"
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi

# `candidates_json` is already newline-separated raw integers (one number per
# line) from the F14 filter shape above. Read each line into the array with a
# portable while-read loop — NOT `mapfile`, which is bash-4-only and aborts on
# macOS's default /bin/bash 3.2 (issue #180 defect #8); this mirrors the
# run-state rehydration loop in lib/goal-state.sh. Empty input yields a
# 0-element array, so the `${#new_candidates[@]}` checks downstream behave
# identically. Each line is numeric-gated (the candidates are raw integers from
# --jq; the gate drops any stray blank or non-integer line defensively).
new_candidates=()
while IFS= read -r _cand_line; do
  [ -n "$_cand_line" ] || continue
  case "$_cand_line" in ''|*[!0-9]*) continue ;; esac
  new_candidates+=("$_cand_line")
done < <(printf '%s' "$candidates_json")

# #301 (RFC 0012 §3.3 goal-R1 item 1) — flush new_candidates to the
# cycle-tagged .candidates sidecar at the END of this fence. new_candidates is
# built in THIS fresh shell and dies at the fence boundary; pre-#301
# write_run_state persisted queue/active/scalars but NOT candidates, so the
# downstream fingerprint + terminal fences rehydrated an EMPTY set and the
# terminal gate emitted goal_converged with open BLOCKER/CRITICAL findings
# still pending (the live false-converge BLOCKER). Fail LOUD on a flush
# failure — proceeding would reproduce exactly that false converge.
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state after Phase-3 candidate collection" >&2; exit 3; }
# <<< region: collect

# For each candidate, extract the fingerprint and check for repeat. In the fence
# era `new_candidates` was rehydrated here from the cycle-tagged `.candidates`
# sidecar; in one process it is simply still in scope.
# >>> region: fingerprint
for issue in "${new_candidates[@]}"; do
  # Issues don't go through _uberdev_goal_fetch_pr_body (PR-specific helper);
  # keep the inline gh issue view + 64KiB cap here. The cap shape is shared
  # with the helper (load-bearing ReDoS defence; R1 / T1).
  body="$(gh issue view "$issue" --json body --jq '.body' 2>/dev/null \
    | head -c "$_UBERDEV_GOAL_BODY_CAP")"
  fp="$(_uberdev_goal_extract_fingerprint "$body")"
  if ! uberdev_goal_check_fingerprint_repeat "$GOAL_ID" "$cycle" "$fp"; then
    # Same fingerprint seen in cycle N-1 → the cycle is generating the same
    # finding again. Halt non-convergence: re-running won't make it go away.
    uberdev_goal_audit goal_circuit_breaker \
      "{\"reason\":\"nonconvergence\",\"issue\":$issue,\"fingerprint\":\"$fp\"}"
    _uberdev_goal_reap_zombies || true
    print_summary "$cycle"
    exit 1
  fi
done
# <<< region: fingerprint

# Blocker-overflow handler (D13). Detection lives in lib/goal-watch.sh step 2b
# (the red trust-signal case) where $audit_json and $pr_num are in scope; it sets
# overflow_detected=1. The truncation is sequenced HERE — after the fingerprint
# repeat check and BEFORE the terminal gates (#301, RFC 0012 §3.3 goal-R1 item 2;
# it previously sat AFTER the loop-back, where the un-truncated set had already
# been merged into `queue`, making the truncation dead code).
#
# The overflow signal queues only the first 10 candidate issues for the next
# cycle (the upstream /review-pr agent already truncated its issue-file list at
# the same cap) and surfaces the count in the goal_cycle_completed summary. It
# **does NOT halt the entire goal**: `halted_due_to_overflow` is a per-PR
# cycle-management signal, not a goal-level circuit breaker. The PR was already
# moved to red-held by the watch loop (overflow is functionally identical to
# RED), and the goal may still converge once that PR's issues are resolved.
# >>> region: overflow
# overflow_detected is set in Phase 2b's red case when any PR's /review-pr
# audit JSON carried halted_due_to_overflow:true. Here in Phase 3 we apply
# the first-10 truncation (no PR transition — Phase 2b already did that).
if [ "${overflow_detected:-0}" = "1" ]; then
  new_candidates=("${new_candidates[@]:0:10}")
  # surfaced in cycle summary; goal continues — do NOT halt.
  # #301 — re-flush the TRUNCATED set to the .candidates sidecar: the
  # terminal/loop-back fence below is a fresh shell and rehydrates from disk;
  # without this flush it would merge the FULL un-truncated set into `queue`.
  uberdev_goal_write_run_state || { echo "goal: failed to persist run-state after overflow truncation" >&2; exit 3; }
fi
# <<< region: overflow

# Cycle terminal conditions, evaluated AFTER the per-candidate fingerprint check
# and the D13 truncation above. Every converge/halt gate is additionally guarded
# on the rollover `queue` being EMPTY (issue #288 #1): issues deferred past
# --max-parallel have no PR, so they are invisible to the PR-state calculus and
# must fall THROUGH to the loop-back rather than be mistaken for convergence.
# >>> region: terminal
failed_issue_count="$(uberdev_goal_count_failed_issues "$GOAL_ID")"
if [ "$failed_issue_count" -gt 0 ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"solver_failed\",\"cycle\":$cycle,\"failed_issues\":$failed_issue_count}"
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi
if [ "$cycle" -ge "$MAX_CYCLES" ] && [ "${#new_candidates[@]}" -gt 0 ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"max_cycles\",\"cycle\":$cycle,\"max\":$MAX_CYCLES,\"queued\":${#new_candidates[@]}}"
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi

# Terminal set for convergence (#160): hard-terminal {merged, merge-failed}
# plus pseudo-terminal {yellow-held, red-held}. Held PRs are surfaced via
# print_summary's `Blocks: #N` rows so the operator can intervene; for the
# convergence calculus they are treated as terminal so the goal exits
# cleanly when nothing else is in flight.
terminal_prs="$(uberdev_goal_list_prs_in_state "$GOAL_ID" merged \
  ; uberdev_goal_list_prs_in_state "$GOAL_ID" merge-failed \
  ; uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held \
  ; uberdev_goal_list_prs_in_state "$GOAL_ID" red-held)"
all_pr_count="$(uberdev_goal_count_distinct_prs "$GOAL_ID")"
terminal_count="$(printf '%s\n' "$terminal_prs" | grep -c . || true)"
# Issue #288 #1 (BLOCKER) — BOTH terminal gates below also require the rollover
# `queue` to be EMPTY. With more issues than --max-parallel, Phase 1 defers the
# overflow into `queue` (the remaining_queue flush at the top of this file).
# Those rolled-over issues have NOT been dispatched, have NO PR, and so do NOT
# appear in all_pr_count — so on a clean cycle `new_candidates` is empty AND
# terminal_count==all_pr_count even though work remains. Without the
# `${#queue[@]} -eq 0` clause the goal emits goal_converged (or halts
# queue_empty_not_converged) while the overflow stays OPEN and never dispatched.
# A non-empty queue must instead fall THROUGH both gates to the loop-back below,
# which re-enters Phase 1 and drains the remaining queue. (Distinct survivor of
# the v0.34.0 rollover-WIPE fix — the wipe was fixed; convergence-evaluates-
# first-and-ignores-the-queue was not.)
if [ "${#new_candidates[@]}" = "0" ] && [ "$terminal_count" = "$all_pr_count" ] && [ "${#queue[@]}" -eq 0 ]; then
  uberdev_goal_audit goal_converged \
    "{\"cycle\":$cycle,\"prs\":$all_pr_count}"
  print_summary "$cycle"
  uberdev_goal_cleanup_run_state || true   # #171 — reap run-state sidecars on terminal exit
  exit 0
fi

# Deterministic queue-empty-not-converged halt (#160). Without this, a PR
# stuck in dispatched/pushed-reviewing/green/merging with nothing left to
# file as a finding would spin the Phase1→2→3 loop until stuck_loop fires (4h).
# Surface the stuck state immediately so the operator can act. The
# `${#queue[@]} -eq 0` clause (issue #288 #1) keeps a non-empty rollover queue
# from being mis-read as "drained but stuck" — overflow issues still pending
# dispatch are NOT a stuck PR; they must loop back into Phase 1, not halt here.
if [ "${#new_candidates[@]}" = "0" ] && [ "${#queue[@]}" -eq 0 ] && [ "$terminal_count" != "$all_pr_count" ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"queue_empty_not_converged\",\"cycle\":$cycle,\"all_prs\":$all_pr_count,\"terminal\":$terminal_count}"
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi

_rolled_over=${#queue[@]}             # Phase-1 carry-over count BEFORE merge (issue #220, AC ❹)
uberdev_goal_audit goal_cycle_completed \
  "{\"cycle\":$cycle,\"new_candidates\":${#new_candidates[@]},\"overflow_count\":${overflow_count:-0},\"rolled_over\":$_rolled_over}"
queue=("${queue[@]}" "${new_candidates[@]}")
cycle=$(( cycle + 1 ))
# #301 — candidates are now CONSUMED into `queue`; clear before the loop-back
# flush so the .candidates sidecar written below is EMPTY under the new cycle
# tag. Without this, the flush would re-tag the already-merged set with cycle
# N+1, and a crashed/skipped fence 1 next cycle would rehydrate it into the
# terminal gates and merge the same candidates into `queue` a second time.
new_candidates=()
# Q4 — reset per-cycle accumulators before looping to Phase 1 (overflow_count
# is per-cycle; overflow_detected gates the per-cycle truncation above).
overflow_count=0
overflow_detected=0
# Issue #288 #3 (MAJOR) — re-seed the merge-barrier clock PER CYCLE. barrier_start_ts
# is seeded once by uberdev_goal_register_batch_pr on the FIRST batch registration
# (gated on an empty batch-prs.tsv) and is otherwise never reset; the TSV is only
# truncated at Phase-0 state_init. So without this reset cycle N's barrier budget
# would be `BARRIER_TIMEOUT_S − Σ(prior cycle durations)` → a spurious
# `stuck_loop phase=merge_barrier` on a healthy late cycle. Reset BOTH:
#   (1) barrier_start_ts=0 — the next write_run_state below flushes the `=0`
#       placeholder, which does NOT match register_batch_pr's
#       `^barrier_start_ts=[1-9][0-9]*$` re-seed guard, so next cycle's first
#       registration re-seeds it to a fresh epoch; and
#   (2) truncate goal-<id>-batch-prs.tsv — so register_batch_pr's `[ ! -s "$tsv" ]`
#       first-registration check is TRUE again next cycle (the seed only fires on
#       first registration). Truncate is best-effort: a write failure must not
#       abort the loop-back, but emit a breadcrumb so a stale registry is visible.
barrier_start_ts=0
_batch_prs_tsv="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}/goal-$GOAL_ID-batch-prs.tsv"
if ! : > "$_batch_prs_tsv"; then
  printf 'goal: WARN could not truncate batch-prs.tsv (%s) at cycle loop-back — barrier clock may not re-seed\n' "$_batch_prs_tsv" >&2
fi
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state before loop-back" >&2; exit 3; }
# loop back to Phase 1
# <<< region: terminal

# Loop-back. In the fence era the comment above was the whole story — the
# orchestrating model was trusted to re-run Phase 1. Exit 42 makes it a
# CONTRACT the driver in skills/goal-pipeline/workflow.js checks, which is what
# turns "the model forgot to loop" from a silent false-converge into a visible
# state.
exit 42
