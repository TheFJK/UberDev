<div align="center">

# UberDev

**Personal Claude Code marketplace — opinionated GitHub-workflow slash commands.**

[![Version](https://img.shields.io/badge/version-0.14.0-blue)](./CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8B5CF6)](https://docs.claude.com/en/docs/claude-code/plugins)
[![Repo Agnostic](https://img.shields.io/badge/repo--agnostic-yes-success)](#configuration)

```
   _   _ _               ____             
  | | | | |__   ___ _ __|  _ \  _____   __
  | | | | '_ \ / _ \ '__| | | |/ _ \ \ / /
  | |_| | |_) |  __/ |  | |_| |  __/\ V / 
   \___/|_.__/ \___|_|  |____/ \___| \_/  
```

**Five commands. Zero ceremony. Every issue, triaged, shipped, merged.**

</div>

---

## Heads up — this plugin burns tokens fast

UberDev's whole personality is **parallel agent fanout**: `/issue` runs a 2-Sonnet-scout fanout, `/uberdev:review-pr` and `/uberdev:simplify` fan out 3–5 reviewers concurrently, `/solve` waves dispatch every task in parallel, `/merge` spawns one conflict-resolver per conflicted file. That's where the speed and quality come from — and that's where the cost comes from.

**Recommended setup: 2× Claude Max ×20 subscriptions.** A single Pro or single Max usage window genuinely is not enough headroom for a normal day of `/turbo` + `/review-pr` + `/merge` cycles. Expect to hit the limit mid-task on a single seat.

**If that's too much, scale down:** prefer `/solve --trivial` / `--small` (skips the orchestrator), skip `/turbo` (interactive `/solve` runs fewer agents), or use a less aggressive plugin. The defaults are tuned for *"ship faster, pay for it"* — a deliberate choice, not a bug.

---

## TL;DR

| Command | What it does |
|---|---|
| **`/solve <issue#>`** | Spawns an autonomous Claude agent in a new terminal (cmux / Ghostty / iTerm / Terminal.app / nohup). Tier-aware: trivial issues skip brainstorm; large ones get the full orchestrator → spec → plan → wave-dispatch → review pipeline. |
| **`/turbo <issue#>`** | Unattended `/solve`. Same pipeline, but the brainstorm phase auto-accepts the lead agent's recommendation and Q&A is resolved against the research bundle. Use when you trust the recommendation and want issue → PR with no babysitting. |
| **`/issue <description>`** | Creates a well-investigated, deduped, label-validated GitHub issue from a one-line ask. 2-Sonnet-scout fanout (codebase + triage) runs in <30 s, with conventional-commit titling and template-by-type. |
| **`/review-pr [<PR#>]`** | Comprehensive PR review using specialized agents fanned out in parallel — code review, simplifier, silent-failure hunter, type-design analyzer, comment analyzer, test analyzer. |
| **`/merge [<PR#> \| --all]`** | Lands an approved PR into the integration branch — autopilot. Ordering, per-PR strategy, conflict resolution (one parallel agent per conflicted file), and local sync, all unattended. |

Every command is **repo-agnostic** — they auto-detect via `gh repo view`. No per-repo config required.

---

## Install

```bash
# One-liner — installs the plugin and patches the missing enabledPlugins entry.
curl -fsSL https://raw.githubusercontent.com/TheFJK/UberDev/main/install.sh | bash
```

Then in Claude Code:

```bash
/uberdev:issue trivial typo in README install step   # smoke-test
```

The six short-form aliases (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`) are auto-installed on first session and refreshed on plugin upgrade. Opt out with `auto_install_aliases: false` in `.claude/uberdev.local.md` or `UBERDEV_NO_AUTO_ALIAS=1`.

> **Why a bootstrap script?** Upstream Claude Code has a bug ([anthropics/claude-code#20661](https://github.com/anthropics/claude-code/issues/20661)) where `/plugin install` populates the cache but does not write `enabledPlugins` in `~/.claude/settings.json` — so `/uberdev:*` commands silently 404. `install.sh` does the install **and** jq-patches `enabledPlugins`. Idempotent. Requires `jq`.

<details>
<summary><strong>Manual install (without curl|bash)</strong></summary>

```bash
# 1. Inside Claude Code:
/plugin marketplace add TheFJK/UberDev
/plugin install uberdev@uberdev

# 2. In your shell — patch the entry the upstream bug skips:
[ -s ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
jq '.enabledPlugins["uberdev@uberdev"] = true' \
   ~/.claude/settings.json > ~/.claude/settings.json.tmp \
   && mv ~/.claude/settings.json.tmp ~/.claude/settings.json

# 3. Back in Claude Code:
/reload-plugins
```

</details>

---

## Updating

Third-party plugins ship with auto-update **off**. Two options:

**Manual (default)** — refresh marketplace metadata, then reinstall:

```bash
/plugin marketplace update uberdev
/plugin install uberdev@uberdev
```

**Auto-update for this marketplace** — `/plugin` → **Marketplaces** → select `uberdev` → toggle auto-update on. Picks up new versions when `version` in `plugin.json` is bumped.

Disable Claude Code's auto-updater globally with `DISABLE_AUTOUPDATER=1` in your shell environment.

---

## Prerequisites

| Requirement | Why |
|---|---|
| **`gh` CLI** authenticated against your target repos | Repo detection, label/scope validation, dedup search, issue & PR ops |
| **`jq`** | Used by `install.sh` and `/merge` |
| **macOS** (Apple Silicon or Intel) | Terminal dispatch via `osascript` for iTerm/Terminal.app; Linux/Windows degrade to detached `nohup` |
| **Claude Code 2.x+** with plugin support | Required for `/plugin marketplace add` |
| **One of:** cmux, Ghostty, iTerm2, Terminal.app | `/solve` auto-detects; falls back to detached `nohup` if none found |

---

## `/solve` — autonomous issue resolution

Auto-classifies a GitHub issue into a tier, then spawns an agent with a tier-appropriate workflow.

| Tier | Auto-detected from… | Spawned workflow |
|---|---|---|
| **trivial** | Labels `typo`/`docs`/`chore`/`good-first-issue`. Body <300 chars. Single file named. | Direct edit → test if touched code is tested → `/uberdev:simplify` → PR |
| **small** | Clear repro + error. Localized to one module. ≤50 LOC. | Lightweight TodoWrite plan (3–6 tasks) → TDD → `/uberdev:simplify` → PR |
| **medium / large** *(default)* | Labels `epic`/`architectural`/`infrastructure`. ≥3 files mentioned. Cross-package. | `/uberdev:orchestrator` (research fanout → optional Q&A → spec-writer → spec-reviewer (always-on for medium+) → plan-writer → plan-reviewer) → `/uberdev:subagent-driven-dev` wave dispatch → `/uberdev:review-pr` |

> **Misclassification is recoverable** — the spawned agent can escalate to `/uberdev:orchestrator` mid-flight if the scope proves larger than triaged. When in doubt, defaults to medium.

**Manual overrides:**

```bash
/solve 123 --trivial                  # force trivial tier
/solve 123 --small                    # force small tier
/solve 123 --full                     # force medium/large
/solve 123 --terminal=ghostty         # force terminal dispatcher
SOLVE_TERMINAL=cmux /solve 123        # same, via env
```

**What runs in the spawned terminal** — model and effort are pinned so behavior is reproducible across runs:

```bash
claude \
  --model 'claude-opus-4-7[1m]' \
  --effort max \
  --worktree solve-issue-123 \
  "$PROMPT"
```

After opening its PR, the agent renames its own terminal tab from `#123 <issue-title>` to `PR #456 <pr-title>` via OSC escape sequences (or cmux's workspace API).

**Wave-based parallel execution** — multi-task plans declare `Depends on:` / `Wave:` / `Owns:` per task. Tasks share a wave only if their `Owns` allowlists are pairwise disjoint. Implementers never run git (controller serializes commits) — eliminates `.git/index.lock` races without per-task worktree ceremony. Maximum parallelism on edits, deterministic commit history, zero merge ceremony between waves.

---

## `/turbo` — unattended issue resolution

Identical to `/solve` for trivial / small. For medium / large, the brainstorm phase **auto-accepts the lead agent's recommendation** instead of asking clarifying questions, and Phase 2 Q&A becomes non-blocking — clarifying answers are auto-picked from the research-bundle synthesis and written to `questions.md` for audit.

| Combo | Brainstorm Q&A | Tool gating |
|---|---|---|
| `/solve 42` | interactive | manual per-tool |
| `/solve 42 --auto` | interactive | AI classifier |
| `/turbo 42` | auto-accept | manual per-tool |
| `/turbo 42 --auto` | auto-accept | AI classifier — **max autonomy** |

`/turbo` and `--auto` are orthogonal: `/turbo` governs brainstorm interactivity; `--auto` governs Claude Code's per-tool permission mode.

**Multi-issue dispatch.** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and spawns three independent agents — one terminal tab/workspace each, all running in parallel. Override flags (`--trivial|--small|--full`, `--auto`, `--terminal=...`) apply batch-wide. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). `/solve` accepts the same syntax.

Spec & plan are still written to disk before implementation — audit them mid-flight to course-correct.

---

## `/merge` — post-review PR landing (autopilot)

Lands approved PRs into the integration branch — fully unattended. No prompts, no halts. Per-PR failures park; the queue continues.

1. **Pre-flight gate** — open / not-draft / approved (`reviewDecision == "APPROVED"`) / CI-green; integration branch resolved (CLI flag > env var > config > `gh repo view`'s default > literal `main`); single-instance lock.
2. **Merge plan** — order (topo-sort hard deps → file-overlap heuristic → approval-age tie-break) + per-PR strategy (conventional-commit ratio + WIP-msg count + `merge-strategy:<name>` label).
3. **Merge + resolve** — non-destructive `git merge-tree` probe; clean PRs via `gh pr merge --<strategy>`; conflicted PRs get one parallel agent per conflicted file in a scratch worktree, project test gate, fast-forward push back (Conventional Commits prefix, no Claude trailer).
4. **Local sync** — `git fetch --prune`, `git pull --ff-only` on integration branch (auto-rebase on ff-only fail), worktree teardown, stale-rooted branch list (never auto-rebase).

**Audit log** — `.uberdev/runs/<run-id>/audit.jsonl`, one JSON line per event (gate, order, strategy, probe, agent, patch, test, push, merge, sync). Path surfaced in the final summary.

**Configuration** in `.claude/uberdev.local.md`:

```yaml
---
integration_branch: main
---
```

Or per-invocation: `--integration-branch=develop`.

> **Note (v0.14.0):** `bot_authors_allow_list`, `auto_confirm`, and `--yes`/`-y` are deprecated no-ops. Autopilot has no author gate and asks no questions; the trust anchor is `reviewDecision == "APPROVED"` plus GitHub branch protections.

---

## `/issue` — investigation-first issue creation

Pipeline: classify → 2-Sonnet-scout fanout (`codebase-scout` + `triage-scout`, parallel in one turn — dedup against closed issues, label/scope validation against `gh label list` and commitlint) → draft → user-confirm → create → print `Next step: /solve N`. Median wall-clock under 30 seconds.

Templates by type — bug (`fix`), feature (`feat`), or chore/refactor — each producing conventional-commit-style titles and a body footed with `**Triage hint:** <trivial|small|medium>` that `/solve` reads later to pick the workflow without reclassifying.

After the spawned agent's PR is approved (and you've run `/uberdev:review-pr`), run `/merge <PR#>` to land it.

**Skip the codebase investigation** for docs/typo issues unrelated to code logic:

```bash
/issue Fix the install step in the README — wrong command --no-explore
```

---

## Configuration

Per-repo settings live in `.claude/uberdev.local.md` (YAML frontmatter; ignored by git). Env vars override file values.

```yaml
---
solve_terminal: ghostty       # ghostty | iterm | cmux | terminal | nohup
solve_auto: false             # auto-accept brainstorm recommendations (= /turbo)
auto_install_aliases: true    # install short-form forwarders at SessionStart
integration_branch: main      # /merge target branch (overrides gh repo view default)
---
```

| Env var | File key | Purpose |
|---|---|---|
| `SOLVE_TERMINAL` | `solve_terminal` | Override `/solve`'s terminal dispatcher (`cmux` / `ghostty` / `iterm` / `terminal` / `nohup`) |
| `SOLVE_AUTO` | `solve_auto` | When `1`/`true`, spawned agent runs with `--permission-mode auto` |
| `UBERDEV_NO_AUTO_ALIAS` | `auto_install_aliases` | When `1`/`true` (env) or `false` (file), suppresses session-start auto-install of `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge` forwarders |
| `UBERDEV_INTEGRATION_BRANCH` | `integration_branch` | `/merge` target branch |

Precedence: CLI flag > env var > `.claude/uberdev.local.md` > default. Missing file → defaults apply silently.

---

## Short-form aliases

Plugin commands are addressed as `/uberdev:<command>` by default — the `uberdev:` prefix is required by Claude Code's plugin manifest. Auto-install drops six forwarders into `~/.claude/commands/`:

| Short form | Canonical |
|---|---|
| `/issue` | `/uberdev:issue` |
| `/solve` | `/uberdev:solve` |
| `/turbo` | `/uberdev:turbo` |
| `/simplify` | `/uberdev:simplify` |
| `/review-pr` | `/uberdev:review-pr` |
| `/merge` | `/uberdev:merge` |

```bash
/uberdev:install-aliases             # install (skip-if-exists)
/uberdev:install-aliases --dry-run   # preview without writing
/uberdev:install-aliases --force     # refresh existing managed forwarders
/uberdev:uninstall-aliases           # remove (only marker-tagged files)
```

Forwarders carry `<!-- managed-by: uberdev-aliases -->` so uninstall is scoped to files we own. Hand-authored `~/.claude/commands/<name>.md` files are never overwritten — collisions skip with a warning. If you reinstall the plugin to a different location, `--force` refreshes the captured paths.

---

## Bundled (since v0.2.0)

UberDev ships these so all commands work standalone — **no `superpowers`, `pr-review-toolkit`, or `code-simplifier` plugin install required**.

| Type | Slugs | Source |
|---|---|---|
| Skills | `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch`, `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills` | adapted from [`superpowers`](https://github.com/obra/superpowers) (MIT, Jesse Vincent) |
| Skills | `orchestrator`, `merge`, `solve-pipeline`, `post-impl-review`, `using-uberdev` | UberDev original |
| Agents | `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer` | from [`pr-review-toolkit`](https://github.com/anthropics/claude-code) (Apache 2.0) |
| Agents | `code-simplifier` | from [`code-simplifier`](https://github.com/anthropics/claude-code) (Apache 2.0) |
| Agents | `plan-reviewer`, `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer`, `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints`, `research-security`, `research-test-coverage`, `codebase-scout`, `triage-scout`, `conflict-resolver` | UberDev original |
| Commands | `/uberdev:review-pr`, `/uberdev:simplify` | adapted; `review-pr` defaults to **parallel** fanout (divergence from upstream) |

Bundled upstream license texts in `plugins/uberdev/licenses/`.

---

## Design decisions worth knowing

| Decision | Rationale |
|---|---|
| **Repo-agnostic by default** | Commands derive `$REPO` from `gh repo view` at runtime. No hardcoded org/project IDs. |
| **No GitHub Project board auto-add** | Portability over board affordance. May return via opt-in `.claude/board.json`. |
| **Model pin baked in** *(in `solve.md`)* | Spawned agents run on `claude-opus-4-7[1m]` for reproducibility. Forks should adjust. |
| **macOS-first terminal dispatch** | `osascript` for iTerm/Terminal.app; native CLI for cmux/Ghostty; `nohup` fallback elsewhere. |
| **Triage hint in every issue body** | `/solve` skips re-classification and picks the right workflow without re-reading the body. |
| **Conventional commits enforced** | `feat(scope):` / `fix(scope):` / `chore(scope):` / `refactor(scope):`. `enhancement` is a label, never a type. |
| **`/merge` autopilot has no author gate** | Trust anchor is `reviewDecision == "APPROVED"` + GitHub branch protections. Bot vs. human vs. external contributor — same eligibility. |
| **No `Co-Authored-By: Claude` trailer** | Commits and PR bodies use the user's authorship only. |
| **Wave-based parallel execution** | Plans declare task dependencies + file ownership; `subagent-driven-dev` fires every wave's tasks concurrently in one shared worktree. Controller-only git eliminates index races without per-task worktree ceremony. |

---

## Changelog

Release notes live in [`CHANGELOG.md`](./CHANGELOG.md) (Keep-a-Changelog 1.1.0 / SemVer). The GitHub releases tab is intentionally kept lean — `CHANGELOG.md` is authoritative.

---

## FAQ

<details>
<summary><strong>Why "UberDev"?</strong></summary>

Personal brand. Marketplace and repo are `UberDev`; the plugin inside is `uberdev` (lowercase to match Claude Code naming conventions).

</details>

<details>
<summary><strong>Will <code>/solve</code> work outside macOS?</strong></summary>

Partially. The terminal-dispatch chain falls through to `nohup` (detached background process with logs in `/tmp/solve-N.log`) on any platform without a recognized terminal app. You lose the per-issue tab and notifications, but the agent still runs.

</details>

<details>
<summary><strong>How do I disable the plugin without uninstalling?</strong></summary>

```
/plugin disable uberdev@uberdev
```

Or edit `~/.claude/settings.json`:

```json
"enabledPlugins": {
  "uberdev@uberdev": false
}
```

</details>

<details>
<summary><strong>I'm hitting Claude usage limits constantly. What do I do?</strong></summary>

Either upgrade — the headline warning recommends 2× Claude Max ×20 for sustained daily use — or scale down: prefer `/solve --trivial` / `--small`, skip `/turbo`, skip `/uberdev:review-pr`, or use a less aggressive plugin. UberDev's defaults are tuned for "ship faster, pay for it" — that's a deliberate choice.

</details>

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## License

MIT. See [`LICENSE`](./LICENSE).

---

<div align="center">

**Built by [@TheFJK](https://github.com/TheFJK) for shipping fast on solo and small-team GitHub projects.**

*If you fork this, [open an issue](https://github.com/TheFJK/UberDev/issues) — I'd love to see what you build on top.*

</div>
