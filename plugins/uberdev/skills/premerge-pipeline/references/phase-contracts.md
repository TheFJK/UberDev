# Premerge — phase contracts and their reasoning

Reference for `skills/premerge-pipeline/SKILL.md`. Four contracts the phases depend on but do not need in context to run: how Phase 0 differs from `/review-pr` Phase 0, what a failed push may print and what the stack PR carries, how severity is derived from a reviewer that emits none, and what `PREMERGE_PUSHED` is at each gate call site.

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
pre-receive hook chooses their length and their content. So the five handlers do
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

The built-in reviewer emits **no severity field in either contract**. `/premerge`
derives one, and this is the entire derivation:

> **`blocker`** — the finding names a concrete path to wrong output, a crash, data
> loss, a security hole, or a broken build/CI invariant. Its `failure_scenario`
> describes observable misbehaviour with inputs or state that reach it.
>
> **`suggestion`** — everything else: duplicated logic, needless complexity,
> wasted work, wrong abstraction altitude, a convention violation, a missing test.
> Real, worth doing, not worth holding the stack for.

Two constraints on applying it:

1. **When the finding carries a `category`, the category decides and your
   judgement does not get a vote.** `lib/premerge-findings.py` maps the reviewer's
   own cleanup vocabulary to `suggestion` and everything else to `blocker`, and it
   **exits non-zero** on a severity that contradicts the category. This is not
   advisory: the free-judgement path exists only where no machine-checkable signal
   does, and it collapses to the checked path the instant one appears.

   The cleanup vocabulary is **this exact set** — apply it literally, do not
   paraphrase it, and do not extend it:

   ```text premerge-cleanup-categories
   reuse  simplification  simplify  efficiency  performance  altitude
   conventions  convention  style  documentation  docs
   test-coverage  tests  naming  readability
   ```

   Every other slug is correctness-class, so the severity you write for a
   finding carrying one **must** be `blocker`. (`CLEANUP_CATEGORIES` in
   `lib/premerge-findings.py` is the enforcer and the source of truth; this copy
   exists because the controller that writes `severity` never opens that file,
   and a rule it cannot see is a rule it will break.)

   **The block above carries the `premerge-cleanup-categories` tag because a
   test reads it.** `tests/premerge.test.sh` P3b imports `premerge-findings.py`,
   evaluates the real `CLEANUP_CATEGORIES`, and compares it set-for-set with
   these tokens. "Edit the two together" was the whole enforcement before, and a
   prose instruction is not one: the only test touching the constant was a grep
   that the identifier exists, which stays green whichever copy drifts — and the
   copy the controller actually reads is this one, the copy with nothing behind
   it. Drift here is `severity_contradicts_category`: `plan` exits 74 having
   written nothing, and the whole attempt dies because the reviewer used a
   synonym. Do not retag or reflow the block without updating that row.
2. **An unfamiliar category is treated as correctness-class, and reading that
   the other way costs the whole attempt.** The asymmetry itself is deliberate: a
   novel *correctness* slug silently demoted to `suggestion` ships the bug. But
   the price of the safe direction is not "one needless fixer dispatch". A slug
   that is not in the set above, written up as `suggestion` because it *reads*
   like a cleanup, is `severity_contradicts_category` — `plan` **exits 74 before
   writing anything**, which per `## Phase 2 — TRIAGE` is a hard stop for the
   attempt, not a fall-through. The needless fixer dispatch is what you get from
   classifying it `blocker`, as the rule requires: that is the cheap outcome, and
   it is the one to pick.

`verdict` is **confidence, not severity** — `CONFIRMED` vs `PLAUSIBLE` says how
sure the reviewer is that the mechanism is real, not how much it matters. Never
map `PLAUSIBLE` to `suggestion`. At `xhigh` on Opus-family models no verify pass
runs at all and `verdict` is absent from every finding, so any rule built on it
would silently become a no-op exactly where it was supposed to help.

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
