---
name: verification-before-completion
description: Use when about to claim work is complete, fixed, or passing, before committing or creating PRs - requires running verification commands and confirming output before making any success claims; evidence before assertions always
---
<!-- Vendored from obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6 (MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt — the base this file was copied from and the SHA vendor.json records for the component. Measured against that blob (#503): the ENTIRE residual is one appended local section, 'Parallel Verification Dispatch', which applies UberDev's parallel-by-default policy to verification and keeps the Iron Law (fresh evidence in this message) binding on every parallel arm. Upstream's copy is therefore not drop-in, which is why the component is stance 'fork'. The file carries no 'superpowers:' token, so the namespace rebrand does not appear in it at all. Permanent local divergence: vendor.json permanent_divergences[].verification-parallel-dispatch. -->

# Verification Before Completion

## Overview

Claiming work is complete without verification is dishonesty, not efficiency.

**Core principle:** Evidence before claims, always.

**Violating the letter of this rule is violating the spirit of this rule.**

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command in this message, you cannot claim it passes.

## The Gate Function

```
BEFORE claiming any status or expressing satisfaction:

1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence
5. ONLY THEN: Make the claim

Skip any step = lying, not verifying
```

## Common Failures

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Tests pass | Test command output: 0 failures | Previous run, "should pass" |
| Linter clean | Linter output: 0 errors | Partial check, extrapolation |
| Build succeeds | Build command: exit 0 | Linter passing, logs look good |
| Bug fixed | Test original symptom: passes | Code changed, assumed fixed |
| Regression test works | Red-green cycle verified | Test passes once |
| Agent completed | VCS diff shows changes | Agent reports "success" |
| Requirements met | Line-by-line checklist | Tests passing |

## Red Flags - STOP

- Using "should", "probably", "seems to"
- Expressing satisfaction before verification ("Great!", "Perfect!", "Done!", etc.)
- About to commit/push/PR without verification
- Trusting agent success reports
- Relying on partial verification
- Thinking "just this once"
- Tired and wanting work over
- **ANY wording implying success without having run verification**

## Rationalization Prevention

| Excuse | Reality |
|--------|---------|
| "Should work now" | RUN the verification |
| "I'm confident" | Confidence ≠ evidence |
| "Just this once" | No exceptions |
| "Linter passed" | Linter ≠ compiler |
| "Agent said success" | Verify independently |
| "I'm tired" | Exhaustion ≠ excuse |
| "Partial check is enough" | Partial proves nothing |
| "Different words so rule doesn't apply" | Spirit over letter |

## Key Patterns

**Tests:**
```
✅ [Run test command] [See: 34/34 pass] "All tests pass"
❌ "Should pass now" / "Looks correct"
```

**Regression tests (TDD Red-Green):**
```
✅ Write → Run (pass) → Revert fix → Run (MUST FAIL) → Restore → Run (pass)
❌ "I've written a regression test" (without red-green verification)
```

**Build:**
```
✅ [Run build] [See: exit 0] "Build passes"
❌ "Linter passed" (linter doesn't check compilation)
```

**Requirements:**
```
✅ Re-read plan → Create checklist → Verify each → Report gaps or completion
❌ "Tests pass, phase complete"
```

**Agent delegation:**
```
✅ Agent reports success → Check VCS diff → Verify changes → Report actual state
❌ Trust agent report
```

## Why This Matters

From 24 failure memories:
- your human partner said "I don't believe you" - trust broken
- Undefined functions shipped - would crash
- Missing requirements shipped - incomplete features
- Time wasted on false completion → redirect → rework
- Violates: "Honesty is a core value. If you lie, you'll be replaced."

## When To Apply

**ALWAYS before:**
- ANY variation of success/completion claims
- ANY expression of satisfaction
- ANY positive statement about work state
- Committing, PR creation, task completion
- Moving to next task
- Delegating to agents

**Rule applies to:**
- Exact phrases
- Paraphrases and synonyms
- Implications of success
- ANY communication suggesting completion/correctness

## Parallel Verification Dispatch

When you have multiple **independent** verification dimensions to check (tests, lint, build, typecheck, smoke tests), they should run **in parallel**, not serially. Wall-time scales with the slowest check, not the sum.

**Two patterns, pick by tool budget:**

**Pattern A: parallel `Bash` calls in a single message** (lightest)

Run each verification command in a single message with multiple `Bash` tool_use blocks (use `run_in_background: true` if any one is long). Each call returns its own exit code + output. Aggregate manually. Best for 2-4 quick checks on the same machine.

**Pattern B: parallel `Task` subagent fanout** (when output is large)

Dispatch one `Task` agent per dimension in a single message. Each agent runs its check, reads the output, classifies pass/fail with evidence, and reports a concise verdict. Best when individual outputs are large (full test suite logs, type-checker spew) — keeps your main context lean.

**Required regardless of pattern:** every claim still needs **fresh evidence in this message**. The Iron Law applies to parallel verification just like serial — you cannot claim "tests pass" until you see the test command's exit code in the current turn.

**Example brief for Pattern B:**

```
Task(subagent_type=general-purpose,
     prompt="Run `pnpm test`. Report:
       - Exit code
       - Pass/fail counts (e.g., '34/34' or '32/34, 2 failures')
       - First 10 lines of any failure output
       - Final verdict: PASS or FAIL
     Do not interpret beyond what the command output shows.")
```

Aggregate reports → if any returned FAIL, fix that dimension before claiming completion.

## The Bottom Line

**No shortcuts for verification.**

Run the command. Read the output. THEN claim the result.

This is non-negotiable.
