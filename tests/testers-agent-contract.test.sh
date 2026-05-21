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

echo "ALL TESTS PASS"
