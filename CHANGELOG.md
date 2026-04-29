# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-04-29

### Added
- **`/uberdev:issue` Phase 2-4 fanout grows from 4 → 8 Task agents** in a single assistant turn. Existing four (`research-codebase`, `research-patterns`, duplicate-search, label/scope-validation) plus `research-prior-art`, `research-constraints`, `research-security` (Semgrep MCP + awesome-secure-defaults), `research-test-coverage` (test-surface mapping). Issue templates gain `## Current ecosystem`, `## Constraints`, and conditional `## Security signals` sections. `NO_EXPLORE=1` narrows to the four in-repo agents only.
- **Always-on spec/plan/PR-test reviewers** (tier-independent quality bar). Orchestrator Phase 1 short-circuits per-topic against `.uberdev/research/issue-<N>/` (mirrors brainstorm). Spec-reviewer is always-on for medium AND large; `--paranoid` deprecated as a no-op. New Phase 4.5 dispatches `plan-reviewer` (1-retry, non-blocking). New Phase 5.5 runs `pr-test-analyzer` pre-merge for large tier.
- **`uberdev:post-impl-review` skill** — 5-agent advisory fanout (`code-reviewer`, `simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`) in a single message. Invoked by `/solve` trivial/small inline prompts AND by `subagent-driven-dev` after each wave.
- **Non-blocking `/turbo` Q&A.** Orchestrator Phase 2 under `--turbo` auto-picks each clarifying answer using research-bundle synthesis and writes `questions.md`. `finish-branch` Option 2 reads it and appends `## Open questions answered by /turbo` (Question | Choice | Confidence) plus `## Reviewer findings summary` to the PR body.
- New agent definitions: `agents/research-security.md`, `agents/research-test-coverage.md`.
- Tests: `tests/post-impl-review.test.sh` (10/10 — frontmatter, 5 reviewer agent names, single-message invariant, both call-site refs, anti-loop guard); `tests/issue-causal-fanout.test.sh` extended to 39/39 (8 new 8-agent assertions + 1 new `--no-explore` 4-agent assertion); `tests/turbo-flow.test.sh` extended to 19/19 (9 new always-on-reviewer assertions).

### Changed
- **`--paranoid` flag is now a no-op.** Spec-reviewer runs unconditionally for medium and large tiers. Old `tier == medium AND --paranoid` gate prose removed from orchestrator; deprecation prose retained for two flag mentions.
- `brainstorm` step 2 short-circuit pattern relaxed to match generic loop variable naming used by orchestrator artifact-reuse.

### Backwards compatibility
- `--paranoid` still parses without error (deprecated no-op) — pre-v0.9 invocations continue to run.
- Issues created before v0.9.0 retain a 4-agent fanout fallthrough when no `## Current ecosystem` / `## Constraints` sections are present in the body.

Closes #11.

## [0.8.0] - 2026-04-29

### Added
- **`/uberdev:issue` deep root-cause research fanout.** Phase 2 now dispatches a 2-agent parallel fanout (`research-codebase` + `research-patterns`) when `NO_EXPLORE=0`, in the same single message as the existing Phase 3 (Duplicate Search) and Phase 4 (Label/Scope Validation) Task() calls — four agents fan out together, Phase 4.5 aggregates all four returns. Research summaries write to `.uberdev/research/run-<RUN_ID>/` and rename to `.uberdev/research/issue-<ISSUE_NUM>/` after `gh issue create`.
- **Bug-template `## Likely root cause` is now a causal triple** — `**Symptom:**` (observable failure), `**Mechanism:**` (specific code/data path), `**Owning code:**` (path/symbol — the assumption to challenge). Optional 5 Whys nested chain for non-trivial bugs. Replaces the previous file-list placeholder.
- **`/uberdev:brainstorm` short-circuit on `.uberdev/research/issue-<N>/`.** When invoked downstream of `/issue` for the same issue number, brainstorm reads the persisted summaries instead of re-dispatching equivalent research agents. Per-topic skip (codebase + in-repo prior art only — external prior art still dispatches); mtime-based staleness fallback; clean fallthrough for issues created before this change.
- **Body authoring rules subsection in `issue.md`** — codifies the WHAT/HOW boundary ahead of the templates: issue body says what is broken or wanted, never how to fix it. Implementation strategy is `/uberdev:brainstorm`'s job.
- **`tests/issue-causal-fanout.test.sh`** — structural-assertion test (modelled on `tests/turbo-flow.test.sh`) locking the contract invariants: Phase 1.5 RUN_ID/SUMMARY_DIR, Phase 2 4-agent single-message fanout, `--no-explore` placeholder verbatim, causal triple labels, feat template rename invariant, Phase 7 artifact-binding rename, brainstorm short-circuit + per-topic skip + stale-check + backwards-compat fallthrough.
- **RFC:** `docs/rfc/2026-04-29-issue-deep-root-cause-research-fanout.md` records the why (2-agent rather than 4-agent fanout, stable artifact directory rather than return-value handoff, triple rather than freeform causal essay, field rename rather than rules-text reminder) and rejected alternatives.

### Changed
- **Feat-template field rename:** `## Proposed approach` → `## What changes`. Field-name pressure replaces rules-text pressure for keeping implementation strategy out of the issue body. Downstream parsers (`/solve`, `/turbo`, `/orchestrator`) read only `**Triage hint:**` from the body, so the rename is contract-preserving.
- **Phase 4.5 aggregate** in `issue.md` extended to reconcile two new research returns (`codebase.md` drives the bug-template triple and `## Likely area`; `patterns.md` drives the `## Related` prior-pattern bullets and informs the causal chain when prior bugs exist).
- **Rules subsection** in `issue.md` gains a WHAT/HOW boundary bullet: issue body never contains an implementation checklist or fix design.

### Backwards compatibility
- No breaking change to issue-body parsing. `**Triage hint:**`, severity checkboxes, label format, and conventional-commit titles all preserved verbatim.
- Issues created before v0.8.0 have no `.uberdev/research/issue-<N>/` directory; brainstorm's short-circuit `[ -d ... ]` check returns false and falls through cleanly to the existing parallel-dispatch path. No data migration.

Closes #9.

## [0.7.1] - 2026-04-29

### Fixed
- `/turbo` unattended chain now propagates `--turbo` end-to-end through every handoff (`brainstorm` → `write-plan` → `subagent-driven-dev` → `finish-branch`). PR #8 closed issue #5 architecturally by making `write-plan` non-interactive, but `finish-branch` was still prompting at the chain tail because none of the downstream skills forwarded `--turbo`. `finish-branch` now auto-selects "Push and Create PR" under `--turbo` and announces the auto-selection.
- `orchestrator` Phase 5 forwards `--turbo` to `subagent-driven-dev` — closes the medium/large `/turbo` gap PR #8 introduced (`/turbo` for medium/large tier routes through `/uberdev:orchestrator --turbo`, but Phase 5 was invoking `subagent-driven-dev` without forwarding the flag, so the chain still stalled at `finish-branch`).
- `finish-branch` Step 5 cleanup behavior reconciled with the file's own Quick Reference table and Red Flags section: cleanup runs only for Options 1 (Merge locally) and 4 (Discard). Option 2 (Push and create PR) leaves the worktree alive for PR-feedback fixups; Option 3 (Keep as-is) is explicit. Pre-existing contradiction surfaced as a live runtime bug under `/turbo` — unattended runs auto-route to Option 2.

### Added
- `tests/turbo-flow.test.sh` — 9 contract assertions locking the `--turbo` propagation contract at every handoff (`brainstorm`, `write-plan`, `subagent-driven-dev`, `finish-branch`, plus `orchestrator` Phase 5 and the `/turbo` command entry point). Default-mode regression canaries also included so future edits can't silently break the non-`--turbo` paths.

## [0.7.0] - 2026-04-28

### Added
- `/uberdev:orchestrator` skill — writer-subagent pipeline used by `/solve` and `/turbo` for medium/large tier issues. Drives 5 phases: research fanout (parallel Sonnet subagents) → optional Q&A (skipped for `/turbo`) → spec-writer (Opus) → optional spec-reviewer (Opus, gated by `--paranoid` for medium tier; always for large tier) → plan-writer (Opus, with internal research fanout) → existing `subagent-driven-dev`. Each writer returns a structured YAML summary; orchestrator main holds pointers, not raw artifacts. Reclaims spawned-agent context for wave dispatch and error recovery.
- 8 new agent definitions: `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints` (Sonnet); `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer` (Opus). Each is invokable via Task() dispatch with a strict universal return contract.
- `--paranoid` flag on `/uberdev:orchestrator` enables spec-reviewer for medium tier issues.

### Changed
- `/solve` and `/turbo` medium/large tier prompts now invoke `/uberdev:orchestrator` instead of `/uberdev:brainstorm` directly. Trivial and small tier paths unchanged. `--turbo` flag now propagates as `/uberdev:orchestrator --turbo …`.
- `brainstorm` skill: added a note acknowledging `/solve` and `/turbo` route through the orchestrator skill; brainstorm itself remains the canonical reference and the right invocation for ad-hoc design work.
- `write-plan` skill: execution handoff is now non-interactive — defaults to subagent-driven; explicit user opt-in for inline. Resolves the `/turbo` unattended-flow break (issue #5).

### Fixed
- `/turbo` no longer halts on a "Subagent-Driven vs. Inline Execution?" prompt during plan handoff. Closes #5 (architecturally, via the writer-subagent refactor in #6).

## [0.6.0] - 2026-04-28

### Added
- `/solve` Ghostty dispatcher tab-spawns into the originating Ghostty window when invoked from inside Ghostty (`TERM_PROGRAM=ghostty`), keeping per-project workspaces visually grouped instead of cluttering the desktop with new top-level windows. `SOLVE_GHOSTTY_NEW_WINDOW=1` forces the legacy new-window behavior; AppleScript failures (e.g. Accessibility permission denied) fall back to it automatically with a stderr warning.
- `/turbo <issue>` slash command: unattended `/solve` that auto-accepts the brainstorm phase's lead-agent recommendations for medium/large tiers (parallel research still runs — recommendation grounding preserved). Trivial/small tiers behave identically to `/solve`. Composes orthogonally with `--auto` (permission-mode flag); `/turbo <issue> --auto` is the max-autonomy combo. No new approval gates — only collapses the clarifying-questions loop. `/turbo` also gains the same Ghostty tab-spawn behavior as `/solve`.
- `/solve --auto` (and `/turbo --auto`) flag: enables Claude Code's `--permission-mode auto` classifier in the spawned agent. Auto-approves low-risk ops (file edits, reads, package installs) and blocks high-risk ones (force push, `rm -rf` on pre-existing files, exfil, self-modification, `--dangerously-skip-permissions`). Resolves from CLI flag → `SOLVE_AUTO=1` env → `solve_auto: true` in `.claude/uberdev.local.md`. `/turbo <issue> --auto` is the max-autonomy combo.

### Changed
- `brainstorm` skill: parallel research dispatch promoted to **default first step** (before clarifying questions; skipped only for trivial tasks). The 2-3 proposed approaches are now grounded in research synthesis, not speculation. No approval gates added — "single forward pass" stays.

### Removed
- Deprecated slash-command shims `/uberdev:brainstorm`, `/uberdev:execute-plan`, `/uberdev:write-plan` removed. They were Superpowers-port leftovers redirecting to the canonical skills of the same name; invoke the skills directly via the Skill tool instead.

## [0.5.0] - 2026-04-28

### Added
- `SessionEnd` hook: best-effort cleanup of `~/.claude/.uberdev-answers`, `/tmp/uberdev-*` (plugin-prefixed only), and brainstorm event files older than 24h.
- `PreCompact` hook: append `.claude/auto-memory.md` to `.claude/session-archive.md` before compaction wipes context (silent no-op when absent; refuses to write through a symlinked `.claude/`).
- `.claude/uberdev.local.md` per-project configuration (YAML frontmatter for tier, review depth, terminal, parallel toggle); env vars override file settings.
- `AskUserQuestion` fast-path in `brainstorm` skill for discrete direction selection (2-5 options) without spinning up the visual companion. Visual companion remains the primary path for full design exploration.
- `isolation: "worktree"` guidance in `subagent-driven-dev` skill — Pattern B's controller-only-git approach is the documented opt-out; everything else defaults to worktree isolation.
- YAML frontmatter (`description`, `argument-hint`, `allowed-tools`) on `/issue` and `/solve` — were previously missing, leaving the picker with empty descriptions and triggering permission prompts on every `gh`/`find`/`osascript` call.
- `CONTRIBUTING.md` (contributor onboarding: quick start, repo layout, conventional commits, branch naming, PR expectations, `/simplify` mandate).
- `CHANGELOG.md` (Keep-a-Changelog 1.1.0 format covering v0.2.0 → v0.5.0).

### Changed
- 5 detail-oriented agents (`comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `plan-reviewer`, `type-design-analyzer`) switched from `model: inherit` to `model: haiku`. Since `/uberdev:review-pr` dispatches all 7 agents in parallel and is bound by the slowest, switching the detail agents to Haiku 4.5 cuts wall-time ~15-20%.
- `code-simplifier` agent rules made stack-agnostic — was hardcoding JS/React conventions (ES modules, `function` keyword, React Props types); now defers to project CLAUDE.md / style guide and language-agnostic clarity rules.
- `plugin.json` description trimmed from ~1.4 KB to one impactful sentence (marketplace listing aesthetics).
- `/uberdev:simplify` `allowed-tools` gains `Edit`, `Write`, `MultiEdit` (was hitting permission prompts on every fix attempt).
- `/uberdev:review-pr` `allowed-tools` narrows `Bash` to `Bash(git*)`, `Bash(gh*)` (read-only command).

### Fixed
- **Critical:** v0.4.0's `/issue` Phase 2/3/4 parallel fanout was silently broken — subagents have no shell context, so `$REPO`/`$DESC`/`$KEYWORDS`/`$COMMITLINT` references in agent briefs didn't resolve. Now resolves in orchestrator bash and bakes literal values into each agent brief.
- **Security (RCE):** `/solve` no longer passes `--dangerously-skip-permissions` to the autonomous agent. A malicious GitHub issue body could otherwise have executed under the user's account; the spawned agent now runs in an interactive terminal where the user gates each permission.
- **Security (prompt-injection):** `inject-brainstorm-answers` hook validates each event line as JSON via `jq`, HTML-escapes `<`/`>`, and refuses symlinked event paths. Closes a vector where any process in the cwd could plant arbitrary closing tags + instructions in the next user turn.
- `session-start` hook replaces fragile manual `escape_for_json` + `printf '%s'` interpolation with `jq -Rs`-style construction. Handles control bytes 0x00-0x1f and stray `%` format-spec collisions that previously corrupted output.
- `pre-compact` hook now refuses to write through a symlinked `.claude/` directory (`[ -d ]` follows symlinks; explicit `[ ! -L ]` guard added).
- Cross-platform `sed -i` in `/solve` — was BSD-only `-i ''` (broke on Linux with `sed: can't read : No such file`); now detects platform via `uname` and uses correct syntax on macOS + Linux.
- `session-start` no longer captures stderr into the SKILL.md content variable (`2>&1` → `2>/dev/null`); a missing skill file now degrades to empty injection rather than appearing as `Error reading…` content.

### Performance
- `inject-brainstorm-answers` per-line `jq -e -c .` fork loop collapsed to a single streaming `jq -R 'fromjson? // empty'` call. Saves ~200-500ms per UserPromptSubmit on active brainstorm sessions (50+ events).
- Two filesystem walks in `inject-brainstorm-answers` (blanket symlink scan + events-file `find`) folded into one targeted walk.

## [0.4.0] - 2026-04-28

### Added
- Parallel-fanout orchestration spread across the plugin: `/uberdev:review-pr` flips its default from sequential to **parallel** (all applicable review agents dispatch concurrently in a single turn).
- `/uberdev:issue` Phase 2/3/4 (codebase investigation + duplicate search + label/scope validation) runs as three parallel agents — roughly 60-70% wall-time savings.
- `systematic-debugging` skill gains **competing-hypothesis fanout** — read-only investigators per hypothesis, no anchoring on the first guess.
- `brainstorm` skill gains optional parallel design-direction exploration for high-stakes designs.
- `write-plan` skill gains opt-in alternative-plan generation (3 decomposition strategies).
- `receiving-code-review` skill adds multi-reviewer parallel triage.

### Changed
- `verification-before-completion` skill documents parallel verification dispatch (independent test/lint/build/typecheck checks running concurrently).
- Documented the parallel-default as a deliberate divergence from upstream `pr-review-toolkit`.

## [0.3.1] - 2026-04-28

### Changed
- `/uberdev:simplify` realigned with Anthropic's built-in `/simplify`: three-parallel-agent orchestrator — Code Reuse, Code Quality, and Efficiency reviewers fan out concurrently in a single Task-tool turn; controller aggregates findings and fixes them.
- Iron rule preserved (no behavior changes), plus UberDev's separate `refactor:` commit mandate.

### Fixed
- Restored proactive-trigger examples in the `code-simplifier` agent that were dropped during the orchestrator refactor.

## [0.3.0] - 2026-04-28

### Added
- Full Superpowers parity port: `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev` skills.
- Brainstorm Visual Companion: Neo Brutalism UI served by a local server, with `frame-template.html`; sessions persist to `.uberdev/brainstorm/`.
- `SessionStart` hook that injects the `using-uberdev` primer at conversation start so Claude knows how to discover plugin skills.

## [0.2.1] - 2026-04-27

### Added
- Wave-based parallel execution (Pattern B) in `/solve` and `/uberdev:subagent-driven-dev`: every task in a wave dispatches in parallel; waves run sequentially.
- `uberdev:write-plan` requires three new headers per task (`Depends on:`, `Wave:`, `Owns:`) and an `## Execution Waves` summary so dependencies and file ownership are explicit.

### Changed
- One shared feature-branch worktree across all waves — no per-task worktree, no merge step between waves.
- Controller (not implementers) runs `git add` / `git commit` to eliminate `.git/index.lock` races. Implementers report changed paths instead.

## [0.2.0] - 2026-04-27

### Added
- Initial public release of the UberDev marketplace and `uberdev` plugin.
- `/solve <issue-number>`: spawns an autonomous Claude agent in a new terminal session (cmux / Ghostty / iTerm / Terminal.app / nohup) with tier-aware triage — trivial issues skip the brainstorm; large ones get the full plan-and-review pipeline.
- `/issue <description>`: eight-phase pipeline that creates a well-investigated, deduped, label-validated GitHub issue, including codebase search, full-text dedup against closed issues, commitlint scope validation, and a triage hint that `/solve` reads later.
- Bundled skills: `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch` — `/solve` runs standalone with no Superpowers / pr-review-toolkit / code-simplifier dependency.
- Bundled review agents: `code-reviewer`, `code-simplifier`, `comment-analyzer`, `plan-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`.
- Bundled commands: `/uberdev:review-pr`, `/uberdev:simplify`.

### Changed
- Documentation: README expanded with `Updating` section explaining manual vs auto-update for third-party marketplaces (`docs:` commit `007537b` on 2026-04-27 superseded by this release).

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/TheFJK/UberDev/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/TheFJK/UberDev/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/TheFJK/UberDev/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/TheFJK/UberDev/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/TheFJK/UberDev/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/TheFJK/UberDev/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
