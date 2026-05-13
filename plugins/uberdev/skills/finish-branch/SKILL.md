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
# Run the project test suite
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

### Step 3: Mode selection (precedence: UBERDEV_TURBO=1 > --interactive > default)

Detect mode from the inherited environment variable `UBERDEV_TURBO` (set by `commands/turbo.md` → `solve-pipeline` → `claude --bg` inline-prefix exec, per #97) AND from `$ARGUMENTS` (for the `--interactive` flag only — finish-branch no longer parses `--turbo` as an argument; turbo signal is env-var-only on the chain hot path):

1. **Turbo mode** — if `[[ "${UBERDEV_TURBO:-0}" == "1" ]]`:
   Skip the prompt, auto-select **Option 2 (Push and create a Pull Request)**, and chain into `/uberdev:review-pr` (no `--turbo` arg — review-pr inherits the env var via Skill() invocation in the same agent process). Announce:

   > "Implementation complete. Turbo mode (UBERDEV_TURBO=1) — auto-selecting Option 2 (Push and create PR). Chaining into /uberdev:review-pr."

   Proceed to Step 4 → Option 2.

2. **Interactive mode** — if `--interactive` is in `$ARGUMENTS` AND `[[ "${UBERDEV_TURBO:-0}" != "1" ]]`:
   Present the legacy 4-option menu below. If the user picks Option 2, chain into `/uberdev:review-pr` (no `--turbo`). Other options behave as today.

   ```
   Implementation complete. What would you like to do?

   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is (I'll handle it later)
   4. Discard this work

   Which option?
   ```

   > **Caveat — Options 1, 3, 4 bypass post-impl review.** Options 1 (Merge back to base locally), 3 (Keep the branch as-is), and 4 (Discard this work) skip `gh pr create` entirely, and therefore skip the chain into `/uberdev:review-pr` whose Phase 1 hosts the 5-reviewer post-impl-review fanout (per `plugins/uberdev/skills/post-impl-review/SKILL.md` "When to invoke" — `/uberdev:review-pr` Phase 1 is the sole live caller). Users who pick Options 1, 3, or 4 explicitly opt out of automated post-impl review for that branch. Only Option 2 (Push and create a Pull Request) preserves the chain. The default mode (always-PR, no flags) and Turbo mode (`UBERDEV_TURBO=1`) both auto-select Option 2 — neither is affected by this bypass.

   **Don't add explanation** — keep options concise.

3. **Default mode** — neither `UBERDEV_TURBO=1` nor `--interactive` set (the always-PR path):
   Auto-select **Option 2 (Push and create a Pull Request)** and chain into `/uberdev:review-pr` (no `--turbo` forwarded). Announce:

   > "Implementation complete. Pushing branch and creating PR. Chaining into /uberdev:review-pr…"

   Proceed to Step 4 → Option 2.

**Conflict resolution:** if both `--interactive` is in `$ARGUMENTS` AND `UBERDEV_TURBO=1` is set, env var wins (turbo's contract is unattended end-to-end; interactive prompts are mutually exclusive). The `UBERDEV_TURBO` env var is the canonical signal on the chain hot path; finish-branch no longer accepts a `--turbo` argument (#97 — env-var-only since the orchestrator → SDD → finish-branch chain is fully internal).

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
- **`## Reviewer findings summary`** — the post-impl-review aggregate (`post-impl-review-final.md`, written by `uberdev:post-impl-review` from `/uberdev:review-pr` Phase 1 after PR push) and any `pr-test-analyzer` output (large tier only). The read-site glob below (`post-impl-review-*.md`) matches both the new `-final.md` filename and any legacy `-wave-final.md` artifacts left over from pre-refactor runs (zero-migration).

Both sections are read-only dumps; finish-branch does not block on confidence threshold or reviewer verdict (per #11 Q1: advisory only, auto-fix deferred).

```bash
# Read the orchestrator questions.md (--turbo non-blocking Q&A log) if present.
# Note: the file lives under the orchestrator $RUN_ID working dir, NOT issue-$N.
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
REVIEW_FILES=$(ls -t .uberdev/research/*/post-impl-review-*.md .uberdev/research/issue-*/post-impl-review.md .uberdev/research/*/pr-test-analyzer.md 2>/dev/null | tr '\n' ' ')

# Compose PR body. Heredoc delimiter is unquoted (`<<EOF`, not the single-
# quoted form) to avoid the Claude permission-pattern evaluator `unmatched '`
# bug (#42). The agent must compose the body free of `$`, backticks, and
# backslash — unquoted heredocs do not shield these from shell expansion.
PR_BODY_FILE=$(mktemp)
cat > "$PR_BODY_FILE" <<EOF_HEADER
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

# Compose PR title via heredoc + read-back into a bash variable, then pass to
# `gh --title "$PR_TITLE_VAR"` — double-quoted variable expansion is byte-
# verbatim, no backtick/dollar re-evaluation. The heredoc delimiter is
# unquoted (`<<PR_TITLE_EOF`, not the single-quoted form) to avoid the Claude
# permission-pattern evaluator `unmatched '` bug (#42); the agent must
# compose the title free of `$`, backticks, and backslash. This closes the
# title-injection vector without inventing a `--title-file` flag (which gh
# does not support).
TITLE_FILE=$(mktemp) || { echo "ERROR: mktemp failed for title file" >&2; exit 1; }
cat > "$TITLE_FILE" <<PR_TITLE_EOF
<title>
PR_TITLE_EOF

# Read title back into a quoted variable — bytes pass through verbatim, no shell
# expansion. `IFS= read -r` reads the first line only; if the title file ever
# contains multiple lines (should not, per the heredoc above), subsequent lines
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
  # the captured output so the caller error message has detail.
  if command -v gitleaks >/dev/null 2>&1; then
    local out rc
    out=$(gitleaks stdin --no-banner --redact 2>&1) ; rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0  # clean — no output, caller continues
    fi
    # Non-zero: leak found OR gitleaks crashed (fail-CLOSED on either).
    # Emit captured output so the caller ERROR message names the offending rule.
    printf '%s\n' "$out"
    return 0  # signal via output, not exit code (caller checks [[ -n $SCAN_OUT ]])
  fi
  # Fallback: inline regex floor — high-true-positive patterns only.
  grep -E -o '(AKIA[0-9A-Z]{16}|gh[ps]_[A-Za-z0-9]{36,255}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' || true
}

# Emit gitleaks-missing warning ONCE in the parent shell (subshell exports do not
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
  # No upstream set or empty diff → scan from origin default branch. Falls
  # back to literal main/master, then to the branch root commit (catches
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
# errors. The negated-conditional branch below surfaces the gh failure
# explicitly (PR_URL captures stderr via 2>&1 in the failure case to keep
# the diagnostic).
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
# Extract PR number from PR_URL using a capture-group variant of PR_URL_REGEX
# (the existing constant at line 289 has no capture group; this inline form
# allows single-pass extraction via BASH_REMATCH). Both gh calls are fail-soft
# per the fire-and-surface contract (issue #11 Q1): a transient gh failure
# loud-logs to stderr but MUST NOT exit non-zero or roll back the PR.
if [[ "$PR_URL" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)$ ]]; then
  PR_NUM="${BASH_REMATCH[1]}"
  if ! gh label create --force review-pr:pending \
       --color FBCA04 \
       --description "review-pr has not yet completed for this PR" 2>/dev/null; then
    echo "warning: failed to create review-pr:pending label; backstop may not fire" >&2
  fi
  if ! gh pr edit "$PR_NUM" --add-label review-pr:pending 2>/dev/null; then
    echo "warning: failed to add review-pr:pending label to PR #$PR_NUM; backstop will not fire if review-pr is missed" >&2
  fi
fi
rm -f "$TITLE_FILE" "$PR_BODY_FILE"
```

The two `gh` calls above are intentionally fail-soft — the fire-and-surface contract trumps backstop completeness, so a transient `gh` failure must not roll back PR creation. The literal label string `review-pr:pending` is declared as `REVIEW_PR_PENDING_LABEL` in `plugins/uberdev/skills/merge-pipeline/SKILL.md` Constants table; it is inlined here (mirroring how `UBERDEV_APPROVED_LABEL` is inlined in `commands/review-pr.md`) because bash does not dereference markdown constants — the literal string is the only available form in this position.

**Chain hand-off (always-PR path, default + turbo):**

After the PR is created and `PR_URL` is validated, **invoke `uberdev:review-pr` via the `Skill` tool** with the captured `PR_URL` (no `--turbo` arg). Review-pr inherits the unattended-mode signal via the `UBERDEV_TURBO=1` env var inherited from the parent `claude --bg` process; review-pr also retains a hybrid arg-OR-env detector for compatibility with the separate dispatch in `merge-pipeline` (which still passes `--turbo` as an arg — out-of-scope for #97). The chain is **fire-and-surface, not fire-and-block**: review-pr findings surface to the user via its own output, but `finish-branch` does NOT block on `REVISIONS_REQUIRED` (advisory only, per #11 Q1).

> Invoke `uberdev:review-pr` via the Skill tool with the captured `PR_URL` (no flag args). Findings are ADVISORY — do NOT block on `REVISIONS_REQUIRED` at this layer (the auto-fix loop is deferred per #11 Q1).

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

| Option | Merge | Push | Keep Worktree | Cleanup Branch | Post-impl review |
|--------|-------|------|---------------|----------------|------------------|
| 1. Merge locally | ✓ | - | - | ✓ | bypassed (no PR) |
| 2. Create PR | - | ✓ | ✓ | - | runs (via /review-pr Phase 1) |
| 3. Keep as-is | - | - | ✓ | - | bypassed (no PR) |
| 4. Discard | - | - | - | ✓ (force) | bypassed (no PR) |

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
- **`uberdev:review-pr`** — invoked via the `Skill` tool after PR creation on the always-PR path (default mode + Turbo mode under `UBERDEV_TURBO=1`). Mirrors `subagent-driven-dev → post-impl-review` (commit `73b2562`). Advisory only — `finish-branch` does not block on reviewer verdict.
