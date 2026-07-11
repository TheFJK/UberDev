#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
CONTRACT="$ROOT/tests/fixtures/run-tree-callsite-contract-v1.json"

python3 -I -B - "$TREE" "$CONTRACT" "${UBERDEV_STRICT_CALLSITE_CONTRACT:-0}" <<'PY'
import json,sys
tree=json.load(open(sys.argv[1])); contract=json.load(open(sys.argv[2])); strict=sys.argv[3]=='1'
assert contract.get('schema_version')==1
providers={k:v for k,v in tree['edges'].items() if v['kind']=='provider' and isinstance(v.get('role'),str)}
rows=contract.get('contracts'); pending=contract.get('pending_edges')
assert isinstance(rows,list) and isinstance(pending,list)
seen=set()
for item in rows:
    assert set(item)=={'edge_id','source','required_inputs','optional_inputs','allowed_workflows'}
    edge=item['edge_id']; assert edge in providers and edge not in seen; seen.add(edge)
    row=providers[edge]
    assert item['source']==row['source'], edge
    assert item['required_inputs']==sorted(row['required_inputs']), edge
    assert item['optional_inputs']==sorted(row['optional_inputs']), edge
    assert item['allowed_workflows']==row['allowed_workflows'], edge
assert len(pending)==len(set(pending)) and not (seen&set(pending))
assert seen|set(pending)==set(providers)
assert set(pending)<=set(providers)
if strict and pending: raise SystemExit('pending callsite contracts: '+','.join(sorted(pending)))
print(f'run-tree-callsite-contract: {len(seen)} closed, {len(pending)} pending')
PY
