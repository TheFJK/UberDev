#!/usr/bin/env bash
# Shape + functional checks for the Codex port deliverables under codex/.
# Verifies: the agent converter round-trips (md→toml, valid TOML, correct
# field mapping incl. RFC 0013 role-default model/effort/sandbox profiles); the
# command converter produces 13 skills + skips the 2 Claude-only ones; generated
# artifacts are Codex-path-safe; the installer is idempotent + installs the
# Codex-ported skill tree; uninstall works; the plugin manifest +
# marketplace.json are valid JSON with the right shape. RFC 0012 §3.4 codex-port.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONVERT_AGENTS="$REPO_ROOT/codex/tools/convert-agents.py"
CONVERT_COMMANDS="$REPO_ROOT/codex/tools/convert-commands.py"
PORT_AGENT_PROMPTS="$REPO_ROOT/codex/tools/port-agent-prompts.sh"
PORT_SKILL="$REPO_ROOT/codex/tools/port-skill.sh"
INSTALLER="$REPO_ROOT/codex/install-codex.sh"
MANIFEST="$REPO_ROOT/codex/uberdev-codex/.codex-plugin/plugin.json"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# assert_cmd RC_EXPECT CMD... — run, compare rc, report.
assert_cmd() {
  local expect="$1"; shift
  local desc="$1"; shift
  local rc
  "$@" >/tmp/codex-test-out 2>&1; rc=$?
  if [ "$rc" -eq "$expect" ]; then pass "$desc"; else
    fail "$desc (expected rc=$expect, got rc=$rc)"; cat /tmp/codex-test-out; fi
}

echo "== Agent converter: round-trip md→toml =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_cmd 0 "convert-agents runs clean over the 44 agents" \
  python3 "$CONVERT_AGENTS" "$REPO_ROOT/plugins/uberdev/agents" "$TMP/agents"

mkdir -p "$TMP/empty-agents-src"
assert_cmd 2 "convert-agents fails when source contains zero agents" \
  python3 "$CONVERT_AGENTS" "$TMP/empty-agents-src" "$TMP/empty-agents-out"

# The converter must use the canonical routing-policy validator, not merely
# read the values it later emits. Each mutation remains syntactically valid
# JSON (except the intentional duplicate-key ambiguity) but violates policy v1.
for mutation in duplicate route effort sandbox; do
  MUT_ROOT="$TMP/policy-mutation-$mutation/uberdev"
  mkdir -p "$MUT_ROOT"
  cp -R "$REPO_ROOT/plugins/uberdev/agents" "$MUT_ROOT/agents"
  cp -R "$REPO_ROOT/plugins/uberdev/lib" "$MUT_ROOT/lib"
  cp -R "$REPO_ROOT/plugins/uberdev/policy" "$MUT_ROOT/policy"
  python3 - "$MUT_ROOT/policy/model-routing-v1.json" "$mutation" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
mutation = sys.argv[2]
raw = path.read_text()
if mutation == "duplicate":
    raw = raw.replace('"schema_version": 1,', '"schema_version": 1,\n  "schema_version": 1,', 1)
    path.write_text(raw)
else:
    value = json.loads(raw)
    if mutation == "route":
        value["routes"]["standard"]["unexpected"] = True
    elif mutation == "effort":
        value["routes"]["standard"]["codex"]["reasoning_effort"] = "impossible"
    else:
        value["roles"]["research-codebase"]["sandbox_ceiling"] = "danger-full-access"
    path.write_text(json.dumps(value, indent=2) + "\n")
PY
  assert_cmd 2 "convert-agents rejects $mutation policy mutation" \
    python3 "$CONVERT_AGENTS" "$MUT_ROOT/agents" "$TMP/mutated-$mutation-out"
done

# All 44 agents produced a uberdev-*.toml.
N="$(find "$TMP/agents" -name 'uberdev-*.toml' 2>/dev/null | wc -l | tr -d ' ')"
[ "$N" -eq 44 ] && pass "44 uberdev-*.toml produced" || fail "expected 44 toml, got $N"

# Every produced .toml parses as valid TOML with the required identity and
# execution-profile keys, and the
# custom-agent name is namespaced to match the file (Codex uses the name field
# as the agent identifier, not the filename).
python3 - <<PY
import tomllib, glob, sys
files = glob.glob("$TMP/agents/uberdev-*.toml")
bad = 0
for p in files:
    d = tomllib.load(open(p, "rb"))
    for k in (
        "name", "description", "developer_instructions", "model",
        "model_reasoning_effort", "sandbox_mode", "features",
    ):
        if k not in d:
            print(f"  FAIL  {p.split('/')[-1]} missing key: {k}"); bad += 1
    expected = p.split("/")[-1].removesuffix(".toml")
    if d.get("name") != expected:
        print(f"  FAIL  {p.split('/')[-1]} name={d.get('name')!r}, expected {expected!r}"); bad += 1
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && pass "all .toml parse + have required keys + namespaced name" || fail "some .toml invalid, missing keys, or unnamespaced"

echo "== Agent converter: RFC 0013 adaptive role profiles =="
python3 - <<PY
import glob
import json
import sys
import tomllib
from pathlib import Path

policy = json.loads(Path("$REPO_ROOT/plugins/uberdev/policy/model-routing-v1.json").read_text())
files = sorted(glob.glob("$TMP/agents/uberdev-*.toml"))
bad = 0
seen = set()
for path in files:
    role = Path(path).stem.removeprefix("uberdev-")
    seen.add(role)
    role_policy = policy["roles"].get(role)
    if role_policy is None:
        print(f"  FAIL  {role}: missing policy role"); bad += 1; continue
    route = policy["routes"][role_policy["route"]]["codex"]
    data = tomllib.load(open(path, "rb"))
    expected = {
        "model": route["model"],
        "model_reasoning_effort": route["reasoning_effort"],
        "sandbox_mode": role_policy["sandbox_ceiling"],
    }
    for key, value in expected.items():
        if data.get(key) != value:
            print(f"  FAIL  {role}: {key}={data.get(key)!r}, expected {value!r}"); bad += 1
    if data.get("features", {}).get("multi_agent") is not False:
        print(f"  FAIL  {role}: leaf profile must set features.multi_agent=false"); bad += 1
    if "max_depth" in data.get("agents", {}):
        print(f"  FAIL  {role}: agents.max_depth is unsupported in role profiles"); bad += 1

missing = set(policy["roles"]) - seen
extra = seen - set(policy["roles"])
if missing or extra:
    print(f"  FAIL  role/profile mismatch: missing={sorted(missing)}, extra={sorted(extra)}")
    bad += 1
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && pass "all 44 role TOMLs exactly match RFC 0013 policy defaults" \
  || fail "generated role TOMLs drift from RFC 0013 policy defaults"

N_MODEL="$(grep -lE '^model = ' "$TMP/agents"/uberdev-*.toml 2>/dev/null | wc -l | tr -d ' ')"
[ "$N_MODEL" -eq 44 ] && pass "all 44 agents pin policy-owned models" \
  || fail "expected 44 policy-owned model keys, found $N_MODEL"
if diff -qr "$TMP/agents" "$REPO_ROOT/codex/agents" >/tmp/codex-agent-drift 2>&1; then
  pass "checked-in role TOMLs match deterministic converter output"
else
  fail "checked-in role TOMLs drift from converter output"
  cat /tmp/codex-agent-drift
fi

python3 - <<PY
import pathlib,sys,tomllib
root=pathlib.Path("$REPO_ROOT")
contract=(root/'plugins/uberdev/shared/phase1-reviewer-output-v1.md').read_text()
roles=('code-reviewer','silent-failure-hunter','type-design-analyzer','comment-analyzer','pr-test-analyzer')
bad=[]
for role in roles:
    value=tomllib.loads((pathlib.Path("$TMP/agents")/f'uberdev-{role}.toml').read_text())['developer_instructions']
    if contract in value: bad.append(role)
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && pass "edge-local reviewer contract is absent from native role TOMLs" \
  || fail "native role TOMLs incorrectly embed the edge-local reviewer contract"
if grep -RqlE '^model = "gpt-5\.4-mini"' "$TMP/agents" 2>/dev/null; then
  fail "generated profiles retain legacy Claude model mapping"
else
  pass "generated profiles contain no legacy Claude model mapping"
fi
# Claude-only fields dropped
NG="$(grep -lE '^(color|allowed-tools|tools) ' "$TMP/agents"/uberdev-*.toml 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "Claude-only fields (color/allowed-tools/tools) dropped from all .toml" \
  || fail "found $NG toml with leftover Claude-only fields"
NG="$(grep -rlE 'CLAUDE_PLUGIN_ROOT|~/\.claude' "$TMP/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "zero Claude-only path/env residuals in generated agents" \
  || fail "found $NG generated agents with Claude-only path/env residuals"
NB="$(grep -rlE '\$\{PLUGIN_ROOT\}/|\$PLUGIN_ROOT/' "$TMP/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NB" -eq 0 ] && pass "generated agents do not depend on bare PLUGIN_ROOT script paths" \
  || fail "found $NB generated agents with bare PLUGIN_ROOT script paths"
if grep -Rql 'â' "$TMP/agents" 2>/dev/null; then
  fail "generated agent metadata has no UTF-8 mojibake"
else
  pass "generated agent metadata has no UTF-8 mojibake"
fi
MODEL_RE='Opus 4\.8|Sonnet 4\.8|WAIT 4\.8|CLAUDE_CODE_SUBAGENT_MODEL|Claude-specific model override'
DANGLING_WAIT_RE='(^|[^[:alnum:]])8-ships intent'
CODEX_PATH_RE='CLAUDE_PLUGIN_ROOT|~/\.claude|~/\.codex/commands'
BARE_ROOT_RE='\$\{PLUGIN_ROOT\}/|\$PLUGIN_ROOT/|(^|[^~])\$\{HOME\}/\.claude|\.claude/plugins'
if grep -RqlE "$MODEL_RE" "$TMP/agents" 2>/dev/null; then
  fail "generated agents do not preserve Claude-only model guidance"
else
  pass "generated agents do not preserve Claude-only model guidance"
fi
if grep -RqlE "$DANGLING_WAIT_RE" "$TMP/agents" 2>/dev/null; then
  fail "generated agents do not leave dangling WAIT-marker fragments"
else
  pass "generated agents do not leave dangling WAIT-marker fragments"
fi

echo "== Runtime Markdown agent prompt porter =="
assert_cmd 0 "port-agent-prompts runs clean over the 44 agents" \
  bash "$PORT_AGENT_PROMPTS" "$REPO_ROOT/plugins/uberdev/agents" "$TMP/runtime-agents"
N_MD="$(find "$TMP/runtime-agents" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$N_MD" -eq 44 ] && pass "44 runtime Markdown prompts produced" || fail "expected 44 runtime Markdown prompts, got $N_MD"
NG="$(grep -rlE 'CLAUDE_PLUGIN_ROOT|~/\.claude' "$TMP/runtime-agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "zero Claude-only path/env residuals in runtime Markdown prompts" \
  || fail "found $NG runtime Markdown prompts with Claude-only path/env residuals"
NB="$(grep -rlE '\$\{PLUGIN_ROOT\}/|\$PLUGIN_ROOT/' "$TMP/runtime-agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NB" -eq 0 ] && pass "runtime Markdown prompts do not depend on bare PLUGIN_ROOT script paths" \
  || fail "found $NB runtime Markdown prompts with bare PLUGIN_ROOT script paths"
if grep -RqlE "$MODEL_RE" "$TMP/runtime-agents" 2>/dev/null; then
  fail "runtime Markdown prompts do not preserve Claude-only model guidance"
else
  pass "runtime Markdown prompts do not preserve Claude-only model guidance"
fi
if grep -RqlE "$DANGLING_WAIT_RE" "$TMP/runtime-agents" 2>/dev/null; then
  fail "runtime Markdown prompts do not leave dangling WAIT-marker fragments"
else
  pass "runtime Markdown prompts do not leave dangling WAIT-marker fragments"
fi
if grep -q '`merge_strategy:` key in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`)' "$TMP/agents/uberdev-merge-strategy-decider.toml" \
   && grep -q '`merge_strategy:` key in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`)' "$TMP/runtime-agents/merge-strategy-decider.md"; then
  pass "generated merge-strategy prompts document Codex config primary and Claude fallback"
else
  fail "generated merge-strategy prompts document Codex config primary and Claude fallback"
fi
if grep -q 'Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md' "$TMP/agents/uberdev-research-constraints.toml" \
   && grep -q 'from AGENTS.md/CLAUDE.md, RFCs, and ADRs' "$TMP/agents/uberdev-research-constraints.toml" \
   && grep -q '<working_dir>/AGENTS.md` — repo-root project rules' "$TMP/agents/uberdev-research-constraints.toml" \
   && grep -q 'Any nested `AGENTS.md` files along the path of files mentioned in `issue_body`' "$TMP/agents/uberdev-research-constraints.toml" \
   && grep -q 'Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md' "$TMP/runtime-agents/research-constraints.md" \
   && grep -q 'from AGENTS.md/CLAUDE.md, RFCs, and ADRs' "$TMP/runtime-agents/research-constraints.md" \
   && grep -q '<working_dir>/AGENTS.md` — repo-root project rules' "$TMP/runtime-agents/research-constraints.md" \
   && grep -q 'Any nested `AGENTS.md` files along the path of files mentioned in `issue_body`' "$TMP/runtime-agents/research-constraints.md"; then
  pass "generated research-constraints prompts read Codex/global instruction sources"
else
  fail "generated research-constraints prompts read Codex/global instruction sources"
fi
mkdir -p "$TMP/empty-runtime-agent-src" "$TMP/runtime-agent-preserve"
printf 'existing prompt\n' > "$TMP/runtime-agent-preserve/existing.md"
if bash "$PORT_AGENT_PROMPTS" "$TMP/empty-runtime-agent-src" "$TMP/runtime-agent-preserve" >/tmp/codex-empty-runtime-agents-out 2>&1; then
  fail "port-agent-prompts refuses empty source before touching destination"
else
  if [ -f "$TMP/runtime-agent-preserve/existing.md" ] \
     && grep -q 'no \*.md agents found' /tmp/codex-empty-runtime-agents-out; then
    pass "port-agent-prompts refuses empty source before touching destination"
  else
    fail "port-agent-prompts empty-source failure deleted or rewrote destination"
  fi
fi
mkdir -p "$TMP/unreadable-runtime-agent-src" "$TMP/unreadable-runtime-agent-preserve"
printf 'existing prompt\n' > "$TMP/unreadable-runtime-agent-preserve/existing.md"
chmod 000 "$TMP/unreadable-runtime-agent-src"
if bash "$PORT_AGENT_PROMPTS" "$TMP/unreadable-runtime-agent-src" "$TMP/unreadable-runtime-agent-preserve" >/tmp/codex-unreadable-runtime-agents-out 2>&1; then
  chmod 700 "$TMP/unreadable-runtime-agent-src"
  fail "port-agent-prompts reports unreadable source directories"
else
  _unreadable_rc=$?
  chmod 700 "$TMP/unreadable-runtime-agent-src"
  if [ "$_unreadable_rc" -eq 1 ] \
     && [ -f "$TMP/unreadable-runtime-agent-preserve/existing.md" ] \
     && grep -q 'unable to scan source agents dir' /tmp/codex-unreadable-runtime-agents-out \
     && grep -q "$TMP/unreadable-runtime-agent-src" /tmp/codex-unreadable-runtime-agents-out; then
    pass "port-agent-prompts reports unreadable source directories before touching destination"
  else
    fail "port-agent-prompts unreadable-source failure lacked diagnostic or touched destination" "$(cat /tmp/codex-unreadable-runtime-agents-out)"
  fi
fi

echo "== Command converter: 13 skills + 2 skipped =="
assert_cmd 0 "convert-commands runs clean" \
  python3 "$CONVERT_COMMANDS" "$REPO_ROOT/plugins/uberdev/commands" "$TMP/cmd-skills"
mkdir -p "$TMP/empty-commands-src"
assert_cmd 2 "convert-commands fails when source contains zero commands" \
  python3 "$CONVERT_COMMANDS" "$TMP/empty-commands-src" "$TMP/empty-commands-out"
N_CMD="$(find "$TMP/cmd-skills" -maxdepth 1 -name 'uberdev-cmd-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$N_CMD" -eq 13 ] && pass "13 uberdev-cmd-* skills produced" || fail "expected 13 cmd skills, got $N_CMD"
# install-aliases / uninstall-aliases NOT present (skipped)
[ ! -d "$TMP/cmd-skills/uberdev-cmd-install-aliases" ] && [ ! -d "$TMP/cmd-skills/uberdev-cmd-uninstall-aliases" ] \
  && pass "Claude-only alias commands skipped (not converted)" \
  || fail "alias commands were converted (should have been skipped)"
NG="$(grep -rlE 'CLAUDE_PLUGIN_ROOT|~/\.claude' "$TMP/cmd-skills" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "zero Claude-only path/env residuals in generated command-skills" \
  || fail "found $NG generated command-skills with Claude-only path/env residuals"
if grep -Rql 'wait_agent' "$TMP/cmd-skills"; then
  pass "command-skill bridge uses Codex wait_agent tool name"
else
  fail "command-skill bridge does not mention wait_agent"
fi
if grep -Rql 'subagent-driven-dev.*post-impl-review.*end-of-issue' "$TMP/cmd-skills" 2>/dev/null; then
  fail "generated command-skills do not describe retired pre-push post-impl-review flow"
else
  pass "generated command-skills do not describe retired pre-push post-impl-review flow"
fi
if grep -RqlE "$MODEL_RE|$DANGLING_WAIT_RE" "$TMP/cmd-skills" 2>/dev/null; then
  fail "generated command-skills do not preserve Claude-only model guidance or dangling WAIT fragments"
else
  pass "generated command-skills do not preserve Claude-only model guidance or dangling WAIT fragments"
fi
if grep -RqlF '${PLUGIN_ROOT:-${PLUGIN_ROOT:-' "$TMP/cmd-skills" 2>/dev/null; then
  fail "generated command-skills do not nest an already-fallback-capable PLUGIN_ROOT"
else
  pass "generated command-skills do not nest an already-fallback-capable PLUGIN_ROOT"
fi
COMMAND_ROOT_LINE="$(grep -m1 '^UBERDEV_REVIEW_PLUGIN_ROOT=' "$TMP/cmd-skills/uberdev-cmd-review-pr/SKILL.md" || true)"
COMMAND_CODEX_HOME="$TMP/command-root-home/.codex"
COMMAND_ROOT="$(
  env CODEX_HOME="$COMMAND_CODEX_HOME" ROOT_LINE="$COMMAND_ROOT_LINE" bash -u -c '
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT CURSOR_PLUGIN_ROOT
    eval "$ROOT_LINE"
    printf "%s" "$UBERDEV_REVIEW_PLUGIN_ROOT"
  '
)"
if [ "$COMMAND_ROOT" = "$COMMAND_CODEX_HOME/plugins/uberdev-codex" ]; then
  pass "converted command resolves runtime root from CODEX_HOME without PLUGIN_ROOT"
else
  fail "converted command CODEX_HOME fallback broken (got ${COMMAND_ROOT:-<empty>})"
fi

echo "== Skill-port: no CLAUDE_PLUGIN_ROOT residuals =="
assert_cmd 0 "port-skill runs clean" \
  bash "$PORT_SKILL" "$REPO_ROOT/plugins/uberdev/skills" "$TMP/skills"
if grep -RqlF '${PLUGIN_ROOT:-${PLUGIN_ROOT:-' "$TMP/skills" 2>/dev/null; then
  fail "ported skills do not nest an already-fallback-capable PLUGIN_ROOT"
else
  pass "ported skills do not nest an already-fallback-capable PLUGIN_ROOT"
fi
SKILL_ROOT_LINE="$(grep -m1 '^UBERDEV_BRAINSTORM_PLUGIN_ROOT=' "$TMP/skills/brainstorm/SKILL.md" || true)"
SKILL_CODEX_HOME="$TMP/skill-root-home/.codex"
SKILL_ROOT="$(
  env CODEX_HOME="$SKILL_CODEX_HOME" ROOT_LINE="$SKILL_ROOT_LINE" bash -u -c '
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT CURSOR_PLUGIN_ROOT
    eval "$ROOT_LINE"
    printf "%s" "$UBERDEV_BRAINSTORM_PLUGIN_ROOT"
  '
)"
if [ "$SKILL_ROOT" = "$SKILL_CODEX_HOME/plugins/uberdev-codex" ]; then
  pass "ported skill resolves runtime root from CODEX_HOME without PLUGIN_ROOT"
else
  fail "ported skill CODEX_HOME fallback broken (got ${SKILL_ROOT:-<empty>})"
fi
VISUAL_CODEX_HOME="$TMP/visual-root-home/.codex"
PORTED_VISUAL_LINES="$(grep -E '^(PLUGIN_SCRIPTS_ROOT|PLUGIN_SCRIPTS)=' "$TMP/skills/orchestrator/SKILL.md" || true)"
PORTED_VISUAL_SCRIPTS="$(
  env CODEX_HOME="$VISUAL_CODEX_HOME" VISUAL_LINES="$PORTED_VISUAL_LINES" bash -u -c '
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT CURSOR_PLUGIN_ROOT
    eval "$VISUAL_LINES"
    printf "%s" "$PLUGIN_SCRIPTS"
  '
)"
if [ "$PORTED_VISUAL_SCRIPTS" = "$VISUAL_CODEX_HOME/plugins/uberdev-codex/skills/brainstorm/scripts" ]; then
  pass "ported visual companion resolves installed scripts from CODEX_HOME without PLUGIN_ROOT"
else
  fail "ported visual companion CODEX_HOME fallback broken (got ${PORTED_VISUAL_SCRIPTS:-<empty>})"
fi

CANONICAL_ORCHESTRATOR="$REPO_ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
if grep -q 'host-provided plugin-root variables' "$CANONICAL_ORCHESTRATOR" \
   && ! grep -q 'with a `find` fallback' "$CANONICAL_ORCHESTRATOR"; then
  pass "canonical visual companion prose matches host-root-only resolution"
else
  fail "canonical visual companion prose still promises a removed find fallback"
fi
CANONICAL_VISUAL_BLOCK="$TMP/canonical-visual-companion.sh"
awk '
  /^PLUGIN_SCRIPTS_ROOT=/ { capture=1 }
  capture && /^```/ { exit }
  capture { print }
' "$CANONICAL_ORCHESTRATOR" > "$CANONICAL_VISUAL_BLOCK"
if [ ! -s "$CANONICAL_VISUAL_BLOCK" ]; then
  fail "canonical visual companion exposes an executable host-root resolution block"
elif env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u CURSOR_PLUGIN_ROOT \
       bash -u "$CANONICAL_VISUAL_BLOCK" \
       >"$TMP/canonical-visual.stdout" 2>"$TMP/canonical-visual.stderr" \
     && grep -qF 'plugin root unavailable (set PLUGIN_ROOT, CLAUDE_PLUGIN_ROOT, or CURSOR_PLUGIN_ROOT)' \
          "$TMP/canonical-visual.stderr"; then
  pass "canonical visual companion degrades with a provider-neutral missing-root diagnostic"
else
  fail "canonical visual companion missing-root path is silent or provider-specific"
fi
NG="$(grep -rl 'CLAUDE_PLUGIN_ROOT' "$TMP/skills" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "zero CLAUDE_PLUGIN_ROOT residuals in ported skills" \
  || fail "found $NG files still referencing CLAUDE_PLUGIN_ROOT"
NG="$(grep -rlE '(^|[^~])\$\{HOME\}/\.claude|\.claude/plugins' "$TMP/skills" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "ported skills have no HOME/.claude plugin-search residuals" \
  || fail "found $NG ported skills with HOME/.claude plugin-search residuals"
if [ ! -d "$TMP/skills/_shared" ]; then
  pass "ported plugin skill root does not expose _shared as a skill"
else
  fail "ported plugin skill root exposes _shared without SKILL.md"
fi
if [ -r "$TMP/shared/document-reviewer-template.md" ] \
   && ! grep -Rql '../_shared/document-reviewer-template.md' "$TMP/skills" 2>/dev/null; then
  pass "ported skills resolve shared templates from package-level shared directory"
else
  fail "ported skills do not resolve shared templates from package-level shared directory"
fi
if grep -q '.codex/uberdev.local.md' "$TMP/skills/using-uberdev/SKILL.md" \
   && grep -q '\$uberdev-cmd-\*' "$TMP/skills/using-uberdev/SKILL.md" \
   && ! grep -q 'SessionStart hook also auto-installs the short-form aliases' "$TMP/skills/using-uberdev/SKILL.md"; then
  pass "ported using-uberdev skill documents Codex config and command-skill behavior"
else
  fail "ported using-uberdev skill still documents Claude-only config or alias behavior"
fi
if grep -q '# Per-project configuration — `.codex/uberdev.local.md` / `.claude/uberdev.local.md`' "$TMP/skills/using-uberdev/references/configuration.md" \
   && grep -q 'Codex prefers optional config from `.codex/uberdev.local.md`' "$TMP/skills/using-uberdev/references/configuration.md" \
   && grep -q 'falls back to `.claude/uberdev.local.md`' "$TMP/skills/using-uberdev/references/configuration.md" \
   && ! grep -q 'Claude Code reads optional config from `.codex/uberdev.local.md`' "$TMP/skills/using-uberdev/references/configuration.md"; then
  pass "ported configuration reference preserves Codex primary + Claude fallback paths"
else
  fail "ported configuration reference rewrote both config paths to .codex"
fi
python3 - <<PY
from pathlib import Path
root = Path("$TMP/skills")
bad = []
for d in root.iterdir():
    if d.is_dir() and d.name != "_shared" and not (d / "SKILL.md").is_file():
        bad.append(f"{d.name}: missing SKILL.md")
for p in root.glob("*/SKILL.md"):
    text = p.read_text(encoding="utf-8")
    if not text.startswith("---\\n"):
        bad.append(f"{p}: missing frontmatter")
        continue
    fm = text.split("---", 2)[1]
    for line in fm.splitlines():
        if line.startswith("description: "):
            value = line[len("description: "):].strip()
            if ": " in value and not value.startswith(("'", '"')):
                bad.append(f"{p}: unquoted description with colon")
if bad:
    print("\\n".join(bad))
    raise SystemExit(1)
PY
[ $? -eq 0 ] && pass "ported plugin skills have validator-safe frontmatter and SKILL.md roots" \
  || fail "ported plugin skills have invalid frontmatter or exposed non-skill dirs"

echo "== Installer: idempotency + uninstall =="
# Codex doctor is a local schema probe; its overall exit can be nonzero because
# an isolated probe home intentionally has no credentials. This stub preserves
# that contract and lets installer failure paths be tested without Codex/auth.
CODEX_STUB="$TMP/codex-profile-probe"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'count="$(find "${CODEX_HOME:?}/agents" -maxdepth 1 -name '\''uberdev-*.toml'\'' 2>/dev/null | wc -l | tr -d '\''[:space:]'\'')"' \
  'if [ "${1:-}" != doctor ] || [ "${2:-}" != --json ] || [ "$count" -ne 44 ]; then exit 64; fi' \
  'if [ "${CODEX_PROFILE_PROBE_MODE:-ok}" = reject ]; then' \
  '  printf '\''%s\n'\'' '\''{"checks":{"config.load":{"details":{"startup warning":"Ignoring malformed agent role definition: /secret/profile/payload"}}}}'\''' \
  'else' \
  '  printf '\''%s\n'\'' '\''{"checks":{"config.load":{"details":{}}}}'\''' \
  'fi' \
  'exit 1' > "$CODEX_STUB"
chmod +x "$CODEX_STUB"
export CODEX_BIN="$CODEX_STUB"

TH_PROFILE_REJECT="$TMP/home-profile-reject"
mkdir -p "$TH_PROFILE_REJECT/.codex/agents"
printf 'existing-user-agent\n' > "$TH_PROFILE_REJECT/.codex/agents/uberdev-existing.toml"
if env HOME="$TH_PROFILE_REJECT" CODEX_HOME="$TH_PROFILE_REJECT/.codex" \
    CODEX_PROFILE_PROBE_MODE=reject bash "$INSTALLER" \
    >/tmp/codex-profile-reject-out 2>&1; then
  fail "installer rejects malformed staged profiles before live mutation"
elif grep -q 'existing-user-agent' "$TH_PROFILE_REJECT/.codex/agents/uberdev-existing.toml" \
  && [ ! -e "$TH_PROFILE_REJECT/.codex/plugins/uberdev-codex" ] \
  && [ ! -e "$TH_PROFILE_REJECT/.agents/skills" ] \
  && [ ! -e "$TH_PROFILE_REJECT/.codex/AGENTS.md" ] \
  && grep -q 'staged Codex agent profile validation failed' /tmp/codex-profile-reject-out \
  && ! grep -q '/secret/profile/payload' /tmp/codex-profile-reject-out; then
  pass "installer rejects malformed staged profiles before live mutation"
else
  fail "profile rejection mutated live state or leaked raw diagnostics"
fi

# Two consecutive installs into the same throwaway HOME, then verify no
# duplicate primer blocks. Then uninstall and verify cleanup.
TH="$TMP/home"
assert_cmd 0 "first install into throwaway HOME" \
  env HOME="$TH" CODEX_HOME="$TH/.codex" bash "$INSTALLER"
if [ -x "$TH/.codex/plugins/uberdev-codex/lib/solve-launcher.sh" ] \
  && [ -r "$TH/.codex/plugins/uberdev-codex/lib/dispatch.sh" ] \
  && [ -r "$TH/.codex/plugins/uberdev-codex/lib/command-workspace.py" ]; then
  pass "standalone installer installs stable runtime lib under CODEX_HOME"
else
  fail "standalone installer did not install stable runtime lib under CODEX_HOME"
fi
if grep -Rql '\${PLUGIN_ROOT:-\${CODEX_HOME:-\$HOME/\.codex}/plugins/uberdev-codex}/lib/solve-launcher\.sh' "$TH/.agents/skills/uberdev-cmd-solve" "$TH/.agents/skills/uberdev-cmd-turbo" 2>/dev/null; then
  pass "installed solve/turbo command skills can resolve runtime lib without PLUGIN_ROOT"
else
  fail "installed solve/turbo command skills still require plugin-host PLUGIN_ROOT"
fi
assert_cmd 0 "second install (idempotent)" \
  env HOME="$TH" CODEX_HOME="$TH/.codex" bash "$INSTALLER"
NB="$(grep -c 'BEGIN uberdev-codex-primer' "$TH/.codex/AGENTS.md" 2>/dev/null || echo 0)"
[ "$NB" -eq 1 ] && pass "exactly 1 primer block after 2 installs (idempotent)" \
  || fail "found $NB primer blocks (expected 1)"
NS="$(find "$TH/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$NS" -eq 39 ] && pass "installer copied 39 Codex-ported skills incl. command-skills" \
  || fail "installer copied $NS skills (expected 39)"
[ -f "$TH/.agents/skills/uberdev-cmd-solve/SKILL.md" ] \
  && pass "standalone installer includes command-skills" \
  || fail "standalone installer missing uberdev-cmd-solve"
NG="$(grep -rlE 'CLAUDE_PLUGIN_ROOT|~/\.claude' "$TH/.agents/skills" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "installed skills are Codex-path-safe" \
  || fail "installed skills contain $NG Claude-only path/env residuals"
NG="$(grep -rlE "${CODEX_PATH_RE}|${BARE_ROOT_RE}|${MODEL_RE}" "$TH/.codex/plugins/uberdev-codex/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "installed runtime Markdown prompts are Codex-path-safe" \
  || fail "installed runtime Markdown prompts contain $NG Claude-only residual files"
if grep -Rql '~/\.codex/commands' "$TH/.agents/skills" 2>/dev/null; then
  fail "installed Codex skills claim slash aliases are installed into ~/.codex/commands"
else
  pass "installed Codex skills do not advertise a nonexistent ~/.codex/commands alias path"
fi
mkdir -p "$TH/.agents/skills/obsolete-managed" "$TH/.codex/agents"
printf 'managed-by=uberdev-codex\n' > "$TH/.agents/skills/obsolete-managed/.uberdev-codex-managed"
printf 'stale agent\n' > "$TH/.codex/agents/uberdev-obsolete.toml"
assert_cmd 0 "upgrade install removes stale managed skills and agents" \
  env HOME="$TH" CODEX_HOME="$TH/.codex" bash "$INSTALLER"
if [ ! -e "$TH/.agents/skills/obsolete-managed" ] \
  && [ ! -e "$TH/.codex/agents/uberdev-obsolete.toml" ]; then
  pass "upgrade install removes stale managed skills and agents"
else
  fail "upgrade install left stale managed artifacts"
fi
assert_cmd 0 "uninstall runs clean" \
  env HOME="$TH" CODEX_HOME="$TH/.codex" bash "$INSTALLER" --uninstall
NS="$(find "$TH/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
# find (not ls) so a no-match glob yields a clean 0 instead of the literal glob.
NA="$(find "$TH/.codex/agents" -maxdepth 1 -name 'uberdev-*.toml' 2>/dev/null | wc -l | tr -d '[:space:]')"
NP="$(grep -c 'uberdev-codex-primer' "$TH/.codex/AGENTS.md" 2>/dev/null | tr -d '[:space:]'; true)"
NR="$(find "$TH/.codex/plugins/uberdev-codex" -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$NS" -eq 0 ] && [ "$NA" -eq 0 ] && [ "$NP" -eq 0 ] && [ "$NR" -eq 0 ] \
  && pass "uninstall removes all skills, agents, runtime files, and the primer block" \
  || fail "uninstall left residue: skills=$NS agents=$NA primer=$NP runtime=$NR"

TH_LEGACY="$TMP/home-legacy-skills"
mkdir -p "$TH_LEGACY/.agents/skills" "$TH_LEGACY/.codex"
rsync -a --delete \
  --exclude '.uberdev-codex-managed' \
  "$REPO_ROOT/codex/uberdev-codex/skills/" "$TH_LEGACY/.agents/skills/"
find "$TH_LEGACY/.agents/skills" -name '.uberdev-codex-managed' -delete
assert_cmd 0 "installer adopts full legacy unmarked UberDev skill set" \
  env HOME="$TH_LEGACY" CODEX_HOME="$TH_LEGACY/.codex" bash "$INSTALLER"
NS="$(find "$TH_LEGACY/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
NM="$(find "$TH_LEGACY/.agents/skills" -maxdepth 2 -name '.uberdev-codex-managed' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "$NS" -eq 39 ] \
  && [ "$NM" -eq 39 ] \
  && [ -x "$TH_LEGACY/.codex/plugins/uberdev-codex/lib/solve-launcher.sh" ] \
  && [ -r "$TH_LEGACY/.codex/plugins/uberdev-codex/lib/command-workspace.py" ] \
  && grep -Rql '\.codex/uberdev.local.md' "$TH_LEGACY/.agents/skills/uberdev-cmd-solve/SKILL.md"; then
  pass "legacy unmarked skill adoption upgrades skills, markers, and runtime"
else
  fail "legacy unmarked skill adoption incomplete: skills=$NS markers=$NM"
fi

TH_LEGACY_BAD="$TMP/home-legacy-skills-bad-frontmatter"
mkdir -p "$TH_LEGACY_BAD/.agents/skills" "$TH_LEGACY_BAD/.codex"
rsync -a --delete \
  --exclude '.uberdev-codex-managed' \
  "$REPO_ROOT/codex/uberdev-codex/skills/" "$TH_LEGACY_BAD/.agents/skills/"
find "$TH_LEGACY_BAD/.agents/skills" -name '.uberdev-codex-managed' -delete
: > "$TH_LEGACY_BAD/.agents/skills/brainstorm/SKILL.md"
if env HOME="$TH_LEGACY_BAD" CODEX_HOME="$TH_LEGACY_BAD/.codex" bash "$INSTALLER" >/tmp/codex-legacy-bad-out 2>&1; then
  fail "installer refuses full legacy-looking skill set with malformed frontmatter"
else
  if [ ! -s "$TH_LEGACY_BAD/.agents/skills/brainstorm/SKILL.md" ] \
     && grep -qi 'collision' /tmp/codex-legacy-bad-out \
     && [ ! -e "$TH_LEGACY_BAD/.codex/plugins/uberdev-codex" ] \
     && [ ! -d "$TH_LEGACY_BAD/.codex/agents" ] \
     && ! grep -q 'BEGIN uberdev-codex-primer' "$TH_LEGACY_BAD/.codex/AGENTS.md" 2>/dev/null; then
    pass "installer refuses full legacy-looking skill set with malformed frontmatter"
  else
    fail "malformed legacy-looking refusal did not preserve files or avoid partial install"
  fi
fi

TH_COLLIDE="$TMP/home-collide"
mkdir -p "$TH_COLLIDE/.agents/skills/brainstorm" "$TH_COLLIDE/.codex"
printf 'user-owned skill\n' > "$TH_COLLIDE/.agents/skills/brainstorm/SKILL.md"
if env HOME="$TH_COLLIDE" CODEX_HOME="$TH_COLLIDE/.codex" bash "$INSTALLER" >/tmp/codex-collide-out 2>&1; then
  fail "installer refuses to overwrite pre-existing user-owned skill directories"
else
  if grep -q 'user-owned skill' "$TH_COLLIDE/.agents/skills/brainstorm/SKILL.md" \
     && grep -qi 'collision' /tmp/codex-collide-out \
     && [ ! -e "$TH_COLLIDE/.codex/plugins/uberdev-codex" ] \
     && [ ! -d "$TH_COLLIDE/.codex/agents" ] \
     && ! grep -q 'BEGIN uberdev-codex-primer' "$TH_COLLIDE/.codex/AGENTS.md" 2>/dev/null; then
    pass "installer refuses to overwrite pre-existing user-owned skill directories"
  else
    fail "installer collision refusal preserves user-owned skill, names collision, and leaves no partial install"
  fi
fi

TH_ZERO="$TMP/home-zero-agents"
ZERO_SRC="$TMP/zero-agent-source"
ZERO_CONVERTER="$TMP/zero-agent-converter.sh"
mkdir -p "$TH_ZERO/.codex/agents" "$ZERO_SRC/agents"
printf 'existing agent\n' > "$TH_ZERO/.codex/agents/uberdev-existing.toml"
cat > "$ZERO_CONVERTER" <<'SH'
import os
import sys

os.makedirs(sys.argv[2], exist_ok=True)
SH
chmod +x "$ZERO_CONVERTER"
if env HOME="$TH_ZERO" CODEX_HOME="$TH_ZERO/.codex" UBERDEV_SRC="$ZERO_SRC" CONVERTER="$ZERO_CONVERTER" bash "$INSTALLER" >/tmp/codex-zero-agents-out 2>&1; then
  fail "installer refuses zero-agent converter output before replacing existing agents"
else
  if [ -f "$TH_ZERO/.codex/agents/uberdev-existing.toml" ] \
     && grep -qi 'zero agents' /tmp/codex-zero-agents-out; then
    pass "installer refuses zero-agent converter output before replacing existing agents"
  else
    fail "installer zero-agent refusal did not preserve existing agents or name the failure"
  fi
fi

TH2="$TMP/home-override"
mkdir -p "$TH2/.codex"
printf '# temporary override\n' > "$TH2/.codex/AGENTS.override.md"
assert_cmd 0 "install merges primer into AGENTS.override.md when present" \
  env HOME="$TH2" CODEX_HOME="$TH2/.codex" bash "$INSTALLER"
if grep -q 'BEGIN uberdev-codex-primer' "$TH2/.codex/AGENTS.override.md"; then
  pass "primer installed into AGENTS.override.md"
else
  fail "primer missing from AGENTS.override.md"
fi

BOOT_SRC="$TMP/bootstrap-src/UberDev-main"
mkdir -p "$BOOT_SRC/codex" "$BOOT_SRC/plugins"
rsync -a --exclude '.git/' "$REPO_ROOT/codex/" "$BOOT_SRC/codex/"
rsync -a --exclude '.git/' "$REPO_ROOT/plugins/uberdev/" "$BOOT_SRC/plugins/uberdev/"
BOOT_TARBALL="$TMP/uberdev-bootstrap.tar.gz"
tar -czf "$BOOT_TARBALL" -C "$TMP/bootstrap-src" UberDev-main
STANDALONE="$TMP/standalone/install-codex.sh"
mkdir -p "$(dirname "$STANDALONE")"
cp "$INSTALLER" "$STANDALONE"
TH3="$TMP/home-bootstrap"
assert_cmd 0 "standalone copied installer bootstraps missing repo sources from archive" \
  env HOME="$TH3" CODEX_HOME="$TH3/.codex" UBERDEV_BOOTSTRAP_TARBALL="$BOOT_TARBALL" bash "$STANDALONE"
NS="$(find "$TH3/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
NA="$(find "$TH3/.codex/agents" -maxdepth 1 -name 'uberdev-*.toml' 2>/dev/null | wc -l | tr -d '[:space:]')"
NB="$(grep -c 'BEGIN uberdev-codex-primer' "$TH3/.codex/AGENTS.md" 2>/dev/null || echo 0)"
[ "$NS" -eq 39 ] && [ "$NA" -eq 44 ] && [ "$NB" -eq 1 ] \
  && [ -r "$TH3/.codex/plugins/uberdev-codex/lib/command-workspace.py" ] \
  && pass "bootstrapped standalone install carries skills, agents, and primer" \
  || fail "bootstrapped install incomplete: skills=$NS agents=$NA primer=$NB"

TH4="$TMP/home-symlink"
CLAUDE_HOME="$TMP/claude-home"
mkdir -p "$TH4/.codex" "$CLAUDE_HOME"
printf '# Claude global\n\nClaude-only guidance stays untouched.\n' > "$CLAUDE_HOME/CLAUDE.md"
ln -s "$CLAUDE_HOME/CLAUDE.md" "$TH4/.codex/AGENTS.md"
assert_cmd 0 "install converts symlinked AGENTS.md into a Codex-owned regular file" \
  env HOME="$TH4" CODEX_HOME="$TH4/.codex" bash "$INSTALLER"
if [ ! -L "$TH4/.codex/AGENTS.md" ] \
  && grep -q 'BEGIN uberdev-codex-primer' "$TH4/.codex/AGENTS.md" \
  && ! grep -q 'BEGIN uberdev-codex-primer' "$CLAUDE_HOME/CLAUDE.md" \
  && find "$TH4/.codex" -maxdepth 1 -name 'AGENTS.md.symlink-*.bak' -type l | grep -q .; then
  pass "symlink conversion preserves Claude target and backs up the old link"
else
  fail "symlink conversion did not isolate Codex AGENTS.md from Claude target"
fi

TH5="$TMP/home-skills-symlink"
CLAUDE_SKILLS="$TMP/claude-skills-target"
mkdir -p "$TH5/.agents" "$TH5/.codex" "$CLAUDE_SKILLS/legacy-skill"
printf 'legacy\n' > "$CLAUDE_SKILLS/legacy-skill/SKILL.md"
ln -s "$CLAUDE_SKILLS" "$TH5/.agents/skills"
assert_cmd 0 "install converts symlinked ~/.agents/skills into a Codex-owned directory" \
  env HOME="$TH5" CODEX_HOME="$TH5/.codex" bash "$INSTALLER"
NS="$(find "$TH5/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ ! -L "$TH5/.agents/skills" ] \
  && [ "$NS" -eq 39 ] \
  && [ ! -e "$CLAUDE_SKILLS/uberdev-cmd-solve" ] \
  && [ -f "$CLAUDE_SKILLS/legacy-skill/SKILL.md" ] \
  && find "$TH5/.agents" -maxdepth 1 -name 'skills.symlink-*.bak' -type l | grep -q .; then
  pass "skills symlink conversion preserves Claude target and installs Codex skills separately"
else
  fail "skills symlink conversion did not isolate Codex skills from Claude target"
fi

TH6="$TMP/home-offline-uninstall"
STANDALONE_UNINSTALL="$TMP/offline/install-codex.sh"
mkdir -p "$(dirname "$STANDALONE_UNINSTALL")" \
  "$TH6/.agents/skills/obsolete-managed" \
  "$TH6/.codex/agents" \
  "$TH6/.codex/plugins/uberdev-codex/lib"
cp "$INSTALLER" "$STANDALONE_UNINSTALL"
printf 'managed-by=uberdev-codex\n' > "$TH6/.agents/skills/obsolete-managed/.uberdev-codex-managed"
printf 'stale agent\n' > "$TH6/.codex/agents/uberdev-obsolete.toml"
printf 'runtime\n' > "$TH6/.codex/plugins/uberdev-codex/lib/stale"
cat > "$TH6/.codex/AGENTS.md" <<'EOF_PRIMER'
before
<!-- BEGIN uberdev-codex-primer (managed by install-codex.sh) -->
managed primer
<!-- END uberdev-codex-primer -->
after
EOF_PRIMER
if (cd "$TMP" && env HOME="$TH6" CODEX_HOME="$TH6/.codex" UBERDEV_BOOTSTRAP_TARBALL="$TMP/missing-bootstrap.tar.gz" bash "$STANDALONE_UNINSTALL" --uninstall) >/tmp/codex-offline-uninstall-out 2>&1; then
  NS="$(find "$TH6/.agents/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
  NA="$(find "$TH6/.codex/agents" -maxdepth 1 -name 'uberdev-*.toml' 2>/dev/null | wc -l | tr -d '[:space:]')"
  NP="$(grep -c 'uberdev-codex-primer' "$TH6/.codex/AGENTS.md" 2>/dev/null | tr -d '[:space:]'; true)"
  NR="$(find "$TH6/.codex/plugins/uberdev-codex" -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$NS" -eq 0 ] && [ "$NA" -eq 0 ] && [ "$NP" -eq 0 ] && [ "$NR" -eq 0 ] \
    && pass "standalone uninstall works offline without bootstrapping repo sources" \
    || fail "offline uninstall left residue: skills=$NS agents=$NA primer=$NP runtime=$NR"
else
  fail "standalone uninstall works offline without bootstrapping repo sources"
fi

echo "== Plugin manifest + marketplace JSON validity =="
python3 - <<PY
import json, os, sys
from pathlib import Path
m = json.load(open("$MANIFEST"))
ok = True
for k in ("name", "version", "description", "skills"):
    if k not in m: print(f"  FAIL  manifest missing key: {k}"); ok = False
if "agents" in m: print("  FAIL  manifest has agents field (must NOT — undocumented)"); ok = False
if "hooks" in m: print("  FAIL  manifest has hooks field (must NOT — validator rejects it)"); ok = False
iface = m.get("interface")
if not isinstance(iface, dict):
    print("  FAIL  manifest interface is missing or not an object"); ok = False
else:
    required = ("displayName", "shortDescription", "longDescription", "developerName", "category", "capabilities")
    for k in required:
        if not iface.get(k):
            print(f"  FAIL  manifest interface missing key: {k}"); ok = False
mp = json.load(open("$MARKETPLACE"))
p = mp["plugins"][0]
if not os.path.isfile("codex/uberdev-codex/.codex-plugin/plugin.json"): ok = False
if p["source"]["path"] != "./codex/uberdev-codex": print("  FAIL  marketplace source.path wrong"); ok = False
skills = Path("$REPO_ROOT/codex/uberdev-codex") / m["skills"]
for d in skills.iterdir():
    if d.is_dir() and not (d / "SKILL.md").is_file():
        print(f"  FAIL  manifest-exposed skills dir lacks SKILL.md: {d.name}"); ok = False
for skill in skills.glob("*/SKILL.md"):
    text = skill.read_text(encoding="utf-8")
    if not text.startswith("---\\n"):
        print(f"  FAIL  {skill} missing frontmatter"); ok = False
        continue
    fm = text.split("---", 2)[1]
    for line in fm.splitlines():
        if line.startswith("description: "):
            value = line[len("description: "):].strip()
            if ": " in value and not value.startswith(("'", '"')):
                print(f"  FAIL  {skill} has validator-unsafe description frontmatter"); ok = False
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && pass "manifest valid and exposed skill package is validator-safe" \
  || fail "manifest or marketplace invalid"
if [ -r "$REPO_ROOT/codex/uberdev-codex/lib/dispatch.sh" ] \
  && [ -r "$REPO_ROOT/codex/uberdev-codex/lib/solve-launcher.sh" ] \
  && [ -r "$REPO_ROOT/codex/uberdev-codex/lib/command-workspace.py" ] \
  && [ -x "$REPO_ROOT/codex/uberdev-codex/hooks/session-start" ] \
  && grep -q '\${PLUGIN_ROOT}/hooks/session-start' "$REPO_ROOT/codex/uberdev-codex/hooks/hooks.json"; then
  pass "plugin package carries runtime lib and plugin-local hook command"
else
  fail "plugin package missing runtime lib or plugin-local hook command"
fi

echo "== Checked-in Codex artifacts =="
NG="$(grep -rlE "$CODEX_PATH_RE" "$REPO_ROOT/codex/agents" "$REPO_ROOT/codex/uberdev-codex/skills" "$REPO_ROOT/codex/uberdev-codex/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "checked-in Codex artifacts have no Claude env/path or fake Codex alias residuals" \
  || fail "checked-in Codex artifacts contain $NG stale Claude/Codex-alias residual files"
NG="$(grep -rlE "$BARE_ROOT_RE" "$REPO_ROOT/codex/agents" "$REPO_ROOT/codex/uberdev-codex/skills" "$REPO_ROOT/codex/uberdev-codex/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "checked-in Codex artifacts avoid bare PLUGIN_ROOT and HOME/.claude plugin paths" \
  || fail "checked-in Codex artifacts contain $NG bare plugin-root or HOME/.claude plugin path residual files"
NG="$(grep -rlE "$MODEL_RE" "$REPO_ROOT/codex/agents" "$REPO_ROOT/codex/uberdev-codex/skills" "$REPO_ROOT/codex/uberdev-codex/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "checked-in Codex artifacts have no Claude-only model guidance" \
  || fail "checked-in Codex artifacts contain $NG Claude-only model guidance files"
NG="$(grep -rlE "$DANGLING_WAIT_RE" "$REPO_ROOT/codex/agents" "$REPO_ROOT/codex/uberdev-codex/skills" "$REPO_ROOT/codex/uberdev-codex/agents" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NG" -eq 0 ] && pass "checked-in Codex artifacts have no dangling WAIT-marker fragments" \
  || fail "checked-in Codex artifacts contain $NG dangling WAIT-marker fragment files"
if grep -q '`merge_strategy:` key in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`)' "$REPO_ROOT/codex/agents/uberdev-merge-strategy-decider.toml" \
   && grep -q '`merge_strategy:` key in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`)' "$REPO_ROOT/codex/uberdev-codex/agents/merge-strategy-decider.md"; then
  pass "checked-in merge-strategy prompts document Codex config primary and Claude fallback"
else
  fail "checked-in merge-strategy prompts document Codex config primary and Claude fallback"
fi
if grep -q 'Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md' "$REPO_ROOT/codex/agents/uberdev-research-constraints.toml" \
   && grep -q 'from AGENTS.md/CLAUDE.md, RFCs, and ADRs' "$REPO_ROOT/codex/agents/uberdev-research-constraints.toml" \
   && grep -q '<working_dir>/AGENTS.md` — repo-root project rules' "$REPO_ROOT/codex/agents/uberdev-research-constraints.toml" \
   && grep -q 'Any nested `AGENTS.md` files along the path of files mentioned in `issue_body`' "$REPO_ROOT/codex/agents/uberdev-research-constraints.toml" \
   && grep -q 'Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md' "$REPO_ROOT/codex/uberdev-codex/agents/research-constraints.md" \
   && grep -q 'from AGENTS.md/CLAUDE.md, RFCs, and ADRs' "$REPO_ROOT/codex/uberdev-codex/agents/research-constraints.md" \
   && grep -q '<working_dir>/AGENTS.md` — repo-root project rules' "$REPO_ROOT/codex/uberdev-codex/agents/research-constraints.md" \
   && grep -q 'Any nested `AGENTS.md` files along the path of files mentioned in `issue_body`' "$REPO_ROOT/codex/uberdev-codex/agents/research-constraints.md"; then
  pass "checked-in research-constraints prompts read Codex/global instruction sources"
else
  fail "checked-in research-constraints prompts read Codex/global instruction sources"
fi

echo "== Primer/tool mapping freshness =="
if grep -q 'wait_agent' "$REPO_ROOT/codex/AGENTS.md" \
  && grep -q 'wait_agent' "$REPO_ROOT/codex/uberdev-codex/skills/using-uberdev/references/codex-tools.md"; then
  pass "primer + codex tool mapping use wait_agent"
else
  fail "primer/tool mapping missing wait_agent"
fi
if grep -q 'multi_agent = true' "$REPO_ROOT/codex/AGENTS.md" \
  || grep -q 'multi_agent = true' "$REPO_ROOT/codex/uberdev-codex/skills/using-uberdev/references/codex-tools.md"; then
  fail "primer/tool mapping still tells users to set stale multi_agent flag"
else
  pass "primer/tool mapping do not require stale multi_agent feature flag"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
