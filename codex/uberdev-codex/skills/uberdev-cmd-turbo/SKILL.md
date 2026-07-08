---
name: uberdev-cmd-turbo
description: "Use when the user wants to unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Dispatches N parallel autonomous agents via a platform-aware dispatch backend (claude-bg / wezterm / background / codex; cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Monitor with `claude agents` (claude-bg), visible panes (wezterm), or PID/log/result files (background/codex). Override the backend with `--backend=<name>`. Invokable explicitly as $uberdev-cmd-turbo. Original description: Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Dispatches N parallel autonomous agents via a platform-aware dispatch backend (claude-bg / wezterm / background / codex; cap: 6 default, configurable via `fanout_concurrency.solve_bg`). Monitor with `claude agents` (claude-bg), visible panes (wezterm), or PID/log/result files (background/codex). Override the backend with `--backend=<name>`."
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/turbo`). On Codex:

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

Original argument hint: `<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]`

---



# Solve GitHub Issue (Unattended)

Spawn an autonomous agent per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel via the selected backend — with **brainstorm Q&A auto-answered**. Monitor with `claude agents` for `claude-bg`, visible panes for `wezterm`, or PID/log/result files for `background` and `codex`.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` end-to-end, with `--turbo` forwarded through `uberdev:finish-branch` into `/uberdev:review-pr` so the post-push review chain runs unattended (Phase 1 reviewer fanout runs against the pushed diff).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; implementation still reaches `uberdev:finish-branch`, which opens the PR and chains `/uberdev:review-pr`; `uberdev:post-impl-review` runs post-PR-push in `/review-pr` Phase 1 against the pushed diff. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent sessions — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6; configurable via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--effort=<level>] [--force] [--backend=<name>]`

- Same flag semantics as `/solve`. `--auto` is orthogonal to `/turbo` — **`/turbo <issue> --auto` is the max-autonomy combo**.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.
- `--effort=<level>` (`low | medium | high | xhigh | max`) — sets the `--effort` flag passed to Claude-backed children. **Default is `max` for `/turbo`** (autopilot, quality > cost — `claude --bg` does NOT inherit the parent session's `/effort` setting in Claude Code 2.1.139, so without this flag every spawn falls back to the supervised daemon's default and silently downgrades quality). The `codex` backend uses Codex model/config defaults instead. Override per-invocation with `--effort=high` etc. Configurable repo-wide via `solve_effort:` in `.codex/uberdev.local.md` (env override: `UBERDEV_SOLVE_EFFORT`). Precedence: CLI flag > env > config > default `max`.
- `--backend=<name>` (`auto | claude-bg | wezterm | background | codex`) — selects how `/turbo` dispatches each per-issue agent. `auto` (default) resolves per-platform: Codex session (`CODEX_HOME` set) or Codex-only host → `codex`; macOS → `wezterm` if available else `claude-bg`; native Windows → `wezterm` if available else `background`; WSL2 → `claude-bg`. `claude-bg` = today's `claude --bg` supervised background sessions (monitor via `claude agents`). `wezterm` = each agent in a visible WezTerm pane (watch them live). `background` = a dependency-free `git worktree add` + detached headless `claude -p` (the Windows-robust fallback). `codex` = detached `codex exec --ask-for-approval never --sandbox workspace-write --json -o <result>` in a per-issue worktree (monitor via PID/log/result file). An explicit `--backend=X` hard-errors if `X` is unusable on this host. Configurable repo-wide via `dispatch_backend:` in `.codex/uberdev.local.md` (env override: `UBERDEV_DISPATCH_BACKEND`). Precedence: CLI flag > env > config > default `auto`.
- `--force` / `-f` → **override the small-team issue-claim protocol** (NEW v0.28.0). On dispatch, `/turbo` marks each issue ACTIVE on GitHub (label `uberdev:active` + assigns `@me` + posts an audit comment with branch, dispatcher, hostname, timestamp) so teammates running concurrent `/turbo` invocations on overlapping issue numbers get a hard refusal showing who/where/when, instead of racing into divergent worktrees and duplicate PRs. The claim is auto-cleared by `/merge` when the PR lands (or when the issue closes — the dispatch-time sweeper handles stale labels on closed issues). `--force` proceeds even if the issue is already claimed — useful for stale-claim recovery after a crashed dispatcher or to reclaim an issue another teammate has abandoned. The override is recorded as `claim_force_override` in the audit log so post-hoc grep can distinguish intentional recoveries from regressions. Solo-dev workflow is unaffected: a single user running `/turbo` from one machine sees no behaviour change (the collision check only refuses cross-machine duplicates).

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--terminal=cmux|ghostty|iterm|terminal|nohup` (CLI flag)
- `$SOLVE_TERMINAL` (env var)
- `solve_terminal: cmux|ghostty|iterm|terminal|nohup` (config key in `.codex/uberdev.local.md`)

On first encounter per run, `/turbo` emits this stderr notice (verbatim) — see `TERMINAL_FLAG_DEPRECATED_NOTE` in `solve-pipeline/SKILL.md` Constants:

> `warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.`

An audit event `deprecated_flag_used` is recorded for each first-encounter emission. Removal target: v1.0.0. The retirement pattern mirrors merge-pipeline PR #49 (`--squash`/`--rebase`/`--bypass-protections`).

## Steps

Run the shared launcher executable as **ONE Bash tool call** — the literal `--auto-mode=1 --turbo` flags select unattended (/turbo) behaviour, and everything after `--` is the raw user argument string (the renderer substitutes `$ARGUMENTS` into real argv words before the shell parses the line):

```bash
bash "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/solve-launcher.sh" --auto-mode=1 --turbo -- $ARGUMENTS
```

**Runtime contract (binding):** set the Bash tool `timeout` up to **600000 ms**. For batches above **~10 issues**, run the call with `run_in_background: true` and watch it via Monitor instead — validation is 1 gh round-trip per issue, claim writes add ~2–3 more, and serial dispatch costs 2–8 s per issue, so the 120 s default timeout can expire mid-claim and strand a half-claimed batch.

The launcher runs the whole pipeline in one process (Phase A validate-all-first → Step 4.5 claim protocol → Phase B per-issue dispatch) and **owns the `AUTO_MODE` / `UBERDEV_TURBO` / `SKIP_PERMISSIONS` env lifecycle in-process** (#97/#241): `--auto-mode=1 --turbo` exports `AUTO_MODE=1` + `UBERDEV_TURBO=1` (the chain-wide unattended-mode signal — propagated to compatible child backends by `lib/dispatch.sh`) and unsets `SKIP_PERMISSIONS` inside the launcher process, so a stale `/goal` export cannot silently elevate bare `/turbo` (Bash tool calls share no shell state — an `unset` in a separate fence protects nothing). Do NOT run the historical multi-fence pipeline. The pipeline contract, constants, and triage table are documented in the `uberdev:solve-pipeline` skill (`skills/solve-pipeline/SKILL.md`); `lib/solve-launcher.sh` is the executable SSOT.
