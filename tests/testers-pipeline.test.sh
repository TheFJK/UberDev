#!/usr/bin/env bash
# tests/testers-pipeline.test.sh
#
# Integration test for the /uberdev:testers aggregate step.
# Uses canned per-agent YAML outputs (tests/fixtures/testers-mock-outputs/)
# to exercise plugins/uberdev/skills/testers-pipeline/aggregate.py
# deterministically.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# aggregate.py's post-hoc audit (T2.2) sources $CLAUDE_PLUGIN_ROOT/lib/rate-cap-audit.sh.
# In a checked-out worktree the env var (if set at all) points at the installed
# plugin cache, which may not yet contain the helper. Pin it to this worktree
# so the test exercises the *source-of-truth* lib, not whatever happens to be
# installed in ~/.claude/plugins/.
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

SCRATCH="$(mktemp -d -t testers-pipeline-XXXX)"
trap "rm -rf $SCRATCH" EXIT

AGG="plugins/uberdev/skills/testers-pipeline/aggregate.py"
INV="plugins/uberdev/skills/testers-pipeline/invariants.yaml"
FIX="tests/fixtures/testers-mock-outputs"

# Mirror the fixtures into the agent-scoped scratch layout
mkdir -p "$SCRATCH/scratch/panicked-grandma" \
         "$SCRATCH/scratch/power-user" \
         "$SCRATCH/scratch/adversarial-security" \
         "$SCRATCH/scratch/chaos-engineer" \
         "$SCRATCH/scratch/a11y-critic"
cp "$FIX/wave-1-grandma.yaml"      "$SCRATCH/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-1-power-user.yaml"   "$SCRATCH/scratch/power-user/out.yaml"
cp "$FIX/wave-1-security.yaml"     "$SCRATCH/scratch/adversarial-security/out.yaml"
cp "$FIX/wave-1-no-evidence.yaml"  "$SCRATCH/scratch/chaos-engineer/out.yaml"
cp "$FIX/wave-1-no-invariant.yaml" "$SCRATCH/scratch/a11y-critic/out.yaml"

# Run aggregator. NB: T2.2 made --rps-cap a required CLI flag on aggregate.py
# (see P5 below). Pass a benign default here so P1-P4 keep exercising
# aggregation behaviour, not arg-parsing.
python3 "$AGG" \
  --run-id smoke \
  --wave 1 \
  --scratch-dir "$SCRATCH/scratch" \
  --invariants "$INV" \
  --rps-cap 10 \
  --out "$SCRATCH/wave-1.yaml"

# P1: file exists and parses
python3 -c "import yaml; yaml.safe_load(open('$SCRATCH/wave-1.yaml'))" || { echo "P1: malformed YAML"; exit 1; }
echo "PASS P1: wave-1.yaml is well-formed"

# P2: exactly 3 findings (5 inputs, 2 dropped — no-evidence and no-invariant)
COUNT="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$SCRATCH/wave-1.yaml'))['findings']))")"
[ "$COUNT" = "3" ] || { echo "P2: expected 3 findings, got $COUNT"; exit 1; }
echo "PASS P2: aggregator kept 3 valid findings + dropped 2 invalid ones"

# P3: the blocker auth_isolation finding is present
HAS_BLOCKER="$(python3 -c "import yaml; ff=yaml.safe_load(open('$SCRATCH/wave-1.yaml'))['findings']; print(any(f['severity']=='blocker' and f['invariant_violated']=='auth_isolation' for f in ff))")"
[ "$HAS_BLOCKER" = "True" ] || { echo "P3: missing blocker auth_isolation finding"; exit 1; }
echo "PASS P3: blocker auth_isolation finding preserved"

# P4: stable IDs are deterministic — re-run and compare hashes
python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$SCRATCH/scratch" --invariants "$INV" --rps-cap 10 --out "$SCRATCH/wave-1b.yaml"
DIFF="$(python3 -c "import yaml; a=yaml.safe_load(open('$SCRATCH/wave-1.yaml'))['findings']; b=yaml.safe_load(open('$SCRATCH/wave-1b.yaml'))['findings']; print(set(f['id'] for f in a) == set(f['id'] for f in b))")"
[ "$DIFF" = "True" ] || { echo "P4: stable-id determinism broken"; exit 1; }
echo "PASS P4: finding IDs are deterministic"

# P5 (aggregate-py-rps-cap): aggregate.py must declare --rps-cap as a required
# CLI flag (T2.2 of the RPS-cap-enforcement plan). Two assertions:
#   1. `--rps-cap` appears in --help text
#   2. running without --rps-cap exits non-zero
HELP_OUT="$(python3 "$AGG" --help 2>&1 || true)"
echo "$HELP_OUT" | grep -q -- "--rps-cap" || { echo "P5: --rps-cap not in --help"; exit 1; }
# Run without --rps-cap; expect non-zero exit. `set -e` would abort on the
# expected failure, so guard with `if`.
if python3 "$AGG" --out "$SCRATCH/x.yaml" >/dev/null 2>&1; then
  echo "P5: expected non-zero exit when --rps-cap missing"; exit 1
fi
echo "PASS P5: --rps-cap is a required flag on aggregate.py"

# P6 (rfc-0006-risks-aligned): RFC 0006 must reflect the post-hoc audit
# framing (T3.1). Three assertions:
#   1. mentions the rate-limit-curl.sh helper
#   2. uses "audited post-hoc" or "audit phase" language
#   3. does NOT carry the outdated "limit the exfil bandwidth" framing
RFC="docs/rfc/0006-testers-command.md"
grep -q "rate-limit-curl.sh" "$RFC" || { echo "P6: missing 'rate-limit-curl.sh' in RFC"; exit 1; }
grep -qE "audited post-hoc|audit phase" "$RFC" || { echo "P6: missing 'audited post-hoc' framing"; exit 1; }
if grep -q "limit the exfil bandwidth" "$RFC"; then
  echo "P6: outdated 'limit the exfil bandwidth' framing still present"; exit 1
fi
echo "PASS P6: RFC 0006 risk section aligned with post-hoc audit model"

echo "ALL TESTS PASS"
