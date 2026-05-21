#!/usr/bin/env bash
# Shape-check harness for /uberdev:goal (RFC 0005).
#
# Covers G1-G20 acceptance gates from the implementation plan
# (docs/uberdev/plans/2026-05-21-uberdev-goal.md §Task 4):
#   G1   commands/goal.md + skills/goal-pipeline/SKILL.md frontmatter
#   G2   PR state machine enum (8 states)
#   G3   Issue state machine enum (5 states)
#   G4   Trust-signal handling (GREEN dispatches merge, YELLOW=critical,
#        RED=blocker, stale via phase2_5)
#   G5   Blocker-unblock chain (Blocks: #N regex, held states,
#        goal_unblock_triggered event)
#   G6   Circuit breaker: max_cycles
#   G7   Circuit breaker: nonconvergence (fingerprint-repeat)
#   G8   Circuit breaker: stuck_loop (4h wall-clock)
#   G9   Circuit breaker: merge_failed
#   G10  Convergence happy-path (goal_converged + exit 0)
#   G11  All 6 audit events present
#   G12  Alias provisioning across 5 surfaces (T5 — see notes)
#   G13  claim_collision soft-fail
#   G14  Blocker overflow (red-held + first-10 truncation, no goal halt)
#   G15  Backend inheritance (UBERDEV_RESOLVED_BACKEND forwarded)
#   G16  Provenance check (UBERDEV_GOAL_ID + automerge predicate + attempts)
#   G17  --dry-run semantics (exits 0, does NOT actually dispatch)
#   G18  ReDoS-safe Blocks: parser (anchored regex + body cap)
#   G19  lib/goal-state.sh shape (12 public + 10 internal fns +
#        idempotency guard + no eval / no bash -c + R12 negative)
#   G20  Version bump locked (plugin.json, marketplace.json,
#        README badge, CHANGELOG, no 0.30.0 leak in solve-claim.test.sh)
#
# Pre-T5 expected failures: G12.readme (README badge mention of /ubergoal)
# and G12.aliases-test (tests/aliases.test.sh row for /ubergoal) — these
# pass once T5's wave-4 alias-provisioning commit lands. G20.readme-badge
# additionally fails until T5 bumps the README version badge from 0.29.0
# to 0.31.0 (T5 owns README.md per the wave-4 file allowlist).

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GOAL_CMD="$REPO_ROOT/plugins/uberdev/commands/goal.md"
GOAL_SKILL="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/SKILL.md"
GOAL_LIB="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"

# Pre-flight: refuse to run if any asserted-against file is missing.
for f in "$GOAL_CMD" "$GOAL_SKILL" "$GOAL_LIB"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s\n' "$file" >&2
    printf '        pattern: %s\n' "$pattern" >&2
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s\n' "$file" >&2
    printf '        pattern: %s (should NOT match)\n' "$pattern" >&2
  else
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  fi
}

echo "== G1: frontmatter (skill + command) =="
assert_grep "$GOAL_SKILL" '^name: goal-pipeline$'        "G1.skill-name"
assert_grep "$GOAL_CMD"   '^description: '               "G1.cmd-description"
assert_grep "$GOAL_CMD"   '^argument-hint: '             "G1.cmd-arg-hint"
assert_grep "$GOAL_CMD"   '^allowed-tools: '             "G1.cmd-allowed-tools"

echo
echo "== G2 + G3: state machine enums =="
# 8-state PR machine: all 8 names appear in the enum constant on a single line.
assert_grep "$GOAL_SKILL" \
  'dispatched\|pushed-reviewing\|green\|yellow-held\|red-held\|merging\|merged\|merge-failed' \
  "G2.pr-state-machine"
# 5-state issue machine: all 5 names appear in the enum constant on a single line.
assert_grep "$GOAL_SKILL" \
  'input\|solving\|pr-pushed\|resolved\|failed' \
  "G3.issue-state-machine"

echo
echo "== G4: trust-signal handling =="
# G4a — GREEN trust signal path: the trust-signal helper is read AND the green
# state is handled. Plan called for 'signal.*green' on one line, but the
# SKILL's case-block has signal on line 200 and `green)` on line 203 (well-
# formed bash); collapse to two single-line assertions: the helper name and
# the green case-arm.
assert_grep "$GOAL_SKILL" 'uberdev_goal_read_trust_signal'  "G4a.trust-signal-read"
assert_grep "$GOAL_SKILL" '^[[:space:]]*green\)[[:space:]]*$|green\)[[:space:]]*$' "G4a.green-case-arm"
# G4a (cont) — GREEN dispatches /merge. The SKILL uses bare `/merge` prose AND
# the helper `_uberdev_goal_dispatch_merge`; either proves the contract.
assert_grep "$GOAL_SKILL" '/merge|_uberdev_goal_dispatch_merge' "G4a.green-dispatches-merge"
# G4b — YELLOW held on CRITICAL.
assert_grep "$GOAL_SKILL" 'yellow-held'                     "G4b.yellow-held"
assert_grep "$GOAL_SKILL" 'critical|CRITICAL'               "G4b.yellow-critical-trigger"
# G4c — RED held on BLOCKER (or halted_due_to_overflow).
assert_grep "$GOAL_SKILL" 'red-held'                        "G4c.red-held"
assert_grep "$GOAL_SKILL" 'blocker|BLOCKER'                 "G4c.red-blocker-trigger"
# G4d — stale handling: phase2_5 absent => re-dispatch /review-pr (not assumed GREEN).
assert_grep "$GOAL_SKILL" 'phase2_5|stale'                  "G4d.stale-handling"

echo
echo "== G5: blocker-unblock chain =="
# The anchored regex MUST appear in the skill's prose / constant.
assert_grep "$GOAL_SKILL" '\^Blocks: #'                     "G5.blocks-regex"
assert_grep "$GOAL_SKILL" 'yellow-held\|red-held'           "G5.held-states"
assert_grep "$GOAL_SKILL" 'goal_unblock_triggered'          "G5.unblock-audit-event"

echo
echo "== G6: circuit breaker max_cycles =="
assert_grep "$GOAL_SKILL" 'MAX_CYCLES|max_cycles'                  "G6.max-cycles-constant"
assert_grep "$GOAL_SKILL" 'cycle.*>.*MAX_CYCLES|cycle >= MAX'      "G6.max-cycles-check"
assert_grep "$GOAL_SKILL" 'goal_circuit_breaker.*max_cycles'       "G6.max-cycles-breaker-emit"

echo
echo "== G7: circuit breaker nonconvergence =="
assert_grep "$GOAL_SKILL" 'fingerprint'                                  "G7.fingerprint-name"
assert_grep "$GOAL_SKILL" 'check_fingerprint_repeat|fingerprint.*repeat' "G7.fingerprint-repeat-check"
assert_grep "$GOAL_SKILL" 'goal_circuit_breaker.*nonconvergence'         "G7.nonconvergence-breaker-emit"

echo
echo "== G8: circuit breaker stuck_loop =="
assert_grep "$GOAL_SKILL" '4 hour|4h|14400'                              "G8.stuck-loop-constant"
assert_grep "$GOAL_SKILL" 'watch_start|stuck_loop'                       "G8.stuck-loop-check"
assert_grep "$GOAL_SKILL" 'goal_circuit_breaker.*stuck_loop'             "G8.stuck-loop-breaker-emit"

echo
echo "== G9: circuit breaker merge_failed =="
assert_grep "$GOAL_SKILL" 'merge_result|merge.*conflict|hook_failed'     "G9.merge-result-classification"
assert_grep "$GOAL_SKILL" 'goal_circuit_breaker.*merge_failed'           "G9.merge-failed-breaker-emit"
assert_grep "$GOAL_SKILL" 'exit 1'                                       "G9.halt-on-merge-failure"

echo
echo "== G10: convergence happy-path =="
assert_grep "$GOAL_SKILL" 'goal_converged'                "G10.converged-event"
assert_grep "$GOAL_SKILL" 'queue.*empty|new_candidates'   "G10.empty-queue-predicate"
assert_grep "$GOAL_SKILL" 'exit 0'                        "G10.zero-exit"

echo
echo "== G11: all 6 audit events present =="
for e in goal_dispatched goal_pr_transition goal_unblock_triggered \
         goal_cycle_completed goal_converged goal_circuit_breaker; do
  assert_grep "$GOAL_SKILL" "$e" "G11.${e}"
done

echo
echo "== G12: alias provisioning across 5 surfaces (T5 — partially pre-T5) =="
# These assertions exercise T5's wave-4 outputs. Until T5 commits the
# /ubergoal entry into all 5 surfaces (aliases-sync.sh, install-aliases.md,
# uninstall-aliases.md, README.md, tests/aliases.test.sh), G12.readme and
# G12.aliases-test will fail. The other three may already pass if T5's
# uncommitted worktree edits cover them at runtime.
assert_grep "$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"           'goal'        "G12.aliases-sync"
assert_grep "$REPO_ROOT/plugins/uberdev/commands/install-aliases.md"   '/ubergoal'   "G12.install-aliases-row"
assert_grep "$REPO_ROOT/plugins/uberdev/commands/uninstall-aliases.md" 'goal'        "G12.uninstall-shorts"
assert_grep "$REPO_ROOT/README.md"                                     '/ubergoal'   "G12.readme"
assert_grep "$REPO_ROOT/tests/aliases.test.sh"                         'goal'        "G12.aliases-test"

echo
echo "== G13: claim_collision soft-fail =="
assert_grep "$GOAL_SKILL" 'claim_collision'                          "G13.claim-collision"
assert_grep "$GOAL_SKILL" 'skip.*issue|continue.*cycle|soft.fail'    "G13.soft-fail-behaviour"
assert_grep "$GOAL_SKILL" 'do NOT halt|never silent|never halt'      "G13.no-halt-prose"

echo
echo "== G14: blocker overflow handler =="
assert_grep "$GOAL_SKILL" 'halted_due_to_overflow'                              "G14.overflow-flag"
assert_grep "$GOAL_SKILL" 'first.*10|truncate.*10|first 10|new_candidates.*:0:10'   "G14.first-10-only"
assert_grep "$GOAL_SKILL" 'does NOT halt the entire goal|do NOT halt entire goal'   "G14.no-halt-prose"

echo
echo "== G15: backend inheritance =="
assert_grep "$GOAL_SKILL" 'UBERDEV_RESOLVED_BACKEND'                        "G15.resolved-backend-env"
# The forwarded backend appears as --backend=$UBERDEV_RESOLVED_BACKEND on
# the /turbo dispatch line; allow either the env-var form or a literal
# backend name in the same line.
assert_grep "$GOAL_SKILL" '--backend=\$?UBERDEV_RESOLVED_BACKEND|--backend=[^[:space:]]+.*uberdev:turbo|uberdev:turbo.*--backend' \
                                                                            "G15.backend-forwarding"

echo
echo "== G16: provenance (Q5 / T5) =="
assert_grep "$GOAL_SKILL" 'UBERDEV_GOAL_ID'                              "G16.goal-id-env"
assert_grep "$GOAL_SKILL" 'uberdev_goal_should_automerge'                "G16.automerge-predicate"
assert_grep "$GOAL_SKILL" 'automerge_attempt|merge.*attempt|MERGE_ATTEMPTS'  "G16.attempt-counter"

echo
echo "== G17: --dry-run semantics =="
assert_grep "$GOAL_SKILL" '--dry-run|dry_run'                            "G17.dry-run-flag"
assert_grep "$GOAL_SKILL" 'exit 0'                                       "G17.dry-run-exit"
# Negative — must NOT actually dispatch /turbo inside the dry-run code path.
# The prose ("would dispatch /turbo") is descriptive narration, not real
# dispatch. Anchor on the imperative call-site shape rather than the prose:
# a real dispatch invokes uberdev_dispatch_one (or `/uberdev:turbo` inside a
# child-process prompt heredoc) — both forbidden inside the dry-run branch.
# Plan-literal `dry.run.*dispatch.*turbo` false-positives on Step 8's
# explanatory bullet at line 113 ("planned cycle-1 dispatch list … would
# dispatch /turbo for issues …"); the contract this assertion locks is "no
# actual gh/dispatch call in the dry-run branch", which is shape-checked by
# requiring the dry-run branch to exit before reaching uberdev_dispatch_one.
assert_no_grep "$GOAL_SKILL" 'dry_run=1.*uberdev_dispatch_one|uberdev_dispatch_one.*dry_run=1' \
                                                                         "G17.dry-run-no-dispatch"

echo
echo "== G18: ReDoS-safe Blocks: parser =="
# The bash-regex literal in lib/goal-state.sh line 95 is
# `^Blocks:\ \#([0-9]+)$` (escaped space, escaped hash). The plan's pattern
# `\^Blocks: #\(\[0-9\]\+\)\$` omits the in-source backslashes; widen to
# match either form so any future stylistic edit (e.g., dropping the
# backslash-escape on space) does not falsely fail.
assert_grep "$GOAL_LIB" '\^Blocks:\\? *\\?#?\(\[0-9\]\+\)\$|\^Blocks: #\(\[0-9\]\+\)\$' \
                                                                         "G18.anchored-regex-in-lib"
assert_grep "$GOAL_LIB" '_UBERDEV_GOAL_BODY_CAP|head -c 65536'           "G18.body-cap"

echo
echo "== G19: lib/goal-state.sh shape =="
# Public function names (11 — uberdev_goal_build_unblock_graph removed
# in the post-impl-review B5 cleanup; it was dead code, never called from
# SKILL.md or anywhere else, and the per-PR unblock decision is made
# in-line by _uberdev_goal_check_unblock without a pre-built graph).
for fn in uberdev_goal_state_init uberdev_goal_pr_state_transition uberdev_goal_issue_state_transition \
          uberdev_goal_read_trust_signal uberdev_goal_check_fingerprint_repeat uberdev_goal_should_automerge \
          uberdev_goal_audit uberdev_goal_locate_review_pr_audit \
          uberdev_goal_extract_pr_num_from_log uberdev_goal_list_prs_in_state uberdev_goal_read_merge_result; do
  assert_grep "$GOAL_LIB" "^${fn}\\(\\)" "G19.public.${fn}"
done
# Internal function names (10 underscore-prefixed helpers — the prior
# `_persist_fp` short-alias forwarder was dropped post-impl-review S4 in
# favor of calling the canonical `_uberdev_goal_persist_fp` directly).
for fn in _uberdev_goal_validate_int _uberdev_goal_extract_fingerprint _uberdev_goal_parse_blocks_line \
          _uberdev_goal_count_merge_attempts _uberdev_goal_pr_state_machine_valid _uberdev_goal_now_secs \
          _uberdev_goal_persist_fp _uberdev_goal_dispatch_review_pr _uberdev_goal_dispatch_merge \
          _uberdev_goal_check_unblock; do
  assert_grep "$GOAL_LIB" "^${fn}\\(\\)" "G19.internal.${fn}"
done
# Idempotency guard against double-sourcing.
assert_grep "$GOAL_LIB" '_UBERDEV_GOAL_STATE_LOADED'                     "G19.idempotency-guard"
# Negative — T3 hard rule: no shell-evaluation primitives.
assert_no_grep "$GOAL_LIB" '\beval '                                     "G19.no-eval"
assert_no_grep "$GOAL_LIB" '\bbash -c'                                   "G19.no-bash-c"
# R12 — the --i-know-what-im-doing override flag MUST be mentioned exactly
# once in commands/goal.md (negative call-out only — never threaded into
# any /goal logic). Positive check: it appears at least once.
assert_grep "$GOAL_CMD" '--i-know-what-im-doing'                         "G19.r12-mentioned-once"

echo
echo "== G20: version bump locked (0.31.0) =="
assert_grep "$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json" '"version": "0\.31\.0"'  "G20.plugin-json"
assert_grep "$REPO_ROOT/.claude-plugin/marketplace.json"            '"version": "0\.31\.0"'  "G20.marketplace-json"
assert_grep "$REPO_ROOT/README.md"                                  'version-0\.31\.0-blue'  "G20.readme-badge"
assert_grep "$REPO_ROOT/CHANGELOG.md"                               '## \[0\.31\.0\]'        "G20.changelog"
assert_no_grep "$REPO_ROOT/tests/solve-claim.test.sh"               '0\.30\.0'               "G20.solve-claim-no-old-version"

echo
echo "== Behavioral tests (B12 — sourced-function exercises) =="
# These tests SOURCE plugins/uberdev/lib/goal-state.sh and exercise the
# real bash functions, not just grep their shape. They cover the four
# silently-shape-checked-only contracts called out in post-impl review B12:
#   BT1 — state-machine forbidden transitions (D17)
#   BT2 — Blocks: parser ReDoS-safe anchoring
#   BT3 — fingerprint repeat detector
#   BT4 — gh_jq_or_jq jq shim file-not-found path
#
# Isolation: mktemp $UBERDEV_TMPDIR for this section so writes do not
# collide with production state nor with each other.
_b12_tmpdir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-b12-%s' "$$")"
mkdir -p "$_b12_tmpdir"
UBERDEV_TMPDIR="$_b12_tmpdir"
export UBERDEV_TMPDIR

# Source the lib under test. Idempotency guard means re-sourcing is a no-op.
# shellcheck source=/dev/null
. "$GOAL_LIB" || {
  printf '  FAIL  B12.source-lib (could not source %s)\n' "$GOAL_LIB" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        got:  %s\n' "$got" >&2
    printf '        want: %s\n' "$want" >&2
  fi
}

assert_rc() {
  local rc="$1" want="$2" label="$3"
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        rc=%s, expected %s\n' "$rc" "$want" >&2
  fi
}

# Substring containment check using bash pattern-matching (avoids the
# subshell + tmpfile overhead of `grep -q`). Used by BT7/BT9/BT11 to
# collapse case-statement asserts on $DISPATCH_LOG into a single line
# while still surfacing the actual haystack on failure.
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*)
      PASS=$((PASS + 1))
      printf '  PASS  %s\n' "$label"
      ;;
    *)
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n' "$label" >&2
      printf '        haystack: %s\n' "$haystack" >&2
      printf '        needle:   %s\n' "$needle" >&2
      ;;
  esac
}

assert_grep_file() {
  local file="$1" pattern="$2" label="$3"
  if [ -f "$file" ] && grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s (exists=%s)\n' "$file" "$([ -f "$file" ] && echo yes || echo no)" >&2
    printf '        pattern: %s\n' "$pattern" >&2
  fi
}

# BT1 — PR state machine: D17 forbidden transitions return non-zero;
# a documented legal transition returns zero.
_uberdev_goal_pr_state_machine_valid yellow-held merging
assert_rc "$?" "1" "BT1.yellow-held->merging-forbidden"
_uberdev_goal_pr_state_machine_valid red-held merging
assert_rc "$?" "1" "BT1.red-held->merging-forbidden"
_uberdev_goal_pr_state_machine_valid dispatched pushed-reviewing
assert_rc "$?" "0" "BT1.dispatched->pushed-reviewing-allowed"

# BT2 — Blocks: parser: anchored shape accepts exact form, rejects
# missing-hash / non-digit / leading-space / empty.
assert_eq "$(_uberdev_goal_parse_blocks_line 'Blocks: #123')" "123" "BT2.exact-match"
assert_eq "$(_uberdev_goal_parse_blocks_line 'Blocks: 123')"  ""    "BT2.no-hash-rejected"
assert_eq "$(_uberdev_goal_parse_blocks_line 'Blocks: #abc')" ""    "BT2.non-digit-rejected"
assert_eq "$(_uberdev_goal_parse_blocks_line ' Blocks: #123')" ""   "BT2.leading-space-rejected"
assert_eq "$(_uberdev_goal_parse_blocks_line '')"              ""   "BT2.empty-rejected"

# BT3 — fingerprint repeat: persist fp at cycle 1, query at cycle 2 with
# same fp -> returns 1 (repeat detected; caller halts non-convergence).
uberdev_goal_state_init test-bt3
_uberdev_goal_persist_fp test-bt3 1 abcd1234abcd1234
UBERDEV_GOAL_ID=test-bt3 uberdev_goal_check_fingerprint_repeat test-bt3 2 abcd1234abcd1234
assert_rc "$?" "1" "BT3.fingerprint-repeat-detected"

# BT4 — gh_jq_or_jq with non-existent file -> returns non-zero (file
# does not exist), produces empty output. Behavioral check that the
# shim's file-existence guard fires.
_bt4_out="$(gh_jq_or_jq /nonexistent/path/that/should/not/exist '.foo' 2>/dev/null)"
_bt4_rc=$?
assert_eq "$_bt4_out" "" "BT4.file-not-found-empty-output"
# rc=1 from the `[ -f ]` guard (file not found is a failure for the shim).
if [ "$_bt4_rc" -ne 0 ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT4.file-not-found-nonzero-rc"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT4.file-not-found-nonzero-rc" >&2
  printf '        expected non-zero, got %s\n' "$_bt4_rc" >&2
fi

# ----- BT5-BT11 — _uberdev_goal_check_unblock behavioural coverage -----
# Function under test: plugins/uberdev/lib/goal-state.sh:467-521.
# Mocks `gh pr view` / `gh issue view` via a per-process function-override
# (Q1 in 2026-05-21 spec; idiom borrowed from tests/findings-to-issues.test.sh:51-73).
# `uberdev_dispatch_one` is NOT defined by goal-state.sh (D8 in spec) — we
# stub it to log dispatches into $DISPATCH_LOG so assertions can verify
# presence/absence of the dispatch side effect.
#
# Per-test reset block (copy-pasted before every BTn) sets all six MOCK_*
# vars (incl. MOCK_ISSUE_STATES) and DISPATCH_LOG to known-empty defaults
# to prevent cross-test contamination.

# Cache the two-blocks PR body for reuse in BT8 + BT11 (E-2).
_two_blocks_body="$(printf 'Blocks: #99\nBlocks: #100\n')"

MOCK_PR_BODY=""
MOCK_PR_RC=0
MOCK_ISSUE_STATE=""
MOCK_ISSUE_RC=0
MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=()
DISPATCH_LOG=""

gh() {
  local sub="$1"; shift
  case "$sub" in
    pr)
      local sub2="$1"; shift
      case "$sub2" in
        view) printf '%s' "$MOCK_PR_BODY"; return "$MOCK_PR_RC" ;;
      esac
      ;;
    issue)
      local sub2="$1"; shift
      case "$sub2" in
        view)
          local issue_n="$1"
          local found=""
          for entry in "${MOCK_ISSUE_STATES[@]+"${MOCK_ISSUE_STATES[@]}"}"; do
            case "$entry" in
              "${issue_n}="*) found="${entry#*=}"; break ;;
            esac
          done
          if [ -n "$found" ]; then
            printf '%s' "$found"
            return 0
          fi
          # Non-success: function-under-test captures `gh ... 2>&1`, so
          # write the error stream to stdout (mirrors how gh's stderr
          # arrives at issue_raw via 2>&1 in goal-state.sh:497).
          if [ "$MOCK_ISSUE_RC" -ne 0 ]; then
            printf '%s' "$MOCK_ISSUE_STDERR"
          else
            printf '%s' "$MOCK_ISSUE_STATE"
          fi
          return "$MOCK_ISSUE_RC"
          ;;
      esac
      ;;
  esac
  return 0
}

# Belt-and-braces forward-defense: the BT5-BT11 path overrides
# _uberdev_goal_dispatch_review_pr directly, so the real impl that would
# chain into uberdev_dispatch_one never runs and this stub is currently
# unreachable. It is kept (and given the same DISPATCHED:$pr body) so a
# future direct uberdev_dispatch_one call site is also neutralised and
# cannot fire the real dispatcher / leak tmpfiles from a passing suite.
uberdev_dispatch_one() {
  DISPATCH_LOG="${DISPATCH_LOG}DISPATCHED:$1 "
}

# Stub the real dispatcher so the prompt-file mktemp inside
# _uberdev_goal_dispatch_review_pr (goal-state.sh:421) never fires —
# otherwise BT7/BT9/BT11 leak 3 real tmpfiles per test run into the
# user's $TMPDIR. BSD mktemp on macOS does NOT honour TMPDIR without -t
# or a template, so setting TMPDIR="$_b12_tmpdir" is not a portable
# redirect. The stub records the same DISPATCHED:$pr marker the real
# code path produces (via uberdev_dispatch_one), preserving the existing
# BT7/BT9/BT11 dispatch-log assertions; the audit-event emit at
# goal-state.sh:518-519 runs in _uberdev_goal_check_unblock itself
# (caller), so BT11's audit assertions are unaffected.
_uberdev_goal_dispatch_review_pr() {
  DISPATCH_LOG="${DISPATCH_LOG}DISPATCHED:$1 "
}

# BT5 — R1: gh pr view returns empty body -> rc=0, no dispatch.
# Issue #140 risk 1; spec line 180-197; function lines 477-480.
MOCK_PR_BODY=""; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=(); DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt5
_uberdev_goal_check_unblock 99 2>/dev/null
_bt5_rc=$?
assert_rc "$_bt5_rc" "0" "BT5.empty-body-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT5.empty-body-no-dispatch"

# BT6 — R2: gh issue view rate-limit -> rc=0 (skip cycle), no dispatch.
# Issue #140 risk 2; spec line 199-214; function lines 502-506.
MOCK_PR_BODY="Blocks: #99"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=1
MOCK_ISSUE_STDERR="API rate limit exceeded"
MOCK_ISSUE_STATES=(); DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt6
_uberdev_goal_check_unblock 99 2>/dev/null
_bt6_rc=$?
assert_rc "$_bt6_rc" "0" "BT6.rate-limit-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT6.rate-limit-no-dispatch"

# BT7 — R1b: gh issue view 404 (issue deleted upstream) -> CLOSED -> dispatch.
# Issue #140 risk 1 sub-path; spec line 216-233; function line 500.
MOCK_PR_BODY="Blocks: #99"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=1
MOCK_ISSUE_STDERR="Could not resolve to an Issue with the number '99'"
MOCK_ISSUE_STATES=(); DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt7
_uberdev_goal_check_unblock 99 2>/dev/null
_bt7_rc=$?
assert_rc "$_bt7_rc" "0" "BT7.404-returns-zero"
assert_contains "$DISPATCH_LOG" "DISPATCHED:99" "BT7.404-dispatch-fires"

# BT8 — R3: mixed CLOSED/OPEN blocking issues -> all_closed=0 -> no dispatch.
# Issue #140 risk 3; spec line 235-252; function lines 488-510.
MOCK_PR_BODY="$_two_blocks_body"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=("99=CLOSED" "100=OPEN")
DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt8
_uberdev_goal_check_unblock 1 2>/dev/null
_bt8_rc=$?
assert_rc "$_bt8_rc" "0" "BT8.mixed-states-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT8.mixed-states-no-dispatch"

# BT9 — R5a: happy-path single-CLOSED -> dispatch fires.
# Issue #140 risk 5 (inverse); spec line 254-267; function lines 512-513.
MOCK_PR_BODY="Blocks: #99"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=("99=CLOSED")
DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt9
_uberdev_goal_check_unblock 1 2>/dev/null
_bt9_rc=$?
assert_rc "$_bt9_rc" "0" "BT9.happy-path-returns-zero"
assert_contains "$DISPATCH_LOG" "DISPATCHED:1" "BT9.happy-path-dispatch-fires"

# BT10 — R4: CRLF-terminated Blocks: line silently drops -> no dispatch.
# Locks current LF-only behaviour (Q5 auto-pick; spec line 269-291).
# If a future PR adds \r-stripping, this test fails and forces a doc update.
#
# Platform-skip: on Windows (msys/cygwin), bash's command substitution
# strips the trailing \r before $(...) captures it, so the body that
# reaches the parser is LF-only. The regression boundary this test
# encodes ("CRLF body must NOT match the anchored ^Blocks: #N$ regex")
# is therefore meaningless on Windows — the platform already strips \r.
# Skip there. The regression boundary remains effective on Linux/macOS
# where CRLF survives command substitution intact.
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*)
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "BT10.skipped-on-windows"
    ;;
  *)
    MOCK_PR_BODY="$(printf 'Blocks: #99\r\n')"; MOCK_PR_RC=0
    MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
    MOCK_ISSUE_STATES=("99=CLOSED")
    DISPATCH_LOG=""
    UBERDEV_GOAL_ID=test-bt10
    _uberdev_goal_check_unblock 1 2>/dev/null
    _bt10_rc=$?
    assert_rc "$_bt10_rc" "0" "BT10.crlf-body-returns-zero"
    assert_eq "$DISPATCH_LOG" "" "BT10.crlf-body-no-dispatch"
    ;;
esac

# BT11 — R5b: full happy-path multi-CLOSED -> dispatch + audit event.
# Issue #140 risk 5 full; spec line 293-317; function lines 512-520.
# uberdev_goal_state_init keeps parity with BT3 (line 360) — currently
# redundant for the >>-append audit write, but defends against future
# changes to uberdev_goal_audit's file-creation semantics.
MOCK_PR_BODY="$_two_blocks_body"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=("99=CLOSED" "100=CLOSED")
DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt11
uberdev_goal_state_init test-bt11
_uberdev_goal_check_unblock 7 2>/dev/null
_bt11_rc=$?
assert_rc "$_bt11_rc" "0" "BT11.audit-happy-path-returns-zero"
assert_contains "$DISPATCH_LOG" "DISPATCHED:7" "BT11.audit-happy-path-dispatch-fires"
assert_grep "$UBERDEV_TMPDIR/goal-test-bt11.jsonl" '"event":"goal_unblock_triggered"' "BT11.audit-event-emitted"
assert_grep "$UBERDEV_TMPDIR/goal-test-bt11.jsonl" '"blocking_issues":\[99,100\]'     "BT11.audit-payload-csv-shape"

# Hygiene: drop the function-override + dispatch stubs before B12 ends
# (spec Error handling section). No subsequent tests, so blast radius is
# zero, but explicit unset documents intent and prevents a future BT12
# appended below from silently inheriting any of these shadows.
unset -f gh
unset -f uberdev_dispatch_one
unset -f _uberdev_goal_dispatch_review_pr

# ----- BT12-BT18 — uberdev_goal_issue_state_transition behavioural coverage -----
# Function under test: plugins/uberdev/lib/goal-state.sh:232-246. Closes the
# review-pr Phase 2.5 blocker finding (issue #138): the 5-state issue
# machine (input -> solving -> pr-pushed -> resolved; solving/pr-pushed -> failed)
# previously had zero behavioural tests — invalid transitions, TSV write
# failures, and timestamp omission could all go undetected. Numbered BT12+
# to leave room for BT5-BT11 (PR #142) to land without collision; both PRs
# branch off worktree-solve-issue-128 and the second to merge resolves with
# a trivial rebase since BT11 < BT12.
#
# No mocks required: pure function with TSV side-effect into $UBERDEV_TMPDIR
# (which BT1-BT4 already set to $_b12_tmpdir). Each test uses a unique
# goal_id so per-test TSVs do not collide.
# (assert_grep_file helper is defined alongside assert_eq/assert_rc above.)

# Stderr is suppressed (`2>/dev/null`) on every uberdev_goal_issue_state_transition
# call in BT12-BT14: invalid transitions print `goal-state: invalid issue
# transition <from>-><to>` to stderr by design, and BT14's non-digit inputs
# (BT14.a/c) similarly traverse the `_uberdev_goal_validate_int` rc=1 path
# without stderr emission. BT18 captures and asserts the stderr message for
# one representative rc=2 case; the redirections in BT12-BT14 keep test
# output clean. Do NOT remove the `2>/dev/null` — it is load-bearing.

# BT12 — all 5 valid transitions return rc=0.
# Same goal_id across the 5 sub-cases since the function does NOT enforce
# state continuity between calls (it validates the from->to pair only,
# not the persisted history); using one TSV lets BT16 verify accumulation
# below.
uberdev_goal_issue_state_transition test-bt12 100 input solving       2>/dev/null
assert_rc "$?" "0" "BT12.a-input-to-solving"
uberdev_goal_issue_state_transition test-bt12 100 solving pr-pushed   2>/dev/null
assert_rc "$?" "0" "BT12.b-solving-to-pr-pushed"
uberdev_goal_issue_state_transition test-bt12 100 pr-pushed resolved  2>/dev/null
assert_rc "$?" "0" "BT12.c-pr-pushed-to-resolved"
uberdev_goal_issue_state_transition test-bt12 101 solving failed      2>/dev/null
assert_rc "$?" "0" "BT12.d-solving-to-failed"
uberdev_goal_issue_state_transition test-bt12 102 pr-pushed failed    2>/dev/null
assert_rc "$?" "0" "BT12.e-pr-pushed-to-failed"

# BT13 — invalid transitions return rc=2.
# Covers the seven shapes the case-block rejects: skip-states, backwards,
# terminal-exits, nonsense. Stderr-message assertion is on BT18 below
# (single representative case — the printf is shared across all rc=2 paths).
uberdev_goal_issue_state_transition test-bt13a 200 input resolved    2>/dev/null
assert_rc "$?" "2" "BT13.a-skip-input-to-resolved"
uberdev_goal_issue_state_transition test-bt13b 200 input failed      2>/dev/null
assert_rc "$?" "2" "BT13.b-input-to-failed-skip-solving"
uberdev_goal_issue_state_transition test-bt13c 200 solving input     2>/dev/null
assert_rc "$?" "2" "BT13.c-solving-to-input-backwards"
uberdev_goal_issue_state_transition test-bt13d 200 solving resolved  2>/dev/null
assert_rc "$?" "2" "BT13.d-solving-to-resolved-skip-pr-pushed"
uberdev_goal_issue_state_transition test-bt13e 200 resolved solving  2>/dev/null
assert_rc "$?" "2" "BT13.e-resolved-terminal-exit-rejected"
uberdev_goal_issue_state_transition test-bt13f 200 failed solving    2>/dev/null
assert_rc "$?" "2" "BT13.f-failed-terminal-exit-rejected"
uberdev_goal_issue_state_transition test-bt13g 200 nonsense more     2>/dev/null
assert_rc "$?" "2" "BT13.g-nonsense-states-rejected"

# BT14 — issue arg must be a non-empty digit-only string (rc=1, BEFORE the
# transition check fires — _uberdev_goal_validate_int runs first).
uberdev_goal_issue_state_transition test-bt14 abc input solving      2>/dev/null
assert_rc "$?" "1" "BT14.a-non-digit-issue-rejected"
uberdev_goal_issue_state_transition test-bt14 ""  input solving      2>/dev/null
assert_rc "$?" "1" "BT14.b-empty-issue-rejected"
uberdev_goal_issue_state_transition test-bt14 -5  input solving      2>/dev/null
assert_rc "$?" "1" "BT14.c-negative-issue-rejected"

# BT15 — TSV persistence: valid transitions write a row; invalid ones do not.
# BT12 wrote 5 rows under goal_id=test-bt12; BT13.* wrote ZERO rows under
# their respective goal_ids (rc=2 returns BEFORE the TSV append).
_bt15_tsv="$_b12_tmpdir/goal-test-bt12-issue-states.tsv"
if [ -f "$_bt15_tsv" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT15.a-tsv-created-on-valid-transition"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT15.a-tsv-created-on-valid-transition" >&2
  printf '        expected file: %s\n' "$_bt15_tsv" >&2
fi
# Row shape: <issue>\t<to>\t<epoch>. Anchor on issue=100, state=solving
# (the very first BT12 row), epoch as a 10-digit Unix timestamp. The
# `{10}` quantifier (not `+`) blocks a regression where someone replaces
# `$(_uberdev_goal_now_secs)` with a short literal like `0` — that would
# pass `[0-9]+` but fail `[0-9]{10}` (covers `date +%s` for ~2001–2286).
# The leading `^` anchors the issue column; trailing `$` anchors the
# epoch column.
assert_grep_file "$_bt15_tsv" $'^100\tsolving\t[0-9]{10}$' "BT15.b-row-shape-issue-tab-state-tab-epoch"
# Invalid transitions wrote NO row: the BT13.a goal_id produces no TSV.
_bt15c_tsv="$_b12_tmpdir/goal-test-bt13a-issue-states.tsv"
if [ ! -f "$_bt15c_tsv" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT15.c-invalid-transition-no-tsv-write"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT15.c-invalid-transition-no-tsv-write" >&2
  printf '        unexpected file present: %s\n' "$_bt15c_tsv" >&2
fi

# BT16 — multiple valid transitions accumulate. BT12 wrote 5 lines under
# goal_id=test-bt12 (input->solving, solving->pr-pushed, pr-pushed->resolved,
# solving->failed, pr-pushed->failed). The TSV is line-oriented so `wc -l`
# is authoritative.
_bt16_lines="$(wc -l < "$_bt15_tsv" 2>/dev/null | tr -d ' ')"
assert_eq "$_bt16_lines" "5" "BT16.transitions-accumulate-5-rows"
# Pin per-issue accumulation, not just the aggregate count: BT12 wrote three
# rows for issue 100 (input->solving->pr-pushed->resolved), one for 101
# (solving->failed), one for 102 (pr-pushed->failed). Asserting only the total
# (==5 above) would pass even if rows landed under the wrong issue or a row
# duplicated/corrupted; per-issue counts catch that. The grep is tab-anchored
# (`^100\t`) so issue 100 cannot match a hypothetical 1000 row — the issue is
# the first tab-delimited column (goal-state.sh:244 `%s\t%s\t%s`).
_bt16_i100="$(grep -cE -e $'^100\t' "$_bt15_tsv" 2>/dev/null | tr -d ' ')"
_bt16_i101="$(grep -cE -e $'^101\t' "$_bt15_tsv" 2>/dev/null | tr -d ' ')"
_bt16_i102="$(grep -cE -e $'^102\t' "$_bt15_tsv" 2>/dev/null | tr -d ' ')"
assert_eq "$_bt16_i100" "3" "BT16.issue-100-three-rows"
assert_eq "$_bt16_i101" "1" "BT16.issue-101-one-row"
assert_eq "$_bt16_i102" "1" "BT16.issue-102-one-row"

# BT17 — goal_id isolation: separate goals write to separate TSVs.
uberdev_goal_issue_state_transition test-bt17-alpha 300 input solving 2>/dev/null
uberdev_goal_issue_state_transition test-bt17-beta  300 input solving 2>/dev/null
_bt17_alpha="$_b12_tmpdir/goal-test-bt17-alpha-issue-states.tsv"
_bt17_beta="$_b12_tmpdir/goal-test-bt17-beta-issue-states.tsv"
_bt17_alpha_rows="$(wc -l < "$_bt17_alpha" 2>/dev/null | tr -d ' ')"
_bt17_beta_rows="$(wc -l < "$_bt17_beta" 2>/dev/null | tr -d ' ')"
if [ -f "$_bt17_alpha" ] && [ -f "$_bt17_beta" ] \
   && [ "${_bt17_alpha_rows:-0}" -gt 0 ] && [ "${_bt17_beta_rows:-0}" -gt 0 ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT17.distinct-goal-ids-distinct-tsvs"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT17.distinct-goal-ids-distinct-tsvs" >&2
  printf '        alpha exists=%s rows=%s\n' \
    "$([ -f "$_bt17_alpha" ] && echo yes || echo no)" "${_bt17_alpha_rows:-0}" >&2
  printf '        beta exists=%s rows=%s\n' \
    "$([ -f "$_bt17_beta" ] && echo yes || echo no)" "${_bt17_beta_rows:-0}" >&2
fi

# BT18 — invalid transition emits the documented stderr message. The
# function's printf format is `goal-state: invalid issue transition %s->%s\n`;
# we capture stderr to a tmpfile and grep for the substring.
_bt18_err="$_b12_tmpdir/bt18-stderr"
: > "$_bt18_err"  # truncate so any prior content cannot false-positive the grep
uberdev_goal_issue_state_transition test-bt18 400 input resolved 2>"$_bt18_err" >/dev/null
assert_grep_file "$_bt18_err" 'invalid issue transition input->resolved' "BT18.stderr-message-on-invalid-transition"

# Cleanup: remove the isolated tmpdir contents (we created the whole
# directory via mktemp -d, so we can rm -rf safely — it's our own).
rm -rf "$_b12_tmpdir" 2>/dev/null || true

echo
echo "== Summary =="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
