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
