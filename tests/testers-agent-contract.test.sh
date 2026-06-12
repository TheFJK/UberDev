#!/usr/bin/env bash
# Tests/testers-agent-contract.test.sh
#
# Grep-based structural contract test for the /uberdev:testers agent fleet.
# Asserts every agent file under plugins/uberdev/agents/testers-*.md has:
#   - Canonical frontmatter (name, description, model, color)
#   - allowed-tools that exclude Edit and bare Write
#   - A reference to the reviewer YAML contract (verdict / findings / confidence)
#   - At least one of the documented invariant IDs from invariants.yaml
#
# This test is intentionally grep-based (no agent execution) — same style as
# tests/aliases.test.sh and tests/audit-fixups.test.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AGENT_DIR="plugins/uberdev/agents"
SKILL_DIR="plugins/uberdev/skills/testers-pipeline"
INVARIANTS="$SKILL_DIR/invariants.yaml"

EXPECTED_AGENTS=(
  testers-panicked-grandma
  testers-power-user
  testers-adversarial-security
  testers-chaos-engineer
  testers-a11y-critic
  testers-mobile-thumb
  testers-monitor-primary
  testers-monitor-devils-advocate
)

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# C1: invariants.yaml exists and has 10 invariants
[ -f "$INVARIANTS" ] || fail "C1: invariants.yaml missing at $INVARIANTS"
N="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$INVARIANTS'))['invariants']))")"
[ "$N" = "10" ] || fail "C1: expected 10 invariants, got $N"
pass "C1: invariants.yaml has 10 entries"

# C2: skill SKILL.md exists and declares schema_version
[ -f "$SKILL_DIR/SKILL.md" ] || fail "C2: SKILL.md missing"
grep -q "schema_version: 1" "$SKILL_DIR/SKILL.md" || fail "C2: SKILL.md lacks schema_version: 1"
pass "C2: SKILL.md present and declares schema_version: 1"

# C3: command file exists and invokes testers-pipeline
[ -f "plugins/uberdev/commands/testers.md" ] || fail "C3: command file missing"
grep -q "uberdev:testers-pipeline" "plugins/uberdev/commands/testers.md" || fail "C3: command does not invoke uberdev:testers-pipeline"
pass "C3: command file invokes testers-pipeline"

# C4: each expected agent file exists with canonical frontmatter
for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  [ -f "$F" ] || fail "C4: $a missing"
  grep -q "^name: $a$" "$F" || fail "C4 $a: name line wrong"
  grep -q "^model: " "$F" || fail "C4 $a: model line missing"
  grep -q "^color: " "$F" || fail "C4 $a: color line missing"
done
pass "C4: all 8 agent files exist with canonical frontmatter"

# C5: no agent has Edit or bare Write in allowed-tools (read-only contract).
# Bare `Write` is forbidden; `Write(<scope>)` is OK. POSIX ERE has no
# lookarounds, so we detect bare Write via a 3-line python YAML parser
# (load the frontmatter, scan allowed-tools tokens). Python YAML is already
# a hard dep of this repo (aggregate.py + report.py); cost is one extra
# subprocess per agent file.
for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  if grep -E "^allowed-tools:.*\\bEdit\\b" "$F" > /dev/null; then
    fail "C5 $a: forbidden 'Edit' in allowed-tools"
  fi
  python3 - "$F" "$a" <<'PY' || exit $?
import sys, re
path, agent = sys.argv[1], sys.argv[2]
with open(path) as fh:
    text = fh.read()
# Extract allowed-tools line(s) from frontmatter — accept YAML list or flow array.
# We don't need a full YAML parser; the contract is "no bare Write token", so
# tokenize on commas / brackets and check each entry literally.
m = re.search(r'(?m)^allowed-tools:\s*(.+)$', text)
if not m:
    sys.exit(0)  # no allowed-tools line → nothing forbidden
tokens = re.findall(r'[A-Za-z_]+(?:\([^)]*\))?', m.group(1))
for tok in tokens:
    if tok == 'Write':
        print(f"FAIL  C5 {agent}: bare 'Write' in allowed-tools (must be scoped Write(<dir>))", file=sys.stderr)
        sys.exit(1)
PY
done
pass "C5: no agent has unrestricted Edit / Write"

# C6: each persona references at least one invariant ID from invariants.yaml
INV_IDS="$(python3 -c "import yaml; [print(i['id']) for i in yaml.safe_load(open('$INVARIANTS'))['invariants']]")"
PERSONA_AGENTS=( testers-panicked-grandma testers-power-user testers-adversarial-security testers-chaos-engineer testers-a11y-critic testers-mobile-thumb )
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  FOUND=0
  while IFS= read -r id; do
    if grep -qE "\\b$id\\b" "$F"; then FOUND=1; break; fi
  done <<< "$INV_IDS"
  [ "$FOUND" = "1" ] || fail "C6 $a: references no invariant from invariants.yaml"
done
pass "C6: every persona references at least one invariant"

# C6b: every persona references the polite-rate-cap enforcement helper
# (uberdev_rate_limit_curl) AND uses audit-consequence framing.
# This is the structural counterpart to T2.3 (which edited the 6 persona files).
PERSONA_LIST=( adversarial-security a11y-critic chaos-engineer mobile-thumb panicked-grandma power-user )
c6b_count=0
for f in "${PERSONA_LIST[@]}"; do
  PFILE="$AGENT_DIR/testers-${f}.md"
  grep -q "uberdev_rate_limit_curl" "$PFILE" || fail "C6b: missing uberdev_rate_limit_curl ref in $f"
  grep -qE "polite_rate_cap|audit phase|rolling 1-second RPS" "$PFILE" || fail "C6b: missing audit-consequence ref in $f"
  c6b_count=$((c6b_count + 1))
done
[ "$c6b_count" -eq 6 ] || fail "C6b: expected 6 personas, got $c6b_count"
pass "C6b: polite-rate clause present in all 6 persona files"

# C7: each agent emits the reviewer YAML contract markers
for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -q "verdict:" "$F" || fail "C7 $a: missing 'verdict:' in output contract"
  grep -q "findings:" "$F" || fail "C7 $a: missing 'findings:' in output contract"
  grep -q "confidence:" "$F" || fail "C7 $a: missing 'confidence:' in output contract"
done
pass "C7: all agents declare verdict / findings / confidence in their output contract"

# C8 (#306 / RFC 0012 §3.10, re-anchored at the Workflow migration): the
# never-worked master-dispatch mode is REMOVED, not guarded. lib/dispatch.sh
# never provided dispatch_master (public surface:
# uberdev_dispatch_preflight/_resolve_env/_one), so the documented default mode
# printed "dispatched master" with nothing running. The migration deletes the
# whole detached path: the Workflow runtime IS the background execution the
# master was for, and the No-Workflow fallback is the retained inline --watch
# directive recipe. This test now asserts the mode's ABSENCE (no dispatch_master
# call site anywhere in SKILL.md) and that the SKILL records the removal so a
# future re-introduction is a conscious, reviewed act.
SKILL_FILE="$SKILL_DIR/SKILL.md"
# No EXECUTABLE dispatch_master call site (the function-invocation form, e.g.
# `dispatch_master "$MASTER_PROMPT"` or a bare-word `dispatch_master ...`
# command). A backtick-quoted prose MENTION explaining the removal is allowed
# and expected — we only forbid a live call. The patterns below match an
# invocation: dispatch_master followed by a quote or by a non-backtick word,
# but NOT `dispatch_master` in inline-code backticks.
if grep -nE 'dispatch_master[[:space:]]+("|\$|[A-Za-z./])' "$SKILL_FILE" | grep -vE '`dispatch_master`' | grep -q .; then
  fail "C8: an executable dispatch_master call site remains in SKILL.md — the never-worked master mode is removed at the RFC 0012 migration, not re-guarded (#306 / §3.10)"
fi
grep -qE 'master.dispatch.+(remove|removed)|master-dispatch mode is .*remove' "$SKILL_FILE" \
  || fail "C8: SKILL.md must document that the master-dispatch mode is removed (No-Workflow fallback section, #306)"
grep -q '#306' "$SKILL_FILE" \
  || fail "C8: SKILL.md must reference #306 where it records the master-mode removal"
pass "C8: no live dispatch_master call site; the master-mode removal is documented (#306 / §3.10)"

# C8b (#306 / RFC 0012 §3.10): the Workflow path is mandated and the No-Workflow
# fallback is present — the migration's two-sided opt-in shape. workflow.js ships
# as the sibling; SKILL.md must carry the Workflow invocation block AND the
# fallback section (the carrier's §4.2 shape guard also enforces this, but
# anchoring it here keeps the testers contract self-describing).
[ -f "$SKILL_DIR/workflow.js" ] || fail "C8b: skills/testers-pipeline/workflow.js missing (the migrated Workflow script)"
grep -q 'Workflow(' "$SKILL_FILE" || fail "C8b: SKILL.md lacks the Workflow invocation block"
grep -qF 'workflow.js' "$SKILL_FILE" || fail "C8b: SKILL.md does not reference the workflow.js scriptPath"
grep -qF '## No-Workflow fallback' "$SKILL_FILE" || fail "C8b: SKILL.md lacks the '## No-Workflow fallback' section (DR-10)"
# The headline politeBreach exit-1 contract is stated at the post-Workflow seam.
grep -qiE 'exit 1|exit.1' "$SKILL_FILE" || fail "C8b: SKILL.md must state the politeBreach exit-1 mandate"
grep -q 'politeBreach' "$SKILL_FILE" || fail "C8b: SKILL.md must name the politeBreach return field (the fail-the-run signal)"
pass "C8b: Workflow path mandated, fallback present, politeBreach exit-1 contract stated"

# C9 (#306 / RFC 0012 testers-R3a): every persona's network_request evidence schema
# carries url + timestamp. lib/rate-cap-audit.sh silently skips rows lacking EITHER
# field (`if not url or not ts: continue`) — without these schema keys the personas
# never emit them and the polite-rate breach gate audits ~nothing.
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -q 'network_request:' "$F" || fail "C9 $a: missing network_request evidence block"
  grep -A5 'network_request:' "$F" | grep -q 'url:' \
    || fail "C9 $a: network_request block lacks url: (rate-cap audit skips the row)"
  grep -A5 'network_request:' "$F" | grep -q 'timestamp:' \
    || fail "C9 $a: network_request block lacks timestamp: (rate-cap audit skips the row)"
done
pass "C9: all 6 persona network_request schema blocks carry url + timestamp"

# C10 (#306 / RFC 0012 §3.10): the executable lib/rl-curl shim exists and the
# rate-limit invocation chain is allowlist-reachable end to end:
#   - shim is executable, bash-shebanged, sources the SSOT wrapper, and accepts
#     per-call --rate-state-dir= / --rps-cap= argv injection;
#   - every persona allowlist carries the Bash(*/lib/rl-curl*) pattern (the compound
#     export+source+uberdev_rate_limit_curl form matches no Bash() pattern);
#   - persona polite-rate blocks and the SKILL dispatch directive document the
#     per-call long-option form (Phase-0 fence exports never reach persona agents).
RLC="plugins/uberdev/lib/rl-curl"
[ -f "$RLC" ] || fail "C10: $RLC missing"
[ -x "$RLC" ] || fail "C10: $RLC is not executable (x-bit lost on checkout?)"
head -1 "$RLC" | grep -q 'bash' || fail "C10: $RLC must run under a bash shebang"
grep -q 'rate-limit-curl.sh' "$RLC" || fail "C10: shim does not source the SSOT wrapper rate-limit-curl.sh"
grep -q 'uberdev_rate_limit_curl' "$RLC" || fail "C10: shim does not call uberdev_rate_limit_curl"
grep -q -- '--rate-state-dir=' "$RLC" || fail "C10: shim lacks --rate-state-dir= argv injection"
grep -q -- '--rps-cap=' "$RLC" || fail "C10: shim lacks --rps-cap= argv injection"
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -qF 'Bash(*/lib/rl-curl*)' "$F" || fail "C10 $a: allowed-tools lacks the Bash(*/lib/rl-curl*) pattern"
  grep -q -- '--rate-state-dir=' "$F" || fail "C10 $a: polite-rate block lacks the per-call --rate-state-dir= injection form"
done
grep -q 'lib/rl-curl' "$SKILL_FILE" || fail "C10: SKILL dispatch directive does not reference lib/rl-curl"
grep -q -- '--rate-state-dir=' "$SKILL_FILE" || fail "C10: SKILL dispatch directive lacks the per-call --rate-state-dir= injection form"
pass "C10: rl-curl shim, persona allowlists and per-call injection are consistent"

echo "ALL TESTS PASS"
