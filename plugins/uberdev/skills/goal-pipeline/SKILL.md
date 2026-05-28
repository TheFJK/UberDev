---
name: goal-pipeline
description: "Autonomous convergence pipeline for /uberdev:goal. Drives cycle algorithm (RFC 0005 §3.3) and PR/issue state machines. Inherits backend dispatch from solve-pipeline."
---

# Goal Pipeline (autonomous convergence body for /uberdev:goal)

This skill is invoked inline by `commands/goal.md`. It reads `$ARGUMENTS` from the caller's shell scope and drives a **5-phase cycle pipeline** — Phase 0 Preflight → Phase 1 Dispatch → Phase 2 Watch → Phase 3 Collect Next Queue → Phase 4 Converge/Halt — until the goal converges, max-cycles fires, fingerprint repeats (non-convergence), wall-clock exceeds 4h (stuck-loop), or a `/merge` halts on conflict/hook (merge-failed).

`/goal` is the autonomous convergence orchestrator from RFC 0005: it loops `/turbo` → auto `/review-pr` → `/merge` if GREEN, recursing on BLOCKER/CRITICAL `review-pr-finding` issues filed by `/review-pr` Phase 2.5 until the queue is empty AND every PR landed in `{merged, merge-failed}`. YELLOW PRs are NEVER merged inside `/goal` — they are held for re-review. RED PRs are held with a `Blocks: #N` body annotation that wires unblock back into the cycle once the blocking issues close.

> **You are an orchestrator, not an implementer.** You preflight, dispatch `/uberdev:orchestrator` agents one per issue, detect each solver's pushed PR via GitHub (`gh pr list` `closingIssuesReferences` / `feat/N-` head — CLI-version-independent, issue #180), drive PR state transitions from the file-based `/review-pr` Phase 2.5 verdict JSON, dispatch `/merge` for GREEN PRs, confirm merge via `gh pr view <pr> --json state == MERGED`, drive unblock checks on every successful merge, collect the next queue from `review-pr-finding` issues filed during the cycle, and halt deterministically via one of the exit paths. You never write feature code yourself.

## Constants

All audit-event names, state-machine enums, regex shapes, and tunable thresholds are declared here once. Later phases reference these names by symbol; values are NOT re-inlined.

```
GOAL_AUDIT_EVENT_ENUM='goal_dispatched|goal_pr_transition|goal_unblock_triggered|goal_cycle_completed|goal_converged|goal_circuit_breaker|goal_merge_deferred|goal_review_pr_deferred|goal_review_grace|goal_reaper_kill|goal_reaper_skipped|goal_issue_closed_without_pr'
GOAL_CIRCUIT_BREAKER_REASONS='max_cycles|nonconvergence|stuck_loop|merge_failed|gh_api_failed|unknown_merge_result|queue_empty_not_converged|agent_stuck_on_dialog'
GOAL_PR_STATE_ENUM='dispatched|pushed-reviewing|green|yellow-held|red-held|merging|merged|merge-failed'
GOAL_ISSUE_STATE_ENUM='input|dispatched|solving|pr-pushed|resolved|resolved-by-no-action|failed'
TRUST_SIGNAL_ENUM='green|yellow|red|stale|missing'
GOAL_MERGE_RESULT_ENUM='success|conflict|hook_failed|missing'
_UBERDEV_GOAL_DEFAULT_MAX_CYCLES=5
_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL=3
_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S=14400
_UBERDEV_GOAL_POLL_SECS=60
_UBERDEV_GOAL_STUCK_SECS=14400         # 4h
_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3
_UBERDEV_GOAL_SOLVE_TIMEOUT=9000       # 150m — no PR AND no live agent => issue failed (issue #180)
_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS=3600   # 60m default — overridable via goal.review_grace_secs / UBERDEV_GOAL_REVIEW_GRACE_SECS / --review-grace-secs (issue #220, AC ❶)
_UBERDEV_GOAL_MERGE_TIMEOUT=3600       # 60m — merging w/o MERGED AND agent idle => back to green for retry (issue #180)
_UBERDEV_GOAL_BODY_CAP=65536           # 64 KiB
FINDING_LABEL='review-pr-finding'
FINDING_FINGERPRINT_REGEX='<!-- uberdev:review-pr-finding fingerprint=([a-f0-9]{16}) -->'
BLOCKS_LINE_REGEX='^Blocks: #([0-9]+)$'
```

Notes on the enums:

- **`GOAL_AUDIT_EVENT_ENUM`** — the 12 events `lib/goal-state.sh::uberdev_goal_audit` accepts. Any other event name returns non-zero from the helper and is dropped on the floor; consumers grep these literals.
- **`GOAL_CIRCUIT_BREAKER_REASONS`** — the 8 halt reasons emitted by Phase 2/3/4 inside the `goal_circuit_breaker` payload's `.reason` field. The four original reasons (`max_cycles`, `nonconvergence`, `stuck_loop`, `merge_failed`); two surfaced-failure reasons added during post-impl-review (`gh_api_failed` — Phase 3 `gh issue list` rc!=0 instead of falsely treating an empty candidates list as convergence; `unknown_merge_result` — Phase 2d case default arm for a `uberdev_goal_read_merge_result` value outside the documented `success|conflict|hook_failed|missing` set); and `queue_empty_not_converged` — Phase 3 deterministic halt when the candidate queue is empty but at least one PR is still in a non-terminal state (issue #160; deterministic alternative to the 4h `stuck_loop` wall-clock fallback); and `agent_stuck_on_dialog` (issue #220 — Phase 2 stuck-on-dialog detector, see Component 3.4). The set is closed; new reasons require an RFC amendment.
- **`GOAL_PR_STATE_ENUM`** — the 8 states the PR machine in `_uberdev_goal_pr_state_machine_valid` recognises. `merged` and `merge-failed` are hard terminal (no further transitions); `yellow-held` and `red-held` are pseudo-terminal for convergence (Phase 3 counts them as terminal so the goal can converge cleanly with held PRs remaining, but the held-PR re-review poll loop in Phase 2 step 2e can still arc them to `green` once a re-review clears the findings, or cross-classify between `yellow-held`/`red-held` if a re-review's trust signal severity changed). `yellow-held → merging` and `red-held → merging` are hard-forbidden (D17 — never merge YELLOW/RED inside `/goal`).
- **`GOAL_ISSUE_STATE_ENUM`** — the 7 states the issue machine recognises. Happy path: `input → dispatched → solving → pr-pushed → resolved`. Close-without-PR path (issue #249): `input → dispatched → solving → resolved-by-no-action` — distinct from `resolved` (which means "PR landed and the issue auto-closed via `Closes #N`"); `resolved-by-no-action` means `/uberdev:orchestrator` legitimately closed the GitHub issue without producing a PR (e.g. stale finding, already-resolved). `dispatched` (issue #236) is written by the parent BEFORE `uberdev_dispatch_one` so any leaf-side crash between spawn and the post-spawn `solving` write still leaves a TSV row the Phase-1 skip-check (`dispatched|solving|pr-pushed`) matches on the next cycle — closes the silent double-spawn surface where a pre-state-write leaf failure looked identical to "never attempted". `pr-pushed → resolved` and the three `→ failed` sinks (`dispatched`, `solving`, `pr-pushed`) are terminal.
- **`TRUST_SIGNAL_ENUM`** — the 5 values `uberdev_goal_read_trust_signal` returns. `stale` (phase2_5 missing in audit JSON) and `missing` (audit JSON absent) both trigger `_uberdev_goal_dispatch_review_pr` rather than an assumed GREEN (D17).
- **`GOAL_MERGE_RESULT_ENUM`** — the 4 values `uberdev_goal_read_merge_result` returns. Maps the merge-pipeline's audit-row events (`merge_executed` for `success`, `pr_parked` with `data.reason ∈ {refused, ambiguous, push-non-ff}` for `conflict`, `pr_parked` with `data.reason == test-fail-exhausted` for `hook_failed`) plus a sentinel `missing` for "no audit row appended yet". Phase 2d's case statement handles each value explicitly; the `*)` default arm emits `goal_circuit_breaker reason=unknown_merge_result` (B7 — defensive guard against future enum drift).
- **`BLOCKS_LINE_REGEX`** is the anchored ReDoS-safe shape (D9 + T1) used by `_uberdev_goal_parse_blocks_line` in `lib/goal-state.sh`. The Phase 3 prose and the Unblock rule both reference this constant by name; the literal `^Blocks: #([0-9]+)$` appears here once.
- **`FINDING_FINGERPRINT_REGEX`** is the marker shape `agents/findings-to-issues.md` injects into every BLOCKER/CRITICAL `review-pr-finding` issue body; Phase 3 extracts it via `_uberdev_goal_extract_fingerprint` to drive the repeat-cycle detector.

## Phase 0 — Preflight

0. **bash ≥ 4 preflight guard (issue #180, defect #8).** Evaluated FIRST — before arg parsing, backend resolution, or any `gh` call. The watch loop's verdict locator (`uberdev_goal_locate_review_pr_audit_by_pr`) iterates unquoted globs that rely on bash's "unmatched glob → literal" semantics (zsh fatals with `no matches found`), and macOS's default `/bin/bash` is 3.2 (no `declare -A`, no `mapfile`). Refuse anything below bash 4 with a clear, actionable error rather than letting the loop misbehave silently.

   ```bash
   # Two-arm detection: the first arm catches non-bash shells (zsh, the Bash-tool
   # default, leaves BASH_VERSINFO unset); the second catches bash 3.2. Either way
   # the watch loop's glob + array semantics are unsafe — fail fast.
   if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
     echo "goal: requires bash >= 4 (macOS default /bin/bash is 3.2, and zsh fatals on the watch loop's unmatched-glob verdict locator)." >&2
     echo "  - install a modern bash:  brew install bash      # -> /opt/homebrew/bin/bash 5.x" >&2
     echo "  - then re-run /uberdev:goal under bash >= 4." >&2
     exit 2
   fi
   ```

1. **Parse positional issue numbers + flags.** The parser scans `$ARGUMENTS` and collects every token matching `^[0-9]+$` into the input queue; recognised flag tokens are `--max-cycles=N`, `--only-mine`, `--dry-run`, `--backend=<name>`. Empty input prints the usage line and exits.

   ```bash
   queue=()
   max_cycles_cli=""
   max_parallel_cli=""
   barrier_timeout_cli=""
   review_grace_cli=""
   only_mine=0
   dry_run=0
   backend_cli=""
   for tok in $ARGUMENTS; do
     case "$tok" in
       --max-cycles=*)         max_cycles_cli="${tok#--max-cycles=}" ;;
       --max-parallel=*)       max_parallel_cli="${tok#--max-parallel=}" ;;
       --barrier-timeout=*)    barrier_timeout_cli="${tok#--barrier-timeout=}" ;;
       --review-grace-secs=*)  review_grace_cli="${tok#--review-grace-secs=}" ;;
       --only-mine)            only_mine=1 ;;
       --dry-run)              dry_run=1 ;;
       --backend=*)            backend_cli="${tok#--backend=}" ;;
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

   MAX_PARALLEL="$(UBERDEV_GOAL_MAX_PARALLEL="${max_parallel_cli:-${UBERDEV_GOAL_MAX_PARALLEL:-}}" \
     uberdev_read_int_in_range goal.max_parallel UBERDEV_GOAL_MAX_PARALLEL 1 10 \
     "$_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL")"

   BARRIER_TIMEOUT_S="$(UBERDEV_GOAL_BARRIER_TIMEOUT_S="${barrier_timeout_cli:-${UBERDEV_GOAL_BARRIER_TIMEOUT_S:-}}" \
     uberdev_read_int_in_range goal.barrier_timeout_s UBERDEV_GOAL_BARRIER_TIMEOUT_S 60 86400 \
     "$_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S")"

   REVIEW_GRACE_SECS="$(UBERDEV_GOAL_REVIEW_GRACE_SECS="${review_grace_cli:-${UBERDEV_GOAL_REVIEW_GRACE_SECS:-}}" \
     uberdev_read_int_in_range goal.review_grace_secs UBERDEV_GOAL_REVIEW_GRACE_SECS 60 86400 \
     "$_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS")"
   ```

4. **Source `lib/dispatch.sh`; call `uberdev_dispatch_preflight`** → sets `UBERDEV_RESOLVED_BACKEND` once for the whole run (D15). The resolved backend is forwarded to every `/uberdev:orchestrator` (Phase 1), `/merge`, and `/review-pr` (Phase 2) child dispatch in this run; it is NEVER re-resolved per cycle.

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
   uberdev_dispatch_preflight "${backend_cli:-auto}"
   # UBERDEV_RESOLVED_BACKEND is now exported (D15: resolved once, frozen for the run).
   # /goal dispatches /uberdev:orchestrator per issue; mirror /turbo's unattended dispatch env so the orchestrator child inherits the same flags /turbo would have set.
   export AUTO_MODE=1            # matches commands/turbo.md (enables UBERDEV_TURBO=1 in the bg env)
   # /goal opts every dispatched bg agent into bypassPermissions so the cmux
   # PermissionRequest hook (or any --settings-shadowing daemon hook) does not
   # stall first-tool-use. The autonomous-loop contract requires it; standalone
   # /turbo + /solve defensively unset this var (see commands/turbo.md and
   # commands/solve.md). EFFORT_LEVEL stays unset -> helper applies :-max.
   export SKIP_PERMISSIONS=1     # (#241) /goal autonomous-loop opt-in; propagation via BG_TURBO_ENV — see lib/dispatch.sh BG_TURBO_ENV blocks
   uberdev_dispatch_resolve_env || exit 1   # establishes TIMEOUT_BIN/SOLVE_TIMEOUT/MODEL/PERM_FLAG/EFFORT_FLAG/BG_PROMPT_MODE once
   ```

5. **Generate `GOAL_ID`.** Random suffix per D4 — NEVER derived from `$@` or issue numbers (those are attacker-controlled; using them would let a caller collide TMPDIR paths):

   ```bash
   export UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"   # D7 — stable sidecar dir for the watcher
   GOAL_ID="goal-$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
   export UBERDEV_GOAL_ID="$GOAL_ID"
   ```

6. **Source `lib/goal-state.sh`; call `uberdev_goal_state_init "$GOAL_ID"`.** This truncate-creates the 8 per-goal state files (jsonl + 7 TSVs) — `goal-<id>.jsonl`, `goal-<id>-pr-states.tsv`, `goal-<id>-issue-states.tsv`, `goal-<id>-fingerprints.tsv`, `goal-<id>-merge-attempts.tsv`, `goal-<id>-review-pr-attempts.tsv`, `goal-<id>-held-audits.tsv`, `goal-<id>-batch-prs.tsv` — under `$UBERDEV_TMPDIR` and refuses unsafe path characters (T4):

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
   uberdev_goal_state_init "$GOAL_ID" || exit 1
   ```

7. **Initialize cycle counter + goal-level wall-clock anchor.** `cycle` is the per-cycle counter referenced by Phase 2/3/4 (audit payloads, MAX_CYCLES check, fingerprint repeat detector). `watch_start` is the **goal-level** wall-clock anchor — it must persist across cycle iterations so the 4h stuck-loop circuit breaker (`_UBERDEV_GOAL_STUCK_SECS`) measures total goal wall-clock, not per-cycle wall-clock (RFC §3.3 intent: the 4h cap is the goal-level safety net). `overflow_count` and `overflow_detected` are **per-cycle** accumulators set in Phase 2b (the red trust-signal case) and reset at the end of Phase 3 (so the `goal_cycle_completed` payload only reports overflows from the current cycle).

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

8. **If `--dry-run`: print planned cycle-1 dispatch list + watch-loop outline, exit 0** (D16, S9). The dry-run path is the audit/preview surface — no `gh` calls, no agent spawns, no merges, **no audit events emitted** (S9 — `goal_dispatched` must NOT fire on dry-run so the audit log only carries real runs). Emit the resolved `MAX_CYCLES`, `MAX_PARALLEL`, `BARRIER_TIMEOUT_S`, the resolved `UBERDEV_RESOLVED_BACKEND`, the issue queue, and the planned audit events ("would emit goal_dispatched", "would dispatch /uberdev:orchestrator for issues …", "would poll GitHub (gh pr list) for each issue's PR"), then exit 0 cleanly. This step runs BEFORE the real `goal_dispatched` emit in step 9 — order matters.

   ```bash
   if [ "$dry_run" = "1" ]; then
     printf 'goal: dry-run preview (no agent spawn, no audit emit)\n'
     printf '  MAX_CYCLES=%s\n' "$MAX_CYCLES"
     printf '  MAX_PARALLEL=%s\n' "$MAX_PARALLEL"
     printf '  BARRIER_TIMEOUT_S=%s\n' "$BARRIER_TIMEOUT_S"
     printf '  backend=%s\n' "$UBERDEV_RESOLVED_BACKEND"
     printf '  issues=%s\n' "${queue[*]}"
     printf '  would emit goal_dispatched\n'
     printf '  would dispatch /uberdev:orchestrator for issues %s (cap=%s per cycle)\n' \
       "${queue[*]}" "$MAX_PARALLEL"
     printf '  would poll GitHub (gh pr list) for each issue'\''s PR\n'
     exit 0
   fi
   ```

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

Per cycle, walk the current `queue` and dispatch one `/uberdev:orchestrator` agent per eligible issue. Skip issues already in `dispatched`, `solving`, or `pr-pushed`. The `dispatched` row is written by the parent BEFORE `uberdev_dispatch_one` (issue #236) so a leaf-side crash between spawn and the post-spawn `solving` write still leaves a row the next cycle's skip-check can match — closing the silent double-spawn surface where a pre-state-write leaf failure (OOM, agent timeout before first state write, future CLI regression) was indistinguishable from "never attempted".

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
# #211 — per-cycle parallel dispatch cap. Issues beyond MAX_PARALLEL roll over
# into remaining_queue, which becomes the next cycle's queue (flushed via
# uberdev_goal_write_run_state at the end of this fence).
dispatched_this_cycle=0
remaining_queue=()
for ISSUE_NUM in "${queue[@]}"; do
  current_state="$(awk -v i="$ISSUE_NUM" -v c1=1 -v c2=2 '{state[$c1]=$c2} END {print state[i]}' \
    "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" 2>/dev/null)"
  # Issue #236 — `dispatched` is the pre-spawn guard state written below before
  # uberdev_dispatch_one. Adding it to the skip-check closes the leaf-crash-
  # pre-state-write double-spawn surface: a leaf that crashes between spawn
  # and the post-spawn `solving` write still leaves a `dispatched` row, so the
  # next cycle's skip-check matches and never silently re-dispatches.
  case "$current_state" in
    dispatched|solving|pr-pushed) continue ;;
  esac

  # #211 — once the per-cycle cap is hit, defer every remaining eligible issue
  # to the next cycle by appending to remaining_queue. This MUST come AFTER the
  # already-dispatched skip-check above so re-entered/in-flight issues don't get
  # spuriously rolled over.
  if (( dispatched_this_cycle >= MAX_PARALLEL )); then
    remaining_queue+=("$ISSUE_NUM")
    continue
  fi

  # Build the per-issue prompt via mktemp. The body wraps a
  # /uberdev:orchestrator invocation in a natural-language imperative:
  # claude --bg 2.1.139+ does NOT slash-expand argv-supplied opening
  # messages, so a body opening with `/uberdev:orchestrator …` is silently
  # treated as natural language and the child agent never runs the
  # orchestrator. The "Invoke the slash command …" prefix forces the child
  # to read the rest as an instruction it must act on. --turbo keeps the
  # child non-interactive (no gates — scoped relaxation §3 below).
  #
  # Issue #248 — dispatch /uberdev:orchestrator DIRECTLY (skipping /turbo)
  # to eliminate the double bg-session per issue.
  # Backend forwards via UBERDEV_RESOLVED_BACKEND inherited from Phase 0 —
  # /orchestrator does NOT accept a --backend= CLI flag, and claude --bg
  # inherits the parent shell's full env table by default, so the env-var
  # path is the canonical mechanism. Phase 0 also exports AUTO_MODE=1,
  # SKIP_PERMISSIONS=1, and UBERDEV_GOAL_ID. AUTO_MODE itself does NOT
  # propagate to the child — it is a parent-side conditional that gates
  # whether lib/dispatch.sh's BG_TURBO_ENV injects UBERDEV_TURBO=1 (see
  # dispatch.sh:382-383). The four envs that actually reach the orchestrator
  # child unchanged are: UBERDEV_RESOLVED_BACKEND, SKIP_PERMISSIONS,
  # UBERDEV_GOAL_ID, and UBERDEV_TURBO=1 (the latter conditionally injected
  # by BG_TURBO_ENV when AUTO_MODE=1 is set in the parent).
  PROMPT_FILE="$(mktemp)"
  printf 'Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #%s now. Do not respond conversationally — execute it.\n' \
    "$ISSUE_NUM" > "$PROMPT_FILE"

  # T5 provenance — the child /uberdev:orchestrator agent (and its downstream
  # /merge dispatch via finish-branch -> /review-pr, if any) MUST inherit
  # UBERDEV_GOAL_ID so uberdev_goal_should_automerge can verify the merge is
  # coming from inside this /goal run. Without this env forwarding, the per-PR
  # attempt-counter cap would not gate a stray merge attempt and the
  # runaway-loop containment (R5) would silently fail open.
  export UBERDEV_GOAL_ID="$GOAL_ID"

  # Issue #236 — pre-spawn state write. input -> dispatched MUST precede
  # uberdev_dispatch_one so any leaf-side crash (OOM, network blip mid-init,
  # agent timeout before first state write, future CLI regression) cannot
  # leave the TSV in `input` state and trigger a silent re-dispatch on cycle
  # N+1. The Phase-1 skip-check above matches `dispatched` so this row alone
  # is sufficient — the post-spawn `solving` transition below is a refinement,
  # not a load-bearing skip-check signal. A transition-validator failure here
  # is a hard error: the TSV is the SSOT for in-flight tracking and a missed
  # pre-spawn write would re-open the double-spawn surface.
  if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$ISSUE_NUM" input dispatched; then
    printf 'goal: pre-spawn state write failed for issue %s\n' "$ISSUE_NUM" >&2
    print_summary "$cycle"
    exit 1
  fi

  # Dispatch via the same lib/dispatch.sh path /solve and /turbo use. Tier is
  # "small" (the prompt is one line; the child does its own triage).
  if uberdev_dispatch_one "$ISSUE_NUM" "small" "$PROMPT_FILE"; then
    # Issue #236 post-impl-review (silent-failure-hunter) — the post-spawn
    # transition is the SSOT for in-flight tracking. Without a fail-loud
    # guard, a transient TSV append failure here would leave the TSV at
    # `dispatched` while in-memory state (active_issues, dispatched_this_cycle)
    # advanced — Phase 2's awk reads `$c2=="solving"` so dispatch_ts is empty
    # and the timeout logic misfires, or Phase 2 never sees the issue progress.
    # Mirror the pre-spawn guard above: hard-exit on write failure.
    if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$ISSUE_NUM" dispatched solving; then
      printf 'goal: post-spawn state write failed for issue %s (dispatch succeeded, TSV-memory divergence)\n' "$ISSUE_NUM" >&2
      print_summary "$cycle"
      exit 1
    fi
    active_issues+=("$ISSUE_NUM")
    dispatched_this_cycle=$(( dispatched_this_cycle + 1 ))
    # #211 — Note: registration is deferred to Phase 2 step 2a once the PR
    # number resolves. uberdev_goal_register_batch_pr requires a valid
    # integer PR number (its _uberdev_goal_validate_int gate rejects empty
    # strings), and the PR doesn't exist yet at dispatch-time (the solver
    # pushes the PR later). Phase 2 step 2a calls
    # uberdev_goal_find_pr_for_issue and, on first non-empty resolution,
    # registers the PR into the batch-PR registry behind an idempotent
    # TSV-lookup guard so the barrier accounts for it.
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
    # Issue #236 — `dispatched` row cleanup. The parent wrote `dispatched`
    # above (line 270), and dispatch_one returned non-zero. Both downstream
    # branches (claim_collision soft-skip + hard-error fall-through) need to
    # transition `dispatched -> failed` so the TSV (the audit-trail SSOT) does
    # not leave a stranded `dispatched` row that the Phase-1 skip-check would
    # match on a future cycle — tightening "skip THIS cycle" silently to
    # "skip for goal-lifetime". Hoisted out of both branches per Phase-2
    # simplify-lens (Quality.3) to eliminate a maintenance-divergence vector
    # where a future cleanup-contract change would need to be applied in two
    # places. The cleanup MUST run before the downstream `continue`/`exit 1`
    # so the TSV reflects the true terminal state — but a cleanup write
    # failure must not mask the original skip/exit cause, so we warn-and-go
    # rather than propagate rc. Without the warning the previous `|| true`
    # form silently orphaned `dispatched` rows on the claim_collision arm
    # (subsequent cycles match `dispatched|solving|pr-pushed` and skip the
    # issue forever — silent zombie that blocks /goal convergence). Emit to
    # stderr so operators see TSV corruption when it happens; the cycle
    # still proceeds to the skip/exit-causing branch below.
    if ! uberdev_goal_issue_state_transition "$GOAL_ID" "$ISSUE_NUM" dispatched failed; then
      printf 'goal: WARN cleanup transition dispatched->failed FAILED for issue %s (TSV-state corruption — manual recovery may be needed)\n' "$ISSUE_NUM" >&2
    fi
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

# #211 — flush the rollover queue back into `queue` so the next cycle picks up
# the issues that exceeded MAX_PARALLEL. Empty remaining_queue is the happy path
# (queue fully drained this cycle); a non-empty rollover is the cap-saturation
# case and is the SSOT for "more issues to dispatch next cycle".
queue=("${remaining_queue[@]}")

# #171 — flush the populated active_issues (+ rehydrated queue/scalars) so the
# Phase 2 watch loop (a fresh shell) rehydrates the dispatched set. Without this,
# active_issues evaporates with this shell and Phase 2 polls nothing, emitting a
# false goal_converged on cycle 1. Loud-exit: this is a phase-boundary persist
# Phase 2 depends on (mirrors the Phase 0 init + Phase 3 loop-back flushes).
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state after dispatch" >&2; exit 3; }
```

## Phase 2 — Watch (per cycle, hard cap 4h wall-clock)

**Concurrency model.** Phase 2 runs as a **single-threaded watcher** per iteration: each `sleep $_UBERDEV_GOAL_POLL_SECS` cycle walks the active-issues list once (step 2a — gh PR detection), the pushed-reviewing PR list once (step 2b — graced verdict read), the green-PR list once (step 2c — /merge dispatch), the merging-PR list once (step 2d — gh merge completion), and the held-PR list once (step 2e — re-review poll) in deterministic order — a serial poll of every PR, never a fan-out. There is **no per-PR poll parallelism in v1** — the audit timeline (`goal_pr_transition` events in `goal-<id>.jsonl`) must remain a serial, replay-deterministic sequence for post-mortems and for the fingerprint-repeat detector in Phase 3. Per-PR poll parallelism is deferred to a future RFC (it would require an event-bus partition by PR number and a multi-writer audit framing that preserves a total order; neither lands in v1).

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
# Issue #220 — INT/TERM are SEPARATE signal slots from EXIT. The existing EXIT
# trap above is NOT overwritten; bash supports one handler per signal slot.
# Reaper runs on Ctrl-C (130) and external kill -TERM (143). EXIT keeps tempfile
# cleanup running on every other exit path. NEVER chain reaper into EXIT — that
# would force the reaper on graceful convergence (slow, wasteful).
trap '_uberdev_goal_reap_zombies; exit 130' INT
trap '_uberdev_goal_reap_zombies; exit 143' TERM

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

  # 2a. Detect each solver's pushed PR via GitHub (issue #180 — CLI-version-
  # independent). The pre-2.1.150 stdout-marker probe (`backgrounded ·` +
  # `pushed PR #N`) is retired: on CLI 2.1.150 `claude --bg` detaches with a
  # banner-only stdout and `pushed PR #N` has zero producers, so the loop keying
  # on it never advanced. Authoritative completion signal = a PR that closes
  # issue N exists on GitHub (`closingIssuesReferences` / `feat/N-` head). When
  # no PR exists yet, `uberdev_goal_agent_busy_for_issue` disambiguates "solver
  # still working" from "solver died", bounded by _UBERDEV_GOAL_SOLVE_TIMEOUT.
  for issue in "${active_issues[@]}"; do
    istate="$(awk -v i="$issue" -v c1=1 -v c2=2 '{s[$c1]=$c2} END{print s[i]}' \
      "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" 2>/dev/null)"
    case "$istate" in pr-pushed|resolved|resolved-by-no-action|failed) continue ;; esac
    pr_num="$(uberdev_goal_find_pr_for_issue "$issue")"
    if [ -n "$pr_num" ]; then
      # #211 — register the PR into the batch-PR registry once it's resolved.
      # Registration is deferred from Phase 1 (no PR number at dispatch-time)
      # to here, the first point at which uberdev_goal_find_pr_for_issue
      # returns a non-empty value. Idempotent guard: skip if a row for this
      # PR already exists in the TSV, so subsequent passes (and repeat 2a
      # resolutions in the same cycle) don't double-write. Best-effort:
      # warn-and-continue on rc != 0 — a transient registry write must not
      # fail the watch loop.
      batch_tsv="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}/goal-${GOAL_ID}-batch-prs.tsv"
      if [ ! -f "$batch_tsv" ] || ! awk -F'\t' -v p="$pr_num" -v c1=1 '$c1==p{found=1; exit} END{exit !found}' "$batch_tsv"; then
        uberdev_goal_register_batch_pr "$GOAL_ID" "$pr_num" "$issue" \
          || printf 'goal: register_batch_pr deferred-call failed for PR=%s issue=%s (rc=%s)\n' "$pr_num" "$issue" "$?" >&2
      fi
      uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving pr-pushed
      uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" dispatched pushed-reviewing
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
    # No PR yet — is the solver still alive, or did it die?
    if uberdev_goal_agent_busy_for_issue "$issue"; then
      any_active=1
    else
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
          uberdev_goal_audit goal_issue_closed_without_pr \
            "{\"goal_id\":\"$GOAL_ID\",\"issue\":$issue,\"detected_at\":$now}"
          continue
        fi
      fi
      if [ "$gh_rc" -ne 0 ]; then
        printf 'goal-pipeline: gh issue view %s failed rc=%d — falling through to timeout backstop\n' \
          "$issue" "$gh_rc" >&2
      fi
      dispatch_ts="$(awk -v i="$issue" -v c1=1 -v c2=2 -v c3=3 '$c1==i && $c2=="solving"{t=$c3} END{print t+0}' \
        "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" 2>/dev/null)"
      if [ "$(( now - dispatch_ts ))" -lt "$_UBERDEV_GOAL_SOLVE_TIMEOUT" ]; then
        any_active=1
      else
        printf 'goal-pipeline: issue %s FAILED (no PR, agent idle, %ss elapsed)\n' \
          "$issue" "$(( now - dispatch_ts ))" >&2
        uberdev_goal_issue_state_transition "$GOAL_ID" "$issue" solving failed
      fi
    fi
  done

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
    case "$signal" in
      green)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing green
        ;;
      yellow)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing yellow-held
        # Baseline audit for step 2e's poll loop — a NEWER audit means a
        # re-review fired, so the poll loop applies the next transition (#159).
        uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
        ;;
      red)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
        uberdev_goal_record_held_audit "$GOAL_ID" "$pr_num" "$audit_json"
        # B6/M14 — blocker-overflow handler (D13). Explicit branch on
        # gh_jq_or_jq rc so a corrupted audit defaults to "no overflow" rather
        # than silently skipping; sets overflow_detected (gates the Phase 3
        # first-10 truncation) and accumulates the per-cycle count.
        if halted_overflow="$(gh_jq_or_jq "$audit_json" '.phases.phase2_5.halted_due_to_overflow // false')"; then
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
        # No verdict yet. Cascade — marker → grace → in-flight → stuck → dispatch
        # (issue #220, Components 3.2-3.4). Order is load-bearing: each probe
        # short-circuits before the next, so the stuck-on-dialog circuit breaker
        # only fires when every benign explanation (marker present, grace not
        # lapsed, /review-pr legitimately in flight) is ruled out. seen_ts comes
        # from the pr-states TSV (FIRST pushed-reviewing transition for this PR).
        # D17: never assume GREEN.
        #
        # B8 (post-impl-review): the awk filter MUST require state == "pushed-
        # reviewing" AND take the FIRST occurrence — without state filtering,
        # later transitions (e.g., dispatched→pushed-reviewing→green→...)
        # leak into seen_ts and the grace-window arithmetic compares "now"
        # against a much-newer transition timestamp, never crossing the
        # threshold. The original awk printed every row's ts for the PR and
        # the shell captured only the LAST line, masking the bug except
        # under specific transition orderings. `!t{t=$c3}` guards FIRST-seen;
        # `t+0` coerces empty → 0 so the downstream `$((now - seen_ts))` is
        # arithmetic-safe even when no row exists. The `-v c1=1 -v c2=2 -v c3=3`
        # parameterisation (issue #222) prevents the Skill renderer from
        # substituting positional args of `$ARGUMENTS` into the awk field refs.
        seen_ts=$(awk -F'\t' -v p="$pr_num" -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="pushed-reviewing" && !t{t=$c3} END{print t+0}' \
          "$UBERDEV_TMPDIR/goal-$GOAL_ID-pr-states.tsv" 2>/dev/null)
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
          _uberdev_goal_dispatch_review_pr "$pr_num"
          any_active=1
        fi
        ;;
    esac
  done

  # 2c. Barrier-gated merge dispatch (issue #211).
  # The previous per-PR `if green; then /merge` body is replaced by a two-
  # predicate gate: ONLY dispatch /merge once (a) every PR in the batch is in
  # a terminal state (GREEN | HELD | MERGE_FAILED | MERGED — barrier-terminal,
  # NOT to be confused with the convergence-terminal set) AND (b) the unblock
  # wait is clear (every blocking issue closed AND every blocked PR carries a
  # `review-pr:green` trust label). Until both predicates hold the per-cycle
  # batch sits at the merge barrier — preventing the multi-PR version-bump
  # collision (the user_workflow_todo_queue memory + project_uberdev_goal_
  # version_bump_collision capture). Sequential, PR-asc merge plus a
  # collision-chain rebase keeps the manifest-touching PRs serialized.
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
    # Both predicates clear — dispatch /merge for GREEN PRs in PR-number-
    # ascending order. The collision-chain rebase forces a fresh main pull
    # after each successful merge so the next PR in the chain rebases onto
    # the just-landed commit before its own merge attempt. This is what
    # serializes manifest-touching PRs (CHANGELOG.md, plugin.json,
    # marketplace.json, README.md) — without it, parallel version-bump PRs
    # silently auto-merge to the SAME vN+1 and the second PR's bump is
    # eaten by git's identical-change auto-resolution (the
    # project_uberdev_merge_version_collision memory).
    for pr in $(_uberdev_goal_batch_green_prs_ordered "$GOAL_ID"); do
      if uberdev_goal_pr_is_merged "$pr"; then
        # Resume / human-merged — finalize via step 2d without re-dispatching
        # /merge against an already-landed PR.
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
        any_active=1
        continue
      fi
      # Phase 2c in-flight gate (issue #220, Component 3.3) — never dispatch
      # /merge while the same PR has a /review-pr still in flight; defer one
      # poll tick. Emits goal_merge_deferred so the audit reflects the back-off.
      #
      # B2 (post-impl-review): set any_active=1 BEFORE continue (mirrors the
      # symmetric Phase 2b in-flight branch which sets it before emitting
      # goal_review_pr_deferred). Without this, an entire batch deferred by
      # in-flight /review-pr leaves any_active=0 and the watch loop terminates
      # with a spurious queue_empty_not_converged breaker fire.
      if uberdev_goal_review_pr_in_flight "$pr"; then
        any_active=1
        uberdev_goal_audit goal_merge_deferred \
          "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"review_in_flight\",\"in_flight_count\":1}"
        continue   # next poll tick re-checks
      fi
      if uberdev_goal_should_automerge "$GOAL_ID" "$pr"; then
        if _uberdev_goal_dispatch_merge "$pr"; then
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
          # Force-refresh main + rebase any remaining batch PRs that share
          # manifest paths so the next iteration's merge sees the just-landed
          # commit (collision-chain serialization, R5).
          # Helper contract is "rc 0 always" (see docstring at goal-state.sh:1238);
          # no `||` fallback needed — best-effort collision detection never halts.
          _uberdev_goal_rebase_collision_chain "$GOAL_ID" "$pr"
        else
          printf 'goal-pipeline: _uberdev_goal_dispatch_merge failed for PR %s; staying in green for next-cycle retry\n' \
            "$pr" >&2
          any_active=1
        fi
      fi
    done
  else
    # Barrier NOT clear yet — at least one PR is PENDING or the unblock-wait
    # has unresolved blockers. Check the wall-clock circuit breaker against
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
        merge_ts="$(awk -v p="$pr" -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="merging"{t=$c3} END{print t+0}' \
          "$UBERDEV_TMPDIR/goal-$GOAL_ID-pr-states.tsv" 2>/dev/null)"
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

  # 2f. Termination check (intra-cycle)
  if [ "$any_active" = "0" ] && \
     [ -z "$(uberdev_goal_list_prs_in_state "$GOAL_ID" merging)" ]; then
    break
  fi

  sleep "$_UBERDEV_GOAL_POLL_SECS"
done
```

> **PID-stash targeting model (issue #220).** `$UBERDEV_TMPDIR/solve-bg-status-<ISSUE>.json` is a single-slot PID stash per issue — it holds the PID of the most-recently-dispatched agent for that issue, and successive dispatches overwrite the prior PID. The stash is populated by `_uberdev_goal_dispatch_*` helpers (dispatch.sh:529-531) at every dispatch, so the slot holds: during Phase 1, the `/uberdev:orchestrator` solver PID; during Phase 2b stale|missing re-dispatch, the `/review-pr` PID (overwrites the solver PID — the prior `/uberdev:orchestrator` solver should have exited by the time Phase 2 starts polling); during Phase 2c, the `/merge` PID. The reaper therefore kills whichever spawn is currently in flight for that issue, which is the intended behaviour — only ONE spawn per issue is alive at any instant (the single-slot constraint is enforced by Component 3.3's in-flight gate). The stuck-on-dialog detector reads from the same slot for the same reason.

Why GitHub + the file-based verdict instead of agent stdout (issue #180): on Claude Code CLI 2.1.150 `claude --bg` detaches in ~4s and writes only a launch banner (`backgrounded · <id>`) to the captured `solve-bg-stdout-N.log` — the agent's real transcript goes to the detached session (`claude logs <id>`). So the old completion probes (`backgrounded · ` as a "terminal" marker; `pushed PR #N`, which has zero producers; `merge-bg-stdout-<pr>.log`, which is never written) could never reflect real state. The version-independent signals are: PR existence/number via `gh pr list --json number,closingIssuesReferences,headRefName` (every solver PR carries a `Closes #N` link and a `feat/N-` head), merge completion via `gh pr view <pr> --json state == MERGED`, and the trust verdict via the existing file-based locator (`uberdev_goal_locate_review_pr_audit_by_pr`) + `uberdev_goal_read_trust_signal`. Solver liveness, used only to distinguish "still working" from "died" (never to gate review-readiness), is `claude agents --json` filtered by cwd + status.

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
    _uberdev_goal_reap_zombies || true
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
all_pr_count="$(awk -v c1=1 '{print $c1}' "$UBERDEV_TMPDIR/goal-$GOAL_ID-pr-states.tsv" \
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
  _uberdev_goal_reap_zombies || true
  print_summary "$cycle"
  exit 1
fi

_rolled_over=${#queue[@]}             # Phase-1 carry-over count BEFORE merge (issue #220, AC ❹)
uberdev_goal_audit goal_cycle_completed \
  "{\"cycle\":$cycle,\"new_candidates\":${#new_candidates[@]},\"overflow_count\":${overflow_count:-0},\"rolled_over\":$_rolled_over}"
queue=("${queue[@]}" "${new_candidates[@]}")
cycle=$(( cycle + 1 ))
# Q4 — reset per-cycle accumulators before looping to Phase 1 (overflow_count
# is per-cycle; overflow_detected gates the per-cycle truncation above).
overflow_count=0
overflow_detected=0
uberdev_goal_write_run_state || { echo "goal: failed to persist run-state before loop-back" >&2; exit 3; }
# loop back to Phase 1
```

**Blocker-overflow handler (D13).** When the upstream `/review-pr` run halted with too many BLOCKER findings (more than the file-issues cap), its audit JSON carries `halted_due_to_overflow: true` at the top level. **Detection lives in Phase 2b** (red signal case) where `$audit_json` and `$pr_num` are in scope; it sets `overflow_detected=1`. Phase 3's truncation step then:

- (Phase 2b already transitioned the PR to `red-held` for the red trust signal — overflow is functionally identical to RED, so the transition is shared);
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
# overflow_detected is set in Phase 2b's red case when any PR's /review-pr
# audit JSON carried halted_due_to_overflow:true. Here in Phase 3 we apply
# the first-10 truncation (no PR transition — Phase 2b already did that).
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
| Stuck-loop (goal-level) | `goal_circuit_breaker` with `reason=stuck_loop` | 1 | `watch_secs >= _UBERDEV_GOAL_STUCK_SECS` (4h) at top of Phase 2 iteration. |
| Stuck-loop (merge_barrier) | `goal_circuit_breaker` with `reason=stuck_loop` + `phase=merge_barrier` | 1 | `uberdev_goal_barrier_breaker_check` fires when `now - barrier_start_ts >= BARRIER_TIMEOUT_S` (issue #211, Phase 2c). The `phase=merge_barrier` field distinguishes this from the goal-level emitter above; payload also carries `elapsed_s` and `pending_prs`. |
| Merge-failed | `goal_circuit_breaker` with `reason=merge_failed` | 1 | `/merge` returned `conflict` or `hook_failed`, or the PR was CLOSED without merging (Phase 2 step 2d). |

**Human-readable summary line.** Print to stdout (NOT stderr — this is the operator's success-or-failure narrative) before exit:

```
goal <GOAL_ID>: cycles=<N>/<MAX> prs_merged=<M> prs_held=<H> issues_resolved=<R> wall_secs=<S>
```

The held-PR list (each row `pr=<num> state=<yellow-held|red-held> blocks=#<i1>,#<i2>,…`) is the **post-mortem surface** — it tells the operator which PRs need human attention. It is printed after the summary line, one row per held PR.

```bash
# #171 — print_summary reads GOAL_ID/MAX_CYCLES/watch_start from the calling
# shell and calls uberdev_goal_* helpers that gate on the UBERDEV_GOAL_ID env.
# Every caller (the Phase 1/2/3 fences) rehydrates that state via
# uberdev_goal_read_run_state at fence top (which also re-exports UBERDEV_GOAL_ID
# + UBERDEV_TMPDIR). Do NOT call print_summary from a block that has not run that
# rehydration — it is never called from Phase 0.
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
  issues_resolved="$(awk -v c1=1 -v c2=2 '$c2=="resolved" || $c2=="resolved-by-no-action" {print $c1}' \
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

Called from Phase 2 step 2d on every `merging → merged` PR transition, for each PR currently in `yellow-held` or `red-held`. The body of the rule is implemented by `lib/goal-state.sh::_uberdev_goal_check_unblock`; the 5-step contract:

1. **Fetch held PR body.** `gh pr view $held_pr --json body --jq '.body'`, capped at `_UBERDEV_GOAL_BODY_CAP` (64 KiB) via `head -c` to bound the regex-parse cost (R1 / T1 — without the cap, a 10 MB PR body could ReDoS the parse loop or starve memory).
2. **Line-split and match against `BLOCKS_LINE_REGEX`.** Each line is fed to bash `[[ =~ ]]` against the anchored shape `^Blocks: #([0-9]+)$` — anchored, no quantifiers under user control, ReDoS-safe (D9 + T1). Non-matching lines are skipped silently (a held PR body need not contain a Blocks line — in which case nothing is unblocked).
3. **Build blocking-issue numbers.** Capture group 1 of each match is re-validated by `_uberdev_goal_validate_int` (defence in depth — anchored `[0-9]+` already passed it, but a second check costs nothing). For each number, query `gh issue view $N --json state --jq '.state'`.
4. **If all blocking issues are CLOSED, re-dispatch `/uberdev:review-pr $held_pr`** via `_uberdev_goal_dispatch_review_pr` (D18 full re-review — including Phase 3 CI Health re-evaluation; the no-shortcut path is mandatory because the upstream merge that triggered this unblock may have changed CI dependencies). If any blocking issue is still OPEN, do nothing this iteration; the unblock check will re-run on the next merged-PR transition.
5. **Emit `goal_unblock_triggered` event** with payload `{pr, blocking_issues: […]}`. This event is the durable record that the unblock fired; consumers can replay it from `goal-<id>.jsonl` to reconstruct the held-PR DAG.

**Completion half (Phase 2 step 2e — #159).** The unblock rule's `/review-pr` dispatch in step 4 is fire-and-forget; it is **Phase 2 step 2e**, the held-PR re-review poll, that closes the loop. On every Phase 2 iteration, step 2e walks every PR currently in `yellow-held` / `red-held`, compares the live latest audit (`uberdev_goal_locate_review_pr_audit_by_pr`) against the previously-consumed audit (`uberdev_goal_get_last_held_audit`), and — when they differ — applies the next state transition based on the new audit's trust signal: `green → green` (eligible for merge in next cycle's step 2c), severity-flip → `{yellow,red}-held → {red,yellow}-held` re-classification, or same-severity → no transition. Without step 2e, the dispatch in step 4 had no consumer, and the held PR was permanently orphaned (the bug issue #159 captured).

## Scoped relaxations

`/goal` is the one place in UberDev where three otherwise-strict /uberdev conventions are deliberately relaxed (RFC §2.3). Every relaxation is scoped to `/goal` only — the relaxed behaviour does NOT leak to standalone `/turbo`, `/merge`, or `/review-pr` invocations.

1. **`feedback_merge_independent`: `/merge` auto-chain allowed inside `/goal`.** The global rule "merge is a deliberate user-invoked command" still holds for standalone use. Inside `/goal`, Phase 2 step 2c auto-dispatches `/merge` for any PR that transitions to `green`, subject to:
   - `uberdev_goal_should_automerge` provenance check (UBERDEV_GOAL_ID env-var must be set — outside `/goal` it isn't, so the auto-merge refuses);
   - per-PR attempt counter cap (`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3` — after 3 attempts the same PR is held for human inspection);
   - YELLOW/RED PRs are NEVER auto-merged (D17 forbidden transitions).

2. **`feedback_brainstorm_no_gates`: `/uberdev:orchestrator` runs non-interactive (no gates).** Phase 1 dispatches `/uberdev:orchestrator --turbo` directly (issue #248), and Phase 0 exports `AUTO_MODE=1` plus `UBERDEV_TURBO=1` (via `BG_TURBO_ENV` in `lib/dispatch.sh`) so the orchestrator child runs in unattended mode. Brainstorm / Q&A approval gates are skipped; the medium/large tier orchestrator runs with its always-on agent reviewer pair instead of human checkpoints. This is consistent with the global memory `feedback_brainstorm_no_gates` and `feedback_quality_over_speed` — quality comes from parallel research + always-on reviewers, not approval prompts.

3. **YELLOW handling: YELLOW PRs are NEVER merged — they are held for re-review.** Standalone `/merge` (with `--accept-critical-deferred`) can land a YELLOW PR; inside `/goal` this is forbidden. The PR-state-machine valid-transitions table in `_uberdev_goal_pr_state_machine_valid` returns non-zero for `yellow-held → merging` (D17); the only way out of `yellow-held` is `→ green` (after a successful `/review-pr` re-review that resolves the CRITICAL findings).

**Backend inheritance (D15).** Backend resolution is the responsibility of Phase 0, propagates to children via the inherited env table, and stays stable across cycles:

- **Phase 0 resolves once.** `uberdev_dispatch_preflight` sets `UBERDEV_RESOLVED_BACKEND` for the whole run; no per-cycle re-resolution at the goal level.
- **Phase 1 no longer forwards `--backend=` as a CLI arg.** The `/uberdev:orchestrator` invocation does not accept a `--backend=` flag, so backend is *not* threaded through argv — only through the env table.
- **Env-var inheritance via `claude --bg` is the canonical mechanism.** `claude --bg` inherits the parent shell's full env table by default; every child (orchestrator, plus the Phase 2 `/merge` and `/review-pr` dispatches in `lib/goal-state.sh::_uberdev_goal_dispatch_{merge,review_pr}`) re-resolves the backend in its own preflight from `UBERDEV_RESOLVED_BACKEND`.
- **Orthogonal to `BG_TURBO_ENV`.** The env-var path carries `UBERDEV_RESOLVED_BACKEND`; `BG_TURBO_ENV` carries only `UBERDEV_TURBO` + `SKIP_PERMISSIONS`. Both reach the child via independent mechanisms (env table for backend, the BG_TURBO_ENV array-wrap for the permission/turbo flags).
- **Per-cycle re-resolution forbidden.** A transient `claude --version` flake mid-run must not silently swap backends — splitting a single goal's solvers across incompatible dispatch mechanisms. Each backend (`claude-bg` / `wezterm` / `background`) has its own session-management and worktree conventions that must stay stable across cycles so the gh + file detection signals (PR discovery via `closingIssuesReferences`, liveness via `claude agents --json` cwd matching, verdict via the file-based locator — issue #180) resolve consistently for every solver in the run.
