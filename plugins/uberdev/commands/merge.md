---
description: "After a PR is approved, lands it into the integration branch — ordering, strategy, conflict resolution, and local sync automated"
argument-hint: "[<PR#> | --all] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Merge Approved PRs

Land approved PRs into the integration branch — ordering, strategy, conflict resolution, and local sync automated.

**RULES:** Do NOT use the Task tool or internal subagents. The skill body owns all logic.

**Usage:** `/merge [<PR#> | --all] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]`

- No args → land the PR for the current branch (errors if none)
- `<PR#>` → land a specific PR
- `--all` → land every open APPROVED PR with passing CI
- `--squash` / `--rebase` / `--merge` → override per-PR strategy heuristic
- `--integration-branch=<name>` → override config / env / repo-default
- `--bypass-protections` → admin-bypass branch protections (audit-logged with required free-text waiver)

Now invoke the `uberdev:merge` skill — it owns the 4-phase pipeline (pre-flight gate, merge plan, merge + parallel conflict-resolve, post-merge local sync). The skill renders inline, so `$ARGUMENTS` remains in scope for its bash blocks.
