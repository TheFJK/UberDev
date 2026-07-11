#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
MIRROR="$ROOT/codex/uberdev-codex/policy/solve-run-tree-v1.json"
POLICY="$ROOT/plugins/uberdev/policy/model-routing-v1.json"

python3 -I -B - "$TREE" "$POLICY" <<'PY'
import json,pathlib,re,sys
tree_path,policy_path=map(pathlib.Path,sys.argv[1:])
assert tree_path.is_file(), "solve run-tree manifest missing"
tree=json.loads(tree_path.read_text()); policy=json.loads(policy_path.read_text())
assert tree['schema_version']==1 and tree['tree_id']=='solve-run-tree-v1'
assert tree['root_edge_id']=='solve.issue.lead'
edges=tree['edges']; assert isinstance(edges,dict) and edges
edge_re=re.compile(r'[a-z][a-z0-9_-]{0,31}(?:\.[a-z][a-z0-9_-]{0,31}){0,3}$')
for edge_id,edge in edges.items():
    assert edge_re.fullmatch(edge_id), edge_id
    assert edge['kind'] in {'provider','skill'}
    assert edge['source'].startswith('plugins/uberdev/')
    assert edge['phase'] and edge['cardinality']
    if edge['kind']=='provider':
        role=edge.get('role')
        if role is not None: assert role in policy['roles'], (edge_id,role)
        assert edge.get('required') in {True,False}
        assert isinstance(edge.get('inputs'),list)
    else:
        assert edge.get('role') is None and edge.get('route') is None

required={
 'solve.issue.lead','finish_branch.review_pr','review_pr.post_impl_review',
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.simplify.reuse',
 'review_pr.simplify.quality','review_pr.simplify.efficiency',
 'review_pr.fix.phase2','review_pr.defer.findings','review_pr.ci.classify',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict'
}
assert required <= edges.keys(), sorted(required-edges.keys())
assert policy['roles']['spec-compliance-reviewer']=={
 'route':'deep','risk_floor':'deep','sandbox_ceiling':'read-only',
 'delegation_mode':'leaf','risk_judgment':True
}
PY

cmp "$TREE" "$MIRROR"
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
if rg -n '^[[:space:]]*(Task|spawn_agent)\(' \
  "$ROOT/plugins/uberdev/commands/review-pr.md" \
  "$ROOT/plugins/uberdev/commands/simplify.md" \
  "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"; then
  echo 'raw executable child call remains in Group C' >&2
  exit 1
fi

echo 'solve-run-tree: manifest, roles, mirrors, and routed markers passed'
