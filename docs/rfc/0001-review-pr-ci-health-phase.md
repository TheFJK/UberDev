# RFC 0001 — `/review-pr` Phase 3: CI Health

| Field            | Value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| **Status**       | Draft — dormant 2026-08-05 (#381), **RESTORED 2026-08-06 (#383)**; see the notes below |
| **Author**       | TheFJK                                                               |
| **Created**      | 2026-05-06                                                           |
| **Targets**      | `plugins/uberdev/commands/review-pr.md`, new agents, new SKILL phase |
| **Supersedes**   | —                                                                    |
| **Tracking**     | [Issue #76](https://github.com/TheFJK/UberDev/issues/76)             |
| **Tier**         | Medium (multi-agent, multi-file, contract-affecting)                 |

---

> **AMENDED 2026-08-05 (issue #381) — this RFC's phase has no transport.**
> `/review-pr` Phase 3 CI health is the capability specified here. #381 deleted
> the `codex` dispatch backend, the only transport with a provider arm for the
> `review_pr.ci.*` routed children; `auto` resolves `workflow` unconditionally,
> and `/review-pr` refuses `wezterm` and `background` for its own children
> because neither publishes a governed child result artifact. The **probe** half
> of this RFC still runs and still reports; the **classifier and fixer** halves
> cannot be dispatched, so a red probe halts at 6c.3 CLASSIFY with
> `subreason=ci_transport_unsupported` and `--no-ci-fix` is the supported mode.
> The status stays **Draft** rather than becoming Superseded: nothing replaces
> the design, and rebuilding Phase 3 Workflow-natively (RFC 0012 §3.1) restores
> it as written. See the sibling amendment in RFC 0002 for what this does and
> does not change about the GREEN predicate.

---

> **AMENDED 2026-08-06 (issue #383) — the capability is RESTORED, and this
> RFC's design is amended in exactly one respect.**
>
> Phase 3's five `review_pr.ci.*` children are dispatched by
> `skills/review-fleet/workflow.js` as four stages — `ci-classify`, `ci-fix`,
> `ci-conflicts`, `ci-defer` — like the other four review-fleet stages. Nothing
> in Phase 3 reaches the routed adapter, so the `ci_transport_unsupported`
> refusal is deleted rather than merely unreachable. `--no-ci-fix` survives as a
> legitimate opt-out and is now enforced in shell.
>
> **The one design change: the `--force-with-lease` lease is CONTROLLER-HELD,
> not agent-held.** This RFC (and `agents/ci-rebase-handler.md` as written)
> had `ci-rebase-handler` capture `EXPECTED_OLD_SHA` itself and perform the
> push. That is an LLM holding the lease: git then compares the remote against
> a value the agent chose, the flag still appears on the command line, and the
> safety property is gone while every downstream check still reads as verified.
> The agent is demoted from pusher to preparer — its tool list drops `git push`
> entirely — and `commands/review-pr.md` captures the lease at 6c.4 ROUTE
> (`rev-parse refs/remotes/origin/<pr_head_branch>`, never `origin/<base>`),
> stores it in a digest-pinned CI authority, and performs the single leased push
> itself. `validate-ci-mutation-outcome` compares the live remote tip against
> that pinned lease BEFORE the controller pushes, so a child that pushed anyway
> is caught rather than trusted.
>
> The `flock` lock this RFC specified is deleted with no replacement: under the
> demotion it would have to be held by the controller across a Workflow call,
> and every command fence is a fresh shell, so the descriptor dies with the
> fence and the lock is void. The lease is the cross-run guard and `git rebase`
> refuses a second in-progress rebase on its own.
>
> Status stays **Draft**.

---

## 1. Summary

Add a third phase to `/review-pr` — **Phase 3 — CI Health** — that runs after Phase 1 (review-fix) and Phase 2 (simplify-fix). Phase 3 probes live CI status on the post-Phase-2 HEAD, monitors pending runs, classifies red runs by failure cause, dispatches specialised fixer agents for code-bug and stale-base classes, and halts with `AskUserQuestion` for failure classes that no code change can resolve (billing, platform outage, secret rotation). The trust-trail signal (`uberdev-approved` label + `Reviewed-by:` trailer + audit JSON) is emitted only after Phase 3 returns green or skips on a green entry-state probe.

## 2. Motivation

### 2.1 Current gap

Today `/review-pr`'s Phase 1 + Phase 2 audit *code* (review findings, simplify lenses) but never look at *CI*. A green `/review-pr` trail can therefore co-exist with a red CI run on the same HEAD. Downstream, `/merge` Phase 1.4 unconditionally `gate_fail`s on `ci_red` (`SKILL.md:296`, `--bypass-protections` is a no-op since v0.17.0). The result: a PR shows the `uberdev-approved` label, the trailer, and the audit JSON — but `/merge` parks it as a surprise. The trust trail lies by omission.

### 2.2 Why fix it inside `/review-pr` and not `/merge`

`/merge`'s job is to *land approved code*. If `/merge` re-pushed fixes for red CI, two contracts break:

1. The `trust-trail-evaluator` agent would return `FORCE_PUSHED` on the new HEAD — the fix would invalidate the very trail it relies on.
2. The reviewer contract (every merged commit was signed off by Phase 1 + Phase 2) would become a lie — `/merge` would have authored unreviewed code.

`/review-pr` already owns the trust-trail emission and re-emits per push. Putting CI-health here lets the trail anchor on a HEAD that is genuinely *reviewed AND CI-green*. `/merge` stays trust-strict and unchanged.

### 2.3 Coherence win

After this RFC lands, a green `/review-pr` trail means **reviewed AND CI green AND base-current**. `/merge` becomes a near-trivial pickup: every PR with a fresh trail is mergeable.

## 3. Design

### 3.1 Phase ordering

```
Phase 1  Review fanout (post-impl-review) → code-fixer       [pushes commit(s)]
Phase 2  Simplify lenses (3-way fanout)   → code-fixer       [pushes 1 commit]
Phase 3  CI Health                                            [may push commit(s)]
Phase 4  Trust-signal emission (label + trailer + JSON)       [pushes anchor]
```

Phase 3 is positioned **after** Phase 2 because Phase 1 and Phase 2 push commits that change HEAD; the only CI state worth diagnosing is the one running on the post-Phase-2 HEAD.

### 3.2 Phase 3 step sequence

#### 3.2.1 Pre-step — wait for checks to register

Immediately after Phase 2's last push (or after Phase 1's last push if Phase 2 was skipped via `--no-simplify`), poll `gh pr checks <N> --json state,name --jq '. | length'` for up to **`CI_REGISTRATION_TIMEOUT_SECONDS`** (default 30) waiting for at least one check whose head SHA matches the local HEAD. Three outcomes:

- **≥ 1 check registered** → proceed to 3.2.2.
- **0 checks after timeout** → emit `ci_no_checks_configured` audit event, skip Phase 3 entirely, proceed to Phase 4 trust-signal emission. (Repos with no CI configured are valid and must not block trust signal emission.)
- **`gh` failure** → emit `ci_probe_unreachable` audit event, skip Phase 3, proceed to Phase 4. Do NOT halt the run on infrastructure flake.

#### 3.2.2 Status probe (bash, no agent)

Single `gh pr checks <N> --json state,bucket,name,detailsUrl --jq '...'` call. Three branches based on aggregated state ∈ `CI_STATUS_ENUM`:

| Aggregated state    | Branch    | Next step      |
| ------------------- | --------- | -------------- |
| All checks `SUCCESS`| **green** | Skip to Phase 4|
| Any check `IN_PROGRESS` / `QUEUED` / `PENDING` | **pending** | 3.2.3 monitor |
| Any check `FAILURE` / `CANCELLED` / `TIMED_OUT` / `ACTION_REQUIRED` | **red**   | 3.2.4 classify |

Audit: emit `ci_status_probe` with `data.state=<green|pending|red>`.

The fast-path **green → Phase 4** is the optimisation called out in the design conversation: when there's no fire, no firefighters.

#### 3.2.3 Monitor & wait

Use `gh pr checks <N> --watch --fail-fast` (built-in poll) with a hard cap of **`CI_MONITOR_TIMEOUT_SECONDS`** (default 1800 — 30 minutes). On timeout, emit `ci_monitor_timeout` audit event and treat as red entering 3.2.4 with `data.timeout=true` so the classifier knows logs may be partial.

After settle → re-enter 3.2.2 with the resolved state (one of green / red — pending is no longer possible).

Audit: `ci_pending_wait` with `data.duration_seconds=<elapsed>`, `data.outcome=<green|red|timeout>`.

#### 3.2.4 Classify (`ci-failure-classifier` agent)

New agent. Inputs:

- `pr_number`
- Output of `gh pr checks <N> --json state,name,detailsUrl,bucket`
- Output of `gh run view <id> --log-failed` for every failed check
- The PR's mergeable state (`gh pr view <N> --json mergeable,mergeStateStatus`) — used to detect class F (stale base) without needing log heuristics
- Optional `pr_body_excerpt`, `recent_runs_history` (last 5 runs of each failing check, used to detect flakiness — class D) wrapped in `<external-untrusted-input>` envelopes

Output (single verdict per PR):

```yaml
classification: <CI_FAILURE_CLASS_ENUM>     # see §4.2
evidence:
  - check_name: <string>
    excerpt: <string, ≤500 chars>
    rationale: <string>
recommended_action: <fix_code | rebase | rerun | halt_billing | halt_infra | halt_env_drift>
confidence: <high | medium | low>
```

Loop guard: if the classifier returns `low` confidence on the **same** classification two iterations in a row, force halt (loop guard, see §3.2.6).

Audit: `ci_classified` with `data.classification=<…>`, `data.confidence=<…>`.

#### 3.2.5 Route by classification

| Class                    | Action                                                                                                                                                                                                                                                |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. `code_bug`**        | Dispatch `ci-code-fixer` agent (3.2.5a). Apply real root-cause fix as `fix(ci): <root cause>` commit, push, re-enter 3.2.1 (post-push registration wait → status probe).                                                                              |
| **B. `billing_quota`**   | `AskUserQuestion`: show exact GH error + billing-page link. Never modify code. On user "skip" → emit no trust signal, exit Phase 3 with `data.outcome=halt_billing`. On `--turbo` (no human) → same skip behaviour, emit no trust signal.            |
| **C. `platform_outage`** | `AskUserQuestion`: present retry / wait / CI-config-change options. On skip / `--turbo` → emit no trust signal.                                                                                                                                       |
| **D. `flaky`**           | One-line stderr surface (`flaky-suspected: <test>, rerunning`), then `gh run rerun --failed`, monitor (3.2.3), re-enter 3.2.2. **Bounded at one rerun per classification iteration** — second flake on the same check → reclassify as A and dispatch fixer. |
| **E. `env_drift`**       | Sub-route by signal: lockfile-drift / generated-file-drift → dispatch `ci-code-fixer` (auto-fix). Secret rotation / expired credential → `AskUserQuestion`. The classifier's `evidence` field disambiguates.                                          |
| **F. `stale_base`**      | Dispatch `ci-rebase-handler` agent (3.2.5b). Re-enter 3.2.1.                                                                                                                                                                                          |

#### 3.2.5a `ci-code-fixer` agent

New agent. Distinct from existing `code-fixer` (which consumes review-finding YAML, not CI logs).

Inputs: failing-check name, failing log excerpt (via `<external-untrusted-input source="ci-log">`), source-tree access, the classifier's evidence list.

Contract:

1. Apply 5-Whys diagnosis (per existing `uberdev:systematic-debugging` skill) before any edit.
2. **Forbidden patterns** (refuse and exit `REFUSED` if the only available fix would require these): `--no-verify`, `git commit --amend` on pushed commits, deleting/skipping tests, swallowing errors (`catch { /* ignore */ }`), hardcoded values to mask the failure.
3. Apply edit, run the failing test/build *locally* before commit (`uberdev:verification-before-completion` skill).
4. Commit as `fix(ci): <one-line root cause summary>` (conventional-commit `fix:` so `merge-strategy-decider` reads it correctly).
5. Push (`git push origin <head-ref>`), return `status: APPLIED` with `commit_sha: <sha>`.

On `REFUSED` (forbidden-pattern would be needed) or repeated diagnosis failure → emit `ci_fix_refused` audit event with rationale, fall through to loop-guard exit (§3.2.6).

#### 3.2.5b `ci-rebase-handler` agent

New agent.

Inputs: PR number, integration branch (already resolved earlier in run).

Contract:

1. `gh pr checkout <N>` (or operate inside an existing checkout).
2. `git fetch origin <integration_branch>`.
3. `git rebase origin/<integration_branch>`.
4. **On clean rebase** → `git push --force-with-lease origin <head-ref>` (NEVER bare `--force` — global CLAUDE.md rule). Return `status: REBASED`, `commit_count_before=<N>`, `commit_count_after=<M>`.
5. **On conflict** → enumerate conflicted files, dispatch the existing `conflict-resolver` agent per file (already used by `/merge` Phase 3), apply textually-justified resolutions OR refuse.
   - All resolved → `git rebase --continue` → push as in step 4.
   - Any refused → `git rebase --abort`, return `status: REFUSED` with the refusal rationale; emit `ci_rebase_refused` audit event; loop-guard handles exit.
6. **On force-push protection error** (e.g. branch is a fork's head ref the agent can't push to) → return `status: REFUSED_PROTECTED`, emit `ci_rebase_refused`, loop-guard handles exit.

Audit: `ci_rebase_applied` with `data.status=<REBASED|REFUSED|REFUSED_PROTECTED>`, `data.conflict_count=<N>`.

#### 3.2.6 Loop guard

Each `(3.2.1 → 3.2.5 → push → 3.2.1)` cycle increments an in-process counter. Hard cap **`CI_FIX_LOOP_CAP`** = 3.

On exhaustion:

- Emit `ci_loop_capped` audit event with `data.last_classification=<…>`, `data.iteration_count=3`.
- `AskUserQuestion`: surface a summary of the three iterations, ask whether to continue (manual unblock) or park the PR.
- On `--turbo` (no human) → emit no trust signal, exit Phase 3 with `data.outcome=loop_capped`.

The cap protects against fix-fail-fix oscillation when the classifier is wrong about root cause.

### 3.3 Trust-signal emission (Phase 4)

Trust signal emits **iff** Phase 3 outcome ∈ {`green` (entry probe), `green_after_fix`, `skipped_no_checks`}. All `halt_*` and `loop_capped` outcomes suppress trust-signal emission and `/review-pr` exits with code 1.

This is a contract change versus today (where Phase 2's `ran/APPROVE` or `skipped` is sufficient for trust-signal). Existing exit-code semantics preserved for back-compat:

- Exit 0 — Phase 1 APPROVE + Phase 2 (ran/APPROVE | skipped) + Phase 3 (green | green_after_fix | skipped_no_checks)
- Exit 1 — Phase 1 not APPROVE, OR Phase 3 halt_*, OR Phase 3 loop_capped
- Exit 2 — Phase 2 blocked (unchanged)

### 3.4 `--turbo` mode (unattended)

`AskUserQuestion` calls in classes B / C / E-secret / loop-cap have no human to answer in turbo mode. Behaviour:

- The runtime mediates: in interactive mode, asks; in turbo mode, treats the question as "skip / wait for human" automatically.
- Phase 3 emits no trust signal on `halt_*` / `loop_capped` outcomes. The PR ends with red CI, no trust trail. `/merge` will park it on `ci_red` later. The human deals with billing / infra / secret rotation out-of-band.
- Phase 3 still attempts auto-fix for classes A / D / E-lockfile / F in turbo mode — those are non-interactive paths.

### 3.5 `--no-ci-fix` flag (NEW)

A new opt-out flag for fast iterative review loops. Parsing rules mirror existing `--no-simplify`. When present:

- Phase 3 reduces to **probe-only**: 3.2.1 + 3.2.2 only. Green → Phase 4. Pending / red → emit `ci_probe_only_skipped` audit event with `data.state=<pending|red>`, exit Phase 3 with no trust signal (red CI still must not produce trust signal).
- `--no-simplify --no-ci-fix` together gives back the old "fast Phase-1-only" loop.

The flag is documented in `commands/review-pr.md`'s arg table.

## 4. New agents, constants, and enums

### 4.1 New agents

- `ci-failure-classifier` — multi-class classifier; reads logs, emits structured verdict.
- `ci-code-fixer` — root-cause fix for class A / E-lockfile.
- `ci-rebase-handler` — rebase-on-base + conflict delegation for class F.

(Reuses existing `conflict-resolver` agent for per-file conflict resolution during rebase.)

### 4.2 New constants

| Constant                            | Value / Type                                                                          | Rationale                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `CI_REGISTRATION_TIMEOUT_SECONDS`   | int, default 30                                                                       | Seconds to wait for first check to register post-push. |
| `CI_MONITOR_TIMEOUT_SECONDS`        | int, default 1800                                                                     | Hard cap for `gh pr checks --watch`.                   |
| `CI_FIX_LOOP_CAP`                   | int, hard-coded 3 (per design call — not user-configurable; see §6)                   | Bound on (probe → classify → fix → push) cycles.       |
| `CI_STATUS_ENUM`                    | `green`, `pending`, `red`                                                             | Aggregated check state output of 3.2.2.                |
| `CI_FAILURE_CLASS_ENUM`             | `code_bug`, `billing_quota`, `platform_outage`, `flaky`, `env_drift`, `stale_base`    | Classifier output domain.                              |
| `CI_OUTCOME_ENUM`                   | `green`, `green_after_fix`, `skipped_no_checks`, `halt_billing`, `halt_infra`, `halt_env_drift`, `loop_capped`, `probe_only_skipped` | Phase 3 exit state. Trust-signal predicate ∈ first 3.  |

### 4.3 New `AUDIT_EVENT_ENUM` members

Add to existing `AUDIT_EVENT_ENUM`:

- `ci_status_probe` — `data.state ∈ CI_STATUS_ENUM`
- `ci_pending_wait` — `data.duration_seconds`, `data.outcome ∈ {green, red, timeout}`
- `ci_classified` — `data.classification ∈ CI_FAILURE_CLASS_ENUM`, `data.confidence ∈ {high, medium, low}`
- `ci_fix_applied` — `data.commit_sha`, `data.classification`
- `ci_fix_refused` — `data.classification`, `data.rationale`
- `ci_rebase_applied` — `data.status ∈ {REBASED, REFUSED, REFUSED_PROTECTED}`, `data.conflict_count`
- `ci_rebase_refused` — `data.rationale`
- `ci_no_checks_configured` — (no data fields)
- `ci_probe_unreachable` — `data.gh_stderr`
- `ci_monitor_timeout` — `data.elapsed_seconds`
- `ci_loop_capped` — `data.last_classification`, `data.iteration_count`
- `ci_probe_only_skipped` — `data.state ∈ {pending, red}` (only emitted under `--no-ci-fix`)

## 5. Failure modes & rollback

| Failure                                | Phase 3 behaviour                                                                                                            | Trust signal? |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------- |
| `gh` outage during 3.2.1               | Emit `ci_probe_unreachable`, skip Phase 3, proceed to Phase 4.                                                               | YES (but we lied about CI being green — see §5.1) |
| Classifier returns malformed YAML      | Emit `ci_classified` with `data.confidence=low`, `data.classification=unknown`. Treat as loop-guard increment. After 3 → halt. | NO            |
| Fixer agent crash mid-edit             | No commit lands (atomic via git). Loop counter increments. Re-enter from 3.2.1.                                              | NO if cap hit |
| Rebase agent leaves repo mid-rebase    | Wrapper script enforces `git rebase --abort` on agent exit / timeout. Working tree restored.                                 | NO if cap hit |
| User `Ctrl+C` during 3.2.3 monitor     | Trap → emit `ci_monitor_aborted` (NEW audit member) → exit 1, no trust signal.                                                | NO            |

### 5.1 The `gh` outage carve-out

Skipping Phase 3 on `ci_probe_unreachable` lets `/review-pr` complete and emit a trust signal even though we don't actually know CI status. This is a **deliberate availability/correctness trade**: if `gh` is down, blocking the trust trail blocks every PR in the queue. Mitigation:

- Audit-log the skip (`ci_probe_unreachable` is never silent).
- `/merge` Phase 1.4 still runs its own CI check via `pr_view_projection`, so the lie is caught at merge time, not at deploy time.
- This is the only Phase-3 path that emits a trust signal without confirming green CI, and it requires `gh` to actively fail.

## 6. Open questions resolved

The two open questions from the design conversation are closed in this RFC:

| Question                                       | Resolution                                                                                                                                    |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **Class D (flaky) auto-rerun: silent or surface?** | **Surface + auto-rerun once.** One-line stderr (`flaky-suspected: <test>, rerunning`) so flake rate stays visible; second flake → reclassify as A. |
| **Loop cap: configurable or hard-coded?**      | **Hard-coded at 3.** Configurability adds knob bloat for unclear value; revisit if real workloads ask for it.                                 |

## 7. Alternatives considered

### 7.1 Phase 0 (before Phase 1) instead of Phase 3 (after Phase 2)

Rejected. Phase 1 and Phase 2 push commits that change HEAD; CI on the pre-Phase-1 HEAD is irrelevant. Probing before Phase 1 means re-probing after, doubling work.

### 7.2 Single monolithic `ci-doctor` agent instead of split classifier + fixer + rebase-handler

Rejected. Classification is a *reading* task (parse logs, infer cause); fixing is a *writing* task (root-cause edits + push). Splitting makes each agent's contract small enough to test in isolation, mirrors the existing `merge-strategy-decider` + `conflict-resolver` split in `/merge`, and lets the rebase handler reuse `conflict-resolver` without dragging classification logic in.

### 7.3 Bolt CI-fix into `/merge` instead of `/review-pr`

Rejected. `/merge`-authored fixes invalidate the trust trail (the new commit returns `FORCE_PUSHED` from `trust-trail-evaluator`) and break the reviewer contract (commits would land unreviewed). `/review-pr` already owns trust-trail emission and naturally re-emits per push.

### 7.4 Skip Phase 3 entirely, keep `/merge` strict and let the human fix red CI manually

Rejected. The user pays the cost every time CI flakes or a stale base trips a green PR. Auto-fix for classes A / D / F covers the most common cases; only B / C / E-secret need human attention, and those need it regardless.

## 8. Migration / rollout

1. **Land RFC** (this doc) on `main` as a non-versioned doc commit.
2. **Implement Phase 3** on a feature branch:
   - New agent files: `agents/ci-failure-classifier.md`, `agents/ci-code-fixer.md`, `agents/ci-rebase-handler.md`.
   - Edit `commands/review-pr.md` to document Phase 3 + `--no-ci-fix`.
   - Add Phase 3 prose to `skills/_shared` or a new `skills/ci-health/SKILL.md` (decision deferred to plan-writer in `/turbo` flow).
   - Extend `AUDIT_EVENT_ENUM` in the relevant SKILL.md constants tables.
   - Add tests under `tests/review-pr.test.sh` covering: green-skip, pending → green, pending → red → fix → green, all 6 classification paths, loop-cap exhaustion, `--no-ci-fix` probe-only, `--turbo` halt classes.
3. **Bump version** per project CLAUDE.md MANDATORY rule (minor bump — `feat:` adding Phase 3): 0.20.3 → 0.21.0. Update all six locations (`plugin.json`, `marketplace.json`, README badge, CHANGELOG, git tag, GH release).
4. **Run `/uberdev:review-pr`** on the implementation PR per project rule.

## 9. References

- `plugins/uberdev/skills/merge-pipeline/SKILL.md:296` — current `ci_red` gate in `/merge`.
- `plugins/uberdev/commands/review-pr.md` — current `/review-pr` Phase 1 / Phase 2 structure.
- `plugins/uberdev/skills/post-impl-review/` — pattern for multi-agent fanout reused by Phase 3 classifier.
- `plugins/uberdev/agents/conflict-resolver.md` — reused by `ci-rebase-handler` for per-file conflict resolution.
- `plugins/uberdev/agents/trust-trail-evaluator.md` — confirms why `/merge` cannot auto-fix CI (`FORCE_PUSHED` verdict).
- Global CLAUDE.md — TDD discipline, 5-Whys, anti-band-aid rules, `--force-with-lease` requirement.
- Project CLAUDE.md — version-bump-everywhere mandate for the implementation PR.
