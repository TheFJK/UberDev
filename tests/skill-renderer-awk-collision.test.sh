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
# a bare `$N` field ref (1-9) in its script body. The regex matches a line
# containing `awk` followed by `$<digit>` not followed by `c` — `$c1` /
# `$c2` / `$c3` (the parameterised form) is the safe shape and the digit
# in `$c1` is not preceded by `$`, so the regex correctly skips it.
#
# Why the `[^c]` lookahead: the parameterised form `$cN` puts `c` AFTER the
# `$`, not before the digit. So `awk -v c1=1 '{print $c1}'` has `$c1` where
# the regex `\$[1-9]` does NOT match (because the char after `$` is `c`, not
# a digit). Conversely `awk '{print $1}'` has `$1<eol>` where the regex `\$[1-9][^c]`
# DOES match. The trailing `[^c]` is just defensive — it rejects the (currently
# impossible) form `$1c` that would shadow `$c1`.

hits="$(find "$SKILLS_DIR" -name "SKILL.md" -print0 \
  | xargs -0 grep -nHE "awk.*\\\$[1-9][^c]" 2>/dev/null || true)"

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
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'EOF_FIXTURE'
# fake awk site — the regex must flag this
foo="$(awk '$1==p{print $2}' file.tsv)"
EOF_FIXTURE
if grep -nE "awk.*\\\$[1-9][^c]" "$fixture" >/dev/null 2>&1; then
  echo "  PASS  R2 the guard regex correctly flags a synthetic vulnerable awk shape"
  PASS=$((PASS+1))
else
  echo "  FAIL  R2 the guard regex no longer flags a synthetic vulnerable awk shape"
  echo "         The R1 scan above is silently passing on every file because the regex is broken."
  echo "         Check this file's grep pattern (currently: awk.*\\\$[1-9][^c])."
  FAIL=$((FAIL+1))
fi

# R3 — fixture proof of the inverse: a synthetic SKILL.md fragment using the
# safe parameterised shape MUST NOT be flagged by the regex. Guards against
# the regex becoming over-broad and false-positiving on the recommended fix.
safe_fixture="$(mktemp)"
trap 'rm -f "$fixture" "$safe_fixture"' EXIT
cat > "$safe_fixture" <<'EOF_SAFE'
# parameterised awk — must NOT be flagged
foo="$(awk -v c1=1 -v c2=2 '$c1==p{print $c2}' file.tsv)"
EOF_SAFE
if grep -nE "awk.*\\\$[1-9][^c]" "$safe_fixture" >/dev/null 2>&1; then
  echo "  FAIL  R3 the guard regex false-positives on the parameterised \`-v cN=N\` + \`\$cN\` shape"
  echo "         R1 will now red CI on every site that has been correctly fixed."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R3 the guard regex does NOT false-positive on the safe parameterised shape"
  PASS=$((PASS+1))
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
