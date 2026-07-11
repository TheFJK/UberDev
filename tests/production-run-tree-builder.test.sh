#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$LIB"

python3 -I -B - "$TREE" "$TMP" "$(id -u)" >"$TMP/cases.tsv" <<'PY'
import hashlib,json,os,pathlib,stat,sys
tree=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); uid=sys.argv[3]
contexts={}
def context(workflow,issue):
 if workflow in contexts:return contexts[workflow]
 run=root/workflow; state=run/f'.agent-state-{uid}'; state.mkdir(parents=True)
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
  p=run/'inputs'/f'{index}-{key}.txt'; p.parent.mkdir(exist_ok=True); p.write_text('fixture\n'); return str(p)
 if kind in {'path_array','optional_path_array'}:
  p=run/'inputs'/f'{index}-{key}.txt'; p.parent.mkdir(exist_ok=True); p.write_text('fixture\n'); return [str(p)]
 if kind=='string_array': return [f'value-{key}']
 raise AssertionError(kind)
index=0
for edge,row in tree['edges'].items():
 if row.get('kind')!='provider' or not isinstance(row.get('role'),str): continue
 for workflow in row['allowed_workflows']:
  index+=1; issue=0 if workflow=='simplify' else 42
  run,carrier=context(workflow,issue)
  types={**row['required_inputs'],**row['optional_inputs']}
  inputs={key:value(kind,run,key,index) for key,kind in types.items()}
  risks=None if row['risk_scope']=='run' else []
  fields=(edge,f'contract-edge-{index}',json.dumps(carrier,separators=(',',':')),json.dumps(inputs,separators=(',',':')),json.dumps(risks,separators=(',',':')))
  print('\t'.join(fields))
PY

COUNT=0
while IFS="$(printf '\t')" read -r EDGE INSTANCE CARRIER INPUTS RISKS; do
  UBERDEV_RUN_CARRIER_JSON="$CARRIER"
  export UBERDEV_RUN_CARRIER_JSON
  uberdev_create_child_handoff "$EDGE" "$INSTANCE" "$INPUTS" "$RISKS" >/dev/null
  [ -f "$UBERDEV_CHILD_HANDOFF" ]
  uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF"
  [ ! -e "$UBERDEV_CHILD_STATUS" ]
  COUNT=$((COUNT + 1))
done <"$TMP/cases.tsv"
[ "$COUNT" -ge 80 ]
echo "production-run-tree-builder: $COUNT provider contracts passed"
