# plugins/uberdev/lib/goal-state.sh
#
# Per-goal state machine + audit sink for /uberdev:goal (RFC 0005).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_goal_state_init                    GOAL_ID
#   uberdev_goal_pr_state_transition           GOAL_ID PR FROM TO
#   uberdev_goal_issue_state_transition        GOAL_ID ISSUE FROM TO
#   uberdev_goal_read_trust_signal             VERDICT_RECEIPT_OR_AUDIT_JSON_PATH
#   uberdev_goal_check_fingerprint_repeat      GOAL_ID CYCLE FINGERPRINT
#   uberdev_goal_should_automerge              GOAL_ID PR
#   uberdev_goal_reset_merge_attempts          GOAL_ID PR            (issue #292.2)
#   uberdev_goal_audit                         EVENT PAYLOAD_JSON
#   uberdev_goal_locate_review_pr_audit        ISSUE_NUM
#   uberdev_goal_locate_review_pr_audit_by_pr  PR_NUM
#   uberdev_goal_get_pr_state                  GOAL_ID PR
#   uberdev_goal_get_issue_state               GOAL_ID ISSUE
#   uberdev_goal_issue_ts_in_state             GOAL_ID ISSUE STATE
#   uberdev_goal_pr_ts_in_state                GOAL_ID PR STATE
#   uberdev_goal_pr_first_ts_in_state          GOAL_ID PR STATE
#   uberdev_goal_batch_has_pr                  GOAL_ID PR
#   uberdev_goal_count_distinct_prs            GOAL_ID
#   uberdev_goal_count_resolved_issues         GOAL_ID
#   uberdev_goal_count_failed_issues           GOAL_ID
#   uberdev_goal_record_held_audit             GOAL_ID PR AUDIT_PATH
#   uberdev_goal_get_last_held_audit           GOAL_ID PR
#   uberdev_goal_last_verdict_state            PR_NUM      (#348 discovery classification)
#   uberdev_goal_record_verdict_anomaly        GOAL_ID PR KIND       (#348)
#   uberdev_goal_count_verdict_anomalies       GOAL_ID PR KIND       (#348)
#   uberdev_goal_find_pr_for_issue             ISSUE_NUM   (gh; issue #180/#290.4)
#   uberdev_goal_pr_list_snapshot                          (gh; #301 per-pass snapshot)
#   uberdev_goal_find_pr_for_issue_from_json   ISSUE_NUM SNAPSHOT_JSON   (#301)
#   uberdev_goal_pr_state_gh                   PR_NUM      (gh; issue #180)
#   uberdev_goal_pr_is_merged                  PR_NUM      (gh; issue #180)
#   uberdev_goal_gh_failure_breaker_check      GOAL_ID [THRESHOLD]   (issue #290.3)
#   uberdev_goal_gh_failure_count              GOAL_ID               (issue #329 review)
#   uberdev_goal_agent_busy_for_issue          ISSUE_NUM   (claude agents; issue #180)
#   uberdev_goal_list_prs_in_state             GOAL_ID STATE
#   uberdev_goal_read_merge_result             PR_NUM
#   uberdev_goal_write_run_state               (env-driven)
#   uberdev_goal_read_run_state                (env-driven)
#   uberdev_goal_cleanup_run_state             (env-driven)
#   uberdev_goal_register_batch_pr             GOAL_ID PR ISSUE   (issue #211)
#   uberdev_goal_barrier_breaker_check         GOAL_ID BARRIER_TIMEOUT_S   (issue #214)
#   uberdev_goal_batch_all_terminal            GOAL_ID            (issue #211)
#   uberdev_goal_batch_unblock_wait_clear      GOAL_ID            (issue #211/#289)
#   uberdev_goal_detect_blocks_cycle           GOAL_ID            (issue #292.1)
#   print_summary                              CYCLES             (issue #270; hoisted from goal-pipeline SKILL.md Phase 4 so the per-fence re-source brings it into scope in every phase)
# Internal:
#   _uberdev_goal_ts_in_state              FILE KEY STATE [FIRST_WINS]
#   _uberdev_goal_validate_int             N
#   _uberdev_goal_is_object_name           SHA                (#345; lowercase 40-hex gate)
#   _uberdev_goal_drain_stderr             LABEL ERRFILE      (#348; prefixed stderr relay)
#   _uberdev_goal_pr_for_issue_jq          ISSUE_NUM          (#301; shared ranking program)
#   _uberdev_goal_verdict_state_path       PR_NUM             (#348)
#   _uberdev_goal_record_verdict_state     PR_NUM STATE       (#348)
#   _uberdev_goal_validate_id              GOAL_ID
#   _uberdev_goal_append                   FILE LINE
#   _uberdev_goal_indirect_get             VARNAME            (issue #270; dual-shell indirect read, no eval)
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
#   _uberdev_goal_gh_failure_counter_path                         (issue #290.3)
#   _uberdev_goal_record_gh_failure                              (issue #290.3)
#   _uberdev_goal_reset_gh_failure                               (issue #290.3)
#   _uberdev_goal_glob_worktree            SUFFIX                 (issue #290.2; cross-shell glob)
# External imports:
#   - lib/dispatch.sh :: _uberdev_dispatch_prepare_tmp_target, uberdev_dispatch_one
#     — both REQUIRED, both live in lib/dispatch.sh (NOT in this file).
#       _uberdev_dispatch_prepare_tmp_target backs uberdev_goal_write_run_state +
#         uberdev_goal_register_batch_pr (#155 TOCTOU-safe target-prep helper —
#         #195 added the writer guard).
#       uberdev_dispatch_one is the dispatch entry-point reached by the two
#         internal dispatch helpers (_uberdev_goal_dispatch_review_pr +
#         _uberdev_goal_dispatch_merge — #207 added the matching guards;
#         same latent-crash class as #195).
#     goal-state.sh does NOT source dispatch.sh itself (no stable relative path
#     from a sourced lib + avoids a load-order cycle); the CALLER must source
#     lib/dispatch.sh BEFORE invoking any of these functions. A `command -v`
#     preflight at the top of each consumer enforces the contract — they fail
#     loud (rc=4, `goal-state:` diagnostic) rather than crashing mid-call on a
#     `command not found`. The goal-pipeline fences already source dispatch.sh
#     first; any standalone caller (and the tests) must do the same.
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

# Worktree-mirror prefixes for .uberdev discovery (issue #220 simplify pass —
# R2 SSOT). Used by helpers that scan for /review-pr + /merge artifacts (verdicts,
# locked markers, merge-result audit). The empty prefix covers the main checkout;
# the three worktree variants cover the using-git-worktrees skill's documented
# layouts. Consumed ONLY via _uberdev_goal_glob_worktree (issue #290.2), which
# does the cross-shell glob expansion — the bare `${prefix}` form does NOT
# glob-expand a variable-derived `*` under the zsh Bash tool, so the worktree
# mirrors were silently invisible there before the helper.
_UBERDEV_GOAL_WORKTREE_PREFIXES=("" ".claude/worktrees/*/" ".worktrees/*/" "worktrees/*/")

# Stuck-on-dialog detector window (issue #220 simplify pass — Q1). Promoted
# from the inline magic literal `60` in uberdev_goal_agent_stuck_on_dialog so
# the threshold is a named tunable. Comparison preserved as `-ge 60` semantics
# via the default; BT79 fixture exercises the 65s threshold so this MUST
# default to 60 to keep behaviour identical.
: "${_UBERDEV_GOAL_STUCK_DIALOG_SECS:=60}"   # ge 60 (preserved threshold)

# Mirrored from skills/goal-pipeline/SKILL.md Phase 0 Constants block (issue #245).
# This is the runtime SSOT — the per-phase fresh-shell rehydration fences (grep
# SKILL.md for the `uberdev_goal_read_run_state` rehydration call) source ONLY
# this lib, never re-execute the Phase 0
# block. Defaulted-assignment ( := ) is order-safe: if the Phase 0 block ran
# first (cycle 1 happy path), these are no-ops; if the lib was sourced fresh
# (every Phase 2 poll iteration), these set the canonical defaults so the
# arithmetic comparisons in the watch loop don't coerce unset -> 0 and fire
# stuck_loop on iteration 1.
: "${_UBERDEV_GOAL_DEFAULT_MAX_CYCLES:=5}"
: "${_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL:=3}"
: "${_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S:=14400}"     # 4h
: "${_UBERDEV_GOAL_POLL_SECS:=60}"
: "${_UBERDEV_GOAL_STUCK_SECS:=14400}"                    # 4h
: "${_UBERDEV_GOAL_MAX_MERGE_ATTEMPTS:=3}"
: "${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:=3}"            # latent — used by _uberdev_goal_dispatch_review_pr via :-3 fallback, never declared until now
: "${_UBERDEV_GOAL_SOLVE_TIMEOUT:=9000}"                  # 150m — no PR AND no live agent => issue failed (#180)
: "${_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS:=3600}"      # 60m default — overridable via goal.review_grace_secs / UBERDEV_GOAL_REVIEW_GRACE_SECS / --review-grace-secs (#220 AC ❶)
: "${_UBERDEV_GOAL_MERGE_TIMEOUT:=3600}"                  # 60m — merging w/o MERGED AND agent idle => back to green for retry (#180)
# #301 (RFC 0012 §3.3 goal-R1 item 3) — bounded-watch budget default applied by
# Phase-0 step 3 when the fence runs under the Claude-Code Bash tool (CLAUDECODE
# env marker) and the operator gave NO explicit bound. Sized to the Bash tool's
# 600s hard call cap minus headroom for one worst-case serial gh walk: the
# Phase-2 budget gate bounds the upcoming SLEEP, not pass gh-latency (see the
# WATCH_BUDGET sizing note in the watch fence), so the fence must finish its
# in-flight pass and exit 42 BEFORE the harness SIGTERM lands.
: "${_UBERDEV_GOAL_DEFAULT_WATCH_BUDGET:=480}"            # 8m — 600s Bash-tool cap minus one serial gh walk
: "${_UBERDEV_GOAL_BODY_CAP:=65536}"                      # 64 KiB
: "${FINDING_LABEL:=review-pr-finding}"
# #290.3 — consecutive gh-failure breaker threshold. The Phase-2a/2d polling
# helpers (find_pr_for_issue / pr_state_gh) fail OPEN (empty+rc0) on a gh
# outage so a transient blip just re-polls; a SUSTAINED outage, however, must
# not ride the 150m solve-timeout / 60m merge-timeout to a false `failed`.
# After this many CONSECUTIVE failures (any success resets the counter), the
# breaker fires gh_api_failed. Default 5 ≈ 5 min at the 60s poll cadence.
: "${_UBERDEV_GOAL_MAX_GH_FAILURES:=5}"
# #348 finding 1 — bound on how many TIMES a PR may be observed with the verdict
# discovery reporting `indeterminate` or `tamper` before /goal stops
# re-dispatching /review-pr against it. Neither cause is fixable by re-reviewing
# (a duplicate-timestamp tie stays a tie; a replaced carrier stays replaced), so
# without a bound the PR spins to the 4h stuck_loop. Default 3 mirrors the
# review-pr dispatch cap.
#
# The tally is CUMULATIVE per (PR, kind) for the life of the run — an
# append-only TSV (uberdev_goal_record_verdict_anomaly) that is never reset —
# and that is deliberate, not an oversight. A "consecutive" counter would have
# to reset on every interleaved non-anomalous observation, and the interleaving
# outcome here is `stale`/`missing` (a verdict that still has not landed), not
# proof the channel healed: a PR alternating indeterminate → stale →
# indeterminate would then never reach the bound and would ride the 4h
# stuck_loop, which is precisely what this cap exists to prevent. Cumulative is
# the only shape that guarantees termination, so the bound reads "N unusable
# verdict observations for this PR", as the operator-facing message and the
# `observations` audit field both say.
: "${_UBERDEV_GOAL_MAX_VERDICT_ANOMALIES:=3}"
# #301 speedup finding 2 — cap on CONSECUTIVE Phase-2 passes that skip the poll
# sleep because the previous pass applied a state transition. Bounds the burst
# so the transition fast-path can never degenerate into a gh-hammering hot loop.
: "${_UBERDEV_GOAL_MAX_FAST_PASSES:=5}"

# Regex constants — PLAIN assignment, NOT := (Q2 security advisory: := would
# let a hostile env override the regex shape and widen the ReDoS attack
# surface without a validator). FINDING_LABEL above intentionally uses :=
# because gh CLI argv quoting + the 100-char label cap bound the override
# surface; regex shape has no such bound. Consumer-call-site SSOT migration
# is deferred (R2 in spec); _uberdev_goal_parse_blocks_line and
# _uberdev_goal_extract_fingerprint still hardcode the literal.
# SECURITY: do NOT change to ':=' — see Q2 advisory above
BLOCKS_LINE_REGEX='^Blocks: #([0-9]+)$'
# SECURITY: do NOT change to ':=' — see Q2 advisory above
FINDING_FINGERPRINT_REGEX='<!-- uberdev:review-pr-finding fingerprint=([a-f0-9]{16}) -->'

# Source the canonical merge verdict selector. Most goal-state helpers do not
# need it, so a packaging omission is tolerated at source time; the verdict
# locator itself maps that omission to the existing missing/re-review path.
# Resolve the sourced file itself, never the caller's cwd: bash publishes
# BASH_SOURCE while zsh publishes the equivalent source identity through %x.
_uberdev_goal_source_path() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    return 1
  fi
}
_UBERDEV_GOAL_FILE="$(_uberdev_goal_source_path)" || return 1
# #349 item 10 — the comment above says "never the caller's cwd", and now the
# code agrees. A source identity with NO `/` (a bare `goal-state.sh`, which the
# shell resolved through PATH/CDPATH or a `cd`-then-source) carries no
# directory information about the LIB, so the old `'.'` fallback resolved to
# the CALLER'S cwd. That is not merely inaccurate prose: the very next block
# sources `$_UBERDEV_GOAL_LIB_DIR/../skills/merge-pipeline/lib/discover.sh`, so
# a caller running from a directory that happens to contain a planted
# `../skills/merge-pipeline/lib/discover.sh` would have had it sourced into the
# goal state machine. Leave the dir EMPTY instead and skip the optional source —
# exactly the packaging-omission path the locator already tolerates.
_UBERDEV_GOAL_LIB_DIR=""
case "$_UBERDEV_GOAL_FILE" in
  */*) _UBERDEV_GOAL_LIB_DIR="$(cd "${_UBERDEV_GOAL_FILE%/*}" 2>/dev/null && pwd -P)" || return 1 ;;
  *) : ;;   # no directory component -> unresolvable; never fall back to cwd
esac
if [ -n "$_UBERDEV_GOAL_LIB_DIR" ] && [ -z "${_UBERDEV_MERGE_DISCOVER_LOADED:-}" ] && \
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

# _uberdev_goal_drain_stderr LABEL ERRFILE   (#348 findings 2-3)
# Emit whatever the previous step wrote into ERRFILE, one `goal-state: LABEL:`
# prefixed line each, then TRUNCATE it so the next step starts from empty.
# Multi-step flows that capture stderr to a file need exactly this: without the
# truncate, step N+1's diagnostic is reported together with step N's; without
# the emit, the diagnostic is the /dev/null the #348 findings are about.
# No-op (rc 0) when ERRFILE is empty or unset, so every call site can be
# unconditional and an mktemp failure degrades to "no breadcrumb", never to a
# broken control flow.
_uberdev_goal_drain_stderr() {
  local label="$1" errfile="${2:-}"
  [ -n "$errfile" ] && [ -s "$errfile" ] || return 0
  sed "s|^|goal-state: ${label}: |" "$errfile" >&2
  : > "$errfile" 2>/dev/null || true
  return 0
}

# _uberdev_goal_is_object_name SHA   (#345 finding 2)
# rc 0 iff SHA is a lowercase 40-hex git object name — the SAME shape the
# closed-receipt jq gate enforces (`test("^[0-9a-f]{40}$")`), expressed once
# here so the legacy pathname branch cannot drift away from it again.
#
# Deliberately NOT `[[ =~ ]]`: this lib is sourced by goal-pipeline SKILL.md
# fences that the Claude-Code Bash tool executes under /bin/zsh, where
# BASH_REMATCH is unset (zsh populates $match instead). A length probe plus a
# single negated character-class glob is exact, POSIX, and shell-agnostic:
# `*[!0-9a-f]*` matches iff ANY byte falls outside the class, so its negation
# proves every byte is in-class, and the length test pins the count at 40.
_uberdev_goal_is_object_name() {
  local sha="$1"
  [ "${#sha}" -eq 40 ] || return 1
  case "$sha" in
    *[!0-9a-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _uberdev_goal_pid_for_issue ISSUE_NUM   (issue #220 simplify pass — R1 SSOT)
# Returns the validated PID stored in the backend status JSON on stdout with
# rc=0, or empty on stdout + rc=1 if the file is missing, the security guard
# fails, jq extraction fails, or the value is not a positive integer. The
# background backend writes solve-bg-status-<ISSUE>.json; it is the only
# PID-bearing backend left since #381 retired the codex transport and its
# solve-codex-status-<ISSUE>.json sidecar.
# Replaces three near-identical 4-line blocks: _uberdev_goal_any_attempt_stuck,
# _uberdev_goal_reap_zombies, and the SKILL.md Phase 2b stuck-on-dialog audit
# payload extraction.
_uberdev_goal_pid_for_issue() {
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local status_file expected_backend pid status_backend status_issue
  case "${UBERDEV_RESOLVED_BACKEND:-background}" in
    background|"")
      status_file="$tmpdir/solve-bg-status-$issue.json"
      expected_backend="background" ;;
    *)
      return 1 ;;
  esac
  _uberdev_dispatch_tmp_target_safe "$status_file" || return 1
  status_backend="$(jq -r '.backend // empty' < "$status_file" 2>/dev/null)" || return 1
  [ "$status_backend" = "$expected_backend" ] || return 1
  status_issue="$(jq -r '.issue // empty' < "$status_file" 2>/dev/null)" || return 1
  _uberdev_goal_validate_int "$status_issue" || return 1
  [ "$status_issue" = "$issue" ] || return 1
  pid="$(jq -r '.pid // empty' < "$status_file" 2>/dev/null)" || return 1
  _uberdev_goal_validate_int "$pid" || return 1
  [ "$pid" -gt 0 ] || return 1
  printf '%s' "$pid"
}

# #381: `uberdev_goal_codex_status_for_issue` lived here. It read the detached
# Codex wrapper's terminal status sidecar (solve-codex-status-<ISSUE>.json) so
# /goal could surface a failed `codex exec` immediately instead of waiting out
# the generic solve timeout. The codex backend is gone from
# _UBERDEV_DISPATCH_BACKEND_ENUM, so UBERDEV_RESOLVED_BACKEND can never equal
# `codex` and the helper's first guard could never pass. Deliberately no shim:
# a dormant reader is how a retired sidecar format drifts back into a live path.

# _uberdev_goal_glob_worktree SUFFIX
# Emit (one per line, on stdout) every READABLE path matching
# `<prefix><SUFFIX>` for each prefix in _UBERDEV_GOAL_WORKTREE_PREFIXES, in
# array order (empty/project-root prefix first, worktree mirrors after).
#
# #270/#290.2 cross-shell glob: the prefixes carry a `*` worktree wildcard and
# come from a VARIABLE. bash glob-expands `${prefix}${SUFFIX}` after
# substitution, but zsh does NOT expand `*` that arrives via a parameter unless
# the expansion is flagged `${~var}` (GLOB_SUBST). Since this lib is re-sourced
# inside the goal-pipeline SKILL.md bash fences that run under /bin/zsh on
# macOS, the bare-`${prefix}` form silently matched NOTHING for the three
# worktree-mirror prefixes under zsh — so worktree verdict/audit/lock discovery
# never fired there (only the empty cwd prefix worked). Branch on the live shell
# and use `${~pat}` under zsh / bare `$pat` under bash (bash hard-errors on
# `${~pat}`: `bad substitution`). Unmatched globs leave the literal pattern,
# which the `[ -r ]` guard rejects (no nullglob assumed) — identical to the
# inline call sites' prior behaviour.
_uberdev_goal_glob_worktree() {
  local suffix="$1" prefix pat c
  if [ -n "${ZSH_VERSION:-}" ]; then
    # zsh: `${~pat}` re-enables glob on the variable-derived pattern;
    # `localoptions nonomatch` makes an UNMATCHED glob yield the literal
    # (function-scoped — does not leak to the caller) instead of zsh's default
    # NOMATCH hard-error, matching bash's no-nullglob behaviour so the `[ -r ]`
    # guard can reject the un-expanded literal uniformly in both shells.
    setopt localoptions nonomatch 2>/dev/null || true
    for prefix in "${_UBERDEV_GOAL_WORKTREE_PREFIXES[@]}"; do
      pat="${prefix}${suffix}"
      for c in ${~pat}; do [ -r "$c" ] && printf '%s\n' "$c"; done
    done
  else
    for prefix in "${_UBERDEV_GOAL_WORKTREE_PREFIXES[@]}"; do
      pat="${prefix}${suffix}"
      for c in $pat; do [ -r "$c" ] && printf '%s\n' "$c"; done
    done
  fi
  return 0
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

# _uberdev_goal_indirect_get VARNAME
# Dual-shell indirect-variable read (#270). bash `${!name}` indirect expansion is
# a hard `bad substitution` error under zsh, and this lib is re-sourced inside the
# goal-pipeline SKILL.md bash fences which run under /bin/zsh on macOS. zsh reads
# an indirect via `${(P)name}`; bash via `${!name}`. Branch on the live shell so
# the SAME source works in both, using only native parameter expansion — never a
# shell-evaluation primitive, which the T3 hard rule (goal.test.sh assertion
# G19.no-eval) forbids in this file. bash never parse-errors on the un-taken zsh
# `${(P)...}` arm (the expansion is resolved lazily, only when run), so leaving
# both arms in one file is safe. Prints the value (empty if unset).
_uberdev_goal_indirect_get() {
  local _name="$1"
  if [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(P)_name:-}"
  else
    printf '%s' "${!_name:-}"
  fi
}

# _uberdev_goal_parse_blocks_line LINE
# ReDoS-safe (D9 + T1): anchored regex; numeric re-validation defense-in-depth.
# Dual-shell capture (#270): this file is also re-sourced inside the goal-pipeline
# SKILL.md bash fences, which run under /bin/zsh on macOS. zsh populates the
# capture array as `$match`, not `$BASH_REMATCH`, so the bash-only form silently
# yielded an empty PR number under zsh — the only `Blocks: #N` parser, so held-PR
# unblock never fired. `${match[1]:-${BASH_REMATCH[1]}}` reads whichever the live
# shell populated (zsh -> match[1]; bash -> BASH_REMATCH[1]).
_uberdev_goal_parse_blocks_line() {
  local line="$1"
  if [[ "$line" =~ ^Blocks:\ \#([0-9]+)$ ]]; then
    local pr_num="${match[1]:-${BASH_REMATCH[1]}}"
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

# uberdev_goal_reset_merge_attempts GOAL_ID PR   (issue #292.2)
# Zero the per-PR merge-attempt counter by appending a `PR<TAB>0` row — the
# count reader above is last-write-wins (`$1==p {c=$2}`), so the appended 0
# supersedes all prior ticks for this PR. Called when a PR transitions back to
# `green` from a HELD state (Phase 2e held→green): the merge-attempt cap
# (uberdev_goal_should_automerge, default 3) is otherwise per-PR-LIFETIME and
# never reset, so a PR legitimately blocked for 2 cycles — then unblocked and
# cleanly GREEN — could hit the cap from transient merge stalls accumulated
# across its hold and never auto-merge again, stalling convergence into
# queue_empty_not_converged with a GREEN-but-unmergeable PR. Resetting on the
# held→green recovery scopes the cap to the PR's CURRENT green lifetime.
# rc 0 on success; rc 1 on validation; propagates the append's rc on a write
# failure (fail-loud, uniform with the state-transition writers — #157).
uberdev_goal_reset_merge_attempts() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr"     || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local row; printf -v row '%s\t%s' "$pr" 0
  _uberdev_goal_append "$tmpdir/goal-$goal_id-merge-attempts.tsv" "$row"
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
# D4 + T4 — Refuse unsafe $UBERDEV_TMPDIR; truncate-create the 8 per-goal
# state files (jsonl + 7 TSVs) — enumerated in the inline comment below.
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
  # CONTRACT: goal-audit-event !case-arm
  case "$event" in
    goal_dispatched|goal_pr_transition|goal_unblock_triggered|goal_cycle_completed|goal_converged|goal_circuit_breaker|goal_merge_deferred|goal_review_pr_deferred|goal_review_grace|goal_reaper_kill|goal_reaper_skipped|goal_issue_closed_without_pr|goal_version_bumped|goal_partial_chain) ;;
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
# D2 issue machine: input → dispatched → solving → pr-pushed → resolved;
# dispatched → failed and solving → failed and pr-pushed → failed allowed.
# `input → solving` is retained for the legacy single-write path (callers that
# do not need the pre-spawn guard). The `dispatched` state (issue #236) closes
# the leaf-crash-pre-state-write double-spawn surface: the parent writes
# `dispatched` BEFORE uberdev_dispatch_one, so any leaf failure between spawn
# and the post-spawn `solving` write still leaves a TSV row the Phase-1
# skip-check (`dispatched|solving|pr-pushed`) can match on the next cycle.
# `pr-pushed → input` (issue #592) is the ONE backwards arc, and the reason
# `pr-pushed` is no longer terminal: when a solver's task chain stops short its
# PR still lands, so the issue has to re-enter the queue for the tasks that
# never shipped. Re-entry is an ARC, not a new state — the enum stays at 7
# members and Phase 1 re-claims the issue through its existing
# `input → dispatched` path. `solving → input` is deliberately NOT added: what
# is modelled is re-entry after a LANDED partial delivery, never a slip
# backwards out of an in-flight solve. `resolved`, `resolved-by-no-action` and
# `failed` remain hard terminal.
# No audit event (issue transitions are derived state; audit covers PR
# transitions + cycle boundaries).
uberdev_goal_issue_state_transition() {
  local goal_id="$1" issue="$2" from="$3" to="$4"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$issue" || return 1
  case "$from->$to" in
    "input->dispatched"|"input->solving"|"dispatched->solving"|"dispatched->failed"|"solving->pr-pushed"|"pr-pushed->resolved"|"solving->failed"|"pr-pushed->failed"|"solving->resolved-by-no-action"|"pr-pushed->input") ;;
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

# uberdev_goal_read_trust_signal VERDICT_RECEIPT_OR_AUDIT_JSON_PATH
# D17 — GREEN/YELLOW/RED/STALE/MISSING from /review-pr Phase 2.5 audit.
#
# #349 item 9 — the argument is NOT (only) a pathname, and the two branches do
# NOT share a tolerance contract. Both facts were wrong in the previous header,
# which is the one place still denying the tightening the closed branch shipped:
#
#   CLOSED RECEIPT (the LIVE path). Anything starting with `{` is the closed
#   controller state minted by uberdev_goal_locate_review_pr_audit_by_pr. It is
#   validated STRICTLY and there is NO legacy tolerance: schema_version must be
#   1, kind must be `uberdev-goal-review-verdict`, `.pr` must be a positive
#   INTEGER, `.sha` must be lowercase 40-hex, `.audit_state` must be
#   legacy|current, and the three phase2_5 counters must be
#   boolean/non-negative-integer. Any deviation returns `missing`. A verdict
#   that cannot be bound to the live HEAD returns `stale`, never a colour.
#
#   LEGACY PATHNAME (fixtures + pre-selector callers). A readable file path is
#   parsed leniently: a missing `.pr`/`.sha` skips the HEAD binding entirely
#   (backward compatibility for pre-anchor verdicts), and a gh outage falls
#   through to the colour decision instead of reporting stale.
#
# Callers must therefore treat "path tolerance" as a property of the LEGACY
# branch only.
# B5 — explicit branch on gh_jq_or_jq exit code: jq-failure (rc!=0) means
# the audit JSON is unreadable (malformed / not JSON); treat as `missing`
# so the caller re-dispatches /review-pr (the only safe action — never
# assume GREEN on an unreadable trust artifact, per D17). Empty stdout
# with rc=0 means jq ran but returned empty (phase2_5 absent) — that's
# the legacy/pre-v0.26.0 audit shape, treated as `stale`.
#
# #290.1 (CRITICAL) — HEAD-SHA binding. The verdict JSON carries both `.pr`
# and `.sha` (the post-emission anchor `headRefOid` written at
# commands/review-pr.md:954). A commit pushed AFTER a GREEN verdict leaves a
# stale-but-green verdict on disk; without binding, /goal advanced
# pushed-reviewing→green→merging on that stale review and churned the PR into
# the retry / queue_empty_not_converged path (/merge's trust-trail-evaluator
# DOES re-validate the SHA, so the merge itself is safe — but /goal
# mis-classifies). Self-contained fix: read `.pr` + `.sha` from the SAME file,
# fetch the live `gh pr view <pr> --json headRefOid`, and on mismatch return
# `stale` (the whole review is invalidated by a new push, regardless of colour)
# so the caller re-dispatches /review-pr instead of advancing to green.
# Fail-SAFE on a gh outage reading headRefOid: a rate-limit / network error
# must NOT masquerade as a SHA mismatch (that would churn the PR), so skip the
# binding and fall through to the colour decision with a one-line breadcrumb —
# identical to the pre-#290 behaviour for that transient window. The check is
# also skipped when the verdict has no `.sha` (legacy/pre-anchor JSON) or no
# `.pr`, preserving backward compatibility (and the audit-path-only test
# fixtures that never set a PR).
# The producer emits its signal from fifteen separate statements, in more
# than one quoting style. !emit-literal keys on the ROLE (an unredirected
# single-literal write to stdout), so `printf "x\\n"`, `printf '%s\\n' x`
# and `echo x` are all seen; a regex over the quoting was not a role key.
# CONTRACT: trust-signal !emit-literal
uberdev_goal_read_trust_signal() {
  local audit_path="$1"
  # Canonical locator output is closed controller state, not a pathname. Its
  # private carrier was already digest/identity-recaptured and cleaned.
  if [ "${audit_path#\{}" != "$audit_path" ]; then
    local closed_fields verdict_pr verdict_sha closed_state
    local blocker critical halted
    if ! closed_fields="$(jq -er '
      if type != "object"
         or .schema_version != 1
         or .kind != "uberdev-goal-review-verdict"
         or ((.pr | type) != "number")
         or (.pr < 1)
         or ((.pr | floor) != .pr)
         or ((.sha | type) != "string")
         or ((.sha | test("^[0-9a-f]{40}$")) | not)
         or (.audit_state != "legacy" and .audit_state != "current")
         or ((.phase2_5_halted | type) != "boolean")
         or ((.phase2_5_blocker_count | type) != "number")
         or (.phase2_5_blocker_count < 0)
         or ((.phase2_5_blocker_count | floor) != .phase2_5_blocker_count)
         or ((.phase2_5_critical_count | type) != "number")
         or (.phase2_5_critical_count < 0)
         or ((.phase2_5_critical_count | floor) != .phase2_5_critical_count)
      then error("closed goal verdict shape")
      else [
        (.pr | tostring),
        .sha,
        .audit_state,
        (.phase2_5_halted | tostring),
        (.phase2_5_blocker_count | tostring),
        (.phase2_5_critical_count | tostring)
      ] | @tsv
      end
    ' <<<"$audit_path" 2>/dev/null)"; then
      printf 'missing\n'
      return 0
    fi
    IFS="$(printf '\t')" read -r \
      verdict_pr verdict_sha closed_state halted blocker critical <<<"$closed_fields"

    local head_oid head_rc
    head_oid="$(gh pr view "$verdict_pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)"
    head_rc=$?
    if [ "$head_rc" -ne 0 ] || [ -z "$head_oid" ]; then
      # An unreadable HEAD means the verdict CANNOT be bound to the live commit,
      # so its colour is unproven — not good. Falling through to the colour
      # decision here would let a rate-limited or offline `gh` turn a verdict
      # earned on an older SHA into a green light for whatever has been pushed
      # since, and /goal auto-merges on green. Report stale: it never authorises
      # a merge, and the existing consumers already handle it by re-reviewing.
      # Re-review churn on a transient gh outage is the correct trade against
      # merging unreviewed commits.
      printf 'goal-state: gh pr view %s headRefOid unreadable (rc=%s); cannot bind verdict to HEAD, reporting stale\n' \
        "$verdict_pr" "$head_rc" >&2
      printf 'stale\n'
      return 0
    elif [ "$head_oid" != "$verdict_sha" ]; then
      printf 'goal-state: trust verdict for PR %s is bound to %s but HEAD is %s; treating as stale (re-review needed)\n' \
        "$verdict_pr" "$verdict_sha" "$head_oid" >&2
      printf 'stale\n'
      return 0
    fi

    [ "$closed_state" = "current" ] || { printf 'stale\n'; return 0; }
    if [ "$halted" = "true" ] || [ "$blocker" -gt 0 ]; then
      printf 'red\n'
    elif [ "$critical" -gt 0 ]; then
      printf 'yellow\n'
    else
      printf 'green\n'
    fi
    return 0
  fi

  [ -f "$audit_path" ] || { printf 'missing\n'; return 0; }
  # #290.1 — bind the verdict to the live PR HEAD before trusting its colour.
  # Both reads come from the same verdict file (no extra disk I/O beyond two
  # jq passes). A jq failure here is non-fatal: it degrades to "no binding"
  # rather than "missing", because the by_severity projection below has its
  # own fail-closed `missing` arm and is the authoritative readability gate.
  local verdict_pr verdict_sha
  verdict_pr="$(jq -r '.pr // empty' "$audit_path" 2>/dev/null)"
  verdict_sha="$(jq -r '.sha // empty' "$audit_path" 2>/dev/null)"
  # #345 finding 2 — this branch validated only `.pr`; `.sha` came off a bare
  # `jq -r` with NO shape check, so a truncated/uppercase/garbage anchor was
  # compared against a 40-char object name in silence and the PR was pinned
  # `stale` forever with nothing on any stream saying why. Validate against the
  # SAME lowercase-40-hex shape the closed-receipt branch enforces, using a
  # `case` glob rather than `[[ =~ ]]` (this lib is sourced by SKILL.md fences
  # that run under /bin/zsh, where BASH_REMATCH is unset — project memory
  # project_uberdev_type_t_bashism_zsh).
  #
  # A malformed anchor is WARNED ABOUT AND STILL COMPARED, deliberately. The
  # comparison of a non-40-hex string against a real object name can only ever
  # produce `stale`, which is the fail-closed outcome. SKIPPING the binding
  # instead would let the verdict's colour through unbound — strictly less safe
  # than the status quo, and /goal auto-merges on green. So the fix here is to
  # make the failure DIAGNOSABLE, not to relax it.
  if [ -n "$verdict_sha" ] && ! _uberdev_goal_is_object_name "$verdict_sha"; then
    printf 'goal-state: verdict %s carries a malformed .sha anchor (%s) — not a lowercase 40-hex object name; it can never equal a live HEAD, so this verdict will read stale until it is re-reviewed\n' \
      "$audit_path" "$verdict_sha" >&2
  fi
  if [ -n "$verdict_pr" ] && [ -n "$verdict_sha" ] \
     && _uberdev_goal_validate_int "$verdict_pr"; then
    local head_oid head_rc
    head_oid="$(gh pr view "$verdict_pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)"
    head_rc=$?
    if [ "$head_rc" -ne 0 ] || [ -z "$head_oid" ]; then
      # gh outage / empty — fail-SAFE: do NOT declare stale on a transient
      # failure (would churn the PR); fall through to the colour decision.
      printf 'goal-state: gh pr view %s headRefOid unreadable (rc=%s); skipping SHA-binding for this read\n' \
        "$verdict_pr" "$head_rc" >&2
    elif [ "$head_oid" != "$verdict_sha" ]; then
      # A commit landed after this verdict — the whole review is stale.
      printf 'goal-state: trust verdict for PR %s is bound to %s but HEAD is %s; treating as stale (re-review needed)\n' \
        "$verdict_pr" "$verdict_sha" "$head_oid" >&2
      printf 'stale\n'; return 0
    fi
  fi
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
# /CONTRACT: trust-signal

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
# worktree-mirror equivalent for the issue's PR. Selection, root binding,
# timestamp ordering, ambiguity handling, and stable byte capture are delegated
# to merge-pipeline/lib/discover.sh. On success the private carrier is
# digest/identity-recaptured, reduced to stable controller state, and cleaned
# before this function returns. Absent or indeterminate both return empty so
# the existing caller classifies the signal as missing and re-runs /review-pr.
uberdev_goal_locate_review_pr_audit() {
  local issue="$1"
  _uberdev_goal_validate_int "$issue" || return 1
  # Resolve PR number via the GitHub-native finder (issue #180), then delegate
  # to the PR-keyed locator. The old solve-bg stdout `pushed PR #N` marker has
  # ZERO producers and `claude --bg` stdout is a detached banner on CLI 2.1.150,
  # so the only reliable issue->PR link is `closingIssuesReferences` / a
  # `<type>/N-` head. Candidate filtering and ranking live in ONE place — the
  # canonical selector in merge-pipeline/lib/discover.sh, reached via
  # uberdev_goal_locate_review_pr_audit_by_pr. Ranking is by the 15-byte
  # YYYYMMDD-HHMMSS prefix, requiring byte-identical artifacts on a tie
  # (RFC 0005 B12); the previous lex-greatest-run_id tiebreak is retired.
  local pr
  pr="$(uberdev_goal_find_pr_for_issue "$issue")"
  [ -n "$pr" ] || return 0
  _uberdev_goal_validate_int "$pr" || return 0
  uberdev_goal_locate_review_pr_audit_by_pr "$pr"
}

# ---------------------------------------------------------------------------
# Verdict-discovery classification channel (#348 findings 1-3).
#
# THE DEFECT. uberdev_goal_locate_review_pr_audit_by_pr funnelled SIX distinct
# outcomes — selector library not sourced, proven absence, indeterminate,
# recapture/tamper failure, projection failure, and cleanup failure — into ONE
# observable: empty stdout with rc 0. /goal then classifies every one of them
# as `missing` and re-dispatches /review-pr. That is fail-safe by accident of
# destination, not by construction, and it costs three things:
#   1. a PERSISTENT indeterminate cause never converges (the recovery action is
#      "re-review", which cannot fix a duplicate-timestamp tie), and the run
#      ends up red_held under the misleading label `dispatch_cap_exhausted`;
#   2. TAMPER — the strongest security signal this machinery produces, meaning
#      the private carrier was replaced/mutated/symlinked/re-owned — reads
#      byte-for-byte identically to "no review has run yet";
#   3. a PROVEN verdict is thrown away because a temp file could not be
#      deleted, with the cleanup's stderr sent to /dev/null.
#
# WHY A SIDECAR AND NOT AN rc. Two hard constraints rule out the obvious fixes.
# (a) The rc is already pinned: `absent`/`indeterminate` must stay rc 0 with no
#     recapture (locked by tests/goal.test.sh G49), and rc 1 is reserved for a
#     non-numeric PR (BT50). Overloading rc would break the selector contract
#     /goal shares with /merge.
# (b) Every caller invokes the locator inside a COMMAND SUBSTITUTION
#     (`audit_json="$(uberdev_goal_locate_review_pr_audit_by_pr "$pr")"`), so a
#     global variable set in here dies with the subshell — the same fence-scoped
#     state class this project has been bitten by repeatedly.
# The classification therefore travels on disk, keyed by GOAL_ID + PR, exactly
# like the gh-failure counter and the held-audit registry.
#
# _uberdev_goal_verdict_state_path PR — path resolver. rc 1 + empty stdout when
# there is no valid UBERDEV_GOAL_ID in scope (standalone/test callers), so the
# recorder degrades to a no-op instead of writing outside a goal run.
_uberdev_goal_verdict_state_path() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local goal_id="${UBERDEV_GOAL_ID:-}"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  printf '%s' "$tmpdir/goal-$goal_id-verdict-state-$pr.txt"
}

# _uberdev_goal_record_verdict_state PR STATE — best-effort single-line write.
# Never disturbs the caller: a write failure leaves the reader at `unknown`,
# which the consumer treats exactly as it treated every outcome before #348.
_uberdev_goal_record_verdict_state() {
  local pr="$1" state="$2"
  local f; f="$(_uberdev_goal_verdict_state_path "$pr")" || return 0
  printf '%s\n' "$state" > "$f" 2>/dev/null || return 0
  return 0
}

# uberdev_goal_last_verdict_state PR — read back the classification recorded by
# the most recent locator call for PR. Prints one of:
#   found | absent | indeterminate | tamper | projection_failed |
#   cleanup_failed | selector_unavailable | unknown
# `unknown` covers "never recorded" and "recorded value outside the enum" — a
# forged sidecar must degrade to the pre-#348 behaviour, never widen into a new
# control-flow arm.
uberdev_goal_last_verdict_state() {
  local pr="$1"
  local f; f="$(_uberdev_goal_verdict_state_path "$pr")" || { printf 'unknown\n'; return 0; }
  [ -r "$f" ] || { printf 'unknown\n'; return 0; }
  local v; v="$(head -n1 "$f" 2>/dev/null)"
  case "$v" in
    found|absent|indeterminate|tamper|projection_failed|cleanup_failed|selector_unavailable)
      printf '%s\n' "$v" ;;
    *) printf 'unknown\n' ;;
  esac
}

# uberdev_goal_record_verdict_anomaly GOAL_ID PR KIND   (#348 finding 1)
# Append-only tally of the non-recoverable verdict-discovery outcomes
# (`indeterminate`, `tamper`) observed for a PR. Same TSV idiom as the held-audit
# registry: append here, count with the reader below, so the tally survives the
# fresh-shell fence boundary that kills every in-memory counter in this pipeline.
uberdev_goal_record_verdict_anomaly() {
  local goal_id="$1" pr="$2" kind="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr" || return 1
  case "$kind" in
    indeterminate|tamper) : ;;
    *) return 2 ;;   # closed set — an unknown kind must not create a new lane
  esac
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local row; printf -v row '%s\t%s' "$pr" "$kind"
  _uberdev_goal_append "$tmpdir/goal-$goal_id-verdict-anomalies.tsv" "$row"
}

# uberdev_goal_count_verdict_anomalies GOAL_ID PR KIND
# Rows recorded for (PR, KIND). Prints 0 when the TSV does not exist yet, so the
# caller's `-ge cap` comparison is always arithmetic-safe.
uberdev_goal_count_verdict_anomalies() {
  local goal_id="$1" pr="$2" kind="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-verdict-anomalies.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v p="$pr" -v k="$kind" '$1==p && $2==k {n++} END {print n+0}' "$f"
}

# uberdev_goal_locate_review_pr_audit_by_pr PR_NUM
# PR-keyed companion to uberdev_goal_locate_review_pr_audit. Used by the
# held-PR re-review poll loop (Phase 2 step 2e) which already has the PR
# number in hand and bypasses issue→PR resolution. Returns a stable minified
# controller-state JSON value (not a mutable pathname) or empty when the
# canonical selector reports absent/indeterminate.
#
# rc contract (UNCHANGED, and load-bearing): rc 1 = the PR argument is not an
# integer; rc 0 for every discovery outcome. What is NEW is that each outcome
# also records its name via _uberdev_goal_record_verdict_state, and that a
# verdict already PROVEN before an unrelated cleanup failure is still emitted.
uberdev_goal_locate_review_pr_audit_by_pr() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  if ! command -v discover_review_verdict_json >/dev/null 2>&1 \
     || ! command -v review_verdict_discovery_state >/dev/null 2>&1 \
     || ! command -v recapture_review_verdict_snapshot >/dev/null 2>&1 \
     || ! command -v cleanup_review_verdict_snapshot >/dev/null 2>&1; then
    printf 'goal-state: canonical verdict selector unavailable; treating audit as missing\n' >&2
    _uberdev_goal_record_verdict_state "$pr" selector_unavailable
    return 0
  fi

  local receipt="" discovery_rc=2 discovery_state=indeterminate
  if receipt="$(discover_review_verdict_json "$pr")"; then
    discovery_rc=0
  else
    discovery_rc=$?
  fi
  discovery_state="$(review_verdict_discovery_state "$discovery_rc")"
  case "$discovery_state" in
    absent|indeterminate)
      # Reuse the existing missing/re-review state-machine path — but record
      # WHICH of the two it was, because they demand different recoveries:
      # `absent` converges once a review runs, `indeterminate` never will.
      _uberdev_goal_record_verdict_state "$pr" "$discovery_state"
      return 0
      ;;
    found)
      ;;
    *)
      _uberdev_goal_record_verdict_state "$pr" indeterminate
      return 0
      ;;
  esac

  # #348 finding 2 — the recapture is the tamper detector. Its failure is NOT
  # "no review has run"; it means the private carrier this process just
  # selected was replaced, mutated, symlinked or re-owned underneath us. Split
  # that from the projection failure below and say so on stderr, loudly.
  local recaptured="" stable="" verdict_state="" jq_err
  jq_err="$(mktemp 2>/dev/null)" || jq_err=""
  if ! recaptured="$(recapture_review_verdict_snapshot "$receipt" 2>>"${jq_err:-/dev/null}")" \
     || [ "$recaptured" != "$receipt" ]; then
    printf 'goal-state: TAMPER — the verdict carrier for PR %s did not survive digest/identity recapture; refusing to trust its colour\n' "$pr" >&2
    _uberdev_goal_drain_stderr recapture "$jq_err"
    verdict_state=tamper
  else
    _uberdev_goal_drain_stderr recapture "$jq_err"
    # #348 finding 2 (second half) — the projection's stderr was discarded and
    # its failure absorbed by `|| stable=""`. Keep it in a temp file and surface
    # it: a projection failure on a RECAPTURED carrier means the verdict shape
    # itself is wrong, which is a producer bug worth seeing.
    if ! stable="$(jq -cer '
      {
        schema_version: 1,
        kind: "uberdev-goal-review-verdict",
        run_timestamp: .run_timestamp,
        pr: .pr,
        sha: .artifact_sha,
        audit_state: .audit_state,
        phase2_5_halted: .phase2_5_halted,
        phase2_5_blocker_count: .phase2_5_blocker_count,
        phase2_5_critical_count: .phase2_5_critical_count,
        phase2_5_halted_due_to_overflow: .phase2_5_halted_due_to_overflow
      }
    ' <<<"$recaptured" 2>>"${jq_err:-/dev/null}")"; then
      stable=""
      printf 'goal-state: verdict projection failed for PR %s — the recaptured carrier is not the expected verdict shape\n' "$pr" >&2
      _uberdev_goal_drain_stderr projection "$jq_err"
      verdict_state=projection_failed
    else
      _uberdev_goal_drain_stderr projection "$jq_err"
      verdict_state=found
    fi
  fi

  # The canonical selector's stable carrier is private and caller-owned, so it
  # must always be cleaned. #348 finding 3 — but a cleanup failure is NOT a
  # discovery failure: the verdict above is already PROVEN (recaptured by exact
  # digest+identity, then projected). Discarding it because `rmdir` raced threw
  # away a valid GREEN with no diagnostic on any stream. Emit the proven verdict
  # anyway, record `cleanup_failed` so the consumer can still see that a carrier
  # leaked, and route the cleanup's stderr to the operator (mirroring
  # merge-pipeline/SKILL.md, which surfaces the same cleanup's stderr).
  if ! cleanup_review_verdict_snapshot "$receipt" >/dev/null 2>>"${jq_err:-/dev/null}"; then
    printf 'goal-state: could not clean the verdict carrier for PR %s — a private copy of the selected verdict may survive in TMPDIR\n' "$pr" >&2
    # Only DOWNGRADE a clean discovery. `tamper` and `projection_failed` are
    # strictly more severe than a leaked temp file and must not be overwritten
    # by it — the consumer branches on the worst thing that happened, not the
    # last thing.
    if [ "$verdict_state" = "found" ]; then
      verdict_state=cleanup_failed
    fi
  fi
  _uberdev_goal_drain_stderr cleanup "$jq_err"
  if [ -n "$jq_err" ]; then rm -f "$jq_err"; fi
  _uberdev_goal_record_verdict_state "$pr" "$verdict_state"
  [ -n "$stable" ] || return 0
  printf '%s\n' "$stable"
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

# ---------------------------------------------------------------------------
# TSV state-read helpers (issues #229/#230/#234/#237 — renderer-collision hoist)
#
# These wrap the inline awk state-reads that previously lived in
# skills/goal-pipeline/SKILL.md. SKILL.md is Skill-RENDERED: the loader
# substitutes positional args of $ARGUMENTS into bare `$1`/`$2`/`$3` inside awk
# single-quoted script bodies (issue #222), which corrupts every field ref.
# This file is SOURCED, never rendered, so the awk bodies below use clean,
# SEMANTIC field refs documented by the column contract. Hoisting every awk
# state-read here is the permanent fix: the SKILL.md call sites become helper
# calls with ZERO awk, so the renderer has nothing to corrupt and the
# `-v c1=1 -v c2=2 -v c3=3` workaround is retired.
#
# TSV column contract (goal-<id>-pr-states.tsv AND goal-<id>-issue-states.tsv):
#   $1 = key   — PR number (pr-states) or issue number (issue-states)
#   $2 = state — state-machine label (e.g. pushed-reviewing / merging / solving)
#   $3 = ts    — epoch seconds of the transition
# Tab-separated; `-F'\t'` is the correct parse (a state label never holds a tab).
# NOTE: goal-<id>-batch-prs.tsv is a DIFFERENT 4-col layout (pr<TAB>issue<TAB>ts<TAB>state —
# written by uberdev_goal_register_batch_pr); uberdev_goal_batch_has_pr keys on $1
# (pr is genuinely col 1 there) so the $1==key contract still holds for it.

# _uberdev_goal_ts_in_state FILE KEY STATE [FIRST_WINS]
# Internal: echo the transition ts (epoch int) for rows matching KEY+STATE,
# coerced to 0 when absent/empty. FIRST_WINS=1 takes the EARLIEST matching ts
# (the review-grace contract — issue #222 B8: the grace clock must run from the
# FIRST pushed-reviewing transition, never a later re-entry, or `now - seen_ts`
# never crosses the threshold); the default (last-wins) takes the most recent.
# Path contract: callers pass a fully-constructed FILE path
# ($tmpdir/goal-<id>-{pr,issue}-states.tsv) — mirrored by the three public
# wrappers uberdev_goal_{issue,pr,pr_first}_ts_in_state below.
_uberdev_goal_ts_in_state() {
  local file="$1" key="$2" state="$3" first="${4:-0}"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v k="$key" -v s="$state" -v first="$first" \
    '$1==k && $2==s { if (first!="1" || t=="") t=$3 } END { print t+0 }' "$file"
}

# uberdev_goal_get_issue_state GOAL_ID ISSUE
# Latest issue-machine state for ISSUE (empty when never transitioned). The
# issue-states mirror of uberdev_goal_get_pr_state.
uberdev_goal_get_issue_state() {
  local goal_id="$1" issue="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$issue" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-issue-states.tsv"
  [ -f "$f" ] || return 0
  awk -F'\t' -v i="$issue" '$1==i {state=$2} END {print state}' "$f"
}

# uberdev_goal_issue_ts_in_state GOAL_ID ISSUE STATE
# Latest ts (epoch int, 0 when absent) for ISSUE in STATE on issue-states.tsv.
uberdev_goal_issue_ts_in_state() {
  local goal_id="$1" issue="$2" state="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$issue" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  _uberdev_goal_ts_in_state "$tmpdir/goal-$goal_id-issue-states.tsv" "$issue" "$state" 0
}

# uberdev_goal_pr_ts_in_state GOAL_ID PR STATE
# Latest ts (epoch int, 0 when absent) for PR in STATE on pr-states.tsv.
uberdev_goal_pr_ts_in_state() {
  local goal_id="$1" pr="$2" state="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  _uberdev_goal_ts_in_state "$tmpdir/goal-$goal_id-pr-states.tsv" "$pr" "$state" 0
}

# uberdev_goal_pr_first_ts_in_state GOAL_ID PR STATE
# EARLIEST ts (epoch int, 0 when absent) for PR in STATE on pr-states.tsv.
# First-wins is load-bearing for the review-grace window (issue #222 B8).
uberdev_goal_pr_first_ts_in_state() {
  local goal_id="$1" pr="$2" state="$3"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  _uberdev_goal_ts_in_state "$tmpdir/goal-$goal_id-pr-states.tsv" "$pr" "$state" 1
}

# uberdev_goal_batch_has_pr GOAL_ID PR
# rc 0 iff a row keyed on PR exists in goal-<id>-batch-prs.tsv; rc 1 when PR is
# absent OR the registry file does not exist yet. Replaces the inline
# `[ ! -f tsv ] || awk ... exit !found` idempotent-registration guard.
uberdev_goal_batch_has_pr() {
  local goal_id="$1" pr="$2"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  _uberdev_goal_validate_int "$pr" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -f "$f" ] || return 1
  awk -F'\t' -v p="$pr" '$1==p {found=1; exit} END {exit !found}' "$f"
}

# uberdev_goal_count_distinct_prs GOAL_ID
# Count of DISTINCT PR numbers recorded in goal-<id>-pr-states.tsv (0 when the
# file is absent/empty). Returns a CLEAN integer — the prior
# `awk '{print $1}' | sort -u | wc -l` form padded with leading spaces on
# macOS/BSD `wc -l`, and the convergence check at SKILL.md compares this with
# `=` (string equality) against a grep-based terminal count, so the padding
# could falsely fail convergence on macOS. The dedup-and-count awk avoids both
# the padding and the extra sort+wc subprocesses.
uberdev_goal_count_distinct_prs() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-pr-states.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -F'\t' '$1 != "" && !seen[$1]++ {n++} END {print n+0}' "$f"
}

# uberdev_goal_count_resolved_issues GOAL_ID
# Count of issue-states.tsv rows in a resolved terminal state (resolved or
# resolved-by-no-action) — a print_summary stat. Row-count semantics preserved
# from the prior `awk ... {print $1} | grep -c .` form (each issue resolves
# once). 0 when the file is absent.
uberdev_goal_count_resolved_issues() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-issue-states.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -F'\t' '$2=="resolved" || $2=="resolved-by-no-action" {n++} END {print n+0}' "$f"
}

# uberdev_goal_count_failed_issues GOAL_ID
# Count of issue-states.tsv rows in failed. Used by the Phase-3 convergence
# gate so a terminal solver failure cannot be misread as clean convergence.
uberdev_goal_count_failed_issues() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1   # #156
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-issue-states.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -F'\t' '$2=="failed" {n++} END {print n+0}' "$f"
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
# GitHub-native issue->PR resolver. Echoes the highest OPEN PR number that
# closes issue N (its `closingIssuesReferences` carries the `Closes #N` link
# every solver PR adds); if no closes-match exists it FALLS BACK to the highest
# OPEN PR whose head branch is `<type>/N-…` for any conventional type in
# _UBERDEV_GOAL_HEAD_REF_TYPES. Replaces the retired solve-bg `pushed PR #N`
# log parser: that marker has ZERO producers and `claude --bg`
# stdout is a detached banner on CLI 2.1.150, so the loop keying on it never
# advanced (issue #180).
#
# #290.4 (MAJOR) — bind to the LIVE PR, prefer the authoritative link:
#   (a) `--state open` (was `--state all`): a stale CLOSED `<type>/N-` branch from
#       a prior failed attempt, or a re-dispatched issue's abandoned PR, could
#       otherwise win the `max` and corrupt batch-registry accounting / verdict
#       location (the locator keys on this result). Merge-completion detection
#       is unaffected — uberdev_goal_pr_state_gh / pr_is_merged issue their own
#       `gh pr view <pr>` against the known PR number, never this finder.
#   (b) prefer the `closingIssuesReferences` match over the `<type>/N-` head-ref
#       heuristic: the head-ref arm is a best-effort fallback for PRs whose
#       Closes-link was dropped, but a branch *named* fix/N- that does NOT
#       close N (a re-used branch) must never outrank a real closes-match. The
#       jq below computes both maxes and takes `$byclose // $byhead`.
#
# ISSUE_NUM is digits-only validated BEFORE interpolation into the gh --jq
# filter (R3 gh-argument-injection guard — the same int gate Phase 0 applies
# to every positional). The filter runs inside gh's own jq (no external pipe),
# so gh progress bytes cannot pollute the result. Empty stdout + rc 0 when no
# PR exists yet — a not-yet-pushed solver must NOT read as an error. A gh
# failure also yields empty (fail-open; the caller treats "no PR" as "keep
# waiting", bounded by the per-issue solve-timeout) BUT now ALSO records a
# consecutive-failure tick (#290.3) so uberdev_goal_gh_failure_breaker_check
# can fire gh_api_failed before the solve-timeout misattributes the outage as
# "agent idle / no PR".
uberdev_goal_find_pr_for_issue() {
  local n="$1"
  _uberdev_goal_validate_int "$n" || return 1
  # `any(.closingIssuesReferences[]?; .number == N)` is deliberate: a bare
  # `.closingIssuesReferences[]?.number == N` yields an EMPTY stream when the
  # array is empty (a PR whose Closes-link was dropped). `any/2` returns a
  # concrete `false` on an empty generator, so the select stays boolean. The
  # input array is bound to `$prs` so both the closes-match and head-ref maxes
  # read the SAME list (jq cannot reference the original input after the first
  # `[...]` reduction).
  #
  # Capture gh's rc so a gh FAILURE (auth expiry, rate-limit 403, network) is
  # surfaced as a one-line breadcrumb rather than masquerading as "no PR yet"
  # (rc 0 + empty) — without it a transient gh outage stalls the goal until the
  # 150m solve-timeout with a MISattributed "agent idle" diagnostic. Still
  # fail-open (return empty, rc 0) so the caller keeps waiting/re-polls.
  local out rc
  out="$(gh pr list --state open --limit 200 \
    --json number,closingIssuesReferences,headRefName \
    --jq "$(_uberdev_goal_pr_for_issue_jq "$n")" \
    2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'goal-state: gh pr list failed (rc=%s) resolving PR for issue %s; treating as no-PR-yet (will re-poll)\n' "$rc" "$n" >&2
    _uberdev_goal_record_gh_failure                                # #290.3
    return 0
  fi
  _uberdev_goal_reset_gh_failure                                   # #290.3 — gh healthy
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Per-pass PR snapshot (#301 speedup finding 1).
#
# THE DEFECT. Phase 2a called uberdev_goal_find_pr_for_issue once PER ISSUE,
# and each call ran its OWN `gh pr list --state open --limit 200`. The response
# is issue-independent — the SAME 200-PR page, re-fetched N times every 60s
# poll, for the whole life of the goal. On a 6-issue cycle that is 6 identical
# round-trips a minute against the API budget the watch loop is most sensitive
# to, and it also means the N answers within one pass can disagree (a PR that
# opens mid-pass is visible to issue 5 and not to issue 1), so the pass is not
# even internally consistent.
#
# THE FIX. Fetch the page ONCE per pass into a snapshot, then resolve every
# issue against that snapshot in-process. One round-trip per pass, and every
# issue in the pass sees the same GitHub state.
# ---------------------------------------------------------------------------

# _UBERDEV_GOAL_HEAD_REF_TYPES — the branch-name types the head-ref FALLBACK arm
# below will accept. It has exactly ONE consumer, the `test("^(…)/${n}-")` call
# inside _uberdev_goal_pr_for_issue_jq, so the syntax that governs it is jq's
# Oniguruma — there is no ERE call site.
#
# The set is the Conventional Commits vocabulary because that is the shape the
# PRODUCER emits: plugins/uberdev/skills/solve-fleet/workflow.js tells every
# solver to name its branch `<type>/<issue>-<short-slug>`, once in the solve
# prompt's branch step and again in the chain's `git worktree add -b` command,
# defining `<type>` as "the conventional-commit type of the change".
#
# UNGUARDED RESIDUAL — producer and consumer are NOT mechanically joined. In
# workflow.js `<type>` is free text the solver agent picks at run time: it is
# never enumerated there, never validated, and nothing compares it against this
# list. A solver that writes `hotfix/N-…`, `bugfix/N-…` or `feature/N-…` still
# produces a head this arm cannot see, and on a partial PR (which carries no
# `Closes #N`) that is the whole linkage gone. Binding the producer to this list,
# or adding a drift guard across the two, is follow-up work; until it exists,
# read a head-ref miss on an off-vocabulary type as this known gap rather than as
# a bug in the jq.
#
# ENUMERATED, never an open `[a-z]+`: the arm is a best-effort guess with no
# authoritative link behind it, so the namespaces it may guess from have to be
# named. Leave it open and a `notes/N-…`, `wip/N-…` or personal `<handle>/N-…`
# branch — none of which is the solver's PR — silently wins the fallback and the
# goal binds the issue to the wrong PR.
_UBERDEV_GOAL_HEAD_REF_TYPES='feat|fix|refactor|test|docs|chore|perf|build|ci|style|revert'

# _uberdev_goal_pr_for_issue_jq ISSUE_NUM — the SSOT ranking program shared by
# the live finder and the snapshot finder, so the two can never disagree about
# which PR belongs to an issue. `any/2` (not `.closingIssuesReferences[]?.number
# == N`) is deliberate: a bare stream yields EMPTY for a PR whose Closes-link was
# dropped, while any/2 returns a concrete false, keeping `select` boolean.
#
# The head-ref arm matches EVERY conventional type, not `feat/` alone. Two
# reasons, and this consumer is widened FIRST so neither can strand a PR:
#   (1) a partial-delivery PR carries no `Closes #N` at all, by design (#554) —
#       a PR must not auto-close an issue it did not finish — so its head ref is
#       the ONLY issue->PR link it has, and the producer types that branch for
#       whatever change it made, not `feat/` by default;
#   (2) defence in depth for the historical shape BT27 pins, a PR whose
#       Closes-link was dropped or edited away: there too the head ref is all
#       that is left, and a fix, refactor or chore PR is exactly as real as a
#       feature PR.
# When this arm loses a live PR the watch loop reads "no PR yet", and under
# /goal that is terminal on the spot rather than the start of a grace period.
# goal-pipeline/workflow.js runs EVERY watch pass with
# UBERDEV_GOAL_SOLVERS_SETTLED=1 — unconditionally, no branch and no config key,
# because the nested fleet call is awaited — so the settled arm in
# lib/goal-watch.sh transitions the issue solving->failed and calls
# _uberdev_goal_phase2_release_claim (dropping the `uberdev:active` label and the
# assignee) on the FIRST tick (RFC 0015 §5). Nor is that self-healing: the
# `failed` row it writes is what uberdev_goal_count_failed_issues counts, and
# lib/goal-phase3.sh's terminal region fires the `solver_failed` circuit breaker
# and exits 1 on any non-zero count — a gate that sits ABOVE the max-cycles and
# convergence gates and is keyed on the whole GOAL_ID, not on this cycle. So one
# lost PR halts the ENTIRE /goal run, taking every other issue in the cycle down
# with it, while the real PR sits open and its issue reads as a failed solve.
# Nothing re-queues it either: Phase 3 collects the next cycle's candidates only
# from $FINDING_LABEL issues, never the original one.
# _UBERDEV_GOAL_SOLVE_TIMEOUT (150m) is NOT the symptom to look for — that arm
# answers a detached-solver liveness question and is reachable only where the
# env var is unset: the Workflow driver always sets it, the documented
# no-Workflow fallback fence in goal-pipeline/SKILL.md does not.
#
# The trailing `-` after ${n} is load-bearing and survives the widening: it is
# what keeps `fix/30-x` out of issue 300 (BT73/BT73d).
_uberdev_goal_pr_for_issue_jq() {
  local n="$1"
  printf '%s' ". as \$prs
          | ([\$prs[] | select(any(.closingIssuesReferences[]?; .number == ${n})) | .number] | max) as \$byclose
          | ([\$prs[] | select(.headRefName | test(\"^(${_UBERDEV_GOAL_HEAD_REF_TYPES})/${n}-\")) | .number] | max) as \$byhead
          | (\$byclose // \$byhead // empty)"
}

# uberdev_goal_pr_list_snapshot
# One `gh pr list` for the whole poll pass. Prints the raw JSON array on stdout.
# Same fail-open contract as uberdev_goal_find_pr_for_issue: a gh failure prints
# NOTHING, ticks the consecutive-failure counter (so the #290.3 breaker can
# fire), and still returns 0 — callers must treat empty as "snapshot
# unavailable, keep waiting", never as "no PRs exist".
uberdev_goal_pr_list_snapshot() {
  local out rc
  out="$(gh pr list --state open --limit 200 \
    --json number,closingIssuesReferences,headRefName 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'goal-state: gh pr list snapshot failed (rc=%s); PR resolution unavailable this pass (will re-poll)\n' "$rc" >&2
    _uberdev_goal_record_gh_failure
    return 0
  fi
  _uberdev_goal_reset_gh_failure
  printf '%s' "$out"
}

# uberdev_goal_find_pr_for_issue_from_json ISSUE_NUM SNAPSHOT_JSON
# Snapshot-resolving twin of uberdev_goal_find_pr_for_issue: identical ranking,
# ZERO network calls. Empty stdout + rc 0 when the snapshot is empty (caller
# already knows the fetch failed and has ticked the counter) or when no PR in
# the snapshot matches. rc 1 only for a non-integer issue argument, matching the
# live finder's R3 gh-argument-injection gate.
uberdev_goal_find_pr_for_issue_from_json() {
  local n="$1" snapshot="${2:-}"
  _uberdev_goal_validate_int "$n" || return 1
  [ -n "$snapshot" ] || return 0
  local out
  out="$(jq -r "$(_uberdev_goal_pr_for_issue_jq "$n")" <<<"$snapshot" 2>/dev/null)" || return 0
  # jq prints the literal `null` for a `max` over an empty array that escaped
  # the `// empty` guard on a malformed snapshot; never let that reach a caller
  # that only checks for emptiness before feeding the value to `gh`.
  [ "$out" = "null" ] && return 0
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
    _uberdev_goal_record_gh_failure                                # #290.3
    return 0
  fi
  _uberdev_goal_reset_gh_failure                                   # #290.3 — gh healthy
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

# ---------------------------------------------------------------------------
# Consecutive gh-failure breaker (#290.3 MAJOR).
# The Phase-2a/2d polling helpers (find_pr_for_issue / pr_state_gh) fail OPEN
# on a gh outage — the right call for a transient blip (just re-poll). But a
# SUSTAINED outage left a solved-and-pushed issue to be abandoned to `failed`
# after the 150m solve-timeout, or churned a merged PR, because gh_api_failed
# only guarded the Phase-3 `gh issue list`. These helpers maintain a tiny
# single-int counter keyed on UBERDEV_GOAL_ID: every helper failure bumps it,
# every helper success resets it, and the breaker-check fires gh_api_failed
# once the count crosses the threshold. The counter file lives alongside the
# other per-goal state under $UBERDEV_TMPDIR and is best-effort (a write
# failure must never crash the fail-open helper that called it — the goal still
# rides the timeout as before, just without the early breaker).
# ---------------------------------------------------------------------------

# _uberdev_goal_gh_failure_counter_path  — internal path resolver. Empty
# stdout (rc 1) when no valid UBERDEV_GOAL_ID is in scope (so callers no-op).
_uberdev_goal_gh_failure_counter_path() {
  local goal_id="${UBERDEV_GOAL_ID:-}"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  printf '%s' "$tmpdir/goal-$goal_id-gh-failures.txt"
}

# _uberdev_goal_record_gh_failure  — bump the consecutive-failure counter.
# Best-effort: never returns non-zero in a way that disturbs the fail-open
# caller (a counter-write failure is logged once, the goal still re-polls).
_uberdev_goal_record_gh_failure() {
  local f; f="$(_uberdev_goal_gh_failure_counter_path)" || return 0
  local cur=0
  [ -r "$f" ] && cur="$(cat "$f" 2>/dev/null)"
  _uberdev_goal_validate_int "$cur" || cur=0
  printf '%s\n' "$(( cur + 1 ))" > "$f" 2>/dev/null || \
    printf 'goal-state: could not record gh-failure tick (unwritable UBERDEV_TMPDIR?)\n' >&2
  return 0
}

# _uberdev_goal_reset_gh_failure  — clear the counter after a healthy gh call.
_uberdev_goal_reset_gh_failure() {
  local f; f="$(_uberdev_goal_gh_failure_counter_path)" || return 0
  # Only rewrite when a non-zero count is on disk — avoids a needless write
  # (and its potential ENOSPC noise) on every healthy poll once the file is 0.
  [ -r "$f" ] || return 0
  local cur; cur="$(cat "$f" 2>/dev/null)"
  [ "$cur" = "0" ] && return 0
  printf '0\n' > "$f" 2>/dev/null || true
  return 0
}

# uberdev_goal_gh_failure_count GOAL_ID
# Public read-side view of the consecutive gh-failure counter. Phase 2 needs this
# to distinguish "no PR exists" from "PR lookup was unavailable" after
# uberdev_goal_find_pr_for_issue fail-opens to empty stdout.
uberdev_goal_gh_failure_count() {
  local goal_id="${1:?goal_id required}"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-gh-failures.txt"
  [ -r "$f" ] || { printf '0'; return 0; }
  local count
  count="$(cat "$f" 2>/dev/null)" || count=0
  _uberdev_goal_validate_int "$count" || count=0
  printf '%s' "$count"
}

# uberdev_goal_gh_failure_breaker_check GOAL_ID [THRESHOLD]
# rc 0 (FIRE) iff the consecutive gh-failure counter for GOAL_ID is >= THRESHOLD
# (default _UBERDEV_GOAL_MAX_GH_FAILURES). On fire, emits ONE goal_circuit_breaker
# audit event {"reason":"gh_api_failed","phase":"poll","consecutive_failures":N}
# — mirrors uberdev_goal_barrier_breaker_check's shape so the watch loop can
# treat both identically (print_summary + exit). rc 1 when under threshold or
# the counter file is absent (no failures recorded yet). Pure read of the
# counter file + one audit append; no gh calls.
uberdev_goal_gh_failure_breaker_check() {
  local goal_id="${1:?goal_id required}"
  local threshold="${2:-${_UBERDEV_GOAL_MAX_GH_FAILURES:-5}}"
  _uberdev_goal_validate_id "$goal_id" || return 1
  _uberdev_goal_validate_int "$threshold" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local f="$tmpdir/goal-$goal_id-gh-failures.txt"
  [ -r "$f" ] || return 1
  local count; count="$(cat "$f" 2>/dev/null)"
  _uberdev_goal_validate_int "$count" || return 1
  [ "$count" -ge "$threshold" ] || return 1
  uberdev_goal_audit goal_circuit_breaker \
    "$(printf '{"reason":"gh_api_failed","phase":"poll","consecutive_failures":%s}' "$count")"
  return 0
}

# uberdev_goal_agent_busy_for_issue ISSUE_NUM   (issue #180)
# rc 0 iff the resolved backend still has an active solver for issue N:
# wezterm polls `claude agents --json` for a live session in the
# solver worktree; background polls the recorded wrapper PID. Phase 2a uses this to disambiguate "solver still working,
# no PR yet" from "solver died" before the per-issue solve-timeout fires.
# Deliberately NOT used to gate review-readiness: the leaf solver routinely
# goes idle for ~20m while its OWN finish-branch /review-pr runs, so keying
# re-review on liveness fires redundant reviews and prematurely red-holds a PR
# whose GREEN verdict simply has not landed (Phase 2b uses a time-grace +
# verdict-poll model instead). Missing/unreadable state, dead PIDs, empty
# lists, malformed JSON, and CLI failures all yield rc 1 (not busy), the
# fail-safe default for this contract.
uberdev_goal_agent_busy_for_issue() {
  local n="$1"
  _uberdev_goal_validate_int "$n" || return 1
  # Backend-aware liveness. wezterm dispatches named sessions queryable via
  # `claude agents --json`; background dispatch tracks only a wrapper PID. The
  # richer status-JSON arm belonged to the codex transport and went with it in
  # #381. Fail-safe default: missing status file / unreadable PID / dead process
  # all yield rc 1 (not busy), so goal proceeds rather than stalling on a lost
  # session.
  case "${UBERDEV_RESOLVED_BACKEND:-}" in
    background)
      local pid
      pid="$(_uberdev_goal_pid_for_issue "$n" 2>/dev/null)" || return 1
      [ -n "$pid" ] || return 1
      kill -0 "$pid" 2>/dev/null
      return $?
      ;;
    workflow)
      # RFC 0015 — a Workflow solver is an agent inside the calling session's
      # Workflow runtime. It has NO `claude agents` session, NO worktree named
      # `solve-issue-<n>` in the shape this probe matches, and NO PID stash. The
      # pre-existing `*)` catch-all sent it to `claude agents --json`, which
      # answers "not busy" for a perfectly healthy fleet — so Phase 2a's
      # no-PR-yet arm fell straight through to the SOLVE_TIMEOUT path and would
      # mark a live solver `failed`.
      #
      # rc 1 (not busy) is still the honest answer, because this shell genuinely
      # cannot observe the fleet — but it is now a DELIBERATE answer with a
      # breadcrumb, not an accident of a wrong probe. The authoritative progress
      # signal for a Workflow run is the structured return the script hands
      # back, plus `gh pr list`; liveness polling is not part of that contract.
      printf 'goal-state: backend=workflow has no pollable per-issue liveness (the fleet is owned by the Workflow runtime); reporting not-busy for issue %s — PR existence via gh is the authoritative progress signal\n' "$n" >&2
      return 1
      ;;
    wezterm|*)
      if claude agents --json 2>/dev/null | jq -e --arg n "$n" '
        any(.[]?;
            (((.cwd // "") | rtrimstr("/")) | endswith("solve-issue-" + $n))
            # jq treats # as a comment to end of line, so the marker sits
            # directly on the declaration instead of resolving forward — an
            # @anchor here would be a substring scan over the rest of the file.
            # NOTE: no apostrophes below — this whole jq program is a
            # single-quoted shell string, and one would terminate it.
            # DECLARED DIVERGENCE, not intent (#370 rank 7): the lifecycle
            # classifier in agent-dispatch.sh treats `queued` as LIVE; this
            # probe does not. Whether `queued` SHOULD be live is a behaviour
            # question of its own.
            # CONTRACT: agent-liveness-value -queued
            and ((.status // "") | test("^(busy|running|starting|working)$")))' \
        >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
  esac
}

# uberdev_goal_review_pr_in_flight PR_NUM   (issue #220, AC ❷)
# rc 0 means a review-pr dispatch must be treated as in-flight. For
# wezterm this means `claude agents --json` shows a live
# /uberdev:review-pr <pr> agent (status ∈ busy|running|starting|working). For
# background it means the tracked wrapper PID is alive. The codex arm used to
# return in-flight for ambiguous running status files so Phase 2b/2c deferred
# duplicate dispatch rather than launching a second reviewer while the status
# writer might still be updating; it was removed with the transport (#381).
# --argjson safely passes the validated PR int as a JSON number. The regex uses
# an unanchored substring match (no leading ^) because the agent's .name field
# is the verbatim prompt body, and post-#235 dispatch bodies open with a
# natural-language imperative ("Invoke the slash command /uberdev:review-pr
# <pr> now. ...") rather than a bare slash. The trailing ($|[^0-9]) boundary is
# the load-bearing anti-collision guard: it rejects 21 matching 218, 42 matching
# 421, etc. (.name // "") + (.status // "") are null-safe (security.md).
uberdev_goal_review_pr_in_flight() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  # wezterm has `claude agents --json`; background has only the status JSON
  # written by dispatch.sh. For that PID-based backend, review-pr in-flight
  # means the tracked wrapper process for this PR is still alive. The
  # status-JSON arm that deferred on ambiguity belonged to the codex transport
  # and was removed with it (#381).
  case "${UBERDEV_RESOLVED_BACKEND:-}" in
    background)
      local pid
      pid="$(_uberdev_goal_pid_for_issue "$pr" 2>/dev/null)" || return 1
      [ -n "$pid" ] || return 1
      kill -0 "$pid" 2>/dev/null
      return $?
      ;;
    workflow)
      # RFC 0015 — same leaf-constraint reasoning as agent_busy_for_issue: a
      # Workflow-dispatched /review-pr is not a `claude agents` session, so the
      # fall-through probe below cannot see it and would answer "not in flight",
      # inviting a duplicate reviewer on top of a live one. Report NOT-in-flight
      # (rc 1) rather than deferring forever: the caller's per-PR review-attempt
      # cap (_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS) is what bounds re-dispatch on
      # this backend, and a permanent rc 0 here would instead spin the PR in
      # pushed-reviewing until the 4h stuck_loop. Breadcrumb so the choice is
      # visible in a post-mortem.
      printf 'goal-state: backend=workflow has no pollable review-pr in-flight signal; reporting not-in-flight for PR %s — the per-PR review-attempt cap bounds re-dispatch\n' "$pr" >&2
      return 1
      ;;
  esac
  if claude agents --json 2>/dev/null | jq -e --argjson pr "$pr" '
    [ .[]?
      | select(
          ((.name // "") | test("/uberdev:review-pr " + ($pr|tostring) + "($|[^0-9])"))
          # DECLARED DIVERGENCE, not intent (#370 rank 7): `queued` is LIVE to
          # the classifier in agent-dispatch.sh and not-live here. See the
          # sibling note on uberdev_goal_agent_busy_for_issue. This is a jq
          # comment inside a single-quoted shell string — no apostrophes.
          # CONTRACT: agent-liveness-value -queued
          and ((.status // "") | test("^(busy|running|starting|working)$"))
        )
    ] | length > 0' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Field probe: lastActivityAt absent (claude agents --json on CLI 2.1.150 exposes
# only pid/cwd/kind/startedAt/sessionId/name/status — startedAt is start-time,
# not last-activity; no near-equivalent timestamp). Activity proxy:
# 1) PER-AGENT stdout-log mtime (preferred — multi-parallel-safe, see B10)
# 2) goal-global audit-log row-count (fallback — degraded under N > 1 agents)
#
# B10 (post-impl-review): the previous audit-log row-count proxy was
# goal-global — one shared file across all parallel agents. Under multi-
# parallel /turbo, any agent's row append refreshed the counter, suppressing
# the stuck-on-dialog signal for every OTHER agent. Switch the primary
# proxy to mtime of the per-issue stdout file
# (`$UBERDEV_TMPDIR/solve-bg-stdout-<ISSUE>.log` — canonical name per
# lib/dispatch.sh lines 334/453/609), which is genuinely per-agent. When the
# caller has the issue number in scope (the common path via
# _uberdev_goal_any_attempt_stuck, which iterates batch-prs.tsv), pass it as
# arg 2 so the helper reads stdout mtime. When the issue is absent (legacy
# single-arg call sites + BT79 fixture), fall back to the audit-log row-
# count proxy with a comment explaining the degradation.
#
# uberdev_goal_agent_stuck_on_dialog PID [ISSUE]   (issue #220, AC ❸)
# rc 0 iff the agent's activity proxy is unchanged over a 60s window AND
# its status is busy/running/starting/working. Writes prior-sample state to
# the run-state sidecar (PRIOR_LAST_ACTIVITY_<pid>, FIRST_DIALOG_TS_<pid>)
# so the detector survives the directive-emitter constraint (in-loop timers
# are dead across fresh-shell phase fences — see memory
# project_uberdev_pipeline_directive_emitter). First sample writes sidecar
# and returns 1 (not-yet-stuck); subsequent samples compare against the
# persisted prior sample.
uberdev_goal_agent_stuck_on_dialog() {
  local pid="$1" issue="${2:-}"
  _uberdev_goal_validate_int "$pid" || return 1
  # #270: NOT named `status` — under /bin/zsh (which runs the goal-pipeline
  # SKILL.md bash fences that source this lib) `status` is a special read-only
  # parameter (an alias for `$?`), so `local status` hard-errors `read-only
  # variable: status` and aborts the function non-zero on its FIRST statement,
  # before the body runs. That alone kept the agent_stuck_on_dialog circuit
  # breaker from ever firing under zsh. `agent_status` is an ordinary name in
  # both shells.
  local agent_status now first_seen prior tmpdir goal_id audit row_count
  agent_status="$(claude agents --json 2>/dev/null | jq -r --argjson pid "$pid" '
    .[]? | select(.pid? == $pid) | .status // ""' 2>/dev/null)"
  [ -n "$agent_status" ] || return 1
  # DECLARED DIVERGENCE, not intent (#370 rank 7): `queued` is LIVE to
  # agent-dispatch.sh's classifier and not-live here.
  # CONTRACT: agent-liveness-value -queued !case-arm
  case "$agent_status" in
    busy|running|starting|working) : ;;
    *) return 1 ;;
  esac
  tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  goal_id="${UBERDEV_GOAL_ID:-}"
  _uberdev_goal_validate_id "$goal_id" || return 1
  # B10: primary proxy — per-issue stdout-log mtime (multi-parallel-safe).
  # Fallback: goal-global audit-log row-count (degraded under N>1 agents
  # because any agent's row append refreshes the counter for ALL agents).
  row_count=""
  if [ -n "$issue" ] && _uberdev_goal_validate_int "$issue"; then
    local stdout_log="$tmpdir/solve-bg-stdout-$issue.log"
    if [ -r "$stdout_log" ]; then
      row_count="$(stat -c %Y "$stdout_log" 2>/dev/null || stat -f %m "$stdout_log" 2>/dev/null)"
    fi
  fi
  if [ -z "$row_count" ]; then
    audit="$tmpdir/goal-$goal_id.jsonl"
    if [ -r "$audit" ]; then
      row_count="$(wc -l < "$audit" 2>/dev/null | tr -d ' ')"
    else
      row_count="0"
    fi
  fi
  _uberdev_goal_validate_int "$row_count" || row_count="0"
  now="$(date +%s)"
  local _prior_key="PRIOR_LAST_ACTIVITY_${pid}"
  local _first_key="FIRST_DIALOG_TS_${pid}"
  # Dual-shell indirect read (#270): bash `${!var}` indirect expansion is a hard
  # `bad substitution` error under zsh — and this helper is re-sourced inside the
  # goal-pipeline SKILL.md bash fences, which run under /bin/zsh on macOS. The
  # parse error aborted uberdev_goal_agent_stuck_on_dialog non-zero every poll, so
  # the agent_stuck_on_dialog circuit breaker could never fire.
  # _uberdev_goal_indirect_get branches on the live shell (zsh `${(P)name}` / bash
  # `${!name}`) using only native parameter expansion — see its header for why no
  # shell-evaluation primitive is used (the T3 hard rule, goal.test.sh G19).
  prior="$(_uberdev_goal_indirect_get "$_prior_key")"
  first_seen="$(_uberdev_goal_indirect_get "$_first_key")"
  if [ -z "$prior" ]; then
    printf -v "$_prior_key" '%s' "$row_count"
    printf -v "$_first_key" '%s' "$now"
    export "$_prior_key" "$_first_key"
    return 1
  fi
  if [ "$row_count" = "$prior" ] && [ -n "$first_seen" ] && [ "$(( now - first_seen ))" -ge "$_UBERDEV_GOAL_STUCK_DIALOG_SECS" ]; then
    return 0
  fi
  if [ "$row_count" != "$prior" ]; then
    printf -v "$_prior_key" '%s' "$row_count"
    printf -v "$_first_key" '%s' "$now"
    export "$_prior_key" "$_first_key"
  fi
  return 1
}

# _uberdev_goal_any_attempt_stuck PR_NUM   (issue #220, AC ❸)
# Iterates prior /review-pr attempts for this PR from the per-goal attempts
# TSV; resolves each to a PID via solve-bg-status-<ISSUE>.json; calls
# uberdev_goal_agent_stuck_on_dialog for each; returns 0 if ANY prior attempt
# is stuck.
_uberdev_goal_any_attempt_stuck() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local goal_id="${UBERDEV_GOAL_ID:-}"
  [ -n "$goal_id" ] || return 1
  # Source: batch-prs.tsv (4 cols: pr<TAB>issue<TAB>ts<TAB>state). Matches
  # the PID-stash targeting model (spec §3.6 F5) — single-slot PID per issue;
  # review-pr-attempts.tsv is a 2-col attempt counter (pr<TAB>count) and is
  # NOT the right source for the PR→issue lookup (issue #220 fix-up).
  local batch_tsv="$UBERDEV_TMPDIR/goal-$goal_id-batch-prs.tsv"
  [ -f "$batch_tsv" ] || return 1
  local row_pr issue _ts _state pid
  while IFS=$'\t' read -r row_pr issue _ts _state; do
    [ "$row_pr" = "$pr" ] || continue
    # R1 SSOT (issue #220 simplify pass): PID extraction via shared helper.
    pid="$(_uberdev_goal_pid_for_issue "$issue")" || continue
    # B10 (post-impl-review): pass $issue so the detector uses per-issue
    # stdout mtime instead of the goal-global audit-log row-count proxy.
    # Under multi-parallel /turbo, the row-count proxy would be refreshed
    # by ANY agent's audit append — masking a real per-agent stall.
    if uberdev_goal_agent_stuck_on_dialog "$pid" "$issue"; then
      return 0
    fi
  done < "$batch_tsv"
  return 1
}

# _uberdev_goal_locked_marker_for_pr_fresh PR_NUM GRACE_SECS   (issue #220, AC ❶)
# rc 0 iff a `.uberdev/runs/*/locked` marker with sibling pr-context.json
# matching this PR exists AND its mtime is within GRACE_SECS. Each candidate
# is guarded through _uberdev_dispatch_tmp_target_safe (security.md
# precedent). --argjson passes the digits-only validated PR as a JSON number.
#
# B1 (post-impl-review): mirror the 4-glob candidate set from
# uberdev_goal_locate_review_pr_audit_by_pr so worktree-mirror markers
# (.claude/worktrees/*/.uberdev/runs/..., .worktrees/*/..., worktrees/*/...)
# are discovered alongside the project-root path. Without this, a /review-pr
# running inside the standard worktree never registers as "in-flight" for the
# /goal poll loop in the project-root checkout, defeating AC ❶.
_uberdev_goal_locked_marker_for_pr_fresh() {
  local pr="$1" grace="$2"
  _uberdev_goal_validate_int "$pr" || return 1
  _uberdev_goal_validate_int "$grace" || return 1
  local now matched_mtime marker_dir ctx mtime pr_match
  now="$(date +%s)"
  matched_mtime=0
  # R2 SSOT (issue #220 simplify pass): glob set read from
  # _UBERDEV_GOAL_WORKTREE_PREFIXES. #270/#290.2 cross-shell: route the dir-glob
  # through _uberdev_goal_glob_worktree — the bare `${prefix}` glob silently
  # matched no worktree mirror under the zsh Bash tool, so a /review-pr running
  # in a worktree never registered as in-flight for the project-root poll loop
  # (the exact gap AC ❶ was filed to close, latent under zsh until now).
  while IFS= read -r marker_dir; do
    [ -d "$marker_dir" ] || continue
    ctx="${marker_dir}pr-context.json"
    [ -r "${marker_dir}locked" ] && [ -r "$ctx" ] || continue
    _uberdev_dispatch_tmp_target_safe "$ctx" || continue
    pr_match="$(jq -r --argjson pr "$pr" 'select(.pr == $pr) | .pr // empty' < "$ctx" 2>/dev/null)" || continue
    [ "$pr_match" = "$pr" ] || continue
    mtime="$(stat -c %Y "${marker_dir}locked" 2>/dev/null || stat -f %m "${marker_dir}locked" 2>/dev/null || echo 0)"
    _uberdev_goal_validate_int "$mtime" || continue
    [ "$mtime" -gt "$matched_mtime" ] && matched_mtime="$mtime"
  done < <(_uberdev_goal_glob_worktree ".uberdev/runs/*/")
  [ "$matched_mtime" -gt 0 ] || return 1
  [ "$(( now - matched_mtime ))" -lt "$grace" ]
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
#
# #290.2 (CRITICAL) — worktree-anchored audit read. /merge runs in its OWN
# dispatched worktree (cwd = the merge agent's `solve-issue-<pr>` worktree per
# lib/dispatch.sh), so it writes the `merge_executed` / `pr_parked` rows to
# THAT worktree's relative `.uberdev/audit.jsonl`. The /goal watcher polls from
# the project-root checkout, where the bare relative `.uberdev/audit.jsonl`
# resolved to a DIFFERENT (often absent / stale) file. The gh-MERGED happy path
# (tier 1) masks this, but on the conflict / hook-failed path tier 2 read the
# wrong file → returned `missing` forever → the merge_failed breaker never fired
# and the PR looped the 60m merge-timeout. Fix: scan the SAME worktree-mirror
# glob set the verdict locator uses (_UBERDEV_GOAL_WORKTREE_PREFIXES), passing
# every readable candidate to one `jq --slurp` in glob order — the empty
# (cwd / project-root) prefix FIRST, the worktree mirrors AFTER, so the merge
# agent worktree's row lands LAST and `last` (the existing, BT46-locked
# line-order tiebreak) picks it over any stale project-root row. No `.ts`
# dependency (BT46 fixtures carry none) — within-file selection stays line-order.
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
  # #290.2 — collect every readable .uberdev/audit.jsonl across the worktree-
  # mirror prefixes (empty prefix = project root, first; worktree mirrors after)
  # via the cross-shell glob helper (the bare `${prefix}` glob does NOT expand
  # under the zsh Bash tool — see _uberdev_goal_glob_worktree).
  local candidate audit_files=()
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && audit_files+=("$candidate")
  done < <(_uberdev_goal_glob_worktree ".uberdev/audit.jsonl")
  [ "${#audit_files[@]}" -gt 0 ] || { printf 'missing\n'; return 0; }
  # Pick the LAST matching JSONL line (most recent) across all candidate files.
  # jq --slurp concatenates the files into ONE array in argument order, so the
  # cross-file ordering is glob order (cwd first, worktrees after) and `last`
  # picks the merge agent worktree's row over a stale project-root row.
  # gh_jq_or_jq's `-r` mode + single-file arg is the wrong tool here (audit.jsonl
  # is JSONL, not one JSON document), so call jq directly with --slurp.
  local row
  row="$(jq -r --argjson pr "$pr" \
    '[.[] | select(.event=="merge_executed" or .event=="pr_parked") | select(.data.pr == $pr) | {event,reason:(.data.reason // "")}] | last | if . == null then "" else "\(.event)\t\(.reason)" end' \
    --slurp "${audit_files[@]}" 2>/dev/null)"
  [ -n "$row" ] || { printf 'missing\n'; return 0; }
  local event="${row%%	*}" reason="${row#*	}"
  case "$event" in
    merge_executed)
      printf 'success\n' ;;
    pr_parked)
      # CONTRACT: park-reason !case-arm
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
  # Bash builtin `$(< file)` avoids a `cat` fork; library is bash-only (header).
  [ -r "$tsv" ] && existing="$(<"$tsv")"
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
  # Background — the previous implementation used the predicate
  # `! grep -q '^barrier_start_ts='` + `>>` append. That bare-prefix pattern
  # is wrong when Phase 0 step 7 has already called uberdev_goal_write_run_state,
  # because the writer ALWAYS emits a `barrier_start_ts=${barrier_start_ts:-0}`
  # line — so the placeholder `barrier_start_ts=0` line exists on disk, the
  # bare-prefix `grep -q` matches it, the `!` negation is FALSE, and the seed
  # never fires. The wall-clock merge-barrier breaker (AC6 / D-211e) then never
  # trips because the Phase 2c guard reads `0` forever.
  #
  # Fix (current predicate, line below): tighten the regex to
  # `^barrier_start_ts=[1-9][0-9]*$` so the placeholder `barrier_start_ts=0`
  # line does NOT match, `! grep -q` is therefore TRUE, and the seed DOES fire.
  # Use an awk rewrite (drop every existing barrier_start_ts= line, append the
  # seeded value at end) → mktemp → mv -f so the placeholder line is REPLACED
  # rather than duplicated. Best-effort: failure leaves the file untouched (the
  # next uberdev_goal_write_run_state rewrites the sidecar atomically from the
  # in-memory scalar anyway).
  if [ "$first" = "1" ]; then
    local sc="$tmpdir/goal-$goal_id-runstate"
    if [ -r "$sc" ] && ! grep -qE '^barrier_start_ts=[1-9][0-9]*$' "$sc"; then
      # Note: dispatch-lib presence already preflighted at line 807 (return 4
      # path), so the symbol is guaranteed present here — no inner command -v.
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
  return 0
}

# uberdev_goal_barrier_breaker_check GOAL_ID BARRIER_TIMEOUT_S
#
# Returns 0 iff the wall-clock merge-barrier breaker should fire — i.e.
# the run-state sidecar's `barrier_start_ts` is a positive integer AND
# `_uberdev_goal_now_secs() - barrier_start_ts >= timeout_s`. On fire,
# emits a single `goal_circuit_breaker` audit event with payload
# `{"reason":"stuck_loop","phase":"merge_barrier","elapsed_s":N,"pending_prs":"..."}`
# — payload shape verbatim-equivalent to the inline math previously in
# SKILL.md Phase 2c. `pending_prs` is the comma-joined PR list with
# state==PENDING from `goal-<id>-batch-prs.tsv` (best-effort; empty
# string on missing/unreadable TSV — the awk `2>/dev/null` swallows
# read errors too). Returns 1 if barrier_start_ts is unset/zero or
# elapsed is under threshold. Issue #214.
uberdev_goal_barrier_breaker_check() {
  local goal_id="${1:?goal_id required}"
  local timeout_s="${2:?timeout_s required}"
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local sc="$tmpdir/goal-$goal_id-runstate"
  [ -r "$sc" ] || return 1
  local barrier_start
  # Single-fork awk: last barrier_start_ts= line wins; numeric coerce inline so
  # empty/non-numeric values fall through to the case-guard below as "0".
  barrier_start="$(awk -F= '$1=="barrier_start_ts"{v=$2} END{print v+0}' "$sc")"
  # treat 0 as unseeded placeholder; positive epoch only
  case "$barrier_start" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  local now elapsed
  now="$(_uberdev_goal_now_secs)"
  elapsed=$(( now - barrier_start ))
  if [ "$elapsed" -ge "$timeout_s" ]; then
    local pending
    pending="$(awk -F'\t' '$4=="PENDING"{printf "%s,", $1}' \
      "$tmpdir/goal-$goal_id-batch-prs.tsv" 2>/dev/null \
      | sed 's/,$//')"
    uberdev_goal_audit goal_circuit_breaker \
      "$(printf '{"reason":"stuck_loop","phase":"merge_barrier","elapsed_s":%s,"pending_prs":"%s"}' \
         "$elapsed" "$pending")"
    return 0
  fi
  return 1
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
# rc 0 (barrier MAY proceed) iff NO HELD row is still actively waiting on an
# OPEN blocking issue. A HELD row gates the barrier (rc 1, "keep waiting") ONLY
# while at least one of its `Blocks: #N` issues is still OPEN — the legitimate
# hold-and-unblock window (RFC 0005 §3.2.3), bounded by the 4h barrier breaker.
# All other HELD rows are PSEUDO-TERMINAL and do NOT gate co-batched GREEN PRs:
#   - NO Blocks: line                                  → permanent hold
#   - ALL Blocks issues CLOSED + `uberdev-approved`    → re-review cleared it green
#   - ALL Blocks issues CLOSED + no `uberdev-approved` → re-review fired but did
#     not produce GREEN (PR stays held) → permanent hold
# The unblock-issue ids come from the PR body's `Blocks: #N` lines (body capped
# at 64 KiB per R1/T1). Pure read of label/issue state.
#
# #289.1 (BLOCKER) — the gate previously required the label `review-pr:green`,
# which has ZERO producers (/review-pr emits `uberdev-approved` /
# `uberdev-approved-with-concerns`, never `review-pr:green` — see
# commands/review-pr.md:895). So a HELD row whose blocker CLOSED but which stayed
# held returned rc 1 FOREVER, blocking every co-batched GREEN PR until the 4h
# stuck_loop and defeating the core hold-and-unblock feature. Fix: gate on the
# label /review-pr actually writes (`uberdev-approved`), and treat a held PR
# whose blockers all closed as pseudo-terminal (it no longer gates) regardless
# of whether the re-review went green — consistent with the Phase-3 convergence
# calculus where both held states are terminal.
#
# #289.3 (MAJOR) — collect and require ALL `Blocks:` issues (the prior loop
# `break`-ed after the FIRST match while _uberdev_goal_check_unblock requires
# ALL closed; a >1-blocker held PR could unblock the barrier prematurely or
# wedge). Mirror check_unblock's all-closed loop, including its 404→CLOSED /
# other-gh-error→wait classification (spec B11: never assume CLOSED on a gh
# failure).
uberdev_goal_batch_unblock_wait_clear() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] && [ -s "$tsv" ] || return 0   # empty registry → trivially clear
  # #270 cross-shell: ALL locals declared ONCE at function scope. Re-running
  # `local var` (no value) inside the per-row loop ECHOES `var=<value>` to
  # stdout under zsh (= `typeset var` on an existing var), which polluted this
  # function's stdout from the 2nd HELD row onward. Declaring up front + bare
  # assignment inside the loop keeps stdout clean in bash AND zsh.
  local pr issue _ts state line body n any_open i issue_state issue_raw issue_rc has_approved
  local blocking=()
  while IFS=$'\t' read -r pr issue _ts state; do
    [ -n "$state" ] || continue
    [ "$state" = "HELD" ] || continue
    # Fetch PR body (capped at 64 KiB) and collect ALL Blocks: #N issues.
    # F17 simplify-lens: reuse the centralized helpers
    # _uberdev_goal_fetch_pr_body + _uberdev_goal_parse_blocks_line (same
    # primitives used by sibling _uberdev_goal_check_unblock); the cap +
    # ReDoS-safe anchored regex + numeric re-validation flow from one source.
    blocking=()                              # reset per HELD row
    body="$(_uberdev_goal_fetch_pr_body "$pr")"
    while IFS= read -r line; do
      n="$(_uberdev_goal_parse_blocks_line "$line")"
      [ -n "$n" ] && blocking+=("$n")
    done <<< "$body"
    # No unblock-issue → permanent hold → pseudo-terminal (doesn't gate).
    [ "${#blocking[@]}" -gt 0 ] || continue
    # Are ALL blocking issues CLOSED? (mirror _uberdev_goal_check_unblock — #289.3)
    # any_open=1 means at least one blocker is still OPEN → genuine wait window.
    # A gh failure other than 404 → wait (rc 1; B11 — never assume CLOSED).
    any_open=0
    for i in "${blocking[@]}"; do
      issue_raw="$(gh issue view "$i" --json state --jq '.state' 2>&1)"
      issue_rc=$?
      if [ "$issue_rc" -ne 0 ]; then
        if printf '%s' "$issue_raw" | grep -q 'Could not resolve to an Issue'; then
          issue_state="CLOSED"   # 404 → deleted upstream → treat as closed
          _uberdev_goal_reset_gh_failure
        else
          printf 'goal-state: batch unblock PR %s blocked by issue %s gh issue view failed rc=%d: %s\n' \
            "$pr" "$i" "$issue_rc" "$issue_raw" >&2
          _uberdev_goal_record_gh_failure
          return 1               # transient gh error → keep waiting (B11)
        fi
      else
        _uberdev_goal_reset_gh_failure
        issue_state="$issue_raw"
      fi
      if [ "$issue_state" != "CLOSED" ]; then any_open=1; break; fi
    done
    # At least one blocker still OPEN → this held PR is in its legitimate
    # hold-and-unblock wait window → gate the barrier.
    [ "$any_open" = "0" ] || return 1
    # All blockers CLOSED → pseudo-terminal regardless of re-review outcome
    # (#289.1). Read the trust label /review-pr actually writes
    # (`uberdev-approved` — NOT the zero-producer `review-pr:green`) purely to
    # classify the breadcrumb: present ⇒ the re-review cleared it green; absent
    # ⇒ the re-review fired but did not produce green and the PR stays held. In
    # BOTH cases the row is pseudo-terminal and `continue`s — it does NOT gate
    # co-batched GREEN PRs (the #289.1 anti-deadlock fix; #289.2's sequential
    # green-PR merge loop serializes any version bumps so an early-merging
    # GREEN PR cannot collide with a freshly-cleared held PR).
    has_approved="$(gh pr view "$pr" --json labels \
      --jq '[.labels[].name | select(. == "uberdev-approved")] | length' 2>/dev/null || true)"
    if [ "${has_approved:-0}" -ge 1 ]; then
      : # cleared green via re-review — no longer gates
    else
      printf 'goal-state: held PR %s has all Blocks closed but no uberdev-approved label (stays held, pseudo-terminal — not gating barrier)\n' "$pr" >&2
    fi
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
# print a stderr warning and return the DISTINCT rc=5 (#301, RFC 0012 §3.3
# goal-R1 item 4). The pre-#301 contract returned rc=0 here, making the
# cap-skip indistinguishable from a successful dispatch — Phase 2b then
# kept `any_active=1` and the PR spun in pushed-reviewing until the 4h
# stuck_loop reaped every live solver. rc=5 lets the 2b caller transition
# the PR to `red-held` (pseudo-terminal for convergence) with a distinct
# audit note instead. Intentionally still NOT a circuit breaker — the goal
# continues toward convergence and the cap does NOT halt the goal. Callers
# that ignore the rc (the unblock rule at _uberdev_goal_check_unblock) keep
# the pre-#301 skip-in-place behaviour. rc map: 0 dispatched; 1 validation/
# mktemp/counter-write failure; 4 missing lib/dispatch.sh; 5 cap exhausted.
# The merge-attempts pattern (uberdev_goal_should_automerge
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
  # #207 — preflight lib/dispatch.sh; without it, a CNF leaks a phantom attempt
  # to the counter TSV. rc=4 mirrors the writer + register_batch_pr precedent.
  if ! command -v uberdev_dispatch_one >/dev/null 2>&1; then
    printf 'goal-state: _uberdev_goal_dispatch_review_pr requires lib/dispatch.sh sourced first (missing uberdev_dispatch_one)\n' >&2
    return 4
  fi
  local current; current="$(_uberdev_goal_count_review_pr_attempts "$goal_id" "$pr")"
  local cap="${_UBERDEV_GOAL_MAX_REVIEW_PR_ATTEMPTS:-3}"
  if [ "$current" -ge "$cap" ]; then
    printf 'goal-pipeline: review-pr dispatch cap reached for PR #%s (cap=%s); skipping re-dispatch this cycle\n' \
      "$pr" "$cap" >&2
    return 5   # #301 — DISTINCT cap-exhausted rc (was 0; see header rc map)
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
  # claude --bg argv mode does NOT slash-expand the opening message, so wrap
  # the slash invocation in a natural-language imperative the child must
  # interpret as an instruction rather than answer conversationally.
  printf 'Invoke the slash command /uberdev:review-pr %s now. Do not respond conversationally — execute it.\n' "$pr" > "$prompt_file"
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
  local tmpdir="${UBERDEV_TMPDIR:-/tmp}"
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"
  # #156 — refuse a forged provenance id rather than pathing a counter TSV with it.
  _uberdev_goal_validate_id "$goal_id" || {
    printf 'goal-state: unsafe UBERDEV_GOAL_ID %s; refusing merge dispatch for PR #%s\n' "$goal_id" "$pr" >&2
    return 1
  }
  # #207 — same dispatch.sh preflight as _uberdev_goal_dispatch_review_pr: a
  # missing uberdev_dispatch_one would otherwise CNF after a phantom counter row.
  if ! command -v uberdev_dispatch_one >/dev/null 2>&1; then
    printf 'goal-state: _uberdev_goal_dispatch_merge requires lib/dispatch.sh sourced first (missing uberdev_dispatch_one)\n' >&2
    return 4
  fi
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
  # Same natural-language wrapper rationale as the review-pr dispatch above:
  # claude --bg argv mode does NOT slash-expand the opening message.
  printf 'Invoke the slash command /uberdev:merge %s now. Do not respond conversationally — execute it.\n' "$pr" > "$prompt_file"
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

# print_summary CYCLES
# Emits the mandated single operator summary line + one post-mortem row per
# held PR (each row `pr=<num> state=<yellow-held|red-held> blocks=#<i1>,#<i2>,…`).
#
# #270 — HOISTED here from the goal-pipeline SKILL.md Phase-4 bash fence. It is
# CALLED from the Phase-1/2/3 fences on every /goal exit path (every circuit
# breaker AND the convergence path), but a shell function does NOT survive a
# fence boundary: each phase is a fresh shell that re-sources only
# config-read.sh / dispatch.sh / goal-state.sh. With the def stranded in Phase 4,
# every non-Phase-4 exit hit `command not found` (rc 127) — the operator summary
# line + held-PR Blocks post-mortem rows were silently dropped and only the
# trailing `exit N` ran. Defining it HERE means the per-fence re-source of
# goal-state.sh brings it into scope in every phase; its only dep,
# _uberdev_goal_fetch_pr_body, already lives in this file.
#
# #171 — print_summary reads GOAL_ID / MAX_CYCLES / watch_start from the calling
# shell and calls uberdev_goal_* helpers that gate on the UBERDEV_GOAL_ID env.
# Every caller (the Phase 1/2/3 fences) rehydrates that state via
# uberdev_goal_read_run_state at fence top (which also re-exports UBERDEV_GOAL_ID
# + UBERDEV_TMPDIR). Do NOT call print_summary from a block that has not run that
# rehydration — it is never called from Phase 0.
print_summary() {
  local cycles="$1" prs_merged prs_held_lines prs_held_count issues_resolved wall_secs
  prs_merged="$(uberdev_goal_list_prs_in_state "$GOAL_ID" merged | grep -c . || true)"
  # Build a `<state>\t<pr>` stream so the per-row printf below can emit the
  # `state=` field promised at line ~466 ("each row pr=<num> state=<yellow-held
  # |red-held> blocks=…"). The prior implementation merged the two lists into
  # bare PR numbers and the `state=` field was silently dropped (S6).
  prs_held_lines="$( \
    uberdev_goal_list_prs_in_state "$GOAL_ID" yellow-held | sed 's/^/yellow-held\t/'; \
    uberdev_goal_list_prs_in_state "$GOAL_ID" red-held    | sed 's/^/red-held\t/' )"
  prs_held_count="$(printf '%s\n' "$prs_held_lines" | grep -c . || true)"
  issues_resolved="$(uberdev_goal_count_resolved_issues "$GOAL_ID")"
  wall_secs="$(( $(date +%s) - watch_start ))"
  printf 'goal %s: cycles=%s/%s prs_merged=%s prs_held=%s issues_resolved=%s wall_secs=%s\n' \
    "$GOAL_ID" "$cycles" "$MAX_CYCLES" "$prs_merged" "$prs_held_count" \
    "$issues_resolved" "$wall_secs"
  printf '%s\n' "$prs_held_lines" | while IFS=$'\t' read -r state p; do
    [ -z "$p" ] && continue
    body="$(_uberdev_goal_fetch_pr_body "$p")"
    blocks="$(printf '%s\n' "$body" | grep -E '^Blocks: #[0-9]+$' \
      | sed -E 's/^Blocks: #([0-9]+)$/#\1/' | paste -sd, -)"
    printf '  pr=%s state=%s blocks=%s\n' "$p" "$state" "${blocks:-none}"
  done
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

# uberdev_goal_detect_blocks_cycle GOAL_ID   (issue #292.1)
# rc 0 (CYCLE FOUND) + echo the cycle's PR numbers CSV on stdout iff the
# Blocks: dependency graph over the batch's HELD PRs contains a cycle (an SCC of
# size ≥1 including a self-loop); rc 1 + empty stdout when the graph is acyclic.
#
# WHY: _uberdev_goal_check_unblock re-reviews a held PR only when ALL its
# `Blocks: #N` issues are CLOSED, with NO cycle guard. A-blocks-B + B-blocks-A
# (A held on an issue that only B's merge closes, and vice-versa) → neither
# issue ever closes → both held PRs spin to the 4h stuck_loop with no diagnostic
# naming the deadlock. RFC §4.3 claims "arbitrary depth" but only handles
# ACYCLIC chains (the dependency graph had no SCC guard). This detector lets the
# watch loop surface a distinct halt + print_summary row instead of riding the
# wall-clock cap.
#
# Graph: nodes = HELD PRs. Edge P→Q iff P's body carries `Blocks: #N` and issue
# N is closed by Q (Q's merge closes N — resolved via uberdev_goal_find_pr_for_issue,
# i.e. the OPEN PR whose closingIssuesReferences include N) AND Q is itself a
# HELD PR in this batch. A cycle over these edges is a merge deadlock.
#
# Cross-shell (#270): indexed arrays + newline-delimited string sets only — NO
# associative arrays (bash `declare -A` / zsh `typeset -A` diverge in key
# enumeration and would reintroduce the dual-shell fragility class). Reachability
# is computed by fixpoint closure; the held-PR set is batch-bounded (small), so
# the O(V·E) closure is cheap. Best-effort on gh failure: an unresolved edge is
# simply omitted (a transient gh outage must not fabricate or hide a cycle — the
# next poll re-evaluates).
uberdev_goal_detect_blocks_cycle() {
  local goal_id="$1"
  _uberdev_goal_validate_id "$goal_id" || return 1
  local tmpdir="${UBERDEV_TMPDIR:-${TMPDIR:-/tmp}}"
  local tsv="$tmpdir/goal-$goal_id-batch-prs.tsv"
  [ -r "$tsv" ] && [ -s "$tsv" ] || return 1
  # 1) Collect HELD PRs.
  local held=() _pr _issue _ts state
  while IFS=$'\t' read -r _pr _issue _ts state; do
    [ "$state" = "HELD" ] || continue
    _uberdev_goal_validate_int "$_pr" || continue
    held+=("$_pr")
  done < "$tsv"
  [ "${#held[@]}" -gt 0 ] || return 1
  # Held-set membership probe (newline-delimited; grep -xF exact-line match).
  local held_set; held_set="$(printf '%s\n' "${held[@]}")"
  # 2) Build edges P<TAB>Q into a newline-delimited string set.
  local edges="" p body line n q
  for p in "${held[@]}"; do
    body="$(_uberdev_goal_fetch_pr_body "$p")"
    [ -n "$body" ] || continue
    while IFS= read -r line; do
      n="$(_uberdev_goal_parse_blocks_line "$line")"
      [ -n "$n" ] || continue
      q="$(uberdev_goal_find_pr_for_issue "$n" 2>/dev/null)"
      [ -n "$q" ] || continue
      _uberdev_goal_validate_int "$q" || continue
      # Q must be a HELD PR in this batch for the edge to matter.
      printf '%s\n' "$held_set" | grep -qxF "$q" || continue
      edges="${edges}${p}	${q}
"
    done <<< "$body"
  done
  [ -n "$edges" ] || return 1
  # 3) Reachability closure via fixpoint. `reach` holds "FROM<TAB>TO" pairs.
  # Seed with the direct edges, then repeatedly compose reach∘edges until no
  # new pair is added. A self-pair "X<TAB>X" anywhere means X lies on a cycle.
  # #270 cross-shell: declare `pair` ONCE at function scope, never re-`local`
  # inside the loop — under zsh, `local var` (= `typeset var`) on an
  # already-declared var ECHOES `var=<value>` to stdout, which polluted the
  # function's stdout (the cycle CSV) when run under the zsh Bash tool. Hoisting
  # the declaration and assigning with a bare `printf -v` keeps stdout clean in
  # both shells.
  local reach="$edges" changed=1 a b c re_from re_to pair
  while [ "$changed" = "1" ]; do
    changed=0
    # For each reachable pair (a,b) and each edge (b,c), try to add (a,c).
    while IFS=$'\t' read -r a b; do
      [ -n "$a" ] && [ -n "$b" ] || continue
      while IFS=$'\t' read -r re_from re_to; do
        [ "$re_from" = "$b" ] || continue
        c="$re_to"
        printf -v pair '%s\t%s' "$a" "$c"
        if ! printf '%s' "$reach" | grep -qxF "$pair"; then
          reach="${reach}${pair}
"
          changed=1
        fi
      done <<< "$edges"
    done <<< "$reach"
  done
  # 4) Any self-pair X<TAB>X ⇒ X is on a cycle. Collect distinct such PRs.
  local cycle_prs
  cycle_prs="$(printf '%s' "$reach" \
    | awk -F'\t' '$1!="" && $1==$2 && !seen[$1]++ {print $1}' \
    | sort -n | paste -sd, -)"
  [ -n "$cycle_prs" ] || return 1
  printf '%s\n' "$cycle_prs"
  return 0
}

# _uberdev_goal_set_batch_terminal_state GOAL_ID PR STATE
# Rewrite the PR's row in goal-<id>-batch-prs.tsv with the new terminal_state.
# Atomic-write via _uberdev_dispatch_prepare_tmp_target + mktemp + mv -f
# (preserves all other rows). Refuses to silently insert a new row for an
# unknown PR — that would let a typo masquerade as a state change.
# rc 0 on success; rc 1 validation / PR-not-in-registry; rc 3 atomic-write;
# rc 4 missing dispatch lib.
#
# #289.2 — MERGING is a NON-terminal sentinel (NOT in uberdev_goal_batch_all_terminal's
# terminal set, NOT in _uberdev_goal_batch_green_prs_ordered's GREEN filter). Phase 2c
# sets it on the lowest green PR the instant /merge is dispatched, so (a) that PR drops
# out of the green-ordered list and (b) batch_all_terminal goes rc 1 — which makes the
# Phase-2c barrier gate FALSE and blocks any further /merge dispatch until Phase 2d
# drives the in-flight PR to MERGED. That cross-pass interlock (paired with the in-pass
# `break`) is what serializes version-bump merges: a second manifest-touching PR can
# never be dispatched while the first is still landing, so two PRs can no longer both
# land vN+1 and have git silently eat the second bump (project_uberdev_merge_version_collision).
_uberdev_goal_set_batch_terminal_state() {
  local goal_id="$1" pr="$2" state="$3"
  _uberdev_goal_validate_id  "$goal_id" || return 1
  _uberdev_goal_validate_int "$pr"      || return 1
  case "$state" in
    GREEN|HELD|MERGE_FAILED|MERGED|PENDING|MERGING) : ;;
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
  existing="$(<"$tsv")"
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

# ---------------------------------------------------------------------------
# Mandatory version bump before landing (issue #364)
# ---------------------------------------------------------------------------
# THE HOLE THIS CLOSES. `skills/solve-fleet/workflow.js` tells every fleet
# solver, correctly, NOT to bump the project version: N solvers branching off
# the same main all resolve the SAME next version, git auto-merges the identical
# change without a conflict, and the second landing silently eats the first
# bump (project memory: project_uberdev_merge_version_collision). But nothing
# downstream ever ADDED the bump back. `_uberdev_goal_rebase_collision_chain`
# below RENUMBERS a bump that already exists; it never creates one. So a /goal
# run landed PRs that touched zero version surfaces, and it failed SILENTLY:
# the two CI version-lock tests assert the surfaces AGREE with each other, not
# that the version ADVANCED, so an unbumped landing leaves every surface
# consistently at the old version, CI stays green, and the marketplace never
# serves the update.
#
# WHY THE BUMP BELONGS HERE. `lib/goal-watch.sh` step 2c acts on exactly ONE
# green PR per pass (strict lowest-first) and holds the MERGING sentinel until
# that PR lands (#289.2). That is the only strictly-serialized point in the
# run, so at the moment we bump, `origin/<base>` already carries the previous
# landing's bump — which is what makes sequential numbering correct instead of
# colliding. Bumping any earlier (in the solver, in the review lane) reopens the
# collision.
#
# FAIL CLOSED. Every helper below returns non-zero rather than guessing, and
# the watch lane must NOT dispatch /merge for a PR whose bump could not be
# guaranteed. Merging unbumped IS the bug; merging is never the fallback.
#
# THE TWO DOWNSTREAM CONSEQUENCES OF PUSHING HERE, and where each is answered.
#   1. The release commit lands ON TOP of the `Reviewed-by:` anchor commit
#      `/review-pr` wrote, so /merge Phase 1.4 PATH_2 would read the trailer off
#      the wrong commit (gate_fail trust_trail_trailer_missing) and, even with
#      the trailer, would see a non-empty cumulative diff (verdict STALE ->
#      trust_trail_stale_sha, which is explicitly excluded from the Step-1.4.5
#      auto-review recovery). ANSWERED IN /merge, not here: PATH_2 sub-condition
#      (a.5) resolves the trust head through
#      `skills/merge-pipeline/lib/release-anchor.sh`, which tolerates the top
#      commit ONLY when it is provably inert with respect to reviewed code. The
#      bump therefore stays at the serialized lane — the only place consecutive
#      versions fall out naturally — instead of being moved before the review,
#      which would reopen the collision class this whole section exists to close.
#   2. The push RESTARTS the PR's checks. /merge Step 1.4 reads any pending
#      rollup entry as gate_fail reason=ci_red. ANSWERED HERE: a successful bump
#      returns rc 2 ("pushed just now — defer"), and the watch lane additionally
#      gates every dispatch on `_uberdev_goal_pr_checks_pending`.

# The canonical version SSOT (`bump-version.sh` surface 1). Its presence is
# also the probe for "does this repo have a version ratchet at all" — /goal is a
# general-purpose command and the mandatory-bump rule belongs to repos that
# actually carry the surfaces `bump-version.sh` knows how to move.
_UBERDEV_GOAL_VERSION_MANIFEST='plugins/uberdev/.claude-plugin/plugin.json'
# The exact stub body `bump-version.sh::bv_insert_changelog_stub` writes. Kept
# as a constant so a drift in that script fails LOUD here (the fill helper
# returns non-zero when the marker is absent) instead of shipping a CHANGELOG
# section whose body is still "release notes pending".
_UBERDEV_GOAL_CHANGELOG_STUB_MARK='_Release notes pending'

# _uberdev_goal_manifest_version   (reads the manifest JSON on stdin)
# Echo the first `"version": "X.Y.Z"` value. Same extraction bump-version.sh
# uses for its own current-version read, so the two can never disagree about
# which literal is canonical.
_uberdev_goal_manifest_version() {
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | sed -n '1p'
}

# _uberdev_goal_validate_ref REF
# A branch name arrives from `gh` and goes straight into `git` argv. Refuse a
# leading `-` (git would parse it as an option), whitespace, and anything
# outside git's own ref-name character set — the same defence-in-depth
# `_uberdev_goal_validate_int` gives the PR numbers.
_uberdev_goal_validate_ref() {
  local ref="$1"
  case "$ref" in
    ''|-*) return 1 ;;
    *[!A-Za-z0-9._/-]*) return 1 ;;
    *'..'*) return 1 ;;
  esac
  return 0
}

# _uberdev_goal_semver_parts VERSION
# Echo `MAJOR MINOR PATCH` for a strict X.Y.Z; rc 1 for anything else. Pure
# parameter expansion — no subshell, no `read`, no `[[ ]]`, so bash 3.2, bash 5
# and zsh all parse and evaluate it identically.
_uberdev_goal_semver_parts() {
  local v="$1" maj min pat rest
  case "$v" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  maj="${v%%.*}"; rest="${v#*.}"
  [ "$rest" != "$v" ] || return 1          # no first dot
  min="${rest%%.*}"; pat="${rest#*.}"
  [ "$pat" != "$rest" ] || return 1        # no second dot
  case "$pat" in *.*) return 1 ;; esac     # X.Y.Z.W is not SemVer
  [ -n "$maj" ] && [ -n "$min" ] && [ -n "$pat" ] || return 1
  printf '%s %s %s' "$maj" "$min" "$pat"
}

# _uberdev_goal_semver_gt A B — rc 0 iff A is strictly newer than B.
# Load-bearing: a PR branched before two releases landed has a version LOWER
# than its base, and a plain `!=` would read that as "already bumped" and let it
# land unbumped — the very bug this machinery closes.
_uberdev_goal_semver_gt() {
  local pa pb a1 a2 a3 b1 b2 b3
  pa="$(_uberdev_goal_semver_parts "$1")" || return 1
  pb="$(_uberdev_goal_semver_parts "$2")" || return 1
  a1="${pa%% *}"; pa="${pa#* }"; a2="${pa%% *}"; a3="${pa#* }"
  b1="${pb%% *}"; pb="${pb#* }"; b2="${pb%% *}"; b3="${pb#* }"
  # `10#` forces base-10 so a zero-padded component can never be read as octal.
  [ "$(( 10#$a1 ))" -gt "$(( 10#$b1 ))" ] && return 0
  [ "$(( 10#$a1 ))" -lt "$(( 10#$b1 ))" ] && return 1
  [ "$(( 10#$a2 ))" -gt "$(( 10#$b2 ))" ] && return 0
  [ "$(( 10#$a2 ))" -lt "$(( 10#$b2 ))" ] && return 1
  [ "$(( 10#$a3 ))" -gt "$(( 10#$b3 ))" ] && return 0
  return 1
}

# _uberdev_goal_next_version CURRENT KIND   (KIND: major|minor|patch)
_uberdev_goal_next_version() {
  local parts="" maj min pat kind="$2"
  parts="$(_uberdev_goal_semver_parts "$1")" || return 1
  maj="${parts%% *}"; parts="${parts#* }"; min="${parts%% *}"; pat="${parts#* }"
  case "$kind" in
    major) printf '%s.0.0'    "$(( 10#$maj + 1 ))" ;;
    minor) printf '%s.%s.0'   "$(( 10#$maj ))" "$(( 10#$min + 1 ))" ;;
    patch) printf '%s.%s.%s'  "$(( 10#$maj ))" "$(( 10#$min ))" "$(( 10#$pat + 1 ))" ;;
    *) return 1 ;;
  esac
}

# _uberdev_goal_fetch_pr_commits PR
# The PR's commit messages in ONE gh round-trip, as tagged lines so the two
# zones stay separable in a flat blob: `S|<subject>` per commit, `B|<line>` for
# every line of every commit body. Split with `sed -n 's/^S|//p'` — `|` is
# literal in a BRE, and unlike a tab it survives BSD sed (macOS) as well as GNU.
_uberdev_goal_fetch_pr_commits() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  gh pr view "$pr" --json commits --jq '
    .commits[]
    | ("S|" + (.messageHeadline // "")),
      ((.messageBody // "") | split("\n")[] | "B|" + .)' 2>/dev/null
}

# _uberdev_goal_bump_kind TITLE BODY [COMMIT_SUBJECTS] [COMMIT_BODIES]
#   -> major|minor|patch
# SemVer from the PR's conventional-commit type, per CLAUDE.md's release rule:
# `feat:` -> minor, everything else (`fix:`/`test:`/`docs:`/`refactor:`/`chore:`)
# -> patch, a `!` marker or a `BREAKING CHANGE:` footer -> major.
#
# The COMMITS are part of the predicate, not decoration. In a /goal run the PR
# title is written by the solver agent, not by a release engineer: a PR titled
# `fix(x): …` that carries a `feat:` commit is a FEATURE, and deriving the step
# from the title alone silently under-releases it as a patch. Title/body still
# participate — a maintainer-authored `BREAKING CHANGE:` footer in the PR body
# is authoritative even when no single commit declares it. Highest wins:
# major > minor > patch.
#
# Herestrings (never `echo … | grep -q`) — a pipe into `grep -q` can EPIPE-race
# under pipefail on Linux CI.
_uberdev_goal_bump_kind() {
  local title="$1" body="$2" subjects="${3:-}" bodies="${4:-}"
  if grep -Eq '^[A-Za-z]+(\([^)]*\))?!:' <<<"$title" \
     || grep -Eq '^[A-Za-z]+(\([^)]*\))?!:' <<<"$subjects" \
     || grep -Eq '^[[:space:]]*BREAKING[ -]CHANGE[[:space:]]*:' <<<"$body" \
     || grep -Eq '^[[:space:]]*BREAKING[ -]CHANGE[[:space:]]*:' <<<"$bodies"; then
    printf 'major'
    return 0
  fi
  if grep -Eq '^feat(\([^)]*\))?:' <<<"$title" \
     || grep -Eq '^feat(\([^)]*\))?:' <<<"$subjects"; then
    printf 'minor'
    return 0
  fi
  printf 'patch'
}

# _uberdev_goal_pr_checks_pending PR
# rc 0 — at least one statusCheckRollup entry is queued / in-progress / pending.
#        The caller MUST NOT dispatch /merge: Step 1.4 of merge-pipeline
#        classifies a non-empty rollup carrying ANY pending entry as
#        gate_fail reason=ci_red, and its null-rollup settle probe is bounded at
#        3 x 10s while this repo's CI critical path is minutes — so dispatching
#        into a pending rollup is a DETERMINISTIC gate-fail that burns one of
#        the three per-PR merge attempts for nothing (#364).
# rc 1 — no pending entry, OR the probe was unusable (gh failure, malformed
#        count, no checks configured). Fail SOFT on purpose: /merge Step 1.4
#        owns the hard CI gate and re-probes with its own settle logic, so a
#        transient gh blip must never wedge the landing lane. This helper only
#        ever WITHHOLDS a dispatch; it can never authorise one.
_uberdev_goal_pr_checks_pending() {
  local pr="$1" pending
  _uberdev_goal_validate_int "$pr" || return 1
  pending="$(gh pr view "$pr" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]?
      | ((.status // .state // "") | ascii_upcase)
      | select(. == "QUEUED" or . == "IN_PROGRESS" or . == "PENDING"
               or . == "WAITING" or . == "REQUESTED" or . == "EXPECTED") ]
    | length' 2>/dev/null)" || pending=""
  case "$pending" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pending" -gt 0 ]
}

# _uberdev_goal_sanitize_release_text TEXT
# A PR title/body is UNTRUSTED input that is about to be written into
# CHANGELOG.md and passed through `awk -v`. Strip control characters (the field
# is single-line by contract), backslashes (awk -v runs escape processing on its
# value) and any leading markdown structure markers (a title beginning `## [9.9.9]`
# would otherwise forge a CHANGELOG section header and break the next release's
# drift pre-check). Length-capped for hygiene.
_uberdev_goal_sanitize_release_text() {
  printf '%s' "$1" \
    | tr -d '[:cntrl:]' \
    | sed -e 's/\\//g' \
          -e 's/^[[:space:]]*[#>*_-]*[[:space:]]*//' \
          -e 's/[[:space:]]*$//' \
    | cut -c1-160
}

# _uberdev_goal_release_entry PR TITLE BODY
# The CHANGELOG bullet that replaces bump-version.sh's stub — derived from the
# PR (its title, and the issue references its body carries), never free-form.
_uberdev_goal_release_entry() {
  local pr="$1" title="$2" body="$3" clean refs
  clean="$(_uberdev_goal_sanitize_release_text "$title")"
  [ -n "$clean" ] || clean="PR #$pr"
  refs="$(grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' <<<"$body" \
          | grep -Eo '[0-9]+' | sort -n -u | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g')"
  if [ -n "$refs" ]; then
    printf -- '- %s (#%s; closes %s)' "$clean" "$pr" "$refs"
  else
    printf -- '- %s (#%s)' "$clean" "$pr"
  fi
}

# _uberdev_goal_fill_changelog_stub CHANGELOG_FILE ENTRY_LINE
# Replace the pending-release stub line bump-version.sh inserted with ENTRY_LINE.
# rc 1 when the stub marker is absent — a release section whose body still reads
# "release notes pending" is not a release, so this fails CLOSED rather than
# committing the placeholder.
_uberdev_goal_fill_changelog_stub() {
  local file="$1" entry="$2" tmp
  [ -f "$file" ] || return 1
  tmp="$file.goal-bump.$$"
  if ! awk -v entry="$entry" -v mark="$_UBERDEV_GOAL_CHANGELOG_STUB_MARK" '
        !filled && index($0, mark) { print entry; filled = 1; next }
        { print }
        END { if (!filled) exit 3 }
      ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# _uberdev_goal_version_bump_deferred PR STAGE
# One place that records "the bump did not happen, and here is exactly where it
# stopped". Reuses the existing closed audit enum: `goal_merge_deferred` already
# means "the merge dispatch was withheld this pass, with a reason". STAGE is a
# fixed vocabulary, never interpolated free text, so the JSON payload can never
# be malformed by a hostile PR title. Always rc 1 — callers `return` it directly.
_uberdev_goal_version_bump_deferred() {
  local pr="$1" stage="$2"
  uberdev_goal_audit goal_merge_deferred \
    "$(printf '{"goal_id":"%s","pr":%s,"reason":"version_bump_failed","stage":"%s"}' \
        "${UBERDEV_GOAL_ID:-unknown}" "$pr" "$stage")" >/dev/null 2>&1 || true
  printf 'goal-state: version bump for PR %s FAILED at stage=%s — NOT dispatching /merge (landing unbumped is invisible to the marketplace); the PR stays green for a later pass\n' \
    "$pr" "$stage" >&2
  return 1
}

# _uberdev_goal_apply_version_bump WT NEXT PR HEAD_REF TITLE BODY
# The write half, isolated so the caller owns worktree lifecycle on every exit
# path (a shell function cannot use `trap` without clobbering the caller's).
# Runs inside a DETACHED throwaway worktree at the PR head — never the /goal
# session's own checkout, whose index must stay pristine (project memory:
# project_uberdev_turbo_main_index_pollution).
_uberdev_goal_apply_version_bump() {
  local wt="$1" next="$2" pr="$3" head_ref="$4" title="$5" body="$6"
  local bump_sh="$_UBERDEV_GOAL_LIB_DIR/bump-version.sh" out entry
  # bump-version.sh owns the seven-surface edit, refuses on pre-existing drift
  # (exit 3) and re-verifies every surface after writing (exit 4). Lean on it;
  # never re-implement the surface list here.
  if ! out="$(bash "$bump_sh" "$next" --repo-root "$wt" 2>&1)"; then
    printf 'goal-state: bump-version.sh %s refused for PR %s:\n%s\n' "$next" "$pr" "$out" >&2
    _uberdev_goal_version_bump_deferred "$pr" "bump_script"
    return 1
  fi
  entry="$(_uberdev_goal_release_entry "$pr" "$title" "$body")"
  if ! _uberdev_goal_fill_changelog_stub "$wt/CHANGELOG.md" "$entry"; then
    _uberdev_goal_version_bump_deferred "$pr" "changelog"
    return 1
  fi
  # `-a` (tracked files only): every surface bump-version.sh touches is tracked,
  # so an untracked stray can never be swept into the release commit.
  if ! out="$(git -C "$wt" commit -a -m "chore(release): v$next" \
        -m "$(printf 'Added by /goal before landing PR #%s. The fleet solvers are forbidden from bumping the version, because N solvers off the same base all resolve the same next version and the duplicate change auto-merges without a conflict. The serialized landing lane is the one point where the next version is unambiguous.' "$pr")" 2>&1)"; then
    printf 'goal-state: git commit failed for PR %s: %s\n' "$pr" "$out" >&2
    _uberdev_goal_version_bump_deferred "$pr" "commit"
    return 1
  fi
  # NEVER --force. A rejected non-fast-forward means the PR branch moved under
  # us; the correct response is to fail closed and re-derive next pass, not to
  # overwrite someone else's commit.
  if ! out="$(git -C "$wt" push origin "HEAD:refs/heads/$head_ref" 2>&1)"; then
    printf 'goal-state: push of the release commit for PR %s failed: %s\n' "$pr" "$out" >&2
    _uberdev_goal_version_bump_deferred "$pr" "push"
    return 1
  fi
  return 0
}

# _uberdev_goal_ensure_version_bump PR
# Guarantee that PR carries a version bump before /goal lands it.
#   rc 0 — the PR ALREADY carried a bump, or the repo has no version ratchet to
#          enforce. Nothing was pushed, so the PR's checks are undisturbed and
#          the caller may proceed to its CI gate.
#   rc 2 — this call created the bump and PUSHED it. The push RESTARTED the
#          PR's checks, so the caller MUST defer the /merge dispatch by at
#          least one pass (#364): merge-pipeline Step 1.4 reads any pending
#          rollup entry as gate_fail reason=ci_red, which would burn one of the
#          three merge attempts and, three passes later, strand the PR in
#          `green` until the 4h stuck_loop breaker. The next pass takes the
#          already_bumped arm (rc 0) and gates on the settled rollup instead.
#   rc 1 — could not guarantee a bump. The caller MUST NOT dispatch /merge.
_uberdev_goal_ensure_version_bump() {
  local pr="$1"
  _uberdev_goal_validate_int "$pr" || return 1
  local goal_id="${UBERDEV_GOAL_ID:-unknown}"

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  if [ -z "$repo_root" ]; then
    _uberdev_goal_version_bump_deferred "$pr" "repo_root_unresolved"
    return 1
  fi

  # No ratchet in this repo -> nothing to enforce. Probed on the working tree
  # (cheap, offline, and a PR cannot remove the file from the base checkout).
  if [ ! -f "$repo_root/$_UBERDEV_GOAL_VERSION_MANIFEST" ]; then
    uberdev_goal_audit goal_version_bumped \
      "$(printf '{"goal_id":"%s","pr":%s,"action":"skipped","reason":"no_version_ratchet"}' "$goal_id" "$pr")" \
      >/dev/null 2>&1 || true
    printf 'goal-state: %s is absent — this repo carries no version ratchet, so PR %s needs no bump\n' \
      "$_UBERDEV_GOAL_VERSION_MANIFEST" "$pr" >&2
    return 0
  fi

  local bump_sh="$_UBERDEV_GOAL_LIB_DIR/bump-version.sh"
  if [ -z "$_UBERDEV_GOAL_LIB_DIR" ] || [ ! -f "$bump_sh" ]; then
    _uberdev_goal_version_bump_deferred "$pr" "bump_script_missing"
    return 1
  fi

  # PR metadata in ONE gh round-trip, through gh's own --jq so this helper adds
  # no local jq dependency (the same reason the rest of this file reaches for
  # `gh … --jq` on API output and plain `jq` only on local files).
  local meta head_ref base_ref cross title
  meta="$(gh pr view "$pr" --json headRefName,baseRefName,isCrossRepository,title \
            --jq '[.headRefName, .baseRefName, (.isCrossRepository | tostring), .title] | @tsv' 2>/dev/null)"
  IFS=$'\t' read -r head_ref base_ref cross title <<<"$meta"
  if ! _uberdev_goal_validate_ref "${head_ref:-}" || ! _uberdev_goal_validate_ref "${base_ref:-}"; then
    _uberdev_goal_version_bump_deferred "$pr" "gh_metadata"
    return 1
  fi
  if [ "${cross:-}" = "true" ]; then
    # A fork head is not pushable through `origin`; pushing `head_ref` there
    # would silently CREATE that branch on the base repo instead of updating the
    # PR. Refuse loudly — the operator bumps the fork by hand, and the
    # already-bumped check below then clears the PR on a later pass.
    _uberdev_goal_version_bump_deferred "$pr" "cross_repository"
    return 1
  fi

  # Base + head tips via FETCH_HEAD rather than refs/remotes/*: correct
  # regardless of how narrow the clone's fetch refspec is.
  local base_sha head_sha
  if ! git fetch origin "$base_ref" >/dev/null 2>&1; then
    _uberdev_goal_version_bump_deferred "$pr" "fetch_base"
    return 1
  fi
  base_sha="$(git rev-parse FETCH_HEAD 2>/dev/null)" || base_sha=""
  if ! git fetch origin "$head_ref" >/dev/null 2>&1; then
    _uberdev_goal_version_bump_deferred "$pr" "fetch_head"
    return 1
  fi
  head_sha="$(git rev-parse FETCH_HEAD 2>/dev/null)" || head_sha=""
  if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
    _uberdev_goal_version_bump_deferred "$pr" "fetch_head"
    return 1
  fi

  local base_ver head_ver
  base_ver="$(git show "$base_sha:$_UBERDEV_GOAL_VERSION_MANIFEST" 2>/dev/null | _uberdev_goal_manifest_version)"
  if ! _uberdev_goal_semver_parts "$base_ver" >/dev/null 2>&1; then
    _uberdev_goal_version_bump_deferred "$pr" "base_version_unreadable"
    return 1
  fi
  head_ver="$(git show "$head_sha:$_UBERDEV_GOAL_VERSION_MANIFEST" 2>/dev/null | _uberdev_goal_manifest_version)"
  # STRICTLY GREATER, not merely different: a PR branched before two releases
  # landed sits BELOW its base and still needs a bump.
  if _uberdev_goal_semver_gt "$head_ver" "$base_ver"; then
    uberdev_goal_audit goal_version_bumped \
      "$(printf '{"goal_id":"%s","pr":%s,"action":"already_bumped","from":"%s","to":"%s"}' \
          "$goal_id" "$pr" "$base_ver" "$head_ver")" >/dev/null 2>&1 || true
    printf 'goal-state: PR %s already carries a version bump (%s -> %s); leaving renumbering to the collision chain\n' \
      "$pr" "$base_ver" "$head_ver" >&2
    return 0
  fi

  local body kind next tagged c_subjects c_bodies
  body="$(_uberdev_goal_fetch_pr_body "$pr")"
  # The SemVer step is derived from the PR's COMMITS as well as its title/body:
  # a /goal PR title is authored by the solver agent, so a `fix(...)` title over
  # a `feat:` commit would otherwise ship a feature as a patch release.
  tagged="$(_uberdev_goal_fetch_pr_commits "$pr")"
  c_subjects="$(printf '%s\n' "$tagged" | sed -n 's/^S|//p')"
  c_bodies="$(printf '%s\n' "$tagged"   | sed -n 's/^B|//p')"
  kind="$(_uberdev_goal_bump_kind "$title" "$body" "$c_subjects" "$c_bodies")"
  if ! next="$(_uberdev_goal_next_version "$base_ver" "$kind")"; then
    _uberdev_goal_version_bump_deferred "$pr" "version_resolution"
    return 1
  fi

  local wt_parent wt rc
  if ! wt_parent="$(mktemp -d 2>/dev/null)"; then
    _uberdev_goal_version_bump_deferred "$pr" "mktemp"
    return 1
  fi
  wt="$wt_parent/pr-$pr"
  if ! git worktree add --detach "$wt" "$head_sha" >/dev/null 2>&1; then
    rm -rf "$wt_parent"
    _uberdev_goal_version_bump_deferred "$pr" "worktree_add"
    return 1
  fi
  _uberdev_goal_apply_version_bump "$wt" "$next" "$pr" "$head_ref" "$title" "$body"
  rc=$?
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt_parent"
  git worktree prune >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || return 1   # the deferral audit row is emitted by the callee

  uberdev_goal_audit goal_version_bumped \
    "$(printf '{"goal_id":"%s","pr":%s,"action":"bumped","from":"%s","to":"%s","kind":"%s"}' \
        "$goal_id" "$pr" "$base_ver" "$next" "$kind")" >/dev/null 2>&1 || true
  printf 'goal-state: PR %s bumped %s -> %s (%s) and pushed as `chore(release): v%s`; deferring /merge one pass so the restarted checks can settle\n' \
    "$pr" "$base_ver" "$next" "$kind" "$next" >&2
  # rc 2, NOT 0 — the push restarted CI. See the contract above.
  return 2
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
#   MAX_CYCLES, UBERDEV_RESOLVED_BACKEND, MAX_PARALLEL, BARRIER_TIMEOUT_S,
#   barrier_start_ts, REVIEW_GRACE_SECS, WATCH_PASSES, WATCH_BUDGET (#299
#   bounded-watch bound), only_mine (#301 — the #291 identity-filter flag,
#   previously absent from the scalar flush: a fresh Phase-3 fence silently
#   widened the candidate set past the --only-mine author filter), and the
#   queue/active_issues/new_candidates arrays from the caller's shell; persists
#   them to predictable, GOAL_ID-keyed sidecars under
#   $UBERDEV_TMPDIR, plus a fixed-path goal-active-id.txt pointer so a fresh
#   shell (no GOAL_ID in env/scalar) can discover the active GOAL_ID.
#   The .candidates sidecar (#301, RFC 0012 §3.3 goal-R1 item 1) is
#   CYCLE-TAGGED: its first line is `cycle=<N>` from the caller's $cycle, and
#   uberdev_goal_read_run_state rehydrates it ONLY when the tag matches the
#   scalar-sidecar cycle — a fence that crashed between the Phase-3 gh query
#   and its flush must not leak the PRIOR cycle's candidates into the
#   terminal gates.
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
  printf 'GOAL_ID=%s\ncycle=%s\nwatch_start=%s\noverflow_count=%s\noverflow_detected=%s\nMAX_CYCLES=%s\nUBERDEV_RESOLVED_BACKEND=%s\nMAX_PARALLEL=%s\nBARRIER_TIMEOUT_S=%s\nbarrier_start_ts=%s\nREVIEW_GRACE_SECS=%s\nWATCH_PASSES=%s\nWATCH_BUDGET=%s\nonly_mine=%s\nCIRCUIT_BREAKER_HALT=%s\n' \
    "$GOAL_ID" "${cycle:-0}" "${watch_start:-0}" "${overflow_count:-0}" \
    "${overflow_detected:-0}" "${MAX_CYCLES:-0}" "${UBERDEV_RESOLVED_BACKEND:-}" \
    "${MAX_PARALLEL:-0}" "${BARRIER_TIMEOUT_S:-0}" "${barrier_start_ts:-0}" \
    "${REVIEW_GRACE_SECS:-0}" "${WATCH_PASSES:-0}" "${WATCH_BUDGET:-0}" \
    "${only_mine:-0}" "${CIRCUIT_BREAKER_HALT:-}" > "$tmp"
  # Append per-PID dialog-stuck samples (issue #220, AC ❸).
  # R3 SSOT (issue #220 simplify pass): single iterator over both prefixes —
  # PRIOR_LAST_ACTIVITY_<pid> and FIRST_DIALOG_TS_<pid> share identical
  # persistence shape, so the prefix is the only variant.
  # Dual-shell enumeration (#270): `compgen -v PREFIX` is a bash builtin that
  # returns NOTHING under zsh — and write_run_state is re-sourced inside the
  # goal-pipeline SKILL.md bash fences, which run under /bin/zsh on macOS. The
  # per-PID stuck-dialog samples were therefore never persisted across fences,
  # compounding the dead detector. Enumerate via `env` instead: both sample
  # writers (uberdev_goal_agent_stuck_on_dialog) and the rehydration arm in
  # read_run_state `export` these keys, so they live in the process environment
  # in BOTH shells. `${var#$prefix}` strips the prefix; the int-validate on the
  # suffix rejects any forged/non-PID key; _uberdev_goal_indirect_get does the
  # dual-shell indirect read with native parameter expansion (T3 hard rule, G19).
  local _prefix _pid_var _pid_suffix _pid_val
  for _prefix in PRIOR_LAST_ACTIVITY_ FIRST_DIALOG_TS_; do
    for _pid_var in $(env | grep -oE "^${_prefix}[0-9]+=" | sed 's/=$//'); do
      _pid_suffix="${_pid_var#$_prefix}"
      _uberdev_goal_validate_int "$_pid_suffix" || continue
      _pid_val="$(_uberdev_goal_indirect_get "$_pid_var")"
      printf '%s=%s\n' "$_pid_var" "$_pid_val" >> "$tmp"
    done
  done
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

  # .candidates sidecar (#301, RFC 0012 §3.3 goal-R1 item 1) — mirrors the
  # .queue writer above with ONE addition: a `cycle=<N>` first-line tag.
  # new_candidates is built inside Phase-3 fence 1 (a fresh shell) and dies at
  # the fence boundary; without this sidecar the downstream fingerprint /
  # terminal fences rehydrated an EMPTY set and the terminal gate emitted
  # goal_converged with open BLOCKER/CRITICAL findings still pending (the live
  # false-converge BLOCKER). The cycle tag lets read_run_state refuse a
  # stale-cycle file (crash between gh query and flush) instead of feeding the
  # PRIOR cycle's candidates into the terminal gates.
  _uberdev_dispatch_prepare_tmp_target "${sc}.candidates" 0 "goal" || return 3
  tmp="$(mktemp "${sc}.candidates.XXXXXXXX")" || return 3
  _filtered="$(printf '%s\n' "${new_candidates[@]:-}" | grep -E '^[0-9]+$' || true)"
  if [ -n "$_filtered" ]; then
    printf 'cycle=%s\n%s\n' "${cycle:-0}" "$_filtered" > "$tmp" || { rm -f "$tmp"; return 3; }
  else
    printf 'cycle=%s\n' "${cycle:-0}" > "$tmp" || { rm -f "$tmp"; return 3; }
  fi
  mv -f "$tmp" "${sc}.candidates" || { rm -f "$tmp"; return 3; }

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
#   overflow_detected, MAX_CYCLES, UBERDEV_RESOLVED_BACKEND, MAX_PARALLEL,
#   BARRIER_TIMEOUT_S, barrier_start_ts, REVIEW_GRACE_SECS, WATCH_PASSES,
#   WATCH_BUDGET, only_mine (#301 — 0|1 allowlist, default 0) scalars,
#   rehydrates the queue/active_issues arrays plus the cycle-tagged
#   new_candidates array (#301 — rehydrated ONLY when the .candidates
#   sidecar's `cycle=<N>` first-line tag matches the scalar-rehydrated
#   cycle; a mismatched/absent tag yields an EMPTY array so a stale-cycle
#   file can never feed the terminal gates),
#   and EXPORTS UBERDEV_GOAL_ID + UBERDEV_TMPDIR
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
      REVIEW_GRACE_SECS)  _uberdev_goal_validate_int "$v" && REVIEW_GRACE_SECS="$v" ;;
      WATCH_PASSES)       _uberdev_goal_validate_int "$v" && WATCH_PASSES="$v" ;;
      WATCH_BUDGET)       _uberdev_goal_validate_int "$v" && WATCH_BUDGET="$v" ;;
      only_mine)
        # #301 — 0|1 allowlist (tighter than the int gate: this flag branches
        # the Phase-3 candidate query; a forged value must degrade to the
        # default-0 "no identity filter" arm, never widen into truthiness).
        case "$v" in 0|1) only_mine="$v" ;; esac ;;
      CIRCUIT_BREAKER_HALT)
        # CONTRACT: goal-circuit-breaker-reason -solver_failed !case-arm
        case "$v" in
          # DECLARED DIVERGENCE, not intent (found while wiring #370's Half A
          # guard, NOT in its register): goal-pipeline/SKILL.md's
          # GOAL_CIRCUIT_BREAKER_REASONS has NINE reasons; this rehydration
          # allowlist has eight — `solver_failed` (goal-phase3.sh; goal-watch.sh's three
          # sites went with the codex solver-status branch #381 deleted)
          # is missing. Latent today: only `agent_stuck_on_dialog` is ever
          # assigned to CIRCUIT_BREAKER_HALT, so nothing is dropped yet. The
          # arm has no else branch, so if that changes the value vanishes on the
          # next fresh-shell fence exactly as it did for UBERDEV_RESOLVED_BACKEND.
          max_cycles|nonconvergence|stuck_loop|merge_failed|gh_api_failed|unknown_merge_result|queue_empty_not_converged|agent_stuck_on_dialog)
            CIRCUIT_BREAKER_HALT="$v" ;;
        esac ;;
      PRIOR_LAST_ACTIVITY_*|FIRST_DIALOG_TS_*)
        # R3 SSOT (issue #220 simplify pass): collapsed two near-identical
        # case arms into one — both keys are PID-suffixed int values with
        # identical validation needs. Q3 fix folded in: uniform 64-char cap
        # on both prefixes (prior arms diverged — PRIOR_LAST_ACTIVITY_ had
        # the cap, FIRST_DIALOG_TS_ did not; behaviour now uniform).
        # B4 (post-impl-review): int-validate the value too — the stuck-on-
        # dialog detector stores row_count (int) here; without int-gating, a
        # non-integer value could round-trip via the sidecar and silently
        # break the string-equality progress comparison in
        # uberdev_goal_agent_stuck_on_dialog.
        local _suffix
        if [[ "$k" == PRIOR_LAST_ACTIVITY_* ]]; then
          _suffix="${k#PRIOR_LAST_ACTIVITY_}"
        else
          _suffix="${k#FIRST_DIALOG_TS_}"
        fi
        _uberdev_goal_validate_int "$_suffix" || continue
        _uberdev_goal_validate_int "$v" || continue
        [ "${#v}" -le 64 ] || continue
        printf -v "$k" '%s' "$v"
        export "$k" ;;
      UBERDEV_RESOLVED_BACKEND)
        # RFC 0015 added `workflow` to lib/dispatch.sh's
        # _UBERDEV_DISPATCH_BACKEND_ENUM but NOT to this allowlist, which is the
        # other half of the same change. The consequence was silent and nasty:
        # an unlisted value is DROPPED here (no else arm), so a fresh-shell
        # phase fence rehydrated an EMPTY UBERDEV_RESOLVED_BACKEND. Every
        # backend-dispatch `case` in this file then fell into its default arm —
        # the reaper's PID-based lane, and `claude agents --json` for liveness —
        # so a Workflow run was probed and reaped as if it were a detached
        # `background` session. Keep this list byte-aligned with the dispatch
        # enum minus `auto` (auto is a REQUEST, never a resolution).
        # CONTRACT: dispatch-backend -auto !case-arm
        case "$v" in workflow|wezterm|background) UBERDEV_RESOLVED_BACKEND="$v" ;; esac ;;
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

  # .candidates rehydrate (#301, RFC 0012 §3.3 goal-R1 item 1) — cycle-tag
  # gated. The first line must be `cycle=<N>` with N matching the cycle scalar
  # rehydrated ABOVE (the scalar block is parsed before the arrays, so $cycle
  # is already this run's value). On a missing/invalid/mismatched tag the
  # array stays EMPTY: a Phase-3 fence that crashed between the gh query and
  # its flush leaves the PRIOR cycle's file behind, and rehydrating that into
  # the terminal gates would re-merge already-queued candidates (double-
  # dispatch) or mask a real empty-query failure. Empty-on-mismatch is the
  # documented fail-safe; the fence-1 gh-rc breaker (gh_api_failed) is the
  # loud path for query failures.
  new_candidates=()
  if [ -r "${sc}.candidates" ]; then
    local line3 _cand_tag _cand_first
    _cand_tag=""
    _cand_first=1
    while IFS= read -r line3; do
      if [ "$_cand_first" = "1" ]; then
        _cand_first=0
        case "$line3" in cycle=*) _cand_tag="${line3#cycle=}" ;; esac
        _uberdev_goal_validate_int "${_cand_tag:-}" || break
        [ "$_cand_tag" = "${cycle:-0}" ] || break
        continue
      fi
      [ -n "$line3" ] || continue
      _uberdev_goal_validate_int "$line3" && new_candidates+=("$line3")
    done < "${sc}.candidates"
  fi

  # #301 — default the only_mine flag when the sidecar predates the field (or
  # carried a forged value): the Phase-3 fence branches on a bare
  # `[ "$only_mine" = "1" ]`, which must resolve to the safe "no identity
  # filter" arm in a fresh shell rather than tripping set -u.
  only_mine="${only_mine:-0}"

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
  export REVIEW_GRACE_SECS
  # #299 finding 2 — re-export the bounded-watch bound so a fresh-shell Phase-2
  # fence (and the per-pass write-back) keeps the same bound across tick-by-tick
  # re-invocations. Default 0 (unbounded) when the sidecar predates the field.
  export WATCH_PASSES="${WATCH_PASSES:-0}"
  export WATCH_BUDGET="${WATCH_BUDGET:-0}"
  export CIRCUIT_BREAKER_HALT
  return 0
}

# _uberdev_goal_reap_zombies   (issue #220, AC reaper)
# Best-effort kill of every PID stashed in solve-bg-status-<ISSUE>.json for
# every issue in this goal's batch-prs.tsv. Per-backend short-circuit:
# wezterm cannot be reaped (no PID visibility — security.md);
# background backend gets full TERM->sleep 2->KILL with owner-gate. Emits
# goal_reaper_kill per kill + goal_reaper_skipped once per skip-backend.
# Never aborts the caller: || true on every step.
_uberdev_goal_reap_zombies() {
  local goal_id="${UBERDEV_GOAL_ID:-}"
  [ -n "$goal_id" ] || return 0
  local batch_tsv="$UBERDEV_TMPDIR/goal-$goal_id-batch-prs.tsv"
  [ -f "$batch_tsv" ] || return 0

  case "${UBERDEV_RESOLVED_BACKEND:-}" in
    wezterm)
      uberdev_goal_audit goal_reaper_skipped \
        "{\"goal_id\":\"$goal_id\",\"backend\":\"${UBERDEV_RESOLVED_BACKEND}\",\"reason\":\"no_pid_visibility\"}" || true
      return 0
      ;;
    workflow)
      # RFC 0015 — a Workflow fleet is not a process tree this shell owns. Its
      # agents are children of the calling session's Workflow runtime, there is
      # no per-issue PID stash to read, and cancellation belongs to that runtime
      # (TaskStop / skip), not to a kill(2) from here. Falling through to the
      # PID lane below would read whatever stale solve-bg-status-<issue>.json a
      # PREVIOUS detached run left in TMPDIR and TERM/KILL an unrelated live
      # process. Skip explicitly, with its own reason so the audit trail does
      # not conflate it with the wezterm no-PID case.
      uberdev_goal_audit goal_reaper_skipped \
        "{\"goal_id\":\"$goal_id\",\"backend\":\"workflow\",\"reason\":\"runtime_owned_lifecycle\"}" || true
      return 0
      ;;
    # background: falls through to the PID-based reap below. It captures the
    # spawned process PID in the per-issue status file
    # (_uberdev_goal_pid_for_issue reads it), so the kill -0 / kill -TERM
    # contract applies. #381 removed the codex arm that shared this path.
  esac

  local issue pid result owner_me pr _ts _state
  owner_me="$(id -un 2>/dev/null)" || return 0

  while IFS=$'\t' read -r pr issue _ts _state; do
    # R1 SSOT (issue #220 simplify pass): PID extraction via shared helper.
    pid="$(_uberdev_goal_pid_for_issue "$issue")" || continue
    kill -0 "$pid" 2>/dev/null || continue
    local pid_owner
    pid_owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')" || true
    if [ -z "$pid_owner" ] || [ "$pid_owner" != "$owner_me" ]; then
      uberdev_goal_audit goal_reaper_kill \
        "{\"goal_id\":\"$goal_id\",\"pr\":$pr,\"pid\":$pid,\"signal\":\"TERM\",\"result\":\"owner_mismatch\"}" || true
      continue
    fi
    # B11 (post-impl-review): pre-probe with kill -0 so non-zero kill -TERM
    # rc can be classified correctly — `already_dead` (ESRCH: process gone)
    # vs `signal_rejected` (EPERM: process alive but kernel refused TERM,
    # e.g., wrong-uid race even after the earlier owner check). Without
    # this, a permission-denied SIGTERM is silently logged as `already_dead`
    # and the reaper's audit trail misclassifies a live-but-unkillable PID.
    if kill -TERM "$pid" 2>/dev/null; then
      result="killed"
    elif kill -0 "$pid" 2>/dev/null; then
      result="signal_rejected"
    else
      result="already_dead"
    fi
    uberdev_goal_audit goal_reaper_kill \
      "{\"goal_id\":\"$goal_id\",\"pr\":$pr,\"pid\":$pid,\"signal\":\"TERM\",\"result\":\"$result\"}" || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      # B9 (post-impl-review): capture kill -KILL rc and record `kill_failed`
      # distinctly. The prior code emitted `result: killed` unconditionally,
      # even when the SIGKILL itself returned non-zero (EPERM / ESRCH on a
      # process gone in the 2s window). Surfacing kill_failed is a critical
      # operational signal — the reaper claims a kill it never landed.
      if kill -KILL "$pid" 2>/dev/null; then
        result="killed"
      else
        result="kill_failed"
      fi
      uberdev_goal_audit goal_reaper_kill \
        "{\"goal_id\":\"$goal_id\",\"pr\":$pr,\"pid\":$pid,\"signal\":\"KILL\",\"result\":\"$result\"}" || true
    fi
  done < "$batch_tsv"
  return 0
}

# _uberdev_goal_handle_harness_term   (#301, RFC 0012 §3.3 goal-R1 item 3)
# TERM-trap body for the Phase-2 watch fence. Under the Claude-Code Bash tool
# a single call is hard-capped at 600s; when the cap lands the harness delivers
# SIGTERM to the still-running fence. The pre-#301 TERM trap chained into
# _uberdev_goal_reap_zombies — so the HARNESS CAP (not an operator abort)
# killed every live solver ~10 minutes into a healthy run. TERM cannot
# distinguish an operator `kill -TERM` from the harness cap, so the TERM path
# now uniformly takes the harness interpretation:
#   1. persist run-state (best-effort — the fence's live scalars/arrays are
#      still in scope inside the trap, so the next tick rehydrates them);
#   2. emit a goal_reaper_skipped audit row (reason=harness_term) so the
#      no-reap choice stays visible post-mortem;
#   3. exit 42 — the bounded-tick "still-active, re-invoke" contract code —
#      WITHOUT reaping (bg solver agents survive; the harness re-invokes the
#      Phase-2 fence which rehydrates and resumes the watch).
# Operator stop is INT (Ctrl-C — still reaps via the INT trap) or an explicit
# _uberdev_goal_reap_zombies invocation.
_uberdev_goal_handle_harness_term() {
  uberdev_goal_write_run_state || \
    printf 'goal-state: WARN run-state flush failed inside the TERM trap — next tick may rehydrate stale state\n' >&2
  uberdev_goal_audit goal_reaper_skipped \
    "{\"goal_id\":\"${UBERDEV_GOAL_ID:-unknown}\",\"reason\":\"harness_term\",\"exit\":42}" || true
  exit 42
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
  rm -f "$sc" "${sc}.queue" "${sc}.active" "${sc}.candidates" "$tmpdir/goal-$GOAL_ID-batch-prs.tsv" 2>/dev/null
  # Remove the fixed-path pointer only if it still names THIS goal, so a
  # concurrent goal's pointer is never clobbered.
  local aid="$tmpdir/goal-active-id.txt"
  if [ -r "$aid" ] && [ "$(head -n1 "$aid" 2>/dev/null)" = "$GOAL_ID" ]; then
    rm -f "$aid" 2>/dev/null
  fi
  return 0
}
