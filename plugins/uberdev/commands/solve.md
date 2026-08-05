---
description: "Spawn an autonomous solver per GitHub issue, with auto-triage and a tier-appropriate workflow. Solvers run in the session's Workflow runtime (one worktree-isolated agent per issue; watch with /workflows) — the default `workflow` backend. Detached transports (wezterm / background / codex) remain available via `--backend=<name>`. Accepts multiple issue numbers."
argument-hint: "<issue-number> [<issue-number>...] [--force] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task", "Workflow"]
---

# Solve GitHub Issue

Spawn an autonomous solver per GitHub issue in **#$ARGUMENTS** — multiple issue numbers run in parallel. On the default `workflow` backend each solver is a worktree-isolated agent in this session's Workflow runtime; watch them with `/workflows`. On the explicit detached backends, monitor with visible panes (`wezterm`) or the printed PID/log/result files (`background`, `codex`).

**Multi-issue dispatch:** `/solve 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents, and do not do the issue's work yourself. Your only actions are the ONE launcher Bash call below and — on the default `workflow` backend — the single `Workflow` call the launcher's args envelope mandates.

**Usage:** `/solve <issue-number> [<issue-number>...] [--force] [--trivial|--small|--full] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]`

- No flag → **auto-triage** by reading each issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually (applies to every issue in the batch)
- `--terminal=…` → **(deprecated in v0.22.0; no behavioural effect)** parsed for backward compat; `/solve` now dispatches through `--backend=`. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--auto` → enable `--dangerously-skip-permissions` on the spawned agent (post-#241 follow-up: historically mapped to `--permission-mode auto`, but auto-mode silently refuses some agent tools — notably Search — both inside and outside cmux, so the middle tier was dead weight; AUTO now resolves to the same strict bypass as SKIP). The trade-off is broad: dangerous tools no longer prompt. Use only when the issue is unattended-friendly (e.g., a /turbo batch or a /solve invocation you'll let run to completion). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`.
- Routing: `--routing-mode=adaptive|inherit`, or force a declared route with `--route=luna|terra|sol|sol-high|sol-max|sol-ultra`, or an exact `--model=<slug> --effort=low|medium|high|xhigh|max|ultra` pair. `ultra` is Codex-only. Route/mode/exact-field conflicts fail before claims.
- Service is independent: `--service-tier=default|fast|flex`; `--fast` is an alias for `fast` and never changes model or effort.
- Claude legacy effort remains `low|medium|high|xhigh|max` via `UBERDEV_SOLVE_EFFORT`; Codex exact effort uses `UBERDEV_REASONING_EFFORT`.
- `--backend=<name>` (`auto | workflow | wezterm | background | codex`) — selects how `/solve` runs each per-issue solver. `auto` (default) resolves to `workflow` on every Claude host and OS; a Codex session (`CODEX_HOME` set) or a Codex-only host still resolves to `codex`. `workflow` = one worktree-isolated solver agent per issue inside this session's Workflow runtime (`skills/solve-fleet/workflow.js`); watch with `/workflows`; no separate agent surface. `wezterm` = each agent in a visible WezTerm pane. `background` = a dependency-free `git worktree add` + detached headless `claude -p`. `codex` = detached `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>` in a per-issue worktree (monitor via PID/log/result file). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.claude/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` overrides the small-team issue-claim protocol. Claims are written only after the whole batch's triage, route, backend, and immutable root contexts validate.
- Multi-issue example: `/solve 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--terminal=cmux|ghostty|iterm|terminal|nohup` (CLI flag)
- `$SOLVE_TERMINAL` (env var)
- `solve_terminal: cmux|ghostty|iterm|terminal|nohup` (config key in `.claude/uberdev.local.md`)

On first encounter per run, `/solve` emits this stderr notice (verbatim) — see `TERMINAL_FLAG_DEPRECATED_NOTE` in `solve-pipeline/SKILL.md` Constants:

> `warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.`

An audit event `deprecated_flag_used` is recorded for each first-encounter emission. Removal target: v1.0.0. The retirement pattern mirrors merge-pipeline PR #49 (`--squash`/`--rebase`/`--bypass-protections`).

## Steps

Run the shared launcher executable as **ONE Bash tool call** — the literal `--auto-mode=0` flag selects interactive (/solve) behaviour, and everything after `--` is the raw user argument string (the renderer substitutes `$ARGUMENTS` into real argv words before the shell parses the line):

```bash
bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=0 -- $ARGUMENTS
```

**Runtime contract (binding):** set the Bash tool `timeout` up to **600000 ms**. For batches above **~10 issues**, run the call with `run_in_background: true` and watch it via Monitor instead — validation is 1 gh round-trip per issue, claim writes add ~2–3 more, and serial dispatch costs 2–8 s per issue, so the 120 s default timeout can expire mid-claim and strand a half-claimed batch.

The launcher runs the whole pipeline in one process (Phase A validate-all-first → Step 4.5 claim protocol → Phase B per-issue dispatch) and **owns the `AUTO_MODE` / `UBERDEV_TURBO` / `SKIP_PERMISSIONS` env lifecycle in-process** (#97/#241): `--auto-mode=0` exports `AUTO_MODE=0` and unsets `UBERDEV_TURBO` + `SKIP_PERMISSIONS` inside the launcher process, so stale shell-profile exports from a prior `/turbo` or `/goal` cannot leak into the spawned children (Bash tool calls share no shell state — an `unset` in a separate fence protects nothing). Do NOT run the historical multi-fence pipeline. The pipeline contract, constants, and triage table are documented in the `uberdev:solve-pipeline` skill (`skills/solve-pipeline/SKILL.md`); `lib/solve-launcher.sh` is the executable SSOT.

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
  other:    <return.counts.noChangesNeeded> no-change, <return.counts.refused> refused, <return.counts.failed> failed
```

Then print one line per entry in `return.results` that is not `PR_OPENED`,
quoting its `blocker`. If `return.cb1Tripped` or `return.cb2Tripped` is true,
say so explicitly and note that issues left unsolved still hold their
`uberdev:active` claim.

**No-Workflow fallback:** if the `Workflow` tool is not among your tools
(Codex, Gemini, Copilot, pre-Workflow Claude Code), re-run the same launcher
call with an explicit detached backend appended — `--backend=codex` inside a
Codex session, otherwise `--backend=background` — and report the dispatch summary
the launcher prints. Do not attempt to emulate the fleet by hand.
