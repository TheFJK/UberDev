# Fix-fleet — why this lane looks like this

Reference for `skills/fix-fleet/SKILL.md`. Orientation, not instructions:
nothing here is a step. It lives beside the body rather than inside it
because the body is bounded by a hard 500-line ceiling that
`tests/skill-size.test.sh` ratchets, and a lane whose skill cannot take an
edit is a lane nobody will fix.

## What this lane is, and what it deliberately is not

`/turbox` runs a full design pipeline per issue: risk-gated security research,
a design-planner, a plan-reviewer, wave-parallel implementers over disjoint
file sets, a spec-compliance reviewer and a code-reviewer per task, a fix
ladder, and a delivery agent. That is eight or more **sequential** agent rungs
before a PR exists, and it is the right shape when an issue decomposes into
independent tasks.

`/fix` is the shape for the other case: **one issue, one obvious change, one
reviewer, park the PR.** It runs 2 agents on the happy path and 3 when the
review comes back red.

| | `/turbox` | `/fix` |
| --- | --- | --- |
| Issues per invocation | up to 3 | **exactly 1** (refused at the launcher, before any claim) |
| Design rungs | security research → design-planner → plan-reviewer | **none** |
| Implementation | wave-parallel over a plan's `Owns` sets | **one agent, whole change** |
| Review | spec-compliance per task **+** code-reviewer per task | **one `code-reviewer` over the whole diff** |
| Fix ladder | a per-task ladder inside each wave | **`fixRounds`, read from the plan** |
| Delivery | a delivery agent per issue | **the controller** — no agent seat |
| Sequential agent rungs | 8+ | **2–3** |

**What it drops is design, not diligence.** The change is still committed by
explicit path, still reviewed by an independent agent against the
`phase1-reviewer-v1` contract, still validated by the canonical boundary, still
run against the project's full test suite, and still parked as a PR that nobody
merges. If you find yourself skipping the review, or opening the PR without
running the suite, you have not made `/fix` faster — you have made it dishonest.

**When the issue is bigger than this lane, say so and stop.** An issue that
needs a decomposition is not served by a lean lane running longer; it is served
by `/turbox`. Phase 2 names the one return that says this.
