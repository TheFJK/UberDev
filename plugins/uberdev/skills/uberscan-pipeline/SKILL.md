---
name: uberscan-pipeline
description: Use when /uberdev:uberscan is invoked. Orchestrates a read-only whole-codebase audit by chunking the repo, running the review-pr Phase-1 reviewer fleet (6 agents) per chunk in concurrent waves, executing a repo-global Semgrep SAST + test-coverage pass, aggregating findings into a markdown report, and filing deduped GitHub issues. Never writes code.
model: opus
---

# Uberscan Pipeline

Owns the lifecycle of `/uberdev:uberscan`. Read-only audit — no agent writes source files. The skill emits DISPATCH directives; the orchestrating session fires all `Task()` calls in ONE message per wave.

## Phases

- **Phase 0 — Parse + scope + chunk**
- **Phase 1 — Per-chunk fan-out waves (6 reviewers per chunk)**
- **Phase 1b — Repo-global pass (Semgrep SAST + test-coverage)**
- **Phase 2 — Aggregate + report**
- **Phase 3 — File issues (skip iff --no-issues)**
- **Phase 4 — Summary + exit**

## Schemas

### Schema C2 — per-chunk findings file

Written to `$RUN_DIR/chunk-NN-findings.yaml` after each chunk's reviewer wave completes.

```yaml
schema_version: 1
chunk_id: <N>
files: [<path>, ...]
findings:
  - severity: blocker | critical | major | important | suggestion
    location: <path>:<line>
    agent: <agent-name>
    summary: <1-line>
    detail: <prose>
    confidence: low | medium | high
```

`type-design-analyzer` and `comment-analyzer` return free-form prose — the orchestrating session MUST normalize their output into C2 rows (one row per identified issue; `detail` holds the prose excerpt; `severity` inferred from section headings or explicit tier markers; `confidence: medium` when no explicit confidence stated). Mirror the `pr-test-analyzer` legacy-Markdown fallback logic in `post-impl-review/SKILL.md` Step 4.

## Reuses

- `lib/config-read.sh` — `uberdev_read_int_in_range` for MAX_CHUNKS and CONCURRENCY
- `skills/uberscan-pipeline/chunk.py` — scope enumeration and budget-bounded chunking
- `skills/uberscan-pipeline/report.py` — deduplication, markdown report, findings-to-issues aggregate
- `agents/findings-to-issues.md` — durable GitHub issue persistence with fingerprint dedupe

## Sub-skill imports

None. This skill is fully self-contained.


## Phase 0 — Parse + scope + chunk

```bash
# Phase 0 precheck — PyYAML is required by report.py.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
RUN_DIR=".uberdev/scan/$RUN_ID"
mkdir -p "$RUN_DIR"

# Parse flags from $ARGUMENTS
SCOPE="."; ALL=0; NO_ISSUES=0; NO_REPORT=0; MAX_CHUNKS_ARG=""; CONCURRENCY_ARG=""; SEVERITY="major"; TURBO=0
for arg in $ARGUMENTS; do
  case "$arg" in
    --all)            ALL=1 ;;
    --no-issues)      NO_ISSUES=1 ;;
    --no-report)      NO_REPORT=1 ;;
    --turbo)          TURBO=1 ;;
    --max-chunks=*)   MAX_CHUNKS_ARG="${arg#--max-chunks=}" ;;
    --concurrency=*)  CONCURRENCY_ARG="${arg#--concurrency=}" ;;
    --severity=*)     SEVERITY="${arg#--severity=}" ;;
    --*)              echo "warning: unknown flag $arg" >&2 ;;
    *)                SCOPE="$arg" ;;
  esac
done

# Resolve MAX_CHUNKS and CONCURRENCY via config-read.sh (precedence: env > config > default).
# Range: MAX_CHUNKS [1,200] default 25; CONCURRENCY [1,16] default 3.
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  if [ -n "$MAX_CHUNKS_ARG" ]; then
    MAX_CHUNKS="$MAX_CHUNKS_ARG"
  else
    MAX_CHUNKS="$(uberdev_read_int_in_range uberscan.max_chunks UBERDEV_UBERSCAN_MAX_CHUNKS 1 200 25)"
  fi
  if [ -n "$CONCURRENCY_ARG" ]; then
    CONCURRENCY="$CONCURRENCY_ARG"
  else
    CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.uberscan UBERDEV_UBERSCAN_FANOUT 1 16 3)"
  fi
  CHUNK_BUDGET="$(uberdev_read_int_in_range uberscan.chunk_budget_bytes UBERDEV_UBERSCAN_CHUNK_BUDGET 4096 1048576 49152)"
else
  MAX_CHUNKS="${MAX_CHUNKS_ARG:-25}"
  CONCURRENCY="${CONCURRENCY_ARG:-3}"
  CHUNK_BUDGET=49152
fi

# Chunk the scope
python3 "${CLAUDE_PLUGIN_ROOT}/skills/uberscan-pipeline/chunk.py" \
  --scope "$SCOPE" \
  --budget-bytes "$CHUNK_BUDGET" \
  --max-chunks "$MAX_CHUNKS" \
  --run-id "$RUN_ID" \
  > "$RUN_DIR/manifest.json" || { echo "error: chunk.py failed (rc=$?); aborting" >&2; exit 2; }

# Fail loud on a corrupt manifest — it must NOT silently proceed to a
# false-clean "0 chunks" run (which would skip every breaker and find nothing).
if ! jq -e '.' "$RUN_DIR/manifest.json" >/dev/null 2>&1; then
  echo "error: manifest.json is not valid JSON; aborting" >&2; exit 2
fi

# CB1/CB7 circuit breaker: overflow guard
OVERFLOW="$(jq -r '.overflow' "$RUN_DIR/manifest.json")"
if [ "$OVERFLOW" = "true" ] && [ "$ALL" != "1" ]; then
  TOTAL_CHUNKS="$(jq -r '.total_chunks' "$RUN_DIR/manifest.json")"
  if [ "$TURBO" = "1" ]; then
    # Cap-and-continue: manifest is already capped at MAX_CHUNKS; record overflow
    echo "[uberscan] overflow: repo has $TOTAL_CHUNKS chunks; capped at MAX_CHUNKS=$MAX_CHUNKS (--turbo cap-and-continue)" >&2
    echo "OVERFLOW=true" >> "$RUN_DIR/run-state.txt"
  else
    echo "error: repo chunked into $TOTAL_CHUNKS chunks which exceeds MAX_CHUNKS=$MAX_CHUNKS." >&2
    echo "  Narrow with a path arg (e.g. /uberscan src/), or pass --all to override the cap," >&2
    echo "  or set a higher cap with --max-chunks=N or uberscan.max_chunks in .uberdev/config.yaml." >&2
    exit 1
  fi
fi

EMITTED_CHUNKS="$(jq '.chunks | length' "$RUN_DIR/manifest.json")"

# CB7 projected-agent ceiling: EMITTED_CHUNKS × 6 reviewers + 2 repo-global agents.
# Independent backstop on top of CB1's chunk-count cap (a low MAX_CHUNKS with a
# high per-chunk fleet could still blow the agent budget).
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  MAX_AGENTS="$(uberdev_read_int_in_range uberscan.max_agents UBERDEV_UBERSCAN_MAX_AGENTS 1 2000 250)"
else
  MAX_AGENTS=250
fi
PROJECTED_AGENTS=$(( EMITTED_CHUNKS * 6 + 2 ))
if [ "$PROJECTED_AGENTS" -gt "$MAX_AGENTS" ] && [ "$ALL" != "1" ]; then
  if [ "$TURBO" = "1" ]; then
    echo "[uberscan] CB7: projected $PROJECTED_AGENTS agents exceeds MAX_AGENTS=$MAX_AGENTS (--turbo cap-and-continue)" >&2
    echo "OVERFLOW=true" >> "$RUN_DIR/run-state.txt"
  else
    echo "error: projected agent count ($PROJECTED_AGENTS = ${EMITTED_CHUNKS}×6 + 2) exceeds MAX_AGENTS=$MAX_AGENTS." >&2
    echo "  Narrow with a path arg, pass --all to override, or raise uberscan.max_agents." >&2
    exit 1
  fi
fi

echo "[uberscan] run_id=$RUN_ID scope=$SCOPE chunks=$EMITTED_CHUNKS concurrency=$CONCURRENCY projected_agents=$PROJECTED_AGENTS"
```


## Phase 1 — Per-chunk fan-out waves

Each chunk receives a **file-set audit brief**: the agents are auditing EXISTING files as they stand in the repo (not a diff). The orchestrating session reads each DISPATCH directive and fires the 6 `Task()` calls IN ONE MESSAGE.

```bash
# Read chunk list from manifest
CHUNK_IDS="$(jq -r '.chunks[].id' "$RUN_DIR/manifest.json")"
TOTAL_EMITTED="$(jq '.chunks | length' "$RUN_DIR/manifest.json")"

# CB4 overall wall-clock budget (60 minutes). The circuit breakers below are
# enforced by the ORCHESTRATING session between waves: this bash loop only emits
# dispatch directives, so it returns in milliseconds — the real wall-clock is
# spent firing the Task() calls. The orchestrator updates the state the breakers
# read (PREV_WAVE_ELAPSED, CUMULATIVE_BLOCKERS_CRITICALS) after each wave returns.
WALL_START="$(date +%s)"
WALL_BUDGET_SECONDS=3600
CIRCUIT_BREAKER_HALT=0
PREV_WAVE_ELAPSED=0

# CB5 findings-flood guard
CUMULATIVE_BLOCKERS_CRITICALS=0
FINDINGS_FLOOD=0

# Process chunks in waves of CONCURRENCY
WAVE_NUM=0
CHUNK_ARRAY=($CHUNK_IDS)
TOTAL_CHUNKS_PROCESSED=0

_uberscan_elapsed() { echo $(( $(date +%s) - WALL_START )); }

IDX=0
while [ "$IDX" -lt "${#CHUNK_ARRAY[@]}" ]; do
  WAVE_NUM=$(( WAVE_NUM + 1 ))

  # Breakers are checked at the TOP of each wave against state the orchestrator
  # maintains across waves (see the post-wave step after this loop). Tripping any
  # breaker sets CIRCUIT_BREAKER_HALT=1 so Phase 4 exits 1.

  # CB3 per-wave timeout (15 min): the PREVIOUS wave's measured duration.
  if [ "${PREV_WAVE_ELAPSED:-0}" -gt 900 ]; then
    echo "[uberscan] CB3: previous wave exceeded 900s; halting before wave $WAVE_NUM" >&2
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB4 overall wall-clock budget check.
  if [ "$(_uberscan_elapsed)" -gt "$WALL_BUDGET_SECONDS" ]; then
    echo "[uberscan] CB4: overall budget of ${WALL_BUDGET_SECONDS}s exceeded after wave $(( WAVE_NUM - 1 )); halting" >&2
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB5 findings-flood guard.
  if [ "$CUMULATIVE_BLOCKERS_CRITICALS" -gt 150 ]; then
    echo "[uberscan] CB5: cumulative blocker+critical findings ($CUMULATIVE_BLOCKERS_CRITICALS) exceeded 150; marking report partial and halting" >&2
    echo "PARTIAL=true" >> "$RUN_DIR/run-state.txt"
    FINDINGS_FLOOD=1; CIRCUIT_BREAKER_HALT=1; break
  fi

  WAVE_START="$(date +%s)"

  # Build the wave's chunk slice
  WAVE_END_IDX=$(( IDX + CONCURRENCY ))
  if [ "$WAVE_END_IDX" -gt "${#CHUNK_ARRAY[@]}" ]; then
    WAVE_END_IDX="${#CHUNK_ARRAY[@]}"
  fi

  echo "[uberscan] wave $WAVE_NUM: chunks ${CHUNK_ARRAY[$IDX]} to ${CHUNK_ARRAY[$(( WAVE_END_IDX - 1 ))]}"

  # Emit DISPATCH directives for each chunk in this wave.
  # The orchestrating session reads these and fires all Task() calls IN ONE MESSAGE.
  for (( CI=IDX; CI<WAVE_END_IDX; CI++ )); do
    CHUNK_ID="${CHUNK_ARRAY[$CI]}"
    CHUNK_NUM="$(printf '%03d' "$CHUNK_ID")"
    CHUNK_FILES_JSON="$(jq --argjson id "$CHUNK_ID" '.chunks[] | select(.id==$id) | .files' "$RUN_DIR/manifest.json")"
    CHUNK_FILES="$(printf '%s' "$CHUNK_FILES_JSON" | jq -r '.[]')"
    CHUNK_OUT="$RUN_DIR/chunk-${CHUNK_NUM}-findings.yaml"

    # Write the dispatch directive for this chunk
    cat > "$RUN_DIR/dispatch-chunk-${CHUNK_NUM}.yaml" <<EOF
schema_version: 1
run_id: $RUN_ID
chunk_id: $CHUNK_ID
chunk_out: $CHUNK_OUT
output_schema: C2
files: $CHUNK_FILES_JSON
agents_to_dispatch:
  - agent: code-reviewer
    lens: correctness
  - agent: code-reviewer
    lens: general-catch-all
  - agent: silent-failure-hunter
  - agent: type-design-analyzer
  - agent: comment-analyzer
  - agent: pr-test-analyzer
notes:
  - "Agents are auditing EXISTING files as-they-stand (NOT a diff)."
  - "type-design-analyzer and comment-analyzer return free-form prose — orchestrator MUST normalize into C2 rows."
  - "Per-agent failure: drop and continue with N-1 agents."
EOF

    # ===========================================================================
    # DISPATCH POINT — the orchestrating session reads dispatch-chunk-NNN.yaml
    # above and fires 6 Task() calls IN A SINGLE assistant message. Each Task
    # receives the file-set audit brief below.
    #
    # FILE-SET AUDIT BRIEF (embed in each Task's prompt verbatim):
    #
    #   You are auditing EXISTING source files as they stand in the repository —
    #   this is NOT a diff review. Your job is to find bugs, design flaws,
    #   unsafe patterns, and quality issues in the code as written today.
    #
    #   Files in this chunk:
    #     <contents of CHUNK_FILES — one path per line>
    #
    #   Read each file in full. Return findings in the C2 YAML schema:
    #
    #   schema_version: 1
    #   chunk_id: <CHUNK_ID>
    #   files: [<list of file paths you examined>]
    #   findings:
    #     - severity: blocker | critical | major | important | suggestion
    #       location: <path>:<line>
    #       agent: <your-agent-name>
    #       summary: <1-line>
    #       detail: <prose>
    #       confidence: low | medium | high
    #
    #   Minimum severity to report: $SEVERITY
    #
    # NORMALIZATION NOTE for type-design-analyzer and comment-analyzer:
    #   These agents return free-form prose. The orchestrator normalizes their
    #   output into C2 rows (one row per identified issue; detail = prose excerpt;
    #   severity inferred from section headings or explicit tier markers;
    #   confidence: medium when not stated). Mirror the pr-test-analyzer
    #   legacy-Markdown fallback in post-impl-review/SKILL.md Step 4.
    #
    # Per-agent failure: if a Task returns BLOCKED or unparseable output,
    # log a warning and continue with N-1 agents for this chunk.
    # Write the merged C2 YAML to: $CHUNK_OUT
    # ===========================================================================

    TOTAL_CHUNKS_PROCESSED=$(( TOTAL_CHUNKS_PROCESSED + 1 ))

    # After the wave completes, the orchestrator updates CUMULATIVE_BLOCKERS_CRITICALS
    # by reading chunk-NNN-findings.yaml:
    #   chunk_bc=$(python3 -c "
    #     import yaml, sys
    #     doc = yaml.safe_load(open('$CHUNK_OUT')) or {}
    #     print(sum(1 for f in (doc.get('findings') or []) if f.get('severity') in {'blocker','critical'}))
    #   " 2>/dev/null || echo 0)
    #   CUMULATIVE_BLOCKERS_CRITICALS=$(( CUMULATIVE_BLOCKERS_CRITICALS + chunk_bc ))
  done

  IDX="$WAVE_END_IDX"
  echo "[uberscan] wave $WAVE_NUM complete ($TOTAL_CHUNKS_PROCESSED/$TOTAL_EMITTED chunks processed)"
done
```

After each wave completes (all chunk Tasks have returned), the orchestrating session:
1. Writes each chunk's normalized findings to `$RUN_DIR/chunk-NNN-findings.yaml` (C2 schema).
2. Updates `CUMULATIVE_BLOCKERS_CRITICALS` from the new chunk files.
3. Records the wave's actual elapsed seconds into `PREV_WAVE_ELAPSED` (from when this wave's Task() calls were fired to when they returned) — this is what CB3 reads on the next iteration.
4. Re-evaluates CB3 (per-wave timeout), CB4 (wall-clock budget), and CB5 (findings flood); if any trips, sets `CIRCUIT_BREAKER_HALT=1` and stops dispatching further waves.


## Phase 1b — Repo-global pass

Fired once, in parallel with the first chunk wave (emit in the same ONE message as wave 1).

```bash
# ===========================================================================
# DISPATCH POINT — emit alongside wave 1 Task() calls in ONE assistant message.
#
# research-security Task:
#   Run Semgrep SAST over $SCOPE using the semgrep MCP tool.
#   Write findings summary to: $RUN_DIR/global-security.md
#   Include: rule_id, severity, file, line, message for each finding.
#
# research-test-coverage Task:
#   Analyze test coverage signals over $SCOPE:
#     - Count test files vs source files
#     - Identify untested modules (source file with no matching test file)
#     - Flag files >200 lines with zero test coverage
#   Write findings summary to: $RUN_DIR/global-coverage.md
# ===========================================================================

cat > "$RUN_DIR/dispatch-global.yaml" <<EOF
schema_version: 1
run_id: $RUN_ID
scope: $SCOPE
agents_to_dispatch:
  - agent: research-security
    tool: semgrep_scan
    out: $RUN_DIR/global-security.md
  - agent: research-test-coverage
    out: $RUN_DIR/global-coverage.md
notes:
  - "Fire both Tasks IN THE SAME message as wave-1 chunk Tasks."
EOF

echo "[uberscan] dispatched global pass (security + coverage) alongside wave 1"
```


## Phase 2 — Aggregate + report

```bash
# Aggregate all chunk findings into the deduped report
if [ "$NO_REPORT" != "1" ]; then
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/uberscan-pipeline/report.py" \
    --run-id "$RUN_ID" \
    --chunks-dir "$RUN_DIR" \
    --out "$RUN_DIR/uberscan-report.md" || { echo "error: report.py (--out) failed (rc=$?); aborting" >&2; exit 2; }
  echo "[uberscan] report written: $RUN_DIR/uberscan-report.md"
else
  echo "[uberscan] --no-report: skipping report file (the issue aggregate is still emitted below)"
fi

# Always emit the findings-to-issues aggregate (used by Phase 3).
# --min-severity "$SEVERITY" enforces the documented issue-filing floor: only
# findings ranked at or above $SEVERITY (default major) reach the aggregate.
python3 "${CLAUDE_PLUGIN_ROOT}/skills/uberscan-pipeline/report.py" \
  --run-id "$RUN_ID" \
  --chunks-dir "$RUN_DIR" \
  --min-severity "$SEVERITY" \
  --emit-findings-to-issues-aggregate "$RUN_DIR/f2i-aggregate.md" || { echo "error: report.py (--emit-findings-to-issues-aggregate) failed (rc=$?); aborting" >&2; exit 2; }

echo "[uberscan] findings-to-issues aggregate written: $RUN_DIR/f2i-aggregate.md"
```

The `f2i-aggregate.md` file is wrapped in `<external-untrusted-input source="uberscan-aggregate">…</external-untrusted-input>` by `report.py` — matching the `findings-to-issues` agent's accepted-source allow-list.


## Phase 3 — File issues (skip iff --no-issues)

```bash
if [ "$NO_ISSUES" != "1" ]; then
  # CB6 gh rate-limit floor check before any write (mirrors the rate-limit-floor
  # pattern in agents/findings-to-issues.md Step 2 — the canonical reference).
  CORE_REMAINING=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)
  SEARCH_REMAINING=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null)

  # Resolve MAX_NEW from config (key uberscan.max_new, default 15)
  if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
    MAX_NEW="$(uberdev_read_int_in_range uberscan.max_new UBERDEV_UBERSCAN_MAX_NEW 1 200 15)"
  else
    MAX_NEW=15
  fi

  RATE_OK=1
  if [ -z "$CORE_REMAINING" ] || ! printf '%s' "$CORE_REMAINING" | grep -qE '^[0-9]+$'; then
    echo "[uberscan] CB6: gh rate_limit core probe returned non-numeric ('$CORE_REMAINING'); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ -z "$SEARCH_REMAINING" ] || ! printf '%s' "$SEARCH_REMAINING" | grep -qE '^[0-9]+$'; then
    echo "[uberscan] CB6: gh rate_limit search probe returned non-numeric ('$SEARCH_REMAINING'); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ "$RATE_OK" = "1" ] && [ "$CORE_REMAINING" -lt $(( 2 * MAX_NEW + 50 )) ]; then
    echo "[uberscan] CB6: core rate limit remaining ($CORE_REMAINING) below floor ($(( 2 * MAX_NEW + 50 ))); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ "$RATE_OK" = "1" ] && [ "$SEARCH_REMAINING" -lt $(( MAX_NEW + 5 )) ]; then
    echo "[uberscan] CB6: search rate limit remaining ($SEARCH_REMAINING) below floor ($(( MAX_NEW + 5 ))); skipping issue filing" >&2
    RATE_OK=0
  fi

  if [ "$RATE_OK" = "1" ]; then
    # findings-to-issues REQUIRES working_dir (its Step 1 refuses with
    # 'input-malformed' if working_dir is not an absolute path inside the
    # worktree); repo_slug + pr_commit_sha back the issue-body **Origin** link.
    # Local origin-URL parse first (fast); fall back to `gh repo view`.
    WORKING_DIR_ABS="$(git rev-parse --show-toplevel 2>/dev/null)"
    ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
    REPO_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E 's@.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$@\1@')"
    if [ -z "$REPO_SLUG" ] || [ "$REPO_SLUG" = "$ORIGIN_URL" ]; then
      REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
    fi
    HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
    # findings-to-issues hard-refuses without an absolute working_dir; if git/gh
    # resolution failed, skip filing rather than dispatch a doomed Task.
    DISPATCH_OK=1
    if [ -z "$WORKING_DIR_ABS" ] || [ -z "$HEAD_SHA" ] || [ -z "$REPO_SLUG" ]; then
      echo "[uberscan] error: could not resolve working_dir/HEAD/repo_slug (git/gh failed); skipping issue filing" >&2
      DISPATCH_OK=0
    fi
    # ===========================================================================
    # DISPATCH POINT — the orchestrating session fires ONE Task() call:
    #
    # DISPATCH: findings-to-issues
    #   run_id=$RUN_ID
    #   working_dir=$WORKING_DIR_ABS        (REQUIRED — agent refuses without it)
    #   repo_slug=$REPO_SLUG
    #   pr_commit_sha=$HEAD_SHA             (HEAD of the scanned working tree)
    #   phase1_aggregate_path=$RUN_DIR/f2i-aggregate.md
    #   phase2_aggregate_path=      (empty — no simplify phase in uberscan)
    #   finding_label=uberscan-finding
    #   finding_marker_slug=uberscan
    #   source_ref=/uberscan run $RUN_ID
    #   pr_number=              (empty — this is a whole-codebase audit, not a PR)
    #   max_new=$MAX_NEW
    # ===========================================================================
    if [ "$DISPATCH_OK" = "1" ]; then
      echo "DISPATCH: findings-to-issues with run_id=$RUN_ID, working_dir=$WORKING_DIR_ABS, repo_slug=$REPO_SLUG, pr_commit_sha=$HEAD_SHA, phase1_aggregate_path=$RUN_DIR/f2i-aggregate.md, finding_label=uberscan-finding, finding_marker_slug=uberscan, source_ref=/uberscan run $RUN_ID, pr_number= (empty), max_new=$MAX_NEW"
    fi
  else
    echo "[uberscan] issue filing skipped (rate-limit floor not met)"
  fi
fi
```


## Phase 4 — Summary + exit

```bash
# Read severity totals from the report if available
_uberscan_sev_total() {
  local sev="$1"
  if [ -f "$RUN_DIR/uberscan-report.md" ]; then
    grep -oE "^- ${sev}: [0-9]+" "$RUN_DIR/uberscan-report.md" | grep -oE '[0-9]+' || echo 0
  else
    # Count directly from chunk files
    python3 - "$RUN_DIR" "$sev" <<'PY'
import sys, glob, yaml
chunks_dir, sev = sys.argv[1], sys.argv[2]
total = 0
for path in glob.glob(f"{chunks_dir}/chunk-*-findings.yaml"):
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as e:
        print(f"error: failed to parse {path}: {e}", file=sys.stderr)
        sys.exit(1)
    total += sum(1 for f in (doc.get("findings") or []) if f.get("severity") == sev)
print(total)
PY
  fi
}

BLOCKER_COUNT="$(_uberscan_sev_total blocker)"
CRITICAL_COUNT="$(_uberscan_sev_total critical)"
MAJOR_COUNT="$(_uberscan_sev_total major)"
IMPORTANT_COUNT="$(_uberscan_sev_total important)"
SUGGESTION_COUNT="$(_uberscan_sev_total suggestion)"

echo
echo "[uberscan] === DONE ==="
echo "  run_id:          $RUN_ID"
echo "  scope:           $SCOPE"
echo "  total_chunks:    $TOTAL_EMITTED"
echo "  chunks_audited:  $TOTAL_CHUNKS_PROCESSED"
echo "  agents_per_chunk: 6"
[ "$FINDINGS_FLOOD" = "1" ] && echo "  partial:         yes (findings-flood CB5 triggered)"
[ "$(grep -c OVERFLOW=true "$RUN_DIR/run-state.txt" 2>/dev/null || echo 0)" -gt 0 ] && echo "  overflow:        yes (capped at MAX_CHUNKS=$MAX_CHUNKS; use --all to override)"
echo "  severity totals:"
echo "    blocker:       $BLOCKER_COUNT"
echo "    critical:      $CRITICAL_COUNT"
echo "    major:         $MAJOR_COUNT"
echo "    important:     $IMPORTANT_COUNT"
echo "    suggestion:    $SUGGESTION_COUNT"
[ "$NO_REPORT" != "1" ] && echo "  report:          $RUN_DIR/uberscan-report.md"
[ "$NO_ISSUES" != "1" ] && echo "  issues:          see findings-to-issues output above"

# Exit codes:
#   0 = clean completion
#   1 = circuit-breaker halt (CB1 overflow non-turbo, CB3 wave timeout, CB4 wall-clock, CB5 flood)
#   2 = fatal preflight failure
if [ "${CIRCUIT_BREAKER_HALT:-0}" = "1" ]; then
  exit 1
fi
exit 0
```

### Circuit-breaker exit mapping

| Circuit breaker | Trigger | Non-turbo behavior | Turbo behavior | Exit |
|---|---|---|---|---|
| **CB1** | `overflow=true` AND `--all` not passed | Halt with guidance | Cap-and-continue | `1` (non-turbo) / `0` (turbo) |
| **CB3** | Per-wave timeout > 900s | Stop early, partial | Stop early, partial | `1` |
| **CB4** | Wall-clock > 3600s (60 min) | Stop early, partial | Stop early, partial | `1` |
| **CB5** | Cumulative blocker+critical > 150 | Stop early, mark partial | Stop early, mark partial | `1` |
| **CB6** | gh rate-limit floor not met | Skip issue filing, continue | Skip issue filing, continue | `0` |
| **CB7** | Projected agents (chunks×6+2) > MAX_AGENTS (250) | Halt with guidance | Cap-and-continue | `1` (non-turbo) / `0` (turbo) |
