---
name: cluster-pipeline
description: "6-phase directive-emitter pipeline for /uberdev:cluster — preflight → fetch → chunk → analyze (parallel Task fanout) → propose → execute (--execute only)."
---

# Cluster Pipeline

Owns the lifecycle of `/uberdev:cluster`. The skill emits DISPATCH directives;
the orchestrating session fires all `Task()` calls in ONE message per wave.

## Phases
- **Phase 0 — Preflight (config-read, arg-parse, RUN_DIR provisioning)**
- **Phase 1 — Fetch (`gh issue list` + body-cap + refuse-list seed)**
- **Phase 2 — Chunk (inline `jq` slice; NO `lib/chunk.py`)**
- **Phase 3 — Analyze (parallel Task fanout via dispatching-parallel-agents)**
- **Phase 3.5 — Cross-chunk meta-pass (skip iff TOTAL_ISSUES < 2 x CHUNK_SIZE)**
- **Phase 4 — Propose (markdown report; `--dry-run` exits 0 here)**
- **Phase 5 — Execute (`--execute` only; per-cluster fold algorithm)**

## Constraints
- State persists to `$RUN_DIR/run-state.txt` between phases (each `bash` fence is a fresh shell — memory `project_uberdev_pipeline_directive_emitter`).
- NO awk `$1`/`$2`/`$3` column refs (skill-renderer `$N` collision — memory `project_uberdev_skill_renderer_dollar_arg_collision`).
- NO `t y p e   - t` or `B A S H _ R E M A T C H` (zsh-incompatible bashisms — memory `project_uberdev_type_t_bashism_zsh`). Use `command -v` for function detection; use `case` glob for regex matching.
- All gh-issue writes (close, edit, comment subcommands) use `--body-file -` or `--comment "$(cat …)"`, NEVER the unsafe `--body` form with a variable expansion. See security.md §Q2.

## Constants (reference, not executed)

The following constants are documented in spec §Components and used throughout
the pipeline. Values come from `lib/config-read.sh::uberdev_read_int_in_range`
under the `cluster.*` namespace at Phase 0; this block is documentation only.

```bash
# cluster-pipeline/SKILL.md constants (documentation only — runtime values via config-read)
CLUSTER_FOLDED_LABEL="folded"
CLUSTER_FOLD_FP_REGEX='<!-- uberdev:cluster-fold lead=([0-9]+) members=([0-9,]+) fingerprint=([a-f0-9]{16}) -->'
CLUSTER_MIN_CONFIDENCE_FLOOR_EXECUTE="0.85"
CLUSTER_MIN_CONFIDENCE_DEFAULT_DRYRUN="0.75"
CLUSTER_MAX_FOLD_PER_RUN="30"
CLUSTER_MAX_CLUSTER_SIZE_DEFAULT="8"
CLUSTER_MAX_CLUSTER_SIZE_HARD_CEILING="25"
CLUSTER_MAX_TOTAL_ISSUES_FETCHED="1000"
CLUSTER_REPO_SLUG_REGEX='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
CLUSTER_VIEWER_PERMISSION_ALLOWLIST="ADMIN MAINTAIN WRITE TRIAGE"
```

## Verbatim hard rules

> From CLAUDE.md and RFC 0007: "All artifacts live under `.uberdev/cluster/<RUN_ID>/`, where `RUN_ID` is a UTC timestamp plus a short random suffix." (constraints.md §RFC-0007)

> From CLAUDE.md: "**Never `--no-verify`** to bypass hooks unless user explicitly asks — investigate hook failure instead." (constraints.md §global)

> From `findings-to-issues.md:35`: "NEVER call `gh issue create --body "$VAR"` or `gh issue create --body "$(cmd)"`." All `gh` writes use `--body-file -` with stdin from a `mktemp` tempfile that was secret-scanned in the same pipeline. (security.md §Q2)

> From `solve-pipeline/SKILL.md:24-27`: "`UBERDEV_ACTIVE_LABEL` = `uberdev:active` ... NEVER set or removed by hand." `/cluster` READS this label to populate refuse list; never writes it. (constraints.md §solve-pipeline)

## Reuses

- `lib/config-read.sh` — `uberdev_read_int_in_range` for all cluster.* caps
- `lib/secret-scan.sh` — `uberdev_run_secret_scan_stdin` fail-CLOSED body scan
- `lib/dispatch.sh` — UBERDEV_TMPDIR resolution + pointer hygiene (optional)
- `lib/report_primitives.py` — `cell()`, `envelope()`, `fingerprint16()` shared helpers
- `skills/cluster-pipeline/cluster_propose.py` — proposal renderer + per-chunk prompt builder
- `agents/issue-similarity-analyzer.md` — read-only Sonnet agent dispatched per chunk

## Phase 0 — Preflight

```bash
set -u

# UBERDEV_TMPDIR sanitisation (constraints.md T4 — ReDoS rule; no metacharacters)
case "${UBERDEV_TMPDIR:-}" in
  *[!A-Za-z0-9_./-]*)
    echo "error: UBERDEV_TMPDIR contains forbidden characters" >&2
    exit 2 ;;
esac
: "${UBERDEV_TMPDIR:=/tmp}"

# Source the shared config-read helper
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
else
  echo "error: ${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh not readable" >&2
  exit 2
fi

# Config-read floors (cluster.* namespace; precedence env > config > default)
MAX_CLUSTER_SIZE="$(uberdev_read_int_in_range cluster.max_cluster_size UBERDEV_CLUSTER_MAX_CLUSTER_SIZE 1 25 8)"
CONCURRENCY="$(uberdev_read_int_in_range fanout_concurrency.cluster UBERDEV_CLUSTER_FANOUT 1 6 3)"
MAX_FOLD="$(uberdev_read_int_in_range cluster.max_fold_per_run UBERDEV_CLUSTER_MAX_FOLD 1 100 30)"
MAX_ISSUES="$(uberdev_read_int_in_range cluster.max_total_issues UBERDEV_CLUSTER_MAX_ISSUES 10 5000 1000)"

# RUN_ID — UTC timestamp + random suffix (NEVER from user input — constraints.md RFC-0007)
# Note the `:-0` fallback: zsh quirk where RANDOM may be unset in some sub-shell contexts.
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$(printf '%04x' "${RANDOM:-0}")"
RUN_DIR=".uberdev/cluster/${RUN_ID}"
mkdir -p "$RUN_DIR/chunks" "$RUN_DIR/dispatches" "$RUN_DIR/analyses"

# Parse flags — long-form --flag=value only (zsh-safe; no positional args here)
MODE="dryrun"
REPO_SLUG=""
LABEL=""
SINCE=""
ONLY_MINE=0
MIN_CONF=""
for arg in $ARGUMENTS; do
  case "$arg" in
    --dry-run)             MODE="dryrun" ;;
    --execute)             MODE="execute" ;;
    --only-mine)           ONLY_MINE=1 ;;
    --repo=*)              REPO_SLUG="${arg#--repo=}" ;;
    --label=*)             LABEL="${arg#--label=}" ;;
    --since=*)             SINCE="${arg#--since=}" ;;
    --min-confidence=*)    MIN_CONF="${arg#--min-confidence=}" ;;
    --max-cluster-size=*)  MAX_CLUSTER_SIZE="${arg#--max-cluster-size=}" ;;
    --concurrency=*)       CONCURRENCY="${arg#--concurrency=}" ;;
    --*)                   echo "warning: unknown flag $arg" >&2 ;;
  esac
done

# Default --min-confidence by mode
if [ -z "$MIN_CONF" ]; then
  if [ "$MODE" = "execute" ]; then
    MIN_CONF="0.85"
  else
    MIN_CONF="0.75"
  fi
fi

# --execute safety floor: refuse if --min-confidence < 0.85 (LLM overconfidence — prior-art.md §7)
# Float compare via python3 — NO awk float compare (awk $-refs would collide with renderer)
if [ "$MODE" = "execute" ]; then
  if ! python3 -c "import sys; sys.exit(0 if float('$MIN_CONF') >= 0.85 else 1)" 2>/dev/null; then
    echo "error: --execute requires --min-confidence >= 0.85 (got $MIN_CONF)" >&2
    echo "       Auto-mutation needs headroom against LLM overconfidence (RFC 0010 §Q4)." >&2
    exit 2
  fi
  if [ -z "$REPO_SLUG" ]; then
    echo "error: --execute requires --repo OWNER/NAME (no implicit gh default)" >&2
    exit 2
  fi
fi

# --repo validation (case glob — zsh-safe; avoids [[ =~ ]] regex matching which is bashism-only)
if [ -n "$REPO_SLUG" ]; then
  case "$REPO_SLUG" in
    [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) : ;;
    *)
      echo "error: --repo must match OWNER/NAME (alphanumerics, dots, dashes, underscores only)" >&2
      exit 2 ;;
  esac
  # viewerPermission pre-flight (--execute only — TRIAGE is min to close issues)
  if [ "$MODE" = "execute" ]; then
    PERM="$(gh repo view "$REPO_SLUG" --json viewerPermission --jq .viewerPermission 2>/dev/null)"
    case " ADMIN MAINTAIN WRITE TRIAGE " in
      *" $PERM "*) : ;;
      *)
        echo "error: --execute requires repo permission in {ADMIN,MAINTAIN,WRITE,TRIAGE}; got '$PERM'" >&2
        exit 2 ;;
    esac
  fi
fi

# Rate-limit pre-flight (security.md §Q7) — refuse if too few core requests remain
CORE_REM="$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo 0)"
NEEDED=$(( 2 * MAX_FOLD + 50 ))
if [ "$MODE" = "execute" ] && [ "$CORE_REM" -lt "$NEEDED" ]; then
  echo "error: gh API core bucket too low ($CORE_REM < $NEEDED) — wait for refresh or use --dry-run" >&2
  exit 2
fi

# Persist run state (HEREDOC — every fresh-shell phase reconstructs from this file)
RUN_DIR_ABS="$(pwd)/$RUN_DIR"
cat > "$RUN_DIR/run-state.txt" <<EOF
RUN_ID=$RUN_ID
RUN_DIR=$RUN_DIR_ABS
MODE=$MODE
REPO_SLUG=$REPO_SLUG
SCOPE_LABEL=$LABEL
SCOPE_SINCE=$SINCE
ONLY_MINE=$ONLY_MINE
MIN_CONFIDENCE=$MIN_CONF
MAX_CLUSTER_SIZE=$MAX_CLUSTER_SIZE
MAX_FOLD_PER_RUN=$MAX_FOLD
MAX_TOTAL_ISSUES=$MAX_ISSUES
CONCURRENCY=$CONCURRENCY
TOTAL_ISSUES=0
CHUNK_COUNT=0
CIRCUIT_BREAKER_HALT=
WRITES_SO_FAR=0
EOF

# Bootstrap pointer for cross-shell rehydration (memory project_uberdev_goal_runstate_crossshell_traps)
printf '%s\n' "$RUN_ID" > "$UBERDEV_TMPDIR/cluster-active-id.txt"

echo "DISPATCH: phase=preflight RUN_DIR=$RUN_DIR MODE=$MODE"
```

## Phase 1 — Fetch

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate from the bootstrap pointer (fresh shell — env did NOT survive)
if [ ! -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  echo "cluster: bootstrap pointer missing at $UBERDEV_TMPDIR/cluster-active-id.txt" >&2
  exit 2
fi
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt")"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
# Fallback to repo-relative path if absolute did not land
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID" >&2
  exit 2
fi

# Restore exported state from run-state.txt
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

# Source secret-scan helper (fail-CLOSED on rc>=2)
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"
fi

# Build the gh query
GH_ARGS=( "--state" "open" "--json" "number,title,body,createdAt,labels,author,assignees,comments" "--limit" "$MAX_TOTAL_ISSUES" )
if [ -n "${REPO_SLUG:-}" ];   then GH_ARGS=( "--repo" "$REPO_SLUG" "${GH_ARGS[@]}" ); fi
if [ -n "${SCOPE_LABEL:-}" ]; then GH_ARGS=( "${GH_ARGS[@]}" "--label" "$SCOPE_LABEL" ); fi
if [ -n "${SCOPE_SINCE:-}" ]; then GH_ARGS=( "${GH_ARGS[@]}" "--search" "created:>=$SCOPE_SINCE" ); fi
if [ "${ONLY_MINE:-0}" = "1" ]; then GH_ARGS=( "${GH_ARGS[@]}" "--author" "@me" ); fi

gh issue list "${GH_ARGS[@]}" > "$RUN_DIR/issues.json"

# Body-cap each issue body at 64 KiB (constraints.md T1 — ReDoS threat boundary)
jq -c 'map(.body |= (.[0:65536]))' "$RUN_DIR/issues.json" > "$RUN_DIR/issues.json.tmp" \
  && mv "$RUN_DIR/issues.json.tmp" "$RUN_DIR/issues.json"

# Initialise an empty refuse-list (touch is the simplest portable bootstrap)
: > "$RUN_DIR/refuse-list.txt"

# Secret-scan each body (security.md §Q5) — fail-CLOSED on rc>=2 means add to refuse-list
if command -v uberdev_run_secret_scan_stdin >/dev/null 2>&1; then
  # Emit one TSV line per issue: number<TAB>body, then read into N + BODY variables
  jq -r '.[] | "\(.number)\t\(.body)"' "$RUN_DIR/issues.json" \
    | while IFS=$'\t' read -r N BODY; do
        case "$N" in
          ''|*[!0-9]*) continue ;;
        esac
        printf '%s' "$BODY" | uberdev_run_secret_scan_stdin >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ge 2 ]; then
          echo "warning: issue #$N redacted from cluster pool (secret-scan failure)" >&2
          printf '%s\n' "$N" >> "$RUN_DIR/refuse-list.txt"
        elif [ "$rc" -eq 1 ]; then
          echo "warning: issue #$N redacted from cluster pool (secret detected)" >&2
          printf '%s\n' "$N" >> "$RUN_DIR/refuse-list.txt"
        fi
      done
fi

# Refuse-list seed — uberdev:active OR review-pr:pending OR folded labels (security.md §Q4)
jq -r '.[] | select((.labels // []) | map(.name) | (index("uberdev:active") or index("review-pr:pending") or index("folded"))) | .number' \
  "$RUN_DIR/issues.json" >> "$RUN_DIR/refuse-list.txt" 2>/dev/null || true

# Open-PR refuse: query for any open PR linked to each issue via closingIssuesReferences
if [ -n "${REPO_SLUG:-}" ]; then
  gh pr list --repo "$REPO_SLUG" --state open --json number,closingIssuesReferences \
    --jq '.[] | .closingIssuesReferences[]?.number' \
    >> "$RUN_DIR/refuse-list.txt" 2>/dev/null || true
else
  gh pr list --state open --json number,closingIssuesReferences \
    --jq '.[] | .closingIssuesReferences[]?.number' \
    >> "$RUN_DIR/refuse-list.txt" 2>/dev/null || true
fi

# Dedupe refuse list (sort -u -n)
if [ -s "$RUN_DIR/refuse-list.txt" ]; then
  sort -u -n "$RUN_DIR/refuse-list.txt" -o "$RUN_DIR/refuse-list.txt" 2>/dev/null || :
fi

# Update TOTAL_ISSUES in run-state.txt — rewrite-from-template (safest cross-platform)
TOTAL="$(jq 'length' "$RUN_DIR/issues.json" 2>/dev/null || echo 0)"
RS_TMP="$(mktemp)"
while IFS='=' read -r k v; do
  case "$k" in
    TOTAL_ISSUES) printf 'TOTAL_ISSUES=%s\n' "$TOTAL" ;;
    ''|\#*)       printf '%s=%s\n' "$k" "$v" ;;
    *)            printf '%s=%s\n' "$k" "$v" ;;
  esac
done < "$RUN_DIR/run-state.txt" > "$RS_TMP"
mv "$RS_TMP" "$RUN_DIR/run-state.txt"

REFUSE_COUNT="$(wc -l < "$RUN_DIR/refuse-list.txt" 2>/dev/null || echo 0)"
# Strip whitespace that wc on macOS prepends
REFUSE_COUNT="$(printf '%s' "$REFUSE_COUNT" | tr -d '[:space:]')"

echo "DISPATCH: phase=fetch TOTAL_ISSUES=$TOTAL REFUSE_COUNT=$REFUSE_COUNT"
```

## Phase 2 — Chunk

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt" 2>/dev/null)"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 2" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

CHUNK_SIZE=10

# Filter refuse-list members out of issues.json into cluster-pool.json
# Inline jq slice — NO lib/chunk.py (Q1 decision)
if [ ! -s "$RUN_DIR/refuse-list.txt" ]; then
  cp "$RUN_DIR/issues.json" "$RUN_DIR/cluster-pool.json"
else
  jq --slurpfile r <(jq -R 'tonumber' "$RUN_DIR/refuse-list.txt" | jq -s .) \
     '[.[] | select((.number) as $n | $r[0] | index($n) | not)]' \
     "$RUN_DIR/issues.json" > "$RUN_DIR/cluster-pool.json"
fi

# Compute chunk count
POOL_SIZE="$(jq 'length' "$RUN_DIR/cluster-pool.json" 2>/dev/null || echo 0)"
CHUNK_COUNT=$(( (POOL_SIZE + CHUNK_SIZE - 1) / CHUNK_SIZE ))
if [ "$CHUNK_COUNT" -lt 1 ]; then
  CHUNK_COUNT=1
fi

# Slice into chunks via jq --argjson (NO awk column refs)
i=0
while [ "$i" -lt "$CHUNK_COUNT" ]; do
  start=$(( i * CHUNK_SIZE ))
  end=$(( start + CHUNK_SIZE ))
  idx_padded="$(printf '%02d' $(( i + 1 )))"
  jq --argjson s "$start" --argjson e "$end" '.[$s:$e]' \
    "$RUN_DIR/cluster-pool.json" > "$RUN_DIR/chunks/chunk-${idx_padded}.json"
  i=$(( i + 1 ))
done

# Update CHUNK_COUNT in run-state.txt (rewrite-from-template)
RS_TMP="$(mktemp)"
while IFS='=' read -r k v; do
  case "$k" in
    CHUNK_COUNT) printf 'CHUNK_COUNT=%s\n' "$CHUNK_COUNT" ;;
    ''|\#*)      printf '%s=%s\n' "$k" "$v" ;;
    *)           printf '%s=%s\n' "$k" "$v" ;;
  esac
done < "$RUN_DIR/run-state.txt" > "$RS_TMP"
mv "$RS_TMP" "$RUN_DIR/run-state.txt"

echo "DISPATCH: phase=chunk CHUNK_COUNT=$CHUNK_COUNT POOL_SIZE=$POOL_SIZE"
```

## Phase 3 — Analyze (parallel `Task()` fanout)

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt" 2>/dev/null)"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 3" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

# Build per-chunk prompts. Each chunk wraps every issue body in its OWN
# external-untrusted-input envelope (security.md §Q1 — per-body source IDs).
for cf in "$RUN_DIR/chunks/"chunk-*.json; do
  [ -r "$cf" ] || continue
  name="$(basename "$cf" .json)"
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/cluster-pipeline/cluster_propose.py" \
    --build-prompt < "$cf" > "$RUN_DIR/dispatches/${name}-prompt.md"
  echo "DISPATCH: phase=analyze chunk=$name prompt=$RUN_DIR/dispatches/${name}-prompt.md"
done

echo "DISPATCH: phase=analyze WAVE_SIZE=$CONCURRENCY CHUNK_COUNT=$CHUNK_COUNT"
```

The orchestrating session reads each `DISPATCH:` line and fires
`Task("issue-similarity-analyzer", $prompt_path)` calls in **single-message batches of
`$CONCURRENCY`** (skill `dispatching-parallel-agents`). Wave-major: wait for each wave's
full return before firing the next. Each agent writes
`$RUN_DIR/analyses/chunk-NN-clusters.yaml`.

## Phase 3.5 — Cross-chunk meta-pass (skip iff TOTAL_ISSUES < 2 x CHUNK_SIZE)

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt" 2>/dev/null)"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 3.5" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

CHUNK_SIZE=10

# Skip rule: < 2 chunks worth of issues means no cross-chunk merge can exist
if [ "${TOTAL_ISSUES:-0}" -lt $((2 * CHUNK_SIZE)) ]; then
  echo "DISPATCH: phase=meta SKIPPED reason=insufficient-issues"
  exit 0
fi

# Aggregate all chunk YAMLs into a single JSON array for the meta-prompt
python3 - "$RUN_DIR" > "$RUN_DIR/all-analyses.json" <<'PY'
import json, sys, pathlib
try:
    import yaml
except ImportError:
    print('[]')
    sys.exit(0)
run_dir = pathlib.Path(sys.argv[1])
clusters = []
for yf in sorted((run_dir / "analyses").glob("*.yaml")):
    try:
        data = yaml.safe_load(yf.read_text()) or {}
    except Exception:
        continue
    for c in data.get("clusters", []) or []:
        clusters.append(c)
print(json.dumps(clusters))
PY

# Build the meta-pass prompt
python3 "${CLAUDE_PLUGIN_ROOT}/skills/cluster-pipeline/cluster_propose.py" \
  --build-meta-prompt < "$RUN_DIR/all-analyses.json" > "$RUN_DIR/dispatches/meta-prompt.md"

echo "DISPATCH: phase=meta prompt=$RUN_DIR/dispatches/meta-prompt.md"
```

After the meta-pass prompt is emitted, the orchestrator fires ONE more
`Task("issue-similarity-analyzer", $RUN_DIR/dispatches/meta-prompt.md)` call.
The agent writes `$RUN_DIR/analyses/meta-clusters.yaml`. Per prior-art.md §7,
the cross-chunk pass also acts as a soft calibration signal — clusters proposed
by multiple chunks gain effective confidence.

## Phase 4 — Propose

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt" 2>/dev/null)"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 4" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

# Aggregate all analyses/*.yaml into one JSON array, filter by MIN_CONFIDENCE
python3 - "$RUN_DIR" "$MIN_CONFIDENCE" > "$RUN_DIR/clusters-filtered.json" <<'PY'
import json, sys, pathlib
try:
    import yaml
except ImportError:
    print('[]')
    sys.exit(0)
run_dir = pathlib.Path(sys.argv[1])
min_conf = float(sys.argv[2])
clusters = []
for yf in sorted((run_dir / "analyses").glob("*.yaml")):
    try:
        data = yaml.safe_load(yf.read_text()) or {}
    except Exception:
        continue
    for c in data.get("clusters", []) or []:
        try:
            if float(c.get("confidence", 0)) >= min_conf:
                clusters.append(c)
        except (TypeError, ValueError):
            continue
print(json.dumps(clusters))
PY

# Render proposal report via cluster_propose.py (default mode = render)
python3 "${CLAUDE_PLUGIN_ROOT}/skills/cluster-pipeline/cluster_propose.py" \
  < "$RUN_DIR/clusters-filtered.json" > "$RUN_DIR/proposals.md"

CLUSTERS_N="$(jq 'length' "$RUN_DIR/clusters-filtered.json" 2>/dev/null || echo 0)"
echo "DISPATCH: phase=propose PROPOSALS=$RUN_DIR/proposals.md CLUSTERS=$CLUSTERS_N"

if [ "${MODE:-dryrun}" = "dryrun" ]; then
  echo
  echo "DRY-RUN complete. See $RUN_DIR/proposals.md"
  printf 'OK\n' > "$RUN_DIR/trust-signal.txt"
  exit 0
fi
```

## Phase 5 — Execute (`--execute` only)

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate
RUN_ID="$(cat "$UBERDEV_TMPDIR/cluster-active-id.txt" 2>/dev/null)"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 5" >&2
    exit 2 ;;
esac
RUN_DIR="$UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID"
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

# Source secret-scan helper for lead-body + per-member comment safety
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"
fi

# Provision the folded label (fail-soft; description <=100 chars per memory project_uberdev_label_desc_100char_limit)
LABEL_DESC="Closed as semantic duplicate by /uberdev:cluster; reversible via gh issue reopen."
gh label create --force "folded" \
  --color "C5DEF5" \
  --description "$LABEL_DESC" 2>&1 \
  || echo "warning: gh label create failed; continuing fail-soft" >&2

WRITES=0
: > "$RUN_DIR/ledger.jsonl"
touch "$RUN_DIR/ledger.jsonl"

# Per-cluster loop — break on MAX_FOLD_PER_RUN cap
jq -c '.[]' "$RUN_DIR/clusters-filtered.json" | while read -r cluster; do
  if [ "$WRITES" -ge "${MAX_FOLD_PER_RUN:-30}" ]; then
    echo "CB: MAX_FOLD_PER_RUN tripped at $WRITES"
    break
  fi

  LEAD="$(printf '%s' "$cluster" | jq -r '.lead')"
  MEMBERS_CSV="$(printf '%s' "$cluster" | jq -r '.members | join(",")')"
  RATIONALE="$(printf '%s' "$cluster" | jq -r '.rationale')"
  CONF="$(printf '%s' "$cluster" | jq -r '.confidence')"

  # Integer-validate the lead (constraints.md T3 — every gh-bound number is gated)
  case "$LEAD" in
    *[!0-9]*|"") echo "skip: invalid lead '$LEAD'"; continue ;;
  esac

  # Per-cluster size enforcement (security.md §Q3 — trust nothing the analyzer returned)
  MEM_COUNT="$(printf '%s' "$cluster" | jq '.members | length')"
  if [ "$MEM_COUNT" -gt "${MAX_CLUSTER_SIZE:-8}" ]; then
    echo "skip: cluster $LEAD exceeds --max-cluster-size ($MEM_COUNT > ${MAX_CLUSTER_SIZE:-8})"
    continue
  fi
  if [ "$MEM_COUNT" -gt 25 ]; then
    echo "REFUSE: hallucinated mega-cluster $LEAD ($MEM_COUNT members > 25 hard ceiling)"
    continue
  fi

  # Fingerprint via sha256 + cut -c1-16 (NOT awk substr — renderer collision)
  FP="$(printf '%s:%s:%s' "$LEAD" "$MEMBERS_CSV" "$RATIONALE" | sha256sum | cut -c1-16)"

  # Idempotency layer (a) — JSONL ledger
  if grep -qF "\"fingerprint\":\"$FP\"" "$RUN_DIR/ledger.jsonl" 2>/dev/null; then
    echo "SKIP: cluster $LEAD already in ledger (fp=$FP)"
    continue
  fi

  # Idempotency layer (b) — lead-body HTML-comment marker
  LEAD_BODY="$(gh issue view "$LEAD" --repo "$REPO_SLUG" --json body --jq .body 2>/dev/null)"
  if printf '%s' "$LEAD_BODY" | grep -qF "<!-- uberdev:cluster-fold lead=$LEAD"; then
    if printf '%s' "$LEAD_BODY" | grep -qF "fingerprint=$FP"; then
      echo "SKIP: cluster $LEAD already folded (body marker fp=$FP)"
      continue
    fi
  fi

  # Per-member TOCTOU re-check (security.md §Q4) + close
  printf '%s' "$cluster" | jq -r '.members[]' | while read -r M; do
    case "$M" in
      *[!0-9]*|"") continue ;;
    esac
    if [ "$M" = "$LEAD" ]; then
      continue
    fi

    # Single gh call requesting labels,state,closingIssuesReferences
    M_INFO="$(gh issue view "$M" --repo "$REPO_SLUG" --json labels,state,closingIssuesReferences --jq '.' 2>/dev/null)"
    M_STATE="$(printf '%s' "$M_INFO" | jq -r '.state')"
    M_LABELS="$(printf '%s' "$M_INFO" | jq -r '[.labels[].name] | join(",")')"
    M_LINKED_PRS="$(printf '%s' "$M_INFO" | jq -r '.closingIssuesReferences | length')"
    if [ "$M_STATE" != "OPEN" ]; then
      echo "SKIP: #$M state=$M_STATE"
      continue
    fi
    case ",$M_LABELS," in
      *,uberdev:active,*|*,review-pr:pending,*|*,folded,*)
        echo "SKIP: #$M has refuse-list label"
        continue ;;
    esac
    if [ "${M_LINKED_PRS:-0}" -gt 0 ]; then
      echo "SKIP: #$M gained a linked PR mid-run (closingIssuesReferences=$M_LINKED_PRS)"
      continue
    fi

    # Build the close-comment via mktemp + secret-scan before posting
    COMMENT_FILE="$(mktemp)"
    printf 'Folded into #%s by /uberdev:cluster.\n\nRationale (confidence %.2f): %s\n' \
      "$LEAD" "$CONF" "$RATIONALE" > "$COMMENT_FILE"

    if command -v uberdev_run_secret_scan_stdin >/dev/null 2>&1; then
      if ! uberdev_run_secret_scan_stdin < "$COMMENT_FILE" >/dev/null 2>&1; then
        echo "REFUSE: comment for #$M contains secret-shape; skipping fold"
        rm -f "$COMMENT_FILE"
        continue
      fi
    fi

    # Close with comment from file — NEVER --body "$VAR"
    gh issue close "$M" --repo "$REPO_SLUG" --reason "not planned" \
      --comment "$(cat "$COMMENT_FILE")" || true
    gh issue edit "$M" --repo "$REPO_SLUG" --add-label "folded" || true
    rm -f "$COMMENT_FILE"

    WRITES=$(( WRITES + 1 ))
    sleep 1
  done

  # Append "Folded children" section + HTML-comment marker on the lead body
  LEAD_NEW_FILE="$(mktemp)"
  {
    printf '%s\n\n' "$LEAD_BODY"
    printf '<!-- uberdev:cluster-fold lead=%s members=%s fingerprint=%s -->\n' \
      "$LEAD" "$MEMBERS_CSV" "$FP"
    printf '## Folded children\n\n'
    printf '%s' "$cluster" | jq -r '.members[] | "- #\(.)"'
  } > "$LEAD_NEW_FILE"

  LEAD_BODY_SAFE=1
  if command -v uberdev_run_secret_scan_stdin >/dev/null 2>&1; then
    if ! uberdev_run_secret_scan_stdin < "$LEAD_NEW_FILE" >/dev/null 2>&1; then
      echo "REFUSE: lead-body for #$LEAD contains secret-shape; skipping body update"
      LEAD_BODY_SAFE=0
    fi
  fi
  if [ "$LEAD_BODY_SAFE" = "1" ]; then
    # Use --body-file for the lead-body edit (security.md §Q2 forbids the unsafe variable form)
    gh issue edit "$LEAD" --repo "$REPO_SLUG" --body-file "$LEAD_NEW_FILE" || true
  fi
  rm -f "$LEAD_NEW_FILE"
  WRITES=$(( WRITES + 1 ))

  # Append to ledger.jsonl — JSON-encode the members list
  MEMBERS_JSON="$(printf '%s' "$cluster" | jq -c '.members')"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"run_id":"%s","lead":%s,"members":%s,"fingerprint":"%s","confidence":%s,"timestamp":"%s"}\n' \
    "$RUN_ID" "$LEAD" "$MEMBERS_JSON" "$FP" "$CONF" "$TS" \
    >> "$RUN_DIR/ledger.jsonl"

  sleep 1
done

printf 'OK\n' > "$RUN_DIR/trust-signal.txt"
echo "DISPATCH: phase=execute WRITES=$WRITES LEDGER=$RUN_DIR/ledger.jsonl"
```
