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
#   assert_no_grep_nonempty <file> <pattern> <desc>
#     Negative-presence assertion for a file the caller BUILT (an awk/sed slice
#     of a source document). Refuses to pass when <file> is missing or empty —
#     an empty slice matches nothing, so a plain `assert_no_grep` on it passes
#     vacuously and keeps passing after the anchors it slices on are renamed.
#
#   assert_version_bump <repo_root> <version>
#     Asserts <version> is propagated to the manifest surfaces. Deliberately a
#     POINTER, not a second copy: the surface list, its count and the history
#     behind it live in one place, the contract block directly above
#     `assert_version_bump` at the bottom of this file. Two hand-maintained
#     copies of that paragraph are what let a retired surface leave the count
#     stale for a release (#382/#472).

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
  if awk "/$section_start/,/$section_end/" "$file" | grep -E -e "$pattern" >/dev/null; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file  section: $section_start..$section_end  pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep_nonempty() {
  local file="$1" pattern="$2" desc="$3"
  # A slice file that the caller generated with awk/sed is empty whenever the
  # anchors it slices on were renamed. `grep -q` on an empty file never matches,
  # so an absence assertion over it PASSES while inspecting nothing at all
  # (#347). Refuse that outcome before evaluating the pattern.
  if [[ ! -s "$file" ]]; then
    echo "  FAIL  $desc (slice missing or empty — refusing vacuous PASS)"
    echo "        file: $file  pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1)); return
  fi
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"
    echo "        file: $file  pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

_assert_version_bump_one() {  # <abs_file> <grep_pattern> <desc>
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"; FAIL=$((FAIL + 1))
  fi
}

# assert_version_bump <repo_root> <version>
# THE one copy of this contract — the header index above points here rather than
# restating it, because the two hand-maintained copies this block used to have
# are the mechanism that kept a stale surface count alive (see the Codex note
# below). Kept directly above the function it documents, not above the private
# single-surface helper.
#
# DRY the version-lock assertion block that was duplicated across
# tests/goal.test.sh (G20) and tests/solve-claim.test.sh — asserts <version> is
# propagated to all four manifest surfaces (plugin.json, marketplace.json,
# README badge, CHANGELOG header). Self-contained (own grep + $PASS/$FAIL bump,
# same caller-counter contract as assert_count). A release bump is now ONE
# <version>-arg change per call site instead of lockstep multi-line regex edits
# across two files (#231).
#
# The Codex plugin manifest was a fifth surface until the Codex distribution
# was retired and the file stopped existing (#382). The body dropped to four in
# that commit; both copies of this comment kept claiming five until #472, which
# collapsed them into this single block. tests/docs-accuracy.test.sh T12.14 now
# pins the count in both directions — the body's call count and this comment's
# stated number — so the pair cannot drift apart again in silence. The two CI
# test-lock files (tests/goal.test.sh, tests/solve-claim.test.sh) are NOT
# asserted here — they are this helper's own call sites, and
# plugins/uberdev/lib/bump-version.sh is what moves them. Six file surfaces in
# total; the repo-root AGENTS.md is the SSOT for the list.
assert_version_bump() {
  local root="$1" ver="$2"
  local v="${ver//./\\.}"   # escape dots so grep -E matches them literally
  _assert_version_bump_one "$root/plugins/uberdev/.claude-plugin/plugin.json" "\"version\": \"$v\"" "version-bump: plugin.json == $ver"
  _assert_version_bump_one "$root/.claude-plugin/marketplace.json"            "\"version\": \"$v\"" "version-bump: marketplace.json == $ver"
  _assert_version_bump_one "$root/README.md"                                  "version-$v-blue"     "version-bump: README badge == $ver"
  _assert_version_bump_one "$root/CHANGELOG.md"                               "## \[$v\]"           "version-bump: CHANGELOG [$ver] header"
}
