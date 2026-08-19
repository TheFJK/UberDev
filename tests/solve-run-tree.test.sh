#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
POLICY="$ROOT/plugins/uberdev/policy/model-routing-v1.json"
# The three prose copies SRT-606.x compares against the pinned unbound-edge set,
# plus the role-card directory its classifier reads.
AGENTS_DIR="$ROOT/plugins/uberdev/agents"
RFC_0016="$ROOT/docs/rfc/0016-contract-markers.md"
MARKER_REGISTER="$ROOT/tests/contract_markers.py"
CHILD_DISPATCH="$ROOT/plugins/uberdev/lib/child-dispatch.sh"

python3 -I -B - "$TREE" "$POLICY" "$AGENTS_DIR" "$RFC_0016" "$MARKER_REGISTER" "$CHILD_DISPATCH" <<'PY'
import json,pathlib,re,sys
tree_path,policy_path,agents_dir,rfc_path,marker_register_path,child_dispatch_path=\
    map(pathlib.Path,sys.argv[1:])
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
# return vocabulary is at stake -- every OTHER member is composable, and the row
# below ASSERTS that rather than stating it. This comment used to hand-write
# "31 of the 32 are composable", derived by nothing: a fourth copy of the pair
# SRT-606.3 derives, sitting five lines above a census that enumerated three
# files and did not count the one it was written in. The split is never typed
# here again -- membership is pinned, and the figures live only where they are
# computed.
assert edges['solve.issue.lead'].get('role') is None
assert tree['root_edge_id']=='solve.issue.lead'
assert {edge_id for edge_id in unbound_provider_edges
        if edges[edge_id].get('role') is None}=={'solve.issue.lead'}
# --- SRT-606.x (#606) -- the prose copies of this set's cardinalities, derived.
#
# Three OTHER files state, in prose, facts about the set pinned above: RFC 0016's
# `sdd-implementer-status` register row, tests/contract_markers.py's mirror
# comment on the same register entry, and the composer comment in
# lib/child-dispatch.sh that explains why the contract-less arm may only POINT.
# Each was written by hand from a reading of the tree, and by #606 all three had
# drifted: two named a third role whose card does carry a fenced block, and the
# third said "the other 31" beside RFC 0016's "all 32" -- two figures that read
# as a contradiction while each was describing a different subset.
#
# A FOURTH copy sat in THIS file, five lines above, and the first edition of this
# census did not count it: SRT-546.2's own comment hand-wrote "31 of the 32 are
# composable". It is gone -- that sentence pins the roleless membership instead
# of typing the split -- which is why the enumeration is three files and not
# four. A census blind to a copy in its own file is the defect it audits.
#
# These rows recompute every figure from `unbound_provider_edges` above and from
# the role cards on disk, then require the prose to match. The only membership
# typed out below is SRT-606.1's two-role set, and that is a claim about the
# CARDS: it reds the moment either card grows a fenced block or a third card
# loses one, which is exactly when the prose has to be re-read.
#
# DECLARED BOUNDARY. SRT-606.3's unlabelled-integer arm constrains the two
# cardinalities only, not every digit in the composer block -- issue numbers and
# contract ids are digits too, and an allow-list of those would be the rotting
# survey this section exists to retire.
assert agents_dir.is_dir(), 'SRT-606.0: role-card directory missing: %s' % agents_dir
sdd_unbound_roles=sorted({edges[e]['role'] for e in unbound_provider_edges
                          if edges[e].get('role') is not None})
# SRT-606.0 -- anti-vacuity. An empty harvest makes every membership comparison
# below trivially true, which is how a guard ends up green beside the very
# defect it names.
assert sdd_unbound_roles, 'SRT-606.0: the pinned unbound set harvested no roles at all'
sdd_role_cards={}
for sdd_role in sdd_unbound_roles:
    sdd_card=agents_dir/(sdd_role+'.md')
    assert sdd_card.is_file(), 'SRT-606.0: unbound role %r has no card at %s' % (sdd_role,sdd_card)
    sdd_role_cards[sdd_role]=sdd_card.read_text(encoding='utf-8')
# SRT-606.1 -- the classifier RFC 0016 states, EXECUTED: does the role card carry
# a fenced block at all? Membership, never a literal count -- a count can stay 2
# while the two names silently change underneath it.
sdd_fence_re=re.compile(r'(?m)^[ \t]*```')
sdd_unfenced_roles=sorted(r for r in sdd_unbound_roles if not sdd_fence_re.search(sdd_role_cards[r]))
assert set(sdd_unfenced_roles)=={'code-reviewer','pr-test-analyzer'}, \
    'SRT-606.1: the unbound roles whose card carries no fenced block are %r' % (sdd_unfenced_roles,)

def sdd_flatten(text):
    """Comment prose as ONE line: markers stripped, wrapping removed.

    Every containment check below reads the flattened form. Where a comment
    happens to wrap is not a fact about the claim it makes, and a row that reds
    on a re-flow reports a fault that did not happen. A claim broken MID-TOKEN
    ('role\\n# card') survives as 'role card' and is seen; one broken mid-WORD
    does not, and reds loudly rather than passing quietly.
    """
    joined=' '.join(re.sub(r'^[ \t]*#[ \t]?','',line) for line in text.splitlines())
    return re.sub(r'\s+',' ',joined).strip()

def sdd_prose_above(path,anchor,row,require_next=None):
    """The contiguous run of comment lines immediately above `anchor`, flattened.

    `require_next` disambiguates an anchor that occurs more than once by naming a
    literal the FOLLOWING line must carry. A non-unique anchor or a collapsed
    block is FATAL rather than an empty slice: a row that reads nothing passes
    every containment check written against it.
    """
    lines=path.read_text(encoding='utf-8').splitlines()
    hits=[i for i,line in enumerate(lines)
          if anchor in line and (require_next is None
                                 or (i+1<len(lines) and require_next in lines[i+1]))]
    assert len(hits)==1, '%s: anchor %r occurs %d time(s) in %s' % (row,anchor,len(hits),path)
    i=hits[0]; block=[]
    while i>0 and lines[i-1].lstrip().startswith('#'):
        i-=1; block.append(lines[i])
    assert len(block)>=5, '%s: the comment block above %r in %s is %d line(s)' % (row,anchor,path,len(block))
    return sdd_flatten('\n'.join(reversed(block)))

# SRT-606.2 -- both prose copies name exactly that subset and no third role.
# Anchored on the role NAMES and on a DERIVED count phrase, never on the
# sentence around them, so a reword stays free while a renumber does not.
sdd_rfc_rows=[line for line in rfc_path.read_text(encoding='utf-8').splitlines()
              if line.startswith('| `sdd-implementer-status`')]
assert len(sdd_rfc_rows)==1, \
    'SRT-606.2: RFC 0016 carries %d sdd-implementer-status register row(s)' % len(sdd_rfc_rows)
sdd_rfc_row=sdd_flatten(sdd_rfc_rows[0])
sdd_prose={'docs/rfc/0016-contract-markers.md':sdd_rfc_row,
           'tests/contract_markers.py':sdd_prose_above(
               marker_register_path,'"sdd-implementer-status": [','SRT-606.2',
               require_next='agents/implementation-worker.md')}
sdd_count_phrase='%d of the %d' % (len(sdd_unfenced_roles),len(sdd_unbound_roles))
for sdd_label,sdd_text in sorted(sdd_prose.items()):
    sdd_named=sorted(r for r in sdd_unbound_roles
                     if re.search(r'(?<![0-9A-Za-z-])%s(?![0-9A-Za-z-])' % re.escape(r),sdd_text))
    assert sdd_named==sdd_unfenced_roles, \
        'SRT-606.2: %s names %r as the unfenced unbound roles; the cards say %r' % (
            sdd_label,sdd_named,sdd_unfenced_roles)
    assert sdd_count_phrase in sdd_text, \
        'SRT-606.2: %s does not state the derived count %r' % (sdd_label,sdd_count_phrase)
# The classifier has to be written down beside the count, because a count is only
# checkable against a stated rule -- #606's miscount happened with the rule left
# implicit, and every reader re-derived a different one.
assert 'fenced block' in sdd_rfc_row and 'role card' in sdd_rfc_row, \
    'SRT-606.2: the RFC register row states no classifier for its unfenced-role count'
# SRT-606.3 -- the composer comment states BOTH cardinalities of the pinned set,
# each carrying the label that says what it counts, and no bare copy of either.
# "the other 31" was true of neither: it counted the composable subset while
# naming an exclusion (sdd.task.implement) that is not in the set at all.
sdd_composer=sdd_prose_above(
    child_dispatch_path,
    "terminal=(b'Return only a response matching the output contract above.",
    'SRT-606.3')
assert 'other 31' not in sdd_composer, \
    'SRT-606.3: the composer comment still says "other 31"'
sdd_unbound_total=len(unbound_provider_edges)
sdd_unbound_composable=len([e for e in unbound_provider_edges if edges[e].get('role') is not None])
for sdd_phrase,sdd_number in (('%d members' % sdd_unbound_total,sdd_unbound_total),
                              ('%d of which carry a role card' % sdd_unbound_composable,
                               sdd_unbound_composable)):
    assert sdd_phrase in sdd_composer, \
        'SRT-606.3: the composer comment does not state %r' % sdd_phrase
    sdd_bare=len(re.findall(r'(?<![0-9])%d(?![0-9])' % sdd_number,sdd_composer))
    assert sdd_bare==sdd_composer.count(sdd_phrase), \
        'SRT-606.3: %d occurs %d time(s) in the composer comment but %r only %d -- an unlabelled cardinality' % (
            sdd_number,sdd_bare,sdd_phrase,sdd_composer.count(sdd_phrase))
assert 'solve.issue.lead' in sdd_composer, \
    'SRT-606.3: the composer comment does not name the roleless member of the set'
# The RFC row states the same pair as the composer comment, and is the copy the
# composer was made consistent with, so it is derived here too -- otherwise the
# pair is free to drift apart in the other direction. Named rather than
# numbered: an ordinal here would be one more figure to keep in step with the
# census above, which is the class this section exists to close.
assert 'all %d unbound provider edges (%d of them ever composed' % (
    sdd_unbound_total,sdd_unbound_composable) in sdd_rfc_row, \
    'SRT-606.3: the RFC register row no longer states the derived %d/%d split' % (
        sdd_unbound_total,sdd_unbound_composable)
assert 'role: null' in sdd_rfc_row, \
    'SRT-606.3: the RFC register row no longer names the roleless member by its manifest field'
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

# --- absorbed from tests/child-contract-v2.test.sh (was its lines 15-116) -----
#
# That file carried a SECOND schema oracle over the same manifest, and both
# oracles justified their own removal by naming the other as the surviving copy.
# They were not duplicates. The five rules below existed ONLY there, so this
# block is what makes dropping the other one safe. This file is now the single
# oracle for policy/solve-run-tree-v1.json.
providers={k:v for k,v in edges.items() if v['kind']=='provider'}
assert providers

# 1. allowed_workflows is a CLOSED vocabulary. The loop at the top of this file
#    checks the list is sorted and duplicate-free but not what may be in it, so
#    a typo'd or invented workflow name passed unnoticed.
for edge_id,row in providers.items():
    assert set(row['allowed_workflows']) <= {'solve','turbo','review-pr','simplify'}, edge_id

# 2. The retired pre-v2 spellings must never come back. `inputs` / `input_types`
#    were replaced by required_inputs / optional_inputs; a row carrying the old
#    keys is silently ignored by the reader rather than rejected.
for edge_id,row in providers.items():
    assert 'inputs' not in row and 'input_types' not in row, edge_id

# 3. format-retry is UNIVERSAL, not per-edge. This file pinned the two keys on
#    the verify edge alone; the rule is that ANY provider edge declaring
#    retry.format must also declare both inputs, or the retry cannot be driven.
for edge_id,row in providers.items():
    if row.get('retry',{}).get('format'):
        assert row['optional_inputs']['format_retry']=='boolean', edge_id
        assert row['optional_inputs']['format_example_path']=='path', edge_id

# 4. The review lens count, DERIVED. The review_edges set earlier in this file is
#    a hardcoded six and predates the convention lens (#431); deriving the set by
#    prefix and asserting seven is what catches a lens being added or dropped.
derived_review_edges={e for e in providers if e.startswith('review_pr.review.')}
assert len(derived_review_edges)==7, sorted(derived_review_edges)

# 5. The simplify lenses take focus as OPTIONAL and have no additional_focus.
#    The lens scalar is controller-supplied; making focus required would break
#    the unfocused invocation, and additional_focus was never implemented.
for edge_id in ('review_pr.simplify.reuse','review_pr.simplify.quality','review_pr.simplify.efficiency'):
    row=providers[edge_id]
    assert 'focus' not in row['required_inputs'], edge_id
    assert row['optional_inputs'].get('focus')=='optional_string', edge_id
    assert 'additional_focus' not in row['optional_inputs'], edge_id
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
# trivial|small|medium, EVERY value that line could produce named an edge
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

# Is $1 present in $2, byte for byte? The pattern is QUOTED, so every character
# of the needle is literal -- `\read` and `*EDGE_ID` are matched as themselves.
#
# This exists because a mutation payload is shell SOURCE TEXT, and it has to
# reach the checker unaltered or the row that carries it means nothing. `mut`
# already asserts the ANCHOR occurs the expected number of times, for the reason
# stated there; the REPLACEMENT half of that same argument -- a mutation that no
# longer bites is a vacuous green -- shipped unguarded, and a corrupted payload
# is exactly a mutation that no longer bites.
payload_arrived() {
  case "$2" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# G0 -- the arrival guard must FIRE, and no differential row can pin it: the
# corruption it catches happens only on the Windows runner, so on every host this
# suite can run the guard from, it is silent. Both halves are asserted, and G0b's
# strings are the MEASURED ones from the failure below rather than invented.
payload_arrived 'read -r UBERDEV_ROOT_EDGE_ID' 'x >/dev/null read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' || {
  echo "G0a: payload_arrived rejected text that DOES carry the payload" >&2; exit 1; }
! payload_arrived '>/dev/null read -r UBERDEV_ROOT_EDGE_ID' \
  '>C:/Program Files/Git/dev/null read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' || {
  echo "G0b: payload_arrived accepted a MANGLED payload -- the corruption below would be a vacuous green again" >&2; exit 1; }

# Print the launcher into MUT with $1 replaced by $2. $3 is how many times the
# anchor must occur ('+' = at least once, default exactly 1); a mismatch is
# FATAL, because a mutation that no longer bites is a vacuous green.
#
# The REPLACEMENT travels on STDIN, and on Windows that is load-bearing rather
# than stylistic. Git-for-Windows rewrites absolute-POSIX-looking values into
# Windows paths at the exec boundary of a NATIVE binary -- here `python.exe` --
# before the callee ever sees them, the same mangling tests/workflow-args.test.sh
# documents at the same boundary for `jq.exe`. Handed over as an ARGV value,
# E39's `>/dev/null read -r UBERDEV_ROOT_EDGE_ID` arrived as
# `>C:/Program Files/Git/dev/null read -r UBERDEV_ROOT_EDGE_ID`, in which the
# redirection target is `C:/Program` and the command word is `Files/Git/dev/null`
# -- so nothing binds, the checker was RIGHT to stay clean, and the row reported
# `E39: mutant rc=0, want 1` on `shape-checks-windows` while passing everywhere
# else.
#
# The ENVIRONMENT is not an escape from it. Moving the payload there was tried on
# this branch and MEASURED on the runner: the arrival guard below fired with
# `the mutation replacement did not survive the exec boundary intact`, so that
# boundary converts env values too. Nor is blanket `MSYS_NO_PATHCONV=1` /
# `MSYS2_ARG_CONV_EXCL='*'` the fix, right though it is in workflow-args, whose
# native callee takes no path: `$LAUNCHER` is a REAL host path on this very
# command line and MUST be converted, or python cannot open it.
#
# Stdin is immune because bash writes the bytes itself -- no exec boundary stands
# between the string and the callee -- and this file already proves that channel
# byte-exact on the same runner, since every mutant reaches `edge_check` the same
# way. `<<<` appends exactly one newline that was not in the payload, so exactly
# that one is stripped back off; the inverse is precise, not a heuristic --
# measured byte-identical against the argv spelling over an empty, a one-line, a
# multi-line and a newline-terminated payload. No row pins the strip and none
# can: dropping it only inserts a blank line above the anchor, and all 69 rows
# stay green (measured). It is stated here as exactness, not as correctness. The
# ANCHOR stays on argv deliberately: no anchor here carries a path-shaped token,
# and a mangled one cannot go quiet -- `src.count` drops to 0 and the occurrence
# assertion below is FATAL.
mut() {
  MUT="$(python3 -I -B -c '
import sys
src = open(sys.argv[1], "rb").read().decode("utf-8")
anchor, want = sys.argv[2], sys.argv[3]
replacement = sys.stdin.buffer.read().decode("utf-8")
if replacement.endswith("\n"):
    replacement = replacement[:-1]
hits = src.count(anchor)
ok = hits >= 1 if want == "+" else hits == int(want)
if not ok:
    raise SystemExit("mutation anchor occurs %d time(s), want %s: %s" % (hits, want, anchor))
sys.stdout.buffer.write(src.replace(anchor, replacement).encode("utf-8"))
' "$LAUNCHER" "$1" "${3:-1}" <<<"$2")" || { echo "FATAL: launcher mutation failed (see the message above)" >&2; exit 2; }
  payload_arrived "$2" "$MUT" || {
    echo "FATAL: the mutation replacement did not survive the exec boundary intact -- the row it feeds would pass vacuously. Wanted: $2" >&2; exit 2; }
}

# A replacement that inserts $1 as its own line directly above anchor $2, with
# the anchor itself preserved.
prepend_line() { printf '%s\n%s' "$1" "$2"; }

# One DIFFERENTIAL row: the unmutated launcher must be clean AND the mutant must
# exit with $4. Asserting only the mutant half would pass vacuously the moment
# the baseline broke -- the convention documented at
# tests/solve-run-tree-scope.test.sh:34-36.
# $6 (optional) is a substring the mutant's diagnostics must contain. An rc
# alone cannot say WHICH rule fired, so a row whose whole purpose is a specific
# rule passes vacuously the moment another rule happens to red the same mutant --
# widen L1's TOKEN_TAIL to admit `%` and E11/E12/E14 would go on passing with
# L2b deleted outright. Naming the expected diagnostic pins the attribution.
edge_differential() {
  local row="$1" anchor="$2" replacement="$3" want_rc="$4" want_hits="${5:-1}" want_msg="${6:-}"
  mut "$anchor" "$anchor" "$want_hits"
  edge_check "$TREE" - <<<"$MUT"
  [ "$EDGE_RC" -eq 0 ] || { echo "$row: the UNMUTATED launcher is not clean (rc=$EDGE_RC): $EDGE_ERR" >&2; exit 1; }
  mut "$anchor" "$replacement" "$want_hits"
  edge_check "$TREE" - <<<"$MUT"
  [ "$EDGE_RC" -eq "$want_rc" ] || {
    echo "$row: mutant rc=$EDGE_RC, want $want_rc: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1; }
  if [ -n "$want_msg" ]; then
    case "$EDGE_ERR" in
      *"$want_msg"*) ;;
      *) echo "$row: mutant rc=$EDGE_RC as wanted, but no diagnostic says '$want_msg' -- the row is passing through a different rule than the one it exists to pin: ${EDGE_ERR:-(no diagnostics)}" >&2; exit 1 ;;
    esac
  fi
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

# --- L2b: bindings that write no `NAME=` token at all -------------------------
#
# E2/E3 above reach only the `UBERDEV_ROOT_EDGE_ID="..."` shape. `printf -v` and
# the `read` builtin bind that very same variable while putting no `=` on the
# line, so BOTH earlier rules are blind to them by construction: L1 needs a
# literal `solve.*` token in the source (a `%s` format string leaves none) and
# L2 needs an assignment RHS (there is none). Every mutant below was measured at
# rc 0 against the pre-L2b checker -- the hole was reproduced, never assumed.
#
# The differential shape is not decoration here. Each row asserts the UNMUTATED
# launcher is clean as well as the mutant dirty, so a rule that reddens
# everything -- the obvious way to make this block pass -- fails it instead.

# E11 -- the filed defect re-expressed through `printf -v`. The composed value
# never appears as a token, so L1 stays silent and only L2b can see this.
edge_differential E11 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v UBERDEV_ROOT_EDGE_ID '"'"'solve.lead.%s'"'"' "$TIER"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E12 -- FORM, not value. The id composed here is the REAL root edge, so nothing
# about it is unresolvable; L2b reds because an edge id was composed at runtime
# at all. Without this row the rule could be satisfied by an id-membership check
# wearing a binding-site name.
edge_differential E12 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "solve.issue.lead"' "$EXPORT_ANCHOR")" 1

# E13 -- a binding tucked mid-line after a `;`. That is L2's own DECLARED LIMIT,
# so it is exactly where the next one would land.
edge_differential E13 "$EXPORT_ANCHOR" \
  "$(prepend_line 'local x; printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1

# E14 -- an INDETERMINATE target. The bound name is not decidable from the text,
# so the checker cannot prove it is NOT an edge id and must refuse rather than
# wave it through.
edge_differential E14 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v "$_name" '"'"'solve.lead.%s'"'"' "$TIER"' "$EXPORT_ANCHOR")" 1

# E15 -- the `read` arm. The value is `"$V"` DELIBERATELY, not "solve.lead.$TIER":
# a literal token is already caught by L1, so the obvious wording would have gone
# green without L2b existing. A row that passes for the wrong reason is the same
# defect class as a `-ge` floor.
edge_differential E15 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E16 -- `read` binds EVERY name it is handed, so a non-first target counts.
edge_differential E16 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r _a UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1

# E17 -- the target FIRST, with a second bare name behind it. This is the target
# position a naive `read [opts] TARGET...` pattern loses: an option-argument
# branch that accepts any bare word lets `-r` swallow the real target and leaves
# the trailing `_b` as the apparent binding, which classifies clean. E15 escapes
# that only because backtracking has nowhere else to go. Pinned so the option
# grammar cannot regress to "anything after a dash-word".
edge_differential E17 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r UBERDEV_ROOT_EDGE_ID _b <<<"$V"' "$EXPORT_ANCHOR")" 1

# E18 -- the idiomatic loop head: `read` reached through a `while` keyword and an
# inline `IFS=` prefix rather than from the start of a line. No other row puts a
# command boundary or an env prefix in front of the verb, so without this one the
# rule could anchor on `^` alone and still pass the whole block.
edge_differential E18 "$EXPORT_ANCHOR" \
  "$(prepend_line 'while IFS= read -r UBERDEV_ROOT_EDGE_ID; do :; done <<<"$V"' "$EXPORT_ANCHOR")" 1

# E19 -- the false-positive floor, and the reason it is THIS line: `local row;
# printf -v row ...` is the live idiom in plugins/uberdev/lib/goal-state.sh
# (eight sites there today). A rule that reddens a bind to a non-edge name would
# be reverted within a day, so the mutant must come back rc 0 just as the
# baseline does -- which is also why this row goes through edge_differential like
# every other, rather than being asserted as a bare clean run.
edge_differential E19 "$EXPORT_ANCHOR" \
  "$(prepend_line 'local row; printf -v row '"'"'%s\t%s'"'"' "$a" "$b"' "$EXPORT_ANCHOR")" 0

# --- L2b: the verb is only a verb where the SHELL would look for one ----------
#
# E11-E19 pin what L2b sees. E20-E32 pin the ways it used to look in the wrong
# place, each measured against the checker of the round before it was written --
# E20-E23 came back rc 0 (the binding walked straight past the rule) while
# E24-E26 and E28-E29 came back rc 1 (text that binds nothing was reported as a
# binding). Neither direction is hypothetical, and BOTH false-positive rounds
# came off the launcher itself: E24 is plugins/uberdev/lib/solve-launcher.sh's
# own `# Inconclusive (read blip or comment not yet indexed)` comment with one
# `$VAR` added, and E28 is a line of its own `CLAIM_BODY` heredoc body with one
# clause added. Cited by SYMBOL and by the quoted text, never by line number:
# this same PR moves the launcher by roughly a hundred lines, and every numbered
# form of these four references was already pointing at the wrong line. That is how close
# a live CI-gating file was, twice, to redding E1 for an unrelated wording edit.
# E27, E30 and E32 are the other direction: they were rc 1 before and must STAY
# rc 1, because each pins a way the fix for its neighbour overshoots into silence.
#
# E31 and E32 pin the heredoc TRACKER itself rather than the rule that consumes
# it, and they are here because neither half of it was pinned by E28-E30: with
# the double-quote transparency removed (E31) or the unterminated-opener rule
# removed (E32), every row from E1 to E30 still passed. A scoping decision no row
# would notice being reversed is the "guard whose predicate is disjoint from the
# drift it must find" shape this whole block exists to police.

# E20 -- `!` negation. `if ! read -r VAR; then` is the E18 loop head one `!`
# away, so it is the cheapest evasion there is; the negation changes the exit
# status and nothing about what the builtin binds.
edge_differential E20 "$EXPORT_ANCHOR" \
  "$(prepend_line 'if ! read -r UBERDEV_ROOT_EDGE_ID; then :; fi' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E21 -- the `command` prefix. It suppresses FUNCTION lookup only, so the builtin
# still runs in the current shell and still binds the name.
edge_differential E21 "$EXPORT_ANCHOR" \
  "$(prepend_line 'command read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E22 -- the `builtin` prefix, on the `printf` arm so neither arm is pinned by
# the `read` rows alone.
edge_differential E22 "$EXPORT_ANCHOR" \
  "$(prepend_line 'builtin printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E23 -- the `time` keyword. Its pipeline runs in the current shell, so the
# binding survives it exactly as it survives `!`.
edge_differential E23 "$EXPORT_ANCHOR" \
  "$(prepend_line 'time read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E24 -- COMMENT PROSE IS NOT A COMMAND, and this exact line is why. It is
# solve-launcher.sh's `# Inconclusive (read blip or comment not yet indexed)`
# comment verbatim plus a `$TMPDIR`: an English sentence in which
# the words `comment` and `read` happen to follow a `(`. Parsed as a command it
# yields the "bound names" blip/or/comment/not/yet/indexed, and the live file was
# clean only because none of those six words contains a `$`. Want 0 -- editing an
# unrelated comment must never red the edge-id guard.
edge_differential E24 "$EXPORT_ANCHOR" \
  "$(prepend_line '    # Inconclusive (read blip or comment not yet indexed in $TMPDIR): warn + proceed' "$EXPORT_ANCHOR")" 0

# E25 -- the same class inside EXECUTABLE code: prose in a double-quoted string.
# A quoted `;` is not a command boundary, and this `read` is an ARGUMENT to
# `echo` rather than a command word, so the line must stay rc 0 -- while the same
# builtin reached through an UNQUOTED boundary stays rc 1, which is what E13
# (after a `;`) and E20 (after `if !`) hold down. What makes this one clean is
# the POSITION, not the quotes: a quoted verb IS a verb (`"read" -r VAR` binds,
# and E35-E38 pin that), so a rule that read "quoted text is not code" would be
# right here for a reason that is false one word to the left.
# Without this row the comment fix could be a bare "strip from the first `#`",
# which leaves the whole argument half of the class open.
edge_differential E25 "$EXPORT_ANCHOR" \
  "$(prepend_line 'echo "if read fails we fall back to $DEFAULT"' "$EXPORT_ANCHOR")" 0

# E26 -- the COMMENT TAIL of a real command. E24/E25 scope where the VERB may be
# found; this scopes where its ARGUMENTS end. `read -r VAR  # ...` is the most
# ordinary line in shell, and every word of the comment used to become a bound
# name (measured: `['-r','line','#','read','the','value','out','of','$TMPDIR']`),
# so any comment holding a `$` red the guard with a diagnostic about a binding
# that is not there. Want 0, for the same reason E24 wants 0.
edge_differential E26 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r line  # read the value out of $TMPDIR' "$EXPORT_ANCHOR")" 0

# E27 -- the two ways the E26 fix goes wrong, in one line. Stopping the word scan
# at any `#` rather than at one that STARTS a word would split `${#A[@]}` and
# lose the target; dropping the whole line at the first `#` would take the
# binding with it. The code BEFORE a trailing comment is command text and stays
# in scope, so this is rc 1 -- as it was before E26 existed.
edge_differential E27 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "${#A[@]}"  # bind it' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E28 -- HEREDOC BODY PROSE, the same class as E24 one construct over and the one
# with a live corpus surface: the mutant is a line of solve-launcher.sh's
# `CLAIM_BODY` heredoc body with one clause added. That body is user-facing English full of `$VAR`, so a
# sentence in which the word `read` happens to follow a `(` used to be parsed as a
# binding and red E1 on a CI-gating file for a wording edit. Nothing a heredoc
# body contains can bind in the current shell -- an unquoted body expands, and an
# expansion runs in a subshell -- so the body is not command text. Want 0.
edge_differential E28 "$EXPORT_ANCHOR" \
  "$(prepend_line 'cat <<UBERDEV_E28_BODY
Auto-clears on /merge or issue close (read $ISSUE_NUM to confirm).
UBERDEV_E28_BODY' "$EXPORT_ANCHOR")" 0

# E29 -- the same scoping stated at full strength: a REAL binding inside a body is
# rc 0 too, because it binds nothing there. This is a deliberate narrowing of the
# rule (it was rc 1 before), so it is pinned rather than left as a register claim
# no row would notice going the other way.
edge_differential E29 "$EXPORT_ANCHOR" \
  "$(prepend_line 'cat <<UBERDEV_E29_BODY
printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"
UBERDEV_E29_BODY' "$EXPORT_ANCHOR")" 0

# E30 -- and the body ENDS. A delimiter the tracker fails to recognise would
# swallow every line after it, silently turning L2b off for the rest of the file
# while E1-E29 all still passed. The binding here sits after the terminator and
# must still be rc 1, which no other row can say.
edge_differential E30 "$EXPORT_ANCHOR" \
  "$(prepend_line 'cat <<UBERDEV_E30_BODY
Auto-clears on /merge or issue close (read $ISSUE_NUM to confirm).
UBERDEV_E30_BODY
printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E31 -- the heredoc must be FOUND, and the launcher's own two bodies are opened
# from inside a double-quoted string: plugins/uberdev/lib/solve-launcher.sh
# opens both as `CLAIM_BODY="$(cat <<EOF` and `RELEASE_BODY="$(cat <<EOF`.
# The `"` closes three lines later, so a line-oriented quote tracker reads the
# `<<EOF` as quoted text and finds no opener at all -- which is why the delimiter
# scan looks THROUGH double quotes, and why that decision needs a row. Teaching
# it to skip them (the obvious "quotes are not code" edit) returns both live
# bodies to command scope, and E28's unquoted `cat <<WORD` cannot tell -- with
# that edit applied, E1-E30 all still passed and only this shape moved: rc 0 as
# the rule stands, rc 1 with the skip. The body text is E28's verbatim, so the
# one thing this row varies is where the heredoc was opened from.
edge_differential E31 "$EXPORT_ANCHOR" \
  "$(prepend_line 'CLAIM_X="$(cat <<UBERDEV_E31_BODY
Auto-clears on /merge or issue close (read $ISSUE_NUM to confirm).
UBERDEV_E31_BODY
)"' "$EXPORT_ANCHOR")" 0

# E32 -- and an opener whose delimiter NEVER arrives is not an opener. Without
# that rule a stray `<<WORD` blanks every line after it, so L2b silently stops
# running over the rest of the file -- the exact failure E30 guards one line at a
# time, but unbounded and with nothing to notice it: measured rc 0 with the rule
# removed, and E1-E31 ALL still pass in that state. A real heredoc left unclosed
# is a shell syntax error, so text is the likelier reading and refusing to blank
# is also the safe direction.
edge_differential E32 "$EXPORT_ANCHOR" \
  "$(prepend_line 'cat <<UBERDEV_E32_NEVER
printf -v UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E33-E34 pin the two `printf -v` TARGET spellings, and they are here because a
# round of review found both branches shipped and pinned by nothing: deleting the
# quoted-target unwrap, or the attached-option branch, left every row from E1 to
# E32 passing while a plain `printf -v` on the root edge id went silent.
# Measured, each against a checker with only that branch removed: E33's line goes
# rc 1 -> rc 0 with the unwrap gone (E34's is unmoved), E34's goes rc 1 -> rc 0
# with the attached-option branch gone (E33's is unmoved). Neither shape appeared
# anywhere in this file before these two rows.

# E33 -- the target written as a fully-quoted literal. `printf -v "NAME"` binds
# NAME exactly as `printf -v NAME` does, so the quotes may not be what decides.
edge_differential E33 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v "UBERDEV_ROOT_EDGE_ID" '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E34 -- the option and its argument written as ONE word. `printf -vNAME` is the
# same command as `printf -v NAME`; a name extractor that only ever looks at the
# NEXT word reads this one as a format string and reports nothing.
edge_differential E34 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -vUBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E35-E39 pin WHERE THE VERB MAY BE WRITTEN, the other half of the scoping E24
# and E25 hold down. Those two say prose is not a command; these five say a
# command is still a command when it is spelled unusually. Quoting a command word
# removes nothing but alias expansion, and a redirection may precede the command
# word -- so all five of these lines really do bind the root edge id in the
# current shell (verified under both `bash -c` and `zsh -c`), and all five were
# measured rc 0 before the site scan learned to read a word the way the shell
# reads one. They are the same argument E20-E23 make for `!`/`command`/`builtin`/
# `time`: a spelling that changes nothing about what the builtin binds may not be
# a way past the rule.

# E35 -- the verb fully double-quoted.
edge_differential E35 "$EXPORT_ANCHOR" \
  "$(prepend_line '"read" -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E36 -- the verb fully SINGLE-quoted, on the `printf` arm so neither the quoting
# style nor the arm is pinned only by E35.
edge_differential E36 "$EXPORT_ANCHOR" \
  "$(prepend_line "'printf' -v UBERDEV_ROOT_EDGE_ID '%s' \"\$V\"" "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E37 -- quoting PART of the verb. This is the row that forbids the cheap fix of
# unwrapping a word that happens to be quoted end to end: `rea"d"` is one word
# whose literal text is `read`, and only per-character quote removal sees it.
edge_differential E37 "$EXPORT_ANCHOR" \
  "$(prepend_line 'rea"d" -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E38 -- a backslash-escaped verb: quoting by a fourth spelling that none of
# E35-E37 reaches, and the one closest to a row that already exists -- `\read` is
# E20's `if ! read` with one character in front of the verb instead of two.
edge_differential E38 "$EXPORT_ANCHOR" \
  "$(prepend_line '\read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E39 -- a REDIRECTION before the command word. `>/dev/null read -r VAR` binds in
# the current shell for exactly the reason `command read -r VAR` does (E21), and
# a redirection is allowed anywhere a transparent prefix is.
#
# This is the one payload carrying an absolute-POSIX-looking token, so it is the
# row that depends on `mut` handing its payload over on STDIN rather than through
# an exec boundary -- see the transport note there. Do not spell the target
# relatively to dodge that: the redirection is what the row exists to pin, and
# the transport is what has to be right.
edge_differential E39 "$EXPORT_ANCHOR" \
  "$(prepend_line '>/dev/null read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E40-E49 pin the SCOPING VOCABULARY itself -- the boundary characters and the
# keywords after which a command word may stand. Every one of them was shipped
# and pinned by nothing: measured by deleting exactly ONE member from a copy of
# the checker and running this whole file, `bash tests/solve-run-tree.test.sh`
# came back rc 0 for `&`, `|`, `(`, `)`, `{`, `then`, `else`, `do`, `until` and
# `elif` alike, while the evasion line below each went rc 1 -> rc 0. Only `;`
# (E13), `while` (E18) and `if` (E20) were held down. A member no row would
# notice being deleted is the "guard whose predicate is disjoint from the drift
# it must find" shape this block exists to police, and `&` is the commonest mid-
# line command position in the language after `;`.
#
# ONE ROW PER MEMBER, deliberately: an rc is binary, so a single mutant line
# carrying several shapes would stay rc 1 on the strength of whichever member
# survived and hide the deletion of every other. Collapsing is only sound for a
# false-positive row (E51), where any member's deletion flips the same 0 to 1.

# E40 -- `&&`. The cheapest mid-line command position there is after E13's `;`.
edge_differential E40 "$EXPORT_ANCHOR" \
  "$(prepend_line 'true && read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E41 -- a PIPELINE. This one carries the only stated justification for reporting
# a subshell site at all (`echo x | read -r VAR` binds under zsh, whose last
# pipeline element runs in the current shell), so dropping `|` would retire that
# rationale silently while every other row stayed green.
#
# The reader token is SPLIT (`re''ad`), which is not decoration: this file sets
# `pipefail`, so tests/epipe-guard.test.sh E1 scans it, and that scan is a text
# match over the source -- it cannot tell a mutant that is DATA from a pipeline
# this file would run. Written contiguously the row reds that guard on both CI
# jobs while asserting nothing about EPIPE. Splitting is the same runtime
# assembly that guard performs on its own fixtures -- its `_R='re''ad'`, under
# the comment beginning "Every offending fixture line is assembled at RUNTIME"
# (referenced by content, not by line, for the reason the row-count floor at the
# end of this block gives -- and by content rather than by ROW LABEL too, since
# that floor's own label moves every time a row is appended). The shell
# concatenates the two quoted halves before `prepend_line` ever sees them, so
# the mutant text is byte-identical to the contiguous spelling; measured, as is
# the differential on it -- this file goes rc 1 naming E41 with `|` deleted from
# BOUNDARY_CHARS, and rc 0 with the checker unmutated.
edge_differential E41 "$EXPORT_ANCHOR" \
  "$(prepend_line 'echo x | re''ad -r UBERDEV_ROOT_EDGE_ID' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E42 -- a command substitution opens a command position at its `(`. Two things
# about this line are measured rather than chosen, and both had to be, because
# the obvious spelling of the row pins NOTHING:
#   * the `$( … )` is UNQUOTED. Inside `X="$( … )"` the whole right-hand side is
#     one word to a line-oriented word scan, so nothing after the `(` is ever
#     reached as a command (rc 0 -- the same reason a `$( … )` in a heredoc body
#     is out of scope);
#   * the substitution follows a WORD that closes the command position. Written
#     as `X=$(read -r …)` the row is green with `(` deleted from BOUNDARY_CHARS,
#     because `X=$` is an inline assignment and those are transparent -- the
#     command position was still open and the `(` decided nothing. After `echo`
#     it is shut, so only the boundary can reopen it: rc 1 as the rule stands,
#     rc 0 with `(` removed, and E1-E60 all still pass in that state.
# This is also the row that reports a SUBSHELL site -- a deliberate
# over-approximation in the safe direction, argued in the scoping bullet of
# tests/launcher_edge_ids.py.
edge_differential E42 "$EXPORT_ANCHOR" \
  "$(prepend_line 'echo $(read -r UBERDEV_ROOT_EDGE_ID)' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E43 -- a `case` arm. Its `)` is a command position, and the launcher's own tier
# dispatch is a `case`, so this is where a composed id would most plausibly land.
edge_differential E43 "$EXPORT_ANCHOR" \
  "$(prepend_line 'case "$T" in trivial) read -r UBERDEV_ROOT_EDGE_ID ;; esac' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E44 -- a brace group. `{` opens a command position; `}` closes one and is
# deliberately NOT a boundary, which is why the binding is written after the `{`.
edge_differential E44 "$EXPORT_ANCHOR" \
  "$(prepend_line '{ read -r UBERDEV_ROOT_EDGE_ID ; }' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E45 -- `then`.
edge_differential E45 "$EXPORT_ANCHOR" \
  "$(prepend_line 'if true; then read -r UBERDEV_ROOT_EDGE_ID; fi' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E46 -- `else`.
edge_differential E46 "$EXPORT_ANCHOR" \
  "$(prepend_line 'if false; then :; else read -r UBERDEV_ROOT_EDGE_ID; fi' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E47 -- `do`, reached from a `for` head rather than E18's `while`.
edge_differential E47 "$EXPORT_ANCHOR" \
  "$(prepend_line 'for x in a; do read -r UBERDEV_ROOT_EDGE_ID; done' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E48 -- `until`, the `while` loop head's twin: E18 pins one and no row pinned
# the other.
edge_differential E48 "$EXPORT_ANCHOR" \
  "$(prepend_line 'until read -r UBERDEV_ROOT_EDGE_ID; do :; done' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E49 -- `elif`.
edge_differential E49 "$EXPORT_ANCHOR" \
  "$(prepend_line 'if false; then :; elif read -r UBERDEV_ROOT_EDGE_ID; then :; fi' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E50-E51 pin `read`'s OPTION GRAMMAR, the other half of E17. E17 forbids the
# grammar from getting greedier (`-r` must not swallow the target); these two
# forbid it from being dropped.

# E50 -- `-a NAME` binds NAME, so its argument is a TARGET and not a value. The
# ATTACHED spelling is what pins it: with `a` removed from READ_NAME_OPTS the
# spaced `read -a NAME` is unmoved (the name is simply read as the first bare
# word instead), while `read -aNAME` goes rc 1 -> rc 0 with the whole option word
# swallowed. Measured both ways.
edge_differential E50 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -aUBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E51 -- the option letters that take a VALUE, all seven on one line and want 0.
# Collapsing is sound here precisely because the row is a false-positive floor:
# delete ANY of `d i n N p t u` from READ_VALUE_OPTS and that letter's argument
# stops being consumed, becomes an apparent target, and -- being an expansion --
# is reported as an indeterminate binding. So all seven flip the same 0 to 1 and
# one row holds every one of them down. Measured per letter, not assumed.
# `read -p "Enter a $NAME: " _x` is the live shape of this: an unrelated prompt
# would start redding the guard, which is the E19/E26 false-positive class.
#
# The prompt carries a SPACE deliberately, and that is a second member this row
# holds down at no extra cost. `word_end`'s double-quote branch -- the one that
# makes a quoted run part of the word it sits in instead of ending it -- shipped
# pinned by nothing: with it deleted, this whole file was rc 0 while a realistic
# prompt went rc 0 -> rc 1, because `"Enter` becomes `-p`'s value and the words
# behind it (`a`, `$NAME:`, `"`) become apparent targets. Written `-p "$P"`, with
# no space inside the quotes, the row could not see that deletion at all: the
# prompt is one word either way. Collapsing it here is sound for the same reason
# the seven letters collapse -- every one of these deletions flips the same 0
# to 1 -- and a space is what any prompt worth writing carries, which is what
# makes this spelling the realistic one rather than a contrivance for the mutant.
edge_differential E51 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -d "$D" -i "$I" -n "$N" -N "$M" -p "Enter a $NAME: " -t "$T" -u "$U" _x' "$EXPORT_ANCHOR")" 0

# E52-E57 pin HOW THE BOUND NAME IS SPELLED, and they are the exact mirror of
# E35-E38: a round of review found the walk unquoting the VERB while the TARGET
# was still matched against its source spelling, so one backslash or one quote
# pair anywhere in the name walked past the guard on the very variable this file
# exists to protect. The five want-1 lines were each measured rc 0 before, and
# each was EXECUTED under `bash -c` (E52 and E53 under `zsh -c` as well) to
# confirm it really binds `UBERDEV_ROOT_EDGE_ID` rather than some other name.
# E55 and E56 are the false-positive floors of the same change, and they are why
# the quoting is REMOVED rather than STRIPPED: which name a word denotes does not
# depend on how it was quoted, but whether the characters inside it are still
# special does, and both of these lines bind nothing at all.

# E52 -- a backslash-escaped NAME. `\read` was judged worth E38 because it is one
# character in front of the verb; this is the same character one word later.
edge_differential E52 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v \UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E53 -- quoting PART of the name: E37 for the target. A name unwrapped only when
# it is quoted end to end (the cheap fix E37 forbids for the verb) does not see
# this one, and neither does a match against the raw spelling.
edge_differential E53 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r UBERDEV_ROOT_EDGE"_ID" <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E54 -- an array SUBSCRIPT. `read -r NAME[0]` binds element 0, and `$NAME` reads
# that element back, so the name that matters is the BASE and a trailing `[...]`
# may not be a way past the rule (executed: `echo "$UBERDEV_ROOT_EDGE_ID"` prints
# what was read).
edge_differential E54 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r UBERDEV_ROOT_EDGE_ID[0] <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E55 -- and the false-positive floor of that same change, want 0. What makes a
# target undecidable is the CONTEXT its `$` stands in, not the character: inside
# double quotes it expands (E14, rc 1) and inside single quotes it does not, so a
# single-quoted $_name is a literal NAME -- one bash and zsh both refuse outright
# (`not a valid identifier`, measured under each), which is to say it binds
# nothing at all. A rule that re-derived undecidability by searching the finished
# literal for a `$` would red this line, and E14 could not tell.
edge_differential E55 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v '"'"'$_name'"'"' '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 0

# E56 -- the second false-positive floor, and the row that keeps E52 honest.
# Inside DOUBLE quotes a backslash escapes only `$`, a backtick, `"` and itself,
# so `"\UBERDEV_ROOT_EDGE_ID"` is a name carrying a literal backslash -- which
# bash and zsh both refuse outright (`not a valid identifier`, measured under
# each), which is to say it binds nothing. E52's UNQUOTED `\UBERDEV_ROOT_EDGE_ID`
# is the variable itself. A quote-removal that dropped every backslash it met
# would collapse the two and report this line, and no other row could tell.
#
# The line carries a SECOND command, and it is the other half of that same
# sentence. `"\UBERDEV_ROOT_EDGE_ID"` starts `\U`, which is NOT in the escape
# set, so it never reaches the escape branch and cannot pin it; `"\$NAME"` is
# `\$`, which is -- the branch turns it into the literal name `$NAME`, refused as
# an identifier (measured under bash and zsh) and therefore rc 0. Delete the
# branch and the `$` keeps its expansion mark, the target becomes undecidable,
# and this row goes 0 -> 1 while the whole rest of the file stays green.
# Collapsing the two shapes onto one want-0 line is sound for the reason E51
# gives: a false-positive floor reds if ANY of the shapes it carries flips.
edge_differential E56 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf -v "\UBERDEV_ROOT_EDGE_ID" '"'"'%s'"'"' "$V"; printf -v "\$NAME" '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 0

# E57 -- the OPTION word carries quotes too. `printf "-v" NAME` is the same
# command as `printf -v NAME` (executed: it binds), so recognising `-v` by its
# source spelling leaves the whole rule one quote pair from silent.
edge_differential E57 "$EXPORT_ANCHOR" \
  "$(prepend_line 'printf "-v" UBERDEV_ROOT_EDGE_ID '"'"'%s'"'"' "$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by printf -v'

# E58 -- `eval` with a BARE-WORD payload. `eval read -r VAR` binds in the current
# shell exactly as `command read -r VAR` does (executed under bash and zsh), so
# `eval` belongs in the transparent set for that spelling. It stays residue for a
# QUOTED payload, where the command is a string this checker cannot re-parse --
# the two halves are why the register's RE-PARSED-PAYLOAD entry and this row are
# both true. Named by its content, not by its ordinal, for the reason that entry
# and the scoping bullet both give: an ordinal rots the moment an entry is added,
# and it reads as intact while sending the reader elsewhere.
edge_differential E58 "$EXPORT_ANCHOR" \
  "$(prepend_line 'eval read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E59 -- a redirection INSIDE the argument list. A redirection may stand anywhere
# in a simple command, so the words after one are still targets (executed: this
# line binds the root edge id). E39 pins a redirection before the verb; a word
# scan that merely STOPPED at the first `<` lost every target behind it, which is
# the same silence one construct later.
edge_differential E59 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r <<<"$V" UBERDEV_ROOT_EDGE_ID' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E60 -- the `time` keyword's own OPTION word. `time -p read -r VAR` binds the
# name in bash exactly as E23's bare `time read` does, because `-p` selects the
# keyword's POSIX output format rather than naming the command; measured rc 0
# before, and executed to confirm it really binds. zsh has no such option and
# runs `-p` as the command, so the option is accepted only directly behind
# `time` -- which is what stops it from becoming a bare `-p` prefix that opens a
# command position anywhere.
edge_differential E60 "$EXPORT_ANCHOR" \
  "$(prepend_line 'time -p read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E61 -- a DECLARED over-approximation, pinned so that closing it cannot leave
# the declaration stale. The scan is line-oriented and carries no cross-line
# quote state, so the continuation lines of a multi-line double-quoted string are
# read as command text and a `read` in that prose is reported as a binding that
# does not exist. It is the E24/E28 false-positive class one construct over, and
# it is NOT latent: the launcher writes most of its prose through heredocs, but
# four multi-line double-quoted strings are open in it today -- :265, and the
# three embedded python programs at :365, :1180 and :1261, the last being the run
# carrier this file exists for. Inserting the prose line `read the $ISSUE_NUM
# log` as a continuation of any one of the four is rc 1 apiece; the same line
# without the `$` is rc 0 apiece. So the exposure is one `$` away from exactly
# the unrelated wording edit E24/E28 were written to prevent, not a hypothetical.
# The fix is not free -- an unbalanced `"` in a comment would then blank the rest
# of the file, the failure E32 exists to forbid -- so the behaviour is written
# down as the third cost of tests/launcher_edge_ids.py's scoping bullet, and this
# row makes that sentence a measurement rather than a claim.
#
# Assert the sentence is THERE first. A pin whose declaration was never written
# is a guard disjoint from what it is supposed to hold down -- the very shape
# this block exists to police -- and it is invisible from the row alone, which
# goes on measuring the behaviour happily either way. The two anchors are the
# MECHANISM and the back-reference, so deleting the declaration when the
# over-approximation is closed reds here instead of orphaning this row.
grep -q 'no cross-line quote state' "$EDGE_CHECK" || {
  echo "E61: tests/launcher_edge_ids.py no longer declares the multi-line double-quoted over-approximation -- this row pins a behaviour nothing declares" >&2; exit 1; }
grep -q 'E61' "$EDGE_CHECK" || {
  echo "E61: tests/launcher_edge_ids.py's declaration no longer names E61 as its pin -- closing the over-approximation would leave this row orphaned" >&2; exit 1; }
edge_differential E61 "$EXPORT_ANCHOR" \
  "$(prepend_line 'UBERDEV_E61_MSG="Auto-clears on /merge or issue close
read the $ISSUE_NUM to confirm"' "$EXPORT_ANCHOR")" 1 1 \
  'binds an indeterminate target'

# E62-E67 pin the OPTION WORDS OF THE TRANSPARENT PREFIXES themselves. E21-E23
# put `command`, `builtin` and `time` in the transparent set and E58 put `eval`
# there, but each of those four parses OPTIONS OF ITS OWN before its command
# word, and a walk that knew nothing of them shut the command position one word
# BEFORE the verb -- so every shape below measured rc 0 against the round that
# shipped E58-E60, and every one of them BINDS. Executed under bash (the shell
# both this file and the launcher run as), reading the variable back:
#
#     command -p read -r V     [bound]      command -- read -r V     [bound]
#     command -p -p read -r V  [bound]      time -- read -r V        [bound]
#     builtin -- read -r V     [bound]      eval -- read -r V        [bound]
#
# This is the silent-miss direction -- #536's own defect class, a binding form
# that walks past the guard -- and it sits ONE FLAG behind rows that already
# exist, which is the same "cheapest evasion there is" argument that justifies
# E20 (`if ! read`, the E18 loop head one `!` away) and E38 (`\read`, E20's verb
# with one character in front of it). `time -p` (E60) was the one member of this
# family the file already modelled; E62-E66 are the five remaining members and
# E67 is the floor from the other side, each measured against bash's own grammar
# rather than guessed at.
#
# The family does not end at E67, and this sentence is here so that the range in
# the line above cannot be read as a closed one: `command`'s option has a second,
# ATTACHED spelling (`command -pp`), which a later round found still rc 0 and
# still binding. It is pinned by E69, appended below rather than inserted here
# for the reason E68 gives.

# E62 -- `command -p`, DOUBLED, and the doubling is what makes one row do two
# jobs. `command` may be given `-p` more than once (`command -p -p read` binds,
# executed) while the `time` keyword may not (`time -p -p read` is `-p: command
# not found`), so the repeat is a member in its own right. Deleting `-p` from
# `command`'s option set and dropping `command` from the repeat set each take
# THIS line from rc 1 to rc 0, which is a conjunction rather than the collapse
# E40-E49 forbids: both members are needed to see one shape, so either deletion
# reds the row instead of hiding behind the other.
edge_differential E62 "$EXPORT_ANCHOR" \
  "$(prepend_line 'command -p -p read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E63 -- `command --`. The end-of-options word is accepted by every prefix that
# parses options at all, so it needs a row per prefix for the reason E40-E49
# gives: an rc is binary, and one mutant line carrying all four would stay rc 1
# on whichever prefix survived.
edge_differential E63 "$EXPORT_ANCHOR" \
  "$(prepend_line 'command -- read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E64 -- `builtin --`. `builtin` takes NO other option (`builtin -p read` is
# `-p: invalid option`, executed), so `--` is the whole of its grammar and this
# row is the only thing that can pin it.
edge_differential E64 "$EXPORT_ANCHOR" \
  "$(prepend_line 'builtin -- read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E65 -- `time --`. The keyword takes `-p` (E60) and `--`, and E60 cannot see
# this one: with `--` deleted from `time`'s options E60 stays rc 1 on its own
# `-p` spelling while this line goes silent.
edge_differential E65 "$EXPORT_ANCHOR" \
  "$(prepend_line 'time -- read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E66 -- `eval --`. E58 pins `eval` with a bare-word payload; this is that same
# payload behind the end-of-options word, which bash's `eval` consumes exactly as
# `command` does (`eval -- read -r V` binds, executed) -- and note `eval -p` does
# NOT (`-p: invalid option`), which is why the option sets are per prefix rather
# than one shared list.
edge_differential E66 "$EXPORT_ANCHOR" \
  "$(prepend_line 'eval -- read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E67 -- and the floor from the other side, want 0: E62-E66 and E69 forbid the
# option grammar from being DROPPED, this one forbids it from getting greedier,
# exactly as E17 does for `read`'s own options against E50/E51. Seven shapes on
# one line, collapsed for the reason E51 gives (any of them flipping reds the
# row), and every one of them binds NOTHING under bash, executed and read back:
#   `command -v read`      `-v` PRINTS the command instead of running it;
#   `! -- read`            `!` takes no options, so `--` is the command word
#                          itself (`--: command not found`);
#   `command -- -p read`   `--` ENDS the option list, so `-p` behind it is the
#                          command word (`-p: command not found`);
#   `time -p -p read`      the keyword's `-p` is not repeatable;
#   `builtin -- -- read`   nor is `--`, for any prefix;
#   `command -pv read`     a CLUSTER is only an option while every letter in it
#                          is one, and `-v` still prints instead of running --
#                          this is the letter set of E69 pinned from the other
#                          side, and the shape a rule that read `-pv` as "starts
#                          with p" would swallow;
#   `time -pp read`        clustering is per prefix as well: the `time` keyword's
#                          `-p` does not cluster (`-pp: command not found`), so
#                          an empty cluster set is a measurement here rather than
#                          an omission.
# A rule that swallowed any dash-word behind a transparent prefix would report
# all seven, and `command -v` is a live shape in the launcher -- `command -v
# uberdev_read_enum` is one of its own guard lines. No probe there puts `read` or
# `printf` in the word after the option, so nothing is red under such a rule
# today; what it would be doing is reading a probe's ARGUMENT as a command, which
# is the E19/E26 false-positive class one helper rename away. (Counted nowhere on
# purpose: a tally of the launcher's probes kept here is a number with nothing to
# compare it to, which is the defect the heredoc count already had to be moved to
# a single home to fix.)
edge_differential E67 "$EXPORT_ANCHOR" \
  "$(prepend_line 'command -v read -r UBERDEV_ROOT_EDGE_ID; ! -- read -r UBERDEV_ROOT_EDGE_ID; command -- -p read -r UBERDEV_ROOT_EDGE_ID; time -p -p read -r UBERDEV_ROOT_EDGE_ID; builtin -- -- read -r UBERDEV_ROOT_EDGE_ID; command -pv read -r UBERDEV_ROOT_EDGE_ID; time -pp read -r UBERDEV_ROOT_EDGE_ID' "$EXPORT_ANCHOR")" 0

# E68 -- the TARGET CLASS itself, which is the one thing in this file the rule
# exists to recognise and was held down by nothing. `EDGE_TARGET` is
# `[A-Za-z0-9_]*EDGE_ID`, deliberately one letter-range wider than `ASSIGNMENT`'s
# `[A-Z0-9_]*EDGE_ID`, and tests/launcher_edge_ids.py argues at length that the
# divergence is sound -- but narrowing it back to the uppercase class left every
# other row in this file green while `read -r my_EDGE_ID` went rc 1 -> rc 0. That
# is the silent-miss direction on the target position itself, so the argument
# gets a measurement: an editor "aligning the two house forms" reds here.
#
# Appended rather than inserted beside E52-E57, where it belongs by subject:
# renumbering rows to make room is how a cross-reference goes stale, which is a
# defect this block has already had to repair twice.
edge_differential E68 "$EXPORT_ANCHOR" \
  "$(prepend_line 'read -r my_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E69 -- the ATTACHED spelling of `command -p`, which is the same defect E62-E66
# closed found one spelling further in. `command`'s options are parsed with
# getopts, so `-pp` is ONE WORD carrying two `-p` flags: `command -pp read -r V`
# binds under bash (executed, read back) and measured rc 0 against the round that
# shipped E62-E67, which modelled an option as an exact WORD and so shut the
# command position on `-pp` one word before the verb. Silent miss, #536's own
# defect class, and one character cheaper than E62's spaced `command -p -p`.
#
# This is the file's own standard rather than a new demand: the attached spelling
# is a member of its own everywhere else here -- E34 exists because
# `printf -vNAME` is a separate branch from `printf -v NAME`, and E50 pins
# `read -aNAME` while the spaced `read -a NAME` is unmoved. The one prefix whose
# option can be attached to itself is not the exception.
#
# It pins `PREFIX_CLUSTERS` alone, and that is deliberate: `PREFIX_OPTIONS` keeps
# the one-letter spelling, so emptying the cluster map reds HERE while dropping
# `-p` from `command`'s option words reds E62 -- two distinct losses, neither
# able to hide behind the other. E67 carries the letter set from the want-0 side
# (`command -pv`, `time -pp`).
#
# Appended rather than inserted beside E62-E67, where it belongs by subject, for
# the reason E68 gives: renumbering rows to make room is how a cross-reference
# goes stale, a defect this block has already had to repair twice.
edge_differential E69 "$EXPORT_ANCHOR" \
  "$(prepend_line 'command -pp read -r UBERDEV_ROOT_EDGE_ID <<<"$V"' "$EXPORT_ANCHOR")" 1 1 \
  'bound by read'

# E70 -- row-count floor, mirroring the one in tests/solve-run-tree-scope.test.sh
# (referenced by name, not by line: the number it used to carry had already
# rotted). A row deleted or short-circuited out of the block must fail the file,
# not shrink it -- so the predicate is `-eq`, never `-ge`. A `-ge` floor cannot
# tell "a row was removed" from "a row was added", which is how E11-E69 could
# have been landed while E2-E10 quietly stopped running.
[ "$EDGE_ROWS" -eq 69 ] || {
  echo "FATAL: $EDGE_ROWS edge-id row(s) ran, expected exactly 69 (E1-E69)" >&2; exit 2; }

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
