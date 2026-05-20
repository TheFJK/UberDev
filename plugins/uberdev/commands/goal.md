---
description: "Autonomous loop that chains /turbo → /review-pr (auto) → /merge if GREEN, recursing on BLOCKER/CRITICAL review-pr-finding issues until convergence or circuit-breaker halt. Inherits the dispatch backend resolver from /solve and /turbo. Inside /goal only: auto-chain to /merge is allowed (carve-out from feedback_merge_independent)."
argument-hint: "<issue> [<issue> ...] [--max-cycles=N] [--only-mine] [--dry-run] [--backend=<name>]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Goal — Autonomous Convergence Loop

Autonomous convergence orchestrator that drives one or more GitHub issues to merged-and-closed by chaining `/turbo` (solve + push PR) → auto `/review-pr` (trust-signal) → `/merge` ONLY when the trust trail is GREEN, recursing on `BLOCKER` / `CRITICAL` `review-pr-finding` issues filed by that review pass. `YELLOW` (CRITICAL findings) and `RED` (BLOCKER findings or `halted_due_to_overflow`) PRs are HELD — never merged automatically — and are re-reviewed only when every issue listed in their `Blocks:` PR-body line closes. The loop terminates on convergence (queue empty AND all open `/goal`-owned PRs are terminal) or on one of four circuit breakers: `max_cycles` (hard cycle ceiling, default 5), `nonconvergence` (queue-fingerprint repeat across cycles), `stuck_loop` (4-hour wall-clock cap), or `merge_failed` (any `/merge` invocation exits non-zero). Per RFC 0005 §2.3 the loop applies three scoped relaxations to the global UberDev rules — see the call-out below.

**Usage:** `/uberdev:goal <issue> [<issue> ...] [--max-cycles=N] [--only-mine] [--dry-run] [--backend=<name>]`

- `--max-cycles=N` — hard ceiling on cycle count (default `5`, range `1..20`; reads `goal.max_cycles` config / `UBERDEV_GOAL_MAX_CYCLES` env).
- `--only-mine` — only enqueue `review-pr-finding` issues authored by `$GH_USER`.
- `--dry-run` — print planned cycle 1 dispatch + watch-loop preview, exit 0. No `/turbo`, no `/merge`, no `/review-pr` is invoked.
- `--backend=<name>` — pin a dispatch backend (`claude-bg` | `wezterm` | `background`); otherwise auto-resolved once by Phase 0 preflight and frozen for the run.

## Scoped relaxations (RFC 0005 §2.3)

- `feedback_merge_independent.md`: `/merge` auto-chain is allowed **inside `/goal` only** (enforced by `UBERDEV_GOAL_ID` env-var provenance check — outside `/goal` the existing manual-invocation rule still binds).
- `feedback_brainstorm_no_gates.md`: `/turbo` runs non-interactive (no human gates) because `/goal` dispatches `/turbo --turbo`; parallel research + always-on agent reviewers still run.
- **RED-override NEVER inherited:** `--i-know-what-im-doing` is NOT threaded through any `/goal` logic — RED PRs (BLOCKER findings or `halted_due_to_overflow`) cannot be merged inside `/goal` even if the operator passes the override to a downstream `/merge` (D14). The flag is mentioned here exactly once, in this negative call-out, by design.

Now invoke the `uberdev:goal-pipeline` skill — it owns the 5-phase pipeline (preflight, dispatch, watch, collect-next, converge/halt). The skill renders inline, so `$ARGUMENTS` remains in scope for its logic.
