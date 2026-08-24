#!/usr/bin/env bash
# Guard against the documentation-drift class fixed in issue #273:
#   1. plugins/uberdev/docs/testing.md must describe the REAL harness
#      (tests/*.test.sh shape-checks + the test.yml CI job layout; marketplace key
#      uberdev@uberdev) — not verbatim upstream Superpowers (tests/claude-code/,
#      test-helpers.sh, analyze-token-usage.py, run-skill-tests.sh,
#      superpowers@superpowers-dev, "run FROM the superpowers directory").
#   2. CONTRIBUTING.md must not carry the dead [Repo layout](README.md#repo-layout)
#      link (README has no such anchor) nor the false "no behavioral tests" claim,
#      and must point at .github/workflows/test.yml as the test-set SSOT.
#   3. docs/rfc/ must have NO duplicate RFC numbers (the 0004 collision: the
#      alias RFC was renumbered to 0011; the dispatch RFC keeps 0004).
#   4. The dispatch RFC (0004) §4/§5 version refs must agree with its Status
#      line + the CHANGELOG: target v0.30.0, not v0.29.0.
#   5. The alias-RFC cross-refs in hooks/session-start + lib/aliases-sync.sh must
#      point at RFC 0011, and no stale 0004-alias-install path ref may survive.
#   6. (#349) RFC prose must not anchor on `file:line` literals, and every
#      symbol it DOES cite must still resolve in the shipped tree. The prior
#      edition of RFC 0012's §3.3 contract table anchored on line numbers and
#      rotted silently inside one release — its "audit-JSON write" anchor came
#      to point at sequential fanout-cap prose, its locked-marker anchor at a
#      Python heredoc, and its trust-reader anchor at the audit EMITTER rather
#      than the reader. Section T9 below makes both halves enforceable: no
#      `*.md:N` / `*.sh:N` literal inside §1 or the contract table, and every
#      named symbol grep-resolves in plugins/uberdev/.
#   7. (#435) `--auto` is a permission BYPASS, and since RFC 0015 §5 the default
#      `workflow` backend does not scope it to the per-issue solvers at all.
#      Section T11 below pins both halves: every line documenting the flag must
#      carry a danger token, the flag PAIR must be named wherever the semantics
#      are described, no doc may repeat the now-false "on the spawned agent"
#      claim, and no doc may sell it as "max autonomy".
#
# These are structural greps over the shipped docs/shell files — they exercise
# the source bytes, not a running session. Every assertion below FAILS on the
# pre-#273 tree and PASSES after the fix.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTING_MD="$REPO_ROOT/plugins/uberdev/docs/testing.md"
CONTRIBUTING_MD="$REPO_ROOT/CONTRIBUTING.md"
RFC_DIR="$REPO_ROOT/docs/rfc"
DISPATCH_RFC="$RFC_DIR/0004-cross-platform-dispatch-backends.md"
ALIAS_RFC="$RFC_DIR/0011-alias-install-reliability.md"
# #432: the reviewer-precision eval RFC. 0018 is reserved for it by the issue,
# and T3.4 below locks the header so a renumber cannot drift from the filename.
PRECISION_RFC="$RFC_DIR/0018-review-precision-eval.md"
# #467: the miner the precision RFC describes. T13 below pairs every absence row
# with a positive one, and the last of them resolves an RFC symbol against this
# file — an RFC that names a field the shipped tool does not have is the same
# drift class as one that describes a rule the tool never implemented.
PRECISION_MINER="$REPO_ROOT/tools/eval/review-precision.py"
SESSION_START="$REPO_ROOT/plugins/uberdev/hooks/session-start"
ALIASES_SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
TEST_YML="$REPO_ROOT/.github/workflows/test.yml"
# Hook-diet surfaces (#309 / RFC 0012 §7.7): the session-start injection is
# using-uberdev/SKILL.md (primer only); the config schema lives in the sibling
# references/configuration.md.
USING_SKILL="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/SKILL.md"
CONFIG_REF="$REPO_ROOT/plugins/uberdev/skills/using-uberdev/references/configuration.md"
# #349 anchor-rot surfaces: the two RFCs whose prose is consumed as a live
# contract checklist (RFC 0012 §3.3 is the /goal + /review-pr + /merge
# acceptance table; RFC 0005 §9.5 defines the behaviours it locks).
WORKFLOW_RFC="$RFC_DIR/0012-ultracode-workflow-orchestration.md"
GOAL_RFC="$RFC_DIR/0005-uberdev-goal.md"
# #434 vendored-provenance surface: RFC 0019 is the written policy behind
# plugins/uberdev/vendor.json and tools/vendor/. It is listed here so a rename
# or an accidental renumber is an explicit FATAL, not a silent skip.
VENDOR_RFC="$RFC_DIR/0019-vendored-upstream-policy.md"
PLUGIN_DIR="$REPO_ROOT/plugins/uberdev"
HOOKS_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks.json"
HOOKS_CURSOR_JSON="$REPO_ROOT/plugins/uberdev/hooks/hooks-cursor.json"
PRE_COMPACT="$REPO_ROOT/plugins/uberdev/hooks/pre-compact"
# #472 version-bump-contract surfaces. CLAUDE.md is the rule document the
# convention lens quotes verbatim AND the only one a worktree solver can read
# (the project CLAUDE.md twin is gitignored — .gitignore). The other three are
# the machinery that decides which commit actually carries the bump, so T12
# below locks the doc and the machinery against EACH OTHER rather than pinning
# either alone.
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
SOLVE_FLEET_JS="$PLUGIN_DIR/skills/solve-fleet/workflow.js"
# #507 design-chain surfaces. The fleet script is the machinery; its SKILL.md
# and RFC 0015 both restate the chain AND the CB1 projection as prose, so T14
# below locks the three against each other rather than pinning any one alone.
SOLVE_FLEET_SKILL="$PLUGIN_DIR/skills/solve-fleet/SKILL.md"
DISPATCH15_RFC="$RFC_DIR/0015-workflow-native-dispatch.md"
# #554 partial-linkage surface. The non-closing `UberDev-Partial: #N` trailer is
# one contract living in three files — the producer (the fleet's delivery
# prompt), the fleet's own return-value declaration, and the ONLY consumer that
# acts on it (/merge Step 3.4). T16.10 below joins them; the consumer is listed
# here so a rename is an explicit FATAL rather than a silently-skipped row.
MERGE_PIPELINE_SKILL="$PLUGIN_DIR/skills/merge-pipeline/SKILL.md"
GOAL_WATCH_SH="$PLUGIN_DIR/lib/goal-watch.sh"
BUMP_VERSION_SH="$PLUGIN_DIR/lib/bump-version.sh"
STRUCTURAL_LIB="$REPO_ROOT/tests/_lib_assert_structural.sh"
# #518 schema-drift surfaces. run_manifest.py's ALLOWED_FIELDS says of itself
# that it is "RFC 0013 section 13 fields plus the minimal process metadata" —
# and nothing compared the two lists, which is how `cache_hit` sat in the schema
# with zero producers for a full release cycle. T15 below compares them in BOTH
# directions, so neither a field the RFC promises nor a field only the code
# knows about can appear without showing up as a diff.
ADAPTIVE_RFC="$RFC_DIR/0013-gpt-5-6-adaptive-execution.md"
RUN_MANIFEST_PY="$PLUGIN_DIR/lib/run_manifest.py"

# #606 citation-rot surfaces. skills/review-fleet/workflow.js carries the seam
# rationale — why each stage boundary exists, and which two RFC 0012 §3.1
# proposals the implementation rejects — and skills/review-fleet/SKILL.md
# carries the same argument for a reader who never opens the script. ONE
# argument, TWO copies, and both were written in file offsets. T18 below lints
# both for offsets and compares the claims they share. The four files after
# them are the ones those copies CITE: they are named here so that a rename is
# an explicit FATAL rather than a row that quietly stops resolving anything.
REVIEW_FLEET_JS="$PLUGIN_DIR/skills/review-fleet/workflow.js"
REVIEW_FLEET_SKILL="$PLUGIN_DIR/skills/review-fleet/SKILL.md"
POST_IMPL_SKILL="$PLUGIN_DIR/skills/post-impl-review/SKILL.md"
REVIEW_AGGREGATE_SH="$PLUGIN_DIR/lib/review-aggregate.sh"
REVIEW_FENCES_SH="$PLUGIN_DIR/lib/review-fences.sh"
SIMPLIFY_CMD="$PLUGIN_DIR/commands/simplify.md"

# This file, read as data: row T6.5b slices its own size-ratchet region to keep
# the measurement platform-invariant (#522).
DOCS_ACCURACY_SELF="$REPO_ROOT/tests/docs-accuracy.test.sh"

# Hard-fail (exit 2) on a missing input — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$TESTING_MD" "$CONTRIBUTING_MD" "$DISPATCH_RFC" "$ALIAS_RFC" \
         "$SESSION_START" "$ALIASES_SYNC" "$TEST_YML" \
         "$USING_SKILL" "$CONFIG_REF" "$HOOKS_JSON" "$HOOKS_CURSOR_JSON" \
         "$PRE_COMPACT" "$WORKFLOW_RFC" "$GOAL_RFC" "$VENDOR_RFC" \
         "$PRECISION_RFC" "$PRECISION_MINER" "$CLAUDE_MD" "$SOLVE_FLEET_JS" \
         "$SOLVE_FLEET_SKILL" "$DISPATCH15_RFC" "$MERGE_PIPELINE_SKILL" \
         "$GOAL_WATCH_SH" "$BUMP_VERSION_SH" "$STRUCTURAL_LIB" \
         "$ADAPTIVE_RFC" "$RUN_MANIFEST_PY" "$DOCS_ACCURACY_SELF" \
         "$REVIEW_FLEET_JS" "$REVIEW_FLEET_SKILL" "$POST_IMPL_SKILL" \
         "$REVIEW_AGGREGATE_SH" "$REVIEW_FENCES_SH" "$SIMPLIFY_CMD"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

# Shared structural-assertion helpers (assert_in_section + assert_count for T12
# — the version rule is sliced to its own section so a stray prose match
# elsewhere in CLAUDE.md cannot false-positive it; see the T12 block for what
# that scoping does and does NOT buy while CLAUDE.md carries a single level-2
# section). Fail-loud guard per #209: a missing or unreadable helper aborts
# rc=2, never vacuous-green.
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }
# The guard above only catches a helper file that is MISSING or unparseable:
# `source` reports the status of the last command in the sourced file, so a
# helper that was renamed, moved or split out still sources rc=0. Every call to
# it would then fail with command-not-found (rc 127), which increments neither
# counter — and with no errexit and no assertion floor this file would print
# `failed: 0` and exit 0 with its structural half never executed. Assert the
# names actually called here, and extend this list when a new one is used.
for structural_fn in assert_in_section assert_count checkout_worst_case_bytes; do
  command -v "$structural_fn" >/dev/null 2>&1 || {
    echo "FATAL: _lib_assert_structural.sh sourced but $structural_fn is not defined (renamed helper?)" >&2
    exit 2
  }
done

PASS=0
FAIL=0

# Assert a regex IS present in a file.
assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# Assert a fixed string is ABSENT from a file (grep -F: literal, no regex).
assert_absent_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        unexpected literal: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

# Slice one `# === BEGIN <title> ===` … `# === END <title> ===` region out of
# THIS file, markers included. Same shape as T6.5b's inline awk further down,
# with three differences that are load-bearing:
#   * awk is handed the PATH, never a `tr -d '\r' |` pipe. awk exits at the
#     first END marker, so a writer upstream of it would die on EPIPE and
#     poison `pipefail` (tests/epipe-guard.test.sh). The CR strip therefore
#     happens INSIDE awk, which the windows shape-check job needs because it
#     checks out with core.autocrlf=true and grep cannot see a CR.
#   * `index($0, …) == 1` is a literal starts-with. The title is data, and the
#     obvious `$0 ~ "^# === BEGIN " t` would silently reinterpret a `.` or a
#     `[` in it as a metacharacter — the T6.5b sibling escapes its `.` by hand
#     precisely because its pattern IS a regex, and a parameterised copy of
#     that shape is one un-escaped title away from matching the wrong line.
#   * The markers are matched only at column 1, so a backtick-quoted MENTION of
#     a marker inside a FAIL message or a comment cannot move where a slice
#     starts — the failure mode measured while writing the T6.5b sibling.
# No `command -v` guard is needed here: every caller feeds the slice to a
# non-vacuity row that reds on an empty body, so a renamed helper (rc 127,
# empty capture) surfaces as a loud FAIL rather than a silent pass.
da_marked_region() {   # <marker title>
  awk -v t="$1" '
    { sub(/\r$/, "") }
    index($0, "# === BEGIN " t " ===") == 1 { a = 1 }
    a { print }
    a && index($0, "# === END " t " ===") == 1 { exit }
  ' "$DOCS_ACCURACY_SELF"
}

# Shared arm for the marker-region non-vacuity rows. Both halves are mandatory:
# a floor alone passes on a slice that ran to EOF because its END marker was
# deleted, and that runaway slice would swallow the very rows that lint it.
da_assert_region_intact() {   # <row-id> <title> <min-lines> <body>
  local id="$1" title="$2" floor="$3" body="$4" lines last
  lines="$(grep -c . <<<"$body" || true)"
  last="$(tail -n 1 <<<"$body")"
  if [ "${lines:-0}" -lt "$floor" ] 2>/dev/null; then
    echo "  FAIL  $id the '$title' region is missing or truncated (${lines:-0} lines, floor $floor)"
    echo "        file: $DOCS_ACCURACY_SELF"
    echo "        an absent region satisfies every absence row below vacuously (#347)"
    FAIL=$((FAIL + 1))
  elif [ "$last" != "# === END $title ===" ]; then
    echo "  FAIL  $id the '$title' slice ran PAST its closing marker"
    echo "        last line: $last"
    echo "        a deleted END marker makes the slice run to EOF and swallow the rows that lint it"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $id the '$title' region is intact (${lines} lines, closed by its own END marker)"
    PASS=$((PASS + 1))
  fi
}

# The same slicing job for a file that carries no `=== BEGIN/END ===` markers of
# its own (#606). A shipped SKILL.md or workflow.js must not grow test-only
# markers, so these two anchor on prose the file already ships: a literal the
# section opens with, and either a literal it closes with or the SHAPE of the
# next section's first line. awk is handed the PATH for the same two reasons
# `da_marked_region` is — no writer to kill with EPIPE when awk exits early
# (tests/epipe-guard.test.sh), and the CR strip has to happen inside awk because
# the windows shape-check job checks out with core.autocrlf=true and grep cannot
# see a CR. `index()` is a literal starts-anywhere search, so a `.` or a `[` in
# an anchor stays a `.` or a `[`.
#
# The body-BUILDING helpers here need no `command -v` guard: a renamed builder is
# rc 127 and an empty capture, and every caller feeds the result to a row that
# reds on an empty body — the non-vacuity rows for the slicers, and every
# multi-word needle for the unwrapper. Row-EMITTERS do need one, because a
# renamed emitter prints no row at all: there is nothing left to red, only a
# total that quietly got smaller. That guard sits further down and derives the
# set it vets from this file's own `da_assert_` call sites, so it reaches every
# emitter wherever defined — including any defined above this paragraph.
da_slice_between() {   # <file> <start-literal> <end-literal>
  awk -v s="$2" -v e="$3" '
    { sub(/\r$/, "") }
    !a && index($0, s) { a = 1; print; next }
    a { print; if (index($0, e)) exit }
  ' "$1"
}

# From <start-literal> to the last line before the first line matching <end-ere>.
# The end is EXCLUSIVE and is a shape, not a literal, because a markdown section
# ends where the next one begins and nothing in the closing line says so.
da_slice_until_re() {   # <file> <start-literal> <end-ere>
  awk -v s="$2" -v e="$3" '
    { sub(/\r$/, "") }
    !a && index($0, s) { a = 1; print; next }
    a && $0 ~ e { exit }
    a { print }
  ' "$1"
}

# One body, UNWRAPPED: every line loses its leading comment marker (`#` or `//`)
# together with all whitespace on either side of it, and the lines rejoin on
# exactly one space. Prose wraps wherever the writer's re-flow puts the break, so
# a quoted span can straddle two source lines — and a break carries cosmetic
# whitespace on BOTH sides, whatever indentation the continuation is written
# with and whatever trailing space the line before it ends on. Read raw, such a
# span is a token carrying a newline; unwrapped without normalising both sides it
# is a token carrying a run of spaces. Neither resolves anywhere, so a purely
# cosmetic re-wrap would red a multi-word row with FAIL text naming a fault that
# did not happen — a guard whose predicate is disjoint from the drift it must
# find, which is the defect this suite's #606 rows exist to retire.
#
# DECLARED BOUNDARY, not an oversight: a break normalises to ONE space, which is
# the one thing about the writer's wrap this cannot preserve. A needle whose
# source carries two consecutive spaces exactly where the prose wraps is
# therefore not quotable across that break — wrap it elsewhere. Every FAIL arm
# prints the unresolved needle, so the case is diagnosable rather than
# mysterious.
#
# Single-token needles — a file offset, a numeral, a spelled cardinal — are read
# against the RAW body instead, deliberately: no line break can split them, and
# the raw body keeps each match on a source line a reader can go open.
da_unwrap_prose() {   # <body>
  sed -e 's,^[[:space:]]*//,,' -e 's/^[[:space:]]*#//' -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//' <<<"$1" | tr '\n' ' '
}

# Non-vacuity for a prose-anchored slice, bounded in BOTH directions. The floor
# catches a start anchor that no longer matches (short or empty slice, which
# would satisfy every absence row below vacuously). The ceiling catches the
# opposite failure: an end anchor that no longer matches lets the slice run to
# EOF, and a slice that swallows the whole file both hides what it was supposed
# to lint and buries the FAIL output of the rows that read it.
#
# The ceiling carries deliberate headroom — it is a RUNAWAY detector, not a size
# ratchet. A runaway is off by hundreds of lines, so a ceiling at roughly twice
# the live size separates the two cases without reding a section that grew a
# paragraph. Measured on a renamed end anchor: the slice went from its own
# length to the whole rest of the file.
#
# The two ends are not equally exposed, and the difference is worth knowing
# before trusting this arm. A LITERAL end anchor is one rename away from
# vanishing, which is the case above. A SHAPE end anchor — the next heading or
# the next horizontal rule — is satisfied by whatever section follows, so
# renaming that heading just moves the boundary rather than losing it, and the
# ceiling only fires if the shape disappears from the entire rest of the file.
# For those slices the FLOOR is the arm that catches the realistic failure, and
# it does: measured, renaming either markdown heading yields a zero-line slice.
da_assert_slice_intact() {   # <row-id> <label> <floor> <ceiling> <body> <start-anchor> <end-anchor>
  local id="$1" label="$2" floor="$3" ceil="$4" body="$5" start="$6" endp="$7" lines
  lines="$(grep -c . <<<"$body" || true)"
  if [ "${lines:-0}" -lt "$floor" ] 2>/dev/null; then
    echo "  FAIL  $id the '$label' slice is missing or truncated (${lines:-0} lines, floor $floor)"
    echo "        start anchor: $start"
    echo "        an anchor that no longer matches yields a short slice, and a short slice satisfies every absence row below vacuously (#347)"
    FAIL=$((FAIL + 1))
  elif [ "${lines:-0}" -gt "$ceil" ] 2>/dev/null; then
    echo "  FAIL  $id the '$label' slice ran PAST its end anchor (${lines} lines, runaway ceiling $ceil)"
    echo "        end anchor: $endp"
    echo "        a lost end anchor makes the slice run to EOF and swallow the rest of the file"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $id the '$label' slice is intact (${lines} lines, between its own prose anchors)"
    PASS=$((PASS + 1))
  fi
}

# One row per (symbol, file) pair: does the replacement anchor a de-lined
# citation now names actually resolve, CONTIGUOUSLY, in the file it points at?
# `grep -F` and not `grep -E`, because these needles carry `(` and `-` and a
# regex reading of `post_review_write_aggregate_v2()` matches the bare name with
# an empty group — i.e. it would pass on exactly the rename this row exists to
# catch.
da_assert_symbol_resolves() {   # <row-id> <file> <needle> <what-it-supports>
  local id="$1" file="$2" needle="$3" why="$4"
  # Repo-relative, not a basename: two of the files these rows read are called
  # SKILL.md, and "resolves in SKILL.md" names neither of them.
  if grep -qF -e "$needle" "$file"; then
    echo "  PASS  $id $needle resolves in ${file#$REPO_ROOT/} ($why)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $id $needle no longer resolves in $file"
    echo "        it is cited as $why"
    echo "        a symbol that does not resolve is a line number with extra steps — re-read the file, then re-word both review-fleet copies in the SAME change"
    FAIL=$((FAIL + 1))
  fi
}

echo "== testing.md describes the REAL harness, not vendored Superpowers =="
# Vendored-upstream tokens that must NOT survive (the whole pre-#273 file).
assert_absent_fixed "$TESTING_MD" "tests/claude-code/"        "T1.1 testing.md drops the upstream tests/claude-code/ path"
assert_absent_fixed "$TESTING_MD" "test-helpers.sh"           "T1.2 testing.md drops upstream test-helpers.sh"
assert_absent_fixed "$TESTING_MD" "analyze-token-usage.py"    "T1.3 testing.md drops upstream analyze-token-usage.py"
assert_absent_fixed "$TESTING_MD" "run-skill-tests.sh"        "T1.4 testing.md drops upstream run-skill-tests.sh"
assert_absent_fixed "$TESTING_MD" "superpowers@superpowers-dev" "T1.5 testing.md drops upstream superpowers@superpowers-dev marketplace key"
# Case-insensitive: kill any 'superpowers directory' instruction in any casing.
if grep -qiE 'superpowers (plugin )?directory' "$TESTING_MD"; then
  echo "  FAIL  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"
  echo "        file: $TESTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T1.6 testing.md drops the 'run FROM the superpowers directory' instruction"; PASS=$((PASS + 1))
fi
# Real harness IS described.
assert_grep "$TESTING_MD" 'tests/\*\.test\.sh'              "T1.7 testing.md names the real tests/*.test.sh shape-checks"
assert_grep "$TESTING_MD" '\.github/workflows/test\.yml'    "T1.8 testing.md points at .github/workflows/test.yml"
assert_grep "$TESTING_MD" 'uberdev@uberdev'                 "T1.9 testing.md uses the real uberdev@uberdev marketplace key"
assert_grep "$TESTING_MD" 'solve-pipeline-zsh\.test\.sh'    "T1.11 testing.md names the zsh-runtime fixture"

# T1.12 / T1.13 — convention 9 states the PRECONDITION for the bash 3.2 exit
# laundering, not a shorter claim that happens to be false (#606). Measured on
# 3.2.57 against 5.3.9, one abort mode (`set -u` on an unbound variable) and one
# EXIT trap: `set -u` alone exits 1 on BOTH majors, with or without the trap and
# with or without `pipefail`. Only `set -e` and `set -u` together, plus an
# installed EXIT trap, launder the abort to 0 — and only on 3.2.
#
# So the short form the doc used to carry ("a `set -u` abort in a script that
# has an `EXIT` trap installed exits zero") is not a simplification, it is a
# false rule: a reader who applies it to their own `set -u`-only fixture
# concludes they need the floor when nothing was laundering, and — worse —
# reads the trap as the culprit and drops it. The same sentence is restated by
# `e5_why` inside tests/exit-floor.test.sh, so the two are corrected together;
# that file's E5 row measures the real thing on the shell in hand, which is why
# the row here lints the PROSE and does not re-measure it.
#
# A pair, deliberately. The presence row alone is satisfied by prose that names
# every option and still leads with the wrong rule; the absence row alone is
# satisfied by deleting the paragraph. `on bash 3.2` scopes the presence pattern
# to convention 9 — it appears once in the file — so a `set -e` sampled from the
# unrelated example block further up cannot satisfy it.
assert_grep "$TESTING_MD" 'on bash 3\.2.*set -u.*set -e.*EXIT' \
  "T1.12 testing.md names errexit AND nounset AND the EXIT trap as the laundering precondition"
assert_absent_fixed "$TESTING_MD" 'a `set -u` abort in a script that has an `EXIT` trap installed' \
  "T1.13 testing.md drops the set-u-plus-trap-alone rule, which is measurably false on both bash majors"

echo
echo "== T1b: CI-layout prose is DERIVED from test.yml, not a hand-written count =="
# Root cause of the 'two-job matrix' rot: the docs hardcoded a job COUNT while
# test.yml grew a third job (supervision-smoke-macos). Derive the job ids from
# the workflow and require the docs to name each one, so the next job addition
# reds here instead of silently making the prose a lie. Scan starts at the
# top-level `jobs:` key so `on: push:` / `concurrency:` children never match.
CI_JOB_IDS="$(awk '
  /^jobs:[[:space:]]*$/          { in_jobs = 1; next }
  in_jobs && /^[^[:space:]#]/    { in_jobs = 0 }
  in_jobs && /^  [a-z0-9][a-z0-9_-]*:[[:space:]]*$/ {
    gsub(/[[:space:]:]/, ""); print
  }
' "$TEST_YML")"
CI_JOB_COUNT="$(printf '%s\n' "$CI_JOB_IDS" | grep -c '[a-z]' || true)"
if [ "${CI_JOB_COUNT:-0}" -ge 2 ] 2>/dev/null; then
  echo "  PASS  T1b.1 test.yml job ids parsed (${CI_JOB_COUNT}: $(printf '%s ' $CI_JOB_IDS))"; PASS=$((PASS + 1))
else
  echo "  FAIL  T1b.1 could not parse >=2 job ids from $TEST_YML"; FAIL=$((FAIL + 1))
fi
# BOTH prose surfaces hand-enumerate the job list, so both are checked: the
# CONTRIBUTING.md paragraph names all jobs inline and rots on the next job
# addition exactly like testing.md's table did.
for job_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  MISSING_JOB_DOC=""
  while IFS= read -r job_id; do
    [ -n "$job_id" ] || continue
    grep -qF -e "$job_id" "$job_doc" || MISSING_JOB_DOC="${MISSING_JOB_DOC} ${job_id}"
  done <<EOF_CI_JOBS
$CI_JOB_IDS
EOF_CI_JOBS
  if [ -z "$MISSING_JOB_DOC" ]; then
    echo "  PASS  T1b.2 $(basename "$job_doc") names every test.yml job"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T1b.2 $(basename "$job_doc") does not name test.yml job(s):${MISSING_JOB_DOC}"
    echo "        file: $job_doc"; FAIL=$((FAIL + 1))
  fi
done
# No hardcoded job-count claim may re-grow in either doc (the drift shape that
# produced 'two-job matrix'). Sharding a job changes the number of CI RUNS
# without changing the number of jobs, so a count in prose is wrong twice over.
# The count token need NOT be adjacent to 'job': 'two shape-check jobs' is the
# same rot as 'two-job matrix', so allow up to three intervening words.
JOB_COUNT_RE='(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+)([ -][a-z]+){0,3}[ -]jobs?([^a-z]|$)'
for count_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  if grep -qiE "$JOB_COUNT_RE" "$count_doc"; then
    echo "  FAIL  T1b.3 $(basename "$count_doc") carries a hardcoded CI job-count claim (drift-prone)"
    grep -inE "$JOB_COUNT_RE" "$count_doc" | cut -c1-120 | sed 's/^/        /'
    echo "        file: $count_doc"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  T1b.3 $(basename "$count_doc") carries no hardcoded CI job-count claim"; PASS=$((PASS + 1))
  fi
done
# Sharding is an execution detail; the docs must say wiring is per JOB so a
# reader never concludes a test needs re-wiring when a shard axis appears.
assert_grep "$TESTING_MD" 'shard' "T1b.4 testing.md explains the per-job (not per-shard) wiring contract"
# Stale-enumeration guard: any *-zsh fixture NAMED in the docs must be one
# test.yml actually invokes with zsh. Catches a renamed/removed fixture that
# the prose keeps advertising (the 'one fixture' / three-name-list class).
ZSH_WIRED="$(grep -oE 'zsh tests/[A-Za-z0-9_-]+-zsh\.test\.sh' "$TEST_YML" | sed 's|^zsh tests/||' | sort -u)"
STALE_ZSH_DOC=""
for zsh_doc in "$TESTING_MD" "$CONTRIBUTING_MD"; do
  while IFS= read -r cited; do
    [ -n "$cited" ] || continue
    grep -qF -e "$cited" <<EOF_ZSH_WIRED || STALE_ZSH_DOC="${STALE_ZSH_DOC} $(basename "$zsh_doc"):${cited}"
$ZSH_WIRED
EOF_ZSH_WIRED
  done <<EOF_ZSH_CITED
$(grep -oE '[A-Za-z0-9_-]+-zsh\.test\.sh' "$zsh_doc" | sort -u)
EOF_ZSH_CITED
done
if [ -z "$STALE_ZSH_DOC" ]; then
  echo "  PASS  T1b.5 every *-zsh fixture named in the docs is one test.yml runs under zsh"; PASS=$((PASS + 1))
else
  echo "  FAIL  T1b.5 docs cite zsh fixture(s) test.yml does not run under zsh:${STALE_ZSH_DOC}"; FAIL=$((FAIL + 1))
fi
# T1b.6 (#628) — the FAILURE-PROPAGATION claim, derived in both directions.
# testing.md described the shape-check jobs as joined into one command list
# "so ... stops at the first red file". That sentence stopped being true the
# moment the run: blocks were de-chained, and nothing in this suite noticed:
# T1/T1b pin the job ids, the zsh glob, the shard rule and the bash-3.2
# preconditions, but never the one sentence a reader uses to decide whether a
# green tail of the CI log means anything. So it is derived from test.yml, not
# asserted: read what the workflow actually does, then require the prose to
# agree. If someone re-chains a block the row flips and demands the opposite
# prose, so it cannot rot in either direction.
#
# The join needle is assembled at runtime. This file is inside the lint corpora
# that grep tests/ for chained-shape literals, and a contiguous one here would
# make this row trip guards it is not the subject of.
# Both orders count: a join can trail the invocation (`bash tests/a.test.sh && \`)
# or lead it (`... && bash tests/a.test.sh`). Reading only the trailing form is
# how a classifier goes quietly blind to half its subject.
T1B_JOIN='&'; T1B_JOIN="${T1B_JOIN}&"
T1B_INVOKE='tests/[A-Za-z0-9._-]+\.test\.(sh|py)'
T1B_CHAINED_N="$(grep -cE "${T1B_INVOKE}.*${T1B_JOIN}|${T1B_JOIN}.*${T1B_INVOKE}" "$TEST_YML" 2>/dev/null || true)"
[ -n "$T1B_CHAINED_N" ] || T1B_CHAINED_N=0
# Does the prose describe the suite as chained? Both tokens on one line.
T1B_DOC_CHAIN="$(grep -nE "${T1B_JOIN}.{0,60}chain|chain.{0,60}${T1B_JOIN}" "$TESTING_MD" 2>/dev/null || true)"
# Does the prose describe the accumulating harness the workflow now carries?
T1B_DOC_ACCUM=no
grep -qE 'run_one|accumulat' "$TESTING_MD" 2>/dev/null && T1B_DOC_ACCUM=yes
if [ "$T1B_CHAINED_N" -eq 0 ] 2>/dev/null; then
  if [ -z "$T1B_DOC_CHAIN" ] && [ "$T1B_DOC_ACCUM" = yes ]; then
    echo "  PASS  T1b.6 test.yml chains no test invocation, and testing.md describes the accumulating harness"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T1b.6 test.yml chains NO test invocation, but testing.md still describes a chained suite"
    [ -z "$T1B_DOC_CHAIN" ] || printf '        %s\n' "$T1B_DOC_CHAIN" | cut -c1-160
    [ "$T1B_DOC_ACCUM" = yes ] || echo "        and it never names the accumulating harness (run_one / accumulate)"
    echo "        file: $TESTING_MD — a reader concludes a red file hides the ones after it (#628)"
    FAIL=$((FAIL + 1))
  fi
else
  # The workflow really is chained again; then the prose must say so, or it
  # under-warns in the other direction.
  if [ -n "$T1B_DOC_CHAIN" ]; then
    echo "  PASS  T1b.6 test.yml chains $T1B_CHAINED_N invocation line(s) and testing.md documents the chaining"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T1b.6 test.yml chains $T1B_CHAINED_N test invocation line(s) that testing.md does not document"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== CONTRIBUTING.md: no dead link, no false claim, test.yml is SSOT =="
assert_absent_fixed "$CONTRIBUTING_MD" "README.md#repo-layout" "T2.1 CONTRIBUTING drops the dead README.md#repo-layout link"
# The false 'no runtime behavioral tests' sentence must be gone.
if grep -qiE 'no runtime behavioral tests' "$CONTRIBUTING_MD"; then
  echo "  FAIL  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"
  echo "        file: $CONTRIBUTING_MD"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T2.2 CONTRIBUTING drops the false 'no runtime behavioral tests' sentence"; PASS=$((PASS + 1))
fi
assert_grep "$CONTRIBUTING_MD" '\.github/workflows/test\.yml' "T2.3 CONTRIBUTING points at test.yml"
assert_grep "$CONTRIBUTING_MD" 'single source of truth|source of truth' "T2.4 CONTRIBUTING frames test.yml as the test-set SSOT"

echo
echo "== docs/rfc/: no duplicate RFC numbers =="
# Extract the leading 4-digit number from every docs/rfc/NNNN-*.md filename and
# assert each appears exactly once. Catches the 0004 collision (and any future
# one) dynamically, without hardcoding the current RFC set.
DUP_NUMS="$(
  for f in "$RFC_DIR"/[0-9][0-9][0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    echo "${base%%-*}"
  done | sort | uniq -d
)"
if [ -n "$DUP_NUMS" ]; then
  echo "  FAIL  T3.1 every docs/rfc/ number is unique"
  echo "        duplicate RFC number(s): $(echo "$DUP_NUMS" | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T3.1 every docs/rfc/ number is unique (no NNNN collision)"; PASS=$((PASS + 1))
fi
# The renumbered alias RFC exists at 0011 and self-identifies as RFC 0011.
assert_grep "$ALIAS_RFC" '^# RFC 0011 — Alias-Install Reliability' "T3.2 alias RFC header self-identifies as RFC 0011"
# The dispatch RFC keeps 0004.
assert_grep "$DISPATCH_RFC" '^# RFC 0004 — Cross-Platform Dispatch' "T3.3 dispatch RFC keeps RFC 0004 header"
# The precision-eval RFC self-identifies as 0018 (#432 reserved the number).
assert_grep "$PRECISION_RFC" '^# RFC 0018 — ' "T3.4 precision RFC header self-identifies as RFC 0018"
# The vendored-upstream policy RFC (#434) self-identifies as RFC 0019. NOTE: the
# H1 carries an em dash (U+2014), matched by `.` only in a UTF-8 locale, so the
# pattern below spells it literally the same way T3.2/T3.3 do.
# Numbered T3.5, not T3.4: #432 and #434 each appended their new RFC assertion as
# "T3.4" independently, so the stacked merge would ship two rows under one label.
assert_grep "$VENDOR_RFC" '^# RFC 0019 — Vendored Upstream Policy' "T3.5 vendor RFC header self-identifies as RFC 0019"
# §7 adjudicates 6.1.0 -> 6.2.0 and is frozen at that measurement, so every later
# upstream release is adjudicated by its own dated amendment (#511 = the 6.3.0
# delta). T3.6 is what stops a watermark advance from landing with no verdict
# table behind it.
# NOTE two traps this pattern is written around:
#   - assert_grep is `grep -qE`, so the heading's parentheses are ERE grouping
#     metacharacters and MUST be escaped. An unescaped '(2026-08-13, #511)'
#     matches a heading that was never written.
#   - the heading deliberately carries no U+2192; the arrow lives in the body
#     prose instead. docs-accuracy runs on ubuntu AND windows-latest, and in a
#     C/POSIX locale `.` is one byte while the arrow is three (see T4.2).
assert_grep "$VENDOR_RFC" '^## Amendment \(2026-08-13, #511\) — ' "T3.6 vendor RFC carries the dated #511 amendment heading"
# Anchored to the amendment's OWN section, not the file: the 2026-08-12 (#457)
# amendment already carries an identical status line, so a whole-file assert_grep
# here would PASS against the pre-existing block and never notice that the #511
# amendment was missing its status.
# The section end is '^### ', NOT '^## '. assert_in_section builds an awk range
# /start/,/end/, and awk tests the END pattern against the START line itself — so
# a '^## ' end pattern matches the '## Amendment …' heading that opened the range
# and collapses it to that one line (measured: 1 line vs 123 open-ended), which
# reds this row for the wrong reason. '^### ' cannot match a two-hash heading and
# bounds the blockquote exactly, while still terminating correctly if a later
# amendment is appended below.
assert_in_section "$VENDOR_RFC" '^## Amendment \(2026-08-13, #511\)' '^### ' \
  'Status of this amendment: \*\*Accepted, implemented\.\*\*' \
  "T3.6b the #511 amendment declares its own status inside its own block"
# §4.2 and §4.3 record a `measured_diff_lines` per component and the register
# records the same numbers again, with nothing reconciling the two — they had
# already drifted on two components (#534). The fix labels each table with the
# revision, date and counting rule its numbers were taken under, and makes
# `measured_diff_basis` a required record in the register.
# Division of labour: the LABELS are reconciled against the register by
# tests/vendor-provenance.test.sh (the comparator reads every `Diff lines` table
# in this document); what these three rows own is the amendment that says what a
# label means, why the two frozen tables keep their cells, and what the numbers
# were measured against. Both T3.6 traps apply here verbatim:
#   - assert_grep is `grep -qE`, so '(2026-08-14, #534)' MUST escape its parens.
#     An unescaped form matches a heading that was never written.
#   - the heading carries no U+2192; this file runs on ubuntu AND windows-latest.
assert_grep "$VENDOR_RFC" '^## Amendment \(2026-08-14, #534\) — ' "T3.7 vendor RFC carries the dated #534 amendment heading"
# Anchored to this amendment's OWN block for the T3.6b reason: three earlier
# amendments already carry a byte-identical status line, so a whole-file
# assert_grep would pass against #457's and never notice this one was missing.
# The section end is '^### ', NOT '^## ' — see the awk-range note above T3.6b.
assert_in_section "$VENDOR_RFC" '^## Amendment \(2026-08-14, #534\)' '^### ' \
  'Status of this amendment: \*\*Accepted, implemented\.\*\*' \
  "T3.7b the #534 amendment declares its own status inside its own block"
# The honesty claim the 14 skill numbers rest on. They were measured against the
# claude-plugins-official plugin cache — a repackaging of the peeled v6.3.0 tag,
# which the #511 amendment records as corroborated rather than trusted — and NOT
# against obra/superpowers itself. The register keeps that distinction in a field
# (`upstream_tree`, beside `upstream_rev`) instead of a sentence; this row is
# what stops the amendment from shipping the field while dropping the paragraph
# that says why the two are not the same thing.
# The end pattern is '^# ' (ONE hash), and both alternatives are wrong here:
# '^### ' stops at the first sub-heading, and the claim lives in a sub-section
# BELOW the blockquote; '^## ' matches the '## Amendment …' start line itself and
# collapses the range to that one line (the awk trap T3.6b records). '^# ' can
# match neither a two- nor a three-hash heading, so the range spans the whole
# amendment — and past it. Nothing below the #534 block closes the range, so it
# runs to EOF and also spans every amendment appended after that block (the
# 2026-08-18 #604 one, and any later). The over-reach is why the pattern must be
# a full sentence naming a field that did not exist before this change: a generic
# phrase would be satisfiable from one of those later blocks, and this row would
# pass while the #534 amendment had lost the paragraph it is here to hold.
assert_in_section "$VENDOR_RFC" '^## Amendment \(2026-08-14, #534\)' '^# ' \
  '`upstream_tree` records that the cache is a repackaging of upstream, not upstream itself\.' \
  "T3.7c the #534 amendment states the measured tree is not upstream itself"

# §7 and the #511/#534 amendments adjudicate an upstream that HAS a review
# point. #604 defect 3 is the opposite case: that an upstream is adjudicated at
# HEAD used to be recorded as the ABSENCE of `last_reviewed_release`, so
# deleting one line from the register was indistinguishable from a deliberate
# policy decision, and the report affirmatively attributed its own silence to a
# key that was simply not there. The register now carries `head_only: true`, and
# this amendment is where that key is adjudicated in prose rather than inferred.
# Both T3.6 traps apply here verbatim:
#   - assert_grep is `grep -qE`, so '(2026-08-18, #604)' MUST escape its parens.
#     An unescaped form matches a heading that was never written.
#   - the heading carries no U+2192; this file runs on ubuntu AND windows-latest.
assert_grep "$VENDOR_RFC" '^## Amendment \(2026-08-18, #604\) — ' "T3.8 vendor RFC carries the dated #604 amendment heading"
# Anchored to this amendment's OWN block for the T3.6b reason, and the pressure
# is now six-fold: the #457, #503, #505, #509, #511 and #534 blocks each carry a
# byte-identical status line, so a whole-file assert_grep would pass against any
# one of them and never notice this amendment shipped without a status.
# The section end is '^### ', NOT '^## ' — see the awk-range note above T3.6b.
assert_in_section "$VENDOR_RFC" '^## Amendment \(2026-08-18, #604\)' '^### ' \
  'Status of this amendment: \*\*Accepted, implemented\.\*\*' \
  "T3.8b the #604 amendment declares its own status inside its own block"

echo
echo "== dispatch RFC 0004: internal version refs agree on v0.30.0 =="
# Status line is the anchor of truth (already v0.30.0); §4/§5 must match it.
assert_grep "$DISPATCH_RFC" 'Status.*Implemented — v0\.30\.0' "T4.1 dispatch RFC Status is v0.30.0"
# NOTE: the RFC uses a multibyte UTF-8 arrow (U+2192) between versions. Match
# it with `.*` (not a single `.`) so the pattern holds in a C/POSIX locale too
# (where `.` is one byte and the arrow is three) — env -i / Git Bash safe.
assert_grep "$DISPATCH_RFC" 'version bump .0\.29\.0.*0\.30\.0' "T4.2 §4 File-impact bump reads 0.29.0 -> 0.30.0"
assert_grep "$DISPATCH_RFC" 'CHANGELOG\.md.*## \[0\.30\.0\].*section' "T4.3 §5 Migration cites the [0.30.0] CHANGELOG section"
assert_grep "$DISPATCH_RFC" 'git tag .v0\.30\.0' "T4.4 §5 Migration cites tag v0.30.0"
# The wrong target version must be gone from §4/§5 (the contradiction). A bare
# 0.28.0/0.29.0 as the bump TARGET '-> 0.29.0' or tag 'v0.29.0' must not survive.
if grep -qE '0\.28\.0.*0\.29\.0|## \[0\.29\.0\] section|git tag .v0\.29\.0' "$DISPATCH_RFC"; then
  echo "  FAIL  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"
  echo "        file: $DISPATCH_RFC"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T4.5 dispatch RFC carries no stale 0.28.0->0.29.0 / v0.29.0 target refs"; PASS=$((PASS + 1))
fi

echo
echo "== alias-RFC cross-refs repointed to RFC 0011; no stale 0004-alias path =="
assert_grep "$SESSION_START" 'RFC 0011' "T5.1 hooks/session-start cites RFC 0011"
assert_grep "$ALIASES_SYNC"  'RFC 0011' "T5.2 lib/aliases-sync.sh cites RFC 0011"
# The cross-ref files must no longer cite the alias work as 'RFC 0004' (the
# dispatch RFC owns 0004; neither of these two files references dispatch).
assert_absent_fixed "$SESSION_START" "RFC 0004" "T5.3 hooks/session-start no longer cites the (dispatch-owned) RFC 0004"
assert_absent_fixed "$ALIASES_SYNC"  "RFC 0004" "T5.4 lib/aliases-sync.sh no longer cites the (dispatch-owned) RFC 0004"
# No surviving path reference to the old alias-RFC filename anywhere in the two
# cross-ref files or the renamed RFC itself.
for f in "$SESSION_START" "$ALIASES_SYNC" "$ALIAS_RFC"; do
  assert_absent_fixed "$f" "0004-alias-install-reliability" "T5.5 no stale 0004-alias-install-reliability path in $(basename "$f")"
done

echo
echo "== T6: hook diet (#309 / RFC 0012 §7.7) — schema in references/configuration.md, primer slim =="
# The SessionStart hook injects using-uberdev/SKILL.md on EVERY startup/clear/
# compact. The 11 KB config schema moved to references/configuration.md; the
# primer keeps only a pointer. These pins make the diet a ratchet.
assert_grep "$USING_SKILL" 'references/configuration\.md' \
  "T6.1 SKILL.md primer points at references/configuration.md"
assert_absent_fixed "$USING_SKILL" "solve_tier_floor" \
  "T6.2 SKILL.md no longer carries the config schema (solve_tier_floor moved)"
assert_absent_fixed "$USING_SKILL" "bot_authors_allow_list" \
  "T6.3 SKILL.md no longer carries the config schema (bot_authors_allow_list moved)"
assert_grep "$CONFIG_REF" 'solve_tier_floor' \
  "T6.4 references/configuration.md carries the moved schema (solve_tier_floor)"
# Size ratchet: the per-session-event injection payload stays dieted. 7168 B
# (7 KiB) leaves headroom over the post-diet primer without allowing the schema
# back in (pre-diet was 16,511 B).
#
# THE UNIT IS THE WORST-CASE CRLF CHECKOUT of the committed blob — its bytes
# plus its newline count — compared against the 7168 B budget. No absolute
# current size is written here on purpose: any PR that edits the primer moves
# it, so a present-tense figure in a comment nothing machine-checks is stale on
# arrival and understates the remaining headroom. T6.5 below prints the live
# measurement, which is the only figure that is true when you read it.
#
# WHY NOT THE WORKTREE FILE (#522). core.autocrlf=true is live on
# windows-latest, so a worktree byte count is a checkout-TRANSLATED size and
# this one literal budget was silently a 7043 B budget there. Measured ONCE, at
# the #522 commit and stated here as history rather than as a current size: the
# same file counted 6454 B on the ubuntu job and 6579 B on the windows job.
# The number the budget is compared against has to be the number CI enforces,
# on both jobs.
#
# WHY NOT PLAIN BLOB BYTES. hooks/session-start reads this primer FROM THE
# WORKTREE and injects it on every session event, so blob-only bytes would
# LOOSEN the guard by one byte per line on the platform with the biggest
# payload. Worst-case keeps today's Windows strictness and raises ubuntu to
# match; nothing has to shrink.
#
# WHY NOT WIDEN /.gitattributes. Row T8.10 below forbids it: the rule is scoped
# to plugins/uberdev/hooks/** because three byte-exactness suites are
# windows-skipped on that scoping, and /.gitattributes records the rationale.
# === BEGIN T6.5 size-ratchet measurement (#522) ===
# USING_SKILL is an ABSOLUTE path (set near the top of this file), and
# `git cat-file blob "HEAD:/Volumes/…"` fails with "exists on disk, but not in
# 'HEAD'". Derive the repo-relative form rather than retyping the path (#370:
# one contract, N uncompared copies).
USING_SKILL_REL="${USING_SKILL#"$REPO_ROOT"/}"
USING_SKILL_BYTES="$(checkout_worst_case_bytes "$REPO_ROOT" "$USING_SKILL_REL")"
USING_SKILL_RC=$?        # captured BEFORE any other command runs
if [ "$USING_SKILL_RC" -ne 0 ]; then
  echo "  FAIL  T6.5 could not measure using-uberdev/SKILL.md (checkout_worst_case_bytes rc=$USING_SKILL_RC)"
  echo "        path: $USING_SKILL_REL — rc 3 means it is not in HEAD (renamed? untracked?),"
  echo "        which is exactly the state that would have made this ratchet silently green. See #522."
  FAIL=$((FAIL + 1))
elif [ "$USING_SKILL_BYTES" -le 7168 ]; then
  echo "  PASS  T6.5 using-uberdev/SKILL.md stays dieted (${USING_SKILL_BYTES} B <= 7168 B)"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6.5 using-uberdev/SKILL.md regressed past the diet ratchet (${USING_SKILL_BYTES} B > 7168 B)"
  echo "        file: $USING_SKILL"; FAIL=$((FAIL + 1))
fi
# === END T6.5 size-ratchet measurement (#522) ===
# T6.5a — anti-vacuity floor. A budget met by an unmeasured value is the #522
# failure mode wearing a fix's clothes. `case`, not `[ "$X" -gt 0 ]`: on an
# empty value the arithmetic test errors with "integer expression expected" and
# the row would fail for the wrong reason, printing a diagnostic that sends the
# next reader after the wrong bug. It is also the zsh-clean form.
case "$USING_SKILL_BYTES" in
  ''|0|*[!0-9]*)
    echo "  FAIL  T6.5a the ratchet was satisfied by an unmeasured value ('$USING_SKILL_BYTES') — a budget met by 0 bytes is not a budget"
    FAIL=$((FAIL + 1)) ;;
  *)
    echo "  PASS  T6.5a T6.5 measured a positive byte count (${USING_SKILL_BYTES} B), not a masked failure"
    PASS=$((PASS + 1)) ;;
esac
# T6.5b — the ratchet above must keep measuring a size that does NOT vary with
# core.autocrlf. Placement below the region is load-bearing: awk exits at the
# first END match, so this row's own marker literals are unreachable and the
# slice can never extract itself. The anchors are pinned to a whole-line comment
# (`^# === `) rather than the bare phrase, because a backtick-quoted MENTION of
# a marker elsewhere in a file silently moves where the slice starts — measured
# while writing the sibling guard in tests/workflow-scripts.test.sh, where it
# made both rows pass with the region absent entirely.
T65_REGION="$(awk '/^# === BEGIN T6\.5 size-ratchet measurement/{a=1} a{print} a && /^# === END T6\.5 size-ratchet measurement/{exit}' "$DOCS_ACCURACY_SELF")"
# Assembled at runtime so this row cannot trip over its own source bytes.
T65_WORKTREE_TOKEN="$(printf 'wc'; printf ' -c <')"
if [ -z "$T65_REGION" ]; then
  echo "  FAIL  T6.5b the T6.5 size-ratchet region is EMPTY — its BEGIN/END markers are gone, and an empty region satisfies every check below vacuously (#347)"
  FAIL=$((FAIL + 1))
elif ! grep -qF -- 'checkout_worst_case_bytes' <<<"$T65_REGION"; then
  echo "  FAIL  T6.5b T6.5 no longer measures via checkout_worst_case_bytes — a 7168 B budget compared against checkout-translated bytes is a 7043 B budget on windows-latest, silently (#522)"
  FAIL=$((FAIL + 1))
elif grep -qF -- "$T65_WORKTREE_TOKEN" <<<"$T65_REGION"; then
  echo "  FAIL  T6.5b T6.5 measures the worktree file again — that size varies with core.autocrlf, so the number in this file stops being the number CI enforces (#522)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T6.5b T6.5 budgets a checkout-independent size (git blob bytes + newline count, not the translated worktree file)"
  PASS=$((PASS + 1))
fi
# Workflow sanction lines (RFC 0012 §4.1): the primer must sanction
# skill-mandated Workflow calls so migrated pipelines are covered from day one.
assert_grep "$USING_SKILL" 'Skill-mandated Workflow calls' \
  "T6.6 primer carries the Workflow sanction section"
assert_grep "$USING_SKILL" 'WORKFLOW_ARGS_BEGIN' \
  "T6.7 primer names the WORKFLOW_ARGS_BEGIN/END relay markers"
assert_grep "$USING_SKILL" 'No-Workflow fallback' \
  "T6.8 primer routes tool-less platforms to the No-Workflow fallback section"

echo
echo "== T6b: alias-count claims are SSOT-derived (lib/aliases-sync.sh ALIASES) =="
# Derive the canonical alias count + short names from the ALIASES table (the
# SSOT) instead of hardcoding, so adding alias #14 reds this test until the
# docs follow. Range: the ALIASES='...' assignment through the closing quote;
# every row contains a pipe.
ALIAS_ROWS="$(sed -n "/^ALIASES='/,/^'\$/p" "$ALIASES_SYNC" | grep '|' | sed "s/^ALIASES='//")"
ALIAS_COUNT="$(printf '%s\n' "$ALIAS_ROWS" | grep -c '|')"
if [ "$ALIAS_COUNT" -ge 1 ] 2>/dev/null; then
  echo "  PASS  T6b.1 ALIASES SSOT parsed (${ALIAS_COUNT} rows)"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6b.1 could not parse ALIASES rows from $ALIASES_SYNC"; FAIL=$((FAIL + 1))
fi
assert_grep "$CONFIG_REF" "installs ${ALIAS_COUNT} top-level forwarder commands" \
  "T6b.2 configuration.md alias paragraph claims the SSOT count (${ALIAS_COUNT})"
MISSING_ALIAS=""
while IFS='|' read -r short _rest; do
  [ -n "$short" ] || continue
  grep -qF -e "/${short}" "$CONFIG_REF" || MISSING_ALIAS="${MISSING_ALIAS} /${short}"
done <<EOF_ALIASES
$ALIAS_ROWS
EOF_ALIASES
if [ -z "$MISSING_ALIAS" ]; then
  echo "  PASS  T6b.3 configuration.md lists every SSOT short alias"; PASS=$((PASS + 1))
else
  echo "  FAIL  T6b.3 configuration.md missing SSOT alias name(s):${MISSING_ALIAS}"
  echo "        file: $CONFIG_REF"; FAIL=$((FAIL + 1))
fi
# The hook must not re-grow a hardcoded count claim (the 7-vs-11-vs-13 drift
# class): no number word / digit immediately before 'top-level forwarder'.
if grep -qE '(seven|nine|ten|eleven|twelve|thirteen|[0-9]+) top-level forwarder' "$SESSION_START"; then
  echo "  FAIL  T6b.4 hooks/session-start carries a hardcoded forwarder count (drift-prone)"
  echo "        file: $SESSION_START"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T6b.4 hooks/session-start carries no hardcoded forwarder count"; PASS=$((PASS + 1))
fi

echo
echo "== T7: CONTRIBUTING.md hook-event + zsh-fixture claims match reality =="
assert_absent_fixed "$CONTRIBUTING_MD" "PreToolUse" \
  "T7.1 CONTRIBUTING drops the false PreToolUse hook claim (no such handler is wired)"
assert_grep "$CONTRIBUTING_MD" 'UserPromptSubmit' \
  "T7.2 CONTRIBUTING names the real UserPromptSubmit handler"
assert_absent_fixed "$CONTRIBUTING_MD" "one fixture," \
  "T7.3 CONTRIBUTING drops the stale 'one fixture' zsh claim (three -zsh fixtures run under zsh)"
assert_grep "$CONTRIBUTING_MD" 'tests/\*-zsh\.test\.sh' \
  "T7.4 CONTRIBUTING's local-run loop special-cases the *-zsh.test.sh fixtures"
# SSOT cross-check: every fixture test.yml runs under zsh must match the
# *-zsh.test.sh glob CONTRIBUTING documents — keeps T7.4's pattern truthful.
BAD_ZSH_WIRING="$(grep -E '^[[:space:]]*zsh tests/' "$TEST_YML" | grep -vE 'zsh tests/[A-Za-z0-9_-]*-zsh\.test\.sh' || true)"
if [ -z "$BAD_ZSH_WIRING" ]; then
  echo "  PASS  T7.5 every zsh-run fixture in test.yml matches the *-zsh.test.sh naming convention"; PASS=$((PASS + 1))
else
  echo "  FAIL  T7.5 test.yml runs zsh fixture(s) outside the *-zsh.test.sh convention CONTRIBUTING documents:"
  echo "$BAD_ZSH_WIRING" | sed 's/^/        /'; FAIL=$((FAIL + 1))
fi

echo
echo "== T8: hooks wiring contract — run-hook.cmd on Claude Code; Cursor is POSIX-direct =="
# hooks.json (Claude Code) must route EVERY handler through the run-hook.cmd
# polyglot (Windows compat). Key-count equality catches a handler added
# without the wrapper.
HOOK_CMD_KEYS="$(grep -c '"command":' "$HOOKS_JSON")"
HOOK_RUNHOOK_REFS="$(grep -c 'run-hook\.cmd' "$HOOKS_JSON")"
if [ "$HOOK_CMD_KEYS" -ge 1 ] && [ "$HOOK_CMD_KEYS" -eq "$HOOK_RUNHOOK_REFS" ]; then
  echo "  PASS  T8.1 hooks.json routes all ${HOOK_CMD_KEYS} handlers through run-hook.cmd"; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.1 hooks.json has ${HOOK_CMD_KEYS} command entries but ${HOOK_RUNHOOK_REFS} run-hook.cmd routes"
  echo "        file: $HOOKS_JSON"; FAIL=$((FAIL + 1))
fi
# hooks-cursor.json deliberately does NOT route through run-hook.cmd: Cursor's
# hook runner execs the bash scripts directly via their shebangs (POSIX hosts).
# run-hook.cmd has no shebang (cmd.exe polyglot), so routing Cursor through it
# would trade a working POSIX path for an unverified Windows one. The decision
# (RFC 0012 §3.13): Cursor on Windows is UNSUPPORTED and documented as such in
# CONTRIBUTING.md. If you flip this, verify Cursor-on-Windows end-to-end first.
assert_absent_fixed "$HOOKS_CURSOR_JSON" "run-hook.cmd" \
  "T8.2 hooks-cursor.json keeps direct POSIX exec (no run-hook.cmd routing)"
assert_grep "$HOOKS_CURSOR_JSON" 'CLAUDE_PLUGIN_ROOT}/hooks/' \
  "T8.3 hooks-cursor.json commands resolve under \${CLAUDE_PLUGIN_ROOT}/hooks/"
assert_grep "$CONTRIBUTING_MD" 'Cursor on Windows is unsupported' \
  "T8.4 CONTRIBUTING documents Cursor-on-Windows as unsupported"
# pre-compact's auto-memory.md contract is live-verified dead-in-repo but kept
# as a documented user/tooling-facing contract (CHANGELOG-published); the hook
# header must say so explicitly so the next reader doesn't re-litigate.
assert_grep "$PRE_COMPACT" 'Contract status \(live-verified' \
  "T8.5 pre-compact documents the verified auto-memory.md contract status"
assert_grep "$PRE_COMPACT" 'DOCUMENTED user/tooling-facing contract' \
  "T8.6 pre-compact states the keep-as-documented-contract decision"

# (#461) Nothing in this repo PARSED either hook manifest before this row: T8.1
# above is `grep -c` over the raw bytes, so a hand-edited trailing comma or an
# unbalanced brace shipped green and Claude Code silently loaded zero handlers.
# Read from stdin — never a path argument — because the windows-latest job runs
# NATIVE Windows Python, which cannot translate the MSYS `/…` paths Git Bash
# hands it (same corollary that governs the XH rows in
# tests/crossplatform-shell-wrappers.test.sh).
if python3 -I -B -c 'import json,sys; json.load(sys.stdin)' < "$HOOKS_JSON" 2>/dev/null; then
  echo "  PASS  T8.7 hooks.json parses as JSON"; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.7 hooks.json is not valid JSON — Claude Code would load NO handlers"
  echo "        file: $HOOKS_JSON"; FAIL=$((FAIL + 1))
fi
if python3 -I -B -c 'import json,sys; json.load(sys.stdin)' < "$HOOKS_CURSOR_JSON" 2>/dev/null; then
  echo "  PASS  T8.8 hooks-cursor.json parses as JSON"; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.8 hooks-cursor.json is not valid JSON"
  echo "        file: $HOOKS_CURSOR_JSON"; FAIL=$((FAIL + 1))
fi
# (#461) Every Claude Code handler must DECLARE its interpreter. Without
# `"shell": "bash"` the runtime picks the shell per host, and on a Windows host
# without Git Bash it picks PowerShell — which parses the quoted
# `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd"` literal as an expression and the
# hook never loads, with nothing surfaced. The declared form makes that host
# throw a named error instead (verified in the shipped runtime: `… requires bash
# but Git Bash was not found. Install Git for Windows …, or add "shell":
# "powershell" to this hook's config`).
#
# THIS ROW IS A COMPLETENESS RATCHET, NOT THE PROOF. A string count over JSON
# bytes cannot show that the declared command actually runs — that is XH3 (POSIX)
# and XH5 (native Windows) in tests/crossplatform-shell-wrappers.test.sh, which
# EXECUTE the extracted literal and assert the emitted SessionStart contract.
# See RFC 0019 §7 / #461 on why a string-presence check alone is a counterfeit
# here: the failure mode this issue is about is silent.
HOOK_SHELL_DECLS="$(grep -c '"shell": "bash"' "$HOOKS_JSON")"
if [ "$HOOK_CMD_KEYS" -ge 1 ] && [ "$HOOK_SHELL_DECLS" -eq "$HOOK_CMD_KEYS" ]; then
  echo "  PASS  T8.9 all ${HOOK_CMD_KEYS} hooks.json handlers declare \"shell\": \"bash\""; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.9 hooks.json has ${HOOK_CMD_KEYS} command entries but ${HOOK_SHELL_DECLS} \"shell\": \"bash\" declarations"
  echo "        file: $HOOKS_JSON"; FAIL=$((FAIL + 1))
fi
# (#461) The hook sources must check out LF on EVERY platform, because
# `"shell": "bash"` means bash parses run-hook.cmd — and under a CR-PRESERVING
# bash a CRLF copy dies at rc=127 with `$'\r': command not found` before it ever
# reaches session-start. That covers stock GNU bash (ubuntu, macOS, WSL, this
# repo's CI) but NOT the MSYS2 bash Git for Windows ships, which is patched to
# drop CR in shell_getc() and so runs a CRLF copy clean — see /.gitattributes
# for the citation and tests/crossplatform-shell-wrappers.test.sh XH2b/XH2d for
# the measured proof. Git for Windows installs with `core.autocrlf=true` by
# default, so without a rule a real user's clone rewrites these files and the
# checkout's behaviour starts depending on which bash resolves. The rule must
# stay NARROW:
# prkit-publish, vendor-provenance and review-precision are windows-skipped on a
# byte-exactness rationale, and a repo-wide `* text=auto` would change what those
# paths check out as. Deliberately NOT in the FATAL `[ -r ]` loop above — a
# missing file has to be a readable FAIL row here, not an exit-2 that stops the
# suite before the rest of T8 runs.
GITATTRIBUTES="$REPO_ROOT/.gitattributes"
if [ -r "$GITATTRIBUTES" ]; then
  GA_BAD_SCOPE="$(grep -vE '^[[:space:]]*(#|$)' "$GITATTRIBUTES" | grep -vE '^plugins/uberdev/hooks/' || true)"
  GA_HOOK_RULE="$(grep -c '^plugins/uberdev/hooks/\*\* text eol=lf$' "$GITATTRIBUTES")"
  if [ -z "$GA_BAD_SCOPE" ] && [ "$GA_HOOK_RULE" -eq 1 ]; then
    echo "  PASS  T8.10 /.gitattributes pins the hook sources to LF and nothing wider"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T8.10 /.gitattributes drifted from the narrow hooks-only eol=lf rule"
    echo "        hooks rule lines: $GA_HOOK_RULE (want 1)"
    [ -z "$GA_BAD_SCOPE" ] || printf '        out-of-scope rule: %s\n' "$GA_BAD_SCOPE"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  T8.10 /.gitattributes is missing — a Git-for-Windows clone (core.autocrlf=true) rewrites plugins/uberdev/hooks/ to CRLF and the declared bash shell cannot parse run-hook.cmd"
  FAIL=$((FAIL + 1))
fi
# (#461) The hooks bullet is the only prose that tells a contributor how the
# Claude Code wiring reaches the scripts. It named the run-hook.cmd polyglot but
# not the declared interpreter, so a reader had no way to know the resolution is
# no longer host-conditional. T8.4 above pins the Cursor half of the SAME bullet;
# keep both truthful together.
assert_grep "$CONTRIBUTING_MD" '"shell": "bash"' \
  "T8.11 CONTRIBUTING names the declared bash interpreter on the Claude Code hooks wiring"
# (#461) Five sites justified a windows-skip with the literal claim that NO
# .gitattributes exists. That claim is now false in the letter while the
# rationale survives — the rule is scoped to plugins/uberdev/hooks/ and covers
# none of those digest paths — so each was reworded to the property it actually
# depends on. CHANGELOG.md was deliberately left alone: a shipped entry is a
# historical record, and rewriting it to match a later change is worse drift than
# leaving it.
# The claim is WRAPPED prose in three of the four files (a `# ` comment column
# splits `no` from `.gitattributes exists`), so a line-anchored grep would read
# clean while the stale sentence is still there. Normalise first: drop newlines
# and backticks, then squeeze the comment column and runs of blanks to one
# space, and match the joined sentence.
GITATTR_STALE_SITES=""
for gitattr_site in "$TEST_YML" \
                    "$REPO_ROOT/tests/prkit-publish.test.sh" \
                    "$REPO_ROOT/tests/vendor-provenance.test.sh" \
                    "$RFC_DIR/0014-prkit-standalone-plugin.md"; do
  if [ ! -r "$gitattr_site" ]; then
    GITATTR_STALE_SITES="$GITATTR_STALE_SITES${GITATTR_STALE_SITES:+ }MISSING/${gitattr_site##*/}"
    continue
  fi
  gitattr_norm="$(tr -d '\n`' < "$gitattr_site" | tr -s $' \t#' ' ')"
  if grep -qE 'no \.gitattributes (file )?exists' <<<"$gitattr_norm"; then
    GITATTR_STALE_SITES="$GITATTR_STALE_SITES${GITATTR_STALE_SITES:+ }${gitattr_site##*/}"
  fi
done
if [ -z "$GITATTR_STALE_SITES" ]; then
  echo "  PASS  T8.12 no windows-skip rationale still claims the repo has no .gitattributes"; PASS=$((PASS + 1))
else
  echo "  FAIL  T8.12 a windows-skip rationale still claims no .gitattributes exists (one now does, scoped to the hooks dir)"
  printf '        %s\n' "$GITATTR_STALE_SITES"; FAIL=$((FAIL + 1))
fi

echo
echo "== T9: RFC anchors are SYMBOLS that resolve, not file:line literals (#349) =="
# Why this section exists: RFC 0012 §3.3's contract table is the acceptance
# checklist a /goal, /review-pr or /merge change is graded against. Its prior
# edition bound every row to a `file:line` literal, and nothing ever resolved
# one — so when the anchored code moved (in the same commits that edited the
# anchored rows), the pointers rotted with no test noticing. Two enforceable
# halves replace that: NO line literals inside the load-bearing prose, and
# every cited symbol must still grep-resolve in the shipped tree.

# --- §1 and the §3.3 contract table, sliced by heading ---------------------
RFC12_S1="$(awk '/^## 1\. Context/{f=1; next} f && /^## 2\./{exit} f' "$WORKFLOW_RFC")"
RFC12_TABLE="$(awk '/^\*\*Joint-migration contract table\.\*\*/{f=1} f && /^### /{exit} f' "$WORKFLOW_RFC")"
# Non-vacuity: a renamed heading must fail loudly, never silently pass zero
# assertions over an empty slice.
for slice_name in S1 TABLE; do
  case "$slice_name" in
    S1)    slice_body="$RFC12_S1"    slice_desc="§1 Context" ;;
    TABLE) slice_body="$RFC12_TABLE" slice_desc="§3.3 contract table" ;;
  esac
  slice_lines="$(printf '%s\n' "$slice_body" | grep -c . || true)"
  if [ "${slice_lines:-0}" -ge 10 ] 2>/dev/null; then
    echo "  PASS  T9.0 RFC 0012 ${slice_desc} slice extracted (${slice_lines} lines)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.0 RFC 0012 ${slice_desc} slice is empty/too small — heading renamed?"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
done

# ANCHOR-FREE: neither `lib/foo.sh:123` nor the `RP:954` / `GS:633-713` /
# `MP:698` / `SKILL:1341` shorthand the old table used may survive.
ANCHOR_RE='\.(md|sh|py|js|json|yaml|yml):[0-9]+|(^|[^A-Za-z])(RP|GS|MP|SKILL):[0-9]+'
for slice_name in S1 TABLE; do
  case "$slice_name" in
    S1)    slice_body="$RFC12_S1"    slice_desc="§1 Context" ;;
    TABLE) slice_body="$RFC12_TABLE" slice_desc="§3.3 contract table" ;;
  esac
  if grep -qE -e "$ANCHOR_RE" <<<"$slice_body"; then
    echo "  FAIL  T9.1 RFC 0012 ${slice_desc} still carries file:line anchors:"
    grep -oE -e "$ANCHOR_RE" <<<"$slice_body" | sort -u | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  T9.1 RFC 0012 ${slice_desc} is anchor-free (symbols only)"; PASS=$((PASS + 1))
  fi
done
assert_grep "$WORKFLOW_RFC" 'Reference convention \(normative for this RFC\)' \
  "T9.2 RFC 0012 states the symbol-over-line-number reference convention"

# --- The contract table names the symbols, and they still exist ------------
# Each pair is "symbol|human description". A rename in the shipped tree reds
# here, which is the entire point: the reference must be resolvable.
CONTRACT_SYMBOLS='review_reserve_run_directory|review-pr run-directory reservation
uberdev_goal_read_trust_signal|goal trust-signal READER (not the audit emitter)
_uberdev_goal_locked_marker_for_pr_fresh|goal locked-marker freshness probe
_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS|review grace window constant
discover_review_verdict_json|canonical verdict selector
uberdev_goal_locate_review_pr_audit_by_pr|PR-keyed verdict locator
uberdev_goal_read_merge_result|merge-result reader
uberdev_goal_review_pr_in_flight|review-pr in-flight probe
uberdev_dispatch_one|dispatch entry point'
while IFS='|' read -r sym desc; do
  [ -n "$sym" ] || continue
  if grep -qF -e "$sym" <<<"$RFC12_TABLE"; then
    echo "  PASS  T9.3 contract table cites \`$sym\` ($desc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.3 contract table no longer cites \`$sym\` ($desc)"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
  if grep -rqF -e "$sym" "$PLUGIN_DIR"; then
    echo "  PASS  T9.4 \`$sym\` resolves in plugins/uberdev/"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.4 \`$sym\` does NOT resolve in plugins/uberdev/ — the RFC cites a dead symbol"
    echo "        renamed? update RFC 0012 §3.3 in the SAME change"; FAIL=$((FAIL + 1))
  fi
done <<EOF_CONTRACT_SYMBOLS
$CONTRACT_SYMBOLS
EOF_CONTRACT_SYMBOLS

# --- §1 is the OTHER symbol-only surface: guard its references too ----------
# The reference convention scopes symbol-only to §1 AND the contract table, so
# §1 needs the same resolvability half. Without it §1 shipped two references
# (`CHUNK_ARRAY=($CHUNK_IDS)`, `_wave_count`) that resolved in NO file — code
# retired by the migration, cited as though it were live.
#
# T9.3b is a small CURATED presence list: the named `Step`/section headings the
# derived scan below cannot see (they are not identifier-shaped) plus the three
# correction anchors this change installed, so a silent revert to prose reds.
SECTION1_SYMBOLS='### Executable setup|the review-pr fence that reserves the run directory
Acquire the single-instance lock|the merge-pipeline single-instance lock step
review_reserve_run_directory|the shipped locked-marker writer
areaPrompt|the scan-fleet area fan-out that replaced the zsh-split wave loop
personaPrompt|the testers round loop that replaced the corrupted count helper'
while IFS='|' read -r sym desc; do
  [ -n "$sym" ] || continue
  if grep -qwF -e "$sym" <<<"$RFC12_S1"; then
    echo "  PASS  T9.3b §1 cites \`$sym\` ($desc)"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.3b §1 no longer cites \`$sym\` ($desc)"
    echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
  fi
  if grep -rqwF -e "$sym" "$PLUGIN_DIR"; then
    echo "  PASS  T9.4b \`$sym\` resolves in plugins/uberdev/"; PASS=$((PASS + 1))
  else
    echo "  FAIL  T9.4b \`$sym\` does NOT resolve in plugins/uberdev/ — §1 cites a dead symbol"
    echo "        retired by a migration? cite the SHIPPED replacement, not the corpse"
    FAIL=$((FAIL + 1))
  fi
done <<EOF_SECTION1_SYMBOLS
$SECTION1_SYMBOLS
EOF_SECTION1_SYMBOLS
# T9.4c is DERIVED, so a NEW dead reference reds without anyone remembering to
# extend a list: every identifier-shaped backticked token in §1 must resolve.
# `(memory: `key`)` spans are stripped first — those name Claude-memory files,
# not repo symbols, and the prose labels them as such. That exclusion is read
# off the prose marker, not hand-maintained per key.
S1_TOKENS="$(printf '%s\n' "$RFC12_S1" \
  | sed 's/memory: `[^`]*`//g' \
  | grep -oE '`[A-Za-z_][A-Za-z0-9_]{5,}`' | tr -d '`' | sort -u)"
S1_TOKEN_COUNT="$(printf '%s\n' "$S1_TOKENS" | grep -c '[A-Za-z]' || true)"
if [ "${S1_TOKEN_COUNT:-0}" -ge 5 ] 2>/dev/null; then
  echo "  PASS  T9.4c §1 yielded ${S1_TOKEN_COUNT} identifier references to resolve"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.4c §1 yielded only ${S1_TOKEN_COUNT} identifier references — slice/format broke"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi
S1_DEAD_TOKENS=""
while IFS= read -r s1_tok; do
  [ -n "$s1_tok" ] || continue
  grep -rqwF -e "$s1_tok" "$PLUGIN_DIR" || S1_DEAD_TOKENS="${S1_DEAD_TOKENS} ${s1_tok}"
done <<EOF_S1_TOKENS
$S1_TOKENS
EOF_S1_TOKENS
if [ -z "$S1_DEAD_TOKENS" ]; then
  echo "  PASS  T9.4c every identifier §1 cites resolves in plugins/uberdev/"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.4c §1 cites identifier(s) that resolve nowhere in plugins/uberdev/:${S1_DEAD_TOKENS}"
  echo "        retired by a migration? cite the SHIPPED replacement, not the corpse"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi

# The rotted claim of record: the trust-fields row must point at the READER.
# `uberdev_goal_audit` is the audit EMITTER the old line anchor landed on.
# Scoped to the table's DATA ROWS so the §3.3 anchoring-rule paragraph — which
# names the emitter deliberately, as the historical example — cannot mask a
# real re-rot, and matched on a symbol boundary so the backticked form the
# RFC's own convention produces (`uberdev_goal_audit` followed by a backtick,
# not a space) is caught too.
RFC12_TABLE_ROWS="$(grep '^|' <<<"$RFC12_TABLE" || true)"
RFC12_TRUST_ROW="$(awk -F'|' '$2 ~ /Trust fields/' <<<"$RFC12_TABLE_ROWS")"
EMITTER_RE='uberdev_goal_audit([^_[:alnum:]]|$)'
if [ -z "$RFC12_TRUST_ROW" ]; then
  echo "  FAIL  T9.5 no 'Trust fields' row found in the §3.3 contract table — renamed?"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
elif grep -qE -e "$EMITTER_RE" <<<"$RFC12_TABLE_ROWS"; then
  echo "  FAIL  T9.5 a contract-table row cites the audit emitter where the trust READER belongs"
  grep -nE -e "$EMITTER_RE" <<<"$RFC12_TABLE_ROWS" | cut -c1-120 | sed 's/^/        /'
  FAIL=$((FAIL + 1))
elif ! grep -qF -e 'uberdev_goal_read_trust_signal' <<<"$RFC12_TRUST_ROW"; then
  echo "  FAIL  T9.5 the 'Trust fields' row no longer names uberdev_goal_read_trust_signal"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
else
  echo "  PASS  T9.5 the Trust-fields row names the reader and no table row names the emitter"
  PASS=$((PASS + 1))
fi

# --- Per-corrected-claim greps (#349) --------------------------------------
# Marker retirement: only successful publication retires markers, so the
# Phase-3 seam must NOT carry an unconditional `rm marker` step beside it.
assert_absent_fixed "$WORKFLOW_RFC" "rm marker" \
  "T9.6 RFC 0012 drops the unconditional 'rm marker' that contradicted the publication rule"
assert_grep "$WORKFLOW_RFC" 'only successful verdict publication retires' \
  "T9.7 RFC 0012 states the publication-gated marker-retirement rule"
# Verdict-selection semantics match discover.sh: an OLDER unknown is ignored.
assert_grep "$WORKFLOW_RFC" 'at or after.*selected timestamp is indeterminate' \
  "T9.8 RFC 0012 qualifies indeterminacy as positional (at-or-after the selected timestamp)"

# Detached-session retirement (RFC 0015) annotations — annotate, never delete.
assert_grep "$WORKFLOW_RFC" 'SUPERSEDED IN PART — RFC 0015' \
  "T9.9 RFC 0012 annotates the detached-dispatch-dependent verdicts as superseded by RFC 0015"
assert_grep "$WORKFLOW_RFC" 'hybrid — shell preflight \+ solve-fleet workflow' \
  "T9.10 §3.0 verdict row for the /solve+/turbo launcher reads hybrid, not keep-shell"
assert_grep "$WORKFLOW_RFC" 'skills/goal-pipeline/workflow\.js' \
  "T9.11 §3.3 names the goal driver script"
# T9.11b — shipped-ness is DERIVED from disk, never asserted in prose. Naming a
# design target is fine; labelling it "shipped" while no such file exists is the
# unverifiable-claim class #349 exists to kill. Every `skills/<name>/workflow.js`
# the RFC names is resolved against the tree; a path that is absent may not
# appear on a line that calls it shipped.
RFC12_JS_PATHS="$(grep -oE 'skills/[a-z0-9_-]+/workflow\.js' "$WORKFLOW_RFC" | sort -u)"
RFC12_JS_COUNT="$(printf '%s\n' "$RFC12_JS_PATHS" | grep -c 'workflow\.js' || true)"
if [ "${RFC12_JS_COUNT:-0}" -ge 1 ] 2>/dev/null; then
  echo "  PASS  T9.11b RFC 0012 names ${RFC12_JS_COUNT} workflow.js driver path(s) to resolve"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.11b no skills/*/workflow.js path parsed from $WORKFLOW_RFC — renamed?"
  FAIL=$((FAIL + 1))
fi
JS_SHIPPED_LIE=""
while IFS= read -r js_path; do
  [ -n "$js_path" ] || continue
  [ -e "$PLUGIN_DIR/$js_path" ] && continue
  # No pipe into `grep -q`: its early exit SIGPIPEs the producer and pipefail
  # would then mask the match. Capture first, match against the capture.
  JS_CITING_LINES="$(grep -F -e "$js_path" "$WORKFLOW_RFC" || true)"
  if grep -qi -e 'shipped' <<<"$JS_CITING_LINES"; then
    JS_SHIPPED_LIE="${JS_SHIPPED_LIE} ${js_path}"
  fi
done <<EOF_RFC12_JS
$RFC12_JS_PATHS
EOF_RFC12_JS
if [ -z "$JS_SHIPPED_LIE" ]; then
  echo "  PASS  T9.11c every workflow.js RFC 0012 calls shipped exists in plugins/uberdev/"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T9.11c RFC 0012 claims shipped-ness for absent driver script(s):${JS_SHIPPED_LIE}"
  echo "        file: $WORKFLOW_RFC"; FAIL=$((FAIL + 1))
fi
assert_grep "$WORKFLOW_RFC" 'EXACTLY ONE nested workflow' \
  "T9.12 §3.3 pins one nested workflow() call per cycle"
assert_grep "$WORKFLOW_RFC" 'spends the single .workflow\(\). nesting level' \
  "T9.13 §3.3 records that /goal spends the single nesting level"
assert_grep "$WORKFLOW_RFC" '§3\.3 spends that level instead' \
  "T9.14 §3.6 retracts the sdd-waves nesting reservation it no longer holds"

# --- RFC 0005 corrected claims, cross-checked against the implementation ---
assert_grep "$GOAL_RFC" 'review_reserve_run_directory' \
  "T9.15 RFC 0005 D220b cites the reservation helper by symbol"
assert_grep "$GOAL_RFC" 'not.*\*\*Step 4\*\*|\*\*not\*\* "Step 4"' \
  "T9.16 RFC 0005 D220b retracts the wrong 'Step 4' pointer"
assert_grep "$GOAL_RFC" 'timestamp >= selected_timestamp' \
  "T9.17 RFC 0005 B13 states the positional indeterminacy predicate verbatim"
assert_grep "$GOAL_RFC" 'never absence\*\* — that half is unconditional' \
  "T9.18 RFC 0005 B13 scopes 'never absence' as the unconditional half"
assert_grep "$GOAL_RFC" 'POSIX; native Windows substitutes reparse-ancestor rejection' \
  "T9.19 RFC 0005 B14 annotates the non-POSIX O_NOFOLLOW substitute"
# Both RFC 0005 claims must match the code they describe, or the annotation is
# just a better-written lie.
DISCOVER_SH="$PLUGIN_DIR/skills/merge-pipeline/lib/discover.sh"
RUN_MANIFEST_PY="$PLUGIN_DIR/lib/run_manifest.py"
if [ -r "$DISCOVER_SH" ] && grep -qF -e 'timestamp >= selected_timestamp' "$DISCOVER_SH"; then
  echo "  PASS  T9.20 B13's predicate matches the canonical selector's code"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.20 B13 claims 'timestamp >= selected_timestamp' but discover.sh no longer does"
  echo "        file: $DISCOVER_SH"; FAIL=$((FAIL + 1))
fi
if [ -r "$RUN_MANIFEST_PY" ] && grep -qF -e '_reject_windows_reparse_ancestors' "$RUN_MANIFEST_PY"; then
  echo "  PASS  T9.21 B14's Windows substitute matches the runtime's reparse-ancestor rejection"; PASS=$((PASS + 1))
else
  echo "  FAIL  T9.21 B14 claims reparse-ancestor rejection but run_manifest.py no longer implements it"
  echo "        file: $RUN_MANIFEST_PY"; FAIL=$((FAIL + 1))
fi

# ── T10: no shipped doc may RECOMMEND a deleted dispatch backend (#381) ────────
# The class: `codex` and `claude-bg` were deleted from
# _UBERDEV_DISPATCH_BACKEND_ENUM, so `--backend=<either>` is an enum error at
# lib/solve-launcher.sh. Nine shipped surfaces still instructed the codex form
# after the deletion, TWO of them inside `## No-Workflow fallback` sections --
# the exact recipe a runtime WITHOUT the Workflow tool is routed to, where the
# model has no way to self-correct by re-running the primary path.
#
# A blanket "the string must not appear" grep is the wrong shape: every mention
# that survives is a deliberate TOMBSTONE, and tombstones are the thing that
# stops the surface silently coming back. So the rule is narrower and exactly
# matches the defect: every line naming `--backend=<deleted>` must ALSO carry a
# token that marks it dead on the same line. A line that names it with no such
# marker is an instruction, and instructions are what red here.
#
# CHANGELOG.md is exempt: it is an append-only historical record whose older
# entries legitimately describe the backends as live at the time of writing.
DEAD_BACKEND_MARKER='enum error|deleted|removed|retired|no longer|#381|~~|RETRACTED|was the'
# NEGATION BEATS THE TOMBSTONE, and must be tested FIRST.
#
# The marker above contains the bare word `deleted`, so a line reading
#   "`claude-bg` is deprecated, not deleted: --backend=claude-bg still works"
# MATCHED it and was skipped as a tombstone -- the very word that makes the
# claim false was the word certifying it as dead. That is not hypothetical:
# docs/rfc/0015 §1 shipped exactly that sentence on this branch and this guard
# waved it through.
#
# A line asserting the backend still works cannot be a tombstone no matter what
# else it contains, so this pattern is evaluated BEFORE the skip and a hit here
# is unconditional.
DEAD_BACKEND_NEGATION='not (deleted|removed|retired|gone)|still works|still passes|still (fully )?supported|remains? (fully )?supported|still (an? )?(available|selectable|valid)'
# _t10_corpus <root> -> repo-relative doc paths, one per line.
#
# The corpus is TRACKED content, not on-disk content (#445). T10 enforces an
# invariant about SHIPPED docs, and "shipped" means "in the tree", not "in the
# directory". A walk of the working directory also reads every scratch checkout
# under it — and UberDev's own tooling (/solve, /turbo, the Workflow runtime's
# isolation:"worktree", /merge's scratch worktree) creates those constantly. The
# result was a guard that stayed green on a fresh CI checkout and reddened on
# any working developer machine: the more the project's automation was used, the
# more reliably its own suite failed, which trains people to ignore a red suite.
#
# `git ls-files` derives the exclusion set from .gitignore rather than restating
# it, so it retires all four worktree prefixes (plugins/uberdev/lib/goal-state.sh
# enumerates "", ".claude/worktrees/*/", ".worktrees/*/", "worktrees/*/") plus
# .uberdev/ and every future scratch root in one move — a denylist of literal
# directory names would have to be extended for each new one. Same enumerator,
# same reasoning, as _epipe_sh_files in tests/epipe-guard.test.sh.
#
# STATED TRADEOFF: a doc that is written but not yet `git add`ed is no longer
# scanned locally. CI scans the committed tree and still catches it before the
# doc can ship, and epipe-guard.test.sh already accepted exactly this tradeoff.
#
# CONTRACT: writes diagnostics to stderr and RETURNS non-zero on an unusable
# root. It must NOT `exit` — this helper is called inside $( … ), where `exit`
# kills only the substitution subshell and leaves the caller holding an EMPTY
# corpus, i.e. exactly the silent vacuous PASS this guard exists to prevent.
# Every call site must therefore propagate the rc explicitly.
_t10_corpus() {
  local t10_root="$1"
  local t10_out
  git -C "$t10_root" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "FATAL: docs-accuracy T10 corpus requires a git work tree: $t10_root" >&2
    return 2
  }
  # core.quotePath=false keeps a non-ASCII tracked path from arriving as
  # "caf\303\251.md", which the per-file existence guard would silently drop.
  t10_out="$(git -c core.quotePath=false -C "$t10_root" ls-files -- '*.md' '*.json')" || return 2
  # A residual quoted path (embedded newline or quote) must be LOUD, not
  # dropped: a silent skip is the failure mode this whole guard is about.
  # Herestring, not a pipe — this file sets pipefail and `grep -q` exits early.
  if grep -qE -e '^"' <<<"${t10_out}"; then
    echo "FATAL: docs-accuracy T10 corpus contains an unrepresentable path: $t10_root" >&2
    return 3
  fi
  printf '%s\n' "${t10_out}"
}

# _t10_scan <root> -> "<path>: <lineno>:<line>" hits, one per line (empty = clean).
# Root-parameterised so the fixture below can drive the REAL scanner over a
# synthetic tree instead of asserting against a paraphrase of it.
_t10_scan() {
  local t10_root="$1"
  # `local x="$(cmd)"` masks the substitution's rc (local's own rc wins), so the
  # declaration and the assignment are deliberately on separate lines.
  local t10_docs t10_doc t10_line
  local t10_hits=""
  t10_docs="$(_t10_corpus "$t10_root")" || return 2
  while IFS= read -r t10_doc; do
    [ -n "${t10_doc}" ] || continue
    # Anchored at the corpus ROOT, with no `./` prefix — `git ls-files` emits
    # repo-relative paths. NOT `*CHANGELOG.md`: that would excuse docs/CHANGELOG.md
    # and every nested copy along with it. T10.5 pins both directions.
    case "${t10_doc}" in
      CHANGELOG.md|.git/*|*/node_modules/*) continue ;;
    esac
    # `ls-files` lists INDEX entries, which may be absent from the working tree
    # (staged deletion, sparse checkout). The grep below swallows its own
    # "no such file" via 2>/dev/null, so without this the file would be skipped
    # silently — the same quiet-drop class the corpus swap exists to remove.
    [ -f "${t10_root}/${t10_doc}" ] || continue
    while IFS= read -r t10_line; do
      [ -n "${t10_line}" ] || continue
      # Herestring, not a pipe: this file sets pipefail, and `grep -q` exits on
      # its first match, so a piped writer would take EPIPE (tests/epipe-guard.test.sh).
      # Three tiers, in this order and no other:
      #   1. struck through -> retracted BY CONSTRUCTION, excused whatever it says.
      #      A ~~...~~ line is the amend-in-place form this repo already uses; its
      #      text is quoted precisely to be contradicted.
      #   2. otherwise, a negation ("not deleted", "still works") -> ALWAYS a hit,
      #      even alongside a tombstone word, because that is the shape where the
      #      falsifying word is also the certifying word.
      #   3. otherwise, an ordinary tombstone word excuses the line.
      grep -qE -e '~~' <<<"${t10_line}" && continue
      if ! grep -qE -e "$DEAD_BACKEND_NEGATION" <<<"${t10_line}"; then
        grep -qE -e "$DEAD_BACKEND_MARKER" <<<"${t10_line}" && continue
      fi
      t10_hits="${t10_hits}${t10_doc}: ${t10_line}
"
    done <<EOF
$(grep -nE -e '--backend=(codex|claude-bg)' "${t10_root}/${t10_doc}" 2>/dev/null || true)
EOF
  done <<<"${t10_docs}"
  printf '%s' "${t10_hits}"
}

dead_backend_hits=""
dead_backend_hits="$(_t10_scan "$REPO_ROOT")" || {
  echo "FATAL: docs-accuracy T10 scan could not run (see above): $REPO_ROOT" >&2; exit 2; }
if [ -z "$dead_backend_hits" ]; then
  echo "  PASS  T10.1 no shipped .md/.json instructs a deleted dispatch backend"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T10.1 a shipped doc names --backend=codex/claude-bg with nothing marking it dead"
  # `\n`, not bare `%s`: capturing _t10_scan through $( … ) strips the trailing
  # newline its hit list carries, so the last hit would otherwise run into the
  # next PASS line.
  printf '%s\n' "$dead_backend_hits" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi
# Anti-vacuity: the scan must actually have looked at the surfaces that shipped
# the defect, or an empty/misrooted enumerator would report a silent PASS.
#
# ONE list, consumed by both T10.2 (the file still carries a tombstone) and
# T10.3 (the enumerator actually reached the file). Two hand-maintained copies
# of the same four paths would drift, and the halves would then be asserting
# about different files while both looked green.
T10_WITNESSES=(
  plugins/uberdev/skills/solve-fleet/SKILL.md
  plugins/uberdev/skills/review-fleet/SKILL.md
  plugins/uberdev/skills/goal-pipeline/SKILL.md
  README.md
)
for dead_backend_witness in "${T10_WITNESSES[@]}"; do
  if grep -qE -e '--backend=(codex|claude-bg)' "$REPO_ROOT/$dead_backend_witness"; then
    echo "  PASS  T10.2 $dead_backend_witness still carries a tombstone the scan reads"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T10.2 $dead_backend_witness has no --backend= mention at all — T10.1 may be vacuous"
    echo "        file: $REPO_ROOT/$dead_backend_witness"
    FAIL=$((FAIL + 1))
  fi
done

# ── T10.3: the corpus the scan actually enumerated is non-empty and reaches
# the witnesses ───────────────────────────────────────────────────────────────
# T10.2 above asserts the four witness files CONTAIN a --backend= mention; it
# never asserts the scan VISITED them. That gap is how a misrooted or empty
# enumerator reports a silent PASS — the hole that let #445 live through a
# release. T10.3 closes it by asserting membership in the enumerated corpus
# itself, not in the hit list (the witnesses are tombstoned, so they correctly
# produce no hits).
T10_REPO_CORPUS=""
T10_REPO_CORPUS="$(_t10_corpus "$REPO_ROOT")" || {
  echo "FATAL: docs-accuracy T10 corpus is unusable: $REPO_ROOT" >&2; exit 2; }
if [ -n "$T10_REPO_CORPUS" ]; then
  echo "  PASS  T10.3 the T10 corpus is non-empty ($(printf '%s\n' "$T10_REPO_CORPUS" | wc -l | tr -d ' ') docs)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T10.3 the T10 corpus is EMPTY — T10.1 above is vacuous, not clean"
  echo "        root: $REPO_ROOT"
  FAIL=$((FAIL + 1))
fi
for dead_backend_witness in "${T10_WITNESSES[@]}"; do
  # Herestring, not a pipe: `grep -q` exits on its first match and this file
  # sets pipefail (tests/epipe-guard.test.sh).
  if grep -qxF -- "$dead_backend_witness" <<<"$T10_REPO_CORPUS"; then
    echo "  PASS  T10.3 $dead_backend_witness is inside the enumerated corpus"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T10.3 $dead_backend_witness is NOT in the enumerated corpus — the scan never read it"
    echo "        root: $REPO_ROOT"
    FAIL=$((FAIL + 1))
  fi
done

# ── T10.4–T10.6: drive the REAL scanner over a synthetic corpus root ──────────
# Built OUTSIDE $REPO_ROOT on purpose. A fixture tree inside the repo would be
# punished by parallel worktrees, dirty-tree guards and .gitignore — and, worse,
# would be swept up by the very enumerator under test, so the fixture could not
# distinguish "excluded correctly" from "never looked".
#
# SELF-TRIP SAFETY: the rows below carry literal bare `--backend=codex` text.
# Safe here because the T10 corpus is *.md/*.json only and this file is .sh;
# safe under $SYN because $SYN is outside $REPO_ROOT. They must NEVER be written
# into a tracked .md/.json in this repo — that reds T10.1 recursively.
SYN="$(mktemp -d)" || { echo "FATAL: could not create the T10 fixture root" >&2; exit 2; }
# Fail loud on an empty or non-directory result: every path below is built by
# concatenating onto $SYN, so an empty $SYN would aim mkdir at the filesystem
# root. Never let this one degrade quietly.
[ -n "$SYN" ] && [ -d "$SYN" ] \
  || { echo "FATAL: the T10 fixture root is not a directory: '$SYN'" >&2; exit 2; }
# Top-level EXIT trap, never `trap … RETURN` (a zsh-incompatible construct the
# cross-shell guard forbids). `|| true` absorbs MSYS read-only .git objects.
trap 'rm -rf "$SYN" 2>/dev/null || true' EXIT
# `-b main` keeps init.defaultBranch advice off stderr under Git Bash.
git init -q -b main "$SYN" >/dev/null 2>&1 \
  || { echo "FATAL: could not init the T10 fixture repo: $SYN" >&2; exit 2; }

SYN_VIOLATION='Dispatch with `--backend=codex` for the fallback path.'
mkdir -p "$SYN/classifier" "$SYN/docs" \
  "$SYN/.worktrees/w" "$SYN/.claude/worktrees/w" "$SYN/worktrees/w" \
  "$SYN/.uberdev/research"

# Classifier rows — one file each, so a hit is trivially attributable.
printf '%s\n' "$SYN_VIOLATION"                                                  > "$SYN/classifier/bare.md"
printf '%s\n' '~~use `--backend=codex`~~'                                       > "$SYN/classifier/struck.md"
printf '%s\n' '`--backend=codex` was removed in #381'                           > "$SYN/classifier/tombstone.md"
printf '%s\n' '`--backend=claude-bg` is deprecated, not deleted: it still works' > "$SYN/classifier/negation.md"

# Corpus-scope rows — identical violating text, differing only in WHERE they sit.
printf '%s\n' "$SYN_VIOLATION" > "$SYN/docs/x.md"                       # plain in-tree doc
printf '%s\n' "$SYN_VIOLATION" > "$SYN/CHANGELOG.md"                    # root: exempt
printf '%s\n' "$SYN_VIOLATION" > "$SYN/docs/CHANGELOG.md"               # nested: NOT exempt
printf '%s\n' "$SYN_VIOLATION" > "$SYN/.worktrees/w/CHANGELOG.md"       # scratch checkout
printf '%s\n' "$SYN_VIOLATION" > "$SYN/.claude/worktrees/w/README.md"   # scratch checkout
printf '%s\n' "$SYN_VIOLATION" > "$SYN/worktrees/w/README.md"           # 4th prefix (goal-state.sh)
printf '%s\n' "$SYN_VIOLATION" > "$SYN/.uberdev/research/note.md"       # runtime scratch

# Index only, no commit: `git ls-files` reads the index, and committing would
# need a configured user.name/user.email that CI runners do not guarantee.
git -C "$SYN" add \
  classifier/bare.md classifier/struck.md classifier/tombstone.md classifier/negation.md \
  docs/x.md CHANGELOG.md docs/CHANGELOG.md >/dev/null 2>&1 \
  || { echo "FATAL: could not stage the T10 fixture corpus: $SYN" >&2; exit 2; }

SYN_HITS=""
SYN_HITS="$(_t10_scan "$SYN")" || {
  echo "FATAL: docs-accuracy T10 scan could not run over the fixture: $SYN" >&2; exit 2; }
# Path-only projection, sorted, one per line — the hit strings carry line
# numbers and prose that would make an exact-set comparison brittle. No `./`
# stripping: _t10_corpus emits repo-relative paths, so a `./` reaching here
# would mean the enumerator regressed and T10.4 SHOULD say so.
SYN_HIT_PATHS="$(printf '%s\n' "$SYN_HITS" | sed -n 's/^\(.*\): [0-9]*:.*$/\1/p' | sort -u)"

_t10_expect_hit() {
  local t10_id="$1" t10_want="$2" t10_why="$3"
  if grep -qxF -- "${t10_want}" <<<"$SYN_HIT_PATHS"; then
    echo "  PASS  ${t10_id} ${t10_want} is reported (${t10_why})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  ${t10_id} ${t10_want} is NOT reported but must be (${t10_why})"
    echo "        hit paths: $(printf '%s' "$SYN_HIT_PATHS" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}
_t10_expect_clean() {
  local t10_id="$1" t10_want="$2" t10_why="$3"
  if grep -qxF -- "${t10_want}" <<<"$SYN_HIT_PATHS"; then
    echo "  FAIL  ${t10_id} ${t10_want} is reported but must be excused (${t10_why})"
    echo "        hit paths: $(printf '%s' "$SYN_HIT_PATHS" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  ${t10_id} ${t10_want} is excused (${t10_why})"
    PASS=$((PASS + 1))
  fi
}

# ── T10.4: the corpus is TRACKED content — scratch checkouts are not scanned ──
# This is the regression under test (#445). The four scratch roots below are all
# created by UberDev's own tooling (/solve, /turbo, the Workflow runtime,
# /merge), so an on-disk enumerator reds the suite on any working dev machine
# while staying green on a fresh CI checkout — the exact inverse of the signal
# the guard is meant to give.
#
# Compared as an EXACT set, so a surplus hit (scratch leaked in) and a missing
# hit (real doc dropped) both red.
SYN_EXPECTED_HITS='classifier/bare.md
classifier/negation.md
docs/CHANGELOG.md
docs/x.md'
if [ "$SYN_HIT_PATHS" = "$SYN_EXPECTED_HITS" ]; then
  echo "  PASS  T10.4 the T10 corpus is exactly the tracked docs — no scratch checkout leaks in"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T10.4 the T10 corpus is not the tracked-doc set (scratch checkouts leak in, or a real doc was dropped)"
  echo "        expected: $(printf '%s' "$SYN_EXPECTED_HITS" | tr '\n' ' ')"
  echo "        actual:   $(printf '%s' "$SYN_HIT_PATHS" | tr '\n' ' ')"
  for t10_scratch in \
    .worktrees/w/CHANGELOG.md \
    .claude/worktrees/w/README.md \
    worktrees/w/README.md \
    .uberdev/research/note.md; do
    if grep -qxF -- "$t10_scratch" <<<"$SYN_HIT_PATHS"; then
      echo "        leaked scratch path: $t10_scratch"
    fi
  done
  FAIL=$((FAIL + 1))
fi

# ── T10.5: the CHANGELOG exemption is anchored at the corpus ROOT ─────────────
# Both directions are asserted separately so a regression says which way it
# broke: widening the arm to *CHANGELOG.md would silently excuse every nested
# copy, and forgetting to re-anchor it after the enumerator swap would start
# reporting the root CHANGELOG's legitimately-historical entries.
_t10_expect_clean T10.5 CHANGELOG.md      'root CHANGELOG is the append-only historical record'
_t10_expect_hit   T10.5 docs/CHANGELOG.md 'a NESTED CHANGELOG is an ordinary shipped doc'

# ── T10.6: the three-tier classifier, pinned row by row ──────────────────────
# Green under BOTH enumerators by construction, so it certifies that the corpus
# swap left the classifier alone.
_t10_expect_hit   T10.6 classifier/bare.md      'bare instruction, no marker at all'
_t10_expect_clean T10.6 classifier/struck.md    'tier 1 — struck through, retracted by construction'
_t10_expect_clean T10.6 classifier/tombstone.md 'tier 3 — ordinary tombstone word'
_t10_expect_hit   T10.6 classifier/negation.md  'tier 2 — negation beats the tombstone word'
# ── T11: `--auto` is documented as a permission BYPASS, correctly scoped (#435) ─
# Two drift classes on one flag, and they compound:
#
#   1. UNDER-LABELLED. `--auto` resolves to the bypass PAIR
#      `--dangerously-skip-permissions --permission-mode bypassPermissions`
#      (#241 collapsed the dead AUTO middle tier into the strict bypass; #246
#      established that both flags are needed because they target different
#      mechanisms). Several surfaces documented it as a mere convenience flag —
#      `README.md` even called `/turbo … --auto` "max autonomy", which reads as
#      an endorsement of the documented happy path rather than a warning.
#   2. MIS-SCOPED. Since RFC 0015 §5 the DEFAULT `workflow` backend runs the
#      per-issue solvers as agents in the calling session, so they inherit ITS
#      permission tier — the flag pair reaches a child's argv only on
#      `--backend=wezterm|background` and on the `/merge` + `/review-pr`
#      dispatches. `commands/solve.md` still promised the bypass was applied
#      "on the spawned agent", which is now false on the default path.
#
# The rule mirrors T10: a line is allowed to NAME the flag, but a line that
# DOCUMENTS it must carry a danger token, and no line may make the unscoped
# spawned-agent claim. Tokens are ASCII-only on purpose — both CI jobs are
# ubuntu + Windows Git Bash, and this repo has no precedent for a multi-byte
# emoji inside an ERE, so ⚠️ may decorate the prose but must never be the only
# thing marking a line as dangerous.
AUTO_DOC_SURFACES="README.md
plugins/uberdev/commands/solve.md
plugins/uberdev/commands/turbo.md
plugins/uberdev/skills/solve-pipeline/SKILL.md
plugins/uberdev/skills/solve-fleet/SKILL.md
plugins/uberdev/skills/using-uberdev/references/configuration.md"
# The flag PAIR is a claim about semantics, so it is pinned only where the
# semantics are actually described — including goal.md, which documents the
# same pair for its detached children but names no `--auto` flag of its own.
AUTO_PAIR_SURFACES="README.md
plugins/uberdev/commands/solve.md
plugins/uberdev/commands/turbo.md
plugins/uberdev/commands/goal.md
plugins/uberdev/skills/solve-pipeline/SKILL.md"
GOAL_MD="$REPO_ROOT/plugins/uberdev/commands/goal.md"
# lib/solve-launcher.sh is deliberately NOT in AUTO_DOC_SURFACES: its nine
# `--auto`/`SOLVE_AUTO` lines are argv-parser code, and a per-line danger-token
# rule over source would red every one of them. It is covered by T11.7 (the
# runtime note) and T11.9 (anti-vacuity) instead.
SOLVE_LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"

# T11.0 — preflight. A moved surface must be a hard failure, never a silent
# zero-assertion PASS (suite convention).
while IFS= read -r auto_surface; do
  [ -n "$auto_surface" ] || continue
  [ -r "$REPO_ROOT/$auto_surface" ] || {
    echo "FATAL: --auto documentation surface missing or unreadable: $REPO_ROOT/$auto_surface" >&2
    exit 2
  }
done <<EOF
$AUTO_DOC_SURFACES
$AUTO_PAIR_SURFACES
EOF
for auto_extra in "$GOAL_MD" "$SOLVE_LAUNCHER"; do
  [ -r "$auto_extra" ] || {
    echo "FATAL: required file missing or unreadable: $auto_extra" >&2
    exit 2
  }
done

# Does any LINE of TEXT match all three (lowercased) EREs? awk rather than
# `grep | grep`, so there is no pipeline exit status for pipefail to poison
# (tests/epipe-guard.test.sh). Pass '.' for an unused slot.
auto_line_has_all() {
  awk -v p1="$1" -v p2="$2" -v p3="$3" '
    { l = tolower($0) }
    l ~ p1 && l ~ p2 && l ~ p3 { found = 1 }
    END { exit !found }
  ' <<<"$4"
}

# T11.1 — the bypass is a flag PAIR (#246): both flags target different
# mechanisms and both are needed. Documenting one without the other invites a
# future "simplification" that drops the half nobody wrote down. File-level,
# not block-level: markdown has no reliable `--auto`-block delimiter, and a
# heuristic one would be a worse lie than no assertion.
while IFS= read -r auto_surface; do
  [ -n "$auto_surface" ] || continue
  assert_grep "$REPO_ROOT/$auto_surface" 'dangerously-skip-permissions' \
    "T11.1 $auto_surface names --dangerously-skip-permissions"
  assert_grep "$REPO_ROOT/$auto_surface" 'permission-mode bypassPermissions' \
    "T11.1 $auto_surface names the other half of the pair (--permission-mode bypassPermissions)"
done <<EOF
$AUTO_PAIR_SURFACES
EOF

# T11.2 — the backend scoping is stated. One line must carry all of
# `inherit` + `session` + `permission|bypass`, so a line about inheriting the
# session's MODEL (which configuration.md already had) cannot satisfy it.
auto_scope_missing=""
while IFS= read -r auto_surface; do
  [ -n "$auto_surface" ] || continue
  if ! auto_line_has_all 'inherit' 'session' 'permission|bypass' \
        "$(cat "$REPO_ROOT/$auto_surface")"; then
    auto_scope_missing="${auto_scope_missing}${auto_surface}
"
  fi
done <<EOF
$AUTO_DOC_SURFACES
plugins/uberdev/commands/goal.md
EOF
if [ -z "$auto_scope_missing" ]; then
  echo "  PASS  T11.2 every --auto surface states that the default backend's solvers inherit the session's permission tier"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.2 surfaces with no 'solvers inherit the session's permission tier' line:"
  printf '%s' "$auto_scope_missing" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

# T11.3 — every line that DOCUMENTS the flag carries an ASCII danger token.
AUTO_DANGER_TOKEN='dangerous|bypass|no prompts|skip.*permission'
# Two pure flag-GRAMMAR enumerations: they list `--auto` among the parser's
# accepted tokens and make no claim about what it does, so a danger token
# there would be noise. Fixed strings, and T11.3b fails if either rots away —
# a stale exemption is a silent hole in the scan.
AUTO_GRAMMAR_EXEMPT_1='`--trivial|--small|--full`, `--auto`, `--force`, routing/model/effort/service'
AUTO_GRAMMAR_EXEMPT_2='`--trivial|--small|--full`, `--auto`, `--force`/`-f`, `--effort=<level>`,'
AUTO_EXEMPT_FILE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
auto_danger_hits=""
while IFS= read -r auto_surface; do
  [ -n "$auto_surface" ] || continue
  while IFS= read -r auto_line; do
    [ -n "$auto_line" ] || continue
    # `--auto-mode` is a launcher argv selector (turbo-vs-interactive), not the
    # permission flag. Delete the string and RE-MATCH rather than skipping the
    # whole line: a line could legitimately carry both forms.
    auto_line_stripped="$(sed 's/--auto-mode//g' <<<"$auto_line")"
    grep -qE -e '--auto|SOLVE_AUTO|solve_auto' <<<"$auto_line_stripped" || continue
    grep -qF -e "$AUTO_GRAMMAR_EXEMPT_1" <<<"$auto_line" && continue
    grep -qF -e "$AUTO_GRAMMAR_EXEMPT_2" <<<"$auto_line" && continue
    grep -qiE -e "$AUTO_DANGER_TOKEN" <<<"$auto_line" && continue
    auto_danger_hits="${auto_danger_hits}${auto_surface}: ${auto_line}
"
  done <<EOF
$(grep -nE -e '--auto' -e 'SOLVE_AUTO' -e 'solve_auto' "$REPO_ROOT/$auto_surface" 2>/dev/null || true)
EOF
done <<EOF
$AUTO_DOC_SURFACES
EOF
if [ -z "$auto_danger_hits" ]; then
  echo "  PASS  T11.3 every line documenting --auto carries an ASCII danger token"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.3 --auto is documented with nothing on the line marking it a permission bypass:"
  printf '%s' "$auto_danger_hits" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

# T11.3b — the exemption list cannot rot into a silent hole.
assert_grep_fixed_docs() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -e "$needle" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        needle: $needle"
    FAIL=$((FAIL + 1))
  fi
}
assert_grep_fixed_docs "$AUTO_EXEMPT_FILE" "$AUTO_GRAMMAR_EXEMPT_1" \
  "T11.3b grammar exemption 1 still resolves (else T11.3 has a stale hole)"
assert_grep_fixed_docs "$AUTO_EXEMPT_FILE" "$AUTO_GRAMMAR_EXEMPT_2" \
  "T11.3b grammar exemption 2 still resolves (else T11.3 has a stale hole)"

# T11.4 — negative: no shipped doc may claim the bypass is applied "on the
# spawned agent" without naming the scope that makes it true. On the default
# `workflow` backend there is no per-child argv at all.
# CHANGELOG.md and docs/ are exempt: append-only history and RFC prose describe
# the world as it was when written.
auto_unscoped_hits=""
while IFS= read -r shipped_md; do
  case "$shipped_md" in
    ./CHANGELOG.md|./docs/*|./.git/*|*/node_modules/*) continue ;;
  esac
  while IFS= read -r auto_line; do
    [ -n "$auto_line" ] || continue
    auto_line_stripped="$(sed 's/--auto-mode//g' <<<"$auto_line")"
    grep -qE -e '--auto' <<<"$auto_line_stripped" || continue
    grep -qE -e 'on the spawned agent' <<<"$auto_line" || continue
    grep -qiE -e 'inherit|session|--backend=' <<<"$auto_line" && continue
    auto_unscoped_hits="${auto_unscoped_hits}${shipped_md}: ${auto_line}
"
  done <<EOF
$(grep -nE -e '--auto' "$shipped_md" 2>/dev/null || true)
EOF
done <<EOF
$(cd "$REPO_ROOT" && git -c core.quotePath=false ls-files -- '*.md' | sed 's|^|./|' | sort)
EOF
if [ -z "$auto_unscoped_hits" ]; then
  echo "  PASS  T11.4 no shipped .md claims --auto applies the bypass 'on the spawned agent' unscoped"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.4 unscoped spawned-agent bypass claim (false on the default workflow backend):"
  printf '%s' "$auto_unscoped_hits" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

# T11.5 — negative: a permission bypass is not a feature to endorse. Neither
# surface may present `--auto` as the recommended maximum-autonomy setup.
assert_absent_fixed "$REPO_ROOT/README.md" "max autonomy" \
  "T11.5 README does not sell --auto as 'max autonomy'"
assert_absent_fixed "$REPO_ROOT/plugins/uberdev/commands/turbo.md" "max-autonomy combo" \
  "T11.5 turbo.md does not sell '/turbo <issue> --auto' as the max-autonomy combo"

# T11.5b — goal.md already leads with the default-backend posture before the
# bypass paragraph (RFC 0015 §6 R-1b). Regression pin on correct prose: reorder
# it and the reader meets the bypass before learning it does not apply.
goal_scope_line="$(awk 'tolower($0) ~ /inherit/ && tolower($0) ~ /session/ { print NR; exit }' "$GOAL_MD")"
goal_bypass_line="$(awk '/dangerously-skip-permissions/ { print NR; exit }' "$GOAL_MD")"
if [ -n "$goal_scope_line" ] && [ -n "$goal_bypass_line" ] \
   && [ "$goal_scope_line" -lt "$goal_bypass_line" ]; then
  echo "  PASS  T11.5b goal.md states the inherit-the-session posture (line $goal_scope_line) before the bypass (line $goal_bypass_line)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.5b goal.md's scoping statement must precede its bypass paragraph (scope='${goal_scope_line}' bypass='${goal_bypass_line}')"
  FAIL=$((FAIL + 1))
fi

# T11.6 — `--i-know-what-im-doing` is documented in goal.md exactly once, in a
# negative call-out ("NEVER inherited"). A second mention is how a negative
# call-out turns into an instruction.
GOAL_OVERRIDE_COUNT="$(grep -c -e '--i-know-what-im-doing' "$GOAL_MD" || true)"
if [ "${GOAL_OVERRIDE_COUNT:-0}" -eq 1 ]; then
  echo "  PASS  T11.6 goal.md mentions --i-know-what-im-doing exactly once (the negative call-out)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.6 expected exactly 1 --i-know-what-im-doing mention in goal.md, found ${GOAL_OVERRIDE_COUNT:-0}"
  FAIL=$((FAIL + 1))
fi

# T11.7 — the launcher tells the OPERATOR at run time, not only the docs. The
# `Permission mode:` line it prints is emitted before the backend is resolved
# (UBERDEV_RESOLVED_BACKEND is exported later, by lib/dispatch.sh), so the
# correction has to live in the workflow branch where the backend IS known.
auto_note_line_no=""
while IFS= read -r auto_note_cand; do
  [ -n "$auto_note_cand" ] || continue
  grep -qE -e 'backend=workflow' <<<"$auto_note_cand" || continue
  grep -qE -e 'inherit' <<<"$auto_note_cand" || continue
  grep -qE -e 'RFC 0015' <<<"$auto_note_cand" || continue
  auto_note_line_no="${auto_note_cand%%:*}"
  break
done <<EOF
$(grep -n -e 'backend=workflow' "$SOLVE_LAUNCHER" 2>/dev/null || true)
EOF
if [ -z "$auto_note_line_no" ]; then
  echo "  FAIL  T11.7 lib/solve-launcher.sh emits no backend=workflow note naming the inherited tier + RFC 0015"
  FAIL=$((FAIL + 1))
else
  auto_guard_start=$((auto_note_line_no - 3))
  [ "$auto_guard_start" -lt 1 ] && auto_guard_start=1
  auto_guard_slice="$(sed -n "${auto_guard_start},$((auto_note_line_no - 1))p" "$SOLVE_LAUNCHER")"
  if auto_line_has_all 'auto_permissions' 'skip_permissions' '.' "$auto_guard_slice"; then
    echo "  PASS  T11.7 the backend=workflow note exists (line $auto_note_line_no) and fires only under a resolved bypass tier"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T11.7 the backend=workflow note is not guarded by AUTO_PERMISSIONS/SKIP_PERMISSIONS within 3 lines above it"
    FAIL=$((FAIL + 1))
  fi
fi

# T11.8 — `solve_auto` means the permission bypass, NOT brainstorm auto-accept
# (that is `/turbo`). README's config comment said the wrong one outright, and
# the shipped config reference did not document the key at all.
readme_solve_auto="$(grep -n -e '^solve_auto:' "$REPO_ROOT/README.md" || true)"
if [ -n "$readme_solve_auto" ] \
   && grep -qiE -e 'permission|bypass' <<<"$readme_solve_auto" \
   && ! grep -qiE -e 'brainstorm' <<<"$readme_solve_auto"; then
  echo "  PASS  T11.8 README's solve_auto key is described as a permission bypass, not brainstorm auto-accept"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.8 README's solve_auto key is missing, or still described as brainstorm auto-accept"
  echo "        line: ${readme_solve_auto:-<absent>}"
  FAIL=$((FAIL + 1))
fi
assert_grep "$CONFIG_REF" '^solve_auto:' \
  "T11.8 the shipped config reference documents the solve_auto key"

# T11.9 — anti-vacuity. Every scan above is a loop over greps; a renamed flag,
# a misrooted path or an emptied file would report a silent PASS (T10.2 shape).
while IFS= read -r auto_surface; do
  [ -n "$auto_surface" ] || continue
  auto_witness=""
  while IFS= read -r auto_line; do
    [ -n "$auto_line" ] || continue
    auto_line_stripped="$(sed 's/--auto-mode//g' <<<"$auto_line")"
    grep -qE -e '--auto|SOLVE_AUTO|solve_auto' <<<"$auto_line_stripped" || continue
    auto_witness="$auto_line"
    break
  done <<EOF
$(grep -nE -e '--auto' -e 'SOLVE_AUTO' -e 'solve_auto' "$REPO_ROOT/$auto_surface" 2>/dev/null || true)
EOF
  if [ -n "$auto_witness" ]; then
    echo "  PASS  T11.9 $auto_surface still documents --auto for T11.3 to read"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T11.9 $auto_surface has no --auto mention at all — T11.3 is vacuous for it"
    FAIL=$((FAIL + 1))
  fi
done <<EOF
$AUTO_DOC_SURFACES
EOF
assert_grep "$GOAL_MD" 'bypassPermissions' \
  "T11.9 goal.md still carries a bypassPermissions line for T11.1/T11.5b to read"
assert_grep "$SOLVE_LAUNCHER" 'AUTO_PERMISSIONS' \
  "T11.9 lib/solve-launcher.sh still carries AUTO_PERMISSIONS for T11.7 to read"

echo
echo "== T11: the vendored confidence rubric attributes its upstream (#431) =="
# The 0-100 rubric is adapted from Anthropic's official `code-review` plugin
# (Apache 2.0). The bundled licence text already ships as
# licenses/pr-review-toolkit-Apache-2.0.txt; the rubric SSOT must NAME it, and
# the README's Bundled table must list the rubric like every other vendored
# surface. Attribution that lives only in a commit message is attribution
# nobody reading the plugin can find.
RUBRIC_SSOT="$REPO_ROOT/plugins/uberdev/shared/finding-confidence-rubric-v1.md"
if [ -r "$RUBRIC_SSOT" ]; then
  assert_grep "$RUBRIC_SSOT" 'licenses/pr-review-toolkit-Apache-2\.0\.txt' \
    "T11.1 rubric SSOT names its bundled Apache-2.0 licence file"
  assert_grep "$RUBRIC_SSOT" 'code-review' \
    "T11.2 rubric SSOT names the upstream plugin it was adapted from"
else
  echo "  FAIL  T11: rubric SSOT missing or unreadable: $RUBRIC_SSOT"
  FAIL=$((FAIL + 2))
fi
if [ -r "$REPO_ROOT/plugins/uberdev/licenses/pr-review-toolkit-Apache-2.0.txt" ]; then
  echo "  PASS  T11.3 the licence file the rubric points at exists on disk"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T11.3 the licence file the rubric points at is missing"
  FAIL=$((FAIL + 1))
fi
assert_grep "$REPO_ROOT/README.md" 'finding-confidence-rubric-v1' \
  "T11.4 README Bundled table names the vendored rubric"

echo
echo "== T12: the version-bump contract — rule doc and machinery, locked in both directions (#472) =="
# THE DRIFT THIS LOCKS. CLAUDE.md's version section said, unqualified, that
# every user-facing merge must bump the version "in the same PR". The shipped
# machinery says the opposite for one whole lane: skills/solve-fleet/workflow.js
# FORBIDS every fleet solver from bumping, because N solvers cut off one base
# all resolve the SAME next version and that duplicate edit auto-merges without
# a conflict, silently losing a release. So the rule document convicted the
# fleet PRs that the tooling had just told to stay unbumped — and the review
# convention lens, which cites CLAUDE.md verbatim, filed that contradiction as a
# blocker on a compliant PR (#472). Fixing the prose alone would re-rot: this
# section pins the rule and the machinery to each other, so a future edit to
# either half that leaves the other behind is a red test, not a stale sentence.
#
# NOT LOCKED HERE, deliberately: that the version actually ADVANCED relative to
# the base. The two CI release-ratchet locks (tests/goal.test.sh G20,
# tests/solve-claim.test.sh) are an EQUALITY ratchet — they assert the surfaces
# agree with each other at a hardcoded literal, not that the number went up —
# and the shape-check jobs have no base ref and no `gh` to compare against.
# Tracked as open issue #386.
#
# THE SECTION SLICE. The range OPENS on the section's first BODY line, not on
# its heading. awk closes a `/start/,/end/` range on the START record when that
# record also matches the end pattern, so a `^## Bump version` start forces an
# end pattern that cannot match the heading itself — the previous `^## [^B]` —
# and that pattern is blind to any future sibling heading whose title begins
# with B. Opening one line lower lets the end anchor be a plain `^## `, which
# closes on EVERY sibling section.
#
# STATED PLAINLY, because the scoping is weaker than it looks: CLAUDE.md carries
# exactly ONE level-2 heading today, so this range still runs to end-of-file and
# the anchoring buys nothing until a sibling section is added — it is insurance,
# not a property of the file as it stands. The start anchor is the invariant
# sentence T12.2a/T12.2b already pin; reword it and all eleven in-section
# assertions go red together, loudly, rather than passing over an empty slice.
CLAUDE_SECTION_START='^\*\*Every user-facing change'
CLAUDE_SECTION_END='^## '

# --- the rule half: what CLAUDE.md must say -------------------------------
assert_grep "$CLAUDE_MD" '^## Bump version EVERYWHERE before merge \(MANDATORY\)$' \
  "T12.1 CLAUDE.md still carries the version-bump section heading"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  'landing commit' \
  "T12.2a the invariant is scoped to the LANDING commit, not to every PR"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '(project )?version advanced|advance the (project )?version' \
  "T12.2b the invariant is that the version ADVANCED on main"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '`/goal`' \
  "T12.3a the /goal lane is named"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '`/solve`.*`/turbo`.*fleet' \
  "T12.3b the /solve + /turbo fleet lane is named"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '[Hh]and-authored' \
  "T12.3c the hand-authored lane is named"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  'fleet PR whose diff carries no version surface is compliant' \
  "T12.4 the fleet carve-out is explicit — an unbumped fleet PR is COMPLIANT"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  'skills/solve-fleet/workflow\.js' \
  "T12.4b the carve-out names the file that forbids the solver from bumping"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  'plugins/uberdev/lib/bump-version\.sh' \
  "T12.5 the bump mechanism is named by path"
# Anchored to the numbered-list-item FORM, not a bare path substring: both test
# paths also appear in the local-verification bullet further down the section,
# so a substring match kept passing after the two surface entries themselves
# were deleted — a label ("listed as a surface") wider than its predicate.
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '^[0-9]+\. \*\*`tests/goal\.test\.sh`\*\*' \
  "T12.5b the CI release-ratchet lock tests/goal.test.sh is still a numbered surface-list entry"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  '^[0-9]+\. \*\*`tests/solve-claim\.test\.sh`\*\*' \
  "T12.5c the CI release-ratchet lock tests/solve-claim.test.sh is still a numbered surface-list entry"
assert_in_section "$CLAUDE_MD" "$CLAUDE_SECTION_START" "$CLAUDE_SECTION_END" \
  'No exception' \
  "T12.5d the no-exception clause survives the rewrite"

# --- the machinery half: what the shipped tree must still do --------------
# BOTH of these are GREEN from the first run by design — they are the half the
# rule now describes, so a red here means the DOC is now lying, not that the
# rewrite is incomplete. Non-vacuity is proven separately: repoint either path
# at a nonexistent file and the preflight above exits 2; repoint it at an empty
# file and the assertion FAILS.
#
# There is deliberately NO third "the bump script exists at the path the rule
# names" assertion. $BUMP_VERSION_SH is in the hard-fail preflight loop at the
# top of this file, which exits 2 when it is unreadable, so such a check could
# only ever take its PASS arm — an unreachable FAIL branch that inflates the
# assertion count while locking nothing, and that count is the only signal a
# reader has that this section inspected anything. The preflight owns the
# existence guarantee; T12.12 below is what actually reads the script.
assert_grep "$SOLVE_FLEET_JS" 'Do NOT bump the project version' \
  "T12.6 solve-fleet still forbids the solver from bumping (the collision class stays closed)"
# #516 — the fleet's prompts must not name rule documents this repo does not ship.
# Scoped to $SOLVE_FLEET_JS by PATH: a `grep -r` over plugins/uberdev/ would red on
# five sibling agent files whose `from CLAUDE.md` prose is out of this issue's scope.
# $SOLVE_FLEET_JS is covered by the hard-fail preflight above — the readability
# loop that exits 2 on a missing or unreadable input — which owns that
# guarantee. Named rather than numbered: a same-file line citation in a file
# this size rots on the first insertion above it.
assert_absent_fixed "$SOLVE_FLEET_JS" 'from CLAUDE.md' \
  "T12.6b the solver no longer attributes its baseline to a file this repo does not ship"
assert_absent_fixed "$SOLVE_FLEET_JS" 'Read CLAUDE.md and AGENTS.md' \
  "T12.6c the constraints lens no longer asserts CLAUDE.md/AGENTS.md exist at the repo root"
assert_absent_fixed "$SOLVE_FLEET_JS" 'contradicts CLAUDE.md/AGENTS.md' \
  "T12.6d the spec-review gate no longer asserts those rule documents exist"
# Positive partner for the absence rows: three forbids alone are satisfied by an
# empty prompt. This is the in-repo convention token (agents/research-constraints.md:95).
assert_grep "$SOLVE_FLEET_JS" 'skipping any that do not exist' \
  "T12.6e the constraints lens instructs conditional discovery instead"
assert_grep "$GOAL_WATCH_SH" '_uberdev_goal_ensure_version_bump' \
  "T12.7 the /goal watch lane still calls the version-bump guarantor"

# --- negatives: the retired claims must not come back ---------------------
assert_absent_fixed "$CLAUDE_MD" 'MUST bump the version in every location below' \
  "T12.9 the unqualified every-PR mandate (the sentence #472 was filed against) is gone"
assert_absent_fixed "$CLAUDE_MD" 'single-escaped' \
  "T12.10a the stale single-escaped regex-form description is gone (post-#231 the locks are one assert_version_bump arg)"
assert_absent_fixed "$CLAUDE_MD" 'double-escaped' \
  "T12.10b the stale double-escaped regex-form description is gone"
assert_absent_fixed "$CLAUDE_MD" 'Update all seven locations above' \
  "T12.10c the 'seven locations in one commit' claim is gone (only six are files)"
assert_absent_fixed "$CLAUDE_MD" "Codex's auto-update" \
  "T12.10d the retired Codex auto-update rationale is gone (#381)"

# Shipped-plugin pointers must not send a reader to the gitignored CLAUDE.md
# twin: it exists in no fresh checkout and in no worktree a solver runs in, so
# the ritual it points at is unreadable exactly when it is needed. Scoped to
# $PLUGIN_DIR — a `grep -r` over a SUBDIRECTORY, never a walk rooted at the
# repository root (tests/test-harness-source-guards.test.sh A3), and the dated
# RFC records under docs/rfc/ keep their historical copies untouched.
#
# SCOPE OF THE CLAIM. This is a FIXED-STRING check for one exact phrasing, and
# the PASS line says exactly that and nothing wider. A pointer worded any other
# way is NOT caught: plugins/uberdev/lib/goal-state.sh still attributes the
# release rule to CLAUDE.md in prose above its SemVer step resolver. Widening
# the needle without sweeping that file in the same change would red the suite
# on an offender no rule-document edit can fix — so widen and sweep together,
# never one without the other.
#
# FAIL-LOUD. grep's status is CAPTURED rather than consumed as a boolean, and
# stderr stays attached so the cause reaches the CI log. This is an ABSENCE
# assertion, so the unsafe polarity is the one that had to be handled: rc>=2 (an
# unreadable file, a vanished search root, an I/O fault, a future argument-shape
# mistake) is a FAILED SEARCH, not a clean no-match, and must never land in the
# arm that prints PASS and increments the counter (#275 / #347 house rule: a
# check that could not run is an explicit FAIL, never a silent zero-assertion
# PASS).
CLAUDE_MD_POINTER='project `CLAUDE.md`'
if [ ! -d "$PLUGIN_DIR" ] || [ ! -r "$PLUGIN_DIR" ]; then
  echo "  FAIL  T12.11 the search root is missing or unreadable — refusing a vacuous PASS"
  echo "        root: $PLUGIN_DIR"
  FAIL=$((FAIL + 1))
else
  CLAUDE_MD_HITS="$(grep -rlF -e "$CLAUDE_MD_POINTER" "$PLUGIN_DIR")"
  CLAUDE_MD_RC=$?
  if [ "$CLAUDE_MD_RC" -ge 2 ]; then
    echo "  FAIL  T12.11 the search errored (grep rc=$CLAUDE_MD_RC) — plugins/uberdev/ was NOT checked"
    echo "        root: $PLUGIN_DIR"
    FAIL=$((FAIL + 1))
  elif [ "$CLAUDE_MD_RC" -eq 0 ]; then
    echo "  FAIL  T12.11 a shipped file under plugins/uberdev/ carries the literal '$CLAUDE_MD_POINTER' pointer at the gitignored twin"
    echo "        offenders:"
    printf '%s\n' "$CLAUDE_MD_HITS" | sed 's/^/          /'
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  T12.11 no shipped file under plugins/uberdev/ carries the literal '$CLAUDE_MD_POINTER' pointer"
    PASS=$((PASS + 1))
  fi
fi

assert_grep "$BUMP_VERSION_SH" 'CLAUDE\.md' \
  "T12.12 bump-version.sh's checklist comment names CLAUDE.md as the documented ritual"
assert_absent_fixed "$STRUCTURAL_LIB" 'Codex plugin.json' \
  "T12.13 assert_version_bump's doc comment no longer claims a retired Codex manifest surface"
assert_absent_fixed "$STRUCTURAL_LIB" 'all five manifest surfaces' \
  "T12.13b assert_version_bump's doc comment no longer claims five surfaces (the body asserts four)"
# T12.13/T12.13b are absence-only — they forbid two exact stale literals, a
# predicate disjoint from the drift they exist to stop: a surface added to or
# dropped from the body while the comment stands still (exactly what #382 did),
# or the same stale claim reworded past a fixed-string check. T12.14 closes that
# with the positive pair — the body's own call count, and the comment stating
# the same number.
assert_count "$STRUCTURAL_LIB" '^assert_version_bump' '^}' \
  '_assert_version_bump_one' 4 \
  "T12.14 assert_version_bump's body still asserts exactly four manifest surfaces"
assert_grep "$STRUCTURAL_LIB" 'all four manifest surfaces' \
  "T12.14b the doc comment states the same four-surface count its body asserts"

echo
echo "== T13: precision RFC 0018 §4/§5 describe the stamp the miner implements (#467) =="
# RFC 0018 §5 described the model the code was INTENDED to have, and v0.45.13
# moved the code without moving the prose: three sentences became false and
# nothing noticed, because §5's body carried no positive assertion at all.
#
# Absence and positive rows come in PAIRS here, deliberately. An absence-only
# predicate is disjoint from the drift it must catch — a false claim reworded
# past a fixed-string forbid sails through — which is the same shape as the
# stamp hole this section documents. Each forbid below therefore has a positive
# twin asserting what the prose must now say instead.
#
# Every positive needle is a SINGLE-LINE substring of the authored prose: the
# sentences it targets span line breaks, and a needle that crosses a wrap can
# never match.
assert_grep "$PRECISION_RFC" 'unmeasured_digests' \
  "T13.1 the precision RFC names the unmeasured_digests field the miner reads"
assert_grep "$PRECISION_RFC" 'carries a sha256 in one of two fields' \
  "T13.2 §5 states every surface carries a digest in one of two fields"
assert_grep "$PRECISION_RFC" 'a post-declaration edit of a declared-unmeasured surface reds' \
  "T13.3 §5 states a declared-unmeasured surface still reds on a post-declaration edit"
assert_grep "$PRECISION_RFC" 'tethered by the anti-parking rule' \
  "T13.4 §5 states what the MEASURED declaration branch is tethered to"
assert_absent_fixed "$PRECISION_RFC" 'records the sha256 of' \
  "T13.5 the false 'records the sha256 of every reviewer prompt surface' claim is gone (two of eight carry no measured digest by design)"
assert_absent_fixed "$PRECISION_RFC" 'also fails the check, so the list cannot accumulate' \
  "T13.5b the unqualified anti-parking claim is gone (it never fired for an unstamped-declared path)"
assert_absent_fixed "$PRECISION_RFC" 'in a second tuple in the miner' \
  "T13.6 the 'a second tuple in the miner is a second roster' claim is gone (SHARED_PROMPT_SURFACES is exactly that, by design)"
assert_grep "$PRECISION_RFC" 'SHARED_PROMPT_SURFACES.* is the one irreducible enumeration' \
  "T13.6b §5 names SHARED_PROMPT_SURFACES and says why it is the one irreducible enumeration"
assert_grep "$PRECISION_MINER" 'unmeasured_digests' \
  "T13.7 the RFC's unmeasured_digests symbol resolves in the shipped miner"

echo
echo "== T14: solve-fleet CB1 and the design-chain docs agree with the script (#507) =="
# The fleet script IS the design chain; SKILL.md and RFC 0015 each restate it in
# prose, and both restate the CB1 projection (1 + issues + N*designCount) with N
# as a LITERAL. #507 threads the reviewer findings into the plan writer without
# moving N — but the deferred follow-up (a plan reviewer) moves it by one, and
# this join is what makes that edit safe: change N in the script and the two
# docs go red instead of silently disagreeing.
#
# T14.1-T14.3 pass on the pre-#507 tree by construction; they are the ratchet.
# T14.4-T14.6 are the red-first rows — they name the hand-off the script now
# performs, which the prose described as going nowhere.
# #508 replaced the per-design-tier LITERAL with an expression — the implement
# phase is now a per-task chain bounded by CB3's budget, so the script reads
# `designCount * (6 + IMPLEMENT_AGENT_BUDGET - 1)`. The join therefore moved from
# a number to a TERM, and it still has to hold in both directions: edit the term
# in the script and the two docs go red rather than silently disagreeing.
#
# Two spellings are normalised rather than duplicated: the docs name the envelope
# key (`implementBudget`) instead of the script's internal constant, and they use
# U+2212 MINUS where JS uses ASCII hyphen. Everything else must match byte for
# byte.
SF_TERM="$(sed -n 's/.*designCount \* (\([^)]*\)).*/\1/p' "$SOLVE_FLEET_JS" | tr -d '\r')"
# EXACTLY one line, for the reason the constant form had: two differing terms
# would build a needle that can never match, and the row would fail for the wrong
# reason. tr -d '\r' because this path is not covered by .gitattributes
# (hooks-scoped) and the value is spliced straight into a needle.
SF_TERM_LINES="$(grep -c '' <<<"$SF_TERM")"
SF_DOC_TERM="$(printf '%s' "$SF_TERM" \
  | sed 's/IMPLEMENT_AGENT_BUDGET/implementBudget/g; s/ - / − /g')"
if [ "$SF_TERM_LINES" = "1" ] && [ -n "$SF_TERM" ]; then
  echo "  PASS  T14.1 a single designCount * (…) term resolves in the fleet script ($SF_TERM)"
  PASS=$((PASS + 1))
  # FIXED-string: the term carries `(`, `)` and `+`, every one of them an ERE
  # metacharacter, so assert_grep would match a pattern rather than the text.
  assert_grep_fixed_docs "$SOLVE_FLEET_SKILL" "(${SF_DOC_TERM}) × design-tier issues" \
    "T14.2 SKILL.md CB1 row restates the fleet script term ($SF_DOC_TERM)"
  assert_grep_fixed_docs "$DISPATCH15_RFC" "(${SF_DOC_TERM}) × design-tier issues" \
    "T14.3 RFC 0015 CB1 row restates the fleet script term ($SF_DOC_TERM)"
else
  echo "  FAIL  T14.1 designCount * (…) did not resolve to exactly one term (lines=$SF_TERM_LINES, got: $SF_TERM)"
  FAIL=$((FAIL + 1))
fi

# The chain rows must name the hand-off the script performs. Single-line needle:
# assert_grep cannot match across an authored line wrap.
assert_grep "$SOLVE_FLEET_SKILL" 'blocking findings are forwarded to the plan writer' \
  "T14.4 SKILL.md chain row names the spec-review findings hand-off"
assert_grep "$DISPATCH15_RFC" 'blocking findings are forwarded to the plan writer' \
  "T14.5 RFC 0015 chain row names the spec-review findings hand-off"

# R-2 recorded the design chain as a lossy translation of /uberdev:orchestrator.
# It must no longer read as though the reviewer output goes nowhere.
assert_in_section "$DISPATCH15_RFC" '^- \*\*R-2 — medium-tier fidelity' '^- \*\*R-3' \
  'blocking findings' \
  "T14.6 RFC 0015 R-2 records that the reviewer findings ARE threaded"

# #524 item 1. Both chain rows already claimed "one revision round" while NO
# reviser was ever dispatched — a doc statement about a rung that did not exist.
# The rows below need a needle the pre-#524 prose cannot satisfy, so they name
# the artifact the round writes: a versioned sibling, never an in-place rewrite
# of spec.md. That is the load-bearing half (the script cannot stat, so a
# truncated in-place spec would be indistinguishable from a good one), which is
# exactly the half a reader must not have to infer.
#
# Anchored to the design-rung TIER ROW, not to the file: each doc describes the
# chain in exactly one line, and a file-wide needle would let the claim drift
# into a footnote while the row a reader actually consults stayed stale.
assert_grep "$SOLVE_FLEET_SKILL" '^\| .medium..*spec-r1\.md' \
  "T14.7 SKILL.md chain row names the versioned artifact the bounded revision round writes"
assert_grep "$DISPATCH15_RFC" '^\| .medium..*spec-r1\.md' \
  "T14.8 RFC 0015 chain row names the same versioned revision artifact"

# #524 item 2. Naming the plan REVIEWER is not enough on its own: the rung has
# no reviser, so its findings ARE its whole output and a chain row that says a
# plan reviewer runs, without saying where what it finds goes, describes a stage
# that could be theatre. Both halves are therefore in the one anchored needle.
# Same TIER-ROW anchor as T14.7/T14.8, for the same reason.
assert_grep "$SOLVE_FLEET_SKILL" '^\| .medium..*plan reviewer.*implementer, task reviewer and fixer' \
  "T14.9a SKILL.md chain row names the plan reviewer AND the three rungs its findings reach"
assert_grep "$DISPATCH15_RFC" '^\| .medium..*plan reviewer.*implementer, task reviewer and fixer' \
  "T14.9b RFC 0015 chain row names the plan reviewer AND the three rungs its findings reach"

# R-2 is the RFC's own register of what the translation still LOSES. It named
# the plan reviewer as the gap that remained; shipping the gate without moving
# it leaves the document asserting the opposite of the code. Positive and
# absence rows in a PAIR (the T13 doctrine): an absence-only predicate is
# disjoint from the drift it must catch, and a positive-only one passes while
# the stale sentence sits two lines below it.
assert_in_section "$DISPATCH15_RFC" '^- \*\*R-2 — medium-tier fidelity' '^- \*\*R-3' \
  '#524 item 2 closed the plan-review gap' \
  "T14.10 RFC 0015 R-2 records that the plan review gate now exists"
# Sliced, then guarded on non-emptiness: an awk range whose anchors were renamed
# yields nothing, and grep over nothing is a PASS that inspected no bytes (#347).
R2_SECTION="$(awk '/^- \*\*R-2 — medium-tier fidelity/,/^- \*\*R-3/' "$DISPATCH15_RFC")"
if [ -z "$R2_SECTION" ]; then
  echo "  FAIL  T14.10b the R-2 slice is EMPTY — its anchors are gone, and an absence check over nothing passes vacuously"
  FAIL=$((FAIL + 1))
elif grep -qF 'What remains missing is the' <<<"$R2_SECTION"; then
  echo "  FAIL  T14.10b R-2 still names a remaining missing design rung — the plan reviewer ships in #524 item 2"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T14.10b R-2 no longer describes a design-review rung as missing"
  PASS=$((PASS + 1))
fi

# #524 item 3. The security lens is the first CONDITIONAL research rung, and the
# condition lives in another file: lib/solve-launcher.sh's triage `risk_signals`,
# carried one hop through the manifest record and joined run-wide by the
# `riskIssueCount` envelope key. Three separate statements, so three rows —
# naming the lens while leaving the gate undocumented would describe a fan-out
# that reads as unconditional, which is precisely the design this change
# rejected, and an operator reading the envelope table would find a key the
# launcher sends and the doc does not admit to.
#
# Same TIER-ROW anchor as T14.7-T14.9 for the chain rows, for the same reason:
# each doc describes the chain in exactly one line, and a file-wide needle lets
# the claim drift into a footnote while the row a reader consults stays stale.
assert_grep "$SOLVE_FLEET_SKILL" '^\| .medium..*security. lens.*risk_signals' \
  "T14.11a SKILL.md chain row names the security lens AND the triage field that gates it"
assert_grep "$DISPATCH15_RFC" '^\| .medium..*security. lens.*risk_signals' \
  "T14.11b RFC 0015 chain row names the same risk-gated lens"
assert_grep "$SOLVE_FLEET_SKILL" 'one record per issue.*risk_signals' \
  "T14.11c SKILL.md records that the manifest record carries risk_signals — the one hop the value crosses"
assert_grep "$SOLVE_FLEET_SKILL" '^\| .riskIssueCount. \|' \
  "T14.11d SKILL.md envelope-keys table documents riskIssueCount"

echo "== T15: RFC 0013 §13 <-> run_manifest.py ALLOWED_FIELDS, compared both directions (#518) =="
# Extraction. The RFC's field list lives in a ```text fence that does NOT
# immediately follow its anchor line — there is a blank line between them — so
# an extractor that reads anchor+1 as the fence collects ZERO names and every
# case below goes vacuously green. Scan forward to the first fence line instead,
# and let T15.1 hard-fail on a short list rather than trusting the scan.
#
# awk does all the splitting and all the iteration: no `for n in $var` (zsh runs
# that once over the whole string), and comparison is per-name `grep -qxF`
# against a herestring rather than a whole-variable equality check — herestrings
# because this file sets `-o pipefail` and is inside epipe-guard.test.sh's scan
# set, and per-name because a `$( )` capture can retain embedded CRs on Git Bash.
RFC_FIELDS="$(awk '
  # `[[:space:]]*$` not a bare `$`: .gitattributes pins eol=lf only under
  # plugins/uberdev/hooks/, and the windows job checks out core.autocrlf=true,
  # so this RFC can arrive CRLF. POSIX [[:space:]] includes CR, so this anchor
  # holds whether or not the resolved awk shows us the CR. Same idiom as the
  # `^jobs:[[:space:]]*$` anchor earlier in this file.
  /^Append-only JSONL events MUST support:[[:space:]]*$/ { seek = 1; next }
  seek && /^```/                             { seek = 0; inf = 1; next }
  inf  && /^```/                             { inf = 0; next }
  inf {
    gsub(/[,\r]/, " ")
    n = split($0, parts, /[ \t]+/)
    for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
  }
' "$ADAPTIVE_RFC")"
CODE_FIELDS="$(awk '
  /^ALLOWED_FIELDS = frozenset\(/ { inf = 1; next }
  inf && /^\)/                    { inf = 0; next }
  inf {
    line = $0
    while (match(line, /"[a-z_][a-z0-9_]*"/)) {
      print substr(line, RSTART + 1, RLENGTH - 2)
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$RUN_MANIFEST_PY")"

RFC_FIELD_N=0
while IFS= read -r _f; do [ -n "$_f" ] && RFC_FIELD_N=$((RFC_FIELD_N + 1)); done <<<"$RFC_FIELDS"
CODE_FIELD_N=0
while IFS= read -r _f; do [ -n "$_f" ] && CODE_FIELD_N=$((CODE_FIELD_N + 1)); done <<<"$CODE_FIELDS"

# T15.1 — anti-vacuity. This case exists because a silent zero-name extraction
# would make T15.2 and T15.3 pass while comparing nothing at all.
if [ "$RFC_FIELD_N" -ge 30 ] && [ "$CODE_FIELD_N" -ge 30 ]; then
  echo "  PASS  T15.1 both field lists extracted (RFC §13: $RFC_FIELD_N, ALLOWED_FIELDS: $CODE_FIELD_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T15.1 setup error: RFC 0013 §13 fence not found — anchor moved?"
  echo "        RFC §13 names extracted:     $RFC_FIELD_N (expected >= 30)"
  echo "        ALLOWED_FIELDS names parsed: $CODE_FIELD_N (expected >= 30)"
  echo "        rfc: $ADAPTIVE_RFC"
  echo "        code: $RUN_MANIFEST_PY"
  FAIL=$((FAIL + 1))
fi

# T15.2 — forward. Every field the RFC promises must be accepted by the code.
# A missing one means the manifest writer hard-rejects an event the RFC says
# MUST be supported.
T15_MISSING=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  grep -qxF -- "$_f" <<<"$CODE_FIELDS" || T15_MISSING="$T15_MISSING $_f"
done <<<"$RFC_FIELDS"
if [ -z "$T15_MISSING" ]; then
  echo "  PASS  T15.2 every RFC 0013 §13 field is a member of ALLOWED_FIELDS ($RFC_FIELD_N/$RFC_FIELD_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T15.2 RFC 0013 §13 declares fields ALLOWED_FIELDS would reject as unknown_field"
  echo "        missing from run_manifest.py:$T15_MISSING"
  FAIL=$((FAIL + 1))
fi

# T15.3 — reverse. Every ALLOWED_FIELDS member is either in the RFC or in the
# exemption roster below. The roster is a literal fenced list, not a regex, for
# two reasons: adding an exemption becomes a reviewable diff, and a member
# silently DELETED from ALLOWED_FIELDS also reds here.
# === BEGIN run-manifest process-metadata exemptions ===
# These six are the "plus the minimal process metadata required to reconcile an
# interrupted agent_started event" half of run_manifest.py's own comment. They
# are intentionally absent from RFC 0013 §13, which specifies the event schema,
# not the reconciliation bookkeeping.
T15_EXEMPT="agent_id
backend_handle
owner_pid
owner_process_identity
status_path
timeout_s"
# === END run-manifest process-metadata exemptions ===
T15_EXTRA=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  grep -qxF -- "$_f" <<<"$RFC_FIELDS" && continue
  grep -qxF -- "$_f" <<<"$T15_EXEMPT" || T15_EXTRA="$T15_EXTRA $_f"
done <<<"$CODE_FIELDS"
T15_STALE_EXEMPT=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  grep -qxF -- "$_f" <<<"$CODE_FIELDS" || T15_STALE_EXEMPT="$T15_STALE_EXEMPT $_f"
done <<<"$T15_EXEMPT"
if [ -z "$T15_EXTRA" ] && [ -z "$T15_STALE_EXEMPT" ]; then
  echo "  PASS  T15.3 every ALLOWED_FIELDS member is in RFC 0013 §13 or the pinned process-metadata roster"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T15.3 ALLOWED_FIELDS and RFC 0013 §13 have drifted"
  [ -n "$T15_EXTRA" ] && echo "        in the code, in neither the RFC nor the exemption roster:$T15_EXTRA"
  [ -n "$T15_STALE_EXEMPT" ] && echo "        exempted here but no longer in ALLOWED_FIELDS:$T15_STALE_EXEMPT"
  FAIL=$((FAIL + 1))
fi

# T15.4 — the `cache_hit` tombstone. The field is normatively declared by RFC
# 0013 §13 and bool-validated by run_manifest.py, but has zero producers: the
# artifact-reuse short-circuit that would have set it was deleted in #308.
# Keeping it is the right call (an Accepted RFC promises it, and removing it is
# a schema NARROWING that turns an out-of-tree producer's event into a hard
# rc=2 unknown_field) — but keeping it SILENTLY is what let it rot. Require the
# entry AND a RESERVED marker inside the frozenset literal, so the next reader
# learns why a validated field never appears in any manifest.
FROZEN_BODY="$(awk '
  /^ALLOWED_FIELDS = frozenset\(/ { inf = 1; next }
  inf && /^\)/                    { inf = 0; next }
  inf                             { print }
' "$RUN_MANIFEST_PY")"
if [ -z "$FROZEN_BODY" ]; then
  echo "  FAIL  T15.4 setup error: ALLOWED_FIELDS frozenset literal not found in run_manifest.py"
  echo "        file: $RUN_MANIFEST_PY"
  FAIL=$((FAIL + 1))
elif ! grep -qF -- '"cache_hit",' <<<"$FROZEN_BODY"; then
  echo "  FAIL  T15.4 cache_hit was dropped from ALLOWED_FIELDS — that is a schema narrowing"
  echo "        RFC 0013 §13 still lists it; removing it here rejects a field the RFC promises"
  FAIL=$((FAIL + 1))
elif ! grep -qE 'RESERVED' <<<"$FROZEN_BODY"; then
  echo "  FAIL  T15.4 cache_hit carries no RESERVED marker inside the ALLOWED_FIELDS literal"
  echo "        file: $RUN_MANIFEST_PY"
  echo "        a validated field with zero producers must say so where it is declared (#518)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T15.4 cache_hit is retained in ALLOWED_FIELDS and marked RESERVED at the declaration"
  PASS=$((PASS + 1))
fi

echo
echo "== T16: solve-fleet SKILL.md <-> workflow.js per-task record, compared both directions (#558) =="
# SKILL.md is the ONLY declaration of the per-task record the fleet publishes,
# and it was minted already wrong: it declared an EMPTY STRING for the no-gate
# verdict where every construction and every mutation site in the script writes
# the named sentinel NOT_APPLICABLE, and it omitted the preserved-claim field,
# the completeness flag and the partial-delivery object outright. A consumer
# written against the documented union matched nothing on the no-gate path and
# read the real value as an unknown member.
#
# Nothing compared the two spellings — the uncompared-copies class (#370) — so
# this section joins them the way T15 joins RFC 0013 §13 to ALLOWED_FIELDS: in
# BOTH directions, so a member gained on either side reds the other instead of
# drifting silently. Every row below is red on the pre-#558 doc (measured: it
# yielded `""` and no NOT_APPLICABLE, no claimedStatus, and no partial-delivery
# members at all).

# --- extraction ------------------------------------------------------------
# Doc side. The return-value fence and the verdict sentence are hand-wrapped
# prose, so this BUFFERS across the authored line wrap instead of reading one
# line: a one-line reader goes silently empty on a re-wrap, which is the
# vacuous-green shape T15.1 exists to stop. Members are whatever sits between
# the anchor and the first CLOSER after it (optionally skipping to an OPENER
# first, for the backtick-quoted verdict union), split on commas, pipes and
# whitespace. `sort -u` on the way out: these are SET comparisons, and a member
# spelled twice is not a second member.
sf_doc_members() {   # <file> <anchor> <closer> [<opener>]
  tr -d '\r' < "$1" | awk -v anchor="$2" -v closer="$3" -v opener="${4:-}" '
    {
      if (fin) next
      if (!cap) {
        p = index($0, anchor)
        if (p == 0) next
        cap = 1
        buf = substr($0, p + length(anchor))
      } else {
        buf = buf " " $0
      }
      seg = buf
      if (opener != "") {
        o = index(seg, opener)
        if (o == 0) next
        seg = substr(seg, o + length(opener))
      }
      e = index(seg, closer)
      if (e == 0) next
      seg = substr(seg, 1, e - 1)
      gsub(/[,|]/, " ", seg)
      m = split(seg, parts, /[ \t]+/)
      for (i = 1; i <= m; i++) if (parts[i] != "") print parts[i]
      fin = 1
    }
  ' | sort -u
}
# Script side, normalised ONCE. Every extraction below reads one of these three
# forms instead of respawning the same four-command prefix over a ~3200-line
# file at each site:
#
#   SF_JS_SRC    `//` comments and CRs stripped, LINES PRESERVED — what the
#                depth-tracking reader below needs, since it is line-oriented.
#   SF_JS_FLAT   the same text collapsed onto one line, which is what lets a
#                single ERE span an authored wrap.
#   SF_JS_GLUED  SF_JS_FLAT with the JS string-concatenation glue removed, for
#                the prompt copies that are split across a wrap by `" + "`.
#
# `//` comments go BEFORE the newlines collapse — the taskRec literal carries
# four comment lines, and prose ending in a colon ("… as the PR-claim pass
# below:") otherwise reads as a key.
#
# Fed to the greps by HERESTRING, never by pipe: this file sets `-o pipefail`
# and is inside epipe-guard.test.sh's scan set, which is the same reason
# sf_member_count further down reads a herestring.
SF_JS_SRC="$(sed 's|//.*||' "$SOLVE_FLEET_JS" | tr -d '\r')"
SF_JS_FLAT="$(tr '\n' ' ' <<<"$SF_JS_SRC")"
SF_JS_GLUED="$(sed 's/"[[:space:]]*+[[:space:]]*"//g' <<<"$SF_JS_FLAT")"

# `[^{}]*` keeps each match inside a single brace-free literal, and these
# records nest nothing. Braces are spelled `[{]`/`[}]` and never `\{`/`\}`: an
# escaped brace in an ERE is undefined by POSIX and GNU grep 3.8+ warns on stray
# escapes, so the bracket expression is the form that means the same thing to
# every grep CI resolves.
sf_js_keys() {       # <ERE matching the whole object literal>
  grep -oE "$1" <<<"$SF_JS_FLAT" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*:' | tr -d ':' | sort -u
}
# Script side, DEPTH-TRACKING. sf_js_keys' `[^{}]*` window is a brace-free
# literal by construction, and the objects joined below break it: finalize()'s
# return nests `counts` and `verification`, and `counts` nests a per-bucket
# `function (r) { … }` predicate of its own. `verification` carries no brace
# today and sf_js_keys could still read it — it is read here anyway, so that
# every object of one pass is extracted by ONE rule instead of by whichever
# helper each object's current contents happen to permit. Same depth-0 rule as
# sf_doc_record_members further down: a nested object appears by KEY NAME and
# never by its members.
#
# TWO anchors, each matched as an ERE against a whole line: the first ARMS the
# scan at the enclosing function definition, the second OPENS the object. One
# anchor cannot do it — `return [{]` is spelled at several sites in this script,
# and a file-wide first-match reader would slice whichever of them comes first.
# `counts: [{]` and `verification: [{]` do resolve uniquely today and are given
# the same two-anchor treatment regardless: a nested key name is not a scarce
# string, and the arming anchor is what makes a row say WHICH object it read
# rather than whichever copy happened to come first. Neither anchor may carry a
# backslash escape: awk resolves escapes in a `-v` assignment before the regex
# ever sees them (warning about it on some builds), so a literal brace is
# spelled `[{]` and a literal parenthesis is left out of the pattern altogether.
sf_js_object_keys() {   # <arming ERE> <opening ERE>
  awk -v arm="$1" -v opener="$2" '
    { if (fin) next
      if (!armed) { if ($0 ~ arm) armed = 1; next }
      if (!cap) { if ($0 !~ opener) next
                  p = index($0, "{"); if (p == 0) next
                  cap = 1; line = substr($0, p + 1) }
      else { line = $0 }
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "{" || c == "[") { depth++; continue }
        if (c == "}" || c == "]") { if (depth == 0) { fin = 1; break } depth--; continue }
        if (depth == 0) buf = buf c
      }
      if (fin) print buf
    }
  ' <<<"$SF_JS_SRC" | grep -oE '[A-Za-z_][A-Za-z0-9_]*:' | tr -d ':' | sort -u
}
# Count and set-difference, factored: every comparison below reads them, and one
# copy of this loop per comparison is the very class this section exists to
# police. Herestrings, not pipes — this file sets `-o pipefail` and is inside
# epipe-guard.test.sh's scan set, where a `printf | grep -q` writer takes EPIPE
# and poisons the rc.
sf_member_count() {  # <newline-separated list>
  local _n=0 _line
  while IFS= read -r _line; do [ -n "$_line" ] && _n=$((_n + 1)); done <<<"$1"
  printf '%s' "$_n"
}
sf_members_absent() {  # <needles> <haystack> -> space-prefixed missing members
  local _out="" _m
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    grep -qxF -- "$_m" <<<"$2" || _out="$_out $_m"
  done <<<"$1"
  printf '%s' "$_out"
}

# Same rule as the _lib_assert_structural.sh guard near the top of this file,
# and for the same reason — this file has no errexit and no assertion floor, so
# a helper that is renamed, moved or typo'd at a call site fails with
# command-not-found (rc 127), which increments NEITHER counter. Every row below
# is of the shape `X="$(sf_… )"; [ -z "$X" ]`, so a missing helper yields the
# empty string, which reads as "no violations found" and prints PASS while
# asserting nothing. Verified: renaming sf_members_absent alone left this file at
# `259 passed, 0 failed`, rc 0, with 8 command-not-found errors on stderr and a
# fabricated 19/19 in the row text.
#
# The guard sits HERE rather than beside the other one because these helpers are
# defined further down the file than that loop runs.
for _sf_fn in sf_doc_members sf_js_keys sf_js_object_keys sf_member_count sf_members_absent; do
  command -v "$_sf_fn" >/dev/null 2>&1 || {
    echo "FATAL: solve-fleet doc-join helper $_sf_fn is not defined (renamed, or a typo'd call site) — every row that calls it would report PASS having asserted nothing" >&2
    exit 2
  }
done

# The per-task record. On the script side that is every literal built with an
# `id:` key and a `reviewVerdict:` key, PLUS every field assigned onto `taskRec`
# afterwards — a field introduced only by mutation is still a published field,
# and `=[^=]` keeps the `===` comparisons out.
SF_DOC_TASK_FIELDS="$(sf_doc_members "$SOLVE_FLEET_SKILL" 'tasks: [{' '}')"
SF_JS_TASK_FIELDS="$({ sf_js_keys '[{] *id: [^{}]*reviewVerdict:[^{}]*[}]'
  grep -oE 'taskRec\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[^=]' "$SOLVE_FLEET_JS" \
    | tr -d '\r' | sed 's/^taskRec\.//; s/[[:space:]]*=.*$//'; } | sort -u)"
SF_DOC_TASK_N="$(sf_member_count "$SF_DOC_TASK_FIELDS")"
SF_JS_TASK_N="$(sf_member_count "$SF_JS_TASK_FIELDS")"

# T16.1 — anti-vacuity. A silent zero-name extraction on either side would make
# T16.2 and T16.3 pass while comparing nothing at all.
if [ "$SF_DOC_TASK_N" -ge 5 ] && [ "$SF_JS_TASK_N" -ge 5 ]; then
  echo "  PASS  T16.1 both per-task field lists extracted (SKILL.md: $SF_DOC_TASK_N, workflow.js: $SF_JS_TASK_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.1 setup error: the per-task record did not extract from both sides"
  echo "        SKILL.md 'tasks: [{...}]' members: $SF_DOC_TASK_N (expected >= 5) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js record fields:        $SF_JS_TASK_N (expected >= 5) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.2 — forward. A documented field the script never writes is a field a
# consumer will read as undefined on every record.
T16_TASK_MISSING="$(sf_members_absent "$SF_DOC_TASK_FIELDS" "$SF_JS_TASK_FIELDS")"
if [ -z "$T16_TASK_MISSING" ]; then
  echo "  PASS  T16.2 every per-task field SKILL.md documents is one workflow.js writes ($SF_DOC_TASK_N/$SF_DOC_TASK_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.2 SKILL.md documents per-task field(s) no task record carries"
  echo "        absent from workflow.js:$T16_TASK_MISSING"
  FAIL=$((FAIL + 1))
fi

# T16.3 — reverse. This is the half that caught #558: `claimedStatus` was minted
# on every record and named in no doc.
T16_TASK_EXTRA="$(sf_members_absent "$SF_JS_TASK_FIELDS" "$SF_DOC_TASK_FIELDS")"
if [ -z "$T16_TASK_EXTRA" ]; then
  echo "  PASS  T16.3 every per-task field workflow.js writes is documented in SKILL.md ($SF_JS_TASK_N/$SF_JS_TASK_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.3 workflow.js publishes per-task field(s) SKILL.md never declares"
  echo "        undocumented:$T16_TASK_EXTRA"
  FAIL=$((FAIL + 1))
fi

# The reviewVerdict union. What can land in the field is either a literal
# assigned at a `reviewVerdict` site, or the reviewer's verdict — and that one
# is closed by the ternary right above the assignment, whose arms are the
# `rev.verdict ===` comparisons (anything outside them is coerced to
# REVISIONS_REQUIRED). Both sources, one set.
SF_DOC_VERDICTS="$(sf_doc_members "$SOLVE_FLEET_SKILL" '`reviewVerdict`' '`' '`')"
SF_JS_VERDICTS="$(grep -oE '(reviewVerdict|rev\.verdict)[^"]*"[A-Z][A-Z0-9_]*"' "$SOLVE_FLEET_JS" \
  | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"\r' | sort -u)"
SF_DOC_VERDICT_N="$(sf_member_count "$SF_DOC_VERDICTS")"
SF_JS_VERDICT_N="$(sf_member_count "$SF_JS_VERDICTS")"

# T16.4 — anti-vacuity for the union. The doc-side anchor is the first
# backticked `reviewVerdict` mention; if it ever stops being the union
# declaration, the extraction shrinks and this row says so rather than letting
# T16.5/T16.6 compare a fragment.
if [ "$SF_DOC_VERDICT_N" -ge 4 ] && [ "$SF_JS_VERDICT_N" -ge 4 ]; then
  echo "  PASS  T16.4 both reviewVerdict unions extracted (SKILL.md: $SF_DOC_VERDICT_N, workflow.js: $SF_JS_VERDICT_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.4 setup error: the reviewVerdict union did not extract from both sides"
  echo "        SKILL.md members:    $SF_DOC_VERDICT_N (expected >= 4) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_VERDICT_N (expected >= 4) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.5 — forward. The #558 defect itself: the doc declared `""` for the no-gate
# case, which the script never writes, so a consumer matching it matched nothing.
T16_VERDICT_MISSING="$(sf_members_absent "$SF_DOC_VERDICTS" "$SF_JS_VERDICTS")"
if [ -z "$T16_VERDICT_MISSING" ]; then
  echo "  PASS  T16.5 every documented reviewVerdict member is one workflow.js can write ($SF_DOC_VERDICT_N/$SF_DOC_VERDICT_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.5 SKILL.md declares reviewVerdict member(s) workflow.js never writes"
  echo "        absent from workflow.js:$T16_VERDICT_MISSING"
  echo "        (the no-gate case is the named sentinel NOT_APPLICABLE, never an empty string)"
  FAIL=$((FAIL + 1))
fi

# T16.6 — reverse. A verdict the script can write and the doc omits is a value
# a consumer's switch has no arm for.
T16_VERDICT_EXTRA="$(sf_members_absent "$SF_JS_VERDICTS" "$SF_DOC_VERDICTS")"
if [ -z "$T16_VERDICT_EXTRA" ]; then
  echo "  PASS  T16.6 every reviewVerdict workflow.js can write is documented in SKILL.md ($SF_JS_VERDICT_N/$SF_JS_VERDICT_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.6 workflow.js can write reviewVerdict value(s) SKILL.md never declares"
  echo "        undocumented:$T16_VERDICT_EXTRA"
  FAIL=$((FAIL + 1))
fi

# The partial-delivery object, same join. It is the only machine-readable record
# of a PR opened over an UNFINISHED chain, so an undocumented member is a fact
# /goal's reader cannot know to look for.
SF_DOC_PARTIAL="$(sf_doc_members "$SOLVE_FLEET_SKILL" 'partialDelivery: {' '}')"
SF_JS_PARTIAL="$(sf_js_keys 'partialDelivery = [{][^{}]*[}]')"
SF_DOC_PARTIAL_N="$(sf_member_count "$SF_DOC_PARTIAL")"
SF_JS_PARTIAL_N="$(sf_member_count "$SF_JS_PARTIAL")"
if [ "$SF_DOC_PARTIAL_N" -ge 3 ] && [ "$SF_JS_PARTIAL_N" -ge 3 ]; then
  echo "  PASS  T16.7 both partialDelivery member lists extracted (SKILL.md: $SF_DOC_PARTIAL_N, workflow.js: $SF_JS_PARTIAL_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.7 setup error: partialDelivery did not extract from both sides"
  echo "        SKILL.md members:    $SF_DOC_PARTIAL_N (expected >= 3) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_PARTIAL_N (expected >= 3) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi
T16_PARTIAL_MISSING="$(sf_members_absent "$SF_DOC_PARTIAL" "$SF_JS_PARTIAL")"
T16_PARTIAL_EXTRA="$(sf_members_absent "$SF_JS_PARTIAL" "$SF_DOC_PARTIAL")"
if [ -z "$T16_PARTIAL_MISSING" ] && [ -z "$T16_PARTIAL_EXTRA" ]; then
  echo "  PASS  T16.8 SKILL.md and workflow.js agree on the partialDelivery members, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.8 the documented partialDelivery object and the one workflow.js builds have drifted"
  [ -n "$T16_PARTIAL_MISSING" ] && echo "        documented but never built:$T16_PARTIAL_MISSING"
  [ -n "$T16_PARTIAL_EXTRA" ] && echo "        built but never documented:$T16_PARTIAL_EXTRA"
  FAIL=$((FAIL + 1))
fi

# The ENCLOSING per-issue record. `chainComplete` has no members of its own, so
# it was previously guarded by a whole-file `assert_grep` — a predicate scoped
# to a DIFFERENT surface than the contract it guards: SKILL.md spells the symbol
# twice (the normative fence AND the prose that explains it), so deleting it
# from the published fence left the row green. Joining the record it belongs to
# makes the flag an ordinary member and removes the need for a grep (#558).
#
# Doc side needs DEPTH tracking, unlike sf_doc_members above: this record nests
# `partialDelivery: {...}` and `tasks: [{...}]`, and a first-closer reader would
# stop inside the first nested object. Only depth-0 tokens are emitted, so the
# nested objects appear by KEY NAME and never by their members. A depth tracker
# that BREAKS fails loudly on T16.10, the forward row: the over-collected
# members (tasksTotal, blocked, skipped, unreviewed) land on the DOC side, and
# the script writes none of them.
#
# The OPTIONAL third argument mirrors the one sf_doc_members takes, and for the
# same reason: an anchor whose own text already contains the opening brace can
# be given alone, but the `## Return value` fence opens on its own line BELOW
# the sentence that introduces it, so there the anchor and the brace cannot be
# one string. Given an opener, everything up to and including the first one
# after the anchor is skipped and the depth-0 read starts there; omitted, the
# behaviour is exactly what the two-argument callers above already get.
sf_doc_record_members() {   # <file> <anchor> [<opener>]
  tr -d '\r' < "$1" | awk -v anchor="$2" -v opener="${3:-}" '
    { if (fin) next
      if (!cap) { p = index($0, anchor); if (p == 0) next
                  cap = 1; line = substr($0, p + length(anchor)) }
      else { line = $0 }
      if (opener != "" && !armed) { o = index(line, opener); if (o == 0) next
                                    armed = 1; line = substr(line, o + length(opener)) }
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "{" || c == "[") { depth++; continue }
        if (c == "}" || c == "]") { if (depth == 0) { fin = 1; break } depth--; continue }
        if (depth == 0) buf = buf c
      }
      if (fin) { gsub(/[,|]/, " ", buf)
                 m = split(buf, parts, /[ \t]+/)
                 for (j = 1; j <= m; j++) { gsub(/:$/, "", parts[j])
                   if (parts[j] != "") print parts[j] } }
    }
  ' | sort -u
}


# Same fail-open rule as the sf_* guard above; this helper is defined below that
# loop, so it needs its own check before its first call site.
command -v sf_doc_record_members >/dev/null 2>&1 || {
  echo "FATAL: solve-fleet doc-join helper sf_doc_record_members is not defined (renamed, or a typo'd call site) — every row that calls it would report PASS having asserted nothing" >&2
  exit 2
}

# === BEGIN T16 citation block ===
# Script side: the unpushedIssue() literal UNION every assignment matching the
# pattern `out.<f> =` or the pattern `r.<f> =` — the same construction-plus-
# mutation shape T16.1–T16.3 already uses for `taskRec.`, and the pattern
# `=[^=]` keeps the `===` comparisons out.
#
# Every reference below is a SYMBOL or a quoted code fragment, and every regex
# or placeholder example is marked by the word pattern in front of it. That
# marker is what T18.10c reads: a shape that resolves nowhere BY CONSTRUCTION is
# excluded by how it is written, so the exclusion lives in this prose rather
# than in a skip list somewhere else that nobody updates. The previous edition
# of this record was written entirely in file offsets, and by the time anyone
# read it again every one of them had rotted — a design record for a drift guard
# that had itself drifted (#606). T18.10 keeps it that way.
#
# THE pattern `\b` IS LOAD-BEARING; do not strip it for POSIX tidiness.
# `ledger` ends in `r`, so without the boundary the alternation also matches the
# tail of the `ledger.complete =` assignment and harvests a phantom member
# `complete` — a name the documented record does not carry, which reds the
# reverse row spuriously. The pattern `\b` is a GNU/BSD ERE extension supported
# by both CI greps (ubuntu-latest and windows-latest/Git Bash); it is NOT one of
# the undefined bracket escapes the note above warns about.
#
# A file-wide key harvest over the pattern `X:` is wrong for the opposite
# reason: this script spells `prProof` in more than one role — the `prProof:`
# key of the relay-object SCHEMA, and the published string classification
# written by `r.prProof = "DISPROVEN"` — so a key harvest drags in schema
# properties (deliveryWorkspaceReady, rows, httpStatus, …) the record never
# carries.
#
# `out` is a local name the script REUSES, and only some of its bindings are
# this record. Named by the function each binding sits in: the `unpushedIssue`
# literal, the `deliverPrompt` await inside `runTaskChain` and the
# `solvePrompt` await inside `solveOne` ARE this record;
# `sanitizeEscalationReason`'s scrubbed string (`var out = s.replace(`) and
# `taskReviewPrompt`'s path (`var out = reviewPath(`) are unrelated locals that
# today carry no property writes at all. Naming them beats counting them, and
# this note is the proof:
# its previous edition stated how many bindings there were, and a later binding
# made that number wrong while every name here stayed correct. Naming only
# beats counting while the list stays CLOSED, which is what T18.5 asserts
# against the script itself — a binding added under a function this paragraph
# does not name reds there, instead of quietly falsifying the sentence above
# the way the retired count was falsified.
# A stray assignment matching the pattern `out.foo =` added under any of them
# would red the reverse row: a REVIEWABLE FALSE POSITIVE, never a silent pass.
# That is the deliberate trade, stated here so it is a decision rather than an
# accident.
# === END T16 citation block ===
SF_DOC_ISSUE_FIELDS="$(sf_doc_record_members "$SOLVE_FLEET_SKILL" 'results: [ {')"
SF_JS_ISSUE_FIELDS="$({ sf_js_keys '[{] *issue: issue,[^{}]*[}]'
  grep -oE '\b(out|r)\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[^=]' "$SOLVE_FLEET_JS" \
    | tr -d '\r' | sed 's/^[a-z]*\.//; s/[[:space:]]*=.*$//'; } | sort -u)"
SF_DOC_ISSUE_N="$(sf_member_count "$SF_DOC_ISSUE_FIELDS")"
SF_JS_ISSUE_N="$(sf_member_count "$SF_JS_ISSUE_FIELDS")"

# === BEGIN T16 member-count floor rationale ===
# T16.9 — anti-vacuity. A moved or renamed anchor yields ZERO, which would make
# T16.10/T16.11 pass while comparing nothing at all. The floor below sits well
# UNDER the live member count, deliberately: a floor set just beneath the live
# size is not an anti-vacuity guard, it is a SIZE RATCHET that reds on a
# legitimate field removal made on both sides. Any positive floor catches the
# failure mode this row exists for, because a lost anchor extracts zero names
# rather than merely fewer. The live sizes are NOT restated here — the row
# prints both of them on every run, which is the only copy that cannot go stale.
# === END T16 member-count floor rationale ===
if [ "$SF_DOC_ISSUE_N" -ge 12 ] && [ "$SF_JS_ISSUE_N" -ge 12 ]; then
  echo "  PASS  T16.9 both per-issue record field lists extracted (SKILL.md: $SF_DOC_ISSUE_N, workflow.js: $SF_JS_ISSUE_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.9 setup error: the per-issue record did not extract from both sides"
  echo "        SKILL.md 'results: [ {...}]' members: $SF_DOC_ISSUE_N (expected >= 12) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js record fields:           $SF_JS_ISSUE_N (expected >= 12) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.10 — forward. A documented field the script never writes is a field a
# consumer reads as undefined on every record.
T16_ISSUE_MISSING="$(sf_members_absent "$SF_DOC_ISSUE_FIELDS" "$SF_JS_ISSUE_FIELDS")"
if [ -z "$T16_ISSUE_MISSING" ]; then
  echo "  PASS  T16.10 every per-issue field SKILL.md documents is one workflow.js writes ($SF_DOC_ISSUE_N/$SF_DOC_ISSUE_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.10 SKILL.md documents per-issue field(s) no result record carries"
  echo "        absent from workflow.js:$T16_ISSUE_MISSING"
  FAIL=$((FAIL + 1))
fi

# T16.11 — reverse. This is the half that closes #558's residual: deleting
# `chainComplete` from the published fence while leaving the prose that explains
# it reds HERE, where the whole-file grep this replaced stayed green.
T16_ISSUE_EXTRA="$(sf_members_absent "$SF_JS_ISSUE_FIELDS" "$SF_DOC_ISSUE_FIELDS")"
if [ -z "$T16_ISSUE_EXTRA" ]; then
  echo "  PASS  T16.11 every per-issue field workflow.js writes is documented in SKILL.md ($SF_JS_ISSUE_N/$SF_JS_ISSUE_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.11 workflow.js publishes per-issue field(s) SKILL.md never declares"
  echo "        undocumented:$T16_ISSUE_EXTRA"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# THE FOUR REMAINING PUBLISHED CONTRACTS (#588). The rows above join the
# per-task record, the reviewVerdict union, partialDelivery and the enclosing
# per-issue record. Four more shapes are published by the same two files and had
# no comparator at all: the per-task `claimedStatus` union, the per-issue
# `status` union, the `prProof` union, and the top-level return object together
# with its nested `counts` and `verification` objects.
#
# MEASURED before these rows existed, one realistic drift per contract — a
# member dropped from the claimedStatus sentence, a member added to the solve
# enum and documented nowhere, a member dropped from ONE solver-prompt copy of
# that same union, a member dropped from the prProof table cell, a key dropped
# from the Return value fence, a counts bucket renamed there, and a verification
# member invented there. Every one of them left BOTH this suite and
# tests/solve-fleet-workflow.test.sh at their clean totals, rc 0.
#
# All four are joined HERE rather than declared with a marker for
# tests/contract_markers.py (#370/#371). Two of them would qualify — `status`
# and `prProof` are closed vocabularies — but the other two are not, and
# workflow.js states the rule where it declines the marker for a one-boolean
# predicate: the marker is reserved for a closed VOCABULARY whose members that
# extractor reads and compares. The top-level return object is a KEY SET, not a
# vocabulary; the claimedStatus roster is spelled on the script side as
# REFERENCES into another frozen map plus a bare empty string, which is not a
# member list an extractor can read off the declaration. Splitting one section
# across two mechanisms on that boundary would put half the fleet's contracts
# where the other half's reader never looks, so all four take the join the rest
# of this section already uses.

# --- 1 of 4: the per-task `claimedStatus` union ----------------------------
# The implementer's own terminal word, kept beside the status the script DERIVES
# from commitCount. The doc side is the sentence under the Return value fence,
# harvested for its backtick-quoted tokens — the empty-string member included,
# because here `""` is a real member. That is the opposite of the reviewVerdict
# union, where T16.5 exists precisely because `""` is NOT one; the two fields sit
# in the same record and mean the empty string differently, which is why each
# gets its own pair of rows rather than a shared one.
SF_DOC_CLAIMED="$(sf_doc_members "$SOLVE_FLEET_SKILL" 'terminal word' 'when it answered' \
  | grep -E '^`.+`$' | tr -d '`' | sort -u)"
# Script side: TASK_CLAIMABLE, and it MUST be TASK_CLAIMABLE rather than
# TASK_STATUS. The two differ by SKIPPED — the chain's own account of a rung it
# never dispatched, which no implementer can claim and which the doc therefore
# does not list. Reading the roster the task schema's enum is built from is what
# keeps SKIPPED out of the comparison, and T16.16 asserts that outcome rather
# than trusting the anchor.
#
# Members are spelled there as REFERENCES (`TASK_STATUS.DONE`), never as string
# literals, so each reference is RESOLVED through the TASK_STATUS map instead of
# being read as a value. Harvesting the array alone would compare PROPERTY NAMES
# — which happen to equal the values today and would stop the moment a member is
# spelled differently from its key, silently comparing the wrong strings. The
# bare `""` fallback on the `taskRec.claimedStatus =` assignment is a member in
# its own right and is unioned in from that one site.
SF_JS_TASK_STATUS_MAP="$(grep -oE 'TASK_STATUS = Object\.freeze\([{][^{}]*[}]' <<<"$SF_JS_FLAT")"
SF_JS_CLAIMABLE_REFS="$(grep -oE 'TASK_CLAIMABLE = Object\.freeze\(\[[^][]*\]' <<<"$SF_JS_FLAT" \
  | grep -oE 'TASK_STATUS\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^TASK_STATUS\.//' | sort -u)"
SF_JS_CLAIMED="$({
  while IFS= read -r _sf_ref; do
    [ -n "$_sf_ref" ] || continue
    grep -oE "[[:space:]]$_sf_ref: \"[A-Za-z_][A-Za-z0-9_]*\"" <<<"$SF_JS_TASK_STATUS_MAP" \
      | grep -oE '"[A-Za-z_][A-Za-z0-9_]*"' | tr -d '"'
  done <<<"$SF_JS_CLAIMABLE_REFS"
  grep -oE 'taskRec\.claimedStatus = [^;]*: "";' "$SOLVE_FLEET_JS" \
    | grep -oE ': "";' | sed 's/^: //; s/;$//'; } | sort -u)"
SF_DOC_CLAIMED_N="$(sf_member_count "$SF_DOC_CLAIMED")"
SF_JS_CLAIMED_N="$(sf_member_count "$SF_JS_CLAIMED")"

# T16.16 — anti-vacuity, plus the SOURCE check that makes this pair discriminate.
# A moved anchor on either side extracts zero names and would make T16.17 pass
# while comparing nothing; the floor is well under the live size for the same
# reason the per-issue floor is, and both live sizes are printed rather than
# restated. The second clause is not decoration: reading TASK_STATUS instead of
# TASK_CLAIMABLE is the one substitution that still extracts a plausible roster,
# and it is caught by the member it drags in.
if [ "$SF_DOC_CLAIMED_N" -ge 2 ] && [ "$SF_JS_CLAIMED_N" -ge 2 ] \
  && ! grep -qxF -- 'SKIPPED' <<<"$SF_JS_CLAIMED"; then
  echo "  PASS  T16.16 both per-task claimedStatus rosters extracted from the claimable list (SKILL.md: $SF_DOC_CLAIMED_N, workflow.js: $SF_JS_CLAIMED_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.16 setup error: the per-task claimedStatus roster did not extract from both sides, or came from the wrong constant"
  echo "        SKILL.md members:    $SF_DOC_CLAIMED_N (expected >= 2) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_CLAIMED_N (expected >= 2) — $SOLVE_FLEET_JS"
  grep -qxF -- 'SKIPPED' <<<"$SF_JS_CLAIMED" \
    && echo "        SKIPPED is in the script-side roster — that is TASK_STATUS, not TASK_CLAIMABLE; no implementer can claim it"
  FAIL=$((FAIL + 1))
fi

# T16.17 — both directions in one row, the T16.8 shape. A documented word the
# script can never record is one a consumer's switch waits for forever; a word
# the script records and the doc omits is one it has no arm for.
T16_CLAIMED_MISSING="$(sf_members_absent "$SF_DOC_CLAIMED" "$SF_JS_CLAIMED")"
T16_CLAIMED_EXTRA="$(sf_members_absent "$SF_JS_CLAIMED" "$SF_DOC_CLAIMED")"
if [ -z "$T16_CLAIMED_MISSING" ] && [ -z "$T16_CLAIMED_EXTRA" ]; then
  echo "  PASS  T16.17 SKILL.md and workflow.js agree on the per-task claimedStatus roster, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.17 the documented claimedStatus roster and TASK_CLAIMABLE have drifted"
  [ -n "$T16_CLAIMED_MISSING" ] && echo "        documented but never recorded:$T16_CLAIMED_MISSING"
  [ -n "$T16_CLAIMED_EXTRA" ] && echo "        recorded but never documented:$T16_CLAIMED_EXTRA"
  FAIL=$((FAIL + 1))
fi

# --- 2 of 4: the per-issue `status` union, in every copy of it -------------
# This vocabulary drives every count in the run, the PR set /goal ingests, and
# the downgrade the proof pass applies — and it is spelled in more than one
# place: the doc union, the `enum` array on the solve schema, and every solver
# prompt that tells an agent which words it may answer with. The prompt copies
# are the ones that cannot be skipped: an agent told a short union answers with
# a word the schema rejects, the structured return is discarded, and the failure
# surfaces as a null result that never names the word that caused it.
SF_DOC_STATUS="$(sf_doc_members "$SOLVE_FLEET_SKILL" '`status` ∈' '`' '`')"
SF_JS_STATUS_ENUM="$(grep -oE 'status: [{] *type: "string", *enum: \[[^][]*\]' <<<"$SF_JS_FLAT" \
  | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"' | sort -u)"
# The prompt copies are JS string CONCATENATION split across an authored wrap,
# so the glue is removed before the union is looked for — otherwise the union
# reads as two fragments and neither one matches. Each copy is kept WHOLE rather
# than merged into a set, and whole means the SPELLING, not the membership.
# Merging is blind in both of the directions that matter: a member dropped from
# one copy is handed back by the other, and a reordered union has the very same
# members — either way the merged set still equals the enum, and every row below
# passes on a script whose copies no longer agree.
#
# The anchor is the RETURN LINE the union rides on, never a member of the union
# itself. Anchoring on a member is self-defeating and silently so: a copy whose
# union is reordered, or whose anchor member is renamed, stops matching and
# drops OUT of the set — and the rows below then compare only the copies that
# did NOT drift, which is the drift a second copy was included to catch,
# passing. The `issue (` field of that line is what holds the per-task
# `taskId (` return line out; its own status vocabulary is a different contract
# and a looser anchor drags it in, poisoning the comparison with words the solve
# schema was never meant to accept.
SF_JS_STATUS_PROMPTS="$(grep -oE 'StructuredOutput: issue \([^)]*\), status \([^)]*\)' <<<"$SF_JS_GLUED" \
  | sed 's/^.*, status (/status (/')"
# Every per-issue return line, carrying a union or not. This is the DENOMINATOR
# the copy count is measured against: re-anchoring keeps a DRIFTED union in the
# set, but a copy that drops its union clause outright has no anchor left to
# match and would still leave without a sound.
SF_JS_STATUS_RETURNS="$(grep -oE 'Return via StructuredOutput: issue \(' <<<"$SF_JS_GLUED")"
SF_JS_STATUS_PROMPT_SPELLINGS="$(sort -u <<<"$SF_JS_STATUS_PROMPTS")"
SF_JS_STATUS_PROMPT_MEMBERS="$(grep -oE '[A-Z][A-Z0-9_]+' <<<"$SF_JS_STATUS_PROMPT_SPELLINGS" | sort -u)"
SF_DOC_STATUS_N="$(sf_member_count "$SF_DOC_STATUS")"
SF_JS_STATUS_N="$(sf_member_count "$SF_JS_STATUS_ENUM")"
SF_JS_STATUS_PROMPT_N="$(sf_member_count "$SF_JS_STATUS_PROMPTS")"
SF_JS_STATUS_RETURN_N="$(sf_member_count "$SF_JS_STATUS_RETURNS")"
SF_JS_STATUS_SPELLING_N="$(sf_member_count "$SF_JS_STATUS_PROMPT_SPELLINGS")"

# T16.18 — anti-vacuity across every copy. Every floor sits well UNDER
# the live size, on the T16.9 rule: a floor set just beneath it is not an
# anti-vacuity guard but a SIZE RATCHET that reds when a member is legitimately
# retired on both sides, and a lost anchor extracts ZERO rather than merely
# fewer. The live sizes are printed by the row instead of restated here.
#
# The prompt floor counts COPIES, not members, and it is an ARMING floor: one
# copy is enough to make T16.21 a real comparison, and collapsing the prompts
# into a single shared builder is a refactor this row must not veto.
#
# Which is exactly why the floor cannot be the whole guard, and the second
# clause is not decoration. A floor is satisfied by whatever SURVIVED: it reads
# the same whether the script publishes one union or lost one of several, so a
# copy that walks out of the set takes its own drift with it and every row below
# reads green on the copies that stayed. Requiring the copies to equal the
# per-issue return lines closes that: the denominator moves with the script, so
# folding the prompts into one shared builder still passes — both sides fall
# together — while a return line that stops carrying its union reds here by
# name, instead of quietly shrinking what T16.20 and T16.21 compare.
if [ "$SF_DOC_STATUS_N" -ge 3 ] && [ "$SF_JS_STATUS_N" -ge 3 ] && [ "$SF_JS_STATUS_PROMPT_N" -ge 1 ] \
  && [ "$SF_JS_STATUS_PROMPT_N" = "$SF_JS_STATUS_RETURN_N" ]; then
  echo "  PASS  T16.18 every status-union copy extracted (SKILL.md: $SF_DOC_STATUS_N, schema enum: $SF_JS_STATUS_N, solver prompts: $SF_JS_STATUS_PROMPT_N of $SF_JS_STATUS_RETURN_N per-issue return lines)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.18 setup error: a copy of the per-issue status union did not extract"
  echo "        SKILL.md members:     $SF_DOC_STATUS_N (expected >= 3) — $SOLVE_FLEET_SKILL"
  echo "        schema enum members:  $SF_JS_STATUS_N (expected >= 3) — $SOLVE_FLEET_JS"
  echo "        solver-prompt copies: $SF_JS_STATUS_PROMPT_N (expected >= 1) — $SOLVE_FLEET_JS"
  [ "$SF_JS_STATUS_PROMPT_N" != "$SF_JS_STATUS_RETURN_N" ] \
    && echo "        per-issue return lines: $SF_JS_STATUS_RETURN_N — a return line carries no status union, so it left the comparison"
  FAIL=$((FAIL + 1))
fi

# T16.19 — the doc and the schema enum, both directions.
T16_STATUS_MISSING="$(sf_members_absent "$SF_DOC_STATUS" "$SF_JS_STATUS_ENUM")"
T16_STATUS_EXTRA="$(sf_members_absent "$SF_JS_STATUS_ENUM" "$SF_DOC_STATUS")"
if [ -z "$T16_STATUS_MISSING" ] && [ -z "$T16_STATUS_EXTRA" ]; then
  echo "  PASS  T16.19 SKILL.md and the solve schema agree on the per-issue status union, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.19 the documented status union and the schema enum have drifted"
  [ -n "$T16_STATUS_MISSING" ] && echo "        documented but not in the enum:$T16_STATUS_MISSING"
  [ -n "$T16_STATUS_EXTRA" ] && echo "        in the enum but never documented:$T16_STATUS_EXTRA"
  FAIL=$((FAIL + 1))
fi

# T16.20 — the solver prompts spell ONE union, not several. Comparing the copies
# to each other rather than only to the enum is what makes a member lost from a
# single prompt visible: the merged set would still equal the enum.
if [ "$SF_JS_STATUS_SPELLING_N" = "1" ]; then
  echo "  PASS  T16.20 every solver prompt spells the status union identically ($SF_JS_STATUS_PROMPT_N copies, one spelling)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.20 the solver prompts disagree about the status union a solver may answer with"
  echo "        file: $SOLVE_FLEET_JS"
  sed 's/^/        /' <<<"$SF_JS_STATUS_PROMPT_SPELLINGS"
  FAIL=$((FAIL + 1))
fi

# T16.21 — that one spelling against the enum, both directions. A prompt word
# the schema rejects and a schema word no prompt offers are the same defect seen
# from its two ends.
T16_PROMPT_MISSING="$(sf_members_absent "$SF_JS_STATUS_PROMPT_MEMBERS" "$SF_JS_STATUS_ENUM")"
T16_PROMPT_EXTRA="$(sf_members_absent "$SF_JS_STATUS_ENUM" "$SF_JS_STATUS_PROMPT_MEMBERS")"
if [ -z "$T16_PROMPT_MISSING" ] && [ -z "$T16_PROMPT_EXTRA" ]; then
  echo "  PASS  T16.21 the solver prompt offers exactly the status words the solve schema accepts, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.21 the solver prompt and the solve schema disagree about the answerable status words"
  [ -n "$T16_PROMPT_MISSING" ] && echo "        offered by the prompt, rejected by the schema:$T16_PROMPT_MISSING"
  [ -n "$T16_PROMPT_EXTRA" ] && echo "        accepted by the schema, never offered:$T16_PROMPT_EXTRA"
  FAIL=$((FAIL + 1))
fi

# --- 3 of 4: the `prProof` union -------------------------------------------
# The classification the proof pass writes onto a record, and the only field
# that says whether a claimed PR was observed. The doc side is the table cell in
# the proof section, read between the cell's own delimiters and filtered to its
# backtick-quoted tokens so the separator glyphs are not members.
SF_DOC_PRPROOF="$(sf_doc_members "$SOLVE_FLEET_SKILL" '| `prProof` | ' '|' \
  | grep -E '^`.+`$' | tr -d '`' | sort -u)"
# Script side, anchored STRICTLY on the assignment sites. A bare `prProof` key
# sweep is wrong here and quietly so: this script spells the symbol in two roles
# — the published classification written by `r.prProof =`, and the `prProof:`
# property of the proof-relay schema — and sweeping the key drags the relay's
# observation properties in as if they were members of this union.
SF_JS_PRPROOF="$(grep -oE 'r\.prProof = "[A-Z][A-Z0-9_]*"' "$SOLVE_FLEET_JS" \
  | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"\r' | sort -u)"
SF_DOC_PRPROOF_N="$(sf_member_count "$SF_DOC_PRPROOF")"
SF_JS_PRPROOF_N="$(sf_member_count "$SF_JS_PRPROOF")"

# T16.22 — anti-vacuity. A renamed table header or a classification moved behind
# a helper extracts zero on that side, and zero-vs-zero is the vacuous green.
if [ "$SF_DOC_PRPROOF_N" -ge 2 ] && [ "$SF_JS_PRPROOF_N" -ge 2 ]; then
  echo "  PASS  T16.22 both prProof unions extracted (SKILL.md: $SF_DOC_PRPROOF_N, workflow.js: $SF_JS_PRPROOF_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.22 setup error: the prProof union did not extract from both sides"
  echo "        SKILL.md members:    $SF_DOC_PRPROOF_N (expected >= 2) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_PRPROOF_N (expected >= 2) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.23 — both directions. This is the field an operator reads to decide
# whether to believe a run, so an unlisted classification is one nobody can look
# up and a documented one the script never writes is a filter that matches
# nothing.
T16_PRPROOF_MISSING="$(sf_members_absent "$SF_DOC_PRPROOF" "$SF_JS_PRPROOF")"
T16_PRPROOF_EXTRA="$(sf_members_absent "$SF_JS_PRPROOF" "$SF_DOC_PRPROOF")"
if [ -z "$T16_PRPROOF_MISSING" ] && [ -z "$T16_PRPROOF_EXTRA" ]; then
  echo "  PASS  T16.23 SKILL.md and workflow.js agree on the prProof union, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.23 the documented prProof union and the classifications the script writes have drifted"
  [ -n "$T16_PRPROOF_MISSING" ] && echo "        documented but never written:$T16_PRPROOF_MISSING"
  [ -n "$T16_PRPROOF_EXTRA" ] && echo "        written but never documented:$T16_PRPROOF_EXTRA"
  FAIL=$((FAIL + 1))
fi

# --- 4 of 4: the TOP-LEVEL return object, and its two nested objects --------
# The outermost shape the fleet publishes — what /goal and every operator read
# first — joined the way the per-issue record above is joined, because it is a
# KEY SET rather than a vocabulary. Doc side is the `## Return value` fence,
# read at depth 0 so the nested records appear by KEY NAME and never by their
# members; the fence opens on its own line below the sentence that introduces
# it, which is why the anchor and the opening brace are given separately.
SF_DOC_RETURN="$(sf_doc_record_members "$SOLVE_FLEET_SKILL" '## Return value' '{')"
# Script side, scoped to finalize() — the one function that builds this object.
# A file-wide reader would collect every literal in the script; the arming
# anchor is what makes `return [{]` mean THIS return.
SF_JS_RETURN="$(sf_js_object_keys '^function finalize' '^  return [{]')"
SF_DOC_RETURN_N="$(sf_member_count "$SF_DOC_RETURN")"
SF_JS_RETURN_N="$(sf_member_count "$SF_JS_RETURN")"

# T16.24 — anti-vacuity, same floor rule as the per-issue row: well under the
# live size, because a floor set just beneath it is a size ratchet that reds on
# a key legitimately removed from both sides. Both live sizes are printed here
# on every run, which is the only copy of them that cannot go stale.
if [ "$SF_DOC_RETURN_N" -ge 12 ] && [ "$SF_JS_RETURN_N" -ge 12 ]; then
  echo "  PASS  T16.24 both top-level return key sets extracted (SKILL.md: $SF_DOC_RETURN_N, workflow.js: $SF_JS_RETURN_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.24 setup error: the top-level return object did not extract from both sides"
  echo "        SKILL.md '## Return value' fence keys: $SF_DOC_RETURN_N (expected >= 12) — $SOLVE_FLEET_SKILL"
  echo "        finalize() return keys:               $SF_JS_RETURN_N (expected >= 12) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.25 — forward. A documented top-level key finalize() never publishes is one
# every consumer reads as undefined on every run.
T16_RETURN_MISSING="$(sf_members_absent "$SF_DOC_RETURN" "$SF_JS_RETURN")"
if [ -z "$T16_RETURN_MISSING" ]; then
  echo "  PASS  T16.25 every top-level key SKILL.md documents is one finalize() returns ($SF_DOC_RETURN_N/$SF_DOC_RETURN_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.25 SKILL.md documents top-level return key(s) finalize() never publishes"
  echo "        absent from workflow.js:$T16_RETURN_MISSING"
  FAIL=$((FAIL + 1))
fi

# T16.26 — reverse. This is the half that retires the hand-picked key greps: a
# key added to the return and to no doc reds here, where a grep for one chosen
# name stayed green for every other name.
T16_RETURN_EXTRA="$(sf_members_absent "$SF_JS_RETURN" "$SF_DOC_RETURN")"
if [ -z "$T16_RETURN_EXTRA" ]; then
  echo "  PASS  T16.26 every top-level key finalize() returns is documented in SKILL.md ($SF_JS_RETURN_N/$SF_JS_RETURN_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.26 finalize() publishes top-level key(s) SKILL.md never declares"
  echo "        undocumented:$T16_RETURN_EXTRA"
  FAIL=$((FAIL + 1))
fi

# The two nested objects get their own pair each, on the partialDelivery
# precedent: the depth-0 read above proves only that the KEY exists, and a
# histogram whose buckets have drifted is exactly as unreadable as a missing
# one.
SF_DOC_COUNTS="$(sf_doc_members "$SOLVE_FLEET_SKILL" 'counts: {' '}')"
SF_JS_COUNTS="$(sf_js_object_keys '^function finalize' '^    counts: [{]')"
SF_DOC_COUNTS_N="$(sf_member_count "$SF_DOC_COUNTS")"
SF_JS_COUNTS_N="$(sf_member_count "$SF_JS_COUNTS")"
if [ "$SF_DOC_COUNTS_N" -ge 3 ] && [ "$SF_JS_COUNTS_N" -ge 3 ]; then
  echo "  PASS  T16.27 both counts bucket lists extracted (SKILL.md: $SF_DOC_COUNTS_N, workflow.js: $SF_JS_COUNTS_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.27 setup error: the counts object did not extract from both sides"
  echo "        SKILL.md members:    $SF_DOC_COUNTS_N (expected >= 3) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_COUNTS_N (expected >= 3) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi
T16_COUNTS_MISSING="$(sf_members_absent "$SF_DOC_COUNTS" "$SF_JS_COUNTS")"
T16_COUNTS_EXTRA="$(sf_members_absent "$SF_JS_COUNTS" "$SF_DOC_COUNTS")"
if [ -z "$T16_COUNTS_MISSING" ] && [ -z "$T16_COUNTS_EXTRA" ]; then
  echo "  PASS  T16.28 SKILL.md and finalize() agree on the counts buckets, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.28 the documented counts histogram and the one finalize() builds have drifted"
  [ -n "$T16_COUNTS_MISSING" ] && echo "        documented but never counted:$T16_COUNTS_MISSING"
  [ -n "$T16_COUNTS_EXTRA" ] && echo "        counted but never documented:$T16_COUNTS_EXTRA"
  FAIL=$((FAIL + 1))
fi

SF_DOC_VERIF="$(sf_doc_members "$SOLVE_FLEET_SKILL" 'verification: {' '}')"
SF_JS_VERIF="$(sf_js_object_keys '^function finalize' '^    verification: [{]')"
SF_DOC_VERIF_N="$(sf_member_count "$SF_DOC_VERIF")"
SF_JS_VERIF_N="$(sf_member_count "$SF_JS_VERIF")"
if [ "$SF_DOC_VERIF_N" -ge 3 ] && [ "$SF_JS_VERIF_N" -ge 3 ]; then
  echo "  PASS  T16.29 both verification member lists extracted (SKILL.md: $SF_DOC_VERIF_N, workflow.js: $SF_JS_VERIF_N)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.29 setup error: the verification object did not extract from both sides"
  echo "        SKILL.md members:    $SF_DOC_VERIF_N (expected >= 3) — $SOLVE_FLEET_SKILL"
  echo "        workflow.js members: $SF_JS_VERIF_N (expected >= 3) — $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi
T16_VERIF_MISSING="$(sf_members_absent "$SF_DOC_VERIF" "$SF_JS_VERIF")"
T16_VERIF_EXTRA="$(sf_members_absent "$SF_JS_VERIF" "$SF_DOC_VERIF")"
if [ -z "$T16_VERIF_MISSING" ] && [ -z "$T16_VERIF_EXTRA" ]; then
  echo "  PASS  T16.30 SKILL.md and finalize() agree on the verification totals, both directions"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.30 the documented verification object and the one finalize() builds have drifted"
  [ -n "$T16_VERIF_MISSING" ] && echo "        documented but never computed:$T16_VERIF_MISSING"
  [ -n "$T16_VERIF_EXTRA" ] && echo "        computed but never documented:$T16_VERIF_EXTRA"
  FAIL=$((FAIL + 1))
fi

echo
echo "== T17: the brainstorm launcher is invoked through bash, with the reason recorded (#533) =="
# WHY THIS SECTION EXISTS. visual-companion.md prescribed `scripts/start-server.sh` bare — an
# invocation that only runs where the exec bit survived the distribution path AND the shell honours
# the shebang. Neither holds on the marketplace copy or on Windows, and the file had ZERO test
# coverage, so the shape was unfalsifiable and a future editor could "simplify" the prefix back out
# with nothing noticing. Two halves are locked here:
#   (a) the shape — every documented launch goes through `bash`, and NO bare form survives at any
#       indentation, plus the reason recorded where the next editor reads it (the Windows block);
#   (b) the cross-file citation — the orchestrator quotes a fragment OUT of this file, and it
#       used to name a LINE RANGE (`visual-companion.md:118-127`). Editing (a) shifted those lines
#       and silently invalidated it. Same class as #349 / T9: anchor on a SYMBOL that resolves.
#       Since #747 that quote lives in orchestrator/references/visual-companion.md rather than in
#       the orchestrator body, so BOTH files are guarded — see the T17.1a/T17.1b note below.
#
# FLOOR, NOT AN EXACT COUNT (deliberate, see #533 review finding 4). The absence row forbids ANY bare
# invocation, whitespace-tolerantly — that alone fully enforces "every invocation is prefixed". The
# companion count row is purely an ANTI-VACUITY floor: it proves the corpus did not shrink to
# nothing. Pinning it to exactly 7 would red CI the day an eighth launch block is legitimately
# documented, for no detection gain.
#
# CHANGELOG.md:2859 carries the same `:118-127` literal and is deliberately NOT guarded: it is a
# frozen record of what a past release shipped, and it is a forbidden version surface in the fleet
# lane (skills/solve-fleet/workflow.js).
VC_MD="$REPO_ROOT/plugins/uberdev/skills/brainstorm/visual-companion.md"
ORCH_SKILL="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
# #747 — the Phase 2 visual-companion flow, and the cross-file citation it
# carries, moved into this reference file when the orchestrator body was cut
# toward Anthropic's 500-line ceiling. The citation still belongs to the
# orchestrator skill; it is just no longer in the body file.
ORCH_VC_REF="$REPO_ROOT/plugins/uberdev/skills/orchestrator/references/visual-companion.md"
# The reference file belongs in this pre-flight, not just in the rows: T17.1b reads
# it with `grep -qF`, and grep on a path that does not exist exits non-zero — which
# an ABSENCE row scores as "the literal is not present", i.e. a silent PASS. A
# deleted or unreadable reference file has to fail loudly HERE, where the message
# can name it, rather than be caught incidentally by T17.2a.
if [ ! -r "$VC_MD" ] || [ ! -r "$ORCH_SKILL" ] || [ ! -r "$ORCH_VC_REF" ]; then
  echo "  FAIL  T17.0 corpus missing or unreadable — every row below would pass vacuously"
  echo "        visual-companion: $VC_MD"
  echo "        orchestrator:     $ORCH_SKILL"
  echo "        orchestrator ref: $ORCH_VC_REF"
  FAIL=$((FAIL + 11))
else
  # BOTH files, not a swap. The citation moved into the reference file (#747), so
  # that is where a line anchor gets reintroduced today; the body file is where the
  # `:118-127` rot actually happened, and nothing prevents a future edit from
  # pulling the flow back inline. Guarding one and dropping the other just trades
  # one blind spot for the other.
  #
  # SCOPE, unchanged since #533: this row governs the `visual-companion.md`
  # citation. Line-anchored citations to OTHER files are a separate, pre-existing
  # convention in this skill — `merge-pipeline/SKILL.md:343` sits in the body and
  # was green under this row for its whole life, and `skills/brainstorm/SKILL.md:166`,
  # `agents/spec-writer.md:30` and `skills/brainstorm/SKILL.md:206-214` moved into
  # the reference file verbatim from that same body. Widening the literal here would
  # not be a re-point, it would be a new rule retro-applied to text this row never
  # covered; that belongs in its own row with its own remediation.
  assert_absent_fixed "$ORCH_SKILL" 'visual-companion.md:' \
    "T17.1a the orchestrator body carries no line-number anchor on that citation"
  assert_absent_fixed "$ORCH_VC_REF" 'visual-companion.md:' \
    "T17.1b nor does the reference file the citation moved into"
  assert_grep "$ORCH_VC_REF" 'Unload when returning to terminal' \
    "T17.2a the orchestrator anchors on the step's heading text instead"
  assert_grep "$VC_MD" 'Unload when returning to terminal' \
    "T17.2b that heading still resolves in the file it cites"
  assert_grep "$VC_MD" 'Continuing in terminal' \
    "T17.3 the waiting.html fragment the orchestrator quotes verbatim still exists there"
  T17_BASH_N="$(grep -cE '^bash scripts/(start|stop)-server\.sh' "$VC_MD")"
  if [ "${T17_BASH_N:-0}" -ge 7 ] 2>/dev/null; then
    echo "  PASS  T17.4 every documented launcher call goes through bash ($T17_BASH_N sites, floor 7)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T17.4 only ${T17_BASH_N:-0} bash-prefixed launcher calls, floor is 7 — a launch block was deleted or un-prefixed"
    echo "        file: $VC_MD"
    FAIL=$((FAIL + 1))
  fi
  # Whitespace-tolerant on purpose: a column-0 anchor is blind to `  scripts/start-server.sh`
  # written one space in, which is the exact "simplified it back" regression this row exists for.
  # Measured: this ERE matches the 7 invocation lines and NOT the prose mentions (the `start-server.sh`
  # reference inside an indented list item, and the two `- Frame template …` reference bullets).
  T17_BARE_N="$(grep -cE '^[[:space:]]*scripts/(start|stop)-server\.sh' "$VC_MD")"
  if [ "${T17_BARE_N:-0}" -eq 0 ] 2>/dev/null; then
    echo "  PASS  T17.5 no bare launcher invocation survives at any indentation"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T17.5 ${T17_BARE_N} bare launcher invocation(s) survive — the exec-bit/shebang dependency is back"
    grep -nE '^[[:space:]]*scripts/(start|stop)-server\.sh' "$VC_MD" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
  # The reason must live IN the Windows block — the platform where the hazard bites — not merely
  # somewhere in the file. Sliced by the two platform headings; no fence delimiter is matched, so no
  # backtick-run escaping is involved. Herestring readers only: epipe-guard.test.sh E1 scans this
  # file (it sets pipefail) and a `awk … | grep -q` here would red both CI jobs.
  T17_WIN="$(awk '/^\*\*Claude Code \(Windows\):\*\*/{f=1} f && /^\*\*Codex:\*\*/{exit} f' "$VC_MD")"
  T17_WIN_N="$(grep -c . <<<"$T17_WIN")"
  if [ "${T17_WIN_N:-0}" -ge 8 ] 2>/dev/null; then
    echo "  PASS  T17.6 Windows block sliced ($T17_WIN_N lines) — the token rows below are scoped, not vacuous"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T17.6 Windows block slice is empty or too small (${T17_WIN_N:-0} lines) — a platform heading was renamed"
    echo "        file: $VC_MD"
    FAIL=$((FAIL + 1))
  fi
  # Durable tokens, not a sentence: `shebang`, `exec bit` and `bash.exe` survive rewording, whereas a
  # whole-sentence literal invites satisfying the test with prose that no longer matches the code.
  for t17_probe in 'shebang|T17.7 the Windows block names the shebang dependency the prefix removes' \
                   'exec bit|T17.8 the Windows block names the exec-bit dependency the prefix removes' \
                   'bash\.exe|T17.9 the Windows block names Git Bash bash.exe for the PowerShell tool'; do
    t17_re="${t17_probe%%|*}"; t17_desc="${t17_probe#*|}"
    if grep -qE -e "$t17_re" <<<"$T17_WIN"; then
      echo "  PASS  $t17_desc"; PASS=$((PASS + 1))
    else
      echo "  FAIL  $t17_desc"
      echo "        file: $VC_MD (Windows block slice)"
      echo "        pattern: $t17_re"
      FAIL=$((FAIL + 1))
    fi
  done
fi

# T16.10 — the OTHER contract the completeness flag produced, and the one with a
# consumer. `chainComplete: false` makes the delivery prompt mandate the
# non-closing `UberDev-Partial: #N` trailer instead of `Closes #N` (#554), and
# that spelling now lives in three files: the producer (the fleet script), the
# fleet's own return-value doc, and /merge's Step 3.4 cleanup, which is the only
# code that parses it. Three uncompared copies of one literal is exactly the
# class #370 named, and here the consequence is concrete — a consumer that
# never learns the spelling silently strands the `uberdev:active` claim on a
# still-OPEN issue and blocks every later /solve, /turbo and /goal Phase 1.
#
# A per-file grep rather than a set-difference: this is a fixed literal, not a
# member list, so what must hold is that the exact spelling resolves in every
# copy. `grep -qF` reads each file directly — no pipeline, so no writer exists
# for pipefail to poison (tests/epipe-guard.test.sh).
T16_PARTIAL_TOKEN='UberDev-Partial:'
T16_PARTIAL_UNJOINED=""
for T16_PARTIAL_FILE in "$SOLVE_FLEET_JS" "$SOLVE_FLEET_SKILL" "$MERGE_PIPELINE_SKILL"; do
  grep -qF -e "$T16_PARTIAL_TOKEN" "$T16_PARTIAL_FILE" \
    || T16_PARTIAL_UNJOINED="$T16_PARTIAL_UNJOINED $T16_PARTIAL_FILE"
done
if [ -z "$T16_PARTIAL_UNJOINED" ]; then
  echo "  PASS  T16.10 the $T16_PARTIAL_TOKEN trailer resolves in all three copies (fleet script, fleet SKILL.md, /merge SKILL.md)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.10 the partial-linkage trailer is missing from a copy of its own contract"
  echo "        literal: $T16_PARTIAL_TOKEN"
  echo "        absent from:$T16_PARTIAL_UNJOINED"
  echo "        a copy that never learns the spelling strands the uberdev:active claim (#554)"
  FAIL=$((FAIL + 1))
fi

# T16.12–T16.15 (#592) — the REGISTER ENTRY the completeness flag carried, and
# its discharge. `chainComplete` shipped under a comment that DECLARED, in as
# many words, that no production code read it. That was an honest register entry
# for a known gap while the gap was real. #592 closes it: finalize() publishes
# `prsPartial`, the partial subset of the very list /goal ingests, so the
# ingesting side has something to read. The declaration is therefore now a FALSE
# statement about this tree — and a stale "nobody reads this" note is worse than
# no note at all, because it tells the next reader not to go looking for the
# consumers that now exist.
#
# The four rows hold both halves of the discharge at once, so neither can be
# done without the other:
#   - the field is published on BOTH sides of the contract, doc fence and script
#     (T16.12/T16.13) — the same both-directions join T16.2/T16.3 use, because a
#     documented field nothing writes and a written field nothing documents are
#     the same drift with opposite signs;
#   - every retired SPELLING of the declaration is gone from BOTH copies AND the
#     marker that replaced it is present (T16.14) — a one-string absence row, or
#     a one-file one, would be a predicate disjoint from the drift it must find,
#     and an absence-only row cannot tell a discharged register entry from a
#     deleted one;
#   - and the residual it used to carry — the issue behind a partial-chain PR is
#     FLAGGED, never re-queued — still points at a FILED number (T16.15). The
#     note made that rule itself: "a pointer to a filed number rather than to 'a
#     follow-up issue': an unnamed one cannot be checked". T16.15 is what makes
#     it checkable, and without it the pointer can be dropped silently.
#
# Scoped slices, not whole-file greps: SKILL.md spells these symbols in the
# normative fence AND in the prose that explains them, so a whole-file grep is a
# predicate on a different surface than the contract it guards — exactly the
# #558 defect T16.9 was added to remove.
T16_RETURN_FENCE="$(tr -d '\r' < "$SOLVE_FLEET_SKILL" | awk '
  /^## Return value/ { sec = 1; next }
  sec && /^```/      { if (infence) exit; infence = 1; next }
  infence            { print }
')"
T16_FENCE_N="$(grep -c . <<<"$T16_RETURN_FENCE")"
# T16.12 — doc side. The anchor guard rides in the same row rather than in a
# separate anti-vacuity one: `prsOpened: [<int>]` is the sibling `prsPartial`
# must appear beside, so its absence means the heading or the fence moved and
# the row reports THAT instead of passing over an empty slice.
if [ "${T16_FENCE_N:-0}" -ge 8 ] && grep -qF -e 'prsOpened: [<int>]' <<<"$T16_RETURN_FENCE"; then
  if grep -qF -e 'prsPartial: [<int>]' <<<"$T16_RETURN_FENCE"; then
    echo "  PASS  T16.12 the return fence publishes prsPartial beside prsOpened ($T16_FENCE_N-line fence)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T16.12 the return fence declares prsOpened but not prsPartial"
    echo "        file: $SOLVE_FLEET_SKILL ('## Return value' fence)"
    echo "        a consumer reading only this fence cannot tell a partial-chain PR from a finished one (#592)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  T16.12 setup error: the '## Return value' fence did not slice (${T16_FENCE_N:-0} lines, prsOpened anchor absent)"
  echo "        file: $SOLVE_FLEET_SKILL"
  FAIL=$((FAIL + 1))
fi

# T16.13 — script side, scoped to finalize(), the one function that builds the
# published return object. A comment elsewhere in the file naming the field must
# not satisfy this row.
T16_FINALIZE="$(tr -d '\r' < "$SOLVE_FLEET_JS" | awk '
  /^function finalize\(\) \{/ { f = 1 }
  f                           { print }
  f && /^\}/                  { exit }
')"
T16_FINALIZE_N="$(grep -c . <<<"$T16_FINALIZE")"
if [ "${T16_FINALIZE_N:-0}" -ge 20 ] && grep -qE '^[[:space:]]*prsOpened:' <<<"$T16_FINALIZE"; then
  if grep -qE '^[[:space:]]*prsPartial:' <<<"$T16_FINALIZE"; then
    echo "  PASS  T16.13 finalize() publishes prsPartial as a top-level sibling of prsOpened ($T16_FINALIZE_N lines)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  T16.13 finalize() returns prsOpened but never publishes prsPartial"
    echo "        file: $SOLVE_FLEET_JS (function finalize)"
    echo "        SKILL.md would then document a field no run ever emits (#592)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  T16.13 setup error: function finalize() did not slice (${T16_FINALIZE_N:-0} lines, prsOpened key absent)"
  echo "        file: $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
fi

# T16.14 — the register entry itself, joined in BOTH directions like T16.12 and
# T16.13 above, because a discharge has the same two failure modes as any other
# contract: the retired claim can survive, and the replacement can go missing.
#
# Direction 1, absence — a SET of spellings over BOTH copies of the contract,
# never one headline literal in one file. A discharge asserted against a single
# string is a predicate DISJOINT from the drift class it exists to close
# (#370/#371), and one scoped to a single file is disjoint in the same way when
# the claim is written twice. Both failures were real here:
#
#   - paraphrase — the comment on the `partialDelivery` block, twelve lines under
#     the retired paragraph, said the flag was what /goal's ingestion "has to
#     grow a reader for". Same claim, different words, made false by the same
#     commit that retired the headline literal.
#   - other copy — SKILL.md, the doc side of this same contract, called the PR
#     linkage "the one consequence of it that is visible outside this return
#     value". A COUNT claim about the flag's consumers is the retired claim with
#     a different number: true when written, falsified by the next commit that
#     gives the flag a consumer, and #592 is that commit. A row that reads only
#     the script cannot see it.
#
# A tree carrying two contradictory answers to "what reads this flag?" is worse
# than either answer alone, so every retired spelling joins the set and the set
# runs over every file that carries the contract.
#
# Direction 2, presence — the ALL-CAPS marker that replaced the retired one, in
# the SCRIPT only. An absence-only row cannot tell a register entry that was
# DISCHARGED from one that was DELETED: strip the whole paragraph and every row
# here still greens, while the fact the entry exists to record — that
# `chainComplete` reaches a consumer, and since which issue — is gone from the
# file that carries it. A marker is pinned rather than a sentence on purpose:
# prose around it is free to be rewritten, and pinning prose would make every
# reword a red. SKILL.md is deliberately NOT held to the marker: it states the
# same facts as prose and is joined by T16.12 and T16.15 instead.
#
# For the ABSENCE half each file is flattened to ONE logical line first — CR
# stripped, newlines to spaces, runs squeezed — because these claims live in
# wrapped comments and wrapped Markdown, where a re-wrap moves a token across a
# line break and a line-scoped `grep -F` then greens over a claim that is still
# there. The superlative quoted above was already split across two source lines
# while it was live, so nothing shorter than the flattened form could pin it.
# The presence half reads the file directly instead: its marker is one ALL-CAPS
# line, and flattening a JS comment joins lines with the `//` openers between
# them, so it would not survive a re-wrap either way. Flattening is a
# value-producing `$( )` of draining readers and every matcher is a herestring,
# so no early-exiting reader ever sits on a pipe (tests/epipe-guard.test.sh),
# and there is no bare `grep -c` whose rc 1 on zero matches would trip a
# stricter harness.
#
# Anti-vacuity: `chainComplete`, the subject of the whole register entry and a
# symbol both copies must name, is asserted present in each flattened text — so
# a truncated read or a copy that stopped documenting the field reports THAT
# rather than passing over an empty haystack. Both files are also in the
# preflight's `[ -r "$f" ] || exit 2` list, so a moved or renamed file is FATAL.
T16_UNREAD_TOKEN='DECLARED UNREAD BY PRODUCTION CODE'
T16_UNREAD_PARAPHRASE='has to grow a reader for'
T16_UNREAD_COUNT_CLAIM='the one consequence of it that is visible outside this return value'
T16_READ_MARKER='READ BY PRODUCTION CODE SINCE #592'
T16_UNREAD_SUBJECT='chainComplete'
T16_UNREAD_SURVIVING=""
T16_UNREAD_UNANCHORED=""
for T16_UNREAD_FILE in "$SOLVE_FLEET_JS" "$SOLVE_FLEET_SKILL"; do
  T16_UNREAD_FLAT="$(tr -d '\r' < "$T16_UNREAD_FILE" | tr '\n' ' ' | tr -s ' ')"
  if ! grep -qF -e "$T16_UNREAD_SUBJECT" <<<"$T16_UNREAD_FLAT"; then
    T16_UNREAD_UNANCHORED="$T16_UNREAD_UNANCHORED $T16_UNREAD_FILE"
    continue
  fi
  for T16_UNREAD_SPELLING in "$T16_UNREAD_TOKEN" "$T16_UNREAD_PARAPHRASE" "$T16_UNREAD_COUNT_CLAIM"; do
    if grep -qF -e "$T16_UNREAD_SPELLING" <<<"$T16_UNREAD_FLAT"; then
      T16_UNREAD_SURVIVING="$T16_UNREAD_SURVIVING [$T16_UNREAD_FILE: $T16_UNREAD_SPELLING]"
    fi
  done
done
if [ -n "$T16_UNREAD_UNANCHORED" ]; then
  echo "  FAIL  T16.14 setup error: a copy of the contract no longer names $T16_UNREAD_SUBJECT"
  echo "        file(s):$T16_UNREAD_UNANCHORED"
  echo "        the absence set would otherwise pass over a haystack that stopped carrying the field"
  FAIL=$((FAIL + 1))
elif [ -n "$T16_UNREAD_SURVIVING" ]; then
  echo "  FAIL  T16.14 a retired claim about what reads chainComplete is still in the tree"
  echo "        surviving spelling(s):$T16_UNREAD_SURVIVING"
  echo "        checked: $SOLVE_FLEET_JS and $SOLVE_FLEET_SKILL"
  echo "        chainComplete has a production reader since #592 — each of these tells the next reader it has none, or that it has only the one"
  FAIL=$((FAIL + 1))
elif ! grep -qF -e "$T16_READ_MARKER" "$SOLVE_FLEET_JS"; then
  echo "  FAIL  T16.14 the retired unread-register claim is gone, but nothing records what replaced it"
  echo "        marker: $T16_READ_MARKER"
  echo "        file: $SOLVE_FLEET_JS"
  echo "        deleting the entry is not discharging it — the next reader learns neither that chainComplete is read nor since when (#592)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T16.14 the unread register entry is discharged: every retired spelling gone from both copies, the replacement marker present"
  PASS=$((PASS + 1))
fi

# T16.15 — the residual keeps a FILED pointer. #592 lands option 1 (flag): the
# issue behind a partial-chain PR is recorded and surfaced, and still never
# re-queued, because lib/goal-phase3.sh builds each next cycle from
# finding-labelled issues alone. Both copies of that residual — the script's own
# note and the SKILL.md section documenting the same field — must name the
# successor by number. A residual described as "a follow-up" is one nobody can
# check for later.
T16_SUCCESSOR='#613'
T16_SUCCESSOR_MISSING=""
for T16_SUCCESSOR_FILE in "$SOLVE_FLEET_JS" "$SOLVE_FLEET_SKILL"; do
  grep -qF -e "$T16_SUCCESSOR" "$T16_SUCCESSOR_FILE" \
    || T16_SUCCESSOR_MISSING="$T16_SUCCESSOR_MISSING $T16_SUCCESSOR_FILE"
done
if [ -z "$T16_SUCCESSOR_MISSING" ]; then
  echo "  PASS  T16.15 the flagged-not-re-queued residual points at filed issue $T16_SUCCESSOR in both copies"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T16.15 the partial-chain residual lost its filed successor number"
  echo "        literal: $T16_SUCCESSOR"
  echo "        absent from:$T16_SUCCESSOR_MISSING"
  echo "        an unnamed follow-up cannot be checked — that rule is the register note's own (#592)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== T18: review-fleet's seam record cites symbols, not offsets (#606) =="
# The same defect class as the block below, in a different pair of files and
# with a worse outcome. skills/review-fleet/workflow.js carries the seam
# rationale, skills/review-fleet/SKILL.md restates it for a reader who never
# opens the script, and both were written in file offsets.
#
# What a rotted offset costs here is more than an unresolvable pointer. The
# offsets naming the push fence had drifted, and the sentence resting on them —
# that `review_publish_same_repo_pr_head` is "genuinely not an on-disk
# executable" — is measurably FALSE: the function is defined in
# lib/review-fences.sh and commands/review-pr.md calls it. An offset nobody can
# resolve is an offset nobody re-checks, so the claim built on it goes false
# unnoticed. That is why T18.4 lints the CLAIM and not only the citation.
#
# Three slices, each anchored on prose the files already ship — a shipped
# SKILL.md must not grow test-only markers the way this file does for itself:
#   (b) workflow.js, the numbered `Consequences` list: its heading through the
#       last line of item 5.
#   (c) SKILL.md, the section on what the script deliberately does not do.
#   (d) SKILL.md, the section on why the run is staged. A SEPARATE slice
#       because it holds the SKILL.md mirror of (b)'s byte-shape-oracle cite,
#       and de-lining one copy but not the other is precisely the drift this
#       issue is about.
#
# DECLARED OMISSIONS, recorded so they read as decisions rather than oversights:
# the preamble ABOVE numbered item 1 in workflow.js and the BOUND-CHILD PROTOCOL
# block below item 5 both cite lib/code_fixer_contract.py by offset, and both are
# left exactly as they are — as is every other offset in that file outside slice
# (b). They point into a different file with a different blast radius, and
# sweeping them here would turn a fix for a record that had already gone false
# into a repo-wide file:line migration.
#
# Row ids T18.6 through T18.8 are an intentional gap: an earlier draft reserved
# them for slice (a) rows that the block below now covers from the record's own
# backticks (T18.10a-c) and its numeral ban (T18.11). A retired id stays retired
# — reusing one reads as a resurrected row. T18.5 is not one of them: it is the
# row that closes the record's `out`-binding list against the script, and it is
# written in the block below under the id it was specified with, which is why
# the ids there do not read in printing order.

# --- Citation-lint detectors, section-local to T18 --------------------------
# TWO forms, because a rotted citation comes in two shapes and one regex sees
# only the first. T18_ANCHOR_RE catches `path.ext:N` and the `RP:`/`GS:`/`MP:`/
# `SKILL:` shorthand. T18_BARE_OFFSET_RE catches the BARE offset — a colon and
# a run of digits with no filename in front of them, parenthesised or not —
# which names no file at all and is the form a reader cannot even resolve
# without guessing which file was meant.
#
# Declared HERE, named for the section that owns them, rather than at file
# scope beside the shared `assert_*` / `da_*` helpers: those helpers are
# parameterised shapes with no policy in them, while these two ARE the policy —
# they decide what this section counts as a citation, and that decision was
# argued for these four slices and nothing else. At file scope a later section
# could pick either of them up by accident and inherit a definition it never
# argued for. Every call site is in this section or the one after it.
#
# Both forms are described below by SHAPE, never by quoting an offset sampled
# out of the tree. A comment that names the wrapping "actually in use" is a
# present-tense measurement of the tree, which is the exact species of claim
# these detectors exist to catch — it goes false the moment the file it sampled
# is edited, and nothing here lints a comment this far above the rows.
#
# Measured over the T16 design record as this change found it: of its EIGHT
# citations T18_ANCHOR_RE saw exactly ONE. The bare form is the half that
# matters here, which is why it is not folded into the anchor regex.
#
# T18_ANCHOR_RE restates T9.1's ANCHOR_RE further down, verbatim. That is
# deliberate and follows the standing decision tests/epipe-guard.test.sh records
# for its own restatement: hoisting two call sites in two suites would buy
# indirection rather than reuse. Do not hoist either of these. How many such
# restatements exist repo-wide is NOT recorded here — an ordinal typed into a
# comment is a count the code can move past without telling it, which is the
# thing T18.11 lints the record below for.
T18_ANCHOR_RE='\.(md|sh|py|js|json|yaml|yml):[0-9]+|(^|[^A-Za-z])(RP|GS|MP|SKILL):[0-9]+'
# The leading negated class is what keeps the bare form usable: it excludes
# clock times (`12:30`), `host:8080`, `http://…` and `${x:0:3}`. In every one
# of those the character immediately before the colon is alphanumeric, `_` or
# `/`, so the class rejects the match on its own. The optional `[(`]` admits
# the two wrappings the lint has to survive: a parenthesised offset in a shell
# comment, where `(` sits immediately before the colon, and its backticked
# Markdown twin, where the backtick consumes the optional class and `(`
# satisfies the preceding negated class.
#
# The digit run is `+`, with no floor under it, and the floor is worth a note
# because an earlier edition of this line carried one. It matched two digits or
# more and justified itself by saying that widening would match `x:0` and every
# `1:1` ratio in prose. That reads like an argument and is FALSE on execution —
# the leading class already rejects both, because what precedes the colon in
# them is a digit. Executed over the four slices this section lints, the
# unfloored form matches nothing the floored one did not, while a one-digit
# offset planted in slice (c) reds T18.1 where the floored form let it through.
# A boundary that costs nothing it claims to cost and buys a hole is the same
# species of defect this section exists to retire, so it is gone rather than
# re-argued. What the linted regions happen to contain today is NOT recorded
# here — a survey of the tree written into a comment is the thing that rots.
T18_BARE_OFFSET_RE='(^|[^A-Za-z0-9_/])[(`]?:[0-9]+'

T18_RF_B_START='Consequences, stated so nobody re-derives them wrongly later'
T18_RF_B_END='strictly better than the pseudocode.'
T18_RF_C_START='### What the script deliberately does **not** do'
T18_RF_D_START='### Why the run is staged instead of one call'
# One shape for both markdown ends: a section runs until the next heading or the
# next horizontal rule, because nothing in its closing line says it is closing.
#
# DECLARED BOUNDARY: `^#+ ` is also the shape of a shell comment, so a fenced
# code block containing one would end the slice at that line and every citation
# below the cut would become invisible to T18.1. The non-vacuity floors below
# sit well under the live sizes — they catch a slice that collapsed, not one
# that was trimmed — so this end shape has to learn about fences before either
# slice may grow one. Neither ships a fenced block today.
T18_RF_MD_END='^---$|^#+ '
T18_RF_B="$(da_slice_between "$REVIEW_FLEET_JS" "$T18_RF_B_START" "$T18_RF_B_END")"
T18_RF_C="$(da_slice_until_re "$REVIEW_FLEET_SKILL" "$T18_RF_C_START" "$T18_RF_MD_END")"
T18_RF_D="$(da_slice_until_re "$REVIEW_FLEET_SKILL" "$T18_RF_D_START" "$T18_RF_MD_END")"
# All three slices UNWRAPPED as well, for every row whose needle is multi-word:
# a shared symbol, a whole sentence, a quoted pseudocode line. Slice (b) is the
# measurement that forces this — it DOES rest the rejection on the seam and it
# DOES name the byte-shape oracle, but it writes both across a line break, so
# the raw slice answers "absent" to needles the file plainly carries. A row that
# reds on where a comment wraps reports a fault that did not happen.
#
# Slice (d) is unwrapped for the same reason even though it is a markdown table
# rather than a comment block: T18.2i reads it for the `encode-aggregate` anchor
# that replaced this change's de-lined `commands/simplify.md` offset, and there
# is nothing to stop a later re-flow breaking that cell across two source lines.
T18_RF_B_PROSE="$(da_unwrap_prose "$T18_RF_B")"
T18_RF_C_PROSE="$(da_unwrap_prose "$T18_RF_C")"
T18_RF_D_PROSE="$(da_unwrap_prose "$T18_RF_D")"

# Every row EMITTER is guarded, unlike the helpers that build the bodies: a
# renamed builder reds the non-vacuity rows through an empty capture, but a
# renamed emitter prints nothing at all — no row, no FAIL, and a total this file
# has no floor on. That is a silent coverage loss, which is the failure mode
# this whole section exists to retire.
#
# The guarded set is DERIVED from this file's own text, never retyped here. A
# spelled-out list can only vet the emitters somebody remembered to add to it,
# and both halves of that gap are measured rather than feared: with the list
# spelled out, renaming an UNLISTED emitter's definition dropped T18.9/T18.9a and
# the run still ended rc 0, and typo'ing a LISTED emitter's call site dropped
# T18.2a just as quietly — while the abort text claimed to catch exactly that.
# A guard whose predicate is disjoint from the drift it advertises is the defect
# #606 exists to close, so it may not be rebuilt inside the fix for it. No count
# of emitters is stated anywhere here for the same reason: it is one more figure
# the code could move past while the prose kept asserting it.
#
# CALL SITES are the harvest, not definitions: a renamed definition is only a
# fault because some call site still says the old name, so `command -v` over the
# CALLED names is what notices, and a rename that updates both is a legitimate
# rename that must stay green. The `da_assert_` prefix is the seam between
# emitters and builders, so a new emitter is covered the day it is named. Both
# harvests are pinned to column 0: a call in this file is never indented, and an
# emitter name quoted inside a comment or a FAIL string must not enlist itself.
t18_defined_emitters="$(grep -oE '^da_assert_[a-z_]+\(\)' "$DOCS_ACCURACY_SELF" | sed 's/()$//' | sort -u)"
t18_called_emitters="$(grep -oE '^da_assert_[a-z_]+[[:space:]]' "$DOCS_ACCURACY_SELF" | sed 's/[[:space:]]*$//' | sort -u)"

# Non-vacuity for the harvest itself: an empty definition set means the pattern
# stopped matching, and every arm below would then vet nothing and pass.
[ -n "$t18_defined_emitters" ] || {
  echo "FATAL: T18 emitter harvest matched no 'da_assert_*() {' definition in $DOCS_ACCURACY_SELF — the guards below would vet an empty set and every emitter row could vanish unnoticed" >&2
  exit 2
}

# Herestrings, not pipes: a `while read` on the right-hand side of a pipe runs in
# a subshell, where `exit 2` would abort the loop and let the run continue green.
#
# This runs before the first call site, so it aborts instead of letting rows go
# missing — which also means an emitter must be DEFINED above here, up with the
# other helpers. Adding one below this point trips the same abort, and the text
# says so rather than sending the reader hunting for a rename that never
# happened; a guard that misnames the fault is the class #606 exists to close.
while IFS= read -r t18_fn; do
  [ -n "$t18_fn" ] || continue
  command -v "$t18_fn" >/dev/null 2>&1 || {
    echo "FATAL: T18 row emitter $t18_fn is called but not defined at this point in the run (renamed definition, a typo'd call site, or a definition added BELOW this guard instead of up with the other helpers) — its rows would vanish from the run rather than fail" >&2
    exit 2
  }
done <<<"$t18_called_emitters"

# The reverse direction, which is what keeps the call-site harvest honest: if it
# silently stopped matching, the loop above would vet nothing and still pass.
while IFS= read -r t18_fn; do
  [ -n "$t18_fn" ] || continue
  grep -qxF "$t18_fn" <<<"$t18_called_emitters" || {
    echo "FATAL: T18 row emitter $t18_fn is defined but never called at column 0 — it is dead, or its call is indented where the guard above cannot see it and so cannot vet it" >&2
    exit 2
  }
done <<<"$t18_defined_emitters"

# T18.0b/T18.0c/T18.0d — non-vacuity, per slice, before anything reads them.
da_assert_slice_intact T18.0b 'review-fleet workflow.js consequences' 20 110 "$T18_RF_B" \
  "$T18_RF_B_START" "$T18_RF_B_END"
da_assert_slice_intact T18.0c 'review-fleet SKILL.md rejected-proposals section' 10 55 "$T18_RF_C" \
  "$T18_RF_C_START" "$T18_RF_MD_END"
da_assert_slice_intact T18.0d 'review-fleet SKILL.md staged-run section' 6 30 "$T18_RF_D" \
  "$T18_RF_D_START" "$T18_RF_MD_END"

# T18.1 — citation-free under THREE detectors, all three slices, with the FAIL
# arm naming the slice each match came from. "There is an offset somewhere in
# review-fleet" is not an actionable diagnostic when the offsets live in two
# files and three sections.
#
# Two of the three are the file's SHARED detectors, reused rather than restated.
# The standing decision recorded beside them is that the one existing restatement
# of T9.1's regex is the last one this file gets; a fourth copy declared inside
# this section would be one more place for the definition of a citation to drift
# from the others.
#
# The third detector is local to this row and exists because these two files
# cite one thing the T16 record never does: an RFC's pseudocode, addressed in
# WORDS as `line 153`. That form carries no colon, so neither shared detector
# can see it — and measured at the baseline, all three of the line references in
# these slices had rotted exactly like the offsets beside them: RFC 0012 §3.1's
# pseudocode had moved, and each number named an unrelated paragraph. A citation
# spelled in English is still a citation.
#
# Declared cost, since a lint on `line <n>` is broader than a lint on `:<n>`:
# these slices may not discuss a numbered line by its number at all. That is the
# intended ratchet — name the pseudocode line by what it SAYS, which is what
# both copies already quote and what T18.2f-T18.2h then resolve against the RFC.
T18_RF_PROSE_OFFSET_RE='(^|[^A-Za-z])lines?[[:space:]]+[0-9]+'
T18_RF_CITED=""
for t18_slice in b c d; do
  case "$t18_slice" in
    b) t18_body="$T18_RF_B"; t18_where="(b) $REVIEW_FLEET_JS — $T18_RF_B_START" ;;
    c) t18_body="$T18_RF_C"; t18_where="(c) $REVIEW_FLEET_SKILL — $T18_RF_C_START" ;;
    d) t18_body="$T18_RF_D"; t18_where="(d) $REVIEW_FLEET_SKILL — $T18_RF_D_START" ;;
  esac
  t18_hits="$({ grep -oE -e "$T18_ANCHOR_RE" <<<"$t18_body" || true
                grep -oE -e "$T18_BARE_OFFSET_RE" <<<"$t18_body" || true
                grep -oE -e "$T18_RF_PROSE_OFFSET_RE" <<<"$t18_body" || true; } | sort -u)"
  [ -z "$t18_hits" ] || T18_RF_CITED="$T18_RF_CITED
        $t18_where
$(sed 's/^/          /' <<<"$t18_hits")"
done
if [ -z "$T18_RF_CITED" ]; then
  echo "  PASS  T18.1 all three review-fleet slices are citation-free under all three detectors"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T18.1 the review-fleet seam record still addresses code by line number"
  echo "        offending matches, by slice:$T18_RF_CITED"
  echo "        cite the symbol — or the sentence — the number was pointing AT; the line moves, the name does not"
  FAIL=$((FAIL + 1))
fi

# T18.2a-T18.2h — the RESOLVE direction: the symbols those offsets were replaced
# with have to still exist in the files they name.
#
# That is one direction of two, and it is worth being exact about which one,
# because the obvious reading of these rows is wrong: da_assert_symbol_resolves
# opens the CITED file and nothing else. It never reads the slice doing the
# citing. So it proves the target still carries the string and it cannot see
# whether slices (b), (c) or (d) still name it — while T18.1, the row this
# family exists to complete, is satisfied by DELETING a citation exactly as well
# as by fixing one, which trades a stale pointer for no pointer at all.
#
# T18.2i is the other direction, and neither is worth much alone. That is the
# same both-directions rule T18.10a/T18.10b state for the T16 record's fragment
# table further down, applied to the review-fleet slices.
da_assert_symbol_resolves T18.2a "$POST_IMPL_SKILL" 'post_review_write_aggregate_v2' \
  'the deterministic aggregate writer whose no-pathname-authority rule both copies quote'
da_assert_symbol_resolves T18.2b "$REVIEW_AGGREGATE_SH" 'post_review_write_aggregate_v2()' \
  'the on-disk definition that retired the "no executable to invoke" rejection'
da_assert_symbol_resolves T18.2c "$SIMPLIFY_CMD" 'encode-aggregate --phase phase2' \
  'the byte-shape oracle the simplify stage hands to Bash'
da_assert_symbol_resolves T18.2d "$REVIEW_FENCES_SH" 'review_publish_same_repo_pr_head()' \
  'the push fence, on disk — the measurement that makes T18.4 a correction and not a re-wording'
# T18.2e — the CLAIM the aggregate-writer citation exists to support, not just
# the symbol. Read against a whitespace-FLATTENED copy: measured, the raw
# `grep -c` for this sentence is 0 because post-impl-review/SKILL.md wraps it
# after "aggregation", so a raw probe would red a correct tree and teach the
# next reader to delete the row. Never assert a wrapped prose claim against raw
# lines.
T18_PIR_FLAT="$(tr -d '\r' < "$POST_IMPL_SKILL" | tr '\n' ' ' | tr -s ' ')"
if grep -qF -e 'does not use any pathname as aggregation authority' <<<"$T18_PIR_FLAT"; then
  echo "  PASS  T18.2e the quoted no-pathname-authority rule is still the writer's own words"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T18.2e the review-fleet copies quote a rule post-impl-review/SKILL.md no longer states"
  echo "        file: $POST_IMPL_SKILL"
  echo "        quoted: does not use any pathname as aggregation authority"
  echo "        a quotation that survives its source is the same rot as an offset that survives its line"
  FAIL=$((FAIL + 1))
fi

# T18.2f-T18.2h — the same rule for the three RFC pseudocode lines the slices
# used to address by number. Each is now quoted, and a quotation is only an
# anchor while it is still the RFC's own words. The `what it supports` text on
# each names the two copies that reject the proposal; that is a claim about the
# review-fleet slices, which these rows do not open — T18.2i is the row that
# holds it, for these three needles and for every other anchor above.
da_assert_symbol_resolves T18.2f "$WORKFLOW_RFC" 'haiku writer emits post-impl-review-final.md' \
  'the aggregate-writer proposal both copies reject'
da_assert_symbol_resolves T18.2g "$WORKFLOW_RFC" 'push agent (haiku): git push origin HEAD' \
  'the push-agent proposal both copies reject'
da_assert_symbol_resolves T18.2h "$WORKFLOW_RFC" 'brief agent: gh pr diff' \
  'the brief-relay proposal both copies reject'

# T18.2i — the CITE direction for every anchor T18.2a-T18.2h resolves, and the
# row that makes the paragraph above true rather than merely well-intentioned.
# One declared table, answering one question per anchor: which slices have to
# still NAME it?
#
# Four of these anchors had no citation-side cover anywhere in the suite, and
# slice (d) was read by nothing that asks what it must CONTAIN — only by T18.0d,
# which asks whether it still exists, and by T18.1, which asks what it must not
# contain. Measured before this row existed: replacing
# `code_fixer_contract.py encode-aggregate --phase phase2` in
# slice (d)'s table cell with "the byte-shape encoder" left the whole run green,
# and the cell degraded to a bare `commands/simplify.md` with no symbol beside
# it — the "no pointer at all" outcome the rows above say they prevent. The same
# was true of the three RFC quotes in both copies, which T18.1 then forbids
# reverting to `line 153`: the pseudocode would end up cited by nothing.
#
# The overlap with T18.3's two shared symbols is deliberate. T18.3 asserts
# SYMMETRY — that the two prose copies did not drift apart — over a list curated
# for that purpose, and it never reads slice (d). This row asserts PERSISTENCE:
# each replacement anchor is still cited where the de-lining put it. Two
# different predicates that happen to agree on two members. Letting either one's
# coverage rest on the other's list would make a retirement over there a silent
# coverage loss over here, which is the class this section exists to retire.
#
# Curated rather than derived, for the reason T18.3 records: the three slices
# are a rationale, a summary and a stage table, not mirrors of each other. An
# anchor is listed for a slice only where that slice's argument DEPENDS on it —
# pinning an incidental mention would red a legitimate re-write with a fault
# that did not happen.
#
# Every needle is read against the UNWRAPPED slice bodies, and that is not
# optional: measured, slice (b) breaks the `encode-aggregate` needle across a
# line break and both copies break the no-pathname-authority sentence, so a raw
# probe would red a correct tree on where its prose happens to wrap.
REVIEW_FLEET_CITED_ANCHORS='post_review_write_aggregate_v2|bc
review_publish_same_repo_pr_head|bc
encode-aggregate --phase phase2|bd
haiku writer emits post-impl-review-final.md|bc
push agent (haiku): git push origin HEAD|bc
brief agent: gh pr diff|bc
does not use any pathname as aggregation authority|bc'
T18_CITE_PAIRS=0
T18_CITE_UNCITED=""
T18_CITE_MALFORMED=""
while IFS= read -r t18_pair; do
  [ -n "$t18_pair" ] || continue
  t18_needle="${t18_pair%|*}"
  t18_want="${t18_pair##*|}"
  # The slice field is a CLOSED set of one-letter names, and it is validated as
  # one before it is used. A field that names nothing this section knows — a
  # typo, a retired letter, a needle whose slice was renamed — would otherwise
  # check no slice at all while still reading as a table entry, and the row
  # would report a smaller number in its PASS text and nothing else. Measured
  # while writing this row: with only a pair floor under it, corrupting ONE
  # entry's field left the whole suite green. So every letter must resolve to a
  # slice, and the count of resolved letters must equal the field's length,
  # which is what makes `bcz` and `bb` faults rather than near-misses.
  t18_hit=0
  for t18_slice in b c d; do
    case "$t18_want" in
      *"$t18_slice"*) ;;
      *) continue ;;
    esac
    t18_hit=$((t18_hit + 1))
    case "$t18_slice" in
      b) t18_body="$T18_RF_B_PROSE"; t18_where="slice (b), ${REVIEW_FLEET_JS#$REPO_ROOT/}" ;;
      c) t18_body="$T18_RF_C_PROSE"; t18_where="slice (c), ${REVIEW_FLEET_SKILL#$REPO_ROOT/}" ;;
      d) t18_body="$T18_RF_D_PROSE"; t18_where="slice (d), ${REVIEW_FLEET_SKILL#$REPO_ROOT/}" ;;
    esac
    T18_CITE_PAIRS=$((T18_CITE_PAIRS + 1))
    grep -qF -e "$t18_needle" <<<"$t18_body" \
      || T18_CITE_UNCITED="$T18_CITE_UNCITED
        $t18_where no longer names: $t18_needle"
  done
  if [ "$t18_hit" -lt 1 ] || [ "${#t18_want}" -ne "$t18_hit" ]; then
    T18_CITE_MALFORMED="$T18_CITE_MALFORMED
        slice field '$t18_want' is not a set of (b|c|d) — entry: $t18_needle"
  fi
done <<EOF_T18_CITED
$REVIEW_FLEET_CITED_ANCHORS
EOF_T18_CITED
if [ -n "$T18_CITE_MALFORMED" ]; then
  echo "  FAIL  T18.2i an entry in the citation table names a slice this section does not have"
  echo "        malformed:$T18_CITE_MALFORMED"
  echo "        such an entry checks nothing while still looking like coverage — fix the letter, or delete the entry deliberately"
  FAIL=$((FAIL + 1))
elif [ "${T18_CITE_PAIRS:-0}" -lt 10 ] 2>/dev/null; then
  echo "  FAIL  T18.2i the citation table did not read — ${T18_CITE_PAIRS:-0} (anchor, slice) pairs seen, floor 10, so this row asserted almost nothing"
  echo "        an empty capture satisfies every needle below vacuously (#347)"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_CITE_UNCITED" ]; then
  echo "  FAIL  T18.2i a replacement anchor is no longer cited by the slice the de-lining put it in"
  echo "        uncited:$T18_CITE_UNCITED"
  echo "        deleting a citation satisfies T18.1 just as well as fixing one — restore the symbol, or retire its entry here in the SAME change"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.2i all $T18_CITE_PAIRS (anchor, slice) pairs still cite the symbol that replaced their offset"
  PASS=$((PASS + 1))
fi

# T18.3 — the two copies agree on the symbols they BOTH carry. Curated, not
# derived, and the reason is a measurement: slice (b) additionally names
# review_fixer_terminal_outcome, review_track_validated_fixer_head,
# AskUserQuestion and the script's own shape gates, while in SKILL.md those
# belong to slice (d) and to the bullet list above slice (c). The blocks are a
# rationale and a summary of two rejected proposals, not mirrors of each other,
# so a whole-block set equality would fail on its first execution and get
# relaxed into nothing. What IS symmetric is the shared claim, and that is what
# this list pins: a one-sided edit that drops any member from either copy reds.
#
# Every member must also resolve OUTSIDE the two prose copies — a path has to
# exist on disk, a function name has to appear under lib/ or commands/ — so a
# symbol the two copies only cite at each other cannot satisfy this row.
#
# Presence is checked against the UNWRAPPED bodies: a path token is exactly the
# kind of needle a markdown re-flow lands inside.
REVIEW_FLEET_REJECTION_SYMBOLS='post_review_write_aggregate_v2
review_publish_same_repo_pr_head
review_refresh_phase1_scope
lib/review-aggregate.sh
lib/review-fences.sh'
T18_SYM_CHECKED=0
T18_SYM_ONESIDED=""
T18_SYM_DEAD=""
while IFS= read -r t18_sym; do
  [ -n "$t18_sym" ] || continue
  T18_SYM_CHECKED=$((T18_SYM_CHECKED + 1))
  grep -qF -e "$t18_sym" <<<"$T18_RF_B_PROSE" \
    || T18_SYM_ONESIDED="$T18_SYM_ONESIDED
        $t18_sym  (absent from slice (b), workflow.js)"
  grep -qF -e "$t18_sym" <<<"$T18_RF_C_PROSE" \
    || T18_SYM_ONESIDED="$T18_SYM_ONESIDED
        $t18_sym  (absent from slice (c), SKILL.md)"
  case "$t18_sym" in
    */*) [ -r "$PLUGIN_DIR/$t18_sym" ] \
           || T18_SYM_DEAD="$T18_SYM_DEAD
        $t18_sym  (no such file under $PLUGIN_DIR)" ;;
    *)   grep -rqF -e "$t18_sym" "$PLUGIN_DIR/lib" "$PLUGIN_DIR/commands" \
           || T18_SYM_DEAD="$T18_SYM_DEAD
        $t18_sym  (named by the prose, defined nowhere under lib/ or commands/)" ;;
  esac
done <<EOF_T18_SYMBOLS
$REVIEW_FLEET_REJECTION_SYMBOLS
EOF_T18_SYMBOLS
if [ "${T18_SYM_CHECKED:-0}" -lt 4 ] 2>/dev/null; then
  echo "  FAIL  T18.3 the shared-symbol list did not read — ${T18_SYM_CHECKED:-0} members seen, floor 4, so this row asserted almost nothing"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_SYM_ONESIDED$T18_SYM_DEAD" ]; then
  echo "  FAIL  T18.3 the two review-fleet copies have drifted apart, or name something that does not exist"
  [ -z "$T18_SYM_ONESIDED" ] || echo "        one-sided:$T18_SYM_ONESIDED"
  [ -z "$T18_SYM_DEAD" ] || echo "        unresolved:$T18_SYM_DEAD"
  echo "        edit both copies in the same change, or retire the member here in that same change"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.3 all $T18_SYM_CHECKED shared symbols are in both review-fleet copies and resolve outside them"
  PASS=$((PASS + 1))
fi

# T18.4 — the CLAIM row, and the reason this section is a correction rather than
# a de-lining. Two halves, because either alone is satisfiable without fixing
# anything: the false rule must be gone from BOTH files, and the true reason
# must be spelled the SAME way in both slices. Delete the paragraph and the
# absence half passes; keep the paragraph and re-word only one copy and the
# agreement half fails.
T18_FALSE_REJECTION='not an on-disk executable'
T18_SEAM_REASON='the controller proves, it does not delegate the proof to an LLM'
T18_CLAIM_FAULTS=""
for t18_copy in "$REVIEW_FLEET_JS" "$REVIEW_FLEET_SKILL"; do
  ! grep -qF -e "$T18_FALSE_REJECTION" "$t18_copy" \
    || T18_CLAIM_FAULTS="$T18_CLAIM_FAULTS
        $t18_copy still claims: $T18_FALSE_REJECTION"
done
grep -qF -e "$T18_SEAM_REASON" <<<"$T18_RF_B_PROSE" \
  || T18_CLAIM_FAULTS="$T18_CLAIM_FAULTS
        slice (b) does not rest the rejection on: $T18_SEAM_REASON"
grep -qF -e "$T18_SEAM_REASON" <<<"$T18_RF_C_PROSE" \
  || T18_CLAIM_FAULTS="$T18_CLAIM_FAULTS
        slice (c) does not rest the rejection on: $T18_SEAM_REASON"
if [ -z "$T18_CLAIM_FAULTS" ]; then
  echo "  PASS  T18.4 neither copy still calls the push fence off-disk, and both rest the rejection on the seam"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T18.4 a review-fleet rejection rests on a reason that is false, or on two different reasons"
  echo "        faults:$T18_CLAIM_FAULTS"
  echo "        review_publish_same_repo_pr_head() is defined in lib/review-fences.sh — T18.2d measures it on every run"
  FAIL=$((FAIL + 1))
fi

echo
echo "== T18: this suite's OWN T16 design record cites symbols, not offsets (#606) =="
# The prose that explains T16.9-T16.11 was written entirely in citations —
# eight of them, one `workflow.js:<line>` and seven bare `:<line>` offsets —
# and by the time this section was written every one of them pointed somewhere
# else. That is precisely the class T9.1 lints in the RFCs, reproduced inside
# the suite whose job is to catch it, and unguarded because no row until now
# read this file's own prose.
#
# No release number appears in this section on purpose. A version literal here
# would put this file in `git grep -ln <version>`, where the bump ritual reads
# its list of release surfaces from — and this file is not one.
#
# TWO regions, not one, and the second is not optional. The drift this change
# retires is split across them: the offsets and a binding count sat in the
# citation block, but the member-count claim sat in the floor rationale a few
# lines below it, OUTSIDE. Scope the lint to the citation block alone and that
# claim goes unguarded no matter how good the predicate is — the region boundary
# decides what these rows can ever SEE, and a criterion that cannot reach the
# drift it must find is the defect this issue is filed against. Measured on the
# pre-rewrite prose: the member-count phrase matched ZERO times when the slice
# was the citation block by itself.
#
# Neither title carries a row id, deliberately. A title is echoed by the rows
# below, and a title of the form `T16.9 …` puts a second `T16.9` in the run
# output — which is the one-id-two-meanings collision this file already carries
# at `T16.10`, where two unrelated rows answer to that id. That collision is
# pre-existing and stays out of scope here; adding a THIRD instance of it while
# fixing something else is what this naming rule prevents.
T18_CITE_TITLE='T16 citation block'
T18_FLOOR_TITLE='T16 member-count floor rationale'
T18_CITE_REGION="$(da_marked_region "$T18_CITE_TITLE")"
T18_FLOOR_REGION="$(da_marked_region "$T18_FLOOR_TITLE")"

# T18.9 / T18.9a — non-vacuity, asserted per region before anything reads them.
da_assert_region_intact T18.9  "$T18_CITE_TITLE"  15 "$T18_CITE_REGION"
da_assert_region_intact T18.9a "$T18_FLOOR_TITLE"  5 "$T18_FLOOR_REGION"

# S-D: both regions, linted as one body. The FAIL arm prints every offending
# match rather than just failing, because "there is a citation somewhere in
# this block" is not an actionable diagnostic.
T18_SD="$T18_CITE_REGION
$T18_FLOOR_REGION"

# The record UNWRAPPED, by the shared helper: every consumer below that looks up
# a MULTI-WORD needle reads this body, never the raw slice, because a comment
# wraps wherever the writer's re-flow puts the break and a quoted span — or the
# `pattern` word that exempts one — can straddle two source lines. The helper's
# own header carries the argument and the one declared boundary; measured here
# against re-wraps of the `var out` sentence whose content is byte-identical — a
# flat `# ` continuation, an INDENTED bullet continuation, and a break taken
# after a trailing space — all three are inert.
#
# T18.10b and T18.10c read this unwrapped body. T18.10 and T18.11 keep reading
# the raw `$T18_SD`, deliberately: their needles are single tokens (a file
# offset, a numeral, a spelled cardinal) that no line break can split, and the
# raw slice keeps each match on the source line a reader can go open.
T18_SD_PROSE="$(da_unwrap_prose "$T18_SD")"

# T18.5 — the CLOSURE row for the record's `out` paragraph, and the reason that
# paragraph may be a LIST at all. A list of names is only better than a count
# while it stays complete. The count it replaced went wrong when a later
# binding was added; a list goes wrong the same way and more quietly, because
# every name still in it stays correct while the SET stops being the whole set.
# Measured on the edition that shipped the list without this row: appending a
# new function with its own `out` binding to the script left every row in this
# section green, with the record's closed-set sentence already false.
#
# DERIVED on the script side, CURATED on the record side, compared in BOTH
# directions. Every `var` / `let` / `const` binding of `out` in the script is
# resolved to the nearest enclosing `function` definition above it; a binding
# whose encloser the record does not name FAILS, and a name the record lists
# that no longer encloses a binding FAILS too. A third arm reads the record
# itself, so dropping a name from the prose is caught from the prose side as
# well. Deriving BOTH sides would only prove awk agrees with itself — the
# curated side is what makes this a comparison against a claim.
#
# awk is handed the PATH and reads it to EOF: no early exit, so no writer dies
# on EPIPE and poisons `pipefail` (tests/epipe-guard.test.sh), and the CR strip
# happens inside awk because the windows job checks out with core.autocrlf=true
# and grep cannot see a CR.
#
# DECLARED BOUNDARY: the encloser is the nearest preceding `function` keyword,
# so a binding inside a function EXPRESSION or an arrow assigned to a variable
# is attributed to whatever named function encloses that expression. That is
# the right answer for the record — which names the site a reader would open —
# and it is why the harvest is not written as a brace-matching parser.
T18_OUT_SITES='sanitizeEscalationReason
taskReviewPrompt
unpushedIssue
runTaskChain
solveOne'
T18_OUT_BOUND_IN="$(awk '
  { sub(/\r$/, "") }
  /^[[:space:]]*(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*\(/ {
    t18fn = $0
    sub(/^[[:space:]]*(async[[:space:]]+)?function[[:space:]]+/, "", t18fn)
    sub(/[[:space:]]*\(.*$/, "", t18fn)
  }
  /(^|[^A-Za-z0-9_$])(var|let|const)[[:space:]]+out([^A-Za-z0-9_$]|$)/ {
    printf "%s\n", (t18fn == "" ? "(bound above the first function definition)" : t18fn)
  }
' "$SOLVE_FLEET_JS")"
T18_OUT_BINDINGS="$(grep -c . <<<"$T18_OUT_BOUND_IN" || true)"
T18_OUT_ENCLOSERS="$(sort -u <<<"$T18_OUT_BOUND_IN")"
T18_OUT_UNNAMED=""
T18_OUT_STALE=""
T18_OUT_UNCITED=""
T18_OUT_CHECKED=0
while IFS= read -r t18_encl; do
  [ -n "$t18_encl" ] || continue
  grep -qxF -e "$t18_encl" <<<"$T18_OUT_SITES" \
    || T18_OUT_UNNAMED="$T18_OUT_UNNAMED
        $t18_encl"
done <<EOF_T18_ENCLOSERS
$T18_OUT_ENCLOSERS
EOF_T18_ENCLOSERS
while IFS= read -r t18_site; do
  [ -n "$t18_site" ] || continue
  T18_OUT_CHECKED=$((T18_OUT_CHECKED + 1))
  grep -qxF -e "$t18_site" <<<"$T18_OUT_ENCLOSERS" \
    || T18_OUT_STALE="$T18_OUT_STALE
        $t18_site"
  grep -qF -e "$t18_site" <<<"$T18_SD_PROSE" \
    || T18_OUT_UNCITED="$T18_OUT_UNCITED
        $t18_site"
done <<EOF_T18_SITES
$T18_OUT_SITES
EOF_T18_SITES
if [ "${T18_OUT_BINDINGS:-0}" -lt 4 ] 2>/dev/null || [ "${T18_OUT_CHECKED:-0}" -lt 4 ] 2>/dev/null; then
  echo "  FAIL  T18.5 the out-binding harvest did not read — ${T18_OUT_BINDINGS:-0} bindings and ${T18_OUT_CHECKED:-0} curated sites seen, floor 4 each, so this row asserted almost nothing"
  echo "        file: $SOLVE_FLEET_JS"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_OUT_UNNAMED$T18_OUT_STALE$T18_OUT_UNCITED" ]; then
  echo "  FAIL  T18.5 the T16 design record's list of out bindings is no longer closed over the script"
  echo "        script: $SOLVE_FLEET_JS"
  echo "        record: $DOCS_ACCURACY_SELF (region: $T18_CITE_TITLE)"
  [ -z "$T18_OUT_UNNAMED" ] || echo "        binds out, named by neither the record nor this row's site list:$T18_OUT_UNNAMED"
  [ -z "$T18_OUT_STALE" ] || echo "        listed as a binding site but binds out nowhere:$T18_OUT_STALE"
  [ -z "$T18_OUT_UNCITED" ] || echo "        a binding site the record has stopped naming:$T18_OUT_UNCITED"
  echo "        name the new site in the record and add it here in the SAME change — a list that is not closed is the count it replaced, with the staleness hidden better"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.5 every out binding in workflow.js sits in a function the T16 record names, and every site it names still binds one ($T18_OUT_BINDINGS bindings, $T18_OUT_CHECKED sites)"
  PASS=$((PASS + 1))
fi

# T18.10 — anchor-free under BOTH detectors. Measured before this change: 8
# matches (1 anchor form, 7 bare form).
T18_SD_HITS="$({ grep -oE -e "$T18_ANCHOR_RE" <<<"$T18_SD" || true
                 grep -oE -e "$T18_BARE_OFFSET_RE" <<<"$T18_SD" || true; } | sort -u)"
if [ -z "$T18_SD_HITS" ]; then
  echo "  PASS  T18.10 the T16 design record is citation-free under both detectors (symbols and quoted fragments only)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T18.10 the T16 design record still cites file offsets — the block that documents a drift guard cannot itself rot"
  echo "        file: $DOCS_ACCURACY_SELF (regions: $T18_CITE_TITLE, $T18_FLOOR_TITLE)"
  sed 's/^/        /' <<<"$T18_SD_HITS"
  echo "        cite a symbol or a quoted code fragment instead; a line number is stale the next time the file is edited"
  FAIL=$((FAIL + 1))
fi

# T18.10a / T18.10b / T18.10c — the POSITIVE half of T18.10, and the half that
# makes the conversion worth doing. Absence of offsets is satisfied just as well
# by prose that names fragments which no longer exist: the citation would have
# changed SHAPE without becoming resolvable, and rot the next time something is
# renamed. So every fragment the record quotes is looked up in the script it
# describes — in BOTH directions, which is the T9.3/T9.4 shape this file already
# runs over the RFC 0012 contract table.
#
# BOTH directions or the table certifies nothing. T18.10a asks whether the
# fragment still RESOLVES in the script; T18.10b asks whether the record still
# CITES it. Without T18.10b the record could drop every quoted binding and the
# resolve loop would still report a full table — those fragments resolve because
# the CODE carries them, which has nothing to do with whether the PROSE does.
#
# `needle|expected`: a number is an EXACT count — a fragment has to identify one
# site to be a citation at all, and a second `var out = reviewPath(` would mean
# the record's claim about that binding needs re-reading, not silently widening.
# `+` is at-least-once, for the entries the record cites as NAMES rather than as
# locations. The exact form can red on a legitimate duplication; that is the
# same declared trade the record itself makes about a stray assignment, a
# REVIEWABLE FALSE POSITIVE in place of a citation that quietly points nowhere.
T18_FRAGMENTS='ledger.complete =|1
r.prProof = "DISPROVEN"|1
prProof:|1
var out = s.replace(|1
var out = reviewPath(|1
unpushedIssue|+
deliverPrompt|+
solvePrompt|+
deliveryWorkspaceReady|+'
T18_FRAG_UNRESOLVED=""
T18_FRAG_UNCITED=""
T18_FRAG_CHECKED=0
while IFS='|' read -r t18_needle t18_want; do
  [ -n "$t18_needle" ] || continue
  T18_FRAG_CHECKED=$((T18_FRAG_CHECKED + 1))
  t18_got="$(grep -cF -e "$t18_needle" "$SOLVE_FLEET_JS" || true)"
  case "$t18_want" in
    '+') [ "${t18_got:-0}" -ge 1 ] 2>/dev/null \
           || T18_FRAG_UNRESOLVED="$T18_FRAG_UNRESOLVED
        $t18_needle  (found ${t18_got:-0}, want at least 1)" ;;
    *)   [ "${t18_got:-0}" -eq "$t18_want" ] 2>/dev/null \
           || T18_FRAG_UNRESOLVED="$T18_FRAG_UNRESOLVED
        $t18_needle  (found ${t18_got:-0}, want exactly $t18_want)" ;;
  esac
  grep -qF -e "$t18_needle" <<<"$T18_SD_PROSE" \
    || T18_FRAG_UNCITED="$T18_FRAG_UNCITED
        $t18_needle"
done <<EOF_T18_FRAGMENTS
$T18_FRAGMENTS
EOF_T18_FRAGMENTS
# A FLOOR, never the table's exact length: quoting a ninth fragment is a
# legitimate edit, and an `-ne <len>` self-count would hard-fail it with "the
# table did not read", which is a lie about what broke. The floor only has to
# catch the heredoc silently yielding nothing.
if [ "${T18_FRAG_CHECKED:-0}" -lt 6 ] 2>/dev/null; then
  echo "  FAIL  T18.10a the fragment table did not read — ${T18_FRAG_CHECKED:-0} entries seen, floor 6, so this row asserted almost nothing"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_FRAG_UNRESOLVED" ]; then
  echo "  FAIL  T18.10a the T16 design record quotes code that no longer resolves in the script it describes"
  echo "        file: $SOLVE_FLEET_JS"
  echo "        unresolved:$T18_FRAG_UNRESOLVED"
  echo "        a symbol that does not resolve is a line number with extra steps — re-read the code, then re-word the record"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.10a each of the $T18_FRAG_CHECKED curated fragments resolves in workflow.js at its declared count"
  PASS=$((PASS + 1))
fi

# T18.10b — the citation half. Same curated table, read against the RECORD.
if [ "${T18_FRAG_CHECKED:-0}" -lt 6 ] 2>/dev/null; then
  echo "  FAIL  T18.10b the fragment table did not read — ${T18_FRAG_CHECKED:-0} entries seen, floor 6, so this row asserted almost nothing"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_FRAG_UNCITED" ]; then
  echo "  FAIL  T18.10b the T16 design record no longer cites fragments this suite curates for it"
  echo "        file: $DOCS_ACCURACY_SELF (regions: $T18_CITE_TITLE, $T18_FLOOR_TITLE)"
  echo "        no longer cited:$T18_FRAG_UNCITED"
  echo "        a record that stops naming the code it describes is back to prose nobody can check — re-cite it, or retire the entry here in the SAME change"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.10b the T16 design record still cites each of the $T18_FRAG_CHECKED curated fragments"
  PASS=$((PASS + 1))
fi

# T18.10c — DERIVED, the T9.4c shape, and the half that survives forgetfulness:
# the table above is hand-maintained, so it can only ever certify the fragments
# somebody remembered to add. This row reads the record's OWN backticks, so a
# NEW quoted fragment that resolves nowhere reds without anyone extending a
# list.
#
# Two span classes are excluded, both by a rule rather than by name:
#   * a span the record marks as a PATTERN — it writes the word pattern in
#     front of every regex or placeholder example. Those are shapes the harvest
#     MATCHES, not code that exists, so they resolve nowhere by construction;
#     the marker lives in the record's own prose, so a new example inherits the
#     exclusion just by being written the same way. That is the `memory: `key``
#     technique T9.4c uses, not a per-token skip list.
#   * a row id or an issue ref, by SHAPE — a pointer to this suite's own rows or
#     to a GitHub issue is not a symbol in the script being described.
#
# Both the marker rule and the harvest read `$T18_SD_PROSE`, the unwrapped body
# built above, so neither depends on where a comment happens to wrap nor on how
# far its continuation is indented — inside the one boundary declared there.
T18_DERIVED_TOKENS="$(sed 's/pattern[[:space:]]*`[^`]*`//g' <<<"$T18_SD_PROSE" \
  | grep -oE '`[^`]+`' \
  | sed 's/^`//; s/`$//' \
  | grep -vE '^(T[0-9]+(\.[0-9]+)?|#[0-9]+)$' \
  | sort -u)"
T18_DERIVED_COUNT="$(grep -c . <<<"$T18_DERIVED_TOKENS" || true)"
T18_DERIVED_DEAD=""
while IFS= read -r t18_tok; do
  [ -n "$t18_tok" ] || continue
  grep -qF -e "$t18_tok" "$SOLVE_FLEET_JS" \
    || T18_DERIVED_DEAD="$T18_DERIVED_DEAD
        $t18_tok"
done <<EOF_T18_DERIVED
$T18_DERIVED_TOKENS
EOF_T18_DERIVED
if [ "${T18_DERIVED_COUNT:-0}" -lt 8 ] 2>/dev/null; then
  echo "  FAIL  T18.10c the backtick harvest yielded only ${T18_DERIVED_COUNT:-0} fragments (floor 8) — the record stopped quoting code, or the harvest broke"
  echo "        file: $DOCS_ACCURACY_SELF (regions: $T18_CITE_TITLE, $T18_FLOOR_TITLE)"
  FAIL=$((FAIL + 1))
elif [ -n "$T18_DERIVED_DEAD" ]; then
  echo "  FAIL  T18.10c the T16 design record quotes fragment(s) that resolve nowhere in the script it describes"
  echo "        file: $SOLVE_FLEET_JS"
  echo "        unresolved:"
  # BOUNDED on both axes. When a region loses its END marker the slice runs to
  # EOF and every swallowed line arrives here as a `fragment`, so an unbounded
  # dump buries T18.9's sentinel — the row that names the REAL fault — under
  # kilobytes of this file's own source. `awk` is used rather than `head`/`sed q`
  # so nothing exits early on a reader and poisons `pipefail` with EPIPE
  # (tests/epipe-guard.test.sh).
  printf '%s\n' "$T18_DERIVED_DEAD" \
    | awk 'NF { n += 1; if (n <= 12) print substr($0, 1, 120) }
           END { if (n > 12) printf "        … and %d more (see T18.9/T18.9a first: a runaway slice reports every swallowed line as a fragment)\n", n - 12 }'
  echo "        prose naming code that does not exist is a citation that changed shape without becoming resolvable; mark a regex or placeholder example by writing the word pattern before it"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  T18.10c all $T18_DERIVED_COUNT fragments harvested from the record's own backticks resolve in workflow.js"
  PASS=$((PASS + 1))
fi

# T18.11 — the retyped counts stay retired, under a DERIVED predicate. The
# previous edition of this row listed the figures the record had already been
# caught copying out of the script by hand, which is a criterion that can only
# ever look BACKWARDS: today's live count, retyped today, reads green through it
# — and today's live count is exactly what every one of those listed figures WAS
# on the day someone typed it. A row certifying "states mechanisms, not retyped
# counts" while the current retype sails past it is the same disjoint-predicate
# defect this whole task exists to retire, rebuilt inside the fix.
#
# What may legitimately carry a figure in the record, and nothing else:
#   * a row id (`T<n>` / `T<n>.<n>`) or an issue ref (`#<n>`), both stripped by
#     SHAPE before either arm looks;
#   * prose naming a MECHANISM, which needs no figure at all — T16.9 prints the
#     live sizes on every run, and that is the only copy that cannot go stale.
#
# TWO arms, because a count comes in two spellings and a digit predicate sees
# only the first. The numeral arm catches a figure typed in digits; the cardinal
# arm catches the same figure spelled as a word, which carries no digit at all
# and would otherwise walk straight through — and a spelled count is what the
# record was caught carrying, so dropping that arm would be dropping coverage
# this suite already had. The cardinal vocabulary is a CLOSED CLASS of English,
# not a list of figures observed to have rotted; that is what makes it look
# forwards rather than backwards — but a closed class only looks forwards if it
# is enumerated to its END. A vocabulary that stops after the units is a
# BACKWARD-LOOKING list wearing a closed class's name: it spans exactly the
# range whose members were caught rotting, and the first retype one step past
# the truncation walks straight through a row whose PASS text says it cannot.
# The class enumerated below is the English cardinal number words — the units,
# the teens, the tens and the magnitudes — plus the collective and
# multiplicative count words, which spell a quantity without being numerals.
# Every word of that class which is NOT enumerated is named as a boundary in the
# paragraph after: a word held out silently is the truncation this paragraph
# rejects, wearing a different hat.
#
# What must not appear in this comment is a figure copied out of the script or
# out of the record — a specimen here would be indistinguishable from a claim,
# and the next reader has no way to tell an example from a measurement. The
# cardinals this prose does spell name its own structure (two arms, two
# spellings), which is not a quantity anything can move past.
#
# DECLARED BOUNDARIES, not oversights. Each is held out because including it
# would cost more than the coverage it buys — and they are spelled out rather
# than counted, so adding one does not leave a stale tally behind:
#   * `one` is a pronoun and an article ("one of", "the one that"), so including
#     it would red honest prose on every other line. `once` and `single` spell
#     the same quantity as an adverb and an adjective, collide with ordinary
#     prose exactly the same way, and are held out with it.
#   * `zero` is how this suite names the VACUITY failure mode itself — an anchor
#     that has moved extracts zero names — which is a mechanism that cannot rot,
#     not a measurement copied out of the script.
#   * the `-illion` magnitudes above `trillion`, and the `-uple` multiplicatives
#     above `quadruple`, are regular open-ended series: they have no end to be
#     enumerated to. A record that reaches them is not drifting, it is broken.
# A count spelled as one of the words named above is what this row cannot see;
# every other member of the class it can.
#
# This row is NOT immune to a lost region marker, and no assembled-needle trick
# can make it so: its own numeral arm is spelled with digits. A slice that runs
# to EOF swallows this source and reds here as well as at T18.9 — a redundant
# red beside the sentinel that names the real fault, never a silent pass.
#
# Longest forms first. `-w` already stops a unit matching inside a teen, so the
# order is not what makes the row SEE the teen — it is what makes `-o` report
# the whole word rather than its prefix in the FAIL arm, and the offending text
# is the actionable half of the diagnostic.
T18_CARDINALS='thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen'
T18_CARDINALS="$T18_CARDINALS|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
T18_CARDINALS="$T18_CARDINALS|hundred|thousand|million|billion|trillion"
T18_CARDINALS="$T18_CARDINALS|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
T18_CARDINALS="$T18_CARDINALS|quadruple|couple|double|myriad|thrice|triple"
T18_CARDINALS="$T18_CARDINALS|dozen|gross|score|twice|pair"
T18_SD_NO_IDS="$(sed -e 's/T[0-9][0-9]*\.[0-9][0-9]*//g' -e 's/T[0-9][0-9]*//g' \
                     -e 's/#[0-9][0-9]*//g' <<<"$T18_SD")"
# `grep -o` is deliberate over `grep -n`: the line numbers would be relative to
# the concatenated slice, not to the file, so they would point at nothing a
# reader can open. The offending text is the actionable half.
T18_COUNT_HITS="$({ grep -oE '[0-9][0-9]*' <<<"$T18_SD_NO_IDS" || true
                    grep -owiE -e "$T18_CARDINALS" <<<"$T18_SD_NO_IDS" || true; } | sort -u)"
if [ -z "$T18_COUNT_HITS" ]; then
  echo "  PASS  T18.11 the T16 design record states mechanisms — no numeral outside a row id or issue ref, and no spelled cardinal"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T18.11 the T16 design record retypes a count the code can move past without telling it"
  echo "        file: $DOCS_ACCURACY_SELF (regions: $T18_CITE_TITLE, $T18_FLOOR_TITLE)"
  sed 's/^/        /' <<<"$T18_COUNT_HITS"
  echo "        name the mechanism instead; T16.9 already prints the live counts on both sides"
  FAIL=$((FAIL + 1))
fi

# === BEGIN T19 README tier vocabulary ===
# T19 — #619. README's user-facing triage table is the FIRST place a user reads
# the tier ladder, and until this row nothing in CI read it for tier names. The
# `large` rung was deleted from the classifier, every validator, the routing
# policy and the fixture corpus, and README still documented it — the rung, its
# eight rules verbatim, and `--full # force medium/large` — because every guard
# that moved with the collapse was keyed on code, and the doc surface had none.
# A user following it labels an issue `architectural` expecting a design
# pipeline, or sets `solve_tier_ceiling: large`, which `uberdev_read_enum`
# matches against a `trivial|small|medium` pipe-list, rejects as `invalid_enum`
# and silently replaces with the empty default — the ceiling never applies.
#
# DERIVED, not transcribed. Both rows read `TIERS` out of `lib/solve_triage.py`
# at run time and compare README against it, so they move with the ladder
# instead of pinning today's three names — a retyped list is exactly the thing
# that drifted. T19.2 is the general form: any `x/y` pair in README whose left
# half is a live tier must have a live tier on the right too, which reds on
# `medium/large` without ever naming `large`. Its false-positive shape (a live
# tier beside an ordinary word, e.g. a hypothetical "medium/high risk") was
# MEASURED rather than assumed: over all 187 historical revisions of README.md
# the only such pair ever written is `medium/large` itself, so the broad scan
# costs nothing and a whole-file sweep is what catches the drift on the four
# lines that carry no `tier` keyword to scope on.
if python3 - "$REPO_ROOT/README.md" "$REPO_ROOT/plugins/uberdev/lib/solve_triage.py" <<'PY_T19'
import importlib.util, pathlib, re, sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r\n", "\n")
spec = importlib.util.spec_from_file_location("st", sys.argv[2])
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
tiers = list(st.TIERS)

ok = True

# T19.1 -- the triage table's tier column IS the ladder, in order.
lines = readme.split("\n")
head = next((i for i, l in enumerate(lines) if l.startswith("| Tier |")), None)
if head is None:
    print("T19.1 README has no `| Tier |` triage table header"); ok = False
else:
    named = []
    for line in lines[head + 2:]:
        if not line.startswith("|"):
            break
        cell = line.split("|")[1]
        cell = re.sub(r"\*\(.*?\)\*", "", cell)     # drop the *(default …)* aside
        named.append(cell.replace("*", "").strip())
    if named != tiers:
        print("T19.1 README triage table names %r; lib/solve_triage.py TIERS is %r" % (named, tiers))
        ok = False

# T19.2 -- no slash-pair that promises a rung the ladder no longer has.
live = set(tiers)
bad = set()
for left, right in re.findall(r"\b([a-z]+)\s*/\s*([a-z]+)\b", readme):
    if left in live and right not in live:
        bad.add("%s/%s" % (left, right))
    if right in live and left not in live:
        bad.add("%s/%s" % (left, right))
if bad:
    print("T19.2 README pairs a live tier with a name the ladder does not have: %s"
          % ", ".join(sorted(bad)))
    ok = False

sys.exit(0 if ok else 1)
PY_T19
then
  echo "  PASS  T19 README's tier vocabulary is derived-equal to lib/solve_triage.py TIERS"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T19 README documents a tier ladder lib/solve_triage.py does not have"
  echo "        file: $REPO_ROOT/README.md"
  FAIL=$((FAIL + 1))
fi
# === END T19 README tier vocabulary ===

# === BEGIN T20 review-fanout cardinality and the /dev RFC's archived counts ===
# T20 — #606. Two counts drifted the moment the surfaces that state them moved
# and the prose that quotes them did not:
#
#   * The Phase 1 reviewer roster grew to SEVEN (the `convention` lens joined),
#     and SEVENTEEN sites across EIGHT live files still promised six —
#     `commands/review-pr.md` twice, `skills/dev-pipeline/SKILL.md`, both SDD
#     flow diagrams, `finish-branch/SKILL.md`, and — worst — the review-fleet
#     engine describing itself: its SKILL.md guard table, four comments in
#     `workflow.js` and five in `lib/review-fleet-args.sh`, plus the ledger check
#     in `lib/review-aggregate.sh`. Every one of them is what a reader sizes the
#     review budget, the nonce pool or the agent ceiling from.
#   * v0.50.0 collapsed the tier ladder to three rungs, and `docs/rfc/0003`'s
#     motivation section still argued from "four tiers (`trivial` → `large`)"
#     and "an unskippable 6-agent fanout", citing a line RANGE that now lands on
#     an `## Emphasis` example fence rather than on the roster.
#
# DERIVED on both halves. The roster size is COUNTED out of the
# `child-callsite-contracts-v1` block in `post-impl-review/SKILL.md` — the wire
# contract, the one surface that cannot be wrong about how many children are
# dispatched — and the ladder is read out of `lib/solve_triage.py` exactly as
# T19 reads it. Nothing below retypes either figure.
#
# The two halves are treated DIFFERENTLY on purpose. Live prose is corrected in
# place; an RFC is an archival record of what was true when it was written, so
# T20.4/T20.5 require a DATED superseded-in-part note (the form RFC 0013 §0A
# already uses) instead of a rewritten §2.1 — and require the note to carry the
# symbol anchor that replaced the rotted `SKILL.md:89-101` offset, because a
# re-anchor is the only half of the correction that stops the citation rotting
# again on the next edit above it.
if python3 - "$PLUGIN_DIR" "$RFC_DIR/0003-dev-command.md" "$PLUGIN_DIR/lib/solve_triage.py" <<'PY_T20'
import importlib.util, json, pathlib, re, sys

plugin_dir = pathlib.Path(sys.argv[1])
rfc = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").replace("\r\n", "\n")
spec = importlib.util.spec_from_file_location("st_t20", sys.argv[3])
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
tiers = list(st.TIERS)

roster_md = plugin_dir / "skills" / "post-impl-review" / "SKILL.md"
roster_text = roster_md.read_text(encoding="utf-8").replace("\r\n", "\n")
# #747 — the post-impl-review body was cut toward Anthropic's 500-line ceiling
# and its roster table, fanout-cap precedence and failure boundary moved into
# reference files the body points at. A quotation credited to a reference file is
# therefore checked against THAT reference file; checking the body alone would
# report a correctly-cited sentence as a fabrication.
#
# The files are kept SEPARATE, keyed by the pathname a shipped source would cite
# them with. Concatenating the skill directory into one haystack would trade away
# both halves of this row's precision: a sentence credited to `SKILL.md` would be
# satisfied by text that exists only in a reference file (the row would stop
# checking WHICH file the citation names, which is the whole job), and — because
# the join collapses to a single space under the normalisation below — a needle
# spanning one file's tail and the next one's head would match a string that
# appears in neither.
ROSTER_FILES = {"post-impl-review/SKILL.md": roster_text}
for ref in sorted((roster_md.parent / "references").glob("*.md")):
    ROSTER_FILES["post-impl-review/references/" + ref.name] = (
        ref.read_text(encoding="utf-8").replace("\r\n", "\n"))
# Normalised once, per file, in the same shape the quotations are flattened into.
ROSTER_FLAT = {name: re.sub(r"\s+", " ", body).casefold()
               for name, body in ROSTER_FILES.items()}
# A credit is a PATHNAME, and it is resolved to the file it names. Bare
# `post-impl-review` is not enough: the artifact filename `post-impl-review-final.md`
# occurs inside quoted prompt text and is not a citation of the skill. A bare
# `references/` with no filename names the directory, so it resolves to every file
# in that directory — each still searched on its own, never joined.
ROSTER_CITE = re.compile(
    r"post-impl-review/(?:SKILL\.md|references/(?:[A-Za-z0-9._-]+\.md)?)")
ok = True

# T20.1 — anti-vacuity for the roster. A renamed marker or a reshaped block
# yields zero reviewer edges, and every comparison below would then be measured
# against a number nothing produced.
block = re.search(r"<!-- BEGIN child-callsite-contracts-v1 -->\n```json\n(.*?)\n```",
                  roster_text, re.DOTALL)
roster = 0
if block is None:
    print("T20.1 post-impl-review/SKILL.md has no child-callsite-contracts-v1 json block"); ok = False
else:
    try:
        edges = json.loads(block.group(1))
    except ValueError as error:
        print("T20.1 the post-impl-review callsite block is not valid JSON: %s" % error); ok = False
        edges = {}
    roster = len([e for e in edges if e.startswith("review_pr.review.")])
    if roster < 5:
        print("T20.1 only %d review_pr.review.* edge(s) in the callsite block — too few to be the roster" % roster)
        ok = False

# T20.2 — anti-vacuity for the scan. TWO tiers, because a detector keyed on
# proximity alone is blind in exactly the files that get this wrong: a file whose
# whole subject is the fanout stops re-naming it, so `review-fleet/workflow.js`
# could say "closed six-edge roster" three lines under a REVIEW_ROSTER of seven
# and no paragraph-proximity scan would ever reach it.
#
#   PROXIMITY tier — every `*.md` under the plugin. A cardinality token must sit
#   within a bounded window of a fanout NAME in the same paragraph, so a reflow
#   cannot hide a claim and a distant unrelated count cannot invent one. This
#   tier alone may read the GENERIC noun `agents`, which means nothing on its own.
#
#   OWNER tier — every file, any extension, that names a `review_pr.review.*`
#   edge. The set is DERIVED by grep, never listed: a file that names the edges
#   is a file describing this roster, and adding a new one opts it in for free.
#   No proximity is required there, so the nouns are narrowed to the ones that
#   are self-anchoring (`reviewer*`, `edge roster`) — never bare `agents`, which
#   is why "The one agent-returned string" is not read as a roster claim.
#
# Number-WORDS count as much as digits. TEN of the seventeen stale sites spelled
# it out — "six children", "six-edge roster", "Six reviewers" — and the row's
# first shape, `(\d+)[- ]agents?`, could see FOUR of them: a digit-only detector
# reading one noun IS the hand-picked census this row exists to stop being. A
# numeral is skipped when a preceding `Phase`/`Step`/`Wave`/`#` makes it an
# ordinal rather than a count, or when an arrow makes it the left side of an
# `N -> M` historical transition (the `5 → 6 reviewers` record of #73 is TRUE
# about #73 and must stay).
#
# A zero harvest means the detector stopped detecting, not that the docs are
# clean, so the floor below is set well under the live count.
NAME = r"(?:post-impl-review|/review-pr|review-pr|review-fleet|REVIEW_ROSTER)"
WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
         "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}
NUM = r"(?:\d+|" + "|".join(sorted(WORDS)) + r")"
ROSTER_NOUN = r"(?:reviewers?|reviewer[- ](?:subagents?|agents?|slots?|lenses)|(?:edge|reviewer) roster)"
ANY_NOUN = r"(?:" + ROSTER_NOUN + r"|agents?)"
def count_re(noun):
    return r"(?<![\w-])(" + NUM + r")[- ]" + noun + r"\b"
NOT_A_COUNT = re.compile(r"(?:[Pp]hase|[Ss]tage|[Ss]tep|[Ww]ave|[Oo]ption|[Ii]teration|#|->|→)\s*$")
WINDOW = 240
forward = re.compile(NAME + r".{0,%d}?" % WINDOW + count_re(ANY_NOUN), re.DOTALL | re.IGNORECASE)
backward = re.compile(count_re(ANY_NOUN) + r".{0,%d}?" % WINDOW + NAME, re.DOTALL | re.IGNORECASE)
owner_only = re.compile(count_re(ROSTER_NOUN), re.IGNORECASE)
scanned = sorted(p for p in plugin_dir.rglob("*")
                 if p.is_file() and p.suffix in (".md", ".js", ".sh"))
# ONE read per file, reused by all three passes below (the owner derivation
# here, the paragraph scan, and T20.6). Nothing between them mutates the tree, so
# re-reading and re-decoding 161 files two to three times per CI run bought
# nothing; every read used these exact arguments, so the cache is the same text.
texts = {p: p.read_text(encoding="utf-8", errors="replace") for p in scanned}
owners = set(p for p in scanned if "review_pr.review." in texts[p])
claims = []
for path in scanned:
    patterns = ([forward, backward] if path.suffix == ".md" else [])
    if path in owners:
        patterns = patterns + [owner_only]
    if not patterns:
        continue
    lines = texts[path].replace("\r\n", "\n").splitlines()
    start = 0
    for idx in range(len(lines) + 1):
        if idx == len(lines) or not lines[idx].strip():
            para = " ".join(lines[start:idx])
            offsets = set()
            for pattern in patterns:
                for hit in pattern.finditer(para):
                    if hit.start(1) in offsets or NOT_A_COUNT.search(para[:hit.start(1)]):
                        continue
                    offsets.add(hit.start(1))
                    token = hit.group(1).lower()
                    stated = WORDS[token] if token in WORDS else int(token)
                    claims.append((path.relative_to(plugin_dir).as_posix(), start + 1, stated))
            start = idx + 1
if len(claims) < 20:
    print("T20.2 the fanout-cardinality detector found %d claim(s) in %s — it has stopped detecting"
          % (len(claims), plugin_dir))
    ok = False
if not any(path.endswith(".js") or path.endswith(".sh") for path, _, _ in claims):
    print("T20.2 the owner tier harvested nothing outside *.md — the derived owner set has gone empty")
    ok = False

# T20.3 — forward. Every live prose surface that sizes the fanout sizes it the
# way the wire contract does.
wrong = ["%s:%d says %d" % row for row in claims if roster and row[2] != roster]
if wrong:
    print("T20.3 live prose sizes the Phase 1 reviewer fanout wrongly (the callsite block dispatches %d): %s"
          % (roster, "; ".join(wrong)))
    ok = False

# T20.4 — the RFC keeps its record AND carries a dated correction. `Draft` in
# the Status field is part of the record; the amendment marker is what tells a
# reader the motivation below it argues from figures that have since moved.
if not re.search(r"SUPERSEDED IN PART \(2026-08-19\)", rfc):
    print("T20.4 docs/rfc/0003-dev-command.md carries no dated superseded-in-part note for its §2.1 counts")
    ok = False

# T20.5 — and the note states BOTH corrected figures, derived, plus the symbol
# that replaced the rotted line-range citation. The heading is read out of the
# roster file, so growing the roster reds this row rather than silently
# re-rotting the anchor.
heading = re.search(r"^### Step 2: Dispatch (\d+) required routed reviewers$",
                    roster_text, re.MULTILINE)
if heading is None:
    print("T20.5 post-impl-review/SKILL.md has no '### Step 2: Dispatch N required routed reviewers' heading to anchor on")
    ok = False
elif roster and int(heading.group(1)) != roster:
    print("T20.5 the roster heading says %s reviewers; the callsite block dispatches %d"
          % (heading.group(1), roster))
    ok = False
else:
    needles = [
        heading.group(0).lstrip("# "),
        "`%s` → `%s`" % (tiers[0], tiers[-1]),
        "%d" % roster,
    ]
    absent = [n for n in needles if n not in rfc]
    if absent:
        print("T20.5 the RFC 0003 correction note omits: %s" % "; ".join(repr(n) for n in absent))
        ok = False
    if re.search(r"post-impl-review/SKILL\.md:\d", rfc):
        print("T20.5 docs/rfc/0003-dev-command.md still cites post-impl-review/SKILL.md by line offset")
        ok = False

# T20.6 — a RETYPED quotation rots the same way a retyped count does, and it
# rots invisibly: `review-fleet/workflow.js` quoted "all six reviewer slots" and
# attributed it to `post-impl-review/SKILL.md`, which says seven. The shipped
# tree misquoted its own cited source, and a cardinality scan cannot catch that
# because the number is inside quotation marks that claim someone else wrote it.
# So every span this engine quotes AND attributes to that file must still be in
# it. Comment wrapping is normalised away first (`//` and `#` continuations),
# because the quotation that was wrong spanned two comment lines and no
# line-oriented grep could have matched it whole. Case is folded: these are
# mid-sentence quotations, so a leading capital is the quoter's, not a
# divergence. Only the DERIVED owner set is read, and only its source files —
# markdown carries `#` as syntax, which this normalisation would eat.
#
# The needle is looked for in the file the citation NAMES, one file at a time.
# That is the row's whole job: a citation of file X is evidence about X, so a
# quote credited to `SKILL.md` for a sentence that has moved into a reference
# file is a real drift in the CITING file and reds here. Searching one file at a
# time is also what keeps a needle from matching across a file boundary.
attributed = 0
for path in sorted(p for p in owners if p.suffix in (".js", ".sh")):
    flat = re.sub(r"\s+", " ",
                  re.sub(r"\n\s*(?://+|#+)\s*", " ",
                         texts[path].replace("\r\n", "\n")))
    for quoted in re.finditer(r"[\"“]([^\"“”]{20,300})[\"”]", flat):
        tail = flat[quoted.end():quoted.end() + 160]
        cited = ROSTER_CITE.findall(tail)
        if not cited:
            continue
        attributed += 1
        where = path.relative_to(plugin_dir).as_posix()
        named, unknown = {}, []
        for cite in cited:
            # A directory citation names its whole contents; a file citation
            # names exactly one file. Either way each candidate stays separate.
            hits = {name: body for name, body in ROSTER_FLAT.items()
                    if (name.startswith(cite) if cite.endswith("/") else name == cite)}
            if hits:
                named.update(hits)
            else:
                unknown.append(cite)
        if unknown:
            print("T20.6 %s quotes %r and credits %s, which is not a file in the post-impl-review skill"
                  % (where, quoted.group(1), ", ".join(sorted(set(unknown)))))
            ok = False
        needle = re.sub(r"\s+", " ", quoted.group(1)).strip().casefold()
        if named and not any(needle in body for body in named.values()):
            print("T20.6 %s quotes %r and credits %s, which does not contain it"
                  % (where, quoted.group(1), ", ".join(sorted(named))))
            ok = False
if attributed < 2:
    print("T20.6 found %d attributed quotation(s) in the review-fleet sources — it has stopped detecting"
          % attributed)
    ok = False

sys.exit(0 if ok else 1)
PY_T20
then
  echo "  PASS  T20 the Phase 1 fanout size is derived-equal across live prose, and RFC 0003's archived counts carry a dated correction"
  PASS=$((PASS + 1))
else
  echo "  FAIL  T20 a review-fanout cardinality or the /dev RFC's archived counts disagree with the shipped tree"
  echo "        files: $PLUGIN_DIR/**/*.md, $RFC_DIR/0003-dev-command.md"
  FAIL=$((FAIL + 1))
fi
# === END T20 review-fanout cardinality and the /dev RFC's archived counts ===

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
