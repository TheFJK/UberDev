#!/opt/homebrew/bin/bash
# ===========================================================================
# Corrected /uberdev:goal autonomous convergence driver  (claude CLI 2.1.150)
# ---------------------------------------------------------------------------
# The stock goal-pipeline watcher keys completion/PR/merge off the captured
# solve-bg stdout log, which is broken on claude 2.1.150 (`claude --bg`
# detaches; `pushed PR #N` never printed; merge-bg-stdout never written).
# This driver replaces those with version-independent signals:
#   * completion / PR discovery : gh closingIssuesReferences (Closes #N) + feat/N- head
#   * trust signal              : file-based review-pr-verdict.json (already robust)
#   * merge result             : gh pr view --json state == MERGED (authoritative)
# Reuses plugin helpers: uberdev_dispatch_one, uberdev_goal_locate_review_pr_audit_by_pr,
# uberdev_goal_read_trust_signal, _uberdev_goal_extract_fingerprint.
# RFC-0005 semantics preserved: cycles, GREEN auto-merge, YELLOW/RED held,
# BLOCKER/CRITICAL recursion, circuit breakers — plus a rolling concurrency cap.
# ===========================================================================
set -uo pipefail
(( ${BASH_VERSINFO[0]:-0} >= 4 )) || { echo "FATAL: needs bash >= 4 (macOS /bin/bash is 3.2). brew install bash; run with /opt/homebrew/bin/bash" >&2; exit 2; }

# Portable: auto-detect the repo root + the newest installed uberdev plugin.
REPO="${GOAL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="${UBERDEV_ROOT:-$(ls -d "$HOME"/.claude/plugins/cache/uberdev/uberdev/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*$::')}"
[ -n "$ROOT" ] && [ -r "$ROOT/lib/goal-state.sh" ] || { echo "FATAL: cannot locate uberdev plugin (set UBERDEV_ROOT)" >&2; exit 2; }
cd "$REPO" || { echo "FATAL: cannot cd $REPO" >&2; exit 9; }
export CLAUDE_PLUGIN_ROOT="$ROOT"
export UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
# shellcheck source=/dev/null
. "$ROOT/lib/config-read.sh"
. "$ROOT/lib/dispatch.sh"
. "$ROOT/lib/goal-state.sh"

# ---- tunables (env-overridable) -------------------------------------------
ISSUES=( "$@" )
MAX_CYCLES="${GOAL_MAX_CYCLES:-5}"
CONCURRENCY="${GOAL_CONCURRENCY:-3}"          # max issues solving at once (rolling)
POLL_SECS="${GOAL_POLL_SECS:-90}"
STUCK_SECS="${GOAL_STUCK_SECS:-14400}"        # 4h global wall-clock cap
AUTO_MERGE="${GOAL_AUTO_MERGE:-1}"            # 1=merge GREEN; 0=hold green for human
BACKEND="${GOAL_BACKEND:-claude-bg}"
SOLVE_TIMEOUT="${GOAL_SOLVE_TIMEOUT:-9000}"   # 150m: no PR & no live agent => failed
MERGE_TIMEOUT="${GOAL_MERGE_TIMEOUT:-3600}"   # 60m merge agent w/o MERGED => retry/fail
MAX_MERGE_ATTEMPTS="${GOAL_MAX_MERGE_ATTEMPTS:-3}"
MAX_REVIEW_ATTEMPTS="${GOAL_MAX_REVIEW_ATTEMPTS:-3}"
REVIEW_GRACE="${GOAL_REVIEW_GRACE:-1800}"     # wait this long for the leaf's OWN /review-pr (≈20m) before dispatching ours
USAGE_BACKOFF="${GOAL_USAGE_BACKOFF:-900}"    # when a review hits the Claude usage cap, wait this long before a fresh retry
USAGE_MAX_BACKOFF="${GOAL_USAGE_MAX_BACKOFF:-10800}"  # give up (red-held) only after this much total quota-wait per PR

GOAL_ID="goal-$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
export UBERDEV_GOAL_ID="$GOAL_ID"
AUDIT="$UBERDEV_TMPDIR/$GOAL_ID.jsonl"
: > "$AUDIT"

log(){ printf '%s [goal] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
audit(){ printf '{"ts":"%s","event":"%s","data":%s}\n' "$(date -u +%FT%TZ)" "$1" "${2:-null}" >> "$AUDIT"; }

# ---- in-memory state (single long-lived process) --------------------------
declare -A IST      # issue -> solving|pr-pushed|resolved|failed   (unset = pending/input)
declare -A IPR      # issue -> pr
declare -A IDT      # issue -> dispatch epoch
declare -A PST      # pr -> pushed-reviewing|green|yellow-held|red-held|merging|merged|merge-failed
declare -A PISS     # pr -> issue
declare -A PMT      # pr -> merge dispatch epoch
declare -A PMA      # pr -> merge attempts
declare -A PRA      # pr -> our review-pr re-dispatch attempts
declare -A PR_SEEN  # pr -> epoch of last review-grace reset (first-seen, then each own /review-pr dispatch)
declare -A RVS      # pr -> session id of our last dispatched /review-pr (for usage-limit inspection)
declare -A RVS_T    # pr -> epoch of our last /review-pr dispatch
declare -A RVS_WAIT # pr -> accumulated quota-wait seconds (usage-limit backoff)
declare -A SEEN_FP  # fingerprint -> cycle (nonconvergence detector)
ALL_ISSUES=()       # every issue ever queued (for summary)

# ---- detection helpers (version-independent) ------------------------------
find_pr_for_issue(){                       # echo highest PR # closing issue $1
  local n="$1"; [[ "$n" =~ ^[0-9]+$ ]] || return 0
  gh pr list --state all --limit 200 --json number,closingIssuesReferences,headRefName \
    --jq "[.[] | select((.closingIssuesReferences[]?.number == ${n}) or (.headRefName|test(\"^feat/${n}-\"))) | .number] | max // empty" 2>/dev/null
}
agent_busy_for_issue(){                     # rc0 if a live agent session cwd ~ solve-issue-$1
  claude agents --json 2>/dev/null | python3 -c '
import sys,json
n=sys.argv[1]
try: arr=json.load(sys.stdin)
except Exception: sys.exit(1)
for s in arr:
    cwd=(s.get("cwd","") or "").rstrip("/")
    if cwd.endswith("solve-issue-"+n) and s.get("status") in ("busy","running","starting","working"): sys.exit(0)
sys.exit(1)' "$1"
}
pr_state_gh(){ gh pr view "$1" --json state --jq .state 2>/dev/null; }
pr_is_merged(){ [ "$(pr_state_gh "$1")" = "MERGED" ]; }
trust_of_pr(){ local v; v="$(uberdev_goal_locate_review_pr_audit_by_pr "$1" 2>/dev/null)"; \
               [ -n "$v" ] && uberdev_goal_read_trust_signal "$v" 2>/dev/null || echo missing; }

# Claude usage/session-limit detection via the session's own log (NOT a verdict
# file). A dispatched agent that hits the Max cap prints "You've hit your session
# limit · resets <time>" and does 0s of work -> no verdict. We must treat that as
# a transient quota stall (back off + retry fresh), NOT as "review failed -> red".
session_limited(){   # rc0 if session $1's log shows a Claude usage/session-limit stall
  local sid="$1"
  [ -n "$sid" ] || return 1
  # grep -a treats the ANSI/PTY-framed `claude logs` output as text; the limit
  # phrase renders as contiguous plain text ("...hit your session limit · resets
  # 8:30pm...") so no ANSI stripping is needed (BSD sed chokes on that anyway).
  timeout 25 claude logs "$sid" 2>/dev/null \
    | grep -qa -iE "hit your (session|usage) limit|usage limit|/usage-credits|approaching your .*limit"
}

dispatch_cmd(){                             # $1=key(issue/pr) $2=slash-command-line
  local key="$1" cmdline="$2" pf rc
  pf="$(mktemp)"; printf '%s\n' "$cmdline" > "$pf"
  UBERDEV_GOAL_ID="$GOAL_ID" uberdev_dispatch_one "$key" small "$pf"; rc=$?
  rm -f "$pf"; return $rc
}

# Rolling dispatch: keep up to CONCURRENCY issues in 'solving'; resume/adopt
# issues that already have a PR or a live agent. Called every watch iteration.
dispatch_pending(){
  local n pr solving_count=0
  for n in "${queue[@]}"; do [ "${IST[$n]:-}" = "solving" ] && solving_count=$((solving_count+1)); done
  for n in "${queue[@]}"; do
    case "${IST[$n]:-input}" in solving|pr-pushed|resolved|failed) continue;; esac
    pr="$(find_pr_for_issue "$n")"
    if [ -n "$pr" ]; then
      if pr_is_merged "$pr"; then log "issue #$n PR #$pr already MERGED (resume)"; IST[$n]=resolved; IPR[$n]="$pr"; PISS[$pr]="$n"; PST[$pr]=merged; continue; fi
      # GOAL_SKIP_LEAF_GRACE=1: this is a recovery resume where the leaf's own
      # /review-pr already ran (or died on the usage cap), so don't waste the
      # leaf-grace window — backdate PR_SEEN so our review dispatches promptly.
      # (The grace still applies AFTER our dispatch, to wait for ITS verdict.)
      local _seen; _seen="$(date +%s)"; [ "${GOAL_SKIP_LEAF_GRACE:-0}" = "1" ] && _seen=$(( _seen - REVIEW_GRACE - 5 ))
      log "issue #$n already has PR #$pr (resume)"; IST[$n]=pr-pushed; IPR[$n]="$pr"; PISS[$pr]="$n"; PST[$pr]="${PST[$pr]:-pushed-reviewing}"; PR_SEEN[$pr]="${PR_SEEN[$pr]:-$_seen}"; continue
    fi
    if agent_busy_for_issue "$n"; then
      log "issue #$n live agent — adopt"; IST[$n]=solving; IDT[$n]="$(date +%s)"; solving_count=$((solving_count+1)); audit goal_issue_adopted "{\"issue\":$n}"; continue
    fi
    (( solving_count >= CONCURRENCY )) && continue
    if dispatch_cmd "$n" "/uberdev:turbo $n --turbo --backend=$UBERDEV_RESOLVED_BACKEND"; then
      IST[$n]=solving; IDT[$n]="$(date +%s)"; solving_count=$((solving_count+1))
      log "dispatched issue #$n (session ${DISPATCH_ID:-?}) [solving $solving_count/$CONCURRENCY]"
      audit goal_issue_dispatched "{\"issue\":$n,\"session\":\"${DISPATCH_ID:-}\"}"
    else log "WARN dispatch failed issue #$n (rc=$?)"; fi
  done
}

summary(){
  local merged=0 held=0 failed=0 pr n
  for pr in "${!PST[@]}"; do case "${PST[$pr]}" in
    merged) merged=$((merged+1));; yellow-held|red-held) held=$((held+1));; merge-failed) failed=$((failed+1));; esac
  done
  log "================ SUMMARY ================"
  log "goal=$GOAL_ID cycles=$cycle/$MAX_CYCLES wall=$(( $(date +%s)-watch_start ))s"
  log "PRs: merged=$merged held=$held merge-failed=$failed"
  for pr in "${!PST[@]}"; do log "  PR #$pr  issue=#${PISS[$pr]:-?}  state=${PST[$pr]}  gh=$(pr_state_gh "$pr")"; done
  for n in "${ALL_ISSUES[@]}"; do log "  issue #$n  state=${IST[$n]:-pending}  pr=${IPR[$n]:-none}"; done
  log "audit: $AUDIT"
  log "========================================"
}

# ===========================================================================
# Phase 0 — preflight
# ===========================================================================
UBERDEV_DISPATCH_BACKEND_REQUESTED="$BACKEND" uberdev_dispatch_preflight \
  || { log "FATAL preflight failed"; exit 1; }
export AUTO_MODE=1
uberdev_dispatch_resolve_env || { log "FATAL resolve_env failed (no timeout(1)?)"; exit 1; }
log "START goal=$GOAL_ID issues=[${ISSUES[*]}] backend=$UBERDEV_RESOLVED_BACKEND auto_merge=$AUTO_MERGE concurrency=$CONCURRENCY max_cycles=$MAX_CYCLES"
audit goal_dispatched "{\"issues\":\"${ISSUES[*]}\",\"backend\":\"$UBERDEV_RESOLVED_BACKEND\",\"auto_merge\":$AUTO_MERGE,\"concurrency\":$CONCURRENCY}"

watch_start="$(date +%s)"
cycle=1
queue=( "${ISSUES[@]}" )
for n in "${queue[@]}"; do ALL_ISSUES+=("$n"); done

# ===========================================================================
# main convergence loop
# ===========================================================================
while true; do
  log "=========== CYCLE $cycle  queue=[${queue[*]}] ==========="

  # ---------- Phase 1+2: paced dispatch + watch ----------
  while true; do
    now="$(date +%s)"
    if (( now - watch_start >= STUCK_SECS )); then
      log "CIRCUIT BREAKER stuck_loop ($((now-watch_start))s)"
      audit goal_circuit_breaker '{"reason":"stuck_loop"}'; summary; exit 1
    fi

    dispatch_pending          # rolling dispatch (respects CONCURRENCY cap)
    any_active=0

    # pending issues (queued, not yet dispatched due to cap) keep the loop alive
    for n in "${queue[@]}"; do [ "${IST[$n]:-input}" = "input" ] && any_active=1; done

    # 2a solving -> PR appeared?
    for n in "${queue[@]}"; do
      [ "${IST[$n]:-}" = "solving" ] || continue
      pr="$(find_pr_for_issue "$n")"
      if [ -n "$pr" ]; then
        log "issue #$n -> PR #$pr"
        IST[$n]=pr-pushed; IPR[$n]="$pr"; PISS[$pr]="$n"; PST[$pr]=pushed-reviewing; PR_SEEN[$pr]="$now"
        audit goal_pr_pushed "{\"issue\":$n,\"pr\":$pr}"
      elif agent_busy_for_issue "$n"; then any_active=1
      elif (( now - ${IDT[$n]:-now} < SOLVE_TIMEOUT )); then any_active=1
      else
        log "issue #$n FAILED (no PR, agent idle, $((now-${IDT[$n]:-now}))s elapsed)"
        IST[$n]=failed; audit goal_issue_failed "{\"issue\":$n}"
      fi
    done

    # 2b read verdict for pushed-reviewing; ALSO re-read held PRs so a verdict
    # that lands AFTER we held (e.g. the leaf's own ~20m /review-pr) is recovered.
    # We do NOT use agent_busy to decide review-readiness (it's unreliable: the
    # solver often goes idle right after pushing the PR while finish-branch's own
    # /review-pr runs separately). Instead we WAIT REVIEW_GRACE for the leaf's
    # verdict, only dispatching our own review after the grace lapses (bounded).
    for pr in "${!PST[@]}"; do
      st="${PST[$pr]}"
      case "$st" in pushed-reviewing|yellow-held|red-held) ;; *) continue;; esac
      sig="$(trust_of_pr "$pr")"
      case "$sig" in
        green)  [ "$st" = green ]       || { log "PR #$pr GREEN (was $st)";  PST[$pr]=green;       audit goal_pr_green "{\"pr\":$pr}"; } ;;
        yellow) [ "$st" = yellow-held ] || { log "PR #$pr YELLOW -> held";   PST[$pr]=yellow-held; audit goal_pr_held "{\"pr\":$pr,\"sig\":\"yellow\"}"; } ;;
        red)    [ "$st" = red-held ]    || { log "PR #$pr RED -> held";      PST[$pr]=red-held;    audit goal_pr_held "{\"pr\":$pr,\"sig\":\"red\"}"; } ;;
        stale|missing)
          # Only pushed-reviewing PRs may trigger our own /review-pr, and only
          # after REVIEW_GRACE without a verdict. Held PRs with a missing verdict
          # are left as-is (re-read next iteration once it appears).
          if [ "$st" = "pushed-reviewing" ]; then
            # Usage-cap aware: if OUR last review session for this PR hit the Claude
            # usage limit, it did ~0s of real work -> do NOT burn a red-hold attempt.
            # Back off USAGE_BACKOFF then re-dispatch a FRESH review (the old session
            # logs the cap forever, so a new session is the only way forward once
            # quota returns). Red-hold only after USAGE_MAX_BACKOFF total quota-wait.
            if [ -n "${RVS[$pr]:-}" ] && session_limited "${RVS[$pr]}"; then
              waited="${RVS_WAIT[$pr]:-0}"
              if (( waited >= USAGE_MAX_BACKOFF )); then
                log "PR #$pr review usage-capped ${waited}s (> max) -> red-held (quota exhausted)"
                PST[$pr]=red-held; audit goal_pr_held "{\"pr\":$pr,\"sig\":\"usage_exhausted\"}"
              elif (( now - ${RVS_T[$pr]:-0} >= USAGE_BACKOFF )); then
                log "PR #$pr review hit Claude usage cap (session ${RVS[$pr]}); backoff elapsed -> re-dispatch FRESH /review-pr (no attempt burned; total wait ${waited}s)"
                if dispatch_cmd "$pr" "/uberdev:review-pr $pr"; then RVS_WAIT[$pr]=$(( waited + now - ${RVS_T[$pr]:-now} )); RVS[$pr]="$DISPATCH_ID"; RVS_T[$pr]="$now"; PR_SEEN[$pr]="$now"; fi
                any_active=1
              else
                any_active=1   # within the quota-backoff window; wait
              fi
            else
              seen="${PR_SEEN[$pr]:-$now}"
              if (( now - seen < REVIEW_GRACE )); then any_active=1     # still waiting for the leaf's own review
              else
                att="${PRA[$pr]:-0}"
                if (( att < MAX_REVIEW_ATTEMPTS )); then
                  log "PR #$pr no verdict after ${REVIEW_GRACE}s grace -> dispatch /review-pr (attempt $((att+1)))"
                  if dispatch_cmd "$pr" "/uberdev:review-pr $pr"; then PRA[$pr]=$((att+1)); PR_SEEN[$pr]="$now"; RVS[$pr]="$DISPATCH_ID"; RVS_T[$pr]="$now"; fi; any_active=1
                else
                  log "PR #$pr no verdict after $att reviews + grace -> red-held (safe; not merged)"
                  PST[$pr]=red-held; audit goal_pr_held "{\"pr\":$pr,\"sig\":\"no_verdict\"}"
                fi
              fi
            fi
          fi;;
      esac
    done

    # 2c green -> merge (auto-merge mode only)
    if [ "$AUTO_MERGE" = "1" ]; then
      for pr in "${!PST[@]}"; do
        [ "${PST[$pr]}" = "green" ] || continue
        att="${PMA[$pr]:-0}"
        if (( att >= MAX_MERGE_ATTEMPTS )); then
          log "CIRCUIT BREAKER merge_failed PR #$pr (max attempts $att)"
          PST[$pr]=merge-failed; audit goal_circuit_breaker "{\"reason\":\"merge_failed\",\"pr\":$pr,\"detail\":\"max_attempts\"}"; summary; exit 1
        fi
        log "PR #$pr GREEN -> dispatch /merge (attempt $((att+1)))"
        if dispatch_cmd "$pr" "/uberdev:merge $pr"; then
          PST[$pr]=merging; PMT[$pr]="$(date +%s)"; PMA[$pr]=$((att+1)); audit goal_merge_dispatched "{\"pr\":$pr}"
        else log "WARN merge dispatch failed PR #$pr — retry next iter"; fi
        any_active=1
      done
    fi

    # 2d merging -> merged?
    for pr in "${!PST[@]}"; do
      [ "${PST[$pr]}" = "merging" ] || continue
      if pr_is_merged "$pr"; then
        log "PR #$pr MERGED ✓"; PST[$pr]=merged
        [ -n "${PISS[$pr]:-}" ] && IST[${PISS[$pr]}]=resolved
        audit goal_pr_merged "{\"pr\":$pr}"
      else
        ghst="$(pr_state_gh "$pr")"
        if [ "$ghst" = "CLOSED" ]; then
          log "CIRCUIT BREAKER merge_failed PR #$pr (closed w/o merge)"
          PST[$pr]=merge-failed; audit goal_circuit_breaker "{\"reason\":\"merge_failed\",\"pr\":$pr,\"detail\":\"closed\"}"; summary; exit 1
        fi
        if (( now - ${PMT[$pr]:-now} >= MERGE_TIMEOUT )) && ! agent_busy_for_issue "$pr"; then
          log "PR #$pr merge stalled (agent idle, not merged) -> back to green for retry"; PST[$pr]=green
        fi
        any_active=1
      fi
    done

    # 2e intra-cycle termination
    merging_left=0; for pr in "${!PST[@]}"; do [ "${PST[$pr]}" = "merging" ] && merging_left=1; done
    [ "$any_active" = "0" ] && [ "$merging_left" = "0" ] && break
    sleep "$POLL_SECS"
  done

  # ---------- Phase 3: collect next queue (BLOCKER/CRITICAL findings) ----------
  goal_start_iso="$(date -u -r "$watch_start" +%FT%TZ 2>/dev/null || date -u -d "@$watch_start" +%FT%TZ)"
  mapfile -t cands < <(gh issue list --label review-pr-finding --state open --limit 100 \
      --json number,body,createdAt \
      --jq "[.[] | select(.createdAt > \"$goal_start_iso\") | select(.body|test(\"BLOCKER|CRITICAL\")) | .number] | .[]" 2>/dev/null)

  next=()
  for iss in "${cands[@]:-}"; do
    [ -n "$iss" ] || continue
    body="$(gh issue view "$iss" --json body --jq .body 2>/dev/null | head -c 65536)"
    fp="$(_uberdev_goal_extract_fingerprint "$body" 2>/dev/null)"
    if [ -n "$fp" ] && [ -n "${SEEN_FP[$fp]:-}" ]; then
      log "CIRCUIT BREAKER nonconvergence (fingerprint $fp repeats; issue #$iss)"
      audit goal_circuit_breaker "{\"reason\":\"nonconvergence\",\"issue\":$iss}"; summary; exit 1
    fi
    [ -n "$fp" ] && SEEN_FP[$fp]=$cycle
    next+=("$iss"); ALL_ISSUES+=("$iss")
  done

  # NOTE: held-PR recovery is handled inline in Phase 2b — verdicts are re-read
  # every iteration, so a held PR whose verdict later turns GREEN is promoted and
  # merged. Genuinely RED/YELLOW PRs stay held (never auto-merged); their
  # BLOCKER/CRITICAL findings recurse below as fresh issues.

  # terminal accounting
  nonterminal=0
  for pr in "${!PST[@]}"; do case "${PST[$pr]}" in
    merged|merge-failed|yellow-held|red-held) ;;
    green) [ "$AUTO_MERGE" = "1" ] && nonterminal=1 ;;
    *) nonterminal=1 ;; esac
  done
  for n in "${ALL_ISSUES[@]}"; do case "${IST[$n]:-pending}" in resolved|failed|pr-pushed) ;; *) nonterminal=1 ;; esac; done

  reviewing=0; for pr in "${!PST[@]}"; do [ "${PST[$pr]}" = "pushed-reviewing" ] && reviewing=1; done

  if [ "${#next[@]}" -eq 0 ] && [ "$nonterminal" -eq 0 ] && [ "$reviewing" -eq 0 ]; then
    log "CONVERGED ✓"; audit goal_converged "{\"cycle\":$cycle}"; summary; exit 0
  fi
  if [ "${#next[@]}" -eq 0 ] && [ "$nonterminal" -ne 0 ] && [ "$reviewing" -eq 0 ]; then
    log "CIRCUIT BREAKER queue_empty_not_converged"
    audit goal_circuit_breaker '{"reason":"queue_empty_not_converged"}'; summary; exit 1
  fi
  if (( cycle >= MAX_CYCLES )) && { [ "${#next[@]}" -gt 0 ] || [ "$nonterminal" -ne 0 ]; }; then
    log "CIRCUIT BREAKER max_cycles (queued ${#next[@]})"
    audit goal_circuit_breaker "{\"reason\":\"max_cycles\",\"queued\":${#next[@]}}"; summary; exit 1
  fi

  log "cycle $cycle complete; next queue=[${next[*]:-}] (+ held re-reviews)"
  audit goal_cycle_completed "{\"cycle\":$cycle,\"new\":${#next[@]}}"
  # carry forward any held PRs being re-reviewed by keeping them out of queue (state-tracked)
  queue=( "${next[@]:-}" )
  cycle=$((cycle+1))
done
