<div align="center">

# UberDev

**A personal Claude Code marketplace bundling opinionated GitHub-workflow slash commands.**

[![Version](https://img.shields.io/badge/version-0.8.0-blue)](https://github.com/TheFJK/UberDev)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8B5CF6)](https://docs.claude.com/en/docs/claude-code/plugins)
[![Repo Agnostic](https://img.shields.io/badge/repo--agnostic-yes-success)](#configuration)

```
   _   _ _               ____             
  | | | | |__   ___ _ __|  _ \  _____   __
  | | | | '_ \ / _ \ '__| | | |/ _ \ \ / /
  | |_| | |_) |  __/ |  | |_| |  __/\ V / 
   \___/|_.__/ \___|_|  |____/ \___| \_/  
```

**Three commands. Zero ceremony. Every issue, triaged and shipped.**

</div>

---

## TL;DR

Three slash commands that turn issue triage and resolution into one-line operations:

| Command | What it does |
|---|---|
| **`/solve <issue-number>`** | Spawns an autonomous Claude agent in a new terminal session (cmux / Ghostty / iTerm / Terminal.app / nohup) with **tier-aware triage** so trivial issues skip the brainstorm and large ones get the full plan-and-review pipeline. |
| **`/turbo <issue-number>`** | **Unattended `/solve`** — same pipeline, but the brainstorm phase auto-accepts the lead agent's recommended design instead of asking clarifying questions. Use when you trust the research-grounded recommendation and want issue → PR with no babysitting. Pair with `--auto` for max autonomy. |
| **`/issue <description>`** | Creates a **well-investigated, deduped, label-validated** GitHub issue from a one-line ask — including codebase search, full-text dedup against closed issues (regression signals), commitlint scope validation, and a triage hint that `/solve` reads later. |

Both are **repo-agnostic** — they auto-detect the current repo via `gh repo view`. No per-repo config required.

---

## Install

```bash
# 1. Add this repo as a Claude Code marketplace
/plugin marketplace add TheFJK/UberDev

# 2. Install the plugin
/plugin install uberdev@uberdev

# 3. Smoke-test
/uberdev:issue trivial typo in README install step
```

Optional — once verified, deconflict any pre-existing global commands so the unqualified `/solve` and `/issue` resolve to the plugin:

```bash
rm -i ~/.claude/commands/solve.md ~/.claude/commands/issue.md
```

---

## Updating

Claude Code does **not** auto-update third-party plugins by default — third-party marketplaces ship with auto-update **off**. Two options:

### Manual update (default)

```bash
/plugin marketplace update uberdev   # refresh marketplace metadata
/plugin install uberdev@uberdev      # reinstall to pull the new version
```

Or interactively: `/plugin` → **Installed** → select `uberdev` → re-install.

### Enable auto-update for this marketplace (one-time)

`/plugin` → **Marketplaces** tab → select `uberdev` → toggle auto-update on. Claude Code then picks up new versions whenever the `version` field in `plugin.json` is bumped.

> **Disabling everything:** set `DISABLE_AUTOUPDATER=1` in your shell environment to globally disable Claude Code's auto-updater (affects Claude Code itself + every plugin).

Each release bumps the `version` field in `.claude-plugin/plugin.json`, so auto-update users get clean version transitions; manual users see the new version listed under the marketplace entry.

---

## Prerequisites

| Requirement | Why |
|---|---|
| **`gh` CLI** authenticated against your target repos | Used for repo detection, label/scope validation, dedup search, issue creation |
| **macOS** (Apple Silicon or Intel) | Terminal dispatch uses `osascript` for iTerm/Terminal.app; Linux/Windows degrade to detached `nohup` |
| **Claude Code 2.x+** with plugin support | Required for `/plugin marketplace add` |
| **One of:** cmux, Ghostty, iTerm2, Terminal.app | `/solve` auto-detects; falls back to detached `nohup` if none found |

---

## `/solve` — autonomous issue resolution

Auto-classifies a GitHub issue into a tier, then spawns an agent with a tier-appropriate workflow.

### Triage tiers

| Tier | Auto-detected from… | Spawned workflow |
|---|---|---|
| **trivial** | Labels `typo`, `docs`, `chore`, `good-first-issue`. Body <300 chars. Single file named. | Direct edit → test if touched code is tested → `/uberdev:simplify` → PR |
| **small** | Clear reproduction + error. Localized to one module. Estimated ≤50 LOC. | Lightweight TodoWrite plan (3–6 tasks) → TDD → `/uberdev:simplify` → PR |
| **medium / large** *(default)* | Labels `epic`, `architectural`, `infrastructure`. ≥3 files mentioned. Cross-package scope. Open questions. | Full `/uberdev:orchestrator` (research fanout → optional Q&A → spec-writer → optional spec-reviewer → plan-writer) → `/uberdev:subagent-driven-dev` → `/uberdev:review-pr` |

> **When in doubt, default to medium.** The spawned agent is explicitly told it may escalate to `/uberdev:orchestrator` mid-flight if the scope proves larger than triaged — **misclassification is recoverable, not catastrophic.**

### Manual overrides

```bash
/solve 123 --trivial                  # Force trivial tier
/solve 123 --small                    # Force small tier
/solve 123 --full                     # Force medium/large
/solve 123 --terminal=ghostty         # Force terminal dispatcher
SOLVE_TERMINAL=cmux /solve 123        # Same, via env var
```

### What runs in the spawned terminal

The agent inherits a model pin and effort cap so behavior is reproducible across runs:

```bash
claude \
  --model 'claude-opus-4-7[1m]' \
  --effort max \
  --worktree solve-issue-123 \
  --dangerously-skip-permissions \
  "$PROMPT"
```

After opening its PR, the spawned agent **renames its own terminal tab** from `#123 <issue-title>` to `PR #456 <pr-title>` via OSC escape sequences (or cmux's workspace API).

---

## `/turbo` — unattended issue resolution

Identical to `/solve` for trivial / small tiers. For medium / large tiers, the brainstorm phase auto-accepts the lead agent's recommendation instead of asking clarifying questions — so the whole pipeline runs without user input.

### When to use which

| Combo | Brainstorm Q&A | Tool gating |
|---|---|---|
| `/solve 42` | interactive | manual per-tool gating |
| `/solve 42 --auto` | interactive | AI classifier (auto-approves safe ops) |
| `/turbo 42` | auto-accept recommendation | manual per-tool gating |
| `/turbo 42 --auto` | auto-accept recommendation | AI classifier — **max autonomy** |

`/turbo` and `--auto` are **orthogonal**: `/turbo` governs brainstorm interactivity; `--auto` governs Claude Code's per-tool permission mode. Pair them for unattended issue → PR.

### Safety

- Spec & plan are still written to disk before implementation waves dispatch — audit them to course-correct.
- A stderr banner before terminal spawn confirms turbo mode is active.
- Trivial / small tiers don't run brainstorm anyway, so `/turbo` is functionally identical to `/solve` there. The intent-signaling name + `--auto` shortcut is the only difference.
- No new approval gates introduced — turbo only **removes** the clarifying-questions stop, never **adds** one.

---

## `/issue` — investigation-first issue creation

Eight-phase pipeline that does the legwork **before** you draft, **before** you create, and **before** you spend a sprint chasing a duplicate ticket.

```mermaid
flowchart TD
    A["/issue 'Login fails on Safari for empty password'"] --> B[Phase 1: Classify type / scope / core problem]
    B --> C[Phase 2: Investigate codebase]
    C --> D[Phase 3: Duplicate search<br/>full-text, includes closed]
    D --> E[Phase 4: Validate labels + scope<br/>against gh label list & commitlint]
    E --> F[Phase 5: Draft]
    F --> G{Phase 6: User confirms?}
    G -- edits --> F
    G -- yes --> H[Phase 7: Create issue]
    H --> I[Phase 8: Print 'Next step: /solve N']
    I --> J["/solve N"]
    J --> K{Triage tier from issue body}
    K -- trivial --> L[Direct edit → PR]
    K -- small --> M[Plan + TDD → PR]
    K -- medium/large --> N[uberdev: brainstorm + write-plan + execute + review-pr → PR]
    L --> O[Rename tab: 'PR #M ...']
    M --> O
    N --> O
```

### Templates

`/issue` produces conventional-commit-style titles and one of four body templates depending on type:

<details>
<summary><strong>Bug (<code>fix</code>)</strong> — click to expand</summary>

```markdown
## Bug
[Clear description — what's broken]

## Expected behavior / Observed behavior
...

## Severity
- [ ] P0 — pages on-call, system down
- [ ] P1 — major feature broken
- [x] P2 — normal bug (default)
- [ ] P3 — minor / cosmetic

## Likely root cause
- **Symptom:** [observable failure mode in user-facing terms]
- **Mechanism:** [the specific code/data path that produces the symptom; cite a concrete artifact such as a function call site, log line, or config value]
- **Owning code:** `path/to/File` — `Class.method()` — [why this is the assumption to challenge]

## Likely area
- `path/to/File` — `ClassName.methodName()` — [why relevant]

## Reproduction
1. ...

## Related
- [Closed/open issues from Phase 3 dedup search, else "none"]

**Triage hint:** <trivial|small|medium>
```

</details>

<details>
<summary><strong>Feature (<code>feat</code>)</strong></summary>

```markdown
## Summary
[What and why]

## Relevant code
- `path/to/File` — `ClassName` — [how it relates]

## What changes
[The capability being added or behavior being modified — externally visible result, contract change, or new affordance. No implementation strategy.]

## Acceptance criteria
- [ ] [criterion]

## Related
- [Prior issues, if any]

**Triage hint:** <trivial|small|medium>
```

</details>

<details>
<summary><strong>Chore / Refactor</strong></summary>

```markdown
## Summary
[What needs doing and why]

## Relevant code
- `path/to/File` — [context]

**Triage hint:** <trivial|small|medium>
```

</details>

### Skip the codebase investigation

For docs/typo issues unrelated to code logic:

```bash
/issue Fix the install step in the README — wrong command --no-explore
```

---

## Configuration

| Env var | Purpose | Default |
|---|---|---|
| `SOLVE_TERMINAL` | Override `/solve`'s terminal dispatcher (`cmux` / `ghostty` / `iterm` / `terminal` / `nohup`) | Auto-detect |

That's it. No `.env` files, no per-repo config, no plugin settings to wire up.

---

## Repo layout

```
UberDev/
├── .claude-plugin/
│   └── marketplace.json          ← Marketplace manifest (lists 1 plugin)
├── plugins/
│   └── uberdev/
│       ├── .claude-plugin/
│       │   └── plugin.json       ← Plugin manifest
│       └── commands/
│           ├── solve.md          ← /solve command body (251 lines)
│           └── issue.md          ← /issue command body (204 lines)
├── .gitignore
└── README.md
```

The marketplace can host additional plugins later — drop a new folder under `plugins/` and add an entry to `marketplace.json`.

---

## Design decisions worth knowing

| Decision | Rationale |
|---|---|
| **Repo-agnostic by default** | Both commands derive `$REPO` from `gh repo view` at runtime. No hardcoded org/project IDs. |
| **No GitHub Project board auto-add** | Kept out of v0.1 to stay portable. May return in v0.2 via opt-in `.claude/board.json`. |
| **Model pin baked in** *(in `solve.md`)* | Spawned agents run on `claude-opus-4-7[1m]` for reproducibility across runs. Forks should adjust to their preferred model. |
| **macOS-first terminal dispatch** | `osascript` for iTerm / Terminal.app, native cmux/Ghostty CLI for those, `nohup` fallback elsewhere. |
| **Triage hint in every issue body** | Lets `/solve` skip re-classification and pick the right workflow without rereading the whole body. |
| **Conventional commits enforced** | `feat(scope):` / `fix(scope):` / `chore(scope):` / `refactor(scope):`. `enhancement` is a **label**, never a type. |
| **Wave-based parallel execution** *(see below)* | Plans declare task dependencies + file ownership; `subagent-driven-dev` fires every wave's tasks concurrently in one shared worktree. Controller-only git eliminates index races without per-task worktree ceremony. |

---

## Wave-based parallel execution (Pattern B)

`/solve` and `/uberdev:subagent-driven-dev` execute multi-task plans in **waves**: every task in a wave dispatches in parallel, waves run sequentially.

### How a plan declares it

`uberdev:write-plan` requires three new headers per task and an `## Execution Waves` summary:

```markdown
## Execution Waves

- **wave-1** (parallel): T1, T2, T3
- **wave-2** (parallel, depends on wave-1): T4, T5
- **wave-3** (sequential, depends on wave-2): T6

### Task 4: Recovery modes

**Depends on:** T1
**Wave:** wave-2
**Owns (file allowlist):** src/recovery.ts, tests/recovery.test.ts
```

Tasks share a wave **only** if their `Owns` allowlists are pairwise disjoint. Overlap → bump the later task to the next wave. The plan-writer's self-review checks acyclic deps + disjoint allowlists before saving.

### How execution stays race-free

| Concern | Pattern B solution |
|---|---|
| Two implementers writing the same file | Plan declares disjoint `Owns` allowlists; each implementer prompt enforces an allowlist + a denylist of sibling-owned paths |
| Concurrent `git add` / `git commit` racing on `.git/index.lock` | **Implementers never run git.** They edit files, run their tests, and report changed paths. The controller stages and commits per task, sequentially, in task ID order |
| A regression introduced by parallel edits hiding until later | Controller runs the project's full test suite once after all wave commits land — before any review dispatches |
| Reviewer of task A reading task B's code | Spec + code-quality reviewer prompts include the task's `BASE_SHA`, `HEAD_SHA`, and explicit allowlist; reviewers ignore changes outside |
| Worktree sprawl | One shared feature-branch worktree across all waves. No merge step between waves. Same worktree `/solve` already creates. |

### Why one shared worktree, not one per agent

Per-agent worktrees would isolate filesystems but add N `git worktree add` calls, an N-way merge step at the end of every wave, and cross-worktree resync time. Pattern B drops all of that by:

1. Letting agents share the worktree (safe because the plan proves disjoint file ownership).
2. Refusing to let agents touch git at all (safe because the controller serializes commits).

Result: maximum parallelism on edits, deterministic commit history, zero merge ceremony.

### Trade-offs you should know

- **Plans must decompose into truly disjoint file sets.** If wave-1 is one bottleneck task that everything depends on, you don't actually get parallelism — fix the decomposition.
- **Implementers can't self-stage.** If your task naturally wants ad-hoc commits (e.g., a bisect-friendly history mid-task), Pattern B forces you to wait for the controller. For most tasks that's fine.
- **The full-suite run between waves costs wall-time.** It's the trade for catching regressions before review dispatch instead of during.

---

## Roadmap

| Version | Status | Adds |
|---|---|---|
| **v0.1.0** | Released | `/solve`, `/issue` — repo-agnostic, no project-board logic |
| **v0.2.0** | Released | Bundles 4 workflow skills (`brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`), 6 review agents (`code-reviewer`, `code-simplifier`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`), and 2 commands (`/uberdev:review-pr`, `/uberdev:simplify`) — `/solve` runs standalone with no superpowers / pr-review-toolkit / code-simplifier dependency |
| **v0.2.1** | Released | **Wave-based parallel execution (Pattern B):** `write-plan` requires `Depends on:` / `Wave:` / `Owns:` per task and an `## Execution Waves` summary; `subagent-driven-dev` dispatches every task in a wave concurrently in one shared feature-branch worktree, with the controller (not the implementers) running git to avoid index races. Cuts wall-time on multi-task plans roughly N× per wave with zero merge ceremony. |
| **v0.3.0** | Released | Full Superpowers parity port (remaining skills: `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev`); brainstorm Visual Companion (Neo Brutalism UI, local server + frame-template.html, sessions persist to `.uberdev/brainstorm/`); SessionStart hook injects the `using-uberdev` primer. |
| **v0.3.1** | Released | **`/uberdev:simplify` realigned with Anthropic's built-in `/simplify`:** three-parallel-agent orchestrator — Code Reuse, Code Quality, Efficiency reviewers fan out concurrently in a single Task-tool turn; controller aggregates findings and fixes them. Iron rule preserved (no behavior changes), plus uberdev's separate `refactor:` commit mandate. Was previously a single-agent dispatch — drift fix bringing parity with the canonical flow shipped in the Claude Code binary. |
| **v0.4.0** | Released | **Parallel fanout spread across the plugin.** `/uberdev:review-pr` flips default from sequential to **parallel** (all applicable review agents dispatch concurrently in a single turn — divergence from upstream `pr-review-toolkit`). `/uberdev:issue` Phase 2/3/4 (codebase investigation + duplicate search + label/scope validation) now runs as three parallel agents, ~60-70% wall-time savings. `verification-before-completion` documents parallel verification dispatch (independent test/lint/build/typecheck checks). `systematic-debugging` adds **competing-hypothesis fanout** — read-only investigators, one per hypothesis, no anchoring. `brainstorm` gains optional parallel design-direction exploration for high-stakes designs. `write-plan` gains opt-in alternative-plan generation (3 decomposition strategies). `receiving-code-review` adds multi-reviewer parallel triage. |
| **v0.5.0** | Released | **Hardening + perf + new platform features.** Security: closes RCE in `/solve` (drops `--dangerously-skip-permissions`), prompt-injection in `inject-brainstorm-answers` (per-line JSON validation, `<`/`>` escaping, symlinked-path refusal), and fragile JSON in `session-start` (jq-based encoding). Critical bug fix: v0.4.0 `/issue` parallel fanout was silently broken — vars now resolved in orchestrator and baked literally into each subagent brief. Perf: 5 detail agents → Haiku 4.5 (~15-20% wall-time on `/uberdev:review-pr`); per-line `jq` fork in brainstorm-answers hook → streaming `jq -R 'fromjson?'` (~200-500ms saved per user prompt). New: `SessionEnd` + `PreCompact` hooks; `.claude/uberdev.local.md` per-project config; `AskUserQuestion` fast-path in `brainstorm`; cross-platform `sed -i` in `/solve`; YAML frontmatter on `/issue` and `/solve`; tightened `allowed-tools`; `CONTRIBUTING.md` + `CHANGELOG.md` (Keep-a-Changelog 1.1.0); stack-agnostic `code-simplifier`. |
| **v0.6.0** | Released | **Unattended workflow + Ghostty integration.** New `/turbo <issue>` — unattended `/solve` that auto-accepts brainstorm recommendations for medium/large tier (parallel research still runs — recommendation grounding preserved); trivial/small tier behaves identically to `/solve`. New `/solve --auto` and `/turbo --auto` flags enable Claude Code's `--permission-mode auto` classifier (auto-approves safe ops; blocks force push, exfil, self-modification, `--dangerously-skip-permissions`). `/solve` and `/turbo` Ghostty dispatcher tab-spawns into the originating Ghostty window when invoked from inside Ghostty (per-project workspaces stay grouped); `SOLVE_GHOSTTY_NEW_WINDOW=1` forces legacy new-window dispatch; AppleScript failures fall back automatically. `brainstorm` skill: parallel research dispatch promoted to default first step (proposed approaches grounded in research synthesis, not speculation). Removed deprecated slash-command shims `/uberdev:brainstorm`, `/uberdev:execute-plan`, `/uberdev:write-plan` (Superpowers-port leftovers — invoke skills directly via the Skill tool). |
| **v0.7.0** | Released | **Writer-subagent orchestrator.** New `/uberdev:orchestrator` skill — 5-phase pipeline used by `/solve` and `/turbo` for medium/large tier: research fanout (parallel Sonnet subagents) → optional Q&A (skipped for `/turbo`) → spec-writer (Opus) → optional spec-reviewer (Opus, gated by `--paranoid` for medium tier; always for large tier) → plan-writer (Opus, with internal research fanout) → existing `subagent-driven-dev`. Each writer returns a structured YAML summary; orchestrator main holds pointers, not raw artifacts — reclaims context for wave dispatch and error recovery. 8 new agent definitions: `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints` (Sonnet); `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer` (Opus). New `--paranoid` flag enables spec-reviewer for medium tier. `/solve` and `/turbo` medium/large prompts now invoke `/uberdev:orchestrator` instead of `/uberdev:brainstorm` directly; trivial/small paths unchanged. `write-plan` execution handoff is now non-interactive (default subagent-driven, explicit opt-in for inline). Closes #5 architecturally — `/turbo` no longer halts on a "Subagent-Driven vs. Inline Execution?" prompt. |
| **v0.7.1** | Released | **`/turbo` end-to-end unattended chain.** Threads `--turbo` through every handoff (`brainstorm` → `write-plan` → `subagent-driven-dev` → `finish-branch`, plus the `orchestrator` Phase 5 → `subagent-driven-dev` link that PR #8 introduced). `finish-branch` auto-selects "Push and Create PR" under `--turbo` instead of prompting; pre-existing Step 5 contradiction (Quick Reference / Red Flags said cleanup runs only for Options 1 & 4, but Step 5 listed Options 1, 2, 4) resolved in favor of consistency — Option 2 leaves the worktree alive for PR-feedback fixups. New `tests/turbo-flow.test.sh` (9 contract assertions) locks the `--turbo` propagation contract at every handoff site so a future skill edit can't silently re-attend the flow. |
| **v0.8.0** | Current | **`/uberdev:issue` deep root-cause research fanout + WHAT/HOW boundary.** Phase 2 dispatches a 2-agent parallel fanout (`research-codebase` + `research-patterns`) alongside the existing Phase 3/4 agents — four agents fan out together in a single message; Phase 4.5 aggregates all four returns. Bug-template `## Likely root cause` becomes a causal triple (Symptom / Mechanism / Owning code) with optional 5 Whys for non-trivial bugs; bare file-path lists in this section are forbidden. Feat-template `## Proposed approach` is renamed to `## What changes` (field-name pressure replaces rules-text pressure). New "Body authoring rules" subsection ahead of the templates codifies WHAT/HOW. Research summaries persist to `.uberdev/research/issue-<N>/` (renamed from `run-<RUN_ID>/` after `gh issue create`); `/uberdev:brainstorm` step 2 short-circuits on this directory per-topic with mtime-based staleness fallback, eliminating the duplicate codebase-research round when invoked downstream of `/issue`. New `tests/issue-causal-fanout.test.sh` (structural assertions, modelled on `tests/turbo-flow.test.sh`) locks the contract invariants. RFC at `docs/rfc/2026-04-29-issue-deep-root-cause-research-fanout.md`. No breaking change — `**Triage hint:**`, severity checkboxes, label format, and conventional-commit titles preserved verbatim. Closes #9. |
| **v0.9** | Maybe | Optional per-repo `.claude/board.json` for re-enabling project-board auto-add |
| **v0.10** | Maybe | Linux + Windows terminal dispatchers; configurable model pin via env |

---

## Bundled (since v0.2.0)

UberDev ships these so `/solve` and `/issue` work standalone — **no `superpowers`, `pr-review-toolkit`, or `code-simplifier` plugin install required**.

| Type | Slug | Source |
|---|---|---|
| Skill | `uberdev:brainstorm` | adapted from [`superpowers:brainstorming`](https://github.com/obra/superpowers) (MIT, Jesse Vincent) |
| Skill | `uberdev:write-plan` | adapted from `superpowers:writing-plans` |
| Skill | `uberdev:execute-plan` | adapted from `superpowers:executing-plans` |
| Skill | `uberdev:subagent-driven-dev` | adapted from `superpowers:subagent-driven-development` |
| Skill | `uberdev:finish-branch` | adapted from `superpowers:finishing-a-development-branch` (renamed) |
| Agent | `uberdev:code-reviewer` | verbatim from [`pr-review-toolkit`](https://github.com/anthropics/claude-code) (Apache 2.0, Anthropic) — CLAUDE.md/style compliance focus |
| Agent | `uberdev:plan-reviewer` | adapted from [`superpowers:code-reviewer`](https://github.com/obra/superpowers) (MIT, Jesse Vincent) — plan-vs-implementation focus (renamed `code-reviewer` → `plan-reviewer` to avoid slug collision) |
| Agent | `uberdev:comment-analyzer` | verbatim from `pr-review-toolkit` |
| Agent | `uberdev:pr-test-analyzer` | verbatim from `pr-review-toolkit` |
| Agent | `uberdev:silent-failure-hunter` | verbatim from `pr-review-toolkit` |
| Agent | `uberdev:type-design-analyzer` | verbatim from `pr-review-toolkit` |
| Agent | `uberdev:code-simplifier` | verbatim from [`code-simplifier`](https://github.com/anthropics/claude-code) v1.0.0 (Apache 2.0, Anthropic) |
| Command | `/uberdev:review-pr` | adapted from `pr-review-toolkit:/review-pr` |
| Command | `/uberdev:simplify` | mirrors Anthropic's built-in `/simplify` (3-phase orchestrator: identify diff → fan out 3 parallel review agents — Reuse, Quality, Efficiency — → aggregate + fix → separate `refactor:` commit) |

Adaptations for the skills: dropped Visual Companion section from `brainstorm` (browser-based mockup server, never used by spawned headless `/solve` agents); retargeted all `superpowers:*` cross-references to `uberdev:*`; replaced references to non-bundled superpowers skills (`using-git-worktrees`, `test-driven-development`, `requesting-code-review`, `finishing-a-development-branch`) with inline prose preserving the discipline. Bundled upstream license texts are in `plugins/uberdev/licenses/`.

---

## FAQ

<details>
<summary><strong>Why "UberDev"?</strong></summary>

Personal brand. The marketplace name and repo are `UberDev`; the plugin inside is `uberdev` (lowercase to match Claude Code naming conventions).

</details>

<details>
<summary><strong>Will <code>/solve</code> work outside macOS?</strong></summary>

Partially. The terminal-dispatch chain falls through to `nohup` (detached background process with logs in `/tmp/solve-N.log`) on any platform without a recognized terminal app. You lose the per-issue tab and notifications, but the agent still runs.

</details>

<details>
<summary><strong>Why no <code>LICENSE</code> file?</strong></summary>

License is declared in `plugin.json` (`"license": "MIT"`) which is enough for the plugin metadata. A repo-root `LICENSE` file may land in a future patch for GitHub UI parity.

</details>

<details>
<summary><strong>How do I disable the plugin without uninstalling?</strong></summary>

```
/plugin disable uberdev@uberdev
```

Or edit `~/.claude/settings.json` and flip the entry to `false`:

```json
"enabledPlugins": {
  "uberdev@uberdev": false
}
```

</details>

---

## License

MIT. See [`plugins/uberdev/.claude-plugin/plugin.json`](plugins/uberdev/.claude-plugin/plugin.json) for the manifest declaration. A standalone `LICENSE` file may land later.

---

<div align="center">

**Built by [@TheFJK](https://github.com/TheFJK) for shipping fast on solo and small-team GitHub projects.**

*If you fork this, [open an issue](https://github.com/TheFJK/UberDev/issues) — I'd love to see what you build on top.*

</div>
