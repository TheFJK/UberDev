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

echo "== #192: circuit-breaker halt + flood persisted to run-state.txt, reconstructed in Phase 4 =="
# Every bash fence runs in a FRESH shell (each phase re-derives RUN_ID/RUN_DIR via
# the #171 rehydration stanza), so a CB3/CB4/CB5 trip set only in memory in the
# Phase-1 loop is invisible to Phase 4. It MUST be persisted to run-state.txt and
# reconstructed there — exactly as OVERFLOW already is.
ck "Phase 1 persists CB3 halt reason to run-state.txt" "grep -q 'CIRCUIT_BREAKER_HALT=CB3' '$SKILL'"
ck "Phase 1 persists CB4 halt reason to run-state.txt" "grep -q 'CIRCUIT_BREAKER_HALT=CB4' '$SKILL'"
ck "Phase 1 persists CB5 halt reason to run-state.txt" "grep -q 'CIRCUIT_BREAKER_HALT=CB5' '$SKILL'"
ck "Phase 1 persists FINDINGS_FLOOD=true to run-state.txt" "grep -q 'FINDINGS_FLOOD=true' '$SKILL'"
# Phase 4 reconstructs the halt decision + flood banner by reading run-state.txt.
ck "Phase 4 reconstructs halt by grepping CIRCUIT_BREAKER_HALT from run-state.txt" "grep -qE 'grep .*CIRCUIT_BREAKER_HALT' '$SKILL'"
ck "Phase 4 reconstructs flood by grepping FINDINGS_FLOOD from run-state.txt" "grep -qE 'grep .*FINDINGS_FLOOD' '$SKILL'"
ck "Phase 4 exit gate keys off reconstructed HALT_REASON" "grep -q 'HALT_REASON' '$SKILL'"
# The brittle in-memory-only exit gate is gone: '\${CIRCUIT_BREAKER_HALT:-0}' = 1
# defaulted to 0 in Phase 4's fresh shell — the exact #192 false-clean exit-0 bug.
ck "old in-memory-only exit gate removed (CIRCUIT_BREAKER_HALT:-0 default)" "[ \$(grep -c 'CIRCUIT_BREAKER_HALT:-0' '$SKILL') -eq 0 ]"

echo "== #192 behavioral: Phase-4 reconstruction honors the persisted halt =="
# The shape assertions above prove the persistence/reconstruction code EXISTS; this
# block proves it BEHAVES (a refactor that kept the grep tokens but broke the exit
# gate would slip past shape-only checks). The SKILL.md Phase-4 bash is a
# directive-emitter that can't run standalone, so `_recon` is a faithful replica of
# the SKILL.md "## Phase 4" reconstruction + banner + exit gate — KEEP IT IN SYNC
# if that fence changes (the shape greps above guard the SKILL.md side of the pair).
_recon() { # $1 = RUN_DIR ; prints banners to stdout ; returns 1 on halt, else 0
  local RUN_DIR="$1" MAX_CHUNKS=25 RUN_STATE HALT_REASON FINDINGS_FLOOD
  RUN_STATE="$RUN_DIR/run-state.txt"
  HALT_REASON=""
  FINDINGS_FLOOD=0
  if [ -r "$RUN_STATE" ]; then
    HALT_REASON="$(grep -E '^CIRCUIT_BREAKER_HALT=' "$RUN_STATE" | tail -n1 | cut -d= -f2)"
    grep -q '^FINDINGS_FLOOD=true' "$RUN_STATE" && FINDINGS_FLOOD=1
  fi
  [ -n "$HALT_REASON" ] && echo "  halted:          yes (circuit breaker $HALT_REASON tripped — results are INCOMPLETE, exit 1)"
  [ "$FINDINGS_FLOOD" = "1" ] && echo "  partial:         yes (findings-flood CB5 triggered)"
  grep -q '^OVERFLOW=true' "$RUN_STATE" 2>/dev/null && echo "  overflow:        yes (capped at MAX_CHUNKS=$MAX_CHUNKS; use --all to override)"
  [ -n "$HALT_REASON" ] && return 1
  return 0
}
_RS="$(mktemp -d)"; trap 'rm -rf "$_RS"' EXIT
# CB5 flood: exit 1 + halted banner + findings-flood partial banner
printf 'PARTIAL=true\nFINDINGS_FLOOD=true\nCIRCUIT_BREAKER_HALT=CB5\n' > "$_RS/run-state.txt"
OUT="$(_recon "$_RS")"; RC=$?
ck "#192 behavioral: CB5 flood exits 1" "[ $RC -eq 1 ]"
ck "#192 behavioral: CB5 prints halted banner" "printf '%s' \"\$OUT\" | grep -q 'CB5 tripped'"
ck "#192 behavioral: CB5 prints findings-flood partial banner" "printf '%s' \"\$OUT\" | grep -q 'findings-flood CB5 triggered'"
# CB3 wave-timeout: exit 1 + halted banner, NO findings-flood banner
printf 'CIRCUIT_BREAKER_HALT=CB3\n' > "$_RS/run-state.txt"
OUT="$(_recon "$_RS")"; RC=$?
ck "#192 behavioral: CB3 wave-timeout exits 1" "[ $RC -eq 1 ]"
ck "#192 behavioral: CB3 prints halted banner" "printf '%s' \"\$OUT\" | grep -q 'CB3 tripped'"
ck "#192 behavioral: CB3 has NO findings-flood banner" "! printf '%s' \"\$OUT\" | grep -q 'findings-flood'"
# Clean run: run-state.txt is created on-demand only by a breaker, so it is ABSENT
# on a clean run -> exit 0, no banners (the documented clean-completion mapping).
rm -f "$_RS/run-state.txt"
OUT="$(_recon "$_RS")"; RC=$?
ck "#192 behavioral: clean run (no run-state.txt) exits 0" "[ $RC -eq 0 ]"
ck "#192 behavioral: clean run prints no banners" "[ -z \"\$OUT\" ]"
# Overflow-only (turbo cap-and-continue): NOT a halt -> exit 0, overflow banner only.
# Also exercises the OVERFLOW grep -q rewrite (no spurious 'integer expected' / no halt).
printf 'OVERFLOW=true\n' > "$_RS/run-state.txt"
OUT="$(_recon "$_RS")"; RC=$?
ck "#192 behavioral: overflow-only is not a halt (exits 0)" "[ $RC -eq 0 ]"
ck "#192 behavioral: overflow-only prints overflow banner" "printf '%s' \"\$OUT\" | grep -q 'overflow:'"
ck "#192 behavioral: overflow-only has NO halted banner" "! printf '%s' \"\$OUT\" | grep -q 'halted:'"

echo "== U7: area-scoped fixed-fleet fanout (the 422→~8 agent optimization) =="
# Pack into <= NUM_AREAS areas, ONE multi-lens reviewer per area — NOT files×6.
ck "Phase 0 packs via chunk.py --areas" "grep -qE 'chunk\.py' '$SKILL' && grep -q -- '--areas \"\$NUM_AREAS\"' '$SKILL'"
ck "resolves uberscan.areas config key (default 8, range 1-24)" "grep -qE 'uberscan\.areas .*UBERDEV_UBERSCAN_AREAS .*1 24 8' '$SKILL'"
ck "CB7 projects exactly 1 agent per area" "grep -qE 'PROJECTED_AGENTS=\\\$\\(\\( EMITTED_AREAS' '$SKILL'"
ck "old chunks×6+2 projection removed" "[ \$(grep -c 'EMITTED_CHUNKS \* 6' '$SKILL') -eq 0 ]"
# Dispatch directive: a single multi-lens reviewer, not the 6-agent roster.
ck "dispatch directive uses a single multi-lens reviewer" "grep -q 'role: area-multi-lens-reviewer' '$SKILL'"
ck "legacy 6-agent roster no longer dispatched (agent: lines)" "[ \$(grep -cE '^[[:space:]]*- agent: (silent-failure-hunter|type-design-analyzer|comment-analyzer|pr-test-analyzer)' '$SKILL') -eq 0 ]"
# Phase 1b: Semgrep + coverage run INLINE, not as dispatched research agents.
ck "Phase 1b runs Semgrep inline" "grep -qE 'semgrep scan --config' '$SKILL'"
ck "Phase 1b coverage heuristic runs inline" "grep -q 'global-coverage.md' '$SKILL' && grep -qE 'git.*ls-files' '$SKILL'"
ck "no research-security/research-test-coverage agent dispatch remains" "[ \$(grep -cE 'agent: research-(security|test-coverage)' '$SKILL') -eq 0 ]"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
