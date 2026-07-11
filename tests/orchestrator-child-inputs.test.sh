#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"

[ -r "$SKILL" ]
[ -r "$LIB" ]

python3 -I -B - "$SKILL" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()

edges = (
    "orchestrator.research.codebase",
    "orchestrator.research.patterns",
    "orchestrator.research.prior_art",
    "orchestrator.research.constraints",
    "orchestrator.research.security",
    "orchestrator.research.test_coverage",
    "orchestrator.research.followup",
    "orchestrator.spec.write",
    "orchestrator.spec.review",
    "orchestrator.spec.revise",
    "orchestrator.plan.research.dependency",
    "orchestrator.plan.research.tests",
    "orchestrator.plan.research.risks",
    "orchestrator.plan.research.security",
    "orchestrator.plan.write",
    "orchestrator.plan.review",
)

for edge in edges:
    pattern = rf"uberdev_child_inputs_build\s+{re.escape(edge)}(?:\s|\\)"
    if not re.search(pattern, source):
        raise SystemExit(f"RED: orchestrator edge does not use production input builder: {edge}")

required_dynamic = (
    'uberdev_child_inputs_format_retry "$failed_edge" "$failed_inputs_json" "$format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.research.followup "$FOLLOWUP_INPUTS" "$followup_format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.spec.review "$SPEC_REVIEW_INPUTS" "$spec_review_format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.spec.revise "$SPEC_REVISE_INPUTS" "$spec_reviser_format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.spec.review "$SPEC_REREVIEW_INPUTS" "$spec_review_format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.plan.review "$PLAN_REVIEW_INPUTS" "$plan_review_format_example_path"',
    'uberdev_child_inputs_format_retry orchestrator.plan.review "$PLAN_REREVIEW_INPUTS" "$plan_review_format_example_path"',
)
for call in required_dynamic:
    if call not in source:
        raise SystemExit(f"RED: orchestrator dynamic retry bypasses production helper: {call}")

if "json.dumps({" in source:
    raise SystemExit("RED: orchestrator still constructs routed input objects inline")
if re.search(r'v\["(?:format_retry|format_example_path|verification_feedback_path|revision_brief_path|spec_path|plan_path)"\]\s*=', source):
    raise SystemExit("RED: orchestrator still mutates routed input objects inline")

# The bounded dynamic loops must rebuild their current spec/plan paths through
# the manifest-aware API rather than cloning an earlier payload.
loop_expectations = (
    ('for revision_cycle in 1 2; do', 'uberdev_child_inputs_build orchestrator.spec.review'),
    ('PLAN_REVISION_INPUTS="$(uberdev_child_inputs_build orchestrator.plan.write', 'PLAN_REREVIEW_INPUTS="$(uberdev_child_inputs_build orchestrator.plan.review'),
)
for left, right in loop_expectations:
    left_at = source.find(left)
    if left_at < 0 or source.find(right, left_at) < 0:
        raise SystemExit(f"RED: dynamic orchestrator loop is not builder-backed: {left}")
PY

# Exercise every exact production builder edge with safely serialized scalar
# literals and existing JSON arrays. This catches manifest drift independently
# of the source reachability assertions above.
. "$LIB"
json_string() {
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "$1"
}

P='"/tmp/input"'
D='"/tmp/work"'
S='"value"'
A='["/tmp/input"]'
R='["security"]'

uberdev_child_inputs_build orchestrator.research.codebase issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
uberdev_child_inputs_build orchestrator.research.patterns issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
uberdev_child_inputs_build orchestrator.research.prior_art issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
uberdev_child_inputs_build orchestrator.research.constraints issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
uberdev_child_inputs_build orchestrator.research.security issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
uberdev_child_inputs_build orchestrator.research.test_coverage issue_path "$P" working_dir "$D" summary_path "$P" >/dev/null
FOLLOWUP="$(uberdev_child_inputs_build orchestrator.research.followup working_dir "$D" summary_path "$P" question "$S" answer "$S")"
uberdev_child_inputs_format_retry orchestrator.research.followup "$FOLLOWUP" /tmp/example >/dev/null
uberdev_child_inputs_build orchestrator.spec.write issue_path "$P" research_paths "$A" questions_path "$P" working_dir "$D" summary_path "$P" >/dev/null
SPEC_REVIEW="$(uberdev_child_inputs_build orchestrator.spec.review spec_path "$P" issue_path "$P" research_paths "$A" working_dir "$D")"
uberdev_child_inputs_format_retry orchestrator.spec.review "$SPEC_REVIEW" /tmp/example >/dev/null
SPEC_REVISE="$(uberdev_child_inputs_build orchestrator.spec.revise spec_path "$P" revision_path "$P" working_dir "$D")"
uberdev_child_inputs_format_retry orchestrator.spec.revise "$SPEC_REVISE" /tmp/example >/dev/null
for edge in dependency tests risks; do
  uberdev_child_inputs_build "orchestrator.plan.research.$edge" spec_path "$P" working_dir "$D" summary_path "$P" output_path "$P" validation_path "$P" >/dev/null
done
uberdev_child_inputs_build orchestrator.plan.research.security spec_path "$P" working_dir "$D" summary_path "$P" output_path "$P" validation_path "$P" risk_signals "$R" >/dev/null
uberdev_child_inputs_build orchestrator.plan.write spec_path "$P" tier '"medium"' working_dir "$D" summary_path "$P" planning_paths "$A" validation_path "$P" >/dev/null
PLAN_REVIEW="$(uberdev_child_inputs_build orchestrator.plan.review plan_path "$P" spec_path "$P" tier '"medium"' working_dir "$D")"
uberdev_child_inputs_format_retry orchestrator.plan.review "$PLAN_REVIEW" /tmp/example >/dev/null

encoded="$(json_string $'quote" slash\\ tab\t')"
python3 -I -B - "$encoded" <<'PY'
import json,sys
assert json.loads(sys.argv[1]) == 'quote" slash\\ tab\t'
PY
printf 'orchestrator-child-inputs: PASS (16 builder edges, dynamic retries, safe scalar JSON)\n'
