# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `brainstorm` skill: parallel research dispatch promoted to **default first step** (before clarifying questions; skipped only for trivial tasks). The 2-3 proposed approaches are now grounded in research synthesis, not speculation. No approval gates added — "single forward pass" stays.

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

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/TheFJK/UberDev/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
