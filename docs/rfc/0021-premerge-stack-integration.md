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
rather than inside it, because `findings-to-issues` fingerprints an issue as
`file:line:summary` and a fix that shifts a line by one gives the same suggestion
a new fingerprint — per-attempt filing produces duplicates, not comments.
See §10 A1 for the loop and §10 A2 for 4c.

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
   brand new — the loop would observe infinite progress and never stop. It is
   also deliberately not the fingerprint `agents/findings-to-issues.md` computes,
   which *is* `file:line:summary` because an issue is about a location. Same
   width, different question.

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

`SKILL.md:805-809` requires every fixer agent to return, per finding:

```
status: APPLIED | NO_CHANGE | REFUSED
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

#### The decision

Four changes, together. None is sufficient alone.

**(a) Freeze the review surface.** The full-stack review runs **once**, at
attempt 1, producing the baseline set `B`. Attempts 2..N review only
`git diff <HEAD_{N-1}>..<HEAD_N>` — the single repair that attempt N−1 just
made — for regressions. The range is **incremental, not cumulative**:
`<HEAD_1>..<HEAD_N>` spans every repair so far and therefore grows monotonically
with each round, which is a slower version of the same growth §1 diagnoses. With
the incremental range the work list shrinks monotonically and review cost per
attempt tracks the size of one repair rather than the size of the stack.

Two consequences inside `lib/premerge-findings.py` that (a) cannot land without:

* **`cmd_converge`'s comparison must change.** It computes
  `fixed = previous_prints - current_prints` and
  `appeared = current_prints - previous_prints` over the two attempts' blocker
  fingerprint multisets (`:1554-1564`). Under (a) those multisets are drawn from
  **disjoint populations** — attempt 1 from the whole stack, attempt N from one
  repair diff — so `fixed ≈ |B|` and `appeared = |current|` on every attempt,
  and neither `STOP_NO_PROGRESS` (`current == previous`) nor `STOP_REGRESSED`
  (`appeared > 0 and fixed == 0`) can ever fire again. The comparison must be
  rebased onto the ledger — `B`'s undispositioned count, attempt over attempt —
  not onto two samples that no longer describe the same surface.
* **`cmd_defer` must carry blockers across attempts.** It unions *suggestions*
  across attempts (`_union_suggestions` + `_carry_prior_suggestions`, `:1436-1439`)
  but takes blockers from a single `document` — the last readable attempt —
  at `:1441`. Once attempts 2..N stop resampling the stack, that array holds only
  second-order findings from the repair diff, and every undispositioned row of
  `B` would be filed nowhere. The blocker path needs the cross-attempt carry that
  only the suggestion path has today — which is §2's gap reappearing as a
  consequence of §2's own fix.

**(b) Give every baseline finding a disposition.** `B` becomes a durable
per-finding ledger with one terminal state each: `fixed | refuted | deferred |
wontfix`.

**The fixers do not emit this vocabulary and the mapping is not one-to-one.**
What `SKILL.md:805-810` actually mandates is `status: APPLIED | NO_CHANGE |
REFUSED` plus a per-finding `outcome: fixed | skipped | no_change_needed`. Only
`fixed` overlaps; `refuted`, `deferred` and `wontfix` have no producer anywhere
in the plugin, and both `skipped` and `no_change_needed` are ambiguous —
`skipped` can mean either `deferred` or `wontfix`, `no_change_needed` either
`refuted` or already-fixed. Since (b) is the decidability keystone of this whole
amendment, the ambiguity is where it fails if left unstated. The fixer contract
must be **widened to emit the ledger vocabulary directly**, with the agent
required to say which of the two readings it means; a controller-side guess
between `deferred` and `wontfix` is not a disposition, it is a coin flip
recorded as evidence.

**Not every disposition may close the gate.** `deferred` and `wontfix` are
terminal states, so a rule reading only *"every row is dispositioned"* is
satisfied by a fixer wave that defers all ten baseline blockers — a gate
**strictly weaker** than today's, where a survivor produces
`reasons: ["blockers_remaining=N"]` and a `not_green` verdict that keeps the run
out of Phases 4 and 5. The gate closes on **`fixed` (verifier-confirmed per (c))
or `refuted` (verifier-confirmed)** only. `deferred` and `wontfix` are operator
decisions: each one holds the gate exactly as a live blocker does unless the run
carries an explicit per-finding acknowledgement, in the shape `/merge` already
uses for `--accept-blocker-deferred`. So the criterion is **"every row in `B` is
`fixed` or `refuted`, or individually acknowledged"** — still decidable, still
monotone, and no weaker than what it replaces.

**(c) Verify with a narrow verifier, not the generator.** A finding whose fixer
reported `fixed` is checked by one agent given the finding and the hunk that
claims to fix it, asked one question: does this address it? It cannot emit new
findings because it is not asked for any, which is the whole point.

`uberdev:finding-verifier` is the right **shape** — one finding in, a bounded
document out — but it is **not reusable as-is**, and this RFC does not get to
present it as off-the-shelf. Its output contract
(`shared/finding-verifier-output-v1.md:16`) is a 0-100 score plus
`reason ∈ {reproduced-from-diff, contradicted-by-diff, pre-existing,
out-of-scope-line, linter-domain, gate-disabled, over-cap-unverified,
verifier-unavailable}`. No token means *"the fix addresses it"*, and a repaired
defect and a never-real defect both land on `contradicted-by-diff` — which is
exactly the `fixed` vs `refuted` split (b) is built on. Its prompt also treats
"the cited line is not one the change modified" as decisive, and under (c) the
cited line is **always** one the fix modified. (c) therefore needs a new prompt
and a new reason vocabulary reusing the agent's shape, not the agent's contract.

**(d) Split the gate's two questions.** "Is this packed stack safe to land?" is
not "is this diff free of anything a reviewer could object to?" The gate asserts:
baseline blockers all dispositioned, CI green, `mergeable` clean. Second-order
defects born in fixer code get **one** bounded pass, and whatever survives it is
filed and the stack still parks. A gate that refuses to park until an LLM runs out
of objections is a gate that never parks.

Chunked review — one reviewer per coherent unit rather than one over the whole
diff — is a real improvement and belongs to **(a)**'s single baseline pass, where
it buys coverage at fixed cost. Applied per-attempt it multiplies the generator
and changes nothing about termination.

#### What this does not change

The A1 ordering (gate before repair), the line-independent multiset fingerprint,
the fixer prompt's prohibition on weakening tests, controller-only commits, the
wave scope guard, and `## The one rule that outranks every other line in this
file` are all untouched.

`STOP_NO_PROGRESS` and `STOP_REGRESSED` are **kept in name and rebuilt in
mechanism**. Their current inputs do not survive (a) — see the `cmd_converge`
consequence above — so they are recomputed from the ledger's undispositioned
count attempt over attempt: no rows closed since the previous attempt is
`STOP_NO_PROGRESS`, and an attempt whose repairs re-opened a previously closed
row is `STOP_REGRESSED`. They stay backstops behind a decidable criterion rather
than serving as the criterion, but "unchanged" would be the wrong word for
them.

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
