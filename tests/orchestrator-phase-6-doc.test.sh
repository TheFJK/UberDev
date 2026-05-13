#!/usr/bin/env bash
# tests/orchestrator-phase-6-doc.test.sh
#
# Validates the orchestrator/SKILL.md Phase 6 cascade doc (issue #94, PR-time fix).
# Mirrors the anchored-grep style of tests/dispatch-claude-bg.test.sh.
#
# Each assertion echoes pass/fail and increments PASS / FAIL counters.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
CHANGELOG="$ROOT/CHANGELOG.md"

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

echo "[orchestrator-phase-6-doc] checking $SKILL"

# AC1 — new heading present, exact form
n=$(grep -cE '^### Phase 6: PR creation \+ review chain$' "$SKILL" || true)
assert_eq "AC1 Phase 6 heading present"          "1" "$n"

# AC2 — deleted heading is gone
n=$(grep -cE '^## End-of-pipeline' "$SKILL" || true)
assert_eq "AC2 ## End-of-pipeline removed"       "0" "$n"

# AC3 — deleted prose is gone
if grep -qF "the orchestrator's job is done. The downstream skill handles PR creation per its own flow." "$SKILL"; then
  echo "  FAIL AC3 misleading one-liner still present"
  FAIL=$((FAIL + 1))
else
  echo "  ok   AC3 misleading one-liner removed"
  PASS=$((PASS + 1))
fi

# AC4 — structural ordering: Phase 5.5 -> Phase 6 -> Logging
order=$(awk '
  /^### Phase 5\.5:/ { f = 1 }
  /^### Phase 6:/    { if (f) p = 1 }
  /^## Logging/      { l = 1; exit }
  END                { print (p && l) ? "ok" : "fail" }
' "$SKILL")
assert_eq "AC4 Phase 5.5 -> Phase 6 -> Logging order" "ok" "$order"

# AC5 — Phase 6 prose names the canonical skill ids
n=$(grep -cE 'uberdev:subagent-driven-dev|uberdev:finish-branch|uberdev:review-pr' "$SKILL" || true)
assert_ge "AC5 canonical skill ids appear >= 3 times" 3 "$n"

# AC6 — reviewer-count signals
six=$(grep -cE '6 advisory reviewer agents' "$SKILL" || true)
three=$(grep -cE '3 .*code-simplifier.*lenses' "$SKILL" || true)
assert_ge "AC6a 6 advisory reviewer agents mentioned"  1 "$six"
assert_ge "AC6b 3 simplify lenses mentioned"           1 "$three"

# AC7 — large-tier Phase 5.5 ordering acknowledged in Phase 6 prose
n=$(grep -ciE 'Phase 5\.5.*pr-test-analyzer.*before' "$SKILL" || true)
assert_ge "AC7 Phase 5.5 ordering note present"        1 "$n"

# AC8 — CHANGELOG entry naming the issue
n=$(grep -cF 'Closes #94' "$CHANGELOG" || true)
assert_ge "AC8 CHANGELOG references #94"               1 "$n"

echo ""
echo "[orchestrator-phase-6-doc] PASS=$PASS FAIL=$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
