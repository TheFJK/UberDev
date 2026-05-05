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
