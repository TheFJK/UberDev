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
| **Amended** | 2026-08-22 — §10 A1 (Phases 1→2→3 become a bounded convergence loop) and A2 (a simplify phase that is reachable and verified). §8's phase diagram and §9's first open question are rewritten in place. |
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
   releases silently collapse into one. `CLAUDE.md` already responds by binding
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
0   PACK        combine + open the stack PR
1   REVIEW      Skill("code-review", "<level> <stack-pr>")
2   TRIAGE      classify; plan the fixer waves; stamp the reviewed HEAD
3   CLEAN GATE  blockers == 0  AND  ci in {green,no_checks}  AND  mergeable != CONFLICTING
                AND  the evidence is stamped with the branch's current HEAD
                AND  a bare no_checks did not follow this attempt's own push
3b  CONVERGE    STOP_GREEN -> Phase 4
                CONTINUE   -> repair the failing term (3c) -> Phase 1, attempt+1
                WAIT_CI    -> re-probe Phase 3; does NOT consume an attempt
                STOP_NO_PROGRESS | STOP_REGRESSED | STOP_EXHAUSTED | STOP_UNREADABLE
                           -> Phase 5, not green
4   SIMPLIFY    three lenses -> apply behaviour-preserving only -> one commit -> push
4c  VERIFY      re-probe CI and re-gate the simplify commit; revert it if it did harm
5   BUMP + PARK issues for everything unfixed, blockers included
                -> one version bump for the stack -> push -> stop
```

Phases 1→2→3 are a **loop**, closed by 3b, and the ordering inside one attempt is
load-bearing: **the gate runs before the repair.** Dispatch the fixers in Phase 2
instead and the loop deadlocks on its own safety check — `plan` stamps the SHA the
review looked at, the fix commit moves `HEAD`, and the gate then reports
`stale_evidence` (a `STOP_UNREADABLE`) on every attempt that actually fixed
something, while only the attempts that changed nothing survive to try again.
Two properties follow from the order as written: every fix commit is reviewed and
gated by the next attempt, and each attempt costs one review rather than two —
the hand-run "re-review" of the pre-amendment design *is* the next Phase 1. The
fix-commit fence refuses without a `not_green` gate verdict for its own attempt,
so the inverted order fails loudly instead of silently converging on nothing.

Suggestions leave the loop at Phase 5
rather than inside it, ~~because `findings-to-issues` fingerprints an issue as
`file:line:summary` and a fix that shifts a line by one gives the same suggestion
a new fingerprint — per-attempt filing produces duplicates, not comments.~~
See §10 A1 for the loop and §10 A2 for 4c.

> **AMENDED 2026-08-23 — see §10 A4.** The conclusion stands; its reason no
> longer does. `findings-to-issues` keys the ISSUE on the owning file, so a
> second dispatch over the same file comments rather than duplicating. What
> per-attempt filing costs now is that the members inside that issue are still
> re-listed as new on every attempt, turning one issue into a per-attempt
> transcript — and each dispatch spends `MAX_NEW` and rate-limit budget to do
> it. Filing once is what keeps the issue a statement about the file rather
> than a log.

`/review-pr` runs its simplify pass at Phase 2, before it has probed CI at all.
That ordering is fine for a single PR being iterated on. It is wrong for a stack
about to land, for two reasons: polishing code that still carries a known
correctness bug is wasted work, and the refactor diff buries the bug from anyone
reading the PR afterwards.

**The gate reads the re-review, not the first pass.** After Phase 2a's fixes, the
first pass's blocker list describes code that no longer exists. ~~Exactly one
re-review runs — not a loop. A blocker that survives a fix is information a human
needs; the third automatic attempt is where a fixer starts "fixing" the test.~~

> **AMENDED 2026-08-22 — see §10 A1.** The re-review is now a bounded loop, and
> a blocker that survives it is filed as an issue rather than printed and lost.
> The hazard the struck text names is real; a counter of one never reached it,
> and the prohibition in the fixer prompt plus the two evidence-based stops do.

**Every gate fails closed.** Unreadable evidence is `not_green`, never green.

## 9. Open questions

- **The CI settle race — RESOLVED 2026-08-22 (§10 A1).** A push restarts checks
  and `test.yml` fires on both `push` and `pull_request` with nothing cancelling
  the loser, so for ~10–30s after Phase 2a's push `gh pr checks` legitimately
  reports no checks — which read as `no_checks`, i.e. green. The loop made that
  urgent rather than academic: every attempt ends in a push, so the race is on
  the main path and not at the edge. The structural fix is
  `assert-green --after-push`. When the attempt that produced the evidence
  pushed, `no_checks` no longer answers green — it contributes the reason
  `ci=no_checks_after_push`, which `converge` routes to `WAIT_CI`: re-probe,
  without consuming a fix attempt, bounded by `CONVERGE_WAIT_CI_CEILING` so a
  check that never settles ends the run `STOP_UNREADABLE` rather than green.
  Note that this is **not** the fix the bullet imagined. A minimum
  observed-check-count has to guess how many checks the repo runs, and a repo
  that legitimately runs one check sits permanently below any threshold above
  one — the gate would never answer. Asking "did *this* attempt just push?" needs
  no such number, and the caller already knows the answer. The prose
  settle-and-re-probe requirement stays, now as what keeps `WAIT_CI` from being a
  busy loop rather than as the only thing standing between a cold build and a
  green gate.
- **`--fix` passthrough.** The built-in reviewer can apply its own findings.
  `/premerge` deliberately does not use it, because those edits would land
  outside the wave planning and outside the commit discipline. If the wave
  machinery ever proves to be net-negative, `--fix` is the fallback to revisit.
- **Multi-base stacks.** `review_consolidate_base` picks one base. A candidate
  set spanning `main` and `release/2.0` gets the majority base and the others are
  excluded by number. Reviewing two stacks in one run is out of scope.

---

## 10. Amendments

### A1 — the bounded convergence loop (2026-08-22)

§8 read, verbatim:

> **The gate reads the re-review, not the first pass.** After Phase 2a's fixes,
> the first pass's blocker list describes code that no longer exists. Exactly one
> re-review runs — not a loop. A blocker that survives a fix is information a
> human needs; the third automatic attempt is where a fixer starts "fixing" the
> test.

The first two sentences stand. The rest is superseded: **Phases 1→2→3 are a
bounded loop, closed by a new `## Phase 3b — CONVERGE`.**

**The refusal identified the hazard correctly and the remedy incorrectly.** The
hazard is real — a fixer that has already failed at a finding starts looking for a
way to make the complaint stop rather than a way to make the code right, and the
cheapest such way is to weaken the test. But a counter of `1` does not prevent
that. A fixer disposed to weaken a test does it on attempt one exactly as readily
as on attempt three; the counter never reaches the case it was written for. What
the counter does reliably do is stop a loop that *was* converging — four blockers,
three of them fixed — and park the stack with the fourth still live. And because
the gate is also what unlocks Phase 4, that same stop took the not-green branch
and skipped simplify entirely (A2). One number bought no protection and cost two
phases.

What guards the hazard directly:

1. **An explicit prohibition in the fixer prompt.** `skills/premerge-pipeline/SKILL.md`
   Phase 2a tells every fixer agent: *"Do NOT weaken, delete, skip or relax a
   test, an assertion or a guard in order to make a finding go away. If the honest
   reading is that the TEST is wrong, say so and skip … Making the evidence stop
   complaining is not fixing the bug."* Paired with the standing rule that a
   skipped finding is a reported outcome and not a failure, so the agent has an
   honest exit that costs it nothing.
2. **Noticing that an attempt achieved nothing.** `STOP_NO_PROGRESS` and
   `STOP_REGRESSED` are computed by `lib/premerge-findings.py` from **blocker
   fingerprints** — this attempt's set against the previous attempt's — not from
   prose and not from a count of tries. An attempt that changed neither the
   blocker set nor the gate's other reasons stops the loop on the spot, whether it
   was attempt two or attempt five; an attempt that *grew* the blocker set stops it
   harder.

   The fingerprint is `path` plus a case-folded, punctuation-stripped `summary`,
   and it is deliberately **not** `file:line`. A fix moves lines, including inside
   other findings' hunks, so a line-keyed identity reports every survivor as
   brand new — the loop would observe infinite progress and never stop. ~~It is
   also deliberately not the fingerprint `agents/findings-to-issues.md` computes,
   which *is* `file:line:summary` because an issue is about a location. Same
   width, different question.~~

   > **AMENDED 2026-08-23 — see §10 A4.** The "deliberately not" verdict holds
   > and the singular does not: `agents/findings-to-issues.md` computes **two**
   > fingerprints, so "the fingerprint" names nothing there. It keys a
   > per-FINDING identity on `file:line:summary` because a finding is about a
   > location, and a per-ISSUE identity on the owning file alone because an
   > issue is now about a file. The loop fingerprint above is deliberately
   > neither. Same 16-hex width, three different questions.

**The counter survives, demoted to a runaway backstop.** `--converge=<n>` takes
`1..6` (`CONVERGE_REPAIR_CEILING`), default `3`; anything outside that range is a
**refusal, not a clamp**, and the library is the enforcer so the numbers being
restated in prose does not make them advisory. `--no-converge` is `--converge=1`
and is the pre-amendment shape spelled as a mode — one fix wave-set and one
re-review.

**The budget counts repairs, not reviews**, and the distinction is load-bearing
rather than pedantic. An attempt is one review+gate; a repair is what a not-green
gate triggers. N repairs therefore always cost N+1 reviews, the last of which
exists to verify the last repair — which is how the loop guarantees that nothing
it writes ships ungated. Count reviews instead and `--converge=1` resolves to
"gate once, repair nothing": zero repairs, under the very flag documented as
reproducing the pre-amendment pipeline, and strictly worse than the design being
superseded. `STOP_EXHAUSTED` fires on `attempt > max_repairs`, never on `>=`. `STOP_EXHAUSTED` is consulted **last**, after every evidence-based
decision, which is the whole ordering claim of this amendment in one line:
evidence outranks budget.

**The decision vocabulary is closed** — `CONVERGE_DECISIONS` in
`lib/premerge-findings.py`, and widening it needs an amendment here first:

| Decision | Meaning | Next |
| --- | --- | --- |
| `CONTINUE` | something is still fixable and the last attempt changed something | repair (3c), then Phase 1 at attempt+1 |
| `WAIT_CI` | nothing to fix; the build has not answered yet | re-probe Phase 3 — **does not consume an attempt** |
| `STOP_GREEN` | the gate passed | Phase 4 |
| `STOP_NO_PROGRESS` | an attempt changed neither the blockers nor the CI reason | Phase 5, not green |
| `STOP_REGRESSED` | our own fixes grew the blocker set | Phase 5, not green |
| `STOP_EXHAUSTED` | the runaway backstop | Phase 5, not green |
| `STOP_UNREADABLE` | evidence stamped to a SHA that is no longer HEAD, or CI that never settled | Phase 5, not green |

`converge` exits **0 to loop again and 1 to stop**, so `STOP_GREEN` — the outcome
the loop exists to reach — exits 1. The verb's contract is to branch on
`DECISION=` on stdout; a controller that reads non-zero as failure reports every
successfully converged stack as a broken one. The inversion is stated here
because it is the one place in this design where the obvious reading is wrong.

**Routing, by gate reason.** On `CONTINUE`, every failing term goes to something
that can repair it; a term with no route is `STOP_UNREADABLE`, never a shrug.

| Gate reason | Repair | Consumes an attempt? |
| --- | --- | --- |
| `blockers_remaining=<n>` | the Phase 2a fixer waves | yes |
| `ci=red` | classify, then route — below | yes |
| `mergeable=CONFLICTING` | the **controller** merges `origin/<base>` into the stack branch and resolves | yes |
| `ci=pending`, `ci=unknown`, `ci=no_checks_after_push` | re-probe | no (`WAIT_CI`) |
| `stale_evidence` | none — the evidence describes code that moved | stops the loop |

`mergeable=CONFLICTING` is repaired by bringing the base **into** the stack, which
is the same primitive `lib/review-consolidate.sh` used to build the branch and the
exact opposite of landing — §7's no-merge rule is untouched. It is controller-owned
because it is a git write on the branch every commit fence asserts against.

**Red CI is repaired, where it is repairable.** Before this amendment nothing in
the pipeline was pointed at a red build at all: the gate could observe `ci=red`
and the run's only response was to stop. Now the failing log is fetched, wrapped
in an `<external-untrusted-input>` envelope with its `sha256` and handed *inline*
to `uberdev:ci-failure-classifier`, and the `failure_class` routes:

| Class | Route | Consumes an attempt? |
| --- | --- | --- |
| `code_bug`, `env_drift` | one `uberdev:ci-code-fixer` at the `signal_anchor` | yes |
| `stale_base` | one `uberdev:ci-rebase-handler` | yes |
| `flaky` | `gh run rerun --failed`, capped | no |
| `billing_quota`, `platform_outage` | none — stop and name it | stops the loop |
| anything else, or `AMBIGUOUS` | none — stop | stops the loop |

`billing_quota` and `platform_outage` are **not loopable**, and that is a
correctness claim rather than a budget one: neither is a code problem, no number
of attempts changes either, and looping on one burns the whole budget and then
reports `STOP_EXHAUSTED` — a summary that describes the wrong thing and sends the
operator to read a diff when they needed to go read a billing page.

**None of the three agents PUSHES and none of them may** — but two of them run
git locally, and that distinction is load-bearing rather than pedantic.
`ci-code-fixer` commits by contract and returns the SHA; `ci-rebase-handler`
rebases, rewriting the branch. So a CI repair does **not** go through the Phase 2a
commit fence: that fence runs `git add -u` and refuses an empty tree, so after the
agent has already committed it finds nothing to add and reports
`COMMIT=none REASON=no-edits` — the repair would look like a no-op. The CI arm
owns its own publication, and the rebase arm needs its `--force-with-lease` SHA
captured **before** dispatch, since a rewritten branch rejects a bare push and the
lease is what makes "the agent pushed anyway" detectable. `## Common Mistakes`'s
*"letting a fixer agent run git"* is about the `general-purpose` wave agents,
which are told outright not to; conflating the two contracts is how a CI repair
silently does nothing.

**`WAIT_CI` does not consume an attempt**, deliberately: a slow build must not eat
the fix budget, or a repo with a 20-minute suite converges strictly worse than one
with a 2-minute suite for reasons that have nothing to do with its code. That
exemption is what obliges it to carry its own bound — `CONVERGE_WAIT_CI_CEILING`
(8), past which the decision becomes `STOP_UNREADABLE`. A check that never settles
is a stop, and it is a **not-green** stop; there is no path by which waiting turns
into a pass.

**Everything the loop could not fix is filed.** Surviving blockers now go through
`findings-to-issues` at `BLOCKER` tier with a `Blocks: #<stack-pr>` backref,
alongside the suggestions. Under the single-shot design a surviving blocker was
printed into the run summary and then lost the moment the terminal scrolled —
which inverts the priority the severity rule in §4 exists to express, since the
thing the machine could not fix is precisely the thing that has to outlive the
run.

### A2 — a simplify phase that is reachable, and verified (2026-08-22)

§8's *ordering* claim is unchanged and still right: simplify runs last, on a clean
stack, because polishing code that carries a known correctness bug is wasted work
and the refactor diff buries the bug from whoever reads the PR next.

**What was broken is that "a clean stack" was unreachable for exactly the stacks
`/premerge` exists for.** With a single-shot gate, one surviving blocker, one red
build or one `CONFLICTING` mergeable sent the run down the not-green branch — and
Phase 4 was skipped **silently**, while the run still reported success. A stack
clean enough to reach simplify was a stack that never needed the command's
fixing machinery in the first place. So Phase 4 was, on the interesting path,
structurally unreachable — while the shape gate asserting its heading exists
stayed green throughout — and red CI was never repaired at all (A1). The loop is
what makes a green gate reachable, and a green
gate is what unlocks this phase; the two amendments are one change described from
two ends.

Two further defects the rework repairs, both of the same family — a promise with
no mechanism behind it:

**(i) Phase 4's promise to file its un-applied lens findings had no producer.**
`lib/premerge-findings.py`'s `plan` verb consumes the built-in reviewer's
contract, which requires a `failure_scenario` on every finding. A
`code-simplifier` lens never emits that field, so there was no path at all from a
lens finding to the aggregate `findings-to-issues` reads. The skill promised the
filing in prose and no verb in the library could have performed it.

The fix is a **producer**, not a better-worded promise: a fourth verb, `defer`,
which is the only caller allowed to emit a `blocker` row in a `premerge-aggregate`
envelope. It builds the single aggregate Phase 5 files, from three sources — the
final attempt's suggestions, the un-applied lens findings (translated: `detail`
becomes `failure_scenario`, the lens name is prefixed onto the summary), and any
blocker the loop stopped on.

That last source closes the same defect one level up, and it is worth naming
separately because the original text of this RFC did not notice it: **a surviving
blocker was printed into the run summary and lost.** `_encode_aggregate` pinned
every row to `suggestion`, so there was no way to file one even in principle — the
one finding the machine could *not* handle was the one finding that did not
outlive the run. `agents/findings-to-issues.md` needed no change to accept it:
`severity_rank(blocker)=3` already sorts a blocker above every cleanup row
specifically so a `max_new` overflow cannot displace one, and Step 8d already
gives it the `@author`-mention shape. The consumer had been ready the whole time.

A lens finding always files as a `suggestion`, whatever the lens called it. These
are findings the simplify pass *declined to apply*, on a stack that had already
passed the clean gate; filing one as a blocker would halt a run over a refactor
suggestion.

**(ii) Nothing re-verified the branch after Phase 4 pushed.** Every gate in the run
was computed *before* the refactor commit existed. A refactor that reddened the
suite, or changed behaviour while reporting that it had not, or introduced a fresh
blocker, would ship inside a stack whose summary said the gate was green — and
Phase 5's `chore(release)` commit would then attest to code nothing had ever
checked. A version bump is a claim about a tree; it must not be the first thing to
touch an unverified one.

**`### 4c — VERIFY`** closes both. It runs unless `--no-post-simplify-review`,
and it runs a **full attempt cycle** at `attempt + 1` — Phase 1, Phase 2, Phase 3
— not the gate alone. CI is re-probed on the **post-simplify SHA** and reported
as a row of its own rather than as an update to the pre-simplify row: two
different SHAs were measured, and collapsing them hides which one was green.

**Phase 2 is the step that is easy to omit and fatal to omit.** `plan` is what
stamps `head_sha`, and the simplify commit has already moved `HEAD`. Re-gating
without re-stamping compares pre-simplify evidence against a post-simplify SHA,
which is `stale_evidence` *by construction* — so the verify step would fire on
every run and revert every correct, behaviour-preserving polish pass. A
self-check that always fails is worse than no self-check: it teaches its reader
to ignore it.

4c also reads the gate verdict directly rather than calling `converge`. The
repair budget may already be spent, and `converge` refuses an attempt past it
(`bad_attempt`, exit 74) — which would turn a successful verify into a crash.

| Verify outcome | Action |
| --- | --- |
| green | Phase 5 — and the summary may now honestly say the stack is green *after* simplify |
| not green, attempts remain | back into Phase 3b with the remaining budget; the refactor is just more code to converge on |
| not green, no budget left | **revert the simplify commit**, push, report `simplify=reverted (<reason>)` |

**The revert rule is the point. Simplify is optional polish, so its failure mode
is `undo`, not `halt`.** Halting would park a stack that was green before the
polish and broken after it, and hand a human a refactor nobody asked for to debug.
`git revert --no-edit <simplify-sha>` restores the last state that actually passed
a gate, and the un-applied lens findings are already on their way to issues by
(i), so the only thing lost is a refactor that was not safe to ship.

**The revert must never reach the fix commits.** Those are the loop's product —
they are what made the stack green — and reverting them would re-open every
blocker the run just paid to close, converting an optional-polish failure into a
total loss. The revert names exactly one SHA, Phase 4b's. That is why 4b makes
exactly **one** commit, and why its commit discipline (controller-only commits, a
refusal on any untracked file an agent left behind) carries more weight here than
anywhere else in the run: a Phase 4 that made two commits, or swept a stray file
into one, would make the undo unrepresentable.

`--no-simplify` still skips Phase 4 outright. `--no-post-simplify-review`
suppresses only 4c, and it is worth naming what that costs, because it is defect
(ii) reinstated on purpose: the run polishes the stack and then bumps the version
over a tree whose last verification predates the polish.

---

### A3 — the loop's termination criterion is wrong in kind (2026-08-23)

A1 built a bounded loop and A2 made its green branch reachable. Both stand. What
neither addressed is the criterion the loop terminates *on*, and three runs have
now shown it cannot be reached on the stacks the command exists for.

A1 said, verbatim (`§10 A1`, item 2):

> **Noticing that an attempt achieved nothing.** `STOP_NO_PROGRESS` and
> `STOP_REGRESSED` are computed by `lib/premerge-findings.py` from **blocker
> fingerprints** — this attempt's set against the previous attempt's — not from
> prose and not from a count of tries.

The fingerprint machinery is correct and stays. The defect is upstream of it:
**the two fingerprint sets being compared are independent samples, not two states
of one work queue.** Everything below follows from that.

#### The measurement

`/premerge` on PR #731 (packing #727–730) ran the full 4-review / 3-repair loop
and stopped `STOP_EXHAUSTED`. Blockers per attempt: **10 → 10 → 6 → 8**, with
`FIXED=10`, `FIXED=10`, `FIXED=6`. An earlier pair of runs on PR #681 filed 19
and 15 issues; of run 2's 15 findings, **one** re-discovered run 1 and the other
**fourteen were new defects in code the loop's own fixers had just written.**

Those numbers do not describe a loop that is converging slowly. They describe a
loop with no fixed point.

#### 1. Phase 1 resamples the whole stack, every attempt

`skills/premerge-pipeline/SKILL.md:584` dispatches

```
Skill("code-review", args: "<PREMERGE_LEVEL> <PREMERGE_PR>")
```

against the **entire stack PR**, and it does so once per attempt. At `xhigh` on a
~3000-line diff that yields roughly ten blockers per pass — not because ten
blockers are present, but because the reviewer is a *sampler* over "defects a
careful reader could name in this diff" and that distribution has effectively
unbounded support at this diff size. `blockers == 0` is not a state the stack can
be driven into; it is a coin that has to land empty.

The loop then makes its own haystack grow. Every repair adds code, and the next
attempt reviews that new code at the same depth as the original. The generator's
rate is roughly constant per unit reviewed and the amount reviewed never shrinks.
Phase 4c (`:1866`) re-dispatches the same full-PR review a fifth time.

**A stop condition of the form "an LLM found nothing this round" is not
decidable, and no amount of budget, fan-out or chunking makes it one.**

#### 2. Blockers are resampled; only suggestions have a ledger

`lib/premerge-findings.py` carries **suggestions** across attempts —
`_carry_prior_suggestions` (`:836`) unions every earlier attempt's suggestion
rows, deduped on `_suggestion_key` (`:873`). Blockers get no equivalent.
`_blocker_fingerprints` (`:812`) exists only to *compare* attempt N's set against
attempt N−1's, and attempt N's set is re-derived wholly from attempt N's fresh
full-PR review.

So the `FIXED=` and `NEW=` counters on the `PREMERGE_CONVERGE` line are a diff of
two independent samples, and two very different events are indistinguishable
inside them:

- a blocker the fixer genuinely repaired, and
- a blocker the sampler simply did not roll this time,

both count `FIXED`. Symmetrically, a defect that was present at attempt 1 but not
sampled until attempt 3 counts `NEW`, which is the input `STOP_REGRESSED` reacts
to. **`FIXED=10/10/6` on PR #731 is not evidence that 26 blockers were fixed. It
is evidence that 26 fingerprints failed to reappear.**

#### 3. The fixers' own dispositions are collected and discarded

`SKILL.md:805-810` requires every fixer agent to return, per finding:

```
status: APPLIED | NO_CHANGE | REFUSED
file: <path>
outcomes:
  - rank: <the finding's rank>
    outcome: fixed | skipped | no_change_needed
    reason: <one line>
```

Nothing parses it. `no_change_needed` occurs **nowhere in the plugin outside
`skills/premerge-pipeline/SKILL.md`**, and inside it only at `:805-809` and
`:1728-1730` — both times as prompt text being handed to an agent. `APPLIED`
never appears in `lib/premerge-findings.py` at all. The fix-commit fence reads
`git status --porcelain` and the wave-scope lists; it never reads what the agents
said they did.

This is the same class as the `blockingFindings` drop recorded for solve-fleet: a
subagent contract that specifies a return value nothing consumes. Here it is the
**only** authoritative per-finding signal in the run, and the loop replaces it
with another roll of the sampler.

#### 4. The generator is used as the verifier

Verifying "did attempt N's fixes work?" is currently done by asking the same
unbounded generator to review the whole diff again. Verification therefore costs
a fresh batch of findings by construction — the act of checking produces new
work. This is why the loop's cost per attempt does not fall as the queue drains:
there is no queue, and checking is as expensive as discovering.

#### Design constraints any fix must satisfy

**This section is deliberately not a specification.** An earlier draft of A3
prescribed four changes; two rounds of review against it produced fourteen
findings, and the second round's six were all in text the first round's fixes had
just written — the amendment reproducing, on itself, the defect it documents. Two
of those were structural rather than cosmetic: the design named `refuted` as a
gate-closing state while defining a producer only for `fixed`, and it prescribed
reviewing a two-SHA range through a dispatch surface that accepts only a PR, a
branch or a path. A design with a state nothing can produce and a keystone
nothing can invoke is a sketch, and a sketch attracts "you did not specify X"
without bound.

So what A3 ratifies is the diagnosis above — every pointer in it executed and
confirmed — plus the constraint set below. Each constraint is a way the obvious
fix goes wrong, recorded so a later implementation is checked against it instead
of rediscovering it. Whichever design satisfies all eight is what §10 gets
amended with next.

**C1 — the reviewed surface must shrink, and the range must be incremental.**
The generator's yield scales with the surface it is pointed at, so a loop that
re-points it at the whole stack every attempt cannot terminate. But
`<HEAD_1>..<HEAD_N>` is cumulative and grows with every repair — a slower version
of the same growth. Only `<HEAD_{N-1}>..<HEAD_N>` has the shrinking property.

**C2 — a shrinking surface breaks three consumers that read the current
attempt's findings as if they described the whole stack.** All three must move to
the ledger in the same change:

* `cmd_assert_green` (`lib/premerge-findings.py:1289-1290`) builds
  `blockers_remaining=%d` from `len(document["blockers"])` of the current
  attempt. Point the review at one repair diff and this reads *"no blockers in
  the last repair"* while `B` still holds ten — empty `reasons`, `VERDICT=green`,
  `STOP_GREEN`, and Phases 4 and 5 attest to a stack with ten live blockers. The
  most dangerous consequence of C1 and the easiest to miss.
* `cmd_converge`'s `fixed` / `appeared` (`:1554-1564`) diff two fingerprint
  multisets drawn, under C1, from disjoint populations.
* `cmd_defer` (`:1441`) takes blockers from one `document` while unioning
  suggestions across attempts (`:1436-1439`), so undispositioned rows of `B`
  would be filed nowhere — §2's gap reappearing as a consequence of §2's own fix.

**C3 — `STOP_NO_PROGRESS` fires spuriously under C1; it does not go quiet.**
The predicate is `current_prints == previous_prints and other == previous_other`
(`:1619-1624`), and empty `Counter`s compare equal. Clean incremental reviews are
the *common* case, so two in a row halt the loop with `B` undispositioned and the
budget unspent, reporting that an attempt achieved nothing about a loop that just
closed rows. The safe-sounding error is to predict these stops fall silent; the
real failure is that they stop a loop that was working.

**C4 — every gate-closing state needs a producer, and `refuted` is the one that
has none.** Adjudicating a finding as not-a-defect is a terminal state real
stacks reach — fixers return `no_change_needed`. But a refuted row has no fix
hunk, so a verifier defined as *"the finding plus the hunk that claims to fix
it"* has no input for it. Left unsolved, every stack containing one
false-positive finding runs to `STOP_EXHAUSTED`.

**C5 — no disposition meaning "not done" may close the gate.** `deferred` and
`wontfix` are terminal, so a criterion reading *"every row is dispositioned"* is
satisfied by deferring all ten baseline blockers — strictly weaker than today's
`blockers_remaining=N` → `not_green`, which is what keeps a run out of Phases 4
and 5. Closing requires an adjudicated `fixed` or `refuted`, or a per-finding
operator acknowledgement in the shape `/merge` already uses for
`--accept-blocker-deferred`.

**C6 — the fixer contract does not speak the ledger's vocabulary, and the gap is
ambiguous rather than absent.** `SKILL.md:805-810` mandates `status: APPLIED |
NO_CHANGE | REFUSED` and `outcome: fixed | skipped | no_change_needed`. Against
ledger states `fixed | refuted | deferred | wontfix` only `fixed` overlaps;
`skipped` reads as either `deferred` or `wontfix`, `no_change_needed` as either
`refuted` or already-fixed. A controller-side guess between two readings is not a
disposition, so the contract must be widened to emit the ledger vocabulary
directly and say which reading it means.

**C7 — a closed row can be re-opened by a later repair, and under C1 nothing
looks.** Repair 1 closes row #3; repair 3 refactors the same function and
reinstates the defect; the incremental review of repair 3 has no knowledge of row
#3, which stays `fixed`. Either closed rows whose files a later repair touched
get re-checked, or `STOP_REGRESSED` must be documented as unreachable rather than
carried as a retained backstop.

**C8 — the incremental review needs a dispatch that exists.** The only reviewer
the pipeline has is the built-in `code-review` skill (`SKILL.md:584`), whose
accepted targets are a PR number, a branch, or a path; the no-target default is
`git diff @{upstream}...HEAD` plus the working tree. A two-SHA range is not in
that surface. C1 needs a path set derived from the repair diff, a locally-arranged
checkout the default picks up, or an extension to the target surface — named
explicitly, because "review the delta" is not yet an invocation.

**On the narrow verifier.** The instinct behind C4 — that checking must be
cheaper than discovering, and structurally unable to emit new findings — is sound
and survives. `uberdev:finding-verifier` is the right **shape**: one finding in,
a bounded document out. It is not reusable as-is. Its contract
(`shared/finding-verifier-output-v1.md:16`) is a 0-100 score plus
`reason ∈ {reproduced-from-diff, contradicted-by-diff, pre-existing,
out-of-scope-line, linter-domain, gate-disabled, over-cap-unverified,
verifier-unavailable}` — no token means *"the fix addresses it"*, and a repaired
defect and a never-real defect both land on `contradicted-by-diff`, collapsing
exactly the `fixed` / `refuted` distinction C4 and C5 depend on. Reuse the shape,
not the contract.

**On chunked review.** One reviewer per coherent unit, rather than one over the
whole diff, is a real improvement and belongs to the single baseline pass, where
it buys coverage at fixed cost. Applied per-attempt it multiplies the generator
and changes nothing about termination.

#### The general law this run demonstrated

A3's own drafting reproduced the defect twice inside two hours, which makes the
underlying rule worth stating in a form that outlives `/premerge`:

> **Never terminate a loop on a generative critic's silence. Terminate on a
> predicate fixed before the loop started.**

A critic asked *"what is wrong with this?"* is sampling from an unbounded set —
the true-but-unstated is infinite on any nontrivial artifact — so its silence is
a property of the sample, never of the artifact. Three corollaries, all visible
in this run:

1. **Separate wrongness from incompleteness.** Wrongness is finite and stays
   fixed: a false claim, a broken pointer, a misquote. Round 1's eight were
   wrongness, and round 2 confirmed every one of them repaired. Incompleteness —
   *"you did not specify X"* — is unbounded, and all six of round 2's findings
   were that. Only wrongness may drive a fix loop; incompleteness is recorded as
   scope. C1–C8 above **are** round 2's findings, absorbed as constraints rather
   than chased as bugs, which is why this section terminates and the previous one
   did not.
2. **If the artifact grew during the repair, the next round's findings are about
   the growth.** This draft went 167 → 237 lines in its fix round and round 2
   returned 6/6 findings in the new text. That ratio — findings landing in text
   the previous round wrote, over total findings — is a cheap, computable
   divergence signal, and at 100% it says stop rather than repair again.
3. **Sample once; afterwards ask only "is item N resolved?"** Re-asking *"what
   else is wrong?"* is not the next iteration of a loop, it is a new loop, and it
   needs its own budget and its own written stopping predicate.

#### What this does not change

The A1 ordering (gate before repair), the line-independent multiset fingerprint,
the fixer prompt's prohibition on weakening tests, controller-only commits, the
wave scope guard, and `## The one rule that outranks every other line in this
file` are all untouched.

**A3 changes no code.** It ratifies the diagnosis and the constraint set; the
loop that ships today is A1's, unmodified, and stays that way until a design
satisfying C1–C8 is written and amended in. `STOP_NO_PROGRESS` and
`STOP_REGRESSED` therefore keep their current inputs and current behaviour —
C2 and C3 record what happens to them *if* C1 lands, not a change made here.

#### Interim mitigations, no code change

`--converge=1` (rounds 2–3 measurably do not converge on a large stack),
`--no-issues` when the stack is `/premerge`'s own machinery, `high` rather than
`xhigh` on a large diff, and a smaller stack. On PR #681, **33 of 39** open
findings targeted `skills/premerge-pipeline/SKILL.md` and
`lib/premerge-findings.py`; #711 and #713 named `_ATTEMPT_RE`
(`lib/premerge-findings.py:232`) and `cmd_converge` (`:1500`) — code that did not
exist before that same stack's own fix rounds wrote it. Both are on `main` today,
having landed with the stack in `c7459641`; the point is that the run generated
findings against its own fresh output, not that the symbols were fictional.

#### Related

#717 (the cross-run issue fingerprint cannot fire), #718 (per-dispatch issue
budget inside an N-round loop; suggestions never gate but always become work) and
#719 (the precision corpus is single-label, so no finding has ever been
adjudicated) are the three already-filed consequences. A3 is the cause they share:
a review loop with a generator, no sink, and no signal that could tell it to
generate less.

### A4 — the ISSUE key is per-file, not per-finding (2026-08-23)

Two passages above rest on one premise: that `findings-to-issues` computes a
single fingerprint, and that it is `file:line:summary`. §8 read, verbatim:

> Suggestions leave the loop at Phase 5 rather than inside it, because
> `findings-to-issues` fingerprints an issue as `file:line:summary` and a fix
> that shifts a line by one gives the same suggestion a new fingerprint —
> per-attempt filing produces duplicates, not comments.

and A1 above read, verbatim:

> It is also deliberately not the fingerprint `agents/findings-to-issues.md`
> computes, which *is* `file:line:summary` because an issue is about a location.
> Same width, different question.

Both are retained struck rather than rewritten, as the record of what was decided
here. Both **conclusions** survive intact — suggestions still leave the loop at
Phase 5, and the loop fingerprint is still deliberately not one of that agent's.
It is the premise underneath them that no longer holds.

**There are three fingerprints across the two files, not two (#722).** The agent
now computes two where it used to compute one, and the loop's own key is the
third:

| Fingerprint | Where | Material | Question it answers |
| --- | --- | --- | --- |
| loop | `lib/premerge-findings.py` — `_fingerprint` | `path` + a case-folded, punctuation-stripped `summary` | is this the same blocker I already tried to fix? |
| member | `agents/findings-to-issues.md` — Step 8a | `file_path`, `line`, `normalised_summary` | is this the same FINDING? |
| container | `agents/findings-to-issues.md` — Step 8a | `sha256("<finding_marker_slug>:<file_path>")[:16]` | which ISSUE owns this finding? |

All three are 16 hex characters wide, which is the whole trap: they substitute
for one another and neither a reader nor a parser notices.

**What it changes for §8.** A second dispatch over a file the agent has already
filed against now matches the container and **comments** — the duplicate §8 named
is gone. Filing inside the loop is still wrong, for the reasons the amended note
there gives: the members are re-listed as new on every attempt, so one issue
becomes a per-attempt transcript; each dispatch spends `MAX_NEW` and rate-limit
budget doing it; and `defer` re-`os.replace`s the aggregate under an in-flight
dispatch, which that agent refuses as `input-malformed`. Phase 5, once, is
unchanged, and so is the phase order it sits in.

**What it changes for A1 — nothing, and the reason matters.** The container key is
path-based too, so it shares the loop fingerprint's insensitivity to line
movement, and the tempting conclusion is that the two may now be one value. They
may not. The container is *meant* to collapse every finding in a file onto one
identity — that collapse is what makes the second dispatch a comment. The loop
key has to do the opposite and keep two findings in one file apart, or, in
`_fingerprint`'s own words, the loop reads a survivor as fixed. The member key is
the mirror hazard: it is keyed on exactly the line movement the loop exists to
survive. Different material, three different questions — never substitute one for
another.

`skills/premerge-pipeline/SKILL.md` (`### 2b — File the suggestions`,
`## Phase 3b — CONVERGE`, `## Common Mistakes`) and
`_fingerprint`'s docstring state the same distinction at the code. This amendment
is what keeps the design authority from outranking them with the retired premise.

### A5 — the growth ratio is computed and stops the loop (2026-08-23)

A5 is the first code change made under A3, and it discharges A3's second
corollary rather than its constraint set. A3 closed, verbatim:

> **A3 changes no code.** It ratifies the diagnosis and the constraint set; the
> loop that ships today is A1's, unmodified, and stays that way until a design
> satisfying C1–C8 is written and amended in.

From this amendment on, the second half of that sentence no longer describes the
shipped tree: the loop carries one new measurement and one new stop, and C1–C8
are not satisfied. A3's text is retained as written — it is the record of what
was decided then — and narrowed here, the way A4 narrows §8 and A1.

The narrowing is precise. C1–C8 are constraints on **replacing the reviewed
surface**, and every one of them is still open. Phase 1 still re-reviews the
whole stack every attempt, so §1's finding — that the loop makes its own
haystack grow, and that the generator's rate is roughly constant per unit
reviewed — is undiminished. A5 adds a predicate over the sampler A1 already
runs, computed from artifacts the run already writes. **It detects the pump; it
does not stop the pumping. It stops the loop.**

That is also what keeps it on the right side of the general law A3 states.
`GROWTH` is a predicate fixed before the loop starts, with a written threshold
and a written streak length, and it never reads a critic's silence:
`blockers == 0` remains a coin that has to land empty, and no stop introduced
here turns on it.

#### What it computes

A3's corollary 2 named the quantity:

> That ratio — findings landing in text the previous round wrote, over total
> findings — is a cheap, computable divergence signal, and at 100% it says stop
> rather than repair again.

`cmd_converge` now computes it as a set intersection, at the point where it
already holds both attempts' evidence:

```
GROWTH(N) = |{ b in blockers(N) : b.file in modified(N-1)
                                  and b.fingerprint not in blockers(N-1) }|
            / |blockers(N)|
```

`blockers(N)` is attempt N's `classified-<NN>.json`; `modified(N-1)` is
`fix-scope-<NN-1>.modified`, the list the fix-commit fence's scope guard already
writes. Both sit inside the run directory `converge` is already handed, so there
is no new artifact, no new phase and no new argument. The value is printed as a
`GROWTH=` field on the existing `PREMERGE_CONVERGE` line and recorded under a
`growth` key on the existing `converge.jsonl` row; the number compared against
the threshold is the same two-decimal value the line prints, so the field an
operator reads and the decision the run took cannot disagree.

The fingerprint exclusion is load-bearing, not an optimisation. The wave plan
assigns exactly the files this attempt's blockers named, so a **survivor** — a
blocker the fixer was handed and did not clear — always sits in a modified file.
Counted, it would drive a loop that is converging with residual findings to 1.00
and stop it on its own success. Excluded, the numerator counts only fingerprints
the previous attempt's evidence did not carry, so it can never exceed the `NEW=`
count already on the same line, which is what makes that line internally
checkable.

Because the reviewed surface is unchanged, the denominator is the same
population `BLOCKERS=` already reports. C2's hazard — consumers reading one
attempt's findings as if they described the whole stack — is a consequence of
C1's shrinking surface and is not created here.

#### The stop

`STOP_SELF_REFERENTIAL` joins the closed `CONVERGE_DECISIONS` vocabulary as a
new cascade arm, after `STOP_NO_PROGRESS` and before the budget check that
yields `STOP_EXHAUSTED`. It fires when `GROWTH` is at or above
`CONVERGE_GROWTH_CEILING` (`0.50`) on `CONVERGE_GROWTH_RUNS` (`2`) consecutive
**measured** attempts, the earlier one read off that attempt's own ledger row
rather than carried in a variable a fence could forget. The pipeline SKILL
restates both numbers as `PREMERGE_GROWTH_CEILING` and `PREMERGE_GROWTH_RUNS`,
the way it restates the loop's other constants.

- **0.50 is break-even, and it is chosen rather than calibrated.** The numerator
  is work the last repair authored; the complement is work the loop inherited.
  At 0.50 a repair round manufactured exactly as much new work as it took from
  the inherited pile, and above it the repair is a net generator — every further
  round enlarges its own haystack. The two runs recorded in #754 were computed
  by hand, over whole runs, not by the code that ships here: the pumped run at
  1.00 and the converging one at 0.20. They bound the threshold — any value in
  (0.20, 1.00] separates them — without determining it.
- **Two rounds, because A3 §2 (*Blockers are resampled; only suggestions have a
  ledger*) is still true.** Attempt N's blocker set is a fresh sample, so a
  defect present since attempt 1 but first rolled at attempt 3 counts as new —
  and the files most likely to be resampled are exactly the ones the repair just
  touched. One high round is therefore consistent with a healthy convergence
  whose repairs happen to be concentrated in a few files, and firing on it would
  reproduce, for a new detector, the failure C3 names for an old one: "the real
  failure is that they stop a loop that was working." No run has yet produced a
  two-round streak from the shipped code — A3's own drafting is the nearest
  recorded case, and that is a single round at 6/6 — so the streak length is the
  conservative choice this argument supports, not a number read off data.
- **It pre-empts `STOP_EXHAUSTED` on purpose.** "The loop was still winning,
  raise `--converge`" and "the loop was reviewing itself" are opposite operator
  responses, and the budget stop says the first about a run that did the second.

Nothing it stops is discarded. `STOP_SELF_REFERENTIAL` is a not-green stop like
every other stop here, so the run reaches Phase 5 with `PREMERGE_SURVIVORS=1`,
which is what adds `--include-blockers` to the `defer` call and puts every
surviving blocker into the aggregate that becomes issues. The ratio's claim is
"not *this loop's* work", never "not work" — corollary 1, record incompleteness
as scope rather than chasing it as a bug, applied to the loop's own output. It
also closes no gate: a run ending here is not green, so C5 is untouched.

#### Why this is a signal and not a proof

Three limits, recorded so the next amendment is checked against them instead of
rediscovering them.

**File granularity over-counts.** The precise question is whether a finding
landed in text the previous repair *wrote*; what is measured is whether it
landed in a **file** that repair modified. A genuinely new defect four hundred
lines from the repair hunk counts as growth. The precise version needs diff-hunk
mapping against a review pointed at one repair's delta, and C8 records that no
such dispatch exists — the only reviewer this pipeline has accepts a PR, a
branch or a path, and a two-SHA range is not in that surface. So the proxy errs
toward stopping, which is what the two-round requirement exists to absorb.
Making it precise belongs to the C1–C8 work, not to a follow-up on this one.

**The measurement is blind on any round whose repair committed nothing.** The
fix-commit fence exits early with `REASON=no-edits` on a clean tree and writes
no `fix-scope-<NN>.modified` at all, and a repair that only re-ran CI commits
nothing. Those attempts report `GROWTH=-`, which means *not measured* and is a
different answer from `0.00`: there was no repair to attribute the round's
findings to, and printing zero would be reporting a measurement nobody took.

**So the guard is incomplete, not defeatable.** A pump interleaved with no-edit
rounds never accumulates two consecutive measured rounds and so never trips this
stop. That is a gap, not a bypass — the run then behaves exactly as it does
today and ends at `STOP_EXHAUSTED` on the budget. Today's behaviour is the floor
every degraded path falls back to: an unmeasurable ratio, an unreadable scope
list, attempt 1, or an attempt with no blockers to divide by all report `-` and
change no decision. Failing closed here would stop a loop that is working, which
is the one direction this measurement must not fail in.

#### What this does not change

The A1 ordering (gate before repair), the line-independent multiset fingerprint,
`STOP_NO_PROGRESS` / `STOP_REGRESSED` and their inputs, `cmd_assert_green`'s
`blockers_remaining` gate, the fixer prompt's prohibition on weakening tests,
controller-only commits, and the wave scope guard are all untouched. The
reviewed surface is still the whole stack, every attempt. C1–C8 remain the open
constraint set for the design that changes that, and A5 is not it.

### A6 — the growth population narrowed after A5 (2026-08-24)

A5 is the design authority for `STOP_SELF_REFERENTIAL`, and it was accurate
against the tree it landed on. Two later changes narrowed the detector without
touching the amendment: #766 put a second kind of row into the array A5's formula
divides by, and the first two `/premerge` repair rounds on the stack that
combined #765 with #766 excluded that row from the ratio and added a term to the
stop. A5 is **retained as written** — the record of what was decided on
2026-08-23 — and narrowed here, the way A5 narrows A3 and A4 narrows §8.

Both narrowings run the same way. `GROWTH` speaks about a **smaller** population
than A5 gives it, and the stop asks **one more question** than A5 records.

#### 1. A carried row counts on neither side

A5's *What it computes* reads, verbatim:

> ```
> GROWTH(N) = |{ b in blockers(N) : b.file in modified(N-1)
>                                   and b.fingerprint not in blockers(N-1) }|
>             / |blockers(N)|
> ```
>
> `blockers(N)` is attempt N's `classified-<NN>.json`

When that was written, the array held one kind of row: a blocker a reviewer
raised. A5 says nothing about carried rows because there were none to say
anything about.

**#766 put a second kind in the same array.** A fixer whose honest scope spans
two files now returns `blocked_on_file`, and `_read_blocked_on` turns each such
path into a blocker finding on the **next** attempt, stamped
`blocked_on_carry: True` and carrying a controller-authored summary that states a
scheduling fact rather than a defect. Up to `MAX_BLOCKED_ON` (`8`) of them can
enter one attempt. They are blockers because the wave plan and the clean gate
have to see them — otherwise a run whose only outstanding work was carried gated
green, dispatched nothing and filed nothing — but no reviewer raised them.

**They are excluded from both sides, not one.** `_growth_ratio` iterates
`_reviewer_blockers(document["blockers"])`, and the previous attempt's evidence
reaches it through `_blocker_fingerprints`, which iterates the same filter. So
`blockers(N)`, `blockers(N-1)` and the divisor all mean *the reviewer-raised rows
of* that array — and `-` for "no blockers to divide by" now means no
reviewer-raised blocker: an attempt holding nothing but carried rows reports `-`,
not a ratio.

The numerator half is forced. A path is carried precisely BECAUSE the previous
fixer could not edit it, so it is never in `fix-scope-<NN-1>.modified` and could
not have satisfied the membership test anyway. The **denominator** half is the
load-bearing one: left in the divisor, a row that can never be counted dilutes
the ratio every round, and the suppression is largest on the runs with the most
cross-file churn — exactly the runs `STOP_SELF_REFERENTIAL` exists for. Two
suppressed rounds in a row is all it takes for it never to fire.

Executed against the shipped module — one reviewer-raised blocker in a file the
last repair modified, alongside one carried consequence:

| | stored `blockers` array | divisor | `BLOCKERS=` | `GROWTH=` |
| --- | --- | --- | --- | --- |
| shipped | 2 | 1 | 1 | `1.00` |
| A5's formula as written | 2 | 2 | — | `0.50` |

**A5's other denominator claim survives intact.** "the denominator is the same
population `BLOCKERS=` already reports" is still true: `BLOCKERS=` is
`_blocker_fingerprints`' multiset total, and the two narrowed together through
`_reviewer_blockers` — which is also the single derivation
`counts.blocker_reviewer` uses, so the three spellings of that population cannot
drift apart. What changed is what the shared population *is*, not that the two
agree.

#### 2. The streak test has a third term

A5's *The stop* reads, verbatim:

> It fires when `GROWTH` is at or above `CONVERGE_GROWTH_CEILING` (`0.50`) on
> `CONVERGE_GROWTH_RUNS` (`2`) consecutive **measured** attempts

`_growth_round_counts` — one predicate, applied to this round's numbers and then
to the previous round's own `converge.jsonl` columns — asks **three** things of
each round. It is measured; it is at or above the ceiling; **and
`blockers >= previous_blockers`**, the round did not reduce the reviewer-raised
blocker count.

The third term is not defensive plumbing. `GROWTH=` answers *what is the residual
made of*, never *which way is this going*, and those two come apart in one
direction: the denominator is the residual, so it shrinks as the loop succeeds,
while the numerator counts findings the reviewer newly sampled in the file the
repair just touched — the file it was always likeliest to resample. **The ratio
therefore rises toward `1.00` precisely as a run converges.** Reproduced against
the shipped module with `--max-repairs 5`: five blockers, then four cleared
leaving one survivor and one new (`0.50`), then one more cleared leaving one
survivor and one new (`0.50`) — `STOP_SELF_REFERENTIAL` on a run that went
5 → 2 → 2, with three of five repair rounds unspent. `CONVERGE_GROWTH_RUNS` does
not mitigate it: at two rounds, a single new finding in a repaired file *is*
`0.50`, twice running.

That is C3's failure with the ratio's own name on it — the failure A5 argues
against for one high round and then leaves undefended for two. A round that
removed more of the reviewer's blockers than it was left holding is a round in
which repairing demonstrably worked, whatever its residual is made of, so it is
not eligible to be half of a divergence streak. The ratio is still measured,
still printed and still recorded on such a round; a genuine pump, which by
definition is not reducing the count, reaches the ceiling on consecutive eligible
rounds exactly as A5 describes.

Executed against the shipped predicate at `GROWTH=0.50`:

| round | `previous_blockers` → `blockers` | eligible |
| --- | --- | --- |
| count held | 5 → 5 | yes |
| count grew | 2 → 5 | yes |
| count fell | 5 → 2 | **no** |
| not measured (`GROWTH=-`) | any | **no** |

#### What this does not change

The threshold (`0.50`), the streak length (`2`), the cascade position (after
`STOP_NO_PROGRESS`, before `STOP_EXHAUSTED`), the file-granularity proxy and its
recorded limits, `GROWTH=-` meaning *not measured* rather than `0.00`, and the
survivors reaching Phase 5 through `--include-blockers` are all as A5 wrote them.
Carried rows leave the **evidence** questions only: they still enter the wave
plan, still gate `blockers_remaining=`, and are still filed — at the §5
`SUGGESTION` tier, via `_as_deferred_carry_row` — when the loop stops with the
edit outstanding.

`skills/premerge-pipeline/SKILL.md` (`## Phase 3b — CONVERGE`) and the docstrings
on `_growth_ratio`, `_reviewer_blockers` and `_growth_round_counts` state both
narrowings at the code. This amendment is what stops the design authority
outranking them with the wider population. C1–C8 remain the open constraint set,
and A6, like A5, is not the design that closes them.
