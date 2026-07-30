---
name: uberthink-pipeline
description: Use when /uberdev:uberthink is invoked. Read-only cross-domain ideation — a VERDICT-FIRST scope gate, then K parallel evolutionary islands (diverge → gap-gate → combine → deterministic Pareto converge → falsify → genetic loop-back) → cross-pollinate → rank → dossier + GitHub issues. The orchestration runs in skills/uberthink-pipeline/workflow.js (RFC 0012 §3.7, Phase 3); this skill is the thin preflight + args seam.
model: inherit
---

# Uberthink Pipeline (thin seam over the uberthink Workflow)

Owns the user-facing lifecycle of `/uberdev:uberthink`. Read-only ideation — no
agent writes application source files. The orchestration (scope gate, per-island
Waves 1–5 with the genetic loop-back, cross-pollination, ranking, dossier render,
issue filing) runs in **`skills/uberthink-pipeline/workflow.js`**. This skill does
only the filesystem-dependent preflight the Workflow script cannot — flag/goal
parse, `RUN_ID` mint, run-tree `mkdir`, config reads, the PyYAML probe — then
emits the canonical args between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` and
mandates the call.

## Why this migrated (RFC 0012 §3.7)

The pre-migration pipeline was a 1539-line directive-emitter whose run ledger
(`run-state.txt`) was *designed* as a key/value store and *implemented* as an
append-only log. Three shipped defects all traced to that one root cause, and all
three die with the migration:

1. **The fleet ceiling was inert.** Every counter bump read the dispatched-agents
   line with a first-match regex — forever the Phase-0 seed of `0` — while every
   reader took the last appended line. Waves of 3+32+2+6 left the file as
   `0,3,32,2,6`: the reader saw 6, the true total was 43, and `MAX_AGENTS` was
   unreachable, so **CB-ISLAND could never halt a runaway genetic loop**. The
   counter is now one JS variable behind `guard(n)`, which throws before a fanout
   it cannot afford.
2. **Masked crashes were delivered as substance.** The Wave-4 Pareto cut and the
   Wave-7 floor cut ran as inline heredocs with stderr discarded and the exit
   code swallowed, so a module-load failure wrote no shortlist → zero falsifier
   dispatches → CB-CONVERGE → a ~90-minute run reported *"the goal as framed
   admitted no feasible novel approach"*. Both cuts are now `report.py` CLI modes
   with real exit codes; a non-zero rc becomes a `TOOLING:` halt that **can never
   route to CB-CONVERGE**, and it also blocks the rank phase so no dossier can be
   built from artifacts that were never written.
3. **The Wave-5 file-set brief was missing.** Dispatch rows carried
   `island_index`/`lens`/`composite_id`/`composite_path`/`summary_dir` and no
   `frame_dir`, while `agents/uberthink-falsifier.md` declares `frame_dir`
   mandatory and the `physics` lens must read `constraints.md`. The falsifier
   prompt is now composed by the script from script-derived frame paths, so the
   omission is structurally impossible.

The **scope gate stays verdict-first**: the `schema` lens runs alone and its
`PROCEED|REFUSE` verdict is read before any sibling agent is dispatched. There is
no pre-verdict parallel Wave 0 — that refusal path is shipped safety. What
changed is that after `PROCEED`, the three remaining Wave-0 lenses fire in the
**same burst** as the Wave-1 generator fanout.

## Reuses

- `skills/uberthink-pipeline/report.py` — 4-axis scoring, the Wave-4 `--emit shortlist` Pareto cut, the Wave-7 `--emit floor-survivors` cut, `--emit dossier`, `--emit aggregate`.
- `skills/uberthink-pipeline/personas.yaml` — donor catalog + persona/lens library (SSOT; relayed verbatim into every wave prompt, agents never re-read it).
- `lib/report_primitives.py` — `cell()` / `envelope()` (consumed by report.py).
- `lib/config-read.sh` — `uberdev_read_int_in_range` + `uberdev_emit_workflow_args`.
- `agents/uberthink-{frame,generator,moderator,synthesizer,falsifier,arbiter}.md` — the wave agents.
- `agents/findings-to-issues.md` — durable GitHub issue persistence (accepts the `uberthink-aggregate` source).

## Artifact layout

```
$RUN_DIR/                                       # .uberdev/think/<RUN_ID>/  (absolute)
  frame/
    frame.md                                    # schema lens (Cartographer) — locked
    scope-verdict.yaml                          # verdict: PROCEED | REFUSE
    teardown.md  prior-art.md  constraints.md
  island-1/
    candidates/cand-*.yaml                      # Wave-1 + Wave-2 generator outputs
    gaps.yaml                                   # Wave-2 moderator output
    composites/comp-*.yaml                      # Wave-3 + post-loop-back synthesizer outputs
    shortlist.yaml                              # Wave-4 deterministic Pareto cut (report.py)
    falsify/<composite-id>-{steelman,premortem,redteam,physics}.yaml
  island-2/  ...                                # same shape, per K
  composites/global-*.yaml                      # Wave-6 cross-pollinated composites
  floor-survivors.yaml                          # Wave-7 deterministic floor cut (report.py)
  ranked.yaml                                   # Wave-7 arbiter output
  report.md                                     # dossier (spec §6) or the partial report
  f2i-aggregate.md                              # findings-to-issues envelope (uberthink-aggregate)
```

All paths reaching a dispatch prompt are **absolute** — the preflight resolves
`RUN_DIR` with `pwd -P` before emitting args (artifact-leak guard in worktrees).

## Preflight + Workflow mandate

Run the fence below — the FS-only work the Workflow script cannot do — then relay
the emitted JSON verbatim into the Workflow.

```bash
# report.py needs PyYAML; probe here for a fast, clear failure rather than a deep
# one mid-run (it runs inside the deterministic-cut relays).
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

REPO_ROOT_ABS="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT_ABS" ] || { echo "error: /uberthink must run inside a git repository" >&2; exit 2; }

# Parse flags; GOAL accumulates the non-flag tokens (the user's free-text goal).
ISLANDS=""; HANDOFF=0; NO_ISSUES=0; MAX_NEW=""; RESUME_ID=""; GOAL=""
for arg in $ARGUMENTS; do
  case "$arg" in
    --islands=*)   ISLANDS="${arg#--islands=}" ;;
    --islands)     : ;;                              # bare flag = keep the default
    --handoff)     HANDOFF=1 ;;
    --no-issues)   NO_ISSUES=1 ;;
    --max-new=*)   MAX_NEW="${arg#--max-new=}" ;;
    --resume=*)    RESUME_ID="${arg#--resume=}" ;;
    --*)           echo "warning: unknown flag $arg" >&2 ;;
    *)             GOAL="${GOAL:+$GOAL }$arg" ;;
  esac
done

# --resume rehydrates an existing run tree instead of minting a new one. Validate
# the id to a closed character class BEFORE it becomes a path component.
if [ -n "$RESUME_ID" ]; then
  case "$RESUME_ID" in
    ''|*[!0-9A-Za-z._-]*|*..*) echo "error: invalid --resume id '$RESUME_ID'" >&2; exit 2 ;;
  esac
  RUN_ID="$RESUME_ID"
  [ -d ".uberdev/think/$RUN_ID" ] || { echo "error: no run tree at .uberdev/think/$RUN_ID" >&2; exit 2; }
else
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
fi

# A resumed run reuses the recorded goal only when the caller did not restate it.
if [ -z "$GOAL" ] && [ -n "$RESUME_ID" ] && [ -r ".uberdev/think/$RUN_ID/goal.txt" ]; then
  GOAL="$(cat ".uberdev/think/$RUN_ID/goal.txt")"
fi
if [ -z "$GOAL" ]; then
  echo "error: /uberthink requires a goal text argument (got empty / flags-only)" >&2
  exit 2
fi

# Resolve config (env > config > default); an explicit flag wins.
ISLANDS_D=2; CONCURRENCY=12; MAX_FLOOD=120; MAX_NEW_D=3; SHORTLIST_TOP=7; LOOP_BACK_CAP=3
if [ -r "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/config-read.sh" ]; then
  . "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/config-read.sh"
  [ -n "$ISLANDS" ] || ISLANDS_D="$(uberdev_read_int_in_range uberthink.islands UBERDEV_UBERTHINK_ISLANDS 1 8 2)"
  [ -n "$MAX_NEW" ] || MAX_NEW_D="$(uberdev_read_int_in_range uberthink.max_new UBERDEV_UBERTHINK_MAX_NEW 1 50 3)"
  CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.uberthink UBERDEV_UBERTHINK_FANOUT 1 64 12)"
  MAX_FLOOD="$(uberdev_read_int_in_range uberthink.max_flood UBERDEV_UBERTHINK_MAX_FLOOD 1 100000 120)"
  SHORTLIST_TOP="$(uberdev_read_int_in_range uberthink.shortlist_top UBERDEV_UBERTHINK_SHORTLIST_TOP 1 50 7)"
  LOOP_BACK_CAP="$(uberdev_read_int_in_range uberthink.loop_back_cap UBERDEV_UBERTHINK_LOOP_BACK_CAP 0 10 3)"
fi
ISLANDS="${ISLANDS:-$ISLANDS_D}"; MAX_NEW="${MAX_NEW:-$MAX_NEW_D}"
case "$ISLANDS" in ''|*[!0-9]*) ISLANDS=2 ;; esac
case "$MAX_NEW" in ''|*[!0-9]*) MAX_NEW=3 ;; esac
[ "$ISLANDS" -lt 1 ] && ISLANDS=1
[ "$ISLANDS" -gt 8 ] && ISLANDS=8      # beyond ~8 the agent ceiling dominates
[ "$MAX_NEW" -lt 1 ] && MAX_NEW=1
[ "$MAX_NEW" -gt 50 ] && MAX_NEW=50

# CB-ISLAND ceiling scales with K — 200 dispatched agents per island (spec §4).
MAX_AGENTS=$(( 200 * ISLANDS ))

# Build the run tree eagerly so every dispatch prompt can point at a directory
# that already exists (wave agents write, they do not mkdir).
mkdir -p ".uberdev/think/$RUN_ID/frame" ".uberdev/think/$RUN_ID/composites"
K=1
while [ "$K" -le "$ISLANDS" ]; do
  mkdir -p ".uberdev/think/$RUN_ID/island-$K/candidates" \
           ".uberdev/think/$RUN_ID/island-$K/composites" \
           ".uberdev/think/$RUN_ID/island-$K/falsify"
  K=$(( K + 1 ))
done
RUN_DIR_ABS="$(cd ".uberdev/think/$RUN_ID" && pwd -P)"
[ -n "$RUN_DIR_ABS" ] || { echo "error: could not resolve an absolute RUN_DIR" >&2; exit 2; }
printf '%s\n' "$GOAL" > "$RUN_DIR_ABS/goal.txt"     # so --resume can rehydrate it

HANDOFF_BOOL=false; [ "$HANDOFF" = "1" ] && HANDOFF_BOOL=true
NO_ISSUES_BOOL=false; [ "$NO_ISSUES" = "1" ] && NO_ISSUES_BOOL=true
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# RFC 0012 §4.1: validate the on-disk Workflow script exists BEFORE mandating the
# call — a missing/misnamed workflow.js must refuse cleanly at preflight.
WORKFLOW_JS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/uberthink-pipeline/workflow.js"
[ -f "$WORKFLOW_JS" ] || { echo "error: $WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; exit 2; }

echo "[uberthink] run_id=$RUN_ID islands=$ISLANDS handoff=$HANDOFF max_new=$MAX_NEW max_agents=$MAX_AGENTS"
echo "[uberthink] RUN_DIR=$RUN_DIR_ABS"

uberdev_emit_workflow_args uberthink-pipeline \
  run_id="$RUN_ID" \
  runId="$RUN_ID" \
  runDirAbs="$RUN_DIR_ABS" \
  pluginRootAbs="$PLUGIN_ROOT" \
  repoRootAbs="$REPO_ROOT_ABS" \
  goal="$GOAL" \
  islands="$ISLANDS" \
  concurrency="$CONCURRENCY" \
  maxAgents="$MAX_AGENTS" \
  maxFlood="$MAX_FLOOD" \
  loopBackCap="$LOOP_BACK_CAP" \
  shortlistTop="$SHORTLIST_TOP" \
  maxNew="$MAX_NEW" \
  handoff="$HANDOFF_BOOL" \
  noIssues="$NO_ISSUES_BOOL" \
  resumeFromRunId="$RESUME_ID" \
  timestampIso="$NOW_ISO"
```

**Workflow mandate:** the preflight validated `[ -f "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/uberthink-pipeline/workflow.js" ]`. Relay the JSON between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2 — no LLM-composed handoffs) into:

```
Workflow({scriptPath: "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/uberthink-pipeline/workflow.js"}, <the JSON between the markers>)
```

**Post-Workflow summary:** when the Workflow returns, print its summary from the structured return value:

```
[uberthink] === DONE ===
  run_id:            <return.runId>
  islands:           <return.islands>
  agents_dispatched: <return.dispatched>/<return.maxAgents>
  loop_backs:        <sum of return.islandStats[].loopBacks>
  ranked:            <return.rankedCount>
  report:            <return.reportPath>
  issues:            <return.issues.issuesCreated> (<return.issues.skipped> skipped)
```

If `return.halts` is non-empty, print `halted: <return.halts joined>` and exit 1
(exit 2 when a halt starts with `SCOPE_MISSING` or `SCOPE_MALFORMED`). A halt
beginning `TOOLING:` means a deterministic cut FAILED — report it as a tooling
failure and never as a statement about the goal.

If `return.handoff.requested` is true and `return.handoff.seedPath` is non-empty,
invoke `Skill(uberdev:brainstorm)` seeded with that file as the final step.

## Circuit-breaker reference

The breakers are live JS state inside `workflow.js` and surface on
`return.halts`; the deliver phase renders the partial-vs-full dossier from the
same list.

| ID | Guard | Trip condition | Action |
|---|---|---|---|
| **CB-ISLAND** | Total fleet ceiling | `dispatched + projected > MAX_AGENTS` (default `200 × ISLANDS`) | `guard()` throws before the fanout; finalize with what completed |
| **CB-BUDGET** | Runtime lifetime cap | `budget.remaining() < projected` | `guard()` throws before the fanout |
| **CB-FLOOD** | Per-island candidate flood | island candidates > `MAX_FLOOD` (default 120) | Mark the island's input set as capped; the Pareto cut prunes |
| **CB-LOOP** | Per-island genetic loop-backs | island loop counter ≥ 3 | Stop evolving that island; survivors carry forward to cross-pollination |
| **CB-CONVERGE** | Non-convergence | every island's shortlist empty / nothing clears the floor, **and every deterministic cut exited 0** | Emit a partial dossier explaining the negative result |
| **TOOLING:** | Crashed relay | any `report.py` / FS relay returns null or `rc != 0` | Record the failure and **suppress CB-CONVERGE** — a crashed cut is not a verdict |
| **SCOPE_REFUSE** | Wave-0 safety lens | schema lens returns `verdict: REFUSE` | Halt before ANY fanout; write the refusal report |

`CB-WAVE` (>1800s per wave) and `CB-CLOCK` (>5400s total) are **retired**. They
were already dead in the directive-emitter era — the bash fence that "timed" a
wave returned in milliseconds, before the wave's `Task()` fanout had even
started — and the Workflow runtime forbids the wall-clock globals outright
(DR-7). The runtime `budget` cap plus the now-live CB-ISLAND / CB-FLOOD / CB-LOOP
cover the real failure modes.

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini/Copilot/pre-Workflow Claude
Code): run the preflight fence above (it mints `RUN_ID`/`RUN_DIR`, builds the run
tree and resolves the caps), then drive the waves by hand. Fire each wave's
`Task()` calls **IN A SINGLE assistant message**; read `personas.yaml` once and
inject each `prompt` verbatim (agents must not re-read it).

1. **Scope gate (alone, verdict-first).** ONE `Task(uberdev:uberthink-frame)` with
   `lens=schema`, `summary_dir=$RUN_DIR/frame`, `working_dir=$REPO_ROOT_ABS`, the
   goal wrapped in `<external-untrusted-input source="user-goal">`. Read
   `$RUN_DIR/frame/scope-verdict.yaml`. On `REFUSE`, write the refusal report and
   **stop before any other dispatch**. Never fan out siblings before this verdict.
2. **Diverge (one message).** `lens=teardown`, `lens=prior-art` and
   `lens=constraints` frame Tasks PLUS, per island `K` and per donor slug the
   schema lens selected, one `uberdev:uberthink-generator` Task
   (`persona_name=field_scout`, `donor_domain=<slug>`) plus the four fixed
   operators `triz`/`morphological`/`provocateur`/`bridge`. Each writes
   `island-K/candidates/cand-*.yaml`. Keep a running total of dispatched agents
   yourself and stop at `MAX_AGENTS` (CB-ISLAND).
3. **Gap-gate (one message).** One `uberdev:uberthink-moderator` per island →
   `island-K/gaps.yaml`; then one targeted generator Task per gap, in one message.
4. **Combine (one message).** Per island, three `uberdev:uberthink-synthesizer`
   Tasks (`weave`, `crossover`, `mutate`) → `island-K/composites/comp-*.yaml`.
5. **Converge (deterministic, no agents).** Per island:
   `python3 "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/uberthink-pipeline/report.py" --run-dir "$RUN_DIR" --emit shortlist --island K --top 7 --out "$RUN_DIR/island-K/shortlist.yaml"`.
   **Check the exit code.** `3` means an input artifact was missing/unreadable —
   that is a tooling failure; report it as such, skip the rank phase, and do NOT
   conclude non-convergence. Never discard this command's stderr or swallow its
   exit status: that is the exact idiom that turned a crash into a verdict.
6. **Falsify (one message).** Per island × per shortlist composite × the four
   lenses `steelman`/`premortem`/`redteam`/`physics`, one
   `uberdev:uberthink-falsifier` Task. Every dispatch MUST carry `frame_dir=$RUN_DIR/frame`
   plus `composite_path`, `summary_dir`, `island_index`, `working_dir` and the goal
   envelope — the `physics` lens reads `$RUN_DIR/frame/constraints.md` as its
   feasibility fence. Fixable kills (`fatal: false`) with a `repair_hint` re-enter
   step 4 as design constraints, capped at 3 loop-backs per island (CB-LOOP).
7. **Cross-pollinate.** With `--islands 1`, copy `island-1/composites/comp-*.yaml`
   to `$RUN_DIR/composites/global-*.yaml`. Otherwise ONE global
   `uberdev:uberthink-synthesizer` `crossover` Task over the union of island
   shortlists; every offspring must splice parents from ≥2 different islands.
8. **Rank.**
   `report.py --run-dir "$RUN_DIR" --emit floor-survivors --out "$RUN_DIR/floor-survivors.yaml"`
   (same exit-code discipline), then ONE `uberdev:uberthink-arbiter` Task which
   scores ONLY the listed ids and writes `$RUN_DIR/ranked.yaml`.
9. **Deliver.** `report.py --emit dossier > "$RUN_DIR/report.md"`; unless
   `--no-issues`, `report.py --emit aggregate --max-new N > "$RUN_DIR/f2i-aggregate.md"`
   then ONE `Task(uberdev:findings-to-issues)` with
   `variant=legacy.uberthink, aggregate_path=$RUN_DIR/f2i-aggregate.md,
   working_dir=$REPO_ROOT_ABS, pr_number=0, finding_label=uberthink-idea,
   finding_marker_slug=uberthink, max_new=$MAX_NEW`. With `--handoff`, finish by
   invoking `Skill(uberdev:brainstorm)` seeded with the `### 1.` dossier block.
