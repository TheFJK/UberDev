#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ORCHESTRATOR_SKILL_UNDER_TEST:-$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md}"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/orchestrator-child-inputs.XXXXXX")"
CAPTURE="$TMP/capture"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$CAPTURE"

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
  . "$output"
}

# Load the real executable setup fence, including its production scalar JSON
# serializer and the production child-input APIs sourced from child-dispatch.
extract_fence '' 1 "$TMP/setup.sh"
bash -n "$TMP/setup.sh"
export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{}'
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev"
. "$TMP/setup.sh"

# Preserve the exact production callsite inputs at the dispatch seam without
# allocating or launching providers. Each instance gets an independent file so
# batching, retry identities, and dynamic loops remain observable.
uberdev_design_dispatch() {
  local edge="$1" instance="$2" role="$3" phase="$4" risk_scope="$5" risks_json="$6" inputs_json="$7"
  printf '%s' "$edge" >"$CAPTURE/$instance.edge"
  printf '%s' "$role" >"$CAPTURE/$instance.role"
  printf '%s' "$phase" >"$CAPTURE/$instance.phase"
  printf '%s' "$risk_scope" >"$CAPTURE/$instance.risk-scope"
  printf '%s' "$risks_json" >"$CAPTURE/$instance.risks.json"
  printf '%s' "$inputs_json" >"$CAPTURE/$instance.inputs.json"
}
uberdev_design_wait() { : "$1" "$2"; }

# Hostile but schema-valid values prove the serializer handles whitespace,
# quotes, backslashes, tabs, and JSON arrays without hand concatenation.
WORKING_DIR_ABS=$'/tmp/orchestrator hostile "dir" \\segment\t'
issue_body_path=$'/tmp/orchestrator hostile "issue" \\body\t.md'
research_codebase_summary_path=$'/tmp/codebase "summary" \\one\t.md'
research_patterns_summary_path=$'/tmp/patterns "summary" \\two\t.md'
research_prior_art_summary_path=$'/tmp/prior "summary" \\three\t.md'
research_constraints_summary_path=$'/tmp/constraints "summary" \\four\t.md'
research_security_summary_path=$'/tmp/security "summary" \\five\t.md'
research_test_summary_path=$'/tmp/tests "summary" \\six\t.md'
format_example_path=$'/tmp/research "format" \\example\t.md'
followup_summary_path=$'/tmp/followup "summary" \\path\t.md'
scope_shift_question=$'Which "quoted" scope uses \\ paths?\t'
scope_shift_answer=$'Use the \\new "scope".\t'
followup_format_example_path=$'/tmp/followup "format" \\example\t.md'
qa_answers_path=$'/tmp/questions "answers" \\path\t.md'
spec_summary_path=$'/tmp/spec "summary" \\path\t.md'
verification_feedback_path=$'/tmp/spec "feedback" \\path\t.md'
spec_path=$'/tmp/current "spec" \\path\t.md'
revision_brief_path=$'/tmp/spec "revision" \\brief\t.md'
spec_review_format_example_path=$'/tmp/spec-review "format" \\example\t.md'
spec_reviser_format_example_path=$'/tmp/spec-revise "format" \\example\t.md'
planning_dependency_summary_path=$'/tmp/dependency "summary" \\path\t.md'
planning_tests_summary_path=$'/tmp/test-map "summary" \\path\t.md'
planning_risks_summary_path=$'/tmp/risk "summary" \\path\t.md'
planning_security_summary_path=$'/tmp/plan-security "summary" \\path\t.md'
dependency_map_path=$'/tmp/dependency "map" \\path\t.md'
test_map_path=$'/tmp/test "map" \\path\t.md'
implementation_risk_path=$'/tmp/implementation "risk" \\path\t.md'
planning_security_output_path=$'/tmp/planning "security" \\path\t.md'
PLANNING_RESEARCH_OUTPUT_SHIM=$'/tmp/planning "shim" \\path\t.py'
plan_summary_path=$'/tmp/plan "summary" \\path\t.md'
plan_write_a1_feedback_path=$'/tmp/plan-a1 "feedback" \\path\t.md'
plan_write_a2_feedback_path=$'/tmp/plan-a2 "feedback" \\path\t.md'
plan_path=$'/tmp/current "plan" \\path\t.md'
plan_review_format_example_path=$'/tmp/plan-review "format" \\path\t.md'
plan_revision_a1_feedback_path=$'/tmp/revision-a1 "feedback" \\path\t.md'
plan_revision_a2_feedback_path=$'/tmp/revision-a2 "feedback" \\path\t.md'
tier='large'

research_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' \
  "$research_codebase_summary_path" "$research_patterns_summary_path")"
planning_paths_json="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' \
  "$dependency_map_path" "$test_map_path" "$implementation_risk_path")"
validated_risk_signals_json='["security","concurrency"]'

# Execute every base research/follow-up/spec/plan/review callsite fence.
for edge in codebase patterns prior_art constraints security test_coverage; do
  run_fence "edge=orchestrator.research.$edge"
done

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
run_fence 'edge=orchestrator.plan.write' 1
plan_write_verification_failed=1
run_fence 'edge=orchestrator.plan.write retry=verification'
run_fence 'edge=orchestrator.plan.review' 1
run_fence 'edge=orchestrator.plan.review retry=format'

plan_revision_verification_failed=1
plan_rereview_format_invalid=1
run_fence 'edge=orchestrator.plan.write' 2

export CAPTURE WORKING_DIR_ABS issue_body_path research_codebase_summary_path
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

capture=Path(os.environ['CAPTURE'])
env=os.environ

def payload(instance):
    path=capture/f'{instance}.inputs.json'
    if not path.is_file():
        raise SystemExit(f'missing captured production dispatch: {instance}')
    try: return json.loads(path.read_text())
    except Exception as error: raise SystemExit(f'invalid captured JSON for {instance}: {error}')

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
    if not (capture/f'{instance}.risks.json').is_file():
        raise SystemExit(f'missing risk capture: {instance}')
PY

# Mutation proof: the executable harness must reject a real callsite whose key
# is populated from the wrong production variable. The previous canned test
# silently accepted this exact mutation.
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
fi

printf 'orchestrator-child-inputs: PASS (actual setup/callsite fences, hostile payloads, mutation rejected)\n'
