#!/usr/bin/env bash
# Shared structural-assertion helpers for uberdev test suites.
# Sourced (not executed) — relies on the caller defining $PASS, $FAIL counters
# and producing its own summary at the end.
#
# Helpers:
#   assert_count <file> <section_start> <section_end> <pattern> <expected> <desc>
#     Counts lines matching <pattern> inside the awk range
#     /<section_start>/,/<section_end>/ of <file>. Fails if count != expected.
#
#   assert_subagent_type <file> <agent_name> <desc>
#     Asserts that <file> contains a literal subagent_type assignment for the
#     given agent name (with or without the uberdev: prefix). Matches:
#       subagent_type: uberdev:<agent_name>
#       subagent_type=uberdev:<agent_name>
#       subagent_type: <agent_name>
#     and the quoted variants.
#
#   assert_in_section <file> <section_start> <section_end> <pattern> <desc>
#     Asserts that <pattern> appears inside the awk range
#     /<section_start>/,/<section_end>/ of <file>. Use to anchor a string to a
#     specific section so a prose match elsewhere in the file does not
#     false-positive.
#
#   assert_version_bump <repo_root> <version>
#     Asserts <version> is propagated to all four manifest surfaces
#     (plugin.json, marketplace.json, README badge, CHANGELOG header). DRYs the
#     version-lock block previously duplicated across goal.test.sh (G20) and
#     solve-claim.test.sh. A release bump is now one <version>-arg change per
#     call site instead of lockstep multi-form-regex edits (#231).

assert_count() {
  local file="$1" section_start="$2" section_end="$3" pattern="$4" expected="$5" desc="$6"
  local actual
  actual=$(awk "/$section_start/,/$section_end/" "$file" | grep -cE -e "$pattern" || true)
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  PASS  $desc (got $actual)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (expected $expected, got $actual)"
    echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_subagent_type() {
  local file="$1" agent_name="$2" desc="$3"
  if grep -qE "subagent_type[:=][[:space:]]*['\"]?(uberdev:)?$agent_name" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file  agent: $agent_name"
    FAIL=$((FAIL + 1))
  fi
}

assert_in_section() {
  local file="$1" section_start="$2" section_end="$3" pattern="$4" desc="$5"
  if awk "/$section_start/,/$section_end/" "$file" | grep -qE -e "$pattern"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# assert_version_bump <repo_root> <version>
# DRY the version-lock assertion block that was duplicated across
# tests/goal.test.sh (G20) and tests/solve-claim.test.sh — asserts <version> is
# propagated to all four manifest surfaces (plugin.json, marketplace.json,
# README badge, CHANGELOG header). Self-contained (own grep + $PASS/$FAIL bump,
# same caller-counter contract as assert_count). A release bump is now ONE
# <version>-arg change per call site instead of lockstep multi-line regex edits
# across two files (#231; the exact footgun memory project_uberdev_version_lock_tests tracks).
_assert_version_bump_one() {  # <abs_file> <grep_pattern> <desc>
  if grep -qE -e "$2" "$1"; then
    echo "  PASS  $3"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $3"; echo "        file: $1"; echo "        pattern: $2"; FAIL=$((FAIL + 1))
  fi
}
assert_version_bump() {
  local root="$1" ver="$2"
  local v="${ver//./\\.}"   # escape dots so grep -E matches them literally
  _assert_version_bump_one "$root/plugins/uberdev/.claude-plugin/plugin.json" "\"version\": \"$v\"" "version-bump: plugin.json == $ver"
  _assert_version_bump_one "$root/.claude-plugin/marketplace.json"            "\"version\": \"$v\"" "version-bump: marketplace.json == $ver"
  _assert_version_bump_one "$root/README.md"                                  "version-$v-blue"     "version-bump: README badge == $ver"
  _assert_version_bump_one "$root/CHANGELOG.md"                               "## \[$v\]"           "version-bump: CHANGELOG [$ver] header"
}
