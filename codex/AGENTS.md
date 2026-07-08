# UberDev for Codex — global primer

> This block is merged into `~/.codex/AGENTS.md` by `install-codex.sh`.
> It mirrors what Claude Code gets from the UberDev session-start hook +
> the `using-uberdev` skill. Edits here are overwritten on re-install.

## What this gives you

UberDev installs a workflow toolkit into Codex: ~39 **skills** and command-skills
(in `~/.agents/skills/`) and ~42 **subagents** (in
`~/.codex/agents/uberdev-*.toml`).
Skills encode reusable workflows (brainstorm, write-plan, execute-plan, TDD,
systematic-debugging, PR review, GitHub-issue triage, etc.); subagents are the
specialized personas those skills fan out to (code-reviewer, spec-writer,
conflict-resolver, the testers squad, …).

## Instruction priority

1. **Your explicit instructions** (this `AGENTS.md`, project `AGENTS.md`, direct
   requests) — highest priority.
2. **UberDev skills** — override Codex's default behaviour where they conflict.
3. **Default system behaviour** — lowest.

If a project's `AGENTS.md` says "don't use TDD" and a skill says "always use
TDD," follow the user's instructions. The user is in control.

## How to use skills in Codex

Skills load natively — when a skill applies to your task, read its `SKILL.md`
and follow it. You can list/inspect them under `~/.agents/skills/`, or invoke
one explicitly by mentioning `$<skill-name>`.

**The rule:** if there is even a 1% chance a skill applies to what you're
doing, invoke it BEFORE responding (including before clarifying questions).
Skills tell you *how* to approach the task; checking them first prevents
undiscined action. Announce: "Using `<skill>` to `<purpose>`", create a plan
item per checklist step, then follow the skill exactly.

Skill priority when several apply: **process skills first** (brainstorming,
debugging — these determine *how* to approach), **implementation skills second**.

## Tool mapping (skills use Claude Code names — translate to Codex)

Skills were authored against Claude Code's tool surface. When a skill
references a tool, use the Codex equivalent:

| Skill references | Codex equivalent |
|------------------|------------------|
| `Task` tool (dispatch a named subagent) | `spawn_agent` — see "Named agent dispatch" below |
| Multiple `Task` calls (parallel) | Multiple `spawn_agent` calls, then `wait_agent` each |
| `TodoWrite` (task tracking) | `update_plan` |
| `Skill` tool (invoke a skill) | Skills load natively — just follow the instructions |
| `Read`, `Write`, `Edit` (files) | Your native file tools |
| `Bash` (run commands) | Your native shell tool (Codex `shell` / `unified_exec`) |
| `WebFetch` / `WebSearch` | Codex web-search / URL-read tools |
| `Workflow` tool (background orchestration) | **No equivalent** — use the skill's `## No-Workflow fallback` section |

### Subagent dispatch

These skills (`dispatching-parallel-agents`, `subagent-driven-dev`,
`orchestrator`, `/solve`, `/turbo`, the review/test pipelines) use Codex
subagents. Current Codex releases enable subagent workflows by default. If
`spawn_agent` / `wait_agent` are not available in a session, update Codex,
check managed configuration, and restart before using these workflows.

### Named agent dispatch (the important workaround)

Skills reference named agent types like `uberdev:code-reviewer`. The standalone
installer writes Codex custom agents named `uberdev-<name>` into
`~/.codex/agents/`. When that custom agent type is available in the current
tool surface, spawn it directly (for example,
`spawn_agent(agent_type="uberdev-code-reviewer", ...)`). If the current tool
surface only exposes built-in roles (`default`, `explorer`, `worker`), use the
portable fallback:

1. Find the agent's prompt (in `~/.codex/agents/uberdev-<name>.toml`, or a
   skill-local `*-prompt.md` template).
2. Read its `developer_instructions` content.
3. Fill any template placeholders (`{BASE_SHA}`, `{WHAT_WAS_IMPLEMENTED}`, …).
4. Spawn a `worker` agent with the filled content as the `message`:

```
spawn_agent(agent_type="worker", message="""
Your task is to perform the following. Follow the instructions below exactly.

<agent-instructions>
[filled developer_instructions content from uberdev-<name>.toml]
</agent-instructions>

Execute this now. Output ONLY the structured response specified above.
""")
```

Use task-delegation framing ("Your task is…"), wrap instructions in XML tags,
and end with an explicit execution directive — this maximises instruction
adherence because `message` is user-level input, not a system prompt.

| Skill instruction | Codex equivalent |
|-------------------|------------------|
| `Task(uberdev:code-reviewer)` | Prefer `spawn_agent(agent_type="uberdev-code-reviewer", message=…)`; fallback to `worker` with `uberdev-code-reviewer.toml` content |
| `Task(general-purpose)` with inline prompt | `spawn_agent(message=…)` with the same prompt |

## Skills that create worktrees / finish branches

`using-git-worktrees`, `finish-branch`, and the solve/orchestrator pipelines
create git worktrees for parallel work. Detect your environment with read-only
git commands before proceeding:

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
BRANCH=$(git branch --show-current)
```

- `GIT_DIR != GIT_COMMON` → already in a linked worktree (skip creation).
- `BRANCH` empty → detached HEAD (cannot branch/push/PR — see "finishing" below).

Under Codex's `workspace-write` sandbox, `git checkout -b` and `git push` may be
blocked. When that happens, commit all work and hand off to the user: output a
suggested branch name, commit message, and PR description for them to apply via
the Codex app's native controls ("Create branch" / "Hand off to local").

## Commands that became skills

Claude Code slash commands (`/issue`, `/review-pr`, `/solve`, `/turbo`,
`/merge`, `/testers`, `/brainstorm`, etc.) have no Codex equivalent — Codex
removed custom prompts in v0.117.0 and points everyone to skills. They ship
here as skills named `uberdev-cmd-<name>` (e.g. `$uberdev-cmd-issue`), and they
also trigger implicitly when your task matches their description. So "create an
issue for the login bug" invokes `uberdev-cmd-issue` automatically.

## Per-project configuration

UberDev reads optional per-project config from `.claude/uberdev.local.md` (YAML
frontmatter; env vars override file values). The full key schema lives in
`~/.agents/skills/using-uberdev/references/configuration.md` — read it before
answering config questions or changing a knob; never guess keys, ranges, or
defaults from memory.

## Uninstall

`./codex/install-codex.sh --uninstall` removes the skills, agents, and this
primer block (preserving the rest of your `~/.codex/AGENTS.md`).
