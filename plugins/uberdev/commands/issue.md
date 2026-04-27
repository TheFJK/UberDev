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

## Phase 2: Investigate Codebase

**Gate the depth:**

- If `$NO_EXPLORE=1` → shallow: Grep + Glob only.
- Else if type=`feat` with multi-module scope, OR type=`fix` whose title hints at `refactor`/`migrate`/`rewrite`/`architecture` — spawn the **Explore** subagent (per CLAUDE.md: ">3 queries → Explore").
- Else → Grep + Glob directly.

Either path must produce a **Likely area** list with real file paths and symbol names. Never guess paths. If you can't find anything relevant, say so explicitly in the draft rather than inventing.

The investigation also refines the preliminary tier from Phase 1: if investigation shows the change sprawls across ≥3 packages, bump the tier up.

## Phase 3: Duplicate Search — full-text, includes closed

```bash
# Extract top 3-5 keywords from $DESC, space-separated (not quoted)
KEYWORDS="<chosen keywords>"
gh search issues --repo "$REPO" $KEYWORDS --limit 10 --json number,title,state,url
```

Review results:

- **Open match** → show the URL, ask whether to comment on it or close-as-dup instead of creating a new issue.
- **Closed match** → potential **regression** signal. Include the closed issue URL in the new issue's `## Related` section.

## Phase 4: Label + scope validation against repo reality

```bash
gh label list --limit 100 --json name,description > /tmp/issue-labels-$$.json

# Locate commitlint config if present
COMMITLINT=$(find . -maxdepth 3 \( -name "commitlint.config.js" -o -name "commitlint.config.cjs" -o -name "commitlint.config.mjs" -o -name "commitlint.config.ts" \) -not -path "*/node_modules/*" | head -1)
```

- **Labels:** open `/tmp/issue-labels-$$.json`, pick the base (`bug` for `fix`, `enhancement` for `feat`) **only if it exists in the repo**, then add context labels by matching investigation keywords against real label names (e.g., `infrastructure`, `dx`, `security`, `docs`). Never invent labels.
- **Scope:** if `$COMMITLINT` is set, Read it, extract the `scope-enum` array, and constrain the Phase 1 scope pick to that list. If the derived scope isn't in the list, flag to the user and propose the closest match.

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

[Analysis from Phase 2 — connect the symptom to specific code]

## Likely area

- `path/to/File` — `ClassName.methodName()` — [why relevant]

## Reproduction

1. [Steps]

## Related

- [Any closed/open issues from Phase 3, else "none"]

**Triage hint:** <trivial|small|medium>
```

### Feature (`feat`) — covers enhancements

**Title:** `feat(scope): description`
**Labels:** `enhancement` + matched context labels

```markdown
## Summary

[What and why]

## Relevant code

- `path/to/File` — `ClassName` — [how it relates]

## Proposed approach

[Implementation strategy informed by Phase 2]

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
