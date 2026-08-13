#!/usr/bin/env bash
# Asserts that the per-task spec-reviewer dispatched by subagent-driven-dev
# is plan-aware:
#   1. spec-reviewer-prompt.md exposes a `Plan Task Description` placeholder
#      so the controller can plumb the plan entry into the reviewer's context.
#   2. spec-reviewer-prompt.md instructs the reviewer to flag `plan drift`
#      (structural deviation from the plan even when the spec is satisfied).
#   3. SKILL.md (step 4f) tells the controller to pass `plan_task_description`
#      alongside the existing dispatch parameters.
#
# Without these three pieces the per-task spec review only catches
# spec-vs-code drift and silently misses plan-vs-code drift (skipped steps,
# swapped libraries, merged tasks, reordered dependencies).
#
# Style mirrors tests/turbo-flow.test.sh and tests/post-impl-review.test.sh:
# grep-based structural assertions against the rendered prompt/skill files,
# no live agent invocation.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_REVIEWER_PROMPT="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/spec-reviewer-prompt.md"
SUBAGENT_DRIVEN="$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
RUN_TREE="$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"

# Pre-flight: refuse to run if the files we're asserting against are missing
# or unreadable — without this every assertion fails with a confusing
# "pattern not found" instead of the real cause.
for f in "$SPEC_REVIEWER_PROMPT" "$SUBAGENT_DRIVEN" "$RUN_TREE"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        file:    $file"
    echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "== spec-reviewer prompt exposes Plan Task Description placeholder =="
assert_grep "$SPEC_REVIEWER_PROMPT" \
  'Plan Task Description' \
  "spec-reviewer-prompt.md has a Plan Task Description section header"

echo
echo "== spec-reviewer prompt names plan drift in the DO list =="
assert_grep "$SPEC_REVIEWER_PROMPT" \
  'plan drift' \
  "spec-reviewer-prompt.md instructs reviewer to flag plan drift"

echo
echo "== SKILL.md plumbs canonical plan_path into the dispatch =="
assert_grep "$SUBAGENT_DRIVEN" \
  '`plan_path`: absolute implementation plan' \
  "subagent-driven-dev SKILL.md names plan_path as a spec-reviewer dispatch parameter"

echo
echo "== SDD runtime handoff, confinement, unwind, and lineage contracts =="
assert_grep "$SUBAGENT_DRIVEN" \
  'uberdev_create_child_handoff "\$edge_id" "\$instance_id" "\$inputs_json" "\$risk_json"' \
  "SDD delegates all handoff allocation and validation to the runtime helper"
assert_grep "$SUBAGENT_DRIVEN" \
  'if uberdev_create_child_handoff "\$edge_id" "\$instance_id" "\$inputs_json" "\$risk_json"; then' \
  "SDD unwinds earlier receipts when later handoff creation fails"
assert_grep "$SUBAGENT_DRIVEN" \
  'sdd_validate_instance_dimensions' \
  "SDD validates wave/task/stage/attempt dimensions before handoff creation"
assert_grep "$SUBAGENT_DRIVEN" \
  'sdd_canonicalize_owned_paths' \
  "SDD canonicalizes allow/deny paths under the worktree before handoff creation"
assert_grep "$SUBAGENT_DRIVEN" \
  'allowed=canon\("allowed_paths"\); denied=canon\("denied_paths"\)' \
  "SDD uses canonical manifest ownership keys"
assert_grep "$SUBAGENT_DRIVEN" \
  'uberdev_preflight_child_batch' \
  "SDD preflights the complete prepared batch before first dispatch"
assert_grep "$SUBAGENT_DRIVEN" \
  'SDD_RECEIPT_INSTANCES' \
  "SDD records successful dispatch receipt fields without delimiters"
assert_grep "$SUBAGENT_DRIVEN" \
  'sdd_unwind_child_receipts' \
  "SDD unwinds all earlier receipts after a partial fanout failure"
# `child_status`, NOT `status`: the pinned property is the bounded timeout
# argument, but under /bin/zsh (how the harness runs a command/skill `bash`
# fence on macOS) `status` is the read-only alias for `$?`, so a local of that
# name kills the fence at its first assignment. Only the renamed spelling is
# accepted, so a green test cannot readmit the fatal one.
assert_grep "$SUBAGENT_DRIVEN" \
  'uberdev_unwind_child "\$child_status" "\$result" "\$SDD_CHILD_TIMEOUT"' \
  "SDD unwind is bounded by the configured positive timeout"
# #458 structural locks. These are the WEAKEST evidence for the plan-scope fix
# and are never its primary oracle — the behavioural oracle is the two-plan
# disjointness block in tests/sdd-child-inputs.test.sh, which executes the real
# handoff allocator. These three rows exist only to catch a future edit that
# deletes the helpers from the file those tests execute.
assert_grep "$SUBAGENT_DRIVEN" \
  'sdd_plan_scope' \
  "SDD mints a per-plan allocation scope (#458)"
assert_grep "$SUBAGENT_DRIVEN" \
  'sdd_validate_plan_scope' \
  "SDD validates the plan scope as a mandatory instance dimension (#458)"
assert_grep "$SUBAGENT_DRIVEN" \
  'uberdev_child_instance_id "sdd-p\$\{plan_scope\}' \
  "SDD bounds the composed instance ID through the shared helper, not by hand (#458)"
if grep -qF 'model_invocation: false' <<<"$(grep -A1 -F 'edge_id: sdd.finish_branch' "$SUBAGENT_DRIVEN")"; then
  echo "  PASS  SDD finish-branch transition has stable non-model lineage"
  PASS=$((PASS + 1))
else
  echo "  FAIL  SDD finish-branch transition lacks stable non-model lineage"
  FAIL=$((FAIL + 1))
fi

if python3 - "$SUBAGENT_DRIVEN" "$RUN_TREE" <<'PY'
import json,re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding="utf-8")
manifest=json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
match=re.search(r'<!-- BEGIN child-callsite-contracts-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END child-callsite-contracts-v1 -->',text,re.S)
if not match: raise SystemExit("missing SDD callsite fixtures")
for edge,row in json.loads(match.group(1)).items():
    declared=manifest["edges"][edge]
    if row["inputs"] != list(declared["required_inputs"]) or row["risk_scope"] != declared["risk_scope"]:
        raise SystemExit(f"{edge}: manifest divergence")
    if row["risk_argument"] != "subtask": raise SystemExit(f"{edge}: risk argument")
# #458: the declared instance-ID vocabulary must name the plan scope, so the
# manifest stops describing a grammar SDD no longer composes. Nothing reads
# instance_dimensions today; this keeps the declaration truthful, it does not
# enforce the fix.
if "plan_scope" not in manifest["instance_dimensions"]:
    raise SystemExit("manifest instance_dimensions omits plan_scope")
PY
then
  echo "  PASS  SDD callsite fixtures exactly match the production manifest"
  PASS=$((PASS + 1))
else
  echo "  FAIL  SDD callsite fixtures diverge from the production manifest"
  FAIL=$((FAIL + 1))
fi

if grep -qE 'sdd_write_handoff|os\.open\(destination|handoff_file="\$SDD_RUN_DIR' "$SUBAGENT_DRIVEN"; then
  echo "  FAIL  SDD retains a caller-owned raw handoff writer"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  SDD has no caller-owned raw handoff writer"
  PASS=$((PASS + 1))
fi

if python3 - "$SUBAGENT_DRIVEN" "$BASH" <<'PY'
import re
import subprocess
import sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding="utf-8")
match=re.search(r"sdd_unwind_child_receipts\(\) \{.*?\n\}",text,re.S)
if not match: raise SystemExit("unwind function missing")
script=f'''set -u
calls=()
uberdev_unwind_child() {{ calls+=("$1|$2|$3"); [ "${{#calls[@]}}" -ne 1 ]; }}
SDD_CHILD_TIMEOUT=600
SDD_RECEIPT_INSTANCES=("one" "two")
SDD_RECEIPT_STATUSES=("/tmp/status|1" "/tmp/status|2")
SDD_RECEIPT_RESULTS=("/tmp/result|1" "/tmp/result|2")
sdd_reset_batch() {{ SDD_RECEIPT_INSTANCES=(); SDD_RECEIPT_STATUSES=(); SDD_RECEIPT_RESULTS=(); }}
{match.group(0)}
rc=0
sdd_unwind_child_receipts || rc=$?
[ "$rc" -eq 1 ]
[ "${{#calls[@]}}" -eq 2 ]
[ "${{calls[0]}}" = "/tmp/status|1|/tmp/result|1|600" ]
[ "${{calls[1]}}" = "/tmp/status|2|/tmp/result|2|600" ]
[ "${{#SDD_RECEIPT_INSTANCES[@]}}" -eq 0 ]
'''
result=subprocess.run([sys.argv[2],"-c",script],text=True,capture_output=True)
if result.returncode: raise SystemExit(result.stderr)
PY
then
  echo "  PASS  SDD partial-fanout unwind drains every receipt after an earlier wait error"
  PASS=$((PASS + 1))
else
  echo "  FAIL  SDD partial-fanout unwind abandoned a recorded child"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]
