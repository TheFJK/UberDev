---
name: uberdev-cmd-goal
description: "Use when the user wants to autonomous loop that solves a queue of GitHub issues (one Workflow-native solver fleet per cycle) → auto /review-pr (trust-signal) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent). Invokable explicitly as $uberdev-cmd-goal. Original description: Autonomous loop that solves a queue of GitHub issues (one Workflow-native solver fleet per cycle) → auto /review-pr (trust-signal) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent)."
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/goal`). On Codex:

- **`$ARGUMENTS`** below = the user's free-text request (the words after the
  command name, or your whole task description if invoked implicitly).
- **`Task` tool** calls → use `spawn_agent`; collect results with `wait_agent`
  (see ~/.agents/skills/using-uberdev/references/codex-tools.md for the
  named-agent mapping).
- **`Skill` tool** invocations → skills load natively; just follow the named
  skill's instructions.
- **`Workflow` tool** (testers/uberscan/ubersimplify) → no Codex equivalent;
  follow the skill's `## No-Workflow fallback` section instead.
- **`MultiEdit`** → apply edits with your native file-edit tool.

Original argument hint: `<issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--review-grace-secs=N] [--max-watch-ticks=N] [--only-mine] [--dry-run] [--resume] [--backend=<name>]`

---



# Goal — Autonomous Convergence Loop

Autonomous convergence orchestrator that drives one or more GitHub issues to merged-and-closed. Each cycle claims its issues, hands them to ONE run of the Workflow-native solver fleet (`skills/solve-fleet/workflow.js` — the same fleet `/solve` and `/turbo` use, one worktree-isolated solver per issue), then drives auto `/review-pr` (trust-signal) → `/merge` ONLY when the trust trail is GREEN, recursing on `BLOCKER` / `CRITICAL` `review-pr-finding` issues filed by that review pass. `YELLOW` (CRITICAL findings) and `RED` (BLOCKER findings or `halted_due_to_overflow`) PRs are HELD — never merged automatically — and are re-reviewed only when every issue listed in their `Blocks:` PR-body line closes. The loop terminates on convergence (queue empty AND all open `/goal`-owned PRs are terminal) or on one of seven circuit breakers. The four loop-logic breakers are `max_cycles` (hard cycle ceiling, default 5), `nonconvergence` (queue-fingerprint repeat across cycles), `stuck_loop` (4-hour wall-clock cap), and `merge_failed` (any `/merge` invocation exits non-zero); three further surfaced-failure guards — `gh_api_failed`, `unknown_merge_result`, and `queue_empty_not_converged` — round out the `GOAL_CIRCUIT_BREAKER_REASONS` enum owned by the goal-pipeline skill. Per RFC 0005 §2.3 the loop applies three scoped relaxations to the global UberDev rules — see the call-out below.

**Usage:** `/uberdev:goal <issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--review-grace-secs=N] [--max-watch-ticks=N] [--only-mine] [--dry-run] [--resume] [--backend=<name>]`

- `--max-cycles=N` — hard ceiling on cycle count (default `5`, range `1..20`; reads `goal.max_cycles` config / `UBERDEV_GOAL_MAX_CYCLES` env).
- `--max-parallel=N` — cap how many issues one cycle claims and hands to the solver fleet (default 3, range 1–10).
  Queue items beyond the cap roll over to the next cycle. Resolved via the same precedence as
  `--max-cycles`: CLI flag > `UBERDEV_GOAL_MAX_PARALLEL` env > `goal.max_parallel` config key > default.
  Values outside `[1, 10]` fall back to the default 3 (with a stderr warning + audit event).
- `--barrier-timeout=N` — wall-clock cap (seconds) on the wait-for-all merge barrier in `lib/goal-watch.sh` step 2c
  (default 14400 = 4h, range 60..86400). Timeout escalates to the existing `stuck_loop` circuit-breaker
  reason; no new breaker enum is added. Resolved via the same precedence as `--max-cycles`.
- `--review-grace-secs=N` — how long (seconds) the watch loop waits for the SOLVER'S OWN `/review-pr`
  verdict to land before `/goal` dispatches a review of its own (default 3600 = 60m, range
  60..86400; same precedence as `--max-cycles`: CLI flag > `UBERDEV_GOAL_REVIEW_GRACE_SECS` env >
  `goal.review_grace_secs` config key > default). The leaf solver runs its own review ~20m after
  pushing and goes idle in that window, so "agent idle ⇒ review done" is false — the grace is what
  stops `/goal` firing redundant reviews and prematurely red-holding a PR whose GREEN verdict simply
  has not landed yet. Lower it when your solvers do not self-review; raise it on a slow CI.
  (Parsed since issue #220; documented here from #301 — it was reachable but invisible.)
- `--only-mine` — only enqueue `review-pr-finding` issues authored by `$GH_USER`. **Requires a single `gh` identity (issue #291):** it filters on `.author.login`, so it assumes the `/review-pr` agent that files the findings runs under the same `gh` identity as the watcher. On a CI-token / multi-identity setup the bg-filed findings carry a different author and would be silently dropped (false convergence with open blockers) — OMIT `--only-mine` there. Opt-in, OFF by default.
- `--dry-run` — print planned cycle 1 dispatch + watch-loop preview, exit 0. No solver, no `/merge`, no `/review-pr` is invoked.
- `--resume` — rehydrate the run this host last started (via the fixed-path `goal-active-id.txt` pointer) instead of minting a new `GOAL_ID`. This is the recovery for RFC 0015 §6 R-1: the Workflow-native solvers do not survive the session, so a closed/compacted/`/clear`ed session leaves a real run on disk with live state and dead children. `--resume` picks it back up; `lib/goal-abort.sh` is the alternative that releases the claims and reaps instead.
- `--watch-passes=N` — run a bounded number of watch poll passes per `lib/goal-watch.sh` invocation, then exit for re-invocation (0=unbounded default).
- `--watch-budget=SECS` — bound each `lib/goal-watch.sh` invocation to a wall-clock budget, then exit for re-invocation. Default 0 (unbounded) — **except under the Claude-Code Bash tool** (`CLAUDECODE` env marker), where an otherwise-unbounded run defaults to `480` (#301, RFC 0012 §3.3 goal-R1 item 3): the tool's 600s call cap minus headroom for one worst-case serial gh walk, so the fence exits 42 for re-invocation instead of being SIGTERMed mid-pass. Pass an explicit `--watch-budget=0` (or `UBERDEV_GOAL_WATCH_BUDGET=0`) to force the unbounded loop there.
- `--max-watch-ticks=N` — how many `lib/goal-watch.sh` invocations `skills/goal-pipeline/workflow.js` relays in ONE cycle before the CB3 tick breaker halts deterministically (default `40`, range `1..500`; same precedence as `--max-cycles`: CLI flag > `UBERDEV_GOAL_MAX_WATCH_TICKS` env > `goal.max_watch_ticks` config key > default). This is the driver-side complement to `--watch-budget`: the budget bounds ONE invocation, this bounds how many of them a cycle gets. Total worst-case watch wall-clock per cycle ≈ `max_watch_ticks × watch_budget`.
- `GOAL_SINGLE_TICK=1` (env) — shorthand for `--watch-passes=1`.
- `--backend=<name>` — pin a dispatch backend; otherwise auto-resolved once by Phase 0 preflight and frozen for the run. Since RFC 0015 `auto` resolves to `workflow` on every Claude host and `/goal`'s solvers run inside the calling session's Workflow runtime. The detached backends (`claude-bg` — deprecated, removal target v1.0.0 — `wezterm`, `background`, `codex`) are still reachable, but only by naming one explicitly: there is no demotion path back onto them.

**Merge barrier (issue #211).** `/merge` does not fire per-PR the instant a PR turns GREEN.
Instead, `/goal` holds until every PR in the cycle's batch is in a terminal state
(`merged`, `merge-failed`, `yellow-held`, `red-held`, or `green`). PRs touching shared
mutable manifests (e.g. the uberdev version-bump triplet) merge sequentially in
PR-number-ascending order: exactly ONE merge is dispatched at a time and the next
green PR becomes eligible only after the prior one lands (a `git fetch origin main`
+ rebase happens between each). A held PR holds the barrier only while one of its
`Blocks: #N` unblock-issues is still open; once all its blockers close it becomes
pseudo-terminal and stops gating the other PRs (its re-review either cleared it
green — detected via the `uberdev-approved` trust-trail label — or it stays held).
A wall-clock cap (default 4h, see `--barrier-timeout=N`) escalates a stuck barrier to
`stuck_loop` halt.

**Mandatory version bump before landing (issue #364).** The fleet solvers are forbidden
from bumping the project version — N solvers off one base all resolve the same next
version and the duplicate change auto-merges without a conflict. `/goal` therefore adds
the bump itself, at the one strictly-serialized point in the run: immediately before it
dispatches `/merge` for the lowest green PR. The next version comes from the **base
branch's** manifest plus the PR's conventional-commit type (`feat:` → minor, `!` /
`BREAKING CHANGE:` → major, everything else → patch); `lib/bump-version.sh` moves all
seven CI-locked surfaces in a throwaway worktree, the CHANGELOG stub is replaced with an
entry derived from the PR, and the result is pushed as `chore(release): vX.Y.Z` (never
`--force`). If the bump cannot be guaranteed the step **fails closed**: `/merge` is not
dispatched, the PR stays `green` for a later pass, and a `goal_merge_deferred` audit row
with `reason=version_bump_failed` names the stage that stopped it. A PR that already
carries a strictly-greater version is left alone (the collision chain renumbers it), and
a repo that carries no version surfaces is skipped rather than blocked.

Pushing that commit onto an already-reviewed head is paid for on both sides. `/merge`
Phase 1.4 PATH_2 resolves its trust head through
`skills/merge-pipeline/lib/release-anchor.sh` first, so a `chore(release):` commit that is
**provably inert** — single parent, exact subject, version-surfaces-only diff whose lines
are byte-identical once SemVer tokens are normalised away — does not invalidate the
`/review-pr` trail beneath it; anything unproven still gates exactly as before. And
because the push restarts the PR's checks, `/goal` defers the `/merge` dispatch for a pass
(`goal_merge_deferred reason=ci_restarted_by_version_bump`) and keeps deferring while any
check is still running (`reason=ci_pending`) rather than burning merge attempts on a
pending rollup.

## Scoped relaxations (RFC 0005 §2.3)

- `feedback_merge_independent.md`: `/merge` auto-chain is allowed **inside `/goal` only** (enforced by `UBERDEV_GOAL_ID` env-var provenance check — outside `/goal` the existing manual-invocation rule still binds).
- `feedback_brainstorm_no_gates.md`: the solvers run non-interactive (no human gates) — `lib/goal-phase0.sh` exports `AUTO_MODE=1` and the claim relay arms `lib/solve-launcher.sh` with `--turbo`, so the fleet runs unattended. Parallel research + always-on writer/reviewer pairs still run inside the fleet.
- **RED-override NEVER inherited:** `--i-know-what-im-doing` is NOT threaded through any `/goal` logic — RED PRs (BLOCKER findings or `halted_due_to_overflow`) cannot be merged inside `/goal` even if the operator passes the override to a downstream `/merge` (D14). The flag is mentioned here exactly once, in this negative call-out, by design.

## Permission requirements (cmux/hooks caveat)

Since RFC 0015 §5 the default `/goal` solvers are **Workflow agents in the calling session**, so they inherit that session's permission tier — there is no per-child argv to set (RFC 0015 §6 R-1b). The paragraphs below therefore apply to the **explicit detached backends** (`--backend=claude-bg|wezterm|background`) and to the `/merge` + `/review-pr` children `lib/goal-watch.sh` still dispatches through `lib/dispatch.sh`.

On those paths `/goal` runs each dispatched bg agent in `bypassPermissions` mode via a **pair** of argv flags — `--dangerously-skip-permissions` AND `--permission-mode bypassPermissions` — so the autonomous loop does not stall on cmux's `PermissionRequest` hook (or any other `--settings`-injected `PreToolUse` hook). The two flags target **different mechanisms** and both are needed (belt-and-suspenders, per #246):

- `--dangerously-skip-permissions` short-circuits the runtime permission-check codepath (the historical bypass).
- `--permission-mode bypassPermissions` pins the bg session UI cycle ring; without an explicit setting it defaults to `auto`, which is exactly the mode that silently breaks Search and other agent tools that the loop relies on.

See `plugins/uberdev/lib/dispatch.sh` for the full rationale. This is set by `lib/goal-phase0.sh` via `export SKIP_PERMISSIONS=1` and propagated through `BG_TURBO_ENV` in `lib/dispatch.sh` to every detached child dispatch; the SKIP_PERMISSIONS env-var resolves to the paired flags inside `uberdev_dispatch_resolve_env`.

**Important:** settings like `"skipDangerousModePermissionPrompt": true` in your own `~/.codex/settings.json` are **NOT** sufficient when cmux (or another daemon manager) injects its own `--settings <blob>` into the bg session's `respawnFlags` via the parent process — the user-settings file is shadowed at bg-dispatch time, not modified on disk. The env-var path (`SKIP_PERMISSIONS=1` → `--dangerously-skip-permissions` in argv) is what actually unblocks the loop.

Standalone `/uberdev:turbo` and `/uberdev:solve` defensively `unset SKIP_PERMISSIONS` so a stale shell export from an earlier `/goal` run cannot silently elevate them. Outside `/goal`, operator-gated permissions are preserved by design (RFC 0005 §2.3 scoped-relaxation contract).

## Execution contract — bash ≥ 4 required (issue #294)

`/goal`'s watch loop locates each PR's `/review-pr` verdict by iterating unquoted globs (`uberdev_goal_locate_review_pr_audit_by_pr` in `lib/goal-state.sh`). That relies on bash's **"unmatched glob → expands to nothing / literal"** semantics. **zsh instead fatals with `no matches found`**, and macOS's stock `/bin/bash` is 3.2 (no `declare -A`, no `mapfile`). So **the whole `/goal` run requires bash ≥ 4.**

The Claude-Code Bash tool runs SKILL.md fences under `/bin/zsh` (where `BASH_VERSINFO` is unset). `lib/goal-phase0.sh` therefore resolves the interpreter instead of dead-ending:

- **Already under bash ≥ 4** (e.g. CI, or an explicit `bash lib/goal-phase0.sh` run): proceed, publishing the running interpreter (`$BASH`) as `UBERDEV_GOAL_BASH`.
- **Not bash ≥ 4, but a bash ≥ 4 binary is discoverable** (checked in order: `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `command -v bash` — each version-verified ≥ 4): it is published as the exported `UBERDEV_GOAL_BASH`, and because the phase logic is now a real shebang **script file**, the resolver simply `exec`s itself under that interpreter. This is the concrete win of moving the phases out of SKILL.md fences: the inline-`zsh -c` case that could not be re-exec'd — and had to proceed on a published-contract promise instead — no longer exists on the default path.
- **No bash ≥ 4 anywhere**: `lib/goal-phase0.sh` exits 2 with `brew install bash`. This is the only case where `/goal` genuinely cannot run.

**The contract has to reach Phases 1/2/3, not just Phase 0.** Re-exec'ing fixes the process that re-execs; `lib/goal-phase1.sh`, `lib/goal-watch.sh` and `lib/goal-phase3.sh` are launched as *separate* processes by the driver's relays, and PATH `bash` on stock macOS is 3.2 — where `lib/goal-watch.sh` dies on `active_issues[@]: unbound variable`, a non-`0`/`42` status the driver reports as `haltReason="watch_script_error"` on cycle 1. So Phase 0 also ships the resolved interpreter in the args envelope as `config.bashBin`, and `skills/goal-pipeline/workflow.js` runs every relay command as `"$bashBin" lib/goal-*.sh` (falling back to PATH `bash` only when the envelope carries no absolute path).

The watch stage keeps its documented exit contract, and `skills/goal-pipeline/workflow.js` is the harness that honours it: exit `0` = drained, proceed to collect; exit `42` = work still in flight, re-invoke `lib/goal-watch.sh`; exit `1` = halt (a circuit breaker, or a fail-loud run-state-flush failure). A harness SIGTERM (e.g. the Bash tool's 600s call cap landing mid-pass) also resolves to exit `42`: the TERM trap persists run-state, emits a `goal_reaper_skipped` audit row (`reason=harness_term`), and does **NOT** reap the solver agents (#301). Operator abort = INT (Ctrl-C), which still reaps.

> **TL;DR for operators:** on stock macOS run `brew install bash` once (gives `/opt/homebrew/bin/bash` 5.x). `/goal` then auto-discovers it. The old behavior — a hard `exit 2` on the first fence even with bash 5 installed — is fixed.

## Session lifetime (RFC 0015 §6 R-1)

The default solvers are Workflow agents in **this** session: if the session ends — closed, `/clear`, compacted — every in-flight solver dies with it. The on-disk run-state does not: `--resume` picks the run back up from the `goal-active-id.txt` pointer, and `plugins/uberdev/lib/goal-abort.sh` is the other half (release the `uberdev:active` claims and reap). Use `--backend=claude-bg` for the deliberate fire-and-forget case until its v1.0.0 removal.

Now invoke the `uberdev:goal-pipeline` skill — it runs the `lib/goal-phase0.sh` preflight and relays its args envelope into `Workflow({scriptPath: "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/goal-pipeline/workflow.js"}, <args>)`, which owns the cycle loop. The skill renders inline, so `$ARGUMENTS` remains in scope for the preflight.
