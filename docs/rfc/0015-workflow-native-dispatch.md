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

~~`claude-bg` is **deprecated**, not deleted: `--backend=claude-bg` still works,
still passes its full test suite, and now prints a one-line deprecation notice.
Removal target **v1.0.0**.~~

> **AMENDED 2026-08-05 (issue #381).** `claude-bg` was **DELETED**, ahead of the
> v1.0.0 target stated above. Every clause struck through is now false:
> `--backend=claude-bg` is an enum error, not a working flag
> (`_UBERDEV_DISPATCH_BACKEND_ENUM` is `auto|workflow|wezterm|background`,
> `lib/dispatch.sh:509`); its test suite was removed with it; and the
> deprecation-notice machinery was deleted rather than left dormant, because a
> dormant alias is how a retired transport drifts back onto a default path.
> See §7 for the reasoning and the retraction of the objections this section
> originally raised.

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
must name a detached backend explicitly (~~`--backend=claude-bg`, until its v1.0.0
removal~~ — **#381 deleted that backend; read `--backend=background`, §7**).
Nothing reaches a detached transport by default any more, on any command.

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
| `medium`, `large` | `parallel()` research fan-out (codebase / constraints / test-coverage — plus a fourth **`security` lens** on any issue whose relayed triage `risk_signals` hold at least one non-blank entry) → spec writer → spec reviewer (its blocking findings are forwarded to the plan writer inside an untrusted-input envelope, #507 — and to the reviser below, in the same envelope, whenever one runs) → **one** bounded revision round on any non-`APPROVE` verdict, writing a sibling `spec-r1.md` instead of rewriting `spec.md` in place, and never re-reviewed → plan writer, pointed at the revision only when it lands at exactly that path → **plan reviewer**, whose blocking findings ARE its output (nothing rewrites the plan) and are forwarded in the same envelope to all three rungs that read it — the implementer, task reviewer and fixer → a sequential per-task chain (implementer → reviewer → bounded fix ladder) in one script-named worktree, then one delivery agent (#508). |

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
| CB1 | projected agents (`2 + issues + (9 + implementBudget − 1) × design-tier issues`) over `maxAgents` → abort **before** any dispatch. The leading 2 is the intake relay plus the batched PR-verification relay (#515); the per-issue term is the #508 per-task chain, bounded by CB3's `implementBudget` (default 24). `T` is unknowable before the plan is written, so the projection uses the live cap — deliberately pessimistic, and the same way about the two other conditional rungs: the spec-revision round (no verdict exists yet at projection time) and the risk-gated `security` research lens — whose gate IS readable by then, but whose cost is a per-design-issue constant shared with `/goal`'s own cycle projection, which runs before any manifest exists. The plan review needs no such allowance: every accepted plan is reviewed. |
| CB2 | runtime `budget` exhausted between waves → stop, report, leave remaining claims intact |
| CB3 | (#508) live per-issue implement-phase agent counter over `implementBudget` → stop the task loop, record the remaining tasks `SKIPPED`, audit `implement_budget_exhausted`, and still deliver what is committed |
| — | manifest/envelope cross-check: only issues the launcher actually claimed are solved; a mismatch in either direction is audited, never silent |
| — | a per-issue chain that throws is caught and recorded as `FAILED` for that issue alone |
| — | `underRunDir()` on every agent-returned artifact path before it reaches a downstream prompt |

Wall-clock breakers are impossible in-script (DR-7). `budget` + CB1 + CB2 cover
the live failure modes — the same resolution scan-fleet reached.

### 4.3 Discipline inherited from the surrounding project

The solver prompt carries the house rules that have no human in the loop to
enforce them on `/turbo`: root-cause fixes, tests-first, conventional commits,
**no `Co-Authored-By` / AI attribution trailer**, `--body-file` never inline
`--body`, an issue-linkage line in the body, no `--force`, no `--no-verify`,
and — new, and specific to parallel batches — **no version bump**: every solver
bumping to the same next version is the collision class this repo has hit
repeatedly. Releases stay serial and operator-driven.

The linkage line is **conditional on what the run actually finished** (#554),
because linkage and completeness were one token and a chain that stopped at task
2 of 5 still auto-closed its issue. A single solver, and a per-task chain whose
`chainComplete` is `true`, carry `Closes #N` and close the issue on merge. A
chain that fell short carries the non-closing whole-line trailer
`UberDev-Partial: #N` and no closing keyword anywhere — not in the body, not in
a commit message, since GitHub honours them in both — so the issue survives the
merge OPEN with the unreached tasks still on it. `/merge` Step 3.4 parses that
trailer to release the `uberdev:active` claim regardless, so an unfinished issue
is left re-solvable rather than claimed by nobody.

`chainComplete` reaches `/goal` as well (#592), and every hop is named by
symbol because the line numbers rot: `finalize()` publishes the partial subset
of `prsOpened` as `prsPartial`; the partial ledger in
`skills/goal-pipeline/workflow.js` accumulates that subset, plus the issue
numbers the same flag names in `results`, for the whole run; and it hands them
to the two shell gates on the only channel a script forbidden the filesystem
has — the command line — as `--partial-prs=` and `--partial-issues=`. From
there the `merge-dispatch-gate` region of `lib/goal-watch.sh` marks the
`green → merging` decision as a partial delivery, and the `terminal` region of
`lib/goal-phase3.sh` refuses to emit `goal_converged` while any issue in the
run delivered a short chain. The PR still merges; what changes is that the run
stops reporting a convergence it did not achieve.

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

### 5.6 The solver-side bump ban left nobody holding the bump (issue #364)

`skills/solve-fleet/workflow.js` tells every solver: *do not bump the project
version, do not touch CHANGELOG.md, the manifests, the README badge, or the
version-lock tests.* That instruction is correct and stays. N solvers branching
off one base all resolve the **same** next version; the two diffs are byte-
identical, so git auto-merges them without a conflict and the second landing
silently eats the first bump (`project_uberdev_merge_version_collision`).

What §5 shipped without was anyone downstream who added the bump back.
`_uberdev_goal_rebase_collision_chain` *renumbers* a bump that already exists —
it has never created one — so a `/goal` run landed PRs that touched **zero**
version surfaces. That is a silent failure by construction: the two CI
version-lock tests assert the surfaces AGREE WITH EACH OTHER, never that the
version ADVANCED. An unbumped landing leaves every surface consistently at the
old value, CI stays green, and the marketplace never serves the update — exactly
the outcome the mandatory-bump rule exists to prevent. PR #363, produced by a
real `/ubergoal` run, would have been auto-merged that way.

The bump belongs to the **landing** step, and only there. `lib/goal-watch.sh`
step 2c acts on exactly one green PR per pass (strict lowest-first) and holds
the `MERGING` sentinel until that PR lands (#289.2) — the one strictly-serialized
point in the run. At that moment `origin/<base>` already carries the previous
landing's bump, which is what makes sequential numbering correct here and
colliding anywhere earlier. So `_uberdev_goal_ensure_version_bump <pr>`
(`lib/goal-state.sh`) runs immediately **before**
`_uberdev_goal_dispatch_merge <pr>`, and the ordering is the entire contract:

- **Next version from the BASE, never the PR branch.** A PR that branched before
  two releases landed sits *below* its base; a `head != base` test would read
  that as "already bumped". The predicate is strictly-greater.
- **Kind from the PR's conventional-commit type** — `feat:` → minor, a `!`
  marker or a `BREAKING CHANGE:` footer → major, everything else → patch.
> **AMENDED 2026-08-05 (issue #381).** "Seven surfaces" is now SIX everywhere
> below. `codex/uberdev-codex/.codex-plugin/plugin.json` was surface 3 until the
> Codex distribution was retired; `lib/bump-version.sh` and
> `skills/merge-pipeline/lib/release-anchor.sh` both dropped it in the same
> commit, and `tests/merge.test.sh` M98.ssot still asserts the two lists agree.
> Nothing else about the release-anchor predicate changed — in particular two of
> the six are still executable test files, which is why a path allow-list alone
> is still not the predicate.

- **`lib/bump-version.sh` owns the seven-surface edit.** It already refuses on
  drift (exit 3) and re-verifies every surface after writing (exit 4); this path
  leans on it rather than re-implementing the surface list. The work happens in a
  throwaway **detached worktree** at the PR head — never the `/goal` session's
  own checkout, whose index must stay pristine
  (`project_uberdev_turbo_main_index_pollution`).
- **FAIL CLOSED.** Any failure returns non-zero, `/merge` is not dispatched, the
  PR stays `green` for a later pass, and a `goal_merge_deferred` row carrying
  `reason=version_bump_failed` plus the exact `stage` lands in the audit stream.
  Merging unbumped IS the bug, so merging is never the fallback. A fork
  (cross-repository) head is refused for the same reason: `origin` is not its
  remote, and pushing there would create a stray branch on the base repo instead
  of updating the PR.
- **Never `--force`.** A rejected non-fast-forward push means the branch moved
  under us; the correct response is to fail closed and re-derive next pass.
- Repos with no `plugins/uberdev/.claude-plugin/plugin.json` carry no version
  ratchet, so the step is **skipped** (audited, never silent) instead of blocking
  `/goal` on every other repository.

- **Kind from the PR's COMMITS as well as its title.** A `/goal` PR title is
  written by the solver agent, not a release engineer, so a `fix(...)` title
  over a `feat:` commit would ship a feature as a patch. `gh pr view --json
  commits` returns the messages in one round-trip; commit subjects feed the
  `feat:`/`!` probes and commit bodies feed the `BREAKING CHANGE:` probe
  alongside the PR body. Highest wins.

The new audit event is `goal_version_bumped` with
`action ∈ {bumped, already_bumped, skipped}`; the failure path deliberately
reuses `goal_merge_deferred`, because the merge really was deferred.

#### 5.6.1 Landing a bump on an already-reviewed head

The bump lands *after* `/review-pr` anchored its trust trail. That is inherent
to putting the bump at the serialized lane, and it is the right trade: the
alternative — bump before the review — buys a correct trailer for free and
reopens the collision class the solver-side ban exists to close, because nothing
before step 2c is serialized. Serializing the bump on its own would be most of
the merge-lane machinery rebuilt. So the lane pays, in two places.

**(a) The trust trail, paid in `/merge`.** `/merge` Phase 1.4 PATH_2 (b) reads
the `Reviewed-by: uberdev/review-pr@<sha>` trailer off the most-recent commit,
and (c) delegates the trailer SHA to `trust-trail-evaluator`, which returns
`STALE` on a non-empty cumulative diff. A release commit on top therefore fails
(b) with `trust_trail_trailer_missing` and would fail (c) with
`trust_trail_stale_sha` — the latter explicitly excluded from the Step-1.4.5
auto-review recovery — while PATH_1 is unreachable because `/review-pr` never
calls `gh pr review --approve`. PATH_2 gains sub-condition **(a.5)**: resolve a
`TRUST_HEAD` via `skills/merge-pipeline/lib/release-anchor.sh` and evaluate (b)
and (c) against it. The helper returns `tolerated` — trust head = the release
commit's parent — only under a structural proof that the commit changed no
reviewed code:

1. exactly one parent (never a merge),
2. subject exactly `chore(release): vX.Y.Z`, anchored at both ends,
3. the parent is not itself a release commit (tolerance depth is exactly 1, so
   code cannot hide two release subjects deep),
4. a non-empty diff confined to the seven version surfaces,
5. the canonical manifest version strictly advances, to the subject's version,
6. outside `CHANGELOG.md`, the removed and added line **sequences** are
   byte-identical once SemVer tokens (including the backslash-escaped forms the
   version-lock tests carry inside regexes) are normalised away,
7. `CHANGELOG.md` is bounded, insertion-only, release-section shaped.

Conditions 6 and 7 are why the predicate is not "subject + path allow-list":
two of the seven surfaces (`tests/goal.test.sh`, `tests/solve-claim.test.sh`)
are executable test files, so a path allow-list alone would be a channel for
smuggling arbitrary test edits past the trust gate. The comparison is
order-sensitive for the same reason — a multiset comparison would tolerate
*reordering* lines of an executable file while every individual line stayed
byte-identical. Any unproven condition, any helper error, any non-zero exit
resolves `TRUST_HEAD` back to `headRefOid`, i.e. the pre-#364 gate. The
`trust-trail-evaluator` agent is not modified and still demands an empty
cumulative diff; `TRUST_ANCHOR_ENUM` and `GATE_FAIL_REASON_ENUM` are unchanged
(a tolerated anchor is recorded as a D15 field-level extension,
`gate_pass.data.release_anchor`).

**(b) The restarted checks, paid in `/goal`.** The push re-triggers the PR's
workflows, and `/merge` Step 1.4 classifies a non-empty rollup carrying any
pending entry as `gate_fail reason=ci_red`; its null-rollup settle probe is
bounded at `CI_ROLLUP_SETTLE_RETRIES` × `CI_ROLLUP_SETTLE_INTERVAL_SEC` = 30 s
against a CI critical path of minutes. Dispatching straight after the push is
therefore a deterministic gate-fail that burns one of the three
`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS`; after three, `uberdev_goal_should_automerge`
returns 1, the `elif` chain takes no arm, the PR sits in `green` forever,
`uberdev_goal_batch_all_terminal` never clears, and the run dies on the 4h
`stuck_loop` breaker. `_uberdev_goal_ensure_version_bump` therefore reports a
**three-way** status — `0` already bumped / no ratchet, `1` could not guarantee,
`2` pushed just now — and step 2c defers on `2` and, independently, on
`_uberdev_goal_pr_checks_pending <pr>`. Neither deferral burns a merge attempt
(the counter lives inside `_uberdev_goal_dispatch_merge`), both emit
`goal_merge_deferred` (`reason=ci_restarted_by_version_bump` / `ci_pending`),
and the CI-settle gate is withholding-only: a `gh` failure or an
unconfigured-checks repo returns rc 1 and falls through to `/merge`, which owns
the hard CI gate. The 4h `stuck_loop` wall clock remains the backstop for a
check that never completes.

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
  the deliberate fire-and-forget case, and ~~`--backend=claude-bg`~~ was exactly
  that escape hatch until v1.0.0 — **#381 deleted it; `--backend=background` is
  the surviving one, see §7**.
- **R-1b — per-child model, effort and permission tier are inexpressible.**
  The detached backends passed `--model`, `--effort` and the
  `--dangerously-skip-permissions --permission-mode bypassPermissions` pair as
  explicit child argv. The Workflow API has no per-agent effort or permission
  option, so fleet solvers **inherit the session's model, effort and permission
  tier**. Two consequences worth stating outright: `/turbo --auto`'s bypass is
  no longer scoped to the children — it is whatever the session already has;
  and a session running below `max` effort produces lower-effort solvers than
  the same command would have on a detached backend. Users who need the pinned
  tier should use `--backend=claude-bg` (**deleted in #381 — read
  `--backend=background`, see §7**) or raise the session's own settings.
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
  decomposition; both writer/reviewer pairs are always-on since #524, but their
  correction rounds are BOUNDED — one for the spec, none for the plan — rather
  than iterated to agreement). RFC 0012 Phase 6 remains the path to full parity;
  until then `--backend=claude-bg` reaches the original pipeline (**#381 deleted
  that backend; `--backend=background` reaches it now, see §7**).
  **#507 closed the first half of the gap**: the reviewer's
  blocking findings are no longer collected and discarded — they are sanitised (count and
  per-string caps enforced in-script, because a schema `maxItems` is a request to
  the model, not a runtime constraint) and threaded into the plan writer's prompt
  behind the `SHARED:envelope v1` carrier, so a non-APPROVE verdict tells the
  planner WHAT is wrong instead of only that something is. Threading is
  presence-driven, not verdict-driven: an APPROVE with caveats is forwarded too.
  **#524 item 1 closed the spec-reviser gap**: a non-`APPROVE` verdict now buys
  ONE bounded spec-revision round, writing a sibling `spec-r1.md` that the plan
  writer is pointed at only when it lands at exactly that path — and charging
  that rung is what moved the CB1 constant to 7.
  **#524 item 2 closed the plan-review gap**: the plan — the artifact the
  implement phase actually executes, and the last design artifact with no review
  at all — is now reviewed on every accepted write, moving the CB1 constant to 8,
  which `tests/docs-accuracy.test.sh` T14 locks against this document. There is
  deliberately no plan REVISER (a second bounded ladder is a second rung on the
  ceiling), so the reviewer's blocking findings are its entire output: they are
  sanitised and enveloped by the same #507 carrier and forwarded to all three
  rungs that read the plan. All three, because the per-task reviewer already
  treats work outside a task's section as a blocking finding — telling only the
  implementer that a plan-review finding may be answered would put the two gates
  in contradiction over one document and burn a fix round on correct work.
  **#524 item 3 closed the security-research gap**, moving the CB1 constant to 9:
  the launcher already computed a triage risk predicate for every issue and
  persisted it into the prepared root request, and it was dropped on exactly one
  hop — the per-issue manifest record, which is the only channel into a Workflow
  script. That hop now carries it, and an issue with at least one non-blank
  signal buys a fourth `security` research lens. Presence and counts only: no
  signal string reaches a prompt or an audit event, and the script applies no
  risk vocabulary of its own. Because an absent field and an empty one gate the
  lens identically, the launcher also declares a run-wide `riskIssueCount` that
  the script joins against the relayed records — otherwise a relay that dropped
  the field would be indistinguishable from a risk-free batch. The parity gap
  that remains is the SDD wave decomposition named at the top of this entry, not
  a missing research or review rung.
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
  fallback** naming the explicit backend to re-run with, and ~~`auto` still
  resolves to `codex` inside a Codex session~~.

  > **AMENDED 2026-08-05 (issue #381).** `auto` no longer resolves `codex`
  > anywhere — the backend and both of its `auto` escapes are deleted
  > (`lib/dispatch.sh:509`, `:682-685`). The mitigation is unchanged in
  > substance but narrower in fact: the No-Workflow fallback names
  > `--backend=background`, which is the only detached transport a Codex
  > session (or any other runtime without the tool) can now select.

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

> **AMENDED 2026-08-05 — `claude-bg` is now DELETED.** The rejection below was
> conditional ("Deprecate, then remove on evidence"), and the evidence arrived.
> `workflow` shipped and stayed shipped across `/solve`, `/turbo` and `/goal`
> (§5), and then across `/review-pr` and `/simplify` — the last two workflows
> that structurally required a detached transport, because they need an atomic
> child result artifact plus caller-workspace repair. Both halves now exist on
> the Workflow-native path: every bound child publishes `result.md` and a
> nonce-bearing `status.json` by same-directory rename, and the controller
> digests both through `lib/code_fixer_contract.py`. With those two resolving
> `workflow`, `claude-bg` was the transport that nothing selected and nothing
> required, and `auto` had already been forbidden from reaching it.
>
> Two things the original rejection weighed are answered rather than waived:
>
> - *"no fallback if the new transport disappoints"* — `background` remains.
>   (`codex` was named here when this note was written and was deleted two
>   commits later in the same issue; only `background` survives, which
>   strengthens rather than weakens the argument — the fallback that was kept is
>   the one every No-Workflow section actually names.) `background` is the same
>   shape (detached, survives the parent, PID-tracked, status + result files)
>   without the second agent surface that motivated this RFC.
> - *"~170 lines of mature, heavily-tested transport"* — the tests went with the
>   code. `tests/dispatch-claude-bg.test.sh` is deleted rather than retargeted,
>   and the S4a/S4b/S4c deprecation guards in
>   `tests/solve-fleet-workflow.test.sh` are **inverted into tombstones** (the
>   surface must now be ABSENT), mirroring
>   `tests/ghostty-dispatch-no-instance-leak.test.sh`. No check that still
>   guards live code was relaxed.
>
> **This also supersedes RFC 0004 §3.5** (*"The `claude-bg` backend (current
> behaviour, formalised)"*), which described the extracted
> `_uberdev_dispatch_claude_bg` provider arm. RFC 0004's remaining per-backend
> transports (`wezterm`, `background`), receipts and supervision contracts are
> untouched and stay canonical.
>
> Deleted with it, because each had exactly one consumer: the
> `claude-bootstrap` long-poll + ownerless-generation reclaim protocol in
> `lib/dispatch.sh`'s git-metadata mutex; `BG_PROMPT_MODE`; the
> `_uberdev_agent_claude_probe` liveness classifier; the unattended-permissions
> preflight; and the `provider_probe_failed` / `provider_cancel_failed`
> watcher-error kinds, whose only writer was that probe's `blocked:` vocabulary.

- **Delete `claude-bg` outright.** ~~Rejected~~ **— accepted on evidence, see the
  amendment above.** The original reasoning: it is ~170 lines of mature,
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
