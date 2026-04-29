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
- `--paranoid` → DEPRECATED no-op. Spec-reviewer is now always-on for medium AND large. Flag is still accepted for back-compat; orchestrator emits a one-line `notice: --paranoid is deprecated; spec-reviewer always runs for medium/large` warning when seen. Removal target: v1.0.0.
- `solve issue #N` → fetch issue body via `gh issue view N --json title,body,labels,number`

## Phase pipeline

### Phase 0: setup
1. Generate a run-id: `RUN_ID=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nohead)` (the `|| echo nohead` is defensive — at very early worktree-init the HEAD ref may not yet resolve; the timestamp prefix alone keeps `RUN_ID` unique within a session).
2. Create research dir: `mkdir -p .uberdev/research/$RUN_ID`
3. Fetch issue body and store in a variable for prompt injection.
4. Determine tier from issue labels and content (use the same heuristics as `/solve` and `/turbo` triage tables; default `medium`).

### Phase 1: artifact-reuse short-circuit (medium/large only)

Before dispatching the research fanout, check `.uberdev/research/issue-<ISSUE_NUM>/` for already-collected artifacts. Mirrors the algorithm from `brainstorm/SKILL.md:87-131` (which itself was extended in this PR for parity), but extended to 6 topics.

```bash
RESEARCH_DIR=".uberdev/research/issue-$ISSUE_NUM"
SHORTCIRCUIT_CODEBASE=0
SHORTCIRCUIT_PATTERNS=0
SHORTCIRCUIT_PRIOR_ART=0
SHORTCIRCUIT_CONSTRAINTS=0
SHORTCIRCUIT_SECURITY=0
SHORTCIRCUIT_TEST_COVERAGE=0
if [ -d "$RESEARCH_DIR" ]; then
  ISSUE_UPDATED_ISO=$(gh issue view "$ISSUE_NUM" --json updatedAt --jq .updatedAt 2>/dev/null)
  if [ -z "$ISSUE_UPDATED_ISO" ]; then
    echo "warning: failed to fetch issue #$ISSUE_NUM updatedAt; using full parallel dispatch" >&2
  else
    ISSUE_UPDATED_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ISSUE_UPDATED_ISO" +%s 2>/dev/null \
                        || date -d "$ISSUE_UPDATED_ISO" +%s 2>/dev/null)
    for TOPIC in codebase patterns prior-art constraints security test-coverage; do
      F="$RESEARCH_DIR/${TOPIC}.md"
      [ -f "$F" ] || continue
      if ! grep -q '^summary:' "$F"; then
        echo "warning: $F missing 'summary:' field; using full parallel dispatch for $TOPIC" >&2
        continue
      fi
      F_MTIME_EPOCH=$(stat -f %m "$F" 2>/dev/null || stat -c %Y "$F" 2>/dev/null)
      if [ -z "$ISSUE_UPDATED_EPOCH" ] || [ -z "$F_MTIME_EPOCH" ]; then
        echo "warning: failed to normalise updatedAt or $F mtime; using full parallel dispatch for $TOPIC" >&2
        continue
      fi
      if [ "$F_MTIME_EPOCH" -lt "$ISSUE_UPDATED_EPOCH" ]; then
        continue
      fi
      VAR="SHORTCIRCUIT_$(echo "$TOPIC" | tr '[:lower:]-' '[:upper:]_')"
      declare "$VAR=1"  # was: eval "$VAR=1" — safer indirection, no shell-injection risk if VAR ever becomes attacker-controlled
    done
  fi
fi
```

For each `SHORTCIRCUIT_<TOPIC>=1`: copy the artifact from `.uberdev/research/issue-<N>/<topic>.md` to `.uberdev/research/$RUN_ID/<topic>.md` so downstream phases (spec-writer, plan-writer) receive a uniform `research_paths.<topic>` path regardless of source.

After the short-circuit pass, dispatch Phase 1 fanout (below) but gate each `Task()` call with `[ "$SHORTCIRCUIT_<TOPIC>" -eq 1 ] || ` so reusable artifacts skip dispatch. Single-message constraint preserved: the message contains all `Task()` calls structurally; per-topic skips at runtime do not split the message.

### Phase 1: research fanout (parallel)

Dispatch the research subagents in a SINGLE message with multiple Task() calls. Tier-dependent fanout:

- `small` tier: dispatch only `research-codebase`
- `medium`/`large`: dispatch `research-codebase`, `research-patterns`, `research-prior-art`, `research-constraints`, `research-security`, `research-test-coverage` — gated by per-topic SHORTCIRCUIT_<TOPIC> flags. All Task() calls remain in a single message.

Each Task() prompt MUST include:
- The issue body (verbatim)
- `summary_dir: .uberdev/research/$RUN_ID/`
- A copy of the agent's expected output YAML format

Wait for all to return. Parse each YAML block. If any returns `BLOCKED`, decide:
- For `research-codebase` BLOCKED → abort with diagnostic message (the rest of the pipeline depends on it).
- For other research agents BLOCKED → continue without that research, log a warning.

If parse fails → re-dispatch the failed agent ONCE with the format example pinned at top of prompt. Max 2 attempts; then proceed without that research and log a warning.

### Phase 2: Q&A

**Non-turbo (interactive):** unchanged — ask 3-5 clarifying questions one at a time via AskUserQuestion, store in `qa_answers`. Use the research bundle to inform the questions (e.g. "research-codebase found that file X follows pattern A but the issue suggests pattern B; which?"). If a Q&A answer reveals scope shift, dispatch ONE narrow follow-up research agent (NOT a full fanout) and incorporate its return.

**Turbo (`--turbo` set):** instead of skipping entirely, generate the same set of clarifying questions in-thread, auto-pick each answer using the spec-writer's `decisions`-block synthesis logic (best guess from research artifacts), and write to `.uberdev/research/$RUN_ID/questions.md` in the format below (Q-N heading, `**Auto-pick:**`, `**Rationale:**`, `**Confidence:** high|medium|low`). The `decisions` array fed to spec-writer has the same shape as a non-turbo run, just with `auto_pick: true` flagged.

Format:
```markdown
## Q1: <verbatim question>
**Auto-pick:** <chosen answer>
**Rationale:** <one sentence>
**Confidence:** high | medium | low

## Q2: ...
```

`finish-branch` reads `questions.md` from `.uberdev/research/$RUN_ID/` and appends a `## Open questions answered by /turbo` section to the PR body — see `finish-branch/SKILL.md`.

### Phase 3: spec-writer

Dispatch `spec-writer` (single Task() call):
- Inputs: `issue_body`, `research_paths` (up to 6 paths for medium/large; 1 for small), `qa_answers` (or `auto_pick: true` for --turbo), `topic_slug` (derived from issue title).

Wait for return. Parse YAML.

**Verification:**
1. `[ -f $artifact_path ]` (file exists)
2. `[ $(wc -c < $artifact_path) -gt 200 ]` (non-trivial)
3. `grep -E "^## (Goal|Architecture|Components)" $artifact_path | wc -l` ≥ 3 (required sections present)
4. content sha matches reported `artifact_sha` (recompute and compare)

If any check fails: re-dispatch with verification feedback. Max 2 attempts. Then fall back to **in-main spec synthesis** (do NOT invoke `uberdev:brainstorm` — its handoff would re-trigger plan-writing and conflict with Phase 4):
1. Read all available research summary files.
2. Read the most recent prior spec under `docs/uberdev/specs/` as a template.
3. Synthesise the spec yourself in-main and write it to `docs/uberdev/specs/$(date +%Y-%m-%d)-$topic_slug-design.md`.
4. Set `spec_path` to that file. Log `phase=spec-writer fallback=in-main`.
5. Continue to Phase 3.5 / Phase 4 normally.

### Phase 3.5: spec-reviewer (always-on for medium and large)

Trigger:
- tier == `medium` OR tier == `large` → ALWAYS run (always-on per #11 design — replaces the prior --paranoid gate)
- tier == `small` or `trivial` → skip (these tiers don't go through orchestrator)

If `--paranoid` was passed, log the deprecation notice from the Args section but otherwise proceed — the flag is a no-op.

Dispatch `spec-reviewer` with `spec_path`, `issue_body`, `research_paths`. Parse YAML.

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

### Phase 4.5: plan-reviewer (always-on for medium and large)

After plan-writer's verification passes, dispatch the `plan-reviewer` agent (single Task() call) with `plan_path`, `spec_path`, `tier`. Parse the universal reviewer YAML (`verdict: APPROVE/REVISIONS_REQUIRED/REJECT`, `findings[]`, `confidence`).

- `verdict: APPROVE` → continue to Phase 5.
- `verdict: REVISIONS_REQUIRED` → re-dispatch `plan-writer` ONCE with `spec_path` + `revision_brief: <findings>` prepended. Hard cap at 1 retry. After 1 retry: log `phase=plan-reviewer status=revisions-exceeded note=proceeding-with-current-plan` and continue to Phase 5 with the current plan (matches the research-agent retry budget; non-blocking).
- `verdict: REJECT` → log critical, surface findings to user (interactive) or write to `$RUN_ID/orchestrator.log` and continue (turbo, since blocking would defeat unattended mode).

Trivial/small tier bypass orchestrator entirely; plan-reviewer is N/A there.

### Phase 5: subagent-driven-dev

Invoke `uberdev:subagent-driven-dev` skill (NOT a Task() — actual skill invocation via Skill tool). Pass `plan_path`. **If the orchestrator was invoked with `--turbo`, also pass `--turbo`** so the downstream chain (`subagent-driven-dev → finish-branch`) stays unattended and `finish-branch` auto-selects "Push and Create PR" instead of prompting. The existing skill handles wave dispatch, review, and PR creation. `subagent-driven-dev` internally calls `uberdev:post-impl-review` after each wave completes — see `plugins/uberdev/skills/post-impl-review/SKILL.md`. Findings are advisory at this layer (non-blocking on `REVISIONS_REQUIRED`); the auto-fix loop is deferred per Q1 of the design spec.

### Phase 5.5: pr-test-analyzer (large tier only, pre-merge)

After `subagent-driven-dev` returns control and BEFORE `finish-branch` dispatches PR creation, large-tier runs dispatch the `pr-test-analyzer` agent (single Task() call) with `commit_range` (`HEAD~N..HEAD` covering all wave commits), `spec_path`, `plan_path`, `acceptance_criteria` extracted from the spec, AND `summary_dir: .uberdev/research/$RUN_ID/`. The dispatch prompt MUST require the agent to write its findings to `<summary_dir>/pr-test-analyzer.md` (the canonical path `finish-branch` reads from when composing the PR body's `## Reviewer findings summary` section).

Parse the analyzer's YAML return (`gaps[]`, `severity`, `confidence`). Append findings to the orchestrator's run-summary used by `finish-branch` for the PR body's `## Reviewer findings summary` section.

Why large-only: signal-to-noise on smaller changes is poor; medium tier may revisit after metrics. (Per spec Open question 2.)

## Tier profiles (summary)

| Tier | Research fanout | Spec reviewer | Plan reviewer | Plan-writer internal research | Post-impl review | pr-test-analyzer |
|---|---|---|---|---|---|---|
| trivial | (orchestrator should not be invoked) | — | — | — | — | — |
| small | 1 (codebase only) | none | none | 1 | — (orch not invoked) | — |
| medium | 6 (gated by SHORTCIRCUIT_<TOPIC>) | always | always | 3 | per-wave (via SDD) | — |
| large | 6 (gated by SHORTCIRCUIT_<TOPIC>) | always | always | 3 | per-wave (via SDD) | pre-merge |

`--turbo` orthogonally skips Phase 2 Q&A (replaced with auto-pick + questions.md log). Tier classification rule: same as `/solve` triage table (read from issue labels + body).

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
