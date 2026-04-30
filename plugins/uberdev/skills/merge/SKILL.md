---
name: merge
description: Use when the user invokes /merge or /uberdev:merge to land approved PRs — owns the 4-phase pre-flight/plan/merge-resolve/sync pipeline.
---

# Merge Skill

## Overview

Post-review PR landing automation. Takes one or more approved PRs, computes a sane order, picks per-PR strategy, resolves conflicts via parallel per-file agents, and lands each merge.

## When to Use

Invoked from `commands/merge.md`. Do NOT call directly outside that path. Pairs with `finish-branch` Option 2 — `finish-branch` opens the PR, `/merge` lands it.

## Constants

All magic strings/numbers used by this skill are declared here once. Later phases reference these names; values are NOT re-inlined.

| Name | Value | Used by |
|---|---|---|
| `STRATEGY_ENUM` | `squash`, `rebase`, `merge` | D11 (per-PR strategy), D-LABEL |
| `WIP_MESSAGE_REGEX` | `/^(wip\|fix\|update\|misc\|asdf\|address review\|typo)/i` | D11 |
| `CONVENTIONAL_COMMIT_THRESHOLD` | 3 (max commit count for rebase candidate) | D11 |
| `PATCH_LINE_CAP` | 200 | D16 (agent rejection threshold) |
| `PATCH_FILE_CAP` | 5 | D16 |
| `LOCK_FILE_PATH` | `.git/uberdev-merge.lock` | D14 |
| `AUDIT_LOG_DIR_PATTERN` | `.uberdev/runs/<run-id>/` | D15 |
| `AUDIT_LOG_FILENAME` | `audit.jsonl` | D15 |
| `AUDIT_EVENT_ENUM` | `gate_pass`, `gate_fail`, `order_proposed`, `order_confirmed`, `strategy_chosen`, `probe_clean`, `probe_conflict`, `agent_dispatched`, `agent_returned`, `patch_applied`, `test_pass`, `test_fail`, `push_resolution`, `merge_executed`, `local_sync`, `branch_deleted`, `worktree_removed`, `admin_bypass`, `waiver_recorded`, `error` | D15 |
| `SCRATCH_WORKTREE_PATTERN` | `.claude/worktrees/merge-<run-id>/` | D10 |
| `BRANCH_NAME_REGEX` | `^[A-Za-z0-9._/-]{1,255}$` | D8 (validation before shell argv use) |
| `MERGE_STRATEGY_LABEL_PREFIX` | `merge-strategy:` | D-LABEL |
| `BOT_AUTHORS_ALLOW_LIST_KEY` | `bot_authors_allow_list` (config key in `.claude/uberdev.local.md`) | D-BOTS |
| `BOT_AUTHORS_DEFAULT` | `["dependabot[bot]", "renovate[bot]"]` | D-BOTS |
| `INTEGRATION_BRANCH_KEY` | `integration_branch` (config key) | D8 |
| `INTEGRATION_BRANCH_ENV_VAR` | `UBERDEV_INTEGRATION_BRANCH` | D8 |

## Inputs

Argument parsing:

- **No args** — use the current branch's PR if one exists. If the current branch has no open PR, error out with a clear message pointing to `finish-branch`.
- **`<PR#>`** (single positional integer) — single-PR mode; operate on exactly that PR number.
- **`--all`** — enumerate all open PRs that are APPROVED and have passing required CI checks; treat the result as the input set.

Integration-branch resolution (four-tier precedence chain, highest wins):

1. **CLI flag** `--integration-branch=<name>` — explicit per-invocation override.
2. **Env var** `UBERDEV_INTEGRATION_BRANCH` (see `INTEGRATION_BRANCH_ENV_VAR`) — shell-scoped override.
3. **Config file** `.claude/uberdev.local.md` `integration_branch:` key (see `INTEGRATION_BRANCH_KEY`) — repo-local default.
4. **Fallback** `gh repo view --json defaultBranchRef` — GitHub's recorded default branch.

Branch names (from any tier) MUST be validated against `BRANCH_NAME_REGEX` before being used as a shell argv. Reject and error out on any name that fails the regex; do not pass unvalidated input to `git`, `gh`, or any subprocess.

## Phase 1 — Pre-flight gate

### Step 1.1 — Acquire the single-instance lock

Use `flock` against `LOCK_FILE_PATH` (declared in `## Constants`). Default fail-fast on contention with message `"another /merge run in progress, PID <X>"`. `--wait` flag opt-in for queueing. Stale-lock cleanup: if PID dead, release.

### Step 1.2 — Read integration_branch via the four-tier precedence chain (D8)

1. CLI flag `--integration-branch=<name>` (highest)
2. env var `INTEGRATION_BRANCH_ENV_VAR`
3. `.claude/uberdev.local.md` YAML frontmatter `INTEGRATION_BRANCH_KEY`
4. `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`

Validate the resolved name against `BRANCH_NAME_REGEX` BEFORE any shell argv use. Reject and abort on regex fail.

### Step 1.3 — Ask-and-persist branch (D8a) when all four tiers are empty

If the four-tier chain returns nothing (network-detached clone, missing remote): prompt user once for a branch name. Validate against `BRANCH_NAME_REGEX`. Offer "Save to `.claude/uberdev.local.md`? [Y/n]". On yes: use `mktemp + mv` atomic write pattern (mirrors `install.sh:89`) — write new YAML frontmatter (or upsert the `integration_branch:` key) to a sibling tempfile in the same directory via `mktemp --tmpdir="$(dirname "$TARGET")" uberdev.local.XXXXXX` (same-filesystem guarantee for atomic rename; bare `mktemp` defaults to `$TMPDIR` and breaks atomicity when `.claude/` is on a different filesystem), `fsync`, then `mv -f` over the target. On no: hold the value only for the current run.

### Step 1.4 — Per-PR pre-flight gate

Project the JSON: `gh pr view <N> --json state,isDraft,reviewDecision,statusCheckRollup,headRepository,maintainerCanModify,isCrossRepository,headRefName,headRefOid,baseRefName,body,commits,labels,createdAt,author`.

Per-PR gate conditions (ALL must pass):
- `state == "OPEN"`
- `isDraft == false`
- `reviewDecision == "APPROVED"`
- `statusCheckRollup` all green OR explicit `--bypass-protections` waiver
- PR author is repo collaborator OR `author.login` ∈ `bot_authors_allow_list` (config key, default `["dependabot[bot]", "renovate[bot]"]` per D-BOTS) OR explicit per-PR consent

On any condition fail: list the specific failing condition for that PR. Exclude from merge set. **Never silently skip** — every fail emits a `gate_fail` event to `audit.jsonl` AND surfaces in the user-facing summary. Continue with passing PRs.

### Step 1.5 — Compute file-overlap matrix (Q1 same-file degradation pre-compute)

For every pair of in-scope PRs, run `git diff --name-only <integration_branch>..<pr-N-head>` and intersect path sets. Pairs with non-empty intersection are flagged for sequential ordering in Phase 2 (PR-A first, then re-probe PR-B against new tip). Distinct-file pairs remain eligible for parallel conflict-resolve in Phase 3.

### Step 1.6 — Fork-PR preflight (Q3 two-step gate)

For every cross-repository PR (`isCrossRepository == true`):
- Same-repo head: proceed.
- User-owned fork + `maintainerCanModify == true`: probe with `git push --dry-run` first. Permission OK → proceed.
- Org-owned fork OR `maintainerCanModify == false`: refuse conflict-resolve. Surface handoff to PR author. Skip that PR (queue continues). Clean-merge case still flows via `gh pr merge` since GitHub natively handles fork merges.

### Step 1.7 — Single-PR pre-flight fail edge case

If only one PR is in scope and its pre-flight fails: abort the run (nothing to merge).

## Phase 2 — Merge plan

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->

## Phase 3 — Merge and conflict-resolve

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->

## Phase 4 — Post-merge local sync

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->
