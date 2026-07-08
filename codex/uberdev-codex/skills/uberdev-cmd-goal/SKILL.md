---
name: uberdev-cmd-goal
description: "Use when the user wants to autonomous loop that dispatches /uberdev:orchestrator (solve + push PR) → auto /review-pr (trust-signal) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent). Invokable explicitly as $uberdev-cmd-goal. Original description: Autonomous loop that dispatches /uberdev:orchestrator (solve + push PR) → auto /review-pr (trust-signal) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent)."
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

Original argument hint: `<issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--only-mine] [--dry-run] [--backend=<name>]`

---



# Goal — Autonomous Convergence Loop

Autonomous convergence orchestrator that drives one or more GitHub issues to merged-and-closed by dispatching `/uberdev:orchestrator --turbo` (solve + push PR) → auto `/review-pr` (trust-signal) → `/merge` ONLY when the trust trail is GREEN, recursing on `BLOCKER` / `CRITICAL` `review-pr-finding` issues filed by that review pass. `YELLOW` (CRITICAL findings) and `RED` (BLOCKER findings or `halted_due_to_overflow`) PRs are HELD — never merged automatically — and are re-reviewed only when every issue listed in their `Blocks:` PR-body line closes. The loop terminates on convergence (queue empty AND all open `/goal`-owned PRs are terminal) or on one of seven circuit breakers. The four loop-logic breakers are `max_cycles` (hard cycle ceiling, default 5), `nonconvergence` (queue-fingerprint repeat across cycles), `stuck_loop` (4-hour wall-clock cap), and `merge_failed` (any `/merge` invocation exits non-zero); three further surfaced-failure guards — `gh_api_failed`, `unknown_merge_result`, and `queue_empty_not_converged` — round out the `GOAL_CIRCUIT_BREAKER_REASONS` enum owned by the goal-pipeline skill. Per RFC 0005 §2.3 the loop applies three scoped relaxations to the global UberDev rules — see the call-out below.

**Usage:** `/uberdev:goal <issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--only-mine] [--dry-run] [--backend=<name>]`

- `--max-cycles=N` — hard ceiling on cycle count (default `5`, range `1..20`; reads `goal.max_cycles` config / `UBERDEV_GOAL_MAX_CYCLES` env).
- `--max-parallel=N` — cap the per-cycle `/uberdev:orchestrator` dispatch fan-out at N (default 3, range 1–10).
  Queue items beyond the cap roll over to the next cycle. Resolved via the same precedence as
  `--max-cycles`: CLI flag > `UBERDEV_GOAL_MAX_PARALLEL` env > `goal.max_parallel` config key > default.
  Values outside `[1, 10]` fall back to the default 3 (with a stderr warning + audit event).
- `--barrier-timeout=N` — wall-clock cap (seconds) on the wait-for-all merge barrier in Phase 2 step 2c
  (default 14400 = 4h, range 60..86400). Timeout escalates to the existing `stuck_loop` circuit-breaker
  reason; no new breaker enum is added. Resolved via the same precedence as `--max-cycles`.
- `--only-mine` — only enqueue `review-pr-finding` issues authored by `$GH_USER`. **Requires a single `gh` identity (issue #291):** it filters on `.author.login`, so it assumes the detached bg `/review-pr` agent that files the findings runs under the same `gh` identity as the watcher. On a CI-token / multi-identity setup the bg-filed findings carry a different author and would be silently dropped (false convergence with open blockers) — OMIT `--only-mine` there. Opt-in, OFF by default.
- `--dry-run` — print planned cycle 1 dispatch + watch-loop preview, exit 0. No `/uberdev:orchestrator`, no `/merge`, no `/review-pr` is invoked.
- `--watch-passes=N` — run a bounded number of Phase-2 poll passes per fence invocation, then exit for re-invocation (0=unbounded default).
- `--watch-budget=SECS` — bound each Phase-2 fence to a wall-clock budget, then exit for re-invocation. Default 0 (unbounded) — **except under the Claude-Code Bash tool** (`CLAUDECODE` env marker), where an otherwise-unbounded run defaults to `480` (#301, RFC 0012 §3.3 goal-R1 item 3): the tool's 600s call cap minus headroom for one worst-case serial gh walk, so the fence exits 42 for re-invocation instead of being SIGTERMed mid-pass. Pass an explicit `--watch-budget=0` (or `UBERDEV_GOAL_WATCH_BUDGET=0`) to force the unbounded loop there.
- `GOAL_SINGLE_TICK=1` (env) — shorthand for `--watch-passes=1`.
- `--backend=<name>` — pin a dispatch backend (`claude-bg` | `wezterm` | `background`); otherwise auto-resolved once by Phase 0 preflight and frozen for the run.

**Merge barrier (issue #211).** `/merge` no longer fires per-PR the instant a PR turns GREEN.
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

## Scoped relaxations (RFC 0005 §2.3)

- `feedback_merge_independent.md`: `/merge` auto-chain is allowed **inside `/goal` only** (enforced by `UBERDEV_GOAL_ID` env-var provenance check — outside `/goal` the existing manual-invocation rule still binds).
- `feedback_brainstorm_no_gates.md`: the dispatched orchestrator runs non-interactive (no human gates) because `/goal` Phase 1 invokes `/uberdev:orchestrator --turbo` directly via `claude --bg`; parallel research + always-on agent reviewers still run.
- **RED-override NEVER inherited:** `--i-know-what-im-doing` is NOT threaded through any `/goal` logic — RED PRs (BLOCKER findings or `halted_due_to_overflow`) cannot be merged inside `/goal` even if the operator passes the override to a downstream `/merge` (D14). The flag is mentioned here exactly once, in this negative call-out, by design.

## Permission requirements (cmux/hooks caveat)

`/goal` runs each dispatched bg `/uberdev:orchestrator` agent in `bypassPermissions` mode via a **pair** of argv flags — `--dangerously-skip-permissions` AND `--permission-mode bypassPermissions` — so the autonomous loop does not stall on cmux's `PermissionRequest` hook (or any other `--settings`-injected `PreToolUse` hook). The two flags target **different mechanisms** and both are needed (belt-and-suspenders, per #246):

- `--dangerously-skip-permissions` short-circuits the runtime permission-check codepath (the historical bypass).
- `--permission-mode bypassPermissions` pins the bg session UI cycle ring; without an explicit setting it defaults to `auto`, which is exactly the mode that silently breaks Search and other agent tools that the loop relies on.

See `plugins/uberdev/lib/dispatch.sh:192-198` for the full rationale. This is set by `goal-pipeline/SKILL.md` Phase 0 via `export SKIP_PERMISSIONS=1` and propagated through `BG_TURBO_ENV` in `lib/dispatch.sh` to every nested child dispatch (`/uberdev:orchestrator` → `subagent-driven-dev`); the SKIP_PERMISSIONS env-var resolves to the paired flags inside `uberdev_dispatch_resolve_env`.

**Important:** settings like `"skipDangerousModePermissionPrompt": true` in your own `~/.codex/settings.json` are **NOT** sufficient when cmux (or another daemon manager) injects its own `--settings <blob>` into the bg session's `respawnFlags` via the parent process — the user-settings file is shadowed at bg-dispatch time, not modified on disk. The env-var path (`SKIP_PERMISSIONS=1` → `--dangerously-skip-permissions` in argv) is what actually unblocks the loop.

Standalone `/uberdev:turbo` and `/uberdev:solve` defensively `unset SKIP_PERMISSIONS` so a stale shell export from an earlier `/goal` run cannot silently elevate them. Outside `/goal`, operator-gated permissions are preserved by design (RFC 0005 §2.3 scoped-relaxation contract).

## Execution contract — bash ≥ 4 required (issue #294)

`/goal`'s watch loop locates each PR's `/review-pr` verdict by iterating unquoted globs (`uberdev_goal_locate_review_pr_audit_by_pr` in `lib/goal-state.sh`). That relies on bash's **"unmatched glob → expands to nothing / literal"** semantics. **zsh instead fatals with `no matches found`**, and macOS's stock `/bin/bash` is 3.2 (no `declare -A`, no `mapfile`). So **the whole `/goal` run requires bash ≥ 4.**

The Claude-Code Bash tool runs every SKILL.md fence under `/bin/zsh` (where `BASH_VERSINFO` is unset). To keep `/goal` runnable, Phase 0 step 0 resolves the interpreter instead of dead-ending:

- **Already under bash ≥ 4** (e.g. CI, or an explicit `bash`-invoked fence): proceed.
- **Not bash ≥ 4, but a bash ≥ 4 binary is discoverable** (checked in order: `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `command -v bash` — each version-verified ≥ 4): Phase 0 publishes it as the exported `UBERDEV_GOAL_BASH`. If the fence was invoked as a real shebang **script file** it `exec`s that script under `UBERDEV_GOAL_BASH`; for an **inline** `zsh -c` body (no script path to re-feed) it proceeds and prints the resolved path. **Run `/goal`'s subsequent SKILL.md fences under `$UBERDEV_GOAL_BASH`** — e.g. by invoking each fence as `"$UBERDEV_GOAL_BASH" -c '<fence body>'`, or by ensuring the Bash tool's shell is bash ≥ 4 for the duration of the run. The bash-requiring glob lives in the Phase 2 watch loop; Phase 0/1's own steps are bash-safe under zsh, but the watch loop is NOT.
- **No bash ≥ 4 anywhere**: Phase 0 exits 2 with `brew install bash`. This is the only case where `/goal` genuinely cannot run.

A driving harness that bounds the watch loop (via `--watch-passes` / `--watch-budget` / `GOAL_SINGLE_TICK=1`) must honor the Phase-2 fence's exit contract: exit `0` = drained, proceed to Phase 3; exit `42` = work still in flight, re-invoke the Phase-2 fence; exit `1` = halt (a circuit breaker, or a fail-loud run-state-flush failure). A harness SIGTERM (e.g. the Bash tool's 600s call cap landing mid-pass) also resolves to exit `42`: the TERM trap persists run-state, emits a `goal_reaper_skipped` audit row (`reason=harness_term`), and does **NOT** reap the bg solver agents (#301 — pre-#301 the TERM trap reaped, so the harness cap killed every live solver). Operator abort = INT (Ctrl-C), which still reaps.

> **TL;DR for operators:** on stock macOS run `brew install bash` once (gives `/opt/homebrew/bin/bash` 5.x). `/goal` then auto-discovers it. The old behavior — a hard `exit 2` on the first fence even with bash 5 installed — is fixed.

Now invoke the `uberdev:goal-pipeline` skill — it owns the 5-phase pipeline (preflight, dispatch, watch, collect-next, converge/halt). The skill renders inline, so `$ARGUMENTS` remains in scope for its logic.
