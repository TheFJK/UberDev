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
#     Asserts <version> is propagated to all five manifest surfaces
#     (plugin.json, marketplace.json, Codex plugin.json, README badge,
#     CHANGELOG header). DRYs the
#     version-lock block previously duplicated across goal.test.sh (G20) and
#     solve-claim.test.sh. A release bump is now one <version>-arg change per
#     call site instead of lockstep multi-form-regex edits (#231).

assert_count() {
  local file="$1" section_start="$2" section_end="$3" pattern="$4" expected="$5" desc="$6"
  # Fail-loud preflight: a missing/unreadable $file used to make awk emit
  # nothing, grep -c print "0", and `|| true` swallow the failure — so any
  # caller with expected==0 (an absence assertion) PASSED vacuously even though
  # the file it claims to inspect does not exist (#275). Refuse here instead.
  if [[ ! -r "$file" ]]; then
    echo "  FAIL  $desc (file missing/unreadable — cannot count, refusing vacuous PASS)"
    echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1)); return
  fi
  # Capture awk's exit status SEPARATELY from grep's so an awk crash (bad
  # range, mid-stream failure) is surfaced as a FAIL rather than masked into a
  # 0-count by the old `… | grep -c … || true` pipe. grep -c's own exit-1 on a
  # legitimate 0 match is expected here — we read its stdout for the count, not
  # its rc — so a genuine absence assertion (present file, 0 matches) still
  # PASSES. Only a grep *error* (rc>=2) is treated as a failure.
  local section awk_rc actual grep_rc
  section=$(awk "/$section_start/,/$section_end/" "$file"); awk_rc=$?
  if [[ "$awk_rc" -ne 0 ]]; then
    echo "  FAIL  $desc (awk failed rc=$awk_rc — cannot count, refusing vacuous PASS)"
    echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1)); return
  fi
  actual=$(printf '%s\n' "$section" | grep -cE -e "$pattern"); grep_rc=$?
  if [[ "$grep_rc" -ge 2 ]]; then
    echo "  FAIL  $desc (grep failed rc=$grep_rc — cannot count, refusing vacuous PASS)"
    echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1)); return
  fi
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
# propagated to all five manifest surfaces (plugin.json, marketplace.json,
# Codex plugin.json, README badge, CHANGELOG header). Self-contained (own grep + $PASS/$FAIL bump,
# same caller-counter contract as assert_count). A release bump is now ONE
# <version>-arg change per call site instead of lockstep multi-line regex edits
# across two files (#231).
_assert_version_bump_one() {  # <abs_file> <grep_pattern> <desc>
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"; FAIL=$((FAIL + 1))
  fi
}
assert_version_bump() {
  local root="$1" ver="$2"
  local v="${ver//./\\.}"   # escape dots so grep -E matches them literally
  _assert_version_bump_one "$root/plugins/uberdev/.claude-plugin/plugin.json" "\"version\": \"$v\"" "version-bump: plugin.json == $ver"
  _assert_version_bump_one "$root/.claude-plugin/marketplace.json"            "\"version\": \"$v\"" "version-bump: marketplace.json == $ver"
  _assert_version_bump_one "$root/codex/uberdev-codex/.codex-plugin/plugin.json" "\"version\": \"$v\"" "version-bump: Codex plugin.json == $ver"
  _assert_version_bump_one "$root/README.md"                                  "version-$v-blue"     "version-bump: README badge == $ver"
  _assert_version_bump_one "$root/CHANGELOG.md"                               "## \[$v\]"           "version-bump: CHANGELOG [$ver] header"
}
