# RFC 0005 — `/uberdev:goal` autonomous convergence orchestrator

| Field            | Value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| **Status**       | Accepted (2026-05-21)                                                |
| **Author**       | TheFJK                                                               |
| **Created**      | 2026-05-21                                                           |
| **Targets**      | new `plugins/uberdev/commands/goal.md`, new `plugins/uberdev/skills/goal-pipeline/SKILL.md`, new `plugins/uberdev/lib/goal-state.sh` |
| **Supersedes**   | —                                                                    |
| **Tracking**     | — (to be filed)                                                      |
| **Tier**         | Large (multi-command orchestrator, state machine, new contract for autonomous loops) |

---

## 1. Summary

Add a new top-level command `/uberdev:goal <issue> [<issue> ...]` that drives a self-replenishing autonomous loop until **every PR landing from those issues is GREEN-merged**. Each cycle:

1. Dispatches one `/uberdev:turbo` agent per input issue (which itself auto-runs `/uberdev:review-pr` post-push).
2. Polls dispatched agents + opened PRs for completion and trust-signal colour.
3. Per PR: GREEN → `/uberdev:merge`. YELLOW (critical deferred) → hold PR, queue its critical issues. RED (blocker deferred) → hold PR, queue its blocker issues.
4. Collects newly-filed `review-pr-finding` issues filtered to `BLOCKER` + `CRITICAL` tier only (major/important skipped).
5. If queue non-empty → cycle N+1 with the queue as input. If empty → converged GREEN, terminate.
6. When a held PR's blocking issue is resolved (its solving PR merges), re-run `/review-pr` on the held PR (option B from design discussion — verifies fix on rebased head), then `/merge` if GREEN.

The loop terminates when every PR opened during the run is merged AND no open blocker/critical `review-pr-finding` issues remain in scope.

## 2. Motivation

### 2.1 The gap today

`/uberdev:turbo` fans out N issues to parallel autonomous agents, each ending at a pushed PR with an auto-run `/review-pr` trust trail. The user then **manually**:

- Decides which PRs to merge (per `feedback_merge_independent` rule).
- Reads `/review-pr` output to spot critical findings.
- Manually opens `/uberdev:solve` on each new finding-issue from Phase 2.5.
- Manually re-merges held PRs after their blockers resolve.

For a 5-issue `/turbo` run with finding-issues, that's typically 30–60 minutes of cognitive overhead per cycle, often spread across hours of wall-clock — and the human is the only thing tracking the dependency graph between blocked PRs and their unblocking issues.

### 2.2 What `/goal` adds

`/goal` is an explicit, opt-in autonomous convergence loop. It encodes:

- The chain `/turbo → /review-pr (auto) → /merge if GREEN` as a state machine.
- The dependency graph between blocked PRs and unblocking issues.
- The "iterate until GREEN" invariant: don't accept YELLOW (critical-deferred) merges, recurse on the deferred findings instead.

It is **not** a replacement for `/turbo` (which still owns single-shot parallel solve) or for `/uberdev:merge` (which still runs standalone for human-controlled merges). It is an orchestrator that composes them.

### 2.3 Scoped exceptions to project rules

Three project-level rules are scoped-relaxed **inside** `/goal` only — the user has opted in by invoking the command. Outside `/goal`, the rules continue to hold.

| Rule                                                                                              | Scoping inside `/goal` |
| ------------------------------------------------------------------------------------------------- | ---------------------- |
| `feedback_merge_independent.md` — never auto-chain `/merge` from `/turbo` / `/review-pr` / `finish-branch` | Auto-chain allowed — `/goal` is the explicit opt-in wrapper |
| CLAUDE.md mandate — `/review-pr` runs after every PR push                                          | Inherited automatically via `/turbo`'s existing `--turbo` chain |
| Trust signal YELLOW is mergeable today (critical-deferred PRs merge silently)                     | YELLOW gated — no merge until critical findings resolved and PR re-reviews GREEN |

## 3. Design

### 3.1 Command surface

```
/uberdev:goal <issue> [<issue> ...] [--max-cycles=N] [--only-mine] [--dry-run]
```

| Flag             | Default | Meaning |
| ---------------- | ------- | ------- |
| `--max-cycles=N` | `5`     | Hard ceiling on cycle count. Natural fixpoint (no new blocker/critical) terminates earlier. |
| `--only-mine`    | off     | Filter cycle-N+1 candidates to issues authored by current user (`gh issue list --search "author:@me"`). Off = pull any open `review-pr-finding` in the repo. |
| `--dry-run`      | off     | Print the planned cycle 1 dispatch + watch loop, exit. No `/turbo`, no `/merge`. |

**No alias collision**: built-in Claude Code `/goal` (v2.1.139+) is a session-scoped Stop-hook wrapper, lives in a different namespace. We use the namespaced form. **Proposed short alias: `/ubergoal`** (matches user's own wording; avoids built-in collision; provisioned via `lib/aliases-sync.sh` per `project_uberdev_aliases_multi_surface.md`).

### 3.2 State model

#### 3.2.1 PR states

| State              | Entered when                                                | Watcher action                     |
| ------------------ | ----------------------------------------------------------- | ---------------------------------- |
| `dispatched`       | `/turbo <issue>` started, no PR pushed yet                  | Poll `claude agents` + per-agent stdout log |
| `pushed-reviewing` | PR pushed; `/review-pr` running in the same `/turbo` agent  | Poll for review completion (audit JSON) |
| `green`            | `/review-pr` emitted GREEN trust signal                     | Dispatch `/uberdev:merge <PR#>`    |
| `yellow-held`      | `/review-pr` emitted YELLOW (`by_severity.critical > 0`)    | Hold; record critical fingerprints + filed-issue URLs for cycle N+1 |
| `red-held`         | `/review-pr` emitted RED (blocker deferred OR overflow halt)| Hold; record blocker fingerprints + filed-issue URLs for cycle N+1 |
| `merging`          | `/uberdev:merge` dispatched                                  | Poll merge agent log               |
| `merged`           | `/merge` returned success; PR closed by merge                | Final state — no further action    |
| `merge-failed`     | `/merge` halted on unresolvable conflict / hook failure     | Halt entire goal; exit non-zero; surface details |

#### 3.2.2 Issue states

| State        | Meaning                                                              |
| ------------ | -------------------------------------------------------------------- |
| `input`      | Initial issue from `$ARGUMENTS` or from a previous cycle's recursion |
| `dispatched` | Pre-spawn guard (#236) — parent has written this row but not yet called `uberdev_dispatch_one`; matched by the Phase-1 skip-check so a leaf-side crash between spawn and the post-spawn `solving` write cannot trigger a silent re-dispatch on the next cycle |
| `solving`    | Dispatched to `/turbo`, no PR yet                                    |
| `pr-pushed`  | Solving PR is in the PR-state machine above                          |
| `resolved`   | Solving PR transitioned to `merged`                                  |
| `failed`     | Solving PR transitioned to `merge-failed`, `/turbo` returned failure, or pre-spawn `dispatched` row aborted on dispatch_one rc!=0 |

#### 3.2.3 Dependency graph

Held PRs reference unblocking issues via the `Blocks: #<PR>` body line that `uberdev:findings-to-issues` writes for BLOCKER/CRITICAL tier rows (confirmed `agents/findings-to-issues.md:156`, `220`).

Watcher rule:

```
On every issue transition to `resolved`:
  for each PR Y in (yellow-held ∪ red-held):
    if any open issue X' that was filed against PR Y was just resolved
       AND no remaining open blocker/critical issues reference PR Y:
       
       → re-evaluate PR Y (OPTION B — verifies fix on rebased head):
         dispatch /uberdev:review-pr <Y>
         on completion:
           GREEN  → dispatch /uberdev:merge <Y>; transition to `merging`
           YELLOW → re-queue new critical findings; stay `yellow-held`
           RED    → re-queue new blocker findings; stay `red-held`
```

### 3.3 Cycle algorithm

```
INITIAL: queue ← $ARGUMENTS (input issues)
         cycle ← 0
         seen_fingerprints ← {}     # for non-convergence detection
         goal_start_ts ← now()
         all_prs ← {}

LOOP:
  cycle ← cycle + 1
  if cycle > MAX_CYCLES:
    halt CIRCUIT_BREAKER_MAX_CYCLES — report queue, exit non-zero
  
  # DISPATCH PHASE
  for issue in queue:
    dispatch `/uberdev:turbo <issue>` via resolved backend
    register issue.state = solving; pr placeholder = dispatched
  
  # WATCH PHASE (per cycle, hard cap 4h wall-clock)
  while any PR in cycle is not in {merged, merge-failed, yellow-held, red-held}
        AND watch_clock < 4h:
    
    sleep 60s
    
    # 1) Drive PR transitions from agent state + audit JSON
    for each dispatched /turbo agent:
      status ← claude agents status <agent-id>
      if status == returned:
        audit ← read $UBERDEV_TMPDIR/solve-bg-stdout-<N>.log + per-PR review-pr audit JSON
        derive PR state per §3.2.1 and transition
    
    # 2) Dispatch /merge for any new GREEN PRs
    for each PR transitioning to green:
      dispatch `/uberdev:merge <PR#>` via resolved backend
      transition to merging
    
    # 3) Drive /merge transitions
    for each merging PR:
      read merge agent log
      if returned success → transition to merged
      if returned merge-failed → halt entire goal
    
    # 4) Check dependency graph (§3.2.3) on each issue→resolved transition
    for each issue transitioning to resolved:
      apply unblock rule
  
  if watch_clock ≥ 4h:
    halt CIRCUIT_BREAKER_STUCK_LOOP — report dispatched-but-silent agents
  
  # COLLECT NEXT QUEUE
  new_candidates ← gh issue list \
    --label review-pr-finding \
    --state open \
    --json number,body,createdAt,author \
    --limit 100 \
    | jq filter:
        body =~ /\*\*Tier:\*\* (BLOCKER|CRITICAL)/
        AND createdAt > goal_start_ts
        AND issue.number ∉ already_processed_issues
        AND (NOT --only-mine OR author.login == current_user)
  
  # CIRCUIT BREAKER: non-convergence
  for each candidate in new_candidates:
    fp ← extract_fingerprint(candidate.body)  # the <!-- uberdev:review-pr-finding fingerprint=...--> marker
    if fp ∈ seen_fingerprints[cycle - 1]:
      halt CIRCUIT_BREAKER_NONCONVERGENCE \
        — report "fingerprint $fp re-filed after prior cycle resolved it; fix isn't sticking"
  
  seen_fingerprints[cycle] ← {fp for c in new_candidates}
  
  # TERMINATION CHECK
  if new_candidates empty AND all_prs all in {merged, merge-failed}:
    TERMINATE — CONVERGED GREEN
  
  queue ← [c.number for c in new_candidates]
  goto LOOP
```

### 3.4 Termination conditions

| Condition                                                       | Exit  | Audit event             |
| --------------------------------------------------------------- | ----- | ----------------------- |
| All PRs merged AND no new blocker/critical issues filed         | 0     | `goal_converged`        |
| Same finding-fingerprint reappears in 2 consecutive cycles      | 1     | `goal_circuit_breaker` reason=`nonconvergence` |
| `--max-cycles` reached with queue non-empty                     | 1     | `goal_circuit_breaker` reason=`max_cycles` |
| Any `/uberdev:merge` returns `merge-failed`                     | 1     | `goal_circuit_breaker` reason=`merge_failed` |
| Watch-pass exceeds 4h wall-clock without state transitions     | 1     | `goal_circuit_breaker` reason=`stuck_loop` |

### 3.5 Backend dispatch

`/goal` inherits the `lib/dispatch.sh` preflight resolver from `skills/solve-pipeline` (`UBERDEV_RESOLVED_BACKEND` ∈ {`claude-bg`, `wezterm`, `background`}). Per-cycle dispatches:

- **`/uberdev:turbo <issue>`** — forwards backend via `--backend=<name>` arg if set; otherwise inherits resolver default.
- **`/uberdev:merge <PR#>`** — same. Each merge is its own background agent; merges run in parallel across independent PRs (`merge-pipeline` Phase 2.2 chooses per-PR strategy).
- **`/uberdev:review-pr <PR#>`** (re-evaluation case in §3.2.3) — same.

Watcher reads:

- `claude agents` for backend-agnostic status (claude-bg + background)
- `$UBERDEV_TMPDIR/solve-bg-stdout-<issue>.log` per `/turbo` dispatch (already namespaced by issue#)
- Per-PR `/review-pr` audit JSON — path scheme to be specified in `skills/goal-pipeline/SKILL.md`; likely `.claude/audit/review-pr-<PR#>-<run-id>.json` (note: see §9.5 B1/B2 for the canonical path actually written — `.uberdev/runs/<run-id>/review-pr-verdict.json`)
- Per-PR `/merge` audit JSON

### 3.6 Telemetry

New audit events (extending `SOLVE_AUDIT_EVENT_ENUM` per `skills/solve-pipeline/SKILL.md:24`):

```
goal_dispatched         — { goal_id, cycle, issue, pr_state_initial }
goal_pr_transition      — { goal_id, cycle, pr, from_state, to_state, fingerprints? }
goal_unblock_triggered  — { goal_id, cycle, resolved_issue, unblocked_pr }
goal_cycle_completed    — { goal_id, cycle, prs_merged, prs_held, new_issues_queued }
goal_converged          — { goal_id, total_cycles, total_prs_merged, total_issues_resolved, wall_clock_seconds }
goal_circuit_breaker    — { goal_id, reason ∈ {max_cycles, nonconvergence, stuck_loop, merge_failed}, payload }
```

Per-goal artifact: `$UBERDEV_TMPDIR/goal-<goal_id>.jsonl` — append-only event stream, one event per line. Cross-references existing `solve-audit.jsonl` by `goal_id`.

## 4. Edge cases

### 4.1 `/turbo` issue claim collision

`/uberdev:solve`'s small-team issue-claim protocol (v0.28.0) means a `/turbo` dispatch may fail with `claim_collision` if another agent (or human) is already solving the issue. `/goal` handling:

- Treat `claim_collision` as a **soft failure** for that issue; do NOT retry within the same cycle.
- Remove the issue from the cycle's expected-PR set.
- Continue the watch pass with the remaining dispatches.
- Surface the collision in the cycle summary; do NOT halt the entire goal.

### 4.2 Finding-issues filed by OTHER `/review-pr` runs during the goal

If a parallel `/review-pr` run (outside this goal) files a `review-pr-finding` while the goal is running, the watcher will pick it up in `COLLECT_NEXT_QUEUE` unless `--only-mine` is set. This is intentional (broad scope) but documented as a behaviour the user should understand before running.

### 4.3 Recursive blocker chains

PR_A → blocked by issue_B → solved by PR_B → `/review-pr PR_B` → files issue_C → blocks PR_B. Recursive blocker chains are possible. The dependency graph in §3.2.3 handles arbitrary depth — `issue_C` becomes cycle N+2's input, its solving PR resolves issue_C, which transitions PR_B from `red-held` → `green` (after re-review), then `/merge PR_B` unblocks PR_A.

Bounded by `--max-cycles`.

### 4.4 Blocker overflow halt (`halted_due_to_overflow`)

Per `findings-to-issues` agent: if a single `/review-pr` run has >10 deferred blocker/critical findings, it halts with `halted_due_to_overflow=true`. `/goal` reads this from the audit JSON and:

- Transitions the PR to `red-held`.
- Queues only the first 10 filed issues for cycle N+1 (the agent already truncated).
- Surfaces the overflow count in the cycle summary.
- Does NOT halt the entire goal — the overflow is for one PR, not the whole run.

### 4.5 Flag propagation

`/goal` does NOT add flag-forwarding to `/turbo` (`--no-simplify`, `--no-ci-fix`, etc.). If the user wants those, they invoke `/turbo` directly. `/goal` runs the standard `/turbo --turbo` chain with default flags.

### 4.6 RED-override carve-out NOT inherited

`/review-pr` Phase 2.5 offers an `AskUserQuestion` choice "Override — emit GREEN" on blocker-deferred halts (per `commands/review-pr.md:263`). Under `--turbo`, that prompt is suppressed and exits 1. `/goal` dispatches `/turbo`, so the override path never fires from inside `/goal` — RED stays RED, the blocker becomes a cycle N+1 issue. This is by design; the "iterate until GREEN" invariant precludes override merges.

## 5. Open questions

| #   | Question                                                                                                          | Recommendation |
| --- | ----------------------------------------------------------------------------------------------------------------- | -------------- |
| Q1  | Should `/goal` cap parallel `/turbo` dispatches per cycle? Today `/turbo` uses `fanout_concurrency.solve_bg` (default 6). | RESOLVED (issue #211, v0.33.20): default fan-out cap = 3, configurable 1–10 via `goal.max_parallel` / `UBERDEV_GOAL_MAX_PARALLEL` / `--max-parallel=N`. Out-of-range values fall back to the default via `uberdev_read_int_in_range` (stderr warning + audit event). The cap applies to Phase 1 dispatch only; Phase 2 watcher remains single-threaded per RFC 0005 §3.3. |
| Q2  | Does `/goal` need its own claim type (`goal_claim`) so two concurrent `/goal` runs don't collide on issue-set overlap? | Defer — single-user repos don't need it; document the gap in README. |
| Q3  | Per-goal audit sink — separate file or append to `solve-audit.jsonl`?                                              | Separate `goal-<id>.jsonl` for clean post-mortem; cross-reference by `goal_id`. |
| Q4  | When `/review-pr` is re-run in §3.2.3, do we wait for CI again (`/review-pr` Phase 3 — RFC 0001)?                  | Yes — re-review is full `/review-pr`, including Phase 3 CI Health. No shortcut. |

## 6. Rollout

Version bump: **minor** (`feat:`) — additive new command, no breaking changes. Targeting **v0.31.0** (current released: v0.30.0).

Phased landing:

1. **Phase A** (this RFC): merge spec; no code.
2. **Phase B**: implementation — `commands/goal.md` + `skills/goal-pipeline/SKILL.md` + `lib/goal-state.sh` (state-machine library).
3. **Phase C**: tests — `tests/goal.test.sh` mocking `claude --bg` + `gh` + agent returns. Cover: happy-path GREEN convergence, single-cycle YELLOW recursion, blocker-unblock chain, all five circuit-breaker paths.
4. **Phase D**: alias `/ubergoal` provisioned via `lib/aliases-sync.sh` + `commands/install-aliases.md` + `commands/uninstall-aliases.md` + README + `tests/aliases.test.sh` (per `project_uberdev_aliases_multi_surface.md`).
5. **Phase E**: README "Commands" section update + CHANGELOG entry + version bump across all 6 surfaces (per project CLAUDE.md mandatory checklist).

## 7. Non-goals

- No web UI / dashboard.
- No cross-repo orchestration.
- No interaction with the built-in Claude Code `/goal` command (we wrap `/turbo` and `/merge`, not the in-session Stop-hook evaluator).
- No replacement of `/turbo` or `/merge` — both remain user-invocable standalone.
- No revision of `feedback_merge_independent.md` outside `/goal` scope — the rule remains in force for ad-hoc invocations of `/turbo`, `/review-pr`, `finish-branch`, etc.
- No support for merging PRs with `--i-know-what-im-doing` override — RED never becomes mergeable inside `/goal`.

## 8. Memory updates required on landing

When this RFC moves from Draft → Accepted:

- Update `feedback_merge_independent.md` with the `/goal` carve-out (auto-merge scoping-relaxed inside `/goal`; rule unchanged outside).
- New memory note: `project_uberdev_goal_state_machine.md` — references this RFC, summarises PR/issue state transitions and the dependency-graph unblock rule, so future-Claude can answer "how does /goal decide when to merge a held PR?" without re-reading the RFC.

## 9. Design Decisions

This section catalogues the inline-code shorthands (e.g. `// D4 — TMPDIR validation`, `# B1 — correct audit path`) that annotate rationale in `plugins/uberdev/lib/goal-state.sh` and `plugins/uberdev/skills/goal-pipeline/SKILL.md`. Each code is a permanent pointer to its row below; comments stay terse, definitions live here.

Codes are grouped by prefix: **D** (design decisions), **T** (trust/threat boundaries), **Q** (open questions resolved into implementation), **R** (robustness rules), **B** (bug fix / behaviour contracts), **S** (simplify/style rules). Within each table, rows are sorted ascending by numeric suffix. The `See also` column points to existing RFC sections (`§N.M.K` style) when the concept is covered elsewhere in this document; codes with `—` (em-dash) have no other RFC coverage and the row here is the canonical definition. Gaps in numbering (e.g. no `B3`, no `D1`) reflect codes that do not appear in source and are intentionally undefined — defining them would be dead documentation.

> **Namespace note (important):** the `Q*` codes in §9.3 are a different namespace from RFC §5 "Open questions". §5 tracks UNRESOLVED design questions; §9.3 tracks questions that were resolved into implementation decisions during PR #129 development. **`Q1` in §9.3 ≠ `Q1` in §5** — same letter, different table. Future work to rename one of the two namespaces is out of scope for this PR (touches code in PR #129; deferred to a follow-up).

### 9.1 D — Design decisions

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| D2  | Issue state machine: six states `input → dispatched → solving → pr-pushed → resolved`; `dispatched → failed`, `solving → failed`, and `pr-pushed → failed` allowed; no audit event on issue transitions (derived state only). `dispatched` (issue #236) is the pre-spawn guard the parent writes BEFORE `uberdev_dispatch_one` so any leaf-side failure between spawn and the post-spawn `solving` write still leaves a TSV row the Phase-1 skip-check (`dispatched\|solving\|pr-pushed`) can match — closing the silent double-spawn surface where a pre-state-write leaf crash looked identical to "never attempted". | §3.2.2 |
| D3  | Audit helper contract: `uberdev_goal_audit` accepts only enum-validated event names and uses manual-escape JSON framing (mirrors `discover.sh:39-53`); unknown events return rc=1. | §3.6 |
| D4  | GOAL_ID and TMPDIR path-safety rules: `GOAL_ID` is generated with a random suffix, never derived from user-controlled input (attacker could collide TMPDIR paths); `UBERDEV_TMPDIR` is validated against a safe-character allowlist before any file creation. | §3.3 |
| D8  | Auto-merge eligibility gate: `/goal` only auto-merges a PR when (a) `UBERDEV_GOAL_ID` env is set (provenance check — proves the call is inside a `/goal` run) and (b) per-PR merge attempt count is below `_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS` (default 3). | §3.2.3, T5, R5 |
| D9  | All regex patterns over PR/issue body text must use anchored bash `[[ =~ ]]` patterns with no quantifiers under user control; this is the ReDoS safety rule for body-parsing loops. | T1, R1 |
| D12 | `claim_collision` soft-fail semantics: when `solve-pipeline` refuses to dispatch an issue because another agent holds the `uberdev:active` label, `/goal` skips that issue for the cycle (does not retry, does not halt the goal). | §4.1 |
| D13 | Blocker-overflow handler: when `/review-pr` audit JSON contains `halted_due_to_overflow: true`, the PR is treated as RED (same transition), `overflow_detected` is set in Phase 2a (where `$audit_json` and `$pr_num` are in scope), and Phase 3 truncates the next-queue to the first 10 candidates; the goal does NOT halt. | §4.4 |
| D15 | Backend resolution is performed exactly once per `/goal` run (Phase 0 `uberdev_dispatch_preflight`) and the result is forwarded to every child dispatch; per-cycle re-resolution is forbidden because the stdout-log polling contract depends on a stable, backend-specific path convention. Also: the merge-pipeline audit log filename is canonically `audit.jsonl` per `merge-pipeline/SKILL.md §"Audit log JSONL schema"`. | §3.5 |
| D16 | `--dry-run` mode exits before any `gh` call, any agent spawn, and any audit event; specifically `goal_dispatched` must NOT fire on dry-run so the audit log only carries real runs. | §3.1 |
| D17 | YELLOW/RED PRs are never merged inside `/goal`; `yellow-held → merging` and `red-held → merging` are forbidden transitions in the PR state machine. `stale` and `missing` trust signals also never imply GREEN — they trigger a re-dispatch of `/review-pr`. Terminal states `merged` and `merge-failed` are irreversible. | §3.2.1, §2.3 |
| D18 | Every re-review dispatch (unblock rule, stale/missing trust signal) uses full `/uberdev:review-pr` with no incremental shortcut, because the upstream merge that triggered unblock may have changed CI dependencies. | §5 |
| D19 | Crash-restart contract: `_UBERDEV_GOAL_STATE_LOADED` guard prevents double-sourcing within a single process; resume-after-SIGKILL is explicitly out of scope for v1. | — |
| D-211a | `uberdev_goal_register_batch_pr` | Per-PR append to `goal-<id>-batch-prs.tsv` registry with atomic write; seeds `barrier_start_ts` on first registration of the cycle. | — |
| D-211b | `uberdev_goal_batch_all_terminal` | Pure-read predicate over the batch registry; rc 0 iff every row's `terminal_state` ∈ {GREEN, HELD, MERGE_FAILED, MERGED}. Empty registry returns rc 1. | — |
| D-211c | `uberdev_goal_batch_unblock_wait_clear` | Pure-read predicate over the batch registry; rc 0 iff every HELD row's unblock-issue is closed AND its PR carries `review-pr:green`. | — |
| D-211d | `_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL` | Phase 1 dispatch cap default (`3`); range `[1, 10]` via `uberdev_read_int_in_range`. | — |
| D-211e | `_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S` | Phase 2 step 2c wall-clock cap default (`14400` = 4h); range `[60, 86400]`. Timeout escalates to `stuck_loop` (no new circuit-breaker reason). | — |

> The three barrier-internal helpers (`_uberdev_goal_set_batch_terminal_state`, `_uberdev_goal_batch_green_prs_ordered`, `_uberdev_goal_rebase_collision_chain`) are underscore-prefixed private primitives and intentionally do not receive §9 D-code rows, matching the convention from D-codes for existing private helpers.

### 9.2 T — Trust / Threat boundaries

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| T1 | ReDoS threat boundary: user-controlled input (PR body, issue body) reaching a regex match must be capped at 64 KiB before the parse loop AND the regex itself must be anchored with no user-controlled quantifiers. Both controls together bound parse cost to O(1) on hostile input. | D9, R1 |
| T3 | `gh` argument injection threat: every value that will be passed to a `gh` CLI call (PR numbers, issue numbers) must pass `_uberdev_goal_validate_int` before the `gh` call executes. | — |
| T4 | TMPDIR path injection threat: `$UBERDEV_TMPDIR` may be set by an attacker-controlled environment; reject it if it contains any character outside `[A-Za-z0-9_./-]` before creating any file under it. | — |
| T5 | Context provenance threat: auto-merge (and by extension, the per-PR attempt counter that contains it) must only fire when `UBERDEV_GOAL_ID` is set in the environment, ensuring the merge path cannot be triggered from outside a `/goal` run. | §3.2.3, D8 |

### 9.3 Q — Open questions resolved into implementation

> **Namespace note (repeated):** the Q-codes in this table are a different namespace from RFC §5 "Open questions". §5 tracks UNRESOLVED design questions; §9.3 tracks questions that have already been resolved into implementation decisions in PR #129. **`Q1` in §9.3 ≠ `Q1` in §5.**

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| Q1 | Bash EXIT trap singleton: bash only supports one `EXIT` trap per shell; the combined cleanup for `$gh_err` and `$findings_err` temporaries must be registered once in Phase 2 (not overwritten in Phase 3). | — |
| Q4 | Per-cycle overflow accumulator reset: `overflow_count` and `overflow_detected` are per-cycle counters that must be reset to 0 after `goal_cycle_completed` is emitted and before looping back to Phase 1, so the next cycle's summary does not double-count previous-cycle overflow PRs. | §4.4 |
| Q5 | Rate-limit pre-flight: a soft `gh api rate_limit` check at Phase 0 step 10 warns when remaining calls < 1000 (never halts), because rate exhaustion is the most likely non-bug cause of stuck-loop; the threshold is a tertiary warning only. | — |

### 9.4 R — Robustness rules

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| R1 | 64 KiB body cap (`head -c 65536`) on any PR or issue body fetched from `gh` before regex processing; this is the load-bearing ReDoS defence (see T1); without the cap a 10 MB body could exhaust memory or cause catastrophic backtracking. | D9, T1 |
| R3 | `gh` argument-injection robustness: call `_uberdev_goal_validate_int` on every PR/issue number before passing it to any `gh` call; this is the first-line defence against shell-injection via attacker-controlled issue numbers. (See also T3 — R3 is the robustness rule; T3 is the threat it mitigates.) | — |
| R5 | Runaway-loop containment: the per-PR merge-attempt counter cap (`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3`) MUST be enforced via `UBERDEV_GOAL_ID` env forwarding to child dispatches; without env forwarding the cap cannot be queried and the loop will attempt unlimited merges. | D8 |
| R6 | Dispatch completion detection: agent completion is determined by the `backgrounded · ` marker in the stdout log (not the non-existent `claude agents status <id>` API); this marker is a stable, asserted contract across all `lib/dispatch.sh` backends and is the only authoritative completion signal in v1. | §3.5 |

### 9.5 B — Bug fix / Behaviour contracts

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| B1  | Correct audit search surface for `/review-pr` results: the canonical root path is `.uberdev/runs/<run-id>/review-pr-verdict.json`, plus the three checkout-local worktree mirrors under `.claude/worktrees/*`, `.worktrees/*`, and `worktrees/*`; the legacy `.claude/audit/review-pr-<PR>-<run>.json` path was never written by `/review-pr` and silently returned "missing" for every lookup, blocking trust-signal reads forever. | §3.5 |
| B2  | Correct audit path for `/merge` results: the canonical path is `.uberdev/audit.jsonl`; the legacy `.claude/audit/merge-<PR>-<run>.json` path was never written by `/merge` and silently returned "missing", causing Phase 2c to never drive PR transitions. | §3.5 |
| B4  | `uberdev_goal_list_prs_in_state` takes exactly one state argument; calling it with a space-separated string `"yellow-held red-held"` makes the second token a positional no-op — `red-held` PRs are silently excluded from the unblock check. Call the function twice and concatenate results. | — |
| B5  | `gh_jq_or_jq` exit-code contract: callers MUST branch on the return code; rc≠0 means jq failed (malformed JSON or missing filter target) and the result is not a valid trust signal; treating empty stdout as equivalent to rc=0 caused a corrupted audit JSON to fall through to the "phase2_5 missing" path and misclassify the trust signal as `stale`. | — |
| B6  | Two separate bugs share this code: (a) Phase 2a overflow detection must run in the `red` signal case where `$audit_json` and `$pr_num` are in scope (not Phase 3 where they don't exist); (b) Phase 3 must check `gh_rc` for the `gh issue list` call — discarding rc meant a 403 rate-limit appeared as empty candidates, falsely triggering `goal_converged`. | — |
| B7  | Defensive default-case guard in Phase 2c's merge-result `case` statement: any value outside `success|conflict|hook_failed|missing` is a contract drift (e.g., a future enum member not yet handled here) and must halt with `goal_circuit_breaker reason=unknown_merge_result` rather than silently leaving the PR stuck in `merging` forever. | §3.4 |
| B10 | `_uberdev_goal_check_unblock` must surface `gh pr view` failures (rate-limited, transient network, PR deleted upstream) instead of treating empty body as "no Blocks: lines" — silent empty-body would leave a held PR waiting for an unblock check that never succeeds; correct behaviour is to skip the iteration and retry next cycle. | §3.2.3 |
| B11 | In the unblock blocking-issue check, a 404 "Could not resolve to an Issue" `gh` error means the issue was deleted upstream and should be treated as CLOSED (unblock proceeds); all other `gh` errors should skip the unblock check this iteration (NOT treat the issue as OPEN, which would permanently hold the PR). | §3.2.3 |
| B12 | `/goal` and `/merge` share the one canonical verdict selector. It follows only an allowed command-line root (`find -H`), captures candidate bytes once through the existing secure artifact runtime, ranks only the 15-byte `YYYYMMDD-HHMMSS` prefix, requires byte-identical expected-PR artifacts tied at the selected timestamp, ignores known other-PR artifacts, and fails indeterminate when an identity-unknown artifact is newer/equal (or when no target exists). Root symlinks may target external storage, but lexical and physical root identity must remain unchanged throughout the scan. | §3.5 |
| B13 | The selector returns a closed, private snapshot receipt; controllers immediately digest/identity-recapture it, cache only normalized scalar trust fields, clean the carrier, and never reopen either the mutable source pathname or the snapshot later. Missing/null `phases` and a missing `phase2_5` member retain the legacy contract; present Phase 2.5 fields use strict JSON types (booleans are never integers, counts are non-negative integers, and only the named override string is valid). Duplicate keys and malformed PR/SHA identity are **never absence** — that half is unconditional. Indeterminacy is *positional*: an unreadable, duplicate-keyed or shape-invalid candidate is recorded as an unknown timestamp and only forces `indeterminate` when it sits **at or after** the selected target timestamp (`timestamp >= selected_timestamp`), or when it is the only candidate class present. A strictly older malformed candidate is IGNORED and a valid newer verdict is still selected — stale rubbish beside a fresh verdict must not deny the fresh verdict. | §3.5 |
| B14 | `/review-pr` atomically reserves `.uberdev/runs/<RUN_ID>` with plain `mkdir` before fanout. Caller-supplied collisions fail; internally minted IDs retry bounded cryptographic hex discriminators. Setup emits one closed receipt containing the run/root and marker identities plus marker digests, installs no `EXIT` trap, and explicitly abandons only identity-validated setup failures. A fresh-shell final fence rehydrates that receipt and uses the shared exact-name `O_EXCL`/`O_NOFOLLOW` publisher **(POSIX; native Windows substitutes reparse-ancestor rejection for `O_NOFOLLOW`, which has no native equivalent)**; failed publication never unlinks its exact pathname, and markers are retired only after durable success. | §3.5 |

### 9.6 S — Simplify / Style rules

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| S4 | Helper naming convention: all internal helpers in `lib/goal-state.sh` must use the `_uberdev_goal_*` prefix; a short alias `_persist_fp` was dropped in favour of the canonical long name `_uberdev_goal_persist_fp` because the call site is not harmed by the longer name and consistency beats brevity for private helpers. | — |
| S6 | `print_summary` held-PR rows must include the `state=` field (`yellow-held` or `red-held`); the prior implementation merged both lists into bare PR numbers, silently dropping the state field that the prose (RFC §3.2.3) promises. | §3.2.3 |
| S9 | Dry-run mode must suppress ALL side effects including audit events; specifically `goal_dispatched` must not be emitted during `--dry-run` so the audit log remains a record of real runs only. (Paired with D16 which defines the dry-run feature; S9 is the audit-purity constraint.) | §3.1 |

### D220 — /goal bulletproof-loop (issue #220, 2026-05-26)

Single addendum row covering the four orthogonal fixes shipped under issue #220. Bug-fix scope under §2.3 (the auto-merge carve-out): no new RFC; all enum changes are documented here once and reflected in `GOAL_AUDIT_EVENT_ENUM` (SKILL.md:19) + `GOAL_CIRCUIT_BREAKER_REASONS` (SKILL.md:20) + the `uberdev_goal_audit` case arm (goal-state.sh:348) + the version 0.34.4 ratchet.

- **D220a** — `goal.review_grace_secs` config key + `UBERDEV_GOAL_REVIEW_GRACE_SECS` env + `--review-grace-secs=N` CLI arg. Range `[60, 86400]`, default `3600` (60min, up from the previous hardcoded `_UBERDEV_GOAL_REVIEW_GRACE=1800`). Resolution precedent: mirrors `goal.max_cycles` precedence at SKILL.md:103-113. Persisted via `uberdev_goal_write_run_state` and rehydrated + EXPORTed via `uberdev_goal_read_run_state`.
- **D220b** — Locked-marker contract at an atomically reserved `.uberdev/runs/<RUN_ID>/locked` + sibling `pr-context.json {pr, issue, started_at}`. Writer: leaf `/uberdev:review-pr`, in the `### Executable setup (run before any builder or child edge)` fence via `review_reserve_run_directory` — **not** "Step 4", which is the `Skill(uberdev:post-impl-review)` fanout the reservation must already have completed before. (Cited by symbol deliberately: the reservation moved twice while the old `Step 4` pointer stood still.) Setup exports an opaque identity/digest reservation receipt and never installs an `EXIT` trap, so caller-owned traps remain byte-for-byte intact. Explicit setup failures abandon through the receipt; ordinary interruption leaves truthful in-flight evidence. The fresh-shell final fence removes only the two receipt-bound markers after durable verdict publication and keeps the verdict directory. Reader: `/goal` Phase 2b via `_uberdev_goal_locked_marker_for_pr_fresh "$pr_num" "$REVIEW_GRACE_SECS"`. The grace-window check bounds staleness after SIGKILL or any crash before finalization (no operator intervention required).
- **D220c** — `goal_merge_deferred` audit event. Payload: `{goal_id, pr, reason: "review_in_flight", in_flight_count}`. Emitted ONLY from Phase 2c's pre-`/merge` gate when `uberdev_goal_review_pr_in_flight "$pr"` returns 0. Distinct event from D220h so audit consumers can tell which leaf was deferred without payload introspection.
- **D220d** — `goal_review_grace` audit event. Payload: `{goal_id, pr, note ∈ marker_present | grace_window_lapsed}`. Emitted from the Phase 2b marker probe (`_uberdev_goal_locked_marker_for_pr_fresh`).
- **D220e** — `agent_stuck_on_dialog` circuit-breaker reason. Payload: `{reason, pid, pr, status, lastActivityAt}`. Triggered by `_uberdev_goal_any_attempt_stuck "$pr_num"` returning 0 from the Phase 2b cascade; the helper returns 0 iff `uberdev_goal_agent_stuck_on_dialog` observes a 60s window with unchanged activity-proxy AND busy status. Note: `lastActivityAt` is ABSENT in current `claude agents --json`; the helper uses audit-log row-count over `goal-<id>.jsonl` as the documented fallback activity proxy. Persisted to sidecar as `CIRCUIT_BREAKER_HALT=agent_stuck_on_dialog` so a fresh-shell Phase 4 can reconstruct the banner.
- **D220f** — `goal_reaper_kill` + `goal_reaper_skipped` audit events. Payloads:
  - `goal_reaper_kill`: `{goal_id, pr, pid, signal: "TERM" | "KILL", result: "killed" | "already_dead" | "owner_mismatch"}` (per-PID).
  - `goal_reaper_skipped`: `{goal_id, backend: "claude-bg" | "wezterm", reason: "no_pid_visibility"}` (per-backend, once per call).
  Emitted by `_uberdev_goal_reap_zombies`. Validation chain: `_uberdev_dispatch_tmp_target_safe` → `_uberdev_goal_validate_int` → `kill -0` → `ps -o user= -p` matches `id -un` → `kill -TERM` → `sleep 2` → `kill -KILL`. Per-backend behaviour: `background` = full reap; `claude-bg`/`wezterm` = skip with breadcrumb (no PID visibility, per security.md). Invoked: from `INT`/`TERM` signal traps (separate signal slots from the existing `EXIT` trap), and directly before every `goal_circuit_breaker` `exit 1` (10 call sites — 9 existing breakers + new `agent_stuck_on_dialog`).
- **D220g** — Phase 3 rollover semantics: `queue=("${queue[@]}" "${new_candidates[@]}")` (Phase-1 carry-over BEFORE new). `rolled_over: N` field added to `goal_cycle_completed` payload (captures `${#queue[@]}` before the merge). Fixes the silent-strand bug where cap-overflowed issues were dropped when cycle-N's `new_candidates=()`.
- **D220h** — `goal_review_pr_deferred` audit event. Payload: `{goal_id, pr, reason: "in_flight", in_flight_count}`. Emitted ONLY from the Phase 2b `stale|missing` arm when `uberdev_goal_review_pr_in_flight "$pr"` returns 0 (i.e. a `/review-pr` re-dispatch was suppressed). Distinct from D220c (`goal_merge_deferred`) so audit consumers can tell which leaf was deferred without payload introspection.

### D249a — Phase 2 close-without-PR detection (issue #249, 2026-05-28)

Single addendum row covering the four orthogonal extensions shipped under issue #249. Bug-fix scope under §2.3 (the auto-merge carve-out): no new RFC; all enum changes are documented here once and reflected in `GOAL_AUDIT_EVENT_ENUM` (SKILL.md:19) + `GOAL_ISSUE_STATE_ENUM` (SKILL.md:22) + the `uberdev_goal_audit` case arm (`lib/goal-state.sh` audit enum) + the `uberdev_goal_issue_state_transition` case arm (`lib/goal-state.sh` arc enum) + the version 0.34.12 ratchet.

- **D249a-event** — `goal_issue_closed_without_pr` audit event. Payload: `{goal_id, issue, detected_at}`. Emitted ONLY from Phase 2 step 2a's `else` branch (no PR yet, agent idle) when `gh issue view --json state --jq .state` returns `CLOSED` AND `uberdev_goal_issue_state_transition $issue solving resolved-by-no-action` succeeds (rc=0). The emission is GUARDED on the transition's rc so a failed transition (rc=1 unwritable tmpdir, rc=2 invalid arc) does NOT produce a false-signal audit row — the issue stays in `solving` and lands as `failed` after the 150-min `_UBERDEV_GOAL_SOLVE_TIMEOUT` backstop.
- **D249a-state** — `resolved-by-no-action` issue state (`GOAL_ISSUE_STATE_ENUM` extended 6 → 7). Semantically distinct from `resolved` (which means "PR landed and the issue auto-closed via `Closes #N`"); `resolved-by-no-action` means `/uberdev:orchestrator` legitimately closed the GitHub issue without producing a PR (e.g. stale finding, already-resolved). Terminal state — no further transitions. Counted toward `issues_resolved` in `print_summary` (operator-facing metrics treat it as a successful close).
- **D249a-skip** — Phase-2a outer skip-check widened from `pr-pushed|resolved|failed` to `pr-pushed|resolved|resolved-by-no-action|failed`. Required for correctness: without it, an issue already in the new state would be re-probed every poll tick (60s by default) — the `gh issue view` probe would still see CLOSED and re-attempt the transition, which would rc=2 (invalid arc from a terminal state) on every cycle. The skip-check makes the new state terminal at the control-flow level too.
- **D249a-gh-rc** — `gh issue view --json state` no-signal contract (RFC 0005 B6). Non-zero rc from the probe is treated as "no signal" — the loop emits a stderr breadcrumb (`goal-pipeline: gh issue view <issue> failed rc=<N> — falling through to timeout backstop`) and falls through to the existing `_UBERDEV_GOAL_SOLVE_TIMEOUT` backstop. The probe MUST NOT cascade a transient gh failure into a false terminal transition. Defence in depth: `_uberdev_goal_validate_int "$issue"` runs before the `gh` call (T3 — validate upstream input before any shell expansion).
