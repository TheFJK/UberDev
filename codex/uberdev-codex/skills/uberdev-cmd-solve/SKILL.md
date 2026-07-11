---
name: uberdev-cmd-solve
description: "Use when the user wants to spawn an autonomous agent per GitHub issue via a platform-aware dispatch backend (claude-bg / wezterm / background / codex; auto-selected per host), with auto-triage and tier-appropriate workflow. Monitor via `claude agents` (claude-bg), visible panes (wezterm), or PID/log/result files (background/codex). Accepts multiple issue numbers; dispatches one agent per issue. Override the backend with `--backend=<name>`. Invokable explicitly as $uberdev-cmd-solve. Original description: Spawn an autonomous agent per GitHub issue via a platform-aware dispatch backend (claude-bg / wezterm / background / codex; auto-selected per host), with auto-triage and tier-appropriate workflow. Monitor via `claude agents` (claude-bg), visible panes (wezterm), or PID/log/result files (background/codex). Accepts multiple issue numbers; dispatches one agent per issue. Override the backend with `--backend=<name>`."
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/solve`). On Codex:

- **`$ARGUMENTS`** below = the user's free-text request (the words after the
  command name, or your whole task description if invoked implicitly).
- **`Task` tool** calls → use `spawn_agent`; collect results with `wait_agent`
  (see ~/.agents/skills/using-uberdev/references/codex-tools.md for the
  named-agent mapping).
- **`Skill` tool** invocations → skills load natively; just follow the named
  skill's instructions.
- **`Workflow` tool** (testers/uberscan/ubersimplify) → no Codex equivalent;
  follow the skill's `## No-Workflow fallback` section instead.
- **`MultiEdit`** → apply edits with your native file-edit tool.

Original argument hint: `<issue-number> [<issue-number>...] [--force] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]`

---



# Solve GitHub Issue

Spawn an autonomous agent per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel via the selected backend. Monitor with `claude agents` for `claude-bg`, visible panes for `wezterm`, or the printed PID/log/result files for `background` and `codex`.

**Multi-issue dispatch:** `/solve 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/solve <issue-number> [<issue-number>...] [--force] [--trivial|--small|--full] [--routing-mode=adaptive|inherit] [--route=<route>|--model=<slug> --effort=<level>] [--service-tier=default|fast|flex|--fast] [--backend=<name>]`

- No flag → **auto-triage** by reading each issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually (applies to every issue in the batch)
- `--terminal=…` → **(deprecated in v0.22.0; no behavioural effect)** parsed for backward compat; `/solve` now dispatches through `--backend=`. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--auto` → enable `--dangerously-skip-permissions` on the spawned agent (post-#241 follow-up: historically mapped to `--permission-mode auto`, but auto-mode silently refuses some agent tools — notably Search — both inside and outside cmux, so the middle tier was dead weight; AUTO now resolves to the same strict bypass as SKIP). The trade-off is broad: dangerous tools no longer prompt. Use only when the issue is unattended-friendly (e.g., a /turbo batch or a /solve invocation you'll let run to completion). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`).
- Routing: `--routing-mode=adaptive|inherit`, or force a declared route with `--route=luna|terra|sol|sol-high|sol-max|sol-ultra`, or an exact `--model=<slug> --effort=low|medium|high|xhigh|max|ultra` pair. `ultra` is Codex-only. Route/mode/exact-field conflicts fail before claims.
- Service is independent: `--service-tier=default|fast|flex`; `--fast` is an alias for `fast` and never changes model or effort.
- Claude legacy effort remains `low|medium|high|xhigh|max` via `UBERDEV_SOLVE_EFFORT`; Codex exact effort uses `UBERDEV_REASONING_EFFORT`.
- `--backend=<name>` (`auto | claude-bg | wezterm | background | codex`) — selects how `/solve` dispatches each per-issue agent. `auto` (default) resolves per-platform: Codex session (`CODEX_HOME` set) or Codex-only host → `codex`; macOS → `wezterm` if available else `claude-bg`; native Windows → `wezterm` if available else `background`; WSL2 → `claude-bg`. `claude-bg` = today's `claude --bg` supervised background sessions (monitor via `claude agents`). `wezterm` = each agent in a visible WezTerm pane (watch them live). `background` = a dependency-free `git worktree add` + detached headless `claude -p` (the Windows-robust fallback). `codex` = detached `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>` in a per-issue worktree (monitor via PID/log/result file). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`) (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` overrides the small-team issue-claim protocol. Claims are written only after the whole batch's triage, route, backend, and immutable root contexts validate.
- Multi-issue example: `/solve 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--terminal=cmux|ghostty|iterm|terminal|nohup` (CLI flag)
- `$SOLVE_TERMINAL` (env var)
- `solve_terminal: cmux|ghostty|iterm|terminal|nohup` (config key in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`))

On first encounter per run, `/solve` emits this stderr notice (verbatim) — see `TERMINAL_FLAG_DEPRECATED_NOTE` in `solve-pipeline/SKILL.md` Constants:

> `warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.`

An audit event `deprecated_flag_used` is recorded for each first-encounter emission. Removal target: v1.0.0. The retirement pattern mirrors merge-pipeline PR #49 (`--squash`/`--rebase`/`--bypass-protections`).

## Steps

Run the shared launcher executable as **ONE Bash tool call** — the literal `--auto-mode=0` flag selects interactive (/solve) behaviour, and everything after `--` is the raw user argument string (the renderer substitutes `$ARGUMENTS` into real argv words before the shell parses the line):

```bash
bash "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/solve-launcher.sh" --auto-mode=0 -- $ARGUMENTS
```

**Runtime contract (binding):** set the Bash tool `timeout` up to **600000 ms**. For batches above **~10 issues**, run the call with `run_in_background: true` and watch it via Monitor instead — validation is 1 gh round-trip per issue, claim writes add ~2–3 more, and serial dispatch costs 2–8 s per issue, so the 120 s default timeout can expire mid-claim and strand a half-claimed batch.

The launcher runs the whole pipeline in one process (Phase A validate-all-first → Step 4.5 claim protocol → Phase B per-issue dispatch) and **owns the `AUTO_MODE` / `UBERDEV_TURBO` / `SKIP_PERMISSIONS` env lifecycle in-process** (#97/#241): `--auto-mode=0` exports `AUTO_MODE=0` and unsets `UBERDEV_TURBO` + `SKIP_PERMISSIONS` inside the launcher process, so stale shell-profile exports from a prior `/turbo` or `/goal` cannot leak into the spawned children (Bash tool calls share no shell state — an `unset` in a separate fence protects nothing). Do NOT run the historical multi-fence pipeline. The pipeline contract, constants, and triage table are documented in the `uberdev:solve-pipeline` skill (`skills/solve-pipeline/SKILL.md`); `lib/solve-launcher.sh` is the executable SSOT.
