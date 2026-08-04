---
name: review-fleet
description: Shared Workflow-native child-dispatch engine for /uberdev:review-pr and /uberdev:simplify (RFC 0012 §3.1). Not invoked directly — the two commands run their existing preflight, emit a per-stage args envelope, and mandate the Workflow call into skills/review-fleet/workflow.js. The script dispatches and waits; every digest, artifact validation and git/gh mutation stays in the calling session's Bash. Opt-in in P2 — the directive-emitter path remains the default.
model: inherit
---

# Review-fleet — the shared `/review-pr` + `/simplify` Workflow engine

This skill hosts `skills/review-fleet/workflow.js`, the single Workflow script
that backs BOTH `/uberdev:review-pr` and `/uberdev:simplify` (RFC 0012 §3.1). It
is **not invoked directly by users**, and it is **not a second pipeline** — the
two command files still own the whole user-facing lifecycle: flag parsing, the
`RUN_ID` reservation, the PR bind, scope capture, every digest, every authority
receipt, the push gate, the trust anchor and the verdict.

Why one script, not two: RFC 0012 §3.1 rejects splitting `/review-pr` per phase
because Phase 3 re-enters Phase 1, so the phases have to share one control flow.
And `/simplify`'s canonical position in the chain **is** `/review-pr`'s Phase 2
(`commands/simplify.md:604`) — its stages are a strict subset. The divergence is
the edge-id family and the authority family, both of which arrive as
controller-supplied scalars. `skills/scan-fleet/workflow.js` is the shipped
two-command precedent.

> **P2 status — ENGINE ONLY. This script is currently UNREACHABLE.**
>
> No command emits `pipeline=review-fleet` yet: `grep -rn 'review-fleet'` outside
> this directory returns zero hits, and neither `commands/review-pr.md` nor
> `commands/simplify.md` contains a `Workflow(` block or a
> `uberdev_emit_workflow_args` call. Nothing can select this engine today.
>
> Everything below therefore describes the contract the wiring **will** satisfy,
> not a path you can run right now. It is written in the present tense because it
> is a specification; do not read it as a status report.
>
> The next increment wires it, and owes exactly:
> 1. the RFC 0012 §4.1 existence guard in both command files;
> 2. the per-stage `uberdev_emit_workflow_args review-fleet …` calls;
> 3. the per-child nonce mint, in the roster order fixed below;
> 4. `mkdir -p <runDirAbs>/children/<slug>-iter<NN>/` before each stage;
> 5. the post-return `capture-review-terminal` / `validate-review-outcome` verbs.
>
> Until all five land, the directive-emitter flow is not merely the default —
> it is the only path that exists.

---

## The seam — read this before changing anything

The script **dispatches and waits. That is all it does.**

Every sha256, every authority receipt, every artifact validation, every git or
`gh` mutation runs in the **calling session's Bash** through
`plugins/uberdev/lib/code_fixer_contract.py`. None of it may move into the
script, and — this is the part that looks safe and is not — none of it may move
into a relay agent either. A Workflow script has no filesystem, so every disk
fact it wants must come through an agent, and an agent is an LLM. If a relay
computed a digest, the authority chain would silently degrade from *the
controller proved it* to *an LLM said so* while every downstream equality check
still looked correct. That is the same reasoning
`_validate_bound_workflow_child_status` uses to forbid a synthesised pid
(`lib/code_fixer_contract.py:6599-6601`).

Two consequences worth stating out loud:

- **The script is a courier, not a computer.** Every digest in every prompt
  arrives in the args envelope already computed, and is forwarded verbatim.
- **The script's own gates are refusals, not blessings.** `isSha256`,
  `isNonce`, `underRunDir` and `isSafeAbsPath` can only *stop* a dispatch. A
  value that passes them is still unproved until the controller re-validates it
  after the call returns.

### Why the run is staged instead of one call

Each stage ends exactly where the controller must prove something before the
next dispatch is safe. **Collapsing two stages into one Workflow call is not an
optimisation — it is the deletion of a proof.**

| Stage | Script dispatches | Calling-session Bash then proves |
|---|---|---|
| `review` | the 6 Phase-1 reviewers | per-child `capture` verbs → trusted ledger → `post_review_capture_aggregation_inputs` → `post_review_write_aggregate_v2` → `digest` → `prepare-authority` |
| `fix` | ONE `code-fixer` child | `capture-review-terminal` → `validate-review-outcome` → `validate-residue` → `review_track_validated_fixer_head` → `review_refresh_phase1_scope` |
| `simplify` | the 3 `code-simplifier` lenses | canonical aggregate → `code_fixer_contract.py encode-aggregate --phase phase2` (the byte-shape oracle, `commands/simplify.md:341-348`) → `digest` → `prepare-authority` |
| `defer` | ONE `findings-to-issues` child | halt handling (`AskUserQuestion`), then the GREEN/YELLOW/RED predicate |

### What the script deliberately does **not** do

RFC 0012 §3.1's pseudocode proposes two things this implementation rejects, and
both look harmless:

- **line 153, "haiku writer emits post-impl-review-final.md".** Rejected. The
  aggregate is published by `post_review_write_aggregate_v2`, a deterministic
  writer that re-validates the closed six-edge roster and "does not use any
  pathname as aggregation authority"
  (`skills/post-impl-review/SKILL.md:1118-1122`). It is a shell function defined
  inside that SKILL.md — not an on-disk executable a relay could even invoke.
- **line 157, "push agent (haiku): git push origin HEAD".** Rejected. Pushing
  goes through `review_publish_same_repo_pr_head`, which proves same-repo
  authority, remote-ref equality, live-PR-head equality, local-HEAD equality and
  clean residue before it moves a ref (`commands/review-pr.md:1898`, `:3380`).

There is also **no brief relay** (RFC §3.1 line 148). The controller already
writes the enveloped diff artifact atomically in Bash
(`review_refresh_phase1_scope`, `commands/review-pr.md:1481-1571`), so the
reviewers read *that* path. This deletes an agent and removes an LLM from the
trust path.

---

## Invocation contract

The preflight validates the on-disk script exists BEFORE mandating the call (RFC
0012 §4.1) — a missing or misnamed `workflow.js` on a target install must refuse
cleanly at preflight, not fail later at the runtime layer:

```bash
REVIEW_FLEET_WORKFLOW_JS="$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"
[ -f "$REVIEW_FLEET_WORKFLOW_JS" ] || { echo "error: $REVIEW_FLEET_WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; exit 2; }
```

It **will** emit the args envelope via `uberdev_emit_workflow_args review-fleet …`
between the `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` markers and mandate,
relaying the JSON **verbatim** (DR-2 — no LLM-composed handoffs). No command does
this yet — see the status block at the top:

```
Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}, <the JSON between the markers>)
```

One envelope per stage. `RUN_ID` is **never** re-minted across stages or across
a Phase-3 re-entry — the marker, the research directory and the verdict path are
all keyed on it, and `/uberdev:goal` treats a new run directory as a fresh
review.

---

## What the shell preflight emits

Reserved envelope keys (`v`, `run_id`, `now_epoch`, `now_iso`, `plugin_root`,
`repo_root`, `cwd`, `pipeline`) sit top-level; everything below lands under
`.config`. The emitter has **no array path** — integer-shaped and bare
true/false values become JSON scalars and everything else becomes a JSON string
(`lib/config-read.sh:958-971`), so list-valued inputs travel comma-joined and
are re-split and re-validated in-script.

### Every stage

| Key | Meaning |
|---|---|
| `mode` | `review-pr` \| `simplify`. Unrecognised values default-close to `simplify`, the smaller authority surface. |
| `stage` | `review` \| `fix` \| `simplify` \| `defer`. **No default** — an unrecognised stage aborts, because guessing one means guessing which proofs already exist. |
| `runId`, `runDirAbs` | the reserved run id and `.uberdev/research/<RUN_ID>` |
| `pluginRootAbs`, `repoRootAbs`, `workingDirAbs` | script-derived prompt inputs |
| `prNumber`, `repoSlug` | bound once by the preflight's single multi-field `gh pr view` |
| `reviewIteration` | integer; keys per-iteration child artifacts so a Phase-3 re-entry never collides |
| `maxAgents` | projected-agent ceiling (default 40) |

### `review` and `simplify` stages

| Key | Meaning |
|---|---|
| `diffPathAbs` | the **already-enveloped** diff artifact, written atomically in Bash. Read by path; never re-wrapped. |
| `aspects` | CSV emphasis tokens. Emphasis only — it never gates fanout membership (`commands/review-pr.md:3874-3875`). |
| `focus` | `/simplify`'s free-text `## Additional Focus`, kept OUTSIDE the envelope |
| `fanoutCap` | reviewer wave size, `[1,50]` default 6. `sequential` ⇒ 1. |
| `lensConcurrency` | lens wave size, `[1,3]` default 3 |
| `runNonces` | the nonce pool — see below |

### `fix` stage — controller-supplied authority, forwarded verbatim

`fixerEdgeId` (`review_pr.fix.phase1` \| `review_pr.fix.phase2` \|
`simplify.fix.phase2`), `commitType` (`fix` for phase1, `refactor` for phase2 —
the pairing is checked, and a mismatch aborts before dispatch),
`findingsPathAbs` + `findingsSha256`, `authorityPathAbs` + `authoritySha256`,
`dispositionPathAbs`, `appliedContentPathAbs`, and exactly one range family:
`commitRangePathAbs`/`commitRangeSha256` for the `review_pr.fix.*` edges, or
`standaloneSnapshotPathAbs`/`standaloneSnapshotSha256` for
`simplify.fix.phase2` (`commands/simplify.md:18`).

### `defer` stage

`phase1PathAbs`, `phase2PathAbs`, `phase1DispositionPathAbs`,
`phase2DispositionPathAbs`, `maxNew`. `phase1PathAbs` is empty for `/simplify`
because no Phase 1 ran (`commands/simplify.md:547`) — that is a declared value,
not a missing one, and the script only enforces its presence in `review-pr` mode.

`childNotes` is optional and **untrusted**: the short `note` strings the earlier
stages' children returned, concatenated by the controller from those runs'
`children[]` returns. Because the stages are separate Workflow calls, this
round-trip is the only way cross-stage notes can reach the defer prompt at all.
The script wraps them in `<external-untrusted-input source="review-fleet-child-notes">`
at assembly time and labels them as leads to corroborate, never as instructions
— the close tag is neutralised with a U+200B so an injected one cannot terminate
the envelope early. The controller must pass them through verbatim and must not
pre-wrap them.

---

## Bound children — the nonce protocol (P1, #381)

Every child that produces a result file is a **bound child**. The controller
mints a single-use `run_nonce` (64 lowercase hex) per child *before* the
Workflow call; the child echoes it verbatim into `status.json`. For a
`workflow`-backend child that nonce **replaces** the
`pid`/`process_identity`/`lease_generation` triple, which must be **absent** —
see `_validate_bound_child_status` and `_validate_bound_workflow_child_status`
(`lib/code_fixer_contract.py:6587-6642`). A Workflow child is awaited
in-session, so it owns no pid and nothing could probe its liveness; the await
*is* the supervision (`lib/agent-dispatch.sh:1461-1473`).

The nonce is a **binding token, not authority**. A garbled nonce makes the
child write one the controller never minted, and validation fails closed — it
can cost a refusal, never buy a false accept. That is why carrying it as an
envelope scalar is safe.

**`runNonces` is one comma-joined scalar consumed in fixed roster order.** These
two orders are a wire format; reordering either array silently re-binds every
child.

| Stage | Nonce index → edge |
|---|---|
| `review` | 0 `review_pr.review.correctness` · 1 `review_pr.review.silent_failures` · 2 `review_pr.review.types` · 3 `review_pr.review.comments` · 4 `review_pr.review.tests` · 5 `review_pr.review.general` |
| `simplify` | 0 `review_pr.simplify.reuse` · 1 `review_pr.simplify.quality` · 2 `review_pr.simplify.efficiency` |
| `fix` | 0 — the single fixer child |
| `defer` | none — `findings-to-issues` writes no bound result file |

A pool whose length does not match the roster **exactly** aborts the stage: a
short pool leaves a child unbound, and a long one means the controller and the
script disagree about the roster.

### Child artifact layout (script-derived — Bash computes the same paths)

```
<runDirAbs>/children/<slug>-iter<NN>/result.md
<runDirAbs>/children/<slug>-iter<NN>/status.json
```

`<NN>` is `reviewIteration` zero-padded to two digits. Slugs are the roster
`slug` values (`correctness`, `silent-failures`, `types`, `comments`, `tests`,
`general`, `reuse`, `quality`, `efficiency`) and, for the fixer, the edge id
lowercased with every non-alphanumeric run collapsed to `-` (e.g.
`review-pr-fix-phase1`). No extra envelope scalars, no round-trip.

Every bound child is told to write `result.md.partial` and then publish it with
a **same-directory `mv -f`** — the shell spelling of the atomic rename
`os.replace` performs — and to do the same for `status.json`. Without that, the
controller can capture a torn half-written file and digest it as final. It is
spelled with `mv` rather than a Python one-liner because the T1
self-contained-script grep bans the module-load keyword *anywhere* in the
script, including inside a prompt string (the same constraint
`scan-fleet/workflow.js:317-319` records).

`status.json` carries exactly:

```json
{"backend":"workflow","state":"completed","exit_code":0,"run_nonce":"<the nonce>",
 "workspace_mode":"<workspaceMode>","worktree":"<worktreeAbs>","branch":"<branchName>",
 "result":"<result.md path>"}
```

---

## What the script returns

The script logs `WORKFLOW_RESULT <json>` on **every** return path — success,
guard-abort and the DR-8 throw path — and returns the same object:

```
{ runId, mode, stage, prNumber, reviewIteration, abortReason, dispatched,
  children: [ {edgeId, slug, status, verdict, resultPath, statusPath,
               findingCount, blockerCount, reason} ],
  fixerStatus, issues: {issuesCreated:[int], commentedUrls:[str], skipped, halted},
  nullsByPhase, auditEvents }
```

`children[].status` ∈ `COMPLETE | BLOCKED` for reviewers and lenses, and
`APPLIED | NO_FIXES_NEEDED | REFUSED` for the fixer. A child whose returned
paths do not equal the script-derived layout is **downgraded to `BLOCKED` with
its paths blanked**, so the controller never goes hunting for an artifact at an
agent-chosen location.

## What the caller does with it

1. `abortReason` non-empty ⇒ nothing was dispatched past the guard. Treat it as
   a preflight failure of the calling command, not as a review result.
2. For `review`: run the per-child capture verbs over `children[].statusPath`
   and `children[].resultPath`, build the trusted ledger, then
   `post_review_write_aggregate_v2`. **Any `BLOCKED` reviewer blocks green
   trust** — missing reviewer evidence is not advisory, and the ordinary
   aggregate exists only after all six slots have valid evidence. A missing or
   empty aggregate terminates `/review-pr` immediately without dispatching the
   fixer, Phase 2, deferred findings or trust; it is infrastructure failure,
   never a zero-finding review. Exact `findings: []` is the valid zero form.
3. For `fix`: `capture-review-terminal` → `validate-review-outcome` →
   `review_track_validated_fixer_head`. `fixerStatus` is a **hint for logging
   only** — the disposition artifact and the head movement are the truth.
4. For `simplify`: build the canonical aggregate and pipe it through
   `encode-aggregate --phase phase2` before any digest.
5. For `defer`: `issues.halted` feeds the Phase-2.5 halt gate, which needs
   `AskUserQuestion` (fail fast via `ToolSearch`; never silently auto-pick).
6. Then the unchanged tail: the single Step-6a guarded push, Phase 3, the trust
   anchor, labels, the verdict JSON, and the existing exit-code contract
   (`0` GREEN/YELLOW/OVERRIDE_GREEN · `1` Phase-1 reject or Phase-3 halt or a
   Phase-2.5 halt resolved to `solve_suggestion`/`skip` · `2` Phase-2 or
   Phase-2.5 blocked or a Step-6a push failure · `3`
   `verdict_published_marker_retire_failed`).

---

## Model policy and circuit breakers

Reviewers, lenses, the `code-fixer` child and `findings-to-issues` are
**judgment** paths — `opts.model` is omitted so the user's session flagship
flows through. Fable is never pinned. This engine ships **no mechanical relay**
at all: the controller already owns every disk and git fact it needs, which is
the point of the seam.

| Guard | Behaviour |
|---|---|
| projected-agent ceiling | computed before any dispatch; **aborts** rather than degrading, because a half-run fanout produces a partial aggregate and a partial aggregate is indistinguishable from a clean zero-finding review |
| nonce-pool gate | size or grammar mismatch aborts the stage before dispatch |
| commit-type / edge pairing | `phase1`⇒`fix:`, `phase2`⇒`refactor:`; a mismatch aborts |
| runtime `budget` | checked between waves with `budget && budget.total && budget.remaining() <= 0` — `parallel()` never rejects, so a budget throw would otherwise arrive as a silent `null` |

Wall-clock breakers are impossible in-script: time arrives frozen in `now_iso`
and the runtime forbids the nondeterministic clock global (DR-7).

## Why `parallel()`, not `pipeline()`

Both fanouts are **genuine barriers**, and each carries a comment saying so. The
controller's aggregate writers consume the **full** roster —
`post_review_write_aggregate_v2` re-validates the closed six-edge roster, and
`encode-aggregate` does the same for the three lenses — so there is no
partial-consumption step a barrier-free `pipeline()` could overlap with. It
would buy nothing here while making this the first shipped `pipeline()` call
site in the plugin, on the flagship review path, against semantics currently
pinned only by harness self-tests.

## Not built in P2 (deliberate)

**Phase 3 — CI health is not dispatched from this script**, and neither is the
trust-anchor/verdict tail; `/review-pr` keeps its existing Bash for both, and
neither phase is declared in `meta.phases`. Phase 3 is the arm with the deepest
git-mutation authority chain — per-iteration `CI_RUN_ID` re-derivation from the
failed check row's immutable `link`/`event`, the rebase lease,
`--force-with-lease`, and the mid-rebase abort path — and moving it needs its
own RFC amendment plus its own tests. Nothing here changes its behaviour.

---

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini, Copilot, pre-Workflow Claude
Code), **run the stages inline as directives in the calling session**. Each
stage below is the exact same fanout the script performs, dispatched with the
`Task` tool instead; the calling-session Bash between stages is **unchanged**,
because it was never inside the Workflow to begin with — that is the whole point
of the seam, and it is why this fallback is a re-dispatch rather than a
re-implementation.

1. **`review`** — dispatch all six reviewers in ONE message
   (`uberdev:code-reviewer` twice for the correctness and general lenses, plus
   `uberdev:silent-failure-hunter`, `uberdev:type-design-analyzer`,
   `uberdev:comment-analyzer`, `uberdev:pr-test-analyzer`), each reading
   `diffPathAbs` by path, each writing `result.md.partial` → `mv -f` →
   `result.md` and its nonce-bearing `status.json` at the layout above. When
   `fanoutCap < 6`, split into `ceil(6 / fanoutCap)` sequential waves, still
   dispatching every child in a wave before the first wait.
2. **`fix`** — dispatch ONE `uberdev:code-fixer` on the controller-supplied
   edge, with the authority scalars verbatim. Never in parallel with anything,
   and never worktree-isolated: it commits onto the caller's checkout on the PR
   branch, git forbids two worktrees on one branch, and an isolated child's
   disposition artifact would vanish with its throwaway worktree.
3. **`simplify`** — dispatch the three `uberdev:code-simplifier` lenses in ONE
   message, `## Lens emphasis` and `## Additional Focus` kept OUTSIDE the
   envelope.
4. **`defer`** — dispatch ONE `uberdev:findings-to-issues` with both aggregate
   paths and both disposition paths; the agent owns `max_new`, dedupe and halt.

Between every pair of stages, run the same calling-session Bash the staged table
above lists. Do not skip a proof because the fanout came from `Task` — the
authority chain is identical on both paths.
