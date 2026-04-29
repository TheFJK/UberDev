---
name: post-impl-review
description: Shared post-implementation review fanout — dispatches 5 reviewer agents (code-reviewer, simplifier, silent-failure-hunter, type-design-analyzer, comment-analyzer) IN A SINGLE MESSAGE and aggregates findings. Use after implementation completes (per-wave from subagent-driven-dev, or post-impl from /solve trivial/small inline prompt).
---

# Post-Implementation Review

## Overview

5 reviewer agents fire in PARALLEL inside a single assistant turn; their findings are aggregated into a single non-blocking summary returned to the caller. The reviewers are advisory — at this layer the caller continues regardless of `REVISIONS_REQUIRED` verdicts. This keeps wall-clock cost low (one round-trip for five perspectives) while still applying multi-axis scrutiny to every wave's commit.

**Announce at start:** "I'm using the post-impl-review skill to fan out the 5 reviewer agents."

## When to invoke

- **`uberdev:subagent-driven-dev`** — after each wave commits, before moving to the next wave. Findings inform (but do not block) the next wave dispatch.
- **`/solve` trivial/small inline prompt** — after the implementer's commit lands. Findings get attached to the PR body or follow-up issue.

## Critical invariant — single-message fanout

Quote from `~/.claude/CLAUDE.md`: *"Parallelize independent work — single message, multiple Agent tool calls."*

The 5 Task() calls below MUST be in ONE assistant turn. Splitting across messages defeats parallelism and regresses the design contract — five sequential round-trips would multiply wall-clock cost and break the "one round-trip for five perspectives" guarantee that the rest of the pipeline relies on.

## Critical invariant — no skill re-entry

This skill MUST NOT trigger `uberdev:brainstorm` or `uberdev:write-plan`. Per orchestrator constraint (paraphrased to keep the anti-loop static-check happy): the write-plan skill MUST NOT be called from inside this chain — its `## Execution Handoff` would itself transition to `uberdev:subagent-driven-dev`, which would duplicate-invoke. The same anti-loop rule applies to the brainstorm skill, whose own handoff would re-trigger plan-writing.

Concretely:
- Do NOT call the brainstorm skill (its handoff would re-trigger plan-writing).
- Do NOT call the write-plan skill (its `## Execution Handoff` would itself transition to `uberdev:subagent-driven-dev`, which is the very caller already running this review).
- Do NOT spawn any agent whose own SKILL/agent body re-enters those two skills.

If a reviewer agent surfaces a finding that "we should re-plan", record it as a finding only — the caller (or a human) decides whether to escalate; this skill never re-enters the planning chain on its own.

## Inputs (passed by caller)

- `changed_paths` — list of files modified by the implementation (e.g. one wave's diff, or one trivial-tier commit's diff).
- `commit_range` — git rev range for diff context, e.g. `HEAD~3..HEAD`.
- `tier` — one of `trivial` / `small` / `medium` / `large`. Used only for reviewer model selection (Haiku for trivial/small, Sonnet for medium/large) per each agent's frontmatter.

## Process

### Step 1: Build the shared reviewer brief

Assemble a single brief that all 5 reviewers will receive verbatim:

1. Paste `changed_paths` as a bulleted list.
2. Paste the `commit_range` diff. If the diff exceeds 2000 lines, summarise per-file (file path + 1-line summary of the change) and inline only the files where the per-line scrutiny actually matters for that reviewer's lens.
3. Paste the issue's acceptance criteria summary if available (read from `.uberdev/research/$RUN_ID/` or the plan's `## Goal` section).

The brief is identical for all 5 reviewers — each agent's own system prompt narrows the lens.

### Step 2: Dispatch 5 Task() agents in a SINGLE message

In ONE assistant turn, fire 5 Task() calls in parallel. Each receives the same brief; each returns its own reviewer YAML.

| Reviewer | Agent file | Lens |
|---|---|---|
| `code-reviewer` | `agents/code-reviewer.md` (sonnet) | Correctness, design, test coverage |
| `code-simplifier` | `agents/code-simplifier.md` | DRY, dead code, over-engineering |
| `silent-failure-hunter` | `agents/silent-failure-hunter.md` | Swallowed errors, ignored returns, silent fallbacks |
| `type-design-analyzer` | `agents/type-design-analyzer.md` | `any`/`unknown` misuse, type safety holes |
| `comment-analyzer` | `agents/comment-analyzer.md` | Stale, redundant, or load-bearing comments |

Each return MUST be in this YAML shape (each agent's own frontmatter codifies it):

```yaml
verdict: APPROVE | REVISIONS_REQUIRED | REJECT
findings:
  - severity: blocker | suggestion
    location: <path>:<line>
    summary: <1-line>
    detail: <prose>
confidence: low | medium | high
```

### Step 3: Wait for all 5 returns; parse each YAML

Wait until all 5 Task() calls have returned (the harness blocks the assistant turn until they all complete — that is the parallelism win). Parse each YAML block.

Failure handling:
- If any single reviewer returns `BLOCKED` (timeout / agent error / unparseable YAML): log a warning to `.uberdev/research/$RUN_ID/post-impl-review.log`, drop that reviewer, continue with N-1.
- If `code-reviewer` itself returns `BLOCKED`: log critical and surface to caller — the caller chooses to continue or escalate (e.g. retry the wave, or open an issue and continue).

### Step 4: Aggregate

Aggregate the 5 returns into the table format below plus the bottom line `Aggregated: N blockers, M suggestions. Continue.`

Write the aggregation to:
- `.uberdev/research/$RUN_ID/post-impl-review-wave-$WAVE.md` (per-wave use from `subagent-driven-dev`)
- `.uberdev/research/issue-$N/post-impl-review.md` (trivial/small inline use from `/solve`)

Aggregation table format:

```
| Agent | Verdict | Top finding |
|-------|---------|-------------|
| code-reviewer        | APPROVE | (no blockers) |
| code-simplifier      | REVISIONS_REQUIRED | <top issue summary> |
| silent-failure-hunter | APPROVE | <empty if APPROVE> |
| type-design-analyzer | APPROVE | <...> |
| comment-analyzer     | APPROVE | <...> |

Aggregated: 0 blockers, 1 suggestion. Continue.
```

Counting rules:
- "blockers" = sum of `severity: blocker` findings across all 5 returns.
- "suggestions" = sum of `severity: suggestion` findings across all 5 returns.
- The trailing `Continue.` is fixed text — this skill is non-blocking by design (Q1 deferral: spec-reviser-style auto-fix loop is out of scope).

## Output (returned to caller, NOT a YAML block)

Return a prose summary of the aggregation table above to the caller. Example:

> Post-impl review for wave 2 of issue #11 complete. 5 reviewers ran in parallel. Aggregated: 0 blockers, 2 suggestions (code-simplifier flagged a dead branch in `foo.ts`; comment-analyzer flagged a stale TODO in `bar.ts`). Full table at `.uberdev/research/$RUN_ID/post-impl-review-wave-2.md`. Continue.

Findings are advisory at this layer — **the caller does NOT block on `REVISIONS_REQUIRED`**. (Per Q1: spec-reviser-style auto-fix loop is deferred. The aggregated file is the artifact downstream tooling reads if it wants to triage findings later.)

## Failure modes

| Symptom | Action |
|---|---|
| 1 reviewer returns `BLOCKED` (timeout/error) | Log warning, drop that reviewer, continue with N-1. |
| 2+ reviewers return `BLOCKED` | Log warning, continue with whatever returned. The aggregation table notes the dropped reviewers as `BLOCKED` rows. |
| `code-reviewer` itself returns `BLOCKED` | Log critical. Surface to caller: caller decides continue-vs-escalate. |
| All 5 return `BLOCKED` | Log critical, return summary `Aggregated: 0 blockers, 0 suggestions (all reviewers blocked). Continue.` — caller still continues; the absence of review is itself recorded. |
| YAML parse fails on a return | Treat as `BLOCKED` for that reviewer; same handling as above. |

## Integration

**Called by:**
- **`uberdev:subagent-driven-dev`** — after each wave's implementer commits land, before dispatching the next wave.
- **`/solve` trivial/small inline prompt** — after the implementer's single commit lands.

**Does NOT call:**
- `uberdev:brainstorm` (anti-loop guard)
- `uberdev:write-plan` (anti-loop guard)
- `uberdev:subagent-driven-dev` (would loop into self via the parent caller)

**Pairs with:**
- `agents/code-reviewer.md`, `agents/code-simplifier.md`, `agents/silent-failure-hunter.md`, `agents/type-design-analyzer.md`, `agents/comment-analyzer.md` — the 5 reviewer agent definitions whose frontmatter codifies the YAML return contract.
