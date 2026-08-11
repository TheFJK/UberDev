#!/usr/bin/env bash
# tools/prkit/verify.sh — prkit generation verify gate (RFC 0014 §5.6).
#   verify.sh <target-repo-root>
# Exit 0 iff the generated tree is correct. Prints each check. Covers the Claude
# plugin (plugins/prkit). RFC 0014 §14's "mandatory native Codex port" clause is
# SUPERSEDED (2026-08-05, issue #381): the generator no longer emits a codex/
# tree, so this gate ASSERTS the retirement (check 10) rather than requiring the
# port. A target generated before #381 keeps its stale codex/ tree forever
# otherwise — no MANAGED_PATH covers a path the generator never writes.
#
# Design invariant (issue #334 review): NO check may pass VACUOUSLY. An empty scan,
# an errored grep (rc>=2), or a zero-file find is treated as a FAIL, never silently
# as "clean" — the [[jq_echo0_masks_crash]] class. Every scanning check asserts it
# actually saw files/refs before it can report OK.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PATH_GUARD="$HERE/managed-path-guard.py"
ROOT="${1:-}"
[ -n "$ROOT" ] || { echo "verify: target repo root required"; exit 2; }
[ -r "$PATH_GUARD" ] \
  || { echo "verify: managed path guard missing/unreadable: $PATH_GUARD"; exit 2; }

# Canonicalize the parent while preserving the root's final directory entry.
# The shared lstat guard can therefore reject a symlink/reparse-point root,
# rather than resolving it away before validation.
ROOT_PARENT="$(dirname "$ROOT")"
ROOT_NAME="$(basename "$ROOT")"
ROOT_PARENT="$(cd "$ROOT_PARENT" && pwd -P)" \
  || { echo "verify: cannot resolve target parent: $ROOT_PARENT"; exit 2; }
ROOT="$ROOT_PARENT/$ROOT_NAME"

# One cleanup owner covers every verifier-created temporary on normal exit and
# HUP/INT/TERM. There were no pre-existing traps in this script to chain; keep
# this as the single trap installation point so later checks cannot clobber it.
VERIFY_TEMP_PATHS=()
cleanup_verify_temp_paths(){
  # `temp_path`, never `path`: zsh ties `path` to `$PATH`, so declaring it local
  # would empty the command search path for this whole body — `rm` would stop
  # resolving and every temporary would leak while the loop reported failure.
  # Matches the `original_status` spelling in the EXIT handler just below.
  local i temp_path cleanup_failed=0
  for ((i=0; i<${#VERIFY_TEMP_PATHS[@]}; i++)); do
    temp_path="${VERIFY_TEMP_PATHS[$i]}"
    [ -n "$temp_path" ] || continue
    case "$temp_path" in
      /)
        echo "verify: refusing unsafe temporary cleanup target: $temp_path" >&2
        cleanup_failed=1
        ;;
      *)
        if rm -rf -- "$temp_path"; then
          VERIFY_TEMP_PATHS[$i]=""
        else
          echo "verify: temporary cleanup failed: $temp_path" >&2
          cleanup_failed=1
        fi
        ;;
    esac
  done
  return "$cleanup_failed"
}
cleanup_verify_on_exit(){
  local original_status=$?
  trap - EXIT HUP INT TERM
  if ! cleanup_verify_temp_paths; then
    [ "$original_status" -ne 0 ] || original_status=1
  fi
  exit "$original_status"
}
trap cleanup_verify_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

check_managed_path(){
  python3 -I -B "$PATH_GUARD" "$ROOT" "$1" "$2"
}

CLAUDE_REQUIRED=(
  "commands/review-pr.md"
  "commands/simplify.md"
  "commands/merge.md"
  "skills/post-impl-review/SKILL.md"
  "skills/merge-pipeline/SKILL.md"
  "policy/model-routing-v1.json"
  "policy/solve-run-tree-v1.json"
  "lib/code_fixer_contract.py"
  "shared/phase1-reviewer-output-v1.md"
  ".claude-plugin/plugin.json"
)
SCAFFOLD_REQUIRED=(
  "README.md"
  "LICENSE"
  "NOTICE"
  "CHANGELOG.md"
  ".gitignore"
  ".github/workflows/ci.yml"
  ".claude-plugin/marketplace.json"
)

# Containment is established before the first recursive find/grep. Root trees
# and known files must exist; a final sealed-tree walk rejects every nested
# link, Windows reparse point, socket/FIFO/device, or other special entry.
check_managed_path "plugins/prkit" required-tree \
  || { echo "verify: unsafe/missing generated tree: plugins/prkit"; exit 2; }
for req in "${CLAUDE_REQUIRED[@]}"; do
  check_managed_path "plugins/prkit/$req" required-file \
    || { echo "verify: unsafe/missing Claude file: $req"; exit 2; }
done
for req in "${SCAFFOLD_REQUIRED[@]}"; do
  check_managed_path "$req" required-file \
    || { echo "verify: unsafe/missing generated file: $req"; exit 2; }
done
check_managed_path "plugins/prkit" sealed-tree \
  || { echo "verify: generated tree is not sealed: plugins/prkit"; exit 2; }

P="$ROOT/plugins/prkit"
# Scan root: the Claude plugin. Array form keeps this space-safe for target
# paths like "/Volumes/FJK SSD/...".
SCAN=("$P")
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
  1) ok "token-guard: no uberdev token (plugins/prkit)" ;;
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
VERIFY_TEMP_PATHS+=("$SHIPPED")
{ ls "$P/commands" 2>/dev/null | sed 's/\.md$//'
  ls "$P/agents" 2>/dev/null | sed 's/\.md$//'
  for d in "$P/skills"/*/; do [ -d "$d" ] && basename "$d"; done
} | sort -u > "$SHIPPED"
OOS_BAD=$(grep -rhoE 'prkit:[a-z][a-z0-9-]+' "$P" 2>/dev/null | sed 's/prkit://' | sort -u | while read -r n; do
  [ -n "$n" ] || continue
  [ "$n" != "active" ] || continue
  [ "${n%-finding}" = "$n" ] || continue
  grep -qxF "$n" "$SHIPPED" || echo "$n"
done)
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
# --- 7. Required tree shape ---
for req in "${CLAUDE_REQUIRED[@]}"; do
  check_managed_path "plugins/prkit/$req" required-file \
    || fail "shape: missing/non-regular/link/reparse $req"
done
ok "shape: claude required-file presence checked"

# --- 7b. Standalone PR-policy integrity: strict JSON, closed PR-phase closure,
# shipped provider roles/workflows/contracts, deterministic serialization. ---
if python3 -I -B - "$ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected_roles={
    'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
    'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
    'convention-compliance','findings-to-issues','merge-strategy-decider',
    'pr-test-analyzer',
    'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
allowed_workflows={'review-pr','simplify','solve','turbo'}
contract_rel='shared/phase1-reviewer-output-v1.md'
review_contract='phase1-reviewer-v1'
edge_semantics={
    'review_pr.post_impl_review':('skill',None,None,None),
    'review_pr.review.correctness':('provider','code-reviewer',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.silent_failures':('provider','silent-failure-hunter',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.types':('provider','type-design-analyzer',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.comments':('provider','comment-analyzer',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.tests':('provider','pr-test-analyzer',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.general':('provider','code-reviewer',('review-pr','solve','turbo'),review_contract),
    'review_pr.review.convention':('provider','convention-compliance',('review-pr','solve','turbo'),review_contract),
    'review_pr.fix.phase1':('provider','code-fixer',('review-pr','solve','turbo'),None),
    'review_pr.simplify.reuse':('provider','code-simplifier',('review-pr','simplify','solve','turbo'),None),
    'review_pr.simplify.quality':('provider','code-simplifier',('review-pr','simplify','solve','turbo'),None),
    'review_pr.simplify.efficiency':('provider','code-simplifier',('review-pr','simplify','solve','turbo'),None),
    'review_pr.fix.phase2':('provider','code-fixer',('review-pr','solve','turbo'),None),
    'review_pr.defer.findings':('provider','findings-to-issues',('review-pr','simplify','solve','turbo'),None),
    'review_pr.ci.classify':('provider','ci-failure-classifier',('review-pr','solve','turbo'),None),
    'review_pr.ci.fix_code':('provider','ci-code-fixer',('review-pr','solve','turbo'),None),
    'review_pr.ci.rebase':('provider','ci-rebase-handler',('review-pr','solve','turbo'),None),
    'review_pr.ci.defer_refusal':('provider','findings-to-issues',('review-pr','solve','turbo'),None),
    'review_pr.ci.resolve_conflict':('provider','conflict-resolver',('review-pr','solve','turbo'),None),
    'simplify.fix.phase2':('provider','code-fixer',('simplify',),None),
}
expected_edges=set(edge_semantics)
review_fixer_inputs={
    'authority_path':'path','authority_sha256':'string',
    'commit_range_path':'path','commit_range_sha256':'string',
    'disposition_path':'path','findings_path':'path','findings_sha256':'string',
    'pr_number':'integer','working_dir':'directory',
}
standalone_fixer_inputs={
    'authority_path':'path','authority_sha256':'string',
    'disposition_path':'path','findings_path':'path','findings_sha256':'string',
    'pr_number':'integer','standalone_snapshot_path':'path',
    'standalone_snapshot_sha256':'string','working_dir':'directory',
}
fixer_input_semantics={
    'review_pr.fix.phase1':review_fixer_inputs,
    'review_pr.fix.phase2':review_fixer_inputs,
    'simplify.fix.phase2':standalone_fixer_inputs,
}
fixer_route_posture={
    'review_pr.fix.phase1':('review_fix','caller','run',False,'one_per_review_iteration'),
    'review_pr.fix.phase2':('simplify_fix','caller','run',False,'zero_or_one_per_review_iteration'),
    'simplify.fix.phase2':('simplify_fix','caller','run',False,'zero_or_one_per_review_iteration'),
}

claude_roles={path.stem for path in (root/'plugins/prkit/agents').glob('*.md')}
assert claude_roles==expected_roles, ('claude role fleet',sorted(claude_roles))
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
    assert set(tree)=={'schema_version','tree_id','root_edge_id','input_limits','output_contracts','edges'}
    assert tree.get('schema_version')==1
    assert tree.get('tree_id')=='review-pr-run-tree-v1'
    assert tree.get('root_edge_id')=='review_pr.post_impl_review'
    assert tree.get('input_limits')=={'max_serialized_bytes':49152}
    edges=tree.get('edges')
    assert isinstance(edges,dict) and edges
    assert set(edges)==expected_edges
    referenced_contracts=set()
    for edge_id,edge in edges.items():
        assert isinstance(edge,dict), edge_id
        expected_kind,expected_role,expected_workflows,expected_contract=edge_semantics[edge_id]
        assert edge.get('kind')==expected_kind, edge_id
        assert edge.get('role')==expected_role, edge_id
        workflows=edge.get('allowed_workflows')
        assert (tuple(workflows) if isinstance(workflows,list) else workflows)==expected_workflows, edge_id
        assert edge.get('output_contract')==expected_contract, edge_id
        assert expected_contract is not None or 'output_contract' not in edge, edge_id
        expected_inputs=fixer_input_semantics.get(edge_id)
        if expected_inputs is not None:
            assert edge.get('required_inputs')==expected_inputs, edge_id
            assert edge.get('optional_inputs')=={}, edge_id
        expected_posture=fixer_route_posture.get(edge_id)
        if expected_posture is not None:
            actual_posture=(
                edge.get('phase'),edge.get('workspace_mode'),edge.get('risk_scope'),
                edge.get('required'),edge.get('cardinality'),
            )
            assert actual_posture==expected_posture, edge_id
            assert type(edge.get('required')) is bool, edge_id
        if expected_kind=='provider':
            assert expected_role in shipped_roles and expected_workflows, edge_id
            assert all(workflow in allowed_workflows for workflow in expected_workflows), edge_id
        if expected_contract is not None:
            contract_id=expected_contract
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
    for edge in (edge_id for edge_id,semantics in edge_semantics.items() if semantics[3]==review_contract):
        row=edges[edge]
        assert row.get('output_contract')=='phase1-reviewer-v1'
        assert row['required_inputs'].get('changed_paths')=='repo_path_array'
    return raw,(plugin/contract_rel).read_text()
claude_policy,claude_contract=validate(root/'plugins/prkit')
PY
then ok "PR-policy: strict deterministic closure, shipped roles/workflows/contracts"
else fail "PR-policy: projection, strict JSON, or contract scoping drift"; fi

# --- 8. Root scaffold files (outside the SCAN roots) — present, non-empty, valid ---
for req in "${SCAFFOLD_REQUIRED[@]}"; do
  { check_managed_path "$req" required-file && [ -s "$ROOT/$req" ]; } \
    || fail "scaffold: missing/empty/non-regular/link/reparse $req"
done

# The standalone workflows persist local trust/research/audit state below
# .prkit/. First require the complete active rule set emitted by the sealed
# scaffold (comments/blanks are inert; CRLF is Git-valid), so additive broad
# rules cannot hide behind a later canonical match.
EXPECTED_GITIGNORE_RULES=(
  ".DS_Store"
  "__pycache__/"
  "*.pyc"
  ".claude/"
  ".worktrees/"
  ".prkit/"
)
ACTUAL_GITIGNORE_RULES=()
while IFS= read -r ignore_line || [ -n "$ignore_line" ]; do
  ignore_line="${ignore_line%$'\r'}"
  ignore_nonblank="${ignore_line// /}"
  [ -n "$ignore_nonblank" ] || continue
  case "$ignore_line" in
    \#*) continue ;;
  esac
  ACTUAL_GITIGNORE_RULES+=("$ignore_line")
done < "$ROOT/.gitignore"
gitignore_rules_canonical=1
if [ "${#ACTUAL_GITIGNORE_RULES[@]}" -ne "${#EXPECTED_GITIGNORE_RULES[@]}" ]; then
  gitignore_rules_canonical=0
else
  for ((ignore_i=0; ignore_i<${#EXPECTED_GITIGNORE_RULES[@]}; ignore_i++)); do
    [ "${ACTUAL_GITIGNORE_RULES[$ignore_i]}" = "${EXPECTED_GITIGNORE_RULES[$ignore_i]}" ] \
      || gitignore_rules_canonical=0
  done
fi

# Then prove the canonical rule is semantically effective while the root
# generation lock remains visible. Separate empty Git metadata supports non-Git
# targets and prevents system/global config, init templates, and excludes from
# becoming verifier evidence.
run_isolated_probe_git(){
  (
    local isolated_config="$1" config_prefix config_var config_suffix
    shift

    # Git's command-scope transports outrank system/global config. Remove both
    # forms in this child only; validated compgen names avoid evaluating caller
    # bytes, and COUNT=0 keeps any non-shell indexed environment entries inert.
    unset GIT_CONFIG_PARAMETERS
    for config_prefix in GIT_CONFIG_KEY_ GIT_CONFIG_VALUE_; do
      while IFS= read -r config_var; do
        config_suffix="${config_var#"$config_prefix"}"
        case "$config_suffix" in
          ''|*[!0-9]*) continue ;;
        esac
        unset "$config_var"
      done < <(compgen -A variable "$config_prefix")
    done

    GIT_CONFIG_COUNT=0 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$isolated_config" \
      git "$@"
  )
}

IGNORE_PROBE_PARENT=""
IGNORE_PROBE_GIT=""
IGNORE_PROBE_TEMPLATE=""
IGNORE_PROBE_CONFIG=""
IGNORE_PROBE_INPUT=""
IGNORE_PROBE_OUTPUT=""
ignore_artifact_status=2
ignore_lock_status=2
ignore_artifact_record_valid=0
ignore_infrastructure_error=0

IGNORE_PROBE_PARENT="$(mktemp -d 2>/dev/null)"
ignore_mktemp_status=$?
if [ "$ignore_mktemp_status" -ne 0 ] || [ -z "$IGNORE_PROBE_PARENT" ]; then
  fail "artifact-ignore: infrastructure error: mktemp failed (rc=$ignore_mktemp_status)"
  ignore_infrastructure_error=1
else
  VERIFY_TEMP_PATHS+=("$IGNORE_PROBE_PARENT")
  IGNORE_PROBE_GIT="$IGNORE_PROBE_PARENT/repo"
  IGNORE_PROBE_TEMPLATE="$IGNORE_PROBE_PARENT/empty-template"
  IGNORE_PROBE_CONFIG="$IGNORE_PROBE_PARENT/empty.gitconfig"
  IGNORE_PROBE_INPUT="$IGNORE_PROBE_PARENT/check-ignore.input"
  IGNORE_PROBE_OUTPUT="$IGNORE_PROBE_PARENT/check-ignore.output"
  mkdir "$IGNORE_PROBE_GIT" "$IGNORE_PROBE_TEMPLATE" 2>/dev/null
  ignore_mkdir_status=$?
  if [ "$ignore_mkdir_status" -ne 0 ]; then
    fail "artifact-ignore: infrastructure error: probe mkdir failed (rc=$ignore_mkdir_status)"
    ignore_infrastructure_error=1
  else
    : > "$IGNORE_PROBE_CONFIG"
    ignore_config_status=$?
    if [ "$ignore_config_status" -ne 0 ]; then
      fail "artifact-ignore: infrastructure error: empty Git config creation failed (rc=$ignore_config_status)"
      ignore_infrastructure_error=1
    else
      printf '%s\0' '.prkit/audit.jsonl' > "$IGNORE_PROBE_INPUT"
      ignore_input_status=$?
      if [ "$ignore_input_status" -ne 0 ]; then
        fail "artifact-ignore: infrastructure error: probe input creation failed (rc=$ignore_input_status)"
        ignore_infrastructure_error=1
      fi
    fi
    if [ "$ignore_infrastructure_error" -eq 0 ]; then
      run_isolated_probe_git "$IGNORE_PROBE_CONFIG" \
        -C "$IGNORE_PROBE_GIT" init -q \
        --template="$IGNORE_PROBE_TEMPLATE" >/dev/null 2>&1
      ignore_init_status=$?
      if [ "$ignore_init_status" -ne 0 ]; then
        fail "artifact-ignore: infrastructure error: git init failed (rc=$ignore_init_status)"
        ignore_infrastructure_error=1
      fi
    fi
  fi
fi

if [ "$ignore_infrastructure_error" -eq 0 ]; then
  run_isolated_probe_git "$IGNORE_PROBE_CONFIG" \
    --git-dir="$IGNORE_PROBE_GIT/.git" --work-tree="$ROOT" \
    -c core.excludesFile=/dev/null \
    check-ignore -v -z --no-index --stdin \
    < "$IGNORE_PROBE_INPUT" > "$IGNORE_PROBE_OUTPUT" 2>/dev/null
  ignore_artifact_status=$?
  run_isolated_probe_git "$IGNORE_PROBE_CONFIG" \
    --git-dir="$IGNORE_PROBE_GIT/.git" --work-tree="$ROOT" \
    -c core.excludesFile=/dev/null \
    check-ignore -q --no-index -- .prkit-generate.lock >/dev/null 2>&1
  ignore_lock_status=$?
  case "$ignore_artifact_status" in
    0|1) ;;
    *)
      fail "artifact-ignore: infrastructure error: git check-ignore for .prkit/audit.jsonl failed (rc=$ignore_artifact_status)"
      ignore_infrastructure_error=1
      ;;
  esac
  case "$ignore_lock_status" in
    0|1) ;;
    *)
      fail "artifact-ignore: infrastructure error: git check-ignore for .prkit-generate.lock failed (rc=$ignore_lock_status)"
      ignore_infrastructure_error=1
      ;;
  esac
fi

if [ "$ignore_infrastructure_error" -eq 0 ] \
   && [ "$ignore_artifact_status" -eq 0 ] \
   && python3 -I -B - "$IGNORE_PROBE_OUTPUT" "$ROOT/.gitignore" <<'PY'
import ntpath
import os
from pathlib import Path
import platform
import re
import sys

record = Path(sys.argv[1]).read_bytes().split(b"\0")
if len(record) != 5 or record[-1] != b"":
    raise SystemExit(1)

source_raw, line_raw, pattern_raw, path_raw, _ = record
source = source_raw.decode("utf-8", "surrogateescape")
expected = sys.argv[2]

if not line_raw.isdigit() or int(line_raw) < 1:
    raise SystemExit(1)
if pattern_raw != b".prkit/" or path_raw != b".prkit/audit.jsonl":
    raise SystemExit(1)


def windows_key(value):
    normalized = value.replace("\\", "/")
    msys_drive = re.match(r"^/([A-Za-z])(/.*)$", normalized)
    if msys_drive:
        normalized = f"{msys_drive.group(1)}:{msys_drive.group(2)}"
    if re.match(r"^[A-Za-z]:/", normalized) or normalized.startswith("//"):
        return ntpath.normcase(ntpath.normpath(normalized))
    return None


source_is_target = source == ".gitignore"
if not source_is_target:
    runtime_system = platform.system().casefold()
    windows_runtime = os.name == "nt" or runtime_system.startswith(
        ("windows", "msys", "mingw", "cygwin")
    )
    if windows_runtime:
        source_windows = windows_key(source)
        expected_windows = windows_key(expected)
        if source_windows is not None or expected_windows is not None:
            source_is_target = (
                source_windows is not None
                and expected_windows is not None
                and source_windows == expected_windows
            )
        elif os.path.isabs(source):
            source_is_target = os.path.realpath(source) == os.path.realpath(expected)
    elif os.path.isabs(source):
        source_is_target = os.path.realpath(source) == os.path.realpath(expected)

raise SystemExit(0 if source_is_target else 1)
PY
then
  ignore_artifact_record_valid=1
fi

if [ "$ignore_infrastructure_error" -eq 0 ] \
   && [ "$gitignore_rules_canonical" -eq 1 ] \
   && [ "$ignore_artifact_status" -eq 0 ] \
   && [ "$ignore_lock_status" -eq 1 ] \
   && [ "$ignore_artifact_record_valid" -eq 1 ]; then
  ok "artifact-ignore: managed .prkit/ rule ignores artifacts without ignoring generation lock"
elif [ "$ignore_infrastructure_error" -eq 0 ]; then
  fail "artifact-ignore: .gitignore must contain an effective .prkit/ rule and leave .prkit-generate.lock unignored"
fi

jq empty "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null || fail "scaffold: marketplace.json is not valid JSON"

# --- 9. No unrendered generator placeholders leaked into generated output ---
# Generator placeholders are uppercase identifiers (for example {{VERSION}}).
# Lowercase doubled braces are valid runtime data, including Git's ^{tree}
# spelling inside Python f-strings (`^{{tree}}`).
PLH=$(grep -rlE '\{\{[A-Z][A-Z0-9_]*\}\}' "${SCAN[@]}" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null)
placeholder_status=$?
case "$placeholder_status" in
  0)
    fail "placeholders: unrendered {{...}} in:"
    echo "$PLH" | sed 's/^/         /'
    ;;
  1) ok "placeholders: no unrendered {{...}} in output" ;;
  *) fail "placeholders: scan errored (grep rc=$placeholder_status) — cannot certify clean" ;;
esac

# --- 10. The Codex tree stays retired (#381, and the drift it hid: #410) ---
# The generator no longer emits codex/ and no MANAGED_PATH covers it, so a
# pre-#381 target keeps its stale tree FOREVER while every gate scoped to
# plugins/prkit stays green over it — the published prkit repo was carrying 54
# such files, months after the port stage was removed here.
#
# This is an ASSERTION, not a deletion: the generator's destructive authority is
# deliberately not widened to a path it never writes, so the gate fails loudly
# instead of removing someone's directory.
#
# `-e || -L`, not `-e`: -e FOLLOWS symlinks, so a DANGLING link named codex — a
# plausible leftover of a hand-cleanup — would pass a bare -e test.
if [ -e "$ROOT/codex" ] || [ -L "$ROOT/codex" ]; then
  fail "codex-retired: generated target still carries a codex/ tree (UberDev #381)"
else
  ok "codex-retired: no codex/ tree in the generated target"
fi

if ! cleanup_verify_temp_paths; then
  fail "cleanup: verifier temporary removal failed"
fi

echo "  Result: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
