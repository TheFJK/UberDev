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
# appended a contract-less fallback directive that NAMED a three-member vocabulary
# of its own, which overrode the card's own wording at the END of the assembled
# prompt and made DONE_WITH_CONCERNS / NEEDS_CONTEXT unreachable -- so
# `context_rounds` bounded a state that could not occur. #546 retired that wording
# composer-wide: the contract-less arm now points at the return contract the role
# card declares and names nothing of its own, so the override is gone on every
# edge in the SRT-546.1 set below. Delegation is not a contract, though -- the
# binding pinned here is what puts a machine-checkable shape in front of THIS
# child, so it stays pinned by id and cannot be dropped silently.
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

# --- #536: every run-tree edge id the launcher names must RESOLVE -------------
#
# The `solve.issue.lead` grep above proves only that the id is PRESENT. It stayed
# green for the whole life of the defect: the launcher's live assignment read
# UBERDEV_ROOT_EDGE_ID="solve.lead.$TIER", and since the tier is one of
# trivial|small|medium|large, EVERY value that line could produce named an edge
# absent from the manifest -- while nothing anywhere read the variable. That is
# the #370 shape ("one contract, N uncompared copies") on the shell-runtime side;
# #510 closed the manifest side with tests/solve-run-tree-scope.test.sh.
#
# tests/launcher_edge_ids.py derives the accepted vocabulary FROM THE TREE (it
# hardcodes no id) and refuses any token that is not a key of `edges`. Row E1
# upgrades the presence grep above into a resolution check; the mutant rows are
# the durable regression pins -- each re-creates one emitter IN MEMORY and
# asserts the checker reds, so a re-introduction cannot ship green.
#
# Mechanics, every one of which has bitten this repo before:
#   * `set -e` is on, so an expected-nonzero call goes through edge_check, which
#     records the code instead of aborting the run before it can be read.
#   * Mutants are fed on STDIN with a herestring -- never `printf | python3`
#     (tests/epipe-guard.test.sh) -- and built by a python program writing BYTES
#     to stdout: no temp file, no mktemp, no `sed -i`, no CRLF rewrite.
#   * No `git show` and no SHA literal: this file also runs on the windows
#     shape-check job, whose checkout has no history depth.
EDGE_CHECK="$ROOT/tests/launcher_edge_ids.py"
LAUNCHER="$ROOT/plugins/uberdev/lib/solve-launcher.sh"
for f in "$EDGE_CHECK" "$LAUNCHER"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done

# The launcher line every insertion row anchors on. Held in one variable so a
# rewording breaks the rows loudly (mut asserts the occurrence count) instead of
# silently turning them into no-op mutations that still pass.
EXPORT_ANCHOR='export UBERDEV_AGENT_PREPARED_REQUEST_JSON'
CARRIER_ANCHOR='error: failed to construct the solve.issue.lead run carrier'

EDGE_ROWS=0
EDGE_RC=0
EDGE_ERR=''
MUT=''

# Run the checker over ($1 = tree, $2 = launcher; `-` reads stdin), recording the
# exit code in EDGE_RC and the diagnostics in EDGE_ERR. Deliberately never
# aborts: a row that expects a nonzero code has to be able to read it.
edge_check() {
  EDGE_ERR="$(python3 -I -B "$EDGE_CHECK" --tree "$1" --launcher "$2" 2>&1 >/dev/null)" && EDGE_RC=0 || EDGE_RC=$?
}

# Print the launcher into MUT with $1 replaced by $2. $3 is how many times the
# anchor must occur ('+' = at least once, default exactly 1); a mismatch is
# FATAL, because a mutation that no longer bites is a vacuous green.
mut() {
  MUT="$(python3 -I -B -c '
import sys
src = open(sys.argv[1], "rb").read().decode("utf-8")
anchor, replacement, want = sys.argv[2], sys.argv[3], sys.argv[4]
hits = src.count(anchor)
ok = hits >= 1 if want == "+" else hits == int(want)
if not ok:
    raise SystemExit("mutation anchor occurs %d time(s), want %s: %s" % (hits, want, anchor))
sys.stdout.buffer.write(src.replace(anchor, replacement).encode("utf-8"))
' "$LAUNCHER" "$1" "$2" "${3:-1}")" || { echo "FATAL: launcher mutation failed (see the message above)" >&2; exit 2; }
}

# A replacement that inserts $1 as its own line directly above anchor $2, with
# the anchor itself preserved.
prepend_line() { printf '%s\n%s' "$1" "$2"; }

# One DIFFERENTIAL row: the unmutated launcher must be clean AND the mutant must
# exit with $4. Asserting only the mutant half would pass vacuously the moment
# the baseline broke -- the convention documented at
# tests/solve-run-tree-scope.test.sh:34-36.
edge_differential() {
  local row="$1" anchor="$2" replacement="$3" want_rc="$4" want_hits="${5:-1}"
  mut "$anchor" "$anchor" "$want_hits"
  edge_check "$TREE" - <<<"$MUT"
  [ "$EDGE_RC" -eq 0 ] || { echo "$row: the UNMUTATED launcher is not clean (rc=$EDGE_RC): $EDGE_ERR" >&2; exit 1; }
  mut "$anchor" "$replacement" "$want_hits"
  edge_check "$TREE" - <<<"$MUT"
  [ "$EDGE_RC" -eq "$want_rc" ] || {
    echo "$row: mutant rc=$EDGE_RC, want $want_rc: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1; }
  EDGE_ROWS=$((EDGE_ROWS + 1))
}

# E1 -- the live launcher against the live tree.
edge_check "$TREE" "$LAUNCHER"
[ "$EDGE_RC" -eq 0 ] || { echo "E1: the launcher names an unresolvable run-tree edge id: $EDGE_ERR" >&2; exit 1; }
EDGE_ROWS=$((EDGE_ROWS + 1))

# E2 -- the filed regression itself, verbatim.
edge_differential E2 "$EXPORT_ANCHOR" \
  "$(prepend_line 'UBERDEV_ROOT_EDGE_ID="solve.lead.$TIER"' "$EXPORT_ANCHOR")" 1

# E3 -- one tier substituted by hand: a BARE literal, still not an edge.
# Membership is what is checked, not merely "the right-hand side contains a $".
edge_differential E3 "$EXPORT_ANCHOR" \
  "$(prepend_line 'UBERDEV_ROOT_EDGE_ID="solve.lead.medium"' "$EXPORT_ANCHOR")" 1

# E4 -- the second emitter the issue never mentioned: the carrier-failure string.
edge_differential E4 "$CARRIER_ANCHOR" 'error: failed to construct solve.lead.$TIER carrier' 1

# E5 -- comments and strings are in scope. The fictional id survived review for
# months inside comment prose, so prose is exactly what must be checked.
edge_differential E5 "$EXPORT_ANCHOR" \
  "$(prepend_line '# Root carrier lineage `solve.lead.<tier>` (legacy catalog alias).' "$EXPORT_ANCHOR")" 1

# E6 -- the guard forbids WRONG ids, not the variable. A root-edge pointer that
# names a real edge is accepted, so this never blocks wiring one to a reader.
edge_differential E6 "$EXPORT_ANCHOR" \
  "$(prepend_line 'UBERDEV_ROOT_EDGE_ID="solve.issue.lead"' "$EXPORT_ANCHOR")" 0

# E7 -- the anti-vacuity floor. Strip every mention of the root edge and the
# checker must say so by name, rather than passing because nothing is left to
# disagree with.
edge_differential E7 'solve.issue.lead' '' 1 '+'
case "$EDGE_ERR" in
  *"never names the tree root edge id 'solve.issue.lead'"*) : ;;
  *) echo "E7: the L3 floor did not name the missing root edge: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1 ;;
esac
case "$EDGE_ERR" in
  *"the extractor matched nothing"*) : ;;
  *) echo "E7: the L3 floor did not report an empty match set: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1 ;;
esac

# E8 -- the accepted vocabulary is TREE-DERIVED, not hardcoded in the checker.
# Rename the edges KEY only, leaving root_edge_id alone: the red then comes
# unambiguously from the membership check, not from a tree-consistency assert
# (which belongs to the manifest block at the top of this file, not here).
TREE_MUT="$(python3 -I -B -c '
import json, sys
tree = json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))
edges = tree["edges"]
if "solve.issue.lead" not in edges:
    raise SystemExit("mutation anchor absent: edges[solve.issue.lead]")
edges["solve.issue.root"] = edges.pop("solve.issue.lead")
sys.stdout.buffer.write(json.dumps(tree).encode("utf-8"))
' "$TREE")" || { echo "FATAL: E8 tree mutation failed (see the message above)" >&2; exit 2; }
edge_check "$TREE" "$LAUNCHER"
[ "$EDGE_RC" -eq 0 ] || { echo "E8: the UNMUTATED tree is not clean (rc=$EDGE_RC): $EDGE_ERR" >&2; exit 1; }
edge_check - "$LAUNCHER" <<<"$TREE_MUT"
[ "$EDGE_RC" -eq 1 ] || { echo "E8: renaming the root edge KEY must red the launcher (rc=$EDGE_RC)" >&2; exit 1; }
case "$EDGE_ERR" in
  *"solve.issue.lead"*) : ;;
  *) echo "E8: the mutant-tree diagnostics never named solve.issue.lead: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1 ;;
esac
EDGE_ROWS=$((EDGE_ROWS + 1))

# E9 -- `commands/solve.md` is a FILENAME, not an edge id: `md` is not an area
# of the tree, so no prefix the extractor derives from `edges` can reach it.
# First assert the launcher really does still name it, so the row cannot pass by
# the reference having been deleted. Then prove E1's silence about those two
# lines is a RESULT and not a blind spot, by giving the very same references a
# REAL area prefix: the lines are in scope, and it is the vocabulary that
# excludes them. Reading E1's diagnostics instead could assert nothing at all --
# E1 has already required rc=0 above, and a clean run puts its summary on
# stdout, so the captured stderr is empty by construction.
grep -q 'solve\.md' "$LAUNCHER" || {
  echo "E9: the launcher no longer names commands/solve.md -- the row is vacuous" >&2; exit 1; }
edge_differential E9 'solve.md' 'solve.issue.md' 1 2
# The mutant's rc does NOT settle it. rc=1 is satisfied by ONE of the two
# references being seen, so a checker blind to the first line would still red on
# the second and pass this row -- proving only that line in scope while the
# comment claimed both. Count the DISTINCT line anchors the diagnostics carry
# instead: two references on two lines, so a blind spot on EITHER now reds E9.
# (mut has already refused to run unless the anchor occurs exactly twice, so a
# deleted reference cannot reach this count and pass it.) The `%%` strip runs to
# end of line, so the CRLF a python-written capture carries on the windows job
# is removed with the reason text and never leaks into a site label.
EDGE_SITES=''
EDGE_SITE_COUNT=0
while IFS= read -r EDGE_DIAG; do
  case "$EDGE_DIAG" in
    *"unresolvable edge id 'solve.issue.md'"*) ;;
    *) continue ;;
  esac
  EDGE_SITE="${EDGE_DIAG%%: unresolvable*}"
  case "$EDGE_SITES" in
    *"[$EDGE_SITE]"*) continue ;;
  esac
  EDGE_SITES="$EDGE_SITES[$EDGE_SITE]"
  EDGE_SITE_COUNT=$((EDGE_SITE_COUNT + 1))
done <<<"$EDGE_ERR"
[ "$EDGE_SITE_COUNT" -eq 2 ] || {
  echo "E9: the mutant's diagnostics name $EDGE_SITE_COUNT distinct line(s) ${EDGE_SITES:-(none)}, want 2 -- one of the two commands/solve.md lines is a blind spot, not out of vocabulary: ${EDGE_ERR:-(no diagnostics)}" >&2
  exit 1; }

# E10 -- stdin has one reader, so asking both sides to use it is a usage error
# (exit 2), never a verdict about the launcher.
edge_check - - </dev/null
[ "$EDGE_RC" -eq 2 ] || { echo "E10: --tree - --launcher - must be a usage error, got rc=$EDGE_RC" >&2; exit 1; }
EDGE_ROWS=$((EDGE_ROWS + 1))

# E11 -- row-count floor, mirroring tests/solve-run-tree-scope.test.sh:490. A row
# deleted or short-circuited out of the block must fail the file, not shrink it.
[ "$EDGE_ROWS" -ge 10 ] || {
  echo "FATAL: $EDGE_ROWS edge-id row(s) ran, expected at least 10 (E1-E10)" >&2; exit 2; }

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
