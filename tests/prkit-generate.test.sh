#!/usr/bin/env bash
# tests/prkit-generate.test.sh — end-to-end: generate a prkit tree into a scratch
# target, assert the verify gate passes, and assert determinism (two runs identical).
# Unix-only (perl + python3 + jq); declared in the test.yml windows-skip marker.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/prkit/generate.sh"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit generate e2e (RFC 0014)"
[ -r "$GEN" ] || { echo "  ABORT — generate.sh missing"; exit 99; }

# T1's path deliberately CONTAINS A SPACE ("prkit tgt") — the real target lives at
# "/Volumes/FJK SSD/Cursor/prkit", and an earlier verify.sh regression word-split on
# that space. Keeping a spaced target here locks the fix in. T2 is space-free so G5
# also proves the generated output is independent of the target path.
_B1="$(mktemp -d)"; _B2="$(mktemp -d)"; T1="$_B1/prkit tgt"; T2="$_B2/out"
mkdir -p "$T1" "$T2"; trap 'rm -rf "$_B1" "$_B2"' EXIT
git -C "$T1" init -q; git -C "$T2" init -q

# G1 — generate into a clean target succeeds and self-verifies
if bash "$GEN" --target "$T1" --version 0.1.0 >/dev/null 2>&1; then ok "G1 generate exits 0 (verify passed)"; else no "G1 generate failed"; fi

# G2 — verify gate independently passes on the produced tree
if bash "$VERIFY" "$T1" >/dev/null 2>&1; then ok "G2 verify passes on generated tree"; else no "G2 verify failed on generated tree"; fi

# G3 — EXACTLY 34 source files landed under plugins/prkit (manifest count-lock;
# -eq not -ge so a silently-dropped copy OR a stray extra file both fail)
n=$(find "$T1/plugins/prkit/commands" "$T1/plugins/prkit/agents" "$T1/plugins/prkit/skills" "$T1/plugins/prkit/lib" "$T1/plugins/prkit/policy" "$T1/plugins/prkit/shared" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 34 ] && ok "G3 exactly 34 copied files present" || no "G3 copied $n files (expected 34)"

# G4 — scaffold files exist with interpolated version
grep -q '0.1.0' "$T1/plugins/prkit/.claude-plugin/plugin.json" && ok "G4 plugin.json version interpolated" || no "G4 plugin.json version missing"
[ -f "$T1/README.md" ] && [ -f "$T1/.claude-plugin/marketplace.json" ] && ok "G4b README + marketplace scaffolded" || no "G4b scaffold files missing"

# G5 — determinism: second generation into a fresh target is byte-identical
bash "$GEN" --target "$T2" --version 0.1.0 >/dev/null 2>&1
if diff -r "$T1/plugins/prkit" "$T2/plugins/prkit" >/dev/null 2>&1; then ok "G5 deterministic (diff -r empty)"; else no "G5 non-deterministic output"; fi

# G6 — Codex port generated: prkit-cmd-* skills, renamed TOML, installer, manifest,
# and prkit-PREFIXED support skills (flat ~/.agents/skills/ coexistence) with NO
# un-prefixed post-impl-review/merge-pipeline dir that would collide with UberDev-codex
if [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-post-impl-review/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-merge-pipeline/SKILL.md" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/post-impl-review" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/merge-pipeline" ] \
   && [ -f "$T1/codex/agents/prkit-code-reviewer.toml" ] \
   && [ -f "$T1/codex/install-codex.sh" ] \
   && grep -q '"name": "prkit-codex"' "$T1/codex/prkit-codex/.codex-plugin/plugin.json"; then
  ok "G6 codex port generated (prkit-cmd-* + prkit-prefixed support skills, no flat collision)"
else no "G6 codex port incomplete or has un-prefixed support skill"; fi

# G6a — the copied full-UberDev installer is rewritten to the standalone
# manifest's actual fleet size. These hints are user-facing verification, so a
# successful install must not claim the full 39/44 fleet.
if grep -qF '# 5 prkit skills' "$T1/codex/install-codex.sh" \
   && grep -qF '# 14 prkit-*.toml subagents' "$T1/codex/install-codex.sh" \
   && grep -qF 'NOT the 14 agents' "$T1/codex/install-codex.sh" \
   && ! grep -Eq '(^|[^0-9])(39|44)([^0-9]|$)' "$T1/codex/install-codex.sh"; then
  ok "G6a standalone installer reports the manifest-true 5 skills / 14 agents"
else no "G6a standalone installer retains full-UberDev fleet counts"; fi

# G6aa — exercise the rewrite transaction itself against synthetic drift. A
# traversal/count mismatch and a missing substitution anchor must both fail
# before touching the installer.
if python3 -I -B - "$GEN" <<'PY'
import pathlib,subprocess,sys,tempfile
source=pathlib.Path(sys.argv[1]).read_text()
marker='  python3 -I -B - "$TARGET" <<\'PY\' || {'
snippet=source.split(marker,1)[1].split('\nPY\n',1)[0]
anchors='NOT the 44 agents\n# ~39 Prkit skills incl. command-skills\n# 44 prkit-*.toml subagents\n'
def fixture(skills,installer_text):
 root=pathlib.Path(tempfile.mkdtemp()); (root/'codex/prkit-codex/skills').mkdir(parents=True); (root/'codex/agents').mkdir()
 for index in range(skills): (root/f'codex/prkit-codex/skills/s{index}').mkdir()
 for index in range(14): (root/f'codex/agents/prkit-a{index}.toml').write_text('x')
 target=root/'codex/install-codex.sh'; target.write_text(installer_text)
 return root,target
for root,target in (fixture(6,anchors),fixture(5,anchors.replace('NOT the 44 agents','anchor drift'))):
 before=target.read_bytes()
 result=subprocess.run([sys.executable,'-I','-B','-',str(root)],input=snippet,text=True,capture_output=True)
 assert result.returncode!=0,result
 assert target.read_bytes()==before
PY
then ok "G6aa count discovery and anchor drift fail closed without mutation"
else no "G6aa generator count/anchor transaction accepted drift"; fi

# G6ab — projection accepts only the canonical edge semantics and publishes
# atomically. Relationship drift must fail before mutation; an injected replace
# failure must preserve the copied policy and remove its temporary artifact.
if python3 -I -B - "$GEN" "$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json" <<'PY'
import json,os,pathlib,subprocess,sys,tempfile
generator=pathlib.Path(sys.argv[1]).read_text()
canonical=pathlib.Path(sys.argv[2]).read_bytes()
marker='  python3 -I -B - "$policy" "$roles_dir" "$role_prefix" "$role_suffix" <<\'PY\' || return 1\n'
snippet=generator.split(marker,1)[1].split('\nPY\n',1)[0]
roles={
 'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
 'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
 'findings-to-issues','merge-strategy-decider','pr-test-analyzer',
 'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
def fixture():
 root=pathlib.Path(tempfile.mkdtemp())
 policy=root/'solve-run-tree-v1.json'; policy.write_bytes(canonical)
 agents=root/'agents'; agents.mkdir()
 for role in roles: (agents/f'{role}.md').write_text('fixture\n')
 return root,policy,agents
def reject_mutation(mutate):
 root,policy,agents=fixture(); tree=json.loads(policy.read_text()); mutate(tree)
 policy.write_text(json.dumps(tree,sort_keys=True,indent=2)+'\n'); before=policy.read_bytes()
 result=subprocess.run([sys.executable,'-I','-B','-',str(policy),str(agents),'','.md'],input=snippet,text=True,capture_output=True)
 assert result.returncode!=0,result
 assert policy.read_bytes()==before
 assert not list(root.glob('.solve-run-tree.*'))
def swap_roles(tree):
 left=tree['edges']['review_pr.review.correctness']; right=tree['edges']['review_pr.review.comments']
 left['role'],right['role']=right['role'],left['role']
def swap_workflows(tree):
 left=tree['edges']['review_pr.fix.phase1']; right=tree['edges']['review_pr.fix.phase2']
 left['allowed_workflows'],right['allowed_workflows']=right['allowed_workflows'],left['allowed_workflows']
def attach_contract(tree):
 tree['edges']['review_pr.fix.phase1']['output_contract']='phase1-reviewer-v1'
for mutation in (swap_roles,swap_workflows,attach_contract): reject_mutation(mutation)
root,policy,agents=fixture(); before=policy.read_bytes(); env=os.environ.copy()
env['PRKIT_GENERATOR_TEST_MODE']='1'; env['PRKIT_TEST_POLICY_PUBLISH_FAIL']='1'
result=subprocess.run([sys.executable,'-I','-B','-',str(policy),str(agents),'','.md'],input=snippet,text=True,capture_output=True,env=env)
assert result.returncode!=0,result
assert policy.read_bytes()==before
assert not list(root.glob('.solve-run-tree.*'))
PY
then ok "G6ab policy projection enforces canonical edge semantics and atomic failure cleanup"
else no "G6ab policy projection accepted relationship drift or leaked partial publication"; fi

# G6b — both standalone runtimes ship one byte-identical, review-only policy
# projection and the manifest-declared reviewer contract, while native Codex
# role TOMLs remain edge-agnostic.
if [ -f "$T1/plugins/prkit/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/plugins/prkit/shared/phase1-reviewer-output-v1.md" ] \
   && [ -f "$T1/codex/prkit-codex/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/codex/prkit-codex/shared/phase1-reviewer-output-v1.md" ] \
   && python3 -I -B - "$T1" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
claude_path=root/'plugins/prkit/policy/solve-run-tree-v1.json'
codex_path=root/'codex/prkit-codex/policy/solve-run-tree-v1.json'
assert claude_path.read_bytes()==codex_path.read_bytes()

def reject_pairs(pairs):
 result={}
 for key,value in pairs:
  if key in result: raise ValueError(f'duplicate JSON key: {key}')
  result[key]=value
 return result

tree=json.loads(
 claude_path.read_text(),
 object_pairs_hook=reject_pairs,
 parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f'non-finite JSON constant: {value}')),
)
assert set(tree)=={'schema_version','tree_id','root_edge_id','output_contracts','edges'}
edges=tree['edges']; assert edges
expected_roles={
 'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
 'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
 'findings-to-issues','merge-strategy-decider','pr-test-analyzer',
 'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
claude_roles={path.stem for path in (root/'plugins/prkit/agents').glob('*.md')}
codex_roles={path.name.removeprefix('prkit-').removesuffix('.toml') for path in (root/'codex/agents').glob('prkit-*.toml')}
assert claude_roles==codex_roles==expected_roles
structural_edges={'review_pr.post_impl_review'}
provider_edges={
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.simplify.reuse',
 'review_pr.simplify.quality','review_pr.simplify.efficiency',
 'review_pr.fix.phase2','review_pr.defer.findings','review_pr.ci.classify',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict',
}
assert set(edges)==structural_edges|provider_edges
assert all(edges[edge_id].get('kind')=='skill' for edge_id in structural_edges)
assert all(edges[edge_id].get('kind')=='provider' for edge_id in provider_edges)
for edge in edges.values():
 workflows=edge.get('allowed_workflows',[])
 assert all(workflow in {'review-pr','simplify','solve','turbo'} for workflow in workflows)
 if edge.get('kind')=='provider':
  assert workflows
  assert edge.get('role') in claude_roles
for edge_id in (
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.ci.classify',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict',
):
 assert edges[edge_id]['allowed_workflows']==['review-pr','solve','turbo'], edge_id
for edge_id in (
 'review_pr.simplify.reuse','review_pr.simplify.quality',
 'review_pr.simplify.efficiency','review_pr.fix.phase2','review_pr.defer.findings',
):
 assert edges[edge_id]['allowed_workflows']==['review-pr','simplify','solve','turbo'], edge_id
referenced={edge['output_contract'] for edge in edges.values() if 'output_contract' in edge}
assert set(tree.get('output_contracts',{}))==referenced
contract=(root/'codex/prkit-codex/shared/phase1-reviewer-output-v1.md').read_text()
roles=('code-reviewer','silent-failure-hunter','type-design-analyzer','comment-analyzer','pr-test-analyzer')
assert all(contract not in (root/f'codex/agents/prkit-{role}.toml').read_text() for role in roles)
PY
then ok "G6b review-only policy is identical, closed, and contract-scoped across runtimes"
else no "G6b standalone policy projection or reviewer contract scope is incorrect"; fi

# G6c — the generated standalone Codex runtime must execute the focused
# six-reviewer happy path, not merely pass structural namespace scans.
if SIX_CHILD_RUNTIME_ROOT="$T1/codex/prkit-codex" \
   SIX_CHILD_RUNTIME_NAMESPACE=prkit SIX_CHILD_CASE=1 \
   bash "$REPO_ROOT/tests/review-pr-codex-six-child.test.sh" >/dev/null 2>&1; then
  ok "G6c generated standalone prkit executes six-child review path"
else no "G6c generated standalone prkit six-child runtime failed"; fi

# G7 — no uberdev token survives anywhere under codex/
if grep -rilE 'uberdev' "$T1/codex" >/dev/null 2>&1; then no "G7 uberdev token survives under codex/"; else ok "G7 codex tree is uberdev-free"; fi

# G8 — codex tree deterministic across the two generations (spaced vs plain path)
if diff -r "$T1/codex" "$T2/codex" >/dev/null 2>&1; then ok "G8 codex deterministic (diff -r empty)"; else no "G8 codex non-deterministic"; fi

# G9 — regeneration CLEANS stale files (the rm -rf clean stage). Plant strays in
# both trees, regenerate into the SAME target, assert they are gone.
printf 'stale\n' > "$T1/plugins/prkit/STALE_CLAUDE.txt"
printf 'stale\n' > "$T1/codex/STALE_CODEX.txt"
bash "$GEN" --target "$T1" --version 0.1.0 --force >/dev/null 2>&1
if [ ! -e "$T1/plugins/prkit/STALE_CLAUDE.txt" ] && [ ! -e "$T1/codex/STALE_CODEX.txt" ]; then
  ok "G9 regeneration removes stale files from both trees"
else no "G9 stale files survived regeneration"; fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
