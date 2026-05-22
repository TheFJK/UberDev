# RFC 0007 — `/uberscan` Whole-Codebase Read-Only Audit

| Field          | Value                                                                              |
| -------------- | ---------------------------------------------------------------------------------- |
| **Status**     | Draft                                                                              |
| **Author**     | TheFJK                                                                             |
| **Created**    | 2026-05-22                                                                         |
| **Targets**    | new `commands/uberscan.md`, new `skills/uberscan-pipeline/`, `agents/findings-to-issues.md` |
| **Supersedes** | —                                                                                  |
| **Tier**       | Medium (multi-agent, multi-file, contract-affecting)                               |

## 1. Summary

`/uberscan` (alias: `/uberscan` → `/uberdev:uberscan`) is a **read-only, whole-codebase** audit command — a static-analysis counterpart to `/review-pr`. Where `/review-pr` inspects a PR diff and gates a merge, `/uberscan` audits the repository as it currently stands and produces a durable backlog of findings plus a structured markdown report. It never modifies source code; the read-only invariant is enforced at the tool-permission layer, not just by convention.

A single run: (1) chunks the repo into budget-bounded, module-cohesive file groups; (2) dispatches the `/review-pr` Phase-1 reviewer fleet (six agents, reframed with a file-set audit brief) against every chunk in concurrency-capped waves, plus a single repo-global Semgrep SAST + test-coverage pass; (3) cross-chunk dedupes and aggregates all findings into a severity-ranked markdown report; and (4) files deduped GitHub issues for `blocker`, `critical`, and `major` severity findings via an adapted `findings-to-issues` pipeline. Suggestion-level findings appear only in the report.

## 2. Motivation

### 2.1 Gap: `/review-pr` is diff-only

`/review-pr` is deliberately scoped to a single PR diff — it is designed to gate a merge, not to characterise accumulated technical debt. A senior engineer joining a codebase has no slash command to get a structured audit of what already exists. `/review-pr` cannot be repurposed for this: it requires a PR number, populates reviewer briefs with diff context, wires `Blocks: #N` backlinks, emits `Reviewed-by` trust signals, and is optimised for a small-bounded changeset. None of those assumptions hold for a whole-repo scan.

### 2.2 Why a whole-codebase audit is valuable

Incremental PR review only surfaces problems introduced *at the time of authorship*. Latent issues — architectural drift, type-design debt, comment rot, silent-failure patterns that crept in across many small PRs, uncovered modules that never had a dedicated PR — never get reviewed. For a solo developer who authors most of their own PRs, the asymmetry is especially pronounced: the reviewer and the author are the same person, so even `/review-pr` provides limited coverage of deep pre-existing issues. A scheduled or on-demand whole-codebase sweep using the same fleet of specialised reviewers fills this gap by treating the current HEAD as the thing under review.

### 2.3 Read-only posture

The output of a whole-codebase audit is a *backlog*, not a diff. Filing dozens of fix commits in one pass would be a high-blast-radius operation that bypasses the normal plan → implement → review cycle. More importantly, an LLM-driven auto-fix applied at scale without targeted investigation introduces a significant regression surface. The `/uberscan` design therefore enforces read-only by dropping `Edit` and `MultiEdit` from the command's `allowed-tools` frontmatter — no agent in the chain can write source, even if it tries. Remediation happens later, one issue at a time, via `/uberdev:solve` on the filed backlog items.

### 2.4 Why simplify is excluded

The `/review-pr` Phase-1 fleet includes simplify lenses (Reuse, Quality, Efficiency). These are intentionally absent from `/uberscan`. Simplification at whole-codebase scale is a qualitatively different operation — it requires a holistic view across modules to identify shared abstractions, and the remediation path is a substantial refactor, not a targeted fix. That makes it a sibling command with its own design, its own circuit-breaker budget, and its own user-approval checkpoints. Mixing simplification lenses into `/uberscan` would bloat its issue output with advice that cannot be addressed incrementally and would conflate two distinct concerns (correctness/quality audit vs. structural simplification).

## 3. Design

### 3.1 The six-reviewer fleet and file-set audit brief

`/uberscan` reuses the exact same six-reviewer composition as `/review-pr` Phase 1 (`post-impl-review`):

| Agent (`subagent_type`)         | Role under `/uberscan`                                               |
| ------------------------------- | -------------------------------------------------------------------- |
| `uberdev:code-reviewer` (correctness lens)   | Correctness, design, CLAUDE.md compliance.              |
| `uberdev:code-reviewer` (general catch-all)  | Broad code-quality sweep — full-fleet fidelity.         |
| `uberdev:silent-failure-hunter`              | Swallowed errors, silent fallbacks.                     |
| `uberdev:type-design-analyzer`               | Type-design quality, `any` misuse, weak invariants.     |
| `uberdev:comment-analyzer`                   | Stale, inaccurate, or misleading comments.              |
| `uberdev:pr-test-analyzer`                   | Coverage-gap mode: untested surface in the chunk's source files. |

Each reviewer receives a **file-set audit brief** in place of the diff context it would normally receive:

> You are auditing an EXISTING codebase as it currently stands — this is NOT a change review and there is no diff. Below are the full contents of \<N\> files (chunk \<i\>/\<total\>, scope: \<scope\>). Evaluate the code as written for \<lens\>. Flag pre-existing issues. Return findings in the standard YAML contract (verdict, findings[] with severity/location/summary/detail, confidence).

This is an orchestration-layer reframing — the agent definitions are unchanged. `type-design-analyzer` and `comment-analyzer` return free-form prose (per their existing contracts); the aggregator normalises both YAML and prose forms, mirroring the `pr-test-analyzer` Markdown fallback already in `post-impl-review`.

In addition to the per-chunk fleet, two **repo-global analyzers** run once over the entire scope:

| Agent                         | Role                                                        |
| ----------------------------- | ----------------------------------------------------------- |
| `uberdev:research-security`   | Semgrep SAST across the full scope; severity-ranked findings. |
| `uberdev:research-test-coverage` | Test-surface map; uncovered modules relevant to scope.   |

These are run once — not per chunk — because Semgrep and coverage mapping are inherently whole-tree operations. Running them per chunk would produce redundant, incomplete views of the same global state.

### 3.2 Chunk-major waves

The orchestration shape is **chunk-major waves with artifact aggregation** (Approach A from the design brainstorm). Each chunk is a unit of work dispatched as a single-message six-reviewer fanout. The orchestrator processes chunks in waves of up to `concurrency` (default 3) chunks at a time, reads only the compact per-chunk aggregate file after each wave (never raw agent transcripts), and advances to the next wave. This keeps the orchestrator's context lean across many chunks — the same "summaries not raw research" principle used by the `/solve` orchestrator.

All artifacts live under `.uberdev/scan/<RUN_ID>/`, where `RUN_ID` is a UTC timestamp plus a short random suffix. Per-chunk aggregate files are named `chunk-NN-findings.md`. The repo-global pass produces `global-security.md` and `global-coverage.md` in the same directory.

The chunking algorithm (implemented in `skills/uberscan-pipeline/chunk.py`) works as follows:

1. **Resolve scope.** No positional argument → whole repo. A path or glob argument → that subtree. Always `git ls-files`-based (tracked files only; respects `.gitignore`).
2. **Filter.** Drop binaries, lockfiles (`*.lock`, `package-lock.json`, etc.), generated or vendored trees (`node_modules/`, `vendor/`, `dist/`, `build/`, `.min.*`), and files over a hard per-file size cap.
3. **Group.** Cluster files by directory for module cohesion; pack directories into chunks under `chunk_budget_bytes` (default ~48 KB ≈ ~12 k tokens). Split oversized directories across multiple chunks; merge tiny adjacent directories to avoid chunk sprawl.
4. **Circuit-breaker gate.** If chunk count > `MAX_CHUNKS` (default 25) or projected agent count > `MAX_AGENTS` (default 250): in interactive mode, halt and surface scoping guidance; in turbo/non-interactive mode, cap to the first `MAX_CHUNKS` by priority and record `overflow_chunks`. Both can be overridden with `--all`.

### 3.3 Repo-global pass

The repo-global pass (Phase 1b) is dispatched concurrently with the first chunk wave. `research-security` runs Semgrep SAST across the full scope and returns severity-ranked findings. `research-test-coverage` produces a test-surface map of uncovered modules. Because these analyzers already operate on the whole tree, no chunking or reframing is needed; they receive the same scope argument passed to the command.

### 3.4 Circuit breakers

Seven circuit breakers govern resource usage:

| ID  | Breaker                              | Default  | Behaviour on trip                                                                                     |
| --- | ------------------------------------ | -------- | ----------------------------------------------------------------------------------------------------- |
| CB1 | `MAX_CHUNKS`                         | 25       | Interactive halt with scoping guidance; turbo caps + records `overflow_chunks`. Override with `--all`. |
| CB2 | Concurrency (`fanout_concurrency.uberscan`) | 3   | Chunks processed in waves of this size — a throttle, not a halt.                                     |
| CB3 | Per-wave timeout                     | 900 s    | Abandon stalled wave, record `chunk_timeout`, continue.                                               |
| CB4 | Overall wall-clock budget            | 60 min   | Finalise with partial results; report marked partial.                                                 |
| CB5 | Findings flood (`blocker+critical`)  | 150      | Stop early ("systemic issue"), report partial; prevents runaway issue filing.                         |
| CB6 | gh rate-limit floor (core bucket)    | 200      | Skip issue filing fail-closed; keep report; surface warning.                                         |
| CB7 | `MAX_AGENTS` (projected)             | 250      | Same handling as CB1.                                                                                 |

All defaults are configurable via `.uberdev/config.json` `uberscan.*` keys and CLI flags. Precedence: CLI > env > config > default, matching existing commands.

### 3.5 Findings-to-issues adaptation

The existing `findings-to-issues` agent is used with two targeted adaptations for the `/uberscan` context:

- **No PR backlinks.** When `pr_number` is empty (always, for `/uberscan`): no `@mention`, no `--assignee`, no `Blocks:`/`Related:` backref. Issues carry `Source: /uberscan run <RUN_ID>` instead.
- **`uberscan-finding` label.** Findings are labelled `uberscan-finding` (distinct from `review-pr-finding`) so the two backlogs are independently filterable via `gh issue list`.

These are additive changes. All existing behaviour is preserved: fingerprint dedupe + HTML-comment markers, `MAX_NEW` cap (default 15 for whole-repo runs), overflow accounting, fail-closed gh handling, and secret-scan-on-body guard.

The `findings-to-issues` agent accepts three new optional inputs (`finding_label`, `finding_marker_slug`, `source_ref`) with defaults that preserve full backward compatibility with `/review-pr`; see §4.

### 3.6 Dropped PR-bound concerns

The following `/review-pr` concerns are explicitly absent from `/uberscan` and must not be re-introduced:

- **Phase 3 CI-health probe.** There is no PR and no CI run to probe.
- **`Reviewed-by` trust signal.** `/uberscan` is advisory; it produces a backlog, not a merge certification.
- **`uberdev-approved` label.** Same reason as above.
- **PR author `@mention`.** No PR number, no author.
- **`Blocks: #N` / `Related:` backrefs.** The findings-to-issues agent writes `Source: /uberscan run <RUN_ID>` instead.
- **`code-simplifier` lenses.** Intentionally excluded; whole-codebase simplification is a separate sibling command.

## 4. Contracts

### C1 — Chunk manifest (JSON)

Written to `.uberdev/scan/<RUN_ID>/manifest.json` by `chunk.py` after Phase 0.

```json
{
  "run_id": "<RUN_ID>",
  "scope": "<whole-repo | path>",
  "total_files": 142,
  "total_bytes": 983041,
  "chunks": [
    {
      "chunk_id": "chunk-00",
      "files": ["src/auth/index.ts", "src/auth/guards.ts"],
      "byte_count": 47821,
      "priority": 1
    }
  ],
  "overflow_chunks": [],
  "circuit_breakers_tripped": []
}
```

Fields: `run_id` (string), `scope` (string), `total_files` (int), `total_bytes` (int), `chunks[]` (array of `{chunk_id, files[], byte_count, priority}`), `overflow_chunks[]` (array of `chunk_id` strings capped due to CB1/CB7), `circuit_breakers_tripped[]` (list of breaker IDs tripped during this phase).

### C2 — Per-chunk findings (YAML)

Written to `.uberdev/scan/<RUN_ID>/chunk-NN-findings.md` by the per-chunk aggregator after each wave. The `agent` enum is the same six-reviewer roster as `/review-pr` Phase 1 — `code-simplifier` is absent and there is no `lens` field.

```yaml
chunk_id: chunk-00
scope_files:
  - src/auth/index.ts
  - src/auth/guards.ts
agents_run: 6
agents_failed: 0
verdict: needs_work
findings:
  - severity: critical
    agent: silent-failure-hunter
    location: src/auth/guards.ts:84
    summary: "JWT decode error swallowed — returns undefined silently"
    detail: >
      The catch block on line 84 discards the JsonWebTokenError and falls
      through to return undefined. Callers that check truthiness will
      proceed as if the token were valid.
    confidence: high
  - severity: major
    agent: code-reviewer
    location: src/auth/index.ts:31
    summary: "Magic number 3600 — should be a named constant"
    detail: "Token TTL is hardcoded as 3600 with no explanation or constant."
    confidence: medium
```

Valid `severity` values: `blocker`, `critical`, `major`, `important`, `suggestion`. Valid `confidence` values: `high`, `medium`, `low`. There is no `lens` field and no `code-simplifier` agent entry.

### C3 — Findings-to-issues aggregate

Written to `.uberdev/scan/<RUN_ID>/f2i-aggregate.md` and passed to the `findings-to-issues` agent wrapped in the standard trust boundary:

```xml
<external-untrusted-input source="uberscan-aggregate">
<!-- contents of f2i-aggregate.md -->
</external-untrusted-input>
```

The aggregate contains only findings at or above the `--min-severity` floor (default `major`, i.e. `severity ∈ {blocker, critical, major, important}`) AND at or above the `--min-confidence` floor (default `medium`) after cross-chunk dedupe. All findings carry `disposition: DEFERRED` (nothing was applied — the scan is read-only), which satisfies the existing `findings-to-issues` `disposition != APPLIED` filter and causes every finding to be eligible for issue filing.

### C4 — New `findings-to-issues` inputs

Three optional inputs are added to the `findings-to-issues` agent. All have defaults that make existing `/review-pr` call sites fully backward-compatible — no changes are required at existing call sites.

| Input                 | Default               | Description                                                                 |
| --------------------- | --------------------- | --------------------------------------------------------------------------- |
| `finding_label`       | `review-pr-finding`   | GitHub label applied to filed issues. `/uberscan` passes `uberscan-finding`. |
| `finding_marker_slug` | `review-pr`           | Slug embedded in the HTML-comment dedup marker `uberdev:<slug>-finding` (the template appends `-finding`). Default `review-pr` → canonical `uberdev:review-pr-finding`. `/uberscan` passes `uberscan` → `uberdev:uberscan-finding`. |
| `source_ref`          | `` (empty string)     | Free-form source reference appended to the issue body. `/uberscan` passes `Source: /uberscan run <RUN_ID>`. |

When `pr_number` is empty and `source_ref` is non-empty, the agent substitutes `source_ref` for the PR backlink line. When both are empty, the agent omits the line entirely.

### Exit codes

| Code | Meaning                                                                                                       |
| ---- | ------------------------------------------------------------------------------------------------------------- |
| `0`  | Scan completed — clean or findings filed (including partial scans where the report was successfully written). |
| `1`  | Circuit-breaker halt before completion — e.g. `MAX_CHUNKS` exceeded without `--all`, or wall-clock budget exceeded with no partial results to report. |
| `2`  | Fatal preflight failure — not a git repo, no scannable files found in scope, or `--no-report --no-issues` leaving no output sink. |

## 5. Risks / Mitigation

### Cost blowup

Running six agents against every chunk across a large codebase is expensive. Mitigations operate at multiple layers:

- **CB1 (`MAX_CHUNKS = 25`) and CB7 (`MAX_AGENTS = 250`)** are the primary cost gates. On a 500-file repo, the default chunking produces roughly 15–20 chunks (≈ 90–120 agent dispatches), well within budget. CB1 halts or caps before the run becomes cost-prohibitive.
- **`--concurrency` flag and `fanout_concurrency.uberscan` config key** throttle parallelism. The default of 3 concurrent chunks (18 simultaneous agents) balances throughput against token-per-minute rate limits.
- **CB4 (60-minute wall-clock budget)** provides an absolute backstop. The scan finalises with whatever partial results exist rather than running indefinitely.
- **`--max-chunks=N` flag** lets users hard-cap without passing `--all`, giving an explicit cost-control override without fully disabling the safety gate.
- **Path/glob scoping** is the first-line cost control, recommended in the command description for large repos.

### Issue spam

Filing issues for every finding in a large codebase would produce an unmanageable backlog:

- **Severity filter:** only findings at or above the `--min-severity` floor (default `major`, i.e. `blocker`/`critical`/`major`/`important`) reach `findings-to-issues`. Suggestion-level findings appear only in the report.
- **`MAX_NEW` cap (default 15 per run):** limits the number of issues filed in a single invocation. Overflow findings are recorded in the report with a note that they were not filed.
- **CB5 (findings flood guard):** if `blocker + critical` findings exceed 150, the scan halts early with a "systemic issue" message and files no issues — the volume signals a repo-level crisis better addressed with a targeted triage session, not 150 auto-filed issues.
- **Fingerprint dedupe** across chunks and across runs (via the HTML-comment marker) prevents the same finding from generating duplicate issues across repeated scans.
- **gh rate-limit floor (CB6):** issue filing is skipped fail-closed below 200 core-bucket remaining, preventing gh API exhaustion.

### Reviewer false-positives on full files

Reviewers trained and calibrated on diffs may exhibit higher false-positive rates when presented with full file contents, particularly for findings that require understanding of callsites outside the chunk:

- **Confidence threshold:** the aggregate filters out `confidence: low` findings before writing `f2i-aggregate.md`. Only `high` and `medium` confidence findings proceed to issue filing (configurable via `report.py --min-confidence`, default `medium`). Implemented in `report.py`.
- **`detail` field requirement:** the YAML contract requires a non-empty `detail` explaining why the finding is a genuine problem, not just a stylistic observation. Hard auto-rejection of empty-`detail` findings is a **deferred enhancement** — silently dropping a high-severity finding solely for a missing `detail` would risk hiding a real bug, so v1 surfaces them and relies on the reviewer briefs requiring `detail`.
- **Cross-reviewer confirmation:** when the same location is flagged by two or more agents, the issue body notes `also_flagged_by` and the combined confidence is elevated. Single-reviewer findings at `medium` confidence remain in the report but can be configured to stay report-only.
- **`--severity` flag:** the user can raise the minimum severity for issue filing from `major` to `critical` or `blocker` when they want a tighter first-pass.

## 6. Alternatives

### Static-friendly reviewer subset

One alternative was to restrict the per-chunk fleet to only the agents that are clearly well-suited to full-file review — `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer` — and drop `code-reviewer` and `pr-test-analyzer` on the grounds that they are most diff-oriented.

**Rejected** because the `/review-pr` Phase-1 design explicitly made the fleet redundant (each agent covers overlapping ground to increase recall). Dropping two of six reviewers saves roughly 30% of agent cost but reduces the recall of the fleet measurably. The file-set audit brief is sufficient to reframe all six reviewers for full-file review; the diff-orientation of `code-reviewer` is a matter of brief, not a structural limitation.

### Adapt-all-agents (including simplify lenses)

An alternative was to run the full post-impl-review fleet including the simplify lenses (Reuse, Quality, Efficiency), making `/uberscan` a superset of `/review-pr` Phase 1 at whole-codebase scale.

**Rejected** on user decision (2026-05-22). Simplification at whole-codebase scale is qualitatively different: the remediation path is a substantial refactor, not a targeted fix; it requires a holistic cross-module view to identify the right abstractions; and the resulting issues are not independently actionable via `/uberdev:solve` in the same way correctness findings are. Mixing simplify lenses into `/uberscan` would conflate two concerns and bloat the backlog with advice that cannot be addressed in isolation. Whole-codebase simplification is deferred to a sibling command with its own RFC.

### Reviewer-major streaming (Approach B)

An alternative orchestration shape was **reviewer-major**: run each of the six reviewers once across all chunks before moving to the next reviewer. This would give each reviewer a single coherent context over the whole codebase, potentially improving cross-file finding quality.

**Rejected** in favour of chunk-major (Approach A). Chunk-major waves allow earlier partial results (findings from chunks 1–3 are available while chunks 4–6 are running), simplify retry logic (a chunk is the unit of failure, not an entire reviewer pass), and keep per-agent context sizes bounded (one chunk ≈ 12 k tokens vs. the entire codebase). The orchestrator's "summaries not raw research" principle is easier to apply when each wave produces a compact per-chunk aggregate. Cross-file finding quality in reviewer-major mode would require the reviewer to hold the entire codebase in context, which is impractical at scale and conflicts with the chunking budget rationale entirely.

## Appendix: Shipping checklist

Per project CLAUDE.md, all of the following must land in the same PR or in the immediately-preceding `chore(release): v0.32.0` commit:

1. `plugins/uberdev/commands/uberscan.md` — frontmatter (§4.1 of the design spec) + body.
2. `plugins/uberdev/skills/uberscan-pipeline/SKILL.md` — orchestration phases (§5 of the design spec).
3. `plugins/uberdev/skills/uberscan-pipeline/chunk.py` — chunking algorithm + manifest writer.
4. `plugins/uberdev/skills/uberscan-pipeline/report.py` — aggregate, dedupe, and report writer.
5. `plugins/uberdev/agents/findings-to-issues.md` — accept `source="uberscan-aggregate"`, empty-`pr_number` path (no mention/backref), new optional inputs (`finding_label`, `finding_marker_slug`, `source_ref`).
6. Alias surfaces (5): `lib/aliases-sync.sh` ALIASES row, `commands/install-aliases.md` table + count, `commands/uninstall-aliases.md` SHORTS list, `README.md` alias table + count, `tests/aliases.test.sh` canonical loop.
7. Version bump to `0.32.0` in all 6 locations (plugin.json, marketplace.json, README badge, CHANGELOG, git tag, GH release).
8. Tests: `tests/uberscan.test.sh` (structural, chunking algorithm, circuit-breaker halt, findings-to-issues adaptation).
