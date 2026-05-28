---
rfc: 10
title: /uberdev:cluster — repo-wide issue similarity analyzer and fold-into-lead consolidator
issue: 247
status: accepted
date: 2026-05-28
author: TheFJK
---

# RFC 0010 — `/uberdev:cluster`: repo-wide issue similarity analyzer and fold-into-lead consolidator

| Field          | Value                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------- |
| **Status**     | Accepted                                                                                    |
| **Author**     | TheFJK                                                                                      |
| **Created**    | 2026-05-28                                                                                  |
| **Closes**     | #247                                                                                        |
| **Targets**    | new `commands/cluster.md`, new `skills/cluster-pipeline/`, new `agents/issue-similarity-analyzer.md`, edit `lib/report_primitives.py` |
| **Supersedes** | —                                                                                           |
| **Related**    | RFC 0005 (`/uberdev:goal`), RFC 0007 (`/uberscan`), RFC 0008 (`/ubersimplify`), RFC 0009 (`/uberthink`) |
| **Tier**       | Large (multi-agent, multi-file, GitHub-mutating under opt-in `--execute`)                   |

## Summary

`/uberdev:cluster` (alias: `/ubercluster`) is a repo-wide GitHub issue similarity analyzer and fold-into-lead consolidator. It performs **second-order dedup** — collapsing finding-issues that share a root cause but carry different fingerprints — closing the gap left by `findings-to-issues`' exact-fingerprint HTML-comment dedupe. The command mirrors the three-layer decomposition used by `/uberscan`, `/ubersimplify`, and `/uberthink`: a thin command, a directive-emitter pipeline skill (`cluster-pipeline`), and a read-only `issue-similarity-analyzer` agent (`model: inherit` per the v0.35.0 all-inherit policy). Default `--dry-run` emits a markdown proposal report; `--execute` (opt-in, mutating) folds clusters into a picked lead and is gated by a hard 0.85 confidence floor. The motivating real cluster lives in this repo's MEMORY: #225 / #226 / #227 all describe the same skill-renderer `$N`-substitution root cause under three different summaries — `/cluster` exists so `/goal` need not burn ~3× the orchestrator + leaf-`/review-pr` fixed token cost dispatching three near-identical `/turbo` runs.

## Motivation

### `/goal` token burn on semantically-duplicate findings

`/uberdev:goal` (RFC 0005) dispatches one `/turbo` per queued finding-issue. Each `/turbo` carries a roughly **100k-token fixed cost** for orchestrator setup + leaf `/review-pr` fanout, paid before any actual repair work begins. When three closely-related findings sit in the queue, `/goal` pays this fixed cost three times — and three branches, three PRs, three trust signals, three `/merge` cycles follow. The motivating cluster in this repo's MEMORY (the skill-renderer `$N`-substitution trio #225 / #226 / #227) is exactly this shape: three different reviewer wordings, one root cause, one fix. A pre-Phase-1 collapse pass that folds those three into one lead drops the dispatch cost by ~3× wall-clock and ~3× tokens, and produces one PR instead of three sibling-mergeable PRs.

### Gap left by `findings-to-issues` exact-fingerprint dedupe

`findings-to-issues` already dedupes by exact fingerprint via the HTML-comment marker `<!-- uberdev:review-pr-finding fingerprint=<16-hex> -->`. That marker is computed from the canonicalized finding text; two reviewers reporting the same defect with different wording produce two different 16-hex fingerprints and two different issues. The exact-fingerprint scheme is correct as a defensive check against re-filing literally the same finding twice; it cannot reach second-order dedup. Closing the second-order gap requires semantic clustering — an LLM read of the issue bodies that judges shared root cause across surface differences. That is a different operation, with different failure modes (overconfidence, hallucination) and a different threat boundary (every issue body becomes external-untrusted-input). Bolting it onto `findings-to-issues` would expand that agent's responsibility surface and introduce calibration uncertainty into a hot path. A standalone command is the cleaner shape.

### Why a standalone v1 (not inline inside `findings-to-issues` or `/goal`)

Calibration uncertainty is the deciding factor. LLM verbalised confidence is systematically overconfident (verbalised 0.90 ≈ realised 0.65-0.75 in the published calibration literature). v1 ships standalone so the analyzer can be exercised in `--dry-run` mode against real-world clusters before any auto-mutation occurs, and well before any hot-path `/goal` cycle depends on its output. v2 may then route low-confidence proposals through `findings-to-issues` (allow-list slug `cluster-aggregate` is already reserved) or hook into `/goal` Phase-1 as a pre-dispatch collapse pass — but only after empirical evidence justifies promotion. Shipping the analyzer as a hot-path component on day one would couple two qualitatively different operations (issue triage vs. issue mutation) and introduce a regression surface against the most-used `/goal` autonomous loop.

## Design

The pipeline runs as six phases (0–5) with one optional inter-phase meta-pass (3.5). Every cross-phase boundary persists state to `.uberdev/cluster/<RUN_ID>/run-state.txt` because each `bash` fence inside the pipeline `SKILL.md` runs in a fresh shell (the directive-emitter rule documented in RFC 0009 §2 and in this repo's MEMORY under `project_uberdev_pipeline_directive_emitter`). The full per-phase contract — state shape, bash sketch, DISPATCH sentinels, error-handling — lives in the design spec at `docs/uberdev/specs/2026-05-28-uberdev-cluster-command-design.md` under `## Pipeline phases`; this section gives the architectural shape only.

### Phase 0 — Preflight

Parses `$ARGUMENTS`, reads `cluster.*` config keys via `lib/config-read.sh::uberdev_read_int_in_range`, validates `--repo OWNER/NAME` against `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, enforces the `--execute` floor (`--min-confidence >= 0.85` mandatory; `--repo` mandatory; `viewerPermission ∈ {ADMIN, MAINTAIN, WRITE, TRIAGE}` pre-check; `gh` core-bucket rate-limit pre-flight). Generates `RUN_ID` (UTC timestamp + 4-hex random suffix), writes `$RUN_DIR/run-state.txt` and a `$UBERDEV_TMPDIR/cluster-active-id.txt` bootstrap pointer for fresh-shell phase rehydration. Refuses on conflicting `--dry-run` + `--execute`.

### Phase 1 — Fetch

Runs one `gh issue list` call against the resolved repo with `--limit MAX_TOTAL_ISSUES_FETCHED` (default 1000, hard ceiling 5000). Caps each issue body at 64 KiB to bound ReDoS-style cost in downstream regex operations, then runs `lib/secret-scan.sh::uberdev_run_secret_scan_stdin` against every body — fail-CLOSED on rc≥2 (any secret-shape match seeds the issue into the refuse list rather than the cluster pool). Builds the refuse list from four sources: the `uberdev:active` and `review-pr:pending` labels (cross-`/solve` and cross-`/review-pr` lock awareness), the `folded` label (prior-run idempotency seed), and any open PR with a `closingIssuesReferences` backlink.

### Phase 2 — Chunk

Inline `jq` array-slicing — explicitly **not** an extension of `lib/chunk.py`. `chunk.py` is `git ls-files`-based and chunks source files; issue-JSON chunking is a different problem solvable in roughly five lines of `jq` (`to_entries[] | select(.key < N)`). The chunk size is 10 issues per chunk, filter-refuse-list-first. Output: `chunks/chunk-NN.json` files.

### Phase 3 — Analyze (parallel `Task()` fanout)

The pipeline `bash` fence here is a directive-emitter: it writes per-chunk prompts via `cluster_propose.py --build-prompt` (each chunk's prompt wraps every issue body in its own `<external-untrusted-input source="github-issue-<N>">` envelope — distinct sources per body, never a single bulk envelope), then emits `DISPATCH: phase=analyze chunk=<name>` sentinels and returns in milliseconds. The orchestrator reads the DISPATCH lines and fires `Task("issue-similarity-analyzer", $prompt_path)` calls in **single-message batches of `$CONCURRENCY`** (default 3, configurable via `fanout_concurrency.cluster`). Wave-major: the orchestrator waits for each wave's full return before firing the next. Each agent writes `$RUN_DIR/analyses/chunk-NN-clusters.yaml`. The agent contract (input envelope shape, calibration rubric, output YAML schema, refusal rules) is specified in full in the design spec under `## Agent contract`.

### Phase 3.5 — Cross-chunk meta-pass

A cluster may straddle a chunk boundary (e.g. #225 in chunk 1, #226 in chunk 2) — one duplicate-cluster member analysed per chunk produces no cluster within a chunk. A single meta-pass takes all chunk-level YAML outputs and looks for cross-chunk merges via one more `Task()` call to `issue-similarity-analyzer` with a `--build-meta-prompt` template. The meta-pass also acts as soft calibration: clusters proposed by multiple independent chunks get higher effective confidence than single-chunk proposals. Skipped when `TOTAL_ISSUES < 2 × CHUNK_SIZE` (i.e. a single chunk has no boundary to straddle).

### Phase 4 — Propose

Aggregates all chunk + meta YAMLs into one JSON cluster array, filters by `MIN_CONFIDENCE`, and renders `$RUN_DIR/proposals.md` via `cluster_propose.py` (which reuses `lib/report_primitives.py::cell()`, `envelope()`, and the new `fingerprint16()`). Under `--dry-run`, the pipeline exits 0 at the end of this phase — the operator reads `proposals.md`, mentally diff-reviews the clusters, and decides whether to re-run with `--execute`.

### Phase 5 — Execute (`--execute` only)

Per-cluster algorithm: provision the `folded` label (`gh label create --force`, description ≤100 chars per MEMORY `project_uberdev_label_desc_100char_limit`), integer-validate every issue number against `case "$N" in *[!0-9]*|"") continue ;; esac` immediately before each `gh` call (defence-in-depth against analyzer-returned malformed numbers), compute `FP=sha256("$lead:$members_csv:$rationale")[0:16]`, run the three-layer idempotency check (see §Three-layer idempotency below), per-member TOCTOU re-check via `gh issue view --json labels,state,closingIssuesReferences` (single round-trip, three fields — closes the Phase-1-to-Phase-5 race window per the security analysis under §Q4), post the "Folded into #LEAD" comment via `--body-file` only (never `--body "$VAR"` — security regression vector per `findings-to-issues:35`), apply the `folded` label, `gh issue close --reason "not planned"`, secret-scan the constructed lead-body file before `gh issue edit --body-file`, then append a JSONL record to `$RUN_DIR/ledger.jsonl`. Serial `gh` writes with `sleep 1` between each (secondary-rate-limit safety — `--concurrency` applies only to the Phase-3 analyzer tier, never to Phase-5 GH mutation).

### Three-layer idempotency

Re-running `--execute` against the same cluster must be a no-op. v1 uses three independent layers; any one match short-circuits the fold:

1. **`$RUN_DIR/ledger.jsonl`** — authoritative run-time audit log. Append-only JSONL, one object per fold action with `run_id`, `lead`, `members`, `fingerprint`, `confidence`, `timestamp`. Check: `grep -qF "\"fingerprint\":\"$FP\""`.
2. **HTML-comment marker on lead body** — user-visible audit trail. Marker shape: `<!-- uberdev:cluster-fold lead=<LEAD-N> members=<M1,M2,...> fingerprint=<16-HEX> -->`. Check: `gh issue view --json body --jq .body | grep -qF "fingerprint=$FP"`. Soft contract — operator can hand-strip; survival relies on the other two layers.
3. **`folded` GitHub label on duplicates** — API-queryable, immutable to body-edit. Check: TOCTOU re-check at Phase 5 plus Phase-1 refuse-list seed.

The three layers cover the realistic single-failure scenarios (marker-strip, label-removal, lost-ledger). Only the unlikely simultaneous failure of all three would allow a duplicate fold; in that case the operator must explicitly `--max-fold-per-run` cap and re-run.

### Safety floors

- **Hard 0.85 confidence floor under `--execute`.** Refused at Phase 0 with verbatim message: `error: --execute requires --min-confidence >= 0.85 (got <N>); Auto-mutation needs headroom against LLM overconfidence (RFC 0010 §Q4).` Rationale: published calibration data shows verbalised 0.90 ≈ realised 0.65-0.75; the 0.85 floor leaves ~10 percentage points of overconfidence headroom against a guess at the realised distribution. `--dry-run` ships at 0.75 default (matching the VSCode triage-extension precedent) because surface-and-review can tolerate lower precision.
- **`MAX_FOLD_PER_RUN=30`** writes per invocation (configurable via `cluster.max_fold_per_run`; hard ceiling 100). Bounds blast radius if the analyzer over-proposes.
- **`MAX_CLUSTER_SIZE=8`** members per cluster default (configurable via `cluster.max_cluster_size`); **hard refuse above 25 members** — analyzer output above the hard ceiling is logged `REFUSE: hallucinated mega-cluster` and dropped without mutation. The default-vs-ceiling split lets operators raise per-run for legitimate larger clusters while still rejecting hallucinated mega-clusters.
- **`--repo OWNER/NAME` mandatory under `--execute`** with `viewerPermission` pre-check (allowlist `{ADMIN, MAINTAIN, WRITE, TRIAGE}`; READ silently fails mid-loop, so refuse upfront). Optional under `--dry-run` — falls back to `gh repo set-default`. Validated via `case` glob pattern (`[A-Za-z0-9._-]*/[A-Za-z0-9._-]*`), not `[[ =~ ]]` regex — `BASH_REMATCH` is empty under zsh per MEMORY `project_uberdev_type_t_bashism_zsh` and the skill-renderer environment.
- **Read-only on duplicate issue bodies.** Phase 5 posts a comment + applies label + closes; never edits the duplicate's body. This keeps `gh issue reopen` fully reversible — the duplicate's audit trail is the close-comment + label, both removable on reopen.

## Migration plan

v1 ships standalone — no migration. The command is a new top-level surface; there is no incumbent implementation to migrate from or backward-compat shim to maintain. v2 may hook into `/uberdev:goal` Phase-1 as a pre-dispatch collapse pass once the standalone analyzer has been exercised in production `--dry-run` mode against enough real-world finding-issue queues to characterise its calibration empirically. The `findings-to-issues` allow-list slug `cluster-aggregate` is also reserved for a possible v2 routing path (low-confidence cluster proposals filed as their own tracking issues for human triage), but v1 explicitly does not extend `agents/findings-to-issues.md` — the proposal report is written to `$RUN_DIR/proposals.md` only.

## Open questions

These are the v1-shipping open questions mirrored from the design spec's `## Risks / open questions`; spec-reviewer signed off on shipping with them open and revisiting in v2.

- **Phase 3.5 meta-pass skip threshold.** The current skip rule is `TOTAL_ISSUES < 2 × CHUNK_SIZE` — equivalently, skip when only one chunk exists. With `CHUNK_COUNT = 2` but issues split unevenly (e.g. 18 / 2), the meta-pass may be a wasted `Task()` call. The threshold may need tightening to `TOTAL_ISSUES < 2 × CHUNK_SIZE` AND `min(chunk_size) >= 3` (or similar) once we have empirical data on whether tiny straddler chunks ever produce useful meta-pass merges. v1 ships the simpler boundary-presence threshold and revisits.
- **`--summary-issue` flag (deferred).** Currently `--execute` writes per-fold rows to `$RUN_DIR/ledger.jsonl` and a single `$RUN_DIR/proposals.md`. An optional `--summary-issue` flag could additionally file one tracking issue summarising the run's folds — useful for operators who want a single GitHub-native audit anchor instead of a local file. Deferred to v2 to keep the v1 mutation surface narrow.
- **`--repo` validation under `--dry-run`.** Current decision (Q&A Q6): optional under `--dry-run` with `gh repo set-default` fallback; mandatory under `--execute`. The trade-off is typo-risk reduction (a stricter validation catches `--repo TheFJK/UbreDev` before any `gh` call) versus invocation friction for the common case. Revisit after the first real-world `--dry-run` runs — if typo-aborts are non-zero, raise to mandatory under `--dry-run` as well.

## Shipping checklist

The following appendix is quoted verbatim from the design spec's `## Rollout plan` section so this RFC stands alone as the auditable approval document. The spec lives at `docs/uberdev/specs/2026-05-28-uberdev-cluster-command-design.md`.

Single PR titled `feat(cluster): /uberdev:cluster — repo-wide issue similarity analyzer and fold-into-lead consolidator (#247)`. Body contains `Closes #247`.

**PR composition:**

1. RFC: `docs/rfc/0010-uberdev-cluster-command.md`
2. Command: `plugins/uberdev/commands/cluster.md`
3. Skill: `plugins/uberdev/skills/cluster-pipeline/SKILL.md` + `cluster_propose.py`
4. Agent: `plugins/uberdev/agents/issue-similarity-analyzer.md`
5. Alias registration (5 surfaces): `aliases-sync.sh`, `install-aliases.md`, `uninstall-aliases.md`, `README.md` (alias table + count prose), `tests/aliases.test.sh`
6. Version bump (8 surfaces): `plugin.json`, `marketplace.json`, `README.md` badge, `CHANGELOG.md` `[0.35.3]` section, `tests/goal.test.sh` G20, `tests/solve-claim.test.sh`, git tag `v0.35.3`, GitHub Release `v0.35.3` (renumbered from 0.35.0 → 0.35.3 at consolidation — collided with main's 0.35.2)
7. Tests: `tests/cluster.test.sh` + `tests/cluster-pipeline.test.sh`
8. CI wiring: `.github/workflows/test.yml` registers both test files on ubuntu + windows + (optionally) macos

**Pre-push checklist (mandatory before push):**

- [ ] All ACs map to a section in this spec — verified in §Acceptance criteria
- [ ] `bash tests/cluster.test.sh` — 0 fails
- [ ] `bash tests/cluster-pipeline.test.sh` — 0 fails
- [ ] `bash tests/aliases.test.sh` — 0 fails (alias drift caught)
- [ ] `bash tests/goal.test.sh` — 0 fails (G20 version-ratchet caught)
- [ ] `bash tests/solve-claim.test.sh` — 0 fails (version-ratchet caught)
- [ ] `gh label create --description` length audit — every new label description ≤100 chars (`wc -m`)
- [ ] `grep -rn "type -t\|BASH_REMATCH" plugins/uberdev/skills/cluster-pipeline/` — 0 hits
- [ ] `grep -rn 'awk.*\$[0-9]' plugins/uberdev/skills/cluster-pipeline/` — 0 hits
- [ ] No secret-shape literals in test fixtures (assemble at runtime — memory `project_uberdev_secret_fixture_self_trip`)
- [ ] PR body contains `Closes #247`
- [ ] No Claude attribution trailer or `🤖 Generated with Claude Code` footer (CLAUDE.md global override)

**Post-push (mandatory):**

- [ ] `/uberdev:review-pr` triggered after push (global CLAUDE.md: "MANDATORY: run `/uberdev:review-pr` after pushing the PR. No exceptions.")
- [ ] On GREEN trust signal: tag `v0.35.3`, `gh release create v0.35.3` with CHANGELOG excerpt
- [ ] `/merge` invocation remains independent — NOT auto-chained from `/cluster` (memory `feedback_merge_independent`)

**Manual verification post-merge:**

- [ ] `/uberdev:cluster --dry-run` against the TurboDev repo → proposals.md generated; recognised clusters include #225/#226/#227 (the memory-documented skill-renderer trio)
- [ ] `/uberdev:cluster --execute --min-confidence 0.90 --repo TheFJK/UberDev --max-fold-per-run 5` against a sandbox repo → ledger.jsonl populated; folded label visible on closed issues; re-run is a no-op (idempotency)
