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
expect_fail "V8b missing native Codex marketplace fails"     'rm -f "$d/.agents/plugins/marketplace.json"'
expect_fail "V8c empty native Codex marketplace fails"       'mkdir -p "$d/.agents/plugins"; : > "$d/.agents/plugins/marketplace.json"'
expect_fail "V8d wrong native marketplace name fails"        'python3 - "$d/.agents/plugins/marketplace.json" <<'"'"'PY'"'"'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["name"]="wrong"; p.write_text(json.dumps(tree))
PY'
expect_fail "V8e wrong native plugin name fails"             'python3 - "$d/.agents/plugins/marketplace.json" <<'"'"'PY'"'"'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["plugins"][0]["name"]="wrong"; p.write_text(json.dumps(tree))
PY'
expect_fail "V8f wrong native plugin source fails"           'python3 - "$d/.agents/plugins/marketplace.json" <<'"'"'PY'"'"'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["plugins"][0]["source"]["path"]="./wrong"; p.write_text(json.dumps(tree))
PY'
expect_fail "V8g wrong native plugin availability fails"     'python3 - "$d/.agents/plugins/marketplace.json" <<'"'"'PY'"'"'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["plugins"][0]["policy"]["installation"]="UNAVAILABLE"; p.write_text(json.dumps(tree))
PY'
expect_fail "V8h changed README marketplace selector fails"   'python3 - "$d/codex/README.md" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace("codex plugin add prkit-codex@prkit","codex plugin add prkit-codex@wrong"))
PY'
expect_fail "V8i duplicated README marketplace selector fails" 'printf "\ncodex plugin add prkit-codex@prkit\n" >> "$d/codex/README.md"'
expect_fail "V8j suffixed README marketplace selector fails"  'python3 - "$d/codex/README.md" <<'"'"'PY'"'"'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace("codex plugin add prkit-codex@prkit","codex plugin add prkit-codex@prkit-evil"))
PY'
expect_fail "V8k root scaffold directory fails"               'rm -f "$d/README.md"; mkdir "$d/README.md"; printf "sentinel\n" > "$d/README.md/sentinel.txt"'
expect_fail "V8l root scaffold symlink fails"                 'rm -f "$d/NOTICE"; ln -s "$d/LICENSE" "$d/NOTICE"'
expect_fail "V8m root scaffold ancestor symlink fails"        'mkdir -p "$dp/outside-agents/plugins"; cp "$d/.agents/plugins/marketplace.json" "$dp/outside-agents/plugins/marketplace.json"; rm -rf "$d/.agents"; ln -s "$dp/outside-agents" "$d/.agents"'
expect_fail "V8n generated-tree ancestor symlink fails"       'mv "$d/plugins" "$dp/outside-plugins"; ln -s "$dp/outside-plugins" "$d/plugins"'
expect_fail "V8o nested generated-tree symlink fails"         'printf "outside\n" > "$dp/outside-file"; ln -s "$dp/outside-file" "$d/codex/nested-link"'
expect_fail "V8p nested generated-tree special file fails"    'mkfifo "$d/codex/nested-pipe"'
expect_fail "V9 removed all agents (non-vacuity/ref-int) fails" 'rm -rf "$d/plugins/prkit/agents"'
expect_fail "V10 removed Claude reviewer contract fails" 'rm -f "$d/plugins/prkit/shared/phase1-reviewer-output-v1.md"'
expect_fail "V11 removed Codex solve run tree fails" 'rm -f "$d/codex/prkit-codex/policy/solve-run-tree-v1.json"'
expect_fail "V12 native reviewer injected edge schema fails" 'python3 - "$d/codex/agents/prkit-code-reviewer.toml" "$d/codex/prkit-codex/shared/phase1-reviewer-output-v1.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); contract=Path(sys.argv[2]).read_text(); p.write_text(p.read_text()+"\n"+contract)
PY'
expect_fail "V13 out-of-scope policy edge fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); tree["edges"]["solve.issue.lead"]={"kind":"skill"}; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V14 unshipped provider role fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); next(edge for edge in tree["edges"].values() if edge.get("kind")=="provider")["role"]="ghost-agent"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V15 unknown workflow in policy fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); next(edge for edge in tree["edges"].values() if edge.get("kind")=="provider")["allowed_workflows"].append("unknown"); p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V16 cross-runtime policy byte divergence fails" 'python3 - "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); tree=json.loads(p.read_text()); edge=tree["edges"]["review_pr.review.correctness"]; edge["allowed_workflows"]=["review-pr","simplify"]; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V17 duplicate policy JSON key fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(); p.write_text(text.replace("{", "{\n  \"schema_version\": 1,", 1))
PY'
expect_fail "V18 non-finite policy JSON constant fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(); p.write_text(text.replace("{", "{\n  \"non_finite\": NaN,", 1))
PY'
expect_fail "V19 unknown policy root key fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["unknown_root"]="must-not-survive"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V20 unexpected review provider edge fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); source=tree["edges"]["review_pr.review.correctness"].copy(); source["allowed_workflows"]=["review-pr"]; tree["edges"]["review_pr.review.unexpected"]=source; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V21 incomplete generated role fleets fail" 'rm -f "$d/plugins/prkit/agents/merge-strategy-decider.md" "$d/codex/agents/prkit-merge-strategy-decider.toml"'
expect_fail "V22 paired runtime reviewer-role swap fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); left=tree["edges"]["review_pr.review.correctness"]; right=tree["edges"]["review_pr.review.comments"]; left["role"],right["role"]=right["role"],left["role"]; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V23 paired runtime workflow swap fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); left=tree["edges"]["review_pr.fix.phase1"]; right=tree["edges"]["review_pr.fix.phase2"]; left["allowed_workflows"],right["allowed_workflows"]=right["allowed_workflows"],left["allowed_workflows"]; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'
expect_fail "V24 paired runtime unexpected edge contract fails" 'python3 - "$d/plugins/prkit/policy/solve-run-tree-v1.json" "$d/codex/prkit-codex/policy/solve-run-tree-v1.json" <<'PY'
import json,sys
from pathlib import Path
for name in sys.argv[1:]:
 p=Path(name); tree=json.loads(p.read_text()); tree["edges"]["review_pr.fix.phase1"]["output_contract"]="phase1-reviewer-v1"; p.write_text(json.dumps(tree,sort_keys=True,indent=2)+"\n")
PY'

# V25 — a placeholder scan error is unavailable evidence, never proof that the
# generated output is clean. The wrapper passes every earlier grep through and
# fails only the final placeholder-pattern invocation.
dp="$(mktemp -d)"; d="$dp/t"; cp -R "$BASE" "$d"; mkdir "$dp/bin"
cat > "$dp/bin/grep" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *A-Za-z_*) exit 2 ;;
esac
exec "$PRKIT_REAL_GREP" "$@"
SH
chmod +x "$dp/bin/grep"
real_grep="$(command -v grep)"
V25_OUTPUT=""
if V25_OUTPUT="$(PATH="$dp/bin:$PATH" PRKIT_REAL_GREP="$real_grep" \
     bash "$VERIFY" "$d" 2>&1)"; then
  no "V25 placeholder scan error fails closed (verify wrongly PASSED)"
elif ! printf '%s\n' "$V25_OUTPUT" | grep -qF 'placeholders: scan errored'; then
  no "V25 placeholder scan error fails closed (expected diagnostic missing)"
else
  ok "V25 placeholder scan error fails closed"
fi
rm -rf "$dp"

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
