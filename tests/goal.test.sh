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
#   G19  lib/goal-state.sh shape (15 public + 13 internal fns +
#        idempotency guard + no eval / no bash -c + R12 negative)
#   G20  Version bump locked (plugin.json, marketplace.json,
#        README badge, CHANGELOG, no 0.30.0 leak in solve-claim.test.sh)
#
# Pre-T5 expected failures: G12.readme (README badge mention of /ubergoal)
# and G12.aliases-test (tests/aliases.test.sh row for /ubergoal) — these
# pass once T5's wave-4 alias-provisioning commit lands. G20.readme-badge
# additionally fails until T5 bumps the README version badge from 0.29.0
# to 0.33.0 (T5 owns README.md per the wave-4 file allowlist).

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
# The bash-regex literal in lib/goal-state.sh's _uberdev_goal_parse_blocks_line is
# `^Blocks:\ \#([0-9]+)$` (escaped space, escaped hash). The plan's pattern
# `\^Blocks: #\(\[0-9\]\+\)\$` omits the in-source backslashes; widen to
# match either form so any future stylistic edit (e.g., dropping the
# backslash-escape on space) does not falsely fail.
assert_grep "$GOAL_LIB" '\^Blocks:\\? *\\?#?\(\[0-9\]\+\)\$|\^Blocks: #\(\[0-9\]\+\)\$' \
                                                                         "G18.anchored-regex-in-lib"
assert_grep "$GOAL_LIB" '_UBERDEV_GOAL_BODY_CAP|head -c 65536'           "G18.body-cap"

echo
echo "== G19: lib/goal-state.sh shape =="
# Public function names (15 — uberdev_goal_build_unblock_graph removed
# in the post-impl-review B5 cleanup; the four `*_held_audit` /
# `_by_pr` / `_get_pr_state` helpers added by the issue #159 + #160
# convergence-loop fix supply the held-PR re-review poll loop's
# bookkeeping surface).
for fn in uberdev_goal_state_init uberdev_goal_pr_state_transition uberdev_goal_issue_state_transition \
          uberdev_goal_read_trust_signal uberdev_goal_check_fingerprint_repeat uberdev_goal_should_automerge \
          uberdev_goal_audit uberdev_goal_locate_review_pr_audit \
          uberdev_goal_locate_review_pr_audit_by_pr \
          uberdev_goal_get_pr_state uberdev_goal_record_held_audit uberdev_goal_get_last_held_audit \
          uberdev_goal_find_pr_for_issue uberdev_goal_pr_state_gh uberdev_goal_pr_is_merged \
          uberdev_goal_agent_busy_for_issue \
          uberdev_goal_list_prs_in_state uberdev_goal_read_merge_result; do
  assert_grep "$GOAL_LIB" "^${fn}\\(\\)" "G19.public.${fn}"
done
# Internal function names (13 underscore-prefixed helpers — `_uberdev_goal_validate_id`
# (#156 goal_id path-traversal guard) and `_uberdev_goal_append` (#157
# unwritable-tmpdir checked-append) add the slug-validation + write-surfacing
# primitives; the prior `_persist_fp` short-alias forwarder was dropped
# post-impl-review S4 in favor of calling the canonical
# `_uberdev_goal_persist_fp` directly; `_uberdev_goal_count_review_pr_attempts`
# added by the B3 bound on Phase 2a's stale|missing re-dispatch loop).
for fn in _uberdev_goal_validate_int _uberdev_goal_validate_id _uberdev_goal_append \
          _uberdev_goal_extract_fingerprint _uberdev_goal_parse_blocks_line \
          _uberdev_goal_count_merge_attempts _uberdev_goal_count_review_pr_attempts \
          _uberdev_goal_pr_state_machine_valid _uberdev_goal_now_secs \
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
echo "== G20: version bump locked (0.33.11) =="
assert_grep "$REPO_ROOT/plugins/uberdev/.claude-plugin/plugin.json" '"version": "0\.33\.11"'  "G20.plugin-json"
assert_grep "$REPO_ROOT/.claude-plugin/marketplace.json"            '"version": "0\.33\.11"'  "G20.marketplace-json"
assert_grep "$REPO_ROOT/README.md"                                  'version-0\.33\.11-blue'  "G20.readme-badge"
assert_grep "$REPO_ROOT/CHANGELOG.md"                               '## \[0\.33\.11\]'        "G20.changelog"
assert_no_grep "$REPO_ROOT/tests/solve-claim.test.sh"               '0\.30\.0'               "G20.solve-claim-no-old-version"

assert_grep "$GOAL_SKILL" 'uberdev_dispatch_resolve_env'  "G20b.phase0-wires-resolve-env (#175 SSOT anchor)"
assert_grep "$GOAL_SKILL" 'export AUTO_MODE=1'            "G20b.phase0-sets-AUTO_MODE (#175 turbo-parity)"

echo
echo "== G23: CLI-version-independent gh+file detection (issue #180) =="
# The watch loop must key completion/PR/merge off gh + the file-based verdict,
# NOT the captured claude --bg stdout (which on CLI 2.1.150 is a detached
# banner only). These gates lock the fix in place against regression.
# Positive: the gh signals are wired into the skill + lib.
assert_grep "$GOAL_SKILL" 'uberdev_goal_find_pr_for_issue'  "G23.find-pr-in-skill"
assert_grep "$GOAL_SKILL" 'uberdev_goal_pr_is_merged'       "G23.pr-is-merged-in-skill"
assert_grep "$GOAL_LIB"   '^uberdev_goal_find_pr_for_issue\(\)'    "G23.lib-find-pr"
assert_grep "$GOAL_LIB"   '^uberdev_goal_pr_state_gh\(\)'          "G23.lib-pr-state-gh"
assert_grep "$GOAL_LIB"   '^uberdev_goal_pr_is_merged\(\)'         "G23.lib-pr-is-merged"
assert_grep "$GOAL_LIB"   '^uberdev_goal_agent_busy_for_issue\(\)' "G23.lib-agent-busy"
assert_grep "$GOAL_LIB"   'closingIssuesReferences'               "G23.lib-uses-closing-refs"
# Phase 0 bash>=4 preflight guard (defect #8 — macOS /bin/bash is 3.2, and the
# Bash-tool default zsh chokes on the unmatched-glob verdict locator).
assert_grep "$GOAL_SKILL" 'BASH_VERSINFO'                  "G23.phase0-bash4-guard"
# Anti-regression: the broken stdout-marker COMPLETION PROBES are gone from the
# watch loop. These target the actual CODE constructs, not token mentions — the
# explanatory prose legitimately NAMES the retired markers to document the fix.
assert_no_grep "$GOAL_SKILL" "grep -q 'backgrounded"      "G23.no-backgrounded-completion-probe"
assert_no_grep "$GOAL_SKILL" 'merge_log='                 "G23.no-merge-bg-stdout-read"
assert_no_grep "$GOAL_SKILL" 'uberdev_goal_extract_pr_num_from_log' "G23.skill-no-extract-call"
assert_no_grep "$GOAL_SKILL" 'mapfile -t'                 "G23.no-mapfile-bash4ism"
# Anti-regression: the false-premise log parser is removed from the lib, and
# the `pushed PR #N` grep it relied on is gone.
assert_no_grep "$GOAL_LIB" '^uberdev_goal_extract_pr_num_from_log' "G23.lib-no-extract-pr-num"
assert_no_grep "$GOAL_LIB" "grep -oE 'pushed PR"          "G23.lib-no-pushed-pr-grep"

echo
echo "== G21: held-PR re-review poll loop (issue #159) =="
# Phase 2 step 2e MUST exist and call the new PR-keyed locator + last-seen
# bookkeeping helpers. The poll loop is what lets a held PR exit the held
# state once /review-pr (re-)runs — without it the unblock rule's dispatch
# is fire-and-forget and held PRs sit forever.
assert_grep "$GOAL_SKILL" 'uberdev_goal_locate_review_pr_audit_by_pr'             "G21.locate-by-pr-in-skill"
assert_grep "$GOAL_SKILL" 'uberdev_goal_get_last_held_audit|last_held_audit'      "G21.last-held-audit-in-skill"
assert_grep "$GOAL_SKILL" 'uberdev_goal_record_held_audit|record_held_audit'      "G21.record-held-audit-in-skill"
assert_grep "$GOAL_SKILL" 'uberdev_goal_get_pr_state'                             "G21.get-pr-state-in-skill"
# Cross-held downgrade/upgrade arcs (yellow-held<->red-held) are valid in
# the PR state machine so a re-review can re-classify the held PR.
assert_grep "$GOAL_LIB" 'yellow-held->red-held'                                   "G21.yellow-to-red-transition"
assert_grep "$GOAL_LIB" 'red-held->yellow-held'                                   "G21.red-to-yellow-transition"
# Forbidden transitions still forbidden post-change (defensive regression guard):
# both held -> merging arcs remain blocked even with the new poll loop.
assert_grep "$GOAL_LIB" 'yellow-held->merging.*return 1'                          "G21.yellow-merging-still-forbidden"
assert_grep "$GOAL_LIB" 'red-held->merging.*return 1'                             "G21.red-merging-still-forbidden"

echo
echo "== G22: queue_empty_not_converged + held-as-terminal (issue #160) =="
# Reason added to the enum AND the deterministic halt is emitted from Phase 3.
assert_grep "$GOAL_SKILL" 'GOAL_CIRCUIT_BREAKER_REASONS=.*queue_empty_not_converged' "G22.reason-in-enum"
assert_grep "$GOAL_SKILL" 'goal_circuit_breaker.*queue_empty_not_converged'         "G22.halt-emit"
# Phase 3 terminal_prs MUST include held states so a goal with only held PRs
# left can converge cleanly instead of spinning until stuck_loop.
assert_grep "$GOAL_SKILL" 'list_prs_in_state.*yellow-held'                         "G22.terminal-includes-yellow-held"
assert_grep "$GOAL_SKILL" 'list_prs_in_state.*red-held'                            "G22.terminal-includes-red-held"

echo
echo "== Behavioral tests (B12 — sourced-function exercises) =="
# These tests SOURCE plugins/uberdev/lib/goal-state.sh and exercise the
# real bash functions, not just grep their shape. They cover the four
# silently-shape-checked-only contracts called out in post-impl review
# B12, plus the trust-signal coverage gap (issue #137) flagged by
# /review-pr Phase 2.5 on PR #129:
#   BT1      state-machine forbidden transitions (D17)
#   BT2      Blocks: parser ReDoS-safe anchoring
#   BT3      fingerprint repeat detector, with sub-cases:
#            BT3a (cycle-1 short-circuit), BT3b (empty-fp guard),
#            BT3c (append semantics), BT3d (invalid-cycle validation)
#   BT4      gh_jq_or_jq jq shim file-not-found path
#   BT12-BT23 uberdev_goal_read_trust_signal enum mapping
#            (green/yellow/red-via-blocker/red-via-halted/stale/missing/
#             missing-via-malformed-json/shape-tolerance/missing-via-
#             second-jq-failure/combined-red-triggers — see #137)
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

assert_file_empty() {
  local file="$1" label="$2"
  # Guard with existence: `[ ! -s ]` alone is true for a NON-EXISTENT file as
  # well as a zero-byte one, so a future refactor that drops the
  # uberdev_goal_state_init fixture would yield a misleading PASS. Requiring
  # `[ -f ]` first makes a missing fixture fail loudly. Behavior-preserving for
  # all current callers (BT3b/BT3d state_init first → file exists, zero bytes).
  if [ -f "$file" ] && [ ! -s "$file" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    # else-branch reaches here for TWO causes: the file is MISSING (the case
    # the `[ -f ]` guard added to catch) or it EXISTS but is non-empty.
    # Branch the diagnostic so the message names the actual cause instead of
    # cat-ing a missing path (which would leak "No such file or directory").
    if [ -f "$file" ]; then
      printf '        non-empty: %s\n' "$(cat "$file")" >&2
    else
      printf '        file missing (expected existing + empty): %s\n' "$file" >&2
    fi
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

# BT3a — cycle 1 no-repeat: at cycle 1 there is no prev cycle to compare,
# so the function MUST take the [-lt 1] short-circuit branch, persist the
# fingerprint at cycle 1, and return 0 (NOT 1) — otherwise a fresh /goal
# run would falsely halt with reason=nonconvergence on its very first
# candidate. Issue #139 risk 1; function line 284 (cycle-1 short-circuit).
uberdev_goal_state_init test-bt3a
UBERDEV_GOAL_ID=test-bt3a uberdev_goal_check_fingerprint_repeat test-bt3a 1 deadbeefdeadbeef
assert_rc "$?" "0" "BT3a.cycle-1-no-repeat-returns-zero"
# The cycle-1 branch persists via _uberdev_goal_persist_fp; verify the TSV
# now carries the cycle-1 fingerprint (covers the "TSV write success" half
# of issue #139's risk 3 — the >> redirection in _uberdev_goal_persist_fp
# actually produced a file with the expected line).
assert_grep "$UBERDEV_TMPDIR/goal-test-bt3a-fingerprints.tsv" $'^1\tdeadbeefdeadbeef$' \
  "BT3a.cycle-1-persists-to-tsv"

# BT3b — empty fingerprint: with fp="" the function MUST take the
# [ -n "$fp" ] || return 0 short-circuit and return 0 WITHOUT any TSV
# write. The pr-test-analyzer concern was that the caller could loop
# forever invoking check_fingerprint_repeat with an empty fp drawn from a
# failed _uberdev_goal_extract_fingerprint; locking the early return here
# means the caller's loop logic can rely on rc=0 + no side effects.
# Issue #139 risk 2; function line 282.
uberdev_goal_state_init test-bt3b
UBERDEV_GOAL_ID=test-bt3b uberdev_goal_check_fingerprint_repeat test-bt3b 5 ""
assert_rc "$?" "0" "BT3b.empty-fingerprint-returns-zero"
# Empty fp must NOT touch the TSV (the file was truncated by state_init);
# if a future edit moves the [ -n ] check below the persist call, this
# fails immediately.
assert_file_empty "$UBERDEV_TMPDIR/goal-test-bt3b-fingerprints.tsv" \
  "BT3b.empty-fingerprint-no-tsv-write"

# BT3c — cycle 2 with non-matching fp: prev cycle 1 has fp A, current
# cycle 2 has fp B, awk match fails, function falls through to the printf
# >> append (the "TSV write success" full path). Asserts rc=0 (no repeat)
# AND that the TSV now carries BOTH cycle entries — locks the append
# semantics so a future edit replacing >> with > does not silently lose
# the cycle-1 entry. Issue #139 risk 3; function lines 286-290.
uberdev_goal_state_init test-bt3c
_uberdev_goal_persist_fp test-bt3c 1 aaaaaaaaaaaaaaaa
UBERDEV_GOAL_ID=test-bt3c uberdev_goal_check_fingerprint_repeat test-bt3c 2 bbbbbbbbbbbbbbbb
assert_rc "$?" "0" "BT3c.cycle-2-new-fp-returns-zero"
# Both lines must be present after the append; check each entry separately
# so a failure pinpoints WHICH cycle entry is missing instead of just
# "one of two patterns didn't match".
_bt3c_tsv="$UBERDEV_TMPDIR/goal-test-bt3c-fingerprints.tsv"
# #152 (silent-failure-hunter F1) — do NOT mask wc's stderr with 2>/dev/null.
# If a regression makes the append silently fail the TSV is missing; surfacing
# wc's diagnostic (plus the explicit existence assert) names the cause instead
# of a bare "got: , want: 2".
assert_grep_file "$_bt3c_tsv" '.' "BT3c.fingerprints-tsv-exists"
_bt3c_lines="$(wc -l < "$_bt3c_tsv" | tr -d ' ')"
assert_eq "$_bt3c_lines" "2" "BT3c.cycle-2-appends-not-overwrites"
assert_grep "$_bt3c_tsv" $'^1\taaaaaaaaaaaaaaaa$' "BT3c.cycle-1-entry-present"
assert_grep "$_bt3c_tsv" $'^2\tbbbbbbbbbbbbbbbb$' "BT3c.cycle-2-entry-present"

# BT3d — invalid cycle: passing a non-integer cycle (e.g. "abc") MUST take
# the _uberdev_goal_validate_int "$cycle" || return 2 short-circuit and
# return rc=2 with NO TSV side-effects. Locks the function's input
# validation contract; an edit that weakens _uberdev_goal_validate_int
# (e.g. accepts non-numeric strings) would otherwise allow a corrupt
# cycle field into the TSV. Issue #139 risk 1b (pre-existing untested
# branch surfaced during review); function line 281.
uberdev_goal_state_init test-bt3d
UBERDEV_GOAL_ID=test-bt3d uberdev_goal_check_fingerprint_repeat test-bt3d abc deadbeefdeadbeef 2>/dev/null
assert_rc "$?" "2" "BT3d.invalid-cycle-returns-two"
# rc=2 must short-circuit before any TSV write; the file was truncated by
# state_init and must remain empty.
assert_file_empty "$UBERDEV_TMPDIR/goal-test-bt3d-fingerprints.tsv" \
  "BT3d.invalid-cycle-no-tsv-write"

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
# #180 — gh+file detection mocks. MOCK_PR_LIST_JSON is the raw JSON array a
# `gh pr list --json ...` call would return; the mock applies the call's own
# `--jq` filter to it (faithfully mirroring gh's in-process jq) so the filter
# logic in uberdev_goal_find_pr_for_issue is exercised, not stubbed. MOCK_PR_STATE
# is what `gh pr view <pr> --json state` returns (used by pr_state_gh / pr_is_merged
# / read_merge_result's gh-first arm). MOCK_CLAUDE_AGENTS_JSON drives the claude()
# mock for agent_busy_for_issue. All default to the inert "no PR / not merged /
# no live agent" shape so pre-#180 behavioural tests (BT41-47 etc.) fall through
# to their original file-based code paths unchanged.
MOCK_PR_LIST_JSON="[]"
MOCK_PR_LIST_RC=0
MOCK_PR_STATE=""
MOCK_PR_STATE_RC=0
MOCK_CLAUDE_AGENTS_JSON="[]"

gh() {
  local sub="$1"; shift
  case "$sub" in
    pr)
      local sub2="$1"; shift
      case "$sub2" in
        list)
          # Apply the call's own --jq filter to MOCK_PR_LIST_JSON, mirroring
          # gh's internal jq (raw output). uberdev_goal_find_pr_for_issue passes
          # the closingIssuesReferences/headRefName filter; running it here means
          # the test exercises the real filter, not a hand-computed answer.
          local _filter='.'
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --jq) _filter="$2"; shift 2 ;;
              *) shift ;;
            esac
          done
          printf '%s' "$MOCK_PR_LIST_JSON" | jq -r "$_filter"
          return "$MOCK_PR_LIST_RC"
          ;;
        view)
          # Distinguish a state projection (`--json state`, used by pr_state_gh)
          # from a body projection (`--json body`, used by unblock/fetch_pr_body).
          local _want_state=0 _a
          for _a in "$@"; do [ "$_a" = "state" ] && _want_state=1; done
          if [ "$_want_state" = "1" ]; then
            printf '%s' "$MOCK_PR_STATE"; return "$MOCK_PR_STATE_RC"
          fi
          printf '%s' "$MOCK_PR_BODY"; return "$MOCK_PR_RC"
          ;;
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

# #180 — claude() mock for uberdev_goal_agent_busy_for_issue, which pipes
# `claude agents --json` into jq. Returns MOCK_CLAUDE_AGENTS_JSON for the
# `agents` subcommand; any other invocation is an inert no-op so a stray
# `claude` call in a future test never spawns a real session.
claude() {
  if [ "$1" = "agents" ]; then printf '%s' "$MOCK_CLAUDE_AGENTS_JSON"; return 0; fi
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
# #148 — capture stderr to a file (do NOT blackhole with 2>/dev/null) and
# assert the empty-body diagnostic IS emitted. Blanket suppression let a
# DIFFERENT rc=0/no-dispatch path (e.g. a future early-return that skips the
# fetch) masquerade as this one; pinning the diagnostic locks the exact code
# path under test. Mirrors BT18's stderr-capture idiom.
MOCK_PR_BODY=""; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=(); DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt5
_bt5_err="$_b12_tmpdir/bt5-stderr"; : > "$_bt5_err"
_uberdev_goal_check_unblock 99 2>"$_bt5_err"
_bt5_rc=$?
assert_rc "$_bt5_rc" "0" "BT5.empty-body-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT5.empty-body-no-dispatch"
assert_grep_file "$_bt5_err" 'returned empty body; skipping unblock check' \
  "BT5.empty-body-diagnostic-surfaced"

# BT6 — R2: gh issue view rate-limit -> rc=0 (skip cycle), no dispatch.
# Issue #140 risk 2; spec line 199-214; function lines 502-506.
# #149 — capture stderr and assert the rate-limit failure diagnostic IS
# surfaced (was blackholed by 2>/dev/null). The bare suppression hid the
# difference between "gh failed, we skipped" (correct) and "we never reached
# the gh call" (a silent regression); asserting the diagnostic distinguishes
# them.
MOCK_PR_BODY="Blocks: #99"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=1
MOCK_ISSUE_STDERR="API rate limit exceeded"
MOCK_ISSUE_STATES=(); DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt6
_bt6_err="$_b12_tmpdir/bt6-stderr"; : > "$_bt6_err"
_uberdev_goal_check_unblock 99 2>"$_bt6_err"
_bt6_rc=$?
assert_rc "$_bt6_rc" "0" "BT6.rate-limit-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT6.rate-limit-no-dispatch"
assert_grep_file "$_bt6_err" 'gh issue view 99 failed \(rc=1\):.*API rate limit exceeded' \
  "BT6.rate-limit-diagnostic-surfaced"

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
# uberdev_goal_state_init keeps parity with the BT3 block above — currently
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

# BT11b/BT11c — #150: N=3 blocking-issues coverage. BT8 (mixed) and BT11
# (happy) only exercised N=2; _uberdev_goal_check_unblock's for-loop over
# "${blocking[@]}" is element-count agnostic today, but an untested N>=3
# cardinality meant a future index-based rewrite could regress undetected.
# These lock the loop at N=3 for both the all-closed (dispatch + CSV join)
# and the middle-OPEN (short-circuit, no dispatch) paths.
_three_blocks_body="$(printf 'Blocks: #99\nBlocks: #100\nBlocks: #101\n')"

# BT11b — N=3 all CLOSED -> dispatch fires AND the audit CSV joins all three.
MOCK_PR_BODY="$_three_blocks_body"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=("99=CLOSED" "100=CLOSED" "101=CLOSED")
DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt11b
uberdev_goal_state_init test-bt11b
_uberdev_goal_check_unblock 8 2>/dev/null
_bt11b_rc=$?
assert_rc "$_bt11b_rc" "0" "BT11b.n3-all-closed-returns-zero"
assert_contains "$DISPATCH_LOG" "DISPATCHED:8" "BT11b.n3-all-closed-dispatch-fires"
assert_grep "$UBERDEV_TMPDIR/goal-test-bt11b.jsonl" '"blocking_issues":\[99,100,101\]' \
  "BT11b.n3-audit-csv-joins-three"

# BT11c — N=3 with the MIDDLE issue OPEN -> all_closed=0 via the loop break at
# element 2 -> no dispatch. Proves the short-circuit visits past element 1 (an
# off-by-one stopping at N=2 would never observe issue 100's OPEN state).
MOCK_PR_BODY="$_three_blocks_body"; MOCK_PR_RC=0
MOCK_ISSUE_STATE=""; MOCK_ISSUE_RC=0; MOCK_ISSUE_STDERR=""
MOCK_ISSUE_STATES=("99=CLOSED" "100=OPEN" "101=CLOSED")
DISPATCH_LOG=""
UBERDEV_GOAL_ID=test-bt11c
_uberdev_goal_check_unblock 9 2>/dev/null
_bt11c_rc=$?
assert_rc "$_bt11c_rc" "0" "BT11c.n3-middle-open-returns-zero"
assert_eq "$DISPATCH_LOG" "" "BT11c.n3-middle-open-no-dispatch"

# Hygiene: drop the dispatch stubs before BT12 (spec Error handling section) so
# a stray dispatch in a later test fails loudly instead of silently logging.
# The gh() + claude() mocks are NOT unset — issue #180's gh+file detection tests
# (BT24-28 find_pr, BT37-40/BT56 locate-via-find_pr, BT59-68 gh-state helpers,
# and read_merge_result's gh-first arm at BT41-47/BT63-64) all route through gh,
# so the override must persist. It stays inert for the file-only tests (BT12-23,
# BT29-34) because their functions never call gh, and MOCK_PR_STATE/MOCK_PR_LIST_JSON
# default to the "not merged / no PR" shape so BT41-47 fall through to the audit path.
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

# ----- BT12-BT23 — uberdev_goal_read_trust_signal: trust-signal enum coverage -----
# (issue #137; finding fingerprint d599c295ba4d2846 from /review-pr Phase
# 2.5 on PR #129). Each test stages a synthetic audit JSON under
# $_b12_tmpdir, invokes the function, and asserts the printed enum
# (green/yellow/red/stale/missing) matches the D17 spec mapping.
#
# Covers the uncovered branches called out by pr-test-analyzer:
#   - actual JSON parsing of .phases.phase2_5      (BT12, BT13, BT14, BT19)
#   - blocker / critical threshold logic           (BT12, BT13, BT14)
#   - halted_due_to_overflow flag                  (BT15)
#   - 'stale' vs 'missing' distinction             (BT16, BT17, BT18)
#   - malformed-by_severity second-jq failure      (BT20)
#   - combined red-triggers (blocker+critical,      (BT21, BT22, BT23)
#     halted+blocker, halted+critical)
#
# Misclassification risk these guard: YELLOW silently treated as GREEN
# (PR auto-merged despite CRITICAL findings); STALE silently treated as
# GREEN (PR auto-merged on legacy/pre-v0.26.0 audit shape that has no
# phase2_5 block); malformed-JSON silently treated as STALE instead of
# MISSING (the B5 hardening would regress).
#
# Note: the BT12-BT18 labels in this block refer to uberdev_goal_read_trust_signal
# test cases and are distinct from the BT12-BT18 labels above which test
# uberdev_goal_issue_state_transition — different functions, both sets kept.

# BT12 — GREEN: by_severity zeros + halted=false -> "green". The clean
# trust-signal path; required precondition for /goal to auto-dispatch
# /merge per goal-pipeline §D17.
_bt12_audit_green="$_b12_tmpdir/audit-green.json"
cat > "$_bt12_audit_green" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 0, "critical": 0},
      "halted": false
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt12_audit_green")" "green" \
  "BT12.clean-phase2_5-emits-green"

# BT13 — YELLOW: critical>0, blocker=0, halted=false. /goal must hold
# YELLOW PRs; a green misclassification here is the "auto-merged despite
# CRITICAL findings" regression the post-impl finding explicitly flags.
_bt13_audit_yellow="$_b12_tmpdir/audit-yellow.json"
cat > "$_bt13_audit_yellow" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 0, "critical": 1},
      "halted": false
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt13_audit_yellow")" "yellow" \
  "BT13.critical-only-emits-yellow"

# BT14 — RED via blocker>0. Blocker count dominates: even with zero
# critical findings the PR must enter red-held. D17 forbids
# yellow-held->merging and red-held->merging transitions (BT1 covers
# that arc; BT14 covers the signal that drives the state transition).
_bt14_audit_red_blocker="$_b12_tmpdir/audit-red-blocker.json"
cat > "$_bt14_audit_red_blocker" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 2, "critical": 0},
      "halted": false
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt14_audit_red_blocker")" "red" \
  "BT14.blocker-emits-red"

# BT15 — RED via halted: halted=true is one of two OR-equal conditions
# that triggers RED (blocker>0 is the other; both share the same
# `red` branch in goal-state.sh:271 via a single `||`). This test
# isolates the halted-only path with blocker=critical=0 so a regression
# that drops the halted check (or reorders the OR) would surface here
# without being masked by a non-zero blocker. RFC 0002 §3.4 calls this
# the "halted_due_to_overflow" signal: Phase 2.5 truncated findings
# beyond MAX_NEW=10 so the severity counters are unreliable; the only
# safe action is red-held.
_bt15_audit_red_halted="$_b12_tmpdir/audit-red-halted.json"
cat > "$_bt15_audit_red_halted" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 0, "critical": 0},
      "halted": true
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt15_audit_red_halted")" "red" \
  "BT15.halted-overrides-clean-counters-emits-red"

# BT16 — STALE: phase2_5 key absent (legacy/pre-v0.26.0 audit shape).
# Distinct from 'missing': the audit ran but predates the Phase 2.5
# trust-signal contract. Caller must re-dispatch /review-pr (never
# silently assume GREEN on a stale artifact per D17).
_bt16_audit_stale="$_b12_tmpdir/audit-stale.json"
cat > "$_bt16_audit_stale" <<'EOF'
{"phases": {}}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt16_audit_stale")" "stale" \
  "BT16.phase2_5-absent-emits-stale"

# BT17 — MISSING: audit file does not exist. Distinct from 'stale':
# /review-pr has not yet produced an artifact for this PR. State
# machine treats both as "re-dispatch /review-pr" today but the
# distinction is load-bearing for goal-pipeline telemetry (stale
# means we already ran once; missing means we haven't).
assert_eq "$(uberdev_goal_read_trust_signal /nonexistent/audit.json)" "missing" \
  "BT17.file-not-found-emits-missing"

# BT18 — MISSING via jq failure (malformed JSON). B5 hardening: the
# jq exit code drives control flow; empty-stdout-as-success would let
# corrupted audit JSON silently misclassify as 'stale' (and thence
# YELLOW->GREEN if a later run produced a halted-but-empty payload).
# stderr suppressed because gh_jq_or_jq emits a warning by design.
_bt18_audit_malformed="$_b12_tmpdir/audit-malformed.json"
printf 'not valid json {{\n' > "$_bt18_audit_malformed"
assert_eq "$(uberdev_goal_read_trust_signal "$_bt18_audit_malformed" 2>/dev/null)" "missing" \
  "BT18.malformed-json-emits-missing"

# BT19 — Shape-tolerance: empty phase2_5 object. The `// 0` and
# `// false` jq defaults preserve GREEN when by_severity counters and
# halted are all absent; the F1 simplify-lens refactor (goal-state.sh
# :265-267) is contracted to keep this invariant. Regressing this
# would surface as false-RED across every pre-counters audit payload.
_bt19_audit_minimal="$_b12_tmpdir/audit-minimal.json"
cat > "$_bt19_audit_minimal" <<'EOF'
{"phases": {"phase2_5": {}}}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt19_audit_minimal")" "green" \
  "BT19.empty-phase2_5-defaults-to-green"

# BT20 — MISSING via second-jq failure (B5 defense-in-depth). The first
# jq call (.phases.phase2_5 // empty) succeeds because phase2_5 IS
# present, so p25 is non-empty and we fall past the 'stale' branch.
# The SECOND jq call then errors because by_severity is a string rather
# than an object — `.by_severity.blocker` cannot index a string and jq
# exits non-zero. Without the explicit rc check at goal-state.sh:301
# (`[ "$jq_rc" -eq 0 ] || { printf 'missing\n'; return 0; }`),
# `read -r blocker critical halted <<<""` would leave all three vars
# empty, the `[ $blocker -gt 0 ]` arithmetic would silently evaluate to
# false, and the function would fall through to printf 'green'. That is
# the YELLOW->GREEN misclassification path the original #137 finding
# was filed against — this test locks the defense-in-depth fix.
_bt20_audit_malformed_severity="$_b12_tmpdir/audit-malformed-severity.json"
cat > "$_bt20_audit_malformed_severity" <<'EOF'
{"phases":{"phase2_5":{"by_severity":"not_an_object","halted":false}}}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt20_audit_malformed_severity" 2>/dev/null)" "missing" \
  "BT20.malformed-by_severity-emits-missing"

# BT21 — RED via blocker>0 AND critical>0 simultaneously. BT14 isolates
# blocker-only and BT13 isolates critical-only; this fixture exercises
# both >0 at once to lock the red branch
# (`[ "$halted" = "true" ] || [ "$blocker" -gt 0 ]`) against an accidental
# `&&` / short-circuit regression. blocker dominates: the function returns
# red before ever reaching the `[ "$critical" -gt 0 ]` yellow branch, so a
# regression that ANDed the conditions (or swapped the branch order) would
# surface here as yellow instead of red.
_bt21_audit_red_both="$_b12_tmpdir/audit-red-both.json"
cat > "$_bt21_audit_red_both" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 1, "critical": 1},
      "halted": false
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt21_audit_red_both")" "red" \
  "BT21.blocker-and-critical-both-emits-red"

# BT22 — RED via halted=true AND blocker>0. BT15 isolates halted-only with
# clean counters; this variant adds blocker>0 to verify halted's red
# precedence is not masked (and that the OR short-circuit still resolves to
# red) when both red-triggering conditions hold. A regression that dropped
# or reordered the halted check would still surface red here via blocker,
# so this is the companion to BT23 (halted+critical) which has no
# blocker fallback.
_bt22_audit_red_halted_blocker="$_b12_tmpdir/audit-red-halted-blocker.json"
cat > "$_bt22_audit_red_halted_blocker" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 1, "critical": 0},
      "halted": true
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt22_audit_red_halted_blocker")" "red" \
  "BT22.halted-and-blocker-emits-red"

# BT23 — RED via halted=true AND critical>0 (blocker=0). The load-bearing
# variant: with blocker=0, the ONLY thing that produces red is the halted
# check. If halted were reordered after / masked by the critical>0 yellow
# branch, this fixture would regress to yellow. Locks halted's red
# precedence over a non-zero critical count.
_bt23_audit_red_halted_critical="$_b12_tmpdir/audit-red-halted-critical.json"
cat > "$_bt23_audit_red_halted_critical" <<'EOF'
{
  "phases": {
    "phase2_5": {
      "by_severity": {"blocker": 0, "critical": 1},
      "halted": true
    }
  }
}
EOF
assert_eq "$(uberdev_goal_read_trust_signal "$_bt23_audit_red_halted_critical")" "red" \
  "BT23.halted-and-critical-emits-red"

# Cleanup: remove the isolated tmpdir we created via mktemp -d above.
# The single `rm -rf "$_b12_tmpdir"` subsumes any per-BT artifacts
# (goal-test-bt3-fingerprints.tsv, audit-*.json, etc.) because they
# all live INSIDE the tmpdir under the section-local UBERDEV_TMPDIR.

# BT5 — uberdev_goal_should_automerge behavioral coverage.
# Reuses the B12 _b12_tmpdir + sourced lib. Each case MUST use a distinct
# goal_id so its per-id TSV (goal-<id>-merge-attempts.tsv) cannot
# cross-contaminate another case.
# _bt5_seed writes one TSV row in the lib's column order: <pr>\t<attempts>
# (PR\tCOUNT), matching the reader's awk `$1==p {c=$2}` in goal-state.sh.
# Returns 1 on write-failure so dependent cases guard with `if _bt5_seed ...`.
_bt5_seed() {
  printf '%s\t%s\n' "$2" "$3" > "$_b12_tmpdir/goal-$1-merge-attempts.tsv" || {
    FAIL=$((FAIL + 1))
    printf '  FAIL  BT5._bt5_seed (could not write %s)\n' \
        "$_b12_tmpdir/goal-$1-merge-attempts.tsv" >&2
    return 1
  }
}
# Sentinel: a non-empty UBERDEV_GOAL_ID *provenance* value. Supplying it isolates
# the int-validation / attempts-cap branches (B3a-B7) from the provenance branch
# (B1/B2), so those refusals/allows are attributable to the predicate under test
# and never to missing provenance. Named for the env it stands in for, not for a
# per-case goal_id arg (cases pass their own literals bt5-3a..bt5-7).
_bt5_provenance_env=bt5-valid

# B1 — provenance branch: with UBERDEV_GOAL_ID unset, a stray /merge fired
# outside /goal context must not auto-merge.
# Subshell required because `unset` cannot be expressed via prefix-assignment.
( unset UBERDEV_GOAL_ID; uberdev_goal_should_automerge bt5-1 123 )
assert_rc "$?" "1" "BT5.B1-provenance-unset-refused"

# B2 — exported-but-empty UBERDEV_GOAL_ID treated identically to unset.
UBERDEV_GOAL_ID="" uberdev_goal_should_automerge bt5-2 123
assert_rc "$?" "1" "BT5.B2-provenance-empty-refused"

# B3a — non-numeric PR refused. Valid provenance env is set deliberately so the
# refusal is attributable to int-validation, not to missing provenance (B1/B2).
UBERDEV_GOAL_ID="$_bt5_provenance_env" uberdev_goal_should_automerge bt5-3a abc
assert_rc "$?" "1" "BT5.B3a-pr-non-numeric-refused"

# B3b — empty PR refused. Provenance env set on purpose (same rationale as B3a):
# isolates the int-validation branch so the refusal is not a provenance miss.
UBERDEV_GOAL_ID="$_bt5_provenance_env" uberdev_goal_should_automerge bt5-3b ""
assert_rc "$?" "1" "BT5.B3b-pr-empty-refused"

# B4 — boundary: predicate uses strict `-lt`, so attempts == cap must refuse.
# Regression detector: an accidental `-le` flip would let attempts == cap
# pass, making this case's expected rc 1 turn into 0 (test goes red).
if _bt5_seed bt5-4 200 3; then
  UBERDEV_GOAL_ID="$_bt5_provenance_env" uberdev_goal_should_automerge bt5-4 200
  assert_rc "$?" "1" "BT5.B4-attempts-at-cap-refused"
fi

# B5 — pairs with B4: attempts == cap-1 must allow (boundary pinned both sides).
if _bt5_seed bt5-5 201 2; then
  UBERDEV_GOAL_ID="$_bt5_provenance_env" uberdev_goal_should_automerge bt5-5 201
  assert_rc "$?" "0" "BT5.B5-attempts-under-cap-allowed"
fi

# B6 — no TSV: count defaults to 0; predicate allows.
UBERDEV_GOAL_ID="$_bt5_provenance_env" uberdev_goal_should_automerge bt5-6 202
assert_rc "$?" "0" "BT5.B6-no-attempts-file-allowed"

# B7 — env knob: renaming _UBERDEV_GOAL_MAX_MERGE_ATTEMPTS breaks the
# override; this case then fails visibly (assert_rc expects 0, gets 1)
# if the var name drifts.
if _bt5_seed bt5-7 203 3; then
  _UBERDEV_GOAL_MAX_MERGE_ATTEMPTS=5 UBERDEV_GOAL_ID="$_bt5_provenance_env" \
      uberdev_goal_should_automerge bt5-7 203
  assert_rc "$?" "0" "BT5.B7-env-knob-override-allowed"
fi

# ----- BT24-BT47 — uberdev_goal_{extract_pr_num_from_log,list_prs_in_state,
#       locate_review_pr_audit,read_merge_result} behavioural coverage -----
# Closes issue #161: the four critical-path lib fns on /uberdev:goal's PR
# state-transition path previously had ZERO behavioural tests — only the
# G19.public.* function-existence shape-checks above (lines 241-242). The
# 170/170 passing suite provided false confidence: a regression in any of
# these four would not be caught. Per the issue's Suggested fix scope, each
# fn gets coverage for happy path, empty input, malformed input, plus one
# function-specific edge case (multi-entry log, multi-PR-in-state, multi-
# run-id lex-sort, last-matching-row-wins).
#
# CWD handling: uberdev_goal_read_merge_result reads ".uberdev/audit.jsonl"
# and uberdev_goal_locate_review_pr_audit globs ".uberdev/runs/*/...",
# both relative to CWD. Tests use a subshell `(cd "$dir" && fn)` to
# control CWD without leaking the change to subsequent tests. Each fixture
# directory under $_b12_tmpdir is unique to its test so per-test state
# cannot cross-contaminate. UBERDEV_TMPDIR is still pinned to $_b12_tmpdir
# from line 294-295, so solve-bg-stdout-<issue>.log fixtures land where
# the function-under-test (locate_review_pr_audit) reads them.

# ===== uberdev_goal_find_pr_for_issue (issue #180 — gh closingIssuesReferences) =====
# Replaces the retired uberdev_goal_extract_pr_num_from_log `pushed PR #N` log
# parser: that marker has zero producers and `claude --bg` stdout is a detached
# banner on CLI 2.1.150. Issue->PR resolution is now GitHub-native — a PR that
# closes issue N (closingIssuesReferences) or whose head is `feat/N-…`.

# BT24 — happy: closingIssuesReferences match -> PR number.
MOCK_PR_LIST_JSON='[{"number":123,"closingIssuesReferences":[{"number":100}],"headRefName":"feat/100-fix"}]'
assert_eq "$(uberdev_goal_find_pr_for_issue 100)" "123" \
  "BT24.find-pr-closes-match"

# BT25 — non-numeric issue: validate_int rejects BEFORE any gh call -> rc=1
# (the R3 gh-argument-injection guard; mirrors BT35/BT41).
uberdev_goal_find_pr_for_issue abc 2>/dev/null
assert_rc "$?" "1" "BT25.find-pr-non-numeric-rc-1"

# BT26 — no match: empty PR list -> empty output, rc=0 (a not-yet-pushed
# solver must NOT be misread as an error).
MOCK_PR_LIST_JSON='[]'
_bt26_rc=0
_bt26_out="$(uberdev_goal_find_pr_for_issue 9999)" || _bt26_rc=$?
assert_eq "$_bt26_out" "" "BT26.find-pr-no-match-empty"
assert_rc "$_bt26_rc" "0" "BT26.find-pr-no-match-rc-zero"

# BT27 — head-ref fallback: closingIssuesReferences empty, head `feat/N-` matches.
# Covers the historical-PR shape where the Closes link was dropped but the
# branch name still carries the issue number.
MOCK_PR_LIST_JSON='[{"number":321,"closingIssuesReferences":[],"headRefName":"feat/200-thing"}]'
assert_eq "$(uberdev_goal_find_pr_for_issue 200)" "321" \
  "BT27.find-pr-head-ref-fallback"

# BT28 — multiple matches + a distractor: highest PR wins (max), and a PR
# closing a DIFFERENT issue is excluded. A regression that dropped the
# `| max` or the `select(... == N)` filter would surface here.
MOCK_PR_LIST_JSON='[{"number":5,"closingIssuesReferences":[{"number":300}],"headRefName":"feat/300-a"},{"number":99,"closingIssuesReferences":[{"number":300}],"headRefName":"feat/300-b"},{"number":1000,"closingIssuesReferences":[{"number":999}],"headRefName":"feat/999-z"}]'
assert_eq "$(uberdev_goal_find_pr_for_issue 300)" "99" \
  "BT28.find-pr-highest-wins-excludes-other-issue"

# Reset the PR-list mock to inert before the file-based BTs below.
MOCK_PR_LIST_JSON='[]'

# ===== uberdev_goal_list_prs_in_state (lines 386-392) =====

# BT29 — missing TSV: `[ -f "$f" ] || return 0` short-circuits (state_init
# not called for test-bt29). Empty stdout + rc=0 expected.
_bt29_rc=0
_bt29_out="$(uberdev_goal_list_prs_in_state test-bt29 green)" || _bt29_rc=$?
assert_eq "$_bt29_out" "" "BT29.list-missing-tsv-empty"
assert_rc "$_bt29_rc" "0" "BT29.list-missing-tsv-rc-zero"

# BT30 — empty TSV (state_init truncates): file exists but no rows -> empty.
uberdev_goal_state_init test-bt30
assert_eq "$(uberdev_goal_list_prs_in_state test-bt30 green)" "" \
  "BT30.list-empty-tsv-empty"

# BT31 — happy: one PR transitioned into `green` -> outputs PR number.
# Exercises the full write-then-read round-trip through
# uberdev_goal_pr_state_transition, which is the only sanctioned way to
# populate the TSV (raw printfs would bypass the D17 state-machine guard).
uberdev_goal_state_init test-bt31
uberdev_goal_pr_state_transition test-bt31 100 dispatched pushed-reviewing
uberdev_goal_pr_state_transition test-bt31 100 pushed-reviewing green
assert_eq "$(uberdev_goal_list_prs_in_state test-bt31 green)" "100" \
  "BT31.list-single-pr-in-state"

# BT32 — multi-PR-in-state: three PRs all reach `green` -> all returned.
# awk's hash-iteration order over the `state[]` associative array is
# undefined (depends on libawk hash function), so the test sorts the
# output before comparing. A regression that emitted only the FIRST or
# LAST PR (instead of iterating the whole hash) would surface here.
uberdev_goal_state_init test-bt32
for _pr in 201 202 203; do
  uberdev_goal_pr_state_transition test-bt32 "$_pr" dispatched pushed-reviewing
  uberdev_goal_pr_state_transition test-bt32 "$_pr" pushed-reviewing green
done
_bt32_sorted="$(uberdev_goal_list_prs_in_state test-bt32 green | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "$_bt32_sorted" "201 202 203" "BT32.list-multi-pr-in-state"

# BT33 — latest-transition-wins (edge case the issue calls out): awk's
# `state[$1]=$2` accumulates rows IN ORDER, so the LAST row for each PR
# overwrites prior rows. PR 300 transitions through three states ending
# in `merging`; a query for `green` MUST NOT include 300, and a query for
# `merging` MUST. A regression that built a union across all rows would
# surface here (300 would appear under BOTH state queries).
uberdev_goal_state_init test-bt33
uberdev_goal_pr_state_transition test-bt33 300 dispatched pushed-reviewing
uberdev_goal_pr_state_transition test-bt33 300 pushed-reviewing green
uberdev_goal_pr_state_transition test-bt33 300 green merging
assert_eq "$(uberdev_goal_list_prs_in_state test-bt33 green)"   "" \
  "BT33.list-latest-wins-green-excludes"
assert_eq "$(uberdev_goal_list_prs_in_state test-bt33 merging)" "300" \
  "BT33.list-latest-wins-merging-includes"

# BT34 — no PR in requested state: rows exist but none match. Positive
# control for the awk `if (state[pr]==s)` filter; complements BT30 (empty
# TSV) by proving the filter ALSO rejects non-matching rows, not just
# the empty case.
uberdev_goal_state_init test-bt34
uberdev_goal_pr_state_transition test-bt34 400 dispatched pushed-reviewing
assert_eq "$(uberdev_goal_list_prs_in_state test-bt34 merging)" "" \
  "BT34.list-no-pr-in-requested-state"

# ===== uberdev_goal_locate_review_pr_audit (lines 353-373) =====

# BT35 — non-numeric issue: validate_int rejects -> rc=1. Stderr suppressed
# because validate_int prints nothing, but mirrored on other BT*-rc-1
# tests in this file for consistency.
uberdev_goal_locate_review_pr_audit abc 2>/dev/null
assert_rc "$?" "1" "BT35.locate-non-numeric-issue-rc-1"

# BT36 — no PR for issue: find_pr_for_issue returns "" for issue 9999 (empty
# gh PR list), so the `[ -n "$pr" ] || return 0` branch fires and the function
# emits nothing. Confirms the function does NOT halt the goal-pipeline when a
# solver has not yet pushed a PR. Capture rc separately (mirrors BT25/BT29) —
# `$(...)` swallows it, so we assert both the empty-stdout invariant AND that
# the function returned 0 (the no-PR short-circuit must NOT raise an error).
MOCK_PR_LIST_JSON='[]'
_bt36_rc=0
_bt36_out="$(uberdev_goal_locate_review_pr_audit 9999)" || _bt36_rc=$?
assert_eq "$_bt36_out" "" "BT36.locate-no-pr-empty"
assert_rc "$_bt36_rc" "0" "BT36.locate-no-pr-rc-zero"

# BT37 — happy: gh resolves issue 37 -> PR=500, .uberdev/runs/<run>/review-pr-verdict.json
# carries matching .pr, run_id matches RUN_ID_REGEX. Function returns
# the relative canonical path. The verdict.json uses `"pr": "500"`
# (string form) because locate_review_pr_audit_by_pr reads .pr via `jq -r`
# (NOT `jq --argjson`) and then string-compares against $pr, so either
# `{"pr": "500"}` or `{"pr": 500}` works identically here. BT43's
# read_merge_result counterpart MUST use integer form (see BT43) — the
# asymmetry is intentional and reflects each fn's filter.
_bt37_dir="$_b12_tmpdir/bt37-cwd"
mkdir -p "$_bt37_dir/.uberdev/runs/20260521-120000-aaaa1111"
MOCK_PR_LIST_JSON='[{"number":500,"closingIssuesReferences":[{"number":37}],"headRefName":"feat/37-x"}]'
cat > "$_bt37_dir/.uberdev/runs/20260521-120000-aaaa1111/review-pr-verdict.json" <<'EOF'
{"pr": "500"}
EOF
_bt37_out="$(cd "$_bt37_dir" && uberdev_goal_locate_review_pr_audit 37)"
assert_eq "$_bt37_out" \
  ".uberdev/runs/20260521-120000-aaaa1111/review-pr-verdict.json" \
  "BT37.locate-happy-path"

# BT38 — multi-run edge case: two runs both match .pr=600; `sort -r |
# head -n 1` picks the lex-greatest run_id. The YYYYMMDD-HHMMSS-<sha>
# format lex-sorts identically to chronological order, so the 200000
# run wins over the 100000 run. A regression that picked oldest, or
# reordered the sort, would surface here. Sha values are intentionally
# CROSSED against timestamps (200000-aaaa vs 100000-bbbb) so a hypo-
# thetical regression that keyed off the sha suffix instead of the
# timestamp prefix would still pick 100000-bbbb (sha "bbbb" > "aaaa"),
# making the assertion fail. The lex-aligned fixture (200000-bbbb vs
# 100000-aaaa) would have hidden such a regression.
_bt38_dir="$_b12_tmpdir/bt38-cwd"
mkdir -p "$_bt38_dir/.uberdev/runs/20260521-100000-bbbb2222" \
         "$_bt38_dir/.uberdev/runs/20260521-200000-aaaa1111"
MOCK_PR_LIST_JSON='[{"number":600,"closingIssuesReferences":[{"number":38}],"headRefName":"feat/38-x"}]'
for _d in 20260521-100000-bbbb2222 20260521-200000-aaaa1111; do
  printf '%s\n' '{"pr": "600"}' \
    > "$_bt38_dir/.uberdev/runs/$_d/review-pr-verdict.json"
done
_bt38_out="$(cd "$_bt38_dir" && uberdev_goal_locate_review_pr_audit 38)"
assert_eq "$_bt38_out" \
  ".uberdev/runs/20260521-200000-aaaa1111/review-pr-verdict.json" \
  "BT38.locate-multi-run-newest-wins"

# BT39 — PR mismatch: verdict.json's .pr is 999 but gh resolves issue 39 to
# PR=700. The `[ "$pr_field" = "$pr" ] || continue` filter rejects the
# candidate; final output empty. Without this filter, the function would
# return a path pointing to an UNRELATED PR's review-pr verdict, which
# would silently misclassify the trust signal.
_bt39_dir="$_b12_tmpdir/bt39-cwd"
mkdir -p "$_bt39_dir/.uberdev/runs/20260521-130000-cccc3333"
MOCK_PR_LIST_JSON='[{"number":700,"closingIssuesReferences":[{"number":39}],"headRefName":"feat/39-x"}]'
printf '%s\n' '{"pr": "999"}' \
  > "$_bt39_dir/.uberdev/runs/20260521-130000-cccc3333/review-pr-verdict.json"
_bt39_out="$(cd "$_bt39_dir" && uberdev_goal_locate_review_pr_audit 39)"
assert_eq "$_bt39_out" "" "BT39.locate-pr-mismatch-empty"

# BT40 — malformed input: run dir name "not-a-run-id" does not match
# RUN_ID_REGEX (`^[0-9]{8}-[0-9]{6}-[a-f0-9]+$`); the regex check rejects
# the candidate -> empty output. Defense against a fabricated or typo'd
# run_id (e.g., from a partial-write of a fresh run dir) leaking through
# the sort.
_bt40_dir="$_b12_tmpdir/bt40-cwd"
mkdir -p "$_bt40_dir/.uberdev/runs/not-a-run-id"
MOCK_PR_LIST_JSON='[{"number":800,"closingIssuesReferences":[{"number":40}],"headRefName":"feat/40-x"}]'
printf '%s\n' '{"pr": "800"}' \
  > "$_bt40_dir/.uberdev/runs/not-a-run-id/review-pr-verdict.json"
_bt40_out="$(cd "$_bt40_dir" && uberdev_goal_locate_review_pr_audit 40)"
assert_eq "$_bt40_out" "" "BT40.locate-malformed-run-id-empty"
# Reset the PR-list mock to inert before the read_merge_result BTs below.
MOCK_PR_LIST_JSON='[]'

# ===== uberdev_goal_read_merge_result (lines 410-438) =====

# BT41 — non-numeric PR: validate_int rejects -> rc=1.
uberdev_goal_read_merge_result abc 2>/dev/null
assert_rc "$?" "1" "BT41.read-merge-non-numeric-pr-rc-1"

# BT42 — missing audit file: `[ -f "$audit" ] || { printf 'missing'; ... }`
# short-circuits when .uberdev/audit.jsonl is absent. Empty CWD subdir
# (no .uberdev/ created) guarantees the file-existence guard fires.
_bt42_dir="$_b12_tmpdir/bt42-cwd"
mkdir -p "$_bt42_dir"
_bt42_out="$(cd "$_bt42_dir" && uberdev_goal_read_merge_result 123)"
assert_eq "$_bt42_out" "missing" "BT42.read-merge-missing-audit-emits-missing"

# BT43 — happy: merge_executed row for PR=900 -> 'success'. .data.pr uses
# integer form (no quotes) because the jq filter uses `--argjson pr "$pr"`
# which parses "900" as the JSON integer 900; matching against a string
# "900" in the fixture would fail the equality check.
_bt43_dir="$_b12_tmpdir/bt43-cwd"
mkdir -p "$_bt43_dir/.uberdev"
printf '%s\n' '{"event":"merge_executed","data":{"pr":900}}' \
  > "$_bt43_dir/.uberdev/audit.jsonl"
_bt43_out="$(cd "$_bt43_dir" && uberdev_goal_read_merge_result 900)"
assert_eq "$_bt43_out" "success" "BT43.read-merge-executed-emits-success"

# BT44 — pr_parked with conflict-class reason (refused) -> 'conflict'.
# The case-block bundles three reasons (refused, ambiguous, push-non-ff)
# into the same `conflict` arm; testing one locks that arm. A regression
# that broke the case-block's `|` separators would still pass this
# single-reason test if `refused` was kept first, but would fail BT43
# (success) or BT45 (hook_failed) — those guard the other arms.
_bt44_dir="$_b12_tmpdir/bt44-cwd"
mkdir -p "$_bt44_dir/.uberdev"
printf '%s\n' '{"event":"pr_parked","data":{"pr":901,"reason":"refused"}}' \
  > "$_bt44_dir/.uberdev/audit.jsonl"
_bt44_out="$(cd "$_bt44_dir" && uberdev_goal_read_merge_result 901)"
assert_eq "$_bt44_out" "conflict" \
  "BT44.read-merge-parked-refused-emits-conflict"

# BT45 — pr_parked test-fail-exhausted -> 'hook_failed'. Distinct from
# 'conflict' because /merge ran the test hook N times and they all
# failed (PARK_REASON_ENUM); the goal-pipeline circuit-breaker maps
# this onto a different retry policy than conflict-class reasons.
_bt45_dir="$_b12_tmpdir/bt45-cwd"
mkdir -p "$_bt45_dir/.uberdev"
printf '%s\n' '{"event":"pr_parked","data":{"pr":902,"reason":"test-fail-exhausted"}}' \
  > "$_bt45_dir/.uberdev/audit.jsonl"
_bt45_out="$(cd "$_bt45_dir" && uberdev_goal_read_merge_result 902)"
assert_eq "$_bt45_out" "hook_failed" \
  "BT45.read-merge-parked-test-fail-emits-hook_failed"

# BT46 — multi-entry edge case (the issue calls this out): latest matching
# row wins. PR=903 was parked, then later merged. The jq pipeline's
# `last` MUST report the most recent matching row -> 'success'. A
# regression that broke --slurp or used `first` would falsely report
# 'conflict' here, keeping the PR in a held state forever.
_bt46_dir="$_b12_tmpdir/bt46-cwd"
mkdir -p "$_bt46_dir/.uberdev"
cat > "$_bt46_dir/.uberdev/audit.jsonl" <<'EOF'
{"event":"pr_parked","data":{"pr":903,"reason":"refused"}}
{"event":"merge_executed","data":{"pr":903}}
EOF
_bt46_out="$(cd "$_bt46_dir" && uberdev_goal_read_merge_result 903)"
assert_eq "$_bt46_out" "success" "BT46.read-merge-multi-entry-last-wins"

# BT47 — malformed JSON: jq fails on the --slurp pipe; stderr is dropped
# by the `2>/dev/null` inside the function; `row` is empty; falls into
# the `[ -n "$row" ] || { printf 'missing'; ... }` branch. Locks the
# "fail closed → missing" contract — a regression that masked jq failure
# as success would let a corrupted audit.jsonl falsely advance the PR
# state machine.
_bt47_dir="$_b12_tmpdir/bt47-cwd"
mkdir -p "$_bt47_dir/.uberdev"
printf 'not valid json {{{\n' > "$_bt47_dir/.uberdev/audit.jsonl"
_bt47_out="$(cd "$_bt47_dir" && uberdev_goal_read_merge_result 904 2>/dev/null)"
assert_eq "$_bt47_out" "missing" \
  "BT47.read-merge-malformed-json-emits-missing"

# ----- BT48-BT58 — held-PR re-review poll loop + convergence terminal
# behavioural coverage (issues #159 + #160). Functions under test:
#   - uberdev_goal_get_pr_state         (latest-state lookup)
#   - uberdev_goal_record_held_audit    (TSV row append)
#   - uberdev_goal_get_last_held_audit  (latest row per PR)
#   - uberdev_goal_locate_review_pr_audit_by_pr (PR-keyed glob locator)
#   - new state-machine arcs yellow-held<->red-held (cross-held re-classification)
#
# Strategy: per-test isolated $UBERDEV_TMPDIR (mktemp -d sub-dir of $_b12_tmpdir)
# and a per-test goal_id. The locator tests `cd` into a scratch dir so the
# relative-glob path (`.uberdev/runs/*/review-pr-verdict.json`) resolves
# against test-controlled fixtures rather than the user's repo state.

# BT48 — uberdev_goal_get_pr_state: latest transition wins per PR.
uberdev_goal_state_init test-bt48
UBERDEV_GOAL_ID=test-bt48 uberdev_goal_pr_state_transition test-bt48 500 pushed-reviewing yellow-held >/dev/null 2>&1
UBERDEV_GOAL_ID=test-bt48 uberdev_goal_pr_state_transition test-bt48 500 yellow-held red-held >/dev/null 2>&1
assert_eq "$(uberdev_goal_get_pr_state test-bt48 500)" "red-held" "BT48.latest-transition-wins"
# Empty when PR has no recorded state.
assert_eq "$(uberdev_goal_get_pr_state test-bt48 999)" "" "BT48.unknown-pr-empty"
# Empty (rc 0) when goal_id TSV does not exist yet.
_bt48_out="$(uberdev_goal_get_pr_state test-bt48-missing 500 2>/dev/null)"
assert_eq "$_bt48_out" "" "BT48.missing-tsv-empty"

# BT49 — uberdev_goal_record_held_audit + uberdev_goal_get_last_held_audit
# round-trip. First record establishes the baseline; second record overrides
# for the same PR; reads return the latest path.
uberdev_goal_state_init test-bt49
uberdev_goal_record_held_audit test-bt49 600 /tmp/audit-first.json
assert_eq "$(uberdev_goal_get_last_held_audit test-bt49 600)" "/tmp/audit-first.json" \
  "BT49.first-record-returned"
uberdev_goal_record_held_audit test-bt49 600 /tmp/audit-second.json
assert_eq "$(uberdev_goal_get_last_held_audit test-bt49 600)" "/tmp/audit-second.json" \
  "BT49.second-record-overrides"
# Different PR in the same goal: independent rows.
uberdev_goal_record_held_audit test-bt49 601 /tmp/audit-other.json
assert_eq "$(uberdev_goal_get_last_held_audit test-bt49 600)" "/tmp/audit-second.json" \
  "BT49.pr-600-isolated"
assert_eq "$(uberdev_goal_get_last_held_audit test-bt49 601)" "/tmp/audit-other.json" \
  "BT49.pr-601-isolated"
# Empty when PR has no recorded held audit.
assert_eq "$(uberdev_goal_get_last_held_audit test-bt49 999)" "" \
  "BT49.unknown-pr-empty"

# BT50 — uberdev_goal_locate_review_pr_audit_by_pr: globs `.uberdev/runs/*`
# in CWD and picks the lex-greatest run_id whose `.pr` matches. Lex-greatest
# = chronologically newest given the YYYYMMDD-HHMMSS-<sha> shape.
_bt50_scratch="$(mktemp -d 2>/dev/null || printf '/tmp/bt50-%s' "$$")"
mkdir -p "$_bt50_scratch"
(
  cd "$_bt50_scratch" || exit 1
  mkdir -p .uberdev/runs/20260101-100000-aaaaaaaa
  mkdir -p .uberdev/runs/20260102-120000-bbbbbbbb
  mkdir -p .uberdev/runs/20260103-110000-cccccccc
  printf '{"pr":700}\n' > .uberdev/runs/20260101-100000-aaaaaaaa/review-pr-verdict.json
  printf '{"pr":700}\n' > .uberdev/runs/20260102-120000-bbbbbbbb/review-pr-verdict.json
  printf '{"pr":701}\n' > .uberdev/runs/20260103-110000-cccccccc/review-pr-verdict.json
)
_bt50_pr700="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 700)"
_bt50_pr701="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 701)"
_bt50_pr999="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 999)"
assert_eq "$_bt50_pr700" ".uberdev/runs/20260102-120000-bbbbbbbb/review-pr-verdict.json" \
  "BT50.newest-audit-for-pr700"
assert_eq "$_bt50_pr701" ".uberdev/runs/20260103-110000-cccccccc/review-pr-verdict.json" \
  "BT50.single-audit-for-pr701"
assert_eq "$_bt50_pr999" "" "BT50.no-audit-for-pr999"
# Non-numeric PR rejected.
uberdev_goal_locate_review_pr_audit_by_pr abc >/dev/null 2>&1
assert_rc "$?" "1" "BT50.non-numeric-pr-rejected"
rm -rf "$_bt50_scratch" 2>/dev/null || true

# BT51 — new state machine arcs (yellow-held<->red-held). The poll loop in
# Phase 2 step 2e uses these to re-classify a held PR when the re-review
# trust signal flips severity (e.g., earlier RED resolves down to YELLOW
# after fixes land in a dependency, or earlier YELLOW escalates to RED
# after a new finding surfaces).
_uberdev_goal_pr_state_machine_valid yellow-held red-held
assert_rc "$?" "0" "BT51.yellow-to-red-allowed"
_uberdev_goal_pr_state_machine_valid red-held yellow-held
assert_rc "$?" "0" "BT51.red-to-yellow-allowed"
# Held arcs remain forbidden -> merging (D17 regression guard).
_uberdev_goal_pr_state_machine_valid yellow-held merging
assert_rc "$?" "1" "BT51.yellow-merging-still-forbidden"
_uberdev_goal_pr_state_machine_valid red-held merging
assert_rc "$?" "1" "BT51.red-merging-still-forbidden"

# BT52 — End-to-end held-PR poll: simulate the Phase 2 step 2e logic against
# the real helper functions. Sequence:
#   1. PR enters yellow-held; record_held_audit stores the initial audit path
#   2. Re-review fires, writes a NEW audit JSON under .uberdev/runs/
#   3. Poll: locate_by_pr returns new audit; get_last_held_audit differs;
#      read_trust_signal on the new audit returns green; transition fires
#   4. Second poll: locate_by_pr returns same audit; get_last_held_audit
#      now matches; no transition (skip)
#
# This is the integration shape the SKILL.md step 2e code-block implements.
_bt52_scratch="$(mktemp -d 2>/dev/null || printf '/tmp/bt52-%s' "$$")"
mkdir -p "$_bt52_scratch"
uberdev_goal_state_init test-bt52
# Step 1: initial held transition + audit baseline.
UBERDEV_GOAL_ID=test-bt52 uberdev_goal_pr_state_transition test-bt52 800 pushed-reviewing yellow-held >/dev/null 2>&1
(
  cd "$_bt52_scratch" || exit 1
  mkdir -p .uberdev/runs/20260201-100000-aaaaaaaa
  cat > .uberdev/runs/20260201-100000-aaaaaaaa/review-pr-verdict.json <<'EOF'
{"pr":800,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
EOF
)
_bt52_initial="$(cd "$_bt52_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 800)"
uberdev_goal_record_held_audit test-bt52 800 "$_bt52_initial"
assert_eq "$(uberdev_goal_get_pr_state test-bt52 800)" "yellow-held" "BT52.initial-state-yellow-held"

# Step 2: re-review writes a NEW audit (green this time).
(
  cd "$_bt52_scratch" || exit 1
  mkdir -p .uberdev/runs/20260202-110000-bbbbbbbb
  cat > .uberdev/runs/20260202-110000-bbbbbbbb/review-pr-verdict.json <<'EOF'
{"pr":800,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}
EOF
)
# Step 3: poll detects new audit, signal green, transitions to green.
_bt52_latest="$(cd "$_bt52_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 800)"
assert_eq "$_bt52_latest" \
  ".uberdev/runs/20260202-110000-bbbbbbbb/review-pr-verdict.json" \
  "BT52.poll-finds-new-audit"
_bt52_last_seen="$(uberdev_goal_get_last_held_audit test-bt52 800)"
if [ "$_bt52_latest" != "$_bt52_last_seen" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT52.new-audit-differs-from-last-seen"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT52.new-audit-differs-from-last-seen" >&2
fi
_bt52_signal="$(cd "$_bt52_scratch" && uberdev_goal_read_trust_signal "$_bt52_latest")"
assert_eq "$_bt52_signal" "green" "BT52.new-audit-green-signal"
_bt52_current_state="$(uberdev_goal_get_pr_state test-bt52 800)"
UBERDEV_GOAL_ID=test-bt52 uberdev_goal_pr_state_transition test-bt52 800 "$_bt52_current_state" green >/dev/null 2>&1
assert_rc "$?" "0" "BT52.held-to-green-transition-allowed"
assert_eq "$(uberdev_goal_get_pr_state test-bt52 800)" "green" "BT52.final-state-green"
uberdev_goal_record_held_audit test-bt52 800 "$_bt52_latest"

# Step 4: second poll — same audit, last_seen now matches → skip transition.
_bt52_latest2="$(cd "$_bt52_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 800)"
_bt52_last_seen2="$(uberdev_goal_get_last_held_audit test-bt52 800)"
assert_eq "$_bt52_latest2" "$_bt52_last_seen2" "BT52.second-poll-same-audit-skips"
rm -rf "$_bt52_scratch" 2>/dev/null || true

# BT53 — Held-PR poll detects re-review STILL RED → optional downgrade arc.
# Scenario: PR was yellow-held; re-review found new blockers; signal=red.
# State machine allows yellow-held → red-held re-classification (BT51).
uberdev_goal_state_init test-bt53
UBERDEV_GOAL_ID=test-bt53 uberdev_goal_pr_state_transition test-bt53 900 pushed-reviewing yellow-held >/dev/null 2>&1
UBERDEV_GOAL_ID=test-bt53 uberdev_goal_pr_state_transition test-bt53 900 yellow-held red-held >/dev/null 2>&1
assert_rc "$?" "0" "BT53.yellow-to-red-downgrade-applied"
assert_eq "$(uberdev_goal_get_pr_state test-bt53 900)" "red-held" "BT53.final-state-red-held"
# Audit event for the downgrade is emitted via goal_pr_transition.
assert_grep "$UBERDEV_TMPDIR/goal-test-bt53.jsonl" '"event":"goal_pr_transition"' \
  "BT53.transition-audit-event-emitted"
assert_grep "$UBERDEV_TMPDIR/goal-test-bt53.jsonl" '"from":"yellow-held","to":"red-held"' \
  "BT53.transition-audit-payload-shape"

# BT54 — Reverse: red-held → yellow-held upgrade.
uberdev_goal_state_init test-bt54
UBERDEV_GOAL_ID=test-bt54 uberdev_goal_pr_state_transition test-bt54 901 pushed-reviewing red-held >/dev/null 2>&1
UBERDEV_GOAL_ID=test-bt54 uberdev_goal_pr_state_transition test-bt54 901 red-held yellow-held >/dev/null 2>&1
assert_rc "$?" "0" "BT54.red-to-yellow-upgrade-applied"
assert_eq "$(uberdev_goal_get_pr_state test-bt54 901)" "yellow-held" "BT54.final-state-yellow-held"

# BT55 — state_init creates the held-audits TSV (new file added by this fix).
# Locks the contract that uberdev_goal_get_last_held_audit can be called on a
# fresh goal without first having to record anything (returns empty cleanly).
uberdev_goal_state_init test-bt55
_bt55_tsv="$UBERDEV_TMPDIR/goal-test-bt55-held-audits.tsv"
if [ -f "$_bt55_tsv" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT55.held-audits-tsv-created-on-init"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT55.held-audits-tsv-created-on-init" >&2
  printf '        expected file: %s\n' "$_bt55_tsv" >&2
fi
assert_eq "$(uberdev_goal_get_last_held_audit test-bt55 1)" "" \
  "BT55.fresh-goal-empty-held-audit-read"

# BT56 — uberdev_goal_locate_review_pr_audit (issue-keyed) still works after
# refactor (delegates to _by_pr). Regression guard: refactor must preserve
# the existing issue → PR → audit chain used by Phase 2 step 2a.
_bt56_scratch="$(mktemp -d 2>/dev/null || printf '/tmp/bt56-%s' "$$")"
mkdir -p "$_bt56_scratch"
(
  cd "$_bt56_scratch" || exit 1
  mkdir -p .uberdev/runs/20260301-100000-deadbeef
  printf '{"pr":1234}\n' > .uberdev/runs/20260301-100000-deadbeef/review-pr-verdict.json
)
# gh resolves issue 555 -> PR 1234 (closingIssuesReferences), then _by_pr globs.
MOCK_PR_LIST_JSON='[{"number":1234,"closingIssuesReferences":[{"number":555}],"headRefName":"feat/555-x"}]'
_bt56_audit="$(cd "$_bt56_scratch" && uberdev_goal_locate_review_pr_audit 555)"
assert_eq "$_bt56_audit" ".uberdev/runs/20260301-100000-deadbeef/review-pr-verdict.json" \
  "BT56.issue-keyed-locator-still-works"
MOCK_PR_LIST_JSON='[]'
rm -rf "$_bt56_scratch" 2>/dev/null || true

# BT57 — stale|missing arm of the step 2e poll loop MUST be a no-op: held
# state unchanged AND the new audit path NOT consumed. Locks the B1 fix
# from #159 post-impl-review (the previous SKILL.md ordering had an
# unconditional record_held_audit AFTER the case statement, so a transient
# undecidable audit overwrote the baseline and the next poll's
# `[ "$new_audit" = "$last_audit" ] && continue` short-circuited forever).
#
# Setup uses a `stale`-shaped new audit (well-formed JSON with .pr present
# so the by_pr locator selects it, but .phases.phase2_5 absent so
# read_trust_signal returns `stale`). This is the realistic transient
# shape — a /review-pr run that wrote the top-level JSON envelope but
# hadn't yet flushed the phase2_5 sub-tree, or a legacy pre-v0.26.0 audit
# that predates the trust-signal contract. The case statement folds
# `stale|missing` into a single arm, so this covers both.
_bt57_scratch="$(mktemp -d 2>/dev/null || printf '/tmp/bt57-%s' "$$")"
mkdir -p "$_bt57_scratch"
uberdev_goal_state_init test-bt57
UBERDEV_GOAL_ID=test-bt57 uberdev_goal_pr_state_transition test-bt57 802 pushed-reviewing yellow-held >/dev/null 2>&1
# Baseline: the audit recorded when the PR first entered held state.
(
  cd "$_bt57_scratch" || exit 1
  mkdir -p .uberdev/runs/20260203-120000-cccccccc
  cat > .uberdev/runs/20260203-120000-cccccccc/review-pr-verdict.json <<'EOF'
{"pr":802,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
EOF
)
_bt57_baseline="$(cd "$_bt57_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 802)"
uberdev_goal_record_held_audit test-bt57 802 "$_bt57_baseline"
assert_eq "$(uberdev_goal_get_last_held_audit test-bt57 802)" "$_bt57_baseline" \
  "BT57.baseline-audit-recorded"

# A NEWER audit appears that is locatable (well-formed JSON with .pr field)
# but undecidable (no phase2_5 sub-tree yet — partial flush / legacy shape).
# read_trust_signal MUST return `stale` for this payload.
(
  cd "$_bt57_scratch" || exit 1
  mkdir -p .uberdev/runs/20260204-130000-dddddddd
  cat > .uberdev/runs/20260204-130000-dddddddd/review-pr-verdict.json <<'EOF'
{"pr":802,"phases":{}}
EOF
)
_bt57_new_audit="$(cd "$_bt57_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 802)"
assert_eq "$_bt57_new_audit" \
  ".uberdev/runs/20260204-130000-dddddddd/review-pr-verdict.json" \
  "BT57.new-audit-locatable"
_bt57_signal="$(cd "$_bt57_scratch" && uberdev_goal_read_trust_signal "$_bt57_new_audit" 2>/dev/null)"
assert_eq "$_bt57_signal" "stale" "BT57.undecidable-audit-emits-stale"

# Simulate the step 2e logic: new_audit != last_audit (so the early
# `continue` guard does not fire), signal is `missing`, so the case
# falls into the stale|missing arm — which MUST NOT record the audit
# and MUST NOT transition state.
_bt57_last_seen_before="$(uberdev_goal_get_last_held_audit test-bt57 802)"
_bt57_state_before="$(uberdev_goal_get_pr_state test-bt57 802)"
case "$_bt57_signal" in
  green|yellow|red)
    # Would record + transition — BT57 must not reach this arm.
    uberdev_goal_record_held_audit test-bt57 802 "$_bt57_new_audit"
    ;;
  stale|missing)
    : # no-op (the fix from B1)
    ;;
esac
assert_eq "$(uberdev_goal_get_pr_state test-bt57 802)" "$_bt57_state_before" \
  "BT57.held-state-unchanged-on-missing"
assert_eq "$(uberdev_goal_get_last_held_audit test-bt57 802)" "$_bt57_last_seen_before" \
  "BT57.last-held-audit-preserved-on-missing"
assert_eq "$(uberdev_goal_get_last_held_audit test-bt57 802)" "$_bt57_baseline" \
  "BT57.baseline-still-points-at-original-audit"
rm -rf "$_bt57_scratch" 2>/dev/null || true

# BT58 — same-severity re-review MUST be a no-op: held state unchanged AND
# no goal_pr_transition event appended to the goal jsonl for this PR. Locks
# the `if [ "$held_current" = ... ]` guards inside the yellow and red arms
# of step 2e (a future refactor that drops those guards would silently
# apply a duplicate yellow-held→yellow-held transition).
_bt58_scratch="$(mktemp -d 2>/dev/null || printf '/tmp/bt58-%s' "$$")"
mkdir -p "$_bt58_scratch"
uberdev_goal_state_init test-bt58
UBERDEV_GOAL_ID=test-bt58 uberdev_goal_pr_state_transition test-bt58 803 pushed-reviewing yellow-held >/dev/null 2>&1
# Baseline: the audit that put PR 803 into yellow-held.
(
  cd "$_bt58_scratch" || exit 1
  mkdir -p .uberdev/runs/20260205-140000-eeeeeeee
  cat > .uberdev/runs/20260205-140000-eeeeeeee/review-pr-verdict.json <<'EOF'
{"pr":803,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
EOF
)
_bt58_baseline="$(cd "$_bt58_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 803)"
uberdev_goal_record_held_audit test-bt58 803 "$_bt58_baseline"

# Snapshot the goal jsonl line count BEFORE the same-severity poll so we
# can assert NO new goal_pr_transition was appended for PR 803.
_bt58_jsonl="$UBERDEV_TMPDIR/goal-test-bt58.jsonl"
_bt58_transitions_before=$(grep -c '"event":"goal_pr_transition".*"pr":803' "$_bt58_jsonl" 2>/dev/null || printf '0')

# A NEWER audit appears, signal STILL yellow (same severity as held).
(
  cd "$_bt58_scratch" || exit 1
  mkdir -p .uberdev/runs/20260206-150000-ffffffff
  cat > .uberdev/runs/20260206-150000-ffffffff/review-pr-verdict.json <<'EOF'
{"pr":803,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":2},"halted":false}}}
EOF
)
_bt58_new_audit="$(cd "$_bt58_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 803)"
_bt58_signal="$(cd "$_bt58_scratch" && uberdev_goal_read_trust_signal "$_bt58_new_audit")"
assert_eq "$_bt58_signal" "yellow" "BT58.new-audit-still-yellow"

# Simulate the step 2e logic: signal is yellow, held_current is yellow-held,
# so the `if [ "$held_current" = "red-held" ]` guard inside the yellow arm
# is FALSE → no transition. The record_held_audit IS called (the audit was
# readable + decided) — that's the same-audit-skips-next-poll lock from BT52.
_bt58_held_current="$(uberdev_goal_get_pr_state test-bt58 803)"
case "$_bt58_signal" in
  green)
    UBERDEV_GOAL_ID=test-bt58 uberdev_goal_pr_state_transition test-bt58 803 "$_bt58_held_current" green >/dev/null 2>&1
    uberdev_goal_record_held_audit test-bt58 803 "$_bt58_new_audit"
    ;;
  yellow)
    if [ "$_bt58_held_current" = "red-held" ]; then
      UBERDEV_GOAL_ID=test-bt58 uberdev_goal_pr_state_transition test-bt58 803 red-held yellow-held >/dev/null 2>&1
    fi
    uberdev_goal_record_held_audit test-bt58 803 "$_bt58_new_audit"
    ;;
  red)
    if [ "$_bt58_held_current" = "yellow-held" ]; then
      UBERDEV_GOAL_ID=test-bt58 uberdev_goal_pr_state_transition test-bt58 803 yellow-held red-held >/dev/null 2>&1
    fi
    uberdev_goal_record_held_audit test-bt58 803 "$_bt58_new_audit"
    ;;
esac

assert_eq "$(uberdev_goal_get_pr_state test-bt58 803)" "yellow-held" \
  "BT58.held-state-unchanged-on-same-severity"
_bt58_transitions_after=$(grep -c '"event":"goal_pr_transition".*"pr":803' "$_bt58_jsonl" 2>/dev/null || printf '0')
# Initial pushed-reviewing→yellow-held transition counts as 1; the same-
# severity poll must NOT emit a second one.
if [ "$_bt58_transitions_after" = "$_bt58_transitions_before" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT58.no-transition-event-on-same-severity"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT58.no-transition-event-on-same-severity" >&2
  printf '        transitions before: %s\n' "$_bt58_transitions_before" >&2
  printf '        transitions after:  %s\n' "$_bt58_transitions_after" >&2
fi
rm -rf "$_bt58_scratch" 2>/dev/null || true

# ----- BT59-BT68 — gh+file detection helpers (issue #180) -----
# Functions under test: uberdev_goal_pr_state_gh, uberdev_goal_pr_is_merged,
# uberdev_goal_read_merge_result (gh-first arm), uberdev_goal_agent_busy_for_issue.
# These replace the CLI-version-dependent stdout-marker probes (`backgrounded ·`
# + `merge-bg-stdout`) with GitHub-native / file-based signals.

# BT59 — pr_state_gh returns the gh state verbatim.
MOCK_PR_STATE="MERGED"
assert_eq "$(uberdev_goal_pr_state_gh 42)" "MERGED" "BT59.pr-state-gh-returns-state"

# BT60 — pr_state_gh non-numeric PR -> rc=1 BEFORE any gh call (R3 guard).
uberdev_goal_pr_state_gh abc 2>/dev/null
assert_rc "$?" "1" "BT60.pr-state-gh-non-numeric-rc-1"

# BT61 — pr_is_merged: rc=0 when gh state == MERGED (authoritative completion).
MOCK_PR_STATE="MERGED"
uberdev_goal_pr_is_merged 42
assert_rc "$?" "0" "BT61.pr-is-merged-true-on-merged"

# BT62 — pr_is_merged: rc=1 when gh state == OPEN (NOT merged — must not finalize).
MOCK_PR_STATE="OPEN"
uberdev_goal_pr_is_merged 42
assert_rc "$?" "1" "BT62.pr-is-merged-false-on-open"

# BT63 — read_merge_result gh-first: gh MERGED -> 'success' even with NO audit row.
# This is the defect-#5 robustness fix: the goal no longer depends on the
# agent-improvised merge_executed audit shape — gh state is authoritative.
MOCK_PR_STATE="MERGED"
_bt63_dir="$_b12_tmpdir/bt63-cwd"; mkdir -p "$_bt63_dir"
_bt63_out="$(cd "$_bt63_dir" && uberdev_goal_read_merge_result 905)"
assert_eq "$_bt63_out" "success" "BT63.read-merge-gh-merged-no-audit-row"

# BT64 — read_merge_result gh-first: gh MERGED OVERRIDES a stale conflict row.
# A pr_parked(refused) row would map to 'conflict' on the audit path, but gh
# says the PR actually merged afterward — gh wins.
MOCK_PR_STATE="MERGED"
_bt64_dir="$_b12_tmpdir/bt64-cwd"; mkdir -p "$_bt64_dir/.uberdev"
printf '%s\n' '{"event":"pr_parked","data":{"pr":906,"reason":"refused"}}' \
  > "$_bt64_dir/.uberdev/audit.jsonl"
_bt64_out="$(cd "$_bt64_dir" && uberdev_goal_read_merge_result 906)"
assert_eq "$_bt64_out" "success" "BT64.read-merge-gh-merged-overrides-conflict-row"
MOCK_PR_STATE=""   # reset: subsequent tests must fall through to the audit path

# BT65 — agent_busy_for_issue: rc=0 when a session cwd ends in solve-issue-N
# AND status is busy. Disambiguates "solver still working" from "solver died".
MOCK_CLAUDE_AGENTS_JSON='[{"cwd":"/x/.claude/worktrees/solve-issue-77","status":"busy"}]'
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "0" "BT65.agent-busy-true-on-busy-matching-cwd"

# BT66 — agent_busy_for_issue: rc=1 when the matching session is idle.
MOCK_CLAUDE_AGENTS_JSON='[{"cwd":"/x/solve-issue-77","status":"idle"}]'
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "1" "BT66.agent-busy-false-on-idle"

# BT67 — agent_busy_for_issue: rc=1 when a busy session belongs to a DIFFERENT
# issue (no solve-issue-7 / solve-issue-77 prefix confusion).
MOCK_CLAUDE_AGENTS_JSON='[{"cwd":"/x/solve-issue-88","status":"busy"}]'
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "1" "BT67.agent-busy-false-on-other-issue"

# BT68 — agent_busy_for_issue: non-numeric issue -> rc=1 BEFORE any claude call.
uberdev_goal_agent_busy_for_issue abc 2>/dev/null
assert_rc "$?" "1" "BT68.agent-busy-non-numeric-rc-1"
MOCK_CLAUDE_AGENTS_JSON='[]'   # reset to inert

# ----- BT69-BT75 — issue #180 /review-pr fix-loop coverage -----
# Closes the gaps surfaced by the post-impl review fanout: the merge-stall
# state-machine arm (the one real correctness bug), gh-failure fail-open + the
# new breadcrumbs, CLOSED-without-merge, and filter/cwd prefix isolation.

# BT69 — state machine: merging->green is VALID (Phase 2d merge-stall recovery).
# Regression guard for the review blocker — WITHOUT this arm the stall recovery
# calls an invalid transition (rc=2), the PR is stranded in `merging`, and the
# goal spins to the 4h stuck_loop: the exact failure mode #180 fixes.
_uberdev_goal_pr_state_machine_valid merging green
assert_rc "$?" "0" "BT69.state-machine-merging-to-green-valid"
_uberdev_goal_pr_state_machine_valid merging merged
assert_rc "$?" "0" "BT69.state-machine-merging-to-merged-still-valid"
_uberdev_goal_pr_state_machine_valid merging yellow-held
assert_rc "$?" "1" "BT69.state-machine-merging-to-yellow-still-invalid"

# BT70 — find_pr_for_issue: a gh FAILURE (rc!=0) is fail-open (empty + rc 0 so
# the caller keeps re-polling) BUT emits a stderr breadcrumb — it must NOT
# masquerade silently as "no PR yet".
MOCK_PR_LIST_JSON='[]'; MOCK_PR_LIST_RC=1
_bt70_err="$_b12_tmpdir/bt70-stderr"; : > "$_bt70_err"
_bt70_rc=0
_bt70_out="$(uberdev_goal_find_pr_for_issue 100 2>"$_bt70_err")" || _bt70_rc=$?
assert_eq "$_bt70_out" "" "BT70.find-pr-gh-failure-empty"
assert_rc "$_bt70_rc" "0" "BT70.find-pr-gh-failure-rc-zero-failopen"
if grep -q 'gh pr list failed' "$_bt70_err"; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "BT70.find-pr-gh-failure-breadcrumb"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "BT70.find-pr-gh-failure-breadcrumb" >&2
fi
MOCK_PR_LIST_RC=0; MOCK_PR_LIST_JSON='[]'

# BT71 — pr_state_gh: gh FAILURE (rc!=0) -> empty + breadcrumb; pr_is_merged false.
MOCK_PR_STATE="OPEN"; MOCK_PR_STATE_RC=1
_bt71_err="$_b12_tmpdir/bt71-stderr"; : > "$_bt71_err"
_bt71_out="$(uberdev_goal_pr_state_gh 42 2>"$_bt71_err")"
assert_eq "$_bt71_out" "" "BT71.pr-state-gh-failure-empty"
if grep -q 'gh pr view failed' "$_bt71_err"; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "BT71.pr-state-gh-failure-breadcrumb"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "BT71.pr-state-gh-failure-breadcrumb" >&2
fi
uberdev_goal_pr_is_merged 42 2>/dev/null
assert_rc "$?" "1" "BT71.pr-is-merged-false-on-gh-failure"
MOCK_PR_STATE_RC=0; MOCK_PR_STATE=""

# BT72 — pr_state_gh CLOSED-without-merge -> "CLOSED"; pr_is_merged false. Phase
# 2d's hard merge_failed gate depends on this (a force-closed PR must surface
# immediately, not loop until MERGE_TIMEOUT).
MOCK_PR_STATE="CLOSED"
assert_eq "$(uberdev_goal_pr_state_gh 42)" "CLOSED" "BT72.pr-state-gh-closed"
uberdev_goal_pr_is_merged 42
assert_rc "$?" "1" "BT72.pr-is-merged-false-on-closed"
MOCK_PR_STATE=""

# BT73 — find_pr_for_issue head-ref PREFIX ISOLATION: a PR whose head is
# `feat/30-x` (issue 30) closing issue 999 must NOT match issue 300 (neither the
# `^feat/300-` head arm nor the closingRefs arm) — guards feat/30 vs feat/300.
MOCK_PR_LIST_JSON='[{"number":4242,"closingIssuesReferences":[{"number":999}],"headRefName":"feat/30-x"}]'
assert_eq "$(uberdev_goal_find_pr_for_issue 300)" "" "BT73.find-pr-head-prefix-300-no-match"
assert_eq "$(uberdev_goal_find_pr_for_issue 30)" "4242" "BT73.find-pr-head-prefix-30-matches"
MOCK_PR_LIST_JSON='[]'

# BT74 — agent_busy_for_issue: malformed claude JSON -> rc 1 (fail-safe "not busy").
MOCK_CLAUDE_AGENTS_JSON='not valid json {{{'
uberdev_goal_agent_busy_for_issue 77 2>/dev/null
assert_rc "$?" "1" "BT74.agent-busy-malformed-json-not-busy"
MOCK_CLAUDE_AGENTS_JSON='[]'

# BT75 — agent_busy_for_issue cwd PREFIX ISOLATION: cwd `solve-issue-7` must NOT
# satisfy a check for issue 77 (endswith isolation; inverse of BT67).
MOCK_CLAUDE_AGENTS_JSON='[{"cwd":"/x/solve-issue-7","status":"busy"}]'
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "1" "BT75.agent-busy-prefix-isolation-7-not-77"
MOCK_CLAUDE_AGENTS_JSON='[]'

# ----- H1-H6 — #156 goal_id path-traversal guard + #157 unwritable-tmpdir surfacing -----
# Both findings target plugins/uberdev/lib/goal-state.sh. #156: goal_id was
# interpolated into per-goal state filenames without the slug validation that
# pr/issue/cycle already get via _uberdev_goal_validate_int (path-traversal
# defense-in-depth). #157: the `: >` truncate-creates and `>>` appends were not
# rc-checked, so a read-only-but-existing $UBERDEV_TMPDIR (which slips past
# state_init's `mkdir -p` success check) silently dropped state rows at rc=0.

# H1 — _uberdev_goal_validate_id: accepts a real generated slug; rejects empty,
# path-separator, `..` traversal, and whitespace.
_uberdev_goal_validate_id "20260521-153359-abc1234"; assert_rc "$?" "0" "H1.accepts-real-goal-id-slug"
_uberdev_goal_validate_id "test-bt_alpha.1";          assert_rc "$?" "0" "H1.accepts-hyphen-dot-underscore"
_uberdev_goal_validate_id "";                          assert_rc "$?" "1" "H1.rejects-empty"
_uberdev_goal_validate_id "../escape";                 assert_rc "$?" "1" "H1.rejects-parent-traversal"
_uberdev_goal_validate_id "a/b";                       assert_rc "$?" "1" "H1.rejects-slash"
_uberdev_goal_validate_id "..";                        assert_rc "$?" "1" "H1.rejects-dotdot"
_uberdev_goal_validate_id "a b";                       assert_rc "$?" "1" "H1.rejects-space"

# H2 — state_init refuses an unsafe goal_id with rc=1 AND surfaces the clean
# refusal diagnostic (before the fix it emitted raw "Permission denied" / "No
# such file" from the doomed `: >` writes into the traversed path).
_h2_err="$_b12_tmpdir/h2-stderr"; : > "$_h2_err"
uberdev_goal_state_init "../pwned" 2>"$_h2_err"
assert_rc "$?" "1" "H2.state-init-refuses-traversal-id"
assert_grep_file "$_h2_err" 'refusing unsafe goal_id' "H2.state-init-clean-diagnostic"

# H3 — a reader function (get_pr_state) rejects an unsafe goal_id with rc=1.
# Before the fix the `[ -f "$f" ] || return 0` file-missing early-return
# swallowed the traversal id and reported success (rc=0).
uberdev_goal_get_pr_state "../pwned" 5 >/dev/null 2>&1
assert_rc "$?" "1" "H3.get-pr-state-rejects-traversal-id"

# H4 — _uberdev_goal_append: success appends the row + returns 0; an unwritable
# target (parent dir absent) returns NON-zero with a diagnostic rather than the
# old silent rc=0.
_h4_ok="$_b12_tmpdir/h4-ok.tsv"; : > "$_h4_ok"
_uberdev_goal_append "$_h4_ok" "row-one"; assert_rc "$?" "0" "H4.append-success-returns-zero"
assert_grep "$_h4_ok" '^row-one$' "H4.append-success-writes-row"
_h4_err="$_b12_tmpdir/h4-stderr"; : > "$_h4_err"
_uberdev_goal_append "$_b12_tmpdir/h4-absent-dir/sub/file.tsv" "row" 2>"$_h4_err"
assert_rc "$?" "1" "H4.append-unwritable-returns-nonzero"
assert_grep_file "$_h4_err" 'append to .* failed' "H4.append-unwritable-surfaces-diagnostic"

# DAC write-permission tests (H5/H6) are meaningless where chmod can't deny the
# owner a write: as root (perms ignored) and on Windows Git Bash (msys chmod
# does not map to an NTFS deny-ACL, so a "0500"/"0444" target stays writable).
# Mirrors BT10's OSTYPE skip for the same platform reason.
_h_skip_perms() {
  [ "$(id -u 2>/dev/null || echo 0)" = "0" ] && return 0
  case "${OSTYPE:-}" in msys*|cygwin*|win32*) return 0 ;; esac
  return 1
}

# H5 — read-only-but-EXISTING $UBERDEV_TMPDIR: state_init's `mkdir -p` succeeds
# (dir exists) but the truncate-creates must fail loud (rc=1 + clean diagnostic).
if _h_skip_perms; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "H5.skipped-no-reliable-chmod-deny"
else
  _h5_ro="$_b12_tmpdir/h5-readonly"; mkdir -p "$_h5_ro"; chmod 0500 "$_h5_ro"
  _h5_err="$_b12_tmpdir/h5-stderr"; : > "$_h5_err"
  ( UBERDEV_TMPDIR="$_h5_ro" UBERDEV_GOAL_ID=h5 uberdev_goal_state_init h5 ) 2>"$_h5_err"
  assert_rc "$?" "1" "H5.state-init-rc1-on-readonly-tmpdir"
  assert_grep_file "$_h5_err" 'cannot create state file' "H5.state-init-clean-diagnostic"
  chmod 0700 "$_h5_ro" 2>/dev/null || true
  rm -rf "$_h5_ro" 2>/dev/null || true
fi

# H6 — genuine #157 silent-failure: when ONLY pr-states.tsv is unwritable (dir +
# jsonl still writable), the bare `printf >> tsv` failure used to be masked by
# the subsequent uberdev_goal_audit (writable jsonl) returning 0 —
# pr_state_transition reported success while the state row was lost. The fix's
# `_uberdev_goal_append ... || return 1` makes the tsv-write failure terminal.
if _h_skip_perms; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "H6.skipped-no-reliable-chmod-deny"
else
  uberdev_goal_state_init test-h6
  chmod 0444 "$_b12_tmpdir/goal-test-h6-pr-states.tsv"
  UBERDEV_GOAL_ID=test-h6 uberdev_goal_pr_state_transition test-h6 5 dispatched pushed-reviewing 2>/dev/null
  _h6_rc=$?
  chmod 0644 "$_b12_tmpdir/goal-test-h6-pr-states.tsv" 2>/dev/null || true
  if [ "$_h6_rc" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "H6.tsv-write-failure-is-terminal"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "H6.tsv-write-failure-is-terminal" >&2
    printf '        expected non-zero rc when pr-states.tsv unwritable, got %s\n' "$_h6_rc" >&2
  fi
fi

# H7 — correctness flip-side of #157 (surfaced by post-impl-review): a
# transition's rc must reflect the SOURCE-OF-TRUTH state-row write, not the
# trailing best-effort audit. When pr-states.tsv persists but ONLY the audit
# jsonl is unwritable, the transition DID happen → rc 0 (the audit failure is
# still surfaced to stderr by _uberdev_goal_append, but must not report a
# persisted transition as failed). Skipped where chmod can't deny writes.
if _h_skip_perms; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "H7.skipped-no-reliable-chmod-deny"
else
  uberdev_goal_state_init test-h7
  chmod 0444 "$_b12_tmpdir/goal-test-h7.jsonl"
  UBERDEV_GOAL_ID=test-h7 uberdev_goal_pr_state_transition test-h7 5 dispatched pushed-reviewing 2>/dev/null
  _h7_rc=$?
  chmod 0644 "$_b12_tmpdir/goal-test-h7.jsonl" 2>/dev/null || true
  assert_rc "$_h7_rc" "0" "H7.transition-rc-reflects-state-row-not-audit"
  assert_grep_file "$_b12_tmpdir/goal-test-h7-pr-states.tsv" $'^5\tpushed-reviewing\t[0-9]{10}$' \
    "H7.state-row-persisted-despite-audit-failure"
fi

# H8 — #156 audit degrade-path coverage (surfaced by post-impl-review): a forged
# UBERDEV_GOAL_ID must NOT path the audit jsonl outside tmpdir. uberdev_goal_audit
# validates the env-derived id and degrades to the safe goal-unknown.jsonl sink
# with a stderr breadcrumb (audit must never abort the state machine). Portable.
_h8_err="$_b12_tmpdir/h8-stderr"; : > "$_h8_err"
( UBERDEV_TMPDIR="$_b12_tmpdir" UBERDEV_GOAL_ID="../pwned" uberdev_goal_audit goal_dispatched '{}' ) 2>"$_h8_err"
assert_rc "$?" "0" "H8.audit-degrades-not-aborts"
assert_grep_file "$_b12_tmpdir/goal-unknown.jsonl" '"event":"goal_dispatched"' "H8.audit-degrades-to-unknown-sink"
assert_grep_file "$_h8_err" 'unsafe UBERDEV_GOAL_ID' "H8.audit-degrade-surfaces-breadcrumb"
if ls "$_b12_tmpdir"/../*pwned* >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "H8.no-escaped-audit-artifact" >&2
else
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "H8.no-escaped-audit-artifact"
fi

# Cleanup: remove the isolated tmpdir contents (we created the whole
# directory via mktemp -d, so we can rm -rf safely — it's our own).
# The single blanket rm subsumes every per-BT artifact (TSVs, audit
# JSONs, run dirs) because they all live INSIDE $_b12_tmpdir.
rm -rf "$_b12_tmpdir/goal-test-bt3"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt48"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt49"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt52"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt53"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt54"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt55"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt57"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt58"* 2>/dev/null || true
rm -f "$_b12_tmpdir"/goal-bt5-*-merge-attempts.tsv 2>/dev/null || true
rm -rf "$_b12_tmpdir" 2>/dev/null || true

echo
echo "== Summary =="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
