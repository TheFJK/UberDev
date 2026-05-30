---
name: uberscan-pipeline
description: Use when /uberdev:uberscan is invoked. Orchestrates a read-only whole-codebase audit by packing the repo into a fixed fleet of byte-balanced areas (default 8), running ONE multi-lens reviewer per area in concurrent waves, executing a repo-global Semgrep SAST + test-coverage pass inline, aggregating findings into a markdown report, and filing deduped GitHub issues. Never writes code.
model: inherit
---

# Uberscan Pipeline

Owns the lifecycle of `/uberdev:uberscan`. Read-only audit — no agent writes source files. The skill emits DISPATCH directives; the orchestrating session fires all `Task()` calls in ONE message per wave.

## Phases

- **Phase 0 — Parse + scope + chunk**
- **Phase 1 — Per-area fan-out waves (1 multi-lens reviewer per area; fixed fleet ≤ NUM_AREAS)**
- **Phase 1b — Repo-global pass (Semgrep SAST + test-coverage) — runs INLINE, 0 dispatched agents**
- **Phase 2 — Aggregate + report**
- **Phase 3 — File issues (skip iff --no-issues)**
- **Phase 4 — Summary + exit**

## Schemas

### Schema C2 — per-area findings file

Written to `$RUN_DIR/chunk-NN-findings.yaml` after each area's reviewer returns. (The
filename keeps the `chunk-` prefix for back-compat with `report.py`'s glob — each file
is now one **area**, not a byte-budget chunk.)

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

The single per-area `code-reviewer` is briefed to return C2 rows **directly** (it owns
every lens, so there is no per-agent prose to normalize). If a finding arrives as
free-form prose, the orchestrating session normalizes it into C2 rows (one row per
issue; `detail` holds the prose excerpt; `severity` inferred from explicit tier markers;
`confidence: medium` when unstated) — same fallback as `post-impl-review/SKILL.md` Step 4.

## Reuses

- `lib/config-read.sh` — `uberdev_read_int_in_range` for NUM_AREAS and CONCURRENCY
- `lib/chunk.py` — scope enumeration + balanced area-packing (`--areas N`; shared with /ubersimplify)
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
# AREA MODEL: the whole repo is reviewed by a FIXED FLEET of <= NUM_AREAS agents
# (one multi-lens reviewer per byte-balanced area), so agent count is bounded
# independent of repo size — NOT files×6. Legacy `--max-chunks=N` is accepted as
# an alias for `--areas=N` so existing muscle memory keeps working.
SCOPE="."; ALL=0; NO_ISSUES=0; NO_REPORT=0; AREAS_ARG=""; CONCURRENCY_ARG=""; SEVERITY="major"; TURBO=0
for arg in $ARGUMENTS; do
  case "$arg" in
    --all)            ALL=1 ;;
    --no-issues)      NO_ISSUES=1 ;;
    --no-report)      NO_REPORT=1 ;;
    --turbo)          TURBO=1 ;;
    --areas=*)        AREAS_ARG="${arg#--areas=}" ;;
    --max-chunks=*)   AREAS_ARG="${arg#--max-chunks=}" ;;  # legacy alias → areas
    --concurrency=*)  CONCURRENCY_ARG="${arg#--concurrency=}" ;;
    --severity=*)     SEVERITY="${arg#--severity=}" ;;
    --*)              echo "warning: unknown flag $arg" >&2 ;;
    *)                SCOPE="$arg" ;;
  esac
done

# Resolve NUM_AREAS and CONCURRENCY via config-read.sh (precedence: env > config > default).
# Range: NUM_AREAS [1,24] default 8; CONCURRENCY [1,16] default 3. An explicit
# --areas/--max-chunks flag is honored verbatim (trusted user override); the
# config/default path is range-clamped.
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  if [ -n "$AREAS_ARG" ]; then
    NUM_AREAS="$AREAS_ARG"
  else
    NUM_AREAS="$(uberdev_read_int_in_range uberscan.areas UBERDEV_UBERSCAN_AREAS 1 24 8)"
  fi
  if [ -n "$CONCURRENCY_ARG" ]; then
    CONCURRENCY="$CONCURRENCY_ARG"
  else
    CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.uberscan UBERDEV_UBERSCAN_FANOUT 1 16 3)"
  fi
else
  NUM_AREAS="${AREAS_ARG:-8}"
  CONCURRENCY="${CONCURRENCY_ARG:-3}"
fi

# Pack the scope into <= NUM_AREAS byte-balanced areas (every file covered; no
# overflow-truncation — see lib/chunk.py pack_areas). The manifest keeps the same
# `chunks[]` schema (each entry is now an AREA), so report.py + downstream jq are
# unchanged.
python3 "${CLAUDE_PLUGIN_ROOT}/lib/chunk.py" \
  --scope "$SCOPE" \
  --areas "$NUM_AREAS" \
  --run-id "$RUN_ID" \
  > "$RUN_DIR/manifest.json" || { echo "error: chunk.py failed (rc=$?); aborting" >&2; exit 2; }

# Fail loud on a corrupt manifest — it must NOT silently proceed to a
# false-clean "0 chunks" run (which would skip every breaker and find nothing).
if ! jq -e '.' "$RUN_DIR/manifest.json" >/dev/null 2>&1; then
  echo "error: manifest.json is not valid JSON; aborting" >&2; exit 2
fi

# Read manifest scalars in one @tsv pass (portable, no repeated jq forks).
# EMITTED_AREAS is the area count = the per-area reviewer fleet size.
IFS=$'\t' read -r OVERFLOW TOTAL_CHUNKS EMITTED_AREAS < <(
  jq -r '[.overflow, .total_chunks, (.chunks|length)] | @tsv' "$RUN_DIR/manifest.json"
)

# CB1 is RETIRED in the area model: pack_areas covers every file in <= NUM_AREAS
# areas, so overflow is always false — there is no chunk-count truncation, and a
# whole-repo scan ALWAYS runs (it cannot silently drop the alphabetically-later
# files, the failure mode of the legacy byte-budget model). The guard below is
# purely defensive (chunk.py hardcodes overflow=false in area mode).
if [ "$OVERFLOW" = "true" ]; then
  echo "[uberscan] warning: unexpected overflow=true in an area-mode manifest (treating as non-fatal)" >&2
fi

# CB7 projected-agent ceiling: EMITTED_AREAS × 1 reviewer per area. The repo-global
# Semgrep + test-coverage passes now run INLINE (Phase 1b) — no dispatched agents —
# so the old "+2" is gone. CB7 is a backstop against an absurd explicit --areas
# override (the default path is already clamped to [1,24]).
# command -v (not `type -t`) so the function-in-scope probe is portable across
# bash AND zsh (the Bash tool runs /bin/zsh): `type -t fn` exits non-zero with empty
# output under zsh, which would silently default MAX_AGENTS and ignore the config cap.
if command -v uberdev_read_int_in_range >/dev/null 2>&1; then
  MAX_AGENTS="$(uberdev_read_int_in_range uberscan.max_agents UBERDEV_UBERSCAN_MAX_AGENTS 1 2000 250)"
else
  MAX_AGENTS=250
fi
PROJECTED_AGENTS=$(( EMITTED_AREAS ))
if [ "$PROJECTED_AGENTS" -gt "$MAX_AGENTS" ] && [ "$ALL" != "1" ]; then
  if [ "$TURBO" = "1" ]; then
    echo "[uberscan] CB7: projected $PROJECTED_AGENTS agents exceeds MAX_AGENTS=$MAX_AGENTS (--turbo cap-and-continue)" >&2
    echo "OVERFLOW=true" >> "$RUN_DIR/run-state.txt"
  else
    echo "error: projected agent count ($PROJECTED_AGENTS areas) exceeds MAX_AGENTS=$MAX_AGENTS." >&2
    echo "  Lower --areas=N, pass --all to override, or raise uberscan.max_agents in .uberdev/config.yaml." >&2
    exit 1
  fi
fi

echo "[uberscan] run_id=$RUN_ID scope=$SCOPE areas=$EMITTED_AREAS concurrency=$CONCURRENCY projected_agents=$PROJECTED_AGENTS (1 multi-lens reviewer per area; global pass inline)"
```


## Phase 1 — Per-chunk fan-out waves

Each **area** receives a **file-set audit brief** and is reviewed by **ONE multi-lens reviewer** — the fixed-fleet model (one agent per area, not six per byte-budget chunk). The agent audits EXISTING files as they stand in the repo (not a diff). The orchestrating session reads each DISPATCH directive and fires the wave's area `Task()` calls (one per area, up to `CONCURRENCY`) IN ONE MESSAGE.

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

  echo "[uberscan] wave $WAVE_NUM: areas ${CHUNK_ARRAY[$IDX]} to ${CHUNK_ARRAY[$(( WAVE_END_IDX - 1 ))]}"

  # Emit DISPATCH directives for each chunk in this wave.
  # The orchestrating session reads these and fires all Task() calls IN ONE MESSAGE.
  for (( CI=IDX; CI<WAVE_END_IDX; CI++ )); do
    CHUNK_ID="${CHUNK_ARRAY[$CI]}"
    CHUNK_NUM="$(printf '%03d' "$CHUNK_ID")"
    CHUNK_FILES_JSON="$(jq --argjson id "$CHUNK_ID" '.chunks[] | select(.id==$id) | .files' "$RUN_DIR/manifest.json")"
    CHUNK_FILES="$(printf '%s' "$CHUNK_FILES_JSON" | jq -r '.[]')"
    CHUNK_OUT="$RUN_DIR/chunk-${CHUNK_NUM}-findings.yaml"

    # Write the dispatch directive for this area (one multi-lens reviewer).
    cat > "$RUN_DIR/dispatch-chunk-${CHUNK_NUM}.yaml" <<EOF
schema_version: 1
run_id: $RUN_ID
chunk_id: $CHUNK_ID
chunk_out: $CHUNK_OUT
output_schema: C2
files: $CHUNK_FILES_JSON
agents_to_dispatch:
  - agent: code-reviewer
    role: area-multi-lens-reviewer
    lenses: [correctness, silent-failures-error-handling, type-design, comment-accuracy, test-coverage, general-catch-all]
notes:
  - "ONE reviewer per area (fixed-fleet model — NOT 6 per chunk). The single agent sweeps every lens above in one pass over the whole area."
  - "Agent audits EXISTING files as-they-stand (NOT a diff) and returns the C2 YAML directly."
  - "Area is the unit of failure: if the Task returns BLOCKED/unparseable, log a warning and continue with the remaining areas."
EOF

    # ===========================================================================
    # DISPATCH POINT — the orchestrating session reads dispatch-chunk-NNN.yaml
    # above and fires ONE Task() per area (the wave's areas together IN A SINGLE
    # assistant message). The single reviewer covers ALL lenses below.
    #
    # FILE-SET AUDIT BRIEF (embed in the area Task's prompt verbatim):
    #
    #   You are the sole reviewer for this AREA of the codebase. You are auditing
    #   EXISTING source files as they stand in the repository — this is NOT a diff
    #   review. Read each file in full, then sweep ALL of these lenses in one pass:
    #     1. Correctness — bugs, logic errors, race conditions, edge cases.
    #     2. Silent failures & error handling — swallowed errors, missing
    #        fallbacks, fail-open paths, unchecked external calls.
    #     3. Type design — weak/over-broad types, unexpressed invariants, `any`.
    #     4. Comment accuracy — comments that contradict the code, comment rot.
    #     5. Test coverage — untested branches, missing edge-case tests.
    #     6. General catch-all — anything else that lowers quality or safety.
    #
    #   Files in this area:
    #     <contents of CHUNK_FILES — one path per line>
    #
    #   Return findings in the C2 YAML schema (one row per finding; set `agent`
    #   to code-reviewer and put the lens name in the summary/detail):
    #
    #   schema_version: 1
    #   chunk_id: <CHUNK_ID>
    #   files: [<list of file paths you examined>]
    #   findings:
    #     - severity: blocker | critical | major | important | suggestion
    #       location: <path>:<line>
    #       agent: code-reviewer
    #       summary: <1-line, lead with the lens, e.g. "[correctness] ...">
    #       detail: <prose>
    #       confidence: low | medium | high
    #
    #   Minimum severity to report: $SEVERITY
    #
    # Area failure: if the Task returns BLOCKED or unparseable output, log a
    # warning and continue with the remaining areas (the area is the unit of
    # failure — there is no per-lens retry; one agent owns the whole area).
    # Write the area's C2 YAML to: $CHUNK_OUT
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
  echo "[uberscan] wave $WAVE_NUM complete ($TOTAL_CHUNKS_PROCESSED/$TOTAL_EMITTED areas processed)"
done
```

After each wave completes (all area Tasks have returned), the orchestrating session:
1. Writes each area's findings to `$RUN_DIR/chunk-NNN-findings.yaml` (C2 schema; `chunk-` prefix kept for the `report.py` glob).
2. Updates `CUMULATIVE_BLOCKERS_CRITICALS` from the new area files.
3. Records the wave's actual elapsed seconds into `PREV_WAVE_ELAPSED` (from when this wave's Task() calls were fired to when they returned) — this is what CB3 reads on the next iteration.
4. Re-evaluates CB3 (per-wave timeout), CB4 (wall-clock budget), and CB5 (findings flood). If any trips, it **appends the trip reason to `$RUN_DIR/run-state.txt`** (`CIRCUIT_BREAKER_HALT=CB3|CB4|CB5`, plus `FINDINGS_FLOOD=true` and `PARTIAL=true` for CB5) and stops dispatching further waves. The persisted `run-state.txt` is the **source of truth** (#192): this bash loop only emits dispatch directives — it returns in milliseconds, so its in-loop counters (`PREV_WAVE_ELAPSED`, `CUMULATIVE_BLOCKERS_CRITICALS`) never accumulate across waves on their own, and Phase 4 runs in a fresh shell. Phase 4 reconstructs the exit code and the partial/flood banner from `run-state.txt`, never from the in-memory `CIRCUIT_BREAKER_HALT`.


## Phase 1b — Repo-global pass (INLINE — 0 dispatched agents)

Runs once, **inline**: the orchestrator runs this fence directly (optionally as a
background `Bash` so it overlaps the area waves). This is part of the agent-count
win — the legacy model dispatched `research-security` + `research-test-coverage`
as 2 separate Tasks; both now run as plain `semgrep`/`python3` inline.

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/uberscan-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/uberscan-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "uberscan: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/scan/$RUN_ID"
fi
# Rehydrate SCOPE from the manifest (self-contained — this fence runs the real
# semgrep/coverage commands, so it needs SCOPE as a live shell var, not a
# directive placeholder). chunk.py records "whole-repo" for a "." scope.
SCOPE="$(jq -r '.scope // "."' "$RUN_DIR/manifest.json" 2>/dev/null)"
{ [ -z "$SCOPE" ] || [ "$SCOPE" = "null" ] || [ "$SCOPE" = "whole-repo" ]; } && SCOPE="."

# --- Semgrep SAST (inline, fail-soft — a missing/erroring semgrep degrades to a
# skip note, never aborts the audit). ---
SEC_OUT="$RUN_DIR/global-security.md"
SEC_JSON="$RUN_DIR/.semgrep.json"
if command -v semgrep >/dev/null 2>&1; then
  # Decouple semgrep's EXIT CODE from the parse decision: semgrep may exit
  # non-zero while still having written a valid, populated JSON (findings present,
  # or a partial-scan warning). Gating the parse on `&& [ -s ]` would then silently
  # drop real findings to the skip note. Instead: always attempt the scan, then
  # parse iff the JSON file is non-empty — the parser itself is malformed-safe
  # (try/except → graceful note), so a corrupt file degrades, never crashes.
  semgrep scan --config auto --json --quiet --timeout 0 --output "$SEC_JSON" "$SCOPE" >/dev/null 2>&1 || true
  if [ -s "$SEC_JSON" ]; then
    python3 - "$SEC_JSON" > "$SEC_OUT" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"_(Semgrep output unparseable: {exc})_"); raise SystemExit(0)
results = data.get("results") or []
rank = {"ERROR": 0, "WARNING": 1, "INFO": 2}
results.sort(key=lambda r: rank.get((r.get("extra") or {}).get("severity", "INFO"), 3))
if not results:
    print("_(Semgrep ran clean — no findings.)_"); raise SystemExit(0)
print(f"Semgrep flagged {len(results)} finding(s) (top 100 by severity):\n")
for r in results[:100]:
    extra = r.get("extra") or {}
    lines = (extra.get("message") or "").strip().splitlines()
    msg = lines[0][:200] if lines else ""
    start = r.get("start") or {}
    print(f"- **{extra.get('severity','INFO')}** `{r.get('check_id','?')}` "
          f"{r.get('path','?')}:{start.get('line','?')} — {msg}")
PY
  else
    echo "_(Semgrep produced no parseable output for scope \`$SCOPE\` — SAST pass skipped this run.)_" > "$SEC_OUT"
  fi
else
  echo "_(Semgrep not installed — SAST pass skipped. Install semgrep to enable.)_" > "$SEC_OUT"
fi
rm -f "$SEC_JSON" 2>/dev/null || true

# --- Test-coverage heuristic (inline, fail-soft). ---
# The whole computation is buffered into one string and the try/except wraps it,
# so the artifact is EITHER the full report OR a single skip note — never a
# partial write capped by a mid-loop traceback (which report.py would otherwise
# file verbatim as a bogus issue). Mirrors the Semgrep block's fail-soft contract;
# always exits 0 so the advisory coverage pass can never abort the audit.
COV_OUT="$RUN_DIR/global-coverage.md"
python3 - "$SCOPE" > "$COV_OUT" 2>/dev/null <<'PY' || printf '_(Test-coverage heuristic skipped — python3 unavailable or crashed.)_\n' > "$COV_OUT"
import os, subprocess, sys

def build(scope):
    out = subprocess.run(["git", "ls-files", "--", scope], capture_output=True, text=True)
    files = [f for f in out.stdout.splitlines() if f]
    SRC_EXT = (".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".rb", ".java", ".sh", ".php")
    TEST_MARK = (".test.", ".spec.", "_test.", "test_", "/tests/", "/test/", "/__tests__/")
    src, tests = [], []
    for f in files:
        if not f.endswith(SRC_EXT):
            continue
        (tests if any(m in f for m in TEST_MARK) else src).append(f)
    stems = set()
    for t in tests:
        base = os.path.basename(t)
        for tok in (".test", ".spec", "test_", "_test"):
            base = base.replace(tok, "")
        stems.add(base.split(".")[0])
    untested = []
    for s in src:
        if os.path.basename(s).split(".")[0] in stems:
            continue
        try:
            n = sum(1 for _ in open(s, errors="ignore"))
        except OSError:
            n = 0
        if n > 200:
            untested.append((s, n))
    untested.sort(key=lambda kv: -kv[1])
    ratio = len(tests) / max(1, len(src))
    lines = [f"Source files: {len(src)} · Test files: {len(tests)} · test:source ratio {ratio:.2f}\n",
             f"Large (>200-line) source files with no matching test file: {len(untested)}\n"]
    lines += [f"- {s} ({n} lines)" for s, n in untested[:30]]
    if not untested:
        lines.append("_(No large untested source files detected.)_")
    return "\n".join(lines)

scope = sys.argv[1] if len(sys.argv) > 1 else "."
try:
    # Build the WHOLE report first, then emit once — a crash mid-build writes only
    # the skip note, never a half-report-plus-traceback into the artifact.
    sys.stdout.write(build(scope) + "\n")
except Exception as exc:
    sys.stdout.write(f"_(Test-coverage heuristic skipped — {type(exc).__name__}: {exc})_\n")
PY

echo "[uberscan] global passes complete (Semgrep SAST + coverage) — ran INLINE, 0 dispatched agents"
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

# Phase 4 runs in a FRESH shell, so SCOPE / area counts from earlier phases are
# gone — derive them from on-disk artifacts (manifest + the findings files that
# were actually written), never from dead in-memory vars.
SCOPE="$(jq -r '.scope // "."' "$RUN_DIR/manifest.json" 2>/dev/null)"
{ [ -z "$SCOPE" ] || [ "$SCOPE" = "null" ]; } && SCOPE="(unknown)"
TOTAL_AREAS="$(jq '.chunks | length' "$RUN_DIR/manifest.json" 2>/dev/null || echo '?')"
AREAS_AUDITED="$(ls "$RUN_DIR"/chunk-*-findings.yaml 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "[uberscan] === DONE ==="
echo "  run_id:          $RUN_ID"
echo "  scope:           $SCOPE"
echo "  total_areas:     $TOTAL_AREAS"
echo "  areas_audited:   $AREAS_AUDITED"
echo "  agents_per_area: 1 (multi-lens reviewer; global Semgrep+coverage ran inline)"
[ -n "$HALT_REASON" ] && echo "  halted:          yes (circuit breaker $HALT_REASON tripped — results are INCOMPLETE, exit 1)"
[ "$FINDINGS_FLOOD" = "1" ] && echo "  partial:         yes (findings-flood CB5 triggered)"
grep -q '^OVERFLOW=true' "$RUN_STATE" 2>/dev/null && echo "  overflow:        yes (CB7 agent-cap hit; lower --areas or raise uberscan.max_agents)"
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
| **CB1** | _Retired in area mode_ — `pack_areas` covers every file in ≤ NUM_AREAS areas, so `overflow` is always false (no chunk-count truncation; a whole-repo scan always runs) | n/a | n/a | — |
| **CB3** | Per-wave timeout > 900s | Stop early, partial | Stop early, partial | `1` |
| **CB4** | Wall-clock > 3600s (60 min) | Stop early, partial | Stop early, partial | `1` |
| **CB5** | Cumulative blocker+critical > 150 | Stop early, mark partial | Stop early, mark partial | `1` |
| **CB6** | gh rate-limit floor not met | Skip issue filing, continue | Skip issue filing, continue | `0` |
| **CB7** | Projected agents (areas×1) > MAX_AGENTS (250) — backstop against an absurd explicit `--areas` | Halt with guidance | Cap-and-continue | `1` (non-turbo) / `0` (turbo) |
