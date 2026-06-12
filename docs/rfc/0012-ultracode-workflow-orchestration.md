# RFC 0012 — Ultracode Workflow orchestration: retiring the directive-emitter

| Field          | Value |
| -------------- | ----- |
| **Status**     | Draft |
| **Author**     | TheFJK |
| **Created**    | 2026-06-11 |
| **Targets**    | new `skills/<name>/workflow.js` scripts (review-pr, merge ×2, goal, solve-design, sdd-waves, scan-fleet, uberthink, testers, cluster-analyze, simplify-pass); thin rewrites of 9 pipeline `SKILL.md` bodies + `commands/review-pr.md`; new `lib/solve-launcher.sh`, `lib/goal-phase{0,1,3}.sh`, `lib/goal-watch.sh`, `lib/bump-version.sh`; `lib/config-read.sh` (args helper); `tests/workflow-scripts.test.sh` + `tests/_workflow_harness.js`; `hooks/session-start` + `skills/using-uberdev` (diet); docs surfaces: README.md mechanics sections, `plugins/uberdev/docs/testing.md`, `skills/writing-skills/SKILL.md`, status annotations on RFC 0005–0010 (§9 docs strategy) |
| **Supersedes** | — (replaces the directive-emitter *substrate* of RFC 0005/0006/0007/0008/0009/0010; their state machines, scoring contracts and trust trails are preserved byte-stable) |
| **Tracking**   | #301–#310 dispositions in §8; new issues per §9 |
| **Tier**       | Large (multi-release migration program; contract-affecting across every pipeline) |
| **Target ver** | staged 0.37.0 → 0.4x per §9 roadmap (current `main` is 0.36.1; every release bumps the two `assert_version_bump` locks at `tests/goal.test.sh:424` + `tests/solve-claim.test.sh:272`) |

---

## 1. Context — the directive-emitter era and its failure classes

Every heavy uberdev pipeline today is a **directive-emitter**: the `SKILL.md` bash fences return in milliseconds, the real work is `Task()` fanout the orchestrating LLM fires *between* fences, and all cross-wave state lives either in the orchestrator's context window or in on-disk sidecars rehydrated per fence (memory: `project_uberdev_pipeline_directive_emitter`; RFC 0009 §3 "Why directive-emitter"). The 2026-06 flow audit (9 agents × 3 lenses → issues #301–#310), followed by a 10-cluster verified deep-dive for this RFC, established that this substrate has four **structural** failure classes plus two chronic taxes — none fixable by patching individual pipelines:

1. **Fence-scoped shell state death.** Each bash fence is a fresh process; `trap EXIT`, PID stamps, exports and arrays die at fence end:
   - the `/merge` single-instance lock is void — next run's `kill -0` sees the dead fence PID and steals it (merge-pipeline/SKILL.md:233-262, #303);
   - `/goal` Phase-3 `new_candidates` is built at goal-pipeline/SKILL.md:1370-1374 and lost before :1389 reads it → **false converge with BLOCKER findings still open** (#301 CRITICAL);
   - `/review-pr`'s locked marker + EXIT trap live milliseconds (review-pr.md:88-106, #302), and the `EXPECTED_OLD_SHA` force-push lease splits across fences (review-pr.md:554→621);
   - `/testers`' `POLITE_BREACH` fail-the-run contract can never fire (testers-pipeline/SKILL.md:337-340, #306).
2. **zsh/bash divergence.** The Bash tool runs `/bin/zsh` on macOS:
   - `ARR=($VAR)` scalar-splits both scan wave loops into one garbage element (uberscan SKILL.md:221-276, ubersimplify SKILL.md:236-281, #305);
   - `compgen -G` ×4 fails → `/merge` PATH_2 misclassifies every worktree-produced PR as STALE (merge SKILL.md:400-403, #303);
   - `type -t`, `BASH_REMATCH`, `trap RETURN`, `declare -A` (solve-pipeline/SKILL.md:309; macOS `/bin/bash` 3.2 hard-errors) misfire silently (memory: `project_uberdev_type_t_bashism_zsh`).
3. **Skill-renderer `$ARGUMENTS` mangling.** Positional args substitute into the *whole* SKILL.md body:
   - bare `$1/$2/$3` in helpers corrupt under `/solve 5 6 7` — the claude-version gate renders `min="5"` and every claim release retargets issue 5 (solve-pipeline/SKILL.md:66/:83/:615, #304);
   - awk column refs died in goal-pipeline (memory: `project_uberdev_skill_renderer_dollar_arg_collision`);
   - `/testers http://localhost:3000` corrupts `_wave_count`'s `"$1" "$2"` (testers-pipeline/SKILL.md:177).
4. **Dead circuit breakers + prose-only control flow.** Timers/accumulators inside ms-returning fences never accumulate:
   - uberthink's fleet ceiling is inert — all 8 `AGENTS_DISPATCHED` bump heredocs regex-match the file's *first* line, the seed `=0` (uberthink SKILL.md:345 et al.; reproduced by simulation, #307);
   - CB-WAVE is dead-by-default; SDD's three fix loops are **unbounded** ("Re-test until green", subagent-driven-dev/SKILL.md:71/:78/:348, #308);
   - wave barriers ("dispatch in a SINGLE message"), retry caps and "loop back to Phase 1" are sentences the orchestrating model may drift on — the #288 class.

Chronic taxes:

- **jq / `|| echo 0` masking.** Crashed producers read as count=0 (memory: `project_uberdev_jq_echo0_masks_crash`). Maximum blast radius: uberthink runs its Wave-4/7 python under `2>/dev/null || true` (SKILL.md:920/:1270), so an ImportError becomes CB-CONVERGE and the user is told their goal "admitted no feasible novel approach" after a ~90-minute run (#307).
- **Main-session token tax** (measured `wc -c`): review-pr.md 91,474 B + post-impl-review 17,746 B; merge-pipeline 124,767 B + merge.md 8,671 B; goal-pipeline 116,760 B + goal.md 10,282 B *plus* up to ~27 full-context watch turns per cycle × 5 cycles; solve-pipeline 68,276 B; orchestrator 48,365 B; uberthink ~2.03 MB of agent-prompt bytes per run; the session-start hook injects 16,511 B on every startup/clear/compact (#309). Full table in §6.

Claude Code now ships the **Workflow tool ("ultracode")**: a deterministic background runtime executes a JavaScript orchestration script that spawns subagents; only the script's return value and `log()` lines reach main-session context — agent transcripts do not. Critically for uberdev, a skill's instructions may legitimately mandate a Workflow call (one of the documented opt-in paths). That is the migration vehicle. This RFC is the master plan: per-pipeline verdicts and designs (§3), shared carrier infrastructure (§4), model policy (§5), token economics (§6), no-migration quick wins (§7), #301–#310 dispositions (§8), the phased roadmap (§9), and risks/open questions/rejected alternatives (§10).

## 2. Ultracode capability analysis

### 2.1 What the runtime gives

- `agent(prompt, opts) → Promise`.
  - With `opts.schema` (JSON Schema) the subagent is forced through a StructuredOutput tool, **validated at the tool layer with retry on mismatch** → returns a parsed object. Without, returns final text (subagents are told their final text IS the return value).
  - Returns `null` if the user skips the agent or it dies on terminal API error after retries — a thunk that throws inside `parallel()` also resolves to `null`.
  - `opts`: `label` (display), `phase` (progress group — use instead of global `phase()` inside pipelined stages), `schema`, `model ∈ {sonnet, opus, haiku, fable}` (**DEFAULT OMIT = inherit session model**), `isolation:"worktree"` (own git worktree, ~200–500 ms + disk; ONLY for parallel file mutators; auto-removed if unchanged), `agentType` — dispatch an EXISTING registered agent type (same registry as the Agent tool, e.g. `uberdev:code-reviewer`, `Explore`), composing with `schema`. **Our 42 `agents/*.md` are reused, not rewritten; only the dispatch layer changes.**
- `parallel(thunks)` — concurrency **with a barrier**; never rejects; `filter(Boolean)` the results.
- `pipeline(items, ...stages)` — each item flows through stages independently, **NO barrier between stages**; stage callbacks receive `(prevResult, originalItem, index)`; a throwing stage drops that item to null and skips its remaining stages. **Default for multi-stage work**; barrier only when a stage needs ALL prior results (dedup, early-exit, cross-reference).
- `phase(title)` / `log(message)` for the `/workflows` progress tree; `args` = the caller's JSON verbatim.
- `budget = {total (null if no token target), spent(), remaining()}` — hard ceiling shared across the turn; `agent()` **throws** past it; loop guards must check `budget.total` truthy.
- `workflow(nameOr{scriptPath}, args)` — child workflow inline; shares concurrency cap, agent counter, budget; **ONE level of nesting** (a `workflow()` inside a child throws).
- **Invocation forms:** inline script; **`scriptPath`** (a `.js` file on disk — a plugin can ship workflow scripts; this **bypasses the Skill renderer's `$ARGUMENTS` substitution** entirely); `name` (saved workflows from `.claude/workflows/` — **plugin-directory support UNVERIFIED**; do not design around it). Every run persists its script under the session dir and returns `{scriptPath, runId}`.
- **Resume:** `Workflow({scriptPath, resumeFromRunId})` — longest unchanged prefix of `agent()` calls returns cached results; **SAME-SESSION ONLY**. Not a cross-session durability mechanism.
- **Caps:** concurrent agents `min(16, cpu cores − 2)` per workflow (excess queues transparently); 1000 agents per workflow lifetime; 4096 items per `parallel`/`pipeline` call; script ≤ 512 KB.
- **Script constraints:** plain JS (not TS); top-level await fine; **NO filesystem or Node API in the script itself** (agents have full tools incl. Bash/Read/Write); `Date.now()`, `Math.random()`, argless `new Date()` **THROW** (resume determinism) — timestamps come in via `args`; the `meta` export must be a **PURE LITERAL** `{name, description, phases[], whenToUse?}` with phase titles matched exactly against `phase()`/`opts.phase` strings; scripts are self-contained — no import/require; shared code only by copy-paste/codegen.
- MCP: workflow agents reach session-connected MCP tools via ToolSearch; interactively-authenticated servers may be absent headless.

### 2.2 Hard constraints — the cannot-do list (checked against every design in §3)

1. **No user interaction from inside**: agents cannot AskUserQuestion; any interactive gate (Q&A phases) must stay in the main loop (hybrid pattern: scout → ask → workflow).
2. **Background relative to the main session**: no foreground step-by-step user visibility beyond the progress tree; the main session continues/ends its turn and is re-invoked on completion.
3. **No script-level sleeps/timers**: polling an external condition (CI runs, claude-bg sessions) means repeated `agent()` calls (each a fresh subagent) or keeping the wait in the main loop (Bash/Monitor).
4. **Same-session resume only**: cross-session durability still needs on-disk state (e.g. goal-state.sh-style stores) written by agents.
5. **Workflow agents are Task-style subagents, NOT detached full Claude sessions**: they cannot replace claude-bg dispatch semantics (independent permission tier, survive-the-parent, hours-long lifetimes). A child `workflow()` per issue CAN replace an in-session SDD fanout — never a detached background solver session.
6. **The script cannot touch the filesystem or git**: all reads/writes/gh calls happen inside agents (or the main loop before/after).
7. **One nesting level** for `workflow()`.
8. **No SendMessage continuation between workflow agents**: every `agent()` is a fresh context; cross-wave memory travels via return values (script state) or disk artifacts written by agents.

### 2.3 What it verifiably fixes here

- Orchestration state in JS variables spanning the whole run → kills class 1 (fence death).
- Control flow leaves the shell entirely → kills class 2 (zsh divergence).
- `scriptPath` files are never rendered; params arrive as real JSON `args` → kills class 3 (renderer mangling).
- Real `while`-loops with real counters + the budget API → kills class 4 (dead breakers); explicit `parallel()`/`pipeline()` semantics replace prose barriers and orchestrator drift.
- Schema-validated returns with automatic retry → kills trailing-YAML parse fragility and `|| echo 0` masking.
- Only the return value + `log()` lines surface → the 91–125 KB skill bodies shrink to thin preflight + an on-disk script that never enters context.

### 2.4 Design rules (binding for every migrated pipeline)

| # | Rule |
|---|------|
| DR-1 | **scriptPath only**, resolved from `${CLAUDE_PLUGIN_ROOT}` (precedent: hooks.json:9). Saved-name registration is unverified — never rely on it. Scripts live at `skills/<name>/workflow.js` (+ `skills/<name>/workflows/*.js` for children), siblings of the SKILL.md they version with, structurally outside the renderer's substitution surface. |
| DR-2 | **Thin preflight bash** does only what the script cannot: `$ARGUMENTS` parse, config reads, RUN_ID/timestamp mint, gh identity/repo resolution, feature/file probes — then prints the canonical args JSON between `WORKFLOW_ARGS_BEGIN/END` markers via `uberdev_emit_workflow_args` (§4.3) and mandates the Workflow call. The model relays the JSON verbatim; no LLM-composed handoffs. |
| DR-3 | **agentType reuse**: existing `agents/*.md` dispatched unmodified except contract additions this RFC names (working_dir, revision_brief, supplied-deps mode, Output-section updates for schema dispatch). |
| DR-4 | **Schemas replace YAML-by-prose**: every structured return is `opts.schema`-forced; enums closed; counts integers. Agent `.md` Output sections updated in the same PR to avoid prompt tension. |
| DR-5 | **Envelopes are two-sided and code-owned** (§4.5): the script's prompt assembler wraps every external or transitively-agent-derived string via the shared envelope snippet (ported from `lib/report_primitives.py:21-89`, ZWSP close-tag neutralisation included); agent-side validators/refusal stanzas are load-bearing and survive slimming. |
| DR-6 | **Absolute-path discipline**: all artifact paths in args and prompts are absolute (artifact path-leak class); agent-returned paths are realpath-prefix-checked under the expected run dir before any read (§4.5 C-7). |
| DR-7 | **Timestamps via args, frozen at preflight**: `run_id`, `now_epoch`, `now_iso` arrive in args (Date.now throws). Any wall-clock gate evaluated MID-run (CI settle, grace windows, stuck timers) takes live time from agent-side `date`, never from args. |
| DR-8 | **Budget + halt discipline**: loop guards check `budget.total && budget.remaining()`; every loop body / `agent()` chain is wrapped in try/catch routing to a `finalize(reason)` path that persists state and emits the breaker audit row — a budget throw must never skip cleanup. |
| DR-9 | **`resumeFromRunId` is forbidden for side-effecting loops** (goal-loop, merge-resolve, sdd-waves): prefix-cache replay returns stale world-state for dispatch/merge results. Allowed where designed in (solve-design's interactive two-burst seam; read-only fleets). |
| DR-10 | **Feature-detect fallback** (§4.2): every migrated SKILL.md carries a `## No-Workflow fallback` section gated on the model's own tool list — Gemini/Copilot/pre-Workflow Claude Code degrade to a retained compact directive recipe instead of breaking. |

## 3. Per-pipeline verdicts and migration designs

### 3.0 Verdict table

| Pipeline | Verdict | Headline win | Effort |
|---|---|---|---|
| `/review-pr` (+ post-impl-review) | **hybrid — flagship** (one script, Phases 1→3) | 109 KB → ~14 KB main session (−87%); diff×9 → 0; kills fence-trap/lease/dead-counter/undefined-`audit` classes; Phase 2.5 ∥ 3 | L |
| `/merge` | **hybrid** (merge-plan.js + merge-resolve.js; landing loop + Phase 4 stay foreground) | 133 KB → ~25–30 KB; N sequential trust turns → 1 burst; enforced retry ladders | L |
| `/goal` | **hybrid** (goal-loop.js driver over extracted bash; workers stay claude-bg) | ~27 ticks/cycle × 5 cycles of full-context turns → 0; #288/#301 classes structurally dead | L |
| orchestrator (/solve //turbo design) | **hybrid, staged** (solve-design.js; gated on headless probe) | child 75–90 KB → 12–15 KB; prose retries/timeouts → enforced code | L |
| subagent-driven-dev | **hybrid** (sdd-waves.js) | 3 unbounded loops capped; −150–280 KB/run; per-task pipeline removes the wave-wide barrier | L |
| /solve //turbo launcher | **keep shell** (hoist to `lib/solve-launcher.sh`) | kills 3 live renderer/fence bugs at root; −66 KB dispatcher | M |
| /uberscan + /ubersimplify | **full** (shared scan-fleet.js, mode arg) | zsh wave loops + fence vars + dead breakers deleted; −70–80% static; explicit `--resume=<run_id>` | L |
| /uberthink | **full** (uberthink workflow.js) | ~95% main-session cut; inert ceiling + masked crashes → real code; agent bytes −45% via lens diet | L |
| /testers | **full** (testers-waves.js) — **proving ground** | replaces never-worked `dispatch_master`; 10–25× main-session cut; breach gate finally live | L |
| /cluster | **hybrid** (cluster-analyze.js for Phases 3/3.5 + filter) | 25–140 KB/run transit → ~0; prose waves → `parallel()` | M |
| /simplify | **hybrid** (simplify-pass.js, preferably after scan-fleet — soft prereq) | diff×4 transit → 1 on-disk copy; deterministic dedupe | M |
| /issue, /dev, brainstorm, finish-branch, write/execute-plan, worktrees, process skills | **keep** | interactivity + foreground git are the product; targeted hardening only | S |
| hooks / aliases / config-read / secret-scan / install.sh / CI | **keep — carrier** | −11 KB/session hook diet; CI double-run halved; ships the .js test architecture | S–M |

### 3.1 `/review-pr` — flagship hybrid; absorbs post-impl-review

**Why one script, not per-phase.** Phase 3's post-fix path re-enters Phase 1 (review-pr.md:651-657); splitting per phase would push the fix loop back into the main session, recreating today's dead-counter and fence-death pattern. The 91,474 B command body *is* the orchestration today — and its loop counters, lease SHAs and 11 `audit <event>` call sites (review-pr.md:339,:342,:372,:612,:632-634,:682 …) reference a helper **defined nowhere in the repo**; the trail exists only because the LLM improvises it.

**Do-first (#302, review-R1 — small PR, lands with or without the migration):**

- Push fix commits before Phase 3: **ONE** guarded `git push origin HEAD` after the LAST fixer — Step 6b, or Step 5 only under `--no-simplify` (exit-2 guard shape of review-pr.md:870-880) — so the PROBE at :365 validates the **post-fix** remote SHA; today GREEN can describe code CI never ran on. One push, not two: each push spawns a duplicate CI set under #309's no-concurrency-group reality.
- Envelope-as-file-bytes at all **three** writer sites — post-impl-review/SKILL.md Step 4, review-pr.md's Phase-2 aggregation (:174), simplify.md's Phase-2→3 aggregation (:81-85) — each with its per-source attribute (`post-impl-review-aggregate`/`simplify-aggregate`), so `findings-to-issues.md:42`'s first-128-bytes validation passes — today every Phase-2.5 dispatch (and /simplify Phase 3.5 identically) is REFUSED input-malformed → fail-open → GREEN with the RFC 0002 blocker gate silently off. Read side in the same PR: review-pr.md:130/:180 stop re-wrapping (pass the path or the already-enveloped bytes; re-anchor R8.3, which locks the read-time wrap today) and finish-branch's PR-body composer strips envelope lines from its glob read (finish-branch/SKILL.md:139).
- The empty-checks + head-age settle re-probe lands in THIS PR (the push change creates the probe-too-early window it guards); fold the benign-cancel same-name dedupe in too if the migration slips a cycle (hard ordering vs #309's concurrency group — see §7.7).

**Args contract** (thin preflight; `PR_NUMBER` bound ONCE from a single multi-field `gh pr view`, killing the never-assigned `$PR_NUMBER` consumed at :243/:365/:404/:543):

```json
{ "runId": "...", "prNumber": 0, "repoSlug": "...", "workingDir": "<abs>", "baseRef": "...",
  "headRefName": "...", "startedAtIso": "...",
  "flags": {"simplify":true, "ciFix":true, "deferIssues":true, "deferIssuesConfig":true, "turbo":false},
  "aspects": [], "markerDir": "<abs>",
  "caps": {"ciFixLoop":3, "rerunFlaky":1, "monitorPassSec":540, "monitorPasses":3,
           "conflictWave":10, "maxNew":10, "settleReprobes":3, "settleAgeSec":120, "fanoutCap":6} }
```

**Script shape** (`skills/review-pr/workflow.js`; meta phases `["Phase 1 — Review fanout","Phase 1 — Fix","Phase 2 — Simplify","Phase 2.5 — Defer issues","Phase 3 — CI health","Verdict"]`):

```text
async function reviewFixCycle(iter):
  brief agent: gh pr diff → writes envelope-wrapped brief.md (source=pr-diff as FILE bytes;
               >2000 lines → per-file summaries inside the envelope; aspects appended)
  parallel(6 reviewers via agentType — code-reviewer ×2 (correctness/general), silent-failure-hunter,
           type-design-analyzer, comment-analyzer, pr-test-analyzer — each Reads the brief by PATH)
       // BARRIER justified: aggregation consumes ALL reviewer returns
  aggregate in-script (schema-validated returns; BLOCKED → drop to N−1) →
       haiku writer emits post-impl-review-final.md (envelope = leading file bytes)
  code-fixer (phase1, agentType, findings by PATH — ends the aggregate double-carry at :126-141)
  parallel(3 code-simplifier lenses; '## Lens emphasis' OUTSIDE the envelope) → simplify-final.md
  code-fixer (phase2 — exactly ONE refactor: commit, R8.6 invariant)
  push agent (haiku): git push origin HEAD → {pushed, headSha}        // #302 CRITICAL 1, in-design

const cycle = await reviewFixCycle(0)
const f2iP = flags.deferIssues ? agent(f2iPrompt /* aggregate PATHS + max_new + pr fields */,
        {agentType:'uberdev:findings-to-issues', schema:S.f2i}) : Promise.resolve(null)
        // agent OWNS MAX_NEW/dedupe/halt
const ci = await ciHealthLoop(f2iP)   // Phase 2.5 ∥ 3 under HALT-GATES-MUTATION ordering:
       // read-only PROBE/MONITOR passes may overlap Phase 2.5 freely, but ciHealthLoop AWAITS the
       // f2i result and requires halted=false before the FIRST ROUTE/fix dispatch (and before the
       // conflict arm) — keeps today's halt-prevents-Phase-3 semantics in interactive AND turbo
       // while retaining nearly all of the 1-3 min overlap win (#302 speedup)

ciHealthLoop(): real while + caps.ciFixLoop counter + budget guard (DR-8):
  haiku probe agents (rate-floor 200; settle re-probes when checks empty && headAge < settleAgeSec)
  classifyBuckets() — pure JS: same-name dedupe best-state-wins (benign-cancel fix), red > pending
       // replaces the jq at :379-384; unit-tested directly (upgrades S15-RUNTIME)
  monitor = repeated ≤540 s watch agents (sleep INSIDE the agent; kills the `timeout 1200` at :404
       which exceeds the 600 s Bash-tool cap and mis-routes harness kills to CLASSIFY)
  classifier / ci-code-fixer / ci-rebase-handler / rerun arms via agentType (oneOf schema enforces the
       status/failure_class pairing); CI-REFUSED → synthetic ci-refused-synthetic aggregate → f2i → halt
  CONFLICT arm: recreate-conflict agent returns EXPECTED_OLD_SHA/BASE_SHA → JS vars (kills :554→:621);
       parallel(conflict-resolver per file, sliced by caps.conflictWave); finisher agent does
       add + rebase --continue + push --force-with-lease with the JS-held lease
       null/throw from ANY arm agent mid-rebase → dispatch a `git rebase --abort` cleanup agent
       BEFORE returning halted — agent() resolves null on death/skip, and a dead finisher must not
       leave the real checkout wedged mid-rebase with nobody watching
  loop re-enters reviewFixCycle(iter) — RUN_ID is never re-minted (marker, research dir and verdict
       path are keyed on it; /goal treats a new run dir as a fresh review)

return {phase1, phase2, phase2_5, phase3, trustStateNoOverride, halts[], auditEvents[], anchorParentShaCandidate}
```

**Main-loop seam** (slimmed review-pr.md, ~8–10 KB), in order:

1. Preflight: flags, RUN_ID mint + regex, single PR bind, locked-marker write **without trap** (the marker must outlive every burst; cleanup moves to the tail — strictly more truthful than today's ms-lived marker).
2. Workflow call.
3. On return: AskUserQuestion for `halts[].needsUserChoice` — the Phase-2.5 blocker halt (:282-309) and 6c.6 billing/outage halt (:659-684). The asks are FORCED post-workflow by constraint 1; the pre-Phase-3 abort power they carry today is restored INSIDE the script by the halted=false gate on Phase 3's mutating arms (ROUTE/fixer/conflict/rerun — the ciHealthLoop ordering above), so the seam placement loses no semantics. Headless semantics preserved: gate 1 already defaults to `solve_suggestion` on no-TTY; gate 2 branches on TURBO — which reaches detached children via env (§3.3).
4. Compute final GREEN/YELLOW/RED incl. OVERRIDE_GREEN; **emit trust artifacts in the load-bearing order: anchor commit → push → labels → verdict JSON LAST with post-push `ANCHOR_SHA`** (the /goal SHA-binding contract — §3.3 table). RED still writes the JSON (review-pr.md:807); skipping it strands /goal in the stale|missing cascade. `review-pr:pending` cleared on green only.
5. Append `auditEvents[]` to `.uberdev/audit.jsonl` JSON-encoded (C-5); rm marker; exit 0/1/2 — the contract `/merge` Step 1.4.5 reads synchronously (merge SKILL.md:527-528) and finish-branch chains on.

Crash story, stated not implied: `resumeFromRunId` retries a crashed WORKFLOW same-session only — a crashed/closed SESSION leaves the run unrecoverable mid-flight, the locked marker ages out at REVIEW_GRACE_SECS (3600 s, goal-state.sh:139) and `review-pr:pending` stays on the PR as the by-design /merge backstop (review-pr.md:952). Equal-not-worse vs today; the win list must not imply more durability than resume provides.

**post-impl-review disposition: absorb-and-tombstone.** Sole live caller is review-pr Phase 1 (post-impl-review/SKILL.md:14-18); workflow subagents cannot Skill→Task, so the script inlines the 6-reviewer fanout. The writer-side invariant set the .js must keep byte-stable:

- (a) path `<checkout-toplevel>/.uberdev/research/<RUN_ID>/post-impl-review-final.md`, RUN_ID `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$`, never the `-wave-` infix (regression-locked, finish-branch-auto-chain.test.sh:168);
- (b) envelope token `post-impl-review-aggregate` in the first 128 file bytes + close tag at end (findings-to-issues.md:42; code-fixer.md:30; byte-equality oracle tests/findings-to-issues.test.sh:313);
- (c) findings table per the fixture `tests/fixtures/findings-to-issues/post-impl-review-final.sample.md` (`agent|severity|file|line|disposition|summary|deferral_reason`; severity enum `blocker|suggestion`) + fixed bottom line `Aggregated: N blockers, M suggestions. Continue.`;
- (d) pr-diff envelope + >2000-line summarise rule + uniform `## Emphasis` from aspect_emphasis (review-pr.test.sh:443);
- (e) config keys `fanout_concurrency.post_impl_review` [1,50] default 6 — incl. the `sequential` stderr-notice literal (review-pr.test.sh:429), which fixes today's silent no-op flag (the export at review-pr.md:42-47 never reaches the skill's fanout fence) — and advisory `command_timeouts.review_pr` + its audit row;
- (f) failure semantics: missing/empty aggregate → warn + zero fixes; all-BLOCKED → the `(all reviewers blocked)` line;
- (g) finish-branch's `REVIEW_FILES` globs (finish-branch/SKILL.md:139) and the fixture stay untouched — they are the read-side oracle. The token outlives the skill (cross-pipeline code-fixer format id, reused by `/simplify`:103 and ubersimplify).

Stale prose cleaned in the same series (several are test-locked stale — fix prose + lock together): turbo.md:15 ↔ turbo-flow.test.sh:443; orchestrator/SKILL.md:550; the 5-vs-6 reviewer counts (SDD:117/:284, finish-branch:74); using-uberdev:146's default-5.

**Tests:** re-anchor review-pr.test.sh R8/R11 dispatch shapes; upgrade S15-RUNTIME (review-pr-phase3-ci.test.sh:358-362) from prose-extracted jq to executing `classifyBuckets()` under node with the same fixtures; move post-impl-review.test.sh's 6-row table + envelope asserts onto the .js; findings-to-issues.test.sh survives intact. Keep the trust-emission asserts (R9.x, R21, T1/T2) pointing at the slimmed command — that bash stays there by design.

### 3.2 `/merge` — hybrid: plan + resolve workflows; landing stays foreground

**Do-first (#303, merge-R1 — the migration baseline):**

1. Lock redesign: `{run_id, started_at, last_heartbeat}` record in `.git/uberdev-merge.lock.d/`, **no trap**; explicit release at Phase 4.6 + every documented early-exit; the landing loop touches `last_heartbeat` at every per-PR iteration and phase boundary, and staleness = heartbeat age > max(`command_timeouts.merge`, ~900 s hard floor) — NEVER `started_at` age, which classifies live long runs as stale (the 1.4.5 auto-review intercept alone can hold the lock past CI_MONITOR_TIMEOUT_SEC=1200) and would trade today's void lock for a steal-during-live-run lock. (The fence PID stamped at SKILL.md:233-262 is dead before the next run's `kill -0` probe — the lock is void today.) The record gains `workflowRunId` for #310's status reader.
2. Replace the `compgen -G` ×4 audit-JSON discovery (:400-403) with a find-based helper in `skills/merge-pipeline/lib/discover.sh` (the #294 `_uberdev_goal_glob_worktree` pattern) + reconcile the STALE contract — agents/trust-trail-evaluator.md:45 promises a "single /review-pr re-run lifts it" recovery the caller never implements (legacy-STALE maps to terminal gate_fail at :457).
3. `git fetch origin <integration> <head>` at the top of **each** landing iteration, **plus** re-point the Step-3.1 merge-tree probe (:692) and the scratch-worktree base (:713) at `origin/<integration_branch>` — the fetch alone only updates `refs/remotes/` while the probe/worktree use the LOCAL ref; the local-ref probe is the actual bug. Today the run's only fetch is Phase 4.1 (:861), so PR-B is probed against the pre-A tip → false-clean probes surface as server-side `gh pr merge` failures with no conflict-resolve attempt.
4. ci_red: bounded 3×10 s rollup re-probe; distinguish no-checks-configured (proceed) from pending (gate_fail) — transient null rollups are a known class.
5. Standardize audit-path **docs** on root `.uberdev/audit.jsonl`: Constants :28-29 and schema :1001 claim `runs/<run-id>/` while every live writer (:156,:517,:548,:702,:820) and /goal's reader glob only the root — "fixing" toward the documented path silently breaks /goal.
6. Reword merge.md:11's "Do NOT use the Task tool" contradiction (the skill mandates 3 Task sites).

Same-PR test re-anchors for this bundle: M62.4/M62.6 (trap-syntax prescriptions) and every `M63.worktree-glob.c0.*` compgen-chain assertion (no test greps AUDIT_LOG_DIR_PATTERN content or merge.md:11's text — verified).

**merge-plan.js** (Phases 1.4–2.3) — meta `['Discover','Gate+Strategy','Order']`. Args: `{prNumbers|null, all, integrationBranch, repoRoot, runId, nowIso, flags{acceptBlockerDeferred, acceptCriticalDeferred, iKnowWhatImDoing, autoReviewOnMerge}, caps{strategy, trust}, repoConvention, auditLogPath}`.

```text
phase Discover: one agent runs lib/discover.sh discover_multi / pr_view_projection via Bash →
    candidates[] {pr, headRefOid, headRefName, baseRefName, createdAt, labels[], reviewDecision,
                  isDraft, state, isCrossRepository, maintainerCanModify, bodyEnvelope}
pipeline(candidates, preflightStage, trustStage, strategyStage)
    // PIPELINE, not parallel: each PR flows independently; a gate-fail returns a TAGGED SENTINEL
    // ({gate:'fail', reason, …}) that passes through the remaining stages untouched — throw/null
    // are reserved STRICTLY for infrastructure death (mapped to a pr_view_unreachable analog),
    // because thrown items cannot populate skipped[]/auditEvents[], and per-PR gate_fail rows +
    // run-summary Skipped lines are consumed contracts (operator + /goal) — no barrier until Order
  preflightStage: pre-condition gates (state/draft/ci_red with its own bounded re-probe in Bash),
      the Step-1.6 fork gate (`git push --dry-run` permission probe + isCrossRepository/
      maintainerCanModify — non-mutating, so it lives here, not as a leftover main-session probe),
      trailer extraction, changedFiles[] (git diff --name-only), commit signals, dependsOn[]
      parsed via the whitelist regex `Depends on #([0-9]+)`
  trustStage (PATH_2 only): agentType uberdev:trust-trail-evaluator —
      schema {verdict ∈ [PASS, STALE, INVALID, FORCE_PUSHED], rationale, subreason?, retryAttempt,
              trailerSha, headRefOid, eventTs}. "Reused unchanged" fails here: in-agent audit-JSON
      self-discovery + fetch-retry violate its read-only Tools allowlist and Inputs contract
      (trust-trail-evaluator.md:22-33/:37). EITHER keep (c.0)/phase2_5 discovery in the Discover
      stage (caller-side; agent-of-record unchanged) OR amend trust-trail-evaluator.md in the same
      PR (Inputs self-discovery; Tools += git fetch, the R1 find helper, jq-on-local-audit; the
      "last lines of your reply, fenced YAML" return prose reconciled with the schema) and re-run
      M47.1-M47.9
  strategyStage (passers): agentType uberdev:merge-strategy-decider —
      returned strategy validated in JS against the CLOSED set {squash, rebase, merge}
      before it can ever reach `gh pr merge --<strategy>` argv (§4.5 C-4)
BARRIER (await pipeline) → phase Order: pure JS — topo-sort hard deps, overlap matrix from
    changedFiles intersections, createdAt tie-break, cycle auto-break with log()
return {plan[], skipped[{pr, reason, verdict?, subreason?, eventTs}], autoReviewEligible[], auditEvents[]}
```

The main loop emits all caller-side audit rows from the structured return through the **existing printf templates** (single writer; /goal's reader untouched; per-event timestamps captured agent-side via `date -u`). The Step-1.4.5 auto-review intercept stays a main-loop seam (Skill() cross-dispatch cannot run inside agents): the plan returns `autoReviewEligible[]`, the main loop dispatches at most one `/review-pr` per listed PR, then re-invokes merge-plan with `prNumbers:[N]` — the fence-dead `AUTO_REVIEW_DISPATCHED` cap (:173/:507) is eliminated by construction. A 10-PR `--all` run collapses 10 sequential trust turn-barriers (:369) into one burst. `agent()` nulls (user-skip/terminal error) map to a defined skip reason — never a silent drop. Because the plan runs in the background, its ci_red verdicts are point-in-time-at-plan, not at-landing: the landing loop does one cheap rollup re-probe per PR immediately before `gh pr merge`. Lean-fleet option: fold the per-PR preflight stage into the Discover agent (batched) so a 5-PR run stays ~11 agents instead of 16. Before the workflow becomes the default, verify the Workflow tool is exposed and opt-in-eligible inside /goal's dispatch context — /goal drives /merge via `uberdev_dispatch_one` into a detached headless worktree session (goal-state.sh:58/:1413-1421), not via Skill() in its own turn — and that the dispatched session idles/resumes across the workflow's background completion boundary; until then the per-PR Task-loop directives stay the documented DR-10 fallback.

**merge-resolve.js** (invoked per conflicted PR only; conflicts are the rare path) — meta `['Resolve','Test gate']`. Args: `{pr, files[], worktreePath(abs), prBranch, integrationBranch, baseSha, strategy, testCommand|null, cap, nowIso, runId}`.

```text
let reResolveUsed = 0, switchUsed = 0, ctx = null
loop:
  parallel(files → agentType uberdev:conflict-resolver, shared scratch worktree, NO isolation:'worktree'
           — isolation would hide the conflicted state; absolute paths only)
      // BARRIER required: the test gate needs ALL files resolved
      schema {status ∈ [RESOLVED, AMBIGUOUS, REFUSED], artifact_path, resolution_summary,
              textual_evidence{ours,theirs}, out_of_hunk_edits, lines_changed:int,
              files_touched:[string], risks[], eventTs}
      // the int/list fields let the script pre-screen caps deterministically before the
      // main loop's authoritative re-check
  AMBIGUOUS/REFUSED/null → return {status:'park', reason, perFile handoffs}
  test-gate agent runs testCommand in the worktree → {pass, tail}
  on fail: reResolveUsed < 1 → ctx = tail, continue
           else switchUsed < 1 → flip strategy, re-probe merge-tree, continue
           else return {status:'park', reason:'test-fail-exhausted', tail}
  budget.remaining() checked before each retry (DR-8)
return {status:'resolved', strategyFinal, files, decisions[]}
```

The main loop keeps fetch/probe/worktree-create, the conflict-materialization command (underspecified today — the thin SKILL must state it before the workflow can rely on file state), the **FULL pre-commit Red-Flag battery** — not just a conflict-marker re-grep: `git diff --stat` in the scratch worktree checked against PATCH_LINE_CAP/PATCH_FILE_CAP, `lib/secret-scan.sh` over the resolution diff, and a changed-paths assertion that every touched file sits inside the conflict set (rejecting `.github`/`.git`/hooks) — the `chore(merge)` commit, non-force push, `gh pr merge` retry, teardown, and `pr_parked`/`merge_executed` audit rows from the return. The re-resolve(≤1)/strategy-switch(≤1)/park ladder — prose at :752-758 today — becomes enforced code; the PARK-is-terminal-floor invariant cannot drift.

**Keep foreground (merge-R5):** the serialized landing loop's git/gh mutations (`gh pr merge --match-head-commit`, resolution commit, push), Phase-4 local sync on the USER'S checkout, Step-4.5 sweep (fix its 404-semantics — GitHub 404s the protection endpoint for unprotected branches, so the sweep is dead on solo-dev repos at :922 — while rewriting; its read-only probe half, 2 gh calls + merge-tree probe + per-branch decision tree at :904-933, may move into a decisions-only agent or a merge-plan tail stage returning typed `stale_branch_rebase_decision` records — only the rebases themselves must stay foreground), and lock acquire/release. The lock brackets the landing, which is main-loop, so the lock is main-loop; the workflow scripts treat it as **inherited**, never re-acquire (resolves the same-session assumption the two-script split would otherwise break). /goal's auto-chain consumes results synchronously after `Skill(uberdev:merge)` returns — main-loop completion semantics must hold.

**Thin-SKILL rewrite + diet (merge-R4, same PR series):** delete the per-PR Task prose, the compgen block, the worktree-glob triplication, the 12.6 KB default-off Step-1.4.5 body (→ 2 KB seam contract); relocate the 11 CI_* constants consumed only by review-pr (:67-77) — sequenced after (or inside) #302's review-pr extraction, which is concurrently rewriting that exact file, to avoid re-anchoring review-pr's own tests twice. KEEP verbatim: the five-mirror trust-anchor prose (deliberately repeated), force-push prohibitions, no-Claude-trailer rule, the failure-mode table (/goal-consumed semantics), the autopilot contract. Re-point the ~153 `SKILL_FILE`-anchored greps in tests/merge.test.sh (M8/M49/M50/M73 become Workflow-call + script-content asserts) + merge-discovery-resilience A4d/A7 in the same PR; fix the duplicate M64 blocks while there; M47.2/M48.2 `^model: inherit` locks are unaffected. Honest sizing (measured): the deletable 1.4/2.2 dispatch prose is ~35–40 KB (Phase 1.4 = 33,577 B, Phase 2 = 8,693 B), and the kept material (Constants table alone 18,529 B pre-prune, Phase 3/4 directives, run-summary format, failure-mode table, five-mirror prose) puts the thin SKILL at ~25–30 KB — a ~70–75% cut, not 80+. 133,438 B → ~25–30 KB main-session.

### 3.3 `/goal` — hybrid driver; claude-bg workers, serialized merges, disk store untouched

`/goal` is the one pipeline whose bash actually *runs* (a real 60 s watch loop with live breakers) and which fires **zero** Task calls — every worker is a detached session via `uberdev_dispatch_one`. Constraint 5 forbids replacing the workers; the migration replaces the **driver**: today the main session is the bounded-tick harness (goal.md:70), paying a full-context turn per tick (up to ~27/cycle at WATCH_BUDGET=540, × 5 cycles) plus ~18 fence-boundary turns, all riding a conversation seeded with 127,042 B.

**Do-first (#301, goal-R1):**

1. Persist `new_candidates` as a `.candidates` sidecar (mirror the `.queue` writer at goal-state.sh:2274-2282) + flush at the end of Phase-3 fence 1 — the live false-converge BLOCKER (`write_run_state` persists queue/active/scalars but NOT candidates). Add `only_mine` to the same scalar flush (parsed at SKILL.md:135/:146, branched on at :1313, absent from the :2237-2242 scalar block — a fresh Phase-3 fence silently widens the candidate set past the #291 identity filter). Tag the sidecar with the writing cycle number and have `read_run_state` ignore it on mismatch — a fence that crashes between the gh query and its flush must not rehydrate the PRIOR cycle's candidates into the terminal gates.
2. Move the D13 first-10 truncation (SKILL.md:1523-1539) BEFORE the terminal/loop-back fence — dead as sequenced.
3. Bounded watch default `WATCH_BUDGET≈480` under the Bash-tool runtime (≤600 s cap minus one worst-case serial gh walk, per SKILL.md:1244-1252's own sizing note — the budget bounds the upcoming SLEEP, not pass gh-latency) + distinguish harness-TERM (persist + exit 42, **no reap**) from operator INT (reap). Today the 600 s SIGTERM fires the TERM trap → `_uberdev_goal_reap_zombies` (:631-632) and kills every live solver ~10 min in. TERM cannot distinguish an operator `kill -TERM` from the harness cap — post-change, operator stop = INT (Ctrl-C) or the explicit reaper entry, and the TERM path emits a `goal_reaper_skipped` audit row so the choice stays visible post-mortem.
4. Review-pr dispatch-cap exhaustion → transition `pushed-reviewing → red-held` with a distinct audit note instead of the `any_active=1` spin to the 4 h stuck_loop (:876-878; cap-reached returns rc 0 at goal-state.sh:1774-1778).

This PR carries its own grep/fence-anchor sweep — moving the D13 fence and inserting a flush relocates content the goal-pipeline-zsh P3-family slicers and goal.test.sh G-greps cut against (the #175/#177 class lands one PR earlier than the extraction).

**Prep (goal-R2, revised; resolves the Phase-0 contradiction by extracting it too):** hoist **all four** phase bodies into bash-shebang scripts — `lib/goal-phase0.sh` (the inline fence shrinks to resolver + arg-parse + `exec "$UBERDEV_GOAL_BASH" "$CLAUDE_PLUGIN_ROOT/lib/goal-phase0.sh" $ARGUMENTS`; the renderer substitutes `$ARGUMENTS` into real argv words pre-shell, so zsh no-word-split is moot, and ALL goal-state.sh calls — state_init, write_run_state, audit — move inside the script: only with that seam is "every entry point guaranteed-bash" true), `lib/goal-phase1.sh` (:333-602), `lib/goal-watch.sh` (:608-1276), `lib/goal-phase3.sh` (:1286-1539) — invoked as `"$UBERDEV_GOAL_BASH" lib/goal-*.sh`. Wins: the #294 resolver's re-exec arm (SKILL.md:109-116) finally works (`$0` is a real shebang file; it can never fire for inline `zsh -c` fences); the renderer hazard dies for every moved body; ~10 Phase-0 orchestrator turns disappear; the bounded-tick 0/42/1 exit contract becomes a clean script API both the main-session fallback AND the workflow drive; `goal-phase0.sh` prints the canonical Workflow-args JSON verbatim — closing the last LLM-composed handoff (the #288 mis-sequencing seam). Scripts keep the source order (dispatch.sh before goal-state.sh — the rc-4 `command -v` preflights at goal-state.sh:2224-2227/:1768-1771). Dual-shell shim deletion in goal-state.sh is **gated on a separate cross-consumer audit** (review-pr.md:109's locked-marker coupling) AND on retiring/inverting goal-state-zsh.test.sh plus the zsh fixtures of goal-state-sidecar.test.sh (both exist to LOCK lib-under-zsh behavior and would red on the trim) — not claimed by this extraction; until that seam + test retirement land, claim only the watch-path shims, ~half the projected goal-state.sh shrink. The extraction PR's checklist also: delete the zero-consumer `uberdev_goal_locate_review_pr_audit` (goal-state.sh:768-782), dedupe the ×3 inlined `uberdev:active` release logic (SKILL.md:409-416/:736/:755) and the never-used `Task` entry in goal.md:4 allowed-tools; make the per-script EXIT traps real instead of porting the fiction (`gh_err` is mktemp'd at SKILL.md:623 and appears ONLY in the trap at :625 — never a redirect target — while Phase-3's `findings_err` leaks one tmpfile per cycle across the fence boundary); and either delete the unbounded `while true … sleep` legacy watch arm or gate it on an interactive-terminal check — post-R1/R3 both surviving drivers use bounded ticks, so the unbounded arm is defensible only for a real-terminal operator running `goal-watch.sh` directly under bash. Re-anchor goal.test.sh G-greps + goal-pipeline-zsh fence extraction in the same PR; keep the Constants block byte-identical or update G24/G28/G34 together.

**goal-loop.js (goal-R3, revised)** — meta `{name:'goal-loop', description:'autonomous convergence driver', phases:['dispatch','watch','collect','finalize']}`. Args from `goal-phase0.sh`: `{goalId, tmpdir, pluginRoot, bashPath, queue[], maxCycles, maxParallel, barrierTimeoutS, reviewGraceSecs, watchBudgetS:480 (contract-asserted ≤ 540), stuckSecs, backend, onlyMine, startEpoch}`.

```text
let queue = [...args.queue], cycle = 1
try {
  while (true) {
    if (cycle > args.maxCycles) return finalize('max_cycles')
    if (budget.total && budget.remaining() < RESERVE) return finalize('budget_halt')
        // RESERVE sized above one full cycle's spend
    phase('dispatch'): ONE agent runs goal-phase1.sh with the issue list
        // claims + TSV writes + dispatch_one are serial BY DESIGN — no parallel(), nothing needs a barrier
        schema {rc, dispatched[], rolledOver[], claimSkipped[]} ; rc!=0 → finalize('dispatch_failed')
        log(claimSkipped + rolledOver EVERY cycle — cross-process claim collisions surface only on
        fence stderr today, which workflow transcripts never show; this keeps them operator-visible)
    phase('watch'): for t in 1..ceil(stuckSecs/watchBudgetS)+2:
        haiku tick agent: "invoke ${bashPath} ${pluginRoot}/lib/goal-watch.sh with WATCH_BUDGET=480;
        Bash timeout=600000; do NOT kill solver sessions; report exit code + breaker + TSV census"
        schema {exitCode, breaker|null, census{solving,reviewing,merging,held,merged}} ; log(census)
        exit 0 → drained; exit 1 → finalize(breaker); null tick → one retry then finalize('tick_lost') WITHOUT reap
        // 60 s cadence lives INSIDE the tick agent's Bash (constraint 3); wall-clock logic (4 h stuck,
        // 60 m grace, 150 m solve timeout) stays bash-side against persisted epoch anchors (DR-7)
    if (!drained) return finalize('stuck_loop')
    phase('collect'): ONE agent runs goal-phase3.sh (candidates query + fingerprint repeat +
        terminal gates + overflow truncation, IN THAT ORDER)
        schema {rc, verdict ∈ [converge, halt, loop], reason|null, candidates[]}
        converge → finalize('converged'); halt → finalize(reason)
    queue = queue.concat(c.candidates)   // candidates survive in JS — the #301 class is structurally gone;
                                         // bash still mirrors to disk for crash forensics
    cycle++
  }
} catch (e) { return finalize('budget_halt') }   // DR-8: the try wraps the ENTIRE cycle loop — any
    // throw, budget ceiling included, routes to finalize so print_summary, the goal_circuit_breaker
    // audit row and the no-reap policy always execute
finalize(status): one agent runs print_summary + (converged ? cleanup_run_state : breaker-path reaper)
    → {summaryLine, heldPrs[]} — the ONLY bytes that reach the main session
```

Revisions baked in (from falsification): tick, dispatch AND collect prompts all mandate Bash `timeout: 600000` (≥ WATCH_BUDGET + one pass of gh latency — the Bash-tool default is 120 s, and an unpinned prompt gets its watch fence SIGTERMed mid-pass); an **operator abort path ships in the same PR** — a `goal-abort` entry that reads `goal-active-id.txt`, runs `_uberdev_goal_reap_zombies`, releases `uberdev:active` labels and clears run-state (workflow-cancel cleanup semantics are unverified — probe empirically BEFORE the workflow becomes the default driver); the SKILL.md feature-detects the Workflow tool and falls back to the tested bounded-tick main-session harness, which goal.md keeps documented as the PERMANENT non-Workflow drive — using-uberdev targets Copilot/Gemini CLIs that have no Workflow tool — not a stopgap (the W2a-W2f contract stays the canonical tick API consumed by both drivers); the run is **session-bound** — background ≠ survive-the-parent; closing Claude Code mid-run orphans the driver while detached solvers continue (documented, paired with the stale-claim recovery story); `resumeFromRunId` is **forbidden** for goal-loop (DR-9 — prefix replay would return cached "dispatched/merged" results against a moved world); the preflight verifies the orchestrating session itself runs with skip-permissions/allowlist coverage (background agents cannot answer prompts — constraint 1). Detached children keep the env injection `UBERDEV_TURBO=1` + `SKIP_PERMISSIONS=1` + `UBERDEV_GOAL_ID` + `UBERDEV_RESOLVED_BACKEND` (SKILL.md:241-248, dispatch.sh:413-415/:555-557) — without it review-pr's 6c.6 non-turbo arm AskUserQuestions inside a headless session (gate 1 is TTY-safe by design at review-pr.md:282/:309; gate 2 branches on TURBO only).

**Keep (goal-R4):** detached solver/review/merge dispatch (constraint 5); the lowest-first + MERGING-interlock merge barrier (SKILL.md:884-1031 — parallelizing it re-opens the version-bump-collision class that bit twice); the goal-state store layout byte-stable (goal-`<id>` TSVs/jsonl + runstate sidecar + `goal-active-id.txt`) — #310's reader and /merge PATH_2's trust trail depend on it. Per-pass gh-memoization speedups (#301c) live in bash helpers agents still execute — do independently, any time.

**Test re-anchors (goal-R5):** the grep-anchor re-points named in goal-R2's extraction PR — goal.test.sh G-greps + goal-pipeline-zsh fence slicers, with the Constants block kept byte-identical or G24/G28/G34 updated together. Called out as a discrete rec because §9 Phase 7 sequences it explicitly alongside the four-script extraction; the work itself lands in the same PR as goal-R2.

**Joint-migration contract table.** /goal consumes only file globs, gh state/labels, and `claude agents` metadata — which is exactly why the three migrations are feasible, provided these literals survive byte-identically (acceptance checklist for Phases 4/5/7):

| Contract | Producer → Consumer | Must preserve |
|---|---|---|
| Verdict JSON | review-pr.md:954 → goal-state.sh:791-811 | `<checkout-toplevel>/.uberdev/runs/<RUN_ID>/review-pr-verdict.json` inside the PR checkout (root or the three worktree layouts), run-id regex, top-level int `.pr`, lex-greatest run-id wins |
| Trust fields | RP:956-990 → GS:633-713 | `.sha`, `.phases.phase2_5.by_severity.{blocker,critical}`, `.halted`, `.halted_due_to_overflow` — a missing phase2_5 block downgrades every green run to `stale` (re-dispatch storms, cap ×3) |
| SHA binding | RP:866-882 → GS:644-659 | emission order anchor-commit → push → labels → **JSON last** with post-push ANCHOR_SHA, within REVIEW_GRACE_SECS — JSON-before-anchor makes every verdict permanently `stale` |
| RED writes JSON | RP:807 → GS red-held path | the RED path still emits the verdict JSON (else stale|missing cascade → dispatch-cap exhaustion → `queue_empty_not_converged` instead of clean red-held) |
| Locked marker | RP:85-109 → GS:1354-1380 | `runs/<RUN_ID>/{locked, pr-context.json{pr:int}}` written BEFORE the fanout, in the checkout toplevel; mtime = THIS run's write time (freshness-bounded; lossy cleanup tolerated) |
| Finding issues | findings-to-issues → SKILL:1341-1343 | label `review-pr-finding`, `**Tier:** BLOCKER|CRITICAL` bold-markdown, 16-hex fingerprint HTML comment, `Blocks: #<PR>` backref; same `gh` identity for `--only-mine` |
| GREEN label | RP:891-936 → GS:1722-1728 | literal `uberdev-approved` (the phantom `review-pr:green` deadlocked the barrier pre-#289.1); `review-pr:pending` cleared on green ONLY (it is /merge's auto-review backstop trigger) |
| In-flight probe | GS:1793 → GS:1197-1210 | detached child session prompt contains the literal `/uberdev:review-pr <N>` followed by a non-digit (`claude agents --json .name` regex) |
| Dispatch plumbing | dispatch.sh:523/:422 → GS:240-249, 1240-1340 | `solve-bg-status-<key>.json` (`.pid`), `solve-bg-stdout-<key>.log` (mtime activity proxy), worktree/cwd `solve-issue-<key>` naming — else the stuck-breaker and reaper go blind and live merges look idle at 60 m |
| Merge result | MP:698-705 → GS:1428-1472 | `merge_executed`/`pr_parked` rows appended to **top-level** `.uberdev/audit.jsonl` (NOT `runs/<id>/` — the documented-but-unwritten path), int `data.pr`; park enum `refused|ambiguous|test-fail-exhausted|push-non-ff`; gh state MERGED via real `gh pr merge`; CLOSED-without-merge = immediate `merge_failed` halt |
| Claim release | MP:772-825 → SKILL:365-416 | Step-3.4 `uberdev:active` label/assignee removal survives the migration — it is the ONLY releaser on the merge path; without it every merged issue soft-skips (rc 2) forever |
| Merge invocation | GS:1839 → /merge | bare `Invoke the slash command /uberdev:merge <pr> now.` in a fresh detached session; `UBERDEV_GOAL_ID` rehydrated before `should_automerge` (provenance gate + attempt cap ×3) |
| Exit codes | RP:1018-1030 → MP:527-544 | 0/1/2 surfaced as the Skill() return for /merge's synchronous Step-1.4.5 and for finish-branch; /goal never reads rcs (goal.md:9's claim is stale prose) |

### 3.4 `/solve` + `/turbo` launcher — keep shell; hoist to `lib/solve-launcher.sh`

The launcher has zero Task fanout; its heavy step is **detached** dispatch (constraint 5) — a Workflow is the wrong tool (LLM agents running 3 gh calls each is waste). Extract Phase A + Step 4.5 + Phase B into an executable `lib/solve-launcher.sh` run as ONE Bash call.

- **Revised invocation contract:** the command files pass literals — solve.md: `bash "$CLAUDE_PLUGIN_ROOT/lib/solve-launcher.sh" --auto-mode=0 -- $ARGUMENTS`; turbo.md: `--auto-mode=1 --turbo` — so no cross-fence env read exists anywhere (Bash tool calls do not share shell state; solve.md:48's "remains in scope" claim is false). `$ARGUMENTS` stays renderer-substituted into real argv — which *is* the fix. The launcher exports `AUTO_MODE`/`UBERDEV_TURBO`/`SKIP_PERMISSIONS` for its children — and the #97/#241 hygiene unsets run INSIDE the launcher (or its invoking fence): the shell profile re-injects `UBERDEV_TURBO`/`SKIP_PERMISSIONS` into every fresh fence, so an unset in a prior fence protects nothing.
- **Runtime contract stated explicitly:** Bash `timeout` up to 600000 ms, or `run_in_background` + Monitor for batches above ~10 issues (serial validation at 1 gh round-trip/issue, serial claim writes, serial dispatch at 2–8 s/issue plausibly exceeds the 120 s default mid-claim, stranding half-claimed batches; the rollback path runs before any abort).
- Kills the three live #304 bugs at root: bare `$1/$2/$3` (solve-pipeline:66/:83/:615); the for-loop opened :706 / closed :808 across fences; `declare -A` at :309. Rewrite with parallel indexed arrays; add post-write claim verification (the check-then-act TOCTOU at :536); #304's in-script parallel dispatch (background subshells + `wait` + rc files) is a PREREQUISITE for batches above ~15 issues, not an optional follow-up (its own prereq: hoist the per-issue `~/.wezterm.lua` rewrite out of `_uberdev_dispatch_wezterm`, dispatch.sh:626-658 — it races under parallelization).
- ~15 structural-grep anchors re-pointed in the same PR (solve-claim:448-456, dispatch-claude-bg:405-440, turbo-flow:113/:131/:154 awk differential guards, config-override:343-352, solve-pipeline-zsh) — run the FULL test.yml list. SKILL.md shrinks to ~6–8 KB; dispatcher load −66 KB.
- **Keep as-is (solve-R3, documented non-action):** `lib/dispatch.sh` and the claude-bg/wezterm/background mechanism. The per-issue solver children are detached full sessions with independent permission tiers (PERM_FLAG bypass-pair, dispatch.sh:225-231), `--effort max` + `MODEL='claude-opus-4-8[1m]'` pins (:192, test-locked ×4), SOLVE_TIMEOUT 3600 s+ lifetimes surviving the dispatcher, and cross-session observability files /goal polls. The precise boundary: everything before `uberdev_dispatch_one` = this extraction; everything inside the child after spawn = §3.5/§3.6; the spawn line, backend resolver and dispatcher-side monitoring do not move. Zero churn in the four dispatch test files.

### 3.5 Orchestrator design phases — staged hybrid (`solve-design.js`)

The child-session design pipeline (6-agent research fanout → Q&A → spec writer/reviewer/reviser → plan writer/reviewer; ~13 agents per clean medium run, ~24 with retries; every retry ladder, 5/10-min timeout and 2-cycle reviser cap is prose-only at orchestrator/SKILL.md:385/:517/:543/:587) is the best full-workflow candidate in the plugin — **but staged**, because turbo medium/large runs ONLY inside headless `claude --bg`/`nohup` children where Workflow-tool availability is unverified (§10 Q-1), and because the assessment's "exactly one interactive seam" was falsified: there are **three**.

- **Stage 0 — probe (before any build).** Confirm the Workflow tool exists and is invocable under `claude --bg` and `nohup claude -p` children; thin preflight feature-detects — tool present → script path; absent (Gemini/Copilot per using-uberdev:32-40, standalone non-CC, headless-without-Workflow) → retained compact directive fallback (DR-10).
- **Stage 1 — seam contract.** The design burst RETURNS `status:'needs_user_decision'` (with findings) for all three interactive points: Phase-2 Q&A, Phase-3.5 reviser exhaustion (:517-519 — "surface findings to user, ask whether to continue or abort") and Phase-4.5 plan REJECT (:544). The child main loop AskUserQuestions and re-invokes with `resumeFromRunId` — same-session in the child, the sanctioned use (DR-9 exception) — so the cached prefix replays. Turbo keeps log-and-continue inside the script. Interactive shape is two-burst: `workflow(mode:'research')` → main-loop Q&A + visual companion → `workflow(mode:'design', qa_answers)`.
- **Stage 2 — config + contracts.** Preflight reads `fanout_concurrency.research` via config-read.sh into args; the script chunks the topic array into sequential `parallel()` batches when cap < topic count — the runtime cap is fixed `min(16, cores−2)` and `parallel()` exposes no concurrency option, so without chunking the tested [1,50] config surface (config-override.test.sh:381-390) goes dead. Do-first contract fixes (solve-R6, extended):
  - pass `working_dir` at the Phase 3/3.5/4/4.5 dispatch sites + absolute `artifact_path` end-to-end (declared inputs the orchestrator omits at :488/:513/:525; relative paths resolve against the wrong CWD);
  - add `revision_brief` + a **supplied-deps mode** to plan-writer (plan-writer.md:18-26/:45-56): only the file-deps + test-coverage agents of its internal fanout are liftable INTO the script (cached in JS vars) — the wave-decomposer self-check takes plan-writer's OWN draft task list as input and cannot be lifted pre-plan; keep it internal or retire it in favor of plan-reviewer Check 2 (plan-reviewer.md:37-42 already re-verifies cycles/Owns-disjointness/ordering, stronger once the §5 inherit upgrade lands). Revision cycles stop re-running agents on an unchanged spec, and nested-Task-inside-a-workflow-agent (unverified) never fires;
  - update spec-writer/spec-reviewer/plan-writer/plan-reviewer Output sections for schema dispatch (their "final lines of your reply = fenced YAML" contracts conflict with StructuredOutput);
  - re-home the two in-main synthesis fallbacks (:498-503 spec, :529-534 plan) as a fallback-synthesis agent dispatched by the script (the script cannot write files — constraint 6);
  - scrub the stale `--paranoid` refs (spec-reviewer.md:3/:10, spec-writer.md:102/:122/:140, spec-reviser.md:44/:52, plan-writer.md:149/:170);
  - **cache decision**: the research cache has ZERO writers (fresh runs write `.uberdev/research/<RUN_ID>/` at :62; the ~200-line freshness predicate at :73-275 reads `issue-<N>/` at :74) — delete the predicate, reintroduce as a preflight probe only if reuse proves valuable; any write-back agent must resolve the MAIN repo root via `--git-common-dir` (under `--bg --worktree`, `--show-toplevel` returns the worktree top per orchestrator:61/:67 — else the "fixed" cache writes into ephemeral worktrees and silently reproduces the zero-writers defect).

**Design kept as assessed:** `parallel()` for the 6-topic research fanout (BARRIER justified — spec-writer consumes ALL six; research-codebase BLOCKED/null aborts); sequential awaits for the spec/plan chain (single item, each stage needs the prior — `pipeline()` would be wrong) with real reviser counters (`while (cycles < 2)`); `envelope()` wrapping issue-body interpolation at **all** sites including spec-writer/spec-reviewer (:488/:513) plus the `cached-research-issue-<N>` source tag for reused artifacts (:307) — centralizing the per-site prose convention into one enforced helper. Return `{spec_path, plan_path, questions_path, verdicts, decisions, risks}`. Phase 5 (SDD) and Phase 6 (finish-branch) stay in-session: §3.6's script is invoked **directly** by the child main loop, not via `workflow()`, preserving the single nesting level. Child main-session context: ~75–90 KB → ~12–15 KB (the issue body stops being interpolated ×8 into main context). **Brainstorm stays directive** (conversation-shaped: one-question-at-a-time loop, visual companion, single pass into write-plan; its 2–3-agent step-2 fanout is below the payoff threshold); it may later reuse `solve-design.js mode:'research'` with ad-hoc topics — never a bespoke workflow. Preflight residue worth taking: orchestrator/SKILL.md is Skill-rendered with `$ARGUMENTS` substitution exactly like the launcher (the live #222/#225 defences at :92/:101/:221-222/:247/:301 prove the exposure) and its preflight spans multiple fences — hoist it into an executable `lib/orchestrator-preflight.sh` emitting the args JSON in ONE Bash call, leaving the SKILL.md as triage prose + the Workflow invocation.

### 3.6 subagent-driven-dev — hybrid (`sdd-waves.js`); finish-branch stays main-loop

The child session's largest fanout (≥3T+1 agents; 15–25 dispatches for a 5-task plan, ~120–250 KB through controller context) with the plugin's worst breaker gap: four **unbounded** loops (SKILL.md:71/:78/:348, plus the NEEDS_CONTEXT answer-and-re-dispatch ping-pong at :149-152/:187) and the 4f→4h wave-wide barrier holding ALL quality reviews until EVERY sibling's spec review approves.

Meta `{name:'sdd-waves', description:'Wave-by-wave plan execution with two-stage per-task review', phases:['Parse plan','Execute waves','Pre-merge test analysis']}`. Args (preflight, absolute paths — the #308 contract): `{plan_path, spec_path|null, summary_dir|null, tier, worktree_root, test_command, baseline_sha, run_id, ts, caps:{fix_rounds:3, retest_rounds:2, context_rounds:2}}`.

```text
A — parse: haiku plan-parser agent → {tasks[{id,wave,title,full_text,owns[],depends_on[],commit_message}],
    waves[][], test_command}; script-side deterministic validation: acyclic deps, pairwise-disjoint
    Owns per wave (today prose at SKILL.md:131) → violation returns {status:'plan-invalid'}
B — per wave:
    parallel(wave.map(implementer via agentType uberdev:sdd-implementer — shared session CWD,
             NO isolation: plan-declared disjoint Owns sets; ownership map + sibling denylist in brief))
        // BARRIER justified: the controller needs ALL reports for deterministic task-ID-order commits
        // NEEDS_CONTEXT → context-answerer agent → re-dispatch ≤ caps.context_rounds
        // BLOCKED / null → commit completed tasks via gitOp, return {status:'escalation', task, blocker}
    gitOp(thunk) — a promise-chain mutex (gitLock = gitLock.then(thunk)); ALL git mutations across the
        run funnel through ONE git-controller agent: staged-paths commit per task + full suite run +
        regression attribution; ≤ caps.retest_rounds suspected-implementer re-dispatches, then halt
    pipeline(waveTasks, specStage, qualityStage)
        // NO barrier between stages — a spec-approved task flows straight to quality review while
        // siblings fix-loop (the #308 fix); spec-before-quality stays per-task by stage ORDER
        // each stage: loop ≤ caps.fix_rounds {review via agentType (sdd-spec-reviewer anchored on the
        // task commit SHA / uberdev:code-reviewer) → fix via sdd-implementer → gitOp FIX-UP commit
        // (amend ONLY while the task's commit is still HEAD — siblings commit behind it, and a
        // rewrite would invalidate the SHA anchors in-flight reviewers were dispatched with;
        // fix-ups are already permitted by SDD:78)}
    budget.remaining() checked between waves (budget.total may be null — guard); skipped/dead agents →
        commit completed work via gitOp, halt cleanly (no uncommitted-edits limbo in the shared CWD)
C — tier 'large': pr-test-analyzer agent writes YAML to ${summary_dir}/pr-test-analyzer.md as its final
    action — the disk artifact IS the integration point; finish-branch's glob (:139) reads it unchanged
return {status, waves[{tasks[{id,sha,spec,quality,concerns}]}], escalations[], artifacts}
```

- New agent files: `agents/sdd-implementer.md`, `agents/sdd-spec-reviewer.md` (ported from implementer-prompt.md / spec-reviewer-prompt.md); `uberdev:code-reviewer` reused unchanged. Implementer Q&A changes from conversational ("Ask them now", implementer-prompt.md:36-44) to one-shot NEEDS_CONTEXT re-dispatch — a deliberate semantic change. Interactive /solve medium/large routes through SDD too (not just /turbo), so the escalation contract is explicit: on BLOCKED rung 4 the workflow halts AFTER committing completed tasks, the main session surfaces the blocker (AskUserQuestion), and re-runs with `resumeFromRunId` same-session so the cached prefix skips finished waves; "plan is wrong" escalations surface through the return value.
- The new preflight fence newly EXPOSES the renderer class (SDD's SKILL.md has zero bash fences today): no bare `$1/$2/$3` anywhere (awk -v / `${ARGUMENTS}` parsing only), and it must tolerate the `--turbo` positional that write-plan:190 forwards (test-locked at turbo-flow.test.sh:62-63).
- Cross-session durability (cheap, constraint-4-legal): the git-controller agent appends a task-id → commit-SHA checkpoint (`<summary_dir>/sdd-state.json`) after each wave commit, so a FRESH session can re-run the workflow and skip already-committed tasks — landed commits are verifiable ground truth via `git log` — upgrading a mid-run crash from re-pay-all-dispatches to resume-from-last-committed-wave.
- `sdd-waves.js` **never calls `workflow()`** — reserving the single nesting level so solve-design.js can later invoke SDD as a child workflow.
- The main session stays hands-off the worktree while the workflow runs — a hard rule in the thinned SKILL.md.
- Unconditional do-first, retained permanently (sdd-R2): prose caps with the exact names `fix_rounds`/`retest_rounds`/`context_rounds` (the third caps the NEEDS_CONTEXT re-dispatches; overflow routes into the same BLOCKED ladder at :189-195) + per-task-quality-start. This capped directive loop IS the permanent `## No-Workflow fallback` sdd-waves' feature-detect routes to (Copilot/Gemini/Codex per using-uberdev:32-40) — not a stopgap — and the script inherits, not re-invents, the names.
- Do-first (sdd-R3, file-disjoint doc sweep — FOUR sites): SDD:117/:284 "5 agents" → 6; finish-branch/SKILL.md:74's "5-reviewer post-impl-review fanout"; orchestrator:550 retract the retired "SDD internally calls post-impl-review" claim (SDD:90); orchestrator:558 retract `--turbo` forwarding (env-var-only per finish-branch:51/:85). Phrase the SDD count fix as descriptive prose ONLY — never `Skill(uberdev:post-impl-review)`/"Invoke … skill" forms, which post-impl-review.test.sh:110 forbids in SDD — and run orchestrator-phase-6-doc.test.sh + post-impl-review.test.sh + turbo-flow.test.sh in the PR (they anchor the exact prose regions being edited). Declare post-impl-review the reviewer-fanout fact owner and finish-branch the mode-signal owner.
- Tests (sdd-R6 — the SDD lock surface is ~15 assertions, not 3): re-point spec-reviewer-plan-aware.test.sh's three greps (:53-67) at the new agent file; post-impl-review.test.sh:128's heading-existence guards (`### High-Level Flow`, `### Parallel Dispatch Pattern` — preserve the headings in the thinned SKILL.md or re-point the awk anchors) and its :110-118 negative greps (the thinned doc must still never phrase a post-impl-review invocation or `WAVE=final`); turbo-flow.test.sh — keep `UBERDEV_TURBO` named in the thinned SKILL.md (:67-69), zero `finish-branch … --turbo` phrasing (:70-72), Step-4.5/pr-test-analyzer language greppable or re-point ~:388-392, the two /review-pr-Phase-1 cross-references kept or re-pointed (:430-439); assert the thinned SKILL.md mandates the Workflow call; add sdd-waves shape tests (meta literal, no forbidden APIs, caps constants, parallel-for-implementers + pipeline-for-reviews greppable); run the FULL test.yml list.

**finish-branch keeps directive (sdd-R4):** foreground push + `gh pr create` + the fail-soft `review-pr:pending` label backstop /merge probes (:293-300, locked by #95.1-#95.5), two genuine interactive gates (4-option menu :63-72, typed `discard` :328-338), and the Skill chain into review-pr (:306-316) — constraints 1/2/6 all bind. Hardening: pin run identity in a per-worktree sidecar — `$(git rev-parse --show-toplevel)/.uberdev/research/active-run-id`, mirroring RESEARCH_DIR's derivation at orchestrator/SKILL.md:74 — read by the Step-5 handoff. Per-worktree keying makes concurrent solve runs (separate worktrees) collision-free by construction, and within one worktree last-writer-wins is correct (the newest run IS the current run); never an export contract — exports across the claude-bg/Skill process boundary are the failure mode being repaired (the `ls -t` newest-across-runs fallback at :128-135 can cross-attach a concurrent run's questions.md into the wrong PR body); resolve the orphaned `issue-*/post-impl-review.md` glob with the §3.5 cache decision (test G2 locks its presence — move test and glob together). Delete SDD's "Model Selection" section (:164-177) instructing a cheap-model downgrade (sdd-R5 — contradicts the v0.35.0 all-inherit posture). execute-plan, write-plan, using-git-worktrees, dispatching-parallel-agents (+ one paragraph routing 2+-stage or looped fanouts to the Workflow tool) and the six behavioral skills stay directive (sdd-R7).

### 3.7 `/uberscan` + `/ubersimplify` — full workflow, ONE shared `scan-fleet.js`

The cleanest deletion in the plan: the ~300 duplicated bash lines per SKILL (wave loops, ×10 rehydrate stanzas, breakers — already drifted once: ubersimplify never received the #192 halt persistence, so every breaker halt exits 0 false-clean at :713) are **deleted, not librarified** — the answer to #305's `scan-pipeline-common.sh` question is no (§10.3).

**Preflight keeps:** PyYAML check, flag parse, config reads (keys unchanged: `uberscan.areas`/`ubersimplify.areas`/`fanout_concurrency.*`/`max_agents`/`max_new`), RUN_ID mint, `chunk.py --areas` → manifest.json, CB7 backstop, WORKING_DIR_ABS/REPO_SLUG/HEAD_SHA; simplify mode: a **dedicated worktree** `git worktree add <WT> -b ubersimplify/<RUN_ID>` replacing `checkout -b` in the user's checkout — kills the `BASE_BRANCH`-unset → `git checkout ""` class (ubersimplify:499-503) and frees the main checkout during the background run.

**Args:** `{mode:'scan'|'simplify', runId, runDirAbs, chunks (manifest verbatim), severity, lenses, flags{noIssues,noReport,auditOnly,turbo}, startEpoch, wallBudget:3600, floodCap:150, workingDirAbs, worktreeAbs, baseBranch, branchName, repoSlug, headSha, maxNew, doneChunkIds}` — `doneChunkIds` from a preflight `ls` of the RUN_DIR named by an explicit `--resume=<run_id>` flag — resume is explicit plumbing, NOT a freebie: a fresh invocation mints a new RUN_ID and finds an empty dir, and the retiring active-id pointer files (§4.6) cannot serve discovery; `severity` via args fixes the dead-`$SEVERITY` argparse abort (uberscan:517 → report.py:176-178). Simplify-mode area audits read `worktreeAbs`, not the live checkout — the run is background now, so user edits during the audit phase would desync findings from the fix target (the dirty-tree refusal at ubersimplify:41-46 only guarantees identity at t0).

```text
meta phases ['Area audits','Global passes','Aggregate','Apply fixes','Publish','File issues']
phase Area audits:
  parallel(chunks not in doneChunkIds, SLICED into sequential batches by fanout_concurrency.* —
           the user throttle (--concurrency=N, uberscan.md:27; grep-locked at ubersimplify.test.sh:30)
           stays honored rather than silently retired to the runtime cap, a CB5 flood re-check runs
           between slices, and the documented --areas>12 wave-slicing becomes the DEFAULT mechanism
           → agentType uberdev:code-reviewer | uberdev:code-simplifier,
           brief = file list + C2/C-LENS spec + "Write your findings YAML to
           ${runDirAbs}/chunk-NNN-*.yaml (ABSOLUTE); read-only otherwise")
      schema {chunk_id, findings_path, counts, end_epoch}   // counts only — the 15-80 KB transit dies
  + ONE extra thunk in the SAME parallel(): haiku global-pass agent (Semgrep + coverage, fail-soft)
      // barrier kills the Phase-1b race where report.py fail-softs missing global files (report.py:77-84)
CB5/CB4 in JS: flood = Σ counts; elapsed = max(end_epoch) − startEpoch   // no Date.now, no `|| echo 0`
phase Aggregate: ONE haiku runner agent executes report.py / aggregate.py with rc + stderrTail schema
simplify mode, phase Apply fixes: if (!auditOnly && flood ≤ floodCap)
  STRICT manifest-order SERIAL code-fixer loop — a real for-loop with budget checked between iterations
      // serial by design (git-index single writer; deterministic for resume); do NOT pipeline audit→fix
phase Publish (simplify): ONE inherit agent — push -u, gh pr create --body-file, or zero-commit teardown
phase File issues: findings-to-issues via agentType (its own CB6 rate-floor — delete the duplicated fences)
return {runId, mode, areasAudited, totals, partial, haltReason, commitCount, prNumber, prUrl, issueUrls}
```

- Read-only invariant for scan mode shifts from allowed-tools to a post-workflow `git status --porcelain` assert + the retained U2 command-file lock (workflow agents have full tools); drop `Write` from uberscan.md:4's main-session allowed-tools while there — post-migration the thin preflight never re-Writes agent YAML, making the U2 invariant strictly stronger than today (where Write can clobber files).
- `allowed-tools` gains `Workflow` ⇒ the aliases byte-match breaks across 5 surfaces (memory: `project_uberdev_aliases_multi_surface`) — budgeted in the PR.
- uberscan.test.sh U5–U8 + #192 blocks and ubersimplify.test.sh greps (checkout -b, gh pr create, role: tokens) rewritten against the .js in the same PR. report.py/aggregate.py/chunk.py and their golden tests survive byte-identical.
- Breaker-semantics shift documented in the exit-mapping table: CB5 re-checks between slices (above) and still gates the FIX stage + marks the report partial; CB3 (per-wave 900 s) has NO analog and CB4 is observational at the barrier — no script timers exist, so a hung area agent stalls the burst with the runtime's terminal-error→null as the only escape; optionally pass per-agent deadline epochs in briefs so agents self-abort via `date +%s`.
- Publish scan posture: **parity, not regression** — the pre-push secret scan is a finish-branch surface (`lib/secret-scan.sh` is sourced there, not on this path); today's ubersimplify Phase-4 push (:488-545) is equally direct without it, so the workflow Publish agent neither gains nor loses a gate, and the leftover-findings path keeps findings-to-issues' own secret-scan + rate floors. Verified in the PR, not assumed.
- Bridge work only if the migration is >~2 weeks out (scan-R3): replace both `CHUNK_ARRAY=($CHUNK_IDS)` loops with the `while IFS= read -r` idiom + the 3-line ubersimplify #192 port — explicitly throwaway, no lib (if shipped, the hotfixed legacy path doubles as the §4.2 No-Workflow fallback recipe for these two commands; else the fallback is a clean detect-or-refuse). Independent any time: scan-R4 (delete chunk.py's dead `--budget-bytes` mode, port IGNORE/lockfile/oversize/cohesion invariants to area-mode tests; emit skipped-oversize NAMES in the manifest), scan-R5 (fix simplify.md:92/:119's severity-enum doc rot against the pinned `blocker|suggestion` — no test pins the rotted prose, so the fix is lock-safe; delete the duplicated CB6 fences as a PRE-migration independent cleanup, never a post-R1 item — uberscan SKILL:539-540 already cedes ownership to findings-to-issues Step 2; scope any findings-to-issues sweep to /simplify-specific stale phrasing, leaving the four-tier review-pr enum + route_by_severity contract untouched).

### 3.8 `/simplify` — small hybrid (`simplify-pass.js`), staged after scan-fleet

Preflight keeps Phase 1 (diff capture + refusal contract + flags) but writes the diff ONCE to `$RUN_DIR/diff.txt`. Script (meta `['Lenses','Fix','File issues']`; args `{runId, diffPathAbs, runDirAbs, focusHint, workingDirAbs, repoSlug, headSha, prNumber, deferIssues, maxNew:10}`): `parallel(3 code-simplifier lenses Reading the diff by path — envelope text composed by the script around a PATH reference, never the bytes; '## Lens emphasis' + '## Additional Focus' outside)` → JS `dedupeByLocation` (port of simplify.md:89-95 — today the dedup policy is executed by the main session in-context; aggregate.py:57's `dedupe_by_location` is the deterministic reference twin) → haiku writer emits `simplify-final.md` under the `post-impl-review-aggregate` envelope. The workflow is scoped to these READ-ONLY stages; code-fixer + findings-to-issues dispatch from the MAIN LOOP after it returns (or the fix stages into a throwaway worktree, fast-forwarded after) — an in-workflow fixer would commit to the user's live checkout after the turn has returned, a concurrent-edit hazard today's blocking in-turn dispatch structurally avoids, and /simplify has no worktree to fence it. Lens prompts state explicitly that StructuredOutput supersedes the YAML-reply format while mirroring the C-record fields, leaving `agents/code-simplifier.md` byte-stable for tests/simplify.test.sh R1/R3 and review-pr Phase 2. The diff stops transiting the main session ×4 (held once + 3 prompt copies today). tests/simplify.test.sh's #286 envelope-on-the-dispatch-line lock re-anchors to the script in the same PR. Dedupe/schema code is copy-pasted from scan-fleet.js when available (self-contained-script rule), but the prereq is SOFT: the dedupe port is ~50 lines against the aggregate.py reference, so ship simplify-pass.js standalone if scan-fleet slips — /simplify is the higher-frequency surface carrying the diff×4 tax. Same Workflow feature-detect fallback as §3.7.

### 3.9 `/uberthink` — full workflow

Purest candidate: zero interactivity, zero git writes, a pure fan-out/fan-in DAG whose genetic loop the bash layer structurally cannot drive (the loop-back is prose at SKILL.md:1143-1149 — "the while-loop lives in the model's head"). Every #307 defect is an orchestration artifact:

- inert `AGENTS_DISPATCHED` (8 bump heredocs match the file's first line — CB-ISLAND, the guard against genetic-loop runaway, never trips; reproduced by simulation: 101 dispatches, reader sees 1);
- masked Wave-4/7 python (`2>/dev/null || true` at :920/:1270) → empty shortlist → CB-CONVERGE → "the goal as framed admitted no feasible novel approach" delivered for an ImportError;
- Wave-5 dispatch omits the falsifier's REQUIRED `frame_dir` + goal envelope (:1006-1011 vs falsifier.md:53 — physics loses its feasibility floor of record);
- Wave-0's recoverable latency hides in the post-verdict lenses, NOT in the schema-first serialization — that gate is shipped safety behavior (SKILL.md:195-197; refusal report :284 "no agents ran beyond the scope-gate"; RFC 0009:160), and uberthink-frame.md:11's all-four-parallel sentence is the stale doc, not the spec;
- no resume for a ~100-agent run (:79 unconditionally re-mints RUN_ID).

**Thin preflight (~6–9 KB):** git checks, RUN_ID/RUN_DIR mint + tree, personas.yaml→JSON, repo/HEAD, timestamps, resume map from an existing RUN_DIR artifact scan (R1c — cross-session resume rides disk, same-session retries get `resumeFromRunId` free). The model parses flags AND the free-text goal straight into the Workflow args JSON — no `$ARGUMENTS` bash fence ever touches the goal — and `manifest.yaml` is written by the FIRST workflow agent, not preflight bash (the Phase-0 heredoc embeds `$GOAL` today, :176-187); the shell-interpretation win is only real with both.

```text
meta {name:'uberthink', phases:['frame','diverge','gap-gate','combine','falsify','cross-pollinate','rank','deliver']}
args {goal, islands, maxNew, noIssues, handoff, runId, runDir, workingDir, repoSlug, headSha,
      startedAtEpoch, caps{maxAgents, maxFlood, loopBackCap}, personas:<JSON>, donorBrief, resume|null}
S = {dispatched:0, halts:[]}; guard(n) bumps the REAL counter + throws CB-ISLAND/CB-BUDGET past caps
phase frame: VERDICT-FIRST — the schema lens runs ALONE; REFUSE → return {refused, rationale} with
    ZERO sibling agents fired (pre-verdict siblings would write harm-elaboration artifacts —
    assumption teardowns, numeric feasibility floors — to disk for primary-purpose-harm goals);
    on PROCEED, teardown + prior-art + constraints fire IN THE SAME burst as the Wave-1 generator
    fanout — generators consume only frame.md (SKILL.md:554) and the three lens artifacts have no
    consumer before Wave 5, so the overlap recovers MORE latency than de-serializing Wave 0 would,
    gate intact (generators forgo teardown/prior-art paths by design)
    donors come from the schema lens's STRUCTURED return — the :416-435 regex scrape dies
islands: pipeline([1..K], island k =>
    parallel(donorScouts + operators → agentType uberthink-generator; prompts composed by the script:
             persona text from args.personas, goal inside the envelope, framePaths {frame, teardown,
             priorArt, constraints} ALL passed — fixes the write-only teardown/prior-art artifacts)
    moderator agent → gaps[]; parallel(gap regen)
    while (true):  // the genetic loop, finally real
      synths = parallel(['weave','crossover','mutate'] → uberthink-synthesizer, repairSeeds injected)
      shortlist = haiku report-runner agent (report.py Pareto via Bash) — schema {rc, stderrTail, shortlist[]}
          rc != 0 → S.halts.push('TOOLING:'+stderrTail), break   // crash ≠ negative result, EVER
      empty → CB-CONVERGE for this island, break
      fals = parallel(shortlist × 4 lenses → uberthink-falsifier; FAL_HANDLE schema with killCauses
             {description, fatal, repairHint} + 5 feasibility sub-scores)
      fixables = collectFixables(fals); if (!fixables.length || ++loop >= caps.loopBackCap) break
      repairSeeds = fixables)
    // pipeline (NOT parallel-of-monoliths): island 2 runs Wave 3 while island 1 falsifies;
    // the ONLY cross-island barrier is Wave 6 — exactly where pipeline returns
phase cross-pollinate: K>1 → global crossover agent over the union of island finalists
    + one extra parallel() falsify pass over global offspring (never falsified today — a 5-line add)
phase rank: ONE uberthink-arbiter agent → ranked.yaml on disk
phase deliver: report-runner emits dossier + f2i aggregate (rc-checked); findings-to-issues via
    agentType with schema {issuesCreated[], skipped, labelsApplied} — filed-issue numbers surface
    in the return value, not free-text reply
return {runDir, reportPath, topDesigns[], agentsDispatched:S.dispatched, loops, halts,
        nullsByIsland, refusedUrls}
    // parallel() swallows throws to null: nulls are COUNTED and surfaced per island — a dead
    // island must shrink K loudly, never silently (the masked-degradation class, re-imported
    // at orchestration level otherwise)
```

- `--handoff` into brainstorm stays a main-loop seam (interactive). CB-CLOCK is replaced by the budget API + the `/workflows` surface (optionally a haiku `date +%s` probe before the falsify wave).
- Platform: the preflight feature-detects the Workflow tool and emits an explicit graceful refusal ("/uberthink requires the Claude Code Workflow tool") on Copilot/Gemini/Codex — a deliberate DR-10 carve-out (a ~100-agent ideation fleet has no honest inline fallback), with the platform-scope reduction stated in the PR/RFC.
- Forensics: run-state.txt's CB/halt trail and the dispatch-wave*.yaml directive files die with the bash layer, and return-value halts[] + log() lines are session-scoped — an agent-written run-log artifact under RUN_DIR replaces them for cross-run forensics.
- Goal free-text stops being shell-interpreted: today `for arg in $ARGUMENTS` (SKILL.md:116) lets `$(...)`/backticks in a goal string execute in the main session; args JSON ends that.
- Rides the same series, bound to land WITH-or-AFTER the workflow (the deterministic script composes per-lens prompts from args.personas, making omission structurally impossible) — **think-R3 lens diet**: move per-lens Process/allow-list text into personas.yaml stanzas (the relay mechanism already exists; fix its `chr(10)` flattening in the same change); falsifier 23,014 B → ~9 KB + 1–2 KB active-lens text; the 56-call falsify wave drops 1.29 MB → ~0.6 MB; per-run agent bytes ~2.03 MB → ~1.0–1.1 MB, compounding per loop-back. If it must ship standalone first, keep the full Process text in the `.md` files and dedupe only the personas.yaml one-liners the other direction — never strip the `.md` while prompts are still model-composed. Count/shape optimization — removing instructions the agent is told to ignore; policy-clean.
- Tests (think-R4): U5's "SINGLE assistant message"/"emits directives" literals → scriptPath mandate + `node --check` + meta/caps/schema asserts; U6's six CB ids → the script's halt-string vocabulary (names kept); U7's cap → script/args default — keep one prose `cap … 3`/LOOP_BACK_CAP mention in the thin SKILL.md so U7's alternate-form regex stays green without weakening the script-side assert (handoff stays greppable in SKILL.md); U9 → refused-shape return + SKILL refusal render. U1–U4, U8, U11–U12 survive; U10's aliases byte-match does NOT — commands/uberthink.md:4 gains `Workflow`, so the same PR byte-syncs aliases-sync.sh:38, sweeps the 5 alias surfaces (install-aliases.md, uninstall-aliases.md, README.md, tests/aliases.test.sh) and runs tests/aliases.test.sh alongside uberthink.test.sh.
- If the migration defers a release: think-R2 hotfix quartet — `findall(...)[-1]` counter; unmask crashes as a TOOLING halt distinct from CB-CONVERGE (an ImportError must never read as "no feasible novel approach"); Wave-5 FILE-SET brief with frame_dir + goal + working_dir (falsifier.md:51 lists all three as required); and the GATE-PRESERVING Wave-0 variant — after the Phase-0b verdict PROCEEDs, fire teardown/prior-art/constraints AND the entire Wave-1 generator fanout in ONE assistant message (merge the Phase-0b and Phase-1 fences), never a pre-verdict parallel Wave-0, which would fire siblings before the scope gate. Otherwise skip as throwaway; do NOT build `lib/uberthink-state.sh`.

### 3.10 `/testers` — full workflow (`testers-waves.js`) — the proving ground

The default dispatch path **has never worked**: `dispatch_master` (SKILL.md:160) exists nowhere in dispatch.sh (exports are `uberdev_dispatch_preflight/_resolve_env/_one`, dispatch.sh:7-11) and its rc=127 is swallowed by echo + `exit 0` (:159-164) — the documented mode prints "dispatched master" success with nothing running. Workflow IS the background execution the master was for; there is **no durability regression** because the detached path never existed. Constraint-clean across the checklist: no interactivity, the only mutation is `gh issue create` inside findings-to-issues, 8 personas ≪ caps, no nesting.

- **Immediate, unconditional (this week, no migration):** the one-line zsh-safe guard — `command -v dispatch_master >/dev/null || { echo 'error: master dispatch unavailable (#306)'; exit 127; }` — converting the fail-open success-claim into a hard refusal steering users to `--watch`, plus a call/definition grep anchor in a test (per #306's own fix text). Gating the cheapest safety fix behind the migration's staging would be an under-reach on risk.
- **Do-first prereqs:** testers-R2 — zsh-safe `lib/rate-limit-curl.sh`: dual-shell libdir `${BASH_SOURCE[0]:-${(%):-%x}}` (empirically verified in both shells), explicit `rmdir` on every return path replacing the zsh-dead `trap RETURN` (:71 — its leak makes the unbounded `until mkdir` at :70 spin forever), bounded mutex retry, per-call env injection (`RATE_STATE_DIR`/`RPS_CAP` are exported only in the Phase-0 fence today, :121-123, so every persona call returns rc 2 fail-closed), + an ubuntu zsh test case (the 17 existing wrapper cases are bash-only). Step 6, same PR: reconcile persona allowed-tools with the invocation form — every persona Bash entry is pattern-scoped (`Bash(curl*)`/`Bash(echo*)`/`Bash(node*)`/`Bash(date*)`/`Bash(jq*)`), which the compound `export RATE_STATE_DIR=…; source …; uberdev_rate_limit_curl` matches NOWHERE: either extend the persona allowlists to permit it (keeping C5's no-Edit/no-bare-Write contract green) or ship an executable `lib/rl-curl` shim (reads RATE_STATE_DIR/RPS_CAP from its own env or argv) under an allowlistable prefix — and verify actual allowed-tools enforcement for agents during the R1 smoke test: if enforced, the wrapper has NEVER been executable by personas; if decorative, the squad's read-only guarantee rests on prompts alone. Either way, RFC 0006 §Risks' exfil-bandwidth bound ("≤ RPS_CAP × 300 = 3000 requests per persona-wave") is currently vacuous at all three layers — allowlist-unreachable wrapper, env/zsh-broken wrapper, timestamp-blind audit — and the R1/R4 docs update re-grounds that claim while preserving P9's locked phrasing. testers-R3a — add `timestamp:` to the 6 persona `network_request` schema blocks (rate-cap-audit.sh:51-52 silently skips rows without url+timestamp; the breach gate currently audits ~nothing). testers-R3b (dump `browser_network_requests` to `traces/` + audit ingestion — lifts coverage from ~1–2% to full traffic) is effort M and a separate follow-up, NOT an R1 gate.

```text
meta {name:'testers-waves', phases:['waves','synthesis','issue-filing']}
args {runId, runDirAbs, pluginRootAbs, target, surface, rounds (preflight-clamped to [1,10] —
      today SKILL.md:102 accepts any integer, and a large value collides mid-run with the
      1000-agent workflow lifetime cap), rpsCap, maxIssues, personas[], noIssues, watch,
      invariantsPathAbs, invariantIds[], timestampIso}
      // path + IDs, not bytes: personas hold Read and aggregate.py consumes the path — inlining
      // the 1,460 B invariants YAML into ~18 prompts would re-add ~26 KB/run for nothing
let followUps = {}, politeBreach = false, prevWave = null
for r in 1..rounds:
  parallel(6 personas via agentType uberdev:testers-* — prompts inline ABSOLUTE pluginRoot/lib paths,
           `export RATE_STATE_DIR=… RPS_CAP=…; source ${pluginRootAbs}/lib/rate-limit-curl.sh` per Bash
           call, the polite-rate directive, invariant IDs, followUps[p], prevWave path; personas ALSO
           write full canonical YAML to scratch — disk stays the evidence channel, returns stay thin)
      // BARRIER required: aggregation + monitors consume all persona outputs
  aggregate pass A: haiku runner with CLAUDE_PLUGIN_ROOT injected (aggregate.py:143-146 hard-requires
      it), run with --no-audit (new flag) → {rc, findings, verified}
  parallel(monitor-primary + devils-advocate reading the JUST-aggregated wave-r.yaml)
      // restructure fixes BOTH ends: wave-1 monitors gain input, wave-N findings gain cross_refs —
      // necessary, not cosmetic: report.py's ≥2-persona fallback (:96-101) is provably dead because
      // stable_id embeds the persona (aggregate.py:19-20); monitor cross_refs are the ONLY verification
  followUps = primary.followUps; aggregate pass B folds monitor scratch WITH the audit —
      pass B is the SOLE authoritative audit (rc==1 → politeBreach = true): aggregate.py re-globs
      scratch and REBUILDS the wave file, so an audited pass A's synthetic polite_rate_cap row is
      REGENERATED (not deduped away) by pass B and the audit re-fires — auditing both passes works
      only if the script ORs the rcs; one authoritative audit is simpler
  budget guard between rounds
phase synthesis: haiku runner — report.py → report.md (+ f2i aggregate unless noIssues)
phase issue-filing: findings-to-issues via agentType (envelope source=testers-aggregate validated at read)
return {runId, surface, target, rounds, totalFindings, verifiedFindings, politeBreach, reportPath, issues}
```

The main loop prints the Phase-6 summary from the return and **fails the run on `politeBreach`** — the headline contract (SKILL.md:337-340), live for the first time; the thin SKILL.md states this post-Workflow summary/exit-1 mandate EXPLICITLY (it is the one remaining prose directive at the seam) and the R4 shape test greps for it. Renderer hazard at :177 dissolves (the helper moves into the runner agent); the residual `_wave_count`-class exposure is closed robustly by moving any kept helper into `lib/` (the renderer never renders lib files) or env-var passing — bare `$1/$2` anywhere in the SKILL.md body stays renderer-exposed — and flag parsing itself may ride INSIDE testers-waves.js as plain-JS string handling, leaving only the fs-dependent steps (PyYAML check, RUN_ID mint, surface auto-detect, prod-url refusal, mkdir) in the bash fence. The 6 persona `.md` `source plugins/uberdev/lib/...` literals are edited in the R1 PR (agentType reuses the files; the repo-relative paths break on any target repo), and the two monitor `.md`s are NOT reuse-as-is either: testers-monitor-primary.md:13 ("previous wave") and :44 ("Wave 3: follow_ups empty") plus devils-advocate.md:20 contradict the personas→aggregate-A→monitors→merge-B order — both monitor edits ride the R1 PR (no test greps those lines; C4–C7 verified safe) with "final wave" parameterized since rounds is variable. The prompt builder wraps target-derived segments — persona findings, monitor followUps, prevWave summaries — in the external-untrusted-input envelope before embedding them in next-wave prompts (they derive from probing an untrusted target; today's flow is equally raw, but the migration writes a fresh prompt contract and inherits §4.5). Optional second verification channel worth taking: carry the findings array in the persona schema return for in-script ≥2-persona within-wave promotion — monitor-outage-resilient at near-zero cost.

**`--watch` decision:** **retain the inline directive path** as the interactive mode AND the No-Workflow fallback — workflow agent transcripts never reach the main session, so the watch-the-QA-squad UX is otherwise unrecoverable (the progress tree shows status, not transcripts; non-headless browser windows are not a substitute). Port the #299/#300 driveable-loop keying for that path (testers-R5.2 — non-throwaway under this decision). Tests (testers-R4): new shape test (meta literal, forbidden-API greps, scriptPath mandate, `schema_version: 1` retained for C2, testers.md C3) wired into the test.yml UBUNTU run block, then EITHER the windows run block (the test is Git-Bash-portable — grep + `node --check`, none of the python3/PyYAML/mktemp reasons that exile the four existing testers tests) OR the windows-skip-list marker block — one of the two, in lockstep, plus the SYNC comment lists in both jobs; ci-wiring W4 is the gate (note test.yml:107-109 sits INSIDE the ubuntu run block — the windows job starts at :121); **add a real grep-anchor over the preflight's `--rps-cap` validation** — wrapper Cases 1-5 inline-reimplement the regex in a heredoc and protect nothing; grep-only shape check by default, `node --check` as nice-to-have (no setup-node in CI). Honest tally vs #306: bullets 1/4/5 fully structural, bullet 2 partial (persona literals hand-edited), bullets 3/6 are do-first agent-shell work. Caveat: on ≤8-core hosts the 6-persona wave runs ~2-wide (`min(16, cores−2)`) — benign transparent queueing, slower wall-clock.

### 3.11 `/cluster` — hybrid (`cluster-analyze.js`)

**Do-first (light-R5, single-file PR, independent of migration):**

1. Phase-4 meta double-count: when `analyses/meta-clusters.yaml` exists aggregate ONLY it, else the chunk YAMLs, + dedupe by `(lead, frozenset(members))` (SKILL.md:586 globs both; the meta pass passes single-chunk clusters through verbatim per cluster_propose.py:130-132 → duplicate clusters and double-fold attempts under `--execute` — the only live correctness bug, #305 MAJOR).
2. Persist `RUN_DIR_ABS` into the bootstrap pointer — the primary rehydration probe `$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID` (:245) can never exist (RUN_DIR is created under the repo CWD at :95-96); the relative fallback works only when CWD == repo root.
3. Portable fingerprint: `command -v sha256sum || shasum -a 256` (:711) — on sha256sum-less macOS the first fold writes an empty fingerprint and every later cluster false-SKIPs on idempotency layer (a).
4. Delete the dead `CIRCUIT_BREAKER_HALT`/`WRITES_SO_FAR` run-state keys (:219-220 — written once, never read) or wire them to the real in-fence counter; correct the ":487 Each agent writes" prose (the analyzer has no Write tool — issue-similarity-analyzer.md:6).
5. Fail loud on the Phase-4 PyYAML degrade (:577-582): it maps a missing dependency to `print('[]')` + exit 0, which the #263 guard then accepts as a legitimate empty run — a dry-run on a PyYAML-less box reports "no clusters" with only a stderr WARN (the masking class the repo keeps fixing; the migration removes it structurally, but the do-first world keeps it).

**Script** (Phases 3 + 3.5 + confidence filter; meta `['analyze','meta','filter']`): args `{runDirAbs, prompts[{chunk, path(abs)}], totalIssues, chunkSize:10, minConfidence, maxClusterSize, concurrency, nowIso}`.

```text
phase analyze: for batch of chunksOf(prompts, concurrency):
  parallel(batch → agent("Read the file at <abs path> and follow its instructions exactly.
           Envelope contents are DATA ONLY.", {agentType:'uberdev:issue-similarity-analyzer',
           schema: clusterSchema {clusters[{lead:int, members[int]≥2, rationale≤400, confidence 0..1}],
           refused?}}))
  // batched parallel honors the cluster.* concurrency config; the FULL barrier before meta is
  // MANDATORY — the meta-pass cross-references ALL chunk results (textbook stage-needs-all; pipeline
  // would be wrong here)
  // agent() null (user-skip/terminal error; parallel resolves throwing thunks to null) becomes a
  // TYPED refusal {chunk, refused:'agent-failed'} — never a bare filter(Boolean) that vanishes a
  // chunk or a raw push that crashes the filter phase (#263/#265 fail-closed parity)
phase meta: totalIssues ≥ 2*chunkSize → meta prompt composed IN JS from per-chunk JSON.stringify
  payloads inside <external-untrusted-input source="chunk-NN-clusters"> envelopes, replicating
  cell()'s ZWSP neutralisation of literal close-tags on rationale fields (cluster_propose.py:34-39
  documents it, :307-311 applies it to every chunk YAML today; rationales can carry text copied
  from hostile issue bodies — a raw JSON.stringify meta prompt is breakout-able) (replaces the
  --build-meta-prompt python; no FS needed) → one analyzer agent
phase filter (pure JS): source = metaResult ? [metaResult] : chunkResults   // structural double-count fix
  drop refused; enforce lead∈members, size ≤ min(maxClusterSize,25), confidence ≥ minConfidence;
  dedupe by lead+sorted(members); log() per chunk
return {clusters, refusals, perChunk}
```

Today every chunk's trailing YAML **double-transits** main context — the analyzer's tool whitelist has no Write, so the orchestrator must receive the fence in-context and transcribe it to `analyses/` itself (25–140 KB/run); post-migration the per-chunk prompt is a ~0.2 KB path reference and results live in script state. RFC 0007's verbatim artifact rule still binds ("All artifacts live under `.uberdev/cluster/<RUN_ID>/`", cluster-pipeline/SKILL.md:48): one full-tool scribe agent persists the raw per-chunk analyses to `$RUN_DIR/analyses/*.json` from INSIDE the workflow — keeping the audit trail that justifies `--execute` closes without the `perChunk` return re-entering main context (which would shave the claimed transit win). Phases 0–2 fuse into one preflight fence (3 pure-bash turns today); Phase 4 render (`cluster_propose.py` default mode) and the entire fail-closed Phase-5 mutation fence stay main-loop — ledger idempotency, TOCTOU re-checks and `--body-file` discipline are tested determinism; port the C-6 guards verbatim (they live only in the bash being rewritten). The Phase-3 seam feature-detects the Workflow tool and falls back to the existing Task-wave directive path, RETAINING the Phase-3.5 fence + Phase-4 aggregation heredoc as the non-Workflow branch (DR-10; Workflow is Claude-Code-only while using-uberdev:30-40 documents Copilot/Gemini operation). The agent .md gains one line: "when a StructuredOutput tool is available, return the same fields via it" (C3.c field-name greps survive). Tests (light-R6): with the fallback branch retaining those fences, P15-P17/P22 stay GREEN and the node-run unit tests over the script's exported filter/meta-skip functions (skip-at-10/execute-at-25/boundary-at-20 + dedupe) + a static shape gate land as ADDITIVE gates, not replacements; the new test file is wired into test.yml's ubuntu run list AND either the windows run list or the windows-skip-list marker block in the same PR (ci-wiring W4 hard-fails any other shape; node ships on both hosted images, so both-jobs is simplest); cluster.test.sh C6's allowed-tools byte-match moves in lockstep with the `Workflow` addition (5 alias surfaces), and `Task` STAYS in cluster.md allowed-tools for the fallback branch (else C1.allowed-tools.task at cluster.test.sh:91-95 migrates alongside C6).

### 3.12 `/issue` and `/dev` — keep directive, with two reliability edits

- **/issue keeps** (light-R1): Phase 5 is a deliberate draft-confirm gate protecting a GitHub mutation (issue.md:178-180) — constraint 1; the entire fanout is ONE wave of TWO read-only scouts consumed inline on a <30 s-median command (issue.md:13); zero loops/breakers/cross-fence state. Edit (light-R7): stop splicing raw `$ARGUMENTS` into the double-quoted `echo` fence (issue.md:24-26 — `$(...)`/backticks in a description are injection-shaped); adopt dev-pipeline's model-side token parse, keeping only `REPO=$(gh repo view ...)` in bash. Keep the test-locked deprecation literals (issue-causal-fanout.test.sh:103-108).
- **/dev keeps** (light-R2): the LEAD as sole git controller staging chunk-exact paths between build and review waves (dev-pipeline/SKILL.md:20-23,:178-208) is the architecture — constraint 6 leaves no script-sized seam (any workflow degenerates to two single-message bursts the Agent tool already does); the scope gate stops with a user-facing re-route; builders share one tree by design. Edit (light-R3): machine-parseable trailing ```yaml report fences for builders/reviewer (`paths[], smoke_test{cmd,result}, deferred[], blocker`) — Phase 3 stages "the EXACT paths from that chunk's report" parsed from free prose today (:166-175,:185-188); the lead parses the fence, not prose. ~80% of the schema-validation win at zero architectural cost.

### 3.13 Keeps — one-line verdicts

brainstorm (conversation-shaped; §3.5 reuse path noted) · finish-branch (§3.6 hardening) · execute-plan (stop-and-ask gates ARE the product) · write-plan (single-author) · using-git-worktrees (interactive dir-selection + the preflight any workflow needs) · dispatching-parallel-agents + six behavioral skills (flat 2–3-agent one-shots; prose discipline) · hooks (harness lifecycle events — the model-invoked Workflow tool structurally cannot host them; they already run real bash via run-hook.cmd) · aliases-sync + install/uninstall-aliases (ms-fast, zero fanout, battle-tested S1-S15) · lib/config-read.sh (becomes the args seam, §4.3) · lib/secret-scan.sh (gates a foreground push) · install.sh (outside Claude; wrap the two unbounded `claude --print` calls at :46-47 in `timeout 30`) · run-hook.cmd. Opportunistic while touching hooks: document or delete pre-compact's dead `auto-memory.md` contract — the zero-writers proof is repo-grep-scope only, so live-verify no HARNESS surface (e.g. an older/other-platform auto-memory feature) writes `.claude/auto-memory.md` before choosing the delete arm over the document arm; route hooks-cursor.json through run-hook.cmd or document Cursor-on-Windows unsupported, pinned by a shape assert.

## 4. Shared infrastructure (the carrier)

### 4.1 Script location + invocation convention

`plugins/uberdev/skills/<name>/workflow.js` (children under `skills/<name>/workflows/`), invoked **only** via `Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/<name>/workflow.js"}, args)`:

- sibling `.js` files are structurally outside the Skill renderer's substitution surface (the $1/$2/$3 class cannot reach them);
- SKILL.md + script version together; the writing-skills authoring guide ships the workflow conventions (META markers, versioned SHARED blocks, fallback section, thin-preflight pattern) in the Phase-1 carrier PR — in-repo where worktree-dispatched agents can see them (R-15);
- `${CLAUDE_PLUGIN_ROOT}` resolution is precedented (hooks.json:9, install-aliases.md:66);
- the saved-workflow `name` form is **unverified for plugin dirs** — never design around it.

The SKILL.md preflight validates `[ -f "$CLAUDE_PLUGIN_ROOT/skills/<name>/workflow.js" ]` before mandating the call. The using-uberdev primer gains ~3 lines sanctioning skill-mandated Workflow calls (the documented opt-in path) — carried by the §7 hook-diet PR so migrated pipelines are covered from day one.

### 4.2 Workflow opt-in + No-Workflow fallback (infra-R6)

Every migrated SKILL.md carries (a) the Workflow invocation block and (b) a mandatory `## No-Workflow fallback` section — a SHORT degraded recipe (sequential inline execution or the retained legacy path), gated on the model self-checking its tool list ("if Workflow is not among your tools…"). `references/{gemini,copilot,codex}-tools.md` each gain a Workflow row ("no equivalent — use the skill's fallback section"; Gemini lacks even Task per gemini-tools.md:17). Shape guard in tests/workflow-scripts.test.sh: for every on-disk `workflow.js`, the sibling SKILL.md must grep-match both the invocation block and the fallback marker — a migrated pipeline cannot ship workflow-only. The self-check is prose-trust, the same level as all existing platform adaptation; the failure mode (model lacks the tool, follows the fallback) is self-evident at invocation. Fallback recipes stay thin by review convention or the token win evaporates.

### 4.3 Config → args plumbing (infra-R7)

New `uberdev_emit_workflow_args <pipeline> KEY=VALUE...` in `lib/config-read.sh`: jq-assembles the **versioned** envelope

```json
{ "v": 1, "run_id": "...", "now_epoch": 0, "now_iso": "...",
  "plugin_root": "<abs>", "repo_root": "<abs>", "cwd": "<abs>", "config": { } }
```

from values the preflight resolves via the existing `uberdev_read_int_in_range/enum/string` (env > `uberdev.local.md` > default precedence, warn-once sentinels and audit rows untouched), printed between `WORKFLOW_ARGS_BEGIN/END` markers for verbatim relay (DR-2). Contract tests: envelope keys + precedence + the never-eval-a-caller-supplied-env-NAME discipline (config-read.sh:60,134,178,205 are constant-name eval sites today; the helper must preserve that property). **Frozen-time contract documented in the helper:** `now_*` freeze at preflight; mid-run wall-clock gates use agent-side `date` (DR-7). jq becomes a hard dependency for migrated preflights — acceptable: session-start already warns loudly when jq is missing, and the §4.2 fallback covers jq-less hosts.

### 4.4 Test architecture for `.js` scripts (infra-R3)

Zero node-based test infrastructure exists today; the first `workflow.js` must not land uncovered while ~60 bash shape tests keep grepping SKILL.md fences the migration empties. New `tests/workflow-scripts.test.sh` + `tests/_workflow_harness.js`, wired into BOTH CI jobs (repo-relative paths only — no new Unix-only skip-list entries; ubuntu and windows runners preinstall Node):

- **T1 — lint:** `node --check --input-type=module < "$f"` (stdin form — no `.mjs` renames, no `package.json` `type:module` scoping side effects on the plugin) over every glob-discovered `workflow*.js`, + hard-limit greps that red at parse time: no `import`/`require`/`process.`/`fs.`/`Date.now`/`Math.random`/`new Date(` outside SHARED markers; size ≤ 512 KB. The invocation form is asserted IN the test, not left to runner defaults: reproduced on Node v20.19.2 that bare `node --check` REDS on the spec-mandated ESM shape (`export const meta` + top-level await) while ≥22.7's default module detection passes it — an unpinned guard flips on runner-image updates, and a `node --version` echo step does not prevent that.
- **T2 — meta validation:** by convention the `meta` export is a pure-JSON literal between `/* META-BEGIN */` and `/* META-END */` markers (stricter than the spec's "pure literal" — enforced via clear T2 error messages); extracted, `JSON.parse`d, `{name, description, phases[]}` asserted, every `phase()`/`opts.phase` string literal in the script ∈ `meta.phases`.
- **T3 — behavioral dry-run:** the harness preprocesses each script before vm execution — extract/strip the `export const meta` statement (T2 already parses it from the markers) and wrap the remaining body in an async IIFE evaluated via `vm.runInNewContext`, OR use `vm.SourceTextModule` under `--experimental-vm-modules`; the chosen path is encoded in the harness. Faithful stubs — `agent()` canned fixture returns keyed by label/agentType; `parallel` = thunk-throws-to-null + barrier; `pipeline` = no inter-stage barrier + item drop; `phase`/`log` recorders; budget stub with `total` falsy by default; Date/Math sandbox shadows that THROW exactly like the runtime. Fixtures drive args; assertions cover agent-call counts per phase, schema presence on every structured call, breaker firing at configured caps, zero forbidden-global hits. **The dead-circuit-breaker class becomes executed, deterministic tests** — strictly stronger than the grep regime it augments. Each runtime semantic AND the preprocessing step are locked by harness self-tests so stub drift and wrapper bugs are caught by the suite itself (non-vacuous before the first workflow lands).
- **T4 — shared-snippet drift guard:** scripts are self-contained, so shared code is copy-paste; `// === SHARED:<name> v<N> ===` … `// === END SHARED ===` blocks with the same name+version must be byte-identical across scripts (the ci-wiring W4 marker-block philosophy).
- **Fixture discipline (normative):** T3 canned returns and the §4.5 C-2/C-5 sanitizer vectors are exactly the fixture shapes that trip finish-branch's pre-push secret scan — it hard-aborts on contiguous secret-shaped source bytes with no override, and no gitleaks allowlist exists in the repo (the documented self-trip class; latent literals already sit at tests/finish-branch.test.sh:74/:78). Assemble such tokens at runtime (`"AKIA""IOSFODNN7EXAMPLE"`-style concatenation) so source bytes never contain them contiguously.

ci-wiring W1's completeness oracle auto-catches unwired test files; W2/W4's single-windows-job awk ranges (`/shape-checks-windows:/,0`) generalize to N shards with §7's CI work — and W1's ubuntu extraction END-anchors on the same literal job key (ci-wiring.test.sh:51), so any windows shard that renames or reorders `shape-checks-windows:` silently extends the W1 wiring range; the rework covers all three anchors together.

### 4.5 Envelope + injection discipline (binding convention)

The repo-wide envelope grep (157 hits) splits duties three ways across the migration:

- **A — duties in orchestrator prose the migration deletes** → re-implemented in `.js` prompt assembly: pr-diff/CI-log/issue-body/PR-body/commit/label/goal wraps; the `RUN_ID_REGEX` validation before path concat; `--body-file -` rules; slug derive-then-validate.
- **B — agent-side stanzas that survive agentType reuse**: the "Untrusted input handling" sections, envelope leading-byte validators, refusal protocols and WebFetch allow-lists in 28 `agents/*.md` are **load-bearing validators, not boilerplate** (ci-failure-classifier.md:25, code-fixer.md:30, findings-to-issues.md:42, trust-trail-evaluator.md:73-75 refuse on malformed envelopes). Prompt-slimming MUST NOT remove them. The envelope is two-sided: wrapped at assembly, verified at receipt.
- **C — new validation rules** where agent-returned strings reach later prompts or shell:

| C-path | Rule |
|---|---|
| C-1 reviewer text → aggregates → fixer prompts | aggregates written + wrapped by **code** (port report_primitives `cell()`/envelope incl. ZWSP close-tag neutralisation, lib/report_primitives.py:21-89) — never LLM string concat; a reviewer-quoted close tag must not escape the envelope |
| C-2 finding summary → `gh issue create --title` | length-cap + control-char/newline strip + the @/# lookalike substitution applied to titles (the body sanitiser doesn't cover titles today, findings-to-issues.md:182) |
| C-3 classifier/fixer returns → synthetic aggregate, audit event names, suggested commands | enum-validate `failure_class` against CI_FAILURE_CLASS_ENUM; slug-normalise `rationale` before `ci_fixer_refused_<rationale>`; keep the `ci-refused-synthetic` wrap |
| C-4 strategy → `gh pr merge --<strategy>` argv | closed-set validation `{squash, rebase, merge}` in JS before command assembly |
| C-5 rationales/free-text → audit JSONL | JSON-encode via a serializer, never printf-interpolate (dispatch.sh:491 documents the forge/break hazard of the unescaped stream) |
| C-6 cluster fields → fold actions (`gh issue edit/close --comment`) | port the `[0-9]+` number gates, refuse-list labels, mktemp + `--body-file`, fold-marker regex from the rewritten fences — they exist nowhere else |
| C-7 returned `artifact_path`/handles → reads | realpath-prefix-check under the expected RUN_DIR/summary_dir before any read or interpolation |
| C-8 `topic_slug` from issue titles → file paths/branches | adopt dev-pipeline's derive-then-validate allow-list (dev-pipeline/SKILL.md:389-396) as the shared rule |
| C-9 conflict-resolver | add the missing untrusted-input stanza to agents/conflict-resolver.md (zero grep hits today, despite orchestrator/SKILL.md:14 naming conflict markers untrusted) — pointer dispatch stays, hunks are never inlined |

Convention statement (normative): (1) wrap-at-assembly by a shared code helper, never ad-hoc concat, never orchestrator-LLM prose; (2) trusted directives (lens emphasis, schemas, operator flags) stay OUTSIDE the envelope; source tags extend the closed registry (findings-to-issues.md:42) explicitly; (3) every schema-returned string is untrusted until validated — enums against closed sets, paths via realpath-prefix, slugs via allow-list, numbers via `^[0-9]+$` — and re-wrapped with provenance when interpolated into a later prompt; (4) never interpolate returned/external strings into shell commands as words; (5) two-sided enforcement per B above.

### 4.6 Observability

Every run persists `{scriptPath, runId}`; live progress in `/workflows`; `log()` census lines are the operator surface for autonomous loops (goal ticks, scan areas, testers waves); artifacts keep landing on disk because agents write them (constraints 4/6) — crash forensics and cross-session state are unchanged. #310 composes cleanly: the merge lock record gains `workflowRunId`; scan/uberthink tmpdir pointer files retire in favor of the artifact dirs (build `/status` against those, not the pointers); do not extend #310's scope to uberthink — the `/workflows` view covers it.

## 5. Model policy

Baseline: 36 agents `model: inherit`, 6 `model: haiku`. Binding policy: quality always wins — haiku only for mechanical classification/dedup/polling; `CLAUDE_CODE_EFFORT_LEVEL=max` for interactive and all children; in workflow `agent()` calls **omit `model`** so the session flagship flows through. The Workflow enum adds `fable`.

| Change | Rationale | Locks affected |
|---|---|---|
| plan-reviewer **haiku → inherit** (agents/plan-reviewer.md:4) | semantic AC-coverage mapping + the self-described load-bearing wave-disjointness gate; a missed same-wave Owns collision produces parallel write conflicts at SDD execute time — not mechanical | none (turbo-flow.test.sh:383 asserts the NAME only) |
| silent-failure-hunter, type-design-analyzer, comment-analyzer, pr-test-analyzer **haiku → inherit** | judgment reviewers whose blocker verdicts feed an auto-fixer; update the "lightweight lenses pin Haiku" prose (post-impl-review:41/:105; the `tier` input goes dead) | none on these four (verified: post-impl-review.test.sh asserts no model lines); run the known ~6-lock sweep as belt-and-braces |
| testers-monitor-devils-advocate **inherit → fable** | implements the documented Snorkel "structurally different critic — different model tier" countermeasure (devils-advocate.md:14; RFC 0006 §Risks) at zero quality cost — a different flagship, not a downgrade | **prereq:** extend tests/uberthink.test.sh:80's frontmatter enum to `(opus\|sonnet\|haiku\|fable\|inherit)` first; note that enum lock covers only uberthink-* agents, and uberthink's per-agent WANT_MODEL lock (:82-84) stays all-inherit |
| **keep**: research-test-coverage haiku (filename-stem pairing — genuinely mechanical); ci-failure-classifier inherit (hard-locked `^model: inherit$`, review-pr-phase3-ci.test.sh:188-189); bg-child `MODEL='claude-opus-4-8[1m]'` pin (dispatch.sh:192; locked at dispatch-claude-bg:256/:625, solve-effort-flag:283, solve-pipeline-zsh:102/:161); all 6 uberthink agents inherit (U4); trust-trail-evaluator + merge-strategy-decider inherit (M47.2/M48.2) | quality-first + test-locked | — |
| **delete** SDD's "Model Selection" section (SKILL.md:164-177) | it instructs "use a fast, cheap model" for implementation — contradicts the v0.35.0 all-inherit posture | verify no lock greps the prose |
| **NEW workflow micro-agents** (set via `opts.model` — no frontmatter, no lock exposure): **haiku** for mechanical relays — report/aggregate runners, pushers, CI pollers/watch passes, log fetchers, plan-parser, goal watch ticks, clock probes, brief writers (when not summarizing); **inherit** for anything that interprets — git-controller (regression attribution), context-answerer, publishers, brief-builders summarizing >2000-line diffs, goal dispatch/collect/finalize | polling/relay is the policy's haiku carve-out; misclassification at the interpret sites halts or falsely converges multi-hour runs | none |

Net effect: existing-agent haiku population 6 → 1; every judgment path inherits the flagship; mechanical relays go haiku only where the schema keeps them dumb (rc + stderrTail passthrough — promote to inherit if a relay ever gains interpretation duties).

## 6. Token economics (measured `wc -c` unless noted)

| Surface | Today (main-session per run) | After migration | Delta |
|---|---|---|---|
| /review-pr + post-impl-review | 109,220 B static (91,474 + 17,746) + the PR diff pasted into 9 dispatch prompts (20 KB diff ≈ 180 KB payload) + both aggregates re-echoed into fixer prompts + ≤500-line CI logs in-context | ~14 KB (slim command + args + structured return + log lines) | **−87% static; diff×9 → 0** |
| /merge | 133,438 B (8,671 + 124,767) + per-PR Task prompts/YAML returns parsed by convention | ~25–30 KB (thin SKILL keeps lock/landing/sync directives + trust prose; deletable dispatch prose measures ~35–40 KB) | −70–75% |
| /goal | 127,042 B (10,282 + 116,760) at invoke **+ up to ~27 full-context ticks/cycle × 5 cycles + ~18 fence turns**, each riding the seeded conversation | ~16–23 KB total, zero intermediate turns (driver in background; log() + return only) | −85% bytes; **the per-tick turn class is eliminated** |
| /solve //turbo dispatcher | ~75 KB (solve.md 7,145 / turbo.md 7,487 + solve-pipeline 68,276) | ~9 KB (slim command + thin launcher SKILL) | −87% |
| solve child (orchestrator) | ~75–90 KB (48,365 skill + ~25–40 KB dispatch/aggregate incl. issue body interpolated ×8) | ~12–15 KB | −80% |
| SDD controller | 33,854 B bundle + the whole plan held in context + ~120–250 KB dispatch echoes/read-backs (≥3T+1 agents) | ~3–4 KB preflight + 2–4 KB return | **−150–280 KB per medium/large run** |
| /uberthink | ~300–450 KB main (71,268 skill + ~110 prompts + ~110 handles); **~2.03 MB agent-prompt bytes** (falsify wave alone 56 × 23,014 B = 1.29 MB; +~1.4 MB per loop-back) | 12–18 KB main; ~1.0–1.1 MB agent bytes after the lens diet | **−95% main; −45% agent** |
| /uberscan | 38,068 B (2,782 + 35,286) + 15–80 KB findings transit (agents return full YAML the orchestrator re-Writes) | ~12–16 KB | −70–80% |
| /ubersimplify | 40,393 B (3,558 + 36,835) + transit + fixer-aggregate CONTENTS embedded in code-fixer prompts | ~12–16 KB | −70–80% |
| /testers | 16,299 B (2,490 + 13,809) + ~75–245 KB dispatch/return traffic (24 prompts incl. the ~700 B polite-rate directive ×18, 24 returns) | ~8–10 KB | **~10–25×** |
| /cluster | 39,011 B (3,237 + 35,774) + 25–140 KB transit (no-Write analyzer forces orchestrator transcription) | ~28 KB body, ~0 transit | −25–140 KB/run |
| /simplify | 12,203 B + diff×4 (held once + 3 prompt copies) | diff once on disk; path-only prompts | diff-proportional |
| session-start hook | 16,511 B + ~330 B envelope on EVERY startup/clear/compact in every plugin-enabled project (measured split: 5,418 B primer + 11,093 B config schema) | ~5.7 KB | **−66% per session event** |

All workflow `.js` files (~6–25 KB each) ship on disk via scriptPath and never enter context. Agent-side `.md` bytes are unchanged by agentType reuse — only think-R3's lens diet moves that needle. In the solve-chain stack, /review-pr loads LAST when context is fullest (~222 KB cumulative per #302) — §3.1 is the single biggest relief in the plugin.

## 7. Phase 0 quick wins (no migration required)

1. **NOW, unconditional:** `/testers` `command -v dispatch_master || exit 127` guard — fail-open silent no-op → hard refusal (§3.10).
2. **#302 trust criticals** (review-R1): push-after-fixers + envelope-as-file-bytes; fold cancel-dedupe + settle window in if §3.1 slips a cycle.
3. **#301 trio** (goal-R1): `.candidates` sidecar + flush, D13 re-sequence, bounded-watch default 480 s + TERM/INT distinction, cap-exhaustion → red-held; two-process fence-handoff test; grep sweep in the same PR.
4. **#303 bundle** (merge-R1): lock record + explicit release, find-based discovery + STALE reconcile, per-landing fetch, ci_red settle, audit-path docs-fix, merge.md:11 reword.
5. **#304 root fix** (solve-R2): `lib/solve-launcher.sh` extraction with literal mode flags + the 600 s / run_in_background contract; parallel-indexed-array rewrite; claim post-write verification.
6. **#308 contracts** (solve-R6 + sdd-R3): working_dir + absolute artifact paths at all dispatch sites, revision_brief + supplied-deps plan-writer mode, Output-section updates, `--paranoid` scrub, the cache delete-or-fix decision (with the `--git-common-dir` main-root rule), stale-seam doc sweep.
7. **#309 series**, in order: hook diet (infra-R1 — move the 11,093 B config block to `references/configuration.md`; +3 primer lines sanctioning skill-mandated Workflow calls; extend merge.test.sh M54's mirror-site list to the new file; fold infra-R8's drift fixes into the same series since both edit using-uberdev:155-175 — alias counts 7/11/13, CONTRIBUTING's PreToolUse and one-zsh-fixture claims, SSOT-derived count asserts) → CI (infra-R2: `push: branches:[main]` **and** the concurrency group land TOGETHER — the group keys differ per event so the branch filter is the load-bearing half; cancel made ref-conditional, `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`, so the proven minutes-apart sequential-release drive never cancels superseded post-merge main runs and per-commit main CI signal survives; only after #302's benign-cancel dedupe, else every superseded push manufactures red `cancel` rows) → windows job shard + ci-wiring W2/W4 awk-range rework + the stale test.yml:17-19 sizing comment → `lib/bump-version.sh` (infra-R5: 4 manifest surfaces + the 2 `assert_version_bump` call-site args + the 2 cosmetic version echo headers at goal.test.sh:423 / solve-claim.test.sh:271, idempotent, drift-grep pre-check built in, prints the ritual checklist so worktree agents finally see it — CLAUDE.md is gitignored and worktree-invisible; rationale rests on foreground control over destructive tag/release + serialization against /merge landings, **not** on any claim that workflows can't run git — workflow agents can).
8. **Model pins** (§5): plan-reviewer + the four review lenses → inherit; SDD model-prose delete; uberthink enum-lock extension (precedes any fable pin).
9. **testers-R2 + R3a** (zsh wrapper + persona timestamps); **light-R5/R3/R7** (cluster bugfix bundle, /dev report fences, /issue args fix); **scan-R4/R5**; install.sh `timeout 30`; instrument inject-brainstorm-answers' per-prompt wall-clock while touching hooks. Conditional bridges only if their migrations slip >~2 weeks: scan-R3 (zsh while-read + #192 port), think-R2 (hotfix quartet).

## 8. Disposition of open issues #301–#310

| Issue | Disposition |
|---|---|
| #301 goal | **do-first** correctness trio (goal-R1) + the 117 KB diet executed as migration prep (goal-R2 four-script extraction); watch-driver items then **superseded** by goal-loop.js; per-pass gh-memoization speedups **unaffected** (live in bash helpers agents still execute) |
| #302 review-pr | **do-first** the two trust CRITICALs (review-R1); everything else **superseded** by review-pr workflow.js — the 91 KB extraction IS the migration (2.5∥3 overlap, monitor caps, marker lifetime, loop counters, gh-view consolidation, aggregate double-carry) |
| #303 merge | **do-first** merge-R1 bundle (lock, compgen+STALE, stale-tip fetch, ci_red, audit-docs, merge.md:11); trust-evaluator batching, fence-dead auto-review cap, 125 KB diet + grep re-points **superseded** by merge-plan/resolve + thin SKILL (running the standalone diet first would force the ~150-grep re-anchor twice); Step-4.5 404 fix rides the rewrite |
| #304 solve/turbo | **do-first as solve-R2** — the lib extraction fixes the three MAJORs (renderer, cross-fence loop, cosmetic cap) at root; the 68 KB diet is **superseded** by the same PR; serial-claims speedup + triage-signal echo **unaffected** by Workflow — implement inside the extracted script |
| #305 scan/cluster | mostly **superseded** by scan-fleet.js + cluster-analyze.js — including the `scan-pipeline-common.sh` extraction itself (rejected: the duplicated lines are deleted, not librarified); **do-first** carve-outs: light-R5 cluster bugfixes, scan-R4/R5; scan-R3 zsh hotfix only if the migration is >~2 weeks out |
| #306 testers | dispatch_master guard **do-NOW**; zsh rate-limit lib + persona timestamps **do-first** (agent-shell defects no orchestration layer touches); loop/breach/unfileable-wave/TESTERS_FANOUT bullets **superseded** by testers-waves.js; the persona .md path literals are the partial remainder, edited in the R1 PR |
| #307 uberthink | **superseded** by the uberthink workflow (inert counter, masked crashes, Wave-5 inputs, Wave-0 serialization, state boilerplate, resume) with the 1.85 MB token item riding as think-R3's lens diet (agentType alone doesn't cut agent bytes); think-R2 hotfix quartet only if deferred a release |
| #308 orchestrator/SDD | **do-first** the contract fixes (solve-R6 + sdd-R3 + absolute-path args — the workflows need honest contracts either way); plan-revision full-rerun + unbounded SDD loops + wave-wide barriers **superseded** by solve-design.js/sdd-waves.js; cross-session resume **partially** superseded (resumeFromRunId is same-session — disk artifacts remain the mechanism) |
| #309 infra | **do-first, nothing superseded**: hook diet + drift fixes, CI concurrency (sequenced after #302's dedupe), windows shard, bump-version.sh; drop its uberthink token line item once §3.9 lands rather than double-tracking |
| #310 status | **unaffected**: all four run-state stores survive by design (constraints 4/6 keep state on disk); land merge-R1 with/before it so the lock-record shape `{run_id, started_at, workflowRunId?}` is defined once; read scan state from artifact dirs, not the retiring tmpdir pointers; don't extend scope to uberthink |

## 9. Phased roadmap

Each phase = 1–3 PR-sized landings, **sequential releases** (the version-collision class: never parallel-bump), full test.yml run per PR (the SSOT-extraction grep-anchor class), `/uberdev:review-pr` after every push.

| Phase | Content | Gate / sequencing |
|---|---|---|
| **0 — quick wins** (0.36.x → 0.37.0) | §7 items. Internal ordering: #302-R1 before infra-R2's cancel-in-progress; goal-R1 before goal-R2; infra-R1+R8 as one series (same file region) | none — all independent of the Workflow tool |
| **1 — carrier** (0.37.x) | infra-R3 test architecture + harness self-tests; infra-R6 fallback convention + reference rows + shape guard; infra-R7 args helper; uberthink enum-lock extension; **docs:** extend the test-pinned `plugins/uberdev/docs/testing.md` (docs-accuracy.test.sh:26) with the T1–T4 node tiers + `_workflow_harness.js`, and ship the writing-skills authoring conventions (§4.1) — both must land WITH the carrier or the pinned surface ships stale; **Stage-0 probe**: Workflow availability + permission gating + cancel/cleanup semantics + `CLAUDE_CODE_EFFORT_LEVEL=max` propagation into workflow subagents, in-session AND inside detached children (no per-agent effort opt exists in the Workflow API; dispatch.sh:236 pins `--effort max` for bg children precisely because shell exports do not propagate to spawned subprocesses — workflow agents have only assumed session inheritance), under `claude --bg` / `nohup claude -p` (smoking-gun evidence, not assumption) | probe outcome steers Phases 5–7 (script-default vs fallback-default inside headless children); a negative effort answer escalates upstream per §10.2 Q6, never accepts degraded children |
| **2 — proving ground** (0.38.0) | `/testers` → testers-waves.js + testers-R4 tests + persona path-literal edits + the fable pin decision. **Why /testers:** lowest blast radius (the default path never worked → zero regression risk) with maximal constraint coverage per unit risk — validates agentType for plugin agents, schema retry, Playwright MCP reachability, parallel barriers, a real rounds loop, findings-to-issues chokepoint; and it runs in the interactive main session, so the headless question doesn't gate it | Phase 1 |
| **3 — read-only fleets** (0.38.x) | scan-fleet.js (+ 5-surface alias sweep, U-test rewrites) → uberthink workflow + lens diet + U-test re-points → cluster-analyze.js (+ C6 lockstep) → simplify-pass.js last (copy-paste reuse from scan-fleet) | Phase 2 green; each its own release |
| **4 — flagship** (0.39.0) | review-pr workflow.js + post-impl-review absorb-and-tombstone + S15→`classifyBuckets()` upgrade + stale-prose/lock pairs (turbo.md:15 ↔ turbo-flow:443 fixed together) | review-R1 landed; trust artifacts byte-stable per the §3.3 contract table (joint /goal + /merge acceptance criteria) |
| **5 — merge** (0.39.x) | merge-plan.js + merge-resolve.js + thin SKILL + the ~153 grep re-points in one PR series | merge-R1 landed; Phase 4 landed (the trust-stage parses review-pr's verdict JSON — re-run the trust-stage schema check after #302's fixes change its inputs) |
| **6 — solve chain** (0.40.x) | solve-design.js Stages 1–2 (shape per the Stage-0 probe outcome) → sdd-waves.js + the two new agent files + sdd-R6 test moves | Phase 1 probe + Phase 0 contracts; sdd-waves never calls workflow() (nesting reserved) |
| **7 — goal** (0.41.x) | goal-R2 four-script extraction (incl. phase0) + goal-R5 test re-points → goal-loop.js + goal-abort entry + feature-detect fallback | Phases 4–5 landed (goal consumes their artifacts per §3.3); the Phase-1 empirical cancel-semantics answer |
| **8 — closeout** | tombstone re-points (~12 doc cross-refs to post-impl-review — the count INCLUDES README:315's shipped-skill row and README:345's "5 advisory reviewers dispatched in one message" description, neither pinned by any test), dispatching-parallel-agents Workflow paragraph, drop #309's uberthink line item, the goal-state shim audit (separate cross-consumer decision incl. goal-state-zsh.test.sh's parity-contract retirement), memory updates | — |

**Docs strategy per phase (normative — README rot is silent):** each migration phase updates README.md's mechanics prose for its pipeline (README:28/:40-49/:132/:157/:174/:212/:230 describe single-message-fanout/wave/claude-bg shapes Phases 2–7 change) and appends a status annotation to the superseded RFC's orchestration sections — RFC 0006 (Phase 2), 0007/0008/0009/0010 (Phase 3), 0001/0002 where their prose pins review-pr implementation shape (Phase 4), 0005 (Phase 7) — reading "directive-emitter substrate superseded by RFC 0012; contracts, scoring and state machines remain canonical". docs-accuracy.test.sh pins only CONTRIBUTING.md, `docs/testing.md`, RFC 0004 and RFC 0011 (docs-accuracy.test.sh:26-30) — README is NOT pinned, so nothing reds when it lies; appendix item 8 carries this per PR.

**Test strategy per .js PR:** §4.4 T1–T4 + per-pipeline T3 behavioral fixtures (canned returns exercising breaker caps and null-agent paths — secret-shaped fixture tokens assembled at runtime per §4.4) + the re-anchored structural suites named in §3 + a full-suite verify. **Version plan:** one release per landing; `bump-version.sh` (Phase 0) makes the ritual one command; the two `assert_version_bump` call sites move per release as today; the only model-lock edit in the program is the uberthink enum extension (Phase 1).

## 10. Risks, open questions, alternatives rejected

### 10.1 Risk register

| # | Risk | Mitigation |
|---|---|---|
| R-1 | **Workflow tool absent/ungated in headless children** (`claude --bg`, `nohup`) — turbo medium/large and goal-dispatched review-pr/merge re-reviews run ONLY there | Phase-1 Stage-0 probe before Phases 5–7; DR-10 fallback makes absence degrade, not break; if headless lacks the tool, solve-design ships interactive-first and goal keeps the tested main-session harness |
| R-2 | **Workflow-cancel cleanup semantics unverified** — does a cancelled run execute any script cleanup? | empirical check in Phase 1; goal-abort entry + the existing stale-claim/already-merged re-entry guards; agents persist state to disk before returning |
| R-3 | **Named-workflow plugin registration unverified** | DR-1: scriptPath only |
| R-4 | **budget throw skips cleanup** (agent() throws past the ceiling) | DR-8 try/catch → finalize on every loop; RESERVE sized above one cycle/wave; T3 fixtures exercise the throw path |
| R-5 | **Session-bound lifetime misread as durability** — closing Claude Code mid-run orphans a driver while detached solvers continue | documented per pipeline; goal keeps the on-disk store + abort entry + stale-claim recovery story; DR-9 forbids resume for side-effecting loops |
| R-6 | **Background permission stalls** — nobody answers prompts inside a workflow | preflights verify skip-permissions/allowlist coverage (policy: the AUTO tier is collapsed into SKIP); detached children keep the bypass-pair env injection |
| R-7 | **Concurrency-cap mismatch vs config caps** — tested [1,50] surfaces vs the fixed `min(16, cores−2)` runtime cap; `parallel()` has no concurrency option | caps arrive via args; scripts chunk batches when configCap < item count (§3.5 Stage 2, §3.11); config-override asserts re-pointed at the preflight+script pair |
| R-8 | **agentType / nested-Task unknowns** — plugin-namespaced agentType strings; Task availability inside workflow agents | Phase-2 proving ground validates agentType against the live registry; plan-writer's self-fanout is lifted into the script so nested Task never fires |
| R-9 | **Grep-anchor churn** (~153 merge + ~15 solve + 6 goal test files + U5–U9 + P15–P22 + #286 + R8/S15) | test moves land in the SAME PR as each extraction; full test.yml runs every PR; the #175/#177 memory class is the named enemy |
| R-10 | **/goal contract drift during the joint migration** | the §3.3 byte-stable table is the acceptance checklist for Phases 4/5/7 — fail closed, not skewed; a seam that delays artifact emission past the workflow return breaks /goal and /merge identically (both read the same JSON), which is the safe failure shape |
| R-11 | **Envelope regression via "slimming"** | §4.5 B-class stanzas declared load-bearing; C-1…C-9 validators are review requirements; the closed source registry is the only extension point |
| R-12 | **MCP absent headless** | gh/claude CLIs via Bash everywhere; Playwright validated in Phase 2; interactively-authed servers never load-bearing in scripts |
| R-13 | **Low-core hosts serialize bursts** (`min(16, cores−2)`) | benign transparent queueing; documented so wall-clock on a 4-core box doesn't read as a hang |
| R-14 | **Transcript-visibility loss** for watch-style UX | testers retains the inline `--watch` path; autonomous loops surface via log() census + `/workflows`; review/merge halts are terminal so post-workflow surfacing loses nothing |
| R-15 | **CLAUDE.md gitignored + worktree-invisible** (release ritual, conventions) | bump-version.sh prints the checklist (in-repo, worktree-visible); this RFC + the test suite are the durable convention carriers |
| R-16 | **RFC-vs-implementation drift from day one** — this RFC was authored UNTRACKED in a worktree (invisible to main-checkout sessions until committed), and it pre-encodes exact conventions (DR-1 paths, DR-10 fallback, §4.3 args envelope, bump-version.sh) that implementation PRs could silently diverge from | commit the RFC to main before any Phase-0 work; every infra-R3/R5/R6/R7 PR cross-checks its wording against §4 and updates the RFC in the same PR when reality wins |

### 10.2 Open questions

1. Headless Workflow availability + permission gating (R-1) — the Phase-1 probe owns the answer; it determines whether the headless solve chain is script-default or fallback-default.
2. Cancel/cleanup semantics (R-2) — empirical; gates goal-loop becoming the default driver.
3. Plugin-dir saved-workflow names (R-3) — parked; scriptPath suffices indefinitely.
4. Budget API interplay with the effort policy: budget is a *count/shape* ceiling consistent with quality-first (it halts cleanly, never degrades per-agent effort); default `budget.total = null` unless the operator sets a target — confirm the harness default in Phase 2 and document the recommended per-pipeline RESERVE sizings.
5. `fable` in `agents/*.md` frontmatter vs workflow `opts.model` only — the devils-advocate pin lands wherever the registry honors it; the enum-lock extension precedes either form.
6. **Effort propagation** (binding policy: `CLAUDE_CODE_EFFORT_LEVEL=max` everywhere, including spawned children): does max effort reach workflow subagents — in-session, and inside the detached `claude --bg` children where the headless solve chain runs? The Workflow API exposes no per-agent effort opt; dispatch.sh:236 pins `--effort max` for detached children precisely because shell exports do not propagate to spawned subprocesses, and workflow agents have only *assumed* session inheritance. The Phase-1 Stage-0 probe owns the answer; a negative result is an upstream escalation, never grounds to accept degraded children.

### 10.3 Alternatives considered and rejected

- **`scan-pipeline-common.sh` extraction (#305)** — would build and test-anchor a shared shell lib that scan-fleet.js deletes weeks later; the ~300 duplicated lines are removed, not librarified. Only the ~40 stable preflight lines remain shared (acceptable to duplicate).
- **Interim two-pass Task batching for merge trust evaluators** — wasted against merge-plan.js and would re-anchor M73 twice.
- **Per-phase review-pr workflows** — Phase 3 re-enters Phase 1; splitting pushes the fix loop back into the main session, recreating the dead-counter class the migration exists to kill.
- **Full-workflow /goal (workers in-workflow)** — constraint 5: workflow agents cannot be detached, survive-the-parent, independently-permissioned sessions; N issue-solvers under one shared budget/concurrency pool would also be wrong. Same reasoning keeps the merge barrier sequential (parallelizing it re-opens the version-bump collision the barrier exists to prevent).
- **Workflow-izing finish-branch, the merge landing loop, Phase-4 sync, hooks, aliases, or the release ritual** — interaction (constraint 1), foreground-git user control over the highest-blast-radius mutations, and harness-event timing are the product. Stated precisely to avoid planting a false precedent: workflow *agents* CAN run git — these rejections rest on policy/control legs, never on a misread of constraint 6 (which binds only the orchestration script).
- **`lib/uberthink-state.sh` bump-helper extraction** — dies with the directive-emitter; build it only if think-R2 ships standalone and the migration is shelved.
- **Bespoke brainstorm workflow** — its 2–3-agent one-shot fanout is below the threshold where dispatch overhead pays; reuse `solve-design.js mode:'research'` later if wanted; keeping it directive also preserves Gemini/Copilot compatibility for the most user-facing interactive skill.
- **Standalone persist-the-counter fix for merge's `AUTO_REVIEW_DISPATCHED` cap** — merge-plan.js's `autoReviewEligible[]` return makes the cap structural; the bash fix becomes dead work.
- **Keeping post-impl-review SKILL.md as a standalone spec doc** — its cross-references are already test-locked stale (turbo-flow.test.sh:443 pins turbo.md:15's retired claim); the invariant set moves to the review-pr cluster's canonical doc and the file tombstones, with the ~12 doc cross-refs re-pointed at closeout.
- **AUTO permission middle tier for workflow runs** — per binding user policy, AUTO is collapsed into SKIP (`--dangerously-skip-permissions` / allowlist coverage); workflows assume it.

---

## Appendix — shipping checklist template (per migrated-pipeline PR)

1. `skills/<name>/workflow.js` (+ children) with `/* META-BEGIN/END */` markers and versioned `SHARED` blocks.
2. Thin SKILL.md: preflight fence → `WORKFLOW_ARGS_BEGIN/END` JSON → Workflow mandate (scriptPath from `${CLAUDE_PLUGIN_ROOT}`) → `## No-Workflow fallback`.
3. Agent `.md` contract edits named in §3 for that pipeline (Output sections for schema dispatch, added inputs) — same PR.
4. Test moves in the same PR: re-anchored structural suites + §4.4 T1–T4 coverage + full test.yml verify (both job lists where applicable).
5. `allowed-tools` gains `Workflow` ⇒ run the 5-surface alias sweep where the command is aliased.
6. Byte-stable consumer contracts verified: the §3.3 table for the goal/review/merge triangle; fixture oracles (findings-to-issues sample, golden reports) for the fleets.
7. Version bump via `lib/bump-version.sh`; sequential release; `/uberdev:review-pr` after push (mandatory).
8. Docs in the same PR: README mechanics section for the pipeline + the superseded-RFC status annotation (§9 docs strategy — README is unpinned by docs-accuracy.test.sh, so rot is silent without this item).
9. Any secret-shaped test fixture assembles its token at runtime (string concatenation), never contiguous source bytes — finish-branch's pre-push scan hard-aborts with no override (§4.4 fixture discipline).
