#!/usr/bin/env bash
# tests/skill-renderer-awk-collision.test.sh — drift-guard for issue #222
# (R1/R2/R3, awk surface) and issue #225 (R4/R5, bash surface).
#
# The Claude Code Skill loader substitutes positional non-flag args of
# $ARGUMENTS into the entire SKILL.md body, INCLUDING inside single-quoted
# awk one-liners AND inside bash function bodies. Two surfaces of the same
# bug class:
#
# awk (#222): `awk '$1==p && $2=="x"{t=$3}'` rendered against args
# `--max-parallel=1 219 198` becomes `awk '219==p && 198=="x"{t=}'` —
# corrupting every column ref. Fix: parameterise via -v field refs:
#   awk -v c1=1 -v c2=2 -v c3=3 '$c1==p && $c2=="x"{t=$c3}'
# The renderer doesn't recognise `$c1` / `$c2` / `$c3` as positional (the
# char immediately after `$` is `c`, not a digit), so the awk script body
# is preserved verbatim.
#
# bash (#225): `emit_topic_log() { echo "x=$1 y=$2"; }` rendered against
# args `--turbo solve GH issue #225` becomes `echo "x=solve y=GH"` —
# hardcoding every call site to the same render-time substitution instead
# of binding at call time. Fix: use bash array-slice positional access:
#   emit_topic_log() { local x="${@:1:1}"; local y="${@:2:1}"; ... }
# The `${@:N:1}` form has no dollar-immediately-followed-by-digit substring
# (the digit follows `:`), so the renderer leaves it verbatim and bash
# evaluates the slice at call time.
#
# R1-R3 scan every plugins/uberdev/skills/*/SKILL.md for the awk shape and
# fail CI when it finds a bare `$N` field ref inside a single-quoted awk
# script body. R4 scans orchestrator/SKILL.md for any bare `$N` anywhere
# (issue #225's stated scope); the broader bash-positional sweep across
# other pipeline SKILL.md files (7+ known sites in solve/goal/finish/
# testers/ubersimplify) is a documented follow-up (NOT enforced here).
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

# Bash-surface regex (#225). Bare `$N` anywhere in a bash script context —
# function body, command substitution, here-doc — gets substituted by the
# Skill renderer just as awk script bodies do. Used by R4 (scans
# orchestrator/SKILL.md) and the R5 inverse fixtures. SSOT'd here for the
# same reason GUARD_REGEX is SSOT'd above — if a future contributor narrows
# the pattern (e.g. `\$[1-9]` to skip `$0`), the inverse-fixture proofs
# (R5.bad / R5.safe) re-evaluate against the SAME pattern, not an
# independent literal that silently diverges.
BASH_GUARD_REGEX='\$[0-9]'

PASS=0; FAIL=0
echo "## skill-renderer collision drift guard (#222 awk + #225 bash)"

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

# Fixture setup — single trap install up front covers every mktemp. Bash
# supports ONE EXIT trap per shell; declaring ALL fixtures + ONE trap before
# any cat-into-fixture avoids the prior two-trap shape where the second
# silently superseded the first (Phase 2 simplify Quality + Efficiency
# convergence). When R6 / R7+ add their own fixture in a future iteration,
# add the mktemp here and the rm path to the single trap below — never
# install a second trap. Original simplify-lens convergence: see PR #224.
fixture_simple="$(mktemp)"
fixture_multi="$(mktemp)"
fixture_safe="$(mktemp)"
fixture_bash_bad="$(mktemp)"
fixture_bash_safe="$(mktemp)"
fixture_emit_topic_log_src="$(mktemp)"
r6_log_tmp="$(mktemp)"
trap 'rm -f "$fixture_simple" "$fixture_multi" "$fixture_safe" "$fixture_bash_bad" "$fixture_bash_safe" "$fixture_emit_topic_log_src" "$r6_log_tmp"' EXIT

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

# R4 — issue #225 follow-up: orchestrator/SKILL.md must contain NO bare `$N`
# anywhere (any surface, awk OR bash). The orchestrator skill is loaded by
# both /uberdev:orchestrator (interactive) and the chain-dispatch from
# /uberdev:solve / /uberdev:turbo, so every $N in its body is at risk.
# Scope is intentionally narrow to issue #225's stated surface; the broader
# bash-positional sweep across other pipeline SKILL.md files is documented
# in the header comment as a follow-up and NOT enforced here (would red CI
# on 7+ known sites in solve/goal/finish/testers/ubersimplify pipelines).
ORCH_SKILL="$SKILLS_DIR/orchestrator/SKILL.md"
if [ ! -r "$ORCH_SKILL" ]; then
  echo "  FAIL  R4 orchestrator/SKILL.md unreadable: $ORCH_SKILL"
  FAIL=$((FAIL+1))
elif grep -qE "$BASH_GUARD_REGEX" "$ORCH_SKILL"; then
  echo "  FAIL  R4 orchestrator/SKILL.md contains bare \$N positional refs:"
  grep -nE "$BASH_GUARD_REGEX" "$ORCH_SKILL" | sed 's/^/          /'
  echo "         Fix: replace bare \`\$N\` with \`\${@:N:1}\` in bash function bodies"
  echo "         (or \`-v cN=N\` + \`\$cN\` if inside an awk script body)."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R4 orchestrator/SKILL.md contains no bare \$N positional refs"
  PASS=$((PASS+1))
fi

# R5 — fixture proof for the bash surface, mirroring R2/R3 for the awk surface.
# Two sub-fixtures: (R5.bad) the naïve `local foo="$1"` shape MUST be detected
# by the R4 regex, and (R5.safe) the recommended `${@:1:1}` shape MUST NOT be
# detected. Same inside-out check as R2/R3 — if a future refactor narrows
# BASH_GUARD_REGEX (e.g. someone adds an awk-only anchor) and a new bash $N
# site slips through, R5.bad catches it; if the regex becomes over-broad and
# false-flags the safe form, R5.safe catches it. R5.bad and R5.safe BOTH
# re-evaluate against the same BASH_GUARD_REGEX SSOT — not an independent
# inline literal that could silently diverge from R4's regex.
# (Fixtures mktemp'd at the top with the other fixtures; single EXIT trap
# covers them all.)

cat > "$fixture_bash_bad" <<'EOF_BASH_BAD'
# naive bash positional refs — the renderer would corrupt these at load time.
# Uses BOTH the raw `$N` form (the #225 bug shape) AND the zsh-reserved `status`
# local-var name (the bug that surfaced in the /review-pr review of #225's
# initial fix). Both are intentional in this fixture: R5 regex-scans only,
# never executes the function, so the zsh-abort issue is irrelevant — and the
# diff against R5.safe (which uses `topic_status`) preserves the contrast.
# Do NOT "consistency-fix" this to `topic_status`; that would weaken the
# inverse proof.
emit_topic_log() {
  local topic="$1"
  local status="$2"
  local note="$3"
  echo "research-$topic $status $note"
}
EOF_BASH_BAD
if grep -qE "$BASH_GUARD_REGEX" "$fixture_bash_bad"; then
  echo "  PASS  R5.bad the bare-\$N regex flags a vulnerable bash function body"
  PASS=$((PASS+1))
else
  echo "  FAIL  R5.bad the bare-\$N regex no longer flags a vulnerable bash function body"
  echo "         The R4 check above will silently pass on regressed orchestrator/SKILL.md."
  FAIL=$((FAIL+1))
fi

cat > "$fixture_bash_safe" <<'EOF_BASH_SAFE'
# renderer-safe bash positional refs via array-slice — must NOT be flagged.
# Local-var name `topic_status` (not `status`) — `status` is read-only in zsh,
# and the Bash-tool default shell on macOS is /bin/zsh, so `local status=…`
# aborts the function. See orchestrator/SKILL.md emit_topic_log comment.
emit_topic_log() {
  local topic="${@:1:1}"
  local topic_status="${@:2:1}"
  local note="${@:3:1}"
  echo "research-$topic $topic_status $note"
}
EOF_BASH_SAFE
if grep -qE "$BASH_GUARD_REGEX" "$fixture_bash_safe"; then
  echo "  FAIL  R5.safe the bare-\$N regex false-positives on \`\${@:N:1}\` array-slice form"
  echo "         R4 will now red CI on the recommended fix shape."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R5.safe the bare-\$N regex does NOT false-positive on the safe \`\${@:N:1}\` shape"
  PASS=$((PASS+1))
fi

# R6 — behavioral execution test. The R4/R5 assertions above are static grep
# scans; they prove the regex correctly classifies syntactic forms but never
# RUN the fixed emit_topic_log to verify it actually works. The pre-#225-fix
# review missed a cross-shell regression (`local status="${@:2:1}"` aborts in
# zsh — `status` is read-only there). R6 sources the live function definition
# out of orchestrator/SKILL.md, calls it with known args, and asserts the
# emitted log line under BOTH /bin/bash AND /bin/zsh — the two shells the
# Skill tool may exec under across macOS / Linux / CI matrices. Without this,
# a future refactor that re-introduces a zsh-reserved local var name slides
# past R4 (file scans clean) AND R5 (fixtures pass) but breaks at runtime.
# (ORCH_SKILL set in R4 block above; reused here. Same shell scope, no
# intervening unset — re-declaring would be dead work and a stale "these
# blocks are independent" signal.)

# Extract the emit_topic_log() definition block from the rendered SKILL.md.
# `awk` slice from the function-open line to the matching `^}` close — same
# brace-counting idiom as awk-line-bounded parses elsewhere in the suite.
# Note on awk script: `${@:1:1}` etc. inside the awk body would be substituted
# by the Skill renderer when THIS test file is loaded as a skill, but tests/*
# is NEVER rendered as a skill — it's run directly via `bash tests/...sh` and
# `bash` has no Skill-renderer semantics, so the `${@:N:1}` in the matched
# function body survives verbatim into the sourced shell.
# (fixture_emit_topic_log_src + r6_log_tmp mktemp'd at the top; single EXIT
# trap covers them.)

awk '/^emit_topic_log\(\) \{/,/^\}/' "$ORCH_SKILL" > "$fixture_emit_topic_log_src"
if [ ! -s "$fixture_emit_topic_log_src" ]; then
  echo "  FAIL  R6 could not extract emit_topic_log() definition from $ORCH_SKILL"
  FAIL=$((FAIL+1))
else
  # Hoist the function-body read out of the per-shell loop — the file content
  # is invariant across iterations, so one cat instead of N.
  emit_topic_log_body="$(cat "$fixture_emit_topic_log_src")"
  # Run under both shells. The harness pipes a LOG file path + the function
  # body + a single call into the shell, then reads the log line back.
  # Single log fixture, truncated per iteration (`: > "$LOG"`) — matches the
  # "all fixtures + one trap" convention this file standardised post-#224.
  for shell_bin in /bin/bash /bin/zsh; do
    if [ ! -x "$shell_bin" ]; then
      echo "  PASS  R6.$(basename "$shell_bin") shell not available on this host (skipped, not failed)"
      PASS=$((PASS+1))
      continue
    fi
    : > "$r6_log_tmp"
    # Stderr deliberately NOT redirected — when R6 fails because a zsh-reserved
    # local var slips back in, the shell's "read-only variable: X" diagnostic
    # IS the smoking gun and surfaces directly in test output.
    "$shell_bin" -c "LOG=\"$r6_log_tmp\"; $emit_topic_log_body; emit_topic_log codebase reused 'cache-hit,mtime=1'"
    actual="$(cat "$r6_log_tmp" 2>/dev/null)"
    case "$actual" in
      *"phase=phase1-fanout agent=research-codebase status=reused note=cache-hit,mtime=1"*)
        echo "  PASS  R6.$(basename "$shell_bin") emit_topic_log emits the expected log line"
        PASS=$((PASS+1))
        ;;
      *)
        echo "  FAIL  R6.$(basename "$shell_bin") emit_topic_log produced unexpected output:"
        echo "          actual: $actual"
        echo "          expected substring: 'agent=research-codebase status=reused note=cache-hit,mtime=1'"
        echo "         Hint: zsh aborts \`local status=…\` (read-only special parameter) — rename the local."
        FAIL=$((FAIL+1))
        ;;
    esac
  done
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
