---
description: "Create a GitHub issue with classification, codebase investigation, duplicate search, and label/scope validation"
argument-hint: "<description> [--no-explore]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Create GitHub Issue

User's description: $ARGUMENTS

**Usage:** `/issue <description> [--no-explore]`

Auto-classifies → investigates the codebase → checks duplicates (full-text, incl. closed) → validates labels + scope against repo reality → drafts → confirms → creates → offers `/solve` as follow-up.

## Phase 0: Detect repo + parse flags

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
NO_EXPLORE=$(echo "$ARGUMENTS" | grep -qE '\-\-no-explore' && echo 1 || echo 0)
DESC=$(echo "$ARGUMENTS" | sed -E 's/ *--no-explore//g')
```

Work with `$DESC` from here on — the flags shouldn't bleed into the issue body.

## Phase 1: Classify

Parse `$DESC`. Determine:

- **Type** — `fix` (bug/broken), `feat` (new capability; covers "enhancements"), `chore` (cleanup), `refactor` (structural-only, no behavior change)
- **Candidate scope** (one word, validated in Phase 4)
- **Core problem** — one-sentence distillation
- **Preliminary tier** for the eventual `/solve` handoff: `trivial` / `small` / `medium` — based on how localized the ask sounds *before* investigation

> `enhancement` is a **label**, never a commit type. Titles always use `feat(scope):` / `fix(scope):` / `chore(scope):` / `refactor(scope):`.

## Phases 2–4: Parallel Investigation

Phases 2, 3, and 4 are **read-only and independent** — they don't share state. When `NO_EXPLORE=0`, Phase 2 itself dispatches **two** Task agents (`research-codebase`, `research-patterns`); together with Phase 3 and Phase 4 that is **four** Task agents fanned out **in a single assistant turn** (one message, four `Task` tool_use blocks). Phase 4.5 aggregates all four returns. When `NO_EXPLORE=1`, Phase 2 collapses to inline Grep/Glob and the fanout shrinks to Phase 3 + Phase 4 only (two Task agents in one message).

## Phase 1.5: Pre-fanout — resolve variables (CRITICAL)

Subagents have no shell context, so resolve every variable here and interpolate literal values into each brief.

```bash
# Already resolved in Phase 0: $REPO, $DESC, $NO_EXPLORE
KEYWORDS="<top 3-5 keywords from $DESC, space-separated>"
COMMITLINT=$(find . -maxdepth 3 \( -name "commitlint.config.js" -o -name "commitlint.config.cjs" -o -name "commitlint.config.mjs" -o -name "commitlint.config.ts" \) -not -path "*/node_modules/*" | head -1)
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nohead)"
SUMMARY_DIR=".uberdev/research/run-$RUN_ID"
mkdir -p "$SUMMARY_DIR"
echo "REPO=$REPO"; echo "DESC=$DESC"; echo "KEYWORDS=$KEYWORDS"; echo "NO_EXPLORE=$NO_EXPLORE"; echo "COMMITLINT=$COMMITLINT"; echo "RUN_ID=$RUN_ID"; echo "SUMMARY_DIR=$SUMMARY_DIR"
```

Every Phase 2-4 agent brief below interpolates these literal resolved values (including `$SUMMARY_DIR` resolved as e.g. `.uberdev/research/run-20260429-143022-604fdb3`); never `$VAR` references.

## Phase 2: Investigate Codebase

Investigate the codebase for the issue described in `$DESC` (resolved). Repo is the resolved `$REPO`. NO_EXPLORE flag is the resolved `$NO_EXPLORE` (0 or 1).

**Gate the depth:**

- If `NO_EXPLORE=1` (literal `1` in the brief) → shallow: Grep + Glob only, inline (no Task dispatch). The bug template's `## Likely root cause` falls back to the placeholder string `[shallow mode — no fanout run; root cause to be confirmed in /brainstorm]` (Phase 5 handles the substitution).
- Else → dispatch a 2-agent parallel fanout (`research-codebase` + `research-patterns`) as Task() calls **in the same single message as the Phase 3 (Duplicate Search) and Phase 4 (Label/Scope Validation) Task() calls** — i.e. all four agents fan out together in one message. Each brief carries the literal resolved values for `issue_body` (the user's `$DESC` plus type/scope from Phase 1), `working_dir` (the absolute repo root), and `summary_dir` (the literal resolved value of `$SUMMARY_DIR`, e.g. `.uberdev/research/run-20260429-143022-604fdb3`).

Each research agent writes its summary to `<summary_dir>/<artifact>.md` (`codebase.md` and `patterns.md` respectively) and returns the universal YAML block per the orchestrator contract. The producer (Phase 4.5) reads the YAML returns and the summary files; it holds pointers, not raw research content.

Either path must produce a **Likely area** list with real file paths and symbol names. Never guess paths. If you can't find anything relevant, say so explicitly in the draft rather than inventing.

The investigation also refines the preliminary tier from Phase 1: if investigation shows the change sprawls across ≥3 packages, bump the tier up.

## Phase 3: Duplicate Search — full-text, includes closed

Run a command shaped like:

```bash
gh search issues --repo TheFJK/UberDev "auth login token" --limit 10 --json number,title,state,url
```

Review results:

- **Open match** → show the URL, ask whether to comment on it or close-as-dup instead of creating a new issue.
- **Closed match** → potential **regression** signal. Include the closed issue URL in the new issue's `## Related` section.

## Phase 4: Label + scope validation against repo reality

Run a command shaped like:

```bash
gh label list --repo TheFJK/UberDev --limit 100 --json name,description > /tmp/issue-labels-$$.json
```

If `$COMMITLINT` resolved to an empty string in Phase 1.5, skip scope validation; otherwise use the resolved literal path (e.g. `./commitlint.config.ts`).

- **Labels:** open `/tmp/issue-labels-$$.json`, pick the base (`bug` for `fix`, `enhancement` for `feat`) **only if it exists in the repo**, then add context labels by matching investigation keywords against real label names (e.g., `infrastructure`, `dx`, `security`, `docs`). Never invent labels.
- **Scope:** if a commitlint path was provided in the brief, Read it, extract the `scope-enum` array, and constrain the Phase 1 scope pick to that list. If the derived scope isn't in the list, flag to the user and propose the closest match.

## Phase 4.5: Aggregate

Wait for all dispatched agents to return (4 agents when `NO_EXPLORE=0`; 2 agents when `NO_EXPLORE=1`). Reconcile their reports:

- **`research-codebase` summary (`codebase.md`)** → drives the bug template's `## Likely root cause` symptom/mechanism/owning-code triple AND the `## Likely area` list. Required for `fix` issues; if `BLOCKED`, abort the fanout with a diagnostic and prompt the user to retry or pass `--no-explore`.
- **`research-patterns` summary (`patterns.md`)** → drives the `## Related` section's prior-pattern bullets and informs the causal chain when prior bugs exist. Optional — if `BLOCKED`, log a one-line warning and continue without it.
- **Phase 3 output** → `## Related` section closed/open issue links, plus regression flagging if a closed issue matches.
- **Phase 4 output** → final label set + validated scope (or a flag if commitlint scope-enum doesn't include the proposed scope).

If any agent returns a blocking question (e.g., "open match found, comment instead?") raise it to the user **before** drafting Phase 5.

## Body authoring rules — WHAT, not HOW

The issue body says *what* is broken or wanted; it never says *how* to fix it. Specifically: no implementation checklists, no step-by-step TODOs, no fix designs, no code snippets that would belong in a PR. Causal explanation (symptom → mechanism → owning code) is in scope. Implementation strategy is `/uberdev:brainstorm`'s job.

This boundary is enforced both by the templates below (the bug template's `## Likely root cause` is a causal triple; the feat template's `## What changes` describes externally visible result, not implementation) and by the rules subsection at the end of this file.

## Phase 5: Draft Issue

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

<!-- AUTHORING NOTE (do not include in rendered issue body): For non-trivial bugs, expand mechanism into a 5 Whys causal chain (each rung citing a file+symbol). -->
<!-- AUTHORING NOTE (do not include in rendered issue body): Bare file-path lists are forbidden in this section — use `## Likely area` for those. The triple is the smallest causal unit; this rule is a hard contract enforced by `tests/issue-causal-fanout.test.sh`. -->

## Likely area

- `path/to/File` — `ClassName.methodName()` — [why relevant]

## Reproduction

1. [Steps]

## Related

- [Any closed/open issues from Phase 3, else "none"]

**Triage hint:** <trivial|small|medium>
```

> **`--no-explore` placeholder.** When `NO_EXPLORE=1` and type=`fix`, substitute the entire `## Likely root cause` section body with the literal string `[shallow mode — no fanout run; root cause to be confirmed in /brainstorm]` (one paragraph, no bullets). The section heading itself stays. Reader knows root cause was deferred, not omitted.

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
```

## Phase 6: Confirm

**STOP and show the draft to the user.** Wait for confirmation, edits, or approval. Do not create the issue yet.

## Phase 7: Create issue

```bash
ISSUE_URL=$(gh issue create \
  --title "<type(scope): description>" \
  --label "<comma,separated,labels>" \
  --body "$(cat <<'EOF'
<body from Phase 5>
EOF
)")
echo "$ISSUE_URL"
ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
```

```bash
if [ -z "$ISSUE_NUM" ]; then
  echo "error: gh issue create did not return a parseable URL: '$ISSUE_URL'" >&2
  echo "error: research artifacts remain at $SUMMARY_DIR (not bound to an issue)" >&2
  return 1
fi
if [ -d "$SUMMARY_DIR" ]; then
  if ! mv "$SUMMARY_DIR" ".uberdev/research/issue-$ISSUE_NUM" 2>/dev/null; then
    # mv failed (typically cross-filesystem EXDEV; could also be perms/disk).
    if cp -R "$SUMMARY_DIR" ".uberdev/research/issue-$ISSUE_NUM"; then
      echo "warning: SUMMARY_DIR rename used cp+rm fallback (cross-filesystem)" >&2
      if ! rm -rf "$SUMMARY_DIR"; then
        echo "warning: cp succeeded but rm failed; both copies remain on disk" >&2
      fi
    else
      echo "error: both mv and cp failed; research artifacts remain at $SUMMARY_DIR (manual cleanup required)" >&2
      return 1
    fi
  fi
fi
```

This binds research artifacts to the issue number atomically (or via cp+rm fallback). `/uberdev:brainstorm` looks up `.uberdev/research/issue-<N>/` keyed on the issue number to short-circuit duplicate research.

## Phase 8: Offer follow-up

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
- **Always confirm** — show the full draft, wait for explicit approval before `gh issue create`.
- **No screenshots section** — user adds those manually after creation if needed.
- **WHAT/HOW boundary enforced** — issue body never contains an implementation checklist or fix design; that work belongs in `/uberdev:brainstorm`. Bug template's `## Likely root cause` is a causal triple (symptom/mechanism/owning code), not a file list. Feat template's `## What changes` describes externally visible result, not implementation strategy.
