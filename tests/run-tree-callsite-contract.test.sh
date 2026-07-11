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

def accepted(overrides):
    module.validate(root,tree,fixture,overrides)

brain_rel="plugins/uberdev/skills/brainstorm/SKILL.md"
brain=(root/brain_rel).read_text()
deleted=re.sub(r'^\s*"brainstorm\.research\.codebase"[^\n]*\n?', '', brain, count=1, flags=re.M)
rejected({brain_rel:deleted},"expected 40")
payload_drift=brain.replace('"question":sys.argv[3]', '"questions":sys.argv[3]', 1)
assert payload_drift != brain
rejected({brain_rel:payload_drift},"executable payload mismatch")
retry_key_drift=brain.replace('v["format_retry"]=True', 'v["format_retried"]=True', 1)
assert retry_key_drift != brain
rejected({brain_rel:retry_key_drift},"retry augment mismatch")
brain_without_retry_dispatch=brain.replace(
    'uberdev_brainstorm_dispatch "$failed_edge" "$format_retry_instance" "$failed_role" "$BRAINSTORM_FORMAT_INPUTS"',
    ': "$failed_edge" "$format_retry_instance" "$failed_role" "$BRAINSTORM_FORMAT_INPUTS"',1)
assert brain_without_retry_dispatch != brain
rejected({brain_rel:brain_without_retry_dispatch},"missing dynamic retry dispatch")
commented_dispatch=brain.replace(
    'uberdev_brainstorm_dispatch brainstorm.research.codebase',
    '# uberdev_brainstorm_dispatch brainstorm.research.codebase',1)
assert commented_dispatch != brain
rejected({brain_rel:commented_dispatch},"executable edge mismatch")

orch_rel="plugins/uberdev/skills/orchestrator/SKILL.md"
orch=(root/orch_rel).read_text()
altered=orch.replace('"optional_inputs":[]', '"optional_inputs":["source_drift"]', 1)
assert altered != orch
rejected({orch_rel:altered},"fixture differs")
disabled_dispatch=orch.replace(
    'uberdev_design_dispatch orchestrator.research.codebase',
    ': orchestrator.research.codebase',1)
assert disabled_dispatch != orch
rejected({orch_rel:disabled_dispatch},"executable edge mismatch")
orch_without_retry_dispatch=orch.replace(
    'uberdev_design_dispatch "$failed_edge" "$format_retry_instance" "$failed_role" "$failed_phase" none "$failed_risks_json" "$FORMAT_RETRY_INPUTS"',
    ': "$failed_edge" "$format_retry_instance" "$failed_role" "$failed_phase" none "$failed_risks_json" "$FORMAT_RETRY_INPUTS"',1)
assert orch_without_retry_dispatch != orch
rejected({orch_rel:orch_without_retry_dispatch},"missing dynamic retry dispatch")

sdd_rel="plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
sdd=(root/sdd_rel).read_text()
sdd_without_dispatch=sdd.replace(
    'sdd_dispatch_prepared "$edge_id" "$instance_id" "$task_inputs_json" "$SDD_RISK_JSON" || return $?',
    ': "$edge_id" "$instance_id" "$task_inputs_json" "$SDD_RISK_JSON"',1)
assert sdd_without_dispatch != sdd
rejected({sdd_rel:sdd_without_dispatch},"missing executable SDD dispatch")

post_rel="plugins/uberdev/skills/post-impl-review/SKILL.md"
post=(root/post_rel).read_text()
post_without_record=post.replace(
    'post_review_record "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" \'[]\' "$REVIEW_RECORDS"',
    ': "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" \'[]\' "$REVIEW_RECORDS"',1)
assert post_without_record != post
rejected({post_rel:post_without_record},"missing executable review record")
post_without_repair=post.replace(
    'post_review_record "$FAILED_REVIEW_EDGE" "$REPAIR_INSTANCE" "$REPAIR_INPUTS" \'[]\' "$REPAIR_PREFIX.records"',
    ': "$FAILED_REVIEW_EDGE" "$REPAIR_INSTANCE" "$REPAIR_INPUTS" \'[]\' "$REPAIR_PREFIX.records"',1)
assert post_without_repair != post
rejected({post_rel:post_without_repair},"missing executable review repair")

review_rel="plugins/uberdev/commands/review-pr.md"
review=(root/review_rel).read_text()
missing_lens=review.replace('for LENS in reuse quality efficiency; do', 'for LENS in quality efficiency; do', 1)
assert missing_lens != review
rejected({review_rel:missing_lens},"dynamic edge mismatch")
review_without_record=review.replace(
    'review_child_record "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" \'[]\' "$SIMPLIFY_RECORDS"',
    ': "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" \'[]\' "$SIMPLIFY_RECORDS"',1)
assert review_without_record != review
rejected({review_rel:review_without_record},"missing executable simplify record")
marker="# routed-provider-edge: review_pr.simplify.reuse"
assert marker in review
accepted({review_rel:review.replace(marker,"",1)})
invalid_marker=review.replace(marker,"# routed-provider-edge: review_pr.simplify.unregistered",1)
rejected({review_rel:invalid_marker},"dynamic marker mismatch")
PY

# Real production builder proof: every documented format retry must survive the
# manifest trust boundary with its exact boolean/path augmentation.
RETRY_RUNTIME="$TMP/retry-runtime"
mkdir -p "$RETRY_RUNTIME"
python3 -I -B - "$TREE" "$RETRY_RUNTIME" "$(id -u)" >"$RETRY_RUNTIME/cases.tsv" <<'PY'
import hashlib,json,pathlib,sys
tree=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); uid=sys.argv[3]
run=root/'solve'; state=run/f'.agent-state-{uid}'; state.mkdir(parents=True); state.chmod(0o700)
metadata={'run_id':'callsite-retry-contract','repository_id':str(root),'workflow':'solve','backend':'codex','issue_num':42,'task_tier':'medium','risk_signals':[]}
context={'schema_version':1,'metadata':metadata,'routing_request':{},'root_decision':{}}
raw=json.dumps(context,sort_keys=True,separators=(',',':')).encode()
context_path=state/'route-context-v1-callsite-retry-contract.json'; context_path.write_bytes(raw); context_path.chmod(0o600)
carrier={'schema_version':1,'run_id':metadata['run_id'],'workflow':'solve','issue_num':42,'context_file':str(context_path),'context_sha256':hashlib.sha256(raw).hexdigest()}
edges=(
 'brainstorm.research.codebase','brainstorm.research.library','brainstorm.research.prior_art',
 'orchestrator.research.followup','orchestrator.spec.review','orchestrator.spec.revise')
def value(kind,key,index):
 if kind=='string': return f'value-{key}'
 if kind=='boolean': return True
 if kind=='directory': return str(run)
 if kind in {'path','optional_path'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return str(path)
 if kind in {'path_array','optional_path_array'}:
  path=run/'inputs'/f'{index}-{key}.txt'; path.parent.mkdir(exist_ok=True); path.write_text('fixture\n'); return [str(path)]
 if kind=='string_array': return [f'value-{key}']
 raise AssertionError((key,kind))
for index,edge in enumerate(edges,1):
 row=tree['edges'][edge]
 inputs={key:value(kind,key,index) for key,kind in row['required_inputs'].items()}
 inputs['format_retry']=True
 inputs['format_example_path']=value('path','format-example',index)
 risks=None if row['risk_scope']=='run' else []
 fields=(edge,f'callsite-retry-{index}',json.dumps(carrier,separators=(',',':')),json.dumps(inputs,separators=(',',':')),json.dumps(risks,separators=(',',':')))
 print('\t'.join(fields))
PY

. "$ROOT/plugins/uberdev/lib/child-dispatch.sh"
RETRY_COUNT=0
while IFS="$(printf '\t')" read -r EDGE INSTANCE CARRIER INPUTS RISKS; do
  UBERDEV_RUN_CARRIER_JSON="$CARRIER"; export UBERDEV_RUN_CARRIER_JSON
  uberdev_create_child_handoff "$EDGE" "$INSTANCE" "$INPUTS" "$RISKS" >/dev/null
  python3 -I -B - "$UBERDEV_CHILD_HANDOFF" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))['inputs']
assert value['format_retry'] is True
assert isinstance(value['format_example_path'],str) and value['format_example_path']
PY
  RETRY_COUNT=$((RETRY_COUNT + 1))
done <"$RETRY_RUNTIME/cases.tsv"
[ "$RETRY_COUNT" -eq 6 ]
