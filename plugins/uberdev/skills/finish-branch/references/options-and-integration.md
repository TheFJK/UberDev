# Finish-branch — option matrix, mistakes, red flags, and integration

Reference for `skills/finish-branch/SKILL.md`. What each of the four options does to the merge, the push, the worktree, the branch and the post-impl review chain; the mistakes this skill exists to prevent; and who calls it and what it chains into.

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
- **`uberdev:review-pr`** — invoked via the `Skill` tool after PR creation on the always-PR path (default mode + Turbo mode under `UBERDEV_TURBO=1`). `/review-pr` owns the post-push reviewer fanout; `finish-branch` does not block on reviewer verdict.
