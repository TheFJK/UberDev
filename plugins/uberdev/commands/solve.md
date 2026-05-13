---
description: "Spawn an autonomous Claude agent as a `claude --bg` background session per GitHub issue, with auto-triage and tier-appropriate workflow. Monitor via `claude agents`. Accepts multiple issue numbers; dispatches one bg session per issue."
argument-hint: "<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue

Spawn an autonomous Claude agent as a `claude --bg` background session per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel. Monitor with `claude agents`.

**Multi-issue dispatch:** `/solve 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent `claude --bg` sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/solve <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>]`

- No flag → **auto-triage** by reading each issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually (applies to every issue in the batch)
- `--terminal=…` → **(deprecated in v0.22.0; no behavioural effect)** parsed for backward compat; `/solve` now dispatches `claude --bg` background sessions visible in `claude agents`. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--auto` → enable `--permission-mode auto` (Claude Code's AI classifier — auto-approves safe ops; blocks force push / `rm -rf` on pre-existing files / exfil / self-modification / `--dangerously-skip-permissions`). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`.
- `--effort=<level>` (`low | medium | high | xhigh | max`) — sets the `--effort` flag passed to each `claude --bg` child. **Default is `max` for `/turbo`** (autopilot, quality > cost — `claude --bg` does NOT inherit the parent session's `/effort` setting in Claude Code 2.1.139, so without this flag every spawn falls back to the supervised daemon's default and silently downgrades quality). Override per-invocation with `--effort=high` etc. Configurable repo-wide via `solve_effort:` in `.claude/uberdev.local.md` (env override: `UBERDEV_SOLVE_EFFORT`). Precedence: CLI flag > env > config > default `max`.
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

```bash
export AUTO_MODE=0       # /solve = interactive mode (post-impl-review wired in trivial/small; orchestrator without --turbo)
unset UBERDEV_TURBO      # NEW (#97): defend against shell-rc pollution from prior /turbo or .zshrc export of UBERDEV_TURBO=1
```

Now invoke the `uberdev:solve-pipeline` skill — it owns the bash launcher (arg parsing, repo detection, tier classification, prompt heredoc, terminal spawn, notify, retitle). The skill renders inline, so `$AUTO_MODE` and `$ARGUMENTS` remain in scope for its bash blocks.
