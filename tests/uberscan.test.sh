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

echo "== U5: Phase 4 reads totals.json sidecar (Item 7 / AC7) =="
# The old path grep-parsed the rendered markdown report or used a python3 -c
# recount inside Phase 4. T6 replaced that with a single jq @tsv read from the
# totals.json sidecar emitted by report.py --emit-totals-json.
ck "Phase 4 reads totals.json via jq" "grep -qE 'jq -r .*severities.*@tsv|jq -r .*\.severities\.' '$SKILL'"
ck "totals.json sidecar referenced" "grep -q 'totals.json' '$SKILL'"
ck "old _uberscan_sev_total grep-the-report path removed" "[ \$(grep -c '_uberscan_sev_total' '$SKILL') -eq 0 ]"
# Sentinel: the old recount used 'python3 -c "... sev ..."' — that active-code
# pattern is now absent. The only surviving python3 -c in SKILL.md is a commented
# orchestrator hint (lines 304-309) that does NOT start with python3 -c at the
# top level; grep -cE 'python3 -c.*sev' returns 0 because the comment line uses
# 'severity' not 'sev' and is in a #-prefixed comment block that our pattern
# doesn't match anyway. Using 'python3 -c.*sev' (abbreviated) is safe: it matches
# the old active severity-counting call form and is genuinely absent now.
ck "no active python3-recount for severities in Phase 4" "! grep -qE 'python3 -c.*sev' '$SKILL'"

echo "== U6: Phase 0/1 jq + sourcing consolidation (Item 8 / AC8) =="
# T6 collapsed the three separate jq calls (.overflow, .total_chunks, .chunks|length)
# into one @tsv read. The old standalone '.overflow' reads used the form:
#   jq -r '.overflow' (with a trailing space before the file arg)
# That form is now absent; the single consolidated read has the form:
#   jq -r '[.overflow, .total_chunks, (.chunks|length)] | @tsv'
ck "manifest scalars read in one @tsv read" "grep -qE 'jq -r .*\[\.overflow, \.total_chunks.*@tsv' '$SKILL'"
# Sentinel for "no standalone .overflow": old isolated reads used  jq -r '.overflow' <file>
# (single-quoted .overflow with trailing space). Count must be 0 now.
ck "no standalone .overflow scalar jq read remains" "[ \$(grep -cE \"jq -r '\.overflow' \" '$SKILL') -eq 0 ]"
# config-read.sh actual dot-source operations: the 3-line guard idiom embeds the
# string 'lib/config-read.sh' twice per site (guard + source line), so raw grep -c
# gives 4-5 hits for 2 actual . source calls. Count only lines that START with
# optional whitespace then '. ' (dot-space = shell source command).
ck "config-read.sh sourced at most twice (actual . source ops; was 3x)" "[ \$(grep -cE '^[[:space:]]*\. .*lib/config-read\.sh' '$SKILL') -le 2 ]"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
