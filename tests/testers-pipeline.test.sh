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

# Run aggregator
python3 "$AGG" \
  --run-id smoke \
  --wave 1 \
  --scratch-dir "$SCRATCH/scratch" \
  --invariants "$INV" \
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
python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$SCRATCH/scratch" --invariants "$INV" --out "$SCRATCH/wave-1b.yaml"
DIFF="$(python3 -c "import yaml; a=yaml.safe_load(open('$SCRATCH/wave-1.yaml'))['findings']; b=yaml.safe_load(open('$SCRATCH/wave-1b.yaml'))['findings']; print(set(f['id'] for f in a) == set(f['id'] for f in b))")"
[ "$DIFF" = "True" ] || { echo "P4: stable-id determinism broken"; exit 1; }
echo "PASS P4: finding IDs are deterministic"

echo "ALL TESTS PASS"
