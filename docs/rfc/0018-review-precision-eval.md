# RFC 0018 — Measuring per-lens reviewer precision from the finding corpus

- **Status:** Accepted — implemented in `tools/eval/review-precision.py`,
  `tests/review-precision.test.sh`, and the meta trailer in
  `agents/findings-to-issues.md`.
- **Issue:** #432. Related: #431 (per-finding confidence gate — unlanded; §7
  pins the seam it consumes).
- **Supersedes:** nothing. **Superseded by:** nothing.

**Reference convention (normative for this RFC):** every reference below is a
*symbol* — a function, constant, file, label or contract name — never a
`file:line` literal. Line numbers rot inside one release; symbols are greppable.

---

## 1. Context and root cause

A confidence threshold is a guess until somebody measures the precision behind
it. `/uberdev:review-pr` dispatches six Phase-1 reviewer lenses and three
Phase-2 simplify lenses, and every deferred finding is already persisted as a
fingerprinted GitHub issue by `findings-to-issues` under the
`review-pr-finding` label. That issue history looks like a labelled dataset
accruing for free.

It is not one. **The finding pipeline is write-only with respect to both
quantities a precision number needs**, and each is knowable at exactly one
moment and recorded at neither:

| Quantity | Knowable at | Recorded |
|---|---|---|
| *Which lens produced this finding* | dispatch — `source_edges` is in the run aggregate | nowhere durable. The issue body renders `**Agent:**`, a **display-only** string derived for humans; nothing machine-readable survives. |
| *Whether the finding was real* | close — the human who closed the issue knew | nowhere. GitHub records `stateReason ∈ {COMPLETED, NOT_PLANNED}`, which is a workflow fact, not a correctness verdict. |

The live corpus at the time of writing (`gh issue list --label
review-pr-finding --state all`, 2026-08-10) makes the gap concrete:

- **38** issues, **all closed** — 37 `COMPLETED`, 1 `NOT_PLANNED`, closed
  between 2026-05-21 and 2026-05-29.
- **Zero** carry any correctness verdict: `gh label list` has no `finding:*`
  label at all, and neither `invalid` nor `wontfix` has ever been applied.
- **3** bodies carry no `**Agent:**` line whatsoever.
- The `**Agent:**` histogram is prose, not an enum:
  `pr-test-analyzer 16 · silent-failure-hunter 7 · code-simplifier-quality 2 ·
  code-simplifier-reuse 2 · code-simplifier-efficiency 1 ·
  "code-reviewer-correctness + code-reviewer-general (corroborated)" 2 ·
  code-reviewer 2 · code-reviewer-correctness 1 · comment-analyzer 1 ·
  "simplify-lens (code-simplifier quality lens)" 1`.
  Six of those rows are Phase-2 simplify lenses mixed into the same label.
  `type-design-analyzer` appears **zero** times — from this data it is
  indistinguishable from a lens that has never fired and a lens whose rows were
  merged away.

So the honest ruling is: **there is no labelled dataset today, and no amount of
mining creates one.** The deliverable of #432 is therefore *instrumentation
first* — start recording the two missing facts at the two moments they are
knowable — plus the miner, the report and the gate that consume them. The first
published table is `insufficient-data` in every cell, and **that is the correct
output**, not a failure of the harness.

### 1.1 Two rejected shortcuts

- **A1 — infer the lens from the `**Agent:**` prose.** Rejected. The histogram
  above shows free text, corroborated multi-lens strings, and a Phase-2 lens
  described two different ways. `findings-to-issues` states normatively that
  `summary`/`detail` are context-only and never contributor authority; parsing
  a rendered display string re-introduces exactly the inference the agent
  forbids.
- **A2 — treat `closed as COMPLETED` as a true positive.** Rejected, and this
  is the load-bearing rejection. `COMPLETED` means *the issue was closed by
  someone who considered it done*. It is applied to findings that were fixed,
  findings that were obsoleted by an unrelated refactor, findings closed in a
  queue sweep, and findings the closer judged wrong but did not want to argue
  about. Precision computed on that signal measures issue hygiene, not reviewer
  quality — and it would publish a number near 1.0, which is precisely the kind
  of unearned claim this RFC exists to stop.

---

## 2. The meta trailer (provenance, recorded at dispatch)

`findings-to-issues` emits one additional HTML comment as the line
**immediately after** the existing fingerprint marker in the issue body:

```text
<!-- uberdev:{finding_marker_slug}-finding fingerprint={16-char-hex} -->
<!-- uberdev-finding-meta v=1 slug={finding_marker_slug} edges={comma-joined edges} severity={severity} tier={BLOCKER|CRITICAL|MAJOR} -->
```

Normative rules:

1. **`edges=` is the contributor-ordered union of the kept row's
   `source_edges` and the `source_edges` of every row merged into it by the
   cross-contributor dedupe step** — i.e. exactly the set the body already
   renders as `**Agent:**` plus `**Also flagged by:**`. Comma-joined, no
   spaces.
2. For the explicitly discriminated legacy fleet variants (`legacy.uberscan`,
   `legacy.ubersimplify`, `legacy.testers`, `legacy.uberthink`) there is no
   `source_edges` array; use the variant's own **validated** `lens` /
   `agent_name` column.
3. When neither exists, emit `edges=` with an empty value. An empty `edges=` is
   a legitimate, recorded state — never a reason to guess.
4. `edges` is **never** derived from `summary` or `detail`. That prohibition is
   the same one the agent already applies to contributor identity.
5. The trailer is the **machine authority**; `**Agent:**` stays display-only.
   The two are allowed to disagree, and neither is derived from the other. A
   disagreement is a rendering bug, not a data-loss event: the trailer wins.
6. `conf=` is **reserved and not emitted**. A per-finding numeric confidence is
   #431's design surface; adding it here would change the exact finding key set
   that `post-impl-review` and `findings-to-issues` both lock, and red their
   key-set tests for no measurement benefit.
7. The trailer changes **nothing** about the fingerprint: not the marker
   template, not the `sha256(path:line:normalised_summary)` recipe, not the
   16-hex truncation, not the fail-CLOSED dedupe lookup, not `MAX_NEW=10`.

### 2.1 Forgery

The existing refusal (`finding-contains-fingerprint-marker`) that blocks a
finding whose text embeds the fingerprint marker is extended to name the second
literal `<!-- uberdev-finding-meta` as well. Both the sanitiser step and the
per-row refusal carve-out check both literals. Without this, attacker-controlled
finding prose could forge a lens attribution — the harness would then publish a
precision number for a lens that never ran.

The same reasoning bans raw issue bodies from the committed corpus (§4).

---

## 3. Verdict labels (ground truth, recorded at close)

Two labels are provisioned by `findings-to-issues`, alongside the existing
`review-pr-finding` provisioning, in the same fail-soft block:

| Label | Colour | Meaning |
|---|---|---|
| `finding:true-positive` | `0e8a16` | The finding described a real defect. |
| `finding:false-positive` | `b60205` | The finding was wrong, or described a non-defect. |

Both descriptions are under the 100-character GitHub limit (measured: 77 and
75). The core rate-limit floor already funds three `gh label create` calls with
headroom.

The `To resolve:` footer of every filed issue asks the closer to apply one of
the two before closing. That is the entire ground-truth mechanism: a human
judgement, recorded once, at the only moment it is cheap.

### 3.1 The adjudication ladder

`classify(row, now)` is a **first-match-wins** ladder, total and disjoint over
every corpus row:

| # | Condition | Class |
|---|---|---|
| 1 | carries **both** verdict labels | `conflicted` |
| 2 | carries `finding:true-positive` | `true-positive` |
| 3 | carries `finding:false-positive` | `false-positive` |
| 4 | open, and `created_at` is within `STALE_DAYS` of `now` | `pending` |
| 5 | open, and older than `STALE_DAYS` | `stale-open` |
| 6 | otherwise (closed, no verdict label) | `unadjudicated` |

Only rows 2 and 3 are `adjudicated`. Ruling, restated because it is the whole
point: **`COMPLETED` alone is not evidence of a true positive**, and a closed
unlabelled row is `unadjudicated`, never `true-positive`.

`NOT_PLANNED → false-positive` is *also* rejected as an automatic mapping, for
the mirror reason: an issue can be closed as not-planned because it was
correct-but-deferred. `stateReason` is carried through into the corpus and the
report publishes raw `tp`, `fp` and `not_planned` counts beside every ratio, so
a reader who disagrees with the ladder can recompute.

### 3.2 Quarantine

Every row carries `attribution_source ∈ {trailer, agent-line, none}`.

- **Only `trailer` rows enter the headline table.** They are the rows whose
  lens attribution is machine-recorded rather than reverse-engineered.
- `agent-line` and `none` rows are rendered in a separate
  **pre-instrumentation (low confidence)** section with an explicit caveat, and
  are excluded from every published ratio and from the ratchet.

Consequence, stated so nobody mistakes it for a bug: on the day this lands, all
38 corpus rows are `agent-line` or `none`, every headline lens has `n=0`, and
the published table reads `insufficient-data (n=0)` in all six cells.

### 3.3 Publication and threshold floors

- `MIN_N_PUBLISH = 20` — below this a lens publishes `insufficient-data (n=K)`,
  never a ratio. A precision computed from a handful of points is noise wearing
  a decimal point.
- `MIN_N_THRESHOLD = 50` — below this **no** per-lens threshold is derived.
  A threshold from noise is worse than the global default, because it looks
  authoritative.
- Published cells render `p (95% CI lo–hi, n=K)` using a Wilson score interval
  with `Z = 1.96`. Wilson rather than normal-approximation because the counts
  are small and the proportions will sit near the boundaries, where the normal
  interval leaves the unit range.

---

## 4. The corpus, the report, and what is never committed

| Artifact | Path | Role |
|---|---|---|
| Corpus | `tools/eval/corpus.json` | Extracted fields only, schema v1. Regenerated by `--refresh`. |
| Baseline | `tools/eval/precision-baseline.json` | Per-lens counts, plus two prompt-surface digest maps with distinct roles: `prompt_digests` holds the bytes the numbers were measured against; `unmeasured_digests` holds the CURRENT bytes of a surface the numbers were *not* measured against, recorded only so its drift stays visible. |
| Report | `docs/eval/review-precision.md` | Deterministic render of corpus + baseline. |

**A raw issue body is NEVER committed.** The corpus stores `number, state,
state_reason, created_at, closed_at, labels[], slug, edges[], path, line,
severity, tier, attribution_source, fingerprint` and nothing else. The reason is
§2.1's, not a secret-scanner one: a raw body can carry a **forged
`<!-- uberdev:` marker** into the tree, and the tree is read by the same dedupe
and refusal paths that must fail CLOSED. `tests/review-precision.test.sh`
asserts no committed eval artifact contains the literal `<!-- uberdev:`.

`docs/*` is git-ignored repo-wide; `docs/eval/` is un-ignored the same way
`docs/rfc/` already is.

---

## 5. The AC substitution, stated openly

Issue #432 asks for: *"CI gate: a PR that edits a reviewer or verifier prompt
must not regress measured precision."*

**That gate is unbuildable, and pretending otherwise would be the worst outcome
of this work.** Two independent reasons:

1. **Ground truth arrives weeks after the prompt edit.** A finding filed by the
   edited prompt gets adjudicated when a human closes the issue it produced —
   days or weeks later. At PR time there is no post-edit measurement to compare.
2. **CI cannot measure anything.** The workflow runs with `permissions:
   contents: read`, no secrets and no `gh`. It cannot query GitHub, so it cannot
   observe a precision number at all.

It is replaced by three CI-bounded properties that *are* checkable from the
committed tree alone:

- **Freshness** — `--check` re-renders the report from the committed corpus and
  requires byte equality. A stale published table is a lie; this catches it.
- **A ratchet** — an *armed* lens (`n ≥ MIN_N_PUBLISH`) fails the check when its
  new point estimate drops below the baseline point estimate **and** its new
  Wilson upper bound is also below the baseline point estimate. The second
  clause is the noise floor: a drop that the interval cannot distinguish from
  sampling noise does not red CI.
- **A prompt-digest re-affirmation stamp** — every reviewer prompt surface
  carries a sha256 in one of two fields, and drift in either fails the check.
  `prompt_digests` holds the bytes the published numbers were measured against.
  `unmeasured_digests` holds the current bytes of a surface that POSTDATES
  `measured_at`: there are no measured bytes to stamp for it, and stamping the
  current ones would assert a measurement that never happened, so what is
  recorded is the weaker, true claim — *these are the bytes that were current
  when the declaration was written*. Editing a surface without either
  re-measuring or declaring it in `pending[]` fails the check. This is the
  honest form of the requested gate: *you may change the prompt, but you must
  say so where the number lives.*

  **The surface set is derived, never enumerated.** `prompt_surfaces()` walks
  `PHASE1_CONTRIBUTORS` and maps each lens to the agent file it is dispatched
  with, then appends the shared bodies those files include by reference. So the
  lens SET is derived from the roster, and the lens→FILE map
  (`LENS_PROMPT_FILES`) is local but no longer uncompared: its agreement with
  `REVIEW_ROSTER[].agentFile` is asserted in both directions by
  `tests/review-precision.test.sh`, which extracts the roster's pairs and fails
  rather than passes when it extracts none. That comparison is what a repointed
  `agentFile:` needs — it leaves both token sets intact while the stamp watches
  a file the fleet no longer dispatches.
  `SHARED_PROMPT_SURFACES` is the one irreducible enumeration, and stays one:
  no roster names those files, because a lens's own prompt pulls them in by
  reference, so there is nothing to derive them from and nothing to compare them
  against. It is held instead to a stated rationale per entry, which is a weaker
  guarantee than a comparator and is recorded here as such rather than glossed.
  The convention lens is what an under-derived surface set looks like in
  practice: it reached the published tables while its own prompt went
  unstamped, because the stamp read a hand-written six-entry tuple. A lens
  with no mapped prompt file now fails loudly instead of being skipped, and
  `tests/review-precision.test.sh` builds its fixture plugin roots from the same
  derivation rather than a third copy.

**Stated limitation of the ratchet.** `--refresh` re-baselines: it rewrites
`precision-baseline.json` from the freshly mined corpus, clearing any recorded
drop and any declared `pending[]`. The ratchet therefore guards the window
*between* refreshes. That is acceptable only because refreshing is a deliberate
act visible in the diff and never a side effect of `--check` — but it is a real
bound on the gate's strength, recorded rather than glossed.

`pending[]` in `precision-baseline.json` is a list of `{path, reason}` objects —
deliberately richer than prkit's bare-string `pending` list, because a
re-affirmation deferral needs a stated reason. Neither kind of declaration can
become a permanent exemption, and the two are bounded differently on purpose.

A **measured** declaration is tethered by the anti-parking rule: the path keeps
its `prompt_digests` entry holding the measured bytes, so the moment it stops
diverging from them the stale declaration fails the check. An **unmeasured**
declaration has no measured bytes to return to, so the anti-parking rule can
never fire for it — which is precisely why it needs a tether of its own. It is
bounded by its `unmeasured_digests` entry instead, and
a post-declaration edit of a declared-unmeasured surface reds. A declared
surface with neither entry fails closed, naming the field to add: the missing
digest is never read as "nothing to check".

### 5.1 The ratchet is UNARMED on day one

With zero `trailer`-attributed rows, every lens has `n = 0 < MIN_N_PUBLISH`, so
no lens is armed and the ratchet cannot red. This is recorded here explicitly so
a reader does not mistake a *silent* ratchet for a *passing* one. The ratchet's
behaviour is proven by fixture baselines and fixture corpora in
`tests/review-precision.test.sh`, never by the committed pair.

---

## 6. Determinism, hermeticity, and injection seams

The miner's render path is pure and offline:

- **Clock injection.** `--render` and `--check` classify against the corpus's own
  `generated_at`, never the wall clock, so the committed report is a pure
  function of the committed corpus. Without that, the `pending`/`stale-open`
  split would drift on its own and red the freshness gate in CI days after the
  report was written, with nothing having changed. `--now <ISO8601>` overrides
  it, which is how ladder rows 4 and 5 are tested.
- **Path injection.** `--corpus`, `--baseline` and `--report` override every
  committed path so every ratchet, freshness and anti-vacuity test drives a
  fixture tree instead of mutating the real one.
- **Repo injection.** The repository slug is resolved with
  `gh repo view --json nameWithOwner` and overridable with `--repo`. No org,
  repo name or numeric project id is hardcoded anywhere in the miner — the test
  suite greps for both.
- **Hermeticity.** Everything except `--refresh` runs with no network and no
  `gh`. The suite proves it by prepending a `gh` shim that touches a sentinel
  and exits non-zero, then asserting `--check` still returns 0 with the sentinel
  absent.
- **Roster import, not roster copy.** `PHASE1_CONTRIBUTORS` and
  `PHASE2_CONTRIBUTORS` are imported from `lib/report_primitives.py`, which the
  wire order in `lib/review-fleet-args.sh` already mirrors. Family partition is
  **membership in those tuples**, never a `startswith("review_pr.review.")`
  prefix test — a prefix test would put a literal roster string back in the
  miner and defeat the no-copy rule it is meant to enforce.

Exit codes: `0` agree, `1` a check failed (freshness, ratchet, or digest), `2`
usage error or an unreadable input.

---

## 7. The threshold consumption seam (for #431)

Issue #432 asks that per-lens thresholds "override the global default from
#431". Two facts make that unshippable in this change: #431 is unlanded, and
every lens is far below `MIN_N_THRESHOLD`. What this RFC ships instead is the
*seam*, so #431 has something to implement against.

A per-lens threshold **cannot live in the agent prompt file.**
`agents/code-reviewer.md` is a single file dispatched **twice** — once as
`review_pr.review.correctness` and once as `review_pr.review.general`. A number
written into that file is necessarily shared by two lenses whose measured
precision may differ, which is exactly the averaging failure the issue calls
out. Therefore:

> **Normative:** a per-lens threshold rides the **dispatcher input, keyed by
> edge id**, alongside the other per-child bindings the review fleet already
> mints. The agent prompt consumes a threshold it is *given*; it never carries
> one.

Until `MIN_N_THRESHOLD` is met, the thresholds block of the report reads
`insufficient-data` for every lens, and the global default stands unmodified.

---

## 8. Out of scope

Per-finding numeric confidence (#431) · shipping a `confidence_threshold`
config key · retro-labelling the 38 historical issues · per-lens model
remediation · **any** change to the fingerprint recipe, the existing marker,
the fail-CLOSED dedupe, or `MAX_NEW=10` · a second `/review-pr` halt path ·
precision for the uberscan / ubersimplify / testers / uberthink fleets (the
trailer's `slug=` makes them measurable later by construction) · **recall**,
which needs the findings the reviewers did *not* file and is not observable
from this corpus at all.
