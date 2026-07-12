#!/usr/bin/env bash
# tools/prkit/verify.sh — prkit generation verify gate (RFC 0014 §5.6 + Codex addendum).
#   verify.sh <target-repo-root>
# Exit 0 iff the generated tree is correct. Prints each check. Covers the Claude
# plugin (plugins/prkit, always) and the Codex port (codex/, when generated).
set -u
set -o pipefail

ROOT="${1:-}"
[ -n "$ROOT" ] && [ -d "$ROOT/plugins/prkit" ] || { echo "verify: no plugins/prkit under '$ROOT'"; exit 2; }
P="$ROOT/plugins/prkit"
# Scan roots: the Claude plugin (always) + the Codex port (if generated). Array
# form keeps this space-safe for target paths like "/Volumes/FJK SSD/...".
SCAN=("$P")
[ -d "$ROOT/codex" ] && SCAN+=("$ROOT/codex")
rc=0
fail(){ echo "  FAIL  $1"; rc=1; }
ok(){ echo "  OK    $1"; }
echo "## prkit verify <$ROOT>"

# --- 1. Token guard: no uberdev anywhere in the shipped trees (root NOTICE/LICENSE,
# which legitimately attribute UberDev, are outside these scan roots). ---
tok=$(grep -rilE 'uberdev' "${SCAN[@]}" 2>/dev/null || true)
if [ -n "$tok" ]; then fail "token-guard: uberdev survives in:"; echo "$tok" | sed 's/^/         /'
else ok "token-guard: no uberdev token (plugins/prkit${SCAN[1]:+ + codex})"; fi

# --- 2. Residual out-of-set command refs (prkit:goal / prkit:solve) ---
oos=$(grep -rEl '(^|[^a-z])prkit:(goal|solve)|/prkit:(goal|solve)' "${SCAN[@]}" 2>/dev/null || true)
if [ -n "$oos" ]; then fail "out-of-set: prkit:goal/solve survives in: $oos"
else ok "out-of-set: no prkit:goal/solve reference"; fi

# --- 3. Referential integrity: every dispatched prkit:X agent has agents/X.md
# (Claude tree only — Codex dispatch uses a different agent_type shape) ---
grep -rhoE 'subagent_type[:=][[:space:]]*prkit:[a-z0-9-]+' "$P" 2>/dev/null \
  | sed -E 's/.*prkit://' | sort -u | while read -r a; do
    [ -f "$P/agents/$a.md" ] || echo "missing-agent:$a"
  done > /tmp/prkit-missing-agents.$$ 2>/dev/null || true
if [ -s /tmp/prkit-missing-agents.$$ ]; then fail "ref-int: agents missing:"; sed 's/^/         /' /tmp/prkit-missing-agents.$$
else ok "ref-int: all dispatched agents exist"; fi
rm -f /tmp/prkit-missing-agents.$$

# --- 4. Referential integrity: every Skill(prkit:X) has skills/X/SKILL.md ---
grep -rhoE 'Skill\(prkit:[a-z0-9-]+' "$P" 2>/dev/null \
  | sed -E 's/.*prkit://' | sort -u | while read -r s; do
    [ -f "$P/skills/$s/SKILL.md" ] || echo "missing-skill:$s"
  done > /tmp/prkit-missing-skills.$$ 2>/dev/null || true
if [ -s /tmp/prkit-missing-skills.$$ ]; then fail "ref-int: skills missing:"; sed 's/^/         /' /tmp/prkit-missing-skills.$$
else ok "ref-int: all invoked skills exist"; fi
rm -f /tmp/prkit-missing-skills.$$

# --- 5. Syntax: shell / python / json / toml (space-safe: NUL-delimited find +
# process substitution; loop stays in the current shell so *err flags persist) ---
serr=0
while IFS= read -r -d '' f; do bash -n "$f" 2>/dev/null || { echo "         bash -n failed: $f"; serr=1; }; done < <(find "${SCAN[@]}" -name '*.sh' -print0 2>/dev/null)
[ "$serr" -eq 0 ] && ok "syntax: bash -n clean" || fail "syntax: shell errors"
perr=0
# ast.parse validates syntax WITHOUT emitting __pycache__/*.pyc — py_compile would
# pollute the generated tree with non-deterministic bytecode (breaks determinism +
# ships build artifacts). ast.parse is artifact-free and deterministic.
while IFS= read -r -d '' f; do python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" 2>/dev/null || { echo "         py syntax failed: $f"; perr=1; }; done < <(find "${SCAN[@]}" -name '*.py' -print0 2>/dev/null)
[ "$perr" -eq 0 ] && ok "syntax: python parse clean" || fail "syntax: python errors"
jerr=0
while IFS= read -r -d '' f; do jq empty "$f" 2>/dev/null || { echo "         jq failed: $f"; jerr=1; }; done < <(find "${SCAN[@]}" -name '*.json' -print0 2>/dev/null)
[ "$jerr" -eq 0 ] && ok "syntax: jq clean" || fail "syntax: json errors"
# TOML (Codex agents) — only when tomllib is available (py>=3.11); skip gracefully otherwise.
if [ -d "$ROOT/codex" ]; then
  if python3 -c 'import tomllib' 2>/dev/null; then
    terr=0
    while IFS= read -r -d '' f; do python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null || { echo "         toml parse failed: $f"; terr=1; }; done < <(find "$ROOT/codex" -name '*.toml' -print0 2>/dev/null)
    [ "$terr" -eq 0 ] && ok "syntax: toml parse clean" || fail "syntax: toml errors"
  else
    ok "syntax: toml check skipped (no tomllib)"
  fi
fi

# --- 6. Required tree shape ---
for req in "commands/review-pr.md" "commands/simplify.md" "commands/merge.md" \
           "skills/post-impl-review/SKILL.md" "skills/merge-pipeline/SKILL.md" \
           "policy/model-routing-v1.json" ".claude-plugin/plugin.json"; do
  [ -e "$P/$req" ] || { fail "shape: missing $req"; }
done
ok "shape: claude required-file presence checked"
if [ -d "$ROOT/codex" ]; then
  for req in "codex/prkit-codex/.codex-plugin/plugin.json" \
             "codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" \
             "codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" \
             "codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" \
             "codex/install-codex.sh" "codex/README.md" "codex/AGENTS.md"; do
    [ -e "$ROOT/$req" ] || fail "shape: missing $req"
  done
  ok "shape: codex required-file presence checked"
fi

echo "  Result: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
