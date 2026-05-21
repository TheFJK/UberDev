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

# ----------------------------------------------------------------------
# P5: malformed YAML in scratch dir
#   aggregate.py wraps each per-agent load in try/except yaml.YAMLError;
#   a broken file is logged to stderr and the run continues with N-1.
#   Regression guard for the silent-failure fix in commit f58c11c.
# ----------------------------------------------------------------------
P5="$SCRATCH/p5"
mkdir -p "$P5/scratch/panicked-grandma" \
         "$P5/scratch/power-user" \
         "$P5/scratch/adversarial-security" \
         "$P5/scratch/chaos-engineer"
cp "$FIX/wave-1-grandma.yaml"    "$P5/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-1-power-user.yaml" "$P5/scratch/power-user/out.yaml"
cp "$FIX/wave-1-security.yaml"   "$P5/scratch/adversarial-security/out.yaml"
cp "$FIX/wave-1-malformed.yaml"  "$P5/scratch/chaos-engineer/out.yaml"

P5_ERR="$P5/stderr.log"
python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P5/scratch" \
  --invariants "$INV" --out "$P5/wave-1.yaml" 2> "$P5_ERR"

[ -f "$P5/wave-1.yaml" ] || { echo "P5: aggregator produced no output"; exit 1; }
python3 -c "import yaml; yaml.safe_load(open('$P5/wave-1.yaml'))" \
  || { echo "P5: aggregator output is itself malformed"; exit 1; }

COUNT_P5="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$P5/wave-1.yaml'))['findings']))")"
[ "$COUNT_P5" = "3" ] || { echo "P5: expected 3 findings after malformed-skip, got $COUNT_P5"; exit 1; }

grep -q "warning: skipping malformed" "$P5_ERR" || {
  echo "P5: expected 'warning: skipping malformed' on stderr; got:"; cat "$P5_ERR"; exit 1;
}
echo "PASS P5: malformed YAML skipped with stderr warning, aggregator continues"

# ----------------------------------------------------------------------
# P6: partial / null evidence shapes are dropped
#   evidence: {screenshot: null, dom_hash: null, repro_steps: []} carries
#   no anchor; has_evidence() must return False and the finding must not
#   appear in the aggregate. Regression guard for the evidence-presence
#   contract in aggregate.py (commit f58c11c).
# ----------------------------------------------------------------------
P6="$SCRATCH/p6"
mkdir -p "$P6/scratch/panicked-grandma" \
         "$P6/scratch/power-user" \
         "$P6/scratch/chaos-engineer"
cp "$FIX/wave-1-grandma.yaml"        "$P6/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-1-power-user.yaml"     "$P6/scratch/power-user/out.yaml"
cp "$FIX/wave-1-null-evidence.yaml"  "$P6/scratch/chaos-engineer/out.yaml"

python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P6/scratch" \
  --invariants "$INV" --out "$P6/wave-1.yaml"

COUNT_P6="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$P6/wave-1.yaml'))['findings']))")"
[ "$COUNT_P6" = "2" ] || { echo "P6: expected 2 findings (null-evidence dropped), got $COUNT_P6"; exit 1; }

LEAKED="$(python3 -c "import yaml; ff=yaml.safe_load(open('$P6/wave-1.yaml'))['findings']; print(any(f.get('persona')=='chaos_engineer' for f in ff))")"
[ "$LEAKED" = "False" ] || { echo "P6: null-evidence finding leaked into output"; exit 1; }
echo "PASS P6: partial/null evidence dropped via has_evidence()"

# ----------------------------------------------------------------------
# P7: finding-ID collisions across waves keep the highest-severity record
#   stable_id(persona, invariant, location) collides for two waves; wave-2
#   carries a stronger severity. report.py:merge_findings (post-Phase-1)
#   must keep the wave-2 record, not the wave-1 one. Regression guard for
#   the setdefault → severity-rank fix in commit f58c11c.
# ----------------------------------------------------------------------
P7="$SCRATCH/p7"
mkdir -p "$P7/w1/scratch/panicked-grandma" \
         "$P7/w2/scratch/panicked-grandma" \
         "$P7/waves"
cp "$FIX/wave-1-grandma.yaml"           "$P7/w1/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-2-grandma-collision.yaml" "$P7/w2/scratch/panicked-grandma/out.yaml"

python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P7/w1/scratch" \
  --invariants "$INV" --out "$P7/waves/wave-1.yaml"
python3 "$AGG" --run-id smoke --wave 2 --scratch-dir "$P7/w2/scratch" \
  --invariants "$INV" --out "$P7/waves/wave-2.yaml"

SAME_ID="$(python3 -c "
import yaml
a = yaml.safe_load(open('$P7/waves/wave-1.yaml'))['findings'][0]['id']
b = yaml.safe_load(open('$P7/waves/wave-2.yaml'))['findings'][0]['id']
print(a == b)
")"
[ "$SAME_ID" = "True" ] || { echo "P7: fixtures must collide on stable_id; check persona/invariant/location"; exit 1; }

MERGED_SEV="$(python3 -c "
import sys, yaml
sys.path.insert(0, 'plugins/uberdev/skills/testers-pipeline')
from report import load_waves, merge_findings
merged = merge_findings(load_waves('$P7/waves'))
assert len(merged) == 1, f'expected 1 merged finding after collision, got {len(merged)}'
print(next(iter(merged.values()))['severity'])
")"
[ "$MERGED_SEV" = "blocker" ] || \
  { echo "P7: collision should keep highest-severity (blocker); got $MERGED_SEV"; exit 1; }
echo "PASS P7: finding-ID collision keeps highest-severity record across waves"

echo "ALL TESTS PASS"
