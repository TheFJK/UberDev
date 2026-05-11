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
SOLVE_PIPELINE="$REPO_ROOT/plugins/uberdev/skills/solve-pipeline/SKILL.md"
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
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
