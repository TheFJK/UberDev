# RFC 0008 — `/ubersimplify`: whole-codebase 3-lens simplification

- **Status:** Draft
- **Author:** TheFJK
- **Created:** 2026-05-22
- **Target version:** 0.33.0
- **Related:** RFC 0007 (`/uberscan`, whole-codebase audit — sibling), RFC 0002 (tiered-halt findings-to-issues), `commands/simplify.md` (3-lens engine), `agents/code-simplifier.md`, `agents/code-fixer.md`

## 1. Summary

`/ubersimplify` applies the `/uberdev:simplify` three-lens pass — **Reuse, Quality, Efficiency** — to the **entire codebase** instead of the current `git diff`, and lands the resulting preserve-behavior refactors on a **new branch behind a single pull request** for review. It is the "writing" sibling to `/uberscan`'s read-only audit: same chunking engine, but the per-chunk fleet is the three `code-simplifier` lenses (not the review-pr reviewers), and an apply phase dispatches `code-fixer` per chunk to produce reviewable `refactor:` commits.

RFC 0007 §2.4 explicitly excluded simplification from `/uberscan` and named this command as the planned sibling. This RFC delivers it.

## 2. Motivation

`/simplify` is diff-scoped: it only ever sees what changed since the last commit. There is no first-class way to sweep an existing repository for accumulated duplication, parameter sprawl, dead abstractions, and hot-path bloat. `/uberscan` proved the whole-codebase chunk-and-fan-out pattern works read-only; `/ubersimplify` reuses that machinery to actually *apply* the three simplify lenses across the whole tree, while keeping the repo-wide blast radius safe by routing every change through one reviewable PR rather than committing in place.

## 3. Non-goals

- **Not a correctness/security audit.** That is `/uberscan`. `/ubersimplify` runs only the three simplify lenses (`code-simplifier`), not the review-pr reviewer fleet, Semgrep, or coverage passes.
- **Not auto-merge.** `/ubersimplify` opens a PR and stops. It never merges, never auto-chains into `/review-pr` or `/merge` (consistent with the `/merge`-is-independent rule). The user reviews and runs `/review-pr` themselves.
- **Not behavior-changing.** The `code-fixer` iron rule (preserve behavior; reject behavior-change findings with `disposition: REFUSED, reason: "behavior-change-rejected"`) is inherited unchanged.
- **No new lens logic.** The Reuse/Quality/Efficiency checklists remain single-sourced in `agents/code-simplifier.md`. Whole-codebase scope only changes the *brief* (audit files as they stand), not the checklists.

## 4. Design

### 4.1 Pipeline phases

The command (`commands/ubersimplify.md`) performs preflight only, then hands off to a new `uberdev:ubersimplify-pipeline` skill that owns six phases. Like `uberscan-pipeline`, the skill is a **directive-emitter**: its bash returns in milliseconds writing dispatch directives, and the orchestrating session fires the `Task()` calls (one message per audit wave; sequential for the apply phase).

| Phase | Name | Writes? | Summary |
|---|---|---|---|
| **0** | Parse + scope + chunk | no | Parse flags; resolve config; `lib/chunk.py` → `manifest.json`. Overflow / projected-agent guards (CB1/CB7). |
| **1** | Per-chunk lens waves | no | For each chunk, fire **3** `code-simplifier` Tasks (Reuse, Quality, Efficiency) in one message, in waves of `CONCURRENCY`. Normalize to per-chunk `chunk-NNN-lens.yaml`. |
| **2** | Aggregate + dedup | no | `aggregate.py` collapses lens findings per `file:line` (lens-merge), emits a per-chunk **fixer aggregate** (`post-impl-review-aggregate` envelope) and the human report. |
| **3** | Branch + apply (skip iff `--audit-only`) | **yes** | `git checkout -b ubersimplify/<RUN_ID>` off the current branch; for each chunk with findings, **sequentially** dispatch one `code-fixer` Task → one `refactor:` commit. Collect disposition YAMLs. |
| **4** | Push + PR (skip iff `--audit-only` or 0 commits) | **yes** | Push the branch; `gh pr create` one PR to the base branch with a run-summary body. Capture PR number. |
| **5** | File leftover issues (skip iff `--no-issues`) | **yes (issues)** | Findings `code-fixer` did not apply (disposition `REFUSED`/`SKIPPED`, fileable tier) → `findings-to-issues`, referencing the new PR. |
| **6** | Summary + exit | no | Severity totals, branch/PR/issue links, circuit-breaker state, exit code. |

`--audit-only` collapses this to the `/uberscan` shape: Phases 0→1→2→(report)→5, no branch/fix/PR, issues filed with an empty `pr_number`.

### 4.2 Scope, chunking, and the lens brief

Scope resolution and chunking are **identical to `/uberscan`** and share the same code (see §6, chunk.py extraction). `git ls-files`-based, `.gitignore`-respecting, binaries/lockfiles/vendored trees filtered, directory-cohesive packing under `chunk_budget_bytes` (default 48 KB).

Each chunk's three lens Tasks receive a **file-set audit brief** (mirroring `uberscan-pipeline` Phase 1) that reframes `code-simplifier` from diff-mode to whole-file mode:

> You are auditing EXISTING source files as they stand in the repository — this is NOT a diff review. Apply your `## Lens emphasis: <Reuse|Quality|Efficiency>` checklist to the code as written today. For the **Reuse** lens specifically, hunt cross-file duplication across the whole repository, not just "new code duplicates existing."

`code-simplifier` already supports this — line 76: *"unless explicitly instructed to review a broader scope."* No agent change required.

### 4.3 Apply phase — why sequential, why per-chunk

Each `code-fixer` invocation does `git add <touched files>` + `git commit`. Running multiple concurrently in one worktree races the git index. Therefore Phase 3 dispatches **one `code-fixer` Task at a time**, each scoped to one chunk's fixer aggregate, each producing exactly one `refactor:` commit (`commit_type_prefix=refactor:`, `phase=phase2` — the existing R8.6 single-commit invariant applies per chunk). The expensive work (lens auditing) stays parallel in Phase 1; the apply is sequential but cheap (edits + commit).

Commit-per-chunk is also the reviewability win: a reviewer reading the PR sees one `refactor:` commit per module, each with the `[preserve]`/`[change]`/`[skipped]` finding list `code-fixer` already writes in the commit body.

### 4.4 Branch, PR, and the dirty-tree refusal

- **Preflight (command):** must be inside a git repo; **working tree must be clean.** A dirty tree is refused (`status: REFUSED, rationale: "dirty-working-tree"`) because `git checkout -b` + per-chunk commits would otherwise sweep the user's uncommitted work into refactor commits. The user commits or stashes first.
- **Branch:** `BASE=$(git branch --show-current)`, then `git checkout -b ubersimplify/<RUN_ID>` from current HEAD.
- **PR:** after commits land, `git push -u origin ubersimplify/<RUN_ID>` and one `gh pr create --base "$BASE"` with title `refactor: /ubersimplify whole-codebase simplification (<RUN_ID>)` and a body summarizing chunks audited, findings by lens/severity, commits, and a pointer to run `/review-pr`. **No `Co-Authored-By` / Claude attribution trailer** (project rule).
- **Zero-commit path:** if every chunk returns `NO_FIXES_NEEDED`, no PR is opened; the pipeline switches back to `$BASE`, deletes the empty `ubersimplify/<RUN_ID>` branch, and reports "already clean."

### 4.5 Leftover findings → issues

`code-fixer` returns a `findings_disposition[]` table per chunk. Rows with `disposition != APPLIED` at a fileable tier (`blocker`) — typically behavior-change refusals the iron rule blocked — are collected into the issue aggregate and filed via `findings-to-issues`. Because `/ubersimplify` *has* a PR (unlike `/uberscan`), it passes the real `pr_number`, so filed issues carry `Blocks: #<PR>` backrefs.

Dispatch parameters: `finding_label=ubersimplify-finding`, `finding_marker_slug=ubersimplify`, `source_ref=/ubersimplify run <RUN_ID>`, `pr_number=<created PR>` (empty under `--audit-only`).

**Audit-only path:** when `--audit-only` is set there is no apply phase and therefore no disposition YAMLs. `aggregate.py` instead emits the issue aggregate directly from **all** fileable (`blocker`) lens findings — every finding is treated as `DEFERRED` — exactly matching `/uberscan`'s read-only filing model. The two modes therefore converge on the same `ubersimplify-aggregate` envelope; they differ only in whether disposition YAMLs filter the row set.

## 5. Contracts

### 5.1 `chunk-NNN-lens.yaml` (per-chunk lens findings, schema C-LENS)

Written by the orchestrator after each chunk's three lens Tasks return. Mirrors `code-simplifier`'s `## Return contract` (note: simplify's enum is `blocker | suggestion`, **not** uberscan's five-level enum — see §9 drift note):

```yaml
schema_version: 1
chunk_id: <N>
files: [<path>, ...]
findings:
  - location: <path>:<line>
    severity: blocker | suggestion
    lens: Reuse | Quality | Efficiency
    summary: <1-line>
    detail: <prose>
```

### 5.2 Per-chunk fixer aggregate (`chunk-NNN-fixer.md`)

`aggregate.py` dedups the chunk's lens findings by `file:line` (merging across lenses: `lens: Reuse+Quality`, ` | `-joined summaries/details, severity = max), then wraps the result in the envelope `code-fixer` validates:

```
<external-untrusted-input source="post-impl-review-aggregate">
- location: <file>:<line>
  severity: blocker | suggestion
  lens: Reuse+Quality
  summary: ...
  detail: ...
</external-untrusted-input>
```

This reuses the exact source string `/simplify` already uses for its `code-fixer` dispatch — **no `code-fixer` change.**

### 5.3 Leftover-issues aggregate (`f2i-aggregate.md`)

```
<external-untrusted-input source="ubersimplify-aggregate">
| severity | location | agent | disposition | summary | detail |
| blocker | src/x.ts:42 | code-simplifier (Reuse) | DEFERRED | ... | ... |
</external-untrusted-input>
```

`findings-to-issues` Step 1 must accept the new source. Its accepted-source closed set becomes `{post-impl-review-aggregate, simplify-aggregate, ci-refused-synthetic, uberscan-aggregate, ubersimplify-aggregate}` — a one-line allow-list addition + the prose at line 28/41.

## 6. Reuse map

| Asset | Reuse strategy |
|---|---|
| `chunk.py` | **Extract** `skills/uberscan-pipeline/chunk.py` → `lib/chunk.py`; both pipelines reference the shared copy. Single source of truth; no fork. `uberscan-pipeline/SKILL.md` and `tests/uberscan-chunk.test.sh` updated to the new path (test-guarded move). |
| `code-simplifier` agent | Reused verbatim via the broadened file-set brief (§4.2). No change. |
| `code-fixer` agent | Reused verbatim (`phase2`/`refactor:`, `post-impl-review-aggregate` envelope). No change. |
| `findings-to-issues` agent | One-line accepted-source addition (`ubersimplify-aggregate`). Parameterized inputs (`finding_label`/`marker_slug`/`source_ref`) already exist from RFC 0007. |
| `lib/config-read.sh` | Reused as-is (key-agnostic `uberdev_read_int_in_range`). |
| Directive-emitter wave pattern + circuit breakers | Mirrored from `uberscan-pipeline` into `ubersimplify-pipeline` (per-chunk fleet is 3 lenses, not 6 reviewers; no repo-global pass). |
| `report.py` | **Not** reused — dedup logic differs (lens-merge vs agent-also-flagged) and `/ubersimplify` needs the dual-envelope output. New `aggregate.py` instead; trivial md-escape helpers kept local. |

## 7. Flags & config

```
/ubersimplify [path-or-glob] [--audit-only] [--all] [--no-issues] [--no-report]
              [--lens=Reuse,Quality,Efficiency] [--max-chunks=N] [--concurrency=N]
              [--turbo]
```

| Flag | Meaning |
|---|---|
| `--audit-only` | Read-only: no branch, no fix, no PR. Scan → report → issues (uberscan shape). |
| `--all` | Override the `MAX_CHUNKS` overflow breaker. |
| `--no-issues` | Skip leftover-issue filing. |
| `--no-report` | Skip the markdown report. |
| `--lens=…` | Subset the lenses (default all three). |
| `--max-chunks=N` / `--concurrency=N` / `--turbo` | As in `/uberscan`. |

Config namespace (via `config-read.sh`, defaults mirror `/uberscan`): `ubersimplify.max_chunks` (25), `fanout_concurrency.ubersimplify` (3), `ubersimplify.chunk_budget_bytes` (49152), `ubersimplify.max_agents` (250), `ubersimplify.max_new` (10).

## 8. Circuit breakers

Mirror `/uberscan` CB1–CB7, recalibrated for the 3-lens fleet:

| ID | Trigger | Behavior |
|---|---|---|
| CB1 | `overflow=true` & not `--all` | Halt with guidance (turbo: cap-and-continue). |
| CB2 | `fanout_concurrency.ubersimplify` (3) | Chunks per audit wave (throttle). |
| CB3 | Per-wave timeout > 900 s | Stop early, partial. |
| CB4 | Wall-clock > 3600 s | Stop early, partial. |
| CB5 | Cumulative blocker findings > 150 | Stop early, mark partial. |
| CB6 | gh rate-limit floor not met | Skip issue filing, keep branch/PR. |
| CB7 | Projected agents (`chunks × 3`) > `MAX_AGENTS` (250) | Halt with guidance (turbo: cap-and-continue). |

The apply phase (Phase 3) is bounded by the audited chunk set — no new unbounded fan-out. A very large simplification PR is surfaced (commit count + files-changed in the summary) but not auto-halted; the PR review gate is the backstop.

## 9. Pre-existing drift note (informational)

`agents/code-simplifier.md:132` emits `severity: blocker | suggestion`, but `commands/simplify.md` Phase 3/3.5 references `critical > important > suggestion` and "deferred-critical findings." `findings-to-issues` keys on `blocker`, so filing still works, but the command and agent disagree on the enum. `/ubersimplify` follows the **agent's** actual enum (`blocker | suggestion`); `blocker` is the only fileable tier from lens findings. A separate cleanup PR should reconcile `simplify.md`'s prose with the agent enum — out of scope here.

## 10. Files to touch

**New:**
1. `plugins/uberdev/commands/ubersimplify.md` — preflight (git repo, clean tree, `--no-issues`+`--no-report` sink guard) + `Skill(uberdev:ubersimplify-pipeline)` handoff. `allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]` (matches the simplify alias-row template).
2. `plugins/uberdev/skills/ubersimplify-pipeline/SKILL.md` — six-phase orchestration.
3. `plugins/uberdev/skills/ubersimplify-pipeline/aggregate.py` — lens-aware dedup + dual-envelope emitter.
4. `docs/rfc/0008-ubersimplify-command.md` — this doc.
5. `tests/ubersimplify.test.sh`, `tests/ubersimplify-aggregate.test.sh` — mirror `uberscan{,-report}.test.sh`.

**Modify:**
6. `plugins/uberdev/lib/chunk.py` — moved from `skills/uberscan-pipeline/chunk.py`.
7. `plugins/uberdev/skills/uberscan-pipeline/SKILL.md` — chunk.py path → `lib/chunk.py`.
8. `tests/uberscan-chunk.test.sh` — chunk.py path → `lib/chunk.py`.
9. `plugins/uberdev/agents/findings-to-issues.md` — add `ubersimplify-aggregate` to the accepted-source set (lines 28 + 41).
10. **Aliases (5 surfaces, 10 → 11):** `lib/aliases-sync.sh` (new row), `commands/install-aliases.md` (desc + table + canonical loop), `commands/uninstall-aliases.md` (desc + `SHORTS`), `README.md` (alias list + counts at lines 68 & 253), `tests/aliases.test.sh` (loops + count assertions).
11. **Version 0.32.0 → 0.33.0 (4 files):** `plugins/uberdev/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` badge, `CHANGELOG.md` (new `## [0.33.0]` section). Plus git tag + GitHub Release after merge.

## 11. Testing (TDD)

- **`ubersimplify-aggregate.test.sh`** — lens-merge dedup (same `file:line` flagged by 2 lenses → one row, `Reuse+Quality`, max severity); both envelopes emitted with the correct `source=` string; leftover filter (only `disposition != APPLIED` blocker rows reach the issue aggregate).
- **`ubersimplify.test.sh`** — command preflight refuses outside a repo and on a dirty tree; `--audit-only` skips the branch/PR phases; flag parsing; circuit-breaker exit mapping; zero-commit path deletes the temp branch and opens no PR.
- **`uberscan-chunk.test.sh`** — still green after the chunk.py move (path update only).
- **`aliases.test.sh`** — 11-alias consistency across all surfaces.
- Run the full `tests/*.sh` suite; no skips.

## 12. Alternatives considered

- **Direct commits on the current branch** (literal `/simplify` semantics scaled up) — rejected as default: a repo-wide sweep landing unreviewed on the working branch is too high-blast-radius. Available conceptually but not implemented; the PR gate is the safe default.
- **One giant `code-fixer` over the whole aggregate** — rejected: a single mega-commit is unreviewable and loses module boundaries; per-chunk commits map cleanly to reviewable units.
- **Audit-only (uberscan clone)** — rejected as default (user explicitly wants fixes), but preserved as `--audit-only`.
- **Fork `chunk.py`** — rejected for SSOT; extracted to `lib/` instead.

## 13. Migration & compatibility

Purely additive. No change to `/simplify`, `/uberscan`, or `findings-to-issues` default behavior (the new accepted source is an allow-list extension; the chunk.py move is path-only and test-guarded). New label `ubersimplify-finding` creates an independent backlog.
