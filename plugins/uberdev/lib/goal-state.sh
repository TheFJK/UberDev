# plugins/uberdev/lib/goal-state.sh
#
# Per-goal state machine + audit sink for /uberdev:goal (RFC 0005).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_goal_state_init               GOAL_ID
#   uberdev_goal_pr_state_transition      GOAL_ID PR FROM TO
#   uberdev_goal_issue_state_transition   GOAL_ID ISSUE FROM TO
#   uberdev_goal_read_trust_signal        AUDIT_JSON_PATH
#   uberdev_goal_check_fingerprint_repeat GOAL_ID CYCLE FINGERPRINT
#   uberdev_goal_should_automerge         GOAL_ID PR
#   uberdev_goal_build_unblock_graph      GOAL_ID
#   uberdev_goal_audit                    EVENT PAYLOAD_JSON
#   uberdev_goal_locate_review_pr_audit   ISSUE_NUM
#   uberdev_goal_extract_pr_num_from_log  STDOUT_LOG_PATH
#   uberdev_goal_list_prs_in_state        GOAL_ID STATE
#   uberdev_goal_read_merge_result        PR_NUM
# Internal:
#   _uberdev_goal_validate_int             N
#   _uberdev_goal_extract_fingerprint      BODY_TEXT
#   _uberdev_goal_parse_blocks_line        LINE
#   _uberdev_goal_count_merge_attempts     GOAL_ID PR
#   _uberdev_goal_pr_state_machine_valid   FROM TO
#   _uberdev_goal_now_secs
#   _uberdev_goal_persist_fp               GOAL_ID CYCLE FP   (alias: _persist_fp)
#   _uberdev_goal_dispatch_review_pr       PR_NUM
#   _uberdev_goal_dispatch_merge           PR_NUM
#   _uberdev_goal_check_unblock            HELD_PR_NUM
# External imports:
#   (none — discover.sh is sourced opportunistically for stderr-isolation helpers
#   but no function names are required from it. The `gh_jq_or_jq` shim below
#   is a local-file jq wrapper; the spec/plan named it after a discover.sh
#   helper that was planned but never landed. Trust-signal + merge-result
#   audit reads target LOCAL files written by /review-pr and /merge, so plain
#   `jq <file> <filter>` is the correct primitive — `gh ... --jq` only works
#   on gh API output and would mis-serve these call sites.)
#
# Sourced by:
#   - skills/goal-pipeline/SKILL.md (every phase)
#   - tests/goal.test.sh (shape checks)
#
# Crash-restart contract (D19): _UBERDEV_GOAL_STATE_LOADED guards
# double-sourcing within a single process. Resume-after-SIGKILL is OUT OF
# SCOPE for v1.

if [ "${_UBERDEV_GOAL_STATE_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_GOAL_STATE_LOADED=1

# Source discover.sh opportunistically for its stderr-isolation helpers;
# tolerated absent (the goal-state.sh functions below do not hard-require
# any discover.sh symbol).
_UBERDEV_GOAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_UBERDEV_MERGE_DISCOVER_LOADED:-}" ] && \
   [ -f "$_UBERDEV_GOAL_LIB_DIR/../skills/merge-pipeline/lib/discover.sh" ]; then
  # shellcheck source=/dev/null
  . "$_UBERDEV_GOAL_LIB_DIR/../skills/merge-pipeline/lib/discover.sh"
fi

# gh_jq_or_jq LOCAL_FILE JQ_FILTER
# Local-file jq wrapper. Reads a JSON file from disk and applies a jq filter.
# Named for the spec/plan's reference to a discover.sh helper that was never
# added; the audit/trust-signal/merge-result call sites take local file paths
# (not gh API output), so plain `jq` is the correct underlying tool.
gh_jq_or_jq() {
  local file="$1" filter="$2"
  [ -n "$file" ] && [ -f "$file" ] || return 1
  jq -r "$filter" "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _uberdev_goal_validate_int N
# POSIX-portable digits-only check (mirror of discover.sh:101-102).
_uberdev_goal_validate_int() {
  local n="$1"
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _uberdev_goal_now_secs
# Epoch seconds (date +%s is POSIX).
_uberdev_goal_now_secs() { date +%s; }

# _uberdev_goal_parse_blocks_line LINE
# ReDoS-safe (D9 + T1): anchored bash regex; numeric re-validation defense-in-depth.
_uberdev_goal_parse_blocks_line() {
  local line="$1"
  if [[ "$line" =~ ^Blocks:\ \#([0-9]+)$ ]]; then
    local pr_num="${BASH_REMATCH[1]}"
    _uberdev_goal_validate_int "$pr_num" || return 1
    printf '%s\n' "$pr_num"
  fi
}

# _uberdev_goal_extract_fingerprint BODY_TEXT
# Anchored hex16 extraction from <!-- uberdev:review-pr-finding fingerprint=... -->.
_uberdev_goal_extract_fingerprint() {
  local body="$1"
  # Anchored grep -oE on the documented FINDING_FINGERPRINT_REGEX shape.
  printf '%s' "$body" \
    | grep -oE '<!-- uberdev:review-pr-finding fingerprint=[a-f0-9]{16} -->' \
    | head -n 1 \
    | sed -E 's/.*fingerprint=([a-f0-9]{16}).*/\1/'
}

# _uberdev_goal_pr_state_machine_valid FROM TO
# D17 — Forbidden transitions: never merge YELLOW/RED inside /goal;
# merged + merge-failed are terminal.
_uberdev_goal_pr_state_machine_valid() {
  local from="$1" to="$2"
  case "$from" in
    merged|merge-failed) return 1 ;;   # terminal
  esac
  case "$from->$to" in
    "dispatched->pushed-reviewing") return 0 ;;
    "pushed-reviewing->green") return 0 ;;
    "pushed-reviewing->yellow-held") return 0 ;;
    "pushed-reviewing->red-held") return 0 ;;
    "yellow-held->green") return 0 ;;   # after successful re-review
    "red-held->green") return 0 ;;
    "green->merging") return 0 ;;
    "merging->merged") return 0 ;;
    "merging->merge-failed") return 0 ;;
    "yellow-held->merging") return 1 ;; # D17 forbidden
    "red-held->merging")    return 1 ;; # D17 forbidden
    *) return 1 ;;
  esac
}

# _uberdev_goal_count_merge_attempts GOAL_ID PR
# Reads goal-<id>-merge-attempts.tsv (TSV row PR_NUM\tCOUNT); echoes
# integer count for given PR (0 if absent).
_uberdev_goal_count_merge_attempts() {
  local goal_id="$1" pr="$2"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-merge-attempts.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -v p="$pr" '$1==p {c=$2} END {print c+0}' "$f"
}

# _uberdev_goal_persist_fp GOAL_ID CYCLE FP
# Append CYCLE\tFINGERPRINT to fingerprints TSV. _persist_fp is a one-line
# forwarder so inline pseudocode call sites remain terse.
_uberdev_goal_persist_fp() {
  local goal_id="$1" cycle="$2" fp="$3"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  printf '%s\t%s\n' "$cycle" "$fp" \
    >> "$tmpdir/goal-$goal_id-fingerprints.tsv"
}
_persist_fp() { _uberdev_goal_persist_fp "$@"; }

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

# uberdev_goal_state_init GOAL_ID
# D4 + T4 — Refuse unsafe $UBERDEV_TMPDIR; truncate-create the 5 per-goal
# state files (jsonl + 4 TSVs).
uberdev_goal_state_init() {
  local goal_id="$1"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  case "$tmpdir" in
    *[!A-Za-z0-9_./-]*)
      printf 'goal-state: refusing unsafe UBERDEV_TMPDIR: %s\n' "$tmpdir" >&2
      return 1 ;;
  esac
  mkdir -p "$tmpdir" 2>/dev/null || true
  : > "$tmpdir/goal-$goal_id.jsonl"
  : > "$tmpdir/goal-$goal_id-pr-states.tsv"
  : > "$tmpdir/goal-$goal_id-issue-states.tsv"
  : > "$tmpdir/goal-$goal_id-fingerprints.tsv"
  : > "$tmpdir/goal-$goal_id-merge-attempts.tsv"
}

# uberdev_goal_audit EVENT PAYLOAD_JSON
# D3 + audit contract: enum-checked event; manual-escape framing (mirrors
# discover.sh:39-53).
uberdev_goal_audit() {
  local event="$1" payload="$2"
  case "$event" in
    goal_dispatched|goal_pr_transition|goal_unblock_triggered|goal_cycle_completed|goal_converged|goal_circuit_breaker) ;;
    *) printf 'goal-state: unknown event %s\n' "$event" >&2; return 1 ;;
  esac
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local ts; ts="$(date -u +%FT%TZ 2>/dev/null || date +%s)"
  printf '{"ts":"%s","event":"%s","payload":%s}\n' "$ts" "$event" "$payload" \
    >> "$tmpdir/goal-${UBERDEV_GOAL_ID:-unknown}.jsonl"
}

# uberdev_goal_pr_state_transition GOAL_ID PR FROM TO
# Validate + append + audit.
uberdev_goal_pr_state_transition() {
  local goal_id="$1" pr="$2" from="$3" to="$4"
  _uberdev_goal_validate_int "$pr" || return 1
  _uberdev_goal_pr_state_machine_valid "$from" "$to" || {
    printf 'goal-state: invalid PR transition %s->%s\n' "$from" "$to" >&2
    return 2
  }
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  printf '%s\t%s\t%s\n' "$pr" "$to" "$(_uberdev_goal_now_secs)" \
    >> "$tmpdir/goal-$goal_id-pr-states.tsv"
  uberdev_goal_audit goal_pr_transition \
    "{\"goal_id\":\"$goal_id\",\"pr\":$pr,\"from\":\"$from\",\"to\":\"$to\"}"
}

# uberdev_goal_issue_state_transition GOAL_ID ISSUE FROM TO
# D2 issue machine: input → solving → pr-pushed → resolved; solving → failed
# and pr-pushed → failed allowed. No audit event (issue transitions are
# derived state; audit covers PR transitions + cycle boundaries).
uberdev_goal_issue_state_transition() {
  local goal_id="$1" issue="$2" from="$3" to="$4"
  _uberdev_goal_validate_int "$issue" || return 1
  case "$from->$to" in
    "input->solving"|"solving->pr-pushed"|"pr-pushed->resolved"|"solving->failed"|"pr-pushed->failed") ;;
    *) printf 'goal-state: invalid issue transition %s->%s\n' "$from" "$to" >&2; return 2 ;;
  esac
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  printf '%s\t%s\t%s\n' "$issue" "$to" "$(_uberdev_goal_now_secs)" \
    >> "$tmpdir/goal-$goal_id-issue-states.tsv"
}

# uberdev_goal_read_trust_signal AUDIT_JSON_PATH
# D17 — GREEN/YELLOW/RED/STALE/MISSING from /review-pr Phase 2.5 audit.
uberdev_goal_read_trust_signal() {
  local audit_path="$1"
  [ -f "$audit_path" ] || { printf 'missing\n'; return 0; }
  local p25
  p25="$(gh_jq_or_jq "$audit_path" '.phases.phase2_5 // empty' 2>/dev/null)"
  [ -n "$p25" ] || { printf 'stale\n'; return 0; }
  local blocker critical halted
  blocker="$(printf '%s' "$p25" | jq -r '.by_severity.blocker // 0')"
  critical="$(printf '%s' "$p25" | jq -r '.by_severity.critical // 0')"
  halted="$(printf '%s' "$p25" | jq -r '.halted // false')"
  if [ "$halted" = "true" ] || [ "$blocker" -gt 0 ]; then printf 'red\n'; return 0; fi
  if [ "$critical" -gt 0 ]; then printf 'yellow\n'; return 0; fi
  printf 'green\n'
}

# uberdev_goal_check_fingerprint_repeat GOAL_ID CYCLE FINGERPRINT
# Non-convergence detector: same fingerprint in cycle N-1 => repeat
# (return 1 → caller halts with goal_circuit_breaker reason=nonconvergence).
uberdev_goal_check_fingerprint_repeat() {
  local goal_id="$1" cycle="$2" fp="$3"
  _uberdev_goal_validate_int "$cycle" || return 2
  [ -n "$fp" ] || return 0
  local prev_cycle=$(( cycle - 1 ))
  [ "$prev_cycle" -lt 1 ] && { _persist_fp "$goal_id" "$cycle" "$fp"; return 0; }
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  if awk -v c="$prev_cycle" -v f="$fp" '$1==c && $2==f {found=1} END {exit !found}' \
       "$tmpdir/goal-$goal_id-fingerprints.tsv"; then
    return 1
  fi
  printf '%s\t%s\n' "$cycle" "$fp" >> "$tmpdir/goal-$goal_id-fingerprints.tsv"
}

# uberdev_goal_should_automerge GOAL_ID PR
# D8 + T5 — provenance check (UBERDEV_GOAL_ID env present) + attempt-count cap.
uberdev_goal_should_automerge() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_int "$pr" || return 1
  local attempts
  attempts="$(_uberdev_goal_count_merge_attempts "$goal_id" "$pr")"
  [ "$attempts" -lt "${_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS:-3}" ] || return 1
  # Provenance: caller must be inside /goal context (UBERDEV_GOAL_ID env set).
  [ -n "${UBERDEV_GOAL_ID:-}" ] || return 1
  return 0
}

# uberdev_goal_build_unblock_graph GOAL_ID
# Emit JSONL of {pr, blocking_issues[]} rows by listing all held PRs and
# parsing their `Blocks: #` lines via the anchored helper. Defers
# per-issue status query to _uberdev_goal_check_unblock.
uberdev_goal_build_unblock_graph() {
  local goal_id="$1"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local pr_states="$tmpdir/goal-$goal_id-pr-states.tsv"
  [ -f "$pr_states" ] || return 0
  # Latest transition wins per PR.
  awk '{state[$1]=$2} END {for (pr in state) if (state[pr]=="yellow-held" || state[pr]=="red-held") print pr}' "$pr_states" \
    | while read -r pr; do
        local body
        body="$(gh pr view "$pr" --json body --jq '.body' 2>/dev/null | head -c "${_UBERDEV_GOAL_BODY_CAP:-65536}")"
        local issues=()
        while IFS= read -r line; do
          local n; n="$(_uberdev_goal_parse_blocks_line "$line")"
          [ -n "$n" ] && issues+=("$n")
        done <<< "$body"
        local issues_json
        issues_json="$(printf '%s\n' "${issues[@]:-}" | jq -R . | jq -s .)"
        printf '{"pr":%s,"blocking_issues":%s}\n' "$pr" "$issues_json"
      done
}

# uberdev_goal_locate_review_pr_audit ISSUE_NUM
# Locate newest .claude/audit/review-pr-<PR>-<run>.json for the issue's PR.
# Returns empty string if none.
uberdev_goal_locate_review_pr_audit() {
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 1
  # Resolve PR number from solve-bg stdout marker.
  local pr
  pr="$(uberdev_goal_extract_pr_num_from_log "${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$issue.log")"
  [ -n "$pr" ] || return 0
  ls -t .claude/audit/review-pr-"$pr"-*.json 2>/dev/null | head -n 1
}

# uberdev_goal_extract_pr_num_from_log STDOUT_LOG_PATH
# Parse `pushed PR #N` marker from solve-bg stdout transcript.
uberdev_goal_extract_pr_num_from_log() {
  local log="$1"
  [ -f "$log" ] || return 0
  grep -oE 'pushed PR #[0-9]+' "$log" | head -n 1 | grep -oE '[0-9]+' || true
}

# uberdev_goal_list_prs_in_state GOAL_ID STATE
# Read goal-<id>-pr-states.tsv; latest transition wins per PR; echo
# newline-separated PR numbers matching STATE.
uberdev_goal_list_prs_in_state() {
  local goal_id="$1" want_state="$2"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-pr-states.tsv"
  [ -f "$f" ] || return 0
  awk -v s="$want_state" '{state[$1]=$2} END {for (pr in state) if (state[pr]==s) print pr}' "$f"
}

# uberdev_goal_read_merge_result PR_NUM
# Reads .claude/audit/merge-<PR>-<run>.json; echoes one of
# success | conflict | hook_failed.
uberdev_goal_read_merge_result() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local audit
  audit="$(ls -t .claude/audit/merge-"$pr"-*.json 2>/dev/null | head -n 1)"
  [ -n "$audit" ] && [ -f "$audit" ] || { printf 'missing\n'; return 0; }
  gh_jq_or_jq "$audit" '.result // "missing"' 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------------------
# Internal dispatch + unblock helpers (depend on lib/dispatch.sh's
# uberdev_dispatch_one — sourced by the goal-pipeline SKILL.md, not here).
# ---------------------------------------------------------------------------

# _uberdev_goal_dispatch_review_pr PR_NUM
# D18 — full re-review (no incremental mode); writes a one-line prompt file
# and dispatches via the standard small-tier path.
_uberdev_goal_dispatch_review_pr() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local prompt_file
  prompt_file="$(mktemp)"
  printf '/uberdev:review-pr %s\n' "$pr" > "$prompt_file"
  UBERDEV_GOAL_ID="${UBERDEV_GOAL_ID:-unknown}" \
    uberdev_dispatch_one "$pr" "small" "$prompt_file"
}

# _uberdev_goal_dispatch_merge PR_NUM
# T5 provenance (UBERDEV_GOAL_ID forwarded) + per-PR attempt counter
# (append-only TSV; count helper picks the latest row).
_uberdev_goal_dispatch_merge() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local prompt_file
  prompt_file="$(mktemp)"
  printf '/uberdev:merge %s\n' "$pr" > "$prompt_file"
  # Increment per-PR attempt counter.
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"
  local current; current="$(_uberdev_goal_count_merge_attempts "$goal_id" "$pr")"
  local next=$(( current + 1 ))
  # Append-only TSV; count helper picks the latest row.
  printf '%s\t%s\n' "$pr" "$next" \
    >> "$tmpdir/goal-$goal_id-merge-attempts.tsv"
  UBERDEV_GOAL_ID="$goal_id" \
    uberdev_dispatch_one "$pr" "small" "$prompt_file"
}

# _uberdev_goal_check_unblock HELD_PR_NUM
# RFC §3.2.3 unblock rule body: if every `Blocks: #N` issue is CLOSED, kick
# off a full /review-pr re-review for the held PR.
_uberdev_goal_check_unblock() {
  local held_pr="$1"
  _uberdev_goal_validate_int "$held_pr" || return 1
  local body
  body="$(gh pr view "$held_pr" --json body --jq '.body' 2>/dev/null | head -c "${_UBERDEV_GOAL_BODY_CAP:-65536}")"
  local blocking=()
  while IFS= read -r line; do
    local n; n="$(_uberdev_goal_parse_blocks_line "$line")"
    [ -n "$n" ] && blocking+=("$n")
  done <<< "$body"
  [ "${#blocking[@]}" -gt 0 ] || return 0
  local all_closed=1
  for i in "${blocking[@]}"; do
    local state
    state="$(gh issue view "$i" --json state --jq '.state' 2>/dev/null || echo OPEN)"
    [ "$state" = "CLOSED" ] || { all_closed=0; break; }
  done
  if [ "$all_closed" = "1" ]; then
    _uberdev_goal_dispatch_review_pr "$held_pr"
    # Join blocking[] with commas WITHOUT mutating IFS (semgrep CWE-20):
    # printf one element per line, then paste -sd, collapses to CSV.
    local blocking_csv
    blocking_csv="$(printf '%s\n' "${blocking[@]}" | paste -sd, -)"
    uberdev_goal_audit goal_unblock_triggered \
      "{\"pr\":$held_pr,\"blocking_issues\":[$blocking_csv]}"
  fi
}
