# RFC 0015 — Workflow-native dispatch: retiring `claude-bg`

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-07-30 |
| **Tier** | Large (transport change across `/solve`, `/turbo`, and — staged — `/goal`) |
| **Target ver** | `0.41.0` (this landing: `/solve` + `/turbo`); `/goal` follows in `0.41.x` |
| **Targets** | new `skills/solve-fleet/{SKILL.md,workflow.js}`; `lib/dispatch.sh` (enum, `auto` arm, supervision gate, provider boundary, deprecation notice); `lib/solve-launcher.sh` (Step 5w); `commands/solve.md` + `commands/turbo.md`; `skills/solve-pipeline/SKILL.md`; `tests/solve-fleet-workflow.test.sh` (new) + `tests/dispatch-fallback.test.sh` + `tests/dispatch-codex.test.sh` + `tests/codex-port.test.sh`; `.github/workflows/test.yml` (both jobs); the `codex/uberdev-codex` mirror |
| **Supersedes** | RFC 0004's **auto-resolution matrix** only. RFC 0004's per-backend transports, receipts and supervision contracts stay canonical for the explicit backends. |
| **Amends** | RFC 0012 **Constraint 5** — see §2 |

---

## 1. Decision

**`auto` no longer resolves to a detached session backend.** On every Claude
host and every OS class, `/solve` and `/turbo` now run their per-issue solvers
inside the calling session's **Workflow runtime** — one worktree-isolated agent
per issue, orchestrated by `skills/solve-fleet/workflow.js`.

`claude-bg` is **deprecated**, not deleted: `--backend=claude-bg` still works,
still passes its full test suite, and now prints a one-line deprecation notice.
Removal target **v1.0.0**.

### Why

The user-facing complaint is exact and worth quoting in the design: detached
`claude --bg` sessions "open a different menu". Everything else follows from
that.

| Property | `claude-bg` (detached) | `workflow` (this RFC) |
|---|---|---|
| Where progress is visible | a separate `claude agents` surface you must switch to and poll | the `/workflows` progress tree in the session you started |
| Result discovery | go look at the agent surface, then go look at GitHub | a structured return value per issue |
| Orchestration state | inside each detached session; unobservable | JS variables in one script; logged as `WORKFLOW_RESULT` |
| Concurrency cap | dispatch-burst chunking only — every session starts immediately regardless of the cap | a real live ceiling (`parallel()` waves) |
| Failure of one issue | invisible until you look | a `FAILED` record naming the issue and the blocker |
| Native Windows | hard error unless WezTerm is installed and running | works — there is no process tree to supervise |
| Host requirements | `claude` CLI, `timeout(1)`/`gtimeout(1)`, per-OS probes | none beyond the session itself |

---

## 2. Amendment to RFC 0012 Constraint 5

RFC 0012 §2.2 constraint 5 reads: *"Workflow agents are Task-style subagents,
NOT detached full Claude sessions: they cannot replace claude-bg dispatch
semantics (independent permission tier, survive-the-parent, hours-long
lifetimes)."*

That constraint is **narrowed, not overturned**. What it correctly identifies is
that a Workflow agent is not a *detached session*. What this RFC establishes is
that **`/solve` never needed one**:

- *Independent permission tier* — an anti-feature here. The tier that should
  apply to work the user just asked for is the tier of the session they asked
  in. `/turbo`'s unattended mode is expressed by `autoMode` in the args, not by
  a second permission domain.
- *Survive-the-parent* — real, and the honest cost of this change (§6 R-1).
  Measured against a batch the user can actually watch and that reports back,
  it loses.
- *Hours-long lifetimes* — Workflow agents are not time-boxed by the script;
  the runtime owns their lifetime. The per-issue `solveTimeoutS` was always
  advisory and is now reported rather than enforced (DR-7: the runtime forbids
  clocks in the script).

Constraint 5 remains binding for anything that genuinely needs to outlive its
session. `/goal`'s cross-session durability (§5) is where that bites.

---

## 3. What moved, and what did not

**Unchanged — still `lib/solve-launcher.sh`, still one Bash call:** argument and
flag parsing, the `MIN_CLAUDE_VERSION` gate, validate-all-first, triage, route
resolution, the prepared root request + context files, Step 4.5's
`uberdev:active` claim protocol and its rollback, and every audit event.

**Changed — the transport only.** A new **Step 5w** sits immediately before the
detached dispatch loop (`Step 5b'`). When the resolved backend is `workflow` it:

1. validates `skills/solve-fleet/workflow.js` exists on disk (RFC 0012 §4.1 —
   refuse at preflight, never at the runtime layer);
2. writes `$UBERDEV_TMPDIR/solve-fleet-manifest.json`, one record per issue
   (`issue`, `tier`, `prompt_file`, `context_file`, `context_sha256`);
3. sets `UBERDEV_KEEP_TMPDIR=1` so prompts and contexts outlive the process;
4. emits the args envelope via `uberdev_emit_workflow_args solve-fleet …`;
5. exits 0 without dispatching anything.

The command file then relays that JSON **verbatim** (DR-2) into
`Workflow({scriptPath: …/skills/solve-fleet/workflow.js}, <args>)`.

Ordering is load-bearing and test-locked (`S7`): Step 5w must precede Step 5b',
or a workflow run would *also* spawn detached sessions — double dispatch against
a single set of claims.

---

## 4. The fleet script

### 4.1 The leaf constraint drives the shape

A Workflow agent has **no Agent/Task tool**. The historical medium/full-tier
prompt told the detached session to `Invoke the slash command
/uberdev:orchestrator …`, which fans out research, spec, plan and SDD waves. A
leaf agent cannot do that — so **the orchestration moved into the script**,
where fan-out is `parallel()` and every agent stays a leaf:

| Tier | Chain |
|---|---|
| `trivial`, `small` | ONE solver agent, `isolation:"worktree"`. Byte-for-byte the same brief the detached session got. |
| `medium`, `large` | `parallel()` research fan-out (codebase / constraints / test-coverage) → spec writer → spec reviewer (**one** bounded revision round) → plan writer → ONE solver agent executing the plan. |

Only the **solver** is worktree-isolated. Research and design agents are
read-only and write to absolute paths under the run dir — an isolated
researcher would write into its own throwaway worktree and the artifact would
vanish. That is the artifact path-leak class this project has hit before, and
the asymmetry is test-locked (`G3`, `G3b`).

The solver prompt states the leaf constraint explicitly ("do the WORK it
describes yourself instead — you are a leaf agent"), because the brief it reads
still contains hand-off language written for a detached session.

### 4.2 Guards

| ID | Guard |
|---|---|
| CB1 | projected agents (`1 + issues + 6×design-tier issues`) over `maxAgents` → abort **before** any dispatch |
| CB2 | runtime `budget` exhausted between waves → stop, report, leave remaining claims intact |
| — | manifest/envelope cross-check: only issues the launcher actually claimed are solved; a mismatch in either direction is audited, never silent |
| — | a per-issue chain that throws is caught and recorded as `FAILED` for that issue alone |
| — | `underRunDir()` on every agent-returned artifact path before it reaches a downstream prompt |

Wall-clock breakers are impossible in-script (DR-7). `budget` + CB1 + CB2 cover
the live failure modes — the same resolution scan-fleet reached.

### 4.3 Discipline inherited from the surrounding project

The solver prompt carries the house rules that have no human in the loop to
enforce them on `/turbo`: root-cause fixes, tests-first, conventional commits,
**no `Co-Authored-By` / AI attribution trailer**, `--body-file` never inline
`--body`, `Closes #N` in the body, no `--force`, no `--no-verify`, and — new,
and specific to parallel batches — **no version bump**: every solver bumping to
the same next version is the collision class this repo has hit repeatedly.
Releases stay serial and operator-driven.

The solver stops at PR opened. It does not merge and does not chain into a
review command; that remains `/goal`'s decision.

---

## 5. `/goal` — staged, not in this landing

`/goal` inherits the backend resolver, so its solvers move with `/solve`. Its
**watch loop** does not, and must not be migrated naively:

- a Workflow cannot sleep, poll on a timer, or wait on CI;
- resume is same-session only, so cross-session durability still needs
  `lib/goal-state.sh` on disk;
- `workflow()` nesting is one level deep, which the per-issue design chain
  already spends if it is ever refactored into a child script.

The staged shape is a **hybrid**: the fan-out and verdict computation move into
a workflow, while CI waiting, merge landing and cross-session state stay in the
main loop. That is a separate landing with its own acceptance criteria.

---

## 6. Risks and accepted behaviour losses

Every loss below is **printed, never silent** — in this section, in
`skills/solve-fleet/SKILL.md`, and where it matters at runtime.

- **R-1 — no survive-the-parent.** If the session ends — closed, `/clear`,
  compact — every in-flight solver dies with it. The detached backends remain
  available for the deliberate fire-and-forget case, and `--backend=claude-bg`
  is exactly that escape hatch until v1.0.0.
- **R-1b — per-child model, effort and permission tier are inexpressible.**
  The detached backends passed `--model`, `--effort` and the
  `--dangerously-skip-permissions --permission-mode bypassPermissions` pair as
  explicit child argv. The Workflow API has no per-agent effort or permission
  option, so fleet solvers **inherit the session's model, effort and permission
  tier**. Two consequences worth stating outright: `/turbo --auto`'s bypass is
  no longer scoped to the children — it is whatever the session already has;
  and a session running below `max` effort produces lower-effort solvers than
  the same command would have on a detached backend. Users who need the pinned
  tier should use `--backend=claude-bg` or raise the session's own settings.
- **R-1c — no in-flight cancellation through `lib/dispatch.sh`.**
  `_uberdev_dispatch_cancel_backend` proves a detached child is gone
  (TERM→poll→KILL→poll, or `claude stop` plus a terminal probe). There is no
  equivalent for a fleet agent: cancellation belongs to the Workflow runtime
  (`TaskStop` / skipping an agent), not to this library. The `workflow` arm is
  absent from the cancel switch by construction, exactly as it is from the
  dispatch switch.
- **R-1d — no status records, lifecycle manifest, or capacity lease.** The
  detached path publishes a canonical status JSON per issue, an
  `agent-lifecycle.jsonl` event stream with exactly one terminal event, and a
  capacity lease bound to the owner process identity. The fleet publishes none
  of those: its observability channel is the `/workflows` progress tree plus
  the `WORKFLOW_RESULT` line and the structured return. That is *more* legible
  interactively and *less* legible to a machine consumer — which is precisely
  why `/goal`, the only machine consumer, is staged (§5) rather than migrated
  blind.
- **R-2 — medium-tier fidelity.** The script's design chain is a faithful but
  not identical translation of `/uberdev:orchestrator` (no SDD wave
  decomposition, one bounded review round instead of the always-on
  writer/reviewer pairs). RFC 0012 Phase 6 remains the path to full parity;
  until then `--backend=claude-bg` reaches the original pipeline.
- **R-3 — a stranded claim, including a new relay-gap window.** If the fleet
  stops early (CB1/CB2, or the session ends), unsolved issues keep their
  `uberdev:active` label. There is also a window the detached path did not
  have: the launcher writes claims and then *exits*, and the run only begins
  when the model relays the args envelope into the `Workflow` call. A run that
  is never relayed — the model errors, the user interrupts — leaves every claim
  in the batch held with nothing running. The script logs the stranded set on
  every early-exit path, but there is no automatic release: releasing a claim
  we did not verify is worse than a visible stale label. **A
  `--reap-stale-claims` sweep on the launcher is the correct fix and is owed
  as a follow-up**; until it lands, `gh issue edit N --remove-label
  uberdev:active` is the manual recovery.
- **R-4 — no Workflow tool.** Codex, Gemini, Copilot and pre-Workflow Claude
  Code have no `Workflow` tool. Every surface carries a **No-Workflow
  fallback** naming the explicit backend to re-run with, and `auto` still
  resolves to `codex` inside a Codex session.

---

## 7. Rejected alternatives

- **Delete `claude-bg` outright.** Rejected: it is ~170 lines of mature,
  heavily-tested transport with real supervision, cancellation and receipt
  semantics, and removing it in the same change that introduces its replacement
  would leave no fallback if the new transport disappoints. Deprecate, then
  remove on evidence.
- **Keep `auto` per-OS and add `workflow` as opt-in.** Rejected: opt-in defaults
  are not defaults. The complaint was about what happens without flags.
- **Have the solver agent invoke `/uberdev:orchestrator`.** Rejected: it cannot
  — the skill's fan-out needs a tool the agent does not have. Discovered as a
  constraint, not a preference.
- **A child `workflow()` per issue.** Deferred: it works and is the natural home
  for the full SDD wave decomposition, but it spends the single nesting level,
  so it should be spent on the design that needs it most (RFC 0012 Phase 6).
