#!/usr/bin/env bash
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/uberscan.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/uberscan-pipeline/SKILL.md"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

echo "== U1: command file structure =="
ck "command file exists" "[ -r '$CMD' ]"
ck "has description frontmatter" "grep -q '^description:' '$CMD'"
ck "has argument-hint" "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools" "grep -q '^allowed-tools:' '$CMD'"

echo "== U2: READ-ONLY invariant (no Edit/MultiEdit in allowed-tools) =="
ck "allowed-tools omits Edit/MultiEdit" "[ \$(grep '^allowed-tools:' '$CMD' | grep -cE '\"Edit\"|MultiEdit') -eq 0 ]"

echo "== U3: pipeline skill =="
ck "skill exists" "[ -r '$SKILL' ]"
ck "skill name is uberscan-pipeline" "grep -q '^name: uberscan-pipeline' '$SKILL'"
ck "skill references chunk.py"  "grep -q 'chunk.py' '$SKILL'"
ck "skill references report.py" "grep -q 'report.py' '$SKILL'"
ck "skill excludes code-simplifier" "[ \$(grep -c 'code-simplifier' '$SKILL') -eq 0 ]"

echo "== U4: alias registration + drift =="
ck "alias row present" "grep -q '^uberscan|uberscan|' '$SYNC'"
# Normalize the shell-string delimiter quote: when the uberscan row is the last line of
# the ALIASES='...' assignment, the closing ' lands on that line (the runtime variable
# value has no quote). Strip single quotes from both sides before the byte-compare.
ALIAS_TOOLS="$(grep '^uberscan|uberscan|' "$SYNC" | cut -d'|' -f3 | tr -d "'")"
CMD_TOOLS="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //' | tr -d "'")"
ck "alias tools byte-match command allowed-tools" "[ \"\$ALIAS_TOOLS\" = \"\$CMD_TOOLS\" ]"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
