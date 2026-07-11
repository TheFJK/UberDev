#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/tests/run-tree-callsite-contract.py"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
CONTRACT="$ROOT/tests/fixtures/run-tree-callsite-contract-v1.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 -I -B "$CHECKER" check --root "$ROOT" --tree "$TREE" --fixture "$CONTRACT"
python3 -I -B "$CHECKER" emit --root "$ROOT" --tree "$TREE" --fixture "$CONTRACT" >"$TMP/emitted.json"
python3 -I -B - "$CONTRACT" "$TMP/emitted.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY

# Mutation proofs: the checker must independently reject source deletion,
# optional-input drift, and loss of explicit reachability for a dynamic edge.
python3 -I -B - "$CHECKER" "$ROOT" "$TREE" "$CONTRACT" <<'PY'
import importlib.util,re,sys
from pathlib import Path

checker_path,root_raw,tree_raw,fixture_raw=sys.argv[1:]
spec=importlib.util.spec_from_file_location("callsite_contract",checker_path)
module=importlib.util.module_from_spec(spec); assert spec.loader is not None; spec.loader.exec_module(module)
root=Path(root_raw); tree=Path(tree_raw); fixture=Path(fixture_raw)

def rejected(overrides, needle):
    try: module.validate(root,tree,fixture,overrides)
    except module.ContractFailure as error:
        assert needle in str(error),(needle,str(error))
    else: raise AssertionError(f"mutation accepted: {needle}")

brain_rel="plugins/uberdev/skills/brainstorm/SKILL.md"
brain=(root/brain_rel).read_text()
deleted=re.sub(r'^\s*"brainstorm\.research\.codebase"[^\n]*\n?', '', brain, count=1, flags=re.M)
rejected({brain_rel:deleted},"expected 40")

orch_rel="plugins/uberdev/skills/orchestrator/SKILL.md"
orch=(root/orch_rel).read_text()
altered=orch.replace('"optional_inputs":[]', '"optional_inputs":["source_drift"]', 1)
assert altered != orch
rejected({orch_rel:altered},"fixture differs")

review_rel="plugins/uberdev/commands/review-pr.md"
review=(root/review_rel).read_text()
marker="# routed-provider-edge: review_pr.simplify.reuse"
assert marker in review
rejected({review_rel:review.replace(marker,"",1)},"unreachable source edge")
PY
