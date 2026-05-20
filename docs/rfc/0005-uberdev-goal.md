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
| `solving`    | Dispatched to `/turbo`, no PR yet                                    |
| `pr-pushed`  | Solving PR is in the PR-state machine above                          |
| `resolved`   | Solving PR transitioned to `merged`                                  |
| `failed`     | Solving PR transitioned to `merge-failed` OR `/turbo` returned failure |

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
- Per-PR `/review-pr` audit JSON — path scheme to be specified in `skills/goal-pipeline/SKILL.md`; likely `.claude/audit/review-pr-<PR#>-<run-id>.json`
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
| Q1  | Should `/goal` cap parallel `/turbo` dispatches per cycle? Today `/turbo` uses `fanout_concurrency.solve_bg` (default 6). | Inherit `solve_bg` for v1; revisit if real cycles produce too-wide fanouts. |
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
