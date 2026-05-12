#!/usr/bin/env bash
# Tombstone test for retired cmux/AppleScript/nohup dispatch surface.
#
# Original scope (issue #31, PR #33): solve-pipeline must NOT use
#   `open -na Ghostty --args --command=$SCRIPT` (poisons Ghostty's instance
#   default; every Cmd+T re-runs the launcher).
#
# Expanded scope (v0.22.0, #85): solve-pipeline must NOT contain any of the
# retired terminal-dispatch forms — cmux IPC, iTerm/Terminal AppleScript,
# nohup launcher invocation. The primary dispatch path is now `claude --bg`
# (see tests/dispatch-claude-bg.test.sh for the positive assertions).

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

echo "== Issue #31 + #85: retired terminal-dispatch surface must remain tombstoned =="

# Root-cause regression guard. The toxic pattern persists --command= for the
# Ghostty process lifetime; every subsequent Cmd+T/Cmd+N re-runs the launcher.
assert_grep_not "$NONCOMMENT" \
  'open -na Ghostty --args --command=' \
  "solve-pipeline must NOT execute 'open -na Ghostty --args --command=' (#31 sticky-flag poison)"

# NEW assertions (post-#85 retirement). All terms must be absent from
# the primary dispatch path. Ghostty is the originating fix; cmux/iterm/
# terminal/nohup all join the tombstone list as part of v0.22.0.
assert_grep_not "$NONCOMMENT" \
  'cmux new-workspace' \
  "cmux dispatch retired in v0.22.0 (#85)"
assert_grep_not "$NONCOMMENT" \
  'osascript -e' \
  "osascript -e interpolation surface retired in v0.22.0 (#85)"
assert_grep_not "$NONCOMMENT" \
  'tell application "iTerm"' \
  "iTerm AppleScript dispatch retired in v0.22.0 (#85)"
assert_grep_not "$NONCOMMENT" \
  'tell application "Terminal"' \
  "Terminal.app AppleScript dispatch retired in v0.22.0 (#85)"
assert_grep_not "$NONCOMMENT" \
  'nohup zsh -l' \
  "nohup launcher dispatch retired in v0.22.0 (#85)"
assert_grep_not "$NONCOMMENT" \
  'keystroke .* using command down' \
  "Ghostty AppleScript keystroke dispatch retired in v0.22.0 (#85)"

# Rationale comment must still reference issue #31 so the original fix's
# context survives — PR #33 convention. Assert against the full SKILL.md
# content (not $NONCOMMENT) since shell-comment stripping is irrelevant
# for a markdown doc, and #31 may legitimately live in any line.
SKILL_FULL=$(cat "$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md")
assert_grep "$SKILL_FULL" \
  '#31|issue 31' \
  "solve-pipeline SKILL.md still references #31 (historical rationale preserved)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
