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
  # /tmp is a symlink to /private/tmp). BSD realpath (default on macOS) lacks
  # `-m` and fails on missing paths, so prefer python3 and fall back to realpath.
  if command -v python3 >/dev/null 2>&1; then
    SESSION_DIR_CANON="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SESSION_DIR" 2>/dev/null)"
  elif command -v realpath >/dev/null 2>&1; then
    SESSION_DIR_CANON="$(realpath "$SESSION_DIR" 2>/dev/null)"
  else
    SESSION_DIR_CANON=""
  fi

  if [[ -n "$SESSION_DIR_CANON" ]]; then
    case "$SESSION_DIR_CANON" in
      /tmp/brainstorm-*|/private/tmp/brainstorm-*)
        rm -rf "$SESSION_DIR_CANON"
        ;;
      *)
        # Path resolved outside the expected ephemeral root — refuse.
        # Keep stop-server's contract (prints JSON + exits 0 on stop) intact;
        # the session dir simply isn't cleaned in this case.
        echo "stop-server: refusing to clean session dir outside /tmp/brainstorm-*: $SESSION_DIR_CANON" >&2
        ;;
    esac
  else
    echo "stop-server: unable to canonicalize SESSION_DIR, skipping cleanup: $SESSION_DIR" >&2
  fi

  echo '{"status": "stopped"}'
else
  echo '{"status": "not_running"}'
fi
