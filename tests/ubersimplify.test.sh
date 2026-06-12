#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/ubersimplify.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/ubersimplify-pipeline/SKILL.md"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

echo "== command structure =="
ck "command file exists" "[ -r '$CMD' ]"
ck "has description"   "grep -q '^description:' '$CMD'"
ck "has argument-hint" "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools" "grep -q '^allowed-tools:' '$CMD'"
ck "command WRITES (Edit present — not read-only)" "grep '^allowed-tools:' '$CMD' | grep -q '\"Edit\"'"
ck "preflight refuses dirty tree" "grep -q 'working tree is dirty' '$CMD'"
ck "hands off to ubersimplify-pipeline" "grep -q 'uberdev:ubersimplify-pipeline' '$CMD'"

echo "== pipeline skill structure =="
ck "skill exists" "[ -r '$SKILL' ]"
ck "skill name is ubersimplify-pipeline" "grep -q '^name: ubersimplify-pipeline' '$SKILL'"
ck "uses shared lib/chunk.py (not uberscan-pipeline copy)" "grep -q 'lib/chunk.py' '$SKILL' && [ \$(grep -c 'uberscan-pipeline/chunk.py' '$SKILL') -eq 0 ]"
ck "references aggregate.py" "grep -q 'aggregate.py' '$SKILL'"
ck "dispatches ONE multi-lens code-simplifier per area (all 3 lenses)" "grep -q 'role: area-multi-lens-simplifier' '$SKILL' && grep -q 'Reuse' '$SKILL' && grep -q 'Quality' '$SKILL' && grep -q 'Efficiency' '$SKILL'"
ck "applies via code-fixer" "grep -q 'code-fixer' '$SKILL'"
ck "creates a branch" "grep -q 'checkout -b ubersimplify/' '$SKILL'"
ck "opens a PR" "grep -q 'gh pr create' '$SKILL'"
ck "files leftovers via findings-to-issues" "grep -q 'findings-to-issues' '$SKILL' && grep -q 'ubersimplify-finding' '$SKILL'"
ck "audit-only skips branch/PR" "grep -q 'audit-only' '$SKILL'"
ck "config namespace ubersimplify.*" "grep -q 'ubersimplify.areas' '$SKILL' && grep -q 'fanout_concurrency.ubersimplify' '$SKILL'"

echo "== area-scoped fixed-fleet fanout (the 210→~8 agent optimization) =="
ck "Phase 0 packs via chunk.py --areas" "grep -q -- '--areas \"\$NUM_AREAS\"' '$SKILL'"
ck "resolves ubersimplify.areas (default 8, range 1-24)" "grep -qE 'ubersimplify\.areas .*UBERDEV_UBERSIMPLIFY_AREAS .*1 24 8' '$SKILL'"
ck "CB7 projects exactly 1 agent per area" "grep -qE 'PROJECTED_AGENTS=\\\$\\(\\( EMITTED_AREAS' '$SKILL'"
ck "old chunks×3 projection removed" "[ \$(grep -c 'EMITTED_CHUNKS \* 3' '$SKILL') -eq 0 ]"
ck "per-lens Task fanout loop removed (no 'for LENS in')" "[ \$(grep -c 'for LENS in' '$SKILL') -eq 0 ]"
ck "no Co-Authored-By trailer in PR body" "[ \$(grep -ci 'Co-Authored-By' '$SKILL') -eq 0 ]"

echo "== scan-R5 (RFC 0012): duplicated CB6 rate-floor fence deleted =="
# The pre-dispatch gh rate-limit floor duplicated agents/findings-to-issues.md
# Step 2 (the canonical owner, which probes both buckets and refuses fail-CLOSED
# with rate-limit-budget-insufficient). The SKILL must NOT re-grow a copy.
ck "no pre-dispatch gh rate_limit probe remains in the SKILL" "[ \$(grep -c 'gh api rate_limit' '$SKILL') -eq 0 ]"
ck "no RATE_OK gating remains in the SKILL" "[ \$(grep -c 'RATE_OK' '$SKILL') -eq 0 ]"
ck "CB6 delegation to findings-to-issues Step 2 documented" "grep -q 'findings-to-issues.md Step 2' '$SKILL'"

# The Phase-5 (File leftover issues) dispatch fence is a FRESH shell (note its
# own #171 RUN_ID/RUN_DIR rehydrate stanza), so it MUST re-resolve WORKING_DIR_ABS
# locally — the only other assignment lives in the Phase-0 preflight fence, which
# does not survive the fence boundary. Reading it without assigning leaves it
# empty -> DISPATCH_OK=0 -> findings-to-issues is silently skipped every run.
# Mirror the uberscan twin (which assigns it inline before ORIGIN_URL).
# The SKILL has exactly TWO dispatch-resolution sites that guard on
# $WORKING_DIR_ABS (Phase-0 preflight + Phase-5 leftover-issues), so the
# count of git-rev-parse assignments of WORKING_DIR_ABS must be >= 2.
WDA_ASSIGNS="$(grep -cF 'WORKING_DIR_ABS="$(git rev-parse --show-toplevel' "$SKILL")"
WDA_GUARDS="$(grep -cF '[ -z "$WORKING_DIR_ABS" ]' "$SKILL")"
ck "every WORKING_DIR_ABS guard fence also assigns it via git rev-parse --show-toplevel (fence-scoped state)" \
  "[ \"\$WDA_ASSIGNS\" -ge \"\$WDA_GUARDS\" ] && [ \"\$WDA_GUARDS\" -ge 1 ]"

echo "== alias registration (byte-match) =="
ck "alias row present" "grep -q '^ubersimplify|ubersimplify|' '$SYNC'"
TOOLS_CMD="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //')"
TOOLS_ALIAS="$(grep '^ubersimplify|ubersimplify|' "$SYNC" | cut -d'|' -f3)"
ck "alias tools byte-match command allowed-tools" "[ \"\$TOOLS_CMD\" = \"\$TOOLS_ALIAS\" ]"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
