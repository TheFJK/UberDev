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
#
# MEASUREMENT primitives (not assertions — they touch neither $PASS nor $FAIL,
# they print a value and return an rc the caller must branch on):
#
#   checkout_worst_case_bytes <repo_root> <repo_relative_path>
#     Prints the largest number of bytes a clean checkout of HEAD:<path> can
#     put on disk, so a byte budget means the same thing on every platform.
#     Full contract in the block directly above the function (#522).

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

# checkout_worst_case_bytes <repo_root> <repo_relative_path>
#
# Prints ONE integer on stdout: the largest number of bytes a clean checkout of
# HEAD:<path> can put on disk — the committed blob's bytes plus its newline
# count, because core.autocrlf=true (live on windows-latest; /.gitattributes is
# deliberately scoped to plugins/uberdev/hooks/** and tests/docs-accuracy.test.sh
# row T8.10 forbids widening it) rewrites every LF as CRLF on checkout.
#
# WHY THIS UNIT and not a byte count over the worktree file (#522): a worktree
# count measures a checkout-TRANSLATED size, so one literal budget is a
# different, stricter budget on Windows and nobody is told. Measured on one
# commit: plugins/uberdev/skills/using-uberdev/SKILL.md counted 6454 B on the
# ubuntu job and 6579 B on the windows job — its 125 newlines.
#
# WHY NOT plain blob bytes: the consumers read the file FROM THE WORKTREE
# (hooks/session-start cats the primer; the Workflow runtime loads workflow.js),
# so blob-only would be a silent one-byte-per-line LOOSENING on the platform
# carrying the biggest payload. Worst-case keeps today's Windows strictness and
# raises the other platforms to match — nothing has to shrink.
#
# IT IS AN UPPER BOUND, not a per-host prediction: a path pinned `eol=lf` by
# /.gitattributes never actually grows on checkout, so for those files this
# over-estimates by their newline count. That is the safe direction (a budget
# is never loosened) and it keeps the number a property of the COMMIT, which is
# the whole point — but do not read it as "what this host will write to disk".
#
# CONTRACT: never prints a number it did not measure. On any failure it prints
# NOTHING on stdout, and returns non-zero:
#   2  <repo_root> is not a git work tree
#   3  no blob at HEAD:<path> (untracked, renamed, or misspelled)
#   4  the blob could not be read, or a count was not an integer
# It must NOT terminate the shell: it is called inside $( … ), where doing so
# kills only the substitution subshell and leaves the caller holding an empty
# string — the vacuous-pass class this function exists to prevent. Same contract
# as _t10_corpus in tests/docs-accuracy.test.sh, and locked by row T1.f7 of
# tests/workflow-scripts.test.sh. Every call site must capture the rc into a
# variable on the very next line and branch on it.
#
# The blob is spooled to a temp file and counted through a REDIRECT rather than
# piped straight out of git: a pipe discards git's own exit status, and
# recovering it needs bash-only PIPESTATUS. `wc -l` counts \n characters
# exactly, which is exactly how many bytes the CRLF rewrite adds, so a blob with
# no trailing newline correctly contributes nothing for its last line.
checkout_worst_case_bytes() {
  # `rel`, never `path`: zsh ties `path` to `PATH`, so a `local path` inside a
  # function shadows the command search path for the whole scope
  # (tests/crossplatform-shell-wrappers.test.sh catches this shape, and caught
  # this very function).
  local root="$1" rel="$2"
  local tmp blob_bytes blob_lines
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 2
  # Blob preflight kept SEPARATE from the read, so "not in HEAD" (3) stays
  # distinguishable from "in HEAD but unreadable" (4). A tree oid — HEAD:<dir> —
  # passes this preflight and fails the read below as 4, which is loud and correct.
  git -C "$root" rev-parse --verify --quiet "HEAD:$rel" >/dev/null 2>&1 || return 3
  tmp="$(mktemp)" || return 4
  if ! git -C "$root" cat-file blob "HEAD:$rel" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 4
  fi
  # tr strips the padding Git Bash's wc emits. Declared then assigned, never
  # `local x="$(…)"` — local's own rc would win and mask the substitution's.
  blob_bytes="$(wc -c < "$tmp" | tr -d '[:space:]')"
  blob_lines="$(wc -l < "$tmp" | tr -d '[:space:]')"
  rm -f "$tmp"
  # case, not [[ =~ ]] (BASH_REMATCH is unset under zsh) and not a grep pipe
  # (this lib is sourced into pipefail-setting suites).
  case "$blob_bytes" in ''|*[!0-9]*) return 4 ;; esac
  case "$blob_lines" in ''|*[!0-9]*) return 4 ;; esac
  printf '%s\n' "$((blob_bytes + blob_lines))"
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
