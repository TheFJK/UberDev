---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Dispatches N parallel autonomous agents via a platform-aware dispatch backend (claude-bg / wezterm / background / codex; cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Monitor with `claude agents` (claude-bg), visible panes (wezterm), or PID/log/result files (background/codex). Override the backend with `--backend=<name>`."
argument-hint: "<issue-number> [<issue-number>...] [--force] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue (Unattended)

Spawn an autonomous agent per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel via the selected backend — with **brainstorm Q&A auto-answered**. Monitor with `claude agents` for `claude-bg`, visible panes for `wezterm`, or PID/log/result files for `background` and `codex`.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` end-to-end, with `--turbo` forwarded through `uberdev:finish-branch` into `/uberdev:review-pr` so the post-push review chain runs unattended (Phase 1 reviewer fanout runs against the pushed diff).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; implementation still reaches `uberdev:finish-branch`, which opens the PR and chains `/uberdev:review-pr`; `uberdev:post-impl-review` runs post-PR-push in `/review-pr` Phase 1 against the pushed diff. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6; configurable via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--force] [--trivial|--small|--full] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]`

- Same flag semantics as `/solve`. `--auto` is orthogonal to `/turbo` — **`/turbo <issue> --auto` is the max-autonomy combo**.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.
- Routing/service flags are identical to `/solve`; unattended execution does not select a stronger route. `--effort=ultra` is Codex-only, and `--fast` changes service tier only.
- `--backend=<name>` (`auto | claude-bg | wezterm | background | codex`) — selects how `/turbo` dispatches each per-issue agent. `auto` (default) resolves per-platform: Codex session (`CODEX_HOME` set) or Codex-only host → `codex`; macOS → `wezterm` if available else `claude-bg`; native Windows → `wezterm` if available else `background`; WSL2 → `claude-bg`. `claude-bg` = today's `claude --bg` supervised background sessions (monitor via `claude agents`). `wezterm` = each agent in a visible WezTerm pane (watch them live). `background` = a dependency-free `git worktree add` + detached headless `claude -p` (the Windows-robust fallback). `codex` = detached `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>` in a per-issue worktree (monitor via PID/log/result file). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.claude/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
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
