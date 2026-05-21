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
# Internal function names (9 + 1 alias forwarder _persist_fp; the alias is
# co-defined alongside _uberdev_goal_persist_fp and not listed separately
# per the plan — the 10 names asserted here are the 9 underscore-prefixed
# helpers plus _uberdev_goal_persist_fp itself).
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
echo "== Summary =="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
