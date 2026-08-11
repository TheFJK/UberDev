# Measured reviewer precision

<!-- GENERATED FILE — do not edit by hand.
     regenerate: python3 tools/eval/review-precision.py --refresh
     verify:     python3 tools/eval/review-precision.py --check
     contract:   docs/rfc/0018-review-precision-eval.md
-->

Corpus: `tools/eval/corpus.json` — 38 rows carrying label `review-pr-finding` in `TheFJK/UberDev`, mined 2026-08-11T01:41:26Z.
Baseline: measured 2026-08-11T01:41:26Z. Ladder, quarantine rule and every floor below are normative in RFC 0018.

- `n` counts ADJUDICATED rows only — those carrying `finding:true-positive` or `finding:false-positive`. A closed, unlabelled finding is `unadjudicated`, never a true positive.
- Publication floor: below n=20 a lens reports `insufficient-data`, never a ratio.
- Threshold floor: below n=50 no per-lens threshold is derived and the global default stands.
- Intervals are Wilson score, 95% (z=1.96).
- Only rows whose lens attribution came from the machine-readable `uberdev-finding-meta` trailer reach the tables below; everything else is quarantined in the pre-instrumentation section.

## Phase 1 — reviewer lenses

| Lens | Precision | tp | fp | not planned | unadjudicated | pending | stale-open | conflicted |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `review_pr.review.correctness` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.review.silent_failures` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.review.types` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.review.comments` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.review.tests` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.review.general` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Phase 2 — simplify lenses

| Lens | Precision | tp | fp | not planned | unadjudicated | pending | stale-open | conflicted |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `review_pr.simplify.reuse` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.simplify.quality` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `review_pr.simplify.efficiency` | insufficient-data (n=0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Other edges

_No findings attributed to an edge outside the two rosters._

## Unattributed

0 row(s) carry the trailer but record no edge. An empty `edges=` is a recorded state, not an invitation to guess a lens.

## Pre-instrumentation (low confidence)

These rows predate the `uberdev-finding-meta` trailer, so their lens is either a display-only prose string or absent entirely. They are excluded from every ratio above and from the ratchet, and no precision is computed for them — reverse-engineering a lens from rendered prose is the inference the finding pipeline forbids everywhere else.

| Attribution source | rows | true-positive | false-positive | not planned | unadjudicated | pending | stale-open | conflicted |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `trailer` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `agent-line` | 35 | 0 | 0 | 1 | 35 | 0 | 0 | 0 |
| `none` | 3 | 0 | 0 | 0 | 3 | 0 | 0 | 0 |

## Derived per-lens thresholds

| Lens | Threshold |
| --- | --- |
| `review_pr.review.correctness` | insufficient-data (n=0) |
| `review_pr.review.silent_failures` | insufficient-data (n=0) |
| `review_pr.review.types` | insufficient-data (n=0) |
| `review_pr.review.comments` | insufficient-data (n=0) |
| `review_pr.review.tests` | insufficient-data (n=0) |
| `review_pr.review.general` | insufficient-data (n=0) |

A threshold, once derivable, rides the dispatcher input keyed by edge id — never the agent prompt file, which one reviewer agent shares across two dispatches (RFC 0018 §7).

## Counts appendix

| Metric | Value |
| --- | --- |
| rows total | 38 |
| rows in section `headline` | 0 |
| rows in section `phase2` | 0 |
| rows in section `other` | 0 |
| rows in section `unattributed` | 0 |
| rows in section `pre-instrumentation` | 38 |
| rows classified `true-positive` | 0 |
| rows classified `false-positive` | 0 |
| rows classified `conflicted` | 0 |
| rows classified `pending` | 0 |
| rows classified `stale-open` | 0 |
| rows classified `unadjudicated` | 38 |
| rows closed as NOT_PLANNED | 1 |
| multi-edge rows | 0 |
| edge observations | 0 |

Section counts partition the corpus: every row lands in exactly one, so they sum to `rows total`. Edge observations count a k-edge row k times, which is why they can exceed the row count.

