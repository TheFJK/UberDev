---
description: "After a PR is approved, lands it into the integration branch — ordering, strategy, conflict resolution, and local sync automated"
argument-hint: "[<PR#> | --all] [--integration-branch=<name>] [--accept-blocker-deferred] [--accept-critical-deferred] [--i-know-what-im-doing]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Merge Approved PRs

Land approved PRs into the integration branch — ordering, strategy, conflict resolution, and local sync automated.

**RULES:** The skill body owns all logic and mandates exactly three Task-tool agent fanouts — `trust-trail-evaluator` (Phase 1.4 PATH_2 (c)), `merge-strategy-decider` (Phase 2.2), and `conflict-resolver` (Phase 3.3) — which is why `Task` is in this command's allowed-tools. Do NOT improvise any Task dispatch beyond those three skill-mandated sites, and do NOT re-implement their logic inline.

**Usage:** `/merge [<PR#> | --all] [--integration-branch=<name>] [--accept-blocker-deferred] [--accept-critical-deferred] [--i-know-what-im-doing]`

- No args → context-aware: single PR if on a PR branch, else discover and land all eligible open PRs against integration_branch.
- `<PR#>` → land a specific PR.
- `--all` → land every open APPROVED PR with passing CI.
- `--yes` / `-y` → **(deprecated; no behavioural effect)** parsed for backward compat; `/merge` is fully unattended (autopilot) and skips all prompts unconditionally. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--squash` / `--rebase` / `--merge` → **(deprecated; no behavioural effect)** parsed for backward compat; the `merge-strategy-decider` agent picks per-PR strategy from PR-shape signals (commit count, conventional-commit ratio, divergence, WIP markers, repo convention) plus an advisory `merge-strategy:<name>` PR-label hint. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--integration-branch=<name>` → override config / env / repo-default.
- `--bypass-protections` → **(deprecated; no behavioural effect)** parsed for backward compat; trust resolution is fully agent-decided via `trust-trail-evaluator`. There is no PATH_3 admin-bypass anchor and no CI-red waiver. First encounter per run emits a one-line stderr deprecation notice. See `## Deprecated Flags` below.
- `--accept-blocker-deferred` → opt-in override of the Phase 2.5 blocker-halt INVALID gate (RFC 0002 §3.6, added v0.26.0). When present, `trust-trail-evaluator` passes the Phase 2.5 gate even if `phases.phase2_5.halted == true`. Per-invocation only (no env-var, no config key) — the operator must acknowledge each blocker-deferred PR individually.
- `--accept-critical-deferred` → opt-in override of the Phase 2.5 critical-deferred STALE gate (RFC 0002 §3.6, added v0.26.0). Lands a YELLOW trust trail (one or more critical findings filed as issues) without a re-review.
- `--i-know-what-im-doing` → required to land a PR whose `/review-pr` run captured an emit-GREEN-on-blocker-deferred override (RFC 0002 §3.5, added v0.26.0). Intentionally verbose flag name — overriding a blocker-deferred trust trail is a high-trust act.

**Autopilot:** /merge runs unattended end-to-end. The plan table renders for transparency; the queue proceeds without `[y/N]` prompts and without author-identity gates. Per-PR failures (test fail, conflict-resolver `AMBIGUOUS`/`REFUSED`, push non-FF) park ONE PR via `drop` strategy and the queue continues. Dependency cycles auto-break to createdAt order. Local-integration divergence auto-rebases; on rebase conflict it surfaces in the run summary while the run still completes. Stale-branch handling executes safe rebases automatically (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection); risky cases skip with rationale. Phase 1.4 trust resolution accepts EITHER `reviewDecision == "APPROVED"` (PATH_1, team / branch-protection path) OR a green `/review-pr` trail bound to current HEAD SHA via the `trust-trail-evaluator` agent (PATH_2, solo-dev / no-protection path; the trail = `uberdev-approved` label + `Reviewed-by:` commit trailer + local audit JSON, with the agent emitting verdicts in `{PASS, STALE, INVALID, FORCE_PUSHED}` over structural primitives) — author identity is not a gate in either path. Combine these with whatever org-level controls you need; autopilot does not substitute for those. When `auto_review_on_merge: true` (default `false`), Phase 1.4 auto-dispatches `/review-pr <N> --turbo` once per PR with missing trust trail (whitelisted reasons only — `trust_trail_label_missing` and `trust_trail_trailer_missing`) before excluding; on a green return, Phase 1.4 re-evaluates with refreshed inputs and the PR proceeds into Phase 2; on a non-green return, the PR is excluded with a clear run-summary line and the queue continues (#89).

## Inputs

Active config keys read by `/merge` at run start (in addition to the deprecated keys documented below for backward compat):

- **`auto_review_on_merge: true|false`** (default `false`; env override `UBERDEV_AUTO_REVIEW_ON_MERGE`) — when `true`, Phase 1.4 auto-dispatches `/review-pr <N> --turbo` once per PR per `/merge` run when the trust trail is missing. **Trigger whitelist:** fires ONLY on `trust_trail_label_missing` or `trust_trail_trailer_missing`. **Excluded reasons (do NOT trigger):** `trust_trail_stale_sha` (v2 work), `trust_trail_agent_invalid_input` (manual investigation), `trust_trail_json_sha_mismatch` (corrupted run-local path), `review_decision_not_approved` (auto-bypassing branch protection is a security regression), and all pre-condition and infrastructure-failure reasons (`pr_state_not_open`, `is_draft`, `ci_red`, `merge_state_blocked`, `pr_view_unreachable`, `pr_base_unresolvable`, `pr_base_parent_skipped`). **Bound:** 1 auto-review per PR per run (named constant `AUTO_REVIEW_DISPATCH_CAP`); no cross-run state — the per-run counter dies with the merge-pipeline subshell. **Audit:** emits `auto_review_dispatched` (before the `Skill()` call) and `auto_review_returned` (after) per triggered PR; both events are members of `AUDIT_EVENT_ENUM`. **Default `false` is bit-identical to current `/merge`** — zero new audit events, zero new wall-clock.

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

Now invoke the `uberdev:merge-pipeline` skill — it owns the 4-phase pipeline (pre-flight gate, merge plan, merge + parallel conflict-resolve, post-merge local sync). The skill renders inline, so `$ARGUMENTS` remains in scope for its bash blocks.
