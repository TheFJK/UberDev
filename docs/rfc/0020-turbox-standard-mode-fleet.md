# RFC 0020 — `/turbox`: the standard-mode solver fleet

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-08-18 |
| **Tier** | Large (a second execution lane for the solver fleet, across launcher, command, skill and lib) |
| **Target ver** | `0.49.0` |
| **Targets** | new `commands/turbox.md`; new `skills/turbox-fleet/SKILL.md`; new `lib/turbox-fleet.sh`; `lib/solve-launcher.sh` (the `--standard` option + Step 5s); `lib/aliases-sync.sh`; `skills/using-uberdev/references/configuration.md`; new `tests/turbox-fleet.test.sh` (portable shape checks, both jobs) + new `tests/turbox-fleet-runtime.test.sh` (behaviour, Unix-only); `.github/workflows/test.yml` (both jobs + the windows-skip-list marker block); `README.md`; `CHANGELOG.md`; the six version-lock surfaces |
| **Complements** | RFC 0015 (the Workflow-native lane). `/turbo` is unchanged; `/turbox` is a sibling lane, not a replacement. |
| **Reuses** | RFC 0005 (`/goal` claim + circuit-breaker vocabulary), the `subagent-driven-dev` wave contract (Pattern B), the existing `agents/*.md` registry |

---

## 1. Decision

**`/turbox <issue#>…` runs the solver fleet with the calling session as the sole
orchestrator, dispatching every agent through the `Agent` tool instead of the
Workflow runtime.**

The launcher is unchanged up to and including the claim protocol. What changes
is what happens after it: instead of emitting a `Workflow` args envelope, the
launcher emits a **turbox plan** and this session executes the fleet itself.

The point of the lane is one property the Workflow lane structurally cannot
have:

> **A Workflow agent has no `Agent`/`Task` tool** (RFC 0015 §4). It cannot fan
> out. That is why `skills/solve-fleet/workflow.js` implements the
> implementation phase as a **sequential per-task loop** — one task at a time,
> each in its own agent, gated by a reviewer. Correct, but serial.

In standard mode the orchestrator is a *session*, not a leaf, so the
implementation phase can be what the plan already says it is: **waves of
parallel implementers over strictly disjoint file sets**. The plan-writer has
emitted `## Execution Waves` and per-task `Owns (file allowlist)` fields all
along; the Workflow lane simply cannot honour them.

### Why not just fix the Workflow lane

It is not fixable from inside. The leaf constraint is a property of the
runtime, not of our script. `workflow()` nesting is one level deep and
`skills/goal-pipeline/SKILL.md` already spends that level. The only way to get
a fan-out-capable orchestrator is to be a session.

### What `/turbox` gives up (say these out loud, never silently)

| Loss | Detail | Escape hatch |
| --- | --- | --- |
| Survive-the-parent | the fleet **is** this session's turn loop; `/clear`, a compact, or closing the session ends it. The Workflow lane has the same property (RFC 0015 §6) — this is not a regression against it, only against `--backend=background`. | `/turbo --backend=background` |
| Context economy | the controller reads plans, parses waves, and holds per-task state in **its own** context. The Workflow lane keeps all of that in the script, out of context. This is the real price of the lane. | pointers-not-artifacts discipline (§4.1); `/turbo` for large batches |
| The `/workflows` progress tree | there is no Workflow run to watch. Progress is the session transcript plus the on-disk run directory. | `/turbo` |
| A structured machine-readable return | the Workflow lane returns one JSON object. Here the controller reports; the durable record is the audit log and the run directory. | `/turbo` |
| Batch size | the parallel-issue cap is **3**, against the Workflow lane's 6 (§3.3). | `/turbo` |

### What it keeps, unchanged

Everything before the transport: validate-all-first, triage, route resolution,
the prepared root request and context files, and the Step 4.5 `uberdev:active`
claim protocol. `lib/solve-launcher.sh` is still the single entry point, and
`/turbox` is `--auto-mode=1 --turbo --standard` on it.

---

## 2. Why `--standard` is a launcher option and NOT a `dispatch_backend` value

The obvious-looking design is `--backend=standard`, next to
`auto|workflow|wezterm|background`. It is rejected, deliberately.

`dispatch_backend` answers **"how is one per-issue solver child launched?"**
Every member launches a thing that runs a whole `/solve` on one issue: a
Workflow agent, a WezTerm pane, a detached headless `claude -p`. Consumers of
the enum are written against exactly that meaning —
`uberdev_dispatch_preflight`'s availability arms, the supervision-capable
subset, `/goal`'s run-state allowlist, `lib/child-dispatch.sh`'s routing, and
`review_fleet_bind_carrier_backend`'s rehydration shape-check.

Standard mode launches **no per-issue solver at all**. There is no child that
runs `/solve`; the session runs the pipeline and the children are the pipeline's
*phases*. Adding it to the enum would make every one of those consumers' answer
silently wrong, and the enum is registered as a `CONTRACT: dispatch-backend`
with copies in nine files — each of which would have to gain a `standard` arm
whose semantics are "not reachable from here".

So: `--standard` is orthogonal to `--backend`, exactly as `--auto` (a
permission bypass) is orthogonal to `--turbo` (an interactivity mode).

**The two are mutually exclusive and the launcher refuses the combination.**
`--standard` with any explicit `--backend=<name>` — CLI flag or
`UBERDEV_DISPATCH_BACKEND` env — is a hard error before any claim is written.
An operator who writes both has two different models of the run in their head,
and picking one for them is how a batch lands somewhere nobody expected.

Internally `--standard` pins the resolver to `workflow` so that
`uberdev_dispatch_preflight`, `uberdev_dispatch_resolve_env` and
`uberdev_dispatch_prepare_root` still run — those produce the route, the
context files and the prepared root request that standard mode also needs.
The pin is honest rather than cosmetic: `workflow` is the one member whose
permission story matches standard mode exactly — **no per-child argv, children
inherit the calling session's tier** (RFC 0015 §6 R-1b). The launcher emits a
`standard_mode_backend_pinned` audit event so the pin is never invisible.

---

## 3. The execution model

> **AMENDED 2026-08-20 (issue #656) — the design path collapses to two rungs.**
> The three always-on research lenses and the three spec rungs are no longer
> dispatched on this lane. `uberdev:design-planner` fills the design rung and
> emits `plan.md` directly — in the same `## Execution Waves` / `Owns (file
> allowlist)` shape `plan-writer` emits, so §3.5, §3.6 and Phase 4 are
> unchanged — gated by the always-on `uberdev:plan-reviewer`. Phase 2 keeps
> exactly one lens, the risk-gated `uberdev:research-security`. This **forks the
> two lanes' fidelity** relative to RFC 0015 §R-2, which argued the always-on
> writer/reviewer pairs into existence: on this lane a wrong design is now
> caught at plan review, rather than before a plan is built on it. §3.1, §3.4
> and §3.7 below are amended to match; §3.2, §3.3, §3.5 and §3.6 are unchanged.
> The **Status** row of the header table above is deliberately left
> **byte-identical** — the `RFC status is Accepted` row (TX13) in
> `tests/turbox-fleet.test.sh` matches that row's exact text, and appending an
> amendment marker to it would red that row. Reproducing the row verbatim here
> would also put a second copy of a byte-locked string into prose, which is the
> drift class RFC 0016 exists to close.

### 3.1 The controller is this session; every agent is a leaf

```
session (controller)
├─ Phase 1  worktrees        one per issue, cut by the controller (paths are KNOWN)
├─ Phase 2  research         the risk-gated security lens only, ALL such issues in ONE message
├─ Phase 3  design           design-planner×N → plan-reviewer×N
├─ Phase 4  implement        wave k of EVERY issue in ONE message; controller stages + commits
├─ Phase 5  gate             per-task reviewers in parallel; bounded fix ladder
└─ Phase 6  deliver          suite → push → PR, per issue in parallel
```

The alternative — one orchestrator agent per issue, each fanning out its own
children — was rejected because it depends on a subagent being able to spawn
subagents, which is not a property this project has verified. If it is
unavailable the design does not fail loudly; each issue-agent silently degrades
to doing the whole issue solo, which looks like a slow success. A design whose
failure mode is indistinguishable from its success mode is not a design.

Flattening has a second, non-obvious win: **cross-issue parallelism at every
phase**. Three issues' design rungs are one message of three `design-planner`
agents, and their first implementation waves are one message holding every task
those waves carry — not three sequential per-issue fan-outs in either case.

### 3.2 Phase-synchronised, not issue-synchronised

Issues advance through phases **together**. An issue that finishes its design
phase early waits for its siblings before the implementation phase begins.

This costs some wall-clock and buys the property the whole lane exists for: at
any moment every in-flight agent belongs to the same phase, so the controller
holds one kind of state, one set of caps, and one dispatch shape. The
alternative — per-issue pipelining — reproduces the Workflow lane's `pipeline()`
semantics in a session that has no scheduler, and the controller becomes a
hand-written event loop.

One exception, inherited from `subagent-driven-dev`: within Phase 5 a task
whose review approves moves to its quality review immediately rather than
waiting for the slowest sibling's fix ladder.

### 3.3 The parallel-issue cap is 3

`fanout_concurrency.turbox`, default **3**, valid range **1..3**. A configured
value above 3 is clamped to 3 with a stderr note; it is a ceiling, not a
suggestion.

The Workflow lane's cap is 6. Standard mode is capped lower because its agent
count *per issue* is multiplicative rather than additive: a design-tier issue at
wave width 3 puts 3 implementers plus their reviewers in flight at once, times
the number of issues. Three issues is already a 9-to-18-agent wave, which is at
the runtime's practical concurrency and at the point where a single session's
usage window becomes the binding constraint.

`/turbox 1 5 3` is the shape the lane is for: a hand-picked handful. Queues
longer than the cap split into `ceil(N / 3)` sequential waves, same as `/turbo`.

### 3.4 Tier routing

| Tier | What runs |
| --- | --- |
| `trivial`, `small` | ONE solver agent per issue in the controller-cut worktree. It runs its own git, its own push, its own PR — it is alone in that checkout, so there is no race for the controller to serialise. Identical in spirit to the Workflow lane's single-solver path. |
| `medium` | The full Phase 2–6 pipeline: risk-gated security research → plan → **wave-parallel** implementation → per-task gate → delivery. |
| any tier with no usable plan | falls back to the single solver. No plan means no tasks, no waves, and no `Owns` sets to prove disjoint. |

### 3.5 The safety boundary: who may run git

This is the rule the lane's correctness rests on, and it is a property of the
*checkout*, not of the agent:

> **A worktree with two or more concurrent writers has exactly one git
> operator: the controller.** A worktree with a single writer lets that writer
> run its own git.

So Phase 4 implementers never run git — they edit files and report the paths
they changed; the controller stages **exactly those paths** and commits per
task in task-ID order. The Phase 3.4 single solver, alone in its worktree, does
its own commits. Same rule, two readings.

Staging is explicit-path only. `git add -A`, `git add .` and `git commit -a`
are refused by `turbox-fleet.sh stage-commit`, which is the chokepoint, not a
convention: an implementer that reported four paths must not be able to sweep a
fifth into the commit, and a dirty tree must not be able to leak into a task
commit.

### 3.6 Disjointness is refused, not reviewed

`plan-reviewer` Check 2 already reviews same-wave `Owns` lists for disjointness.
A review is advice. `turbox-fleet.sh wave-disjoint` is the refusal: before any
implementer in a wave is dispatched, every pair of tasks' `Owns` sets is
compared for **equality or directory containment** — one task owning `lib/` and
a sibling owning `lib/x.sh` race exactly as if they shared a path, and a plain
set intersection calls them disjoint. On overlap it dispatches **nothing** and
returns rc 3; on missing ownership, rc 2.

An overlap is a plan defect. It routes into the BLOCKED ladder and the wave's
decomposition is fixed — never "dispatch anyway".

The containment predicate is deliberately the same one
`sdd_assert_wave_disjoint` uses. Two implementations of "do these paths
collide" is one implementation too many.

### 3.7 Circuit breakers

| ID | Guard |
| --- | --- |
| **TB1** | projected agents over `maxAgents` (default 600) → abort **before** any dispatch. Projection: `smallIssues + (3 + implementBudget) × designIssues`, where 3 = the risk-gated security lens + design-planner + plan-reviewer (#656). Pessimistic on the one conditional rung (the risk-gated security lens) for the same reason the Workflow lane is: it is not knowable at projection time. |
| **TB2** | a **live** per-issue counter of implementation-phase agents against `implementBudget` (default 24, clamped 4..96). On exhaustion the remaining tasks are recorded `SKIPPED`, `implement_budget_exhausted` is audited, and **delivery still runs** on what is already committed — reviewed commits must never strand in a worktree. |
| **TB3** | wave disjointness (§3.6). Refuses the wave, not the run. |
| **TB4** | loop caps: `fix_rounds` = 3 per task per review stage, `retest_rounds` = 2 per wave, `context_rounds` = 2 per task. Inherited names and defaults from `subagent-driven-dev`. |
| — | a per-issue chain that throws is caught and recorded `FAILED` for that issue only; one bad issue never takes the batch down. |

Wall-clock breakers are out of scope, as they are in the Workflow lane.

---

## 4. Contracts

### 4.1 The controller holds pointers, never artifacts

Inherited verbatim from `skills/orchestrator/SKILL.md`. The controller reads
paths, SHAs, statuses and one-line summaries out of agent returns. It does not
read spec bodies, plan bodies, research artifacts or review findings into its
own context — those travel **on disk**, and downstream agents are given the
path. This is what makes a session-hosted fleet affordable at all.

The one thing the controller must parse in full is each plan's task table:
task IDs, wave numbers, and `Owns` allowlists. That is the input to §3.6 and it
cannot be delegated to the thing it is guarding.

### 4.2 The turbox plan envelope

The launcher emits one compact JSON object between `TURBOX_PLAN_BEGIN` and
`TURBOX_PLAN_END`, machine-composed, relayed verbatim (the DR-2 rule: no
LLM-composed handoffs). Deliberately **not** the `WORKFLOW_ARGS_BEGIN/END`
marker pair — those markers mean "call `Workflow()` with this", and a turbox
plan relayed into `Workflow()` would be a category error rather than an error
message.

| Key | Meaning |
| --- | --- |
| `manifestPathAbs` | the per-issue manifest (`issue`, `tier`, `prompt_file`, `risk_signals`, `context_file`, `context_sha256`) — the same record shape the Workflow lane's fleet reads |
| `issues`, `issueCount` | comma-joined issue numbers, and the declared count |
| `riskIssueCount` | how many issues carry non-blank triage `risk_signals` (gates the security research lens) |
| `concurrency` | parallel-issue wave size, 1..3 (§3.3) |
| `runDirAbs` | prompts, contexts, per-issue design artifacts, fix ledgers, rulings |
| `worktreeRootAbs` | `<runDirAbs>/worktrees`; issue *N* gets `<worktreeRootAbs>/issue-<N>` |
| `repoRootAbs`, `pluginRootAbs`, `repoSlug`, `baseBranch`, `branchPrefix` | controller-derived inputs |
| `maxAgents`, `implementBudget`, `fixRounds` | TB1 / TB2 / TB4 ceilings |
| `autoMode` | always true — `/turbox` is unattended by construction |

> **AMENDED 2026-08-20 (issue #656).** `riskIssueCount` now gates the lane's
> *only* Phase-2 lens rather than the fourth of four (§3). The envelope's keys,
> shape and marker pair are otherwise unchanged.

### 4.3 Untrusted input

Unchanged and non-negotiable. Issue bodies, PR bodies, comments and fetched web
content are data. They reach an agent as a **path to a private run artifact**,
wrapped at the reading end in `<external-untrusted-input>`, never as prompt
text and never as instructions. The controller never interpolates issue text
into a dispatch prompt.

---

## 5. Alternatives considered

| Alternative | Verdict |
| --- | --- |
| `--backend=standard` in the `dispatch_backend` enum | **Rejected** — §2. Wrong meaning for nine consumers, for a value none of them can reach. |
| One orchestrator agent per issue, fanning out | **Rejected** — §3.1. Depends on unverified nested dispatch, and degrades silently rather than loudly. |
| Replace the Workflow lane with this one | **Rejected.** The Workflow lane's context economy, `/workflows` progress tree and structured return are real advantages for batch work. Two lanes, one launcher. |
| Per-issue pipelining instead of phase synchronisation | **Rejected** — §3.2. Hand-written event loop in a session with no scheduler. |
| Per-task worktrees instead of Pattern B | **Rejected.** N worktrees plus a merge step, to solve a race that a proven-disjoint partition already prevents. `subagent-driven-dev` settled this; re-deciding it here would fork the contract. |
| Reuse `WORKFLOW_ARGS_BEGIN/END` for the plan | **Rejected** — §4.2. Those markers are an instruction to call `Workflow()`. |

---

## 6. Acceptance criteria

1. `/turbox 1 5 3` validates all three issues, claims them, and emits one
   `TURBOX_PLAN_BEGIN/END` envelope naming all three. No `WORKFLOW_ARGS`
   marker appears on the standard-mode path.
2. `--standard` with an explicit `--backend=` (flag or env) exits non-zero
   **before** any claim is written, naming both tokens.
3. `fanout_concurrency.turbox` resolves 1..3, defaults to 3, and clamps a
   larger configured value to 3 with a stderr note.
4. `turbox-fleet.sh wave-disjoint` returns 3 on an equal-path overlap, 3 on a
   directory-containment overlap, 2 on missing ownership, and 0 on a genuinely
   disjoint wave.
5. `turbox-fleet.sh stage-commit` refuses `-A`, `--all`, and a `.` pathspec, and stages
   exactly the paths it was given.
6. TB1 aborts before dispatch when the projection exceeds `maxAgents`; TB2
   still runs delivery on committed work when the implement budget is
   exhausted.
7. The command file mandates the launcher call and the skill, and does **not**
   declare the `Workflow` tool.
8. `tests/turbox-fleet.test.sh` is wired into both `.github/workflows/test.yml`
   jobs, and `tests/turbox-fleet-runtime.test.sh` into the ubuntu job plus the
   `ci-wiring windows-skip-list` marker block, where it refuses to run under Git
   Bash (`tests/ci-wiring.test.sh` W4 and W9 enforce both halves).

### Where each criterion is proved

An acceptance criterion with no executing predicate behind it is a wish. Each
row names the fixture section that runs it, so a criterion cannot quietly stop
being true.

| AC | Proved by | Note |
| --- | --- | --- |
| 1 | `turbox-fleet.test.sh` TX10 | the ordering assert — the standard branch `exit 0`s before the Workflow emit, so the two envelopes are mutually exclusive by construction. The live end-to-end run needs real issues and is **not** covered. |
| 2 | `turbox-fleet-runtime.test.sh` R11 | both arms, flag and env, asserting rc **and** the "no claims written" line |
| 3 | `turbox-fleet-runtime.test.sh` R3 | default, honoured values, clamp above, floor below |
| 4 | `turbox-fleet-runtime.test.sh` R7 | equality, containment **both directions**, the shared-prefix negative control (`lib/a.sh` vs `lib/ab.sh` must NOT collide), cross-wave, missing, malformed |
| 5 | `turbox-fleet-runtime.test.sh` R8 | every refusal, plus the positive control: an untracked sibling in the same tree must not land in the commit |
| 6 | `turbox-fleet-runtime.test.sh` R4 (TB1) and R5 (TB2) | R4 executes the projection over both arms: 1 small + 2 design at `implementBudget` 24 is **55** agents and fits the 600 ceiling; 30 design issues is **810** and is refused with rc 3. TB2's "still deliver" half is a **skill directive**, not an executed predicate — see the boundary below |
| 7 | `turbox-fleet.test.sh` TX1, TX2 | the `allowed-tools` line is grepped for the absence of `Workflow` |
| 8 | `tests/ci-wiring.test.sh` W4, W9 | wiring and the Unix-only refusal |
| — | `turbox-fleet-runtime.test.sh` R12 | the plan envelope, composed by the python program **extracted verbatim from the launcher** rather than a hand-copied twin |

> **AMENDED 2026-08-20 (issue #656).** The AC-6 row's R4 numbers moved with the
> design-rung count (9 → 3, §3.7): the projection is now
> `small + (3 + implementBudget) × design`, so R4's fitting arm reads 55 where
> it read 67 and its refusing arm 810 where it read 990. The refusal case is
> preserved — 810 still exceeds the 600 ceiling — so R4 keeps proving both
> halves of TB1 rather than only the one that fits.

**Declared boundary.** The lane's *safety* guards are executable and asserted by
exit code: the disjointness refusal, the staging refusals, the loop caps, the
budget counter, the envelope shape. The lane's *orchestration* — one-message
dispatch, phase synchronisation, the fix-ladder ordering, delivering after a TB2
cut-off — is prose in `skills/turbox-fleet/SKILL.md` that the controller
follows, exactly as `dev-pipeline` and `subagent-driven-dev` are. A controller
that ignores the skill cannot defeat the guards, but it can be slower than this
RFC claims. Nothing here proves a model *executed* a phase.
