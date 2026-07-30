#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
POLICY="$ROOT/plugins/uberdev/policy/model-routing-v1.json"

python3 -I -B - "$TREE" "$POLICY" <<'PY'
import json,pathlib,re,sys
tree_path,policy_path=map(pathlib.Path,sys.argv[1:])
assert tree_path.is_file(), "solve run-tree manifest missing"
tree=json.loads(tree_path.read_text()); policy=json.loads(policy_path.read_text())
assert tree['schema_version']==1 and tree['tree_id']=='solve-run-tree-v1'
assert tree['root_edge_id']=='solve.issue.lead'
assert tree['input_limits']=={'max_serialized_bytes':49152}
edges=tree['edges']; assert isinstance(edges,dict) and edges
edge_re=re.compile(r'[a-z][a-z0-9_-]{0,31}(?:\.[a-z][a-z0-9_-]{0,31}){0,3}$')
for edge_id,edge in edges.items():
    assert edge_re.fullmatch(edge_id), edge_id
    assert edge['kind'] in {'provider','skill'}
    assert edge['source'].startswith('plugins/uberdev/')
    assert edge['phase'] and edge['cardinality']
    if edge['kind']=='provider':
        assert edge.get('workspace_mode','isolated') in {'isolated','caller'}, edge_id
        role=edge.get('role')
        if role is not None: assert role in policy['roles'], (edge_id,role)
        assert edge.get('required') in {True,False}
        assert edge.get('risk_scope') in {'none','subtask','run'}, edge_id
        required_inputs=edge.get('required_inputs'); optional_inputs=edge.get('optional_inputs')
        assert isinstance(required_inputs,dict) and isinstance(optional_inputs,dict), edge_id
        assert not set(required_inputs)&set(optional_inputs), edge_id
        assert set(required_inputs.values())|set(optional_inputs.values()) <= {
            'string','bounded_text','optional_string','integer','boolean','path','optional_path',
            'directory','path_array','optional_path_array','repo_path_array','string_array'
        }, edge_id
        allowed=edge.get('allowed_workflows')
        assert isinstance(allowed,list) and allowed==sorted(set(allowed)), edge_id
    else:
        assert edge.get('role') is None and edge.get('route') is None

required={
 'solve.issue.lead','finish_branch.review_pr','review_pr.post_impl_review',
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.simplify.reuse',
 'review_pr.simplify.quality','review_pr.simplify.efficiency',
 'review_pr.fix.phase2','simplify.fix.phase2','review_pr.defer.findings','review_pr.ci.classify',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict'
}
assert required <= edges.keys(), sorted(required-edges.keys())
for stale in {
 'orchestrator.plan.research_dependency','orchestrator.plan.research_tests',
 'orchestrator.plan.research_risks','orchestrator.plan.research_security'
}:
    assert stale not in edges, stale
assert {
 'orchestrator.plan.research.dependency','orchestrator.plan.research.tests',
 'orchestrator.plan.research.risks','orchestrator.plan.research.security'
} <= edges.keys()
assert edges['brainstorm.research.prior_art']['role']=='research-patterns'
assert edges['brainstorm.research.library']['role']=='research-prior-art'
assert edges['orchestrator.plan.write']['retry']['verification']==2
review_edges={
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments',
 'review_pr.review.tests','review_pr.review.general'
}
assert tree['output_contracts']=={
    'phase1-reviewer-v1':'shared/phase1-reviewer-output-v1.md'
}
for edge_id in review_edges:
    assert edges[edge_id]['required'] is True, edge_id
    assert edges[edge_id]['retry']=={'format':1}, edge_id
    assert edges[edge_id]['required_inputs']['changed_paths']=='repo_path_array', edge_id
    assert edges[edge_id]['output_contract']=='phase1-reviewer-v1', edge_id
fixer_inputs={
 'authority_path':'path','authority_sha256':'string',
 'findings_path':'path','findings_sha256':'string',
 'commit_range_path':'path','commit_range_sha256':'string',
 'working_dir':'directory','pr_number':'integer','disposition_path':'path'
}
assert edges['review_pr.fix.phase1']['phase']=='review_fix'
assert edges['review_pr.fix.phase2']['phase']=='simplify_fix'
for edge_id in ('review_pr.fix.phase1','review_pr.fix.phase2'):
    assert edges[edge_id]['required_inputs']==fixer_inputs, edge_id
    assert edges[edge_id]['optional_inputs']=={}, edge_id
assert edges['simplify.fix.phase2']['required_inputs']=={
 'authority_path':'path','authority_sha256':'string',
 'findings_path':'path','findings_sha256':'string',
 'standalone_snapshot_path':'path','standalone_snapshot_sha256':'string',
 'working_dir':'directory','pr_number':'integer','disposition_path':'path'
}
assert edges['simplify.fix.phase2']['optional_inputs']=={}
assert edges['simplify.fix.phase2']['phase']=='simplify_fix'
assert edges['simplify.fix.phase2']['allowed_workflows']==['simplify']
caller_edges={
 'review_pr.fix.phase1','review_pr.fix.phase2','simplify.fix.phase2','review_pr.ci.fix_code',
 'review_pr.ci.rebase','review_pr.ci.resolve_conflict'
}
assert {edge_id for edge_id,row in edges.items() if row.get('workspace_mode')=='caller'}==caller_edges
for edge_id in caller_edges:
    assert edges[edge_id]['required_inputs'].get('working_dir')=='directory', edge_id
assert policy['roles']['spec-compliance-reviewer']=={
 'route':'deep','risk_floor':'deep','sandbox_ceiling':'read-only',
 'delegation_mode':'leaf','risk_judgment':True
}
PY

# The Codex policy copy is generated packaging output. Canonical policy changes
# are verified here; dedicated generation/manifest tests own mirror drift.
cmp "$ROOT/plugins/uberdev/policy/model-routing-v1.json" "$ROOT/codex/uberdev-codex/policy/model-routing-v1.json"
cmp "$ROOT/plugins/uberdev/lib/solve-launcher.sh" "$ROOT/codex/uberdev-codex/lib/solve-launcher.sh"
grep -q 'finish_branch.review_pr' "$ROOT/codex/uberdev-codex/skills/finish-branch/SKILL.md"
grep -q 'uberdev_dispatch_child' "$ROOT/codex/uberdev-codex/skills/post-impl-review/SKILL.md"

for file in \
  plugins/uberdev/commands/review-pr.md \
  plugins/uberdev/commands/simplify.md \
  plugins/uberdev/skills/post-impl-review/SKILL.md; do
  grep -q 'uberdev_dispatch_child' "$ROOT/$file"
  grep -q 'uberdev_wait_child' "$ROOT/$file"
done

grep -q 'solve.issue.lead' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'UBERDEV_RUN_CARRIER_JSON' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'context_file' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'context_sha256' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'finish_branch.review_pr' "$ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
grep -q 'review_pr.post_impl_review' "$ROOT/plugins/uberdev/commands/review-pr.md"

for mirror in \
  codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md \
  codex/uberdev-codex/skills/uberdev-cmd-simplify/SKILL.md; do
  grep -q 'uberdev_dispatch_child' "$ROOT/$mirror"
  grep -q 'uberdev_wait_child' "$ROOT/$mirror"
done

# Provider invocations in Group-C command/skill sources must use the routed
# adapter. Historical discussion may name the legacy tool, but executable
# call syntax is forbidden.
if grep -nE '^[[:space:]]*(Task|spawn_agent)\(' \
  "$ROOT/plugins/uberdev/commands/review-pr.md" \
  "$ROOT/plugins/uberdev/commands/simplify.md" \
  "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"; then
  echo 'raw executable child call remains in Group C' >&2
  exit 1
fi

echo 'solve-run-tree: manifest, roles, mirrors, and routed markers passed'
