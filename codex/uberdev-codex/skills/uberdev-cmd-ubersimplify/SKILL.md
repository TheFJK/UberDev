---
name: uberdev-cmd-ubersimplify
description: "Use when the user wants to whole-codebase 3-lens simplification (Reuse/Quality/Efficiency). Packs the repo into a fixed fleet of byte-balanced areas (default 8), audits each area with ONE multi-lens code-simplifier, applies preserve-behavior fixes via code-fixer as one refactor: commit per area on a new branch, opens ONE PR for review, and files leftover blocker findings as GitHub issues. Whole-repo by default; pass a path/glob to narrow. --audit-only for a read-only scan. Invokable explicitly as $uberdev-cmd-ubersimplify. Original description: Whole-codebase 3-lens simplification (Reuse/Quality/Efficiency). Packs the repo into a fixed fleet of byte-balanced areas (default 8), audits each area with ONE multi-lens code-simplifier, applies preserve-behavior fixes via code-fixer as one refactor: commit per area on a new branch, opens ONE PR for review, and files leftover blocker findings as GitHub issues. Whole-repo by default; pass a path/glob to narrow. --audit-only for a read-only scan."
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/ubersimplify`). On Codex:

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

Original argument hint: `[path-or-glob] [--audit-only] [--all] [--no-issues] [--no-report] [--lens=Reuse,Quality,Efficiency] [--areas=N] [--concurrency=N] [--turbo]`

---



# /ubersimplify — whole-codebase 3-lens simplification

Runs the `/uberdev:simplify` lenses (**Reuse, Quality, Efficiency**) across the **entire
codebase** (or a path-scoped subtree) via a **fixed fleet of area agents** (one multi-lens
`code-simplifier` per byte-balanced area, default 8), then applies preserve-behavior
refactors via `code-fixer` — one `refactor:` commit per area — on a **new branch behind a
single PR** for review. Leftover findings the iron rule blocked are filed as GitHub issues.
This is the *writing* sibling of the read-only `/uberscan`. Design: `docs/rfc/0008-ubersimplify-command.md`.

## Usage
`/ubersimplify [path-or-glob] [flags]` — no path = whole repo.

| Flag | Meaning |
|------|---------|
| `--audit-only` | Read-only: scan + report + issues, no branch/fix/PR. |
| `--all` | Override the `MAX_AGENTS` (CB7) backstop. |
| `--no-issues` | Skip leftover-issue filing. |
| `--no-report` | Skip the markdown report. |
| `--lens=…` | Subset the lenses the single area agent runs (default all three). |
| `--areas=N` | Fleet size: pack the repo into ≤ N byte-balanced areas, one agent each (default 8, range 1-24). `--max-chunks=N` is a legacy alias. |
| `--concurrency=N` | Areas audited per wave (default from config, 3). |
| `--turbo` | Non-interactive: circuit breakers cap-and-continue instead of prompting. |

## Implementation

Invoke the `uberdev:ubersimplify-pipeline` skill with `$ARGUMENTS` in scope. The skill owns
all phases (scope+area-pack, per-area lens waves, aggregate, branch+apply, push+PR, issue
filing). This command performs only preflight validation, then hands off:

```bash
# Preflight
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: /ubersimplify must run inside a git repository" >&2; exit 2
fi
# A dirty tree would let `git checkout -b` + per-chunk commits sweep the user's
# uncommitted work into refactor commits. Refuse unless --audit-only (read-only).
if ! printf '%s' "$ARGUMENTS" | grep -q -- '--audit-only' \
   && [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash first (or use --audit-only)" >&2; exit 2
fi
# A detached HEAD has no branch to base the PR on, and the zero-commit teardown
# would `git checkout ""`. Refuse unless --audit-only (which never branches).
if ! printf '%s' "$ARGUMENTS" | grep -q -- '--audit-only' \
   && ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
  echo "error: /ubersimplify requires a branch checkout, not a detached HEAD (or use --audit-only)" >&2; exit 2
fi
if printf '%s' "$ARGUMENTS" | grep -q -- '--no-issues' && printf '%s' "$ARGUMENTS" | grep -q -- '--no-report'; then
  echo "error: --no-issues and --no-report together leave no output sink" >&2; exit 2
fi
```

Then invoke `Skill(uberdev:ubersimplify-pipeline)` with the same `$ARGUMENTS`.
