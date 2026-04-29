#!/usr/bin/env bash
# Stop the brainstorm server and clean up
# Usage: stop-server.sh <session_dir>
#
# Kills the server process. Only deletes session directory if it's
# under /tmp (ephemeral). Persistent directories (.uberdev/) are
# kept so mockups can be reviewed later.

SESSION_DIR="$1"

if [[ -z "$SESSION_DIR" ]]; then
  echo '{"error": "Usage: stop-server.sh <session_dir>"}'
  exit 1
fi

STATE_DIR="${SESSION_DIR}/state"
PID_FILE="${STATE_DIR}/server.pid"

# Canonicalize a path without requiring it to exist. BSD realpath (default on
# macOS) lacks `-m` and fails on missing paths, so prefer python3 and fall back
# to `realpath` only when python3 is missing.
#
# Stderr policy: capture both helpers' stderr into a temp variable and emit it
# ONLY on total failure. Previous `2>/dev/null` everywhere collapsed real tool
# errors (broken python3, ENOENT, missing perms, etc.) into the same silent
# return as a legitimately rejected path — admins lost the signal needed to
# debug skipped cleanup.
canonicalize() {
  local p="$1" out err=""
  if command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>&1)
    if [ $? -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    err="$out"
  fi
  if command -v realpath >/dev/null 2>&1; then
    out=$(realpath "$p" 2>&1)
    if [ $? -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    err="${err}${err:+; }${out}"
  fi
  echo "stop-server/canonicalize: failed to resolve '$p' (${err:-no python3 or realpath available})" >&2
  return 1
}

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")

  # Try to stop gracefully, fallback to force if still alive
  kill "$pid" 2>/dev/null || true

  # Wait for graceful shutdown (up to ~2s)
  for i in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  # If still running, escalate to SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true

    # Give SIGKILL a moment to take effect
    sleep 0.1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    echo '{"status": "failed", "error": "process still running"}'
    exit 1
  fi

  rm -f "$PID_FILE" "${STATE_DIR}/server.log"

  # Only delete ephemeral /tmp directories. Canonicalize first so a path like
  # /tmp/../home/victim can't slip past a glob-style prefix check, then match
  # exact `/tmp/brainstorm-*` (or `/private/tmp/brainstorm-*` on macOS, where
  # /tmp is a symlink to /private/tmp).
  SESSION_DIR_CANON="$(canonicalize "$SESSION_DIR")" || SESSION_DIR_CANON=""

  if [[ -n "$SESSION_DIR_CANON" ]]; then
    case "$SESSION_DIR_CANON" in
      /tmp/brainstorm-*|/private/tmp/brainstorm-*)
        rm -rf "$SESSION_DIR_CANON"
        echo '{"status": "stopped"}'
        exit 0
        ;;
      *)
        # Path resolved outside the expected ephemeral root — refuse to clean.
        # Caller MUST know cleanup was skipped: previously we still emitted
        # `{"status":"stopped"}` here, which lied about cleanup completing.
        echo "stop-server: refusing to clean session dir outside /tmp/brainstorm-*: $SESSION_DIR_CANON" >&2
        echo '{"status": "stopped_no_cleanup", "reason": "session dir resolved outside /tmp/brainstorm-*; cleanup refused"}'
        exit 0
        ;;
    esac
  else
    # Canonicalize failed — process was killed but session dir survives. Distinguish
    # this from a clean stop so callers can surface the leak / retry cleanup.
    echo "stop-server: unable to canonicalize SESSION_DIR, skipping cleanup: $SESSION_DIR" >&2
    echo '{"status": "stopped_no_cleanup", "reason": "could not canonicalize SESSION_DIR; cleanup skipped"}'
    exit 0
  fi
else
  echo '{"status": "not_running"}'
fi
