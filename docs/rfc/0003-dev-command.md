# RFC 0003 — `/dev`: Prototype Fast-Lane Command

| Field          | Value                                                                                                                                                                                                                 |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**     | Draft (2026-05-16 — awaiting implementation)                                                                                                                                                                          |
| **Author**     | TheFJK                                                                                                                                                                                                                 |
| **Created**    | 2026-05-16                                                                                                                                                                                                             |
| **Targets**    | NEW: `plugins/uberdev/commands/dev.md`, `plugins/uberdev/skills/dev-pipeline/SKILL.md`, `tests/dev.test.sh`, `tests/dev-pipeline.test.sh`. MODIFIED: `commands/install-aliases.md`, `commands/uninstall-aliases.md`, `README.md`, `CHANGELOG.md`, `.claude-plugin/marketplace.json`, `plugins/uberdev/.claude-plugin/plugin.json` |
| **Supersedes** | —                                                                                                                                                                                                                      |
| **Builds on**  | `dispatching-parallel-agents` (one-message N-`Task()` primitive) · `subagent-driven-dev` (disjoint-Owns + controller-only-git discipline, borrowed as inline rules)                                                    |
| **Tracking**   | none — ad-hoc design (new plugin feature, not an issue resolution)                                                                                                                                                     |
| **Tier**       | Medium (new command + new skill, multi-file, no contract change to existing commands)                                                                                                                                  |

---

## 1. Summary

Add `/dev`, a new UberDev command that builds a **minimal working prototype or small function fast**, via parallel subagents, **deliberately skipping** the spec → plan → heavy-review pipeline that `/solve` and `/turbo` run.

`/dev <free-text idea>` runs **in the current session**: a lead agent scope-gates the idea, decomposes it in-context into 1–4 independent chunks, builds them with parallel `Task()` subagents, integrates with controller-only git, runs **one light reviewer**, opens a PR labelled **`prototype`**, and **auto-files a "harden" issue** so the prototype debt is tracked, queryable, and `/solve`-able.

The product purpose: a fast lane for ideas too small to justify a brainstorm/spec/plan cycle, where the goal is a *working happy-path function* — not exhaustive edge-case coverage.

## 2. Motivation

### 2.1 The gap — no fast parallel light-review lane

A three-agent codebase audit (2026-05-16) established:

1. `/solve` has four tiers (`trivial` → `large`), but **every tier — even `trivial` — terminates in `finish-branch` → `gh pr create` → full `/review-pr`**, an unskippable 6-agent fanout (`post-impl-review/SKILL.md:89-101`). `trivial`/`small` are also **single-agent**. No "parallel agents + skip spec/plan + light review" path exists.
2. The parallel primitive is `dispatching-parallel-agents` — fire N `Task()` in one message, aggregate. `subagent-driven-dev` adds the safety discipline worth borrowing (disjoint "Owns" file-allowlists, controller-only git, one task per agent) **but requires a written plan doc with a `## Execution Waves` block** (`subagent-driven-dev/SKILL.md:18-27,63`). No doc-less parallel path exists.
3. `/review-pr` **cannot be made fast** — no flag skips its Phase 1 6-agent fanout. `/simplify`'s 3-agent fanout is the lightest existing review primitive.
4. The `prototype` label is **greenfield** — zero hits repo-wide. `gh label create --force` (idempotent) is the established label-creation idiom (`finish-branch/SKILL.md:287`).

`/dev` is therefore genuinely new behaviour, not a re-skin of an existing tier.

### 2.2 The solo-dev prototype workflow

UberDev's author solves nearly every issue they open within hours-to-days; issues function as a personal TODO queue ([[user_workflow_todo_queue]]). There is a recurring class of work — a small util, a single function, a throwaway-ish component to see if an idea pans out — where the full brainstorm → spec → plan → 6-agent-review machinery is pure overhead. Today the only options are `/solve trivial` (still single-agent, still full `/review-pr`) or building it by hand. `/dev` makes that class of work first-class: parallel, fast, and honestly labelled.

### 2.3 Design tension — the AAA quality bar vs prototype speed

The global `CLAUDE.md` sets an explicit "AAA Studio Perfection" bar: TDD-always, no band-aids, "MANDATORY: run `/review-pr` after pushing the PR. No exceptions." A literal reading forbids a fast-lane command outright.

The resolution is **not** "lower quality and hide it." It is to recognise a prototype as a **distinct artifact class** with a different, *explicit*, *labelled* bar — and a *tracked* path back to production. The `prototype` PR label plus the auto-filed harden issue are precisely that mechanism: the debt is visible (`gh pr list --label prototype`), enumerated (the "Deliberately not covered" list), and actionable (`/solve` the harden issue). Prototype code never masquerades as production code. This keeps `/dev` consistent with the quality-first ethos rather than violating it — see §3.1.

> **Constraint citation (verbatim — global `~/.claude/CLAUDE.md`, "Security — Non-Negotiable"):** *"Never implement an insecure pattern, even if explicitly asked. Refuse and explain."* `/dev`'s Quality Contract keeps security, secret-handling, and crash-hiding **as hard floors** — never in the relaxed column. A prototype is rough, never unsafe.

## 3. Design

### 3.1 The Quality Contract

The heart of the design. `/dev` output is governed by an explicit two-column bar, carried **verbatim** into every implementer-agent prompt and the light-reviewer prompt (the global AAA `CLAUDE.md` is also in those agents' context and will otherwise pull them to production-grade output).

| ✅ Relaxed for prototypes — *becomes the harden-issue backlog* | 🚫 Hard floors — *never relaxed; rough ≠ unsafe* |
| --- | --- |
| Edge cases, rare inputs, exhaustive error paths | **Security**: no injection / XSS / SSRF / path traversal / weak or hand-rolled crypto |
| Strict TDD red-green-refactor → **one happy-path smoke test** | No hardcoded secrets, tokens, credentials, or private URLs |
| DI, hexagonal ports/adapters, event-bus wiring → direct calls OK | No swallowed errors that **hide** a crash or data corruption |
| Config extraction for genuinely local one-off constants | The code must **actually run** and perform the happy path it claims |
| Retry / fallback for external calls → a single attempt is OK | Conventional Commits; no `--no-verify`; **no Claude attribution** in commits / PR body |
| RFC / ADR / extensive docs → the PR description suffices | No deletion / overwrite of unrelated existing files |
| Performance tuning | — |

**Why one light reviewer suffices (decision Q2):** the reviewer's entire scope is the **right-hand column plus "does it run."** It explicitly does not review the left-hand column — those are deliberate, tracked deferrals. A single focused agent covers that scope; a 6-agent fanout would spend five agents flagging intentionally-deferred work.

### 3.2 Command + skill architecture

Two new files, mirroring the established `command → skill` delegation pattern (`solve.md` → `solve-pipeline/SKILL.md`):

```
plugins/uberdev/commands/dev.md                # thin delegator
plugins/uberdev/skills/dev-pipeline/SKILL.md   # owns the 7-phase flow
```

**`commands/dev.md`** — frontmatter + a brief framing paragraph + invoke the `uberdev:dev-pipeline` skill. `$ARGUMENTS` stays in scope for the skill (as `solve.md` keeps it for `solve-pipeline`).

```yaml
---
description: "Fast lane for a minimal working prototype or small function. Decomposes the idea, builds it via parallel subagents in-session, runs one light review, opens a PR labelled `prototype`, and auto-files a harden issue. Skips spec/plan and full /review-pr by design."
argument-hint: "<idea description> [--no-pr] [--no-issue]"
allowed-tools: ["Bash", "Read", "Edit", "Write", "Task"]
---
```

Canonical name `/uberdev:dev`; short alias `/dev` added to `install-aliases.md` / `uninstall-aliases.md`.

**`skills/dev-pipeline/SKILL.md`** — single-file skill (prompt templates inlined; split out only if it grows). Owns argument parsing, the scope gate, decomposition rules, the implementer + reviewer prompt templates, git discipline, and the PR/label/issue sequence.

### 3.3 The pipeline

Runs in-session on a `proto/<slug>` branch. Seven phases.

**Phase 0 — Argument parse + scope gate + branch setup.**
- Parse `$ARGUMENTS`: extract `--no-pr`, `--no-issue`; remainder is the idea. Empty idea → usage message, stop.
- **Scope gate.** Stop and re-route to `/solve` or `/brainstorm` if the idea clearly exceeds prototype scope: multiple subsystems; needs a DB schema/migration; needs new cross-cutting architecture; estimated > ~6 files or > ~400 LOC; phrased as "build a platform/app/system" at multi-feature scale. There is **no `--force`** — if the gate trips, print the reason + suggested alternative, stop.
  - ✅ in-scope: "a debounce util", "parse ISO-8601 durations", "a `--json` flag that dumps config", "a small status-badge component".
  - ❌ out-of-scope: "build a billing system", "add multi-tenant auth", "a dashboard with charts + export + filters".
- **Branch setup.** Derive `<slug>` (kebab-case, ≤ ~5 words). If on the repo default branch, create + check out `proto/<slug>` **now**, before any commit. (Must precede Phase 3 so prototype commits never land on the default branch.)
- **Dirty-tree note.** Unrelated uncommitted changes → print a one-line notice, proceed; pollution is structurally prevented because Phase 3 stages explicit paths only.

**Phase 1 — Inline decomposition.** The lead splits the idea into **1–4 chunks**, each `{ id, goal, owns: [file allowlist] }`. Rules in §3.4. In-context only — nothing written to `docs/uberdev/plans/`.

**Phase 2 — Parallel build.** One `Task(subagent_type: general-purpose)` per chunk, **all in a single message** (the `dispatching-parallel-agents` invariant). Implementer prompt per §3.5.

**Phase 3 — Integrate, commit, verify.** The lead is the **sole git controller**:
- For each chunk in `id` order: `git add <exact reported paths>` (never `-A`), then `git commit -m "feat: <chunk goal> (prototype)"`. No Claude attribution trailer.
- A chunk that reported a blocker/failure → not committed; collected for the report; one quick lead fix-attempt if trivial, else surfaced honestly.
- After all chunk commits: run smoke tests together (detect the repo test runner; if none, exercise the entry path and note "no test runner — manual sanity check only").
- A failing smoke test → **one** lead fix pass → `fix:` commit. Still failing → surface honestly; do not claim success.

**Phase 4 — Light review.** One `Task(subagent_type: general-purpose)` — **not** `uberdev:code-reviewer` (that agent reviews against full AAA guidelines and would flag every deliberately-deferred item). Reviewer prompt per §3.5. A `BLOCKER` → one lead fix pass + `fix:` commit; still blocked → surface, do not push a broken PR.

**Phase 5 — PR + label + harden issue.** Skipped under `--no-pr`. Otherwise:
1. `git push -u origin proto/<slug>`.
2. `gh pr create --title "<imperative summary>" --body-file <tmp>` with a **provisional** body (§3.6) — the hardening-issue reference is a placeholder at this point. Capture PR `#N`.
3. `gh label create --force prototype --color D4C5F9 --description "Prototype-grade — built via /dev, needs hardening"` — idempotent, fail-soft with a warning (mirrors `finish-branch:287`).
4. `gh pr edit <N> --add-label prototype`.
5. Unless `--no-issue`: `gh issue create --title "Harden prototype: <thing> (PR #<N>)" --body-file <tmp> --label prototype` → capture `#M`.
6. `gh pr edit <N> --body-file <tmp>` — **finalize** the body with `#M` filled in (or "Hardening not tracked (`--no-issue`)" under `--no-issue`). PR-first ordering lets the issue title cite `#N`; the body is finalized once `#M` exists.
7. `gh` unavailable / not a git repo → commits preserved locally; push/PR/issue skipped with a clear user-visible warning. The build result is never lost.

**Phase 6 — Report.** Surface: branch, PR URL, harden-issue URL, chunks built, smoke-test status, the consolidated "Deliberately not covered" list, and the light-review verdict.

### 3.4 Decomposition rules

- **Disjoint Owns.** No file path appears in two chunks' `owns`. Two candidate chunks that would touch the same file → **merge them** (no fake parallelism).
- **Genuine independence only.** Decompose along real module/file seams. An indivisible single function is **one chunk** (degenerate case — still dispatched as a single `Task`; the lead never implements directly, keeping the controller/implementer split clean).
- **Cap 4.** The scope gate already removed large work; 4 is the prototype ceiling.
- New files are assigned to exactly one chunk. A pre-existing shared file needed by multiple chunks → either collapse those chunks, or have the lead make that one edit sequentially after the fanout.

### 3.5 Agent contracts

**Implementer (`general-purpose`, one per chunk).** Prompt contains: a `PROTOTYPE MODE` banner + the **full Quality Contract table verbatim**; the chunk goal; the Owns allowlist ("create/edit ONLY `<owns>`; do NOT touch sibling-owned paths `<union of siblings' owns>`"); "write one happy-path smoke test, skip edge cases"; "do NOT run git — the controller owns git"; an **output contract** (report: created/modified paths, the smoke-test command + pass/fail, a one-line `Deliberately not covered:` note, any blocker); and "if this chunk is larger than a prototype slice, stop and report — do not build a partial mess."

**Light reviewer (`general-purpose`, one).** Prompt: "Review against the **PROTOTYPE bar**, not production standards." Check **only**: (1) does it run / perform the happy path; (2) security red flags; (3) silent failures that hide a crash or data corruption. "Do NOT comment on missing edge cases, abstractions, test coverage, naming, style, performance — those are deliberately deferred." Output: verdict `PASS | BLOCKER`; blocker list with `file:line`; a short "noted for harden issue" list.

**Design risk + mitigation.** Both agent types inherit the global AAA `CLAUDE.md`. *Mitigation:* the loud `PROTOTYPE MODE` banner + verbatim contract; the output contract forces each implementer to *name* what it deliberately did not cover, making the relaxed column an explicit surfaced artifact rather than a silent omission.

### 3.6 Artifacts

**PR body:**

```markdown
## Prototype: <thing>

<one paragraph: what it does and how to use it>

⚠️ Built via `/dev` — **prototype-grade, not production**. Hardening tracked in #<M>.

## Deliberately not covered
- <consolidated edge cases / error paths / abstractions skipped>

## Test plan
- Happy-path smoke test: `<cmd>` → <pass | fail>
```

*The `#<M>` reference is a placeholder at PR-create time, filled in at Phase 5 step 6 once the harden issue exists; under `--no-issue` that line instead reads "Hardening not tracked (`--no-issue`)."*

**`prototype` label:** name `prototype`, colour `D4C5F9` (light purple — distinct from the plugin's existing `review-pr:pending` yellow and `review-pr-finding` red), description "Prototype-grade — built via /dev, needs hardening". Created idempotently via `gh label create --force`.

**Harden issue body:**

```markdown
Prototype shipped in #<N> (built via `/dev`). Needs hardening to the production bar.

## What it does
<short description>

## Gaps to close
- <not-covered list — edge cases, error handling, full tests, abstractions, config extraction>

## Hardening checklist
- [ ] Edge cases & error paths
- [ ] Full test coverage (TDD)
- [ ] Production patterns (DI, error handling, config extraction)
- [ ] Full `/review-pr` pass

Run `/solve` on this issue to bring the prototype to the AAA quality bar.
```

### 3.7 Flags

- `--no-pr` — build + commit on the branch; skip push/PR/issue. For "I just want the code locally."
- `--no-issue` — create the PR, skip the harden issue. PR body then states "Hardening not tracked (`--no-issue`)."

No other flags. Execution model, review depth, and test policy are fixed by design; parallelism is auto-decided; the scope gate replaces a `--force`. `/dev` is itself designed with prototype restraint — minimal surface.

### 3.8 Error handling & edge cases

| Situation | Behaviour |
| --- | --- |
| Empty idea text | Usage message, stop. |
| Scope gate trips | Print reason + suggested alternative, stop. No partial build. |
| Decomposition yields 1 chunk | Single `Task` dispatched; no fanout. Lead still never implements directly. |
| Implementer reports "bigger than a prototype slice" | Abort that chunk, surface it, suggest `/solve`. Sibling chunks proceed. |
| All implementers fail | No commits, no PR; report failure honestly. |
| Smoke test fails after one fix pass | Surface honestly; PR body shows `fail`; do not claim success. |
| No test runner in repo | Manual sanity-check of the entry path; note it in the PR body. |
| On default branch at start | `proto/<slug>` created before any commit (Phase 0). |
| Dirty working tree | Notice printed; proceed. Explicit-path staging prevents pollution. |
| `gh` missing / unauthenticated / not a git repo | Commits preserved locally; Phase 5 skipped with a warning. |

## 4. File impact summary

| File | Change |
| --- | --- |
| `docs/rfc/0003-dev-command.md` | NEW — this RFC. |
| `plugins/uberdev/skills/dev-pipeline/SKILL.md` | NEW — the 7-phase flow + prompt templates. |
| `plugins/uberdev/commands/dev.md` | NEW — thin delegator. |
| `plugins/uberdev/commands/install-aliases.md` | MOD — register the `dev` alias. |
| `plugins/uberdev/commands/uninstall-aliases.md` | MOD — deregister the `dev` alias. |
| `tests/dev.test.sh` | NEW — command-file structural assertions. |
| `tests/dev-pipeline.test.sh` | NEW — skill structural assertions. |
| `tests/install-aliases.test.sh` (if it enumerates aliases) | MOD — add `dev`. |
| `README.md` | MOD — version badge + `/dev` commands-list entry. |
| `CHANGELOG.md` | MOD — `## [0.27.0]` section. |
| `.claude-plugin/marketplace.json` | MOD — `plugins[0].version` → `0.27.0`. |
| `plugins/uberdev/.claude-plugin/plugin.json` | MOD — `version` → `0.27.0`. |

**Testing strategy.** Mirror the existing bash harness (`tests/*.test.sh`, `assert_grep` + structural helpers). `tests/dev.test.sh`: frontmatter valid; `description`/`argument-hint`/`allowed-tools` present; body delegates to `uberdev:dev-pipeline`. `tests/dev-pipeline.test.sh` (**structural**): Quality-Contract table present with both columns; all 7 phases present; single-message-fanout instruction present; `git add <paths>` discipline present and `-A` **absent**; controller-only-git instruction present; `gh label create --force prototype` present; harden-issue `gh issue create` present; scope-gate section present.

## 5. Migration / rollout

Per the project `CLAUDE.md` "Bump version EVERYWHERE" mandate, `/dev` is a user-facing feature → a **minor** bump `0.26.1 → 0.27.0` across all six locations: `plugin.json`, `marketplace.json`, the `README.md` badge, a `CHANGELOG.md` `## [0.27.0] — <date>` section, the git tag `v0.27.0`, and the GitHub Release. Plus a `/dev` entry in the README commands list.

Purely additive — no existing command, skill, or agent changes behaviour. No migration steps for existing users; the new command appears after the marketplace manifest updates.

## 6. Alternatives considered

### 6.1 Reuse `subagent-driven-dev` with a synthetic single-wave plan
Write a minimal plan file, hand it to SDD. **Rejected:** SDD enforces per-task strict TDD + two-stage (spec + quality) review per task — exactly the weight `/dev` exists to avoid — and writes the plan doc `/dev` deliberately skips. `/dev` borrows SDD's *discipline* (disjoint Owns, controller-only git) as inline rules instead.

### 6.2 Single-agent, no fanout
Simplest, but drops the user's core "parallel agents" requirement. **Rejected** as the headline model; folded in as the degenerate 1-chunk case (§3.4).

### 6.3 Chain `/dev` into `/review-pr`
**Rejected:** `/review-pr`'s Phase 1 6-agent fanout cannot be skipped and would defeat the "fast" goal. Full review is *deferred* (to the harden issue), not skipped-and-forgotten — the `prototype` label marks the deferral.

### 6.4 Background-session dispatch like `/solve`
Spawn a `claude --bg` session per `/dev`. **Rejected:** a prototype is a quick, watchable, interactive thing; in-session gives the fastest feedback with no `claude agents` monitoring overhead. (User-selected — decision Q1.)

### 6.5 Add a 5th `prototype` tier to `/solve` instead of a new command
**Rejected:** `/solve` is fundamentally issue-number-driven and `claude --bg`-dispatched; `/dev` is free-text-idea-driven and in-session. Bolting an in-session free-text mode onto `/solve` would fork its argument model and dispatch path. A separate, small command is cleaner and more discoverable.

## 7. Open questions

None. The four primary design forks were resolved with the user (decisions Q1–Q4, §9); the remainder (D5–D9) are author decisions grounded in the 2026-05-16 codebase audit. Scope is focused enough for a single implementation plan.

## 8. Risk / rollout

- **Risk: implementer agents over-engineer** (the global AAA `CLAUDE.md` is in their context). *Mitigation:* §3.5 — loud `PROTOTYPE MODE` banner, verbatim contract, output contract forcing an explicit "not covered" declaration.
- **Risk: `/dev` used for work that should be `/solve`.** *Mitigation:* the Phase 0 scope gate with concrete in/out-of-scope examples.
- **Risk: prototype debt accumulates unreviewed.** *Mitigation:* the auto-filed harden issue lands the debt in the personal TODO queue; `gh pr list --label prototype` and `gh issue list --label prototype` make the backlog queryable.
- **Rollback:** purely additive — deleting the two new files + reverting the manifest/version edits fully removes `/dev` with zero impact on existing commands.

## 9. Decision log

| # | Decision | Choice | Source |
| --- | --- | --- | --- |
| Q1 | Execution model | **In-session** — lead decomposes + fires `Task()` subagents in the current conversation; no `claude --bg`. | User. |
| Q2 | Review depth | **One light reviewer** — scope limited to "does it run + hard floors"; no `/review-pr`. | User. |
| Q3 | Tests | **Happy-path smoke test only** — one per built unit; no TDD red-green-refactor. | User. |
| Q4 | Harden tracking | **Auto-file a GitHub issue** `Harden prototype: … (PR #N)`, labelled `prototype`. | User. |
| D5 | Execution architecture | **Inline decompose + parallel `Task()` fanout**, mimicking `dispatching-parallel-agents`, borrowing SDD's disjoint-Owns + controller-only-git as inline rules. | Author (audit). |
| D6 | Decomposition output | **In-context only** — no plan file on disk. | Author. |
| D7 | Branch naming | **`proto/<slug>`** — distinct prefix; created before any commit if on the default branch. | Author. |
| D8 | Hard floors | Security, secret-handling, no-crash-hiding, "code must run" — **never relaxed**. | Author (global `CLAUDE.md`). |
| D9 | Published design artifact | This RFC (`docs/rfc/`, tracked). The brainstorm spec location `docs/uberdev/specs/` is gitignored "local-only", so the published artifact is the RFC. | Author (`.gitignore` + RFC-before-coding mandate). |
