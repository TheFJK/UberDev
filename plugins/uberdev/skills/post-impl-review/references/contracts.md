# Post-impl-review — roster, aggregate contract, and integration

Reference for `skills/post-impl-review/SKILL.md`. The reviewer roster and the fanout-cap precedence are needed at dispatch time; the evidence-failure taxonomy, the convention-lens citation gate, and the integration contract are needed when a run fails or when a downstream reader has to be re-pointed. Nothing here is optional — it is the same contract, moved off the eager path.

## Reviewer roster and the fanout cap

| Reviewer | Agent file | Lens |
|---|---|---|
| `code-reviewer` (correctness lens) | `agents/code-reviewer.md` (inherit) | Correctness and design (project-convention claims belong to the convention lens, which gates them on a verbatim citation) |
| `silent-failure-hunter` | `agents/silent-failure-hunter.md` | Swallowed errors, ignored returns, silent fallbacks |
| `type-design-analyzer` | `agents/type-design-analyzer.md` | `any`/`unknown` misuse, type safety holes |
| `comment-analyzer` | `agents/comment-analyzer.md` | Stale, redundant, or load-bearing comments |
| `pr-test-analyzer` | `agents/pr-test-analyzer.md` (inherit) | Behavioral test coverage, critical gaps, test quality |
| `code-reviewer` (general lens) | `agents/code-reviewer.md` (inherit) | Catch-all for issues that fall outside the other 6 lenses (the brief flags this lens via the dispatcher's prompt) |
| `convention-compliance` | `agents/convention-compliance.md` (inherit) | Project-convention compliance, with a verbatim rule citation for every finding (the only lens permitted to quote another file, and only from the allowlist) |

**Net change vs. pre-#73 fanout:** −`code-simplifier` (moved to Phase 2 of `/uberdev:review-pr` as the named lens dispatcher), +`pr-test-analyzer` (was documented in `/review-pr` `## Agent Descriptions` but never actually fanned out from this skill). 5 → 6 reviewers; composition changed.

**Per-repo fanout cap.** Immediately before dispatching the 7 reviewer
agents, the executable setup sources `${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh`
and resolves `POST_IMPL_REVIEW_CAP=$(uberdev_read_int_in_range fanout_concurrency.post_impl_review UBERDEV_FANOUT_POST_IMPL_REVIEW 1 50 7)`,
then lets `post_review_resolve_cap` override that answer with the caller's
`fanout_cap` Skill input when one was supplied.
When `CAP < 7`, split the 7 routed calls into `ceil(7 / CAP)` sequential
waves — each wave still obeys the dispatch-all-before-wait
invariant. When `CAP >= 7` (default), dispatch all 7 in one wave
(today's behaviour, unchanged). Default 7, range [1, 50],
precedence `fanout_cap` input > env > config > default. The input is the ONLY
precedence tier that works across a caller boundary: `/uberdev:review-pr`'s
`sequential` token used to `export UBERDEV_FANOUT_POST_IMPL_REVIEW=1` from one
of its own `bash` blocks, which is a different shell from this fence, so the
override never arrived and the token was a silent no-op (#302).
## The evidence ledger

The evidence ledger is independently roster-bound. Every row carries the
stable edge, its original index in `REVIEW_EDGES`, the exact launched child
instance, the child-owned `validated-result.md` path derived from that
instance's launched provider-result directory, and the validated digest.
Repair attempts retain the failed row's original edge/index while minting a
fresh instance. The final gate requires the exact edge/index roster, one
matching launched instance per row, and unique canonical paths and file
identities; duplicate indices, duplicate/hard-linked artifacts, foreign paths,
and digest replacement all fail closed.
## Evidence-failure classes

`result-rewritten-after-status` is the same distinction applied to a different
failure (#645). One nonce is minted per review ITERATION and every re-dispatch
of that iteration inherits it, writing the same `children/<slug>-iter<NN>/`
directory, so a retry that published its `result.md` and then died leaves the
COMPLETED attempt's `status.json` attesting to the DEAD attempt's report — with
every digest equality passing, because both digests are computed from the same
substituted bytes. The bound-child protocol publishes the result before the
status, so `capture-bound-child` refuses a result that is strictly newer than
the status attesting to it. Reported under its own class because the
investigation is "this child's result was rewritten after it completed", not the
`roster-mismatch` reading of "this child never bound itself".

`incomplete-roster` is a statement about row count, not about intactness: a
ledger truncated at a line boundary presents as short too, and the ledger's own
bytes cannot separate the two. The corroborating evidence is the wait
boundary's per-child record. `post_review_wait_all` emits
`post_review_child_wait_failure edge=… index=… instance=… rc=…` for every
reviewer it abandoned, and `uberdev_wait_child` emits `child settle budget
exhausted: instance=… state=… budget=…s reason=…` when its own wall-clock
budget — not the reviewer — is what ended the wait. One abandonment line per
missing row means a supervision shortfall; a short ledger with no such line
means rows were lost after they were written. Without those lines the two are
indistinguishable after the fact, because a child abandoned mid-settle keeps
the terminal state it published for itself.
### The convention lens's citation gate (#433)

`review_pr.review.convention` is the one Phase 1 lens whose finding is a claim
ABOUT A DOCUMENT — "the project's rules say X". That claim reads as
authoritative and is trivially fabricated, so the lens is admissible in this
fleet only because it arrives with its own filter, and the filter is
DETERMINISTIC: "does this byte string occur in that file, near that line" and
"does a rule in directory D govern a file under D" are both decidable, so
routing them through a second model would trade a decision for an opinion.

The writer takes three more REQUIRED inputs — the run's `rule-sources.txt`
allowlist, the root those paths are relative to, and the run's
`changed-paths.json` — and gates every convention observation **before** scope
grouping (grouping merges same-`(path,line)` findings across edges, so a later
cull would take another lens's finding with it):

- the quote is verified verbatim against the cited file's own bytes, within a
  bounded window of the cited line, after whitespace normalisation;
- a cited path outside the allowlist is never opened at all;
- a rule is scoped to its own directory subtree — `plugins/x/CLAUDE.md` does not
  govern `tools/`;
- a quote that is secret-shaped, too short to cite anything, or longer than the
  contract's 300-character carve-out is refused;
- a rule **this PR itself wrote** is circular rather than false, so the finding
  survives demoted to `suggestion`.

A finding whose quote cannot be located is **culled**, not downweighted — a
fabricated citation is a false finding, not an uncertain one — and the
contributor's `verdict` is then recomputed from its surviving blockers so the
two-way verdict/severity invariant still holds on the aggregate.

Every cull and demotion is written to
`.uberdev/research/$RUN_ID/post-review/convention-citations.md` (reason, cited
rule, finding location, normalised quote prefix — each field neutralised the same
way any other repo-derived text is, because in a PR that edits a rule file the
quote is attacker-controlled). The log is published BEFORE the aggregate and is
written even when nothing was culled, so its absence means the gate did not run
rather than "nothing to report": **a cull is never swallowed.** Child
`result.md` snapshots are never rewritten — they are sha256-pinned in the trusted
ledger, so only the aggregate is filtered and the filtering is itself an
artifact.

The writer adds four fail-closed classes for these inputs:
`rule-sources-unavailable`, `rule-root-unavailable`, `changed-paths-unavailable`,
and `citation-log-unwritable`. A MISSING allowlist is a controller that never ran
discovery and refuses the whole write; an allowlist that exists and is EMPTY is
legitimate and means this repository wrote no conventions down.

Markdown tables, YAML bodies, verdict-only rows, and lossy "top finding"
summaries are not aggregate fallbacks. The downstream fixer receives every
finding in the canonical document. This skill remains audit-only; the caller's
Phase 1 fixer owns the apply-and-commit loop.
## Failure modes

| Symptom | Action |
|---|---|
| Reviewer supervision is blocked | Suppress the ordinary aggregate immediately, return blocked, and prevent fixer/trust dispatch. |
| A terminal reviewer returns malformed YAML | Retry that edge once with a fresh `attempt02`; if still malformed, suppress the ordinary aggregate, return blocked, and prevent fixer/trust dispatch. |

## Integration

**Called by (the only live caller):**
- **`/uberdev:review-pr` Phase 1** — invoked via the `Skill` tool. Inputs `changed_paths` and `commit_range` are computed by `/uberdev:review-pr` from one fixed local merge-base-to-reviewed-head-SHA snapshot of the pushed PR; `tier` is passed through separately. The 7 reviewer agents run in one or more cap-controlled waves, with every child in a wave dispatched before its first wait; their aggregated findings are written to the canonical path (see Step 4 above) and consumed by `/uberdev:review-pr`'s Phase 1 apply-loop.

**Findings artifact contract:**
- **Writer:** this skill (`uberdev:post-impl-review`), Step 4 — the `<external-untrusted-input source="post-impl-review-aggregate">…</external-untrusted-input>` envelope IS the file's leading/trailing bytes (see Step 4 "Envelope-as-file-bytes").
- **Path:** `.uberdev/research/<RUN_ID>/post-impl-review-final.md`. `<RUN_ID>` MUST match the regex `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` (see `commands/review-pr.md` Run-ID format).
- **Reader:** `/uberdev:review-pr` Phase 1 apply-loop AND Phase 2.5 `findings-to-issues`. Readers pass the artifact PATH (or its already-enveloped bytes verbatim) into downstream prompts — they MUST NOT re-wrap (#302; a read-time second wrap produced a nested envelope while the on-disk file stayed bare, so `findings-to-issues.md` Step 1's first-128-bytes validation refused every Phase-2.5 dispatch `input-malformed`). The envelope still neutralizes the same threat model: second-order injection where issue-author text → diff hunk → reviewer report → aggregate → fixer prompt; imperative directives in reviewer prose stay DATA per the orchestrator trust-boundary convention (see `plugins/uberdev/skills/orchestrator/SKILL.md` "Trust boundary" section).
- **Read shape:** the file body is the exact compact sorted Phase 1 JSON schema-v2 document defined in Step 4. The apply-loop parses only that document; there is no Markdown/YAML aggregate fallback.
- **Failure boundary:** if the artifact is missing or empty, `/uberdev:review-pr` terminates immediately without dispatching the fixer, Phase 2, deferred findings, or trust. The ordinary aggregate exists only after all seven reviewer slots have valid evidence.

**Pre-push bypass (documented opt-out):**
`finish-branch --interactive` Options 1 (local merge), 3 (keep), and 4 (discard) bypass `gh pr create` entirely and therefore bypass the post-push `/uberdev:review-pr` chain. Users who select those options explicitly opt out of automated post-impl review for that branch. The `--interactive` flag is the sole gate for this bypass; the default mode (always-PR) and `--turbo` mode both auto-select Option 2 (Push and create PR), which preserves the chain. See `skills/finish-branch/SKILL.md` Step 4 "Option 1/3/4" caveat for the consumer-side documentation.

**Does NOT call:**
- `uberdev:brainstorm` (anti-loop guard — its handoff would re-trigger plan-writing)
- `uberdev:write-plan` (anti-loop guard — its `## Execution Handoff` would transition to `uberdev:subagent-driven-dev`, which is upstream of the caller)
- `uberdev:subagent-driven-dev` (would loop into self via the parent caller chain)

**Pairs with:**
- `agents/code-reviewer.md`, `agents/silent-failure-hunter.md`, `agents/type-design-analyzer.md`, `agents/comment-analyzer.md`, `agents/pr-test-analyzer.md`, `agents/convention-compliance.md` — the 6 distinct reviewer agent definitions governed by the manifest-declared shared YAML output contract. `code-reviewer` is dispatched twice (general lens + correctness lens) to round out 7 fanout slots; the agent file is reused but the prompt brief differentiates the lens.
