---
name: goal-pipeline
description: "Autonomous convergence pipeline for /uberdev:goal. Drives the cycle algorithm (RFC 0005 §3.3) and the PR/issue state machines from skills/goal-pipeline/workflow.js, with each phase in an independently-testable lib/goal-*.sh script. Runs on the Workflow-native backend (RFC 0015 §5) — the per-issue solvers come from skills/solve-fleet/workflow.js, not from a detached `claude --bg` session."
---

# Goal Pipeline (autonomous convergence body for /uberdev:goal)

This skill is invoked inline by `commands/goal.md`. It preflights the run, then hands the **whole cycle loop** to `skills/goal-pipeline/workflow.js` — a Workflow-native driver that owns the queue, the cycle counter, the candidate set and the fingerprint history as ordinary JS variables spanning the run, and drives each cycle through four relay-run shell phases.

> **You are an orchestrator, not an implementer.** You run the preflight, relay one JSON envelope into one `Workflow(...)` call, and print the summary it returns. You never write feature code, never decide a trust colour, and never hand-compose the args envelope.

## Why this is a driver and not a set of fences (RFC 0015 §5)

Every phase of `/goal` used to be a ```bash fence in this file. Two structural facts made that shape unfixable:

1. **Each fence is a separate shell.** The cycle counter, the rollover queue, the candidate array, the EXIT/INT/TERM traps and every accumulated counter died at the fence boundary. The false-converge, the rollover wipe and the dead circuit breakers were all the same bug wearing different clothes — and each was patched individually until the next variable died.
2. **The Skill renderer substitutes `$ARGUMENTS`' positional tokens into the whole body**, including inside single-quoted `awk` one-liners and — per #404 — every shell positional in a `bash` fence, braced or not. `lib/*.sh` is never rendered, so bare positional refs are safe there. This sentence carries no literal dollar-digit token for the same reason.

So the executable body now lives in four shebang'd, independently-testable scripts, and the loop that used to be an instruction to the model is a real loop in a real driver.

| Phase | Script | Owns |
|---|---|---|
| 0 — preflight | `lib/goal-phase0.sh` | arg parse, config reads, `GOAL_ID` mint, state init, `--resume` rehydration, the `uberdev_emit_workflow_args goal …` envelope |
| 1 — claim | `lib/goal-phase1.sh` | label provisioning, the `uberdev:active` cross-process claim, the `MAX_PARALLEL` rollover, the `input -> dispatched` transition. **It does not dispatch.** |
| 2 — watch | `lib/goal-watch.sh` | the merge lane + every circuit breaker, under the documented `0` (drained) / `42` (re-invoke) / `1` (halt) exit contract |
| 3 — collect | `lib/goal-phase3.sh` | candidates → fingerprint repeat → overflow truncation → terminal gates |
| driver | `skills/goal-pipeline/workflow.js` | the cycle loop, the projected-agent gate, and **exactly one** nested `workflow()` call per cycle into `skills/solve-fleet/workflow.js` |

**There is no `solve-one.js`, and there must not be one.** `workflow()` nesting is one level deep. The solve-fleet script already fans out per issue internally (waves of `concurrency`, one worktree-isolated solver each, plus the research/spec/plan chain for the medium tier). A nested call *per issue* would spend the single nesting level on the wrong thing and the fleet's own agents could not run.

## Constants

All audit-event names, state-machine enums, regex shapes, and tunable thresholds are declared here once. Later phases reference these names by symbol; values are NOT re-inlined.

> **Runtime SSOT:** the scalar constants below are mirrored into `plugins/uberdev/lib/goal-state.sh` (using `: "${VAR:=default}"`) so fresh-shell rehydration fences in Phases 1/2/3/4 — which source ONLY the lib, never re-execute this Phase 0 block — get canonical defaults. This SKILL.md block is the documentation SSOT and is preserved byte-identical for tests G24/G28/G34. See issue #245.

<!-- The block below is held byte-identical by tests/goal.test.sh G24/G28/G34,
     so the #370 contract markers sit outside the fence and resolve forward
     via @anchor. See docs/rfc/0016-contract-markers.md. -->
<!-- CONTRACT: goal-audit-event @GOAL_AUDIT_EVENT_ENUM= -->
<!-- CONTRACT: goal-circuit-breaker-reason @GOAL_CIRCUIT_BREAKER_REASONS= -->
<!-- CONTRACT: trust-signal @TRUST_SIGNAL_ENUM= -->
```
GOAL_AUDIT_EVENT_ENUM='goal_dispatched|goal_pr_transition|goal_unblock_triggered|goal_cycle_completed|goal_converged|goal_circuit_breaker|goal_merge_deferred|goal_review_pr_deferred|goal_review_grace|goal_reaper_kill|goal_reaper_skipped|goal_issue_closed_without_pr|goal_version_bumped|goal_partial_chain|goal_partial_delivery'
GOAL_CIRCUIT_BREAKER_REASONS='max_cycles|nonconvergence|stuck_loop|merge_failed|gh_api_failed|unknown_merge_result|queue_empty_not_converged|agent_stuck_on_dialog|solver_failed|backend_resolve_failed'
GOAL_PR_STATE_ENUM='dispatched|pushed-reviewing|green|yellow-held|red-held|merging|merged|merge-failed'
GOAL_ISSUE_STATE_ENUM='input|dispatched|solving|pr-pushed|resolved|resolved-by-no-action|failed'
TRUST_SIGNAL_ENUM='green|yellow|red|stale|missing'
GOAL_MERGE_RESULT_ENUM='success|conflict|hook_failed|missing'
_UBERDEV_GOAL_DEFAULT_MAX_CYCLES=5
_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL=3
_UBERDEV_GOAL_DEFAULT_IMPLEMENT_BUDGET=24      # the nested fleet's CB3 per-issue implement cap; CB1 projects against it (issue #590)
_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S=14400
_UBERDEV_GOAL_POLL_SECS=60
_UBERDEV_GOAL_STUCK_SECS=14400         # 4h
_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3
_UBERDEV_GOAL_SOLVE_TIMEOUT=9000       # 150m — no PR AND no live agent => issue failed (issue #180)
_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS=3600   # 60m default — overridable via goal.review_grace_secs / UBERDEV_GOAL_REVIEW_GRACE_SECS / --review-grace-secs (issue #220, AC ❶)
_UBERDEV_GOAL_MERGE_TIMEOUT=3600       # 60m — merging w/o MERGED AND agent idle => back to green for retry (issue #180)
_UBERDEV_GOAL_BODY_CAP=65536           # 64 KiB
FINDING_LABEL='review-pr-finding'
FINDING_FINGERPRINT_REGEX='<!-- uberdev:review-pr-finding fingerprint=([a-f0-9]{16}) -->'
BLOCKS_LINE_REGEX='^Blocks: #([0-9]+)$'
```

Notes on the enums:

- **`GOAL_AUDIT_EVENT_ENUM`** — the 15 events `lib/goal-state.sh::uberdev_goal_audit` accepts. Any other event name returns non-zero from the helper and is dropped on the floor; consumers grep these literals. `goal_version_bumped` (issue #364) records the mandatory pre-landing bump with `action ∈ {bumped, already_bumped, skipped}`; a bump that could NOT be guaranteed is recorded on the existing `goal_merge_deferred` event with `reason=version_bump_failed` — the merge really was deferred, so it needs no new event. `goal_partial_chain` (issue #592) is **RESERVED VOCABULARY — nothing emits it yet.** It is the member name held for the re-queue decision record of a PR whose solver task chain stopped short (`stage ∈ {requeued, at_cap, transition_refused}` plus a diagnostic no-op stage), landed ahead of the re-queue mechanism itself so the closed enum did not have to be widened twice. The mechanism is tracked in **issue #613**; until it lands, the only occurrences in the tree are this declaration and the accepting arm in `lib/goal-state.sh`, which says in its own comment that the event is deliberately not read. What SHIPS today is the opposite of a re-queue: `lib/goal-phase3.sh` halts the convergence branch and tells the operator the run cannot re-queue them because a landed partial delivery is permanent for the run, and `skills/solve-fleet/workflow.js` flags the issue and never re-queues it. **Do not read a zero count of these rows as "no decision was taken"** — no producer exists to write one. `goal_pr_transition` carries an OPTIONAL `partial_chain: true` **subfield** (issue #592) on the one decision row where a partial-chain PR leaves `green` for `merging` — subfield reuse rather than a new event, because it is the same transition; only the literal `1` in the optional fifth positional of `uberdev_goal_pr_state_transition` sets it, so no other value a caller passes can reach the payload text. `goal_partial_delivery` (issue #592) is the merge lane's counterpart and records a different decision at a different moment: payload `{goal_id, pr, issue, cycle}`, emitted as a partial-chain PR leaves `green` for `merging` — on BOTH arms that make that transition (the already-merged/resume arm and the dispatch-success arm) and on neither of the arms that withhold the merge, where the PR stays green and would otherwise be re-flagged every tick. **One row per PR is conditional on the `MERGING` sentinel write succeeding**: that write, not the `green → merging` state transition, is what drops the PR out of the merge lane's GREEN candidate list, and both arms let it fail soft — so a run whose sentinel write fails re-flags the PR each tick until it sticks. That is accepted rather than de-duplicated, because such a run is already degraded (its merge barrier may not be serializing) and it says so on stderr. It does not change which PRs `/goal` is willing to merge; it is what stops an unattended run from reporting a converged issue it did not converge.
- **`GOAL_CIRCUIT_BREAKER_REASONS`** — the 10 halt reasons emitted by Phase 2/3/4 inside the `goal_circuit_breaker` payload's `.reason` field. The four original reasons (`max_cycles`, `nonconvergence`, `stuck_loop`, `merge_failed`); two surfaced-failure reasons added during post-impl-review (`gh_api_failed` — Phase 3 `gh issue list` rc!=0 instead of falsely treating an empty candidates list as convergence; `unknown_merge_result` — Phase 2d case default arm for a `uberdev_goal_read_merge_result` value outside the documented `success|conflict|hook_failed|missing` set); `queue_empty_not_converged` — Phase 3 deterministic halt when the candidate queue is empty but at least one PR is still in a non-terminal state (issue #160; deterministic alternative to the 4h `stuck_loop` wall-clock fallback); `agent_stuck_on_dialog` (issue #220 — Phase 2 stuck-on-dialog detector, see Component 3.4); and `solver_failed` — a dispatched solver reached a terminal failed/no-PR state, so convergence would be false. `solver_failed` covers **two** distinct Phase-3 halts, told apart by the payload's `phase` **subfield** rather than by a second reason (issue #592): the dispatched-solver failure above, which carries no `phase`, and `phase=partial_chain` — every PR terminal but at least one issue's solver **task chain stopped short**, so the convergence that would otherwise be declared here is false. Subfield reuse is deliberate and is the same shape `lib/goal-watch.sh` already uses for `stuck_loop` + `phase=blocks_cycle`. `skills/goal-pipeline/workflow.js` surfaces that subfield in its run result as its own `haltPhase`, never concatenated into `haltReason` — the reason string is what existing readers match on. `backend_resolve_failed` (issue #624) is the tenth: `lib/goal-phase3.sh`'s rehydration calls `uberdev_dispatch_resolve_env`, a host-capability preflight whose one failure mode is a detached-transport host with no `timeout(1)`/`gtimeout(1)`, and that exit used to append NO row at all — so the collect relay, which publishes the reason of the LAST `goal_circuit_breaker` row in the run's jsonl, republished an earlier phase's or an earlier CYCLE's reason as this halt's cause. It is a member and not a `phase` subfield because both subfield reuses above discriminate two shapes of the SAME failure, and a host missing a coreutils binary is not a solver that fell short. The set is closed; new reasons require an RFC amendment (this one has RFC 0005 §9 D624a).
- **`GOAL_PR_STATE_ENUM`** — the 8 states the PR machine in `_uberdev_goal_pr_state_machine_valid` recognises. `merged` and `merge-failed` are hard terminal (no further transitions); `yellow-held` and `red-held` are pseudo-terminal for convergence (Phase 3 counts them as terminal so the goal can converge cleanly with held PRs remaining, but the held-PR re-review poll loop in Phase 2 step 2e can still arc them to `green` once a re-review clears the findings, or cross-classify between `yellow-held`/`red-held` if a re-review's trust signal severity changed). `yellow-held → merging` and `red-held → merging` are hard-forbidden (D17 — never merge YELLOW/RED inside `/goal`).
- **`GOAL_ISSUE_STATE_ENUM`** — the 7 states the issue machine recognises. Happy path: `input → dispatched → solving → pr-pushed → resolved`. Close-without-PR path (issue #249): `input → dispatched → solving → resolved-by-no-action` — distinct from `resolved` (which means "PR landed and the issue auto-closed via `Closes #N`"); `resolved-by-no-action` means `/uberdev:orchestrator` legitimately closed the GitHub issue without producing a PR (e.g. stale finding, already-resolved). `dispatched` (issue #236) is written by the parent BEFORE `uberdev_dispatch_one` so any leaf-side crash between spawn and the post-spawn `solving` write still leaves a TSV row the Phase-1 skip-check (`dispatched|solving|pr-pushed`) matches on the next cycle — closes the silent double-spawn surface where a pre-state-write leaf failure looked identical to "never attempted". `resolved`, `resolved-by-no-action` and the three `→ failed` sinks (`dispatched`, `solving`, `pr-pushed`) are terminal. Partial-delivery re-entry (issue #592): `pr-pushed → input` is the **one** backwards arc, so an issue whose PR landed with its task chain stopped short can re-enter the queue for the tasks that never shipped — which is why `pr-pushed` is no longer terminal itself. **The arc is ACCEPTED by the machine but no caller traverses it yet**; like `goal_partial_chain` above it is vocabulary landed ahead of the re-queue mechanism in issue #613, so today a partial delivery is flagged and left where it is. It is deliberately the only backwards arc: `solving → input` stays rejected, because what is modelled is re-entry after a **landed** partial delivery, not a slip backwards out of an in-flight solve. **No member is added** — the arc reuses the existing `input` state, so the enum scalar above is byte-unchanged.
- **`TRUST_SIGNAL_ENUM`** — the 5 values `uberdev_goal_read_trust_signal` returns. `stale` (phase2_5 missing in audit JSON) and `missing` (audit JSON absent) both trigger `_uberdev_goal_dispatch_review_pr` rather than an assumed GREEN (D17).
- **`GOAL_MERGE_RESULT_ENUM`** — the 4 values `uberdev_goal_read_merge_result` returns. Maps the merge-pipeline's audit-row events (`merge_executed` for `success`, `pr_parked` with `data.reason ∈ {refused, ambiguous, push-non-ff}` for `conflict`, `pr_parked` with `data.reason == test-fail-exhausted` for `hook_failed`) plus a sentinel `missing` for "no audit row appended yet". Phase 2d's case statement handles each value explicitly; the `*)` default arm emits `goal_circuit_breaker reason=unknown_merge_result` (B7 — defensive guard against future enum drift).
- **`BLOCKS_LINE_REGEX`** is the anchored ReDoS-safe shape (D9 + T1) used by `_uberdev_goal_parse_blocks_line` in `lib/goal-state.sh`. The Phase 3 prose and the Unblock rule both reference this constant by name; the literal `^Blocks: #([0-9]+)$` appears here once.
- **`FINDING_FINGERPRINT_REGEX`** is the marker shape `agents/findings-to-issues.md` injects into every BLOCKER/CRITICAL `review-pr-finding` issue body; Phase 3 extracts it via `_uberdev_goal_extract_fingerprint` to drive the repeat-cycle detector.
- **`_UBERDEV_GOAL_DEFAULT_IMPLEMENT_BUDGET`** (issue #590) is the nested solver fleet's CB3 per-issue implement-phase agent cap as `/goal` resolves it, and it exists here because **CB1's per-issue projection is derived from it**. Phase 0 resolves it through the usual chain — `--implement-budget=N` > `UBERDEV_GOAL_IMPLEMENT_BUDGET` > `goal.implement_budget` > `UBERDEV_SOLVE_FLEET_IMPLEMENT_BUDGET` (the variable `lib/solve-launcher.sh` already reads when it composes the fleet envelope) > this default — clamps it to the fleet's own `4..96`, and publishes it as the envelope's `implementBudget` key. `skills/goal-pipeline/workflow.js` then does two things with it: it prices the pre-claim projection against it, and it pins it back onto the STEP 2 launcher command line so the fleet is **armed** with the number `/goal` projected against rather than merely measured by it.

### CB1 — the per-cycle agent projection

`projectedAgentsForCycle(issueCount)` is computed BEFORE the claim pass and compared against `agentsSpent + projection > maxAgents`. It has three terms, and every one of them is a term the nested fleet really spends:

| Term | Value | Why |
|---|---|---|
| driver relays | `3 + maxWatchTicks` | the claim, verdict and collect relays, plus up to `maxWatchTicks` watch relays |
| fleet run-level | `2 + (issueCount > 0 ? 1 : 0)` | the fleet's batched intake relay and batched PR-claim verification relay (#515), plus its run-shared repo profile (#615 A), which it dispatches once per run that has any design-tier issue |
| fleet per-issue | `issueCount × (9 + implementBudget)` | the issue's own solver, the nine research/design agents a medium-tier issue costs, and the #508 per-task implementer → reviewer → fix chain bounded by `implementBudget` |

`/goal` has no manifest at projection time and so no tier breakdown; it prices **every** claimed issue as design-tier, which is why the repo-profile gate reduces to "the cycle claimed something". The same two helpers price the SPEND accumulator after the fleet returns, so the ceiling and the ledger cannot answer differently. **A ceiling that under-projects is not a ceiling**: CB1 is the only NAMED halt, so a projection reading low does not merely mis-report — it stops firing, and the run dies against the runtime's own lifetime cap with no halt reason, no audit row and no cycle record saying why it stopped. That is exactly what a frozen per-issue literal did at any raised budget (#590), and what an uncounted repo-profile agent did on every cycle.

## Preflight

Run this ONCE. It resolves the execution contract, validates every issue number, resolves the tunables, mints (or with `--resume` rehydrates) `GOAL_ID`, initialises the on-disk state, and prints the args envelope.

The `[ -f … ]` tests are LIVE guards, not prose: a missing or misnamed script must refuse here, at preflight, never later at the runtime layer (RFC 0012 §4.1).

```bash
GOAL_WORKFLOW_JS="$CLAUDE_PLUGIN_ROOT/skills/goal-pipeline/workflow.js"
GOAL_PHASE0_SH="$CLAUDE_PLUGIN_ROOT/lib/goal-phase0.sh"
[ -f "$GOAL_WORKFLOW_JS" ] || { echo "goal: $GOAL_WORKFLOW_JS missing (RFC 0012 §4.1) — reinstall the plugin; /goal has no non-Workflow driver" >&2; exit 2; }
[ -f "$GOAL_PHASE0_SH" ] || { echo "goal: $GOAL_PHASE0_SH missing (RFC 0012 §4.1) — reinstall the plugin" >&2; exit 2; }
bash "$GOAL_PHASE0_SH" $ARGUMENTS
```

Exit codes: `0` envelope emitted (or `--dry-run` preview printed and nothing else to do), `2` usage error / invalid issue number / no bash ≥ 4 reachable, `3` run-state could not be persisted. On `--dry-run` the preflight prints the preview and emits **no** envelope — stop there.

## Workflow mandate

Relay the JSON between `WORKFLOW_ARGS_BEGIN` and `WORKFLOW_ARGS_END` **verbatim** (DR-2 — byte for byte; never re-key it, never re-compose it, never summarise it):

```
Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/goal-pipeline/workflow.js"}, <args>)
```

The driver returns a structured result and logs it as one `WORKFLOW_RESULT` line. Progress is visible with `/workflows` — there is no separate agent surface to poll.

## Post-Workflow summary

After the driver returns, print the operator's narrative from the on-disk audit trail — the same `print_summary` contract the fence era had, read from state rather than reconstructed from the model's memory of the run:

**`UBERDEV_GOAL_ID` is NOT in scope here, and gating on it would make this fence dead code.** `lib/goal-phase0.sh` exports it inside its OWN process, several Bash calls ago; this shell inherits nothing from it. `uberdev_goal_read_run_state` is what recovers the id — it bootstraps `GOAL_ID` from the fixed-path `goal-active-id.txt` pointer (`lib/goal-state.sh`, issue #171) — so it is called **unconditionally**, exactly as `lib/goal-phase1.sh`, `lib/goal-watch.sh` and `lib/goal-phase3.sh` call it, and **its** exit status is the gate.

```bash
[ -r "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh" ] && . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
[ -r "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh" ] && . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
if uberdev_goal_read_run_state; then
  print_summary "${cycle:-1}"
  GOAL_AUDIT_LOG="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}/goal-${UBERDEV_GOAL_ID:-${GOAL_ID:-}}.jsonl"
  printf '  audit: %s\n' "$GOAL_AUDIT_LOG"
  tail -n 5 "$GOAL_AUDIT_LOG" 2>/dev/null || true
else
  echo "goal: no run-state to summarise (no goal-active-id.txt pointer under \${UBERDEV_TMPDIR:-\${TMPDIR:-/tmp}}) — the driver's WORKFLOW_RESULT line above is the record of this run." >&2
fi
```

`print_summary` lives in `lib/goal-state.sh` (issue #270), not inline here: a shell function does not survive a fence boundary, and defining it in a trailing fence stranded it so every non-final exit path hit `command not found` and silently dropped the operator summary + the held-PR post-mortem rows.

## No-Workflow fallback

Codex, Gemini, Copilot and pre-Workflow Claude Code have no `Workflow` tool. There is **no detached-session fallback for `/goal`** — the interim `uberdev_dispatch_demote_workflow_to_detached` shim that used to demote a `workflow` resolution back onto the detached `claude --bg` transport is deleted (RFC 0015 §5), because keeping it meant that transport stayed on a default path. The transport itself was deleted in turn (RFC 0015 §7 as amended).

What remains is the manual sequence. Every phase script is a normal executable with a documented exit contract, so the loop can be driven by hand (or by any harness) without the driver:

Every phase script runs under **bash ≥ 4** (`lib/goal-watch.sh`'s verdict locator iterates unmatched globs, which zsh and bash 3.2 do not survive). Phase 0 resolves one and exports it as `UBERDEV_GOAL_BASH`; drive the rest with that, never with PATH `bash` — stock macOS ships 3.2.

```bash
export CLAUDE_PLUGIN_ROOT=<plugin root>

# Preflight ONCE. Name a detached backend explicitly — with no `Workflow` tool
# present, the default resolution has nothing to run on. Phase 0 prints
# the resolved interpreter as the envelope's config.bashBin (and exports
# UBERDEV_GOAL_BASH); GBASH below is that interpreter.
bash "$CLAUDE_PLUGIN_ROOT/lib/goal-phase0.sh" 123 124 --backend=background
GBASH="${UBERDEV_GOAL_BASH:-$(command -v bash)}"

# Then, per cycle:
#  1. claim. Prints one JSON line: {"dispatch":"<csv>","rollover":"<csv>",...}
"$GBASH" "$CLAUDE_PLUGIN_ROOT/lib/goal-phase1.sh"
#  2. solve the claimed set. `--force` is required, not optional: step 1 already
#     took the `uberdev:active` claim for these issues, so the launcher's own
#     claim pass would otherwise refuse them as a collision with us. Arm it with
#     EXACTLY the `dispatch` list — `--force` means an issue you add by hand
#     here is solved without ever having been claimed.
"$GBASH" "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=1 --turbo -- \
  <claimed issues> --backend=background --force
#  3. reconcile: --mark-solving=<csv> on success, --mark-failed=<csv> otherwise.
#     A non-zero exit here means a state transition did NOT land — stop and fix
#     it; step 4 can never drive an issue whose row is stuck at `dispatched`.
"$GBASH" "$CLAUDE_PLUGIN_ROOT/lib/goal-phase1.sh" --mark-solving=<csv>
#  4. watch until it stops asking to be re-invoked (0 drained / 42 again / 1 halt).
while :; do
  "$GBASH" "$CLAUDE_PLUGIN_ROOT/lib/goal-watch.sh"; rc=$?
  [ "$rc" = "42" ] || break
done
[ "$rc" = "0" ] || exit "$rc"
#  5. collect (0 converged -> stop / 42 loop back to step 1 / 1 halt).
"$GBASH" "$CLAUDE_PLUGIN_ROOT/lib/goal-phase3.sh"
```

`--backend=background` in that sequence is the deliberate escape hatch: it is a detached transport with a PID, a status file and a result file, so a harness with no `Workflow` tool can still supervise the run. `auto` never selects it. It is also the only such transport: `--backend=codex` is an enum error since #381 deleted that backend (`lib/dispatch.sh:509`), so a Codex session takes this same line.

## Scoped relaxations

`/goal` is the one place in UberDev where three otherwise-strict conventions are deliberately relaxed (RFC 0005 §2.3). Every relaxation is scoped to `/goal` only — the relaxed behaviour does NOT leak to standalone `/turbo`, `/merge`, or `/review-pr` invocations.

1. **`feedback_merge_independent`: `/merge` auto-chain allowed inside `/goal`.** The global rule "merge is a deliberate user-invoked command" still holds for standalone use. Inside `/goal`, `lib/goal-watch.sh` step 2c auto-dispatches `/merge` for any PR that transitions to `green`, subject to: the `uberdev_goal_should_automerge` provenance check (`UBERDEV_GOAL_ID` must be set — outside `/goal` it is not, so the auto-merge refuses); the per-PR attempt-counter cap (`_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=3`); and D17 — YELLOW/RED PRs are NEVER auto-merged.

2. **`feedback_brainstorm_no_gates`: the solvers run non-interactive (no gates).** `lib/goal-phase0.sh` exports `AUTO_MODE=1` and `SKIP_PERMISSIONS=1`, and the claim relay arms `lib/solve-launcher.sh` with `--turbo`, so every fleet solver runs unattended. Brainstorm / Q&A approval gates are skipped; quality comes from the fleet's parallel research + always-on reviewer pairs, not from human checkpoints.

3. **YELLOW handling: YELLOW PRs are NEVER merged — they are held for re-review.** Standalone `/merge` (with `--accept-critical-deferred`) can land a YELLOW PR; inside `/goal` this is forbidden. `_uberdev_goal_pr_state_machine_valid` returns non-zero for `yellow-held → merging` (D17); the only way out of `yellow-held` is `→ green` after a re-review clears the CRITICAL findings.

## Mandatory version bump before landing (issue #364)

The fleet solver prompt (`skills/solve-fleet/workflow.js`) forbids every solver from bumping the project version, and that is CORRECT: N solvers branching off one base all resolve the same next version, git auto-merges the identical change without a conflict, and the second landing silently eats the first bump (`project_uberdev_merge_version_collision`). But nothing downstream added the bump back — `_uberdev_goal_rebase_collision_chain` *renumbers* a bump that already exists, it never creates one — so `/goal` landed PRs that touched **zero** version surfaces.

It failed silently, which is why it survived: the two CI version-lock tests assert the surfaces AGREE WITH EACH OTHER, not that the version ADVANCED. An unbumped landing leaves every surface consistently at the old version, CI stays green, and the marketplace never serves the update.

`lib/goal-watch.sh` step 2c therefore calls `_uberdev_goal_ensure_version_bump <pr>` **immediately before** `_uberdev_goal_dispatch_merge <pr>`. That position is the whole contract:

- Step 2c acts on exactly ONE green PR per pass (strict lowest-first) and holds the `MERGING` sentinel until it lands (#289.2). It is the only strictly-serialized point in the run, so `origin/<base>` already carries the previous landing's bump — which is what makes sequential numbering correct here and colliding anywhere earlier.
- The helper resolves the next version from the **base branch's** manifest (never the PR branch's — a PR that branched before two releases landed sits *below* its base) plus the PR's conventional-commit type: `feat:` → minor, `!` / `BREAKING CHANGE:` → major, everything else → patch. It then runs `lib/bump-version.sh` in a throwaway **detached worktree** at the PR head (never the `/goal` checkout, whose index must stay pristine), replaces the CHANGELOG stub with an entry derived from the PR title + its issue refs, commits `chore(release): vX.Y.Z`, and pushes — never `--force`.
- **It FAILS CLOSED.** Any failure returns non-zero, `/merge` is NOT dispatched, the PR stays `green` for a later pass, and a `goal_merge_deferred` row with `reason=version_bump_failed` plus the exact `stage` lands in the audit stream. Merging unbumped IS the bug, so merging is never the fallback.
- A PR that already carries a strictly-greater version is a **no-op** (the collision chain renumbers it as before), and a repo with no `plugins/uberdev/.claude-plugin/plugin.json` has no version ratchet to enforce, so the step is skipped (audited, not silent) rather than blocking `/goal` on every other repo.

### Why the bump stays HERE, and the two gates that pay for it

Pushing a commit onto a reviewed PR head has two downstream consequences. Both are solved; neither is solved by moving the bump earlier. Bumping before `/review-pr` would buy a correct trust trail for free — and reopen the exact collision class the solver-side ban exists to prevent, because nothing before step 2c is serialized. The bump belongs at the serialized lane; the lane pays for it.

1. **The trust trail — answered in `/merge`, not here.** `/review-pr` anchors its `Reviewed-by: uberdev/review-pr@<sha>` trailer on the PR head; the release commit lands on top of it. Unpatched, `/merge` Phase 1.4 PATH_2 reads the trailer off the most-recent commit (now the release commit — `gate_fail trust_trail_trailer_missing`) and, even with the trailer, sees a non-empty cumulative diff over the trailer SHA (verdict `STALE` → `trust_trail_stale_sha`, which is explicitly excluded from the Step-1.4.5 auto-review recovery). PATH_1 is unreachable because `/review-pr` never calls `gh pr review --approve`. So PATH_2 sub-condition **(a.5)** resolves a `TRUST_HEAD` through `skills/merge-pipeline/lib/release-anchor.sh` and evaluates (b) and (c) against it. The helper reports `tolerated` — trust head = the release commit's parent — only when that commit is *provably inert with respect to reviewed code*: single parent, subject exactly `chore(release): vX.Y.Z`, parent not itself a release commit, non-empty diff confined to the seven version surfaces, manifest version strictly advancing to the subject's version, insertion-only release-shaped CHANGELOG, and — everywhere else — removed/added line **sequences** identical once SemVer tokens are normalised away. Two of the seven surfaces are executable test files, so neither the subject nor the path set is sufficient on its own, and the line comparison is order-sensitive (a multiset comparison would tolerate reordering test-file lines). Anything unproven falls back to `TRUST_HEAD = headRefOid`, i.e. the pre-#364 gate. The `trust-trail-evaluator` agent is untouched: it still requires an empty cumulative diff.
2. **The restarted checks — answered here.** The push re-triggers the PR's workflows, and `/merge` Step 1.4 reads *any* pending rollup entry as `gate_fail reason=ci_red` (its null-rollup settle probe is bounded at 3 × 10 s, against a CI critical path of minutes). Dispatching into that is a deterministic gate-fail that burns one of the three `_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS`; three passes of it and `uberdev_goal_should_automerge` starts returning 1, no `elif` arm is taken, the PR sits in `green` forever, `uberdev_goal_batch_all_terminal` never clears, and the run ends on the 4h `stuck_loop` breaker. So `_uberdev_goal_ensure_version_bump` returns a **three-way** status — `0` already bumped / no ratchet, `1` could not guarantee (fail closed), `2` **pushed just now, defer** — and step 2c additionally gates every dispatch on `_uberdev_goal_pr_checks_pending <pr>`. Step 2c branches on `-eq 2` and then on `-ne 0`, never on a literal `-eq 1`: the refusal arm is the catch-all, so a status this lane does not recognise withholds the dispatch instead of falling through to it. Both deferrals emit `goal_merge_deferred` (`reason=ci_restarted_by_version_bump` and `reason=ci_pending`) and neither burns a merge attempt, because the attempt counter lives inside `_uberdev_goal_dispatch_merge`. The CI-settle gate is *withholding only*: a `gh` failure or a repo with no checks configured returns rc 1 and falls through to `/merge`, which owns the hard CI gate. The 4h `stuck_loop` wall clock stays the backstop for a check that never completes.

**Backend inheritance (D15).** `lib/goal-phase0.sh` resolves the backend ONCE via `uberdev_dispatch_preflight` and freezes it for the run; it is never re-resolved per cycle. RFC 0015 §5: `auto` resolves to `workflow`, and `/goal`'s solvers are spawned by `skills/solve-fleet/workflow.js` inside the calling session — there is no demotion step and no detached default. A transient CLI probe flake mid-run must never silently swap backends and split one goal's solvers across incompatible dispatch mechanisms.

**Accepted loss (RFC 0015 §6 R-1).** `/goal`'s children no longer survive the session: if the session ends — closed, `/clear`, compact — every in-flight solver dies with it. `lib/goal-abort.sh` is the recovery (it releases the claims and reaps), and `/uberdev:goal --resume` picks a run back up from the `goal-active-id.txt` pointer.
