# RFC 0015 — Workflow-native dispatch: retiring `claude-bg`

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-07-30 |
| **Tier** | Large (transport change across `/solve`, `/turbo` and `/goal`) |
| **Target ver** | `0.41.0` (`/solve` + `/turbo`); `/goal` landed in the following `0.41.x` (§5) |
| **Targets** | new `skills/solve-fleet/{SKILL.md,workflow.js}`; `lib/dispatch.sh` (enum, `auto` arm, supervision gate, provider boundary, deprecation notice); `lib/solve-launcher.sh` (Step 5w); `commands/solve.md` + `commands/turbo.md`; `skills/solve-pipeline/SKILL.md`; `tests/solve-fleet-workflow.test.sh` (new) + `tests/dispatch-fallback.test.sh` + `tests/dispatch-codex.test.sh` + `tests/codex-port.test.sh`; `.github/workflows/test.yml` (both jobs); the `codex/uberdev-codex` mirror. **§5 landing:** new `skills/goal-pipeline/workflow.js` + `lib/goal-{phase0,phase1,watch,phase3}.sh`; `skills/goal-pipeline/SKILL.md` (shrunk to preflight + mandate + fallback); `commands/goal.md`; `lib/dispatch.sh` (demotion helper DELETED); `tests/goal-workflow.test.sh` (new) + `tests/goal.test.sh` + `tests/goal-pipeline-zsh.test.sh` re-anchored |
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
session — and the §5 landing settles what that means for `/goal`. `/goal`'s
**children** turned out not to need it either: they are the same solvers
`/solve` runs, and they now die with the session exactly as `/solve`'s do. What
`/goal` genuinely needs to outlive a session is its **state**, not its
processes, and that was always on disk in `lib/goal-state.sh`. So the constraint
now binds one narrow thing: an operator who deliberately wants fire-and-forget
must name a detached backend explicitly (`--backend=claude-bg`, until its v1.0.0
removal). Nothing reaches a detached transport by default any more, on any
command.

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

## 5. `/goal` — shipped

`/goal` is Workflow-native. This section described a staged hybrid before that
landing; what follows is what actually shipped.

### 5.1 The fences were the bug

`/goal` was five ```bash fences in `skills/goal-pipeline/SKILL.md`. The
Claude-Code Bash tool gives every fence its own shell, so the cycle counter, the
rollover queue, the candidate array, the EXIT/INT/TERM traps and every
accumulated counter died at each phase boundary. The false-converge (candidates
rehydrated empty), the rollover wipe (queue overwritten instead of merged) and
the dead circuit breakers (a counter that reset every pass) are one bug in three
costumes, and each was patched individually until the next variable died. The
Skill renderer's `$ARGUMENTS` positional substitution — which rewrote bare
`$1`/`$2`/`$3` inside single-quoted `awk` one-liners — was the second structural
hazard of that shape.

So the executable body moved into four shebang'd, independently-testable scripts
that `lib/*.sh` (never rendered) makes safe, and the loop that used to be an
instruction to the model became a real loop in a real driver:

| Phase | Script | Owns |
|---|---|---|
| 0 preflight | `lib/goal-phase0.sh` | arg parse, config reads, `GOAL_ID` mint, state init, `--resume` rehydration, the `uberdev_emit_workflow_args goal …` envelope |
| 1 claim | `lib/goal-phase1.sh` | label provisioning, the `uberdev:active` cross-process claim, the `MAX_PARALLEL` rollover, `input -> dispatched`. **It does not dispatch.** |
| 2 watch | `lib/goal-watch.sh` | the merge lane + every circuit breaker, under the documented `0`/`42`/`1` exit contract |
| 3 collect | `lib/goal-phase3.sh` | candidates → fingerprint repeat → overflow truncation → terminal gates |
| driver | `skills/goal-pipeline/workflow.js` | the cycle loop, the projected-agent gate, and the nested fleet call |

### 5.2 The three §5 objections, resolved

The staged plan listed three reasons `/goal` could not follow `/solve`. Each has
a concrete answer:

- *"A Workflow cannot sleep, poll on a timer, or wait on CI."* Correct, and it
  does not. The polling lives in `lib/goal-watch.sh`, which is an ordinary shell
  script with an ordinary `sleep`. The driver's watch stage is a **bounded
  `for`** whose counter — never a clock — is the bound (DR-7), re-invoking the
  script on its `42` ("still working") code until it returns `0` (drained) or
  `1` (halt).
- *"Resume is same-session only, so cross-session durability still needs
  `lib/goal-state.sh` on disk."* It still does, unchanged. `--resume` reads the
  fixed-path `goal-active-id.txt` pointer and rehydrates.
- *"`workflow()` nesting is one level deep."* It is, and it is spent
  deliberately: **exactly ONE nested call per cycle** into
  `skills/solve-fleet/workflow.js` for the whole cycle. There is no
  `solve-one.js` and there must not be one — the fleet already fans out per
  issue internally, so a nested call *per issue* would spend the single level on
  the wrong thing and the fleet's own agents could not run.

### 5.3 The interim demotion is deleted

`uberdev_dispatch_demote_workflow_to_detached` existed for exactly one caller:
`/goal`'s Phase-1 loop, which drove `uberdev_dispatch_one` itself and so could
not serve the `workflow` backend. It re-resolved a `workflow` selection back
down to the retired per-OS matrix — which is to say it kept **`claude-bg`, a
deprecated backend, reachable from `auto` on a default path**.

With `/goal` no longer dispatching, the helper is **deleted, not left dormant**.
A dormant demotion is precisely how retired policy drifts back into a default.
Reaching a detached backend is now an explicit `--backend=<name>` choice on every
surface, and `tests/solve-fleet-workflow.test.sh` S16-S20 assert the inverse of
what they used to: the helper must not exist, nothing may call it,
`lib/goal-phase1.sh` must contain no `uberdev_dispatch_one`, and the driver must
make exactly one nested `workflow()` call.

**One thing genuinely does still need a detached transport, and it is not the
solvers.** `lib/goal-watch.sh` dispatches two children of its own — `/merge`
(step 2c) and `/review-pr` (step 2b) — and it is a *shell polling loop*, not the
driver, so it cannot call the Workflow tool. `lib/dispatch.sh` correctly refuses
the `workflow` backend there. So the watch script resolves an explicit child
transport (`background` by default, overridable via `UBERDEV_GOAL_CHILD_BACKEND`)
and announces it. Three things distinguish that from the deleted shim: it is
scoped to two dispatches instead of the whole run, it leaves the solvers
Workflow-native, and it names a first-class non-deprecated backend rather than
re-entering the retired per-OS matrix. Moving those two children into the driver
as Workflow agents is the natural follow-up, and it is not this landing.

### 5.5 The 150-minute solver timeout is now dead weight, and says so

`_UBERDEV_GOAL_SOLVE_TIMEOUT` (150m) answered one question: *is the detached
solver still working, or did it die?* That question only exists when the solver
outlives its dispatcher. The nested fleet call is **awaited**, so by the time
`lib/goal-watch.sh` runs, every solver in the cycle has already returned — an
issue with no PR and no live agent is terminal *now*. The driver therefore passes
`UBERDEV_GOAL_SOLVERS_SETTLED=1`, and the watch script classifies immediately
instead of spending the entire watch-tick budget re-proving a settled fact. The
marker is opt-in, so a hand-run `lib/goal-watch.sh` keeps the timeout semantics.

### 5.4 Trust verdicts are never LLM-reported

Every relay in the driver is mechanical: run a script, report its exit status
verbatim. The one place a trust colour surfaces (the per-cycle summary) hands the
verdict **path** to a relay running `uberdev_goal_read_trust_signal` and consumes
that helper's stdout; the schema's enum is the helper's own closed return set.
No agent is ever asked what colour a PR is.

## 6. Risks and accepted behaviour losses

Every loss below is **printed, never silent** — in this section, in
`skills/solve-fleet/SKILL.md`, and where it matters at runtime.

- **R-1 — no survive-the-parent.** If the session ends — closed, `/clear`,
  compact — every in-flight solver dies with it. This is true of `/goal` too
  since §5: its children are the same fleet solvers, so a closed session leaves
  a real run with live on-disk state and dead processes. The recovery is
  explicit and shipped: `/uberdev:goal --resume` rehydrates the run from the
  fixed-path `goal-active-id.txt` pointer and carries on, and
  `plugins/uberdev/lib/goal-abort.sh` is the other half — it releases the
  `uberdev:active` claims and reaps. The detached backends remain available for
  the deliberate fire-and-forget case, and `--backend=claude-bg` is exactly that
  escape hatch until v1.0.0.
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
  `/goal` inherits this as of §5, and it costs it more than it costs `/solve`:
  `lib/goal-phase0.sh` still exports `SKIP_PERMISSIONS=1`, but that now only
  reaches the children `lib/goal-watch.sh` still dispatches through
  `lib/dispatch.sh` (`/merge`, `/review-pr`) — the *solvers* take the session's
  tier. An unattended `/goal` therefore wants a session that is already at the
  tier and effort the operator intends, or an explicit detached backend.
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

## 6b. The args-shape contract (added v0.42.2 — read before writing a workflow.js)

**The runtime hands `args` to a `scriptPath` workflow as a JSON STRING, not a parsed object.**
Probed live 2026-07-31 with a no-agent workflow that reported `typeof args`:

```
argsType:           "string"
shippedGuardResult: "NOT-OBJECT — guard yields {} and the pipeline no-ops"
parsesAsJson:       true
```

Every script shipped through v0.42.1 opened with
`const A = (args && typeof args === "object") ? args : {};`. Under a string that guard falls
through to `{}`, so **every migrated pipeline — `/ubergoal`, the `/solve`+`/turbo` fleet,
`/uberscan`, `/ubersimplify`, `/testers`, `/uberthink` — returned success having dispatched
nothing.** A `/ubergoal` run finished in 5 ms with zero agents and an empty journal.

Three things made this survive nine releases:

1. **The failure mode is a silent no-op, not a throw.** The script completes, returns a
   well-formed result, and exits 0. Nothing looks wrong.
2. **The test harness modelled the runtime incorrectly.** `tests/_workflow_harness.js` passed
   `args` as a parsed object, so the suite was green while production was dead. A test oracle
   that models the runtime wrongly is worse than no oracle — it certifies the bug.
3. **Running both shapes is not sufficient on its own.** Verified: reverting a script to the
   object-only guard and re-running the harness under a string envelope still PASSED, because a
   no-op raises no error. Only requiring *proof of consumption* catches it.

The contract is therefore enforced three ways:

- every `workflow.js` carries the byte-identical `// === SHARED:args-envelope v1 ===` block,
  which accepts a string or an object and treats unparseable input as absent;
- `validate` runs every script under **both** shapes;
- `GENERIC_ARGS.run_id` is a sentinel that must appear in the script's observable output
  (logs, agent prompts, nested `workflow()` calls), proving the envelope was read. Mutation-
  verified against all five scripts: restoring the object-only guard reds each one.

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
