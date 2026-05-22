# plugins/uberdev/lib/goal-state.sh
#
# Per-goal state machine + audit sink for /uberdev:goal (RFC 0005).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_goal_state_init                    GOAL_ID
#   uberdev_goal_pr_state_transition           GOAL_ID PR FROM TO
#   uberdev_goal_issue_state_transition        GOAL_ID ISSUE FROM TO
#   uberdev_goal_read_trust_signal             AUDIT_JSON_PATH
#   uberdev_goal_check_fingerprint_repeat      GOAL_ID CYCLE FINGERPRINT
#   uberdev_goal_should_automerge              GOAL_ID PR
#   uberdev_goal_audit                         EVENT PAYLOAD_JSON
#   uberdev_goal_locate_review_pr_audit        ISSUE_NUM
#   uberdev_goal_locate_review_pr_audit_by_pr  PR_NUM
#   uberdev_goal_get_pr_state                  GOAL_ID PR
#   uberdev_goal_record_held_audit             GOAL_ID PR AUDIT_PATH
#   uberdev_goal_get_last_held_audit           GOAL_ID PR
#   uberdev_goal_extract_pr_num_from_log       STDOUT_LOG_PATH
#   uberdev_goal_list_prs_in_state             GOAL_ID STATE
#   uberdev_goal_read_merge_result             PR_NUM
#   uberdev_goal_write_run_state               (env-driven)
#   uberdev_goal_read_run_state                (env-driven)
#   uberdev_goal_cleanup_run_state             (env-driven)
# Internal:
#   _uberdev_goal_validate_int             N
#   _uberdev_goal_validate_id              GOAL_ID
#   _uberdev_goal_append                   FILE LINE
#   _uberdev_goal_extract_fingerprint      BODY_TEXT
#   _uberdev_goal_parse_blocks_line        LINE
#   _uberdev_goal_count_merge_attempts     GOAL_ID PR
#   _uberdev_goal_count_review_pr_attempts GOAL_ID PR
#   _uberdev_goal_pr_state_machine_valid   FROM TO
#   _uberdev_goal_now_secs
#   _uberdev_goal_persist_fp               GOAL_ID CYCLE FP
#   _uberdev_goal_fetch_pr_body            PR_NUM
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
# added; the audit/trust-signal call sites take local file paths (not gh API
# output), so plain `jq` is the correct underlying tool.
#
# Failure mode: jq errors (malformed JSON, missing filter target) are
# surfaced to stderr as a single audit-friendly warning line, then the
# function returns rc=1 (B5). Callers MUST branch on exit code rather than
# treating empty-stdout as success — masking jq failure as rc=0 let a
# corrupted audit JSON fall through to the "phase2_5 missing" path and
# silently misclassified the trust signal. Stdout stays empty on failure
# so the legacy `[ -n "$out" ]` predicates also still fail closed; the
# exit-code change is additive.
gh_jq_or_jq() {
  local file="$1" filter="$2"
  [ -n "$file" ] && [ -f "$file" ] || return 1
  local jq_err jq_rc
  # B4 — fallback arm: if mktemp fails (read-only /tmp, exhausted inode
  # table, etc.) we cannot capture stderr to a file, so run jq with stderr
  # discarded BUT explicitly capture its rc and return it. Previously the
  # fallback `return` echoed the implicit rc of the prior command, which
  # happened to be jq's own rc, but only because no intervening commands
  # mutated $?. Making the capture explicit is defence in depth — and it
  # preserves the audit-contract guarantee (callers branch on rc) even
  # when the warning-line breadcrumb is unavailable.
  jq_err="$(mktemp 2>/dev/null)" || {
    jq -r "$filter" "$file" 2>/dev/null
    jq_rc=$?
    return "$jq_rc"
  }
  if ! jq -r "$filter" "$file" 2>"$jq_err"; then
    local first_line
    first_line="$(head -n 1 "$jq_err" 2>/dev/null)"
    printf 'goal-state: jq failed on %s: %s\n' "$file" "${first_line:-unknown error}" >&2
    rm -f "$jq_err"
    return 1
  fi
  rm -f "$jq_err"
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

# _uberdev_goal_validate_id GOAL_ID
# #156 — path-traversal defense-in-depth. goal_id is interpolated into the
# per-goal state filenames ($tmpdir/goal-<id>-*.tsv|jsonl); an id containing a
# path separator or `..` could escape $UBERDEV_TMPDIR. Constrain to a safe slug
# (mirrors the _uberdev_goal_validate_int guard pr/issue/cycle already use).
# goal_id is internally generated (D4) so a real id is never rejected — this
# closes the theoretical traversal vector a forged/compromised id would open.
_uberdev_goal_validate_id() {
  local id="$1"
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;  # empty or any non-slug char (incl. `/`)
    *..*) return 1 ;;                  # belt-and-braces: reject `..` sequence
    *) return 0 ;;
  esac
}

# _uberdev_goal_now_secs (POSIX)
_uberdev_goal_now_secs() { date +%s; }

# _uberdev_goal_append FILE LINE
# #157 — surface unwritable-$UBERDEV_TMPDIR failures. The bare `>> "$f"`
# appends below returned the rc of the *next* statement (or rc=0 when the
# append was a function's last line), so a read-only-but-existing tmpdir —
# which slips past uberdev_goal_state_init's `mkdir -p` success check —
# silently dropped state rows while the writer reported success. Centralise
# the append + rc-check + diagnostic so every state-stream writer fails loud;
# callers propagate the failure with `|| return`.
_uberdev_goal_append() {
  local file="$1" line="$2"
  if ! printf '%s\n' "$line" >> "$file"; then
    printf 'goal-state: append to %s failed (unwritable UBERDEV_TMPDIR?)\n' "$file" >&2
    return 1
  fi
}

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
    "yellow-held->red-held") return 0 ;; # re-review escalates severity (#159)
    "red-held->yellow-held") return 0 ;; # re-review downgrades severity (#159)
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

# _uberdev_goal_count_review_pr_attempts GOAL_ID PR
# B3 bound — sibling of _uberdev_goal_count_merge_attempts; reads
# goal-<id>-review-pr-attempts.tsv (TSV row PR_NUM\tCOUNT) and echoes the
# latest integer count for given PR (0 if absent). Append-only writes from
# _uberdev_goal_dispatch_review_pr below; cap enforced by the same helper
# at ${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3}. The cap bounds the Phase
# 2a stale|missing re-dispatch loop (SKILL.md line 280-283) so the watch
# loop's 60s cadence cannot fire >3 /review-pr dispatches per PR over the
# 4h stuck_loop window (was unbounded at 240/PR).
_uberdev_goal_count_review_pr_attempts() {
  local goal_id="$1" pr="$2"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-review-pr-attempts.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -v p="$pr" '$1==p {c=$2} END {print c+0}' "$f"
}

# _uberdev_goal_persist_fp GOAL_ID CYCLE FP
# Persist a (cycle, fingerprint) pair to the fingerprints TSV — the
# repeat-cycle detector reads this stream to decide non-convergence.
# M17 — intent-first framing. Naming history (the dropped short alias
# `_persist_fp` from post-impl-review S4) was removed; the project
# convention `_uberdev_goal_*` is documented at the top-level surface
# section, not here.
_uberdev_goal_persist_fp() {
  local goal_id="$1" cycle="$2" fp="$3"
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local row; printf -v row '%s\t%s' "$cycle" "$fp"
  # Source-of-truth write for the non-convergence fingerprint stream — propagate
  # append failure explicitly (uniform with the two state-transition writers).
  _uberdev_goal_append "$tmpdir/goal-$goal_id-fingerprints.tsv" "$row" || return 1
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

# uberdev_goal_state_init GOAL_ID
# D4 + T4 — Refuse unsafe $UBERDEV_TMPDIR; truncate-create the 5 per-goal
# state files (jsonl + 4 TSVs).
uberdev_goal_state_init() {
  local goal_id="$1"
  # #156 — refuse an unsafe goal_id before it reaches any path interpolation.
  _uberdev_goal_validate_id "$goal_id" || {
    printf 'goal-state: refusing unsafe goal_id: %s\n' "$goal_id" >&2
    return 1
  }
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  case "$tmpdir" in
    *[!A-Za-z0-9_./-]*)
      printf 'goal-state: refusing unsafe UBERDEV_TMPDIR: %s\n' "$tmpdir" >&2
      return 1 ;;
  esac
  # M13 — drop the `|| true` mask. If mkdir -p genuinely fails (read-only
  # filesystem, permissions, exhausted inode table) surface the rc here so the
  # operator sees the underlying cause (mkdir's own stderr) and the goal halts
  # early. The truncate-creates below are individually rc-checked (#157).
  if ! mkdir -p "$tmpdir" 2>/dev/null; then
    printf 'goal-state: mkdir -p %s failed; refusing to init state\n' "$tmpdir" >&2
    return 1
  fi
  # #157 — rc-check every truncate-create. A read-only-but-existing $tmpdir
  # passes the mkdir -p above (the dir already exists) yet cannot accept new
  # files; the bare `: > "$f"` writes used to fail one-by-one with raw
  # "Permission denied" noise and a confusing partial-state. Fail fast on the
  # first unwritable file with a clean diagnostic. The 7 state files:
  #   jsonl                  — per-goal audit stream
  #   pr-states.tsv          — PR state-machine transitions
  #   issue-states.tsv       — issue state-machine transitions
  #   fingerprints.tsv       — non-convergence fingerprint stream
  #   merge-attempts.tsv     — per-PR /merge attempt counter
  #   review-pr-attempts.tsv — per-PR /review-pr re-dispatch counter (B3 bound,
  #                            bounds Phase 2a's stale|missing re-dispatch loop)
  #   held-audits.tsv        — last re-review audit consumed per held PR (2e);
  #                            latest row per pr wins (get_last_held_audit tail)
  local f
  for f in "$tmpdir/goal-$goal_id.jsonl" \
           "$tmpdir/goal-$goal_id-pr-states.tsv" \
           "$tmpdir/goal-$goal_id-issue-states.tsv" \
           "$tmpdir/goal-$goal_id-fingerprints.tsv" \
           "$tmpdir/goal-$goal_id-merge-attempts.tsv" \
           "$tmpdir/goal-$goal_id-review-pr-attempts.tsv" \
           "$tmpdir/goal-$goal_id-held-audits.tsv"; do
    if ! : > "$f"; then
      printf 'goal-state: cannot create state file %s (unwritable UBERDEV_TMPDIR?)\n' "$f" >&2
      return 1
    fi
  done
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
  # #156 — validate the env-derived goal_id before pathing the jsonl. A forged
  # UBERDEV_GOAL_ID degrades to the safe `unknown` sink (with a breadcrumb)
  # rather than escaping tmpdir; audit must not abort the state machine.
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"
  _uberdev_goal_validate_id "$goal_id" || {
    printf 'goal-state: unsafe UBERDEV_GOAL_ID %s; auditing to goal-unknown.jsonl\n' "$goal_id" >&2
    goal_id="unknown"
  }
  local ts; ts="$(date -u +%FT%TZ 2>/dev/null || date +%s)"
  local line; printf -v line '{"ts":"%s","event":"%s","payload":%s}' "$ts" "$event" "$payload"
  # Best-effort telemetry sink: the append's rc propagates (last statement) and
  # any write failure is surfaced to stderr by _uberdev_goal_append, but callers
  # intentionally do NOT gate the state machine on audit durability — see
  # uberdev_goal_pr_state_transition's `|| true`.
  _uberdev_goal_append "$tmpdir/goal-$goal_id.jsonl" "$line"
}

# uberdev_goal_pr_state_transition GOAL_ID PR FROM TO
# Validate + append + audit.
uberdev_goal_pr_state_transition() {
  local goal_id="$1" pr="$2" from="$3" to="$4"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  _uberdev_goal_pr_state_machine_valid "$from" "$to" || {
    printf 'goal-state: invalid PR transition %s->%s\n' "$from" "$to" >&2
    return 2
  }
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  # #157 — propagate a failed state-row write instead of letting the trailing
  # audit call's rc mask it (this row is the PR machine's source of truth).
  local row; printf -v row '%s\t%s\t%s' "$pr" "$to" "$(_uberdev_goal_now_secs)"
  _uberdev_goal_append "$tmpdir/goal-$goal_id-pr-states.tsv" "$row" || return 1
  # The state-row above is the PR machine's source of truth; the audit jsonl is
  # best-effort telemetry. uberdev_goal_audit surfaces its own write failures to
  # stderr, but a telemetry-write failure must NOT report a transition whose
  # state-row already persisted as failed — so swallow audit's rc here and let
  # this function's rc reflect the source-of-truth write.
  uberdev_goal_audit goal_pr_transition \
    "{\"goal_id\":\"$goal_id\",\"pr\":$pr,\"from\":\"$from\",\"to\":\"$to\"}" || true
}

# uberdev_goal_issue_state_transition GOAL_ID ISSUE FROM TO
# D2 issue machine: input → solving → pr-pushed → resolved; solving → failed
# and pr-pushed → failed allowed. No audit event (issue transitions are
# derived state; audit covers PR transitions + cycle boundaries).
uberdev_goal_issue_state_transition() {
  local goal_id="$1" issue="$2" from="$3" to="$4"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$issue" || return 1
  case "$from->$to" in
    "input->solving"|"solving->pr-pushed"|"pr-pushed->resolved"|"solving->failed"|"pr-pushed->failed") ;;
    *) printf 'goal-state: invalid issue transition %s->%s\n' "$from" "$to" >&2; return 2 ;;
  esac
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local row; printf -v row '%s\t%s\t%s' "$issue" "$to" "$(_uberdev_goal_now_secs)"
  # Source-of-truth write for the issue machine. The append's rc already
  # propagates (it is the last statement), but the explicit `|| return 1`
  # documents that contract and future-proofs against a later trailing
  # statement silently masking the failure — the exact class
  # uberdev_goal_pr_state_transition hit before #157. (#157)
  _uberdev_goal_append "$tmpdir/goal-$goal_id-issue-states.tsv" "$row" || return 1
}

# uberdev_goal_read_trust_signal AUDIT_JSON_PATH
# D17 — GREEN/YELLOW/RED/STALE/MISSING from /review-pr Phase 2.5 audit.
# B5 — explicit branch on gh_jq_or_jq exit code: jq-failure (rc!=0) means
# the audit JSON is unreadable (malformed / not JSON); treat as `missing`
# so the caller re-dispatches /review-pr (the only safe action — never
# assume GREEN on an unreadable trust artifact, per D17). Empty stdout
# with rc=0 means jq ran but returned empty (phase2_5 absent) — that's
# the legacy/pre-v0.26.0 audit shape, treated as `stale`.
uberdev_goal_read_trust_signal() {
  local audit_path="$1"
  [ -f "$audit_path" ] || { printf 'missing\n'; return 0; }
  local p25
  if ! p25="$(gh_jq_or_jq "$audit_path" '.phases.phase2_5 // empty')"; then
    printf 'missing\n'; return 0
  fi
  [ -n "$p25" ] || { printf 'stale\n'; return 0; }
  # Single jq pass emits blocker\tcritical\thalted as TSV; bash `read` splits
  # into three locals in one syscall (3 jq forks -> 1; F1 simplify-lens). The
  # `// 0` and `// false` defaults preserve the prior shape-tolerance for
  # audit JSONs missing either by_severity counter or the halted field.
  #
  # B5 defense-in-depth: capture the jq pipeline's rc into a separate
  # assignment so a structural type error (e.g. by_severity is a string
  # instead of an object — the `// 0` default cannot rescue indexing into
  # a string) is treated as "missing" rather than silently fall through.
  # Inlining the substitution into `read -r <<<"$(...)"` would discard
  # the rc; without this branch, malformed phase2_5 → empty TSV → empty
  # blocker/critical/halted vars → fall-through to "green" (the exact
  # YELLOW->GREEN misclassification path issue #137 was filed against).
  #
  # Audit parity (S4): this second pass operates on the in-memory $p25
  # string, so it cannot route through the gh_jq_or_jq shim (which takes a
  # FILE path). Instead, mirror that shim's breadcrumb directly — but the
  # success path stays a clean in-memory capture (no temp file): run jq with
  # stderr discarded and read its rc. ONLY on the failure path (about to
  # return `missing` anyway) re-run jq capturing stderr in-memory and emit
  # one audit-friendly warning line, so a structural type error leaves an
  # operator trail rather than vanishing. Behaviour is unchanged: rc!=0
  # still maps to `missing` (BT20-locked); the warning is stderr-only and
  # additive.
  #
  # M16 — jq filter projects three fields as a single tab-separated row so
  # the downstream bash `read -r blocker critical halted` consumes them in
  # one syscall instead of three separate jq forks. The `// 0` and
  # `// false` defaults preserve shape-tolerance on audit JSON that omits
  # either `by_severity` counters or the `halted` field.
  local jq_filter='[.by_severity.blocker // 0, .by_severity.critical // 0, (.halted // false | tostring)] | @tsv'
  local tsv jq_rc
  tsv="$(jq -r "$jq_filter" <<<"$p25" 2>/dev/null)"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    local jq_err first_line
    jq_err="$(jq -r "$jq_filter" <<<"$p25" 2>&1 1>/dev/null)"
    first_line="${jq_err%%$'\n'*}"
    printf 'goal-state: jq failed on phase2_5 by_severity projection: %s\n' \
      "${first_line:-unknown error}" >&2
    printf 'missing\n'; return 0
  fi
  local blocker critical halted
  read -r blocker critical halted <<<"$tsv"
  if [ "$halted" = "true" ] || [ "$blocker" -gt 0 ]; then printf 'red\n'; return 0; fi
  if [ "$critical" -gt 0 ]; then printf 'yellow\n'; return 0; fi
  printf 'green\n'
}

# uberdev_goal_check_fingerprint_repeat GOAL_ID CYCLE FINGERPRINT
# Non-convergence detector: same fingerprint in cycle N-1 => repeat
# (return 1 → caller halts with goal_circuit_breaker reason=nonconvergence).
uberdev_goal_check_fingerprint_repeat() {
  local goal_id="$1" cycle="$2" fp="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$cycle" || return 2
  [ -n "$fp" ] || return 0
  local prev_cycle=$(( cycle - 1 ))
  [ "$prev_cycle" -lt 1 ] && { _uberdev_goal_persist_fp "$goal_id" "$cycle" "$fp"; return 0; }
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  if awk -v c="$prev_cycle" -v f="$fp" '$1==c && $2==f {found=1} END {exit !found}' \
       "$tmpdir/goal-$goal_id-fingerprints.tsv"; then
    return 1
  fi
  # M8 — DRY: use the canonical helper instead of inlining the printf. The
  # cycle-1 short-circuit branch above already calls _uberdev_goal_persist_fp;
  # this branch did the same write inline. Single source of truth means a future
  # change to the TSV row shape only needs to land in the helper.
  _uberdev_goal_persist_fp "$goal_id" "$cycle" "$fp"
}

# uberdev_goal_should_automerge GOAL_ID PR
# D8 + T5 — provenance check (UBERDEV_GOAL_ID env present) + attempt-count cap.
uberdev_goal_should_automerge() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local attempts
  attempts="$(_uberdev_goal_count_merge_attempts "$goal_id" "$pr")"
  [ "$attempts" -lt "${_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS:-3}" ] || return 1
  # Provenance: caller must be inside /goal context (UBERDEV_GOAL_ID env set).
  [ -n "${UBERDEV_GOAL_ID:-}" ] || return 1
  return 0
}

# uberdev_goal_locate_review_pr_audit ISSUE_NUM
# Locate newest .uberdev/runs/<run-id>/review-pr-verdict.json (canonical) or
# worktree-mirror equivalent for the issue's PR. Mirrors merge-pipeline/SKILL.md
# Phase 1.4 PATH_2 sub-condition (c.0): four glob patterns total — the
# canonical `.uberdev/runs/*` path plus three additional worktree-mirror
# layouts (/solve and /turbo write `.claude/worktrees/*/.uberdev/` per
# solve-pipeline/SKILL.md; using-git-worktrees emits hidden `.worktrees/*`
# and visible `worktrees/*` layouts). Filters by top-level `.pr == $pr_num`,
# validates each `<run-id>` against RUN_ID_REGEX before any path concatenation
# (D4/F8 path-traversal hardening — basename-of-dirname projection is path-
# layout-agnostic because prefix segments are never concatenated from untrusted
# input), and picks the lex-greatest `<run-id>` (chronologically newest;
# `YYYYMMDD-HHMMSS-<short-sha>` lex-sorts identically). Returns empty string
# when no match. The legacy `.claude/audit/review-pr-<PR>-<run>.json` path is
# never written by /review-pr — reading it (the pre-B1 behavior) silently
# returned "missing" forever, blocking the goal-pipeline from ever picking up
# the trust signal.
uberdev_goal_locate_review_pr_audit() {
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 1
  # Resolve PR number from solve-bg stdout marker, then delegate to the
  # PR-keyed locator. The same `.pr == $pr` filter + lex-greatest-run_id
  # tiebreak lives in one place now (was duplicated before the held-PR
  # poll loop landed — see uberdev_goal_locate_review_pr_audit_by_pr).
  local pr
  pr="$(uberdev_goal_extract_pr_num_from_log "${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$issue.log")"
  [ -n "$pr" ] || return 0
  _uberdev_goal_validate_int "$pr" || return 0
  uberdev_goal_locate_review_pr_audit_by_pr "$pr"
}

# uberdev_goal_locate_review_pr_audit_by_pr PR_NUM
# PR-keyed companion to uberdev_goal_locate_review_pr_audit. Used by the
# held-PR re-review poll loop (Phase 2 step 2e) which already has the PR
# number in hand and bypasses the issue→PR resolution. Same glob set, same
# filter (`.pr == $pr`), same lex-greatest run_id tiebreak (newest wins
# because YYYYMMDD-HHMMSS-<sha> sorts identically to chronological order).
# Returns the relative path to the audit JSON or empty when no match.
uberdev_goal_locate_review_pr_audit_by_pr() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local candidate_file run_id pr_field
  for candidate_file in .uberdev/runs/*/review-pr-verdict.json \
           .claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json \
           .worktrees/*/.uberdev/runs/*/review-pr-verdict.json \
           worktrees/*/.uberdev/runs/*/review-pr-verdict.json; do
    [ -r "$candidate_file" ] || continue
    pr_field="$(jq -r '.pr // empty' "$candidate_file" 2>/dev/null)" || continue
    [ "$pr_field" = "$pr" ] || continue
    run_id="$(basename "$(dirname "$candidate_file")")"
    [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] || continue
    printf '%s\t%s\n' "$run_id" "$candidate_file"
  done | sort -r | head -n 1 | cut -f2
}

# uberdev_goal_get_pr_state GOAL_ID PR
# Latest-transition lookup: read goal-<id>-pr-states.tsv, return the most
# recent state recorded for PR. Empty string when no row exists (PR has
# never been transitioned). Used by Phase 2 step 2e to determine the
# `from` arg for state transitions on held PRs whose re-review trust
# signal changed.
uberdev_goal_get_pr_state() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-pr-states.tsv"
  [ -f "$f" ] || return 0
  awk -v p="$pr" '$1==p {state=$2} END {print state}' "$f"
}

# uberdev_goal_record_held_audit GOAL_ID PR AUDIT_PATH
# Append-only TSV write recording the audit path the held-PR poll loop
# has consumed for PR. Subsequent reads via uberdev_goal_get_last_held_audit
# pick the tail entry per PR; a different path on the next poll means a
# new re-review fired and the poll loop should act on it.
uberdev_goal_record_held_audit() {
  local goal_id="$1" pr="$2" audit_path="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local row; printf -v row '%s\t%s' "$pr" "$audit_path"
  _uberdev_goal_append "$tmpdir/goal-$goal_id-held-audits.tsv" "$row"   # #157
}

# uberdev_goal_get_last_held_audit GOAL_ID PR
# Latest-row lookup in goal-<id>-held-audits.tsv per PR. Returns empty
# string when no row exists (the held PR has not been polled yet, or the
# TSV does not exist). Caller compares against the live locate result to
# decide whether a re-review has fired since the last poll.
uberdev_goal_get_last_held_audit() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-held-audits.tsv"
  [ -f "$f" ] || return 0
  awk -v p="$pr" '$1==p {path=$2} END {print path}' "$f"
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
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-pr-states.tsv"
  [ -f "$f" ] || return 0
  awk -v s="$want_state" '{state[$1]=$2} END {for (pr in state) if (state[pr]==s) print pr}' "$f"
}

# uberdev_goal_read_merge_result PR_NUM
# Reads the canonical `.uberdev/audit.jsonl` JSONL stream written by every
# merge-pipeline phase (see merge-pipeline/SKILL.md §"Audit log JSONL schema"
# (D15) — `AUDIT_LOG_FILENAME='audit.jsonl'`). Filters rows by
# `.event ∈ {merge_executed, pr_parked}` AND `.data.pr == $pr`, takes the
# most recent (last appended line). Maps the merge-pipeline's PARK_REASON_ENUM
# + merge_executed semantics onto goal-pipeline's tri-state result:
#   - `merge_executed`                                    -> success
#   - `pr_parked` with data.reason ∈ {refused, ambiguous, push-non-ff}
#                                                         -> conflict
#   - `pr_parked` with data.reason == test-fail-exhausted -> hook_failed
#   - no matching row                                     -> missing
# The legacy `.claude/audit/merge-<PR>-<run>.json` path is never written by
# /merge — reading it (the pre-B2 behavior) silently returned "missing"
# forever, which then fell through to no PR transition in Phase 2c and the
# goal would never converge.
uberdev_goal_read_merge_result() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local audit=".uberdev/audit.jsonl"
  [ -f "$audit" ] || { printf 'missing\n'; return 0; }
  # Pick the LAST matching JSONL line (most recent). Use a single jq pass
  # to project `event\treason` for the final matching row; gh_jq_or_jq's
  # `-r` mode + file argument is the wrong tool here (audit.jsonl is JSONL,
  # not a single JSON document), so call jq directly with `--slurp` to
  # treat the stream as an array.
  local row
  row="$(jq -r --argjson pr "$pr" \
    '[.[] | select(.event=="merge_executed" or .event=="pr_parked") | select(.data.pr == $pr) | {event,reason:(.data.reason // "")}] | last | if . == null then "" else "\(.event)\t\(.reason)" end' \
    --slurp "$audit" 2>/dev/null)"
  [ -n "$row" ] || { printf 'missing\n'; return 0; }
  local event="${row%%	*}" reason="${row#*	}"
  case "$event" in
    merge_executed)
      printf 'success\n' ;;
    pr_parked)
      case "$reason" in
        refused|ambiguous|push-non-ff) printf 'conflict\n' ;;
        test-fail-exhausted)           printf 'hook_failed\n' ;;
        *)                             printf 'missing\n' ;;
      esac ;;
    *)
      printf 'missing\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Internal dispatch + unblock helpers (depend on lib/dispatch.sh's
# uberdev_dispatch_one — sourced by the goal-pipeline SKILL.md, not here).
# ---------------------------------------------------------------------------

# _uberdev_goal_dispatch_review_pr PR_NUM
# D18 — full re-review (no incremental mode); writes a one-line prompt file
# and dispatches via the standard small-tier path.
#
# B3 bound — per-PR attempt cap at ${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3}.
# Step 2a's stale|missing arm (SKILL.md line 280-283) calls this every 60s
# while a PR sits in pushed-reviewing with a missing/stale audit; the cap
# bounds total dispatches per PR across the entire goal run (worst case
# was 240/PR over the 4h stuck_loop window — now 3/PR). On cap-exceeded:
# print a stderr warning and return rc=0 so the step 2a loop continues
# normally (the PR stays in its current state; subsequent watch iterations
# skip re-dispatch via the same cap check). Intentionally NOT a circuit
# breaker — the goal continues toward convergence and the cap does NOT
# halt the goal. The merge-attempts pattern (uberdev_goal_should_automerge
# at line 367) inspires the helper structure but the semantics differ:
# merge-attempts gates a transition to `merging`; review-pr-attempts skips
# a dispatch in-place.
_uberdev_goal_dispatch_review_pr() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"
  # #156 — refuse a forged provenance id rather than pathing a counter TSV with it.
  _uberdev_goal_validate_id "$goal_id" || {
    printf 'goal-state: unsafe UBERDEV_GOAL_ID %s; refusing review-pr dispatch for PR #%s\n' "$goal_id" "$pr" >&2
    return 1
  }
  local current; current="$(_uberdev_goal_count_review_pr_attempts "$goal_id" "$pr")"
  local cap="${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3}"
  if [ "$current" -ge "$cap" ]; then
    printf 'goal-pipeline: review-pr dispatch cap reached for PR #%s (cap=%s); skipping re-dispatch this cycle\n' \
      "$pr" "$cap" >&2
    return 0
  fi
  local prompt_file
  # B5 — mktemp failure (read-only /tmp, exhausted inode table) used to fall
  # through silently: $prompt_file ended up empty, the printf to "" was a
  # no-op, and uberdev_dispatch_one received an invalid path. The goal then
  # appeared to dispatch but no agent actually spawned, blocking convergence
  # until 4h stuck_loop fired. Now: rc-check on mktemp and surface the
  # failure to stderr + return non-zero so the caller can fall back.
  if ! prompt_file="$(mktemp 2>/dev/null)"; then
    printf 'goal-state: mktemp failed in _uberdev_goal_dispatch_review_pr (PR %s)\n' "$pr" >&2
    return 1
  fi
  printf '/uberdev:review-pr %s\n' "$pr" > "$prompt_file"
  # Increment per-PR attempt counter (append-only TSV mirrors the
  # merge-attempts pattern at _uberdev_goal_dispatch_merge below).
  local next=$(( current + 1 ))
  # #157 — fail closed: if the attempt-counter write fails, do NOT dispatch (an
  # unrecorded attempt would defeat the per-PR cap and risk a re-dispatch
  # storm). Surface + return non-zero so the caller retries next cycle.
  local row; printf -v row '%s\t%s' "$pr" "$next"
  _uberdev_goal_append "$tmpdir/goal-$goal_id-review-pr-attempts.tsv" "$row" || return 1
  UBERDEV_GOAL_ID="$goal_id" \
    uberdev_dispatch_one "$pr" "small" "$prompt_file"
}

# _uberdev_goal_dispatch_merge PR_NUM
# T5 provenance (UBERDEV_GOAL_ID forwarded) + per-PR attempt counter
# (append-only TSV; count helper picks the latest row).
_uberdev_goal_dispatch_merge() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local prompt_file
  # B5 — same rc-check pattern as _uberdev_goal_dispatch_review_pr above.
  # Without this, a silent mktemp failure (read-only /tmp, exhausted inode
  # table) propagates an empty prompt_file path into uberdev_dispatch_one
  # and the merge agent never spawns. Phase 2b's caller (SKILL.md step 2b)
  # was already updated post-B2 to branch on this function's rc; surface a
  # non-zero return on dispatch-helper failure so it stays in `green` for
  # the next cycle's retry (bounded by the per-PR attempt counter cap).
  if ! prompt_file="$(mktemp 2>/dev/null)"; then
    printf 'goal-state: mktemp failed in _uberdev_goal_dispatch_merge (PR %s)\n' "$pr" >&2
    return 1
  fi
  printf '/uberdev:merge %s\n' "$pr" > "$prompt_file"
  # Increment per-PR attempt counter.
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"
  # #156 — refuse a forged provenance id rather than pathing a counter TSV with it.
  _uberdev_goal_validate_id "$goal_id" || {
    printf 'goal-state: unsafe UBERDEV_GOAL_ID %s; refusing merge dispatch for PR #%s\n' "$goal_id" "$pr" >&2
    return 1
  }
  local current; current="$(_uberdev_goal_count_merge_attempts "$goal_id" "$pr")"
  local next=$(( current + 1 ))
  # #157 — fail closed: an unrecorded merge attempt would defeat the per-PR
  # attempt cap; surface + return non-zero (caller retries next cycle) rather
  # than dispatching with a lost counter row. Append-only TSV; count helper
  # picks the latest row.
  local row; printf -v row '%s\t%s' "$pr" "$next"
  _uberdev_goal_append "$tmpdir/goal-$goal_id-merge-attempts.tsv" "$row" || return 1
  UBERDEV_GOAL_ID="$goal_id" \
    uberdev_dispatch_one "$pr" "small" "$prompt_file"
}

# _uberdev_goal_fetch_pr_body PR_NUM
# Centralized PR-body fetch + 64KiB cap (F17 simplify-lens). The cap is the
# load-bearing ReDoS defence (R1 / T1) — capping the gh-returned body before
# any regex-parse loop bounds parse cost on a hostile PR description. Three
# call sites previously duplicated this gh + head pipeline; this helper is
# the single source of truth.
#
# Returns the (possibly capped) body on stdout; empty string when gh fails
# or the PR has no body. Callers branch on `[ -n "$body" ]`.
_uberdev_goal_fetch_pr_body() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  gh pr view "$pr" --json body --jq '.body' 2>/dev/null \
    | head -c "${_UBERDEV_GOAL_BODY_CAP:-65536}"
}

# _uberdev_goal_check_unblock HELD_PR_NUM
# RFC §3.2.3 unblock rule body: if every `Blocks: #N` issue is CLOSED, kick
# off a full /review-pr re-review for the held PR.
_uberdev_goal_check_unblock() {
  local held_pr="$1"
  _uberdev_goal_validate_int "$held_pr" || return 1
  local body
  body="$(_uberdev_goal_fetch_pr_body "$held_pr")"
  # B10 — Surface gh pr view failures (rate-limited, transient network,
  # PR deleted upstream) instead of silently treating empty body as "no
  # Blocks: lines" — that would let a held PR sit forever waiting for an
  # unblock check that will never succeed. Skip this iteration; the
  # next merged-PR transition will re-run the check.
  [ -n "$body" ] || {
    printf 'goal-state: gh pr view %s returned empty body; skipping unblock check this cycle\n' "$held_pr" >&2
    return 0
  }
  local blocking=()
  while IFS= read -r line; do
    local n; n="$(_uberdev_goal_parse_blocks_line "$line")"
    [ -n "$n" ] && blocking+=("$n")
  done <<< "$body"
  [ "${#blocking[@]}" -gt 0 ] || return 0
  local all_closed=1
  for i in "${blocking[@]}"; do
    # B11 — Distinguish "issue 404 (deleted upstream)" from other gh
    # failures. The old `… || echo OPEN` fallback treated every error
    # (rate-limit, network, 404) as OPEN, so a deleted blocking issue
    # would permanently hold the PR. Now: 404 -> CLOSED (the only
    # interpretation that makes the unblock proceed); other errors ->
    # skip the unblock check and retry next cycle (do NOT assume any
    # state).
    local state issue_raw issue_rc
    issue_raw="$(gh issue view "$i" --json state --jq '.state' 2>&1)"
    issue_rc=$?
    if [ "$issue_rc" -ne 0 ]; then
      if printf '%s' "$issue_raw" | grep -q 'Could not resolve to an Issue'; then
        state="CLOSED"
      else
        printf 'goal-state: gh issue view %s failed (rc=%s): %s\n' \
          "$i" "$issue_rc" "$issue_raw" >&2
        return 0
      fi
    else
      state="$issue_raw"
    fi
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

# ---------------------------------------------------------------------------
# Run-state sidecar (issue #171): persist the GOAL_ID pointer + loop
# accumulators so they survive fresh-shell Bash boundaries. KEY=value text,
# written atomically via the #155 TOCTOU-safe helper. The reader parses +
# per-field-validates the sidecar — it is never sourced or executed as code;
# NEVER mapfile (bash-3.2/zsh portability).
# ---------------------------------------------------------------------------

# uberdev_goal_write_run_state
#   Reads GOAL_ID, cycle, watch_start, overflow_count, overflow_detected,
#   MAX_CYCLES, UBERDEV_RESOLVED_BACKEND, and the queue/active_issues arrays
#   from the caller's shell; persists them to predictable, GOAL_ID-keyed
#   sidecars under $UBERDEV_TMPDIR. Returns 0 on success, 3 (fail-CLOSED) if
#   _uberdev_dispatch_prepare_tmp_target rejects any target.
uberdev_goal_write_run_state() {
  _uberdev_goal_validate_id "${GOAL_ID:-}" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local sc="$tmpdir/goal-$GOAL_ID-runstate"   # NO .env extension

  # Scalar sidecar: prepare predictable target (symlink-reject + EUID-owner
  # check + 0600-create under set -C), write temp sibling, atomic mv.
  _uberdev_dispatch_prepare_tmp_target "$sc" 0 "goal" || return 3
  local tmp
  tmp="$(mktemp "${sc}.XXXXXXXX")" || return 3
  printf 'GOAL_ID=%s\ncycle=%s\nwatch_start=%s\noverflow_count=%s\noverflow_detected=%s\nMAX_CYCLES=%s\nUBERDEV_RESOLVED_BACKEND=%s\n' \
    "$GOAL_ID" "${cycle:-0}" "${watch_start:-0}" "${overflow_count:-0}" \
    "${overflow_detected:-0}" "${MAX_CYCLES:-0}" "${UBERDEV_RESOLVED_BACKEND:-}" > "$tmp"
  mv -f "$tmp" "$sc" || { rm -f "$tmp"; return 3; }

  # Array sidecars: one int per line, no IFS-mutating joins.
  _uberdev_dispatch_prepare_tmp_target "${sc}.queue" 0 "goal" || return 3
  tmp="$(mktemp "${sc}.queue.XXXXXXXX")" || return 3
  printf '%s\n' "${queue[@]:-}" | grep -E '^[0-9]+$' > "$tmp" || true
  mv -f "$tmp" "${sc}.queue" || { rm -f "$tmp"; return 3; }

  _uberdev_dispatch_prepare_tmp_target "${sc}.active" 0 "goal" || return 3
  tmp="$(mktemp "${sc}.active.XXXXXXXX")" || return 3
  printf '%s\n' "${active_issues[@]:-}" | grep -E '^[0-9]+$' > "$tmp" || true
  mv -f "$tmp" "${sc}.active" || { rm -f "$tmp"; return 3; }
  return 0
}

# uberdev_goal_read_run_state
#   Reads + per-field-validates the sidecar; never sources or executes it. Caller must
#   already hold the GOAL_ID pointer (it keys the sidecar path). On success
#   exports/sets GOAL_ID, cycle, watch_start, overflow_count,
#   overflow_detected, MAX_CYCLES, UBERDEV_RESOLVED_BACKEND, and rehydrates
#   the queue/active_issues arrays. Returns 0 on success; 1 if missing/
#   unreadable. Invalid fields are skipped (not assigned a garbage value);
#   a forged GOAL_ID is rejected and never interpolated into a path.
uberdev_goal_read_run_state() {
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  _uberdev_goal_validate_id "${GOAL_ID:-}" || { echo "goal: invalid GOAL_ID pointer" >&2; return 1; }
  local sc="$tmpdir/goal-$GOAL_ID-runstate"
  [ -r "$sc" ] || { echo "goal: missing run-state sidecar ($sc)" >&2; return 1; }

  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      GOAL_ID)
        # Load-bearing: a substituted sidecar GOAL_ID with / or .. is a
        # path-traversal vector. Gate BEFORE any later path interpolation.
        _uberdev_goal_validate_id "$v" && GOAL_ID="$v" ;;
      cycle)             _uberdev_goal_validate_int "$v" && cycle="$v" ;;
      watch_start)       _uberdev_goal_validate_int "$v" && watch_start="$v" ;;
      overflow_count)    _uberdev_goal_validate_int "$v" && overflow_count="$v" ;;
      overflow_detected) _uberdev_goal_validate_int "$v" && overflow_detected="$v" ;;
      MAX_CYCLES)        _uberdev_goal_validate_int "$v" && MAX_CYCLES="$v" ;;
      UBERDEV_RESOLVED_BACKEND)
        case "$v" in claude-bg|wezterm|background) UBERDEV_RESOLVED_BACKEND="$v" ;; esac ;;
      *) : ;;   # reject unknown keys (allowlist only)
    esac
  done < "$sc"

  # Rehydrate arrays with the portable read loop (NOT mapfile); each element
  # int-gated so a newline/extra-field injection cannot survive.
  queue=()
  if [ -r "${sc}.queue" ]; then
    local line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _uberdev_goal_validate_int "$line" && queue+=("$line")
    done < "${sc}.queue"
  fi
  active_issues=()
  if [ -r "${sc}.active" ]; then
    local line2
    while IFS= read -r line2; do
      [ -n "$line2" ] || continue
      _uberdev_goal_validate_int "$line2" && active_issues+=("$line2")
    done < "${sc}.active"
  fi
  return 0
}

# uberdev_goal_cleanup_run_state
#   Best-effort removal of the three known predictable sidecar paths on goal
#   completion / circuit-breaker halt. Never fatal; no globbing of attacker-
#   influenceable patterns (each path is GOAL_ID-keyed and validated).
uberdev_goal_cleanup_run_state() {
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  _uberdev_goal_validate_id "${GOAL_ID:-}" || return 0
  local sc="$tmpdir/goal-$GOAL_ID-runstate"
  rm -f "$sc" "${sc}.queue" "${sc}.active" 2>/dev/null
  return 0
}
