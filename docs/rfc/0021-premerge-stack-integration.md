# RFC 0021 — `/premerge`: the pre-merge stack gate

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-08-21 |
| **Tier** | Large (a new PR-phase command spanning command, skill, lib, one agent contract and the accepted-source SSOT) |
| **Target ver** | `0.53.0` |
| **Targets** | new `commands/premerge.md`; new `skills/premerge-pipeline/SKILL.md`; new `lib/premerge-findings.py`; `agents/findings-to-issues.md` (the `SUGGESTION` tier, the `premerge.defer.findings` origin row, the `premerge-aggregate` source); `agents/code-simplifier.md` (third sanctioned call site); `lib/report_primitives.py` (`ACCEPTED_SOURCES`); `lib/aliases-sync.sh`; `commands/install-aliases.md`; `commands/uninstall-aliases.md`; `skills/using-uberdev/references/configuration.md`; `plugins/uberdev/vendor.json`; `docs/rfc/0019` §2.1 counts; new `tests/premerge.test.sh`; `.github/workflows/test.yml` (both jobs); `README.md`; `CHANGELOG.md`; the six version-lock surfaces |
| **Complements** | RFC 0002 (the tiered-halt vocabulary this extends by one tier). `/review-pr` and `/simplify` are unchanged. |
| **Reuses** | `lib/review-consolidate.sh` (#470, `/review-pr` Phase 0) verbatim; `skills/merge-pipeline/lib/discover.sh` `discover_open_prs`; `agents/findings-to-issues.md`; `agents/code-simplifier.md`; `lib/bump-version.sh` |

---

## 1. Decision

**`/premerge` packs every open non-draft PR onto one integration branch, reviews
the combined result with the BUILT-IN `code-review` skill, fixes the correctness
blockers with dispatched agents, files the cleanup findings as GitHub issues,
runs the three simplify lenses only once the stack is clean, bumps the version
once for the whole stack, and parks the stack PR.**

It never merges. There is no flag that makes it merge.

## 2. Why a new command rather than a `/review-pr` flag

`/review-pr --consolidate` already packs PRs, and `/premerge` reuses that exact
library. The difference is not the packing — it is everything the packing is
*for*.

| | `/review-pr --consolidate` | `/premerge` |
| --- | --- | --- |
| Packing | an offer, declined by default under `--turbo` and no-TTY | unconditional; packing is the command |
| Review engine | uberdev's seven-agent Phase-1 fanout | the built-in `code-review` skill |
| Severity source | schema-v2 aggregates (`blocker`/`suggestion`) produced by uberdev agents | derived, because the built-in reviewer emits none |
| `suggestion` rows | dropped by `route_by_severity` | **filed**, at a new tier |
| Simplify pass | Phase 2, unconditional, before CI is even probed | Phase 4, gated on a clean stack |
| Version bump | not its job | one bump for the whole stack, on the stack branch |
| Trust trail | emitted; `/merge` reads it | **none** — see §7 |
| Ends at | a reviewed PR with a trust trail | a parked PR |

Folding these into `/review-pr` would mean a flag that changes the review engine,
the severity vocabulary, the phase order, the halt rules and the trust-trail
emission. That is a second command wearing the first one's name.

## 3. The problem it exists to solve

Three defect classes are **cross-PR by construction** and structurally invisible
to any per-PR review:

1. **Version collision.** N PRs cut from one base all resolve the same next
   version. Git auto-merges the identical edit with no conflict, so two intended
   releases silently collapse into one. `AGENTS.md` already responds by binding
   the bump to the *landing commit* and forbidding PR authors from bumping —
   which leaves an obvious gap: *something* has to do the bump, once, at landing
   time. Nothing did. `/premerge` Phase 5 is that something.
2. **Duplicate work.** Two PRs add the same helper under different names. Each
   review sees a reasonable new helper.
3. **Guard escape by rename.** One PR renames a file; another adds a guard whose
   corpus reads `git diff --name-only`, which collapses renames. Each PR is fine;
   the combination is not.

Reviewing the combination is the only place any of these is visible.

## 4. The severity rule and why it is where it is

The built-in reviewer emits **no severity field in either of its two output
contracts**. It emits an ordinal ranking, an optional `category` kebab slug, and
an optional `verdict` in `{CONFIRMED, PLAUSIBLE}` — and `verdict` is *confidence*,
not importance.

So `/premerge` derives severity, into the two-value vocabulary the rest of uberdev
already uses:

> **`blocker`** — a concrete path to wrong output, a crash, data loss, a security
> hole, or a broken build invariant.
> **`suggestion`** — everything else. Real, worth doing, not worth holding the
> stack for.

**The derivation is split deliberately.** Where the reviewer supplied a
`category`, `lib/premerge-findings.py` maps it — the reviewer's own cleanup
vocabulary (`reuse`, `simplification`, `efficiency`, `altitude`, `conventions`,
`test-coverage`, …) to `suggestion`, everything else to `blocker` — and **exits
non-zero** if the controller's severity contradicts it. Where no category exists,
the controller judges, per the rule above written down in the skill.

This is not a compromise; it is the point. A prose-matching heuristic over
`summary` and `failure_scenario` would be a confident-looking guess, and this
repo's own history says a guess nobody can contradict drifts until it is wrong in
one direction permanently. So the free-judgement path exists **only** where no
machine-checkable signal does, and it collapses to the checked path the instant
one appears. The run reports `CATEGORY_BACKED` — how many severities were checked
rather than judged — so an operator can see which regime a given run was in.

**Unfamiliar categories resolve to blocker.** A novel cleanup slug costs one
needless fixer dispatch; a novel correctness slug silently demoted to
`suggestion` ships the bug. The asymmetry is chosen, not incidental.

## 5. The `SUGGESTION` tier

`agents/findings-to-issues.md` drops `suggestion` rows on the floor today —
correctly, because `/review-pr` and `/simplify` both *apply* their suggestions
inline, so filing them would duplicate an applied fix as an open issue.

`/premerge` is the first caller for which that is false: its Phase 1 reviewer is
advisory only and its Phase 4 lens pass runs later and on a narrower scope, so a
Phase 1 cleanup finding has no other sink.

The tier is added with a **single-arm gate**:

- `SUGGESTION_TIER_ENABLED` defaults to `0` and is set to `1` by exactly one arm
  of `findings_derive_review_origin` — the `premerge.defer.findings` case.
- `severity_rank(suggestion) = 0`, below every other tier, so a `MAX_NEW`
  overflow truncates cleanup rows first and can never displace a blocker. That
  ordering is what lets the new tier share one cap instead of needing a budget.
- `SUGGESTION` **never halts** and never trips the broken-feature overflow guard
  (scoped to `{BLOCKER, CRITICAL}`). A halt would contradict the definition that
  produced the row.
- Its label is `premerge-finding`, **not** `review-pr-finding`.
  `lib/goal-phase3.sh` selects `/goal` recursion targets by that label plus a
  `**Tier:** BLOCKER|CRITICAL` body line; filing cleanup ideas under it would
  enlist each one into a convergence loop with no way to decide it is done.

Every other caller therefore takes the pre-existing `*) return 1` arm on a
`suggestion`, bit-identically to shipped behaviour.

## 6. What `/premerge` reuses, and the two things it does not

**Reused whole:** `lib/review-consolidate.sh` (discovery ordering, the merge
loop with conflict handback, the ancestry gate, the typed exclusion vocabulary,
the PR body/title renderers, the supersession comments, the manifest);
`discover_open_prs`; `agents/findings-to-issues.md`; `agents/code-simplifier.md`;
`lib/bump-version.sh`.

**Deliberately not reused — 1: `review_consolidate_assert_current`.** That
assertion proves the PR the operator invoked `/review-pr` on survived the
combine. `/premerge` is invoked on no PR, so the assertion has no referent.
Calling it with a fabricated number would be worse than not calling it. Phase 0c
substitutes a **strictly stronger** invariant: every candidate present in
`candidates.json` must appear in the included ledger or the excluded ledger, and
a number in neither halts the run. `assert_ancestry` still runs unchanged.

**Deliberately not reused — 2: the authenticated `code-fixer` contract.**
`agents/code-fixer.md`'s three routes are welded to `review-pr` and `simplify`
carrier identities, to the seven-edge Phase-1 contributor roster, and to a
`phase2` rule that admits only `behavior_tag: preserve` — which would refuse
every correctness fix `/premerge` needs to make. Claiming one of those identities
would mean a premerge run producing an aggregate that *says* it came from the
seven-reviewer fanout. That is the replica-drift shape this repo has been bitten
by repeatedly, and it is worse than the honest alternative.

So `/premerge` dispatches plain `general-purpose` fixer agents under a bounded
contract it states in full: **one agent per file, disjoint files per wave, no
`git` of any kind, no new files, refuse rather than widen scope.** The controller
makes every commit, asserts the branch first, and refuses to commit if any agent
left an untracked file behind. The tradeoff is stated rather than hidden: weaker
sandboxing than `code-fixer`, in exchange for not lying about provenance.

## 7. No trust trail

`/premerge` emits no `uberdev-approved` label, no `Reviewed-by:` trailer and no
audit JSON. `/merge`'s PATH_2 therefore does not accept a `/premerge` run as
review evidence, and that is intended: the trail is a claim that uberdev's
seven-lens fanout, its finding-verification gate and its CI-health phase all ran,
and under `/premerge` none of them did.

Run `/uberdev:review-pr <stack-pr>` on the parked stack PR when you want a trail.
The two compose in that order and `/premerge` leaves the branch in exactly the
state `/review-pr` expects.

## 8. Phase order, and why simplify is last

```
0  PACK        combine + open the stack PR
1  REVIEW      Skill("code-review", "<level> <stack-pr>")
2  TRIAGE      blockers -> fixer waves -> one commit -> push -> ONE re-review
               suggestions -> findings-to-issues (SUGGESTION tier)
3  CLEAN GATE  blockers == 0  AND  ci in {green,no_checks}  AND  mergeable != CONFLICTING
4  SIMPLIFY    three lenses -> apply behaviour-preserving only -> one commit -> push
5  BUMP + PARK one version bump for the stack -> push -> stop
```

`/review-pr` runs its simplify pass at Phase 2, before it has probed CI at all.
That ordering is fine for a single PR being iterated on. It is wrong for a stack
about to land, for two reasons: polishing code that still carries a known
correctness bug is wasted work, and the refactor diff buries the bug from anyone
reading the PR afterwards.

**The gate reads the re-review, not the first pass.** After Phase 2a's fixes, the
first pass's blocker list describes code that no longer exists. Exactly one
re-review runs — not a loop. A blocker that survives a fix is information a human
needs; the third automatic attempt is where a fixer starts "fixing" the test.

**Every gate fails closed.** Unreadable evidence is `not_green`, never green.

## 9. Open questions

- **The CI settle race.** A push restarts checks and `test.yml` fires on both
  `push` and `pull_request` with nothing cancelling the loser, so for ~10–30s
  after Phase 2a's push `gh pr checks` legitimately reports no checks — which
  reads as `no_checks`, i.e. green. Phase 3 documents a settle-and-re-probe
  requirement in prose. A structural fix (a minimum observed-check-count before
  the gate may answer) is deferred.
- **`--fix` passthrough.** The built-in reviewer can apply its own findings.
  `/premerge` deliberately does not use it, because those edits would land
  outside the wave planning and outside the commit discipline. If the wave
  machinery ever proves to be net-negative, `--fix` is the fallback to revisit.
- **Multi-base stacks.** `review_consolidate_base` picks one base. A candidate
  set spanning `main` and `release/2.0` gets the majority base and the others are
  excluded by number. Reviewing two stacks in one run is out of scope.
