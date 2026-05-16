#!/usr/bin/env bash
# tests/dev-pipeline.test.sh — shape-check regression suite for dev-pipeline/SKILL.md.
#
# Asserts that the dev-pipeline skill contains the required structural elements:
# frontmatter, Quality Contract, all 7 phase headings (0-6), single-message
# fanout instruction, explicit-path git add, controller-only-git rule,
# prototype label creation, harden-issue creation, and scope-gate section.
#
# Sections:
#   DP1   — SKILL.md frontmatter (name, description)
#   DP2   — all seven phase headings (## Phase 0 … ## Phase 6)
#   DP3   — Quality Contract section (Relaxed, Hard-floors columns)
#   DP4   — single-message fanout instruction
#   DP5   — explicit-path git add (and absence of git add -A)
#   DP6   — controller-only-git rule
#   DP7   — prototype label creation (gh label create --force prototype)
#   DP8   — harden-issue creation (gh issue create)
#   DP9   — scope-gate section
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/uberdev/skills/dev-pipeline/SKILL.md"

# Pre-flight: refuse to run if the asserted-against file is missing.
for f in "$SKILL_FILE"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL  $1"
  FAIL=$((FAIL + 1))
}

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    pass "$desc"
  else
    fail "$desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    fail "$desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
  else
    pass "$desc"
  fi
}

echo "== DP1/DP3: skill frontmatter + Quality Contract =="
assert_grep "$SKILL_FILE" '^name:[[:space:]]*dev-pipeline' \
  "DP1.1: frontmatter name: dev-pipeline"
assert_grep "$SKILL_FILE" '^description:' \
  "DP1.2: frontmatter description: present"
assert_grep "$SKILL_FILE" '^## Quality Contract' \
  "DP3.1: ## Quality Contract section present"
assert_grep "$SKILL_FILE" 'Relaxed for prototypes' \
  "DP3.2: Relaxed column present"
assert_grep "$SKILL_FILE" 'Hard floors' \
  "DP3.3: Hard-floors column present"

echo
echo "== DP2: all seven phase headings (0-6) =="
# Bounds: for n in 0 1 2 3 4 5 6 (Phase 0 is parse/scope/branch; Phase 6 is report)
assert_grep "$SKILL_FILE" "^## Phase 0" "DP2.0: ## Phase 0 heading present"
assert_grep "$SKILL_FILE" "^## Phase 1" "DP2.1: ## Phase 1 heading present"
assert_grep "$SKILL_FILE" "^## Phase 2" "DP2.2: ## Phase 2 heading present"
assert_grep "$SKILL_FILE" "^## Phase 3" "DP2.3: ## Phase 3 heading present"
assert_grep "$SKILL_FILE" "^## Phase 4" "DP2.4: ## Phase 4 heading present"
assert_grep "$SKILL_FILE" "^## Phase 5" "DP2.5: ## Phase 5 heading present"
assert_grep "$SKILL_FILE" "^## Phase 6" "DP2.6: ## Phase 6 heading present"

echo
echo "== DP4-DP9: pipeline structure + security locks =="
assert_grep "$SKILL_FILE" 'single message|IN A SINGLE MESSAGE' \
  "DP4: single-message fanout instruction present"
assert_grep "$SKILL_FILE" 'git add ' \
  "DP5.1: git add with explicit paths present"
assert_no_grep "$SKILL_FILE" 'git add -A' \
  "DP5.2: skill does NOT use git add -A"
assert_grep "$SKILL_FILE" 'sole git controller|controller owns git|lead is the .*git controller' \
  "DP6: controller-only-git rule present"
assert_grep "$SKILL_FILE" 'gh label create --force prototype' \
  "DP7.1: prototype label creation present"
assert_grep "$SKILL_FILE" 'gh issue create' \
  "DP8: harden-issue creation present"
assert_grep "$SKILL_FILE" 'scope gate|Scope gate|scope-gate' \
  "DP9: scope-gate section present"

echo
echo "== Summary =="
echo "  PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
