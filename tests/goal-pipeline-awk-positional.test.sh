#!/usr/bin/env bash
# tests/goal-pipeline-awk-positional.test.sh — regression-lock for #222.
#
# The Claude Code Skill loader text-blind-substitutes positional non-flag args
# of $ARGUMENTS into the entire rendered SKILL.md body. The substitution does
# NOT respect single-quote boundaries, so awk field references like $1 / $2 /
# $3 inside `awk '...'` one-liners are rewritten as if they were shell
# positional parameters. That silently corrupts every state-read in
# goal-pipeline (Phase 1 skip-check, Phase 2 dispatch_ts / seen_ts / merge_ts,
# Phase 3 all_pr_count / issues_resolved), causing false convergence and
# false FAILED transitions.
#
# The fix (issue #222 Option 1) is to parameterise the field refs via
#   awk -v c1=1 -v c2=2 -v c3=3 '... $c1 ... $c2 ... $c3 ...'
# The renderer does NOT substitute $cN (it's not a positional shell var).
#
# This static test walks every awk one-liner in the pipeline SKILL.md bodies
# and asserts no `$1`..`$9` literal field-ref appears inside a single-quoted
# region. Defense-in-depth: covers all 5 *-pipeline files so a future
# regression in any of them is caught.
#
# Detection algorithm: state-machine walk over each line containing `awk `.
# Track an in_quote toggle as we encounter `'`; accumulate the bytes seen
# while in_quote is true. Match `$[1-9]` against the accumulated buffer.
# The toggle is sufficient because shell single quotes do not nest and do
# not support backslash-escape inside the quoted region.

set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/plugins/uberdev/skills"

PASS=0; FAIL=0
echo "## goal-pipeline awk positional-arg-substitution guard (#222)"

# Subjects: every *-pipeline SKILL.md that runs through the args-substituting
# Skill loader. goal-pipeline was the trigger; the others get the same
# defense-in-depth lock so a future regression is caught immediately.
SUBJECTS=(
  "$PIPELINE_DIR/goal-pipeline/SKILL.md"
  "$PIPELINE_DIR/uberscan-pipeline/SKILL.md"
  "$PIPELINE_DIR/ubersimplify-pipeline/SKILL.md"
  "$PIPELINE_DIR/merge-pipeline/SKILL.md"
  "$PIPELINE_DIR/solve-pipeline/SKILL.md"
  "$PIPELINE_DIR/testers-pipeline/SKILL.md"
)

for SUBJECT in "${SUBJECTS[@]}"; do
  rel="${SUBJECT#"$REPO_ROOT/"}"
  if [ ! -r "$SUBJECT" ]; then
    echo "  FAIL  G_$(basename "$(dirname "$SUBJECT")") subject not readable: $rel"
    FAIL=$((FAIL+1))
    continue
  fi
  violations=$(awk '
    /awk[ \t]/ {
      line = $0
      in_quote = 0
      quoted = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\047") {
          in_quote = !in_quote
        } else if (in_quote) {
          quoted = quoted c
        }
      }
      if (match(quoted, /\$[1-9]/) > 0) {
        printf "    %s:%d  %s\n", FILENAME, NR, $0
        v++
      }
    }
    END { exit (v > 0 ? 1 : 0) }
  ' "$SUBJECT")
  rc=$?
  tag="G_$(basename "$(dirname "$SUBJECT")")"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $tag $rel: no \$N field refs inside single-quoted awk scripts"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $tag $rel: \$N field refs inside single-quoted awk scripts (Skill renderer will substitute):"
    printf '%s\n' "$violations"
    echo "         Fix: parameterise via 'awk -v c1=1 -v c2=2 -v c3=3 ... \$c1 ... \$c2 ... \$c3 ...'"
    FAIL=$((FAIL+1))
  fi
done

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
