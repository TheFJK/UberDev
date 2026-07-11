# RFC 0013 — GPT-5.6 Adaptive Execution Architecture

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-07-09 |
| **Tier** | Large, multi-release optimization program |
| **Target ver** | 0.40.0–0.42.0: routing foundation → agent behavior → workflow efficiency |
| **Related** | RFC 0012 (`docs/rfc/0012-ultracode-workflow-orchestration.md`), RFC 0004 (`docs/rfc/0004-cross-platform-dispatch-backends.md`), Codex port v0.39.0–v0.39.1 |

---

## 1. Decision

UberDev will use **end-to-end adaptive execution** for detached leads and delegated agents. A deterministic policy will select the least expensive GPT-5.6 route that satisfies the task's complexity and risk floor. The policy will control model, reasoning effort, sandbox, and service tier as separate values and will record every decision.

The staged program keeps the current shell/skill architecture while adding a central policy, native Codex agent profiles, prompt and contract cleanup, quality-neutral workflow gates, and usage telemetry across releases 0.40.0 through 0.42.0. It does **not** add another LLM call to choose a model.

The user's ambient Codex setting may remain `gpt-5.6-sol` with `ultra`; under adaptive mode, routine UberDev children will still use their resolved lower-cost routes. An explicit UberDev `--route=sol-ultra` is a forced run policy and takes precedence over adaptive child routes; the run fails before any child whose forced route cannot be enforced.

This document uses **MUST**, **SHOULD**, and **MAY** normatively.

### 1.1 Why this direction

The audit found five structural causes of unnecessary cost and latency:

1. The Codex backend currently passes neither `-m` nor `model_reasoning_effort`, so detached `/solve` and `/turbo` runs inherit global config even when `--effort` was parsed.
2. Forty-one of forty-two installed agents omit model and effort. With a Sol-Ultra parent, scouts, classifiers, monitors, and relays also run on Sol Ultra.
3. `/solve` advertises auto-triage but assigns unspecified issues to `medium`; a routine issue can therefore enter a roughly thirteen-agent design path before implementation.
4. The generated Codex prompts are synchronized but still contain about 47,000 body words, Claude-specific tool language, dropped-whitelist claims, an impossible child-to-grandchild planning flow, and incompatible reviewer output contracts.
5. Several workflows repeat broad fleets or run provably empty work. Default Testers is about 32 model calls, Ubersimplify about 29, and Uberthink about 83–289 before surrounding controller work.

Current OpenAI guidance supports the chosen direction: GPT-5.6 prompts should be shorter and less repetitive; Terra is suitable for read-heavy parallel workers; model and `model_reasoning_effort` can be set per custom agent; and Ultra should be used where maximum reasoning and proactive delegation justify its additional usage. See [GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model) and [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

## 2. Goals

The optimization program MUST:

- Resolve model, reasoning effort, service tier, and sandbox before every adaptive or forced detached Codex lead and delegated role; in explicit inherit mode, resolve an ambient execution policy and leave concrete model/effort fields `null` when the provider cannot report them.
- Preserve explicit Sol-Ultra access while preventing ambient Ultra from cascading into routine workers.
- Make `/solve` tier selection real and deterministic rather than defaulting all unspecified work to `medium`.
- Replace obsolete Claude-to-Codex model inheritance with an explicit Codex role policy.
- Reduce prompt weight and translate Codex artifacts to native capability language.
- Remove broken nested delegation and unify reviewer contracts.
- Eliminate deterministic, duplicate, empty, and unnecessary repeat model calls where behavior is provably equivalent.
- Preserve one comprehensive final quality gate for review-bearing workflows.
- Enforce actual live concurrency rather than dispatch burst size.
- Record route, usage, latency, fallback, cache, and terminal outcome without logging sensitive content.
- Preserve Claude, WezTerm, and background backend behavior unless a change is explicitly covered by the provider adapter and parity tests.

## 3. Non-goals

The optimization program MUST NOT:

- Implement the remaining RFC 0012 Workflow migrations.
- Build a general DAG scheduler, distributed queue, or replacement agent runtime.
- Raise `agents.max_depth` to preserve nested delegation.
- Depend on GPT-5.6 Pro mode, direct Responses API integration, or undocumented Codex APIs.
- Enable Fast service by default; latency tier is independent from model quality and consumes more usage.
- Cache non-identical reasoning inputs or any side-effecting operation.
- Weaken trust-trail, claim, permission, security, merge, or final-review safety semantics.
- Migrate unrelated Claude model identifiers as part of the Codex optimization.

## 4. Terminology

- **Task tier:** UberDev workflow depth: `trivial`, `small`, `medium`, or `large`.
- **Logical route:** Vendor-neutral capability class chosen by UberDev.
- **Provider route:** Concrete model, effort, service tier, and sandbox resolved for Codex or Claude.
- **Ambient selection:** Model/effort inherited from the parent Codex session. It is not an explicit UberDev route pin.
- **Forced route:** A CLI or environment override that the user intentionally applies to an UberDev run.
- **Risk floor:** Minimum logical route permitted for a role or risk signal.
- **Quality gate:** Required validation whose failure blocks success, regardless of efficiency gains.

Model choice, reasoning effort, service tier, and sandbox MUST remain independent fields. `ultra` is a reasoning/delegation level, not a model slug; `gpt-5.6-sol` is the frontier model.

## 5. Architecture

### 5.1 Components

The implementation will add five bounded components:

1. **Policy catalog** — a single versioned data file containing logical routes, Codex mappings, role defaults, risk floors, and fallback order.
2. **Deterministic resolver** — accepts workflow, role, tier, risk signals, backend, explicit overrides, and config; returns a complete route decision.
3. **Provider adapters** — translate a logical route into backend-native launch arguments or custom-agent configuration.
4. **Run manifest** — append-only JSONL events for routing, execution, usage, fallback, budgets, and quality gates.
5. **Generated-agent pipeline** — composes provider-native TOML and Markdown from canonical sources and fails CI on drift.

The policy catalog MUST be the single source of truth. Shell launchers, the agent converter, skills, documentation tests, and installers MUST consume or validate against it rather than duplicating model tables.

### 5.2 Resolver input and output

The resolver MUST accept:

```text
workflow, phase, role, task_tier, risk_signals, backend,
explicit_route, explicit_model, explicit_effort, explicit_service_tier,
project_config, environment, parent_run
```

It MUST return a machine-readable decision:

```json
{
  "schema_version": 1,
  "logical_route": "standard",
  "backend": "codex",
  "model": "gpt-5.6-terra",
  "reasoning_effort": "medium",
  "service_tier": "default",
  "sandbox": "read-only",
  "route_source": "role-policy",
  "field_sources": {
    "model": "route",
    "reasoning_effort": "route",
    "service_tier": "default",
    "sandbox": "role-policy"
  },
  "forced": false,
  "risk_signals": [],
  "minimum_route": "standard",
  "fallback_chain": [],
  "reason_codes": ["read-heavy-role"]
}
```

The resolver MUST be pure and testable with injected configuration and model-catalog fixtures. It MUST NOT call an LLM.

### 5.3 Precedence

Routing mode resolves first: concrete/exact CLI pin → CLI `--routing-mode` → concrete/exact environment pin → `UBERDEV_MODEL_ROUTING_MODE` → project config → release default. A concrete route or complete exact pair sets mode to `forced`. At the same source, a mode selector is mutually exclusive with a concrete route or exact fields; a higher-precedence forced selection shadows a lower-precedence mode and records that fact. A forced parent run remains immutable for descendants.

Model and reasoning fields resolve in this order:

1. Exact CLI field: `--model` or `--effort`.
2. CLI concrete logical route: `--route` supplies model and effort together.
3. Forced parent run route, when an ancestor explicitly requested propagation.
4. Exact environment field: `UBERDEV_MODEL` or `UBERDEV_REASONING_EFFORT`.
5. Environment logical route: `UBERDEV_ROUTE`.
6. Project role override.
7. Project workflow override.
8. Adaptive task-tier, role, and risk policy.
9. Ambient inheritance only when the selected policy is `inherit`.

At the same source level, a concrete logical route is mutually exclusive with exact model/effort fields. For example, `--route=sol-ultra --effort=low` is an error. `adaptive` and `inherit` are routing modes selected with `--routing-mode`; they are not valid `--route` values and do not claim to supply a model/effort pair. An explicit `--routing-mode` is mutually exclusive with `--route` or exact model/effort overrides. A higher-precedence route may shadow lower-precedence exact environment fields, and the resolver records the ignored source. Exact model plus exact effort is allowed, but the final pair MUST validate. `--route=sol-ultra` normalizes to logical `ultra`; natural-language text inside an issue body MUST NOT trigger it.

Once an explicit CLI or environment route has been normalized as a forced run route, that normalized route is authoritative for every descendant. Environment variables inherited by a child are not treated as a new override. Model/effort flags emitted by the provider adapter are the carrier for the already-resolved route, not a new precedence source. A descendant that attempts to introduce a conflicting explicit override is an internal `route_conflict` error.

Every explicit CLI/environment concrete route, and every complete exact model/effort pair, becomes a forced run-tree constraint after validation. The final provider pair MUST match a built-in policy-catalog entry or a project extension that declares a logical capability rank and compatible efforts; an otherwise supported but unranked pair fails with `unranked_exact_pair`. The effective logical capability MUST satisfy the lead and judgment-bearing descendant risk floors; a lower explicit route fails with `route_below_risk_floor` rather than weakening the safety policy. Sol Ultra receives a dedicated contract in Section 5.6 because it additionally exercises the maximum supported reasoning/delegation route.

Service tier resolves independently: CLI `--service-tier`/`--fast` → `UBERDEV_SERVICE_TIER` → project config → `default`. It never changes the logical route.

Sandbox and permissions use a restrictive ceiling, not ordinary last-writer precedence. The parent runtime policy is the maximum authority. A role default, workflow override, or CLI sandbox may make it more restrictive but MUST NOT widen it. Route selection and model fallback never alter sandbox or approval policy.

Provider-compatible fallback is a post-resolution state transition, not a precedence level. It runs only after the selected automatic model/effort pair is proven unavailable and follows Section 8.2.

### 5.4 Codex route matrix

| Logical route | CLI aliases | Model | Effort | Typical work |
|---|---|---|---|---|
| `economy` | `luna` | `gpt-5.6-luna` | `low` | Classification, extraction, compact normalization, unavoidable semantic relays |
| `standard` | `terra` | `gpt-5.6-terra` | `medium` | Exploration, bounded scans, routine parallel workers, trivial/small leads |
| `quality` | `sol` | `gpt-5.6-sol` | `medium` | Normal implementation, synthesis, and medium leads |
| `deep` | `sol-high` | `gpt-5.6-sol` | `high` | Review, security, planning, difficult fixes |
| `frontier` | `sol-max` | `gpt-5.6-sol` | `max` | Largest quality-first single-agent judgments and large leads |
| `ultra` | `sol-ultra` | `gpt-5.6-sol` | `ultra` | Explicit forced runs or large high-risk work benefiting from maximum reasoning/delegation |

The implementation MUST use explicit model slugs rather than the moving `gpt-5.6` alias. `service_tier` defaults to `default` for every logical route. `--fast` is only an alias for explicit `--service-tier=fast`; Codex maps that native config value to the provider request's priority tier. `--fast` MUST NOT change model or effort. `flex` MAY be selected explicitly where the active provider/catalog supports it, but it is never an availability fallback.

### 5.5 Top-level route policy

| Task tier | Default lead route | High-risk lead route |
|---|---|---|
| `trivial` | `standard` | `deep` |
| `small` | `standard` | `deep` |
| `medium` | `quality` | `frontier` |
| `large` | `frontier` | `ultra` |

`/turbo` MUST use the same route as `/solve`. Unattended execution is not itself a reason to buy more reasoning. A user MAY force any supported route at or above the effective risk floor; the resolver records the override and still preserves sandbox and permission policy.

High-risk signals include security, authentication, authorization, cryptography, concurrency, data loss, schema migration, release infrastructure, force-push behavior, public API compatibility, and destructive operations. High-risk roles MUST have a minimum route of `deep`.

Risk propagates at the scope where judgment is performed. A run-level high-risk signal sets the lead floor; a security- or data-bearing subtask sets the floor for the descendant that analyzes or modifies it. Pure bookkeeping, transport, and monitor roles retain their role floor unless they make a risk judgment themselves. Tests and telemetry MUST distinguish `run_risk` from `subtask_risk` so a security issue cannot down-route its security reviewer while also avoiding an unnecessary escalation of a terminal-status monitor.

### 5.6 Forced Sol Ultra

`--route=sol-ultra` MUST set the detached lead and every LLM descendant in the same UberDev run tree to `gpt-5.6-sol` + `ultra`. The scope includes research, design, implementation, review, repair, monitor, and semantic-relay calls; deterministic program steps are not model invocations and are unaffected. It MUST NOT widen sandbox permissions or enable Fast service.

Role TOMLs enforce adaptive defaults; they are not the forced-route mechanism. If the active native subagent surface cannot override a role TOML for a forced child route, the provider adapter MUST use an explicit supported carrier (`codex exec` with `-m` and `-c model_reasoning_effort=...`) or fail with `route_unenforceable`. The implementation MUST NOT generate a role-by-route Cartesian set of agent files. It MUST NOT report that Sol Ultra propagated when the child merely inherited an unknown route.

Ambient Sol Ultra is different: adaptive child role policies override it by default. This is the mechanism that prevents a high-end parent from making every scout and monitor equally expensive.

## 6. Real `/solve` auto-triage

The launcher MUST stop assigning `medium` before evaluating its own signals. Classification runs before tier floor/ceiling clamps:

1. **Large:** any label in `epic`, `needs-discussion`, `architectural`, `infrastructure`, or cross-cutting `refactor`; or at least three distinct named files/modules; or a high-risk signal spanning more than one component.
2. **Trivial:** not large/high-risk; no stack trace; at most one named file; body under 300 characters after Markdown stripping; and either a trivial label (`typo`, `docs`, `documentation`, `chore`, `good-first-issue`) or a title match (`typo`, `rename`, `bump`, `version`, `readme`).
3. **Small:** not large/high-risk; at most two named files; body under 4,000 characters; and at least one concrete reproduction/error signal such as a stack trace, scoped `bug` label, or explicit reproduce/expected/actual/error markers.
4. **Medium:** everything else.

The resolver then applies `solve_tier_floor` and `solve_tier_ceiling`. Every decision records matched rules, raw tier, clamped tier, and source. Conflicting signals resolve toward the higher tier.

## 7. Agent role policy

### 7.1 Economy, read-only

`triage-scout`, `ci-failure-classifier`, `merge-strategy-decider`, `testers-monitor-primary`, and `testers-monitor-devils-advocate`.

### 7.2 Standard, read-only

`codebase-scout`, all `research-*` agents except `research-security`, `issue-similarity-analyzer`, `comment-analyzer`, and all tester personas except `testers-adversarial-security`.

### 7.3 Quality

Read-only: `code-simplifier`, `uberthink-frame`, `uberthink-generator`, and `uberthink-moderator`.

Workspace-write: `spec-reviser`.

### 7.4 Deep

Read-only: `code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, `pr-test-analyzer`, `research-security`, `testers-adversarial-security`, `spec-reviewer`, `plan-reviewer`, `uberthink-synthesizer`, and `uberthink-falsifier`.

Workspace-write: `spec-writer`, `plan-writer`, `code-fixer`, `ci-code-fixer`, and `conflict-resolver`.

### 7.5 Frontier

Read-only: `uberthink-arbiter` and the dedicated escalation/arbitration role.

No role MAY default to `ultra` or `danger-full-access`. Route overrides never widen sandbox.

Every role MUST declare `delegation_mode: leaf | orchestrator` in the policy catalog. Every bundled custom-agent role in this RFC is a leaf: its profile MUST disable multi-agent tools and set maximum spawn depth to zero, and detached launches MUST pass the equivalent `features.multi_agent=false` and `agents.max_depth=0` overrides. The root host orchestrator retains `agents.max_depth=1`. Installation and CI probes MUST prove every custom agent, including `plan-writer`, cannot spawn a child; a prompt-only “do not delegate” sentence is not sufficient enforcement. Adding a future custom-agent orchestrator requires a spec amendment and an enforceable depth design.

## 8. Provider compatibility and fallback

### 8.1 Adaptive and forced Codex launch shape

Adaptive and forced detached Codex runs MUST pass the resolved values explicitly:

```text
codex --ask-for-approval never exec
  --sandbox <resolved-sandbox>
  -m <resolved-model>
  -c model_reasoning_effort="<resolved-effort>"
  -c service_tier="<resolved-service-tier>"
  --json
  -o <result-file>
  <prompt>
```

Custom agent TOMLs MUST contain role-default `model`, `model_reasoning_effort`, and `sandbox_mode`. The converter MUST stop deriving Codex routes from legacy Claude `inherit`/`haiku` frontmatter.

Those pinned TOMLs are adaptive profiles, not the `inherit` rollback carrier. When `model_routing.mode: inherit` is effective, bundled workflows MUST bypass pinned native profiles and launch the canonical role prompt through an unpinned provider-adapter path that omits model and reasoning overrides. Tests MUST prove inherit mode observes the ambient selection and never accidentally selects an adaptive role pin. Manually invoking an installed adaptive custom agent remains an explicit use of that role profile and is outside the workflow rollback switch.

### 8.2 Catalog validation

The adapter SHOULD validate against `codex debug models` when available and MUST support an injected catalog fixture in tests. The installer MUST validate generated TOML and confirm that redacted Codex diagnostics report a valid configuration before reporting success; unrelated optional MCP, connectivity, update, or terminal warnings do not fail installation.

Fallback rules:

- Explicit model/effort/route pins fail loudly; they never silently downgrade.
- Automatic routes may step down `ultra → frontier → deep → quality → standard → economy` only to a compatible combination and never below the role/risk floor. If no explicit provider route remains at or above the floor, dispatch fails with `route_unavailable`; adaptive mode never falls through to unknown inheritance.
- Authentication, permission, malformed prompt, sandbox, and tool failures are not model-availability failures and MUST NOT trigger model fallback.
- Every fallback records rejected model/effort, error class, selected fallback, and source.
- In adaptive Codex mode, if the current tool surface cannot honor a custom agent profile, the run MUST use the explicit provider adapter or fail before dispatch. `route_degraded=inherit` is permitted only when the user selected `model_routing.mode: inherit`. A run MUST NOT claim a cheaper route was used without evidence.

### 8.3 Claude compatibility

When `--route` is absent, Claude-backed dispatch initially preserves its current model and `--effort` behavior. The logical resolver and telemetry are backend-neutral, but release 0.40.0 does not perform an unrelated Claude model migration. Provider parity tests MUST prove the Codex change does not leak Codex flags into Claude, WezTerm, or background paths.

## 9. GPT-5.6-native prompt contract

Every generated Codex agent MUST have:

1. A routing description no longer than 240 characters and without dialogue examples.
2. One job, explicit exclusions, typed inputs, and an input trust classification.
3. Native Codex capability language; no Claude tool names or claims about dropped tool whitelists.
4. A bounded path/diff/action scope and explicit stopping conditions.
5. `completed`, `blocked`, and `refused` terminal states.
6. Missing-input and missing-tool behavior.
7. One exact machine-parseable output contract as the final block.
8. `Do not delegate` unless the role is explicitly designated as an orchestrator.

Generated developer instructions SHOULD stay under 700 words. An agent may exceed 700 words only with a documented test/eval justification and a hard ceiling of 1,000 words. Total generated agent-body words MUST fall at least 40% from the audited baseline before adaptive routing becomes the default.

The source prompts SHOULD use platform-neutral verbs. The Codex converter MUST translate unavoidable provider-specific capability names and decode literal newline escapes in descriptions. The Codex skill porter MUST emit native dispatch guidance rather than leaving bare `Task()` calls for the model to reinterpret.

Deterministic validation, sorting, hashing, rate limiting, retries, Git operations, GitHub writes, and ranking arithmetic belong in tested code rather than model prompts.

## 10. Correctness repairs to agent orchestration

### 10.1 Flatten planning

`plan-writer` MUST stop spawning grandchildren. `agents.max_depth` stays at its documented default.

The root orchestrator dispatches dependency-map, test-map, and implementation-risk research as direct children, then passes their artifact paths to `plan-writer`. `plan-writer` only synthesizes the implementation plan.

### 10.2 Canonical reviewer contract

The duplicated sixth `code-reviewer` dispatch MUST be removed. The comprehensive post-implementation fleet consists of five distinct reviewers: correctness, silent failures, type design, comments/documentation, and test adequacy.

Every reviewer emits the same JSON contract:

```json
{
  "schema_version": 1,
  "reviewer_id": "string",
  "status": "completed|blocked|refused",
  "verdict": "approve|revisions_required|reject",
  "findings": [{
    "severity": "blocker|major|suggestion",
    "category": "string",
    "location": {"path": "string", "line": 1},
    "summary": "string",
    "detail": "string",
    "confidence": "low|medium|high"
  }]
}
```

A shared schema validator MUST reject malformed output. One format-repair retry is allowed. A required blocked/unparseable reviewer prevents a green final trust trail.

### 10.3 Deterministic replacements

Release 0.41.0 MUST extract deterministic work from three oversized agents:

- `findings-to-issues`: validation, fingerprints, severity routing, duplicate checks, rate limiting, secret scanning, capped GitHub writes, retry classification, and output formatting become a tested program. A bounded semantic summarizer MAY remain only where deterministic equivalence is impossible.
- `trust-trail-evaluator`: audit JSON, ancestry, tree diff, log diff, and PR corroborator evaluation become deterministic.
- `ci-rebase-handler`: explicit-SHA lease checks and safe rebase/push become a lock-protected script; conflicts may still route to `conflict-resolver`.

Removed agent work MUST no longer count as model invocations. External writes retain existing safety and idempotency gates.

### 10.4 Run-tree callsite enforcement

Every governed provider edge MUST construct manifest-valid inputs through the
shared child-input runtime and MUST reach the immutable handoff and routed
dispatch boundaries. This property is proven by execution, not by attempting
to parse Markdown-embedded shell.

When an explicit test-only mode is enabled, the child runtime writes correlated
JSONL receipts after successful input construction, handoff creation, and
routed dispatch entry. Receipts contain only schema version, event type,
test-declared canonical source, edge ID, instance ID where applicable, and a
SHA-256 digest of canonicalized inputs. They MUST NOT contain prompts, source
text, issue bodies, paths supplied as model inputs, credentials, or other
sensitive payload content. The receipt file MUST be a caller-owned regular file
inside a private test directory; symlinks, unsafe ownership, and malformed
events fail closed. Production execution does not emit these test receipts.

The receipt validator MUST require an exact three-event chain for all 40
source-owned provider edges:

```text
build(source, edge, inputs_sha256)
  -> handoff(source, edge, instance, inputs_sha256)
  -> dispatch(source, edge, instance, inputs_sha256)
```

Multiple complete chains are permitted for bounded retries and revisions. An
unknown edge, missing event, digest mismatch, conflicting instance, or edge
outside the typed source fixture fails validation. Source-specific executable
harnesses MUST invoke the real production callsite and runtime wrappers; a
test-authored direct builder call is not reachability evidence.

Static enforcement remains responsible only for deterministic declarations:
exactly 40 unique source contracts, typed fixture equality, and exact manifest
schema/workflow/risk equality. It MUST NOT infer caller-local JSON construction,
shell command position, quoting, substitutions, function invocation, or heredoc
execution.

Governed executable fences also use a deliberately strict source rule: the raw
fence text MUST contain none of the direct provider/backend atoms
`spawn_agent`, `uberdev_agent_dispatch`, `uberdev_dispatch_one`,
`_uberdev_agent_dispatch_backend`, `claude`, or `codex`, and no `Task(` or
`Agent(` call. The rule is case-sensitive and has no exceptions for quotes,
comments, paths, heredocs, or here-strings. Provider-specific path discovery
belongs in the host adapter or generated-provider porter; canonical workflow
fences consume neutral root variables and routed child APIs. The scanner is a
raw bounded-text check, not a shell parser. Deliberately constructing provider
names from fragments is outside this source-style rule and remains prohibited
by the routed runtime contract and code review.

## 11. Workflow efficiency gates

Release 0.42.0 includes quality-neutral gates:

- Empty diff: skip reviewers/fixers and record `skipped_empty`.
- Empty findings: skip fixer.
- Ubersimplify audit-only: skip all fixer aggregation, reducing the default modeled path from 19 calls to 11.
- Ubersimplify normal mode: aggregate/fix only areas with `mergedCount > 0`; batch deterministic area aggregation where possible.
- Review repair loop: after a localized fix, re-run only lenses affected by changed hunks.
- Review completion: run exactly one final full five-reviewer fleet before approval.
- Uberthink: make its cumulative fleet counter real and cache only exact-equivalent read-only results keyed by input hash, source revision, prompt version, model/effort, lens, and tool version.
- Deterministic relays: replace with code where the host surface permits; otherwise route to `economy` and preserve a typed failure contract.

Security, authentication, concurrency, database, public API, and build-system changes always include their applicable high-risk lenses during targeted re-review. No targeted route may suppress the final full gate.

## 12. True concurrency and budgets

`fanout_concurrency.solve_bg` MUST become a live-session semaphore, not a dispatch-burst size. A new session starts only while the number of non-terminal sessions is below the cap. Capacity releases on completion, failure, timeout, or cancellation.

The semaphore scope is `(repository identity, backend)` and its state lives under a private `0700` directory in `UBERDEV_TMPDIR`. Acquisition uses a cross-process atomic `mkdir` mutex with bounded retry. While holding the mutex, the launcher:

1. Reconciles every lease through the backend's canonical liveness/status probe.
2. Deletes terminal leases and leases whose owner is dead and whose backend handle is not live.
3. Counts remaining live leases.
4. Creates a `0600` lease by temporary-file-plus-atomic-rename only when the count is below the cap.
5. Releases the mutex before launching or polling.

A lease records run ID, owner PID, backend handle, start time, command timeout, and status path. The launcher updates the backend handle after spawn and releases the lease through an EXIT trap plus terminal reconciliation. A lease older than its command timeout is stale only after the backend liveness probe also fails. Simultaneous-process, killed-owner, stale-lease, timeout, and cancellation tests MUST prove the observed live count never exceeds the cap and capacity is eventually recovered.

Each workflow SHOULD declare call, retry, loop, and wall-clock ceilings. Before starting another wave, it MUST reserve enough budget for its final quality gate. Budget exhaustion produces a structured partial result; it never silently omits the final gate and reports success.

## 13. Telemetry and run manifest

Every bundled LLM call MUST ultimately go through an instrumented `agent-dispatch` interface owned by the host workflow, not directly through an unobserved model instruction. The interface resolves the route, writes `route_decided`, writes `agent_started`, performs exactly one native or CLI dispatch, waits or registers the backend handle, and writes a terminal event.

The native adapter may use a custom-agent tool only when it can prove the effective role profile and bracket the call with manifest events. If the surface lacks enforceable route selection or lifecycle observation, the Codex adapter uses explicit `codex exec` with status/result files. Direct `spawn_agent`/`Task()` use outside this interface is forbidden in bundled workflow sources and rejected by the generated-artifact check.

If the host exits after `agent_started`, the next run-manifest reconciliation marks the orphan `abandoned` after the backend liveness probe fails. Thus every started call eventually has one of `completed`, `failed`, `timed_out`, `cancelled`, or `abandoned`; token fields may remain `null` for a native surface that does not report them.

Shadow mode records an adaptive decision but executes inherit mode. It is suitable for route-distribution and policy analysis, not quality comparison. Canary evaluation performs the actual paired adaptive/control executions from Section 17.2.

Append-only JSONL events MUST support:

```text
schema_version, event, timestamp, run_id, parent_run_id,
workflow, phase, role, issue_or_pr, backend, task_tier,
routing_mode, decision_logical_route, decision_source,
decision_model, decision_reasoning_effort,
effective_policy, effective_logical_route, effective_model,
effective_reasoning_effort, effective_service_tier, effective_sandbox,
enforcement_evidence,
risk_signals, queue_ms, duration_ms, prompt_bytes, result_bytes,
input_tokens, cached_input_tokens, output_tokens, usage_source,
retry_count, fallback_from, fallback_reason, cache_hit,
terminal_status, error_class, quality_gate
```

In adaptive/forced execution, decision and effective fields MUST agree after any recorded fallback. In shadow mode, decision fields contain the adaptive proposal while `effective_policy=inherit`; effective route/model/effort are `null` unless the provider reports them. `enforcement_evidence` is one of `explicit_argv`, `validated_profile`, `provider_reported`, or `ambient_unverified`. Unavailable route, effort, and token fields are `null`, never estimated. Prompt bodies, source code, issue bodies, credentials, and secrets MUST NOT be logged. Codex usage is parsed from `--json` output when present; provider-reported values are authoritative.

## 14. User configuration

`.codex/uberdev.local.md` is preferred, with `.claude/uberdev.local.md` as fallback:

```yaml
model_routing:
  mode: adaptive                 # adaptive | inherit; final default in 0.42.0
  service_tier: default
  risk_escalation: true
  adaptive_fallback: true
  shadow: false
  workflows: {}
  roles: {}

fanout_concurrency:
  solve_bg: 6
```

The example shows the final 0.42.0 steady state. Releases 0.40.0 and 0.41.0 ship `mode: inherit` as the default and allow `adaptive` as an explicit opt-in or shadow decision source.

CLI controls:

```text
--routing-mode: adaptive | inherit
--route: economy | standard | quality | deep | frontier | ultra
         luna | terra | sol | sol-high | sol-max | sol-ultra
--service-tier: default | fast | flex
```

`--route` selects and propagates a concrete forced route. `--routing-mode=adaptive` enables policy selection without a pin; `--routing-mode=inherit` selects the unpinned rollback path. `--fast` aliases `--service-tier=fast`; service tier remains independent from model and effort.

Environment overrides:

```text
UBERDEV_MODEL_ROUTING_MODE
UBERDEV_ROUTE
UBERDEV_MODEL
UBERDEV_REASONING_EFFORT
UBERDEV_SERVICE_TIER
```

All keys, defaults, ranges, precedence, and deprecation behavior MUST be added to the configuration reference and tested against the parser.

## 15. Generated artifact discipline

Canonical agent and skill sources remain under `plugins/uberdev/`. Generated Codex files MUST NOT be hand-edited.

One synchronization command MUST regenerate:

- `codex/agents/*.toml`
- `codex/uberdev-codex/agents/*.md`
- Codex skills and command-skills
- Mirrored runtime libraries

CI MUST run the same command in `--check` mode and fail on byte or semantic drift. Unknown source model classes and untranslatable tool claims MUST fail generation rather than warn and silently inherit.

## 16. Error handling

- Resolver/config errors fail before dispatch with the rejected value and valid alternatives.
- Explicit route failures never downgrade.
- Automatic route failures may downgrade once per step, within the minimum route, with a manifest event.
- A malformed structured agent result gets one format-repair retry, then becomes `blocked`.
- A routine route may retry once on transient provider failure and escalate once only when the first completed result shows insufficient confidence or unresolved high-risk evidence.
- Missing route enforcement is a visible degraded state, not success metadata.
- No catch path may swallow an agent, quality-gate, cache-validation, or external-write failure.

## 17. Testing and evaluation

### 17.1 Deterministic tests

- Route resolver: every class, alias, precedence combination, tier mapping, risk floor, explicit failure, and automatic fallback.
- Model catalog fixtures: Sol/Terra/Luna supported efforts, unavailable model, and an unsupported Mini+Ultra pair.
- Dispatch: captured Codex argv includes model, reasoning effort, service tier, and sandbox; Claude paths contain no Codex flags.
- Agent generation: expected role route/sandbox, native language, description/word budgets, literal-newline decoding, no dropped-whitelist claims, and byte-drift check.
- Planning: no custom child agent delegates; dependency, test, and risk research fanout is rooted in the host orchestrator and `plan-writer` receives only artifact paths.
- Reviewers: one valid/invalid fixture per role, five unique reviewers, one repair retry, required-blocked behavior.
- Workflows: exact invocation counts for empty, clean, retry, targeted repair, final full gate, audit-only simplify, zero-findings areas, cache hit/miss, and budget exhaustion.
- Concurrency: observed live child count never exceeds the configured cap.
- Crash/resume, timeout, cancellation, malformed output, and partial backend failure.

### 17.2 Golden evaluation corpus

Before adaptive mode becomes the default, shadow and canary decisions run against a versioned corpus under `tests/fixtures/model-routing-eval/v1/`. Its manifest freezes task inputs, model-catalog snapshot, prompt/policy/workflow versions, expected terminal state, and canonical finding IDs. The primary paired control uses the same release-candidate code, prompts, and workflow twice: once with adaptive routing and once with forced `--route=sol-ultra`. A separately reported historical comparison freezes `v0.39.1` and its observed effective routes, but it does not decide routing non-inferiority because it would confound prompt and workflow changes. Shadow-mode records are excluded from quality statistics. The first accepted corpus MUST contain at least 60 paired tasks spanning trivial, small, medium, large, security, concurrency, data-loss, type, test, and documentation work.

Deterministic tasks run once per configuration. Nondeterministic agent workflows run five paired trials per task and configuration, with adaptive/control order randomized and recorded per pair. A finding matches a canonical expected finding when category and severity match and the cited line is within three lines of the seeded location; remaining unmatched findings receive blinded human adjudication recorded in the corpus ledger. A canonical blocker/critical finding counts as recalled only when it appears in the deterministic run or in at least four of five adaptive trials; every such canonical finding MUST be recalled.

For completion rate and non-blocker finding recall, adaptive routing is non-inferior only when the lower bound of a one-sided 95% paired bootstrap confidence interval for `(adaptive - baseline)` is at least `-0.05`. The corpus gate MUST demonstrate at least 80% power for that five-percentage-point margin through a checked-in simulation before results are accepted. Blocker/critical recall is an absolute gate and admits no margin.

Required gates:

- 100% task-level recall for the corpus's canonical blocker/critical findings under the deterministic-or-four-of-five rule, with the same-build forced-Sol-Ultra control reported alongside it.
- Completion rate and non-blocker recall pass the defined five-percentage-point non-inferiority test.
- No lead or judgment-bearing descendant for a security/auth/data-loss task routed below `deep`; pure bookkeeping and monitor roles are checked against their declared role floors.
- At least 40% reduction in generated agent prompt-body words.
- Unspecified trivial/small issues no longer enter the full thirteen-agent design path.
- Ubersimplify audit-only default path is at most 11 model calls.
- Every model invocation has a route/terminal manifest pair.
- Every accepted cache hit proves exact key equivalence.
- One final comprehensive review gate remains on every review-bearing success path.

Efficiency metrics are model calls, prompt/result bytes, provider-reported tokens, p50/p95 wall time, queue time, retry rate, cache hit rate, and completion rate. Lower usage is an improvement only after the quality gates hold.

## 18. Release sequence

The program is deliberately split into three user-facing releases. Each release is independently testable, releasable, and rollback-safe; no PR carries the entire program.

### 18.1 Release 0.40.0 — Routing foundation

- Add the policy catalog, pure resolver, provider adapters, config/CLI parsing, catalog fixtures, and run-manifest primitives.
- Route detached Codex leads explicitly and make `/solve` auto-triage real.
- Public `--route` support begins with `/solve` and `/turbo`; other workflows reject the flag as unsupported until their complete call tree uses the adapter, rather than making a partial propagation promise.
- Generate role-default model, effort, sandbox, and declared delegation mode without rewriting all prompt bodies yet; enforce leaf restrictions for every custom role.
- Flatten plan-writer research into root-level fanout so `plan-writer` is a leaf before the first adaptive release.
- Introduce the instrumented dispatch interface and migrate every bundled Codex call path that makes a route promise.
- Implement the process-safe live concurrency semaphore.
- Ship `adaptive` as opt-in and shadow-capable; retain `inherit` as the default until the golden corpus passes.
- Add one authoritative generation/synchronization check.

### 18.2 Release 0.41.0 — Native agent behavior

- Apply the native prompt contract and achieve the 40% prompt-body reduction.
- Make the Codex skill porter emit native dispatch guidance.
- Standardize five reviewer outputs and remove the duplicate reviewer.
- Extract deterministic work from `findings-to-issues`, `trust-trail-evaluator`, and `ci-rebase-handler` while preserving their safety gates.

### 18.3 Release 0.42.0 — Workflow efficiency and adaptive default

- Add empty/zero-finding gates, targeted repair re-review, one final full gate, cumulative budgets, and exact-input caches.
- Migrate every remaining bundled Codex and provider-neutral workflow call path to the instrumented dispatch interface, including compatibility telemetry for unchanged Claude/WezTerm/background execution. Enable public route flags only after each complete call tree is enforceable and observable, then enable the repository lint that rejects direct bundled `spawn_agent`/`Task()` dispatch outside the adapter.
- Run the frozen paired evaluation corpus and publish its machine-readable result artifact.
- Enable `model_routing.mode: adaptive` by default only after every golden gate passes.
- Preserve `inherit` as the immediate rollback switch.

### 18.4 Later RFC work

Continue RFC 0012 in this order only after telemetry supports it: review → cluster → Uberthink → orchestrator/subagent-driven development → goal. A backend-neutral DAG scheduler remains a separate RFC and is justified only if provider/runtime divergence stays material after 0.42.0.

## 19. Acceptance criteria

### 19.1 Release 0.40.0

- Every migrated top-level/delegated Codex call records a route before start and a terminal event or reconciled `abandoned` event.
- Ambient Sol Ultra no longer makes adaptive opt-in routine children inherit Ultra.
- Explicit `--route=sol-ultra` is enforced for the complete run tree or fails with `route_unenforceable` before the first unenforceable dispatch.
- All generated role TOMLs contain expected model, effort, sandbox, and declared delegation mode; live probes reject nested spawn for every custom role, including `plan-writer`, and inherit-mode tests prove the unpinned rollback path.
- `/solve` no longer defaults every unspecified issue to `medium`.
- Live concurrency never exceeds the configured cap under simultaneous-process and killed-owner tests.
- Claude, WezTerm, background, and Codex parity tests pass.
- Generated artifacts are drift-free.
- Version `0.40.0` is updated in every mandated location in its release commit.

### 19.2 Release 0.41.0

- Generated prompt-body words are at least 40% below the audited baseline and native-language lint is clean.
- Five unique reviewer fixtures validate against the canonical schema; the duplicate reviewer count is zero.
- Extracted deterministic steps consume zero model calls and retain existing safety/idempotency tests.
- Version `0.41.0` is updated in every mandated location in its release commit.

### 19.3 Release 0.42.0 and program completion

- Empty-work fixtures produce zero unnecessary model calls.
- Targeted repair review is followed by exactly one full final fleet.
- Ubersimplify audit-only default path is at most 11 model calls.
- Every accepted cache hit proves exact key equivalence.
- Golden blocker/critical recall remains 100%, and the defined non-inferiority gates pass.
- Every bundled model invocation has a route/terminal manifest pair.
- Full test suite, smoke tests, install verification, version ratchets, and documentation checks pass.
- Version `0.42.0` is updated in every mandated location in its release commit.
- Each tag and GitHub Release is created only after the corresponding merge.
