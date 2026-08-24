# Premerge — common mistakes

Reference for `skills/premerge-pipeline/SKILL.md`. Every entry is a failure this pipeline has actually shipped or been one edit away from shipping. Read the entry a refusal names before working around that refusal.

## Common Mistakes

**Merging.** Covered above and worth repeating because every other pipeline in
this plugin ends somewhere near a merge. This one does not.

**Gating on a stale attempt's evidence.** After a fix lands, an earlier attempt's
blocker list describes code that no longer exists. Gate on
`classified-<NN>.json` for the attempt you are in — and pass `--head-sha`, which
is what catches the nastier version: a `plan` that REFUSED (a >64-finding review,
a finding the reviewer emitted twice) exits before writing anything, so the previous attempt's
artifact is still sitting there looking perfectly fresh.

**Dispatching the fixers before the gate.** The single most dangerous edit
anyone will make to this file, because it looks obviously right — find the
blockers, fix them, then check. It deadlocks the loop: `plan` stamps the SHA the
review saw, the fix commit moves `HEAD`, and the gate then reports
`stale_evidence` on every attempt that actually fixed something. The commit fence
refuses without a `not_green` gate verdict for the attempt, so the mistake fails
loudly rather than silently converging on nothing. See
`## The order within one attempt`.

**Bounding the loop with the counter alone.** `--converge=3` is a runaway
backstop, not the stop condition. The stop conditions are `STOP_NO_PROGRESS`,
`STOP_REGRESSED` and `STOP_SELF_REFERENTIAL`, and deleting them to "simplify" the
loop restores exactly the hazard RFC 0021 refused a loop over: three attempts
that achieve nothing, the third of which quietly edits a test.

**Terminating the loop on the reviewer going quiet.** A critic asked *what is
wrong with this?* samples from an unbounded set, so an attempt that returns no
blockers is a property of that sample and never of the stack. Find → fix →
re-find therefore has no fixed point to reach, which is why a round counter ends
up doing the stop condition's job. `GROWTH=` is the substitute: the fraction of
an attempt's blockers that are new **and** sit in a file the previous attempt's
repair modified — work this loop made for itself. At `1.00` the loop is reviewing
its own output, and the response to that is to stop, not to repair again.

**Reading `GROWTH=-` as `GROWTH=0.00`.** The dash means the ratio was not
measured, and five things produce it: (1) attempt 1, which has no previous repair
to attribute anything to; (2) a previous attempt that committed no edits, so the
commit fence exited `REASON=no-edits` and wrote no `fix-scope-<NN>.modified`;
(3) a previous attempt that repaired through the Phase 3 CI arm, which pushes
real code edits but publishes `ci-scope-<NN>.*` and no scope list this
measurement reads — the one cause that makes the stop unreachable, and the
subject of *Reading "the round is not measured"…* below; (4) an attempt with no
**reviewer-raised** blocker to divide by, which includes one holding only
`blocked_on_carry` rows, since a carried row counts on neither side; and (5) a
scope file that is present but could not be read. Only the fifth is a fault, and
it is the one an operator otherwise misses: it announces itself as
`premerge-findings: repair_scope_unreadable:` on stderr and nowhere else, so a
`-` on the line is a reason to go and check stderr, not only to note that the
ratio was undefined. `0.00` by contrast IS a measurement — the previous repair
authored none of this round's findings, the healthiest reading the signal has.
Collapsing the two turns "we did not look" into "we looked and it was fine", in
the run summary an operator reads to decide whether to raise `--converge` or cut
the stack down.

**Raising `--converge` on a run that stopped `STOP_SELF_REFERENTIAL`.** That stop
pre-empts `STOP_EXHAUSTED` on purpose, because the two call for opposite moves:
the budget stop says a loop that was still winning ran out of rounds, and the
self-referential stop says more rounds would only enlarge the loop's own
haystack. Cut the stack down or lower the review level instead. Nothing is lost
either way — it is a not-green stop, so Phase 5 runs with `PREMERGE_SURVIVORS=1`
and files every surviving blocker as an issue. The claim is "not *this loop's*
work", never "not work".

**Firing the growth stop on a single round — or on the ratio alone.** Two ways of
under-counting the same test, and both stop loops that were working. A round is
**eligible** on **three** conditions, not one: `GROWTH=` is measured, it is at or
above `PREMERGE_GROWTH_CEILING`, **and** the round did not reduce the
reviewer-raised blocker count (`blockers >= previous_blockers`, read off the
previous attempt's own `converge.jsonl` row rather than a variable a fence could
forget). Then `PREMERGE_GROWTH_RUNS` consecutive rounds must clear all three.
The third condition is not decoration: `GROWTH=` answers what the residual is
made **of**, never which way the run is going, and since the denominator shrinks
as the loop succeeds while the reviewer keeps resampling the file the repair just
touched, the ratio RISES toward `1.00` exactly as a run converges. Shipped
without it, a measured 5 → 2 → 2 run read `0.50` twice and stopped with three of
its five repair rounds unspent. The second round is not timidity either — every
attempt's blocker set is a fresh sample of an unbounded generator, so one high
round is equally consistent with a convergence whose repairs happen to be
concentrated in a few files. RFC 0021 A3 records that stopping such a loop, not a
detector falling silent, is the real failure mode; a run log showing `GROWTH=0.90`
twice and no stop is the count condition doing its job, not the detector failing.

**Making the growth ratio precise before making it used.** File-level membership
over-counts: a new finding anywhere in a touched file counts as growth. It is a
signal, not a proof, and that is deliberate — it is also why the stop needs two
consecutive eligible rounds rather than one. The precise version needs diff-hunk
mapping against a review pointed at one repair's delta, and RFC 0021 A3 C8 records
that no such dispatch exists yet — building it here would replace a working coarse
signal with a keystone nothing can invoke.

**Reading "the round is not measured" as "the round repaired nothing".** The one
inference that is worth more than the ratio's precision, because it is the case
where the detector is switched **off** rather than merely coarse.
`_repair_scope_path` opens `fix-scope-<NN>.modified` and nothing else, so a
*present, pushed, genuinely code-changing* repair still reads as no scope if it
published under another name — and one arm does exactly that. Phase 3's CI fence
on `arm=commit` dispatches `ci-code-fixer`, compares its diff against
`ci-scope-<NN>.allowed`, pushes, and publishes `ci-scope-<NN>.*` only. The next
attempt therefore prints `GROWTH=-` and is not eligible, and a loop that keeps
repairing through that arm can never accumulate two consecutive eligible rounds:
`STOP_SELF_REFERENTIAL` is structurally **unreachable** for it. Not hypothetical
— the run that surfaced this took that path at attempt 1. Nor is it closable from
the findings side: `ci-scope-<NN>.changed` is written before the scope comparison
and before the push, and attributing a round's findings to edits that may never
have left the machine trades one wrong measurement for another. The half that
closes it is a durable publish in the CI fence itself — SKILL.md, not the library
— and until that lands, `-` is the honest report and it stops nothing.

**Reading `converge`'s exit status as success or failure.** `STOP_GREEN` exits 1.
1 means "stop", 0 means "go round again". Branch on `DECISION=`.

**Filing issues inside the loop.** `findings-to-issues` keys the ISSUE on the
owning file, so a second dispatch comments rather than duplicating — but every
fix moves lines, so each attempt re-lists the same members as new and turns
one issue into a per-attempt transcript, while burning the per-dispatch
`MAX_NEW` and rate-limit budget doing it. It also re-`os.replace`s the
aggregate under an in-flight dispatch, which that agent refuses as
`input-malformed`. File once, at Phase 5.

**Letting a fixer edit the test instead of the code.** The named hazard. It is
guarded in the fixer prompt and by the progress detectors, and both halves are
load-bearing — a prompt rule with no detector behind it is a suggestion.

**Letting Phase 4 be the last word.** A refactor pushed after the last gate is
unverified code with a green summary attached. `### 4c — VERIFY` re-probes and
re-gates it, and reverts the polish rather than parking a stack it broke.

**Reverting past the fix commits.** `4c`'s revert takes out the *simplify* commit
only. The fix commits are what made the stack green.

**Reading `verdict` as severity.** `PLAUSIBLE` means "the mechanism is real, the
trigger is uncertain", not "minor". And at `xhigh` on Opus-family models no verify
pass runs, so a `verdict`-based rule is a no-op precisely where it was meant to
help.

**Letting a WAVE agent run git.** The Phase 2a and Phase 4b wave agents are
`general-purpose` and are told outright not to touch git; the controller owns
their commit. An agent that commits produces a commit nobody validated, on a
branch whose HEAD other fences assert against.

**Assuming that rule covers the CI agents too.** It does not, and reading it that
way makes CI repair silently do nothing. `uberdev:ci-code-fixer` commits locally
by contract and `uberdev:ci-rebase-handler` rewrites the branch, so the Phase 2a
commit fence finds a clean tree and reports `COMMIT=none REASON=no-edits`. The
CI arm publishes its own work — see `#### Repairing red CI` — and the rebase arm
needs the `--force-with-lease` SHA captured *before* dispatch.

**Reading "the CI arm owns its publication" as "the CI arm skips the checks".**
A different commit fence is not no commit fence. `premerge-ci-publish` carries
the same three load-bearing checks as the Phase 2a fence — branch assertion,
untracked refusal, scope comparison — because `ci-code-fixer`'s "minimal-scope
edits" is a prompt-level assurance and the entry below says outright that a
prompt-level assurance is not enforcement. The arm that publishes without them
puts agent-authored commits on the stack PR unexamined.

**Two agents in one wave sharing a file.** `_fix_waves` groups by path so this
cannot happen — do not "optimise" it into one-agent-per-finding.

**Adding a `blocked_on_file` path straight to the commit fence's allowed set.**
The smallest possible diff, and wrong twice over. The fence derives the
committable set from `fix-waves-<NN>.json` and nothing else, which is what keeps
"committable" and "owned by exactly one agent" the same set. A path in the
allowed list with no wave entry is committable while nobody owns it, and
`_fix_waves` never grouped it, so the disjointness above says nothing about the
two next-wave agents that may now both edit it against the one worktree those
waves share with no isolation. Worse, the wave plan is also what DISPATCHES the
fixers, so a `blocked_on_file` path that reached only the allowed list is edited
by nobody: the cross-file consequence survives the round untouched — the very
failure the widening was reaching for. The paths go through `_fix_waves` as
synthesised blocker findings, never around it.

**Unioning `blocked_on_file` across every earlier attempt.** The sibling in the
same file invites it — `_carry_prior_suggestions` walks `range(1, attempt)` —
and copying that shape reads as consistency. It is correct there because a
suggestion is never fixed and must not be lost. A blocked-on path is the
opposite: it WIDENS what a fixer may edit, so a union over every earlier attempt
only ever grows, and the repair budget runs to `PREMERGE_REPAIR_CEILING` rounds
— a set that grows every round is no longer a guard by the last of them. Exactly
one predecessor: `plan --carry-blocked` opens `blocked-on-<N-1>.json` by name,
never a range, and what survives validation is capped at
`PREMERGE_MAX_BLOCKED_ON`.

**Trusting "Edit ONLY `<path>`" because the prompt says it.** The prompt is the
instruction; the commit fence's scope check is the enforcement. `git add -u`
stages every tracked modification in the tree, so without that comparison
against `fix-waves-<NN>.json` an agent that wandered into a second file — or any
stray hunk sitting in the tree — lands in the stack commit unreviewed, and the
file-disjointness the wave design rests on becomes a claim nobody checks.

**Treating an empty findings artifact as an absent one.** `findings: []` means the
reviewer found nothing. A missing `review-input.json` means something broke. If
those two collapse into one state, every future failure reports as a clean run.

**Answering a repo-kind question with a plugin-kind probe.** `[ -r
"$PLUGIN_ROOT/lib/<anything>" ]` is true in every repository the plugin is
installed into. Any guard meant to mean "this repo is not UberDev" must read a
path under `$PREMERGE_ROOT`, and any guard that cannot fail in normal operation
is not a guard — it is a comment that costs an `if`.

**Leaving the run directory unignored.** Phases 0a and 0b are five fences apart,
and the first writes into the tree the second gates on. It looks fine here and
only here, because this repo's own `.gitignore` covers `.uberdev/`.

**Bumping by hand.** Six surfaces plus two hidden CI ratchet locks
(`tests/goal.test.sh` G20, `tests/solve-claim.test.sh`). `bump-version.sh` is the
only correct writer.

**Skipping the accounted-for gate in 0c.** It is the substitute for the assertion
`/premerge` deliberately does not run. Removing it leaves the pack with no
completeness proof at all.
