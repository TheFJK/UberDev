---
name: goal-pipeline
description: "Autonomous convergence pipeline for /uberdev:goal. Drives cycle algorithm (RFC 0005 §3.3) and PR/issue state machines. Inherits backend dispatch from solve-pipeline."
---

# Goal Pipeline (autonomous convergence body for /uberdev:goal)

This skill is invoked inline by `commands/goal.md`. It reads `$ARGUMENTS` from the caller's shell scope and drives a **5-phase cycle pipeline** — Phase 0 Preflight → Phase 1 Dispatch → Phase 2 Watch → Phase 3 Collect Next Queue → Phase 4 Converge/Halt — until the goal converges, max-cycles fires, fingerprint repeats (non-convergence), wall-clock exceeds 4h (stuck-loop), or a `/merge` halts on conflict/hook (merge-failed).

`/goal` is the autonomous convergence orchestrator from RFC 0005: it loops `/turbo` → auto `/review-pr` → `/merge` if GREEN, recursing on BLOCKER/CRITICAL `review-pr-finding` issues filed by `/review-pr` Phase 2.5 until the queue is empty AND every PR landed in `{merged, merge-failed}`. YELLOW PRs are NEVER merged inside `/goal` — they are held for re-review. RED PRs are held with a `Blocks: #N` body annotation that wires unblock back into the cycle once the blocking issues close.

> **You are an orchestrator, not an implementer.** You preflight, dispatch `/turbo` agents one per issue, watch their stdout transcripts for the `backgrounded · ` marker, drive PR state transitions from the `/review-pr` Phase 2.5 audit JSON, dispatch `/merge` for GREEN PRs, drive unblock checks on every successful merge, collect the next queue from `review-pr-finding` issues filed during the cycle, and halt deterministically via one of the five exit paths. You never write feature code yourself.

## Constants

All audit-event names, state-machine enums, regex shapes, and tunable thresholds are declared here once. Later phases reference these names by symbol; values are NOT re-inlined.

```
GOAL_AUDIT_EVENT_ENUM='goal_dispatched|goal_pr_transition|goal_unblock_triggered|goal_cycle_completed|goal_converged|goal_circuit_breaker'
GOAL_CIRCUIT_BREAKER_REASONS='max_cycles|nonconvergence|stuck_loop|merge_failed|gh_api_failed|unknown_merge_result|queue_empty_not_converged'
GOAL_PR_STATE_ENUM='dispatched|pushed-reviewing|green|yellow-held|red-held|merging|merged|merge-failed'
GOAL_ISSUE_STATE_ENUM='input|solving|pr-pushed|resolved|failed'
TRUST_SIGNAL_ENUM='green|yellow|red|stale|missing'
GOAL_MERGE_RESULT_ENUM='success|conflict|hook_failed|missing'
_UBERDEV_GOAL_DEFAULT_MAX_CYCLES=5
_UBERDEV_GOAL_POLL_SECS=60
_UBERDEV_GOAL_STUCK_SECS=14400         # 4h
_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3
_UBERDEV_GOAL_BODY_CAP=65536           # 64 KiB
FINDING_LABEL='review-pr-finding'
FINDING_FINGERPRINT_REGEX='<!-- uberdev:review-pr-finding fingerprint=([a-f0-9]{16}) -->'
BLOCKS_LINE_REGEX='^Blocks: #([0-9]+)$'
```

Notes on the enums:

- **`GOAL_AUDIT_EVENT_ENUM`** — the 6 events `lib/goal-state.sh::uberdev_goal_audit` accepts. Any other event name returns non-zero from the helper and is dropped on the floor; consumers grep these literals.
- **`GOAL_CIRCUIT_BREAKER_REASONS`** — the 7 halt reasons emitted by Phase 2/3/4 inside the `goal_circuit_breaker` payload's `.reason` field. The four original reasons (`max_cycles`, `nonconvergence`, `stuck_loop`, `merge_failed`); two surfaced-failure reasons added during post-impl-review (`gh_api_failed` — Phase 3 `gh issue list` rc!=0 instead of falsely treating an empty candidates list as convergence; `unknown_merge_result` — Phase 2c case default arm for a `uberdev_goal_read_merge_result` value outside the documented `success|conflict|hook_failed|missing` set); and `queue_empty_not_converged` — Phase 3 deterministic halt when the candidate queue is empty but at least one PR is still in a non-terminal state (issue #160; deterministic alternative to the 4h `stuck_loop` wall-clock fallback). The set is closed; new reasons require an RFC amendment.
- **`GOAL_PR_STATE_ENUM`** — the 8 states the PR machine in `_uberdev_goal_pr_state_machine_valid` recognises. `merged` and `merge-failed` are hard terminal (no further transitions); `yellow-held` and `red-held` are pseudo-terminal for convergence (Phase 3 counts them as terminal so the goal can converge cleanly with held PRs remaining, but the held-PR re-review poll loop in Phase 2 step 2e can still arc them to `green` once a re-review clears the findings, or cross-classify between `yellow-held`/`red-held` if a re-review's trust signal severity changed). `yellow-held → merging` and `red-held → merging` are hard-forbidden (D17 — never merge YELLOW/RED inside `/goal`).
- **`GOAL_ISSUE_STATE_ENUM`** — the 5 states the issue machine recognises; `pr-pushed → resolved` and the two `→ failed` transitions are the only sinks.
- **`TRUST_SIGNAL_ENUM`** — the 5 values `uberdev_goal_read_trust_signal` returns. `stale` (phase2_5 missing in audit JSON) and `missing` (audit JSON absent) both trigger `_uberdev_goal_dispatch_review_pr` rather than an assumed GREEN (D17).
- **`GOAL_MERGE_RESULT_ENUM`** — the 4 values `uberdev_goal_read_merge_result` returns. Maps the merge-pipeline's audit-row events (`merge_executed` for `success`, `pr_parked` with `data.reason ∈ {refused, ambiguous, push-non-ff}` for `conflict`, `pr_parked` with `data.reason == test-fail-exhausted` for `hook_failed`) plus a sentinel `missing` for "no audit row appended yet". Phase 2c's case statement handles each value explicitly; the `*)` default arm emits `goal_circuit_breaker reason=unknown_merge_result` (B7 — defensive guard against future enum drift).
- **`BLOCKS_LINE_REGEX`** is the anchored ReDoS-safe shape (D9 + T1) used by `_uberdev_goal_parse_blocks_line` in `lib/goal-state.sh`. The Phase 3 prose and the Unblock rule both reference this constant by name; the literal `^Blocks: #([0-9]+)$` appears here once.
- **`FINDING_FINGERPRINT_REGEX`** is the marker shape `agents/findings-to-issues.md` injects into every BLOCKER/CRITICAL `review-pr-finding` issue body; Phase 3 extracts it via `_uberdev_goal_extract_fingerprint` to drive the repeat-cycle detector.

## Phase 0 — Preflight

1. **Parse positional issue numbers + flags.** The parser scans `$ARGUMENTS` and collects every token matching `^[0-9]+$` into the input queue; recognised flag tokens are `--max-cycles=N`, `--only-mine`, `--dry-run`, `--backend=<name>`. Empty input prints the usage line and exits.

   ```bash
   queue=()
   max_cycles_cli=""
   only_mine=0
   dry_run=0
   backend_cli=""
   for tok in $ARGUMENTS; do
     case "$tok" in
       --max-cycles=*) max_cycles_cli="${tok#--max-cycles=}" ;;
       --only-mine)    only_mine=1 ;;
       --dry-run)      dry_run=1 ;;
       --backend=*)    backend_cli="${tok#--backend=}" ;;
       *) [[ "$tok" =~ ^[0-9]+$ ]] && queue+=("$tok") ;;
     esac
   done
   ```

2. **Numeric-validate every positional argument** (T3 mitigation). For each token in `queue`, call `_uberdev_goal_validate_int` (from `lib/goal-state.sh`); any failure aborts before any `gh` call sees the value. This is the first defence against `gh` argument injection via PR/issue numbers (R3).

   ```bash
   for issue in "${queue[@]}"; do
     _uberdev_goal_validate_int "$issue" || {
       printf 'goal: invalid issue number: %s\n' "$issue" >&2; exit 2
     }
   done
   ```

3. **Read `--max-cycles` via the config-read range helper.** Resolves `--max-cycles=N` CLI flag → `UBERDEV_GOAL_MAX_CYCLES` env → `goal.max_cycles` config key → default `_UBERDEV_GOAL_DEFAULT_MAX_CYCLES`; range `[1, 20]`:

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
   MAX_CYCLES="$(UBERDEV_GOAL_MAX_CYCLES="${max_cycles_cli:-${UBERDEV_GOAL_MAX_CYCLES:-}}" \
     uberdev_read_int_in_range goal.max_cycles UBERDEV_GOAL_MAX_CYCLES 1 20 "$_UBERDEV_GOAL_DEFAULT_MAX_CYCLES")"
   ```

4. **Source `lib/dispatch.sh`; call `uberdev_dispatch_preflight`** → sets `UBERDEV_RESOLVED_BACKEND` once for the whole run (D15). The resolved backend is forwarded to every `/turbo`, `/merge`, and `/review-pr` child dispatch in this run; it is NEVER re-resolved per cycle.

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
   uberdev_dispatch_preflight "${backend_cli:-auto}"
   # UBERDEV_RESOLVED_BACKEND is now exported (D15: resolved once, frozen for the run).
   # /goal dispatches /turbo per issue, so mirror /turbo's unattended dispatch env.
   export AUTO_MODE=1            # matches commands/turbo.md (enables UBERDEV_TURBO=1 in the bg env)
   # AUTO_PERMISSIONS and EFFORT_LEVEL are intentionally left unset -> helper applies
   # :-0 / :-max defaults (turbo-parity: empty PERM_FLAG, EFFORT_FLAG=( --effort max )).
   uberdev_dispatch_resolve_env || exit 1   # establishes TIMEOUT_BIN/SOLVE_TIMEOUT/MODEL/PERM_FLAG/EFFORT_FLAG/BG_PROMPT_MODE once
   ```

5. **Generate `GOAL_ID`.** Random suffix per D4 — NEVER derived from `$@` or issue numbers (those are attacker-controlled; using them would let a caller collide TMPDIR paths):

   ```bash
   export UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"   # D7 — stable sidecar dir for the watcher
   GOAL_ID="goal-$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
   export UBERDEV_GOAL_ID="$GOAL_ID"
   ```

6. **Source `lib/goal-state.sh`; call `uberdev_goal_state_init "$GOAL_ID"`.** This truncate-creates the per-goal state files (`goal-<id>.jsonl`, `goal-<id>-pr-states.tsv`, `goal-<id>-issue-states.tsv`, `goal-<id>-fingerprints.tsv`, `goal-<id>-merge-attempts.tsv`, `goal-<id>-review-pr-attempts.tsv`, `goal-<id>-held-audits.tsv`) under `$UBERDEV_TMPDIR` and refuses unsafe path characters (T4):

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
   uberdev_goal_state_init "$GOAL_ID" || exit 1
   ```

7. **Initialize cycle counter + goal-level wall-clock anchor.** `cycle` is the per-cycle counter referenced by Phase 2/3/4 (audit payloads, MAX_CYCLES check, fingerprint repeat detector). `watch_start` is the **goal-level** wall-clock anchor — it must persist across cycle iterations so the 4h stuck-loop circuit breaker (`_UBERDEV_GOAL_STUCK_SECS`) measures total goal wall-clock, not per-cycle wall-clock (RFC §3.3 intent: the 4h cap is the goal-level safety net). `overflow_count` and `overflow_detected` are **per-cycle** accumulators set in Phase 2a and reset at the end of Phase 3 (so the `goal_cycle_completed` payload only reports overflows from the current cycle).

   ```bash
   cycle=1
   watch_start="$(date +%s)"
   overflow_count=0
   overflow_detected=0
   ```

   ```bash
   # #171 — persist the run-state pointer + loop accumulators so Phases 1-4
   # (fresh shells) can rehydrate GOAL_ID + counters. cycle is initialized above.
   uberdev_goal_write_run_state || { echo "goal: failed to persist run-state" >&2; exit 3; }
   ```

8. **If `--dry-run`: print planned cycle-1 dispatch list + watch-loop outline, exit 0** (D16, S9). The dry-run path is the audit/preview surface — no `gh` calls, no agent spawns, no merges, **no audit events emitted** (S9 — `goal_dispatched` must NOT fire on dry-run so the audit log only carries real runs). Emit the resolved `MAX_CYCLES`, the resolved `UBERDEV_RESOLVED_BACKEND`, the issue queue, and the planned audit events ("would emit goal_dispatched", "would dispatch /turbo for issues …", "would poll solve-bg-stdout-N.log per issue"), then exit 0 cleanly. This step runs BEFORE the real `goal_dispatched` emit in step 9 — order matters.

9. **Emit `goal_dispatched` event** with `{goal_id, cycle: 0, issues, dry_run, backend}` payload (real runs only — dry-run exits in step 8 before reaching here). This is the audit anchor — `cycle: 0` distinguishes the initial dispatch from the Phase 1 per-cycle dispatch:

   ```bash
   issues_json="$(printf '%s\n' "${queue[@]}" | jq -R . | jq -sc .)"
   uberdev_goal_audit goal_dispatched \
     "{\"goal_id\":\"$GOAL_ID\",\"cycle\":0,\"issues\":$issues_json,\"dry_run\":$dry_run,\"backend\":\"$UBERDEV_RESOLVED_BACKEND\"}"
   ```

10. **`gh api rate_limit` soft pre-flight (Q5 tertiary).** Warn-only — never halt. Per cycle the watcher generates roughly `5 × N × 60` `gh` calls; rate-limit exhaustion mid-run is the highest-likelihood "stuck loop" cause that's NOT a real bug, so surface it up-front:

   ```bash
   remaining="$(gh api rate_limit --jq '.resources.core.remaining // 0' 2>/dev/null || echo 0)"
   if [ "$remaining" -lt 1000 ]; then
     printf 'goal: warning — gh API rate-limit remaining=%s < 1000; long runs may stall on 403s\n' \
       "$remaining" >&2
   fi
   ```

## Phase 1 — Dispatch (per cycle)

Per cycle, walk the current `queue` and dispatch one `/turbo` agent per eligible issue. Skip issues already in `solving` or `pr-pushed` (resume safety — if Phase 0 was re-entered after a partial run within the same `$UBERDEV_TMPDIR`, in-flight issues must not be re-dispatched).

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 1" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
declare -a active_issues=()
for ISSUE_NUM in "${queue[@]}"; do
  current_state="$(awk -v i="$ISSUE_NUM" '{state[$1]=$2} END {print state[i]}' \
    "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" 2>/dev/null)"
  case "$current_state" in
    solving|pr-pushed) continue ;;
  esac

  # Build the per-issue prompt via mktemp. The body is a single /uberdev:turbo
  # line; --turbo runs non-interactive (no gates — scoped relaxation §3 below)
  # and --backend forwards the Phase 0 resolved backend so every cycle uses the
  # same backend.
  PROMPT_FILE="$(mktemp)"
  printf '/uberdev:turbo %s --turbo --backend=%s\n' \
    "$ISSUE_NUM" "$UBERDEV_RESOLVED_BACKEND" > "$PROMPT_FILE"

  # T5 provenance — the child /turbo agent (and its downstream /merge dispatch,
  # if any) MUST inherit UBERDEV_GOAL_ID so uberdev_goal_should_automerge can
  # verify the merge is coming from inside this /goal run. Without this env
  # forwarding, the per-PR attempt-counter cap would not gate a stray merge
  # attempt and the runaway-loop containment (R5) would silently fail open.
  export UBERDEV_GOAL_ID="$GOAL_ID"

  # Dispatch via the same lib/dispatch.sh path /solve and /turbo use. Tier is
  # "small" (the prompt is one line; the child does its own triage).
  if uberdev_dispatch_one "$ISSUE_NUM" "small" "$PROMPT_FILE"; then
    uberdev_goal_issue_state_transition "$GOAL_ID" "$ISSUE_NUM" input solving
    active_issues+=("$ISSUE_NUM")
  else
    rc=$?
    # D12 — claim_collision is a soft fail: another dispatcher (a teammate's
    # /solve, or a parallel /goal run) already holds the uberdev:active label
    # on this issue. Skip for the cycle; do NOT retry; do NOT halt the goal.
    # Detection: solve-pipeline writes `{"event":"claim_collision","data":{"issue":N,...}}`
    # to $SOLVE_AUDIT_LOG (default ${UBERDEV_TMPDIR:-/tmp}/solve-audit.jsonl)
    # when it refuses to dispatch a claimed issue. uberdev_dispatch_one does
    # NOT propagate rc=42 — the contract is "any non-zero rc is a dispatch
    # failure"; the audit JSONL is the canonical claim_collision signal.
    solve_audit="${SOLVE_AUDIT_LOG:-${UBERDEV_TMPDIR:-/tmp}/solve-audit.jsonl}"
    if [ -f "$solve_audit" ] && \
       grep -q "\"event\":\"claim_collision\".*\"issue\":$ISSUE_NUM" "$solve_audit" 2>/dev/null; then
      printf 'goal: issue %s skipped this cycle (claim_collision)\n' "$ISSUE_NUM" >&2
      continue
    fi
    # Any other dispatch failure is a hard error — fail loud, never silent.
    printf 'goal: dispatch failed for issue %s (rc=%s)\n' "$ISSUE_NUM" "$rc" >&2
    print_summary "$cycle"
    exit 1
  fi
done
```

## Phase 2 — Watch (per cycle, hard cap 4h wall-clock)

**Concurrency model.** Phase 2 runs as a **single-threaded watcher** per iteration: each `sleep $_UBERDEV_GOAL_POLL_SECS` cycle walks the active-issues list once (step 2a), the green-PR list once (step 2b), and the merging-PR list once (step 2c) in deterministic order — a serial poll of every PR, never a fan-out. There is **no per-PR poll parallelism in v1** — the audit timeline (`goal_pr_transition` events in `goal-<id>.jsonl`) must remain a serial, replay-deterministic sequence for post-mortems and for the fingerprint-repeat detector in Phase 3. Per-PR poll parallelism is deferred to a future RFC (it would require an event-bus partition by PR number and a multi-writer audit framing that preserves a total order; neither lands in v1).

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 2" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
# watch_start is set in Phase 0 (step 7) — goal-level wall-clock anchor.
# The 4h stuck-loop check below measures total goal wall-clock, not per-cycle.
# Q1 — bash supports ONE EXIT trap per shell; register the combined cleanup
# for $gh_err + $findings_err here (Phase 3 mktemps $findings_err later).
# Initialize $findings_err empty so `rm -f ""` is harmless if Phase 3 isn't
# reached, and so a later `trap '…' EXIT` doesn't overwrite this one.
gh_err="$(mktemp)"
findings_err=""
trap 'rm -f "$gh_err" "$findings_err"' EXIT

while true; do
  now="$(date +%s)"
  if (( now - watch_start >= _UBERDEV_GOAL_STUCK_SECS )); then
    uberdev_goal_audit goal_circuit_breaker \
      "{\"reason\":\"stuck_loop\",\"watch_secs\":$((now-watch_start))}"
    print_summary "$cycle"
    exit 1
  fi

  any_active=0

  # 2a. Poll each dispatched /turbo agent's stdout log
  # F13 simplify-lens — the `backgrounded · ` marker is terminal (emitted once
  # at session end by every dispatch.sh backend), so `tail -c 65536` bounds
  # per-poll grep cost to O(1) regardless of uncapped log growth. Identical
  # semantics for a contract that promises a terminal-marker; cheaper polling.
  for issue in "${active_issues[@]}"; do
    log="$UBERDEV_TMPDIR/solve-bg-stdout-$issue.log"
    if [ -f "$log" ] && tail -c 65536 "$log" 2>/dev/null | grep -q 'backgrounded · '; then
      audit_json="$(uberdev_goal_locate_review_pr_audit "$issue")"
      signal="$(uberdev_goal_read_trust_signal "$audit_json")"
      pr_num="$(uberdev_goal_extract_pr_num_from_log "$log")"
      # F11 simplify-lens — surface the missing-marker case (no `pushed PR #N`
      # line in the solve-bg stdout transcript yet) instead of letting it fall
      # through to a silent `uberdev_goal_pr_state_transition` validate-fail.
      # Treat as in-flight: keep the issue active so the next poll retries.
      if [ -z "$pr_num" ]; then
        printf 'goal-pipeline: issue %s: no `pushed PR #N` marker in stdout yet; deferring to next poll\n' \
          "$issue" >&2
        any_active=1
        continue
      fi
      case "$signal" in
        green)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing green
          ;;
        yellow)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing yellow-held
          # Record the audit that put this PR in held so step 2e's poll loop
          # has a baseline — when a NEWER audit appears (re-review fired),
          # the poll loop applies the next state transition (#159).
          uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
          ;;
        red)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
          # Record audit baseline for the step 2e poll loop (mirrors yellow case).
          uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
          # B6 — Blocker-overflow handler (D13). Reads the per-PR audit JSON
          # while $audit_json and $pr_num are still in scope (the Phase 3
          # site previously held this block but those variables don't exist
          # there, so the check silently no-op'd). Setting overflow_detected
          # here gates the Phase 3 first-10 truncation below.
          #
          # M14 — explicit branch on gh_jq_or_jq rc. If the audit JSON is
          # corrupted, the old `halted_overflow="$(gh_jq_or_jq …)"` swallowed
          # jq's rc and left $halted_overflow empty — `[ "" = "true" ]` is
          # false so the overflow check silently skipped. Surface to stderr;
          # default to "no overflow" (safer than spuriously truncating the
          # next cycle's candidate queue on an unreadable audit).
          if halted_overflow="$(gh_jq_or_jq "$audit_json" '.phases.phase2_5.halted_due_to_overflow // false')"; then
            if [ "$halted_overflow" = "true" ]; then
              overflow_detected=1
              # Q4 — accumulate per-cycle PR-overflow count for the
              # goal_cycle_completed audit payload (the prose at line ~381
              # promises {overflow_count: N} in the summary).
              overflow_count=$(( ${overflow_count:-0} + 1 ))
              uberdev_goal_write_run_state || echo "goal: warning: run-state flush failed in Phase 2a" >&2
            fi
          else
            printf 'goal-pipeline: overflow check failed to read audit %s for PR %s; treating as no overflow this cycle\n' \
              "$audit_json" "$pr_num" >&2
          fi
          ;;
        stale|missing)
          # D17: never assume GREEN on missing phase2_5 — re-dispatch /review-pr.
          # B3 bound — _uberdev_goal_dispatch_review_pr enforces a per-PR cap
          # at ${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3} dispatches across the
          # entire goal run (TSV at goal-<id>-review-pr-attempts.tsv mirrors
          # the merge-attempts pattern). The cap returns rc=0 with a stderr
          # warning when exceeded — the watch loop's 60s cadence cannot fire
          # >3 /review-pr dispatches per PR over the 4h stuck_loop window
          # (was unbounded at 240/PR). NOT a circuit breaker: the goal does
          # not halt; subsequent cycles skip re-dispatch in-place.
          _uberdev_goal_dispatch_review_pr "$pr_num"
          ;;
      esac
    else
      any_active=1
    fi
  done

  # 2b. Dispatch /merge for any new GREEN PRs
  # B2 — Only transition to `merging` on dispatch rc=0 (mirrors Phase 1's
  # `if uberdev_dispatch_one …` branching at lines ~166-189). Failed dispatch
  # (mktemp fails, prompt write fails, claude-bg session refuse, etc.) used
  # to transition the PR to `merging` anyway, then the watch loop would
  # poll for a backgrounded · marker that would never appear, stalling
  # until the 4h stuck_loop circuit breaker fired. Now: rc!=0 logs to
  # stderr and leaves the PR in `green` so the next watch iteration
  # retries; the per-PR attempt counter (cap 3) bounds runaway retries.
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" green); do
    if uberdev_goal_should_automerge "$GOAL_ID" "$pr"; then
      if _uberdev_goal_dispatch_merge "$pr"; then
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
      else
        printf 'goal-pipeline: _uberdev_goal_dispatch_merge failed for PR %s; staying in green for next-cycle retry\n' \
          "$pr" >&2
        any_active=1
      fi
    fi
  done

  # 2c. Drive /merge transitions
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" merging); do
    merge_log="$UBERDEV_TMPDIR/merge-bg-stdout-$pr.log"
    # F13 simplify-lens — `tail -c 65536` bounds per-poll grep cost; the
    # `backgrounded · ` marker is terminal so tail-of-file is equivalent.
    [ -f "$merge_log" ] && tail -c 65536 "$merge_log" 2>/dev/null | grep -q 'backgrounded · ' || continue
    result="$(uberdev_goal_read_merge_result "$pr")"
    case "$result" in
      success)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" merging merged
        # B4 — uberdev_goal_list_prs_in_state takes ONE state ($2); passing
        # `yellow-held red-held` made `red-held` a positional no-op and the
        # red-held PRs silently never got the unblock check. Call twice and
        # concatenate, mirroring print_summary's pattern below.
        for held_pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held; \
                         uberdev_goal_list_prs_in_state "$GOAL_ID" red-held); do
          _uberdev_goal_check_unblock "$held_pr"
        done
        ;;
      conflict|hook_failed)
        uberdev_goal_audit goal_circuit_breaker \
          "{\"reason\":\"merge_failed\",\"pr\":$pr,\"result\":\"$result\"}"
        print_summary "$cycle"
        exit 1
        ;;
      missing)
        # /merge hasn't appended an audit row for this PR yet (in-flight or
        # the merge-bg-stdout marker fired before the audit write hit the
        # disk). Defer to the next watch iteration — re-poll happens on the
        # next sleep cycle. Do NOT halt.
        ;;
      *)
        # B7 — defensive default-case guard. uberdev_goal_read_merge_result
        # is contracted to return `success|conflict|hook_failed|missing`; any
        # other value indicates a contract drift (e.g., a future enum member
        # not threaded through here). Halt loudly rather than fall through
        # silently, which would leave the PR stuck in `merging` forever.
        uberdev_goal_audit goal_circuit_breaker \
          "{\"reason\":\"unknown_merge_result\",\"pr\":$pr,\"result\":\"$result\"}"
        print_summary "$cycle"
        exit 1
        ;;
    esac
  done

  # 2e. Poll held PRs for re-review completion (RFC 0005 §3.2.3 hold-and-
  # unblock completion-half; #159). When the unblock rule (step 2c) dispatches
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
        # B1 — keep the watch loop alive for one more iteration so step 2b
        # (which runs ABOVE step 2e in cycle order) has a chance to pick this
        # freshly-green PR up on the next pass and dispatch /merge. Without
        # this, the held→green transition is invisible to step 2d's
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

  # 2d. Termination check (intra-cycle)
  if [ "$any_active" = "0" ] && \
     [ -z "$(uberdev_goal_list_prs_in_state "$GOAL_ID" merging)" ]; then
    break
  fi

  sleep "$_UBERDEV_GOAL_POLL_SECS"
done
```

Why polling stdout transcripts instead of the (non-existent) `claude agents status <id>` API: R6 in the implementation plan — the dispatch-backend agent-status API is a known gap, and the `backgrounded · ` marker emitted by every `lib/dispatch.sh` backend's stdout transcript is the only authoritative completion signal. The marker is a stable contract (asserted by the shared test surface), so this is not a fragile screen-scrape — it is the documented backend completion signal.

## Phase 3 — Collect Next Queue

After Phase 2 drains (no active agents, no merging PRs), enumerate the new BLOCKER/CRITICAL `review-pr-finding` issues filed during the cycle, repeat-detect them, and decide whether to loop, converge, or halt.

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 3" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
# Snapshot goal start for the createdAt filter — only consider findings filed
# during THIS goal run, not pre-existing review-pr-finding issues that pre-date
# the cycle. The TZ-Z timestamp lines up with gh's ISO-8601 createdAt format.
goal_start_iso="$(date -u -r "$watch_start" +%FT%TZ 2>/dev/null \
  || date -u -d "@$watch_start" +%FT%TZ)"

# In-process gh query — mirror discover.sh:152-183 mktemp/EXIT-trap stderr
# isolation pattern (no shell-piped --template, never an external jq pipe).
# The EXIT trap for $findings_err is registered up in Phase 2 alongside the
# $gh_err cleanup (bash only honors ONE EXIT trap per shell; a second trap
# here would silently overwrite the first and leak $gh_err).
findings_err="$(mktemp)"

# Build the optional --only-mine filter via env-injected GH_USER (gh resolves
# .author.login via env passthrough; --jq receives `env.GH_USER` literal).
# F14 simplify-lens — the filter projects directly to `.number` per matching
# row (newline-separated raw integers) so the downstream mapfile no longer
# needs a redundant `jq -r '.[]'` pass to flatten a `map(.number)` JSON array.
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
  print_summary "$cycle"
  exit 1
fi

# `candidates_json` is already newline-separated raw integers (one number per
# line) from the F14 filter shape above. Bash mapfile reads each line into the
# array; empty input yields a 0-element array (the `${#new_candidates[@]}`
# checks downstream behave identically to the prior map(.number)+jq -r path).
mapfile -t new_candidates < <(printf '%s' "$candidates_json")
```

For each candidate, extract the fingerprint and check for repeat:

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 3 (fingerprint loop)" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
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
    print_summary "$cycle"
    exit 1
  fi
done
```

**`--only-mine` filter behaviour.** When set, the `select(.author.login == env.GH_USER)` clause inside `--jq` restricts the candidate set to issues authored by the current `gh api user --jq '.login'` identity. This is the small-team / shared-repo escape hatch: a teammate's `/review-pr` run on an unrelated PR may have filed its own `review-pr-finding` issues, and the operator running `/goal` doesn't want to inherit those into their convergence loop. The label `FINDING_LABEL='review-pr-finding'` is the coarse filter; `--only-mine` is the optional fine filter.

**Cycle terminal conditions (evaluated AFTER the per-candidate fingerprint check):**

- If `cycle >= MAX_CYCLES` AND `new_candidates` is non-empty: halt with `goal_circuit_breaker reason=max_cycles`, exit 1. The operator has explicitly capped iteration count via `--max-cycles=N` or the `goal.max_cycles` config key; we respect the cap rather than spinning forever.
- If `new_candidates` is empty AND every PR in this run is in `{merged, merge-failed, yellow-held, red-held}`: convergence reached, emit `goal_converged`, exit 0. Held states are **pseudo-terminal for convergence** (#160) — they are surfaced to the operator via `print_summary` (each held PR's `Blocks: #N` list is printed) and are addressed out-of-band; counting them as terminal here is what lets the goal converge cleanly instead of spinning until the 4h `stuck_loop` fires. `merge-failed` PRs are counted as terminal-converged because the merge-failed circuit breaker would have already fired upstream — reaching this state means every PR has been driven to a stable resting state.
- If `new_candidates` is empty AND at least one PR is still in a non-terminal in-flight state (`dispatched`, `pushed-reviewing`, `green` not yet merged, `merging`): emit `goal_circuit_breaker reason=queue_empty_not_converged`, exit 1 (#160). This is the deterministic alternative to the 4h `stuck_loop` wall-clock fallback — the queue is drained but PRs are stuck, so surface immediately instead of spinning against the GitHub API.
- Otherwise: emit `goal_cycle_completed` with the cycle summary `{cycle, prs_merged, prs_held, issues_resolved, new_candidates}`, set `queue ← new_candidates`, increment `cycle`, and loop back to Phase 1.

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 3 (terminal check)" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
if [ "$cycle" -ge "$MAX_CYCLES" ] && [ "${#new_candidates[@]}" -gt 0 ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"max_cycles\",\"cycle\":$cycle,\"max\":$MAX_CYCLES,\"queued\":${#new_candidates[@]}}"
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
all_pr_count="$(awk '{print $1}' "$UBERDEV_TMPDIR/goal-$GOAL_ID-pr-states.tsv" \
  | sort -u | wc -l)"
terminal_count="$(printf '%s\n' "$terminal_prs" | grep -c . || true)"
if [ "${#new_candidates[@]}" = "0" ] && [ "$terminal_count" = "$all_pr_count" ]; then
  uberdev_goal_audit goal_converged \
    "{\"cycle\":$cycle,\"prs\":$all_pr_count}"
  print_summary "$cycle"
  uberdev_goal_cleanup_run_state || true   # #171 — reap run-state sidecars on terminal exit
  exit 0
fi

# Deterministic queue-empty-not-converged halt (#160). Without this, a PR
# stuck in dispatched/pushed-reviewing/green/merging with nothing left to
# file as a finding would spin the Phase1→2→3 loop until stuck_loop fires (4h).
# Surface the stuck state immediately so the operator can act.
if [ "${#new_candidates[@]}" = "0" ] && [ "$terminal_count" != "$all_pr_count" ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"queue_empty_not_converged\",\"cycle\":$cycle,\"all_prs\":$all_pr_count,\"terminal\":$terminal_count}"
  print_summary "$cycle"
  exit 1
fi

uberdev_goal_audit goal_cycle_completed \
  "{\"cycle\":$cycle,\"new_candidates\":${#new_candidates[@]},\"overflow_count\":${overflow_count:-0}}"
queue=("${new_candidates[@]}")
cycle=$(( cycle + 1 ))
# Q4 — reset per-cycle accumulators before looping to Phase 1 (overflow_count
# is per-cycle; overflow_detected gates the per-cycle truncation above).
overflow_count=0
overflow_detected=0
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state before loop-back" >&2; exit 3; }
# loop back to Phase 1
```

**Blocker-overflow handler (D13).** When the upstream `/review-pr` run halted with too many BLOCKER findings (more than the file-issues cap), its audit JSON carries `halted_due_to_overflow: true` at the top level. **Detection lives in Phase 2a** (red signal case) where `$audit_json` and `$pr_num` are in scope; it sets `overflow_detected=1`. Phase 3's truncation step then:

- (Phase 2a already transitioned the PR to `red-held` for the red trust signal — overflow is functionally identical to RED, so the transition is shared);
- queues only the first 10 candidate issues for the next cycle (the upstream agent already truncated the issue-file list at the cap; the queue cap mirrors that ceiling);
- surfaces the overflow count in the `goal_cycle_completed` summary `{overflow_count: N}`;
- **does NOT halt the entire goal** — `halted_due_to_overflow` is a per-PR cycle-management signal, not a goal-level circuit breaker. The goal continues to its next cycle and may converge once the overflow PR's issues are resolved.

```bash
# #171 fresh-shell rehydration — re-source libs (idempotent via _UBERDEV_*_LOADED
# guards) and re-read run-state. Safe under set -u (${VAR:-} expansions).
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]    && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
[ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ]  && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
GOAL_ID="${UBERDEV_GOAL_ID:-${GOAL_ID:-}}"
uberdev_goal_read_run_state || { echo "goal: cannot rehydrate run-state in Phase 3 (overflow check)" >&2; exit 3; }
uberdev_dispatch_resolve_env || exit 1   # re-derive backend/env (idempotent, D8); not persisted
# overflow_detected is set in Phase 2a's red case when any PR's /review-pr
# audit JSON carried halted_due_to_overflow:true. Here in Phase 3 we apply
# the first-10 truncation (no PR transition — Phase 2a already did that).
if [ "${overflow_detected:-0}" = "1" ]; then
  new_candidates=("${new_candidates[@]:0:10}")
  # surfaced in cycle summary; goal continues — do NOT halt.
fi
```

## Phase 4 — Converge / Halt

Every exit path from this skill emits exactly one terminal audit event AND prints exactly one human-readable summary line to stdout:

**Exit paths (verbatim, in priority order):**

| Path | Audit event | Exit code | Trigger |
|---|---|---|---|
| Convergence | `goal_converged` | 0 | `new_candidates` empty AND every PR in `{merged, merge-failed, yellow-held, red-held}` (Phase 3 terminal check). Held states are pseudo-terminal so the goal converges cleanly when only held PRs remain (#160). |
| Max-cycles cap | `goal_circuit_breaker` with `reason=max_cycles` | 1 | `cycle >= MAX_CYCLES` AND `new_candidates` non-empty (Phase 3). |
| Non-convergence | `goal_circuit_breaker` with `reason=nonconvergence` | 1 | Fingerprint repeat detected by `uberdev_goal_check_fingerprint_repeat` (Phase 3 per-candidate loop). |
| Queue-empty-not-converged | `goal_circuit_breaker` with `reason=queue_empty_not_converged` | 1 | `new_candidates` empty AND at least one PR still in a non-terminal in-flight state (`dispatched`, `pushed-reviewing`, `green`, `merging`) — deterministic Phase 3 halt that pre-empts the 4h `stuck_loop` fallback (#160). |
| Stuck-loop | `goal_circuit_breaker` with `reason=stuck_loop` | 1 | `watch_secs >= _UBERDEV_GOAL_STUCK_SECS` (4h) at top of Phase 2 iteration. |
| Merge-failed | `goal_circuit_breaker` with `reason=merge_failed` | 1 | `/merge` returned `conflict` or `hook_failed` (Phase 2 step 2c). |

**Human-readable summary line.** Print to stdout (NOT stderr — this is the operator's success-or-failure narrative) before exit:

```
goal <GOAL_ID>: cycles=<N>/<MAX> prs_merged=<M> prs_held=<H> issues_resolved=<R> wall_secs=<S>
```

The held-PR list (each row `pr=<num> state=<yellow-held|red-held> blocks=#<i1>,#<i2>,…`) is the **post-mortem surface** — it tells the operator which PRs need human attention. It is printed after the summary line, one row per held PR.

```bash
# #171 — print_summary reads GOAL_ID/MAX_CYCLES/watch_start from the calling
# shell; every caller (Phase 2/3 fences) rehydrates them via
# uberdev_goal_read_run_state at fence top. Do NOT call from a non-rehydrated block.
print_summary() {
  local cycles="$1" prs_merged prs_held_lines prs_held_count issues_resolved wall_secs
  prs_merged="$(uberdev_goal_list_prs_in_state "$GOAL_ID" merged | grep -c . || true)"
  # Build a `<state>\t<pr>` stream so the per-row printf below can emit the
  # `state=` field promised at line ~466 ("each row pr=<num> state=<yellow-held
  # |red-held> blocks=…"). The prior implementation merged the two lists into
  # bare PR numbers and the `state=` field was silently dropped (S6).
  prs_held_lines="$( \
    uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held | sed 's/^/yellow-held\t/'; \
    uberdev_goal_list_prs_in_state "$GOAL_ID" red-held    | sed 's/^/red-held\t/' )"
  prs_held_count="$(printf '%s\n' "$prs_held_lines" | grep -c . || true)"
  issues_resolved="$(awk '$2=="resolved" {print $1}' \
    "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" | grep -c . || true)"
  wall_secs="$(( $(date +%s) - watch_start ))"
  printf 'goal %s: cycles=%s/%s prs_merged=%s prs_held=%s issues_resolved=%s wall_secs=%s\n' \
    "$GOAL_ID" "$cycles" "$MAX_CYCLES" "$prs_merged" "$prs_held_count" \
    "$issues_resolved" "$wall_secs"
  printf '%s\n' "$prs_held_lines" | while IFS=$'\t' read -r state p; do
    [ -z "$p" ] && continue
    body="$(_uberdev_goal_fetch_pr_body "$p")"
    blocks="$(printf '%s\n' "$body" | grep -E '^Blocks: #[0-9]+$' \
      | sed -E 's/^Blocks: #([0-9]+)$/#\1/' | paste -sd, -)"
    printf '  pr=%s state=%s blocks=%s\n' "$p" "$state" "${blocks:-none}"
  done
}
```

## Unblock rule

Called from Phase 2 step 2c on every `merging → merged` PR transition, for each PR currently in `yellow-held` or `red-held`. The body of the rule is implemented by `lib/goal-state.sh::_uberdev_goal_check_unblock`; the 5-step contract:

1. **Fetch held PR body.** `gh pr view $held_pr --json body --jq '.body'`, capped at `_UBERDEV_GOAL_BODY_CAP` (64 KiB) via `head -c` to bound the regex-parse cost (R1 / T1 — without the cap, a 10 MB PR body could ReDoS the parse loop or starve memory).
2. **Line-split and match against `BLOCKS_LINE_REGEX`.** Each line is fed to bash `[[ =~ ]]` against the anchored shape `^Blocks: #([0-9]+)$` — anchored, no quantifiers under user control, ReDoS-safe (D9 + T1). Non-matching lines are skipped silently (a held PR body need not contain a Blocks line — in which case nothing is unblocked).
3. **Build blocking-issue numbers.** Capture group 1 of each match is re-validated by `_uberdev_goal_validate_int` (defence in depth — anchored `[0-9]+` already passed it, but a second check costs nothing). For each number, query `gh issue view $N --json state --jq '.state'`.
4. **If all blocking issues are CLOSED, re-dispatch `/uberdev:review-pr $held_pr`** via `_uberdev_goal_dispatch_review_pr` (D18 full re-review — including Phase 3 CI Health re-evaluation; the no-shortcut path is mandatory because the upstream merge that triggered this unblock may have changed CI dependencies). If any blocking issue is still OPEN, do nothing this iteration; the unblock check will re-run on the next merged-PR transition.
5. **Emit `goal_unblock_triggered` event** with payload `{pr, blocking_issues: […]}`. This event is the durable record that the unblock fired; consumers can replay it from `goal-<id>.jsonl` to reconstruct the held-PR DAG.

**Completion half (Phase 2 step 2e — #159).** The unblock rule's `/review-pr` dispatch in step 4 is fire-and-forget; it is **Phase 2 step 2e**, the held-PR re-review poll, that closes the loop. On every Phase 2 iteration, step 2e walks every PR currently in `yellow-held` / `red-held`, compares the live latest audit (`uberdev_goal_locate_review_pr_audit_by_pr`) against the previously-consumed audit (`uberdev_goal_get_last_held_audit`), and — when they differ — applies the next state transition based on the new audit's trust signal: `green → green` (eligible for merge in next cycle's step 2b), severity-flip → `{yellow,red}-held → {red,yellow}-held` re-classification, or same-severity → no transition. Without step 2e, the dispatch in step 4 had no consumer, and the held PR was permanently orphaned (the bug issue #159 captured).

## Scoped relaxations

`/goal` is the one place in UberDev where three otherwise-strict /uberdev conventions are deliberately relaxed (RFC §2.3). Every relaxation is scoped to `/goal` only — the relaxed behaviour does NOT leak to standalone `/turbo`, `/merge`, or `/review-pr` invocations.

1. **`feedback_merge_independent`: `/merge` auto-chain allowed inside `/goal`.** The global rule "merge is a deliberate user-invoked command" still holds for standalone use. Inside `/goal`, Phase 2 step 2b auto-dispatches `/merge` for any PR that transitions to `green`, subject to:
   - `uberdev_goal_should_automerge` provenance check (UBERDEV_GOAL_ID env-var must be set — outside `/goal` it isn't, so the auto-merge refuses);
   - per-PR attempt counter cap (`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3` — after 3 attempts the same PR is held for human inspection);
   - YELLOW/RED PRs are NEVER auto-merged (D17 forbidden transitions).

2. **`feedback_brainstorm_no_gates`: `/turbo` runs non-interactive (no gates).** Phase 1 forwards `--turbo` to every child dispatch, which sets `AUTO_MODE=1` in solve-pipeline. Brainstorm / Q&A approval gates are skipped; the medium/large tier orchestrator runs with its always-on agent reviewer pair instead of human checkpoints. This is consistent with the global memory `feedback_brainstorm_no_gates` and `feedback_quality_over_speed` — quality comes from parallel research + always-on reviewers, not approval prompts.

3. **YELLOW handling: YELLOW PRs are NEVER merged — they are held for re-review.** Standalone `/merge` (with `--accept-critical-deferred`) can land a YELLOW PR; inside `/goal` this is forbidden. The PR-state-machine valid-transitions table in `_uberdev_goal_pr_state_machine_valid` returns non-zero for `yellow-held → merging` (D17); the only way out of `yellow-held` is `→ green` (after a successful `/review-pr` re-review that resolves the CRITICAL findings).

**Backend inheritance (D15).** Backend resolution is performed **once** by Phase 0 via `uberdev_dispatch_preflight`, which sets `UBERDEV_RESOLVED_BACKEND` for the whole run. The Phase 1 `/turbo` dispatch forwards `--backend=$UBERDEV_RESOLVED_BACKEND` explicitly (see the printf at line ~154); the Phase 2 `/merge` and `/review-pr` dispatches in `lib/goal-state.sh::_uberdev_goal_dispatch_{merge,review_pr}` do NOT thread the flag because the child commands do not accept `--backend` — those children re-resolve the backend in their own preflight from the same `UBERDEV_RESOLVED_BACKEND` env var that is exported by Phase 0 and inherited into every spawned shell. Per-cycle re-resolution at the orchestrator level is forbidden — it would let a transient `claude --version` flake mid-run silently swap backends and corrupt the agent-stdout polling contract (every backend emits the `backgrounded · ` marker, but the path conventions for `solve-bg-stdout-N.log` and `merge-bg-stdout-N.log` are backend-specific in a way that must remain stable across cycles). Wiring `--backend` through both downstream commands so the whole pipeline carries the flag explicitly is tracked as a follow-up (out of scope for v1).
