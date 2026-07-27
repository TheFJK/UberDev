#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
LIB_MIRROR="$ROOT/codex/uberdev-codex/lib/child-dispatch.sh"
CONTRACT="$ROOT/plugins/uberdev/shared/phase1-reviewer-output-v1.md"
CONTRACT_MIRROR="$ROOT/codex/uberdev-codex/shared/phase1-reviewer-output-v1.md"
FINDINGS_AGENT="$ROOT/plugins/uberdev/agents/findings-to-issues.md"
FINDINGS_AGENT_MIRROR="$ROOT/codex/uberdev-codex/agents/findings-to-issues.md"

python3 -I -B - "$TREE" <<'PY'
import json,sys
tree=json.load(open(sys.argv[1])); providers={k:v for k,v in tree['edges'].items() if v['kind']=='provider'}
assert tree.get('input_limits')=={'max_serialized_bytes':49152}
types={'integer','string','optional_string','boolean','path','optional_path','directory','string_array','path_array','optional_path_array','repo_path_array'}
assert providers
for edge,row in providers.items():
    assert row.get('workspace_mode','isolated') in {'isolated','caller'}, edge
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
for edge in ('review_pr.simplify.reuse','review_pr.simplify.quality','review_pr.simplify.efficiency'):
    row=providers[edge]
    assert 'focus' not in row['required_inputs'], edge
    assert row['optional_inputs'].get('focus')=='optional_string', edge
    assert 'additional_focus' not in row['optional_inputs'], edge
review_edges={edge for edge in providers if edge.startswith('review_pr.review.')}
assert len(review_edges)==6
assert tree.get('output_contracts')=={'phase1-reviewer-v1':'shared/phase1-reviewer-output-v1.md'}
for edge in review_edges:
    row=providers[edge]
    assert row['required_inputs']['changed_paths']=='repo_path_array', edge
    assert row.get('output_contract')=='phase1-reviewer-v1', edge
caller_edges={
 'review_pr.fix.phase1','review_pr.fix.phase2','review_pr.ci.fix_code',
 'review_pr.ci.rebase','review_pr.ci.resolve_conflict'
}
assert {edge for edge,row in providers.items() if row.get('workspace_mode')=='caller'}==caller_edges
for edge in caller_edges:
    assert providers[edge]['required_inputs'].get('working_dir')=='directory', edge
PY

grep -q '^uberdev_preflight_child_batch()' "$LIB"
grep -q '^uberdev_unwind_child()' "$LIB"
cmp "$TREE" "$ROOT/codex/uberdev-codex/policy/solve-run-tree-v1.json"
cmp "$LIB" "$ROOT/codex/uberdev-codex/lib/child-dispatch.sh"
cmp "$ROOT/plugins/uberdev/lib/child-inputs.py" \
  "$ROOT/codex/uberdev-codex/lib/child-inputs.py"
cmp "$CONTRACT" "$CONTRACT_MIRROR"

python3 -I -B - \
  "$LIB" "$LIB_MIRROR" "$CONTRACT" "$CONTRACT_MIRROR" \
  "$FINDINGS_AGENT" "$FINDINGS_AGENT_MIRROR" <<'PY'
import os
import pathlib
import sys
import tempfile

lib_path,lib_mirror_path,contract_path,contract_mirror_path,*agent_paths=sys.argv[1:]
lib=pathlib.Path(lib_path).read_text()
lib_mirror=pathlib.Path(lib_mirror_path).read_text()
contract=pathlib.Path(contract_path).read_text()
contract_mirror=pathlib.Path(contract_mirror_path).read_text()
failures=[]

if "def safe_existing(" in lib or "def safe_existing(" in lib_mirror:
    failures.append("unused safe_existing helper remains")
if contract != contract_mirror:
    failures.append("reviewer contract mirrors drift")
if "`` -?:,[]{}#&*!|>@` ``; contain" not in contract:
    failures.append("literal-backtick grammar does not use a safe code-span delimiter")

for agent_path in agent_paths:
    value=pathlib.Path(agent_path).read_text()
    if (
        "partial second request cannot turn a healthy API into two empty values:\n\n"
        "   ```bash\n"
    ) not in value:
        failures.append(f"{agent_path}: rate-limit fence lacks a leading blank line")
    if (
        '     SEARCH_REMAINING=""\n'
        "   fi\n"
        "   ```\n\n"
        "   The core bucket funds"
    ) not in value:
        failures.append(f"{agent_path}: rate-limit fence lacks a trailing blank line")

function_start=lib.index("uberdev_child_validate_phase1_review_result() {")
snippet_start=lib.index("<<'PY'\n",function_start)+len("<<'PY'\n")
snippet_end=lib.index("\nPY\n}",snippet_start)
snippet=lib[snippet_start:snippet_end]

with tempfile.TemporaryDirectory() as temporary:
    result=pathlib.Path(temporary)/"result.md"
    result.write_text(
        "```yaml\nverdict: APPROVE\nfindings: []\nconfidence: high\n```\n",
        encoding="utf-8",
    )
    original_argv=sys.argv
    original_open=os.open
    original_geteuid=getattr(os,"geteuid",None)

    def execute():
        sys.argv=["phase1-validator",str(result),"",""]
        try:
            exec(compile(snippet,"phase1-validator","exec"),{})
        except SystemExit as error:
            return error.code
        return 0

    if callable(original_geteuid):
        os.geteuid=lambda: original_geteuid()+1
        try:
            if execute()!=2:
                failures.append("phase1 validator accepted a foreign-owned result")
        finally:
            os.geteuid=original_geteuid

    observed_flags=[]
    def tracked_open(path,flags,*args,**kwargs):
        observed_flags.append(flags)
        return original_open(path,flags,*args,**kwargs)
    os.open=tracked_open
    try:
        if execute()!=0:
            failures.append("phase1 validator rejected a caller-owned valid result")
    finally:
        os.open=original_open
        sys.argv=original_argv
    if not observed_flags:
        failures.append("phase1 validator did not use descriptor-pinned os.open")
    nofollow=getattr(os,"O_NOFOLLOW",0)
    if nofollow and observed_flags and not observed_flags[0]&nofollow:
        failures.append("phase1 validator omitted O_NOFOLLOW")

if failures:
    raise AssertionError("; ".join(failures))
PY

# The shared constructor must enforce RepoPathArray before the later handoff
# boundary so a successful build always carries the same nominal invariant.
INPUT_HELPER="$ROOT/plugins/uberdev/lib/child-inputs.py"
! grep -q 'MAX_INPUT_BYTES[[:space:]]*=' "$INPUT_HELPER"
grep -q "input_limits" "$INPUT_HELPER"
grep -q "input_limits" "$LIB"
python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
  changed_paths '["README.md","src/example.ts"]' \
  diff_path '"/tmp/diff"' criteria_path '"/tmp/criteria"' emphasis '[]' >/dev/null
for unsafe in \
  '["/absolute"]' \
  '["../traversal"]' \
  '["src/./dot.ts"]' \
  '["src\\windows.ts"]' \
  '["src//empty.ts"]'
do
  if python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
      changed_paths "$unsafe" diff_path '"/tmp/diff"' criteria_path '"/tmp/criteria"' emphasis '[]' \
      >/dev/null 2>&1; then
    echo "child-contract-v2: unsafe RepoPathArray reached a successful construction boundary: $unsafe" >&2
    exit 1
  fi
done

# A successful constructor result must fit inside the dispatcher's immutable
# 64-KiB handoff after the fixed carrier/schema overhead is added.
OVERSIZED_PATHS="$(python3 -I -B - <<'PY'
import json
print(json.dumps([f"src/generated/{index:05d}-{'x' * 80}.ts" for index in range(700)],separators=(',',':')))
PY
)"
if python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
    changed_paths "$OVERSIZED_PATHS" diff_path '"/tmp/diff"' \
    criteria_path '"/tmp/criteria"' emphasis '[]' >/dev/null 2>&1; then
  echo "child-contract-v2: oversized RepoPathArray crossed the construction boundary" >&2
  exit 1
fi

# Exact immutable-input boundary from the shared manifest contract: the limit is
# accepted and limit-plus-one is rejected by the constructor.
python3 -I -B - "$INPUT_HELPER" "$TREE" <<'PY'
import importlib.util,json,pathlib,sys
helper_path,manifest_path=sys.argv[1:]
spec=importlib.util.spec_from_file_location("child_inputs",helper_path)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
manifest=json.loads(pathlib.Path(manifest_path).read_text())
limit=manifest['input_limits']['max_serialized_bytes']
paths=[f"src/p{index:02d}-"+("x"*2990)+".ts" for index in range(16)]
accepted={"changed_paths":paths,"diff_path":"/tmp/diff","criteria_path":"/tmp/criteria","emphasis":[]}
current=len(json.dumps(accepted,sort_keys=True,separators=(",",":")).encode())
accepted["changed_paths"][-1]=accepted["changed_paths"][-1][:-3]+("x"*(limit-current))+".ts"
rejected=json.loads(json.dumps(accepted))
rejected["changed_paths"][-1]=rejected["changed_paths"][-1][:-3]+"x.ts"
assert len(json.dumps(accepted,sort_keys=True,separators=(",",":")).encode())==limit
assert len(json.dumps(rejected,sort_keys=True,separators=(",",":")).encode())==limit+1
assert max(map(len,accepted["changed_paths"]))<=4096
module.validate_inputs(manifest,"review_pr.review.correctness",accepted)
try:
    module.validate_inputs(manifest,"review_pr.review.correctness",rejected)
except module.InputFailure:
    pass
else:
    raise AssertionError("limit-plus-one inputs crossed the constructor boundary")
PY
echo 'child-contract-v2: PASS'
