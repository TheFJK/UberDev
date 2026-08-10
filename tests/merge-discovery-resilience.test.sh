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
#   emit_gate_fail            (gate-fail audit-emit helper)
#
# `parse_review_verdict_phase2_5` was RETIRED in #347: the closed-receipt path
# (discover -> recapture -> cleanup) has parsed and validated the phase2_5 tuple
# from the SAME captured bytes since the secure-capture rework, so the standalone
# jq parser had zero production callers. Its A13/B11 coverage went with it —
# testing a function nothing calls only proves the tests still run.
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

# Strict cleanup assertion (#347). Every cleanup call site used to end in
# `>/dev/null 2>&1 || true`, which threw away BOTH the exit code and the stderr.
# A cleanup that silently stopped removing the private carrier would then have
# kept all 15 sites green while leaking one mode-0400 copy of the selected
# verdict per call. Assert the rc AND that the carrier and its private mktemp
# directory are actually gone.
assert_cleanup_removed() {
  local receipt="$1" desc="$2" snapshot_path parent rc err
  if [ -z "$receipt" ]; then
    echo "  FAIL  $desc — no receipt to clean up"
    FAIL=$((FAIL + 1))
    return
  fi
  snapshot_path="$(jq -r '.snapshot_path // empty' <<<"$receipt" 2>/dev/null)"
  err="$(mktemp)"
  ( . "$LIB"; cleanup_review_verdict_snapshot "$receipt" ) >/dev/null 2>"$err"
  rc=$?
  parent="$(dirname "$snapshot_path")"
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL  $desc — cleanup exited $rc: $(head -c 200 "$err" 2>/dev/null)"
    FAIL=$((FAIL + 1))
  elif [ -z "$snapshot_path" ]; then
    echo "  FAIL  $desc — receipt carried no snapshot_path"
    FAIL=$((FAIL + 1))
  elif [ -e "$snapshot_path" ]; then
    echo "  FAIL  $desc — carrier still present: $snapshot_path"
    FAIL=$((FAIL + 1))
  elif [ -e "$parent" ]; then
    echo "  FAIL  $desc — private capture directory still present: $parent"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  fi
  rm -f "$err"
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
# `resolve_pr_base` joined the list in #437: /merge must resolve each PR's OWN
# base ref, and the resolution has to fail closed rather than silently fall
# back to the repo-global integration branch.
for fn in discover_bare_fast_path discover_multi pr_view_projection emit_gate_fail resolve_pr_base; do
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
echo "== A5: lib/discover.sh releases its mktemp stderr file on every return path =="
# THE CLASS (#401). The three public functions used to guard their mktemp
# stderr-capture file with `trap "rm -f \"$gh_err\"" RETURN`. zsh does not
# accept RETURN as a signal, and merge-pipeline/SKILL.md `bash` fences execute
# under /bin/zsh — so in the shell this library actually runs in the trap NEVER
# INSTALLS: the file leaks once per call, `undefined signal: RETURN` goes to
# stderr on every discovery, and under `setopt err_return` / `set -e` the
# function aborts at the trap line before ever calling gh.
#
# The A5b that shipped here asserted the literal string `trap ... RETURN` was
# PRESENT — a guard enforcing the bug. It encoded "cleanup happens" as "this
# one construct appears", read against bash semantics for a file bash does not
# run. It is repointed at the real invariant: every return path releases the
# file, and no trap of any signal survives.
#
# ONE extractor, ONE probe, ONE verdict — five consumers. A second copy of the
# comparator would be the same "one contract, N uncompared copies" drift
# (#370/#371) this fix is about, so A5d exercises the SAME `_a5_verdict` that
# A5b ships, from the other side.

# Extract ONE function body from $LIB, whole-line comments stripped. Anchored on
# the `name() {` opener at column 0 and the matching `}` at column 0 — the shape
# every function in this file uses. Scoped to NAMED functions, never file-wide:
# the unrelated `mktemp -d` secure-capture boundary in the verdict-discovery
# half has its own explicit cleanup and must not be swept into this count.
_a5_body() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)[[:space:]]*\\{[[:space:]]*$" { inb=1; next }
    inb && /^\}[[:space:]]*$/                      { inb=0; next }
    inb                                            { print }
  ' "$LIB" | grep -v '^[[:space:]]*#'
}

# "<lines> <returns> <releases> <returns-not-immediately-preceded-by-a-release>"
_a5_probe() {
  printf '%s\n' "$1" | awk '
    { lines++ }
    /^[[:space:]]*return[[:space:]]/ {
      ret++
      if (prev !~ /^[[:space:]]*rm -f "\$gh_err"[[:space:]]*$/) bad++
    }
    /^[[:space:]]*rm -f "\$gh_err"[[:space:]]*$/ { rel++ }
    { prev = $0 }
    END { printf "%d %d %d %d\n", lines+0, ret+0, rel+0, bad+0 }
  '
}

# rc 0 = clean, rc 1 = violation. An EMPTY body is a violation, not a vacuous
# pass — that is the whole point of A5d's second arm.
_a5_verdict() {
  [ -n "$1" ] || return 1
  local a5_probe a5_ret a5_rel a5_bad
  a5_probe="$(_a5_probe "$1")"
  IFS=' ' read -r _ a5_ret a5_rel a5_bad <<<"$a5_probe"
  [ "$a5_ret" = 3 ] && [ "$a5_rel" = 3 ] && [ "$a5_bad" = 0 ]
}

# Tightened from the bare `mktemp` grep, which stayed green through a template
# change and could not tell the three capture sites apart from any other use.
assert_count_eq "$LIB" 'gh_err="\$\(mktemp\)"' 3 \
  "A5a: three gh_err mktemp stderr-capture sites"

for a5_fn in discover_bare_fast_path discover_multi pr_view_projection; do
  A5_BODY="$(_a5_body "$a5_fn")"
  if [ -n "$A5_BODY" ]; then
    echo "  PASS  A5b.$a5_fn.extracted: function body extracted from lib/discover.sh"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A5b.$a5_fn.extracted: no function body extracted — the extractor is blind"
    FAIL=$((FAIL + 1))
  fi
  if _a5_verdict "$A5_BODY"; then
    echo "  PASS  A5b.$a5_fn: 3 returns, 3 explicit \$gh_err releases, none unguarded"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A5b.$a5_fn: a return path does not release \$gh_err"
    echo "        probe (lines returns releases unguarded-returns): $(_a5_probe "$A5_BODY")"
    FAIL=$((FAIL + 1))
  fi
done

# No trap of ANY signal, not just RETURN. `trap ... EXIT` is not the fix either:
# this library is SOURCED, so an EXIT trap installs on the CALLER's shell and
# the third call would silently replace the first two — and lib/goal-phase3.sh,
# which sources this library, already owns the single process-wide EXIT slot.
assert_no_grep "$LIB" '^[[:space:]]*trap[[:space:]]' \
  "A5c: no trap statement of any signal survives in lib/discover.sh"

# Anti-vacuity, both arms through the SAME verdict A5b uses.
A5_SYNTH="$(cat <<'EOF_A5_SYNTH'
  rm -f "$gh_err"
  return 1
  rm -f "$gh_err"
  return 1
  printf '%s\n' "$result"
  return 0
EOF_A5_SYNTH
)"
if _a5_verdict "$A5_SYNTH"; then
  echo "  FAIL  A5d.i: the verdict accepts a 3-return / 2-release body (vacuous)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  A5d.i: a body whose last return is unguarded is rejected"
  PASS=$((PASS + 1))
fi
A5_MISSING="$(_a5_body __a5_no_such_function__)"
if [ -z "$A5_MISSING" ] && ! _a5_verdict "$A5_MISSING"; then
  echo "  PASS  A5d.ii: an extractor that matches nothing is a violation, not a 0==0 pass"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A5d.ii: an empty body passes the verdict — A5b could go green on a blind extractor"
  FAIL=$((FAIL + 1))
fi

# The one position an inserted statement is FORBIDDEN: between the gh capture
# and `local gh_exit=$?`. Anything in between rewrites gh_exit to that
# statement's status and destroys the audit event's exit_code field.
A5E_COUNT="$(printf '%s\n' "$LIB_NORMALISED" | awk '
  /^[[:space:]]*local gh_exit=\$\?[[:space:]]*$/ && a5prev ~ /^[[:space:]]*result="\$\(gh / { n++ }
  { a5prev = $0 }
  END { print n+0 }
')"
assert_eq "$A5E_COUNT" "3" \
  "A5e: \`local gh_exit=\$?\` still immediately follows each \`result=\"\$(gh …)\"\` capture"

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
echo "== A15: discovery is stack-aware — the --base wire filter is gone (#437) =="
# THE BUG. `gh pr list --base "$integration_branch"` is an EXACT server-side
# match, so a PR stacked on another PR's head returns ZERO candidates and
# /merge exits 0 reporting "nothing to merge" — the false-convergence signal
# /goal consumes. The fix drops --base from the wire query and re-applies the
# integration branch client-side as the ROOT of a transitive reachability set
# (baseRefName == root, OR baseRefName == the headRefName of another
# candidate, applied until fixpoint).
assert_no_grep "$LIB" '^[[:space:]]*--base "\$integration_branch"' \
  "A15a: discover_multi's gh query no longer carries --base (the exact-match filter that hid stacked PRs)"
assert_grep "$LIB" '_uberdev_discover_stack_filter' \
  "A15b: lib/discover.sh defines/uses the client-side stack filter"
# The filter must be transitive, not one-hop: a fixpoint/bounded-iteration
# construct is the anchor a one-hop `select(.baseRefName == $root)` cannot fake.
assert_grep "$LIB" 'reduce range\(0; \(\$prs\|length\)\)' \
  "A15c: the closure iterates to a fixpoint (bounded by candidate count), so a 3-deep stack roots"
# The root still comes from integration_branch — Half 2 changes its ROLE
# (exact filter -> root of the reachability set), it does not retire it.
assert_grep "$LIB" '\-\-arg root "\$integration_branch"' \
  "A15d: integration_branch is still load-bearing, now as the stack ROOT"

echo
echo "== A16: Phase 3 writes target the PR's OWN base, never the global branch (#437) =="
# Every Phase-3 write site used origin/<integration_branch> for a PR whose base
# may be another branch. Both directions were reproduced: a stacked PR probes
# CONFLICT against main while its real base merges clean (phantom conflict ->
# conflict-resolvers dispatched at nothing), and a genuine base-vs-head conflict
# probes CLEAN against main (invisible conflict -> gh pr merge fired at a PR
# that does not merge). B26 executes both.
A16_PHASE3="$(awk '/^## Phase 3/,/^## Phase 4/' "$SKILL")"
for a16_probe in \
  'git merge-tree --write-tree origin/<PR_BASE> <headRefOid>' \
  'git worktree add .claude/worktrees/merge-<run-id> origin/<PR_BASE>' \
  'resolve_pr_base'
do
  if grep -qF -- "$a16_probe" <<<"$A16_PHASE3"; then
    echo "  PASS  A16: Phase 3 cites '$a16_probe'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A16: Phase 3 must cite '$a16_probe' (#437 per-PR base awareness)"
    FAIL=$((FAIL + 1))
  fi
done
# The #303 invariant must survive the retarget: still `origin/`-qualified,
# never the bare local ref — for EITHER placeholder.
for a16_bare in \
  'merge-tree --write-tree <PR_BASE>' \
  'merge-tree --write-tree <integration_branch>' \
  'git worktree add .claude/worktrees/merge-<run-id> <PR_BASE>' \
  'git worktree add .claude/worktrees/merge-<run-id> <integration_branch>'
do
  if grep -qF -- "$a16_bare" <<<"$A16_PHASE3"; then
    echo "  FAIL  A16.bare: Phase 3 must NOT use the bare local ref '$a16_bare' (#303 invariant survives #437)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  A16.bare: no Phase-3 '$a16_bare' (bare local ref) remains"
    PASS=$((PASS + 1))
  fi
done
assert_grep "$SKILL" 'pr_base_unresolvable' \
  "A16.reason: SKILL.md registers the typed gate_fail reason 'pr_base_unresolvable'"

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
if grep -qE '\[ [^][]*\\>' <<<"$LIB_NORMALISED"; then
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
assert_cleanup_removed "$B8_OUT" "B8a.cleanup: private carrier and capture directory removed"
B8_OUT="$(_b8_call 99)"
B8_RC=$?
assert_eq "$(printf '%s' "$B8_OUT" | jq -r '.artifact_sha // empty')" \
  "$B8_SHA_99" \
  "B8b: PR 99 → .worktrees/ hidden-convention layout found"
assert_eq "$B8_RC" "0" "B8b.rc: PR 99 match → FOUND=0"
assert_cleanup_removed "$B8_OUT" "B8b.cleanup: private carrier and capture directory removed"
B8_OUT="$(_b8_call 77)"
B8_RC=$?
assert_eq "$(printf '%s' "$B8_OUT" | jq -r '.artifact_sha // empty')" \
  "$B8_SHA_77" \
  "B8c: PR 77 → worktrees/ visible-convention layout found"
assert_eq "$B8_RC" "0" "B8c.rc: PR 77 match → FOUND=0"
assert_cleanup_removed "$B8_OUT" "B8c.cleanup: private carrier and capture directory removed"
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
  assert_cleanup_removed "$B9_OUT" "B9c.cleanup: zsh-produced receipt cleans up completely"
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
  assert_cleanup_removed "$1" "${2:-B10.cleanup}: private carrier and capture directory removed"
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
_b10_cleanup_receipt "$B10_OUT" "B10d.3"

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
_b10_cleanup_receipt "$B10_OUT" "B10fother.3"

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
# The scan is in-process since issue #346, so an unreadable directory replaces
# the old shadowed-`find` stub as the deterministic failure injection.
mkdir -p "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa"
chmod 000 "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa" 2>/dev/null || true
if ls "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa" >/dev/null 2>&1; then
  # Windows/Git Bash chmod is a no-op, and root ignores the mode bits.
  echo "  SKIP  B10h: cannot make a directory unreadable on this platform/user"
  chmod 755 "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa" 2>/dev/null || true
else
  B10_OUT="$(
    cd "$B10_SANDBOX" &&
    . "$LIB" &&
    discover_review_verdict_json 42
  )" 2>"$B10_ERR"
  B10_RC=$?
  chmod 755 "$B10_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa" 2>/dev/null || true
  assert_eq "$B10_OUT" "" "B10h.1: failed root scan emits no path"
  assert_eq "$B10_RC" "2" "B10h.2: failed root scan → INDETERMINATE=2"
fi

rm -f "$B10_ERR"
rm -rf "$B10_SANDBOX"

echo
echo "== A14/B12: closed verdict receipt + secure snapshot contract =="
assert_grep "$LIB" '^review_verdict_discovery_state\(\)[[:space:]]*\{' \
  "A14a: executable discovery rc-to-state helper is defined"
# The scan is a bounded in-process walk, not `find` (issue #346: native-Windows
# Python resolves a bare "find" to System32\find.exe). These pin the same three
# invariants the find argv used to carry.
assert_grep "$LIB" '^def scan_root_layout\(root_name, exact_depth, exact_path\):' \
  "A14b: command-line roots are traversed by the bounded in-process walk"
assert_grep "$LIB" 'follow_symlinks=False' \
  "A14c: descendant symlinks are never followed during descent"
assert_no_grep "$LIB" 'follow_symlinks=True' \
  "A14c.0: no descent path opts back into following symlinks"
assert_grep "$LIB" 'if depth == exact_depth:' \
  "A14c.1: the walk emits only at the pinned exact depth"
assert_grep "$LIB" 'fnmatch\.fnmatchcase\(posix, exact_path\)' \
  "A14c.1b: candidates must match the exact slash-path glob before being emitted"
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

# A CURRENT artifact is one that can name both endpoints of what it reviewed, so
# post-#440 the `base` member is part of the baseline payload. The base-absent
# and base-malformed shapes get their own explicit rows in B13.
B12_BASE_SHA="dddddddddddddddddddddddddddddddddddddddd"

_b12_payload() {
  local pr="$1" sha="$2" blocker="${3:-0}" critical="${4:-0}"
  printf '{"pr":%s,"sha":"%s","base":{"sha":"%s","ref":"main"},"phases":{"phase2_5":{"halted":false,"by_severity":{"blocker":%s,"critical":%s},"override_reason":null}}}\n' \
    "$pr" "$sha" "$B12_BASE_SHA" "$blocker" "$critical"
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
# Behavioural replacement for the old fake-`find` argv log (issue #346 removed
# the subprocess). Asserting argv proved only that the right flags were passed;
# these prove the property the flags existed for -- an artifact one level too
# shallow or too deep is invisible, and only the pinned depth is emitted.
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_OUT" "" "B12.walk.out: bounded empty scans emit no receipt"
assert_eq "$B12_RC" "1" "B12.walk.rc: bounded empty scans prove absence"

B12_SHA40="$(printf 'a%.0s' $(seq 40))"
# Too shallow: directly under the root, i.e. depth 1 where the layout pins 2.
printf '{"pr":42,"sha":"%s"}\n' "$B12_SHA40" >"$B12_SANDBOX/.uberdev/runs/review-pr-verdict.json"
# Too deep: one extra directory level below the pinned depth.
mkdir -p "$B12_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa/nested"
printf '{"pr":42,"sha":"%s"}\n' "$B12_SHA40" \
  >"$B12_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa/nested/review-pr-verdict.json"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_RC" "1" "B12.walk.depth: artifacts above and below the pinned depth are invisible"
# Now place one at the exact pinned depth; it must become discoverable.
printf '{"pr":42,"sha":"%s"}\n' "$B12_SHA40" \
  >"$B12_SANDBOX/.uberdev/runs/20260101-000000-aaaaaaaa/review-pr-verdict.json"
B12_OUT="$(
  cd "$B12_SANDBOX" &&
  . "$LIB" &&
  discover_review_verdict_json 42
)" 2>"$B12_ERR"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.walk.depth-exact: an artifact at the pinned depth is discovered"

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
assert_cleanup_removed "$B12_OUT" "B12.find.depth2.cleanup: private carrier and capture directory removed"

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
assert_cleanup_removed "$B12_OUT" "B12.find.depth5.cleanup: private carrier and capture directory removed"

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
assert_cleanup_removed "$B12_OUT" "B12.root.symlink.cleanup: private carrier and capture directory removed"

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
assert_cleanup_removed "$B12_OUT" "B12.root.external.cleanup: private carrier and capture directory removed"
rm -rf "$B12_EXTERNAL_ROOT"

# Retargeting an allowed command-line symlink while find is running invalidates
# the scan even when find itself exits zero and returns no candidate.
_b12_clear
B12_RETARGET_A="$(mktemp -d)"
B12_RETARGET_B="$(mktemp -d)"
ln -s "$B12_RETARGET_A" "$B12_SANDBOX/.worktrees"
# This case used the external `find` as a mid-scan timing hook to retarget the
# root symlink. Issue #346 removed the subprocess, so no shell-reachable hook
# exists inside the walk. Pin the checks the hook used to prove instead: the
# root identity is snapshotted before the scan, re-verified immediately after,
# and re-verified again across all roots once every capture completes.
assert_grep "$LIB" 'lexical_before = raw_identity\(root_lexical_entry\)' \
  "B12.root.retarget.snapshot: root identity is snapshotted before the scan"
assert_grep "$LIB" 'raise VerdictError\(f"root identity drifted: \{root_name\}"\)' \
  "B12.root.retarget.rc: root identity drift is INDETERMINATE, never absence"
assert_grep "$LIB" '^def verify_bound_roots\(bound_roots\):' \
  "B12.root.retarget.reverify: every bound root is re-verified after capture"
rm -rf "$B12_RETARGET_A" "$B12_RETARGET_B"

# A find result whose relative suffix attempts lexical traversal is
# indeterminate, even when the command itself exits successfully.
_b12_clear
mkdir -p "$B12_SANDBOX/.worktrees"
# This case injected a traversal-shaped path through the external `find`.
# Since issue #346 the walk composes candidate paths itself from scandir names,
# so a traversal suffix is unreachable by construction rather than merely
# rejected. validate_suffix remains as defence in depth; what is tested here is
# the property that makes traversal impossible -- descent never follows a link.
B12_ESCAPE_TARGET="$(mktemp -d)"
mkdir -p "$B12_ESCAPE_TARGET/.uberdev/runs/20260101-010101-a1"
printf '{"pr":42,"sha":"%s"}\n' "$(printf 'a%.0s' $(seq 40))" \
  >"$B12_ESCAPE_TARGET/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
ln -s "$B12_ESCAPE_TARGET" "$B12_SANDBOX/.worktrees/escape" 2>/dev/null || true
if [ ! -L "$B12_SANDBOX/.worktrees/escape" ]; then
  echo "  SKIP  B12.root.traversal: ln -s did not produce a symlink on this platform"
else
  B12_OUT="$(
    cd "$B12_SANDBOX" &&
    . "$LIB" &&
    discover_review_verdict_json 42
  )" 2>"$B12_ERR"
  B12_RC=$?
  assert_eq "$B12_OUT" "" "B12.root.traversal.out: a linked descendant emits no receipt"
  assert_eq "$B12_RC" "1" "B12.root.traversal.rc: descent never follows a link out of the root"
fi
assert_grep "$LIB" 'find result escaped or violated the root layout' \
  "B12.root.traversal.guard: the lexical-escape guard is retained as defence in depth"
rm -rf "$B12_ESCAPE_TARGET"

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
assert_cleanup_removed "$B12_OUT" "B12.tie.identical.cleanup: private carrier and capture directory removed"

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-ffff/review-pr-verdict.json" "$B12_PAYLOAD_A"
_b12_write ".worktrees/w/.uberdev/runs/20260101-010102-0000/review-pr-verdict.json" "$B12_PAYLOAD_B"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "0" "B12.rank.seconds.rc: distinct-second ordering remains chronological"
_b12_assert_receipt "$B12_OUT" "$B12_SHA_B" \
  "B12.rank.seconds.receipt: later timestamp wins regardless of suffix ordering"
assert_cleanup_removed "$B12_OUT" "B12.rank.seconds.cleanup: private carrier and capture directory removed"

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
assert_cleanup_removed "$B12_OUT" "B12.unknown.older.cleanup: private carrier and capture directory removed"

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
    assert_cleanup_removed "$receipt" "B13.valid.$label.cleanup: private carrier and capture directory removed"
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
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\",\"ref\":\"main\"},\"phases\":{\"phase2_5\":{}}}" \
  current false 0 0 null
_b13_valid "nullable-defaults" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\",\"ref\":\"main\"},\"phases\":{\"phase2_5\":{\"halted\":null,\"by_severity\":null,\"override_reason\":null}}}" \
  current false 0 0 null
_b13_valid "typed-values" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\",\"ref\":\"main\"},\"phases\":{\"phase2_5\":{\"halted\":true,\"by_severity\":{\"blocker\":2,\"critical\":3},\"override_reason\":\"user-selected-emit-green-on-blocker-deferred\"}}}" \
  current true 2 3 user-selected-emit-green-on-blocker-deferred

# #440 — base identity is the second endpoint of the reviewed delta. An artifact
# that omits it is pre-#440 telemetry and degrades to the EXISTING `legacy`
# state, no matter how modern its phase2_5 block: recording no base is not
# evidence that the base is unchanged. Minting a new audit-state token instead
# would red lib/goal-state.sh and goal-verdict-receipt.test.sh, which both pin
# the vocabulary to legacy|current.
_b13_valid "base-missing-degrades-to-legacy" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"phases\":{\"phase2_5\":{\"halted\":true,\"by_severity\":{\"blocker\":2,\"critical\":3}}}}" \
  legacy false 0 0 null
_b13_valid "base-null-degrades-to-legacy" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":null,\"phases\":{\"phase2_5\":{}}}" \
  legacy false 0 0 null

_b13_invalid "top-level-array" '[]'
_b13_invalid "base-not-object" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":\"main\"}"
_b13_invalid "base-array" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":[]}"
_b13_invalid "base-sha-missing" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"ref\":\"main\"}}"
_b13_invalid "base-sha-short" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"aaaa\",\"ref\":\"main\"}}"
_b13_invalid "base-sha-uppercase" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"ref\":\"main\"}}"
_b13_invalid "base-ref-missing" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\"}}"
_b13_invalid "base-ref-empty" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\",\"ref\":\"\"}}"
_b13_invalid "base-ref-nonstring" \
  "{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"base\":{\"sha\":\"$B12_BASE_SHA\",\"ref\":7}}"
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
  # The carrier was deliberately destroyed above, so cleanup cannot prove the
  # identity it is asked to remove. It MUST fail closed (2), never report a
  # successful removal of something it never re-bound.
  (
    . "$LIB"
    cleanup_review_verdict_snapshot "$B12_RECEIPT"
  ) >/dev/null 2>"$B12_ERR"
  assert_eq "$?" "2" "B12.snapshot.cleanup-destroyed: cleanup of a destroyed carrier is INDETERMINATE=2"
  B12_ORPHAN_DIR="$(dirname "$B12_SNAPSHOT_PATH")"
  case "${B12_ORPHAN_DIR##*/}" in
    uberdev-review-verdict.*) rm -rf "$B12_ORPHAN_DIR" ;;
  esac
else
  for B12_DRIFT_CASE in stable digest-drift replacement symlink nonregular; do
    echo "  FAIL  B12.snapshot.$B12_DRIFT_CASE: closed receipt prerequisite missing"
    FAIL=$((FAIL + 1))
  done
fi

rm -f "$B12_ERR"
rm -rf "$B12_SANDBOX"

echo
echo "== B15: an unloadable secure runtime is INDETERMINATE, never proven absence =="
# Regression for the fail-open funnel: the selector maps interpreter rc 1 to
# "exhaustive ABSENT", but 1 is also CPython's code for any unhandled exception.
# With the module load unguarded, a missing/partial run_manifest.py exited 1 and
# /merge read ABSENT as gate_pass -- landing a PR whose verdict it never read.
B15_ROOT="$(mktemp -d)"
mkdir -p "$B15_ROOT/skills/merge-pipeline/lib" "$B15_ROOT/lib" "$B15_ROOT/work"
cp "$LIB" "$B15_ROOT/skills/merge-pipeline/lib/discover.sh"
# NOTE: $B15_ROOT/lib/run_manifest.py is deliberately absent.
(
  cd "$B15_ROOT/work" && git init -q .
  . "$B15_ROOT/skills/merge-pipeline/lib/discover.sh"
  discover_review_verdict_json 340
) >/dev/null 2>&1
assert_eq "$?" "2" "B15.runtime-missing: unloadable artifact runtime → INDETERMINATE=2 (never ABSENT=1)"
(
  cd "$B15_ROOT/work" && . "$B15_ROOT/skills/merge-pipeline/lib/discover.sh"
  review_verdict_discovery_state 2
) >"$B15_ROOT/state" 2>/dev/null
assert_eq "$(cat "$B15_ROOT/state")" "indeterminate" "B15.state: rc 2 maps to indeterminate"
rm -rf "$B15_ROOT"

echo
echo "== B16: the selector receipt carries phase2_5_halted_due_to_overflow =="
# Regression for the dead /goal blocker-overflow gate: the field was absent from
# the receipt entirely, so overflow_detected could never reach 1 and the Phase 3
# truncation was unreachable code.
B16_ROOT="$(mktemp -d)"
mkdir -p "$B16_ROOT/.uberdev/runs/20260730-101112-abcdef01"
B16_SHA="$(printf 'a%.0s' $(seq 40))"
printf '{"pr":340,"sha":"%s","base":{"sha":"%s","ref":"main"},"phases":{"phase2_5":{"halted":false,"halted_due_to_overflow":true,"by_severity":{"blocker":0,"critical":0}}}}\n' \
  "$B16_SHA" "$B12_BASE_SHA" >"$B16_ROOT/.uberdev/runs/20260730-101112-abcdef01/review-pr-verdict.json"
B16_RECEIPT="$( cd "$B16_ROOT" && git init -q . 2>/dev/null; cd "$B16_ROOT" && . "$LIB" && discover_review_verdict_json 340 2>/dev/null )"
B16_RC=$?
assert_eq "$B16_RC" "0" "B16.found: verdict carrying halted_due_to_overflow is discoverable"
assert_eq "$(printf '%s' "$B16_RECEIPT" | jq -r '.phase2_5_halted_due_to_overflow')" "true" \
  "B16.overflow-true: receipt carries phase2_5_halted_due_to_overflow=true"
# A verdict without the field must default to false, not null/absent.
printf '{"pr":341,"sha":"%s","base":{"sha":"%s","ref":"main"},"phases":{"phase2_5":{"halted":false,"by_severity":{"blocker":0,"critical":0}}}}\n' \
  "$B16_SHA" "$B12_BASE_SHA" >"$B16_ROOT/.uberdev/runs/20260730-101112-abcdef01/review-pr-verdict.json"
B16_RECEIPT2="$( cd "$B16_ROOT" && . "$LIB" && discover_review_verdict_json 341 2>/dev/null )"
assert_eq "$(printf '%s' "$B16_RECEIPT2" | jq -r '.phase2_5_halted_due_to_overflow')" "false" \
  "B16.overflow-default: absent halted_due_to_overflow defaults to false"
rm -rf "$B16_ROOT"

echo
echo "== B17: derived root-layout pins (#342) =="
# ROOT_LAYOUTS used to restate one segment count THREE ways — expected_shape,
# exact_depth, exact_path — with nothing proving the three agreed. A silent
# disagreement produced zero candidates, and zero candidates funnels through
# `raise SystemExit(1)` = exhaustive ABSENT = /merge gate_pass. The pins are now
# derived from expected_shape and asserted against a documented table.
assert_grep "$LIB" '^ROOT_LAYOUTS = \($' \
  "B17.table: ROOT_LAYOUTS is still the single root enumeration"
assert_grep "$LIB" '^EXPECTED_ROOT_LAYOUT_PINS = \{$' \
  "B17.expected: a documented pin table exists to assert the derivation against"
assert_grep "$LIB" '^ROOT_LAYOUT_PINS = derive_root_layout_pins\(\)$' \
  "B17.derive: the live pins are derived, never hand-written"
assert_no_grep "$LIB" '^[[:space:]]*assert .*ROOT_LAYOUT' \
  "B17.no-bare-assert: a bare module-scope assert would exit 1 = proven ABSENT (the funnel reserves 1)"
# The derivation must fail through fail() -> SystemExit(2), never through an
# uncaught error that the shell maps to exhaustive absence.
B17_ROOT="$(mktemp -d)"
mkdir -p "$B17_ROOT/lib" "$B17_ROOT/skills/merge-pipeline/lib" "$B17_ROOT/work"
cp "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" "$B17_ROOT/lib/run_manifest.py"
sed 's|^EXPECTED_ROOT_LAYOUT_PINS = {$|EXPECTED_ROOT_LAYOUT_PINS = {\
    "drifted/root": (99, "drifted/root/*"),|' \
  "$LIB" > "$B17_ROOT/skills/merge-pipeline/lib/discover.sh"
if grep -q 'drifted/root' "$B17_ROOT/skills/merge-pipeline/lib/discover.sh"; then
  (
    cd "$B17_ROOT/work" &&
    . "$B17_ROOT/skills/merge-pipeline/lib/discover.sh" &&
    discover_review_verdict_json 42
  ) >/dev/null 2>"$B17_ROOT/err"
  assert_eq "$?" "2" "B17.drift-rc: a pin-contract disagreement is INDETERMINATE=2, never ABSENT=1"
  assert_grep "$B17_ROOT/err" 'indeterminate: derived root layout pins disagree' \
    "B17.drift-msg: the disagreement names itself on stderr"
else
  echo "  FAIL  B17.drift-rc: could not build the pin-drift fixture"
  echo "  FAIL  B17.drift-msg: could not build the pin-drift fixture"
  FAIL=$((FAIL + 2))
fi
rm -rf "$B17_ROOT"

echo
echo "== B18: hostile nodes at the verdict path (#347) =="
# A FIFO or a directory at the pinned candidate path must never be captured as
# an artifact, and must never be reported as proven absence either: the walk
# emits any node type at the pinned depth by design, and regularity is enforced
# during secure capture.
_b12_clear
mkdir -p "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1"
if mkfifo "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json" 2>/dev/null; then
  B12_OUT="$(_b12_capture 42)"
  B12_RC=$?
  assert_eq "$B12_OUT" "" "B18.fifo.out: a FIFO candidate emits no receipt"
  assert_eq "$B12_RC" "2" "B18.fifo.rc: an uncapturable candidate is INDETERMINATE=2, never ABSENT=1"
  rm -f "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
else
  echo "  SKIP  B18.fifo: mkfifo unavailable on this platform"
fi

_b12_clear
mkdir -p "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B18.dir.out: a directory at the candidate path emits no receipt"
assert_eq "$B12_RC" "2" "B18.dir.rc: a directory candidate is INDETERMINATE=2, never ABSENT=1"
_b12_clear

echo
echo "== B19: MAXIMUM_SIZE boundary is exactly 1 MiB inclusive (#347) =="
assert_grep "$LIB" '^MAXIMUM_SIZE = 1024 \* 1024$' \
  "B19.constant: MAXIMUM_SIZE is 1 MiB"
_b19_sized_payload() {
  # Emit valid verdict JSON padded to exactly $1 bytes. python3 is already a hard
  # dependency of the selector, and `head -c /dev/zero | tr` is not portable
  # enough to trust for an exact-byte boundary fixture.
  local target="$1" head_json tail_json filler_len
  head_json="{\"pr\":42,\"sha\":\"$B12_SHA_A\",\"pad\":\""
  tail_json='"}'
  filler_len=$(( target - ${#head_json} - ${#tail_json} ))
  [ "$filler_len" -ge 0 ] || return 1
  printf '%s' "$head_json"
  python3 -c 'import sys; sys.stdout.write("x" * int(sys.argv[1]))' "$filler_len"
  printf '%s' "$tail_json"
}
_b19_boundary_case() {
  local size="$1" expect_rc="$2" label="$3" actual_size
  _b12_clear
  mkdir -p "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1"
  _b19_sized_payload "$size" \
    > "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json"
  actual_size="$(wc -c < "$B12_SANDBOX/.uberdev/runs/20260101-010101-a1/review-pr-verdict.json" | tr -d ' ')"
  assert_eq "$actual_size" "$size" "B19.$label.fixture: payload is exactly $size bytes"
  B12_OUT="$(_b12_capture 42)"
  B12_RC=$?
  assert_eq "$B12_RC" "$expect_rc" \
    "B19.$label.rc: a $size-byte candidate returns rc $expect_rc"
  if [ "$expect_rc" = "0" ]; then
    assert_cleanup_removed "$B12_OUT" "B19.$label.cleanup: boundary-sized carrier is removed"
  else
    assert_eq "$B12_OUT" "" "B19.$label.out: an oversized candidate emits no receipt"
  fi
}
_b19_boundary_case 1048576 0 accepted
_b19_boundary_case 1048577 2 rejected
_b12_clear

echo
echo "== B20: divergent duplicate JSON keys are rejected (#347) =="
# `{"pr":42,"pr":99}` is accepted by a naive json.loads (last key wins) and would
# let one artifact claim two PR identities. object_pairs_hook must reject it.
_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
  "{\"pr\":42,\"pr\":99,\"sha\":\"$B12_SHA_A\"}"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B20.divergent.out: a divergent duplicate key emits no receipt"
assert_eq "$B12_RC" "2" "B20.divergent.rc: a divergent duplicate key is INDETERMINATE=2"
# ... and the same shape with identical values is still rejected — the guard is
# structural (duplicate key), not value-comparing.
_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
  "{\"pr\":42,\"pr\":42,\"sha\":\"$B12_SHA_A\"}"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "2" "B20.identical.rc: even an identical duplicate key is rejected structurally"
_b12_clear

echo
echo "== B21: one broken root never hides another root's failure (#348) =="
# scan_root_layout used to abort the whole enumeration on the first OSError, so a
# stale worktree with a mode-000 subdirectory under .worktrees stopped every
# other root from even being scanned. Errors now accumulate, the scan continues,
# and ONE fail-closed error names every failing root plus its errno.
assert_grep "$LIB" '^def describe_scan_failures\(failures\):$' \
  "B21.renderer: a single accumulated-failure renderer exists"
assert_grep "$LIB" '^[[:space:]]*scan_matches, scan_errors = scan_results$' \
  "B21.accumulate: scan_root_layout returns matches AND accumulated errors"

_b12_clear
: > "$B12_SANDBOX/.worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_OUT" "" "B21.regular-root.out: a root that is a regular file emits no receipt"
assert_eq "$B12_RC" "2" "B21.regular-root.rc: a root that is a regular file is INDETERMINATE=2"
assert_grep "$B12_ERR" 'root is not a directory: \.worktrees' \
  "B21.regular-root.err: the failing root is named"
rm -f "$B12_SANDBOX/.worktrees"

# Two independently broken roots must BOTH be named — proof the scan did not
# abort at the first one.
_b12_clear
: > "$B12_SANDBOX/.worktrees"
: > "$B12_SANDBOX/worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "2" "B21.two-roots.rc: two broken roots stay fail-closed"
assert_grep "$B12_ERR" 'root is not a directory: \.worktrees' \
  "B21.two-roots.err-hidden: the hidden-convention root is named"
assert_grep "$B12_ERR" 'root is not a directory: worktrees' \
  "B21.two-roots.err-visible: the visible-convention root is ALSO named (no first-error abort)"
rm -f "$B12_SANDBOX/.worktrees" "$B12_SANDBOX/worktrees"

# An unreadable subtree under one root reports that root with its errno.
_b12_clear
mkdir -p "$B12_SANDBOX/.worktrees/w/.uberdev/runs/20260101-010101-a1"
chmod 000 "$B12_SANDBOX/.worktrees/w/.uberdev/runs" 2>/dev/null || true
if ls "$B12_SANDBOX/.worktrees/w/.uberdev/runs" >/dev/null 2>&1; then
  chmod 755 "$B12_SANDBOX/.worktrees/w/.uberdev/runs" 2>/dev/null || true
  echo "  SKIP  B21.errno: cannot make a directory unreadable on this platform/user"
else
  B12_OUT="$(_b12_capture 42)"
  B12_RC=$?
  chmod 755 "$B12_SANDBOX/.worktrees/w/.uberdev/runs" 2>/dev/null || true
  assert_eq "$B12_RC" "2" "B21.errno.rc: an unreadable subtree stays fail-closed"
  assert_grep "$B12_ERR" 'root scan failed: \.worktrees \(errno [0-9]' \
    "B21.errno.err: the failure names the root AND its errno"
fi
chmod -R u+rwX "$B12_SANDBOX/.worktrees" 2>/dev/null || true
_b12_clear

# Accumulation is a DIAGNOSTIC improvement, deliberately not an outcome change:
# a perfectly good verdict under the canonical root does NOT rescue a run whose
# sibling root could not be read. That is not under-delivery, it is the only
# sound model — selection ranks by timestamp and `discover` already calls a
# newer/tied UNKNOWN artifact indeterminate, so an unreadable root (the same
# epistemic state with less information) could be hiding a newer verdict for
# this very PR. Honouring the readable roots would let one chmod-000 stale
# worktree silently land a superseded verdict. Pinned so a future "partial
# success" refactor has to argue with a red test.
_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" \
  "$(_b12_payload 42 "$B12_SHA_A")"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
_b12_assert_receipt "$B12_OUT" "$B12_SHA_A" \
  "B21.canonical-alone: the canonical root alone resolves to a FOUND receipt"
assert_eq "$B12_RC" "0" "B21.canonical-alone.rc: canonical-only discovery is FOUND=0"
: > "$B12_SANDBOX/.worktrees"
B12_OUT="$(_b12_capture 42)"
B12_RC=$?
assert_eq "$B12_RC" "2" \
  "B21.canonical-plus-broken.rc: a broken sibling root makes an otherwise-good canonical verdict INDETERMINATE=2 (fail-closed, not partial success)"
assert_eq "$B12_OUT" "" \
  "B21.canonical-plus-broken.out: no receipt is emitted from the readable roots"
assert_grep "$B12_ERR" 'root is not a directory: \.worktrees' \
  "B21.canonical-plus-broken.err: the unreadable root is still named"
rm -f "$B12_SANDBOX/.worktrees"
_b12_clear

echo
echo "== B22: the private capture directory never leaks (#344) =="
# secure_publish_captured deliberately never unlinks its attempt file, so the
# capture directory is NOT empty once publication ran. The old shell-side
# `rmdir "$capture_dir" 2>/dev/null || true` therefore ALWAYS failed, silently,
# leaking a mode-0400 copy of the selected verdict on every non-clean exit.
assert_grep "$REPO_ROOT/plugins/uberdev/lib/run_manifest.py" \
  '^def secure_remove_private_capture_dir\(path: str, prefix: str\) -> None:$' \
  "B22.helper: run_manifest exposes the prefix-guarded capture-dir remover"
assert_no_grep "$LIB" 'rmdir "\$capture_dir"' \
  "B22.no-swallow: the swallowing rmdir is gone"
assert_grep "$LIB" 'warning: leaked private verdict capture directory' \
  "B22.breadcrumb: a residual directory is named on stderr, not swallowed"
assert_grep "$LIB" '^            discard_private_capture_dir\(capture_dir\)$' \
  "B22.python-owns: the creating interpreter removes the directory on every failure path"

# The prefix is BOTH the mktemp template and the basename guard that bounds the
# failure-path `rm -rf` — restating it per consumer (mktemp template, shell case
# guard, Python CAPTURE_DIR_PREFIX) let a drifted copy disarm one guard while
# every site still read as correct. One binding, transported; the literal must
# appear exactly once in the whole library.
B22_PREFIX_LITERALS="$(grep -c 'uberdev-review-verdict\.' "$LIB" | tr -d ' ')"
assert_eq "$B22_PREFIX_LITERALS" "1" \
  "B22.prefix-ssot: the capture-dir prefix literal appears exactly once in lib/discover.sh"
assert_grep "$LIB" '^UBERDEV_VERDICT_CAPTURE_PREFIX="uberdev-review-verdict\."$' \
  "B22.prefix-binding: the single binding is a shell constant"
assert_grep "$LIB" 'CAPTURE_DIR_PREFIX = os\.environ\.get\("UBERDEV_VERDICT_CAPTURE_PREFIX", ""\)' \
  "B22.prefix-transported: the Python side reads the binding instead of re-typing it"
# An empty transport is INDETERMINATE on both sides, never a permissive default:
# the Python `startswith` guards would match every path and the shell `case`
# pattern would collapse to `*`.
(
  cd "$B12_SANDBOX" || exit 2
  . "$LIB"
  UBERDEV_VERDICT_CAPTURE_PREFIX=""
  discover_review_verdict_json 42
) >/dev/null 2>"$B12_ERR"
assert_eq "$?" "2" "B22.prefix-empty.rc: an empty prefix binding is INDETERMINATE=2"
assert_grep "$B12_ERR" 'capture-directory prefix binding is missing' \
  "B22.prefix-empty.err: the missing binding is named, not silently defaulted"

# Point TMPDIR at a private directory so the leak assertion is exact and cannot
# be perturbed by anything else on the runner.
B22_TMP="$(mktemp -d)"
_b22_leak_check() {
  local label="$1" pr="$2" expected_rc="$3" out rc residue
  rm -rf "$B22_TMP"
  mkdir -p "$B22_TMP"
  out="$(
    cd "$B12_SANDBOX" || exit 2
    TMPDIR="$B22_TMP"
    export TMPDIR
    . "$LIB"
    discover_review_verdict_json "$pr"
  )" 2>"$B12_ERR"
  rc=$?
  assert_eq "$rc" "$expected_rc" "B22.$label.rc: exit code is $expected_rc"
  if [ "$rc" -eq 0 ]; then
    assert_cleanup_removed "$out" "B22.$label.cleanup: successful discovery cleans up"
  fi
  residue="$(ls -A "$B22_TMP" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$residue" "0" "B22.$label.no-leak: private TMPDIR is empty afterwards"
}

_b12_clear
_b22_leak_check "absent" 42 1

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" '{"pr":'
_b22_leak_check "malformed" 42 2

_b12_clear
: > "$B12_SANDBOX/.worktrees"
_b22_leak_check "broken-root" 42 2
rm -f "$B12_SANDBOX/.worktrees"

_b12_clear
_b12_write ".uberdev/runs/20260101-010101-a1/review-pr-verdict.json" "$(_b12_payload 42 "$B12_SHA_A")"
_b22_leak_check "found" 42 0

# The load-bearing case the old `rmdir` could never handle: a capture directory
# that is NOT empty when discovery fails. Seed a stale attempt file (exactly what
# secure_publish_captured leaves behind and never unlinks) and prove the creating
# interpreter still removes the whole directory.
_b12_clear
B22_SEEDED="$(mktemp -d "$B22_TMP/uberdev-review-verdict.XXXXXX")"
printf 'stale carrier bytes\n' > "$B22_SEEDED/review-pr-verdict.json.attempt-deadbeef-cafe"
chmod 0400 "$B22_SEEDED/review-pr-verdict.json.attempt-deadbeef-cafe"
(
  cd "$B12_SANDBOX" || exit 2
  . "$LIB"
  _uberdev_review_verdict_python discover 42 "$B22_SEEDED"
) >/dev/null 2>"$B12_ERR"
assert_eq "$?" "1" "B22.nonempty.rc: a seeded non-empty capture dir still reports ABSENT=1"
if [ -e "$B22_SEEDED" ]; then
  echo "  FAIL  B22.nonempty.removed: a NON-EMPTY capture directory leaked: $B22_SEEDED"
  FAIL=$((FAIL + 1))
  rm -rf "$B22_SEEDED"
else
  echo "  PASS  B22.nonempty.removed: a non-empty capture directory is removed by its creating interpreter"
  PASS=$((PASS + 1))
fi
rm -rf "$B22_TMP"
_b12_clear

echo
echo "== B23: the three gh_err functions run clean under zsh (the shell SKILL fences use) (#401) =="
# WHY A RUN AND NOT ANOTHER GREP. Every prior instance of this class — `type -t`,
# `${BASH_REMATCH[…]}`, `mapfile`, zsh tied parameters — was found by RUNNING
# under zsh; a shape-grep is blind to it by construction. Layer B's
# `_run_lib_call` sources the library in a subshell of the BASH test process,
# and this file's one existing zsh row (B9) drives discover_review_verdict_json.
# The three gh_err functions had never been executed under zsh anywhere in the
# suite — which is exactly how a `trap … RETURN` that zsh rejects outright
# shipped, survived a full Layer A + Layer B suite, and was found by a human
# running /merge.
#
# HARD-FAIL, never SKIP, when zsh is missing: this is the only row that proves
# the fix in the shell production actually uses. This file runs on the ubuntu
# shape-check job only (it is in test.yml's windows skip-list), that job installs
# zsh, and macOS ships it — so an absent zsh is a broken runner, not a platform
# to tolerate quietly.
if ! command -v zsh >/dev/null 2>&1; then
  echo "  FAIL  B23.pre: zsh not on PATH — the only row proving the #401 fix in the production shell must never SKIP"
  FAIL=$((FAIL + 1))
else
  B23_SANDBOX="$(mktemp -d)"
  B23_LEAKDIR="$B23_SANDBOX/leak"
  B23_BIN="$B23_SANDBOX/bin"
  B23_AUDIT="$B23_SANDBOX/audit.jsonl"
  B23_REAL_MKTEMP="$(command -v mktemp)"
  mkdir -p "$B23_LEAKDIR" "$B23_BIN"
  # A `mktemp` shim — the same technique this file already uses for `gh`. It
  # relocates ONLY the no-argument form (the one lib/discover.sh calls) into a
  # private directory, so "did the function release its capture file?" is an
  # ABSOLUTE emptiness check instead of a before/after delta over the shared
  # temp dir. The delta form races with every other process on the box, and it
  # cannot be sandboxed away on macOS: mktemp there reads the Darwin user temp
  # dir from confstr and ignores TMPDIR entirely (verified live — `TMPDIR=$s
  # mktemp` still lands in /var/folders/…/T). Every other argv shape passes
  # straight through, so nothing else in the library changes behaviour.
  cat > "$B23_BIN/mktemp" <<'EOF_B23_MKTEMP'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 0 ]; then
  exec "$UBERDEV_TEST_REAL_MKTEMP" "$UBERDEV_TEST_LEAK_DIR/tmp.XXXXXXXXXX"
fi
exec "$UBERDEV_TEST_REAL_MKTEMP" "$@"
EOF_B23_MKTEMP
  chmod +x "$B23_BIN/mktemp"

  # $1 = FAKE_GH_MODE, $2 = shell text to run after sourcing, $3 = optional
  # prelude executed BEFORE the source (B23g needs `setopt err_return` to be in
  # force while the library is read, exactly as a fence would set it).
  #
  # Env goes on the command as a PREFIX, never inlined into the `-c` string, and
  # $LIB is single-quoted inside it: this repo's checkout path contains a space
  # and every other form splits it.
  _b23_run() {
    local b23_err b23_prelude
    b23_prelude="${3:-}"
    b23_err="$(mktemp)"
    rm -rf "$B23_LEAKDIR"
    mkdir -p "$B23_LEAKDIR"
    : > "$B23_AUDIT"
    _B23_OUT="$(
      PATH="$B23_BIN:$FAKE_GH_DIR:$PATH" \
      FAKE_GH_MODE="$1" \
      UBERDEV_AUDIT_LOG_PATH="$B23_AUDIT" \
      UBERDEV_TEST_REAL_MKTEMP="$B23_REAL_MKTEMP" \
      UBERDEV_TEST_LEAK_DIR="$B23_LEAKDIR" \
      zsh -c "$b23_prelude . '$LIB' && $2" 2>"$b23_err"
    )"
    _B23_RC=$?
    _B23_ERR="$(cat "$b23_err")"
    rm -f "$b23_err"
    # The harness's own scratch files are made by the PARENT bash, which has no
    # shim on PATH, so they can never be miscounted as the child's leak.
    _B23_LEAK="$(ls -A "$B23_LEAKDIR" 2>/dev/null)"
  }

  # Every row asserts its own subject PLUS the two facts the bug produced.
  _b23_assert_clean() {
    local b23_label="$1"
    case "$_B23_ERR" in
      *"undefined signal"*)
        echo "  FAIL  $b23_label.signal: zsh rejected a trap signal — a \`trap … RETURN\` is back: $_B23_ERR"
        FAIL=$((FAIL + 1))
        ;;
      *)
        echo "  PASS  $b23_label.signal: no 'undefined signal' on stderr under zsh"
        PASS=$((PASS + 1))
        ;;
    esac
    if [ -z "$_B23_LEAK" ]; then
      echo "  PASS  $b23_label.leak: the mktemp stderr-capture file was released"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $b23_label.leak: capture file(s) survived the call: $_B23_LEAK"
      FAIL=$((FAIL + 1))
    fi
  }

  _b23_run success-bare 'discover_bare_fast_path feat/x'
  assert_eq "$_B23_OUT" "2" "B23a: discover_bare_fast_path prints the count under zsh"
  assert_eq "$_B23_RC" "0" "B23a.rc: success exits 0"
  _b23_assert_clean B23a

  _b23_run success-multi 'discover_multi main'
  assert_eq "$_B23_RC" "0" "B23b.rc: discover_multi exits 0 under zsh"
  assert_eq "$(jq 'length' <<<"$_B23_OUT" 2>/dev/null)" "2" \
    "B23b: discover_multi emits the two-candidate array under zsh"
  _b23_assert_clean B23b

  _b23_run success-pr-view 'pr_view_projection 42'
  assert_eq "$_B23_RC" "0" "B23c.rc: pr_view_projection exits 0 under zsh"
  assert_eq "$(jq -r '.state' <<<"$_B23_OUT" 2>/dev/null)" "OPEN" \
    "B23c: pr_view_projection emits the projection under zsh"
  _b23_assert_clean B23c

  # THE ROW THAT CATCHES A TOO-EARLY RELEASE. Both _uberdev_discover_warn and
  # _uberdev_discover_emit_audit READ $gh_err; an `rm -f` hoisted above them
  # empties the breadcrumb while leaving every other row green.
  _b23_run fail-net 'discover_bare_fast_path feat/x'
  assert_eq "$_B23_RC" "1" "B23d.rc: gh failure propagates exit 1 under zsh"
  case "$_B23_ERR" in
    *"warning: bare-mode discovery failed"*"network unreachable"*)
      echo "  PASS  B23d: the failure breadcrumb still carries gh's stderr (release is after the readers)"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  B23d: breadcrumb missing or emptied — was \$gh_err released before the readers? [$_B23_ERR]"
      FAIL=$((FAIL + 1))
      ;;
  esac
  _b23_assert_clean B23d

  # discover_multi's contract is "always exits 0, '[]' on failure" — two of its
  # three returns are on failure arms an error-only probe would never reach.
  _b23_run fail-net 'discover_multi main'
  assert_eq "$_B23_RC" "0" "B23e.rc: discover_multi still exits 0 on gh failure under zsh"
  assert_eq "$_B23_OUT" "[]" "B23e: discover_multi falls back to '[]' under zsh"
  case "$_B23_ERR" in
    *"warning: multi-discover failed"*"network unreachable"*)
      echo "  PASS  B23e: multi-discover breadcrumb intact"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  B23e: multi-discover breadcrumb missing or emptied [$_B23_ERR]"
      FAIL=$((FAIL + 1))
      ;;
  esac
  _b23_assert_clean B23e

  _b23_run fail-pr-view 'pr_view_projection 42'
  assert_eq "$_B23_RC" "1" "B23f.rc: pr_view_projection normalises gh's exit 2 to 1 under zsh"
  case "$_B23_ERR" in
    *"warning: pr_view_projection #42 failed (gh exit 2)"*)
      echo "  PASS  B23f: pr_view_projection breadcrumb carries the real gh exit code"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  B23f: pr_view_projection breadcrumb missing or emptied [$_B23_ERR]"
      FAIL=$((FAIL + 1))
      ;;
  esac
  _b23_assert_clean B23f

  # The errexit half, pinned CONDITIONALLY and on purpose. Under default zsh
  # options the dead trap only leaked and printed; under `setopt err_return` (or
  # `set -e`) it ABORTED the function at that line, so the caller's `|| N=0`
  # normalised a real single-PR fast path to "no PRs" and /merge re-discovered
  # the whole queue. merge-pipeline/SKILL.md sets no errexit today, so this was
  # one `set -e` away rather than live — and no row here asserts a non-zero
  # return under default options, because that behaviour does not exist.
  _b23_run success-bare 'discover_bare_fast_path feat/x' 'setopt err_return;'
  assert_eq "$_B23_RC" "0" "B23g.rc: survives \`setopt err_return\` (pre-fix this aborted with rc=1)"
  assert_eq "$_B23_OUT" "2" "B23g: still prints the count under \`setopt err_return\`"
  _b23_assert_clean B23g

  # The audit event is the other reader of $gh_err, and its exit_code field is
  # the thing a stray statement between the gh capture and `local gh_exit=$?`
  # would silently rewrite (A5e locks the source side; this locks the runtime).
  _b23_run fail-net 'discover_bare_fast_path feat/x'
  B23_EVENTS="$(jq -s -c '[.[] | select(.event=="discovery_gh_failed")]' "$B23_AUDIT" 2>/dev/null)"
  assert_eq "$(jq 'length' <<<"${B23_EVENTS:-[]}" 2>/dev/null)" "1" \
    "B23h: exactly one discovery_gh_failed event written under zsh"
  assert_eq "$(jq -r '.[0].data.step // empty' <<<"${B23_EVENTS:-[]}" 2>/dev/null)" "1.0.5" \
    "B23h.step: the event carries step 1.0.5"
  assert_eq "$(jq -r '.[0].data.exit_code | type' <<<"${B23_EVENTS:-[]}" 2>/dev/null)" "number" \
    "B23h.exit_code: exit_code is numeric (not rewritten by an inserted statement)"
  assert_eq "$(jq -r '(.[0].data.gh_stderr // "") | length > 0' <<<"${B23_EVENTS:-[]}" 2>/dev/null)" "true" \
    "B23h.gh_stderr: gh's stderr reached the audit log (release is after the readers)"
  _b23_assert_clean B23h

  rm -rf "$B23_SANDBOX"
fi

echo
echo "== B24: discover_multi finds stacked PRs and roots them transitively (#437) =="
# Half 2. `--base` is an EXACT server-side match, so a PR whose base is another
# PR's head returned 0 candidates and /merge exited 0 with "nothing to merge".
# The fake-gh `success-stacked` mode ignores argv and returns the FULL set, so
# this row measures the CLIENT-SIDE filter and nothing else:
#   101 base=main            -> in  (root)
#   102 base=feat/branch-a   -> in  (1 hop:  head of 101)
#   103 base=feat/branch-b   -> in  (2 hops: head of 102)   <-- transitivity
#   109 base=release/2.0     -> OUT (nobody's head)
#   110 base=null            -> OUT (defensive: null base is not the root)
B24_AUDIT="$(mktemp)"; rm -f "$B24_AUDIT"
B24_CALLLOG="$(mktemp)"; : > "$B24_CALLLOG"
_run_lib_call "success-stacked" \
  'discover_multi main' \
  "export UBERDEV_AUDIT_LOG_PATH='$B24_AUDIT'; export FAKE_GH_CALL_LOG='$B24_CALLLOG'"
assert_eq "$_LB_EXIT" "0" "B24a: exit 0 (discover_multi never aborts the run)"
B24_NUMS="$(jq -c '[.[].number]' <<<"${_LB_STDOUT:-[]}" 2>/dev/null)"
assert_eq "${B24_NUMS:-PARSE_FAILED}" "[101,103,102]" \
  "B24b: the whole 3-deep stack survives, input order preserved, unrelated bases dropped"
# Falsifiability floor: prove the fixture really did offer the two PRs that
# must be excluded, so B24b is a filter result and not an empty-input pass.
B24_RAW_COUNT="$(FAKE_GH_MODE=success-stacked "$FAKE_GH_DIR/gh" pr list | jq 'length' 2>/dev/null)"
assert_eq "${B24_RAW_COUNT:-0}" "5" \
  "B24c: the fixture offered 5 candidates (so B24b's 3 is a real exclusion, not an empty set)"
# The wire query must no longer carry --base at all: a server-side exact match
# is unfixable client-side because the stacked rows never arrive.
if grep -q -e '--base' "$B24_CALLLOG" 2>/dev/null; then
  echo "  FAIL  B24d: the gh wire query still carries --base (stacked PRs never reach the client-side filter)"
  echo "        call log: $(cat "$B24_CALLLOG")"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  B24d: the gh wire query carries no --base (recorded argv)"
  PASS=$((PASS + 1))
fi
# Anti-vacuity for B24d: the stub must actually have been called and logged.
if [ -s "$B24_CALLLOG" ]; then
  echo "  PASS  B24e: the fake-gh call log is non-empty (B24d is a real argv assertion)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B24e: the fake-gh call log is empty — B24d would pass vacuously"
  FAIL=$((FAIL + 1))
fi
# B24d is a NEGATIVE argv assertion, and a negative alone cannot catch a MISSING
# bound. Dropping --base moved the base filter off the wire, so gh's default
# `--limit 30` (gh 2.83.1) stopped applying to the integration-branch subset and
# started applying to EVERY open PR in the repo — eligible candidates truncated
# away before the client-side filter ever sees them, i.e. the false-convergence
# signal /goal consumes, reintroduced in a new form. The window must therefore be
# explicit and wide.
if grep -q -e '--limit' "$B24_CALLLOG" 2>/dev/null; then
  echo "  PASS  B24i: the gh wire query carries an explicit --limit (recorded argv)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B24i: the gh wire query has NO --limit — gh's default 30-row window now spans every base branch in the repo, silently truncating candidates (#437)"
  echo "        call log: $(cat "$B24_CALLLOG")"
  FAIL=$((FAIL + 1))
fi
# ...and wide enough to matter. A `--limit 30` would satisfy B24i while changing
# nothing, so pin the literal the Constants table declares.
if grep -q -e '--limit 200' "$B24_CALLLOG" 2>/dev/null; then
  echo "  PASS  B24j: the wire window is DISCOVERY_WIRE_LIMIT=200 (matches lib/goal-state.sh's PR enumerations)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B24j: the wire window must be 200, not gh's default 30 (#437 — the base filter now runs AFTER truncation)"
  echo "        call log: $(cat "$B24_CALLLOG")"
  FAIL=$((FAIL + 1))
fi
if [ -s "$B24_AUDIT" ]; then
  echo "  FAIL  B24f: audit log unexpectedly non-empty on the happy stacked path: $(cat "$B24_AUDIT")"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  B24f: no discovery_gh_failed event on the happy stacked path"
  PASS=$((PASS + 1))
fi
# Non-stacked repos must be BIT-IDENTICAL to pre-#437: success-multi is two
# PRs both based on main, and both must still come back.
_run_lib_call "success-multi" 'discover_multi main'
assert_eq "$(jq -c '[.[].number]' <<<"${_LB_STDOUT:-[]}" 2>/dev/null)" "[101,102]" \
  "B24g: the non-stacked path is unchanged (both main-based PRs still returned)"
# A root that no PR is based on yields an empty set, not the whole list.
_run_lib_call "success-stacked" 'discover_multi trunk'
assert_eq "$(jq -c '.' <<<"${_LB_STDOUT:-null}" 2>/dev/null)" "[]" \
  "B24h: an unmatched root returns [] (the filter is a filter, not a pass-through)"
rm -f "$B24_AUDIT" "$B24_CALLLOG"

echo
echo "== B25: resolve_pr_base fails CLOSED on every unresolvable base (#437) =="
# Silently substituting integration_branch is precisely the bug, so the
# contract is: stdout carries the resolved ref ONLY on success; every failure
# arm emits gate_fail reason=pr_base_unresolvable and prints nothing.
# `baseRefName` is GitHub-supplied text that reaches `git` argv, so it gets the
# same BRANCH_NAME_REGEX gate SKILL.md Step 1.2 applies to the global branch.
B25_REPO="$(mktemp -d)"
(
  cd "$B25_REPO" || exit 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name Tester
  printf 'l1\nl2\n' > f.txt
  git add f.txt
  git commit -q -m M0
  git update-ref refs/remotes/origin/main main
  git checkout -q -b feat/a
  printf 'l1\na1\n' > f.txt
  git commit -q -am A1
  git update-ref refs/remotes/origin/feat/a feat/a
) >/dev/null 2>&1

# $1 = base-ref argument, $2 = audit-log path. Runs with cwd inside the git
# fixture so the rev-parse guard has real refs to resolve against.
_b25_run() {
  local b25_out b25_err
  b25_out="$(mktemp)"; b25_err="$(mktemp)"
  : > "$2"
  (
    cd "$B25_REPO" || exit 127
    UBERDEV_AUDIT_LOG_PATH="$2"
    export UBERDEV_AUDIT_LOG_PATH
    # shellcheck source=/dev/null
    . "$LIB"
    resolve_pr_base 42 "$1"
  ) >"$b25_out" 2>"$b25_err"
  _B25_RC=$?
  _B25_OUT="$(cat "$b25_out")"
  _B25_ERR="$(cat "$b25_err")"
  rm -f "$b25_out" "$b25_err"
}

B25_AUDIT="$(mktemp)"

_b25_run 'feat/a' "$B25_AUDIT"
assert_eq "$_B25_RC" "0"              "B25a: a resolvable per-PR base exits 0"
assert_eq "$_B25_OUT" "origin/feat/a" "B25b: stdout is the origin/-qualified remote-tracking ref (#303 invariant)"
assert_eq "$([ -s "$B25_AUDIT" ] && echo nonempty || echo empty)" "empty" \
  "B25c: no gate_fail on the happy path"

# Four failure arms. Each must exit 1, print NOTHING, and type the failure.
#   empty  -> baseRefName absent/empty from the projection
#   null   -> GitHub's JSON null rendered by `jq -r`
#   space  -> BRANCH_NAME_REGEX reject (argv-injection surface)
#   nl     -> embedded newline (a line-oriented regex gate would let the
#             second line through; this is the arm a naive `grep -qE` fails)
#   ghost  -> refs/remotes/origin/<base> absent: `git merge-tree` against a
#             missing ref exits 1, byte-indistinguishable from a real conflict
B25_NL="$(printf 'feat/a\nevil')"
for b25_case in "empty::" "null:null:" "space:feat/a evil:" "ghost:no/such/branch:"; do
  b25_label="${b25_case%%:*}"
  b25_rest="${b25_case#*:}"
  b25_arg="${b25_rest%:*}"
  _b25_run "$b25_arg" "$B25_AUDIT"
  assert_eq "$_B25_RC" "1" "B25.$b25_label.rc: unresolvable base ('$b25_arg') exits 1"
  assert_eq "$_B25_OUT" ""  "B25.$b25_label.stdout: prints nothing — NEVER falls back to integration_branch"
  assert_grep "$B25_AUDIT" '"event":"gate_fail"' \
    "B25.$b25_label.audit: emits a gate_fail audit row"
  assert_grep "$B25_AUDIT" '"reason":"pr_base_unresolvable"' \
    "B25.$b25_label.reason: the reason is the typed GATE_FAIL_REASON_ENUM member"
done
_b25_run "$B25_NL" "$B25_AUDIT"
assert_eq "$_B25_RC" "1" "B25.newline.rc: an embedded newline in baseRefName is rejected"
assert_eq "$_B25_OUT" ""  "B25.newline.stdout: prints nothing"
# The load-bearing negative: no failure arm may leak the global branch.
_b25_run 'no/such/branch' "$B25_AUDIT"
case "$_B25_OUT" in
  *main*) echo "  FAIL  B25.no-fallback: stdout leaked 'main' on an unresolvable base — that IS #437"
          FAIL=$((FAIL + 1)) ;;
  *)      echo "  PASS  B25.no-fallback: an unresolvable base never yields the integration branch"
          PASS=$((PASS + 1)) ;;
esac
rm -f "$B25_AUDIT"
rm -rf "$B25_REPO"

echo
echo "== B26: the per-PR base is what makes the probe TRUTHFUL (#437, both directions) =="
# Executed against real git, not asserted. Both directions were reproduced on
# the issue and are reproduced here from the ref resolve_pr_base returns.
# Capability probe by EXECUTION (never `--help`, which pages): merge-tree
# --write-tree landed in git 2.38 and is the primitive Step 3.1 mandates.
B26_CAP="$(mktemp -d)"
(
  cd "$B26_CAP" || exit 1
  git init -q -b main .
  git config user.email t@example.com; git config user.name Tester
  printf 'x\n' > f.txt; git add f.txt; git commit -q -m c1
  git merge-tree --write-tree main main
) >/dev/null 2>&1
B26_CAPRC=$?
rm -rf "$B26_CAP"
if [ "$B26_CAPRC" -ne 0 ]; then
  echo "  FAIL  B26.pre: git merge-tree --write-tree unavailable (rc=$B26_CAPRC) — the probe under test cannot be executed"
  FAIL=$((FAIL + 1))
else
  # Direction 1 — PHANTOM CONFLICT. fix/b is stacked on fix/a; main advanced
  # after fix/a was cut. Probing fix/b against main invents a conflict that
  # does not exist on the merge /merge is actually performing.
  B26_FX1="$(mktemp -d)"
  (
    cd "$B26_FX1" || exit 1
    git init -q -b main .
    git config user.email t@example.com; git config user.name Tester
    printf 'l1\nl2\n' > f.txt; git add f.txt; git commit -q -m M0
    git checkout -q -b fix/a; printf 'l1\na1\n' > f.txt; git commit -q -am A1
    git checkout -q -b fix/b; printf 'l1\nb1\n' > f.txt; git commit -q -am B1
    git checkout -q main;     printf 'l1\nm1\n' > f.txt; git commit -q -am M1
    git update-ref refs/remotes/origin/main main
    git update-ref refs/remotes/origin/fix/a fix/a
  ) >/dev/null 2>&1
  B26_BASE1="$( cd "$B26_FX1" && . "$LIB" && resolve_pr_base 102 'fix/a' )"
  ( cd "$B26_FX1" && git merge-tree --write-tree origin/main fix/b ) >/dev/null 2>&1
  B26_WRONG1=$?
  ( cd "$B26_FX1" && git merge-tree --write-tree "$B26_BASE1" fix/b ) >/dev/null 2>&1
  B26_RIGHT1=$?
  assert_eq "$B26_BASE1" "origin/fix/a" "B26a: resolve_pr_base returns the stacked PR's own base"
  assert_eq "$B26_WRONG1" "1" "B26b: probing against the GLOBAL branch reports a conflict (the phantom /merge invents today)"
  assert_eq "$B26_RIGHT1" "0" "B26c: probing against the RESOLVED per-PR base is clean — no conflict-resolver fanout is warranted"
  rm -rf "$B26_FX1"

  # Direction 2 — INVISIBLE REAL CONFLICT. fix/b was cut from fix/a@A1 and
  # fix/a then advanced divergently. main-vs-fix/b is clean, so /merge takes
  # the clean path and fires `gh pr merge` at a PR that does not merge.
  B26_FX2="$(mktemp -d)"
  (
    cd "$B26_FX2" || exit 1
    git init -q -b main .
    git config user.email t@example.com; git config user.name Tester
    printf 'l1\nl2\n' > f.txt; git add f.txt; git commit -q -m M0
    git checkout -q -b fix/a; printf 'l1\na1\n' > f.txt; git commit -q -am A1
    git checkout -q -b fix/b; printf 'l1\nb1\n' > f.txt; git commit -q -am B1
    git checkout -q fix/a;    printf 'l1\na2\n' > f.txt; git commit -q -am A2
    git update-ref refs/remotes/origin/main main
    git update-ref refs/remotes/origin/fix/a fix/a
  ) >/dev/null 2>&1
  B26_BASE2="$( cd "$B26_FX2" && . "$LIB" && resolve_pr_base 202 'fix/a' )"
  ( cd "$B26_FX2" && git merge-tree --write-tree origin/main fix/b ) >/dev/null 2>&1
  B26_WRONG2=$?
  ( cd "$B26_FX2" && git merge-tree --write-tree "$B26_BASE2" fix/b ) >/dev/null 2>&1
  B26_RIGHT2=$?
  # Anti-vacuity for B26e: `git merge-tree --write-tree "" <head>` also exits 1,
  # so without this row a resolve_pr_base that returned nothing would keep B26e
  # green for the wrong reason.
  assert_eq "$B26_BASE2" "origin/fix/a" "B26d.base: the resolved ref is the real base, not an empty string"
  assert_eq "$B26_WRONG2" "0" "B26d: probing against the GLOBAL branch is clean — the real conflict is INVISIBLE"
  assert_eq "$B26_RIGHT2" "1" "B26e: probing against the RESOLVED per-PR base DETECTS the real conflict"
  rm -rf "$B26_FX2"

  # The rc-collision that makes the fetch guard load-bearing: a base ref that
  # was never fetched makes merge-tree exit 1 — the SAME code as a genuine
  # conflict. `git rev-parse --verify` is the only honest discriminator, and
  # resolve_pr_base runs it BEFORE the probe.
  B26_FX3="$(mktemp -d)"
  (
    cd "$B26_FX3" || exit 1
    git init -q -b main .
    git config user.email t@example.com; git config user.name Tester
    printf 'l1\n' > f.txt; git add f.txt; git commit -q -m M0
    git update-ref refs/remotes/origin/main main
  ) >/dev/null 2>&1
  ( cd "$B26_FX3" && git merge-tree --write-tree origin/fix/a main ) >/dev/null 2>&1
  assert_eq "$?" "1" "B26f: an unfetched base makes merge-tree exit 1 — indistinguishable from a real conflict"
  ( cd "$B26_FX3" && . "$LIB" && UBERDEV_AUDIT_LOG_PATH=/dev/null resolve_pr_base 42 'fix/a' ) >/dev/null 2>&1
  assert_eq "$?" "1" "B26g: resolve_pr_base gate-fails on the unfetched base instead of letting it read as a conflict"
  rm -rf "$B26_FX3"
fi

echo
echo "== B27: the #437 helpers run clean under zsh (the shell SKILL fences use) (#401 class) =="
# Same reasoning as B23: a shape-grep is blind to `type -t`, $BASH_REMATCH and
# friends. resolve_pr_base does regex validation and discover_multi now runs a
# jq closure — both are exactly the shapes that historically differed.
if ! command -v zsh >/dev/null 2>&1; then
  echo "  FAIL  B27.pre: zsh not on PATH — the production-shell row must never SKIP"
  FAIL=$((FAIL + 1))
else
  B27_REPO="$(mktemp -d)"
  (
    cd "$B27_REPO" || exit 1
    git init -q -b main .
    git config user.email t@example.com; git config user.name Tester
    printf 'l1\n' > f.txt; git add f.txt; git commit -q -m M0
    git update-ref refs/remotes/origin/main main
  ) >/dev/null 2>&1
  B27_ERR="$(mktemp)"
  B27_OUT="$(
    cd "$B27_REPO" && \
    UBERDEV_AUDIT_LOG_PATH=/dev/null \
    zsh -c ". '$LIB' && resolve_pr_base 42 main" 2>"$B27_ERR"
  )"
  B27_RC=$?
  assert_eq "$B27_RC"  "0"           "B27a: resolve_pr_base exits 0 under zsh"
  assert_eq "$B27_OUT" "origin/main" "B27b: resolve_pr_base returns the same ref under zsh"
  assert_eq "$(cat "$B27_ERR")" ""   "B27c: resolve_pr_base is stderr-clean under zsh (no 'bad pattern'/'undefined signal')"
  B27_STACK="$(
    PATH="$FAKE_GH_DIR:$PATH" FAKE_GH_MODE=success-stacked UBERDEV_AUDIT_LOG_PATH=/dev/null \
    zsh -c ". '$LIB' && discover_multi main" 2>"$B27_ERR"
  )"
  assert_eq "$(jq -c '[.[].number]' <<<"${B27_STACK:-[]}" 2>/dev/null)" "[101,103,102]" \
    "B27d: the stack closure produces the same set under zsh"
  assert_eq "$(cat "$B27_ERR")" "" "B27e: discover_multi is stderr-clean under zsh on the stacked path"
  # TWO dropped candidates, deliberately. zsh does not word-split an unquoted
  # parameter expansion (SH_WORD_SPLIT is off), so a `for n in $dropped` over the
  # multi-line jq output would iterate ONCE over the whole blob and emit a single
  # gate_fail whose "PR number" is a newline-joined string. A one-element fixture
  # passes under both shells and proves nothing — the row needs >=2 drops to see it.
  B27_PRUNE_SET='[{"number":101,"headRefName":"feat/branch-a","baseRefName":"main"},{"number":102,"headRefName":"feat/branch-b","baseRefName":"feat/gone"},{"number":103,"headRefName":"feat/branch-c","baseRefName":"feat/also-gone"}]'
  B27_PRUNE_AUDIT="$(mktemp)"; : > "$B27_PRUNE_AUDIT"
  B27_PRUNE="$(
    UBERDEV_AUDIT_LOG_PATH="$B27_PRUNE_AUDIT" \
    zsh -c ". '$LIB' && prune_orphaned_candidates main '$B27_PRUNE_SET'" 2>"$B27_ERR"
  )"
  assert_eq "$(jq -c '[.[].number]' <<<"${B27_PRUNE:-[]}" 2>/dev/null)" "[101]" \
    "B27f: prune_orphaned_candidates produces the same set under zsh"
  assert_eq "$(grep -c '"reason":"pr_base_parent_skipped"' "$B27_PRUNE_AUDIT" || true)" "2" \
    "B27g: BOTH drops are emitted as separate rows under zsh (a \`for n in \$dropped\` loop would emit ONE row with a newline-joined pr number)"
  assert_eq "$(jq -sc '[.[].pr] | sort' "$B27_PRUNE_AUDIT" 2>/dev/null)" "[102,103]" \
    "B27h: each row carries a real integer pr number under zsh (not a joined blob sanitised to 0)"
  rm -f "$B27_PRUNE_AUDIT"
  rm -f "$B27_ERR"
  rm -rf "$B27_REPO"
fi

echo
echo "== B28: a stacked child whose parent did NOT survive is pruned, not merged (#437) =="
# Half 2 admits stacked candidates. Step 1.4 then REMOVES some of them, and
# nothing used to drop their children. That state is silent and severe: PR-A
# gate-fails on an ordinary reason (ci_red, trust_trail_missing), PR-B is
# stacked on A's head and is green, so PR-B reaches Step 3.2 and
# `gh pr merge <B>` merges it into GitHub's RECORDED base — fix/a, not the
# integration branch. That emits merge_executed, the event /goal's
# uberdev_goal_read_merge_result selects, so the run reports converged and B's
# `Closes #N` closes the issue while main never receives the code. Before #437
# every survivor shared one base and this was structurally impossible.
#
# Fixture: the SAME 3-deep stack as B24, minus PR 101 (the root) — i.e. the
# state after 101 gate-fails at Phase 1.4. 102 and 103 are both green and both
# unmergeable.
B28_AUDIT="$(mktemp)"; : > "$B28_AUDIT"
B28_ERRF="$(mktemp)"
B28_ORPHANS='[{"number":102,"headRefName":"feat/branch-b","baseRefName":"feat/branch-a"},{"number":103,"headRefName":"feat/branch-c","baseRefName":"feat/branch-b"}]'
B28_OUT="$(
  UBERDEV_AUDIT_LOG_PATH="$B28_AUDIT" \
  bash -c ". '$LIB' && prune_orphaned_candidates main '$B28_ORPHANS'" 2>"$B28_ERRF"
)"
assert_eq "$(jq -c '.' <<<"${B28_OUT:-null}" 2>/dev/null)" "[]" \
  "B28a: both orphans are dropped — a green child of a skipped parent is NOT mergeable"
# TRANSITIVITY: 103's parent is 102, which is itself an orphan. A one-hop
# parent check would keep 103 and merge it into feat/branch-b.
assert_eq "$(grep -c '"reason":"pr_base_parent_skipped"' "$B28_AUDIT" || true)" "2" \
  "B28b: BOTH dropped candidates emit the typed gate_fail (the closure is transitive, not one-hop)"
assert_grep "$B28_AUDIT" '"pr":103' \
  "B28c: the 2-hop orphan is dropped too (dropping PR-B must drop whatever is stacked on PR-B)"
if grep -q 'stacked on a PR that did not survive' "$B28_ERRF"; then
  echo "  PASS  B28d: each drop leaves a stderr breadcrumb (never a silent drop)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  B28d: a dropped candidate MUST surface on stderr — silent drops are how false convergence hides"
  echo "        stderr: $(cat "$B28_ERRF")"
  FAIL=$((FAIL + 1))
fi
# The other half of the contract: survivors rooted on the integration branch
# are untouched, so this is a filter and not a blanket refusal.
B28_SET='[{"number":101,"headRefName":"feat/branch-a","baseRefName":"main"},{"number":109,"headRefName":"feat/branch-z","baseRefName":"release/2.0"}]'
: > "$B28_AUDIT"
B28_KEEP="$(
  UBERDEV_AUDIT_LOG_PATH="$B28_AUDIT" \
  bash -c ". '$LIB' && prune_orphaned_candidates main '$B28_SET'" 2>/dev/null
)"
assert_eq "$(jq -c '[.[].number]' <<<"${B28_KEEP:-[]}" 2>/dev/null)" "[101]" \
  "B28e: an integration-rooted candidate survives; an unrelated-base one does not"
# FAIL-OPEN on malformed input. Every arm of this function only REMOVES
# candidates, so a jq failure that emitted '[]' would convert a transient tool
# error into "nothing to merge" — the exact false-convergence signal the
# function exists to prevent. Returning the input unchanged is the safe
# direction; Step 3.2's per-iteration parent-landed guard still gates the merge.
: > "$B28_AUDIT"
B28_BAD="$(
  UBERDEV_AUDIT_LOG_PATH="$B28_AUDIT" \
  bash -c ". '$LIB' && prune_orphaned_candidates main 'not json'" 2>/dev/null
)"
assert_eq "$B28_BAD" "not json" \
  "B28f: an unevaluable reachability check FAILS OPEN (returns the input) — never '[]', which would BE false convergence"
assert_eq "$([ -s "$B28_AUDIT" ] && echo nonempty || echo empty)" "empty" \
  "B28g: the fail-open path emits no gate_fail (it dropped nobody, so it must accuse nobody)"
rm -f "$B28_AUDIT" "$B28_ERRF"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
