---
description: "Create a GitHub issue with classification, codebase investigation, duplicate search, and label/scope validation"
argument-hint: "<description> [--no-explore]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Create GitHub Issue

User's description: $ARGUMENTS

**Usage:** `/issue <description> [--no-explore]`

Auto-classifies → dispatches **two Task agents** in a single assistant turn (`uberdev:codebase-scout` + `uberdev:triage-scout`, both running on inherit — the session model) → drafts the body inline from their YAML returns → confirms with the user → creates → offers `/solve` as follow-up. Median wall-clock under 30s.

## Phase 0: Detect repo + parse flags

<!-- Prereqs (gh, jq) verified at session start by hooks/session-start. The
     previous `command -v gh` block here was theatre — Claude reads command
     files as instructions, not bash, so the check was never actually executed
     at command-invocation time. Real runtime guards live in the session-start
     hook (jq fails the hook fast; gh injects a one-time warning when missing). -->

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
```

**Parse the flags MODEL-SIDE — never through a shell fence.** Scan the tokens of
the user's description (rendered after "User's description:" at the top of this
file): if a `--no-explore` token is present, drop it and print this deprecation
notice to the user verbatim —
`notice: --no-explore is deprecated; the default fanout is now 2 scouts. Removal target: v1.0.0`
— then everything else, in order, is `$DESC` (the same model-side token-scan
parse dev-pipeline Phase 0 uses). The description is untrusted free text:
echoing the raw arguments through a double-quoted shell fence (the old
`echo`-into-`sed` shape) hands any `$(...)` or backticks inside a description
to the shell. Model-side parsing keeps it data; the only bash in this phase is
the `gh repo view` repo probe above.

Work with `$DESC` from here on — the flags shouldn't bleed into the issue body.

## Phase 1: Classify

Parse `$DESC`. Determine:

- **Type** — `fix` (bug/broken), `feat` (new capability; covers "enhancements"), `chore` (cleanup), `refactor` (structural-only, no behavior change)
- **Candidate scope** (one word, validated in Phase 2 via `uberdev:triage-scout`)
- **Core problem** — one-sentence distillation
- **Preliminary tier** for the eventual `/solve` handoff: `trivial` / `small` / `medium` — based on how localized the ask sounds *before* investigation

> `enhancement` is a **label**, never a commit type. Titles always use `feat(scope):` / `fix(scope):` / `chore(scope):` / `refactor(scope):`.

## Phase 2: Dispatch the two scouts (single assistant turn)

Phase 2 dispatches **two Task agents** in a single assistant turn (one message, two `Task` tool_use blocks): `uberdev:codebase-scout` and `uberdev:triage-scout`. Both pin `model: inherit` in their frontmatter, so they run on the session model (Opus 4.8 1M). Their returns are inline YAML; nothing is persisted to disk.

> **Model override.** To force a specific subagent model regardless of the session, set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` as a global override (tracked at `affaan-m/everything-claude-code#173`).

Each brief carries the literal resolved values for `description` (the user's `$DESC` from Phase 0), `issue_type` (from Phase 1 classification), `working_dir` (the absolute repo root), and `repo_slug` (the resolved `$REPO`).

- **`uberdev:codebase-scout`** — receives `{description, issue_type, working_dir, model_hint: inherit}` and returns YAML with `likely_area: [paths]` and (if `issue_type=fix`) `likely_root_cause: "one-line hypothesis"`. Drives the bug template's `## Likely area` and `## Likely root cause` sections.
- **`uberdev:triage-scout`** — receives `{description, issue_type, working_dir, repo_slug, model_hint: inherit}` and returns YAML with `duplicates: [{number, title, state}]`, `valid_labels: [...]`, `valid_scope: "..."`, `commitlint_present: true|false`. Drives the duplicate section, the `--label` flags, and the title scope. (`issue_type` is required so the scout picks the base label — `bug` for `fix`, `enhancement` for `feat` — without re-classifying.)

If the codebase scout returns `status: BLOCKED` (no real paths grounded), the main thread substitutes `"No clear area identified — defer to /brainstorm"` in the `## Likely area` section. **Never invent paths.**

If the triage scout returns `status: DONE_WITH_CONCERNS` for `valid_labels` (e.g. `gh label list` failed), the main thread proceeds without a `--label` flag and notes the omission to the user before Phase 4.

## Phase 3: Compose body from scout returns

Parse both YAML returns from Phase 2 and:

1. Pick the bug or feat template based on the Phase 1 classification.
2. Insert `## Likely area` (unconditional, from `codebase-scout.likely_area`).
3. For `fix` issues, insert `## Likely root cause` populated with the one-line `codebase-scout.likely_root_cause`. **Do not** generate a Symptom/Mechanism/Owning-code triple here — the bug template's existing causal-triple labels remain in the file as a hard contract, but populating them is `/uberdev:brainstorm`'s job. Authoring note in the rendered template makes this explicit.
4. Add `## Possible duplicates` only if `triage-scout.duplicates` is non-empty. Closed matches get a regression-warning suffix.
5. Set `--label` flags on `gh issue create` from `triage-scout.valid_labels`.
6. Use `triage-scout.valid_scope` in the title's `<type(scope):>` prefix.
7. **Do not** include the deprecated "Current ecosystem", "Constraints", or "Security signals" headings — they are removed from the templates entirely (see Phase 4 templates below).
8. Emit the **scope declaration** as the last line of the body: `<!-- uberdev-scope v=1 files=<comma-joined paths> -->`. List the files a fix is expected to **change** — never the files cited as evidence. `lib/solve_triage.py` reads this block as fact and sizes the solver fleet off it (1 agent vs 33), falling back to a prose heuristic only when it is absent, so the declaration is the cheapest accuracy in the pipeline. When the scouts return nothing concrete enough to name, emit `files=` with an empty value: that is a recorded "scope not known yet", and it is always better than a guess. Being an HTML comment it renders invisibly, so it costs a human reader nothing.

If any blocking concern surfaces (e.g. an open duplicate match), raise it to the user **before** drafting Phase 4.

## Body authoring rules — WHAT, not HOW

The issue body says *what* is broken or wanted; it never says *how* to fix it. Specifically: no implementation checklists, no step-by-step TODOs, no fix designs, no code snippets that would belong in a PR. Causal explanation (symptom → mechanism → owning code) is in scope. Implementation strategy is `/uberdev:brainstorm`'s job.

This boundary is enforced both by the templates below (the bug template's `## Likely root cause` is a causal triple; the feat template's `## What changes` describes externally visible result, not implementation) and by the rules subsection at the end of this file.

## Phase 4: Draft Issue

Show the user a complete draft BEFORE creating.

### Bug (`fix`)

**Title:** `fix(scope): concise description`
**Labels:** `bug` + matched context labels

```markdown
## Bug

[Clear description — what's broken]

## Expected behavior

[What should happen]

## Observed behavior

[What actually happens]

## Severity

- [ ] P0 — pages on-call, system down
- [ ] P1 — major feature broken, needs fast fix
- [x] P2 — normal bug (default; uncheck if otherwise)
- [ ] P3 — minor / cosmetic

## Likely root cause

- **Symptom:** [observable failure mode in user-facing terms]
- **Mechanism:** [the specific code/data path that produces the symptom; cite a concrete artifact such as a function call site, log line, or config value]
- **Owning code:** `path/to/File` — `Class.method()` — [why this is the assumption to challenge]

<!-- AUTHORING NOTE (do not include in rendered issue body): The codebase-scout populates a one-line hypothesis here at /issue creation time. The full Symptom/Mechanism/Owning-code triple is filled in by /uberdev:brainstorm at solve time when running on fresh code. -->

## Likely area

- `path/to/File` — `ClassName.methodName()` — [why relevant]

## Reproduction

1. [Steps]

## Related

- [Any closed/open issues from `triage-scout.duplicates`, else "none"]

**Triage hint:** <trivial|small|medium>

<!-- uberdev-scope v=1 files=path/to/one.ts,path/to/two.ts -->
```

### Feature (`feat`) — covers enhancements

**Title:** `feat(scope): description`
**Labels:** `enhancement` + matched context labels

```markdown
## Summary

[What and why]

## Relevant code

- `path/to/File` — `ClassName` — [how it relates]

## What changes

[The capability being added or the behavior being modified, described in WHAT terms — externally visible result, contract change, or new affordance. No implementation strategy. Implementation belongs in /uberdev:brainstorm.]

## Acceptance criteria

- [ ] [criterion]

## Related

- [Prior issues, if any]

**Triage hint:** <trivial|small|medium>

<!-- uberdev-scope v=1 files=path/to/one.ts,path/to/two.ts -->
```

### Chore (`chore`) / Refactor (`refactor`)

**Title:** `chore(scope): description` or `refactor(scope): description`
**Labels:** matched context (e.g., `infrastructure`, `dx`) — no default

```markdown
## Summary

[What needs doing and why]

## Relevant code

- `path/to/File` — [context]

**Triage hint:** <trivial|small|medium>

<!-- uberdev-scope v=1 files=path/to/one.ts,path/to/two.ts -->
```

## Phase 5: Confirm

**STOP and show the draft to the user.** Wait for confirmation, edits, or approval. Do not create the issue yet.

## Phase 6: Create issue

The body is delivered via `--body-file -` with the heredoc on stdin — **never**
the `--body` flag with a `"$VAR"` or `"$(…)"` expansion (the dev-pipeline hard
rule: issue bodies carry user-derived text, and stdin delivery keeps it opaque
data).
The heredoc delimiter is single-quoted so `$()`/backtick expansion stays
disabled inside the body.

```bash
ISSUE_URL=$(gh issue create \
  --title "<type(scope): description>" \
  --label "<comma,separated,labels>" \
  --body-file - <<'EOF'
<body from Phase 4>
EOF
)
echo "$ISSUE_URL"
ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
```

## Phase 7: Offer follow-up

Print a structured confirmation so the user can copy-paste the next action:

```
Issue #$ISSUE_NUM created: $ISSUE_URL
Labels: <comma,separated>
Triage hint: <tier>

Next step: /solve $ISSUE_NUM
→ spawned workflow: <trivial: direct edit | small: lightweight plan + TDD | medium: full brainstorm>
```

**Do not run `/solve` automatically** — always wait for the user.

## Rules

- **Investigate before drafting** — "Likely area" must reference real code, not guesses. Escalate to Explore for multi-module scope.
- **Full-text duplicate search** — `gh search issues`, include closed (regression evidence) — never `gh issue list --limit 30`.
- **Validate labels against repo reality** — `gh label list` first; never invent labels that don't exist.
- **Validate scope against commitlint** — if a scope-enum exists, pick from it; flag mismatches to the user.
- **Conventional commit titles only** — `feat`/`fix`/`chore`/`refactor` (plus `docs`/`test`/`perf`/`style` if appropriate). `enhancement` is a **label**, never a type.
- **Severity mandatory on bugs** — default P2; surface on-call concerns early.
- **Triage hint mandatory in every issue body** — `/solve` parses it to pick the tier without redoing classification.
- **Scope declaration mandatory in every issue body** — the trailing `<!-- uberdev-scope v=1 files=… -->` block names the files a fix is expected to CHANGE, and `lib/solve_triage.py` reads it as fact rather than scraping paths out of the prose. Left off, triage falls back to a heuristic and this repo's `path:line` evidence style makes every well-evidenced issue look bigger than it is (#614). A file list here is a size signal, not an implementation plan — it does not breach the WHAT/HOW boundary below, which is about the prose. When the change set is genuinely unknown, `files=` empty is the honest answer.
- **Always confirm** — show the full draft, wait for explicit approval before `gh issue create`.
- **No screenshots section** — user adds those manually after creation if needed.
- **WHAT/HOW boundary enforced** — issue body never contains an implementation checklist or fix design; that work belongs in `/uberdev:brainstorm`. Bug template's `## Likely root cause` is a causal triple (symptom/mechanism/owning code), not a file list. Feat template's `## What changes` describes externally visible result, not implementation strategy.
- **Model override** — to force a specific subagent model regardless of the session, set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` as a global override. Tracked at `affaan-m/everything-claude-code#173`.
