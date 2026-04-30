---
description: "After a PR is approved, lands it into the integration branch — ordering, strategy, conflict resolution, and local sync automated"
argument-hint: "[<PR#> | --all] [--yes|-y] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Merge Approved PRs

Land approved PRs into the integration branch — ordering, strategy, conflict resolution, and local sync automated.

**RULES:** Do NOT use the Task tool or internal subagents. The skill body owns all logic.

**Usage:** `/merge [<PR#> | --all] [--yes|-y] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]`

- No args → land the PR for the current branch (errors if none). Single-PR scope auto-confirms by default.
- `<PR#>` → land a specific PR. Single-PR scope auto-confirms by default.
- `--all` → land every open APPROVED PR with passing CI. Multi-PR scope prompts unless `--yes` or `auto_confirm: true` config.
- `--yes` / `-y` → skip the plan-confirm prompt and stale-branch per-branch prompts for this run.
- `--squash` / `--rebase` / `--merge` → override per-PR strategy heuristic.
- `--integration-branch=<name>` → override config / env / repo-default.
- `--bypass-protections` → admin-bypass branch protections (audit-logged with required free-text waiver).

**Auto-confirm:** the plan-confirm `[y/N]` prompt is suppressed when (1) `--yes` / `-y` is passed, (2) `.claude/uberdev.local.md` sets `auto_confirm: true`, OR (3) the post-gate merge set contains exactly one PR (single-PR scope default — the explicit PR number is the consent). Under auto-confirm, the Phase 4.5 stale-branch offer also becomes list-only — no per-branch prompts and no auto-rebase. /merge **never** runs `git rebase` automatically; auto-confirm only suppresses the offer.

Now invoke the `uberdev:merge` skill — it owns the 4-phase pipeline (pre-flight gate, merge plan, merge + parallel conflict-resolve, post-merge local sync). The skill renders inline, so `$ARGUMENTS` remains in scope for its bash blocks.
