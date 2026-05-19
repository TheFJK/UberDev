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
    _uberdev_audit_emit "$1" "$2" || true
  fi
}

# _uberdev_dispatch_wezterm_available -> exit 0 if wezterm usable, 1 otherwise.
# Usable = binary on PATH AND the mux answers list-clients within the poll
# budget (cold-start race guard, RFC §3.6). Starts wezterm-mux-server if the
# mux is not already up.
_uberdev_dispatch_wezterm_available() {
  command -v wezterm >/dev/null 2>&1 || return 1
  local i
  for i in 1 2 3 4 5; do
    if wezterm cli list-clients >/dev/null 2>&1; then
      return 0
    fi
    wezterm-mux-server --daemonize >/dev/null 2>&1 || true
    sleep 1
  done
  wezterm cli list-clients >/dev/null 2>&1
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
      echo "error: uberdev_dispatch_one: unresolved backend '${UBERDEV_RESOLVED_BACKEND:-}'" >&2
      DISPATCH_RC=1
      return 1 ;;
  esac
}

# _uberdev_dispatch_claude_bg ISSUE_NUM TIER PROMPT_FILE
# Extract of the v0.22.0 inline `claude --bg` dispatch. Sets DISPATCH_RC and
# DISPATCH_ID (the bg session id) for the caller. No behaviour change.
_uberdev_dispatch_claude_bg() {
  local ISSUE_NUM="$1" TIER="$2" PROMPT_FILE="$3"
  DISPATCH_RC=0
  DISPATCH_ID=""
  local BG_STDOUT_LOG="${UBERDEV_TMPDIR:-/tmp}/solve-bg-stdout-$ISSUE_NUM.log"
  # UBERDEV_TURBO=1 chain-wide signal for /turbo (AUTO_MODE=1) only; env(1)
  # mediates the inline-prefix because timeout(1) is argv[0] (see SKILL.md
  # comment lifted verbatim). Empty array under AUTO_MODE=0 -> no-op passthrough.
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
      PROMPT_BODY="$(cat "$PROMPT_FILE")"
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
    DISPATCH_ID="$(grep -oE 'backgrounded · [0-9a-f]{8}' "$BG_STDOUT_LOG" | awk '{print $NF}' | head -1)"
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"claude-bg\",\"bg_session_id\":\"${DISPATCH_ID:-}\",\"mode\":\"$BG_PROMPT_MODE\"}"
  else
    DISPATCH_LOG="$BG_STDOUT_LOG"
    _uberdev_dispatch_audit error \
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
  # Explicit dispatcher-controlled worktree — sidesteps the Windows
  # worktree-isolation bug #40164 in the --bg backend's own --worktree path
  # handling. MSYS_NO_PATHCONV stops Git Bash rewriting the POSIX path.
  if ! MSYS_NO_PATHCONV=1 git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" >"$LOG_FILE" 2>&1; then
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit error \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"worktree\",\"backend\":\"background\",\"rc\":1}"
    return 1
  fi
  local PROMPT_BODY
  PROMPT_BODY="$(cat "$PROMPT_FILE")"
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
  DISPATCH_ID="$(cat "$STATUS_FILE.pid" 2>/dev/null || echo '')"
  # Liveness gate: `nohup … &` makes `DISPATCH_RC=$?` report the fork, not the
  # exec — a `claude -p` that failed to launch (binary missing, etc.) still
  # leaves DISPATCH_RC=0. Confirm the captured pid is a live process; if not,
  # clear DISPATCH_ID so the success guard below falls through to the error path.
  if [[ -n "$DISPATCH_ID" ]] && ! kill -0 "$DISPATCH_ID" 2>/dev/null; then
    DISPATCH_ID=""
  fi
  # Per-issue status file — the dispatcher tracks PID liveness + log tail
  # against this; Step 6's summary prints its path.
  cat > "$STATUS_FILE" <<EOF
{"issue":$ISSUE_NUM,"tier":"$TIER","backend":"background","pid":"${DISPATCH_ID:-}","log":"$LOG_FILE","worktree":"$WORKTREE_DIR","branch":"$WORKTREE_BRANCH"}
EOF
  if [[ "$DISPATCH_RC" -eq 0 && -n "$DISPATCH_ID" ]]; then
    _uberdev_dispatch_audit agent_dispatched \
      "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"backend\":\"background\",\"pid\":\"$DISPATCH_ID\",\"log\":\"$LOG_FILE\"}"
  else
    DISPATCH_RC=1
    DISPATCH_LOG="$LOG_FILE"
    _uberdev_dispatch_audit error \
      "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"backend\":\"background\",\"rc\":$DISPATCH_RC}"
  fi
  return "$DISPATCH_RC"
}

# _uberdev_dispatch_wezterm ISSUE_NUM TIER PROMPT_FILE -> body filled by Task 12.
_uberdev_dispatch_wezterm() { return 0; }
