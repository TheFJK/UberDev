---
name: solve-pipeline
description: "Shared launcher pipeline for /uberdev:solve and /uberdev:turbo. Parses arguments, classifies tier, writes tier-appropriate prompt, dispatches an autonomous agent through the resolved backend per issue. The executable lives in lib/solve-launcher.sh and runs as ONE Bash call; this skill is the contract + triage reference. Invoked by both commands — never call directly."
---

# Solve Pipeline (shared contract for /solve and /turbo)

The pipeline executable is **`lib/solve-launcher.sh`** — a single bash script
the command files run as **ONE Bash tool call**:

```
bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=0 -- <user arguments>   # /solve
bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=1 --turbo -- <user arguments>   # /turbo
```

On Codex, the command-skills call the same launcher through `$PLUGIN_ROOT`.

Why one call, why a lib file (#304 root fix, RFC 0012 §3.4): Bash tool calls
share **no shell state** — the historical multi-fence pipeline silently lost
functions, arrays, and even a split `for` loop across fence boundaries — and
the Skill renderer substitutes positional `$ARGUMENTS` into SKILL.md bodies,
corrupting bare positional refs (`$N`) in inline helpers (`/solve 5 6 7`
rendered the version-gate's `local min=` as `local min="5"`). `lib/*.sh` is
never rendered and one process keeps all state alive. The launcher OWNS the `AUTO_MODE` / `UBERDEV_TURBO` /
`SKIP_PERMISSIONS` env lifecycle for its children (#97/#241 hygiene runs
in-process — the shell profile re-injects into every fresh fence, so a
prior-fence `unset` protects nothing).

## Runtime contract (binding for callers)

- Pass a Bash-tool `timeout` of **up to 600000 ms** (the tool maximum).
- For batches above **~10 issues**, run the launcher with
  `run_in_background: true` and watch it via Monitor instead: validation is 1
  gh round-trip per issue, claim writes add ~2–3 more, and serial dispatch
  costs 2–8 s per issue — the 120 s default timeout can expire mid-claim and
  strand a half-claimed batch (the rollback path runs before any abort, but
  only while the process is alive).
- The wave cap (`fanout_concurrency.solve_bg`, default 6) means different
  things per transport, and the difference is load-bearing:
  - on the **detached** backends it is **dispatch-burst chunking**, not a live
    concurrency ceiling — every backend returns immediately after spawn, so all
    dispatched agents run concurrently regardless of the cap;
  - on the **`workflow`** backend it is a **real live ceiling**: the fleet runs
    issues in `parallel()` waves of that size and each wave is a barrier, so at
    most `concurrency` solvers exist at once (further bounded by the runtime's
    own `min(16, cores-2)` cap).
- On the `workflow` backend the launcher call is short and cheap regardless of
  batch size — it stops after the claim protocol and emits args. The long-running
  work happens in the Workflow, which reports through `/workflows`.

`$ARGUMENTS` may contain **one or more issue numbers** (e.g. `42` or `5 6 7`).
The launcher validates every issue up front (Phase A, validate-all-first),
echoes one `triage:` signal line per issue, claims each issue (Step 4.5), and
then hands the batch to the resolved transport. On the default `workflow`
backend (RFC 0015) it stops at **Step 5w**: it writes
`$UBERDEV_TMPDIR/solve-fleet-manifest.json`, emits the args envelope, and the
command file mandates one `Workflow` call into
`skills/solve-fleet/workflow.js`, which runs one worktree-isolated solver agent
per issue. On a detached backend (`claude-bg` / `wezterm` / `background` /
`codex`) it instead dispatches one autonomous session per issue (Phase B) via
`lib/dispatch.sh`.
The `codex` backend is also available under Codex or via `--backend=codex`;
it runs detached `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>`.
Per-issue artifacts (`$UBERDEV_TMPDIR/solve-prompt-N.txt`,
`$UBERDEV_TMPDIR/solve-bg-stdout-N.log`, `$UBERDEV_TMPDIR/solve-codex-stdout-N.log`,
`$UBERDEV_TMPDIR/solve-codex-status-N.json`, `$UBERDEV_TMPDIR/solve-codex-result-N.md`,
`.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch) are
namespaced by issue number, so concurrent spawns are collision-free. Override flags
(`--trivial|--small|--full`, `--auto`, `--force`, routing/model/effort/service
flags, `--backend=<name>`) apply batch-wide. Monitor via `/workflows` (workflow — the
default), `claude agents` (claude-bg), visible panes (wezterm), or
PID/log/result files (background/codex).

## Constants

Bound shell-side in `lib/solve-launcher.sh` (the executable SSOT); this table
is the documentation surface.

<!-- A marker line inside the table would split it; the anchor resolves
     forward to the one row that declares the backend enum. -->
<!-- CONTRACT: dispatch-backend @"| `DISPATCH_BACKEND_ENUM` |" -->
| Name | Value (verbatim) | Where used |
|---|---|---|
| `TERMINAL_FLAG_DEPRECATED_NOTE` | see the column-0 binding in `lib/solve-launcher.sh` (verbatim note also quoted under `## Deprecated Flags` in both command files) | Phase A stderr emission on first `--terminal=` / `$SOLVE_TERMINAL` encounter. |
| `MIN_CLAUDE_VERSION` | `2.1.152` | Phase A hard gate (`claude --bg` needs 2.1.139+; `--permission-mode bypassPermissions` needs 2.1.152+, #246). |
| `DISPATCH_BACKEND_ENUM` | `auto \| workflow \| claude-bg \| wezterm \| background \| codex` | `--backend=` parser; `auto` defers to `lib/dispatch.sh` preflight, which resolves `workflow` on every Claude host (RFC 0015). `claude-bg` is deprecated — removal target v1.0.0. |
| `FANOUT_CONCURRENCY_SOLVE_BG_DEFAULT` | `6` | `MAX_PARALLEL_BG_AGENTS` default (dispatch-burst chunk size). |
| `GH_PARALLEL_CAP` | `8` | Chunk size for the parallel gh stages (validation reads, claim writes) — GitHub secondary-rate-limit courtesy. |
| `EFFORT_LEVEL_DEFAULT` | `max` | /turbo is unattended — quality > cost. |
| `EFFORT_LEVEL_ENUM` | `low \| medium \| high \| xhigh \| max \| ultra` | Public parser; `ultra` is rejected unless backend resolution selects Codex. Claude legacy effort remains the first five values. |
| `EFFORT_SOURCE_ENUM` | `cli \| env \| config \| default` | Source tag in the `effort_resolved` audit event. |
| `SOLVE_AUDIT_EVENT_ENUM` | `agent_dispatched`, `deprecated_flag_used`, `solve_bg_fanout_wave_started`, `solve_workflow_fleet_prepared`, `effort_resolved`, `error`, `claim_acquired`, `claim_collision`, `claim_force_override`, `claim_write_failed`, `claim_released`, `dispatch_backend_resolved`, `dispatch_setup_failed` | Audit-log writers (launcher + `lib/dispatch.sh`). `dispatch_setup_failed` carries `phase` (+ `subphase` ∈ {`marker_absent`, `pipeline_error`} on `id_extract`); `claim_collision` carries `phase:"post_write_verification"` when the post-write re-read lost to a racing dispatcher. |
| `UBERDEV_ACTIVE_LABEL` | `uberdev:active` | Step 4.5 claim protocol — applied on dispatch; cleared by `/merge` post-merge or the dispatch-failure rollback. NEVER set or removed by hand (color `D93F0B`; description ≤100 chars — GitHub 422s longer). |
| `CLAIM_COMMENT_MARKER` | `<!-- uberdev-claim-comment v1 -->` | HTML-comment fingerprint on every claim audit comment — the only safe parser surface. Collision checks match the **version-stripped prefix** so rolling v1/v2 upgrades stay mutually visible (#123 B7); adding optional body fields is backward-compatible (missing fields parse as `"?"`), removing/renaming fields MUST bump the marker version. |

## Deterministic triage heuristics

| Tier | Signals (any strong match) | Spawned workflow |
|------|----------------------------|------------------|
| **trivial** | Labels: `typo`, `docs`, `documentation`, `chore`, `good-first-issue`. Body <300 chars after stripping markdown. Title matches `typo\|rename\|bump\|version\|readme`. No stack trace. Single file named. | Read pre-collected research → minimal edit → test (if touched code is tested) → PR. **No brainstorm, no multi-step plan.** Phase 1 of `/uberdev:review-pr` runs the post-impl reviewer fanout and Phase 2 runs the simplify lenses after the PR opens. |
| **small** | Clear reproduction + error message. Localized to one module/package. Estimated ≤50 LOC. Labels: `bug` (scoped) or none. Not cross-cutting. | Read pre-collected research → lightweight TodoWrite plan (3–6 tasks) → TDD → PR. **No brainstorm.** Phase 1 of `/uberdev:review-pr` runs the post-impl reviewer fanout and Phase 2 runs the simplify lenses after the PR opens. |
| **medium/large** | Large: epic/discussion/architecture/infrastructure labels, ≥3 named files, multi-component high risk, or refactor plus ≥2 components/cross-cutting marker. Bare `refactor` is not sufficient. Medium is the fallback. | Full `/uberdev:brainstorm` → `/uberdev:write-plan` → `/uberdev:subagent-driven-dev` → `/uberdev:review-pr` pipeline. |

`lib/solve_triage.py` computes raw tier and closed risk signals, then applies
floor, ceiling, and the explicit tier override last without erasing risks. It
rejects oversized snapshots instead of truncating them and emits canonical JSON.

## Pipeline phases (all inside the launcher)

### Phase A — validate-all-first (Steps 1–4)

Strict argument parsing (positive issue tokens deduped, maximum 50; duplicate,
conflicting, and unknown flags rejected; parsers for
`--trivial|--small|--full`, `--auto`, `--force`/`-f`, `--effort=<level>`,
`--routing-mode`, `--route`, `--model`, `--service-tier`, `--fast`,
`--backend=<name>`, plus the `--terminal=` deprecation shim), the provider
version gate, repo guard, and per-issue `gh issue view --json` validation
(parallelized in `GH_PARALLEL_CAP` chunks; stdout kept pure JSON with stderr
captured separately). Any failure (closed, missing, gh error, live claim
without `--force`) prints **all** errors and aborts with `no claims written;
no agents dispatched`. Root routes and immutable contexts for the complete
batch are resolved before Step 4.5; partial claims or dispatches are forbidden.

Permission tiers: `--auto` (or `SOLVE_AUTO=1`, or `solve_auto: true` in
`.claude/uberdev.local.md`) sets `AUTO_PERMISSIONS=1`, which resolves to the
same bypass pair as `SKIP_PERMISSIONS=1` (`--dangerously-skip-permissions
--permission-mode bypassPermissions`, #241/#246). `AUTO_PERMISSIONS` is
distinct from `AUTO_MODE` (turbo-vs-interactive); the launcher prints the
resolved `Permission mode:` line for operator attribution, and
`AUTO_PERMISSIONS` reaches `lib/dispatch.sh` in-process.

### 4.5. Claim protocol — mark issue ACTIVE (v0.28.0; verification v0.37)

For every validated issue, a three-part claim is written **in sequence with rollback on partial failure**
(label → `@me` assignee → fingerprinted audit comment), followed by a
**post-write verification** re-read: the launcher
re-fetches the latest marker-matched claim comment and backs off
(newest-wins, assignee removed, batch fails) when a racing dispatcher's claim
landed after ours. Claim sequences for different issues run in parallel
chunks (#304 serial-claims speedup); all writes are fail-loud and any failure
rolls back every claim acquired in the run.

**Known limitation — residual TOCTOU race window (#123 B2, narrowed by post-write verification).** The Step-4 collision check and the Step-4.5 write remain non-atomic; the post-write re-read closes the practical window at the cost of one extra gh round-trip per issue, but two dispatchers that both verify before either's comment is indexed (sub-second) can stay mutually blind. The protocol is **best-effort, not a strong distributed lock** — see CHANGELOG `## [0.28.0]` Why for the original design tradeoff.

### Phase B — per-issue dispatch (Steps 5–6)

Tier-appropriate prompts (trivial/small heredocs commit and hand off to
`uberdev:finish-branch`, `--turbo` forwarded on the auto-mode branch;
medium/large dispatches `/uberdev:orchestrator`), then serial dispatch via
`uberdev_dispatch_one` in `ceil(N / cap)` waves with one
`solve_bg_fanout_wave_started` audit event per wave. Dispatch failures roll
back that issue's claim (with a B3 ownership re-check so a racing teammate's
claim is never stripped) and are reported loudly — no silent partial-batch
failures. The final summary names every spawned session and the
backend-appropriate monitoring surface.

## Boundary (RFC 0012 §3.4)

Everything before `uberdev_dispatch_one` lives in `lib/solve-launcher.sh`;
the spawn line, backend resolver, env resolution (`MODEL`, `PERM_FLAG`,
`EFFORT_FLAG`, `SOLVE_TIMEOUT`, `TIMEOUT_BIN`) and dispatcher-side monitoring
live in `lib/dispatch.sh`. The per-issue solver children are detached full
sessions with independent permission tiers and `SOLVE_TIMEOUT`-scale
lifetimes that survive the launcher process.

## History / tombstones

- Terminal-emulator dispatch (cmux / Ghostty `open -na --args` / iTerm /
  Terminal AppleScript / nohup) was retired in v0.22.0 (#85); issue #31
  (PR #33) documented the Ghostty sticky-`--command=` instance poison that
  started the retirement. `--terminal=` and `$SOLVE_TERMINAL` are parsed
  without effect and emit `TERMINAL_FLAG_DEPRECATED_NOTE` — see
  `## Deprecated Flags` in `commands/solve.md` / `commands/turbo.md`.
- The multi-fence SKILL.md pipeline (Phase A/B bash fences executed inline)
  was hoisted into `lib/solve-launcher.sh` per RFC 0012 §3.4 / issue #304.
