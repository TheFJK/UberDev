# Orchestrator — tier profiles, failure recovery, logging, and the deleted research cache

Reference for `skills/orchestrator/SKILL.md`. Per-tier fanout, the retry-then-fall-back contract every dispatch obeys, the log line shape, standalone invocation, and the decision record for the Phase 1 research cache that was deleted (do not reintroduce it without reading the binding rules there).

### Phase 1 research cache — deleted (decision record, #308 / RFC 0012 §3.5)

Earlier revisions carried a ~200-line artifact-reuse short-circuit here: a freshness predicate over `.uberdev/research/issue-<N>/<topic>.md` that gated per-topic reuse of cached research before the fanout. It was deleted after a live repo-wide grep verified the cache had **zero writers**: fresh runs write only to `$UBERDEV_RESEARCH_ROOT/<RUN_ID>/` (Phase 0), `/issue` stopped persisting research under `issue-<N>/` back in issue #14 (the last readers of that path were retired in #518), and no other phase, agent, or skill ever wrote those paths — the predicate could never fire and was pure dead weight on every design-rung run.

Binding rules for any future reintroduction:

- **Write-back must resolve the MAIN repo root via `git rev-parse --git-common-dir`** — e.g. `CACHE_ROOT="$(dirname "$(git rev-parse --git-common-dir)")/.uberdev/research"`. Under `claude --bg --worktree`, `--show-toplevel` returns the *worktree* top (correct for per-run artifacts, see Phase 0 step 2) — a write-back keyed on it would land in ephemeral worktrees and silently reproduce the zero-writers defect this deletion removed.
- **Reintroduce as a thin preflight probe only if reuse proves valuable** — never re-grow an inline freshness predicate in this skill body.
- **Trust boundary unchanged:** reused artifacts stay untrusted on reuse and MUST be wrapped per the "Trust boundary" section (`source="cached-research-issue-<N>"`). Freshness is a cache signal, never a trust upgrade.

## Tier profiles (summary)

| Tier | Research fanout | Spec reviewer | Plan reviewer | Root-owned planning research | Post-impl review | pr-test-analyzer |
|---|---|---|---|---|---|---|
| trivial | (orchestrator should not be invoked) | — | — | — | — | — |
| small | 1 (codebase only) | none | none | N/A (orchestrator bypassed) | — (orch not invoked) | — |
| medium | 6 (always fresh) | always | always | 3 base (+ security when high-risk) | post-PR-push (via /review-pr Phase 1) | pre-merge (dispatched from `subagent-driven-dev` Step 4.5) |

`--turbo` orthogonally skips Phase 2 Q&A (replaced with auto-pick + questions.md log). Tier classification rule: same as `/solve` triage table (read from issue labels + body).

## Failure recovery summary

For every subagent dispatch:
1. Verify artifact (path exists, size, expected sections, sha match) and YAML return parses.
2. On failure: re-dispatch ONCE with verification feedback prepended.
3. After 2 attempts: fall back to in-main equivalent for that single phase, log warning, continue.
4. Hard timeouts: 5min research, 10min spec/plan. Timeout counts toward the 2-attempt budget.

The three planning-research artifacts are a pre-dispatch evidence gate: after the single targeted retry, invalid path validation returns `status: BLOCKED`. It does not use the in-main fallback because doing so would bypass the root-owned research contract.

Spec-reviewer fix loop max: 2 reviser cycles.

## Logging

For every phase, write a one-line log to `$RESEARCH_DIR_ABS/orchestrator.log`:
```
[<ISO ts>] phase=<name> agent=<name> status=<status> attempt=<n> note=<...>
```

This is the trail for the issue's "telemetry/measurement" acceptance criterion.

## Standalone invocation (no /solve or /turbo)

The skill can be invoked directly: `/uberdev:orchestrator solve issue #N`. Behaves the same — useful for testing or for users who want orchestrator-style pipeline without the spawning overhead of `/solve`.
