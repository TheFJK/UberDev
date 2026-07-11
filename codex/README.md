# UberDev for Codex

UberDev's full workflow toolkit — 39 skills and command-skills, 44 subagents,
plus the autonomous dispatch backend — installable into the
[OpenAI Codex CLI](https://developers.openai.com/codex).

This is the Codex counterpart to UberDev's Claude Code plugin. The workflows
(brainstorm → plan → execute, TDD, systematic-debugging, parallel PR review,
GitHub issue triage & resolution, the testers QA squad) are the same; the
delivery surfaces are adapted to Codex's skill / subagent / AGENTS.md model.

## Why two install paths

Codex's documented plugin manifest bundles **skills, MCP servers, apps, and
hooks** — but has **no `agents` field** (as of July 2026). So a
plugin alone can ship the skills but cannot ship the 44 subagents that
`/review-pr`, `/testers`, `/solve`, and the research/spec/plan pipelines fan
out to. Two paths cover this:

| Path | Installs skills | Installs agents | Best for |
|------|:---:|:---:|---|
| **Standalone installer** (this repo) | ✅ `~/.agents/skills/` | ✅ `~/.codex/agents/` | full functionality incl. dispatch |
| **Codex plugin/marketplace** | ✅ bundled | ❌ (manifest has no agents field) | browse-and-toggle in `/plugins` |

**For `/solve`, `/turbo`, `/review-pr`, `/testers` to actually fan out to
their subagents, you need the standalone installer.** The plugin alone leaves
those commands functional-but-subagentless. Many users run **both**: the
plugin for managed hooks/UI + the installer for agents + primer.

---

## Prerequisites

- **Codex CLI** — `codex` on PATH ([install](https://developers.openai.com/codex))
- **python3** — for the agent converter (macOS ships it)
- **rsync** — for skill mirroring (`brew install rsync` / `apt install rsync`)
- **jq** — recommended (some skills use it for JSON)
- **gh CLI** — required by `/issue`, `/solve`, `/turbo`, `/review-pr`, `/merge`

## Path 1 — Standalone installer (recommended)

```bash
# From a clone of this repo:
./codex/install-codex.sh

# Or the one-liner:
curl -fsSL https://raw.githubusercontent.com/TheFJK/UberDev/main/codex/install-codex.sh | bash
```

This installs three things:

1. **Skills** → `~/.agents/skills/` (39 Codex-ported UberDev skills, including command-skills)
2. **Agents** → `~/.codex/agents/uberdev-*.toml` (44 custom subagents, converted from Claude `.md`)
3. **Primer** → merged into the active global instruction file (`~/.codex/AGENTS.override.md` when present, otherwise `~/.codex/AGENTS.md`)

When run from a clone, the installer uses the local repo files. When run as the
one-liner, it downloads a temporary UberDev source snapshot, installs from that,
then removes the temporary copy.

Restart Codex. Verify:

```bash
ls ~/.agents/skills/      # ~39 UberDev skill dirs incl. command-skills
ls ~/.codex/agents/       # 44 uberdev-*.toml
grep uberdev-codex-primer ~/.codex/AGENTS*.md  # primer block present
```

**Uninstall:**

```bash
./codex/install-codex.sh --uninstall   # removes skills, agents, primer (preserves the rest of AGENTS.md)
```

## Path 2 — Codex-native plugin (browse & toggle)

```bash
# Add this repo as a marketplace source:
codex plugin marketplace add TheFJK/UberDev

# Then in the Codex TUI:
/plugins                    # open the plugin browser
# → find "uberdev-codex" under the uberdev marketplace
# → Space to enable
```

Or non-interactively:

```bash
codex plugin add uberdev-codex@uberdev
```

This installs the **skills + session-start hook + Markdown agent prompt files** as
a managed plugin (toggle on/off in `/plugins`, no file copying). The 42 Codex
custom-agent TOML files and the AGENTS.md primer are **not** part of the plugin —
run the standalone installer for those.

---

## What you get

### Skills (`~/.agents/skills/`)

Process skills (use these first — they determine *how* to approach a task):

- **brainstorm** — turn ideas into designs/specs via parallel research agents
- **write-plan** / **execute-plan** — spec → implementation plan → wave-based parallel execution
- **systematic-debugging** — root-cause hunting (5 Whys, find-the-polluter)
- **test-driven-development** — TDD discipline + anti-patterns
- **subagent-driven-dev** / **dispatching-parallel-agents** — fan-out orchestration
- **verification-before-completion** — done-check before claiming success

Implementation skills:

- **orchestrator** — the `/solve` / `/turbo` engine (research → spec → plan → waves)
- **solve-pipeline** / **goal-pipeline** / **merge-pipeline** / **dev-pipeline**
- **testers-pipeline** / **uberscan-pipeline** / **ubersimplify-pipeline** / **uberthink-pipeline**
- **using-git-worktrees**, **finish-branch**, **post-impl-review**, **cluster-pipeline**
- **requesting-code-review** / **receiving-code-review**
- **writing-skills**, **using-uberdev**, **scan-fleet**

### Command-skills (`$uberdev-cmd-<name>`)

The 13 Claude Code slash commands, re-homed as Codex skills (Codex custom
prompts are deprecated — skills are the documented shareable replacement).
Invoke explicitly with `$uberdev-cmd-issue`, or implicitly by describing the task
("create an issue for the login bug" triggers `uberdev-cmd-issue`):

| Skill | Claude command | What it does |
|---|---|---|
| `uberdev-cmd-issue` | `/issue` | well-investigated, deduped GitHub issue from a one-line ask |
| `uberdev-cmd-solve` | `/solve` | autonomous agent per issue (dispatch backend) |
| `uberdev-cmd-turbo` | `/turbo` | unattended `/solve` (auto-accept brainstorm) |
| `uberdev-cmd-review-pr` | `/review-pr` | parallel-fanout PR review (6 specialized lenses) |
| `uberdev-cmd-merge` | `/merge` | land approved PR + per-file conflict resolution |
| `uberdev-cmd-simplify` | `/simplify` | 3-lens simplification (Reuse/Quality/Efficiency) |
| `uberdev-cmd-testers` | `/testers` | read-only adversarial QA squad (8 personas) |
| `uberdev-cmd-dev` | `/dev` | fast-lane prototype → PR |
| `uberdev-cmd-goal` | `/uberdev:goal` | autonomous turbo→review→merge loop |
| `uberdev-cmd-cluster` | `/uberdev:cluster` | repo-wide issue similarity + fold |
| `uberdev-cmd-uberscan` | `/uberscan` | whole-codebase read-only audit |
| `uberdev-cmd-ubersimplify` | `/ubersimplify` | whole-codebase simplification |
| `uberdev-cmd-uberthink` | `/uberthink` | cross-domain ideation engine |

### Subagents (`~/.codex/agents/uberdev-*.toml`)

42 specialized personas the skills dispatch to. Codex custom-agent names are
prefixed with `uberdev-`; roles include `code-reviewer`, `spec-writer`,
`plan-writer`, `conflict-resolver`, `code-simplifier`, `silent-failure-hunter`,
`type-design-analyzer`, the 8 `testers-*` squad personas, the 6 `research-*`
scouts, the `uberthink-*` fleet, `findings-to-issues`, etc.

---

## How skills map to Codex (the important bit)

UberDev skills were authored against Claude Code's tool surface. When a skill
references a Claude tool, use the Codex equivalent (full table in
`~/.agents/skills/using-uberdev/references/codex-tools.md`):

| Skill references | Codex equivalent |
|---|---|
| `Task` (named subagent) | `spawn_agent` — prefer `agent_type="uberdev-<name>"`; fallback to reading `~/.codex/agents/uberdev-<name>.toml` and spawning `worker` |
| parallel `Task` calls | multiple `spawn_agent` + `wait_agent` |
| `TodoWrite` | `update_plan` |
| `Skill` tool | skills load natively — follow the instructions |
| `Workflow` tool | **no equivalent** — use the skill's `## No-Workflow fallback` section |
| `MultiEdit` | native file-edit tool |

The named-agent dispatch is the key workaround for plugin packaging: Codex can
load custom agents from `~/.codex/agents`, but the plugin manifest cannot ship
them yet. When a skill says `Task(uberdev:code-reviewer)`, prefer
`spawn_agent(agent_type="uberdev-code-reviewer", ...)` if that custom agent is
available in the current tool surface. If only built-in roles are exposed, read
`uberdev-code-reviewer.toml`'s `developer_instructions` and spawn a `worker`
with that content as the message. The primer in `~/.codex/AGENTS.md` (installed
above) has the full framing.

## Autonomous dispatch (`/solve` & `/turbo`)

The `codex` dispatch backend spawns one autonomous `codex exec` session per
issue, backgrounded via `nohup`, PID-tracked like the existing `background`
backend. It's auto-selected when:
- `CODEX_HOME` is set (you're running inside Codex), or
- `claude` is absent but `codex` is present.

Override explicitly:

```bash
# In a solve/turbo invocation:
--backend=codex        # force the codex backend
--backend=claude-bg    # force claude --bg (needs claude CLI)
```

The spawned session runs `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>`
in a per-issue git worktree. Liveness is PID-based (`kill -0`); the agent's
final message lands in the `-o` result file for post-run inspection.

## Known limitations (v1)

- **`Workflow` tool**: the testers-pipeline and scan-fleet skills use Claude's
  `Workflow` orchestration tool, which Codex lacks. They fall back to their
  `## No-Workflow fallback` path (bounded manual `spawn_agent` / directive
  fallback — functional, but not the Workflow orchestration Claude gives).
- **`uberdev_goal_review_pr_in_flight`**: the goal-loop's review-pr liveness
  check uses `claude agents --json` for Claude-backed sessions and the
  backend status JSON PID for `background` / `codex` sessions.
- **Agent execution profiles**: all 44 generated role TOMLs receive their
  default `model`, `model_reasoning_effort`, and `sandbox_mode` directly from
  `plugins/uberdev/policy/model-routing-v1.json` (RFC 0013). Claude
  `model: inherit` / `model: haiku` frontmatter no longer controls Codex.
  Leaf roles also set `features.multi_agent = false`; Codex 0.144.1 rejects
  `agents.max_depth = 0`, while the feature flag is a supported role-config
  field and prevents nested delegation.
- **`codex cloud exec`** (async server-side dispatch) is a future enhancement;
  v1 uses local `codex exec` + `nohup`.
- **Windows**: the codex backend is cross-platform (`codex exec` runs on
  Windows), but the dispatch tests' python3/rsync dependencies keep
  `codex-port.test.sh` off the Windows CI job (it runs on ubuntu).

## Regenerating the Codex artifacts

If you change the source skills/agents/commands, regenerate the Codex output:

```bash
# Skills → codex/uberdev-codex/skills/ (path-fixed copies)
bash codex/tools/port-skill.sh plugins/uberdev/skills codex/uberdev-codex/skills

# Agents → codex/agents/*.toml (Claude .md → Codex .toml)
python3 codex/tools/convert-agents.py plugins/uberdev/agents codex/agents

# Runtime Markdown prompts → codex/uberdev-codex/agents/ (Codex-path-safe copies)
bash codex/tools/port-agent-prompts.sh plugins/uberdev/agents codex/uberdev-codex/agents

# Commands → codex/uberdev-codex/skills/uberdev-cmd-*/ (13 command-skills)
python3 codex/tools/convert-commands.py plugins/uberdev/commands codex/uberdev-codex/skills

# Runtime shell libraries → codex/uberdev-codex/lib/
rsync -a --delete --exclude '__pycache__/' --exclude '*.pyc' --exclude '*.bak' --exclude '*.bak2' --exclude '*.fix' --exclude '.DS_Store' \
  plugins/uberdev/lib/ codex/uberdev-codex/lib/
```

All five are idempotent. Keep `codex/uberdev-codex/.codex-plugin/plugin.json`'s
`version` in sync with `plugins/uberdev/.claude-plugin/plugin.json`.

## License

MIT — same as the parent UberDev project.
