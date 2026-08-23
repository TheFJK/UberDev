---
description: "Create a GitHub issue with classification, codebase investigation, duplicate search, and label/scope validation"
argument-hint: "<description> [--no-explore]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Create GitHub Issue

User's description: $ARGUMENTS

**Usage:** `/issue <description> [--no-explore]`

Auto-classifies → dispatches **two Task agents** in a single assistant turn (`uberdev:codebase-scout` + `uberdev:triage-scout`, both running on inherit — the session model) → drafts the body inline from their YAML returns → **creates** → prints the issue URL and offers `/solve` as follow-up. Median wall-clock under 30s, in ONE turn.

**Autopilot (always ON).** `/issue` runs end to end and asks no approval question before `gh issue create`. Same precedent as `/merge`, where the `auto_confirm` config key is a documented no-op (`skills/using-uberdev/references/configuration.md`, the `auto_confirm` precedence entry), and the same principle as this repo's "No HARD-GATE approval checkpoints" row in `README.md`'s design-decisions table. Filing an issue is trivially reversible — close it, edit it — so the blast radius never justified a gate. There is exactly **one** halt, in Phase 5: the duplicate gate on `uberdev:triage-scout`'s return. It fails **closed**, so it halts on either of two verdicts — the search ran and found an **open** duplicate, or the search could not run at all and open duplicates were never ruled out. A gate whose predicate is unevaluable has cleared nothing. Scout degradations that leave that verdict decidable (`codebase-scout` `status: BLOCKED`, an empty `valid_labels` from a failed `gh label list`, a substituted scope) are **reported** in the Phase 7 result block and never promoted to gates. There is no config key and no `--confirm` flag: autopilot is unconditional.

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

If the codebase scout returns `status: BLOCKED` (no real paths grounded), the main thread substitutes `"No clear area identified — defer to /brainstorm"` in the `## Likely area` section. **Never invent paths.** This is a degradation, not a gate: record it as a `degradation:` line in the Phase 7 result block and carry on to Phase 3.

`triage-scout` returns **one** `status` field covering **two** independent probes (`agents/triage-scout.md`, "Failure modes"): a failed `gh label list` and a failed `gh search issues` both surface as `status: DONE_WITH_CONCERNS`, and the failed *search* reports `duplicates: []` — byte-identical to a search that ran and matched nothing. The status alone therefore never says which probe failed, and neither does the shape of `duplicates`. The field that does is `summary`, which the scout's return contract requires to note **which validations succeeded** — so a contract-compliant `DONE_WITH_CONCERNS` always names the probe that degraded. Classify the return on exactly one question — *did the duplicate search run to completion?* — here, before Phase 3, and carry the classification into the Phase 5 gate:

- **Duplicate state PROVEN.** The return affirms the search completed, by one of exactly two routes: `status: DONE` (the scout's contract routes every probe failure to a non-`DONE` status, so `DONE` is the affirmative for both probes), **or** `status: DONE_WITH_CONCERNS` whose `summary` names the degraded probe and the duplicate search is **not** among them — a failed `gh label list`, a commitlint-scope substitution. `duplicates` may now be read at face value.
- **Duplicate state UNKNOWN.** Everything else, because nothing else affirms the search completed: `status: BLOCKED`; a `status: DONE_WITH_CONCERNS` whose `summary` names the duplicate search as failed, rate-limited, truncated or partial; a `status: DONE_WITH_CONCERNS` whose `summary` is silent about which probe degraded (off-contract, and illegible in the one direction that decides the gate); or no parseable YAML return at all. Empty-but-unproven is **not** empty — and non-empty-but-unproven is **not** complete: a `duplicates` list is evidence the search *started*, never evidence it *finished*, so entries in it never upgrade UNKNOWN to PROVEN. A rate-limited page that came back with one closed match is precisely the state the gate exists to fail closed on. Re-dispatch `uberdev:triage-scout` **exactly once** with the identical brief: a rate limit or a transient 502 usually clears on the second look, and a `DONE` retry re-enters the gate with a decidable verdict at zero interaction cost. Exactly once, never a loop. If the retry is still unproven, the duplicate state is `UNKNOWN` for Phase 5, which halts on it. Never round `UNKNOWN` down to "no duplicates found".

The common degradation is a label-only one: `gh label list` failed, the search ran, and the `summary` says so — which classifies **PROVEN** with `valid_labels: []`. The main thread proceeds without a `--label` flag and records the omission as a `degradation:` line in the Phase 7 result block. It does **not** halt and it does **not** ask — labels are an enrichment, whereas the duplicate search is the gate's own input.

## Phase 3: Compose body from scout returns

Parse both YAML returns from Phase 2 and:

1. Pick the bug or feat template based on the Phase 1 classification.
2. Insert `## Likely area` (unconditional, from `codebase-scout.likely_area`).
3. For `fix` issues, insert `## Likely root cause` populated with the one-line `codebase-scout.likely_root_cause`. **Do not** generate a Symptom/Mechanism/Owning-code triple here — the bug template's existing causal-triple labels remain in the file as a hard contract, but populating them is `/uberdev:brainstorm`'s job. Authoring note in the rendered template makes this explicit.
4. Add `## Possible duplicates` only if `triage-scout.duplicates` is non-empty. Closed matches get a regression-warning suffix. When Phase 2 classified the duplicate state as `UNKNOWN` the list is partial whatever its length: an empty one leaves no section to add, and a non-empty one renders under a `search did not complete — this list may be incomplete` note rather than as a finished result. Either way the draft only ever reaches `gh issue create` if the user answered *file anyway* at the Phase 5 halt, which records the un-run check as a Phase 7 `degradation:` line.
5. Set `--label` flags on `gh issue create` from `triage-scout.valid_labels`.
6. Use `triage-scout.valid_scope` in the title's `<type(scope):>` prefix.
7. **Do not** include the deprecated "Current ecosystem", "Constraints", or "Security signals" headings — they are removed from the templates entirely (see Phase 4 templates below).
8. Emit the **scope declaration** as the last line of the body: `<!-- uberdev-scope v=1 files=<comma-joined paths> -->`. List the files a fix is expected to **change** — never the files cited as evidence. `lib/solve_triage.py` reads this block as fact and sizes the solver fleet off it (1 agent vs 33), falling back to a prose heuristic only when it is absent, so the declaration is the cheapest accuracy in the pipeline. When the scouts return nothing concrete enough to name, emit `files=` with an empty value: that is a recorded "scope not known yet", and it is always better than a guess. Being an HTML comment it renders invisibly, so it costs a human reader nothing.

Nothing in this phase halts. The one halt in the whole command is Phase 5's duplicate gate, evaluated against the Phase 2 classification of `triage-scout.duplicates` — after the draft exists, so a halt can show both what the gate found (or could not look at) and what would otherwise have been filed. Every concern that leaves that verdict decidable (a `BLOCKED` codebase scout, an empty `valid_labels`, a substituted scope) is a **degradation**: carry it into the Phase 7 result block and keep going. A triage scout whose *duplicate search* did not complete is not one of them: it makes the gate's own input unknown, so it halts in Phase 5 instead.

## Body authoring rules — WHAT, not HOW

The issue body says *what* is broken or wanted; it never says *how* to fix it. Specifically: no implementation checklists, no step-by-step TODOs, no fix designs, no code snippets that would belong in a PR. Causal explanation (symptom → mechanism → owning code) is in scope. Implementation strategy is `/uberdev:brainstorm`'s job.

This boundary is enforced both by the templates below (the bug template's `## Likely root cause` is a causal triple; the feat template's `## What changes` describes externally visible result, not implementation) and by the rules subsection at the end of this file.

## Phase 4: Draft Issue

Compose the complete draft. It is a record, not a prompt: it becomes the `--body-file -` payload in Phase 6, and it reaches the user's terminal on exactly one path — when the Phase 5 duplicate gate halts, on either of its two halting verdicts. On the autopilot path the draft is never printed; what prints is the Phase 7 result block, which carries the issue URL rather than the body.

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

## Phase 5: Open-duplicate gate (the only halt)

Evaluate one predicate against the Phase 2 `triage-scout` return, using that phase's PROVEN/UNKNOWN classification: does `duplicates` **provably** contain no entry whose `state` is `open`? The gate fails **closed** — only a proven absence clears it, so the predicate has three outcomes, two of which halt. Take the **first** branch below that matches; they are an ordered decision, not a menu.

- **No open duplicate** — Phase 2 classified the duplicate state PROVEN, and `duplicates` is empty or every entry is `state: closed`. Proceed **straight to Phase 6**. Do not print the draft here, do not ask for approval, do not end the turn. This is the autopilot path and it is the common one.
- **At least one open duplicate** — **STOP.** Print the Phase 4 draft, then every open match as `#<number> — <title> (open)`, and ask whether to file anyway, comment on the existing issue instead, or abandon. Do not run `gh issue create` until the user answers, and then run it **only** if the answer is *file anyway*. An answer is not an approval: two of the three answers end the run without creating anything. An open duplicate is a fact returned by `triage-scout`, not a judgement call, and a second copy of a live issue is the one outcome that closing it does not cleanly undo.
- **Duplicate state unknown** — Phase 2 classified it UNKNOWN and the single re-dispatch did not resolve it: `gh search issues` never demonstrably completed, so an empty `duplicates` means *we could not look*, not *we looked and found nothing*, and a non-empty one is a partial page rather than the answer. Reached only when no entry is `state: open` — an open match, even out of a search that may have been truncated, is a fact the branch above already halts on, and that branch names it and offers commenting, so it wins the overlap. **STOP the same way.** Print the Phase 4 draft, then `duplicate search unavailable — <the scout's own one-line reason from its summary>; open duplicates were NOT ruled out`, and ask whether to file anyway or abandon. Do not run `gh issue create` until the user answers, and then run it **only** if the answer is *file anyway*. Commenting is not offered here: there is no matched issue to comment on. This branch is the reason the gate is fail-closed — an unavailable search is precisely the state in which the un-ruled-out duplicate is most likely, and reporting it as a Phase 7 `degradation:` line would deliver the notice *after* the `gh issue create` the gate exists to hold back. A check that could not run has not passed.

Each answer has exactly one terminal state:

- **File anyway** — continue to Phase 6 unchanged. Reached from the unknown-state branch it additionally carries `degradation: duplicate search unavailable — filed without a duplicate check, at the user's answer` into the Phase 7 result block, so the record shows the check never ran.
- **Comment on the existing issue instead** — offered only on the open-duplicate branch. Post the Phase 4 draft as a comment on the matched issue with `gh issue comment <number> --body-file -`, the same stdin-heredoc delivery Phase 6 mandates, then print `Commented on #<number>: <comment-url>` and end the turn. Phases 6 and 7 do not run and no issue is created.
- **Abandon** — print `Abandoned: open duplicate #<number>. Nothing was created.` (open-duplicate branch) or `Abandoned: duplicate search unavailable. Nothing was created.` (unknown-state branch) and end the turn. Phases 6 and 7 do not run.

**Closed** duplicates never halt. They are regression evidence and already render as `## Possible duplicates` with the regression-warning suffix (Phase 3, step 4).

## Phase 6: Create issue

Reached on the autopilot path, or from Phase 5 when the user chose to file anyway. The other two Phase 5 answers already ended the turn, so this phase does not run for them.

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

## Phase 7: Report what was filed

Print a structured result block. It is the record of what got created and the copy-paste handle for the next action:

```
Issue #$ISSUE_NUM created: $ISSUE_URL
Labels: <comma,separated>
Triage hint: <tier>
degradation: <one line per scout degradation, plus the duplicate-search line when the Phase 5 unknown-state halt was answered "file anyway"; omit this line entirely when both scouts returned status: DONE>

Next step: /solve $ISSUE_NUM
→ spawned workflow: <trivial: direct edit | small: lightweight plan + TDD | medium: full brainstorm>
```

Never convert a `degradation:` line into a question — it is reported output, not a gate. A duplicate search that never completed is not one of these lines on the way in: it is the Phase 5 gate's own input, and it has already halted there. It appears here only as the *record* of a halt the user answered *file anyway*.

**Do not run `/solve` automatically** — always wait for the user. Autopilot covers `gh issue create` and stops there; dispatching a solver is a different blast radius and stays user-invoked.

## Rules

- **Investigate before drafting** — "Likely area" must reference real code, not guesses. Escalate to Explore for multi-module scope.
- **Full-text duplicate search** — `gh search issues`, include closed (regression evidence) — never `gh issue list --limit 30`. If the search itself cannot run, that is `UNKNOWN`, not "no duplicates": retry once, then halt at Phase 5. An unproven `duplicates: []` is never a clean bill of health, and an unproven non-empty list is never a complete one — matches prove the search started, never that it finished.
- **Validate labels against repo reality** — `gh label list` first; never invent labels that don't exist.
- **Validate scope against commitlint** — if a scope-enum exists, pick from it; flag mismatches to the user.
- **Conventional commit titles only** — `feat`/`fix`/`chore`/`refactor` (plus `docs`/`test`/`perf`/`style` if appropriate). `enhancement` is a **label**, never a type.
- **Severity mandatory on bugs** — default P2; surface on-call concerns early.
- **Triage hint mandatory in every issue body** — `/solve` parses it to pick the tier without redoing classification.
- **Scope declaration mandatory in every issue body** — the trailing `<!-- uberdev-scope v=1 files=… -->` block names the files a fix is expected to CHANGE, and `lib/solve_triage.py` reads it as fact rather than scraping paths out of the prose. Left off, triage falls back to a heuristic and this repo's `path:line` evidence style makes every well-evidenced issue look bigger than it is (#614). A file list here is a size signal, not an implementation plan — it does not breach the WHAT/HOW boundary below, which is about the prose. When the change set is genuinely unknown, `files=` empty is the honest answer.
- **Autopilot: never confirm** — `/issue` creates without an approval prompt and the draft is a record, not a question. The single exception is Phase 5's duplicate gate, which fails closed: it halts on an open duplicate **and** on a duplicate search that could not run, because a check that never ran has not passed. Scout degradations that leave that gate decidable are reported in the Phase 7 result block, never turned into gates. No config key, no `--confirm` flag — matching the `/merge` precedent where `auto_confirm` is a documented no-op.
- **No screenshots section** — user adds those manually after creation if needed.
- **WHAT/HOW boundary enforced** — issue body never contains an implementation checklist or fix design; that work belongs in `/uberdev:brainstorm`. Bug template's `## Likely root cause` is a causal triple (symptom/mechanism/owning code), not a file list. Feat template's `## What changes` describes externally visible result, not implementation strategy.
- **Model override** — to force a specific subagent model regardless of the session, set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` as a global override. Tracked at `affaan-m/everything-claude-code#173`.
