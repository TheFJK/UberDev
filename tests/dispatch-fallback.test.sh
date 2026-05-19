#!/usr/bin/env bash
# Shape-check for the platform-aware fallback resolver in lib/dispatch.sh
# (uberdev_dispatch_preflight). Verifies the per-OS preference order, the
# WSL2 same-OS guard, single-resolution (no mid-fanout switch), and the
# explicit --backend= hard-error path. RFC 0004 §3.3 / §4.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        pattern: $pattern (must not appear)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== Positive: per-OS auto-resolution preference order =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_os_class' \
  "preflight calls the OS-class detector"
assert_grep "$DISPATCH_LIB" \
  'macos\)' \
  "resolver has a macos branch"
assert_grep "$DISPATCH_LIB" \
  'windows-native\)' \
  "resolver has a windows-native branch"
assert_grep "$DISPATCH_LIB" \
  'wsl2\)' \
  "resolver has a wsl2 branch"
assert_grep "$DISPATCH_LIB" \
  'UBERDEV_RESOLVED_BACKEND' \
  "preflight exports UBERDEV_RESOLVED_BACKEND"
assert_grep "$DISPATCH_LIB" \
  'dispatch_backend_resolved' \
  "preflight emits the dispatch_backend_resolved audit event"

echo "== Positive: WSL2 same-OS mux guard + single resolution =="
assert_grep "$DISPATCH_LIB" \
  'wezterm-mux-server|list-clients' \
  "preflight probes WezTerm mux availability (list-clients poll)"
assert_grep "$DISPATCH_LIB" \
  'same.OS|AF_UNIX|WSLg' \
  "preflight documents/enforces the WSL2 same-OS mux constraint"
assert_grep "$DISPATCH_LIB" \
  'commits|once per|whole batch|single' \
  "preflight resolves once and commits the whole batch (no mid-fanout switch)"

echo "== Positive: explicit --backend= hard-errors when unusable =="
assert_grep "$DISPATCH_LIB" \
  'UBERDEV_DISPATCH_BACKEND_REQUESTED|requested' \
  "preflight distinguishes an explicit request from auto"
assert_grep "$DISPATCH_LIB" \
  '^[[:space:]]*(exit|return) 1' \
  "preflight hard-errors (non-zero) when an explicit backend is unusable"

echo "== Anti-pattern: auto never escapes as a resolved backend =="
assert_grep_not "$DISPATCH_LIB" \
  'UBERDEV_RESOLVED_BACKEND=auto$|UBERDEV_RESOLVED_BACKEND="auto"' \
  "auto is resolved away — never assigned as the final backend"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
