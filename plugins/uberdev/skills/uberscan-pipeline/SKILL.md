---
name: uberscan-pipeline
description: Use when /uberdev:uberscan is invoked. Read-only whole-codebase audit — packs the repo into a fixed fleet of byte-balanced areas (default 8), runs ONE multi-lens reviewer per area, runs an inline repo-global Semgrep SAST + test-coverage pass, aggregates findings into a markdown report, and files deduped GitHub issues. Never writes source code. The orchestration runs in the shared scan-fleet Workflow (skills/scan-fleet/workflow.js, mode=scan); this skill is the thin preflight + args seam.
model: inherit
---

# Uberscan Pipeline (thin seam over scan-fleet)

Owns the user-facing lifecycle of `/uberdev:uberscan`. Read-only — no agent
writes source files. The orchestration (area packing, the per-area multi-lens
`code-reviewer` fanout, the inline Semgrep+coverage pass, `report.py`
aggregation, `findings-to-issues`) runs in the shared **scan-fleet Workflow**
(`skills/scan-fleet/workflow.js`, `mode=scan`; RFC 0012 §3.7, Phase 3). This
skill does only the filesystem-dependent preflight the Workflow script cannot —
flag/scope parse, `RUN_ID` mint, `RUN_DIR` mkdir, config reads, the PyYAML probe
— then emits the canonical args between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END`
and mandates the call.

## Reuses

- `lib/chunk.py` — scope enumeration + balanced area-packing (`--areas N`; shared with /ubersimplify).
- `skills/uberscan-pipeline/report.py` — dedup, markdown report, totals.json, findings-to-issues aggregate.
- `skills/scan-fleet/global-pass.sh` — the inline repo-global Semgrep SAST + test-coverage pass.
- `agents/code-reviewer.md` — the per-area multi-lens reviewer (correctness, silent-failures, type-design, comment-accuracy, test-coverage, general). Read-only; /uberscan never applies edits (that writing lens belongs to /ubersimplify).
- `agents/findings-to-issues.md` — durable GitHub issue persistence with fingerprint dedupe; it OWNS the gh rate-limit floor (CB6) — see `agents/findings-to-issues.md Step 2` (the canonical owner; no pre-dispatch copy lives here).

## Schema C2 — per-area findings file (`chunk-NNN-findings.yaml`)

The per-area `code-reviewer` writes this directly; `report.py` globs
`chunk-*-findings.yaml`. (Byte-stable contract — the area agent and report.py
both depend on it.)

```yaml
schema_version: 1
chunk_id: <N>
files: [<path>, ...]
findings:
  - severity: blocker | critical | major | important | suggestion
    location: <path>:<line>
    agent: code-reviewer
    summary: <1-line>
    detail: <prose>
    confidence: low | medium | high
```

## Preflight + Workflow mandate

Run the fence below — the FS-only work the Workflow script cannot do — then relay
the emitted JSON verbatim into the Workflow.

```bash
# PyYAML is required by report.py (it runs inside the aggregate agent; probe here
# for a fast, clear failure rather than a deep one mid-run).
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
RUN_DIR=".uberdev/scan/$RUN_ID"
mkdir -p "$RUN_DIR"
RUN_DIR_ABS="$(cd "$RUN_DIR" && pwd)"
REPO_ROOT_ABS="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT_ABS" ] || { echo "error: /uberscan must run inside a git repository" >&2; exit 2; }

# AREA MODEL: the whole repo is reviewed by a FIXED FLEET of <= NUM_AREAS agents
# (one multi-lens reviewer per byte-balanced area), so agent count is bounded
# independent of repo size. Legacy --max-chunks=N aliases --areas=N.
SCOPE="."; NO_ISSUES=0; NO_REPORT=0; AREAS_ARG=""; CONCURRENCY_ARG=""; SEVERITY="major"
for arg in $ARGUMENTS; do
  case "$arg" in
    --no-issues)      NO_ISSUES=1 ;;
    --no-report)      NO_REPORT=1 ;;
    --all|--turbo)    : ;;  # legacy flags: the bounded fixed-fleet (<=24 areas) never nears MAX_AGENTS
    --areas=*)        AREAS_ARG="${arg#--areas=}" ;;
    --max-chunks=*)   AREAS_ARG="${arg#--max-chunks=}" ;;  # legacy alias → areas
    --concurrency=*)  CONCURRENCY_ARG="${arg#--concurrency=}" ;;
    --severity=*)     SEVERITY="${arg#--severity=}" ;;
    --*)              echo "warning: unknown flag $arg" >&2 ;;
    *)                SCOPE="$arg" ;;
  esac
done

# Resolve config (env > config > default). An explicit --areas/--concurrency wins.
NUM_AREAS="${AREAS_ARG:-8}"; CONCURRENCY="${CONCURRENCY_ARG:-3}"; MAX_AGENTS=250; MAX_NEW=15
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  [ -n "$AREAS_ARG" ]       || NUM_AREAS="$(uberdev_read_int_in_range uberscan.areas UBERDEV_UBERSCAN_AREAS 1 24 8)"
  [ -n "$CONCURRENCY_ARG" ] || CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.uberscan UBERDEV_UBERSCAN_FANOUT 1 16 3)"
  MAX_AGENTS="$(uberdev_read_int_in_range uberscan.max_agents UBERDEV_UBERSCAN_MAX_AGENTS 1 2000 250)"
  MAX_NEW="$(uberdev_read_int_in_range uberscan.max_new UBERDEV_UBERSCAN_MAX_NEW 1 200 15)"
fi
NO_ISSUES_BOOL=false; [ "$NO_ISSUES" = "1" ] && NO_ISSUES_BOOL=true
NO_REPORT_BOOL=false; [ "$NO_REPORT" = "1" ] && NO_REPORT_BOOL=true
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# RFC 0012 §4.1: validate the on-disk Workflow script exists BEFORE mandating the
# call — a missing/misnamed workflow.js must refuse cleanly at preflight.
WORKFLOW_JS="$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js"
[ -f "$WORKFLOW_JS" ] || { echo "error: $WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; exit 2; }

uberdev_emit_workflow_args scan-fleet \
  mode=scan \
  run_id="$RUN_ID" \
  runId="$RUN_ID" \
  runDirAbs="$RUN_DIR_ABS" \
  pluginRootAbs="$CLAUDE_PLUGIN_ROOT" \
  repoRootAbs="$REPO_ROOT_ABS" \
  scope="$SCOPE" \
  manifestPathAbs="$RUN_DIR_ABS/manifest.json" \
  numAreas="$NUM_AREAS" \
  concurrency="$CONCURRENCY" \
  maxAgents="$MAX_AGENTS" \
  maxNew="$MAX_NEW" \
  minSeverity="$SEVERITY" \
  noIssues="$NO_ISSUES_BOOL" \
  noReport="$NO_REPORT_BOOL" \
  timestampIso="$NOW_ISO"
```

**Workflow mandate:** the preflight validated `[ -f "$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js" ]`. Relay the JSON between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2 — no LLM-composed handoffs) into:

```
Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js"}, <the JSON between the markers>)
```

**Post-Workflow summary:** when the Workflow returns, print its summary from the structured return value:

```
[uberscan] === DONE ===
  run_id:        <return.runId>
  scope:         <return.scope>
  areas:         <return.areasReturned>/<return.areaCount>
  total findings:<return.totalFindings>
  report:        <return.reportPath>
  issues:        <return.issues.issuesCreated> (<return.issues.skipped> skipped)
```

If `return.cb5Tripped` is true, also print `partial: yes (findings-flood CB5 — results INCOMPLETE)` and exit 1.

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini/Copilot/pre-Workflow Claude
Code): do the preflight fence above (it mints `RUN_ID`/`RUN_DIR` and resolves
`NUM_AREAS`/`CONCURRENCY`/`SEVERITY`), then run the directive recipe by hand
instead of the Workflow call:

1. **Pack** — `python3 "$CLAUDE_PLUGIN_ROOT/lib/chunk.py" --scope "$SCOPE" --areas "$NUM_AREAS" --run-id "$RUN_ID" > "$RUN_DIR/manifest.json"` (chunk.py writes the manifest JSON to stdout — there is no `--out` flag).
2. **Areas** — for each `manifest.chunks[].id`, dispatch ONE `Task(subagent_type: uberdev:code-reviewer)` (in waves of `CONCURRENCY`, IN ONE MESSAGE per wave) briefed with the Schema C2 above and minimum severity `$SEVERITY`; each writes `$RUN_DIR/chunk-NNN-findings.yaml`.
3. **Global pass** — `bash "$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/global-pass.sh" "$SCOPE" "$RUN_DIR"` (inline Semgrep SAST + test-coverage; 0 dispatched agents).
4. **Aggregate** — `python3 "$CLAUDE_PLUGIN_ROOT/skills/uberscan-pipeline/report.py" --run-id "$RUN_ID" --chunks-dir "$RUN_DIR" --out "$RUN_DIR/uberscan-report.md" --emit-totals-json "$RUN_DIR/totals.json" --min-severity "$SEVERITY" --emit-findings-to-issues-aggregate "$RUN_DIR/f2i-aggregate.md"` (drop `--out` under `--no-report`; drop the `--emit-findings-to-issues-aggregate` + `--min-severity` under `--no-issues`).
5. **File issues** (unless `--no-issues`) — `Task(subagent_type: uberdev:findings-to-issues)` over `$RUN_DIR/f2i-aggregate.md` (envelope `source=uberscan-aggregate`), `finding_label=uberscan-finding`, `finding_marker_slug=uberscan`, `max_new=$MAX_NEW`. The agent owns the CB6 gh rate-limit floor and the MAX_NEW/dedupe/halt logic.
