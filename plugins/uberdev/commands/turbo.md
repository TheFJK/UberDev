---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Dispatches N parallel autonomous agents via a platform-aware dispatch backend (claude-bg / wezterm / background; auto-selected per OS — cross-platform on macOS, WSL2, native Windows; cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Monitor with `claude agents` (claude-bg) or visible panes (wezterm). Override the backend with `--backend=<name>`."
argument-hint: "<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue (Unattended)

Spawn an autonomous Claude agent as a `claude --bg` background session per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel — with **brainstorm Q&A auto-answered**. Monitor with `claude agents`.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` end-to-end, with `--turbo` forwarded through `uberdev:finish-branch` into `/uberdev:review-pr` so the post-push review chain runs unattended (Phase 1 reviewer fanout runs against the pushed diff).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; `subagent-driven-dev` invokes `uberdev:post-impl-review` once at end-of-issue (consolidated across all waves); large tier additionally fires `pr-test-analyzer` pre-merge. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent `claude --bg` sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6; configurable via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]`

- Same flag semantics as `/solve`. `--auto` is orthogonal to `/turbo` — **`/turbo <issue> --auto` is the max-autonomy combo**.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.
- `--effort=<level>` (`low | medium | high | xhigh | max`) — sets the `--effort` flag passed to each `claude --bg` child. **Default is `max` for `/turbo`** (autopilot, quality > cost — `claude --bg` does NOT inherit the parent session's `/effort` setting in Claude Code 2.1.139, so without this flag every spawn falls back to the supervised daemon's default and silently downgrades quality). Override per-invocation with `--effort=high` etc. Configurable repo-wide via `solve_effort:` in `.claude/uberdev.local.md` (env override: `UBERDEV_SOLVE_EFFORT`). Precedence: CLI flag > env > config > default `max`.
- `--backend=<name>` (`auto | claude-bg | wezterm | background`) — selects how `/turbo` dispatches each per-issue agent. `auto` (default) resolves per-platform: macOS → `wezterm` if available else `claude-bg`; native Windows → `wezterm` if available else `background`; WSL2 → `claude-bg`. `claude-bg` = today's `claude --bg` supervised background sessions (monitor via `claude agents`). `wezterm` = each agent in a visible WezTerm pane (watch them live). `background` = a dependency-free `git worktree add` + detached headless `claude -p` (the Windows-robust fallback). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.claude/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` → **override the small-team issue-claim protocol** (NEW v0.28.0). On dispatch, `/turbo` marks each issue ACTIVE on GitHub (label `uberdev:active` + assigns `@me` + posts an audit comment with branch, dispatcher, hostname, timestamp) so teammates running concurrent `/turbo` invocations on overlapping issue numbers get a hard refusal showing who/where/when, instead of racing into divergent worktrees and duplicate PRs. The claim is auto-cleared by `/merge` when the PR lands (or when the issue closes — the dispatch-time sweeper handles stale labels on closed issues). `--force` proceeds even if the issue is already claimed — useful for stale-claim recovery after a crashed dispatcher or to reclaim an issue another teammate has abandoned. The override is recorded as `claim_force_override` in the audit log so post-hoc grep can distinguish intentional recoveries from regressions. Solo-dev workflow is unaffected: a single user running `/turbo` from one machine sees no behaviour change (the collision check only refuses cross-machine duplicates).

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
export AUTO_MODE=1       # /turbo = unattended mode (post-impl-review omitted in trivial/small; orchestrator + review-pr detect turbo via UBERDEV_TURBO env-var OR --turbo arg — hybrid OR detector, #97)
export UBERDEV_TURBO=1   # NEW (#97): chain-wide unattended-mode signal — inherits via Skill() into solve-pipeline + via fork+exec into claude --bg child (env(1)-mediated, since timeout(1) sits in front of the inline-prefix slot)
unset SKIP_PERMISSIONS   # (#241) defend against shell-rc / stale-session pollution from a prior /goal export — /turbo retains operator-gated perms by design. MUST run BEFORE Skill('uberdev:solve-pipeline') below so the launcher inherits a clean env (mirrors the #97 UBERDEV_TURBO unset ordering rule for /solve).
```

Now invoke the `uberdev:solve-pipeline` skill.
