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

# uberdev_dispatch_preflight -> body filled by Task 8.
uberdev_dispatch_preflight() { return 0; }

# uberdev_dispatch_one ISSUE_NUM TIER PROMPT_FILE -> body filled by Task 8.
uberdev_dispatch_one() { return 0; }

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
