#!/usr/bin/env bash
# Shape-check tests for /dev command and dev-pipeline skill (issue #120).
# Covers: command-file frontmatter contract and body reference to the skill.
#
# Sections:
#   D1.1 — commands/dev.md frontmatter has a description: key
#   D1.2 — commands/dev.md frontmatter has an argument-hint: key
#   D1.3 — commands/dev.md frontmatter has an allowed-tools: key
#   D2   — commands/dev.md body references the uberdev:dev-pipeline skill

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD_FILE="$REPO_ROOT/plugins/uberdev/commands/dev.md"
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/dev-pipeline/SKILL.md"

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

echo "== D1/D2: dev.md command-file structure =="
assert_grep "$CMD_FILE" \
  '^description:' \
  "D1.1 — frontmatter has a description: key"

assert_grep "$CMD_FILE" \
  '^argument-hint:' \
  "D1.2 — frontmatter has an argument-hint: key"

assert_grep "$CMD_FILE" \
  '^allowed-tools:' \
  "D1.3 — frontmatter has an allowed-tools: key"

assert_grep "$CMD_FILE" \
  'uberdev:dev-pipeline' \
  "D2 — body references the uberdev:dev-pipeline skill"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
