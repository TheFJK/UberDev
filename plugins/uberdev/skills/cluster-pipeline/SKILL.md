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
- `agents/issue-similarity-analyzer.md` — read-only `inherit`-model agent dispatched per chunk

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

# Parse flags — accepts both `--flag=value` and `--flag value` (space) forms.
# State machine: when EXPECT_VALUE_FOR is non-empty, the next non-flag arg is
# consumed as the value for the named flag. cluster.md (argument-hint + help
# table + preflight) advertises space-form; we accept both to avoid the
# documented form silently failing (memory project_uberdev_skill_renderer_dollar_arg_collision
# trap-class: documented behaviour must match runtime).
MODE="dryrun"
REPO_SLUG=""
LABEL=""
SINCE=""
ONLY_MINE=0
MIN_CONF=""
EXPECT_VALUE_FOR=""
for arg in $ARGUMENTS; do
  if [ -n "$EXPECT_VALUE_FOR" ]; then
    case "$EXPECT_VALUE_FOR" in
      repo)              REPO_SLUG="$arg" ;;
      label)             LABEL="$arg" ;;
      since)             SINCE="$arg" ;;
      min-confidence)    MIN_CONF="$arg" ;;
      max-cluster-size)  MAX_CLUSTER_SIZE="$arg" ;;
      concurrency)       CONCURRENCY="$arg" ;;
    esac
    EXPECT_VALUE_FOR=""
    continue
  fi
  case "$arg" in
    --dry-run)             MODE="dryrun" ;;
    --execute)             MODE="execute" ;;
    --only-mine)           ONLY_MINE=1 ;;
    --repo)                EXPECT_VALUE_FOR=repo ;;
    --repo=*)              REPO_SLUG="${arg#--repo=}" ;;
    --label)               EXPECT_VALUE_FOR=label ;;
    --label=*)             LABEL="${arg#--label=}" ;;
    --since)               EXPECT_VALUE_FOR=since ;;
    --since=*)             SINCE="${arg#--since=}" ;;
    --min-confidence)      EXPECT_VALUE_FOR=min-confidence ;;
    --min-confidence=*)    MIN_CONF="${arg#--min-confidence=}" ;;
    --max-cluster-size)    EXPECT_VALUE_FOR=max-cluster-size ;;
    --max-cluster-size=*)  MAX_CLUSTER_SIZE="${arg#--max-cluster-size=}" ;;
    --concurrency)         EXPECT_VALUE_FOR=concurrency ;;
    --concurrency=*)       CONCURRENCY="${arg#--concurrency=}" ;;
    --*)                   echo "warning: unknown flag $arg" >&2 ;;
  esac
done
if [ -n "$EXPECT_VALUE_FOR" ]; then
  echo "error: --$EXPECT_VALUE_FOR requires a value" >&2
  exit 2
fi

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

# --repo validation — anchored grep ensures every character is in the safe
# class. The earlier case glob `[A-Za-z0-9._-]*/[A-Za-z0-9._-]*` is permissive:
# in shell glob `*` matches ZERO OR MORE of ANY character, not "more chars from
# the preceding class". `printf | grep -Eq '^...$'` is zsh-safe (no bashism)
# and rejects shell-metachar contamination at the boundary.
if [ -n "$REPO_SLUG" ]; then
  if ! printf '%s\n' "$REPO_SLUG" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "error: --repo must match OWNER/NAME (alphanumerics, dots, dashes, underscores only)" >&2
    exit 2
  fi
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
EOF
# Note: no CIRCUIT_BREAKER_HALT / WRITES_SO_FAR keys here — the only live fold
# counter is the in-fence WRITES accumulator in Phase 5 (fence-scoped state in
# a directive-emitter never survives to a later fence, so a run-state mirror of
# it would be written once and never read — dead by construction).

# Bootstrap pointer for cross-shell rehydration (memory project_uberdev_goal_runstate_crossshell_traps).
# TWO lines: RUN_ID, then RUN_DIR_ABS. RUN_DIR is created under the repo CWD
# (see mkdir above), NOT under $UBERDEV_TMPDIR — so later fresh-shell phases can
# only relocate the run dir if the pointer carries the absolute path; a bare
# RUN_ID would leave them with a CWD-relative guess that breaks the moment the
# orchestrator's shell starts somewhere other than the repo root.
printf '%s\n%s\n' "$RUN_ID" "$RUN_DIR_ABS" > "$UBERDEV_TMPDIR/cluster-active-id.txt"

echo "DISPATCH: phase=preflight RUN_DIR=$RUN_DIR MODE=$MODE"
```

## Phase 1 — Fetch

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate from the bootstrap pointer (fresh shell — env did NOT survive).
# Pointer format (Phase 0): line 1 = RUN_ID, line 2 = RUN_DIR_ABS. The old
# probe $UBERDEV_TMPDIR/.uberdev/cluster/$RUN_ID could NEVER exist — Phase 0
# creates RUN_DIR under the repo CWD, not under $UBERDEV_TMPDIR.
if [ ! -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  echo "cluster: bootstrap pointer missing at $UBERDEV_TMPDIR/cluster-active-id.txt" >&2
  exit 2
fi
RUN_ID=""
RUN_DIR_PTR=""
{ IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer" >&2
    exit 2 ;;
esac
# Pointer RUN_DIR must be absolute and traversal-free; else discard it.
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
# Fallback to repo-relative path (works only when CWD == repo root)
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
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

# Fail-CLOSED on gh issue list failure: a silently-empty issues.json would
# fool every downstream phase into thinking the repo has zero open issues,
# which masks API/network breakage as a "nothing to cluster" no-op.
if ! gh issue list "${GH_ARGS[@]}" > "$RUN_DIR/issues.json"; then
  echo "error: gh issue list failed (rc=$?); cannot proceed without issue pool" >&2
  exit 2
fi

# Body-cap each issue body at 64 KiB (constraints.md T1 — ReDoS threat boundary)
jq -c 'map(.body |= (.[0:65536]))' "$RUN_DIR/issues.json" > "$RUN_DIR/issues.json.tmp" \
  && mv "$RUN_DIR/issues.json.tmp" "$RUN_DIR/issues.json"

# Initialise an empty refuse-list (touch is the simplest portable bootstrap)
: > "$RUN_DIR/refuse-list.txt"

# Secret-scan each body (security.md §Q5) — fail-CLOSED on rc>=2 means add to refuse-list
# Bodies are base64-encoded in jq so embedded newlines do not break the TSV
# read loop. The earlier `\(.body)` form leaked raw multi-line bodies into the
# `while IFS=$'\t' read -r N BODY` loop, where only the first body line landed
# in BODY and subsequent body lines re-fed into the loop where the
# `case "$N" in *[!0-9]*) continue ;;` arm silently dropped them — secrets on
# body lines 2+ passed through the fail-CLOSED scanner.
if command -v uberdev_run_secret_scan_stdin >/dev/null 2>&1; then
  jq -r '.[] | "\(.number)\t\(.body | @base64)"' "$RUN_DIR/issues.json" \
    | while IFS=$'\t' read -r N BODY_B64; do
        case "$N" in
          ''|*[!0-9]*) continue ;;
        esac
        BODY="$(printf '%s' "$BODY_B64" | base64 -d 2>/dev/null)" || {
          echo "warning: issue #$N base64 decode failed; redacting to refuse-list" >&2
          printf '%s\n' "$N" >> "$RUN_DIR/refuse-list.txt"
          continue
        }
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

# issues.json drives TOTAL_ISSUES — the cross-phase rendezvous count every later
# phase reads. A crashed/partial/0-byte producer must FATAL, not silently floor
# TOTAL to 0 (#265 — same masking class as #263). `jq 'length'` on a 0-byte file
# exits 0 with empty output, so the `-s` guard AND the `type=="array"` check are
# both load-bearing (mirrors the Phase-4 CLUSTERS_N gate later in this file).
if [ ! -s "$RUN_DIR/issues.json" ] \
   || ! TOTAL="$(jq 'if type == "array" then length else error("issues.json is not a JSON array") end' "$RUN_DIR/issues.json")"; then
  echo "cluster: FATAL - cannot read issue count (non-empty JSON array) from $RUN_DIR/issues.json (upstream gh/jq producer crashed or partial-wrote); aborting" >&2
  exit 2
fi
# Update TOTAL_ISSUES in run-state.txt — rewrite-from-template (safest cross-platform).
# mktemp failure is fail-CLOSED: run-state.txt is the cross-phase rendezvous
# point. Without TOTAL_ISSUES every subsequent phase reads zero.
RS_TMP="$(mktemp)" || { echo "error: mktemp failed for run-state rewrite (rc=$?)" >&2; exit 2; }
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

# Rehydrate from the 2-line bootstrap pointer (RUN_ID, RUN_DIR_ABS)
RUN_ID=""
RUN_DIR_PTR=""
if [ -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  { IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
fi
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 2" >&2
    exit 2 ;;
esac
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID at phase 2" >&2
  exit 2
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

# Compute chunk count. cluster-pool.json is always written just above (cp OR jq),
# so a missing/0-byte/non-array value here means that producer crashed — FATAL
# rather than silently floor POOL_SIZE to 0 (#265). A legitimately-empty pool
# still writes valid `[]` (POOL_SIZE=0 → CHUNK_COUNT floored to 1 below).
if [ ! -s "$RUN_DIR/cluster-pool.json" ] \
   || ! POOL_SIZE="$(jq 'if type == "array" then length else error("cluster-pool.json is not a JSON array") end' "$RUN_DIR/cluster-pool.json")"; then
  echo "cluster: FATAL - cannot read pool size (non-empty JSON array) from $RUN_DIR/cluster-pool.json (refuse-list filter producer crashed or wrote a non-array); aborting" >&2
  exit 2
fi
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

# Update CHUNK_COUNT in run-state.txt (rewrite-from-template).
# mktemp failure fail-CLOSED — same rationale as Phase 1: run-state.txt is
# the cross-phase contract.
RS_TMP="$(mktemp)" || { echo "error: mktemp failed for run-state rewrite (rc=$?)" >&2; exit 2; }
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

# Rehydrate from the 2-line bootstrap pointer (RUN_ID, RUN_DIR_ABS)
RUN_ID=""
RUN_DIR_PTR=""
if [ -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  { IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
fi
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 3" >&2
    exit 2 ;;
esac
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID at phase 3" >&2
  exit 2
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
full return before firing the next. Each agent RETURNS its clusters as a trailing
fenced YAML block — the analyzer is read-only (no Write tool;
`agents/issue-similarity-analyzer.md` whitelists only `Bash(gh issue view*)` + `Read`)
— and the ORCHESTRATOR transcribes each return verbatim to
`$RUN_DIR/analyses/chunk-NN-clusters.yaml`.

## Phase 3.5 — Cross-chunk meta-pass (skip iff TOTAL_ISSUES < 2 x CHUNK_SIZE)

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate from the 2-line bootstrap pointer (RUN_ID, RUN_DIR_ABS)
RUN_ID=""
RUN_DIR_PTR=""
if [ -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  { IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
fi
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 3.5" >&2
    exit 2 ;;
esac
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID at phase 3.5" >&2
  exit 2
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

# Aggregate per-chunk YAMLs as `{"chunk": <stem>, "yaml": <raw text>}` records
# — the schema build_meta_prompt() expects (cluster_propose.py:227-259). The
# earlier flat-clusters array left every envelope sourcing `chunk-unknown` and
# every yaml body empty, silently turning the cross-chunk meta-pass into a no-op.
python3 - "$RUN_DIR" > "$RUN_DIR/all-analyses.json" <<'PY'
import json
import pathlib
import sys
run_dir = pathlib.Path(sys.argv[1])
records = []
for yf in sorted((run_dir / "analyses").glob("*.yaml")):
    records.append({"chunk": yf.stem, "yaml": yf.read_text()})
print(json.dumps(records))
PY

# Build the meta-pass prompt
python3 "${CLAUDE_PLUGIN_ROOT}/skills/cluster-pipeline/cluster_propose.py" \
  --build-meta-prompt < "$RUN_DIR/all-analyses.json" > "$RUN_DIR/dispatches/meta-prompt.md"

echo "DISPATCH: phase=meta prompt=$RUN_DIR/dispatches/meta-prompt.md"
```

After the meta-pass prompt is emitted, the orchestrator fires ONE more
`Task("issue-similarity-analyzer", $RUN_DIR/dispatches/meta-prompt.md)` call.
The agent RETURNS its consolidated clusters as a trailing fenced YAML block
(read-only — no Write tool); the ORCHESTRATOR transcribes that return verbatim
to `$RUN_DIR/analyses/meta-clusters.yaml`. Per prior-art.md §7, the cross-chunk
pass also acts as a soft calibration signal — clusters proposed by multiple
chunks gain effective confidence.

## Phase 4 — Propose

```bash
set -u
: "${UBERDEV_TMPDIR:=/tmp}"

# Rehydrate from the 2-line bootstrap pointer (RUN_ID, RUN_DIR_ABS)
RUN_ID=""
RUN_DIR_PTR=""
if [ -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  { IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
fi
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 4" >&2
    exit 2 ;;
esac
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID at phase 4" >&2
  exit 2
fi
while IFS='=' read -r k v; do
  case "$k" in
    ''|\#*) continue ;;
  esac
  export "$k=$v"
done < "$RUN_DIR/run-state.txt"

# Aggregate analyses into one JSON array, filter by MIN_CONFIDENCE.
# Source selection: when the Phase-3.5 meta-pass ran, meta-clusters.yaml is the
# AUTHORITATIVE consolidation (it passes single-chunk clusters through verbatim
# — cluster_propose.py meta semantics), so aggregate ONLY it; globbing it
# TOGETHER with the chunk YAMLs double-counts every passthrough cluster and
# double-folds under --execute. No meta file → aggregate the chunk YAMLs.
# Either way, dedupe by (lead, frozenset(members)).
# A missing PyYAML dependency FAILS LOUD (nonzero exit + FATAL on stderr) —
# never a silent empty-set stdout + exit 0, which the downstream
# non-empty-array guard would accept as a legitimate empty run (the #263/#265
# masking class).
python3 - "$RUN_DIR" "$MIN_CONFIDENCE" > "$RUN_DIR/clusters-filtered.json" <<'PY'
import json, sys, pathlib
try:
    import yaml
except ImportError:
    sys.stderr.write("cluster: FATAL PyYAML not importable; cannot aggregate analyses YAML. Install pyyaml (pip install pyyaml) and re-run.\n")
    sys.exit(3)
run_dir = pathlib.Path(sys.argv[1])
min_conf = float(sys.argv[2])
meta_path = run_dir / "analyses" / "meta-clusters.yaml"
if meta_path.is_file():
    sources = [meta_path]
    meta_only = True
else:
    sources = sorted((run_dir / "analyses").glob("*.yaml"))
    meta_only = False
clusters = []
seen = set()
for yf in sources:
    try:
        data = yaml.safe_load(yf.read_text()) or {}
    except Exception as e:
        if meta_only:
            # Sole source: a parse failure here would silently become "[] = no
            # clusters" — fail loud instead (same masking class as the import).
            sys.stderr.write(f"cluster: FATAL unparseable meta-clusters.yaml {yf}: {e}\n")
            sys.exit(3)
        sys.stderr.write(f"cluster: WARN skipping unparseable analyses YAML {yf}: {e}\n")
        continue
    for c in data.get("clusters", []) or []:
        try:
            if float(c.get("confidence", 0)) < min_conf:
                continue
        except (TypeError, ValueError) as e:
            sys.stderr.write(f"cluster: WARN skipping cluster with non-numeric confidence in {yf}: {e}\n")
            continue
        try:
            key = (int(c.get("lead")), frozenset(int(m) for m in (c.get("members") or [])))
        except (TypeError, ValueError) as e:
            sys.stderr.write(f"cluster: WARN skipping cluster with non-numeric lead/members in {yf}: {e}\n")
            continue
        if key in seen:
            sys.stderr.write(f"cluster: WARN dropping duplicate cluster lead={key[0]} (same member set already aggregated)\n")
            continue
        seen.add(key)
        clusters.append(c)
print(json.dumps(clusters))
PY
AGG_RC=$?
if [ "$AGG_RC" -ne 0 ]; then
  echo "cluster: FATAL - Phase 4 aggregation failed (rc=$AGG_RC); see stderr above. Aborting before render/dispatch." >&2
  exit 2
fi

# Render proposal report via cluster_propose.py (default mode = render)
python3 "${CLAUDE_PLUGIN_ROOT}/skills/cluster-pipeline/cluster_propose.py" \
  < "$RUN_DIR/clusters-filtered.json" > "$RUN_DIR/proposals.md"

# CLUSTERS drives the DISPATCH contract the orchestrator reads. A crashed or
# partial Phase-4 aggregation (above) leaves clusters-filtered.json missing,
# zero-byte (the `>` redirect truncates it to 0 bytes BEFORE python3 writes, so
# any crash before the final print leaves exactly an empty file), malformed, or
# a non-array JSON value. The old `2>/dev/null || echo 0` masked every one of
# these as CLUSTERS=0, which the orchestrator cannot tell apart from a
# legitimate empty run. Require a non-empty, valid JSON *array* and hard-fail
# otherwise. Note `jq 'length'` on a 0-byte file exits 0 with empty output, so
# the `-s` guard (not jq's rc) is what distinguishes "crashed to 0 bytes" from a
# genuine empty run — which still writes valid `[]`, yielding CLUSTERS=0 and a
# normal dispatch.
if [ ! -s "$RUN_DIR/clusters-filtered.json" ] \
   || ! CLUSTERS_N="$(jq 'if type == "array" then length else error("clusters-filtered.json is not a JSON array") end' "$RUN_DIR/clusters-filtered.json")"; then
  echo "cluster: FATAL - cannot read a cluster count (non-empty JSON array) from $RUN_DIR/clusters-filtered.json (Phase 4 aggregation crashed or produced no valid JSON array); aborting instead of dispatching CLUSTERS=0" >&2
  exit 2
fi
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

# Rehydrate from the 2-line bootstrap pointer (RUN_ID, RUN_DIR_ABS)
RUN_ID=""
RUN_DIR_PTR=""
if [ -r "$UBERDEV_TMPDIR/cluster-active-id.txt" ]; then
  { IFS= read -r RUN_ID || :; IFS= read -r RUN_DIR_PTR || :; } < "$UBERDEV_TMPDIR/cluster-active-id.txt"
fi
case "$RUN_ID" in
  ''|*[!0-9A-Za-z._-]*|*..*)
    echo "cluster: invalid RUN_ID pointer at phase 5" >&2
    exit 2 ;;
esac
case "$RUN_DIR_PTR" in
  /*) ;;
  *) RUN_DIR_PTR="" ;;
esac
case "$RUN_DIR_PTR" in
  *..*) RUN_DIR_PTR="" ;;
esac
RUN_DIR="$RUN_DIR_PTR"
if [ -z "$RUN_DIR" ] || [ ! -r "$RUN_DIR/run-state.txt" ]; then
  RUN_DIR=".uberdev/cluster/$RUN_ID"
fi
if [ ! -r "$RUN_DIR/run-state.txt" ]; then
  echo "cluster: cannot locate run-state.txt for RUN_ID=$RUN_ID at phase 5" >&2
  exit 2
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

# Portable sha256: GNU coreutils ships sha256sum; stock macOS ships only
# shasum. Fail LOUD up front if neither exists — an empty fingerprint would
# make every later cluster false-SKIP on idempotency layer (a).
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "error: neither sha256sum nor shasum found on PATH; cannot compute fold fingerprints" >&2
  exit 2
fi
_uberdev_cluster_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

# Provision the folded label — fail-CLOSED: if the label cannot be created or
# updated, every subsequent `gh issue edit --add-label "folded"` would silently
# omit the label and break Phase 5's idempotency contract. Description ≤100
# chars per memory project_uberdev_label_desc_100char_limit.
LABEL_DESC="Closed as semantic duplicate by /uberdev:cluster; reversible via gh issue reopen."
if ! gh label create --force "folded" \
  --color "C5DEF5" \
  --description "$LABEL_DESC" >/dev/null 2>&1; then
  echo "error: gh label create 'folded' failed; Phase 5 cannot label folded duplicates correctly" >&2
  exit 2
fi

WRITES=0
: > "$RUN_DIR/ledger.jsonl"

# Per-cluster loop — break on MAX_FOLD_PER_RUN cap.
# Process substitution `done < <(jq ...)` keeps the loop body in the parent
# shell so WRITES accumulates across iterations. The earlier `jq | while`
# pipeline ran the loop body in a subshell, so every `WRITES=$(( WRITES + 1 ))`
# died at end-of-subshell and the cap check `[ "$WRITES" -ge "$MAX_FOLD_PER_RUN" ]`
# always read the initialised 0 — silently breaking the cap and reporting
# `WRITES=0` in the final DISPATCH line.
while IFS= read -r cluster; do
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
    *[!0-9]*|"") echo "skip: invalid lead '$LEAD'" >&2; continue ;;
  esac

  # Per-cluster size enforcement (security.md §Q3 — trust nothing the analyzer returned)
  MEM_COUNT="$(printf '%s' "$cluster" | jq '.members | length')"
  if [ "$MEM_COUNT" -gt "${MAX_CLUSTER_SIZE:-8}" ]; then
    echo "skip: cluster $LEAD exceeds --max-cluster-size ($MEM_COUNT > ${MAX_CLUSTER_SIZE:-8})" >&2
    continue
  fi
  if [ "$MEM_COUNT" -gt 25 ]; then
    echo "REFUSE: hallucinated mega-cluster $LEAD ($MEM_COUNT members > 25 hard ceiling)" >&2
    continue
  fi

  # Fingerprint via portable sha256 (sha256sum or shasum -a 256, probed above)
  # + cut -c1-16 (NOT awk substr — renderer collision)
  FP="$(printf '%s:%s:%s' "$LEAD" "$MEMBERS_CSV" "$RATIONALE" | _uberdev_cluster_sha256 | cut -c1-16)"
  case "$FP" in
    *[!a-f0-9]*|"")
      echo "error: fingerprint computation produced non-hex output for cluster $LEAD; aborting fold" >&2
      exit 2 ;;
  esac

  # Idempotency layer (a) — JSONL ledger
  if grep -qF "\"fingerprint\":\"$FP\"" "$RUN_DIR/ledger.jsonl" 2>/dev/null; then
    echo "SKIP: cluster $LEAD already in ledger (fp=$FP)" >&2
    continue
  fi

  # Idempotency layer (b) — lead-body HTML-comment marker
  LEAD_BODY="$(gh issue view "$LEAD" --repo "$REPO_SLUG" --json body --jq .body 2>/dev/null)"
  if printf '%s' "$LEAD_BODY" | grep -qF "<!-- uberdev:cluster-fold lead=$LEAD"; then
    if printf '%s' "$LEAD_BODY" | grep -qF "fingerprint=$FP"; then
      echo "SKIP: cluster $LEAD already folded (body marker fp=$FP)" >&2
      continue
    fi
  fi

  # Per-member TOCTOU re-check (security.md §Q4) + close.
  # Inner process substitution `done < <(printf | jq)` keeps WRITES in the
  # outer loop body's shell — same trap as the outer pipe-into-while.
  while IFS= read -r M; do
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
    case "$M_LINKED_PRS" in ''|*[!0-9]*) M_LINKED_PRS=0 ;; esac
    if [ "$M_STATE" != "OPEN" ]; then
      echo "SKIP: #$M state=$M_STATE" >&2
      continue
    fi
    case ",$M_LABELS," in
      *,uberdev:active,*|*,review-pr:pending,*|*,folded,*)
        echo "SKIP: #$M has refuse-list label" >&2
        continue ;;
    esac
    if [ "${M_LINKED_PRS:-0}" -gt 0 ]; then
      echo "SKIP: #$M gained a linked PR mid-run (closingIssuesReferences=$M_LINKED_PRS)" >&2
      continue
    fi

    # Build the close-comment via mktemp + secret-scan before posting.
    # mktemp failure is fail-CLOSED at the per-iteration boundary — we cannot
    # safely write a comment without a temp file (security.md §Q2 forbids
    # `gh issue close --comment "$VAR"`).
    COMMENT_FILE="$(mktemp)" || {
      echo "warning: mktemp failed for #$M comment; skipping fold (rc=$?)" >&2
      continue
    }
    printf 'Folded into #%s by /uberdev:cluster.\n\nRationale (confidence %.2f): %s\n' \
      "$LEAD" "$CONF" "$RATIONALE" > "$COMMENT_FILE"

    if command -v uberdev_run_secret_scan_stdin >/dev/null 2>&1; then
      if ! uberdev_run_secret_scan_stdin < "$COMMENT_FILE" >/dev/null 2>&1; then
        echo "REFUSE: comment for #$M contains secret-shape; skipping fold" >&2
        rm -f "$COMMENT_FILE"
        continue
      fi
    fi

    # Close with comment from file — NEVER --body "$VAR".
    # Capture rc so a failed close does NOT count as a successful fold and we
    # do not race ahead to label / ledger. Failed-close branch logs and
    # continues to the next member — close is per-issue and recoverable.
    if gh issue close "$M" --repo "$REPO_SLUG" --reason "not planned" \
         --comment "$(cat "$COMMENT_FILE")"; then
      if ! gh issue edit "$M" --repo "$REPO_SLUG" --add-label "folded"; then
        echo "warning: gh issue edit --add-label folded for #$M failed; close succeeded — manual relabel required" >&2
      fi
      rm -f "$COMMENT_FILE"
      WRITES=$(( WRITES + 1 ))
      sleep 1
    else
      rc=$?
      echo "warning: gh issue close #$M failed (rc=$rc); skipping label + ledger for this member" >&2
      rm -f "$COMMENT_FILE"
      continue
    fi
  done < <(printf '%s' "$cluster" | jq -r '.members[]')

  # Append "Folded children" section + HTML-comment marker on the lead body.
  # mktemp failure here is fail-CLOSED at the cluster boundary — without the
  # marker we cannot satisfy idempotency layer (b) on the next run.
  LEAD_NEW_FILE="$(mktemp)" || {
    echo "warning: mktemp failed for lead #$LEAD body update; skipping lead-body marker (rc=$?)" >&2
    continue
  }
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
      echo "REFUSE: lead-body for #$LEAD contains secret-shape; skipping body update" >&2
      LEAD_BODY_SAFE=0
    fi
  fi
  if [ "$LEAD_BODY_SAFE" = "1" ]; then
    # Use --body-file for the lead-body edit (security.md §Q2 forbids the unsafe variable form).
    # A failed lead-body update is a hard idempotency break: without the
    # HTML-comment marker, a re-run will re-fold the same members. Log + skip
    # the ledger append for THIS cluster (the per-member closes already
    # landed; the cluster is partially complete and a re-run must re-attempt
    # the body marker).
    if ! gh issue edit "$LEAD" --repo "$REPO_SLUG" --body-file "$LEAD_NEW_FILE"; then
      echo "warning: gh issue edit --body-file for lead #$LEAD failed (rc=$?); skipping ledger append" >&2
      rm -f "$LEAD_NEW_FILE"
      continue
    fi
  fi
  rm -f "$LEAD_NEW_FILE"
  WRITES=$(( WRITES + 1 ))

  # Append to ledger.jsonl — JSON-encode the members list. Ledger append
  # failure is fail-CLOSED: a missing ledger row means a re-run will re-fold
  # the same cluster (idempotency layer (a) breaks); abort the whole Phase 5
  # so the operator can investigate FS state before any more writes land.
  MEMBERS_JSON="$(printf '%s' "$cluster" | jq -c '.members')"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! printf '{"run_id":"%s","lead":%s,"members":%s,"fingerprint":"%s","confidence":%s,"timestamp":"%s"}\n' \
       "$RUN_ID" "$LEAD" "$MEMBERS_JSON" "$FP" "$CONF" "$TS" \
       >> "$RUN_DIR/ledger.jsonl"; then
    echo "error: ledger append failed for cluster $LEAD (rc=$?); aborting Phase 5 to avoid double-folds on re-run" >&2
    exit 2
  fi

  sleep 1
done < <(jq -c '.[]' "$RUN_DIR/clusters-filtered.json")

printf 'OK\n' > "$RUN_DIR/trust-signal.txt"
echo "DISPATCH: phase=execute WRITES=$WRITES LEDGER=$RUN_DIR/ledger.jsonl"
```
