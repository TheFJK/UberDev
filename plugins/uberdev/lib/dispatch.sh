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
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'macos'; return 0 ;;
  esac
  if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    printf 'wsl2'; return 0
  fi
  case "${OS:-}" in
    Windows_NT) printf 'windows-native'; return 0 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
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

# _uberdev_dispatch_claude_bg ISSUE_NUM TIER PROMPT_FILE -> body filled by Task 6.
_uberdev_dispatch_claude_bg() { return 0; }

# _uberdev_dispatch_background ISSUE_NUM TIER PROMPT_FILE -> body filled by Task 7.
_uberdev_dispatch_background() { return 0; }

# _uberdev_dispatch_wezterm ISSUE_NUM TIER PROMPT_FILE -> body filled by Task 12.
_uberdev_dispatch_wezterm() { return 0; }
