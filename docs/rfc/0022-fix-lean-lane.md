# RFC 0022 — `/fix`: the lean single-issue lane

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-08-24 |
| **Tier** | Medium (a narrowing of an existing execution lane, across launcher, command and skill — no new lib) |
| **Target ver** | `0.57.0` |
| **Targets** | new `commands/fix.md`; new `skills/fix-fleet/SKILL.md`; `lib/solve-launcher.sh` (the `--fix` option, the FX1 arity refusal, Step 5f); `lib/turbox-fleet.sh` (`audit --basename`); `lib/aliases-sync.sh`; `commands/install-aliases.md`; `commands/uninstall-aliases.md`; `skills/using-uberdev/references/configuration.md`; `README.md`; `CLAUDE.md` (the bump-lane table); `plugins/uberdev/vendor.json` + `docs/rfc/0019` (the chained component-count locks); new `tests/fix-lane.test.sh`; `.github/workflows/test.yml`; `CHANGELOG.md`; the six version-lock surfaces |
| **Complements** | RFC 0020 (`/turbox`, the standard-mode fleet). `/fix` is a **narrowing of** that lane, not a sibling of it: it reuses the launcher preflight, the worktree helper, the staging refusal and the audit sink verbatim. |
| **Reuses** | `lib/turbox-fleet.sh` (`worktree-add`, `stage-commit`, `round-permitted`, `audit`), `shared/phase1-reviewer-output-v1.md`, `uberdev_child_validate_phase1_review_result`, the Step 4.5 claim protocol |

---

## 1. Decision

**`/fix <issue#>` solves exactly one issue with one implementer, one
`code-reviewer` over the whole diff, at most one fix round, and a PR this
session pushes and parks.** The calling session is the orchestrator, as on
`/turbox`; what changes is that every design rung is gone and delivery costs no
agent seat.

Two sequential agent rungs on the happy path, three when the review comes back
red — against `/turbox`'s eight or more.

### What `/fix` gives up (say these out loud, never silently)

- **No security-research lens.** An issue carrying triage `risk_signals` gets
  no SAST pass on this lane. The signals are still computed by the launcher and
  still travel in the manifest; nothing reads them.
- **No design spec and no plan.** Nothing writes down what the change is
  supposed to be before it is written, so nothing can compare the result
  against it. The `spec-compliance-reviewer` rung has no input and does not run.
- **No wave decomposition.** One agent makes the whole change. The TB3
  disjointness refusal has nothing to refuse because there is only one writer.
- **No per-task review.** One `code-reviewer` sees the whole diff at once
  instead of one reviewer per task. That is a coarser lens, and it is the main
  thing the operator is trading away.
- **A short fix ladder.** One round, not three.

### What it keeps, unchanged

- The **full launcher preflight**: validate-all-first, triage, route
  resolution, the prepared root request and context files, and the Step 4.5
  `uberdev:active` claim protocol.
- The **worktree isolation** and the explicit-path staging refusal — every
  commit still goes through `stage-commit`, which refuses `-A`, `--all`, a bare
  `.`, absolute paths and `../` escapes.
- The **`phase1-reviewer-v1` contract** and the canonical
  `uberdev_child_validate_phase1_review_result` boundary. A review result that
  does not validate does not silently become an approval.
- The **full test suite**, run before the PR opens, with the real result
  reported.
- The **untrusted-input discipline**: the issue body reaches an agent only as a
  path to a `0600` run artifact, wrapped at the reading end.
- The **park-the-PR rule**. `/fix` never merges and never chains into `/merge`.

### Why the trade is honest

The lane's failure mode is "a change that needed design got none." The lane
answers that structurally rather than by hoping: the implementer's return
vocabulary carries **`TOO_BIG`**, an honest first-class answer meaning *this
issue wants a decomposition — run `/turbox`*. It is not a failure, it is not
retried, and the controller is told never to argue an agent out of it.

Without that escape the lane would be a trap: an operator picks `/fix` because
it is fast, the issue turns out to be a design problem, and a lane with no
design rungs produces a plausible-looking PR nobody planned.

---

## 2. Why a new command rather than a `/turbox` flag

The repo's doctrine, stated most sharply in RFC 0021 §2: a flag is wrong when
it would change the engine, the phase order, the halt rules and the output
contract at once — "that is a second command wearing the first one's name."

Measured against `/turbox`, all four move:

| | `/turbox` | `/fix` |
| --- | --- | --- |
| Argument arity | up to 3 issues, batched by `concurrency` | **exactly 1**, refused at the launcher |
| Phase order | 7 phases, 2 of them design | **6 phases, 0 design** |
| Implementation engine | wave-parallel over a plan's `Owns` sets | one agent, whole change |
| Review engine | `spec-compliance-reviewer` **+** `code-reviewer`, per task | one `code-reviewer`, whole diff |
| Halt vocabulary | `DONE`/`NO_CHANGES`/`BLOCKED`/`NEEDS_CONTEXT` | adds **`TOO_BIG`**, drops `NEEDS_CONTEXT` |
| Circuit breakers | TB1–TB4 | **FX1–FX4** (different guards, different loops) |
| Delivery | a delivery agent per issue | the controller |
| Plan envelope | 18 keys | **14** — no `riskIssueCount`, `concurrency`, `implementBudget`, `maxAgents` |

RFC 0003 §6.5's objection to folding `/dev` into `/solve` — a forked argument
model — deliberately does **not** apply here: `/fix` takes issue numbers, same
as `/solve`. That argument is unavailable, and this RFC does not reach for it.
The case rests entirely on the table above.

### Why `--fix` requires `--standard` rather than implying it

`--fix` is a **narrowing** of standard mode, not a third transport. RFC 0020 §2
established that `dispatch_backend` answers exactly one question — "how is one
per-issue solver child launched?" — and that standard mode launches no such
child, which is why `--standard` is an orthogonal launcher option rather than a
new enum member. `--fix` inherits that reasoning wholesale, so it is a second
orthogonal option on the same axis.

Requiring `--standard` rather than implying it is deliberate: an operator who
typed only `--fix` has a lane in mind the launcher cannot confirm, and guessing
is how a run lands somewhere nobody expected. `commands/fix.md` passes both
literals.

One consequence, stated so it is not mistaken for a bug: the existing
`--standard` × `--backend` refusal message names `/turbox`, because `--fix`
requires `--standard` and therefore trips the same guard. The message is true
on both lanes; only its example is turbox-flavoured.

---

## 3. The execution model

### 3.1 FX1 — arity is refused before a claim is written

The refusal fires in `lib/solve-launcher.sh` immediately after
`solve_triage.py parse-cli` returns, which is the last point before `gh` runs
and therefore before Step 4.5 can write a claim. This placement is the whole
point of the guard: a lane that discovered its second issue after claiming both
would leave two issues labelled `uberdev:active` with nothing running, and an
operator releasing them by hand.

The error names `/turbox` as the batch lane and says a second issue is not a
batch to split.

`skills/fix-fleet/SKILL.md` Phase 0b re-checks the manifest holds exactly one
record. That is the second lock, not the first: a plan reaching the skill with
two records is a relay defect, and a lane that trusted the relay would have no
way to notice.

### 3.2 The controller owns git — all of it

`/turbox` invariant 3 lets a **lone** writer in a worktree run its own git,
which is why its Phase 1c single solver opens its own PR. `/fix` is stricter:
no agent runs git, not the implementer and not the fixer.

The reason is that the controller is delivering anyway. Once it is pushing and
opening the PR, a second git operator buys nothing and costs the explicit-path
staging guarantee — an implementer that reported four paths could sweep a fifth
into the commit.

### 3.3 Delivery costs no agent seat

`/turbox` spends a delivery agent per issue because it has one worktree per
issue and a report to compose across several tasks. `/fix` has one worktree,
one change and one review, so the controller runs the suite, pushes, and opens
the PR itself.

Running the suite in the controller is also **more** trustworthy than asking an
agent to report its own result honestly.

### 3.4 A red suite opens a draft PR, never a green-looking one

Three conditions make the PR a draft: a red suite, blockers still standing
after FX2's cap, or a run counted `UNREVIEWED` because the review result never
validated. All three are named in the body and in the Phase 6 report. Work
that is not ready gets a surface that says so and cannot be merged by accident,
and committed work never strands in a worktree.

The lane never re-runs a suite hoping for a different answer.

### 3.5 Reading the review without reading the findings

The reviewer writes a `phase1-reviewer-v1` result file. The controller:

1. validates it through `uberdev_child_validate_phase1_review_result`, invoked
   as `bash -c '. "$1/lib/child-dispatch.sh" && …'` — `bash -c` because the
   Bash tool runs `/bin/zsh` and `child-dispatch.sh` is bash;
2. reads exactly two facts out of it with `grep`: the `verdict` line and the
   count of `severity: blocker` rows.

The findings themselves never enter the controller's context. The fixer is
given the path.

Validating through the canonical boundary rather than re-implementing the
schema is deliberate: a second copy of a validator drifts from the first, and
prose asserting the two are equivalent is not a producer.

### 3.6 Circuit breakers

| ID | Guard | On trip |
| --- | --- | --- |
| **FX1** | more than one issue | refused at the launcher before any claim; re-checked in Phase 0b |
| **FX2** | the plan's `fixRounds` reached with blockers standing | keep the commits, open the PR as a draft, name the standing blockers |
| **FX3** | `round-permitted --loop retest_rounds` rc 3 | stop re-running, carry the red result, open the PR as a draft |
| **FX4** | an unparseable implementer return, or a review result the validator rejects | one re-prompt, then stop (implementer) or count the run `UNREVIEWED` (reviewer) |

**`fixRounds` is a lane field, not the turbox per-task cap.** That one bounds
a fix ladder inside a wave loop, and adopting its number here would import a
budget written for a different loop. Its value is owned by
`bash lib/turbox-fleet.sh loop-cap` and is deliberately not copied into this
RFC, the launcher or the skill. `/fix` has its own default of one round,
resolved in the launcher and emitted in the plan, so the skill reads the field
rather than restating anything.

`retest_rounds` IS shared — it bounds the same thing on both lanes (how many
times a red suite may be handed back), so it is read from
`bash "$LIB" loop-cap retest_rounds`.

---

## 4. The fix plan envelope

A **third** marker pair, `FIX_PLAN_BEGIN` / `FIX_PLAN_END`. Each marker names
exactly one executor: `WORKFLOW_ARGS_BEGIN/END` means "call `Workflow()` with
this", `TURBOX_PLAN_BEGIN/END` selects a lane with design rungs this one does
not have. Relaying a fix plan into either would run the wrong pipeline rather
than produce an error message.

```json
{"v":1,"lane":"fix-lean","manifestPathAbs":"…","issues":"819","issueCount":1,
 "runDirAbs":"…","worktreeRootAbs":"…/worktrees","repoRootAbs":"…",
 "pluginRootAbs":"…","repoSlug":"owner/repo","baseBranch":"main",
 "branchPrefix":"worktree-fix-issue-","fixRounds":1,"autoMode":true}
```

The envelope is deliberately **narrower** than the turbox plan: no
`riskIssueCount` (no security lens), no `concurrency` (arity 1), no
`implementBudget` or `maxAgents` (no wave loop to bound). A field the skill
never reads is a field that drifts unnoticed.

`branchPrefix` is `worktree-fix-issue-`, distinct from turbox's
`worktree-turbox-issue-`, so the lane that opened a PR is legible from its
branch name.

### 4.1 `audit --basename`

`lib/turbox-fleet.sh` is shared, so its `audit` subcommand gained an optional
`--basename` defaulting to `turbox-audit.jsonl`; `/fix` passes
`fix-audit.jsonl`. It is a basename, not a path — a `/` or a `..` is refused,
because the one thing an audit sink must not do is write outside the run dir.

Sharing the executable rather than forking it is the point: `worktree-add`,
`stage-commit`, `round-permitted` and `audit` keep one definition.

---

## 5. Alternatives considered

**A — `/turbox --lean` instead of a new command.** Rejected on RFC 0021 §2's
criterion: the flag would move the arity, the phase order, the halt vocabulary,
the breaker set and the plan envelope at once. §2's table is the argument.

**B — `/solve --trivial` is already the fast path.** Rejected on measurement,
not preference. The trivial rung skips brainstorm and plan, but it still
terminates in a full `/review-pr`, and its solver runs in the Workflow runtime
where the implementation phase is a sequential per-task loop. `/fix` changes
what runs after implementation, which is where the rungs actually are.

**C — Reuse turbox's Phase 1c single-solver path verbatim.** Rejected because
Phase 1c has **no review gate at all** — its solver edits, commits, pushes and
opens its own PR unreviewed. That is the right shape for a `trivial`-tier issue
inside a batch that has other gates around it; it is the wrong shape for a lane
an operator reaches for deliberately. `/fix` keeps one independent reviewer.

**D — Let the implementer run its own git and open its own PR.** Rejected: see
§3.2. It would save one round trip and cost the explicit-path staging
guarantee.

**E — Re-implement the reviewer-result schema inside the skill.** Rejected: see
§3.5.

---

## 6. Acceptance criteria

1. `--fix` without `--standard` exits 64 with a message naming the requirement.
2. `/fix` with two or more issue numbers exits 1 with `no claims written; no
   agents dispatched` on stderr, before any `gh` call.
3. `/fix` with one issue emits a `FIX_PLAN_BEGIN`/`FIX_PLAN_END` envelope whose
   `lane` is `fix-lean` and whose `branchPrefix` is `worktree-fix-issue-`.
4. The envelope carries none of `riskIssueCount`, `concurrency`,
   `implementBudget`, `maxAgents`.
5. `fixRounds` defaults to 1 and honours `UBERDEV_FIX_FIX_ROUNDS`; a
   non-positive or non-numeric value exits 2.
6. `bash lib/turbox-fleet.sh audit` still writes `turbox-audit.jsonl` with no
   `--basename`, writes the named file with one, and refuses a `--basename`
   containing `/` or `..` with rc 2.
7. `skills/fix-fleet/SKILL.md` mandates `TOO_BIG`, the canonical validator
   call, controller-owned git, and the draft-PR rule.
8. The launcher refuses cleanly when `skills/fix-fleet/SKILL.md` is absent,
   naming `/turbox` as the fallback.
9. The six alias surfaces and the two chained vendor locks agree at 16 aliases
   and 79 components.

### Where each criterion is proved

`tests/fix-lane.test.sh` — criteria 1–8 as executed behaviour, plus the command
and skill shape checks. Criterion 9 is proved by the pre-existing
`tests/aliases.test.sh`, `tests/docs-accuracy.test.sh` T6b and
`tests/vendor-provenance.test.sh` V3/V24b, which this change moves rather than
adds to.
