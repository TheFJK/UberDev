# shellcheck shell=bash
# Generated under R1+R2 root fix (see CHANGELOG v0.19.3)
#
# Why this exists: gh's spinner / progress bytes leak into stdout when /merge
# pipes `gh ... --json` into an external `jq`, which crashes the pipeline with
# "Invalid string: control characters from U+0000 through U+001F must be
# escaped". R1 collapses every gh|jq pipeline into `gh ... --jq '<filter>'`
# (in-process; no FD pollution). R2 lifts the three discovery sites out of
# SKILL.md prose into this real lib so the model cannot improvise a `2>&1`
# back in. Each function emits a `discovery_gh_failed` audit event on failure.

if [ "${_UBERDEV_MERGE_DISCOVER_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_MERGE_DISCOVER_LOADED=1

# _uberdev_discover_audit_path
# Resolve the audit-log path. Tests redirect via UBERDEV_AUDIT_LOG_PATH;
# production defaults to .uberdev/audit.jsonl (best-effort, pre-lock context).
_uberdev_discover_audit_path() {
  printf '%s' "${UBERDEV_AUDIT_LOG_PATH:-.uberdev/audit.jsonl}"
}

# _uberdev_discover_iso_ts
# Emit a UTC ISO8601 timestamp. POSIX-portable on macOS bash 3.2 (BSD date).
_uberdev_discover_iso_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _uberdev_discover_truncate FILE
# Echo the first 512 bytes of FILE, JSON-escaped (backslashes, quotes, and
# control bytes \n \r \t are escaped; other C0/C1 + DEL dropped via tr).
# Bash 3.2 + POSIX tools only (no GNU-sed multiline-label extensions —
# BSD sed on macOS rejects `:a;N;$!ba`, which would silently produce
# unescaped raw newlines and corrupt the JSONL audit log).
_uberdev_discover_truncate() {
  local file="$1"
  if [ ! -r "$file" ]; then
    printf ''
    return 0
  fi
  # Read first 512 bytes, then escape JSON-meaningful characters in awk.
  # awk reads byte-by-byte via getc-style RS="" emulation; using the
  # "feed each character" pattern keeps the scan portable across BSD
  # awk (macOS) and gawk. Drop C0/C1 + DEL except \n \r \t, then escape.
  head -c 512 "$file" 2>/dev/null \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C awk '
        BEGIN { ORS = ""; out = "" }
        {
          line = $0
          gsub(/\\/, "\\\\", line)
          gsub(/"/, "\\\"", line)
          gsub(/\r/, "\\r", line)
          gsub(/\t/, "\\t", line)
          out = out (NR > 1 ? "\\n" : "") line
        }
        END { print out }
      '
}

# _uberdev_discover_json_escape_str STRING
# Emit STRING JSON-escaped (backslash, quote, \n \r \t escaped; other
# C0/C1 + DEL dropped via tr). Defense-in-depth for enum-shaped fields
# (reason, step) interpolated into audit-log JSON via bare-string printf.
# Today every call site passes a static enum literal, so this is unreachable
# given current callers — but the function signatures do not enforce that
# discipline, and a future caller passing a dynamic string would otherwise
# corrupt the audit log. Mirrors the awk shape used by
# _uberdev_discover_truncate so behaviour is identical for any input the
# truncate path would also accept.
_uberdev_discover_json_escape_str() {
  printf '%s' "$1" \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C awk '
        BEGIN { ORS = ""; out = "" }
        {
          line = $0
          gsub(/\\/, "\\\\", line)
          gsub(/"/, "\\\"", line)
          gsub(/\r/, "\\r", line)
          gsub(/\t/, "\\t", line)
          out = out (NR > 1 ? "\\n" : "") line
        }
        END { print out }
      '
}

# _uberdev_discover_emit_audit REASON STEP EXIT_CODE STDERR_FILE [PR_NUMBER]
# Best-effort append of one discovery_gh_failed event to the audit log.
# Pre-lock context — no run_id required (mirrors Step 1.0a's
# uberdev_config_read precedent of writing to .uberdev/audit.jsonl directly).
# Never fails the caller if the log write fails (`|| true`).
_uberdev_discover_emit_audit() {
  local reason="$1"
  local step="$2"
  local exit_code="$3"
  local stderr_file="$4"
  local pr_number="${5:-}"
  local audit_path
  audit_path="$(_uberdev_discover_audit_path)"
  local audit_dir
  audit_dir="$(dirname "$audit_path")"
  local stderr_truncated
  stderr_truncated="$(_uberdev_discover_truncate "$stderr_file")"
  local ts
  ts="$(_uberdev_discover_iso_ts)"
  # Sanitise numerics so a non-integer exit_code / pr_number cannot inject
  # malformed-or-attacker-shaped JSON into the audit log (defense in depth —
  # both fields come from gh-validated sources today, but the contract is
  # bare-numeric in the JSON shape per the AUDIT_EVENT_ENUM doc).
  case "$exit_code" in ''|*[!0-9-]*) exit_code=-1 ;; esac
  case "$pr_number" in ''|*[!0-9]*) pr_number="" ;; esac
  # JSON-escape string fields. Today's callers pass static enum literals
  # (reason ∈ {gh_failed, jq_failed}; step ∈ {1.0.5, 1.2.5, 1.4}), so these
  # escapes are no-ops in practice — the helper is here so the function
  # contract no longer relies on caller discipline. stderr_truncated is
  # already escaped by _uberdev_discover_truncate above.
  local reason_escaped step_escaped
  reason_escaped="$(_uberdev_discover_json_escape_str "$reason")"
  step_escaped="$(_uberdev_discover_json_escape_str "$step")"
  # Ensure parent dir exists (best-effort).
  mkdir -p "$audit_dir" 2>/dev/null || true
  if [ -n "$pr_number" ]; then
    printf '{"ts":"%s","event":"discovery_gh_failed","data":{"reason":"%s","step":"%s","exit_code":%s,"gh_stderr":"%s","pr_number":%s}}\n' \
      "$ts" "$reason_escaped" "$step_escaped" "$exit_code" "$stderr_truncated" "$pr_number" \
      >> "$audit_path" 2>/dev/null || true
  else
    printf '{"ts":"%s","event":"discovery_gh_failed","data":{"reason":"%s","step":"%s","exit_code":%s,"gh_stderr":"%s"}}\n' \
      "$ts" "$reason_escaped" "$step_escaped" "$exit_code" "$stderr_truncated" \
      >> "$audit_path" 2>/dev/null || true
  fi
}

# _uberdev_discover_warn STEP_LABEL EXIT_CODE STDERR_FILE
# Emit one stderr breadcrumb (truncated to 512 bytes of stderr).
_uberdev_discover_warn() {
  local label="$1"
  local exit_code="$2"
  local stderr_file="$3"
  local truncated
  if [ -r "$stderr_file" ]; then
    truncated="$(head -c 512 "$stderr_file" 2>/dev/null \
                 | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  else
    truncated=""
  fi
  printf 'warning: %s (gh exit %s): %s\n' "$label" "$exit_code" "$truncated" >&2
}

# discover_bare_fast_path CURRENT_BRANCH
# Stdout: integer N (count of open non-draft PRs whose HEAD = current_branch).
# Exit:   0 on success (incl. N=0); 1 on gh-or-jq failure.
# Stderr: warning on failure (see _uberdev_discover_warn).
# Audit:  discovery_gh_failed with step="1.0.5" on failure.
# Implementation: in-process `gh ... --jq 'length'` (R1 root fix — no
# external jq pipe, eliminating FD-pollution surface).
discover_bare_fast_path() {
  local current_branch="$1"
  local gh_err
  gh_err="$(mktemp)"
  # Function-scoped trap; bash 3.2 supports RETURN trap idiom.
  # shellcheck disable=SC2064  # intentional immediate expansion of $gh_err
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr list \
    --head "$current_branch" \
    --state open \
    --search 'draft:false' \
    --json number,headRefOid \
    --jq 'length' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "bare-mode discovery failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.0.5" "$gh_exit" "$gh_err"
    return 1
  fi

  # Validate result is an integer (jq 'length' on a non-array → would have
  # exited non-zero above; defensive numeric check guards against future
  # gh-CLI changes that emit informational stdout text alongside JSON).
  case "$result" in
    ''|*[!0-9]*)
      _uberdev_discover_warn "bare-mode discovery returned non-integer" "$gh_exit" "$gh_err"
      _uberdev_discover_emit_audit "jq_failed" "1.0.5" "$gh_exit" "$gh_err"
      return 1
      ;;
  esac

  printf '%s\n' "$result"
  return 0
}

# discover_multi INTEGRATION_BRANCH
# Stdout: JSON array of candidate PRs (or '[]' on failure — Step 1.7's
#         clean-exit-0 contract still applies).
# Exit:   0 always (gh-or-jq failure → '[]' + audit event).
# Stderr: warning on failure.
# Audit:  discovery_gh_failed with step="1.2.5" on failure.
# Implementation: gh's in-process --jq filter does the isDraft==false
# belt-and-suspenders filter; no external jq pipe.
discover_multi() {
  local integration_branch="$1"
  local gh_err
  gh_err="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr list \
    --base "$integration_branch" \
    --state open \
    --search 'draft:false' \
    --json number,title,headRefOid,headRefName,baseRefName,isDraft,createdAt,reviewDecision,labels,body,author,headRepositoryOwner \
    --jq '[.[] | select(.isDraft==false)]' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "multi-discover failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.2.5" "$gh_exit" "$gh_err"
    printf '[]\n'
    return 0
  fi

  # Empty stdout on a 0-exit gh is unexpected (jq identity on empty would
  # have errored); treat as jq_failed and fall back to '[]'.
  if [ -z "$result" ]; then
    _uberdev_discover_warn "multi-discover returned empty stdout" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "jq_failed" "1.2.5" "$gh_exit" "$gh_err"
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "$result"
  return 0
}

# pr_view_projection PR_NUMBER
# Stdout: JSON object with the 15 fields Step 1.4 trust gate consumes.
# Exit:   0 on success; 1 on gh-or-jq failure.
# Stderr: warning on failure.
# Audit:  discovery_gh_failed with step="1.4" and pr_number=<N> on failure.
# Implementation: identity --jq '.' filter routes the projection through
# gh's in-process JSON parser before reaching stdout (R1 root fix —
# downstream callers can safely use `<<<"$PR_JSON"` herestrings because
# the bytes are clean by construction).
pr_view_projection() {
  local pr_number="$1"
  local gh_err
  gh_err="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f \"$gh_err\"" RETURN

  local result
  result="$(gh pr view "$pr_number" \
    --json state,isDraft,reviewDecision,statusCheckRollup,headRepository,maintainerCanModify,isCrossRepository,headRefName,headRefOid,baseRefName,body,commits,labels,createdAt,author \
    --jq '.' \
    2>"$gh_err")"
  local gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    _uberdev_discover_warn "pr_view_projection #$pr_number failed" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "gh_failed" "1.4" "$gh_exit" "$gh_err" "$pr_number"
    return 1
  fi

  if [ -z "$result" ]; then
    _uberdev_discover_warn "pr_view_projection #$pr_number returned empty stdout" "$gh_exit" "$gh_err"
    _uberdev_discover_emit_audit "jq_failed" "1.4" "$gh_exit" "$gh_err" "$pr_number"
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

# emit_gate_fail PR_NUMBER REASON
# Discovery-adjacent helper. Appends one gate_fail event to the audit log
# with {event:"gate_fail",pr:<N>,data:{reason:"<reason>"}} and writes a
# stderr breadcrumb. Mirrors the inline gate_fail pattern used elsewhere
# in /merge so Step 1.4's `pr_view_projection` failure path can short-
# circuit cleanly when the projection lib call fails.
emit_gate_fail() {
  local pr_number="$1"
  local reason="$2"
  # Bare-numeric pr_number in JSON; sanitise non-integer input to 0 so the
  # emitted line stays valid JSON regardless of caller bugs.
  case "$pr_number" in ''|*[!0-9]*) pr_number=0 ;; esac
  # JSON-escape reason. Today's only caller passes the static enum
  # GATE_FAIL_REASON_ENUM literal "pr_view_unreachable" — escape is a no-op
  # there. Defense-in-depth so the function contract no longer relies on
  # caller discipline (mirrors _uberdev_discover_emit_audit).
  local reason_escaped
  reason_escaped="$(_uberdev_discover_json_escape_str "$reason")"
  local audit_path
  audit_path="$(_uberdev_discover_audit_path)"
  local audit_dir
  audit_dir="$(dirname "$audit_path")"
  local ts
  ts="$(_uberdev_discover_iso_ts)"
  mkdir -p "$audit_dir" 2>/dev/null || true
  printf '{"ts":"%s","event":"gate_fail","pr":%s,"data":{"reason":"%s"}}\n' \
    "$ts" "$pr_number" "$reason_escaped" \
    >> "$audit_path" 2>/dev/null || true
  printf 'gate_fail: PR #%s reason=%s\n' "$pr_number" "$reason" >&2
}
