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
removed_builder=brain.replace(
    'uberdev_child_inputs_build brainstorm.research.codebase',
    ': brainstorm.research.codebase',1)
assert removed_builder != brain
rejected({brain_rel:removed_builder},"builder edge mismatch")
swapped_builder_edge=brain.replace(
    'uberdev_child_inputs_build brainstorm.research.codebase',
    'uberdev_child_inputs_build brainstorm.research.library',1)
assert swapped_builder_edge != brain
rejected({brain_rel:swapped_builder_edge},"builder edge mismatch")
quoted_builder=brain.replace(
    'uberdev_child_inputs_build brainstorm.research.codebase',
    "printf '%s' 'uberdev_child_inputs_build brainstorm.research.codebase'",1)
assert quoted_builder != brain
rejected({brain_rel:quoted_builder},"builder edge mismatch")
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
quoted_runtime_dispatch=brain.replace(
    'uberdev_dispatch_child "$edge" "$handoff" "$result" "$status" >/dev/null',
    "printf '%s\\n' 'uberdev_dispatch_child \\\"$edge\\\" \\\"$handoff\\\" \\\"$result\\\" \\\"$status\\\"' >/dev/null",1)
assert quoted_runtime_dispatch != brain
rejected({brain_rel:quoted_runtime_dispatch},"routed chain missing uberdev_dispatch_child")
inline_comment_dispatch=brain.replace(
    'uberdev_dispatch_child "$edge" "$handoff" "$result" "$status" >/dev/null',
    ': # then uberdev_dispatch_child "$edge" "$handoff" "$result" "$status"',1)
assert inline_comment_dispatch != brain
rejected({brain_rel:inline_comment_dispatch},"routed chain missing uberdev_dispatch_child")
nested_data_dispatch=brain.replace(
    'uberdev_dispatch_child "$edge" "$handoff" "$result" "$status" >/dev/null',
    'printf \'%s\' "$(printf uberdev_dispatch_child)"',1)
assert nested_data_dispatch != brain
rejected({brain_rel:nested_data_dispatch},"routed chain missing uberdev_dispatch_child")

def drift_question_type(value):
    value["edges"]["brainstorm.research.codebase"]["required_inputs"]["question"]="boolean"
rejected_tree(drift_question_type,"manifest input type mismatch: brainstorm.research.codebase")

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
swapped_retry_edge=orch.replace(
    'uberdev_child_inputs_format_retry orchestrator.research.followup',
    'uberdev_child_inputs_format_retry orchestrator.spec.review',1)
assert swapped_retry_edge != orch
rejected({orch_rel:swapped_retry_edge},"retry helper edge mismatch")

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
rejected({post_rel:post_without_repair},"retry helper edge mismatch")

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
rejected({review_rel:review.replace(marker,"",1)},"dynamic marker mismatch")
invalid_marker=review.replace(marker,"# routed-provider-edge: review_pr.simplify.unregistered",1)
rejected({review_rel:invalid_marker},"dynamic marker mismatch")
PY
