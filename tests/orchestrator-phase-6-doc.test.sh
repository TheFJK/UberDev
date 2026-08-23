#!/usr/bin/env bash
# tests/orchestrator-phase-6-doc.test.sh
#
# Validates the orchestrator/SKILL.md Phase 6 cascade doc (issue #94, PR-time fix).
# Mirrors the anchored-grep style of tests/dispatch-background.test.sh.
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

# Guard: source-of-truth files must exist. Without this, the AC3 negated-grep
# below (and any future bare-grep tests) would silently treat a missing/unreadable
# file as "string absent" and mark the assertion PASS. Fail fast instead.
if [ ! -f "$SKILL" ]; then
  echo "  FAIL precondition: SKILL file not found at $SKILL"
  exit 1
fi
if [ ! -f "$CHANGELOG" ]; then
  echo "  FAIL precondition: CHANGELOG not found at $CHANGELOG"
  exit 1
fi

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

# AC4 — Phase 5.5 must NOT exist (issue #92 — dispatch moved into SDD Step 4.5)
n=$(grep -cE '^### Phase 5\.5:' "$SKILL" || true)
assert_eq "AC4 Phase 5.5 section absent (#92)" "0" "$n"

# AC4b — structural ordering: Phase 5 -> Phase 6 -> the trailing reference
# section (post-#92). #747 moved the Logging contract itself into
# references/tiers-and-recovery.md when the body was cut toward Anthropic's
# 500-line ceiling, so the body's last section is now the pointer that names it.
# Both halves are asserted: the ORDER here, and the CONTENT in AC4c below —
# checking only the pointer would let the logging contract disappear entirely.
order=$(awk '
  /^### Phase 5: /                                { f = 1 }
  /^### Phase 6:/                                 { if (f) p = 1 }
  /^## Tier profiles, failure recovery, logging/  { l = 1; exit }
  END                { print (p && l) ? "ok" : "fail" }
' "$SKILL")
assert_eq "AC4b Phase 5 -> Phase 6 -> the trailing reference section" "ok" "$order"

# AC4c — the Logging contract still exists, in the file the pointer names.
SKILL_TIERS_REF="$(dirname "$SKILL")/references/tiers-and-recovery.md"
n=$(grep -cE '^## Logging$' "$SKILL_TIERS_REF" || true)
assert_eq "AC4c the Logging contract survives in tiers-and-recovery.md" "1" "$n"

# Extract the Phase 6 section body (### Phase 6: ... up to the next `## ` heading)
# once so AC5/AC6/AC7 can all scope their searches to it. Scoping is what makes
# these assertions regress when Phase 6 itself is deleted; otherwise bare-grep
# matches in other phases would mask the regression.
phase6_body=$(awk '/^### Phase 6:/{f=1; next} /^## /{f=0} f' "$SKILL")

# AC5 — Phase 6 prose names the canonical skill ids. Count individual matches
# (grep -o) rather than matching lines (grep -c), so multi-mention lines aren't
# under-counted. The brace-grouped `|| true` keeps a zero-match grep from
# aborting the script under `set -euo pipefail` (pipefail would otherwise
# propagate grep's exit-1 through the command substitution).
n=$(printf '%s\n' "$phase6_body" | { grep -oE 'uberdev:subagent-driven-dev|uberdev:finish-branch|uberdev:review-pr' || true; } | wc -l | tr -d ' ')
assert_ge "AC5 canonical skill ids appear >= 3 times in Phase 6" 3 "$n"

# AC6 — reviewer-count signals (scoped to Phase 6 body, see AC5 comment)
six=$(printf '%s\n' "$phase6_body" | grep -cE '6 advisory reviewer agents' || true)
three=$(printf '%s\n' "$phase6_body" | grep -cE '3 .*code-simplifier.*lenses' || true)
assert_ge "AC6a 6 advisory reviewer agents mentioned"  1 "$six"
assert_ge "AC6b 3 simplify lenses mentioned"           1 "$three"

# AC7 — the Phase 6 design-rung note must NOT mention "Phase 5.5" (post-#92 the
# dispatch is owned by SDD Step 4.5; Phase 6 references the new location).
n=$(printf '%s\n' "$phase6_body" | grep -ciE 'Phase 5\.5' || true)
assert_eq "AC7 Phase 6 body no longer mentions Phase 5.5 (#92)" "0" "$n"

# AC7b — the Phase 6 design-rung note must mention the new SDD Step 4.5 location
n=$(printf '%s\n' "$phase6_body" | grep -ciE 'subagent-driven-dev.*Step 4\.5|SDD.*Step 4\.5' || true)
assert_ge "AC7b Phase 6 names SDD Step 4.5 (#92)" 1 "$n"

# AC8 — CHANGELOG entry naming the issue. Scope to the `## [0.23.1]` block via
# the same awk pattern so an old "Closes #94" in an unrelated future release
# doesn't mask deletion of the 0.23.1 entry.
v0231_body=$(awk '/^## \[0\.23\.1\]/{f=1; next} /^## /{f=0} f' "$CHANGELOG")
n=$(printf '%s\n' "$v0231_body" | grep -cF 'Closes #94' || true)
assert_ge "AC8 CHANGELOG references #94 in 0.23.1"     1 "$n"

# AC9 — CHANGELOG 0.23.5 entry references #92 (the issue this PR closes).
v0235_body=$(awk '/^## \[0\.23\.5\]/{f=1; next} /^## /{f=0} f' "$CHANGELOG")
n=$(printf '%s\n' "$v0235_body" | grep -cF 'Closes #92' || true)
assert_ge "AC9 CHANGELOG references #92 in 0.23.5"     1 "$n"

echo ""
echo "[orchestrator-phase-6-doc] PASS=$PASS FAIL=$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
