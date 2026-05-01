---
description: "After a PR is approved, lands it into the integration branch — ordering, strategy, conflict resolution, and local sync automated"
argument-hint: "[<PR#> | --all] [--yes|-y (deprecated)] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Merge Approved PRs

Land approved PRs into the integration branch — ordering, strategy, conflict resolution, and local sync automated.

**RULES:** Do NOT use the Task tool or internal subagents. The skill body owns all logic.

**Usage:** `/merge [<PR#> | --all] [--yes|-y (deprecated)] [--squash|--rebase|--merge] [--integration-branch=<name>] [--bypass-protections]`

- No args → land the PR for the current branch (errors if none).
- `<PR#>` → land a specific PR.
- `--all` → land every open APPROVED PR with passing CI.
- `--yes` / `-y` → **(deprecated; no behavioural effect)** parsed for backward compat; `/merge` is fully unattended (autopilot) and skips all prompts unconditionally. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--squash` / `--rebase` / `--merge` → override per-PR strategy heuristic.
- `--integration-branch=<name>` → override config / env / repo-default.
- `--bypass-protections` → admin-bypass branch protections (audit-logged with required free-text waiver).

**Autopilot:** /merge runs unattended end-to-end. The plan table renders for transparency; the queue proceeds without `[y/N]` prompts and without author-identity gates. Per-PR failures (test fail, conflict-resolver `AMBIGUOUS`/`REFUSED`, push non-FF) park ONE PR via `drop` strategy and the queue continues. Dependency cycles auto-break to createdAt order. Local-integration divergence auto-rebases; on rebase conflict it surfaces in the run summary while the run still completes. Stale-branch handling executes safe rebases automatically (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection); risky cases skip with rationale. The trust anchor for the queue is `reviewDecision == "APPROVED"` plus GitHub branch protections (required reviews, status checks) — combine these with whatever org-level controls you need; autopilot does not substitute for those.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--yes`, `-y` (CLI flags)
- `auto_confirm: true|false` (config key in `.claude/uberdev.local.md`)
- `bot_authors_allow_list: [...]` (config key in `.claude/uberdev.local.md`) — as of v0.14.0, /merge no longer gates on PR-author identity; any APPROVED + CI-green PR is eligible regardless of author. The trust anchor is `reviewDecision == "APPROVED"` plus GitHub branch protections. The key remains parseable for backward compat.

On first encounter per run, /merge emits this stderr notice (verbatim) for the autopilot flags:

> `warning: --yes / -y / auto_confirm are deprecated; /merge is now fully unattended. The flag has no behavioural effect.`

An audit event `deprecated_flag_used` is recorded once per encounter. No version-gated removal — keys stay parseable indefinitely. Pattern follows Terraform / npm CLI deprecation precedent.

Now invoke the `uberdev:merge` skill — it owns the 4-phase pipeline (pre-flight gate, merge plan, merge + parallel conflict-resolve, post-merge local sync). The skill renders inline, so `$ARGUMENTS` remains in scope for its bash blocks.
