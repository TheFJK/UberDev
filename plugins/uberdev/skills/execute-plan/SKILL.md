---
name: execute-plan
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---
<!-- Vendored from obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6 (MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt — the base this file (upstream skills/executing-plans/SKILL.md) was copied from and the SHA vendor.json records for the component. Measured against that blob (#503): the residual is the directory rename plus the namespace rebrand plus one behavioural rewrite — Step 2 now executes the plan's '## Execution Waves' summary in wave order with a full-test gate between waves, and the sub-skill handoffs point at uberdev:subagent-driven-dev and uberdev:finish-branch. That wave contract is the interlock uberdev:write-plan emits and uberdev:subagent-driven-dev consumes, so upstream's copy is not drop-in; the component is stance 'fork'. Permanent local divergence: vendor.json permanent_divergences[].plan-execution-wave-contract. -->

# Executing Plans

## Overview

Load plan, review critically, execute all tasks, report when complete.

**Announce at start:** "I'm using the execute-plan skill to implement this plan."

**Note:** Quality is significantly higher on platforms with subagent support (Claude Code, Codex). If subagents are available, prefer `uberdev:subagent-driven-dev` over this skill — fresh subagent per task with two-stage review catches more issues than single-session inline execution.

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed

### Step 2: Execute Tasks

The plan declares an `## Execution Waves` summary. Inline execution can't truly parallelize, but the wave order must still be honored: never start a task whose `Depends on:` list includes an unfinished task.

For each wave (in order):
  For each task in the wave (any order is fine — they're independent):
    1. Mark as in_progress
    2. Follow each step exactly (plan has bite-sized steps)
    3. Run verifications as specified
    4. Mark as completed
  After every task in the wave is complete, run the project's full test command before starting the next wave.

If you spot tasks that are clearly independent and your platform supports it, prefer `uberdev:subagent-driven-dev` — it will dispatch the wave's implementers in parallel and finish significantly faster.

**Apply TDD discipline within each task:** write a minimal failing test for the new behavior FIRST, run it to see it fail for the expected reason, write the simplest code that makes it pass, run again to see green, then refactor while green. Don't write production code without a failing test in front of it. (The plan's tasks should already encode this — these notes apply if a task is loose on TDD.)

### Step 3: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the finish-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use `uberdev:finish-branch`
- Follow that skill to verify tests, present 4 options (merge / PR / keep / discard), execute the chosen one, and clean up the worktree as appropriate.

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow setup (run before this skill):**
- **Isolated worktree** — `git worktree add .worktrees/<feature-name> -b <branch-name>` (verify `.worktrees/` is in `.gitignore`; add and commit if not). Run the project's setup command (`npm install` / `cargo build` / `pip install -r requirements.txt` / `go mod download`) and the project's test command to verify a clean baseline before implementing the plan.

**Related skills:**
- **`uberdev:write-plan`** — creates the plan this skill executes
- **`uberdev:subagent-driven-dev`** — preferred alternative when subagents are available (one fresh subagent per task with two-stage review)

**Finishing the development branch:** invoke `uberdev:finish-branch` (see Step 3 above).
