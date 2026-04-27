---
name: write-plan
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the write-plan skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree. **Set up an isolated worktree before starting:** `git worktree add .worktrees/<feature-name> -b <branch-name>` (verify `.worktrees/` is in `.gitignore`; add and commit if not). Run the project's setup command (`npm install` / `cargo build` / `pip install -r requirements.txt` / `go mod download` — auto-detect from project files) and the project's test command to verify a clean baseline before implementing the plan.

**Save plans to:** `docs/uberdev/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Wave Decomposition (MANDATORY)

After mapping the file structure, build the dependency graph and group tasks into **waves**. Tasks in the same wave dispatch in parallel; waves run sequentially.

**Rules for assigning waves:**
1. A task with `Depends on: none` goes in `wave-1`.
2. A task's wave = `max(wave of each dependency) + 1`.
3. Two tasks can share a wave **only if** their `Owns` allowlists are strictly disjoint. Any shared file = move the later task to the next wave.
4. Schema/contract tasks (types, interfaces, DB migrations, shared constants) almost always belong to `wave-1` alone — most other tasks depend on them.

The wave's executor (`uberdev:subagent-driven-dev`) dispatches all wave tasks concurrently in the **same shared feature-branch worktree**, with each implementer restricted to its `Owns` allowlist. The controller — not the implementers — runs git, so disjoint allowlists are sufficient to prevent collisions.

**Required plan-level summary (immediately after the header):**

```markdown
## Execution Waves

- **wave-1** (parallel): T1, T2, T3
- **wave-2** (parallel, depends on wave-1): T4, T5
- **wave-3** (sequential, depends on wave-2): T6

Worker dispatches each wave concurrently; controller waits for the wave to finish before starting the next.
```

This summary is what `uberdev:subagent-driven-dev` reads to decide its dispatch pattern. If you can't produce a sensible wave summary, the plan's task boundaries are wrong — fix the decomposition before continuing.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use uberdev:subagent-driven-dev (recommended) or uberdev:execute-plan to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

Every task MUST declare its dependencies and parallel-dispatch wave. Without this, `uberdev:subagent-driven-dev` can't safely fire tasks concurrently and falls back to slow sequential execution.

````markdown
### Task N: [Component Name]

**Depends on:** [task IDs this requires, or `none`]
**Wave:** [wave-N — tasks in the same wave dispatch in parallel]
**Owns (file allowlist):** [explicit list of paths this task may create/edit — used to enforce no overlap with sibling tasks in the same wave]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- DRY, YAGNI, TDD, frequent commits

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**1. Spec coverage:** Skim each section/requirement in the spec. Can you point to a task that implements it? List any gaps.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

**4. Wave correctness:**
- Does every task declare `Depends on:`, `Wave:`, and `Owns:`?
- Are dependencies acyclic? (Task A → B → A is a planning bug.)
- For each wave, are all `Owns` allowlists pairwise disjoint? Any overlap means the wave is unsafe — split it.
- Is wave-1 a single bottleneck task? That's a smell — can the schema/contract work be split, or are downstream tasks under-decomposed?

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## Execution Handoff

After saving the plan, offer execution choice:

**"Plan complete and saved to `docs/uberdev/plans/<filename>.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using execute-plan, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use `uberdev:subagent-driven-dev`
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use `uberdev:execute-plan`
- Batch execution with checkpoints for review
