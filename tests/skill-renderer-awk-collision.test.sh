#!/usr/bin/env bash
# tests/skill-renderer-awk-collision.test.sh — drift-guard for issue #222.
#
# The Claude Code Skill loader substitutes positional non-flag args of
# $ARGUMENTS into the entire SKILL.md body, INCLUDING inside single-quoted
# awk one-liners. So `awk '$1==p && $2=="x"{t=$3}'` rendered against args
# `--max-parallel=1 219 198` becomes `awk '219==p && 198=="x"{t=}'` —
# corrupting every column ref. The fix is to parameterise the field refs:
#   awk -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="x"{t=$c3}'
# The renderer doesn't recognise `$c1` / `$c2` / `$c3` as positional (the
# char immediately after `$` is `c`, not a digit), so the awk script body
# is preserved verbatim.
#
# This guard scans every plugins/uberdev/skills/*/SKILL.md and fails CI when
# it finds an awk command whose script body contains a bare `$N` field ref
# (0-9). Adopt the `-v cN=N` + `$cN` form instead.
#
# Portable: bash + grep + find + sort + tr. Runs on ubuntu-latest (native
# bash) and windows-latest (Git Bash) without any extra deps.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/uberdev/skills"

# Single source of truth for the vulnerable-awk regex (Phase 2 simplify-lens
# Reuse / Quality / Efficiency convergence — was duplicated 4× before).
#
# Pattern: `awk[^']*'[^']*\$[0-9]` — anchors:
#   awk      — the keyword.
#   [^']*    — any non-quote chars (flags, -F, -v assignments).
#   '        — opening single-quote of the awk script body.
#   [^']*    — any non-quote chars within the body, up to the first `$N`.
#   \$[0-9]  — bare `$<digit>` (0-9). The safe parameterised form `$c1` /
#              `$c2` etc. has `c` immediately after `$` (alphabetic, not a
#              digit), so the regex does not match it — no `[^c]` exclusion
#              needed, and adding one was a false-negative source: `[^c]`
#              required SOME char after the digit, missing `$N` at end-of-
#              file (degenerate after flatten) AND erroneously skipping the
#              `$1cents` shape (vulnerable but with `c` immediately after).
#
# Why `$0` is included: the Skill renderer also substitutes the first
# positional non-flag arg into bare `$0` references. solve-pipeline's
# `awk '!seen[$0]++'` (dedupe-by-whole-line) rendered as `awk '!seen[222]++'`
# on `/turbo 222` — works by luck on single-issue input but drops every
# issue past the first on `/turbo 5 6 7`. Same bug class, same fix shape:
# `-v c0=0` + `$c0`. See merge-pipeline:809 + finish-branch:162 + solve-
# pipeline:93.
#
# Why `[^']*` anchors are load-bearing: without them, a greedy `.*` after
# `awk` would span across the entire flattened file and false-flag a `$N`
# in an unrelated bash block far from any awk. The `[^']*` bounds the match
# to the FIRST single-quoted string after `awk`, which is the actual awk
# script body the Skill renderer would corrupt.
#
# Why we flatten files first (issue #222 review blocker — orchestrator/
# SKILL.md:225-class regression): multi-line awk scripts have the awk
# keyword on one line and the bare `$N` on a later line of the same single-
# quoted body. A naive per-line `grep` misses this entirely. We flatten via
# `tr '\n' ' '` before scanning, so a multi-line awk body becomes one
# logical line and the `[^']*`-bounded match still applies cleanly.
# Line-number reporting is sacrificed (file path identifies the vulnerable
# file; the operator greps for the site).
GUARD_REGEX="awk[^']*'[^']*\\\$[0-9]"

PASS=0; FAIL=0
echo "## skill-renderer awk-collision drift guard (#222)"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "  ABORT — skills directory missing: $SKILLS_DIR"; exit 99
fi

# R1 — no plugins/uberdev/skills/*/SKILL.md may contain an awk command with
# a bare `$N` field ref (0-9) inside its single-quoted script body.
hits=""
while IFS= read -r -d '' skill_file; do
  flattened="$(tr '\n' ' ' < "$skill_file")"
  if printf '%s' "$flattened" | grep -qE "$GUARD_REGEX"; then
    hits="$hits$skill_file"$'\n'
  fi
done < <(find "$SKILLS_DIR" -name "SKILL.md" -print0)

if [ -z "$hits" ]; then
  echo "  PASS  R1 no plugins/uberdev/skills/*/SKILL.md awk script body contains a bare \$N field ref"
  PASS=$((PASS+1))
else
  echo "  FAIL  R1 these SKILL.md awk one-liners use bare \$N field refs vulnerable to the renderer:"
  printf '          %s\n' "$hits" | sed 's/^/  /'
  echo "         Fix: add \`-v c1=1 -v c2=2 -v c3=3\` to the awk invocation and use \`\$c1\` / \`\$c2\` / \`\$c3\`"
  echo "         in place of \`\$1\` / \`\$2\` / \`\$3\`. See goal-pipeline/SKILL.md for examples and"
  echo "         this file's header comment for the why."
  FAIL=$((FAIL+1))
fi

# R2 + R3 fixture setup — single trap install up front covers every mktemp.
# Bash supports ONE EXIT trap per shell; declaring all three fixtures + one
# trap before any cat-into-fixture avoids the prior two-trap shape where the
# second silently superseded the first (Phase 2 simplify Quality + Efficiency).
fixture_simple="$(mktemp)"
fixture_multi="$(mktemp)"
fixture_safe="$(mktemp)"
trap 'rm -f "$fixture_simple" "$fixture_multi" "$fixture_safe"' EXIT

# R2 — fixture proof: a synthetic SKILL.md fragment containing the bad shape
# MUST be detected by the same regex. This is an inside-out check that the
# guard itself is wired correctly — if a future refactor accidentally breaks
# the regex (e.g. someone narrows `\$[0-9]` to `\$[1-3]` and a new $4 site
# slips through), R2 catches it before the live R1 above silently passes.
# Two sub-fixtures: simple single-line awk + a multi-line awk (the latter
# anchors the multi-line scan path strengthened post-#224 review).
cat > "$fixture_simple" <<'EOF_FIXTURE'
# fake awk site — the regex must flag this
foo="$(awk '$1==p{print $2}' file.tsv)"
EOF_FIXTURE
cat > "$fixture_multi" <<'EOF_MULTI'
# multi-line awk site — line-anchored grep MUST miss it but the flattened
# scan (tr '\n' ' ' + grep) MUST catch it. Anchors orchestrator/SKILL.md:225
# class of regression (issue #222 review blocker).
foo="$(awk '
  /^header/ { capture=1; next }
  capture && NF {
    split($1, p, ":")
  }
' input.tsv)"
EOF_MULTI

# Simple-shape (single-line) — sanity check that the basic case is caught.
if grep -qE "$GUARD_REGEX" "$fixture_simple"; then
  echo "  PASS  R2.simple the guard regex flags a single-line vulnerable awk shape"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2.simple the guard regex no longer flags a single-line vulnerable awk shape"
  echo "         Check GUARD_REGEX in this file (currently: $GUARD_REGEX)."
  FAIL=$((FAIL+1))
fi

# Multi-line-shape — the inside-out check for the flattened scan path. A
# line-anchored grep on this fixture would NOT match; the flattened scan
# MUST. If this regresses, R1 silently passes on multi-line vulnerable awks
# (exactly the bug class found at orchestrator/SKILL.md:225).
multi_flat="$(tr '\n' ' ' < "$fixture_multi")"
if printf '%s' "$multi_flat" | grep -qE "$GUARD_REGEX"; then
  echo "  PASS  R2.multiline the flattened scan flags a multi-line vulnerable awk shape"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2.multiline the flattened scan no longer flags multi-line vulnerable awks"
  echo "         orchestrator/SKILL.md:225-class regressions will silently pass R1."
  FAIL=$((FAIL+1))
fi

# R3 — fixture proof of the inverse: a synthetic SKILL.md fragment using the
# safe parameterised shape MUST NOT be flagged by the regex. Guards against
# the regex becoming over-broad and false-positiving on the recommended fix.
# Includes $c0, $c1, $c2, AND $c3 (covers every column index in the source
# fixes — solve/merge/finish use $c0; goal-pipeline uses up to $c3).
cat > "$fixture_safe" <<'EOF_SAFE'
# parameterised awk — must NOT be flagged
foo="$(awk -v c0=0 -v c1=1 -v c2=2 -v c3=3 '!seen[$c0]++ && $c1==p && $c2=="x"{t=$c3}' file.tsv)"
EOF_SAFE
if grep -qE "$GUARD_REGEX" "$fixture_safe"; then
  echo "  FAIL  R3 the guard regex false-positives on the parameterised \`-v cN=N\` + \`\$cN\` shape"
  echo "         R1 will now red CI on every site that has been correctly fixed."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R3 the guard regex does NOT false-positive on the safe parameterised shape"
  PASS=$((PASS+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
