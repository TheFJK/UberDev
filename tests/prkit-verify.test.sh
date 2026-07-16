#!/usr/bin/env bash
# tests/prkit-verify.test.sh — the verify gate PASSES a real generated tree and
# FAILS each injected defect. Unix-only (perl+python3+jq via generate); declared
# in the test.yml windows-skip marker. Uses a real generated baseline (not a
# hand-built stub) so the stricter non-vacuity / ref-integrity / syntax-count /
# out-of-set / scaffold / placeholder checks are exercised against realistic input,
# and the codex fail-path is covered (issue #334 review, test-analyzer P1).
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/prkit/generate.sh"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit verify gate (RFC 0014 §5.6)"
[ -r "$VERIFY" ] || { echo "  ABORT — verify.sh missing"; exit 99; }

BASEP="$(mktemp -d)"; BASE="$BASEP/clean"; mkdir -p "$BASE"; git -C "$BASE" init -q
trap 'rm -rf "$BASEP"' EXIT
bash "$GEN" --target "$BASE" --version 0.1.0 >/dev/null 2>&1 || { echo "  ABORT — baseline generation failed"; exit 99; }

# V1 — the clean generated tree passes
if bash "$VERIFY" "$BASE" >/dev/null 2>&1; then ok "V1 clean generated tree passes"; else no "V1 clean generated tree rejected"; fi

# expect_fail <desc> <mutate-cmd> : copy baseline, apply mutation on $d, assert verify FAILS
expect_fail(){
  local desc="$1" mutate="$2" dp d
  dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"
  eval "$mutate"
  if bash "$VERIFY" "$d" >/dev/null 2>&1; then no "$desc (verify wrongly PASSED)"; else ok "$desc"; fi
  rm -rf "$dp"
}

# assembled at runtime so this test file's own bytes never contain the token
UB="UBERDEV""_INJECTED_LEAK=1"

expect_fail "V2 uberdev token in plugins/prkit fails"       'printf "%s\n" "$UB" >> "$d/plugins/prkit/lib/dispatch.sh"'
expect_fail "V3 uberdev token in codex/ fails"              'printf "%s\n" "$UB" >> "$d/codex/prkit-codex/lib/dispatch.sh"'
expect_fail "V4 dangling dispatched agent ref fails"        'printf "subagent_type: prkit:ghost-agent\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V5 residual prkit:goal fails"                  'printf "chain to /prkit:goal here\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V6 dangling out-of-set prkit:brainstorm fails" 'printf "see prkit:brainstorm for ideation\n" >> "$d/plugins/prkit/commands/review-pr.md"'
expect_fail "V7 unrendered {{VERSION}} placeholder fails"   'printf "version {{VERSION}} here\n" >> "$d/README.md"'
expect_fail "V8 empty marketplace.json fails"               ': > "$d/.claude-plugin/marketplace.json"'
expect_fail "V9 removed all agents (non-vacuity/ref-int) fails" 'rm -rf "$d/plugins/prkit/agents"'
expect_fail "V10 removed Claude reviewer contract fails" 'rm -f "$d/plugins/prkit/shared/phase1-reviewer-output-v1.md"'
expect_fail "V11 removed Codex solve run tree fails" 'rm -f "$d/codex/prkit-codex/policy/solve-run-tree-v1.json"'
expect_fail "V12 native reviewer missing canonical schema fails" 'python3 - "$d/codex/agents/prkit-code-reviewer.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); value=p.read_text(); marker="## Phase 1 reviewer output contract (v1)"; p.write_text(value.replace(marker,"removed",1))
PY'

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
