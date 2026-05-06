#!/usr/bin/env bash
# Regression test: solve-pipeline must detect cmux via $CMUX_SOCKET_PATH (the
# env var current cmux exports) AND tolerate the legacy $CMUX_SOCKET (older
# releases). Recent cmux explicitly sets `CMUX_SOCKET=` to empty string
# inside a live session, so a bare `-n "$CMUX_SOCKET"` test fails and the
# detection silently falls through to the ghostty arm — keystrokes then land
# in whatever window has focus (browser/Google search), and the agent never
# starts. See conversation logs around 2026-05-06.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

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

# Detection block lives in Step 3. Both the auto-detect arm and the
# explicit-override validation arm must read CMUX_SOCKET_PATH.
DETECTION=$(awk '/^### 3\. Detect terminal app$/,/^### 4\./' "$SOLVE_PIPELINE")
DETECTION_FILE=$(mktemp)
printf '%s\n' "$DETECTION" > "$DETECTION_FILE"

echo "== cmux detection: must check \$CMUX_SOCKET_PATH (current) and \$CMUX_SOCKET (legacy) =="

# Auto-detect arm: the elif that picks TERMINAL=cmux must read CMUX_SOCKET_PATH.
assert_grep "$DETECTION_FILE" \
  'CMUX_SOCKET_PATH' \
  "Step 3 detection block references \$CMUX_SOCKET_PATH (current cmux env var)"

# Legacy fallback retained for older cmux installs.
assert_grep "$DETECTION_FILE" \
  '\$CMUX_SOCKET\b' \
  "Step 3 detection block still references \$CMUX_SOCKET (legacy fallback)"

# Both must appear in a parameter-expansion fallback chain so a missing
# CMUX_SOCKET_PATH falls through to CMUX_SOCKET, not vice versa.
assert_grep "$DETECTION_FILE" \
  '\$\{CMUX_SOCKET_PATH:-\$\{?CMUX_SOCKET' \
  "Step 3 detection uses \${CMUX_SOCKET_PATH:-...CMUX_SOCKET...} fallback chain (path preferred, socket legacy; matches plain or set-u-defensive forms)"

# The explicit-override validation arm (TERMINAL=cmux requested but socket dead)
# must use the same fallback so a user with --terminal=cmux on current cmux
# isn't told their socket is missing when it's actually exported under the new
# name.
assert_grep "$DETECTION_FILE" \
  'CMUX_SOCKET_PATH.*not a live socket|not a live socket.*CMUX_SOCKET_PATH|neither.*CMUX_SOCKET_PATH' \
  "Step 3 override-validation warning mentions CMUX_SOCKET_PATH (so users see the right env var to set)"

# Regression guard: the bare `[[ -n "$CMUX_SOCKET" && -S "$CMUX_SOCKET" ]]`
# check must NOT be the only socket test in the auto-detect arm — current cmux
# sets CMUX_SOCKET to empty, so the bare form silently fails.
if grep -qE '^\s*elif\s+\[\[\s*-n\s+"\$CMUX_SOCKET"\s+&&\s+-S\s+"\$CMUX_SOCKET"\s+\]\]' "$DETECTION_FILE"; then
  echo "  FAIL  bare \`[[ -n \"\$CMUX_SOCKET\" && -S \"\$CMUX_SOCKET\" ]]\` regression — current cmux sets CMUX_SOCKET= empty, this check always fails"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  no bare \$CMUX_SOCKET-only socket check (regression guard for the 0.20.0 → 0.20.1 fix)"
  PASS=$((PASS + 1))
fi

rm -f "$DETECTION_FILE"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
