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
backstop, not the stop condition. The stop conditions are `STOP_NO_PROGRESS` and
`STOP_REGRESSED`, and deleting them to "simplify" the loop restores exactly the
hazard RFC 0021 refused a loop over: three attempts that achieve nothing, the
third of which quietly edits a test.

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
