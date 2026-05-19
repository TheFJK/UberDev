#!/usr/bin/env bash
# Shape-check for the `wezterm` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_wezterm). Verifies `wezterm cli spawn` with
# --domain-name, the mux-preflight list-clients poll, the .wezterm.lua
# managed-block with exit_behavior Hold, the pinned socket, and the
# ABSENCE of `claude --bg` from the wezterm arm. RFC 0004 §3.6 / §4.

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

echo "== Positive: wezterm cli spawn mechanism =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_wezterm\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_wezterm function"
assert_grep "$DISPATCH_LIB" \
  'wezterm cli spawn' \
  "wezterm backend spawns each agent via wezterm cli spawn"
assert_grep "$DISPATCH_LIB" \
  '\-\-domain-name uberdev' \
  "wezterm spawn pins the named uberdev domain"
assert_grep "$DISPATCH_LIB" \
  '\-\-cwd ' \
  "wezterm spawn --cwd's the pane into the worktree"
assert_grep "$DISPATCH_LIB" \
  'claude -p' \
  "wezterm backend runs foreground headless claude -p in the pane"
assert_grep "$DISPATCH_LIB" \
  'WEZTERM_UNIX_SOCKET' \
  "wezterm backend pins \$WEZTERM_UNIX_SOCKET so fan-out stays on one mux"
assert_grep "$DISPATCH_LIB" \
  'git worktree add' \
  "wezterm backend runs git worktree add itself (no native --worktree)"

echo "== Positive: mux preflight + .wezterm.lua managed block =="
assert_grep "$DISPATCH_LIB" \
  'wezterm-mux-server' \
  "wezterm preflight starts wezterm-mux-server before the first spawn"
assert_grep "$DISPATCH_LIB" \
  'list-clients' \
  "wezterm preflight polls wezterm cli list-clients (cold-start race guard)"
assert_grep "$DISPATCH_LIB" \
  '\.wezterm\.lua' \
  "wezterm backend manages a .wezterm.lua config"
assert_grep "$DISPATCH_LIB" \
  'exit_behavior.*Hold' \
  ".wezterm.lua managed block sets exit_behavior = Hold (pane stays visible)"
assert_grep "$DISPATCH_LIB" \
  'unix_domains' \
  ".wezterm.lua managed block defines the uberdev unix_domains entry"
assert_grep "$DISPATCH_LIB" \
  'managed|BEGIN uberdev|END uberdev' \
  ".wezterm.lua block is a fenced managed region (merge, never overwrite)"
assert_grep "$DISPATCH_LIB" \
  '"backend":"wezterm"' \
  "agent_dispatched payload carries backend=wezterm"
assert_grep "$DISPATCH_LIB" \
  '"pane_id":' \
  "agent_dispatched payload carries the spawned pane_id"

echo "== Anti-pattern: wezterm backend never uses claude --bg =="
# Scope the check to the _uberdev_dispatch_wezterm function body — sibling
# backends in the same file legitimately use `claude --bg`.
WT_FN_BODY="$(awk '/^_uberdev_dispatch_wezterm\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s' "$WT_FN_BODY" | grep -qE 'claude --bg'; then
  echo "  FAIL  _uberdev_dispatch_wezterm uses claude --bg (pane needs foreground claude -p)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  _uberdev_dispatch_wezterm does not use claude --bg"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
