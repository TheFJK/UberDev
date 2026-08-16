---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Runs N parallel solvers in the session's Workflow runtime (one worktree-isolated agent per issue; cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Watch with /workflows. Detached transports (wezterm / background) remain available via `--backend=<name>`."
argument-hint: "<issue-number> [<issue-number>...] [--force] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task", "Workflow"]
---

# Solve GitHub Issue (Unattended)

Spawn an autonomous solver per GitHub issue in **#$ARGUMENTS** — multiple issue numbers run in parallel — with **brainstorm Q&A auto-answered**. On the default `workflow` backend each solver is a worktree-isolated agent in this session's Workflow runtime; watch them with `/workflows`. On the explicit detached backends, monitor with visible panes (`wezterm`) or PID/log/result files (`background`).

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` end-to-end, with `--turbo` forwarded through `uberdev:finish-branch` into `/uberdev:review-pr` so the post-push review chain runs unattended (Phase 1 reviewer fanout runs against the pushed diff).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; implementation still reaches `uberdev:finish-branch`, which opens the PR and chains `/uberdev:review-pr`; `uberdev:post-impl-review` runs post-PR-push in `/review-pr` Phase 1 against the pushed diff. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6; configurable via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents, and do not do the issue's work yourself. Your only actions are the ONE launcher Bash call below and — on the default `workflow` backend — the single `Workflow` call the launcher's args envelope mandates.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--force] [--trivial|--small|--full] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]`

- Same flag semantics as `/solve`. The `--auto` permission **bypass** is orthogonal to `/turbo`: `/turbo` decides whether the brainstorm asks you anything, `--auto` decides whether tools ask you anything.
- ⚠️ `--auto` is a permission **bypass**, not an autonomy dial. It resolves to the pair `--dangerously-skip-permissions --permission-mode bypassPermissions` (both needed — different mechanisms, #246), and wherever the pair lands there are **no tool prompts**, destructive ones included. `/turbo` alone is already unattended; adding `--auto` buys nothing but the bypass.
- **Scope.** On the default `workflow` backend the pair does not reach the per-issue solvers: they run as agents in the calling **session** and inherit **its** permission tier (RFC 0015 §6 R-1b). It is passed per child only on `--backend=wezterm|background`.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.
- Routing/service flags are identical to `/solve`; unattended execution does not select a stronger route. `--effort=ultra` is REFUSED on every backend since #381, and `--fast` changes service tier only.
- `--backend=<name>` (`auto | workflow | wezterm | background`) — selects how `/turbo` runs each per-issue solver. `auto` (default) resolves to `workflow` on every Claude host and OS; there is no environment that resolves anything else. `workflow` = one worktree-isolated solver agent per issue inside this session's Workflow runtime (`skills/solve-fleet/workflow.js`); watch with `/workflows`; no separate agent surface. `wezterm` = each agent in a visible WezTerm pane. `background` = a dependency-free `git worktree add` + detached headless `claude -p`. The `codex` backend was deleted in #381. An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.claude/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` overrides the small-team issue-claim protocol only after the whole batch's route/context validation succeeds; the override emits `claim_force_override`.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--terminal=cmux|ghostty|iterm|terminal|nohup` (CLI flag)
- `$SOLVE_TERMINAL` (env var)
- `solve_terminal: cmux|ghostty|iterm|terminal|nohup` (config key in `.claude/uberdev.local.md`)

On first encounter per run, `/turbo` emits this stderr notice (verbatim) — see `TERMINAL_FLAG_DEPRECATED_NOTE` in `solve-pipeline/SKILL.md` Constants:

> `warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.`

An audit event `deprecated_flag_used` is recorded for each first-encounter emission. Removal target: v1.0.0. The retirement pattern mirrors merge-pipeline PR #49 (`--squash`/`--rebase`/`--bypass-protections`).

## Steps

Run the shared launcher executable as **ONE Bash tool call** — the literal `--auto-mode=1 --turbo` flags select unattended (/turbo) behaviour, and everything after `--` is the raw user argument string (the renderer substitutes `$ARGUMENTS` into real argv words before the shell parses the line):

```bash
bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=1 --turbo -- $ARGUMENTS
```

**Runtime contract (binding):** set the Bash tool `timeout` up to **600000 ms**. For batches above **~10 issues**, run the call with `run_in_background: true` and watch it via Monitor instead — validation is 1 gh round-trip per issue, claim writes add ~2–3 more, and serial dispatch costs 2–8 s per issue, so the 120 s default timeout can expire mid-claim and strand a half-claimed batch.

The launcher runs the whole pipeline in one process (Phase A validate-all-first → Step 4.5 claim protocol → Phase B per-issue dispatch) and **owns the `AUTO_MODE` / `UBERDEV_TURBO` / `SKIP_PERMISSIONS` env lifecycle in-process** (#97/#241): `--auto-mode=1 --turbo` exports `AUTO_MODE=1` + `UBERDEV_TURBO=1` (the chain-wide unattended-mode signal — propagated to compatible child backends by `lib/dispatch.sh`) and unsets `SKIP_PERMISSIONS` inside the launcher process, so a stale `/goal` export cannot silently elevate bare `/turbo` (Bash tool calls share no shell state — an `unset` in a separate fence protects nothing). Do NOT run the historical multi-fence pipeline. The pipeline contract, constants, and triage table are documented in the `uberdev:solve-pipeline` skill (`skills/solve-pipeline/SKILL.md`); `lib/solve-launcher.sh` is the executable SSOT.

## Workflow mandate (backend=workflow — the default)

When the launcher resolves the **`workflow`** backend (what `auto` selects on
every Claude host) it does **not** dispatch anything. It stops after the claim
protocol, writes the per-issue manifest, and prints an args envelope between
`WORKFLOW_ARGS_BEGIN` / `WORKFLOW_ARGS_END`.

Relay the JSON between those markers **verbatim** (DR-2 — never compose or edit
the handoff yourself) into:

```
Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/solve-fleet/workflow.js"}, <the JSON between the markers>)
```

The fleet runs one solver agent per issue in its own git worktree, in waves of
`concurrency`. Watch it with `/workflows` — there is no separate agent surface
to poll.

**Post-Workflow summary:** when the Workflow returns, print its result:

```
[solve] === DONE ===
  issues:   <return.issueCount> (<return.designedIssues> via the design path)
  PRs:      <return.counts.prOpened> opened -> <return.prsOpened>
  verified: <return.verification.confirmed> confirmed, <return.verification.disproven> disproven, <return.verification.unverified> unverified
  other:    <return.counts.noChangesNeeded> no-change, <return.counts.refused> refused, <return.counts.failed> failed
```

Then print one line per entry in `return.results` that is not `PR_OPENED`,
quoting its `blocker`. If `return.cb1Tripped` or `return.cb2Tripped` is true,
say so explicitly and note that issues left unsolved still hold their
`uberdev:active` claim.

A `disproven` or `unverified` count above zero means the fleet could not stand
behind a solver's PR claim — say so and point the user at `return.auditEvents`,
which names the issue and the reason for every disagreement. A
`pr_proof_not_run` row there means the run threw before verification ran, so
nothing was proved — say so even when every count reads zero. This matters most
here: `/turbo` is unattended, so nobody else is going to notice.

**No-Workflow fallback:** if the `Workflow` tool is not among your tools
(Gemini, Copilot, pre-Workflow Claude Code), re-run the same launcher
call with `--backend=background` appended — and report the dispatch summary
the launcher prints. Do not attempt to emulate the fleet by hand.
