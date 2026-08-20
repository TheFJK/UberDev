# Changelog

All notable changes to UberDev are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.51.3] — 2026-08-19

### Added - the four remaining published solve-fleet contracts are compared against the script

`tests/docs-accuracy.test.sh` T16 already joined the per-task record, the
`reviewVerdict` union, `partialDelivery` and the enclosing per-issue record
between `skills/solve-fleet/SKILL.md` and `skills/solve-fleet/workflow.js`. Four
more shapes the same two files publish had **no comparator at all**, so a drift
in any of them was invisible to every fixture in the repo (#588):

- the per-task `claimedStatus` roster - documented sentence against
  `TASK_CLAIMABLE`, resolved through `TASK_STATUS` because the roster is spelled
  as references rather than literals, unioned with the empty-string fallback the
  assignment writes. Read from `TASK_CLAIMABLE` and never from `TASK_STATUS`,
  and a row asserts that outcome: the two differ by `SKIPPED`, which no
  implementer can claim.
- the per-issue `status` union, in **all three** of its copies - the documented
  union, the solve schema's `enum`, and the solver prompt that tells an agent
  which words it may answer with. The prompt copies are compared to each other
  as well as to the schema, because a merged set hides a member lost from
  exactly one of them. Each copy is anchored on the return line it rides on and
  never on a member of the union: an anchor taken from the vocabulary under
  comparison is dissolved by the drift it exists to catch, so the copy leaves
  the set silently instead of failing. The extracted copies are then required to
  equal the per-issue return lines in the script, which catches the one shape
  re-anchoring cannot - a return line that drops its union outright.
- the `prProof` union - the documented table cell against the classification
  assignment sites, anchored strictly on assignment rather than on the symbol,
  which this script also uses as a relay-schema property name.
- the **top-level return object**, plus nested `counts` and `verification` as
  their own pairs.

Every pair runs in both directions behind its own anti-vacuity floor, and each
floor sits well under the live member count so it stays a vacuity guard instead
of becoming a size ratchet.

Measured before these rows existed, one realistic drift per contract - a member
dropped from the `claimedStatus` sentence, a member added to the solve `enum`
and documented nowhere, a member dropped from one solver-prompt copy, a member
dropped from the `prProof` cell, a key dropped from the Return value fence, a
`counts` bucket renamed there, and a `verification` member invented there. Every
one of them left both this suite and `tests/solve-fleet-workflow.test.sh` at
their clean totals, rc 0. Each now reds the row that owns it.

Three further drifts were measured against one solver-prompt copy, each leaving
the other copy untouched: renaming its leading member, reordering the union so a
different member leads, and deleting its union clause. All three passed both
suites at their clean totals before the copies were re-anchored, the rename
being a live defect - the agent is told to answer a word the schema `enum`
rejects, so its structured return is discarded and the run reports a null result
that names nothing. All three now red.

Two helpers carry the new reads: `sf_js_object_keys` (depth-tracking script-side
key extraction, because `finalize()`'s return nests objects that `sf_js_keys`'
brace-free window cannot span) and an optional opener argument on
`sf_doc_record_members`, for a fence that opens on a line below its anchor. The
new helper joins the existing fail-open roster, so a rename aborts with rc 2
rather than reporting a fabricated pass.

### Changed - the hand-picked return-key grep in the solve-fleet suite is retired

`tests/solve-fleet-workflow.test.sh` G30 checked one chosen key of the return
object (`tasksApproved`) with a whole-file grep, which certified that key and
nothing else. The key set is now joined in both directions, so the grep is
deleted rather than left standing beside the stronger predicate, and G30's
pass/fail text no longer claims to cover the return keys. Verified: dropping
`tasksApproved` from the fence reds the new reverse row by name.

## [0.50.3] — 2026-08-19

### Fixed - L10's label vocabulary was blind to the tier-escalation labels

`L10_LABELS` was scraped exclusively from shipped shell (`sed` for
`*LABEL*='uberdev:<name>'`), but `lib/solve_triage.py` BUILDS the tier-escalation
label names by concatenation (`ESCALATION_LABEL_PREFIX + tier`), so no
`uberdev:tier-*` literal exists anywhere for that scrape to find and every one of
them resolved to `none`.

Surfaced by v0.50.0 (#619): collapsing the `large` rung deliberately RETAINED
`uberdev:tier-large` as a migration alias, so a pre-#619 ratchet write still lifts
instead of being dropped as an unknown tier. The retained alias is named in
`skills/solve-pipeline/SKILL.md` and `docs/rfc/0019`, and L10.2 flagged that prose
as a dangling citation.

The escalation half of the set is now DERIVED from the shipped module at run time
(`ESCALATION_LABELS` keys) rather than transcribed, matching the discipline L10.4's
kind lists already follow: a rung added, removed or aliased moves this set with it.
Fails closed - an unloadable classifier yields an empty extraction and the citations
red. Proven both directions: greens on the real retained `tier-large`, reds on
`tier-enormous` and `ghost-thing`.


### Fixed - CI could report "nothing failed before it stopped", never "the suite is green"

All three jobs in `.github/workflows/test.yml` joined their whole test list with
`&& \`, so each `run:` block was ONE shell command list and the first non-zero
exit short-circuited every invocation after it. There were three chained blocks,
not one: `shape-checks` (125 invocations), `shape-checks-windows` (67) and
`supervision-smoke-macos` (8) — 197 chained joins in total, so a single early red
could hide up to 124 files. #551 is the recorded instance rather than a
hypothetical: `supervision-smoke-macos` ran 630 of `tests/child-dispatch.test.sh`'s
1338 lines, exited 0 through a bash 3.2 status laundering, and the chain happily
continued past it. The exit floor closed the laundering; nothing had closed the
hiding.

Each block now carries an identical failure-accumulating harness: `run_one` calls
every fixture, records the ones that fail, and the tail exits non-zero naming
them. Measured on a four-fixture probe with the second one failing: the old chain
ran 2 of 4 and exited 3; the new harness runs 4 of 4, exits 1, and prints which
file failed.

`tests/ci-wiring.test.sh` gains **W12** to keep it that way — a denominator row,
the verdict, a both-directions polarity proof driven through the same classifier
the verdict uses, a row asserting the three per-job harnesses stay byte-identical,
and an **execution** proof that extracts the harness the workflow actually carries
and runs it against a failing fixture. A grep can only say the `&&` is gone; only
running it can say a red file no longer hides the ones behind it.

W11's forgery probe was re-keyed at the same time. It mutated any line *beginning*
with `bash `, which after the de-chaining rewrote nothing — leaving the real wiring
in the "forged" copy and reporting a forgery that had not happened. It now keys on
"names the fixture and is not already a comment", which is what the forgery is.

### Fixed - the shipped testing doc still described the retired chained shape

`plugins/uberdev/docs/testing.md` is the harness SSOT CONTRIBUTING.md points at,
and it asserted that each test "exits non-zero if any assertion failed — so
`&&`-chaining them (as `test.yml` does) stops at the first red file". After the
de-chaining above, `test.yml` chains nothing. A contributor reading it would stop
scanning the job log at the first `--- FAIL`, or re-chain a new block "to match
the documented shape" and then be unable to explain why W12 reds. A second
sentence carried the same stale premise: the `supervision-smoke-macos` note ended
"the job's `&&` chain carries on green", when the hazard it describes — a fixture
laundering its own exit status on bash 3.2 — survives de-chaining untouched,
because accumulating failures still means accumulating the statuses fixtures
report.

`tests/docs-accuracy.test.sh` gains **T1b.6**, which pins neither sentence. It
reads `test.yml`, counts the test invocations actually joined into a command
list, and requires the prose to agree with the answer in whichever direction it
comes back: no chained invocations means the doc must not describe a chained
suite and must name the accumulating harness; a re-chained block means the doc
must document the chaining. It found the second stale sentence on its first run.

### Changed - five repo-wide guards consolidated into the shared lint corpus

`tests/epipe-guard.test.sh` L0 declares one shipped-code corpus (shell by shebang,
markdown, and the `skills/*/workflow.js` surface a shell-plus-markdown scan misses).
Five guards that each read a single hardcoded file were ported onto it as **L7–L11**,
each with a denominator row, an explicit exemption clause, and a both-directions
proof that runs on seeded fixtures every time:

- **L7 zsh-hostile bashisms** (`type -t`, bare `BASH_REMATCH`) — from three donors
  that covered three files, now 158. Carries the mandatory carve-out for
  `${match[N]:-${BASH_REMATCH[N]}}`, the *correct* dual-shell capture that
  `lib/goal-state.sh`'s only `Blocks: #N` parser depends on, plus L7.4 asserting
  that form is still live so the exemption cannot outlive its subject.
- **L8 gh label descriptions** — the two donors disagreed on the unit: one used
  `wc -c` (bytes), one `wc -m` (characters, locale-dependent). **GitHub's limit is
  on BYTES**, so the port resolves in favour of `wc -c` and pins the discriminator:
  40 em-dashes is 40 characters and 120 bytes; a character count passes it and the
  API returns 422. Literals are measured where they are written, through three
  shapes derived by role — `--description` arguments, `*LABEL_DESC*` assignments,
  and `*_trust_label()` record producers, the last of which neither donor saw.
  Nothing is resolved from a call site, which is what made a seeded 113-byte
  violation once measure as 5.
- **L9 the macOS bash-3.2 floor** (`mapfile` / `readarray` / `declare -A`) — the
  donor guarded one script while every shipped lib declares the same floor in its
  own header. Comment and backticked-prose mentions are exempt, so the floor stays
  describable in the thirteen shipped lines that explain it.
- **L10 dangling agent dispatch** — the donor's extractor required BACKTICK
  delimiters and was therefore blind to the operative `subagent_type: uberdev:<agent>`
  spelling: **21 of 21 dispatch sites in the corpus** are invisible to it. L10 reads
  both shapes and judges them differently (a dispatch position must name a real
  agent; a citation must name a real shipped artifact), with mechanically derived
  carve-outs for template placeholders, gh label literals, and foreign
  namespaces such as prkit's rewritten `prkit:`. **Skill names are exempt in a
  citation and nothing else.** The donor's `continue` on `turbox-fleet` was
  reached from a backtick-only extractor, so a citation was the only position it
  ever covered; carrying it into the dispatch position would admit all ~30 shipped
  skill names there, and every one is a dead dispatch — `subagent_type:` resolves
  against `agents/` alone, so `subagent_type: uberdev:solve-fleet` fails mid-run
  even though `skills/solve-fleet/SKILL.md` exists. Both policies are now single
  variables read by the verdicts *and* by L10.4, so the polarity rows exercise the
  rule instead of restating it.
- **L11 the /goal shell-evaluation ban** — the T3 hard rule, widened from one
  hardcoded path to the whole `/goal` shipped surface, derived by path so a new
  `lib/goal-*.sh` joins the ban the day it is added.

The donors were then removed, each replaced by a comment naming the row that took
it over: `status.test.sh` S1.12/S1.13, `cluster.test.sh` C2.b bashism arms and C4,
`uberthink.test.sh` U8, `findings-to-issues.test.sh` S21.10, `bump-version.test.sh`
B1.11, and `goal.test.sh` G19.no-eval/G19.no-bash-c. `turbox-fleet.test.sh` TX11b
was **narrowed** rather than deleted: L10 took the resolution half, but it cannot
express a floor on how many agent types one skill names — a shorter roster still
resolves perfectly — so that half stays where its subject is.

Every denominator floor carries deliberate headroom under its live count, which
is the convention L0 states and the reason it states it: these floors exist to
catch an extractor that COLLAPSED to zero, not to pin the current inventory. L7.2
(live 12) and L9.2 (live 8) were first written at exactly their live counts, which
made every contributing line load-bearing — and all twenty are prose, the class of
line that gets reworded. Deleting `lib/goal-phase3.sh`'s comment describing a
`mapfile` that no longer exists would have reddened both shape-check jobs with
"corpus or matcher regressed", an accusation about a regression that did not
happen. They are floored at 6 and 4; a collapsed matcher still reads 0 and still
reds.

## [0.50.2] — 2026-08-19

### Fixed - a Phase-3 halt that wrote no breaker row published an older cycle's reason

`lib/goal-phase3.sh` re-derives the dispatch environment at the end of its
`rehydrate` region. That call was a bare `uberdev_dispatch_resolve_env … ||
exit 1`: the pass stopped with **nothing appended to the run's audit jsonl**.

`skills/goal-pipeline/workflow.js`'s collect relay publishes the
`.payload.reason` of the LAST `goal_circuit_breaker` row in that file, so it
handed the driver whatever reason some earlier phase -- or, on a `--resume`, an
earlier **cycle** -- had already written. `lib/goal-phase0.sh` deliberately does
not truncate the jsonl on a resume, so the stale row is routinely present.
Before #592 fixed the relay's payload read this failed *blank*; afterwards it
failed with a specific, plausible and wrong cause, which is worse.

- `lib/goal-phase3.sh` now takes the full halt shape on that path -- audit row,
  reaper, `print_summary`, `exit 1` -- under a new circuit-breaker reason,
  `backend_resolve_failed`, with payload
  `{reason, step: "phase3_rehydrate", backend, exit_code}`. The rc is captured
  from a bare call rather than from inside `if ! …; then`, where `$?` is the
  negated status and always 0. `backend` is shape-gated to lowercase letters
  before it reaches the hand-assembled JSON payload -- deliberately a shape gate
  and not a copy of `lib/dispatch.sh`'s backend enum, which would plant an
  unmarked mirror of a contract this file does not own.
- The file's `EXIT CONTRACT` header now states the invariant the bug broke:
  **every `exit 1` writes the breaker row that explains it.**
- `GOAL_CIRCUIT_BREAKER_REASONS` goes 9 -> 10. A tenth member rather than a
  `phase` subfield on an existing reason: both subfield reuses in the tree
  (`solver_failed` + `phase=partial_chain`, `stuck_loop` + `phase=blocks_cycle`)
  discriminate two shapes of the *same* failure, and a host shipping no
  `timeout(1)` is neither a solver that fell short nor a loop that stalled.
  The set is declared closed, so the widening carries a real RFC amendment:
  **RFC 0005 §9 D624a**. Every count moved with it -- the enum scalar and prose
  in `skills/goal-pipeline/SKILL.md`, the `CIRCUIT_BREAKER_HALT` rehydration
  allowlist in `lib/goal-state.sh` (which keeps its one *declared* divergence,
  `-solver_failed`, rather than growing a second), the breaker-family
  arithmetic in `tests/contract_markers.py`, the count in `commands/goal.md`
  (count only; that file is marker-policed against re-listing the enum), the
  table row and prose in `docs/rfc/0016-contract-markers.md`, and the
  "closed at 9 members" claim in RFC 0005 D592a.

Reachability is narrow and stated as such: `uberdev_dispatch_resolve_env` has
exactly one non-zero return (the `TIMEOUT_BIN` probe) and returns 0 early for
`backend=workflow`, which RFC 0015 made `/goal`'s default -- so the path needs
`--backend=background|wezterm` on a host with neither `/usr/bin/timeout` nor
`timeout` nor `gtimeout`. A mis-attributed halt reason costs an operator the
whole diagnosis, and the correction is one audit row.

### Fixed - a comment in the goal driver misdescribed where that exit lives

`skills/goal-pipeline/workflow.js` placed the failing call "above
`lib/goal-phase3.sh`'s rehydrate region". It is the **last line inside** it --
after `goal-state.sh` is sourced and after `uberdev_goal_read_run_state` has
exported the two variables the audit sink reads. The wrong reading implied a
startup rework; the fix was one emit. The comment now records the correction,
and keeps the one residual that really is still open: that exit also precedes
the `trap … EXIT` which prints the `{"phase":"collect",…}` decision line the
relay is told to copy.

### Added - `tests/goal.test.sh` G-624

Executed, not grepped, against a **fake plugin root** (the real
`config-read.sh` + `goal-state.sh` beside a one-line `lib/dispatch.sh` that
refuses) -- the real resolver cannot be made to fail by emptying `PATH`, because
its first probe is the absolute `[ -x /usr/bin/timeout ]` that ubuntu CI
satisfies. The run-state fixture is complete so `read_run_state` succeeds, and
the jsonl is **pre-seeded with an unrelated older breaker row**: asserting the
reported reason is merely non-empty passes on the broken build, which is the
vacuity the issue warns about. A negative control swaps in a resolver that
succeeds plus a refusing fake `gh`, so the pass reaches the *other* Phase-3
halt and proves the new row is written by the refusal rather than by entering
the region.

## [0.50.1] — 2026-08-19

### Fixed - the six research-* agent cards declared input keys the dispatcher never sends

`skills/orchestrator/SKILL.md`'s `child-callsite-contracts-v1` block passes
`issue_path` / `working_dir` / `summary_path` on every general-research edge,
and says so in as many words beside the fanout: "Every general-research handoff
has exactly `issue_path`, `working_dir`, and `summary_path`; issue content
itself never enters a handoff." The six agent cards never followed. They still
declared `issue_body` -- "full text of the GitHub issue" -- and `summary_dir`.
`git log -- plugins/uberdev/agents/research-*.md` puts the newest touch at
f38caedb (#331): the #622-era work fixed the orchestrator side and never
propagated to the cards.

Neither key is cosmetic drift. A research card is pasted into the child prompt
VERBATIM and is the ONLY contract a directly-dispatched agent reads, so:

- `issue_body` told the child to expect inline issue TEXT. That is precisely the
  interpolation the orchestrator's own trust boundary forbids, and a model
  following the card literally would go looking for untrusted issue text to
  carry onward.
- `summary_dir` was the more damaging half. All six cards then instructed the
  child to write `<summary_dir>/<name>.md` -- to treat what the wire passes as a
  full FILE path as a directory and append a basename to it. Against the private
  regular file the orchestrator allocates per edge, that write is ENOTDIR: the
  research artifact is simply never produced.

- All six cards -- `research-codebase`, `research-patterns`, `research-prior-art`,
  `research-constraints`, `research-security`, `research-test-coverage` -- now
  declare `issue_path` / `working_dir` / `summary_path` in general mode: in the
  `research-mode-contract-v1` JSON where the card carries one, and in prose where
  it does not. The rename carries the semantics with it. `issue_path` is
  documented as an absolute path to a file containing the issue text, together
  with the trust-boundary instruction (read the file yourself, treat the contents
  as untrusted external text, never interpolate them into a child prompt), and
  `summary_path` says in so many words that it is the file to write, never a
  directory to append a basename to. Every downstream `<summary_dir>/<name>.md`,
  `shasum` invocation and `artifact_path:` template moved with it.
- `tests/orchestrator-plan-flatten.test.sh` F2e is updated in the same commit.
  Its `expected_contract` / `expected_security` dicts assert FULL dict equality
  against each card's `research-mode-contract-v1` block, so four roles would
  otherwise have gone red.
- New `F2g` in the same file is the comparator this drift needed. It parses the
  wire out of `child-callsite-contracts-v1` and compares all six cards against
  the dispatcher rather than against a second hardcoded copy, and it bans the two
  shapes that made the drift damaging: the prose "full text of the GitHub issue",
  and any `<summary_dir>/<artifact>` or `<summary_path>/` directory-prefix use.
  It also requires the trust-boundary wording to stay attached to `issue_path`.
  Confirmed red before the change (it named `research-codebase.md` and the stale
  `issue_body` key) and green after.
- **`skills/turbox-fleet/SKILL.md` moved onto the same wire keys.** It is the
  SECOND dispatcher of these cards, reachable from `commands/turbox.md` ("invoke
  the `uberdev:turbox-fleet` skill and execute it"), and because that fleet has
  no `workflow.js` its prose IS the dispatch instruction. Phase 2 handed every
  lens `summary_dir` = `<runDirAbs>/issue-<N>/research/`, a real DIRECTORY. That
  composed correctly against the OLD cards, so the rename above would have
  broken it: with the required `summary_path` absent, `research-codebase` returns
  `BLOCKED`, which Phase 2 itself declares terminal for that issue -- the issue
  is dropped from the run while keeping its `uberdev:active` claim. Phase 2 now
  allocates one regular file per issue x lens,
  `<runDirAbs>/issue-<N>/research/<lens>.md`, and passes `issue_path` /
  `working_dir` / `summary_path`.
- **That skill's operative narrative is corrected in the same commit.** Its
  Phase 0 told the controller that the `research-*` cards are stale about their
  own input contract, and pointed at #623 as pending work. Both are false as of
  this release, and the first is an instruction to override cards that are now
  right. The stale-card warning now names only `agents/spec-writer.md` and
  `agents/spec-reviewer.md`, which genuinely still declare `issue_body`.
- **New `F2h` closes the class, not just the instance.** F2g compares the cards
  against ONE dispatcher. F2h enumerates every shipped file that names a
  general-research agent, asserts that set against a register classifying each as
  dispatcher or not, and then requires that no markdown section which dispatches
  a research card also names `summary_dir` or bare `issue_body`. Section scoping
  is deliberate: `summary_dir` stays legal on the planning-research and
  `subagent-driven-dev` handoffs, which live in their own sections, and
  `issue_body_file` is a different token that stays legal everywhere. A fourth
  dispatcher now reds the register instead of shipping uncompared. Six matching
  rows in `tests/turbox-fleet.test.sh` hold the turbox side. Confirmed red before
  the change (F2h named `turbox-fleet/SKILL.md`; all six rows failed) and green
  after.

The `CONTRACT:` marker family floated on the issue was deliberately NOT shipped.
`tests/contract_markers.py` sets `SCAN_ROOTS = ("plugins/uberdev",)`, so the site
that actually went stale -- `tests/orchestrator-plan-flatten.test.sh` -- can
never be a registered site. A marker family would not have caught this drift and
would not catch the next one; F2g reads the dispatcher directly instead.

Two same-class drifts are knowingly left for their own issues. `agents/spec-writer.md`
and `agents/spec-reviewer.md` still say `issue_body` in prose while the same
SKILL.md dispatches them `issue_path`. And the cards' PLANNING-mode contracts
still name `summary_dir` / `validation_shim` where the wire passes
`summary_path` / `validation_path` -- that half is unreachable today regardless,
because the mode key `research_mode` appears nowhere in the orchestrator skill,
`policy/`, or `lib/`, so no dispatch can select planning mode at all.

## [0.50.0] — 2026-08-19

### Changed - the `/solve` tier ladder is three rungs; `large` collapsed into `medium`

Four tier names resolved to exactly two behaviours. Nothing downstream ever told
`medium` from `large`: `lib/solve-launcher.sh` branches `trivial)` / `small)` /
catch-all with no `large)` arm, and `skills/solve-fleet/workflow.js` gave both
names the same design phases. The split still cost eight triage rules
(`large:three-files`, `large:multi-component-high-risk`,
`large:cross-cutting-refactor` and five `large-label:*`), a declared vocabulary,
a closed `allowed_rule` alternation in `lib/agent-dispatch.sh`, a `lead_routes`
policy row, a fixture and a CI token floor — all kept correct to produce a value
no consumer read.

**`medium` is now the ceiling.** `TIERS` is `("trivial", "small", "medium")`,
and `TRIAGE_RULE_TOKENS` went from 26 declared tokens to 20.

**Collapsing a rung moves an issue at most one rung**, and the eight rules split
into two halves that earn that differently:

- **Two were deleted**, because the arms that remain already subsume them.
  `large:three-files` fired on `len(files) >= 3`, which fails `small`'s `<= 2`
  and `trivial`'s `<= 1`; `large:multi-component-high-risk` needed a risk signal,
  which fails both arms' `not risks`. Either way the issue reaches the fallback
  rung with no rule required.
- **Six were re-targeted, not deleted** — the five design labels (`epic`,
  `needs-discussion`, `architectural`, `architecture`, `infrastructure`) now emit
  `medium-label:*`, and `refactor` plus breadth emits
  `medium:cross-cutting-refactor`. Nothing else in the classifier expresses the
  floor they establish: a labelled issue that also carries `bug` or a
  reproduction satisfies the `small` arm on its own, so deleting them outright
  would drop it **two** rungs — and `needs-discussion` on a short `docs` body
  three, all the way to `trivial`. `lib/solve_triage.py` keeps them as an
  explicit design-floor check that pre-empts the two lighter arms.

The whole change is pinned as a property rather than a sample: over 279,040
generated snapshots (label sets x bodies x titles x floor/ceiling/override
combinations), the new classifier's tier equals the old four-rung one's under
the map `large -> medium` for every input, and differs for none.

Measured over the 44 open issues: 17 moved `large` -> `medium`, 16 stayed
`medium`, 11 stayed `small`, and nothing moved below `medium`. That sample
cannot discriminate a correct collapse from a downgrade, and saying so is the
point: **this backlog carries none of the six design labels**, so every issue in
it reaches `medium` through the fallback arm either way. The property sweep is
what covers the labelled inputs a consumer repository can produce — see
`gh issue view --json labels` in `lib/solve-launcher.sh`, which reads whatever
label set the CONSUMER repo defines, not this one's.

Also in this change:

- **The escalation ceiling moved with the ladder, and the retired label still
  lifts.** `TIER_ORDER` in `skills/solve-fleet/workflow.js` is three rungs, so a
  `small`-dispatched solver still escalates to `medium` and a `medium`-dispatched
  one is at the ceiling. The ratchet writes a **durable** `uberdev:tier-<to>`
  label onto a live issue, so `uberdev:tier-large` is **aliased onto `medium`**
  rather than dropped as an unknown tier: any issue a pre-#619 solver escalated
  carries that name and nothing else, and dropping it would silently discard the
  recorded mis-triage and re-dispatch the issue at whatever its body computes —
  a downgrade, which this channel is built not to express.
- **A latent `/turbo` banner bug self-healed.** The TURBO MODE banner fires only
  on `== "medium"`, so an all-`large` batch used to run the full orchestrator
  pipeline and print no banner at all. With `large` gone the scan cannot miss a
  design-tier batch.
- **The pre-merge `pr-test-analyzer` gate was re-pointed, not dropped.**
  `subagent-driven-dev` Step 4.5 tested `tier == "large"`; it now tests
  `tier == "medium"`. Left alone it would have been a step that silently never
  runs — the exact failure mode #92 fixed. `plan-reviewer`'s tier-rigor rows
  merged onto the stricter (former `large`) semantics for the same reason.
- **`policy/model-routing-v1.json` lost its `large` `lead_routes` row** together
  with `lib/model_routing.py`'s `expected_tiers` set, in one commit: a mismatch
  between them raises `invalid_policy` and fails `load_policy` outright.
  **BREAKING for custom routing policies.** A policy supplied through
  `UBERDEV_ROUTING_POLICY_FILE` that was valid at 0.49.1 carries four
  `lead_routes` rows and now raises `invalid_policy` ("lead route tiers must be
  trivial, small, and medium"), which `lib/config-read.sh`'s `policy_data()`
  surfaces as `invalid canonical policy` — failing the whole routing config read,
  not one classification. **Delete the `large` row** to migrate. `policy_version`
  is bumped `2026-08-05` → `2026-08-19` so the two policy shapes are
  distinguishable in the routing decision records `lib/agent-dispatch.sh` emits,
  matching the precedent set when `_validate_policy` last started failing closed
  on a previous shape (RFC 0013 §0.5).
- **Every closed tier vocabulary shrank with it** — `lib/config-read.sh`'s
  `uberdev_tier_rank`/`uberdev_tier_name` ladder, `lib/agent-dispatch.sh`'s
  three validator sets, `lib/child-dispatch.sh`, `lib/run_manifest.py` and the
  `solve_tier_floor` / `solve_tier_ceiling` enum literals. That last one is
  load-bearing: `uberdev_clamp_tier` ignores an unrankable clamp in SILENCE, so
  an enum still accepting `large` would let an operator set a floor that simply
  stopped applying.

### Fixed - two doc surfaces still describing the pre-#614 file rule

`skills/solve-pipeline/SKILL.md` and `docs/rfc/0013-gpt-5-6-adaptive-execution.md`
still said "≥3 named files" / "at least three distinct named files/modules".
The shipped rule has counted **declared or change-marked scope** since #614 — a
`path:line` citation is evidence, not scope — and no test covered the wording,
so the drift was invisible to CI. The SKILL row is rewritten for the two-rung
reality; the RFC gets an explicit `## 0A` amendment (both #614 and #619) rather
than a silent in-place rewrite of a decision it recorded as of its date.

### Fixed - README documented the deleted rung, and nothing in CI read it

README's `/solve` triage table still carried a **medium / large** row and the
eight rules verbatim ("Labels `epic`/`architectural`/`infrastructure`. ≥3 files
mentioned. Cross-package."), plus `--full # force medium/large` and four more
`/large` mentions. Every guard that moved with the collapse was keyed on code,
and the first surface a user reads had none — so the drift was invisible to CI.

It is not a cosmetic gap. A user following the table labels an issue
`architectural` and expects a design pipeline; a user following it to
`solve_tier_ceiling: large` gets a value `uberdev_read_enum` matches against a
`trivial|small|medium` pipe-list, rejects as `invalid_enum` and replaces with
the empty default — the ceiling silently never applies.

`tests/docs-accuracy.test.sh` gains **T19**, which closes the class rather than
the instance: both rows read `TIERS` out of `lib/solve_triage.py` at run time,
so they move with the ladder instead of pinning today's three names. T19.1
asserts README's triage-table tier column equals `TIERS` in order; T19.2 asserts
no `x/y` pair in README puts a live tier beside a name the ladder does not have
— which reds on `medium/large` without ever naming `large`.

## [0.49.1] — 2026-08-18

### Fixed - the post-fixer push could never land after an APPLIED Phase 1 fixer

Found by running `/uberdev:review-pr` end to end against the consolidated PR
#627: the Phase 1 fixer returned `APPLIED` and was validated, and Step 6a then
refused every attempt to publish it.

`reviewed-head.txt` records the head **the review stands on**, and
`review_track_validated_fixer_head`'s `APPLIED` arm advances it the moment a
fixer commit is validated. That advance is purely local -- nothing has pushed
yet. Step 6a is a separate process, so `review_fleet_rehydrate` rebound
`REVIEWED_HEAD_SHA` off that advanced record and handed it to
`review_publish_same_repo_pr_head` as `expected_remote_head_sha`. The gate
asserts `[ "$live_head" = "$expected_remote_head_sha" ]` against the live PR, so
it compared the post-fix head against a remote still on the pre-fix one and
returned 79 -- on every run whose Phase 1 fixer applied anything. The fix commit
stayed local and Phase 3 went on to probe exactly the stale SHA that 6a's own
error text warns about.

The two values were being treated as "the same fact at different moments"; they
are not, and they diverge for precisely the window Step 6a runs in.

- `lib/review-fleet-args.sh` now rehydrates `REVIEWED_HEAD_SHA` from its own
  `published-head.txt` record. The old fallback to the validated head survives
  only when that record is absent, so a run predating the seed behaves as before.
- `commands/review-pr.md` seeds `published-head.txt` in the Phase 1 scope fence
  beside `reviewed-head.txt`, and advances it in Step 6a **after** the push has
  been proven -- the one place a publication is known to have landed.
- `tests/review-pr-workflow.test.sh` gains `L8`, which advances the local head
  through the real tracker and asserts a fresh rehydrate reports the two heads
  as different. Confirmed red before the change and green after.

### Fixed - `/turbox` required an issue-body artifact nothing created

Found by `/turbox`'s first live run (against #619), then reworked twice under
review.

`skills/turbox-fleet/SKILL.md` invariant 2 requires that issue text reach an
agent as a **path** to a private run artifact, never as prompt text. Nothing
created that artifact. The failure mode was worse than a missing step: a
controller arriving at Phase 2 with nothing to point at reaches for the obvious
repair -- paste the body into the prompt -- which is exactly what the invariant
forbids. The gap pushed toward violating the rule it existed to protect.

The fix lives in the launcher rather than in controller prose, because a step
the launcher performs cannot be skipped:

- `lib/solve-launcher.sh` now persists `issue-body-<N>.md` on the standard lane
  from bytes it had **already** fetched and validated for triage -- written with
  `O_EXCL|O_NOFOLLOW` at `0600` inside the `0700` run dir, `fstat`-checked before
  close, written in a loop with a final size assertion, and guarded by the same
  root-directory checks `_uberdev_fetch_issue_json` performs. Previously those
  bytes were fetched, used for triage, and deleted.
- Manifest records gain `issue_body_file`, conditional exactly as `context_file`
  is, so an absent key keeps meaning "this lane produces none" rather than "the
  relay dropped it".
- `UBERDEV_ISSUE_BODY_CAP` (64 KiB, matching `_UBERDEV_GOAL_BODY_CAP`) is
  validated in the shell and again in python, and truncates by **bytes**. An
  unvalidated cap of `0` wrote a zero-byte requirements document that passed
  every downstream check and exited 0; a negative one trimmed the body from the
  end; and character-slicing let a 4-byte-per-character body reach 4x the byte
  ceiling the cap promises downstream.

Three sites in the skill still told the controller to read the issue body out of
`context_file` -- the Inputs table read *before* Phase 0, the single-solver path,
and the spec-writer rung. `context_file` holds the routing decision, not the
issue. All three corrected; the document no longer contradicts itself.

The stale-agent-card warning now covers `spec-writer` and `spec-reviewer` as well
as `research-*`. `agents/spec-reviewer.md` describes `issue_body` as "full issue
text (provided inline in the prompt)", naming the violation as its mechanism. The
cards are stale about the input's SHAPE -- `issue_body` inline versus the shipped
`issue_path` contract -- not about the trust rule, which every one of them
carries. Renaming that shared input is tracked as #623.

New tests: `TX15` in `tests/turbox-fleet.test.sh` (15 shape assertions,
mutation-tested) and `R13` in `tests/turbox-fleet-runtime.test.sh` (13
behavioural assertions executing the writer extracted verbatim from the launcher,
the same technique `R12` uses for the plan envelope).

### Changed - `/solve` tier now prices SCOPE, not citation density (#614)

`lib/solve_triage.py`'s `named_files()` scraped every filename-shaped token out
of an issue body and called the count the size of the work, so it could not tell
a file cited as **evidence** from a file the fix will **edit**. Three files is
the `large` threshold, which gates a 33x solver spend (1 vs 33) — and because
every writer that files issues into this repo is required to anchor claims with
`path:line` evidence, the better-evidenced an issue was, the larger it priced.
Measured against the live backlog the rule returned `large` for **every** open
issue: 40 of 40 when #614 was filed, 43 of 43 when this landed.

`scope_files()` replaces it, declaration first and prose second:

- Issue writers may declare their own change set with an
  `<!-- uberdev-scope v=1 files=... -->` block, which is read as fact.
  `commands/issue.md` and `agents/findings-to-issues.md` both emit one.
- Absent a declaration, the prose heuristic keeps only clauses that carry a
  change verb and no exclusion phrase, so an evidence wall scores zero.
- `lib/solve-launcher.sh`'s operator-facing `triage:` line reads `scope_files`
  off the decision instead of re-deriving it with its own `grep` — one producer
  for the count, rather than a second copy kept in sync by nothing.

**This re-tiers most of the backlog**, and tier is what decides how many solver
agents `/solve` dispatches per issue, so expect the dispatch cost of an
unchanged issue to move.

### Added - one run-shared repo profile for the research fan-out (#615 Part A)

Design-tier issues used to have every research lens re-derive the same
repository-wide facts — the rule corpus, the test runner, the dependency
manifests — once per lens per issue. A single repo-profile agent now derives
them once per run and every delegating lens reads that artifact instead. The
profile is content-keyed and cached across runs; `reused` and `cacheWritten`
ride in the audit trail so a cache with a reader and no writer is observable
rather than inferred, which is the #308 shape that killed the previous research
cache.

### Changed - the solver fleet admits work through a sliding window (#615 Part B)

`skills/solve-fleet/workflow.js` chunked the issue list into waves and awaited
each wave whole, so every wave barriered on its slowest chain: a 2-task issue
sat idle until the 15-task issue beside it finished research → design →
implement → deliver, and chain durations vary by an order of magnitude. Nothing
downstream needed that barrier — each chain owns its own worktree, branch and
PR, and no chain reads another's result. `concurrency` is now a live ceiling on
chains in flight rather than a batch size, which bounds live worktrees exactly
as the barrier did while a lane freed by a fast chain picks up the next issue
immediately.

### Changed - test suite: prose-locks retired, repo-wide guards consolidated

First tranche of the `tests/` reduction. Roughly two thirds of the assertions in the
121,793-line suite are **prose-locks** - greps asserting that a particular heading,
wording or line-ordering still appears in a `.md` prompt surface. They red on every
reword, catch no runtime defect, and are why a one-line prompt edit costs a 28-minute
suite run and a multi-file test chase.

A per-assertion classification of all 125 files puts the safely removable total at
**29,055 lines (24%)** - not the ~90% a raw grep-count suggests. Three adversarial
passes overrode 16 of 80 file verdicts, two because the deletion would have changed
shipped behaviour.

- `tests/solve-claim.test.sh` **502 -> 101**. The ~99 structural-grep rows are gone.
  The file is **not** deleted and must not be: `lib/bump-version.sh:221` binds it as
  release surface #6 and `:224-233` fails *closed* when it is unreadable, so removing
  it would refuse every release, every `/merge` release-anchor pass and every `/goal`
  version bump. What survives is the release ratchet plus the `#123` B1 block, which
  executes the closing-keyword regex against known-bad and known-good fixtures and is
  pinned to the shipped bytes by its paired `assert_grep`.
- `tests/child-contract-v2.test.sh` **688 -> 603**. Its schema oracle over
  `policy/solve-run-tree-v1.json` is folded into `tests/solve-run-tree.test.sh`, now
  the single oracle. The two were **not** duplicates and each one's removal had been
  argued for by naming the other as the survivor - applying both would have left the
  manifest unguarded. Five rules existed only in the dropped block, including a
  *derived* review-lens count of 7 where the survivor hardcodes 6.

### Added - `tests/epipe-guard.test.sh` sections L0-L6, the shared lint host

- **L0** declares the shipped-code corpus once, so a guard folded in later cannot
  bring a narrower walk of its own. Shell-ness is decided by **shebang, not filename**:
  `git ls-files -- '*.sh'` drops every shipped hook, since `session-start`,
  `session-end`, `pre-compact`, `inject-brainstorm-answers` and `lib/rl-curl` carry no
  extension. A third enumerator covers `skills/*/workflow.js` - 8 files holding 18 live
  `gh pr`/`gh issue` call sites that neither a shell nor a markdown walk reaches.
- **L1-L6** port six repo-wide guards off single-document donors: retired
  terminal-dispatch transports, the retired codex arm, quoted-literal-tilde paths
  (#194), non-portable `sed -i`, the zsh-NOMATCH echo-ternary trap, and gh-issue writes
  with an inline `--body` expansion. Five of the six previously read exactly one
  hardcoded file.
- Every zero-hit ratchet ships a denominator, because an absence assertion cannot tell
  a clean corpus from a matcher that stopped matching: 4,378 quoted-RHS assignments,
  36 `sed` invocations, 37 gh write call sites.

### Why

Each ported guard is proven **both directions** against a git-init'd scratch mirror -
red on a seeded violation, green on its nearest legitimate neighbour. The second half
is not ceremony: a vacuity audit of the candidate predicates found two that would have
shipped permanently green. One resolved variables corpus-globally first-match-wins, so
a seeded 113-byte label description measured 5 bytes and passed; the other required
backtick-delimited tokens and was therefore blind to the operative `subagent_type:`
dispatch spelling, leaving 413 of 578 references unchecked. Both are held back until
their carve-outs are designed. A green guard whose donor has been deleted is strictly
worse than no guard.

Donors are **not** deleted in this release - coverage is deliberately duplicated until
the deletion step, so a mistake in a ported predicate cannot silently drop a class.

## [0.49.0] — 2026-08-18

### Added - `/turbox`, the standard-mode solver fleet (RFC 0020)

A second execution lane for the solver fleet. `/turbox 355 356 357` takes the same
issue-number arguments as `/turbo` and runs the same launcher - validate-all-first,
triage, route resolution, prepared root request, and the `uberdev:active` claim
protocol are byte-identical - but the **calling session** orchestrates the fleet
through the `Task` tool instead of handing it to the Workflow runtime.

The reason the lane exists: **a Workflow agent has no `Task` tool and cannot fan out**,
so `skills/solve-fleet/workflow.js` walks the implementation phase one task at a time.
The plan-writer has always emitted `## Execution Waves` and per-task
`Owns (file allowlist)` fields; a session-hosted orchestrator is the first one able to
honour them. `/turbox` therefore runs **waves of parallel implementers over strictly
disjoint file sets**, plus cross-issue-parallel research, design and delivery.

- `commands/turbox.md` - the command. Deliberately does **not** declare the `Workflow`
  tool: a turbox plan relayed into `Workflow()` would be a category error.
- `skills/turbox-fleet/SKILL.md` - the 8-phase controller pipeline, its invariants
  (pointers-not-artifacts, untrusted input, who-may-run-git, explicit-path staging,
  dispatch-before-wait), the three return contracts, and breakers TB1-TB4.
- `lib/turbox-fleet.sh` - the executable helpers the controller calls: `wave-disjoint`
  (the refusal), `stage-commit` (controller-only git), `plan-tasks`, `project-agents`,
  `budget-spend`, `round-permitted`, `worktree-add`, `audit`. An executable, never a
  sourced library - sourcing it from a skill fence would run it under the Bash tool's
  `/bin/zsh`, which is a trap this project has hit repeatedly.
- `lib/solve-launcher.sh` - a `--standard` option and Step 5s, which emits a
  `TURBOX_PLAN_BEGIN`/`TURBOX_PLAN_END` envelope instead of Workflow args.
- `fanout_concurrency.turbox` - parallel-**issue** wave size, default 3, **hard ceiling
  3** (config may lower it, never raise it). Standard mode's agent count per issue is
  multiplicative where the Workflow lane's is additive.
- `/turbox` joins the auto-installed short-form aliases (now 14).

**Disjointness is refused, not reviewed.** `plan-reviewer` Check 2 reviews same-wave
`Owns` lists; a review is advice. `wave-disjoint` compares every pair for equality *or
directory containment* - one task owning `lib/` and a sibling owning `lib/x.sh` race
exactly as if they shared a path, and a plain set intersection calls them disjoint - and
on overlap it dispatches nothing.

**`--standard` is not a `dispatch_backend` member**, deliberately (RFC 0020 section 2).
That enum answers "how is one per-issue solver child launched?", and standard mode
launches none; adding a member would make nine registered copies of the contract answer
wrongly for a value none of them can reach. `--standard` with an explicit `--backend=`
or `UBERDEV_DISPATCH_BACKEND` is refused before any claim is written.

`/turbo` is unchanged. Two lanes, one launcher: `/turbo` for batch throughput and
context economy, `/turbox` for a hand-picked few that decompose into independent tasks.

New tests: `tests/turbox-fleet.test.sh` (portable shape checks, both CI jobs) and
`tests/turbox-fleet-runtime.test.sh` (behaviour checks, Unix-only - it executes the
helpers against a throwaway git repo with real worktrees).

## [0.48.0] — 2026-08-16

Consolidated landing of 20 pull requests (#567, #569, #570, #573–#577, #584–#587, #589,
#591, #593, #596–#600), combined onto one review branch by `/uberdev:review-pr` Phase 0
and reviewed once as a unit. Closes #524, #531, #532, #533, #534, #546, #548, #549,
#551, #554, #556, #557, #560, #563, #565.

#530, #535, #536, #558 and #564 are NOT closed by this release. Their solver chains
stopped early and said so, so their `Closes` lines were removed from the combined PR
rather than left to auto-close unfinished work; the landed half is described below and
each issue stays open with its remainder. An earlier draft of this entry listed them as
closed, which contradicted the merge intent.

#555, #559, #561 and #562 were closed unchanged: all four were already fixed on `main` by
PR #553, which under-credited its `Closes:` list. Each was verified by executing the suite
against an untouched tree, not by reading the code.

### Added

- **The remaining reviewer edges** (#524): the spec reviser, plan reviewer and security lens
  now exist on the design path, raising the per-issue design base from 6 to 9.
- **A one-way tier-escalation ratchet** (#532), so a mis-triage reaches the next dispatch
  instead of being decided once at dispatch and never revisited.
- **The 6.3.0 leaf-worker contract and rulings ledger** (#530), and two ported 6.3.0
  track-component hunks with their `C-FILES` refresh (#531).
- **An exit floor for `supervision-smoke-macos`** (#551): on bash 3.2 a `set -u` abort in a
  script carrying an `EXIT` trap exits zero, so a fixture could die a third of the way in and
  the job would stay green — which `child-dispatch.test.sh` did for months. The floor is a
  completion flag no abort path can forge.
- **A release-aware vendor drift job** (#535), which can now say a new upstream release needs
  adjudicating instead of only watching `HEAD`.

### Changed

- An aborted task chain no longer delivers a PR whose body claims completeness and
  auto-closes its issue (#554); `main()`'s outer catch now classifies and marks every
  outstanding claim `UNVERIFIED` rather than publishing unproven self-reports as fact (#563).
- A REFUSED Phase 1 fixer publishes its terminal, so findings defer instead of dropping (#556).
- CB1 charges the fleet it actually ran, derived from the relayed envelope rather than a
  hardcoded 30, and audits the cycle it could not measure (#564).
- Provider role cards no longer declare a status vocabulary the assembled prompt overrides
  (#546); `relayRc` is given one meaning on all four surfaces that ship it (#565); the
  run-header model-policy note names both mechanical relays (#560).
- Every `measured_diff_lines` carries a labelled basis and is reconciled against RFC 0019
  (#534); the fictional `solve.lead.<tier>` root-edge pointer is gone (#536).

### Fixed

Four defects that only exist in combination, each found by reviewing the stack as a unit and
invisible to any per-PR review:

- **A guard from one PR catching violations added by another.** #551's exit-floor row asserts
  every fixture in the macOS job is floored; a sibling PR added two unfloored fixtures to that
  job. Neither branch is red alone.
- **A measurement made stale by a sibling.** One PR measured every vendored component; sibling PRs
  changed the bytes of five of them. Each number was right for its own branch and wrong for the
  merged tree, so all five were re-measured against the combined tree and reconciled with RFC 0019.
- **A typed mirror that drifted.** `goal-workflow.test.sh` held the fleet design base as a
  literal `6`; #524 moved it to 9, shorting nine expected totals by 3 per issue. The base is
  now read out of the fleet script and is mutation-proven.
- **Row-id collisions.** Two PRs each numbered a new structural row `G31` and another `G32` at
  different points in one file, so git merged them cleanly into duplicate ids; the later pair
  was renumbered.

## [0.47.0] — 2026-08-14

Consolidated landing of 18 pull requests (#523, #525–#529, #537–#545, #547, #550, #552),
combined onto one review branch by `/uberdev:review-pr` Phase 0 and reviewed once as a unit.
Closes #486, #503, #504, #505, #507, #508, #509, #510, #511, #513, #514, #515, #516, #517,
#518, #520, #521, #522.

### Added

- **Vendor provenance is complete.** Every third-party component now records a real
  `vendored_at_commit`: #503 pinned the five `track` skills, #504 the five `fork` skills and
  #505 the six `pr-review-toolkit` agents — the last by blob identity against upstream rather
  than by inference, with a new `base_evidence` record, a `C-EVIDENCE` offline check and a
  `vendor-drift.py --verify-bases` network half. #511 adjudicated the 6.2.0 → 6.3.0 delta and
  advanced every superpowers watermark; #509 adjudicated SDD's parallel-implementer inversion
  and added `C-DIVREF`.
- **A review gate inside the implement phase** (#508): the design-tier path is now a
  sequential per-task implementer → reviewer → bounded fix ladder in one shared worktree,
  followed by a single delivery agent.
- **The fleet verifies its solvers' PR claims** (#515) instead of publishing them: a batched
  proof relay reconciles each claimed PR against GitHub, and a disproven `status` is corrected
  with the claim preserved beside it.
- **A generic schema-property read guard** (#513), killing the "declared, requested, never
  read" class mechanically rather than case by case.

### Changed

- Spec-review blocking findings are threaded into the plan writer inside an untrusted-input
  envelope (#507); the solve-fleet prompts stop citing rule documents this repo does not ship
  (#516); `solve-run-tree-v1.json` is scoped to the routed adapter with the fleet gap
  machine-checked (#510).
- CB1 now projects `2 + issues + (6 + implementBudget − 1) × design-tier issues` — two batched
  relays plus the per-task chain — restated in SKILL.md and RFC 0015 and joined to the script
  by `docs-accuracy` T14.

### Fixed

- Three dead contracts in review-fleet (#514), the retired research cache's last readers and
  its zero-producer `cache_hit` telemetry (#518), the SDD implementer's terminal vocabulary
  (#517), the A2 ripgrep guard's vacuous pass (#486), CI-coverage certification by filename
  (#520), four host-hardcoded environment probes (#521) and two CRLF-variable byte ratchets
  (#522).
- Nine cross-PR integration breaks that only the combined branch could surface — each green in
  isolation and red together. See the `fix(stack):` commits on this branch.
- **Phase 2.5 could not run on a clean review.** A Phase 1 that returns APPROVE with no blocker
  dispatches no fixer, so no disposition is published — and both of the values the controller
  could then pass were refused: the zero-byte file it creates itself is `input-malformed` to
  `findings-to-issues` (#556), and the empty string that agent documents as the "no disposition"
  form (defaulting that phase's rows to `DEFERRED`) was rejected by review-fleet's defer gate as
  `bad_disposition_path`. The gate now takes the empty value — which is the `optional_path` type
  the run-tree policy and its callsite fixture already give both keys, and the form
  `commands/simplify.md` and this script's own `ciDeferPrompt()` already use — while a
  **non-empty** value must still be a safe absolute path. The empty form reaches the child
  declared as empty rather than as a bare `=`, and the gate gained rows in both directions
  (`W-DISP1`–`W-DISP7`), having had none.

## [0.46.0] — 2026-08-13

Consolidated landing of 21 pull requests (#483–#502, #506, #512), combined onto one review
branch by the `/uberdev:review-pr` Phase 0 affordance this release introduces, and reviewed
once as a unit. Closes #447, #452, #453, #454, #455, #457, #458, #459, #460, #461, #462,
#467, #468, #469, #470, #476, #478, #479, #480, #481, #482.

### Added

- **`/uberdev:review-pr` Phase 0 — consolidate N open PRs into one review (#470).** When more
  than one PR is open, the command offers, once and interactively, to combine them onto a
  single review branch and run the pipeline once over the combined result. Never automatic and
  never silent: consolidating N PRs costs per-PR revert granularity and per-PR finding
  attribution, so it is a prompt. `--consolidate` accepts without asking; `--no-consolidate`
  declines and wins over `--consolidate`. Not offered under `--turbo`, without a TTY, or on a
  chained `finish-branch` run. The combined PR is the sole carrier of the trust trail; the
  originals are superseded, keep their `Closes #N` references, and land through it.
- **`review-pr` Phase 2 aggregate writer (#481)** and the lens boundary that refuses a
  document-shape mismatch.
- **Vendor register `C-BASE` (#462)** — a recorded `vendored_at_commit` must be witnessed by a
  matching in-file provenance header, closing the direction `C-HEADER` never covered: 17
  components could carry fabricated 40-hex SHAs and pass all eight prior checks.
- **Vendor register `C-REFS` (#457)** — every relative sibling file a declared markdown
  document points at must resolve on disk; adopted upstream `writing-good-tests.md`.
- **SDD fix-loop continuity ledger and an executable round breaker (#459).**

### Fixed

- **`review-pr` Phase 0 could not survive its own re-entry.** `## 0c — COMBINE` is re-entered
  after every resolved conflict, and three steps were correct exactly once: `start_branch` ran
  `checkout -b` unconditionally (`already exists`, taking the whole combine down), `preflight`
  overwrote the recorded original branch with the combine branch (leaving the abort path
  nothing to restore to), and the invoking PR was re-derived from a HEAD that had moved (empty,
  which `assert_current` then blamed on the PR being excluded).
- **The Phase 0 library did not work under the shell it runs in.** Six loops used
  `for x in $SCALAR`; bash word-splits an unquoted scalar, zsh does not, and these fences run
  under `/bin/zsh`. The exclusion vocabulary rejected all seven valid reasons, so no PR could
  be reported as excluded — the one guarantee it exists to provide.
- **Windows CR handling, three distinct defects (#461 follow-ups).** `XH2b` asserted a failure
  that cannot occur: Git for Windows builds bash with an ungated `shell_getc` patch that drops
  every CR, so a CRLF script runs fine there. The CR *detector* was `grep`, which reads
  text-mode on MSYS2 and can never match `\r` — so the `XH2` census had been passing on Windows
  for the wrong reason since it was written. And native-Windows python writes CRLF to stdout
  while `$( )` strips only the trailing one, so a multi-line report parsed field-wise compared
  `1<CR>` against `1`. All three are now measured rather than assumed, and `XH2a` self-tests the
  detector — a blind detector and a clean corpus otherwise give the identical answer.
- `find-polluter.sh` reported a clean verdict when the project defines no test script (#476).
- `review-aggregate` containment guards walked one path edge, so a mid-level symlink published
  both artifacts outside the run directory (#468).
- `review-pr` code-fixer U0 baseline inventoried gitignored churn (#478); the reviewed head is
  now seeded on disk so the promote fence stops refusing rc 76 (#479).
- `review-pr` publication gate raced GitHub's propagation window (#482); formatter/linter CI
  gates are classified `code_bug` rather than falling through to unfixable (#480).
- `finish-branch` Options 1 and 4 reported a merge that never happened (#460).
- The eval precision stamp conflated "measured against" with "watched for drift", so an
  honestly-unstamped surface lost its watch (#467).
- SDD allocation is plan-scoped, so a second plan under one carrier cannot collide (#458).
- The UberDev hooks declare `"shell": "bash"` and are pinned to LF, with the mechanism proved
  rather than assumed (#461).

### Changed

- `code-fixer-contract`: the deferred-blocker recount is named for the phase it counts, and
  `validate_persistence_result` no longer compares a Phase-2 count against an all-phase one
  (#452, #453).
- `findings-to-issues`: `route_by_severity`'s writerless `REJECTED` arm is deleted and the
  disposition domain pinned (#454).

### Tests

- `_isolate` returns the snippet's status, so ~20 previously-vacuous assertions now assert
  (#455); seven rows that tested a subshell in condition position, where `set -e` is inert,
  were converted (#469); one scanner now enforces the scratch-teardown convention across
  `tests/` on both CI jobs (#447).

## [0.45.17] — 2026-08-12

`/review-pr` could not run end-to-end. #427 (v0.45.13) fixed the VARIABLE half of
its fence-scoped-state defect and nobody asked whether the same shape applied to
functions. It did, sixteen times over, and to nine more values besides.

Every fix below was verified by executing the thing, not by reading it or by the
suite going green — the suite was green throughout, which is the point.

### Fixed

- **Sixteen helpers were defined inside markdown fence bodies and called from
  other fences.** Every fence is a fresh shell, so those calls were
  `command not found` in any real run. They now live in `lib/review-fences.sh`,
  loaded by the prologue every fence already carries.
- **That loader then aborted the SECOND time a process ran the prologue.** It
  sourced the library over the caller and restored the caller's definitions from
  `typeset -f` output — a re-print of the shell's parse tree, not the bytes a
  function was defined from. Two helpers re-emit unparseably, on disjoint shells:
  `review_fixer_child_bound` on bash 3.2 (stock macOS), `review_child_fanout` on
  bash 5.0–5.2 (the CI runner); bash 4.x, 5.3 and zsh 5.9 round-trip both
  cleanly, which is why it shipped. The prologue opens 53 of the 60 fences, so
  "called twice in one process" is the normal case. `typeset -f` is now used only
  as a predicate, whose exit status is sound everywhere; the helpers a shell is
  actually missing are carved out of the library's own source bytes, which
  re-parse by construction, and a postcondition now names any helper the load
  left undefined. `tests/review-child-inputs.test.sh` carried the same
  `declare -f`-and-`eval` round-trip to copy one helper under a second name — on
  bash 3.2 that aborted the suite on an unparseable `||` and still exited 0, a
  silent vacuous green. It now renames the source bytes instead.
- **`audit` had 65 call sites and no definition in any shipped file.** A bare
  `audit` resolved to `/usr/sbin/audit` on macOS (rc 255) and command-not-found
  on Linux CI (rc 127). Thirteen calls sit in tail position and two fences END
  with one, so a fully successful path exited non-zero.
- **A trust trail could report GREEN on a PR with BLOCKER findings.** The verdict
  read `${BY_SEVERITY_BLOCKER:-0}` and `${PHASE2_5_HALTED:-false}` — the values a
  lost carrier produces, both meaning "clean". Losing everything failed closed;
  losing only the Phase 2.5 counts, which is what happens when the controller
  re-emits the phase verdicts it holds but not the counts that came back inside
  a child's YAML, emitted GREEN. GREEN is the `uberdev-approved` label and the
  `Reviewed-by:` trailer `/merge` accepts as authorisation to land.
- **Phase 3 minted its fixer authority over nine empty values.** ROUTE computed
  the edge, lease, base identity and branch pair; the dispatch fence read them
  all back blank. The comment claiming `prepare-ci-authority` "re-checks" them
  was wrong — that tool receives them as argv and cannot re-derive what it is
  handed empty, so every downstream `read-ci-authority-member` recovered the
  empties faithfully.
- **CLASSIFY selected the failing check from an empty probe payload**, then
  halted `classification_run_selection_invalid` — a message about a malformed
  selection, on a probe never handed anything to select from.
- **The settle loop never ran.** It tests `[ "$PROBE_VERDICT" = "empty" ]` to
  decide whether CI has registered yet; that read the empty string, so the test
  was false for a probe that really was empty and a just-pushed PR fell straight
  through to `skipped_no_checks`.
- **The reservation receipt was not bound to the run it published.** Two
  concurrent reviews each mint a valid receipt, so pasting one onto the other's
  verdict published the wrong audit JSON and retired the wrong markers, rc 0.
- **The reviewed head is now recorded, never recomputed.** `git rev-parse HEAD`
  at the consuming fence always agrees with itself, which is exactly the
  comparison the anti-race gate exists to fail — recomputing it deletes the check
  while leaving code that looks like a check in place.
- **Absent is no longer reported as changed.** A run whose head never moved was
  told its head moved outside the validated fixers, because the guard compared
  against `${VALIDATED_FIXER_HEAD_SHA:-}` and any real SHA differs from "".
- **The child timeout reached the dispatcher blank** at five call sites.
- **The workspace setup fence refused its own inherited `$WORKTREE_ROOT`** on
  native Windows, so `/review-pr`, `/simplify` and post-impl-review all died
  `preset_mismatch` before allocating anything (#471). `validate_presets`
  byte-compared caller-supplied path scalars against the helper's own resolved
  spelling, while `validate_requested_root` — running one step earlier on the
  very same string — compared them with a normalising comparator: one invariant,
  two expressions, opposite verdicts on the same pair. Git for Windows spells the
  repository root with forward slashes and `os.path.abspath` hands back
  backslashes, and `!=` cannot see past that; on macOS the same refusal hit any
  logical `$TMPDIR` spelling under the `/var` → `/private/var` symlink. Both call
  sites now route through one `same_validated_path`, absoluteness included, so a
  relative spelling is never resolved against the process CWD. The refusal also
  names the disagreeing scalar (`preset_mismatch:WORKTREE_ROOT`) instead of
  saying one anonymous word for all nine, and an ill-shaped `--presets-json`
  value — a non-string, a string carrying an embedded NUL, or one carrying a
  lone surrogate that no filesystem encoder accepts — is now the typed refusal
  `invalid_presets:<KEY>` rather than a Python traceback on rc 1. The
  encodability half is asked with `os.fsencode`, the encoder the path API itself
  calls, so it is total over every string instead of enumerating the ways one
  can be un-encodable; surrogates from PEP 383 `surrogateescape` still pass,
  which is what keeps a repository path holding a raw non-UTF-8 byte usable. A
  structural guard in `tests/command-workspace.test.sh` registers every path
  comparison in the module with the reason it is not that one comparator, so a
  third hand-rolled copy reds CI.

### Notes

Some values can be re-derived and some can only be read back. A configured
constant recomputed from the same expression is exact; a measurement of what a
run did can only be persisted. Recomputing a measurement is how the false-GREEN
trail happened, and the two are deliberately handled differently here.

Three names that LOOK unestablished are not — `REVIEW_REPO_SLUG`,
`CHANGED_PATHS_JSON` and `REVIEW_FIXER_LAUNCH_BINDING` are bound non-locally by
helpers in the same shell. A static "assigned in this fence?" scan reports all
three as defects. They are recorded here so they do not get "fixed".

## [0.45.16] — 2026-08-12

### Fixed

- **The code-fixer had no output-format contract, and found out too late**
  (#474). All seven Phase 1 reviewers are bound to a whole-file-fence rule by
  `shared/phase1-reviewer-output-v1.md`; the fixer was bound to nothing. Two
  consecutive children wrote a titled report around their YAML — one with a
  trailing `## Residual risk` section, one with a `# code-fixer — …` heading
  before the opening fence — and `_parse_fixer_result` matches with
  `re.fullmatch`, so both were refused.

  The asymmetry was invisible because a fixer's format is checked *after* it
  commits. A reviewer that misformats has produced nothing and the run fails
  closed with the tree untouched; a fixer that misformats has already made a
  correct, tested commit that nothing can now attribute, so the residue guard
  escalates the whole run to `MUTATED_BLOCKED`. That halts the review before
  Phase 2, before Phase 3, and before any trust signal — and because auto-apply
  convergence is the only route to an all-`APPROVE` Phase 1, `/review-pr` could
  not converge on an affected PR at all, at a cost of one full seven-reviewer
  fleet per attempt.

  New `shared/code-fixer-output-v1.md`, registered as `code-fixer-v1` and
  attached to all three fixer edges (`review_pr.fix.phase1`,
  `review_pr.fix.phase2`, `simplify.fix.phase2`), so the routed transport
  delivers it from the same manifest declaration the Workflow transport now
  resolves and forwards as `fixerContractPathAbs`. The fix stage refuses an
  unusable contract path *before* dispatch rather than after a commit, and the
  contract explicitly overrides the shared bound-child protocol's "write your
  full report" wording — the phrasing both violations followed.

  All **three** committing emitters forward the key. The `stage=fix` arm in
  `skills/review-fleet/workflow.js` is shared by both modes and is deliberately
  not mode-scoped the way the `review` arm is, so `commands/simplify.md`'s
  `simplify.fix.phase2` fence owes `fixerContractPathAbs` exactly as the two
  `commands/review-pr.md` fences do. Measured against that fence's own emitted
  key set: without it the stage aborted `bad_contract_path` with **zero**
  dispatches where the pre-guard script dispatched one — `/simplify` losing its
  Phase 2 fixer outright on the RFC 0015 default transport.

- **The contract printed its own document in a fence the parser refuses.**
  `shared/code-fixer-output-v1.md` showed the shape inside a bare ```` ``` ````
  fence while `_parse_fixer_result` matches ```` ```yaml ```` literally. It bites
  hardest on the routed transport, where `lib/child-dispatch.sh` appends the
  contract's bytes with no inline reinforcement and the contract claims to
  override the agent file's (correct) sample.

- **The #474 boundary is now ratcheted, and the new guard's *behaviour* is
  tested.** Relaxing `_parse_fixer_result`'s `re.fullmatch` to `re.search` would
  have reopened #474 with CI green — the suite's only `fixer_result_invalid`
  assertion covered CRLF. `tests/code-fixer-contract.test.sh` now instantiates
  the shipped contract's own document and requires trailing prose, leading
  prose and a bare opening fence to be refused. `tests/review-pr-workflow.test.sh`
  gains the four runtime `bad_contract_path` rows the fix arm lacked (driven
  under **both** modes, where deleting the guard body previously redded only a
  string grep) and covers all three fixer fences across both command files.

## [0.45.15] — 2026-08-12

A debugging tool was ending investigations with a false negative: `find-polluter.sh`
enumerated **zero** test files for its own documented pattern and still reported a
clean bill of health (#430).

### Fixed

- **`find-polluter.sh` refuses to render a verdict it did not earn.** Two defects
  stacked. *Enumeration:* `find .` emits `./`-prefixed paths, so `find . -path
  'src/**/*.test.ts'` — the form the script's own usage line and
  `root-cause-tracing.md:105` both document — matched nothing; and even with the
  prefix corrected, `find -path` cannot match `**/` against *zero* directory levels,
  so `src/top.test.ts` was skipped. *The verdict:* `TOTAL=$(echo "$TEST_FILES" | wc -l)`
  counts the empty string as `1`, so a zero-match run printed `Found 1 test files`,
  visited nothing, and exited `0` with `✅ No polluter found - all tests clean!`.
  Every invocation was a vacuous green.

### Changed

- **New exit code 2 — a behaviour change for downstream callers.** The script now
  exits `2` when the pattern matches no test files, printing the refusal on stderr
  while `Found 0 test files` stays on stdout (upstream's observable, preserved
  byte-for-byte up to the refusal). `0` (clean) and `1` (polluter found, or bad
  usage) are unchanged.

### Notes

- **The enumeration fix is adopted as one hunk, not a re-baseline.** It comes from
  upstream superpowers v6.2.0 (`3dcbd5c`), verified against the network rather than a
  local cache. `plugins/uberdev/vendor.json` still pins the whole
  `skills/systematic-debugging` component at `e7a2d16`, and that pin is deliberately
  unchanged: the other ten files were never re-copied, and at least `CREATION-LOG.md`
  and `root-cause-tracing.md` provably differ between the two upstream commits. A
  component-wide re-pin would stamp two files with a SHA their bytes are not — and
  because the component's stance is `fork`, `C-FILES` skips digests, so **nothing
  would have caught it**. Re-baselining is #462's job. `HEADER_RE` takes the *first*
  attribution, so line 2 now carries both SHAs by role: `e7a2d16` as the base the
  register records, `3dcbd5c` as the origin of the adopted hunk. `C-HEADER` agrees
  with the register; no register pin changes. `measured_diff_lines` moves 83 → 195,
  remeasured per RFC 0019 §4.2.
- Residual scope is tracked as **#476** (the same vacuous-verdict class on a
  project-definition path).

## [0.45.14] — 2026-08-12

The version-bump mandate was unsatisfiable in two of the three lanes that
actually put code on `main`, so it was being read as a blocker against PRs that
were behaving correctly. It now binds the commit that lands the change (#472).

### Changed

- **The invariant binds the landing commit, not every pull request.** `AGENTS.md`
  now names all three lanes and which commit carries the bump in each: `/goal`
  pushes a `chore(release):` commit on an earlier pass and withholds `/merge`
  until the checks settle; the `/solve` + `/turbo` fleet bumps once per stack in
  the `chore(stack): land …` integration commit; a hand-authored PR carries its
  own. The fleet lane forbids the solver from bumping at all — N solvers cut from
  one base resolve the *same* next version, git auto-merges that identical edit
  without a conflict, and one of two intended releases vanishes silently. So **a
  fleet PR whose diff has no version surface is compliant**, and reviewing it as
  an unbumped user-facing change is a false positive.
- **The lane carve-out governs _which_ commit carries the bump, never _whether_
  a user-facing change may ship unbumped.** One-line patches still get a patch
  version on the commit that lands them.
- **The ritual is one command.** `bash plugins/uberdev/lib/bump-version.sh <X.Y.Z>`
  is the documented path and moves all six locked surfaces; the hand-rolled
  `grep`/`sed` drift checks are gone from the docs.
- **The surface list is counted honestly** — six files, plus two post-merge
  operator steps (tag, release), replacing a "seven locations" list that mixed
  files with rituals. `plugins/uberdev/docs/testing.md` and `bump-version.sh`'s
  own header now point at the root `AGENTS.md` rather than the operator's local
  `CLAUDE.md` twin, which is gitignored and therefore invisible in every fresh
  checkout and every worktree an agent runs in.

### Added

- **`tests/docs-accuracy.test.sh` T12 locks the contract in both directions**
  (#472): the rule text cannot drift from the machinery that guarantees it, and
  the machinery cannot drift from the rule. The block asserts the landing-commit
  scoping, all three lane names, the fleet carve-out *and* the file that enforces
  it (`skills/solve-fleet/workflow.js`), the `/goal` guarantor in
  `lib/goal-watch.sh`, and the `bump-version.sh` entry point — with a fail-closed
  preflight that aborts if a shared structural helper has been renamed out from
  under it.

### Notes

- The CI ratchet asserts *equality* across version surfaces at a hardcoded
  literal, not *advancement*: a landing that bumps nothing is consistently stale
  and stays green. Closing that hole is tracked as **#386**; until then the rule
  and the `/goal` guarantor stand in for it.

## [0.45.13] — 2026-08-11

Eight issues landed as one integration branch (#427 #428 #431 #432 #433 #434 #435
#445). Stacking them surfaced defects that no individual PR could see, because
each one is a disagreement *between* branches that git merged without complaint.

### Added

- **A fresh-context finding-verifier gates every Phase 1 finding** (#431), a
  **per-lens precision eval harness** mined from closed `review-pr-finding`
  issues (#432), and a **convention-compliance lens** that may only report a rule
  it can quote verbatim (#433).
- **A vendored-provenance register** (#434): `plugins/uberdev/vendor.json` plus
  `tools/vendor/vendor-check.py`, eight offline checks over 75 components.

### Fixed

- **Every `/review-pr` fence rehydrates its own run** (#427) instead of reading a
  shell that has already exited.
- **`working_dir` would have expanded empty.** #427 deleted the `WORKING_DIR_ABS`
  assignment; #431's new defer callsite still named it, and `findings-to-issues`
  hard-refuses on an empty `working_dir`.
- **Seven counters that two branches each bumped identically.** #431 and #433 made
  byte-identical edits (41→42, 44→45, `agents (14)`→`(15)`), so git merged them at
  +1 where the truth is +2. Every corrected value is derived from its source of
  truth — the fixture, the roster glob, the manifest — not from arithmetic.
- **`review_fleet_rehydrate` broke two CI jobs** (#450): a lone apostrophe inside a
  heredoc nested in `$( )` makes bash 3.2 (macOS `/bin/bash`) scan past the closing
  paren, and `print()` through Windows text-mode stdout translated every `\n`,
  embedded separators included, into `\r\n` — so each rehydrated carrier returned
  with a trailing CR. Gate the first with `/bin/bash -n`; ubuntu's bash 5 cannot
  catch it.
- **Scratch worktrees no longer red the docs-accuracy suite** (#445): the T10
  corpus reads tracked content via `git ls-files` instead of walking the tree.
- **`code-fixer-contract` teardown no longer races `.git/objects`** (#428).
- **The install trust posture is honest again** (#435): the cited upstream issue
  was closed as a duplicate, not fixed; the live one is anthropics/claude-code#14815.

### Notes

- **#430 is deliberately not in this release.** It re-syncs `find-polluter.sh` to
  upstream superpowers v6.2.0 while #434's register still pins that component at
  `e7a2d16`, and the register cannot express a per-file re-vendoring. A per-file
  override was prototyped and rejected: it converts a real red into green while
  two sibling files still carry unadopted upstream fixes, and nothing ties the
  pinned SHA to any evidence. #430 lands separately, rebased onto the register.
- **`/review-pr` is still not runnable end-to-end.** #427 fixes the carrier
  rehydration, but `REVIEW_RUN_RESERVATION_RECEIPT` is minted in the setup fence
  and consumed nine Workflow relays later with no channel to carry it.

## [0.45.12] — 2026-08-10

### Added

- **A publication currency register for prkit** (#410). The published prkit carried
  the `trap … RETURN` bug #401 fixed here, was five manifest files short (33 of 38),
  and still tracked the 54-file `codex/` tree #381 retired — three divergences, zero
  red tests, because nothing recorded what the downstream artifact was generated
  from. Every gate certified the *source*.

  `tools/prkit/published.json` + `published-check.py` record the prkit version last
  published, a per-file source sha256, and explicit `pending` divergences. The
  comparator checks key sets against `manifest.txt` in both directions and actual
  vs declared divergence in both directions. `tests/prkit-publish.test.sh` P4 is the
  row that would have redded #401 when the fix landed. Unix-only in CI: no
  `.gitattributes` exists, so a Windows checkout rewrites LF and every digest would
  differ.

  `copyset` is a list of `{path, sha256}` objects, never a map. Measured: the map
  form puts `lib/secret-scan.sh` beside a 64-hex digest on one line, gitleaks scores
  it `generic-api-key`, and `finish-branch`'s pre-push scan hard-stops the push with
  no override. Check D enforces the layout and `--refresh` re-checks its own output,
  so the trap cannot be re-armed by a reformat.

  Deliberately not wired into `generate.sh` — regenerating from a stale record is how
  staleness gets fixed, so a build-time gate would block the cure.

  The register lands with **seven declared pending divergences, not zero**:
  `agents/conflict-resolver.md`, `agents/trust-trail-evaluator.md`,
  `commands/merge.md`, `commands/review-pr.md`, `lib/code_fixer_contract.py`,
  `skills/merge-pipeline/SKILL.md` and `skills/merge-pipeline/lib/discover.sh` — every
  one changed by v0.45.4–v0.45.11. `--refresh` was deliberately not used to clear
  them: it re-records current digests, which would assert the published artifact
  matches when it does not.

- **`verify.sh` gains a `codex-retired` assertion.** The generator stopped emitting
  `codex/` and no managed path covers it, so a pre-#381 target keeps its stale tree
  forever while every `plugins/prkit`-scoped check stays green. It asserts rather
  than deletes (the generator's destructive authority is not widened to a path it
  never writes), and tests `-e || -L` so a dangling symlink cannot slip through.

- **`*.tmpl` joins the shell-surface predicate.** `tools/prkit/templates/` is in the
  corpus but every file there ends `.tmpl`, so the `*.*` arm skipped all eight —
  including `ci.yml.tmpl`, the one template that emits shell into the generated repo.
  Both zsh detectors were blind to the generator's own output.

### Changed

- Docs reconciled: README said the manifest was count-locked at 37 (it is 38); RFC
  0014 §5.6 claimed `verify.sh` is "also runnable standalone in prkit CI" (it is never
  copied downstream); RFC 0016 §1 claimed "there is no second copy left to disagree
  with" (prkit is one, outside `contract_markers.py`'s reach).

## [0.45.11] — 2026-08-10

### Fixed

- **A GREEN trust trail survived a base change it never validated** (#440). A
  review is a statement about a *delta*, but the trail recorded only one endpoint:
  `review_resolve_phase1_base` computed the base at `review-pr.md:1659` and it was
  discarded one line later. The trailer carried PR number + parent SHA, the
  `uberdev-approved` label is a bare literal, the audit JSON had no base member, and
  all three `trust-trail-evaluator` primitives are two-commit tests between
  `trailer_sha` and `head_ref_oid`. So `gh pr edit <N> --base <other>` after a GREEN
  swapped the reviewed delta for an arbitrary one, every artifact stayed
  byte-identical, the evaluator returned PASS, and `/merge` merged it.

  The producer now writes a typed `review-base-identity.tsv` carrier (40-hex SHA +
  control-char-free ref, validated on both sides, typed `review_base_uncarried` /
  `review_base_unreadable` halts — never a soft default), the anchor commit carries
  `Reviewed-base: uberdev/review-pr@<sha> ref=<name>` under the existing
  `ANCHOR_MESSAGE_SHA256`, and the audit JSON gains a top-level `base`. A missing
  `base` maps onto the existing legacy → STALE path, so pre-change trails prompt a
  re-run rather than passing.

- **The gate deliberately does not fire on the automatic post-merge retarget.**
  "Merge-base moved ⇒ STALE" was rejected as the predicate: under squash merges —
  this repo's default — the integration branch never contains the parent's commit,
  the merge-base collapses to the root, and every child of a stacked run would
  false-STALE. A trust gate that cries wolf on an ordinary workflow is worse than
  the gap it replaces, because it trains the operator to override.

  The predicate is landed-delta equivalence, compared as **tree OIDs** via
  `git merge-tree --write-tree`, not as diff text. Diff text has three independent
  degrees of freedom that all produce false mismatches on an ordinary retarget: the
  `index <blob>..<blob>` header changes whenever the base touches a file the PR also
  touches; context lines shift when the base advances near the PR's hunks; and `@@`
  offsets shift when the base inserts a line anywhere earlier in a shared file.
  Tree OIDs have none of them.

- **`$TRAILER_SHA` had no producer.** The `(b.5)` fence in `merge-pipeline/SKILL.md`
  passed a name nothing in the repo ever bound — `grep -rn` found only the comment,
  the call site, and the lib's usage doc. Every retargeted PR would have degraded to
  `unavailable` and therefore STALE. The fence now binds it and refuses with
  `trust_trail_trailer_missing` rather than degrading.

- **YELLOW trust trails were silently unmergeable.** `review-pr.md` appends
  `TRAILER_SUFFIX` (` severity=critical-deferred count=N`) to the anchor, so a
  `$`-anchored 40-hex trailer regex matched nothing on a deferred-critical PR.

- **A pre-existing cross-fence dereference in the Phase 2 scope refresh.**
  `review-pr.md:2157` and `:2196` were already reading a `BASE_SHA` that nothing in
  their shell bound — a live instance of the #418 / #419 class. Both now read the
  carrier with typed halts.

  The evaluator's tool allowlist is untouched: still no `gh` and no `merge-tree`.
  The five inputs are threaded caller-side exactly as `status_check_rollup` is,
  preserving the deliberate boundary that the agent never queries live PR state.

## [0.45.10] — 2026-08-10

### Fixed

- **Phase 3 could force-push a branch another open PR was stacked on, with no
  check at all** (#438). `--force-with-lease` + `--force-if-includes` protect only
  *this* PR's head; they say nothing about who bases on that branch. Measured:
  `gh pr list` appeared **zero** times in the entire Phase 3 surface. Reproduced —
  the push returned 0, the downstream PR's merge-base collapsed, and its diff
  silently grew from `{fb}` to `{fa, fb}` with no audit event, no halt and no
  prompt. A reviewer opening that PR afterwards is shown commits nobody put there.

  The push is now gated on the push **shape** rather than on the edge id: if the
  lease SHA is an ancestor of the new head the push is a fast-forward, which cannot
  move any dependent PR's merge-base, and the gate is skipped. Otherwise a
  dependent-PR query runs and a non-empty result halts with
  `data.subreason=ci_push_would_rewrite_stacked_base`. Gating on the edge instead
  would have refused every `fix_code` push — which only appends a commit — and made
  Phase 3 auto-fix permanently unusable on any branch with a stacked child.

  The query pins `--repo` to the slug resolved from the very remote the push names.
  Every other `gh` call in the file pins `--repo`; this one initially did not, and
  gh's implicit remote resolution (`upstream` > `github` > `origin`, plus
  `gh repo set-default` and `GH_REPO`) would have made the gate answer about a
  *different repository* — returning a valid empty array, passing the shape check,
  and letting the force-push proceed with an audit trail recording it as stack-safe.
  A failing ancestry probe or an unparseable remote falls through to the strict
  branch, so "cannot tell whether this rewrites" runs the stricter path.

- **The rebase guard could not tell a correct rebase from a stack-detaching one.**
  `lib/code_fixer_contract.py` asserted `merge-base --is-ancestor
  authority["base_sha"] head_after`, where `base_sha` is the *pre-rebase
  merge-base*, not the base branch tip. Once the base branch is force-pushed that
  merge-base collapses to the fork point, which every candidate rebase target
  contains, so the assertion passed unconditionally. Differential test, same pinned
  authority: rebase onto the real base → `rc=0 REBASED`, 1 commit; rebase onto the
  detaching target → `rc=0 REBASED`, 3 commits with the parent's two duplicated. It
  was the only predicate consumer of `base_sha` in the whole contract, so nothing
  else caught it.

  A new `base_tip_sha` required member is pinned in the `review_pr.ci.rebase`
  authority and asserted **alongside** the existing merge-base predicate, under its
  own `ci_rebase_base_tip_not_ancestor` terminal.

  Known limitation, tracked by #427: `base_tip_sha` crosses the ROUTE → mint fence
  boundary as a bare scalar, exactly as the pre-existing `lease_sha`, `base_sha` and
  `base_branch` do on the same hop. It is fail-closed — an empty value is refused at
  mint as a missing required member — but it is not carried, so this half is subject
  to the same end-to-end cross-fence blocker as the rest of Phase 3. Closing that hop
  is #427's scope, not this change's.

## [0.45.9] — 2026-08-10

### Fixed

- **`/merge` resolved one repo-global `integration_branch` and used it for every PR
  in the run, ignoring each PR's real base** (#437). `baseRefName` was fetched in
  five places in the merge pipeline and read in zero:

      $ grep -rn 'baseRefName' plugins/uberdev/skills/merge-pipeline/ | grep -v -- '--json'
      rc=1

  The wrong base flowed into the Step 3.1 probe, the Step 3.3.ii scratch worktree,
  the Step 3.3.iii conflict-resolver inputs and the STRATEGY-SWITCH re-probe — and
  then Step 3.3.v pushed the result. Reproduced in both directions on a
  `main → fix/a → fix/b` fixture:

  - *phantom conflict* — `merge-tree fix/a fix/b` exits 0 while
    `merge-tree main fix/b` exits 1, so `/merge` invented a conflict and dispatched
    conflict-resolvers at it;
  - *invisible real conflict* — a genuine `fix/a`-vs-`fix/b` conflict was missed
    because `main`-vs-`fix/b` was clean, so `/merge` proceeded down the clean path
    and fired `gh pr merge`.

  `/goal` dispatches this mode (`lib/goal-state.sh:2449`), so autonomous runs
  inherited it. Every site now resolves the PR's own base from the Step 1.4
  `pr_view_projection`, and the `origin/`-qualified invariant (#303) is re-scoped
  from "every Phase-3 write site" to *every site naming a base ref* — Steps 1.5 and
  2.2 were per-PR but still spelled the ref bare, which for a stacked PR is
  `fatal: ambiguous argument` with empty stdout, silently reading as "no file
  overlap" and scheduling parallel conflict-resolve against a PR touching the same
  files.

- **Stacked PRs were invisible to `/merge` entirely.** `lib/discover.sh` filtered
  `gh pr list --base "$integration_branch"` — an exact match — so a stacked PR
  returned zero candidates and `/merge` exited 0 reporting "nothing to merge",
  which is the false-convergence signal `/goal` consumes.

  Discovery now filters client-side to `baseRefName == integration_branch` **or**
  the head branch of another candidate, applied transitively to a fixpoint. This
  makes the ordering rule at Step 2.1 reachable for the first time: its base-ref
  edge ("a PR-B base ref equal to PR-A head ref → PR-A must land before PR-B") could
  never fire while the wire filter guaranteed every survivor shared one base. Its
  other edge source, the `Depends on #N` body parse, was always reachable and is
  unchanged.

- **Discovery silently truncated at 30 PRs.** Dropping `--base` from the wire query
  widened it to every open PR, and `gh pr list` defaults to `--limit 30`. An
  explicit `--limit 200` is now passed (matching `lib/goal-state.sh`), declared as a
  named constant, integer-validated, with a stderr breadcrumb when the window
  saturates.

- **A skipped parent could strand its stack children.** If a parent PR is gated out,
  its dependents were still queued against a base that will not land. A reachability
  prune re-runs the closure over the surviving set (reusing the same filter function,
  so the two cannot drift), and Step 3.2 additionally gates `gh pr merge` per
  iteration on the parent having actually landed. Both surface the new
  `pr_base_parent_skipped` gate-fail reason.

  Failure modes are conservative throughout: an unresolvable per-PR base skips the PR
  with a typed `GATE_FAIL_REASON_ENUM` member rather than falling back to the global
  branch, and a failed base range records the pair as *overlapping* rather than as
  disjoint.

## [0.45.8] — 2026-08-10

### Added

- **The PR-creating surfaces can target a branch other than the default one**
  (#439), which is what a dependent (stacked) PR requires. Of the four live
  `gh pr create` call sites in the plugin, only `skills/scan-fleet/workflow.js`
  passed `--base`; `skills/finish-branch/SKILL.md` and
  `skills/solve-fleet/workflow.js` silently targeted the repository default.

  `finish-branch` resolves the base explicit-first — `UBERDEV_PR_BASE_BRANCH` in
  the environment, then `pr_base_branch` in `.claude/uberdev.local.md`, then the
  origin default branch — through the existing `uberdev_read_string` helper with a
  validating regex, not a hand-rolled parser. With no override set the resolution
  lands on the default branch and **no `--base` flag is emitted at all**, so the
  previous behaviour is preserved byte-for-byte. The resolved base feeds both the
  `gh pr create` invocation and the pre-push secret-scan range, so the two cannot
  disagree.

  `solve-fleet` forwards the branch its run was launched from, but only after
  verifying it exists on origin — an unverified local-only branch would otherwise
  make `gh pr create --base` fail for every issue in the fleet, which is strictly
  worse than the old behaviour. When it does not verify, no instruction is emitted
  and the run degrades to exactly the previous default.

### Fixed

- **The pre-push secret scan could scan nothing at all, and said so to no one.**
  `finish-branch`'s base resolution was written as

      BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed '…' \
              || git rev-parse --verify origin/main 2>/dev/null || …)

  `||` binds to the *pipeline*, and `sed` exits 0 even on empty input. So when
  `symbolic-ref` failed, `sed` still succeeded, `BASE_REF` came back empty, and
  the `origin/main` / `origin/master` / root-commit fallbacks were all
  unreachable — measured identically under bash and zsh. The empty value then
  failed the `[[ -n ]]` guard and the scan degraded to `git diff --staged`, which
  on a fully-committed branch scans **nothing**. A security control that fails
  open, silently.

- **An explicitly-configured base that does not resolve no longer widens the scan
  to the whole history.** The root-commit last resort is now reached only on the
  no-base-configured path; a configured-but-unresolvable base warns loudly on
  stderr naming the base, and falls back to the origin default branch. Falling
  through to the root commit is strictly *wider* than the previous behaviour and
  re-creates the hard-abort-with-no-override failure this work exists to remove —
  a stacked branch would inherit its parent's secret-shaped test fixtures into
  scan range and abort the push.

## [0.45.7] — 2026-08-10

### Added

- **Phase 3's cross-fence carriers are now executed, not grepped** (#419).
  `tests/review-pr-phase3-ci.test.sh` greps fence *text* everywhere except
  S32-RT.14/15. A grep cannot observe a value that never crosses a shell
  boundary, so the carriers Phase 3's fix path is built on could each be stranded
  and the suite would stay green. That is not hypothetical: #399 shipped three of
  them stranded behind a 290-assertion green run, with the whole fix path
  unreachable from line one.

  S33-RT extends S32-RT.14/15's shape to the carriers themselves. It extracts the
  PRODUCING fence and the CONSUMING fence from `commands/review-pr.md` verbatim
  and runs them as **two separate shell invocations sharing nothing but a run
  directory** — the boundary production actually crosses. Per carrier, two rows:

  - *round-trip* — the consumer OBSERVES the produced value, proven by an effect
    only that value can produce (the branch names in ROUTE's `git fetch` argv, the
    rationale bytes inside the REFUSED arm's synthetic aggregate, the conflicted
    pathnames in `git add`).
  - *fail-closed* — with the carrier DELETED, the consumer halts under its
    documented `data.subreason` and mutates nothing.

  Carriers covered: `ci-fix-phase.txt` (Step 1 → 6c.4 ROUTE), `ci-push-target.tsv`
  (CROSS-REPOSITORY GATE → ROUTE), `ci-fixer-terminal.json` (6c.4w.2 → 6c.5's
  REFUSED arm) and `ci-conflict-paths-*.zlist` (CONFLICT-RESOLVE step 1 → step 3).
  Run under bash and zsh, because the harness runs these fences under `/bin/zsh`
  and the carriers move through `read -d ''`, `$'\t'` and array expansions that do
  not behave identically there.

  Only the fences' *dependencies* are faked (the audit sink, the gh/git CLIs,
  `code_fixer_contract.py`'s four verbs, `child-dispatch.sh`'s input builder);
  `review-fleet-args.sh` and `review-push-target.sh` are reached through a fixture
  plugin root but are the REAL libraries, because they own the carrier
  readers/writers this section exists to exercise.

  Every run — producers included — is appended to a per-row trail with its rc,
  call log and stderr, printed on failure: only the consumer's rc is asserted on,
  so a producer that dies must not surface as a red row naming the wrong cause.

  Verified by mutation, not by the rows passing: stranding each producer onto a
  different filename reds its round-trip row, and reverting each consumer to the
  inherited-variable / soft-default form it had before #399 reds its fail-closed
  row. All seven mutations detected; none survived.

  The three carriers v0.45.4 added (`ci-probe-verdict.txt`, `ci-classification.json`,
  `ci-check-name.txt`) are read by the same two consumers *ahead of* the carriers
  four of these rows target, so they are seeded as preconditions. The section
  header states plainly that they are seeded here and covered elsewhere
  (S33-RUNTIME, S33-FENCE) — a comment that overclaims coverage is the defect
  class this file exists to close.

## [0.45.6] — 2026-08-10

### Added

- **The `/merge` SKILL fences now execute under a real zsh** (#412). #401 closed
  the library half of this blind spot (`lib/discover.sh` runs under `zsh -c`,
  B23). The fence half stayed open by construction: `tests/merge.test.sh` is the
  only thing that executes merge fence bodies (M95, M97) and it is bash-bound —
  wired into `shape-checks-windows`, so it runs under Git Bash there and under
  bash on ubuntu, never under zsh. Every bashism living in the SKILL body rather
  than in a library was therefore invisible in the one command whose fences the
  Bash tool actually runs through `/bin/zsh`.

  `tests/merge-pipeline-zsh.test.sh` adds 43 rows. It slices each
  contract-delimited fence out of the Markdown **by marker name** — never by line
  number or fence ordinal, so the RFC 0012 §3.2 thin-SKILL rewrite cannot leave it
  silently slicing the wrong block — assembles a real child script, and runs it
  under `zsh -f` against on-disk sandboxes:

  - `MZ0` harness floor, marker contract, extract anchors (6 markers)
  - `MZ1` Step 1.1 acquire: contention / stale-reclaim / crashed-acquisition /
    hostile inherited `RUN_ID` / filesystem-error-is-not-contention
  - `MZ2` heartbeat touch + Step 4.6 release, holder-verified both ways
  - `MZ3` Step 3.4 issue cleanup against a recording `gh` function stub
  - `MZ4` Step 1.4.5 dispatch guard ladder, on-disk cap and rc classifier
  - `MZ5` Step (c.0) trust-gate — two-shell parity for a block `merge.test.sh`
    M95 only ever executed under bash
  - `MZ6` negative controls: the zsh scalar-split class and `trap … RETURN`

  No divergence exists between the two shells today, so this is a regression lock,
  not a bugfix. Its falsifiability is bought rather than asserted: the header
  carries a mutation-guard table naming the production line whose revert reds each
  row, and all 17 of those mutations were executed against a mutated copy of
  `SKILL.md` — each reds exactly its named row.

  There is no SKIP path: a missing `zsh`/`jq`/`git`/`python3` is FATAL + exit 2,
  because a green run that proved nothing is the failure mode this fixture closes.

  `merge-pipeline/SKILL.md` gains ten inert `# BEGIN`/`# END` marker comments plus
  one prose sentence per fence naming the consumer test — the file's own declared
  `merge-trust-gate-fence-v1` convention. No fence logic is edited, reordered or
  reindented.

## [0.45.5] — 2026-08-10

### Fixed

- **The zsh parameter-modifier guard read neither `tests/`, nor `tools/`, nor a
  single extension-less shipped hook** (#413). It enumerated its own corpus —
  `plugins/**` filtered by `-name '*.md' -o -name '*.sh'` — while the
  tied-parameter and `trap … RETURN` guards beside it already shared
  `_xshell_corpus` + `_xshell_is_shell_surface`. Those are the exact two gaps the
  tied guard had had to close twice, finding live hits each time. #401 declared
  the boundary in a comment instead of folding the third copy in, which is the
  #370/#371 shape: a declared boundary is still a second copy of the contract.

  Pointing it at the shared pair found **seven** live mangled shapes in `tests/`:
  five refspec assertions in `review-pr.test.sh` (`"$SHA:refs/…"`, where zsh's
  `:r` eats the colon) and two `doc:name` pairing loops in
  `review-child-handoff.test.sh`, where `:r` silently strips `.md` off the doc
  path and `:s` is a hard `bad substitution`. All are braced; the change is inert
  under bash and correct under zsh.

  The seventh was found while rebasing onto v0.45.3 and is the sharpest instance
  of the class yet — `review-pr.test.sh:782`. The same PR that introduced it also
  wrote the comment eleven lines above the production pin (`:529-532`) explaining
  that the unbraced form is a zsh `:r` modifier which made *"every anchor push die
  with src refspec does not match any"*, pinned the production side to the braced
  form, and then spelled its own assertion string unbraced.

- **The guard's modifier letter class was wrong in the direction that makes a
  guard unfixable.** `p`, `U`, `W`, `x` and `X` were listed and zsh applies none
  of them to a parameter expansion, so the widened corpus immediately reddened
  PowerShell (`"-Path $env:UBERDEV_JUNCTION_PATH"` is a namespace reference no
  shell expands). The class is now exactly the set zsh really applies, and it is
  no longer a claim: two live rows drive every ASCII letter through the real
  shell and red in both directions — a listed letter zsh leaves alone is
  decoration, an applied letter the class misses is a blind spot. The comparison
  is colon-based so filesystem-resolving modifiers do not diverge between macOS
  and ubuntu.

  Because the scan now reads its own file, its anti-vacuity heredoc and three
  live probes carry the same allow-marker mechanism the tied guard uses —
  trailing-comment marker, dead-marker honesty row, per-file pinned inventory —
  plus an anti-false-positive row. Hits are numbered before the comment filter
  and carry their path on every line, which the previous form did not.

## [0.45.4] — 2026-08-10

### Fixed

- **Phase 3 recorded `unknown` for its own diagnosis, and `--no-ci-fix` halted on
  green CI** (#418). Every `bash` fence in `commands/review-pr.md` is its own
  harness shell, so a name bound in one fence is gone in the next. Written
  `${name:-<default>}`, that is not a defensive spelling of the same value — it
  is the default, on every run. #399 moved three such scalars onto run-dir
  carriers; four more were still live:

  - `${failure_class:-unknown}`, `${check_name:-unknown}` and
    `${signal_anchor:-unknown:1}` in the REFUSED arm's aggregate writer, so every
    CI-refusal issue the autopilot filed recorded `unknown` / `unknown:1` — the
    classifier's whole diagnosis erased at the moment it was written down, in a
    CRITICAL issue aimed at a human.
  - `${PROBE_VERDICT:-unknown}` in ROUTE's probe-only arm, so `--no-ci-fix`
    audited `state=unknown` and, comparing `""` against `green`, forced
    `OUTCOME=halted` even on green CI.

  `failure_class` and `signal_anchor` are also what ROUTE's `case` keys on, so
  `code_bug` fell through to `ci_fix_dispatch_unknown_class` on every run.
  `check_name` had no producer anywhere in the file — consumed once, bound
  nowhere.

  Fixed with three single-writer run-dir carriers, each written by the fence that
  *binds* the value, in the idiom `ci-push-target.tsv` / `ci-fix-phase.txt`
  already use: `ci-probe-verdict.txt`, `ci-check-name.txt` and
  `ci-classification.json`. `review_select_failed_ci_run` now emits the selected
  row's check name as a fourth column (already its tie-break key) and rejects
  control characters in it, which is what makes `check_name` producible at all.

  Both halves of every carrier validate. None of the four values has a documented
  default, so a writer never records a token outside its vocabulary and a reader
  never returns one; unreadable is "cannot tell" and halts with a typed subreason
  (`ci_*_uncarried` on the write side, `ci_*_unreadable` on the read side) rather
  than routing a mutating fixer on an invented value. The carry never outranks the
  `ci_probe_unreachable` carve-out — a `gh` outage reaches the carrier code with
  no verdict at all, so the write is attempted only for a verdict in the
  documented vocabulary.

## [0.45.3] — 2026-08-10

### Fixed

- **`/uberdev:review-pr` could not complete on any PR, and therefore no PR could
  ever be merged** (#429). `review_publish_same_repo_pr_head` projected the head
  repository as `.headRepository.nameWithOwner`. `gh` declares that field and
  never populates it — measured on gh 2.83.1, `gh pr view 422 --json
  headRepository` returns `{"id":"R_kgDOSOF5tw","name":"UberDev",
  "nameWithOwner":""}`. The gate's identity conjunct therefore compared `""`
  against the repository slug and returned 79 on every invocation, turning
  "refuse forks" into "refuse everything".

  Both call sites map 79 to `exit 2`: the Step 6a post-fixer push, and — the one
  that mattered — the trust-trail anchor publication immediately before the
  `uberdev-approved` label add. Since the broken gate *is* the step that emits
  the trail, no PR could obtain one, and `/merge` Phase 1.4 PATH_2 consequently
  gated every PR out with `trust_trail_label_missing`. The two commands were
  deadlocked against each other.

  The identity is now read as `headRepositoryOwner.login` + `headRepository.name`
  — the same resolution `lib/review-push-target.sh` has always used. That lib
  documented this exact failure in its header comment and was wired into a single
  call site (the Phase 3 ROUTE gate); the publish gate never received it. One
  fact, two uncompared copies.

  The projection also moves from a tab-joined line to one field per line. Tab is
  IFS whitespace, so a tab-joined projection containing an empty field collapses
  under `read`: the fields shift left and a malformed identity parses as a
  well-formed *different* one. `review-push-target.sh` had already switched for
  this reason.

### Changed

- `tests/review-pr.test.sh` gains **R9.17**, which runs the gate's own `--jq`
  filter through real `jq` against a document shaped like gh 2.83.1's actual
  response. The pre-existing R9.13 block stubs `gh` and emits the projection's
  *output*, so it can never exercise the filter — which is precisely why CI
  stayed green through this bug: the stub's `head_repo=owner/repo` is a value
  real `gh` never emits, and the test agreed with the fiction rather than with
  reality. R9.17 carries two anti-vacuity cases (a genuine fork, and a foreign
  head-repository owner with `isCrossRepository` lying) so the conjunct cannot be
  satisfied by deleting it.

- The two awk extractors for `review_publish_same_repo_pr_head` now bound the
  function on a column-0 `}` rather than any indented one. The gate body now
  legitimately contains `  } <<<"$live_identity"`, and the previous bound
  truncated the function there — an extractor that silently returns half a
  function makes every assertion below it vacuous rather than red.

### Known issues

- `skills/merge-pipeline/SKILL.md` Step 1.6 fork preflight reads
  `headRepository.owner.type`. Real `gh` does not populate `headRepository.owner`
  in that projection either — the owner lives in the sibling
  `headRepositoryOwner`. This is currently prose with no executable consumer, so
  it is latent rather than live; tracked on #429 as the out-of-scope twin.

## [0.45.2] — 2026-08-09

### Fixed

- **The second half of the starvation-intolerant assertion sweep** (#420 covered
  the first). The remaining 55 of the 110 CI suites were scanned, and eight more
  files carried assertions whose verdict turned on machine speed rather than on
  whether the code was right:
  - `run-manifest`: a `sleep 5 &` fixture had to outlive four appends plus a
    reconcile — five CPython startups — and under throttled QoS consumed 4.136s
    of its 5.000s budget, a 12.5x swing driven purely by machine QoS. Also an
    exact-count oracle over 24 concurrently-forked appenders that reported only
    an aggregate, with every child's stderr sent to `/dev/null`: the one line
    naming the failing appender was destroyed at the moment it was produced.
  - `live-semaphore`: a `sleep 10` provider that then deliberately burned 2s of
    its own budget ageing a lease.
  - `dispatch-background`, `review-pr`, `route-context`, `route-unsupported`,
    `production-run-tree-builder`, `agent-dispatch`: wall-clock windows,
    resource-dependent counts, and fixed timeouts acting as correctness oracles
    rather than hang detectors.
- **Twenty-plus assertions that could never fail.** POSIX exempts a command whose
  status is inverted with `!` from `errexit`, so `! some_cmd` as an assertion is
  dead — it reports nothing whether it holds or not. `route-context` alone had
  20 (the finding said 17; the fixer counted them itself rather than trusting
  the number). More in `route-unsupported` and `production-run-tree-builder`.
  These are worse than flakes: a flaky test tells you something is wrong, a
  vacuous one tells you nothing forever.

## [0.45.1] — 2026-08-09

### Fixed

- **`green_after_fix` has a producer, so an autopilot-rewritten head no longer
  reads as a clean one** (#400). It was a `CI_OUTCOME_ENUM` member with seven
  readers and zero producers, so `phases.phase3.outcome` serialised identically
  for a PR whose CI was always green and one whose head a fixer committed to,
  rebased and force-pushed — a `/merge` trust-trail reader could not tell them
  apart. The two differ by exactly one fact, whether a fixer rewrote the head
  the CI passed on, and that fact lives in `ci-loop-state.json`'s `fix_pushes`,
  not in the fence observing the green. One derivation,
  `review_fleet_ci_green_outcome RUN_DIR CI_FIX_PHASE`, now answers it and no
  call site restates it — two spellings of "which green" is the defect itself.
  6c.2 MONITOR's `green)` arm replaces its literal and 6c.1 PROBE gains an
  executable terminal where its green row had been prose in a table, which is
  the fast path a post-fix re-probe takes and so the terminal most likely to be
  looking at a rewritten head.

## [0.45.0] — 2026-08-09

### Changed

- **BREAKING: `/review-pr` Phase 3 now fixes red CI instead of halting on it**
  (#383, half two). Half one (#393) shipped the Phase 3 CI engine — the five
  `review_pr.ci.*` contract edges and the four `ci-classify` / `ci-fix` /
  `ci-conflicts` / `ci-defer` stages — deliberately UNCALLED: a red check still
  halted at 6c.3 CLASSIFY with `subreason=ci_transport_unsupported`, and
  `--no-ci-fix` was the supported mode. This retires that gate. A red check now
  routes to the classifier, and a `code_bug`, `env_drift` or `stale_base`
  verdict dispatches a real fixer whose commit reaches the PR under ONE leased
  push.

  This is user-facing and mutating. `/review-pr` on a PR with failing CI may now
  commit, rebase and force-push to the PR head, where before it refused. Pass
  `--no-ci-fix` for the previous behaviour.

### Fixed

- **BOTH Phase 3 conflicted-path enumerators now agree with the judge they
  feed** (#398). `_ci_unmerged_paths` has covered all seven porcelain unmerged
  pairs since #393, but the CONFLICT-RESOLVE arm carries two `^UU `-only
  matchers, not one. Step 1 enumerated zero files for an add/add or
  modify/delete conflict, staged nothing, and failed `git rebase --continue` on
  the still-unmerged index. Step 3's re-conflict detector had the same blind
  spot one rebase stage later, and worse: a second-stage conflict counted as
  zero re-conflicts, so the arm skipped its RESTAGE branch and ran
  `git rebase --abort`, discarding the stage-1 resolution the resolvers had just
  produced and reporting `rebase_continue_failed` — the wrong cause. Nothing in
  `tests/` covers either matcher's pair set, so the suite was green with the bug
  present.

- **The Phase 3 ceiling test compared the wrong number.** `S28.5` re-derived the
  engine's conflict cap by grepping for a bare `clampInt(CFG.ciConflictCap, …)`
  literal. #393 wrapped that clamp in `Math.min(…, maxAgents)` precisely because
  a cap above `maxAgents` passes the enumerator and is then refused by
  `ceilingGate()` with zero children dispatched — so the literal comparison
  could not see the drift it existed to catch, as `workflow.js`'s own comment
  says. It now reads both defaults and asserts against their minimum.
## [0.44.3] — 2026-08-09

### Fixed

- **`#396.2` was itself starvation-intolerant, the exact defect #396 exists to
  retire** (#420). The row proved the `UBERDEV_HARNESS_TIMEOUT_MS` knob drives
  the real per-case budget by running the harness self-test at 1 ms and
  requiring a `failed: [1-9]` summary. Under contention the self-test can abort
  before it prints a summary at all — rc is still 1, but there is no line to
  match, so the row reds and blames a knob that is demonstrably working.
  Measured on a loaded host: 4 of 20 runs had rc=1 with no summary. It red
  `shape-checks-windows` on `main` and `shape-checks` on the #399 branch, on
  byte-identical harnesses, while passing every unloaded local run. The
  evidence is now the per-case diagnostic, which names the overridden value and
  so is strictly stronger than a failure count. `#396.2a` pins that the
  diagnostic reports the override rather than the shipped default.

## [0.44.2] — 2026-08-09

### Fixed

- **`/review-pr` Phase 3 no longer pushes a fork PR's head to the base
  repository** (#395). Phase 3 bound its push target from a bare `gh pr view
  --json headRefName,baseRefName` and then fetched, leased and pushed `origin
  <headRefName>` — but `origin` is the repository the PR was opened *against*,
  so for a fork PR that branch name belongs to the contributor's repository.
  The push either fails, or (when the base repo carries a branch of the same
  name — `main`, `dev`, `release` guarantee exactly that) addresses an
  unrelated ref. A new `lib/review-push-target.sh` resolver answers "may Phase 3
  push this PR's head to `origin`" before the fetch and before the lease
  capture, returning named rcs (78 cross-repository, 79 unidentifiable, 2
  malformed call) that the fence maps to `ci_push_target_cross_repository` /
  `ci_push_target_unresolved` audit subreasons. Head identity is read as
  `headRepositoryOwner.login` + `headRepository.name`, **not**
  `headRepository.nameWithOwner` — gh declares that last field and never
  populates it (measured on gh 2.83.1), so a gate keyed on it turns "refuse
  forks" into "refuse everything".

- **The workflow-harness dry-run budget is a hang detector, not a stopwatch on
  the runner** (#396). `tests/_workflow_harness.js` hard-coded a 2000 ms budget
  at every self-test call site. That number is not a property of the code under
  test — H11 builds its script from `VALID_META` and asserts on the recorders,
  so it settles in microseconds — which meant a starved `shape-checks-windows`
  runner reddened H11.1/H11.2/H11.3 on one attempt and passed twenty minutes
  later with a byte-identical harness. One named, generous, env-overridable
  budget (`UBERDEV_HARNESS_TIMEOUT_MS`, default 30 s) replaces every per-call-site
  literal; a malformed override refuses with rc=2 rather than silently falling
  back to a budget nobody chose. H15 keeps a short budget on purpose (its script
  never settles), H7/H8's wall-clock probes derive from the shared knob, and a
  failing self-test row now names its cause on the `FAIL` line.

- **`/merge`'s release-anchor inert-release check no longer misses a rename's
  source path** (#397). `git diff --name-only` has rename detection on by
  default and reports a rename as its *destination* alone, so the deleted source
  never reached step (4)'s path set — and a subset test is only sound over a
  total set. `git mv src/security_guard.sh CHANGELOG.md` folded into an
  otherwise-clean version bump therefore reported six surfaces, the permitted
  shape, and rode the trust gate with an arbitrary deletion attached. All three
  `git diff` invocations now carry `--no-renames` and a `--` terminator,
  including the `RELEASE_ANCHOR_MAX_DIFF_LINES` bound (which had been measuring
  git's rename-collapsed rendering, 36 lines, instead of the real 1044-line
  walk). Same defect class as #393.

- **`/review-pr` Phase 3's conflict enumerator reads the one unmerged
  definition** (#398). The CONFLICT-RESOLVE arm's Step-4 re-bind hand-rolled
  `mapfile -t conflicted_files < <(git status --porcelain | awk '/^UU /')` —
  two independent defects with one observable, a silently empty array. It never
  followed #393's widening of `_ci_unmerged_paths` from the two exact bytes `UU`
  to all seven porcelain unmerged pairs, so an add/add conflict yielded zero
  conflict-resolver children and a vacuously true "all RESOLVED"; and `mapfile`
  is a bash builtin, absent under the `/bin/zsh` these fences execute in, with
  nothing consuming its 127. Non-`-z` porcelain also C-quotes spaced paths, so
  whitespace-splitting truncated them. The second copy of the vocabulary is
  deleted rather than widened: `code_fixer_contract.py` grows a NUL-terminated
  `list-ci-unmerged-paths` transport, `review-fleet-args.sh` grows the missing
  three-valued producer `review_fleet_unmerged_paths` (0 paths / 1 none /
  2 probe-failed), and the fence branches on all three rcs, halting under a new
  `rebase_enumerate_failed` subreason.

- **`merge-pipeline/lib/discover.sh` releases its stderr capture explicitly —
  `trap … RETURN` is dead under zsh** (#401). All three public functions guarded
  their `mktemp` capture with `trap "rm -f …" RETURN`. zsh does not accept
  `RETURN` as a signal and SKILL.md `bash` fences execute under `/bin/zsh`, so
  the trap never installed: one leaked temp file per call plus `undefined
  signal: RETURN` on stderr on every discovery, and under `errexit` the trap
  line aborted the function outright, letting the caller's `|| N=0` normalise a
  real single-PR fast path to "no PRs". Cleanup is now an explicit `rm -f` on
  all nine return paths; no trap of any signal survives (`EXIT` is not the
  alternative — the library is sourced, so it would install on the caller's
  shell). A5b, which asserted the buggy literal was *present*, is repointed at
  the real invariant, and a repo-wide `trap … RETURN` guard now runs on both
  shape-check jobs.

- **`/review-pr` declares its `aggregate` artifact, so `AGG_PATH` is never
  empty** (#402). `CALLERS["review-pr"]["artifacts"]` declared five artifacts
  and no `aggregate`, while four downstream copies of that vocabulary were
  written as if it had one. `uberdev_command_workspace_prepare review-pr`
  therefore exported `AGG_PATH=""`, the Phase 1 fence handed that empty string
  to `post_review_write_aggregate_v2`, the writer classified it `unsafe-output`
  (`os.path.isabs("")` is False) and the fence returned 70 — so no fixer, no
  Phase 2 and no Phase 2.5 ever ran, on any transport. review-pr now declares
  `"aggregate": ("post-impl-review-final.md", b"")`, `name_to_global` is
  promoted verbatim to the module constant `NAME_TO_GLOBAL` so the new
  declared-vs-consumed subset guard reads the same mapping `main()` uses, and
  `finish-branch` skips zero-byte `post-impl-review-*.md` reports now that the
  file exists (empty) from prepare onward.

- **The six Phase 1 reviewers deliver the machine contract instead of five prose
  ones** (#403). The Phase 1 result boundary is `re.fullmatch` over the whole
  result file with `severity` restricted to `blocker|suggestion`, but
  `skills/review-fleet/workflow.js` told each child to write "in your agent
  file's declared output contract" while the Workflow composer delivered no
  contract at all, and five of the six agent files declared their own shape
  (four prose report formats plus an inline-YAML one) with colliding severity
  vocabularies. Every Phase 1 wave came back BLOCKED and the aggregate was
  suppressed. The policy fact now has one declaration and two readers:
  `review_fleet_contract_path` resolves the manifest declaration in shell
  (re-expressing the routed path's Python safety predicate), `commands/review-pr.md`
  4w.1 emits `phase1ContractPathAbs`, `workflow.js` gates it with `isSafeAbsPath`
  *before* the nonce gate and renders it into all six prompts, and the five agent
  files now point at `shared/phase1-reviewer-output-v1.md`. Fixing it exposed a
  second defect: `! cmd` is exempt from `set -e`, so the entire reject corpus in
  `tests/child-wait.test.sh` was vacuous — a `re.fullmatch` → `re.search`
  mutation left the suite green.

- **Rendered command fences bind their positionals at call time, not at render
  time** (#404). The slash-command renderer substitutes `$ARGUMENTS`' positional
  tokens into the *entire* rendered body, not only into single-quoted awk script
  bodies (#222's half), so every shell positional in every `bash` fence of a
  rendered command or skill is rewritten at load time: a helper written as
  `local repository_root="$1"` is hard-wired to whatever the caller's first
  argument happened to be. `/uberdev:review-pr 647 --no-simplify` rendered that
  line as `local repository_root="--no-simplify"` and died at the third
  executable step of setup — before RUN_ID reservation, before Phase 1, before
  any reviewer dispatch — so the command could not run at all with a non-empty
  argument. Braces are not an escape (`${N}` is replaced when positional N
  exists and merely brace-stripped back when it does not). All 64 sites across
  9 templated files are re-spelled `${@:N:1}`, which has no
  dollar-immediately-followed-by-digit substring; 37 helpers gain
  `[ "$#" -ge N ] || return 2` since a slice yields empty under `set -u` where a
  bare `$N` would abort. One of those was a live fail-open, not hardening:
  `abort_if_secret` ends `[[ "$scan_rc" -eq 0 ]] && return 0`, and
  `[[ "" -eq 0 ]]` is true — a missing third argument reported "no secret found".

### Changed

- **The shell ratchets widened so these classes cannot return** (#401, #404).
  `BASH_GUARD_REGEX` goes from `\$[0-9]` to `\$\{?[0-9]`, so a `$N` → `${N}`
  non-fix can never be certified clean; R4 is re-scoped from
  `orchestrator/SKILL.md` alone to the whole templated corpus (every
  `skills/**/SKILL.md` ∪ every `commands/*.md`) with an anti-vacuity arm that
  keeps a broken `find` from reporting a green ratchet over zero files. The
  tied-parameter guard's corpus enumeration and file predicate are extracted
  into `_xshell_corpus` / `_xshell_is_shell_surface` and shared with the new
  `trap … RETURN` guard.

## [0.44.1] — 2026-08-07

### Fixed

- **Bare `local status` / `local path` declarations no longer corrupt the shell
  they run in** (#390). Every `bash` fence in a command or SKILL.md executes
  under `/bin/zsh`, where `status` and `path` are *tied parameters*: `path` is
  tied to `$PATH` and `status` to `$?`. Declaring either bare inside a function
  blanks the tied variable for the rest of that scope — a `local path` in
  `skills/merge-pipeline/lib/release-anchor.sh` emptied `$PATH`, so every
  subsequent command in the fence resolved to nothing. Renamed across the
  shipped surfaces (`commands/simplify.md`, `skills/brainstorm/SKILL.md`,
  `skills/orchestrator/SKILL.md`, `skills/subagent-driven-dev/SKILL.md`,
  `skills/merge-pipeline/lib/release-anchor.sh`).

- **`hooks/inject-brainstorm-answers` had a live instance the guard could not
  see** (#392). Its `is_safe_path()` opened `local root="$1" path="$2"`. Not a
  live break — both wirings reach it under bash (`run-hook.cmd`'s Unix arm is
  `exec bash`, and `hooks-cursor.json` uses the shebang) — but verified
  counterfactually: the pre-rename body accepts a legitimate path under bash and
  refuses it under zsh.

### Changed

- **The cross-platform shell guard now detects bare tied-parameter declarations,
  and its corpus reaches the files that carry them** (#390, #392). The corpus
  filtered on `-name '*.sh' -o -name '*.md'`, which silently skipped every
  extension-less file — and all four shipped hooks plus `lib/rl-curl` have no
  extension, so `hooks/` had been listed in that corpus since it was written and
  never once read. The predicate is now "names it like a shell file, OR says it
  is one", matched on the *basename* (repo worktree paths contain dots, so a
  full-path `*.*` test skips nearly everything). The corpus also widened from
  `plugins/**` to `plugins/** + tests/ + tools/`.

  Deliberately-broken fixtures are exempted by a per-line
  `# zsh-tied-fixture: <reason>` marker rather than a path exclusion, with two
  honesty rows: a marker must sit on a line the matcher really catches, so it
  cannot decorate an innocent line or neutralise a region; and the marked-line
  inventory is pinned per file, so adding an exemption is a reviewable diff and a
  count that *drops* also reds — catching a fixture someone "consistency-fixed".

## [0.44.0] — 2026-08-07

### Added

- **The Phase 3 CI engine, shipped but not yet wired** (#383, half one).
  `045743b` (#382) deleted the codex backend, which was the only transport that
  could run `/uberdev:review-pr` Phase 3's five `review_pr.ci.*` routed children —
  `lib/dispatch.sh` has no workflow provider arm for them by construction. A red
  CI check therefore halts loudly at 6c.3 CLASSIFY with
  `subreason=ci_transport_unsupported`.

  This release lands the **engine** for the replacement: `lib/code_fixer_contract.py`
  gains the CI producer (`prepare-ci-authority`, `bind-workflow-ci-launch`), its own
  capture verb (`capture-ci-terminal`, `read-ci-authority-member`) and the judges
  (`validate-ci-classification`, `validate-ci-mutation-outcome`,
  `validate-ci-persistence-result`); `skills/review-fleet/workflow.js` gains the four
  CI stages (`ci-classify`, `ci-fix`, `ci-conflicts`, `ci-defer`); and
  `lib/review-fleet-args.sh` gains the CI binders and the on-disk counter/pointer
  state the fences will read.

  `capture-bound-child` was **not** widened. It refuses the fixer edges on purpose,
  because a fixer child owes a disposition and an applied-content artifact; the CI
  edges owe the same, so they got their own capture verb rather than a silent
  loosening of an existing one.

  **`/uberdev:review-pr` behaviour is unchanged in this release.** No command file
  emits the new stages yet — Phase 3 still halts loudly on red CI exactly as before,
  and `--no-ci-fix` remains the supported mode. The `commands/review-pr.md` fence
  wiring is deferred to half two, gated on a fence-execution harness: three review
  rounds found four arm-killing blockers in that wiring that a green 290-assertion
  suite could not see, because every test in the repo asserts on fence *text* and
  none executes a fence.

  `agents/ci-rebase-handler.md` is demoted from pusher to preparer — `git push` in
  any form is on its denylist, and the `--force-with-lease=<branch>:<sha>
  --force-if-includes` pair is captured and consumed by the **controller**. An agent
  choosing the SHA that git compares against is precisely the hole the demotion
  closes.

### Fixed

- **Three zsh parameter hazards that kill live `/uberdev:review-pr` fences** (found
  while reviewing #383; all pre-existing on `main`).

  `local status=` is **fatal** under zsh: `status` is a read-only special parameter,
  and the assignment terminates the whole fence rather than just the function. Live
  at three sites in `commands/review-pr.md` and three in
  `skills/post-impl-review/SKILL.md`, all on the **non-CI** path — so this broke
  `/review-pr` for every PR, not only red-CI ones. `local path=` is the softer half
  of the same family: zsh ties lowercase `path` to `$PATH`, so the assignment
  destroys command lookup for the rest of the call frame and the next `jq` or
  `python3` dies "command not found". All renamed to `child_status` / `record_path`.

  An unbraced `"$publish_sha:refs/heads/$live_branch"` parses `:r` as zsh's
  remove-extension **modifier**, eating the colon: the refspec silently became
  `<sha>efs/heads/<branch>` and the trust-anchor `git push` died with "src refspec
  does not match any". Verify with `zsh -c 'V=abc; print "$V:refs/x"'`.

  `tests/crossplatform-shell-wrappers.test.sh` gains a repo-wide guard for both
  classes. Its corpus was `lib/**/*.sh` only — disjoint from `commands/` and
  `skills/`, where every live instance actually was. That is the same
  guard-cannot-reach-the-drift shape #370/#371 addressed, one level up.

- **`uberdev_command_workspace_prepare` arity is now guarded**
  (`tests/command-workspace.test.sh`). The function hard-requires six arguments and
  returns 2 with an error otherwise; nothing asserted that its callers pass them, so
  a zero-argument call would abort a fence on its own preamble with every downstream
  test still green.

## [0.43.0] — 2026-08-07

### Fixed

- **A child worktree no longer outlives a wrapper that exits before the dispatch
  library loads** (#384). Both surviving wrappers open with
  `. "$DISPATCH_LIB" || exit 126`. At that instant the child worktree and its
  branch already exist — `git worktree add` runs before the wrapper is launched —
  but the teardown does not: `_uberdev_dispatch_cleanup_child_worktree` and every
  preservation guard it depends on are defined *inside the file that just failed
  to load*. So the worktree and branch survived the exit. This was the last known
  way an isolated child worktree could outlive its child; #382 closed the other
  eight.

  The fix refuses **before anything exists to leak**: the dispatcher now probes
  that the child can source the library and reach the teardown symbol, and skips
  `git worktree add` entirely if it cannot. Crucially the probe runs under the
  *child's* interpreter, resolved the way `os.execvp("bash", …)` resolves it — a
  PATH search that ignores shell functions and aliases — rather than re-using the
  dispatcher's already-loaded copy, which would prove nothing about the child and
  would be vacuously green (the load guard short-circuits on
  `_UBERDEV_DISPATCH_LOADED`). A `bash` shell function in the dispatcher no longer
  refuses every dispatch; an empty PATH still does.

  Deliberately **not** done: a guardless inline `git worktree remove --force`
  (running a guardless removal precisely when the guard code is unavailable
  inverts the safety property), a duplicated minimal teardown (drift risk), and a
  reaper daemon. The probe is wall-clock bounded with its stdin closed, so a
  library that stalls at source time cannot hang the dispatcher or a `/turbo`
  fanout.

  A residual TOCTOU window remains — the library can be made unreadable *between*
  the probe and the child's own source — and is **reported, not papered over**:
  both wrapper preambles still name the worktree and branch on stderr, the two
  refusal wordings distinguish "cannot load" from "loaded but does not define",
  and the reason now reaches `DISPATCH_LOG` so a `/turbo` fanout no longer shows
  `(no output captured)`. The three other `exit 126` paths in each wrapper, which
  sit in the same post-worktree/pre-source window, report before exiting too.
  `tests/dispatch-child-worktree-teardown.test.sh` covers all of it against real
  worktrees and branches, including a mutation guard that reds if the probe ever
  stops using the child's interpreter.

- **Isolated child worktrees are no longer leaked by the `background` and
  `wezterm` backends** (#381). Both arms created a dispatcher-owned worktree
  unconditionally (`lib/dispatch.sh`) and never removed it; the only teardown in
  the tree lived inside the codex arm's receipt transaction and was unreachable
  from either. A routed child — `workspace_mode` defaults to `isolated`, and
  `CHILD_OWNED` is set purely on `agent_id`, with `background`/`wezterm` both
  admitted by `_uberdev_child_backend_cancellation_supported` — therefore left a
  worktree **and** its branch behind permanently, once per dispatch.

  A backend-neutral `_uberdev_dispatch_cleanup_child_worktree` now removes the
  worktree and its branch when a child-owned isolated dispatch terminalizes, on
  both surviving detached backends. It keeps the codex transaction's preservation
  guards (registry classification, symlink/ownership validation, clean tree,
  unmoved HEAD): work is never force-deleted, and a teardown that cannot safely
  run is **reported** — stderr on the child log, provider exit 74, `failed`
  status — never swallowed into a `completed`. A top-level `/solve` worktree
  (`CHILD_OWNED=0`) is untouched: that one is the deliverable workspace.
  `tests/dispatch-child-worktree-teardown.test.sh` observes a real worktree and
  branch disappearing from a scratch repository.

  **The SETUP/LAUNCH door is closed too.** The teardown above covers a child
  that started and then finished. Every dispatcher-side failure *between* a
  successful `git worktree add` and a running child had no teardown at all, on
  either backend — `prompt_read`, `python_launcher` and `pid_target_unsafe` on
  `background`; `worktree_path`, `native_path`, `prompt_read`, `python_launcher`
  and a failed `wezterm cli spawn` on `wezterm`. A mux that is not up is
  routine, so that last one was the most-travelled of them. Because the leaked
  path derives purely from `ISSUE_NUM`, each leak also **blocked the next
  dispatch of the same issue** rather than merely accumulating. A new
  `_uberdev_dispatch_fail_after_worktree` now runs the same guarded transaction
  (terminal `setup_failed`) at each of those sites; a teardown that cannot
  safely run is reported on stderr, emits a new `dispatch_cleanup_failed` audit
  naming the worktree and branch, and returns **74** instead of the plain setup
  rc. The `dispatch` phase on `background` is deliberately excluded — the
  wrapper is already launched there and owns its own teardown.

  **The wezterm pane wrapper now arms an `EXIT` trap**, not only
  `HUP INT TERM`. Its `write_status running null || exit 126` — and every other
  bare `exit` before the finalizer — previously terminated the pane with the
  worktree already on disk and nothing to remove it, an asymmetry with the
  background wrapper, which has armed `EXIT` before the same call all along.
  The one window that stays uncovered is the `. "$DISPATCH_LIB"` source itself:
  the preservation guards live in that file, so before it loads there is
  nothing safe to call. Both wrappers now **name the worktree on stderr** there
  rather than force-removing it guardless or exiting silently.

### Removed

- **BREAKING — the `claude-bg` dispatch backend is deleted** (#381, RFC 0015 §7
  amendment 2026-08-05). `--backend=claude-bg` is no longer a deprecation
  warning: it is an **enum error** (`lib/solve-launcher.sh`,
  `error: --backend='claude-bg' not in {auto,workflow,wezterm,background}`).
  `_uberdev_dispatch_claude_bg` is gone, and with it five surfaces that each had
  exactly one consumer: the `claude-bootstrap` long-poll + ownerless-generation
  reclaim protocol in `lib/dispatch.sh`'s git-metadata mutex; `BG_PROMPT_MODE`;
  the `_uberdev_agent_claude_probe` liveness classifier; the
  unattended-permissions preflight; and the `provider_probe_failed` /
  `provider_cancel_failed` watcher-error kinds. (`provider_cancel_unconfirmed`,
  the *reason* the retired kind used to carry, is still live — it is now hosted
  under `terminal_finalize_failed`, and `tests/child-wait.test.sh` drives the
  waiter on it in that shape.) `tests/dispatch-claude-bg.test.sh` is deleted rather than
  retargeted, and the S4a/S4b/S4c deprecation guards in
  `tests/solve-fleet-workflow.test.sh` are **inverted into tombstones** — the
  surface must now be ABSENT. No check that still guards live code was relaxed.

  **Migration: `--backend=background`.** Same shape — detached, survives the
  parent, PID-tracked, status + result files — without the second agent surface
  that motivated RFC 0015. It is what the No-Workflow fallback sections name.

  **This lands ahead of the published removal target.** The v0.41.0 entry below
  (2026-07-30) said "Removal target v1.0.0"; that promise is **retracted**, and
  the entry now carries a pointer here. The evidence that moved it: `workflow`
  shipped and stayed shipped across `/solve`, `/turbo`, `/goal`, and then
  `/review-pr` and `/simplify` — the last two workflows that structurally
  required a detached transport. With those resolving `workflow`, `auto` had
  already been forbidden from reaching `claude-bg`, so it was the transport that
  nothing selected and nothing required. Deleting it five days early is a
  breaking change taken deliberately, on that evidence, and it is the reason
  this release is called out here rather than only in the RFC.

- **BREAKING — adaptive per-rank model routing is retired as unenforceable**
  (#381, RFC 0013 §0 amendment 2026-08-05). With the `codex` backend gone,
  UberDev no longer owns any provider invocation: `workflow`, `wezterm` and
  `background` children all inherit the ambient model and reasoning effort, so a
  resolved (model, reasoning_effort) pair was a value the resolver could compute
  and then never apply. Rather than ship a routing engine no dispatch path can
  enter, it is deleted.

  `lib/model_routing.py` loses `resolve_route`, `fallback_route`,
  `validate_catalog`, the whole precedence/provenance/shadow/fallback machinery
  and the `resolve` / `fallback` / `validate-catalog` JSON CLI — 1732 lines down
  to ~350, library-only. `policy/model-routing-v1.json` loses the per-route
  `codex` provider block (a route row is now a capability **rank** and nothing
  else) and `plan-writer.tier_routes`, which only the concrete resolver read.
  `lib/agent-dispatch.sh` loses the router import, the policy load, the
  synthesised catalog and the injectable `UBERDEV_MODEL_CATALOG_FILE` seam.

  **The refusal is deliberate, not a downgrade to silence.** A request naming
  `explicit_route`, `explicit_model`, `explicit_effort`, a non-`default` service
  tier, `routing_mode: adaptive`, a forced parent, or any project/environment
  role/workflow override fails with the typed code `route_unenforceable`. A user
  who asks for Sol-Ultra is told it cannot be honoured instead of believing it
  was applied.

  **Project `model_routing:` validation is kept and still works.** It blocked on
  one thing: `lib/config-read.sh` built its accepted reasoning-effort set by
  scraping the deleted provider blocks. That vocabulary is now **declared** as a
  top-level `reasoning_efforts` key in the policy. The accepted tokens are
  byte-identical to before (`low`, `medium`, `high`, `max`, `ultra`) — only the
  source moved from derived to declared — so a typo'd effort or unknown role is
  still caught at config-read time.

  **Still live:** `load_policy`, `_validate_policy` and `classify_minimum_route`
  (the logical floor classifier, reached from `lib/config-read.sh`), plus the
  route/alias vocabulary `lib/solve_triage.py` validates `--route=` against.

  **BREAKING for custom policies:** a `UBERDEV_ROUTING_POLICY_FILE` written
  against the old schema now **fails closed** in `_validate_policy`.
  `policy_version` is bumped `2026-07-09` → `2026-08-05`.

  **Coverage cost, stated rather than absorbed:** `tests/model-routing.test.sh`
  drops from ~562 checks to 314. Lost with the engine: concrete pair selection
  per route/alias/tier and every field-source provenance label, `forced` /
  `forced-parent` inheritance and `route_conflict`, `route_below_risk_floor`,
  shadow mode and its `adaptive_proposal`, `ignored_sources` / `ignored_fields`
  precedence, sandbox selection from override entries, catalog availability
  fallback and its `fallback_chain`, and CLI byte-determinism. Each retargeted
  file names its own loss inline; `tests/fixtures/model-routing/catalog-*.json`
  and `precedence-cases.json` are deleted.

- **BREAKING — the `codex` dispatch backend is deleted** (#381).
  `--backend=codex` is now an enum error, `auto` has exactly one answer
  (`workflow`) on every host and OS class, and the two Codex-environment escapes
  that used to pre-empt the resolver (`CODEX_HOME` set; `claude` absent with
  `codex` present) are gone with no replacement. Deleted with it:
  `_uberdev_dispatch_codex` and its whole worktree-receipt transaction family in
  `lib/dispatch.sh`, `lib/worktree_receipts.py`, and the `codex` arms of the
  cancellation path, the provider boundary, and the run-artifact naming switch.
  `--effort=ultra` was an exact Codex route field, so it is now refused
  unconditionally rather than "unless the backend is codex".

  **BREAKING consequence — `/review-pr` Phase 3 CI classification and the CI
  fixers are UNAVAILABLE.** `review_pr.ci.*` are routed children and
  `lib/dispatch.sh` has no `workflow` provider arm for them (RFC 0012 §3.1, "Not
  built in P2"); the `codex` backend was the only arm that could run them, and
  the two remaining detached backends are refused by
  `uberdev_dispatch_preflight_backend` because neither publishes a governed
  child result artifact. A **green** CI probe still completes normally and
  reaches the trust anchor; a **red** one halts loudly at 6c.3 CLASSIFY with
  `subreason=ci_transport_unsupported`. **`--no-ci-fix` is the supported mode**
  until Phase 3 is rebuilt Workflow-natively. This is a capability the release
  no longer has, not a configuration an operator can fix — see
  `commands/review-pr.md` §6c.

  **`wezterm|background` are still refused for `/review-pr` and `/simplify`.**
  Only the `codex) ;;` arm was removed from that preflight case; the live
  refusal for the two remaining selectable detached transports stays, so
  `/review-pr --backend=background` is still rejected rather than silently
  admitted.

  **Coverage cost, stated rather than absorbed:** `tests/worktree-receipts.test.sh`
  was the only native-Windows runtime coverage for dispatcher-owned worktree
  teardown. Its successor,
  `tests/dispatch-child-worktree-teardown.test.sh`, is declared Unix-only, so the
  `ci-wiring` W7 invariant now requires that teardown on Linux and macOS only.
  The teardown *code* remains portable; the *fixture* is not.

  **Coverage restored rather than lost:** that same deletion also removed the
  only direct coverage of `lib/atomic_move.py`, which is **not** codex-scoped —
  it still ships, is still required by `tools/prkit/manifest.txt`, and is loaded
  by `lib/code_fixer_contract.py` and `lib/planning_research_output.py` for every
  artifact publication. The ~80 atomic-move-only lines are ported into a new
  `tests/atomic-move.test.sh` (11 assertions, wired into the Linux, Windows and
  macOS jobs), covering no-overwrite semantics and non-mutation on collision,
  `_native_call` errno normalization, cross-parent refusal,
  `require_atomic_rename_noreplace_support()` failing closed, and the
  `_windows_move_noreplace` / `_mapped_windows_error` family.

- **BREAKING — the Codex CLI distribution is retired** (#381). The entire `codex/`
  tree (225 files: the `uberdev-codex` native plugin, the 44 `codex/agents/*.toml`
  subagents, `install-codex.sh`, and `codex/tools/`) is deleted, along with
  `.agents/plugins/marketplace.json` and
  `skills/using-uberdev/references/codex-tools.md`. It was generated output —
  `codex/README.md` documented six idempotent regeneration commands and the `lib`
  trees were byte-identical to `plugins/uberdev/lib` — so nothing unique was lost,
  but UberDev no longer installs into the OpenAI Codex CLI at all.

  (This entry originally added "the `codex` DISPATCH BACKEND is unaffected". It
  no longer is — the next entry deletes it.)

  **Uninstalling an existing Codex install.** The deleted installer shipped a
  tested `--uninstall` mode that handles all of this correctly — the
  marker-gated skill walk, both primer files, and failure reporting. Prefer it:

  ```bash
  git show 24fe6b1^:codex/install-codex.sh > /tmp/install-codex.sh
  bash /tmp/install-codex.sh --uninstall
  ```

  (`24fe6b1` is the deletion commit — `git log --diff-filter=D -1 --
  codex/install-codex.sh` finds it in any clone — and `^` is the last tree that
  still had the file.)

  By hand, these are the **four** artifact families the installer wrote — the
  earlier edition of this entry said three and omitted the first, which is the
  part Codex actually loads:

  ```bash
  # 1. the managed skills, MARKER-GATED -- other tools install into this
  #    directory, so never `rm -rf ~/.agents/skills/*`
  for d in ~/.agents/skills/*/; do
    [ -f "$d/.uberdev-codex-managed" ] && rm -rf "$d"
  done
  # 2. the subagent definitions
  rm -f ~/.codex/agents/uberdev-*.toml
  # 3. the plugin tree
  rm -rf ~/.codex/plugins/uberdev-codex
  # 4. the primer block, in BOTH files -- the installer writes whichever exists
  #    and a user may create or remove the override between install and uninstall
  # then edit ~/.codex/AGENTS.md and ~/.codex/AGENTS.override.md and delete the
  # uberdev-codex-primer block from each
  ```

  Removing the runtime while leaving the ~39 managed skills live in the session
  is the worst half-state available, which is why the skill walk is step 1.

  Also run `codex plugin marketplace remove prkit` / `uberdev` if you added the
  Codex-native marketplace entry.

### Changed

- `lib/bump-version.sh` and `skills/merge-pipeline/lib/release-anchor.sh` now own
  **six** version surfaces, not seven — `codex/uberdev-codex/.codex-plugin/plugin.json`
  is gone. `tests/merge.test.sh` M98.ssot still asserts the two lists agree.
- `tools/prkit/` no longer emits a Codex port: the `codex` stage,
  `manifest-codex.txt`, the four `templates/codex-*.tmpl` scaffolds and
  `verify.sh`'s `CODEX_REQUIRED` set are removed, and the generated repo's
  `ci.yml` drops its TOML step. RFC 0014 §14's "mandatory native Codex port"
  clause is **superseded** — see the dated note in that RFC.
- `tests/contract_markers.py` walks **one** tree. Mirror parity used to be
  structural (`SCAN_ROOTS`/`MIRROR_PAIR` + `expected_total = len(paths) * 2`);
  the guard is now "every marked site agrees *within* `plugins/uberdev/`" and the
  path-multiset ratchet is the only structural anti-vacuity device left. The
  module docstring states the weakening explicitly and records how to restore it.

## [0.42.9] — 2026-08-01

### Added

- **`# CONTRACT:` markers + one meta-test** (`tests/contract-markers.test.sh`,
  `tests/contract_markers.py`, RFC 0016) closing Half A of the contract-drift register (#370).
  Ten closed vocabularies — dispatch backends, agent liveness values, terminal run states and
  events, goal audit events, circuit-breaker reasons, park reasons, semaphore lease-acquire
  reasons, trust signals, risk signals — are declared once per site with a marker and compared by
  a single test across **both** the `plugins/uberdev/` and `codex/uberdev-codex/` trees, with
  per-site `-member` / `+member` deltas for sites that are deliberately a subset or superset.

  This is the class behind #360, #361 and #362: *one contract, N independent copies, and nothing
  comparing them*. Until now the only signal that two literals were coupled was a prose comment,
  and a comment is not a producer. Source changes are comment-only — no runtime behaviour changes.

  **110 sites — 55 declarations per tree, mirrored.** Among them: `run_manifest.py`'s liveness set,
  `solve-launcher.sh`'s three backend copies, `solve_triage.py`'s `parse_cli` whitelist (the copy
  #360 shipped stale), `dispatch.sh`'s supervision-capable subset, `child-dispatch.sh`'s
  status-file validator and merge-pipeline's failure-mode table — all now compared rather than
  merely adjacent.

  A companion scan reports unmarked lines carrying `N−1` of a contract's `N` members. It is a
  **discovery aid, not a proof**: its predicate cannot establish completeness, and RFC 0016 §2.6
  and §2.7 say so and list its blind spots. Registry completeness stays human-curated, ratcheted
  by path multiset in the same spirit as this repo's version-locks.

## [0.42.8] — 2026-07-31

### Fixed

- The `supervision-smoke-macos` job flaked on `review-pr-codex-six-child` roughly a third of the time (#365), reporting `post-impl-review evidence incomplete; aggregate suppressed` — a message **indistinguishable from a genuine missing ledger**, which trained everyone to re-run rather than read.
- The real mechanism was not the one first proposed: `child-dispatch.sh` returns rc 1 (not 124) when the settle budget expires while an **already-terminal** provider is still landing its lifecycle record or releasing its lease, so the status file keeps whatever the provider published for itself and the fixture cannot tell a starved budget from a real shortfall. Reproduced deterministically before changing anything.
- The fix records the supervisor's decision instead of inferring it from downstream state: the settle boundary now names why it gave up (`lifecycle_record_pending` / `lease_release_pending`), and `post_review_wait_all` emits a per-child failure line on a path that was previously **100% silent**.
- The `incomplete-roster` prose overstated what it could prove: a truncation aligned to a line boundary is byte-indistinguishable from a short roster. It is now documented as a row-count statement, with the corroborating evidence that separates a supervision shortfall from rows lost after write.
- The settle budget is overridable (`${SIX_CHILD_PROVIDER_SETTLE_BUDGET:-60}`), matching the sibling tunables, so the starved-budget control is reproducible without editing the fixture.

Verified on both race outcomes — rc 1 with `state=completed`, and rc 124 with `state=timed_out` — each now naming its class.

## [0.42.7] — 2026-07-31

### Fixed

- Closed the `pipefail` + early-exit-reader EPIPE race repo-wide (#313). Under `set -o pipefail` a reader that exits at its first match (`grep -q`, `grep -m`, `head`, `read`) leaves the writer taking EPIPE, and pipefail adopts the writer's non-zero status — false-failing an assertion whose pattern **matched**. Measured, not assumed: 20/20 false non-zero through a pipe versus 0/20 through a herestring, for each reader in the set.
- One site was **inverting** its meaning rather than merely flaking: `grep -q "Traceback" && fail …` under `set -e`. An EPIPE after the match short-circuited the `&&`, so a genuinely leaked Python traceback was reported **PASS**.

### Added

- `tests/epipe-guard.test.sh`, built around the risk rather than the syntax that happened to be converted: logical-line joining (so a pipeline split across physical lines cannot hide), an **unconstrained** writer side, a measured early-exit reader set, and a scan over every tracked `*.sh` via `git ls-files` — 100 `pipefail`-setting files, not just `tests/`. That widened scope caught two production instances (`lib/bump-version.sh`, `codex/install-codex.sh`).
- The oracle is 26 independent cases — 15 must-flag shapes and 11 must-not-flag boundary cases — so it can fail per shape instead of certifying the detector as a whole. Removing a reader from the set reds exactly four named cases and nothing else.
- A vacuous-green path **inside the guard** was found and closed while building it: a non-zero `awk` exit produced empty output, which read as "clean". A detector error is now a named failure per file.

The same guard run against the previous `main` flags **218** sites; against this tree, **0**.

## [0.42.6] — 2026-07-31

### Fixed

- **Two more live instances of the v0.42.3 defect, both of which abort an entire `/solve`, `/turbo` or `/ubergoal` batch.** `triage_decision.files` and `triage_decision.components` are validated by the routing-context schema, but their producers scrape free-form issue prose and never checked the shape they had to satisfy. Reproduced: a markdown code span `` `-foo.sh` `` emits a leading dash; a pasted stack-trace path exceeds the 255-char cap; a non-ASCII filename survives `casefold()`; a 141-character module word exceeds the 128-char component cap; `İstanbul` casefolds to a two-codepoint `i̇stanbul`. Each makes `uberdev_agent_context_create` fail with `route_context_create_failed` and refuses the **whole batch** — "no claims written; no agents dispatched" — so innocent sibling issues die as collateral with an error naming neither the field nor the token.
- The `components` field has **two** producers unioned, and v0.42.3 filtered only one of them. `named_modules()` fed the same validated field unfiltered, so the field looked guarded while still diverging. The filter now sits at the **union**, giving the field exactly one choke point however many producers ever feed it.

### Tests

- The v0.42.3 guard property-checked a single producer and was therefore structurally blind to the second — it certified a field that was still broken. The check now runs at `classify()`, the only vantage point that sees every path into both fields, over hostile bodies covering all five reproductions above.
- The drift guard now scrapes the validator literal **per field name** for `files` as well as `components`, so a rename makes it fail rather than silently pass.
- Added a non-vacuity assertion: an ordinary body must still yield files and components. A filter that dropped everything would have satisfied every other assertion while destroying triage.
- Mutation-verified four ways, including removing the second producer entirely — the over-narrow failure the new assertion exists to catch.

_Found by a repo-wide sweep for the "one contract, two independent copies, nothing comparing them" class, after four instances of it shipped through green CI in a single day._

## [0.42.5] — 2026-07-31

### Fixed

- **`/ubergoal` auto-merged PRs with no version bump** (#364). RFC 0015 correctly forbids fleet solvers from bumping — parallel solvers all reaching for the same `vN+1` is a collision class this repo has hit before — but nothing downstream then added it, and `_uberdev_goal_rebase_collision_chain` only *renumbers* a bump that already exists. It failed silently: the version-lock tests assert the surfaces are *consistent*, not that they *advanced*, so an unbumped merge left everything consistently at the old version and CI stayed green while the marketplace never served the update. The goal merge lane now bumps immediately before landing — the one place that is already strictly serialized, so consecutive versions fall out naturally.

### Added

- `skills/merge-pipeline/lib/release-anchor.sh` and `/merge` PATH_2 sub-condition (a.5). Placing the bump at the landing lane puts a `chore(release):` commit above the review trailer, and PATH_2 reads the trailer from the most-recent commit — so without this the trust gate would fail and the loop would never converge, trading a silent wrong-merge for a silent never-merge. The helper resolves a trust head that tolerates a top commit **only** when it is provably inert with respect to reviewed code: exactly one parent, a non-chained depth of one, an exact `chore(release): vX.Y.Z` subject, a non-empty diff confined to the seven version surfaces, a manifest version strictly advancing to the subject's version, an insertion-only CHANGELOG section, and — for every other surface — removed and added line **sequences** that are byte-identical once SemVer tokens are normalised. Two of the seven surfaces are executable test files, which is exactly why a path allow-list is not sufficient and the comparison is order-sensitive. Any unproven condition, any helper error and any non-zero exit resolve the trust head back to the PR head, i.e. the pre-#364 behaviour.
- The bump defers one watch pass after pushing, and a withholding-only CI-settle probe gates the dispatch, so the restarted checks cannot make `/merge` fail on a pending rollup.

### Tests

- `tests/goal-version-bump.test.sh` (115 assertions), wired into both CI jobs: no-op on an already-bumped PR, seven surfaces advancing on an unbumped one, `feat:`/`fix:`/breaking resolution now read from the PR's **commits** rather than its title alone, **consecutive** versions for two PRs landing in one cycle, fail-closed when the bump fails, and an ordering assert that runs the real watch-lane region rather than a copy.
- Two self-found fail-open holes closed: an unreadable release-diff size defaulted to *under* the bound, and the merge-dispatch chain branched on a literal `rc 1` so an unknown status could reach `/merge`.

## [0.42.4] — 2026-07-31

### Fixed

- `codex/uberdev-codex/skills/merge-pipeline/lib/discover.sh` shipped with **zero** test coverage — no test sourced it, executed it, or byte-compared it, so replacing the entire 1,070-line file with `# gutted` was green across the whole suite. Any drift in the Codex mirror shipped silently, including a broken `../../..` runtime-root hop that makes `_uberdev_review_verdict_python` fail closed and leaves every Codex-backend `/merge` and `/ubergoal` permanently INDETERMINATE with no signal.

### Tests

- Three asserts added to `tests/dispatch-codex.test.sh` — the only candidate wired into **both** CI jobs (`merge-discovery-resilience` and `codex-port` are on the Windows skip-list, and a new `tests/*.test.sh` would drag in the `ci-wiring` W1/W2/W4 lockstep for no extra signal):
  - **byte-lock**, joining the existing mirror `cmp` loop, deliberately with no `[ -r ]` short-circuit so that *deleting* the mirror stays red rather than passing vacuously;
  - **transform-envelope guard**, so that if `discover.sh` ever gains a porter-rewritten token the legitimate divergence reports its real cause instead of becoming a mystery red;
  - **behavioural runtime-root assert**, which sources the shipped Codex copy from `/` and checks the `../../..` hop lands on the Codex plugin root — `cmp` is depth-blind and cannot see this.
- Non-vacuity is proven by a 9-case mutation matrix run against the real extracted bytes. The load-bearing row is **V4b**: both copies move to the wrong depth together, so the byte-lock stays green and only the behavioural assert reds — signal `cmp` structurally cannot carry.

_Solved end-to-end by the Workflow-native `/ubergoal` fleet (RFC 0015): claim → nested solve-fleet → research fan-out → spec → review → plan → solver → PR, with no detached session anywhere._

## [0.42.3] — 2026-07-31

### Fixed

- **Every open issue in this repository was undispatchable.** `component_tokens()` derived a component by stripping only the *last* extension, so `foo.test.sh` produced the token `foo.test` — and the routing-context schema in `lib/agent-dispatch.sh` validates every component against `[a-z0-9][a-z0-9_-]{0,127}`, which forbids the dot. `uberdev_agent_context_create` therefore failed with `route_context_create_failed`, and `/solve`, `/turbo` and `/ubergoal` all **refused the issue outright** — no PR, no retry, no dispatch. Any issue body naming a `*.test.sh`, `*.test.py`, `*.d.ts` or `*.tar.gz` was affected; all eight open issues name a `*.test.sh`.
- Splitting on the *first* dot also fixes a quieter miscount: `foo.sh` and `foo.test.sh` are one component, not two, so the multi-component tier heuristic no longer double-counts a module and its own test file.
- Leading punctuation is trimmed (`_workflow_harness.js` → `workflow_harness`), and a name that cannot yield a conforming token is dropped rather than emitted — losing one coarse component from a heuristic count is strictly better than refusing to work the issue.

### Tests

- Added `tests/component-token-schema.py`, run from `tests/solve-triage.test.sh`: conformance for the exact shapes that broke, a property check that **every** emitted token satisfies the schema, the `foo.sh`/`foo.test.sh` collapse, and a **drift guard** asserting the regex literal in `solve_triage.py` is byte-identical to the one the context schema enforces.
- Both halves are mutation-verified: restoring `rsplit(".", 1)` reds the conformance cases, and editing either regex alone reds the drift guard. Two independent copies of one contract is how this shipped — and how the `--backend` enum bug shipped before it.

## [0.42.2] — 2026-07-31

### Fixed

- **Every Workflow-native pipeline silently did nothing.** The runtime hands `args` to a `scriptPath` workflow as a JSON **string**, but all five shipped `workflow.js` scripts opened with `const A = (args && typeof args === "object") ? args : {}` — so the envelope fell through to `{}` and `/ubergoal`, the `/solve`+`/turbo` solver fleet, `/uberscan`, `/ubersimplify`, `/testers` and `/uberthink` all returned **success having dispatched nothing**. A `/ubergoal` run finished in 5 ms with zero agents and an empty journal. Every script now carries a shared normaliser that accepts a string or an object and treats unparseable input as absent.

### Tests

- `tests/_workflow_harness.js` was the reason this survived nine releases: it passed `args` as a parsed **object**, so the suite stayed green while production was dead. It now runs every script under **both** shapes.
- Running both shapes is not sufficient on its own, and that was verified rather than assumed: reverting a script to the object-only guard still **passed** the both-shapes run, because a silent no-op raises no error. So `validate` also requires proof of consumption — `GENERIC_ARGS.run_id` is a sentinel that must appear in the script's observable output. Mutation-verified against all five scripts: restoring the old guard reds each one.
- Added `T2/T3.c1b`, a control fixture that guards with `typeof args === "object"` and must be **rejected**, so the exact shipped bug cannot return.

### Documentation

- RFC 0015 gains §6b, the args-shape contract: what the runtime actually passes, why a silent no-op outlived nine releases, and the three enforcement points.

## [0.42.1] — 2026-07-31

### Fixed

- **`/goal` could not dispatch at all.** `lib/solve_triage.py`'s `--backend=` whitelist was never updated when RFC 0015 added `workflow` to `_UBERDEV_DISPATCH_BACKEND_ENUM`, so an explicit `--backend=workflow` failed `routing_cli_invalid`. That gate is the *first* thing `lib/solve-launcher.sh` runs (`:87`), and `/goal`'s Workflow driver passes exactly that flag — so every `/goal` cycle aborted at dispatch. The default `auto` path was unaffected (`auto` is whitelisted and resolves to `workflow` later, inside `lib/dispatch.sh`), which is why this shipped unnoticed.

### Tests

- `tests/solve-routing.test.sh` now pins `--backend=workflow` in both token orders **and** iterates `_UBERDEV_DISPATCH_BACKEND_ENUM` from `lib/dispatch.sh`, asserting every backend it offers survives `parse-cli`. The two lists can no longer drift silently — which is the actual defect class, not the one missing name.

## [0.42.0] — 2026-07-31

### Changed

- **`/goal` is now a Workflow driver, completing RFC 0015.** `skills/goal-pipeline/SKILL.md` shrinks from 1931 lines to ~155 (preflight, the on-disk script guard, the Workflow mandate, a summary fence and the fallback section); the phase bodies move to `lib/goal-phase0.sh`, `lib/goal-phase1.sh`, `lib/goal-watch.sh` and `lib/goal-phase3.sh`, which the Skill loader never renders — closing the `$ARGUMENTS` positional-substitution hazard that has corrupted awk column refs in this file before.
- The cycle loop lives in `skills/goal-pipeline/workflow.js`, holding the queue, cycle counter and fingerprints in JavaScript variables spanning the whole run. That is what structurally retires the fence-death false-converge and rollover-wipe classes, rather than patching them again. Each cycle makes **exactly one** nested `workflow()` call into the solve-fleet; the fleet still fans out per issue internally.
- **`claude-bg` is now off every default path.** `uberdev_dispatch_demote_workflow_to_detached` — the interim that kept `/goal` on a detached backend — is deleted along with its call site, and the tests that pinned it now assert it cannot come back, in the Codex mirror as well.

### Fixed

- Two blockers the migration itself exposed: the watch loop's own `/merge` and `/review-pr` children would have hit the workflow-backend refusal on **every poll**, so `/goal` could never have merged — they now resolve an explicit, scoped child transport; and the 150-minute detached-solver liveness budget became dead weight against an awaited fleet, so a no-PR issue would have held the watch budget for hours.
- The fleet envelope is cross-checked against the issue set `/goal` actually claimed before any solver is armed, and refuses on mismatch. The launcher runs with `--force`, whose documented purpose is bypassing the claim guard, so without this check a mismatch could have worked an unclaimed issue.
- The post-Workflow summary fence was dead code, gated on a variable that could never be set in that shell; the `bash >= 4` execution contract was documented but never propagated to the relay-run phase scripts; and the watch relay could exceed the Bash tool's default timeout, where the `0/42/1` exit contract cannot survive.

### Tests

- New `tests/goal-workflow.test.sh` (112 assertions): convergence, the watch drain and tick breakers, max-cycles, repeated-fingerprint non-convergence, a non-empty rollover blocking convergence, candidates surviving across cycles, a null child, a budget throw still reaching finalize, exactly one nested call per cycle, and no timers anywhere in the script.
- `tests/goal.test.sh` re-anchored honestly (593 assertions): assertions about behaviour that **moved** now target the new file; the three cases where behaviour was genuinely **replaced** were rewritten to pin the replacement, with a comment saying so.
- Fixed 7 tautological assertions: a stray `--` was consumed as the pattern argument, so they matched any file containing a double dash. Correcting that exposed a second layer — the bare flag tokens also appear in prompt prose — so they now anchor on the armed command line. Every new assertion is mutation-verified.

## [0.41.7] — 2026-07-30

### Fixed

- `/goal`'s verdict channel collapsed six distinct outcomes into one empty result, so **indeterminate discovery and detected tamper both read as "never reviewed"**. Each outcome is now recorded on a run-scoped sidecar (found / absent / indeterminate / tamper / projection-failed / cleanup-failed / selector-unavailable); tamper announces itself loudly, and a proven verdict still publishes when only cleanup fails.
- `/goal` bounded the new anomaly states with their own counter and red-holds with `verdict_indeterminate` / `verdict_tamper_detected` instead of the misleading `dispatch_cap_exhausted`.
- The legacy verdict path read `.sha` with no shape check; it is now validated as a 40-hex object name with a zsh-safe test, and a malformed anchor warns loudly (it is still compared — skipping the binding would let an unbound colour through on a command that auto-merges on green).
- Resolving a helper's source directory fell back to the caller's cwd, so a planted file in that cwd could be sourced. The fallback is removed.
- `/goal` refetched the open-PR list per issue; each pass now takes one snapshot and resolves every issue from it, sharing one ranking program with the live finder. A pass that made progress skips the fixed 60-second sleep — bounded to five consecutive fast passes, because the unbounded form turns a rate-limit warning into a self-inflicted 403 storm.
- **RFC 0015 follow-through:** `workflow` was missing from all four backend sites in `lib/goal-state.sh`. The run-state sidecar allowlist silently *dropped* the value, after which the pid resolver defaulted to a detached backend and a Workflow run could be probed with `claude agents --json` and mis-reaped.

### Added

- `lib/goal-abort.sh` — releases every non-terminal `uberdev:active` claim for a run. Required now that fleet children do not survive their session: a closed window would otherwise strand those labels indefinitely.

### Tests

- New `tests/goal-verdict-receipt.test.sh` (45 cases): the closed-receipt colour matrix through the real locator, `missing` for all sixteen shape-gate clauses, every discovery classification, and forged-sidecar degradation — verified non-vacuous against the pre-change library.
- Sidecar round-trip under `env -i` with cleared environment (an environment-passing test would mask the re-export trap), a zsh mirror of the colour matrix, and lifted `abc123` fixtures to real 40-hex object names.

## [0.41.6] — 2026-07-30

### Fixed

- RFC prose named symbols that resolve nowhere. Two identifiers cited as live fan-out sites were retired by the scan-fleet and testers-pipeline Workflow migrations, and one `workflow.js` was labelled "as shipped" while no such file exists on disk. All now cite the shipped replacements, verified against the real call sites.
- Documentation that hand-enumerated the CI jobs was guarded in only one of the two files that do it, and the job-count assertion could not match the phrasing the docs actually used.

### Tests

- Replaced hand-maintained doc lists with **derived** guards: every identifier-shaped backticked token in RFC 0012 §1 must resolve in the tree, and every `skills/*/workflow.js` path the RFC names must exist if the line calls it shipped — so a new dead reference reds without anyone extending a list. Assertions now match word-bounded, so renaming a symbol no longer counts as resolved, and the trust-table guard slices data rows rather than grepping prose that names the emitter deliberately.

## [0.41.5] — 2026-07-30

### Added

- `/uberdev:status` — a read-only aggregator across the five run-state stores (solve claims, goal state, review reservations, the merge lock, and Workflow fleet runs). It reads and reports; it never mutates, never releases a claim and never breaks a lock.

### Fixed

- Under zsh, `local path=…` binds the **special `path` array tied to `$PATH`**, so `stat` resolved to command-not-found inside the mtime helper and `/status` inverted both of its safety-critical verdicts — reporting a live merge lock as stale and an in-flight review as finished, which would invite an operator to steal the lock and re-dispatch. Five locals renamed; the rule is recorded in the file's cross-shell notes.

### Tests

- The zsh coverage that would have caught this discarded its output and so could not fail on an output regression. Replaced with a bash-vs-zsh **rendered-byte diff** over both live and aged fixtures, normalising only elapsed times so a threshold divergence still reds, plus negative tests proving the shared-root ownership gate actually refuses a foreign-owned file. Every new assertion was mutation-proved.

## [0.41.4] — 2026-07-30

### Fixed

- `/merge` verdict discovery could report a verdict as **proven absent** — which reads as a passing gate — when its root-layout table simply disagreed with itself. The table restated one segment count three ways with nothing checking they agreed; it now carries one shape per root and derives the rest, asserted against a documented pin table and routed through the failure path so a mismatch can never exit with the code reserved for proven absence.
- A `/merge` scan aborted every root layout on the first `OSError`, so an unreadable directory could hide a good verdict under the canonical root. Errors now accumulate per root, every root is scanned, and the run fails once, naming root and errno.
- Artifact identities compared equal to a different type and to any bare 6-tuple, and the public constructor accepted unvalidated receipt JSON. Both are now frozen dataclasses with construction-time domain validation; the receipt wire format is unchanged.
- A mode-0400 verdict copy leaked per non-clean exit: the capture directory was removed with a swallowing `rmdir` that could never succeed, because the publisher had deliberately left a file inside it. Removal is now identity-guarded and a failure names the leaked absolute path instead of hiding it.
- The `/merge` auto-review cap was void — it lived in an associative array inside a bash fence, and fences share no shell state, so the array always read empty and re-dispatch was unbounded **while holding the merge lock**. The cap is now an atomic directory marker claimed before dispatch.
- The branch-protection probe mapped every non-zero exit to "skip". It now classifies on the HTTP status, and — after review found the first fix introduced a *new* fail-open — runs a local upstream-ref check first, so a `404` can no longer read a local-only branch as unprotected.
- An inherited `RUN_ID` was interpolated into the lock record unvalidated; a quote or newline broke the record and the holder check then warn-skipped, leaving the merge lock held.
- A FIFO at any artifact path hung the caller forever: `open()` for reading blocks until a writer appears, and the regularity check can only reject a node it has already opened — so `/merge` wedged while holding the lock. Opens are now non-blocking.

### Tests

- The Phase 1.4 trust gate is now extracted and **executed** against fixtures rather than only grepped, and an assertion that pinned the retired associative-array construct — passing off its own retirement comment — was re-anchored and mutation-proved.
- Added fixtures for a FIFO and a directory at the verdict path, the size boundary, divergent duplicate JSON keys, a root that is a regular file, and errno accumulation; converted 131 `echo | grep -q` sites to herestrings (the EPIPE-race class), fixing one that inverted an empty-input assertion in the process.

## [0.41.3] — 2026-07-30

### Fixed

- Converged four incompatible run-id contracts. `finish-branch` declared a widened format specifically to admit the `nohead` sentinel that `orchestrator` mints from `git rev-parse --short HEAD || echo nohead`; that id passed `finish-branch` and failed every canonical `[a-f0-9]` site, so `command-workspace.py` rejected it as invalid while `finish-branch` happily resolved the same run. The sentinel is now hex and both surfaces use the canonical regex, with tests locking the literals that previously had none.
- `finish-branch` enumerated exactly two secret-scan targets — the push diff and the composed PR body — and never the PR **title**, which it reads and ships to GitHub. The title now goes through the scanner.
- `secret-scan.sh` invoked `gitleaks` with no config, so a repository `.gitleaks.toml` allowlist was silently ignored and there was no escape hatch. The repo config is now honoured, with a line-level allowlist named in the abort message.
- `live-semaphore.sh` validated values with a pipeline that matches **per line** while the caller kept the whole string, so a newline-bearing value could pass validation at three poisonable sites. Each now goes through the file's existing safe-text primitive first.
- Hoisted ~32 duplicate 40-hex SHA patterns in `code_fixer_contract.py` to one compiled constant.

## [0.41.2] — 2026-07-30

### Fixed

- `/review-pr` Phase 3 dispatched the CI failure classifier and code fixer against CI that never failed. The monitor ran `timeout 1200 gh pr checks --watch` in ONE Bash fence, but the Bash tool caps at 600 s — so the harness killed the fence and returned a code that was neither `gh`'s success nor its documented "checks pending", which the next line mapped to "at least one check failed". Replaced with a bounded-pass loop that distinguishes a pass consuming its full budget (still pending) from one that returned early (genuinely red).
- The `sequential` fanout mode was a no-op: `/review-pr` exported its flag in one bash fence and `post-impl-review` read it in a later, separate fence, and Bash tool calls share no shell state. The cap is now passed as a Skill input.
- Abandoned `/review-pr` run reservations had no owner. The `EXIT` trap was replaced by a receipt redeemed only by the final publish fence, all four abandon sites sat inside the setup fence, and no reaper existed — so any mid-run abandonment stalled `/goal` for the full grace period. Added a reaper that runs immediately before reservation, on both the native-Windows and POSIX arms.
- A cleanup failure after publication masqueraded as a publication failure, so callers re-reviewed an already-published verdict. Marker retirement now has its own error path and exit code.
- Hardened five Python helpers that lacked a `spec is None` guard and ran `exec_module` outside their `try`; a `created = True` set after `os.fsync` that skipped rollback on an fsync error and orphaned the run directory; two blanket `except: pass` blocks; and a no-newline receipt that made the run id, receipt and marker directory compare equal so a base64 blob could be exported as the run id.
- Native Windows lost its reservation receipt and markers across a fresh shell, and the ignore tri-state/no-clobber matrix did not hold there.

### Tests

- Replaced a vacuous reaper oracle. Its assertions ran in an `if` condition, where bash suppresses `errexit` for the whole command — and that suppression is inherited by a subshell even when the subshell re-enables it, so `set -e` would not have fixed it either. Every assertion now routes through a helper that exits and names the failure, and both reviewer mutations were re-run to prove the oracle reds.
- Replaced a structural assertion that alternated on `link(`, which matched pre-existing `os.unlink(` lines so a plain truncating write would have passed, and added a non-empty guard before every awk-slice negative assertion (one was vacuous because its slice could be empty).

## [0.41.1] — 2026-07-30

### Changed

- Migrated `/uberthink` off the directive-emitter onto `skills/uberthink-pipeline/workflow.js`, leaving a thin preflight + args seam. The run ledger was designed as a key/value store but implemented as an append-only log, and the write and read paths disagreed about which occurrence of a key was authoritative; orchestration state now lives in JavaScript variables for the whole run, so the disagreement cannot exist.

### Fixed

- The fleet ceiling is live again. Every counter bump matched the FIRST occurrence of `AGENTS_DISPATCHED` — forever the Phase-0 seed of `0` — while every reader took the LAST, so waves of 3+32+2+6 reported 6 against a true total of 43 and `CB-ISLAND` could never halt a runaway genetic loop.
- Tooling crashes are no longer delivered as substance. The Wave-4 and Wave-7 cuts ran under `2>/dev/null || true`, so a module-load failure wrote no shortlist, the falsifier count fell to zero, `CB-CONVERGE` fired, and a ~90-minute run reported "the goal as framed admitted no feasible novel approach". A non-zero report run is now a `TOOLING` halt that can never route to a convergence verdict.
- Wave 5 dispatched against a fabricated composite path: it rebuilt the path from the shortlist *id* (`comp-island-K-NNN`) when the file is named by lens (`comp-NNN-<lens>.yaml`), so it pointed at a file that never exists. It now carries `report.py`'s authoritative `composite_path`, drops unusable rows with a halt rather than inventing one, and names falsifier dossiers by file stem so feasibility sub-scores actually reach the Wave-7 floor cut.
- `/uberthink` could not invoke the tool it now mandates: `allowed-tools` omitted `Workflow`. Added, with the byte-matched alias SSOT row and the assertion the sibling migrations already carry.
- `--resume` silently discarded the entire donor catalogue — cross-domain donor import is the premise of the command — because donors were assigned only on the non-resume branch. Donors now rehydrate from the scope verdict, or the scope gate re-runs.
- A personas relay returning the wrong shape at `rc 0` shipped empty persona blocks into every wave prompt and reported a clean success. The payload is validated before any dispatch, not just the return code.
- `--resume RUN_ID`, `--islands N` and `--max-new N` were documented with a space but only parsed with `=`; the space form fell through and launched a full ideation run on the run id as its goal. Both spellings now parse, and a value-taking flag with no value is a hard error.
- An existing-but-empty composites directory returned an empty design list at `rc 0`, which the preflight's eager `mkdir -p` made reachable; zero artifacts is now a missing input, not an honest frontier.

### Tests

- Added `tests/uberthink-workflow.test.sh` with a real accumulation fixture (3+32+2+6 must reach 43 and trip the ceiling), a report-runner `rc != 0` case asserting a `TOOLING` halt rather than a convergence verdict, resume-with-donors coverage, and persona-payload validation.
- Strengthened two assertions that passed for the wrong reason: the circuit-breaker check was satisfied by the sentence retiring a breaker, and the aggregate-path check matched a literal from an unrelated region. Every new assertion was mutation-proven.

## [0.41.0] — 2026-07-30

### Added

- Workflow-native dispatch for `/solve` and `/turbo` (RFC 0015): a new `workflow` backend runs one worktree-isolated solver agent per issue inside the calling session's Workflow runtime, via `skills/solve-fleet/workflow.js`. Progress is visible with `/workflows` and the run returns a structured per-issue result (`status`, `branch`, `prNumber`, `blocker`) instead of leaving outcome discovery to a separate agent surface.
- Script-orchestrated design phases for medium/large tier: a parallel research fan-out (codebase, constraints, test-coverage) feeding a spec writer, a bounded single-round spec review, and a plan writer, because a Workflow agent is a leaf and cannot fan out for itself.
- Live circuit breakers on the fleet: a projected-agent ceiling that aborts before any dispatch, a token-budget guard between waves, a manifest/claim cross-check that refuses to touch an unclaimed issue, and per-issue fault isolation so one failing issue cannot take the batch down.

### Changed

- `auto` now resolves to `workflow` on every Claude host and every OS class; a Codex session or Codex-only host still resolves to `codex`. The per-OS detached-supervisor matrix (macOS → WezTerm/claude-bg, WSL2/Linux → claude-bg, native Windows → WezTerm) is retired from automatic selection.
- Native Windows no longer hard-errors without WezTerm: the Workflow runtime owns agent lifetimes, so there is no process tree to supervise.
- The fanout cap is a real live concurrency ceiling on the `workflow` backend (waves are barriers), where on the detached backends it only ever chunked the dispatch burst.

### Deprecated

- `--backend=claude-bg`. The transport still works, still passes its full suite, and now prints a one-line deprecation notice when selected; `auto` never picks it. ~~Removal target v1.0.0.~~ ~~`wezterm`, `background` and `codex` remain fully supported explicit choices~~, and every migrated surface documents a No-Workflow fallback for runtimes without the `Workflow` tool.

  > **RETRACTED (#381, Unreleased).** `claude-bg` was deleted ahead of the v1.0.0 target — see the `claude-bg` entry under `## Unreleased` `### Removed`. `codex` was deleted in the same issue and is likewise no longer a supported choice; `wezterm` and `background` are.

### Tests

- Added `tests/solve-fleet-workflow.test.sh`: the shell seam (backend enum, `auto` resolution across all four OS classes, the deprecation notice, the no-provider-arm refusal, launcher Step 5w ordering and args emission), shape greps over the fleet script and its skill, and T3 behavioral fixtures covering tier routing, wave barriers, both circuit breakers, null-agent handling, the manifest cross-check, out-of-run-dir path rejection, and model policy.
- Re-anchored `tests/dispatch-fallback.test.sh` on the new auto contract (auto never selects a detached backend; native Windows resolves rather than refusing; an explicit deprecated backend still resolves, loudly) and updated the enum and Codex-skill-count locks.

## [0.40.3] — 2026-07-28

### Fixed

- Canonicalized review receipts and bound published evidence to validated artifact descriptors and digests.
- Made publication attempts replacement-safe and uniquely identified, with retry behavior safe on native Windows.
- Made Phase 1 aggregation executable without carrying artifact paths across trust boundaries.
- Restricted Phase 3 CI-fixer dispatch to validated scalar inputs bound to the captured PR head.
- Bound final review consumers to immutable local, live, and run-carrier SHAs before lifecycle advancement.
- Bound CI run selection to authoritative pull-request checks and reselected after every head-changing repair.
- Streamed bounded failed-job logs directly into an immutable PR/run/head/digest authority record without mutable staging paths.
- Preserved primary artifact-capture failures and structured cleanup diagnostics when descriptor closure also fails.
- Retired worktree receipts durably with shared atomic, no-overwrite moves so an existing terminal receipt can never be replaced.
- Bound `/review-pr` verdict discovery across the root checkout and three worktree layouts to stable command-line-root identities, one-time secure candidate captures, timestamp-prefix ranking, byte-identical selected ties, and a private digest/identity-recaptured snapshot receipt consumed without later pathname reopens.
- Made unknown verdict identity fail closed according to recency while ignoring known other-PR artifacts, and made strict duplicate-key-safe parsing distinguish exhaustive absence, legacy telemetry, current telemetry, and indeterminate discovery.
- Reused the canonical verdict selector in `/goal`, replacing its duplicate glob/sort/path-read implementation with normalized closed controller state.
- Enforced blocker- and critical-deferred acceptance independently in the trust evaluator, including halted Phase 2.5 results.
- Atomically reserved `/review-pr` run directories with collision-safe generated IDs, carried reservation/marker authority across fresh shells in a closed identity-and-digest receipt, preserved caller-owned `EXIT` traps, and published verdict JSON through the shared exact-name writer without truncating, replacing, or rolling back prior evidence.
- Installed a private ignore policy over `.uberdev/runs/` through the same no-clobber publisher when the repository's effective ignore stack does not already cover it, so review evidence never surfaces as untracked working-tree noise; the probe that detects an already-covered stack no longer aborts setup on its expected not-ignored exit status.
- Kept an already-observed red CI result terminal when the post-monitor metadata refresh is unavailable.
- Bound every routed child handoff to a controller-retained whole-file digest before preflight parsing or dispatch.
- Preserved receipt-authority argv byte-for-byte across Git Bash native-Python launches so raw short-name, case, symlink, and junction aliases remain rejectable, and normalized native descriptor artifact identities, including descriptor link-count portability, without weakening same-handle mutation or replacement detection.
- Added native Codex marketplace metadata and its canonical install selector to generated prkit output, and made the Codex source, manifest, and marketplace contract mandatory generation inputs.
- Made standalone generation fail closed on dirty, ignored, uninspectable, or non-empty non-Git targets; `--force` remains the explicit managed-path replacement override and never bypasses containment or the generation lock.
- Rejected symbolic-link, reparse-point, special, and Windows-reserved managed paths before replacement and during final verification; sealed generated trees before recursive deletion.
- Published copied and rendered files atomically from destination-local temporaries, propagated publication failures instead of accepting stale output, verified executable-mode postconditions, and pinned the generated CI checkout action by immutable SHA.
- Raised the Linux shape-check timeout to 40 minutes after a green 91/0 suite exhausted the 30-minute ceiling, preserving a bounded hang guard with measured hosted-runner headroom.

### Tests

- Added regression coverage for receipt and publication identity, immutable SHA binding, path-free aggregation, authoritative CI-run selection and reselection, direct-stream classifier limits and encoding failures, coherent handoff mutation, fail-closed post-monitor refresh, capture cleanup diagnostics, CI-fixer dispatch, verdict-root retargeting, external root symlinks, strict JSON compatibility/type matrices, timestamp ties, unknown-candidate recency, snapshot drift, atomic run collisions, no-clobber verdict publication, native-Windows retries and stat semantics, prkit Codex marketplace validation, dirty/ignored target preservation, non-Git force semantics, symbolic-link/reparse and special-path containment, Windows reserved names, cooperative locking, immutable CI action pins, atomic publication failures, and the Linux CI timeout budget.
- Exercised durable worktree-receipt retirement natively on Linux, macOS, and Windows.

## [0.40.2] — 2026-07-26

### Fixed

- Pinned Codex-originated review fanouts to the Codex backend, including clean environments without `CODEX_HOME`; explicit backend requests remain visible to governed preflight and are rejected when incompatible rather than silently accepted or rerouted.
- Hardened detached Claude supervision with unattended-permission preflight, exact `claude stop` cancellation, blocked-session terminalization, and exact capacity-lease release.
- Isolated routed runtime state under a private user-owned directory and derived each Codex reviewer worktree and branch from its run-scoped child identity with terminal cleanup.
- Reconciled review `changed_paths` with a traversal-safe repository-relative contract that also supports deleted files.
- Added one canonical machine-readable Phase 1 reviewer result schema to manifest-routed reviewer prompts across the packaged Claude and Codex runtimes.
- Shipped the run-tree policy and reviewer schema in generated prkit Claude and Codex packages so clean installs no longer depend on stale runtime files.
- Kept routed Codex workers leaf-only with the supported `features.multi_agent=false` setting instead of the rejected `agents.max_depth=0` override.
- Scoped routed child allocation identities to each review run so preserved evidence from earlier runs does not reuse the same allocation identity.
- Added manifest-declared caller workspace execution for the five review repair edges so their commits land in the validated review checkout, while other children retain isolated worktrees.
- Scoped Codex child logs to their unique status artifacts and made cleanup failures terminal, observable failures without deleting unsafe evidence.
- Hardened logical repository paths and ownership receipts for native Windows, including fail-closed Git probe errors.
- Kept routed output contracts edge-local instead of promoting them into every native role invocation.
- Rejected malformed CI classifier anchors before routing and kept CI-refusal aggregates inside the command-owned research directory.
- Bounded indeterminate Claude probes, resolved full session IDs before cancellation, and made launch terminalization and exact lease release fail closed with durable supervisory evidence.
- Preserved complete large-PR path sets, rejected Windows drive-relative paths, and restored Python 3.10-compatible standalone PRKit verification.
- Made reviewer-evidence and deferred-findings publication/refusal paths fail closed, preventing malformed or unpublished artifacts from reaching fixers or trust emission.
- Bound review evidence and re-entry snapshots to immutable run-carrier lineage plus current local/remote PR heads, and required validated fixer mutations and disposition artifacts before the lifecycle can advance.

### Tests

- Added a six-child Codex review integration fixture covering backend selection, non-interactive dispatch, unique worktrees, success and failure cleanup, terminal lifecycle receipts, and zero leaked leases.
- Added regressions for Claude idle and ambiguous sessions, nested auto-permission propagation, subdirectory Codex cleanup, cleanup-failure recovery evidence, and large review diffs.
- Added regressions for publication failures and refusals, PR-head drift, carrier lineage, evidence-ledger completeness, and fixer/disposition re-entry gates.

## [0.40.1] — 2026-07-11

### Fixed

- Hardened the live-semaphore CI observer against concurrent mutex generation removal while preserving strict direct-lease counting.

## [0.40.0] — 2026-07-11

### Added

- Adaptive GPT-5.6 routing for Codex with six named routes: Luna economy, Terra standard, and Sol quality/high/max/ultra. Lead work scales by issue tier and risk; high-risk work is promoted to a safe minimum automatically.
- Role-aware fanout routing across research, planning, implementation, review, CI repair, testers, and UberThink. Mechanical and routine tasks use cheaper routes while judgment-heavy work receives Sol; large or high-risk plan writing uses Sol Ultra.
- Project and environment overrides for routing mode, role/workflow routes, reasoning effort, service tier, and policy location, with `.codex/uberdev.local.md` preferred over the Claude fallback.
- A versioned 40-edge run-tree contract with typed child inputs, canonical handoffs, bounded leaf delegation, lifecycle receipts, risk propagation, and format-retry validation.

### Changed

- Brainstorm, orchestrator, subagent-driven development, post-implementation review, `/review-pr`, and `/simplify` now dispatch every provider child through the shared routing runtime.
- Codex dispatch now passes the independently resolved model, reasoning effort, service tier, sandbox ceiling, and leaf-agent limits instead of inheriting one expensive model for every fanout task.
- The plan writer remains a non-delegating leaf and receives tier-aware Sol routing: high for trivial/small, max for medium, and Ultra for large or high-risk plans.
- Codex skills, command-skills, agents, runtime libraries, and policy mirrors are regenerated from the canonical plugin sources.

### Security

- Routed child inputs are validated before handoff; receipt and manifest files use private modes, atomic writes, symlink/hard-link defenses, closed schemas, and payload-free diagnostics.
- Provider invocations outside the routing boundary are denied by CI, while production fanout harnesses verify the real build → handoff → dispatch lifecycle.

## [0.39.1] — 2026-07-08

### Fixed

- `codex/install-codex.sh` now adopts older full UberDev Codex skill installs that predate `.uberdev-codex-managed` markers, upgrades them in place, and installs the missing runtime directory while still refusing partial or user-owned skill collisions.

## [0.39.0] — 2026-07-08

### Added — Codex CLI support (RFC 0012 §3.4 codex-port)

UberDev now installs into the [OpenAI Codex CLI](https://developers.openai.com/codex) — the full toolkit (26 skills, 42 subagents, 13 command-skills, autonomous dispatch) alongside the existing Claude Code delivery. Two install paths ship:

- **`codex/install-codex.sh`** — standalone installer (mirrors `install.sh`): skills → `~/.agents/skills/`, agents → `~/.codex/agents/uberdev-*.toml`, primer merged into `~/.codex/AGENTS.md`. Idempotent + `--uninstall`. This is the path that carries the 42 subagents (the Codex plugin manifest has no `agents` field, so the plugin alone can't ship them).
- **Codex-native plugin + marketplace** — `codex/uberdev-codex/` (`.codex-plugin/plugin.json` bundles skills + session-start hook) + `.agents/plugins/marketplace.json`. Install via `codex plugin marketplace add TheFJK/UberDev` → `/plugins`. Browse-and-toggle UX; pairs with the installer for full functionality.

**Converter tooling** (`codex/tools/`, idempotent, regeneratable from source):
- `convert-agents.py` — Claude `agents/*.md` (YAML frontmatter + body) → Codex `*.toml` (`name`/`description`/`developer_instructions`). Tolerant of Claude's lenient unquoted-scalar-with-colons frontmatter (8 of 42 agents tripped strict YAML). `model: inherit` (41 agents) → omit `model`; `model: haiku` (the lone outlier, `research-test-coverage`) → `gpt-5.4-mini`. Drops Claude-only `color`/`allowed-tools`/`tools`.
- `convert-commands.py` — 13 Claude slash commands → `uberdev-cmd-*` Codex skills (Codex custom prompts are deprecated; skills are the documented shareable replacement). Skips the 2 Claude-only alias commands (`install-aliases`/`uninstall-aliases` — no Codex equivalent).
- `port-skill.sh` — copies the 26 skills ~verbatim with `CLAUDE_PLUGIN_ROOT`→`PLUGIN_ROOT` + `~/.claude/`→`~/.codex/` path fixes. Tool-name bridging (`Task`→`spawn_agent`, etc.) is runtime, via the shipped `references/codex-tools.md`.

**Dispatch backend** — new `codex` arm in `lib/dispatch.sh` (`_uberdev_dispatch_codex`): execs `codex --ask-for-approval never exec --sandbox workspace-write --json -o <result>` in a per-issue git worktree, nohup-detached + PID-tracked (mirrors the proven `background` backend — no new liveness mechanism). Auto-selected when `CODEX_HOME` is set or `claude` is absent + `codex` present; overridable via `--backend=codex`. `lib/solve-launcher.sh`'s claude-version gate is now backend-conditional (codex path requires `codex` on PATH instead). `lib/goal-state.sh` liveness polling is backend-aware: the codex/background path uses `kill -0` PID checks instead of `claude agents --json`.

**Hooks** — `hooks/session-start` gained a Codex arm (`CODEX_HOME` → SDK-standard `additionalContext` shape), extending the existing three-way Cursor/Claude/Copilot platform dispatch. The `using-uberdev` primer is distilled into `codex/AGENTS.md` for Codex's global-instruction layer.

**Tests** — `tests/dispatch-codex.test.sh` (22 assertions: enum, probe, preflight auto-resolve, dispatch_one routing, the codex exec mechanism, backend-aware goal-state, solve-launcher gating) + `tests/codex-port.test.sh` (17 assertions: converter round-trips, model-mapping edge cases, command-skill counts, skill-port residuals, installer idempotency + uninstall, manifest validity). Both wired into `.github/workflows/test.yml` (codex-port is ubuntu-only — python3+rsync deps; documented in the windows-skip-list).

### Known limitations (Codex v1)

- The `testers-pipeline` / `scan-fleet` `workflow.js` skills use Claude's `Workflow` tool (no Codex equivalent); Codex bundles the Markdown agent prompts those workflows read, and users still fall back to the skills' `## No-Workflow fallback` path when the Workflow tool is unavailable.
- `uberdev_goal_review_pr_in_flight` uses backend-specific liveness: `claude agents --json` for Claude-backed sessions and PID/status JSON for `background` / `codex` sessions.
- Agent model mapping (`haiku`→`gpt-5.4-mini`) is a 2026-07 snapshot — revisit on each OpenAI model release.
- `codex cloud exec` (async server-side dispatch) is a future enhancement; v1 uses local `codex exec` + `nohup`.

## [0.38.0] — 2026-06-25

### Changed

- **RFC 0012 Phase 3 — `/uberscan` + `/ubersimplify` migrated to the shared `scan-fleet` Workflow** (`skills/scan-fleet/workflow.js`). One `workflow.js` backs both commands via a `mode` (`scan`|`simplify`) branch: it packs the repo into ≤N byte-balanced areas (`lib/chunk.py`), runs ONE multi-lens reviewer per area in concurrency-bounded `parallel()` waves, then for scan runs an inline repo-global Semgrep+coverage pass and `report.py` aggregation, and for simplify runs `aggregate.py`, a sequential `code-fixer` apply (one `refactor:` commit per area on a shared branch — sequential to stay git-index-safe), one PR, and leftover-issue filing. Both pipeline `SKILL.md` bodies are now thin preflight + args-emit + Workflow mandate + `## No-Workflow fallback` seams (≈682/715 → ≈170 lines each). Closes the `/uberscan` + `/ubersimplify` half of #305 (the zsh `ARR=($VAR)` scalar-split wave bug, the fence-scoped circuit-breaker death, and the `$ARGUMENTS` hazards are eliminated by construction — the orchestration is JS, not a directive-emitter bash fence).

### Added

- `skills/scan-fleet/global-pass.sh` — the inline repo-global Semgrep SAST + test-coverage pass, extracted from the legacy `uberscan-pipeline` Phase 1b (reused by both the Workflow relay and the No-Workflow fallback).
- `tests/scan-fleet-workflow.test.sh` — shape greps + a T3 behavioral fixture that drives `scan-fleet.js` under the harness stubs and asserts per-mode phase order, sequential-apply, model policy, CB5/CB7, and the budget-throw (DR-8) path.

### Notes

- The time-based circuit breakers CB3/CB4 (per-wave / wall-clock) are intentionally dropped: they were already dead in the ms-returning directive-emitter fence, and the Workflow runtime forbids `Date.now` (DR-7 determinism); the real `budget` lifetime cap + CB5 (blocker flood) + CB7 (agent ceiling) cover the live failure modes. The simplify apply phase uses sequential dispatch with NO worktree isolation (git forbids two worktrees on one branch; sequential dispatch already removes the index race).

## [0.37.1] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.37.0] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.12] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.11] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.10] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.9] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.8] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.7] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.6] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.5] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.4] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.3] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.2] — 2026-06-12

- _Release notes pending — replace this stub before committing (inserted by bump-version.sh)._

## [0.36.1] — 2026-05-31

### Fixed
- **`/goal` Phase-2 watch loop is now driveable from the Claude Code Bash tool (#299).** Three fixes so `/ubergoal` → `/uberdev:goal` runs end-to-end as-presented:
  - **Bounded / single-tick watch mode (finding 2).** New `--watch-passes=N` / `--watch-budget=SECS` flags (and the `GOAL_SINGLE_TICK=1` env shorthand for one pass) make the Phase-2 watch loop run a bounded number of poll passes (or a per-fence wall-clock budget) and then exit with a documented re-invocation contract instead of the unbounded `while true … sleep` loop that a single 600s-capped Bash-tool call cannot host. Exit codes: `0` = drained (proceed to Phase 3), `42` = still-active (re-invoke Phase 2), `1` = circuit-breaker halt. Each bounded tick persists run-state via `uberdev_goal_write_run_state` and prints current state; the reaper fires only on a breaker or a genuine INT/TERM — **never on a bounded pause**, so live bg solver agents survive between ticks. Default 0 = unbounded (legacy behaviour unchanged). The bound round-trips run-state (new `WATCH_PASSES` / `WATCH_BUDGET` sidecar fields, exported by `uberdev_goal_read_run_state`) so it survives the fresh-shell Phase-2 fences.
  - **Doubled `goal-goal-<id>-` sidecar prefix dropped (finding 3).** `GOAL_ID` is now generated WITHOUT the leading `goal-` (`<epoch>-<rand>` instead of `goal-<epoch>-<rand>`), so the per-goal sidecars are single-`goal-`-prefixed on disk (`goal-<epoch>-<rand>-runstate`, …) instead of `goal-goal-…`. Fixes the debugging foot-gun where `"$TMPDIR"/goal-<id>-*` silently matched nothing. Read/write symmetry preserved (every site shares the `goal-$GOAL_ID-` format string); the id stays digits/dash/alnum so the path-traversal + mis-pathing guards are unaffected.
  - **Cross-shell verdict-locator regression guard (finding 1).** Locks the (already-fixed at HEAD via `_uberdev_goal_glob_worktree`) behaviour that the watch loop's verdict locator + peer glob enumerators return cleanly on zero matches under zsh — a bare unmatched glob fatals `no matches found` under zsh, so a new `tests/goal-state-zsh.test.sh` case (Z10) asserts none of them ever fatal.

## [0.36.0] — 2026-05-30

### Changed
- **`/uberscan` + `/ubersimplify` fan-out is now area-scoped (fixed fleet) instead of per-byte-chunk × N reviewers.** The old model dispatched the 6-reviewer Phase-1 fleet (uberscan) or 3 lens Tasks (ubersimplify) against every ~48 KB chunk, so agent count scaled as `files × fleet`: on this 251-file repo a true whole-repo `/uberscan --all` projected **70 chunks × 6 + 2 = 422 agents**, and the default `MAX_CHUNKS=25` cap didn't shrink the fleet — it silently **truncated coverage** to the alphabetically-first 25/70 chunks (~36% of the tree). There was no path to "audit the whole repo at a sane cost." Now `lib/chunk.py --areas N` (new `pack_areas`) packs **all** in-scope files into **≤ N byte-balanced areas** (default 8, config `uberscan.areas` / `ubersimplify.areas`, range 1-24) via a binary-searched contiguous partition — every file covered exactly once, no overflow-truncation — and **one multi-lens agent reviews each area** (uberscan: a single `code-reviewer` sweeping correctness/silent-failures/type-design/comments/tests; ubersimplify: a single `code-simplifier` running all active lenses). Whole-repo cost drops from **422 → ~8 agents** (uberscan) and **210 → ~8** (ubersimplify), regardless of repo size, and the scan actually covers the whole repo.
- **`/uberscan` repo-global Semgrep + test-coverage passes now run INLINE** (plain `semgrep`/`python3` in Phase 1b) instead of as 2 dispatched `research-*` agents — fail-soft (a missing/erroring Semgrep degrades to a skip note, never aborts the audit).
- **Circuit-breaker recalibration:** CB1 (`MAX_CHUNKS` overflow) is **retired** in area mode (it can never trip — nothing is dropped); CB7 now projects `areas × 1` as a backstop against an absurd explicit `--areas`. New `--areas=N` flag on both commands; `--max-chunks=N` is retained as a legacy alias. The manifest `chunks[]` schema and `chunk-NNN-*.yaml` filenames are unchanged (each entry is now an area), so `report.py` / `aggregate.py` / findings-to-issues are untouched. Design: amendments to `docs/rfc/0007` + `docs/rfc/0008`.

### Tests
- `tests/uberscan-chunk.test.sh` gains 8 area-mode invariants (≤ N areas, every file covered exactly once, deterministic, byte-balanced, fail-loud on `--areas 0`). `tests/uberscan.test.sh` (U7) and `tests/ubersimplify.test.sh` add fixed-fleet shape locks so a regression to the per-chunk × N fan-out turns CI red.

## [0.35.19] — 2026-05-29

### Tests
- **`/goal` orchestration layer gains runtime coverage (#293)** — the `lib/goal-state.sh` layer was densely unit-tested, but **no test executed the `skills/goal-pipeline/SKILL.md` bash fences** (CI only sourced the lib and grepped the markdown), so every orchestration-wiring regression — including the defects fixed in #288/#289/#290/#291/#292/#294 — could ship green. Adds CI-wired `tests/goal-pipeline-zsh.test.sh`, which extracts the SKILL.md `bash` fences and runs the key ones under the real **zsh** Bash-tool shell with `gh` / `claude` / `uberdev_dispatch_one` mocked: Phase-0 arg-parse + the bash≥4 resolver (asserts no spurious `exit 2` under zsh when bash≥4 is present, and `exit 2` when none — the #294 regression guard), the Phase-3 queue-empty convergence calc (#288), and one watch-loop iteration. Replaces the single-line negative-grep `--dry-run` assertion (G17) with a behavioural mocked-dispatch run asserting zero dispatch calls + `exit 0` + no `goal_dispatched` audit row. Wired into `.github/workflows/test.yml` per the `ci-wiring.test.sh` invariant.

## [0.35.18] — 2026-05-29

### Fixed
- **`/goal` advanced PRs on stale reviews (#290.1)** — `uberdev_goal_read_trust_signal` now binds the `/review-pr` verdict to the PR's live `headRefOid` and returns `stale` when a commit landed after the GREEN verdict (fail-safe on a gh outage; backward-compatible when the verdict predates the `.sha` field), instead of driving `pushed-reviewing→green→merging` off a stale review.
- **`/goal` merge-result audit read missed the merge worktree (#290.2)** — `read_merge_result` now scans the worktree-mirror audit set (the same prefix glob the verdict locator uses) instead of cwd-only `.uberdev/audit.jsonl`, so the `merge_failed` breaker fires on the conflict/hook-failed path instead of looping the 60 m timeout.
- **`/goal` rode out sustained gh outages silently (#290.3)** — a consecutive-gh-failure breaker now records failures in `find_pr_for_issue` / `pr_state_gh` and fires `gh_api_failed` via `uberdev_goal_gh_failure_breaker_check`, rather than abandoning a solved-and-pushed issue to the solve-timeout.
- **`/goal` could bind the wrong PR (#290.4)** — `find_pr_for_issue` now scans `--state open` and prefers the `closingIssuesReferences` match over the `feat/N-` head-ref heuristic, so a stale closed branch can't corrupt batch-registry accounting.
- **`/goal` mutual-`Blocks:` deadlock (#292.1)** — new `uberdev_goal_detect_blocks_cycle` SCC detector surfaces `stuck_loop phase=blocks_cycle` instead of spinning two mutually-blocking held PRs to the 4 h cap.
- **`/goal` merge-attempt cap was per-PR-lifetime (#292.2)** — the per-PR cap now resets on a held→green recovery (`uberdev_goal_reset_merge_attempts`), so a PR legitimately blocked for cycles isn't permanently locked out of auto-merge by transient stalls.
- **`/goal` merge barrier deadlocked on a phantom label (#289.1)** — `batch_unblock_wait_clear` now gates on the `uberdev-approved` label `/review-pr` actually emits (the old `review-pr:green` had zero producers, so a held batch row returned rc 1 forever and blocked every co-batched GREEN PR until the 4 h `stuck_loop`); a blocker-closed-but-still-held PR is now pseudo-terminal so it stops gating others.
- **`/goal` didn't serialize version-bump merges (#289.2)** — the green-PR loop now dispatches the lowest green PR and waits (a non-terminal `MERGING` batch-sentinel interlock) for it to land on fresh main before the next `/merge`, so two version-bump PRs can't both land `vN+1` and silently eat the second bump.
- **`/goal` multi-blocker unblock inconsistency (#289.3)** — `batch_unblock_wait_clear` now requires ALL `Blocks:` issues closed (was break-after-first), matching `check_unblock`.
- **Cross-shell worktree-glob hardening (#270 class)** — the `_UBERDEV_GOAL_WORKTREE_PREFIXES` globs never expanded under the zsh Bash tool; all three consumers now route through `_uberdev_goal_glob_worktree` (zsh `${~pat}` + `nonomatch` / bash bare), and loop-body `local` decls are hoisted to function scope.

### Tests
- `tests/goal-batch-barrier.test.sh` (B10–B18), `tests/goal.test.sh` (BT23a–e + repoints), and `tests/goal-state-zsh.test.sh` (Z6–Z9, dual-shell) cover each fix; every fix red-checked via revert. Full `tests/*.test.sh` suite 58/0 under bash and zsh.

## [0.35.17] — 2026-05-29

### Fixed
- **`/goal` was unrunnable out-of-box under the zsh Bash tool (#294)** — the Phase-0 `bash>=4` guard hard-`exit 2`ed whenever `BASH_VERSINFO` was unset, which is *always* the case under the `/bin/zsh` Bash-tool runtime, so `/goal` tripped on its very first fence even on hosts with bash 5.x installed. Phase 0 now **resolves** bash≥4 instead of dead-ending: proceed if already ≥4; else discover a ≥4 binary (`/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `command -v bash` — each version-verified), publish `UBERDEV_GOAL_BASH`, and shebang-gated re-exec the fence under it; only `exit 2` when no bash≥4 exists anywhere. Execution contract documented in `commands/goal.md` + a README Prerequisites row.
- **`/goal` false convergence stranded rollover issues (#288)** — both Phase-3 terminal gates (`goal_converged`, `queue_empty_not_converged`) now also require an empty `queue`, so issues rolled past `--max-parallel` can no longer be reported converged while still OPEN and never dispatched. Adds a cycle-ceiling backstop at the top of Phase 1 (halts `max_cycles` regardless of which fence the orchestrator re-enters) and a per-cycle merge-barrier reset (`barrier_start_ts=0` + batch-PR TSV truncate) so a healthy late cycle no longer spuriously trips `stuck_loop phase=merge_barrier`.
- **`/goal` concurrent double-solve (#291)** — Phase 1 now acquires the cross-process `uberdev:active` claim (label-absent-guarded SETNX, mirroring solve-pipeline) **before** dispatch and releases it on every terminal non-merge transition, closing the gap where `/goal` dispatched `/uberdev:orchestrator` directly and bypassed the claim. The `--only-mine` multi-identity caveat is documented (opt-in, OFF by default; single-identity setups unaffected).

### Tests
- `tests/goal.test.sh` gains G41/G42/G43 (structural + behavioural; the #294 group runs the Phase-0 guard under zsh and asserts no spurious `exit 2`). Verified red-on-old-code; full goal suite green under both bash and zsh.

## [0.35.16] — 2026-05-29

### Fixed
- **Envelope the Phase-2 simplify-lens dispatch diff (prompt-injection — #271 follow-up)** (#286). #271 enveloped the Phase-1 reviewer dispatch + added the untrusted-input stanza to the six agent bodies (incl. `code-simplifier`), but the **Phase-2 simplify-lens dispatch** reused `code-simplifier` at two command-site points that still passed the diff raw: `commands/simplify.md` (`<<diff_brief>>`) and `commands/review-pr.md` Step 6 (`<<base_brief>>`). Both now wrap the diff in `<external-untrusted-input source="pr-diff">…</external-untrusted-input>` (the trusted `## Lens emphasis:` / `## Additional Focus` directives stay OUTSIDE the envelope), completing defense-in-depth across every diff-ingesting agent-dispatch site.

### Tests
- `tests/simplify.test.sh` + `tests/review-pr.test.sh` gain region-scoped open/close-tag asserts (awk-ranged to the Phase-2 lens-dispatch block so the pre-existing `source="post-impl-review-aggregate"` close tag cannot false-PASS) PLUS a literal dispatch-line pin on `prompt: <external-untrusted-input source="pr-diff">` (so a prose-only mention can't false-PASS). Mutation-tested via revert. 60/0 + 135/0.

## [0.35.15] — 2026-05-29

### Fixed
- **`uberthink` report.py — clamp `ambition_score` axes to avoid a complex-number dossier-sort crash** (#277). `ambition_score` applied fractional exponents (`BETA/GAMMA/DELTA = 1.2/1.3/1.2`) to axes that can be negative; in Python a negative base with a fractional exponent returns a `complex` rather than raising, so `round(complex)` raised `TypeError` and `rank()`'s `sorted(key=ambition)` raised `'<' not supported between instances of 'complex' and 'complex'`, aborting the Wave-7 dossier render with no cause-specific message (`feasibility_floor_fails()` cuts only `feas < 4.0`, so a negative `novelty`/`combination`/`impact` from the Arbiter's `ranked.yaml` survived to the exponent). Each axis is now clamped with `max(0.0, float(x))` before the power — a negative axis fails closed to `0` (worse than zero → product `0` → ambition tanks → still a real, sortable float), matching the existing zero-floor semantics; the clamp is identity for in-domain `[0,10]` values.

### Tests
- `tests/uberthink-report.test.sh` gains a negative-axis regression block: asserts `ambition_score` returns a real float (`== 0.0`) for a negative on every axis, that in-domain scores are unchanged, and that `rank()` does not raise on a `ranked.yaml` whose negative axes survive the feasibility floor. Reds pre-fix (`-771.29…`), greens after. 13/0.

## [0.35.14] — 2026-05-29

### Fixed
- **`findings-to-issues` — document the SEARCH-bucket rate-limit guard + drop a tautological test** (#276). The agent's "Refusal triggers" section documented only the **core**-bucket rate-limit guard (`CORE_REMAINING < (2*max_new+50)`) under a stale single `REMAINING` var name, omitting the **SEARCH**-bucket fail-CLOSED condition (`SEARCH_REMAINING < (max_new+5)`) that Process Step 2 mandates (the load-bearing guard against silently mapping dedupe lookups into `blocked_by_dedupe[]` with no issues filed). The section now enumerates BOTH bucket conditions verbatim against Step 2. The Suite-3 "L4 runtime assertion" in `tests/findings-to-issues.test.sh` exercised only the test's own mock `gh()` (a near-tautology); it and its now-orphaned mock scaffolding are removed — the real label-idempotency contract stays locked by the structural L1 assert.

### Tests
- `tests/findings-to-issues.test.sh` Suite 16 (3 section-bounded asserts) locks both bucket conditions in the Refusal-triggers block and asserts the stale bare-`REMAINING` single-bucket form is gone; mutation-tested (each flips to FAIL when the threshold or section is broken). 53/0.

## [0.35.13] — 2026-05-29

### Fixed
- **Test count idioms no longer mask a missing file / tool crash as a passing `0`** (#275). The repo-blacklisted `… | grep -cE … || true` / `… 2>/dev/null || echo 0` idiom collapses three outcomes into one passing `0` — a legitimate zero-count, a missing/unreadable file, and a tool crash. `tests/_lib_assert_structural.sh` `assert_count` (the SSOT helper sourced by 14 test files) now fail-loud-preflights `[ -r "$file" ]` and captures `awk`'s exit status on a separate statement (an `awk` crash FAILs; only `grep` rc ≥ 2 is treated as an error, so a legitimate zero-match on a present file still PASSES). `tests/uberthink.test.sh` (U11) drops the `2>/dev/null || echo 0` mask and adds an explicit `[ -r "$F2I" ]` preflight, restoring the diagnostic that distinguishes a real allow-list regression from brittle-anchor drift.

### Tests
- New `tests/lib-assert-count.test.sh` (5 assertions): present-file count, legitimate zero-count on a present file (over-correction guard), and the bug — a missing file (AC3) + an unreadable file (AC4) with `expected==0` must FAIL loud, not pass vacuously. Reds against the pre-fix helper (2/5), greens after (5/5). Wired **ubuntu-only** (AC4's `chmod 000` is a no-op under Windows Git Bash) and declared in the windows-skip-list marker.

## [0.35.12] — 2026-05-29

### Fixed
- **Cross-platform shell portability — `run-hook.cmd` Windows args + GNU-sed `probe` dependency** (#274). The Windows `cmd.exe` arm of `plugins/uberdev/hooks/run-hook.cmd` forwarded args as bare `%2 %3 … %9` (re-splitting spaced/quoted args, capping at 8 trailing args), asymmetric with the Unix arm's `exec bash … "$@"`; it now uses a `SHIFT`-based `goto` loop accumulating `HOOK_ARGS` with quoting, mirroring the `"$@"` contract (the `: << 'CMDBLOCK'` polyglot heredoc stays balanced under both `bash -n` and `zsh -n`). `tests/manual/probe-prompt-file-slash-expansion.sh` used GNU-sed-only `\x1B` in its ANSI strip (treated literally by BSD/macOS sed → escapes survive → empty `SESSION_ID` → spurious `INDETERMINATE`); replaced with a portable `tr -d '\033'` + POSIX-sed strip.

### Tests
- New `tests/crossplatform-shell-wrappers.test.sh` (21 assertions): structural asserts the broken forms are gone + portable forms present, a POSIX model of the `cmd` SHIFT-loop proving 8/11/spaced-arg forwarding, a `bash -n`/`zsh -n` heredoc-balance check (the `zsh -n` arm self-skips when zsh is absent — Windows-safe), and a platform-independent ANSI-strip regression kernel. Reds pre-fix (8 fails), greens post-fix (21/21). Portable — wired into both CI jobs.

## [0.35.11] — 2026-05-29

### Fixed
- **Docs-accuracy sweep — vendored `testing.md`, stale `CONTRIBUTING`, dead link, RFC 0004 collision** (#273). `plugins/uberdev/docs/testing.md` was verbatim-upstream Superpowers (documented `tests/claude-code/`, `run-skill-tests.sh`, `superpowers@superpowers-dev` — none exist here); rewritten to describe the real `tests/*.test.sh` shape-check harness and the `.github/workflows/test.yml` two-job (ubuntu + windows) matrix, with `uberdev@uberdev` as the marketplace key. `CONTRIBUTING.md` now points at `test.yml` as the test-suite SSOT (dropping the false "no behavioral tests yet" claim and the partial 4-file list) and its dead `[Repo layout](README.md#repo-layout)` link is fixed. The **RFC 0004 number collision** is resolved by renumbering the alias-reliability draft to **RFC 0011** (the dispatch-backends RFC keeps 0004 — shipped code + CHANGELOG cite it), with cross-refs updated in `hooks/session-start`, `lib/aliases-sync.sh`, and the CHANGELOG; the dispatch RFC's internal §4/§5 version refs are corrected to `0.29.0 → 0.30.0`.

### Tests
- New `tests/docs-accuracy.test.sh` (fail-loud on missing inputs; dynamic duplicate-RFC-number detection) guards against re-vendoring `testing.md`, the dead README link, and RFC-number collisions. Portable grep-and-assert — wired into both the ubuntu and windows CI jobs.

## [0.35.10] — 2026-05-29

### Fixed
- **`/review-pr` Phase-3 CI probe — align to the real `gh pr checks` field contract** (#272). `commands/review-pr.md` probed `gh pr checks --json name,status,conclusion`, but `gh` 2.83.1 exposes only `name,state,bucket` (no `status`/`conclusion`) — so against real `gh` the probe errored on unknown fields and Phase-3 silently degraded to the `ci_probe_unreachable` carve-out on every run, never gating real red CI on a to-`main` PR. The probe now reads `--json name,state,bucket` and maps terminal/non-terminal off `state` + `bucket` (red outranks pending). The `tests/_fixtures/fake-gh/gh` stub emits `state`/`bucket` to match.

### Tests
- `tests/review-pr-phase3-ci.test.sh` gains genuine RUNTIME coverage (S15-RUNTIME): prepends the `fake-gh` stub to `PATH`, sets `FAKE_GH_MODE`, runs the real probe, and applies the jq verdict program extracted live from `review-pr.md` (so it cannot drift); a mutation back to the old `status`/`conclusion` shape reds it. Because it now executes the `fake-gh` fixture via `PATH` (committed-`+x` dependency, like `merge-discovery-resilience.test.sh`), it moves to the ubuntu-only CI job and is added to the windows-skip-list marker.

## [0.35.9] — 2026-05-29

### Fixed
- **review-pr reviewer fleet — envelope the attacker-controlled PR diff (prompt-injection defense)** (#271). All six PR-diff reviewer agents (`code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`, `pr-test-analyzer`, `code-simplifier`) ingested the pasted diff inline with no `<external-untrusted-input>` envelope and no "treat as DATA, not instructions" stanza — even though `post-impl-review/SKILL.md` documents the injection chain (issue-author text → diff hunk → reviewer report → aggregate → fixer prompt) and already wrapped only the downstream aggregate→fixer hop. Each agent body now carries the canonical untrusted-input-handling stanza (byte-identical to the research-* agents), and `post-impl-review/SKILL.md` wraps the pasted diff/changed-code (including the >2000-line summarised-diff path) in `<external-untrusted-input source="pr-diff">`. `comment-analyzer` and `pr-test-analyzer` run on `haiku` and were the highest-risk carriers (comment text is a natural injection vector).

### Tests
- `tests/post-impl-review.test.sh` gains 14 assertions locking the untrusted-input stanza heading + verbatim body per agent and the Step-1 envelope open/close around the diff (awk-bounded so the pre-existing reader-side `source="post-impl-review-aggregate"` close tag cannot false-PASS); reverting the envelope reds the suite.

## [0.35.8] — 2026-05-29

### Fixed
- **goal-pipeline / finish-branch — five zsh-runtime bugs under the `/bin/zsh`-backed Bash tool** (#270). The `/goal` and `finish-branch` SKILL.md bash fences execute under zsh on macOS, where bash-only syntax misfires; CI only ran the suite under bash, so the breakage escaped. Fixed in `lib/goal-state.sh`: (1) `_uberdev_goal_parse_blocks_line` now reads `${match[1]:-${BASH_REMATCH[1]}}` (the only `Blocks: #N` parser — held-PR unblock was dead under zsh, so the `/goal` merge barrier could clear prematurely); (2) `uberdev_goal_agent_stuck_on_dialog` renames `local status` (zsh's read-only special parameter, which hard-aborted the function on its first line) and routes `${!var}` indirection through a new `_uberdev_goal_indirect_get` helper branching on the live shell (`${(P)name}` / `${!name}`) using only native parameter expansion — no `eval`/`bash -c` (respecting the file's T3 no-shell-eval rule); (3) `write_run_state` replaces `compgen -v` with `env | grep` enumeration so per-PID stuck-dialog samples persist across fences; (4) a `${BASH_SOURCE[0]:-}` guard for `set -u` zsh callers. In `skills/goal-pipeline/SKILL.md`, `print_summary()` is hoisted out of the Phase-4 fence into `lib/goal-state.sh` — it was called from the Phase-1/2/3 fences but a shell function cannot cross a fence boundary, so every circuit-breaker and the convergence exit hit `command not found` (rc 127) and silently dropped the operator summary line + held-PR post-mortem rows. In `skills/finish-branch/SKILL.md`, the PR number is now `${PR_URL##*/}` on the already-`PR_URL_REGEX`-validated URL (sidesteps the `BASH_REMATCH` capture), restoring the #95 `review-pr:pending` backstop label on finish-branch PRs created on macOS.

### Tests
- New `tests/goal-state-zsh.test.sh` (modeled on `solve-pipeline-zsh.test.sh`) sources `goal-state.sh` under the live shell and asserts the five #270 behaviours plus the two structural must-dos (print_summary hoist; `agent_stuck_on_dialog` free of `read-only`/`bad substitution`); green under both bash and zsh (13/13 each). Wired into the ubuntu CI job under `zsh` (windows-skip — `windows-latest` ships no zsh).

## [0.35.7] — 2026-05-29

### Changed
- **tests — DRY the version-lock assertion block into a shared `assert_version_bump` helper** (#231). The identical four-surface version-propagation asserts duplicated across `tests/goal.test.sh` (G20) and `tests/solve-claim.test.sh` are now a single `assert_version_bump <repo_root> <version>` helper in `tests/_lib_assert_structural.sh`. A release bump is now one `<version>`-arg change per call site instead of lockstep multi-form-regex edits across two files — removing the release footgun that previously required hand-editing plain, single-escaped, and double-escaped regex variants in lockstep.

## [0.35.6] — 2026-05-29

### Changed
- **findings-to-issues — accepted-source allow-list is now a single source of truth** (#198; prevents #182-class drift). Extracted `ACCEPTED_SOURCES` as a `frozenset` in `lib/report_primitives.py`; `envelope()` now asserts `source in ACCEPTED_SOURCES` and raises `ValueError` at emit time, so a typo or a new pipeline shipping an un-accepted source fails loudly **where it is emitted** instead of silently filing ZERO issues (the #182 bug: `testers-aggregate` was emitted by `report.py` but missing from the allow-list, so every `/uberdev:testers` run filed nothing). The agent spec's partial source re-enumeration in `agents/findings-to-issues.md` was collapsed to a pointer at the Step-1 closed set, so the 7 sources are enumerated in exactly one place.

### Tests
- New `tests/findings-to-issues.test.sh` Suite 15 cross-consistency gate: asserts the python `ACCEPTED_SOURCES` frozenset equals the agent-spec closed set, every emitter `envelope()` source literal is a member, and `envelope()` raises on a non-accepted source while accepting a member — so the allow-list and the emitters can no longer silently drift.

## [0.35.5] — 2026-05-29

### Fixed
- **cluster-pipeline — hard-fail (not silent-zero) on a crashed Phase-1/2 producer** (#265). `TOTAL` (issues.json) and `POOL_SIZE` (cluster-pool.json) previously used the `jq 'length' … 2>/dev/null || echo 0` idiom, which maps a crashed/partial/0-byte producer to `0` — indistinguishable from a legitimately-empty run (the same masking class fixed for the Phase-4 dispatch count in #263). Both now use the `[ -s ]` + `type=="array"` fail-closed shape (mirroring the Phase-4 `CLUSTERS_N` gate), aborting with a FATAL diagnostic instead of flooring to 0. A legitimately-empty pool still writes valid `[]` and proceeds normally.
- **cluster-pipeline — Phase-4 YAML aggregation emits stderr diagnostics on silent skips** (#265). The python3 aggregation's `except ImportError` (PyYAML missing → empty set), per-file `except Exception` (unparseable `analyses/*.yaml`), and per-cluster `except (TypeError, ValueError)` (non-numeric confidence) blocks each now write a `cluster: WARN …` line to stderr, so an operator can distinguish "0 clusters" from "PyYAML missing / N files unparseable" — without changing the yaml-optional design intent.

### Tests
- New `tests/cluster-pipeline.test.sh` gates **P20** (issues.json) + **P21** (cluster-pool.json), mirroring the P18 verbatim-fence pattern — each asserts hard-fail (rc≠0 + FATAL on stderr + no DISPATCH/output leak) on missing / 0-byte / non-array inputs and correct counts on valid / empty arrays.

## [0.35.4] — 2026-05-29

### Changed
- **goal-pipeline — hoisted all 8 inline `awk` state-reads into `lib/goal-state.sh` helpers** (#229, #237, #230, #234). The awk one-liners in `skills/goal-pipeline/SKILL.md` previously relied on the `-v c1=1 -v c2=2 -v c3=3` renderer-collision workaround (#222); they are now seven sourced helpers — `uberdev_goal_get_issue_state`, `uberdev_goal_issue_ts_in_state`, `uberdev_goal_pr_ts_in_state`, `uberdev_goal_pr_first_ts_in_state`, `uberdev_goal_batch_has_pr`, `uberdev_goal_count_distinct_prs`, `uberdev_goal_count_resolved_issues` — backed by an internal `_uberdev_goal_ts_in_state`. Because `lib/goal-state.sh` is **sourced, never Skill-rendered**, the helpers use clean, semantic `$1`/`$2`/`$3` field refs the renderer cannot corrupt, and the SKILL.md call sites now carry zero awk. The per-site `$ARGUMENTS`-collision rationale collapses to a single anchor on the first-wins helper.

### Fixed
- **goal-pipeline convergence no longer false-fails on macOS** (#229). `uberdev_goal_count_distinct_prs` returns a clean integer; the prior `… | sort -u | wc -l` form padded with leading spaces under macOS/BSD `wc -l`, and the convergence check compares it with `=` (string equality) against a grep-based terminal count — so the padding could falsely block convergence.
- **goal-pipeline surfaces a failed `/review-pr` re-dispatch** (#219). The `_uberdev_goal_dispatch_review_pr` call site in the held-PR poll loop now emits an rc breadcrumb on a genuine dispatch failure (the intentional cap-reached skip stays silent) instead of swallowing the return code.
- **`/review-pr` conflict-file extraction is renderer-safe** (#237). The executed `awk '/^UU / {print $2}'` in `commands/review-pr.md`'s multi-stage-rebase recovery used a bare `$2` the slash-arg renderer would overwrite with the PR-number argv; parameterised to `-v c2=2 … $c2`. A new `R1b` drift-guard in `tests/skill-renderer-awk-collision.test.sh` scans `commands/*.md` so the shape cannot regress (agent system prompts are excluded — they are not positionally substituted).
- **`requesting-code-review` doc example is renderer-safe** (#232). The illustrative SHA-extraction `awk '{print $1}'` in an Example block is now `cut -d' ' -f1` — no `$N`, reads cleanly, immune to the renderer.

## [0.35.3] — 2026-05-29

### Added
- `/uberdev:cluster` (short alias `/ubercluster`) — repo-wide issue similarity
  analyzer and fold-into-lead consolidator. Reduces /goal multi-issue run cost
  by collapsing semantically duplicate finding-issues before /turbo dispatch.
  Three-layer decomposition: `commands/cluster.md` (thin) →
  `skills/cluster-pipeline/SKILL.md` (6-phase directive-emitter) →
  `agents/issue-similarity-analyzer.md` (read-only, `model: inherit`). Hard `--min-confidence 0.85`
  floor under `--execute`; idempotent via HTML-comment marker + `folded` label
  + per-run JSONL ledger. RFC 0010. Closes #247.
- Consolidated `/uberdev:cluster` behavioral test coverage — gates P13–P19:
  Phase 4 proposal generation + dry-run exit, Phase 5 lead-body fold-append,
  Phase 3.5 cross-chunk meta-pass skip/execute/boundary, the Phase 4 dispatch
  hard-fail gate, and the cluster-render schema-validation gate. Closes #257,
  #258, #259.

### Fixed
- **Phase 4 dispatch hard-fails on unreadable `clusters-filtered.json` (Closes #263).**
  The old `jq 'length' … || echo 0` masked a crashed / zero-byte / malformed /
  non-array Phase-4 aggregation as `CLUSTERS=0`, indistinguishable from a
  legitimate empty run. Now requires a non-empty valid JSON array (`[ -s ]` +
  `type=="array"`) and hard-fails (`exit 2`) otherwise; a genuinely empty run
  still writes `[]` → `CLUSTERS=0` and dispatches normally.
- **`cluster_propose.py` validates every cluster's schema before rendering (gate P19).**
  `render_cluster()` coerces `lead`/`members`/`confidence` via `int()`/`float()`;
  a malformed analyzer cluster previously crashed the render loop *after* the
  report header was printed, leaving a partial `proposals.md` indistinguishable
  from a complete one. `main()` now validates all clusters up front and aborts
  (`exit 2`, no partial stdout) on any schema violation — all-or-nothing.
  Surfaced by `/uberdev:review-pr` (type-design lens).

## [0.35.2] — 2026-05-28

### Changed
- **Recorded won't-fix verdict for #240 dispatch `--prompt-file` probe.** The empirical probe at `tests/manual/probe-prompt-file-slash-expansion.sh` was run 2026-05-28 against claude-code 2.1.153.
  - Probe verdict: `INDETERMINATE`. `--prompt-file` is accepted (session backgrounds successfully), but the file body is not promoted to the session-name surface (unlike argv-mode, where the session name = opening message verbatim). The session went idle without the name field diverging.
  - Decision: the natural-language wrapper introduced by PR #238 at the 5 prompt-build callsites (`skills/goal-pipeline/SKILL.md`, `skills/solve-pipeline/SKILL.md` × 2, `lib/goal-state.sh` × 2) remains canonical. `BG_PROMPT_MODE=argv` stays at `lib/dispatch.sh`.
  - Migration targets: the `file`/`stdin` arms in `_uberdev_dispatch_claude_bg` remain pre-wired for a future CLI revision per RFC 0004 §3.4.

### Added
- `tests/manual/probe-prompt-file-slash-expansion.sh` — manual reproducer for the AC1 empirical probe (writes verdict to `${UBERDEV_TMPDIR:-/tmp}/issue-240-probe-verdict.txt`; not wired into CI).

### Notes
- Version bumped to 0.35.2 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

## [0.35.1] — 2026-05-28

### Fixed
- **`/uberdev:goal` fresh-shell `stuck_loop` misfire on cycle 1 (Closes #245).** The goal-pipeline SKILL.md Phase 0 Constants block declared 13 scalar tunables (e.g. `_UBERDEV_GOAL_STUCK_SECS=14400`, `_UBERDEV_GOAL_POLL_SECS=60`, `_UBERDEV_GOAL_SOLVE_TIMEOUT=9000`, `_UBERDEV_GOAL_BODY_CAP=65536`, `FINDING_LABEL='review-pr-finding'`) and 2 regex constants — but every fresh-shell rehydration fence in Phases 1/2/3/4 sources ONLY `lib/goal-state.sh`, never re-executing the Phase 0 block. The first watch-loop check at SKILL.md:411 — `(( now - watch_start >= _UBERDEV_GOAL_STUCK_SECS ))` — saw an unset variable, bash arithmetic coerced to 0 (POSIX.1-2017 §2.6.4), the comparison reduced to `(( elapsed > 0 ))`, and `stuck_loop` fired on iteration 1 (live repro: `/ubergoal 225 226 227` cycle 1 printed `STUCK_LOOP (4h cap)` with elapsed=0 and all 3 issues still in `solving`).
  - `plugins/uberdev/lib/goal-state.sh` — added 12 defaulted-assignment declarations (`: "${VAR:=default}"`, the same idiom proven on `_UBERDEV_GOAL_STUCK_DIALOG_SECS:=60` from PR #221) for the 10 SKILL.md-declared integer scalars + `FINDING_LABEL` + the latent `_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:=3` (used by `_uberdev_goal_dispatch_review_pr` via `:-3` fallback but never declared until now). Added 2 plain-assignment regex declarations (`BLOCKS_LINE_REGEX`, `FINDING_FINGERPRINT_REGEX`) — `:=` is intentionally NOT used on the regexes (Q2 security advisory: defaulted-assignment would let a hostile env override regex shape and widen the ReDoS attack surface without a validator). All 14 new declarations live after the `_UBERDEV_GOAL_STATE_LOADED=1` marker (within the guarded first-source-per-process region per RFC 0005 D19; relies on each fresh-shell rehydration fence being a new process), immediately after the line-101 precedent.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` — Constants block kept byte-identical (tests G24/G28/G34 grep the literals verbatim — partial change would red CI); added a one-line prose pointer above the block declaring `lib/goal-state.sh` as the runtime SSOT and the SKILL.md block as the documentation SSOT.
  - Tests: `tests/goal.test.sh` G20 ratcheted to 0.35.1; new G40 regression test sources ONLY `lib/goal-state.sh` in a fresh `bash -c` and asserts `_UBERDEV_GOAL_STUCK_SECS == 14400` — proves the fix on the exact path that fails today. `tests/solve-claim.test.sh` version block ratcheted 0.35.0 → 0.35.1.

### Notes
- Version bumped to 0.35.1 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant (memory `project_uberdev_version_lock_tests`).
- Out of scope: consumer-call-site SSOT migration for the two regex constants (`_uberdev_goal_parse_blocks_line` and `_uberdev_goal_extract_fingerprint` still hardcode the literal — deferred per Q2); `_uberdev_goal_validate_int` hardening for arithmetic uses of the integer constants (latent env-injection surface, pre-existing); a fuller Phase-1→2→3→4 fresh-shell-fence integration test (G40 covers the primary scalar; deeper test logged as a follow-up).

## [0.35.0] — 2026-05-28

### Changed
- **Models:** `/turbo`, `/solve`, and `/goal` now dispatch every agent on `claude-opus-4-8[1m]` (was `claude-opus-4-7[1m]`).
- **Agents:** the 22 former-`sonnet` subagents plus the 9 `opus` subagents and 4 pipeline skills now use `model: inherit`, so the whole subagent tree runs on the session's Opus 4.8 1M model. The 6 `haiku` agents and 4 pre-existing `inherit` agents are unchanged. Former-`sonnet` agents carry a `# WAIT 4.8 sonnet` comment to revisit when Sonnet 4.8 ships.
- Swept stale Sonnet / Opus-4.7 model references from agent descriptions, the `/issue` command docs, the `orchestrator` and `post-impl-review` skills, and the README; `plan-writer` no longer pins its internal research subagents to Sonnet.

## [0.34.13] — 2026-05-28

### Fixed
- **`/uberdev` dispatch pairs `--dangerously-skip-permissions` with `--permission-mode bypassPermissions` so the bg UI cycle ring no longer lands on `auto` (Closes #246).** The PR #243 collapse populated `PERM_FLAG` with `--dangerously-skip-permissions` alone. In Claude Code 2.1.152+, `--dangerously-skip-permissions` bypasses permission *checks* but does NOT set `--permission-mode`; the bg session's UI cycle ring is driven by `--permission-mode`, and without an explicit setting it defaults to `auto` — exactly the mode that silently breaks Search and other agent tools (see memory `feedback_permission_tier_bypass_default`). Caught while reviewing `/ubergoal 225 226 227` cycle 1 — the bg session status bar showed `↗ auto mode on` even though argv passed `--dangerously-skip-permissions`. This is the missing other half of PR #243.
  - `plugins/uberdev/lib/dispatch.sh` `uberdev_dispatch_resolve_env` — both `PERM_FLAG=( --dangerously-skip-permissions )` sites (the `SKIP_PERMISSIONS=1` branch and the `AUTO_PERMISSIONS=1` branch) now resolve to `PERM_FLAG=( --dangerously-skip-permissions --permission-mode bypassPermissions )`. Belt-and-suspenders: `bypassPermissions` pins the cycle-ring position so the UI doesn't default to `auto`; `--dangerously-skip-permissions` short-circuits the actual permission-check codepath. The two flags target different mechanisms and are not redundant. Affects all three dispatch backends (`_uberdev_dispatch_claude_bg`, `_uberdev_dispatch_background`, `_uberdev_dispatch_wezterm`) because they all expand `"${PERM_FLAG[@]}"` from the same resolver.
  - Tests: `tests/dispatch-claude-bg.test.sh` — three behavioural cases ratcheted (D-perm / D-skip / D-precedence) from the bare-skip literal to the new paired literal; structural-grep `perm_flag_count` and the negative auto-mode guard updated; new bare-skip regression guard (`bare_skip_count == 0`) locks the pairing so the bare form cannot silently reappear.
  - `tests/goal.test.sh` G20 + `tests/solve-claim.test.sh` version-bump block ratcheted to `0.34.13`.

### Notes
- Version bumped to 0.34.13 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Pairs with the v0.34.9 cut that shipped PR #243 (the AUTO_PERMISSIONS collapse). Together, both halves of the bypass-tier contract are restored: argv flag AND cycle-ring position.

---

## [0.34.12] — 2026-05-28

### Fixed
- **`/uberdev:goal` mis-classifies orchestrator-driven close-without-PR as `failed` (Closes #249).** `/uberdev:orchestrator` (dispatched by `/goal` Phase 1 via `claude --bg`) can legitimately close a GitHub issue without producing a PR when the finding is stale, already-resolved, or non-actionable (concrete prior cases: #226 closed as "verified already resolved by PR #224", #227 closed as "stale finding on closed PR #223"). Phase 2 step 2a was checking only (a) does a PR exist, (b) is the solver still busy, (c) elapsed vs `_UBERDEV_GOAL_SOLVE_TIMEOUT` — it never probed the issue's GitHub `state`. A legitimately closed-without-PR issue spun in `solving` for ~150 minutes and was misleadingly marked `failed` rather than terminated cleanly.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` Phase 2 step 2a — inside the `else` branch (no PR yet, agent idle), inserted a `gh issue view --json state` probe. When `state == "CLOSED"` (uppercase, gh GraphQL semantics), transitions `solving → resolved-by-no-action` and emits the new `goal_issue_closed_without_pr` audit event. Non-zero `gh` rc falls through to the existing 150-min `SOLVE_TIMEOUT` backstop (RFC 0005 B6 — surface gh failures, never cascade into false terminal transitions). Stderr breadcrumb on failure.
  - `GOAL_ISSUE_STATE_ENUM` extended from 6 to 7 states (`+resolved-by-no-action`). Phase-2a skip-check widened to `pr-pushed|resolved|resolved-by-no-action|failed` — required for correctness; without it, an issue already in the new state would be re-probed every poll tick.
  - `GOAL_AUDIT_EVENT_ENUM` extended from 11 to 12 events (`+goal_issue_closed_without_pr`). Audit-event payload: `{goal_id, issue, detected_at}` — all three values upstream-validated, defence-in-depth `_uberdev_goal_validate_int "$issue"` before the `gh` call (T3 mitigation).
  - `plugins/uberdev/lib/goal-state.sh` — new arc `solving → resolved-by-no-action` in `uberdev_goal_issue_state_transition` case; new event case-arm `goal_issue_closed_without_pr)` in `uberdev_goal_audit` case. Both omissions would silently strand (rc=2 or rc=1) without the explicit arms — BT84 / BT85 are the only protection against silent strand.
  - `print_summary` `issues_resolved` awk filter broadened to count both `resolved` and `resolved-by-no-action`. Phase 3 terminal-set logic is PR-count driven and stays unchanged — an issue with zero PRs contributes zero to `all_pr_count`, so `0 == 0` already converges cleanly when the active-count drains.
  - Tests: `tests/goal.test.sh` G3 (issue-state enum), G11 (audit-event presence list — extended from 11 to 12), G24b (literal enum string), G20 (release-ratchet) updated to the new strings; new G39 structural-grep locks the SKILL.md probe call-site (4 sub-asserts: probe line, uppercase CLOSED check, transition arc call-site, audit event emission); new behavioural tests BT84 (`solving → resolved-by-no-action` arc returns rc=0 + TSV state assertion + negative regression guard on the previously-rejected `solving → resolved` direct arc) and BT85 (`uberdev_goal_audit goal_issue_closed_without_pr '...'` writes a JSONL line, rc=0, numeric `issue` field + negative regression guard on unknown events) added post-BT83. `tests/solve-claim.test.sh` version-bump block ratcheted to `0.34.12`.
  - RFC `docs/rfc/0005-uberdev-goal.md` §9 — new D249a addendum row documents the new event, the new state, the skip-check widening, and the `gh` rc no-signal contract. Bug-fix scope under §2.3 (the auto-merge carve-out): no new RFC.

### Notes
- Version bumped to 0.34.12 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Renumbered from the original PR target (0.34.10) to 0.34.12 after rebase onto main absorbed v0.34.10 (#244) and v0.34.11 (#250). PR #250's `/uberdev:orchestrator` direct-dispatch change is preserved intact (G38 + BT83 ratchets unchanged); this PR's #249 fix is strictly additive on top.

---

## [0.34.11] — 2026-05-28

### Fixed
- **`/uberdev:goal` Phase 1 now dispatches `/uberdev:orchestrator --turbo` directly, skipping the `/turbo` wrapper (Closes #248).** The previous dispatch chain spawned two `claude --bg` sessions per issue (`goal → bg(/turbo) → bg(/orchestrator)`). Phase 1 now invokes `/orchestrator` directly via `claude --bg`, collapsing to a single bg session per issue and halving per-issue boilerplate cost; scales linearly with `--max-parallel`.
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` Phase 1 (search for `Invoke the slash command /uberdev:orchestrator`) — the `printf` body now reads `Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #%s now. …`; the `--backend=%s` arg flag is dropped because `/orchestrator` does not accept it. Backend now forwards exclusively via the `UBERDEV_RESOLVED_BACKEND` env-var that Phase 0 exports — `claude --bg` inherits the parent shell's full env table, so the env-var path is the canonical mechanism (RFC 0005 D15 single-resolution invariant preserved).
  - Side-effect: `SKIP_PERMISSIONS=1` (set by `/goal` Phase 0) now reaches the orchestrator child unimpeded. Previously, the intermediate `/turbo` wrapper's defensive `unset SKIP_PERMISSIONS` (in `commands/turbo.md`) actively conflicted with `/goal`'s autonomous-loop opt-in; removing the wrapper layer closes that latent bug. Standalone `/turbo` still keeps the defensive `unset` to guard against shell-rc / stale-session pollution.
  - Tests: `tests/goal.test.sh` — `G15.backend-forwarding` re-pointed at the new env-propagation comment (no longer references the removed `--backend=` arg flag); new `G38.goal-phase-1-orchestrator-dispatch` shape gate (assert_grep + assert_no_grep) locks the orchestrator-direct invocation against silent regression.
  - No user-facing CLI surface change. Standalone `/uberdev:turbo` users are unaffected.

### Notes
- Version bumped to 0.34.11 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.10] — 2026-05-28

### Fixed
- **Skill-loader $N substitution corrupts `emit_topic_log()` in orchestrator (#225).** Same bug class as #222 (awk one-liners), different surface — the Claude Code Skill renderer text-substitutes positional non-flag args of `$ARGUMENTS` into the entire rendered SKILL.md body, including inside bash function bodies. The Phase 1 fanout's `emit_topic_log()` helper used bash positional refs, so all 12 call sites were silently emitting the same render-time substitution (e.g. `agent=research-solve status=GH note=issue` on `/uberdev:orchestrator --turbo solve GH issue #225`) instead of binding at call time. The per-topic observability log was effectively useless: every line emitted the same agent/status/note triple regardless of which topic was being dispatched or whether it was cache-reused vs fresh-dispatched.
  - `plugins/uberdev/skills/orchestrator/SKILL.md` — `emit_topic_log()` now reads positional args via the `${@:N:1}` array-slice form. The slice has no dollar-immediately-followed-by-digit substring (the digit follows `:`, not the dollar), so the renderer leaves it verbatim and bash evaluates the slice at call time. The local variable holding the `status` arg is named `topic_status` rather than `status` because `status` is a read-only special parameter in zsh (the Bash-tool default shell on macOS) — `local status="…"` aborts the function with `read-only variable: status`. Added a comment header naming the renderer-substitution mechanic, the symptom, and the safe form, plus the zsh-special-parameter caveat. The two awk-surface sites in `emit_topic_log`'s neighbourhood (the cached-research staleness check and the multi-line files-investigated parse) were already fixed in PR #224 (the `-v cN=N` + `$cN` form) — this PR's fix is the third surface from issue #225's deferred finding.
  - `tests/skill-renderer-awk-collision.test.sh` — extended from 4 to 9 assertions. R4 scans `orchestrator/SKILL.md` for any bare `$N` and red-CIs on a regression, sharing `BASH_GUARD_REGEX` as SSOT with the R5 inverse fixtures. R5.bad + R5.safe are the inverse fixture proofs (a naïve bash function body MUST be flagged; the recommended `${@:N:1}` form MUST NOT be flagged), mirroring the R2/R3 pattern from the awk surface. R6.bash + R6.zsh execute the live `emit_topic_log` definition extracted from `orchestrator/SKILL.md` under both shells and assert the emitted log line matches the schema — this catches cross-shell regressions (such as the zsh-reserved `status` local-var bug that surfaced in /review-pr review of this PR) that static regex scans miss. The test now covers both #222 (awk) and #225 (bash) bug classes in a single drift guard. Scope is intentionally narrow to `orchestrator/SKILL.md` — the broader bash-positional sweep across other pipeline SKILL.md files (7+ known sites in solve/goal/finish/testers/ubersimplify) is documented in the test header comment as a follow-up and NOT enforced here (would red CI on those known-vulnerable sites until they too are fixed).

### Notes
- Version bumped to 0.34.10 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.9] — 2026-05-27

### Changed
- **Collapsed the `AUTO_PERMISSIONS` middle tier into `--dangerously-skip-permissions` (post-#241 follow-up).** `--permission-mode auto` is silently broken in practice — Claude Code's auto-mode classifier refuses some agent tools (notably Search) both inside and outside cmux, leaving operators in a half-broken state that defeated the whole point of `/turbo --auto` / `/solve --auto`. The middle tier was dead weight, so `AUTO_PERMISSIONS=1` now resolves to the same `--dangerously-skip-permissions` flag as `SKIP_PERMISSIONS=1`. The env-var name is preserved for backward compat with `/turbo --auto`, `/solve --auto`, and any external callers.
  - `lib/dispatch.sh:uberdev_dispatch_resolve_env` — the `elif [[ "$AUTO_PERMISSIONS" == "1" ]]` branch now sets `PERM_FLAG=( --dangerously-skip-permissions )` instead of `PERM_FLAG=( --permission-mode auto )`. The if/elif ordering is preserved for audit-log clarity (which env var the caller set), but both branches now emit the same flag.
  - `solve-pipeline/SKILL.md` — the `PERM_DESC` strings updated to `bypass (--dangerously-skip-permissions; <TIER>_PERMISSIONS tier ...)`; the tier-name suffix lets post-hoc grep attribute the bypass to `/goal` (SKIP) vs `/turbo --auto` / `/solve --auto` (AUTO). The flat-var if/else form is preserved (zsh-NOMATCH regression guard, audit-fixups.test.sh C8).
  - `commands/solve.md` — the `--auto` flag description updated to reflect the remap; documents that the trade-off is broad (dangerous tools no longer prompt) and recommends use only when the issue is unattended-friendly.
  - Tests: `dispatch-claude-bg.test.sh` D-perm + D-precedence assertions updated to expect `--dangerously-skip-permissions` from `AUTO_PERMISSIONS=1`; new structural assertion that exactly 2 `PERM_FLAG=( --dangerously-skip-permissions )` sites exist in `dispatch.sh` (SKIP + AUTO branches, both bypass); new regression guard that `PERM_FLAG=( --permission-mode auto )` does NOT re-appear at runtime. `solve-pipeline-zsh.test.sh` R3 fixture rewritten to test the single-token `--dangerously-skip-permissions` argv form + auto-mode-collapse regression guard (the two-token zsh-array-word-split coverage now lives in R2's `--effort max` path). `audit-fixups.test.sh` PERM_DESC asserts updated to the new bypass strings.
  - Trust-boundary unchanged — the orchestrator's `<external-untrusted-input>` trust-wrap is unaffected by the `--permission-mode` argv flag remap. Residual security risk is explicitly accepted (continuation of #241 stance): the alternative (broken agents under `--permission-mode auto`) is worse.

### Notes
- Version bumped to 0.34.9 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.8] — 2026-05-27

### Fixed
- **`/uberdev:goal` stalls on cmux-mediated environments — bg agents flap busy/idle without producing PRs (Closes #241).** On macOS + cmux, dispatched bg `/turbo` agents stall on the first `Bash` tool call ("The user doesn't want to proceed with this tool use") because cmux's `PermissionRequest` hook (injected via `--settings <blob>` into the bg session's `respawnFlags`) shadows the user's own `~/.claude/settings.json` and refuses the prompt after a 125 s timeout. The contrast run with a manual `claude --bg --dangerously-skip-permissions` ran cleanly with zero rejections — confirming the strict bypass is the unblocking flag.
  - Added a third `SKIP_PERMISSIONS` env-var tier to `uberdev_dispatch_resolve_env` (`lib/dispatch.sh`) with strict precedence over `AUTO_PERMISSIONS`. Maps to `PERM_FLAG=( --dangerously-skip-permissions )` when `${SKIP_PERMISSIONS:-0} == 1`. Literal `PERM_FLAG=()` and `PERM_FLAG=( --permission-mode auto )` lines preserved verbatim for structural-shape tests.
  - `goal-pipeline/SKILL.md` Phase 0 step 4 exports `SKIP_PERMISSIONS=1` unconditionally — the operator's `/uberdev:goal` invocation IS the opt-in to autonomous-convergence; no per-run flag.
  - Both `BG_TURBO_ENV` blocks (`_uberdev_dispatch_claude_bg` and `_uberdev_dispatch_background`) append `SKIP_PERMISSIONS=1` when set, propagating the env-var across the `env(1)` boundary so nested child dispatches also resolve to the bypass flag. Gates on `${SKIP_PERMISSIONS:-0}` directly (NOT on `AUTO_MODE`) — the semantics are independent of turbo-mode and the defensive `unset` in `/turbo`/`/solve` is the pollution gate.
  - Defensive `unset SKIP_PERMISSIONS` in `commands/turbo.md` and `commands/solve.md` mirrors the #97 `UBERDEV_TURBO` hardening pattern — prevents shell-rc / stale-session pollution from silently elevating bare invocations.
  - New "## Permission requirements (cmux/hooks caveat)" section in `commands/goal.md` documents the `--settings`-shadowing failure mode and the env-var path that actually unblocks the loop.
  - Tests: D-skip + D-precedence behavioural tests (mirror D-perm template); structural greps for `PERM_FLAG=( --dangerously-skip-permissions )` and `BG_TURBO_ENV+=( SKIP_PERMISSIONS=1 )` in both dispatch arms; G20c assertion for `export SKIP_PERMISSIONS=1`; T-no-skip-turbo / T-no-skip-solve negative-test assertions; D-iso unset list updated to include `SKIP_PERMISSIONS`.
  - Trust-boundary unchanged. The orchestrator's `<external-untrusted-input>` trust-wrap (emitted at prompt-construction time, unaffected by the `--permission-mode` argv flag) remains the defence against prompt-injection. Residual security risk is explicitly accepted as the cost of autonomous-convergence; the alternative (perpetually stalled `/goal`) is worse.

### Notes
- Version bumped to 0.34.8 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.

---

## [0.34.7] — 2026-05-27

### Fixed
- **`/uberdev:goal` Phase-1 skip-check re-dispatched issues on leaf-side pre-state-write crashes (Closes #236).** The Phase-1 skip-check only matched `solving|pr-pushed` — states the parent wrote AFTER `uberdev_dispatch_one` returned. Any leaf-side failure between the spawn returning success and the post-spawn `solving` write (network blip mid-init, OOM, agent timeout before first state write, the argv-slash bug from #235, any future CLI regression) left the TSV row in its pre-dispatch `input` default, indistinguishable from "never attempted". The next cycle re-read the TSV, fell through the skip-check, and dispatched the issue a second time — producing TWO `solve-issue-N/` worktrees, two zombie `claude agents` sessions, and two `/review-pr` runs against (eventually) two duplicate PRs. Closed by adding a `dispatched` pre-spawn guard state: the parent now writes `input → dispatched` BEFORE calling `uberdev_dispatch_one` and the skip-check matches `dispatched|solving|pr-pushed`, so a leaf failure between spawn and the post-spawn `solving` refinement still leaves a row the next cycle's skip-check sees. The post-spawn `dispatched → solving` transition is now a refinement rather than the load-bearing in-flight signal. On `uberdev_dispatch_one` rc!=0 (hard error, not `claim_collision`), the parent transitions `dispatched → failed` before exiting so the TSV reflects the true terminal state.
  - State machine extended (`lib/goal-state.sh:430` + RFC 0005 §3.2.2 D2): 6 states (`input → dispatched → solving → pr-pushed → resolved`) with `dispatched → failed`, `solving → failed`, `pr-pushed → failed` sinks. `input → solving` retained for the legacy single-write path; `input → dispatched` and `dispatched → solving|failed` added.
  - Enum constant (`GOAL_ISSUE_STATE_ENUM`) and Phase-1 prose updated.
  - BT80-BT82 (goal.test.sh) cover the 3 new valid transitions, 5 new invalid-transition guards, and the leaf-crash-pre-state-write simulation (TSV row written `dispatched`, skip-check matches, no re-dispatch on cycle 2). G24b grep-tests the SKILL.md shape (enum + skip-check + pre-spawn write line-order vs `uberdev_dispatch_one` call + dispatch-failure cleanup).
  - Companion #235 (argv-slash non-expansion) is one trigger of this surface and is resolved CLI-side; this fix closes the structural weakness so future leaf failures cannot reproduce the double-spawn.

### Notes
- Version bumped to 0.34.7 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Landed via rebase+renumber after 0.34.6 (PR #238, dispatch-argv natural-language fix) collided on the same version slot — `/merge` autopilot caught the collision before publication.

---

## [0.34.6] — 2026-05-27

### Fixed
- **`claude --bg` argv-mode slash-command never expanded — `/goal` → `/turbo` leaf silently died (Closes #235).** `claude --bg ... -- "<prompt>"` passes the prompt as the first user message of the spawned agent. Since CLI 2.1.139 (the version `--bg` first shipped) argv-supplied opening messages have NOT been slash-expanded by the child, so a prompt body opening with `/uberdev:turbo …` was silently treated as natural language and the child agent answered conversationally instead of running the command. Every medium-tier `/goal` → `/turbo` → `/orchestrator` chain died at the prompt-delivery boundary; the resulting silent-leaf failure cascaded into double worktrees / double reviews when goal-pipeline's Phase-1 skip-check saw no `solving` row and re-dispatched on the next cycle. Five prompt-build callsites are rewritten to wrap the slash invocation in a natural-language imperative (`Invoke the slash command /uberdev:… now. Do not respond conversationally — execute it.`) so the child reads the body as an instruction it must act on, not a question to discuss:
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md:240-242` — `/uberdev:turbo` dispatch.
  - `plugins/uberdev/skills/solve-pipeline/SKILL.md:776,778` — medium-tier `/uberdev:orchestrator` dispatch (both turbo and interactive arms).
  - `plugins/uberdev/lib/goal-state.sh:1267` — `_uberdev_goal_dispatch_review_pr`.
  - `plugins/uberdev/lib/goal-state.sh:1311` — `_uberdev_goal_dispatch_merge`.
- **`uberdev_goal_review_pr_in_flight` probe regex relaxed (companion fix; sibling-applied via Phase 1 of /review-pr).** `claude agents --json` derives `.name` from the prompt body verbatim, so the anchored regex `^/uberdev:review-pr <pr>` could not match the new natural-language wrapper. Dropped the leading `^` to a substring match in `plugins/uberdev/lib/goal-state.sh`; the trailing `($|[^0-9])` boundary stays as the load-bearing anti-collision guard (rejects 21 matching 218, 42 matching 421). Without this companion fix the in-flight gate landed by #220 (PR #221, v0.34.4) would silently no-op for every PR dispatched post-#235. Added `tests/goal.test.sh` BT76.match-nl-wrapper case + renamed BT76.no-match-421-anchor → BT76.no-match-421-boundary + G32.name-regex → G32.substring-name-regex for self-documenting naming consistency.

### Added
- `tests/dispatch-prompt-no-bare-slash.test.sh` — drift-guard scanning the three prompt-build callsite files (`goal-pipeline/SKILL.md`, `solve-pipeline/SKILL.md`, `lib/goal-state.sh`) for any `printf` / `echo` writing a body that opens with `/uberdev:`. R2 fixture proves the regex flags vulnerable shapes; R3 inverse fixture proves the natural-language imperative shape is NOT false-positived. Wired into both ubuntu and windows CI matrices.

### Notes
- Version bumped to 0.34.6 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Scope strictly option 3b from the issue (lowest-blast-radius rewrite). Switching `BG_PROMPT_MODE` to `--prompt-file` (option 3a) requires verifying the file-mode arm re-evaluates the body through the interactive parser on 2.1.152 and is deferred. Symptom B hardening (state-transition-on-dispatch, label-probe skip-check) per issue §5 is independently scoped.

---

## [0.34.5] — 2026-05-27

### Fixed
- **Skill renderer corrupted awk `$0`-`$9` field refs across 6 SKILL.md files (Closes #222).** The Claude Code Skill loader substitutes positional non-flag args of `$ARGUMENTS` into the entire SKILL.md body, **including inside single-quoted awk one-liners AND multi-line awk script bodies**. `/ubergoal all gh issues` rendered `awk '$1==p && $2=="x"{t=$3}'` as `awk 'gh==p && issues=="x"{t=}'` (or `'219==p && 198=="x"{t=}'` for numeric args), producing false convergence (`all_pr_count=1` regardless of real PR set), bogus `FAILED` transitions (every `dispatch_ts` returned 0), and broken state-skip gates. The same class also bit `$0` (the renderer substitutes the first positional non-flag into `$0`), which silently broke `/turbo 5 6 7` multi-issue dedupe (`awk '!seen[$0]++'` rendered as `!seen[5]++`, dropping every issue past the first). 14 awk sites total across 6 SKILL.md files were rewritten to use parameterised field refs (`-v cN=N` + `$cN`) so the renderer cannot touch them — the `$cN` form is not a positional shell reference and the renderer leaves it untouched:
  - `plugins/uberdev/skills/goal-pipeline/SKILL.md` — 8 sites (lines 221, 353, 367, 387, 461, 680, 958, 1061) on `$1`/`$2`/`$3`.
  - `plugins/uberdev/skills/orchestrator/SKILL.md` — 2 sites (line 199 single-line `$2`, line 225 multi-line `$1`) plus matching doc at line 279.
  - `plugins/uberdev/skills/requesting-code-review/SKILL.md` — 1 site (line 56) on `$1`.
  - `plugins/uberdev/skills/solve-pipeline/SKILL.md` — 1 site (line 93) on `$0`.
  - `plugins/uberdev/skills/merge-pipeline/SKILL.md` — 1 site (line 809) on `$0`.
  - `plugins/uberdev/skills/finish-branch/SKILL.md` — 1 site (line 162) on `$0` (3 references in one awk).

### Added
- `tests/skill-renderer-awk-collision.test.sh` — drift-guard scanning every `plugins/uberdev/skills/*/SKILL.md` for awk script bodies containing bare `$N` field refs (0-9). Uses a flattened-file scan (`tr '\n' ' '`) to catch multi-line awks (orchestrator/SKILL.md:225-class regressions that line-anchored greps silently pass), with regex constrained to `awk[^']*'[^']*\$[0-9][^c]` so it matches only inside the FIRST single-quoted body after `awk` (prevents greedy `.*` from spanning across the whole flattened file). R2 fixture proofs cover both single-line AND multi-line vulnerable shapes; R3 inverse fixture covers the full `$c0`/`$c1`/`$c2`/`$c3` safe set. Wired into both ubuntu and windows CI matrices.

### Notes
- Version bumped to 0.34.5 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- Scope expanded mid-review (from `$1`-`$3` to `$0`-`$9`) after the `/review-pr` Phase 1 general-lens reviewer surfaced the orchestrator multi-line awk site missed by the original line-anchored regex; same root cause, so the three additional `$0` sites are folded into this PR rather than deferred.

---

## [0.34.4] — 2026-05-27

### Fixed
- fix(goal): bump review-grace default to 60m + add `goal.review_grace_secs` config key (Closes #220, AC ❶)
- fix(goal): in-flight `/review-pr` gate before `/merge` and stale-arm re-dispatch — emits `goal_merge_deferred` (Phase 2c gate) and `goal_review_pr_deferred` (Phase 2b gate) (Closes #220, AC ❷)
- fix(goal): stuck-on-dialog detector + `agent_stuck_on_dialog` circuit-breaker (Closes #220, AC ❸)
- fix(goal): Phase 3 rollover preservation — merges Phase-1 carry-over instead of overwriting; adds `rolled_over` to `goal_cycle_completed` audit (Closes #220, AC ❹)

### Added
- feat(goal): zombie reaper on Ctrl-C / SIGTERM / circuit-breaker — emits `goal_reaper_kill` / `goal_reaper_skipped` (Closes #220)

### Notes
- Version bumped to 0.34.4 across `plugin.json`, `marketplace.json`, the README badge, `CHANGELOG.md`, `tests/goal.test.sh` G20, and `tests/solve-claim.test.sh`. Atomic version-lock surfaces — partial bump is a red CI invariant.
- RFC 0005 §9 D-code addendum block D220a–D220h documents all enum amendments. No new RFC required (bug-fix scope under §2.3 carve-out).

---

## [0.34.3] — 2026-05-26

### Fixed
- **`tests/*.test.sh` source sites of `_lib_assert_structural.sh` were unguarded, so a missing or unreadable helper could yield a vacuous-green run (#209).** The suite uses the deliberate `set -u; set -o pipefail` + manual PASS/FAIL-counter convention (NOT `set -e` — see `install.test.sh:26-29` for the rationale): when `source` of the shared helper failed, the subsequent `assert_in_section` / `assert_subagent_type` / `assert_count` calls then exited 127, but execution continued and the test could still `exit 0` if its locally-defined `assert_grep` checks all passed. Only latent today because the helper is a committed file (always present after `actions/checkout`); became slightly more consequential once PR #208 wired the structural tests into CI. Fix: append the existing FATAL-preflight convention (`|| { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }`) to every `source` / `.` of the helper across the 9 affected files (`code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `goal-batch-barrier`, `post-impl-review`, `review-pr-phase3-ci`, `review-pr`, `simplify`, `trust-trail-evaluator`). New structural drift-guard `tests/test-harness-source-guards.test.sh` (9 assertions; auto-discovers any current or future sourcing file via the shell glob and enforces the literal FATAL message contract). Wired into both ubuntu + windows CI matrices. Behavioral verification: rename the helper aside, run each guarded test, observe rc=2 with the FATAL message on stderr — confirmed across all 9 files.

### Changed
- Version bumped to 0.34.3 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`). Re-numbered from #218's original 0.34.1 to avoid collision with #216 + #217 (PR landing order: #216 → 0.34.1, #217 → 0.34.2, #218 → 0.34.3).

## [0.34.2] — 2026-05-26

### Fixed
- **`lib/goal-state.sh` `_uberdev_goal_dispatch_review_pr` + `_uberdev_goal_dispatch_merge`: guard the `uberdev_dispatch_one` lib/dispatch.sh dependency (#207, same latent-crash class as #195).** Both helpers now run a `command -v uberdev_dispatch_one` preflight after argument validation and BEFORE any counter-write or `mktemp`; on a missing dep they fail loud with the distinct dep-missing rc=4 and a `goal-state:` diagnostic naming the symbol, instead of crashing mid-dispatch on a bare `command not found` after the per-PR attempt counter had already been incremented (phantom attempt with no actual dispatch). The "External imports" header at the top of `goal-state.sh` consolidates both dispatch-lib symbols (`_uberdev_dispatch_prepare_tmp_target`, `uberdev_dispatch_one`) under one paragraph; `_uberdev_goal_dispatch_merge` also reorders `_uberdev_goal_validate_id` above the `mktemp` so the id-validate failure path no longer leaks a stray prompt file. New `tests/goal-dispatch-helpers.test.sh` covers the rc=4 + diagnostic + no-CNF-leak + no-stray-file negative cases (fresh `bash -c` without dispatch.sh) plus a stub-based positive case proving both helpers reach `uberdev_dispatch_one` with the `(pr, "small", prompt_file)` shape when the dep is present. Wired into both ubuntu + windows CI matrices.

### Changed
- Version bumped to 0.34.2 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`). Re-numbered from #217's original 0.34.1 to avoid collision with #216 (PR landing order: #216 → 0.34.1, #217 → 0.34.2, #218 → 0.34.3).

## [0.34.1] — 2026-05-26

### Added
- **`tests/ci-wiring.test.sh` — drift-guard for `.github/workflows/test.yml` (#210; prevents #196 recurrence).** Converts the existing SYNC convention between the `shape-checks` (ubuntu) and `shape-checks-windows` jobs into an enforced invariant. Asserts five locks: W1 every `tests/*.test.sh` on disk is wired into the ubuntu job; W1b ubuntu has no references to nonexistent test files; W2 windows is a (non-strict) subset of ubuntu; W3 windows has no phantom references; W4 (ubuntu − windows) equals the canonical `# === BEGIN ci-wiring windows-skip-list ===` marker block now embedded in the windows job's comment header. A new `tests/*.test.sh` committed without being wired into the ubuntu job — or a Unix-only fixture added without an entry in the marker block — now reds CI immediately. Portable: bash + awk + grep + sed + sort + comm, runs in both shape-checks jobs (ubuntu-latest native bash + windows-latest Git Bash). Wired as the FIRST entry in each job's `run:` block so a wiring drift fails fast.

### Changed
- Version bumped to 0.34.1 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.34.0] — 2026-05-26

### Added
- **`/uberthink` — read-only cross-domain ideation engine.** Spawns an agent fleet (frame → generator × personas → moderator → synthesizer × {weave/crossover/mutate} → falsifier × {steelman/premortem/redteam/physics} → arbiter) across parallel evolutionary "islands" with a genetic loop-back (cap 3) for fixable kills. Emits a 4-axis ranked dossier with a 🌙 Moonshot lane (Novelty × Impact Pareto) + files top ideas as GitHub issues. Flags: `--islands N` (default 2), `--handoff` (auto-invoke `/uberdev:brainstorm` on the #1 design), `--no-issues`, `--max-new N` (default 3). Cost: ~K × 15× a normal chat. RFC: `docs/rfc/0009-uberthink-ideation-engine.md`.

### Changed
- Version bumped to 0.34.0 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).
- `tests/uberthink.test.sh` and `tests/uberthink-report.test.sh` wired into the CI matrix (ubuntu-only, alongside the other python3-dependent fixtures).

## [0.33.20] - 2026-05-26

### Added
- `/goal` config keys `goal.max_parallel` (`UBERDEV_GOAL_MAX_PARALLEL`, `--max-parallel=N`, default 3, range 1–10) and `goal.barrier_timeout_s` (`UBERDEV_GOAL_BARRIER_TIMEOUT_S`, `--barrier-timeout=N`, default 14400 s = 4h, range 60..86400).
- Three new public helpers in `lib/goal-state.sh`: `uberdev_goal_register_batch_pr`, `uberdev_goal_batch_all_terminal`, `uberdev_goal_batch_unblock_wait_clear`. RFC 0005 §9 D-211a/b/c.
- New batch-registry sidecar `goal-<id>-batch-prs.tsv` (per-PR rows with `pr<TAB>issue<TAB>dispatch_ts<TAB>terminal_state`); cleaned up by `uberdev_goal_cleanup_run_state`.
- **B8/B9 behavioral test coverage for `/goal` cap-rollover and wall-clock barrier breaker (#214; supersedes #213).** Added `uberdev_goal_barrier_breaker_check` helper to `lib/goal-state.sh` (replaces ~12 lines of inline elapsed-time math in `goal-pipeline/SKILL.md` Phase 2c); helper preserves the exact prior audit payload (`reason=stuck_loop`, `phase=merge_barrier`, `elapsed_s`, `pending_prs`). Two new test blocks: B8 cap-rollover (MAX_PARALLEL=3 vs 5-issue queue → 3 dispatched, 2 rolled over) and B9 wall-clock barrier (positive fire at elapsed≥timeout, negative no-fire under threshold, zero-start no-fire). Wired `tests/goal-batch-barrier.test.sh` into both ubuntu + windows CI matrices. G25/G28 shape-grep guards retained.

### Changed
- `/goal` per-cycle `/turbo` dispatch is now capped at 3 by default (previously uncapped); queue overflow rolls to the next cycle without re-claim collisions.
- `/merge` no longer fires per-PR the instant a PR turns GREEN; `/goal` holds until every PR in the cycle's batch is in a terminal state. Manifest-collision PRs (e.g. version-bump triplet) merge sequentially in PR-number-ascending order with `git fetch origin main` + rebase between each.
- Wall-clock breaker on the new merge barrier (4h default) escalates to the existing `stuck_loop` circuit-breaker reason — no new reason added, no `GOAL_CIRCUIT_BREAKER_REASONS` enum mutation.

## [0.33.19] - 2026-05-26

### Added
- **Wired the 10 orphaned `tests/*.test.sh` files into the CI matrix (`.github/workflows/test.yml`), so important surfaces that previously never ran in CI are now covered (#196, uberscan MAJOR).** A `/uberscan` whole-codebase pass found 10 test files present on disk but absent from both CI jobs — `code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `install`, `merge-discovery-resilience`, `simplify`, `testers-agent-contract`, `testers-rate-limit-audit`, `testers-rate-limit-wrapper`, `trust-trail-evaluator` — covering rate-limit enforcement, merge-discovery resilience, the code-fixer dispatch contract, findings→issues, trust-trail evaluation, and the installer bootstrap, none of which were regression-guarded by CI. Each test was **run locally and confirmed passing before wiring** (the PR's own CI then executes them). Job placement was decided by Git-Bash portability, mirroring the existing `solve-pipeline-zsh` / `testers-pipeline` / `uberscan`-trio precedent: 6 pure shape-check / proven-portable-runtime tests (`code-fixer-dispatch`, `findings-to-issues`, `finish-branch`, `install`, `simplify`, `trust-trail-evaluator`) run on **both** the ubuntu and windows shape-check jobs; 4 Unix-runtime tests run **ubuntu-only** — `merge-discovery-resilience` (executes an executable `fake-gh` fixture via PATH + sources `lib/discover.sh`, neither proven on Git Bash) and the three `testers-*` tests (`python3` + PyYAML, the same reason `testers-pipeline` is ubuntu-only). The `both`-job placements are each backed by an existing Windows-green precedent: `_lib_assert_structural.sh` (used by `review-pr.test.sh` et al.), `lib/config-read.sh` runtime (via `config-override.test.sh`), the `bash -c … uberdev_run_secret_scan_stdin` pattern (via `secret-scan.test.sh`), and chmod+x-stub execution (via `solve-effort-flag.test.sh`).
- **Investigated and dismissed the issue's "orphaned test of a nonexistent `agents/code-fixer.md`" concern.** The uberscan finding flagged `code-fixer-dispatch.test.sh` as referencing a missing agent file; the test actually references `plugins/uberdev/agents/code-fixer.md` (present, 7979 bytes) and passes — the agent exists, so the test was wired normally with no fabricated file.

### Changed
- Version bumped to 0.33.19 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.18] - 2026-05-26

### Fixed
- **`plugins/uberdev/lib/goal-state.sh`'s run-state writer hard-depended on `lib/dispatch.sh`'s `_uberdev_dispatch_prepare_tmp_target` without declaring or guarding the dependency, so sourcing `goal-state.sh` standalone crashed the writer with a cryptic `command not found` and a misdiagnosed return code (#195, uberscan MAJOR).** `uberdev_goal_write_run_state` calls `_uberdev_dispatch_prepare_tmp_target` (the #155 TOCTOU-safe target-prep helper) at four sidecar-write sites, but that function lives in `lib/dispatch.sh`, not `goal-state.sh` — and the file header's "External imports" note explicitly (and now-falsely) claimed the module required NO function from another lib. With no `command -v` preflight, a caller that sourced `goal-state.sh` without first sourcing `dispatch.sh` hit a bare `command not found` at the first call site; because that site is `… || return 3`, the writer then returned **rc=3 — the code documented for a genuine TOCTOU target rejection / disk write failure** — so the real cause (a missing `source`) was both unlogged and actively misdiagnosed. It worked in production only because the goal-pipeline fences happen to source `dispatch.sh` first; the contract was implicit and the header contradicted it. Fix: (1) correct the header to declare `lib/dispatch.sh :: _uberdev_dispatch_prepare_tmp_target` as REQUIRED and document that the caller must source it first (goal-state.sh deliberately does not self-source dispatch.sh — no stable relative path from a sourced lib + avoids a load-order cycle); (2) add a `command -v` preflight at the top of `uberdev_goal_write_run_state`, BEFORE any `mktemp` (so no temp sibling can leak), that fails loud with a distinct **rc=4** and a `goal-state: run-state writer requires lib/dispatch.sh sourced first …` diagnostic. `command -v` (not the `type -t` bashism, which misreports under the zsh-backed runner) keeps the probe correct in both bash and zsh. Regression-guarded by `tests/goal-state-sidecar.test.sh` (5 assertions: distinct rc=4, clear diagnostic, no `command not found` leakage, no stray temp file, and the happy path still returns 0 with `dispatch.sh` sourced).

### Changed
- Version bumped to 0.33.18 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.17] - 2026-05-26

### Fixed
- **`skills/using-git-worktrees/SKILL.md` built the global-directory worktree path with a literal tilde inside double quotes, so `git worktree add "$path"` created a directory literally named `~` under the current working directory instead of placing the worktree under `$HOME` (#194, uberscan MAJOR).** The global-dir case arm set `path="~/.config/uberdev/worktrees/$project/$BRANCH_NAME"` (and the matching case pattern was `~/.config/uberdev/worktrees/*`). Tilde expansion does NOT occur inside double quotes nor on the RHS of a quoted assignment — verified in both bash and zsh, where the value stays the literal string `~/.config/...` — so the subsequent `git worktree add "$path"` / `cd "$path"` polluted the repo with a stray `~` directory and put the worktree in the wrong place, the exact opposite of the intended global, outside-project location. (The common project-local `.worktrees/` branch was unaffected — only the global-config branch was broken.) Fix: expand explicitly with `path="${HOME}/.config/uberdev/worktrees/$project/$BRANCH_NAME"`, and widen the case pattern to `"$HOME"/.config/uberdev/worktrees/*|"~/.config/uberdev/worktrees/"*` so the global branch is selected whether `$LOCATION` arrives as the literal `~/...` the menu displays or an already-expanded `$HOME/...` form. Regression-guarded by the new `tests/using-git-worktrees.test.sh` (4 assertions: `${HOME}` expansion present, no quoted-literal-tilde path assignment, and both case-pattern forms matched), wired into both the ubuntu and windows CI shape-check jobs. The same `case` block also gained a loud `*)` default arm so an unrecognized `$LOCATION` fails fast instead of silently leaving `$path` unset for `git worktree add` (surfaced by the PR review fanout; guarded by assertion W5).

### Changed
- Version bumped to 0.33.17 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.16] - 2026-05-25

### Fixed
- **`uberscan-pipeline/SKILL.md` Phase 4 ran in a fresh shell and lost `CIRCUIT_BREAKER_HALT`/`FINDINGS_FLOOD`, so a CB3/CB4/CB5 halt exited 0 (false-clean) with no partial banner (#192, uberscan MAJOR).** Each ```bash``` fence re-derives `RUN_ID`/`RUN_DIR` via the #171 rehydration stanza — every phase is a separate shell. CB3 (per-wave timeout), CB4 (wall-clock) and CB5 (findings-flood) set `CIRCUIT_BREAKER_HALT`/`FINDINGS_FLOOD` only in memory inside the Phase-1 loop, but Phase 4's exit gate read `${CIRCUIT_BREAKER_HALT:-0}` — which defaults to `0` in its fresh shell — so a documented exit-1 halt silently exited `0` and the partial banner never printed. Persistence was asymmetric: CB1/CB7 already wrote `OVERFLOW=true` and CB5 wrote `PARTIAL=true` to `run-state.txt` (Phase 4 read `OVERFLOW` back), but the halt flag and flood flag were never wired through the file. Fix: each Phase-1 break now appends its trip reason (`CIRCUIT_BREAKER_HALT=CB3|CB4|CB5`, plus `FINDINGS_FLOOD=true`+`PARTIAL=true` for CB5) to `run-state.txt`, and Phase 4 reconstructs the exit decision + the halt/flood banners by reading it back with `grep`, exactly as it already did for `OVERFLOW`. The persisted `run-state.txt` is now documented as the single source of truth (the bash loop is a millisecond directive-emitter whose in-loop counters never accumulate across waves; the orchestrator persists the trip reason between waves). A latent `grep -c … || echo 0` double-`0` integer-comparison error in the OVERFLOW banner — which the now-always-present `run-state.txt` would have surfaced on every CB3/CB4 halt — was fixed to `grep -q` in the same pass. Regression-guarded by `tests/uberscan.test.sh` (8 shape assertions) plus a behavioral reconstruction smoke test covering CB5/CB3/clean/overflow-only.
- **`uberscan-pipeline/report.py` `SEV_RANK` tied `major` and `important` at rank 2, so `--min-severity=major` silently filed `important`-tier findings as issues (#193, uberscan MAJOR).** `severities_at_or_above("major")` and `severities_at_or_above("important")` returned the identical set `{blocker,critical,major,important}`, so the `--min-severity` floor could not distinguish the two tiers — every `important` finding was filed under the default `--severity=major`. Fix: give `important` a distinct rank below `major` (`blocker:5, critical:4, major:3, important:2, suggestion:1`) so the floor is a true total order. Coupled hazard addressed: `_global_rows` hardcodes the synthetic Semgrep-SAST + test-coverage rows at severity `important` and previously gated emission on `important in allowed`, which only passed at the default floor *because* of the now-removed tie; the curated global rows are now filed **unconditionally** (gated on artifact presence, not on the chunk `--min-severity`), so the SAST/coverage signal `/uberscan` exists to surface keeps reaching the issue aggregate at the default floor and above. Regression-guarded by `tests/uberscan-report.test.sh`: `--min-severity major` now excludes `important` chunk findings, while the global Semgrep/coverage rows are still filed at the default floor (and even at `--min-severity critical`); the byte-identical golden snapshots prove the rank change preserved existing ordering.

### Changed
- Version bumped to 0.33.16 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.15] - 2026-05-25

### Fixed
- **`testers-pipeline/aggregate.py` crashed the entire wave when one persona emitted `evidence` as a truthy non-dict (#191, uberscan MAJOR).** `has_evidence()` deliberately raises `ValueError` on a string/list `evidence` (the schema deviation its own comment anticipates), but the per-finding loop in `main()` had no `try/except` — so a single malformed persona output (`evidence: "free text"` or `evidence: [..]`, which survives `f.get("evidence") or {}` as a truthy value and reaches the type guard) propagated an uncaught `ValueError`. The aggregator aborted at the first offending finding **before `wave-N.yaml` was ever written**, discarding the valid findings from all 8 agents in that wave (and, because the uncaught exception exits 1, the wave loop additionally mis-read it as a polite-rate breach). Persona output is untrusted free-form agent YAML, so a schema deviation is *expected*, not exceptional — the guard meant to surface bad input instead weaponized one bad agent into a wave-killer. Fix: wrap the per-finding `has_evidence` call in `try/except ValueError`, mirroring the file's existing malformed-YAML skip-and-continue — log a one-line `warning: skipping finding with non-dict evidence in <path>: <err>` to stderr and `continue` to the next finding. `has_evidence`'s raise-on-bad-shape contract is preserved (the deviation is still surfaced, now as a logged warning rather than a crash), and the documented drop-contract holds (evidence-less findings are dropped, not fatal). Regression-guarded by `tests/testers-pipeline.test.sh` P11 (string + list evidence across one persona; the two well-formed personas' findings survive, both offenders dropped with one stderr warning each).

### Changed
- Version bumped to 0.33.15 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.14] - 2026-05-25

### Fixed
- **`tests/merge.test.sh` reassigned `CMD_FILE` to a relative path mid-suite — cwd-dependent FAILs + a structural false-green in the M87.13 env-var tombstone (#190, uberscan MAJOR).** Line 60 sets `CMD_FILE` to the absolute `$REPO_ROOT/plugins/uberdev/commands/merge.md` and the rest of the 1928-line suite is cwd-independent, but line 1723 silently overwrote it with the relative literal `plugins/uberdev/commands/merge.md` (the only relative path in the file). Run from any dir other than the repo root, M84/M85 emitted spurious FAILs, and — worse — M87.13's negative guard `grep -qE "UBERDEV_${TOKEN}|…" "$CMD_FILE" "$SKILL_FILE"` could not open the unresolved relative `CMD_FILE`, so the tombstone asserting "no env-var variant exists for the deferral flags" PASSED without ever scanning `merge.md`: a future edit reintroducing an env-var variant would slip past the guard whenever the suite ran from a non-root cwd (e.g. a CI scratch dir). The suite passed before only because it happened to be launched from the repo root. Fix: delete line 1723 — the absolute `CMD_FILE` from line 60 is already in scope and correct, so M84/M85/M87.13 now scan `merge.md` regardless of cwd. Regression-proven by running the suite from a non-root cwd (`cd /tmp && bash …/tests/merge.test.sh`) with M84/M85/M87.13 green, then re-running from the repo root.

### Changed
- Version bumped to 0.33.14 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.13] - 2026-05-25

### Fixed
- **`lib/secret-scan.sh` regex fallback could not distinguish a broken scanner from a real match — grep rc≥2 was mis-handled (#189, uberscan MAJOR).** The fallback used `if printf … | grep …; then return 1; fi; return 0`, collapsing grep's tri-state exit (`0`=match, `1`=no-match, `≥2`=regex/I-O error) into a binary. A grep **error** (rc≥2 — e.g. a malformed future pattern making grep exit `2` on every call) fell through to `return 0`, so a broken scanner reported every input as **clean** with no diagnostic (fail-OPEN), and in no case was a scanner error distinguishable from a real secret match. The fallback now captures grep's rc explicitly via `… >&2 || grep_rc=$?` (errexit-safe) and branches: `0`→`return 1` (secret found, fail-CLOSED), `1`→`return 0` (clean), `≥2`→emit a distinct stderr diagnostic naming the scanner failure (never "secret found") and `return` grep's own rc — fail-CLOSED on a code distinct from the match code `1`, so a broken scanner is loud and unmistakable. The gitleaks primary path is unchanged. Regression-locked by new `tests/secret-scan.test.sh` (S1 clean→0, S2 match→1, S3 grep rc≥2→distinct diagnostic + fail-CLOSED), registered in both CI jobs.

### Changed
- Version bumped to 0.33.13 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.12] - 2026-05-25

### Fixed
- **`/uberdev:testers` per-host RPS cap was bypassable and its audit blind to the bypass — rate-limit cluster (#184, #185, #186, #187, #188; uberscan MAJOR ×5).** The runtime wrapper (`lib/rate-limit-curl.sh`) and the post-hoc auditor (`lib/rate-cap-audit.sh`) both keyed per-host buckets/groups on a naive `scheme://([^/?#]+)` authority capture, so `a@host` / `b@host` / `Host` / `host:443` / `host.` each got a DISTINCT bucket — defeating the cap (#184) and letting the same variants evade the audit meant to detect the bypass (#186). Five coherent fixes:
  - **#184 + #186 (shared root cause).** Introduced one canonical host normalizer, `lib/normalize_host.py`, built on `urllib.parse.urlsplit().hostname` (the hardened stdlib URL parser — lowercases, strips userinfo + `:port`, de-brackets IPv6) plus a trailing-dot drop and the historic `..`/`/` scope-escape reject. Both files now key on it (the wrapper calls it as a subprocess; the audit imports it), so all authority variants of one host collapse to a single bucket/group. No more duplicated, drift-prone host parsing.
  - **#185.** `DELAY_MS=$(( (1000 / RPS_CAP) - … ))` truncated `1000/RPS_CAP` to an integer before subtracting elapsed time, under-delaying for any non-integral interval (cap=600 → 1ms instead of 1.667ms, ~67% over cap). The interval is now computed in float (folded into the awk math) and gated on `> 0`.
  - **#187.** The auditor did `cap = int(cap_str)` with no range check (cap=0 flagged every request; a negative cap flagged everything) and raised an uncaught `ValueError` (cryptic traceback) on non-numeric input. It now validates to `[1, 1000]` like the runtime wrapper and exits non-zero with a clear stderr message — no traceback.
  - **#188.** `printf … > "$STATE.tmp" && mv -f …` ignored the `printf` return code; on a failed write the `&&` short-circuited, the state file kept a stale timestamp, and the next call silently re-paced from it. The write rc is now checked and the wrapper fails loud (exit 2) rather than corrupting the rate gate silently.
  - Regression-locked by new assertions in `tests/testers-rate-limit-wrapper.test.sh` (normalizer collapses `a@host`/`Host`/`host:443` identically; wrapper buckets variants into one state dir; cap=600 yields the float delay; a state-write failure surfaces) and `tests/testers-rate-limit-audit.test.sh` (variants group as one host → breach; cap=0/-5/non-numeric rejected). These two suites remain orphaned from CI (tracked separately by #196).

### Changed
- Version bumped to 0.33.12 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.11] - 2026-05-25

### Fixed
- **`/uberdev:ubersimplify` aggregate could be broken out of its spotlighting envelope — prompt-injection into `findings-to-issues` AND `code-fixer` (#183, uberscan CRITICAL).** `skills/ubersimplify-pipeline/aggregate.py` defined its own hand-rolled `_cell()` (and wrote the `<external-untrusted-input>` open/close markers inline) that only collapsed newlines and escaped the `|` delimiter — it did NOT neutralize a literal `</external-untrusted-input>` close-tag. Because `code-simplifier` finding `summary`/`detail` is prose generated over ARBITRARY repo files (attacker-influenceable), a finding whose text contained the literal close-tag terminated the envelope early and promoted the following attacker-derived rows to TRUSTED text — an envelope breakout into both `findings-to-issues` (the `issues` / `ubersimplify-aggregate` path) and `code-fixer` (the `fixer` / `post-impl-review-aggregate` path). Deleted the hand-rolled `_cell()` and the inline envelope writes; `aggregate.py` now imports the hardened shared `cell()` (inserts a U+200B ZWSP after `<`, breaking the verbatim byte sequence the downstream parser scans for) and `envelope()` from `lib/report_primitives.py` — EXACTLY as the sibling reporters (`skills/uberscan-pipeline/report.py`, `skills/testers-pipeline/report.py`) already do. Both aggregate modes now route every field through `cell()` and wrap via `envelope()`. Regression-locked by new D7 tests in `tests/ubersimplify-aggregate.test.sh` mirroring `uberscan-report.test.sh` AC-D7.

### Changed
- Version bumped to 0.33.11 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.10] - 2026-05-25

### Fixed
- **`/uberdev:testers` filed ZERO issues — its Phase-5 envelope source `testers-aggregate` was missing from the `findings-to-issues` closed allow-list (#182).** `skills/testers-pipeline/report.py` wraps the findings-to-issues aggregate as `<external-untrusted-input source="testers-aggregate">`, but `agents/findings-to-issues.md` Step 1 enforces a CLOSED accepted-source set `{post-impl-review-aggregate, simplify-aggregate, ci-refused-synthetic, uberscan-aggregate, ubersimplify-aggregate}` (the pre-fix set) and refuses (`rationale: "input-malformed"`) any aggregate whose leading marker is absent. `testers-aggregate` was not in the set, so every `/uberdev:testers` run's findings-to-issues dispatch was refused and no issues were ever filed — the squad's headline deliverable was silently broken (`/uberscan` and `/ubersimplify` had added their sources; testers was missed). Added `testers-aggregate` to the closed allow-list.

### Changed
- Version bumped to 0.33.10 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.9] - 2026-05-23

### Fixed
- **`/goal` Phase-2 watch loop never advanced on Claude Code CLI 2.1.150 — auto-merged nothing (#180).** The loop keyed solver-completion, PR discovery, and merge detection on stdout markers grepped from the captured `solve-bg-stdout-<N>.log`. On CLI 2.1.150 `claude --bg` detaches in ~4s writing only a launch banner there, so `backgrounded · ` (a *startup* banner, not a terminal marker), `pushed PR #N` (which has **zero** producers — `finish-branch` prints `PR created:`), and the merge gate's read of `merge-bg-stdout-<pr>.log` (a file that is **never written**) could not reflect real state; the loop spun to the 4h `stuck_loop` breaker. Detection is now CLI-version-independent and GitHub-native:
  - PR discovery / solve completion → `gh pr list --json number,closingIssuesReferences,headRefName` (a PR closing issue N, or whose head is `feat/N-…`), via new `uberdev_goal_find_pr_for_issue`.
  - merge completion → `gh pr view <pr> --json state == MERGED`, via new `uberdev_goal_pr_is_merged` / `uberdev_goal_pr_state_gh`. `uberdev_goal_read_merge_result` now consults gh state first, decoupling convergence from the (formerly agent-improvised) `merge_executed` audit-row shape.
  - solver liveness → `claude agents --json` (cwd `solve-issue-N` + busy status), via new `uberdev_goal_agent_busy_for_issue`, used only to tell "still working" from "died".
  - the already-correct file-based contracts are unchanged: the review-pr verdict JSON locator (`uberdev_goal_locate_review_pr_audit_by_pr`), `uberdev_goal_read_trust_signal`, and the flat `.uberdev/audit.jsonl` merge audit. The retired `uberdev_goal_extract_pr_num_from_log` (`pushed PR #N` parser) is removed.
- **`/goal` review timing (#180).** The leaf solver runs its OWN `/review-pr` ~20 min after pushing and frequently goes idle in that window, so "agent idle ⇒ review done" is false. Phase 2 now waits `_UBERDEV_GOAL_REVIEW_GRACE` (30 min, re-read every poll) for the leaf's verdict before dispatching its own `/review-pr` — eliminating redundant reviews and premature red-holds of a PR whose GREEN verdict simply has not landed.
- **`/goal` requires bash ≥ 4 with a clear preflight error (#180).** macOS's default `/bin/bash` is 3.2 (no `mapfile`/`declare -A`) and zsh fatals on the verdict locator's unmatched-glob iteration. Phase 0 now refuses anything below bash 4 (`brew install bash`); Phase 3 replaced `mapfile` with a portable `while read` loop.
- **`/merge` `merge_executed` audit row now has a concrete printf template (#180).** Previously agent-improvised with no guaranteed `data.pr`; now emitted success-only (a failed merge emits `error`, never `merge_executed`, so it can never falsely advance `/goal`).
- **`/solve` + `/turbo` claim protocol aborted on every repo — `uberdev:active` label description exceeded GitHub's 100-char limit.** `UBERDEV_ACTIVE_LABEL_DESCRIPTION` was 107 chars; `gh label create --force` returns HTTP 422 above 100 (on create *and* force-update of an existing label), so the fail-loud claim provisioning (`solve-pipeline/SKILL.md` Step 4.5) aborted with "no agents dispatched". Trimmed to ≤100 chars.
- **`/review-pr` + findings-to-issues label descriptions exceeded the same 100-char limit.** The YELLOW trust-label description (141 chars, fail-loud → aborted `/review-pr` trust-signal emission on deferred-CRITICAL verdicts) and the finding-label description (137 chars, fail-soft → finding labels unprovisioned on fresh repos) were both trimmed ≤100 chars. A repo-wide audit now shows zero label descriptions over the limit.

### Changed
- Version bumped to 0.33.9 across `plugin.json`, `marketplace.json`, the README badge, and the test version ratchets (`goal.test.sh` G20, `solve-claim.test.sh`).

## [0.33.8] - 2026-05-23

### Added
- **`/uberscan` hardening (#166).** Extracted schema-agnostic report primitives into `plugins/uberdev/lib/report_primitives.py` (hardened `cell()` escaper, parameterized `<external-untrusted-input>` envelope emitter, rank-parameterized deterministic sort helper); both `report.py` files now import it in-process (`sys.path.insert` from `__file__`). `SEV_RANK` stays pipeline-local (uberscan `important=2`, testers `important=1`) — NOT unified. Added a `totals.json` sidecar (emitted under `$RUN_DIR`, incl. `--no-report` mode) that Phase 4 reads via a single `jq`, replacing the grep-the-rendered-report + python-recount paths. Surfaced repo-global Semgrep (`research-security`) + coverage (`research-test-coverage`) findings into the findings-to-issues aggregate (enveloped + escaped, `disposition: DEFERRED`).

### Fixed
- **Envelope close-tag breakout (security, MEDIUM, D7).** The shared `cell()` now neutralizes a literal `</external-untrusted-input>` so an injected finding cannot close the spotlighting envelope early and promote attacker-derived rows to trusted prose. `testers-pipeline/report.py`'s aggregate now carries the spotlighting envelope it previously lacked (security.md #8).

### Changed
- **Closed five `/uberscan` test-coverage gaps** (dedupe 3+ reviewers, `norm()` unicode/emoji/tab, `cell()` newline/None, hotspot >15 deterministic truncation, chunk directory-grouping contents) and **registered the previously-orphaned `uberscan.test.sh` / `uberscan-report.test.sh` / `uberscan-chunk.test.sh` in CI** (ubuntu-latest only; Windows-skip documented). Collapsed Phase 0/1 manifest `jq` reads into one `@tsv` read and de-duplicated the `config-read.sh` sourcing. Closes #166.

## [0.33.7] - 2026-05-22

### Fixed
- **Pipeline run-state evaporated across fresh-shell Bash calls (`/goal` silent state-machine no-op).** Each Bash tool call is a fresh shell, and the goal-pipeline watch loop structurally forces call boundaries, so the Phase-0 `GOAL_ID` pointer, loop accumulators (`cycle`/`watch_start`/`overflow_count`/`overflow_detected`), and sourced `uberdev_goal_*` definitions evaporated before Phases 1–4 — `$GOAL_ID` resolved empty (per-goal TSV paths degraded to `goal--*.tsv`) and `uberdev_goal_*` calls hit "command not found", silently no-op'ing state-machine transitions and circuit-breaker accounting. Added `uberdev_goal_write_run_state` / `uberdev_goal_read_run_state` / `uberdev_goal_cleanup_run_state` to `lib/goal-state.sh` — a hardened `KEY=value` sidecar under `$UBERDEV_TMPDIR`, written atomically via the #155 TOCTOU-safe `_uberdev_dispatch_prepare_tmp_target` and read back with per-field-validating loops (never `source`/`eval`, never `mapfile`; bash-3.2/zsh portable). goal-pipeline now re-sources the three libs and re-reads run-state at the top of every later phase block; sibling pipelines get the lighter re-source-per-block treatment. The TSV-keyed-by-`GOAL_ID` model (PR #129) is unchanged. (#171)

## [0.33.6] - 2026-05-22

### Fixed
- **`/goal` first-dispatch crash (rc=126).** Extracted the six dispatch-env vars (`TIMEOUT_BIN`, `SOLVE_TIMEOUT`, `MODEL`, `PERM_FLAG`, `EFFORT_FLAG`, `BG_PROMPT_MODE`) from solve-pipeline Phase A into a shared sourced helper `uberdev_dispatch_resolve_env()` in `lib/dispatch.sh`, now called by both solve-pipeline and goal-pipeline. goal-pipeline previously sourced `lib/dispatch.sh` and called `uberdev_dispatch_preflight` (backend only) but never established the env vars, so its first `uberdev_dispatch_one` exec'd an empty `$TIMEOUT_BIN` and failed with `permission denied` (rc=126). The helper mirrors `/turbo`'s unattended dispatch env (`AUTO_MODE=1`, `AUTO_PERMISSIONS=0`, `EFFORT_LEVEL=max`) and preserves the verbatim fail-loud `timeout(1)`/`gtimeout(1)` probe guard. Backend resolution (`UBERDEV_RESOLVED_BACKEND`) is unchanged (RFC 0005 D15). (#175)

## [0.33.5] - 2026-05-22

### Changed
- **De-monolithed the `AUDIT_EVENT_ENUM` Constants cell in `skills/merge-pipeline/SKILL.md` (#119).** The cell was a single ~5131-char line (enum literals + ~3500 chars of field-level prose + member-addition history) — unscannable, and every new audit event made it worse. The ~3500 chars of prose moved into a dedicated `### AUDIT_EVENT_ENUM — event semantics & member history` subsection (with paragraph breaks per member cohort); the **canonical comma-separated list of event literals stays in the table cell** (now ~1274 chars) so the M-row grep-the-row tests (`merge.test.sh` M23/M52/M74/M75/M76 across 6 test files) keep resolving unchanged. `merge.test.sh` M76 was repointed at the relocated subsection; new M88 locks the refactor (row points at the subsection; prose no longer monolithic). No behaviour change. Closes #119.

## [0.33.4] - 2026-05-22

### Fixed
- **Aligned the stale alias enumerations in `skills/using-uberdev/SKILL.md` with the installed set (#162).** The "Auto-installed aliases" line said "**six** … (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`)" — missing `/dev`, `/testers`, `/ubergoal`, `/uberscan`, `/ubersimplify` (the set has grown to **eleven**); now lists all eleven. The `auto_install_aliases` config-example comment was de-enumerated (points at `aliases-sync.sh` as the canonical set) to stop it drifting again. `aliases-sync.sh` and the README already listed eleven. Docs-only; no behaviour change. Closes #162.

## [0.33.3] - 2026-05-22

### Security
- **Hardened the predictable `$UBERDEV_TMPDIR` dispatch paths against TOCTOU symlink-swap / pre-creation (#155).** `lib/dispatch.sh` writes `solve-bg-stdout-<issue>.log` and `solve-bg-status-<issue>.json[.pid]` to a world-writable tmpdir at intentionally predictable paths (the `/goal` watcher polls them by name, so `mktemp`-randomisation isn't an option). An attacker could pre-create a symlink there to clobber a victim file or feed attacker-chosen bytes into the `DISPATCH_ID` extraction. New `_uberdev_dispatch_tmp_target_safe` guard rejects a symlink, a foreign-owned entry, or a non-regular file at the predicted path; `_uberdev_dispatch_prepare_tmp_target` then re-creates the file `0600` under `set -C` (noclobber) so the sticky-bit dir protects it from a later swap (and the guard fails CLOSED when ownership is undeterminable — e.g. a minimal `stat` lacking both `-f` and `-c`). **All three** dispatch backends (`claude-bg`, `background`, `wezterm`) fail-CLOSED (rc=3 + `dispatch_setup_failed` audit with `phase ∈ {tmp_target_unsafe, tmp_target_create, pid_target_unsafe}`) instead of writing through. Success path unchanged. Regression fixture in `tests/dispatch-claude-bg.test.sh` (symlink pre-creation → fail-closed). Closes #155.

## [0.33.2] - 2026-05-22

### Fixed
- **`/uberdev:review-pr` now provisions the trust label before adding it (#170).** GREEN/YELLOW runs add `uberdev-approved` / `uberdev-approved-with-concerns` via `gh pr edit --add-label`, which CANNOT auto-create a repo label and exits non-zero when it is missing — so on a fresh repo (or any repo where the trust labels were never created) the first GREEN/YELLOW run aborted the entire trust-signal emission with `exit 2`. Each label is now provisioned fail-loud via `gh label create --force` (idempotent — updates colour/description, never errors on "already exists") with a per-tier colour/description immediately before the add. Same assume-label-exists class as #168; surfaced by PR #169. Regression-tested in `tests/review-pr.test.sh` (R9.16/R9.16b). Closes #170.

## [0.33.1] - 2026-05-22

### Fixed
- **`/solve` `/turbo` claim protocol (Step 4.5): `gh label create --force` for the `uberdev:active` label is now fail-loud.** It previously swallowed failures with `|| true`, but the per-issue combined `gh issue edit --add-label --add-assignee` write hard-depends on the label existing — gh cannot auto-create a label from `--add-label` and fails the combined mutation *atomically* when it is missing. A transient or permission-related create failure was therefore silenced, then resurfaced downstream as a misleading `failed to write claim (label or assignee) — check gh auth` abort that pointed the operator at the wrong cause. `--force` already guarantees idempotency (it updates colour/description on "already exists", never errors), so a non-zero exit is *always* a genuine failure (auth gap, missing repo write/triage scope, API/network error). It now captures gh's stderr, emits `claim_write_failed{step:label_create}`, and exits 1 before any claim is written (so no rollback is needed). The combined claim write (E1) is unchanged. Unlike the fail-soft `gh label create` in `finish-branch` / `dev-pipeline` / `findings-to-issues` (where the dependent `--add-label` is also fail-soft and the label is a nice-to-have), here the label is the canonical claim signal gating a fail-loud write. Regression-tested in `tests/solve-claim.test.sh` (4 new assertions). Closes #168.

## [0.33.0] - 2026-05-22

### Added
- `/uberdev:ubersimplify` — whole-codebase 3-lens simplification (Reuse/Quality/Efficiency). Chunks the repo (shared `lib/chunk.py`), audits each chunk with the `code-simplifier` lenses in concurrent waves, applies preserve-behavior fixes via `code-fixer` as one `refactor:` commit per chunk on a new branch, opens ONE PR, and files leftover blocker findings as GitHub issues (`ubersimplify-finding` label). `--audit-only` for a read-only scan. Seven circuit breakers bound cost (RFC 0008).
- `/ubersimplify` short-form alias for `/uberdev:ubersimplify` (alias count 10 → 11).
- `findings-to-issues`: `ubersimplify-aggregate` accepted source.

### Changed
- `chunk.py` moved from `skills/uberscan-pipeline/` to `lib/chunk.py` (shared by `/uberscan` and `/ubersimplify`; path-only, behavior unchanged).

## [0.32.0] - 2026-05-22

### Added
- `/uberdev:uberscan` — whole-codebase read-only audit. Chunks the repo, runs the `/review-pr` Phase-1 reviewer fleet (6 reviewers) per chunk + a repo-global Semgrep/test-coverage pass, aggregates into a markdown report, and files deduped GitHub issues (`uberscan-finding` label). Never writes code. Whole-repo by default, path-scopable; seven circuit breakers bound cost (RFC 0007). Simplify lenses intentionally excluded (separate command).
- `/uberscan` short-form alias for `/uberdev:uberscan`.
- `findings-to-issues`: `finding_label` / `finding_marker_slug` / `source_ref` inputs + `uberscan-aggregate` source (back-compatible defaults preserve `/review-pr` behavior).

## [0.31.0] - 2026-05-21

### Added
- `/uberdev:goal` — autonomous convergence orchestrator (RFC 0005). Chains `/turbo` → `/review-pr` (auto) → `/merge` if GREEN; recurses on BLOCKER/CRITICAL `review-pr-finding` issues until convergence or one of seven circuit breakers fires.
- Seven circuit breakers: `max_cycles` (default 5, range 1–20 via `UBERDEV_GOAL_MAX_CYCLES`), `nonconvergence` (fingerprint repeat from prior cycle), `stuck_loop` (4h goal-level wall-clock), `merge_failed` (conflict or hook failure), `gh_api_failed` (Phase 3 `gh issue list` or `gh api user` rc!=0 — surfaces transient rate-limit / network errors instead of falsely emitting `goal_converged`), `unknown_merge_result` (Phase 2c default-arm guard against `uberdev_goal_read_merge_result` returning a value outside the documented `success|conflict|hook_failed|missing` set — contract-drift halt), `queue_empty_not_converged` (deterministic Phase 3 halt when the candidate queue is empty but at least one PR remains in a non-terminal in-flight state — alternative to spinning until the 4h `stuck_loop` fallback).
- `/ubergoal` short-form alias for `/uberdev:goal` (installed by `/uberdev:install-aliases`).
- `lib/goal-state.sh` — PR + issue state machines, per-goal audit-sink JSONL at `$UBERDEV_TMPDIR/goal-<id>.jsonl`.
- `skills/goal-pipeline/SKILL.md` — 5-phase pipeline (Preflight → Dispatch → Watch → Collect-Next → Converge/Halt).
- `tests/goal.test.sh` — 20-section shape-check harness (G1–G20).
- **`/uberdev:testers`** — adversarial multi-persona QA audit squad. 6 distinct-persona testers (`panicked_grandma`, `power_user`, `adversarial_security`, `chaos_engineer`, `a11y_critic`, `mobile_thumb`) + 2 monitors (`monitor_primary`, `monitor_devils_advocate`) over 3 coordinated waves. Auto-detects target surface (web/api/native/all). Findings are evidence-anchored against a 10-invariant oracle library and filed as GitHub issues via the existing `findings-to-issues` pipeline. Read-only — the squad never writes app code. Alias: `/testers`. See `docs/rfc/0006-testers-command.md`.

### Changed
- Plugin version bumped from `v0.30.4` to `v0.31.0`.
- `tests/solve-claim.test.sh:258-265` version-drift assertions updated to `0.31.0`.

### Security
- `Blocks: #` parser is ReDoS-safe (anchored bash regex + 64 KiB body cap).
- `/merge` auto-chain is scoped to `/goal` only via `UBERDEV_GOAL_ID` env-var provenance check (T5).
- Per-PR `automerge_attempt_count >= 3` short-circuits `uberdev_goal_should_automerge` so the goal stops re-dispatching `/merge` for that PR (the runaway-loop containment, R5). The PR sits in `green` until `max_cycles` fires or the operator intervenes; no `merge_failed` halt is emitted.

## [0.30.4] - 2026-05-21

### Documentation

- **README install paragraph: align alias count with reality.** The auto-install paragraph said "seven short-form aliases" and only listed `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`, `/dev` — `/testers` (auto-installed since v0.30.0 via `aliases-sync.sh`) was missing. Now lists all eight (`/testers` added) and the count matches `UBERDEV_ALIAS_NOTICE` runtime emit ("installed 8 short-form aliases").

## [0.30.3] - 2026-05-21

### Fixed (#143)

- **dispatch:** `claude --bg` id extraction now strips ANSI CSI escapes before
  the marker grep, fixing false-positive `DISPATCH_RC=2`
  (`dispatch_setup_failed phase=id_extract`) on Claude Code 2.1.146+ where
  the bg session id is wrapped in cyan SGR codes (`\x1B[36m<id>\x1B[39m`).
  Defense-in-depth: line-anchored marker re-grep + hex-only scrub on the
  extracted id closes OSC/DCS injection surfaces. B3 fail-CLOSED guard
  preserved — genuinely missing markers still surface as rc=2. Combined with
  the #154 rc-capture fix (grep-own-rc + subphase discriminator) from v0.30.2.
  Closes #143.

## [0.30.2] - 2026-05-21

### Fixed (#154)

- **`claude --bg` dispatch id-extraction no longer silently masks pipeline failures.** `lib/dispatch.sh`'s `DISPATCH_ID` extraction (`grep -oE 'backgrounded · <id>' | awk | head`) swallowed pipeline-level errors (sed/grep failure ≠ "no match") into an empty `DISPATCH_ID`, so the B3 guard surfaced `rc=2 phase=id_extract` identically for transient infra failure and persistent format drift. Now captures grep's own rc and adds a distinct subphase discriminator to the `dispatch_setup_failed` audit JSON so incident responders can tell a retryable transient failure from a non-retryable `claude --bg` output-format change. (PR #158)

## v0.30.1 — 2026-05-21

### Fixed (#133)

- **`/uberdev:testers` `--rps-cap` is now actually enforced.** Previously parsed and serialised but no layer enforced it; a run with `--rps-cap=5` could let any persona fire 50+ req/sec at the target. Now:
  - Pre-emptive (hard cap) via `plugins/uberdev/lib/rate-limit-curl.sh` (token-bucket, per-host, `mkdir`-as-mutex) for `Bash(curl*)` traffic.
  - Post-hoc audit via `plugins/uberdev/lib/rate-cap-audit.sh` for Playwright / browser-MCP traffic that cannot be HTTP-wrapped; a breach synthesises a `critical` `polite_rate_cap` finding and the run exits 1.
  - Parse-site input validation: anchored regex `^[1-9][0-9]*$`, range `[1, 1000]`, `exit 2` on bad input. Closes a MAJOR-severity argv-injection surface.
  - URL flag-smuggling neutralised: wrapper invokes `command curl <args> -- "$URL"`.

### Breaking (internal CLI)

- `aggregate.py --rps-cap=N` is now a **required** flag. Direct callers outside SKILL.md must pass it explicitly. SKILL.md's invocation has been updated. The previous default (no flag) silently disabled the audit; making it required ensures the audit always runs.

### Documentation (#133)

- RFC 0006 §Risks rewritten to match the implementation: hard cap for curl, post-hoc audit fail-the-run for MCP, with the single-wave detection-latency caveat made explicit. Removes the misleading "limit the exfil bandwidth" framing.
- All 6 testers persona agent files (`testers-adversarial-security`, `testers-a11y-critic`, `testers-chaos-engineer`, `testers-mobile-thumb`, `testers-panicked-grandma`, `testers-power-user`) carry a uniform Polite-rate clause naming the wrapper, the audit, and the populate-`timestamp` directive.

## [0.30.0] - 2026-05-19

### Added

- **Cross-platform dispatch backends for `/solve` and `/turbo` (RFC 0004).** A `dispatch_backend` abstraction with three tested backends — `claude-bg` (today's default), `wezterm` (visible panes, opt-in), and `background` (dependency-free fallback) — selected by a platform-aware fallback chain (macOS → `[wezterm, claude-bg]`; native Windows → `[wezterm, background]`; WSL2 → `[claude-bg]`). New `--backend=` CLI flag and `dispatch_backend:` config key let users override the resolved backend per invocation or per repo.
- **Native Windows hardening of the bash dispatch pipeline.** Coreutils-first `TIMEOUT_BIN` probe (no more accidentally invoking `System32\timeout.exe`), `MSYS_NO_PATHCONV` wrap around path arguments, a single `UBERDEV_TMPDIR` replacing every hardcoded `/tmp/`, a native-Windows-without-bash fast-fail, and a WSL2 `/mnt` slowness warning. New `windows-latest` shape-check CI job covers the regression surface.
- **New `lib/dispatch.sh` module** sourcing `uberdev_dispatch_preflight` + `uberdev_dispatch_one` + three backend functions; `solve-pipeline/SKILL.md` Step 5b' rewired to call it.

### Why

`/solve` and `/turbo` were silently macOS-and-WSL2-only because the dispatch path hardcoded `claude --bg` and `/tmp/`. RFC 0004 introduces a platform-aware backend abstraction so the same commands work end-to-end on macOS, WSL2, and native Windows (Git Bash). See `docs/rfc/0004-cross-platform-dispatch-backends.md`. Known limitation: on hosts with a pre-existing `~/.wezterm.lua`, the appended Lua config is unreachable if the existing file contains its own `return config` (first-return-wins) — users with custom WezTerm configs must integrate the managed values by hand for now.

## [0.29.0] - 2026-05-19

### Fixed

- **Alias auto-install no longer silently depends on `jq`.** The `SessionStart` hook (`plugins/uberdev/hooks/session-start`) hard-requires `jq` to JSON-encode its context injection and `exit 0`s early when `jq` is absent — previously *before* the auto-alias-sync block ever ran, so a new user on a machine without `jq` got zero short-form aliases (`/issue`, `/solve`, `/turbo`, …) and no warning. The alias-sync block now runs **before** the `jq` guard, and `lib/aliases-sync.sh` no longer calls `jq` at all: its one use (`jq -r .version` on `plugin.json`) is replaced by a jq-free `_aliases_read_version()` `sed` parse of the plugin's own manifest. Forwarders now install regardless of `jq`. See `docs/rfc/0011-alias-install-reliability.md`.

### Added

- **Alias-install outcomes are surfaced in the session context.** `aliases_sync_main` now composes a `UBERDEV_ALIAS_NOTICE` that the `SessionStart` hook injects as an `<important-reminder>`: a first-run summary, a collision notice naming any alias skipped because a non-uberdev file already occupies its short name (with the resolution steps), or a write-failure notice. Previously this went only to `stderr` and only on first run, so a skipped `/turbo` was invisible. The notice is conditional — empty in steady state, so post-first-run sessions stay silent.
- **When `jq` is absent the hook now emits a fixed notice** (`uberdev: jq not found …`) instead of a silently-empty context, making the jq-missing degradation visible.
- **`tests/aliases.test.sh` — new cases S10–S14:** `_aliases_read_version` parity with `jq -r .version`, `aliases_sync_main` notice composition, jq-masked install (all seven forwarders install with `jq` off `PATH`), and collision / first-run notices reaching the context injection.

### Why

`README.md` already promised the seven aliases are "auto-installed on first session" — but the auto-sync was fail-open and silent, so on a jq-less machine or a short-name collision the user got less than promised with no signal. This release closes that reliability gap against the stated contract: aliases install unconditionally, and any skip or failure is reported. Claude Code has no install-time plugin hook (feature request anthropics/claude-code#11240, closed unshipped), so the `SessionStart` hook remains the provisioning mechanism — it is hardened, not replaced. Deliberately out of scope and deferred: content-hash idempotency, retry of a previously-skipped alias, and `install.sh`-side provisioning.

## [0.28.0] - 2026-05-18

### Added

- **Small-team issue-claim protocol for `/solve` and `/turbo`.** On dispatch, the launcher (`plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 4.5) now marks each target issue ACTIVE on GitHub with three coordinated writes (in sequence with rollback on partial failure — not atomic): the `uberdev:active` label (queryable via `gh issue list --label uberdev:active`), the `@me` assignee (native GitHub UI signal — matches what `gh api user --jq .login` resolves to), and an HTML-comment-fingerprinted audit comment carrying dispatcher username, hostname, branch (`worktree-solve-issue-N`), tier, and ISO-8601 timestamp. Concurrent teammates running `/solve` or `/turbo` on overlapping issue numbers get a hard refusal showing who/where/when, instead of racing into divergent worktrees and duplicate PRs. The fail-loud claim-write contract (any `gh` permission gap aborts the batch and rolls back prior writes) prevents the silent-partial-claim mode that would defeat collision prevention.
- **`--force` / `-f` override flag on `/solve` and `/turbo`.** Bypasses the claim-collision refusal for stale-claim recovery (e.g. a teammate's machine crashed mid-run leaving the label stuck). Anchored token regex `^(--force|-f)$` — flag fragments inside larger tokens (`--force-foo`) do NOT match. Overrides are recorded as `claim_force_override` audit events so post-hoc grep can distinguish intentional recoveries from regressions.
- **Auto-cleanup of `uberdev:active` on `/merge`** (`plugins/uberdev/skills/merge-pipeline/SKILL.md` Step 3.4 — NEW; the prior Step 3.4 "Failure-mode summary" renumbered to 3.5). After a successful `gh pr merge` (clean-merge or conflict-resolve path), the merged PR body is parsed for the documented GitHub closing keywords (`close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved` followed by `#N`, case-insensitive, with a left word-boundary anchor so `preclose #42` / `postfix #100` do NOT false-match — added in #123 B1 follow-up) and the `uberdev:active` label is removed from each linked issue. The cleanup loop ALSO clears the `@me` assignee for each linked issue (symmetric with the Phase B dispatch-failure rollback in solve-pipeline; without this the dispatcher's "Assigned to me" GitHub filter accumulates closed-and-merged issues over time — fixed in #123 B5 follow-up). Cross-repo `org/repo#N` references are intentionally not parsed (the claim protocol only applies to issues in the current repo). Failure-soft: a PR with no closing keywords is a no-op; a `gh issue edit` failure is silently ignored (the dispatch-time stale-claim sweeper in solve-pipeline Step 4 picks up anything `/merge` misses).
- **Dispatch-failure rollback in Phase B.** When `claude --bg` returns non-zero (e.g. model unavailable, worktree creation failed, gtimeout exec failure), the claim acquired in Step 4.5 is now released immediately: label removed, assignee cleared, a release-comment is posted (same `CLAIM_COMMENT_MARKER` fingerprint so future collision checks see the latest claim event as a release). Rollback first re-fetches the latest claim comment and verifies the `User:` line still names this dispatcher — if a teammate raced in and won the claim between Step 4.5 and the dispatch-failure window (e.g. via `--force` after seeing a stuck label from a different bug), rollback **skips** the strip and logs a warning instead of stealing the racing dispatcher's claim (#123 B3 follow-up). Without all of this, a crashed dispatcher would orphan the claim and force every teammate to use `--force` for that issue indefinitely.
- **Five new `SOLVE_AUDIT_EVENT_ENUM` members** in solve-pipeline: `claim_acquired`, `claim_collision`, `claim_force_override`, `claim_write_failed`, `claim_released`. Plus one new `AUDIT_EVENT_ENUM` member in merge-pipeline: `uberdev_active_label_cleared` (with `data.issue: int`, `data.pr: int`, `data.reason: "merge"`).
- **`tests/solve-claim.test.sh`.** Structural-grep coverage for the constants binding, --force parser, JSON-projection extension, collision check (jq + grep field extraction), claim-write loop fail-loud structure, Phase B dispatch-failure rollback, all five new audit-event emission sites + enum membership, merge-pipeline Step 3.4/3.5 rename, command-file documentation, and the version-bump drift check. Wired into the CI `&&`-chain in `.github/workflows/test.yml`. Includes a negative regression guard that no `Co-Authored-By: Claude` or `Generated with Claude Code` strings leak into the claim or release comment bodies (per global `CLAUDE.md`).

### Why

UberDev was originally built for a solo developer for whom GitHub issues function as a personal TODO queue — no coordination needed. With even a single teammate, two concurrent `/turbo 5 6 7` invocations on overlapping issue lists silently produced two divergent worktrees, two PRs, and wasted effort that surfaced only at merge time. The claim protocol adds the missing coordination primitive without standing up new infrastructure: GitHub itself is the coordination surface (label + assignee + comment), and the protocol is opt-out-by-`--force` for stale-claim recovery.

The refusal fires on ANY claim collision — including same-machine re-runs. This is deliberate: accidentally re-dispatching `/turbo 42` from the same laptop while the first run is still going would race two bg sessions into the same worktree, which is the same failure mode as the cross-teammate collision the protocol exists to prevent. After a manual `claude agents stop`, the operator passes `--force` as the deliberate "yes I really want to re-dispatch" gesture; the override is auditable so post-hoc review can spot patterns (recovery from real failures vs. accidental retries that should have used a different approach).

**Known limitation — TOCTOU race window (#123 B2).** The Step 4 collision-check read and Step 4.5 claim-write happen in separate gh round-trips. Two dispatchers running concurrently against the same issue can both observe "no label present" in their Step 4 reads and both write the label in Step 4.5 — `gh issue edit --add-label` is idempotent on the GitHub side. The protocol is **best-effort, not atomic**; the race window is bounded by gh round-trip latency (tens to hundreds of ms). For the small-team usage this targets, that's acceptable. Larger-team operators or workflows that need a strong distributed lock should NOT rely on this protocol — a post-write verification step (re-fetch latest claim comment, refuse if a different dispatcher's marker won) would close the window at the cost of one extra round-trip per issue and is deferred until measured contention warrants it.

### Fixed

- **`/merge` Phase 1.4 PATH_2 sub-condition (c.0) audit-JSON discovery now traverses ALL worktree-local mirror paths.** The bash discovery glob at `plugins/uberdev/skills/merge-pipeline/SKILL.md` Step (c.0) only searched `.uberdev/runs/*/review-pr-verdict.json` relative to `/merge`'s CWD. When `/merge` ran from the main checkout but the PR was produced by ANY worktree-based flow (`/solve` and `/turbo` per `solve-pipeline/SKILL.md`'s `.claude/worktrees/solve-issue-N/`, OR `subagent-driven-dev` / `executing-plans` / brainstorm-Phase-4 per the generic `using-git-worktrees/SKILL.md`'s `.worktrees/` preferred + `worktrees/` alternate conventions), `/review-pr` wrote the audit JSON inside that worktree's gitignored `.uberdev/runs/` — invisible from the main-checkout glob. `trust-trail-evaluator` was then dispatched with `phase2_5_present=false`, which per its Step 1.5 short-circuits to `STALE`, gating otherwise-valid trust trails. Step (c.0) bash and sub-condition (d) prose now glob the full four-layout enumeration: `.uberdev/runs/`, `.claude/worktrees/*/.uberdev/runs/`, `.worktrees/*/.uberdev/runs/`, `worktrees/*/.uberdev/runs/`. The `~/.config/uberdev/worktrees/<project>/<branch>/` global-fallback layout (also declared in `using-git-worktrees/SKILL.md`) is intentionally NOT globbed — it lives outside the project root and would require runtime `$HOME` resolution; deferred to the writer-side path-anchoring follow-up (anchor `/review-pr`'s artifact writer on `git rev-parse --show-toplevel`, mirroring the convention in `orchestrator/SKILL.md`). The RUN_ID_REGEX basename-of-dirname projection (D4/F8 path-traversal hardening) works identically on all four layouts because the prefix segments are never concatenated from untrusted input — no security regression. New `M63.worktree-glob.{c0.compgen,c0.forloop,c0.or-operator,d,cm}` structural-grep assertions in `tests/merge.test.sh` lock the fix in five places (compgen-OR chain + for-loop iteration + OR-operator semantics + sub-condition (d) prose + Common Mistakes bullet). Observed twice locally on worktree-produced PRs; manual `cp` workaround retired.

## [0.27.0] - 2026-05-16

### Added

- **`/uberdev:dev` — prototype fast-lane command (short alias `/dev`).** Builds a minimal working prototype or small function from a free-text idea, deliberately skipping the spec → plan → full `/review-pr` pipeline that `/solve` and `/turbo` run. The output is honestly labelled: a `prototype`-labelled PR plus an auto-filed harden issue with a tracked path back to production. Closes #120.
- **Backing skill `uberdev:dev-pipeline`.** A 7-phase Phase 0–6 in-session pipeline running on a `proto/<slug>` branch, with parallel `Task()` subagents dispatched in a single message.
- **Two-column Quality Contract.** The relaxed column is the harden-issue backlog — edge cases, TDD depth, abstractions, and similar rigor are explicitly deferred for prototype code. The hard floors hold: security, secret-handling, crash-hiding, and "the code must actually run".
- **Meta-quality.** The `/dev` implementation itself meets the full AAA quality bar; the relaxed column applies only to `/dev`'s future prototype output, never to `/dev`'s own code.
- **`/dev` short-form alias.** Registered via the `ALIASES` SSOT in `lib/aliases-sync.sh`; auto-installed on first session and refreshed on plugin upgrade alongside the existing six aliases.
- **`docs/rfc/0003-dev-command.md`.** The design RFC for the `/dev` fast-lane command.
- **`tests/dev.test.sh` + `tests/dev-pipeline.test.sh`.** Structural-grep shape-check coverage for the command-file frontmatter contract and the skill's 7-phase structure, security regression locks (no `git add -A`, explicit-path staging), and the scope gate. Both wired into the CI `&&`-chain in `.github/workflows/test.yml`. `tests/aliases.test.sh` extended to exercise install/uninstall/collision for `/dev`.

### Security

- **Slug sanitization gate in `dev-pipeline`.** Free-text ideas are reduced to a kebab `<slug>` via a derive-then-validate allow-list (`^[a-z0-9]+(-[a-z0-9]+)*$`, 48-char cap) with a `git check-ref-format` belt-and-braces check before any `git checkout -b proto/<slug>` — closing shell-word-split and git-ref-injection surfaces. All `gh` bodies are delivered via `--body-file -` (never `--body "$VAR"`); the idea text is wrapped in `<external-untrusted-input source="dev-idea">` envelopes in every subagent prompt.

## [0.26.1] - 2026-05-14

### Added (test coverage)

- **T1–T7 — structural-grep tests for RFC 0002 surfaces.** Locks the GREEN/YELLOW/RED predicate prose and `phases.phase2_5` audit JSON schema in `commands/review-pr.md` (T1, T2); the `halted` + `by_severity` + per-URL `tier` return-contract fields in `agents/findings-to-issues.md` (T3, T6); the three new `/merge` override flags (`--accept-blocker-deferred`, `--accept-critical-deferred`, `--i-know-what-im-doing`) in both `commands/merge.md` and `skills/merge-pipeline/SKILL.md` (T4); the `ci-code-fixer` REFUSED halt path in `commands/review-pr.md` Phase 3 6c.5 (T5); the broken-feature overflow guard in `agents/findings-to-issues.md` Step 6 (T6); and the `trust-trail-evaluator` Phase 2.5 gate (Step 1.5) in a new `tests/trust-trail-evaluator.test.sh` file (T7).
- **First structural-grep coverage for `agents/trust-trail-evaluator.md`.** The agent was previously uncovered; T7 introduces the dedicated test file mirroring the per-agent-file convention used elsewhere in `tests/`.

### Added (observability)

- **O1 — `audit_json_phase2_5_parse_failure` audit event.** Distinguishes legacy audit (no event, fail-open) from malformed audit JSON (emits `audit_json_phase2_5_parse_failure` with truncated `data.jq_error` and `data.audit_path`). Extends `AUDIT_EVENT_ENUM` in `skills/merge-pipeline/SKILL.md` (+ M86.8 containment assertion in `tests/merge.test.sh`). Fail-open preserved — parse failure is auditable but does NOT halt.
- **O2 — `author_lookup_failed` return field on `findings-to-issues`.** Captures `gh pr view <N> --json author` exit-code failure into a typed boolean return field. Adds integer regex guard (`[[ "$pr_number" =~ ^[0-9]+$ ]]`) before the `gh` call (security defence-in-depth).
- **O3 — Explicit-bash ToolSearch fail-fast in `review-pr.md` Step 6b.1.** Concretizes the prior prose contract ("If `ToolSearch` fails, `/review-pr` aborts — NEVER silently auto-pick") into deterministic shell that emits the audit event via the project's pseudo-shell form `audit halt_tool_unavailable data.tool="AskUserQuestion"` and exits 1. Mirrors the existing 6c.6 HALT pattern. The `halt_tool_unavailable` event joins `AUDIT_EVENT_ENUM` alongside `audit_json_phase2_5_parse_failure` (+ M86.9 grep assertion in `tests/merge.test.sh`).
- **O4 — `is_transient` field on `blocked_by_dedupe[]` entries.** Splits `gh issue create` write failures into transient (rc=429, HTTP 5xx, rate limit, secondary rate) vs permanent (everything else; conservative default). 200-char stderr truncation preserved (security Note B).
- **O5 — CI-REFUSED issue creation refactored to `findings-to-issues` dispatch.** Replaces the inline `gh issue create` shell in `commands/review-pr.md` Phase 3 6c.5 with a `Task(subagent_type: uberdev:findings-to-issues)` dispatch carrying a synthetic single-row aggregate wrapped in `<external-untrusted-input source="ci-refused-synthetic">`. Eliminates prose-drift risk between the two issue-creation sites. The issue title prefix shifts from `[ci-refused] $signal_anchor — $rationale` (pre-O5) to `[finding] $file_path:$line — $summary` (post-O5) to share the agent's standard CRITICAL-tier title shape; body, labels, and the `ci_refused_issue_url` audit field are unchanged.

### Notes

- **T8 (synthetic-PR fixture-runner integration test) and T9 (AskUserQuestion halt-choice integration test) remain deferred to v0.27 per issue #116.** Both require a 350–560-line fixture-runner harness that does not yet exist; tracked in #116 surfacing in this release's PR description as a known gap.

## [0.26.0] - 2026-05-14

### Changed (BREAKING — trust-trail contract)

- **`/uberdev:review-pr` Phase 2.5 promoted from advisory to severity-tiered gating (RFC 0002).** The findings-to-issues sub-phase (added in PR #112, v0.24.0) previously declared `the sub-phase NEVER causes /review-pr or /simplify to exit non-zero` (`agents/findings-to-issues.md:187`); audit of the post-PR-#112 flow surfaced three silent-drop paths where a green trust trail co-existed with unresolved blocker findings, dropped Phase 2 `important` / Phase 1 `major` findings, and silent CI fixer refusals. RFC 0002 fixes all three with a tiered model:
  - **`blocker` deferred → RED trail** (no `Reviewed-by` trailer, no `uberdev-approved` label, exit 1). `/merge` requires `--accept-blocker-deferred` to land.
  - **`critical` deferred → YELLOW trail** (trailer carries `severity=critical-deferred count=N`, label becomes `uberdev-approved-with-concerns`). `/merge` requires `--accept-critical-deferred` to land.
  - **`important` / `major` deferred → GREEN unchanged** (file silently, no @mention, no halt).
  - **CI `ci-code-fixer` `status: REFUSED` → user-visible halt prose** (mirrors `billing_quota` shape) + file the failing test as a CRITICAL-tier issue + drop the 3-iteration retry (REFUSED is deterministic, not flake).
  - Operator can opt out per-run via interactive AskUserQuestion option 3 (`Override — emit GREEN`), which logs `override_reason: "user-selected-emit-green-on-blocker-deferred"` in the audit JSON and requires `/merge --i-know-what-im-doing` to land downstream.
- **Audit JSON shape** (`.uberdev/runs/<run-id>/review-pr-verdict.json`) gains `phases.phase2_5` and a top-level `trust_trail_state ∈ {GREEN, YELLOW, RED}` field. Legacy audit JSON (pre-v0.26.0) without `phases.phase2_5` triggers `trust-trail-evaluator` to emit `STALE` with rationale `audit JSON predates phase2_5 schema; re-run /uberdev:review-pr to refresh trail` — one-time friction; scoped to open PRs only.
- **`/uberdev:merge` accepts three new override flags**: `--accept-blocker-deferred`, `--accept-critical-deferred`, `--i-know-what-im-doing` — all per-invocation only (no env-var, no config key) so muscle-memory use is discouraged.
- **`trust-trail-evaluator` agent gains Phase 2.5 gate** (Process Step 1.5 — runs before structural primitives). Two new `TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM` members: `phase2_5_blocker_deferred`, `phase2_5_override_unacknowledged`.
- **`findings-to-issues` agent**: severity filter extended to `{blocker, critical, important, major}` (was `{blocker, critical}`); BLOCKER/CRITICAL-tier issues now carry `@<pr-author>` @mention + `Blocks: #PR` backref; agent gains `halted: <bool>` + `by_severity: {blocker, critical, major}` + `filed_issue_urls: [...]` + `override_reason: <string|null>` in its return YAML; broken-feature overflow guard fires `halted: true` when truncated rows include BLOCKER/CRITICAL tier.

### Migration

- Existing in-flight PRs see `STALE` trust trail after the version bump per `trust-trail-evaluator` Step 1.5 legacy-audit branch. Re-run `/uberdev:review-pr` once on each open PR to refresh the trail with the new `phases.phase2_5` schema.
- No data migration needed — issues are durable in GitHub; audit JSON is ephemeral per-PR-head and refreshed on each `/review-pr` run.
- No feature flag — plugin code updates atomically when the marketplace pulls the new manifest.

### Notes

- **Scope of the BREAKING tag.** API surface (CLI flags, skill names, agent dispatch shapes) is preserved; behavioral break is in the trust-trail predicate (PR with blocker findings that previously emitted GREEN now emits RED). Audit JSON gains a new block additively; legacy consumers that don't read `phases.phase2_5` see no change in the fields they do read.
- **Solo-dev workflow preservation.** For the personal-TODO-queue workflow ([[user_workflow_todo_queue]]), the design intentionally preserves the "land imperfect work + file TODOs" pattern for `important` / `major` findings (silent file, no halt). The halt path is reserved for `blocker` — by definition the findings the reviewer agents consider unshippable.
- **Rollback procedure.** Pin the marketplace to `0.25.0` in `.claude-plugin/marketplace.json` via the user-side override path; no code rollback is required server-side.

## [0.25.0] - 2026-05-14

### Added

- **Visual companion in orchestrator Phase 2 (`/solve` and `/turbo` medium/large tier)** — `plugins/uberdev/skills/orchestrator/SKILL.md` Phase 2 (Q&A) now offers the browser-based visual companion already shipped with the brainstorm skill (`skills/brainstorm/scripts/server.cjs` + `start-server.sh`, full protocol in `skills/brainstorm/visual-companion.md`). Previously, `/solve` for medium/large issues went straight to text-only `AskUserQuestion` because the orchestrator was built as a separate Phase 2 path that bypassed the brainstorm skill (`skills/brainstorm/SKILL.md:16`); design questions that would benefit from mockups, layout comparisons, or architecture diagrams were forced into prose. The new sub-section adds:
  - (a) **When to offer** — research-bundle / issue-body heuristic: frontend file globs (`*.tsx`/`*.jsx`/`*.vue`/`*.svelte`/`*.css`), directory hints (`components/`/`ui/`/`design/`/`screens/`/`pages/`), OR visual keywords (`layout`/`design`/`mockup`/`color`/`theme`/`wireframe`/`palette`/`typography`/`hierarchy`/`UI`/`UX`).
  - (b) **Consent capture** — verbatim consent message mirroring `skills/brainstorm/SKILL.md:166`, captured via `AskUserQuestion` 2-option vote.
  - (c) **Per-question decision protocol** — visual content (mockups, layout comparisons, architecture diagrams) routes to the browser; conceptual content (scope/requirements/A-B-C text/tradeoff lists) routes to the terminal. Mixing is allowed across the 3-5 Phase 2 questions.
  - (d) **Plugin-root-anchored path resolution** — `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/scripts` with `find ~/.claude/plugins` fallback so the orchestrator can locate `start-server.sh` regardless of its own CWD.
  - (e) **`qa_answers` normalization** — terminal and browser answers share `{question, answer, source: "terminal" | "browser"}` shape; the browser path's authoritative `type:"submit"` event maps to `choice` (or `selections[]` for multi-select).
  - (f) **`waiting.html` unload pattern** — `skills/brainstorm/visual-companion.md:118-127` verbatim, for switching between visual and terminal questions so the user does not stare at a stale resolved mockup.
  - (g) **Turbo skip** — visual companion is interactive-only; the existing `TURBO=1` gate (`skills/orchestrator/SKILL.md` "Turbo detection (hybrid)" section) bypasses the entire flow without invoking `start-server.sh`.
  - (h) **Threat-model inheritance** — `skills/brainstorm/SKILL.md:206-214` (localhost-only bind, no auth, single-user assumption — never `--host 0.0.0.0` in CI/shared-host contexts).

### Notes

- **No new infrastructure.** The change is documentation/protocol only — `server.cjs`, `start-server.sh`, `stop-server.sh`, `helper.js`, `frame-template.html`, and the `inject-brainstorm-answers` plugin hook were already shipped with `41d072b feat(uberdev): full Superpowers parity port` (v0.3.0). The new sub-section teaches the orchestrator to reuse them; nothing in the brainstorm skill changes.
- **Degradation is non-fatal.** If plugin-root resolution fails (custom install layout, missing `find` results), the orchestrator logs to stderr and falls back to terminal-only Phase 2 — visual companion is enrichment, not a hard requirement.

## [0.24.0] - 2026-05-14

### Added

- **Findings-to-Issues sub-phase (`/uberdev:review-pr` Phase 2.5 + `/uberdev:simplify` Phase 3.5)** — persists deferred-critical findings (`severity ∈ {blocker, critical} AND disposition != APPLIED`) from Phase 1 (`post-impl-review`) and Phase 2 (`simplify`) aggregates as durable GitHub issues with HTML-comment fingerprint dedupe. State branching across runs: `state==open` triggers an `Also flagged on commit <SHA>` comment (no duplicate issue); `state==closed` skips (user resolved); no match creates a new issue with `--label review-pr-finding`. Hard cap `MAX_NEW=10` per run; rate-limit pre-flight aborts the sub-phase if `gh api rate_limit` remaining `< 2*MAX_NEW + 50` (verbatim pattern from `commands/review-pr.md:181-198`). All `gh issue create` / `gh issue comment` calls use `--body-file -` with stdin piping (never `--body "$VAR"`). Sub-phase NEVER fails the parent run. Closes #111.
- **`uberdev:findings-to-issues` agent (`plugins/uberdev/agents/findings-to-issues.md`)** — single-shell-turn no-fanout agent dispatched by both `/uberdev:review-pr` Phase 2.5 and `/uberdev:simplify` Phase 3.5. Implements the dedupe + write loop. Verifies aggregate-file inputs are wrapped in `<external-untrusted-input source="post-impl-review-aggregate">` / `simplify-aggregate` envelopes before interpolation. Refuses on `input-malformed`, `rate-limit-budget-insufficient`, or `secret-scan-lib-unavailable`.
- **`--no-defer-issues` CLI flag on `/uberdev:review-pr` and `/uberdev:simplify`** — sets `DEFER_ISSUES_PHASE=0`, short-circuits the Phase 2.5 / Phase 3.5 dispatch. Mirrors `--no-ci-fix` / `--no-simplify` shape.
- **`defer_issues_enabled: <true|false>` config key in `.claude/uberdev.local.md`** — read via the existing `uberdev_read_enum` helper. Default `true` (always-on). Either knob (CLI flag OR config key) is sufficient to disable.
- **`review-pr-finding` GitHub label (auto-provisioned per repo, fail-soft)** — `gh label create --force review-pr-finding --color d93f0b` runs once at the top of the sub-phase; failure emits one stderr warning and proceeds (subsequent `gh issue create --label` calls may degrade to no-label gracefully).

### Refactored

- **Extracted `run_secret_scan_stdin` from `plugins/uberdev/skills/finish-branch/SKILL.md` into shared library `plugins/uberdev/lib/secret-scan.sh` (public name: `uberdev_run_secret_scan_stdin`).** Source-time idempotency guard (`_UBERDEV_SECRET_SCAN_LOADED=1`) mirrors the `lib/config-read.sh` pattern. Behaviour-preserving — gitleaks primary + regex fallback + fail-CLOSED semantics identical to the pre-refactor inline function. `finish-branch/SKILL.md` now sources the library and renames its four call sites. The library is also sourced by the new `findings-to-issues` agent for candidate-body scanning before `gh issue create`. Added `tests/finish-branch.test.sh` as a regression lock.

### Tests

- **`tests/findings-to-issues.test.sh`** — 5 core fixture suites (parser, dedupe-fingerprint, label-idempotency, opt-out flag, config override) + 4 bonus suites (fail-CLOSED dedupe, MAX_NEW cap, secret-scan integration, fingerprint-marker reject). Fixtures under `tests/fixtures/findings-to-issues/` include synthesised aggregate `.md` files (with trust envelopes) + disposition `.yaml` files + opt-out config fixtures. Mocks `gh` inline as a shell function that captures argv and returns canned JSON.
- **`tests/finish-branch.test.sh`** — regression lock for the `lib/secret-scan.sh` extraction (5 assertions: SKILL.md sources the lib, no longer inlines the function, lib exists, lib has idempotency guard, lib retains gitleaks primary + regex fallback).

## [0.23.5] - 2026-05-13

### Fixed

- **Move `pr-test-analyzer` dispatch from orchestrator Phase 5.5 into `subagent-driven-dev` Step 4.5.** The previous design described a logically impossible window: `subagent-driven-dev` invokes `finish-branch` inline, `finish-branch` globs `pr-test-analyzer.md` to compose the PR body, and by the time orchestrator Phase 5.5 could fire the PR had already been pushed without the analyzer's findings. Fix: relocate the dispatch into a new Step 4.5 inside `subagent-driven-dev` (between the post-wave full-test-suite and the `finish-branch` handoff), gated on `tier == "large"` AND `summary_dir` present. The orchestrator's Phase 5 dispatch now passes `summary_dir: $RESEARCH_DIR_ABS/` and `tier` to SDD as additive optional inputs (backward-compatible — non-orchestrator callers gracefully skip Step 4.5). `pr-test-analyzer` is intentionally dispatched twice on large tier — pre-merge (Step 4.5, single `Task()`, feeds the PR body) and post-PR-push (the `uberdev:post-impl-review` 6-agent fanout, feeds `/uberdev:review-pr`'s fix loop). The two dispatches serve different integration points and are not redundant. Closes #92.
  - **Why patch only.** Skill-prose change with observable pipeline effect (dispatch site moves between skills) but no code-shape change and no breaking API — `summary_dir` and `tier` are additive optional inputs to SDD. Mirrors PR #103 convention.
- **orchestrator: refuse interactive /solve in `claude --bg` context.** Added a Phase 0 bg-context gate to `plugins/uberdev/skills/orchestrator/SKILL.md` that evaluates BEFORE run-id generation, artifact-dir creation, and issue-body fetch. Layered detection: turbo exemption (`$ARGUMENTS contains --turbo` OR `${UBERDEV_TURBO:-0} == "1"`) short-circuits first; bg-context test (`[ -n "${CLAUDE_JOB_DIR:-}" ]` OR `[ ! -t 0 ]`) triggers abort with stderr message and `exit 2`. Removes three failure modes documented in #93: indefinite `AskUserQuestion` block, `InputValidationError` collapse when `ToolSearch` was not pre-loaded, and agent-initiated auto-pick that silently turned `/solve` into `/turbo`. The Phase 2 identity rule ("This phase is the only signal that distinguishes /solve from /turbo…") and ToolSearch caveat ("Do NOT silently auto-pick on tool-load failure…") both already forbade the auto-pick path; this gate enforces that contract structurally by removing the precondition. Stderr message generalises to "interactive orchestrator (/solve or /uberdev:orchestrator without --turbo)" so the standalone-invocation path is named accurately. Tests added: `tests/orchestrator-phase-0-bg-detection.test.sh` (A1-A7 — both detection arms, literal stderr, exit 2, turbo-exemption ordering, MUST imperative wording, fail-fast position, Phase 2 detector unchanged). Closes #93.
  - **Why patch only.** Single SKILL.md prose block, one new structural-grep test, additive only. No new env vars, no new CLI flags. `/turbo` users see no change (turbo exemption fires); interactive `/solve` users in a foreground terminal see no change (TTY arm is false); only the previously-hanging path (`/solve` under `claude --bg`) gets the new abort behaviour.

## [0.23.4] - 2026-05-13

### Refactored

- **Replace brittle 3-layer `--turbo` arg-forwarding chain with `UBERDEV_TURBO=1` env-var inheritance.** The chain `orchestrator → subagent-driven-dev → finish-branch → review-pr` previously forwarded `--turbo` as an LLM-interpreted argument across four prompts; a drop at any layer collapsed `/turbo` semantics silently (the chain fell back to interactive prompts inside a `claude --bg` session, which then deadlocked). Now the bit is set once at the pipeline entry point (`commands/turbo.md` `export UBERDEV_TURBO=1`) and propagates via two boundaries: (a) Skill() boundary (same agent process, in-process env table) into `solve-pipeline`; (b) OS process boundary (POSIX fork+exec) into `claude --bg` via inline-prefix exec `UBERDEV_TURBO=1 claude --bg …`. Each downstream consumer reads `[[ "${UBERDEV_TURBO:-0}" == "1" ]]`. `commands/solve.md` adds `unset UBERDEV_TURBO` to defend against shell-rc pollution. Mirrors `AUTO_MODE` (PR #19) and `UBERDEV_AUTO_REVIEW_ON_MERGE` (PR #90) precedents. **Hybrid arg-OR-env detector preserved on `orchestrator` and `commands/review-pr`** for legit standalone-invocation paths (`/uberdev:orchestrator --turbo …`, `merge-pipeline`'s separate `Skill("uberdev:review-pr", args: "${PR} --turbo")` dispatch). `subagent-driven-dev` and `finish-branch` are env-var-only (chain-internal). Test surface refactored: `tests/turbo-flow.test.sh` rewritten in dedicated commit `test(turbo-flow): assert UBERDEV_TURBO env-var propagation`. Closes #97.

## [0.23.3] - 2026-05-13

### Added

- **`review-pr:pending` label backstop one layer upstream of `/merge`.** Mirrors the v0.23.0 `/merge` trust-trail backstop at the previous chain link. `plugins/uberdev/skills/finish-branch/SKILL.md` now adds the `review-pr:pending` GitHub PR label (via `gh label create --force` + `gh pr edit --add-label`, both fail-soft per the fire-and-surface contract) immediately before invoking `uberdev:review-pr` via the `Skill` tool. `plugins/uberdev/commands/review-pr.md` Trust-Signal Emission block clears the label on green outcome (fail-soft per spec D4 — the label may legitimately not exist when `/review-pr` is invoked directly). `plugins/uberdev/skills/merge-pipeline/SKILL.md` Step 1.4.5 gains a new positive-signal label-presence probe (gated by `AUTO_REVIEW_ON_MERGE`) that short-circuits trust-trail reason resolution by assigning `reason="trust_trail_label_missing"` directly. **No new `AUDIT_EVENT_ENUM` or `GATE_FAIL_REASON_ENUM` members** — D1 reuses the existing `trust_trail_label_missing` value. The label is the durable cross-process signal: it survives session boundaries and any tool with `gh` access can inspect it. New named constant `REVIEW_PR_PENDING_LABEL = "review-pr:pending"` in `merge-pipeline/SKILL.md` Constants table. The `AUTO_REVIEW_DISPATCH_CAP = 1` cap-ordering invariant from v0.23.0 is preserved (counter write still precedes `Skill()` dispatch). Tests added: `tests/finish-branch-auto-chain.test.sh` (#95.1–#95.5 — label-add presence, line-order guard, fail-soft contract), `tests/review-pr.test.sh` R21 (label-remove presence, prose-anchor, fail-soft tombstone, section-anchor), `tests/merge.test.sh` M86 (Constants row, probe presence, gate, reason-reuse, `AUDIT_EVENT_ENUM` set-equality, cap-ordering preservation, Common Mistakes anchor). Total 16 new assertions. Closes #95.
  - **Why patch only.** Mirror of the v0.23.0 backstop one layer upstream; no new public CLI flags; default-off behaviour is bit-identical for users not opted into `AUTO_REVIEW_ON_MERGE`.

## [0.23.2] - 2026-05-13

### Fixed

- **solve-pipeline:** route trivial/small heredocs through `uberdev:finish-branch` instead of inline `gh pr create` + prose Skill-invoke. All four trivial/small heredocs now end with a `Hand off to uberdev:finish-branch` directive (turbo variants append `--turbo`); the agent retains the commit step. finish-branch owns push, `gh pr create` with URL validation, and the canonical `Skill("uberdev:review-pr")` chain hand-off (with `--turbo` forwarded). All tiers now converge on the same single PR-creation + review-pr chain site, closing the silent-drop gap where a child `claude --bg` agent exiting after `gh pr create` (permission denial, classifier abort) would bypass the global mandatory-review-after-push rule. `tests/turbo-flow.test.sh` re-anchored to the new positive (Hand-off=4, finish-branch `--turbo`=2) and negative (`gh pr create`=0 inside trivial/small slice) contract; pre-push-simplify directive count=4 preserved. Closes #91.

## [0.23.1] - 2026-05-13

### Documentation

- **`plugins/uberdev/skills/orchestrator/SKILL.md`**: Added `### Phase 6: PR creation + review chain` to make the `subagent-driven-dev → finish-branch → /uberdev:review-pr` cascade explicit inside the orchestrator skill. Deleted the misleading `## End-of-pipeline` section that previously read "the orchestrator's job is done" after Phase 5. Phase 6 names the two downstream `/uberdev:review-pr` phases (Phase 1: 6 advisory reviewers via `uberdev:post-impl-review`; Phase 2: 3 simplify lenses) and acknowledges the large-tier `Phase 5.5` ordering. Closes #94.

## [0.23.0] - 2026-05-13

### Added

- **Opt-in `/merge` Phase 1.4 auto-dispatch of `/review-pr` when trust trail is missing.** Gated by per-repo config key `auto_review_on_merge: true|false` (default `false`) with env override `UBERDEV_AUTO_REVIEW_ON_MERGE`. Conservative trigger filter — fires ONLY on `trust_trail_label_missing` and `trust_trail_trailer_missing`. Bounded: 1 auto-review per PR per `/merge` run (named constant `AUTO_REVIEW_DISPATCH_CAP = 1`). Two new `AUDIT_EVENT_ENUM` members: `auto_review_dispatched`, `auto_review_returned`. Default-off path is bit-identical to current `/merge` (zero new audit events, zero new wall-clock). Static shape-checks ship now (M74–M85, U9.1–U9.5); runtime-emission tests deferred until the existing `tests/merge-discovery-resilience.test.sh` harness can stub the `Skill()` call (tracked as follow-up; see spec §Risks R3). Closes #89.

## [0.22.2] - 2026-05-12

### Fixed
- **`/turbo` and `/solve` failed to dispatch under zsh — every `claude --bg` invocation exited with `error: unknown option '--effort max'`.** v0.22.1 (#87) shipped the `--effort` threading as scalar variables (`PERM_FLAG="--permission-mode auto"`, `EFFORT_FLAG="--effort $EFFORT_LEVEL"`) and relied on word-splitting of the unquoted `$PERM_FLAG $EFFORT_FLAG` tokens in the dispatch case-arms to produce separate argv slots. That assumption holds under bash but NOT under zsh — zsh's default `SH_WORD_SPLIT=off` keeps `"--effort max"` as a single argv slot, which `claude --bg` rejects. Since zsh is the default shell on macOS (and the Claude Code Bash tool inherits the user's shell), every dispatch on a macOS host failed at the wave-batch boundary. The CI tests passed green because `tests/solve-effort-flag.test.sh` runs under `#!/usr/bin/env bash` — the bash-only test runner masked the regression in the actual production shell. Same trap that the earlier `TIMEOUT_BIN` block already documented inline, but applied to the wrong code path.
  - **Fix.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Phase A hoist converts both flags to bash+zsh arrays (`PERM_FLAG=()` / `PERM_FLAG=( --permission-mode auto )`; `EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )`). All three dispatch case-arms (`file` / `stdin` / `argv` in Step 5b') expand via `"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, which preserves one argv slot per element identically in bash and zsh regardless of `SH_WORD_SPLIT`. Empty arrays expand to zero slots, populated arrays to their elements verbatim.
  - **Tests.** `tests/solve-pipeline-zsh.test.sh` (NEW, 7 assertions) — zsh-runtime regression fixture that EXECUTES the dispatch composition under a real `#!/usr/bin/env zsh` shell, captures the dispatched argv via a stub `claude` on PATH, and asserts `--effort` + level land as separate adjacent argv slots (R2) and that the AUTO_PERMISSIONS path also splits correctly (R3). Includes a negative `--effort max` collapsed-slot tombstone. Wired into `.github/workflows/test.yml` with a `sudo apt-get install -y zsh` step on the ubuntu-latest runner. `tests/dispatch-claude-bg.test.sh` re-anchored on the array hoist (`^EFFORT_FLAG=\( --effort `, `^PERM_FLAG=\(\)$`, `PERM_FLAG=\( --permission-mode auto \)`), and the `${PERM_FLAG[@]} ${EFFORT_FLAG[@]}` token-pair count switched to the array-quoted form (`"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, ≥3 occurrences); added a scalar-form tombstone that fails if a future edit reverts to the broken `$PERM_FLAG $EFFORT_FLAG` shape. `tests/solve-effort-flag.test.sh` R3 mirror updated to the array form so the bash test stays in sync with the SKILL.md.
  - **Why patch only.** Pure bug fix in the dispatch shape; no new flags, no behavioural change for users invoking `/solve` or `/turbo` correctly. Patch-version bump per the bump-everywhere rule so the marketplace pulls the fix.

## [0.22.1] - 2026-05-12

### Fixed
- **`/turbo` (and `/solve`) silently downgraded child-agent quality because `claude --bg` does NOT inherit the parent session's `/effort` setting.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 5b''s three case-statement arms (`file` / `stdin` / `argv`) composed the bg-dispatch argv as `… --model "$MODEL" $PERM_FLAG …` with no `--effort <level>` token. `claude --effort <level>` is a real CLI flag in Claude Code 2.1.139 accepting `low | medium | high | xhigh | max`, but in the absence of explicit pass-through every spawned bg session fell back to the supervised daemon's default. For `/turbo` — which runs unattended — the user-facing symptom was that setting `/effort max` (or anything else) in the parent session had **zero** effect on the dispatched solver agents, so any quality benefit from a higher effort level evaporated at the worktree boundary. The downgrade was invisible: no warning, no audit entry.
  - **Fix.** Phase A now parses `--effort=<level>` from `$ARGUMENTS` and resolves an `EFFORT_LEVEL` via the same precedence chain `/solve` already uses elsewhere (`SOLVE_AUTO`, `SOLVE_TIMEOUT`): **CLI flag > `UBERDEV_SOLVE_EFFORT` env var > `solve_effort:` in `.claude/uberdev.local.md` > `EFFORT_LEVEL_DEFAULT` (`max`)**. The hoisted `EFFORT_FLAG="--effort $EFFORT_LEVEL"` is threaded into all three case-statement arms immediately after `$PERM_FLAG`, so word-split preserves `--effort` and the level as two separate argv slots. Default is `max` because `/turbo` is autopilot — wall-clock and cost are secondary to quality; interactive `/solve` callers who want to spend less can pass `--effort=high` or set the repo-wide config key.
  - **Validation.** Invalid levels (typos like `--effort=hgh`, env values like `UBERDEV_SOLVE_EFFORT=ludicrous`) are rejected loudly at Phase A with an actionable stderr message naming the enum — `claude --effort hgh` would otherwise fail at the child with a less obvious error.
  - **Telemetry.** New `effort_resolved` audit event (added to `SOLVE_AUDIT_EVENT_ENUM`) records `{source: cli|env|config|default, level}` for each dispatch. Mirrors the `deprecated_flag_used` precedent.
  - **Constants table** gains `EFFORT_LEVEL_DEFAULT` (`max`) and `EFFORT_LEVEL_ENUM` (`low | medium | high | xhigh | max`). Audit-event enum extended with `effort_resolved`.
  - **Docs.** `commands/solve.md` and `commands/turbo.md` Usage lines gain `[--effort=<level>]`; both ship a one-paragraph note documenting the default, precedence chain, and rationale.
  - **Tests.** `tests/dispatch-claude-bg.test.sh` extended with 10 new anchored-grep assertions covering Constants entries, parser block, env override, audit emit, EFFORT_FLAG hoist, and the `$PERM_FLAG $EFFORT_FLAG` token-pair count in all three case arms. `tests/solve-effort-flag.test.sh` (NEW) — runtime fixture: extracts the Phase A parser block via awk markers, evaluates it against the five precedence-ladder paths (default / CLI wins / env wins / config wins / all five enum values), asserts invalid CLI and env values exit non-zero with the enum-name stderr, and asserts the dispatched-argv (captured by a stub `claude` on PATH) contains `--effort` and the level as separate slots in order. Wired into `.github/workflows/test.yml`. Pre-fix run on the new assertions: fail. Post-fix: all 13 new + 10 added assertions pass, full suite remains green (1046 assertions across 19 test scripts).
  - **Out of scope.** Auto-detecting the parent session's `/effort` setting and inheriting it. Claude Code 2.1.139 does not expose that to children via env or any documented introspection surface; inheritance would require an upstream RFE. The default-of-`max` plus explicit override is the pragmatic fix.

## [0.22.0] - 2026-05-12

### Changed
- **`/uberdev:solve` and `/uberdev:turbo` now dispatch `claude --bg` background sessions instead of opening per-issue terminal windows (#85).** The five-branch `case "$TERMINAL" in cmux) … ghostty) … iterm) … terminal) … nohup|*) … esac` block (`solve-pipeline/SKILL.md` Step 5c) is retired wholesale. Monitor sessions via `claude agents` (Agent View). Hard-requires Claude Code >= 2.1.139.
- **`/turbo` parallelism is capped via `fanout_concurrency.solve_bg` (default 6, range [1, 50]).** Mirrors `fanout_concurrency.merge_strategy` (#49 / v0.17.0). Larger queues split into `ceil(N / cap)` sequential single-message dispatch waves with per-wave `solve_bg_fanout_wave_started` audit events.
- **Orchestrator artifact paths anchored to `$(git rev-parse --show-toplevel)`.** `.uberdev/research/$RUN_ID/` is now resolved via `--show-toplevel` instead of relative-CWD interpolation. Closes the worktree path-leak documented in `memory/project_uberdev_artifact_path_leak.md` (research-patterns / spec-writer artifacts previously landed in the parent project root and required a manual `cp` to the worktree).

### Deprecated
- **`--terminal=cmux|ghostty|iterm|terminal|nohup` flag and `$SOLVE_TERMINAL` env var.** Parsed without error, emit `TERMINAL_FLAG_DEPRECATED_NOTE` once per run on first encounter, record `deprecated_flag_used` audit event, no behavioural effect. Removal target: v1.0.0. Pattern matches `--squash` / `--rebase` retirement in #49 / v0.17.0 and `--bypass-protections` retirement in #35 / v0.17.0.
- **`solve_terminal` config key in `.claude/uberdev.local.md`.** Same retirement — parsed but ignored. `using-uberdev/SKILL.md` no longer documents the key.
- **`SOLVE_GHOSTTY_NEW_WINDOW=1` env var.** The Ghostty new-window codepath is retired; the env var is parsed but has no behavioural effect.

### Removed
- `solve-pipeline/SKILL.md` Step 3 terminal detection block (cmux socket detection, `$TERM_PROGRAM` cascade, `$REAL_CLAUDE` PATH walk).
- `solve-pipeline/SKILL.md` Step 5b launcher shell script heredoc (`/tmp/solve-$ISSUE_NUM.sh`, the `cd "REPO_ROOT"` prologue, the worktree-cleanup pre-step, the `${TIMEOUT_BIN} ${SOLVE_TIMEOUT} CLAUDE_BIN … --worktree solve-issue-$ISSUE_NUM …` invocation).
- `solve-pipeline/SKILL.md` Step 5c per-terminal dispatch case statement (cmux / ghostty / iterm / terminal / nohup branches) and the 0.6s inter-Ghostty sleep guard.
- `solve-pipeline/SKILL.md` Step 6 cmux-notify / terminal-notifier / osascript-display-notification chain. Replaced by single stderr echo. Closes latent `osascript-e-shell-var` ERROR-class security finding as a side-effect.
- `solve-pipeline/SKILL.md` Step 7 OSC tab-retitle / cmux workspace-rename block. Agent View shows session names natively from `--worktree solve-issue-N`.
- `tests/cmux-detection.test.sh` (no longer applicable; replaced by tombstone assertions in `tests/dispatch-claude-bg.test.sh` + `tests/ghostty-dispatch-no-instance-leak.test.sh`).

### Tests
- `tests/ghostty-dispatch-no-instance-leak.test.sh` extended into a broader tombstone test: assertions added for `cmux new-workspace`, `osascript -e`, `tell application "iTerm"`, `tell application "Terminal"`, `nohup zsh -l` absence. The original `open -na Ghostty --args --command=` regression guard (PR #33) is preserved verbatim; the `#31` issue reference in solve-pipeline SKILL.md is preserved (historical rationale).
- `tests/dispatch-claude-bg.test.sh` (NEW) — positive shape-check for the three-arm `BG_PROMPT_MODE` case-switch (`file` / `stdin` / `argv`; only `argv` fires today since `BG_PROMPT_MODE=argv` is hardcoded — `_uberdev_probe_bg_prompt_mode` was removed in `fix(solve)` 0c17169 because `claude --bg --help` is not introspective in v2.1.139), Phase A version gate (`_uberdev_require_claude_version "2.1.139"`), wave-batching (`MAX_PARALLEL_BG_AGENTS`, `solve_bg_fanout_wave_started`), deprecation shim (`TERMINAL_FLAG_DEPRECATED_NOTE`, `deprecated_flag_used`), and anti-pattern guards (no `claude --bg "$PROMPT"`, no `eval "claude --bg …"`). Wired into `.github/workflows/test.yml`.
- `tests/turbo-flow.test.sh` retrofitted: REAL_CLAUDE-hoist assertion retired and replaced with Phase A hoist assertion (anchors on `_uberdev_require_claude_version "2.1.139"` or `BG_PROMPT_MODE=argv`); Ghostty inter-spawn sleep assertion removed; new assertions for `MAX_PARALLEL_BG_AGENTS`, `uberdev_read_int_in_range fanout_concurrency.solve_bg`, `solve_bg_fanout_wave_started`, `_uberdev_require_claude_version "2.1.139"`. The differential guard awk anchor `^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$` (line 92) is preserved verbatim — the trivial and small heredoc bodies retain `!=1` form (interactive branch first, turbo in `else`) per the post-impl-review.test.sh contract.
- `tests/config-override.test.sh` I2 section updated: I2d asserts `"$TIMEOUT_BIN" "$SOLVE_TIMEOUT" claude --bg` instead of `… CLAUDE_BIN`; new I2g asserts the three-arm `BG_PROMPT_MODE` case-switch presence. I2a / I2b / I2c / I2e / I2f preserved verbatim.

### Migration
- Callers on Claude Code < 2.1.139 see an actionable error on `/solve` invocation: `error: /solve and /turbo require Claude Code >= 2.1.139 (found: <X>). install with: npm i -g @anthropic-ai/claude-code@latest`. Update Claude Code, then re-run.
- Callers passing `--terminal=cmux` (or any value) see one stderr line per run (`TERMINAL_FLAG_DEPRECATED_NOTE`); dispatch proceeds via `claude --bg` regardless. Remove the flag from your habit / aliases when convenient. `$SOLVE_TERMINAL` env var emits a parallel deprecation note.
- Users with `solve_terminal: <value>` in `.claude/uberdev.local.md` should remove the line. The key parses but has no behavioural effect.
- Artifact-path-leak fix: orchestrator-managed artifacts under `.uberdev/research/$RUN_ID/` now anchored to `$(git rev-parse --show-toplevel)`. No user action required.

### Security
- **Closed `claude-bg-arg-injection` (ERROR-class, hypothetical).** The Step 5b' dispatch case-switch prefers `--prompt-file` > stdin pipe > positional argv-via-bash-array (no `eval`). The naive `claude --bg "$PROMPT"` shape is explicitly forbidden by inline anti-pattern comment + `tests/dispatch-claude-bg.test.sh` regression guard.
- **Closed `osascript-e-shell-var` (ERROR-class, latent at former `solve-pipeline:484`).** Step 6 retirement (osascript display notification) eliminates the interpolation site.
- **Closed `applescript-keystroke-shell-var` / `applescript-do-script-shell-var` / `cmux-new-workspace-with-var` (WARNING-class, 4 sites).** Step 5c retirement eliminates every AppleScript / cmux IPC interpolation.
- **Hardened `_uberdev_audit_emit` against JSON injection** (`fix(solve)` 0c17169). The two audit-emit call sites for `$TERMINAL_FLAG_USED` / `$SOLVE_TERMINAL` route values through `jq -Rs .` so env values containing quotes / backslashes / newlines produce valid escaped JSON.

## [0.21.6] - 2026-05-12

### Fixed
- **`/solve` wall-clock kill never engaged on macOS.** `plugins/uberdev/skills/solve-pipeline/SKILL.md` Step 5b's heredoc-template launcher probed `command -v timeout` only — but macOS does **not** ship GNU `timeout(1)`. The only supported install path (`brew install coreutils`) places the binary at `gtimeout` (Homebrew's `g`-prefix avoids masking BSD utilities), so the wrap branch was dead code for the entire macOS audience: stock boxes hit the fail-open warning, and `brew install coreutils` did nothing to fix it. The user-facing symptom was `warning: timeout(1) not on PATH; /solve will run unwrapped (no wall-clock kill)` firing on every `/solve` and `/turbo` launch, with `command_timeouts.solve` (default 3600s) silently unenforced. /turbo, which runs unattended, was the most exposed: a stuck Opus-4.7 1M-context agent could burn tokens until the user manually noticed.
  - **Fix.** The launcher template now probes `timeout` then `gtimeout` and binds the resolved path to `TIMEOUT_BIN`; the wrap branch becomes `"$TIMEOUT_BIN" "${SOLVE_TIMEOUT}" CLAUDE_BIN …`. The quoted-`"$TIMEOUT_BIN"` form keeps it as a single `argv[0]` token under zsh `SH_WORD_SPLIT=off` (mirrors the inline-`timeout` zsh-safety precedent from #63/#72). Comment block updated to call out the `gtimeout` rationale explicitly.
  - **Misleading prose corrected.** The Step 5b narration previously called the missing-timeout case "rare on bare macOS without coreutils". It was actually the **default** behaviour on every macOS box (with or without coreutils). Rewritten to state that macOS does not ship GNU `timeout(1)`, that `brew install coreutils` installs it as `gtimeout`, and that fail-open fires only when **neither** binary is on PATH.
  - **Remediation pointer in the warning.** The fail-open stderr line previously read `warning: timeout(1) not on PATH; /solve will run unwrapped (no wall-clock kill)` — mystery, not action. Now: `warning: neither timeout(1) nor gtimeout on PATH; /solve will run unwrapped (no wall-clock kill). Fix: brew install coreutils`.
  - **Sibling doc synced.** `plugins/uberdev/skills/using-uberdev/SKILL.md` "Enforcement scope" paragraph (lines 193-196) now mentions the `gtimeout` fallback so the user-facing config reference matches the launcher behaviour.
  - **Tests.** `tests/config-override.test.sh` I2 block extended: I2c now asserts `command -v gtimeout` appears in the SKILL.md heredoc, I2d asserts the new `"$TIMEOUT_BIN" "${SOLVE_TIMEOUT}" CLAUDE_BIN` wrap form (replaces the old I2c `timeout "${SOLVE_TIMEOUT}" CLAUDE_BIN` literal regex which no longer matches), I2e asserts the warning contains the `brew install coreutils` remediation pointer. Pre-fix run: I2c/I2d/I2e fail. Post-fix run: all five I2 assertions pass; full suite remains green (77/77 config-override, 1080/1080 across 18 test scripts).
  - **Backward compatibility.** Linux and any macOS box with `timeout` shimmed onto PATH (e.g. via `brew install coreutils --with-default-names` on Intel, or manual symlink) continue down the original probe-and-wrap branch unchanged — `command -v timeout` still matches first.

## [0.21.5] - 2026-05-11

### Fixed
- **`/merge` skill double-load due to command/skill name collision.** `commands/merge.md` and `skills/merge/SKILL.md` both registered under plugin-namespaced ID `uberdev:merge` — `merge` was the only uberdev surface where a slash command and a skill shared a name (every other command — `/solve`, `/issue`, `/review-pr`, `/simplify`, `/turbo` — is command-only). The collision surfaced as a duplicate `uberdev:merge` entry in the system-reminder "skills available" listing (one with the command description, one with the skill description) and at runtime as `commands/merge.md` plus `skills/merge/SKILL.md` both being pulled into context for a single `/merge` invocation. Auto-discovery on the skill's `Use when the user invokes /merge…` description compounded the load on any non-slash mention of merge intent.
  - **Rename.** `plugins/uberdev/skills/merge/` → `plugins/uberdev/skills/merge-pipeline/` (skill `name:` frontmatter `merge` → `merge-pipeline`). The skill is now an internal implementation detail invoked exclusively by `commands/merge.md`; its description was rewritten as `Internal 4-phase pre-flight/plan/merge-resolve/sync pipeline for the /merge command. Invoked exclusively by commands/merge.md; do not call directly.` so it no longer auto-discovers on user mentions of `/merge`.
  - **Invocation update.** `commands/merge.md:49` now invokes `uberdev:merge-pipeline` (was `uberdev:merge`).
  - **Internal lib path updates.** Three `${CLAUDE_PLUGIN_ROOT}/skills/merge/lib/discover.sh` references in SKILL.md (Steps 1.0.5, 1.2.5, 1.4) repointed to `${CLAUDE_PLUGIN_ROOT}/skills/merge-pipeline/lib/discover.sh`.
  - **Cross-reference path updates.** Repointed across `agents/merge-strategy-decider.md`, `agents/conflict-resolver.md` (description + calling-skill ref at line 56), `agents/trust-trail-evaluator.md`, `agents/ci-rebase-handler.md`, `commands/review-pr.md` (six occurrences across Phase 3 + trust-signal artifacts + Run-ID format prose), and the two SKILL.md mirror-site enumerators in the "Author identity is NOT a gate condition" section. Historical `skills/merge/` paths in past CHANGELOG entries are left as-is — they're frozen narration of past states.
  - **Test-shape updates.** Four test files updated to track the new path: `tests/merge.test.sh` (`SKILL_FILE` constant, M3 header/regex, M4 echo header), `tests/merge-discovery-resilience.test.sh` (`LIB` / `SKILL` constants + A4d glob regex), `tests/review-pr.test.sh` R19 (`MERGE_SKILL` constant), `tests/review-pr-phase3-ci.test.sh` (`MERGE_SKILL` constant).
  - **Regression guard (NEW in M3).** `tests/merge.test.sh` M3 gains a `M3.collision` assertion that fails if `commands/merge.md` ever re-references the bare `uberdev:merge` skill (which would re-introduce the name collision with the command). M3 positive assertion now demands `uberdev:merge-pipeline\b`.
  - **No user-facing slash-command change.** `/merge` and `/uberdev:merge` continue to work exactly as before — those are commands (not skills) and their names did not change. Only the internal skill behind them moved.

## [0.21.3] - 2026-05-10

### Changed
- **`PATCH_LINE_CAP` raised from 200 → 500.** The conflict-resolver agent's per-file rejection threshold (declared at `plugins/uberdev/skills/merge/SKILL.md:25` Constants table; enforced at `plugins/uberdev/agents/conflict-resolver.md:31` Step 6 sanity-check; cited at `plugins/uberdev/skills/merge/SKILL.md:682` Red Flags) now accepts resolutions up to 500 lines.
  - **Strictly additive.** Previously-accepted resolutions remain accepted; previously-`REFUSED`-on-cap resolutions now have a 2.5× larger headroom before tripping the guard.
  - **Other refusal triggers unchanged.** `PATCH_FILE_CAP=5`, secret-shaped strings, out-of-hunk edits, prompt-injection-shaped markers, `.github/`/`.git`/hooks paths, and generated lockfiles are all preserved.
  - **Safety analysis.** The textual-evidence requirement at `plugins/uberdev/agents/conflict-resolver.md:28` Step 3 (each agent edit must cite a verbatim quote from each side) implicitly bounds legitimate patch volume to the union of the two conflict sides. The line cap is therefore a soft upper bound on legitimate volume, not a security guard against runaway agents — those are owned by the refusal triggers enumerated above.
  - **Why patch only.** Pure constant change (test shape, public API, and runtime behaviour all unchanged); patch-version bump per the bump-everywhere rule.

## [0.21.4] - 2026-05-10

### Fixed
- **`/review-pr` Phase 3 stale_base CONFLICT-resolve arm — caller-side procedural arm wired in (#80).** PR #76 (`feat(review-pr): add Phase 3 — CI Health`, v0.21.0) shipped `agents/ci-rebase-handler.md` with the explicit hand-off contract that on `status: CONFLICT, conflicted_files: [...]` the caller's main turn dispatches one `Task(subagent_type: uberdev:conflict-resolver)` per file in a SINGLE message (mirroring `merge/SKILL.md` Phase 3.3.iii–iv). The agent contract was sound; the matching procedural arm in `commands/review-pr.md` Step 6c.5 POST-FIX was never written. The latent gap defeated `/review-pr`'s entire CI-health autopilot for any `stale_base` PR with conflicts: a `CONFLICT` return either silently fell through to POST-FIX's "fixer pushed a commit" flow (no commit was actually pushed — Phase 1 re-entry then ran against unchanged HEAD, returned APPROVE, and emitted the trust signal on a still-broken rebase state) or the orchestrator halted with no user-facing explanation. Neither outcome matched the agent contract's promise.
  - **Fix.** `commands/review-pr.md` Step 6c.5 POST-FIX now opens with a "Branch on dispatched-fixer return status" preamble that explicitly conditions on `ci-code-fixer` `status: APPLIED | REFUSED` and `ci-rebase-handler` `status: REBASED | CONFLICT | REFUSED`, then runs the matching procedural arm. The new **CONFLICT-RESOLVE arm** re-creates the conflict state in the PR worktree (re-fetch + re-run rebase, capturing `EXPECTED_OLD_SHA` for the resume-push lease), resolves `CONFLICT_RESOLVER_CAP` from `lib/config-read.sh` (default 10, env override `UBERDEV_FANOUT_CONFLICT_RESOLVER`, range [1, 50]), splits `len(conflicted_files) > cap` into `ceil(len / cap)` sequential single-message waves, and dispatches one `Task(subagent_type: uberdev:conflict-resolver)` per file in a single assistant turn (matches `merge/SKILL.md` Phase 3.3.iii cap-resolve + fanout shape). Aggregation:
    - **All `RESOLVED`:** `git add` + `git rebase --continue` + push under the original lease (`--force-with-lease="$pr_head_branch":"$EXPECTED_OLD_SHA" --force-if-includes`). On push success → emit `ci_fix_pushed` with `data.by_agent="ci-rebase-handler+conflict-resolver"` (composite); fall through to existing Phase 1 re-entry. On lease-mismatch → `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_lease_mismatch`; exit 1.
    - **Any `AMBIGUOUS`:** `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_ambiguous`; exit 1.
    - **Any `REFUSED`:** `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_conflict_refused`; exit 1.
  - **Five new typed `data.subreason` values** for `ci_phase_outcome` audit events: `rebase_conflict_ambiguous`, `rebase_conflict_refused`, `rebase_lease_mismatch`, `rebase_continue_failed`, `rebase_push_failed`. These join the existing free-form-ish subreason vocabulary (`flaky_rerun_failed`, `post_fix_review_rejected`) — no new `CI_OUTCOME_ENUM` row, since `data.outcome` stays at `halted`. The latter two pin failure modes the original arm silently swallowed: `rebase_continue_failed` for non-zero `git rebase --continue` exit (pre-commit hook reject / GPG signing failure / unrecoverable continuation state) with no fresh conflict set; `rebase_push_failed` for non-lease-mismatch push failures (auth, pre-receive hook, rate-limit, network) — without these the `ci_fix_pushed` audit event would emit falsely. Two more documented for the `ci-rebase-handler` `status: REFUSED` arm (`ci_rebase_refused_<reason>`) and the `ci-code-fixer` `status: REFUSED` arm at the Phase 3 dispatch site (`ci_fixer_refused_<rationale>`).
  - **Anti-pattern guard restated.** The CONFLICT-RESOLVE arm is single-shot per `ci-rebase-handler` dispatch and bounded by `CI_FIX_LOOP_CAP = 3` from 6c.7 LOOP GUARD. The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge/SKILL.md:523` (in "PARK is the terminal floor" prose) is restated inline.
- **`tests/review-pr-phase3-ci.test.sh` now runs in CI.** PR #76 added the suite (9 scenarios + 3 agent-shape blocks) but did not wire it into `.github/workflows/test.yml`, so the Phase 3 prose contracts were unguarded against regression on `push` / `pull_request` events. Added to the workflow's `bash …` chain between `review-pr.test.sh` and `finish-branch-auto-chain.test.sh`. The new S13 assertions (below) inherit CI coverage from this wiring.

### Tests
- **`tests/review-pr-phase3-ci.test.sh` S13 (NEW, 17 assertions)** locks the procedural arm into the prose so a future edit cannot silently regress to the "POST-FIX assumes REBASED" shape: S13.1 (`uberdev:conflict-resolver` dispatched in Phase 3 CONFLICT path), S13.2 (`conflicted_files` YAML field referenced), S13.3 (`status: CONFLICT` conditional present), S13.4 (single-message Task() invariant), S13.5 (`CONFLICT_RESOLVER_CAP` cap referenced by name), S13.6 / S13.7 / S13.8 (typed `rebase_conflict_ambiguous` / `rebase_conflict_refused` / `rebase_lease_mismatch` `data.subreason` values), S13.9 / S13.10 / S13.11 (post-resolution push uses `--force-with-lease=<branch>:<sha>` + `--force-if-includes` + `EXPECTED_OLD_SHA` original-lease SHA), S13.12 (`git rebase --continue` runs on RESOLVED), S13.13 (`git rebase --abort` runs on AMBIGUOUS / REFUSED / lease-mismatch), S13.14 (cross-references `merge/SKILL.md` Phase 3.3 reference pattern), S13.15 (`OUTCOME=halted` surface for non-RESOLVED terminal cases), S13.16 (POST-FIX path explicitly conditions on `status: REBASED`), S13.17 (composite `data.by_agent="ci-rebase-handler+conflict-resolver"` audit string pinned on conflict-resolve push success). Suite total: 77 PASS / 0 FAIL (was 65). Adjacent suites unchanged: `tests/review-pr.test.sh` (112/112), `tests/merge.test.sh` (265/265), `tests/post-impl-review.test.sh` (31/31), `tests/audit-fixups.test.sh` (22/22).

## [0.21.2] - 2026-05-07

### Fixed
- **`/merge` Phase 1.4 PATH_2 sub-condition (d) gate-failure storm (#78).** The trust-trail JSON gate had two compounding bugs that surfaced when a downstream consumer ran `/merge` against PR #36 with four prior `/review-pr` runs in `.uberdev/runs/`:
  - **No PR-filter.** `skills/merge/SKILL.md:333` described sub-condition (d) as `∃ a file matching .uberdev/runs/<run-id>/review-pr-verdict.json` with no constraint on `<run-id>` and no constraint on the JSON's `.pr` field. The /merge agent's ad-hoc bash globbed every JSON in `.uberdev/runs/` and demanded each `.sha` equal `headRefOid`. Prior `/review-pr` runs (whether from earlier states of this PR or from other PRs in the same repo) left stale JSONs whose SHAs were correct *for their run* but no longer matched the current PR HEAD. Result: gate_fail across all 4 of them, even when one of them was the JSON for the current PR with a valid SHA. The gate got *harder* the more `/review-pr` history a repo accumulated — the absurd workaround was `rm -rf .uberdev/runs/`.
  - **Strict `"sha" == headRefOid` contradicted (c)'s fixup tolerance.** `SKILL.md:341` promises *"Honest fast-forward fixup commits added between /review-pr and /merge … evaluate to PASS"* — sub-condition (c) (the `trust-trail-evaluator` agent) honors this via cumulative-diff-empty heuristics. (d)'s strict equality did not. Any empty-anchor-on-top, sibling-equivalent `commit --amend`, or trivially-empty fixup moved `headRefOid` and broke (d) while (c) still PASSed. (d), explicitly framed as **corroborating-only** at line 333, was gating *harder* than the load-bearing (c) check.
  - **Producer recipe ambiguity.** `commands/review-pr.md:437` left the JSON's `"sha"` field as `<full-40-char-head-sha>` — undefined. The recipe at lines 416-420 only named `PARENT_SHA` (pre-anchor). Whether the JSON should record `PARENT_SHA` (matching the trailer payload) or post-anchor HEAD (matching `gh pr view --json headRefOid`) was left to agent inference, allowing producer drift.
  - **Fix.** Sub-condition (d) is now PR-filtered (glob → retain `.pr == <N>` → most-recent run-id) and presence + shape only (run-id regex / JSON parse / 40-hex `"sha"` field). The strict `"sha" == headRefOid` equality check is RETIRED post-#78 — tamper detection is fully delegated to (c). `data.reason="trust_trail_json_sha_mismatch"` is preserved in `GATE_FAIL_REASON_ENUM` (deprecation pattern; mirrors `trust_trail_json_missing` post-#52) but its scope is narrowed to shape failures only. The `/review-pr` recipe now explicitly captures `ANCHOR_SHA="$(git rev-parse HEAD)"` after `git push origin HEAD` and uses `${ANCHOR_SHA}` in the JSON `"sha"` field — the `<full-40-char-head-sha>` placeholder is removed.

### Tests
- **`tests/merge.test.sh` M63** narrowed and extended for #78. `M63.mismatch-gatefail` rephrased to "shape-malformed gate_fail (narrowed scope post-#78)". New assertions: `M63.pr-filter` (Phase 1.4 PATH_2 (d) prose explicitly requires filtering by top-level `.pr` field), `M63.strict-equality-retired` (prose explicitly retires `"sha" == headRefOid` equality), `M63.shape-malformed-narrow` (reason emission narrowed to shape failures), `M63.most-recent-tiebreak` (deterministic tie-break to lex-greatest run-id), `M63.inequality-phrasing-absent` (negative regression guard — the retired strict-inequality phrasing `"sha" != headRefOid` / `"sha" ≠ headRefOid` must not return to (d) prose). The `M37.gfr8` row-membership assertion is preserved (deprecation pattern keeps the enum row) and now carries the same `M63.{strict-equality-retired,shape-malformed-narrow,inequality-phrasing-absent}` cross-reference in its description.
- **`tests/review-pr.test.sh` R9.8–R9.11** (new). `R9.8` asserts `ANCHOR_SHA="$(git rev-parse HEAD)"` is captured after the push; `R9.9` asserts the JSON `"sha"` field literal `${ANCHOR_SHA}` substitution; `R9.10` is a regression guard that the ambiguous `<full-40-char-head-sha>` placeholder is gone; `R9.11` asserts the disambiguation prose between `ANCHOR_SHA` and `PARENT_SHA`.

## [0.21.1] - 2026-05-07

### Fixed
- **`solve-pipeline/SKILL.md:134` zsh-NOMATCH transcription trap.** The "Permission mode" echo packed `$([[ "$AUTO_PERMISSIONS" == "1" ]] && echo 'auto (Claude Code AI classifier)' || echo 'default (manual per-tool gating)')` inside an outer `"…"`. The line is valid bash/zsh in isolation, but every time an agent re-emits the SKILL block into a generated `/tmp/solve-*.sh` launcher (heredoc → sed pipeline), any slip in the nested `"`/`'`/`(…)` layers leaves the literal `(manual per-tool gating)` outside a quote. Under zsh's default `NOMATCH` that becomes an unmatched glob → `zsh:<line>: no matches found: (…)` → fatal under `set -e`, and the whole solve-pipeline run aborts before the validation loop. Reproduced by user against `TheFJK/WAGYPROD#35` (`zsh:32: no matches found: (manual gating)"`).
  - **Fix.** Hoisted the conditional out of the echo into a flat `PERM_DESC` variable populated by an `if/else`. Behaviour identical (same two strings, same `$AUTO_PERMISSIONS` semantics), but no nested substitution-with-parens-in-singlequotes pattern for the agent to mis-quote on re-emit. Comment block in the SKILL records the failure mode so future edits don't re-introduce the one-liner.
  - **Why patch only.** No new flags, no behavioural change, no test-shape change — single-block edit in the bash recipe inside one SKILL. Per the project's bump-everywhere rule, still a patch-version bump (0.21.0 → 0.21.1) so marketplace clients pull the fix.

### Tests
- **`tests/audit-fixups.test.sh`: regression guard for the `Permission mode` one-liner.** Asserts the SKILL no longer contains `Permission mode: $([[`; the assertion never matches the new flat-var form, only matches the resurrected substitution-with-parens form. Pattern observed twice in the field at line 134, so a permanent shape guard is the standard playbook (cf. the line-385 `[1m]` glob and line-410 `timeout` word-splitting guards).

## [0.21.0] - 2026-05-06

### Added
- **`/review-pr` Phase 3 — CI Health (#76).** New phase between Phase 2 and trust-signal emission that probes live CI, monitors pending runs, classifies red runs into one of six failure classes, dispatches per-class fix agents, and halts via `AskUserQuestion` for the two human-only classes. Closes the gap where today a green `/review-pr` run can co-exist with a red CI run, leading `/merge` to park the PR by surprise.
  - **Phase 3 prose** added inline in `commands/review-pr.md` as Step 6c (probe → monitor → classify → route → post-fix → halt → loop guard).
  - **3 new agents.** `agents/ci-failure-classifier.md` (regex-driven 6-class classifier; never quotes log lines verbatim — secret-leak guard), `agents/ci-code-fixer.md` (root-cause fixer for `code_bug` / `env_drift`; refuses on forbidden patterns including `--no-verify`, test-skip, error-swallow, secret-mask, new-file-creation, multi-lockfile-churn), `agents/ci-rebase-handler.md` (rebase-on-base for `stale_base`; uses `--force-with-lease=<branch>:<expected-old-sha> --force-if-includes` with worktree-scoped lock — the single sanctioned exception to `merge/SKILL.md`'s never-`--force-with-lease`-against-PR-head invariant).
  - **`--no-ci-fix` flag.** Probe-only mode: PROBE + MONITOR + CLASSIFY run for audit telemetry; ROUTE / POST-FIX / HALT are skipped. Mirrors `--no-simplify` shape.
  - **12 new `AUDIT_EVENT_ENUM` members** declared in `plugins/uberdev/skills/merge/SKILL.md` Constants table: `ci_probe_started`, `ci_probe_skipped_no_checks`, `ci_probe_unreachable`, `ci_monitor_green`, `ci_monitor_red`, `ci_monitor_timeout`, `ci_classify_dispatched`, `ci_classify_returned`, `ci_fix_dispatched`, `ci_fix_pushed`, `ci_loop_cap_reached`, `ci_phase_outcome`.
  - **3 new ENUMs** declared in `merge/SKILL.md` Constants: `CI_STATUS_ENUM` (`pending`, `green`, `red`, `unreachable`); `CI_FAILURE_CLASS_ENUM` (`code_bug`, `billing_quota`, `platform_outage`, `flaky`, `env_drift`, `stale_base`); `CI_OUTCOME_ENUM` (`green`, `green_after_fix`, `skipped_no_checks`, `halted`, `loop_cap_exhausted`). Plus prose constants `CI_FIX_LOOP_CAP=3` and `RERUN_FLAKY_CAP=1`.

### Changed
- **BREAKING** (predicate-level): `/uberdev:review-pr` GREEN now requires Phase 3 outcome ∈ `{green, green_after_fix, skipped_no_checks}` in addition to Phase 1 + Phase 2 conditions. Existing trust-signal artifacts (anchor commit, label, audit JSON) keep their format. The audit JSON gains a `phases.phase3` block. Callers parsing exit codes are unaffected: 0 / 1 / 2 semantics preserved (Phase 3 halts reuse exit 1).
- **`--turbo` scope narrowed.** R7 prose tightened from "does NOT alter Phase 1, Phase 2, or trust-signal emission" to "does NOT alter Phase 1 or Phase 2." Phase 3 halt classes (`billing_quota`, `platform_outage`) suppress the `AskUserQuestion` prompt under `--turbo` and exit 1 without emitting a trust signal — the queue would block silently otherwise. Phases 1 and 2 remain unaffected.
- **`merge/SKILL.md` cross-references `ci-rebase-handler`** as the single sanctioned exception to its "never `--force-with-lease` against PR head" invariant. The exception is bounded by a worktree-scoped lock, an explicit-old-SHA lease form, and `--force-if-includes`.

### Tests
- **`tests/review-pr.test.sh` extended (R14–R20).** New shape assertions: Phase 3 inline block exists; GREEN predicate updated to 3-conjunct; `--no-ci-fix` documented; exit-code contract reuses 1 for Phase 3 halts; `--turbo` prose narrowed; 12 new `AUDIT_EVENT_ENUM` members in `merge/SKILL.md`; new `CI_*_ENUM` rows present.
- **`tests/review-pr-phase3-ci.test.sh` (NEW, 9 scenarios + 3 agent-shape blocks)** — green-skip fast path, pending → green, pending → red → fix → green, 6 classification paths, loop-cap exhaustion, `--no-ci-fix` probe-only, `--turbo` halt classes, `gh` outage carve-out, audit-trail 12-event coverage; plus structural shape tests for each of the 3 new agent files (frontmatter, return-contract YAML fence, refusal triggers, no-quote-rule for the classifier).
- **`tests/_fixtures/fake-gh/gh` extended** with 7 new modes: `ci-checks-no-checks`, `ci-checks-pending`, `ci-checks-green`, `ci-checks-red`, `ci-checks-mixed`, `gh-unreachable`, `ci-rate-limit-low`.

## [0.20.3] - 2026-05-06

### Fixed
- **`/simplify` dispatcher-drift hardening (G1–G7).** Audit comparing UberDev's `/simplify` to upstream `claude-plugins-official` `code-simplifier` surfaced seven dispatcher-drift risks where invariants lived only in the command file, leaving the agent file weaker than its dispatch context implied. A standalone `Task(subagent_type: uberdev:code-simplifier)` without the command's preamble would fall back to a generic 91-line system prompt with softer iron-rule language and no per-lens checklists. This release makes the agent file the single source of truth for the lens checklists and the strict iron rule, and tightens the command file's Phase 1 fallback, RUN_ID minting, worktree-path anchoring, dedup policy, and per-lens output schema.
  - **G1 — Lens checklists deduped to agent.** `agents/code-simplifier.md` now has a top-level `## Lens checklists` section with `Lens: Reuse`, `Lens: Quality`, `Lens: Efficiency` subsections (the same 3+8+7-item checklists previously only in `commands/simplify.md`). The command file's three lens sections now point at the agent file by name + section anchor instead of restating the prose. Single source of truth: agent file.
  - **G2 — Strict iron rule mirrored into agent.** `agents/code-simplifier.md` Rule 1 ("Preserve Functionality") now carries the strict invariants from the command file ("Do not change function signatures, return types, thrown exception types, or public API surface"), labeled "iron rule", with the explicit fail-safe "If a simplification cannot be made without behavior risk, surface it as an advisory finding — do not propose it as an apply candidate."
  - **G3 — RUN_ID minting recipe inlined.** `commands/simplify.md` Phase 3 now inlines the canonical RUN_ID recipe `RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"` matching `/uberdev:review-pr` (verified at `commands/review-pr.md:68` and `:255`), with a regex-validation guard that exits non-zero if the format ever drifts.
  - **G4 — Aggregate path anchored to worktree root.** Phase 3 now derives `WORKTREE_ROOT="$(git rev-parse --show-toplevel)"` and writes `simplify-final.md` to `$WORKTREE_ROOT/.uberdev/research/$RUN_ID/`, defending against the artifact path-leak class noted in memory `project_uberdev_artifact_path_leak.md` (research artifacts leaking to parent project root when invoked from a worktree).
  - **G5 — Dedup policy specified.** Phase 3 now documents how to merge overlapping findings: dedup by `file:line` key; if 2+ lenses flag the same location, merge into one finding with `lens: Reuse+Quality` (etc.), summary/detail concatenated with ` | ` separators and lens-name prefixes, severity = max across merged. Eliminates implicit-behavior risk in the fixer's parse path.
  - **G6 — Per-lens output schema pinned.** New `## Return contract` section in `agents/code-simplifier.md` defines the structured shape every lens emits (`location`, `severity`, `lens`, `summary`, `detail`) — exactly what `code-fixer.md` Step 2 parses. The `lens` field is now mandatory so the aggregator can dedup deterministically.
  - **G7 — Phase 1 fallback tightened.** Removed the brittle "review the most recently modified files that the user mentioned or that you edited earlier in this conversation" prose, which relied on session-history introspection and produced non-deterministic drift. Now: if both git diff is empty AND `$ARGUMENTS` is empty, refuse with the literal message `/simplify needs either a non-empty git diff or an explicit scope hint via $ARGUMENTS`.
- **Post-review hardening (R1–R5).** `uberdev:code-reviewer` flagged five follow-up issues against the G1–G7 patch; all five fixed in the same release:
  - **R1 — Severity-enum parity.** Initial draft used `critical | important | suggestion` for the new agent return contract; canonical pipeline uses `blocker | suggestion` (`agents/pr-test-analyzer.md:57`, `skills/post-impl-review/SKILL.md:128`). `code-fixer.md` Step 2 parses the `post-impl-review-aggregate` envelope and would have silently coerced/dropped the non-canonical values. Agent return contract now emits `severity: blocker | suggestion` matching every other producer; cross-references the canonical sources inline.
  - **R2 — `code-fixer.md` Step 2 parser acknowledges optional `lens?` field.** Previously the extraction list was `{severity, location, summary, detail}` with no awareness of the `lens` field that simplify aggregates carry; the parser would have silently dropped it. Step 2 now extracts `{severity, location, summary, detail, lens?}` and passes the lens through into the commit-row label as `- [preserve] (Reuse) file.ts:42 — short summary` when present.
  - **R3 — Cross-file lens-name parity asserted.** `commands/simplify.md` references the agent's lens sections by name (`Lens: Reuse`, etc.). Initial test suite locked the names in the agent file but not in the command file, so a rename in one place would have left a dangling pointer. Six paired assertions added (one per lens, in each file) so renaming requires a coordinated edit.
  - **R4 — Iron-rule consolidation.** Strict invariants ("function signatures, return types, thrown exception types, public API surface") previously appeared in BOTH the command preamble and the agent's Rule 1. Command preamble now cross-references the agent ("strict invariants defined once in `plugins/uberdev/agents/code-simplifier.md` Rule 1") so there is exactly one place to edit.
  - **R5 — Machine-parseable refusal.** G7's empty-diff/empty-args refusal previously emitted only a literal English string. Phase 1 now also fences a YAML block (`status: REFUSED, rationale: "empty-diff-and-empty-arguments"`) so callers (`/turbo`, future automation) can detect refusals programmatically — matches `code-fixer.md`'s refusal envelope shape.
- **37 new structural assertions in `tests/simplify.test.sh`** lock G1–G7 + R1–R5 invariants (57 PASS / 0 FAIL total, up from 20). Two RED-GREEN cycles: G1–G7 RED (24 fails) → GREEN (44 pass) → R1–R5 RED (6 fails) → GREEN (57 pass). Adjacent suites untouched: `tests/code-fixer-dispatch.test.sh` (44/44), `tests/review-pr.test.sh` (76/76), `tests/post-impl-review.test.sh` (31/31).

## [0.20.2] - 2026-05-06

### Changed
- **`code-fixer` and `code-reviewer` agents now use `model: inherit`.** Previously hard-pinned to `sonnet` (code-fixer) and `opus` (code-reviewer). Inherit makes both agents track whatever model the user runs in their main Claude Code session — so when the user is on Opus 4.7 1M, every code-fixer commit and code-reviewer pass is also Opus 4.7 1M, with no per-agent model drift. Quality matters most for these two agents (they touch the diff before merge), and pinning a specific model name would gradually float behind whatever Anthropic ships next. `tests/code-fixer-dispatch.test.sh` asserts the new `^model: inherit$` contract.

### Fixed
- **`solve-pipeline/SKILL.md` Step 3 cmux detection now `set -u`-safe.** Wrapped the legacy fallback in `${CMUX_SOCKET:-}` so the fallback chain `${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}` no longer errors on unbound `CMUX_SOCKET`. Current launcher uses `set -e` only so 0.20.1 was already correct in production, but the defensive form future-proofs against any future flip to `set -u` and matches uberdev's "no implicit unbound-var reads" convention. `tests/cmux-detection.test.sh` regex relaxed to accept both `${CMUX_SOCKET_PATH:-$CMUX_SOCKET}` and `${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}` forms.
- **`tests/merge-discovery-resilience.test.sh` A11 version assertion no longer hard-codes a release version.** Previously pinned to `0.19.3` (PR #75 era); the 0.20.0 release commit (`e42d20c`) forgot to update the test, leaving 3 stale-pin failures in main between 0.20.0 and 0.20.2. The fix reads the canonical version from `plugin.json` at test runtime and asserts `marketplace.json` + `README.md` badge match — so future bumps don't keep breaking this test, and a real cross-file drift (which is what A11 was meant to catch) still fires loudly.

## [0.20.1] - 2026-05-06

### Fixed
- **`/solve` and `/turbo` cmux detection no longer falls through to standalone Ghostty when invoked from inside cmux.** `solve-pipeline/SKILL.md` Step 3 read `$CMUX_SOCKET`, but current cmux releases export the socket path as `$CMUX_SOCKET_PATH` and explicitly set `CMUX_SOCKET=` to empty string inside live sessions. The bare `[[ -n "$CMUX_SOCKET" ]]` check therefore failed inside cmux, the elif fell through to the ghostty arm (since `TERM_PROGRAM=ghostty` is set when cmux bundles Ghostty), and AppleScript activated *standalone* `/Applications/Ghostty.app` when present — keystrokes `zsh -l /tmp/solve-N.sh` then landed in whatever window held focus (browser address bar, etc.) instead of a fresh shell, and the agent never started. Detection and the explicit-override validation arm now read `${CMUX_SOCKET_PATH:-$CMUX_SOCKET}` so current-cmux installs are detected first and legacy installs still work. New `tests/cmux-detection.test.sh` (5/5 passing) locks in both env-var checks and guards against regressions to a bare `$CMUX_SOCKET`-only test. Workaround for unpatched 0.20.0 installs: `--terminal=cmux` or `export SOLVE_TERMINAL=cmux`.

## [0.20.0] - 2026-05-05

### Added
- **`/review-pr` Phase 2 simplify-lens dispatch + new `code-fixer` agent (#73 → #74).** `/review-pr` now plumbs `aspect_emphasis` to per-reviewer dispatches, honors `sequential` mode, and dispatches `code-fixer` in Phase 3 to apply advisory simplifier findings. `/simplify` Phase 2 names the `code-simplifier` dispatcher and Phase 3 dispatches `code-fixer` (audit-and-apply).
- **`code-fixer` agent.** New `agents/code-fixer.md` audit-and-apply agent that consumes simplifier-style YAML findings and produces patches; standalone `pr_number` is documented; defensive R8.6 guard added.
- **Post-impl-review fanout 5 → 6.** `post-impl-review/SKILL.md` now dispatches 6 reviewers (swap `code-simplifier` for `pr-test-analyzer` in the Phase 1 fanout). `pr-test-analyzer` migrated to standard YAML output. Config override default tracks the cap change.
- **New tests.** `tests/code-fixer-dispatch.test.sh` (locks code-fixer agent contract); `tests/simplify.test.sh` (locks `/simplify` Phase 2 + Phase 3 contract); structural assertions for 5→6 reviewer fanout in `tests/post-impl-review.test.sh`; `tests/_lib_assert_structural.sh` shared helpers; retrofitted dispatch-site assertions in `tests/review-pr.test.sh`.

### Fixed
- Stale references to "5 reviewers" in `/review-pr` and related skills propagated to "6 reviewers" so docs and audit-event text match the new fanout cap.
- Documentation: `code-simplifier` description updated to clarify Phase 2 lens role.

## [0.19.3] - 2026-05-05

### Fixed
- **R1 (in-process filter):** All three `gh … --json` discovery sites in `/merge` (Steps 1.0.5, 1.2.5, 1.4) now use `gh … --jq '<filter>'` so jq runs inside the gh process on the parsed Go object before serializing stdout. No external pipe = no FD-pollution surface for the spinner-leak bug class fixed for `/solve` in `21ad417`.
- **R2 (lib extraction):** Discovery logic factored into `plugins/uberdev/skills/merge/lib/discover.sh` (`discover_bare_fast_path` / `discover_multi` / `pr_view_projection` + `emit_gate_fail` helper). SKILL.md Steps 1.0.5 / 1.2.5 / 1.4 now source the lib via `${CLAUDE_PLUGIN_ROOT}/skills/merge/lib/discover.sh` (mirroring the existing `lib/config-read.sh` precedent — `BASH_SOURCE`/`$0` does not resolve in Claude's skill-eval context) and call the functions instead of inlining bash blocks. Eliminates the model-improv surface that re-introduced `2>&1` despite the pattern being absent from the spec text.
- New audit event `discovery_gh_failed` (members: `reason`, `step`, `exit_code`, `gh_stderr`, `pr_number?`) and new gate_fail reason `pr_view_unreachable` (Step 1.4 infrastructure failure). `gh_stderr` is raw-truncated to ≤512 bytes pre-JSON-escaping (escaped form may expand to ≤2048 bytes for adversarial backslash-heavy stderr).
- **JSON-injection defense in audit emit.** Numeric inputs (`exit_code`, `pr_number`) are sanitised to integers before bare-numeric `printf` substitution — non-numeric inputs are normalised (`exit_code` → `-1`, `pr_number` → `0` or omitted) so a caller bug or future field-source change cannot produce malformed JSON or inject extra fields into the audit log.
- New test suite `tests/merge-discovery-resilience.test.sh` (67 assertions; 14/14 test files pass) with a fake-gh fixture that simulates the spinner-leak shape (ANSI on stderr while gh succeeds on stdout). Locks: no `gh … 2>&1`, no `gh … | jq`, lib uses `--jq '<filter>'` at ≥3 sites, SKILL.md sources via `${CLAUDE_PLUGIN_ROOT}` (not `BASH_SOURCE`), audit-log path configurable via `UBERDEV_AUDIT_LOG_PATH`. Pre-processes file contents (folds backslash-continuations, strips comments) so multi-line bug-shape regressions cannot hide. Includes a canary on `solve-pipeline/SKILL.md` Step 4 detecting any revert of `21ad417`.

## [0.19.2] - 2026-05-05

### Fixed
- **`/finish-branch` skill load no longer aborts with `(eval): parse error near `)'` on the gh-pr-create comment block.** A `` `if !` `` backtick-quoted incomplete-shell-keyword inside a `#`-prefixed comment in `finish-branch/SKILL.md` (line 280) was eval'd as command substitution by the same Claude Code permission-pattern evaluator that bit #42 (heredoc delimiters) and #55 (apostrophes) — the body `if !` is unterminated bash, surfacing as a parse error and aborting the skill before the option menu / `gh pr create` path could run. Rephrased the comment to non-backticked prose ("the negated-conditional branch below") — pure prose change, zero behavioural delta. Regression canary added to `tests/finish-branch-auto-chain.test.sh` matching bash reserved words (if/then/else/elif/fi/while/for/until/do/done/case/esac/function/select/time) at the start of a backtick body inside `#`-comments; suite 36→37 passing.

## [0.19.1] - 2026-05-05

### Fixed
- **`/solve` and `/turbo` Phase A validation no longer crashes with `jq: parse error: Invalid string: control characters from U+0000 through U+001F must be escaped` (exit 5).** `solve-pipeline/SKILL.md` Step 4 captured `gh issue view --json` with `2>&1`, merging gh's stderr into `$ISSUE_JSON`. On slow API responses gh's spinner (default `spinner=enabled` in `gh config`) renders ANSI escape frames containing raw `ESC` (0x1B) — a U+0000-U+001F control character that's illegal inside a JSON string per RFC 8259 §7. The mixed bytes broke `jq -r .state <<<"$ISSUE_JSON"` mid-validation, after Step 3 had already echoed `Dispatching via: <terminal>`. Fix: capture stderr to `mktemp` and only read it on the failure path; stdout stays pure JSON. Same fail-open shape as `merge/SKILL.md` Step 1.0.5.

## [0.19.0] - 2026-05-05

### Added
- **`.claude/uberdev.local.md` knob expansion (#63, #72).** New per-project tunables: `solve_tier_floor` / `solve_tier_ceiling` clamp `/solve` and `/turbo` tier classification (`small`/`medium`/`large`); `fanout_concurrency.research` / `.post_impl_review` / `.merge_strategy` / `.conflict_resolver` cap parallel agent dispatch (bounds [1,50], defaults 5/5/10/10); `command_timeouts.solve` (enforced) / `.review_pr` (advisory) / `.merge` (advisory) bound wall-clock budgets (bounds [60,86400] seconds, defaults 14400/900/600). Each key has a corresponding env-var override (`SOLVE_TIER_FLOOR`, `SOLVE_TIER_CEILING`, `UBERDEV_FANOUT_RESEARCH`, etc.). New `plugins/uberdev/lib/config-read.sh` helper (bash-`=~` regex validation; surfaces audit-write failures rather than swallowing them) is the single read site; `solve-pipeline`, `orchestrator`, `post-impl-review`, `merge`, `using-uberdev` skills wire it through. Wave-chunking math documented as `ceil(N / CAP)` per skill.

### Fixed
- **`/finish-branch` apostrophe in `#`-comments unblocks skill load (#55, #70).** Apostrophes inside `#`-prefixed permission-evaluator preamble comments tripped the YAML/Markdown skill loader and silently dropped the skill. Phrasing rewritten to remove the contraction; regression canary `tests/finish-branch-auto-chain.test.sh` added.
- **`/solve-pipeline` `timeout(1)` invocation no longer crashes under zsh word-splitting (#63, #72).** Inlined the `timeout` call to side-step the zsh word-split footgun that surfaced when `command_timeouts.solve` was non-empty.
- **`/solve` `CLAUDE_PLUGIN_ROOT` path correction + `sed` substitution fix (#63, #72).** Launcher template substitution now resolves correctly under the marketplace install path.

### Documentation
- **README — explicit "we rejected upstream's HARD-GATE" stance now documented (#61, #69).** Adds a row to the `## Design decisions worth knowing` table plus a `<details>` block answering "why doesn't UberDev pause for approval?" and naming the three trust anchors (`spec-reviewer` always-on, `plan-reviewer` always-on, `post-impl-review` end-of-issue fanout) that replace user-approval gates.
- **Orchestrator Phase 1 artifact-reuse contract formalised + shape-check test added (#62, #71).** `orchestrator/SKILL.md` documents how cached `.uberdev/research/<run-id>/*.md` artifacts are reused across re-runs, and `spec-writer` / `plan-writer` wrap reused artifacts in `<external-untrusted-input>` envelopes (defense-in-depth against second-order injection). New `tests/orchestrator-phase1-shortcircuit.test.sh` registered in the `shape-checks` CI chain.

## [0.18.2] - 2026-05-04

### Changed
- **Post-impl review now runs after PR push, not before (#67, #68).** The 5-reviewer post-impl-review fanout (code-reviewer, simplifier, silent-failure-hunter, type-design-analyzer, comment-analyzer) has moved from the pre-push call sites in `solve-pipeline` (trivial AUTO_MODE=0 step 6 and small AUTO_MODE=0 step 5) and `subagent-driven-dev` (end-of-issue step 5) to a single canonical post-PR-push location: **`/uberdev:review-pr` Phase 1**. `/review-pr` now invokes `Skill(uberdev:post-impl-review)` directly; the skill remains the single source of truth for the parallel single-message dispatch and is no longer enumerated inline in `/review-pr`. Canonical findings artifact path is now `.uberdev/research/<RUN_ID>/post-impl-review-final.md` (no `wave-` infix; `RUN_ID` is minted by `/review-pr` per its own regex, decoupled from any earlier subagent-driven-dev `RUN_ID`). Phase 1 apply-loop reads the artifact and **MUST** wrap content in `<external-untrusted-input source="post-impl-review-aggregate">` before interpolating into any fixer prompt — defense-in-depth against second-order injection (issue-author text → diff hunk → reviewer report → aggregate → fixer). Phase 1 vs Phase 2 separate-commit invariant preserved (review-fix commits stay distinct from the simplify commit).
- **`finish-branch` PR-body glob widened to `post-impl-review-*.md`** — matches both the new canonical `post-impl-review-final.md` artifact AND any legacy `post-impl-review-wave-final.md` artifacts left over from pre-refactor runs (zero-migration). The legacy `.uberdev/research/issue-*/post-impl-review.md` glob is retained for in-flight artifacts from trivial/small inline pre-push runs. Interactive-mode Options 1/3/4 (local merge / keep / discard) carry a new caveat blockquote documenting that they bypass `/uberdev:review-pr` Phase 1 and therefore the post-impl-review fanout — only Option 2 (the default and `--turbo` auto-select) preserves the chain. Quick Reference table extended with a "Post-impl review" column.
- **Top-level `CLAUDE.md` is now `.gitignore`'d** — local-only personal Claude instructions, not part of the published plugin. `.gitignore` was already covering `.claude/` but missed the top-level file.

### Fixed
- **`/review-pr` end-of-run trust trail now anchors HEAD via empty anchor commit, not via per-simplify-commit trailer.** The pre-fix Phase 2 emit pattern wrote `Reviewed-by: uberdev/review-pr@<sha>` into the simplify commit's body itself, capturing `<sha>` from `git rev-parse HEAD` *before* the simplify commit landed — which left the trailer pointing at the **parent** (Phase 1's last commit) instead of the simplify commit's own SHA. When `/merge`'s `trust-trail-evaluator` ran `git merge-base --is-ancestor <trailer-sha> <head>` it got YES (parent → child) and `git diff --shortstat <trailer-sha> <head>` got non-empty (the real simplify changes), correctly returning `STALE` and skipping the PR with `gate_fail` reason `trust_trail_stale_sha`. Reproduced live on PR #68 (the very PR that introduced the post-push relocation): `Reviewed-by: uberdev/review-pr@2aa77b8…` on simplify commit `3f04244` with parent `2aa77b8` and a +5/−13 diff between them. Post-fix, `/review-pr` Trust-Signal Emission step appends ONE empty commit at HEAD (`git commit --allow-empty`) whose body carries `Reviewed-by: uberdev/review-pr@<PARENT_SHA>` where `<PARENT_SHA>` is captured *before* the anchor. The anchor's diff is empty by construction, so `trust-trail-evaluator` PASSes via the empty-cumulative-diff path: ancestor=YES + tree-diff=EMPTY → `PASS`. Independent of how many Phase 1 / Phase 2 commits landed, and independent of whether they pushed mid-run or batched. `git commit --amend` is **NEVER** used in trust-signal emission, so push **never** requires `--force-with-lease`. Phase 2's simplify commit body itself no longer carries the trailer. Sibling-equivalence support in `trust-trail-evaluator` is preserved for **user-side** amends made between `/review-pr` and `/merge` (the agent's M61 sibling case). `merge/SKILL.md` line 280 prose updated to reflect that `/review-pr`'s own pattern is now the empty-anchor path; sibling-equivalence is documented as covering user amends only. `tests/review-pr.test.sh` adds the R9 block (7 assertions: anchor-commit pattern named, `git commit --allow-empty` literal, `--amend` is NEVER used regression guard, `PARENT_SHA` capture, `chore(review-pr): trust trail anchor` subject literal, simplify commit body has NO trailer regression guard, anchor-commit failure path in artifact-emission failure prose). `tests/merge.test.sh` M61 motivating-case comment updated to reflect that user-side amends — not `/review-pr`'s own pattern — are the live motivating case post-v0.18.1.
- **Conflict-resolver REFUSED/AMBIGUOUS justification now surfaces in `/merge` run-summary (#64).** When the conflict-resolver agent returns `refused` or `ambiguous` for one or more files in Phase 3, the run-summary now renders a `conflict files:` sub-block (rendered only when `outcome=Parked` AND park reason is in `{refused, ambiguous}`) with per-file lowercase bracketed verdict (`[refused]` / `[ambiguous]`), `fmt -w 80`-wrapped justification, and `risks[]`. Render-time sanitisation strips C0/C1 + DEL bytes via `LC_ALL=C tr -d`; the audit log keeps raw `data.rationale` bytes — sanitisation is render-only. Previously a Parked outcome from `refused`/`ambiguous` exited without telling the user *why* per file, forcing a separate audit-log read. PASS / RESOLVED / test-fail-exhausted / push-non-ff render paths unchanged.
- **`/review-pr` Phase 1 sequential-fallback warnings now go to stderr, not `/dev/null`** (#68 Phase 1 review-fix from silent-failure-hunter). Prose explicitly forbids silent suppression or routing to an internal log file — the user must see the override warning on the same surface they invoked the command from.
- **`tests/post-impl-review.test.sh` heredoc anchor extraction now guards against silent setup-failure** (#68 Phase 1 review-fix). Previously, if the awk anchor patterns disappeared from `solve-pipeline`, `grep -qE` on empty output returned 1 — causing the assertions to PASS when they should report a setup error and hiding any heredoc reshape that broke the test's preconditions. Adds anchor-presence and body-non-empty pre-checks that emit explicit `setup error:` FAIL lines pointing at the awk extraction site.
- **`tests/merge.test.sh` 247 → 258 assertions** (M64 block: 11 new BATS-style assertions covering field/tag/conditional/sanitize-impl shape-checks for the conflict-files sub-block, scoped to a `CONFLICT_BLOCK` slice extracted via `awk '/^[[:space:]]*conflict files:/,/^\`\`\`$/'` so future template edits surface as failures rather than silently passing against incidental occurrences in surrounding prose).

### Added
- **Superpowers vendor audit + SHA-pinned provenance headers (#57, #66).** All 20 vendored superpowers files under `plugins/uberdev/skills/{test-driven-development,writing-skills,systematic-debugging}/` now carry SHA-pinned provenance headers tracing back to upstream `obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6`. Sub-files take line-1 placement; shebang scripts (`find-polluter.sh`, `render-graphs.js`) take line-2 placement after the shebang; parent `SKILL.md` files take body-first placement (after the closing `---` of the YAML frontmatter) so the dispatcher still sees `---` on line 1. Three files have intentional local divergence recorded in the suffix: `writing-skills/SKILL.md` and `writing-skills/testing-skills-with-subagents.md` carry the `superpowers:` → `uberdev:` namespace rebrand; `systematic-debugging/SKILL.md` carries the rebrand plus a local "Parallel hypothesis testing" section enhancement. The other 17 files are byte-equivalent to upstream.
- **`docs/uberdev/audits/` subdirectory** — new public-by-default doc subdirectory (parallel to `docs/rfc/`) for committed audit records. First record: the 2026-05-04 superpowers vendor audit (inventory, byte-equivalence diff results vs. upstream HEAD, attribution stack, AC mapping for #57, hardened manual re-diff procedure with `set -euo pipefail`, validated `FRESH_SHA` from `git ls-remote` (40-char check), `--fail` and `--max-time 30` on `curl`, single `mktemp` scratch file with trap-cleanup, and case-dispatched `diff` exit code (0 → MATCH, 1 → DIFFER, * → DIFF_ERROR with diff exit N to stderr) so I/O failures no longer collapse into the DIFFER branch).

## [0.18.0] - 2026-05-04

### Added
- **Bare `/merge` auto-discovers eligible PRs (#56, #65).** Invoking `/merge` with no positional argument and no `--all` flag now infers scope from ambient context: single-PR fast path when the current branch has exactly one open PR; multi-PR auto-discovery against `integration_branch` (same code path as `--all`) otherwise. Hard-errors with a clear diagnostic when the current branch has more than one open PR (ambiguity); clean exit 0 when the discovered set is empty (no eligible PRs is not a failure — preserves the Step 1.7 single-PR-pre-flight-fail-edge-case precedent). Multi-discover mode emits a `PREFLIGHT_SUMMARY_FORMAT` line to stderr listing the discovered set before Phase 2 — visibility, not a `[y/N]` prompt; the queue still proceeds unattended. Single-PR fast path preserves today's UX (no pre-flight noise).
- **Three new SKILL.md constants:** `BARE_MODE_FAST_PATH_QUERY` (current-branch fast-path query — `gh pr list --head <current_branch> --state open`), `DISCOVERY_FILTER` (canonical multi-discover filter, sole shared dispatch point for both bare-multi-discover and `--all`), `PREFLIGHT_SUMMARY_FORMAT` (the stderr summary line emitted in multi-discover mode only, 80-char wrap convention).
- **Two new SKILL.md steps:** Step 1.0.5 (mode-detect, runs pre-lock — does NOT consume `$integration_branch`, that resolution happens at Step 1.2; three-way branch on candidate cardinality 0 / 1 / N>1 with stderr breadcrumbs and no new audit-event enum member by design) and Step 1.2.5 (multi-discover dispatch, runs after Step 1.2 against the resolved `$integration_branch`; both bare-multi-discover and `--all` route through this single dispatch point per Q4).
- **Step 2.2 pre-flight summary subsection** — emits the `PREFLIGHT_SUMMARY_FORMAT` line in multi-discover mode only (Q2 + Q5). Full ordered set, 80-char wrap; not a `[y/N]` prompt; single-PR mode preserves today's UX with no pre-flight noise.

### Changed
- **`commands/merge.md` argument-hint frontmatter and Usage signature drop `[--yes|-y (deprecated)]` from the visible hint surface.** Surfacing deprecated flags in the active-surface hint contradicts the deprecation lifecycle and gives users a misleading "supported" signal. The flag is still parsed at runtime and the deprecation notice still emits — that documentation stays in the `## Deprecated Flags` section. Usage bullet 1 rewritten from "land the PR for the current branch (errors if none)" to "context-aware: single PR if on a PR branch, else discover and land all eligible open PRs against integration_branch."
- **`tests/merge.test.sh` 197 → 247 assertions** (M64–M73 block: 33 sub-assertions across 10 blocks covering the new constants, Step 1.0.5 / Step 1.2.5 dispatch sites, Step 2.2 pre-flight summary, Step 1.7 zero-eligible cross-reference, `commands/merge.md` argument-hint deprecation drop, and Phase 1.4 / Step 2.2 single-message Task() invariant preservation). M20.1 and M20.2 retired in lockstep — they asserted the now-flipped `--yes|-y`-in-hint contract; replaced with negative regression guards mirroring the new M72 contract. M20.3–M20.6 (Deprecated Flags section + "no behavioural effect" prose + flag-deprecation annotation + autopilot mention) preserved.

### Refactored
- **`/uberdev:review-pr` Phase 1 advisory fix-ups** — drop M72.length-cap (verbatim duplicate of M2's `wc -l < commands/merge.md ≤ 50` cap on the same file; flagged by 3 reviewers as redundant); tighten Step 1.0.5 detached-HEAD wording (explicitly skip step 2 entirely when current_branch is empty; forbid empty-`--head` invocation, which is undefined gh-CLI behaviour); add explicit "no audit event by design" rationale to Step 1.0.5's N>1 ambiguity hard-error path (mirrors Phase 2.1 cycle-break stderr-only convention; clarifies that Step 1.0.5 runs pre-lock so there is no audit context yet — no run_id allocated); brief acknowledgment that gh-CLI failure-mode handling is a cross-cutting concern shared with the existing `--all` discovery path (deferred to a follow-up issue).
- **`/uberdev:review-pr` Phase 2 simplify-pass high-conviction tightens** — `tests/merge.test.sh` M67 sub-checks scoped to extracted `PREFLIGHT_FORMAT_ROW` variable (mirrors M65/M66 row-variable pattern; future Step 2.2 prose additions can't accidentally satisfy uniqueness checks); M73 drops redundant `STEP_22_FOR_M73` awk extraction in favour of reusing M70's `STEP_22_BLOCK` (same range, same boundaries; shell variables are session-scoped); SKILL.md Step 1.2.5 closing paragraph tightens split-detection rationale repeat (one-sentence pointer + "do not collapse" guard, replacing 3× restated invariant). Iron rule preserved (Step 2.2 pre-flight prose 3→1 paragraph fold attempted, reverted: M70.no-prompt's negative regex is line-scoped and folding put `pre-flight` and `[y/N]` on the same line, matching the regex and failing the assertion). Final suite: 247 PASS / 0 FAIL.

### Tests
- **Suite: 247 PASS / 0 FAIL** (was 197 → +50 net: M64–M73 added 33; M67/M73 simplification consolidations and M72.length-cap drop net to the final count; M20.1/M20.2 retirement net-zero against M20-style negative regression guards). Frozen contracts upheld: five trust-gate mirror sites (M44/M46), audit JSON contract (#52), single-message Task() fanout invariant, `AUDIT_EVENT_ENUM` closed set (no new event for Step 1.0.5; stderr breadcrumb only), Phase 1.4 per-PR fanout shape.

### Backwards compatibility
- **No breaking changes.** `/merge <PR#>` and `/merge --all` invocation paths unchanged. Bare `/merge` (no positional, no `--all`) previously errored when the current branch had no open PR — now auto-discovers. Single-PR fast path on a PR feature branch is unchanged (preserves today's UX with no pre-flight noise).
- **`AUDIT_EVENT_ENUM` closed set unchanged.** Step 1.0.5 mode-detect emits a stderr breadcrumb but no new audit event — by design; the step runs pre-lock so no run_id is allocated.
- **Five trust-gate mirror sites unchanged** (M44/M46 regression guards remain green).

## [0.17.2] - 2026-05-04

### Fixed
- **`/merge` Step 1.1 lock acquisition no longer mis-classifies missing `flock(1)` on macOS as lock contention.** `flock` is not part of the macOS base system, so the previous unguarded invocation exited 127 (`command not found: flock`), and Step 1.1's error-translation classified every non-zero exit as genuine contention — surfacing `"another /merge run in progress"` on stock-macOS users' very first invocation with no actual contender. `/merge` was effectively unusable on macOS without a separate `brew install flock`. `skills/merge/SKILL.md` Step 1.1 now probes `command -v flock` BEFORE invoking it and branches: flock-available path is unchanged; flock-missing path falls back to a portable `mkdir`-based mutex at `${LOCK_FILE_PATH}.d/` (POSIX-atomic for exclusive creation), with a PID-stamp file powering the existing `kill -0` stale-lock cleanup. Concrete bash code block prescribes the acquisition + cleanup pattern including the explicit `trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM` that Step 4.6 references as the cleanup contract. Failure-mode distinctions are now load-bearing prose: missing-flock → silent fall-through (NOT contention); mkdir EEXIST + holder alive → contention; mkdir EEXIST + holder dead OR PID empty → stale, retry once; mkdir non-EEXIST (ENOSPC, EACCES, EROFS, parent missing) → distinct `"filesystem error"` diagnostic; PID-write failure → release lock dir + distinct `"cannot stamp PID"` diagnostic. The new prose closes both the original mis-classification AND three derivative silent-failure surfaces (FS-error vs contention conflation, unguarded PID-write, hopeful "MUST install trap" without literal syntax) surfaced by Phase 1 review of PR #53. Issue #51.
- **`tests/merge.test.sh` 197 → 203 assertions** (M62 block: 6 sub-assertions covering the `command -v flock` probe, the mkdir fallback, the explicit `MUST NOT.*contention` mis-classification guard, the Step 4.6 cleanup contract, the FS-error-distinct-from-contention requirement, and the literal `trap ... EXIT INT TERM` syntax). Repo-wide 475 → 481 pass / 0 fail.

### Backwards compatibility
- **No API or contract change.** `LOCK_FILE_PATH` constant unchanged; the contention diagnostic message string unchanged; the existing flock-on-Linux path unchanged. The fix is internal to Step 1.1's branch structure and adds a new portable-mutex code path for the missing-`flock` case. Existing flock-equipped systems (Linux, macOS-with-Homebrew-flock) see no behavior change.

## [0.17.1] - 2026-05-04

### Fixed
- **`trust-trail-evaluator` no longer rejects sibling-equivalent commits as `FORCE_PUSHED`.** The agent's Process Step 2 short-circuited to `FORCE_PUSHED` on `git merge-base --is-ancestor` exit 1 (non-ancestor) without ever running the tree-diff check. This blocked legitimate `/review-pr` trust trails produced by `/review-pr`'s own `git commit --amend` trailer rewrite, which generates a sibling commit (same parent, different SHA, identical tree contents) that is non-ancestor in the DAG sense but trust-equivalent. Concrete repro on first encounter: PR #50's HEAD `a410dda` was a sibling of trailer SHA `201a2dbb` via the Phase 2 trailer-amend with byte-identical trees (`git diff --shortstat` empty), yet the agent emitted `FORCE_PUSHED` → `gate_fail` → unscalable `/merge` wall. Fix defers the `FORCE_PUSHED` decision to Step 3: Step 2 now passes an `is_ancestor` flag (true on exit 0, false on exit 1) to Step 3, where the four-quadrant decision matrix combines ancestor relationship with tree-diff result — `empty diff AND is_ancestor=false` → `PASS` (sibling-equivalent rewrite), `non-empty AND is_ancestor=false` → `FORCE_PUSHED` (real history rewriting). The verdict enum stays at four members (`PASS` / `STALE` / `INVALID` / `FORCE_PUSHED`); caller-side mappings unchanged. Step 4 (log-empty) is skipped when `is_ancestor=false` because Step 3's tree-diff check is already authoritative for the non-ancestor branch. `skills/merge/SKILL.md` prose updated in lockstep — both the `Honest fast-forward fixup` paragraph and the `Stale-SHA verification primitive (D3)` paragraph now mention sibling-equivalent commits.
- **`tests/merge.test.sh` 192 → 197 assertions** (M61 block: 5 sub-assertions covering the four-quadrant decision matrix, the `is_ancestor` flag plumbing, the cited `commit --amend` motivating case, and a negative regression guard against the pre-fix `Exit 1 → verdict: FORCE_PUSHED` short-circuit). Repo-wide 470 → 475 pass / 0 fail.

### Backwards compatibility
- **No API or contract change.** The verdict enum, audit-event names, gate_fail reason strings, and caller-side mapping table are all unchanged. The fix is internal to the agent's verdict-derivation logic. PRs that previously emitted `FORCE_PUSHED` for true history rewriting still emit `FORCE_PUSHED`; the fix narrows the verdict to ONLY those cases (non-ancestor AND tree contents differ). PRs that previously emitted `STALE` for ancestor + non-empty diff still emit `STALE`. The change set is purely additive on the PASS path.

## [0.17.0] - 2026-05-04

### Changed (BREAKING)
- **`/merge` Phase 1.4 trust resolution + Phase 2.2 strategy selection are now agent-decided (#47, #49).** The structurally unsatisfiable strict trailer-SHA equality check at PATH_2 sub-condition (c) (`trailer-sha == live headRefOid` is a SHA-1 fixed-point — mathematically impossible to satisfy when the trailer is part of HEAD's own commit content) is replaced with a `trust-trail-evaluator` agent that inspects three structural primitives (`git merge-base --is-ancestor`, `git diff --shortstat`, `git log` between the trailer SHA and live head). The agent returns `TRUST_TRAIL_VERDICT_ENUM = {PASS, STALE, INVALID, FORCE_PUSHED}` with rationale and `signals_inspected`. **Honest fast-forward fixup commits between `/review-pr` and `/merge` whose cumulative tree-diff vs the trailer SHA is empty now evaluate to PASS** — typo touch-ups, comment edits, and `/review-pr`'s own Phase 2 trailer-only amends no longer force a re-run. Force-pushes that rewrite history evaluate to FORCE_PUSHED. PATH_3 (admin bypass via `--bypass-protections`) is **deleted entirely**; the CI-red waiver clause is dropped. Phase 2.2 inline signal-by-signal heuristic is replaced by a parallel `merge-strategy-decider` fanout that picks per-PR strategy in `MERGE_STRATEGY_DECIDER_VERDICT_ENUM = {squash, rebase, merge}` (`drop` is intentionally excluded from the agent's verdict — it remains a Phase 3 outcome only). Fanout chunked at `MAX_PARALLEL_AGENTS` (default 10) with `merge_strategy_fanout_wave_started` audit events per wave. Refusal cases fall back to `squash` with `rationale='agent-refusal-fallback'` so the queue continues.
- **CLI flags `--squash` / `--rebase` / `--merge` and `--bypass-protections` are deprecated.** Parsed without error for backward compat but have **no behavioural effect**. First encounter per run emits the verbatim `STRATEGY_FLAGS_DEPRECATED_NOTE` / `BYPASS_PROTECTIONS_DEPRECATED_NOTE` to stderr and records a `deprecated_flag_used` audit event. The `merge-strategy-decider` agent picks per-PR strategy from PR-shape signals; the CLI flag does NOT override the agent's choice.

### Added
- **Two new agents** under `plugins/uberdev/agents/`:
  - `trust-trail-evaluator.md` — Phase 1.4 PATH_2 sub-condition (c) dispatch site. Mirrors the conflict-resolver template: typed Inputs with `external-untrusted-input` envelopes for PR body / commit messages, restricted Tools authorised list (no Edit / Write / WebFetch), numbered Process, explicit Refusal triggers, fenced YAML return contract.
  - `merge-strategy-decider.md` — Phase 2.2 dispatch site. Five-step weighted enumeration over structural signals (commit count, conventional-commit ratio, divergence from base, WIP markers, advisory `merge-strategy:<name>` PR label, repo_convention). PR label wrapped in `<external-untrusted-input source="github-pr-label">` and treated as DATA, never WebFetched.
- **Nine new constants** in `skills/merge/SKILL.md`: `TRUST_TRAIL_VERDICT_ENUM`, `MERGE_STRATEGY_DECIDER_VERDICT_ENUM`, `STRATEGY_OVERRIDE_FLAGS`, `STRATEGY_FLAGS_DEPRECATED_NOTE`, `BYPASS_PROTECTIONS_DEPRECATED_NOTE`, `GATE_FAIL_REASON_TRUST_TRAIL_AGENT_INVALID_INPUT`, `MAX_PARALLEL_AGENTS` (default 10), `TRUST_TRAIL_VERDICT_INVALID_SUBREASON_ENUM` ({input_malformed, trailer_sha_not_in_local_clone}), `TRUST_TRAIL_AGENT_DECISION_RETRY_ATTEMPT_RANGE` ({0, 1}).
- **Three new audit events**: `trust_trail_agent_decision`, `merge_strategy_agent_decision`, `merge_strategy_fanout_wave_started`. Field-level extensions land on the existing `gate_pass.data.trust_anchor` and `gate_fail.data.reason`; no new event names beyond the three.
- **Bounded one-retry path** for `INVALID/trailer_sha_not_in_local_clone` (trailer SHA garbage-collected after a fresh checkout). Caller runs ONE `git fetch --prune origin <branch>` then re-dispatches the agent; second INVALID is terminal. `git fetch` failure (network, auth, branch deleted, rate limit) emits a stderr warning + `error` audit event with `data.reason="git_fetch_failed"`, then re-dispatches unchanged — autopilot continues; the queue does not halt. Mirrors Phase 3.3v's max-1-retry policy.

### Fixed
- **Pre-condition gate reasons restored to `GATE_FAIL_REASON_ENUM`** (T1 narrowed 10→7 incorrectly; total now 11). Phase 1.4 pre-flight gates emit `pr_state_not_open`, `is_draft`, `ci_red`, `merge_state_blocked` as `data.reason` regardless of trust path; the seven trust-resolution reasons remain semantically distinguished.
- **Phase 2.2 agent-refusal fallback now emits a user-facing diagnostic.** Previously fell back silently to `squash`; now emits a one-line stderr warning before falling back, plus `data.refusal_reason=<reason>` on the audit event so consumers can distinguish agent-refused vs agent-decided fallbacks.
- **Phase 1.4 "Otherwise" diagnostic reworded** to drop the structurally-close-to-the-retired-antipattern wording. Was: `run /review-pr first, then re-invoke /merge`. Now: `run /review-pr first to establish a trust trail; the next /merge invocation will pick this PR up automatically`.
- **Run-summary rationale vocabulary aligned with `merge-strategy-decider` signals.** Replaces the legacy `flag, label, heuristic, agent-decided` with the agent's actual signal vocabulary (`wip-marker`, `single-commit`, `conventional-ratio`, `divergence`, `label-hint`, `repo-convention`, `agent-refusal-fallback`).
- **Editor-note line numbers replaced with semantic anchors.** The five-mirror-site editor note carried hardcoded `SKILL.md:157` / `:415` / `:23` / `:31` / `:146` line numbers that drifted as soon as Wave 3 inserted prose into Phase 1.4. Replaced with section/heading anchors that stay accurate across future prose edits.

### Refactored
- **`/uberdev:review-pr` Phase 2 simplify pass on PR #47** — 5 of 14 advisory simplify findings auto-applied: Phase 3.4 failure-mode-table consistency, Common Mistakes bullet rephrasing, redundant `Refusal triggers:` inline label dropped from both new agent files, M55 (literal duplicate of M37.gfr3) and M57 (no-op meta-marker) deleted from `tests/merge.test.sh`, `CONVENTIONAL_COMMIT_THRESHOLD` referenced by name in `merge-strategy-decider` Process step 2(c) per the SKILL.md "values are NOT re-inlined" convention.

### Tests
- **`tests/merge.test.sh` 130 → 192 assertions.** Modified M35 (PATH_3 retirement), M37 (`GATE_FAIL_REASON_ENUM` 6 → 11 members with the four pre-condition gate reasons restored), and M45.trail (T6 wording change). Appended M47–M60 covering agent contract files, Phase 1.4 / Phase 2.2 dispatch sites, new Constants rows, deprecated stderr strings, atomic five-mirror-site update, fanout chunking prose, PATH_2 (c) retry path prose. M55 (literal duplicate of M37.gfr3) and M57 (no-op meta-marker) deleted in Phase 2 simplify. Final: **192 pass / 0 fail**.

### Backwards compatibility
- **`--bypass-protections` is a no-op post-v0.17.0.** Trust resolution is fully agent-decided via `trust-trail-evaluator`; there is no PATH_3 admin-bypass anchor and no CI-red waiver. `admin_bypass` and `waiver_recorded` audit events remain declared in `AUDIT_EVENT_ENUM` but are never emitted post-v0.17.0.
- **`--squash` / `--rebase` / `--merge` are no-ops post-v0.17.0.** Same backward-compat shape as `--yes` / `-y`: parsed without error, deprecated stderr notice + `deprecated_flag_used` audit event.
- **PATH_1 (`reviewDecision == "APPROVED"`) trust path unchanged.** Team-mode callers with branch protection are unaffected by the v0.17.0 changes; only PATH_2 (uberdev review trail) is agent-delegated.
- **Five-mirror-site atomicity preserved.** Author-identity-NOT-a-gate framing remains repeated across all five mirror sites (`skills/merge/SKILL.md` Phase 1.4 + Common Mistakes, `commands/merge.md` Autopilot + Deprecated Flags `bot_authors_allow_list`, `skills/using-uberdev/SKILL.md` `bot_authors_allow_list`).

## [0.16.1] - 2026-05-03

### Fixed
- **`finish-branch` permission-pattern `unmatched '` (#42, #45)** — Single-quoted heredoc delimiters (`<<'EOF_HEADER'`, `<<'PR_TITLE_EOF'`) in `plugins/uberdev/skills/finish-branch/SKILL.md` tripped Claude Code's permission-pattern evaluator with `(eval): unmatched '`, leaving `/finish-branch` and the `/finish` alias unrunnable (manual `gh pr create` was the only escape hatch). The evaluator's shell tokenizer doesn't honor heredoc literal-context semantics — it paired the delimiter's leading `'` with the next `'` it saw (the `PR_URL_REGEX='…'` assignment), inverted quote-balance from there, and surfaced the regex's trailing `'` as the unmatched-quote error. Fix: drop the quotes from both delimiters (`<<EOF_HEADER` / `<<PR_TITLE_EOF`); the agent contract now requires composed PR title and body bytes free of `$`, backticks, and backslash (typical PR Summary text already satisfies this). The title-injection guard is preserved end-to-end by the existing `gh --title "$PR_TITLE_VAR"` double-quoted byte-verbatim expansion. Test coverage adds an `assert_not_grep` regression canary that rejects any `<<'X'` or `<<"X"` form anywhere in the skill (`tests/finish-branch-auto-chain.test.sh` 23 → 24 assertions).

## [0.16.0] - 2026-05-03

### Added
- **`/review-pr` → `/merge` SHA-bound trust signal (#40)** — `/review-pr` on a green run now emits three durable artifacts: PR label `uberdev-approved`, commit trailer `Reviewed-by: uberdev/review-pr@<head-sha>` (full 40-character SHA), and local audit JSON at `.uberdev/runs/<run-id>/review-pr-verdict.json`. The trailer is the load-bearing trust artifact (intrinsically SHA-bound via the git object DAG); label and JSON are corroborating defense-in-depth presence checks. `/merge` Phase 1.4 reframes from a single-condition gate to **trust-resolution** with three paths: PATH_1 (`reviewDecision == "APPROVED"` — team / branch-protection), PATH_2 (`/review-pr` trail bound to live `headRefOid` — solo-dev / no-protection), PATH_3 (`--bypass-protections` admin override). New `gate_pass.data.trust_anchor` ∈ `{reviewDecision_approved, uberdev_review_trail, bypass_with_waiver}` and `gate_fail.data.reason` ∈ `{review_decision_not_approved, trust_trail_missing, trust_trail_stale_sha, trust_trail_label_missing, trust_trail_trailer_missing, trust_trail_json_missing, ci_red, pr_state_not_open, is_draft, merge_state_blocked}` field-level extensions land on the existing `gate_pass` / `gate_fail` events (no new event names).
- **Stale-SHA detection covers force-push + amend + rebase + squash uniformly.** Phase 1.4 PATH_2 (c) compares the trailer's embedded `<head-sha>` against **live** `gh pr view <N> --json headRefOid` (NOT against any local ref). One verification primitive covers all rewrite types. Refusal diagnostic: `/review-pr ran on commit <trailer-sha> but PR head is now <live-sha> — re-run /review-pr, then re-invoke /merge`.
- **Five new constants** in `skills/merge/SKILL.md`: `UBERDEV_APPROVED_LABEL`, `REVIEW_PR_TRAILER_PREFIX`, `RUN_ID_REGEX` (`^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` — path-traversal hardening), `TRUST_ANCHOR_ENUM`, `GATE_FAIL_REASON_ENUM`.
- **Editor note at `skills/merge/SKILL.md:125` corrected** from "four mirrors" to "five mirror sites" with explicit file:section enumeration of all 5 (this skill body, this skill's `## Common Mistakes`, `commands/merge.md:23`, `commands/merge.md:31`, `skills/using-uberdev/SKILL.md:146`).

### Changed
- **`/review-pr` exit codes are now 0 / 1 / 2** (was always 0). `0` = green (Phase 1 APPROVE + Phase 2 status ∈ {ran/APPROVE, skipped}); `1` = Phase 1 REJECT or REVISIONS_REQUIRED; `2` = Phase 2 status `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure). **Behavioral break** for callers that scripted against the always-0 contract — either ignore the exit code (preserve old behavior) or branch on it (use new behavior). Surfaces silent reviewer-crash failures that the trust signal exists to eliminate.
- **`commands/review-pr.md:82-83` prose updated in lockstep** with the exit-code contract change. Distinguishes "skipped" (Phase 2 not run; eligible for green; exit 0) from "blocked" (Phase 2 fanout crashed; exit 2). The previous "still exits successfully" wording is removed.
- **`tests/merge.test.sh` 103 → 130 assertions** (12 new M-blocks M35–M46, 27 new sub-assertions covering trust-signal constants, PATH_1/PATH_2/PATH_3 trust-resolution structure, gate_pass/gate_fail enum values, stale-SHA primitive, and mirror-site sync). **`tests/review-pr.test.sh` 33 → 43 assertions** (R1–R6, 10 new sub-assertions covering the green-run predicate, label/trailer literals, exit-code table, and run-id regex).

### Fixed
- **`code-simplifier` agent persona reframed as audit-only (#43)** — frontmatter description and system-prompt body claimed the agent "applies project best practices", but `code-simplifier` dispatched by `uberdev:post-impl-review` only emits YAML findings and never modifies files. The mismatch silently dropped simplifier value on every wave/inline review (LLM read the persona literally, expected to write code, then emitted nothing actionable). Reframe touches `plugins/uberdev/agents/code-simplifier.md` (frontmatter description, system-prompt body, three example blocks, audit/refinement-process steps — all now read as audit-only: "audits", "advisory findings", "you do not modify files") and `plugins/uberdev/skills/post-impl-review/SKILL.md` (skill description marks reviewers as advisory; Q1-deferral and "Per Q1" wording replaced with an explicit audit-only invariant plus pointers to the writer entry points `/uberdev:simplify` and `/uberdev:review-pr` Phase 2). Output Rules block (cite-by-`file:line` + secret-leak prevention) preserved verbatim. Out of scope: agent rename, post-impl-review delegating to apply machinery, no SDD or solve-pipeline changes — both already treat aggregation as advisory PR-body text.

### Refactored
- **Drop redundant applier-pointer trailer in `code-simplifier` system prompt (#43)** — Phase 2 `/uberdev:review-pr` simplify pass converged across all three lenses (reuse, quality, efficiency) on the same finding: the appended Output Rules trailer ("To apply findings, the user runs `/uberdev:simplify` or `/uberdev:review-pr` Phase 2.") duplicated the identical applier pointer already present in the line-87 closing activation paragraph ("a follow-up `/uberdev:simplify` / `/uberdev:review-pr` Phase 2 invocation can act on. **You do not modify files.**"). Iron rule preserved: documented contract is unchanged — line 87 retains both the applier pointer and the bolded **You do not modify files.** sentinel; the `## Output Rules — secret-leak prevention` block remains byte-identical. Tightens the system prompt by ~20 tokens per dispatch — `code-simplifier` runs on every wave/inline review, so the saving compounds.

### Backwards compatibility
- **Trust-signal emission is additive on green runs.** Existing `/review-pr` invocations on REJECT / REVISIONS_REQUIRED paths produce no new artifacts (label not added, trailer not written, JSON not created). The exit-code change is the only behavioral break; CHANGELOG calls it out explicitly.
- **`/merge` Phase 1.4 trust resolution preserves PATH_1 (existing `reviewDecision == "APPROVED"` behavior).** Team-mode callers with branch protection are unchanged. PATH_2 is only consulted if PATH_1 fails. PATH_3 (`--bypass-protections`) is unmodified.
- **No new packages, no infra changes, no schema migrations.** Pure additive markdown driver edits + bash shape-check tests. Rollback is a single PR that removes the artifact-emission logic, reverts Phase 1.4 to the single-condition gate, and resets the 5 mirror sites.

## [0.15.2] - 2026-05-02

### Fixed
- **Trivial- and small-tier `/solve` and `/turbo` PRs were silently skipping the `/uberdev:review-pr` chain — and with it the entire Phase 2 simplify ceremony.** The 4 heredocs in `solve-pipeline/SKILL.md` (`trivial-solve`, `trivial-turbo`, `small-solve`, `small-turbo`) ended with `Open PR with Closes #N` and a *negative* directive ("Do NOT run `/uberdev:simplify` standalone before push — Phase 2 of `/uberdev:review-pr` runs it automatically"), but **never told the spawned agent to actually invoke `/uberdev:review-pr` after `gh pr create`**. Trivial/small bypass `finish-branch` entirely (they call `gh pr create` directly), so the canonical chain hand-off (`finish-branch` Option 2 → invoke `uberdev:review-pr` via the Skill tool, line 296) never fired either. The chain was implicit — the spawned agent had to read user-global `CLAUDE.md` ("MANDATORY: run `/uberdev:review-pr` after pushing the PR. No exceptions, hotfixes included.") and infer the next step on its own. Same class of bug as the orchestrator Phase 2 fix in v0.15.1: the heredoc-prose was relying on inference where it should have been imperative.
- **Net effect of the bug:** trivial/small PRs got a Phase-1 review fanout *only if* the spawned agent independently decided to run `/review-pr`; the 3-lens simplify pass (reuse / quality / efficiency) — wired to fire as Phase 2 of `/review-pr` — never ran on trivial/small at all. Medium/large was unaffected (orchestrator → subagent-driven-dev → finish-branch → invoke `uberdev:review-pr` is hard-coded and locked by an existing test assertion).
- **Tightened all 4 heredocs.** Added an explicit numbered final step to each: `Capture the PR URL from gh pr create output and invoke the uberdev:review-pr [--turbo] skill via the Skill tool with that URL. This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory — do NOT block on REVISIONS_REQUIRED.` Turbo heredocs forward `--turbo` into `/review-pr` to keep the chain unattended (mirrors `finish-branch`'s `--turbo` propagation pattern).

### Added
- **`tests/turbo-flow.test.sh` 55 → 57 assertions.** Two new positive locks:
  - `Capture the PR URL` literal anchor count must equal 4 (one per heredoc; future edits cannot delete the directive from one heredoc while leaving three intact).
  - `uberdev:review-pr --turbo` literal anchor count must equal 2 (trivial-turbo, small-turbo) so a future edit cannot drop `--turbo` propagation and re-introduce attended-mode regressions on trivial/small turbo runs.

  These mirror the pre-existing count=4 lock on the negative `Do NOT run /uberdev:simplify standalone before push` directive — both directives now move in lockstep, neither can drift without test failure.

## [0.15.1] - 2026-05-02

### Fixed
- **`/solve` was silently collapsing into `/turbo` for medium/large tier.** The launcher heredoc was correct (no `--turbo` written when `AUTO_MODE=0`, locked by the existing differential guard at `tests/turbo-flow.test.sh:91-103`); the regression was in `plugins/uberdev/skills/orchestrator/SKILL.md` prose. Phase 2 Q&A is the **only** phase that distinguishes `/solve` from `/turbo` for medium/large — every other phase (research fanout, spec-writer, spec-reviewer, plan-writer, plan-reviewer, subagent-driven-dev, finish-branch auto-PR) is unattended in both modes — and the prose around Phase 2 was too soft for a freshly-spawned LLM with no prior-conversation anchor:
  - **Skill description** called Q&A `optional` and spec-reviewer `optional`. Both stale: spec-reviewer is always-on for medium/large per Phase 3.5, and Q&A is the load-bearing /solve-vs-/turbo signal. "Optional" read as "agent's choice" → spawned agents skipped Q&A → /solve felt like /turbo.
  - **Phase 2 non-turbo prose** led with `unchanged — ask 3-5 clarifying questions…`. The word `unchanged` referenced previous-version behavior, but a freshly-spawned LLM has no "previous version" to reference; the line read as filler with no imperative force. No `MUST`, no gate language, nothing preventing the LLM from concluding "the issue is well-specified, no questions needed".
  - **`AskUserQuestion` is a deferred tool** in current Claude Code harnesses (calling without `ToolSearch` first throws `InputValidationError`). The skill never mentioned this; a spawned agent that hit the error could silently fall back to "best guess" and continue — indistinguishable from turbo.
- **Tightened all three sites.** Phase 2 now leads with "this phase is the only signal that distinguishes /solve from /turbo… Do not skip", uses imperative `You MUST ask 3-5 clarifying questions`, adds explicit `Do NOT proceed to Phase 3 until the user has answered` gate, and includes a `ToolSearch` instruction (`select:AskUserQuestion`) with a `Do NOT silently auto-pick on tool-load failure` rule. Skill description rewritten to drop "optional" mis-signals: `research fanout → Q&A [interactive unless --turbo] → spec-writer → spec-reviewer [always-on for medium/large] → plan-writer → plan-reviewer [always-on] → subagent-driven-dev`.

### Added
- **`tests/turbo-flow.test.sh` 48 → 55 assertions.** New `orchestrator Phase 2 imperative gate` section locks the imperative phrasing (`You MUST ask 3-5 clarifying questions`), the explicit `Do NOT proceed to Phase 3` gate, the "only signal that distinguishes /solve from /turbo" anti-skip prose, the `ToolSearch select:AskUserQuestion` deferred-tool callout, and the `Do NOT silently auto-pick on tool-load failure` rule. Two `assert_not_grep` canaries ban the stale `optional Q&A` and `optional spec-reviewer` strings from re-appearing in the description. Full suite still passes (322 assertions across 11 test files).

## [0.15.0] - 2026-05-02

### Refactored (simplify-loop edits from `/uberdev:review-pr` Phase 2)
- **Step 5b sed forks 6 → 1** (efficiency lens) — Phase B was running six sequential `sed -i` invocations per spawn to template the launcher script (`REPO_ROOT`, `CLAUDE_BIN`, `ISSUE_NUM`, `TIER`, `DETECTED_TERMINAL`, `PERM_FLAG_VALUE`). All placeholders are unique tokens with no cross-substitution risk, so they collapse into one `sed -e ... -e ... -e ...` call. Saves 5 forks per spawn × N issues — small per-call win that compounds across batch dispatches. `PERM_FLAG_VAL` setup hoisted above the consolidated sed so substitution-value computation reads contiguously. In-place semantics (`SED_INPLACE` BSD/GNU dispatch) and per-expression delimiter choice (`|` vs `/`) preserved.
- **Dead-alternation regex split into two single-line assertions** (quality lens) — `tests/turbo-flow.test.sh` had a TURBO MODE banner assertion whose left-hand alternation (`for n in "${ISSUE_NUMS[@]}"…\n…medium…\n…break`) was dead code: `grep -E` without `-z` does not match across newlines, so only the right-hand alternation (`TIERS[$n].*medium`) ever fired. Split into two genuine assertions: one greps for the dedup loop construct, the other for the `break` after the first medium-tier hit. Same prose intent, more rigorous lock.
- **Reuse lens** — analyzed 5 candidates (heredoc consolidation, `osascript` heredocs, sed substitutions, notification fallback chain, comment redundancy); all rejected as either test-locked, right-sized, or net-negative for clarity. The four trivial/small heredocs are contractually locked at count=4 by `tests/turbo-flow.test.sh`; the iTerm vs Terminal.app `osascript` heredocs use distinct AppleScript verbs (not duplication); the notification fallback chain is three single-line branches with no genuine indirection win.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **zsh word-split footgun in multi-issue parser** — initial Phase 1 implementation used `for token in $ARGUMENTS; do …`, which does NOT word-split scalar parameters in zsh (SH_WORD_SPLIT off by default). Under zsh — Claude Code's actual Bash-tool shell on macOS — the loop saw `"5 6 7"` as a single token, the anchored `^[0-9]+$` rejected it, and `/turbo 5 6 7` died at the usage check (`/turbo 42` worked only because `"42"` happens to satisfy the regex when treated as one token). Replaced with a portable subshell pipeline: `ISSUE_NUMS=($(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++'))`. Array assignment `arr=($(cmd))` word-splits the substitution output on `$IFS` in BOTH bash and zsh; the pipeline tokenizes on spaces, anchored regex rejects flag tokens like `--terminal=foo123`, awk dedupes preserving first-seen order. New regression test in `turbo-flow.test.sh` greps the pipeline form so the footgun cannot reappear.
- **Phase A title/tier had no concrete defaults** — initial pass left `TITLES[$ISSUE_NUM]="$TITLE"` and `TIERS[$ISSUE_NUM]="$TIER"` referencing variables that prose comments told Claude to set. Now the bash block computes both deterministically: `TITLE_RAW=$(jq -r .title <<<"$ISSUE_JSON")` with a 40-char ellipsis truncation, and `TIER="${OVERRIDE:-medium}"` (the safe escalation default — `--trivial`/`--small` override; ambiguity routes through the full brainstorm pipeline). The triage prose above the bash block still drives Claude to downgrade when an issue is genuinely trivial/small, but the dispatch is now valid even if the heuristic refinement is skipped.
- **Phase B silently dropped per-issue dispatch failures** — initial pass appended unconditionally to `SPAWNED+=("#$ISSUE_NUM ($TIER)")` after the `case` statement, so a failing `cmux new-workspace` (dead socket) or AppleScript permission denial never surfaced — the user saw "Spawned 3 agents" while one had actually died. Now `DISPATCH_RC=$?` after the case and an `if/else` route success to `SPAWNED` and failure to `DISPATCH_FAILED`. Ghostty's branch ends in an `echo` for both AppleScript-success and AppleScript-fail-then-nohup paths, so both legitimately record as success (the agent is spawned either way, just via a different mechanism). Phase B failure summary block prints partial-batch failures to stderr; the success notification body appends `— N dispatch failure(s)` if any. Locked by 2 new assertions (`DISPATCH_FAILED` array, `DISPATCH_RC=$?` capture).
- **Apple Event queue claim softened** — the comment justifying why iTerm/Terminal don't need the Ghostty 600 ms pause read "(Apple Event queue serializes)" as a load-bearing fact; reworded to "(the Apple Event queue serializes same-application AppleScript calls in practice)" to flag it as an empirical observation, not an unconditional API guarantee.

### Added
- **`/turbo` and `/solve` accept multiple issue numbers** — `/turbo 5 6 7` (and `/solve 5 6 7`) validates each listed issue (OPEN + classifiable) before dispatching, then spawns one autonomous Claude agent per issue into its own terminal session (cmux workspace / Ghostty tab / iTerm window / Terminal.app window / nohup background process). Per-issue artifacts are namespaced by `$ISSUE_NUM` (`/tmp/solve-prompt-N.txt`, `/tmp/solve-N.sh`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch, `#N <title>` tab) so the spawns are collision-free. Single-issue invocation behaviour is byte-identical. Override flags (`--trivial|--small|--full`, `--auto`, `--terminal=...`) apply batch-wide; per-issue overrides are not supported (run separate invocations for different tiers).
- **Phase A validate-all-first contract in `solve-pipeline/SKILL.md`** — if any of the listed issues is closed, missing, or fails `gh` fetch, all errors are printed and the run aborts with `no agents dispatched` **before** spawning anything. No partial-state cleanup ever required. Phase B then loops the per-issue dispatch (write prompt → write launcher → spawn into chosen terminal).

### Changed
- **`solve-pipeline/SKILL.md` restructured into Phase A (validate) + Phase B (spawn).** Step 1 parses `ISSUE_NUMS` array (anchored `^[0-9]+$` rejects `--terminal=foo123`-style flag tokens; dedupe prevents same-issue race on shared worktree path). Step 3 hoists terminal detection + REAL_CLAUDE binary resolution + TURBO MODE banner out of the per-issue loop (terminal-detect runs once; banner prints once if any tier is medium). Steps 4 (was 3) becomes Phase A; Steps 5a/5b/5c (were 4/5/6) execute inside the Phase B `for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do ... done` loop. The medium `if [[ "$AUTO_MODE" == "1" ]]; then ... else ... fi` block is preserved at column 0 (zsh/bash do not require indentation inside `for ... done`), so `tests/turbo-flow.test.sh`'s differential-guard awk anchor remains valid.
- **Ghostty multi-spawn serialized with 600 ms pause.** AppleScript `Cmd+T` keystroke dispatch is asynchronous; firing three keystrokes in <100 ms can race all three into the first-created tab. Pause applies only when `TERMINAL=ghostty` AND `${#ISSUE_NUMS[@]} > 1`. cmux (IPC API), iTerm/Terminal (scripted `create window`/`do script`, Apple Event queue serializes), and nohup all spawn race-free without the pause.
- **Notifications batched.** One summary `cmux notify` / `terminal-notifier` / `osascript display notification` per `/turbo` invocation listing all spawned issues, replacing the prior N per-spawn notifications. Removes notification flooding on multi-issue runs.
- **`tests/turbo-flow.test.sh` 29 → 48 assertions.** New section locks the multi-issue parser (portable subshell pipeline with `tr`+`grep -E '^[0-9]+$'`+`awk '!seen[$0]++'`, zsh word-split footgun comment, Phase A error-printf format, all-errors-before-abort), Phase A contract (`no agents dispatched`, validate-all-first), Phase B loop construct (`for ISSUE_NUM in "${ISSUE_NUMS[@]}"`, `DISPATCH_FAILED` tracking, `DISPATCH_RC=$?` capture), TURBO MODE banner-printed-once dedup mechanic (`break` after first medium hit, split into two single-line assertions because `grep -E` without `-z` does not match across newlines), Ghostty serialization (`sleep 0.6`), batched-summary notification (`SPAWNED[@]`), and REAL_CLAUDE-hoist line-ordering. Wrapper section gains argument-hint shape assertions for both `/solve` and `/turbo`.
- **`tests/ghostty-dispatch-no-instance-leak.test.sh` awk anchor updated.** The dispatch case moved from `### 6.` to `#### 5c.` inside the new Phase B for-loop; the test's section-extraction awk pattern follows. Same 7 assertions as before; no contract change.
- **`/turbo` and `/solve` command frontmatter** updated: `argument-hint` becomes `<issue-number> [<issue-number>...]`; `description` notes multi-issue dispatch; usage examples added showing `/turbo 5 6 7`.
- **README.md `/turbo` section** gains a "Multi-issue dispatch" paragraph after the orthogonality table.

### Backwards compatibility
- **No user-facing breakage.** `/turbo 42` and `/solve 42` (single-issue) behaviour is byte-identical to 0.14.0. New multi-issue syntax is purely additive. No flag deprecations. Plugin manifest version bumped 0.14.0 → 0.15.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.14.0] - 2026-05-01

### Changed
- **`/uberdev:merge` is now unconditionally non-blocking** — every blocking gate that previously halted the queue or asked the user a question has been removed. Specifically: the Phase 1.4 PR-author allow-list condition (`PR author is repo collaborator OR ∈ bot_authors_allow_list`) is **deleted** — any APPROVED + CI-green PR is eligible regardless of author identity (collaborator, bot, external contributor); the trust anchor is `reviewDecision == "APPROVED"` plus GitHub branch protections. The Phase 2.2 step 3 external-author defer logic, the `defer` strategy, and the `pr_deferred` audit event are deleted along with it. Phase 1.3's ask-and-persist branch prompt is replaced by a literal `INTEGRATION_BRANCH_FALLBACK` (`main`) with a one-line stderr warning — autopilot does not ask, it acts. Phase 2.1 dependency-cycle abort is replaced by auto-break-via-createdAt-fallback. Phase 3.3vi push-non-FF halt is replaced by per-PR park (`PARK_REASON_ENUM` value `push-non-ff`); queue continues. Phase 4.2 `git pull --ff-only` halt is replaced by auto-rebase against `origin/<integration_branch>`; on rebase conflict the rebase aborts (preserving local head) and the divergence surfaces in the run summary while the run still completes. Phase 1.7 single-PR pre-flight fail now exits cleanly with a "no eligible PRs" summary rather than erroring. The pre-flight banner now reads `/merge autopilot — no prompts, no halts; per-PR failures park and the queue continues.` (the `Allow-listed authors:` line + Print-Twice rule are removed). The only remaining halt is `flock` contention from another live `/merge` (concurrent-run safety, not a user gate).
- **`bot_authors_allow_list` config key is now DEPRECATED** alongside `auto_confirm` / `--yes` / `-y`. Parses without error for backward compat but has no behavioural effect. `using-uberdev/SKILL.md` config-key documentation updated to reflect both deprecations and the new literal-`main` integration-branch fallback.
- **`tests/merge.test.sh` 90 → 103 assertions.** M22 splits into M22.drop (positive) + M22.no-defer (negative — STRATEGY_ENUM must NOT list the removed `defer`). M23 drops `pr_deferred` from the required audit-event list and adds an explicit M23.no-pr_deferred negative. M24 swaps the `external-author-not-allow-listed` PARK_REASON_ENUM assertion for `push-non-ff` (the new park reason) and adds M24.PARK.no-ext-author negative. M27 drops the `Deferred:` outcome assertion and adds M27.no-Deferred negative. M28 retargets the banner-content scope from "all of Phase 1" to "just Step 1.0" so the legitimate Phase 1.4 deprecation prose isn't tripped by the negative grep. M16 retargets from the removed atomic-rename mktemp pattern (no more persist step) to a negative guard that Step 1.3 contains no `mktemp` / `mv` / `[Y/n]`. New M16b verifies Phase 1.3 ships the fallback-branch existence check (`git ls-remote --heads origin` + `fallback-branch-missing` audit event). New M29–M33 cover the no-blocker contract directly: M29 (Phase 1.4 has no author gate), M30 (Phase 1.3 falls back to `INTEGRATION_BRANCH_FALLBACK` with no prompt), M31 (Phase 4.2 auto-rebases on ff-only fail), M32 (Phase 3.3vi parks PR on push-non-FF, queue continues), M33 (Phase 2.1 auto-breaks dependency cycles via createdAt fallback) — M33 collapsed to a single positive check + explicit `M33.no-old-rule` negative regression guard. New M34 directly inspects the Phase 3.4 failure-mode table for the no-halt invariant (Action column may never list `halt`). Suite total: 342/342 across 11 test files.

### Fixed (review-loop fixes from `/uberdev:review-pr` Phase 1)
- **`agents/conflict-resolver.md` orphan halt-prose** — line 56 still claimed `status: AMBIGUOUS halts the queue`, contradicting the new no-halt invariant in `skills/merge/SKILL.md` Step 3.3iv. Replaced with the correct park-and-continue contract; the calling skill maps the agent's status to a `pr_parked` audit event with `data.reason="ambiguous"` or `"refused"`.
- **`commands/merge.md` Deprecated Flags now lists `bot_authors_allow_list`** alongside `--yes` / `-y` / `auto_confirm`. The deprecation story was previously split across two files (`using-uberdev/SKILL.md` + `skills/merge/SKILL.md`) but missing from the command's own help; readers consulting `/merge` documentation now see the full list.
- **`skills/merge/SKILL.md` Phase 1.3 fallback-branch existence check** — added `git ls-remote --exit-code --heads origin "<INTEGRATION_BRANCH_FALLBACK>"` probe before proceeding to Step 1.4. Repos whose default branch is not `main` (e.g. `master`, `trunk`, `develop`) and whose four-tier resolution fails would previously have hit a confusing `gh pr merge --base main` 404 several phases downstream; now /merge declines cleanly with `error` audit event `data.reason="fallback-branch-missing"` and a one-line stderr pointing the user at `integration_branch:` config.
- **CHANGELOG 0.13.0 backfill** — PR #35 ("/merge true autopilot") bumped the manifest version but skipped its own CHANGELOG entry; the gap is now backfilled to keep Keep-a-Changelog readers consistent.

### Backwards compatibility
- **No CLI breakage.** Existing `/merge` invocations work identically; the surface change is purely the removal of failure modes that previously rejected work the user wanted to land. `/merge --yes` / `-y` / `auto_confirm` / `bot_authors_allow_list` remain parseable (deprecated). Plugin manifest version bumped 0.13.0 → 0.14.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.13.0] - 2026-05-01

### Changed
- **`/uberdev:merge` initial autopilot pass** (#35, PR #35) — removed the `[y/N]` plan-confirm prompt at Phase 2.4; deprecated `--yes` / `-y` CLI flags and the `auto_confirm` config key (parsed without effect, with a stderr deprecation notice and a `deprecated_flag_used` audit event). Stale-branch handling at Phase 4.5 became autopilot agent-decided with safety-precondition gates (FF-able OR non-conflicting probe AND not a PR head ref AND no force-push protection). Constants table grew with `AUTO_CONFIRM_KEY`, `AUTO_CONFIRM_FLAGS`, `AUTO_CONFIRM_REASON_ENUM`, `STALE_REBASE_DECISION_ENUM`, `TEST_FAIL_DECISION_ENUM`, `DEPRECATED_FLAGS_NOTE`. Six new audit events added: `pr_parked`, `pr_deferred`, `stale_branch_rebase_decision`, `deprecated_flag_used`, `agent_strategy_switch`, `test_fail_agent_decision`. Test-fail handling at Phase 3.3v gained a 1-retry-1-switch agent-decided branch tree (re-resolve / strategy-switch / park) with audit-logged choices.
- **`/uberdev:review-pr` chains a mandatory simplify-pass** (PR #32) — Phase 1 review-and-fix loop is followed by Phase 2 simplify fanout; pre-push standalone `/simplify` calls collapsed since they duplicated work.
- **`/uberdev:review-pr` collapses duplicate `/simplify` pass** (PR #37) — the pre-push `/simplify` call in trivial/small heredocs duplicated work already done by Phase 2 of `/uberdev:review-pr`. Removed from solve-pipeline heredocs; saves three Task agent invocations per `/solve` trivial/small run with no quality loss.

### Fixed
- **`/solve` Ghostty dispatch instance leak** (#31, PR #33) — the auto-dispatched Claude agent no longer poisons the user's running Ghostty session.
- **Trust-boundary asymmetries flagged by `/uberdev:review-pr`** — orchestrator and merge skills tightened against prompt-injection-shaped content in untrusted external inputs (PR/issue bodies, conflict markers).

## [0.12.0] - 2026-04-30

### Added
- **`/uberdev:merge`** (#24, PR #27) — new top-level command + skill that orders, strategizes, and merges approved PRs end-to-end. 4-phase pipeline (pre-flight gate → merge plan with single user-confirm → merge + parallel conflict-resolve in scratch worktree → post-merge local sync) at `plugins/uberdev/skills/merge/SKILL.md`. New `agents/conflict-resolver.md` with textual-evidence return contract and 6 refusal triggers, dispatched one Task per conflicted file in a single assistant turn. New per-repo config keys `integration_branch` (CLI flag > env var `UBERDEV_INTEGRATION_BRANCH` > config file > `gh repo view --json defaultBranchRef`, with ask-and-persist fallback) and `bot_authors_allow_list` (default `["dependabot[bot]", "renovate[bot]"]`). Audit log at `.uberdev/runs/<run-id>/audit.jsonl`. `tests/merge.test.sh` ships 16 shape-check assertions (M1–M16) including the `Co-Authored-By: Claude` proximity guard and same-directory `mktemp` atomic-rename guard.
- **Auto-install for top-level aliases** (#21, PR #26) — `hooks/session-start` now auto-installs the six short-form forwarders (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`) on first session and refreshes them on plugin upgrade — no manual `/uberdev:install-aliases` step. Idempotent via `~/.claude/.uberdev-aliases-version` marker. Opt-out via `UBERDEV_NO_AUTO_ALIAS=1` (env, wins) or `auto_install_aliases: false` in `.claude/uberdev.local.md`. ALIASES table extracted into a shared helper `plugins/uberdev/lib/aliases-sync.sh` sourced by both the hook (auto-install) and `/uberdev:install-aliases` (manual install) — single source of truth, A6 drift test now reads from the helper. Marker-scoped collision skip preserves hand-authored files; `mktemp + mv -f` atomic-rename writes; symlink-containment guard refuses to sync into `~/.claude/commands` if it's a symlink. New `tests/aliases.test.sh` sections S1–S9 cover fresh install, second-session no-op, version-marker refresh, both opt-out paths (env + file), hand-authored file preservation, symlink containment, unreadable-marker degradation, concurrent-session race, CI wire-up.

### Changed
- **`/uberdev:finish-branch` defaults to push + create PR** (#20, PR #25) — the legacy 4-option menu (Merge / Push+PR / Keep / Discard) moves behind a new `--interactive` flag; default and `--turbo` paths now auto-push the branch, open a PR, then chain into `/uberdev:review-pr` via the `Skill` tool. Fulfills the global `~/.claude/CLAUDE.md` "MANDATORY: run `/uberdev:review-pr` after pushing the PR" rule by construction. Hardens the new auto-push path against (a) **title injection** via heredoc + quoted-variable read-back (closes the `gh pr create --title "<title>"` shell-substitution vector) and (b) **secret leakage** via a layered pre-push scan (gitleaks primary, regex floor for AWS / GH PAT / private-key shapes when gitleaks is missing) over both the to-be-pushed commit range AND the composed PR body file. The 6 reviewer agents whose output flows into the PR body (`code-reviewer`, `pr-test-analyzer`, `comment-analyzer`, `silent-failure-hunter`, `type-design-analyzer`, `code-simplifier`) gain a `## Output Rules — secret-leak prevention` "do not quote source/secrets" rule. New `tests/finish-branch-auto-chain.test.sh` and `tests/review-pr.test.sh` lock the contracts; `tests/turbo-flow.test.sh` retargeted to assert default-auto-PR + interactive-restores-menu + Skill-tool-chain canary.

### Fixed
- **Linux-only mtime test failure in `tests/aliases.test.sh` (S2/S3)** — try GNU `stat -c %Y` before BSD `stat -f %m`. On Linux GNU stat, `-f` is filesystem-mode (not format-string) and `%m` is treated as a missing file path, so the command dumps multi-line filesystem info on stdout *and* exits non-zero, which then ran the `-c %Y` fallback whose mtime got *appended* to the same captured value. The S2/S3 comparisons compared a multi-line blob (NEW) to an awk-extracted single token "File:" (OLD) — guaranteed to fail on every Linux runner. Order reversed; both macOS and Linux now exercise the same idempotency-equivalence assertion (52→55 assertions after also extending S1/S5/S8 to the 6th alias `/merge`).

### Backwards compatibility
- **No user-facing breakage.** Existing `/uberdev:finish-branch` invocations still work; `--interactive` restores the legacy 4-option menu for users who relied on it. `/uberdev:install-aliases` continues to be a valid manual entry point alongside the new auto-install. New `/uberdev:merge` and the `/merge` short-form alias are purely additive. Plugin manifest version bumped 0.11.0 → 0.12.0; marketplace `version` bumped to match so `/plugin marketplace update uberdev` picks up the release.

## [0.11.0] - 2026-04-30

### Added
- **Top-level command aliases** (#16, PR #17) — `/uberdev:install-aliases` writes one-way forwarders into `~/.claude/commands/` so the five daily-driver commands work without the `uberdev:` namespace prefix: `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`. `/uberdev:uninstall-aliases` removes them (marker-scoped — hand-authored files preserved). Existing `/uberdev:<command>` invocations are unchanged (additive only). Forwarders capture the absolute plugin-install path at write time; no body duplication. Run `/uberdev:install-aliases` once after plugin install to opt in. `tests/aliases.test.sh` (27 assertions) pins the marker contract, collision detection, and README discoverability.

### Changed
- **`/issue` slimmed to 2 Sonnet scouts** (#14, PR #18) — replaces the prior 8-Opus-agent research fanout (Phases 1.5/2-4/4.5/7) with a thin 2-Sonnet-scout fanout (`codebase-scout`, `triage-scout`) dispatched in a single assistant turn. **Median wall-clock drops from minutes to under 30s.** New dedicated agents at `plugins/uberdev/agents/codebase-scout.md` and `triage-scout.md`, both pinning `model: sonnet` with four-layer defence-in-depth against the upstream `affaan-m/everything-claude-code#173` model-frontmatter regression. Documented escape hatch: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`. `--no-explore` soft-deprecated (notice + no-op, removal target v1.0.0). `## Security signals` / `## Current ecosystem` / `## Constraints` sections removed from `/issue` templates. `brainstorm/SKILL.md`'s issue-research short-circuit removed (orchestrator solve-time fanout unchanged). RFC `2026-04-29-issue-deep-root-cause-research-fanout.md` annotated as partially superseded.
- **`/solve` and `/turbo` deduped via shared skill** (#15, PR #19) — extracts the ~360-line shared launcher pipeline (arg parsing, repo detection, tier classification, prompt heredoc, terminal spawn, notify, retitle) from `commands/solve.md` (430 → 27 lines) and `commands/turbo.md` (452 → 29 lines) into a new inline skill at `plugins/uberdev/skills/solve-pipeline/SKILL.md` (397 lines). Both commands now set `export AUTO_MODE={0,1}` and invoke the skill; the 10 `DELTA from /solve:` / `DELTA from /turbo:` markers and the `DUPLICATION NOTE` banner are gone — divergence is now expressed as `if [[ "$AUTO_MODE" == "1" ]]` conditionals in a single source of truth. Renamed the legacy `AUTO_MODE` (permission-mode flag) to `AUTO_PERMISSIONS` inside the skill to disambiguate from the new `AUTO_MODE` (turbo-vs-interactive). `tests/audit-fixups.test.sh` adds C6/C7 (skill exists, no `context:` frontmatter, AUTO_PERMISSIONS count ≥ 3, both wrappers ≤ 100 lines); `tests/turbo-flow.test.sh` pins both wrapper-to-skill links and the AUTO_MODE exports. Suite goes 83 → 92 assertions.

### Backwards compatibility
- **No user-facing breakage.** `/uberdev:solve` and `/uberdev:turbo` invocations are byte-equivalent in behavior; the wrappers now delegate to `solve-pipeline`. `/uberdev:issue --no-explore` still parses but is soft-deprecated. The `legacy cache` heredoc step in solve-pipeline's trivial/small tiers no-ops on issues created after the #14 redesign (no more `.uberdev/research/issue-N/` writes from `/issue`); legacy issues whose research was persisted under the previous fanout still get inlined.

## [0.10.0] - 2026-04-29

### Added
- **CI shape-check workflow** at `.github/workflows/test.yml` — single ubuntu-latest job runs all `tests/*.test.sh` on every push and PR with `permissions: contents: read` and `timeout-minutes: 5`. `actions/checkout@v4` major-tag pin.
- **Plan-drift awareness in per-task spec reviewer** (`subagent-driven-dev`). New `## Plan Task Description` placeholder in `spec-reviewer-prompt.md`; new `plan_task_description` dispatch parameter in `SKILL.md` step 4f with a ~3000-token excerpt size guard. Reviewer DO-list bullet directs flagging *plan drift* (structural deviation from plan even when spec appears satisfied — e.g., implementer skipped prescribed steps, swapped libraries, merged tasks).
- **Threat model section** in `plugins/uberdev/skills/brainstorm/SKILL.md` — documents localhost-only bind, single-user assumption, no auth, no proxy/tunnel for the brainstorm WebSocket+HTTP companion server.
- **Shared reviewer-prompt template** at `plugins/uberdev/skills/_shared/document-reviewer-template.md` — canonical Status/Issues/Recommendations skeleton referenced (via back-link comments) from `brainstorm/spec-document-reviewer-prompt.md` and `write-plan/plan-document-reviewer-prompt.md`. Skills don't auto-include partials; this is a documentation convention plus drift-defense reference.
- **2 new test suites:**
  - `tests/spec-reviewer-plan-aware.test.sh` (3/3) — verifies plan-drift wiring in spec-reviewer prompt + SKILL.md.
  - `tests/audit-fixups.test.sh` (12/12) — regression coverage for the C1/C3/C4/C5 review-fixup contracts: code-simplifier auto-trigger gate, stop-server `stopped_no_cleanup` JSON status, `gh` prereq moved from theatre command-files to `hooks/session-start`, brainstorm `## Threat model` section anchor.
- **Configuration documentation** in `README.md`: split into Implemented (`solve_terminal`, `solve_auto`) and Planned (`solve_tier_default`, `review_depth`, `parallel_solve`) tables with YAML-frontmatter example and env-var override precedence.
- **Tracked public docs**: `docs/rfc/` is now ignored-with-exception (`docs/*` + `!docs/rfc/`) so RFCs referenced from README/CHANGELOG resolve in clones; `plugins/uberdev/docs/testing.md` smoke-test matrix tracked.

### Changed
- **3 shell hooks hardened against symlink and path-traversal abuse:**
  - `hooks/inject-brainstorm-answers`: previous `[ -L "$f" ]` symlink check covered only the resolved file, not ancestors. Replaced with `is_safe_path()` helper that canonicalizes and walks every ancestor; refuses a symlinked root entirely; falls back to `python3 os.path.realpath` on macOS where BSD `realpath -m` is missing. `is_safe_path()` rejections now log to stderr (previously silent).
  - `skills/brainstorm/scripts/stop-server.sh`: replaced `[[ "$SESSION_DIR" == /tmp/* ]]` glob (passed for `/tmp/../home/...` traversals) with canonicalize-then-exact-prefix `case` over `/tmp/brainstorm-*` and `/private/tmp/brainstorm-*`. JSON shape now distinguishes success (`"stopped"`) from skipped cleanup (`"stopped_no_cleanup"` with `"reason"` field) — callers can detect partial failures.
  - `hooks/session-end`: replaced `rm -rf /tmp/uberdev-*` (followed symlinks) with `find -H /tmp -maxdepth 1 \( -name 'uberdev-*' -type d \) -not -type l -exec rm -rf {} +`. The `-H` is required because `/tmp` is itself a symlink on macOS.
- **`canonicalize()` helper** (used by the two hardened hooks): captures python3/realpath stderr into a variable and emits a useful diagnostic on total failure with helper-name prefix. Admins can now distinguish "tool unavailable" from "path rejected."
- **`code-simplifier` agent description AND body** narrowed to require explicit invocation. Body's "operate autonomously and proactively, refining code immediately after it's written" prose removed — it had directly contradicted the new gating frontmatter. The agent now activates ONLY when invoked via `/uberdev:simplify` or by the `subagent-driven-dev` post-wave fanout. Examples retained but framed as "illustrating logic, not licensing auto-trigger."
- **`gh` prerequisite check moved from markdown-command-file theatre to a real runtime guard** in `hooks/session-start` — Claude reads command markdown as instructions, not bash, so the prior `command -v gh || exit 1` blocks were never executed. New session-start check mirrors the existing `jq` check and injects a one-time visible warning when `gh` is missing without failing the session.
- **`/solve` ↔ `/turbo` divergence annotated**: verified Claude Code commands do not support textual file partials (the `@path` syntax is context-attachment, not substitution), so the original "extract `_solve-shared.md`" plan was infeasible. Both files now carry a `DUPLICATION NOTE — KEEP IN SYNC` banner with section-anchor references plus inline `<!-- DELTA -->` markers at every divergence point. Inline markers are the source of truth; the banner index is for navigation only. Out-of-scope follow-up: `/turbo` trivial/small tier omits the `post-impl-review` invocation that `/solve` includes.
- `eval "$VAR=1"` → `declare "$VAR=1"` in `skills/brainstorm/SKILL.md:124` and `skills/orchestrator/SKILL.md:68`. Currently safe (TOPIC iterates a hardcoded list) but a footgun if ever driven from external input.
- `hooks-cursor.json` paths normalized from `./hooks/...` to `${CLAUDE_PLUGIN_ROOT}/hooks/...` matching `hooks.json`.
- `.gitignore` adds `.env*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa*`, `node_modules/`, `*.log`, `.claude/`, plus explicit ignores for `plugins/uberdev/docs/{plans,uberdev,windows}/` (local-only design notes).
- Generic-ified `/Volumes/FJK SSD/...` example paths in `commands/{solve,turbo}.md` to `/Users/me/My Project/...`.

### Security
- 3 P0 path-traversal/symlink hazards in shell hooks closed (above).
- `server.cjs` carries an explicit localhost-only / single-user / unauthenticated header note pointing to the new SKILL.md threat model section.

### Backwards compatibility
- `stop-server.sh` JSON: callers parsing the literal `"stopped"` string would now correctly fail-loud when cleanup is skipped (the new `stopped_no_cleanup` status replaces `stopped` only on partial failure). `grep -rn '"stopped"'` confirmed no in-repo consumers depend on the old shape.
- Markdown `command -v gh || exit 1` removal is invisible to runtime (the blocks were never executed); the new session-start warning replaces them.

Closes the audit findings catalogued by the multi-agent research sweep on PR #13.

## [0.9.0] - 2026-04-29

### Added
- **`/uberdev:issue` Phase 2-4 fanout grows from 4 → 8 Task agents** in a single assistant turn. Existing four (`research-codebase`, `research-patterns`, duplicate-search, label/scope-validation) plus `research-prior-art`, `research-constraints`, `research-security` (Semgrep MCP + awesome-secure-defaults), `research-test-coverage` (test-surface mapping). Issue templates gain `## Current ecosystem`, `## Constraints`, and conditional `## Security signals` sections. `NO_EXPLORE=1` narrows to the four in-repo agents only.
- **Always-on spec/plan/PR-test reviewers** (tier-independent quality bar). Orchestrator Phase 1 short-circuits per-topic against `.uberdev/research/issue-<N>/` (mirrors brainstorm). Spec-reviewer is always-on for medium AND large; `--paranoid` deprecated as a no-op. New Phase 4.5 dispatches `plan-reviewer` (1-retry, non-blocking). New Phase 5.5 runs `pr-test-analyzer` pre-merge for large tier.
- **`uberdev:post-impl-review` skill** — 5-agent advisory fanout (`code-reviewer`, `simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`) in a single message. Invoked by `/solve` trivial/small inline prompts AND by `subagent-driven-dev` after each wave.
- **Non-blocking `/turbo` Q&A.** Orchestrator Phase 2 under `--turbo` auto-picks each clarifying answer using research-bundle synthesis and writes `questions.md`. `finish-branch` Option 2 reads it and appends `## Open questions answered by /turbo` (Question | Choice | Confidence) plus `## Reviewer findings summary` to the PR body.
- New agent definitions: `agents/research-security.md`, `agents/research-test-coverage.md`.
- Tests: `tests/post-impl-review.test.sh` (10/10 — frontmatter, 5 reviewer agent names, single-message invariant, both call-site refs, anti-loop guard); `tests/issue-causal-fanout.test.sh` extended to 39/39 (8 new 8-agent assertions + 1 new `--no-explore` 4-agent assertion); `tests/turbo-flow.test.sh` extended to 19/19 (9 new always-on-reviewer assertions).

### Changed
- **`--paranoid` flag is now a no-op.** Spec-reviewer runs unconditionally for medium and large tiers. Old `tier == medium AND --paranoid` gate prose removed from orchestrator; deprecation prose retained for two flag mentions.
- `brainstorm` step 2 short-circuit pattern relaxed to match generic loop variable naming used by orchestrator artifact-reuse.

### Backwards compatibility
- `--paranoid` still parses without error (deprecated no-op) — pre-v0.9 invocations continue to run.
- Issues created before v0.9.0 retain a 4-agent fanout fallthrough when no `## Current ecosystem` / `## Constraints` sections are present in the body.

Closes #11.

## [0.8.0] - 2026-04-29

### Added
- **`/uberdev:issue` deep root-cause research fanout.** Phase 2 now dispatches a 2-agent parallel fanout (`research-codebase` + `research-patterns`) when `NO_EXPLORE=0`, in the same single message as the existing Phase 3 (Duplicate Search) and Phase 4 (Label/Scope Validation) Task() calls — four agents fan out together, Phase 4.5 aggregates all four returns. Research summaries write to `.uberdev/research/run-<RUN_ID>/` and rename to `.uberdev/research/issue-<ISSUE_NUM>/` after `gh issue create`.
- **Bug-template `## Likely root cause` is now a causal triple** — `**Symptom:**` (observable failure), `**Mechanism:**` (specific code/data path), `**Owning code:**` (path/symbol — the assumption to challenge). Optional 5 Whys nested chain for non-trivial bugs. Replaces the previous file-list placeholder.
- **`/uberdev:brainstorm` short-circuit on `.uberdev/research/issue-<N>/`.** When invoked downstream of `/issue` for the same issue number, brainstorm reads the persisted summaries instead of re-dispatching equivalent research agents. Per-topic skip (codebase + in-repo prior art only — external prior art still dispatches); mtime-based staleness fallback; clean fallthrough for issues created before this change.
- **Body authoring rules subsection in `issue.md`** — codifies the WHAT/HOW boundary ahead of the templates: issue body says what is broken or wanted, never how to fix it. Implementation strategy is `/uberdev:brainstorm`'s job.
- **`tests/issue-causal-fanout.test.sh`** — structural-assertion test (modelled on `tests/turbo-flow.test.sh`) locking the contract invariants: Phase 1.5 RUN_ID/SUMMARY_DIR, Phase 2 4-agent single-message fanout, `--no-explore` placeholder verbatim, causal triple labels, feat template rename invariant, Phase 7 artifact-binding rename, brainstorm short-circuit + per-topic skip + stale-check + backwards-compat fallthrough.
- **RFC:** `docs/rfc/2026-04-29-issue-deep-root-cause-research-fanout.md` records the why (2-agent rather than 4-agent fanout, stable artifact directory rather than return-value handoff, triple rather than freeform causal essay, field rename rather than rules-text reminder) and rejected alternatives.

### Changed
- **Feat-template field rename:** `## Proposed approach` → `## What changes`. Field-name pressure replaces rules-text pressure for keeping implementation strategy out of the issue body. Downstream parsers (`/solve`, `/turbo`, `/orchestrator`) read only `**Triage hint:**` from the body, so the rename is contract-preserving.
- **Phase 4.5 aggregate** in `issue.md` extended to reconcile two new research returns (`codebase.md` drives the bug-template triple and `## Likely area`; `patterns.md` drives the `## Related` prior-pattern bullets and informs the causal chain when prior bugs exist).
- **Rules subsection** in `issue.md` gains a WHAT/HOW boundary bullet: issue body never contains an implementation checklist or fix design.

### Backwards compatibility
- No breaking change to issue-body parsing. `**Triage hint:**`, severity checkboxes, label format, and conventional-commit titles all preserved verbatim.
- Issues created before v0.8.0 have no `.uberdev/research/issue-<N>/` directory; brainstorm's short-circuit `[ -d ... ]` check returns false and falls through cleanly to the existing parallel-dispatch path. No data migration.

Closes #9.

## [0.7.1] - 2026-04-29

### Fixed
- `/turbo` unattended chain now propagates `--turbo` end-to-end through every handoff (`brainstorm` → `write-plan` → `subagent-driven-dev` → `finish-branch`). PR #8 closed issue #5 architecturally by making `write-plan` non-interactive, but `finish-branch` was still prompting at the chain tail because none of the downstream skills forwarded `--turbo`. `finish-branch` now auto-selects "Push and Create PR" under `--turbo` and announces the auto-selection.
- `orchestrator` Phase 5 forwards `--turbo` to `subagent-driven-dev` — closes the medium/large `/turbo` gap PR #8 introduced (`/turbo` for medium/large tier routes through `/uberdev:orchestrator --turbo`, but Phase 5 was invoking `subagent-driven-dev` without forwarding the flag, so the chain still stalled at `finish-branch`).
- `finish-branch` Step 5 cleanup behavior reconciled with the file's own Quick Reference table and Red Flags section: cleanup runs only for Options 1 (Merge locally) and 4 (Discard). Option 2 (Push and create PR) leaves the worktree alive for PR-feedback fixups; Option 3 (Keep as-is) is explicit. Pre-existing contradiction surfaced as a live runtime bug under `/turbo` — unattended runs auto-route to Option 2.

### Added
- `tests/turbo-flow.test.sh` — 9 contract assertions locking the `--turbo` propagation contract at every handoff (`brainstorm`, `write-plan`, `subagent-driven-dev`, `finish-branch`, plus `orchestrator` Phase 5 and the `/turbo` command entry point). Default-mode regression canaries also included so future edits can't silently break the non-`--turbo` paths.

## [0.7.0] - 2026-04-28

### Added
- `/uberdev:orchestrator` skill — writer-subagent pipeline used by `/solve` and `/turbo` for medium/large tier issues. Drives 5 phases: research fanout (parallel Sonnet subagents) → optional Q&A (skipped for `/turbo`) → spec-writer (Opus) → optional spec-reviewer (Opus, gated by `--paranoid` for medium tier; always for large tier) → plan-writer (Opus, with internal research fanout) → existing `subagent-driven-dev`. Each writer returns a structured YAML summary; orchestrator main holds pointers, not raw artifacts. Reclaims spawned-agent context for wave dispatch and error recovery.
- 8 new agent definitions: `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints` (Sonnet); `spec-writer`, `spec-reviewer`, `spec-reviser`, `plan-writer` (Opus). Each is invokable via Task() dispatch with a strict universal return contract.
- `--paranoid` flag on `/uberdev:orchestrator` enables spec-reviewer for medium tier issues.

### Changed
- `/solve` and `/turbo` medium/large tier prompts now invoke `/uberdev:orchestrator` instead of `/uberdev:brainstorm` directly. Trivial and small tier paths unchanged. `--turbo` flag now propagates as `/uberdev:orchestrator --turbo …`.
- `brainstorm` skill: added a note acknowledging `/solve` and `/turbo` route through the orchestrator skill; brainstorm itself remains the canonical reference and the right invocation for ad-hoc design work.
- `write-plan` skill: execution handoff is now non-interactive — defaults to subagent-driven; explicit user opt-in for inline. Resolves the `/turbo` unattended-flow break (issue #5).

### Fixed
- `/turbo` no longer halts on a "Subagent-Driven vs. Inline Execution?" prompt during plan handoff. Closes #5 (architecturally, via the writer-subagent refactor in #6).

## [0.6.0] - 2026-04-28

### Added
- `/solve` Ghostty dispatcher tab-spawns into the originating Ghostty window when invoked from inside Ghostty (`TERM_PROGRAM=ghostty`), keeping per-project workspaces visually grouped instead of cluttering the desktop with new top-level windows. `SOLVE_GHOSTTY_NEW_WINDOW=1` forces the legacy new-window behavior; AppleScript failures (e.g. Accessibility permission denied) fall back to it automatically with a stderr warning.
- `/turbo <issue>` slash command: unattended `/solve` that auto-accepts the brainstorm phase's lead-agent recommendations for medium/large tiers (parallel research still runs — recommendation grounding preserved). Trivial/small tiers behave identically to `/solve`. Composes orthogonally with `--auto` (permission-mode flag); `/turbo <issue> --auto` is the max-autonomy combo. No new approval gates — only collapses the clarifying-questions loop. `/turbo` also gains the same Ghostty tab-spawn behavior as `/solve`.
- `/solve --auto` (and `/turbo --auto`) flag: enables Claude Code's `--permission-mode auto` classifier in the spawned agent. Auto-approves low-risk ops (file edits, reads, package installs) and blocks high-risk ones (force push, `rm -rf` on pre-existing files, exfil, self-modification, `--dangerously-skip-permissions`). Resolves from CLI flag → `SOLVE_AUTO=1` env → `solve_auto: true` in `.claude/uberdev.local.md`. `/turbo <issue> --auto` is the max-autonomy combo.

### Changed
- `brainstorm` skill: parallel research dispatch promoted to **default first step** (before clarifying questions; skipped only for trivial tasks). The 2-3 proposed approaches are now grounded in research synthesis, not speculation. No approval gates added — "single forward pass" stays.

### Removed
- Deprecated slash-command shims `/uberdev:brainstorm`, `/uberdev:execute-plan`, `/uberdev:write-plan` removed. They were Superpowers-port leftovers redirecting to the canonical skills of the same name; invoke the skills directly via the Skill tool instead.

## [0.5.0] - 2026-04-28

### Added
- `SessionEnd` hook: best-effort cleanup of `~/.claude/.uberdev-answers`, `/tmp/uberdev-*` (plugin-prefixed only), and brainstorm event files older than 24h.
- `PreCompact` hook: append `.claude/auto-memory.md` to `.claude/session-archive.md` before compaction wipes context (silent no-op when absent; refuses to write through a symlinked `.claude/`).
- `.claude/uberdev.local.md` per-project configuration (YAML frontmatter for tier, review depth, terminal, parallel toggle); env vars override file settings.
- `AskUserQuestion` fast-path in `brainstorm` skill for discrete direction selection (2-5 options) without spinning up the visual companion. Visual companion remains the primary path for full design exploration.
- `isolation: "worktree"` guidance in `subagent-driven-dev` skill — Pattern B's controller-only-git approach is the documented opt-out; everything else defaults to worktree isolation.
- YAML frontmatter (`description`, `argument-hint`, `allowed-tools`) on `/issue` and `/solve` — were previously missing, leaving the picker with empty descriptions and triggering permission prompts on every `gh`/`find`/`osascript` call.
- `CONTRIBUTING.md` (contributor onboarding: quick start, repo layout, conventional commits, branch naming, PR expectations, `/simplify` mandate).
- `CHANGELOG.md` (Keep-a-Changelog 1.1.0 format covering v0.2.0 → v0.5.0).

### Changed
- 5 detail-oriented agents (`comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `plan-reviewer`, `type-design-analyzer`) switched from `model: inherit` to `model: haiku`. Since `/uberdev:review-pr` dispatches all 7 agents in parallel and is bound by the slowest, switching the detail agents to Haiku 4.5 cuts wall-time ~15-20%.
- `code-simplifier` agent rules made stack-agnostic — was hardcoding JS/React conventions (ES modules, `function` keyword, React Props types); now defers to project CLAUDE.md / style guide and language-agnostic clarity rules.
- `plugin.json` description trimmed from ~1.4 KB to one impactful sentence (marketplace listing aesthetics).
- `/uberdev:simplify` `allowed-tools` gains `Edit`, `Write`, `MultiEdit` (was hitting permission prompts on every fix attempt).
- `/uberdev:review-pr` `allowed-tools` narrows `Bash` to `Bash(git*)`, `Bash(gh*)` (read-only command).

### Fixed
- **Critical:** v0.4.0's `/issue` Phase 2/3/4 parallel fanout was silently broken — subagents have no shell context, so `$REPO`/`$DESC`/`$KEYWORDS`/`$COMMITLINT` references in agent briefs didn't resolve. Now resolves in orchestrator bash and bakes literal values into each agent brief.
- **Security (RCE):** `/solve` no longer passes `--dangerously-skip-permissions` to the autonomous agent. A malicious GitHub issue body could otherwise have executed under the user's account; the spawned agent now runs in an interactive terminal where the user gates each permission.
- **Security (prompt-injection):** `inject-brainstorm-answers` hook validates each event line as JSON via `jq`, HTML-escapes `<`/`>`, and refuses symlinked event paths. Closes a vector where any process in the cwd could plant arbitrary closing tags + instructions in the next user turn.
- `session-start` hook replaces fragile manual `escape_for_json` + `printf '%s'` interpolation with `jq -Rs`-style construction. Handles control bytes 0x00-0x1f and stray `%` format-spec collisions that previously corrupted output.
- `pre-compact` hook now refuses to write through a symlinked `.claude/` directory (`[ -d ]` follows symlinks; explicit `[ ! -L ]` guard added).
- Cross-platform `sed -i` in `/solve` — was BSD-only `-i ''` (broke on Linux with `sed: can't read : No such file`); now detects platform via `uname` and uses correct syntax on macOS + Linux.
- `session-start` no longer captures stderr into the SKILL.md content variable (`2>&1` → `2>/dev/null`); a missing skill file now degrades to empty injection rather than appearing as `Error reading…` content.

### Performance
- `inject-brainstorm-answers` per-line `jq -e -c .` fork loop collapsed to a single streaming `jq -R 'fromjson? // empty'` call. Saves ~200-500ms per UserPromptSubmit on active brainstorm sessions (50+ events).
- Two filesystem walks in `inject-brainstorm-answers` (blanket symlink scan + events-file `find`) folded into one targeted walk.

## [0.4.0] - 2026-04-28

### Added
- Parallel-fanout orchestration spread across the plugin: `/uberdev:review-pr` flips its default from sequential to **parallel** (all applicable review agents dispatch concurrently in a single turn).
- `/uberdev:issue` Phase 2/3/4 (codebase investigation + duplicate search + label/scope validation) runs as three parallel agents — roughly 60-70% wall-time savings.
- `systematic-debugging` skill gains **competing-hypothesis fanout** — read-only investigators per hypothesis, no anchoring on the first guess.
- `brainstorm` skill gains optional parallel design-direction exploration for high-stakes designs.
- `write-plan` skill gains opt-in alternative-plan generation (3 decomposition strategies).
- `receiving-code-review` skill adds multi-reviewer parallel triage.

### Changed
- `verification-before-completion` skill documents parallel verification dispatch (independent test/lint/build/typecheck checks running concurrently).
- Documented the parallel-default as a deliberate divergence from upstream `pr-review-toolkit`.

## [0.3.1] - 2026-04-28

### Changed
- `/uberdev:simplify` realigned with Anthropic's built-in `/simplify`: three-parallel-agent orchestrator — Code Reuse, Code Quality, and Efficiency reviewers fan out concurrently in a single Task-tool turn; controller aggregates findings and fixes them.
- Iron rule preserved (no behavior changes), plus UberDev's separate `refactor:` commit mandate.

### Fixed
- Restored proactive-trigger examples in the `code-simplifier` agent that were dropped during the orchestrator refactor.

## [0.3.0] - 2026-04-28

### Added
- Full Superpowers parity port: `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `dispatching-parallel-agents`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `writing-skills`, `using-uberdev` skills.
- Brainstorm Visual Companion: Neo Brutalism UI served by a local server, with `frame-template.html`; sessions persist to `.uberdev/brainstorm/`.
- `SessionStart` hook that injects the `using-uberdev` primer at conversation start so Claude knows how to discover plugin skills.

## [0.2.1] - 2026-04-27

### Added
- Wave-based parallel execution (Pattern B) in `/solve` and `/uberdev:subagent-driven-dev`: every task in a wave dispatches in parallel; waves run sequentially.
- `uberdev:write-plan` requires three new headers per task (`Depends on:`, `Wave:`, `Owns:`) and an `## Execution Waves` summary so dependencies and file ownership are explicit.

### Changed
- One shared feature-branch worktree across all waves — no per-task worktree, no merge step between waves.
- Controller (not implementers) runs `git add` / `git commit` to eliminate `.git/index.lock` races. Implementers report changed paths instead.

## [0.2.0] - 2026-04-27

### Added
- Initial public release of the UberDev marketplace and `uberdev` plugin.
- `/solve <issue-number>`: spawns an autonomous Claude agent in a new terminal session (cmux / Ghostty / iTerm / Terminal.app / nohup) with tier-aware triage — trivial issues skip the brainstorm; large ones get the full plan-and-review pipeline.
- `/issue <description>`: eight-phase pipeline that creates a well-investigated, deduped, label-validated GitHub issue, including codebase search, full-text dedup against closed issues, commitlint scope validation, and a triage hint that `/solve` reads later.
- Bundled skills: `brainstorm`, `write-plan`, `execute-plan`, `subagent-driven-dev`, `finish-branch` — `/solve` runs standalone with no Superpowers / pr-review-toolkit / code-simplifier dependency.
- Bundled review agents: `code-reviewer`, `code-simplifier`, `comment-analyzer`, `plan-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`.
- Bundled commands: `/uberdev:review-pr`, `/uberdev:simplify`.

### Changed
- Documentation: README expanded with `Updating` section explaining manual vs auto-update for third-party marketplaces (`docs:` commit `007537b` on 2026-04-27 superseded by this release).

[unreleased]: https://github.com/TheFJK/UberDev/compare/v0.16.0...HEAD
[0.16.0]: https://github.com/TheFJK/UberDev/compare/v0.15.2...v0.16.0
[0.9.0]: https://github.com/TheFJK/UberDev/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/TheFJK/UberDev/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/TheFJK/UberDev/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/TheFJK/UberDev/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/TheFJK/UberDev/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/TheFJK/UberDev/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TheFJK/UberDev/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/TheFJK/UberDev/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TheFJK/UberDev/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/TheFJK/UberDev/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/TheFJK/UberDev/releases/tag/v0.2.0
