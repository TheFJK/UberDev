---
description: "Pre-merge stack gate. Packs every open non-draft PR onto ONE integration branch, reviews the combined result with the built-in /code-review, dispatches fixers at the blockers, files the rest as GitHub issues, and only once the stack is clean runs the /simplify three-lens pass and the version bump. Always parks the stack PR — never merges."
argument-hint: "[<level>] [--no-simplify] [--no-issues] [--no-bump] [--no-ci-gate] [--dry-run]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
---

# /premerge — one stack, one review, one bump, parked

`/premerge` is the gate a pile of open PRs passes through **before** anything lands.
It packs every open non-draft PR onto a single integration branch, opens ONE
`chore(stack): land #A #B …` PR, and then treats that combined branch as the unit
of review — because the defect classes that matter at landing time (two PRs
resolving the same next version, two PRs adding the same helper, one PR's rename
silently defeating another's guard) are **cross-PR by construction and invisible
to any per-PR review**.

Review is the **built-in `code-review` skill**, not uberdev's seven-agent fanout.
Findings split two ways: a correctness blocker gets a **dispatched fixer**, and
everything else — reuse, simplification, efficiency, altitude, conventions —
becomes a **GitHub issue**, so the polish is recorded without holding the stack.
The `/simplify` three-lens pass runs **last and only on a clean stack**: polishing
code that still carries a known bug is wasted work, and it buries the bug in
refactor noise.

**`/premerge` never merges.** It ends at a pushed, open, bumped stack PR — parked.
Landing it is `/merge`, and only when you say so.

## Usage

`/premerge [<level>] [flags]` — no arguments: every open non-draft PR, reviewed at `xhigh`.

| Argument | Meaning |
|---|---|
| `<level>` | Review effort for the built-in `code-review`: `low`, `medium`, `high`, `xhigh` (default), `max`. **Not a free dial** — see `## Effort levels are not a ladder` below before changing it. |
| `--no-simplify` | Stop after the clean gate. Skips Phase 4 entirely. |
| `--no-issues` | Do not file suggestion findings as issues. They are still reported in the run summary — unfiled, not unrecorded. |
| `--no-bump` | Skip Phase 5's version bump. The stack PR is still pushed and parked. |
| `--no-ci-gate` | Drop the CI-green term from the clean gate. Blocker count and mergeable state still gate. Use when the repo has no checks worth waiting on. |
| `--dry-run` | Run Phase 0's discovery and print the pack plan — which PRs, in what order, onto what base — then stop. No branch, no PR, no review, no writes. |

## Effort levels are not a ladder

The built-in reviewer resolves `model × level` to a **cell**, and the cells differ
in kind, not only in depth. On Opus-family models `xhigh` runs its ten finder
angles **inline with no subagents and no verify pass**, so every finding arrives
with `verdict` absent; `max` is the cell that fans out to agents *and* runs a
verifier vote per candidate. Choosing `max` therefore buys a machine-checkable
confidence signal that `xhigh` structurally cannot produce — and choosing `xhigh`
buys speed at the price of triaging on rank and category alone.

`/premerge` works correctly either way (`lib/premerge-findings.py` reads both
output contracts and both severity signals), and it **reports which signals it
actually got** — the `CATEGORY_BACKED` count in the triage line is how many
severities were machine-checked rather than judged. Read that number before
trusting a run's split.

## What it will not do

- **It will not merge.** Not the stack PR, not the originals, not on green, not
  on an approving review. There is no flag that makes it merge.
- **It will not close the originals.** They stay open and get exactly one
  supersession comment; their `Closes #N` references travel onto the stack PR so
  the underlying issues still close when *you* land it.
- **It will not drop a PR silently.** A candidate that cannot be packed is
  excluded **by number with a typed reason** and that reason is rendered into
  the stack PR body.
- **It will not report green on evidence it could not read.** Every gate in the
  pipeline fails closed.

## Implementation

Invoke the `uberdev:premerge-pipeline` skill with `$ARGUMENTS` in scope. The skill
owns all six phases (pack, review, triage, clean gate, simplify, bump+park). This
command performs only preflight validation, then hands off:

```bash
# Preflight
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: /premerge must run inside a git repository" >&2; exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "error: /premerge needs the gh CLI to discover and open pull requests" >&2; exit 2
fi
# A dirty tree cannot be packed onto a combine branch, and finding that out
# after the first merge would leave a half-built branch behind. Refuse early.
# `git status --porcelain` and not a pipe into a -q reader: this fence would
# EPIPE-race under pipefail on Linux CI (#404 class).
UBERDEV_PREMERGE_PORCELAIN="$(git status --porcelain)" || exit 2
if [ -n "$UBERDEV_PREMERGE_PORCELAIN" ]; then
  echo "error: /premerge refuses to build a stack over uncommitted work; commit or set it aside first" >&2
  exit 2
fi
# --no-simplify with --no-issues and --no-bump leaves review-and-fix only. That
# is a legal, useful mode (a pure blocker sweep), so it is NOT refused here —
# unlike /uberscan's --no-issues + --no-report, which would leave no sink at all.
```

Then invoke `Skill(uberdev:premerge-pipeline)` with the same `$ARGUMENTS`.

Design rationale and full topology in [`docs/rfc/0021-premerge-stack-integration.md`](../../../docs/rfc/0021-premerge-stack-integration.md).

<!--
Authoring hazards for this command and its pipeline skill, learned the hard way
elsewhere in this repo. Do not remove without reading the cited test.

  * The skill renderer substitutes `$ARGUMENTS` positionals into the WHOLE
    rendered body, single-quoted awk programs included. So an awk column
    reference — a dollar sign followed by a digit — is rewritten before awk ever
    parses it. Pass the column in with `-v cN=N` and reference `$cN` instead.
    Braces do not help: the renderer substitutes the braced spelling too (#404).
    Guarded by tests/skill-renderer-awk-collision.test.sh R1/R1b/R4, which reads
    this file too — which is why the hazard is DESCRIBED here rather than
    spelled out. A literal example would be a real occurrence, and the renderer
    would corrupt this very comment.
  * These fences run through /bin/zsh. `type -t` is a bashism (use `command -v`)
    and `BASH_REMATCH` is unset under zsh (`$match`) — tests/epipe-guard.test.sh
    L7. So is `for x in $SCALAR`, which zsh runs ONCE over the whole string;
    use `while IFS= read -r`.
  * Never pipe into an early-exiting reader (`| grep -q`) inside a fence that
    sets pipefail — tests/epipe-guard.test.sh E1/E4. Use a herestring.
  * `gh issue create --body "$VAR"` is banned; pipe via `--body-file -` —
    tests/epipe-guard.test.sh L9.
-->
