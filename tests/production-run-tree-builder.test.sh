#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
CONTRACT="$ROOT/tests/fixtures/run-tree-callsite-contract-v1.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$LIB"
BUILDER_CALLS="$TMP/builder-calls"
: >"$BUILDER_CALLS"
eval "$(declare -f uberdev_child_inputs_build | sed '1s/uberdev_child_inputs_build/uberdev_child_inputs_build_production/')"
uberdev_child_inputs_build() {
  printf '%s\n' "$1" >>"$BUILDER_CALLS"
  uberdev_child_inputs_build_production "$@"
}

CASE_BUILDER="$TMP/build-cases.py"
build_case_fixture() { python3 -I -B "$CASE_BUILDER" "$TREE" "$1" "$2" "$(id -u)" "$ROOT"; }
apply_case_fixture() { build_case_fixture "$1" "$2"; }
coverage_is_complete() { [ "$(wc -l <"$1" | tr -d ' ')" -eq "$EXPECTED_COUNT" ]; }

python3 -I -B - "$CASE_BUILDER" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1]).write_text(r'''import hashlib,json,pathlib,sys

tree=json.load(open(sys.argv[1])); fixture=json.load(open(sys.argv[2])); root=pathlib.Path(sys.argv[3]); uid=sys.argv[4]; repository=pathlib.Path(sys.argv[5]).resolve()
edges=tree.get('edges'); contracts=fixture.get('contracts')
assert fixture.get('schema_version')==1 and isinstance(edges,dict) and isinstance(contracts,list)
contexts={}

def governed_source(edge):
 if edge.startswith('brainstorm.'): return 'plugins/uberdev/skills/brainstorm/SKILL.md'
 if edge.startswith('orchestrator.'): return 'plugins/uberdev/skills/orchestrator/SKILL.md'
 if edge.startswith('sdd.'): return 'plugins/uberdev/skills/subagent-driven-dev/SKILL.md'
 if edge.startswith('review_pr.review.'): return 'plugins/uberdev/skills/post-impl-review/SKILL.md'
 if edge.startswith('review_pr.'): return 'plugins/uberdev/commands/review-pr.md'
 if edge.startswith('simplify.'): return 'plugins/uberdev/commands/simplify.md'
 raise AssertionError(edge)

def context(workflow,issue):
 if workflow in contexts:return contexts[workflow]
 run=root/workflow; state=run/f'.agent-state-{uid}'; state.mkdir(parents=True); state.chmod(0o700)
 metadata={'run_id':f'root-{workflow}','repository_id':str(repository),'workflow':workflow,'backend':'background','issue_num':issue,'task_tier':'medium','risk_signals':['security']}
 payload={'schema_version':1,'metadata':metadata,'routing_request':{},'root_decision':{}}
 raw=json.dumps(payload,sort_keys=True,separators=(',',':')).encode(); path=state/f'route-context-v1-root-{workflow}.json'
 path.write_bytes(raw); path.chmod(0o600)
 carrier={'schema_version':1,'run_id':metadata['run_id'],'workflow':workflow,'issue_num':issue,'context_file':str(path),'context_sha256':hashlib.sha256(raw).hexdigest()}
 contexts[workflow]=(run,carrier); return run,carrier

def value(kind,run,key,index):
 if kind=='integer': return 1
 if kind=='boolean': return True
 if kind=='string': return f'value-{key}'
 if kind=='bounded_text': return f'value-{key}'
 if kind=='optional_string': return ''
 if kind=='directory': return str(run)
 if kind in {'path','optional_path'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return str(path)
 if kind in {'path_array','optional_path_array'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return [str(path)]
 if kind=='repo_path_array': return [f'src/deleted-{index}-{key}.ts']
 if kind=='string_array': return [f'value-{key}']
 raise AssertionError((key,kind))

seen=set(); index=0
for contract in contracts:
 assert isinstance(contract,dict)
 edge=contract.get('edge_id'); source=contract.get('source')
 required=contract.get('required_inputs'); optional=contract.get('optional_inputs'); workflows=contract.get('allowed_workflows')
 required_types=contract.get('required_input_types'); optional_types=contract.get('optional_input_types')
 assert isinstance(edge,str) and edge not in seen; seen.add(edge)
 assert isinstance(source,str) and source and '\t' not in source and '\n' not in source
 assert source==governed_source(edge)
 assert isinstance(required,list) and isinstance(optional,list) and isinstance(workflows,list) and workflows
 assert isinstance(required_types,dict) and isinstance(optional_types,dict)
 assert all(isinstance(key,str) and key for key in required+optional)
 assert len(required)==len(set(required)) and len(optional)==len(set(optional)) and not set(required)&set(optional)
 assert all(workflow in {'solve','turbo','review-pr','simplify'} for workflow in workflows) and len(workflows)==len(set(workflows))
 row=edges.get(edge)
 assert isinstance(row,dict) and row.get('kind')=='provider'
 assert isinstance(row.get('role'),str) and row['role'] and isinstance(row.get('phase'),str) and row['phase']
 risk_scope=contract.get('risk_scope'); risk_argument=contract.get('risk_argument')
 assert risk_scope==row.get('risk_scope') and risk_scope in {'run','subtask','none'}
 assert risk_argument==({'run':None,'subtask':'subtask','none':[]}[risk_scope])
 assert set(required)==set(required_types) and set(optional)==set(optional_types)
 assert required_types==row.get('required_inputs') and optional_types==row.get('optional_inputs')
 fixture_types={**required_types,**optional_types}
 for workflow in workflows:
  index+=1; issue=0 if workflow=='simplify' else 42
  run,carrier=context(workflow,issue)
  workspace_mode=row.get('workspace_mode','isolated')
  inputs={key:value(fixture_types[key],repository if workspace_mode=='caller' and key=='working_dir' else run,key,index) for key in required+optional}
  if edge in {'review_pr.fix.phase1','review_pr.fix.phase2'}:
   inputs['pr_number']=issue
   inputs['findings_sha256']=hashlib.sha256(pathlib.Path(inputs['findings_path']).read_bytes()).hexdigest()
   inputs['commit_range_sha256']=hashlib.sha256(pathlib.Path(inputs['commit_range_path']).read_bytes()).hexdigest()
   inputs['authority_sha256']=hashlib.sha256(pathlib.Path(inputs['authority_path']).read_bytes()).hexdigest()
  if edge=='simplify.fix.phase2':
   inputs['pr_number']=0
   inputs['findings_sha256']=hashlib.sha256(pathlib.Path(inputs['findings_path']).read_bytes()).hexdigest()
   inputs['standalone_snapshot_sha256']=hashlib.sha256(pathlib.Path(inputs['standalone_snapshot_path']).read_bytes()).hexdigest()
   inputs['authority_sha256']=hashlib.sha256(pathlib.Path(inputs['authority_path']).read_bytes()).hexdigest()
  if edge=='review_pr.ci.classify':
   content=f'<external-untrusted-input source="github-actions-log-pr-{issue}-run-1">\nfailed assertion\n</external-untrusted-input>\n'
   inputs.update(
    pr_number=issue,
    run_id='1',
    head_sha='0123456789abcdef0123456789abcdef01234567',
    log_content=content,
    log_sha256=hashlib.sha256(content.encode()).hexdigest(),
   )
  argv_path=root/'argv'/f'{index:03d}.tsv'; argv_path.parent.mkdir(exist_ok=True)
  argv_path.write_text(''.join(f'{key}\t{json.dumps(inputs[key],separators=(",",":"))}\n' for key in required+optional))
  risks=None if risk_scope=='run' else []
  fields=(edge,source,f'contract-edge-{index:03d}',json.dumps(carrier,separators=(',',':')),json.dumps(risks,separators=(',',':')),str(argv_path))
  print('\t'.join(fields))
''')
PY

CONTRACT_COUNT="$(python3 -I -B -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["contracts"]))' "$CONTRACT")"
EXPECTED_COUNT="$(python3 -I -B -c 'import json,sys; print(sum(len(row["allowed_workflows"]) for row in json.load(open(sys.argv[1]))["contracts"]))' "$CONTRACT")"
[ "$CONTRACT_COUNT" -eq 41 ]
[ "$EXPECTED_COUNT" -eq 102 ]

RUNTIME="$TMP/runtime"
apply_case_fixture "$CONTRACT" "$RUNTIME" >"$TMP/cases.tsv"
awk -F '	' 'NF != 6 { exit 1 }' "$TMP/cases.tsv"
coverage_is_complete "$TMP/cases.tsv"

# Same-count mutation proof: optional-key, type, and source drift must each fail
# even though contract and expanded-workflow counts remain unchanged.
python3 -I -B - "$CONTRACT" "$TMP" <<'PY'
import json,pathlib,sys
source=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])
def write(name,mutate):
 value=json.loads(json.dumps(source)); mutate(value['contracts'][0])
 (root/f'drifted-{name}.json').write_text(json.dumps(value,sort_keys=True,separators=(',',':')))
def optional(row):
 removed=row['optional_inputs'].pop(); row['optional_input_types'].pop(removed)
write('optional',optional)
write('type',lambda row: row['required_input_types'].__setitem__('question','boolean'))
write('source',lambda row: row.__setitem__('source','README.md'))
PY
for DRIFT in optional type source; do
  if apply_case_fixture "$TMP/drifted-$DRIFT.json" "$TMP/drifted-$DRIFT-runtime" >"$TMP/drifted-$DRIFT.tsv" 2>"$TMP/drifted-$DRIFT.err"; then
    echo "production-run-tree-builder: same-count $DRIFT drift accepted" >&2
    exit 1
  fi
done

# Mutation proof: deleting one source-derived contract removes all of that
# contract's workflow cases. The exact coverage gate must reject the reduced
# set instead of silently reconstructing the omitted edge from the manifest.
python3 -I -B - "$CONTRACT" "$TMP/omitted-contract.json" "$TMP/omitted-edge" <<'PY'
import json,pathlib,sys
value=json.load(open(sys.argv[1])); removed=value['contracts'].pop(0)
pathlib.Path(sys.argv[2]).write_text(json.dumps(value,sort_keys=True,separators=(',',':')))
pathlib.Path(sys.argv[3]).write_text(removed['edge_id'])
PY
build_case_fixture "$TMP/omitted-contract.json" "$TMP/mutation-runtime" >"$TMP/omitted-cases.tsv"
[ "$(wc -l <"$TMP/omitted-cases.tsv" | tr -d ' ')" -lt "$EXPECTED_COUNT" ]
[ -s "$TMP/omitted-edge" ]
OMITTED_EDGE="$(<"$TMP/omitted-edge")"
OMITTED_LEAK_RC=0
grep -Fq -e "$OMITTED_EDGE" "$TMP/omitted-cases.tsv" || OMITTED_LEAK_RC=$?
if [ "$OMITTED_LEAK_RC" -eq 0 ]; then
  echo "production-run-tree-builder: omitted contract $OMITTED_EDGE leaked back into the generated case set" >&2
  exit 1
fi
[ "$OMITTED_LEAK_RC" -eq 1 ]
if coverage_is_complete "$TMP/omitted-cases.tsv"; then
  echo 'production-run-tree-builder: fixture omission silently restored from manifest' >&2
  exit 1
fi

COUNT=0
INVALID_TYPE_CHECKED=0
VALID_BUILDER_CALLS=0
while IFS="$(printf '\t')" read -r EDGE SOURCE INSTANCE CARRIER RISKS ARGV_FILE; do
  [ -f "$ROOT/$SOURCE" ]
  set --
  while IFS="$(printf '\t')" read -r KEY JSON_LITERAL; do
    set -- "$@" "$KEY" "$JSON_LITERAL"
  done <"$ARGV_FILE"
  BUILT="$(uberdev_child_inputs_build "$EDGE" "$@")"
  VALID_BUILDER_CALLS=$((VALID_BUILDER_CALLS + 1))
  VALIDATED="$(uberdev_child_inputs_validate "$EDGE" "$BUILT")"
  [ "$VALIDATED" = "$BUILT" ]
  if [ "$INVALID_TYPE_CHECKED" -eq 0 ]; then
    set --
    FIRST_ARGUMENT=1
    while IFS="$(printf '\t')" read -r KEY JSON_LITERAL; do
      if [ "$FIRST_ARGUMENT" -eq 1 ]; then JSON_LITERAL=null; FIRST_ARGUMENT=0; fi
      set -- "$@" "$KEY" "$JSON_LITERAL"
    done <"$ARGV_FILE"
    if uberdev_child_inputs_build "$EDGE" "$@" >/dev/null 2>&1; then
      echo "production-run-tree-builder: production builder accepted invalid type for $EDGE" >&2
      exit 1
    fi
    INVALID_TYPE_CHECKED=1
  fi
  UBERDEV_RUN_CARRIER_JSON="$CARRIER"
  export UBERDEV_RUN_CARRIER_JSON
  uberdev_create_child_handoff "$EDGE" "$INSTANCE" "$VALIDATED" "$RISKS" >/dev/null
  [ -f "$UBERDEV_CHILD_HANDOFF" ]
  uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256"
  [ ! -e "$UBERDEV_CHILD_STATUS" ]
  COUNT=$((COUNT + 1))
done <"$TMP/cases.tsv"
[ "$INVALID_TYPE_CHECKED" -eq 1 ]
[ "$COUNT" -eq "$EXPECTED_COUNT" ]
[ "$VALID_BUILDER_CALLS" -eq "$EXPECTED_COUNT" ]
[ "$(wc -l <"$BUILDER_CALLS" | tr -d ' ')" -eq "$((EXPECTED_COUNT + 1))" ]
echo "production-run-tree-builder: $COUNT fixture-derived provider contracts passed"
