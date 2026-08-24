---
description: "Pre-merge stack gate. Packs every open non-draft PR onto ONE integration branch, then loops review → fix → re-review until the stack is green or repairing provably stops working, repairing red CI along the way. Once green it runs the /simplify three-lens pass, re-gates the polish and reverts it if it did harm, files everything it could not fix as GitHub issues, and bumps the version. Always parks the stack PR — never merges."
argument-hint: "[<level>] [--converge=<n>] [--no-converge] [--no-ci-fix] [--no-post-simplify-review] [--no-simplify] [--no-issues] [--no-bump] [--no-ci-gate] [--dry-run]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "MultiEdit", "Read", "Task", "Write"]
---

# /premerge — one stack, one loop, one bump, parked

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
Review, fix and gate then run **as a loop** rather than a straight line: the gate's
not-green branch repairs what it can and reviews again, so a stack that needs real
work reaches green instead of being parked with a live blocker still in it.

The `/simplify` three-lens pass runs **last and only on a green stack**: polishing
code that still carries a known bug is wasted work, and it buries the bug in
refactor noise. Because it is also the last thing to touch the branch, it is the
one phase whose output nothing else would check — so it re-probes CI, re-gates its
own commit, and **reverts itself** rather than parking a stack that was green
before the polish and broken after it.

**`/premerge` never merges.** It ends at a pushed, open, bumped stack PR — parked.
Landing it is `/merge`, and only when you say so.

## Usage

`/premerge [<level>] [flags]` — no arguments: every open non-draft PR, reviewed at `xhigh`.

| Argument | Meaning |
|---|---|
| `<level>` | Review effort for the built-in `code-review`: `low`, `medium`, `high`, `xhigh` (default), `max`. **Not a free dial** — see `## Effort levels are not a ladder` below before changing it. |
| `--converge=<n>` | How many **repair rounds** the loop may take: `1` to `6`, default `3`. N repairs cost N+1 reviews — the last review is the one that verifies the last repair, which is why nothing the loop writes ever ships ungated. Out of range is a **refusal, not a clamp** — running six rounds while you believe ninety-nine are coming is the silent substitution every other refusal here exists to prevent. |
| `--no-converge` | The same request as `--converge=1`: one wave-set of fixes, one re-review, the pre-loop behaviour. Spelled both ways because one reads as a dial position and the other as a mode. |
| `--no-ci-fix` | Suppress the CI **repair** only. The probe and the classification still run, so the gate still reports what CI said and the summary still names the failure class. A flag that blinded the gate as well would be a different, much worse flag. |
| `--no-post-simplify-review` | Skip the VERIFY step that re-probes and re-gates the simplify commit. The polish then ships on the strength of a gate that predates it — a state worth making deliberate rather than accidental. |
| `--no-simplify` | Stop at the clean gate. Skips Phase 4 entirely, VERIFY included. |
| `--no-issues` | Do not file findings as issues — the surviving blockers included. They are still reported in the run summary: unfiled, not unrecorded. |
| `--no-bump` | Skip Phase 5's version bump. The stack PR is still pushed and parked. |
| `--no-ci-gate` | Drop the CI-green term from the clean gate. Blocker count and mergeable state still gate. Use when the repo has no checks worth waiting on. |
| `--dry-run` | Run Phase 0's discovery and print the pack plan — which PRs, in what order, onto what base — then stop. No branch, no PR, no review, no writes. |

## The loop stops on evidence, not on a counter

The clean gate's not-green branch routes each failing term at something that can
repair it: the fixer waves at a surviving blocker, `uberdev:ci-failure-classifier`
and then `uberdev:ci-code-fixer` or `uberdev:ci-rebase-handler` at a red build, a
controller-owned merge of the base into the stack at `CONFLICTING`. Then it reviews
again. Before the loop the gate was single-shot, so any stack that needed real
fixing never reached green — which left the simplify phase behind that gate
structurally unreachable and silently never run, and left a red build unrepaired
altogether.

What ends the loop is a measurement, not a countdown. `STOP_NO_PROGRESS` fires on
an attempt that changed neither the blocker set nor the CI reason; `STOP_REGRESSED`
fires when our own fixes grew the blocker set. Both compare blocker **fingerprints**
across attempts rather than `file:line`, because a fix moves lines and a
location-keyed identity would report every survivor as brand new — the loop would
see infinite progress and never stop.

A third measurement catches what those two cannot. Both compare fingerprint sets
drawn from independent full-stack reviews, so neither can tell a defect the
fixers just wrote from one that was always there. `STOP_SELF_REFERENTIAL` fires
when, for two attempts running, at least half of the blockers a round returned
did not exist the round before **and** sit in files the previous repair
modified — the loop reviewing its own output. It reports `GROWTH=` on every
attempt so you can see the difference between a run that was still converging
and one that had started generating its own work. The findings that trip it are
filed as issues like every other survivor, not dropped.

Why that measurement has to exist at all: a reviewer asked *what is wrong with
this?* samples from an **unbounded** set, so a round that comes back with no
blockers is a property of the sample, never of the stack. Find → fix → re-find
has no fixed point, and a loop that terminates when the critic goes quiet is
terminating on nothing. `GROWTH=` stands in for the fixed point the loop does not
have: the fraction of a round's blockers that landed in text the **previous
round's own repair wrote**. At `1.00` the loop is reviewing its own output, and
the correct response to that is to **stop**, not to repair again.

`STOP_SELF_REFERENTIAL` pre-empts the budget stop deliberately, because *"it was
still winning, raise `--converge`"* and *"the loop was reviewing itself"* are
**opposite** operator responses — and an operator shown the budget stop for a run
that did the second will raise the budget on a loop that can never converge. For
the same reason the stop takes **two consecutive measured rounds** at or above
that half-mark, never one. Each review is a fresh sample, and the files most
likely to be resampled next round are exactly the ones the last repair touched,
so a single high round is equally consistent with a healthy convergence whose
repairs happen to be concentrated in a few files. Removing the two-round
requirement makes the detector stop loops that were working — the failure it
exists to avoid.

`GROWTH=` is a signal, not a proof. Attribution is at file granularity, so a
genuinely new defect elsewhere in a repaired file over-counts as growth; and a
round whose repair committed nothing leaves no scope list to attribute against,
so it prints `GROWTH=-` — *not measured*, which is a different answer from
`0.00`.

`--converge` is the runaway backstop behind those three, not the stop condition,
and that distinction is the answer to the hazard RFC 0021 originally refused a
loop over: *"the third automatic attempt is where a fixer starts 'fixing' the test."*
The attempt that achieves nothing is now caught **when it happens** rather than
assumed to be the third one, and the fixer agents are told outright that a test
they read as the wrong half is a finding to report and skip, never an obstacle to
delete.

Waiting on a build is not an attempt. `pending`, `unknown`, and the no-checks
window that a push opens are re-probed without spending fix budget, under a bound
of their own — so a check that never settles ends the run as **not green**, never
as a pass.

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
- **It will not loop forever.** The loop ends on the attempt that stopped making
  progress, made things worse, or began reviewing what its own repairs wrote;
  `--converge`'s ceiling of six is only the backstop behind those three, and
  waiting on CI has a bound of its own.
- **It will not weaken a test to clear a finding.** Making the evidence stop
  complaining is not fixing the bug. A fixer that honestly reads the test as the
  wrong half says so and skips, and the run records that as an answer.
- **It will not report a stack green on a simplify pass nothing verified.** The
  polish lands after every other gate in the run, so it is re-probed and re-gated
  on its own SHA — and reverted, not debugged, if it broke a stack that was green.
- **It will not lose what it could not fix.** A blocker the loop stopped on
  becomes an issue at BLOCKER tier with a backref to the stack PR, instead of a
  line in a summary that scrolls away.
- **It will not report green on evidence it could not read.** Every gate in the
  pipeline fails closed.

## Implementation

Invoke the `uberdev:premerge-pipeline` skill with `$ARGUMENTS` in scope. The skill
owns all six phases — pack, review, triage, the clean gate and its convergence
branch, verified simplify, bump+park — and the review→fix→gate loop that runs the
middle three until the stack is green or repairing provably stops working. This
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
