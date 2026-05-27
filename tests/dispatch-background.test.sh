#!/usr/bin/env bash
# Shape-check for the `background` dispatch backend in lib/dispatch.sh
# (_uberdev_dispatch_background). Verifies explicit `git worktree add`,
# detached headless `claude -p`, nohup/disown backgrounding, per-issue
# status-file writes, and the ABSENCE of `claude --bg`. RFC 0004 §3.7 / §4.

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

echo "== Positive: background backend mechanism =="
assert_grep "$DISPATCH_LIB" \
  '_uberdev_dispatch_background\(\)' \
  "lib/dispatch.sh defines the _uberdev_dispatch_background function"
assert_grep "$DISPATCH_LIB" \
  'git worktree add' \
  "background backend runs explicit git worktree add (sidesteps #40164)"
assert_grep "$DISPATCH_LIB" \
  'claude -p' \
  "background backend launches headless claude -p (print mode)"
assert_grep "$DISPATCH_LIB" \
  'nohup' \
  "background backend detaches the process via nohup"
assert_grep "$DISPATCH_LIB" \
  'disown' \
  "background backend disowns the detached process"
assert_grep "$DISPATCH_LIB" \
  '"\$\{EFFORT_FLAG\[@\]\}"' \
  "background backend threads \"\${EFFORT_FLAG[@]}\" into claude -p"
assert_grep "$DISPATCH_LIB" \
  '"\$\{PERM_FLAG\[@\]\}"' \
  "background backend threads \"\${PERM_FLAG[@]}\" into claude -p"
assert_grep "$DISPATCH_LIB" \
  'BG_TURBO_ENV\+=\( SKIP_PERMISSIONS=1 \)' \
  "BG_TURBO_ENV propagates SKIP_PERMISSIONS to background dispatch arm (#241)"

echo "== Positive: status-file writes + audit payload =="
assert_grep "$DISPATCH_LIB" \
  'DISPATCH_RC' \
  "background backend sets the DISPATCH_RC per-issue result var"
assert_grep "$DISPATCH_LIB" \
  '"backend":"background"' \
  "agent_dispatched payload carries backend=background"
assert_grep "$DISPATCH_LIB" \
  '"pid":' \
  "agent_dispatched payload carries the detached pid"
assert_grep "$DISPATCH_LIB" \
  'solve-bg-status-|status' \
  "background backend writes a per-issue status file"

echo "== Anti-pattern: background backend never uses claude --bg =="
# Extract just the _uberdev_dispatch_background function body and assert
# `claude --bg` does not appear inside it (sibling backends in the same
# file legitimately use it — scope the check to this function).
BG_FN_BODY="$(awk '/^_uberdev_dispatch_background\(\)/{f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB")"
if printf '%s' "$BG_FN_BODY" | grep -qE 'claude --bg'; then
  echo "  FAIL  _uberdev_dispatch_background uses claude --bg (must use claude -p)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  _uberdev_dispatch_background does not use claude --bg"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
