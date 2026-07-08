---
name: uberdev-cmd-dev
description: "Use when the user wants to fast lane for a minimal working prototype or small function. Decomposes the idea, builds it via parallel subagents in-session, runs one light review, opens a PR labelled `prototype`, and auto-files a harden issue. Skips spec/plan and full /review-pr by design. Invokable explicitly as $uberdev-cmd-dev. Original description: Fast lane for a minimal working prototype or small function. Decomposes the idea, builds it via parallel subagents in-session, runs one light review, opens a PR labelled `prototype`, and auto-files a harden issue. Skips spec/plan and full /review-pr by design."
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/dev`). On Codex:

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

Original argument hint: `<idea description> [--no-pr] [--no-issue]`

---



# Dev — Prototype Fast Lane

Build a minimal working prototype or small function from a free-text idea in **$ARGUMENTS**. `/dev` decomposes the idea, builds it via parallel `Task()` subagents in the current session, runs one light review, opens a PR labelled `prototype`, and auto-files a harden issue. It **deliberately skips** the spec → plan → full `/review-pr` pipeline that `/solve` and `/turbo` run — its output is honestly labelled prototype-grade work with a tracked path to production.

**Usage:** `/dev <idea description> [--no-pr] [--no-issue]`

- `--no-pr` → build and commit locally; skip PR creation and the harden issue.
- `--no-issue` → open the PR but skip the auto-filed harden issue.

Now invoke the `uberdev:dev-pipeline` skill — it owns the 7-phase pipeline (parse + scope gate + branch, decomposition, parallel build, integrate/commit/verify, light review, PR + label + harden issue, report). The skill renders inline, so `$ARGUMENTS` remains in scope for its logic.
