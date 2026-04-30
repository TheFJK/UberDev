#!/usr/bin/env bash
# Shape-check tests for /merge command (issue #24).
# Covers: command-file frontmatter contract, dispatcher-vs-skill split,
# skill phase headings, conflict-resolve safety guards, integration-branch
# config-read prose, no-Claude-trailer rule, atomic-rollback prose.
#
# Sections:
#   M1 — commands/merge.md exists, has frontmatter, has description,
#        argument-hint, allowed-tools.
#   M2 — commands/merge.md is ≤ 50 lines (thin-dispatcher contract).
#   M3 — commands/merge.md references uberdev:merge skill (not merge-prs).
#   M4-M16 — added in Task 11 after the SKILL.md body lands.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD_FILE="$REPO_ROOT/plugins/uberdev/commands/merge.md"
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/merge/SKILL.md"
AGENT_FILE="$REPO_ROOT/plugins/uberdev/agents/conflict-resolver.md"

# Pre-flight: refuse to run if any asserted-against file is missing.
for f in "$CMD_FILE" "$SKILL_FILE"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "== M1: commands/merge.md exists with required frontmatter =="
assert_grep "$CMD_FILE" '^description:' "M1.1 — has description key"
assert_grep "$CMD_FILE" '^argument-hint:' "M1.2 — has argument-hint key"
assert_grep "$CMD_FILE" '^allowed-tools:' "M1.3 — has allowed-tools key"

echo
echo "== M2: commands/merge.md is a thin dispatcher (≤ 50 lines) =="
LINE_COUNT=$(wc -l < "$CMD_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -le 50 ]; then
  echo "  PASS  M2 — $LINE_COUNT lines (≤ 50)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  M2 — $LINE_COUNT lines (> 50, dispatcher should stay thin)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== M3: commands/merge.md references uberdev:merge skill =="
assert_grep "$CMD_FILE" 'uberdev:merge([^-A-Za-z0-9_]|$)' \
  "M3 — invokes uberdev:merge (not merge-prs or any other name)"
# Negative: must NOT reference the rejected skill name 'merge-prs'.
if grep -qE 'merge-prs\b' "$CMD_FILE"; then
  echo "  FAIL  M3.neg — references rejected skill name 'merge-prs'"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  M3.neg — does NOT reference rejected skill name 'merge-prs'"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
