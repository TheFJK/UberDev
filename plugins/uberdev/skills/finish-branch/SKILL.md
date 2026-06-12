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

2. **Interactive mode** — if `--interactive` is in `$ARGUMENTS` (and `UBERDEV_TURBO` is not `1` — turbo wins per precedence above):
   Present the legacy 4-option menu below. If the user picks Option 2, chain into `/uberdev:review-pr` (no `--turbo`). Other options behave as today.

   ```
   Implementation complete. What would you like to do?

   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is (I'll handle it later)
   4. Discard this work

   Which option?
   ```

   > **Caveat — Options 1, 3, 4 bypass post-impl review.** Options 1 (Merge back to base locally), 3 (Keep the branch as-is), and 4 (Discard this work) skip `gh pr create` entirely, and therefore skip the chain into `/uberdev:review-pr` whose Phase 1 hosts the 6-reviewer post-impl-review fanout. `plugins/uberdev/skills/post-impl-review/SKILL.md` is the authoritative owner of the reviewer-fanout facts (agent roster, count, dispatch shape — per its "When to invoke", `/uberdev:review-pr` Phase 1 is the sole live caller); this skill owns only the chain mode-signal. Users who pick Options 1, 3, or 4 explicitly opt out of automated post-impl review for that branch. Only Option 2 (Push and create a Pull Request) preserves the chain. The default mode (always-PR, no flags) and Turbo mode (`UBERDEV_TURBO=1`) both auto-select Option 2 — neither is affected by this bypass.

   **Don't add explanation** — keep options concise.

3. **Default mode** — neither `UBERDEV_TURBO=1` nor `--interactive` set (the always-PR path):
   Auto-select **Option 2 (Push and create a Pull Request)** and chain into `/uberdev:review-pr` (no `--turbo` forwarded). Announce:

   > "Implementation complete. Pushing branch and creating PR. Chaining into /uberdev:review-pr…"

   Proceed to Step 4 → Option 2.

**Conflict resolution:** if `--interactive` is in `$ARGUMENTS` AND `UBERDEV_TURBO=1` is also set, env var wins (turbo's contract is unattended end-to-end; interactive prompts are mutually exclusive). The `UBERDEV_TURBO` env var is the canonical signal on the chain hot path; finish-branch no longer accepts a `--turbo` argument (#97 — env-var-only since the orchestrator → SDD → finish-branch chain is fully internal). This Step 3 is the authoritative owner of the chain mode-signal contract — upstream docs (orchestrator Phase 6, SDD Step 5) defer to it and must not restate flag-forwarding behaviour.

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

- **`## Open questions answered by /turbo`** — table rendered from the active-run `questions.md` (written by orchestrator Phase 2 under `--turbo`; run identity resolved via the per-worktree `active-run-id` sidecar below, written by orchestrator Phase 0). Columns: Question | Choice | Confidence. Reviewers can scan for `medium`/`low` confidence rows quickly.
- **`## Reviewer findings summary`** — the post-impl-review aggregate (`post-impl-review-final.md`, written by `uberdev:post-impl-review` from `/uberdev:review-pr` Phase 1 after PR push) and any `pr-test-analyzer` output (large tier only, written by SDD Step 4.5 before this handoff). The read-site glob below (`post-impl-review-*.md`) matches both the new `-final.md` filename and any legacy `-wave-final.md` artifacts left over from pre-refactor runs (zero-migration).

Both sections are read-only dumps; finish-branch does not block on confidence threshold or reviewer verdict (per #11 Q1: advisory only, auto-fix deferred).

```bash
# Resolve run identity for the orchestrator artifact reads below. Environment
# exports do NOT survive the claude-bg / Skill process boundary, so the
# cross-process contract is the per-worktree sidecar written by orchestrator
# Phase 0 — never a RUN_ID export. An in-process RUN_ID (same-agent chain) is
# honoured first when it names a real run dir.
# RUN_ID_FORMAT mirrors the orchestrator Phase 0 mint:
# date +%Y%m%d-%H%M%S, then a hyphen, then short-SHA or the literal nohead.
RUN_ID_FORMAT='^[0-9]{8}-[0-9]{6}-[0-9a-z]{4,40}$'
RESEARCH_ROOT="$(git rev-parse --show-toplevel)/.uberdev/research"
ACTIVE_RUN_ID=""
if [ -n "${RUN_ID:-}" ] && [[ "${RUN_ID}" =~ $RUN_ID_FORMAT ]] && [ -d "$RESEARCH_ROOT/${RUN_ID}" ]; then
  ACTIVE_RUN_ID="${RUN_ID}"
elif [ -f "$RESEARCH_ROOT/active-run-id" ]; then
  SIDECAR_ID="$(head -1 "$RESEARCH_ROOT/active-run-id" 2>/dev/null | tr -d '[:space:]')"
  # Validate BEFORE any path concatenation: the sidecar is a worktree-writable
  # file, so reject anything that does not match the run-id mint (this also
  # excludes path metacharacters and traversal bytes by construction).
  if [[ "$SIDECAR_ID" =~ $RUN_ID_FORMAT ]] && [ -d "$RESEARCH_ROOT/$SIDECAR_ID" ]; then
    ACTIVE_RUN_ID="$SIDECAR_ID"
  fi
fi
# There is deliberately NO newest-across-runs fallback here (the old
# ls -t over .uberdev/research/*/questions.md): mtime ordering can
# cross-attach a stale or concurrent run artifact into the wrong PR body
# (#308). When run identity does not resolve, the optional sections below
# are silently omitted — omission beats misattribution.

QUESTIONS_FILE=""
if [ -n "$ACTIVE_RUN_ID" ] && [ -f "$RESEARCH_ROOT/$ACTIVE_RUN_ID/questions.md" ]; then
  QUESTIONS_FILE="$RESEARCH_ROOT/$ACTIVE_RUN_ID/questions.md"
fi

# Read the post-impl-review aggregate (and pr-test-analyzer if present) for
# the Reviewer findings summary section — scoped to the active run dir when
# identity resolved; the wildcard branch covers manual invocations that have
# no orchestrator run. The legacy .uberdev/research/issue-N glob component
# was DELETED together with the orchestrator research cache (#308: the
# issue-N cache had zero writers, so the glob could only ever match nothing).
#
# REVIEW_FILES stays NEWLINE-delimited (raw `ls -t` output, no `tr '\n' ' '`
# join) so the consumer below can iterate it with a while-read loop. This
# fence runs under /bin/zsh on macOS (the Claude-Code Bash tool default), where
# SH_WORD_SPLIT is OFF: a space-joined scalar fed to a for-loop over the list
# would NOT word-split — $f would bind to the whole list as one token, the
# `[ -f "$f" ]` guard would fail, and the entire section (including the envelope
# strip) would be silently skipped. Newline-delimited + read-loop is word-split-
# independent and behaves identically under bash and zsh.
if [ -n "$ACTIVE_RUN_ID" ]; then
  REVIEW_FILES=$(ls -t "$RESEARCH_ROOT/$ACTIVE_RUN_ID"/post-impl-review-*.md "$RESEARCH_ROOT/$ACTIVE_RUN_ID"/pr-test-analyzer.md 2>/dev/null)
else
  REVIEW_FILES=$(ls -t .uberdev/research/*/post-impl-review-*.md .uberdev/research/*/pr-test-analyzer.md 2>/dev/null)
fi

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
    awk -v c0=0 '/^## Q[0-9]+:/{q=$c0; sub(/^## Q[0-9]+: */, "", q)} /^\*\*Auto-pick:\*\*/{a=$c0; sub(/^\*\*Auto-pick:\*\* */, "", a)} /^\*\*Confidence:\*\*/{c=$c0; sub(/^\*\*Confidence:\*\* */, "", c); print "| " q " | " a " | " c " |"}' "$QUESTIONS_FILE" | (echo "| Question | Choice | Confidence |"; echo "|----------|--------|------------|"; cat)
  } >> "$PR_BODY_FILE"
fi

if [ -n "$REVIEW_FILES" ]; then
  {
    echo
    echo "## Reviewer findings summary"
    echo
    # Iterate the NEWLINE-delimited REVIEW_FILES with a while-read loop, NOT a
    # for-loop over $REVIEW_FILES — under zsh (the Bash-tool default on macOS,
    # and this is a raw bash code fence with no bash shebang) an unquoted scalar
    # does not word-split (SH_WORD_SPLIT off), so the for-loop would bind $f to
    # the entire list as one token, the `[ -f "$f" ]` guard would fail, and this
    # whole section — including the envelope strip below — would be silently
    # skipped. The read-loop is word-split-independent (identical under bash/zsh).
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      echo "### $(basename "$f")"
      # Strip external-untrusted-input envelope tag lines before pasting into
      # the PR body: aggregate files carry the tags as file bytes once the
      # #302 writer-side change lands (harmless no-op on files without them).
      # Only PURE tag lines are dropped — finding text that merely mentions
      # the tag inline survives. GitHub renders raw tags as noise; every LLM
      # consumer re-wraps PR bodies at its own read site, so no validator is
      # weakened by stripping here.
      sed -E -e '/^[[:space:]]*<external-untrusted-input[^>]*>[[:space:]]*$/d' \
             -e '/^[[:space:]]*<\/external-untrusted-input>[[:space:]]*$/d' "$f"
      echo
    done <<< "$REVIEW_FILES"
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
# investigation. The library signals leaks via non-zero exit code (matched
# content streams to stderr for diagnostic capture). Callers MUST check the
# exit code, NOT the captured stdout, because the library writes nothing to
# stdout on either path.
# Layered secret scan (gitleaks + regex fallback): sourced from shared library.
# Source-time idempotency guard prevents double-load if any caller already sourced.
source "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"

# Helper: scan stdin; abort if the library returns non-zero. Cleans up tmp files
# and preserves worktree. Captures stderr into $SCAN_DIAG so the abort message
# names the offending pattern.
abort_if_secret() {
  local label="$1"
  local scan_diag="$2"
  local scan_rc="$3"
  [[ "$scan_rc" -eq 0 ]] && return 0
  echo "ERROR: secret found in $label (rc=$scan_rc): $scan_diag" >&2
  echo "Push aborted. Worktree preserved. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
}

# Scan target 1: the diff that will actually be pushed (commits ahead of upstream).
# Falls back to staged diff for fresh branches that have no remote tracking yet.
# Capture stderr (matched lines) into $SCAN_DIAG and the function exit code
# into $SCAN_RC for the abort_if_secret check.
if PUSH_DIFF=$(git diff @{u}..HEAD 2>/dev/null) && [[ -n "$PUSH_DIFF" ]]; then
  SCAN_DIAG=$(printf '%s' "$PUSH_DIFF" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
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
    SCAN_DIAG=$(git diff "$BASE_REF..HEAD" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
  else
    SCAN_DIAG=$(git diff --staged | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
  fi
fi
abort_if_secret "to-be-pushed diff" "$SCAN_DIAG" "$SCAN_RC"

# Scan target 2: composed PR body file
SCAN_DIAG=$(uberdev_run_secret_scan_stdin < "$PR_BODY_FILE" 2>&1 >/dev/null); SCAN_RC=$?
abort_if_secret "composed PR body" "$SCAN_DIAG" "$SCAN_RC"

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
# Extract the PR number from PR_URL by stripping everything up to the final
# slash. PR_URL already passed PR_URL_REGEX immediately above (it ends in
# /pull/ then digits), so ${PR_URL##*/} yields exactly those digits with no
# further parse. This deliberately AVOIDS a capture-group [[ =~ ]] match
# (#270): finish-branch SKILL.md bash fences run under /bin/zsh on macOS, where
# the capture lands in the match array, not BASH_REMATCH; the bash-only form left
# PR_NUM empty, so gh pr edit with an empty arg failed (swallowed by the
# fail-soft guard) and the #95 review-pr:pending backstop label was never set on
# any PR created via finish-branch on macOS, defeating the /merge label-present
# probe. Both gh calls remain fail-soft per the fire-and-surface contract (issue
# #11 Q1): a transient gh failure loud-logs to stderr but MUST NOT exit non-zero
# or roll back the PR.
PR_NUM="${PR_URL##*/}"
if ! gh label create --force review-pr:pending \
     --color FBCA04 \
     --description "review-pr has not yet completed for this PR" 2>/dev/null; then
  echo "warning: failed to create review-pr:pending label; backstop may not fire" >&2
fi
if ! gh pr edit "$PR_NUM" --add-label review-pr:pending 2>/dev/null; then
  echo "warning: failed to add review-pr:pending label to PR #$PR_NUM; backstop will not fire if review-pr is missed" >&2
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
