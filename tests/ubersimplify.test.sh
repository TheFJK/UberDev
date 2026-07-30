#!/usr/bin/env bash
# tests/ubersimplify.test.sh — RFC 0012 §3.7 (Phase 3): /ubersimplify migrated to
# the shared scan-fleet Workflow. Tests the THIN SKILL.md seam + command/alias
# surface. The orchestration (area fanout, sequential code-fixer apply, CB5/CB7,
# model policy, phase order, the --audit-only branch) lives in workflow.js and is
# tested behaviorally by tests/scan-fleet-workflow.test.sh; aggregate.py keeps its
# own test (ubersimplify-aggregate.test.sh).
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
ck "allowed-tools carries Workflow (the migration's dispatch tool)" "grep '^allowed-tools:' '$CMD' | grep -q '\"Workflow\"'"
ck "preflight refuses dirty tree" "grep -q 'working tree is dirty' '$CMD'"
ck "hands off to ubersimplify-pipeline" "grep -q 'uberdev:ubersimplify-pipeline' '$CMD'"

echo "== pipeline skill structure =="
ck "skill exists" "[ -r '$SKILL' ]"
ck "skill name is ubersimplify-pipeline" "grep -q '^name: ubersimplify-pipeline' '$SKILL'"
ck "uses shared lib/chunk.py (not uberscan-pipeline copy)" "grep -q 'lib/chunk.py' '$SKILL' && [ \$(grep -c 'uberscan-pipeline/chunk.py' '$SKILL') -eq 0 ]"
ck "references aggregate.py" "grep -q 'aggregate.py' '$SKILL'"
ck "the 3 lenses are named (multi-lens code-simplifier per area)" "grep -q 'code-simplifier' '$SKILL' && grep -q 'Reuse' '$SKILL' && grep -q 'Quality' '$SKILL' && grep -q 'Efficiency' '$SKILL'"
ck "applies via code-fixer" "grep -q 'code-fixer' '$SKILL'"
ck "creates a branch" "grep -q 'checkout -b ubersimplify/' '$SKILL'"
ck "opens a PR" "grep -q 'gh pr create' '$SKILL'"
ck "files leftovers via findings-to-issues" "grep -q 'findings-to-issues' '$SKILL' && grep -q 'ubersimplify-finding' '$SKILL'"
ck "fixer aggregates use canonical Phase 2 v2" "grep -q 'simplify-aggregate' '$SKILL' && grep -q 'schema v2\|schema-v2' '$SKILL'"
ck "fixer dispositions are JSON" "grep -q 'fixer-disposition.json' '$SKILL' && ! grep -q 'fixer-disposition.yaml' '$SKILL'"
ck "audit-only skips branch/PR" "grep -q 'audit-only' '$SKILL'"
ck "config namespace ubersimplify.*" "grep -q 'ubersimplify.areas' '$SKILL' && grep -q 'fanout_concurrency.ubersimplify' '$SKILL'"
ck "retains the C-LENS per-area schema contract" "grep -q 'schema_version: 1' '$SKILL' && grep -q 'chunk-NNN-lens.yaml' '$SKILL'"
ck "no Co-Authored-By trailer in PR body" "[ \$(grep -ci 'Co-Authored-By' '$SKILL') -eq 0 ]"

echo "== thin Workflow seam (RFC 0012 §3.7 / DR-1/DR-2) =="
ck "preflight emits scan-fleet args via uberdev_emit_workflow_args (DR-2)" "grep -q 'uberdev_emit_workflow_args scan-fleet' '$SKILL'"
ck "emits mode=simplify" "grep -q 'mode=simplify' '$SKILL'"
ck "mandates the scriptPath Workflow call into scan-fleet/workflow.js" "grep -qF 'Workflow({scriptPath: \"\$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js\"}' '$SKILL'"
ck "runs the §4.1 [ -f \"\$WORKFLOW_JS\" ] existence guard (variable form)" \
  "grep -qE '\\[[[:space:]]+-f[[:space:]]+\"\\\$WORKFLOW_JS\"[[:space:]]+\\]' '$SKILL' && grep -qE '^[[:space:]]*WORKFLOW_JS=.*skills/scan-fleet/workflow\\.js' '$SKILL'"
ck "carries the '## No-Workflow fallback' section (DR-10)" "grep -qF '## No-Workflow fallback' '$SKILL'"
ck "preflight resolves an absolute WORKING_DIR_ABS via git rev-parse --show-toplevel" "grep -qF 'WORKING_DIR_ABS=\"\$(git rev-parse --show-toplevel' '$SKILL'"
ck "no per-phase #171 RUN_ID rehydrate stanza remains (single-process workflow now)" "[ \$(grep -c 'ubersimplify-active-id.txt' '$SKILL') -eq 0 ]"

echo "== scan-R5 (RFC 0012): CB6 rate-floor owned by findings-to-issues, not duplicated =="
ck "no pre-dispatch gh rate_limit probe in the SKILL" "[ \$(grep -c 'gh api rate_limit' '$SKILL') -eq 0 ]"
ck "no RATE_OK gating in the SKILL" "[ \$(grep -c 'RATE_OK' '$SKILL') -eq 0 ]"
ck "CB6 delegation to findings-to-issues Step 2 documented" "grep -q 'findings-to-issues.md Step 2' '$SKILL'"

echo "== alias registration (byte-match) =="
ck "alias row present" "grep -q '^ubersimplify|ubersimplify|' '$SYNC'"
TOOLS_CMD="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //')"
TOOLS_ALIAS="$(grep '^ubersimplify|ubersimplify|' "$SYNC" | cut -d'|' -f3)"
ck "alias tools byte-match command allowed-tools" "[ \"\$TOOLS_CMD\" = \"\$TOOLS_ALIAS\" ]"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
