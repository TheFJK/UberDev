# UberDev `/goal` — broken on Claude Code CLI **2.1.150** (+ macOS bash 3.2)

> Maintainer fix-guide. Source paths below are relative to the uberdev plugin
> root: `plugins/uberdev/` (this repo). Discovered 2026-05-23 while running
> `/goal` against an external project on `claude 2.1.150`. A working reference
> implementation of the corrected watch loop ships alongside this doc:
> `goal-driver.reference.sh`.

---

## TL;DR

`/uberdev:goal`'s Phase-2 watch loop (`skills/goal-pipeline/SKILL.md`) detects
solver-agent completion, PR push, and merge by **grepping the captured
`solve-bg-stdout-<N>.log`** for `backgrounded · ` and `pushed PR #N`. On
**claude 2.1.150** none of those signals appear in that file, so the loop never
advances — it spins to the 4 h `stuck_loop` breaker and auto-merges nothing.
There are also two latent contract bugs (wrong merge-log filename;
`pushed PR #N` is never emitted by anything) and a **bash 4+ requirement** that
fails on macOS's default `/bin/bash` 3.2.

**The file-based contracts are fine** (verdict JSON, trust-signal classification,
merge `audit.jsonl`). The fix is to replace the **stdout-marker signals** with
**`gh` + file** signals. Reference impl proven end-to-end: it dispatched, solved,
reviewed GREEN, and **auto-merged a PR to `main`** on 2.1.150.

---

## Environment where it reproduces

| | |
|---|---|
| Claude Code CLI | **2.1.150** (plugin assumes `claude --bg` ≈ 2.1.139 semantics) |
| OS | macOS (Darwin 25.x, arm64) |
| Default shell for skill bash | `/bin/bash` **3.2.57** (Apple; no `declare -A`, no `mapfile`) |
| uberdev | 0.33.7 / 0.33.8 |

---

## Root cause 1 — `claude --bg` detaches immediately on 2.1.150

`lib/dispatch.sh` runs `claude --bg … > "$UBERDEV_TMPDIR/solve-bg-stdout-N.log"`.
On 2.1.150, `claude --bg`:

- **returns in ~4 s** (it backgrounds the session and exits — the `timeout
  $SOLVE_TIMEOUT` wrapper is now a no-op), and
- writes **only the launch banner** to the captured stdout (≈241 bytes):
  ```
  Starting background service…
  backgrounded · <8hex>
    claude agents / attach / logs / stop …
  ```
- the agent's **real transcript** goes to the detached session (`claude logs
  <id>`), **not** to `solve-bg-stdout-N.log`.

So the watcher's two probes both fail:

- `grep -q 'backgrounded · '` — matches at **t=0** (it's a *startup* banner, not a
  terminal marker as the SKILL comment claims), or never (for the `background`
  backend, which streams `claude -p` but emits no such marker).
- `uberdev_goal_extract_pr_num_from_log` (greps `pushed PR #N`) — see RC-3.

## Root cause 2 — plugin requires bash 4+, macOS ships 3.2

`skills/goal-pipeline/SKILL.md` uses `mapfile` (bash 4+) and the reference state
model uses `declare -A` (bash 4+). The verdict locator
(`uberdev_goal_locate_review_pr_audit_by_pr`) iterates **unquoted globs**
(`for f in .uberdev/runs/* .claude/worktrees/*/…`) which rely on **bash**
"unmatched glob → literal" semantics. Net portability matrix:

| Shell | `declare -A` | `mapfile` | unmatched glob | Verdict |
|---|---|---|---|---|
| `/bin/bash` 3.2 | ❌ | ❌ | literal ✓ | unusable |
| `zsh` (Bash-tool default) | ✓ | ❌ | **fatal `no matches found`** ❌ | unusable |
| `bash` ≥ 4.4 | ✓ | ✓ | literal ✓ | **required** |

> Fix: `brew install bash` (→ `/opt/homebrew/bin/bash` 5.x) and ensure the loop
> runs under it; **and** add a preflight version guard (see fixes below).

---

## The contract defects (and where to fix them in source)

| # | Defect | Source location | Fix |
|---|---|---|---|
| 1 | completion keyed on `backgrounded · ` (startup banner, not terminal) | `skills/goal-pipeline/SKILL.md` Phase 2a & 2c | gate on `gh` PR existence / `gh pr view --json state`, not the stdout marker |
| 2 | PR number from `pushed PR #N` grep — **string is never emitted** (finish-branch prints `PR created: <url>`) | `lib/goal-state.sh` `uberdev_goal_extract_pr_num_from_log` (~L587); producer `skills/finish-branch/SKILL.md` (~L279) | replace resolver with `gh pr list --json number,closingIssuesReferences,headRefName` → match `closingIssuesReferences[].number == N` or head `^feat/N-`. *(Or: also `echo "pushed PR #$num"` in finish-branch to satisfy the existing contract — but gh is more robust.)* |
| 3 | solve completion = `tail … \| grep 'backgrounded · '` | `skills/goal-pipeline/SKILL.md` Phase 2a | completion = a PR exists for issue N (gh); liveness via `claude agents --json` cwd `…/solve-issue-N` + status busy |
| 4 | merge completion reads `merge-bg-stdout-<pr>.log` — **never written** (`uberdev_dispatch_one` always writes `solve-bg-stdout-<key>.log`) | `skills/goal-pipeline/SKILL.md` Phase 2c | completion = `gh pr view <pr> --json state == MERGED` |
| 5 | `merge_executed` audit row is **agent-improvised** (no printf template), but consumer needs `.data.pr` | producer `skills/merge-pipeline/SKILL.md`; consumer `lib/goal-state.sh` `uberdev_goal_read_merge_result` (~L621) | add a concrete `merge_executed` printf template in merge-pipeline **and/or** make `read_merge_result` consult `gh pr view --json state` first |
| 6 | session mgmt: **`claude stop <SHORT-id>` works headless ✓** — use it to reap stray agents. `kill`/`pkill -9` do **NOT** stick (the `cc-daemon` resurrects the worker); the **full** session id is rejected ("No job matching"). `claude logs`/`attach` behave as prompts in non-TTY. | n/a (CLI behavior) | reap via `claude stop <short-id>`; inspect via `claude agents --json` |
| 7 | PR↔issue linkage assumed `worktree-solve-issue-N` | various locators/comments | actual PR head is **`feat/N-<slug>`**; reliable link is GitHub-native `closingIssuesReferences` (every historical PR carries `Closes #N`) |
| 8 | bash 4+ assumed; no guard | `skills/goal-pipeline/SKILL.md` Phase 0; `install.sh`; README | add `(( BASH_VERSINFO[0] >= 4 )) \|\| { echo "uberdev/goal needs bash ≥4 — brew install bash"; exit 1; }` preflight; document the dep |

### What is already correct (do NOT change — version-independent, file-based)

- **Verdict JSON**: `.uberdev/runs/<YYYYMMDD-HHMMSS-sha>/review-pr-verdict.json`
  with `.pr`, `.phases.phase2_5.by_severity.{blocker,critical}`, `.halted`,
  `.halted_due_to_overflow`. Written headlessly on **every** review (incl. RED).
  `uberdev_goal_locate_review_pr_audit_by_pr`'s 4-glob set finds it in the
  solver's worktree. ✓
- `uberdev_goal_read_trust_signal` green/yellow/red classification. ✓
- The **leaf solver already runs `/review-pr` itself** (finish-branch chain), so
  a verdict normally exists *before* the goal would re-dispatch one — the goal's
  own `/review-pr` dispatch is correctly only a `stale|missing` fallback. ✓
- Merge audit is the **flat** `.uberdev/audit.jsonl` (matches what merge writes;
  the `runs/<id>/` dir in the constant is never materialized). ✓

---

## The fix, concretely

Two equivalent options:

1. **Patch source (ship in 0.33.9)** — apply the right-column changes above to
   `lib/goal-state.sh` (resolver + merge-result) and `skills/goal-pipeline/SKILL.md`
   (Phase 2a/2c completion gates + Phase 0 bash guard). Keep the state machine,
   audit, fingerprint/nonconvergence, and circuit breakers as-is.

2. **Stopgap driver (no source edit)** — run `goal-driver.reference.sh` (here).
   It `source`s the plugin's working helpers (`uberdev_dispatch_one`,
   `uberdev_goal_locate_review_pr_audit_by_pr`, `uberdev_goal_read_trust_signal`,
   `_uberdev_goal_extract_fingerprint`) and reimplements only the broken
   detection. Preserves RFC-0005 semantics: rolling concurrency cap, GREEN
   auto-merge, YELLOW/RED held, BLOCKER/CRITICAL recursion, and the
   `stuck_loop / max_cycles / nonconvergence / merge_failed` breakers.

### Corrected detection (the heart of the fix)

```bash
# PR for issue N — GitHub-native link (NOT stdout, NOT worktree-solve-issue-N)
find_pr_for_issue(){ local n="$1"
  gh pr list --state all --limit 200 --json number,closingIssuesReferences,headRefName \
    --jq "[.[] | select((.closingIssuesReferences[]?.number == ${n}) or (.headRefName|test(\"^feat/${n}-\"))) | .number] | max // empty"; }

# solver liveness (disambiguate 'no PR yet' from 'agent died')
agent_busy_for_issue(){ claude agents --json | python3 - "$1" <<'PY'
import sys,json
n=sys.argv[1]
for s in json.load(sys.stdin):
    if (s.get("cwd","") or "").rstrip("/").endswith("solve-issue-"+n) and s.get("status") in ("busy","running","starting","working"): sys.exit(0)
sys.exit(1)
PY
}

# trust signal — reuse the (correct) file-based locator + reader
trust_of_pr(){ local v; v="$(uberdev_goal_locate_review_pr_audit_by_pr "$1")"; \
               [ -n "$v" ] && uberdev_goal_read_trust_signal "$v" || echo missing; }

# merge result — gh state is authoritative
pr_is_merged(){ [ "$(gh pr view "$1" --json state --jq .state)" = MERGED ]; }
```

---

### Critical timing nuance — grace the review; do NOT poll `agent_busy`

Found live on 2.1.150: the leaf solver runs its **own** `/review-pr` (via the
finish-branch chain) ~20 min **after** pushing the PR, and the solver session
frequently goes **idle** during that window. So "agent idle ⇒ review is done" is
**false** — keying the goal's own `/review-pr` dispatch on `agent_busy` fired 3
redundant reviews in 4 minutes and prematurely `red-held` a PR whose GREEN verdict
simply hadn't landed yet (it would never merge → no convergence). The correct
model is **time-graced + verdict-polled**, not liveness-based:

- wait **`REVIEW_GRACE` (default 30 min)** after PR-push for the leaf's verdict,
  re-reading the verdict JSON every poll — so it advances the instant the verdict
  lands, with **zero** redundant reviews on the happy path;
- only after the grace lapses dispatch our own `/review-pr` (bounded ×3, each
  resetting the grace timer);
- **re-read held PRs' verdicts every iteration** so a verdict that lands *after* a
  hold is recovered (`held → green → merge`);
- on **resume**, treat an already-`MERGED` PR as terminal (never re-merge).

(For a source fix this means defect #3's "completion via agent liveness" must be
"verdict-presence with a grace window," and `lib/goal-state.sh`'s held states must
be re-read, not write-once.)

## How to run the stopgap (verified on 2.1.150)

```bash
brew install bash                                  # one-time: macOS ships 3.2
cd <your-uberdev-managed-repo>
GOAL_AUTO_MERGE=1 GOAL_CONCURRENCY=3 \
  /opt/homebrew/bin/bash /path/to/goal-driver.reference.sh 15 20 24 25 31 33 \
  > .goal-run.log 2>&1 &
/opt/homebrew/bin/bash /path/to/goal-monitor.sh 600   # periodic snapshots
```

Env knobs: `GOAL_AUTO_MERGE` (1=merge GREEN, 0=hold for human), `GOAL_CONCURRENCY`
(default 3), `GOAL_MAX_CYCLES` (5), `GOAL_STUCK_SECS` (14400), `GOAL_BACKEND`
(claude-bg), `GOAL_SOLVE_TIMEOUT` (9000), `GOAL_MERGE_TIMEOUT` (3600).

The reference driver auto-detects the repo root (`git rev-parse --show-toplevel`)
and the newest installed plugin (`~/.claude/plugins/cache/uberdev/uberdev/*`), so
it is repo-agnostic.

---

## Repro / evidence (read-only smoke tests)

```bash
# 1. claude --bg detaches with banner-only stdout (~4s, 241 bytes):
time claude --bg --model claude-haiku-4-5-20251001 -- "say hi" > /tmp/x.log 2>&1; cat /tmp/x.log
# 2. 'pushed PR #N' appears nowhere as a producer:
grep -rn 'pushed PR' plugins/uberdev/   # only consumers/comments
# 3. PR head is feat/N-<slug>, link is closingIssuesReferences:
gh pr list --state all --json number,headRefName,closingIssuesReferences --limit 5
# 4. bash floor:
/bin/bash -c 'declare -A m'   # -> "declare: -A: invalid option" on macOS 3.2
```

End-to-end proof on 2.1.150 (external repo, issue #33):
`dispatch → feat/33-… branch → 12 commits → PR #56 pushed → leaf /review-pr →
trust=green → /merge → PR #56 MERGED to main`, all observed via the corrected
gh/verdict signals.

---

## Operational lessons (from a live 6-issue run on Claude Max)

A real `/goal` run (6 p0 issues, all merged) surfaced failure modes beyond the CLI
drift — fold these into the skill:

1. **Claude Max usage cap is the real concurrency limit, not CPU.** Six parallel
   `/turbo` agents (each fanning out to research/spec/plan/impl + a review fleet)
   **maxed the 5-hour Max window**. Capped review agents launch, print
   `You've hit your session limit · resets <time>`, do **0s of work**, and write
   **no verdict** — which a naive watcher misreads as "review failed → red-held."
   - **Detect** via `claude logs <short-id>` (the limit phrase renders as plain
     text; `grep -a` it). `session_limited()` in the reference driver does this.
   - **Handle**: back off + re-dispatch a FRESH review (the old session logs the
     cap forever); never burn the red-hold attempt budget on a quota stall.
   - **Prevent**: default `GOAL_CONCURRENCY` should be **1–2** on a Max plan, not
     6. Reviews are *not* concurrency-gated by `CONCURRENCY` (only solves are) —
     a follow-up should gate review/merge fan-out too. For now, run serial.

2. **Parallel PRs on a shared base CONFLICT once siblings merge.** After the first
   few p0 PRs landed, the rest went `mergeable=CONFLICTING/DIRTY` (e.g. both #20
   and #25 edited `fal.ts`/`worker.ts`; #31 and #25 added different `referenceImageUrls`
   / `internalUserId`-vs-`ownerId`). `/goal`'s auto-merge does **not** rebase, so a
   GREEN-but-conflicting PR can't land. **Resolve by merging `main` into the branch**
   (sequential), validating locally (`prisma generate` → `typecheck` → `vitest` →
   `prettier`), then push → CI → merge. Recovery resumes can set
   `GOAL_SKIP_LEAF_GRACE=1` so a re-adopted PR reviews promptly.

3. **`claude stop <short-id>` is the only headless session reaper.** `kill`/`pkill -9`
   are resurrected by the `cc-daemon`; the full session id is rejected.

4. **Conflict resolution that worked** (preserve-both-features default): keep both
   sides when complementary (e.g. #25 `isReferenceConditioned` guard + #20 image-URL
   mapping); unify duplicate concepts on the canonical name (`ownerId`); drop
   stale tests for replaced functions (placeholder `processGenerationJob`); always
   `prisma generate` in a resumed worktree (its client is stale).

## Suggested CHANGELOG entry

```
### Fixed
- `/goal`: watch loop is now CLI-version-independent. Solver/merge completion and
  PR discovery use `gh` (closingIssuesReferences / pr state) and the file-based
  review-pr verdict instead of grepping `claude --bg` stdout, which on CLI 2.1.150
  is a detached banner only (`backgrounded ·` is a startup marker; `pushed PR #N`
  is never emitted; `merge-bg-stdout-<pr>.log` was never written).
- `/goal`: require bash ≥ 4 with a clear preflight error (macOS default /bin/bash
  is 3.2). `brew install bash`.
```
