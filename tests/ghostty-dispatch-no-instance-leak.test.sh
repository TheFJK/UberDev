#!/usr/bin/env bash
# Regression test for issue #31:
#   `open -na Ghostty --args --command=$SCRIPT` makes --command= the running
#   Ghostty instance's default — every Cmd+T/Cmd+N the user opens manually
#   re-runs the launcher script, "poisoning" the instance for its lifetime.
#
# This test locks the contract: solve-pipeline must NOT use that flag form,
# and the ghostty dispatch case must rely on keystroke-based AppleScript
# (which doesn't set any instance default) with a clean nohup fallback.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

PASS=0
FAIL=0

# String-based variants of the sibling-test `assert_grep` / `assert_grep_not`
# helpers. Take a content blob as the first arg (instead of a path) so we can
# scope assertions to a sub-section of the file without round-tripping through
# tempfiles.
assert_grep() {
  local input="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" <<<"$input"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_not() {
  local input="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" <<<"$input"; then
    echo "  FAIL  $desc"
    echo "        pattern: $pattern (must not appear)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

# Strip shell-comment lines so the rationale comment that *names* the bad
# pattern in order to warn against it doesn't trigger the regression-guard
# assertion.
NONCOMMENT=$(grep -vE '^[[:space:]]*#' "$SOLVE_PIPELINE")

# Just the dispatch case under the per-issue "Spawn agent in new terminal
# session" sub-step (multi-issue refactor moved this from `### 6.` to
# `#### 5c.` inside the Phase B for-loop). Avoid matches against the earlier
# Step 3 terminal-detection validation block (which also has a `ghostty)` arm
# but with different content) by anchoring on the dispatch heading specifically.
DISPATCH=$(awk '/^#### 5c\. Spawn agent in new terminal session$/,/^### 6\./' "$SOLVE_PIPELINE")

# Just the ghostty arm body (between `  ghostty)` and the next `    ;;`) so the
# nohup-fallback assertion proves the fallback lives inside the ghostty case,
# not in the default `nohup|*)` arm at the bottom of the dispatch.
GHOSTTY=$(awk '
  /^  ghostty\)/ { in_arm=1; print; next }
  in_arm && /^    ;;/ { print; in_arm=0; next }
  in_arm { print }
' <<<"$DISPATCH")

echo "== Issue #31: ghostty dispatch must not leak --command= as instance default =="

# Root-cause regression guard. The toxic pattern persists --command= for the
# Ghostty process lifetime; every subsequent Cmd+T/Cmd+N re-runs the launcher.
assert_grep_not "$NONCOMMENT" \
  'open -na Ghostty --args --command=' \
  "solve-pipeline must NOT execute 'open -na Ghostty --args --command=' (#31 sticky-flag poison)"

# The dispatch section must drive Ghostty via AppleScript keystrokes (Cmd+T or
# Cmd+N) — keystroke dispatch types into a tab/window without setting any
# instance default, so it doesn't poison the Ghostty process. Accept either
# a literal `keystroke "t"`/`keystroke "n"` or a `keystroke "$VAR"` form fed
# by a `="t"`/`="n"` assignment, since either is contract-compliant.
assert_grep "$DISPATCH" \
  'keystroke .* using command down' \
  "ghostty dispatch uses AppleScript keystroke + command-modifier (no instance default)"

# Cmd+N path (SOLVE_GHOSTTY_NEW_WINDOW=1 or invoked from outside Ghostty).
# Accepts literal `keystroke "n"` OR a variable assigned ="n".
assert_grep "$GHOSTTY" \
  '(keystroke "n"|="n"[[:space:]]*(#|$))' \
  "ghostty new-window path uses Cmd+N (literal keystroke or via spawn-key variable)"

# Cmd+T path (existing tab-spawn behavior). Same matching strategy.
assert_grep "$GHOSTTY" \
  '(keystroke "t"|="t"[[:space:]]*(#|$))' \
  "ghostty tab-spawn path still uses Cmd+T (no regression on the originally-working path)"

# If the dispatch parameterizes via a spawn-key variable (current
# implementation), the AppleScript heredoc must consume it via
# `keystroke "$GHOSTTY_SPAWN_KEY"` — otherwise both `="n"` and `="t"`
# assignments could exist while the keystroke is hardcoded to one of them,
# silently breaking the path that doesn't match the hardcode. Hedge: skip
# this check if neither path uses the variable form (i.e. both are inlined
# as separate heredocs), which is also contract-compliant.
if grep -qE 'GHOSTTY_SPAWN_KEY=' <<<"$GHOSTTY"; then
  assert_grep "$GHOSTTY" \
    'keystroke "\$GHOSTTY_SPAWN_KEY"' \
    "AppleScript heredoc consumes the spawn-key via variable (not hardcoded once both branches set it)"
fi

# When AppleScript itself is unusable (Accessibility denied, custom keybind),
# the final fallback must be nohup — never `open -na Ghostty --args --command=`.
# Anchored within the ghostty arm so the default `nohup|*)` arm doesn't satisfy this.
assert_grep "$GHOSTTY" \
  'nohup zsh -l' \
  "ghostty arm itself falls back to nohup when AppleScript unavailable"

# Reference issue #31 in a comment so future contributors who might reintroduce
# `open --args --command=` see the rationale before they do.
assert_grep "$GHOSTTY" \
  '#31|issue 31' \
  "ghostty arm comments reference issue #31 (rationale for avoiding --command=)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
