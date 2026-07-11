#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"

python3 -I -B - "$TREE" <<'PY'
import json,sys
tree=json.load(open(sys.argv[1])); providers={k:v for k,v in tree['edges'].items() if v['kind']=='provider'}
types={'integer','string','optional_string','boolean','path','optional_path','directory','string_array','path_array','optional_path_array'}
assert providers
for edge,row in providers.items():
    assert 'inputs' not in row and 'input_types' not in row, edge
    assert isinstance(row.get('required_inputs'),dict), edge
    assert isinstance(row.get('optional_inputs'),dict), edge
    assert not (set(row['required_inputs']) & set(row['optional_inputs'])), edge
    assert set(row['required_inputs'].values())|set(row['optional_inputs'].values()) <= types, edge
    allowed=row.get('allowed_workflows')
    assert isinstance(allowed,list) and allowed==sorted(set(allowed)), edge
    assert set(allowed) <= {'solve','turbo','review-pr','simplify'}, edge
for edge in ('orchestrator.plan.write','sdd.task.implement'):
    assert providers[edge]['allowed_workflows']==['solve','turbo']
assert providers['orchestrator.plan.write']['retry']=={'revision':1,'verification':2}
assert providers['orchestrator.plan.write']['optional_inputs']['verification_feedback_path']=='path'
assert providers['orchestrator.plan.write']['optional_inputs']['revision_brief_path']=='path'
for edge,row in providers.items():
    if row.get('retry',{}).get('format'):
        assert row['optional_inputs']['format_retry']=='boolean', edge
        assert row['optional_inputs']['format_example_path']=='path', edge
PY

grep -q '^uberdev_preflight_child_batch()' "$LIB"
grep -q '^uberdev_unwind_child()' "$LIB"
cmp "$TREE" "$ROOT/codex/uberdev-codex/policy/solve-run-tree-v1.json"
cmp "$LIB" "$ROOT/codex/uberdev-codex/lib/child-dispatch.sh"
echo 'child-contract-v2: PASS'
