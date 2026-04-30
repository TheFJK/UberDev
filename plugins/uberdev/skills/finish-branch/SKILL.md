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

### Step 3: Mode selection (precedence: --turbo > --interactive > default)

Detect flags from `$ARGUMENTS`:

1. **Turbo mode** — if `--turbo` is in `$ARGUMENTS`:
   Skip the prompt, auto-select **Option 2 (Push and create a Pull Request)**, and chain into `/uberdev:review-pr` (forwarding `--turbo`). Announce:

   > "Implementation complete. Turbo mode — auto-selecting Option 2 (Push and create PR). Chaining into /uberdev:review-pr (--turbo)."

   Proceed to Step 4 → Option 2.

2. **Interactive mode** — if `--interactive` is in `$ARGUMENTS` (and `--turbo` is NOT):
   Present the legacy 4-option menu below. If the user picks Option 2, chain into `/uberdev:review-pr` (no `--turbo`). Other options behave as today.

   ```
   Implementation complete. What would you like to do?

   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is (I'll handle it later)
   4. Discard this work

   Which option?
   ```

   **Don't add explanation** — keep options concise.

3. **Default mode** — neither flag set (the always-PR path):
   Auto-select **Option 2 (Push and create a Pull Request)** and chain into `/uberdev:review-pr` (no `--turbo` forwarded). Announce:

   > "Implementation complete. Pushing branch and creating PR. Chaining into /uberdev:review-pr…"

   Proceed to Step 4 → Option 2.

**Conflict resolution:** if both `--turbo` and `--interactive` are present, `--turbo` wins (turbo's contract is unattended end-to-end; interactive prompts are mutually exclusive).

**Discoverability:** the `--interactive` flag restores the legacy 4-option menu (Merge back to base / Push and create a Pull Request / Keep the branch as-is / Discard) for users who want it. The default is now always-PR; this fulfills the `~/.claude/CLAUDE.md` mandate "MANDATORY: run `/uberdev:review-pr` after pushing the PR. No exceptions, hotfixes included."

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

# Compose PR title via heredoc + read-back, NOT --title (which would shell-interpret
# any backticks / $() in the agent-composed title text). The heredoc with a
# single-quoted EOF marker prevents shell expansion of the title content; the
# subsequent read-back into a quoted bash variable preserves the bytes verbatim
# when passed to `gh --title`. This closes the title-injection vector without
# inventing a `--title-file` flag (which gh does not support).
TITLE_FILE=$(mktemp) || { echo "ERROR: mktemp failed for title file" >&2; exit 1; }
cat > "$TITLE_FILE" <<'PR_TITLE_EOF'
<title>
PR_TITLE_EOF

# Read title back into a quoted variable — bytes pass through verbatim, no shell
# expansion. `IFS= read -r` reads the first line only; if the title file ever
# contains multiple lines (shouldn't, per the heredoc above), subsequent lines
# are silently dropped. Empty-title rejection happens implicitly via the
# downstream `gh pr create` failure path.
IFS= read -r PR_TITLE_VAR < "$TITLE_FILE" || { echo "ERROR: failed to read title file" >&2; rm -f "$TITLE_FILE" "$PR_BODY_FILE"; exit 1; }

# Pre-push secret scan: layered defense (gitleaks primary + regex fallback)
# over BOTH the to-be-pushed commit range AND the composed PR-body file. Either
# hit aborts the push BEFORE any text reaches GitHub. Worktree is preserved for
# investigation. The scan helper signals via output (non-empty = leak found)
# rather than exit code so callers compose with `[[ -n $SCAN_OUT ]]`.
run_secret_scan_stdin() {
  # Primary: gitleaks (when installed). gitleaks exits 0 if no leaks found,
  # non-zero (default 1) if leaks found via --exit-code, or >1 on actual
  # errors. We use the exit code as the authoritative signal — output-text
  # filtering is unreliable because info messages like "no leaks found"
  # would false-positive a substring match. On non-zero exit, we surface
  # the captured output so the caller's error message has detail.
  if command -v gitleaks >/dev/null 2>&1; then
    local out rc
    out=$(gitleaks stdin --no-banner --redact 2>&1) ; rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0  # clean — no output, caller continues
    fi
    # Non-zero: leak found OR gitleaks crashed (fail-CLOSED on either).
    # Emit captured output so caller's ERROR message names the offending rule.
    printf '%s\n' "$out"
    return 0  # signal via output, not exit code (caller checks [[ -n $SCAN_OUT ]])
  fi
  # Fallback: inline regex floor — high-true-positive patterns only.
  grep -E -o '(AKIA[0-9A-Z]{16}|gh[ps]_[A-Za-z0-9]{36,255}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' || true
}

# Emit gitleaks-missing warning ONCE in the parent shell (subshell exports don't
# propagate, so the warning must live outside run_secret_scan_stdin to avoid
# printing twice).
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "WARNING: gitleaks not installed — using regex fallback only. Recommend: brew install gitleaks" >&2
fi

# Helper: abort if scan output is non-empty. Cleans up tmp files and preserves worktree.
abort_if_secret() {
  local label="$1" hit="$2"
  [[ -n "$hit" ]] || return 0
  echo "ERROR: secret found in $label: $hit" >&2
  echo "Push aborted. Worktree preserved. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
}

# Scan target 1: the diff that will actually be pushed (commits ahead of upstream).
# Falls back to staged diff for fresh branches that have no remote tracking yet.
if PUSH_DIFF=$(git diff @{u}..HEAD 2>/dev/null) && [[ -n "$PUSH_DIFF" ]]; then
  SCAN_OUT=$(printf '%s' "$PUSH_DIFF" | run_secret_scan_stdin)
else
  # No upstream set or empty diff → scan from origin's default branch. Falls
  # back to literal main/master, then to the branch's root commit (catches
  # everything since branch creation). Note: `git merge-base HEAD HEAD~1` is
  # degenerate (= HEAD~1) and was removed — it scanned only the last commit.
  BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@' \
          || git rev-parse --verify origin/main 2>/dev/null \
          || git rev-parse --verify origin/master 2>/dev/null \
          || git rev-list --max-parents=0 HEAD 2>/dev/null \
          || echo "")
  if [[ -n "$BASE_REF" ]]; then
    SCAN_OUT=$(git diff "$BASE_REF..HEAD" | run_secret_scan_stdin)
  else
    SCAN_OUT=$(git diff --staged | run_secret_scan_stdin)
  fi
fi
abort_if_secret "to-be-pushed diff" "$SCAN_OUT"

# Scan target 2: composed PR body file
SCAN_OUT=$(run_secret_scan_stdin < "$PR_BODY_FILE")
abort_if_secret "composed PR body" "$SCAN_OUT"

# Both scans clean → push and create PR. Each step is exit-code-checked so a
# failure surfaces explicitly (rather than silently proceeding to the next step).
if ! git push -u origin <feature-branch>; then
  echo "ERROR: git push failed. Branch state preserved. Worktree retained. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi

# Capture PR URL from gh stdout AND its exit code together. gh returns the
# created PR URL on stdout when successful; non-zero exit on auth/network/quota
# errors. The `if !` branch surfaces gh's failure explicitly (PR_URL captures
# stderr via 2>&1 in the failure case to keep the diagnostic).
if ! PR_URL=$(gh pr create --title "$PR_TITLE_VAR" --body-file "$PR_BODY_FILE" 2>&1); then
  echo "ERROR: gh pr create failed: $PR_URL" >&2
  echo "Branch state preserved. Worktree retained. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi
PR_URL_REGEX='^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$'
if [[ ! "$PR_URL" =~ $PR_URL_REGEX ]]; then
  echo "ERROR: gh pr create returned non-parseable URL: $PR_URL" >&2
  echo "Branch state preserved. Worktree retained. Do NOT chain into review-pr. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi
echo "PR created: $PR_URL"
rm -f "$TITLE_FILE" "$PR_BODY_FILE"
```

**Chain hand-off (always-PR path, default + turbo):**

After the PR is created and `PR_URL` is validated, **invoke `uberdev:review-pr` via the `Skill` tool** with the captured `PR_URL`. Forward `--turbo` if it was in `$ARGUMENTS`. The chain is **fire-and-surface, not fire-and-block**: review-pr's findings surface to the user via its own output, but `finish-branch` does NOT block on `REVISIONS_REQUIRED` (advisory only, per #11 Q1).

> Invoke `uberdev:review-pr` via the Skill tool with the captured `PR_URL`. Forward `--turbo` if present. Findings are ADVISORY — do NOT block on `REVISIONS_REQUIRED` at this layer (the auto-fix loop is deferred per #11 Q1).

Mirrors the canonical `subagent-driven-dev → post-impl-review` precedent (commit `73b2562`). `commands/review-pr.md` has no `disable-model-invocation` flag, so the `Skill` tool can invoke the slash command directly without promotion.

A review-pr failure (e.g., reviewer agent crash, `gh pr view` error) is loud-logged but does NOT roll back the PR or branch state. `finish-branch` returns success once the PR is open and the chain has been kicked off.

Use the `Skill` tool for this dispatch — never the agent-spawning tool.

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
- **`uberdev:merge`** — follows Option 2. `finish-branch` opens the PR; `/merge` lands it. Together they form the lifecycle `/issue → /solve → push → /review-pr → /merge`.

**Chains into:**
- **`uberdev:review-pr`** — invoked via the `Skill` tool after PR creation on the always-PR path (default mode + `--turbo`). Mirrors `subagent-driven-dev → post-impl-review` (commit `73b2562`). Advisory only — `finish-branch` does not block on reviewer verdict.
