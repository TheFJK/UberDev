# Contributing to UberDev

Thanks for considering a contribution. UberDev is a small, opinionated Claude Code plugin — patches that sharpen the existing `/solve` and `/issue` flows, port useful skills, or fix sharp edges are always welcome.

---

## Quick start

See [Install](README.md#install) in the README. Contributor delta: clone your fork and `/plugin marketplace add /absolute/path/to/UberDev` (your local checkout) instead of `marketplace add TheFJK/UberDev`.

When you change a plugin file, re-run `/plugin install uberdev@uberdev` to pick up the edits — Claude Code caches plugin assets per session. See Anthropic's [plugin install docs](https://docs.claude.com/en/docs/claude-code/plugins) and the [marketplace.json reference](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces) if you're adding a new plugin.

---

## Repo layout

See [Repo layout](README.md#repo-layout) in the README. Contributor-only additions:

- `plugins/uberdev/agents/` — reusable subagent prompts that orchestrator commands compose.
- `plugins/uberdev/skills/` — discoverable workflow skills (each is a folder with `SKILL.md` + optional supporting files).
- `plugins/uberdev/hooks/` — `SessionStart` / `PreToolUse` / `SessionEnd` / `PreCompact` event handlers, wired in `hooks.json`.
- `plugins/uberdev/licenses/` — bundled upstream license texts (Anthropic, Jesse Vincent) for the verbatim/adapted components listed in the README's "Bundled" section.

---

## Adding a component

Use the existing files as templates rather than starting from scratch — they encode the conventions reviewers will expect.

**Slash command** — copy `plugins/uberdev/commands/issue.md` or `solve.md`. Frontmatter declares argument hints and allowed tools; the body is a prompt the agent executes.

**Subagent** — copy any agent in `plugins/uberdev/agents/` (e.g. `code-reviewer.md`). Keep agent prompts focused on a single responsibility; orchestrator commands compose them.

**Skill** — copy a skill directory under `plugins/uberdev/skills/` (e.g. `brainstorm/` or `write-plan/`). Each skill is a folder with a `SKILL.md` (frontmatter `name` + `description`) plus optional supporting files. The `description` is what the dispatcher matches against — make it specific.

**Hook** — copy `plugins/uberdev/hooks/session-start` (or any sibling: `session-end`, `pre-compact`, `inject-brainstorm-answers`). Hooks are wired in `plugins/uberdev/hooks/hooks.json`.

If your change is large enough to need a design discussion, open a draft issue first.

---

## Conventional commits + branches

We use [Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`. Scope is optional but encouraged when the change is plugin-internal: `feat(uberdev): ...`. `enhancement` is a label, never a type.

Branches mirror commit types: `feat/short-name`, `fix/short-name`, `refactor/short-name`, etc. If you're working off a tracked issue, prefix with the number: `feat/123-add-thing`.

---

## Pull requests

1. Push your branch and open a PR against `main`.
2. Reference the issue with `Closes #N` in the PR body — merge will auto-close it.
3. **Open the PR and let `/uberdev:review-pr` Phase 2 run automatically** — it dispatches the three simplify lenses on the post-Phase-1 diff (full PR + review-fix commits) and lands the result as a separate `refactor:` commit. Do not run `/simplify` standalone before opening the PR — it would duplicate Phase 2 on a strictly smaller diff.
4. Confirm the existing smoke tests still pass — see _Local testing_ below.
5. Keep the PR focused. One topic per PR. Split unrelated changes.

CI is light by design (this plugin is markdown + shell scripts, not a build pipeline), so reviewer trust depends on small, atomic PRs.

---

## Local testing

`plugins/uberdev/docs/testing.md` documents the smoke-test matrix — run it after non-trivial changes to `/solve`, `/issue`, or any skill that the spawned agents invoke.

For pure markdown / docs edits, install the plugin locally and confirm the affected command or skill loads without warning (`/plugin` → Installed → `uberdev` shows no errors).

### Running tests locally

Run all shape-check tests with:

```bash
bash tests/turbo-flow.test.sh
bash tests/issue-causal-fanout.test.sh
bash tests/post-impl-review.test.sh
bash tests/spec-reviewer-plan-aware.test.sh
```

These also run in CI on every push and PR (`.github/workflows/test.yml`). All four are shape-checks against prompt files — no runtime behavioral tests yet.

---

## Code of conduct

Be kind, assume good faith, and keep technical disagreements technical. If you experience or witness behavior that crosses the line, open an issue tagged `conduct` (or email the maintainer). Owner is [@TheFJK](https://github.com/TheFJK), who handles reports and final calls on disputes.
