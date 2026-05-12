---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Dispatches N parallel `claude --bg` background sessions (cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Monitor with `claude agents`."
argument-hint: "<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue (Unattended)

Spawn an autonomous Claude agent as a `claude --bg` background session per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel — with **brainstorm Q&A auto-answered**. Monitor with `claude agents`.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` except `uberdev:post-impl-review` is NOT invoked (asymmetry preserved from prior behavior).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; `subagent-driven-dev` invokes `uberdev:post-impl-review` once at end-of-issue (consolidated across all waves); large tier additionally fires `pr-test-analyzer` pre-merge. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent `claude --bg` sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6; configurable via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>]`

- Same flag semantics as `/solve`. `--auto` is orthogonal to `/turbo` — **`/turbo <issue> --auto` is the max-autonomy combo**.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.
- `--effort=<level>` (`low | medium | high | xhigh | max`) — sets the `--effort` flag passed to each `claude --bg` child. **Default is `max` for `/turbo`** (autopilot, quality > cost — `claude --bg` does NOT inherit the parent session's `/effort` setting in Claude Code 2.1.139, so without this flag every spawn falls back to the supervised daemon's default and silently downgrades quality). Override per-invocation with `--effort=high` etc. Configurable repo-wide via `solve_effort:` in `.claude/uberdev.local.md` (env override: `UBERDEV_SOLVE_EFFORT`). Precedence: CLI flag > env > config > default `max`.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--terminal=cmux|ghostty|iterm|terminal|nohup` (CLI flag)
- `$SOLVE_TERMINAL` (env var)
- `solve_terminal: cmux|ghostty|iterm|terminal|nohup` (config key in `.claude/uberdev.local.md`)

On first encounter per run, `/turbo` emits this stderr notice (verbatim) — see `TERMINAL_FLAG_DEPRECATED_NOTE` in `solve-pipeline/SKILL.md` Constants:

> `warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.`

An audit event `deprecated_flag_used` is recorded for each first-encounter emission. Removal target: v1.0.0. The retirement pattern mirrors merge-pipeline PR #49 (`--squash`/`--rebase`/`--bypass-protections`).

## Steps

```bash
export AUTO_MODE=1  # /turbo = unattended mode (post-impl-review omitted in trivial/small; orchestrator gets --turbo)
```

Now invoke the `uberdev:solve-pipeline` skill.
