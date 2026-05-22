# plugins/uberdev/lib/dispatch.sh
#
# Dispatch-backend abstraction for /solve and /turbo (RFC 0004).
# SOURCED, never executed. No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_dispatch_preflight                       -> resolves auto -> concrete backend
#   uberdev_dispatch_one  ISSUE_NUM TIER PROMPT_FILE  -> dispatch one issue
# Internal:
#   _uberdev_dispatch_claude_bg / _uberdev_dispatch_wezterm / _uberdev_dispatch_background
#
# Sourced by:
#   - skills/solve-pipeline/SKILL.md Step 5b'
#   - tests/dispatch-claude-bg.test.sh, dispatch-fallback.test.sh,
#     dispatch-background.test.sh, dispatch-wezterm.test.sh
#
# All variable expansions are double-quoted (mirrors lib/config-read.sh discipline).
# Source-time idempotent: the guard below makes repeat `source` calls cheap.

if [ "${_UBERDEV_DISPATCH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_DISPATCH_LOADED=1

# The dispatch_backend enum — identical to the --backend= flag's accepted set.
_UBERDEV_DISPATCH_BACKEND_ENUM='auto|claude-bg|wezterm|background'

# _uberdev_dispatch_os_class -> prints one of: macos | windows-native | wsl2 | linux
# WSL2 is detected via /proc/version containing "microsoft" (case-insensitive);
# native Windows via $OS=Windows_NT with no WSL marker; macOS via uname.
_uberdev_dispatch_os_class() {
  local _uname
  _uname="$(uname -s 2>/dev/null)"
  case "$_uname" in
    Darwin) printf 'macos'; return 0 ;;
  esac
  if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    printf 'wsl2'; return 0
  fi
  case "${OS:-}" in
    Windows_NT) printf 'windows-native'; return 0 ;;
  esac
  case "$_uname" in
    MINGW*|MSYS*|CYGWIN*) printf 'windows-native'; return 0 ;;
  esac
  printf 'linux'
}

# _uberdev_dispatch_audit EVENT JSON
# Delegate to the SKILL.md-defined _uberdev_audit_emit when present; else no-op.
# Keeps lib/dispatch.sh independently sourceable in tests.
_uberdev_dispatch_audit() {
  if command -v _uberdev_audit_emit >/dev/null 2>&1; then
    # _uberdev_audit_emit is defined but failed: the dispatch must still
    # proceed (audit is best-effort, not load-bearing), but a silently
    # dropped audit event leaves the run trail incomplete with no trace.
    # Emit a stderr warning so the gap is at least diagnosable. The
    # not-defined branch stays a deliberate graceful no-op (tests source
    # this file standalone without the SKILL.md audit harness).
    _uberdev_audit_emit "$1" "$2" || echo "warning: audit failed for event $1" >&2
  fi
}

# _uberdev_dispatch_wezterm_available -> exit 0 if wezterm usable, 1 otherwise.
# Usable = binary on PATH AND the `uberdev` mux domain answers list-clients
# within the poll budget (cold-start race guard, RFC §3.6). Starts
# wezterm-mux-server if the mux is not already up. EVERY `wezterm cli` call
# below MUST pass `--domain-name uberdev` so the probe targets the same mux
# domain the spawn step uses; querying the default (stray) WezTerm instance
# would defeat the fan-out-isolation guarantee (RFC §3.6, B1 fix).
_uberdev_dispatch_wezterm_available() {
  command -v wezterm >/dev/null 2>&1 || return 1
  # S9: the list-clients probe is needed twice (each poll iteration and the
  # final post-loop attempt). Defining it once structurally enforces the
  # `--domain-name uberdev` mux-pin invariant so the probe cannot drift to
  # the default (stray) WezTerm instance at one site but not the other. Pure
  # extraction — byte-identical command + redirections, same exit status.
  _wt_probe() { wezterm cli --domain-name uberdev list-clients >/dev/null 2>&1; }
  local i
  for i in 1 2 3 4 5; do
    if _wt_probe; then
      return 0
    fi
    wezterm-mux-server --daemonize >/dev/null 2>&1 || true
    sleep 1
  done
  _wt_probe
}

# uberdev_dispatch_preflight
# Resolves UBERDEV_DISPATCH_BACKEND_REQUESTED (auto|claude-bg|wezterm|background)
# to a concrete UBERDEV_RESOLVED_BACKEND, ONCE per invocation, committed for
# the whole batch (no mid-fanout switch). Hard-errors (return 1) when an
# explicit backend is unusable on this host. Emits dispatch_backend_resolved.
uberdev_dispatch_preflight() {
  local requested="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-auto}"
  local os_class reason resolved
  os_class="$(_uberdev_dispatch_os_class)"
  case "$requested" in
    claude-bg|background)
      # claude-bg / background depend only on git + claude + shell — usable
      # on every OS class. No capability gate.
      resolved="$requested"; reason="explicit" ;;
    wezterm)
      # Explicit wezterm: validate mux usability AND the same-OS constraint.
      if [ "$os_class" = "wsl2" ]; then
        echo "error: --backend=wezterm from WSL2 cannot drive a native-Windows WezTerm" >&2
        echo "       (WSL2 dropped AF_UNIX mux interop; WSLg is GUI-only). Run /solve" >&2
        echo "       from the same OS side as WezTerm, or use --backend=background." >&2
        return 1
      fi
      if ! _uberdev_dispatch_wezterm_available; then
        echo "error: --backend=wezterm requested but WezTerm is unavailable" >&2
        echo "       (binary missing, or the mux failed to come up). Install WezTerm" >&2
        echo "       or use --backend=background. See RFC 0004 §3.6." >&2
        return 1
      fi
      resolved="wezterm"; reason="explicit" ;;
    auto)
      case "$os_class" in
        macos)
          if _uberdev_dispatch_wezterm_available; then resolved="wezterm"; reason="auto-macos-wezterm"
          else resolved="claude-bg"; reason="auto-macos-fallback"; fi ;;
        windows-native)
          if _uberdev_dispatch_wezterm_available; then resolved="wezterm"; reason="auto-windows-wezterm"
          else resolved="background"; reason="auto-windows-fallback"; fi ;;
        wsl2)
          resolved="claude-bg"; reason="auto-wsl2" ;;
        *)
          resolved="claude-bg"; reason="auto-linux" ;;
      esac ;;
    *)
      echo "error: dispatch backend '$requested' not in {$_UBERDEV_DISPATCH_BACKEND_ENUM}" >&2
      return 1 ;;
  esac
  export UBERDEV_RESOLVED_BACKEND="$resolved"
  _uberdev_dispatch_audit dispatch_backend_resolved \
    "{\"requested\":\"$requested\",\"resolved\":\"$resolved\",\"os_class\":\"$os_class\",\"reason\":\"$reason\"}"
  return 0
}

# ---------------------------------------------------------------------------
# uberdev_dispatch_resolve_env
# Resolves the six deterministic dispatch-env vars consumed by every backend:
#   BG_PROMPT_MODE, MODEL, PERM_FLAG[], EFFORT_FLAG[], SOLVE_TIMEOUT, TIMEOUT_BIN.
# SSOT for both solve-pipeline (replaces its inline Phase A block) and
# goal-pipeline (Phase 0). Sourced, NEVER exec'd — PERM_FLAG/EFFORT_FLAG are
# bash arrays that cannot survive an env(1)/fork+exec boundary, so they must be
# set in the caller's shell scope. Idempotent: deterministic scalars, arrays
# rebuilt each call. Returns 1 (fail-loud) when no timeout(1)/gtimeout(1) is on
# PATH. Does NOT read or write UBERDEV_RESOLVED_BACKEND (that is preflight's;
# RFC 0005 D15 constrains backend resolution only — env resolution is exempt).
# Inputs (read with safe defaults so goal-pipeline, which has no arg-parser,
# can call it): AUTO_PERMISSIONS (default 0), EFFORT_LEVEL (default max).
uberdev_dispatch_resolve_env() {
  # BG_PROMPT_MODE: hardcoded `argv` (claude --bg 2.1.139 has no documented
  # --prompt-file / stdin form; the file/stdin arms in _uberdev_dispatch_claude_bg
  # remain a pre-wired migration target, unexercised at runtime).
  BG_PROMPT_MODE=argv

  # MODEL: single-quoted to keep zsh from glob-evaluating [1m] under NOMATCH.
  MODEL='claude-opus-4-7[1m]'

  # PERM_FLAG: array form (zsh SH_WORD_SPLIT=off would treat a scalar at command
  # position as one argv slot). Empty by default; populated only when the caller
  # opted into --permission-mode auto via AUTO_PERMISSIONS=1.
  AUTO_PERMISSIONS="${AUTO_PERMISSIONS:-0}"
  PERM_FLAG=()
  [[ "$AUTO_PERMISSIONS" == "1" ]] && PERM_FLAG=( --permission-mode auto )

  # EFFORT_FLAG: threaded form of EFFORT_LEVEL (default max for callers without
  # an --effort parser, e.g. goal-pipeline). Bash+zsh array.
  EFFORT_LEVEL="${EFFORT_LEVEL:-max}"
  EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )

  # Wall-clock timeout: read command_timeouts.solve (env override
  # UBERDEV_SOLVE_TIMEOUT; default 3600s; range [60, 86400]). Guard with
  # `command -v` so this block is independently sourceable.
  if command -v uberdev_read_int_in_range >/dev/null 2>&1; then
    SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
  elif [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
    SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
  else
    echo "warning: config-read.sh not found at ${CLAUDE_PLUGIN_ROOT:-}/lib/; uberdev.local.md timeout settings ignored" >&2
    SOLVE_TIMEOUT=3600
  fi

  # TIMEOUT_BIN probe (RFC 0004 §3.8 order — MSYS coreutils absolute path FIRST,
  # then Unix `timeout`, then macOS Homebrew `gtimeout`). MOVED VERBATIM.
  TIMEOUT_BIN=""
  if   [ -x /usr/bin/timeout ];                 then TIMEOUT_BIN=/usr/bin/timeout
  elif command -v timeout  >/dev/null 2>&1;     then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1;     then TIMEOUT_BIN=gtimeout
  fi

  # Runtime guard: fail-loud if neither timeout(1) nor gtimeout(1) is on PATH.
  # Regression guard: tests/config-override.test.sh I2f anchors on this
  # `if [[ -n "$TIMEOUT_BIN" ]]; then` pattern; do not collapse to `[[ … ]] ||`.
  if [[ -n "$TIMEOUT_BIN" ]]; then
    : # timeout(1) or gtimeout(1) available; bg dispatch arms wrap correctly
  else
    echo "error: neither timeout(1) nor gtimeout(1) found on PATH" >&2
    echo "       install with: brew install coreutils  # provides gtimeout" >&2
    return 1
  fi
  return 0
}

# uberdev_dispatch_one ISSUE_NUM TIER PROMPT_FILE
# Routes one issue to the backend resolved by uberdev_dispatch_preflight.
# Sets DISPATCH_RC + DISPATCH_ID (+ DISPATCH_LOG on failure); returns the backend's rc.
uberdev_dispatch_one() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  # Reset the caller-visible out-params so a prior iteration's values — esp.
  # DISPATCH_LOG, which a backend sets only on its error path — never leak
  # into a subsequent success (T6/T7 code-review finding; central SSOT reset).
  DISPATCH_RC=0
  DISPATCH_ID=""
  DISPATCH_LOG=""
  if [ -z "${UBERDEV_RESOLVED_BACKEND:-}" ]; then
    uberdev_dispatch_preflight || { DISPATCH_RC=1; return 1; }
  fi
  case "${UBERDEV_RESOLVED_BACKEND:-}" in
    claude-bg)   _uberdev_dispatch_claude_bg  "$ISSUE_NUM" "$TIER" "$PROMPT_FILE" ;;
    wezterm)     _uberdev_dispatch_wezterm    "$ISSUE_NUM" "$TIER" "$PROMPT_FILE" ;;
    background)  _uberdev_dispatch_background  "$ISSUE_NUM" "$TIER" "$PROMPT_FILE" ;;
    *)
      # Unreachable by design — uberdev_dispatch_preflight only ever exports
      # one of the three concrete backends (or returns non-zero, handled
      # above). Still emit dispatch_setup_failed so an out-of-band mutation
      # of UBERDEV_RESOLVED_BACKEND leaves an audit trace like every other
      # failure arm in this file, rather than only an stderr line.
      echo "error: uberdev_dispatch_one: unresolved backend '${UBERDEV_RESOLVED_BACKEND:-}'" >&2
      DISPATCH_RC=1
      _uberdev_dispatch_audit dispatch_setup_failed \
        "{\"issue\":$ISSUE_NUM,\"phase\":\"unresolved_backend\",\"backend\":\"${UBERDEV_RESOLVED_BACKEND:-}\",\"rc\":1}"
      return 1 ;;
  esac
  # Explicit return of the backend's rc. Each backend already returns its
  # own DISPATCH_RC, so the case statement's exit status is well-defined
  # today; this makes the function contract explicit and stops a future
  # backend arm that forgets to `return` from silently leaking the rc of
  # whatever ran last inside it.
  return "$DISPATCH_RC"
}

# _uberdev_dispatch_claude_bg ISSUE_NUM TIER PROMPT_FILE
# Extract of the v0.22.0 inline `claude --bg` dispatch. Sets DISPATCH_RC and
# DISPATCH_ID (the bg session id) for the caller. No behaviour change.
# --- TOCTOU symlink-swap / pre-creation guard for predictable tmp paths (#155) ---
# $UBERDEV_TMPDIR is world-writable (default /tmp) and the bg-stdout / status
# paths are intentionally PREDICTABLE so the /goal watcher can poll them by name
# — mktemp-randomisation would break that discovery contract. Instead, guard
# every predictable redirect target before writing: reject a symlink (an
# attacker can point it at a victim file so our `>` clobbers it, or so the
# DISPATCH_ID extraction reads attacker-chosen bytes) and reject an entry NOT
# owned by the current EUID (pre-creation in a non-sticky dir) or one that is
# not a regular file. A same-EUID regular file is allowed (legitimate
# re-dispatch — `>` truncates it). Returns non-zero on reject.
_uberdev_dispatch_tmp_target_safe() {
  local target="$1" owner_uid
  if [ -L "$target" ]; then
    echo "error: refusing to write through a symlink at the predicted path: $target (possible TOCTOU symlink-swap)" >&2
    return 1
  fi
  if [ -e "$target" ]; then
    # Probe GNU `stat -c` FIRST, then BSD `stat -f`. Ordering is load-bearing:
    # GNU stat treats `-f` as --file-system, so `stat -f '%u' FILE` on Linux
    # prints filesystem info (non-empty, with a non-zero rc from the bogus '%u'
    # operand) instead of failing cleanly — probing `-f` first there yields a
    # garbage owner_uid that never equals `id -u` and spuriously fail-closes
    # the happy path. The integer-validation below is the backstop: any
    # garbage / empty result → undeterminable → fail CLOSED.
    owner_uid="$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target" 2>/dev/null || true)"
    case "$owner_uid" in ''|*[!0-9]*) owner_uid="" ;; esac
    if [ -z "$owner_uid" ]; then
      # stat unavailable / unparseable in BOTH GNU (-c) and BSD (-f) forms
      # (e.g. busybox / minimal image). We cannot prove the entry is ours, so
      # fail CLOSED — an empty owner_uid must NOT skip the ownership gate (that
      # would let an attacker-owned pre-created file through). The symlink +
      # regular-file checks do NOT backstop ownership, so this is load-bearing.
      echo "error: cannot determine owner of predicted path (stat -c/-f both failed): $target — failing closed" >&2
      return 1
    fi
    if [ "$owner_uid" != "$(id -u)" ]; then
      echo "error: refusing predicted path owned by uid=$owner_uid (expected $(id -u)): $target (possible pre-creation attack)" >&2
      return 1
    fi
    if [ ! -f "$target" ]; then
      echo "error: predicted path exists and is not a regular file: $target" >&2
      return 1
    fi
  fi
  return 0
}

# _uberdev_dispatch_prepare_tmp_target PATH ISSUE_NUM BACKEND
#   Guard PATH (above), then (re)create it 0600-owned-by-us under `set -C`
#   (noclobber) so the create fails if anything races into the path after the
#   guard, and the sticky bit on $UBERDEV_TMPDIR then protects the file we own
#   from a later swap. Emits a dispatch_setup_failed audit + returns 3 on any
#   failure (fail-CLOSED). This is the spec-accepted mitigation (#155): it
#   decisively raises the bar without a C-level O_NOFOLLOW open, which bash
#   redirects cannot express; the residual guard→create window is closed by
#   `set -C`, and the create→use window by the sticky-dir ownership invariant.
_uberdev_dispatch_prepare_tmp_target() {
  local target="$1" issue="$2" backend="$3"
  if ! _uberdev_dispatch_tmp_target_safe "$target"; then
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"tmp_target_unsafe\",\"backend\":\"$backend\",\"rc\":3}"
    return 3
  fi
  rm -f -- "$target" 2>/dev/null
  if ! ( umask 077; set -C; : > "$target" ) 2>/dev/null; then
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$issue,\"phase\":\"tmp_target_create\",\"backend\":\"$backend\",\"rc\":3}"
    return 3
  fi
  return 0
}

_uberdev_dispatch_claude_bg() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local BG_STDOUT_LOG="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  # TOCTOU hardening (#155): guard + 0600-create the predictable bg-stdout path
  # before any case arm redirects to it (3 redirect sites below).
  if ! _uberdev_dispatch_prepare_tmp_target "$BG_STDOUT_LOG" "$ISSUE_NUM" "claude-bg"; then
    DISPATCH_RC=3
    DISPATCH_LOG="$BG_STDOUT_LOG"
    return 3
  fi
  # UBERDEV_TURBO=1 chain-wide signal for /turbo (AUTO_MODE=1) only; env(1)
  # mediates the inline-prefix because timeout(1) is argv[0]. Empty array
  # under AUTO_MODE=0 -> no-op passthrough.
  local BG_TURBO_ENV=()
  [[ "${AUTO_MODE:-0}" == "1" ]] && BG_TURBO_ENV=( UBERDEV_TURBO=1 )
  local BG_PROMPT_MODE="${BG_PROMPT_MODE:-argv}"
  case "$BG_PROMPT_MODE" in
    file)
      # Trusted path arg; file contents never reach the shell as argv.
      "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" env "${BG_TURBO_ENV[@]}" claude --bg \
        --prompt-file "$PROMPT_FILE" \
        --worktree "solve-issue-$ISSUE_NUM" \
        --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" > "$BG_STDOUT_LOG" 2>&1
      DISPATCH_RC=$?
      ;;
    stdin)
      # File content streamed on FD 0; no argv quoting concern.
      "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" env "${BG_TURBO_ENV[@]}" claude --bg \
        --worktree "solve-issue-$ISSUE_NUM" \
        --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" \
        < "$PROMPT_FILE" > "$BG_STDOUT_LOG" 2>&1
      DISPATCH_RC=$?
      ;;
    argv)
      # Bash array form (spec-reviewer finding 1) — single argv slot, no eval.
      local PROMPT_BODY
      # B5 fix (prompt-read), mirrored from the `background` backend: an
      # unreadable $PROMPT_FILE would otherwise leave PROMPT_BODY="" and
      # dispatch `claude --bg … -- ""` (garbage agent), with the audit event
      # happily reporting success. Guard the cat read and surface the failure
      # as a dispatch_setup_failed audit + rc=1.
      if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$BG_STDOUT_LOG")"; then
        DISPATCH_RC=1
        DISPATCH_LOG="$BG_STDOUT_LOG"
        _uberdev_dispatch_audit dispatch_setup_failed \
          "{\"issue\":$ISSUE_NUM,\"phase\":\"prompt_read\",\"backend\":\"claude-bg\",\"rc\":1}"
        return 1
      fi
      local cmd=( "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" env "${BG_TURBO_ENV[@]}" claude --bg
            --worktree "solve-issue-$ISSUE_NUM"
            --model "$MODEL" )
      cmd+=( "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" -- "$PROMPT_BODY" )
      "${cmd[@]}" > "$BG_STDOUT_LOG" 2>&1
      DISPATCH_RC=$?
      ;;
    *)
      # Defensive default arm (silent-failure-hunter finding B2) — rc=127
      # instead of a silent no-op that would report DISPATCH_RC=0.
      echo "error: BG_PROMPT_MODE='$BG_PROMPT_MODE' is not one of {file, stdin, argv}" > "$BG_STDOUT_LOG"
      DISPATCH_RC=127
      ;;
  esac
  if [[ "$DISPATCH_RC" -eq 0 ]]; then
    # Combined #143 (ANSI-strip + line-anchor + hex-validate) + #154 (capture
    # grep's OWN rc to tell a retryable pipeline error from non-retryable marker
    # drift). ANSI-strip first — `claude --bg` may wrap the `backgrounded · <id>`
    # marker in CSI color codes; the line-anchor `^...$` additionally rejects
    # OSC/DCS-wrapped markers (defense-in-depth). The cleaned stream is piped to
    # `grep -m1` so `$?` is grep's rc: grep is the LAST command in the
    # `printf|grep` pipeline, so the subshell exits with grep's rc and `$()`
    # propagates it as `$?`. (The subshell's PIPESTATUS is just not visible to
    # the outer scope — a scoping fact, not destruction.)
    # `${ID_RAW##* }` reproduces `awk '{print $NF}'`; the hex-validate sentinel
    # rejects any partial/garbage token. Mirrors the wezterm B4 SPAWN_RC=$? precedent.
    local ID_CLEAN ID_RAW ID_GREP_RC ID_SUBPHASE
    ID_CLEAN="$(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' "$BG_STDOUT_LOG")"
    ID_RAW="$(printf '%s\n' "$ID_CLEAN" | grep -m1 -aoE '^backgrounded · [0-9a-f]{8}$')"
    ID_GREP_RC=$?
    DISPATCH_ID="${ID_RAW##* }"
    DISPATCH_ID="${DISPATCH_ID//[^0-9a-f]/}"
    [[ "${#DISPATCH_ID}" -eq 8 ]] || DISPATCH_ID=""  # sentinel: empty == validation failed (B3 guard below)
    # B3 fix (preserved): `claude --bg` exited 0 but the marker was absent or
    # the extraction pipeline errored. Recording bg_session_id="" as a
    # "successful dispatch" would let /solve drop the claim-label while the user
    # has no way to `claude agents`-monitor or recover. Surface rc=2 with a
    # subphase discriminator so incident responders can tell drift
    # (marker_absent) from infra (pipeline_error).
    if [[ "$ID_GREP_RC" -ge 2 || -z "$DISPATCH_ID" ]]; then
      # subphase from a TWO-ELEMENT LITERAL SET only (D7 injection guard):
      # never derived from $ID_RAW or $BG_STDOUT_LOG content, which is
      # untrusted and would forge/break the unescaped audit JSONL.
      ID_SUBPHASE="marker_absent"
      [[ "$ID_GREP_RC" -ge 2 ]] && ID_SUBPHASE="pipeline_error"
      DISPATCH_RC=2
      DISPATCH_LOG="$BG_STDOUT_LOG"
      # Defense-in-depth (wezterm B4): stamp empty so the success arm can
      # never fire on a partial token from a failed extraction.
      DISPATCH_ID=""
      _uberdev_dispatch_audit dispatch_setup_failed \
        "{\"issue\":$ISSUE_NUM,\"phase\":\"id_extract\",\"subphase\":\"$ID_SUBPHASE\",\"backend\":\"claude-bg\",\"rc\":2,\"mode\":\"$BG_PROMPT_MODE\"}"
      return 2
    fi
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"claude-bg\",\"bg_session_id\":\"$DISPATCH_ID\",\"mode\":\"$BG_PROMPT_MODE\"}"
  else
    DISPATCH_LOG="$BG_STDOUT_LOG"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"claude-bg\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
}

# _uberdev_dispatch_background ISSUE_NUM TIER PROMPT_FILE
# Dependency-free fallback: explicit `git worktree add` + detached headless
# `claude -p`. Sets DISPATCH_RC and DISPATCH_ID (the detached pid).
_uberdev_dispatch_background() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local WORKTREE_DIR=".claude/worktrees/solve-issue-$ISSUE_NUM"
  local WORKTREE_BRANCH="worktree-solve-issue-$ISSUE_NUM"
  local LOG_FILE="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  local STATUS_FILE="${UBERDEV_TMPDIR:-/tmp}/solve-bg-status-$ISSUE_NUM.json"
  # TOCTOU hardening (#155): guard + 0600-create the predictable log + pid
  # paths before any redirect writes to them (world-writable $UBERDEV_TMPDIR).
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE.pid" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  # Explicit dispatcher-controlled worktree — sidesteps the Windows
  # worktree-isolation bug #40164 in the --bg backend's own --worktree path
  # handling. MSYS_NO_PATHCONV stops Git Bash rewriting the POSIX path.
  if ! MSYS_NO_PATHCONV=1 git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" >"$LOG_FILE" 2>&1; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"worktree\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  local PROMPT_BODY
  # B5 fix (prompt-read): an unreadable $PROMPT_FILE would otherwise leave
  # PROMPT_BODY="" and dispatch `claude -p ""` (garbage agent), with the
  # audit event happily reporting success. Guard the cat read and surface
  # the failure as a dispatch_setup_failed audit + rc=1.
  if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$LOG_FILE")"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"prompt_read\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  local BG_TURBO_ENV=()
  [[ "${AUTO_MODE:-0}" == "1" ]] && BG_TURBO_ENV=( UBERDEV_TURBO=1 )
  # Detached headless claude -p. cwd = the worktree. `claude -p` print mode
  # is non-interactive and verified on native Windows -> logs cleanly.
  # nohup + `&` + disown fully detach so the agent outlives this shell.
  (
    cd "$WORKTREE_DIR" || exit 127
    nohup env "${BG_TURBO_ENV[@]}" claude -p "$PROMPT_BODY" \
      --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" \
      >"$LOG_FILE" 2>&1 &
    printf '%s' "$!" > "$STATUS_FILE.pid"
    disown 2>/dev/null || true
  )
  DISPATCH_RC=$?
  # #155: re-verify the .pid side-file is ours and not a symlink before parsing
  # (defence-in-depth across the subshell-write → parent-read window — a swap
  # here could feed an attacker-chosen pid into DISPATCH_ID).
  if ! _uberdev_dispatch_tmp_target_safe "$STATUS_FILE.pid"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"pid_target_unsafe\",\"backend\":\"background\",\"rc\":3}"
    return 3
  fi
  DISPATCH_ID="$(cat "$STATUS_FILE.pid" 2>/dev/null || echo '')"
  # S10 cleanup: $STATUS_FILE.pid is a one-shot inter-subshell side file
  # whose only purpose is bridging the pid back from the subshell above.
  # Delete it now so a subsequent rerun for the same issue cannot read a
  # stale pid (the canonical record lives in $STATUS_FILE below).
  rm -f "$STATUS_FILE.pid" 2>/dev/null || true
  # Liveness gate: `nohup … &` makes `DISPATCH_RC=$?` report the fork, not the
  # exec — a `claude -p` that failed to launch (binary missing, etc.) still
  # leaves DISPATCH_RC=0. Confirm the captured pid is a live process; if not,
  # clear DISPATCH_ID so the success guard below falls through to the error path.
  if [[ -n "$DISPATCH_ID" ]] && ! kill -0 "$DISPATCH_ID" 2>/dev/null; then
    DISPATCH_ID=""
  fi
  # Per-issue status file — the dispatcher tracks PID liveness + log tail
  # against this; Step 6's summary prints its path. B6 fix: guard the
  # heredoc write so a failed write ($UBERDEV_TMPDIR unwritable, disk full,
  # etc.) surfaces as dispatch_setup_failed instead of a fake-success audit
  # with no status file for Step 6 to read.
  if ! _uberdev_dispatch_prepare_tmp_target "$STATUS_FILE" "$ISSUE_NUM" "background"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  if ! cat > "$STATUS_FILE" <<EOF
{"issue":$ISSUE_NUM,"tier":"$TIER","backend":"background","pid":"${DISPATCH_ID:-}","log":"$LOG_FILE","worktree":"$WORKTREE_DIR","branch":"$WORKTREE_BRANCH"}
EOF
  then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"status_write\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  if [[ "$DISPATCH_RC" -eq 0 && -n "$DISPATCH_ID" ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"background\",\"pid\":\"$DISPATCH_ID\",\"log\":\"$LOG_FILE\"}"
  else
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"background\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
}

# _uberdev_dispatch_wezterm_config
# Idempotently merge the uberdev managed block into ~/.wezterm.lua. The block
# is fenced by BEGIN/END markers; on a re-run the old block is stripped and
# re-appended. The user's own config outside the markers is never touched.
_uberdev_dispatch_wezterm_config() {
  local cfg="${HOME}/.wezterm.lua"
  local begin='-- BEGIN uberdev managed block (RFC 0004) -- do not edit'
  local end='-- END uberdev managed block'
  local tmp="${UBERDEV_TMPDIR:-/tmp}/.wezterm.uberdev.$$"
  # KNOWN LIMITATION (RFC 0004 §3.6 — follow-up amendment): this helper appends a
  # Lua `return { … }` block. If the user's existing `.wezterm.lua` already
  # contains its own `return config`, Lua's first-return-wins semantics mean the
  # managed block's `unix_domains` / `exit_behavior` are unreachable and the
  # `wezterm` backend cannot reach the `uberdev` mux domain. Robust on fresh
  # configs; users with an existing config must integrate the managed values by
  # hand for now. Tracked as a follow-up RFC amendment.
  # Strip any prior managed block, preserving the user's surrounding config.
  if [ -f "$cfg" ]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1} skip && $0==e {skip=0; next} !skip {print}
    ' "$cfg" > "$tmp" || return 1
  else
    : > "$tmp" || return 1
  fi
  # Append a fresh managed block. exit_behavior=Hold keeps a finished or
  # crashed agent pane (and its transcript) visible — the default "Close"
  # makes the pane vanish on exit.
  cat >> "$tmp" <<'LUA' || return 1
-- BEGIN uberdev managed block (RFC 0004) -- do not edit
return {
  unix_domains = { { name = 'uberdev' } },
  exit_behavior = 'Hold',
}
-- END uberdev managed block
LUA
  mv "$tmp" "$cfg" || return 1
}

# _uberdev_dispatch_wezterm ISSUE_NUM TIER PROMPT_FILE
# Spawns each agent as a foreground headless `claude -p` in a visible WezTerm
# pane. Sets DISPATCH_RC and DISPATCH_ID (the spawned pane id).
_uberdev_dispatch_wezterm() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  if ! _uberdev_dispatch_wezterm_config; then
    DISPATCH_RC=1
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"config","backend":"wezterm","rc":1}'
    return 1
  fi
  # RFC §3.6: every `wezterm cli` call in this file passes
  # `--domain-name uberdev` (the probe in _uberdev_dispatch_wezterm_available
  # and the spawn below). That flag — not any env-var pin — is the actual
  # mechanism that keeps fan-out on one mux. No socket-env-var export is
  # used or needed; the domain flag fully determines the target mux.
  local WORKTREE_DIR=".claude/worktrees/solve-issue-$ISSUE_NUM"
  local WORKTREE_BRANCH="worktree-solve-issue-$ISSUE_NUM"
  local LOG_FILE="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  # TOCTOU hardening (#155): guard + 0600-create the predictable log path
  # before the worktree-add redirect below — the wezterm backend writes the
  # SAME world-writable path the claude-bg / background backends harden, so it
  # must fail-CLOSED on a symlink/foreign-owned target too.
  if ! _uberdev_dispatch_prepare_tmp_target "$LOG_FILE" "$ISSUE_NUM" "wezterm"; then
    DISPATCH_RC=3; DISPATCH_LOG="$LOG_FILE"; return 3
  fi
  # The backend runs its own worktree add — a pane's `claude -p` does not get
  # native --worktree. Absolute path, quoted (repo path may contain spaces).
  # MSYS_NO_PATHCONV stops Git Bash rewriting the path.
  if ! MSYS_NO_PATHCONV=1 git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" >"$LOG_FILE" 2>&1; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"worktree","backend":"wezterm","rc":1}'
    return 1
  fi
  local WORKTREE_ABS
  WORKTREE_ABS="$(cd "$WORKTREE_DIR" && pwd)"
  local PROMPT_BODY
  # B5 fix (prompt-read), mirrored from the `background` backend: an
  # unreadable $PROMPT_FILE would otherwise leave PROMPT_BODY="" and spawn
  # `claude -p ""` into the pane (garbage agent), with the audit event
  # happily reporting success. Guard the cat read and surface the failure
  # as a dispatch_setup_failed audit + rc=1.
  if ! PROMPT_BODY="$(cat "$PROMPT_FILE" 2>>"$LOG_FILE")"; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"prompt_read","backend":"wezterm","rc":1}'
    return 1
  fi
  # wezterm cli spawn into the pinned uberdev domain. Foreground claude -p
  # (headless print mode streaming into the pane) — detaching would empty the
  # pane. MSYS2_ARG_CONV_EXCL stops Git Bash mangling the --cwd path arg
  # before it reaches wezterm.
  #
  # B4 fix: capture the spawn rc IMMEDIATELY after the `$(...)` close. Before
  # this change the only gate was `[ -z "$DISPATCH_ID" ]`, which missed the
  # case where `wezterm cli spawn` exits non-zero AND prints a partial token
  # to stdout — the partial string was then treated as a valid pane id. AND-
  # gating SPAWN_RC=0 with the non-empty check covers both failure shapes.
  local SPAWN_RC
  DISPATCH_ID="$(MSYS2_ARG_CONV_EXCL='*' wezterm cli spawn \
    --domain-name uberdev --cwd "$WORKTREE_ABS" -- \
    claude -p "$PROMPT_BODY" --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" \
    2> >(tee -a "$LOG_FILE" >&2))"
  SPAWN_RC=$?
  if [[ "$SPAWN_RC" -ne 0 || -z "$DISPATCH_ID" ]]; then
    DISPATCH_RC=1
    # Stamp DISPATCH_ID empty so the success arm below cannot fire on a
    # partial-stdout token from a failed spawn.
    DISPATCH_ID=""
  fi
  if [[ "$DISPATCH_RC" -eq 0 ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      '{"issue":'"$ISSUE_NUM"',"tier":"'"$TIER"'","backend":"wezterm","pane_id":"'"$DISPATCH_ID"'"}'
  else
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit dispatch_setup_failed \
      '{"issue":'"$ISSUE_NUM"',"phase":"dispatch","backend":"wezterm","rc":'"$DISPATCH_RC"'}'
  fi
  return "$DISPATCH_RC"
}
