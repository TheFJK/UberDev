---
name: scan-fleet
description: Shared fixed-fleet Workflow engine for /uberdev:uberscan (read-only audit) and /uberdev:ubersimplify (preserve-behavior refactor). Not invoked directly — uberscan-pipeline (mode=scan) and ubersimplify-pipeline (mode=simplify) emit args and mandate the Workflow call into skills/scan-fleet/workflow.js. RFC 0012 §3.7 (Phase 3).
model: inherit
---

# Scan-fleet — the shared `/uberscan` + `/ubersimplify` Workflow engine

This skill hosts `skills/scan-fleet/workflow.js`, the single Workflow script that
backs BOTH `/uberdev:uberscan` and `/uberdev:ubersimplify` (RFC 0012 §3.7, Phase
3). It is **not invoked directly by users.** The two pipeline skills
(`uberscan-pipeline`, `ubersimplify-pipeline`) own the user-facing preflight —
flag/scope parsing, `RUN_ID` mint, `RUN_DIR` mkdir, config reads, the PyYAML/jq
probes — then emit the canonical args envelope and mandate the Workflow call into
this script. The `mode` config key (`scan` | `simplify`) is the only branch.

Why one script, not two: in the directive-emitter (SKILL.md bash) era the phases
diverged across un-shareable prose, so two files were unavoidable. In the
Workflow runtime the phases are *functions* branching on `mode` — the
area-packing and per-area-reviewer wave are shared verbatim and the divergence is
~120 lines of guarded code. The carrier's T4 shared-block drift guard + the
single behavioral test entry point make ONE file the lower-maintenance design.

## What the script does (both modes)

1. **pack** — a Bash relay runs `lib/chunk.py --scope … --areas N` and returns the
   byte-balanced area inventory (zero-overflow: every file covered exactly once).
2. **areas** — ONE multi-lens reviewer per area, in `parallel()` waves bounded by
   `concurrency`. scan → `uberdev:code-reviewer` (C2 findings YAML); simplify →
   `uberdev:code-simplifier` (C-LENS findings YAML). Live circuit breakers: CB5
   (cumulative-blocker flood), CB7 (projected-agent ceiling), plus the runtime
   `budget` lifetime cap. (CB3/CB4 wall-clock breakers are dropped — they were
   already dead in the ms-returning directive-emitter fence and the runtime
   forbids `Date.now`; `budget` + CB5 + CB7 cover the live failure modes.)
3. **scan tail** — an inline repo-global Semgrep SAST + test-coverage relay
   (0 dispatched reviewers), then `report.py` aggregates → report + totals +
   `uberscan-aggregate` issue aggregate → `findings-to-issues`.
4. **simplify tail** — per-area `aggregate.py fixer` dedupe, then (unless
   `--audit-only`) a shared branch + SEQUENTIAL `code-fixer` apply (one
   `refactor:` commit per area — sequential because concurrent commits race the
   git index) + ONE `gh pr create`, then `aggregate.py issues` →
   `ubersimplify-aggregate` → `findings-to-issues`.

## Invocation contract (replicated by the two pipeline preflights)

The preflight validates the on-disk script exists BEFORE mandating the call (RFC
0012 §4.1) — a missing/misnamed `workflow.js` on a target install must refuse
cleanly at preflight, not fail later at the runtime layer:

```bash
WORKFLOW_JS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/scan-fleet/workflow.js"
[ -f "$WORKFLOW_JS" ] || { echo "error: $WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; exit 2; }
```

It then emits the args envelope via `uberdev_emit_workflow_args scan-fleet …`
between the `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` markers and mandates,
relaying the JSON **verbatim** (DR-2 — no LLM-composed handoffs):

```
Workflow({scriptPath: "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/scan-fleet/workflow.js"}, <the JSON between the markers>)
```

When the Workflow returns, the pipeline prints its mode-specific summary from the
structured return value (see each pipeline's SKILL.md).

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini/Copilot/pre-Workflow Claude
Code), the two pipeline skills degrade to their retained directive-emitter
recipes — `uberscan-pipeline`'s `## No-Workflow fallback` (chunk.py pack →
per-area `code-reviewer` Task fanout → inline Semgrep+coverage → `report.py` →
`findings-to-issues`) and `ubersimplify-pipeline`'s `## No-Workflow fallback`
(pack → per-area `code-simplifier` → `aggregate.py fixer` → sequential
`code-fixer` apply → push+PR → `aggregate.py issues` → `findings-to-issues`).
Those recipes are the authoritative fallback; this engine skill carries no
standalone directive path of its own.
