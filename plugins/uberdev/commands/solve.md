---
description: "Spawn an autonomous Claude agent per GitHub issue via a platform-aware dispatch backend (claude-bg / wezterm / background; auto-selected per OS — cross-platform on macOS, WSL2, native Windows), with auto-triage and tier-appropriate workflow. Monitor via `claude agents` (claude-bg) or visible panes (wezterm). Accepts multiple issue numbers; dispatches one agent per issue. Override the backend with `--backend=<name>`."
argument-hint: "<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue

Spawn an autonomous Claude agent as a `claude --bg` background session per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel. Monitor with `claude agents`.

**Multi-issue dispatch:** `/solve 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent `claude --bg` sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/solve <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]`

- No flag → **auto-triage** by reading each issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually (applies to every issue in the batch)
- `--terminal=…` → **(deprecated in v0.22.0; no behavioural effect)** parsed for backward compat; `/solve` now dispatches `claude --bg` background sessions visible in `claude agents`. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--auto` → enable `--dangerously-skip-permissions` on the spawned agent (post-#241 follow-up: historically mapped to `--permission-mode auto`, but auto-mode silently refuses some agent tools — notably Search — both inside and outside cmux, so the middle tier was dead weight; AUTO now resolves to the same strict bypass as SKIP). The trade-off is broad: dangerous tools no longer prompt. Use only when the issue is unattended-friendly (e.g., a /turbo batch or a /solve invocation you'll let run to completion). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`.
- `--effort=<level>` (`low | medium | high | xhigh | max`) — sets the `--effort` flag passed to each `claude --bg` child. **Default is `max` for `/turbo`** (autopilot, quality > cost — `claude --bg` does NOT inherit the parent session's `/effort` setting in Claude Code 2.1.139, so without this flag every spawn falls back to the supervised daemon's default and silently downgrades quality). Override per-invocation with `--effort=high` etc. Configurable repo-wide via `solve_effort:` in `.claude/uberdev.local.md` (env override: `UBERDEV_SOLVE_EFFORT`). Precedence: CLI flag > env > config > default `max`.
- `--backend=<name>` (`auto | claude-bg | wezterm | background`) — selects how `/solve` dispatches each per-issue agent. `auto` (default) resolves per-platform: macOS → `wezterm` if available else `claude-bg`; native Windows → `wezterm` if available else `background`; WSL2 → `claude-bg`. `claude-bg` = today's `claude --bg` supervised background sessions (monitor via `claude agents`). `wezterm` = each agent in a visible WezTerm pane (watch them live). `background` = a dependency-free `git worktree add` + detached headless `claude -p` (the Windows-robust fallback). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.claude/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` → **override the small-team issue-claim protocol** (NEW v0.28.0). On dispatch, `/solve` marks each issue ACTIVE on GitHub (label `uberdev:active` + assigns `@me` + posts an audit comment with branch, dispatcher, hostname, timestamp) so teammates running concurrent `/solve` invocations on overlapping issue numbers get a hard refusal showing who/where/when, instead of racing into divergent worktrees and duplicate PRs. The claim is auto-cleared by `/merge` when the PR lands (or when the issue closes — the dispatch-time sweeper handles stale labels on closed issues). `--force` proceeds even if the issue is already claimed — useful for stale-claim recovery after a crashed dispatcher or to reclaim an issue another teammate has abandoned. The override is recorded as `claim_force_override` in the audit log so post-hoc grep can distinguish intentional recoveries from regressions. Solo-dev workflow is unaffected: a single user running `/solve` from one machine sees no behaviour change (the collision check only refuses cross-machine duplicates).
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
