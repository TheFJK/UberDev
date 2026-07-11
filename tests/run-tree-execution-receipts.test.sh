#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Each production callsite harness owns its receipt assertions. This suite is
# deliberately only a small CI entrypoint: no exports, aggregate format, or
# second receipt parser to maintain.
BRAINSTORM_SKIP_WRAPPER_MUTATION_PROOF=1 \
  bash "$ROOT/tests/brainstorm-child-inputs.test.sh"
ORCHESTRATOR_SKIP_MUTATION_PROOF=1 \
  bash "$ROOT/tests/orchestrator-child-inputs.test.sh"
bash "$ROOT/tests/sdd-child-inputs.test.sh"
REVIEW_EARLY_PROBE_CHILD=1 \
  bash "$ROOT/tests/review-child-inputs.test.sh"

echo 'run-tree-execution-receipts: PASS (4 independent production harnesses)'
