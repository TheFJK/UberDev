---
name: orchestrator
description: "Writer-subagent orchestrator for /solve and /turbo medium/large tier. Drives a 5-phase pipeline (research fanout → optional Q&A → spec-writer → optional spec-reviewer → plan-writer → subagent-driven-dev). Use when /solve or /turbo prompt invokes /uberdev:orchestrator. Standalone invocation also works for ad-hoc design tasks."
---

# Writer-Subagent Orchestrator

You are the orchestrator. You drive the design+plan+execute pipeline by dispatching dedicated subagents and parsing their structured returns. You hold pointers — paths, shas, summaries — never the raw artifacts.

**Spec:** see `docs/uberdev/specs/2026-04-28-writer-subagent-orchestrator-design.md` for the full design including return contracts and tier profiles.

## Args

The skill is invoked from `/solve` or `/turbo` prompts as:

```
/uberdev:orchestrator [--turbo] [--paranoid] solve issue #N
```

Parse args:
- `--turbo` → skip Phase 2 Q&A; auto-pick recommendation in spec-writer dispatch
- `--paranoid` → enable Phase 3.5 spec-reviewer for medium tier (large tier always enables it)
- `solve issue #N` → fetch issue body via `gh issue view N --json title,body,labels,number`

## Phase pipeline

### Phase 0: setup
1. Generate a run-id: `RUN_ID=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nohead)` (the `|| echo nohead` is defensive — at very early worktree-init the HEAD ref may not yet resolve; the timestamp prefix alone keeps `RUN_ID` unique within a session).
2. Create research dir: `mkdir -p .uberdev/research/$RUN_ID`
3. Fetch issue body and store in a variable for prompt injection.
4. Determine tier from issue labels and content (use the same heuristics as `/solve` and `/turbo` triage tables; default `medium`).

### Phase 1: research fanout (parallel)

Dispatch the research subagents in a SINGLE message with multiple Task() calls. Tier-dependent fanout:

- `small` tier: dispatch only `research-codebase`
- `medium`/`large`: dispatch `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints`

Each Task() prompt MUST include:
- The issue body (verbatim)
- `summary_dir: .uberdev/research/$RUN_ID/`
- A copy of the agent's expected output YAML format

Wait for all to return. Parse each YAML block. If any returns `BLOCKED`, decide:
- For `research-codebase` BLOCKED → abort with diagnostic message (the rest of the pipeline depends on it).
- For other research agents BLOCKED → continue without that research, log a warning.

If parse fails → re-dispatch the failed agent ONCE with the format example pinned at top of prompt. Max 2 attempts; then proceed without that research and log a warning.

### Phase 2: Q&A (skipped if --turbo)

If `--turbo` is set: skip entirely.

Otherwise: ask the user clarifying questions using AskUserQuestion. Use the research bundle to inform the questions (e.g. "research-codebase found that file X follows pattern A but the issue suggests pattern B; which?"). One question at a time, max 3-5 total. Store answers in `qa_answers` (markdown bullets).

If a Q&A answer reveals scope shift, dispatch ONE narrow follow-up research agent (NOT a full fanout) and incorporate its return.

### Phase 3: spec-writer

Dispatch `spec-writer` (single Task() call):
- Inputs: `issue_body`, `research_paths` (4 paths), `qa_answers` (or `auto_pick: true` for --turbo), `topic_slug` (derived from issue title).

Wait for return. Parse YAML.

**Verification:**
1. `[ -f $artifact_path ]` (file exists)
2. `[ $(wc -c < $artifact_path) -gt 200 ]` (non-trivial)
3. `grep -E "^## (Goal|Architecture|Components)" $artifact_path | wc -l` ≥ 3 (required sections present)
4. content sha matches reported `artifact_sha` (recompute and compare)

If any check fails: re-dispatch with verification feedback. Max 2 attempts. Then fall back to **in-main spec synthesis** (do NOT invoke `uberdev:brainstorm` — its handoff would re-trigger plan-writing and conflict with Phase 4):
1. Read all four research summary files.
2. Read the most recent prior spec under `docs/uberdev/specs/` as a template.
3. Synthesise the spec yourself in-main and write it to `docs/uberdev/specs/$(date +%Y-%m-%d)-$topic_slug-design.md`.
4. Set `spec_path` to that file. Log `phase=spec-writer fallback=in-main`.
5. Continue to Phase 3.5 / Phase 4 normally.

### Phase 3.5: spec-reviewer (gated)

Trigger:
- tier == `large` → always run
- tier == `medium` AND `--paranoid` flag → run
- otherwise → skip

If running: dispatch `spec-reviewer` with `spec_path`, `issue_body`, `research_paths`. Parse YAML.

If `verdict: APPROVE` → continue to Phase 4.

If `verdict: REVISIONS_REQUIRED`: dispatch `spec-reviser` with `spec_path` + `revision_brief: <findings>`. Wait for return; verify; loop max 2 cycles. After 2 still REVISIONS_REQUIRED:
- `--turbo` mode: log warning, accept current spec, continue.
- interactive mode: surface findings to user, ask whether to continue or abort.

If `verdict: REJECT` → abort with diagnostic.

### Phase 4: plan-writer

Dispatch `plan-writer` with `spec_path`, `tier`, `topic_slug`. The plan-writer internally dispatches its own Sonnet research subagents — orchestrator just waits for the final return.

Verification: `[ -f $artifact_path ]`, `[ $(wc -c < $artifact_path) -gt 500 ]`, `grep -E "^## Execution Waves" $artifact_path` succeeds, content sha matches.

If verification fails: re-dispatch up to 2 times with feedback. Then fall back to **in-main plan synthesis** (do NOT invoke `uberdev:write-plan` skill — its `## Execution Handoff` will itself transition to `uberdev:subagent-driven-dev`, which would duplicate-invoke once Phase 5 fires):
1. Read the spec.
2. Synthesise the wave-decomposed plan yourself in-main, mirroring the `uberdev:write-plan` template (For agentic workers note, Goal, Architecture, Tech Stack, `## Execution Waves` summary, `## Task N:` blocks with `Depends on:` / `Wave:` / `Owns:` / `Files:` / `- [ ]` checkbox steps).
3. Write to `docs/uberdev/plans/$(date +%Y-%m-%d)-$topic_slug.md`.
4. Set `plan_path` to that file. Log `phase=plan-writer fallback=in-main`.
5. Continue to Phase 5.

### Phase 5: subagent-driven-dev

Invoke `uberdev:subagent-driven-dev` skill (NOT a Task() — actual skill invocation via Skill tool). Pass `plan_path`. **If the orchestrator was invoked with `--turbo`, also pass `--turbo`** so the downstream chain (`subagent-driven-dev → finish-branch`) stays unattended and `finish-branch` auto-selects "Push and Create PR" instead of prompting. The existing skill handles wave dispatch, review, and PR creation.

## Tier profiles (summary)

| Tier | Research fanout | Spec reviewer | Plan-writer internal research |
|---|---|---|---|
| trivial | (orchestrator should not be invoked; if it is, fail with diagnostic) | — | — |
| small | 1 (codebase only) | none | 1 |
| medium | 4 | gated by --paranoid | 3 |
| large | 4 | always | 3 |

`--turbo` orthogonally skips Phase 2 Q&A. Tier classification rule: same as `/solve` triage table (read from issue labels + body).

## Failure recovery summary

For every subagent dispatch:
1. Verify artifact (path exists, size, expected sections, sha match) and YAML return parses.
2. On failure: re-dispatch ONCE with verification feedback prepended.
3. After 2 attempts: fall back to in-main equivalent for that single phase, log warning, continue.
4. Hard timeouts: 5min research, 10min spec/plan. Timeout counts toward the 2-attempt budget.

Spec-reviewer fix loop max: 2 reviser cycles.

## Logging

For every phase, write a one-line log to `.uberdev/research/$RUN_ID/orchestrator.log`:
```
[<ISO ts>] phase=<name> agent=<name> status=<status> attempt=<n> note=<...>
```

This is the trail for the issue's "telemetry/measurement" acceptance criterion.

## End-of-pipeline

After Phase 5 completes (subagent-driven-dev returns control), the orchestrator's job is done. The downstream skill handles PR creation per its own flow.

## Standalone invocation (no /solve or /turbo)

The skill can be invoked directly: `/uberdev:orchestrator solve issue #N`. Behaves the same — useful for testing or for users who want orchestrator-style pipeline without the spawning overhead of `/solve`.
