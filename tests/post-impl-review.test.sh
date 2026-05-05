#!/usr/bin/env bash
# Asserts that uberdev:post-impl-review skill exists as a Phase 1 post-PR-push
# reviewer fanout, dispatches all 6 reviewer agents in a single message
# (5 distinct files; code-reviewer dispatched twice — general lens + correctness
# lens), and that deprecated pre-push call sites have been removed per #67.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POST_IMPL="$REPO_ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
SOLVE_CMD="$REPO_ROOT/plugins/uberdev/commands/solve.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"

for f in "$POST_IMPL" "$SOLVE_CMD" "$SUBAGENT_DRIVEN" "$SOLVE_PIPELINE"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

# Structural-assertion helpers (assert_count / assert_subagent_type / assert_in_section)
. "$REPO_ROOT/tests/_lib_assert_structural.sh"

echo "== post-impl-review skill exists with frontmatter =="
assert_grep "$POST_IMPL" '^name: post-impl-review' "frontmatter has name: post-impl-review"

echo
echo "== 6 reviewer agents named in single message =="
assert_grep "$POST_IMPL" 'code-reviewer' "code-reviewer named"
assert_grep "$POST_IMPL" 'pr-test-analyzer' "pr-test-analyzer named (6th reviewer per #73)"
assert_grep "$POST_IMPL" 'silent-failure-hunter' "silent-failure-hunter named"
assert_grep "$POST_IMPL" 'type-design-analyzer' "type-design-analyzer named"
assert_grep "$POST_IMPL" 'comment-analyzer' "comment-analyzer named"
# Anti-regression: code-simplifier MUST NOT be in the Step 2 dispatch table region
# (it moved to Phase 2 of /uberdev:review-pr as the named lens dispatcher per #73).
if awk '/^### Step 2:/,/^### Step 3:/' "$POST_IMPL" | grep -qE '\| .code-simplifier. \|'; then
  echo "  FAIL  code-simplifier MUST NOT appear in Step 2 dispatch table (moved to Phase 2 lens per #73)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  code-simplifier removed from Step 2 dispatch table (Phase 1 → Phase 2 lens migration)"; PASS=$((PASS + 1))
fi
# F3 — dispatch table row count, anchored on the FIRST column (the reviewer
# name) to avoid over-matching row dividers. The first column shape is
# "| `<name>`" optionally followed by " (qualifier)" before the next pipe —
# the second `code-reviewer` row uses " (general lens)" so we tolerate any
# non-pipe trailing chars between the closing backtick and the next "|".
assert_count "$POST_IMPL" '^### Step 2: ' '^### Step 3: ' '^\| .code-[a-z-]+.[^|]*\||^\| .pr-test-analyzer.[^|]*\||^\| .silent-failure-hunter.[^|]*\||^\| .type-design-analyzer.[^|]*\||^\| .comment-analyzer.[^|]*\|' \
  6 \
  "Step 2 dispatch table has exactly 6 reviewer rows (one per dispatch slot, including 2 code-reviewer rows)"
assert_grep "$POST_IMPL" 'single message|SINGLE message|one assistant turn|ONE assistant turn' \
  "single-message-fanout invariant documented"
assert_grep "$POST_IMPL" '6 Task\(\) calls.*ONE assistant turn|MUST be in ONE assistant turn' \
  "6 Task() calls / single-message invariant documented"

echo
echo "== Aspect emphasis input + Step 1 brief assembly (#73) =="
assert_grep "$POST_IMPL" '^- .aspect_emphasis. — optional list' \
  "Inputs section accepts aspect_emphasis (optional list)"
assert_in_section "$POST_IMPL" '^### Step 1: Build' '^### Step 2:' \
  '## Emphasis' \
  "Step 1 brief assembly mentions ## Emphasis section appended when aspect_emphasis non-empty"

echo
echo "== Fanout cap default updated 5 → 6 (#73) =="
assert_grep "$POST_IMPL" 'uberdev_read_int_in_range fanout_concurrency\.post_impl_review UBERDEV_FANOUT_POST_IMPL_REVIEW 1 50 6' \
  "fanout cap default in uberdev_read_int_in_range bumped to 6 (was 5)"
assert_grep "$POST_IMPL" 'POST_IMPL_REVIEW_CAP=6' \
  "fanout cap fallback assignment is 6 (was 5)"

echo
echo "== pr-test-analyzer YAML migration-window fallback (#73) =="
assert_grep "$POST_IMPL" 'Migration-window fallback for .pr-test-analyzer.' \
  "Step 4 documents transient fallback parser for legacy free-form pr-test-analyzer output"

echo
echo "== Anti-regression: pre-push call sites removed (#67) =="
# Tightened from plan-spec literal `'uberdev:post-impl-review|post-impl-review'` per
# controller note: subagent-driven-dev/SKILL.md retains 2 spec-mandated cross-references
# (line 54 BASELINE_SHA narrative, line 97 diagram caption) that point readers to the NEW
# post-PR-push location. Those are descriptive prose, not call sites — the structural
# intent of this assertion is "no Skill(uberdev:post-impl-review) invocation" rather
# than "no string match". Same tightening applied to solve-pipeline for symmetry.
assert_no_grep "$SOLVE_PIPELINE" 'Skill\(uberdev:post-impl-review\)|Skill tool.*uberdev:post-impl-review|Invoke .uberdev:post-impl-review. skill' \
  "solve-pipeline/SKILL.md no longer references post-impl-review (pre-push call site removed per #67)"
assert_no_grep "$SUBAGENT_DRIVEN" 'Skill\(uberdev:post-impl-review\)|Skill tool.*uberdev:post-impl-review|Invoke .uberdev:post-impl-review. skill' \
  "subagent-driven-dev/SKILL.md no longer references post-impl-review (end-of-issue call site removed per #67)"

echo
echo "== Anti-regression: obsolete SDD step 5 prose removed =="
assert_no_grep "$SUBAGENT_DRIVEN" 'End-of-issue post-impl-review' \
  "subagent-driven-dev no longer codifies the consolidated end-of-issue invocation (step 5 deleted per #67)"
assert_no_grep "$SUBAGENT_DRIVEN" 'WAVE.*final|WAVE: .final.' \
  "subagent-driven-dev no longer passes WAVE=final (no in-skill post-impl-review dispatch)"

echo
echo "== Anti-regression: per-wave post-impl-review wording is GONE from subagent-driven-dev wave-loop =="
# Whole-file count of "per-wave" inside the wave-loop region must be 0. The Red Flag bullet
# elsewhere in the file uses "post-wave full-test-suite" (different phrase, about the
# full-test-suite run that stays in the loop — unrelated to the relocation), so we anchor on
# the wave-loop section only via awk range. Anchor-existence guard added below: if either
# range header is renamed (e.g. ### -> ##, or wording changes), awk silently returns empty
# and grep would report 0 hits — a false PASS. Verify both anchors exist first.
if ! grep -q '^### High-Level Flow' "$SUBAGENT_DRIVEN" || ! grep -q '^### Parallel Dispatch Pattern' "$SUBAGENT_DRIVEN"; then
  echo "  FAIL  awk anchors '### High-Level Flow' / '### Parallel Dispatch Pattern' missing — wave-loop region cannot be extracted (rename detected?)"
  FAIL=$((FAIL + 1))
else
  WAVE_LOOP_REGION=$(awk '/^### High-Level Flow/,/^### Parallel Dispatch Pattern/' "$SUBAGENT_DRIVEN")
  if [ -z "$WAVE_LOOP_REGION" ]; then
    echo "  FAIL  awk extracted empty wave-loop region (anchors found but range did not match)"
    FAIL=$((FAIL + 1))
  else
    # `grep -c` always prints the count to stdout (even 0), but exits 1 on zero matches.
    # `|| true` keeps the count clean (avoids "0\n0" from `|| echo 0`) and tolerates the non-zero exit.
    WAVE_LOOP_HITS=$(grep -cE "per-wave|after each wave" <<<"$WAVE_LOOP_REGION" || true)
    if [[ "$WAVE_LOOP_HITS" -eq 0 ]]; then
      echo "  PASS  per-wave / after-each-wave wording removed from wave-loop region"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  per-wave / after-each-wave wording must be 0 in wave-loop region (got $WAVE_LOOP_HITS)"
      FAIL=$((FAIL + 1))
    fi
  fi
fi

# Obsolete step 5 prose must be fully gone
if grep -qE "per-wave post-impl-review has already covered" "$SUBAGENT_DRIVEN"; then
  echo "  FAIL  obsolete step 5 wording 'per-wave post-impl-review has already covered' must be removed"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  obsolete step 5 wording removed"
  PASS=$((PASS + 1))
fi

echo
echo "== post-impl-review/SKILL.md names /uberdev:review-pr Phase 1 as sole live caller (#67) =="
assert_grep "$POST_IMPL" '/uberdev:review-pr Phase 1' \
  "When-to-invoke names /uberdev:review-pr Phase 1 as the sole live caller"
assert_no_grep "$POST_IMPL" 'end-of-issue from subagent-driven-dev' \
  "frontmatter description no longer names subagent-driven-dev as a caller"
assert_grep "$POST_IMPL" 'post-impl-review-final\.md' \
  "Step 4 output paths name the canonical post-impl-review-final.md (no wave- infix)"
assert_grep "$POST_IMPL" 'Findings artifact contract' \
  "Integration section contains a Findings artifact contract subsection"
assert_grep "$POST_IMPL" 'Pre-push bypass|Options 1.*3.*4.*bypass|Options 1, 3, 4 bypass' \
  "Integration section documents the finish-branch Options 1/3/4 bypass"
assert_grep "$POST_IMPL" 'external-untrusted-input source="post-impl-review-aggregate"' \
  "Findings artifact contract names the trust-boundary envelope on the reader side"

echo
echo "== code-simplifier agent self-trigger guard drops 'post-wave' wording =="
CODE_SIMPLIFIER="$REPO_ROOT/plugins/uberdev/agents/code-simplifier.md"
if [ ! -r "$CODE_SIMPLIFIER" ]; then
  echo "  FAIL  code-simplifier.md missing or unreadable"
  FAIL=$((FAIL + 1))
else
  if grep -q "post-wave" "$CODE_SIMPLIFIER"; then
    echo "  FAIL  'post-wave' must be removed from code-simplifier.md self-trigger guard"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  'post-wave' wording removed from code-simplifier.md"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "== Both AUTO_MODE branches of trivial+small heredocs omit post-impl-review (#67) =="
# Anchor presence guard — if the extraction anchors disappear from solve-pipeline
# (e.g., heredoc reshape), awk silently produces empty output and the grep below
# returns 1 ("no match"), causing both assertions to PASS when they should
# report a setup error. Validate the anchors exist before extracting.
if ! grep -qE '^if \[\[ "\$AUTO_MODE" != "1" \]\]; then$' "$SOLVE_PIPELINE" \
   || ! grep -qE '^else$' "$SOLVE_PIPELINE"; then
  echo "  FAIL  setup error: AUTO_MODE branch anchors not found in $SOLVE_PIPELINE — heredoc reshaped? Update the awk extraction in tests/post-impl-review.test.sh."
  FAIL=$((FAIL + 1))
else
  AUTO_MODE_0_BODIES=$(awk '
    /^if \[\[ "\$AUTO_MODE" != "1" \]\]; then$/ { in_solve=1; next }
    in_solve && /^else$/ { in_solve=0; next }
    in_solve && /<< EOF$/ { in_heredoc=1; next }
    in_solve && in_heredoc && /^EOF$/ { in_heredoc=0; next }
    in_solve && in_heredoc { print }
  ' "$SOLVE_PIPELINE")
  AUTO_MODE_1_BODIES=$(awk '
    /^if \[\[ "\$AUTO_MODE" != "1" \]\]; then$/ { in_solve=1; next }
    in_solve && /^else$/ { in_solve=0; in_turbo=1; next }
    in_turbo && /^fi$/ { in_turbo=0; next }
    in_turbo && /<< EOF$/ { in_heredoc=1; next }
    in_turbo && in_heredoc && /^EOF$/ { in_heredoc=0; next }
    in_turbo && in_heredoc { print }
  ' "$SOLVE_PIPELINE")
  # Body-non-empty guard — the trivial+small heredocs MUST exist post-refactor
  # (only their bodies must omit post-impl-review). Empty extraction = setup error.
  if [ -z "$AUTO_MODE_0_BODIES" ]; then
    echo "  FAIL  setup error: AUTO_MODE=0 heredoc bodies extracted as empty — heredoc reshaped or removed? Update the awk extraction."
    FAIL=$((FAIL + 1))
  fi
  if [ -z "$AUTO_MODE_1_BODIES" ]; then
    echo "  FAIL  setup error: AUTO_MODE=1 heredoc bodies extracted as empty — heredoc reshaped or removed? Update the awk extraction."
    FAIL=$((FAIL + 1))
  fi
fi
if grep -qE 'post-impl-review|uberdev:post-impl-review' <<<"$AUTO_MODE_0_BODIES"; then
  echo "  FAIL  AUTO_MODE=0 (interactive) trivial/small heredoc BODIES MUST NOT mention post-impl-review (per #67 — pre-push call sites removed)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  AUTO_MODE=0 (interactive) trivial/small heredoc bodies correctly omit post-impl-review"
  PASS=$((PASS + 1))
fi
if grep -qE 'post-impl-review|uberdev:post-impl-review' <<<"$AUTO_MODE_1_BODIES"; then
  echo "  FAIL  AUTO_MODE=1 (turbo) trivial/small heredoc BODIES MUST NOT mention post-impl-review (asymmetry preserved per #15 + #67)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  AUTO_MODE=1 (turbo) trivial/small heredoc bodies correctly omit post-impl-review"
  PASS=$((PASS + 1))
fi

echo
echo "== Anti-loop guard: skill MUST NOT re-invoke brainstorm or write-plan =="
if grep -qE 'invoke[[:space:]]+(uberdev:)?brainstorm|invoke[[:space:]]+(uberdev:)?write-plan' "$POST_IMPL"; then
  echo "  FAIL  post-impl-review skill must not invoke brainstorm or write-plan"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  post-impl-review skill does not invoke brainstorm or write-plan"
  PASS=$((PASS + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
