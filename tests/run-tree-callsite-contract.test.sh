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

# The static checker owns only declared/typed contract closure. Executability is
# proved independently by run-tree-execution-receipts.test.sh, so shell grammar
# and reachability heuristics must not grow back here.
python3 -I -B - "$CHECKER" "$ROOT" "$TREE" "$CONTRACT" <<'PY'
import importlib.util,json,re,sys,tempfile
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

def rejected_tree(mutate, needle):
    value=json.loads(tree.read_text())
    mutate(value)
    with tempfile.NamedTemporaryFile("w",suffix=".json",delete=False) as stream:
        json.dump(value,stream); mutated=Path(stream.name)
    try:
        try: module.validate(root,mutated,fixture)
        except module.ContractFailure as error:
            assert needle in str(error),(needle,str(error))
        else: raise AssertionError(f"manifest mutation accepted: {needle}")
    finally: mutated.unlink()

brain_rel="plugins/uberdev/skills/brainstorm/SKILL.md"
brain=(root/brain_rel).read_text()
deleted=re.sub(r'^\s*"brainstorm\.research\.codebase"[^\n]*\n?', '', brain, count=1, flags=re.M)
rejected({brain_rel:deleted},"expected 40")

invalid_workflow=brain.replace(
    '"allowed_workflows":["solve","turbo"]',
    '"allowed_workflows":["solve","unknown"]',1)
assert invalid_workflow != brain
rejected({brain_rel:invalid_workflow},"allowed workflows must be sorted and closed")

risk_mismatch=brain.replace(
    '"risk_scope":"none","risk_argument":[]',
    '"risk_scope":"none","risk_argument":"subtask"',1)
assert risk_mismatch != brain
rejected({brain_rel:risk_mismatch},"risk scope/argument mismatch")

def drift_question_type(value):
    value["edges"]["brainstorm.research.codebase"]["required_inputs"]["question"]="boolean"
rejected_tree(drift_question_type,"manifest input type mismatch: brainstorm.research.codebase")

orch_rel="plugins/uberdev/skills/orchestrator/SKILL.md"
orch=(root/orch_rel).read_text()
altered=orch.replace('"optional_inputs":[]', '"optional_inputs":["source_drift"]', 1)
assert altered != orch
rejected({orch_rel:altered},"fixture differs")
PY

python3 -I -B - "$CHECKER" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for forbidden in (
    "import shlex",
    "BASH_FENCE",
    "_prefix_expects_command",
    "_token_is_executable",
    "_heredoc_declarations",
    "_executable_lines",
    "_has_executable_helper",
    "_command",
    "_function_body",
    "_without_nested_functions",
    "_validate_source_reachability",
):
    assert forbidden not in text, f"shell parser symbol remains: {forbidden}"
line_count = len(text.splitlines())
assert line_count < 360, f"static checker did not materially shrink: {line_count} lines"
PY
