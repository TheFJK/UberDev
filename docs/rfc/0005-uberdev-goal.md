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

## 9. Design Decisions

This section catalogues the inline-code shorthands (e.g. `// D4 — TMPDIR validation`, `# B1 — correct audit path`) that annotate rationale in `plugins/uberdev/lib/goal-state.sh` and `plugins/uberdev/skills/goal-pipeline/SKILL.md`. Each code is a permanent pointer to its row below; comments stay terse, definitions live here.

Codes are grouped by prefix: **D** (design decisions), **T** (trust/threat boundaries), **Q** (open questions resolved into implementation), **R** (robustness rules), **B** (bug fix / behaviour contracts), **S** (simplify/style rules). Within each table, rows are sorted ascending by numeric suffix. The `See also` column points to existing RFC sections (`§N.M.K` style) when the concept is covered elsewhere in this document; codes with `—` (em-dash) have no other RFC coverage and the row here is the canonical definition. Gaps in numbering (e.g. no `B3`, no `D1`) reflect codes that do not appear in source and are intentionally undefined — defining them would be dead documentation.

> **Namespace note (important):** the `Q*` codes in §9.3 are a different namespace from RFC §5 "Open questions". §5 tracks UNRESOLVED design questions; §9.3 tracks questions that were resolved into implementation decisions during PR #129 development. **`Q1` in §9.3 ≠ `Q1` in §5** — same letter, different table. Future work to rename one of the two namespaces is out of scope for this PR (touches code in PR #129; deferred to a follow-up).

### 9.1 D — Design decisions

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| D2  | Issue state machine: five states `input → solving → pr-pushed → resolved`; `solving → failed` and `pr-pushed → failed` allowed; no audit event on issue transitions (derived state only). | §3.2.2 |
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
| B1  | Correct audit path for `/review-pr` results: the canonical path is `.uberdev/runs/<run-id>/review-pr-verdict.json`; the legacy `.claude/audit/review-pr-<PR>-<run>.json` path was never written by `/review-pr` and silently returned "missing" for every lookup, blocking trust-signal reads forever. | §3.5 |
| B2  | Correct audit path for `/merge` results: the canonical path is `.uberdev/audit.jsonl`; the legacy `.claude/audit/merge-<PR>-<run>.json` path was never written by `/merge` and silently returned "missing", causing Phase 2c to never drive PR transitions. | §3.5 |
| B4  | `uberdev_goal_list_prs_in_state` takes exactly one state argument; calling it with a space-separated string `"yellow-held red-held"` makes the second token a positional no-op — `red-held` PRs are silently excluded from the unblock check. Call the function twice and concatenate results. | — |
| B5  | `gh_jq_or_jq` exit-code contract: callers MUST branch on the return code; rc≠0 means jq failed (malformed JSON or missing filter target) and the result is not a valid trust signal; treating empty stdout as equivalent to rc=0 caused a corrupted audit JSON to fall through to the "phase2_5 missing" path and misclassify the trust signal as `stale`. | — |
| B6  | Two separate bugs share this code: (a) Phase 2a overflow detection must run in the `red` signal case where `$audit_json` and `$pr_num` are in scope (not Phase 3 where they don't exist); (b) Phase 3 must check `gh_rc` for the `gh issue list` call — discarding rc meant a 403 rate-limit appeared as empty candidates, falsely triggering `goal_converged`. | — |
| B7  | Defensive default-case guard in Phase 2c's merge-result `case` statement: any value outside `success|conflict|hook_failed|missing` is a contract drift (e.g., a future enum member not yet handled here) and must halt with `goal_circuit_breaker reason=unknown_merge_result` rather than silently leaving the PR stuck in `merging` forever. | §3.4 |
| B10 | `_uberdev_goal_check_unblock` must surface `gh pr view` failures (rate-limited, transient network, PR deleted upstream) instead of treating empty body as "no Blocks: lines" — silent empty-body would leave a held PR waiting for an unblock check that never succeeds; correct behaviour is to skip the iteration and retry next cycle. | §3.2.3 |
| B11 | In the unblock blocking-issue check, a 404 "Could not resolve to an Issue" `gh` error means the issue was deleted upstream and should be treated as CLOSED (unblock proceeds); all other `gh` errors should skip the unblock check this iteration (NOT treat the issue as OPEN, which would permanently hold the PR). | §3.2.3 |

### 9.6 S — Simplify / Style rules

| Code | One-sentence definition | See also |
|------|-------------------------|----------|
| S4 | Helper naming convention: all internal helpers in `lib/goal-state.sh` must use the `_uberdev_goal_*` prefix; a short alias `_persist_fp` was dropped in favour of the canonical long name `_uberdev_goal_persist_fp` because the call site is not harmed by the longer name and consistency beats brevity for private helpers. | — |
| S6 | `print_summary` held-PR rows must include the `state=` field (`yellow-held` or `red-held`); the prior implementation merged both lists into bare PR numbers, silently dropping the state field that the prose (RFC §3.2.3) promises. | §3.2.3 |
| S9 | Dry-run mode must suppress ALL side effects including audit events; specifically `goal_dispatched` must not be emitted during `--dry-run` so the audit log remains a record of real runs only. (Paired with D16 which defines the dry-run feature; S9 is the audit-purity constraint.) | §3.1 |
