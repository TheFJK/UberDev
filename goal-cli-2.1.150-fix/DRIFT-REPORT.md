# `/uberdev:goal` — broken against Claude Code CLI 2.1.150 (built for 2.1.139)

**Plugin:** uberdev 0.33.7 · **CLI observed:** claude 2.1.150 · **Date:** 2026-05-23
**Symptom:** `/uberdev:goal` dispatches solver agents but the Phase-2 watch loop never
detects completion, PR push, or merge — it spins until the 4 h `stuck_loop` circuit
breaker and auto-merges nothing. Root cause is a CLI behavior change plus several
contract mismatches that indicate the Phase-2 watch loop has never run end-to-end.

Evidence below was gathered by read-only smoke tests; each finding is reproducible.

---

## Findings

### 1. `claude --bg` detaches immediately; captured stdout is the banner only
The dispatch backends (`lib/dispatch.sh`) run `claude --bg … > solve-bg-stdout-N.log`.
On 2.1.150, `claude --bg` returns in ~4 s after printing only:
```
Starting background service…
backgrounded · <8hex>
  claude agents / attach / logs / stop …
```
(241 bytes). The agent's real transcript goes to the **detached session**, retrievable
via `claude logs <id>` — **not** to the captured stdout the watcher polls.

### 2. `backgrounded ·` is a *startup* banner, not a terminal marker
`skills/goal-pipeline/SKILL.md` Phase 2a/2c treat `grep -q 'backgrounded · '` as
"agent finished" (comment: *"emitted once at session end by every backend"*). It is
emitted at **session start** (the session is then "idle — send a prompt to start").
So the marker is present at t=0 (false-positive completion) for `claude-bg`, and
**never** present for the `background`/`claude -p` backend.

### 3. `pushed PR #N` is never emitted
`uberdev_goal_extract_pr_num_from_log` (`lib/goal-state.sh:587`) greps the captured
log for `pushed PR #N`. **No** solve/turbo/dev/finish-branch path prints that string —
`finish-branch` prints `PR created: <url>`. The only occurrence in the plugin is the
goal watcher's own "marker missing" stderr line. PR number is therefore never resolved.

### 4. Phase 2c reads a file that is never written
Phase 2c reads `merge-bg-stdout-<pr>.log`, but `uberdev_dispatch_one` always writes
`solve-bg-stdout-<ISSUE>.log`. The merge-completion gate can never fire.

### 5. `merge_executed` audit row is agent-improvised
`uberdev_goal_read_merge_result` (`goal-state.sh:621`) selects
`.event=="merge_executed" | .data.pr`. `merge-pipeline/SKILL.md` has **no printf
template** for `merge_executed` (only prose "emit merge_executed"); the LLM agent
constructs the shape at runtime, so `.data.pr` is not guaranteed. (`pr_parked` *does*
have a concrete template.) Authoritative signal should be `gh pr view <pr> --json state`.

### 6. session management (corrected after live testing)
`claude stop <SHORT-id>` **does** work headless (`stopped <id>`) — this is the way to reap
a stray/runaway bg session. Caveats learned the hard way: plain `kill`/`pkill -9` do **not**
stick (the `cc-daemon` resurrects the worker), and the **full** session id is rejected
("No job matching") — only the 8-hex short id works. `claude logs`/`attach` behave as
*prompts* in non-TTY (spawn ephemeral agents). `claude agents --json` lists sessions.
Corollary: a watch loop must NOT `git worktree remove` a session's worktree before the
session is stopped (do `claude stop` first, then remove).

### 7. PR↔issue linkage assumption is wrong
The watcher/locators assume head branch `worktree-solve-issue-N`. That is only the
**initial** worktree branch; the solver renames to `feat/N-<slug>` before pushing
(verified on 12 historical merged PRs). Reliable linkage is GitHub-native
`closingIssuesReferences` (every historical PR carries `Closes #N`), with `^feat/N-`
head as fallback.

### What *is* correct (version-independent, file-based)
- Verdict JSON: `.uberdev/runs/<YYYYMMDD-HHMMSS-sha>/review-pr-verdict.json` with
  `.pr`, `.phases.phase2_5.by_severity.{blocker,critical}`, `.halted`,
  `.halted_due_to_overflow` — written headlessly on every review, found via the 4
  worktree globs in `uberdev_goal_locate_review_pr_audit_by_pr`. ✓
- `uberdev_goal_read_trust_signal` classification (green/yellow/red). ✓
- The leaf solver **already runs `/review-pr` itself** (finish-branch chain), so a
  verdict JSON normally exists without the goal's own re-dispatch. ✓
- Merge audit reads the **flat** `.uberdev/audit.jsonl` (matches what merge writes;
  the `runs/<id>/` dir in the constant is never materialized). ✓

---

## Required fixes (for native `/goal`)

Replace stdout-marker signals with version-independent ones:

| Signal | Broken (stdout) | Fix |
|---|---|---|
| solve completion / PR # | `backgrounded ·` + `pushed PR #N` grep | `gh pr list --json number,closingIssuesReferences,headRefName` → PR whose `closingIssuesReferences[].number == N` or head `^feat/N-` |
| agent liveness | (none) | `claude agents --json` cwd `…/solve-issue-N` + status busy |
| review completion / trust | (ok) | keep file-based verdict locator + `read_trust_signal` |
| merge completion / result | `merge-bg-stdout` grep + `merge_executed` row | `gh pr view <pr> --json state == MERGED`; `pr_parked` reason for failure |
| session cleanup | `claude stop` | kill by PID (`background` backend writes pid) or interactive `claude agents` |

Files to change: `lib/goal-state.sh` (`uberdev_goal_extract_pr_num_from_log` →
gh-based finder; `uberdev_goal_read_merge_result` → gh-state first) and
`skills/goal-pipeline/SKILL.md` Phase 2a/2c/2e completion gates.

A working reference implementation of the corrected watch loop is in
`.claude/goal-driver.sh` (same repo) — it reuses the plugin's dispatch + verdict +
trust-signal + fingerprint helpers and only replaces the broken completion/PR/merge
detection.
