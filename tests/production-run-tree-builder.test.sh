#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
CONTRACT="$ROOT/tests/fixtures/run-tree-callsite-contract-v1.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$LIB"

CASE_BUILDER="$TMP/build-cases.py"
apply_case_fixture() { python3 -I -B "$CASE_BUILDER" "$TREE" "$1" "$2" "$(id -u)"; }
coverage_is_complete() { [ "$(wc -l <"$1" | tr -d ' ')" -eq "$EXPECTED_COUNT" ]; }

python3 -I -B - "$CASE_BUILDER" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1]).write_text(r'''import hashlib,json,pathlib,sys

tree=json.load(open(sys.argv[1])); fixture=json.load(open(sys.argv[2])); root=pathlib.Path(sys.argv[3]); uid=sys.argv[4]
edges=tree.get('edges'); contracts=fixture.get('contracts')
assert fixture.get('schema_version')==1 and isinstance(edges,dict) and isinstance(contracts,list)
contexts={}

def context(workflow,issue):
 if workflow in contexts:return contexts[workflow]
 run=root/workflow; state=run/f'.agent-state-{uid}'; state.mkdir(parents=True); state.chmod(0o700)
 metadata={'run_id':f'root-{workflow}','repository_id':str(root),'workflow':workflow,'backend':'codex','issue_num':issue,'task_tier':'medium','risk_signals':['security']}
 payload={'schema_version':1,'metadata':metadata,'routing_request':{},'root_decision':{}}
 raw=json.dumps(payload,sort_keys=True,separators=(',',':')).encode(); path=state/f'route-context-v1-root-{workflow}.json'
 path.write_bytes(raw); path.chmod(0o600)
 carrier={'schema_version':1,'run_id':metadata['run_id'],'workflow':workflow,'issue_num':issue,'context_file':str(path),'context_sha256':hashlib.sha256(raw).hexdigest()}
 contexts[workflow]=(run,carrier); return run,carrier

def value(kind,run,key,index):
 if kind=='integer': return 1
 if kind=='boolean': return True
 if kind=='string': return f'value-{key}'
 if kind=='optional_string': return ''
 if kind=='directory': return str(run)
 if kind in {'path','optional_path'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return str(path)
 if kind in {'path_array','optional_path_array'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return [str(path)]
 if kind=='string_array': return [f'value-{key}']
 raise AssertionError((key,kind))

seen=set(); index=0
for contract in contracts:
 assert isinstance(contract,dict)
 edge=contract.get('edge_id'); source=contract.get('source')
 required=contract.get('required_inputs'); optional=contract.get('optional_inputs'); workflows=contract.get('allowed_workflows')
 assert isinstance(edge,str) and edge not in seen; seen.add(edge)
 assert isinstance(source,str) and source and '\t' not in source and '\n' not in source
 assert isinstance(required,list) and isinstance(optional,list) and isinstance(workflows,list) and workflows
 assert all(isinstance(key,str) and key for key in required+optional)
 assert len(required)==len(set(required)) and len(optional)==len(set(optional)) and not set(required)&set(optional)
 assert all(workflow in {'solve','turbo','review-pr','simplify'} for workflow in workflows) and len(workflows)==len(set(workflows))
 row=edges.get(edge)
 assert isinstance(row,dict) and row.get('kind')=='provider'
 assert isinstance(row.get('role'),str) and row['role'] and isinstance(row.get('phase'),str) and row['phase']
 risk_scope=contract.get('risk_scope'); risk_argument=contract.get('risk_argument')
 assert risk_scope==row.get('risk_scope') and risk_scope in {'run','subtask','none'}
 assert risk_argument==({'run':None,'subtask':'subtask','none':[]}[risk_scope])
 manifest_types={**row.get('required_inputs',{}),**row.get('optional_inputs',{})}
 assert all(key in manifest_types for key in required+optional)
 for workflow in workflows:
  index+=1; issue=0 if workflow=='simplify' else 42
  run,carrier=context(workflow,issue)
  inputs={key:value(manifest_types[key],run,key,index) for key in required+optional}
  risks=None if risk_scope=='run' else []
  fields=(edge,source,f'contract-edge-{index:03d}',json.dumps(carrier,separators=(',',':')),json.dumps(inputs,separators=(',',':')),json.dumps(risks,separators=(',',':')))
  print('\t'.join(fields))
''')
PY

CONTRACT_COUNT="$(python3 -I -B -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["contracts"]))' "$CONTRACT")"
EXPECTED_COUNT="$(python3 -I -B -c 'import json,sys; print(sum(len(row["allowed_workflows"]) for row in json.load(open(sys.argv[1]))["contracts"]))' "$CONTRACT")"
[ "$CONTRACT_COUNT" -eq 40 ]
[ "$EXPECTED_COUNT" -eq 102 ]

RUNTIME="$TMP/runtime"
apply_case_fixture "$CONTRACT" "$RUNTIME" >"$TMP/cases.tsv"
awk -F '	' 'NF != 6 { exit 1 }' "$TMP/cases.tsv"
coverage_is_complete "$TMP/cases.tsv"

# Mutation proof: deleting one source-derived contract removes all of that
# contract's workflow cases. The exact coverage gate must reject the reduced
# set instead of silently reconstructing the omitted edge from the manifest.
python3 -I -B - "$CONTRACT" "$TMP/omitted-contract.json" "$TMP/omitted-edge" <<'PY'
import json,pathlib,sys
value=json.load(open(sys.argv[1])); removed=value['contracts'].pop(0)
pathlib.Path(sys.argv[2]).write_text(json.dumps(value,sort_keys=True,separators=(',',':')))
pathlib.Path(sys.argv[3]).write_text(removed['edge_id'])
PY
apply_case_fixture "$TMP/omitted-contract.json" "$TMP/mutation-runtime" >"$TMP/omitted-cases.tsv"
[ "$(wc -l <"$TMP/omitted-cases.tsv" | tr -d ' ')" -lt "$EXPECTED_COUNT" ]
! grep -Fq "$(<"$TMP/omitted-edge")" "$TMP/omitted-cases.tsv"
if coverage_is_complete "$TMP/omitted-cases.tsv"; then
  echo 'production-run-tree-builder: fixture omission silently restored from manifest' >&2
  exit 1
fi

COUNT=0
INVALID_TYPE_CHECKED=0
while IFS="$(printf '\t')" read -r EDGE SOURCE INSTANCE CARRIER INPUTS RISKS; do
  [ -f "$ROOT/$SOURCE" ]
  VALIDATED="$(uberdev_child_inputs_validate "$EDGE" "$INPUTS")"
  [ "$VALIDATED" = "$(python3 -I -B -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]),sort_keys=True,separators=(",",":")))' "$INPUTS")" ]
  if [ "$INVALID_TYPE_CHECKED" -eq 0 ]; then
    INVALID_INPUTS="$(python3 -I -B -c 'import json,sys; value=json.loads(sys.argv[1]); value[next(iter(value))]=None; print(json.dumps(value,separators=(",",":")))' "$INPUTS")"
    if uberdev_child_inputs_validate "$EDGE" "$INVALID_INPUTS" >/dev/null 2>&1; then
      echo "production-run-tree-builder: invalid type accepted for $EDGE" >&2
      exit 1
    fi
    INVALID_TYPE_CHECKED=1
  fi
  UBERDEV_RUN_CARRIER_JSON="$CARRIER"
  export UBERDEV_RUN_CARRIER_JSON
  uberdev_create_child_handoff "$EDGE" "$INSTANCE" "$VALIDATED" "$RISKS" >/dev/null
  [ -f "$UBERDEV_CHILD_HANDOFF" ]
  uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF"
  [ ! -e "$UBERDEV_CHILD_STATUS" ]
  COUNT=$((COUNT + 1))
done <"$TMP/cases.tsv"
[ "$INVALID_TYPE_CHECKED" -eq 1 ]
[ "$COUNT" -eq "$EXPECTED_COUNT" ]
echo "production-run-tree-builder: $COUNT fixture-derived provider contracts passed"
