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

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->

## Phase 2 — Merge plan

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->

## Phase 3 — Merge and conflict-resolve

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->

## Phase 4 — Post-merge local sync

<!-- Body filled in by wave-2 (Phase 1) and wave-3 (Phases 2/3/4). Do not edit the heading text. -->
