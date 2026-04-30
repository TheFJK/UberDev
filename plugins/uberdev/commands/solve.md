---
description: "Spawn an autonomous Claude agent in a new terminal/cmux workspace to solve a GitHub issue, with auto-triage and tier-appropriate workflow"
argument-hint: "<issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue

Spawn an autonomous Claude agent in a new cmux workspace to solve GitHub issue **#$ARGUMENTS**.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/solve <issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]`

- No flag → **auto-triage** by reading the issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually
- `--terminal=…` → override terminal detection (else `$SOLVE_TERMINAL` env var, else auto-detect)
- `--auto` → enable `--permission-mode auto` (Claude Code's AI classifier — auto-approves safe ops; blocks force push / `rm -rf` on pre-existing files / exfil / self-modification / `--dangerously-skip-permissions`). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`.
- `SOLVE_GHOSTTY_NEW_WINDOW=1` env var → force the legacy *new window* dispatch instead of tab-spawning into the originating Ghostty window (Ghostty terminal only).

## Steps

```bash
export AUTO_MODE=0  # /solve = interactive mode (post-impl-review wired in trivial/small; orchestrator without --turbo)
```

Now invoke the `uberdev:solve-pipeline` skill — it owns the bash launcher (arg parsing, repo detection, tier classification, prompt heredoc, terminal spawn, notify, retitle). The skill renders inline, so `$AUTO_MODE` and `$ARGUMENTS` remain in scope for its bash blocks.
