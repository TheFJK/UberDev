#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ORCHESTRATOR_SKILL_UNDER_TEST:-$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md}"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/orchestrator-child-inputs.XXXXXX")"
RUN_DIR="$TMP/runtime"
HANDOFFS="$RUN_DIR/handoffs"
RECEIPTS="$TMP/receipts/child-dispatch.jsonl"
PROVIDER_CALLS="$TMP/provider-calls"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$RECEIPTS")"
chmod 700 "$(dirname "$RECEIPTS")"
: >"$RECEIPTS"
chmod 600 "$RECEIPTS"
: >"$PROVIDER_CALLS"
chmod 600 "$PROVIDER_CALLS"
export UBERDEV_CHILD_TEST_MODE=1
export UBERDEV_CHILD_TEST_SOURCE='plugins/uberdev/skills/orchestrator/SKILL.md'
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$RECEIPTS"

[ -r "$SKILL" ]

extract_fence() {
  local header="$1" occurrence="$2" output="$3"
  python3 -I -B - "$SKILL" "$header" "$occurrence" "$output" <<'PY'
import re,sys
from pathlib import Path

source,header,occurrence_raw,output=sys.argv[1:]
text=Path(source).read_text()
matches=[]
for match in re.finditer(r'^```bash uberdev-executable([^\n]*)\n(.*?)\n```$',text,re.M|re.S):
    if match.group(1).strip() == header:
        matches.append(match.group(2))
occurrence=int(occurrence_raw)
if occurrence < 1 or occurrence > len(matches):
    raise SystemExit(f'missing executable fence header={header!r} occurrence={occurrence}')
Path(output).write_text(matches[occurrence-1]+'\n')
PY
}

run_fence() {
  local header="$1" occurrence="${2:-1}" slug output
  slug="$(printf '%s-%s' "$header" "$occurrence" | tr -cs 'A-Za-z0-9._-' '_')"
  output="$TMP/$slug.sh"
  extract_fence "$header" "$occurrence" "$output"
  bash -n "$output"
  . "$output" >/dev/null
}

# Load the real executable setup fence, including its production scalar JSON
# serializer and the production child-input APIs sourced from child-dispatch.
extract_fence '' 1 "$TMP/setup.sh"
bash -n "$TMP/setup.sh"
export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{}'
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev"
. "$TMP/setup.sh"

# Build one real immutable root context. A non-path repository id intentionally
# confines every typed child path to RUN_DIR, where the hostile fixture files
# below live.
ROOT_REQUEST_JSON="$(python3 -I -B - "$RUN_DIR" <<'PY'
import json,sys
print(json.dumps({
 'schema_version':1,'run_dir':sys.argv[1],'run_id':'orchestrator-receipt-root',
 'repository_id':'fixture-repository','backend':'codex','workflow':'solve',
 'phase':'lead','role':'lead','task_tier':'large',
 'risk_signals':['concurrency','security'],'issue_or_pr':42,'issue_num':42,
 'capacity':6,'timeout_s':20,'routing_mode':'adaptive',
},sort_keys=True,separators=(',',':')))
PY
)"
mkdir -p "$RUN_DIR"
ROOT_DECISION_JSON="$(uberdev_agent_resolve_request "$ROOT_REQUEST_JSON")"
ROOT_METADATA_JSON='{"run_id":"orchestrator-receipt-root","repository_id":"fixture-repository","workflow":"solve","backend":"codex","issue_num":42,"task_tier":"large","risk_signals":["concurrency","security"]}'
ROOT_CONTEXT_OUT="$(uberdev_agent_context_create "$RUN_DIR" "$ROOT_REQUEST_JSON" "$ROOT_DECISION_JSON" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$ROOT_METADATA_JSON" '2026-07-11T00:00:00Z')"
ROOT_CONTEXT_FILE="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"],end="")' "$ROOT_CONTEXT_OUT")"
ROOT_CONTEXT_SHA="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"],end="")' "$ROOT_CONTEXT_OUT")"
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B - "$ROOT_CONTEXT_FILE" "$ROOT_CONTEXT_SHA" <<'PY'
import json,sys
print(json.dumps({'schema_version':1,'run_id':'orchestrator-receipt-root','workflow':'solve','issue_num':42,'context_file':sys.argv[1],'context_sha256':sys.argv[2]},sort_keys=True,separators=(',',':')))
PY
)"
UBERDEV_AGENT_PREPARED_REQUEST_JSON="$ROOT_REQUEST_JSON"
export UBERDEV_RUN_CARRIER_JSON UBERDEV_AGENT_PREPARED_REQUEST_JSON

# Keep the complete production design batch and child-dispatch stack. Only its
# final provider seam is replaced; it must observe child-dispatch's receipt
# before it can publish a completed fixture result/status pair.
uberdev_agent_dispatch() {
  local request="$1" result="$3" status="$4" instance edge backend decision event manifest
  [ "$#" -eq 4 ] || return 2
  instance="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["run_id"],end="")' "$request")" || return 2
  backend="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["backend"],end="")' "$request")" || return 2
  [ "$backend" = codex ] || return 2
  edge="$(python3 -I -B -c 'import json,sys;print(json.load(open(sys.argv[1]))["edge_id"],end="")' "$HANDOFFS/$instance.json")" || return 2
  python3 -I -B - "$RECEIPTS" "$UBERDEV_CHILD_TEST_SOURCE" "$edge" "$instance" <<'PY'
import json
import pathlib
import sys
receipt,source,edge,instance=sys.argv[1:]
rows=pathlib.Path(receipt).read_text().splitlines()
if not rows:
    raise SystemExit('provider seam reached before any dispatch receipt')
last=json.loads(rows[-1])
if (last.get('event'),last.get('source'),last.get('edge_id'),last.get('instance_id')) != ('dispatch',source,edge,instance):
    raise SystemExit(f'provider seam reached before correlated dispatch receipt: {last!r}')
PY
  decision="$(python3 -I -B -c 'import json,sys; r=json.loads(sys.argv[1]); d=r["root_decision"].copy(); d["risk_scope"]=r["risk_scope"]; d["risk_signals"]=r["risk_signals"]; print(json.dumps(d,sort_keys=True,separators=(",",":")),end="")' "$request")" || return 2
  manifest="$RUN_DIR/.agent-state-$(id -u)/agent-lifecycle.jsonl"
  event="$(_uberdev_agent_event_json route_decided "$request" "$decision")" || return 2
  _uberdev_agent_append_event "$manifest" "$event" || return 2
  event="$(_uberdev_agent_event_json agent_started "$request" "$decision" '' "$status")" || return 2
  _uberdev_agent_append_event "$manifest" "$event" || return 2
  printf 'fixture result for %s\n' "$instance" >"$result"
  chmod 600 "$result" || return 2
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"fixture-%s"}\n' "$instance" >"$status"
  chmod 600 "$status" || return 2
  event="$(_uberdev_agent_event_json completed "$request" "$decision")" || return 2
  _uberdev_agent_append_event "$manifest" "$event" || return 2
  printf '%s|%s\n' "$edge" "$instance" >>"$PROVIDER_CALLS"
}

# Hostile but schema-valid values prove the serializer handles whitespace,
# quotes, backslashes, tabs, and JSON arrays without hand concatenation.
WORKING_DIR_ABS="$RUN_DIR"$'/orchestrator hostile "dir" \\segment\t'
mkdir -p "$WORKING_DIR_ABS"
issue_body_path="$WORKING_DIR_ABS"$'/orchestrator hostile "issue" \\body\t.md'
research_codebase_summary_path="$WORKING_DIR_ABS"$'/codebase "summary" \\one\t.md'
research_patterns_summary_path="$WORKING_DIR_ABS"$'/patterns "summary" \\two\t.md'
research_prior_art_summary_path="$WORKING_DIR_ABS"$'/prior "summary" \\three\t.md'
research_constraints_summary_path="$WORKING_DIR_ABS"$'/constraints "summary" \\four\t.md'
research_security_summary_path="$WORKING_DIR_ABS"$'/security "summary" \\five\t.md'
research_test_summary_path="$WORKING_DIR_ABS"$'/tests "summary" \\six\t.md'
format_example_path="$WORKING_DIR_ABS"$'/research "format" \\example\t.md'
followup_summary_path="$WORKING_DIR_ABS"$'/followup "summary" \\path\t.md'
scope_shift_question=$'Which "quoted" scope uses \\ paths?\t'
scope_shift_answer=$'Use the \\new "scope".\t'
followup_format_example_path="$WORKING_DIR_ABS"$'/followup "format" \\example\t.md'
qa_answers_path="$WORKING_DIR_ABS"$'/questions "answers" \\path\t.md'
spec_summary_path="$WORKING_DIR_ABS"$'/spec "summary" \\path\t.md'
verification_feedback_path="$WORKING_DIR_ABS"$'/spec "feedback" \\path\t.md'
spec_path="$WORKING_DIR_ABS"$'/current "spec" \\path\t.md'
revision_brief_path="$WORKING_DIR_ABS"$'/spec "revision" \\brief\t.md'
spec_review_format_example_path="$WORKING_DIR_ABS"$'/spec-review "format" \\example\t.md'
spec_reviser_format_example_path="$WORKING_DIR_ABS"$'/spec-revise "format" \\example\t.md'
planning_dependency_summary_path="$WORKING_DIR_ABS"$'/dependency "summary" \\path\t.md'
planning_tests_summary_path="$WORKING_DIR_ABS"$'/test-map "summary" \\path\t.md'
planning_risks_summary_path="$WORKING_DIR_ABS"$'/risk "summary" \\path\t.md'
planning_security_summary_path="$WORKING_DIR_ABS"$'/plan-security "summary" \\path\t.md'
dependency_map_path="$WORKING_DIR_ABS"$'/dependency "map" \\path\t.md'
test_map_path="$WORKING_DIR_ABS"$'/test "map" \\path\t.md'
implementation_risk_path="$WORKING_DIR_ABS"$'/implementation "risk" \\path\t.md'
planning_security_output_path="$WORKING_DIR_ABS"$'/planning "security" \\path\t.md'
PLANNING_RESEARCH_OUTPUT_SHIM="$WORKING_DIR_ABS"$'/planning "shim" \\path\t.py'
plan_summary_path="$WORKING_DIR_ABS"$'/plan "summary" \\path\t.md'
plan_write_a1_feedback_path="$WORKING_DIR_ABS"$'/plan-a1 "feedback" \\path\t.md'
plan_write_a2_feedback_path="$WORKING_DIR_ABS"$'/plan-a2 "feedback" \\path\t.md'
plan_path="$WORKING_DIR_ABS"$'/current "plan" \\path\t.md'
plan_review_format_example_path="$WORKING_DIR_ABS"$'/plan-review "format" \\path\t.md'
plan_revision_a1_feedback_path="$WORKING_DIR_ABS"$'/revision-a1 "feedback" \\path\t.md'
plan_revision_a2_feedback_path="$WORKING_DIR_ABS"$'/revision-a2 "feedback" \\path\t.md'
tier='large'

for fixture_path in \
  "$issue_body_path" "$research_codebase_summary_path" "$research_patterns_summary_path" \
  "$research_prior_art_summary_path" "$research_constraints_summary_path" \
  "$research_security_summary_path" "$research_test_summary_path" "$format_example_path" \
  "$followup_summary_path" "$followup_format_example_path" "$qa_answers_path" \
  "$spec_summary_path" "$verification_feedback_path" "$spec_path" "$revision_brief_path" \
  "$spec_review_format_example_path" "$spec_reviser_format_example_path" \
  "$planning_dependency_summary_path" "$planning_tests_summary_path" \
  "$planning_risks_summary_path" "$planning_security_summary_path" \
  "$dependency_map_path" "$test_map_path" "$implementation_risk_path" \
  "$planning_security_output_path" "$PLANNING_RESEARCH_OUTPUT_SHIM" "$plan_summary_path" \
  "$plan_write_a1_feedback_path" "$plan_write_a2_feedback_path" "$plan_path" \
  "$plan_review_format_example_path" "$plan_revision_a1_feedback_path" \
  "$plan_revision_a2_feedback_path"; do
  printf 'private hostile fixture: %s\n' "${fixture_path##*/}" >"$fixture_path"
  chmod 600 "$fixture_path"
done

research_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' \
  "$research_codebase_summary_path" "$research_patterns_summary_path")"
planning_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' \
  "$dependency_map_path" "$test_map_path" "$implementation_risk_path")"
validated_risk_signals_json='["concurrency","security"]'

# Execute every base research/follow-up/spec/plan/review callsite fence.
for edge in codebase patterns prior_art constraints security test_coverage; do
  run_fence "edge=orchestrator.research.$edge"
done
run_fence 'barrier=orchestrator.research'

failed_inputs_json="$GENERAL_CODEBASE_INPUTS"
failed_edge='orchestrator.research.codebase'
failed_instance='orchestrator-research-codebase-a1'
failed_role='research-codebase'
failed_phase='research'
failed_risks_json='[]'
run_fence 'retry=format'

run_fence 'edge=orchestrator.research.followup'
run_fence 'edge=orchestrator.research.followup retry=format'
run_fence 'edge=orchestrator.spec.write'
run_fence 'edge=orchestrator.spec.write retry=verification'
run_fence 'edge=orchestrator.spec.review'
run_fence 'edge=orchestrator.spec.review retry=format'

spec_reviser_format_invalid=1
spec_reviewer_format_invalid=1
spec_review_verdict='APPROVE'
run_fence 'edge=orchestrator.spec.revise'

run_fence 'edge=orchestrator.plan.research.dependency'
run_fence 'edge=orchestrator.plan.research.tests'
run_fence 'edge=orchestrator.plan.research.risks'
run_fence 'edge=orchestrator.plan.research.security'
run_fence 'barrier=orchestrator.plan.research'
run_fence 'edge=orchestrator.plan.write' 1
plan_write_verification_failed=1
run_fence 'edge=orchestrator.plan.write retry=verification'
run_fence 'edge=orchestrator.plan.review' 1
run_fence 'edge=orchestrator.plan.review retry=format'

plan_revision_verification_failed=1
plan_rereview_format_invalid=1
run_fence 'edge=orchestrator.plan.write' 2

python3 -I -B - "$RECEIPTS" "$HANDOFFS" "$PROVIDER_CALLS" "$UBERDEV_CHILD_TEST_SOURCE" <<'PY'
import hashlib,json,re,sys
from collections import Counter
from pathlib import Path

receipt_path,handoff_dir,provider_path,source=sys.argv[1:]
expected_instances={}
def expect(edge,*instances):
    for instance in instances:
        if instance in expected_instances: raise AssertionError(instance)
        expected_instances[instance]=edge

expect('orchestrator.research.codebase',
       'orchestrator-research-codebase-a1','orchestrator-research-codebase-a2')
expect('orchestrator.research.patterns','orchestrator-research-patterns-a1')
expect('orchestrator.research.prior_art','orchestrator-research-prior-art-a1')
expect('orchestrator.research.constraints','orchestrator-research-constraints-a1')
expect('orchestrator.research.security','orchestrator-research-security-a1')
expect('orchestrator.research.test_coverage','orchestrator-research-test-coverage-a1')
expect('orchestrator.research.followup',
       'orchestrator-research-followup-a1','orchestrator-research-followup-a2')
expect('orchestrator.spec.write','orchestrator-spec-write-a1','orchestrator-spec-write-a2')
expect('orchestrator.spec.review',
       'orchestrator-spec-review-a1','orchestrator-spec-review-a2',
       'orchestrator-spec-review-r1-a1','orchestrator-spec-review-r1-a2')
expect('orchestrator.spec.revise',
       'orchestrator-spec-revise-r1-a1','orchestrator-spec-revise-r1-a2')
expect('orchestrator.plan.research.dependency','orchestrator-plan-research-dependency-a1')
expect('orchestrator.plan.research.tests','orchestrator-plan-research-tests-a1')
expect('orchestrator.plan.research.risks','orchestrator-plan-research-risks-a1')
expect('orchestrator.plan.research.security','orchestrator-plan-research-security-a1')
expect('orchestrator.plan.write',
       'orchestrator-plan-write-a1','orchestrator-plan-write-a2','orchestrator-plan-write-a3',
       'orchestrator-plan-write-r1-a1','orchestrator-plan-write-r1-a2','orchestrator-plan-write-r1-a3')
expect('orchestrator.plan.review',
       'orchestrator-plan-review-a1','orchestrator-plan-review-a2',
       'orchestrator-plan-review-r1-a1','orchestrator-plan-review-r1-a2')

expected_edges={
 'orchestrator.research.codebase','orchestrator.research.patterns',
 'orchestrator.research.prior_art','orchestrator.research.constraints',
 'orchestrator.research.security','orchestrator.research.test_coverage',
 'orchestrator.research.followup','orchestrator.spec.write',
 'orchestrator.spec.review','orchestrator.spec.revise',
 'orchestrator.plan.research.dependency','orchestrator.plan.research.tests',
 'orchestrator.plan.research.risks','orchestrator.plan.research.security',
 'orchestrator.plan.write','orchestrator.plan.review',
}
if set(expected_instances.values()) != expected_edges or len(expected_instances) != 31:
    raise SystemExit('invalid receipt expectation fixture')

handoff_root=Path(handoff_dir)
actual_files={path.stem:path for path in handoff_root.glob('*.json')}
if set(actual_files) != set(expected_instances):
    raise SystemExit(f'handoff identity mismatch: expected={sorted(expected_instances)!r} actual={sorted(actual_files)!r}')

expected_build=Counter()
expected_correlated=Counter()
for instance,edge in expected_instances.items():
    value=json.loads(actual_files[instance].read_text())
    if value.get('instance_id') != instance or value.get('edge_id') != edge:
        raise SystemExit(f'handoff identity/edge mismatch: {instance}')
    inputs=value.get('inputs')
    if not isinstance(inputs,dict):
        raise SystemExit(f'handoff inputs missing: {instance}')
    canonical=json.dumps(inputs,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
    digest=hashlib.sha256(canonical).hexdigest()
    expected_build[(edge,digest)]+=1
    expected_correlated[(edge,instance,digest)]+=1

raw=Path(receipt_path).read_text()
rows=[json.loads(line) for line in raw.splitlines()]
build=Counter(); handoff=Counter(); dispatch=Counter()
for row in rows:
    event=row.get('event')
    keys={'schema_version','event','source','edge_id','inputs_sha256'}
    if event != 'build': keys.add('instance_id')
    if set(row) != keys or row.get('schema_version') != 1:
        raise SystemExit(f'unknown receipt shape: {row!r}')
    if row.get('source') != source or row.get('edge_id') not in expected_edges:
        raise SystemExit(f'unknown receipt source/edge: {row!r}')
    digest=row.get('inputs_sha256')
    if not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest):
        raise SystemExit(f'invalid receipt digest: {row!r}')
    edge=row['edge_id']
    if event == 'build':
        build[(edge,digest)]+=1
    elif event in {'handoff','dispatch'}:
        instance=row.get('instance_id')
        if expected_instances.get(instance) != edge:
            raise SystemExit(f'unknown receipt chain: {row!r}')
        target=handoff if event == 'handoff' else dispatch
        target[(edge,instance,digest)]+=1
    else:
        raise SystemExit(f'unknown receipt event: {row!r}')

if build != expected_build:
    raise SystemExit(f'incomplete build correlations: expected={expected_build!r} actual={build!r}')
if handoff != expected_correlated:
    raise SystemExit(f'incomplete handoff correlations: expected={expected_correlated!r} actual={handoff!r}')
if dispatch != expected_correlated:
    raise SystemExit(f'incomplete dispatch correlations: expected={expected_correlated!r} actual={dispatch!r}')
if len(rows) != 93:
    raise SystemExit(f'unknown receipt count: expected=93 actual={len(rows)}')

provider=[]
for line in Path(provider_path).read_text().splitlines():
    edge,instance=line.split('|',1)
    provider.append((edge,instance))
expected_provider=Counter((edge,instance) for instance,edge in expected_instances.items())
if Counter(provider) != expected_provider:
    raise SystemExit(f'provider seam mismatch: expected={expected_provider!r} actual={Counter(provider)!r}')
PY

export HANDOFFS WORKING_DIR_ABS issue_body_path research_codebase_summary_path
export research_patterns_summary_path research_prior_art_summary_path
export research_constraints_summary_path research_security_summary_path research_test_summary_path
export format_example_path followup_summary_path scope_shift_question scope_shift_answer followup_format_example_path
export qa_answers_path spec_summary_path verification_feedback_path spec_path revision_brief_path
export spec_review_format_example_path spec_reviser_format_example_path
export planning_dependency_summary_path planning_tests_summary_path planning_risks_summary_path planning_security_summary_path
export dependency_map_path test_map_path implementation_risk_path planning_security_output_path PLANNING_RESEARCH_OUTPUT_SHIM
export plan_summary_path plan_write_a1_feedback_path plan_write_a2_feedback_path plan_path plan_review_format_example_path
export plan_revision_a1_feedback_path plan_revision_a2_feedback_path tier
export research_paths_json planning_paths_json validated_risk_signals_json

python3 -I -B - <<'PY'
import json,os
from pathlib import Path

handoffs=Path(os.environ['HANDOFFS'])
env=os.environ

def handoff(instance):
    path=handoffs/f'{instance}.json'
    if not path.is_file():
        raise SystemExit(f'missing production handoff: {instance}')
    try: return json.loads(path.read_text())
    except Exception as error: raise SystemExit(f'invalid production handoff for {instance}: {error}')

def payload(instance):
    value=handoff(instance)
    inputs=value.get('inputs')
    if not isinstance(inputs,dict):
        raise SystemExit(f'missing production handoff inputs: {instance}')
    return inputs

def exact(instance, expected):
    actual=payload(instance)
    if actual != expected:
        raise SystemExit(f'payload mismatch for {instance}: expected={expected!r} actual={actual!r}')

summaries={
 'codebase':'research_codebase_summary_path','patterns':'research_patterns_summary_path',
 'prior-art':'research_prior_art_summary_path','constraints':'research_constraints_summary_path',
 'security':'research_security_summary_path','test-coverage':'research_test_summary_path',
}
for role,key in summaries.items():
    exact(f'orchestrator-research-{role}-a1',{
      'issue_path':env['issue_body_path'],'working_dir':env['WORKING_DIR_ABS'],'summary_path':env[key]})

expected_codebase={
  'issue_path':env['issue_body_path'],'working_dir':env['WORKING_DIR_ABS'],
  'summary_path':env['research_codebase_summary_path'],
  'format_retry':True,'format_example_path':env['format_example_path']}
exact('orchestrator-research-codebase-a2',expected_codebase)

followup={'working_dir':env['WORKING_DIR_ABS'],'summary_path':env['followup_summary_path'],
          'question':env['scope_shift_question'],'answer':env['scope_shift_answer']}
exact('orchestrator-research-followup-a1',followup)
exact('orchestrator-research-followup-a2',followup|{
  'format_retry':True,'format_example_path':env['followup_format_example_path']})

research_paths=json.loads(env['research_paths_json'])
spec_write={'issue_path':env['issue_body_path'],'research_paths':research_paths,
            'questions_path':env['qa_answers_path'],'working_dir':env['WORKING_DIR_ABS'],
            'summary_path':env['spec_summary_path']}
exact('orchestrator-spec-write-a1',spec_write)
exact('orchestrator-spec-write-a2',spec_write|{'verification_feedback_path':env['verification_feedback_path']})

spec_review={'spec_path':env['spec_path'],'issue_path':env['issue_body_path'],
             'research_paths':research_paths,'working_dir':env['WORKING_DIR_ABS']}
exact('orchestrator-spec-review-a1',spec_review)
exact('orchestrator-spec-review-a2',spec_review|{
  'format_retry':True,'format_example_path':env['spec_review_format_example_path']})
spec_revise={'spec_path':env['spec_path'],'revision_path':env['revision_brief_path'],
             'working_dir':env['WORKING_DIR_ABS']}
exact('orchestrator-spec-revise-r1-a1',spec_revise)
exact('orchestrator-spec-revise-r1-a2',spec_revise|{
  'format_retry':True,'format_example_path':env['spec_reviser_format_example_path']})
# Dynamic re-review must use the current spec path, not a cloned stale payload.
exact('orchestrator-spec-review-r1-a1',spec_review)
exact('orchestrator-spec-review-r1-a2',spec_review|{
  'format_retry':True,'format_example_path':env['spec_review_format_example_path']})

plan_base={'spec_path':env['spec_path'],'working_dir':env['WORKING_DIR_ABS'],
           'validation_path':env['PLANNING_RESEARCH_OUTPUT_SHIM']}
for suffix,summary,output in (
 ('dependency','planning_dependency_summary_path','dependency_map_path'),
 ('tests','planning_tests_summary_path','test_map_path'),
 ('risks','planning_risks_summary_path','implementation_risk_path')):
    exact(f'orchestrator-plan-research-{suffix}-a1',plan_base|{
      'summary_path':env[summary],'output_path':env[output]})
exact('orchestrator-plan-research-security-a1',plan_base|{
  'summary_path':env['planning_security_summary_path'],'output_path':env['planning_security_output_path'],
  'risk_signals':json.loads(env['validated_risk_signals_json'])})

planning_paths=json.loads(env['planning_paths_json'])
plan_write={'spec_path':env['spec_path'],'tier':env['tier'],'working_dir':env['WORKING_DIR_ABS'],
            'summary_path':env['plan_summary_path'],'planning_paths':planning_paths,
            'validation_path':env['PLANNING_RESEARCH_OUTPUT_SHIM']}
exact('orchestrator-plan-write-a1',plan_write)
exact('orchestrator-plan-write-a2',plan_write|{'verification_feedback_path':env['plan_write_a1_feedback_path']})
exact('orchestrator-plan-write-a3',plan_write|{'verification_feedback_path':env['plan_write_a2_feedback_path']})

plan_review={'plan_path':env['plan_path'],'spec_path':env['spec_path'],
             'tier':env['tier'],'working_dir':env['WORKING_DIR_ABS']}
exact('orchestrator-plan-review-a1',plan_review)
exact('orchestrator-plan-review-a2',plan_review|{
  'format_retry':True,'format_example_path':env['plan_review_format_example_path']})

revision=plan_write|{'revision_brief_path':env['revision_brief_path']}
exact('orchestrator-plan-write-r1-a1',revision)
exact('orchestrator-plan-write-r1-a2',revision|{
  'verification_feedback_path':env['plan_revision_a1_feedback_path']})
exact('orchestrator-plan-write-r1-a3',revision|{
  'verification_feedback_path':env['plan_revision_a2_feedback_path']})
# Dynamic re-review must use the current plan path, not a cloned stale payload.
exact('orchestrator-plan-review-r1-a1',plan_review)
exact('orchestrator-plan-review-r1-a2',plan_review|{
  'format_retry':True,'format_example_path':env['plan_review_format_example_path']})

for instance in (
 'orchestrator-research-security-a1','orchestrator-plan-research-security-a1'):
    if handoff(instance).get('risk_signals') != json.loads(env['validated_risk_signals_json']):
        raise SystemExit(f'risk mapping mismatch: {instance}')
PY

# Mutation proof: the executable harness must reject a real callsite whose key
# is populated from the wrong production variable. The previous canned test
# silently accepted this exact mutation.
mutation_status='skipped'
if [ "${ORCHESTRATOR_SKIP_MUTATION_PROOF:-0}" != 1 ]; then
  MUTATED="$TMP/orchestrator-mutated.md"
  python3 -I -B - "$SKILL" "$MUTATED" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
old='summary_path "$(uberdev_design_json_string "$research_codebase_summary_path")")"'
new='summary_path "$(uberdev_design_json_string "$issue_body_path")")"'
if old not in source: raise SystemExit('mutation target missing')
Path(sys.argv[2]).write_text(source.replace(old,new,1))
PY
  if ORCHESTRATOR_SKIP_MUTATION_PROOF=1 ORCHESTRATOR_SKILL_UNDER_TEST="$MUTATED" \
      bash "$0" >"$TMP/mutation.out" 2>"$TMP/mutation.err"; then
    echo 'mutation unexpectedly passed: wrong research summary mapping' >&2
    exit 1
  fi
  grep -Fq 'payload mismatch for orchestrator-research-codebase-a1' "$TMP/mutation.err"
  mutation_status='rejected'
fi

printf 'orchestrator-child-inputs: PASS (16 edges, 31 correlated receipt chains, hostile payloads, mutation %s)\n' "$mutation_status"
