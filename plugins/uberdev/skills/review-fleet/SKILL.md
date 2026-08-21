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
(`commands/simplify.md:294-295`) — its stages are a strict subset. The divergence is
the edge-id family and the authority family, both of which arrive as
controller-supplied scalars. `skills/scan-fleet/workflow.js` is the shipped
two-command precedent.

> **P3 status — WIRED AND DEFAULT.** Both command files select this engine when
> `UBERDEV_CARRIER_BACKEND=workflow`, and since #381 step 3 that is what `auto`
> resolves to for `/review-pr` and `/simplify` — unconditionally, on every host.
> `--backend=codex` is an **enum error** since #381 step 4 deleted the backend
> (`lib/dispatch.sh:509`); it is not an escape hatch for anything. The one
> declared gap — /review-pr Phase 3 — was CLOSED by #383: its five
> `review_pr.ci.*` children are dispatched by this script as the `ci-classify`,
> `ci-fix`, `ci-conflicts` and `ci-defer` stages. See the bottom of this log.
>
> **#383 shipped in two halves.** Half one added the four stages
> (`ci-classify`, `ci-fix`, `ci-conflicts`, `ci-defer`) to this script and their
> producer, capture verb and judges to `lib/code_fixer_contract.py`, without
> re-pointing the caller — so for that one release the Phase 3 rows below were
> the engine's contract rather than what the command did. Half two removed the
> `ci_transport_unsupported` gate and wired `commands/review-pr.md`'s Phase 3
> fences at them, so every row below is now both.
>
> All five caller obligations have landed in `commands/review-pr.md` (stages
> `review`, `fix` ×2, `simplify`, `defer`) and `commands/simplify.md` (stages
> `simplify`, `fix`, `defer`):
> 1. the RFC 0012 §4.1 existence guard, inline in every stage fence;
> 2. the per-stage `uberdev_emit_workflow_args review-fleet …` call;
> 3. the per-child CSPRNG nonce mint, in the roster order fixed below
>    (`review_fleet_mint_nonce`, `lib/review-fleet-args.sh`);
> 4. `mkdir -p <runDirAbs>/children/<slug>-iter<NN>/` before every bind
>    (`review_fleet_bind_roster` / `review_fleet_bind_fixer` /
>    `review_fleet_bind_persistence`);
> 5. the post-return capture verbs, per stage.
>
> The roster order, the nonce mint, the child-directory formula and the three
> binding producers live ONCE, on disk, in `lib/review-fleet-args.sh` — the same
> reasoning as `lib/review-aggregate.sh`: every `bash` block in a command file is
> a fresh shell, and a wire format duplicated across two markdown fences drifts.
>
> ### Gate log — what is retired, and what is not
>
> A stage wired before its proof exists would dispatch a real fanout, spend real
> agent budget, let the fixer commit onto the caller's checkout — and then fail
> its proof. That is strictly worse than being unreachable, because the seam
> this whole skill exists to defend is the proof *between* the stages. So each
> gate is tracked to a named, tested primitive.
>
> - ✅ **RETIRED (P1) — the launch-binding chain.** `bind_workflow_launch`
>   (`lib/code_fixer_contract.py:6534`) mints a binding keyed on `run_nonce`
>   instead of the detached triple, `_load_workflow_launch_binding` (`:6568`)
>   re-loads it, and `_validate_bound_workflow_child_status` (`:6985`) binds the
>   status file on that nonce and **rejects** `pid`/`process_identity`/
>   `lease_generation` outright (`DETACHED_SUPERVISION_KEYS`, `:6964`).
> - ✅ **RETIRED (#381 step 1) — the `review` stage's aggregate builders.**
>   Three things were true and are no longer:
>
>   1. *They had no on-disk executable.* The three functions now ship as
>      `lib/review-aggregate.sh`, and `skills/post-impl-review/SKILL.md` sources
>      that file rather than defining them. Every `bash` block is a fresh shell,
>      so the old fence-text definitions were unreachable to any caller that was
>      not the skill itself — that, and nothing about the proofs, was the gate.
>   2. *The receipt/pid demand was mis-attributed.* Neither
>      `post_review_capture_aggregation_inputs` nor
>      `post_review_write_aggregate_v2` ever touched a receipt, a pid or a mode
>      bit; the writer reads **only stdin**. The detached-shaped demand lived in
>      a third function, `post_review_validated_evidence_complete`, and inside it
>      in exactly one block: the `launched`-row receipt/handle/pid triple. That
>      function now accepts a second launch-row shape,
>      `{edge,index,instance,binding,result,status}`, and proves it through
>      `code_fixer_contract.py capture-bound-child` — a verb that takes no
>      caller-supplied digest and computes both itself. Every other check is
>      byte-identical on both shapes, and one wave may not mix them.
>   3. *The `0o400` result was blamed on the child.* No child of **any** backend
>      writes `validated-result.md`. The controller does, through
>      `uberdev_child_validate_phase1_review_result`
>      (`lib/child-dispatch.sh:1189`, `os.fchmod(descriptor,0o400)` at `:1343`),
>      which `/review-pr` already has in scope — it sources
>      `lib/child-dispatch.sh` at `commands/review-pr.md:42`.
> - ✅ **RETIRED — both command files may call `Workflow`.** `Workflow` is in
>   `allowed-tools` in `commands/review-pr.md:4` and `commands/simplify.md:4`,
>   with the byte-matched `lib/aliases-sync.sh` rows.
> - ✅ **RETIRED — the `fix`, `simplify` and `defer` stages have a
>   workflow-shaped capture.** `_load_fixer_launch_binding` and
>   `_load_persistence_binding` no longer rebuild the detached
>   `LAUNCH_BINDING_KEYS` base unconditionally; both now pick it from the
>   **declared backend** through `_binding_base_keys`
>   (`lib/code_fixer_contract.py:6455`, called at `:6737` and `:6917`), so a
>   workflow binding reaches all three `capture-*-terminal` verbs unchanged.
>   `capture-bound-child` was *not* widened — a fixer child still owes more than
>   a reviewer, and it still owes it here: the two new producers
>   `bind_workflow_fixer_launch` (`:6681`) and `bind_workflow_persistence_launch`
>   (`:6853`) pin exactly what their detached twins pin (the controller-created
>   authority by path+digest and edge+worktree; the aggregate/disposition digests
>   plus a recount of deferred blockers), and the capture still freezes the
>   disposition and applied-content artifacts alongside status and result.
>   The two launch shapes stay mutually exclusive — `DETACHED_ONLY_BINDING_KEYS`
>   (`:6313`) and `WORKFLOW_ONLY_BINDING_KEYS` (`:6316`) are derived, not
>   re-spelled, and neither shape may carry the other's members. An outcome's tie
>   back to its launch is backend-shaped by `_launch_identity` (`:6967`): a
>   workflow outcome reports `run_nonce`, never a relabelled `receipt_sha256`, so
>   a consumer written to check a dispatch receipt fails closed rather than
>   accepting a nonce as though a receipt had been verified.
> - ✅ **RETIRED (#381 step 3) — both commands dispatch this engine.** The five
>   obligations above are in both command files, and
>   `uberdev_dispatch_preflight_backend` now admits `workflow` for `review-pr`
>   and `simplify` (`lib/dispatch.sh`) instead of refusing it, so
>   `--backend=workflow` reaches the wiring. The routed
>   `uberdev_dispatch_child` call for each of these children is *replaced* on
>   that transport, not run alongside it — every stage says so explicitly, and
>   the review stage says so twice, because dispatching the roster through both
>   `Skill(uberdev:post-impl-review)` and the engine would produce two ledgers
>   for one wave.
>
>   Two contract gaps were closed to make this reachable rather than merely
>   plausible:
>   - **the defer child is now a bound child.** `f2iPrompt` carries the
>     bound-child protocol and the `defer` stage gates a one-nonce pool, because
>     `capture-persistence-terminal` and `validate-persistence-result` read that
>     child's own `result.md` and `status.json`. A detached backend gets that
>     pair from the provider harness; a Workflow child has no harness, so
>     without this the defer stage would have returned a plausible `issues`
>     object with nothing to validate it against. Additive: the child owes more
>     than it did, never less. `f2iPrompt` states that debt explicitly — the
>     `result.md` Return-Contract fence `validate-persistence-result` parses, and
>     a narrowly scoped precedence note over `agents/findings-to-issues.md`'s
>     `## Tools authorised` section, which was written for a transport whose
>     provider harness published those two artifacts FOR the agent. That section
>     stays as-is: the carve-out is the controller's, per-dispatch, and names
>     exactly what it does and does not relax.
>   - **`review_promote_validated_fixer_outcome` was taught the workflow outcome
>     shape.** `_launch_identity` emits `run_nonce` where a detached outcome
>     emits `receipt_sha256`, and the parser previously asserted the detached key
>     set exactly. It now accepts EXACTLY ONE of the two, still requires 64-hex,
>     and still refuses a document carrying both, neither, or any extra key.
> - ✅ **RETIRED (#381 step 3) — `auto` resolves `workflow` for both workflows.**
>   The review-pr/simplify special case that demanded the `codex` CLI is deleted
>   from `uberdev_dispatch_preflight`; these two now take the same ladder as
>   every other workflow. #381 step 4 then removed the two Codex-environment
>   escapes that used to run AHEAD of the per-OS matrix (`CODEX_HOME` set, or
>   `claude` absent with `codex` present) — both resolved a backend that no
>   longer exists, and there is no replacement, because `auto` has exactly one
>   answer now (`lib/dispatch.sh:682-685`).
>
>   `auto` also cannot resolve a transport this install cannot execute.
>   `_uberdev_dispatch_require_workflow_engine` checks that
>   `skills/review-fleet/workflow.js` is actually on disk, against a plugin root
>   the library derives from its OWN location (not `CLAUDE_PLUGIN_ROOT`, which
>   could answer for a different install). A missing engine is a **loud refusal
>   naming the path**, never a silent demotion to another backend — the retired
>   per-OS matrix drifted back into default paths exactly that way. The same gate
>   guards explicit `--backend=workflow` and `uberdev_dispatch_preflight_backend`,
>   so all three refuse identically instead of at three different stages.
> - ✅ **RESOLVED (#383) — /review-pr Phase 3 CI classification and the CI
>   fixers are BACK, Workflow-natively.** The entry below is kept as HISTORY,
>   not as current state: the gate log records what was true when it was
>   written, and deleting it would lose why the capability ever went away.
>
>   **Was (#381):** `review_pr.ci.classify`, `review_pr.ci.fix_code`,
>   `review_pr.ci.rebase`, `review_pr.ci.defer_refusal` and the
>   conflict-resolver fanout were routed children, and
>   `_uberdev_agent_dispatch_backend` has no `workflow` provider arm by
>   construction. Step 3 made `workflow` what `auto` resolves to and step 4
>   deleted `codex` — the only transport that ever had an arm for those edges —
>   so a red check halted at 6c.3 CLASSIFY with
>   `subreason=ci_transport_unsupported`, and `--no-ci-fix` was the supported
>   mode.
>
>   **Is (#383):** those five edges are dispatched by THIS script, as four
>   stages — `ci-classify`, `ci-fix`, `ci-conflicts`, `ci-defer` — so nothing in
>   Phase 3 reaches the routed adapter, for the same reason nothing in Phase 1
>   or Phase 2 does. The inline gate is deleted and the
>   `ci_transport_unsupported` reason no longer exists anywhere in the plugin.
>   `--no-ci-fix` survives as a legitimate opt-out (probe/monitor/classify for
>   telemetry, ROUTE/POST-FIX/HALT skipped) and is now **enforced in shell** at
>   the head of the ROUTE fence rather than being orchestrator prose with no
>   reader anywhere in the file.
>
>   New contract surface, all in `lib/code_fixer_contract.py`:
>   `prepare-ci-authority`, `bind-workflow-ci-launch`, `capture-ci-terminal`,
>   `read-ci-authority-member`, `validate-ci-classification`,
>   `validate-ci-mutation-outcome`, `validate-ci-persistence-result`. The CI
>   edges got their OWN producer and their OWN capture verb rather than joining
>   `WORKFLOW_BOUND_EDGE_IDS` — see the design note above.
>
>   The executable proofs for both halves are
>   `tests/review-pr-workflow.test.sh` (section W runs every stage, E6 drives the
>   conflict fanout at its ceiling, E7 executes the CI binders) and
>   `tests/code-fixer-contract.test.sh` (real git repos, real conflicts).

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
(`lib/code_fixer_contract.py:6985`; the reasoning is its docstring at
`:6997-6999` and the guard is `DETACHED_SUPERVISION_KEYS` at `:7004`).

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
| `review` | the 7 Phase-1 reviewers | per-child `capture` verbs → trusted ledger → `post_review_capture_aggregation_inputs` → `post_review_write_aggregate_v2` → `digest` → `prepare-authority` |
| `fix` | ONE `code-fixer` child | `review_fixer_terminal_outcome` → (`capture-review-terminal` → `validate-review-outcome` \| `publish-unapplied-terminal`) → `validate-residue` → `review_track_validated_fixer_head` → `review_refresh_phase1_scope` |
| `postfix` | ONE `code-reviewer` child over one validated fixer's own commit range | `capture-bound-child` → the child's own result bytes re-read and validated → `review_write_postfix_aggregate` (fails closed, rc 74 — a finding that reached no sink is a swallowed error) → the per-phase sidecar, published on the zero-dispatch paths too |
| `simplify` | the 3 `code-simplifier` lenses | canonical aggregate → `code_fixer_contract.py encode-aggregate --phase phase2` (the byte-shape oracle, `commands/simplify.md`) → `digest` → `prepare-authority` |
| `defer` | ONE `findings-to-issues` child | halt handling (`AskUserQuestion`), then the GREEN/YELLOW/RED predicate |
| `ci-classify` | ONE `ci-failure-classifier` child | `capture-ci-terminal` → `validate-ci-classification` (closed class enum, class/anchor pairing, anchor names a REAL repository file) → the routing scalar the mutating arm keys on |
| `ci-fix` | ONE `ci-code-fixer` **or** `ci-rebase-handler` child | `capture-ci-terminal` → `validate-ci-mutation-outcome` (parent identity, one commit, subject form, anchor+one-lockfile scope for `fix_code`; head moved, base is ancestor, **remote tip still equals the pinned lease**, and `CONFLICT` when the child left a live rebase with unmerged paths, for `rebase`) → on `APPLIED`/`REBASED`, the single controller-held `--force-with-lease` push at `commands/review-pr.md` **6c.4w.3** |
| `ci-conflicts` | N `conflict-resolver` children, one per conflicted path | `capture-ci-terminal` + `validate-ci-mutation-outcome` per resolver (worktree carries no conflict markers — the resolver is forbidden `git add`, so the index is legitimately still unmerged here) → `git add` → `git rebase --continue` → **the same 6c.4w.3 leased-push fence**, re-run |
| `ci-defer` | ONE `findings-to-issues` child | `capture-ci-terminal` → `validate-ci-persistence-result` → the CI-REFUSED halt prose and audit |

### What the script deliberately does **not** do

RFC 0012 §3.1's pseudocode proposes two things this implementation rejects, and
both look harmless:

- **`haiku writer emits post-impl-review-final.md`.** Rejected. The aggregate is
  published by `post_review_write_aggregate_v2`, a deterministic writer that
  re-validates the closed seven-edge roster and "does not use any pathname as
  aggregation authority" — its own words, in
  `skills/post-impl-review/SKILL.md`. Since #381 it IS on disk, defined in
  `lib/review-aggregate.sh` — so "no on-disk executable to invoke" does not
  carry the rejection, here or in the bullet below. What carries it is the seam
  itself: the controller proves, it does not delegate the proof to an LLM.
  `lib/review-aggregate.sh` exists so the CALLING SESSION can source the
  builders across its fresh-shell `bash` blocks, which is the opposite of
  handing them to a relay.
- **`push agent (haiku): git push origin HEAD`.** Rejected, by the same one
  argument. Pushing goes through `review_publish_same_repo_pr_head`, a shell
  function defined in `lib/review-fences.sh` and called from the
  `commands/review-pr.md` fences, and what carries the rejection is what that
  fence PROVES before it moves a ref: same-repo authority, remote-ref equality,
  live-PR-head equality, local-HEAD equality and clean residue. An earlier
  edition of this bullet rejected it on a different ground — that the fence,
  unlike the aggregate writer, was not a file a relay could invoke at all. That
  was read off a line number, the line moved, and the sentence went false while
  still reading as an argument (#606). It is a shell function on disk, like the
  writer; the seam is what separates them from a relay, not the filesystem.

There is also **no brief relay** (RFC §3.1's `brief agent: gh pr diff`). The
controller already writes the enveloped diff artifact atomically in Bash
(`review_refresh_phase1_scope`, `lib/review-fences.sh`), so the reviewers read
*that* path. This deletes an agent and removes an LLM from the trust path.

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

<!-- A marker line inside the table would split it in two, so the #370 contract
     marker sits above it and resolves forward via @anchor. The whole stage
     vocabulary is ONE backticked alternation for the same mechanism's sake: a
     cell that mixes the members with prose carries two competing spans, and the
     extractor refuses to choose between them. See
     docs/rfc/0016-contract-markers.md. -->
<!-- CONTRACT: review-fleet-stage @"| `stage` |" -->
| Key | Meaning |
|---|---|
| `mode` | `review-pr` \| `simplify`. Unrecognised values default-close to `simplify`, the smaller authority surface. |
| `stage` | `review \| verify \| postfix \| fix \| simplify \| defer \| ci-classify \| ci-fix \| ci-conflicts \| ci-defer` — **no default**. An unrecognised stage aborts `unknown_stage`, because guessing one means guessing which proofs already exist. |
| `runId`, `runDirAbs` | the reserved run id and `.uberdev/research/<RUN_ID>` |
| `pluginRootAbs`, `repoRootAbs`, `workingDirAbs` | script-derived prompt inputs |
| `prNumber`, `repoSlug` | bound once by the preflight's single multi-field `gh pr view` |
| `reviewIteration` | integer; keys per-iteration child artifacts so a Phase-3 re-entry never collides |
| `maxAgents` | projected-agent ceiling (default 40) |

### `verify` stage (RFC 0017 / #431)

| Key | Meaning |
|---|---|
| `verifyCount` | integer 1..50 — one child per eligible Phase 1 finding. `0` aborts `bad_verify_count`: the controller short-circuits a zero roster without calling the script. |
| `verifyCap` | TOTAL ceiling, clamped by `maxAgents`. Above it the stage refuses BY NAME up-front, never `agent_ceiling` after acceptance. Mirrors `REVIEW_FLEET_VERIFY_TOTAL_CAP` on the controller's side. |
| `verifyClaimPrefixAbs` | per-child claim card at `<prefix><NN>.json`. ONE string crosses the boundary; the per-child pathname is derived here, so no verifier can be pointed at a sibling's claim. |
| `verifyContractPathAbs` | the `finding-verifier-v1` output contract, manifest-resolved by the controller |
| `verifyRubricPathAbs` | `shared/finding-confidence-rubric-v1.md` |
| `verifyPrContextPathAbs` | the PR title/description artifact |

**There is no threshold key, and adding one is a defect.** The cutoff is applied
controller-side in `publish-verification`; a verifier told the cutoff calibrates
to it. `tests/review-pr-workflow.test.sh` V1 asserts the script mentions no
threshold scalar at all.

### `review` and `simplify` stages

| Key | Meaning |
|---|---|
| `diffPathAbs` | the **already-enveloped** diff artifact, written atomically in Bash. Read by path; never re-wrapped. |
| `aspects` | CSV emphasis tokens. Emphasis only — it never gates fanout membership (`commands/review-pr.md:1324`, `:4507`). |
| `focus` | `/simplify`'s free-text `## Additional Focus`, kept OUTSIDE the envelope |
| `fanoutCap` | reviewer wave size, `[1,50]` default 6. `sequential` ⇒ 1. |
| `lensConcurrency` | lens wave size, `[1,3]` default 3 |
| `runNonces` | the nonce pool — see below |

### `review` stage only

| Key | Meaning |
|---|---|
| `phase1ContractPathAbs` | absolute path to the Phase 1 reviewer output contract, resolved by the controller from `policy/solve-run-tree-v1.json` `output_contracts["phase1-reviewer-v1"]` (`lib/review-fleet-args.sh review_fleet_contract_path`). The script re-declares nothing: it has no filesystem, and a second spelling of the path would be a second declaration that drifts. Absent, relative or traversal-bearing ⇒ `abort("bad_contract_path")` with **zero** dispatches. |

### `fix` stage — controller-supplied authority, forwarded verbatim

`fixerEdgeId` (`review_pr.fix.phase1` \| `review_pr.fix.phase2` \|
`simplify.fix.phase2`), `commitType` (`fix` for phase1, `refactor` for phase2 —
the pairing is checked, and a mismatch aborts before dispatch),
`findingsPathAbs` + `findingsSha256`, `authorityPathAbs` + `authoritySha256`,
`dispositionPathAbs`, `appliedContentPathAbs`, and exactly one range family:
`commitRangePathAbs`/`commitRangeSha256` for the `review_pr.fix.*` edges, or
`standaloneSnapshotPathAbs`/`standaloneSnapshotSha256` for
`simplify.fix.phase2` (`commands/simplify.md:18`).

| Key | Meaning |
|---|---|
| `fixerContractPathAbs` | absolute path to the code-fixer output contract, resolved by the controller from `policy/solve-run-tree-v1.json` `output_contracts["code-fixer-v1"]` (`lib/review-fleet-args.sh review_fleet_contract_path`), same one-declaration rule as `phase1ContractPathAbs`. Absent, relative or traversal-bearing ⇒ `abort("bad_contract_path")` with **zero** dispatches. **Required by ALL THREE emitters** — this arm is shared by both modes and is deliberately *not* mode-scoped the way the `review` arm is, so `commands/simplify.md`'s `simplify.fix.phase2` fence owes the key exactly as the two `commands/review-pr.md` fences do (#474). |

### `postfix` stage (#655)

ONE bounded correctness review of a validated fixer's OWN commits, dispatched
once per applied fixer phase per review iteration. Its whole cost argument is
scope × lens count × agent count: the roster is one child, the diff is the
narrowest in the run, and the `agent()` call omits `model` because a reviewer
interprets — cheap here means less work, never a cheaper route through the same
work.

| Key | Meaning |
|---|---|
| `postfixCount` | integer — the size of THIS dispatch's roster, `REVIEW_FLEET_POSTFIX_LENS_COUNT` on the controller's side. Outside `1..postfixCap`, or unequal to the fixed roster length, it aborts `bad_postfix_count` up-front, never `agent_ceiling` after acceptance. `0` is a wiring bug: a phase with no applied fixer commit is short-circuited by the CONTROLLER, which never calls the script at all. |
| `postfixCap` | the per-review-iteration TOTAL ceiling (`REVIEW_FLEET_POSTFIX_TOTAL_CAP`), clamped by `maxAgents`. It spans BOTH passes — Phase 1 and Phase 2 each dispatch this stage once — so it is a different number from `postfixCount` and forwarding one as the other is the zero-dispatch bug the `ci-conflicts` cap comment records. |
| `postfixDiffPathAbs` | the **already-enveloped** diff of the fixer's own commits, written atomically in Bash by `review_build_postfix_scope` before the call. Read by path; never re-wrapped. |
| `postfixRangePathAbs` | the `<40hex>..<40hex>` commit-range carrier the controller wrote on the validated-`APPLIED` arm. Passed by path; the child re-derives nothing from it. |
| `postfixContractPathAbs` | the `phase1-reviewer-v1` output contract, manifest-resolved by the controller. The post-fix child is a `code-reviewer` emitting the Phase 1 reviewer document, so it binds to the SAME declaration the fanout binds to — one declaration, two stages, no second copy to drift. |
| `postfixPhase` | `phase1` or `phase2`, and nothing else. Gated rather than defaulted: it names which fixer's commits these are, and the controller keys the aggregate and the sidecar on it, so a guessed value files one phase's findings under the other. |

The three path keys above and `workingDirAbs` are all gated **before** the nonce
gate: a wiring regression must burn no nonce and dispatch no child. Absent,
relative or traversal-bearing ⇒ `abort("bad_postfix_diff_path" |
"bad_postfix_range_path" | "bad_postfix_contract_path" | "bad_working_dir")`
with **zero** dispatches.

### `defer` stage

`phase1PathAbs`, `phase2PathAbs`, `phase1DispositionPathAbs`,
`phase2DispositionPathAbs`, `maxNew`. `phase1PathAbs` is empty for `/simplify`
because no Phase 1 ran (`commands/simplify.md:547`) — that is a declared value,
not a missing one, and the script only enforces its presence in `review-pr` mode.

Three OPTIONAL keys ride the same single dispatch: `verificationPathAbs` (the
Phase 1 verification sidecar, #431) and `postfixPhase1PathAbs` /
`postfixPhase2PathAbs` (the two post-fix aggregates, #655). Each is rendered
into the child's input list only when non-empty; an omitted line means that
artifact does not exist for this run, and `findings-to-issues` then behaves
exactly as it did before the producing gate existed. A non-empty postfix path
that is not a safe absolute path aborts `bad_postfix_aggregate_path` — the same
gate the disposition pair takes, for the same reason: an ungated relative value
renders into the prompt and leaves the agent to improvise a location.

**Both transports owe these keys.** `review_pr.defer.findings` is dispatched
over the routed composer *and* over this script, and the script reads each input
by NAME off an args object with no unknown-key rejection. A key emitted for one
transport and unread by the other is discarded in silence: no abort, no `bad_*`
refusal, no failing test — the findings simply never reach the child. Add the
reader and the emitter in the same change.

### Phase 3 CI stages (#383)

The keys below are read by the four `ci-*` stages in `workflow.js`, minted by
`lib/review-fleet-args.sh`, and emitted by `commands/review-pr.md`'s Phase 3
fences. The executable proofs are `tests/review-pr-workflow.test.sh` section W
(every stage run for real), section E6 (the conflict fanout driven at its
ceiling and one past it) and section E7 (the CI binders executed against the
real contract), plus `tests/code-fixer-contract.test.sh`.

| Key | Stages | Meaning |
|---|---|---|
| `ciLoopIter` | all four | `[1,3]`, default 1. Phase 3's own loop counter. It keys the **slug** (`ciSlug`), never the child-directory formula — `iterSuffix()` still owns that suffix, so `<runDir>/children/ci-rebase-ci02-iter01` is unique in both counters through ONE formula. |
| `ciAuthorityPathAbs`, `ciAuthoritySha256` | `ci-classify`, `ci-fix`, `ci-defer` | the CI authority document, minted no-clobber by `prepare-ci-authority` and pinned into the binding by digest. **Not `ci-conflicts`** — see `ciConflictAuthorityPrefixAbs`. |
| `ciInputSha256` | `ci-classify`, `ci-fix`, `ci-defer` | the digest of the child's own pinned input document. The PATH is **not** an envelope key — the script derives it as `<childDir>/input.json`, so no agent-visible scalar can steer a sibling's read. |
| `ciFixerEdgeId` | `ci-fix` | `review_pr.ci.fix_code` \| `review_pr.ci.rebase`, keyed into the script's `CI_FIX_ARMS` table. Anything else aborts `unknown_ci_fixer_edge`. |
| `ciFailureClass`, `ciSignalAnchor` | `ci-fix` | what `validate-ci-classification` returned to the CONTROLLER, never what the classify child returned to the script. The class/edge pairing is re-checked in-script as a REFUSAL, not a blessing. |
| `ciRunId`, `ciHeadSha`, `ciBaseSha` | `ci-fix`, `ci-conflicts` | prompt scalars |
| `ciPrBranch`, `ciBaseBranch` | `ci-fix`, `ci-conflicts` | gated with `isSafeBindingScalar` |
| `ciConflictCount` | `ci-conflicts` | the resolver COUNT, never the path list |
| `ciConflictCap` | `ci-conflicts` | the TOTAL ceiling on the fanout, re-clamped in-script to `min(ciConflictCap, maxAgents)`. The effective number is therefore **40** under the `maxAgents=40` every call site emits — including `commands/review-pr.md`'s CONFLICT-RESOLVE arm — which is what `lib/review-fleet-args.sh`'s `REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP` refuses at on the controller's side. NOT `fanout_concurrency.conflict_resolver` — that key is a concurrency knob, and forwarding it here refuses an 11-conflict PR with zero resolvers dispatched; and NOT `ciConflictCount`'s bare 50 clamp either, because the roster length goes straight into `ceilingGate()` and a cap above `maxAgents` aborts `agent_ceiling` with zero resolvers dispatched. |
| `ciConflictWave` | `ci-conflicts` | the CONCURRENCY knob (`fanout_concurrency.conflict_resolver`, default 10) handed to `dispatchRoster`, which batches a larger roster into sequential waves |
| `ciConflictAuthorityPrefixAbs` | `ci-conflicts` | the per-resolver authority pathname MINUS its index: the script appends `<index>.json`, so ONE spelling of the rule crosses the boundary and resolver N is told about resolver N's authority. No digest is carried — a per-resolver digest cannot be forwarded as one scalar, and the controller re-checks each one itself when it judges. |
| `ciAggregatePathAbs`, `ciAggregateSha256` | `ci-defer` | the one-row `ci-refused-synthetic` aggregate |

**`lease_sha` is not in this table and never will be.** It is a member of the CI
authority document, pinned by digest, and the controller reads it back through
`read-ci-authority-member` (which re-checks the digest) at push time. The script
never sees it, because the script never pushes.

**`base_tip_sha` is not in this table either, for exactly that reason.** It is
the base branch's tip as the controller observed it before dispatch, and it
exists to prove — at push time, in the controller — that the head about to be
force-pushed is still descended from the branch the PR is based on (#438). Like
the lease, it is a controller-side proof value about a push the script does not
perform, so it lives in the authority document and nowhere else.

**There is no cross-stage note carrier, and there cannot be one.** The stages
are separate Workflow calls, so an in-call buffer is always empty in the defer
stage; a script has no filesystem verb, so it cannot persist one; every fence is
a fresh shell (#427), so no scalar survives; and no controller fence parses a
Workflow return at all. The only remaining courier would be the orchestrator
copying untrusted agent text out of a return into a later fence's shell word —
an LLM-composed handoff, which DR-2 forbids. The half-wired version of this — an
envelope key with no producer, an in-call array `finalize()` never returned, and
an untrusted-input wrapper for both — was deleted in #514: nothing embedded
agent-returned content in a prompt, so the hardening around it never executed
while reading, to anyone auditing, like coverage. Each child's `note` is
reported instead — see *What the script returns*.

---

## Bound children — the nonce protocol (P1, #381)

Every child that produces a result file is a **bound child**. The controller
mints a single-use `run_nonce` (64 lowercase hex) per child *before* the
Workflow call; the child echoes it verbatim into `status.json`. For a
`workflow`-backend child that nonce **replaces** the
`pid`/`process_identity`/`lease_generation` triple, which must be **absent** —
see `_validate_bound_child_status` and `_validate_bound_workflow_child_status`
(`lib/code_fixer_contract.py:7032` and `:6985`). A Workflow child is awaited
in-session, so it owns no pid and nothing could probe its liveness; the await
*is* the supervision (`lib/agent-dispatch.sh:1291-1302` — the
non-numeric-handle arm is a deliberate no-op, not a fall-through).

The nonce is a **binding token, not authority**. A garbled nonce makes the
child write one the controller never minted, and validation fails closed — it
can cost a refusal, never buy a false accept. That is why carrying it as an
envelope scalar is safe.

**`runNonces` is one comma-joined scalar consumed in fixed roster order.** These
two orders are a wire format; reordering either array silently re-binds every
child.

| Stage | Nonce index → edge |
|---|---|
| `review` | 0 `review_pr.review.correctness` · 1 `review_pr.review.silent_failures` · 2 `review_pr.review.types` · 3 `review_pr.review.comments` · 4 `review_pr.review.tests` · 5 `review_pr.review.general` · 6 `review_pr.review.convention` |
| `simplify` | 0 `review_pr.simplify.reuse` · 1 `review_pr.simplify.quality` · 2 `review_pr.simplify.efficiency` |
| `fix` | 0 — the single fixer child |
| `verify` | 0..N-1 — one `review_pr.verify.finding` child per ELIGIBLE Phase 1 finding (`severity: blocker` AND disposition != `APPLIED`), in the order `project-verification-claims` wrote the claim cards |
| `postfix` | 0 — the single `review_pr.postfix.correctness` child. Its slug is the roster base keyed by phase (`postfix-correctness-phase1` / `postfix-correctness-phase2`), the `ci-*` rule one stage over: both passes run inside ONE `reviewIteration`, so the iteration suffix cannot separate them and the phase keys the slug instead. `review_fleet_postfix_slug` and the script's `postfixSlug()` are the two halves of that formula and must stay byte-identical. |
| `defer` | 0 — the single `review_pr.defer.findings` child |
| `ci-classify` | 0 — the single `review_pr.ci.classify` child |
| `ci-fix` | 0 — the single `review_pr.ci.fix_code` **or** `review_pr.ci.rebase` child |
| `ci-conflicts` | 0..N-1 — one `review_pr.ci.resolve_conflict` child per conflicted path, in the CONTROLLER's own unmerged-path enumeration order |
| `ci-defer` | 0 — the single `review_pr.ci.defer_refusal` child |

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
`general`, `reuse`, `quality`, `efficiency`); for the fixer, the edge id
lowercased with every non-alphanumeric run collapsed to `-` (e.g.
`review-pr-fix-phase1`); and for the post-fix pass, the roster base keyed by
phase (`postfix-correctness-phase1`), because both of its passes run inside one
`reviewIteration` and `<NN>` cannot separate them. No extra envelope scalars, no
round-trip.

Every bound child is told to write `result.md.partial` and then publish it with
a **same-directory `mv -f`** — the shell spelling of the atomic rename
`os.replace` performs — and to do the same for `status.json`. Without that, the
controller can capture a torn half-written file and digest it as final.

**The result is published BEFORE the status, and that order is load-bearing**
(#645). The status is the completion signal, so `capture-bound-child` refuses a
result whose mtime is strictly newer than the status attesting to it
(`child_result_rewritten_after_status`). That is what stops a RE-DISPATCH of one
iteration — which inherits the same nonce and, because `childDirAbs()` keys on
`reviewIteration` alone, the same directory — from leaving a dead attempt's
report underneath a completed attempt's status. Reversing the two publishes in
the prompt would red every healthy child instead. It is
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
               findingCount, blockerCount, note, reason} ],
  fixerStatus, issues: {issuesCreated:[int], commentedUrls:[str], skipped, halted},
  nullsByPhase, auditEvents }
```

`children[].note` is the short sentence every child is asked for, and the one
channel a `BLOCKED` child has for saying *why*. It is **untrusted** agent text
derived from PR-author-controlled diff bytes, so it is clamped at capture:
control characters removed (C0 **and** C1 — C0 includes `\n` and `\r`), then
truncated to 200 characters, in that order. It reaches no prompt; its only
reader is the `WORKFLOW_RESULT` line above, which `JSON.stringify` already
escapes. Treat it as a lead when reading a run log, never as a fact.

`children[].status` ∈ `COMPLETE | BLOCKED` for reviewers and lenses, and
`APPLIED | NO_FIXES_NEEDED | REFUSED` for the fixer. A child whose returned
paths do not equal the script-derived layout is **downgraded to `BLOCKED` with
its paths blanked**, so the controller never goes hunting for an artifact at an
agent-chosen location.

## What the caller does with it

1. `abortReason` non-empty ⇒ nothing was dispatched past the guard. Treat it as
   a preflight failure of the calling command, not as a review result.
2. For `review`: source `lib/review-aggregate.sh`, then for each child mint the
   binding with `code_fixer_contract.py bind-workflow-launch` **before** the
   Workflow call, validate the returned `children[].resultPath` through
   `uberdev_child_validate_phase1_review_result` (which writes the canonical
   `0o400 validated-result.md` — no child of any backend writes it), append a
   `{edge,index,instance,binding,result,status}` row to the launched ledger and
   a `{edge,index,instance,result,sha256}` row to the validated ledger, then
   `post_review_validated_evidence_complete` →
   `post_review_capture_aggregation_inputs` →
   `post_review_write_aggregate_v2`. The binding row is proved by
   `code_fixer_contract.py capture-bound-child`, invoked from that builder — the
   verb accepts no caller-supplied digest and computes both itself. **Any
   `BLOCKED` reviewer blocks green
   trust** — missing reviewer evidence is not advisory, and the ordinary
   aggregate exists only after all seven slots have valid evidence. A missing or
   empty aggregate terminates `/review-pr` immediately without dispatching the
   fixer, Phase 2, deferred findings or trust; it is infrastructure failure,
   never a zero-finding review. Exact `findings: []` is the valid zero form.
3. For `fix`: mint the binding with `code_fixer_contract.py
   bind-workflow-fixer-launch` **before** the Workflow call — not
   `bind-workflow-launch`, which mints no authority pin — then
   `review_fixer_terminal_outcome` → (`capture-review-terminal` →
   `validate-review-outcome` | `publish-unapplied-terminal`) →
   `validate-residue` → `review_track_validated_fixer_head` →
   `review_refresh_phase1_scope`. The branch is on the disposition record the
   controller pre-created, and existence is read separately from size: a
   NON-EMPTY record is a terminal to capture; an EXACTLY-EMPTY one is a child
   that applied nothing, whose record the controller publishes on its behalf
   from the returned rows (`agents/code-fixer.md`, "A refusal owes no second
   publication"); an ABSENT one is workspace loss or tampering and refuses
   without invoking any verb. `fixerStatus` is a **hint for logging
   only** — the disposition artifact and the head movement are the truth. The
   outcome carries `run_nonce` where a detached outcome carries
   `receipt_sha256`; a consumer that checks the detached key must be taught the
   workflow shape rather than handed the nonce under the old name.
4. For `simplify`: build the canonical aggregate and pipe it through
   `encode-aggregate --phase phase2` before any digest.
5. For `defer`: mint with `code_fixer_contract.py
   bind-workflow-persistence-launch` **before** the Workflow call, then
   `capture-persistence-terminal` → `validate-persistence-result`.
   `issues.halted` is a **reporting hint only** — the same status
   `fixerStatus` holds in item 3. The Phase-2.5 HALT decision comes from
   `validate-persistence-result`'s receipt, computed from the child's own frozen
   result bytes, never from the script's agent-declared return
   (`commands/review-pr.md:2534-2536`). The script's `issues` return supplies
   the counts and URLs for the Step 7 table and nothing else. That gate needs
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
| Phase 1 output contract | `review` only. An absent, relative or traversal-bearing `phase1ContractPathAbs` aborts `bad_contract_path` **before** the nonce gate, so no nonce is burned. Seven reviewers dispatched without a stated serialization all fail `uberdev_child_validate_phase1_review_result` and the whole aggregate is suppressed — a full fanout spent to learn a wiring bug (#403) |
| fixer output contract | `fix`, in **both** modes — the arm is shared, so this governs `simplify.fix.phase2` too. An absent, relative or traversal-bearing `fixerContractPathAbs` aborts `bad_contract_path` **before** the nonce gate. Stricter than the reviewer twin in consequence, not in mechanism: a fixer has already COMMITTED by the time its result is parsed, so an unbound format strands unattributable history and escalates the run to `MUTATED_BLOCKED` (#474) |
| post-fix scope, count and phase | `postfix` only. The range diff, the commit-range carrier, the reviewer contract and `workingDirAbs` are all gated **before** the nonce gate, so a wiring regression burns no nonce and dispatches no child. A `postfixCount` outside `1..postfixCap`, or unequal to the one-child roster, aborts `bad_postfix_count` BY NAME up-front rather than `agent_ceiling` after acceptance. A `postfixPhase` that is neither `phase1` nor `phase2` aborts `bad_postfix_phase` rather than defaulting: the controller keys the aggregate and the sidecar on it, so a guess files one phase's findings under the other (#655) |
| commit-type / edge pairing | `phase1`⇒`fix:`, `phase2`⇒`refactor:`; a mismatch aborts |
| runtime `budget` | checked between waves with `budget && budget.total && budget.remaining() <= 0` — `parallel()` never rejects, so a budget throw would otherwise arrive as a silent `null` |

Wall-clock breakers are impossible in-script: time arrives frozen in `now_iso`
and the runtime forbids the nondeterministic clock global (DR-7).

## Why `parallel()`, not `pipeline()`

Both fanouts are **genuine barriers**, and each carries a comment saying so. The
controller's aggregate writers consume the **full** roster —
`post_review_write_aggregate_v2` re-validates the closed seven-edge roster, and
`encode-aggregate` does the same for the three lenses — so there is no
partial-consumption step a barrier-free `pipeline()` could overlap with. It
would buy nothing here while making this the first shipped `pipeline()` call
site in the plugin, on the flagship review path, against semantics currently
pinned only by harness self-tests.

## Not built in P2 (deliberate)

**The trust-anchor/verdict tail is not dispatched from this script**;
`/review-pr` keeps its existing Bash for it, and that phase is not declared in
`meta.phases`.

**Phase 3 — CI health was in this section until #383 built it**, in two halves:
half one shipped the four `ci-*` stages, their producer, capture verb and
judges, and half two re-pointed `commands/review-pr.md`'s fences at them. What
stayed behind in Bash, and why, is not a leftover:

- **6c.1 PROBE and 6c.2 MONITOR dispatch no agent.** MONITOR additionally
  *cannot* move: `Date.now()` / `new Date()` throw inside a Workflow script and
  `now_iso` is frozen at preflight (DR-7), so the 480 s per-fence and
  `CI_MONITOR_DEADLINE_SEC` across-fence budgets are not expressible there.
- **The rebase lease, `git add`, `git rebase --continue`, the force-push, the
  mid-rebase abort and `gh run rerun`** are mutations, and mutations are the
  controller's by the seam rule.
- **The loop counters** live in an on-disk sidecar
  (`review_fleet_write_ci_state`), not in an in-script `while`: the loop is the
  controller RE-ENTERING Phase 1, and an in-script counter would lose the count
  the moment the call returned.

---

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini, Copilot, pre-Workflow Claude
Code), **run the stages inline as directives in the calling session**. Each
stage below is the exact same fanout the script performs, dispatched with the
`Task` tool instead; the calling-session Bash between stages is **unchanged**,
because it was never inside the Workflow to begin with — that is the whole point
of the seam, and it is why this fallback is a re-dispatch rather than a
re-implementation.

Those Bash blocks are each a **fresh shell** on every runtime, so every one of
them opens by re-deriving its own run: `review_fleet_rehydrate`
(`lib/review-fleet-args.sh`) resolves the plugin root, the repository root, the
run identity and every artifact path from disk rather than from a shell that has
already exited (#427). The fallback needs nothing extra for this — the same
fences carry the same prologue.

1. **`review`** — dispatch all seven reviewers in ONE message
   (`uberdev:code-reviewer` twice for the correctness and general lenses, plus
   `uberdev:silent-failure-hunter`, `uberdev:type-design-analyzer`,
   `uberdev:comment-analyzer`, `uberdev:pr-test-analyzer`,
   `uberdev:convention-compliance`), each reading
   `diffPathAbs` by path, each writing `result.md.partial` → `mv -f` →
   `result.md` and its nonce-bearing `status.json` at the layout above. The
   convention child — and only it — also receives the absolute
   `rule-sources.txt` path, the citation grammar its `detail` must use, and the
   empty-allowlist instruction. When
   `fanoutCap < 7`, split into `ceil(7 / fanoutCap)` sequential waves, still
   dispatching every child in a wave before the first wait.
2. **`verify`** — dispatch one `uberdev:finding-verifier` per ELIGIBLE Phase 1
   finding in ONE message, each reading only its OWN claim card
   (`<verifyClaimPrefixAbs><NN>.json`) plus the diff, the PR context and the
   rubric BY PATH. Each is a **bound child** like every other, and that is not
   ceremony here: the controller captures every verifier through
   `capture-bound-child` before it reads a single opinion, so a verifier that
   skipped the partial-then-rename publish rule or echoed a nonce this run never
   minted is recorded `verifier-unavailable` — which never culls, but never gets
   to defend the finding either. **Never tell the child the confidence
   threshold**: the controller compares the score against a cutoff the verifier
   does not see, which is what keeps the number an opinion about the claim
   rather than a vote about the gate. Do not skip this stage silently — with no
   verifier available, run the gate's kill switch (threshold 0) deliberately, so
   every eligible finding is recorded `gate-disabled` and SURVIVES.
3. **`fix`** — dispatch ONE `uberdev:code-fixer` on the controller-supplied
   edge, with the authority scalars verbatim. Never in parallel with anything,
   and never worktree-isolated: it commits onto the caller's checkout on the PR
   branch, git forbids two worktrees on one branch, and an isolated child's
   disposition artifact would vanish with its throwaway worktree.
4. **`postfix`** — dispatch ONE `uberdev:code-reviewer` over the validated
   fixer's own commit range, reading the enveloped range diff and the
   `<40hex>..<40hex>` carrier BY PATH and bound to the same
   `phase1-reviewer-v1` output contract the Phase 1 fanout uses. Dispatch it
   only when that carrier EXISTS: its absence is the zero-dispatch
   short-circuit, and the writer that creates it fails closed, so "no file" can
   only mean "no applied commit". Publish the per-phase sidecar on the
   zero-dispatch paths too — a run that recorded nothing must not read
   downstream like a run that found nothing.
5. **`simplify`** — dispatch the three `uberdev:code-simplifier` lenses in ONE
   message, `## Lens emphasis` and `## Additional Focus` kept OUTSIDE the
   envelope.
6. **`defer`** — dispatch ONE `uberdev:findings-to-issues` with both aggregate
   paths and both disposition paths; the agent owns `max_new`, dedupe and halt.
7. **`ci-classify`** — dispatch ONE `uberdev:ci-failure-classifier` reading its
   pinned input document by path, writing `result.md` + `status.json` at the
   layout above. Its slug carries the CI loop counter (`ci-classify-ciNN`), so
   the directory is `<runDir>/children/ci-classify-ciNN-iterMM`.
8. **`ci-fix`** — dispatch ONE `uberdev:ci-code-fixer` (for `code_bug` /
   `env_drift`) or ONE `uberdev:ci-rebase-handler` (for `stale_base`), chosen by
   the controller-supplied `ciFixerEdgeId`. Never worktree-isolated: both commit
   onto the caller's checkout on the PR branch. **The rebase child must not be
   given a push tool** — the controller holds the lease and pushes.
9. **`ci-conflicts`** — dispatch one `uberdev:conflict-resolver` per conflicted
   path in ONE message, each reading only its own input document. The path list
   comes from the controller's own unmerged-path enumeration
   (`code_fixer_contract.py list-ci-unmerged-paths`), never from the rebase
   child's return.
10. **`ci-defer`** — dispatch ONE `uberdev:findings-to-issues` against the
    one-row `ci-refused-synthetic` aggregate, with the three other
    aggregate/disposition inputs declared empty.

Between every pair of stages, run the same calling-session Bash the staged table
above lists. Do not skip a proof because the fanout came from `Task` — the
authority chain is identical on both paths.
