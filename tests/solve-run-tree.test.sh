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
# #510 -- the manifest must say what it governs and, just as importantly, what it
# does NOT. Deliberately shallow: this file is the manifest's schema oracle, so its
# job is to make the block undeletable. The semantic comparison against the agents
# the Workflow fleet actually dispatches lives in tests/solve-run-tree-scope.test.sh,
# which derives the live half BY EXECUTING the fleet script.
scope=tree.get('scope')
assert isinstance(scope,dict) and isinstance(scope.get('governs'),dict), 'manifest declares no scope.governs block'
assert isinstance(scope.get('does_not_govern'),list) and scope['does_not_govern'], 'scope.does_not_govern is missing or empty'
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
 'review_pr.ci.resolve_conflict','review_pr.verify.finding'
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
    'phase1-reviewer-v1':'shared/phase1-reviewer-output-v1.md',
    'finding-verifier-v1':'shared/finding-verifier-output-v1.md',
    'code-fixer-v1':'shared/code-fixer-output-v1.md',
    'sdd-implementer-v1':'shared/sdd-implementer-output-v1.md'
}
for contract_id,relative in tree['output_contracts'].items():
    assert (tree_path.parent.parent/relative).is_file(), contract_id
# #517 -- the SDD implementer edge is the one PROVIDER edge whose card declared a
# terminal vocabulary the controller never agreed to. Unbound, lib/child-dispatch.sh
# appends its contract-less fallback directive ("Return completed, blocked, or
# refused."), which overrides the card's own wording at the END of the assembled
# prompt and makes DONE_WITH_CONCERNS / NEEDS_CONTEXT unreachable -- so
# `context_rounds` bounded a state that could not occur. Pinned by id so the
# binding cannot be dropped silently.
assert edges['sdd.task.implement'].get('output_contract')=='sdd-implementer-v1'
# #474 -- the fixer edges are format-bound the same way the reviewer edges are.
# A fixer COMMITS before its result is parsed, so an unbound format is not a
# retryable refusal like a reviewer's: it strands unattributed history and halts
# the run MUTATED_BLOCKED. Pinned as a set so a fourth fixer edge added later
# cannot quietly ship unbound.
fixer_edges={'review_pr.fix.phase1','review_pr.fix.phase2','simplify.fix.phase2'}
assert {e for e,row in edges.items() if row.get('output_contract')=='code-fixer-v1'}==fixer_edges
# SRT-546.1 (#546) -- the provider edges that carry NO output_contract. With no
# contract to embed, lib/child-dispatch.sh's terminal directive is the LAST word
# the child reads about what to return, so on these edges it may only POINT AT
# the role card and must never NAME a terminal vocabulary of its own -- naming
# one silently overrides whatever the card declared. That override was #517's
# root cause on sdd.task.implement and #546's on the rest of this set.
# Enumerated, never counted: this set SHRINKS as edges get bound, and a bare
# len(...)==32 would rot the moment any new provider edge is added, because the
# count can stay 32 while the membership silently changes. A PR that binds an
# edge therefore deletes one obvious line below; a PR that adds an unbound
# provider edge adds one, and has to have read this comment to do it.
unbound_provider_edges={
 'brainstorm.research.codebase','brainstorm.research.library',
 'brainstorm.research.prior_art','orchestrator.plan.research.dependency',
 'orchestrator.plan.research.risks','orchestrator.plan.research.security',
 'orchestrator.plan.research.tests','orchestrator.plan.review',
 'orchestrator.plan.write','orchestrator.research.codebase',
 'orchestrator.research.constraints','orchestrator.research.followup',
 'orchestrator.research.patterns','orchestrator.research.prior_art',
 'orchestrator.research.security','orchestrator.research.test_coverage',
 'orchestrator.spec.review','orchestrator.spec.revise','orchestrator.spec.write',
 'review_pr.ci.classify','review_pr.ci.defer_refusal','review_pr.ci.fix_code',
 'review_pr.ci.rebase','review_pr.ci.resolve_conflict','review_pr.defer.findings',
 'review_pr.simplify.efficiency','review_pr.simplify.quality',
 'review_pr.simplify.reuse','sdd.premerge.test_review','sdd.task.quality_review',
 'sdd.task.spec_review','solve.issue.lead'
}
assert {edge_id for edge_id,row in edges.items()
        if row['kind']=='provider' and row.get('output_contract') is None}==unbound_provider_edges
# SRT-546.2 -- the one role-less member of that set, explained where it is
# asserted so it does not read as an oversight. solve.issue.lead is the run's
# ROOT edge: it has no role card, so _uberdev_child_prepare never composes a
# prompt for it and it reads no terminal directive at all. It belongs to the set
# above because it is an unbound provider edge, not because it is a child whose
# return vocabulary is at stake -- 31 of the 32 are composable, this one is not.
assert edges['solve.issue.lead'].get('role') is None
assert tree['root_edge_id']=='solve.issue.lead'
for edge_id in review_edges:
    assert edges[edge_id]['required'] is True, edge_id
    assert edges[edge_id]['retry']=={'format':1}, edge_id
    assert edges[edge_id]['required_inputs']['changed_paths']=='repo_path_array', edge_id
    assert edges[edge_id]['output_contract']=='phase1-reviewer-v1', edge_id
# The Phase 1 verification gate (#431). One child per eligible finding, so the
# cardinality is per-finding and not per-iteration; read-only, so it stays in
# the default `isolated` workspace and out of `caller_edges` below.
verify=edges['review_pr.verify.finding']
assert verify['required'] is True
assert verify['retry']=={'format':1}
assert verify['output_contract']=='finding-verifier-v1'
assert verify['role']=='finding-verifier'
assert verify['risk_scope']=='subtask'
assert verify['phase']=='verify_finding'
assert verify['cardinality']=='one_per_eligible_finding_per_review_iteration'
assert verify['allowed_workflows']==['review-pr']
assert verify.get('workspace_mode','isolated')=='isolated'
assert verify['required_inputs']=={
 'claim_path':'path','diff_path':'path','pr_context_path':'path',
 'rubric_path':'path','working_dir':'directory'
}
assert verify['optional_inputs']=={
 'claude_md_paths':'optional_path_array',
 'format_retry':'boolean','format_example_path':'path'
}
# The claim card is the mechanical half of the withholding: the verifier edge
# must not be able to ask for the aggregate, the disposition, or the reviewer's
# own reasoning by name.
assert not ({'findings_path','phase1_path','aggregate_path','detail','authority_path'}
            & (set(verify['required_inputs'])|set(verify['optional_inputs'])))
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

# The four Codex-mirror assertions here (policy byte-equality, launcher
# byte-equality, and the two ported-SKILL greps) went with the Codex tree in
# issue #381. Their Claude-tree counterparts are asserted below.

# One entry per routed-child LIFECYCLE, not per file. /review-pr's is split
# across two files: the command dispatches, and lib/review-fences.sh holds the
# builders it calls -- they had to leave the markdown because a function defined
# in a ```bash fence is unreachable from the next fence (#427). Grepping the
# command alone would have found no `uberdev_wait_child` at all and reported the
# routed adapter missing; grepping the pair keeps the assertion about the
# lifecycle it was written for.
for files in \
  'plugins/uberdev/commands/review-pr.md plugins/uberdev/lib/review-fences.sh' \
  'plugins/uberdev/commands/simplify.md' \
  'plugins/uberdev/skills/post-impl-review/SKILL.md'; do
  lifecycle=''
  for file in $files; do lifecycle="$lifecycle$(cat "$ROOT/$file")"; done
  grep -q 'uberdev_dispatch_child' <<<"$lifecycle"
  grep -q 'uberdev_wait_child' <<<"$lifecycle"
done

grep -q 'solve.issue.lead' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'UBERDEV_RUN_CARRIER_JSON' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'context_file' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'context_sha256' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'finish_branch.review_pr' "$ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"
grep -q 'review_pr.post_impl_review' "$ROOT/plugins/uberdev/commands/review-pr.md"

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
