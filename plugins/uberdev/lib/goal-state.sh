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
#   uberdev_goal_find_pr_for_issue             ISSUE_NUM   (gh; issue #180)
#   uberdev_goal_pr_state_gh                   PR_NUM      (gh; issue #180)
#   uberdev_goal_pr_is_merged                  PR_NUM      (gh; issue #180)
#   uberdev_goal_agent_busy_for_issue          ISSUE_NUM   (claude agents; issue #180)
#   uberdev_goal_list_prs_in_state             GOAL_ID STATE
#   uberdev_goal_read_merge_result             PR_NUM
#   uberdev_goal_write_run_state               (env-driven)
#   uberdev_goal_read_run_state                (env-driven)
#   uberdev_goal_cleanup_run_state             (env-driven)
#   uberdev_goal_register_batch_pr             GOAL_ID PR ISSUE   (issue #211)
#   uberdev_goal_batch_all_terminal            GOAL_ID            (issue #211)
#   uberdev_goal_batch_unblock_wait_clear      GOAL_ID            (issue #211)
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
#   _uberdev_goal_set_batch_terminal_state GOAL_ID PR STATE       (issue #211)
#   _uberdev_goal_batch_green_prs_ordered  GOAL_ID                (issue #211)
#   _uberdev_goal_rebase_collision_chain   GOAL_ID JUST_MERGED_PR (issue #211)
# External imports:
#   - lib/dispatch.sh :: _uberdev_dispatch_prepare_tmp_target — REQUIRED by
#     uberdev_goal_write_run_state, which reuses this #155 TOCTOU-safe target-prep
#     helper for every run-state sidecar it writes (issue #195). goal-state.sh
#     does NOT source dispatch.sh itself (no stable relative path from a sourced
#     lib + avoids a load-order cycle); the CALLER must source lib/dispatch.sh
#     BEFORE invoking the writer. A `command -v` preflight at the top of
#     uberdev_goal_write_run_state enforces the contract — it fails loud (rc=4,
#     `goal-state:` diagnostic) rather than crashing mid-write on a `command not
#     found`. The goal-pipeline fences already source dispatch.sh first; any
#     standalone caller (and the tests) must do the same.
#   - discover.sh is sourced opportunistically (below) for stderr-isolation
#     helpers, but no function names are required from it. The `gh_jq_or_jq` shim
#     below is a local-file jq wrapper; the spec/plan named it after a discover.sh
#     helper that was planned but never landed. Trust-signal + merge-result audit
#     reads target LOCAL files written by /review-pr and /merge, so plain
#     `jq <file> <filter>` is the correct primitive — `gh ... --jq` only works on
#     gh API output and would mis-serve these call sites.
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
    "merging->green") return 0 ;;       # #180 — merge-stall recovery: re-queue a stalled /merge agent (Phase 2d) back to green; bounded by the per-PR merge-attempt cap so it cannot loop
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
# 2b stale|missing graced re-dispatch arm (issue #180 split the old monolithic
# 2a into 2a PR-detect + 2b verdict-read) so the watch loop's 60s cadence
# cannot fire >3 /review-pr dispatches per PR over the 4h stuck_loop window
# (was unbounded at 240/PR).
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
  # first unwritable file with a clean diagnostic. The 8 state files:
  #   jsonl                  — per-goal audit stream
  #   pr-states.tsv          — PR state-machine transitions
  #   issue-states.tsv       — issue state-machine transitions
  #   fingerprints.tsv       — non-convergence fingerprint stream
  #   merge-attempts.tsv     — per-PR /merge attempt counter
  #   review-pr-attempts.tsv — per-PR /review-pr re-dispatch counter (B3 bound,
  #                            bounds Phase 2b's stale|missing graced re-dispatch arm)
  #   held-audits.tsv        — last re-review audit consumed per held PR (2e);
  #                            latest row per pr wins (get_last_held_audit tail)
  #   batch-prs.tsv          — issue #211 batch registry (one row per dispatched
  #                            PR; cols: pr<TAB>issue<TAB>dispatch_ts<TAB>terminal_state)
  local f
  for f in "$tmpdir/goal-$goal_id.jsonl" \
           "$tmpdir/goal-$goal_id-pr-states.tsv" \
           "$tmpdir/goal-$goal_id-issue-states.tsv" \
           "$tmpdir/goal-$goal_id-fingerprints.tsv" \
           "$tmpdir/goal-$goal_id-merge-attempts.tsv" \
           "$tmpdir/goal-$goal_id-review-pr-attempts.tsv" \
           "$tmpdir/goal-$goal_id-held-audits.tsv" \
           "$tmpdir/goal-$goal_id-batch-prs.tsv"; do
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
  # Resolve PR number via the GitHub-native finder (issue #180), then delegate
  # to the PR-keyed locator. The old solve-bg stdout `pushed PR #N` marker has
  # ZERO producers and `claude --bg` stdout is a detached banner on CLI 2.1.150,
  # so the only reliable issue->PR link is `closingIssuesReferences` / `feat/N-`
  # head. The `.pr == $pr` filter + lex-greatest-run_id tiebreak lives in one
  # place (see uberdev_goal_locate_review_pr_audit_by_pr).
  local pr
  pr="$(uberdev_goal_find_pr_for_issue "$issue")"
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

# uberdev_goal_find_pr_for_issue ISSUE_NUM   (issue #180)
# GitHub-native issue->PR resolver. Echoes the highest PR number whose
# `closingIssuesReferences` includes issue N (the `Closes #N` link every solver
# PR carries) OR whose head branch is `feat/N-…`. Replaces the retired
# solve-bg `pushed PR #N` log parser: that marker has ZERO producers and
# `claude --bg` stdout is a detached banner on CLI 2.1.150, so the loop keying
# on it never advanced (issue #180).
#
# ISSUE_NUM is digits-only validated BEFORE interpolation into the gh --jq
# filter (R3 gh-argument-injection guard — the same int gate Phase 0 applies
# to every positional). The filter runs inside gh's own jq (no external pipe),
# so gh progress bytes cannot pollute the result. Empty stdout + rc 0 when no
# PR exists yet — a not-yet-pushed solver must NOT read as an error. A gh
# failure also yields empty (fail-open; the caller treats "no PR" as "keep
# waiting", bounded by the per-issue solve-timeout).
uberdev_goal_find_pr_for_issue() {
  local n="$1"
  _uberdev_goal_validate_int "$n" || return 1
  # `any(.closingIssuesReferences[]?; .number == N)` is deliberate: a bare
  # `.closingIssuesReferences[]?.number == N` yields an EMPTY stream when the
  # array is empty (a PR whose Closes-link was dropped), and `empty or X`
  # collapses to empty in jq — silently discarding a row that the `feat/N-`
  # head-ref arm would have matched. `any/2` returns a concrete `false` on an
  # empty generator, so the `or` stays boolean and the head-ref fallback works.
  #
  # Capture gh's rc so a gh FAILURE (auth expiry, rate-limit 403, network) is
  # surfaced as a one-line breadcrumb rather than masquerading as "no PR yet"
  # (rc 0 + empty) — without it a transient gh outage stalls the goal until the
  # 150m solve-timeout with a MISattributed "agent idle" diagnostic. Still
  # fail-open (return empty, rc 0) so the caller keeps waiting/re-polls; the
  # breadcrumb only distinguishes the two empty cases in the operator's log.
  local out rc
  out="$(gh pr list --state all --limit 200 \
    --json number,closingIssuesReferences,headRefName \
    --jq "[.[] | select(any(.closingIssuesReferences[]?; .number == ${n}) or (.headRefName | test(\"^feat/${n}-\"))) | .number] | max // empty" \
    2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'goal-state: gh pr list failed (rc=%s) resolving PR for issue %s; treating as no-PR-yet (will re-poll)\n' "$rc" "$n" >&2
    return 0
  fi
  printf '%s' "$out"
}

# uberdev_goal_pr_state_gh PR_NUM   (issue #180)
# Echo the GitHub PR state (OPEN|CLOSED|MERGED) for PR_NUM — the authoritative,
# CLI-version-independent merge signal (replaces the never-written
# merge-bg-stdout-<pr>.log marker probe). On gh failure: emit a one-line
# breadcrumb to stderr and echo empty — so the Phase 2d CLOSED gate and
# read_merge_result's gh-first arm see "" (treated as "not CLOSED / not MERGED"
# → defer + re-poll) but the operator's log shows WHY, instead of a silent
# gh-outage being indistinguishable from a genuinely-OPEN PR.
uberdev_goal_pr_state_gh() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local out rc
  out="$(gh pr view "$pr" --json state --jq '.state' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'goal-state: gh pr view failed (rc=%s) reading state for PR %s; treating as not-merged/not-closed (will re-poll)\n' "$rc" "$pr" >&2
    return 0
  fi
  printf '%s' "$out"
}

# uberdev_goal_pr_is_merged PR_NUM   (issue #180)
# rc 0 iff gh reports PR_NUM as MERGED. The Phase 2d merge-completion gate (a
# merging PR is done when GitHub says MERGED, not when an stdout marker that is
# never written appears).
uberdev_goal_pr_is_merged() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  [ "$(uberdev_goal_pr_state_gh "$pr")" = "MERGED" ]
}

# uberdev_goal_agent_busy_for_issue ISSUE_NUM   (issue #180)
# rc 0 iff a live `claude` background session is working in the solver's
# worktree for issue N (cwd ends `solve-issue-N`, status ∈ busy|running|
# starting|working). Phase 2a uses it to disambiguate "solver still working,
# no PR yet" from "solver died" before the per-issue solve-timeout fires.
# Deliberately NOT used to gate review-readiness: the leaf solver routinely
# goes idle for ~20m while its OWN finish-branch /review-pr runs, so keying
# re-review on liveness fires redundant reviews and prematurely red-holds a PR
# whose GREEN verdict simply has not landed (Phase 2b uses a time-grace +
# verdict-poll model instead). jq parses the agent list (codebase-standard;
# avoids a python3 runtime dependency); a parse failure or empty list yields
# "not busy", the fail-safe default. The rc is normalised to exactly 0 (busy)
# or 1 (not busy) — `jq -e` returns 1 on a `false` result but 2/5 on a parse
# error, so the explicit if/return collapses every "not busy" cause (no match,
# malformed JSON, claude failure) to a single rc 1 for a crisp caller contract.
uberdev_goal_agent_busy_for_issue() {
  local n="$1"
  _uberdev_goal_validate_int "$n" || return 1
  if claude agents --json 2>/dev/null | jq -e --arg n "$n" '
    any(.[]?;
        (((.cwd // "") | rtrimstr("/")) | endswith("solve-issue-" + $n))
        and ((.status // "") | test("^(busy|running|starting|working)$")))' \
    >/dev/null 2>&1; then
    return 0
  fi
  return 1
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
# Resolves the merge outcome for PR_NUM as one of success|conflict|hook_failed|
# missing. Two-tier signal (issue #180 — defect #5):
#
#   1. gh state FIRST: if `gh pr view <pr> --json state` == MERGED, the PR
#      landed -> `success`, regardless of whether merge-pipeline appended a
#      (formerly agent-improvised, shape-unguaranteed) merge_executed audit row.
#      This is the authoritative, CLI-version-independent completion signal and
#      decouples goal convergence from the audit-row shape.
#   2. local audit FALLBACK: for PRs that did NOT merge, read the canonical
#      `.uberdev/audit.jsonl` JSONL stream (D15 — `AUDIT_LOG_FILENAME='audit.jsonl'`),
#      filter rows by `.event ∈ {merge_executed, pr_parked}` AND `.data.pr == $pr`,
#      take the most recent (last appended line), and map merge-pipeline's
#      PARK_REASON_ENUM onto the failure classes:
#        - `merge_executed`                                    -> success
#        - `pr_parked` reason ∈ {refused, ambiguous, push-non-ff} -> conflict
#        - `pr_parked` reason == test-fail-exhausted             -> hook_failed
#        - no matching row                                       -> missing
uberdev_goal_read_merge_result() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  # Tier 1 — gh state is authoritative for the success path. No inline
  # 2>/dev/null: uberdev_goal_pr_state_gh already suppresses gh's own stderr and
  # emits its own breadcrumb on failure, so letting its stderr through surfaces a
  # gh outage here instead of silently falling through to the audit tier.
  if [ "$(uberdev_goal_pr_state_gh "$pr")" = "MERGED" ]; then
    printf 'success\n'; return 0
  fi
  # Tier 2 — local audit classifies failures for PRs that did not merge.
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
# Batch registry + barrier helpers (issue #211).
# The batch registry tracks every PR /goal dispatches inside a single cycle so
# Phase 2c can decide when to enter the merge barrier (all_terminal predicate)
# and when to exit it (unblock_wait_clear predicate). Three public helpers +
# three internal helpers + run-state SSOT updates form the SSOT for Phase 1
# (register on dispatch) and Phase 2c (poll predicates, sequential merge).
# Atomic writes via the #155 TOCTOU-safe target-prep helper (same primitive
# uberdev_goal_write_run_state uses); the lib hard-depends on dispatch.sh
# being sourced first by the goal-pipeline body (a `command -v` preflight
# in register_batch_pr fails loud with rc=4 if the dep is missing).
# ---------------------------------------------------------------------------

# uberdev_goal_register_batch_pr GOAL_ID PR ISSUE
# Append a row to goal-<id>-batch-prs.tsv with terminal_state=PENDING.
# On the first registration of the cycle, also seed barrier_start_ts into
# the run-state sidecar (best-effort; the next uberdev_goal_write_run_state
# call atomically rewrites it).
# rc 0 on success; rc 1 validation; rc 3 atomic-write; rc 4 missing dispatch lib.
uberdev_goal_register_batch_pr() {
  local goal_id="$1" pr="$2" issue="$3"
  _uberdev_goal_validate_id  "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr"      || return 1
  _uberdev_goal_validate_int "$issue"   || return 1
  if ! command -v _uberdev_dispatch_prepare_tmp_target >/dev/null 2>&1; then
    printf 'goal-state: uberdev_goal_register_batch_pr requires lib/dispatch.sh sourced first\n' >&2
    return 4
  fi
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  local ts; ts="$(_uberdev_goal_now_secs)"
  # First-registration seed: if registry is empty, seed barrier_start_ts.
  local first=0
  if [ ! -s "$tsv" ]; then first=1; fi
  # Atomic append: read existing FIRST (the #155 prepare_tmp_target call below
  # rm+truncates its target, so reading after prepare returns an empty file),
  # write merged content into a fresh sibling, then atomic mv onto the prepared
  # 0600-owned target. The prepare call still provides the TOCTOU-safe target
  # guard (symlink reject + EUID-owner check + 0600 noclobber-create) — the
  # mv -f then replaces the prepared empty target with the merged content in
  # one filesystem syscall.
  local tmp existing
  existing=""
  [ -r "$tsv" ] && existing="$(cat "$tsv")"
  _uberdev_dispatch_prepare_tmp_target "$tsv" 0 "goal" || return 3
  tmp="$(mktemp "${tsv}.XXXXXXXX")" || return 3
  if [ -n "$existing" ]; then
    printf '%s\n%s\t%s\t%s\tPENDING\n' "$existing" "$pr" "$issue" "$ts" > "$tmp" || { rm -f "$tmp"; return 3; }
  else
    printf '%s\t%s\t%s\tPENDING\n' "$pr" "$issue" "$ts" > "$tmp" || { rm -f "$tmp"; return 3; }
  fi
  mv -f "$tmp" "$tsv" || { rm -f "$tmp"; return 3; }
  # Best-effort seed barrier_start_ts on first registration.
  #
  # The previous implementation used `! grep -q '^barrier_start_ts='` + `>>` append.
  # That predicate is wrong when Phase 0 step 7 has already called
  # uberdev_goal_write_run_state, because the writer ALWAYS emits a
  # `barrier_start_ts=${barrier_start_ts:-0}` line — so the placeholder
  # `barrier_start_ts=0` line exists on disk, the `! grep -q` predicate is
  # FALSE, and the seed never fires. The wall-clock merge-barrier breaker
  # (AC6 / D-211e) then never trips because the Phase 2c guard reads `0`
  # forever.
  #
  # Fix: treat any `barrier_start_ts=0` (or missing line) as unseeded. Use
  # an awk rewrite (drop every existing barrier_start_ts= line, append the
  # seeded value at end) → mktemp → mv -f so the placeholder line is
  # REPLACED rather than duplicated. Best-effort: failure leaves the file
  # untouched (the next uberdev_goal_write_run_state rewrites the sidecar
  # atomically from the in-memory scalar anyway).
  if [ "$first" = "1" ]; then
    local sc="$tmpdir/goal-$goal_id-runstate"
    if [ -r "$sc" ] && ! grep -qE '^barrier_start_ts=[1-9][0-9]*$' "$sc"; then
      if command -v _uberdev_dispatch_prepare_tmp_target >/dev/null 2>&1; then
        local sc_tmp
        sc_tmp="$(mktemp "${sc}.XXXXXXXX")" 2>/dev/null || sc_tmp=""
        if [ -n "$sc_tmp" ]; then
          if awk -v ts="$ts" '
            /^barrier_start_ts=/ { next }
            { print }
            END { printf "barrier_start_ts=%s\n", ts }
          ' "$sc" > "$sc_tmp" 2>/dev/null; then
            mv -f "$sc_tmp" "$sc" 2>/dev/null || rm -f "$sc_tmp" 2>/dev/null
          else
            rm -f "$sc_tmp" 2>/dev/null
          fi
        fi
      fi
    fi
  fi
  return 0
}

# uberdev_goal_batch_all_terminal GOAL_ID
# rc 0 iff registry is non-empty and every row's terminal_state ∈
# {GREEN,HELD,MERGE_FAILED,MERGED}. Empty registry returns rc 1. PENDING
# anywhere returns rc 1. Pure read; no gh calls.
uberdev_goal_batch_all_terminal() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] && [ -s "$tsv" ] || return 1
  local _pr _issue _ts state
  while IFS=$'\t' read -r _pr _issue _ts state; do
    [ -n "$state" ] || continue
    case "$state" in
      GREEN|HELD|MERGE_FAILED|MERGED) : ;;
      *) return 1 ;;
    esac
  done < "$tsv"
  return 0
}

# uberdev_goal_batch_unblock_wait_clear GOAL_ID
# rc 0 iff every HELD row has either NO unblock-issue OR (unblock-issue closed
# AND PR-trust-label review-pr:green present). The unblock-issue id is inferred
# from the PR body's `Blocks: #N` line (body capped at 64 KiB per R1/T1).
# Pure read of label/issue state. Stale or 404 label/issue data is treated as
# "still waiting" (rc 1) per spec B11 — never assume CLOSED on a gh failure.
uberdev_goal_batch_unblock_wait_clear() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] && [ -s "$tsv" ] || return 0   # empty registry → trivially clear
  local pr issue _ts state line
  while IFS=$'\t' read -r pr issue _ts state; do
    [ -n "$state" ] || continue
    [ "$state" = "HELD" ] || continue
    # Fetch PR body (capped at 64 KiB) and look for Blocks: #N.
    # F17 simplify-lens: reuse the centralized helpers
    # _uberdev_goal_fetch_pr_body + _uberdev_goal_parse_blocks_line (same
    # primitives used by sibling _uberdev_goal_check_unblock); the cap +
    # ReDoS-safe anchored regex + numeric re-validation now flow from a
    # single source of truth.
    local body blocking_issue n
    body="$(_uberdev_goal_fetch_pr_body "$pr")"
    blocking_issue=""
    while IFS= read -r line; do
      n="$(_uberdev_goal_parse_blocks_line "$line")"
      if [ -n "$n" ]; then
        blocking_issue="$n"
        break
      fi
    done <<< "$body"
    # No unblock-issue → this HELD PR doesn't gate the barrier.
    [ -n "$blocking_issue" ] || continue
    # Verify issue is CLOSED.
    local issue_state
    issue_state="$(gh issue view "$blocking_issue" --json state --jq .state 2>/dev/null)" || return 1
    [ "$issue_state" = "CLOSED" ] || return 1
    # Verify trust label review-pr:green is present.
    local has_green
    has_green="$(gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null | grep -c '^review-pr:green$' || true)"
    [ "$has_green" -ge 1 ] || return 1
  done < "$tsv"
  return 0
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
# Phase 2b's stale|missing graced arm (issue #180) calls this after the
# REVIEW_GRACE window lapses while a PR sits in pushed-reviewing with a
# missing/stale audit; the cap
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

# _uberdev_goal_set_batch_terminal_state GOAL_ID PR STATE
# Rewrite the PR's row in goal-<id>-batch-prs.tsv with the new terminal_state.
# Atomic-write via _uberdev_dispatch_prepare_tmp_target + mktemp + mv -f
# (preserves all other rows). Refuses to silently insert a new row for an
# unknown PR — that would let a typo masquerade as a state change.
# rc 0 on success; rc 1 validation / PR-not-in-registry; rc 3 atomic-write;
# rc 4 missing dispatch lib.
_uberdev_goal_set_batch_terminal_state() {
  local goal_id="$1" pr="$2" state="$3"
  _uberdev_goal_validate_id  "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr"      || return 1
  case "$state" in
    GREEN|HELD|MERGE_FAILED|MERGED|PENDING) : ;;
    *) printf 'goal-state: invalid batch terminal state: %s\n' "$state" >&2; return 1 ;;
  esac
  if ! command -v _uberdev_dispatch_prepare_tmp_target >/dev/null 2>&1; then
    return 4
  fi
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] || return 1
  # Read existing TSV into memory BEFORE preparing the target (the #155 prepare
  # helper rm+truncates its target, so a read after prepare would yield empty —
  # see register_batch_pr for the same ordering rationale). The mv -f below
  # replaces the prepared empty target with the rewritten content atomically.
  local existing
  existing="$(cat "$tsv")"
  _uberdev_dispatch_prepare_tmp_target "$tsv" 0 "goal" || return 3
  local tmp
  tmp="$(mktemp "${tsv}.XXXXXXXX")" || return 3
  # Rewrite the row whose first column == $pr, preserving all other rows.
  local row_pr row_issue row_ts row_state found=0
  while IFS=$'\t' read -r row_pr row_issue row_ts row_state; do
    [ -n "$row_pr" ] || continue
    if [ "$row_pr" = "$pr" ]; then
      printf '%s\t%s\t%s\t%s\n' "$row_pr" "$row_issue" "$row_ts" "$state" >> "$tmp"
      found=1
    else
      printf '%s\t%s\t%s\t%s\n' "$row_pr" "$row_issue" "$row_ts" "$row_state" >> "$tmp"
    fi
  done <<< "$existing"
  if [ "$found" = "0" ]; then
    rm -f "$tmp"
    # Restore the original content since we refused the insert.
    printf '%s' "$existing" > "$tsv" 2>/dev/null || true
    return 1   # PR not in registry; refuse silent insert
  fi
  mv -f "$tmp" "$tsv" || { rm -f "$tmp"; return 3; }
  return 0
}

# _uberdev_goal_batch_green_prs_ordered GOAL_ID
# Emit PR numbers (one per line) whose terminal_state=GREEN, sorted numerically
# ascending (`sort -n`). Phase 2c sequential-merge feeds this ordered list into
# /merge so the lowest-numbered green PR lands first and downstream PRs rebase
# onto its fresh main. rc 0 with empty stdout when no GREEN rows exist.
_uberdev_goal_batch_green_prs_ordered() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] && [ -s "$tsv" ] || return 0
  local pr _issue _ts state
  while IFS=$'\t' read -r pr _issue _ts state; do
    [ "$state" = "GREEN" ] && printf '%s\n' "$pr"
  done < "$tsv" | sort -n
}

# _uberdev_goal_rebase_collision_chain GOAL_ID JUST_MERGED_PR
# For each remaining GREEN PR in the batch, intersect its file-diff with the
# just-merged PR's file-diff; on non-empty intersection, fetch fresh
# origin/main and emit a goal_pr_transition audit event tagged
# collision_files=<csv>. The actual rebase is delegated to the existing
# /merge rebase handler on the next iteration — this helper's job is to
# pre-fetch main and surface the collision in the audit stream so the next
# /merge dispatch picks up the fresh base. rc 0 always (best-effort —
# collision detection must never halt the goal).
_uberdev_goal_rebase_collision_chain() {
  local goal_id="$1" merged_pr="$2"
  _uberdev_goal_validate_id  "$goal_id"   || return 0
  _uberdev_goal_validate_int "$merged_pr" || return 0
  # Use `gh pr diff --name-only` rather than `git diff --name-only origin/main..pr-N`:
  # the `pr-N` refs do not exist in the local clone, so the prior `git diff`
  # call failed silently (|| true) and the helper was a permanent no-op.
  # `gh pr diff` resolves the PR via the GitHub API and prints the same
  # path-set; failures still degrade gracefully (intersection stays empty,
  # no audit, rc 0 — matches the spec's "best-effort, never halt the goal"
  # contract).
  local merged_diff
  merged_diff="$(gh pr diff "$merged_pr" --name-only 2>/dev/null || true)"
  [ -n "$merged_diff" ] || return 0
  # F17 simplify-lens: hoist the sort of $merged_diff above the inner loop;
  # comm -12 cares only about set contents, not iteration count, so this
  # saves one `sort -u` per remaining-PR iteration.
  local merged_sorted
  merged_sorted="$(printf '%s\n' "$merged_diff" | sort -u)"
  local pr
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    [ "$pr" = "$merged_pr" ] && continue
    local pr_diff intersection
    pr_diff="$(gh pr diff "$pr" --name-only 2>/dev/null || true)"
    intersection="$(comm -12 <(printf '%s\n' "$merged_sorted") <(printf '%s\n' "$pr_diff" | sort -u))"
    if [ -n "$intersection" ]; then
      # Collision detected — refresh main and audit the transition.
      git fetch origin main 2>/dev/null || true
      uberdev_goal_audit goal_pr_transition \
        "$(printf '{"pr":%s,"from":"green","collision_files":"%s"}' \
            "$pr" "$(printf '%s' "$intersection" | tr '\n' ',' | sed 's/,$//')")" 2>/dev/null || true
      # The actual rebase is delegated to the existing /merge rebase handler
      # on the next iteration; the audit + pre-fetched main is the contract.
    fi
  done < <(_uberdev_goal_batch_green_prs_ordered "$goal_id")
  return 0
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
#   MAX_CYCLES, MAX_PARALLEL, BARRIER_TIMEOUT_S, barrier_start_ts,
#   UBERDEV_RESOLVED_BACKEND, and the queue/active_issues arrays
#   from the caller's shell; persists them to predictable, GOAL_ID-keyed
#   sidecars under $UBERDEV_TMPDIR, plus a fixed-path goal-active-id.txt pointer
#   so a fresh shell (no GOAL_ID in env/scalar) can discover the active GOAL_ID.
#   Returns 0 on success; 4 (fail-CLOSED) if its required lib/dispatch.sh helper
#   _uberdev_dispatch_prepare_tmp_target is not sourced (see "External imports");
#   1 if GOAL_ID is invalid; 3 (fail-CLOSED) if _uberdev_dispatch_prepare_tmp_target
#   rejects a target or a sidecar write fails.
uberdev_goal_write_run_state() {
  # Preflight (issue #195): this writer hard-depends on lib/dispatch.sh's
  # _uberdev_dispatch_prepare_tmp_target, which goal-state.sh does not source. A
  # caller that skipped dispatch.sh would otherwise hit a bare `command not
  # found` at the first call site below and return the MISLEADING write-failure
  # rc=3. Fail loud with a distinct rc instead, BEFORE any mktemp (so no temp
  # sibling can leak). `command -v` is the cross-shell (bash + zsh) probe — NOT
  # `type -t`, a bashism that misreports under the zsh-backed runner.
  if ! command -v _uberdev_dispatch_prepare_tmp_target >/dev/null 2>&1; then
    printf 'goal-state: run-state writer requires lib/dispatch.sh sourced first (missing _uberdev_dispatch_prepare_tmp_target)\n' >&2
    return 4
  fi
  _uberdev_goal_validate_id "${GOAL_ID:-}" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local sc="$tmpdir/goal-$GOAL_ID-runstate"   # NO .env extension

  # Scalar sidecar: prepare predictable target (symlink-reject + EUID-owner
  # check + 0600-create under set -C), write temp sibling, atomic mv.
  _uberdev_dispatch_prepare_tmp_target "$sc" 0 "goal" || return 3
  local tmp _filtered aid
  tmp="$(mktemp "${sc}.XXXXXXXX")" || return 3
  printf 'GOAL_ID=%s\ncycle=%s\nwatch_start=%s\noverflow_count=%s\noverflow_detected=%s\nMAX_CYCLES=%s\nUBERDEV_RESOLVED_BACKEND=%s\nMAX_PARALLEL=%s\nBARRIER_TIMEOUT_S=%s\nbarrier_start_ts=%s\n' \
    "$GOAL_ID" "${cycle:-0}" "${watch_start:-0}" "${overflow_count:-0}" \
    "${overflow_detected:-0}" "${MAX_CYCLES:-0}" "${UBERDEV_RESOLVED_BACKEND:-}" \
    "${MAX_PARALLEL:-0}" "${BARRIER_TIMEOUT_S:-0}" "${barrier_start_ts:-0}" > "$tmp"
  mv -f "$tmp" "$sc" || { rm -f "$tmp"; return 3; }

  # Array sidecars: one int per line, no IFS-mutating joins. Capture first
  # (command substitution strips trailing newlines, and `grep || true` absorbs
  # rc=1 on an empty array — a no-match, not an error), then write fail-CLOSED
  # so a real redirect failure (e.g. ENOSPC) cannot silently truncate the file.
  # `printf '%s\n'` re-adds the trailing newline so the final element survives
  # the read-back loop.
  _uberdev_dispatch_prepare_tmp_target "${sc}.queue" 0 "goal" || return 3
  tmp="$(mktemp "${sc}.queue.XXXXXXXX")" || return 3
  _filtered="$(printf '%s\n' "${queue[@]:-}" | grep -E '^[0-9]+$' || true)"
  if [ -n "$_filtered" ]; then
    printf '%s\n' "$_filtered" > "$tmp" || { rm -f "$tmp"; return 3; }
  else
    : > "$tmp" || { rm -f "$tmp"; return 3; }
  fi
  mv -f "$tmp" "${sc}.queue" || { rm -f "$tmp"; return 3; }

  _uberdev_dispatch_prepare_tmp_target "${sc}.active" 0 "goal" || return 3
  tmp="$(mktemp "${sc}.active.XXXXXXXX")" || return 3
  _filtered="$(printf '%s\n' "${active_issues[@]:-}" | grep -E '^[0-9]+$' || true)"
  if [ -n "$_filtered" ]; then
    printf '%s\n' "$_filtered" > "$tmp" || { rm -f "$tmp"; return 3; }
  else
    : > "$tmp" || { rm -f "$tmp"; return 3; }
  fi
  mv -f "$tmp" "${sc}.active" || { rm -f "$tmp"; return 3; }

  # Fixed-path pointer (issue #171 bootstrap): a fresh shell has no GOAL_ID in
  # env/scalar, so it cannot name the keyed sidecar above. Publish the active
  # GOAL_ID to a well-known path LAST — after the keyed data exists — so a
  # reader that discovers the pointer always finds complete keyed state. One
  # active /goal per $UBERDEV_TMPDIR is assumed (matches the run-state model).
  aid="$tmpdir/goal-active-id.txt"
  _uberdev_dispatch_prepare_tmp_target "$aid" 0 "goal" || return 3
  tmp="$(mktemp "${aid}.XXXXXXXX")" || return 3
  printf '%s\n' "$GOAL_ID" > "$tmp" || { rm -f "$tmp"; return 3; }
  mv -f "$tmp" "$aid" || { rm -f "$tmp"; return 3; }
  return 0
}

# uberdev_goal_read_run_state
#   Reads + per-field-validates the sidecar; never sources or executes it. If the
#   caller's GOAL_ID is empty/invalid (a fresh shell — env + scalars evaporate
#   across Bash calls, issue #171), it is bootstrapped from the fixed-path
#   goal-active-id.txt pointer (content gated through _uberdev_goal_validate_id).
#   On success: sets the GOAL_ID, cycle, watch_start, overflow_count,
#   overflow_detected, MAX_CYCLES, MAX_PARALLEL, BARRIER_TIMEOUT_S,
#   barrier_start_ts, UBERDEV_RESOLVED_BACKEND scalars, rehydrates
#   the queue/active_issues arrays, and EXPORTS UBERDEV_GOAL_ID + UBERDEV_TMPDIR
#   (the env vars the uberdev_goal_* helpers + bare $UBERDEV_TMPDIR/... paths in
#   the pipeline body depend on — see the export block at the function's end).
#   Returns 0 on success; 1 if missing/unreadable. Invalid fields are skipped
#   (not assigned a garbage value); a forged GOAL_ID is rejected and never
#   interpolated into a path.
uberdev_goal_read_run_state() {
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local _aid=""
  # Bootstrap (issue #171): a fresh shell has no GOAL_ID — env vars and shell
  # scalars do not survive across Bash calls. Recover it from the fixed-path
  # active-id pointer so the keyed sidecar can be located. The pointer's content
  # is untrusted: gate it through _uberdev_goal_validate_id (path-traversal)
  # before assigning, exactly as for the sidecar's stored GOAL_ID.
  if ! _uberdev_goal_validate_id "${GOAL_ID:-}"; then
    [ -r "$tmpdir/goal-active-id.txt" ] && _aid="$(head -n1 "$tmpdir/goal-active-id.txt" 2>/dev/null)"
    _uberdev_goal_validate_id "${_aid:-}" && GOAL_ID="$_aid"
  fi
  _uberdev_goal_validate_id "${GOAL_ID:-}" || { echo "goal: no valid GOAL_ID (env/scalar empty; active-id pointer missing or invalid)" >&2; return 1; }
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
      MAX_PARALLEL)      _uberdev_goal_validate_int "$v" && MAX_PARALLEL="$v" ;;
      BARRIER_TIMEOUT_S) _uberdev_goal_validate_int "$v" && BARRIER_TIMEOUT_S="$v" ;;
      barrier_start_ts)  _uberdev_goal_validate_int "$v" && barrier_start_ts="$v" ;;
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

  # #178 — re-export the env vars a fresh shell's downstream consumers need.
  # Four uberdev_goal_* helpers gate on the UBERDEV_GOAL_ID *env var*, NOT the
  # bare GOAL_ID scalar this function sets: uberdev_goal_audit (the goal_id sink —
  # empty env => mis-sinks to goal-unknown.jsonl), uberdev_goal_should_automerge
  # (provenance gate `[ -n "${UBERDEV_GOAL_ID:-}" ]` — empty env => refuses a GREEN
  # PR, so /goal never converges), and the review-pr/merge dispatch helpers. The
  # goal-pipeline body also interpolates bare $UBERDEV_TMPDIR/... paths and the
  # PR #129 TSV/audit helpers fall back to $UBERDEV_TMPDIR; an unset value resolves
  # them under / or /tmp instead of the dir Phase 0 wrote. Exporting both here —
  # the single rehydration SSOT every fence calls — restores a complete, consistent
  # environment and is what makes the #171 fix actually hold across fresh shells.
  export UBERDEV_GOAL_ID="$GOAL_ID"
  export UBERDEV_TMPDIR="$tmpdir"
  return 0
}

# uberdev_goal_cleanup_run_state
#   Best-effort removal of the run-state sidecars + the fixed-path active-id
#   pointer on goal completion / circuit-breaker halt. Never fatal; no globbing
#   of attacker-influenceable patterns (each keyed path is GOAL_ID-keyed and
#   validated). The shared pointer is removed only if it still names THIS goal.
uberdev_goal_cleanup_run_state() {
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  _uberdev_goal_validate_id "${GOAL_ID:-}" || return 0
  local sc="$tmpdir/goal-$GOAL_ID-runstate"
  rm -f "$sc" "${sc}.queue" "${sc}.active" "$tmpdir/goal-$GOAL_ID-batch-prs.tsv" 2>/dev/null
  # Remove the fixed-path pointer only if it still names THIS goal, so a
  # concurrent goal's pointer is never clobbered.
  local aid="$tmpdir/goal-active-id.txt"
  if [ -r "$aid" ] && [ "$(head -n1 "$aid" 2>/dev/null)" = "$GOAL_ID" ]; then
    rm -f "$aid" 2>/dev/null
  fi
  return 0
}
