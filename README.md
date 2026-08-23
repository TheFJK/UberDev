<div align="center">

# UberDev

**Personal Claude Code marketplace — opinionated GitHub-workflow slash commands.**

[![Version](https://img.shields.io/badge/version-0.54.0-blue)](./CHANGELOG.md)
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

UberDev's whole personality is **parallel agent fanout**: `/issue` runs a 2-scout fanout, `/uberdev:review-pr` runs seven reviewers in one or more cap-controlled waves with every child in each wave dispatched before its first wait, `/uberdev:simplify` runs three simplification lenses concurrently, `/solve` waves dispatch every task in parallel, and `/merge` spawns one conflict-resolver per conflicted file. That's where the speed and quality come from — and that's where the cost comes from.

**Recommended setup: 2× Claude Max ×20 subscriptions.** A single Pro or single Max usage window genuinely is not enough headroom for a normal day of `/turbo` + `/review-pr` + `/merge` cycles. Expect to hit the limit mid-task on a single seat.

**If that's too much, scale down:** prefer `/solve --trivial` / `--small` (skips the orchestrator), skip `/turbo` (interactive `/solve` runs fewer agents), or use a less aggressive plugin. The defaults are tuned for *"ship faster, pay for it"* — a deliberate choice, not a bug.

---

## TL;DR

| Command | What it does |
|---|---|
| **`/solve <issue#>`** | Runs an autonomous solver per issue as a worktree-isolated agent in the session's Workflow runtime (watch with `/workflows`). Tier-aware: trivial issues skip design; medium gets a parallel research fan-out → spec → plan → implement chain. Detached transports remain available via `--backend=`. |
| **`/turbo <issue#>`** | Unattended `/solve`. Same pipeline, but the brainstorm phase auto-accepts the lead agent's recommendation and Q&A is resolved against the research bundle. Use when you trust the recommendation and want issue → PR with no babysitting. |
| **`/turbox <issue#>`** | Unattended `/turbo` in **standard mode**: this session orchestrates the fleet through the `Task` tool instead of the Workflow runtime, so the implementation phase runs **waves of parallel implementers over disjoint file sets** — which the Workflow lane's leaf agents structurally cannot do. Design and delivery fan out across issues too. Parallel-issue cap **3**. Costs session context; buys wall-clock. (RFC 0020) |
| **`/issue <description>`** | Creates a well-investigated, deduped, label-validated GitHub issue from a one-line ask. 2-scout fanout (codebase + triage) runs in <30 s, with conventional-commit titling and template-by-type. |
| **`/review-pr [<PR#>]`** | Comprehensive PR review using specialized agents in cap-controlled dispatch-before-wait waves — code review, simplifier, silent-failure hunter, type-design analyzer, comment analyzer, test analyzer. With more than one PR open it first offers (interactively, once) to combine them all onto a single review branch and run the pipeline once over the combined result — cheaper by a factor of N, at the cost of per-PR revert granularity and per-PR finding attribution. `--consolidate` accepts without asking; `--no-consolidate` declines permanently and wins over `--consolidate`. Never offered under `--turbo`, without a TTY, or on a chained `finish-branch` run. |
| **`/merge [<PR#> \| --all]`** | Lands an approved PR into the integration branch — autopilot. Bare invocation auto-discovers scope: single PR for the current branch, or all eligible open PRs against `integration_branch`. Ordering, per-PR strategy, conflict resolution (one parallel agent per conflicted file), and local sync, all unattended. |
| **`/premerge [<level>]`** | Pre-merge stack gate. Packs **every** open non-draft PR onto one integration branch and opens ONE `chore(stack): land #A #B` PR, then reviews the *combination* with the built-in `/code-review` (default `xhigh`) — which is the only place the cross-PR defect classes are visible at all: two PRs resolving the same next version, two PRs adding the same helper, one PR's rename defeating another's guard. Review → fix → re-review is a **bounded convergence loop**: fixer waves at the correctness blockers, `ci-failure-classifier` → `ci-code-fixer` at a red build, a base merge at a conflict, until the stack is green or the evidence says repairing has stopped working. That loop is what makes the three simplify lenses reachable at all — they run **last and only on a green stack**, and before the loop existed a single-shot gate left them silently unreached on any stack that needed fixing. Everything the run could not fix, **surviving blockers included**, is filed as a `premerge-finding` issue. Bumps the version once for the whole stack. **Always parks the PR — never merges.** (RFC 0021) |
| **`/dev <idea>`** | Prototype fast lane. Decomposes a free-text idea, builds it via parallel `Task()` subagents in-session, runs one light review, opens a PR labelled `prototype`, and auto-files a harden issue. Deliberately skips spec/plan and full `/review-pr`. Honors `--no-pr` / `--no-issue`. |
| **`/testers`** | Read-only adversarial QA audit squad — 6 personas + 2 monitors over 3 waves; auto-detects web/api/native target; files verified findings as GitHub issues. |
| **`/uberdev:cluster`** | Repo-wide issue similarity analyzer + fold-into-lead consolidator (RFC 0010). |
| **`/uberdev:goal <issue#>`** | Autonomous loop that chains `/turbo` → `/review-pr` (auto) → `/merge` if GREEN, recursing on BLOCKER/CRITICAL `review-pr-finding` issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from `/solve` and `/turbo`. |
| **`/uberthink <goal>`** | Read-only cross-domain ideation engine. Fleet fanout across N evolutionary "islands" (frame → diverge → gap-gate → combine → converge → falsify → genetic loop-back → cross-pollinate → rank) producing a ranked dossier with a 🌙 moonshot lane. Top idea(s) filed as GitHub issues; `--handoff` chains the winner into `/brainstorm`. Always-deep × `--islands K` ≈ K×15× a normal chat. |

Every command is **repo-agnostic** — they auto-detect via `gh repo view`. No per-repo config required.

- **Findings-to-Issues sub-phase (`/uberdev:review-pr` Phase 2.5, `/uberdev:simplify` Phase 3.5):** persists deferred-critical findings as durable GitHub issues with HTML-comment fingerprint dedupe. Opt out via `--no-defer-issues` flag or `defer_issues_enabled: false` in `.claude/uberdev.local.md`.

---

## Install

Two doors. The one-liner is the convenient one; the manual flow below is the one you can read before you run it. They do the same thing.

### One-liner (`curl | bash`)

```bash
# Installs the plugin and patches the missing enabledPlugins entry.
curl -fsSL https://raw.githubusercontent.com/TheFJK/UberDev/main/install.sh | bash
```

Then in Claude Code:

```bash
/uberdev:issue trivial typo in README install step   # smoke-test
```

The fifteen short-form aliases (`/issue`, `/solve`, `/turbo`, `/turbox`, `/simplify`, `/review-pr`, `/merge`, `/premerge`, `/dev`, `/testers`, `/ubergoal`, `/uberscan`, `/ubersimplify`, `/uberthink`, `/ubercluster`) are auto-installed on first session and refreshed on plugin upgrade — `jq` is not required, and if a short name collides with an existing file the session context reports which alias was skipped. The first-run notice confirms "installs 15 aliases". Opt out with `auto_install_aliases: false` in `.claude/uberdev.local.md` or `UBERDEV_NO_AUTO_ALIAS=1`.

> **Why a bootstrap script?** Upstream Claude Code has a bug where `/plugin install` populates the cache but does not write `enabledPlugins` in `~/.claude/settings.json` — so `/uberdev:*` commands silently 404. `install.sh` does the install **and** jq-patches `enabledPlugins`. Idempotent. Requires `jq`.
>
> **Upstream state — re-checked 2026-08-10.** The tracking issue this README used to cite is closed, but the bug is not fixed:
>
> - **Live:** [anthropics/claude-code#14815](https://github.com/anthropics/claude-code/issues/14815) — open. Unfixed, so the patch is still load-bearing.
> - [#20661](https://github.com/anthropics/claude-code/issues/20661) — **closed** 2026-01-29 as a **duplicate**, by a bot; this is the reference this README used to cite.
> - [#17832](https://github.com/anthropics/claude-code/issues/17832) — **closed** 2026-03-30, **not_planned**; the canonical issue #20661 was folded into, declined upstream.
> - [#15524](https://github.com/anthropics/claude-code/issues/15524) — **closed** 2025-12-31 as a **duplicate**.

### Manual install (no `curl | bash`)

Piping a remote script into your shell is a hard sell. You do not have to: `install.sh` is a convenience, and these are the exact steps it performs — it performs nothing else.

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

**If you skip step 2, nothing fails loudly.** The plugin lands in the cache and the marketplace lists it as installed — but the loader reads `enabledPlugins`, so every `/uberdev:*` command 404s with no error message. The commands simply do not load, and there is nothing in the UI to tell you why. That silent failure is the entire reason step 2 exists (and the entire reason `install.sh` exists).

### What the script does to `~/.claude/settings.json`

Audit only the part that touches your settings — everything else in the file is preflight, best-effort slash commands and error output:

```bash
sed -n '/# BEGIN settings-mutation/,/# END settings-mutation/p' install.sh
```

That fenced region, and nothing else in the script, writes your settings file. Inside it:

- It sets `enabledPlugins["uberdev@uberdev"] = true`. That is the whole mutation.
- It is **idempotent** — a re-run against already-enabled state is a byte-identical no-op.
- It **preserves** unrelated keys (`theme`, `model`, `permissions`, …); sibling `enabledPlugins` entries for other plugins are preserved verbatim, because it mutates one key rather than replacing the object.
- It refuses to patch a **malformed** settings file: on invalid JSON it prints jq's parse error, exits non-zero, and leaves your file byte-for-byte untouched instead of rewriting it.
- It writes atomically — jq's output goes to a temp file in the same directory, then one `mv` renames it into place, so an interrupted run cannot leave a half-written settings file behind.
- A manually-disabled entry (`"uberdev@uberdev": false`) is **flipped back** to `true`. So the *How do I disable the plugin without uninstalling?* route in the FAQ does not survive a re-run of `install.sh` — re-disable after updating.

Every one of those claims is pinned by `tests/install.test.sh` (I2–I6, I9, I12) against a sandboxed `$HOME`.

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
| **Claude Code >= 2.1.139** with plugin support | Required for `/plugin marketplace add`. `/solve` and `/turbo` hard-fail on older versions with an actionable `npm i -g @anthropic-ai/claude-code@latest` pointer. |
| **`bash` >= 4 — `/ubergoal` (`/uberdev:goal`) only** | The `/goal` watch loop's verdict locator relies on bash's unmatched-glob semantics (zsh fatals with `no matches found`; stock macOS `/bin/bash` is 3.2). On macOS run `brew install bash` once (→ `/opt/homebrew/bin/bash` 5.x); `/goal` auto-discovers it (Phase 0 publishes `UBERDEV_GOAL_BASH` and runs the fences under it — see `commands/goal.md` "Execution contract"). Other commands run fine under the default zsh. |

---

## `/solve` — autonomous issue resolution

Auto-classifies a GitHub issue into a tier, then spawns an agent with a tier-appropriate workflow.

| Tier | Auto-detected from… | Spawned workflow |
|---|---|---|
| **trivial** | Labels `typo`/`docs`/`chore`/`good-first-issue`. Body <300 chars. Single file named. | Direct edit → test if touched code is tested → `/uberdev:simplify` → PR |
| **small** | Clear repro + error. Localized to one module. ≤50 LOC. | Lightweight TodoWrite plan (3–6 tasks) → TDD → `/uberdev:simplify` → PR |
| **medium** *(default, and the ceiling)* | The fallback rung — anything the two rows above do not claim. In practice: a risk signal, a stack trace, ≥3 files in the issue's **declared or change-marked scope** (a `path:line` citation is evidence, not scope), a design label (`epic`/`needs-discussion`/`architectural`/`architecture`/`infrastructure`), or `refactor` plus cross-cutting breadth. | `/uberdev:orchestrator` (research fanout → optional Q&A → spec-writer → spec-reviewer (always-on at this rung) → plan-writer → plan-reviewer) → `/uberdev:subagent-driven-dev` wave dispatch → `/uberdev:review-pr` |

> **Misclassification is recoverable** — the spawned agent can escalate to `/uberdev:orchestrator` mid-flight if the scope proves larger than triaged. When in doubt, defaults to medium.

**Manual overrides:**

```bash
/solve 123 --trivial                  # force trivial tier
/solve 123 --small                    # force small tier
/solve 123 --full                     # force medium (the top rung)
/solve 123 --auto                     # permission BYPASS pair: --dangerously-skip-permissions --permission-mode bypassPermissions (no tool prompts)
/workflows                             # monitor active /solve and /turbo solver fleets
```

**What actually runs** (RFC 0015) — the launcher validates, triages and claims every issue, then hands the batch to `skills/solve-fleet/workflow.js`. That script runs **one solver agent per issue in its own git worktree**, in `parallel()` waves of `fanout_concurrency.solve_bg` (default 6):

```
/solve 5 6 7
  └── lib/solve-launcher.sh   validate -> triage -> claim -> emit args   (one Bash call, seconds)
  └── Workflow(skills/solve-fleet/workflow.js)
        ├── #5  medium  research x3 -> spec -> review -> plan
        │               -> [impl -> review -> fix* ]xT -> deliver -> PR   (one shared worktree)
        ├── #6  trivial                                    solve (worktree) -> PR
        └── #7  small                                      solve (worktree) -> PR
```

For a medium-tier issue the plan is written as numbered tasks (`## Task <n>:`),
and the implement phase walks them **one at a time** in a single shared
worktree: an implementer commits the task, a reviewer reads `git show HEAD`
against that task, and up to three fix rounds amend the same commit. Only when
every task has settled does one delivery agent run the suite, push and open the
PR. Trivial/small issues, and any issue whose design phase produced no usable
plan, keep the single-solver path — no plan means no tasks, so there is no
boundary a review gate could sit on.

Monitor with **`/workflows`** — the progress tree lives in the session you started, and the run returns a structured per-issue result (`status`, `branch`, `prNumber`, `blocker`). There is no separate agent surface to poll.

**Detached transports** are still available for fire-and-forget runs: `--backend=wezterm`, `--backend=background`. Those spawn a real session per issue:

```bash
git worktree add .claude/worktrees/solve-issue-123 -b worktree-solve-issue-123
claude -p "<prompt>" --model 'claude-opus-4-8[1m]'   # detached, PID-tracked
```

and are monitored through visible WezTerm panes or the printed PID / log / result files. `auto` never selects them. The `claude --bg` transport that used to head this list was removed in RFC 0015 §7 as amended, and `--backend=codex` was deleted the same way in #381 — both are now enum errors, not deprecations.

**Sequential per-task execution with a gate on every task** — this is what `/solve` and `/turbo` actually run. Tasks are walked in plan order, never in parallel: two implementation agents in one checkout collide, and the payoff being chased (fresh context per task, a review before the next task starts) needs no parallelism. There is no `Owns:` allowlist to validate, no git mutex and no controller serializing commits — each task agent commits its own single commit in the shared worktree, and each fix round amends it, so the history is one clean commit per task and nothing is pushed until delivery.

> The wave-parallel shape (`Depends on:` / `Wave:` / `Owns:` per task, pairwise-disjoint allowlists, a controller that owns git) belongs to the directive `subagent-driven-dev` skill, which `/uberdev:orchestrator` still drives in a normal session. The Workflow-native fleet does not implement it.

---

## `/turbo` — unattended issue resolution

Identical to `/solve` for trivial / small. For medium, the brainstorm phase **auto-accepts the lead agent's recommendation** instead of asking clarifying questions, and Phase 2 Q&A becomes non-blocking — clarifying answers are auto-picked from the research-bundle synthesis and written to `questions.md` for audit.

| Combo | Brainstorm Q&A | Tool gating |
|---|---|---|
| `/solve 42` | interactive | manual per-tool |
| `/solve 42 --auto` | interactive | skip-permissions bypass |
| `/turbo 42` | auto-accept | manual per-tool |
| `/turbo 42 --auto` | auto-accept | skip-permissions bypass |

⚠️ **`--auto` is a permission bypass, not a convenience flag.** It resolves to the flag **pair** `--dangerously-skip-permissions --permission-mode bypassPermissions` (both are needed — they target different mechanisms, #246). Wherever that pair lands, **no tool prompts** — including destructive ones. Post-#241 the middle `--permission-mode auto` tier was removed rather than kept, because it silently refused some agent tools (notably Search); `--auto` is now the same strict bypass as `SKIP_PERMISSIONS=1`, with no gentler option in between. `/turbo` and `--auto` remain orthogonal: `/turbo` governs brainstorm interactivity, `--auto` governs permissions.

**Where the bypass actually applies.** On the default `workflow` backend it does **not** reach the per-issue solvers: they run as agents inside your session and inherit **its** permission tier, because the Workflow API exposes no per-agent permission option (RFC 0015 §6 R-1b). The pair is passed to a child's argv only on `--backend=wezterm|background` and on the `/merge` + `/review-pr` dispatches. So on the default path `--auto` raises nothing per child — and if your session is already running bypassed, dropping `--auto` lowers nothing either.

**Multi-issue dispatch.** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and runs three independent solvers — each in its own `.claude/worktrees/solve-issue-N/` worktree, all running in parallel. Override flags (`--trivial|--small|--full`, and `--auto` — the permission **bypass**) apply batch-wide. Larger queues split into `ceil(N / cap)` sequential single-message waves (default cap 6 via `fanout_concurrency.solve_bg`). If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). `/solve` accepts the same syntax.

Spec & plan are still written to disk before implementation — audit them mid-flight to course-correct.

---

## `/turbox` — unattended issue resolution, standard mode

Same fleet, same launcher, same claims — a different **orchestrator**.

`/turbo` runs its fleet inside the Workflow runtime, and **a Workflow agent has
no `Task` tool**: it cannot fan out. That is why `skills/solve-fleet/workflow.js`
walks the implementation phase one task at a time, each in its own agent, gated
by a reviewer. Correct, but serial.

`/turbox` makes the orchestrator a *session* instead of a leaf. The plan-writer
has always emitted `## Execution Waves` and per-task `Owns (file allowlist)`
fields; only a fan-out-capable orchestrator can honour them.

```
/turbox 355 356 357
  └── lib/solve-launcher.sh --standard   validate -> triage -> claim -> emit plan   (one Bash call)
  └── this session, following skills/turbox-fleet/SKILL.md
        Phase 2  research    [355 security]   ← risk-gated; 356 and 357 skip Phase 2
        Phase 3  design      design-planner ×3 → plan-review ×3
        Phase 4  wave 1      [355.t1 355.t2 355.t3 │ 356.t1 356.t2 │ 357.t1]  ← ONE message
                             controller stages + commits per task; implementers never run git
        Phase 5  gate        per-task reviewers in parallel, bounded fix ladder
        Phase 6  deliver     suite → push → PR, per issue in parallel
```

| | `/turbo` | `/turbox` |
|---|---|---|
| Orchestrator | `solve-fleet/workflow.js` (a leaf) | **your session** |
| Implementation | sequential per task | **wave-parallel over disjoint `Owns` sets** |
| Progress | `/workflows` tree | the transcript + the run directory |
| Return | one structured JSON object | the controller's report + an audit log |
| Context cost | near zero | **real** — the controller holds per-task state |
| Parallel issues | 6 | **3** |

**Disjointness is refused, not reviewed.** `plan-reviewer` Check 2 already
reviews same-wave `Owns` lists. A review is advice; `turbox-fleet.sh
wave-disjoint` is the refusal. Before any implementer in a wave is dispatched,
every pair of tasks is compared for equality **or directory containment** — one
task owning `lib/` and a sibling owning `lib/x.sh` race exactly as if they
shared a path, and a plain set intersection calls them disjoint. On overlap it
dispatches **nothing**: an overlap is a plan defect, not a scheduling problem.

**Who may run git** is a property of the checkout, not the agent: a worktree
with two or more concurrent writers has exactly one git operator (the
controller); a worktree with a single writer runs its own git. So wave
implementers report paths and the controller commits them — through a helper
that refuses `git add -A`, `--all`, a bare `.`, absolute paths and `../`
escapes.

`--backend=` is **refused** on this lane and the launcher says so before writing
a claim: standard mode launches no per-issue solver child, so there is no
backend to select. Use `/turbo --backend=…` for the detached transports.

Pick `/turbo` for batch throughput and context economy. Pick `/turbox` when the
issues are few, hand-picked, and decompose into genuinely independent tasks.

---

## `/merge` — post-review PR landing (autopilot)

Lands approved PRs into the integration branch — fully unattended. No prompts, no halts. Per-PR failures park; the queue continues.

**Invocation modes:**
- `/merge <PR#>` — land a specific PR.
- `/merge --all` — land every eligible open PR (APPROVED + CI-green) against `integration_branch`.
- `/merge` (no args) — context-aware. On a PR feature branch: single-PR fast path. Otherwise: auto-discover and land every eligible open PR against `integration_branch` (same path as `--all`, with a pre-flight stderr summary listing the discovered set).

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

## `/premerge` — the pre-merge stack gate

`/premerge` packs **every** open non-draft PR onto one integration branch, opens a
single `chore(stack): land #A #B …` PR, and reviews *that* — because the defects
that actually bite at landing time are cross-PR by construction and structurally
invisible to any per-PR review:

- two PRs cut from one base both bump to the **same** next version; git
  auto-merges the identical edit and one intended release disappears silently;
- two PRs add the same helper under different names, and each review sees a
  reasonable new helper;
- one PR's rename defeats a guard another PR just added, because
  `git diff --name-only` collapses renames.

```
/premerge                 # every open non-draft PR, reviewed at xhigh
/premerge max             # same, with the reviewer's agent fan-out + verify votes
/premerge --converge=5    # up to five repair rounds instead of three (ceiling 6)
/premerge --no-converge   # one fix pass, one re-review, then gate once — the pre-loop behaviour
/premerge --dry-run       # print the pack plan and stop
```

**Six phases.**

| Phase | What |
|---|---|
| 0 PACK | `lib/review-consolidate.sh` — dependency-ordered sequential merge, conflict handback, ancestry gate, typed exclusions, one supersession comment per original, `Closes #N` carried onto the stack PR |
| 1 REVIEW | the **built-in** `code-review` skill against the stack PR — not uberdev's seven-agent fanout |
| 2 TRIAGE | classify the review's findings and plan the fixer waves (one agent per file, disjoint files per wave, agents never touch git). Stamps the reviewed SHA into the evidence. Runs once per attempt; the cleanup findings accumulate as a union deduped by fingerprint across attempts, because a suggestion the reviewer stops repeating is unmentioned, not resolved |
| 3 CLEAN GATE + CONVERGE | blockers cleared **and** CI green **and** not conflicting; fails closed on unreadable evidence. Not green routes each failing term at something that can repair it — fixer waves at a blocker, `ci-failure-classifier` → `ci-code-fixer` / `ci-rebase-handler` at a red build, a controller-owned base merge at `CONFLICTING` — and re-enters Phase 1. A build that has not answered yet is re-probed without spending an attempt |
| 4 SIMPLIFY + VERIFY | the three lenses — **last, and only on a green stack**. Applies only behaviour-preserving findings, then re-probes CI and re-gates the polish commit on its own SHA — because Phase 4 is the last thing to touch the branch and every earlier gate was computed before it. A refactor that broke a stack which was green is `git revert`ed, not handed to a human at 3am |
| 5 BUMP + PARK | everything the run could not fix becomes an issue — surviving blockers at `BLOCKER` tier with a `Blocks: #<stack-pr>` backref, suggestions and un-applied lens findings at `SUGGESTION` — then one `bump-version.sh` for the whole stack, push, stop |

**The counter is a backstop, not the stop condition.** `--converge=<n>` **repair rounds** (default 3,
ceiling 6, refused rather than clamped outside that range) only bounds a runaway.
What actually ends the loop is evidence: `STOP_NO_PROGRESS` the moment an attempt
changes neither the blocker fingerprints nor the CI reason, `STOP_REGRESSED` the
moment our own fixes grow the blocker set. Those two are the real guard against
the hazard RFC 0021 originally refused a loop over — the third attempt that quietly
edits the test instead of the code — because they notice the attempt that achieved
nothing rather than assuming attempt three will be the bad one. Blocker identity is
a fingerprint over path plus a normalised summary and deliberately **not**
`file:line`: every fix moves lines, so a line-keyed identity would report each
survivor as brand new, see infinite progress and never stop. A blocker that
survives the loop is filed as a GitHub issue with a `Blocks: #<stack-pr>` backref
rather than printed into a summary that scrolls away — the one finding the machine
could not handle is the one that most needs to outlive the run.

**Effort levels are not a ladder.** The built-in reviewer resolves *model × level*
to a cell, and the cells differ in kind. On Opus-family models `xhigh` runs its
ten angles **inline, with no subagents and no verify pass**, so findings carry no
`verdict`; `max` is the cell that fans out to agents *and* votes. `/premerge`
works under both and reports `CATEGORY_BACKED` — how many severities were
machine-checked rather than judged — so you can see which regime a run was in.

**It never merges.** Not on green CI, not on an approving review, not under any
flag. It ends at a pushed, open, bumped, parked PR. Landing is `/merge`.

**It emits no trust trail**, so `/merge`'s PATH_2 will not accept a `/premerge`
run as review evidence — that trail claims the seven-lens fanout, the
finding-verification gate and the CI-health phase all ran, and here none did. Run
`/review-pr <stack-pr>` on the parked PR when you want one; the two compose in
that order.

Design rationale and full topology in [`docs/rfc/0021-premerge-stack-integration.md`](./docs/rfc/0021-premerge-stack-integration.md).

---

## `/issue` — investigation-first issue creation

Pipeline: classify → 2-scout fanout (`codebase-scout` + `triage-scout`, parallel in one turn — dedup against open and closed issues, label/scope validation against `gh label list` and commitlint) → draft → **create** → print `Next step: /solve N`. Median wall-clock under 30 seconds — one turn, no approval prompt.

**Autopilot.** `/issue` files the issue without stopping to ask — the same call `/merge` made when `auto_confirm` became a documented no-op. The draft is the issue body, not a question: on the normal path it never reaches your terminal — what prints is the result block with the issue URL. Exactly one halt survives: an **open** duplicate found by `triage-scout` stops before `gh issue create` and shows you both the match and the draft, because a second copy of a live issue is the one outcome that closing it does not cleanly undo. Closed duplicates never halt — they are regression evidence and render as `## Possible duplicates`. Scout degradations (a `BLOCKED` codebase scout, a `gh label list` that failed) are reported in the result block, never promoted to gates. There is no opt-out key and no `--confirm` flag. `/solve` is still never auto-run.

Templates by type — bug (`fix`), feature (`feat`), or chore/refactor — each producing conventional-commit-style titles and a body footed with `**Triage hint:** <trivial|small|medium>` that `/solve` reads later to pick the workflow without reclassifying.

After the spawned agent's PR is approved (and you've run `/uberdev:review-pr`), run `/merge <PR#>` to land it.

**Skip the codebase investigation** for docs/typo issues unrelated to code logic:

```bash
/issue Fix the install step in the README — wrong command --no-explore
```

---

## `/uberthink` — cross-domain ideation engine

Read-only, **always-deep**, whole-fleet ideation engine. Takes a hard technical goal in free text and produces a **ranked dossier of novel approaches** — generated by importing the best mechanisms from a large catalog of donor domains (centered on software engineering, game dev, IT/systems, and mathematics; far-field wildcards for forced distance), fusing them via genetic-algorithm-style crossover across parallel "islands," and stress-testing them through a falsification fleet so crackpot ideas die before they reach you. It is to *ideas* what `/uberscan` is to *audit* — **never writes application code**.

**Topology (one wave per arrow):** frame → diverge → gap-gate → combine → converge → falsify → genetic loop-back (≤ 3) → cross-pollinate → rank & deliver. Designs killed on a *fixable* flaw re-enter the combine wave for crossover-repair; designs killed on a *fatal* flaw (physics, trivial counterexample) are cut permanently. This is what converges ambitious ideas toward feasible ones instead of discarding them.

**Output dossier (`report.md`):** `🌙 Moonshot lane` (Novelty × Impact Pareto, surfaced *first* so wild ideas lead) → `Ranked approaches` (by AmbitionScore — a 4-term product over Novelty / Feasibility / Combination / Impact, which tanks the whole score on a near-zero axis) → `Culled ideas` appendix → `Run metadata`. Top candidate(s) (`--max-new`, default 3) are filed as `uberthink-idea`-labelled GitHub issues via `findings-to-issues`.

```bash
/uberthink "design a hard-to-fingerprint anti-censorship transport"
/uberthink "<goal>" --islands 3 --max-new 5         # 3 evolutionary islands, file top 5
/uberthink "<goal>" --no-issues                     # dossier only; no GitHub issues
/uberthink "<goal>" --handoff                       # after filing, hand #1 to /brainstorm
```

> **Cost note:** `/uberthink` is **always-deep** (no tier knob) and runs the full fleet × `--islands K`. Expect roughly **K × 15× a normal chat** in tokens — `CB-ISLAND` and `CB-CLOCK` circuit breakers are the ceilings. Budget accordingly; this is the most expensive command in UberDev by design.

**Composes with `/brainstorm`:** `/uberthink` invents the approach (ranked dossier); `/brainstorm` designs the implementation. `--handoff` auto-chains the #1 design into `/uberdev:brainstorm` seeded with its dossier section — moonshot → real design in one shot.

Design rationale and full topology in [`docs/rfc/0009-uberthink-ideation-engine.md`](./docs/rfc/0009-uberthink-ideation-engine.md).

---

## Configuration

Per-repo settings live in `.claude/uberdev.local.md` (YAML frontmatter; ignored by git). Env vars override file values.

```yaml
---
solve_auto: false             # permission bypass: resolves to --dangerously-skip-permissions --permission-mode bypassPermissions (/turbo governs Q&A, not this key)
fanout_concurrency:
  solve_bg: 6                 # /turbo parallel solver fanout cap (default 6, range [1, 50])
auto_install_aliases: true    # install short-form forwarders at SessionStart
integration_branch: main      # /merge target branch (overrides gh repo view default)
goal:
  max_cycles: 5               # /uberdev:goal hard cycle ceiling (default 5, range [1, 20])
---
```

| Env var | File key | Purpose |
|---|---|---|
| `UBERDEV_FANOUT_SOLVE_BG` | `fanout_concurrency.solve_bg` | Cap on parallel solvers dispatched by `/turbo`; int [1, 50], default 6 |
| `SOLVE_AUTO` | `solve_auto` | When `1`/`true`, resolves the permission bypass pair `--dangerously-skip-permissions --permission-mode bypassPermissions` (post-#241 the AUTO tier was collapsed into this bypass; on the default `workflow` backend the solvers inherit the session's permission tier instead — see above) |
| `UBERDEV_NO_AUTO_ALIAS` | `auto_install_aliases` | When `1`/`true` (env) or `false` (file), suppresses session-start auto-install of `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`, `/premerge`, `/dev`, `/testers`, `/ubergoal`, `/uberscan`, `/ubersimplify`, `/uberthink`, `/ubercluster` forwarders |
| `UBERDEV_INTEGRATION_BRANCH` | `integration_branch` | `/merge` target branch |
| `UBERDEV_PR_BASE_BRANCH` | `pr_base_branch` | Base branch new PRs target (`gh pr create --base`) and the pre-push secret-scan range base; default unset → the origin default branch. Set to a parent PR's branch to open a stacked PR |
| `UBERDEV_GOAL_MAX_CYCLES` | `goal.max_cycles` | `/uberdev:goal` hard cycle ceiling; int [1, 20], default 5 |

Precedence: CLI flag > env var > `.claude/uberdev.local.md` > default. Missing file → defaults apply silently.

---

## Short-form aliases

Plugin commands are addressed as `/uberdev:<command>` by default — the `uberdev:` prefix is required by Claude Code's plugin manifest. Auto-install drops fifteen forwarders into `~/.claude/commands/`:

| Short form | Canonical |
|---|---|
| `/issue` | `/uberdev:issue` |
| `/solve` | `/uberdev:solve` |
| `/turbo` | `/uberdev:turbo` |
| `/simplify` | `/uberdev:simplify` |
| `/review-pr` | `/uberdev:review-pr` |
| `/merge` | `/uberdev:merge` |
| `/premerge` | `/uberdev:premerge` |
| `/dev` | `/uberdev:dev` |
| `/testers` | `/uberdev:testers` |
| `/ubergoal` | `/uberdev:goal` |
| `/uberscan` | `/uberdev:uberscan` |
| `/ubersimplify` | `/uberdev:ubersimplify` |
| `/uberthink` | `/uberdev:uberthink` |
| `/ubercluster` | `/uberdev:cluster` |

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
| Skills | `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch`, `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev` | adapted from [`superpowers`](https://github.com/obra/superpowers) (MIT, Jesse Vincent) |
| Skills | `orchestrator`, `merge-pipeline`, `solve-pipeline`, `post-impl-review` | UberDev original |
| Agents | `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer` | from [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official) (Apache 2.0) |
| Agents | `code-simplifier` | from [`code-simplifier`](https://github.com/anthropics/claude-plugins-official) (Apache 2.0) — the same agent is also distributed inside `pr-review-toolkit`; our copy is byte-identical to the standalone `code-simplifier` plugin's blob at the commit `vendor.json` pins |
| Shared contracts | `finding-confidence-rubric-v1` (the 0–100 finding-confidence scale + false-positive catalogue) | adapted from [`code-review`](https://github.com/anthropics/claude-plugins-official) (Apache 2.0) |
| Agents | `plan-reviewer`, `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer`, `design-planner`, `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints`, `research-security`, `research-test-coverage`, `codebase-scout`, `triage-scout`, `conflict-resolver` | UberDev original |
| Commands | `/uberdev:review-pr`, `/uberdev:simplify` | adapted; `review-pr` defaults to **parallel** fanout (divergence from upstream) |

Bundled upstream license texts in `plugins/uberdev/licenses/`.

Machine-readable provenance — upstream repo, pinned commit, vendoring date, upstream directory name, and a written **track**-vs-**fork** decision per component — lives in `plugins/uberdev/vendor.json`, enforced offline by `tools/vendor/vendor-check.py` and diffed weekly by `tools/vendor/vendor-drift.py`. The policy behind it is [RFC 0019](docs/rfc/0019-vendored-upstream-policy.md).

---

## Design decisions worth knowing

| Decision | Rationale |
|---|---|
| **Repo-agnostic by default** | Commands derive `$REPO` from `gh repo view` at runtime. No hardcoded org/project IDs. |
| **No GitHub Project board auto-add** | Portability over board affordance. May return via opt-in `.claude/board.json`. |
| **Model pin baked in** *(in `lib/dispatch.sh`)* | Spawned agents run on `claude-opus-4-8[1m]` for reproducibility. Forks should adjust. |
| **Workflow-native solver fleets** | `/solve` and `/turbo` run one worktree-isolated agent per issue inside the calling session's Workflow runtime — watch them in `/workflows`, platform-agnostic. No terminal emulator required. |
| **Triage hint in every issue body** | `/solve` skips re-classification and picks the right workflow without re-reading the body. |
| **Conventional commits enforced** | `feat(scope):` / `fix(scope):` / `chore(scope):` / `refactor(scope):`. `enhancement` is a label, never a type. |
| **`/merge` autopilot has no author gate** | Trust anchor is `reviewDecision == "APPROVED"` + GitHub branch protections. Bot vs. human vs. external contributor — same eligibility. |
| **No `Co-Authored-By: Claude` trailer** | Commits and PR bodies use the user's authorship only. |
| **Wave-based parallel execution** | Plans declare task dependencies + file ownership; `subagent-driven-dev` fires every wave's tasks concurrently in one shared worktree. Controller-only git eliminates index races without per-task worktree ceremony. |
| **No HARD-GATE approval checkpoints** | Upstream's brainstorm pauses for user sign-off before implementation. UberDev replaces user gates with parallel research fanout and always-on agent reviewers (`spec-reviewer`, `plan-reviewer`, post-push `/review-pr` Phase 1 `post-impl-review`). Quality wins from review depth, not approval ceremony. |

<details>
<summary><strong>Why doesn't UberDev pause for me to approve the design?</strong></summary>

Upstream `obra/superpowers` gates implementation behind a user-approval HARD-GATE: brainstorm halts, asks "does this look right so far?", and waits for sign-off before any subagent runs. Per-section approval prompts and a 3-iteration review-loop cap follow the same pattern.

UberDev rejects all of those. User gates trade quality for ceremony — every pause shifts review burden onto a non-expert reader (you) and adds wall-clock cost. Quality wins from **parallel research fanout** (six research agents in one shot), **always-on reviewers** (`spec-reviewer` runs on medium tier per orchestrator Phase 3.5; `plan-reviewer` runs on every plan per Phase 4.5), and a **post-push `/review-pr` Phase 1 `post-impl-review` fanout** (seven advisory reviewers — correctness, silent-failure, type-design, comment/doc, PR-test, convention-compliance, and general quality lenses — run in one or more cap-controlled waves, with every child in each wave dispatched before its first wait; simplification is `/review-pr` Phase 2).

</details>

---

## Measured reviewer precision

A confidence threshold is a guess until somebody measures the precision behind it. `/review-pr` files every deferred finding as a fingerprinted GitHub issue, so the precision of each reviewer lens is measurable — per lens, not globally, because a single number would average the two `code-reviewer` dispatches into something meaningless.

| Lens | Measured precision |
|---|---|
| `review_pr.review.correctness` | insufficient-data (n=0) |
| `review_pr.review.silent_failures` | insufficient-data (n=0) |
| `review_pr.review.types` | insufficient-data (n=0) |
| `review_pr.review.comments` | insufficient-data (n=0) |
| `review_pr.review.tests` | insufficient-data (n=0) |
| `review_pr.review.general` | insufficient-data (n=0) |

**Every cell reads `insufficient-data` because instrumentation started with this release, and that is the correct output — not a placeholder.** Lens provenance is only now recorded machine-readably (a `uberdev-finding-meta` trailer written beside the fingerprint marker), and correctness ground truth only exists once a human applies `finding:true-positive` or `finding:false-positive` when closing a filed finding. The 38 historical findings have neither, so they are quarantined out of the table rather than mined for a flattering number: a closed issue means somebody closed it, which is issue hygiene, not reviewer quality.

Full report with raw counts, intervals and the pre-instrumentation quarantine: [`docs/eval/review-precision.md`](./docs/eval/review-precision.md). Design and the floors it enforces: [RFC 0018](./docs/rfc/0018-review-precision-eval.md).

```bash
python3 tools/eval/review-precision.py --refresh   # re-mine + re-render
python3 tools/eval/review-precision.py --check     # CI gate: freshness + ratchet + prompt digests
```

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

Yes — `/solve` and `/turbo` support Linux, macOS, and native Windows. On the default `workflow` backend there is no OS-specific supervision at all (the Workflow runtime owns every agent), which is why native Windows no longer requires WezTerm. Process-identity reconciliation is supported on Linux, macOS, and native Windows for the explicit detached backends; other kernels fail closed instead of using a degraded PID fingerprint. Requires Claude Code >= 2.1.139.

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
