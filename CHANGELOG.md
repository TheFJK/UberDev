# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`/review-pr` → `/merge` SHA-bound trust signal (#40)** — `/review-pr` on a green run now emits three durable artifacts: PR label `uberdev-approved`, commit trailer `Reviewed-by: uberdev/review-pr@<head-sha>` (full 40-character SHA), and local audit JSON at `.uberdev/runs/<run-id>/review-pr-verdict.json`. The trailer is the load-bearing trust artifact (intrinsically SHA-bound via the git object DAG); label and JSON are corroborating defense-in-depth presence checks. `/merge` Phase 1.4 reframes from a single-condition gate to **trust-resolution** with three paths: PATH_1 (`reviewDecision == "APPROVED"` — team / branch-protection), PATH_2 (`/review-pr` trail bound to live `headRefOid` — solo-dev / no-protection), PATH_3 (`--bypass-protections` admin override). New `gate_pass.data.trust_anchor` ∈ `{reviewDecision_approved, uberdev_review_trail, bypass_with_waiver}` and `gate_fail.data.reason` ∈ `{review_decision_not_approved, trust_trail_missing, trust_trail_stale_sha, trust_trail_label_missing, trust_trail_trailer_missing, trust_trail_json_missing, ci_red, pr_state_not_open, is_draft, merge_state_blocked}` field-level extensions land on the existing `gate_pass` / `gate_fail` events (no new event names).
- **Stale-SHA detection covers force-push + amend + rebase + squash uniformly.** Phase 1.4 PATH_2 (c) compares the trailer's embedded `<head-sha>` against **live** `gh pr view <N> --json headRefOid` (NOT against any local ref). One verification primitive covers all rewrite types. Refusal diagnostic: `/review-pr ran on commit <trailer-sha> but PR head is now <live-sha> — re-run /review-pr, then re-invoke /merge`.
- **Five new constants** in `skills/merge/SKILL.md`: `UBERDEV_APPROVED_LABEL`, `REVIEW_PR_TRAILER_PREFIX`, `RUN_ID_REGEX` (`^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` — path-traversal hardening), `TRUST_ANCHOR_ENUM`, `GATE_FAIL_REASON_ENUM`.
- **Editor note at `skills/merge/SKILL.md:125` corrected** from "four mirrors" to "five mirror sites" with explicit file:section enumeration of all 5 (this skill body, this skill's `## Common Mistakes`, `commands/merge.md:23`, `commands/merge.md:31`, `skills/using-uberdev/SKILL.md:146`).

### Changed
- **`/review-pr` exit codes are now 0 / 1 / 2** (was always 0). `0` = green (Phase 1 APPROVE + Phase 2 status ∈ {ran/APPROVE, skipped}); `1` = Phase 1 REJECT or REVISIONS_REQUIRED; `2` = Phase 2 status `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure). **Behavioral break** for callers that scripted against the always-0 contract — either ignore the exit code (preserve old behavior) or branch on it (use new behavior). Surfaces silent reviewer-crash failures that the trust signal exists to eliminate.
- **`commands/review-pr.md:82-83` prose updated in lockstep** with the exit-code contract change. Distinguishes "skipped" (Phase 2 not run; eligible for green; exit 0) from "blocked" (Phase 2 fanout crashed; exit 2). The previous "still exits successfully" wording is removed.
- **`tests/merge.test.sh` 34 → ~62 assertions** (M35–M46 trust-signal coverage). **`tests/review-pr.test.sh`** gains R1–R6 covering the green-run predicate, label/trailer literals, exit-code table, and run-id regex.

### Backwards compatibility
- **Trust-signal emission is additive on green runs.** Existing `/review-pr` invocations on REJECT / REVISIONS_REQUIRED paths produce no new artifacts (label not added, trailer not written, JSON not created). The exit-code change is the only behavioral break; CHANGELOG calls it out explicitly.
- **`/merge` Phase 1.4 trust resolution preserves PATH_1 (existing `reviewDecision == "APPROVED"` behavior).** Team-mode callers with branch protection are unchanged. PATH_2 is only consulted if PATH_1 fails. PATH_3 (`--bypass-protections`) is unmodified.
- **No new packages, no infra changes, no schema migrations.** Pure additive markdown driver edits + bash shape-check tests. Rollback is a single PR that removes the artifact-emission logic, reverts Phase 1.4 to the single-condition gate, and resets the 5 mirror sites.

## [0.15.0] - 2026-05-02

### Refactored (simplify-loop edits from `/uberdev:review-pr` Phase 2)
- **Step 5b sed forks 6 → 1** (efficiency lens) — Phase B was running six sequential `sed -i` invocations per spawn to template the launcher script (`REPO_ROOT`, `CLAUDE_BIN`, `ISSUE_NUM`, `TIER`, `DETECTED_TERMINAL`, `PERM_FLAG_VALUE`). All placeholders are unique tokens with no cross-substitution risk, so they collapse into one `sed -e ... -e ... -e ...` call. Saves 5 forks per spawn × N issues — small per-call win that compounds across batch dispatches. `PERM_FLAG_VAL` setup hoisted above the consolidated sed so substitution-value computation reads contiguously. In-place semantics (`SED_INPLACE` BSD/GNU dispatch) and per-expression delimiter choice (`|` vs `/`) preserved.
- **Dead-alternation regex split into two single-line assertions** (quality lens) — `tests/turbo-flow.test.sh` had a TURBO MODE banner assertion whose left-hand alternation (`for n in "${ISSUE_NUMS[@]}"…\n…medium…\n…break`) was dead code: `grep -E` without `-z` does not match across newlines, so only the right-hand alternation (`TIERS[$n].*medium`) ever fired. Split into two genuine assertions: one greps for the dedup loop construct, the other for the `break` after the first medium-tier hit. Same prose intent, more rigorous lock.
- **Reuse lens** — analyzed 5 candidates (heredoc consolidation, `osascript` heredocs, sed substitutions, notification fallback chain, comment redundancy); all rejected as either test-locked, right-sized, or net-negative for clarity. The four trivial/small heredocs are contractually locked at count=4 by `tests/turbo-flow.test.sh`; the iTerm vs Terminal.app `osascript` heredocs use distinct AppleScript verbs (not duplication); the notification fallback chain is three single-line branches with no genuine indirection win.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **zsh word-split footgun in multi-issue parser** — initial Phase 1 implementation used `for token in $ARGUMENTS; do …`, which does NOT word-split scalar parameters in zsh (SH_WORD_SPLIT off by default). Under zsh — Claude Code's actual Bash-tool shell on macOS — the loop saw `"5 6 7"` as a single token, the anchored `^[0-9]+$` rejected it, and `/turbo 5 6 7` died at the usage check (`/turbo 42` worked only because `"42"` happens to satisfy the regex when treated as one token). Replaced with a portable subshell pipeline: `ISSUE_NUMS=($(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++'))`. Array assignment `arr=($(cmd))` word-splits the substitution output on `$IFS` in BOTH bash and zsh; the pipeline tokenizes on spaces, anchored regex rejects flag tokens like `--terminal=foo123`, awk dedupes preserving first-seen order. New regression test in `turbo-flow.test.sh` greps the pipeline form so the footgun cannot reappear.
- **Phase A title/tier had no concrete defaults** — initial pass left `TITLES[$ISSUE_NUM]="$TITLE"` and `TIERS[$ISSUE_NUM]="$TIER"` referencing variables that prose comments told Claude to set. Now the bash block computes both deterministically: `TITLE_RAW=$(jq -r .title <<<"$ISSUE_JSON")` with a 40-char ellipsis truncation, and `TIER="${OVERRIDE:-medium}"` (the safe escalation default — `--trivial`/`--small` override; ambiguity routes through the full brainstorm pipeline). The triage prose above the bash block still drives Claude to downgrade when an issue is genuinely trivial/small, but the dispatch is now valid even if the heuristic refinement is skipped.
- **Phase B silently dropped per-issue dispatch failures** — initial pass appended unconditionally to `SPAWNED+=("#$ISSUE_NUM ($TIER)")` after the `case` statement, so a failing `cmux new-workspace` (dead socket) or AppleScript permission denial never surfaced — the user saw "Spawned 3 agents" while one had actually died. Now `DISPATCH_RC=$?` after the case and an `if/else` route success to `SPAWNED` and failure to `DISPATCH_FAILED`. Ghostty's branch ends in an `echo` for both AppleScript-success and AppleScript-fail-then-nohup paths, so both legitimately record as success (the agent is spawned either way, just via a different mechanism). Phase B failure summary block prints partial-batch failures to stderr; the success notification body appends `— N dispatch failure(s)` if any. Locked by 2 new assertions (`DISPATCH_FAILED` array, `DISPATCH_RC=$?` capture).
- **Apple Event queue claim softened** — the comment justifying why iTerm/Terminal don't need the Ghostty 600 ms pause read "(Apple Event queue serializes)" as a load-bearing fact; reworded to "(the Apple Event queue serializes same-application AppleScript calls in practice)" to flag it as an empirical observation, not an unconditional API guarantee.

### Added
- **`/turbo` and `/solve` accept multiple issue numbers** — `/turbo 5 6 7` (and `/solve 5 6 7`) validates each listed issue (OPEN + classifiable) before dispatching, then spawns one autonomous Claude agent per issue into its own terminal session (cmux workspace / Ghostty tab / iTerm window / Terminal.app window / nohup background process). Per-issue artifacts are namespaced by `$ISSUE_NUM` (`/tmp/solve-prompt-N.txt`, `/tmp/solve-N.sh`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch, `#N <title>` tab) so the spawns are collision-free. Single-issue invocation behaviour is byte-identical. Override flags (`--trivial|--small|--full`, `--auto`, `--terminal=...`) apply batch-wide; per-issue overrides are not supported (run separate invocations for different tiers).
- **Phase A validate-all-first contract in `solve-pipeline/SKILL.md`** — if any of the listed issues is closed, missing, or fails `gh` fetch, all errors are printed and the run aborts with `no agents dispatched` **before** spawning anything. No partial-state cleanup ever required. Phase B then loops the per-issue dispatch (write prompt → write launcher → spawn into chosen terminal).

### Changed
- **`solve-pipeline/SKILL.md` restructured into Phase A (validate) + Phase B (spawn).** Step 1 parses `ISSUE_NUMS` array (anchored `^[0-9]+$` rejects `--terminal=foo123`-style flag tokens; dedupe prevents same-issue race on shared worktree path). Step 3 hoists terminal detection + REAL_CLAUDE binary resolution + TURBO MODE banner out of the per-issue loop (terminal-detect runs once; banner prints once if any tier is medium). Steps 4 (was 3) becomes Phase A; Steps 5a/5b/5c (were 4/5/6) execute inside the Phase B `for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do ... done` loop. The medium `if [[ "$AUTO_MODE" == "1" ]]; then ... else ... fi` block is preserved at column 0 (zsh/bash do not require indentation inside `for ... done`), so `tests/turbo-flow.test.sh`'s differential-guard awk anchor remains valid.
- **Ghostty multi-spawn serialized with 600 ms pause.** AppleScript `Cmd+T` keystroke dispatch is asynchronous; firing three keystrokes in <100 ms can race all three into the first-created tab. Pause applies only when `TERMINAL=ghostty` AND `${#ISSUE_NUMS[@]} > 1`. cmux (IPC API), iTerm/Terminal (scripted `create window`/`do script`, Apple Event queue serializes), and nohup all spawn race-free without the pause.
- **Notifications batched.** One summary `cmux notify` / `terminal-notifier` / `osascript display notification` per `/turbo` invocation listing all spawned issues, replacing the prior N per-spawn notifications. Removes notification flooding on multi-issue runs.
- **`tests/turbo-flow.test.sh` 29 → 48 assertions.** New section locks the multi-issue parser (portable subshell pipeline with `tr`+`grep -E '^[0-9]+$'`+`awk '!seen[$0]++'`, zsh word-split footgun comment, Phase A error-printf format, all-errors-before-abort), Phase A contract (`no agents dispatched`, validate-all-first), Phase B loop construct (`for ISSUE_NUM in "${ISSUE_NUMS[@]}"`, `DISPATCH_FAILED` tracking, `DISPATCH_RC=$?` capture), TURBO MODE banner-printed-once dedup mechanic (`break` after first medium hit, split into two single-line assertions because `grep -E` without `-z` does not match across newlines), Ghostty serialization (`sleep 0.6`), batched-summary notification (`SPAWNED[@]`), and REAL_CLAUDE-hoist line-ordering. Wrapper section gains argument-hint shape assertions for both `/solve` and `/turbo`.
- **`tests/ghostty-dispatch-no-instance-leak.test.sh` awk anchor updated.** The dispatch case moved from `### 6.` to `#### 5c.` inside the new Phase B for-loop; the test's section-extraction awk pattern follows. Same 7 assertions as before; no contract change.
- **`/turbo` and `/solve` command frontmatter** updated: `argument-hint` becomes `<issue-number> [<issue-number>...]`; `description` notes multi-issue dispatch; usage examples added showing `/turbo 5 6 7`.
- **README.md `/turbo` section** gains a "Multi-issue dispatch" paragraph after the orthogonality table.

### Backwards compatibility
- **No user-facing breakage.** `/turbo 42` and `/solve 42` (single-issue) behaviour is byte-identical to 0.14.0. New multi-issue syntax is purely additive. No flag deprecations. Plugin manifest version bumped 0.14.0 → 0.15.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.14.0] - 2026-05-01

### Changed
- **`/uberdev:merge` is now unconditionally non-blocking** — every blocking gate that previously halted the queue or asked the user a question has been removed. Specifically: the Phase 1.4 PR-author allow-list condition (`PR author is repo collaborator OR ∈ bot_authors_allow_list`) is **deleted** — any APPROVED + CI-green PR is eligible regardless of author identity (collaborator, bot, external contributor); the trust anchor is `reviewDecision == "APPROVED"` plus GitHub branch protections. The Phase 2.2 step 3 external-author defer logic, the `defer` strategy, and the `pr_deferred` audit event are deleted along with it. Phase 1.3's ask-and-persist branch prompt is replaced by a literal `INTEGRATION_BRANCH_FALLBACK` (`main`) with a one-line stderr warning — autopilot does not ask, it acts. Phase 2.1 dependency-cycle abort is replaced by auto-break-via-createdAt-fallback. Phase 3.3vi push-non-FF halt is replaced by per-PR park (`PARK_REASON_ENUM` value `push-non-ff`); queue continues. Phase 4.2 `git pull --ff-only` halt is replaced by auto-rebase against `origin/<integration_branch>`; on rebase conflict the rebase aborts (preserving local head) and the divergence surfaces in the run summary while the run still completes. Phase 1.7 single-PR pre-flight fail now exits cleanly with a "no eligible PRs" summary rather than erroring. The pre-flight banner now reads `/merge autopilot — no prompts, no halts; per-PR failures park and the queue continues.` (the `Allow-listed authors:` line + Print-Twice rule are removed). The only remaining halt is `flock` contention from another live `/merge` (concurrent-run safety, not a user gate).
- **`bot_authors_allow_list` config key is now DEPRECATED** alongside `auto_confirm` / `--yes` / `-y`. Parses without error for backward compat but has no behavioural effect. `using-uberdev/SKILL.md` config-key documentation updated to reflect both deprecations and the new literal-`main` integration-branch fallback.
- **`tests/merge.test.sh` 90 → 103 assertions.** M22 splits into M22.drop (positive) + M22.no-defer (negative — STRATEGY_ENUM must NOT list the removed `defer`). M23 drops `pr_deferred` from the required audit-event list and adds an explicit M23.no-pr_deferred negative. M24 swaps the `external-author-not-allow-listed` PARK_REASON_ENUM assertion for `push-non-ff` (the new park reason) and adds M24.PARK.no-ext-author negative. M27 drops the `Deferred:` outcome assertion and adds M27.no-Deferred negative. M28 retargets the banner-content scope from "all of Phase 1" to "just Step 1.0" so the legitimate Phase 1.4 deprecation prose isn't tripped by the negative grep. M16 retargets from the removed atomic-rename mktemp pattern (no more persist step) to a negative guard that Step 1.3 contains no `mktemp` / `mv` / `[Y/n]`. New M16b verifies Phase 1.3 ships the fallback-branch existence check (`git ls-remote --heads origin` + `fallback-branch-missing` audit event). New M29–M33 cover the no-blocker contract directly: M29 (Phase 1.4 has no author gate), M30 (Phase 1.3 falls back to `INTEGRATION_BRANCH_FALLBACK` with no prompt), M31 (Phase 4.2 auto-rebases on ff-only fail), M32 (Phase 3.3vi parks PR on push-non-FF, queue continues), M33 (Phase 2.1 auto-breaks dependency cycles via createdAt fallback) — M33 collapsed to a single positive check + explicit `M33.no-old-rule` negative regression guard. New M34 directly inspects the Phase 3.4 failure-mode table for the no-halt invariant (Action column may never list `halt`). Suite total: 342/342 across 11 test files.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **`agents/conflict-resolver.md` orphan halt-prose** — line 56 still claimed `status: AMBIGUOUS halts the queue`, contradicting the new no-halt invariant in `skills/merge/SKILL.md` Step 3.3iv. Replaced with the correct park-and-continue contract; the calling skill maps the agent's status to a `pr_parked` audit event with `data.reason="ambiguous"` or `"refused"`.
- **`commands/merge.md` Deprecated Flags now lists `bot_authors_allow_list`** alongside `--yes` / `-y` / `auto_confirm`. The deprecation story was previously split across two files (`using-uberdev/SKILL.md` + `skills/merge/SKILL.md`) but missing from the command's own help; readers consulting `/merge` documentation now see the full list.
- **`skills/merge/SKILL.md` Phase 1.3 fallback-branch existence check** — added `git ls-remote --exit-code --heads origin "<INTEGRATION_BRANCH_FALLBACK>"` probe before proceeding to Step 1.4. Repos whose default branch is not `main` (e.g. `master`, `trunk`, `develop`) and whose four-tier resolution fails would previously have hit a confusing `gh pr merge --base main` 404 several phases downstream; now /merge declines cleanly with `error` audit event `data.reason="fallback-branch-missing"` and a one-line stderr pointing the user at `integration_branch:` config.
- **CHANGELOG 0.13.0 backfill** — PR #35 ("/merge true autopilot") bumped the manifest version but skipped its own CHANGELOG entry; the gap is now backfilled to keep Keep-a-Changelog readers consistent.

### Backwards compatibility
- **No CLI breakage.** Existing `/merge` invocations work identically; the surface change is purely the removal of failure modes that previously rejected work the user wanted to land. `/merge --yes` / `-y` / `auto_confirm` / `bot_authors_allow_list` remain parseable (deprecated). Plugin manifest version bumped 0.13.0 → 0.14.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.13.0] - 2026-05-01

### Changed
- **`/uberdev:merge` initial autopilot pass** (#35, PR #35) — removed the `[y/N]` plan-confirm prompt at Phase 2.4; deprecated `--yes` / `-y` CLI flags and the `auto_confirm` config key (parsed without effect, with a stderr deprecation notice and a `deprecated_flag_used` audit event). Stale-branch handling at Phase 4.5 became autopilot agent-decided with safety-precondition gates (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection). Constants table grew with `AUTO_CONFIRM_KEY`, `AUTO_CONFIRM_FLAGS`, `AUTO_CONFIRM_REASON_ENUM`, `STALE_REBASE_DECISION_ENUM`, `TEST_FAIL_DECISION_ENUM`, `DEPRECATED_FLAGS_NOTE`. Six new audit events added: `pr_parked`, `pr_deferred`, `stale_branch_rebase_decision`, `deprecated_flag_used`, `agent_strategy_switch`, `test_fail_agent_decision`. Test-fail handling at Phase 3.3v gained a 1-retry-1-switch agent-decided branch tree (re-resolve / strategy-switch / park) with audit-logged choices.
- **`/uberdev:review-pr` chains a mandatory simplify-pass** (PR #32) — Phase 1 review-and-fix loop is followed by Phase 2 simplify fanout; pre-push standalone `/simplify` calls collapsed since they duplicated work.
- **`/uberdev:review-pr` collapses duplicate `/simplify` pass** (PR #37) — the pre-push `/simplify` call in trivial/small heredocs duplicated work already done by Phase 2 of `/uberdev:review-pr`. Removed from solve-pipeline heredocs; saves three Task agent invocations per `/solve` trivial/small run with no quality loss.

### Fixed
- **`/solve` Ghostty dispatch instance leak** (#31, PR #33) — the auto-dispatched Claude agent no longer poisons the user's running Ghostty session.
- **Trust-boundary asymmetries flagged by `/uberdev:review-pr`** — orchestrator and merge skills tightened against prompt-injection-shaped content in untrusted external inputs (PR/issue bodies, conflict markers).

## [0.12.0] - 2026-04-30

### Added
- **`/uberdev:merge`** (#24, PR #27) — new top-level command + skill that orders, strategizes, and merges approved PRs end-to-end. 4-phase pipeline (pre-flight gate → merge plan with single user-confirm → merge + parallel conflict-resolve in scratch worktree → post-merge local sync) at `plugins/uberdev/skills/merge/SKILL.md`. New `agents/conflict-resolver.md` with textual-evidence return contract and 6 refusal triggers, dispatched one Task per conflicted file in a single assistant turn. New per-repo config keys `integration_branch` (CLI flag > env var `UBERDEV_INTEGRATION_BRANCH` > config file > `gh repo view --json defaultBranchRef`, with ask-and-persist fallback) and `bot_authors_allow_list` (default `["dependabot[bot]", "renovate[bot]"]`). Audit log at `.uberdev/runs/<run-id>/audit.jsonl`. `tests/merge.test.sh` ships 16 shape-check assertions (M1–M16) including the `Co-Authored-By: Claude` proximity guard and same-directory `mktemp` atomic-rename guard.
- **Auto-install for top-level aliases** (#21, PR #26) — `hooks/session-start` now auto-installs the six short-form forwarders (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`) on first session and refreshes them on plugin upgrade — no manual `/uberdev:install-aliases` step. Idempotent via `~/.claude/.uberdev-aliases-version` marker. Opt-out via `UBERDEV_NO_AUTO_ALIAS=1` (env, wins) or `auto_install_aliases: false` in `.claude/uberdev.local.md`. ALIASES table extracted into a shared helper `plugins/uberdev/lib/aliases-sync.sh` sourced by both the hook (auto-install) and `/uberdev:install-aliases` (manual install) — single source of truth, A6 drift test now reads from the helper. Marker-scoped collision skip preserves hand-authored files; `mktemp + mv -f` atomic-rename writes; symlink-containment guard refuses to sync into `~/.claude/commands` if it's a symlink. New `tests/aliases.test.sh` sections S1–S9 cover fresh install, second-session no-op, version-marker refresh, both opt-out paths (env + file), hand-authored file preservation, symlink containment, unreadable-marker degradation, concurrent-session race, CI wire-up.

### Changed
- **`/uberdev:finish-branch` defaults to push + create PR** (#20, PR #25) — the legacy 4-option menu (Merge / Push+PR / Keep / Discard) moves behind a new `--interactive` flag; default and `--turbo` paths now auto-push the branch, open a PR, then chain into `/uberdev:review-pr` via the `Skill` tool. Fulfills the global `~/.claude/CLAUDE.md` "MANDATORY: run `/uberdev:review-pr` after pushing the PR" rule by construction. Hardens the new auto-push path against (a) **title injection** via heredoc + quoted-variable read-back (closes the `gh pr create --title "<title>"` shell-substitution vector) and (b) **secret leakage** via a layered pre-push scan (gitleaks primary, regex floor for AWS / GH PAT / private-key shapes when gitleaks is missing) over both the to-be-pushed commit range AND the composed PR body file. The 6 reviewer agents whose output flows into the PR body (`code-reviewer`, `pr-test-analyzer`, `comment-analyzer`, `silent-failure-hunter`, `type-design-analyzer`, `code-simplifier`) gain a `## Output Rules — secret-leak prevention` "do not quote source/secrets" rule. New `tests/finish-branch-auto-chain.test.sh` and `tests/review-pr.test.sh` lock the contracts; `tests/turbo-flow.test.sh` retargeted to assert default-auto-PR + interactive-restores-menu + Skill-tool-chain canary.

### Fixed
- **Linux-only mtime test failure in `tests/aliases.test.sh` (S2/S3)** — try GNU `stat -c %Y` before BSD `stat -f %m`. On Linux GNU stat, `-f` is filesystem-mode (not format-string) and `%m` is treated as a missing file path, so the command dumps multi-line filesystem info on stdout *and* exits non-zero, which then ran the `-c %Y` fallback whose mtime got *appended* to the same captured value. The S2/S3 comparisons compared a multi-line blob (NEW) to an awk-extracted single token "File:" (OLD) — guaranteed to fail on every Linux runner. Order reversed; both macOS and Linux now exercise the same idempotency-equivalence assertion (52→55 assertions after also extending S1/S5/S8 to the 6th alias `/merge`).

### Backwards compatibility
- **No user-facing breakage.** Existing `/uberdev:finish-branch` invocations still work; `--interactive` restores the legacy 4-option menu for users who relied on it. `/uberdev:install-aliases` continues to be a valid manual entry point alongside the new auto-install. New `/uberdev:merge` and the `/merge` short-form alias are purely additive. Plugin manifest version bumped 0.11.0 → 0.12.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.11.0] - 2026-04-30

### Added
- **Top-level command aliases** (#16, PR #17) — `/uberdev:install-aliases` writes one-way forwarders into `~/.claude/commands/` so the five daily-driver commands work without the `uberdev:` namespace prefix: `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`. `/uberdev:uninstall-aliases` removes them (marker-scoped — hand-authored files preserved). Existing `/uberdev:<command>` invocations are unchanged (additive only). Forwarders capture the absolute plugin-install path at write time; no body duplication. Run `/uberdev:install-aliases` once after plugin install to opt in. `tests/aliases.test.sh` (27 assertions) pins the marker contract, collision detection, and README discoverability.

### Changed
- **`/issue` slimmed to 2 Sonnet scouts** (#14, PR #18) — replaces the prior 8-Opus-agent research fanout (Phases 1.5/2-4/4.5/7) with a thin 2-Sonnet-scout fanout (`codebase-scout`, `triage-scout`) dispatched in a single assistant turn. **Median wall-clock drops from minutes to under 30s.** New dedicated agents at `plugins/uberdev/agents/codebase-scout.md` and `triage-scout.md`, both pinning `model: sonnet` with four-layer defence-in-depth against the upstream `affaan-m/everything-claude-code#173` model-frontmatter regression. Documented escape hatch: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`. `--no-explore` soft-deprecated (notice + no-op, removal target v1.0.0). `## Security signals` / `## Current ecosystem` / `## Constraints` sections removed from `/issue` templates. `brainstorm/SKILL.md`'s issue-research short-circuit removed (orchestrator solve-time fanout unchanged). RFC `2026-04-29-issue-deep-root-cause-research-fanout.md` annotated as partially superseded.
- **`/solve` and `/turbo` deduped via shared skill** (#15, PR #19) — extracts the ~360-line shared launcher pipeline (arg parsing, repo detection, tier classification, prompt heredoc, terminal spawn, notify, retitle) from `commands/solve.md` (430 → 27 lines) and `commands/turbo.md` (452 → 29 lines) into a new inline skill at `plugins/uberdev/skills/solve-pipeline/SKILL.md` (397 lines). Both commands now set `export AUTO_MODE={0,1}` and invoke the skill; the 10 `DELTA from /solve:` / `DELTA from /turbo:` markers and the `DUPLICATION NOTE` banner are gone — divergence is now expressed as `if [[ "$AUTO_MODE" == "1" ]]` conditionals in a single source of truth. Renamed the legacy `AUTO_MODE` (permission-mode flag) to `AUTO_PERMISSIONS` inside the skill to disambiguate from the new `AUTO_MODE` (turbo-vs-interactive). `tests/audit-fixups.test.sh` adds C6/C7 (skill exists, no `context:` frontmatter, AUTO_PERMISSIONS count ≥ 3, both wrappers ≤ 100 lines); `tests/turbo-flow.test.sh` pins both wrapper-to-skill links and the AUTO_MODE exports. Suite goes 83 → 92 assertions.

### Backwards compatibility
- **No user-facing breakage.** `/uberdev:solve` and `/uberdev:turbo` invocations are byte-equivalent in behavior; the wrappers now delegate to `solve-pipeline`. `/uberdev:issue --no-explore` still parses but is soft-deprecated. The `legacy cache` heredoc step in solve-pipeline's trivial/small tiers no-ops on issues created after the #14 redesign (no more `.uberdev/research/issue-N/` writes from `/issue`); legacy issues whose research was persisted under the previous fanout still get inlined.

## [0.10.0] - 2026-04-29

### Added
- **CI shape-check workflow** at `.github/workflows/test.yml` — single ubuntu-latest job runs all `tests/*.test.sh` on every push and PR with `permissions: contents: read` and `timeout-minutes: 5`. `actions/checkout@v4` major-tag pin.
- **Plan-drift awareness in per-task spec reviewer** (`subagent-driven-dev`). New `## Plan Task Description` placeholder in `spec-reviewer-prompt.md`; new `plan_task_description` dispatch parameter in `SKILL.md` step 4f with a ~3000-token excerpt size guard. Reviewer DO-list bullet directs flagging *plan drift* (structural deviation from plan even when spec appears satisfied — e.g., implementer skipped prescribed steps, swapped libraries, merged tasks).
- **Threat model section** in `plugins/uberdev/skills/brainstorm/SKILL.md` — documents localhost-only bind, single-user assumption, no auth, no proxy/tunnel for the brainstorm WebSocket+HTTP companion server.
- **Shared reviewer-prompt template** at `plugins/uberdev/skills/_shared/document-reviewer-template.md` — canonical Status/Issues/Recommendations skeleton referenced (via back-link comments) from `brainstorm/spec-document-reviewer-prompt.md` and `write-plan/plan-document-reviewer-prompt.md`. Skills don't auto-include partials; this is a documentation convention plus drift-defense reference.
- **2 new test suites:**
  - `tests/spec-reviewer-plan-aware.test.sh` (3/3) — verifies plan-drift wiring in spec-reviewer prompt + SKILL.md.
  - `tests/audit-fixups.test.sh` (12/12) — regression coverage for the C1/C3/C4/C5 review-fixup contracts: code-simplifier auto-trigger gate, stop-server `stopped_no_cleanup` JSON status, `gh` prereq moved from theatre command-files to `hooks/session-start`, brainstorm `## Threat model` section anchor.
- **Configuration documentation** in `README.md`: split into Implemented (`solve_terminal`, `solve_auto`) and Planned (`solve_tier_default`, `review_depth`, `parallel_solve`) tables with YAML-frontmatter example and env-var override precedence.
- **Tracked public docs**: `docs/rfc/` is now ignored-with-exception (`docs/*` + `!docs/rfc/`) so RFCs referenced from README/CHANGELOG resolve in clones; `plugins/uberdev/docs/testing.md` smoke-test matrix tracked.

### Changed
- **3 shell hooks hardened against symlink and path-traversal abuse:**
  - `hooks/inject-brainstorm-answers`: previous `[ -L "$f" ]` symlink check covered only the resolved file, not ancestors. Replaced with `is_safe_path()` helper that canonicalizes and walks every ancestor; refuses a symlinked root entirely; falls back to `python3 os.path.realpath` on macOS where BSD `realpath -m` is missing. `is_safe_path()` rejections now log to stderr (previously silent).
  - `skills/brainstorm/scripts/stop-server.sh`: replaced `[[ "$SESSION_DIR" == /tmp/* ]]` glob (passed for `/tmp/../home/...` traversals) with canonicalize-then-exact-prefix `case` over `/tmp/brainstorm-*` and `/private/tmp/brainstorm-*`. JSON shape now distinguishes success (`"stopped"`) from skipped cleanup (`"stopped_no_cleanup"` with `"reason"` field) — callers can detect partial failures.
  - `hooks/session-end`: replaced `rm -rf /tmp/uberdev-*` (followed symlinks) with `find -H /tmp -maxdepth 1 \( -name 'uberdev-*' -type d \) -not -type l -exec rm -rf {} +`. The `-H` is required because `/tmp` is itself a symlink on macOS.
- **`canonicalize()` helper** (used by the two hardened hooks): captures python3/realpath stderr into a variable and emits a useful diagnostic on total failure with helper-name prefix. Admins can now distinguish "tool unavailable" from "path rejected."
- **`code-simplifier` agent description AND body** narrowed to require explicit invocation. Body's "operate autonomously and proactively, refining code immediately after it's written" prose removed — it had directly contradicted the new gating frontmatter. The agent now activates ONLY when invoked via `/uberdev:simplify` or by the `subagent-driven-dev` post-wave fanout. Examples retained but framed as "illustrating logic, not licensing auto-trigger."
- **`gh` prerequisite check moved from markdown-command-file theatre to a real runtime guard** in `hooks/session-start` — Claude reads command markdown as instructions, not bash, so the prior `command -v gh || exit 1` blocks were never executed. New session-start check mirrors the existing `jq` check and injects a one-time visible warning when `gh` is missing without failing the session.
- **`/solve` ↔ `/turbo` divergence annotated**: verified Claude Code commands do not support textual file partials (the `@path` syntax is context-attachment, not substitution), so the original "extract `_solve-shared.md`" plan was infeasible. Both files now carry a `DUPLICATION NOTE — KEEP IN SYNC` banner with section-anchor references plus inline `<!-- DELTA -->` markers at every divergence point. Inline markers are the source of truth; the banner index is for navigation only. Out-of-scope follow-up: `/turbo` trivial/small tier omits the `post-impl-review` invocation that `/solve` includes.
- `eval "$VAR=1"` → `declare "$VAR=1"` in `skills/brainstorm/SKILL.md:124` and `skills/orchestrator/SKILL.md:68`. Currently safe (TOPIC iterates a hardcoded list) but a footgun if ever driven from external input.
- `hooks-cursor.json` paths normalized from `./hooks/...` to `${CLAUDE_PLUGIN_ROOT}/hooks/...` matching `hooks.json`.
- `.gitignore` adds `.env*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa*`, `node_modules/`, `*.log`, `.claude/`, plus explicit ignores for `plugins/uberdev/docs/{plans,uberdev,windows}/` (local-only design notes).
- Generic-ified `/Volumes/FJK SSD/...` example paths in `commands/{solve,turbo}.md` to `/Users/me/My Project/...`.

### Security
- 3 P0 path-traversal/symlink hazards in shell hooks closed (above).
- `server.cjs` carries an explicit localhost-only / single-user / unauthenticated header note pointing to the new SKILL.md threat model section.

### Backwards compatibility
- `stop-server.sh` JSON: callers parsing the literal `"stopped"` string would now correctly fail-loud when cleanup is skipped (the new `stopped_no_cleanup` status replaces `stopped` only on partial failure). `grep -rn '"stopped"'` confirmed no in-repo consumers depend on the old shape.
- Markdown `command -v gh || exit 1` removal is invisible to runtime (the blocks were never executed); the new session-start warning replaces them.

Closes the audit findings catalogued by the multi-agent research sweep on PR #13.

## [0.9.0] - 2026-04-29

### Added
- **`/uberdev:issue` Phase 2-4 fanout grows from 4 → 8 Task agents** in a single assistant turn. Existing four (`research-codebase`, `research-patterns`, duplicate-search, label/scope-validation) plus `research-prior-art`, `research-constraints`, `research-security` (Semgrep MCP + awesome-secure-defaults), `research-test-coverage` (test-surface mapping). Issue templates gain `## Current ecosystem`, `## Constraints`, and conditional `## Security signals` sections. `NO_EXPLORE=1` narrows to the four in-repo agents only.
- **Always-on spec/plan/PR-test reviewers** (tier-independent quality bar). Orchestrator Phase 1 short-circuits per-topic against `.uberdev/research/issue-<N>/` (mirrors brainstorm). Spec-reviewer is always-on for medium AND large; `--paranoid` deprecated as a no-op. New Phase 4.5 dispatches `plan-reviewer` (1-retry, non-blocking). New Phase 5.5 runs `pr-test-analyzer` pre-merge for large tier.
- **`uberdev:post-impl-review` skill** — 5-agent advisory fanout (`code-reviewer`, `simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`) in a single message. Invoked by `/solve` trivial/small inline prompts AND by `subagent-driven-dev` after each wave.
- **Non-blocking `/turbo` Q&A.** Orchestrator Phase 2 under `--turbo` auto-picks each clarifying answer using research-bundle synthesis and writes `questions.md`. `finish-branch` Option 2 reads it and appends `## Open questions answered by /turbo` (Question | Choice | Confidence) plus `## Reviewer findings summary` to the PR body.
- New agent definitions: `agents/research-security.md`, `agents/research-test-coverage.md`.
- Tests: `tests/post-impl-review.test.sh` (10/10 — frontmatter, 5 reviewer agent names, single-message invariant, both call-site refs, anti-loop guard); `tests/issue-causal-fanout.test.sh` extended to 39/39 (8 new 8-agent assertions + 1 new `--no-explore` 4-agent assertion); `tests/turbo-flow.test.sh` extended to 19/19 (9 new always-on-reviewer assertions).

### Changed
- **`--paranoid` flag is now a no-op.** Spec-reviewer runs unconditionally for medium and large tiers. Old `tier == medium AND --paranoid` gate prose removed from orchestrator; deprecation prose retained for two flag mentions.
- `brainstorm` step 2 short-circuit pattern relaxed to match generic loop variable naming used by orchestrator artifact-reuse.

### Backwards compatibility
- `--paranoid` still parses without error (deprecated no-op) — pre-v0.9 invocations continue to run.
- Issues created before v0.9.0 retain a 4-agent fanout fallthrough when no `## Current ecosystem` / `## Constraints` sections are present in the body.

Closes #11.

## [0.8.0] - 2026-04-29

### Added
- **`/uberdev:issue` deep root-cause research fanout.** Phase 2 now dispatches a 2-agent parallel fanout (`research-codebase` + `research-patterns`) when `NO_EXPLORE=0`, in the same single message as the existing Phase 3 (Duplicate Search) and Phase 4 (Label/Scope Validation) Task() calls — four agents fan out together, Phase 4.5 aggregates all four returns. Research summaries write to `.uberdev/research/run-<RUN_ID>/` and rename to `.uberdev/research/issue-<ISSUE_NUM>/` after `gh issue create`.
- **Bug-template `## Likely root cause` is now a causal triple** — `**Symptom:**` (observable failure), `**Mechanism:**` (specific code/data path), `**Owning code:**` (path/symbol — the assumption to challenge). Optional 5 Whys nested chain for non-trivial bugs. Replaces the previous file-list placeholder.
- **`/uberdev:brainstorm` short-circuit on `.uberdev/research/issue-<N>/`.** When invoked downstream of `/issue` for the same issue number, brainstorm reads the persisted summaries instead of re-dispatching equivalent research agents. Per-topic skip (codebase + in-repo prior art only — external prior art still dispatches); mtime-based staleness fallback; clean fallthrough for issues created before this change.
- **Body authoring rules subsection in `issue.md`** — codifies the WHAT/HOW boundary ahead of the templates: issue body says what is broken or wanted, never how to fix it. Implementation strategy is `/uberdev:brainstorm`'s job.
- **`tests/issue-causal-fanout.test.sh`** — structural-assertion test (modelled on `tests/turbo-flow.test.sh`) locking the contract invariants: Phase 1.5 RUN_ID/SUMMARY_DIR, Phase 2 4-agent single-message fanout, `--no-explore` placeholder verbatim, causal triple labels, feat template rename invariant, Phase 7 artifact-binding rename, brainstorm short-circuit + per-topic skip + stale-check + backwards-compat fallthrough.
- **RFC:** `docs/rfc/2026-04-29-issue-deep-root-cause-research-fanout.md` records the why (2-agent rather than 4-agent fanout, stable artifact directory rather than return-value handoff, triple rather than freeform causal essay, field rename rather than rules-text reminder) and rejected alternatives.

### Changed
- **Feat-template field rename:** `## Proposed approach` → `## What changes`. Field-name pressure replaces rules-text pressure for keeping implementation strategy out of the issue body. Downstream parsers (`/solve`, `/turbo`, `/orchestrator`) read only `**Triage hint:**` from the body, so the rename is contract-preserving.
- **Phase 4.5 aggregate** in `issue.md` extended to reconcile two new research returns (`codebase.md` drives the bug-template triple and `## Likely area`; `patterns.md` drives the `## Related` prior-pattern bullets and informs the causal chain when prior bugs exist).
- **Rules subsection** in `issue.md` gains a WHAT/HOW boundary bullet: issue body never contains an implementation checklist or fix design.

### Backwards compatibility
- No breaking change to issue-body parsing. `**Triage hint:**`, severity checkboxes, label format, and conventional-commit titles all preserved verbatim.
- Issues created before v0.8.0 have no `.uberdev/research/issue-<N>/` directory; brainstorm's short-circuit `[ -d ... ]` check returns false and falls through cleanly to the existing parallel-dispatch path. No data migration.

Closes #9.

## [0.7.1] - 2026-04-29

### Fixed
- `/turbo` unattended chain now propagates `--turbo` end-to-end through every handoff (`brainstorm` → `write-plan` → `subagent-driven-dev` → `finish-branch`). PR #8 closed issue #5 architecturally by making `write-plan` non-interactive, but `finish-branch` was still prompting at the chain tail because none of the downstream skills forwarded `--turbo`. `finish-branch` now auto-selects "Push and Create PR" under `--turbo` and announces the auto-selection.
- `orchestrator` Phase 5 forwards `--turbo` to `subagent-driven-dev` — closes the medium/large `/turbo` gap PR #8 introduced (`/turbo` for medium/large tier routes through `/uberdev:orchestrator --turbo`, but Phase 5 was invoking `subagent-driven-dev` without forwarding the flag, so the chain still stalled at `finish-branch`).
- `finish-branch` Step 5 cleanup behavior reconciled with the file's own Quick Reference table and Red Flags section: cleanup runs only for Options 1 (Merge locally) and 4 (Discard). Option 2 (Push and create PR) leaves the worktree alive for PR-feedback fixups; Option 3 (Keep as-is) is explicit. Pre-existing contradiction surfaced as a live runtime bug under `/turbo` — unattended runs auto-route to Option 2.

### Added
- `tests/turbo-flow.test.sh` — 9 contract assertions locking the `--turbo` propagation contract at every handoff (`brainstorm`, `write-plan`, `subagent-driven-dev`, `finish-branch`, plus `orchestrator` Phase 5 and the `/turbo` command entry point). Default-mode regression canaries also included so future edits can't silently break the non-`--turbo` paths.

## [0.7.0] - 2026-04-28

### Added
- `/uberdev:orchestrator` skill — writer-subagent pipeline used by `/solve` and `/turbo` for medium/large tier issues. Drives 5 phases: research fanout (parallel Sonnet subagents) → optional Q&A (skipped for `/turbo`) → spec-writer (Opus) → optional spec-reviewer (Opus, gated by `--paranoid` for medium tier; always for large tier) → plan-writer (Opus, with internal research fanout) → existing `subagent-driven-dev`. Each writer returns a structured YAML summary; orchestrator main holds pointers, not raw artifacts. Reclaims spawned-agent context for wave dispatch and error recovery.
- 8 new agent definitions: `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints` (Sonnet); `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer` (Opus). Each is invokable via Task() dispatch with a strict universal return contract.
- `--paranoid` flag on `/uberdev:orchestrator` enables spec-reviewer for medium tier issues.

### Changed
- `/solve` and `/turbo` medium/large tier prompts now invoke `/uberdev:orchestrator` instead of `/uberdev:brainstorm` directly. Trivial and small tier paths unchanged. `--turbo` flag now propagates as `/uberdev:orchestrator --turbo …`.
- `brainstorm` skill: added a note acknowledging `/solve` and `/turbo` route through the orchestrator skill; brainstorm itself remains the canonical reference and the right invocation for ad-hoc design work.
- `write-plan` skill: execution handoff is now non-interactive — defaults to subagent-driven; explicit user opt-in for inline. Resolves the `/turbo` unattended-flow break (issue #5).

### Fixed
- `/turbo` no longer halts on a "Subagent-Driven vs. Inline Execution?" prompt during plan handoff. Closes #5 (architecturally, via the writer-subagent refactor in #6).

## [0.6.0] - 2026-04-28

### Added
- `/solve` Ghostty dispatcher tab-spawns into the originating Ghostty window when invoked from inside Ghostty (`TERM_PROGRAM=ghostty`), keeping per-project workspaces visually grouped instead of cluttering the desktop with new top-level windows. `SOLVE_GHOSTTY_NEW_WINDOW=1` forces the legacy new-window behavior; AppleScript failures (e.g. Accessibility permission denied) fall back to it automatically with a stderr warning.
- `/turbo <issue>` slash command: unattended `/solve` that auto-accepts the brainstorm phase's lead-agent recommendations for medium/large tiers (parallel research still runs — recommendation grounding preserved). Trivial/small tiers behave identically to `/solve`. Composes orthogonally with `--auto` (permission-mode flag); `/turbo <issue> --auto` is the max-autonomy combo. No new approval gates — only collapses the clarifying-questions loop. `/turbo` also gains the same Ghostty tab-spawn behavior as `/solve`.
- `/solve --auto` (and `/turbo --auto`) flag: enables Claude Code's `--permission-mode auto` classifier in the spawned agent. Auto-approves low-risk ops (file edits, reads, package installs) and blocks high-risk ones (force push, `rm -rf` on pre-existing files, exfil, self-modification, `--dangerously-skip-permissions`). Resolves from CLI flag → `SOLVE_AUTO=1` env → `solve_auto: true` in `.claude/uberdev.local.md`. `/turbo <issue> --auto` is the max-autonomy combo.

### Changed
- `brainstorm` skill: parallel research dispatch promoted to **default first step** (before clarifying questions; skipped only for trivial tasks). The 2-3 proposed approaches are now grounded in research synthesis, not speculation. No approval gates added — "single forward pass" stays.

### Removed
- Deprecated slash-command shims `/uberdev:brainstorm`, `/uberdev:execute-plan`, `/uberdev:write-plan` removed. They were Superpowers-port leftovers redirecting to the canonical skills of the same name; invoke the skills directly via the Skill tool instead.

## [0.5.0] - 2026-04-28

### Added
- `SessionEnd` hook: best-effort cleanup of `~/.claude/.uberdev-answers`, `/tmp/uberdev-*` (plugin-prefixed only), and brainstorm event files older than 24h.
- `PreCompact` hook: append `.claude/auto-memory.md` to `.claude/session-archive.md` before compaction wipes context (silent no-op when absent; refuses to write through a symlinked `.claude/`).
- `.claude/uberdev.local.md` per-project configuration (YAML frontmatter for tier, review depth, terminal, parallel toggle); env vars override file settings.
- `AskUserQuestion` fast-path in `brainstorm` skill for discrete direction selection (2-5 options) without spinning up the visual companion. Visual companion remains the primary path for full design exploration.
- `isolation: "worktree"` guidance in `subagent-driven-dev` skill — Pattern B's controller-only-git approach is the documented opt-out; everything else defaults to worktree isolation.
- YAML frontmatter (`description`, `argument-hint`, `allowed-tools`) on `/issue` and `/solve` — were previously missing, leaving the picker with empty descriptions and triggering permission prompts on every `gh`/`find`/`osascript` call.
- `CONTRIBUTING.md` (contributor onboarding: quick start, repo layout, conventional commits, branch naming, PR expectations, `/simplify` mandate).
- `CHANGELOG.md` (Keep-a-Changelog 1.1.0 format covering v0.2.0 → v0.5.0).

### Changed
- 5 detail-oriented agents (`comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `plan-reviewer`, `type-design-analyzer`) switched from `model: inherit` to `model: haiku`. Since `/uberdev:review-pr` dispatches all 7 agents in parallel and is bound by the slowest, switching the detail agents to Haiku 4.5 cuts wall-time ~15-20%.
- `code-simplifier` agent rules made stack-agnostic — was hardcoding JS/React conventions (ES modules, `function` keyword, React Props types); now defers to project CLAUDE.md / style guide and language-agnostic clarity rules.
- `plugin.json` description trimmed from ~1.4 KB to one impactful sentence (marketplace listing aesthetics).
- `/uberdev:simplify` `allowed-tools` gains `Edit`, `Write`, `MultiEdit` (was hitting permission prompts on every fix attempt).
- `/uberdev:review-pr` `allowed-tools` narrows `Bash` to `Bash(git*)`, `Bash(gh*)` (read-only command).

### Fixed
- **Critical:** v0.4.0's `/issue` Phase 2/3/4 parallel fanout was silently broken — subagents have no shell context, so `$REPO`/`$DESC`/`$KEYWORDS`/`$COMMITLINT` references in agent briefs didn't resolve. Now resolves in orchestrator bash and bakes literal values into each agent brief.
- **Security (RCE):** `/solve` no longer passes `--dangerously-skip-permissions` to the autonomous agent. A malicious GitHub issue body could otherwise have executed under the user's account; the spawned agent now runs in an interactive terminal where the user gates each permission.
- **Security (prompt-injection):** `inject-brainstorm-answers` hook validates each event line as JSON via `jq`, HTML-escapes `<`/`>`, and refuses symlinked event paths. Closes a vector where any process in the cwd could plant arbitrary closing tags + instructions in the next user turn.
- `session-start` hook replaces fragile manual `escape_for_json` + `printf '%s'` interpolation with `jq -Rs`-style construction. Handles control bytes 0x00-0x1f and stray `%` format-spec collisions that previously corrupted output.
- `pre-compact` hook now refuses to write through a symlinked `.claude/` directory (`[ -d ]` follows symlinks; explicit `[ ! -L ]` guard added).
- Cross-platform `sed -i` in `/solve` — was BSD-only `-i ''` (broke on Linux with `sed: can't read : No such file`); now detects platform via `uname` and uses correct syntax on macOS + Linux.
- `session-start` no longer captures stderr into the SKILL.md content variable (`2>&1` → `2>/dev/null`); a missing skill file now degrades to empty injection rather than appearing as `Error reading…` content.

### Performance
- `inject-brainstorm-answers` per-line `jq -e -c .` fork loop collapsed to a single streaming `jq -R 'fromjson? // empty'` call. Saves ~200-500ms per UserPromptSubmit on active brainstorm sessions (50+ events).
- Two filesystem walks in `inject-brainstorm-answers` (blanket symlink scan + events-file `find`) folded into one targeted walk.

## [0.4.0] - 2026-04-28

### Added
- Parallel-fanout orchestration spread across the plugin: `/uberdev:review-pr` flips its default from sequential to **parallel** (all applicable review agents dispatch concurrently in a single turn).
- `/uberdev:issue` Phase 2/3/4 (codebase investigation + duplicate search + label/scope validation) runs as three parallel agents — roughly 60-70% wall-time savings.
- `systematic-debugging` skill gains **competing-hypothesis fanout** — read-only investigators per hypothesis, no anchoring on the first guess.
- `brainstorm` skill gains optional parallel design-direction exploration for high-stakes designs.
- `write-plan` skill gains opt-in alternative-plan generation (3 decomposition strategies).
- `receiving-code-review` skill adds multi-reviewer parallel triage.

### Changed
- `verification-before-completion` skill documents parallel verification dispatch (independent test/lint/build/typecheck checks running concurrently).
- Documented the parallel-default as a deliberate divergence from upstream `pr-review-toolkit`.

## [0.3.1] - 2026-04-28

### Changed
- `/uberdev:simplify` realigned with Anthropic's built-in `/simplify`: three-parallel-agent orchestrator — Code Reuse, Code Quality, and Efficiency reviewers fan out concurrently in a single Task-tool turn; controller aggregates findings and fixes them.
- Iron rule preserved (no behavior changes), plus UberDev's separate `refactor:` commit mandate.

### Fixed
- Restored proactive-trigger examples in the `code-simplifier` agent that were dropped during the orchestrator refactor.

## [0.3.0] - 2026-04-28

### Added
- Full Superpowers parity port: `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev` skills.
- Brainstorm Visual Companion: Neo Brutalism UI served by a local server, with `frame-template.html`; sessions persist to `.uberdev/brainstorm/`.
- `SessionStart` hook that injects the `using-uberdev` primer at conversation start so Claude knows how to discover plugin skills.

## [0.2.1] - 2026-04-27

### Added
- Wave-based parallel execution (Pattern B) in `/solve` and `/uberdev:subagent-driven-dev`: every task in a wave dispatches in parallel; waves run sequentially.
- `uberdev:write-plan` requires three new headers per task (`Depends on:`, `Wave:`, `Owns:`) and an `## Execution Waves` summary so dependencies and file ownership are explicit.

### Changed
- One shared feature-branch worktree across all waves — no per-task worktree, no merge step between waves.
- Controller (not implementers) runs `git add` / `git commit` to eliminate `.git/index.lock` races. Implementers report changed paths instead.

## [0.2.0] - 2026-04-27

### Added
- Initial public release of the UberDev marketplace and `uberdev` plugin.
- `/solve <issue-number>`: spawns an autonomous Claude agent in a new terminal session (cmux / Ghostty / iTerm / Terminal.app / nohup) with tier-aware triage — trivial issues skip the brainstorm; large ones get the full plan-and-review pipeline.
- `/issue <description>`: eight-phase pipeline that creates a well-investigated, deduped, label-validated GitHub issue, including codebase search, full-text dedup against closed issues, commitlint scope validation, and a triage hint that `/solve` reads later.
- Bundled skills: `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch` — `/solve` runs standalone with no Superpowers / pr-review-toolkit / code-simplifier dependency.
- Bundled review agents: `code-reviewer`, `code-simplifier`, `comment-analyzer`, `plan-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`.
- Bundled commands: `/uberdev:review-pr`, `/uberdev:simplify`.

### Changed
- Documentation: README expanded with `Updating` section explaining manual vs auto-update for third-party marketplaces (`docs:` commit `007537b` on 2026-04-27 superseded by this release).

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/TheFJK/UberDev/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/TheFJK/UberDev/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/TheFJK/UberDev/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/TheFJK/UberDev/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/TheFJK/UberDev/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/TheFJK/UberDev/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
