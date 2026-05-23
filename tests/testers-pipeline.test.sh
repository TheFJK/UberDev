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

# ----------------------------------------------------------------------
# P5: malformed YAML in scratch dir
#   aggregate.py wraps each per-agent load in try/except yaml.YAMLError;
#   a broken file is logged to stderr and the run continues with N-1.
#   Regression guard: aggregator must skip malformed YAML (issue #132,
#   PR #130 fix in aggregate.py main loop).
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
  --invariants "$INV" --rps-cap 10 --out "$P5/wave-1.yaml" 2> "$P5_ERR"

[ -f "$P5/wave-1.yaml" ] || { echo "P5: aggregator produced no output"; exit 1; }
python3 -c "import yaml; yaml.safe_load(open('$P5/wave-1.yaml'))" \
  || { echo "P5: aggregator output is itself malformed"; exit 1; }

COUNT_P5="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$P5/wave-1.yaml'))['findings']))")"
[ "$COUNT_P5" = "3" ] || {
  echo "P5: expected 3 findings after malformed-skip (grandma + power-user + security), got $COUNT_P5"
  echo "P5:   personas in output: $(python3 -c "import yaml; print([f.get('persona') for f in yaml.safe_load(open('$P5/wave-1.yaml'))['findings']])")"
  exit 1
}

grep -q "warning: skipping malformed" "$P5_ERR" || {
  echo "P5: expected 'warning: skipping malformed' on stderr; got:"; cat "$P5_ERR"; exit 1;
}
echo "PASS P5: malformed YAML skipped with stderr warning, aggregator continues"

# ----------------------------------------------------------------------
# P6: partial / null evidence shapes are dropped
#   evidence: {screenshot: null, dom_hash: null, repro_steps: []} carries
#   no anchor; has_evidence() must return False and the finding must not
#   appear in the aggregate.
#   Regression guard: aggregator must reject null/empty evidence (issue
#   #132, PR #130 fix in aggregate.py has_evidence()).
# ----------------------------------------------------------------------
P6="$SCRATCH/p6"
mkdir -p "$P6/scratch/panicked-grandma" \
         "$P6/scratch/power-user" \
         "$P6/scratch/chaos-engineer"
cp "$FIX/wave-1-grandma.yaml"        "$P6/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-1-power-user.yaml"     "$P6/scratch/power-user/out.yaml"
cp "$FIX/wave-1-null-evidence.yaml"  "$P6/scratch/chaos-engineer/out.yaml"

python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P6/scratch" \
  --invariants "$INV" --rps-cap 10 --out "$P6/wave-1.yaml"

COUNT_P6="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$P6/wave-1.yaml'))['findings']))")"
[ "$COUNT_P6" = "2" ] || { echo "P6: expected 2 findings (null-evidence dropped), got $COUNT_P6"; exit 1; }

LEAKED="$(python3 -c "import yaml; ff=yaml.safe_load(open('$P6/wave-1.yaml'))['findings']; print(any(f.get('persona')=='chaos_engineer' for f in ff))")"
[ "$LEAKED" = "False" ] || { echo "P6: null-evidence finding leaked into output"; exit 1; }
echo "PASS P6: partial/null evidence dropped via has_evidence()"

# ----------------------------------------------------------------------
# P7: finding-ID collisions across waves keep the highest-severity record
#   stable_id(persona, invariant, location) collides for two waves; wave-2
#   carries a stronger severity. report.py:merge_findings must keep the
#   wave-2 record, not the wave-1 one.
#   Regression guard: collision must keep highest-severity, not first-seen
#   (issue #132, PR #130 fix in report.py merge_findings — setdefault to
#   severity-rank).
# ----------------------------------------------------------------------
P7="$SCRATCH/p7"
mkdir -p "$P7/w1/scratch/panicked-grandma" \
         "$P7/w2/scratch/panicked-grandma" \
         "$P7/waves"
cp "$FIX/wave-1-grandma.yaml"           "$P7/w1/scratch/panicked-grandma/out.yaml"
cp "$FIX/wave-2-grandma-collision.yaml" "$P7/w2/scratch/panicked-grandma/out.yaml"

python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P7/w1/scratch" \
  --invariants "$INV" --rps-cap 10 --out "$P7/waves/wave-1.yaml"
python3 "$AGG" --run-id smoke --wave 2 --scratch-dir "$P7/w2/scratch" \
  --invariants "$INV" --rps-cap 10 --out "$P7/waves/wave-2.yaml"

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

# P8 (aggregate-py-rps-cap): aggregate.py must declare --rps-cap as a required
# CLI flag (T2.2 of the RPS-cap-enforcement plan). Two assertions:
#   1. `--rps-cap` appears in --help text
#   2. running without --rps-cap exits non-zero
HELP_OUT="$(python3 "$AGG" --help 2>&1 || true)"
echo "$HELP_OUT" | grep -q -- "--rps-cap" || { echo "P8: --rps-cap not in --help"; exit 1; }
# Run without --rps-cap; expect non-zero exit. `set -e` would abort on the
# expected failure, so guard with `if`.
if python3 "$AGG" --out "$SCRATCH/x.yaml" >/dev/null 2>&1; then
  echo "P8: expected non-zero exit when --rps-cap missing"; exit 1
fi
echo "PASS P8: --rps-cap is a required flag on aggregate.py"

# P9 (rfc-0006-risks-aligned): RFC 0006 must reflect the post-hoc audit
# framing (T3.1). Three assertions:
#   1. mentions the rate-limit-curl.sh helper
#   2. uses "audited post-hoc" or "audit phase" language
#   3. does NOT carry the outdated "limit the exfil bandwidth" framing
RFC="docs/rfc/0006-testers-command.md"
grep -q "rate-limit-curl.sh" "$RFC" || { echo "P9: missing 'rate-limit-curl.sh' in RFC"; exit 1; }
grep -qE "audited post-hoc|audit phase" "$RFC" || { echo "P9: missing 'audited post-hoc' framing"; exit 1; }
if grep -q "limit the exfil bandwidth" "$RFC"; then
  echo "P9: outdated 'limit the exfil bandwidth' framing still present"; exit 1
fi
echo "PASS P9: RFC 0006 risk section aligned with post-hoc audit model"

# ----------------------------------------------------------------------
# P10 (issue #166): render_findings_to_issues_aggregate now emits the
#   <external-untrusted-input> spotlighting envelope (it previously lacked
#   it — security.md #8) and routes cells through the shared hardened cell()
#   (report_primitives, D7). Assert: opening marker in first 128 bytes,
#   single structural close marker, and close marker is the trailer.
# ----------------------------------------------------------------------
P10="$SCRATCH/p10"; mkdir -p "$P10/waves/scratch/power-user"
cp "$FIX/wave-1-power-user.yaml" "$P10/waves/scratch/power-user/out.yaml"
python3 "$AGG" --run-id smoke --wave 1 --scratch-dir "$P10/waves/scratch" \
  --invariants "$INV" --rps-cap 10 --out "$P10/waves/wave-1.yaml"
python3 plugins/uberdev/skills/testers-pipeline/report.py \
  --run-id smoke --waves-dir "$P10/waves" --invariants "$INV" \
  --emit-findings-to-issues-aggregate "$P10/agg.md"
head -c 128 "$P10/agg.md" | grep -q '<external-untrusted-input source="testers-aggregate">' \
  || { echo "P10: opening envelope marker not in first 128 bytes"; exit 1; }
[ "$(grep -cF '</external-untrusted-input>' "$P10/agg.md")" = "1" ] \
  || { echo "P10: expected exactly one structural close marker"; exit 1; }
[ "$(grep -vE '^[[:space:]]*$' "$P10/agg.md" | tail -1)" = '</external-untrusted-input>' ] \
  || { echo "P10: close marker is not the trailer"; exit 1; }
echo "PASS P10: testers aggregate carries spotlighting envelope + hardened cell()"

echo "ALL TESTS PASS"
