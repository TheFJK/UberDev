# RFC 0017 — the Phase 1 finding-verification gate

- **Status:** Accepted — implemented across `plugins/uberdev/{agents,shared,lib,policy,skills,commands}`
- **Issue:** #431. Blocks #433 (a convention-compliance lens must not ship before a filter exists); feeds #432 (the eval harness measures what this gate filters).
- **Supersedes:** nothing. **Superseded by:** nothing.

**Reference convention (normative for this RFC, inherited from RFC 0016):**
every reference below is a *symbol* — a function, constant, file or contract
name — never a `file:line` literal.

---

## 1. Context

`/review-pr` Phase 1 fans out six reviewer lenses and forwards **every** finding
straight into Phase 2.5 `findings-to-issues`. There was no verification pass
between detection and persistence.

The cost of a false positive is not symmetric with upstream's. Anthropic's
official `code-review` plugin turns a false positive into a PR comment a human
ignores. UberDev turns it into a durable, fingerprint-deduped GitHub issue —
which then becomes a `/goal` recursion target, and then possibly a code change
made to fix a bug that never existed. Precision is the axis that decides whether
unattended issue-to-merge is usable at all.

It also settles a stated design debt. UberDev rejects superpowers' HARD-GATE
approval checkpoints on the grounds that *review depth beats approval ceremony*.
That holds only if the review filters. The human gate is gone; nothing
precision-related had replaced it.

---

## 2. The verifier agent

`agents/finding-verifier.md`, `model: inherit`, dispatched once per eligible
Phase 1 finding on the new edge `review_pr.verify.finding`, each in **fresh
context**. It receives the claim, the diff, the PR title/description, the
project guidelines, and the rubric. It returns a 0–100 score and a reason token.
It applies no threshold and reaches no verdict.

**Eligible** is `severity == "blocker" AND disposition != "APPLIED"`, declared
once in `_eligible_verification_rows` and read by both verification verbs. A
suggestion never becomes a tier the `/goal` loop recurses on, and an APPLIED
blocker is already fixed in the branch — neither is worth a verifier.

### 2.1 What the child does not get, and how

The claim card `project_verification_claims` writes carries exactly
`{finding_index, location, summary}` — `CLAIM_KEYS`, asserted equal to that set.
The reviewer's `detail` field, where the argument and the reviewer's own
`confidence: <n> — ` prefix live, is **not withheld by instruction; it is
absent from the bytes**. `tests/code-fixer-contract.test.sh` proves it on the
concatenated card bytes: neither the confidence prefix, nor the reasoning
string, nor any `source_edges` value appears.

Everything else — the aggregate, the disposition, other verifiers' results — is
prompt-level withholding, and the agent file and the dispatch prompt both say so
honestly rather than implying a guarantee the design does not make. §7 records
that limit.

---

## 3. The rubric SSOT

`shared/finding-confidence-rubric-v1.md` declares the 0–100 scale, its five
anchors, and the ~9-item false-positive catalogue **once**. It is adapted from
Anthropic's official `code-review` plugin (Apache 2.0); the bundled licence text
is `plugins/uberdev/licenses/pr-review-toolkit-Apache-2.0.txt`, the rubric names
it, and `README.md`'s Bundled table lists it.

Two consumers now read the same scale for different purposes, and the file says
so explicitly rather than merging the policies:

| consumer | use |
|---|---|
| `agents/code-reviewer.md` | **reporting filter** — score your own finding, stay silent below 80, map the rest onto `blocker` / `suggestion` |
| `agents/finding-verifier.md` | **adjudication scale** — score somebody else's claim and emit the number |

`tests/post-impl-review.test.sh` pins uniqueness on the two endpoint anchors:
they appear in the SSOT and nowhere else under `plugins/`. A second copy of the
scale cannot avoid restating them. This is the #370 multi-copy-contract class,
caught the cheap way.

**Severity vocabulary.** The gate filters on the reviewer contract's
`blocker | suggestion`, before `findings-to-issues` normalizes into
`{blocker, critical, major, important}`. Normalization stays where it was.

---

## 4. The threshold config

`review.confidence_threshold` — int `[0, 100]`, default 80, env
`UBERDEV_REVIEW_THRESHOLD`, documented in `references/configuration.md`,
resolved through the existing `uberdev_read_int_in_range` precedence chain.

**It is applied entirely controller-side**, in `publish_verification`. The child
is never told it. Three reasons, in order of weight:

1. A verifier told the cutoff calibrates to it. The score stops being an opinion
   about the claim and becomes a vote about the gate.
2. Recorded scores stay re-thresholdable offline. #432's eval harness can sweep
   the cutoff over already-recorded runs without re-dispatching anything.
3. It is mechanically checkable. `tests/review-pr-workflow.test.sh` V1 asserts
   `skills/review-fleet/workflow.js` contains no threshold scalar at all, with
   an anti-vacuity companion (V1b) proving the scanned file is the one carrying
   the stage.

Making `0` a *meaningful* value forced a root-cause fix: `uberdev_read_int_in_range`
rejected a configured `0` as `non_integer` before the range check ever ran,
because its grammar was `^[1-9][0-9]*$`. Three shipped keys already declared
`min=0` (`goal.watch_passes`, `goal.watch_budget`, `uberthink.loop_back_cap`),
so all three silently returned their defaults and blamed the wrong thing in the
warning. The grammar is now `^(0|[1-9][0-9]*)$` — whether `0` is *allowed* is
the range check's job, not the grammar's. Leading-zero rejection is preserved.

---

## 5. The culled-findings artifact

`.uberdev/research/<RUN_ID>/phase1-verification.json`, a **sibling of
`phase1-disposition.json`** under an exact basename that `publish_verification`
enforces:

```json
{"schema_version":1,"phase":"phase1","aggregate_sha256":"<hex>","threshold":80,
 "findings_verification":[
   {"finding_index":1,"location":"src/a.py:42","summary_sha256":"<hex>",
    "score":93,"verdict":"SURVIVES","reason":"reproduced-from-diff"}]}
```

`score` is `null` on any row no child scored, and the reason names why.

### 5.1 Why not `.uberdev/runs/<run-id>/culled.jsonl` (the issue's suggestion)

Three independent reasons, any one of which is sufficient:

1. `.uberdev/runs/` is the **reservation** directory whose `locked` marker
   `/goal` Phase 2b polls and `/status` discovers. Writing review artifacts
   there overloads a directory whose meaning is "a run is holding this slot".
2. `agents/findings-to-issues.md` refuses any aggregate path not beneath
   `.uberdev/research/`. A sidecar the consumer cannot bind is not a sidecar.
3. A `.jsonl` stream cannot carry the `aggregate_sha256` digest that makes the
   binding forgery-resistant. The sidecar is bound the same way the disposition
   is: canonical parent, exact basename, `lstat`-proved regular file with link
   count 1, digest equality against the already-read aggregate bytes, triple
   match per row, and an identity re-check immediately before the first GitHub
   write.

### 5.2 Fail toward keeping

Only a well-formed score **strictly below** the threshold ever culls. Three arms
land `SURVIVES` instead, each with its own reason so the artifact says which
happened:

| situation | reason | verdict |
|---|---|---|
| threshold is `0` | `gate-disabled` | `SURVIVES` |
| roster longer than `REVIEW_FLEET_VERIFY_TOTAL_CAP` | `over-cap-unverified` | `SURVIVES` |
| child blocked, timed out, or returned a malformed document | `verifier-unavailable` | `SURVIVES` |

At threshold `0` **no verifier agent is dispatched at all** — the controller
short-circuits before the Workflow call. Above the cap the surplus rows are
neither dispatched nor dropped: a gate that aborted on a large finding set would
make a bad review un-reviewable, and one that dropped rows would cull without
saying so.

---

## 6. The `/goal` interaction — satisfied by not filing

`lib/goal-phase3.sh` selects recursion targets by the `review-pr-finding` label
plus a `**Tier:** (BLOCKER|CRITICAL)` body regex. A row that is never filed
carries neither. **No `/goal` code changes**, and the all-culled case is proved
directly: `findings-to-issues` returns `status: DONE`, empty arrays,
`halted: false`, and performs **zero** GitHub writes — no label create, no
issue, no comment — exactly as a `findings: []` input does.

---

## 7. Trust-trail asymmetry, chosen explicitly

Culling a blocker can flip a run RED → GREEN. That direction is intended: a
false-positive blocker that keeps a run RED hard-fails `/merge` and blocks the
PR forever, which is the failure mode this gate exists to end.

The design buys **observability**, not a free direction. Every cull is named
three times: in the sidecar, in a `review_finding_verified` row on the repo-root
`.uberdev/audit.jsonl`, and in the additive
`phases.phase2_5.verification: {threshold, verified, culled}` block that
`trust-trail-evaluator` and a human both read. No existing `phase2_5` field
changes shape.

---

## 8. Known limits — stated, not hidden

1. **The withholding is mechanical only for the claim card.** The verifier has
   file tools and could in principle read `post-impl-review-final.md`. The card
   guarantees the reasoning is not *handed* to it; the rest is a prompt rule,
   and both the agent file and the dispatch prompt say so.
2. **`validate_persistence_result` compares across phases.** It enforces
   `expected_deferred_blockers == by_severity_blocker + skipped_blockers`, where
   the left side is Phase-2-derived (`count_deferred_blockers` hardcodes a
   `simplify-aggregate` envelope and `phase2` validation on both axes) and
   `by_severity.blocker` counts rows written across both phases. The equality is
   therefore already unsound for any run that files a Phase 1 blocker; #427
   (`/review-pr` unrunnable end-to-end) is why nobody has observed it. This gate
   moves the right-hand side. **Pre-existing, out of scope here, followed up in
   #453** (and the Phase-2-only `count_deferred_blockers` in #452).
   The spec's proposal to bind the verification sidecar into
   `count_deferred_blockers` was CUT for the same reason: that function cannot
   parse a Phase 1 pair at all.
3. **Green CI proves the wiring, not the filtering.** The suite proves the stage
   dispatches, the sidecar binds, the threshold reads, the cap refuses by name,
   and a culled row is never filed. It does **not** prove the gate filters a real
   false positive. #427 is OPEN, so no end-to-end live run is observable yet;
   #429 is CLOSED (v0.45.3). Behavioural evidence is #432's eval harness.

---

## 9. Deferred

- **Model tiering / a cheap verifier.** Unreachable: naming a concrete route
  fails `route_unenforceable` since #381, and RFC 0012 §5 made every agent
  `model: inherit`. Needs a new mechanism, not a config knob.
- **"N `/goal` cycles with no resolving change → auto-relabel
  probable-false-positive."** Needs new persistent per-fingerprint state plus a
  new label, overlaps `uberdev_goal_check_fingerprint_repeat`, and must not
  become a tenth member of the `CONTRACT:`-marked nine-member
  `GOAL_CIRCUIT_BREAKER_REASONS` enum.
- **Extending the gate to the Phase 1 fixer authority** — blocked by the
  `strict=True` zips in `_validate_disposition`.
- **Phase 2 findings**, **new reviewer lenses** (a seventh lens has lower
  marginal value than a verifier and negative value without one), the dead
  `REJECTED` arm in `route_by_severity` (#454 — shipped; the arm is deleted and
  the helper's inbound domain is pinned against the producer enum, see RFC
  0002's #454 amendment), and reconciling the three pre-existing confidence
  vocabularies.
- **`tests/config-override.test.sh`'s vacuous `[ $? -eq 0 ]` assertions** (#455).
  `_isolate` ends in `rm -rf`, so the exit-status half of ~20 existing
  assertions cannot fail. The cases this RFC's work added use a falsifiable
  stderr-marker form instead and say why in a comment; fixing the class is its
  own change.
- **Republishing `prkit`.** The verify edge, the verifier agent, the rubric and
  the verifier contract all entered `tools/prkit/manifest.txt` (38 -> 41 files),
  and `tools/prkit/published.json` records the bytes they will be published
  with. `TheFJK/prkit` must be regenerated and repushed before its register
  describes a shipped tree.
- **Marking the eight `reason` tokens with `CONTRACT:`.** They split into a
  child set and a controller set at their Python declaration, which the RFC 0016
  extractor reads as two competing vocabularies in one region and — correctly —
  refuses to guess about. Only the two-member `verdict` vocabulary is marked;
  the reason vocabulary is held by executable equality asserts in
  `tests/code-fixer-contract.test.sh` and `tests/child-dispatch.test.sh`.
