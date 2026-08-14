---
name: solve-fleet
description: Workflow-native per-issue solver fleet backing /uberdev:solve and /uberdev:turbo. Not invoked directly — lib/solve-launcher.sh emits the args envelope with backend=workflow and the command files mandate the Workflow call into skills/solve-fleet/workflow.js. RFC 0015 (the detached-session retirement).
model: inherit
---

# Solve-fleet — the Workflow-native `/solve` + `/turbo` transport

This skill hosts `skills/solve-fleet/workflow.js`, the Workflow script that runs
one solver agent per GitHub issue. It is **not invoked directly by users** and it
is not a second pipeline: `solve-pipeline` still owns the whole user-facing
lifecycle (flags, triage, claims). This is only the **transport** — the thing
that replaced detached `claude --bg` sessions (RFC 0015).

## Why this replaced the detached `claude --bg` transport

That backend dispatched each issue as a detached `claude --bg` session. Those
sessions:

- live in a **separate agent surface** the user has to switch to and poll —
  orchestration progress is invisible from the session that started it;
- carry their **own permission tier and lifetime**, so a batch can outlive the
  session that launched it with no supervision from it;
- give the launcher **no structured result**: outcome discovery is "go look at
  `claude agents`, then go look at GitHub".

The Workflow runtime gives the same parallelism with a live `/workflows`
progress tree, deterministic control flow with real counters, structured
per-issue returns, and **no second surface**. `auto` therefore resolves to
`workflow` on every Claude host. The detached `claude --bg` backend was first
deprecated and then **deleted** once /review-pr and /simplify resolved
`workflow` too and nothing on any default path could still reach it (RFC 0015
§7 as amended). `codex` was deleted with it in the same issue. `background`
and `wezterm` remain as the explicit detached transports.

## The leaf constraint (why the design phases live in the script)

A Workflow agent has **no Agent/Task tool** — it cannot fan out. The historical
medium/full-tier prompt told the detached session to invoke
`/uberdev:orchestrator`, which fans out research, spec, plan and SDD waves. A
leaf agent cannot do that, so **the orchestration moved into the script**:

| Tier | What the fleet runs |
|---|---|
| `trivial`, `small` | ONE solver agent (`isolation:"worktree"`). Unchanged from the detached-session behaviour — those tiers were always a single session. |
| `medium`, `large` (`--full`) | `parallel()` research fan-out (codebase / constraints / test-coverage) → spec writer → spec reviewer (**one** revision round, never unbounded — the #308 class; its blocking findings are forwarded to the plan writer inside an untrusted-input envelope, #507) → plan writer → a **sequential per-task loop** (implementer → reviewer → bounded fix ladder, at most `FIX_ROUNDS` = 3 fixes and 4 reviews per task) in ONE script-named worktree at `<runDirAbs>/worktrees/issue-<N>` → one delivery agent (full suite, push, PR). |
| any tier with **no usable plan** | falls back to the single solver above — no plan means no tasks, so there is no boundary a **review gate** could sit on. |

Only the **solver** is worktree-isolated. The research and design agents are
read-only and write their artifacts to absolute paths under the run dir — an
isolated researcher would write into its own throwaway worktree and the artifact
would vanish (the artifact path-leak class this project has hit before).

**Why the per-task path uses no runtime isolation.** `isolation:"worktree"` hands
out an *anonymous* checkout: the script never learns its path, and a second
isolated agent gets a different one. A single agent needs no name, so it keeps
runtime isolation. A *chain* of agents must address one shared checkout by path,
which runtime isolation structurally cannot provide — hence the script-derived
`<runDirAbs>/worktrees/issue-<N>`, cut by task 1 with `git worktree add` and
reported back as `workspaceReady`. If task 1 cannot open it the chain stops with
`workspace_not_ready` and **no delivery agent runs**; a task agent is told
explicitly never to fall back to the repository root.

**Why sequential and not wave-parallel.** The win is fresh context per task plus
a gate per task, and both are available one task at a time — with no git mutex,
no disjoint-ownership validation and no two agents writing one checkout. Each
task is left as exactly ONE commit; each fix round `--amend`s it, so the
reviewer's target is always `git show HEAD` and no commit SHA is ever threaded
through a prompt. Reviewer findings travel **on disk only**
(`<runDirAbs>/issue-<N>/task-<k>/review-<r>.md`); the fixer is given those paths,
never the text, which is what keeps this script free of the `SHARED:envelope`
block.

## What you give up (RFC 0015 §6 — say these out loud, never silently)

| Loss | Detail | Escape hatch |
|---|---|---|
| Survive-the-parent | closing the session, `/clear` or a compact kills every in-flight solver | `--backend=background` |
| Per-child model / effort / permission tier | the Workflow API has no per-agent effort or permission option, so solvers inherit the **session's** model, effort and tier. `/turbo --auto`'s bypass is no longer scoped to children. | raise the session's own settings, or `--backend=background` |
| In-flight cancellation via `lib/dispatch.sh` | cancellation belongs to the Workflow runtime (`TaskStop` / skip), not to this library | `/workflows`, `TaskStop` |
| Status records / lifecycle manifest / capacity lease | the fleet's observability is the progress tree + the structured return, not machine-readable per-issue JSON | `--backend=background` for machine consumers |
| Claim safety on a never-relayed run | claims are written by the launcher *before* the model relays the args, so an un-relayed run holds claims with nothing running | `gh issue edit N --remove-label uberdev:active` (a `--reap-stale-claims` sweep is owed) |

## What did NOT move

Everything up to and including the claim protocol still runs in
`lib/solve-launcher.sh` and is unchanged: validate-all-first, triage, route
resolution, the prepared root request + context files, and the Step 4.5
`uberdev:active` claims. The script starts from the manifest that pass wrote.

## Invocation contract

`lib/solve-launcher.sh` Step 5w validates the on-disk script exists BEFORE
emitting anything (RFC 0012 §4.1) — a missing/misnamed `workflow.js` on a target
install must refuse cleanly at preflight, not fail later at the runtime layer:

```bash
SOLVE_FLEET_WORKFLOW_JS="$UBERDEV_PLUGIN_ROOT/skills/solve-fleet/workflow.js"
[ -f "$SOLVE_FLEET_WORKFLOW_JS" ] || { echo "error: ... missing (RFC 0012 §4.1)" >&2; exit 2; }
```

It writes `$UBERDEV_TMPDIR/solve-fleet-manifest.json` (one record per issue:
`issue`, `tier`, `prompt_file`, and the `context_file`/`context_sha256` from the
prepared root request), then emits the args envelope via
`uberdev_emit_workflow_args solve-fleet …` between the
`WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` markers. The command file relays that
JSON **verbatim** (DR-2 — no LLM-composed handoffs):

```
Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/solve-fleet/workflow.js"}, <the JSON between the markers>)
```

### Envelope keys

| Key | Meaning |
|---|---|
| `manifestPathAbs` | the per-issue manifest the `intake` relay reads |
| `issues` | comma-joined issue numbers — cross-checked against the manifest |
| `issueCount` | declared count; a mismatch is recorded as an audit event |
| `concurrency` | wave size (`fanout_concurrency.solve_bg`, default 6) |
| `autoMode` | true for `/turbo` (unattended) |
| `runDirAbs` | where prompts, contexts and per-issue design artifacts live |
| `repoRootAbs`, `pluginRootAbs`, `repoSlug`, `branchPrefix` | script-derived prompt inputs |
| `solveTimeoutS` | **advisory** per-issue budget, reported not policed (the runtime forbids clocks — DR-7) |
| `maxAgents` | CB1 projected-agent ceiling (launcher default 600) |
| `implementBudget` | CB3 per-issue implement-phase agent cap; default 24, clamped 4..96, `UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET` overrides |

## Circuit breakers

| ID | Guard |
|---|---|
| CB1 | projected agents (`2 + issues + (6 + implementBudget − 1) × design-tier issues`) over `maxAgents` → abort **before** any dispatch. The leading 2 is the intake relay plus the batched PR-verification relay (#515); the per-issue term is the #508 per-task chain, bounded by CB3's `implementBudget` (default 24). `T` is unknowable before the plan is written, so the projection uses the live cap — deliberately pessimistic. |
| CB2 | runtime `budget` exhausted between waves → stop, report, leave remaining claims intact |
| CB3 | a **live** counter of implement-phase agents per issue against `implementBudget`. On exhaustion the task loop stops, the remaining tasks are recorded `SKIPPED`, `implement_budget_exhausted` is audited — and delivery still runs on what is already committed (the one dispatch deliberately exempt, so reviewed commits never strand in a worktree). |
| — | a per-issue chain that throws is caught and recorded as `FAILED` for that issue only; one bad issue never takes the batch down |

Wall-clock breakers are impossible in-script (the runtime forbids
`Date.now()`); the `budget` cap plus CB1/CB2/CB3 cover the live failure modes.

Degradation inside the task chain is recorded, never silent:
`task_implementer_null`, `task_implementer_blocked`, `task_review_null` (the
task is marked UNREVIEWED and the loop **continues** — a skipped agent must not
strand committed work), `task_review_rejected`, `task_fix_rounds_exhausted`,
`task_fixer_null`, `task_count_clamped`, `workspace_not_ready`.

## Return value

The script logs `WORKFLOW_RESULT <json>` and returns:

```
{ runId, repoSlug, issueCount, concurrency, autoMode, designedIssues,
  researchArtifacts, results: [ {issue, status, branch, prNumber, prUrl,
  commitCount, testsRunClaimed, summary, blocker,
  prProof, provenCommitCount, claimedStatus, claimedPrNumber, claimedPrUrl,
  tasks: [{id, status, reviewVerdict, fixRounds, commitCount}]} ],
  prsOpened: [<int>],
  counts: {prOpened, pushedNoPr, committedNotPushed, noChangesNeeded, refused, failed},
  tasksTotal, tasksApproved, tasksBlocked, tasksUnreviewed,
  verification: {probed, confirmed, disproven, unverified, notApplicable, relayRc},
  cb1Tripped, cb2Tripped, nullsByPhase, auditEvents }
```

`status` ∈ `PR_OPENED | PUSHED_NO_PR | COMMITTED_NOT_PUSHED | NO_CHANGES_NEEDED
| REFUSED | FAILED`. Per-task `status` ∈ `DONE | NO_CHANGES | BLOCKED | SKIPPED`
and `reviewVerdict` ∈ `APPROVE | REVISIONS_REQUIRED | REJECT | UNREVIEWED | ""`
(empty when the task committed nothing, which skips the gate and burns no fix
round). `tasks` is absent on the single-solver path, which has no tasks. The
fleet never merges and never chains into a review command — opening the PR is
where it stops.

## Claim verification (#515)

A solver's structured return is a **self-report**. `status` drives every count
above *and* the PR set `/goal` ingests, so the fleet no longer takes it on
trust: in the `deliver` phase a single read-only **haiku relay** queries GitHub
for every claimed PR (`gh api -i .../pulls/<N>`, one call per number, bounded
in-agent retry) and returns **raw observations only** — HTTP status, `number`,
`head.ref`, `state`, `commits`. It reaches no verdict. The **script**
adjudicates, downgrades and audits.

| Field | Meaning |
|---|---|
| `prProof` | `CONFIRMED` · `DISPROVEN` · `UNVERIFIED` · `NOT_APPLICABLE` |
| `provenCommitCount` | commits GitHub reports on the PR (`null` when not observed) |
| `claimedStatus` / `claimedPrNumber` / `claimedPrUrl` | present only on a downgraded record — the original claim, preserved |
| `verification` | run totals; `relayRc` is `null` when the relay never ran |

The rule: **the proof wins in the field that drives behaviour, the claim is
never erased, and the disagreement is an audit event.** `status` is overwritten
on disproof (with the claim moved into `claimed*`); `commitCount` drives nothing
so the claim stays and the proof lands beside it in `provenCommitCount`.

Only two observations disprove a claim — an authoritative **404**, and a **200
naming a different head branch**. Everything else (no relay, a null relay, a
non-zero rc, a missing row, 0/401/403/429/5xx) classifies `UNVERIFIED` and
**retains** the claim: a probe that cannot speak must never drop a real PR out
of `/goal`'s queue. A status is never *upgraded* — a non-`PR_OPENED` record
carrying a PR number is audited, never promoted.

`testsRunClaimed` is deliberately **honest, not verifiable**: nothing here can
falsify it, so nothing reads it.

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini, Copilot, pre-Workflow Claude
Code), re-run the launcher with an explicit detached backend:

```bash
bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=<0|1> -- <args> --backend=background
```

`--backend=background` is the only detached backend this fallback names, and it
is complete on its own. **`--backend=codex` is an enum error** — #381 deleted
that backend (`lib/dispatch.sh:509`) along with the `CODEX_HOME` auto-escape
(`lib/dispatch.sh:682-685`), so there is nothing to select inside a Codex
session either. The surviving detached backends are unchanged and remain fully
tested; only their selection priority changed.
