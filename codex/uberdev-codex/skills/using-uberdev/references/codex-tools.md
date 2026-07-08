# Codex Tool Mapping

Skills use Claude Code tool names. When you encounter these in a skill, use your platform equivalent:

| Skill references | Codex equivalent |
|-----------------|------------------|
| `Task` tool (dispatch subagent) | `spawn_agent` (see [Named agent dispatch](#named-agent-dispatch)) |
| Multiple `Task` calls (parallel) | Multiple `spawn_agent` calls |
| Task returns result | `wait_agent` |
| Task completes automatically | `close_agent` to free slot |
| `TodoWrite` (task tracking) | `update_plan` |
| `Skill` tool (invoke a skill) | Skills load natively — just follow the instructions |
| `Read`, `Write`, `Edit` (files) | Use your native file tools |
| `Bash` (run commands) | Use your native shell tools |
| `Workflow` tool (background orchestration script) | No equivalent — use the skill's `## No-Workflow fallback` section |

## Subagent dispatch

Current Codex releases enable subagent workflows by default. If `spawn_agent`,
`wait_agent`, or `close_agent` are unavailable in a session, update Codex, check
managed configuration, and restart before using skills like
`dispatching-parallel-agents` and `subagent-driven-development`.

## Named agent dispatch

Claude Code skills reference named agent types like `uberdev:code-reviewer`.
The standalone installer writes Codex custom agents named `uberdev-<name>` into
`~/.codex/agents/`.

When a skill says to dispatch a named agent type:

1. Prefer direct custom-agent dispatch when the current tool surface exposes it
   (for example, `spawn_agent(agent_type="uberdev-code-reviewer", ...)`).
2. If only built-in roles are available, find the agent TOML
   (`~/.codex/agents/uberdev-code-reviewer.toml`) or the skill's local prompt
   template like `code-quality-reviewer-prompt.md`.
3. Read `developer_instructions` or the prompt content.
4. Fill any template placeholders (`{BASE_SHA}`, `{WHAT_WAS_IMPLEMENTED}`, etc.)
5. Spawn a `worker` agent with the filled content as the `message`.

| Skill instruction | Codex equivalent |
|-------------------|------------------|
| `Task tool (uberdev:code-reviewer)` | Prefer `spawn_agent(agent_type="uberdev-code-reviewer", message=...)`; fallback to `worker` with `uberdev-code-reviewer.toml` content |
| `Task tool (general-purpose)` with inline prompt | `spawn_agent(message=...)` with the same prompt |

### Message framing

The `message` parameter is user-level input, not a system prompt. Structure it
for maximum instruction adherence:

```
Your task is to perform the following. Follow the instructions below exactly.

<agent-instructions>
[filled prompt content from the agent's .md file]
</agent-instructions>

Execute this now. Output ONLY the structured response following the format
specified in the instructions above.
```

- Use task-delegation framing ("Your task is...") rather than persona framing ("You are...")
- Wrap instructions in XML tags — the model treats tagged blocks as authoritative
- End with an explicit execution directive to prevent summarization of the instructions

### When this workaround can be removed

This approach compensates for Codex's plugin system not yet supporting an
`agents` field in `plugin.json`. When the plugin manifest gains an `agents`
field, the plugin can ship the custom agents directly and the separate
standalone installer can go away.

## Environment Detection

Skills that create worktrees or finish branches should detect their
environment with read-only git commands before proceeding:

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
BRANCH=$(git branch --show-current)
```

- `GIT_DIR != GIT_COMMON` → already in a linked worktree (skip creation)
- `BRANCH` empty → detached HEAD (cannot branch/push/PR from sandbox)

See `using-git-worktrees` Step 0 and `finishing-a-development-branch`
Step 1 for how each skill uses these signals.

## Codex App Finishing

When the sandbox blocks branch/push operations (detached HEAD in an
externally managed worktree), the agent commits all work and informs
the user to use the App's native controls:

- **"Create branch"** — names the branch, then commit/push/PR via App UI
- **"Hand off to local"** — transfers work to the user's local checkout

The agent can still run tests, stage files, and output suggested branch
names, commit messages, and PR descriptions for the user to copy.
