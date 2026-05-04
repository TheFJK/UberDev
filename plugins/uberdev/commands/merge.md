---
description: "After a PR is approved, lands it into the integration branch — ordering, strategy, conflict resolution, and local sync automated"
argument-hint: "[<PR#> | --all] [--integration-branch=<name>]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Merge Approved PRs

Land approved PRs into the integration branch — ordering, strategy, conflict resolution, and local sync automated.

**RULES:** Do NOT use the Task tool or internal subagents. The skill body owns all logic.

**Usage:** `/merge [<PR#> | --all] [--integration-branch=<name>]`

- No args → context-aware: single PR if on a PR branch, else discover and land all eligible open PRs against integration_branch.
- `<PR#>` → land a specific PR.
- `--all` → land every open APPROVED PR with passing CI.
- `--yes` / `-y` → **(deprecated; no behavioural effect)** parsed for backward compat; `/merge` is fully unattended (autopilot) and skips all prompts unconditionally. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--squash` / `--rebase` / `--merge` → **(deprecated; no behavioural effect)** parsed for backward compat; the `merge-strategy-decider` agent picks per-PR strategy from PR-shape signals (commit count, conventional-commit ratio, divergence, WIP markers, repo convention) plus an advisory `merge-strategy:<name>` PR-label hint. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--integration-branch=<name>` → override config / env / repo-default.
- `--bypass-protections` → **(deprecated; no behavioural effect)** parsed for backward compat; trust resolution is fully agent-decided via `trust-trail-evaluator`. There is no PATH_3 admin-bypass anchor and no CI-red waiver. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.

**Autopilot:** /merge runs unattended end-to-end. The plan table renders for transparency; the queue proceeds without `[y/N]` prompts and without author-identity gates. Per-PR failures (test fail, conflict-resolver `AMBIGUOUS`/`REFUSED`, push non-FF) park ONE PR via `drop` strategy and the queue continues. Dependency cycles auto-break to createdAt order. Local-integration divergence auto-rebases; on rebase conflict it surfaces in the run summary while the run still completes. Stale-branch handling executes safe rebases automatically (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection); risky cases skip with rationale. Phase 1.4 trust resolution accepts EITHER `reviewDecision == "APPROVED"` (PATH_1, team / branch-protection path) OR a green `/review-pr` trail bound to current HEAD SHA via the `trust-trail-evaluator` agent (PATH_2, solo-dev / no-protection path; the trail = `uberdev-approved` label + `Reviewed-by:` commit trailer + local audit JSON, with the agent emitting verdicts in `{PASS, STALE, INVALID, FORCE_PUSHED}` over structural primitives) — author identity is not a gate in either path. Combine these with whatever org-level controls you need; autopilot does not substitute for those.

## Deprecated Flags

The following flags / config keys are accepted for backward compat but have no behavioural effect:

- `--yes`, `-y` (CLI flags)
- `auto_confirm: true|false` (config key in `.claude/uberdev.local.md`)
- `--squash`, `--rebase`, `--merge` (CLI flags) — `merge-strategy-decider` agent picks per-PR strategy from PR-shape signals plus an advisory `merge-strategy:<name>` label hint. The CLI flag does NOT override the agent's choice for any PR.
- `--bypass-protections` (CLI flag) — trust resolution is fully agent-decided via `trust-trail-evaluator` (Phase 1.4 PATH_2 sub-condition (c)). No CI-red waiver, no PATH_3 admin-bypass anchor.
- `bot_authors_allow_list: [...]` (config key in `.claude/uberdev.local.md`) — as of v0.14.0, /merge no longer gates on PR-author identity; any APPROVED + CI-green PR is eligible regardless of author. Phase 1.4 trust resolution accepts EITHER `reviewDecision == "APPROVED"` (PATH_1, team / branch-protection path) OR a green `/review-pr` trail bound to current HEAD SHA via the `trust-trail-evaluator` agent (PATH_2, solo-dev / no-protection path; the agent emits verdicts in `{PASS, STALE, INVALID, FORCE_PUSHED}` over structural primitives) — author identity is not a gate in either path. The key remains parseable for backward compat.

On first encounter per run, /merge emits this stderr notice (verbatim) for the autopilot flags:

> `warning: --yes / -y / auto_confirm are deprecated; /merge is now fully unattended. The flag has no behavioural effect.`

Encountering `--squash` / `--rebase` / `--merge` for the first time emits this stderr notice (verbatim):

> `warning: --squash / --rebase / --merge are deprecated; /merge is fully unattended and the merge-strategy-decider agent picks per-PR strategy. The flag has no behavioural effect.`

Encountering `--bypass-protections` for the first time emits this stderr notice (verbatim):

> `warning: --bypass-protections is deprecated; /merge trust resolution is now agent-decided (trust-trail-evaluator). The flag has no behavioural effect.`

An audit event `deprecated_flag_used` is recorded once per encounter (one per flag class per run). No version-gated removal — keys stay parseable indefinitely. Pattern follows Terraform / npm CLI deprecation precedent. The same `deprecated_flag_used` event covers all five deprecated flag classes (`--yes`, `-y`, `auto_confirm`, `--squash` / `--rebase` / `--merge`, `--bypass-protections`); no new audit-event enum value is introduced.

Now invoke the `uberdev:merge` skill — it owns the 4-phase pipeline (pre-flight gate, merge plan, merge + parallel conflict-resolve, post-merge local sync). The skill renders inline, so `$ARGUMENTS` remains in scope for its bash blocks.
