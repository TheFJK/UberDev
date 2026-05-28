---
description: "Autonomous loop that dispatches /uberdev:orchestrator (solve + push PR) → auto /review-pr (trust-signal) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent)."
argument-hint: "<issue> [<issue> ...] [--max-cycles=N] [--max-parallel=N] [--barrier-timeout=N] [--only-mine] [--dry-run] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task"]
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
- `--only-mine` — only enqueue `review-pr-finding` issues authored by `$GH_USER`.
- `--dry-run` — print planned cycle 1 dispatch + watch-loop preview, exit 0. No `/uberdev:orchestrator`, no `/merge`, no `/review-pr` is invoked.
- `--backend=<name>` — pin a dispatch backend (`claude-bg` | `wezterm` | `background`); otherwise auto-resolved once by Phase 0 preflight and frozen for the run.

**Merge barrier (issue #211).** `/merge` no longer fires per-PR the instant a PR turns GREEN.
Instead, `/goal` holds until every PR in the cycle's batch is in a terminal state
(`merged`, `merge-failed`, `yellow-held`, `red-held`, or `green`). PRs touching shared
mutable manifests (e.g. the uberdev version-bump triplet) merge sequentially in
PR-number-ascending order, with `git fetch origin main` + rebase between each. When a
held PR's `review-pr-finding` unblock-issue is in flight, the barrier holds until the
unblock-issue closes AND the held PR's trust-trail label transitions to `review-pr:green`.
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

**Important:** settings like `"skipDangerousModePermissionPrompt": true` in your own `~/.claude/settings.json` are **NOT** sufficient when cmux (or another daemon manager) injects its own `--settings <blob>` into the bg session's `respawnFlags` via the parent process — the user-settings file is shadowed at bg-dispatch time, not modified on disk. The env-var path (`SKIP_PERMISSIONS=1` → `--dangerously-skip-permissions` in argv) is what actually unblocks the loop.

Standalone `/uberdev:turbo` and `/uberdev:solve` defensively `unset SKIP_PERMISSIONS` so a stale shell export from an earlier `/goal` run cannot silently elevate them. Outside `/goal`, operator-gated permissions are preserved by design (RFC 0005 §2.3 scoped-relaxation contract).

Now invoke the `uberdev:goal-pipeline` skill — it owns the 5-phase pipeline (preflight, dispatch, watch, collect-next, converge/halt). The skill renders inline, so `$ARGUMENTS` remains in scope for its logic.
