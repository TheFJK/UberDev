# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- _placeholder_

### Changed
- _placeholder_

### Fixed
- _placeholder_

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

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
