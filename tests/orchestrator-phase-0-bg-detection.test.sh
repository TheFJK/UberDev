#!/usr/bin/env bash
# tests/orchestrator-phase-0-bg-detection.test.sh
#
# Validates the orchestrator/SKILL.md Phase 0 bg-context detection gate
# introduced by issue #93. Mirrors the anchored-grep style of
# tests/orchestrator-phase-6-doc.test.sh and tests/turbo-flow.test.sh.
#
# Assertions A1-A7 from the design spec
# (docs/uberdev/specs/2026-05-13-orchestrator-bg-context-detection-design.md
# Components §4).
#
# Each assertion echoes pass/fail and increments PASS / FAIL counters.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok   $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name (expected=$expected actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_ge() {
  local name="$1" min="$2" actual="$3"
  if (( actual >= min )); then
    echo "  ok   $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name (expected>=$min actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

echo "[orchestrator-phase-0-bg-detection] checking $SKILL"

if [ ! -f "$SKILL" ]; then
  echo "  FAIL precondition: SKILL file not found at $SKILL"
  exit 1
fi

# Extract the Phase 0 section body (### Phase 0: setup ... up to ### Phase 1:)
# once so A1-A6 can scope assertions to the new gate and a stray match in a
# later phase cannot mask deletion of the Phase 0 prose.
phase0_body=$(awk '/^### Phase 0: setup$/{f=1; next} /^### Phase 1:/{f=0} f' "$SKILL")

# A1 — both detection arms present in the Phase 0 block
n_jobdir=$(printf '%s\n' "$phase0_body" | grep -cF 'CLAUDE_JOB_DIR' || true)
n_tty=$(printf '%s\n' "$phase0_body" | grep -cE '! -t 0' || true)
assert_ge "A1a Phase 0 names CLAUDE_JOB_DIR"        1 "$n_jobdir"
assert_ge "A1b Phase 0 names POSIX [ ! -t 0 ] arm"  1 "$n_tty"

# A2 — literal stderr abort message present (generalised form covers the
# standalone-invocation path per reviewer finding; either form is accepted).
n=$(printf '%s\n' "$phase0_body" | grep -cE 'cannot run in a claude --bg session' || true)
assert_ge "A2 Phase 0 contains stderr abort message" 1 "$n"

# A3 — non-zero exit code in the Phase 0 gate
n=$(printf '%s\n' "$phase0_body" | grep -cE 'exit 2' || true)
assert_ge "A3 Phase 0 uses exit 2 (non-zero abort)" 1 "$n"

# A4 — turbo exemption inside the Phase 0 block: BOTH --turbo and
# UBERDEV_TURBO referenced BEFORE the bg-context test. We assert the
# ordering via awk: the line containing UBERDEV_TURBO must precede the
# line containing CLAUDE_JOB_DIR inside Phase 0.
order=$(printf '%s\n' "$phase0_body" | awk '
  /UBERDEV_TURBO/ { if (!seen_jobdir) seen_turbo = NR }
  /CLAUDE_JOB_DIR/ { if (seen_turbo) seen_jobdir = NR }
  END { print (seen_turbo && seen_jobdir && seen_turbo < seen_jobdir) ? "ok" : "fail" }
')
assert_eq "A4a turbo exemption precedes bg-context test" "ok" "$order"
n_turbo=$(printf '%s\n' "$phase0_body" | grep -cE -- '--turbo' || true)
assert_ge "A4b Phase 0 names --turbo (standalone-invocation arm)" 1 "$n_turbo"

# A5 — imperative MUST abort / MUST NOT proceed wording (mirrors the
# Phase 2 gate template from commit 790c654; defends against soft prose
# drift that previously made /solve auto-collapse into /turbo).
n=$(printf '%s\n' "$phase0_body" | grep -ciE 'MUST abort|MUST NOT proceed' || true)
assert_ge "A5 Phase 0 uses imperative MUST gate wording" 1 "$n"

# A6 — fail-fast position: the bg-context gate (CLAUDE_JOB_DIR reference)
# must appear in the SKILL.md BEFORE the first RUN_ID= assignment.
bg_line=$(grep -nE 'CLAUDE_JOB_DIR' "$SKILL" | head -1 | cut -d: -f1 || true)
rid_line=$(grep -nE '^RUN_ID=|^\s*1\. Generate a run-id|RUN_ID=\$' "$SKILL" | head -1 | cut -d: -f1 || true)
if [ -n "${bg_line:-}" ] && [ -n "${rid_line:-}" ] && [ "$bg_line" -lt "$rid_line" ]; then
  echo "  PASS A6 bg-context gate precedes RUN_ID generation (bg=$bg_line rid=$rid_line)"
  PASS=$((PASS + 1))
else
  echo "  FAIL A6 fail-fast invariant violated (bg=$bg_line rid=$rid_line)"
  FAIL=$((FAIL + 1))
fi

# A7 — Phase 2 turbo detector at lines ~200-211 unchanged (negative
# assertion guarding against accidental Phase 2 modification when adding
# Phase 0). The exact shape is the hybrid OR detector documented in spec
# Decision Q6 and tested in turbo-flow.test.sh:308-310.
phase2_body=$(awk '/^### Phase 2: Q&A$/{f=1; next} /^### Phase 3:/{f=0} f' "$SKILL")
n=$(printf '%s\n' "$phase2_body" | grep -cE '\$ARGUMENTS.*--turbo.*UBERDEV_TURBO|UBERDEV_TURBO.*\$ARGUMENTS.*--turbo' || true)
assert_ge "A7 Phase 2 hybrid turbo detector unchanged" 1 "$n"

echo ""
echo "[orchestrator-phase-0-bg-detection] PASS=$PASS FAIL=$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0

# ─────────────────────────────────────────────────────────────────────
# Manual verification (not automated — run before merging the PR):
#
#   1. /solve #93 from interactive TTY
#        → orchestrator reaches Phase 2 and asks 3-5 clarifying questions
#        (baseline preserved; bg-gate's TTY arm is false, CLAUDE_JOB_DIR
#        is absent → turbo exemption irrelevant → step 1+ runs normally).
#
#   2. /solve #93 from `claude --bg --worktree solve-issue-93`
#        → orchestrator aborts in Phase 0 with the generalised stderr
#        message; `claude agents` surfaces `exit 2` within seconds; no
#        $RESEARCH_DIR_ABS directory is created.
#
#   3. /turbo #93 from `claude --bg`
#        → orchestrator proceeds through Phase 0 (turbo exemption fires
#        on UBERDEV_TURBO=1); no abort; Phase 1 fanout dispatches.
# ─────────────────────────────────────────────────────────────────────
