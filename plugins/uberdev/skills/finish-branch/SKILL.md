---
name: finish-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the finish-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run project's test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 3: Present Options

**Turbo mode (when `--turbo` is in `$ARGUMENTS`):**

If invoked with `--turbo` (typically forwarded from `uberdev:subagent-driven-dev` via `/turbo`), **skip the prompt** and auto-select **Option 2 (Push and create a Pull Request)**. Announce the choice, then proceed straight to Step 4 → Option 2.

> "Implementation complete. Turbo mode — auto-selecting Option 2 (Push and create PR)."

**Default mode:**

Present exactly these 4 options:

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 4: Execute Choice

#### Option 1: Merge Locally

```bash
# Switch to base branch
git checkout <base-branch>

# Pull latest
git pull

# Merge feature branch
git merge <feature-branch>

# Verify tests on merged result
<test command>

# If tests pass
git branch -d <feature-branch>
```

Then: Cleanup worktree (Step 5)

#### Option 2: Push and Create PR

Option 2 PR-body composition: in addition to the standard Summary + Test Plan, two conditional sections are appended when their source artifacts exist:

- **`## Open questions answered by /turbo`** — table rendered from `.uberdev/research/$RUN_ID/questions.md` (written by orchestrator Phase 2 under `--turbo`). Columns: Question | Choice | Confidence. Reviewers can scan for `medium`/`low` confidence rows quickly.
- **`## Reviewer findings summary`** — concatenated post-impl-review aggregates (per-wave, written by `uberdev:post-impl-review` from `subagent-driven-dev`) and any `pr-test-analyzer` output (large tier only).

Both sections are read-only dumps; finish-branch does not block on confidence threshold or reviewer verdict (per #11 Q1: advisory only, auto-fix deferred).

```bash
# Read the orchestrator's questions.md (--turbo non-blocking Q&A log) if present.
# Note: the file lives under the orchestrator's $RUN_ID working dir, NOT issue-$N.
QUESTIONS_FILE=""
if [ -n "${RUN_ID:-}" ] && [ -f ".uberdev/research/$RUN_ID/questions.md" ]; then
  QUESTIONS_FILE=".uberdev/research/$RUN_ID/questions.md"
else
  # Fallback: pick the most recent .uberdev/research/*/questions.md for cases
  # where $RUN_ID was not exported across processes. (Glob expansion does NOT
  # happen inside `[ -f ... ]`, so we use ls and a non-empty check instead.)
  CANDIDATE=$(ls -t .uberdev/research/*/questions.md 2>/dev/null | head -1)
  if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ]; then
    QUESTIONS_FILE="$CANDIDATE"
  fi
fi

# Read the post-impl-review aggregate (and pr-test-analyzer if present) for
# the Reviewer findings summary section.
REVIEW_FILES=$(ls -t .uberdev/research/*/post-impl-review-wave-*.md .uberdev/research/issue-*/post-impl-review.md .uberdev/research/*/pr-test-analyzer.md 2>/dev/null | tr '\n' ' ')

# Compose PR body
PR_BODY_FILE=$(mktemp)
cat > "$PR_BODY_FILE" <<'EOF_HEADER'
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF_HEADER

if [ -n "$QUESTIONS_FILE" ] && [ -f "$QUESTIONS_FILE" ]; then
  {
    echo
    echo "## Open questions answered by /turbo"
    echo
    echo "The following questions were answered automatically — please review:"
    echo
    # Extract questions and auto-picks; render as a markdown table.
    awk '/^## Q[0-9]+:/{q=$0; sub(/^## Q[0-9]+: */, "", q)} /^\*\*Auto-pick:\*\*/{a=$0; sub(/^\*\*Auto-pick:\*\* */, "", a)} /^\*\*Confidence:\*\*/{c=$0; sub(/^\*\*Confidence:\*\* */, "", c); print "| " q " | " a " | " c " |"}' "$QUESTIONS_FILE" | (echo "| Question | Choice | Confidence |"; echo "|----------|--------|------------|"; cat)
  } >> "$PR_BODY_FILE"
fi

if [ -n "$REVIEW_FILES" ]; then
  {
    echo
    echo "## Reviewer findings summary"
    echo
    for f in $REVIEW_FILES; do
      [ -f "$f" ] || continue
      echo "### $(basename "$f")"
      cat "$f"
      echo
    done
  } >> "$PR_BODY_FILE"
fi

# Push and create PR
git push -u origin <feature-branch>
gh pr create --title "<title>" --body-file "$PR_BODY_FILE"
rm -f "$PR_BODY_FILE"
```

Then: Cleanup worktree (Step 5)

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
git checkout <base-branch>
git branch -D <feature-branch>
```

Then: Cleanup worktree (Step 5)

### Step 5: Cleanup Worktree

**For Options 1 and 4:**

Check if in worktree:
```bash
git worktree list | grep $(git branch --show-current)
```

If yes:
```bash
git worktree remove <worktree-path>
```

**For Options 2 and 3:** Keep worktree. Option 2 leaves the branch alive for PR-feedback fixups; Option 3 is explicit "keep as-is". The Quick Reference table and Red Flags below codify this.

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch |
|--------|-------|------|---------------|----------------|
| 1. Merge locally | ✓ | - | - | ✓ |
| 2. Create PR | - | ✓ | ✓ | - |
| 3. Keep as-is | - | - | ✓ | - |
| 4. Discard | - | - | - | ✓ (force) |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" → ambiguous
- **Fix:** Present exactly 4 structured options

**Automatic worktree cleanup**
- **Problem:** Remove worktree when might need it (Option 2, 3)
- **Fix:** Only cleanup for Options 1 and 4

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only

## Integration

**Called by:**
- **`uberdev:subagent-driven-dev`** — after all tasks complete and final review approves
- **`uberdev:execute-plan`** — after all batches complete and verification passes

**Pairs with:**
- The worktree-setup prose inlined in `uberdev:execute-plan` and `uberdev:subagent-driven-dev` — this skill cleans up the worktree those skills created.
