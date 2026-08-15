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
# #472 version-bump-contract surfaces. AGENTS.md is the rule document the
# convention lens quotes verbatim AND the only one a worktree solver can read
# (the project CLAUDE.md twin is gitignored — .gitignore). The other three are
# the machinery that decides which commit actually carries the bump, so T12
# below locks the doc and the machinery against EACH OTHER rather than pinning
# either alone.
AGENTS_MD="$REPO_ROOT/AGENTS.md"
SOLVE_FLEET_JS="$PLUGIN_DIR/skills/solve-fleet/workflow.js"
# #507 design-chain surfaces. The fleet script is the machinery; its SKILL.md
# and RFC 0015 both restate the chain AND the CB1 projection as prose, so T14
# below locks the three against each other rather than pinning any one alone.
SOLVE_FLEET_SKILL="$PLUGIN_DIR/skills/solve-fleet/SKILL.md"
DISPATCH15_RFC="$RFC_DIR/0015-workflow-native-dispatch.md"
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

# This file, read as data: row T6.5b slices its own size-ratchet region to keep
# the measurement platform-invariant (#522).
DOCS_ACCURACY_SELF="$REPO_ROOT/tests/docs-accuracy.test.sh"

# Hard-fail (exit 2) on a missing input — a moved/renamed file must be an
# explicit failure, never silently-zero-assertions PASS.
for f in "$TESTING_MD" "$CONTRIBUTING_MD" "$DISPATCH_RFC" "$ALIAS_RFC" \
         "$SESSION_START" "$ALIASES_SYNC" "$TEST_YML" \
         "$USING_SKILL" "$CONFIG_REF" "$HOOKS_JSON" "$HOOKS_CURSOR_JSON" \
         "$PRE_COMPACT" "$WORKFLOW_RFC" "$GOAL_RFC" "$VENDOR_RFC" \
         "$PRECISION_RFC" "$PRECISION_MINER" "$AGENTS_MD" "$SOLVE_FLEET_JS" \
         "$SOLVE_FLEET_SKILL" "$DISPATCH15_RFC" \
         "$GOAL_WATCH_SH" "$BUMP_VERSION_SH" "$STRUCTURAL_LIB" \
         "$ADAPTIVE_RFC" "$RUN_MANIFEST_PY" "$DOCS_ACCURACY_SELF"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

# Shared structural-assertion helpers (assert_in_section + assert_count for T12
# — the version rule is sliced to its own section so a stray prose match
# elsewhere in AGENTS.md cannot false-positive it; see the T12 block for what
# that scoping does and does NOT buy while AGENTS.md carries a single level-2
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
# THE DRIFT THIS LOCKS. AGENTS.md's version section said, unqualified, that
# every user-facing merge must bump the version "in the same PR". The shipped
# machinery says the opposite for one whole lane: skills/solve-fleet/workflow.js
# FORBIDS every fleet solver from bumping, because N solvers cut off one base
# all resolve the SAME next version and that duplicate edit auto-merges without
# a conflict, silently losing a release. So the rule document convicted the
# fleet PRs that the tooling had just told to stay unbumped — and the review
# convention lens, which cites AGENTS.md verbatim, filed that contradiction as a
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
# STATED PLAINLY, because the scoping is weaker than it looks: AGENTS.md carries
# exactly ONE level-2 heading today, so this range still runs to end-of-file and
# the anchoring buys nothing until a sibling section is added — it is insurance,
# not a property of the file as it stands. The start anchor is the invariant
# sentence T12.2a/T12.2b already pin; reword it and all eleven in-section
# assertions go red together, loudly, rather than passing over an empty slice.
AGENTS_SECTION_START='^\*\*Every user-facing change'
AGENTS_SECTION_END='^## '

# --- the rule half: what AGENTS.md must say -------------------------------
assert_grep "$AGENTS_MD" '^## Bump version EVERYWHERE before merge \(MANDATORY\)$' \
  "T12.1 AGENTS.md still carries the version-bump section heading"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  'landing commit' \
  "T12.2a the invariant is scoped to the LANDING commit, not to every PR"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '(project )?version advanced|advance the (project )?version' \
  "T12.2b the invariant is that the version ADVANCED on main"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '`/goal`' \
  "T12.3a the /goal lane is named"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '`/solve`.*`/turbo`.*fleet' \
  "T12.3b the /solve + /turbo fleet lane is named"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '[Hh]and-authored' \
  "T12.3c the hand-authored lane is named"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  'fleet PR whose diff carries no version surface is compliant' \
  "T12.4 the fleet carve-out is explicit — an unbumped fleet PR is COMPLIANT"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  'skills/solve-fleet/workflow\.js' \
  "T12.4b the carve-out names the file that forbids the solver from bumping"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  'plugins/uberdev/lib/bump-version\.sh' \
  "T12.5 the bump mechanism is named by path"
# Anchored to the numbered-list-item FORM, not a bare path substring: both test
# paths also appear in the local-verification bullet further down the section,
# so a substring match kept passing after the two surface entries themselves
# were deleted — a label ("listed as a surface") wider than its predicate.
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '^[0-9]+\. \*\*`tests/goal\.test\.sh`\*\*' \
  "T12.5b the CI release-ratchet lock tests/goal.test.sh is still a numbered surface-list entry"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
  '^[0-9]+\. \*\*`tests/solve-claim\.test\.sh`\*\*' \
  "T12.5c the CI release-ratchet lock tests/solve-claim.test.sh is still a numbered surface-list entry"
assert_in_section "$AGENTS_MD" "$AGENTS_SECTION_START" "$AGENTS_SECTION_END" \
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
assert_absent_fixed "$AGENTS_MD" 'MUST bump the version in every location below' \
  "T12.9 the unqualified every-PR mandate (the sentence #472 was filed against) is gone"
assert_absent_fixed "$AGENTS_MD" 'single-escaped' \
  "T12.10a the stale single-escaped regex-form description is gone (post-#231 the locks are one assert_version_bump arg)"
assert_absent_fixed "$AGENTS_MD" 'double-escaped' \
  "T12.10b the stale double-escaped regex-form description is gone"
assert_absent_fixed "$AGENTS_MD" 'Update all seven locations above' \
  "T12.10c the 'seven locations in one commit' claim is gone (only six are files)"
assert_absent_fixed "$AGENTS_MD" "Codex's auto-update" \
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

assert_grep "$BUMP_VERSION_SH" 'AGENTS\.md' \
  "T12.12 bump-version.sh's checklist comment names AGENTS.md as the documented ritual"
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
# Anchored to the medium/large TIER ROW, not to the file: each doc describes the
# chain in exactly one line, and a file-wide needle would let the claim drift
# into a footnote while the row a reader actually consults stayed stale.
assert_grep "$SOLVE_FLEET_SKILL" '^\| .medium., .large.*spec-r1\.md' \
  "T14.7 SKILL.md chain row names the versioned artifact the bounded revision round writes"
assert_grep "$DISPATCH15_RFC" '^\| .medium., .large.*spec-r1\.md' \
  "T14.8 RFC 0015 chain row names the same versioned revision artifact"

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
# Script side. `//` comments are stripped BEFORE the newlines collapse — the
# taskRec literal carries four comment lines, and prose ending in a colon
# ("… as the PR-claim pass below:") otherwise reads as a key. Collapsing to one
# line is what lets one ERE span an authored wrap; `[^{}]*` keeps each match
# inside a single brace-free literal, and these records nest nothing. Braces are
# spelled `[{]`/`[}]` and never `\{`/`\}`: an escaped brace in an ERE is
# undefined by POSIX and GNU grep 3.8+ warns on stray escapes, so the bracket
# expression is the form that means the same thing to every grep CI resolves.
sf_js_keys() {       # <ERE matching the whole object literal>
  sed 's|//.*||' "$SOLVE_FLEET_JS" | tr -d '\r' | tr '\n' ' ' \
    | grep -oE "$1" | grep -oE '[A-Za-z_][A-Za-z0-9_]*:' | tr -d ':' | sort -u
}
# Count and set-difference, factored: six of each below, and six copies of the
# same loop is the very class this section exists to police. Herestrings, not
# pipes — this file sets `-o pipefail` and is inside epipe-guard.test.sh's scan
# set, where a `printf | grep -q` writer takes EPIPE and poisons the rc.
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

# T16.9 — the completeness flag has no members to join, so it gets the symbol
# pair instead: named in the doc, and resolving in the script it describes.
assert_grep "$SOLVE_FLEET_SKILL" 'chainComplete' \
  "T16.9 SKILL.md's return value declares the chainComplete flag"
assert_grep "$SOLVE_FLEET_JS" 'chainComplete' \
  "T16.9b the chainComplete symbol resolves in the fleet script"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]
