---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Same pipeline, no Q&A friction. Accepts multiple issue numbers; dispatches one agent per issue in parallel."
argument-hint: "<issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue (Unattended)

Spawn an autonomous Claude agent in a new cmux workspace per GitHub issue in **#$ARGUMENTS** — multiple issue numbers dispatch in parallel — with **brainstorm Q&A auto-answered**.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2–3 approaches with its recommendation and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` except `uberdev:post-impl-review` is NOT invoked (asymmetry preserved from prior behavior).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). `/uberdev:orchestrator` is dispatched with the unattended-mode flag; `subagent-driven-dev` invokes `uberdev:post-impl-review` once at end-of-issue (consolidated across all waves); large tier additionally fires `pr-test-analyzer` pre-merge. Findings are summarised in the PR body under `## Reviewer findings summary`.

**Multi-issue dispatch:** `/turbo 5 6 7` validates all three issues up front (open + classifiable) and then spawns three independent agents — one terminal tab/workspace each, all running in parallel. If any issue is closed, missing, or fails `gh` fetch, the run aborts before spawning anything (`no agents dispatched`). Override flags apply batch-wide.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]`

- Same flag semantics as `/solve`. `--auto` is orthogonal to `/turbo` — **`/turbo <issue> --auto` is the max-autonomy combo**.
- Multi-issue example: `/turbo 5 6 7` ⇒ three parallel agents, one per issue. Same flag set applies to all three.

## Steps

```bash
export AUTO_MODE=1  # /turbo = unattended mode (post-impl-review omitted in trivial/small; orchestrator gets --turbo)
```

Now invoke the `uberdev:solve-pipeline` skill.
