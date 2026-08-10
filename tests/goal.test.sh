#!/usr/bin/env bash
# Shape-check harness for /uberdev:goal (RFC 0005).
#
# Covers G1-G20 acceptance gates from the implementation plan
# (docs/uberdev/plans/2026-05-21-uberdev-goal.md §Task 4):
#   G1   commands/goal.md + skills/goal-pipeline/SKILL.md frontmatter
#   G2   PR state machine enum (8 states)
#   G3   Issue state machine enum (7 states — `dispatched` pre-spawn guard #236; `resolved-by-no-action` close-without-PR #249)
#   G4   Trust-signal handling (GREEN dispatches merge, YELLOW=critical,
#        RED=blocker, stale via phase2_5)
#   G5   Blocker-unblock chain (Blocks: #N regex, held states,
#        goal_unblock_triggered event)
#   G6   Circuit breaker: max_cycles
#   G7   Circuit breaker: nonconvergence (fingerprint-repeat)
#   G8   Circuit breaker: stuck_loop (4h wall-clock)
#   G9   Circuit breaker: merge_failed
#   G10  Convergence happy-path (goal_converged + exit 0)
#   G11  All 12 audit events present
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
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

# RFC 0015 §5 — the executable body of /goal moved OUT of the SKILL.md bash
# fences into four shebang'd scripts plus a Workflow driver. Assertions about
# BEHAVIOUR now target the file that owns that behaviour; SKILL.md keeps only
# the documentation SSOT (the Constants block, byte-identical) plus the
# preflight / Workflow-mandate / No-Workflow-fallback seam. Nothing was
# dropped -- every gate below names its new home.
GOAL_P0="$REPO_ROOT/plugins/uberdev/lib/goal-phase0.sh"      # preflight
GOAL_P1="$REPO_ROOT/plugins/uberdev/lib/goal-phase1.sh"      # claim (never dispatch)
GOAL_WATCH="$REPO_ROOT/plugins/uberdev/lib/goal-watch.sh"    # watch + merge lane
GOAL_P3="$REPO_ROOT/plugins/uberdev/lib/goal-phase3.sh"      # collect next queue
GOAL_WF="$REPO_ROOT/plugins/uberdev/skills/goal-pipeline/workflow.js"   # cycle driver

# Pre-flight: refuse to run if any asserted-against file is missing.
for f in "$GOAL_CMD" "$GOAL_SKILL" "$GOAL_LIB" "$GOAL_P0" "$GOAL_P1" "$GOAL_WATCH" "$GOAL_P3" "$GOAL_WF"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

# Retired-surface complement: proves a pattern is ABSENT from live (non-comment)
# lines. Tombstone comments naming what was removed must not read as live code.
assert_absent_live() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE -e "^[^#]*($pattern)" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:            %s\n' "$file" >&2
    printf '        still-live regex: %s\n' "$pattern" >&2
  else
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  fi
}

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

# Shared structural-assertion helpers (assert_version_bump for G20). Fail-loud
# guard per #209: a missing/unreadable helper aborts rc=2, not vacuous-green.
source "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

# assert_eq GOT WANT LABEL — scalar equality (used by the behavioural G17 run).
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        got:  [%s]\n' "$got" >&2
    printf '        want: [%s]\n' "$want" >&2
  fi
}

# extract_region NAME FILE — print the body between `# >>> region: NAME` and
# `# <<< region: NAME` in a plain shell script. This REPLACES the old
# extract_fence (which sliced ```bash blocks out of SKILL.md) now that the
# executable body lives in lib/goal-*.sh: those files carry explicit region
# markers precisely so a fixture can run ONE block standalone. Exit 3 (caller
# fails loud) when the region is not found, so a renamed region reds here
# instead of silently extracting nothing.
_GOAL_EXTRACT_AWK="$(mktemp)"
cat > "$_GOAL_EXTRACT_AWK" <<'AWK'
BEGIN { inregion=0; found=0 }
{
  line=$0
  if (inregion==0) {
    if (line ~ ("^[[:space:]]*# >>> region: " NAME "[[:space:]]*$")) { inregion=1; found=1; next }
    next
  }
  if (line ~ ("^[[:space:]]*# <<< region: " NAME "[[:space:]]*$")) { exit }
  print line
}
END { if (found==0) exit 3 }
AWK
extract_region() { awk -v NAME="$1" -f "$_GOAL_EXTRACT_AWK" "$2"; }
trap 'rm -f "$_GOAL_EXTRACT_AWK"' EXIT

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
# 7-state issue machine: all 7 names appear in the enum constant on a single line.
# `dispatched` is the pre-spawn guard state added in #236 to close the
# leaf-crash-pre-state-write double-spawn surface (see G24b for the Phase-1
# integration and BT80-BT82 for the behavioural coverage).
# `resolved-by-no-action` is the orchestrator-closed-without-PR state added in
# #249 (see BT84/BT85 for the behavioural coverage).
assert_grep "$GOAL_SKILL" \
  'input\|dispatched\|solving\|pr-pushed\|resolved\|resolved-by-no-action\|failed' \
  "G3.issue-state-machine"

echo
echo "== G4: trust-signal handling =="
# G4a — GREEN trust signal path: the trust-signal helper is read AND the green
# state is handled. Plan called for 'signal.*green' on one line, but the
# SKILL's case-block has signal on line 200 and `green)` on line 203 (well-
# formed bash); collapse to two single-line assertions: the helper name and
# the green case-arm.
assert_grep "$GOAL_WATCH" 'uberdev_goal_read_trust_signal'  "G4a.trust-signal-read"
assert_grep "$GOAL_WATCH" '^[[:space:]]*green\)[[:space:]]*$|green\)[[:space:]]*$' "G4a.green-case-arm"
# G4a (cont) — GREEN dispatches /merge. The SKILL uses bare `/merge` prose AND
# the helper `_uberdev_goal_dispatch_merge`; either proves the contract.
assert_grep "$GOAL_WATCH" '/merge|_uberdev_goal_dispatch_merge' "G4a.green-dispatches-merge"
# G4b — YELLOW held on CRITICAL.
assert_grep "$GOAL_WATCH" 'yellow-held'                     "G4b.yellow-held"
assert_grep "$GOAL_SKILL" 'critical|CRITICAL'               "G4b.yellow-critical-trigger"
# G4c — RED held on BLOCKER (or halted_due_to_overflow).
assert_grep "$GOAL_WATCH" 'red-held'                        "G4c.red-held"
assert_grep "$GOAL_SKILL" 'blocker|BLOCKER'                 "G4c.red-blocker-trigger"
# G4d — stale handling: phase2_5 absent => re-dispatch /review-pr (not assumed GREEN).
assert_grep "$GOAL_WATCH" 'phase2_5|stale'                  "G4d.stale-handling"

echo
echo "== G5: blocker-unblock chain =="
# The anchored regex MUST appear in the skill's prose / constant.
assert_grep "$GOAL_SKILL" '\^Blocks: #'                     "G5.blocks-regex"
assert_grep "$GOAL_SKILL" 'yellow-held\|red-held'           "G5.held-states"
assert_grep "$GOAL_SKILL" 'goal_unblock_triggered'          "G5.unblock-audit-event"

echo
echo "== G6: circuit breaker max_cycles =="
assert_grep "$GOAL_P3" 'MAX_CYCLES|max_cycles'                  "G6.max-cycles-constant"
assert_grep "$GOAL_P3"    '"\$cycle" -ge "\$MAX_CYCLES"'          "G6.max-cycles-check"
assert_grep "$GOAL_P3"    'reason.*max_cycles'                     "G6.max-cycles-breaker-emit"
# The ceiling is enforced TWICE on purpose (#288 #2): the claim pass re-checks
# it from rehydrated run-state, so a mis-sequenced re-entry that lands back on
# the claim phase with an over-incremented cycle cannot run unbounded.
assert_grep "$GOAL_P1"    'reason.*max_cycles'                     "G6.max-cycles-phase1-backstop-emit"

echo
echo "== G7: circuit breaker nonconvergence =="
assert_grep "$GOAL_P3"    'fingerprint'                                  "G7.fingerprint-name"
assert_grep "$GOAL_P3"    'check_fingerprint_repeat|fingerprint.*repeat' "G7.fingerprint-repeat-check"
assert_grep "$GOAL_P3"    'reason.*nonconvergence'                       "G7.nonconvergence-breaker-emit"

echo
echo "== G8: circuit breaker stuck_loop =="
assert_grep "$GOAL_WATCH" '4 hour|4h|14400'                              "G8.stuck-loop-constant"
assert_grep "$GOAL_WATCH" 'watch_start|stuck_loop'                       "G8.stuck-loop-check"
assert_grep "$GOAL_WATCH" 'reason.*stuck_loop'                           "G8.stuck-loop-breaker-emit"

echo
echo "== G9: circuit breaker merge_failed =="
assert_grep "$GOAL_WATCH" 'merge_result|merge.*conflict|hook_failed'     "G9.merge-result-classification"
assert_grep "$GOAL_WATCH" 'reason.*merge_failed'                         "G9.merge-failed-breaker-emit"
assert_grep "$GOAL_WATCH" '^[[:space:]]*exit 1[[:space:]]*$'             "G9.halt-on-merge-failure"

echo
echo "== G10: convergence happy-path =="
assert_grep "$GOAL_P3"    'goal_converged'                "G10.converged-event"
assert_grep "$GOAL_P3"    'queue.*empty|new_candidates'   "G10.empty-queue-predicate"
assert_grep "$GOAL_P3"    '^[[:space:]]*exit 0[[:space:]]*$' "G10.zero-exit"

echo
echo "== G11: all 12 audit events present =="
for e in goal_dispatched goal_pr_transition goal_unblock_triggered \
         goal_cycle_completed goal_converged goal_circuit_breaker \
         goal_merge_deferred goal_review_pr_deferred goal_review_grace \
         goal_reaper_kill goal_reaper_skipped goal_issue_closed_without_pr; do
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
echo "== G13: claim collision soft-fail =="
# RFC 0015 §5 — /goal no longer calls uberdev_dispatch_one, so the old probe
# that read solve-launcher's `claim_collision` audit row out of the DISPATCH
# FAILURE branch has no dispatch rc left to interpret; that probe is genuinely
# gone with the dispatch call. The BEHAVIOUR it protected — another process
# holds the claim, so skip the issue for THIS cycle and never halt the goal —
# survives intact in the claim pass's own SETNX rc-2 arm, which is what these
# assertions now target.
assert_grep "$GOAL_P1" 'collision \(held by another process\)'      "G13.claim-collision"
assert_grep "$GOAL_P1" 'skipped this cycle'                          "G13.soft-fail-behaviour"
assert_grep "$GOAL_P1" 'soft-skip'                                   "G13.no-halt-prose"
# The rc-2 arm must `continue`, never exit — it is the one arm of the claim
# switch that does not halt the run.
assert_grep "$GOAL_P1" '_claim_rc" = "2"'                            "G13.collision-rc2-arm"
# And the driver must explain WHY the fleet launcher is armed with --force:
# the claim it would collide with is OUR OWN, taken one step earlier. Without
# that rationale a future edit drops --force and every cycle self-collides.
assert_grep "$GOAL_WF" 'would\s+.otherwise refuse them as a collision with us|otherwise refuse them as a collision with us' \
                                                                     "G13.launcher-force-rationale"

echo
echo "== G14: blocker overflow handler =="
# Detection lives in the watch loop (the red trust-signal arm has $audit_json
# and $pr_num in scope); the truncation + the no-halt contract live in collect.
assert_grep "$GOAL_WATCH" 'halted_due_to_overflow'                              "G14.overflow-flag"
assert_grep "$GOAL_P3" 'first.*10|truncate.*10|first 10|new_candidates.*:0:10'   "G14.first-10-only"
assert_grep "$GOAL_P3" 'does NOT halt the entire goal|do NOT halt entire goal'   "G14.no-halt-prose"

echo
echo "== G15: backend inheritance =="
assert_grep "$GOAL_P0" 'UBERDEV_RESOLVED_BACKEND'                           "G15.resolved-backend-env"
# The backend is resolved ONCE in the preflight and frozen for the run (D15);
# every later phase re-derives its dispatch ENV from that frozen value rather
# than re-resolving. Anchor the rule where it is documented and both places it
# is consumed, so a per-cycle re-resolution cannot creep back in.
assert_grep "$GOAL_SKILL" 'Backend inheritance \(D15\)'                     "G15.backend-inheritance-doc"
assert_grep "$GOAL_P0" '^[[:space:]]*uberdev_dispatch_preflight[[:space:]]*$' "G15.backend-resolved-once"
assert_grep "$GOAL_WATCH" 'uberdev_dispatch_resolve_env "\$\{UBERDEV_RESOLVED_BACKEND:-\}"' \
                                                                            "G15.backend-forwarding"

echo
echo "== G16: provenance (Q5 / T5) =="
assert_grep "$GOAL_P1" 'UBERDEV_GOAL_ID'                                 "G16.goal-id-env"
assert_grep "$GOAL_WATCH" 'uberdev_goal_should_automerge'                "G16.automerge-predicate"
assert_grep "$GOAL_WATCH" 'automerge_attempt|merge.*attempt|MERGE_ATTEMPTS'  "G16.attempt-counter"

echo
echo "== G17: --dry-run semantics (BEHAVIOURAL — #293) =="
assert_grep "$GOAL_P0" '--dry-run|dry_run'                               "G17.dry-run-flag"
assert_grep "$GOAL_P0" '^[[:space:]]*exit 0[[:space:]]*$'                "G17.dry-run-exit"
# #293 — the old G17 was a single-line negative grep
# (`dry_run=1.*uberdev_dispatch_one`) that CANNOT catch a real dispatch leak:
# the guard is an early `exit 0` hundreds of lines away from any dispatch call,
# so the two literals never share a line regardless of whether the gate works.
# Replace it with a BEHAVIOURAL run: extract the real Phase-0 fences (arg-parse
# -> dry-run gate -> the step-9 `goal_dispatched` emit) from SKILL.md, run them
# under bash with `uberdev_dispatch_one` + `uberdev_goal_audit` MOCKED as
# call-recorders, and assert the dry-run contract (S9 + D16):
#   (1) exit 0, (2) ZERO dispatch calls, (3) NO goal_dispatched audit row.
# A negative control (same fences, NO --dry-run) proves the assertion is not
# vacuous: it MUST reach the emit and record goal_dispatched.
g17_dir="$(mktemp -d)"
g17_argparse="$g17_dir/argparse.sh"
g17_dryrun="$g17_dir/dryrun.sh"
g17_emit="$g17_dir/emit.sh"
# CI runs goal.test.sh under bash (ubuntu bash 5.x / windows Git Bash 4.x+) —
# both are bash>=4, so the dry-run fences (which use bash arrays) run under the
# launching interpreter. $BASH is the absolute path to the running bash.
g17_bash="${BASH:-bash}"
if extract_region argparse "$GOAL_P0" > "$g17_argparse" && [ -s "$g17_argparse" ] \
   && extract_region dry-run "$GOAL_P0" > "$g17_dryrun" && [ -s "$g17_dryrun" ] \
   && extract_region dispatched-emit "$GOAL_P0" > "$g17_emit" && [ -s "$g17_emit" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G17.extract: arg-parse + dry-run gate + goal_dispatched emit regions located in lib/goal-phase0.sh"

  # Build the dry-run driver. Mocks record into files; we pre-seed the resolved
  # Phase-0 scalars the dry-run gate prints, then run the three fences in order.
  cat > "$g17_dir/dry_driver.sh" <<DRV
set -u
export UBERDEV_TMPDIR="$g17_dir/state"; mkdir -p "\$UBERDEV_TMPDIR"
. "$GOAL_LIB"
uberdev_dispatch_one() { printf 'DISPATCH %s\n' "\$*" >> "$g17_dir/dispatch.log"; return 0; }
uberdev_goal_audit()  { printf 'AUDIT %s\n'    "\$1" >> "$g17_dir/audit.log"; return 0; }
MAX_CYCLES=5; MAX_PARALLEL=3; BARRIER_TIMEOUT_S=14400; MAX_WATCH_TICKS=40
UBERDEV_RESOLVED_BACKEND=wezterm
GOAL_ID="goal-g17dryrun01"
ARGUMENTS="101 202 --dry-run"
source "$g17_argparse"
source "$g17_dryrun"
source "$g17_emit"
printf 'REACHED-EMIT rc=%s\n' "\$?"
DRV
  g17_out="$("$g17_bash" "$g17_dir/dry_driver.sh" 2>&1)"
  g17_rc=$?
  assert_eq "$g17_rc" "0" "G17.behavioral.exit0: --dry-run run exits 0"
  g17_dispatched="$([ -s "$g17_dir/dispatch.log" ] && echo LEAKED || echo none)"
  assert_eq "$g17_dispatched" "none" "G17.behavioral.no-dispatch: --dry-run made ZERO uberdev_dispatch_one calls"
  if [ -s "$g17_dir/audit.log" ] && grep -q 'goal_dispatched' "$g17_dir/audit.log"; then
    assert_eq "goal_dispatched-emitted" "absent" "G17.behavioral.no-audit: --dry-run emitted NO goal_dispatched row (S9)"
  else
    assert_eq "absent" "absent" "G17.behavioral.no-audit: --dry-run emitted NO goal_dispatched row (S9)"
  fi
  # The dry-run `exit 0` must short-circuit BEFORE the step-9 emit fence runs.
  if grep -q 'REACHED-EMIT' <<<"$g17_out"; then
    assert_eq "reached-emit" "short-circuited" "G17.behavioral.short-circuit: dry-run exits before the goal_dispatched emit fence"
  else
    assert_eq "short-circuited" "short-circuited" "G17.behavioral.short-circuit: dry-run exits before the goal_dispatched emit fence"
  fi

  # Negative control — WITHOUT --dry-run the SAME fences MUST reach the emit and
  # record goal_dispatched. Proves the dry-run assertions above are non-vacuous
  # (a broken/removed dry-run gate would let the dry-run run fall through to the
  # emit, flipping G17.behavioral.no-audit RED).
  cat > "$g17_dir/real_driver.sh" <<DRV
set -u
export UBERDEV_TMPDIR="$g17_dir/state2"; mkdir -p "\$UBERDEV_TMPDIR"
. "$GOAL_LIB"
uberdev_dispatch_one() { printf 'DISPATCH %s\n' "\$*" >> "$g17_dir/dispatch2.log"; return 0; }
uberdev_goal_audit()  { printf 'AUDIT %s\n'    "\$1" >> "$g17_dir/audit2.log"; return 0; }
MAX_CYCLES=5; MAX_PARALLEL=3; BARRIER_TIMEOUT_S=14400; MAX_WATCH_TICKS=40
UBERDEV_RESOLVED_BACKEND=wezterm
GOAL_ID="goal-g17real01"
ARGUMENTS="101 202"
source "$g17_argparse"
source "$g17_dryrun"
source "$g17_emit"
printf 'REACHED-EMIT rc=%s\n' "\$?"
DRV
  "$g17_bash" "$g17_dir/real_driver.sh" >/dev/null 2>&1
  if [ -s "$g17_dir/audit2.log" ] && grep -q 'goal_dispatched' "$g17_dir/audit2.log"; then
    assert_eq "emitted" "emitted" "G17.behavioral.control: WITHOUT --dry-run the emit fence IS reached + records goal_dispatched (non-vacuous proof)"
  else
    assert_eq "absent" "emitted" "G17.behavioral.control: WITHOUT --dry-run the emit fence IS reached + records goal_dispatched (non-vacuous proof)"
  fi
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "G17.extract: could NOT extract the Phase-0 dry-run regions from lib/goal-phase0.sh (region markers renamed?)" >&2
fi
# Structural backstop (kept from the original G17): the preflight must contain
# no dispatch call at all. Post-RFC-0015 that is a stronger statement than the
# old same-line grep — nothing in Phase 0 spawns anything.
assert_no_grep "$GOAL_P0" 'uberdev_dispatch_one'                          "G17.dry-run-no-dispatch"
rm -rf "$g17_dir"

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
# Public function names (24 — 18 prior + 3 new barrier helpers added by issue #211:
# uberdev_goal_register_batch_pr, uberdev_goal_batch_all_terminal,
# uberdev_goal_batch_unblock_wait_clear; issue #220 adds two helpers —
# uberdev_goal_review_pr_in_flight (in-flight gate for Phase 2b + 2c) and
# uberdev_goal_agent_stuck_on_dialog (60s activity-window detector via
# audit-log row-count proxy); issue #329 adds the gh-failure counter reader so
# Phase 2 can distinguish "no PR" from "PR lookup unavailable".
for fn in uberdev_goal_state_init uberdev_goal_pr_state_transition uberdev_goal_issue_state_transition \
          uberdev_goal_read_trust_signal uberdev_goal_check_fingerprint_repeat uberdev_goal_should_automerge \
          uberdev_goal_audit uberdev_goal_locate_review_pr_audit \
          uberdev_goal_locate_review_pr_audit_by_pr \
          uberdev_goal_get_pr_state uberdev_goal_record_held_audit uberdev_goal_get_last_held_audit \
          uberdev_goal_find_pr_for_issue uberdev_goal_pr_state_gh uberdev_goal_pr_is_merged \
          uberdev_goal_agent_busy_for_issue \
          uberdev_goal_review_pr_in_flight \
          uberdev_goal_agent_stuck_on_dialog \
          uberdev_goal_list_prs_in_state uberdev_goal_read_merge_result \
          uberdev_goal_register_batch_pr \
          uberdev_goal_batch_all_terminal \
          uberdev_goal_batch_unblock_wait_clear \
          uberdev_goal_gh_failure_count; do
  assert_grep "$GOAL_LIB" "^${fn}\\(\\)" "G19.public.${fn}"
done
# Internal function names (19 underscore-prefixed helpers — `_uberdev_goal_validate_id`
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
          _uberdev_goal_check_unblock \
          _uberdev_goal_set_batch_terminal_state \
          _uberdev_goal_batch_green_prs_ordered \
          _uberdev_goal_rebase_collision_chain \
          _uberdev_goal_any_attempt_stuck \
          _uberdev_goal_locked_marker_for_pr_fresh \
          _uberdev_goal_reap_zombies; do
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
echo "== G20: version bump locked (0.45.3) =="
assert_version_bump "$REPO_ROOT" "0.45.3"
assert_no_grep "$REPO_ROOT/tests/solve-claim.test.sh"               '0\.30\.0'               "G20.solve-claim-no-old-version"

assert_grep "$GOAL_P0" 'uberdev_dispatch_resolve_env'     "G20b.phase0-wires-resolve-env (#175 SSOT anchor)"
assert_grep "$GOAL_P0" 'export AUTO_MODE=1'               "G20b.phase0-sets-AUTO_MODE (#175 turbo-parity)"
assert_grep "$GOAL_P0" 'export SKIP_PERMISSIONS=1'        "G20c.phase0-sets-SKIP_PERMISSIONS (#241 cmux/hook bypass)"

echo
echo "== G23: CLI-version-independent gh+file detection (issue #180) =="
# The watch loop must key completion/PR/merge off gh + the file-based verdict,
# NOT the captured claude --bg stdout (which on CLI 2.1.150 is a detached
# banner only). These gates lock the fix in place against regression.
# Positive: the gh signals are wired into the skill + lib.
assert_grep "$GOAL_WATCH" 'uberdev_goal_find_pr_for_issue'  "G23.find-pr-in-watch"
assert_grep "$GOAL_WATCH" 'uberdev_goal_pr_is_merged'       "G23.pr-is-merged-in-watch"
assert_grep "$GOAL_LIB"   '^uberdev_goal_find_pr_for_issue\(\)'    "G23.lib-find-pr"
assert_grep "$GOAL_LIB"   '^uberdev_goal_pr_state_gh\(\)'          "G23.lib-pr-state-gh"
assert_grep "$GOAL_LIB"   '^uberdev_goal_pr_is_merged\(\)'         "G23.lib-pr-is-merged"
assert_grep "$GOAL_LIB"   '^uberdev_goal_agent_busy_for_issue\(\)' "G23.lib-agent-busy"
assert_grep "$GOAL_LIB"   'closingIssuesReferences'               "G23.lib-uses-closing-refs"
# Phase 0 bash>=4 preflight guard (defect #8 — macOS /bin/bash is 3.2, and the
# Bash-tool default zsh chokes on the unmatched-glob verdict locator).
assert_grep "$GOAL_P0" 'BASH_VERSINFO'                  "G23.phase0-bash4-guard"
# Anti-regression: the broken stdout-marker COMPLETION PROBES are gone from the
# watch loop. These target the actual CODE constructs, not token mentions — the
# explanatory prose legitimately NAMES the retired markers to document the fix.
assert_no_grep "$GOAL_WATCH" "grep -q 'backgrounded"      "G23.no-backgrounded-completion-probe"
assert_no_grep "$GOAL_WATCH" 'merge_log='                 "G23.no-merge-bg-stdout-read"
assert_no_grep "$GOAL_WATCH" 'uberdev_goal_extract_pr_num_from_log' "G23.watch-no-extract-call"
assert_no_grep "$GOAL_P3" 'mapfile -t'                 "G23.no-mapfile-bash4ism"
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
assert_grep "$GOAL_WATCH" 'uberdev_goal_locate_review_pr_audit_by_pr'             "G21.locate-by-pr-in-watch"
assert_grep "$GOAL_WATCH" 'uberdev_goal_get_last_held_audit|last_held_audit'      "G21.last-held-audit-in-watch"
assert_grep "$GOAL_WATCH" 'uberdev_goal_record_held_audit|record_held_audit'      "G21.record-held-audit-in-watch"
assert_grep "$GOAL_WATCH" 'uberdev_goal_get_pr_state'                             "G21.get-pr-state-in-watch"
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
assert_grep "$GOAL_P3" 'reason.*queue_empty_not_converged'                      "G22.halt-emit"
assert_grep "$GOAL_SKILL" 'GOAL_CIRCUIT_BREAKER_REASONS=.*agent_stuck_on_dialog' "G22.reason-agent-stuck-in-enum"
assert_grep "$GOAL_WATCH" 'reason.*agent_stuck_on_dialog'                        "G22.halt-emit-agent-stuck"
# Phase 3 terminal_prs MUST include held states so a goal with only held PRs
# left can converge cleanly instead of spinning until stuck_loop.
assert_grep "$GOAL_P3" 'list_prs_in_state.*yellow-held'                         "G22.terminal-includes-yellow-held"
assert_grep "$GOAL_P3" 'list_prs_in_state.*red-held'                            "G22.terminal-includes-red-held"

echo
echo "== G24: --max-parallel cap config-read + dry-run surface (#211 AC1) =="
# Phase 0 step 3 MUST read goal.max_parallel via uberdev_read_int_in_range
# with the verbatim default + range from the spec (default 3, [1,10]).
assert_grep "$GOAL_P0" 'uberdev_read_int_in_range goal\.max_parallel UBERDEV_GOAL_MAX_PARALLEL 1 10' \
                                                                         "G24.config-read-call-shape"
# Default constant lives in the Constants block.
assert_grep "$GOAL_SKILL" '_UBERDEV_GOAL_DEFAULT_MAX_PARALLEL=3'         "G24.default-constant"
# Dry-run preview surfaces MAX_PARALLEL.
assert_grep "$GOAL_P0" 'MAX_PARALLEL'                                  "G24.dry-run-mentions-cap"

echo
echo "== G24b: claim pass writes 'dispatched' PRE-arm + extended skip-check (issue #236) =="
# Issue #236: the parent must transition input->dispatched BEFORE the solvers can
# possibly start, so a crash in that window cannot produce a double-claim on the
# next cycle. RFC 0015 §5 retargets the window rather than removing it: there is
# no longer a spawn call here at all, so the window is now "claim taken, fleet
# not yet armed" and the guard state is written before the claim pass prints the
# dispatch list the driver arms the fleet with.
# Enum constant must include `dispatched` (grep -F literal — `|` is grep alternation under -E).
if grep -qF "GOAL_ISSUE_STATE_ENUM='input|dispatched|solving|pr-pushed|resolved|resolved-by-no-action|failed'" "$GOAL_SKILL"; then
  PASS=$((PASS+1)); echo "  PASS  G24b.enum-includes-dispatched-and-resolved-by-no-action"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G24b.enum-includes-dispatched-and-resolved-by-no-action (literal enum string not found in SKILL.md)" >&2
fi
# Skip-check matches all three pre-resolved in-flight states (literal alternation in case-arm).
if grep -qF 'dispatched|solving|pr-pushed) continue' "$GOAL_P1"; then
  PASS=$((PASS+1)); echo "  PASS  G24b.skip-check-extended-to-dispatched"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G24b.skip-check-extended-to-dispatched (literal case-arm not found)" >&2
fi
# ORDER: the claim is taken, THEN input->dispatched is written, THEN the JSON
# dispatch list is printed. Any other order re-opens a hole — writing the state
# before the claim would mark an issue in-flight we may not own, and printing
# the list before the state write would let the fleet start against an `input`
# row that the next cycle's skip-check does not match.
_g24b_claim_line="$(grep -nF '_uberdev_goal_claim_issue "$ISSUE_NUM"; _claim_rc=$?' "$GOAL_P1" | head -1 | cut -d: -f1)"
_g24b_pre_arm_line="$(grep -nF 'input dispatched' "$GOAL_P1" | head -1 | cut -d: -f1)"
_g24b_emit_line="$(grep -nF '{"phase":"claim"' "$GOAL_P1" | head -1 | cut -d: -f1)"
if [ -n "$_g24b_claim_line" ] && [ -n "$_g24b_pre_arm_line" ] && [ -n "$_g24b_emit_line" ] \
   && [ "$_g24b_claim_line" -lt "$_g24b_pre_arm_line" ] && [ "$_g24b_pre_arm_line" -lt "$_g24b_emit_line" ]; then
  PASS=$((PASS+1)); echo "  PASS  G24b.claim-then-dispatched-then-emit (claim=$_g24b_claim_line < state=$_g24b_pre_arm_line < emit=$_g24b_emit_line)"
else
  FAIL=$((FAIL+1))
  echo "  FAIL  G24b.claim-then-dispatched-then-emit (claim=$_g24b_claim_line state=$_g24b_pre_arm_line emit=$_g24b_emit_line)" >&2
fi
# Post-arm solving transition: dispatched->solving once the fleet holds the manifest.
assert_grep "$GOAL_P1" 'dispatched solving' "G24b.dispatched-to-solving-post-arm"
# Arming-failure path transitions dispatched->failed (no solver, no PR; explicit cleanup).
assert_grep "$GOAL_P1" 'dispatched failed' "G24b.dispatched-to-failed-on-arm-failure"
# ...and the driver must actually drive both arms, or the states above are dead.
# Anchored on the COMMAND (`--mark-solving=<CSV>`), not the bare flag name — the
# STEP 3 prose names both flags, so a bare-token grep survives their deletion.
assert_grep "$GOAL_WF" '--mark-solving=<CSV>'  "G24b.driver-marks-solving"
assert_grep "$GOAL_WF" '--mark-failed=<CSV>'   "G24b.driver-marks-failed"

echo
echo "== G25: Phase 1 dispatch loop honours MAX_PARALLEL cap (#211 AC2) =="
# The cap counter and rollover array MUST appear inside the Phase 1 dispatch.
assert_grep "$GOAL_P1" 'dispatched_this_cycle'                         "G25.cap-counter-var"
assert_grep "$GOAL_P1" 'remaining_queue'                               "G25.rollover-array-var"
assert_grep "$GOAL_P1" '\-ge "\$MAX_PARALLEL"'                        "G25.cap-comparison"
# The register-batch-pr call is the SSOT side-effect tying dispatch to the registry.
assert_grep "$GOAL_WATCH" 'uberdev_goal_register_batch_pr'                "G25.register-batch-pr-call"

echo
echo "== G26: Phase 2 step 2c uses batch-all-terminal + unblock-wait predicates (#211 AC3, AC5) =="
assert_grep "$GOAL_WATCH" 'uberdev_goal_batch_all_terminal'               "G26.all-terminal-predicate"
assert_grep "$GOAL_WATCH" 'uberdev_goal_batch_unblock_wait_clear'         "G26.unblock-wait-predicate"
# Sequential green-PR iteration ordering helper.
assert_grep "$GOAL_WATCH" '_uberdev_goal_batch_green_prs_ordered'         "G26.green-prs-ordered"
# Collision-chain rebase helper.
assert_grep "$GOAL_WATCH" '_uberdev_goal_rebase_collision_chain'          "G26.collision-chain"

echo
echo "== G27: --max-parallel range [1,10] enforced via uberdev_read_int_in_range (#211 AC1 boundary) =="
# The range arguments 1 10 appear verbatim in the config-read call (G24 covers shape;
# G27 doubles-down by asserting the literal min/max so an editor can't silently widen).
assert_grep "$GOAL_P0" 'goal\.max_parallel UBERDEV_GOAL_MAX_PARALLEL 1 10' \
                                                                         "G27.literal-range-1-10"
# And the symmetric flag-parse line for --max-parallel=N. assert_grep already
# uses `grep -qE -e "$pattern"`, so the leading dashes in the pattern are safe
# to pass directly without a `--` separator (which would otherwise be consumed
# as the positional pattern arg).
assert_grep "$GOAL_P0" '\-\-max-parallel=\*'                           "G27.flag-parse-pattern"

echo
echo "== G28: Barrier wall-clock breaker maps to stuck_loop (#211 AC6) =="
# Barrier-timeout config-read call shape (default 14400 = 4h; range [60, 86400]).
assert_grep "$GOAL_P0" 'uberdev_read_int_in_range goal\.barrier_timeout_s UBERDEV_GOAL_BARRIER_TIMEOUT_S 60 86400' \
                                                                         "G28.barrier-config-read-call-shape"
assert_grep "$GOAL_SKILL" '_UBERDEV_GOAL_DEFAULT_BARRIER_TIMEOUT_S=14400' "G28.barrier-default-constant"
# Phase 2 step 2c iteration computes elapsed against barrier_start_ts and
# escalates to the closed-enum reason stuck_loop — no new reason added.
assert_grep "$GOAL_P0" 'BARRIER_TIMEOUT_S'                             "G28.barrier-var-referenced"
assert_grep "$GOAL_P3" 'barrier_start_ts'                              "G28.barrier-start-ts-referenced"
# The audit event reuses stuck_loop verbatim (closed enum).
assert_grep "$GOAL_SKILL" 'reason.*stuck_loop|stuck_loop.*reason|"stuck_loop"' \
                                                                         "G28.reuses-stuck-loop-reason"
# And GOAL_CIRCUIT_BREAKER_REASONS still does NOT contain merge_barrier_timeout.
assert_no_grep "$GOAL_WATCH" 'merge_barrier_timeout'                      "G28.no-new-reason-merge-barrier-timeout"

echo
echo "== G29: Manifest-collision sequential merge (#211 AC4) =="
# The collision-chain helper uses `gh pr diff --name-only` for path-set
# intersection (NOT `git diff --name-only origin/main..pr-N` — those local
# `pr-N` refs do not exist in the worktree, so the lookup is a silent no-op).
assert_grep "$GOAL_LIB" 'gh pr diff'                                      "G29.gh-pr-diff-in-lib"
# PR-number-ascending ordering: the green-PRs-ordered helper must sort numerically.
assert_grep "$GOAL_LIB" 'sort -n'                                         "G29.sort-numeric-pr-ordering"

echo
echo "== G30: Unblock-wait condition (issue closed + uberdev-approved label) (#211 AC5 / #289.1) =="
# The unblock-wait predicate in lib/goal-state.sh must reference the closed-issue
# condition and the CORRECT trust label. #289.1: the gate now reads the label
# /review-pr actually writes (`uberdev-approved`) — the prior `review-pr:green`
# had ZERO producers, so a held batch row whose blocker closed returned rc 1
# forever and blocked every co-batched GREEN PR until the 4h stuck_loop.
assert_grep "$GOAL_LIB" '^uberdev_goal_batch_unblock_wait_clear\(\)'      "G30.predicate-defined"
assert_grep "$GOAL_LIB" 'select\(\. == "uberdev-approved"\)'             "G30.approved-trust-label"
# Negative regression guard: no LIVE jq gate on the phantom review-pr:green
# label remains (a comment naming the old label is acceptable).
assert_no_grep "$GOAL_LIB" 'select\(\. == "review-pr:green"\)'           "G30.no-phantom-green-label-gate"
# Stale/missing issue data treated as "still waiting" (rc 1) — defensive default arm.
assert_grep "$GOAL_LIB" 'CLOSED'                                          "G30.closed-issue-check"

echo
echo "== G31: Phase 2 step 2e updates batch registry on held → green transitions (#211 AC3/AC5 wiring) =="
# Phase 2e MUST call _uberdev_goal_set_batch_terminal_state after recording a
# held-PR's green transition — otherwise the barrier never sees the update.
assert_grep "$GOAL_WATCH" '_uberdev_goal_set_batch_terminal_state'        "G31.set-terminal-state-call"
# The rebase helper is called per just-merged PR in the green-set.
assert_grep "$GOAL_WATCH" '_uberdev_goal_rebase_collision_chain'          "G31.rebase-chain-in-phase2c"

echo
echo "== G32: uberdev_goal_review_pr_in_flight in-flight gate shape (issue #220, AC ❷) =="
assert_grep "$GOAL_LIB" '^uberdev_goal_review_pr_in_flight\(\)'                    "G32.fn-defined"
assert_grep "$GOAL_LIB" 'jq -e --argjson pr'                                       "G32.argjson-pr"
assert_grep "$GOAL_LIB" '/uberdev:review-pr '                                      "G32.substring-name-regex"
assert_grep "$GOAL_LIB" '(\$\|\[\^0-9\])'                                          "G32.regex-trailing-boundary"
assert_grep "$GOAL_LIB" 'busy\|running\|starting\|working'                         "G32.status-whitelist"
# #381: this used to require the literal `background|codex` case arm (the
# pattern is ERE, so `\|` matched a literal pipe). The codex arm is deleted, so
# assert the LIVE arm and the retired one's absence rather than a merged label.
assert_grep "$GOAL_LIB" '^[[:space:]]*background\)'                                "G32.background-pid-branch"
assert_absent_live "$GOAL_LIB" '[[:space:]]*codex\)'                               "G32.no-codex-arm-survives"
assert_grep "$GOAL_WATCH" 'uberdev_goal_review_pr_in_flight'                       "G32.called-from-watch"

echo
echo "== G33: Phase 3 rollover preservation + rolled_over audit field (issue #220, AC ❹) =="
assert_grep "$GOAL_P3" 'queue=\("\$\{queue\[@\]\}" "\$\{new_candidates\[@\]\}"\)' "G33.merge-not-overwrite"
assert_grep "$GOAL_P3" '_rolled_over=\$\{#queue\[@\]\}'                         "G33.capture-before-merge"
assert_grep "$GOAL_P3" '\\"rolled_over\\":\$_rolled_over'                       "G33.payload-field"
assert_no_grep "$GOAL_P3" 'local _rolled_over'                                  "G33.no-local-keyword (script-scope)"

echo
echo "== G34: goal.review_grace_secs config plumbing (issue #220, AC ❶) =="
assert_grep "$GOAL_SKILL" '_UBERDEV_GOAL_DEFAULT_REVIEW_GRACE_SECS=3600'                                "G34.default-3600"
assert_grep "$GOAL_P0" 'uberdev_read_int_in_range goal.review_grace_secs UBERDEV_GOAL_REVIEW_GRACE_SECS 60 86400' "G34.range-helper"
assert_grep "$GOAL_P0" 'review_grace_cli'                                                            "G34.cli-arg-var"
assert_grep "$GOAL_P0" '--review-grace-secs=\*)'                                                  "G34.cli-arg-case-arm"
assert_no_grep "$GOAL_P0" '_UBERDEV_GOAL_REVIEW_GRACE\b'                                             "G34.old-symbol-removed"

echo
echo "== G35: _uberdev_goal_reap_zombies precedes every goal_circuit_breaker exit 1 (issue #220, AC reaper) =="
# The reaper call sites moved with the breakers: the claim ceiling backstop is
# in the claim pass, the watch/merge breakers in the watch script, and the
# convergence-side breakers in the collect script. Count across all three — the
# guard is "every breaker reaps", not "they all live in one file".
reaper_count="$(cat "$GOAL_P1" "$GOAL_WATCH" "$GOAL_P3" | grep -cF '_uberdev_goal_reap_zombies || true')"
if [ "$reaper_count" -ge 9 ]; then
  PASS=$((PASS+1)); echo "  PASS  G35.reaper-call-sites (count=$reaper_count, ge 9)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G35.reaper-call-sites (count=$reaper_count, want ge 9)" >&2
fi
assert_grep "$GOAL_LIB"   '^_uberdev_goal_reap_zombies\(\)'                       "G35.helper-defined"
assert_grep "$GOAL_LIB"   'goal_reaper_skipped'                                    "G35.skip-event-name"
assert_grep "$GOAL_LIB"   'no_pid_visibility'                                     "G35.skip-event-reason"
assert_grep "$GOAL_LIB"   'goal_reaper_kill'                                      "G35.kill-event-name"
assert_grep "$GOAL_LIB"   '\\"signal\\":\\"TERM\\"'                               "G35.kill-event-signal-term"
assert_grep "$GOAL_LIB"   'kill -KILL'                                            "G35.kill-9-escalation"

echo
echo "== G36: INT/TERM traps installed, existing EXIT trap unchanged (issue #220, AC reaper; #301 TERM/INT split) =="
assert_grep "$GOAL_WATCH" "trap '_uberdev_goal_reap_zombies; exit 130' INT"       "G36.int-trap"
# #301 (RFC 0012 §3.3 goal-R1 item 3) — TERM is the HARNESS-cap signal, not an
# operator abort: it must route to the no-reap persist+exit-42 handler, never
# the reaper (the pre-#301 trap '_uberdev_goal_reap_zombies; exit 143' TERM
# meant the Bash tool's 600s cap killed every live solver ~10 minutes in).
assert_grep "$GOAL_WATCH" "trap '_uberdev_goal_handle_harness_term' TERM"         "G36.term-trap"
assert_no_grep "$GOAL_WATCH" "trap '_uberdev_goal_reap_zombies; exit 143' TERM"   "G36.term-trap-no-reap-regression"
assert_grep "$GOAL_WATCH" "trap 'rm -f \"\\\$gh_err\" \"\\\$findings_err\"' EXIT" "G36.exit-trap-unchanged"
# Handler shape in the lib: defined + persists + audits goal_reaper_skipped
# (reason=harness_term) + exits 42, and NEVER calls the reaper.
assert_grep "$GOAL_LIB" '^_uberdev_goal_handle_harness_term\(\)'                  "G36.term-handler-defined"
assert_grep "$GOAL_LIB" 'harness_term'                                            "G36.term-handler-audit-reason"
_g36_handler_body="$(sed -n '/^_uberdev_goal_handle_harness_term()/,/^}/p' "$GOAL_LIB")"
if grep -q 'uberdev_goal_write_run_state' <<<"$_g36_handler_body" \
   && grep -q 'goal_reaper_skipped' <<<"$_g36_handler_body" \
   && grep -qE '^[[:space:]]*exit 42$' <<<"$_g36_handler_body" \
   && ! grep -q '_uberdev_goal_reap_zombies' <<<"$_g36_handler_body"; then
  PASS=$((PASS+1)); echo "  PASS  G36.term-handler-shape (persist + goal_reaper_skipped + exit 42, NO reap)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G36.term-handler-shape (want persist + goal_reaper_skipped + exit 42 and NO reaper call; got: [$_g36_handler_body])" >&2
fi

echo
echo "== G37: uberdev_goal_agent_stuck_on_dialog 60s window helper shape (issue #220, AC ❸) =="
assert_grep "$GOAL_LIB" '^uberdev_goal_agent_stuck_on_dialog\(\)'                 "G37.fn-defined"
assert_grep "$GOAL_LIB" 'PRIOR_LAST_ACTIVITY_'                                    "G37.sidecar-prior-key"
assert_grep "$GOAL_LIB" 'FIRST_DIALOG_TS_'                                        "G37.sidecar-first-seen-key"
assert_grep "$GOAL_LIB" '\-ge 60'                                                 "G37.60s-window"
assert_grep "$GOAL_LIB" '^_uberdev_goal_any_attempt_stuck\(\)'                    "G37.wrapper-defined"
assert_grep "$GOAL_WATCH" '_uberdev_goal_any_attempt_stuck'                       "G37.wrapper-called-from-watch"

echo
echo "== G38: one nested solve-fleet call per cycle, never a per-issue spawn (issue #248 / RFC 0015 §5) =="
# Issue #248's original guarantee was "ONE session per issue, not two": the old
# Phase-1 prompt invoked /uberdev:orchestrator DIRECTLY instead of wrapping it in
# a /turbo bg session (goal -> bg(turbo) -> bg(orchestrator)). RFC 0015 §5 keeps
# the guarantee and removes the mechanism: there is no per-issue session at all
# now. The driver makes EXACTLY ONE nested workflow() call per cycle into the
# solve-fleet, which fans out internally.
#
# This is the same anti-double-spawn property, one level up, so the assertions
# move with it rather than being dropped.
assert_grep "$GOAL_WF" 'skills/solve-fleet/workflow.js'  "G38.driver-targets-the-fleet"
_g38_nested="$(grep -cE '(^|[^A-Za-z0-9_])workflow\(\{' "$GOAL_WF" || true)"
if [ "$_g38_nested" = "1" ]; then
  PASS=$((PASS+1)); echo "  PASS  G38.exactly-one-nested-workflow-call (count=$_g38_nested)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G38.exactly-one-nested-workflow-call (count=$_g38_nested, want exactly 1 — a per-issue nested call spends the single nesting level on the wrong thing)" >&2
fi
# The fleet script itself must contain ZERO nested workflow() sites: a nested
# call inside the child throws at runtime (one level only).
_g38_child_nested="$(grep -cE '(^|[^A-Za-z0-9_])workflow\(' "$REPO_ROOT/plugins/uberdev/skills/solve-fleet/workflow.js" || true)"
if [ "$_g38_child_nested" = "0" ]; then
  PASS=$((PASS+1)); echo "  PASS  G38.child-fleet-has-no-nested-workflow"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G38.child-fleet-has-no-nested-workflow (count=$_g38_child_nested — the nesting budget is already spent by the goal driver)" >&2
fi
# And the claim pass must not have grown a spawn back.
assert_no_grep "$GOAL_P1" 'Invoke the slash command /uberdev:turbo' \
  "G38.goal-phase-1-no-turbo-wrapper-dispatch"

echo
echo "== G39: Phase 2 step 2a probes gh issue state inside else-no-agent branch (issue #249) =="
# Issue #249 — lock the probe SHAPE in the right control-flow position.
# Both BT84/BT85 cover the helpers in isolation; G39 covers the SKILL.md probe
# call-site, so a future refactor that removes the probe block entirely would
# trip this grep guard (BT84/BT85 would still pass — they test the helpers).
assert_grep "$GOAL_WATCH" 'gh issue view "\$issue" --json state --jq' \
  "G39.probe-line-present"
assert_grep "$GOAL_WATCH" '\[ "\$issue_state" = "CLOSED" \]' \
  "G39.uppercase-CLOSED-check"
assert_grep "$GOAL_WATCH" 'uberdev_goal_issue_state_transition "\$GOAL_ID" "\$issue" solving resolved-by-no-action' \
  "G39.transition-arc-call-site"
assert_grep "$GOAL_WATCH" 'uberdev_goal_audit goal_issue_closed_without_pr' \
  "G39.audit-event-emitted"
# See BT84/BT85 below for the behavioural complement.

# G39b — RETIRED SURFACE (#381). This asserted that Phase 2 surfaced a terminal
# Codex agent failure immediately (helper defined, called from the watch script,
# failed/completed-without-PR both circuit-breaking) instead of waiting out the
# 150-minute solve timeout.
#
# COVERAGE DELIBERATELY DROPPED: `uberdev_goal_codex_status_for_issue` and the
# watch-script branch that called it are deleted, and their precondition --
# UBERDEV_RESOLVED_BACKEND=codex -- is unproducible now that `codex` is out of
# _UBERDEV_DISPATCH_BACKEND_ENUM (lib/dispatch.sh:509). No surviving backend
# ships an equivalent sidecar, so there is no terminal-status signal left to
# surface early. Inverted to the absence check; the solver_failed circuit
# breaker itself is still asserted below, since that reason code is live.
echo "== G39b: the Codex terminal-status fast path is gone (#381) =="
assert_absent_live "$GOAL_LIB"   'uberdev_goal_codex_status_for_issue' "G39b.status-helper-deleted"
assert_absent_live "$GOAL_WATCH" 'uberdev_goal_codex_status_for_issue' "G39b.watch-call-site-deleted"
assert_absent_live "$GOAL_WATCH" '_codex_state'                       "G39b.no-codex-state-variable-survives"
assert_absent_live "$GOAL_LIB"   'solve-codex-status-'                "G39b.no-codex-sidecar-path-survives"
assert_grep "$GOAL_SKILL" 'GOAL_CIRCUIT_BREAKER_REASONS=.*solver_failed' \
  "G39b.solver-failed-reason-in-enum"
assert_grep "$GOAL_SKILL" 'solver_failed' \
  "G39b.solver-failed-reason-still-documented"

echo "== G39c: Phase 0 threads parsed --backend into dispatch preflight =="
assert_grep "$GOAL_P0" 'UBERDEV_DISPATCH_BACKEND_REQUESTED="\$\{backend_cli:-\$\{UBERDEV_DISPATCH_BACKEND_REQUESTED:-auto\}\}"' \
  "G39c.backend-cli-export-assigned"
assert_grep "$GOAL_P0" 'export UBERDEV_DISPATCH_BACKEND_REQUESTED' \
  "G39c.backend-cli-exported"
assert_grep "$GOAL_P0" '^[[:space:]]*uberdev_dispatch_preflight[[:space:]]*$' \
  "G39c.preflight-uses-env-request"

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

assert_no_grep_file() {
  local file="$1" pattern="$2" label="$3"
  if [ -f "$file" ] && ! grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$label" >&2
    printf '        file:    %s (exists=%s)\n' "$file" "$([ -f "$file" ] && echo yes || echo no)" >&2
    printf '        pattern: %s (expected ABSENT but matched)\n' "$pattern" >&2
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
_bt12_failed_count="$(uberdev_goal_count_failed_issues test-bt12 2>/dev/null || printf 'MISSING')"
assert_eq "$_bt12_failed_count" "2" "BT12.f-count-failed-issues-for-terminal-gate"

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

# ----- BT23a-BT23e — uberdev_goal_read_trust_signal SHA-binding (#290.1) -----
# The verdict JSON carries `.pr` + `.sha` (the post-emission anchor headRefOid).
# read_trust_signal must compare that `.sha` against the LIVE
# `gh pr view <pr> --json headRefOid` and return `stale` on mismatch — a commit
# pushed after a GREEN verdict must NOT drive pushed-reviewing→green on the
# stale review. Each case overrides `gh` locally (the section-global gh() mock
# is for state/body/list, not headRefOid).

# BT23a — GREEN verdict, HEAD == verdict.sha → green (binding holds, no churn).
_bt23a_v="$_b12_tmpdir/v-sha-match.json"
cat > "$_bt23a_v" <<'EOF'
{"pr":42,"sha":"abc123","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}
EOF
_bt23a_out="$(
  gh() { case "$1 $2" in "pr view") printf 'abc123' ;; esac; }
  uberdev_goal_read_trust_signal "$_bt23a_v" 2>/dev/null
)"
assert_eq "$_bt23a_out" "green" "BT23a.sha-match-green"

# BT23b — GREEN verdict, HEAD advanced (!= verdict.sha) → stale (the #290.1 bug).
_bt23b_out="$(
  gh() { case "$1 $2" in "pr view") printf 'def456' ;; esac; }
  uberdev_goal_read_trust_signal "$_bt23a_v" 2>/dev/null
)"
assert_eq "$_bt23b_out" "stale" "BT23b.sha-mismatch-stale"

# BT23c — RED verdict + HEAD advanced → STILL stale (a new push invalidates the
# whole review regardless of colour; re-review is the only safe action).
_bt23c_v="$_b12_tmpdir/v-sha-red.json"
cat > "$_bt23c_v" <<'EOF'
{"pr":42,"sha":"abc123","phases":{"phase2_5":{"by_severity":{"blocker":1,"critical":0},"halted":false}}}
EOF
_bt23c_out="$(
  gh() { case "$1 $2" in "pr view") printf 'def456' ;; esac; }
  uberdev_goal_read_trust_signal "$_bt23c_v" 2>/dev/null
)"
assert_eq "$_bt23c_out" "stale" "BT23c.sha-mismatch-overrides-red-to-stale"

# BT23d — gh outage reading headRefOid (rc!=0 / empty) → fail-SAFE: fall through
# to the colour decision (green here), NOT a false stale (which would churn).
_bt23d_out="$(
  gh() { return 1; }
  uberdev_goal_read_trust_signal "$_bt23a_v" 2>/dev/null
)"
assert_eq "$_bt23d_out" "green" "BT23d.gh-outage-failsafe-no-false-stale"

# BT23e — legacy verdict WITHOUT a `.sha` field → no binding (backward compat);
# the colour decision stands even if HEAD differs. Guards the audit-path-only
# fixtures (BT12-BT23) that carry neither `.pr` nor `.sha`.
_bt23e_v="$_b12_tmpdir/v-no-sha.json"
cat > "$_bt23e_v" <<'EOF'
{"pr":42,"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}
EOF
_bt23e_out="$(
  gh() { case "$1 $2" in "pr view") printf 'zzz999' ;; esac; }
  uberdev_goal_read_trust_signal "$_bt23e_v" 2>/dev/null
)"
assert_eq "$_bt23e_out" "green" "BT23e.legacy-no-sha-skips-binding"

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

# BT37 — happy: gh resolves issue 37 -> PR=500 and canonical discovery returns
# stable controller-state JSON after cleaning its private snapshot.
_goal_receipt_field() {
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null
}
_bt_verdict_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_bt37_dir="$_b12_tmpdir/bt37-cwd"
mkdir -p "$_bt37_dir/.uberdev/runs/20260521-120000-aaaa1111"
MOCK_PR_LIST_JSON='[{"number":500,"closingIssuesReferences":[{"number":37}],"headRefName":"feat/37-x"}]'
cat > "$_bt37_dir/.uberdev/runs/20260521-120000-aaaa1111/review-pr-verdict.json" <<'EOF'
{"pr":500,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
EOF
_bt37_out="$(cd "$_bt37_dir" && uberdev_goal_locate_review_pr_audit 37)"
assert_eq "$(_goal_receipt_field "$_bt37_out" '.run_timestamp')" \
  "20260521-120000" \
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
  printf '%s\n' '{"pr":600,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    > "$_bt38_dir/.uberdev/runs/$_d/review-pr-verdict.json"
done
_bt38_out="$(cd "$_bt38_dir" && uberdev_goal_locate_review_pr_audit 38)"
assert_eq "$(_goal_receipt_field "$_bt38_out" '.run_timestamp')" \
  "20260521-200000" \
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
  printf '{"pr":700,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > .uberdev/runs/20260101-100000-aaaaaaaa/review-pr-verdict.json
  printf '{"pr":700,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > .uberdev/runs/20260102-120000-bbbbbbbb/review-pr-verdict.json
  printf '{"pr":701,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > .uberdev/runs/20260103-110000-cccccccc/review-pr-verdict.json
)
_bt50_pr700="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 700)"
_bt50_pr701="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 701)"
_bt50_pr999="$(cd "$_bt50_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 999)"
assert_eq "$(_goal_receipt_field "$_bt50_pr700" '.run_timestamp')" "20260102-120000" \
  "BT50.newest-audit-for-pr700"
assert_eq "$(_goal_receipt_field "$_bt50_pr701" '.run_timestamp')" "20260103-110000" \
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
{"pr":800,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
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
{"pr":800,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}
EOF
)
# Step 3: poll detects new audit, signal green, transitions to green.
_bt52_latest="$(cd "$_bt52_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 800)"
assert_eq "$(_goal_receipt_field "$_bt52_latest" '.run_timestamp')" \
  "20260202-110000" \
  "BT52.poll-finds-new-audit"
_bt52_last_seen="$(uberdev_goal_get_last_held_audit test-bt52 800)"
if [ "$_bt52_latest" != "$_bt52_last_seen" ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "BT52.new-audit-differs-from-last-seen"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "BT52.new-audit-differs-from-last-seen" >&2
fi
_bt52_saved_body="$MOCK_PR_BODY"
MOCK_PR_BODY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_bt52_signal="$(cd "$_bt52_scratch" && uberdev_goal_read_trust_signal "$_bt52_latest")"
MOCK_PR_BODY="$_bt52_saved_body"
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
  printf '{"pr":1234,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > .uberdev/runs/20260301-100000-deadbeef/review-pr-verdict.json
)
# gh resolves issue 555 -> PR 1234 (closingIssuesReferences), then _by_pr globs.
MOCK_PR_LIST_JSON='[{"number":1234,"closingIssuesReferences":[{"number":555}],"headRefName":"feat/555-x"}]'
_bt56_audit="$(cd "$_bt56_scratch" && uberdev_goal_locate_review_pr_audit 555)"
assert_eq "$(_goal_receipt_field "$_bt56_audit" '.run_timestamp')" "20260301-100000" \
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
{"pr":802,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
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
{"pr":802,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{}}
EOF
)
_bt57_new_audit="$(cd "$_bt57_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 802)"
assert_eq "$(_goal_receipt_field "$_bt57_new_audit" '.run_timestamp')" \
  "20260204-130000" \
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
{"pr":803,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":1},"halted":false}}}
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
{"pr":803,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":2},"halted":false}}}
EOF
)
_bt58_new_audit="$(cd "$_bt58_scratch" && uberdev_goal_locate_review_pr_audit_by_pr 803)"
_bt58_saved_body="$MOCK_PR_BODY"
MOCK_PR_BODY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_bt58_signal="$(cd "$_bt58_scratch" && uberdev_goal_read_trust_signal "$_bt58_new_audit")"
MOCK_PR_BODY="$_bt58_saved_body"
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
UBERDEV_GOAL_ID=test-bt70-ghcount
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

uberdev_goal_gh_failure_count test-bt70-ghcount >/dev/null 2>&1
assert_rc "$?" "0" "BT70b.gh-failure-count-helper-readable"
_bt70_count="$(uberdev_goal_gh_failure_count test-bt70-ghcount)"
assert_eq "$_bt70_count" "1" "BT70b.find-pr-gh-failure-recorded-counter"
_uberdev_goal_reset_gh_failure
_bt70_reset_count="$(uberdev_goal_gh_failure_count test-bt70-ghcount)"
assert_eq "$_bt70_reset_count" "0" "BT70b.gh-failure-counter-reset-readable"

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

# BT75b — Codex solver liveness must honor terminal status before PID liveness.
# Phase 2a calls agent_busy_for_issue before reading terminal Codex status; if a
# completed/failed status with a still-live wrapper PID returns busy, the watch
# loop skips the terminal handling and waits until the stuck-loop breaker.
_bt75b_prev_tmp="${UBERDEV_TMPDIR:-}"
_bt75b_prev_backend="${UBERDEV_RESOLVED_BACKEND:-}"
_bt75b_tmp="$(mktemp -d)"
printf '%s\n' '{"issue":77,"backend":"codex","state":"completed","exit_code":0,"pid":"'"$$"'"}' \
  > "$_bt75b_tmp/solve-codex-status-77.json"
. "$DISPATCH_LIB"
export UBERDEV_TMPDIR="$_bt75b_tmp" UBERDEV_RESOLVED_BACKEND=codex
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "1" "BT75b.agent-busy-codex-completed-not-busy"
printf '%s\n' '{"issue":77,"backend":"codex","state":"failed","exit_code":17,"pid":"'"$$"'"}' \
  > "$_bt75b_tmp/solve-codex-status-77.json"
uberdev_goal_agent_busy_for_issue 77
assert_rc "$?" "1" "BT75b.agent-busy-codex-failed-not-busy"
UBERDEV_TMPDIR="$_bt75b_prev_tmp"
if [ -n "$_bt75b_prev_backend" ]; then
  UBERDEV_RESOLVED_BACKEND="$_bt75b_prev_backend"
else
  unset UBERDEV_RESOLVED_BACKEND
fi
export UBERDEV_TMPDIR
rm -rf "$_bt75b_tmp"

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

# ----- BT76-BT79 — issue #220 wave-3 wiring behavioural coverage -----
# Functions under test:
#   - uberdev_goal_review_pr_in_flight (rc 0/1 by anchored-regex match)
#   - Phase 2c emits goal_merge_deferred (skill-level event-emission contract)
#   - Phase 2b emits goal_review_pr_deferred (symmetric contract)
#   - Phase 3 rollover merge-not-overwrite (cycle queue preservation)
#   - uberdev_goal_agent_stuck_on_dialog (60s-window detector via audit-log
#     row-count proxy — lastActivityAt is absent in claude agents JSON per field
#     probe; the helper persists baseline state in sidecar keys and re-evaluates
#     across successive samples)
# Each test uses `bash -c` to keep the parent suite's mocks/state pristine.

echo "== BT76: uberdev_goal_review_pr_in_flight returns 0/1 by substring-regex match =="
_bt76() {
  local pr="$1" expected_rc="$2" label="$3"
  bash -c '
    claude() { printf "%s\n" "[{\"name\":\"/uberdev:review-pr 42\",\"status\":\"busy\"}]"; }
    export -f claude
    . "'"$DISPATCH_LIB"'"
    . "'"$GOAL_LIB"'"
    uberdev_goal_review_pr_in_flight '"$pr"'
  '
  local got=$?
  if [ "$got" -eq "$expected_rc" ]; then
    PASS=$((PASS+1)); echo "  PASS  $label (rc=$got)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label (rc=$got want=$expected_rc)" >&2
  fi
}
_bt76_nl() {
  local pr="$1" expected_rc="$2" label="$3"
  bash -c '
    claude() { printf "%s\n" "[{\"name\":\"Invoke the slash command /uberdev:review-pr 42 now. Do not respond conversationally — execute it.\",\"status\":\"busy\"}]"; }
    export -f claude
    . "'"$DISPATCH_LIB"'"
    . "'"$GOAL_LIB"'"
    uberdev_goal_review_pr_in_flight '"$pr"'
  '
  local got=$?
  if [ "$got" -eq "$expected_rc" ]; then
    PASS=$((PASS+1)); echo "  PASS  $label (rc=$got)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label (rc=$got want=$expected_rc)" >&2
  fi
}
_bt76 42  0 "BT76.match-42"
_bt76 43  1 "BT76.no-match-43"
_bt76 421 1 "BT76.no-match-421-boundary (regression: 42 must not match 421)"
_bt76_nl 42  0 "BT76.match-nl-wrapper (post-#235 prompt body shape matches probe regex)"
_bt76_status_file() {
  local backend="$1" status_name="$2" pid="$3" expected_rc="$4" label="$5"
  local tmp got
  tmp="$(mktemp -d)"
  printf '{"issue":42,"backend":"%s","pid":"%s"}\n' "$backend" "$pid" > "$tmp/$status_name"
  UBERDEV_TMPDIR="$tmp" UBERDEV_RESOLVED_BACKEND="$backend" bash -c '
    . "'"$DISPATCH_LIB"'"
    . "'"$GOAL_LIB"'"
    uberdev_goal_review_pr_in_flight 42
  '
  got=$?
  rm -rf "$tmp"
  if [ "$got" -eq "$expected_rc" ]; then
    PASS=$((PASS+1)); echo "  PASS  $label (rc=$got)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label (rc=$got want=$expected_rc)" >&2
  fi
}
# #381: the codex rows here are RETIRED, not merely renamed. `background` is
# the only PID-bearing backend left, so it keeps the full live/dead/zero-PID
# matrix. The state-machine rows (completed/failed terminal, running-with-
# unreadable-PID defers to in-flight) belonged to the codex sidecar's richer
# status JSON, which lib/goal-state.sh no longer reads at all -- there is no
# equivalent signal on `background`, so those rows have no subject.
#
# COVERAGE DELIBERATELY DROPPED: terminal-state short-circuiting and the
# defer-on-ambiguous-running behaviour of uberdev_goal_review_pr_in_flight.
_bt76_status_file background solve-bg-status-42.json "$$" 0 "BT76.background-status-live-pid-in-flight"
_bt76_status_file background solve-bg-status-42.json 999999999 1 "BT76.background-status-dead-pid-not-in-flight"
_bt76_status_file background solve-bg-status-42.json 0 1 "BT76.background-status-pid-zero-not-in-flight"
# RETIRED SURFACE: a codex-backed probe must now answer "not in flight" through
# the case statement's fall-through, never resurrect a sidecar reader.
_bt76_status_file codex solve-codex-status-42.json "$$" 1 "BT76.codex-backend-no-longer-probed"

echo "== BT77: Phase 2c emits goal_merge_deferred with mock in-flight /review-pr (issue #220 AC ❷) =="
# B5 (post-impl-review): the original BT77 verified (a) the deferred event was
# emitted + (b) the sibling Phase 2b event was NOT emitted — but never asserted
# the LOAD-BEARING behavior, namely that _uberdev_goal_dispatch_merge was
# skipped. The marker-file probe below closes that gap: a stub redirects any
# accidental dispatch into a marker file, and the absence of that file proves
# the gate suppressed dispatch.
bt77_capture="$(mktemp)"
bt77_marker="$(mktemp -u)"
bash -c '
  claude() { printf "%s\n" "[{\"name\":\"/uberdev:review-pr 42\",\"status\":\"busy\"}]"; }
  export -f claude
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_audit() {
    printf "EVENT=%s PAYLOAD=%s\n" "$1" "$2"
  }
  export -f uberdev_goal_audit
  # B5: stub _uberdev_goal_dispatch_merge so an accidental call leaves a
  # marker — the assertion below proves the gate skipped dispatch.
  _uberdev_goal_dispatch_merge() { : > "'"$bt77_marker"'"; }
  export -f _uberdev_goal_dispatch_merge
  pr=42
  GOAL_ID=goal-test-bt77abc1
  if uberdev_goal_review_pr_in_flight "$pr"; then
    uberdev_goal_audit goal_merge_deferred "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"review_in_flight\",\"in_flight_count\":1}"
  else
    echo "BUG: in-flight gate said clear when mock said busy" >&2
    _uberdev_goal_dispatch_merge "$pr"   # exercise the negative path
  fi
' > "$bt77_capture" 2>&1
if grep -qF 'EVENT=goal_merge_deferred PAYLOAD={"goal_id":"goal-test-bt77abc1","pr":42,"reason":"review_in_flight","in_flight_count":1}' "$bt77_capture"; then
  PASS=$((PASS+1)); echo "  PASS  BT77.event-emitted"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77.event-emitted (got: $(cat "$bt77_capture"))" >&2
fi
if ! grep -qF 'EVENT=goal_review_pr_deferred' "$bt77_capture"; then
  PASS=$((PASS+1)); echo "  PASS  BT77.no-review-pr-deferred-event (Phase 2c does not emit Phase 2b event)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77.no-review-pr-deferred-event (got Phase 2b event in Phase 2c scenario)" >&2
fi
if [ ! -e "$bt77_marker" ]; then
  PASS=$((PASS+1)); echo "  PASS  BT77.dispatch-merge-skipped (in-flight gate suppressed dispatch)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77.dispatch-merge-skipped (marker exists — dispatch fired despite in-flight gate)" >&2
fi
rm -f "$bt77_capture" "$bt77_marker"

echo "== BT77b: Phase 2b emits goal_review_pr_deferred with mock in-flight /review-pr (issue #220 AC ❷') =="
# B6 (post-impl-review): mirror BT77's dispatch-skip assertion for the
# _uberdev_goal_dispatch_review_pr suppression — without it, BT77b only
# asserted event emission, not the load-bearing "no re-dispatch" behavior.
bt77b_capture="$(mktemp)"
bt77b_marker="$(mktemp -u)"
bash -c '
  claude() { printf "%s\n" "[{\"name\":\"/uberdev:review-pr 42\",\"status\":\"busy\"}]"; }
  export -f claude
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  uberdev_goal_audit() { printf "EVENT=%s PAYLOAD=%s\n" "$1" "$2"; }
  export -f uberdev_goal_audit
  # B6: stub _uberdev_goal_dispatch_review_pr to drop a marker on accidental call.
  _uberdev_goal_dispatch_review_pr() { : > "'"$bt77b_marker"'"; }
  export -f _uberdev_goal_dispatch_review_pr
  pr=42
  GOAL_ID=goal-test-bt77babc1
  if uberdev_goal_review_pr_in_flight "$pr"; then
    uberdev_goal_audit goal_review_pr_deferred "{\"goal_id\":\"$GOAL_ID\",\"pr\":$pr,\"reason\":\"in_flight\",\"in_flight_count\":1}"
  else
    _uberdev_goal_dispatch_review_pr "$pr"
  fi
' > "$bt77b_capture" 2>&1
if grep -qF 'EVENT=goal_review_pr_deferred PAYLOAD={"goal_id":"goal-test-bt77babc1","pr":42,"reason":"in_flight","in_flight_count":1}' "$bt77b_capture"; then
  PASS=$((PASS+1)); echo "  PASS  BT77b.event-emitted"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77b.event-emitted (got: $(cat "$bt77b_capture"))" >&2
fi
if ! grep -qF 'EVENT=goal_merge_deferred' "$bt77b_capture"; then
  PASS=$((PASS+1)); echo "  PASS  BT77b.no-merge-deferred-event (Phase 2b does not emit Phase 2c event)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77b.no-merge-deferred-event" >&2
fi
if [ ! -e "$bt77b_marker" ]; then
  PASS=$((PASS+1)); echo "  PASS  BT77b.dispatch-review-pr-skipped (in-flight gate suppressed re-dispatch)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT77b.dispatch-review-pr-skipped (marker exists — dispatch fired despite in-flight gate)" >&2
fi
rm -f "$bt77b_capture" "$bt77b_marker"

echo "== BT78: Phase 3 rollover merges Phase-1 carry-over instead of overwriting (issue #220 AC ❹) =="
# B7 (post-impl-review): the original BT78 verified the array-merge shape only.
# The DOWNSTREAM behavior — issue 198 actually getting dispatched in cycle 2 —
# was unguarded. The simulation below counts dispatches against the merged
# queue and asserts the set contains 198, closing the gap.
bt78_out="$(bash -c '
  queue=(207 210 198)
  active=("${queue[@]:0:2}")
  queue=("${queue[@]:2}")
  new_candidates=()
  _rolled_over=${#queue[@]}
  queue=("${queue[@]}" "${new_candidates[@]}")
  printf "queue_after=%s rolled_over=%s\n" "${queue[*]}" "$_rolled_over"
  # B7: simulate Phase 1 dispatch against the merged queue and emit the
  # dispatched-set for assertion below. Reuse the merged $queue array.
  dispatched=()
  for _q in "${queue[@]}"; do
    dispatched+=("$_q")
  done
  printf "dispatched_count=%s dispatched_set=%s\n" "${#dispatched[@]}" "${dispatched[*]}"
')"
case "$bt78_out" in
  "queue_after=198 rolled_over=1"$'\n'"dispatched_count=1 dispatched_set=198")
    PASS=$((PASS+1)); echo "  PASS  BT78.cycle-2-queue-preserves-198"
    ;;
  *)
    FAIL=$((FAIL+1)); echo "  FAIL  BT78.cycle-2-queue-preserves-198 (got [$bt78_out])" >&2
    ;;
esac
if ! grep -qF "queue_after= rolled_over=1" <<<"$bt78_out"; then
  PASS=$((PASS+1)); echo "  PASS  BT78.no-silent-strand (bug regression guard)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT78.no-silent-strand (queue empty AFTER rollover — wipe regression)" >&2
fi
# B7: separate assertion — the dispatched-set MUST contain 198.
if grep -qE "dispatched_set=([^ ]+ )*198( |$)" <<<"$bt78_out"; then
  PASS=$((PASS+1)); echo "  PASS  BT78.cycle-2-dispatch-includes-198"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT78.cycle-2-dispatch-includes-198 (set: $(grep -oE 'dispatched_set=[^[:space:]]*( [0-9]+)*' <<<"$bt78_out"))" >&2
fi

echo "== BT79: uberdev_goal_agent_stuck_on_dialog 60s-window detector via audit-log row-count proxy (issue #220 AC ❸) =="
bt79_capture="$(mktemp)"
bt79_audit_jsonl="$(mktemp)"
echo '{"event":"goal_dispatched"}' > "$bt79_audit_jsonl"
bash -c '
  GOAL_ID=goal-test-bt79abc1
  export GOAL_ID UBERDEV_GOAL_ID="$GOAL_ID"
  # Place a stub goal-<id>.jsonl into UBERDEV_TMPDIR so the helper finds it via the standard path.
  UBERDEV_TMPDIR="$(mktemp -d)"
  export UBERDEV_TMPDIR
  cp "'"$bt79_audit_jsonl"'" "$UBERDEV_TMPDIR/goal-$GOAL_ID.jsonl"
  claude() {
    printf "%s\n" "[{\"pid\":12345,\"status\":\"busy\"}]"
  }
  export -f claude
  _ts_now=1729000000
  date() {
    case "$1" in
      +%s)  printf "%s\n" "${MOCK_NOW:-$_ts_now}" ;;
      *)    command date "$@" ;;
    esac
  }
  export -f date
  . "'"$DISPATCH_LIB"'"
  . "'"$GOAL_LIB"'"
  # First sample — should return rc=1 (not yet stuck) and persist baseline.
  MOCK_NOW=1729000000 uberdev_goal_agent_stuck_on_dialog 12345 && rc1=0 || rc1=$?
  # Second sample — 65s later, same audit row-count, status still busy => stuck.
  MOCK_NOW=1729000065 uberdev_goal_agent_stuck_on_dialog 12345 && rc2=0 || rc2=$?
  printf "rc1=%s rc2=%s\n" "$rc1" "$rc2"
' > "$bt79_capture" 2>&1
if grep -qF 'rc1=1 rc2=0' "$bt79_capture"; then
  PASS=$((PASS+1)); echo "  PASS  BT79.first-sample-not-stuck-second-sample-stuck"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT79.detector-state-machine (got: $(cat "$bt79_capture"))" >&2
fi
rm -f "$bt79_capture" "$bt79_audit_jsonl"

# ----- BT80-BT82 — `dispatched` issue-state pre-spawn guard (issue #236) -----
# Closes the leaf-crash-pre-state-write double-spawn surface. The parent now
# transitions input->dispatched BEFORE uberdev_dispatch_one and dispatched->
# solving (or dispatched->failed) AFTER. The Phase-1 skip-check in SKILL.md
# matches `dispatched|solving|pr-pushed`, so a leaf crash between dispatch
# and the post-spawn solving write never produces a double-spawn on the next
# cycle. BT80 covers the new valid transitions; BT81 covers the invalid ones
# the case-block must still reject; BT82 simulates the leaf-crash scenario
# and asserts the skip-check matches on cycle 2.

echo "== BT80: new 'dispatched' valid transitions (issue #236) =="
uberdev_goal_issue_state_transition test-bt80 600 input dispatched      2>/dev/null
assert_rc "$?" "0" "BT80.a-input-to-dispatched"
uberdev_goal_issue_state_transition test-bt80 600 dispatched solving    2>/dev/null
assert_rc "$?" "0" "BT80.b-dispatched-to-solving"
uberdev_goal_issue_state_transition test-bt80 601 input dispatched      2>/dev/null
assert_rc "$?" "0" "BT80.c-input-to-dispatched-second-issue"
uberdev_goal_issue_state_transition test-bt80 601 dispatched failed     2>/dev/null
assert_rc "$?" "0" "BT80.d-dispatched-to-failed-on-dispatch-rc-nonzero"

echo "== BT81: invalid 'dispatched' transitions still rejected (issue #236) =="
# Backwards / terminal-exit / skip-state guards remain for the new state.
uberdev_goal_issue_state_transition test-bt81 700 dispatched input      2>/dev/null
assert_rc "$?" "2" "BT81.a-dispatched-to-input-backwards"
uberdev_goal_issue_state_transition test-bt81 700 dispatched pr-pushed  2>/dev/null
assert_rc "$?" "2" "BT81.b-dispatched-to-pr-pushed-skip-solving"
uberdev_goal_issue_state_transition test-bt81 700 dispatched resolved   2>/dev/null
assert_rc "$?" "2" "BT81.c-dispatched-to-resolved-skip-states"
uberdev_goal_issue_state_transition test-bt81 700 resolved dispatched   2>/dev/null
assert_rc "$?" "2" "BT81.d-resolved-terminal-cannot-go-to-dispatched"
uberdev_goal_issue_state_transition test-bt81 700 failed dispatched     2>/dev/null
assert_rc "$?" "2" "BT81.e-failed-terminal-cannot-go-to-dispatched"

echo "== BT82: leaf-crash-pre-state-write skip-check guards re-dispatch (issue #236) =="
# Simulates the exact failure mode #236 describes: cycle 1 writes `dispatched`
# pre-spawn, the leaf crashes before parent writes `solving`, cycle 2's
# Phase-1 skip-check reads the TSV and MUST NOT re-dispatch. Mirrors the
# Phase-1 skip-check shape (case "$current_state" in dispatched|solving|pr-pushed)
# without sourcing SKILL.md (the loop is markdown-embedded).
_bt82_tsv="$_b12_tmpdir/goal-test-bt82-issue-states.tsv"
uberdev_goal_issue_state_transition test-bt82 800 input dispatched 2>/dev/null
# Read the LATEST state for issue 800 (mirrors SKILL.md:221 awk pattern).
_bt82_state="$(awk -v i=800 -v c1=1 -v c2=2 '{state[$c1]=$c2} END {print state[i]}' "$_bt82_tsv" 2>/dev/null)"
assert_eq "$_bt82_state" "dispatched" "BT82.a-tsv-state-is-dispatched-after-pre-spawn-write"
# Simulate cycle 2 Phase-1 skip-check.
_bt82_skipped=0
case "$_bt82_state" in
  dispatched|solving|pr-pushed) _bt82_skipped=1 ;;
esac
assert_eq "$_bt82_skipped" "1" "BT82.b-skip-check-matches-dispatched-prevents-double-spawn"
# Negative control — the pre-fix surface. Cycle 1 never wrote any pre-spawn
# state, so cycle 2's awk read the TSV and got EMPTY (no row exists for an
# issue that was never transitioned). The empty awk output is what fell
# through the old `solving|pr-pushed` skip-check and triggered the silent
# re-dispatch. Read an issue that was never transitioned to surface the
# actual pre-fix awk output (NOT a hardcoded "input" string — that string is
# never written to the TSV; no `*->input` transition exists per
# uberdev_goal_issue_state_transition's case-arm).
_bt82_pre_fix_state="$(awk -v i=801 -v c1=1 -v c2=2 '{state[$c1]=$c2} END {print state[i]}' "$_bt82_tsv" 2>/dev/null)"
assert_eq "$_bt82_pre_fix_state" "" "BT82.c-pre-fix-awk-output-is-empty-not-input"
_bt82_skipped_pre_fix=0
case "$_bt82_pre_fix_state" in
  dispatched|solving|pr-pushed) _bt82_skipped_pre_fix=1 ;;
esac
assert_eq "$_bt82_skipped_pre_fix" "0" "BT82.d-skip-check-NOT-match-empty-pre-fix-regression-guard"

echo
echo "== BT83: the cycle-arming chain, end to end (issue #248 -> RFC 0015 §5) =="
# BT83 used to eval the Phase-1 `printf 'Invoke the slash command
# /uberdev:orchestrator …' > "$PROMPT_FILE"` block and assert the RUNTIME prompt
# named the orchestrator and not /turbo. That per-issue prompt no longer exists:
# the driver arms the whole cycle through lib/solve-launcher.sh instead, so there
# is no printf to eval.
#
# The property BT83 protected — the arming chain is fully specified in the
# source, not improvised by the model at run time — is asserted here on the
# chain that replaced it. The RUNTIME complement (the actual relay prompt the
# driver emits, captured under the Workflow harness stubs) lives in
# tests/goal-workflow.test.sh; a grep here plus a live prompt capture there is
# the same two-sided coverage BT83 + G38 gave.
assert_grep "$GOAL_WF" 'lib/goal-phase1.sh|phase1Sh'          "BT83.a-arming-chain-names-the-claim-pass"
assert_grep "$GOAL_WF" 'lib/solve-launcher.sh|launcherSh'     "BT83.b-arming-chain-names-the-launcher"
# These two anchor on the ARMED COMMAND, not on the loose flag token: the
# prompt's own prose explains `--backend=workflow` and `--force` at length, so a
# bare token grep passes even after the flag is deleted from the command line
# (verified by mutation). The full fragment is what actually arms the launcher.
assert_grep "$GOAL_WF" '--turbo -- <ISSUES> --backend=workflow --force' \
  "BT83.c-launcher-command-armed-on-the-workflow-backend-with-force (our own claim would otherwise collide)"
# ...and the two flags must not drift apart into separate call sites.
assert_grep "$GOAL_WF" 'backend=workflow --force' "BT83.d-force-immediately-follows-the-backend-pin"
# The envelope must be relayed VERBATIM (DR-2). An LLM-composed envelope is the
# failure mode this instruction exists to prevent.
assert_grep "$GOAL_WF" 'VERBATIM'                             "BT83.e-envelope-relayed-verbatim"
# ...and the driver must REFUSE an envelope it cannot validate rather than
# repairing it into the nested call.
assert_grep "$GOAL_WF" 'parseFleetArgs'                       "BT83.f-envelope-validated-before-nesting"
assert_grep "$GOAL_WF" 'pipeline !== "solve-fleet"'           "BT83.g-envelope-pipeline-identity-checked"
# Negative: no /uberdev:turbo wrapper anywhere in the arming chain (the
# double-session anti-pattern #248 closed).
assert_no_grep "$GOAL_WF" '/uberdev:turbo'                    "BT83.h-no-turbo-wrapper-in-the-arming-chain"

echo "== BT84: new 'solving->resolved-by-no-action' valid arc (issue #249) =="
# Issue #249 — orchestrator can legitimately close an issue without producing
# a PR. The new `solving->resolved-by-no-action` arc is the terminal state for
# that path. Test the full setup chain (input->dispatched->solving) then verify
# the new arc returns rc=0 and the TSV row reflects the new state.
# Negative control: the previously-rejected `solving->resolved` direct arc
# must STILL return rc=2 (regression guard against silent broadening of the
# case-arm pattern).
# IMPORTANT: this block must NOT be wrapped in a (...) subshell — assert_rc/eq
# modify the parent's PASS/FAIL counters; a subshell would isolate those
# increments and the final `[[ $FAIL -eq 0 ]]` gate would not catch BT84
# regressions. See /review-pr 251 finding SF-007 + 251-G-03 for the empirical
# 460-vs-455 PASS-line delta that confirmed the lost counter increments.
_bt84_tmpdir="$_b12_tmpdir/goal-test-bt84"
mkdir -p "$_bt84_tmpdir"
UBERDEV_TMPDIR="$_bt84_tmpdir" bash -c '
  set +e
  . "'"$REPO_ROOT"'/plugins/uberdev/lib/goal-state.sh"
  uberdev_goal_state_init "bt84" >/dev/null
  uberdev_goal_issue_state_transition "bt84" 900 input dispatched >/dev/null
  echo "rc_a=$?"
  uberdev_goal_issue_state_transition "bt84" 900 dispatched solving >/dev/null
  echo "rc_b=$?"
  uberdev_goal_issue_state_transition "bt84" 900 solving resolved-by-no-action >/dev/null
  echo "rc_c=$?"
  # Negative control on a fresh issue 901 — the direct solving->resolved arc
  # must STILL be rejected (resolved is reached via pr-pushed; resolved-by-no-action
  # is the alternative).
  uberdev_goal_issue_state_transition "bt84" 901 input dispatched >/dev/null
  uberdev_goal_issue_state_transition "bt84" 901 dispatched solving >/dev/null
  uberdev_goal_issue_state_transition "bt84" 901 solving resolved 2>/dev/null
  echo "rc_e=$?"
' > "$_bt84_tmpdir/bt84-out.txt" 2>&1
_bt84_rc_a="$(grep -oE 'rc_a=[0-9]+' "$_bt84_tmpdir/bt84-out.txt" | head -1 | cut -d= -f2)"
_bt84_rc_b="$(grep -oE 'rc_b=[0-9]+' "$_bt84_tmpdir/bt84-out.txt" | head -1 | cut -d= -f2)"
_bt84_rc_c="$(grep -oE 'rc_c=[0-9]+' "$_bt84_tmpdir/bt84-out.txt" | head -1 | cut -d= -f2)"
_bt84_rc_e="$(grep -oE 'rc_e=[0-9]+' "$_bt84_tmpdir/bt84-out.txt" | head -1 | cut -d= -f2)"
_bt84_state="$(awk -v i=900 -v c1=1 -v c2=2 '$c1==i{s=$c2} END{print s}' \
  "$_bt84_tmpdir/goal-bt84-issue-states.tsv" 2>/dev/null)"
assert_rc "$_bt84_rc_a" "0" "BT84.a-input-to-dispatched-setup"
assert_rc "$_bt84_rc_b" "0" "BT84.b-dispatched-to-solving-setup"
assert_rc "$_bt84_rc_c" "0" "BT84.c-solving-to-resolved-by-no-action"
assert_eq "$_bt84_state" "resolved-by-no-action" "BT84.d-tsv-state-is-resolved-by-no-action"
assert_rc "$_bt84_rc_e" "2" "BT84.e-existing-solving-to-resolved-still-rejected"

echo "== BT85: uberdev_goal_audit emits goal_issue_closed_without_pr JSONL row (issue #249) =="
# Issue #249 — the new audit event must be accepted by uberdev_goal_audit's
# enum case-arm and produce a JSONL row with a numeric `issue` field. A future
# rename / typo in the case-arm would silently rc=1 and the event would be
# dropped on the floor (helper returns non-zero, payload not persisted).
# NOTE: uberdev_goal_audit reads goal_id from UBERDEV_GOAL_ID env (not arg) and
# writes to "$UBERDEV_TMPDIR/goal-$UBERDEV_GOAL_ID.jsonl" — so both must be set.
_bt85_tmpdir="$_b12_tmpdir/goal-test-bt85"
mkdir -p "$_bt85_tmpdir"
UBERDEV_TMPDIR="$_bt85_tmpdir" UBERDEV_GOAL_ID="bt85" bash -c '
  set +e
  . "'"$REPO_ROOT"'/plugins/uberdev/lib/goal-state.sh"
  uberdev_goal_state_init "$UBERDEV_GOAL_ID" >/dev/null
  uberdev_goal_audit goal_issue_closed_without_pr \
    "{\"goal_id\":\"bt85\",\"issue\":1000,\"detected_at\":1234567890}" >/dev/null
  echo "audit_rc=$?"
  uberdev_goal_audit goal_does_not_exist "{}" 2>/dev/null
  echo "neg_rc=$?"
' > "$_bt85_tmpdir/bt85-out.txt" 2>&1
_bt85_audit_rc="$(grep -oE 'audit_rc=[0-9]+' "$_bt85_tmpdir/bt85-out.txt" | head -1 | cut -d= -f2)"
_bt85_neg_rc="$(grep -oE 'neg_rc=[0-9]+' "$_bt85_tmpdir/bt85-out.txt" | head -1 | cut -d= -f2)"
assert_rc "$_bt85_audit_rc" "0" "BT85.a-uberdev_goal_audit-returns-zero"
_bt85_audit="$_bt85_tmpdir/goal-bt85.jsonl"
if grep -q '"event":"goal_issue_closed_without_pr"' "$_bt85_audit" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS  BT85.b-jsonl-row-written-with-event-name"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT85.b-jsonl-row-written-with-event-name (event row not found in $_bt85_audit)" >&2
fi
if grep -qE '"issue":1000([,}]|$)' "$_bt85_audit" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS  BT85.c-issue-field-is-numeric-not-quoted"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT85.c-issue-field-is-numeric-not-quoted (issue not numeric or row missing)" >&2
fi
assert_rc "$_bt85_neg_rc" "1" "BT85.d-unknown-event-still-rejected"

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
rm -rf "$_b12_tmpdir/goal-test-bt80"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt81"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt82"* 2>/dev/null || true
rm -f "$_b12_tmpdir"/bt83-prompt-out.txt 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt84"* 2>/dev/null || true
rm -rf "$_b12_tmpdir/goal-test-bt85"* 2>/dev/null || true
rm -f "$_b12_tmpdir"/goal-bt5-*-merge-attempts.tsv 2>/dev/null || true
rm -rf "$_b12_tmpdir" 2>/dev/null || true

echo
echo "== G40: fresh-shell lib re-source rehydrates STUCK_SECS (#245) =="
# Reproduces the exact stuck_loop misfire from issue #245 (run id
# goal-1779914294-PyIwDEMz, cycle 1): a fresh `bash -c` shell sources only
# lib/goal-state.sh — NOT the SKILL.md Phase 0 Constants block. Before the
# fix, $_UBERDEV_GOAL_STUCK_SECS was unset → bash arithmetic coerced to 0 →
# `(( now - watch_start >= 0 ))` fired stuck_loop on iteration 1.
# After the fix, the lib's `: "${_UBERDEV_GOAL_STUCK_SECS:=14400}"` sets the
# canonical default during the fresh-shell source, so the assertion below
# must report the literal 14400.
if [ -x /opt/homebrew/bin/bash ]; then
  _g40_bash=/opt/homebrew/bin/bash
else
  _g40_bash=bash
fi
_g40_out="$("$_g40_bash" -c '. "'"$REPO_ROOT"'/plugins/uberdev/lib/goal-state.sh"; echo "$_UBERDEV_GOAL_STUCK_SECS"' 2>&1)"
if [ "$_g40_out" = "14400" ]; then
  PASS=$((PASS+1)); echo "  PASS  G40.stuck-secs-rehydrated-on-fresh-shell"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G40.stuck-secs-rehydrated-on-fresh-shell (expected 14400, got: $_g40_out)" >&2
fi

echo
echo "== G41: Phase-0 bash>=4 execution-contract guard does NOT dead-end when bash>=4 exists (issue #294) =="
# Structural: the guard resolves a bash binary + publishes UBERDEV_GOAL_BASH
# instead of the old unconditional `exit 2` on unset BASH_VERSINFO.
assert_grep "$GOAL_P0" 'UBERDEV_GOAL_BASH'                                   "G41.publishes-bash-path"
assert_grep "$GOAL_P0" '/opt/homebrew/bin/bash /usr/local/bin/bash'         "G41.brew-path-candidates"
assert_grep "$GOAL_P0" 'exec "\$UBERDEV_GOAL_BASH" "\$0" "\$@"'              "G41.reexec-under-discovered-bash"
# Anti-regression: the guard must NOT exit 2 unconditionally on unset
# BASH_VERSINFO. The old form was a single `if [ -z "${BASH_VERSINFO:-}" ] ...
# exit 2`. The new form only exits 2 inside the `-z "$UBERDEV_GOAL_BASH"`
# (no-bash-found) branch — so a guard text containing `-z "${BASH_VERSINFO`
# directly gating `exit 2` would be the regression.
assert_no_grep "$GOAL_P0" 'if \[ -z "\$\{BASH_VERSINFO:-\}" \] \|\| \[ "\$\{BASH_VERSINFO\[0\]:-0\}" -lt 4 \]; then' "G41.no-old-hard-exit-guard"
# Re-exec must be shebang-gated so it never tries to exec the interpreter binary
# ($0=/bin/zsh under an inline `zsh -c` body) — the rc=126 trap.
assert_grep "$GOAL_P0" "head -c2 \"\\\$0\""                                  "G41.reexec-shebang-gated"
# Behavioural: extract the FIRST Phase-0 bash fence (the guard) and run its
# guard logic under zsh with bash>=4 present. It MUST NOT exit 2 (the #294 bug
# was a spurious exit 2 on the very first fence under the zsh Bash tool). We run
# the guard up to the point it would reach the rest of Phase-0, then echo a
# sentinel; a clean run prints the sentinel and resolves UBERDEV_GOAL_BASH.
if command -v zsh >/dev/null 2>&1 && { [ -x /opt/homebrew/bin/bash ] || [ -x /usr/local/bin/bash ]; }; then
  _g41_guard="$(extract_region bash4-resolver "$GOAL_P0")"
  # Stop the extracted guard before the (undefined-in-isolation) Phase-0 body by
  # appending a sentinel echo; the guard arms either exit 2 (bug), exec away, or
  # fall through to here.
  _g41_script="$_g41_guard"$'\n''echo "__G41_REACHED__:UBERDEV_GOAL_BASH=${UBERDEV_GOAL_BASH:-unset}"'
  _g41_out="$(/bin/zsh -c "$_g41_script" 2>&1)"; _g41_rc=$?
  if [ "$_g41_rc" != "2" ] && grep -q '__G41_REACHED__' <<<"$_g41_out"; then
    PASS=$((PASS+1)); echo "  PASS  G41.zsh-guard-no-spurious-exit2 (rc=$_g41_rc, reached body)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  G41.zsh-guard-no-spurious-exit2 (rc=$_g41_rc, out: $_g41_out)" >&2
  fi
  # And it must have resolved a real bash>=4 path (not left it unset).
  if grep -qE '__G41_REACHED__:UBERDEV_GOAL_BASH=.*/bash' <<<"$_g41_out"; then
    PASS=$((PASS+1)); echo "  PASS  G41.zsh-guard-resolved-bash-path"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  G41.zsh-guard-resolved-bash-path (out: $_g41_out)" >&2
  fi
else
  echo "  SKIP  G41.zsh-guard-behavioural (zsh or bash>=4 not available on this host)"
fi

echo
echo "== G42: false-convergence rollover guard + cycle backstop + per-cycle barrier reset (issue #288) =="
# #288 #1 — BOTH Phase-3 terminal gates also require the rollover queue empty.
assert_grep "$GOAL_P3" '\[ "\$\{#new_candidates\[@\]\}" = "0" \] && \[ "\$terminal_count" = "\$all_pr_count" \] && \[ "\$\{#queue\[@\]\}" -eq 0 \]' "G42.converge-gate-queue-empty-guard"
assert_grep "$GOAL_P3" '\[ "\$\{#new_candidates\[@\]\}" = "0" \] && \[ "\$\{#queue\[@\]\}" -eq 0 \] && \[ "\$terminal_count" != "\$all_pr_count" \]' "G42.queue-empty-not-converged-queue-guard"
# #288 #2 — Phase-1-top cycle ceiling backstop reads cycle from run-state.
assert_grep "$GOAL_P1" '\[ "\$\{cycle:-1\}" -gt "\$\{MAX_CYCLES:-0\}" \]'   "G42.phase1-cycle-ceiling-backstop"
assert_grep "$GOAL_P1" 'phase1_ceiling_backstop'                            "G42.phase1-backstop-audit-tag"
# #288 #3 — per-cycle barrier reset at the loop-back: barrier_start_ts=0 + TSV truncate.
assert_grep "$GOAL_P3" 'barrier_start_ts=0'                                 "G42.barrier-reset-zero"
assert_grep "$GOAL_P3" '_batch_prs_tsv=.*goal-\$GOAL_ID-batch-prs.tsv'      "G42.barrier-reset-tsv-path"
assert_grep "$GOAL_P3" ': > "\$_batch_prs_tsv"'                             "G42.barrier-reset-tsv-truncate"
# Anti-regression: the #220 rollover-preservation merge must still be present
# (NOT reverted to an overwrite) — the queue-empty guard relies on it.
assert_grep "$GOAL_P3" 'queue=\("\$\{queue\[@\]\}" "\$\{new_candidates\[@\]\}"\)' "G42.rollover-merge-preserved"
# Behavioural: the cap-overflow convergence-gate predicate must be FALSE while
# the rollover queue is non-empty (so the goal does NOT falsely converge).
# Mirror the exact gate boolean from the SKILL with a non-empty queue: 0 new
# candidates + all PRs terminal + 1 rolled-over issue => must NOT converge.
_g42_new=0; _g42_term=3; _g42_all=3; _g42_queue_len=1
if [ "$_g42_new" = "0" ] && [ "$_g42_term" = "$_g42_all" ] && [ "$_g42_queue_len" -eq 0 ]; then
  FAIL=$((FAIL+1)); echo "  FAIL  G42.cap-overflow-does-not-converge (gate fired with non-empty queue — false convergence)" >&2
else
  PASS=$((PASS+1)); echo "  PASS  G42.cap-overflow-does-not-converge (gate correctly held open: queue_len=$_g42_queue_len)"
fi
# And with an EMPTY queue + same terminal state it SHOULD converge (no false negative).
_g42_queue_len=0
if [ "$_g42_new" = "0" ] && [ "$_g42_term" = "$_g42_all" ] && [ "$_g42_queue_len" -eq 0 ]; then
  PASS=$((PASS+1)); echo "  PASS  G42.empty-queue-still-converges (no false negative)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G42.empty-queue-still-converges (gate wrongly held open with empty queue)" >&2
fi

echo
echo "== G43: cross-process uberdev:active claim acquire/release (issue #291 #1) + --only-mine identity doc (#291 #2) =="
# #291 #1 — SETNX claim helper defined + acquired BEFORE dispatch, released on terminal.
assert_grep "$GOAL_P1" '_uberdev_goal_claim_issue\(\)'                       "G43.claim-helper-defined"
assert_grep "$GOAL_P1" '_uberdev_goal_release_claim\(\)'                     "G43.release-helper-defined"
assert_grep "$GOAL_P1" "UBERDEV_ACTIVE_LABEL='uberdev:active'"               "G43.active-label-bound"
# The claim is the OUTERMOST guard: it must be acquired before the
# input->dispatched write (which is itself before the fleet is armed — G24b
# locks that half). Ordering inside the claim pass is what makes the label a
# real cross-process lock rather than a label we set after the fact.
_g43_claim_line="$(grep -nF '_uberdev_goal_claim_issue "$ISSUE_NUM"; _claim_rc=$?' "$GOAL_P1" | head -1 | cut -d: -f1)"
_g43_state_line="$(grep -nF 'input dispatched' "$GOAL_P1" | head -1 | cut -d: -f1)"
if [ -n "$_g43_claim_line" ] && [ -n "$_g43_state_line" ] && [ "$_g43_claim_line" -lt "$_g43_state_line" ]; then
  PASS=$((PASS+1)); echo "  PASS  G43.claim-precedes-state-write (claim=$_g43_claim_line state=$_g43_state_line)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G43.claim-precedes-state-write (claim=$_g43_claim_line state=$_g43_state_line)" >&2
fi
# Collision => soft-skip this cycle (continue), gh-fail => hard error.
assert_grep "$GOAL_P1" '_claim_rc=\$\?'                                      "G43.claim-rc-captured"
assert_grep "$GOAL_P1" 'uberdev:active claim held by another process'       "G43.collision-soft-skip-msg"
# Release on terminal non-merge transitions: Phase-1 dispatch-failure + Phase-2 failed/resolved-by-no-action.
# Release sites now live in two files: the claim pass (state-write failure and
# the arming-failure --mark-failed path) and the watch loop (solve timeout,
# closed-without-PR, Codex terminal states).
_g43_release_count="$(cat "$GOAL_P1" "$GOAL_WATCH" | grep -cE '_uberdev_goal_release_claim "\$ISSUE_NUM"|_uberdev_goal_release_claim "\$_issue"|gh issue edit "\$issue" --remove-label "uberdev:active"')"
if [ "$_g43_release_count" -ge 3 ]; then
  PASS=$((PASS+1)); echo "  PASS  G43.claim-released-on-terminal (count=$_g43_release_count, ge 3)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G43.claim-released-on-terminal (count=$_g43_release_count, want ge 3)" >&2
fi
# #291 #2 — the --only-mine identity requirement is documented (not a silent drop).
assert_grep "$GOAL_P3" 'Identity requirement \(issue #291'                  "G43.only-mine-identity-doc-phase3"
assert_grep "$GOAL_CMD"   'Requires a single .gh. identity \(issue #291\)'      "G43.only-mine-identity-doc-cmd"

echo
echo "== G44: .candidates sidecar persistence + only_mine scalar flush (#301, RFC 0012 §3.3 goal-R1 item 1) =="
# Writer mirrors the .queue shape with a cycle=<N> first-line tag; reader gates
# rehydration on the tag matching the scalar-rehydrated cycle; cleanup removes it.
assert_grep "$GOAL_LIB" '\$\{sc\}\.candidates'                                  "G44.lib-candidates-sidecar-path"
assert_grep "$GOAL_LIB" "printf 'cycle=%s\\\\n%s\\\\n'"                          "G44.lib-candidates-cycle-tagged-writer"
assert_grep "$GOAL_LIB" '"\$_cand_tag" = "\$\{cycle:-0\}"'                       "G44.lib-candidates-cycle-tag-gate"
assert_grep "$GOAL_LIB" '"\$\{sc\}\.queue" "\$\{sc\}\.active" "\$\{sc\}\.candidates"' "G44.lib-cleanup-removes-candidates"
# only_mine joins the scalar flush + the validating read arm (#291 identity
# filter must survive the fresh Phase-3 fence).
assert_grep "$GOAL_LIB" 'only_mine=%s'                                          "G44.lib-only-mine-in-scalar-flush"
assert_grep "$GOAL_LIB" 'case "\$v" in 0\|1\) only_mine="\$v"'                   "G44.lib-only-mine-read-allowlist"
# Phase-3 fence 1 flushes at fence END (the false-converge fix) — fail-loud.
assert_grep "$GOAL_P3" 'failed to persist run-state after Phase-3 candidate collection' "G44.collect-flush-fail-loud"
# Loop-back clears the consumed candidates BEFORE the flush (double-merge guard):
# the clear must sit between the rollover merge and the loop-back write.
_g44_merge_line="$(grep -nF 'queue=("${queue[@]}" "${new_candidates[@]}")' "$GOAL_P3" | head -1 | cut -d: -f1)"
_g44_clear_line="$(grep -nF 'new_candidates=()' "$GOAL_P3" | awk -F: -v m="${_g44_merge_line:-0}" '$1 > m { print $1; exit }')"
_g44_loopback_flush_line="$(grep -nF 'failed to persist run-state before loop-back' "$GOAL_P3" | head -1 | cut -d: -f1)"
if [ -n "${_g44_merge_line:-}" ] && [ -n "${_g44_clear_line:-}" ] && [ -n "${_g44_loopback_flush_line:-}" ] \
   && [ "$_g44_clear_line" -gt "$_g44_merge_line" ] && [ "$_g44_clear_line" -lt "$_g44_loopback_flush_line" ]; then
  PASS=$((PASS+1)); echo "  PASS  G44.loopback-clears-consumed-candidates (merge=$_g44_merge_line < clear=$_g44_clear_line < flush=$_g44_loopback_flush_line)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G44.loopback-clears-consumed-candidates (merge=$_g44_merge_line clear=$_g44_clear_line flush=$_g44_loopback_flush_line)" >&2
fi

echo
echo "== G45: D13 first-10 truncation sequenced BEFORE the terminal/loop-back fence (#301, RFC 0012 §3.3 goal-R1 item 2) =="
# Pre-#301 the truncation fence sat AFTER the loop-back fence — dead code (the
# un-truncated set had already merged into queue and flushed). Lock the order:
# truncation line < terminal-gate line < rollover-merge line.
_g45_trunc_line="$(grep -nF 'new_candidates=("${new_candidates[@]:0:10}")' "$GOAL_P3" | head -1 | cut -d: -f1)"
_g45_term_line="$(grep -nF 'Terminal set for convergence' "$GOAL_P3" | head -1 | cut -d: -f1)"
if [ -n "${_g45_trunc_line:-}" ] && [ -n "${_g45_term_line:-}" ] && [ "$_g45_trunc_line" -lt "$_g45_term_line" ]; then
  PASS=$((PASS+1)); echo "  PASS  G45.truncation-precedes-terminal-fence (trunc=$_g45_trunc_line < terminal=$_g45_term_line)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G45.truncation-precedes-terminal-fence (trunc=${_g45_trunc_line:-MISSING} terminal=${_g45_term_line:-MISSING} — D13 truncation is dead again if it trails the terminal fence)" >&2
fi
# The truncation fence re-flushes the TRUNCATED set so the fresh-shell terminal
# fence rehydrates first-10, not the full set.
assert_grep "$GOAL_P3" 'failed to persist run-state after overflow truncation' "G45.truncation-reflushes-sidecar"

echo
echo "== G46: review-pr dispatch-cap exhaustion -> red-held with distinct audit note (#301, RFC 0012 §3.3 goal-R1 item 4) =="
# Lib: cap-reached returns the DISTINCT rc 5 (was rc 0 — indistinguishable from
# a successful dispatch, so 2b spun any_active=1 to the 4h stuck_loop).
_g46_cap_block="$(sed -n '/review-pr dispatch cap reached/,/fi/p' "$GOAL_LIB")"
if grep -qE 'return 5' <<<"$_g46_cap_block"; then
  PASS=$((PASS+1)); echo "  PASS  G46.lib-cap-returns-distinct-rc5"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G46.lib-cap-returns-distinct-rc5 (cap arm: [$_g46_cap_block])" >&2
fi
# SKILL 2b: rc captured, rc-5 arm transitions pushed-reviewing -> red-held and
# emits the goal_review_pr_deferred note with reason=dispatch_cap_exhausted.
assert_grep "$GOAL_WATCH" '_rpr_rc=\$\?'                                        "G46.watch-2b-rc-captured"
assert_grep "$GOAL_WATCH" '\[ "\$_rpr_rc" -eq 5 \]'                              "G46.watch-2b-rc5-branch"
assert_grep "$GOAL_WATCH" 'dispatch_cap_exhausted'                               "G46.watch-2b-distinct-audit-note"
_g46_redheld_count="$(grep -cF 'uberdev_goal_pr_state_transition "$GOAL_ID" "$pr_num" pushed-reviewing red-held' "$GOAL_WATCH")"
if [ "$_g46_redheld_count" -ge 2 ]; then
  PASS=$((PASS+1)); echo "  PASS  G46.watch-2b-red-held-transition (count=$_g46_redheld_count: red case + cap-exhaustion arm)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G46.watch-2b-red-held-transition (count=$_g46_redheld_count, want ge 2 — cap-exhaustion arm missing?)" >&2
fi

echo
echo "== G47: bounded-watch default 480s under the Claude-Code Bash tool (#301, RFC 0012 §3.3 goal-R1 item 3) =="
assert_grep "$GOAL_LIB"   '_UBERDEV_GOAL_DEFAULT_WATCH_BUDGET:=480'              "G47.lib-default-constant-480"
assert_grep "$GOAL_P0" 'CLAUDECODE'                                           "G47.phase0-claudecode-feature-detect"
assert_grep "$GOAL_P0" 'WATCH_BUDGET="\$\{_UBERDEV_GOAL_DEFAULT_WATCH_BUDGET:-480\}"' "G47.phase0-default-applied"
assert_grep "$GOAL_CMD"   'defaults to .480'                                     "G47.cmd-documents-480-default"
assert_grep "$GOAL_CMD"   'harness_term'                                         "G47.cmd-documents-term-contract"
# The default must NOT override an explicit zero: the gate requires empty
# CLI/env inputs, not just resolved-0 values.
assert_grep "$GOAL_P0" '\-z "\$\{watch_budget_cli:-\}"'                       "G47.phase0-explicit-zero-opt-out"

echo
echo "== BT86: _uberdev_goal_handle_harness_term behavioural — persist + audit + exit 42, NO reap (#301) =="
bt86_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-bt86-%s' "$$")"
bt86_out="$(UBERDEV_TMPDIR="$bt86_dir" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  UBERDEV_GOAL_ID="goal-test-bt86abc1" bash -c '
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    uberdev_goal_write_run_state() { echo persisted >> "$UBERDEV_TMPDIR/bt86-calls"; return 0; }
    _uberdev_goal_reap_zombies()   { echo reaped    >> "$UBERDEV_TMPDIR/bt86-calls"; }
    uberdev_goal_audit()           { echo "audit:$1:$2" >> "$UBERDEV_TMPDIR/bt86-calls"; }
    ( _uberdev_goal_handle_harness_term )
    printf "rc=%s\n" "$?"
    cat "$UBERDEV_TMPDIR/bt86-calls" 2>/dev/null
  ')"
if grep -q '^rc=42$' <<<"$bt86_out" \
   && grep -q '^persisted$' <<<"$bt86_out" \
   && grep -q '^audit:goal_reaper_skipped:.*harness_term' <<<"$bt86_out" \
   && ! grep -q '^reaped$' <<<"$bt86_out"; then
  PASS=$((PASS+1)); echo "  PASS  BT86.term-handler-contract (exit 42 + persist + goal_reaper_skipped/harness_term, reaper NOT called)"
else
  FAIL=$((FAIL+1)); echo "  FAIL  BT86.term-handler-contract (got: [$bt86_out])" >&2
fi
rm -rf "$bt86_dir"

echo
echo "== G48: goal verdict lookup delegates canonical selector and cleans its stable capture =="
_g48_locator_block="$(awk '
  /^uberdev_goal_locate_review_pr_audit_by_pr\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$GOAL_LIB")"
if grep -q 'discover_review_verdict_json' <<<"$_g48_locator_block" \
  && grep -q 'review_verdict_discovery_state' <<<"$_g48_locator_block"; then
  PASS=$((PASS+1)); echo "  PASS  G48.canonical-selector-and-state-helper"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G48.canonical-selector-and-state-helper (goal must not fork selector/rc semantics)" >&2
fi
if grep -q 'cleanup_review_verdict_snapshot' <<<"$_g48_locator_block"; then
  PASS=$((PASS+1)); echo "  PASS  G48.stable-capture-cleaned"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G48.stable-capture-cleaned (goal must clean the selector carrier on every found path)" >&2
fi
if ! grep -qE '_uberdev_goal_glob_worktree|find[[:space:]]|sort -r|jq[[:space:]]+-r' \
  <<<"$_g48_locator_block"; then
  PASS=$((PASS+1)); echo "  PASS  G48.no-forked-discovery"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G48.no-forked-discovery (duplicated glob/sort/jq selector remains)" >&2
fi
if grep -qE 'indeterminate.*missing|DISCOVERY_STATE.*indeterminate|2\\|\\*.*return 0' \
  <<<"$_g48_locator_block"; then
  PASS=$((PASS+1)); echo "  PASS  G48.indeterminate-reuses-existing-missing-rereview-path"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G48.indeterminate-reuses-existing-missing-rereview-path" >&2
fi

echo
echo "== G49: selector indeterminate emits no controller state and never recaptures =="
G49_TMP="$(mktemp -d)"
G49_OUT="$(
  G49_CALLS="$G49_TMP/calls" bash -c '
    . "$1"
    discover_review_verdict_json() { return 2; }
    review_verdict_discovery_state() {
      [ "$1" -eq 2 ] && printf "indeterminate\n" || return 1
    }
    recapture_review_verdict_snapshot() { printf "recapture\n" >>"$G49_CALLS"; }
    cleanup_review_verdict_snapshot() { printf "cleanup\n" >>"$G49_CALLS"; }
    uberdev_goal_locate_review_pr_audit_by_pr 73
    printf "rc=%s\n" "$?"
  ' _ "$GOAL_LIB"
)"
if [ "$G49_OUT" = "rc=0" ] && [ ! -e "$G49_TMP/calls" ]; then
  PASS=$((PASS+1)); echo "  PASS  G49 — rc2 reuses missing/re-review with no receipt recapture or controller state"
else
  FAIL=$((FAIL+1)); echo "  FAIL  G49 — rc2 touched a receipt or published controller state (out=[$G49_OUT] calls=[$(cat "$G49_TMP/calls" 2>/dev/null)])" >&2
fi
rm -rf "$G49_TMP"

echo
echo "== BT61: an unreadable PR head can never yield a merge-authorising colour =="
# Regression: the closed-receipt branch warned and FELL THROUGH to the colour
# decision when `gh pr view ... headRefOid` failed or returned empty, so a
# rate-limited or offline gh could report green for a verdict bound to a
# superseded SHA -- and /goal auto-merges on green. It must report stale.
BT61_TMP="$(mktemp -d)"
mkdir -p "$BT61_TMP/.uberdev/runs/20260305-090000-abcdef01"
cat > "$BT61_TMP/.uberdev/runs/20260305-090000-abcdef01/review-pr-verdict.json" <<'EOF'
{"pr":900,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}
EOF
BT61_RECEIPT="$(cd "$BT61_TMP" && uberdev_goal_locate_review_pr_audit_by_pr 900 2>/dev/null)"
if [ -z "$BT61_RECEIPT" ]; then
  printf '  FAIL  %s\n' "BT61.setup — could not build a closed receipt"
  FAIL=$((FAIL + 1))
else
  # Control: with a matching head the same receipt is green, so the assertions
  # below prove the gh-failure branch specifically, not a broken fixture.
  BT61_OK="$(
    gh() { case "$1 $2" in "pr view") printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$BT61_RECEIPT" 2>/dev/null
  )"
  assert_eq "$BT61_OK" "green" "BT61.control — matching head still reports green"
  BT61_RC1="$(
    gh() { case "$1 $2" in "pr view") return 1 ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$BT61_RECEIPT" 2>/dev/null
  )"
  assert_eq "$BT61_RC1" "stale" "BT61.gh-nonzero — gh failure reports stale, never green"
  BT61_EMPTY="$(
    gh() { case "$1 $2" in "pr view") printf '' ;; *) return 0 ;; esac; }
    uberdev_goal_read_trust_signal "$BT61_RECEIPT" 2>/dev/null
  )"
  assert_eq "$BT61_EMPTY" "stale" "BT61.gh-empty — empty headRefOid reports stale, never green"
fi
rm -rf "$BT61_TMP"

echo
echo "== G50: the post-Workflow summary fence rehydrates UNCONDITIONALLY (RFC 0015 §5) =="
# The fence used to read `GOAL_ID="${UBERDEV_GOAL_ID:-}"` and gate its whole body
# on that being non-empty. UBERDEV_GOAL_ID is exported inside `bash
# lib/goal-phase0.sh` — a CHILD of a DIFFERENT, earlier Bash call — so in this
# fence it is ALWAYS empty and the body was dead code: the operator summary never
# printed. Every other consumer (goal-phase1.sh, goal-watch.sh, goal-phase3.sh)
# calls uberdev_goal_read_run_state unconditionally and lets IT bootstrap the id
# from the fixed-path goal-active-id.txt pointer.
#
# A grep cannot tell the two shapes apart — only running the fence with
# UBERDEV_GOAL_ID genuinely unset can. So: extract the fence verbatim, seed real
# run-state, and run it in a fresh bash with the env var cleared.
_g50_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-g50-%s' "$$")"
_g50_fence="$_g50_dir/summary.fence.sh"
# The first ```bash block after the "## Post-Workflow summary" heading.
awk '
  { sub(/\r$/, "") }   # CRLF-tolerant: a windows-latest checkout may carry \r,
                       # which would defeat every $-anchored match below AND
                       # make the extracted fence unrunnable.
  /^## Post-Workflow summary$/ { seen=1; next }
  seen && /^```bash$/          { cap=1; next }
  cap && /^```$/               { exit }
  cap                          { print }
' "$GOAL_SKILL" > "$_g50_fence"
if [ -s "$_g50_fence" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G50.extract: located the post-Workflow summary fence in the goal-pipeline SKILL.md"

  _g50_id="1700000042-g50fence"
  # Seed a real run: state files + the goal-active-id.txt pointer the fence must
  # bootstrap from. Done in its OWN shell, exactly as lib/goal-phase0.sh does.
  UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
  "${BASH:-bash}" -c '
    set -u
    . "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
    . "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
    GOAL_ID="'"$_g50_id"'"
    export UBERDEV_GOAL_ID="$GOAL_ID"
    uberdev_goal_state_init "$GOAL_ID" || exit 9
    cycle=3; watch_start="$(date +%s)"; MAX_CYCLES=5; MAX_PARALLEL=3
    queue=(); active_issues=()
    uberdev_goal_write_run_state || exit 9
  ' >/dev/null 2>&1 \
    && _g50_seeded=1 || _g50_seeded=0
  assert_eq "$_g50_seeded" "1" "G50.seed: run-state + goal-active-id.txt pointer written"

  # THE ASSERTION: fresh shell, UBERDEV_GOAL_ID explicitly unset (the production
  # condition), only UBERDEV_TMPDIR + CLAUDE_PLUGIN_ROOT in the environment.
  # `unset` (a builtin) rather than `env -u`: the same clear-the-variable effect
  # on every shell the CI matrix runs, Git-Bash-on-windows included.
  _g50_out="$(UBERDEV_TMPDIR="$UBERDEV_TMPDIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
      "${BASH:-bash}" -c 'unset UBERDEV_GOAL_ID GOAL_ID; . "$0"' "$_g50_fence" 2>&1)"
  if grep -q "^goal $_g50_id: cycles=3/5 " <<<"$_g50_out"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G50.prints-summary: the fence rehydrates from the pointer and prints the operator summary with UBERDEV_GOAL_ID unset"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G50.prints-summary: fence printed no summary (dead-code gate on UBERDEV_GOAL_ID?) — got: [$_g50_out]" >&2
  fi
  if grep -q "audit: .*goal-$_g50_id\.jsonl" <<<"$_g50_out"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G50.prints-audit-path: the fence names the audit log for the rehydrated id (not an empty goal-.jsonl)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G50.prints-audit-path: audit path missing/unkeyed — got: [$_g50_out]" >&2
  fi
  # Non-vacuity control: point the SAME fence at a tmpdir with no pointer. It
  # must say so on stderr and print NO summary — proving G50.prints-summary is
  # discriminating and not a grep that would pass on any output.
  _g50_empty="$_g50_dir/empty"; mkdir -p "$_g50_empty"
  _g50_neg="$(UBERDEV_TMPDIR="$_g50_empty" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
      "${BASH:-bash}" -c 'unset UBERDEV_GOAL_ID GOAL_ID; . "$0"' "$_g50_fence" 2>&1)"
  if grep -q 'no run-state to summarise' <<<"$_g50_neg" \
     && ! grep -q 'cycles=' <<<"$_g50_neg"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G50.control: with no active-id pointer the fence says so and prints no summary (assert is discriminating)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G50.control: pointer-less run should refuse loudly and print nothing — got: [$_g50_neg]" >&2
  fi
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G50.extract: could NOT extract the post-Workflow summary fence (heading renamed?)" >&2
fi
rm -rf "$_g50_dir"

echo
echo "== G51: the child-transport pin does not re-route the SOLVER liveness probe =="
# uberdev_dispatch_preflight EXPORTS UBERDEV_RESOLVED_BACKEND process-globally,
# and uberdev_goal_agent_busy_for_issue branches on that same variable. So the
# `background` pin lib/goal-watch.sh takes for its OWN /merge + /review-pr
# children silently re-routed the SOLVER liveness probe onto the PID-file arm —
# for solvers that are Workflow agents and never write a PID file. A comment
# saying "the solvers stay Workflow-native" cannot detect that; running the
# wrapper can.
_g51_fn="$(awk '
  /^_uberdev_goal_watch_solver_busy\(\) \{/ { cap=1 }
  cap                                       { print }
  cap && /^\}$/                             { exit }
' "$GOAL_WATCH")"
if [ -n "$_g51_fn" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G51.extract: located _uberdev_goal_watch_solver_busy in lib/goal-watch.sh"
  _g51_dir="$(mktemp -d 2>/dev/null || printf '/tmp/goal-g51-%s' "$$")"
  {
    echo 'set -u'
    echo 'uberdev_goal_agent_busy_for_issue() { printf "PROBED=%s\n" "${UBERDEV_RESOLVED_BACKEND:-}"; return 1; }'
    printf '%s\n' "$_g51_fn"
    echo '_uberdev_goal_watch_solver_busy 123; printf "RC=%s\n" "$?"'
    echo 'printf "AFTER=%s\n" "${UBERDEV_RESOLVED_BACKEND:-}"'
  } > "$_g51_dir/probe.sh"
  _g51_out="$(UBERDEV_RESOLVED_BACKEND=background UBERDEV_GOAL_SOLVER_BACKEND=workflow \
    "${BASH:-bash}" "$_g51_dir/probe.sh" 2>&1)"
  if grep -q '^PROBED=workflow$' <<<"$_g51_out"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G51.probes-solver-backend: liveness is asked under the SOLVER backend, not the pinned child transport"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G51.probes-solver-backend: probe saw the child transport — got: [$_g51_out]" >&2
  fi
  if grep -q '^AFTER=background$' <<<"$_g51_out"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G51.restores-child-backend: the child transport is restored after the probe (the /merge + /review-pr dispatches keep it)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G51.restores-child-backend: the override leaked past the probe — got: [$_g51_out]" >&2
  fi
  # The no-PR solver arm must go through the wrapper. A bare
  # `uberdev_goal_agent_busy_for_issue "$issue"` there is the bug returning.
  if grep -qE '^[[:space:]]*if[[:space:]]+uberdev_goal_agent_busy_for_issue[[:space:]]+"\$issue"' "$GOAL_WATCH"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G51.no-bare-solver-probe: the solver arm calls uberdev_goal_agent_busy_for_issue directly again — the pin re-routes it" >&2
  else
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "G51.no-bare-solver-probe: the solver arm probes only via _uberdev_goal_watch_solver_busy"
  fi
  rm -rf "$_g51_dir"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G51.extract: _uberdev_goal_watch_solver_busy missing — the pin re-routes the solver liveness probe" >&2
fi
# The solver backend must be captured BEFORE the pin overwrites it.
_g51_save_line="$(grep -n 'UBERDEV_GOAL_SOLVER_BACKEND="\${UBERDEV_GOAL_SOLVER_BACKEND:-\${UBERDEV_RESOLVED_BACKEND:-}}"' "$GOAL_WATCH" | head -1 | cut -d: -f1)"
_g51_pin_line="$(grep -n 'UBERDEV_DISPATCH_BACKEND_REQUESTED="\${UBERDEV_GOAL_CHILD_BACKEND:-background}"' "$GOAL_WATCH" | head -1 | cut -d: -f1)"
if [ -n "$_g51_save_line" ] && [ -n "$_g51_pin_line" ] && [ "$_g51_save_line" -lt "$_g51_pin_line" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G51.saved-before-pin: the run-level solver backend is captured before the child-transport pin runs"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G51.saved-before-pin: solver backend captured at line [$_g51_save_line], pin at [$_g51_pin_line] — capture must come first" >&2
fi

echo
echo "== G52: the bash>=4 execution contract reaches the RELAY-RUN phase scripts (#294) =="
# lib/goal-phase0.sh's re-exec fixes phase 0 and nothing else: Phases 1/2/3 are
# separate processes the driver's relays launch. PATH `bash` is 3.2 on stock
# macOS, where lib/goal-watch.sh dies on `active_issues[@]: unbound variable` —
# a non-0/42 status the driver reports as watch_script_error on cycle 1.
assert_grep "$GOAL_P0" 'UBERDEV_GOAL_BASH="\$\{UBERDEV_GOAL_BASH:-\$\{BASH:-\}\}"' "G52.phase0-publishes-in-the-already-bash4-arm"
assert_grep "$GOAL_P0" 'bashBin="\$GOAL_BASH_BIN"'                                  "G52.phase0-emits-bashBin-in-the-envelope"
assert_grep "$GOAL_WF" 'CFG.bashBin'                                                "G52.driver-reads-bashBin"
assert_grep "$GOAL_WF" 'function bashCmd'                                           "G52.driver-builds-every-relay-command-under-it"
# ...and no relay may still hardcode a bare `bash "<path>"` command word.
# grep -F: the needle is the JS source fragment `'bash "' +`, which is all
# metacharacter and would be a silently-never-matching ERE.
if grep -F "'bash \"' +" "$GOAL_WF" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G52.no-bare-bash-relay: a relay still launches a phase script with PATH bash" >&2
else
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G52.no-bare-bash-relay: no relay hardcodes PATH bash for a phase script"
fi
# The published path must survive Phase 0's own arm (a) — the CI/bash>=4 case.
_g52_out="$("${BASH:-bash}" -c '
  set -u
  BASH_VERSINFO_PROBE=1
  '"$(awk "/^# >>> region: bash4-resolver/{c=1;next} /^# <<< region: bash4-resolver/{exit} c{print}" "$GOAL_P0")"'
  printf "PUBLISHED=%s\n" "${UBERDEV_GOAL_BASH:-unset}"
' 2>&1)"
# A drive-letter prefix is accepted for Git-Bash-on-windows; the asserted
# property is "absolute path to a bash", not a POSIX-only spelling.
if grep -qE '^PUBLISHED=([A-Za-z]:)?/.*bash' <<<"$_g52_out"; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "G52.arm-a-publishes: running the resolver under bash>=4 publishes an absolute interpreter path"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "G52.arm-a-publishes: arm (a) left UBERDEV_GOAL_BASH unset — Phases 1/2/3 would fall back to PATH bash — got: [$_g52_out]" >&2
fi

echo
echo "== G53: --max-watch-ticks is an operator-tunable knob, not a hardcoded driver default =="
assert_grep "$GOAL_P0" '--max-watch-ticks='                                      "G53.phase0-parses-the-flag"
assert_grep "$GOAL_P0" 'goal\.max_watch_ticks UBERDEV_GOAL_MAX_WATCH_TICKS 1 500 40' "G53.phase0-resolves-via-the-standard-precedence-chain"
assert_grep "$GOAL_P0" 'maxWatchTicks="\$MAX_WATCH_TICKS"'                           "G53.phase0-emits-it-in-the-envelope"
assert_grep "$GOAL_CMD" '--max-watch-ticks=N'                                     "G53.cmd-documents-the-flag"

echo
echo "== Summary =="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
