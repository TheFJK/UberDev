---
description: "Simplify recently modified code for clarity and maintainability while preserving functionality"
argument-hint: "[file-or-scope]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Simplify Code

Dispatch the `uberdev:code-simplifier` agent to refine recently modified code for clarity, consistency, and maintainability — without changing behavior.

**Scope (optional):** "$ARGUMENTS"

## Workflow

1. **Determine the diff**
   - If `$ARGUMENTS` names files or a path, use that.
   - Otherwise, use `git diff` (unstaged) plus `git diff --staged` to identify recently modified code.
   - If both are empty, fall back to the most recent commit: `git show HEAD --stat`.

2. **Dispatch the agent**

   Launch the `uberdev:code-simplifier` agent via the Task tool, passing it:
   - The file paths (or diff hunks) to focus on.
   - Project conventions from any `CLAUDE.md` files in scope.
   - Explicit instruction: **do not change behavior** — refactor for clarity only.

3. **Review the agent's report**
   - Each suggestion should preserve the public surface (function signatures, return types, exception types).
   - Reject any suggestion that materially changes runtime behavior or removes error handling.
   - Apply accepted suggestions as a separate `refactor:` commit.

## When to run

- Before pushing — per the global "always /simplify before push" rule in user CLAUDE.md.
- After a non-trivial implementation or bug fix has landed but before review.
- After accepting code-review feedback that involves restructuring.

## When NOT to run

- On greenfield code that's still being designed.
- Mid-debugging — simplify after the bug is understood and fixed.
- On generated code, vendored deps, or test fixtures.

## Notes

- The agent focuses on **recently modified code** by default. To simplify a specific file regardless of modification status, pass its path as `$ARGUMENTS`.
- Behavior preservation is the iron rule. If a simplification can't be made without behavior risk, the agent should call it out rather than apply it silently.
- This command is a thin wrapper. The agent (`plugins/uberdev/agents/code-simplifier.md`) owns the actual simplification logic.
