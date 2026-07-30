#!/usr/bin/env bash
# Tests for the R1+R2 root fix to /merge's discovery logic (issue/PR for v0.19.3).
#
# The bug class being guarded against: `gh pr list ... 2>&1 | jq ...` and
# `gh pr view ... | jq ...` shapes inside the merge skill body. Two failure
# modes flow from those shapes:
#   R1 — spinner / progress indicators leak from gh's stderr into the jq
#        pipeline and crash the parse, masquerading as "no PRs found"
#        (the original 21ad417 fix in solve-pipeline; the merge skill had
#        the same bug pattern in three sites).
#   R2 — when gh itself fails (network, auth, malformed response), `2>&1`
#        merges its diagnostics with the JSON output and the inline jq
#        either crashes or silently swallows an empty result; the run can
#        then proceed past a failure that should have aborted with audit.
#
# The fix introduces a new bash library at
#   plugins/uberdev/skills/merge-pipeline/lib/discover.sh
# exposing four functions that move filtering into gh's `--jq '<filter>'`
# (in-process) and capture stderr separately via mktemp so the gh exit code
# can be inspected and propagated to a structured audit event:
#   discover_bare_fast_path   (Step 1.0.5)
#   discover_multi            (Step 1.2.5)
#   pr_view_projection        (Step 1.4)
#   discover_review_verdict_json (typed audit-artifact discovery)
#   parse_review_verdict_phase2_5 (atomic phase2_5 validation + extraction)
#   emit_gate_fail            (gate-fail audit-emit helper)
#
# This test file has two layers:
#   Layer A — file-content greps that lock the implementation shape so a
#             future regression can't reintroduce the bug (no live gh).
#   Layer B — functional tests that source the library and exercise it
#             against the fake-gh fixture in tests/_fixtures/fake-gh.
#
# Layer B sources lib/discover.sh from REPO_ROOT. In the test author's
# isolated worktree the file does not exist yet — Layer B will FAIL until
# the implementation worktree is merged in. That is the expected and
# intended state during parallel development.
#
# Bash 3.2 compatible. No associative arrays.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/lib/discover.sh"
SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
# #304 / RFC 0012 §3.4: the A10 canary (mktemp stderr capture in the Step 4
# validation fetch) lives in lib/solve-launcher.sh, hoisted out of
# solve-pipeline/SKILL.md.
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"
PLUGIN_JSON="$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
README="$REPO_ROOT/README.md"
FAKE_GH_DIR="$REPO_ROOT/tests/_fixtures/fake-gh"

# Pre-flight: refuse to run if any input file is missing. This test file
# focuses on lib/discover.sh and the merge SKILL.md; if those are absent
# (e.g. before the implementation agent merges in their work) we still
# want clear failures rather than confusing "pattern not found" errors.
# We only HARD-FAIL on files that should always exist; lib/discover.sh
# may be absent in the test author's worktree and will surface as
# specific Layer A failures instead.
for f in "$SKILL" "$SOLVE_PIPELINE" "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$README"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

if [ ! -x "$FAKE_GH_DIR/gh" ]; then
  echo "FATAL: fake-gh fixture not executable: $FAKE_GH_DIR/gh" >&2
  exit 2
fi

PASS=0
FAIL=0

# --- Helpers ----------------------------------------------------------------

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file" 2>/dev/null; then
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern (must NOT appear): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_count_at_least() {
  local file="$1" pattern="$2" min="$3" desc="$4"
  local count
  # `grep -cE` always prints an integer (even 0), but exits 1 when count=0
  # and 2 on real errors (unreadable file, bad regex). `|| true` handles
  # the count=0 path; we still want to surface zero counts as failures via
  # the comparison below rather than silently skipping the assertion.
  count=$(grep -cE -e "$pattern" "$file" 2>/dev/null || true)
  # If count is empty (file unreadable, etc.), default to 0 so the
  # comparison below fails loud.
  count="${count:-0}"
  if [ "$count" -ge "$min" ] 2>/dev/null; then
    echo "  PASS  $desc (count=$count, min=$min)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:     $file"
    echo "        pattern:  $pattern"
    echo "        expected: count >= $min"
    echo "        actual:   $count"
    FAIL=$((FAIL + 1))
  fi
}

assert_count_eq() {
  local file="$1" pattern="$2" expected="$3" desc="$4"
  local count
  count=$(grep -cE -e "$pattern" "$file" 2>/dev/null || true)
  count="${count:-0}"
  if [ "$count" = "$expected" ]; then
    echo "  PASS  $desc (count=$count)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:     $file"
    echo "        pattern:  $pattern"
    echo "        expected: count == $expected"
    echo "        actual:   $count"
    FAIL=$((FAIL + 1))
  fi
}

# Layer-B helpers — wrap a function call against the fake-gh fixture in a
# clean PATH/env subshell. Captures stdout, stderr, exit; exposes via
# globals _LB_STDOUT / _LB_STDERR / _LB_EXIT for the caller to assert on.
_run_lib_call() {
  local mode="$1" call="$2" extra_env="${3:-}"
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  # shellcheck disable=SC2030,SC2031
  (
    PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_MODE="$mode"
    if [ -n "$extra_env" ]; then
      eval "$extra_env"
    fi
    # shellcheck source=/dev/null
    if [ ! -r "$LIB" ]; then
      echo "lib/discover.sh missing — Layer B cannot source it" >&2
      exit 127
    fi
    . "$LIB"
    eval "$call"
  ) >"$out" 2>"$err"
  rc=$?
  _LB_STDOUT="$(cat "$out")"
  _LB_STDERR="$(cat "$err")"
  _LB_EXIT="$rc"
  rm -f "$out" "$err"
}

# --- Layer A — Source-discipline assertions --------------------------------

echo "== A1: lib/discover.sh exists and is non-empty =="
if [ -s "$LIB" ]; then
  echo "  PASS  lib/discover.sh exists and is non-empty"
  PASS=$((PASS + 1))
else
  echo "  FAIL  lib/discover.sh missing or empty: $LIB"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A2: lib/discover.sh defines all four functions =="
# Match either `funcname() {` (with optional whitespace) or `function funcname`.
# We accept both POSIX-style and bash `function` keyword styles.
for fn in discover_bare_fast_path discover_multi pr_view_projection emit_gate_fail; do
  assert_grep "$LIB" \
    "^${fn}[[:space:]]*\([[:space:]]*\)[[:space:]]*\{|^function[[:space:]]+${fn}([[:space:]]|\(|\{|$)" \
    "A2: function ${fn} defined"
done

echo
echo "== A3: lib/discover.sh uses --jq '<filter>' at >= 3 sites (real call sites only, no comments) =="
# `gh ... --jq '<filter>'` is the canonical in-process filter shape. Real
# implementation uses multi-line `gh \\` continuation so we fold continuations
# AND strip comments before counting — closes the prose-only false-pass risk
# flagged in code review (S5).
LIB_NORMALISED="$(grep -v '^[[:space:]]*#' "$LIB" | awk 'BEGIN{RS=""} {gsub(/\\\n[[:space:]]*/," "); print}')"
JQ_HITS=$(printf '%s\n' "$LIB_NORMALISED" | grep -cE "[-][-]jq '" || echo 0)
JQ_HITS="${JQ_HITS//[^0-9]/}"
if [ "$JQ_HITS" -ge 3 ]; then
  echo "  PASS  A3: --jq '<filter>' appears in >= 3 real call sites (found $JQ_HITS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A3: --jq '<filter>' appears only $JQ_HITS times (expected >= 3, one per discovery fn)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A4: lib/discover.sh does NOT contain bug shapes (continuations folded, comments stripped) =="
# We pre-process to (a) strip comment-only lines (file docs what it avoids)
# and (b) fold backslash-continuations into single logical lines (real impl
# splits gh calls across 7+ lines). This catches bug-shapes that span
# continuations — the false-negative class flagged in code review (S4).
COUNT=$(printf '%s\n' "$LIB_NORMALISED" | grep -cE "gh[[:space:]]([^|]*[[:space:]])?2>&1" || echo 0)
COUNT="${COUNT//[^0-9]/}"
if [ "$COUNT" -eq 0 ]; then
  echo "  PASS  A4a: no 'gh ... 2>&1' (stderr-merged) shape — closes R1 spinner-leak class"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A4a: found $COUNT 'gh ... 2>&1' bug-shape occurrence(s)"
  FAIL=$((FAIL + 1))
fi
COUNT=$(printf '%s\n' "$LIB_NORMALISED" | grep -cE "gh[[:space:]]([^|]*[[:space:]])?\| *jq([^.A-Za-z]|$)" || echo 0)
COUNT="${COUNT//[^0-9]/}"
if [ "$COUNT" -eq 0 ]; then
  echo "  PASS  A4b: no 'gh ... | jq …' (piped-jq) shape — closes R2 retired pattern"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A4b: found $COUNT 'gh ... | jq' bug-shape occurrence(s)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A4c: SKILL.md sources lib via \${CLAUDE_PLUGIN_ROOT} (not BASH_SOURCE) — closes B1 blocker =="
# B1 (code-review blocker): SKILL.md bash blocks run in Claude's eval context
# where BASH_SOURCE is empty and \$0 is /bin/bash. The canonical path resolution
# is \${CLAUDE_PLUGIN_ROOT} which Claude Code injects at skill-evaluation time.
# This regression-locks the fix.
assert_no_grep "$SKILL" 'BASH_SOURCE\[0\]:-\$0' \
  "A4c: SKILL.md does NOT use BASH_SOURCE/\$0 (broken in Claude eval context)"
assert_count_at_least "$SKILL" 'CLAUDE_PLUGIN_ROOT.*skills/merge-pipeline/lib/discover\.sh' 3 \
  "A4d: SKILL.md sources lib via \${CLAUDE_PLUGIN_ROOT} at all 3 hot spots"

echo
echo "== A5: lib/discover.sh uses mktemp + trap RETURN cleanup =="
assert_grep "$LIB" 'mktemp' \
  "A5a: mktemp present (stderr capture file)"
assert_grep "$LIB" 'trap[[:space:]]+.*RETURN' \
  "A5b: trap ... RETURN present (function-scoped cleanup)"

echo
echo "== A6: lib/discover.sh uses configurable audit-log path =="
# Exact env-var fallback shape; locks the contract end-to-end so tests
# that override UBERDEV_AUDIT_LOG_PATH actually take effect.
assert_grep "$LIB" 'UBERDEV_AUDIT_LOG_PATH:-\.uberdev/audit\.jsonl' \
  "A6: \${UBERDEV_AUDIT_LOG_PATH:-.uberdev/audit.jsonl} fallback present"

echo
echo "== A7: SKILL.md sources lib/discover.sh from each call site =="
# One source line per discovery step (1.0.5, 1.2.5, 1.4). The skill must
# `source ... lib/discover.sh` (or `. lib/discover.sh`) at >= 3 places.
# NOTE: pre-v0.21.5 we used `[^\n]*` here, which BSD/GNU grep treats as the
# char class `[^\, n]` — so any `n` between `.` and `lib/discover.sh` (such
# as the `n` in `merge-pipeline`) silently broke the match. The post-v0.21.5
# fix used `.*` for reach, but that matched prose lines in addition to the
# real `source`/dot statements (count climbed from 3 → 6 and the regression
# guard's intent was structurally weakened). Anchoring on `^[[:space:]]*`
# plus the literal `.` or `source` keyword restores the intent: matches the
# 3 real source statements at lines 143/246/284 exactly.
assert_count_at_least "$SKILL" '^[[:space:]]*(\.|source)[[:space:]].*lib/discover\.sh' 3 \
  "A7: SKILL.md sources lib/discover.sh in >= 3 places"

echo
echo "== A8: SKILL.md no longer contains raw bug shapes =="
assert_no_grep "$SKILL" 'gh pr list[^|]*\| *jq' \
  "A8a: SKILL.md no inline 'gh pr list ... | jq ...' (R2 retired shape)"
assert_no_grep "$SKILL" 'gh pr view[^|]*\| *jq' \
  "A8b: SKILL.md no inline 'gh pr view ... | jq ...' (R2 retired shape)"

echo
echo "== A9: SKILL.md ## Constants block declares new audit/gate-fail names =="
# Both names must appear *somewhere* in the file (the constants block lists
# enum members inline). We anchor on the literal token; the implementing
# agent writes them into the AUDIT_EVENT_ENUM and GATE_FAIL_REASON_ENUM rows.
assert_grep "$SKILL" 'discovery_gh_failed' \
  "A9a: SKILL.md mentions new audit event 'discovery_gh_failed'"
assert_grep "$SKILL" 'pr_view_unreachable' \
  "A9b: SKILL.md mentions new gate_fail reason 'pr_view_unreachable'"

echo
echo "== A10: solve-pipeline canary preserved (21ad417 fix intact) =="
# This is the original mktemp-stderr-capture pattern; the merge fix is the
# same pattern applied to a different skill. If this assertion fails, the
# upstream fix has been undone and the new merge fix is also at risk.
assert_grep "$SOLVE_PIPELINE" 'GH_ERR=\$\(mktemp\)' \
  "A10: solve-pipeline Step 4 still has GH_ERR=\$(mktemp) (21ad417 fix intact)"

echo
echo "== A11: version pinned identically across plugin.json, marketplace.json, README.md =="
# Read the canonical version from plugin.json (single source of truth) and
# assert the other two file-based locations match. Previously hard-coded to
# "0.19.3", which broke on every release bump (the 0.20.0 chore-release
# commit forgot to also update this test, leaving 3 stale-pin failures
# in main between 0.20.0 and 0.20.2). Reading dynamically keeps the
# cross-file drift assertion honest without per-bump maintenance.
A11_VERSION="$(grep -E '^[[:space:]]*"version":' "$PLUGIN_JSON" | head -1 | sed -E 's/.*"version":[[:space:]]*"([^"]+)".*/\1/')"
if [[ -z "$A11_VERSION" ]]; then
  echo "  FAIL  A11 setup: could not extract canonical version from $PLUGIN_JSON"
  FAIL=$((FAIL + 1))
else
  # Escape periods for grep -E (the only meta-char in a SemVer-like string).
  A11_PATTERN="${A11_VERSION//./\\.}"
  assert_grep "$MARKETPLACE_JSON" "\"version\":[[:space:]]*\"$A11_PATTERN\"" \
    "A11a: marketplace.json version matches plugin.json canonical ($A11_VERSION)"
  assert_grep "$README" "version-$A11_PATTERN-blue" \
    "A11b: README.md badge version matches plugin.json canonical ($A11_VERSION)"
fi

# --- Layer B — Functional fake-gh tests ------------------------------------

echo
echo "== B1: discover_bare_fast_path happy path =="
# Fake gh emits "2" on stdout (length-of-array via the in-process --jq
# 'length' filter). Function should pass that through, exit 0, and write
# nothing to the audit log.
B1_AUDIT="$(mktemp)"
rm -f "$B1_AUDIT"
_run_lib_call "success-bare" \
  'discover_bare_fast_path feat/my-branch' \
  "export UBERDEV_AUDIT_LOG_PATH='$B1_AUDIT'"
assert_eq "$_LB_STDOUT" "2" "B1a: stdout is the integer count '2'"
assert_eq "$_LB_EXIT" "0" "B1b: exit code is 0 on success"
if [ ! -s "$B1_AUDIT" ]; then
  echo "  PASS  B1c: no audit event written on happy path"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B1c: audit log unexpectedly non-empty: $(cat "$B1_AUDIT" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
rm -f "$B1_AUDIT"

echo
echo "== B2: discover_bare_fast_path gh-failure path =="
# Fake gh exits 1 with stderr "network unreachable". Function must:
#   - return exit 1
#   - emit 'warning: bare-mode discovery failed' to stderr
#   - append a discovery_gh_failed audit event with step=1.0.5,
#     exit_code=1, reason=gh_failed, gh_stderr containing the original
#     "network unreachable" diagnostic.
B2_AUDIT="$(mktemp)"
rm -f "$B2_AUDIT"
_run_lib_call "fail-net" \
  'discover_bare_fast_path feat/my-branch' \
  "export UBERDEV_AUDIT_LOG_PATH='$B2_AUDIT'"
assert_eq "$_LB_EXIT" "1" "B2a: exit code is 1 on gh failure"
case "$_LB_STDERR" in
  *"warning: bare-mode discovery failed"*)
    echo "  PASS  B2b: stderr contains 'warning: bare-mode discovery failed'"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  B2b: stderr missing 'warning: bare-mode discovery failed'"
    echo "        actual stderr: $_LB_STDERR"
    FAIL=$((FAIL + 1))
    ;;
esac
if [ -s "$B2_AUDIT" ]; then
  assert_grep "$B2_AUDIT" '"event":"discovery_gh_failed"' \
    "B2c: audit log contains discovery_gh_failed event"
  assert_grep "$B2_AUDIT" '"step":"1\.0\.5"' \
    "B2d: audit event has step=1.0.5"
  assert_grep "$B2_AUDIT" '"reason":"gh_failed"' \
    "B2e: audit event has reason=gh_failed"
  assert_grep "$B2_AUDIT" '"exit_code":1' \
    "B2f: audit event has exit_code=1"
  assert_grep "$B2_AUDIT" 'network unreachable' \
    "B2g: audit event gh_stderr contains 'network unreachable'"
else
  echo "  FAIL  B2c-g: audit log was not written (file empty: $B2_AUDIT)"
  FAIL=$((FAIL + 5))
fi
rm -f "$B2_AUDIT"

echo
echo "== B3: discover_multi spinner-pollution defense (R1) =="
# Headline anti-regression: fake gh emits valid JSON on stdout AND ANSI
# cursor escapes on stderr. With the OLD `gh ... 2>&1 | jq …` shape, the
# escapes would have crashed jq. With the NEW `gh --jq '<filter>'` shape,
# stderr cannot reach the function's stdout — the call must succeed.
B3_AUDIT="$(mktemp)"
rm -f "$B3_AUDIT"
_run_lib_call "spinner-leak" \
  'discover_multi main' \
  "export UBERDEV_AUDIT_LOG_PATH='$B3_AUDIT'"
assert_eq "$_LB_EXIT" "0" "B3a: exit code 0 despite spinner-leaking gh stderr"
case "$_LB_STDOUT" in
  *'"number":'*'101'*)
    echo "  PASS  B3b: stdout is valid JSON array (parseable by downstream code)"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  B3b: stdout did not contain expected JSON content"
    echo "        actual stdout: $_LB_STDOUT"
    FAIL=$((FAIL + 1))
    ;;
esac
# stdout must NOT contain ANSI escape sequences. The OLD shape merged
# stderr into stdout via 2>&1; the NEW shape must keep them separate.
case "$_LB_STDOUT" in
  *$'\x1b'*)
    echo "  FAIL  B3c: stdout was contaminated with ANSI escapes (R1 regression)"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  PASS  B3c: stdout is clean of ANSI escape sequences"
    PASS=$((PASS + 1))
    ;;
esac
if [ ! -s "$B3_AUDIT" ]; then
  echo "  PASS  B3d: no audit event on happy spinner-leak path"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B3d: audit log unexpectedly non-empty: $(cat "$B3_AUDIT" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
rm -f "$B3_AUDIT"

echo
echo "== B4: discover_multi gh/jq-failure path =="
# Note: gh's internal --jq filter exits non-zero when the upstream JSON is
# malformed. The fake-gh `fail-malformed` mode simulates that exact shape
# (exit 1, malformed JSON on stdout, parser error on stderr). The lib
# treats this as a discovery failure and:
#   - returns '[]' on stdout (so callers get an empty candidate set
#     rather than an aborted run — discovery is best-effort)
#   - returns exit 0 (the contract says discover_multi never aborts the
#     run; the failure is recorded in the audit log instead)
#   - appends a discovery_gh_failed audit event with step=1.2.5
#     and reason=jq_failed (or reason=gh_failed if the lib chooses to
#     report based on gh's exit code rather than the filter outcome —
#     both are acceptable; we accept either).
B4_AUDIT="$(mktemp)"
rm -f "$B4_AUDIT"
_run_lib_call "fail-malformed" \
  'discover_multi main' \
  "export UBERDEV_AUDIT_LOG_PATH='$B4_AUDIT'"
assert_eq "$_LB_STDOUT" "[]" "B4a: stdout is '[]' on jq/gh failure (best-effort discovery)"
assert_eq "$_LB_EXIT" "0" "B4b: exit code 0 (failure recorded in audit, run continues)"
case "$_LB_STDERR" in
  *"warning: multi-discover failed"*)
    echo "  PASS  B4c: stderr contains 'warning: multi-discover failed'"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  B4c: stderr missing 'warning: multi-discover failed'"
    echo "        actual stderr: $_LB_STDERR"
    FAIL=$((FAIL + 1))
    ;;
esac
if [ -s "$B4_AUDIT" ]; then
  assert_grep "$B4_AUDIT" '"event":"discovery_gh_failed"' \
    "B4d: audit log contains discovery_gh_failed event"
  assert_grep "$B4_AUDIT" '"step":"1\.2\.5"' \
    "B4e: audit event has step=1.2.5"
  # Accept either reason — see comment above. The lib's choice depends on
  # how it distinguishes a non-zero gh exit from a filter failure.
  assert_grep "$B4_AUDIT" '"reason":"(jq_failed|gh_failed)"' \
    "B4f: audit event reason is jq_failed or gh_failed"
else
  echo "  FAIL  B4d-f: audit log was not written (file empty: $B4_AUDIT)"
  FAIL=$((FAIL + 3))
fi
rm -f "$B4_AUDIT"

echo
echo "== B5: pr_view_projection happy path =="
B5_AUDIT="$(mktemp)"
rm -f "$B5_AUDIT"
_run_lib_call "success-pr-view" \
  'pr_view_projection 42' \
  "export UBERDEV_AUDIT_LOG_PATH='$B5_AUDIT'"
assert_eq "$_LB_EXIT" "0" "B5a: exit code 0 on happy path"
# Verify the 15 fields are all present in stdout (sanity — the fake-gh
# fixture emits all 15, and the lib's --jq projection should preserve them).
for field in state isDraft reviewDecision statusCheckRollup headRepository \
             maintainerCanModify isCrossRepository headRefName headRefOid \
             baseRefName body commits labels createdAt author; do
  case "$_LB_STDOUT" in
    *"\"$field\""*)
      # one PASS per field → 15 assertions in this block
      echo "  PASS  B5: stdout contains field '$field'"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  B5: stdout missing field '$field'"
      FAIL=$((FAIL + 1))
      ;;
  esac
done
if [ ! -s "$B5_AUDIT" ]; then
  echo "  PASS  B5z: no audit event on happy pr_view_projection"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B5z: audit log unexpectedly non-empty: $(cat "$B5_AUDIT" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
rm -f "$B5_AUDIT"

echo
echo "== B6: pr_view_projection gh-failure path =="
B6_AUDIT="$(mktemp)"
rm -f "$B6_AUDIT"
_run_lib_call "fail-pr-view" \
  'pr_view_projection 42' \
  "export UBERDEV_AUDIT_LOG_PATH='$B6_AUDIT'"
assert_eq "$_LB_EXIT" "1" "B6a: exit code 1 on gh failure"
case "$_LB_STDERR" in
  *"warning: pr_view_projection #42 failed"*)
    echo "  PASS  B6b: stderr contains 'warning: pr_view_projection #42 failed'"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  B6b: stderr missing 'warning: pr_view_projection #42 failed'"
    echo "        actual stderr: $_LB_STDERR"
    FAIL=$((FAIL + 1))
    ;;
esac
if [ -s "$B6_AUDIT" ]; then
  assert_grep "$B6_AUDIT" '"event":"discovery_gh_failed"' \
    "B6c: audit log contains discovery_gh_failed event"
  assert_grep "$B6_AUDIT" '"step":"1\.4"' \
    "B6d: audit event has step=1.4"
  assert_grep "$B6_AUDIT" '"pr_number":42' \
    "B6e: audit event has pr_number=42"
  assert_grep "$B6_AUDIT" '"exit_code":2' \
    "B6f: audit event has exit_code=2 (fake-gh fail-pr-view exits 2)"
else
  echo "  FAIL  B6c-f: audit log was not written (file empty: $B6_AUDIT)"
  FAIL=$((FAIL + 4))
fi
rm -f "$B6_AUDIT"

echo
echo "== B7: audit log path is configurable via UBERDEV_AUDIT_LOG_PATH =="
# Verify the env-var override actually redirects audit lines away from the
# default `.uberdev/audit.jsonl`. We use a unique-per-pid path under /tmp
# (no collisions across parallel test runs) and assert it lands there.
# We also assert the default path is NOT written to. To make that assertion
# robust we run from a fresh PWD where `.uberdev/audit.jsonl` is guaranteed
# absent at start.
B7_SANDBOX="$(mktemp -d)"
B7_AUDIT="/tmp/test-audit-$$"
rm -f "$B7_AUDIT"
# We deliberately use the failure path so an audit line is forced out.
(
  cd "$B7_SANDBOX"
  PATH="$FAKE_GH_DIR:$PATH"
  export FAKE_GH_MODE="fail-net"
  export UBERDEV_AUDIT_LOG_PATH="$B7_AUDIT"
  if [ ! -r "$LIB" ]; then
    echo "lib/discover.sh missing — Layer B cannot source it" >&2
    exit 127
  fi
  # shellcheck source=/dev/null
  . "$LIB"
  discover_bare_fast_path feat/branch >/dev/null 2>&1 || true
)
if [ -s "$B7_AUDIT" ]; then
  echo "  PASS  B7a: audit line landed in UBERDEV_AUDIT_LOG_PATH override"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B7a: audit line did not land in $B7_AUDIT (override ignored?)"
  FAIL=$((FAIL + 1))
fi
if [ ! -s "$B7_SANDBOX/.uberdev/audit.jsonl" ]; then
  echo "  PASS  B7b: default .uberdev/audit.jsonl was NOT written when override set"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B7b: default .uberdev/audit.jsonl was written despite override"
  echo "        contents: $(cat "$B7_SANDBOX/.uberdev/audit.jsonl" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi
rm -f "$B7_AUDIT"
rm -rf "$B7_SANDBOX"

echo
echo "== A12: discover_review_verdict_json — find-based audit-JSON discovery shape (#303) =="
# #303 / RFC 0012 §3.2 item 2: the inline `compgen -G` OR-chain in SKILL.md
# Step (c.0) was a bashism that silently misfired under the zsh Bash tool
# (#294 _uberdev_goal_glob_worktree class). The replacement is a find-based
# helper here in lib/discover.sh; `find` is an external binary with identical
# semantics under bash 3.2, zsh, and CI bash. tests/merge.test.sh
# M63.worktree-glob.* locks the four-layout enumeration sync across surfaces;
# this file locks the function shape + runtime behavior.
assert_grep "$LIB" '^discover_review_verdict_json\(\)[[:space:]]*\{' \
  "A12a: function discover_review_verdict_json defined"
assert_grep "$LIB" '0.*found|FOUND=0|return 0.*found' \
  "A12a.1: discovery contract declares FOUND=0"
assert_grep "$LIB" '1.*absent|ABSENT=1|return 1.*absent' \
  "A12a.2: discovery contract declares exhaustive ABSENT=1"
assert_grep "$LIB" '2.*indeterminate|INDETERMINATE=2|return 2.*indeterminate' \
  "A12a.3: discovery contract declares INDETERMINATE=2"
assert_no_grep "$LIB" '^[[:space:]]*(if[[:space:]]+)?compgen[[:space:]]|\|\|[[:space:]]*compgen[[:space:]]' \
  "A12b: no compgen invocation in lib/discover.sh (bashism — #294 class; comments may mention it)"
assert_grep "$LIB" \
  'RUN_ID_RE = re\.compile\(r"\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$"\)|grep -qE .\^\[0-9\]\{8\}-\[0-9\]\{6\}-\[a-f0-9\]\+\$' \
  "A12c: run-id segment is validated against RUN_ID_REGEX without [[ =~ ]] / BASH_REMATCH"
# A12d — `[ a \> b ]` is a bash test-builtin extension: zsh's `[` rejects
# `\>` with "condition expected: >", silently degrading the run-id tie-break
# to first-found. Caught live during #303 implementation; the fix is
# LC_ALL=C expr. Comment lines are stripped before the check (the rationale
# comments legitimately mention the forbidden shape); LIB_NORMALISED is set
# at A3.
if printf '%s\n' "$LIB_NORMALISED" | grep -qE '\[ [^][]*\\>'; then
  echo "  FAIL  A12d: '[ ... \\> ... ]' test-bracket string comparison present (zsh rejects it — use LC_ALL=C expr)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  A12d: no '[ ... \\> ... ]' test-bracket string comparison (zsh-safe tie-break)"
  PASS=$((PASS + 1))
fi

echo
echo "== B8: discover_review_verdict_json functional — four layouts, .pr filter, run-id regex, tie-break (#303) =="
# Sandbox repo root with verdict JSONs across all four documented layouts.
# The helper searches relative paths from CWD, so we cd into the sandbox
# (mirrors the B7 sandbox convention).
B8_SANDBOX="$(mktemp -d)"
B8_SHA_OLD="1111111111111111111111111111111111111111"
B8_SHA_NEW="2222222222222222222222222222222222222222"
B8_SHA_99="9999999999999999999999999999999999999999"
B8_SHA_77="7777777777777777777777777777777777777777"
mkdir -p "$B8_SANDBOX/.uberdev/runs/20260101-000000-aaaa111"
printf '{"pr":42,"sha":"%s"}\n' "$B8_SHA_OLD" \
  > "$B8_SANDBOX/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json"
mkdir -p "$B8_SANDBOX/.claude/worktrees/solve-issue-7/.uberdev/runs/20260102-000000-bbbb222"
printf '{"pr":42,"sha":"%s"}\n' "$B8_SHA_NEW" \
  > "$B8_SANDBOX/.claude/worktrees/solve-issue-7/.uberdev/runs/20260102-000000-bbbb222/review-pr-verdict.json"
mkdir -p "$B8_SANDBOX/.worktrees/wt1/.uberdev/runs/20260103-000000-cccc333"
printf '{"pr":99,"sha":"%s"}\n' "$B8_SHA_99" \
  > "$B8_SANDBOX/.worktrees/wt1/.uberdev/runs/20260103-000000-cccc333/review-pr-verdict.json"
mkdir -p "$B8_SANDBOX/worktrees/wt2/.uberdev/runs/20251231-000000-dddd444"
printf '{"pr":77,"sha":"%s"}\n' "$B8_SHA_77" \
  > "$B8_SANDBOX/worktrees/wt2/.uberdev/runs/20251231-000000-dddd444/review-pr-verdict.json"
# Path-traversal / regex-rejection fixture: a verdict for PR 42 under a
# run-id that fails RUN_ID_REGEX. "zz-invalid-run-id" sorts lex-GREATER than
# any timestamp run-id, so if the regex validation were dropped this entry
# would win the PR-42 tie-break — B8a doubles as the regex-rejection guard.
mkdir -p "$B8_SANDBOX/worktrees/wt3/.uberdev/runs/zz-invalid-run-id"
printf '{"pr":42,"sha":"%s"}\n' "$B8_SHA_OLD" \
  > "$B8_SANDBOX/worktrees/wt3/.uberdev/runs/zz-invalid-run-id/review-pr-verdict.json"

_b8_call() {
  # Args: PR number (forwarded verbatim). Runs the helper from the sandbox.
  ( cd "$B8_SANDBOX" && . "$LIB" && discover_review_verdict_json "$1" ) 2>/dev/null
}

B8_OUT="$(_b8_call 42)"
B8_RC=$?
assert_eq "$(printf '%s' "$B8_OUT" | jq -r '.artifact_sha // empty')" \
  "$B8_SHA_NEW" \
  "B8a: PR 42 → newest valid timestamp wins across layouts (invalid run-id rejected)"
assert_eq "$B8_RC" "0" "B8a.rc: PR 42 match → FOUND=0"
( . "$LIB"; cleanup_review_verdict_snapshot "$B8_OUT" ) >/dev/null 2>&1 || true
B8_OUT="$(_b8_call 99)"
B8_RC=$?
assert_eq "$(printf '%s' "$B8_OUT" | jq -r '.artifact_sha // empty')" \
  "$B8_SHA_99" \
  "B8b: PR 99 → .worktrees/ hidden-convention layout found"
assert_eq "$B8_RC" "0" "B8b.rc: PR 99 match → FOUND=0"
( . "$LIB"; cleanup_review_verdict_snapshot "$B8_OUT" ) >/dev/null 2>&1 || true
B8_OUT="$(_b8_call 77)"
B8_RC=$?
assert_eq "$(printf '%s' "$B8_OUT" | jq -r '.artifact_sha // empty')" \
  "$B8_SHA_77" \
  "B8c: PR 77 → worktrees/ visible-convention layout found"
assert_eq "$B8_RC" "0" "B8c.rc: PR 77 match → FOUND=0"
( . "$LIB"; cleanup_review_verdict_snapshot "$B8_OUT" ) >/dev/null 2>&1 || true
B8_OUT="$(_b8_call 123)"
B8_RC=$?
assert_eq "$B8_OUT" "" "B8d: unmatched PR → empty stdout (corroborator absent)"
assert_eq "$B8_RC" "1" "B8e: unmatched PR → exit 1 (exhaustive ABSENT contract)"
B8_OUT="$(_b8_call 'x; rm -rf /')"
B8_RC=$?
assert_eq "$B8_OUT" "" "B8f: non-integer PR argument → empty stdout (input gate)"
assert_eq "$B8_RC" "2" "B8g: non-integer PR argument → exit 2 (invalid input is INDETERMINATE, never ABSENT)"
rm -rf "$B8_SANDBOX"

echo
echo "== B9: discover_review_verdict_json zsh parity (#303 — the helper exists to fix a zsh bashism) =="
# The pre-#303 compgen chain AND an early draft of this helper ([ a \> b ])
# both misfired ONLY under zsh — bash-run tests alone cannot catch the
# class (the #294 _uberdev_goal_glob_worktree lesson). Run the same
# discovery under a real zsh when available (macOS always; CI ubuntu images
# ship zsh — the solve-pipeline-zsh fixture relies on it) and assert
# bash-identical output plus a clean stderr (a "condition expected" class
# error surfaces there).
if command -v zsh >/dev/null 2>&1; then
  B9_SANDBOX="$(mktemp -d)"
  B9_SHA_OLD="3333333333333333333333333333333333333333"
  B9_SHA_NEW="4444444444444444444444444444444444444444"
  mkdir -p "$B9_SANDBOX/.uberdev/runs/20260101-000000-aaaa111"
  printf '{"pr":42,"sha":"%s"}\n' "$B9_SHA_OLD" \
    > "$B9_SANDBOX/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json"
  mkdir -p "$B9_SANDBOX/.claude/worktrees/w/.uberdev/runs/20260105-000000-ffff999"
  printf '{"pr":42,"sha":"%s"}\n' "$B9_SHA_NEW" \
    > "$B9_SANDBOX/.claude/worktrees/w/.uberdev/runs/20260105-000000-ffff999/review-pr-verdict.json"
  B9_ERR="$(mktemp)"
  B9_OUT="$(zsh -c "cd '$B9_SANDBOX' && . '$LIB' && discover_review_verdict_json 42" 2>"$B9_ERR")"
  B9_RC=$?
  assert_eq "$(printf '%s' "$B9_OUT" | jq -r '.artifact_sha // empty')" \
    "$B9_SHA_NEW" \
    "B9a: zsh run picks the newest timestamp (receipt parity with bash)"
  assert_eq "$B9_RC" "0" "B9a.rc: zsh match → FOUND=0"
  if [ -s "$B9_ERR" ]; then
    echo "  FAIL  B9b: zsh run emitted stderr (bashism leak?): $(head -c 200 "$B9_ERR")"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  B9b: zsh run emitted no stderr (no 'condition expected' class errors)"
    PASS=$((PASS + 1))
  fi
  ( . "$LIB"; cleanup_review_verdict_snapshot "$B9_OUT" ) >/dev/null 2>&1 || true
  rm -f "$B9_ERR"
  rm -rf "$B9_SANDBOX"
else
  echo "  SKIP  B9: zsh not available on this runner (informational — macOS and CI ubuntu both ship zsh)"
fi

echo
echo "== B10: verdict discovery identity safety + recency ordering =="
B10_SANDBOX="$(mktemp -d)"
B10_ERR="$(mktemp)"
B10_SHA_42="5555555555555555555555555555555555555555"
B10_VALID_42="{\"pr\":42,\"sha\":\"$B10_SHA_42\"}"

_b10_clear() {
  rm -rf \
    "$B10_SANDBOX/.uberdev" \
    "$B10_SANDBOX/.claude" \
    "$B10_SANDBOX/.worktrees" \
    "$B10_SANDBOX/worktrees"
  : > "$B10_ERR"
}

_b10_write() {
  local relative_path="$1"
  local json="$2"
  mkdir -p "$(dirname "$B10_SANDBOX/$relative_path")"
  printf '%s\n' "$json" > "$B10_SANDBOX/$relative_path"
}

_b10_call() {
  local pr_number="$1"
  ( cd "$B10_SANDBOX" && . "$LIB" && discover_review_verdict_json "$pr_number" ) 2>"$B10_ERR"
}

_b10_receipt_sha() {
  printf '%s' "$1" | jq -r '.artifact_sha // empty' 2>/dev/null
}

_b10_cleanup_receipt() {
  [ -n "$1" ] || return 0
  ( . "$LIB"; cleanup_review_verdict_snapshot "$1" ) >/dev/null 2>&1 || true
}

# An empty, fully scanned search surface is exhaustive absence.
_b10_clear
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10zero.1: empty exhaustive scan emits no path"
assert_eq "$B10_RC" "1" "B10zero.2: empty exhaustive scan → ABSENT=1"

# A valid-run-id candidate whose identity cannot be parsed is not evidence of
# exhaustive absence.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10a.1: malformed identity candidate emits no path"
assert_eq "$B10_RC" "2" "B10a.2: malformed identity candidate → INDETERMINATE=2, never ABSENT"
if grep -qiE 'indeterminate|identity.*unknown|malformed' "$B10_ERR"; then
  echo "  PASS  B10a.3: malformed identity emits a stderr reason"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B10a.3: malformed identity MUST emit an indeterminate stderr reason"
  FAIL=$((FAIL + 1))
fi

# Unreadable identity is the same unknown-identity class.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":42}'
chmod 000 "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json"
B10_OUT="$(_b10_call 42)"
B10_RC=$?
chmod 600 "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json"
assert_eq "$B10_OUT" "" "B10b.1: unreadable identity candidate emits no path"
assert_eq "$B10_RC" "2" "B10b.2: unreadable identity candidate → INDETERMINATE=2, never ABSENT"

# A string lookalike is not the integer PR identity.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":"42"}'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10bstr.1: string PR lookalike emits no path"
assert_eq "$B10_RC" "2" "B10bstr.2: string PR lookalike → INDETERMINATE=2"

# Symlinked artifacts are not trusted as local run-owned identity evidence.
_b10_clear
printf '%s\n' '{"pr":42}' > "$B10_SANDBOX/outside-verdict.json"
mkdir -p "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaa111"
ln -s "$B10_SANDBOX/outside-verdict.json" \
  "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json"
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10blink.1: symlinked identity candidate emits no path"
assert_eq "$B10_RC" "2" "B10blink.2: symlinked identity candidate → INDETERMINATE=2"
rm -f "$B10_SANDBOX/outside-verdict.json"

# Fully readable candidates for other PRs prove exhaustive absence.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":99}'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10c.1: valid other-PR-only scan emits no path"
assert_eq "$B10_RC" "1" "B10c.2: valid other-PR-only scan remains exhaustive ABSENT=1"

# An older identity-unknown candidate cannot override a newer valid target.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":'
_b10_write \
  ".worktrees/wt/.uberdev/runs/20260102-000000-bbbb222/review-pr-verdict.json" \
  "$B10_VALID_42"
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$(_b10_receipt_sha "$B10_OUT")" \
  "$B10_SHA_42" \
  "B10d.1: newer valid target outranks older identity-unknown candidate"
assert_eq "$B10_RC" "0" "B10d.2: newer valid target → FOUND=0"
_b10_cleanup_receipt "$B10_OUT"

# A newer identity-unknown candidate may be the target's superseding artifact,
# so the older valid target is not safe to select.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  "$B10_VALID_42"
_b10_write \
  ".worktrees/wt/.uberdev/runs/20260102-000000-bbbb222/review-pr-verdict.json" \
  '{"pr":'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10e.1: newer identity-unknown candidate suppresses older target path"
assert_eq "$B10_RC" "2" "B10e.2: newer identity-unknown candidate → INDETERMINATE=2"

# Equal run-id across layouts is equally unsafe when one identity is unknown.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  "$B10_VALID_42"
_b10_write \
  ".worktrees/wt/.uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  '{"pr":'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10f.1: equal-run-id identity ambiguity emits no target path"
assert_eq "$B10_RC" "2" "B10f.2: equal-run-id identity ambiguity → INDETERMINATE=2"

# A newer known-other-PR artifact cannot hide an older valid target.
_b10_clear
_b10_write \
  ".uberdev/runs/20260101-000000-aaaa111/review-pr-verdict.json" \
  "$B10_VALID_42"
_b10_write \
  ".worktrees/wt/.uberdev/runs/20260102-000000-bbbb222/review-pr-verdict.json" \
  '{"pr":99}'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$(_b10_receipt_sha "$B10_OUT")" \
  "$B10_SHA_42" \
  "B10fother.1: newer known-other-PR candidate does not suppress target"
assert_eq "$B10_RC" "0" "B10fother.2: older target with newer known-other → FOUND=0"
_b10_cleanup_receipt "$B10_OUT"

# Invalid run-id candidates never participate in identity or recency ranking.
_b10_clear
_b10_write \
  ".uberdev/runs/not-a-run-id/review-pr-verdict.json" \
  '{"pr":'
B10_OUT="$(_b10_call 42)"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10g.1: invalid-run-id candidate is ignored"
assert_eq "$B10_RC" "1" "B10g.2: invalid-run-id-only scan is exhaustive ABSENT=1"

# Any incomplete root scan is indeterminate, even when no candidate bytes were
# returned. Shadow find with a deterministic failure to exercise this seam.
_b10_clear
B10_FAKE_BIN="$B10_SANDBOX/fake-find-bin"
mkdir -p "$B10_FAKE_BIN"
mkdir -p "$B10_SANDBOX/.uberdev/runs"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$B10_FAKE_BIN/find"
chmod +x "$B10_FAKE_BIN/find"
B10_OUT="$(
  cd "$B10_SANDBOX" &&
  PATH="$B10_FAKE_BIN:$PATH" &&
  export PATH &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B10_ERR"
B10_RC=$?
assert_eq "$B10_OUT" "" "B10h.1: failed root scan emits no path"
assert_eq "$B10_RC" "2" "B10h.2: failed root scan → INDETERMINATE=2"

rm -f "$B10_ERR"
rm -rf "$B10_SANDBOX"

echo
echo "== A13/B11: phase2_5 parser validates raw types and publishes atomically =="
assert_grep "$LIB" '^parse_review_verdict_phase2_5\(\)[[:space:]]*\{' \
  "A13: function parse_review_verdict_phase2_5 defined"

B11_SANDBOX="$(mktemp -d)"
B11_ERR="$(mktemp)"
B11_JSON="$B11_SANDBOX/review-pr-verdict.json"

_b11_call() {
  ( cd "$B11_SANDBOX" && . "$LIB" && parse_review_verdict_phase2_5 "$B11_JSON" ) 2>"$B11_ERR"
}

printf '%s\n' '{"phases":{"phase2_5":{}}}' > "$B11_JSON"
B11_OUT="$(_b11_call)"
B11_RC=$?
assert_eq "$B11_OUT" $'current\tfalse\t0\t0\tnull' \
  "B11a.1: empty phase2_5 object is current-clean with caller defaults"
assert_eq "$B11_RC" "0" "B11a.2: empty phase2_5 object parses successfully"

printf '%s\n' \
  '{"phases":{"phase2_5":{"halted":null,"by_severity":{"blocker":null,"critical":null},"override_reason":null}}}' \
  > "$B11_JSON"
B11_OUT="$(_b11_call)"
B11_RC=$?
assert_eq "$B11_OUT" $'current\tfalse\t0\t0\tnull' \
  "B11b.1: explicit null optional fields preserve current-clean defaults"
assert_eq "$B11_RC" "0" "B11b.2: explicit null optional fields parse successfully"

printf '%s\n' '{"phases":{}}' > "$B11_JSON"
B11_OUT="$(_b11_call)"
B11_RC=$?
assert_eq "$B11_OUT" $'legacy\tfalse\t0\t0\tnull' \
  "B11c.1: missing phase2_5 block is a present legacy audit"
assert_eq "$B11_RC" "0" "B11c.2: legacy audit parses successfully"

printf '%s\n' '{"phases":{"phase2_5":{"by_severity":{"blocker":false}}}}' > "$B11_JSON"
B11_OUT="$(_b11_call)"
B11_RC=$?
assert_eq "$B11_OUT" "" "B11d.1: explicit blocker:false never publishes a tuple"
assert_eq "$B11_RC" "2" "B11d.2: explicit blocker:false is malformed"

printf '%s\n' '{"phases":{"phase2_5":{"by_severity":{"critical":false}}}}' > "$B11_JSON"
B11_OUT="$(_b11_call)"
B11_RC=$?
assert_eq "$B11_OUT" "" "B11e.1: explicit critical:false never publishes a tuple"
assert_eq "$B11_RC" "2" "B11e.2: explicit critical:false is malformed"

# A zero-exit jq that fails to return the complete five-field tuple models an
# extraction seam failure. The parser must validate output before publishing
# current state.
B11_FAKE_BIN="$B11_SANDBOX/fake-bin"
mkdir -p "$B11_FAKE_BIN"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "current\tfalse\t0\n"' \
  'exit 0' \
  > "$B11_FAKE_BIN/jq"
chmod +x "$B11_FAKE_BIN/jq"
B11_OUT="$(
  cd "$B11_SANDBOX" &&
  PATH="$B11_FAKE_BIN:$PATH" &&
  export PATH &&
  . "$LIB" &&
  parse_review_verdict_phase2_5 "$B11_JSON"
)" 2>"$B11_ERR"
B11_RC=$?
assert_eq "$B11_OUT" "" "B11f.1: incomplete extraction never publishes current state"
assert_eq "$B11_RC" "2" "B11f.2: incomplete extraction is malformed"

rm -f "$B11_ERR"
rm -rf "$B11_SANDBOX"

echo
echo "== A14/B12: closed verdict receipt + secure snapshot contract =="
assert_grep "$LIB" '^review_verdict_discovery_state\(\)[[:space:]]*\{' \
  "A14a: executable discovery rc-to-state helper is defined"
assert_grep "$LIB" 'find[[:space:]]+-H[[:space:]]' \
  "A14b: command-line roots are traversed with find -H"
assert_no_grep "$LIB" 'find[[:space:]]+-L[[:space:]]' \
  "A14c: descendant symlinks are never followed with find -L"
assert_grep "$LIB" '"-mindepth",' \
  "A14c.1: find bounds depth and exact slash-path before emitting candidates"
assert_grep "$LIB" '\.uberdev/runs/\*/review-pr-verdict\.json' \
  "A14c.2: canonical run root declares exact depth 2"
assert_grep "$LIB" '\.worktrees/\*/\.uberdev/runs/\*/review-pr-verdict\.json' \
  "A14c.3: worktree roots declare exact depth 5"
assert_grep "$LIB" 'secure_capture_regular' \
  "A14d: candidate authority uses run_manifest.secure_capture_regular"
assert_grep "$LIB" 'secure_publish_captured' \
  "A14e: selected bytes use run_manifest.secure_publish_captured"
assert_grep "$LIB" 'secure_capture_published' \
  "A14f: published carrier is digest-recaptured before receipt emission"
assert_grep "$LIB" '^recapture_review_verdict_snapshot\(\)[[:space:]]*\{' \
  "A14g: snapshot drift validator is defined"
assert_grep "$LIB" '^cleanup_review_verdict_snapshot\(\)[[:space:]]*\{' \
  "A14h: caller-owned stable snapshot cleanup helper is defined"

for B12_PAIR in '0 found' '1 absent' '2 indeterminate' '71 indeterminate'; do
  set -- $B12_PAIR
  B12_STATE="$(
    . "$LIB"
    review_verdict_discovery_state "$1"
  )" 2>/dev/null
  B12_STATE_RC=$?
  assert_eq "$B12_STATE" "$2" "B12.rc.$1: discovery rc $1 maps to $2"
  assert_eq "$B12_STATE_RC" "0" "B12.rc.$1.status: state helper itself succeeds"
done

B12_SANDBOX="$(mktemp -d)"
B12_ERR="$(mktemp)"
B12_SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B12_SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

_b12_clear() {
  rm -rf \
    "$B12_SANDBOX/.uberdev" \
    "$B12_SANDBOX/.claude" \
    "$B12_SANDBOX/.worktrees" \
    "$B12_SANDBOX/worktrees" \
    "$B12_SANDBOX/_linked_worktrees" \
    "$B12_SANDBOX/_outside"
  : > "$B12_ERR"
}

_b12_payload() {
  local pr="$1" sha="$2" blocker="${3:-0}" critical="${4:-0}"
  printf '{"pr":%s,"sha":"%s","phases":{"phase2_5":{"halted":false,"by_severity":{"blocker":%s,"critical":%s},"override_reason":null}}}\n' \
    "$pr" "$sha" "$blocker" "$critical"
}

_b12_write() {
  local relative_path="$1" payload="$2"
  mkdir -p "$(dirname "$B12_SANDBOX/$relative_path")"
  printf '%s' "$payload" > "$B12_SANDBOX/$relative_path"
}

_b12_capture() {
  local pr="$1"
  (
    cd "$B12_SANDBOX" || exit 2
    . "$LIB"
    discover_review_verdict_json "$pr"
  ) 2>"$B12_ERR"
}

_b12_assert_receipt() {
  local receipt="$1" expected_sha="$2" desc="$3"
  if printf '%s' "$receipt" | jq -e \
    --arg sha "$expected_sha" '
      .schema_version == 1
      and (.snapshot_path | type == "string" and length > 0)
      and (.snapshot_sha256 | test("^[0-9a-f]{64}$"))
      and (.snapshot_identity | type == "array" and length == 6)
      and .artifact_sha == $sha
      and .audit_state == "current"
      and .phase2_5_halted == false
      and .phase2_5_blocker_count == 0
      and .phase2_5_critical_count == 0
      and .phase2_5_override_reason == null
    ' >/dev/null 2>&1; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        receipt: $receipt"
    FAIL=$((FAIL + 1))
  fi
}

# Optional roots that do not exist are exhaustively absent.
_b12_clear
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.root.absent.out: absent optional roots emit no receipt"
assert_eq "$B12_RC" "1" "B12.root.absent.rc: absent optional roots → ABSENT=1"

# An allowed root hidden behind an inaccessible ancestor is not proven absent.
# The root probe must distinguish ENOENT from inspection errors so merge cannot
# bypass a verdict by taking the audit-absent path.
_b12_clear
mkdir -p "$B12_SANDBOX/.claude"
chmod 000 "$B12_SANDBOX/.claude"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
chmod 700 "$B12_SANDBOX/.claude"
assert_eq "$B12_OUT" "" "B12.root.inaccessible.out: inaccessible ancestor emits no receipt"
assert_eq "$B12_RC" "2" "B12.root.inaccessible.rc: inaccessible ancestor → INDETERMINATE=2"
assert_grep "$B12_ERR" 'root inspect failed: \.claude/worktrees' \
  "B12.root.inaccessible.err: inaccessible ancestor reports the failed root probe"

# Each allowed root invokes find with the exact option ordering and depth/path
# contract. This also proves shallow/deep entries never become candidates.
_b12_clear
mkdir -p \
  "$B12_SANDBOX/.uberdev/runs" \
  "$B12_SANDBOX/.claude/worktrees" \
  "$B12_SANDBOX/.worktrees" \
  "$B12_SANDBOX/worktrees"
B12_FIND_BIN="$B12_SANDBOX/fake-depth-bin"
B12_FIND_LOG="$B12_SANDBOX/find-argv.log"
mkdir -p "$B12_FIND_BIN"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"$B12_FIND_LOG"' \
  'exit 0' \
  >"$B12_FIND_BIN/find"
chmod +x "$B12_FIND_BIN/find"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  PATH="$B12_FIND_BIN:$PATH" &&
  export PATH B12_FIND_LOG &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.find.argv.out: bounded empty scans emit no receipt"
assert_eq "$B12_RC" "1" "B12.find.argv.rc: bounded empty scans prove absence"
for B12_EXPECTED_FIND in \
  '-H .uberdev/runs -mindepth 2 -maxdepth 2 -path .uberdev/runs/*/review-pr-verdict.json -print0' \
  '-H .claude/worktrees -mindepth 5 -maxdepth 5 -path .claude/worktrees/*/.uberdev/runs/*/review-pr-verdict.json -print0' \
  '-H .worktrees -mindepth 5 -maxdepth 5 -path .worktrees/*/.uberdev/runs/*/review-pr-verdict.json -print0' \
  '-H worktrees -mindepth 5 -maxdepth 5 -path worktrees/*/.uberdev/runs/*/review-pr-verdict.json -print0'
do
  if grep -Fqx -- "$B12_EXPECTED_FIND" "$B12_FIND_LOG"; then
    echo "  PASS  B12.find.argv: $B12_EXPECTED_FIND"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  B12.find.argv: missing exact argv [$B12_EXPECTED_FIND]"
    FAIL=$((FAIL + 1))
  fi
done

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_A")"
_b12_write ".uberdev/runs/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_B")"
_b12_write ".uberdev/runs/20270101-010101-a1/extra/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_B")"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.find.depth2.rc: canonical shallow/deep decoys are ignored"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.find.depth2.receipt: only exact canonical depth 2 is selected"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

_b12_clear
_b12_write ".worktrees/w/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_A")"
_b12_write ".worktrees/.uberdev/runs/20270101-010101-a1/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_B")"
_b12_write ".worktrees/a/b/.uberdev/runs/20270101-010101-a1/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_B")"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.find.depth5.rc: worktree shallow/deep decoys are ignored"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.find.depth5.receipt: only exact worktree depth 5 is selected"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

# A symlink is supported only as the find -H command-line root. Its captured
# physical target may be external, but that root identity must stay stable.
_b12_clear
mkdir -p "$B12_SANDBOX/_linked_worktrees/w/.uberdev/runs/20260101-010101-a1"
_b12_payload 42 "$B12_SHA_A" \
  > "$B12_SANDBOX/_linked_worktrees/w/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
ln -s "_linked_worktrees" "$B12_SANDBOX/.worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.root.symlink.rc: in-repository command-line root symlink is supported"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.root.symlink.receipt: symlink-root capture returns one closed receipt"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

# Dangling roots are not equivalent to absent optional roots. A valid external
# target is supported because find -H binds the command-line root itself.
_b12_clear
ln -s "missing-target" "$B12_SANDBOX/.worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.root.dangling.out: dangling root emits no receipt"
assert_eq "$B12_RC" "2" "B12.root.dangling.rc: dangling root → INDETERMINATE=2"
_b12_clear
B12_EXTERNAL_ROOT="$(mktemp -d)"
mkdir -p "$B12_EXTERNAL_ROOT/w/.uberdev/runs/20260101-010101-a1"
_b12_payload 42 "$B12_SHA_A" \
  > "$B12_EXTERNAL_ROOT/w/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
ln -s "$B12_EXTERNAL_ROOT" "$B12_SANDBOX/.worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.root.external.rc: external command-line root target is supported"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.root.external.receipt: external-root bytes remain bound to the captured root"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true
rm -rf "$B12_EXTERNAL_ROOT"

# Retargeting an allowed command-line symlink while find is running invalidates
# the scan even when find itself exits zero and returns no candidate.
_b12_clear
B12_RETARGET_A="$(mktemp -d)"
B12_RETARGET_B="$(mktemp -d)"
ln -s "$B12_RETARGET_A" "$B12_SANDBOX/.worktrees"
B12_RETARGET_BIN="$B12_SANDBOX/fake-retarget-bin"
mkdir -p "$B12_RETARGET_BIN"
printf '%s\n' \
  '#!/bin/sh' \
  '/bin/rm -f .worktrees' \
  '/bin/ln -s "$B12_RETARGET_DEST" .worktrees' \
  'exit 0' \
  > "$B12_RETARGET_BIN/find"
chmod +x "$B12_RETARGET_BIN/find"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  PATH="$B12_RETARGET_BIN:$PATH" &&
  B12_RETARGET_DEST="$B12_RETARGET_B" &&
  export PATH B12_RETARGET_DEST &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.root.retarget.out: retargeted root emits no receipt"
assert_eq "$B12_RC" "2" "B12.root.retarget.rc: root identity drift → INDETERMINATE=2"
rm -rf "$B12_RETARGET_A" "$B12_RETARGET_B"

# A find result whose relative suffix attempts lexical traversal is
# indeterminate, even when the command itself exits successfully.
_b12_clear
mkdir -p "$B12_SANDBOX/.worktrees"
B12_TRAVERSAL_BIN="$B12_SANDBOX/fake-traversal-bin"
mkdir -p "$B12_TRAVERSAL_BIN"
printf '%s\n' \
  '#!/bin/sh' \
  'printf ".worktrees/../escape/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json\\0"' \
  'exit 0' \
  > "$B12_TRAVERSAL_BIN/find"
chmod +x "$B12_TRAVERSAL_BIN/find"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  PATH="$B12_TRAVERSAL_BIN:$PATH" &&
  export PATH &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.root.traversal.out: traversal-shaped find result emits no receipt"
assert_eq "$B12_RC" "2" "B12.root.traversal.rc: traversal-shaped find result → INDETERMINATE=2"

# A descendant worktree symlink is not followed by find -H.
_b12_clear
mkdir -p "$B12_SANDBOX/_linked_worktrees/w/.uberdev/runs/20260101-010101-a1"
_b12_payload 42 "$B12_SHA_A" \
  > "$B12_SANDBOX/_linked_worktrees/w/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
mkdir -p "$B12_SANDBOX/.worktrees"
ln -s "$B12_SANDBOX/_linked_worktrees/w" "$B12_SANDBOX/.worktrees/w"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.descendant-symlink.out: descendant symlink is not traversed"
assert_eq "$B12_RC" "1" "B12.descendant-symlink.rc: untraversed descendant proves absence"

# A guarded mktemp failure is infrastructure indeterminacy, never absence.
_b12_clear
B12_FAKE_BIN="$B12_SANDBOX/fake-mktemp-bin"
mkdir -p "$B12_FAKE_BIN"
printf '%s\n' '#!/bin/sh' 'exit 71' > "$B12_FAKE_BIN/mktemp"
chmod +x "$B12_FAKE_BIN/mktemp"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  PATH="$B12_FAKE_BIN:$PATH" &&
  export PATH &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.mktemp.out: mktemp failure emits no receipt"
assert_eq "$B12_RC" "2" "B12.mktemp.rc: mktemp failure → INDETERMINATE=2"

# Rank by the 15-byte timestamp prefix only. At the selected timestamp every
# expected-PR artifact must carry byte-identical payloads.
_b12_clear
B12_PAYLOAD_A="$(_b12_payload 42 "$B12_SHA_A")"
B12_PAYLOAD_B="$(_b12_payload 42 "$B12_SHA_B")"
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write ".worktrees/w/.uberdev/runs/20260101-010101-b2/review-pr-verdict.json" "$B12_PAYLOAD_B"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.tie.divergent.out: same-timestamp divergent target artifacts emit no receipt"
assert_eq "$B12_RC" "2" "B12.tie.divergent.rc: same-timestamp divergent target artifacts → INDETERMINATE=2"

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write ".worktrees/w/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$B12_PAYLOAD_A"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.tie.identical.rc: cross-layout exact-run-id identical bytes are accepted"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.tie.identical.receipt: identical tie publishes one receipt"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-ffff/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write ".worktrees/w/.uberdev/runs/20260101-010102-0000/review-pr-verdict.json" "$B12_PAYLOAD_B"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.rank.seconds.rc: distinct-second ordering remains chronological"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_B" \
  "B12.rank.seconds.receipt: later timestamp wins regardless of suffix ordering"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

# Known other-PR artifacts never affect ranking. Unknown identity is harmless
# only when older than the selected target; newer/equal unknown is fail-closed,
# and with no target any unknown makes absence unprovable.
_b12_clear
_b12_write ".uberdev/runs/20260101-010100-a1/review-pr-verdict.json" '{"pr":'
_b12_write ".worktrees/w/.uberdev/runs/20260101-010101-b2/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write "worktrees/z/.uberdev/runs/20260101-010102-c3/review-pr-verdict.json" "$(_b12_payload 99 "$B12_SHA_B")"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.unknown.older.rc: older unknown + newer other-PR do not suppress target"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B12.unknown.older.receipt: target survives harmless candidates"
(
  . "$LIB"
  cleanup_review_verdict_snapshot "$B12_OUT"
) >/dev/null 2>&1 || true

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write ".worktrees/w/.uberdev/runs/20260101-010102-b2/review-pr-verdict.json" '{"pr":'
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.unknown.newer.out: newer unknown suppresses older target receipt"
assert_eq "$B12_RC" "2" "B12.unknown.newer.rc: newer unknown → INDETERMINATE=2"

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" '{"pr":'
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.unknown.only.out: unknown-only scan emits no receipt"
assert_eq "$B12_RC" "2" "B12.unknown.only.rc: no target + any unknown → INDETERMINATE=2"

echo
echo "== B13: selected verdict parser compatibility and strict-type matrix =="
_b13_valid() {
  local label="$1" payload="$2" expected_state="$3" expected_halted="$4"
  local expected_blocker="$5" expected_critical="$6" expected_override="$7"
  local receipt rc
  _b12_clear
  _b12_write \
    ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
    "$payload"
  receipt="$(_b12_capture 42)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$receipt" | jq -e \
    --arg state "$expected_state" \
    --argjson halted "$expected_halted" \
    --argjson blocker "$expected_blocker" \
    --argjson critical "$expected_critical" \
    --arg override "$expected_override" '
      .audit_state == $state
      and .phase2_5_halted == $halted
      and .phase2_5_blocker_count == $blocker
      and .phase2_5_critical_count == $critical
      and (
        ($override == "null" and .phase2_5_override_reason == null)
        or ($override != "null" and .phase2_5_override_reason == $override)
      )
    ' >/dev/null 2>&1; then
    echo "  PASS  B13.valid.$label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  B13.valid.$label"
    echo "        rc: $rc"
    echo "        receipt: $receipt"
    FAIL=$((FAIL + 1))
  fi
  if [ "$rc" -eq 0 ]; then
    (
      . "$LIB"
      cleanup_review_verdict_snapshot "$receipt"
    ) >/dev/null 2>&1 || true
  fi
}

_b13_invalid() {
  local label="$1" payload="$2" receipt rc
  _b12_clear
  _b12_write \
    ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
    "$payload"
  receipt="$(_b12_capture 42)"
  rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$receipt" ]; then
    echo "  PASS  B13.invalid.$label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  B13.invalid.$label"
    echo "        expected: rc=2 and no receipt"
    echo "        actual rc: $rc"
    echo "        receipt: $receipt"
    FAIL=$((FAIL + 1))
  fi
}

_b13_valid "phases-missing" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\"}" \
  legacy false 0 0 null
_b13_valid "phases-null" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":null}" \
  legacy false 0 0 null
_b13_valid "phase2_5-missing" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{}}" \
  legacy false 0 0 null
_b13_valid "phase2_5-empty" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{}}}" \
  current false 0 0 null
_b13_valid "nullable-defaults" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":null,\"by_severity\":null,\"override_reason\":null}}}" \
  current false 0 0 null
_b13_valid "typed-values" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":true,\"by_severity\":{\"blocker\":2,\"critical\":3},\"override_reason\":\"user-selected-emit-green-on-blocker-deferred\"}}}" \
  current true 2 3 user-selected-emit-green-on-blocker-deferred

_b13_invalid "top-level-array" '[]'
_b13_invalid "duplicate-pr" \
  "{\"pr\":42,\"pr\":42,\"sha\":\"$B12_SHA_A\"}"
_b13_invalid "pr-bool" \
  "{\"pr\":true,\"sha\":\"$B12_SHA_A\"}"
_b13_invalid "pr-string" \
  "{\"pr\":\"42\",\"sha\":\"$B12_SHA_A\"}"
_b13_invalid "pr-fraction" \
  "{\"pr\":42.0,\"sha\":\"$B12_SHA_A\"}"
_b13_invalid "pr-nonpositive" \
  "{\"pr\":0,\"sha\":\"$B12_SHA_A\"}"
_b13_invalid "sha-missing" '{"pr":42}'
_b13_invalid "sha-uppercase" \
  '{"pr":42,"sha":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}'
_b13_invalid "sha-short" '{"pr":42,"sha":"aaaa"}'
_b13_invalid "sha-nonstring" '{"pr":42,"sha":42}'
_b13_invalid "phases-bool" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":false}"
_b13_invalid "phases-string" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":\"legacy\"}"
_b13_invalid "phases-array" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":[]}"
_b13_invalid "phase2_5-null" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":null}}"
_b13_invalid "phase2_5-string" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":\"current\"}}"
_b13_invalid "phase2_5-array" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":[]}}"
_b13_invalid "halted-number" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":0}}}"
_b13_invalid "halted-string" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":\"false\"}}}"
_b13_invalid "severity-bool" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":false}}}"
_b13_invalid "severity-array" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":[]}}}"
_b13_invalid "blocker-bool" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":false}}}}"
_b13_invalid "blocker-string" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":\"1\"}}}}"
_b13_invalid "blocker-negative" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":-1}}}}"
_b13_invalid "blocker-fraction" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":1.5}}}}"
_b13_invalid "critical-bool" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"critical\":false}}}}"
_b13_invalid "critical-negative" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"critical\":-1}}}}"
_b13_invalid "critical-fraction" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"critical\":1.5}}}}"
_b13_invalid "override-bool" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"override_reason\":false}}}"
_b13_invalid "override-unknown" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"override_reason\":\"operator-said-so\"}}}"
_b13_invalid "duplicate-nested-key" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":false,\"halted\":true}}}"
_b13_invalid "non-finite-number" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"by_severity\":{\"blocker\":NaN}}}}"

# A published snapshot is accepted only while path, digest, identity, and
# regular-file shape all remain bound to the closed receipt.
_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$B12_PAYLOAD_A"
B12_RECEIPT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.snapshot.setup: secure snapshot receipt created"
if printf '%s' "$B12_RECEIPT" | jq -e \
  '.snapshot_path | type == "string" and startswith("/")' >/dev/null 2>&1; then
  (
    . "$LIB"
    recapture_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "0" "B12.snapshot.stable: unchanged snapshot digest-recaptures"
  B12_SNAPSHOT_PATH="$(printf '%s' "$B12_RECEIPT" | jq -r '.snapshot_path')"
  B12_SNAPSHOT_COPY="$B12_SANDBOX/snapshot-copy"
  cp "$B12_SNAPSHOT_PATH" "$B12_SNAPSHOT_COPY"
  chmod 600 "$B12_SNAPSHOT_PATH"
  printf '\n' >> "$B12_SNAPSHOT_PATH"
  (
    . "$LIB"
    recapture_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "2" "B12.snapshot.digest-drift: mutated snapshot → INDETERMINATE=2"
  rm -f "$B12_SNAPSHOT_PATH"
  cp "$B12_SNAPSHOT_COPY" "$B12_SNAPSHOT_PATH"
  chmod 400 "$B12_SNAPSHOT_PATH"
  (
    . "$LIB"
    recapture_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "2" "B12.snapshot.replacement: byte-identical replacement identity → INDETERMINATE=2"
  rm -f "$B12_SNAPSHOT_PATH"
  ln -s "$B12_SNAPSHOT_COPY" "$B12_SNAPSHOT_PATH"
  (
    . "$LIB"
    recapture_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "2" "B12.snapshot.symlink: symlink carrier → INDETERMINATE=2"
  rm -f "$B12_SNAPSHOT_PATH"
  mkdir "$B12_SNAPSHOT_PATH"
  (
    . "$LIB"
    recapture_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "2" "B12.snapshot.nonregular: directory carrier → INDETERMINATE=2"
  rm -rf "$B12_SNAPSHOT_PATH"
  rm -f "$B12_SNAPSHOT_COPY"
  (
    . "$LIB"
    cleanup_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>&1 || true
else
  for B12_DRIFT_CASE in stable digest-drift replacement symlink nonregular; do
    echo "  FAIL  B12.snapshot.$B12_DRIFT_CASE: closed receipt prerequisite missing"
    FAIL=$((FAIL + 1))
  done
fi

rm -f "$B12_ERR"
rm -rf "$B12_SANDBOX"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
