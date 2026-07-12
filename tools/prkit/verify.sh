#!/usr/bin/env bash
# tools/prkit/verify.sh — prkit generation verify gate (RFC 0014 §5.6).
#   verify.sh <target-repo-root>
# Exit 0 iff the generated tree is correct. Prints each check.
set -u
set -o pipefail

ROOT="${1:-}"
[ -n "$ROOT" ] && [ -d "$ROOT/plugins/prkit" ] || { echo "verify: no plugins/prkit under '$ROOT'"; exit 2; }
P="$ROOT/plugins/prkit"
rc=0
fail(){ echo "  FAIL  $1"; rc=1; }
ok(){ echo "  OK    $1"; }
echo "## prkit verify <$ROOT>"

# --- 1. Token guard: no uberdev under plugins/prkit (allowlist: NOTICE/LICENSE at root) ---
tok=$(grep -rilE 'uberdev' "$P" 2>/dev/null || true)
if [ -n "$tok" ]; then fail "token-guard: uberdev survives in:"; echo "$tok" | sed 's/^/         /'
else ok "token-guard: no uberdev under plugins/prkit"; fi

# --- 2. Residual out-of-set command refs (prkit:goal / prkit:solve) ---
oos=$(grep -rEl '(^|[^a-z])prkit:(goal|solve)|/prkit:(goal|solve)' "$P" 2>/dev/null || true)
if [ -n "$oos" ]; then fail "out-of-set: prkit:goal/solve survives in: $oos"
else ok "out-of-set: no prkit:goal/solve reference"; fi

# --- 3. Referential integrity: every dispatched prkit:X agent has agents/X.md ---
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

# --- 5. Syntax: shell / python / json ---
serr=0
for f in $(find "$P" -name '*.sh' 2>/dev/null); do bash -n "$f" 2>/dev/null || { echo "         bash -n failed: $f"; serr=1; }; done
[ "$serr" -eq 0 ] && ok "syntax: bash -n clean" || fail "syntax: shell errors"
perr=0
for f in $(find "$P" -name '*.py' 2>/dev/null); do python3 -m py_compile "$f" 2>/dev/null || { echo "         py_compile failed: $f"; perr=1; }; done
[ "$perr" -eq 0 ] && ok "syntax: py_compile clean" || fail "syntax: python errors"
jerr=0
for f in $(find "$P" -name '*.json' 2>/dev/null); do jq empty "$f" 2>/dev/null || { echo "         jq failed: $f"; jerr=1; }; done
[ "$jerr" -eq 0 ] && ok "syntax: jq clean" || fail "syntax: json errors"

# --- 6. Required tree shape ---
for req in "commands/review-pr.md" "commands/simplify.md" "commands/merge.md" \
           "skills/post-impl-review/SKILL.md" "skills/merge-pipeline/SKILL.md" \
           "policy/model-routing-v1.json" ".claude-plugin/plugin.json"; do
  [ -e "$P/$req" ] || { fail "shape: missing $req"; }
done
ok "shape: required-file presence checked"

echo "  Result: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
