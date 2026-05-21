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
GOAL_CIRCUIT_BREAKER_REASONS='max_cycles|nonconvergence|stuck_loop|merge_failed'
GOAL_PR_STATE_ENUM='dispatched|pushed-reviewing|green|yellow-held|red-held|merging|merged|merge-failed'
GOAL_ISSUE_STATE_ENUM='input|solving|pr-pushed|resolved|failed'
TRUST_SIGNAL_ENUM='green|yellow|red|stale|missing'
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
- **`GOAL_CIRCUIT_BREAKER_REASONS`** — the 4 halt reasons emitted by Phase 2/3/4 inside the `goal_circuit_breaker` payload's `.reason` field. The set is closed; new reasons require an RFC amendment.
- **`GOAL_PR_STATE_ENUM`** — the 8 states the PR machine in `_uberdev_goal_pr_state_machine_valid` recognises; `merged` and `merge-failed` are terminal. `yellow-held → merging` and `red-held → merging` are forbidden (D17).
- **`GOAL_ISSUE_STATE_ENUM`** — the 5 states the issue machine recognises; `pr-pushed → resolved` and the two `→ failed` transitions are the only sinks.
- **`TRUST_SIGNAL_ENUM`** — the 5 values `uberdev_goal_read_trust_signal` returns. `stale` (phase2_5 missing in audit JSON) and `missing` (audit JSON absent) both trigger `_uberdev_goal_dispatch_review_pr` rather than an assumed GREEN (D17).
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
   # UBERDEV_RESOLVED_BACKEND is now exported.
   ```

5. **Generate `GOAL_ID`.** Random suffix per D4 — NEVER derived from `$@` or issue numbers (those are attacker-controlled; using them would let a caller collide TMPDIR paths):

   ```bash
   GOAL_ID="goal-$(date +%s)-$(mktemp -u XXXXXXXX | tr -d '/' | head -c 8)"
   export UBERDEV_GOAL_ID="$GOAL_ID"
   ```

6. **Source `lib/goal-state.sh`; call `uberdev_goal_state_init "$GOAL_ID"`.** This truncate-creates the per-goal state files (`goal-<id>.jsonl`, `goal-<id>-pr-states.tsv`, `goal-<id>-issue-states.tsv`, `goal-<id>-fingerprints.tsv`, `goal-<id>-merge-attempts.tsv`) under `$UBERDEV_TMPDIR` and refuses unsafe path characters (T4):

   ```bash
   [ -r "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/lib/goal-state.sh"
   uberdev_goal_state_init "$GOAL_ID" || exit 1
   ```

7. **Emit `goal_dispatched` event** with `{goal_id, cycle: 0, issues, dry_run, backend}` payload. This is the audit anchor — `cycle: 0` distinguishes the initial dispatch from the Phase 1 per-cycle dispatch:

   ```bash
   issues_json="$(printf '%s\n' "${queue[@]}" | jq -R . | jq -sc .)"
   uberdev_goal_audit goal_dispatched \
     "{\"goal_id\":\"$GOAL_ID\",\"cycle\":0,\"issues\":$issues_json,\"dry_run\":$dry_run,\"backend\":\"$UBERDEV_RESOLVED_BACKEND\"}"
   ```

7a. **Initialize cycle counter + goal-level wall-clock anchor.** `cycle` is the per-cycle counter referenced by Phase 2/3/4 (audit payloads, MAX_CYCLES check, fingerprint repeat detector). `watch_start` is the **goal-level** wall-clock anchor — it must persist across cycle iterations so the 4h stuck-loop circuit breaker (`_UBERDEV_GOAL_STUCK_SECS`) measures total goal wall-clock, not per-cycle wall-clock (RFC §3.3 intent: the 4h cap is the goal-level safety net).

   ```bash
   cycle=1
   watch_start="$(date +%s)"
   ```

8. **If `--dry-run`: print planned cycle-1 dispatch list + watch-loop outline, exit 0** (D16). The dry-run path is the audit/preview surface — no `gh` calls, no agent spawns, no merges. Emit the resolved `MAX_CYCLES`, the resolved `UBERDEV_RESOLVED_BACKEND`, the issue queue, and the planned audit events ("would emit goal_dispatched", "would dispatch /turbo for issues …", "would poll solve-bg-stdout-N.log per issue"), then exit 0 cleanly.

9. **`gh api rate_limit` soft pre-flight (Q5 tertiary).** Warn-only — never halt. Per cycle the watcher generates roughly `5 × N × 60` `gh` calls; rate-limit exhaustion mid-run is the highest-likelihood "stuck loop" cause that's NOT a real bug, so surface it up-front:

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
# watch_start is set in Phase 0 (step 7a) — goal-level wall-clock anchor.
# The 4h stuck-loop check below measures total goal wall-clock, not per-cycle.
gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT

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
  for issue in "${active_issues[@]}"; do
    log="$UBERDEV_TMPDIR/solve-bg-stdout-$issue.log"
    if [ -f "$log" ] && grep -q 'backgrounded · ' "$log" 2>/dev/null; then
      audit_json="$(uberdev_goal_locate_review_pr_audit "$issue")"
      signal="$(uberdev_goal_read_trust_signal "$audit_json")"
      pr_num="$(uberdev_goal_extract_pr_num_from_log "$log")"
      case "$signal" in
        green)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing green
          ;;
        yellow)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing yellow-held
          ;;
        red)
          uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
          ;;
        stale|missing)
          # D17: never assume GREEN on missing phase2_5 — re-dispatch /review-pr
          _uberdev_goal_dispatch_review_pr "$pr_num"
          ;;
      esac
    else
      any_active=1
    fi
  done

  # 2b. Dispatch /merge for any new GREEN PRs
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" green); do
    if uberdev_goal_should_automerge "$GOAL_ID" "$pr"; then
      _uberdev_goal_dispatch_merge "$pr"
      uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" green merging
    fi
  done

  # 2c. Drive /merge transitions
  for pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" merging); do
    merge_log="$UBERDEV_TMPDIR/merge-bg-stdout-$pr.log"
    [ -f "$merge_log" ] && grep -q 'backgrounded · ' "$merge_log" 2>/dev/null || continue
    result="$(uberdev_goal_read_merge_result "$pr")"
    case "$result" in
      success)
        uberdev_goal_pr_state_transition "$GOAL_ID" "$pr" merging merged
        for held_pr in $(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held red-held); do
          _uberdev_goal_check_unblock "$held_pr"
        done
        ;;
      conflict|hook_failed)
        uberdev_goal_audit goal_circuit_breaker \
          "{\"reason\":\"merge_failed\",\"pr\":$pr,\"result\":\"$result\"}"
        print_summary "$cycle"
        exit 1
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
# Snapshot goal start for the createdAt filter — only consider findings filed
# during THIS goal run, not pre-existing review-pr-finding issues that pre-date
# the cycle. The TZ-Z timestamp lines up with gh's ISO-8601 createdAt format.
goal_start_iso="$(date -u -r "$watch_start" +%FT%TZ 2>/dev/null \
  || date -u -d "@$watch_start" +%FT%TZ)"

# In-process gh query — mirror discover.sh:152-183 mktemp/EXIT-trap stderr
# isolation pattern (no shell-piped --template, never an external jq pipe).
# Top-level `trap … RETURN` would never fire (RETURN fires inside functions);
# EXIT is the correct script-level cleanup hook.
findings_err="$(mktemp)"
trap 'rm -f "$findings_err"' EXIT

# Build the optional --only-mine filter via env-injected GH_USER (gh resolves
# .author.login via env passthrough; --jq receives `env.GH_USER` literal).
if [ "$only_mine" = "1" ]; then
  GH_USER="$(gh api user --jq '.login')"
  export GH_USER
  jq_filter='[.[] | select(.body | test("\\*\\*Tier:\\*\\* (BLOCKER|CRITICAL)")) | select(.createdAt > $start) | select(.author.login == env.GH_USER)] | map(.number)'
else
  jq_filter='[.[] | select(.body | test("\\*\\*Tier:\\*\\* (BLOCKER|CRITICAL)")) | select(.createdAt > $start)] | map(.number)'
fi

candidates_json="$(gh issue list --label "$FINDING_LABEL" --state open \
  --json number,body,createdAt,author --limit 100 \
  --jq "$jq_filter" --arg start "$goal_start_iso" 2>"$findings_err")"
[ -s "$findings_err" ] && cat "$findings_err" >&2

# Convert JSON array to bash array of issue numbers.
mapfile -t new_candidates < <(printf '%s' "$candidates_json" | jq -r '.[]')
```

For each candidate, extract the fingerprint and check for repeat:

```bash
for issue in "${new_candidates[@]}"; do
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
- If `new_candidates` is empty AND every PR in this run is in `{merged, merge-failed}`: convergence reached, emit `goal_converged`, exit 0. `merge-failed` PRs are counted as terminal-converged because the merge-failed circuit breaker would have already fired upstream — reaching this state means every PR has been driven to a terminal state.
- Otherwise: emit `goal_cycle_completed` with the cycle summary `{cycle, prs_merged, prs_held, issues_resolved, new_candidates}`, set `queue ← new_candidates`, increment `cycle`, and loop back to Phase 1.

```bash
if [ "$cycle" -ge "$MAX_CYCLES" ] && [ "${#new_candidates[@]}" -gt 0 ]; then
  uberdev_goal_audit goal_circuit_breaker \
    "{\"reason\":\"max_cycles\",\"cycle\":$cycle,\"max\":$MAX_CYCLES,\"queued\":${#new_candidates[@]}}"
  print_summary "$cycle"
  exit 1
fi

terminal_prs="$(uberdev_goal_list_prs_in_state "$GOAL_ID" merged \
  ; uberdev_goal_list_prs_in_state "$GOAL_ID" merge-failed)"
all_pr_count="$(awk '{print $1}' "$UBERDEV_TMPDIR/goal-$GOAL_ID-pr-states.tsv" \
  | sort -u | wc -l)"
terminal_count="$(printf '%s\n' "$terminal_prs" | grep -c . || true)"
if [ "${#new_candidates[@]}" = "0" ] && [ "$terminal_count" = "$all_pr_count" ]; then
  uberdev_goal_audit goal_converged \
    "{\"cycle\":$cycle,\"prs\":$all_pr_count}"
  print_summary "$cycle"
  exit 0
fi

uberdev_goal_audit goal_cycle_completed \
  "{\"cycle\":$cycle,\"new_candidates\":${#new_candidates[@]}}"
queue=("${new_candidates[@]}")
cycle=$(( cycle + 1 ))
# loop back to Phase 1
```

**Blocker-overflow handler (D13).** When the upstream `/review-pr` run halted with too many BLOCKER findings (more than the file-issues cap), its audit JSON carries `halted_due_to_overflow: true` at the top level. Phase 3 detects this when reading the `/review-pr` audit JSON for any PR currently in `pushed-reviewing` (Phase 2a flow path) and:

- transitions the PR straight to `red-held` (BLOCKER overflow is functionally identical to RED — too many issues to merge through);
- queues only the first 10 candidate issues for the next cycle (the upstream agent already truncated the issue-file list at the cap; the queue cap mirrors that ceiling);
- surfaces the overflow count in the `goal_cycle_completed` summary `{overflow_count: N}`;
- **does NOT halt the entire goal** — `halted_due_to_overflow` is a per-PR cycle-management signal, not a goal-level circuit breaker. The goal continues to its next cycle and may converge once the overflow PR's issues are resolved.

```bash
halted_overflow="$(gh_jq_or_jq "$audit_json" '.halted_due_to_overflow // false')"
if [ "$halted_overflow" = "true" ]; then
  uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held
  new_candidates=("${new_candidates[@]:0:10}")
  # surfaced in cycle summary; goal continues — do NOT halt.
fi
```

## Phase 4 — Converge / Halt

Every exit path from this skill emits exactly one terminal audit event AND prints exactly one human-readable summary line to stdout:

**Exit paths (verbatim, in priority order):**

| Path | Audit event | Exit code | Trigger |
|---|---|---|---|
| Convergence | `goal_converged` | 0 | `new_candidates` empty AND every PR in `{merged, merge-failed}` (Phase 3 terminal check). |
| Max-cycles cap | `goal_circuit_breaker` with `reason=max_cycles` | 1 | `cycle >= MAX_CYCLES` AND `new_candidates` non-empty (Phase 3). |
| Non-convergence | `goal_circuit_breaker` with `reason=nonconvergence` | 1 | Fingerprint repeat detected by `uberdev_goal_check_fingerprint_repeat` (Phase 3 per-candidate loop). |
| Stuck-loop | `goal_circuit_breaker` with `reason=stuck_loop` | 1 | `watch_secs >= _UBERDEV_GOAL_STUCK_SECS` (4h) at top of Phase 2 iteration. |
| Merge-failed | `goal_circuit_breaker` with `reason=merge_failed` | 1 | `/merge` returned `conflict` or `hook_failed` (Phase 2 step 2c). |

**Human-readable summary line.** Print to stdout (NOT stderr — this is the operator's success-or-failure narrative) before exit:

```
goal <GOAL_ID>: cycles=<N>/<MAX> prs_merged=<M> prs_held=<H> issues_resolved=<R> wall_secs=<S>
```

The held-PR list (each row `pr=<num> state=<yellow-held|red-held> blocks=#<i1>,#<i2>,…`) is the **post-mortem surface** — it tells the operator which PRs need human attention. It is printed after the summary line, one row per held PR.

```bash
print_summary() {
  local cycles="$1" prs_merged prs_held issues_resolved wall_secs
  prs_merged="$(uberdev_goal_list_prs_in_state "$GOAL_ID" merged | grep -c . || true)"
  prs_held="$(uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held; \
              uberdev_goal_list_prs_in_state "$GOAL_ID" red-held)"
  prs_held_count="$(printf '%s\n' "$prs_held" | grep -c . || true)"
  issues_resolved="$(awk '$2=="resolved" {print $1}' \
    "$UBERDEV_TMPDIR/goal-$GOAL_ID-issue-states.tsv" | grep -c . || true)"
  wall_secs="$(( $(date +%s) - watch_start ))"
  printf 'goal %s: cycles=%s/%s prs_merged=%s prs_held=%s issues_resolved=%s wall_secs=%s\n' \
    "$GOAL_ID" "$cycles" "$MAX_CYCLES" "$prs_merged" "$prs_held_count" \
    "$issues_resolved" "$wall_secs"
  printf '%s\n' "$prs_held" | while read -r p; do
    [ -z "$p" ] && continue
    body="$(gh pr view "$p" --json body --jq '.body' 2>/dev/null \
      | head -c "$_UBERDEV_GOAL_BODY_CAP")"
    blocks="$(printf '%s\n' "$body" | grep -E '^Blocks: #[0-9]+$' \
      | sed -E 's/^Blocks: #([0-9]+)$/#\1/' | paste -sd, -)"
    printf '  pr=%s blocks=%s\n' "$p" "${blocks:-none}"
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

## Scoped relaxations

`/goal` is the one place in UberDev where three otherwise-strict /uberdev conventions are deliberately relaxed (RFC §2.3). Every relaxation is scoped to `/goal` only — the relaxed behaviour does NOT leak to standalone `/turbo`, `/merge`, or `/review-pr` invocations.

1. **`feedback_merge_independent`: `/merge` auto-chain allowed inside `/goal`.** The global rule "merge is a deliberate user-invoked command" still holds for standalone use. Inside `/goal`, Phase 2 step 2b auto-dispatches `/merge` for any PR that transitions to `green`, subject to:
   - `uberdev_goal_should_automerge` provenance check (UBERDEV_GOAL_ID env-var must be set — outside `/goal` it isn't, so the auto-merge refuses);
   - per-PR attempt counter cap (`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3` — after 3 attempts the same PR is held for human inspection);
   - YELLOW/RED PRs are NEVER auto-merged (D17 forbidden transitions).

2. **`feedback_brainstorm_no_gates`: `/turbo` runs non-interactive (no gates).** Phase 1 forwards `--turbo` to every child dispatch, which sets `AUTO_MODE=1` in solve-pipeline. Brainstorm / Q&A approval gates are skipped; the medium/large tier orchestrator runs with its always-on agent reviewer pair instead of human checkpoints. This is consistent with the global memory `feedback_brainstorm_no_gates` and `feedback_quality_over_speed` — quality comes from parallel research + always-on reviewers, not approval prompts.

3. **YELLOW handling: YELLOW PRs are NEVER merged — they are held for re-review.** Standalone `/merge` (with `--accept-critical-deferred`) can land a YELLOW PR; inside `/goal` this is forbidden. The PR-state-machine valid-transitions table in `_uberdev_goal_pr_state_machine_valid` returns non-zero for `yellow-held → merging` (D17); the only way out of `yellow-held` is `→ green` (after a successful `/review-pr` re-review that resolves the CRITICAL findings).

**Backend inheritance (D15).** Backend resolution is performed **once** by Phase 0 via `uberdev_dispatch_preflight`, which sets `UBERDEV_RESOLVED_BACKEND`. Every `/turbo`, `/merge`, and `/review-pr` child dispatch in this run forwards `--backend=$UBERDEV_RESOLVED_BACKEND` so the entire goal uses a single, deterministic backend. Per-cycle re-resolution is forbidden — it would let a transient `claude --version` flake mid-run silently swap backends and corrupt the agent-stdout polling contract (every backend emits the `backgrounded · ` marker, but the path conventions for `solve-bg-stdout-N.log` and `merge-bg-stdout-N.log` are backend-specific in a way that must remain stable across cycles).
