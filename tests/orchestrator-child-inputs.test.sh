#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ORCHESTRATOR_SKILL_UNDER_TEST:-$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md}"
TMP="$(mktemp -d "$ROOT/tests/_fixtures/orchestrator-child-inputs.XXXXXX")"
RUN_DIR="$TMP/runtime"
HANDOFFS="$RUN_DIR/handoffs"
LIFECYCLE="$RUN_DIR/.agent-state-$(id -u)/agent-lifecycle.jsonl"
RECEIPTS="$TMP/receipts/child-dispatch.jsonl"
PROVIDER_CALLS="$TMP/provider-calls"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$RECEIPTS")"
chmod 700 "$(dirname "$RECEIPTS")"
: >"$RECEIPTS"
chmod 600 "$RECEIPTS"
: >"$PROVIDER_CALLS"
chmod 600 "$PROVIDER_CALLS"
derive_receipt_source() {
  [ "$#" -eq 1 ] || return 2
  python3 -I -B - "$1" "$ROOT" <<'PY'
import hashlib,os,sys
skill=os.path.realpath(sys.argv[1]); root=os.path.realpath(sys.argv[2])
canonical=os.path.realpath(os.path.join(root,'plugins/uberdev/skills/orchestrator/SKILL.md'))
if skill == canonical:
    source='plugins/uberdev/skills/orchestrator/SKILL.md'
else:
    digest=hashlib.sha256(skill.encode()).hexdigest()[:24]
    source=f'plugins/uberdev/test-fixtures/orchestrator-under-test-{digest}.md'
print(source,end='')
PY
}
export UBERDEV_CHILD_TEST_MODE=1
export UBERDEV_CHILD_TEST_SOURCE="$(derive_receipt_source "$SKILL")"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$RECEIPTS"
EXPECTED_RECEIPT_SOURCE="$(derive_receipt_source "$SKILL")"
[ "$UBERDEV_CHILD_TEST_SOURCE" = "$EXPECTED_RECEIPT_SOURCE" ] || {
  echo 'receipt source is not derived from ORCHESTRATOR_SKILL_UNDER_TEST' >&2
  exit 1
}
SOURCE_SPOOF_SKILL="$TMP/orchestrator-source-spoof.md"
cp "$SKILL" "$SOURCE_SPOOF_SKILL"
if [ "$(derive_receipt_source "$SOURCE_SPOOF_SKILL")" = "$UBERDEV_CHILD_TEST_SOURCE" ]; then
  echo 'mutation source spoof unexpectedly matched source under test' >&2
  exit 1
fi

[ -r "$SKILL" ]

extract_fence() {
  local header="$1" occurrence="$2" output="$3"
  python3 -I -B - "$SKILL" "$header" "$occurrence" "$output" <<'PY'
import re,sys
from pathlib import Path

source,header,occurrence_raw,output=sys.argv[1:]
text=Path(source).read_text()
fences=list(re.finditer(r'^```bash uberdev-executable([^\n]*)\n(.*?)\n```$',text,re.M|re.S))
actual_headers=[match.group(1).strip() for match in fences]
expected_headers=[
 '',
 'edge=orchestrator.research.codebase',
 'edge=orchestrator.research.patterns',
 'edge=orchestrator.research.prior_art',
 'edge=orchestrator.research.constraints',
 'edge=orchestrator.research.security',
 'edge=orchestrator.research.test_coverage',
 'barrier=orchestrator.research',
 'retry=format',
 'edge=orchestrator.research.followup',
 'edge=orchestrator.research.followup retry=format',
 'edge=orchestrator.spec.write',
 'edge=orchestrator.spec.write retry=verification',
 'edge=orchestrator.spec.review',
 'edge=orchestrator.spec.review retry=format',
 'edge=orchestrator.spec.revise',
 'edge=orchestrator.plan.research.dependency',
 'edge=orchestrator.plan.research.tests',
 'edge=orchestrator.plan.research.risks',
 'edge=orchestrator.plan.research.security',
 'barrier=orchestrator.plan.research',
 'edge=orchestrator.plan.write',
 'edge=orchestrator.plan.write retry=verification',
 'edge=orchestrator.plan.review',
 'edge=orchestrator.plan.review retry=format',
 'edge=orchestrator.plan.write',
]
if actual_headers != expected_headers:
    raise SystemExit(f'executable fence inventory mismatch: expected={expected_headers!r} actual={actual_headers!r}')
matches=[]
for match in fences:
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

DUPLICATE_SKILL="$TMP/orchestrator-duplicate-fence.md"
python3 -I -B - "$SKILL" "$DUPLICATE_SKILL" <<'PY'
import re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
match=re.search(r'^```bash uberdev-executable edge=orchestrator\.research\.codebase\n.*?\n```$',text,re.M|re.S)
if match is None: raise SystemExit('duplicate fence mutation target missing')
Path(sys.argv[2]).write_text(text+'\n'+match.group(0)+'\n')
PY
if (
  SKILL="$DUPLICATE_SKILL"
  extract_fence 'edge=orchestrator.research.codebase' 1 "$TMP/duplicate-fence-probe.sh" \
    >/dev/null 2>&1
); then
  echo 'duplicate executable fence/callsite mutation unexpectedly passed' >&2
  exit 1
fi

# Load the real executable setup fence, including its production scalar JSON
# serializer and the production child-input APIs sourced from child-dispatch.
extract_fence '' 1 "$TMP/setup.sh"
bash -n "$TMP/setup.sh"
export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{}'
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev"
. "$TMP/setup.sh"
REAL_AGENT_DISPATCH_SHA="$(declare -f uberdev_agent_dispatch | shasum -a 256 | awk '{print $1}')"
assert_real_agent_dispatch() {
  local current
  current="$(declare -f uberdev_agent_dispatch | shasum -a 256 | awk '{print $1}')"
  [ "$current" = "$REAL_AGENT_DISPATCH_SHA" ] || {
    echo 'real uberdev_agent_dispatch wrapper was replaced' >&2
    return 1
  }
}

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

# Keep the complete production design, child-dispatch, route-resolution,
# lifecycle, and lease stack. Only the detached backend provider is replaced.
_uberdev_agent_dispatch_backend() {
  local backend="$1" issue="$2" tier_arg="$3" prompt="$4" result="$5" status="$6" decision="$7"
  local instance edge
  [ "$#" -eq 7 ] || return 2
  instance="${result%/result.md}"
  instance="${instance##*/}"
  edge="$(python3 -I -B -c 'import json,sys;print(json.load(open(sys.argv[1]))["edge_id"],end="")' "$HANDOFFS/$instance.json")" || return 2
  python3 -I -B - \
    "$RECEIPTS" "$UBERDEV_CHILD_TEST_SOURCE" "$HANDOFFS/$instance.json" \
    "$LIFECYCLE" "$RUN_DIR/.agent-state-$(id -u)" "$PROVIDER_CALLS" \
    "$backend" "$issue" "$tier_arg" "$prompt" "$result" "$status" "$decision" <<'PY'
import hashlib,json,pathlib,re,sys
(
 receipt_path,source,handoff_path,lifecycle_path,state_dir,provider_path,
 backend,issue,tier,prompt_path,result_path,status_path,decision_raw,
)=sys.argv[1:]
handoff=json.loads(pathlib.Path(handoff_path).read_text())
instance=handoff['instance_id']; edge=handoff['edge_id']
if (backend,issue,tier)!=('codex','42','large'):
    raise SystemExit(f'backend arguments mismatch: {(backend,issue,tier)!r}')
child=pathlib.Path(result_path).parent
if pathlib.Path(prompt_path)!=child/'prompt.txt' or pathlib.Path(status_path)!=child/'status.json' or child.name!=instance:
    raise SystemExit(f'backend path arguments mismatch: {instance}')

receipt_rows=[json.loads(line) for line in pathlib.Path(receipt_path).read_text().splitlines()]
if not receipt_rows:
    raise SystemExit('backend reached before any dispatch receipt')
last=receipt_rows[-1]
if (last.get('event'),last.get('source'),last.get('edge_id'),last.get('instance_id')) != ('dispatch',source,edge,instance):
    raise SystemExit(f'backend reached before correlated dispatch receipt: {last!r}')

decision=json.loads(decision_raw)
if (
 decision.get('schema_version')!=1 or decision.get('backend')!='codex' or
 decision.get('risk_scope')!=handoff.get('risk_scope') or
 decision.get('risk_signals')!=handoff.get('risk_signals') or
 decision.get('forced') is not False or
 not isinstance(decision.get('model'),str) or not decision.get('model') or
 not isinstance(decision.get('reasoning_effort'),str) or not decision.get('reasoning_effort') or
 decision.get('routing_mode') not in {'adaptive','forced','inherit','shadow'} or
 decision.get('effective_policy') not in {'adaptive','forced','inherit'}
):
    raise SystemExit(f'backend decision mismatch: {instance}')

lifecycle=[json.loads(line) for line in pathlib.Path(lifecycle_path).read_text().splitlines()]
prefix=[row for row in lifecycle if row.get('run_id')==instance]
if [row.get('event') for row in prefix] != ['route_decided','agent_started']:
    raise SystemExit(f'real lifecycle prefix missing at backend: {instance}')
if prefix[1].get('status_path')!=status_path:
    raise SystemExit(f'real lifecycle status path mismatch at backend: {instance}')

leases=[]
for path in (pathlib.Path(state_dir)/'semaphore-v1').rglob('*.lease'):
    try: fields=dict(line.split('=',1) for line in path.read_text().splitlines())
    except Exception: continue
    if fields.get('run_id')==instance and fields.get('status_path')==status_path:
        leases.append((path,fields))
if len(leases)!=1 or not re.fullmatch(r'[A-Za-z0-9._:-]+',leases[0][1].get('generation','')):
    raise SystemExit(f'exact active lease missing at backend: {instance}')

capture={
 'edge_id':edge,'instance_id':instance,'backend':backend,'issue_num':int(issue),'tier':tier,
 'decision_sha256':hashlib.sha256(json.dumps(decision,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
 'lease_generation':leases[0][1]['generation'],
}
with pathlib.Path(provider_path).open('a') as stream:
    stream.write(json.dumps(capture,sort_keys=True,separators=(',',':'))+'\n')
PY
  DISPATCH_ID="fixture-$instance"
  DISPATCH_RC=0
  DISPATCH_LOG=''
  printf 'fixture result for %s\n' "$instance" >"$result"
  chmod 600 "$result" || return 2
  printf '{"backend":"codex","state":"completed","exit_code":0,"pid":"%s"}\n' "$DISPATCH_ID" >"$status"
  chmod 600 "$status" || return 2
  return 0
}

assert_real_agent_dispatch
if (
  uberdev_agent_dispatch() { :; }
  assert_real_agent_dispatch >/dev/null 2>&1
); then
  echo 'broken wrapper mutation unexpectedly passed' >&2
  exit 1
fi

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
  if [ "$edge" = patterns ]; then
    PRE_PATTERNS_INPUTS="$(uberdev_child_inputs_build orchestrator.research.patterns \
      issue_path "$(uberdev_design_json_string "${issue_body_path%/*}/./${issue_body_path##*/}")" \
      working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS/.")" \
      summary_path "$(uberdev_design_json_string "${research_patterns_summary_path%/*}/./${research_patterns_summary_path##*/}")")"
    CANONICAL_PATTERNS_INPUTS="$(python3 -I -B - "$PRE_PATTERNS_INPUTS" <<'PY'
import json,os,sys
value=json.loads(sys.argv[1])
for key in ('issue_path','working_dir','summary_path'):
    value[key]=os.path.realpath(value[key])
print(json.dumps(value,sort_keys=True,separators=(',',':')),end='')
PY
)"
    [ "$PRE_PATTERNS_INPUTS" != "$CANONICAL_PATTERNS_INPUTS" ] || {
      echo 'validated snapshot fixture did not transform build A into build B' >&2
      exit 1
    }
    VALIDATED_PATTERNS_INPUTS="$(uberdev_child_inputs_validate orchestrator.research.patterns "$CANONICAL_PATTERNS_INPUTS")"
    [ "$VALIDATED_PATTERNS_INPUTS" = "$CANONICAL_PATTERNS_INPUTS" ] || {
      echo 'production child-input validation changed canonical build B' >&2
      exit 1
    }
  fi
  run_fence "edge=orchestrator.research.$edge"
  if [ "$edge" = patterns ]; then
    [ "$GENERAL_PATTERNS_INPUTS" = "$VALIDATED_PATTERNS_INPUTS" ] || {
      echo 'validated build B does not match production patterns handoff inputs' >&2
      exit 1
    }
  fi
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

validate_runtime() {
  [ "$#" -eq 5 ] || return 2
  python3 -I -B - "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib,json,os,re,sys
from pathlib import Path

receipt_path,lifecycle_path,handoff_dir,provider_path,source=sys.argv[1:]
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

handoff_values={}
expected_chain={}
expected_edge_instances={}
for instance,edge in expected_instances.items():
    value=json.loads(actual_files[instance].read_text())
    if value.get('instance_id') != instance or value.get('edge_id') != edge:
        raise SystemExit(f'handoff identity/edge mismatch: {instance}')
    inputs=value.get('inputs')
    if not isinstance(inputs,dict):
        raise SystemExit(f'handoff inputs missing: {instance}')
    canonical=json.dumps(inputs,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
    digest=hashlib.sha256(canonical).hexdigest()
    key=(edge,digest)
    handoff_values[instance]=value
    expected_chain[instance]=key
    expected_edge_instances.setdefault(edge,set()).add(instance)

raw=Path(receipt_path).read_text()
rows=[json.loads(line) for line in raw.splitlines()]
grouped={}
dispatch_order=[]
for index,row in enumerate(rows):
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
    key=(edge,digest)
    if event == 'build':
        instance=None
    elif event in {'handoff','dispatch'}:
        instance=row.get('instance_id')
        if expected_chain.get(instance) != key:
            raise SystemExit(f'unknown receipt chain: {row!r}')
        if event == 'dispatch':
            dispatch_order.append((edge,instance))
    else:
        raise SystemExit(f'unknown receipt event: {row!r}')
    grouped.setdefault(edge,[]).append((event,instance,digest,index))

for edge,expected_group_instances in expected_edge_instances.items():
    pending_builds=[]
    open_chain=None
    seen=set()
    for event,instance,digest,index in grouped.get(edge,[]):
        if event == 'build':
            if open_chain is not None:
                raise SystemExit(f'receipt event order mismatch: build interrupted instance={open_chain[0]} index={index}')
            pending_builds.append(digest)
        elif event == 'handoff':
            if open_chain is not None:
                raise SystemExit(f'receipt event order mismatch: duplicate handoff instance={instance} index={index}')
            if not pending_builds:
                raise SystemExit(f'receipt missing prior build: instance={instance} index={index}')
            if pending_builds[-1] != digest:
                raise SystemExit(f'receipt final build mismatch: instance={instance} index={index}')
            if instance not in expected_group_instances or instance in seen:
                raise SystemExit(f'unknown or duplicate receipt handoff: instance={instance} index={index}')
            open_chain=(instance,digest)
        else:
            if open_chain != (instance,digest):
                raise SystemExit(f'receipt event order mismatch: dispatch instance={instance} open={open_chain} index={index}')
            seen.add(instance)
            open_chain=None
            pending_builds=[]
    if open_chain is not None or pending_builds:
        raise SystemExit(f'incomplete ordered receipt group: edge={edge}')
    if seen != expected_group_instances:
        raise SystemExit(f'incomplete receipt identities: expected={sorted(expected_group_instances)!r} actual={sorted(seen)!r}')

lifecycle_rows=[json.loads(line) for line in Path(lifecycle_path).read_text().splitlines()]
lifecycle_by_instance={instance:[] for instance in expected_instances}
for row in lifecycle_rows:
    instance=row.get('run_id')
    if instance not in lifecycle_by_instance:
        raise SystemExit(f'unknown lifecycle instance: {row!r}')
    lifecycle_by_instance[instance].append(row)

for instance,edge in expected_instances.items():
    events=lifecycle_by_instance[instance]
    if [row.get('event') for row in events] != ['route_decided','agent_started','completed']:
        raise SystemExit(f'lifecycle event sequence mismatch: instance={instance} events={[row.get("event") for row in events]!r}')
    handoff=handoff_values[instance]
    for row in events:
        correlated=(
          row.get('run_id')==instance and row.get('agent_id')==instance and
          row.get('parent_run_id')=='orchestrator-receipt-root' and
          row.get('backend')=='codex' and row.get('workflow')=='solve' and
          row.get('phase')==handoff.get('phase') and row.get('role')==handoff.get('role') and
          row.get('task_tier')=='large' and row.get('risk_signals')==handoff.get('risk_signals')
        )
        if not correlated:
            raise SystemExit(f'lifecycle correlation mismatch: instance={instance} event={row.get("event")}')
    expected_status=handoff_root.parent/'children'/instance/'status.json'
    if events[1].get('status_path') != str(expected_status):
        raise SystemExit(f'lifecycle status-path mismatch: instance={instance}')
    if 'terminal_status' in events[0] or 'terminal_status' in events[1] or events[2].get('terminal_status')!='completed':
        raise SystemExit(f'lifecycle terminal mismatch: instance={instance}')
    status=json.loads(expected_status.read_text())
    if status.get('state')!='completed' or status.get('exit_code')!=0:
        raise SystemExit(f'child status not completed: instance={instance}')

state_root=handoff_root.parent/f'.agent-state-{os.geteuid()}'
residual_leases=list((state_root/'semaphore-v1').rglob('*.lease'))
if residual_leases:
    raise SystemExit(f'residual child leases after waits: {[str(path) for path in residual_leases]!r}')

provider_rows=[json.loads(line) for line in Path(provider_path).read_text().splitlines()]
provider=[]
for row in provider_rows:
    if set(row)!={'edge_id','instance_id','backend','issue_num','tier','decision_sha256','lease_generation'}:
        raise SystemExit(f'provider capture shape mismatch: {row!r}')
    if (
      row.get('backend')!='codex' or row.get('issue_num')!=42 or row.get('tier')!='large' or
      not re.fullmatch(r'[0-9a-f]{64}',row.get('decision_sha256','')) or
      not re.fullmatch(r'[A-Za-z0-9._:-]+',row.get('lease_generation',''))
    ):
        raise SystemExit(f'provider capture values mismatch: {row!r}')
    provider.append((row['edge_id'],row['instance_id']))
if provider != dispatch_order:
    raise SystemExit(f'provider seam mismatch: expected={dispatch_order!r} actual={provider!r}')
PY
}

validate_runtime "$RECEIPTS" "$LIFECYCLE" "$HANDOFFS" "$PROVIDER_CALLS" "$UBERDEV_CHILD_TEST_SOURCE"

MUTATION_DIR="$TMP/runtime-mutations"
mkdir -p "$MUTATION_DIR"
chmod 700 "$MUTATION_DIR"
RECEIPT_REORDERED="$MUTATION_DIR/receipt-reordered.jsonl"
RECEIPT_BUILD_LATE="$MUTATION_DIR/receipt-build-late.jsonl"
RECEIPT_BUILD_AFTER_HANDOFF="$MUTATION_DIR/receipt-build-after-handoff.jsonl"
RECEIPT_FINAL_MISMATCH="$MUTATION_DIR/receipt-final-mismatch.jsonl"
RECEIPT_MISCORRELATED="$MUTATION_DIR/receipt-miscorrelated.jsonl"
LIFECYCLE_OMITTED="$MUTATION_DIR/lifecycle-omitted.jsonl"
LIFECYCLE_MISCORRELATED="$MUTATION_DIR/lifecycle-miscorrelated.jsonl"
python3 -I -B - "$RECEIPTS" "$LIFECYCLE" \
  "$RECEIPT_REORDERED" "$RECEIPT_BUILD_LATE" \
  "$RECEIPT_BUILD_AFTER_HANDOFF" "$RECEIPT_FINAL_MISMATCH" "$RECEIPT_MISCORRELATED" \
  "$LIFECYCLE_OMITTED" "$LIFECYCLE_MISCORRELATED" <<'PY'
import hashlib,json,os,sys
from pathlib import Path

(
 receipt_path,lifecycle_path,reordered_path,late_path,
 after_handoff_path,final_mismatch_path,receipt_miscorrelated_path,
 omitted_path,lifecycle_miscorrelated_path,
)=sys.argv[1:]

def write(path,rows):
    Path(path).write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
    os.chmod(path,0o600)

receipts=[json.loads(line) for line in Path(receipt_path).read_text().splitlines()]
reordered=[dict(row) for row in receipts]
target='orchestrator-research-followup-a1'
handoff_index=next(i for i,row in enumerate(reordered) if row.get('event')=='handoff' and row.get('instance_id')==target)
dispatch_index=next(i for i,row in enumerate(reordered) if row.get('event')=='dispatch' and row.get('instance_id')==target)
reordered[handoff_index],reordered[dispatch_index]=reordered[dispatch_index],reordered[handoff_index]
write(reordered_path,reordered)

late=[dict(row) for row in receipts]
target='orchestrator-research-patterns-a1'
handoff=next(row for row in late if row.get('event')=='handoff' and row.get('instance_id')==target)
build_indexes=[i for i,row in enumerate(late) if row.get('event')=='build' and row.get('edge_id')==handoff['edge_id']]
if not build_indexes: raise SystemExit('receipt build-late mutation target missing')
build_rows=[late[i] for i in build_indexes]
late=[row for i,row in enumerate(late) if i not in set(build_indexes)]
dispatch_index=next(i for i,row in enumerate(late) if row.get('event')=='dispatch' and row.get('instance_id')==target)
late[dispatch_index+1:dispatch_index+1]=build_rows
write(late_path,late)

after_handoff=[dict(row) for row in receipts]
target='orchestrator-research-followup-a1'
handoff_index=next(i for i,row in enumerate(after_handoff) if row.get('event')=='handoff' and row.get('instance_id')==target)
handoff=after_handoff[handoff_index]
final_build_index=max(i for i,row in enumerate(after_handoff[:handoff_index]) if row.get('event')=='build' and row.get('edge_id')==handoff['edge_id'])
after_handoff.insert(handoff_index+1,dict(after_handoff[final_build_index]))
write(after_handoff_path,after_handoff)

final_mismatch=[dict(row) for row in receipts]
target='orchestrator-research-prior-art-a1'
handoff_index=next(i for i,row in enumerate(final_mismatch) if row.get('event')=='handoff' and row.get('instance_id')==target)
handoff=final_mismatch[handoff_index]
final_build_index=max(i for i,row in enumerate(final_mismatch[:handoff_index]) if row.get('event')=='build' and row.get('edge_id')==handoff['edge_id'])
final_mismatch[final_build_index]['inputs_sha256']=hashlib.sha256(b'missing-matching-final-build').hexdigest()
if final_mismatch[final_build_index]['inputs_sha256']==handoff['inputs_sha256']: raise SystemExit('final mismatch digest collision')
write(final_mismatch_path,final_mismatch)

receipt_miscorrelated=[dict(row) for row in receipts]
target='orchestrator-research-constraints-a1'
row=next(row for row in receipt_miscorrelated if row.get('event')=='dispatch' and row.get('instance_id')==target)
row['instance_id']='orchestrator-research-patterns-a1'
write(receipt_miscorrelated_path,receipt_miscorrelated)

lifecycle=[json.loads(line) for line in Path(lifecycle_path).read_text().splitlines()]
target='orchestrator-spec-write-a1'
omitted=[row for row in lifecycle if not (row.get('run_id')==target and row.get('event')=='agent_started')]
if len(omitted)!=len(lifecycle)-1: raise SystemExit('lifecycle omission mutation target missing')
write(omitted_path,omitted)

target='orchestrator-plan-write-a1'; wrong='orchestrator-plan-write-a2'
lifecycle_miscorrelated=[dict(row) for row in lifecycle]
row=next(row for row in lifecycle_miscorrelated if row.get('run_id')==target and row.get('event')=='completed')
row['run_id']=wrong
write(lifecycle_miscorrelated_path,lifecycle_miscorrelated)
PY

assert_runtime_rejected() {
  local name="$1" expected="$2" receipts="$3" lifecycle="$4"
  if validate_runtime "$receipts" "$lifecycle" "$HANDOFFS" "$PROVIDER_CALLS" "$UBERDEV_CHILD_TEST_SOURCE" \
      >"$MUTATION_DIR/$name.out" 2>"$MUTATION_DIR/$name.err"; then
    echo "runtime mutation unexpectedly passed: $name" >&2
    return 1
  fi
  grep -Fq "$expected" "$MUTATION_DIR/$name.err" || {
    echo "runtime mutation failed for the wrong reason: $name" >&2
    return 1
  }
}

assert_runtime_rejected receipt-reordered 'receipt event order mismatch' "$RECEIPT_REORDERED" "$LIFECYCLE"
assert_runtime_rejected receipt-build-late 'receipt missing prior build' "$RECEIPT_BUILD_LATE" "$LIFECYCLE"
assert_runtime_rejected receipt-build-after-handoff 'receipt event order mismatch' "$RECEIPT_BUILD_AFTER_HANDOFF" "$LIFECYCLE"
assert_runtime_rejected receipt-final-mismatch 'receipt final build mismatch' "$RECEIPT_FINAL_MISMATCH" "$LIFECYCLE"
assert_runtime_rejected receipt-miscorrelated 'unknown receipt chain' "$RECEIPT_MISCORRELATED" "$LIFECYCLE"
assert_runtime_rejected lifecycle-omitted 'lifecycle event sequence mismatch' "$RECEIPTS" "$LIFECYCLE_OMITTED"
assert_runtime_rejected lifecycle-miscorrelated 'lifecycle event sequence mismatch' "$RECEIPTS" "$LIFECYCLE_MISCORRELATED"

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
