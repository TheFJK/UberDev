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
- `lib/chunk.py` — scope enumeration and budget-bounded chunking (shared with /ubersimplify)
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

# #171 — persist RUN_ID pointer so later fresh-shell blocks can reconstruct RUN_DIR.
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
  UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  _scan_ptr="$UBERDEV_TMPDIR/uberscan-active-id.txt"
  if _uberdev_dispatch_prepare_tmp_target "$_scan_ptr" 0 "uberscan"; then
    # Warn (not silent) if the write fails — the pointer is best-effort
    # (a missing one degrades to in-session RUN_ID), but a silent failure here
    # was the gap a fresh-shell block can't diagnose. A partial/corrupt write is
    # caught fail-closed by the re-read's `case` validator downstream.
    printf '%s\n' "$RUN_ID" > "$_scan_ptr" \
      || echo "uberscan: warning: failed to persist RUN_ID pointer; cross-shell RUN_DIR recovery may fail" >&2
  fi
fi

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
python3 "${CLAUDE_PLUGIN_ROOT}/lib/chunk.py" \
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
# Read all scalar fields from manifest in one @tsv pass (portable, no repeated jq forks).
IFS=$'\t' read -r OVERFLOW TOTAL_CHUNKS EMITTED_CHUNKS < <(
  jq -r '[.overflow, .total_chunks, (.chunks|length)] | @tsv' "$RUN_DIR/manifest.json"
)
if [ "$OVERFLOW" = "true" ] && [ "$ALL" != "1" ]; then
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

# CB7 projected-agent ceiling: EMITTED_CHUNKS × 6 reviewers + 2 repo-global agents.
# Independent backstop on top of CB1's chunk-count cap (a low MAX_CHUNKS with a
# high per-chunk fleet could still blow the agent budget).
# config-read.sh is conditionally sourced above (line ~100, if readable); use
# command -v to detect whether the function is in scope — portable across bash
# AND zsh. (type -t is a bash-only builtin flag: in zsh it exits non-zero with
# empty output, which would silently default MAX_AGENTS to 250 and ignore a
# configured uberscan.max_agents cap.)
if command -v uberdev_read_int_in_range >/dev/null 2>&1; then
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
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi

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
  # breaker PERSISTS its reason to $RUN_DIR/run-state.txt (#192) — Phase 4 runs in
  # a FRESH shell, so the in-memory CIRCUIT_BREAKER_HALT below does not survive the
  # phase boundary; the persisted file is the source of truth Phase 4 reads back.

  # CB3 per-wave timeout (15 min): the PREVIOUS wave's measured duration.
  if [ "${PREV_WAVE_ELAPSED:-0}" -gt 900 ]; then
    echo "[uberscan] CB3: previous wave exceeded 900s; halting before wave $WAVE_NUM" >&2
    echo "CIRCUIT_BREAKER_HALT=CB3" >> "$RUN_DIR/run-state.txt"
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB4 overall wall-clock budget check.
  if [ "$(_uberscan_elapsed)" -gt "$WALL_BUDGET_SECONDS" ]; then
    echo "[uberscan] CB4: overall budget of ${WALL_BUDGET_SECONDS}s exceeded after wave $(( WAVE_NUM - 1 )); halting" >&2
    echo "CIRCUIT_BREAKER_HALT=CB4" >> "$RUN_DIR/run-state.txt"
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB5 findings-flood guard.
  if [ "$CUMULATIVE_BLOCKERS_CRITICALS" -gt 150 ]; then
    echo "[uberscan] CB5: cumulative blocker+critical findings ($CUMULATIVE_BLOCKERS_CRITICALS) exceeded 150; marking report partial and halting" >&2
    # Persist all three flags together: PARTIAL (report banner), FINDINGS_FLOOD
    # (flood banner) and CIRCUIT_BREAKER_HALT=CB5 (exit-1 gate) — Phase 4 reads them back.
    {
      echo "PARTIAL=true"
      echo "FINDINGS_FLOOD=true"
      echo "CIRCUIT_BREAKER_HALT=CB5"
    } >> "$RUN_DIR/run-state.txt"
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
4. Re-evaluates CB3 (per-wave timeout), CB4 (wall-clock budget), and CB5 (findings flood). If any trips, it **appends the trip reason to `$RUN_DIR/run-state.txt`** (`CIRCUIT_BREAKER_HALT=CB3|CB4|CB5`, plus `FINDINGS_FLOOD=true` and `PARTIAL=true` for CB5) and stops dispatching further waves. The persisted `run-state.txt` is the **source of truth** (#192): this bash loop only emits dispatch directives — it returns in milliseconds, so its in-loop counters (`PREV_WAVE_ELAPSED`, `CUMULATIVE_BLOCKERS_CRITICALS`) never accumulate across waves on their own, and Phase 4 runs in a fresh shell. Phase 4 reconstructs the exit code and the partial/flood banner from `run-state.txt`, never from the in-memory `CIRCUIT_BREAKER_HALT`.


## Phase 1b — Repo-global pass

Fired once, in parallel with the first chunk wave (emit in the same ONE message as wave 1).

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi

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
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi

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
# --emit-totals-json guarantees $RUN_DIR/totals.json exists for Phase 4 even when
# --no-report was passed (the --out path already writes it as a sidecar).
python3 "${CLAUDE_PLUGIN_ROOT}/skills/uberscan-pipeline/report.py" \
  --run-id "$RUN_ID" \
  --chunks-dir "$RUN_DIR" \
  --min-severity "$SEVERITY" \
  --emit-totals-json "$RUN_DIR/totals.json" \
  --emit-findings-to-issues-aggregate "$RUN_DIR/f2i-aggregate.md" || { echo "error: report.py (--emit-findings-to-issues-aggregate) failed (rc=$?); aborting" >&2; exit 2; }

echo "[uberscan] findings-to-issues aggregate written: $RUN_DIR/f2i-aggregate.md"
```

The `f2i-aggregate.md` file is wrapped in `<external-untrusted-input source="uberscan-aggregate">…</external-untrusted-input>` by `report.py` — matching the `findings-to-issues` agent's accepted-source allow-list.


## Phase 3 — File issues (skip iff --no-issues)

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi

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
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi

# Read severity totals from the machine-readable sidecar (SSOT — report.py
# emits totals.json under $RUN_DIR, incl. --no-report mode). Single jq read
# replaces the former grep-the-rendered-report + python-recount paths.
TOTALS_JSON="$RUN_DIR/totals.json"
if [ -r "$TOTALS_JSON" ]; then
  IFS=$'\t' read -r BLOCKER_COUNT CRITICAL_COUNT MAJOR_COUNT IMPORTANT_COUNT SUGGESTION_COUNT < <(
    jq -r '[(.severities.blocker // 0), (.severities.critical // 0), (.severities.major // 0), (.severities.important // 0), (.severities.suggestion // 0)] | @tsv' "$TOTALS_JSON"
  )
else
  echo "[uberscan] warning: totals.json missing or unreadable at $TOTALS_JSON; severity totals shown as 0 (report.py may have failed to emit the sidecar)" >&2
  BLOCKER_COUNT=0; CRITICAL_COUNT=0; MAJOR_COUNT=0; IMPORTANT_COUNT=0; SUGGESTION_COUNT=0
fi

# Reconstruct circuit-breaker state from run-state.txt (#192). The Phase-1 loop
# runs in a SEPARATE shell, so the CIRCUIT_BREAKER_HALT / FINDINGS_FLOOD it set in
# memory are GONE here — defaulting the unset flag to 0 would exit a CB3/CB4/CB5
# halt as a false-clean 0 with no partial banner. Each Phase-1 break (and the
# orchestrator, between waves) appends its trip reason to run-state.txt; Phase 4 is
# the single source of truth that reads it back, exactly as it does for OVERFLOW.
RUN_STATE="$RUN_DIR/run-state.txt"
HALT_REASON=""
FINDINGS_FLOOD=0
if [ -r "$RUN_STATE" ]; then
  HALT_REASON="$(grep -E '^CIRCUIT_BREAKER_HALT=' "$RUN_STATE" | tail -n1 | cut -d= -f2)"
  grep -q '^FINDINGS_FLOOD=true' "$RUN_STATE" && FINDINGS_FLOOD=1
fi

echo
echo "[uberscan] === DONE ==="
echo "  run_id:          $RUN_ID"
echo "  scope:           $SCOPE"
echo "  total_chunks:    $TOTAL_EMITTED"
echo "  chunks_audited:  $TOTAL_CHUNKS_PROCESSED"
echo "  agents_per_chunk: 6"
[ -n "$HALT_REASON" ] && echo "  halted:          yes (circuit breaker $HALT_REASON tripped — results are INCOMPLETE, exit 1)"
[ "$FINDINGS_FLOOD" = "1" ] && echo "  partial:         yes (findings-flood CB5 triggered)"
grep -q '^OVERFLOW=true' "$RUN_STATE" 2>/dev/null && echo "  overflow:        yes (capped at MAX_CHUNKS=$MAX_CHUNKS; use --all to override)"
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
# HALT_REASON is reconstructed from run-state.txt above (#192): the in-memory
# CIRCUIT_BREAKER_HALT set in the Phase-1 loop does NOT survive into this fresh shell,
# so the exit decision keys off the persisted reason, not an unset in-memory flag.
if [ -n "$HALT_REASON" ]; then
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
