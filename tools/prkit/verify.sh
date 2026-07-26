#!/usr/bin/env bash
# tools/prkit/verify.sh — prkit generation verify gate (RFC 0014 §5.6 + Codex addendum).
#   verify.sh <target-repo-root>
# Exit 0 iff the generated tree is correct. Prints each check. Covers the Claude
# plugin (plugins/prkit, always) and the Codex port (codex/, when generated).
#
# Design invariant (issue #334 review): NO check may pass VACUOUSLY. An empty scan,
# an errored grep (rc>=2), or a zero-file find is treated as a FAIL, never silently
# as "clean" — the [[jq_echo0_masks_crash]] class. Every scanning check asserts it
# actually saw files/refs before it can report OK.
set -u
set -o pipefail

ROOT="${1:-}"
[ -n "$ROOT" ] && [ -d "$ROOT/plugins/prkit" ] || { echo "verify: no plugins/prkit under '$ROOT'"; exit 2; }
P="$ROOT/plugins/prkit"
# Scan roots: the Claude plugin (always) + the Codex port (if generated). Array
# form keeps this space-safe for target paths like "/Volumes/FJK SSD/...".
SCAN=("$P")
[ -d "$ROOT/codex" ] && SCAN+=("$ROOT/codex")
rc=0
fail(){ echo "  FAIL  $1"; rc=1; }
ok(){ echo "  OK    $1"; }
echo "## prkit verify <$ROOT>"

# --- 0. Non-vacuity: the scan roots actually contain files ---
SCANNED_FILES=$(find "${SCAN[@]}" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "${SCANNED_FILES:-0}" -lt 20 ]; then fail "non-vacuity: only ${SCANNED_FILES:-0} files under scan roots — generation likely broke"
else ok "non-vacuity: $SCANNED_FILES files under scan roots"; fi

# --- 1. Token guard: no uberdev anywhere in the shipped trees. grep exit codes:
# 0 = matched (LEAK, fail), 1 = no match (clean), >=2 = grep ERROR (cannot certify
# clean -> fail; the || true trap that hides a crashed/permission-denied scan). ---
tok=$(grep -rilE 'uberdev' "${SCAN[@]}" 2>/dev/null); grc=$?
case "$grc" in
  0) fail "token-guard: uberdev survives in:"; echo "$tok" | sed 's/^/         /' ;;
  1) ok "token-guard: no uberdev token (plugins/prkit${SCAN[1]:+ + codex})" ;;
  *) fail "token-guard: token scan errored (grep rc=$grc) — cannot certify clean" ;;
esac

# --- 2. Residual out-of-set command refs (prkit:goal / prkit:solve), same exit-code discipline ---
oos=$(grep -rEl '(^|[^a-z])prkit:(goal|solve)|/prkit:(goal|solve)' "${SCAN[@]}" 2>/dev/null); orc=$?
case "$orc" in
  0) fail "out-of-set: prkit:goal/solve survives in: $oos" ;;
  1) ok "out-of-set: no prkit:goal/solve reference" ;;
  *) fail "out-of-set: scan errored (grep rc=$orc)" ;;
esac

# --- 3. Referential integrity: every dispatched prkit:X agent has agents/X.md
# (Claude tree only). Assert refs were actually found — 0 refs means the dispatch
# syntax the regex keys off vanished (a broken copy/rewrite), not a genuine pass. ---
AGENT_REFS=$(grep -rhoE 'subagent_type[:=][[:space:]]*prkit:[a-z0-9-]+' "$P" 2>/dev/null | sed -E 's/.*prkit://' | sort -u)
if [ -z "$AGENT_REFS" ]; then fail "ref-int: found ZERO dispatched prkit: agent refs — expected several (broken tree?)"
else
  missing_agents=$(printf '%s\n' "$AGENT_REFS" | while read -r a; do [ -n "$a" ] && { [ -f "$P/agents/$a.md" ] || echo "$a"; }; done)
  if [ -n "$missing_agents" ]; then fail "ref-int: agents missing:"; printf '%s\n' "$missing_agents" | sed 's/^/         /'
  else ok "ref-int: all $(printf '%s\n' "$AGENT_REFS" | grep -c .) dispatched agents exist"; fi
fi

# --- 4. Referential integrity: every Skill(prkit:X) has skills/X/SKILL.md ---
SKILL_REFS=$(grep -rhoE 'Skill\(prkit:[a-z0-9-]+' "$P" 2>/dev/null | sed -E 's/.*prkit://' | sort -u)
if [ -z "$SKILL_REFS" ]; then fail "ref-int: found ZERO Skill(prkit:X) refs — expected at least post-impl-review"
else
  missing_skills=$(printf '%s\n' "$SKILL_REFS" | while read -r s; do [ -n "$s" ] && { [ -f "$P/skills/$s/SKILL.md" ] || echo "$s"; }; done)
  if [ -n "$missing_skills" ]; then fail "ref-int: skills missing:"; printf '%s\n' "$missing_skills" | sed 's/^/         /'
  else ok "ref-int: all invoked skills exist"; fi
fi

# --- 5. Out-of-set namespace gate: every prkit:<name> reference must resolve to a
# shipped command/agent/skill OR an allowlisted label (`active`, `*-finding`).
# Backstops the neutralizer's de-namespace: a NEW UberDev skill it didn't strip
# would surface here as a dangling prkit:<name> and fail generation. ---
SHIPPED="$(mktemp)"
{ ls "$P/commands" 2>/dev/null | sed 's/\.md$//'
  ls "$P/agents" 2>/dev/null | sed 's/\.md$//'
  for d in "$P/skills"/*/; do [ -d "$d" ] && basename "$d"; done
} | sort -u > "$SHIPPED"
OOS_BAD=$(grep -rhoE 'prkit:[a-z][a-z0-9-]+' "$P" 2>/dev/null | sed 's/prkit://' | sort -u | while read -r n; do
  case "$n" in ''|active|*-finding) continue;; esac
  grep -qxF "$n" "$SHIPPED" || echo "$n"
done)
rm -f "$SHIPPED"
if [ -n "$OOS_BAD" ]; then fail "out-of-set: dangling prkit:<name> (not shipped, not a label):"; printf '%s\n' "$OOS_BAD" | sed 's/^/         prkit:/'
else ok "out-of-set: every prkit:<name> resolves to a shipped item or label"; fi

# --- 6. Syntax: shell / python / json / toml. Each requires a plausible file count
# (>0 of the types the tree is known to contain) so a catastrophic empty copy can't
# read as "clean". Space-safe NUL-find + current-shell loop. ---
sh_n=0; serr=0
while IFS= read -r -d '' f; do sh_n=$((sh_n+1)); bash -n "$f" 2>/dev/null || { echo "         bash -n failed: $f"; serr=1; }; done < <(find "${SCAN[@]}" -name '*.sh' -print0 2>/dev/null)
if [ "$sh_n" -eq 0 ]; then fail "syntax: found ZERO .sh files — expected many (broken copy?)"
elif [ "$serr" -ne 0 ]; then fail "syntax: shell errors"
else ok "syntax: bash -n clean ($sh_n files)"; fi
py_n=0; perr=0
# ast.parse validates syntax WITHOUT emitting __pycache__/*.pyc (py_compile would
# pollute the tree with non-deterministic bytecode). Artifact-free + deterministic.
while IFS= read -r -d '' f; do py_n=$((py_n+1)); python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" 2>/dev/null || { echo "         py syntax failed: $f"; perr=1; }; done < <(find "${SCAN[@]}" -name '*.py' -print0 2>/dev/null)
if [ "$py_n" -eq 0 ]; then fail "syntax: found ZERO .py files — expected several (broken copy?)"
elif [ "$perr" -ne 0 ]; then fail "syntax: python errors"
else ok "syntax: python parse clean ($py_n files)"; fi
jerr=0
while IFS= read -r -d '' f; do jq empty "$f" 2>/dev/null || { echo "         jq failed: $f"; jerr=1; }; done < <(find "${SCAN[@]}" -name '*.json' -print0 2>/dev/null)
[ "$jerr" -eq 0 ] && ok "syntax: jq clean" || fail "syntax: json errors"
# TOML (Codex agents) — only when tomllib is available (py>=3.11); skip gracefully otherwise.
if [ -d "$ROOT/codex" ]; then
  if python3 -c 'import tomllib' 2>/dev/null; then
    terr=0
    while IFS= read -r -d '' f; do python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null || { echo "         toml parse failed: $f"; terr=1; }; done < <(find "$ROOT/codex" -name '*.toml' -print0 2>/dev/null)
    [ "$terr" -eq 0 ] && ok "syntax: toml parse clean" || fail "syntax: toml errors"
  else
    ok "syntax: toml check skipped (no tomllib)"
  fi
fi

# --- 7. Required tree shape ---
for req in "commands/review-pr.md" "commands/simplify.md" "commands/merge.md" \
           "skills/post-impl-review/SKILL.md" "skills/merge-pipeline/SKILL.md" \
           "policy/model-routing-v1.json" "policy/solve-run-tree-v1.json" \
           "shared/phase1-reviewer-output-v1.md" ".claude-plugin/plugin.json"; do
  [ -e "$P/$req" ] || fail "shape: missing $req"
done
ok "shape: claude required-file presence checked"
if [ -d "$ROOT/codex" ]; then
  for req in "codex/prkit-codex/.codex-plugin/plugin.json" \
             "codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" \
             "codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" \
             "codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" \
             "codex/prkit-codex/skills/prkit-post-impl-review/SKILL.md" \
             "codex/prkit-codex/skills/prkit-merge-pipeline/SKILL.md" \
             "codex/prkit-codex/policy/solve-run-tree-v1.json" \
             "codex/prkit-codex/shared/phase1-reviewer-output-v1.md" \
             "codex/install-codex.sh" "codex/README.md" "codex/AGENTS.md"; do
    [ -e "$ROOT/$req" ] || fail "shape: missing $req"
  done
  # Coexistence: NO un-prefixed skill dir may exist in the flat Codex skills space
  # (would collide with an UberDev-for-Codex install in ~/.agents/skills/).
  for bad in post-impl-review merge-pipeline; do
    [ -e "$ROOT/codex/prkit-codex/skills/$bad" ] && fail "shape: un-prefixed codex skill dir '$bad' would collide"
  done
  ok "shape: codex required-file presence + prkit-prefixed skills checked"
fi

# --- 7b. Standalone review-policy integrity: strict JSON, review-only closure,
# shipped provider roles/workflows/contracts, deterministic serialization, and
# byte equality across Claude/Codex. Native Codex roles stay edge-local. ---
if python3 -I -B - "$ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected_roles={
    'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
    'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
    'findings-to-issues','merge-strategy-decider','pr-test-analyzer',
    'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
allowed_workflows={'review-pr','simplify'}
review_edges={
    'review_pr.review.correctness','review_pr.review.silent_failures',
    'review_pr.review.types','review_pr.review.comments',
    'review_pr.review.tests','review_pr.review.general',
}
contract_rel='shared/phase1-reviewer-output-v1.md'
structural_edges={'review_pr.post_impl_review'}
provider_edges={
    'review_pr.review.correctness','review_pr.review.silent_failures',
    'review_pr.review.types','review_pr.review.comments',
    'review_pr.review.tests','review_pr.review.general',
    'review_pr.fix.phase1','review_pr.simplify.reuse',
    'review_pr.simplify.quality','review_pr.simplify.efficiency',
    'review_pr.fix.phase2','review_pr.defer.findings','review_pr.ci.classify',
    'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
    'review_pr.ci.resolve_conflict',
}
expected_edges=structural_edges|provider_edges

claude_roles={path.stem for path in (root/'plugins/prkit/agents').glob('*.md')}
codex_roles={
    path.name.removeprefix('prkit-').removesuffix('.toml')
    for path in (root/'codex/agents').glob('prkit-*.toml')
}
assert claude_roles==expected_roles, ('claude role fleet',sorted(claude_roles))
assert codex_roles==expected_roles, ('codex role fleet',sorted(codex_roles))
assert claude_roles==codex_roles
shipped_roles=claude_roles

def reject_pairs(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise ValueError(f'duplicate JSON key: {key}')
        result[key]=value
    return result

def reject_constant(value):
    raise ValueError(f'non-finite JSON constant: {value}')

def strict_load(raw):
    return json.loads(
        raw.decode('utf-8'),
        object_pairs_hook=reject_pairs,
        parse_constant=reject_constant,
    )

def validate(plugin):
    policy=plugin/'policy/solve-run-tree-v1.json'
    raw=policy.read_bytes()
    tree=strict_load(raw)
    canonical=(json.dumps(tree,sort_keys=True,allow_nan=False,indent=2)+'\n').encode()
    assert raw==canonical, f'non-deterministic policy serialization: {policy}'
    assert set(tree)=={'schema_version','tree_id','root_edge_id','output_contracts','edges'}
    assert tree.get('schema_version')==1
    assert tree.get('tree_id')=='review-pr-run-tree-v1'
    assert tree.get('root_edge_id')=='review_pr.post_impl_review'
    edges=tree.get('edges')
    assert isinstance(edges,dict) and edges
    assert set(edges)==expected_edges
    assert all(edges[edge_id].get('kind')=='skill' for edge_id in structural_edges)
    assert all(edges[edge_id].get('kind')=='provider' for edge_id in provider_edges)
    referenced_contracts=set()
    for edge_id,edge in edges.items():
        assert isinstance(edge,dict), edge_id
        role=edge.get('role')
        if role is not None: assert role in shipped_roles, edge_id
        workflows=edge.get('allowed_workflows')
        if workflows is not None:
            assert isinstance(workflows,list) and workflows, edge_id
            assert all(isinstance(workflow,str) and workflow in allowed_workflows for workflow in workflows), edge_id
            assert workflows==[workflow for workflow in ('review-pr','simplify') if workflow in workflows], edge_id
        if edge.get('kind')=='provider':
            assert role in shipped_roles, edge_id
            assert workflows, edge_id
        if 'output_contract' in edge:
            contract_id=edge['output_contract']
            assert isinstance(contract_id,str) and contract_id
            referenced_contracts.add(contract_id)
    contracts=tree.get('output_contracts')
    assert isinstance(contracts,dict)
    assert set(contracts)==referenced_contracts
    for contract_id,contract_path in contracts.items():
        assert isinstance(contract_id,str) and contract_id
        assert isinstance(contract_path,str) and contract_path
        assert (plugin/contract_path).is_file(), contract_path
    assert contracts=={'phase1-reviewer-v1':contract_rel}
    for edge in review_edges:
        row=edges[edge]
        assert row.get('output_contract')=='phase1-reviewer-v1'
        assert row['required_inputs'].get('changed_paths')=='repo_path_array'
    return raw,(plugin/contract_rel).read_text()
claude_policy,claude_contract=validate(root/'plugins/prkit')
codex_plugin=root/'codex/prkit-codex'
if codex_plugin.is_dir():
    codex_policy,codex_contract=validate(codex_plugin)
    assert codex_policy==claude_policy
    assert codex_contract==claude_contract
    try:
        import tomllib
    except ModuleNotFoundError:
        tomllib=None
    if tomllib is not None:
        for role in ('code-reviewer','silent-failure-hunter','type-design-analyzer','comment-analyzer','pr-test-analyzer'):
            data=tomllib.loads((root/f'codex/agents/prkit-{role}.toml').read_text())
            assert codex_contract not in data['developer_instructions'], role
PY
then ok "review-policy: strict deterministic closure, shipped roles/workflows/contracts, runtime parity"
else fail "review-policy: projection, strict JSON, runtime parity, or contract scoping drift"; fi

# --- 8. Root scaffold files (outside the SCAN roots) — present, non-empty, valid ---
for req in README.md LICENSE NOTICE CHANGELOG.md .gitignore \
           .github/workflows/ci.yml .claude-plugin/marketplace.json; do
  [ -s "$ROOT/$req" ] || fail "scaffold: missing/empty $req"
done
jq empty "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null || fail "scaffold: marketplace.json is not valid JSON"
ok "scaffold: root files present, non-empty, marketplace.json valid"

# --- 9. No unrendered template placeholders leaked into generated output ---
PLH=$(grep -rlE '\{\{[A-Za-z_]+\}\}' "${SCAN[@]}" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null || true)
[ -z "$PLH" ] && ok "placeholders: no unrendered {{...}} in output" || { fail "placeholders: unrendered {{...}} in:"; echo "$PLH" | sed 's/^/         /'; }

echo "  Result: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
