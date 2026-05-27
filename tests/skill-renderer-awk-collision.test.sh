#!/usr/bin/env bash
# tests/skill-renderer-awk-collision.test.sh — drift-guard for issue #222.
#
# The Claude Code Skill loader substitutes positional non-flag args of
# $ARGUMENTS into the entire SKILL.md body, INCLUDING inside single-quoted
# awk one-liners. So `awk '$1==p && $2=="x"{t=$3}'` rendered against args
# `--max-parallel=1 219 198` becomes `awk '219==p && 198=="x"{t=}'` —
# corrupting every column ref. The fix is to parameterise the field refs:
#   awk -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="x"{t=$c3}'
# The renderer doesn't recognise `$c1` / `$c2` / `$c3` as positional, so
# the awk script body is preserved verbatim.
#
# This guard scans every plugins/uberdev/skills/*/SKILL.md and fails CI when
# it finds an awk command whose script body contains a bare `$N` field ref
# (1-9). Adopt the `-v cN=N` + `$cN` form instead.
#
# Portable: bash + grep + find + sort. Runs on ubuntu-latest (native bash)
# and windows-latest (Git Bash) without any extra deps.

set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/uberdev/skills"

PASS=0; FAIL=0
echo "## skill-renderer awk-collision drift guard (#222)"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "  ABORT — skills directory missing: $SKILLS_DIR"; exit 99
fi

# R1 — no plugins/uberdev/skills/*/SKILL.md may contain an awk command with
# a bare `$N` field ref (0-9) inside its single-quoted script body. The regex
# `awk[^']*'[^']*\$[0-9][^c]` matches:
#   awk          — the keyword
#   [^']*        — any non-quote chars (flags, -F, -v assignments)
#   '            — opening single-quote of the awk script body
#   [^']*        — any non-quote chars within the body (everything up to
#                  the first `$N` if present)
#   \$[0-9][^c]  — bare `$<digit>` not followed by `c` (i.e. NOT `$c0`/`$c1`)
#
# Why `$0` is included: the Skill renderer also substitutes the first
# positional non-flag arg into bare `$0` references. solve-pipeline's
# `awk '!seen[$0]++'` (the dedupe-by-whole-line idiom) rendered as
# `awk '!seen[222]++'` on `/turbo 222` — works by luck on single-issue
# input but drops every issue past the first on `/turbo 5 6 7`. Same
# class of bug as `$1`-`$9`, same parameterised fix shape: `-v c0=0`
# and `$c0`. See merge-pipeline:809 + finish-branch:162 + solve-pipeline:93.
#
# The `[^']*` anchors are load-bearing: without them, a greedy `.*` after
# `awk` would span across the entire flattened file and flag a `$N` in a
# completely unrelated context (e.g. a shell variable `$1` in a separate
# bash block far away from any awk invocation). The `[^']*` bounds the
# match to the FIRST single-quoted string immediately after `awk`, which is
# the actual awk script body that the Skill renderer would corrupt.
#
# Multi-line awk scripts (issue #222 review blocker — orchestrator/SKILL.md:
# 226-class regression): the awk keyword may appear on one line while the
# bare `$N` lives on a later line of the same single-quoted body. A naive
# per-line `grep` misses this entirely. We flatten the file via `tr '\n' ' '`
# before scanning, so a single-quoted awk body spread across many lines
# becomes one logical line and the [^']*-bounded match still applies cleanly.
# Line-number reporting is sacrificed (file path identifies the vulnerable
# file; the operator greps for the site); an acceptable trade for catching
# the bug class the original line-anchored shape silently passed.

hits=""
while IFS= read -r -d '' skill_file; do
  flattened="$(tr '\n' ' ' < "$skill_file")"
  if printf '%s' "$flattened" | grep -qE "awk[^']*'[^']*\\\$[0-9][^c]"; then
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
  echo "         tests/skill-renderer-awk-collision.test.sh's header comment for the why."
  FAIL=$((FAIL+1))
fi

# R2 — fixture proof: a synthetic SKILL.md fragment containing the bad shape
# MUST be detected by the same regex. This is an inside-out check that the
# guard itself is wired correctly — if a future refactor accidentally breaks
# the regex (e.g. someone changes `\$[1-9]` to `\$[1-3]` and a new $4 site
# slips through), R2 catches it before the live R1 above silently passes.
# Three sub-fixtures: simple awk, -F'\t' prefix awk, and a multi-line awk
# (the third anchors the multi-line scan path strengthened post-#224 review).
fixture="$(mktemp)"
fixture_multi="$(mktemp)"
trap 'rm -f "$fixture" "$fixture_multi"' EXIT
cat > "$fixture" <<'EOF_FIXTURE'
# fake awk site — the regex must flag this
foo="$(awk '$1==p{print $2}' file.tsv)"
EOF_FIXTURE
cat > "$fixture_multi" <<'EOF_MULTI'
# multi-line awk site — line-anchored grep MUST miss it but the flattened
# scan (tr '\n' ' ' + grep) MUST catch it. Anchors orchestrator/SKILL.md:226
# class of regression (issue #222 review blocker).
foo="$(awk '
  /^header/ { capture=1; next }
  capture && NF {
    split($1, p, ":")
  }
' input.tsv)"
EOF_MULTI
# Simple-shape (single-line) — sanity check that the basic case is caught.
if grep -nE "awk[^']*'[^']*\\\$[0-9][^c]" "$fixture" >/dev/null 2>&1; then
  echo "  PASS  R2.simple the guard regex flags a single-line vulnerable awk shape"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2.simple the guard regex no longer flags a single-line vulnerable awk shape"
  echo "         Check this file's grep pattern (currently: awk[^']*'[^']*\\\$[0-9][^c])."
  FAIL=$((FAIL+1))
fi
# Multi-line-shape — the inside-out check for the flattened scan path. A
# line-anchored grep on this fixture would NOT match; the flattened scan
# MUST. If this regresses, R1 silently passes on multi-line vulnerable awks
# (exactly the bug class found at orchestrator/SKILL.md:226).
multi_flat="$(tr '\n' ' ' < "$fixture_multi")"
if printf '%s' "$multi_flat" | grep -qE "awk[^']*'[^']*\\\$[0-9][^c]"; then
  echo "  PASS  R2.multiline the flattened scan flags a multi-line vulnerable awk shape"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2.multiline the flattened scan no longer flags multi-line vulnerable awks"
  echo "         orchestrator/SKILL.md:226-class regressions will silently pass R1."
  FAIL=$((FAIL+1))
fi

# R3 — fixture proof of the inverse: a synthetic SKILL.md fragment using the
# safe parameterised shape MUST NOT be flagged by the regex. Guards against
# the regex becoming over-broad and false-positiving on the recommended fix.
# Includes $c1, $c2, AND $c3 (covers every column index used in the source
# fixes — goal-pipeline uses up to $c3 at lines 387/461/680).
safe_fixture="$(mktemp)"
trap 'rm -f "$fixture" "$fixture_multi" "$safe_fixture"' EXIT
cat > "$safe_fixture" <<'EOF_SAFE'
# parameterised awk — must NOT be flagged
foo="$(awk -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="x"{t=$c3}' file.tsv)"
EOF_SAFE
if grep -nE "awk[^']*'[^']*\\\$[0-9][^c]" "$safe_fixture" >/dev/null 2>&1; then
  echo "  FAIL  R3 the guard regex false-positives on the parameterised \`-v cN=N\` + \`\$cN\` shape"
  echo "         R1 will now red CI on every site that has been correctly fixed."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R3 the guard regex does NOT false-positive on the safe parameterised shape"
  PASS=$((PASS+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
