---
description: "Comprehensive PR review using specialized agents"
argument-hint: "[review-aspects] [--no-simplify] [--turbo]"
allowed-tools: ["Bash(git*)", "Bash(gh*)", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality.

**Review Aspects (optional):** "$ARGUMENTS"

`/uberdev:review-pr` is a true **two-phase** command. Both phases run by default — flow: **review fanout → fix loop → simplify fanout → final aggregation**.

- **Phase 1 — Review + Fix loop**: parallel review fanout, then auto-apply fixes for the findings.
- **Phase 2 — Simplify pass**: parallel fanout of the three simplify lenses (reuse / quality / efficiency) defined in `/uberdev:simplify`, with auto-applied edits committed separately. Single-message dispatch per the `uberdev:post-impl-review` contract.

Pass `--no-simplify` (anywhere in the arguments) to skip Phase 2 and preserve the legacy single-pass behavior. Cost trade-off: Phase 2 adds three extra agent invocations per run; opt out for fast feedback loops on iterative review (e.g. when you've already run `/uberdev:simplify` separately).

Pass `--turbo` (anywhere in the arguments) to acknowledge invocation from `finish-branch`'s turbo-mode auto-chain. `/review-pr` accepts `--turbo` for forwarder-compatibility and parses it without error, but its presence does NOT alter Phase 1, Phase 2, or trust-signal emission — the run produces an identical Phase 2 simplify commit, identical trailer payload, identical artifact triplet (label + trailer + JSON). Single code path → deterministic SHA binding for the `Reviewed-by:` trailer. The flag is documented here so the producer-defines-its-API contract is explicit (no LLM interpretation latitude).

## Review Workflow:

1. **Determine Review Scope**
   - Check git status to identify changed files
   - Parse arguments to see if user requested specific review aspects
   - Detect `--no-simplify` token in `$ARGUMENTS` and strip it from the aspect list — sets `SIMPLIFY_PHASE=0`, otherwise `SIMPLIFY_PHASE=1` (default). Detect `--turbo` token in `$ARGUMENTS` and strip it from the aspect list — `--turbo` is an acknowledged no-op (forwarder-compatibility for `finish-branch`'s turbo-mode auto-chain); it does NOT mutate `SIMPLIFY_PHASE` or any other phase variable.
   - Default: Run all applicable reviews + Phase 2 simplify pass

2. **Available Review Aspects:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable reviews (default)

3. **Identify Changed Files**
   - Run `git diff --name-only` to see modified files
   - Check if PR already exists: `gh pr view`
   - Identify file types and what reviews apply

4. **Determine Applicable Reviews**

   Based on changes:
   - **Always applicable**: uberdev:code-reviewer (general quality)
   - **If test files changed**: uberdev:pr-test-analyzer
   - **If comments/docs added**: uberdev:comment-analyzer
   - **If error handling changed**: uberdev:silent-failure-hunter
   - **If types added/modified**: uberdev:type-design-analyzer
   - **After passing review**: uberdev:code-simplifier (polish and refine)

5. **Launch Review Agents — parallel by default**

   **Dispatch all applicable agents concurrently in a single message** (one assistant turn, multiple Task tool_use blocks). Each agent sees the full diff and produces an independent report — they do not share state, so there is no reason to serialize them.

   This is a deliberate divergence from upstream `pr-review-toolkit`, which defaults to sequential. Parallel matches the orchestrator-first principle and the canonical fanout pattern used by `/uberdev:simplify`.

   **Sequential fallback** (only when explicitly requested via `sequential` argument):
   - Useful for interactive walkthroughs where you want to act on each report before the next
   - Otherwise, prefer parallel — wall-time scales with the slowest reviewer, not the sum

6. **Apply Phase 1 Fixes**

   Auto-apply the review fixes from the agent findings as one or more `fix:` / `refactor:` conventional commits. These are the **review-phase commits** — keep them distinct from the Phase 2 simplify commit (separate-commit invariant below).

   **Green-run predicate (Phase 1 contribution):** Phase 1 contributes to a green run iff after auto-apply convergence the verdict is `APPROVE`. `REVISIONS_REQUIRED` and `REJECT` end Phase 1 with no trust-signal emission and `/review-pr` exits with code 1 (see step 9 exit-code contract). The full green predicate combines this with Phase 2's status (defined in step 7) — only `(Phase 1 == APPROVE) AND (Phase 2 status ∈ {ran/APPROVE, skipped})` triggers trust-signal emission.

7. **Phase 2 — Mandatory Simplify Pass** (skip iff `SIMPLIFY_PHASE=0`)

   After Phase 1 fixes land, dispatch the three simplify lenses (**Code Reuse Review**, **Code Quality Review**, **Code Efficiency Review**) as a parallel fanout — **all three Task() calls in a SINGLE assistant message, ONE assistant turn**, mirroring the `uberdev:post-impl-review` single-message dispatch contract. The lens-by-lens checklist (what each agent looks for) is the canonical definition in `/uberdev:simplify` Phase 2 — refer there rather than restate.

   **Brief preparation** (mirrors `uberdev:post-impl-review` Step 1):

   - Compute the post-Phase-1 diff once via `git diff <base>..HEAD` and pass the same brief verbatim to all three Task() calls.
   - Truncation rule: if the diff exceeds 2000 lines, summarise per-file (path + 1-line summary) and inline only the files where per-line scrutiny matters for that lens. Same rule as `uberdev:post-impl-review` SKILL Step 1.

   Each lens preserves the iron rule from `/uberdev:simplify`: **behavior preservation is non-negotiable.**

   **Auto-apply simplify edits** in a separate `refactor:` conventional commit, distinct from the Phase 1 review-fix commits. Reviewers must be able to tell "review fixes" apart from "simplify pass" by commit boundary alone — this distinct commit boundary is mandatory, not stylistic.

   **On green Phase 2 (status ∈ {ran/APPROVE, skipped}), append the trust-signal trailer to the simplify-pass commit body:**

   ```
   Reviewed-by: uberdev/review-pr@<head-sha>
   ```

   where `<head-sha>` is the FULL 40-character SHA returned by `git rev-parse HEAD` immediately after the commit-write completes (NOT the abbreviated short-SHA — downstream `/merge` parser greps the literal 40-hex form). The trailer is the load-bearing trust artifact for `/merge` Phase 1.4 trust resolution (see `skills/merge/SKILL.md` Constants `REVIEW_PR_TRAILER_PREFIX`).

   **When Phase 2 is `skipped`** (no simplify commit exists because `--no-simplify` was set or no simplify-eligible diff was found): append the trailer via `git commit --amend` to the most-recent commit on the PR head — typically the last Phase 1 auto-apply fix commit, or the user's tip commit if no Phase 1 fixes were needed. The amend recomputes the head SHA, so the trailer payload binds to the **post-amend** SHA, not the pre-amend SHA. Recompute `git rev-parse HEAD` after the amend before writing the trailer payload. This commit goes through pre-commit hooks normally — never `--no-verify`. Author = current `git config user.email` / `user.name`; the trailer is procedural attribution to the `/review-pr` command (not a Claude attribution).

   **Advisory-only findings** (where a lens declines to edit because the change carries behavior risk, or the agent flags a concern outside the iron-rule envelope) are **never silently dropped** — they surface in the Phase 2 row of the final aggregation table (step 8) so the human reviewer sees them.

   **Non-blocking but exit-coded.** Phase 2 status governs the exit code (see step 9 exit-code contract):

   - `ran/APPROVE` or `skipped` → eligible for green; exit 0 if Phase 1 was APPROVE.
   - `blocked` (timeout, agent error, parse failure, aggregator crash) → exit 2. Phase 1 review-fix work is **not undone** — those commits land normally — but no trust-signal artifacts (label / trailer / JSON) are emitted, and the exit code surfaces the silent-failure mode that previously got swallowed. The Phase 2 row's Status is `blocked` (lowercase). Fix the aggregator before re-running.

   Phase 2 verdict ≠ Phase 2 status: an APPROVE verdict with `ran` status counts toward green; REVISIONS_REQUIRED or REJECT verdicts do NOT block trust-signal emission (they surface as advisory findings in the final aggregation table — see step 8). The trust-signal predicate is rooted in *status* (did the fanout complete cleanly?), not *verdict*.

8. **Final Aggregation — distinguish review-phase vs simplify-phase findings**

   After Phase 1 fixes land and (if enabled) Phase 2 simplify edits land, summarize both phases in a single table that **distinguishes review-phase findings from simplify-phase findings**:

   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

9. **Provide Action Plan**

   Organize findings, with the review-phase vs simplify-phase distinction preserved in every row:

   ```markdown
   # PR Review Summary

   ## Phase outcomes
   | Phase | Status | Verdict | Auto-applied | Advisory findings |
   |---|---|---|---|---|
   | Phase 1 — Review + Fix | ran | APPROVE / REVISIONS_REQUIRED / REJECT | <commit shas> | <count> |
   | Phase 2 — Simplify     | ran / blocked / skipped | APPROVE / REVISIONS_REQUIRED / REJECT (omit if status≠ran) | <commit sha or ∅> | <count> |

   `Verdict` reuses the canonical `uberdev:post-impl-review` reviewer enum (APPROVE | REVISIONS_REQUIRED | REJECT). `Status` is orthogonal: `ran` (the fanout completed), `blocked` (fanout failure — see "Non-blocking" above), `skipped` (`--no-simplify` was set).

   ## Critical Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Important Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Suggestions (X found)
   - [phase: review | simplify] [agent-name]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR

   ## Recommended Action
   1. Fix critical issues first
   2. Address important issues
   3. Consider suggestions
   4. Re-run review after fixes
   ```

## Trust-Signal Emission (on green run)

After the final aggregation table renders, evaluate the green-run predicate:

```
GREEN := (Phase 1 verdict == "APPROVE") AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
```

On GREEN, emit three SHA-bound durable artifacts in lockstep (all reference the same post-emission `headRefOid`):

1. **Label** — `gh pr edit <N> --add-label uberdev-approved` (idempotent — `gh` no-ops if the label is already present). The literal label string is `uberdev-approved` (see `skills/merge/SKILL.md` Constants `UBERDEV_APPROVED_LABEL`).

2. **Trailer** — already emitted in step 7 on the simplify commit (or amended onto the most-recent commit when Phase 2 is `skipped`). Verify with `git log -1 --format=%B | grep -E '^Reviewed-by: uberdev/review-pr@[a-f0-9]{40}$'` before proceeding to artifact 3.

3. **Audit JSON** — write to `.uberdev/runs/<run-id>/review-pr-verdict.json`:

```json
{
  "pr": <int>,
  "sha": "<full-40-char-head-sha>",
  "verdict": "APPROVE",
  "phases": {
    "phase1": {"status": "ran", "verdict": "APPROVE"},
    "phase2": {"status": "ran/APPROVE" | "skipped", "verdict": "APPROVE" | null}
  },
  "timestamp": "<ISO8601>"
}
```

The JSON is **local debug telemetry only** — `.uberdev/` is gitignored, so the JSON does NOT cross-clone. `/merge` consumes the trailer as the load-bearing trust artifact and treats the JSON as a corroborating presence check. See `skills/merge/SKILL.md` Phase 1.4 Path 2 for the consumer side.

On any artifact-emission failure (label add fails, JSON write fails): exit 2 (treat as `blocked`-equivalent because the trust-signal contract is broken). Print the failing `gh` / filesystem stderr; suggest re-running `/review-pr`.

### Run-ID format

`<run-id>` MUST be derived as:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
```

This mirrors the convention in `skills/merge/SKILL.md:209` (Phase 3.3ii scratch worktree path). Before any path concatenation, validate `<run-id>` against the regex:

```
^[0-9]{8}-[0-9]{6}-[a-f0-9]+$
```

See `skills/merge/SKILL.md` Constants `RUN_ID_REGEX`. If the regex match fails (defensive — should never trigger with internally-generated values), exit 2 and print: `BUG: run-id <value> does not match ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ — file an issue`. The regex constraint forecloses path-traversal if a future iteration ever sources `<run-id>` from external input.

## Exit-Code Contract

| Exit code | Condition |
|-----------|-----------|
| `0` | GREEN — Phase 1 verdict == `APPROVE` AND Phase 2 status ∈ {`ran/APPROVE`, `skipped`} |
| `1` | Phase 1 verdict ∈ {`REJECT`, `REVISIONS_REQUIRED`} (regardless of Phase 2) |
| `2` | Phase 2 status == `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure) |

Exit code `2` is a **behavioral break** from the previous always-exit-0 contract. Callers that scripted `/review-pr` against the old "always exits successfully" prose must either ignore the exit code (preserve old behavior) or branch on it (use new behavior). The new contract surfaces silent reviewer-crash failures that the trust signal exists to eliminate. Documented in CHANGELOG.

The exit code is rooted in Phase 2 *status*, not Phase 2 *verdict* — a `ran/APPROVE` exit-0 may still contain advisory `REVISIONS_REQUIRED` simplify findings surfaced in the aggregation table (step 8).

## Usage Examples:

**Full review (default):**
```
/uberdev:review-pr
```

**Specific aspects:**
```
/uberdev:review-pr tests errors
# Reviews only test coverage and error handling

/uberdev:review-pr comments
# Reviews only code comments

/uberdev:review-pr simplify
# Simplifies code after passing review
```

**Sequential override** (default is parallel):
```
/uberdev:review-pr all sequential
# Force one-at-a-time dispatch — use only for interactive walkthroughs
```

**Skip Phase 2 simplify pass** (legacy single-pass behavior):
```
/uberdev:review-pr --no-simplify
# Run only Phase 1 review-and-fix; skip the mandatory simplify fanout.
# Use when only correctness review is wanted (e.g. pre-merge gate after a
# /simplify pass already ran). Combinable with aspect args:
/uberdev:review-pr tests errors --no-simplify
```

## Agent Descriptions:

**uberdev:comment-analyzer**:
- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**uberdev:pr-test-analyzer**:
- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**uberdev:silent-failure-hunter**:
- Finds silent failures
- Reviews catch blocks
- Checks error logging

**uberdev:type-design-analyzer**:
- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**uberdev:code-reviewer**:
- Checks CLAUDE.md compliance
- Detects bugs and issues
- Reviews general code quality

**uberdev:code-simplifier**:
- Simplifies complex code
- Improves clarity and readability
- Applies project standards
- Preserves functionality

## Tips:

- **Run early**: Before creating PR, not after
- **Focus on changes**: Agents analyze git diff by default
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use specific reviews**: Target specific aspects when you know the concern

## Workflow Integration:

**Before committing:**
```
1. Write code
2. Run: /uberdev:review-pr code errors
3. Fix any critical issues
4. Commit
```

**Before creating PR:**
```
1. Stage all changes
2. Run: /uberdev:review-pr all
3. Address all critical and important issues
4. Run specific reviews again to verify
5. Create PR
```

**After PR feedback:**
```
1. Make requested changes
2. Run targeted reviews based on feedback
3. Verify issues are resolved
4. Push updates
```

## Notes:

- Agents run autonomously and return detailed reports
- Each agent focuses on its specialty for deep analysis
- Results are actionable with specific file:line references
- Agents use appropriate models for their complexity
- All agents available in `/agents` list
