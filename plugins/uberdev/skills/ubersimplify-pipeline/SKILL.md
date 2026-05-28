---
name: ubersimplify-pipeline
description: Use when /uberdev:ubersimplify is invoked. Orchestrates whole-codebase 3-lens simplification — chunks the repo (shared lib/chunk.py), audits each chunk with the three code-simplifier lenses in concurrent waves, applies preserve-behavior fixes via code-fixer as one refactor: commit per chunk on a new branch, opens ONE PR, and files leftover blocker findings as GitHub issues. --audit-only is read-only.
model: inherit
---

# Ubersimplify Pipeline

Owns the lifecycle of `/uberdev:ubersimplify`. The *writing* sibling of the read-only `/uberscan`: it audits the whole codebase with the `code-simplifier` lenses, then APPLIES preserve-behavior refactors via `code-fixer` — one `refactor:` commit per chunk — on a new branch behind a single PR. `--audit-only` collapses it to a read-only scan (no branch/fix/PR). The skill emits DISPATCH directives; the orchestrating session fires all `Task()` calls — one wave at a time in Phase 1, one chunk at a time in Phase 3.

## Phases

- **Phase 0 — Parse + scope + chunk**
- **Phase 1 — Per-chunk fan-out waves (3 code-simplifier lenses per chunk)**
- **Phase 2 — Aggregate (per-chunk fixer aggregate via aggregate.py + human report)**
- **Phase 3 — Branch + SEQUENTIAL code-fixer apply (skip iff --audit-only)**
- **Phase 4 — Push + ONE gh pr create (skip iff --audit-only or 0 commits)**
- **Phase 5 — File leftover issues (aggregate.py issues → findings-to-issues; skip iff --no-issues)**
- **Phase 6 — Summary + exit**

## Schemas

### Schema C-LENS — per-chunk lens findings file

Written to `$RUN_DIR/chunk-NNN-lens.yaml` after each chunk's 3-lens reviewer wave completes. This is the input `aggregate.py fixer` dedups across lenses.

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

`code-simplifier` returns exactly this record shape (see `agents/code-simplifier.md` "Return contract"). `severity` is the two-value `blocker | suggestion` enum the `post-impl-review-aggregate` envelope uses — no normalization map needed. The `lens` field is mandatory so `aggregate.py` can merge by `file:line` across lenses (`Reuse+Quality`).

### Schema C-FIXER-DISP — per-chunk apply disposition

Written to `$RUN_DIR/chunk-NNN-fixer-disposition.yaml` after each Phase-3 `code-fixer` Task returns (its `findings_disposition` block verbatim). `aggregate.py issues` reads these to subtract APPLIED locations from the leftover-issues set.

```yaml
status: APPLIED | NO_FIXES_NEEDED | REFUSED
phase: phase2
findings_disposition:
  - location: <path>:<line>
    disposition: APPLIED | SKIPPED | REFUSED
    behavior_tag: preserve | change | n/a
    reason: <prose>
```

## Reuses

- `lib/config-read.sh` — `uberdev_read_int_in_range` for MAX_CHUNKS / CONCURRENCY / CHUNK_BUDGET / MAX_AGENTS / MAX_NEW
- `lib/chunk.py` — scope enumeration and budget-bounded chunking (shared with /uberscan)
- `skills/ubersimplify-pipeline/aggregate.py` — lens-merge dedup (`fixer` mode → `post-impl-review-aggregate` envelope) + leftover-issues collection (`issues` mode → `ubersimplify-aggregate` envelope)
- `agents/code-simplifier.md` — the 3 lenses (Reuse / Quality / Efficiency), audit-only
- `agents/code-fixer.md` — preserve-behavior apply as `refactor:` commits
- `agents/findings-to-issues.md` — durable GitHub issue persistence with fingerprint dedupe

## Sub-skill imports

None. This skill is fully self-contained.


## Phase 0 — Parse + scope + chunk

```bash
# Phase 0 precheck — PyYAML is required by aggregate.py.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
RUN_DIR=".uberdev/simplify/$RUN_ID"
mkdir -p "$RUN_DIR"

# #171 — persist RUN_ID pointer for fresh-shell RUN_DIR reconstruction.
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
  UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  _simp_ptr="$UBERDEV_TMPDIR/ubersimplify-active-id.txt"
  if _uberdev_dispatch_prepare_tmp_target "$_simp_ptr" 0 "ubersimplify"; then
    # Warn (not silent) if the write fails — the pointer is best-effort
    # (a missing one degrades to in-session RUN_ID), but a silent failure here
    # was the gap a fresh-shell block can't diagnose. A partial/corrupt write is
    # caught fail-closed by the re-read's `case` validator downstream.
    printf '%s\n' "$RUN_ID" > "$_simp_ptr" \
      || echo "ubersimplify: warning: failed to persist RUN_ID pointer; cross-shell RUN_DIR recovery may fail" >&2
  fi
fi

# Anchor an absolute working dir up front: code-fixer and findings-to-issues both
# REQUIRE an absolute working_dir inside the worktree (they refuse with
# input-malformed otherwise). Resolve once and reuse everywhere.
WORKING_DIR_ABS="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$WORKING_DIR_ABS" ]; then
  echo "error: /ubersimplify must run inside a git repository (git rev-parse failed)" >&2
  exit 2
fi

# Parse flags from $ARGUMENTS
SCOPE="."; ALL=0; AUDIT_ONLY=0; NO_ISSUES=0; NO_REPORT=0
MAX_CHUNKS_ARG=""; CONCURRENCY_ARG=""; TURBO=0; LENS_SUBSET=""
for arg in $ARGUMENTS; do
  case "$arg" in
    --audit-only)     AUDIT_ONLY=1 ;;
    --all)            ALL=1 ;;
    --no-issues)      NO_ISSUES=1 ;;
    --no-report)      NO_REPORT=1 ;;
    --turbo)          TURBO=1 ;;
    --lens=*)         LENS_SUBSET="${arg#--lens=}" ;;
    --max-chunks=*)   MAX_CHUNKS_ARG="${arg#--max-chunks=}" ;;
    --concurrency=*)  CONCURRENCY_ARG="${arg#--concurrency=}" ;;
    --*)              echo "warning: unknown flag $arg" >&2 ;;
    *)                SCOPE="$arg" ;;
  esac
done

# Resolve config via config-read.sh (precedence: env > config > default).
# MAX_CHUNKS [1,200] def 25; CONCURRENCY [1,16] def 3; CHUNK_BUDGET [4096,1048576] def 49152;
# MAX_AGENTS [1,2000] def 250.
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  if [ -n "$MAX_CHUNKS_ARG" ]; then
    MAX_CHUNKS="$MAX_CHUNKS_ARG"
  else
    MAX_CHUNKS="$(uberdev_read_int_in_range ubersimplify.max_chunks UBERDEV_UBERSIMPLIFY_MAX_CHUNKS 1 200 25)"
  fi
  if [ -n "$CONCURRENCY_ARG" ]; then
    CONCURRENCY="$CONCURRENCY_ARG"
  else
    CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.ubersimplify UBERDEV_UBERSIMPLIFY_FANOUT 1 16 3)"
  fi
  CHUNK_BUDGET="$(uberdev_read_int_in_range ubersimplify.chunk_budget_bytes UBERDEV_UBERSIMPLIFY_CHUNK_BUDGET 4096 1048576 49152)"
  MAX_AGENTS="$(uberdev_read_int_in_range ubersimplify.max_agents UBERDEV_UBERSIMPLIFY_MAX_AGENTS 1 2000 250)"
else
  MAX_CHUNKS="${MAX_CHUNKS_ARG:-25}"
  CONCURRENCY="${CONCURRENCY_ARG:-3}"
  CHUNK_BUDGET=49152
  MAX_AGENTS=250
fi

# Chunk the scope with the SHARED lib (not the retired uberscan-pipeline copy).
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

# CB1 overflow guard: repo chunked into more than MAX_CHUNKS pieces.
OVERFLOW="$(jq -r '.overflow' "$RUN_DIR/manifest.json")"
if [ "$OVERFLOW" = "true" ] && [ "$ALL" != "1" ]; then
  TOTAL_CHUNKS="$(jq -r '.total_chunks' "$RUN_DIR/manifest.json")"
  if [ "$TURBO" = "1" ]; then
    echo "[ubersimplify] overflow: repo has $TOTAL_CHUNKS chunks; capped at MAX_CHUNKS=$MAX_CHUNKS (--turbo cap-and-continue)" >&2
    echo "OVERFLOW=true" >> "$RUN_DIR/run-state.txt"
  else
    echo "error: repo chunked into $TOTAL_CHUNKS chunks which exceeds MAX_CHUNKS=$MAX_CHUNKS." >&2
    echo "  Narrow with a path arg (e.g. /ubersimplify src/), or pass --all to override the cap," >&2
    echo "  or set a higher cap with --max-chunks=N or ubersimplify.max_chunks in .uberdev/config.yaml." >&2
    exit 1
  fi
fi

EMITTED_CHUNKS="$(jq '.chunks | length' "$RUN_DIR/manifest.json")"

# CB7 projected-agent ceiling: EMITTED_CHUNKS × 3 lenses (NO repo-global pass —
# /ubersimplify has no Semgrep/coverage agents, unlike /uberscan). Independent
# backstop on top of CB1 (a low MAX_CHUNKS with a wide fleet could still blow budget).
PROJECTED_AGENTS=$(( EMITTED_CHUNKS * 3 ))
if [ "$PROJECTED_AGENTS" -gt "$MAX_AGENTS" ] && [ "$ALL" != "1" ]; then
  if [ "$TURBO" = "1" ]; then
    echo "[ubersimplify] CB7: projected $PROJECTED_AGENTS agents exceeds MAX_AGENTS=$MAX_AGENTS (--turbo cap-and-continue)" >&2
    echo "OVERFLOW=true" >> "$RUN_DIR/run-state.txt"
  else
    echo "error: projected agent count ($PROJECTED_AGENTS = ${EMITTED_CHUNKS}×3) exceeds MAX_AGENTS=$MAX_AGENTS." >&2
    echo "  Narrow with a path arg, pass --all to override, or raise ubersimplify.max_agents." >&2
    exit 1
  fi
fi

echo "[ubersimplify] run_id=$RUN_ID scope=$SCOPE chunks=$EMITTED_CHUNKS concurrency=$CONCURRENCY lenses=${LENS_SUBSET:-Reuse,Quality,Efficiency} audit_only=$AUDIT_ONLY projected_agents=$PROJECTED_AGENTS"
```


## Phase 1 — Per-chunk fan-out waves (3 lenses per chunk)

Each chunk receives a **file-set audit brief**: the agents audit EXISTING files as they stand in the repo (not a diff). Per chunk the orchestrating session fires **3** `Task()` calls IN ONE MESSAGE — one per lens (`Reuse`, `Quality`, `Efficiency`), each `subagent_type: uberdev:code-simplifier`. If `LENS_SUBSET` is set, dispatch only the named lenses for every chunk (e.g. `--lens=Reuse,Quality` → 2 Tasks/chunk; recompute the per-chunk fleet size accordingly).

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

# Read chunk list from manifest
CHUNK_IDS="$(jq -r '.chunks[].id' "$RUN_DIR/manifest.json")"
TOTAL_EMITTED="$(jq '.chunks | length' "$RUN_DIR/manifest.json")"

# Normalize the active lens set (default = all three, in checklist order).
if [ -n "$LENS_SUBSET" ]; then
  ACTIVE_LENSES="$(printf '%s' "$LENS_SUBSET" | tr ',' ' ')"
else
  ACTIVE_LENSES="Reuse Quality Efficiency"
fi

# CB4 overall wall-clock budget (60 minutes). The circuit breakers below are
# enforced by the ORCHESTRATING session between waves: this bash loop only emits
# dispatch directives, so it returns in milliseconds — the real wall-clock is
# spent firing the Task() calls. The orchestrator updates the state the breakers
# read (PREV_WAVE_ELAPSED, CUMULATIVE_BLOCKERS) after each wave returns.
WALL_START="$(date +%s)"
WALL_BUDGET_SECONDS=3600
CIRCUIT_BREAKER_HALT=0
PREV_WAVE_ELAPSED=0

# CB5 findings-flood guard (counts blocker-tier lens rows).
CUMULATIVE_BLOCKERS=0
FINDINGS_FLOOD=0

# Process chunks in waves of CONCURRENCY
WAVE_NUM=0
CHUNK_ARRAY=($CHUNK_IDS)
TOTAL_CHUNKS_PROCESSED=0

_ubersimplify_elapsed() { echo $(( $(date +%s) - WALL_START )); }

IDX=0
while [ "$IDX" -lt "${#CHUNK_ARRAY[@]}" ]; do
  WAVE_NUM=$(( WAVE_NUM + 1 ))

  # Breakers are checked at the TOP of each wave against state the orchestrator
  # maintains across waves (see the post-wave step after this loop). Tripping any
  # breaker sets CIRCUIT_BREAKER_HALT=1 so Phase 6 exits 1.

  # CB3 per-wave timeout (15 min): the PREVIOUS wave's measured duration.
  if [ "${PREV_WAVE_ELAPSED:-0}" -gt 900 ]; then
    echo "[ubersimplify] CB3: previous wave exceeded 900s; halting before wave $WAVE_NUM" >&2
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB4 overall wall-clock budget check.
  if [ "$(_ubersimplify_elapsed)" -gt "$WALL_BUDGET_SECONDS" ]; then
    echo "[ubersimplify] CB4: overall budget of ${WALL_BUDGET_SECONDS}s exceeded after wave $(( WAVE_NUM - 1 )); halting" >&2
    CIRCUIT_BREAKER_HALT=1; break
  fi

  # CB5 findings-flood guard.
  if [ "$CUMULATIVE_BLOCKERS" -gt 150 ]; then
    echo "[ubersimplify] CB5: cumulative blocker findings ($CUMULATIVE_BLOCKERS) exceeded 150; marking report partial and halting" >&2
    echo "PARTIAL=true" >> "$RUN_DIR/run-state.txt"
    FINDINGS_FLOOD=1; CIRCUIT_BREAKER_HALT=1; break
  fi

  WAVE_START="$(date +%s)"

  # Build the wave's chunk slice
  WAVE_END_IDX=$(( IDX + CONCURRENCY ))
  if [ "$WAVE_END_IDX" -gt "${#CHUNK_ARRAY[@]}" ]; then
    WAVE_END_IDX="${#CHUNK_ARRAY[@]}"
  fi

  echo "[ubersimplify] wave $WAVE_NUM: chunks ${CHUNK_ARRAY[$IDX]} to ${CHUNK_ARRAY[$(( WAVE_END_IDX - 1 ))]}"

  # Emit DISPATCH directives for each chunk in this wave.
  # The orchestrating session reads these and fires all lens Task() calls IN ONE MESSAGE.
  for (( CI=IDX; CI<WAVE_END_IDX; CI++ )); do
    CHUNK_ID="${CHUNK_ARRAY[$CI]}"
    CHUNK_NUM="$(printf '%03d' "$CHUNK_ID")"
    CHUNK_FILES_JSON="$(jq --argjson id "$CHUNK_ID" '.chunks[] | select(.id==$id) | .files' "$RUN_DIR/manifest.json")"
    CHUNK_FILES="$(printf '%s' "$CHUNK_FILES_JSON" | jq -r '.[]')"
    CHUNK_OUT="$RUN_DIR/chunk-${CHUNK_NUM}-lens.yaml"

    # Write the dispatch directive for this chunk
    {
      echo "schema_version: 1"
      echo "run_id: $RUN_ID"
      echo "chunk_id: $CHUNK_ID"
      echo "chunk_out: $CHUNK_OUT"
      echo "output_schema: C-LENS"
      echo "files: $CHUNK_FILES_JSON"
      echo "lenses_to_dispatch: [$(printf '%s' "$ACTIVE_LENSES" | sed 's/ /, /g')]"
      echo "agents_to_dispatch:"
      for LENS in $ACTIVE_LENSES; do
        echo "  - agent: code-simplifier"
        echo "    subagent_type: uberdev:code-simplifier"
        echo "    lens: $LENS"
      done
      echo "notes:"
      echo "  - \"Agents audit EXISTING files as-they-stand (NOT a diff).\""
      echo "  - \"One Task per lens; fire all lens Tasks for this chunk IN ONE MESSAGE.\""
      echo "  - \"Per-lens failure: drop that lens and continue with the remaining lenses.\""
    } > "$RUN_DIR/dispatch-chunk-${CHUNK_NUM}.yaml"

    # ===========================================================================
    # DISPATCH POINT — the orchestrating session reads dispatch-chunk-NNN.yaml
    # above and fires ONE Task() call PER ACTIVE LENS (default 3) IN A SINGLE
    # assistant message, each with subagent_type: uberdev:code-simplifier. Each
    # Task receives the file-set audit brief below PLUS its own lens-emphasis line.
    #
    # FILE-SET AUDIT BRIEF (embed in each Task's prompt verbatim, substituting the
    # lens name into the `## Lens emphasis` heading — code-simplifier runs the
    # matching checklist for that heading; see agents/code-simplifier.md):
    #
    #   You are auditing EXISTING source files as they stand in the repository —
    #   this is NOT a diff review. Your job is to find simplification
    #   opportunities in the code as written today.
    #
    #   ## Lens emphasis: <Reuse | Quality | Efficiency>
    #
    #   > Audit these EXISTING files as they stand (NOT a diff). Apply your
    #   > `## Lens emphasis` checklist. For the Reuse lens, hunt cross-file duplication
    #   > across the whole repository.
    #
    #   Files in this chunk:
    #     <contents of CHUNK_FILES — one path per line>
    #
    #   Read each file in full. Return findings in the C-LENS record schema (one
    #   record per finding, fields in this order):
    #
    #     - location: <path>:<line>
    #       severity: blocker | suggestion
    #       lens: <this Task's lens — Reuse | Quality | Efficiency>
    #       summary: <1-line, no source quoting>
    #       detail: <prose rationale + suggested direction>
    #
    #   If you have zero findings, return an empty list — do not invent findings.
    #
    # Per-lens failure: if a lens Task returns BLOCKED or unparseable output, log a
    # warning and continue with the remaining lenses for this chunk.
    # Merge all lens findings for this chunk into ONE C-LENS file: $CHUNK_OUT
    # ===========================================================================

    TOTAL_CHUNKS_PROCESSED=$(( TOTAL_CHUNKS_PROCESSED + 1 ))

    # After the wave completes, the orchestrator updates CUMULATIVE_BLOCKERS by
    # reading the chunk's lens file (CB5 counts blocker rows):
    #   chunk_b=$(python3 -c "
    #     import yaml
    #     doc = yaml.safe_load(open('$CHUNK_OUT')) or {}
    #     print(sum(1 for f in (doc.get('findings') or []) if f.get('severity') == 'blocker'))
    #   " 2>/dev/null || echo 0)
    #   CUMULATIVE_BLOCKERS=$(( CUMULATIVE_BLOCKERS + chunk_b ))
  done

  IDX="$WAVE_END_IDX"
  echo "[ubersimplify] wave $WAVE_NUM complete ($TOTAL_CHUNKS_PROCESSED/$TOTAL_EMITTED chunks processed)"
done
```

After each wave completes (all lens Tasks for the wave's chunks have returned), the orchestrating session:
1. Merges each chunk's per-lens findings into `$RUN_DIR/chunk-NNN-lens.yaml` (C-LENS schema; one `findings:` list with every lens's rows).
2. Updates `CUMULATIVE_BLOCKERS` by counting `severity: blocker` rows in the new chunk files.
3. Records the wave's actual elapsed seconds into `PREV_WAVE_ELAPSED` (from when this wave's Task() calls were fired to when they returned) — this is what CB3 reads on the next iteration.
4. Re-evaluates CB3 (per-wave timeout), CB4 (wall-clock budget), and CB5 (findings flood); if any trips, sets `CIRCUIT_BREAKER_HALT=1` and stops dispatching further waves.


## Phase 2 — Aggregate (per-chunk fixer aggregate + report)

For each `chunk-NNN-lens.yaml`, produce the per-chunk `code-fixer` input by deduping the lens findings across lenses by `file:line` (merged `lens` becomes `Reuse+Quality`, severity = max, summary/detail lens-prefixed). The output is wrapped in the `post-impl-review-aggregate` envelope `code-fixer` validates.

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

# Per-chunk fixer aggregate (the code-fixer input for Phase 3).
for LENS_FILE in "$RUN_DIR"/chunk-*-lens.yaml; do
  [ -e "$LENS_FILE" ] || continue
  CHUNK_NUM="$(basename "$LENS_FILE" | sed -E 's/^chunk-([0-9]+)-lens\.yaml$/\1/')"
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/ubersimplify-pipeline/aggregate.py" fixer \
    --lens-file "$LENS_FILE" \
    --out "$RUN_DIR/chunk-${CHUNK_NUM}-fixer.md" \
    || { echo "error: aggregate.py fixer failed for $LENS_FILE (rc=$?); aborting" >&2; exit 2; }
done
echo "[ubersimplify] per-chunk fixer aggregates written under $RUN_DIR"

# Optional human-readable report (skip iff --no-report). The report lists, per
# chunk, the merged findings and their lens/severity — a reviewer artifact only;
# the fix decision is driven by the fixer aggregates above, not this file.
if [ "$NO_REPORT" != "1" ]; then
  {
    echo "# /ubersimplify report — run $RUN_ID"
    echo
    echo "- scope: \`$SCOPE\`"
    echo "- chunks audited: $TOTAL_CHUNKS_PROCESSED / $TOTAL_EMITTED"
    echo "- lenses: ${LENS_SUBSET:-Reuse, Quality, Efficiency}"
    echo "- audit-only: $AUDIT_ONLY"
    echo
    echo "## Merged findings per chunk"
    for LENS_FILE in "$RUN_DIR"/chunk-*-lens.yaml; do
      [ -e "$LENS_FILE" ] || continue
      CHUNK_NUM="$(basename "$LENS_FILE" | sed -E 's/^chunk-([0-9]+)-lens\.yaml$/\1/')"
      echo
      echo "### Chunk $CHUNK_NUM"
      python3 - "$LENS_FILE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
findings = doc.get("findings") or []
if not findings:
    print("_no findings_")
else:
    for f in findings:
        print(f"- `{f.get('location','')}` **{f.get('severity','')}** ({f.get('lens','')}) — {f.get('summary','')}")
PY
    done
  } > "$RUN_DIR/ubersimplify-report.md"
  echo "[ubersimplify] report written: $RUN_DIR/ubersimplify-report.md"
else
  echo "[ubersimplify] --no-report: skipping the human report (fixer aggregates + issue aggregate still emitted)"
fi
```


## Phase 3 — Branch + sequential code-fixer apply (skip iff --audit-only)

Skipped entirely under `--audit-only` (read-only mode). Otherwise a new branch is cut from the current branch, then a `code-fixer` Task is dispatched **one chunk at a time** — concurrent apply Tasks would race the git index (two `git add`/`git commit` in flight corrupt the staging area). Each `code-fixer` produces exactly one `refactor:` commit (Phase 2 single-commit invariant, R8.6).

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

if [ "$AUDIT_ONLY" = "1" ]; then
  echo "[ubersimplify] --audit-only: skipping branch + apply (Phases 3-4)"
  BRANCH=""
  PR_NUMBER=""
  COMMIT_COUNT=0
else
  BASE_BRANCH="$(git branch --show-current)"
  BRANCH="ubersimplify/$RUN_ID"
  # Branch convention: checkout -b ubersimplify/<RUN_ID>
  git checkout -b "$BRANCH" || { echo "error: branch create failed for $BRANCH (rc=$?); aborting" >&2; exit 2; }

  # ===========================================================================
  # DISPATCH POINT — the orchestrating session fires ONE code-fixer Task() at a
  # time (NEVER in parallel — concurrent commits race the git index), for each
  # chunk whose fixer aggregate is non-empty. Wait for each to return and write
  # its findings_disposition before dispatching the next.
  #
  # For each chunk-NNN-fixer.md that has at least one finding row:
  #
  # DISPATCH (one at a time): code-fixer with
  #   findings_path=$RUN_DIR/chunk-NNN-fixer.md
  #   findings_aggregate=<contents of that file — already wrapped in
  #                       <external-untrusted-input source="post-impl-review-aggregate">>
  #   commit_range=HEAD~0..HEAD   (n/a — code-fixer applies to the working tree)
  #   working_dir=$WORKING_DIR_ABS
  #   pr_number=n/a               (PR not created until Phase 4)
  #   phase=phase2
  #   commit_type_prefix=refactor:
  #
  # After each Task returns, write its `findings_disposition` block verbatim to:
  #   $RUN_DIR/chunk-NNN-fixer-disposition.yaml   (Schema C-FIXER-DISP)
  # Then dispatch the next chunk's code-fixer.
  # ===========================================================================

  # Count commits the apply phase produced (used by Phase 4's skip guard).
  COMMIT_COUNT="$(git rev-list --count "$BASE_BRANCH..$BRANCH")"
  echo "[ubersimplify] apply complete: $COMMIT_COUNT refactor: commit(s) on $BRANCH"
fi
```


## Phase 4 — Push + ONE gh pr create (skip iff --audit-only or 0 commits)

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

if [ "$AUDIT_ONLY" = "1" ]; then
  echo "[ubersimplify] --audit-only: no push/PR"
elif [ "${COMMIT_COUNT:-0}" -eq 0 ]; then
  # No fixes landed — the codebase was already clean for these lenses. Tear down
  # the empty temp branch and return to the base branch so the tree is untouched.
  echo "[ubersimplify] no fixes applied — already clean; removing temp branch"
  git checkout "$BASE_BRANCH" || { echo "error: could not return to $BASE_BRANCH (rc=$?); temp branch $BRANCH left for inspection" >&2; exit 2; }
  git branch -D "$BRANCH" || echo "warning: could not delete empty temp branch $BRANCH (rc=$?)" >&2
  BRANCH=""
else
  # Build the PR body FIRST (via --body-file; never inline $VAR — second-order
  # injection guard). No attribution/co-author trailer of any kind (project rule).
  {
    echo "## /ubersimplify whole-codebase simplification"
    echo
    echo "Run \`$RUN_ID\` audited the codebase with the three \`code-simplifier\` lenses"
    echo "(**Reuse**, **Quality**, **Efficiency**) and applied preserve-behavior refactors"
    echo "via \`code-fixer\` — one \`refactor:\` commit per chunk."
    echo
    echo "| Metric | Value |"
    echo "|---|---|"
    echo "| Scope | \`$SCOPE\` |"
    echo "| Chunks audited | $TOTAL_CHUNKS_PROCESSED / $TOTAL_EMITTED |"
    echo "| Lenses | ${LENS_SUBSET:-Reuse, Quality, Efficiency} |"
    echo "| refactor: commits | $COMMIT_COUNT |"
    echo "| blocker findings | ${CUMULATIVE_BLOCKERS:-0} |"
    echo
    echo "Each commit is scope-locked to one chunk's findings and tagged \`[preserve]\`/\`[change]\`"
    echo "per finding. Leftover (non-applied) blocker findings are filed as \`ubersimplify-finding\`"
    echo "GitHub issues."
    echo
    echo "Review, then run \`/review-pr\` on this PR."
  } > "$RUN_DIR/pr-body.md"

  git push -u origin "$BRANCH" || { echo "error: git push failed (rc=$?); aborting" >&2; exit 2; }

  PR_URL="$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
    --title "refactor: /ubersimplify whole-codebase simplification ($RUN_ID)" \
    --body-file "$RUN_DIR/pr-body.md")" || { echo "error: gh pr create failed (rc=$?); aborting" >&2; exit 2; }
  PR_NUMBER="$(printf '%s' "$PR_URL" | sed -E 's@.*/pull/([0-9]+).*@\1@')"
  if ! printf '%s' "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
    # PR was created but its URL did not parse — surface it rather than dispatch
    # findings-to-issues with a silently-empty pr_number. Phase 5 then files
    # issues without the PR backref (degraded, not broken).
    echo "warning: could not parse PR number from '$PR_URL'; issues will file without a PR backref" >&2
    PR_NUMBER=""
  fi
  echo "[ubersimplify] opened PR #$PR_NUMBER: $PR_URL"
fi
```


## Phase 5 — File leftover issues (skip iff --no-issues)

Collect the fileable (`blocker`-tier) lens findings that `code-fixer` did NOT apply, wrap them in the `ubersimplify-aggregate` envelope, and hand them to `findings-to-issues`. Under `--audit-only` no apply phase ran, so every fileable finding is treated as deferred.

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

if [ "$NO_ISSUES" != "1" ]; then
  # Build the leftover-issues aggregate. --audit-only -> every fileable finding is
  # deferred (no disposition files exist); otherwise APPLIED locations are subtracted.
  AUDIT_FLAG=""
  [ "$AUDIT_ONLY" = "1" ] && AUDIT_FLAG="--audit-only"
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/ubersimplify-pipeline/aggregate.py" issues \
    --chunks-dir "$RUN_DIR" \
    --out "$RUN_DIR/f2i-aggregate.md" \
    $AUDIT_FLAG \
    || { echo "error: aggregate.py issues failed (rc=$?); aborting" >&2; exit 2; }
  echo "[ubersimplify] findings-to-issues aggregate written: $RUN_DIR/f2i-aggregate.md"

  # CB6 gh rate-limit floor check before any write (mirrors the rate-limit-floor
  # pattern in agents/findings-to-issues.md Step 2 — the canonical reference).
  CORE_REMAINING=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)
  SEARCH_REMAINING=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null)

  # Resolve MAX_NEW from config (key ubersimplify.max_new, default 10).
  if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
    MAX_NEW="$(uberdev_read_int_in_range ubersimplify.max_new UBERDEV_UBERSIMPLIFY_MAX_NEW 1 200 10)"
  else
    MAX_NEW=10
  fi

  RATE_OK=1
  if [ -z "$CORE_REMAINING" ] || ! printf '%s' "$CORE_REMAINING" | grep -qE '^[0-9]+$'; then
    echo "[ubersimplify] CB6: gh rate_limit core probe returned non-numeric ('$CORE_REMAINING'); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ -z "$SEARCH_REMAINING" ] || ! printf '%s' "$SEARCH_REMAINING" | grep -qE '^[0-9]+$'; then
    echo "[ubersimplify] CB6: gh rate_limit search probe returned non-numeric ('$SEARCH_REMAINING'); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ "$RATE_OK" = "1" ] && [ "$CORE_REMAINING" -lt $(( 2 * MAX_NEW + 50 )) ]; then
    echo "[ubersimplify] CB6: core rate limit remaining ($CORE_REMAINING) below floor ($(( 2 * MAX_NEW + 50 ))); skipping issue filing" >&2
    RATE_OK=0
  fi
  if [ "$RATE_OK" = "1" ] && [ "$SEARCH_REMAINING" -lt $(( MAX_NEW + 5 )) ]; then
    echo "[ubersimplify] CB6: search rate limit remaining ($SEARCH_REMAINING) below floor ($(( MAX_NEW + 5 ))); skipping issue filing" >&2
    RATE_OK=0
  fi

  if [ "$RATE_OK" = "1" ]; then
    # findings-to-issues REQUIRES an absolute working_dir inside the worktree (it
    # refuses with input-malformed otherwise); repo_slug + pr_commit_sha back the
    # issue-body Origin link. Local origin-URL parse first (fast); fall back to gh.
    ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
    REPO_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E 's@.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$@\1@')"
    if [ -z "$REPO_SLUG" ] || [ "$REPO_SLUG" = "$ORIGIN_URL" ]; then
      REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
    fi
    HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
    DISPATCH_OK=1
    if [ -z "$WORKING_DIR_ABS" ] || [ -z "$HEAD_SHA" ] || [ -z "$REPO_SLUG" ]; then
      echo "[ubersimplify] error: could not resolve working_dir/HEAD/repo_slug (git/gh failed); skipping issue filing" >&2
      DISPATCH_OK=0
    fi
    # ===========================================================================
    # DISPATCH POINT — the orchestrating session fires ONE Task() call:
    #
    # DISPATCH: findings-to-issues
    #   run_id=$RUN_ID
    #   working_dir=$WORKING_DIR_ABS        (REQUIRED — agent refuses without it)
    #   repo_slug=$REPO_SLUG
    #   pr_commit_sha=$HEAD_SHA
    #   phase1_aggregate_path=$RUN_DIR/f2i-aggregate.md
    #   phase2_aggregate_path=      (empty — single-aggregate run)
    #   finding_label=ubersimplify-finding
    #   finding_marker_slug=ubersimplify
    #   source_ref=/ubersimplify run $RUN_ID
    #   pr_number=$PR_NUMBER        (empty under --audit-only / 0-commit clean run)
    #   max_new=$MAX_NEW
    # ===========================================================================
    if [ "$DISPATCH_OK" = "1" ]; then
      echo "DISPATCH: findings-to-issues with run_id=$RUN_ID, working_dir=$WORKING_DIR_ABS, repo_slug=$REPO_SLUG, pr_commit_sha=$HEAD_SHA, phase1_aggregate_path=$RUN_DIR/f2i-aggregate.md, phase2_aggregate_path= (empty), finding_label=ubersimplify-finding, finding_marker_slug=ubersimplify, source_ref=/ubersimplify run $RUN_ID, pr_number=${PR_NUMBER:-} (empty under --audit-only), max_new=$MAX_NEW"
    fi
  else
    echo "[ubersimplify] issue filing skipped (rate-limit floor not met); branch/PR retained"
  fi
fi
```


## Phase 6 — Summary + exit

```bash
# #171 — rehydrate RUN_ID/RUN_DIR in a fresh shell.
UBERDEV_TMPDIR="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
if [ -z "${RUN_ID:-}" ] && [ -r "$UBERDEV_TMPDIR/ubersimplify-active-id.txt" ]; then
  RUN_ID="$(head -n1 "$UBERDEV_TMPDIR/ubersimplify-active-id.txt")"
  case "$RUN_ID" in ''|*[!0-9A-Za-z._-]*|*..*) echo "ubersimplify: invalid RUN_ID pointer" >&2; exit 2 ;; esac
  RUN_DIR=".uberdev/simplify/$RUN_ID"
fi

# Severity totals across all chunk lens files.
_ubersimplify_sev_total() {
  local sev="$1"
  python3 - "$RUN_DIR" "$sev" <<'PY'
import sys, glob, yaml
chunks_dir, sev = sys.argv[1], sys.argv[2]
total = 0
for path in glob.glob(f"{chunks_dir}/chunk-*-lens.yaml"):
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as e:
        print(f"error: failed to parse {path}: {e}", file=sys.stderr)
        sys.exit(1)
    total += sum(1 for f in (doc.get("findings") or []) if f.get("severity") == sev)
print(total)
PY
}

BLOCKER_COUNT="$(_ubersimplify_sev_total blocker)"
SUGGESTION_COUNT="$(_ubersimplify_sev_total suggestion)"

echo
echo "[ubersimplify] === DONE ==="
echo "  run_id:           $RUN_ID"
echo "  scope:            $SCOPE"
echo "  total_chunks:     $TOTAL_EMITTED"
echo "  chunks_audited:   $TOTAL_CHUNKS_PROCESSED"
echo "  lenses_per_chunk: ${LENS_SUBSET:-Reuse,Quality,Efficiency}"
[ "$FINDINGS_FLOOD" = "1" ] && echo "  partial:          yes (findings-flood CB5 triggered)"
[ "$(grep -c OVERFLOW=true "$RUN_DIR/run-state.txt" 2>/dev/null || echo 0)" -gt 0 ] && echo "  overflow:         yes (capped at MAX_CHUNKS=$MAX_CHUNKS; use --all to override)"
echo "  severity totals:"
echo "    blocker:        $BLOCKER_COUNT"
echo "    suggestion:     $SUGGESTION_COUNT"
if [ "$AUDIT_ONLY" = "1" ]; then
  echo "  mode:             audit-only (no branch/fix/PR)"
else
  echo "  refactor commits: ${COMMIT_COUNT:-0}"
  [ -n "${BRANCH:-}" ] && echo "  branch:           $BRANCH"
  [ -n "${PR_NUMBER:-}" ] && echo "  PR:               #$PR_NUMBER"
  [ -z "${BRANCH:-}" ] && [ "${COMMIT_COUNT:-0}" -eq 0 ] && echo "  result:           already clean (no commits; temp branch removed)"
fi
[ "$NO_REPORT" != "1" ] && echo "  report:           $RUN_DIR/ubersimplify-report.md"
[ "$NO_ISSUES" != "1" ] && echo "  issues:           see findings-to-issues output above (label: ubersimplify-finding)"
[ -n "${PR_NUMBER:-}" ] && echo "  next:             run /review-pr on PR #$PR_NUMBER (mandatory; NOT auto-chained)"

# Exit codes:
#   0 = clean completion (including audit-only and already-clean runs)
#   1 = circuit-breaker halt (CB1 overflow non-turbo, CB3 wave timeout, CB4 wall-clock, CB5 flood, CB7 agent ceiling non-turbo)
#   2 = fatal preflight failure (PyYAML missing, not a git repo, chunk.py/aggregate.py/git/gh hard failure)
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
| **CB5** | Cumulative blocker findings > 150 | Stop early, mark partial | Stop early, mark partial | `1` |
| **CB6** | gh rate-limit floor not met | Skip issue filing; **keep branch/PR** | Skip issue filing; keep branch/PR | `0` |
| **CB7** | Projected agents (chunks×3) > MAX_AGENTS (250) | Halt with guidance | Cap-and-continue | `1` (non-turbo) / `0` (turbo) |

CB7 projects `chunks × 3` (three lenses, no repo-global pass — unlike `/uberscan`'s `chunks × 6 + 2`). CB6 differs from a fatal halt: it skips only issue filing and **retains the branch and PR** so the applied refactors are never lost to a transient rate-limit dip.
