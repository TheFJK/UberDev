---
description: "Review changed code for reuse, quality, and efficiency, then fix any issues found"
argument-hint: "[additional-focus]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
---

# Simplify: Code Review and Cleanup

Review all changed files for reuse, quality, and efficiency. Fix any issues found.

**Iron rule:** preserve behavior. Do not change function signatures, return types, thrown exception types, or public API surface. If a simplification can't be made without behavior risk, call it out — don't apply it silently.

## Phase 1: Identify Changes

Run `git diff` (or `git diff HEAD` if there are staged changes) to see what changed. If there are no git changes, review the most recently modified files that the user mentioned or that you edited earlier in this conversation.

If `$ARGUMENTS` is non-empty, treat it as **additional focus** to add to each agent's brief (see Phase 2).

## Phase 2: Launch Three Review Agents in Parallel

Use the **Task** tool to launch all three agents concurrently **in a single message** (one assistant turn, three `Task` tool_use blocks), each with `subagent_type: uberdev:code-simplifier`. Pass each agent the full diff so it has the complete context, plus a `## Lens emphasis: <Reuse | Quality | Efficiency>` subsection identifying the lens. If `$ARGUMENTS` is set, append it under an `## Additional Focus` heading at the bottom of each agent brief (orthogonal to lens emphasis — lens parameterises which checklist runs, additional focus narrows scope). Concrete shape per lens:

```
Task(
  subagent_type: uberdev:code-simplifier,
  description: "Lens: <Reuse | Quality | Efficiency>",
  prompt: <<diff_brief>>\n\n## Lens emphasis: <Reuse | Quality | Efficiency>\n\n## Additional Focus\n<$ARGUMENTS verbatim>
)
```

### Lens 1: Code Reuse Review (`## Lens emphasis: Reuse`)

Each lens dispatches the same `uberdev:code-simplifier` agent with the lens-emphasis subsection in the prompt body — three Task() calls in one assistant turn, single source of truth for the named-agent dispatcher.

For each change:

1. **Search for existing utilities and helpers** that could replace newly written code. Look for similar patterns elsewhere in the codebase — common locations are utility directories, shared modules, and files adjacent to the changed ones.
2. **Flag any new function that duplicates existing functionality.** Suggest the existing function to use instead.
3. **Flag any inline logic that could use an existing utility** — hand-rolled string manipulation, manual path handling, custom environment checks, ad-hoc type guards, and similar patterns are common candidates.

### Lens 2: Code Quality Review (`## Lens emphasis: Quality`)

Review the same changes for hacky patterns:

1. **Redundant state**: state that duplicates existing state, cached values that could be derived, observers/effects that could be direct calls
2. **Parameter sprawl**: adding new parameters to a function instead of generalizing or restructuring existing ones
3. **Copy-paste with slight variation**: near-duplicate code blocks that should be unified with a shared abstraction
4. **Leaky abstractions**: exposing internal details that should be encapsulated, or breaking existing abstraction boundaries
5. **Stringly-typed code**: using raw strings where constants, enums (string unions), or branded types already exist in the codebase
6. **Unnecessary JSX nesting**: wrapper Boxes/elements that add no layout value — check if inner component props (flexShrink, alignItems, etc.) already provide the needed behavior
7. **Nested conditionals**: ternary chains (`a ? x : b ? y : ...`), nested if/else, or nested switch 3+ levels deep — flatten with early returns, guard clauses, a lookup table, or an if/else-if cascade
8. **Unnecessary comments**: comments explaining WHAT the code does (well-named identifiers already do that), narrating the change, or referencing the task/caller — delete; keep only non-obvious WHY (hidden constraints, subtle invariants, workarounds)

### Lens 3: Efficiency Review (`## Lens emphasis: Efficiency`)

Review the same changes for efficiency:

1. **Unnecessary work**: redundant computations, repeated file reads, duplicate network/API calls, N+1 patterns
2. **Missed concurrency**: independent operations run sequentially when they could run in parallel
3. **Hot-path bloat**: new blocking work added to startup or per-request/per-render hot paths
4. **Recurring no-op updates**: state/store updates inside polling loops, intervals, or event handlers that fire unconditionally — add a change-detection guard so downstream consumers aren't notified when nothing changed. Also: if a wrapper function takes an updater/reducer callback, verify it honors same-reference returns (or whatever the "no change" signal is) — otherwise callers' early-return no-ops are silently defeated
5. **Unnecessary existence checks**: pre-checking file/resource existence before operating (TOCTOU anti-pattern) — operate directly and handle the error
6. **Memory**: unbounded data structures, missing cleanup, event listener leaks
7. **Overly broad operations**: reading entire files when only a portion is needed, loading all items when filtering for one

## Phase 3: Fix Issues — dispatch `code-fixer` subagent

Wait for all three lenses to complete. Aggregate their findings to `.uberdev/research/<RUN_ID>/simplify-final.md` (mint a fresh `RUN_ID` if standalone — same shape as `/uberdev:review-pr`'s Run-ID format, regex `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$`).

Dispatch a fresh `code-fixer` subagent (defined in `plugins/uberdev/agents/code-fixer.md`) to apply the findings as a single `refactor:` conventional commit — this command's main turn no longer holds apply-loop edits in-context. Use the Task tool:

```
Task(
  subagent_type: uberdev:code-fixer,
  description: "Apply simplify findings as a refactor: commit",
  prompt: <<wraps simplify-final.md under <external-untrusted-input source="post-impl-review-aggregate">,
            commit_range, working_dir, pr_number (or n/a if standalone),
            phase=phase2, commit_type_prefix=refactor:>>
)
```

The agent enforces:
- **Iron rule:** preserve behavior. The agent rejects any finding that would materially change runtime behavior or remove error handling, returning `disposition: REFUSED, reason: "behavior-change-rejected"`.
- **Separate `refactor:` commit:** ONE `refactor:` commit only — the agent's contract locks Phase 2 to a single commit (R8.6 separate-commit invariant). Mirrors `/uberdev:review-pr` Phase 2 apply path, so reviewers can always tell "feature/fix" apart from "simplify pass" by commit boundary alone.

When the agent returns:
1. Briefly summarize what was fixed (or confirm `status: NO_FIXES_NEEDED` — the code was already clean).
2. The agent has already staged + committed; capture `commits[0].sha` and report it to the user. Surface every `findings_disposition` row where `disposition != APPLIED` so advisory findings (false positives, behavior-change refusals) are never silently dropped.

## When to run

The canonical place `/simplify` runs in the chain is **automatically as Phase 2 of `/uberdev:review-pr`** — every PR review chains a mandatory simplify pass after the review-and-fix loop, applying all three lenses to the full `<base>..HEAD` diff (original commits + Phase 1 review-fix commits). That run is strictly more complete than any pre-push call would be, so a separate pre-push `/simplify` is **not** part of `/solve` or `/turbo` — re-running it would duplicate work on a smaller diff.

Standalone invocations are still valid for these out-of-chain cases:

- After a non-trivial implementation or bug fix has landed but you don't intend to open a PR yet (e.g. iterating on a long-lived branch).
- After accepting code-review feedback that involves restructuring, before re-requesting review.
- Ad-hoc, when you want to clean up a specific edit without going through the full `/review-pr` fanout.

## When NOT to run

- Inside a `/solve` / `/turbo` heredoc before push — Phase 2 of `/uberdev:review-pr` already covers it on a strictly larger diff.
- On greenfield code that's still being designed.
- Mid-debugging — simplify after the bug is understood and fixed.
- On generated code, vendored deps, or test fixtures.
