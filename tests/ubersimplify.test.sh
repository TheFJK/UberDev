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

echo "== alias registration (byte-match) =="
ck "alias row present" "grep -q '^ubersimplify|ubersimplify|' '$SYNC'"
TOOLS_CMD="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //')"
TOOLS_ALIAS="$(grep '^ubersimplify|ubersimplify|' "$SYNC" | cut -d'|' -f3)"
ck "alias tools byte-match command allowed-tools" "[ \"\$TOOLS_CMD\" = \"\$TOOLS_ALIAS\" ]"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
