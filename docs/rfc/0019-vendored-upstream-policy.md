# RFC 0019 — Vendored Upstream Policy

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Author** | TheFJK |
| **Created** | 2026-08-10 |
| **Tier** | Large (new shipped data file, two new tools, a scheduled workflow, and a per-component policy decision across 20 vendored components) |
| **Target ver** | next minor release (`vendor.json` ships inside the plugin tree, so the surface is user-visible) |
| **Targets** | new `plugins/uberdev/vendor.json`; new `tools/vendor/vendor-check.py` + `tools/vendor/vendor-drift.py`; new `.github/workflows/vendor-drift.yml`; new `tests/vendor-provenance.test.sh` + `tests/vendor-drift.test.sh`; `tests/ci-wiring.test.sh` (generalised from one workflow file to a workflow set); `tests/docs-accuracy.test.sh` (T3.4); `README.md` Bundled table; `.github/workflows/test.yml` (both wiring surfaces) |
| **Supersedes** | `docs/uberdev/audits/2026-05-04-superpowers-vendor-audit.md` — as the *live* record of what is vendored and from where. The audit stays on disk as the historical snapshot it is; it is not deleted, and #448 is concurrently editing it. |

---

## 1. Problem

UberDev vendors 20 third-party components: 14 skill directories derived from
`obra/superpowers`, and 6 reviewer/simplifier agents derived from
`anthropics/claude-plugins-official`. Until this RFC, the provenance of those
components was recorded in three places that could not be reconciled with each
other:

- **In-file headers** — a `Vendored from <owner>/<repo>@<sha>` comment. Only
  **20 files across 3 skill directories** carry one (`systematic-debugging`,
  `test-driven-development`, `writing-skills`). The other 11 skill directories
  and all 6 agents carry no pin at all.
- **The README Bundled table** — names upstreams, never commits, and had drifted:
  it listed `using-uberdev` as an UberDev original when it is a rename of
  upstream's `using-superpowers`; it listed a skill slug `merge` that does not
  exist on disk (the directory is `merge-pipeline`); and both agent rows cited
  `https://github.com/anthropics/claude-code`, which is not where those agents
  are distributed.
- **`plugins/uberdev/licenses/`** — three licence texts, no versions.

Three spellings of one fact, none of them checked against the others or against
disk. The result is the class this RFC exists to kill: **undeclared drift**.

The cost is not theoretical. Upstream v6.2.0 fixed a real bug in
`find-polluter.sh`; UberDev shipped the broken copy for months because nothing
compared the two. That specific repair is owned by #430 and its PR, not by this
RFC — what this RFC owns is making the *next* one visible within a week instead
of within a year.

A second, quieter cost: because no per-component decision existed, every
divergence looked accidental. Some of them are deliberate and permanent (§6).
Without a written stance, a future "sync from upstream" would silently revert
them.

**Reference convention.** This RFC cites symbols, file paths and section names.
It never cites `file:line` literals — line anchors rot inside a single release
(the failure documented by #349).

---

## 2. The register: `uberdev-vendor-v1`

`plugins/uberdev/vendor.json` is the single source of truth. It is shipped
inside the plugin tree, alongside the code it describes, so a user who installs
UberDev standalone gets the attribution record with it.

### 2.1 Shape

```jsonc
{
  "schema": "uberdev-vendor-v1",
  "policy_rfc": "docs/rfc/0019-vendored-upstream-policy.md",
  "root": "plugins/uberdev",
  "upstreams": { "<id>": { "repo": "owner/name", "license": "...",
                           "license_file": "licenses/..." } },
  "permanent_divergences": [ { "id": "...", "permanent": true, "...": "..." } ],
  "components": [ { "id": "skills/<name>", "path": "skills/<name>", "...": "..." } ]
}
```

Every directory under `plugins/uberdev/skills/` and every file under
`plugins/uberdev/agents/` is a component. There are **75** of them: 20
third-party and 55 carrying `"origin": "uberdev"`. The originals are two-field
stubs; their only job is to make coverage two-way, so that a *new* undeclared
vendored file cannot hide among them.

### 2.2 Two commits per component, not one

| Field | Meaning |
| --- | --- |
| `vendored_at_commit` | What we actually copied from. 40-hex where an in-file header records it; the literal `"unknown"` where no base has been recovered. With #503, #504 and #505 landed together, **no component reads `"unknown"`**. |
| `last_reviewed_upstream_commit` | The **watermark**: the upstream commit a human has triaged this component against. What the weekly job diffs from. |

The split is load-bearing. `"unknown"` was the honest value wherever a base was
unrecoverable — `git log` recovers the *vendoring* commit in this repo, never the
upstream base — and inventing a SHA would make every future diff silently wrong.
The watermark makes those components diffable anyway, from the day this lands,
and it means week 1's report contains post-landing changes instead of a wall of
pre-existing noise. Advancing a watermark is the recorded act of *having looked*.

`tools/vendor/vendor-check.py`'s `C-BASE` is what makes that last clause a rule
rather than a warning: a 40-hex value in `vendored_at_commit` must be restated
by an in-file `Vendored from <owner>/<repo>@<sha>` header on one of the
component's own files, so writing one is a visible, reviewable edit to the
shipped bytes rather than a single silent field change. It is the converse of
`C-HEADER`, which validates only the headers that already exist. It does not —
and offline cannot — prove a copy really happened at that SHA; it makes the
claim cost two coordinated lies instead of one.

### 2.3 `stance` is enforced, not annotated

- `stance: "track"` ⇒ `files[]` is a list of `{path, sha256}`. A local edit to a
  tracked file reds `tools/vendor/vendor-check.py` until the digest is refreshed
  or the change is declared in `divergences[]`.
- `stance: "fork"` ⇒ `files[]` is a plain path list. We own the bytes; edits are
  expected; only *coverage* is ratcheted.
- **Amended by #503:** a component that records a real `vendored_at_commit` is
  digest-locked **whatever its stance** — `files[]` is `{path, sha256}` for every
  `track` component and for every pinned one. See the 2026-08-13 amendment for
  why the two questions come apart.

Be precise about what the digest lock buys: it guards **our bytes against local
tampering and undeclared local edits**. It says nothing about upstream. Comparing
against upstream is `tools/vendor/vendor-drift.py`'s job, and that comparison is
a network operation that must never run inside the offline guard.

### 2.4 Divergences are structured so the drift report can subtract them

Each component carries `divergences[]` — references into
`permanent_divergences[]` plus any component-local entries. `permanent: true`
marks a never-reconcile divergence (§6), so no future sync silently reintroduces
upstream's version of a thing we deliberately changed, and so the weekly report
can label a changed file *declared* instead of raw drift.

---

## 3. Vendor or peer-depend?

Upstream superpowers is now officially distributed as
`superpowers@claude-plugins-official`. That makes a peer dependency technically
available for the first time, so the question has to be answered rather than
assumed.

**Decision: keep-vendoring.**

What the alternative would buy and cost:

| Factor | Weight |
| --- | --- |
| **The standalone promise** | The README Bundled section, both plugin-manifest `description` fields, the shipped `LICENSE`, and `install.sh` all promise that UberDev works with **no** `superpowers`, `pr-review-toolkit` or `code-simplifier` install. Peer-depending breaks a published contract, not an implementation detail. |
| **The `enabledPlugins` failure class** | UberDev already ships `install.sh` because an upstream Claude Code bug silently disabled the plugin through `enabledPlugins`. Adding a *second* plugin whose activation we do not control multiplies a failure mode that is silent by construction. |
| **Permanent divergences** | Five divergences (§6) are never-reconcile. Upstream's files are therefore not drop-in for at least 13 of the 20 components; a peer dependency would have to be shimmed per skill, which is strictly more machinery than vendoring. |
| **Namespace** | Peer-depending re-exposes the `superpowers:` skill namespace that every vendored file deliberately rewrites to `uberdev:`. |
| **Free updates (the cost of this decision)** | Vendoring forfeits upstream's fixes-for-free. This is a real loss, and #430 is the receipt. |

The compensating control for that last row is the whole point of this RFC:
`.github/workflows/vendor-drift.yml` turns "free updates" into "a weekly, deduped
list of exactly what changed, per component, with declared divergences already
subtracted". That is a smaller benefit than automatic updates and a much larger
one than the status quo of nothing.

---

## 4. Per-component stance

### 4.1 The rule

A component is **`fork`** if *either*:

1. its file set differs from upstream's for that component, **or**
2. it carries a permanent local divergence beyond attribution and the namespace
   rebrand, or its dispatch/behavioural contract has been rewritten so upstream's
   copy is not drop-in.

Otherwise it is **`track`**: the delta is attribution plus the
`superpowers:` → `uberdev:` rebrand plus bounded local examples, and we
re-baseline from upstream.

The rule is mechanical on purpose. `diff` line count alone is *not* the
criterion — it was measured for every component and is recorded below as
evidence, but two components with 206 and 228 differing lines are `track`
(1:1 file sets, prose-only deltas) while one with 72 is `fork` (upstream deleted
a file and added a different one).

### 4.2 Skills — measured against `superpowers` v6.2.0

Measured with `diff -r` against the on-disk upstream tree at the `v6.2.0` tag;
"diff lines" counts both `<` and `>` lines and includes the provenance-header
lines UberDev adds.

**Measured:** `superpowers` at `v6.2.0`, on 2026-08-10, counting `<` plus `>` lines including the provenance headers this section's prose declares.

| Component | Upstream path | Diff lines | Stance | Reason |
| --- | --- | ---: | --- | --- |
| `skills/dispatching-parallel-agents` | `skills/dispatching-parallel-agents` | 33 | track | 1:1 file set; delta is the namespace rebrand. |
| `skills/receiving-code-review` | `skills/receiving-code-review` | 41 | track | 1:1 file set; delta is the namespace rebrand. |
| `skills/verification-before-completion` | `skills/verification-before-completion` | 49 | track | 1:1 file set; delta is the namespace rebrand. |
| `skills/execute-plan` | `skills/executing-plans` | 50 | track | Directory rename + namespace rebrand; 1:1 file set. |
| `skills/test-driven-development` | `skills/test-driven-development` | 72 | **fork** | File sets diverge — we ship `testing-anti-patterns.md`, upstream replaced it with `writing-good-tests.md`. Adopting that swap is a decision (#457), not a merge. |
| `skills/systematic-debugging` | `skills/systematic-debugging` | 83 | **fork** | Permanent local *Parallel hypothesis testing* section, already recorded in the file's own header. |
| `skills/write-plan` | `skills/writing-plans` | 123 | track | Directory rename + namespace rebrand; 1:1 file set. |
| `skills/using-uberdev` | `skills/using-superpowers` | 174 | **fork** | This is UberDev's own plugin primer; reference sets diverge in both directions. |
| `skills/using-git-worktrees` | `skills/using-git-worktrees` | 206 | track | Single file, 1:1; delta is the namespace rebrand and UberDev path examples. |
| `skills/requesting-code-review` | `skills/requesting-code-review` | 228 | **fork** | Carries the permanent parallel-by-default review fanout (§6). |
| `skills/writing-skills` | `skills/writing-skills` | 367 | track | 1:1 file set; the 6.2.0 delta is upstream's own prose compression, which we want. |
| `skills/finish-branch` | `skills/finishing-a-development-branch` | 734 | **fork** | Owns the pre-push secret-scan gate, the auto-chain into `/uberdev:review-pr`, and the no-`Co-Authored-By` rule. |
| `skills/subagent-driven-dev` | `skills/subagent-driven-development` | 1064 | **fork** | File sets diverge in both directions; the routed SDD lifecycle is UberDev-owned. Also carries the permanent wave-parallel implementer divergence, which inverts an explicit upstream prohibition (§6). |
| `skills/brainstorm` | `skills/brainstorming` | 2255 | **fork** | Deliberately gate-free (§6); driven by `/uberdev:orchestrator` Phase 1, not an interactive human loop. |

Seven `track`, seven `fork`.

> **Superseded rows.** This table is the dated snapshot of what was measured and
> decided at the v6.2.0 tag. Four of its `track` rows were re-adjudicated against
> their actual base by the 2026-08-13 (#503) amendment below, which carries the
> live stance for `receiving-code-review`, `verification-before-completion`,
> `execute-plan` and `write-plan`. `plugins/uberdev/vendor.json` is always the
> live record; read the amendments before quoting a row.

### 4.3 Agents — measured against `claude-plugins-official`

Re-measured against each component's **recovered base** (§ Amendment 2026-08-13),
counting both `<` and `>` lines and including the provenance-header line each
file now carries.

**Measured:** `claude-plugins-official` at the per-row `Base` column, on 2026-08-13, counting `<` plus `>` lines including the provenance header.

| Component | Upstream path | Base | Diff lines | Stance |
| --- | --- | --- | ---: | --- |
| `agents/comment-analyzer.md` | `plugins/pr-review-toolkit/agents/comment-analyzer.md` | `4ca561f` | 56 | fork |
| `agents/silent-failure-hunter.md` | `plugins/pr-review-toolkit/agents/silent-failure-hunter.md` | `4ca561f` | 57 | fork |
| `agents/pr-test-analyzer.md` | `plugins/pr-review-toolkit/agents/pr-test-analyzer.md` | `4ca561f` | 58 | fork |
| `agents/type-design-analyzer.md` | `plugins/pr-review-toolkit/agents/type-design-analyzer.md` | `4ca561f` | 64 | fork |
| `agents/code-reviewer.md` | `plugins/pr-review-toolkit/agents/code-reviewer.md` | `4ca561f` | 81 | fork |
| `agents/code-simplifier.md` | `plugins/code-simplifier/agents/code-simplifier.md` | `ceb9b72` | 154 | fork |

All six stay `fork`, and the verdict is unchanged — but the **reason recorded
here was measurably wrong for five of them**, and stating a true reason is the
point of writing one down. The claim was that UberDev had rewritten every
`description` frontmatter into the named-lens contract. Measured against the
recovered bases, the frontmatter of `comment-analyzer`, `pr-test-analyzer`,
`silent-failure-hunter` and `type-design-analyzer` is **byte-identical to
upstream** — upstream's auto-trigger examples still ship verbatim — and
`code-reviewer`'s frontmatter differs by exactly two lines, both of them
`model: opus` → `model: inherit`. Only `code-simplifier` was rewritten as
described (42 frontmatter lines).

What actually makes all six not drop-in is the **body**: upstream's own
output-format section is replaced by the `phase1-reviewer-v1` result-file
contract that `/uberdev:review-pr` Phase 1 validates, and the untrusted-input
and secret-leak reporting sections are added. Upstream's copy would emit a
serialization the aggregator rejects. That is a stronger reason than the one it
replaces, which is why the stances are re-stated rather than re-adjudicated.

**A correction the measurement forced — now reversed by a better measurement.**
This RFC previously moved `code-simplifier`'s upstream from the standalone
`code-simplifier` plugin (where the README had it) to `pr-review-toolkit`, on
the grounds that the shipped bytes were 115 diff lines from the
`pr-review-toolkit` copy and 137 from the standalone one. That inference was
wrong, and it was wrong in an instructive way: **similarity was measured against
bytes that had already accumulated a 42-line local frontmatter rewrite**, so the
smaller number was tracking our own edit rather than the ancestry. Blob identity
settles what similarity could not — the vendored file's blob at `bae840a` is
`05e361b4…`, which is `plugins/code-simplifier/agents/code-simplifier.md` at
upstream `ceb9b72b…`, the only commit that has ever touched that path, and is
*not* any blob of the `pr-review-toolkit` copy. The component points back at the
standalone plugin. `pr-review-toolkit` remains a declared upstream for the other
five agents, and both licence texts stay shipped and referenced.

### 4.4 What `track` obliges

`track` is a promise to re-baseline, and it has a price: the seven tracked skill
directories are digest-locked, so **any** local edit to one of them reds
`vendor-check.py` until the register is refreshed. That is the ratchet working.
It is also why `systematic-debugging` is `fork` rather than `track` despite a
thin delta — its permanent local section means upstream is not a merge base, and
forking it keeps the #430 repair free of a digest conflict.

---

## 5. Rename map — and why the renames stay

| Upstream | UberDev |
| --- | --- |
| `brainstorming` | `brainstorm` |
| `writing-plans` | `write-plan` |
| `executing-plans` | `execute-plan` |
| `subagent-driven-development` | `subagent-driven-dev` |
| `finishing-a-development-branch` | `finish-branch` |
| `using-superpowers` | `using-uberdev` |

**The renames are explicitly declined for reversal.** They are the invocation
surface: `/uberdev:brainstorm`, `/uberdev:write-plan`, `/uberdev:finish-branch`
are referenced from commands, agent prompts, tests and user muscle memory.
Reverting them to upstream's spellings to make `diff` tidier would trade a live
interface for a cosmetic gain. The map lives in `vendor.json` as each
component's `upstream_path`, which is what makes the diff tooling work without
the rename.

---

## 6. Permanent divergences — never reconcile

Recorded in `vendor.json` under `permanent_divergences[]` and referenced from the
components they apply to. Every entry carries `"permanent": true` except
`worktree-location-failloud`, which is a bug fix rather than a policy and is
marked `false` precisely so an equivalent upstream guard retires it instead of
being reconciled against.

| Id | Scope | Divergence |
| --- | --- | --- |
| `namespace-rebrand` | all third-party components | `superpowers:` → `uberdev:`. UberDev ships standalone under its own plugin id. |
| `parallel-hypothesis-testing` | `skills/systematic-debugging` | The local *Parallel hypothesis testing* section, already declared in the file's own provenance header. |
| `find-polluter-fail-loud` | `skills/systematic-debugging` | Three local additions to `find-polluter.sh` (#430, #476), declared in the file's own provenance header: fail-loud exit-2 refusals wherever the run cannot back a verdict, glob- and whitespace-safe array enumeration, and a pre-loop runner-capability probe. Upstream returns a green 0 in every refusal shape and its own test asserts that green, so a re-sync collides head-on. |
| `brainstorm-no-approval-gates` | `skills/brainstorm` | UberDev rejects upstream's HARD-GATE / per-section / spec-review approval checkpoints. Quality comes from parallel research and always-on reviewer agents, not human gates. |
| `review-pr-parallel-by-default` | `skills/requesting-code-review` | `/uberdev:review-pr` fans its review lenses out in parallel by default; upstream's flow is sequential. |
| `no-co-authored-by` | `skills/finish-branch` | UberDev never emits a `Co-Authored-By` or AI-attribution trailer in commits or PR bodies. |
| `interactive-discard-option` | `skills/finish-branch` | Upstream 6.2.0 stopped offering to discard *uncommitted work*. UberDev Option 4 discards a *branch and its commits* behind a typed confirmation, reachable only under `--interactive`. Different capability, so upstream's removal does not apply — see §7. |
| `sdd-parallel-implementer-waves` | `skills/subagent-driven-dev` | Upstream forbids dispatching multiple implementation subagents in parallel. UberDev's fork inverts that: wave-parallel implementers over a strictly disjoint per-task file partition is its stated core principle. The partition is declared by the plan's `Owns (file allowlist)` field and its `## Execution Waves` summary, reviewed by `plan-reviewer` Check 2, and refused at dispatch by `sdd_assert_wave_disjoint`. Never reconciled — see the #509 amendment. |
| `receiving-review-parallel-triage` | `skills/receiving-code-review` | The local *Multi-Reviewer Parallel Triage* section: one triage agent per reviewer dispatched in a single message, a fixed Critical/Important/Minor/Refute/Need-clarification shape, de-duplication across reviewers, and three named skip conditions. It names UberDev's own reviewer agents, so upstream has nothing to reconcile with. Measured at #503 as the component's entire residual. |
| `verification-parallel-dispatch` | `skills/verification-before-completion` | The local *Parallel Verification Dispatch* section: two patterns chosen by tool budget, with the Iron Law restated so every parallel arm still needs fresh evidence in the current turn. Measured at #503 as the component's entire residual. |
| `plan-execution-wave-contract` | `skills/write-plan` and `skills/execute-plan` | The wave-parallel plan contract UberDev owns on both sides — `write-plan` emits the wave decomposition and per-task headers, `execute-plan` walks the waves, and `uberdev:subagent-driven-dev` parses the same format. A two-sided interlock: re-baselining either side alone breaks it. |
| `plan-reviewer-inline-no-dispatch` | `skills/write-plan` | Upstream's `plan-document-reviewer-prompt.md` is a dispatch template; UberDev's copy is an inline self-review checklist that must not create a child, because the plan writer runs as a leaf under `uberdev:orchestrator` where a nested dispatch has no runtime. |
| `worktree-location-failloud` | `skills/using-git-worktrees` | **`permanent: false`.** A local bug fix, not a policy: upstream's worktree-path `case` relies on a tilde that expands in neither a `case` pattern nor a quoted RHS, and has no default arm, so an unmatched location falls through with `$path` unset. This copy quotes both accepted spellings, builds the path from `${HOME}`, and exits 1 with a named error. An equivalent upstream guard retires this entry rather than being reconciled against it. |
| `sdd-implementer-refused-status` | `skills/subagent-driven-dev` | Upstream 6.3.0 handles four implementer statuses. UberDev's implementers are routed leaf workers under a safety contract upstream has no equivalent of, so a handoff can be unexecutable for a reason no added context answers; #517 adds a fifth member, `REFUSED`, and a controller branch that forbids re-dispatching the same task with unchanged handoff data. |

---

## 7. The 6.1.0 → 6.2.0 delta: adjudicated, not inherited

**No behavioural upstream content is imported by this RFC's PR.** Each item below
gets a verdict; every ADOPT names a filed issue.

| Upstream item | Verdict | Reasoning |
| --- | --- | --- |
| `writing-good-tests.md` replaces `testing-anti-patterns.md` | **ADOPT — #457** | It names the string-presence trap by name: grep-style tests over scripts, skills and prompts counterfeit falsifiability, because the observable is behaviour, never text. That is a precise diagnosis of a defect class this repo keeps rediscovering (#419). Highest-value item in the delta. |
| SDD workspace is now plan-scoped | **ADOPT — #458** | Fixes a real cross-plan contamination: a follow-up plan in the same tree could read the prior plan's ledger as its own. `subagent-driven-dev` is a fork, so the fix is not inherited. |
| Review-fix loop resumes the implementer, with a five-round breaker | **ADOPT — #459** | A fresh implementer re-derives context the reviewer already priced in, and an unbounded fix loop is the class `/goal`'s circuit breakers exist to stop. |
| `finishing-a-development-branch`: worktree-cleanup no-op fixed | **ADOPT by PORT — #460, shipped** | Answered by executed probe, and the honest answer is worse than the hypothesis. UberDev did **not** inherit upstream's exact defect: upstream captured `WORKTREE_PATH`, then `cd`d, then recomputed it; UberDev never `cd`d and never captured a path. It had four *adjacent* live defects instead, each reproduced against a real repository: (1) an unchecked `git checkout <base>` — from a linked worktree it exits 128, HEAD stays on the feature branch, and the next `git merge <feature>` self-merges at rc 0 with `Already up to date`, so **Option 1 reported a merge that never happened**; (2) `git worktree list \| grep <current-branch>` matched the main checkout's own row in an ordinary clone; (3) the same probe went vacuous on a detached HEAD, where `git branch --show-current` prints nothing and the pattern becomes the empty string; (4) the branch delete was ordered before the worktree removal, which git refuses. Fixed by replacing both prose sequences with one executable, extractable block in Step 5 that resolves every root before it mutates anything. |
| `finishing-a-development-branch`: no discard prompt | **DECLINED — #460** | Category error. Upstream stopped offering to discard *uncommitted work*; UberDev Option 4 deletes a *branch and its commits* behind a typed `discard` confirmation, reachable only under `--interactive`. Verified by grep: `finish-branch/SKILL.md` has no `git status --porcelain` and no `stash`, so the flow never inspects uncommitted work at all. Recorded permanently as `permanent_divergences[].interactive-discard-option` (§6). |
| `finishing-a-development-branch`: forge-agnostic PR creation | **DEFERRED — #460** | Not declined, blocked on a contract that does not exist yet. `gh` is not an implementation detail here: the `finish-branch → /review-pr → /merge` handshake runs on the `review-pr:pending` label (`REVIEW_PR_PENDING_LABEL` in `merge-pipeline/SKILL.md` Constants, read by `/merge`, cleared by `/review-pr`), and four literal `gh` invocations are shape-locked in `tests/finish-branch-auto-chain.test.sh`. Forge abstraction is RFC-tier work with no existing seam; a follow-up issue should own it. This row is the durable, grep-checkable record that it was adjudicated rather than missed. |
| Windows SessionStart hook declares `shell: "bash"` | **ADOPT — #461** | The upstream failure mode was silent: PowerShell parsed the quoted path as an expression, cmd.exe truncated on a metacharacter, and the bootstrap never loaded with no error. UberDev ships its own hooks, so this must be verified independently on the Windows CI job. |
| Library-wide prose compression across 11 skills | **SKIP** | Not skipped as unwanted — skipped as *already covered*. Seven components are `track`, so the compression arrives mechanically at their next re-baseline. The two surfaces where the token budget actually bites are the session-hook-injected `using-uberdev` files, which are `fork` and are governed by UberDev's own hook-diet work rather than by upstream's edits. Filing an issue for it would duplicate the re-baseline. |

One more follow-up fell out of the register itself rather than the upstream
delta: **#462** — backfill real `vendored_at_commit` values and in-file
provenance headers as each component is genuinely re-baselined. `"unknown"` is
honest; it should not be permanent.

#462 landed the mechanism and the first pin that could be proved from bytes:

- **`C-BASE`**, the converse of `C-HEADER` (§2.2). Before it, a `"unknown"`
  could be replaced by any 40-hex literal and all eight checks stayed green —
  measured on the pre-#462 tree, all 17 fabricated at once, exit 0. Provenance
  was assertable, not evidenced.
- **`skills/dispatching-parallel-agents` pinned at `e7a2d16`**, because its
  shipped `SKILL.md` is byte-identical to upstream at that commit — the pin
  needed a header, not a reconciliation. Its `stance_reason` was corrected in
  the same change: it had claimed a `'superpowers:' → 'uberdev:'` delta for a
  file that contains neither token, and its 33 measured lines are entirely
  upstream's own v6.2.0 prose compression, un-adopted here.

The remaining 16 were owned by three successors, split by what each one costs
rather than by component type: **#503** the five unpinned `track` skills (each
carries a real residual, and declaring it engages §4.1's `fork` trigger, so a
stance re-adjudication comes with it), **#504** the five unpinned `fork` skills,
and **#505** the six agents (no local clone of `claude-plugins-official` exists,
so their base needs a network content match — the watermark is a review point,
not a proven base).

**All three successors are resolved** (see the amendments below): #503 pinned the
five `track` skills, #504 the five `fork` skills, and #505 the six agents — the
last of those by blob identity against upstream rather than by inference.
`"unknown"` now stands on **none** of the 20 components.

---

## 8. The weekly drift job

`.github/workflows/vendor-drift.yml` runs `tools/vendor/vendor-drift.py` on a
weekly `schedule:` and on `workflow_dispatch:`. Workflow-level permission is
`contents: read`; the job additionally takes `issues: write`. Nothing else.

Contract:

1. Group components by upstream repo; resolve each repo's HEAD with
   `git ls-remote`.
2. **Fail loudly** if `ls-remote` exits non-zero, prints nothing, or prints a
   non-40-hex ref. "Upstream unreachable" must never render as "no drift" — that
   is the same silent-green class this RFC exists to kill, and it would be
   especially corrosive inside the very tool meant to detect it.
3. **Assert every declared `upstream_path` still resolves in the upstream tree**
   before diffing it. A prefix that matches nothing yields an empty changed-file
   list, which renders as a confident "no drift" every week forever; a path
   upstream has renamed or deleted is a finding, not silence. This one was found
   by running the reporter against the real upstreams, not by any stub.
4. Per component, diff `last_reviewed_upstream_commit..HEAD` restricted to the
   component's `upstream_path`.
5. Render **one** markdown report: component, stance, watermark → HEAD, changed
   files (capped, with a residual count), and declared divergences listed
   separately from raw drift.
6. Embed `<!-- uberdev-vendor-drift-v1 -->` plus a `drift-fingerprint:` line.
   Find the open tracking issue by that marker and **edit** it. Call
   `gh issue create` only when no such issue is open. Comment only when the
   fingerprint changed. No drift and no open issue ⇒ do nothing.

Failure modes, stated so they are not rediscovered:

- **`schedule:` only fires from the default branch.** The job is inert until this
  merges; `workflow_dispatch` from the branch is the pre-merge proof.
- **A new skill directory or agent file reds `C-COVER` by design.** Any PR that
  adds one must add its register entry in the same change. Sibling PRs adding
  agents will therefore red on rebase — that is the ratchet, not a regression.
- **A `track` component's digest lock reds on any local edit.** Intentional: the
  fix is to refresh the register in the same PR, or to move the component to
  `fork` with a written reason.
- **The register is never its own oracle.** No test may run the checker's
  `--refresh` path; the producer cannot validate itself.

---

## 9. Supersession

This RFC supersedes
`docs/uberdev/audits/2026-05-04-superpowers-vendor-audit.md` as the **live**
record of what UberDev vendors, from where, and under which stance. The audit
remains on disk as a dated snapshot and is not deleted; it is a pointer, not a
replacement, and another change is editing it concurrently.

From here on, the live record is `plugins/uberdev/vendor.json`, enforced by
`tools/vendor/vendor-check.py` in CI and refreshed by
`tools/vendor/vendor-drift.py` weekly.

---

## Amendment (2026-08-12, #457) — `writing-good-tests.md` adopted

> **Amends the `skills/test-driven-development` row of §4.2 and the
> `writing-good-tests.md` verdict in §7. Adds `C-REFS` to the check list in §8.**
> Status of this amendment: **Accepted, implemented.**

### What changed

`skills/test-driven-development` now ships upstream's `writing-good-tests.md` and
no longer ships `testing-anti-patterns.md`. `SKILL.md` points at it with
upstream's own markdown link, in upstream's position — replacing the local
`@`-ref, which force-loaded a 300-line reference on every TDD invocation against
the convention `skills/writing-skills` states in its own "Why no @ links" note.
The file set for the component is therefore **1:1 with upstream v6.2.0**.

### The stance stays `fork`, for a different reason

§4.2 recorded this component as `fork` because the **file sets diverged**. That
reason is now spent, and it is deliberately **not** replaced by `track`:

- `SKILL.md` is still at `e7a2d16` — upstream's own v6.2.0 prose compression
  (which folds "Why Order Matters" and the rationalisations table together) is
  un-adopted.
- `writing-good-tests.md` is at `3dcbd5c` (v6.2.0), adopted whole.

No single upstream commit is drop-in, so the tree is a **composite of two
upstream revisions**. `track` *promises* a digest-locked re-baseline (§4.4), so
claiming it here would be a false statement with no CI signal behind it —
`stance: fork` is exactly what makes `C-FILES` skip digests for this component.
`measured_diff_lines` moves **72 → 64**. **#462 still owns** the component
re-baseline and the eventual flip to `track`; adopting one file is not one.

The `Seven track, seven fork` tally in §4.2 is unchanged, as is §4.2's dated
`diff -r` measurement table and §7's adjudication record: both are historical
snapshots of what was measured and decided at the v6.2.0 tag, not live state.

### `C-REFS` — the channel this swap ran through

Every check in §8 reconciles the register against disk, or an in-file header
against the register. **None of them read what a shipped document says.** So a
`SKILL.md` could go on instructing agents to read a reference a vendor swap had
deleted, and the guard stayed green: the reference is not a register field, and
`fork` means its bytes are never digested. That is not hypothetical — it is the
exact surface this issue moved.

`vendor-check.py` therefore gains a ninth check:

> **`C-REFS`** — for every declared markdown file of every third-party
> component, every *relative* sibling reference (`@ref` or `](link)`, outside
> fenced blocks and inline code spans) must resolve on disk. Finding **zero**
> references anywhere is itself a failure, mirroring `C-HEADER`'s
> "the scan is vacuous" arm.

Two boundaries in that rule are load-bearing, and each is measured rather than
assumed:

- **Code spans are stripped, not just fences.** `skills/writing-skills` teaches
  the `@`-ref convention by quoting a **bad** example in backticks, and a scan
  that read it would report a dangling reference against a file that is
  deliberately describing what not to write. Without the strip the check is red
  on the shipped tree (4 references / 1 unresolved, against 3 / 0 with it).
- **An `@` carrying a local part is an address, not a reference.** An email, an
  npm-style `pkg@1.2.3` and a tag pin such as `repo@v6.2.0` all end in a dotted
  token that a naive `@`-scan reads as a filename — `x@y.com` yields `y.com`.
  A check that reds on a document referencing nothing is worse than no check, so
  a reference must be a standalone token.

`tests/vendor-provenance.test.sh` gains the matching falsifiability rows — a
deleted target with the register kept consistent, a misspelled target, the
resolving-corpus assertion, and the vacuity arm — each proved red for `C-REFS`
**and nothing else**.

---

## Amendment (2026-08-13, #503) — five bases pinned, four stances re-adjudicated, the digest lock moved to the pin

> **Amends §2.2's unpinned counts, §2.3's digest-lock rule, and the `track` rows
> of §4.2 for `receiving-code-review`, `verification-before-completion`,
> `execute-plan` and `write-plan`.**
> Status of this amendment: **Accepted, implemented.**

### What was measured

Each of the five components #462 left unpinned was diffed file-by-file against
`obra/superpowers@e7a2d16` — and, to make "that is the base" evidence rather than
assumption, against **every** upstream commit in each file's history. `e7a2d16`
is the closest blob for all six files; no earlier or later upstream revision
matches better, so no hunk in any of them is un-adopted upstream prose. The whole
residual is local, and every hunk is attributed:

| Component | Residual vs `e7a2d16` | Attribution |
| --- | ---: | --- |
| `skills/using-git-worktrees` | 17 | Brand rewrite of the global worktree location, plus a fail-loud fix to the path-resolution `case` in the creation snippet. |
| `skills/receiving-code-review` | 29 | One appended local section, *Multi-Reviewer Parallel Triage*. **No rebrand token in the file at all.** |
| `skills/verification-before-completion` | 30 | One appended local section, *Parallel Verification Dispatch*. **No rebrand token in the file at all.** |
| `skills/execute-plan` | 42 | Rename + rebrand + wave-ordered Step 2 and the UberDev sub-skill handoffs. |
| `skills/write-plan` | 99 | Rename + rebrand + the plan **format** this repo owns (wave decomposition, task headers, non-interactive handoff) + the reviewer prompt rewritten from a Task dispatch into an inline checklist. |

Two of those five carried the exact sentence #462 caught on
`skills/dispatching-parallel-agents`: *"the local delta is the namespace
rebrand"*, on a file containing no `superpowers:` token. The register's
`stance_reason` fields now state what was measured instead.

### The stance verdicts

`skills/using-git-worktrees` **stays `track`**. §4.1's fork trigger needs a
*permanent* local divergence or a rewritten behavioural contract; a bounded
correction inside a shell example is neither, and it is recorded as
`divergences[].worktree-location-failloud` with `permanent: false` precisely so
an equivalent upstream guard retires it rather than being reconciled against it.

The other four **flip `track` → `fork`**. Two carry a permanent local policy
section upstream has no equivalent for; two carry the wave contract that
`write-plan` emits, `execute-plan` walks and `uberdev:subagent-driven-dev`
parses — a two-sided interlock, so re-baselining either side alone breaks it.
`track` *promises* a digest-locked re-baseline (§4.4); claiming it for a
component whose upstream copy is not drop-in would be a false statement with no
CI signal behind it, the same reasoning the #457 amendment used.

Live tally after this amendment: **three `track`, eleven `fork`** among the 14
skill components. §4.2's table keeps its dated numbers.

### Why the flip did not cost coverage

Stated plainly, because it was the reason this work was split out of #462:
`C-FILES` enforced `sha256` only when `stance == "track"`, so an honest
re-adjudication to `fork` **deleted five digest locks**. Worse than a wash —
provenance improved (a real base, restated in a header `C-BASE` demands) at the
same instant the byte evidence behind it vanished. Measured on the pre-#503 tree:
appending a byte to any `fork`-stance file left `vendor-check.py` at exit 0, so a
pinned fork was a component whose shipped header named a base with nothing
holding its bytes to that claim.

The coupling was the defect. `stance` answers a **policy** question — do we
re-baseline from upstream? The digest answers an **evidence** question — have our
bytes moved since we recorded them? #503 ties the lock to the **pin**: recording
a base is the act that puts bytes under a digest, whatever the stance. An
unpinned `fork` stays unlocked, which is what keeps the distinction real.

Net effect on coverage, counted rather than asserted: **nine** components are now
digest-locked instead of seven, and the file count under lock rises from **14 to
27** — the five re-adjudicated components keep theirs, and the two previously
pinned forks (`systematic-debugging`, `test-driven-development`) contribute 13
files that nothing held before.

Two smaller repairs fall out of the same rule:

- `skills/systematic-debugging`'s two **file-scoped** `divergences[]` entries are
  now component-scoped (`"file": null`). A file-scoped entry is `C-FILES`'
  declared-change escape hatch, and it would have disarmed the new lock on
  exactly the two files whose local divergence is most worth watching. It was
  never needed: `C-FILES` compares our bytes against **our** recorded digest,
  never against upstream, so an upstream-relative divergence has nothing to
  excuse. `vendor-drift.py`'s `declared_files()` resolves the ref back to
  `permanent_divergences[].file`, so the weekly report still labels those files
  *declared* rather than raw drift.
- `skills/dispatching-parallel-agents` no longer references `namespace-rebrand`.
  #462 corrected that component's prose and left the machine-readable reference
  behind, so the register asserted a divergence its own `stance_reason` denied.

### What now enforces this

- `tests/vendor-provenance.test.sh` **V30** — a byte changed in a *pinned fork*
  file must red `C-FILES` by name. Run against the pre-#503 checker it reports
  `checker stayed GREEN on a mutated tree`, which is the defect stated in the
  row's own words. **V14** is its counter-case, holding an *unpinned* fork edit
  green so the widening cannot creep into "every fork is locked".
- **V31** — every digest-locked component actually records a `sha256` per file,
  asserted against the committed register rather than through the checker.
- **V32** — a `namespace-rebrand` reference on a *pinned* component must be
  witnessed by a brand token in that component's own bytes. This is the ratchet
  for the class #462 and #503 each found by hand. It is scoped to pinned
  components because an unpinned one has no proven base, so the claim is not yet
  checkable — the six agents are **#505**'s.
- **V25**, widened from `track` to the digest-locked set, so the escape hatch
  cannot be reopened on a pinned fork.
- **V5**'s exact header count moves 21 → 27 — and on to **38** with #504's five
  and #505's six landing alongside it in the same stack.

### What is left

Eleven components still read `"unknown"`: the five unpinned `fork` skills
(**#504**) and the six agents (**#505**). This amendment supersedes §7's
"the remaining 16 are owned by three successors" — #503 is done, and the sentence
should be read as naming the two that remain.

---

## Amendment (2026-08-13, #505) — the six agents pinned, by evidence

> **Amends §2.1's component counts, §2.2's unpinned counts, §4.3 in full, and
> §7's successor list. Adds `base_evidence` to the register schema, `C-EVIDENCE`
> to `vendor-check.py`, and `--verify-bases` to `vendor-drift.py`.**
> Status of this amendment: **Accepted, implemented.**

### The ceiling this hits, and how it gets past it

§2.2 is candid about `C-BASE`: it "does not — and offline cannot — prove a copy
really happened at that SHA; it makes the claim cost two coordinated lies
instead of one." For the skill directories #503 left unpinned that ceiling is
tolerable, because `obra/superpowers` is on disk and a reviewer can diff. For
the six `claude-plugins-official` agents it was not: **no clone of that upstream
exists anywhere in this repository**, so no reviewer could have compared the
bytes even by hand. Both lies were free.

The recovery is a measurement rather than a stronger assertion. For each
component, `git rev-parse <vendored_ref>:<path>` in **this** repository yields
the blob oid the file had when it was vendored; `git rev-parse
<candidate>:<upstream_path>` in a blobless scratch clone of upstream yields the
blob oid upstream holds at a candidate commit. **The two object ids are equal
for all six.** Git object ids are content addresses, so equality is byte
identity — not similarity, not a date match, not a plausible ancestor.

| Component | Base | Blob (both sides) |
| --- | --- | --- |
| `agents/code-reviewer.md` | `4ca561fb…` | `462f2e01b89e6339994c071c765dcb4dd380c869` |
| `agents/comment-analyzer.md` | `4ca561fb…` | `e214620a3fa348c550bfca1f8d23ceaec39bfe57` |
| `agents/pr-test-analyzer.md` | `4ca561fb…` | `9b2de05b90e74f828e58a8874ed17f6eb9372db3` |
| `agents/silent-failure-hunter.md` | `4ca561fb…` | `b8a8dfa41e18ef6ac801ae64be38b2508aa04f44` |
| `agents/type-design-analyzer.md` | `4ca561fb…` | `f720f0fcec856560cdddb6b030ac7e64af159438` |
| `agents/code-simplifier.md` | `ceb9b72b…` | `05e361b4ef1b688203251989707f8a924a9ed266` |

`vendored_ref` is shared (`bae840ae…`, the vendoring commit in this repo). The
five `pr-review-toolkit` paths have 1–2 commits of upstream history each, and
`4ca561f` is the revision current at `vendored_on: 2026-04-27`; `ceb9b72` is the
**only** commit that has ever touched the standalone `code-simplifier` path.

### `base_evidence` — the record, and why it is a field rather than prose

```jsonc
"base_evidence": {
  "method": "blob-identity",
  "vendored_ref": "bae840ae05a07fe47c9999843364f5bf1aa4a3c1",
  "blobs": { "code-reviewer.md": "462f2e01b89e6339994c071c765dcb4dd380c869" }
}
```

`blobs` is keyed by the component's own `files[]`, which is what makes it
generalise to the multi-file skill components #503 and #504 will pin. Recorded
in the register rather than written up here because a paragraph rots silently
and a field can be re-derived. Three things now re-derive it, split by cost:

- **`C-EVIDENCE`** (`vendor-check.py`) — offline SHAPE. A known `method`, a
  40-hex `vendored_ref`, a `blobs` map whose key set **equals** the component's
  `files[]` with 40-hex values, and a 40-hex `vendored_at_commit` behind it.
  It validates what is *declared* and refuses over an empty set; it deliberately
  does **not** demand universal coverage, because that would red every
  `obra/superpowers` component — none of them carries an evidence record — and a check that reds on
  somebody else's unstarted work gets suppressed. No `git`, no `subprocess`, no
  socket — that is what keeps §2.3's offline guarantee structural.
- **`tests/vendor-provenance.test.sh` V35/V36/V36b** — the offline HALF of the
  identity, re-derived with `git rev-parse` against this repo's own history. It
  **fails rather than skips** in a shallow clone (the ubuntu shape-check job
  therefore checks out with `fetch-depth: 0`): a proof that quietly stands down
  in CI is the vacuous green this whole ratchet exists to refuse.
- **`vendor-drift.py --verify-bases`** — the UPSTREAM half. A blobless scratch
  clone per upstream, `git rev-parse <base>:<upstream_path>`, compared against
  the recorded oid. It is a network operation, so it runs in
  `vendor-drift.yml` (before the reporting step) and never in the test suite.
  An unreachable remote exits 1, a malformed record exits 2, and an empty
  evidence set exits 2 rather than certifying nothing.

### A deliberate departure: the six new headers cite no repository path

The 21 existing provenance headers are free to reference sibling files. These
six are not, and the constraint is external: all six agents are in
`tools/prkit/manifest.txt`, `tools/prkit/rewrite.sh` applies a blanket
`uberdev` → `prkit` rewrite to every byte it copies, and the generated tree
ships no `licenses/` directory. A repo-relative path in one of these headers
would therefore be rewritten into a path that does not exist downstream, and the
token guard in `tools/prkit/verify.sh` fails the generation gate on the word
`uberdev` outright. The headers name the **SPDX identifier** instead of pointing
at the licence file, and `tests/prkit-verify.test.sh` carries a row that keeps
the decision guarded rather than remembered.

That leaves a **pre-existing** compliance gap this change deliberately does not
widen: `TheFJK/prkit` publishes six Apache-2.0 agents with no licence text of
its own. Closing it means adding the two licence files to
`tools/prkit/manifest.txt`, which moves the count-lock 42 → 44 and — because
`published-check.py` requires manifest ≡ copyset — demands a real prkit
republication. That is its own change, and it is filed separately.

### What is deliberately NOT done here

- **Watermarks are untouched.** `last_reviewed_upstream_commit` still reads
  `920824c3…` on all six. §2.2's split between "what we copied from" and "what a
  human has triaged against" is the whole point, and advancing a watermark is
  the recorded act of having looked.
- **No stance is re-adjudicated.** All six stay `fork`; §4.3's *reason* is
  corrected because it was measurably false, not its verdict.
- **Upstream `ce721c1` (2026-04-28) is not adopted.** It adds a
  `## When to invoke` section to four of the five `pr-review-toolkit` agents
  that this repo has never carried. A genuine finding for the weekly drift job,
  recorded here so it is visibly deferred rather than missed.

### What is left

Nothing. #503's five `track` skills, #504's five `fork` skills and these six
agents land in one stack, so **no component reads `"unknown"`** and §7's
successor list is closed. `C-EVIDENCE` still covers only what declares
`base_evidence`; extending that record to the fourteen `obra/superpowers`
skill components — none of which carries one — is the next piece of work, not a
residual of this one.

---

## Amendment (2026-08-13, #509) — the SDD parallel-implementer divergence, adjudicated

> **Amends the `skills/subagent-driven-dev` row of §4.2 and the table in §6, and
> tightens §2.4's `divergences[]` shape. Adds `C-DIVREF` to
> `vendor-check.py`'s check catalogue.**
> Status of this amendment: **Accepted, implemented.**

### What changed

Upstream's `subagent-driven-development/SKILL.md` carries an explicit
prohibition — never dispatch multiple implementation subagents in parallel,
because they conflict. UberDev's `skills/subagent-driven-dev` inverts it, and
does so as its **stated core principle**: implementers within one wave dispatch
in parallel into a single shared feature-branch worktree, over a strictly
disjoint per-task file partition, with the controller as the only process that
runs git.

The verdict is **deliberate, not drift** — the same call §6 already records for
`review-pr-parallel-by-default`, and for the same reason: throughput the
sequential shape cannot buy, bounded by a precondition rather than by hope. It
is therefore registered rather than reverted, and §6 gains the
`sdd-parallel-implementer-waves` row.

§6 also gains the row it was already missing. `find-polluter-fail-loud` has been
in `permanent_divergences[]` since #430/#476 and was never written into the
table — the §6 list held **six** rows against the register's **seven**. That
asymmetry is what made the SDD omission survivable: a reviewer reading §6 to
decide "was this adjudicated?" was reading a list nothing kept honest.
`tests/vendor-provenance.test.sh` V31 now reconciles the two by id, in both
directions, over an anti-vacuity floor so a broken parse cannot report
agreement.

The `Seven track, seven fork` tally in §4.2 is unchanged; so is its dated
`diff -r` measurement table, `measured_diff_lines`, both commit fields and the
review date. The parallel-wave behaviour being adjudicated was already shipping,
and nothing here re-baselines the component: `stance: fork` is exactly what makes
the local `SKILL.md` edits below move no digest, and the component's file **set**
is untouched.

### The precondition now has a producer and a refusal

§4.2's stance reason and the old Pattern-B paragraph both leaned on a plan
declaration that no planner emits. The partition is real, but it was spelled
under a name nothing produced, so the "zero races" claim rested on prose.

It now rests on three things, each of which exists:

1. **Produced** — `agents/plan-writer.md` emits each task's
   `Owns (file allowlist)` field plus the plan's `## Execution Waves` summary.
2. **Reviewed** — `agents/plan-reviewer.md` Check 2 requires same-wave `Owns`
   lists to be strictly disjoint and treats any file appearing in two of them as
   a critical finding.
3. **Refused at dispatch** — `sdd_assert_wave_disjoint` compares the wave's
   prepared implementer `allowed_paths` for equality *and directory
   containment*, and `sdd_launch_prepared_batch` calls it **before** it launches
   anything. An overlapping wave exits `3`, a wave whose implementers declare no
   ownership exits `2`, and in both cases **zero** children are dispatched. An
   overlap is a plan defect and routes into the BLOCKED ladder — never "dispatch
   anyway".

Directory containment is the boundary that is easy to get wrong and is therefore
stated: a task owning a directory and a sibling owning a file inside it is a
collision that a plain set intersection reports as disjoint.

Today's `solve-fleet` route dispatches exactly **one** worktree-isolated
implementer per issue, so it never reaches a parallel wave at all; the wave shape
is exercised by the in-session SDD controller. That is a description of current
behaviour, recorded so the next reader does not have to re-derive it — not a
promise about it.

### `C-DIVREF` — the channel this omission ran through

`check_files()` short-circuits every component whose stance is not `track`, so a
`fork`'s `divergences[]` is never read. And before this change **no check
anywhere** resolved a `components[].divergences[].ref` against a
`permanent_divergences[].id`. The single resolution in the repo lived in
`tests/finish-branch.test.sh` F14 and was scoped to one component; the other
seventy-four could reference a record that does not exist, or lose the record
under a live reference, with every check green.

`vendor-check.py` therefore gains an eleventh check:

> **`C-DIVREF`** — every `components[].divergences[].ref` resolves to a declared
> `permanent_divergences[].id`, for every component regardless of origin or
> stance.

Three boundaries are deliberate:

- **No vacuity arm.** `C-HEADER`, `C-BASE` and `C-REFS` each fail on an empty
  corpus, because for them zero findings means the scan broke. Here an empty
  `divergences[]` corpus is a legal register state, and a `found == 0` failure
  would red a tree that has simply declared nothing.
- **A `ref` is mandatory, which tightens §2.4.** That section's phrase "plus any
  component-local entries" could be read as licensing an entry with only a
  `file` and no pointer. `C-DIVREF` closes that reading: every entry must name an
  adjudicated record. Measured on the tree at adoption, all 27 entries across the
  register already carry a `ref` and the only keys in use are `ref` and `file`,
  so this costs nothing today and buys the thing this issue is about — a
  divergence cannot be declared to the tooling without first being written down
  as a decision. A component-local `file` stays welcome; it just rides on a
  `ref`, exactly as `skills/subagent-driven-dev`'s new entry does.
- **F14 stays.** Its scope is now covered by `C-DIVREF`, but its
  `interactive-discard-option` *record* assertion — that the entry exists, is
  permanent, and is scoped to `skills/finish-branch` — is still the only thing
  pinning that entry, and `C-DIVREF` does not pin records, only pointers.

`tests/vendor-provenance.test.sh` gains the matching falsifiability rows: a live
reference misspelled while the record stays, the record deleted under a live
reference, and an entry carrying a `file` with no pointer at all — each proved
red for `C-DIVREF` **and nothing else**, and each driven through the full checker
rather than `--only`, because an unknown `--only` id prints the wanted id inside
its own `known:` list and would report PASS against a checker that has no such
check.

The dispatch-time refusal gains its own falsifiability fixture in
`tests/sdd-routed-lifecycle.test.sh`, launched under both shells: measured with
the guard call removed, the identical-ownership case returns rc `0` with two
children dispatched under bash and rc `1` with no diagnostic under zsh, so the
rows assert a refusal that only the guard can produce.

---

## Amendment (2026-08-13, #511) — the 6.3.0 delta adjudicated

> **Amends §7 of this RFC: §7's table is the dated adjudication at the `v6.2.0`
> tag and stays frozen; this block adjudicates the 6.2.0 → 6.3.0 delta and
> advances the review point on the 14 `superpowers` components.**
> Status of this amendment: **Accepted, implemented.**

**No behavioural upstream content is imported by this amendment's PR.** Each item
below gets a verdict; every ADOPT names a filed issue, and the port is that
issue's PR.

### The review point

The 14 `superpowers` components now record
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797` as their
`last_reviewed_upstream_commit`, reviewed on `2026-08-13`. That commit is the
peeled `v6.3.0` tag of `obra/superpowers`, and the same value is recorded once
more at `upstreams.superpowers` as `last_reviewed_commit` /
`last_reviewed_release` / `last_reviewed_on`, so the upstream carries its review
point in one place and the components are checked against it.

Reproducible without a tag lookup: at adjudication time upstream's default-branch
HEAD resolved to that same commit.

```
git ls-remote https://github.com/obra/superpowers 'refs/tags/v6.3.0*'
  86babb696875227929e85420f287d6309374b93f  refs/tags/v6.3.0
  b36e0829c6d0140e93cfef2ca599b1b07d4a7797  refs/tags/v6.3.0^{}
git ls-remote https://github.com/obra/superpowers HEAD
  b36e0829c6d0140e93cfef2ca599b1b07d4a7797  HEAD
```

`upstreams.pr-review-toolkit` gains `last_reviewed_commit` and
`last_reviewed_on` at its components' existing values, and deliberately **no**
`last_reviewed_release`: it is a plugin inside a monorepo with no release
vocabulary, and inventing a label would be exactly the fabrication this register
exists to prevent. The six agent components are byte-unchanged — that upstream
contributed zero paths to this delta.

### What was measured

`diff -rq` between the two plugin-cache trees,
`claude-plugins-official/superpowers/6.2.0` and `.../6.3.0`. Thirty-seven
differing entries; **thirteen** of them fall under a declared `upstream_path` and
are the corpus of the table below. The remaining twenty-four are the aggregate
`SKIP` row.

The cache is `claude-plugins-official`'s repackaging of upstream, not upstream
itself, so it is corroborated rather than trusted. Five files were fetched from
`raw.githubusercontent.com` at the peeled tag and compared by sha256 against the
cache copy — `writing-skills/render-graphs.js`, `writing-plans/SKILL.md`,
`subagent-driven-development/SKILL.md`, `brainstorming/SKILL.md` and
`using-superpowers/SKILL.md` — and all five matched. Every "we already have
this" claim in a reasoning cell below is backed by a probe against UberDev's own
bytes under `plugins/uberdev/skills/`, never against the cache.

Two upstream files bundle two separable decisions each, so they take two rows:
`brainstorming/SKILL.md` and `writing-skills/render-graphs.js`. Splitting them is
the point of adjudicating rather than importing — in both cases one half is
adoptable and the other is not.

### The verdicts

| Upstream item | Verdict | Reasoning |
| --- | --- | --- |
| `brainstorming/SKILL.md`: ceremony tiering (Spike / Bounded / Architectural) and the one-way ratchet | **ADOPT by PORT — #532, shipped** | The tiering itself was already here: `solve-pipeline` classifies every issue `trivial` / `small` / `medium` / `large` through `lib/solve_triage.py`, and `/dev` is the shipped spike lane. The **ratchet** was not — a grep of `solve-pipeline/SKILL.md` and `solve_triage.py` for re-classification or tier escalation returned nothing. Tier was computed once, at dispatch, from issue-body signals and never revisited, so a solver that discovered mid-run that its issue was cross-cutting finished on the lighter workflow and nothing recorded that it was mis-triaged. **Shipped** as an upgrade-only ratchet: `classify()` raises `raw_tier` from an `uberdev:tier-<to>` label and records `escalation-label:<tier>` in `matched_rules` beside the computed token; a solver reports the discovery on its structured return (`escalatedTier` / `escalationReason`), where it is validated, clamped and audited rather than trusted; and the four dispatch briefs plus `solve-pipeline/SKILL.md` state the rule, with upstream's anti-label-shopping red flags carried by `solve-pipeline/SKILL.md`. Upgrade-only by construction, twice over — `trivial` is not an addressable escalation target, so the vocabulary cannot name a downgrade *to* the bottom rung, and the comparison only ever raises, so a label naming a tier at or below the computed one is inert rather than an error. Both clauses are load-bearing: `uberdev:tier-small` on an issue that computes `large` is nameable, and it is the comparison that makes it a no-op (`tests/solve-triage.test.sh` E2). **Deliberately deferred, owned by #571**: the escalation buys back no ceremony in the run that reported it. `DESIGN_TIERS`, the `workflow.js` design gate and CB1's pre-dispatch agent projection are untouched, because CB1 commits the fleet's agent budget *before* dispatch and re-entering research, spec and plan for an in-flight issue would spend design agents no ceiling ever counted. What the solver raises is its own bar; the tier itself moves on the next dispatch. |
| `brainstorming/SKILL.md`: approval gate restated as universal ("Too Simple To Need A Design" becomes "Too Simple To Need Approval") | **DECLINED** | Standing decision, not an open question. `permanent_divergences[].brainstorm-no-approval-gates` (§6) records that UberDev rejects upstream's HARD-GATE and per-section approval checkpoints; quality comes from parallel research and always-on reviewer agents. §6 divergences are never reconciled, so a new upstream phrasing of the same gate changes nothing. |
| `brainstorming/visual-companion.md`: launcher invoked through `bash` | **ADOPT by PORT — #533** | The changed block is Copilot CLI's, which UberDev does not ship. The defect it fixes is shipped: every UberDev launch block, including **Claude Code (Windows)**, invokes `scripts/start-server.sh` bare and depends on the shebang plus a surviving exec bit. CI runs a `windows-latest` job. Port the `bash` prefix and upstream's stated reason, not the block. |
| `finishing-a-development-branch/SKILL.md`: worktree removal refused, ask the human | **DECLINED** | Already held, and held more strongly. `finish-branch` removes without `--force` in merge mode and leaves a worktree holding uncommitted work standing with a `WARNING` naming it. Upstream's remedy is a three-option question to a human; UberDev's `--turbo` contract is unattended, so asking would stall a run that has no one to answer. The safety invariant upstream is protecting — never `--force` on your own initiative — is already the shipped behaviour. |
| `requesting-code-review/code-reviewer.md`: "You Do Not Dispatch Subagents" | **ADOPT by PORT — #530** | This file **is** shipped, and a grep of the component for any never-spawn contract returns nothing. |
| `subagent-driven-development/SKILL.md`: the no-subagents contract (dispatch bullet and red-flag row) | **ADOPT by PORT — #530** | Contract drift, not absence: `agents/implementation-worker.md` and `lib/child-dispatch.sh` both already state the leaf-worker rule, while the vendored prompt templates that SDD actually pastes into dispatches carry no trace of it. One contract, several uncompared copies. |
| `subagent-driven-development/SKILL.md`: "Rulings, not stalls" plus four named stop conditions | **ADOPT by PORT — #530** | Split verdict inside one item. The **autonomy** half is already UberDev policy — `--turbo` is unattended by contract and `/goal` carries its own circuit breakers — so there is nothing to adopt there. The **ledger** half is absent: no `Ruling:` convention exists anywhere in the component, so an unattended solver that overrides its plan reports that in prose, if at all. Adopt the structured `Ruling: <what> — <why> — <cost if wrong>` line and its exhaustive end-of-run roll-up. |
| `subagent-driven-development/SKILL.md`: batched same-shape dispatch, bounded waits, preflight scan-table | **DEFERRED** | Real and wanted, but written against Codex's `wait_agent` event subscription and its V1/V2 lifecycle. UberDev's solvers run in the Workflow runtime (RFC 0015), whose wait surface differs. Re-adjudicate against that surface rather than porting guidance whose cost model does not hold here. |
| `subagent-driven-development/implementer-prompt.md`: "You Do Not Dispatch Subagents" | **ADOPT by PORT — #530** | Shipped file, same zero-hit grep as the row above. Upstream's stated reason is empirical: every reviewer a worker spawned duplicated the task review the controller dispatched anyway. |
| `subagent-driven-development/re-review-prompt.md`: no-subagents contract | **SKIP** | Not shipped. The component's files are `SKILL.md`, `implementer-prompt.md`, `code-quality-reviewer-prompt.md` and `spec-reviewer-prompt.md`; there is no local file to review. The contract itself is adopted where UberDev does have a surface for it, under #530. |
| `subagent-driven-development/task-reviewer-prompt.md`: no-subagents, evidence-legibility and batched-dispatch checks | **SKIP** | Not shipped, per the same file list. |
| `using-superpowers/SKILL.md`: pointer to `references/hermes-tools.md` | **SKIP** | Adopting the pointer would red `C-REFS`, which requires every relative sibling reference in a declared markdown document to resolve on disk. UberDev ships no `hermes-tools.md`, so the adoption would be a dangling reference by construction. |
| `using-superpowers/references/codex-tools.md`: multi-agent V1/V2 tools, waiting, model routing | **SKIP** | Not shipped — UberDev's reference set is `configuration.md`, `copilot-tools.md` and `gemini-tools.md`. The transferable half is the waiting guidance, adjudicated as `DEFERRED` two rows above rather than twice. |
| `using-superpowers/references/hermes-tools.md` (new file) | **SKIP** | Not shipped; UberDev does not target the Hermes harness. |
| `writing-plans/SKILL.md`: the plan template gains a `Spec:` pointer | **ADOPT by PORT — #531, shipped** | Absent locally at adjudication. It mattered more here than upstream: UberDev's medium and large pipeline writes spec and plan as separate artifacts and hands the plan to a solver in a fresh worktree, where nothing named the spec the plan argues from. One correction to the stance this row named at adjudication time: the register records `skills/write-plan` as `fork`, not `track` — #503 re-adjudicated it — but the digest lock reaches it just the same, through its recorded base (#503 moved the lock to the pin), so adoption redded `C-FILES` until the recorded `sha256` was refreshed in the same PR. Shipped across all three carriers of the one plan-header contract, not just the skill: `skills/write-plan/SKILL.md`, `agents/plan-writer.md` (the copy the routed medium and large pipeline actually emits from) and `skills/orchestrator/SKILL.md`'s in-main fallback enumeration; `tests/orchestrator-plan-flatten.test.sh` `F10` now compares them so they cannot drift apart again, and `F10c` pins the hunk boundary by asserting that upstream's adjacent `## Global Constraints` section — same release, never adjudicated — stayed out. The **reader** half is deliberately out of scope: teaching `skills/execute-plan` and `skills/subagent-driven-dev` to resolve the pointer, and to record upstream's *"A plan with no reachable spec gets a ledger note saying so — rulings made without one are provisional"* note, is filed as **#568** and needs its own verdict row here. |
| `writing-skills/render-graphs.js`: `execSync('which dot')` becomes `execFileSync('dot', ['-V'])` | **ADOPT by PORT — #531, shipped** | A genuine portability fix that applied verbatim: the shipped copy still shelled out to `which`, which is not a command on Windows, and CI runs a Windows job. `skills/writing-skills` is `track`, so the same `C-FILES` refresh obligation applies. |
| `writing-skills/render-graphs.js`: CommonJS becomes ESM | **DECLINED** | The worked example of why §7 adjudicates instead of importing — and of checking the hypothesis before recording it. The expected finding was a hard `SyntaxError`, since no `package.json` governs `plugins/uberdev/`. **Measured, it is not:** Node 20.19.2 ships module-syntax detection unflagged, and upstream's 6.3.0 bytes ran unmodified at the UberDev path. The real cost is narrower and still disqualifying — an **undeclared runtime floor**. The identical canary run as `node --no-experimental-detect-module` exits 1 with *"To load an ES module, set `type: module`"*, and this repo declares no `engines` field and pins no CI `node-version`. Adopting the module system would raise the floor to Node 20.19 / 22.7 for a tree that is otherwise CommonJS throughout, buying nothing. Take the `execFileSync` half, leave the `import` half. |
| Everything outside every declared `upstream_path` | **SKIP** | Measured, not omitted: `.devin-plugin/` and `.hermes-plugin/` (new harnesses), six harness manifests, `.gitignore`, `.version-bump.json`, `README.md`, `RELEASE-NOTES.md`, `package.json`, `scripts/bump-version.sh`, `scripts/sync-to-codex-plugin.sh`, new `docs/superpowers/plans/` and `docs/superpowers/specs/` material, and new `tests/devin/`, `tests/hermes/`, `tests/version-bump/` and `tests/writing-skills/` trees. `.orphaned_at` exists only in the 6.2.0 cache — a cache artifact rather than an upstream path, so it is not adjudicated. |

One question the issue asked explicitly, answered by measurement: **the fix-round
ladder did not move.** #459 adopted the resume-plus-breaker half at 6.2.0, and
6.3.0 leaves rounds, cap and escalation identical — the ladder text appears only
on unchanged context lines in the diff. There is nothing to adopt.

### The seven untouched components

Seven of the 14 `superpowers` components have **no path in this delta at all**.
Their watermark advance records "reviewed, empty delta" rather than an
unevidenced claim, and naming them is what makes that difference checkable:

`skills/dispatching-parallel-agents`, `skills/execute-plan`,
`skills/receiving-code-review`, `skills/systematic-debugging`,
`skills/test-driven-development`, `skills/using-git-worktrees`,
`skills/verification-before-completion`.

### What the advance does and does not claim

It is a **review point**, not a proven base.

- `vendored_at_commit` does **not** move. §2.2's two-commits-per-component split
  is exactly this distinction: `C-BASE` requires an in-file
  `Vendored from …@<sha>` witness before a base may be pinned, and no such
  header was written here. Base-pinning stays owned by #503, #504 and #505.
- `measured_diff_lines` and the §4.2 / §4.3 stance tables stay at their `v6.2.0`
  measurement. They are deliberately untouched, and #534 owns labelling each
  measurement with the revision it was taken at — the register and §4.2 already
  disagree on two components, which is the defect that issue exists to close.
- Nothing under `plugins/uberdev/skills/` changes in this PR. Every ADOPT row
  above is a filed issue, and the port is that issue's PR.

`tests/vendor-provenance.test.sh` gains the matching rows: **V30** (every
component's watermark equals its own upstream's review point), **V31** (every
labelled review point is named by this RFC, with a vacuity arm so deleting the
labels reds instead of passing), **V32** (every verdict row above carries exactly
one token and every ADOPT cites an issue) and **V33** (a component sitting at its
upstream's review point may be reviewed later than it, never earlier).
`tests/docs-accuracy.test.sh` gains T3.6, which is what stops a future watermark
advance from landing with no verdict table behind it.

---

## Amendment (2026-08-14, #534) — every measurement carries its basis

> **Amends §4.2 and §4.3 by labelling each table with the revision, date and
> counting rule its numbers were measured under; amends the *What the advance
> does and does not claim* subsection of the 2026-08-13 (#511) amendment, which
> reserved this work for #534; and restructures `measured_diff_basis` in the
> register from free prose into a required record. No table cell is edited.**
> Status of this amendment: **Accepted, implemented.**

### What the number actually depends on

`measured_diff_lines` is a diff count, and a diff has **two** operands: an
upstream revision, and a set of local bytes. The register recorded a bare
integer — naming neither — while §4.2 and §4.3 carried a second copy of the same
numbers, and nothing compared the two.

That makes drift the steady state rather than a possibility. Both operands move,
on unrelated schedules: upstream ships a release, and any local edit to a
vendored file changes our half. So the two copies come apart during ordinary
work, and when they do, a bare integer cannot say whether the RFC is stale, the
register is stale, or both numbers are honest measurements taken at different
points. Two components had already reached that state with every check green —
`skills/systematic-debugging` (register 195, §4.2 83, after the local
`find-polluter.sh` additions of #430 and #476) and
`skills/test-driven-development` (register 64, §4.2 72, after the
`writing-good-tests.md` swap of #457). Both had moved for good reasons. Neither
copy could say so.

`measured_diff_basis` is therefore a **required record** on every component that
records a measurement: `upstream_rev` and `upstream_tree` name the upstream
operand, `uberdev_rev` names the local one, `measured_on` dates the act, and
`method` states the counting rule. The number becomes self-describing, so two
measurements taken at different points are legible as exactly that instead of as
a contradiction.

### The cache is not upstream

The 14 `superpowers` measurements below were taken against the
`claude-plugins-official` plugin cache at `superpowers/6.3.0` — the same artifact
the 2026-08-13 (#511) amendment measured its delta over, and corroborated rather
than trusted for the reason that amendment gives.

The register keeps the two apart instead of collapsing them into one field:
`upstream_rev` names the revision that tree is corroborated to repackage
(`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`, the peeled `v6.3.0` tag), while
`upstream_tree` records that the cache is a repackaging of upstream, not upstream itself.

Re-measuring the 14 directly from `obra/superpowers` at the peeled tag would
retire that distinction rather than record it — and it is a network read, which
belongs to `tools/vendor/vendor-drift.py` (§8) and to its own issue, not to an
offline check. Until it happens, the honest statement is the one the record now
makes: a measurement against a corroborated repackaging, said out loud.

### Why §4.2 and §4.3 are not renumbered

Both tables are **dated snapshots at their own bases**, and this amendment edits
no cell in either. §4.2's numbers are what was measured at the `v6.2.0` tag;
§4.3's are what was measured at each component's recovered base. Now that each
table declares that basis and the register declares its own, the surfaces no
longer make competing claims about one measurement — they make separate,
labelled claims about different ones, which is what they always were.

§4.2's `**Measured:**` line dates that measurement `2026-08-10`, and the basis
for that date is this RFC's own `Created` field: it is the only date the document
records for the work that produced the table, and the table landed in commit
`231891f74821d9108639a0eaa01ea1a5b5a82f6e` on 2026-08-11, which corroborates it.
An asserted date with a stated basis is the whole point of this amendment; an
asserted date with none was the defect.

§4.3's label deliberately invents **no release tag**. Its upstream is a plugin
inside a monorepo with no release vocabulary — `upstreams.pr-review-toolkit` in
the register already records why it carries no `last_reviewed_release` — so the
label names the per-row `Base` column, which is the honest revision that table
already carries.

### §4.2's stated counting rule, measured

§4.2's prose declares that its counts *include* the provenance-header lines
UberDev adds. Measured against the `claude-plugins-official` cache tree at
`superpowers/6.2.0`, that rule reproduces exactly **one** of its 14 rows, and the
other 13 miss it in two distinct ways:

- **1 row** reproduces under the stated rule, headers included: `writing-skills`
  (367).
- **9 rows** reproduce only with the provenance-header lines **excluded**:
  `brainstorm`, `dispatching-parallel-agents`, `execute-plan`,
  `receiving-code-review`, `requesting-code-review`, `using-git-worktrees`,
  `using-uberdev`, `verification-before-completion` and `write-plan`. Each is
  off by exactly its header count.
- **4 rows** reproduce under neither, because their bytes have moved since:
  `finish-branch` (734 recorded; 1067 included / 1066 excluded),
  `subagent-driven-dev` (1064; 1333 / 1332), `systematic-debugging` (83;
  304 / 293) and `test-driven-development` (72; 64 / 62).

**1 + 9 + 4 = 14.** §4.2 is frozen, so this correction lives here rather than in
an edit to its prose — the same idiom §4.3 already uses when it records that the
reason written down there was measurably wrong for five of its six rows.

`test-driven-development` is worth naming twice, because it is the one row that
*looks* like a match and is not: 64 is the number the **register** carried after
the #457 swap, while §4.2's frozen cell reads 72. Read the two copies as one and
the rule appears to hold for it; read them as what they are — two measurements of
different byte sets — and it does not. That confusion, in miniature, is the
defect this amendment closes.

### The 14 skills re-measured at the review point

The register's 14 skill measurements now sit at the review point #511 already
advanced them to, so the numbers describe the bytes actually shipped. This table
is **deliberately a third `Diff lines` table**: it carries its own label, which
means the new numbers land in a *checked* copy rather than in a third
uncompared one.

**Measured:** `superpowers` at `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`, on 2026-08-14, counting `<` plus `>` lines including the provenance headers.

| Component | §4.2 cell | Register before | Diff lines |
| --- | ---: | ---: | ---: |
| `skills/brainstorm` | 2255 | 2255 | 2365 |
| `skills/dispatching-parallel-agents` | 33 | 33 | 34 |
| `skills/execute-plan` | 50 | 50 | 51 |
| `skills/finish-branch` | 734 | 734 | 1077 |
| `skills/receiving-code-review` | 41 | 41 | 42 |
| `skills/requesting-code-review` | 228 | 228 | 243 |
| `skills/subagent-driven-dev` | 1064 | 1064 | 1453 |
| `skills/systematic-debugging` | 83 | 195 | 304 |
| `skills/test-driven-development` | 72 | 64 | 64 |
| `skills/using-git-worktrees` | 206 | 206 | 207 |
| `skills/using-uberdev` | 174 | 174 | 176 |
| `skills/verification-before-completion` | 49 | 49 | 50 |
| `skills/write-plan` | 123 | 123 | 125 |
| `skills/writing-skills` | 367 | 367 | 373 |

The two rows the issue reports are settled **by measurement**, not by editing a
frozen cell: `systematic-debugging` reads 304 and `test-driven-development` 64,
both at `b36e0829…`, while §4.2 keeps 83 and 72 at `v6.2.0`. Different bases,
both labelled, correctly not compared.

`brainstorm` (2365), `requesting-code-review` (243), `subagent-driven-dev` (1453), `write-plan` (125) and `writing-skills` (373) were **re-measured on 2026-08-16**
against the same upstream rev. Their first figures were taken on a tree that did not yet carry this stack
changes to them — the two adopted 6.3.0 hunks (the plan-header `Spec:` pointer
and the `render-graphs.js` `execFileSync` change) among them. Those hunks
and this measurement landed in the same stack, so each figure was correct for
the tree it was taken on and neither was correct for the combined one. The
upstream side did not move; only the local bytes did, and the register's
`measured_diff_basis` records the `uberdev_rev` the new numbers were taken at.

The table carries **no stance column**, on purpose. A stance is a decision, not a
measurement, and nothing in this repository reconciles a stance cell in this
document against the register — §4.2's own stance cells are already superseded
for four components by the 2026-08-13 (#503) amendment. Restating one here would
manufacture a fresh uncompared copy of exactly the kind this amendment exists to
retire. `plugins/uberdev/vendor.json` carries the live stance, as §4.2's own
superseded-rows note says.

### The six agent numbers are labelled, and they re-derive offline

The six `agents/*` numbers are **unchanged**. Their existing free-prose basis
moved verbatim into `method` — nothing recorded was discarded — and each gained
`upstream_rev`, `upstream_tree`, `uberdev_rev` and `measured_on` around it.

They were re-derived, and the boundary is worth stating precisely rather than
implying, because it is narrower than it looks. Re-deriving one needs **no
network at all**: `base_evidence.blobs` pins the upstream blob's oid and
`base_evidence.vendored_ref` names the commit it resolves at, both inside this
repository, and `tests/vendor-provenance.test.sh`'s V35 row already asserts —
offline — that every one of those oids re-derives from git here. Reading each
blob out with `git cat-file -p` and diffing it against the shipped file
reproduces all six recorded counts exactly, at the base each row records. What
does need a network read is a **different act**: re-measuring against a revision
*newer* than the one `base_evidence` pins. That is
`tools/vendor/vendor-drift.py`'s job (§8), not this amendment's, and conflating
the two would have written down a false reason for a true decision.

`measured_on` therefore reads `2026-08-14` on all six. The numbers did not move,
but the act that date records — checking that each still re-derives at its
recorded base — did happen, on that date and without a socket.

The record is what makes that reproducible by anyone, not just here:
`uberdev_rev` names the commit whose bytes were counted, so
`git show <uberdev_rev>:<path>` yields our half of the diff exactly, and
`upstream_tree` names the artifact that was the other half. Before this change,
**13 of the 14** skill numbers no longer reproduced against the review point the
register itself declares, and the record could not say so, because it named no
revision at all.

**The self-describing case, and why it is exempt (amended 2026-08-16).** That
contract is unachievable for one shape: a change that alters a component's bytes
AND updates its measurement in the SAME commit. The tree counted is the one that
commit produces, and its SHA does not exist while the change is being authored.
Naming the branch commit whose tree really was counted does not work either —
`main` is first-parent linear, every branch lands squashed, and a branch-only SHA
therefore ceases to exist on merge, leaving the basis citing an operand that
cannot be resolved and turning V46 red during unrelated later work.

For that shape only, `uberdev_rev` names the **base** the measurement was taken
against and `method` states that the tree counted is that rev plus the change
shipping alongside. `git show <uberdev_rev>:<path>` then yields the base half
rather than the counted half, so the operand is named rather than reproducible in
one command — which is strictly better than the alternative it replaces, a count
whose operand cannot be named at all (the defect this whole section exists to
close). Re-stamping the basis with the post-merge commit is a valid follow-up,
not a requirement: the base rev already resolves on `main`, so nothing is red in
the meantime.

All six take `uberdev_rev` `9002870bbbf21dabe9cc08a81d8293495c7beb38` rather than
the last commit to touch each file before it. Their recorded method counts the
provenance-header line, and those headers do not exist in the earlier commits —
`git show 231891f74821d9108639a0eaa01ea1a5b5a82f6e:plugins/uberdev/agents/code-reviewer.md`
carries none. Both the headers and the counts landed together, so that commit is
the one whose bytes the numbers describe.

### `C-MEASURE` — the channel this drift ran through

The checks `vendor-check.py` performs reconcile the register against disk, an
in-file header against the register, a register pointer against a register
record, or the register against its own declared shape.
**None of them read a recorded measurement.** `measured_diff_lines` was an
optional integer that **no code read** — its only occurrence outside the register
and prose like this document's own was its membership in `COMPONENT_KEYS` — so it
could hold any number, taken at any revision, against any bytes, and no check had
an opinion.

`vendor-check.py` therefore gains a thirteenth check:

> **`C-MEASURE`** — `measured_diff_lines` and `measured_diff_basis` are a
> biconditional: recording either without the other is a failure. The count is a
> non-negative integer (and not a `bool`). The basis is a record over a **closed**
> sub-key set — `upstream_rev`, `upstream_tree`, `uberdev_rev`, `measured_on` and
> `method` required, `component_digest` optional — with each member's format
> checked. Recording **zero** measurements anywhere is itself a failure, mirroring
> `C-HEADER`'s and `C-REFS`' vacuity arms.

Three boundaries are deliberate:

- **It owns the shape, never the truth of a count.** Re-deriving a diff needs the
  upstream bytes, and those always live **outside the register**: in this
  repository's git object storage for the six agents, in the on-disk plugin cache
  for the 14 skills, and over the network only for a revision newer than the one
  recorded. `C-MEASURE` reaches for none of the three — it reads the register and
  nothing else — and §2.3's offline guarantee stays structural because the checker
  never opens a socket. A shape check that quietly grew any of those reads would
  be the more expensive defect; the network is only the farthest of them, not the
  boundary itself.
- **Coverage is not universal.** A component nobody has measured is not a defect,
  so the rule is *every component that records a measurement records its basis*,
  not *every component records one*. The vacuity arm is what keeps that from
  degenerating: deleting the corpus would otherwise be the cheapest way to make
  the check permanently green.
- **The register-to-RFC reconciliation is not here.** It compares two documents,
  which is a test's job, not a shipped checker's. It lives in
  `tests/vendor-provenance.test.sh`, reads every `Diff lines` table in this
  document with its own label, and compares a register number to a table number
  **only where both declare the same revision** — like-for-like, so a labelled
  disagreement between two different bases is correctly not a finding. Its
  falsifiability row drives that predicate over mutated copies of both documents,
  one of which deletes §4.3's label. The invariant that mutation defends is that
  a `Diff lines` table must **never inherit a neighbouring section's basis**: the
  label scan is bounded to the table's own section, and a table carrying no label
  of its own is a hard failure rather than a silently re-based comparison.

`"schema"` deliberately stays `uberdev-vendor-v1`. A schema string earns a bump
when it protects a consumer that cannot be updated in lockstep; the producer and
every consumer of this register live in this repository, and `C-MEASURE` is the
contract that the new required record is present. The unchanged literal is a
decision, not an oversight.
