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
| `skills/subagent-driven-dev` | `skills/subagent-driven-development` | 1064 | **fork** | File sets diverge in both directions; the routed SDD lifecycle is UberDev-owned. |
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

Recorded in `vendor.json` under `permanent_divergences[]`, each with
`"permanent": true`, and referenced from the components they apply to.

| Id | Scope | Divergence |
| --- | --- | --- |
| `namespace-rebrand` | all third-party components | `superpowers:` → `uberdev:`. UberDev ships standalone under its own plugin id. |
| `parallel-hypothesis-testing` | `skills/systematic-debugging` | The local *Parallel hypothesis testing* section, already declared in the file's own provenance header. |
| `brainstorm-no-approval-gates` | `skills/brainstorm` | UberDev rejects upstream's HARD-GATE / per-section / spec-review approval checkpoints. Quality comes from parallel research and always-on reviewer agents, not human gates. |
| `review-pr-parallel-by-default` | `skills/requesting-code-review` | `/uberdev:review-pr` fans its review lenses out in parallel by default; upstream's flow is sequential. |
| `no-co-authored-by` | `skills/finish-branch` | UberDev never emits a `Co-Authored-By` or AI-attribution trailer in commits or PR bodies. |
| `interactive-discard-option` | `skills/finish-branch` | Upstream 6.2.0 stopped offering to discard *uncommitted work*. UberDev Option 4 discards a *branch and its commits* behind a typed confirmation, reachable only under `--interactive`. Different capability, so upstream's removal does not apply — see §7. |

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
  does **not** demand universal coverage, because that would red the four
  superpowers components whose backfill #503/#504 own, and a check that reds on
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
`base_evidence`; extending that record to the ten skill components is the
next piece of work, not a residual of this one.
