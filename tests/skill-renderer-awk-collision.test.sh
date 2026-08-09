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
# script body.
#
# R4 was issue #225's narrow scan of orchestrator/SKILL.md alone. Issue #404
# proved that narrowness was the bug: 64 live sites across 9 other templated
# files, one of them fatal (`/uberdev:review-pr` could not start with a
# non-empty argument — `local repository_root="$1"` rendered as
# `local repository_root="--no-simplify"` and the third executable step of
# setup died). R4 now scans the ENTIRE templated corpus — every
# `plugins/uberdev/skills/**/SKILL.md` plus every `plugins/uberdev/commands/*.md`,
# which is exactly R1's corpus unioned with R1b's.
#
# WHAT DELIBERATELY STAYS OUT, and why an unstated limit is worse than a
# stated one: `plugins/uberdev/agents/*.md` (agents receive a task prompt, never
# positional slash args), non-`SKILL.md` files under `skills/`,
# `plugins/uberdev/lib/**/*.sh`, `skills/*/lib/*.sh`,
# `skills/brainstorm/scripts/*.sh` and `tests/**`. None of those is ever passed
# through the renderer, so their ~42 bare positionals are correct as written —
# `lib/child-dispatch.sh` alone has 26 and works. Widening to them would red CI
# on correct code and teach contributors to distrust this guard.
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

# Bash-surface regex (#225, widened by #404). A positional ref anywhere in a
# bash script context — function body, command substitution, here-doc — gets
# substituted by the Skill renderer just as awk script bodies do. Used by R4
# (scans the whole templated corpus) and the R5/R5b inverse fixtures. SSOT'd
# here for the same reason GUARD_REGEX is SSOT'd above — if a future
# contributor narrows the pattern (e.g. `\$[1-9]` to skip `$0`), the
# inverse-fixture proofs re-evaluate against the SAME pattern, not an
# independent literal that silently diverges.
#
# Why the optional `{` (#404). Braces do NOT protect a positional: the renderer
# replaces `${N}` when positional N exists and merely brace-strips it to `$N`
# when it does not, so `$1` -> `${1}` changes the spelling and nothing else.
# `\$\{?[0-9]` catches both spellings in one pass and still spares the fix:
# on `${@:1:1}` the optional `{` matches and `[0-9]` must then match `@`
# (fail); with the `{` left unmatched, `[0-9]` must match `{` (fail). R5b.safe
# pins that both ways round.
BASH_GUARD_REGEX='\$\{?[0-9]'

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
  if grep -qE "$GUARD_REGEX" <<<"$flattened"; then
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

# R1b — issue #237 audit: command files (plugins/uberdev/commands/*.md) are
# slash-arg-substituted by the Skill loader exactly like SKILL.md, so an awk
# script body with a bare `$N` inside an EXECUTED block is the same #222 bug
# class. The concrete prior site WAS review-pr.md's conflict-file extraction,
# `awk '/^UU / {print $2}'`, where `$2` is clobbered by the PR-number argv;
# #398 retired that line entirely (the conflict set now comes from
# `code_fixer_contract.py list-ci-unmerged-paths`, no awk at all), so the
# fixtures below are built on a different, still-plausible command-file awk
# site. They exist to prove the `$N` vs `-v cN=N` distinction, not to bless any
# particular line.
# agents/*.md are intentionally NOT scanned: agent system prompts receive a
# task prompt, never positional slash args, so their `awk '{print $1}'` field
# refs are legitimate and would false-positive here.
COMMANDS_DIR="$REPO_ROOT/plugins/uberdev/commands"
cmd_hits=""
if [ -d "$COMMANDS_DIR" ]; then
  while IFS= read -r -d '' cmd_file; do
    flattened="$(tr '\n' ' ' < "$cmd_file")"
    if grep -qE "$GUARD_REGEX" <<<"$flattened"; then
      cmd_hits="$cmd_hits$cmd_file"$'\n'
    fi
  done < <(find "$COMMANDS_DIR" -name "*.md" -print0)
fi
if [ -z "$cmd_hits" ]; then
  echo "  PASS  R1b no plugins/uberdev/commands/*.md awk script body contains a bare \$N field ref"
  PASS=$((PASS+1))
else
  echo "  FAIL  R1b these command files use bare \$N field refs vulnerable to the renderer:"
  printf '          %s\n' "$cmd_hits" | sed 's/^/  /'
  echo "         Fix: add \`-v cN=N\` to the awk invocation and use \`\$cN\` in place of \`\$N\`."
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
fixture_cmd_bad="$(mktemp)"
fixture_cmd_safe="$(mktemp)"
fixture_bash_braced_bad="$(mktemp)"
fixture_bash_braced_safe="$(mktemp)"
trap 'rm -f "$fixture_simple" "$fixture_multi" "$fixture_safe" "$fixture_bash_bad" "$fixture_bash_safe" "$fixture_emit_topic_log_src" "$r6_log_tmp" "$fixture_cmd_bad" "$fixture_cmd_safe" "$fixture_bash_braced_bad" "$fixture_bash_braced_safe"' EXIT

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
if grep -qE "$GUARD_REGEX" <<<"$multi_flat"; then
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

# R1b.fixture — inverse proof for the R1b command-surface scan (mirrors R2/R3
# for the SKILL surface). The live R1b above reuses GUARD_REGEX (proven by
# R2/R3) but its find+flatten loop over commands/*.md is otherwise unexercised;
# these two fixtures prove the command-surface scan path flags the vulnerable
# shape and spares the safe parameterised form. Closes the R1b coverage gap
# (#266 review — pr-test-analyzer).
cat > "$fixture_cmd_bad" <<'EOF_CMD_BAD'
# fake command-file awk site — R1b's scan MUST flag this
FAILING_CHECKS="$(gh pr checks "$PR_NUMBER" | awk '/fail/ {print $1}')"
EOF_CMD_BAD
cmd_bad_flat="$(tr '\n' ' ' < "$fixture_cmd_bad")"
if grep -qE "$GUARD_REGEX" <<<"$cmd_bad_flat"; then
  echo "  PASS  R1b.bad the command-surface scan flags a vulnerable awk shape in a command file"
  PASS=$((PASS+1))
else
  echo "  FAIL  R1b.bad the command-surface scan no longer flags a vulnerable awk shape"
  echo "         R1b will silently pass on a regressed commands/*.md."
  FAIL=$((FAIL+1))
fi
cat > "$fixture_cmd_safe" <<'EOF_CMD_SAFE'
# renderer-safe parameterised command-file awk — R1b's scan must NOT flag this
FAILING_CHECKS="$(gh pr checks "$PR_NUMBER" | awk -v c1=1 '/fail/ {print $c1}')"
EOF_CMD_SAFE
cmd_safe_flat="$(tr '\n' ' ' < "$fixture_cmd_safe")"
if grep -qE "$GUARD_REGEX" <<<"$cmd_safe_flat"; then
  echo "  FAIL  R1b.safe the command-surface scan false-positives on the parameterised \`-v c2=2\` + \$c2 shape"
  echo "         R1b will red CI on the recommended command-file fix."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R1b.safe the command-surface scan does NOT false-positive on the safe parameterised shape"
  PASS=$((PASS+1))
fi

# R4 — issue #225, widened by issue #404. NO templated markdown file may
# contain a renderer-substitutable positional ref anywhere in its body, on any
# surface (awk OR bash), in either spelling (`$N` or `${N}`). Corpus is R1's
# unioned with R1b's — see the header comment for what deliberately stays out.
#
# Every file here is rendered by the Skill loader before the model or the shell
# ever sees it, so a positional token in the SOURCE is not a positional at
# RUNTIME: it is whatever the caller's Nth argument happened to be. Escaping
# cannot fix it (`${N}` is substituted too), which is why the guard is a
# spelling ratchet and not a lint suggestion.
#
# ORCH_SKILL is still resolved here — R6 below sources the live emit_topic_log
# out of it.
ORCH_SKILL="$SKILLS_DIR/orchestrator/SKILL.md"
bash_corpus_files=""
bash_corpus_hits=""
while IFS= read -r -d '' corpus_file; do
  bash_corpus_files="$bash_corpus_files${corpus_file#"$REPO_ROOT"/}"$'\n'
  corpus_hit="$(grep -nE "$BASH_GUARD_REGEX" "$corpus_file" || true)"
  [ -n "$corpus_hit" ] || continue
  while IFS= read -r corpus_line; do
    [ -n "$corpus_line" ] || continue
    bash_corpus_hits="$bash_corpus_hits${corpus_file#"$REPO_ROOT"/}:$corpus_line"$'\n'
  done <<EOF_CORPUS_HIT
$corpus_hit
EOF_CORPUS_HIT
done < <(find "$SKILLS_DIR" -name "SKILL.md" -print0; find "$COMMANDS_DIR" -name "*.md" -print0)

if [ -z "$bash_corpus_hits" ]; then
  echo "  PASS  R4 no templated SKILL.md / command file contains a renderer-substitutable positional ref"
  PASS=$((PASS+1))
else
  echo "  FAIL  R4 these templated files contain renderer-substitutable positional refs:"
  printf '%s' "$bash_corpus_hits" | sed 's/^/          /'
  echo "         Fix: replace \`\$N\` / \`\${N}\` with \`\${@:N:1}\` in bash function bodies"
  echo "         (or \`-v cN=N\` + \`\$cN\` if inside an awk script body). Braces alone do"
  echo "         NOT help — the renderer substitutes \`\${N}\` too (issue #404)."
  FAIL=$((FAIL+1))
fi

# R4.corpus — anti-vacuity. A `find` that silently matches nothing (renamed
# directory, wrong -name pattern, unreadable path) would make R4 above pass on
# an empty corpus and report a green ratchet over zero files. Assert the corpus
# is non-empty AND still contains the two files #404 measured as the worst
# offenders (30 and 11 sites respectively).
#
# orchestrator/SKILL.md is required readable in the same row: R4's predecessor
# checked that directly and R6 below still depends on it — an unreadable file
# makes R6's slice empty, which R6 reports as the legitimate post-#308
# "function retired" PASS rather than as a broken corpus.
r4_corpus_missing=""
for corpus_expected in \
  plugins/uberdev/commands/review-pr.md \
  plugins/uberdev/skills/post-impl-review/SKILL.md; do
  case $'\n'"$bash_corpus_files" in
    *$'\n'"$corpus_expected"$'\n'*) ;;
    *) r4_corpus_missing="$r4_corpus_missing $corpus_expected" ;;
  esac
done
[ -r "$ORCH_SKILL" ] || r4_corpus_missing="$r4_corpus_missing $ORCH_SKILL(unreadable)"
if [ -n "$bash_corpus_files" ] && [ -z "$r4_corpus_missing" ]; then
  echo "  PASS  R4.corpus the scanned corpus is non-empty and includes the known high-density files"
  PASS=$((PASS+1))
else
  echo "  FAIL  R4.corpus the scanned corpus is empty or lost a known file:$r4_corpus_missing"
  echo "         R4 above would report PASS over a corpus it never actually read."
  FAIL=$((FAIL+1))
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
# inverse proof. The trailing marker is what buys that exemption from the
# repo-wide tied-parameter scan in tests/crossplatform-shell-wrappers.test.sh,
# which reads tests/ as of the corpus widening — a per-line marker rather than a
# path exclusion, so the other four hundred lines of this file stay scanned.
emit_topic_log() {
  local topic="$1"
  local status="$2"  # zsh-tied-fixture: the deliberate half of the bad/safe pair
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

# R5b — issue #404's half of the inverse proof: the BRACED spelling. The #404
# author first "fixed" the corruption by rewriting `$N` -> `${N}`, reasoning
# that `${2:-}` and `${10}` had survived a live render. They had survived only
# because those positionals did not exist. The verified rule is:
#   `${N}` where positional N EXISTS       -> replaced by the argument
#   `${N}` where N has NO argument         -> brace-stripped to `$N` (harmless)
# So braces change the spelling, not the outcome, and a guard that only knew
# `\$[0-9]` would have certified that non-fix as clean. R5b.bad pins that the
# widened regex catches the braced spelling with NO bare form present at all,
# and R5b.safe pins that widening did not swallow the recommended fix — the
# braced-but-safe `${@:N:1}` and ordinary `${VAR:-default}` expansions.
#
# Neither fixture declares a zsh-tied local (`status`, `path`, `dir`, `argv`, …):
# the marked-line inventory in tests/crossplatform-shell-wrappers.test.sh is
# pinned per file, and this file's allowance is exactly one line (R5.bad's).
cat > "$fixture_bash_braced_bad" <<'EOF_BRACED_BAD'
# braced positional refs, no bare `$N` anywhere — the renderer rewrites these
# exactly as it rewrites the bare form, so the guard MUST flag them.
emit_topic_log() {
  local topic="${1}"
  local topic_status="${2}"
  local note="${10}"
  echo "research-$topic $topic_status $note"
}
EOF_BRACED_BAD
if grep -qE "$BASH_GUARD_REGEX" "$fixture_bash_braced_bad"; then
  echo "  PASS  R5b.bad the widened regex flags the braced \`\${N}\` spelling"
  PASS=$((PASS+1))
else
  echo "  FAIL  R5b.bad the widened regex misses the braced \`\${N}\` spelling"
  echo "         A \`\$N\` -> \`\${N}\` non-fix would pass R4 while staying corrupted (#404)."
  FAIL=$((FAIL+1))
fi

cat > "$fixture_bash_braced_safe" <<'EOF_BRACED_SAFE'
# renderer-safe forms that a naively-widened regex would false-positive on:
# the array-slice fix (including a two-digit index) and ordinary parameter
# expansions whose default value happens to be numeric.
emit_topic_log() {
  local topic="${@:1:1}"
  local topic_status="${@:2:1}"
  local note="${@:10:1}"
  local timeout_s="${TIMEOUT:-300}"
  local extra="${VAR:-}"
  echo "research-$topic $topic_status $note $timeout_s $extra"
}
EOF_BRACED_SAFE
if grep -qE "$BASH_GUARD_REGEX" "$fixture_bash_braced_safe"; then
  echo "  FAIL  R5b.safe the widened regex false-positives on \`\${@:N:1}\` or \`\${VAR:-N}\`"
  echo "         R4 would now red CI on the recommended fix and on ordinary defaults."
  FAIL=$((FAIL+1))
else
  echo "  PASS  R5b.safe the widened regex spares \`\${@:N:1}\` and \`\${VAR:-default}\`"
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
  # emit_topic_log() was part of the Phase-1 research-cache freshness predicate,
  # which RFC 0012 §3.5 / #308 DELETED from orchestrator/SKILL.md after a live
  # grep proved the cache had zero writers. With the function gone there is no
  # live subject to runtime-check — that is the correct post-deletion state, not
  # a regression. R6's behavioral check below still runs (and guards the
  # zsh-reserved-local hazard) whenever the function IS present; the static R4
  # bare-$N scan over the whole SKILL.md remains in force regardless. The R5.bad
  # / R5.safe inline fixtures preserve the classifier proof independently of this
  # function's existence.
  echo "  PASS  R6 emit_topic_log() absent from $ORCH_SKILL (retired with the #308 research-cache deletion; nothing to runtime-check)"
  PASS=$((PASS+1))
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
