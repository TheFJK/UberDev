#!/usr/bin/env bash
# tests/dispatch-prompt-no-bare-slash.test.sh — drift-guard for issue #235.
#
# `claude --bg ... -- "<prompt>"` passes the prompt as the first user message
# of the new agent. The CLI does NOT slash-expand argv-supplied opening
# messages (verified on 2.1.139 / 2.1.150 / 2.1.152), so a prompt body that
# STARTS with `/uberdev:...` is silently treated as natural-language and the
# child agent answers conversationally instead of running the slash command.
# Every `/goal` → `/turbo` → `/orchestrator` chain dies at this boundary, and
# the resulting silent-leaf failure cascades into Symptom B (double worktrees
# / double reviews when the goal-pipeline skip-check sees no `solving` row
# and re-dispatches on the next cycle).
#
# Fix (issue #235 option 3b — lowest-blast-radius): re-anchor every prompt
# body so it does not start with a slash. The bodies are rewritten to a
# natural-language imperative that still references the slash command, e.g.:
#
#     Invoke the slash command /uberdev:turbo 222 --turbo --backend=claude-bg
#     now. Do not respond conversationally — execute it.
#
# This guard scans the three known prompt-build callsite files and fails CI
# when it finds a `printf` / `echo` writing a body whose first character is
# `/`. Comment lines (`# /uberdev:...`) and Skill-tool references (e.g.
# `Skill("uberdev:review-pr")`) are intentionally NOT matched — only the
# write-the-prompt-body primitives at column-zero or with leading whitespace
# in source are.
#
# Portable: bash + grep. Runs on ubuntu-latest and windows-latest.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"

PASS=0; FAIL=0
echo "## dispatch-prompt-no-bare-slash drift guard (#235)"

# The three callsite files that BUILD a per-issue prompt body for the
# claude --bg dispatcher.
CALLSITES=(
  "$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"
  "$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
  "$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"
)
for f in "${CALLSITES[@]}"; do
  [ -r "$f" ] || { echo "  ABORT — callsite missing or unreadable: $f"; exit 99; }
done

# Pattern: a `printf` or `echo` whose first quoted format-string argument
# opens with `/uberdev:`. Anchors:
#   ^[[:space:]]*    — leading whitespace OK; line-leading match.
#   (printf|echo)    — the two write primitives used at the callsites.
#   ([[:space:]]+-[a-zA-Z]+)?  — optional `-n` / `-e` flag for echo.
#   [[:space:]]+     — gap before the quoted body.
#   ['"]             — opening quote (printf uses ', echo "$VAR" uses ").
#   /uberdev:        — bare slash command opening the body.
GUARD_REGEX='^[[:space:]]*(printf|echo)([[:space:]]+-[a-zA-Z]+)?[[:space:]]+['"'"'"]/uberdev:'

# R1 — no callsite file may contain a `printf` / `echo` that writes a
# prompt body opening with `/uberdev:`. Comment lines (`# printf …`) are
# stripped post-grep so docs-only mentions never trip.
hits=""
for f in "${CALLSITES[@]}"; do
  line_match="$(grep -nE "$GUARD_REGEX" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -n "$line_match" ]; then
    hits="$hits"$'\n'"$f:"$'\n'"$line_match"$'\n'
  fi
done

if [ -z "$hits" ]; then
  echo "  PASS  R1 no callsite writes a prompt body starting with /uberdev:"
  PASS=$((PASS+1))
else
  echo "  FAIL  R1 these callsites write a bare-slash prompt body (claude --bg argv mode does NOT slash-expand):"
  printf '%s\n' "$hits" | sed 's/^/         /'
  echo "         Fix: rewrite the body to a natural-language imperative, e.g.:"
  echo "           Invoke the slash command /uberdev:turbo \$N --turbo --backend=\$B now. Do not respond conversationally — execute it."
  FAIL=$((FAIL+1))
fi

# R2 + R3 — fixture proofs. Single trap installed up front covers both
# fixtures so a future refactor cannot break trap cleanup (bash supports
# ONE EXIT trap per shell; mirror skill-renderer-awk-collision.test.sh).
fixture_bad="$(mktemp)"
fixture_good="$(mktemp)"
trap 'rm -f "$fixture_bad" "$fixture_good"' EXIT

# R2 — fixture proof: a synthetic vulnerable line MUST be detected by the
# same regex. Inside-out check guarding against future regex narrowing.
cat > "$fixture_bad" <<'EOF_FIXTURE'
# fake prompt-build sites — the regex MUST flag both
echo "/uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM" > "$prompt_file"
printf '/uberdev:turbo %s\n' "$ISSUE_NUM" > "$PROMPT_FILE"
EOF_FIXTURE
if grep -qE "$GUARD_REGEX" "$fixture_bad"; then
  echo "  PASS  R2 the guard regex flags synthetic bare-slash prompt-build lines"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2 the guard regex no longer flags synthetic bare-slash prompt-build lines"
  echo "         Check GUARD_REGEX in this file (currently: $GUARD_REGEX)"
  FAIL=$((FAIL+1))
fi

# R3 — fixture proof of the inverse: the recommended natural-language
# imperative shape MUST NOT trip the regex. Guards against the regex
# becoming over-broad and false-positiving on the fix.
cat > "$fixture_good" <<'EOF_OK'
# fixed prompt-build sites — the regex MUST NOT flag any of these
printf 'Invoke the slash command /uberdev:turbo %s --turbo --backend=%s now. Do not respond conversationally — execute it.\n' "$ISSUE_NUM" "$BACKEND" > "$PROMPT_FILE"
echo "Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM now. Do not respond conversationally — execute it." > "$prompt_file"
EOF_OK
if grep -qE "$GUARD_REGEX" "$fixture_good"; then
  echo "  FAIL  R3 the guard regex false-positives on the natural-language imperative shape"
  echo "         Inspect GUARD_REGEX (currently: $GUARD_REGEX)"
  FAIL=$((FAIL+1))
else
  echo "  PASS  R3 the guard regex does NOT false-positive on the natural-language imperative shape"
  PASS=$((PASS+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
