# Premerge — phase contracts and their reasoning

Reference for `skills/premerge-pipeline/SKILL.md`. Four contracts the phases depend on but do not need in context to run: how Phase 0 differs from `/review-pr` Phase 0, what a failed push may print and what the stack PR carries, what `PREMERGE_PUSHED` is at each gate call site, and what the Phase 5-trail fences require at theirs. The severity rule is the one contract that must NOT live here — `## The severity rule` below says where it is and why.

### What `/premerge` does differently from `/review-pr` Phase 0

| | `/review-pr` Phase 0 | `/premerge` Phase 0 |
|---|---|---|
| Trigger | an `AskUserQuestion` offer, declined by default under `--turbo` / no-TTY | unconditional; packing IS the command |
| Minimum candidates | 2 (below that the offer is noise) | 1 (a stack of one still earns the review, the bump and the park) |
| Invoking PR | must exist and must survive the combine (`review_consolidate_assert_current`) | **none** — `/premerge` runs from the integration branch, so that assertion has no referent and is deliberately NOT called |
| Substitute invariant | — | every discovered candidate must end the phase either **included** or **excluded with a typed reason**; a candidate present in `candidates.json` and absent from both ledgers halts the run |

That last row is the whole reason it is safe to drop `assert_current`. The
assertion `/review-pr` needs is "the PR you invoked me on is in here". `/premerge`
was invoked on no PR, so it asserts the strictly stronger thing instead: nothing
that was discovered went missing. `review_consolidate_assert_ancestry` still runs
unchanged and still proves every *included* candidate's head is reachable from the
combined HEAD.

### What a failed push is allowed to say

Every `git push` in this file captures its stderr, because a push that exits 2
without a word is a dead end mid-loop. But *what* it captures is not this repo's
text: everything a server sends back arrives as `remote:` lines, and a
pre-receive hook chooses their length and their content. So the six handlers do
not print the capture — they print a **bounded, single-line, token-free** view of
it, rebuilt in place by one line. That line is deliberately not reproduced here —
the fences are its only copy, so this section cannot come to describe a bound the
code stopped enforcing. It does three things, one hazard each:

- **`cut -c1-200`** is the bound `agents/findings-to-issues.md` puts on every
  attacker-influenced `gh` stderr — *"bounds attacker-influenced stderr
  substring"* (its security Note B). A rejection message is as long as the
  server wants it to be, and this fence's every other diagnostic is
  length-bounded already.
- **`tr -s '\n\r\t' ' '`** folds the capture onto one line. The fence's own
  `PREMERGE …` results go to this same stderr stream and the controller scrapes
  that stream positionally, so a multi-line capture is a way for a remote to open
  a line of its own in it.
- **`PREMERGE` → `PRE-MERGE`** breaks the token spelling, because collapsing to
  one line is not on its own enough: a `remote: PREMERGE CI PUBLISH=<sha>
  ARM=commit ATTEMPT=3` line is a well-formed controller result no matter where
  it sits. Broken this way it is still perfectly readable to an operator, and it
  cannot be mistaken for a second `PREMERGE` line — nor accidentally rewritten
  into a *different* live token, which is what substituting only the trailing
  space would do to `PREMERGE GATE …`.

Three details that are deliberate, not incidental:

- **Drained readers only.** `head -c 200` is the precedent's literal spelling and
  it is an early-exiting reader; these fences set `set -u` and not
  `set -o pipefail` today, but the day one adds it that shape is the EPIPE class
  `tests/epipe-guard.test.sh` bans. `tr` and `cut` read to EOF — and so does the
  rebase arm's classifier, which is a bare `grep -E` with no `-q`, `-m` or `-l`
  for exactly that reason. The question never arises.
- **The bound is a property of what gets PRINTED, not of what gets classified.**
  In four handlers that makes it the first statement, because printing is all
  they do. The rebase arm in `#### Repairing red CI` also *classifies*, and there
  the bound runs after the classifier and immediately before the print. Bounding
  first was tried, and the argument for it does not survive being executed: the
  precedent bounds a `gh` stderr whose marker is at the head, while git puts
  `To <remote>` and every server `remote:` line ahead of
  `! [rejected] … (stale info)` — and with a 43-character branch name spelled
  twice inside that one line, **two** banner lines already push the marker past
  character 200. Run against the shipped handler under both `bash` and `zsh`: a
  plain rejection classified as a lease rejection, the same rejection behind two
  `remote:` lines classified as a generic failure. That is the one failure mode
  this arm exists to name being reported as the one it exists to tell it apart
  from, with the branch already rebased locally and no recovery arm. Flattening
  first failed in the opposite direction — every line joined into one, so
  `\[rejected\].*(stale info|…)` could bridge two originally unrelated lines and
  call an ordinary failure a lease rejection. `grep` is line-oriented, so
  classifying the capture as git wrote it closes both.
- **The verdict and the message still read the same bytes.** That was the old
  ordering's reason for itself, and it is honoured more strictly now rather than
  dropped: a verdict drawn from bytes the operator is never shown is a verdict
  the message can contradict, so the rejection arm prints the **matched line** —
  bounded, flattened and defused like everything else — while the generic arm,
  which matched nothing, prints the head of the capture.

### What the stack PR carries

`review_consolidate_body` renders it, and the shape is a contract:

- **`## Consolidated PRs`** — every superseded original by number and title.
- **`## Excluded`** — every candidate that could not be packed, by number, with
  its typed reason (`cross_repo`, `closed_mid_run`, `base_deleted`, `fetch_failed`,
  `conflict_unresolved`, `ancestry_lost`, `push_refused`). The enum has a single
  declaration in `lib/review-consolidate.sh` and is not restated here so it cannot
  drift.
- **The deduped union of the originals' `Closes #N` references**, so the
  underlying issues still close when the stack lands.

The originals keep their labels and stay open. They receive exactly one
supersession comment: no label, no close, no merge, no assignee change.

## The severity rule

**Normative in `skills/premerge-pipeline/SKILL.md`, under its own
`## The severity rule` heading** — the derivation, the two constraints on
applying it, the tagged `premerge-cleanup-categories` block and the
`verdict`-is-confidence rule are all there, and deliberately have no copy here.
It lives there and not here because SKILL.md is the only file loaded eagerly
when the skill fires, while anything under `references/` is loaded on demand and
may never be opened in a given run: the controller has to write a `severity` for
every finding it records, and a rule it cannot see is a rule it will break.

### What `PREMERGE_PUSHED` is at each call site

The fence takes `PREMERGE_PUSHED` with `:?` and no default, because *"defaulting
it to 0 would make the SAFE answer the one you get by forgetting"*. That only
holds if the file says what the value **is** at every place the gate runs — and
it used to say so at exactly one of them (`### 4c` step 3). A controller left to
infer the rest passes `0` at a gate that just pushed, `no_checks` is read as
green, and the stack passes on a build that has not started: the whole race
`--after-push` exists to close, re-entered through the input that closes it.

Every call site, and the value each one passes:

| Gate call site | `PREMERGE_PUSHED` | Why |
| --- | --- | --- |
| Phase 3, first entry at attempt 1 | `1` | `### 0c` pushed the stack branch and opened the PR immediately before Phase 1. The branch is new, so its checks are the ones just triggered |
| Phase 3, re-entry after `premerge-fix-commit` | `1` | That fence ends in `git push origin "$PREMERGE_BRANCH"` |
| Phase 3, re-entry after `premerge-ci-publish` (commit arm **or** rebase arm) | `1` | Both arms end in a push; the rebase arm's is a `--force-with-lease` |
| Phase 3, re-probe from a `WAIT_CI` decision | `1` | The re-probe asks about the SAME push that produced the wait. See the row in `### 3c` |
| `### 4c` step 3, after the simplify commit | `1` | Already stated there; repeated here so this table is the whole list |
| Phase 3 run against a stack nothing has pushed to since its last probe | `0` | The only `0` case, and it is not reachable from the loop above — it exists for a manual re-run of the fence on an already-settled branch |

There is deliberately no "controller decides" row. If a future arm ends without
a push, it adds a row here; a gate whose input is inferred is a gate whose
correctness is inferred.

### The CI settle window

A push restarts checks, and `test.yml` fires on both `push` and `pull_request`
with nothing cancelling the loser. For roughly the first 10–30 seconds after a
push, `gh pr checks` legitimately reports **no checks at all** — which the gate
would otherwise read as `no_checks`, i.e. green. That is a premature pass on a
build that has not started, and under a loop it stops being an edge case:
**every attempt ends in a push.**

`--after-push` is the structural fix RFC 0021 §9 deferred. When the attempt
pushed, `no_checks` becomes the reason `ci=no_checks_after_push` instead of a
pass, and Phase 3b routes it to `WAIT_CI` — which re-probes without consuming an
attempt. `pending` is a "come back later" state, not a verdict; it is polled out,
never gated on.

**But `--after-push` is only right where a check is actually coming.** The flag
is conditioned on *this PR getting checks at all*, not on the repo containing a
workflow file — a repo whose only workflow is `on: schedule` or
`on: workflow_dispatch` has a file and will never have a PR check, and a gate
that waits for one spends the whole `PREMERGE_WAIT_CI_CEILING` and then reports
`STOP_UNREADABLE` about a stack that was green. The fence answers the question in
this order:

1. **Has any probe in this run already seen a check on this PR?** The gate
   records that the first time `PREMERGE_CI` lands on `red`, `pending` or
   `green`, in `$PREMERGE_RUN_DIR/ci-observed`. It is one-way and run-scoped: a
   PR that had a check once gets checks, so a later `no_checks` is the settle
   window and nothing else. This is the conclusive signal.
2. **Cold start only** — nothing observed yet, which is where the very first
   post-push gate of a run sits. Then the tree decides, narrowed from "a
   workflow file exists" to "a workflow file declares a **PR-reachable
   trigger**" (`pull_request`, `pull_request_target`, `push`, `merge_group`).
   Ambiguity resolves toward waiting, because a needless wait costs minutes and
   a premature green ships an unbuilt stack.

Two other answers the probe can give are **not** the settle window, and reading
them as it is how this gate would go back to passing on evidence it never read.
A `gh pr checks` that failed outright — expired auth, a network drop, a 404, a
rate limit — is `unknown`, never `no_checks`; the fence tells the two apart by
corroborating with `gh pr view --json statusCheckRollup`, because the exit
status means "a check failed" or "checks are pending" just as often as it means
"the probe never ran". And a `cancel` bucket is **terminal**: a cancellation a
same-named run replaced is dropped, one that nothing replaced is `red`. Waiting
on either only spends the ceiling to arrive at `STOP_UNREADABLE` about a state
that was never going to change.

`PREMERGE_WAIT_CI_CEILING` bounds the waiting. A check that never settles is not
a reason to loop forever, and after that many re-probes the loop calls the
evidence unreadable and stops — which is a *not-green* stop, never a pass.

### What the Phase 5-trail fences require at their call sites

Both fences take their inputs with `:?` and no default, so the value at every
call site is part of the contract rather than a convention.

| Fence | Variable | Value at the call site |
|---|---|---|
| `premerge-trail-gate` | `PREMERGE_ATTEMPT` | the attempt the loop stopped on — the same number the CONVERGE phase last wrote a ledger row for |
| `premerge-trail-gate` | `PREMERGE_STOP` | the `DECISION=` token from that ledger row, verbatim. Never re-derived, and never inferred from an exit status: `STOP_GREEN` exits **1** by design |
| `premerge-trail-emit` | `PREMERGE_TRAIL` | the `TRAIL=` token the gate fence printed — `emit` or `skipped`. Anything but `emit` exits **0** having published nothing |
| `premerge-trail-emit` | `PREMERGE_TRAIL_ATTEMPT` | the zero-padded `ATTEMPT=` token from the same line, which becomes the `attempt=NN` half of the trailer's gate token. The two digits are checked, not assumed: `/merge` matches the trailer suffix against `^gate=green attempt=[0-9]{2}$`, so an unpadded `3` is refused with exit **2** before any write — never silently skipped |

The gate fence runs after the post-simplify VERIFY step has re-gated the simplify
commit and before the bump, so the HEAD it binds to is the last gated tree. A
controller that runs it earlier binds a trail to a tree the simplify phase is
about to change; one that runs it after the bump binds it to a release commit no
gate read.

**Four refusals, one shape.** `stop_not_green`, `gate_unreadable`, `not_green`
and `head_moved` are the whole set the gate fence can print, each on the same
`PREMERGE TRAIL=skipped REASON=…` line, and `### 5b — PARK`'s trust-trail row
transcribes whichever one it was. They are separate tokens because they call for
different next moves: the first says the stack still has work in it, the last
says something touched the branch after the gate read it, and a run that
collapsed them into a blank row would withhold the one thing an operator can act
on. All four exit **0** — declining to emit is an ordinary outcome the run
continues past, not a failure of the fence.

**The emit fence prints a different vocabulary, and `half_emitted` is in it.**
The four reasons above are the *gate* fence's whole set. The publication fence has
its own, and a controller that knows only the gate's has no arm for the state that
matters most. It prints `PREMERGE TRAIL=emitted ANCHOR=<sha> PR=<n>
LABEL=premerge-approved` on success and exits **0** — `emitted`, past tense, not
the gate's `emit` — and `PREMERGE TRAIL=half_emitted` with
`REASON=label_unprovisioned` or `REASON=label_unapplied`, each carrying
`ANCHOR=<sha> PR=<n>`, when the anchor reached the remote but the label did not.
Both of those exit **2**. Everything that refuses *earlier* than the push prints a
bare `error:` line, no `TRAIL=` token at all, and exits **2** — there is nothing
emitted for a token to describe. `### 5b — PARK`'s trust-trail row transcribes all
three forms, and `half_emitted` must never be collapsed into `none`: `none` says
nothing reached the remote, `half_emitted` says half of it did.

**Past the push there is no rollback, and that is the design.** By then the anchor
is a pushed commit, and taking it back means force-pushing a branch other clones
may already have fetched — so both `half_emitted` arms report a state rather than
pretend to undo one. Leaving it standing is safe because the state fails
**closed**: `/merge` resolves PATH_2 from the label *and* the trailer, so an anchor
wearing no label resolves nothing. The recovery is to re-run the idempotent label
step, never to rewrite the branch. The ordering that produces the state is itself
deliberate — the push runs before the label because, of the two artifacts, the
irreversible one is the inert one and the one carrying the visible claim is the one
a re-run can still fix.

**Before the push, every refusal unwinds its own anchor.** The anchor commit is
still local there, and 5a pushes this branch a few steps later, so one left behind
is one 5a publishes: a premerge trailer with no label and no gate anyone consented
to. Those arms `git reset --soft` back to the gated parent — `--soft` moves the
branch pointer and touches neither the index nor the working tree, so the
pre-commit state comes back whole, staged bytes included. One arm deliberately does
**not** unwind: the one that finds the anchor's parent is not the head the fence
read. A branch whose shape the fence cannot account for is one it must not rewrite,
so that arm refuses and leaves it for a human.

**The write-guards all assert before the first write.** The PR number the anchor
names comes from `combined_pr` in the run directory's `manifest.json`, not from the
call site, and `jq -r` is not a validator: a manifest missing that key prints the
string `null` and exits **0**, so the `|| exit 2` never fires. Unguarded, the fence
would anchor `... for #null`, push it, and fail only at `gh pr edit null` — landing
squarely in the post-push state the paragraph above says cannot be undone. A
numeric-shape check refuses it first, exactly as the two-digit check on
`PREMERGE_TRAIL_ATTEMPT` refuses an unpadded attempt first: assert before the first
write, never repair after it. The fence also declines to trust the checkout it
inherits — it reads HEAD itself, refuses unless HEAD is on the stack branch named
in the run directory, and refuses unless the anchor it just made carries that same
head as its parent.

**What the trail claims, and what it must never be read as claiming.** It says
`/premerge`'s clean gate was green on this exact head: blockers cleared, CI green
or absent, the stack not conflicting, and the evidence stamped with the branch's
own HEAD. It says nothing about the seven-lens review fanout, the
finding-verification pass or the CI-health phase — under `/premerge` none of them
ran, and the instrument field in the trailer is the thing that keeps the claim
honest rather than a convention someone has to remember. `/merge` resolves the
instrument from the label *and* from the trailer, refuses when the two disagree,
and records a green premerge trail under its own trust anchor, so an audit
consumer can tell the two tiers apart without reading either producer.

**And a trail is still not permission to merge.** It changes which PRs `/merge`
is *able* to resolve a trust path for; it changes nothing about who decides that
a specific PR should land. `/premerge` parks the stack PR and dispatches nothing.
