---
name: ubersimplify-pipeline
description: Use when /uberdev:ubersimplify is invoked. Whole-codebase 3-lens simplification — packs the repo into a fixed fleet of byte-balanced areas (default 8, shared lib/chunk.py), audits each area with ONE multi-lens code-simplifier (Reuse/Quality/Efficiency), applies preserve-behavior fixes via code-fixer as one refactor: commit per area on a shared branch, opens ONE PR, and files leftover blocker findings as GitHub issues. --audit-only is read-only. The orchestration runs in the shared scan-fleet Workflow (skills/scan-fleet/workflow.js, mode=simplify); this skill is the thin preflight + args seam.
model: inherit
---

# Ubersimplify Pipeline (thin seam over scan-fleet)

Owns the user-facing lifecycle of `/uberdev:ubersimplify` — the *writing* sibling
of read-only `/uberscan`. The orchestration (area packing, the per-area multi-lens
`code-simplifier` fanout, `aggregate.py` dedupe, the SEQUENTIAL `code-fixer`
apply, the single `gh pr create`, `findings-to-issues`) runs in the shared
**scan-fleet Workflow** (`skills/scan-fleet/workflow.js`, `mode=simplify`; RFC
0012 §3.7, Phase 3). This skill does only the filesystem-dependent preflight the
Workflow script cannot — flag/scope parse, `RUN_ID` mint, `RUN_DIR` mkdir, config
reads, the PyYAML probe — then emits the canonical args and mandates the call.
`--audit-only` collapses simplify to a read-only scan (no branch/fix/PR).

## Reuses

- `lib/chunk.py` — scope enumeration + balanced area-packing (`--areas N`; shared with /uberscan, NOT a uberscan-pipeline copy).
- `skills/ubersimplify-pipeline/aggregate.py` — lens-merge dedup (`fixer` mode → `post-impl-review-aggregate` envelope) + leftover-issues collection (`issues` mode → `ubersimplify-aggregate` envelope).
- `agents/code-simplifier.md` — the 3 lenses (Reuse / Quality / Efficiency), audit-only per area.
- `agents/code-fixer.md` — preserve-behavior apply as one `refactor:` commit per area (R8.6 single-commit invariant; phase2 = refactor: only).
- `agents/findings-to-issues.md` — durable GitHub issue persistence; it OWNS the gh rate-limit floor (CB6) — see `agents/findings-to-issues.md Step 2` (no pre-dispatch copy lives here).

## Schema C-LENS — per-area lens findings file (`chunk-NNN-lens.yaml`)

The per-area `code-simplifier` writes this; `aggregate.py fixer` dedups across
lenses by `file:line`. (Byte-stable contract.)

```yaml
schema_version: 1
chunk_id: <N>
files: [<path>, ...]
findings:
  - location: <path>:<line>
    severity: blocker | suggestion
    lens: Reuse | Quality | Efficiency
    summary: <1-line>
    detail: <prose>
```

## Preflight + Workflow mandate

```bash
# PyYAML is required by aggregate.py (probe here for a fast, clear failure).
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
RUN_DIR=".uberdev/simplify/$RUN_ID"
mkdir -p "$RUN_DIR"
RUN_DIR_ABS="$(cd "$RUN_DIR" && pwd)"
# code-fixer + findings-to-issues both REQUIRE an absolute working_dir inside the
# worktree (they refuse input-malformed otherwise). Resolve once; the Workflow
# agents re-resolve via git, but the preflight also guards a non-git invocation.
WORKING_DIR_ABS="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$WORKING_DIR_ABS" ] || { echo "error: /ubersimplify must run inside a git repository (git rev-parse failed)" >&2; exit 2; }

# AREA MODEL: the whole repo is simplified by a FIXED FLEET of <= NUM_AREAS agents
# (one multi-lens code-simplifier per byte-balanced area). Legacy --max-chunks=N
# aliases --areas=N.
SCOPE="."; AUDIT_ONLY=0; NO_ISSUES=0; NO_REPORT=0; AREAS_ARG=""; CONCURRENCY_ARG=""; LENS_SUBSET=""
for arg in $ARGUMENTS; do
  case "$arg" in
    --audit-only)     AUDIT_ONLY=1 ;;
    --no-issues)      NO_ISSUES=1 ;;
    --no-report)      NO_REPORT=1 ;;
    --all|--turbo)    : ;;  # legacy flags: the bounded fixed-fleet (<=24 areas) never nears MAX_AGENTS
    --lens=*)         LENS_SUBSET="${arg#--lens=}" ;;
    --areas=*)        AREAS_ARG="${arg#--areas=}" ;;
    --max-chunks=*)   AREAS_ARG="${arg#--max-chunks=}" ;;  # legacy alias → areas
    --concurrency=*)  CONCURRENCY_ARG="${arg#--concurrency=}" ;;
    --*)              echo "warning: unknown flag $arg" >&2 ;;
    *)                SCOPE="$arg" ;;
  esac
done

# Resolve config (env > config > default). An explicit --areas/--concurrency wins.
NUM_AREAS="${AREAS_ARG:-8}"; CONCURRENCY="${CONCURRENCY_ARG:-3}"; MAX_AGENTS=250; MAX_NEW=10
if [ -r "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/config-read.sh" ]; then
  . "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/config-read.sh"
  [ -n "$AREAS_ARG" ]       || NUM_AREAS="$(uberdev_read_int_in_range ubersimplify.areas UBERDEV_UBERSIMPLIFY_AREAS 1 24 8)"
  [ -n "$CONCURRENCY_ARG" ] || CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.ubersimplify UBERDEV_UBERSIMPLIFY_FANOUT 1 16 3)"
  MAX_AGENTS="$(uberdev_read_int_in_range ubersimplify.max_agents UBERDEV_UBERSIMPLIFY_MAX_AGENTS 1 2000 250)"
  MAX_NEW="$(uberdev_read_int_in_range ubersimplify.max_new UBERDEV_UBERSIMPLIFY_MAX_NEW 1 200 10)"
fi
LENSES="${LENS_SUBSET:-Reuse,Quality,Efficiency}"
BRANCH_NAME="ubersimplify/$RUN_ID"
AUDIT_ONLY_BOOL=false; [ "$AUDIT_ONLY" = "1" ] && AUDIT_ONLY_BOOL=true
NO_ISSUES_BOOL=false; [ "$NO_ISSUES" = "1" ] && NO_ISSUES_BOOL=true
NO_REPORT_BOOL=false; [ "$NO_REPORT" = "1" ] && NO_REPORT_BOOL=true
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# RFC 0012 §4.1: validate the on-disk Workflow script exists BEFORE mandating the call.
WORKFLOW_JS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/scan-fleet/workflow.js"
[ -f "$WORKFLOW_JS" ] || { echo "error: $WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use the No-Workflow fallback" >&2; exit 2; }

uberdev_emit_workflow_args scan-fleet \
  mode=simplify \
  run_id="$RUN_ID" \
  runId="$RUN_ID" \
  runDirAbs="$RUN_DIR_ABS" \
  pluginRootAbs="$PLUGIN_ROOT" \
  repoRootAbs="$WORKING_DIR_ABS" \
  scope="$SCOPE" \
  manifestPathAbs="$RUN_DIR_ABS/manifest.json" \
  numAreas="$NUM_AREAS" \
  concurrency="$CONCURRENCY" \
  maxAgents="$MAX_AGENTS" \
  maxNew="$MAX_NEW" \
  lenses="$LENSES" \
  branchName="$BRANCH_NAME" \
  auditOnly="$AUDIT_ONLY_BOOL" \
  noIssues="$NO_ISSUES_BOOL" \
  noReport="$NO_REPORT_BOOL" \
  timestampIso="$NOW_ISO"
```

**Workflow mandate:** the preflight validated `[ -f "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/scan-fleet/workflow.js" ]`. Relay the JSON between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2) into:

```
Workflow({scriptPath: "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/scan-fleet/workflow.js"}, <the JSON between the markers>)
```

**Post-Workflow summary:** when the Workflow returns, print from the structured return value:

```
[ubersimplify] === DONE ===
  run_id:           <return.runId>
  scope:            <return.scope>
  areas:            <return.areasReturned>/<return.areaCount>
  refactor commits: <return.appliedAreas> area(s) applied (<return.refusedAreas> refused)
  branch:           <return.branch>
  PR:               #<return.prNumber>
  issues:           <return.issues.issuesCreated> (<return.issues.skipped> skipped)
```

Under `--audit-only` the branch/PR lines are empty. If `return.prNumber` is set, print `next: run /review-pr on PR #<n> (mandatory; NOT auto-chained)`.

## No-Workflow fallback

On a runtime without the `Workflow` tool (Gemini/Copilot/pre-Workflow Claude
Code): do the preflight fence above, then run the directive recipe by hand:

1. **Pack** — `python3 "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/chunk.py" --scope "$SCOPE" --areas "$NUM_AREAS" --run-id "$RUN_ID" > "$RUN_DIR/manifest.json"` (chunk.py writes the manifest JSON to stdout — there is no `--out` flag).
2. **Areas** — for each `manifest.chunks[].id`, dispatch ONE `Task(subagent_type: uberdev:code-simplifier)` (waves of `CONCURRENCY`, IN ONE MESSAGE) running ALL lenses in `$LENSES` over the area; each writes `$RUN_DIR/chunk-NNN-lens.yaml` (Schema C-LENS).
3. **Aggregate** — per area, `python3 "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/ubersimplify-pipeline/aggregate.py" fixer --lens-file "$RUN_DIR/chunk-NNN-lens.yaml" --out "$RUN_DIR/chunk-NNN-fixer.md"`.
4. **Apply** (skip iff `--audit-only`) — `git checkout -b ubersimplify/$RUN_ID`, then dispatch `Task(subagent_type: uberdev:code-fixer)` ONE AT A TIME (never parallel — concurrent commits race the git index), phase2, one `refactor:` commit per area; write each disposition to `$RUN_DIR/chunk-NNN-fixer-disposition.yaml`.
5. **PR** (skip iff `--audit-only` or 0 commits) — write the PR body to a FILE (never inline — 2nd-order injection guard; NO Claude/co-author trailer), `git push -u origin "$BRANCH_NAME"`, then `gh pr create --body-file …`.
6. **File leftovers** (unless `--no-issues`) — `python3 "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/ubersimplify-pipeline/aggregate.py" issues --chunks-dir "$RUN_DIR" --out "$RUN_DIR/f2i-aggregate.md"` (add `--audit-only` when set), then `Task(subagent_type: uberdev:findings-to-issues)` over it (envelope `source=ubersimplify-aggregate`), `finding_label=ubersimplify-finding`, `finding_marker_slug=ubersimplify`, `max_new=$MAX_NEW`, `pr_number=$PR_NUMBER`. The agent owns the CB6 gh rate-limit floor + MAX_NEW/dedupe/halt.
