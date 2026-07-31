#!/usr/bin/env bash
# tests/uberscan.test.sh — RFC 0012 §3.7 (Phase 3): /uberscan migrated to the
# shared scan-fleet Workflow. This file tests the THIN SKILL.md seam + the
# command/alias surface + the extracted global-pass.sh. The orchestration logic
# (area fanout, CB5/CB7, model policy, phase order) lives in workflow.js and is
# tested behaviorally by tests/scan-fleet-workflow.test.sh; chunk.py + report.py
# keep their own tests (uberscan-chunk.test.sh / uberscan-report.test.sh).
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/uberscan.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/uberscan-pipeline/SKILL.md"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
GLOBAL_PASS="$REPO_ROOT/plugins/uberdev/skills/scan-fleet/global-pass.sh"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

echo "== U1: command file structure =="
ck "command file exists" "[ -r '$CMD' ]"
ck "has description frontmatter" "grep -q '^description:' '$CMD'"
ck "has argument-hint" "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools" "grep -q '^allowed-tools:' '$CMD'"

echo "== U2: READ-ONLY invariant (no Edit/MultiEdit in allowed-tools) =="
ck "allowed-tools omits Edit/MultiEdit" "[ \$(grep '^allowed-tools:' '$CMD' | grep -cE '\"Edit\"|MultiEdit') -eq 0 ]"
ck "allowed-tools carries Workflow (the migration's dispatch tool)" "grep '^allowed-tools:' '$CMD' | grep -q '\"Workflow\"'"

echo "== U3: pipeline skill =="
ck "skill exists" "[ -r '$SKILL' ]"
ck "skill name is uberscan-pipeline" "grep -q '^name: uberscan-pipeline' '$SKILL'"
ck "skill references chunk.py"  "grep -q 'chunk.py' '$SKILL'"
ck "skill references report.py" "grep -q 'report.py' '$SKILL'"
ck "skill dispatches code-reviewer (read-only), never code-simplifier" "grep -q 'code-reviewer' '$SKILL' && [ \$(grep -c 'code-simplifier' '$SKILL') -eq 0 ]"
ck "retains the C2 per-area schema contract" "grep -q 'schema_version: 1' '$SKILL' && grep -q 'chunk-NNN-findings.yaml' '$SKILL'"

echo "== U4: alias registration + drift (byte-match) =="
ck "alias row present" "grep -q '^uberscan|uberscan|' '$SYNC'"
ALIAS_TOOLS="$(grep '^uberscan|uberscan|' "$SYNC" | cut -d'|' -f3 | tr -d "'")"
CMD_TOOLS="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //' | tr -d "'")"
ck "alias tools byte-match command allowed-tools" "[ \"\$ALIAS_TOOLS\" = \"\$CMD_TOOLS\" ]"

echo "== U5: thin Workflow seam (RFC 0012 §3.7 / DR-1/DR-2) =="
ck "preflight emits scan-fleet args via uberdev_emit_workflow_args (DR-2 verbatim relay)" "grep -q 'uberdev_emit_workflow_args scan-fleet' '$SKILL'"
ck "emits mode=scan" "grep -q 'mode=scan' '$SKILL'"
ck "mandates the scriptPath Workflow call into scan-fleet/workflow.js" "grep -qF 'Workflow({scriptPath: \"\$CLAUDE_PLUGIN_ROOT/skills/scan-fleet/workflow.js\"}' '$SKILL'"
# RFC 0012 §4.1: an EXECUTABLE [ -f ...workflow.js ] existence guard (variable form), not prose.
ck "runs the §4.1 [ -f \"\$WORKFLOW_JS\" ] existence guard before mandating" \
  "grep -qE '\\[[[:space:]]+-f[[:space:]]+\"\\\$WORKFLOW_JS\"[[:space:]]+\\]' '$SKILL' && grep -qE '^[[:space:]]*WORKFLOW_JS=.*skills/scan-fleet/workflow\\.js' '$SKILL'"
ck "carries the '## No-Workflow fallback' section (DR-10)" "grep -qF '## No-Workflow fallback' '$SKILL'"
ck "resolves uberscan.areas config key (default 8, range 1-24)" "grep -qE 'uberscan\\.areas .*UBERDEV_UBERSCAN_AREAS .*1 24 8' '$SKILL'"
ck "no per-phase #171 RUN_ID rehydrate stanza remains (single-process workflow now)" "[ \$(grep -c 'uberscan-active-id.txt' '$SKILL') -eq 0 ]"
ck "no fence-scoped CIRCUIT_BREAKER_HALT run-state.txt persistence remains (CB lives in workflow.js)" "[ \$(grep -c 'CIRCUIT_BREAKER_HALT=' '$SKILL') -eq 0 ]"

echo "== U6: global-pass.sh extracted (the inline Semgrep + coverage pass) =="
ck "global-pass.sh exists + executable shebang" "[ -r '$GLOBAL_PASS' ] && head -1 '$GLOBAL_PASS' | grep -q 'bin/env bash'"
ck "skill references global-pass.sh" "grep -q 'global-pass.sh' '$SKILL'"
ck "global-pass runs Semgrep" "grep -qE 'semgrep scan --config' '$GLOBAL_PASS'"
ck "global-pass writes the two artifacts report.py reads by name" "grep -q 'global-security.md' '$GLOBAL_PASS' && grep -q 'global-coverage.md' '$GLOBAL_PASS'"

echo "== U7: global-pass coverage heuristic — behavioral (runtime-only code) =="
# The coverage python is a heredoc inside global-pass.sh — shape tests never run
# it, so a typo / non-fail-soft crash would only surface on a live /uberscan.
# Extract the REAL coverage heredoc and run it (moved here from the old SKILL.md).
P1B_TMP="$(mktemp -d)"
awk '/COV_OUT.*<<.PY/{f=1;next} f&&/^PY$/{f=0} f{print}' "$GLOBAL_PASS" > "$P1B_TMP/cov.py"
ck "coverage heredoc extracted (non-empty)" "[ -s '$P1B_TMP/cov.py' ]"
ck "coverage python is syntactically valid" "python3 -c \"import ast; ast.parse(open('$P1B_TMP/cov.py').read())\""
( cd "$P1B_TMP" && git init -q && mkdir -p src tests && printf 'a\nb\n' > src/mod.py && printf 'x\n' > tests/test_mod.py && git add -A 2>/dev/null )
COV_RUN="$(cd "$P1B_TMP" && python3 cov.py . 2>&1)"
ck "coverage run emits the 'Source files:' summary" "grep -q 'Source files:' <<<\"\$COV_RUN\""
ck "coverage run never writes a Python traceback (fail-soft)" "! grep -q 'Traceback (most recent call last)' <<<\"\$COV_RUN\""
COV_NONGIT="$(cd "$(mktemp -d)" && python3 "$P1B_TMP/cov.py" . 2>&1)"; COV_NONGIT_RC=$?
ck "coverage is fail-soft outside a git repo (exit 0, no traceback)" "[ $COV_NONGIT_RC -eq 0 ] && ! grep -q 'Traceback' <<<\"\$COV_NONGIT\""
# global-pass.sh itself is fail-soft + always exits 0 (advisory pass must never abort the audit).
GP_TMP="$(mktemp -d)"; ( cd "$GP_TMP" && git init -q && printf 'x\n' > a.py && git add -A 2>/dev/null )
( cd "$GP_TMP" && bash "$GLOBAL_PASS" . "$GP_TMP" ); GP_RC=$?
ck "global-pass.sh exits 0 (fail-soft) and writes both artifacts" "[ $GP_RC -eq 0 ] && [ -f '$GP_TMP/global-security.md' ] && [ -f '$GP_TMP/global-coverage.md' ]"
rm -rf "$P1B_TMP" "$GP_TMP"

echo "== U8: chunk.py CLI contract (the relay must use REAL flags — guards the --out blocker class) =="
# The Workflow harness STUBS agents, so the CLI strings inside scan-fleet.js relay
# prompts are never executed by the behavioral fixtures. A fabricated flag (the
# `--out` class — chunk.py has no --out, it writes JSON to stdout) would ship
# silently and break EVERY live run. Lock chunk.py's real interface here + assert
# the relays redirect stdout instead of passing --out.
CHUNK="$REPO_ROOT/plugins/uberdev/lib/chunk.py"
WF="$REPO_ROOT/plugins/uberdev/skills/scan-fleet/workflow.js"
CK_TMP="$(mktemp -d)"; ( cd "$CK_TMP" && git init -q && printf 'x\n' > a.py && git add -A 2>/dev/null )
( cd "$CK_TMP" && python3 "$CHUNK" --scope . --areas 2 --run-id T > "$CK_TMP/m.json" 2>/dev/null ); CK_RC=$?
ck "chunk.py writes manifest JSON to STDOUT with --scope/--areas/--run-id (rc 0, valid JSON)" \
  "[ $CK_RC -eq 0 ] && python3 -c \"import json,sys; d=json.load(open('$CK_TMP/m.json')); sys.exit(0 if isinstance(d.get('chunks'),list) else 1)\""
ck "chunk.py REJECTS --out (proves the relays MUST redirect stdout, not pass --out — review blocker #2)" \
  "! ( cd '$CK_TMP' && python3 '$CHUNK' --scope . --areas 2 --run-id T --out '$CK_TMP/x.json' >/dev/null 2>&1 )"
# (The "pack relay redirects stdout, no chunk.py --out" assertion lives in
# tests/scan-fleet-workflow.test.sh, which inspects the actual rendered area-pack
# prompt string — robust against report.py/aggregate.py's legitimate --out usage.)
rm -rf "$CK_TMP"

echo "== scan-R5 (RFC 0012): CB6 rate-floor owned by findings-to-issues, not duplicated =="
ck "no pre-dispatch gh rate_limit probe in the SKILL" "[ \$(grep -c 'gh api rate_limit' '$SKILL') -eq 0 ]"
ck "no RATE_OK gating in the SKILL" "[ \$(grep -c 'RATE_OK' '$SKILL') -eq 0 ]"
ck "CB6 delegation to findings-to-issues Step 2 documented" "grep -q 'findings-to-issues.md Step 2' '$SKILL'"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
