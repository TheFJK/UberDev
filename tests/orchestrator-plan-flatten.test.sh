#!/usr/bin/env bash
# Structural regression for RFC 0013 section 10.1 / T40-3.
#
# Planning research belongs to the root orchestrator. plan-writer is a leaf
# that receives three validated artifact paths and only synthesizes the plan.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORCHESTRATOR="$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
PLAN_WRITER="$ROOT/plugins/uberdev/agents/plan-writer.md"
RUN_TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
BRAINSTORM="$ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
WRITE_PLAN="$ROOT/plugins/uberdev/skills/write-plan/SKILL.md"
RESEARCH_CODEBASE="$ROOT/plugins/uberdev/agents/research-codebase.md"
RESEARCH_TEST_COVERAGE="$ROOT/plugins/uberdev/agents/research-test-coverage.md"
RESEARCH_CONSTRAINTS="$ROOT/plugins/uberdev/agents/research-constraints.md"
RESEARCH_SECURITY="$ROOT/plugins/uberdev/agents/research-security.md"
PLANNING_OUTPUT_SHIM="$ROOT/plugins/uberdev/lib/planning_research_output.py"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_ge() {
  local name="$1" minimum="$2" actual="$3"
  if (( actual >= minimum )); then
    printf '  PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (expected>=%s actual=%s)\n' "$name" "$minimum" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

for required in \
  "$ORCHESTRATOR" \
  "$PLAN_WRITER" \
  "$RUN_TREE" \
  "$BRAINSTORM" \
  "$WRITE_PLAN" \
  "$RESEARCH_CODEBASE" \
  "$RESEARCH_TEST_COVERAGE" \
  "$RESEARCH_CONSTRAINTS" \
  "$RESEARCH_SECURITY"; do
  if [[ ! -r "$required" ]]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$required" >&2
    exit 2
  fi
done

phase4_body=$(awk '
  /^### Phase 4: plan-writer$/ { in_phase = 1 }
  /^### Phase 4\.5:/ { in_phase = 0 }
  in_phase
' "$ORCHESTRATOR")

phase45_body=$(awk '
  /^### Phase 4\.5:/ { in_phase = 1 }
  /^### Phase 5:/ { in_phase = 0 }
  in_phase
' "$ORCHESTRATOR")

printf '%s\n' '== F0 enforced plan-writer tool allowlist =='
if python3 - "$PLAN_WRITER" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.match(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.S)
if not match:
    raise SystemExit("missing frontmatter")
tools_line = re.search(r"(?m)^tools:\s*(.+)$", match.group(1))
if not tools_line:
    raise SystemExit("missing tools frontmatter")
tools = json.loads(tools_line.group(1))
expected = [
    "Read",
    "Write",
    "Edit",
    "Bash(*/lib/planning_research_output.py *)",
    "Bash(shasum *)",
    "Bash(awk *)",
    "Bash(mkdir -p *)",
    "Bash(date *)",
]
if tools != expected:
    raise SystemExit(f"tools mismatch: {tools!r}")
for forbidden in ("Task", "Agent", "spawn_agent", "Skill", "Workflow"):
    if any(forbidden.lower() in tool.lower() for tool in tools):
        raise SystemExit(f"delegation capability leaked: {forbidden}")
PY
then
  printf '%s\n' '  PASS F0 frontmatter enforces the exact non-delegating tool allowlist'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F0 frontmatter must enforce the exact non-delegating tool allowlist'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F0a research-role tool authorization matches planning execution =='
if python3 - \
    "$RESEARCH_CODEBASE" \
    "$RESEARCH_TEST_COVERAGE" \
    "$RESEARCH_CONSTRAINTS" \
    "$RESEARCH_SECURITY" <<'PY'
import json
import re
import sys
from pathlib import Path

common = [
    "Read",
    "Write",
    "Grep",
    "Glob",
    "Bash(*/lib/planning_research_output.py *)",
]
expected = {
    "research-codebase.md": common + [
        "Bash(find *)",
        "Bash(wc *)",
        "Bash(git rev-parse HEAD)",
        "Bash(git log *)",
        "Bash(shasum *)",
        "Bash(awk *)",
    ],
    "research-test-coverage.md": common + [
        "Bash(find *)",
        "Bash(wc *)",
        "Bash(git rev-parse HEAD)",
        "Bash(shasum *)",
        "Bash(awk *)",
    ],
    "research-constraints.md": common + [
        "Bash(git rev-parse HEAD)",
        "Bash(shasum *)",
        "Bash(awk *)",
    ],
    "research-security.md": common + [
        "Bash(git rev-parse HEAD)",
        "Bash(shasum *)",
        "Bash(awk *)",
        "mcp__plugin_semgrep_semgrep__semgrep_scan",
        "mcp__plugin_semgrep_semgrep__semgrep_scan_with_custom_rule",
        "mcp__plugin_semgrep_semgrep__get_supported_languages",
        "WebFetch",
        "WebSearch",
    ],
}
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    text = path.read_text(encoding="utf-8")
    frontmatter = re.match(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.S)
    if not frontmatter:
        raise SystemExit(f"{path.name}: missing frontmatter")
    tools_line = re.search(r"(?m)^tools:\s*(.+)$", frontmatter.group(1))
    if not tools_line:
        raise SystemExit(f"{path.name}: missing enforced tools")
    tools = json.loads(tools_line.group(1))
    if tools != expected[path.name]:
        raise SystemExit(f"{path.name}: tools mismatch: {tools!r}")
    for forbidden in ("Task", "Agent", "spawn_agent", "Skill", "Workflow"):
        if any(forbidden.lower() in tool.lower() for tool in tools):
            raise SystemExit(f"{path.name}: delegation capability leaked: {forbidden}")
PY
then
  printf '%s\n' '  PASS F0a all base roles authorize exact helper/exploration/write/hash tools only'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F0a base-role enforced tool authorization is missing or excessive'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F0b resolver carrier preserves absent callers and fails closed when malformed =='
if python3 - "$ORCHESTRATOR" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
marked = re.search(
    r"<!-- BEGIN resolver-decision-input-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END resolver-decision-input-v1 -->",
    text,
    re.S,
)
if not marked:
    raise SystemExit("missing resolver-decision-input-v1")
contract = json.loads(marked.group(1))
expected = {
    "input_key": "resolver_decision",
    "required_fields": {
        "schema_version": 1,
        "risk_signals": "array[string]",
    },
    "captured_state": {
        "decision": "validated_resolver_decision",
        "risk_signals": "validated_risk_signals",
    },
    "conditional_security_source": "validated_risk_signals",
    "infer_from_issue_body_or_text": False,
    "on_absent": {
        "validated_resolver_decision": {
            "schema_version": 1,
            "risk_signals": [],
            "route_source": "compatibility-default",
        },
        "validated_risk_signals": [],
        "planning_security_dispatch": False,
        "reason": "carrier_absent_pending_t40_6",
        "provenance": "v0.40-foundation-compatibility",
    },
    "on_malformed_supplied": {
        "status": "BLOCKED",
        "artifact_path": "",
        "artifact_sha": "",
        "dispatch_any_child": False,
    },
    "carrier_owner": "T40-6",
}
if contract != expected:
    raise SystemExit(f"resolver contract mismatch: {contract!r}")
phase0 = re.search(r"(?ms)^### Phase 0: setup$(.*?)(?=^### Phase 1)", text)
if not phase0:
    raise SystemExit("Phase 0 missing")
for marker in (
    "validated_resolver_decision",
    "validated_risk_signals",
    "T40-6",
    "Do not infer",
    "carrier_absent_pending_t40_6",
    "optional through the T40-3/T40-5 foundation",
):
    if marker not in phase0.group(1):
        raise SystemExit(f"Phase 0 missing marker: {marker}")
for contradiction in (
    "Phase 0 requires a resolver-owned decision object",
    "dispatch also supplies a structured, non-text `resolver_decision` input",
):
    if contradiction in text:
        raise SystemExit(f"optional carrier contradicted by: {contradiction}")
PY
then
  printf '%s\n' '  PASS F0b absent carrier is compatibility-safe while malformed supplied carrier fails closed'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F0b resolver decision/risk state contract missing or malformed'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F0c canonical BLOCKED/no-artifact policy =='
lowercase_blocked_hits=$(grep -nE 'status: blocked|terminal_status": "blocked"' \
  "$ORCHESTRATOR" "$PLAN_WRITER" || true)
if [[ -n "$lowercase_blocked_hits" ]]; then
  printf '%s\n' '  FAIL F0c lowercase blocked status remains:'
  printf '%s\n' "$lowercase_blocked_hits"
  FAIL=$((FAIL + 1))
else
  printf '%s\n' '  PASS F0c status enum uses canonical uppercase BLOCKED'
  PASS=$((PASS + 1))
fi
n=$(grep -cF 'artifact_path: ""' "$ORCHESTRATOR" || true)
assert_ge 'F0c BLOCKED contract carries no artifact_path' 1 "$n"
n=$(grep -cF 'artifact_sha: ""' "$ORCHESTRATOR" || true)
assert_ge 'F0c BLOCKED contract carries no artifact_sha' 1 "$n"
for policy_marker in \
  'Phase-1 optional research BLOCKED is advisory' \
  'Phase-4 required planning BLOCKED is terminal' \
  'planning-security BLOCKED is advisory'; do
  n=$(grep -cF "$policy_marker" "$ORCHESTRATOR" || true)
  assert_ge "F0c scoped status policy: $policy_marker" 1 "$n"
done

printf '%s\n' '== F0d trivial/small terminal tier handoff =='
if python3 - "$ORCHESTRATOR" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
marked = re.search(
    r"<!-- BEGIN orchestrator-tier-gate-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END orchestrator-tier-gate-v1 -->",
    text,
    re.S,
)
if not marked:
    raise SystemExit("missing orchestrator-tier-gate-v1")
contract = json.loads(marked.group(1))
expected = {
    "caller_contract": "solve-pipeline-tier-native",
    "bypass_tiers": ["trivial", "small"],
    "defensive_phase0_action": "terminal_handoff_return",
    "continue_tiers": ["medium", "large"],
    "forbidden_after_handoff": [
        "phase1_research",
        "phase2_qa",
        "phase3_spec",
        "phase4_planning_research",
        "plan_writer",
        "phase5_implementation",
        "phase6_review_chain",
    ],
}
if contract != expected:
    raise SystemExit(f"tier gate contract mismatch: {contract!r}")

phase0 = re.search(r"(?ms)^### Phase 0: setup$(.*?)(?=^### Phase 1)", text)
phase1 = re.search(r"(?ms)^### Phase 1: research fanout \(parallel\)$(.*?)(?=^### Phase 2)", text)
phase4 = re.search(r"(?ms)^### Phase 4: plan-writer$(.*?)(?=^### Phase 4\.5:)", text)
if not (phase0 and phase1 and phase4):
    raise SystemExit("required phase boundary missing")
if marked.start() > text.index("### Phase 1: research fanout (parallel)"):
    raise SystemExit("tier terminal gate does not precede Phase 1")
for marker in (
    "return immediately",
    "MUST NOT enter Phase 1",
    "solve-pipeline",
    "tier-native",
):
    if marker not in phase0.group(1):
        raise SystemExit(f"Phase 0 terminal gate missing {marker!r}")
if re.search(r"(?i)small.{0,80}dispatch|dispatch.{0,80}small", phase1.group(1)):
    raise SystemExit("operative small-tier Phase-1 dispatch remains")
if "medium/large only" not in phase1.group(1):
    raise SystemExit("Phase 1 lacks medium/large-only precondition")
if "medium/large only" not in phase4.group(1):
    raise SystemExit("Phase 4 lacks medium/large-only precondition")

# Execute the documented phase-entry state machine. Bypass tiers must have no
# reachable research/planning dispatches; both full tiers retain both sites.
def reachable_dispatches(tier: str) -> list[str]:
    if tier in contract["bypass_tiers"]:
        return []
    if tier in contract["continue_tiers"]:
        return ["phase1_research", "phase4_planning_research", "plan_writer"]
    raise ValueError(tier)

for tier in ("trivial", "small"):
    if reachable_dispatches(tier):
        raise SystemExit(f"{tier} can reach orchestrator dispatches")
for tier in ("medium", "large"):
    if reachable_dispatches(tier) != [
        "phase1_research", "phase4_planning_research", "plan_writer"
    ]:
        raise SystemExit(f"{tier} full pipeline changed")
PY
then
  printf '%s\n' '  PASS F0d trivial/small terminate before all orchestrator research/planning dispatches'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F0d trivial/small must hand off before Phase 1 and Phase 4'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F1 plan-writer is a true leaf =='
nested_hits=$(grep -nE \
  '(^### .*Internal research fanout)|Task[[:space:]]*(\(|tool)|spawn_agent|^[[:space:]]*(Dispatch|Re-dispatch).*(subagent|agent)' \
  "$PLAN_WRITER" || true)
if [[ -n "$nested_hits" ]]; then
  printf '%s\n' '  FAIL F1 nested child-owned research/delegation remains in plan-writer:'
  printf '%s\n' "$nested_hits" | sed -n '1,8p'
  FAIL=$((FAIL + 1))
else
  printf '%s\n' '  PASS F1 plan-writer has no executable or normative child delegation'
  PASS=$((PASS + 1))
fi

n=$(grep -cF 'Do not delegate' "$PLAN_WRITER" || true)
assert_ge 'F1b explicit Do not delegate instruction' 1 "$n"

printf '%s\n' '== F2 root-owned planning fanout precedes plan-writer =='
fanout_line=$(printf '%s\n' "$phase4_body" | grep -nF 'Root-owned planning-research fanout' | head -1 | cut -d: -f1 || true)
writer_line=$(printf '%s\n' "$phase4_body" | grep -nE '^Dispatch `plan-writer`' | head -1 | cut -d: -f1 || true)
if [[ -n "$fanout_line" && -n "$writer_line" && "$fanout_line" -lt "$writer_line" ]]; then
  printf '  PASS F2 planning fanout precedes plan-writer (fanout=%s writer=%s)\n' "$fanout_line" "$writer_line"
  PASS=$((PASS + 1))
else
  printf '  FAIL F2 planning fanout must precede plan-writer (fanout=%s writer=%s)\n' \
    "${fanout_line:-missing}" "${writer_line:-missing}"
  FAIL=$((FAIL + 1))
fi

n=$(printf '%s\n' "$phase4_body" | grep -ciE 'one parallel dispatch wave|single message.*parallel' || true)
assert_ge 'F2b base planning researchers form one parallel dispatch wave' 1 "$n"

codebase_line=$(printf '%s\n' "$phase4_body" | grep -nE 'research-codebase.*dependency-map\.md' | head -1 | cut -d: -f1 || true)
coverage_line=$(printf '%s\n' "$phase4_body" | grep -nE 'research-test-coverage.*test-map\.md' | head -1 | cut -d: -f1 || true)
constraints_line=$(printf '%s\n' "$phase4_body" | grep -nE 'research-constraints.*implementation-risk\.md' | head -1 | cut -d: -f1 || true)
wait_line=$(printf '%s\n' "$phase4_body" | grep -nE 'Wait for all planning-research children' | head -1 | cut -d: -f1 || true)
if [[ -n "$codebase_line" && -n "$coverage_line" && -n "$constraints_line" && -n "$wait_line" ]] \
  && (( wait_line > codebase_line && wait_line > coverage_line && wait_line > constraints_line )); then
  printf '%s\n' '  PASS F2c all three canonical base roles dispatch before the shared wait'
  PASS=$((PASS + 1))
else
  printf '  FAIL F2c base roles must all dispatch before one shared wait (codebase=%s coverage=%s constraints=%s wait=%s)\n' \
    "${codebase_line:-missing}" "${coverage_line:-missing}" "${constraints_line:-missing}" "${wait_line:-missing}"
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F2d machine-readable fanout contract =='
if python3 - "$ORCHESTRATOR" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
marked = re.search(
    r"<!-- BEGIN planning-research-contract-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END planning-research-contract-v1 -->",
    text,
    re.S,
)
if not marked:
    raise SystemExit("missing planning-research-contract-v1")
contract = json.loads(marked.group(1))
expected_base = [
    {"key": "dependency_map_path", "role": "research-codebase", "filename": "dependency-map.md"},
    {"key": "test_map_path", "role": "research-test-coverage", "filename": "test-map.md"},
    {"key": "implementation_risk_path", "role": "research-constraints", "filename": "implementation-risk.md"},
]
if contract.get("base_artifacts") != expected_base:
    raise SystemExit(f"base mapping mismatch: {contract.get('base_artifacts')!r}")
dispatch = contract.get("dispatch", {})
if dispatch != {
    "issue_all_base_calls_before_wait": True,
    "shared_wait_count": 1,
    "retry_format_once_per_child": True,
}:
    raise SystemExit(f"dispatch mismatch: {dispatch!r}")
security = contract.get("conditional_security", {})
if security != {
    "role": "research-security",
    "condition_source": "validated_risk_signals",
    "infer_from_issue_body_or_text": False,
    "issue_before_shared_wait": True,
    "adds_planning_research_key": False,
}:
    raise SystemExit(f"security mismatch: {security!r}")
failure = contract.get("validation_failure", {})
if failure != {
    "targeted_retry_count": 1,
    "retry_scope": "failed_canonical_role_only",
    "terminal_status": "BLOCKED",
    "dispatch_plan_writer_after_terminal_failure": False,
}:
    raise SystemExit(f"failure transition mismatch: {failure!r}")
revision = contract.get("revision", {})
if revision != {
    "reuse_keys": ["dependency_map_path", "test_map_path", "implementation_risk_path"],
    "rerun_planning_research": False,
}:
    raise SystemExit(f"revision mismatch: {revision!r}")
if len(contract.get("planning_research_keys", [])) != 3:
    raise SystemExit("planning_research must have exactly three keys")
if contract["planning_research_keys"] != [item["key"] for item in expected_base]:
    raise SystemExit("planning_research key order/mapping drift")
PY
then
  printf '%s\n' '  PASS F2d exact role/order/wait/security/retry/revision contract parses'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F2d exact role/order/wait/security/retry/revision contract must parse'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F2e base research roles expose backward-compatible planning mode =='
if python3 - \
    "$ORCHESTRATOR" \
    "$RESEARCH_CODEBASE" \
    "$RESEARCH_TEST_COVERAGE" \
    "$RESEARCH_CONSTRAINTS" \
    "$RESEARCH_SECURITY" \
    "$PLAN_WRITER" <<'PY'
import json
import re
import sys
from pathlib import Path, PurePosixPath

orchestrator_text = Path(sys.argv[1]).read_text(encoding="utf-8")
contract_match = re.search(
    r"<!-- BEGIN planning-research-contract-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END planning-research-contract-v1 -->",
    orchestrator_text,
    re.S,
)
if not contract_match:
    raise SystemExit("orchestrator planning contract missing")
orchestrator_contract = json.loads(contract_match.group(1))
by_role = {item["role"]: item for item in orchestrator_contract["base_artifacts"]}

expected = {
    "research-codebase": (sys.argv[2], "dependency_map_path", "dependency-map.md", "codebase.md"),
    "research-test-coverage": (sys.argv[3], "test_map_path", "test-map.md", "test-coverage.md"),
    "research-constraints": (sys.argv[4], "implementation_risk_path", "implementation-risk.md", "constraints.md"),
}
required_planning_inputs = [
    "research_mode",
    "spec_path",
    "working_dir",
    "summary_dir",
    "output_path",
    "validation_shim",
]
run_dir = PurePosixPath("/tmp/current run with spaces")
for role, (path, key, planning_filename, general_filename) in expected.items():
    text = Path(path).read_text(encoding="utf-8")
    marked = re.search(
        r"<!-- BEGIN research-mode-contract-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END research-mode-contract-v1 -->",
        text,
        re.S,
    )
    if not marked:
        raise SystemExit(f"{role}: missing research-mode-contract-v1")
    contract = json.loads(marked.group(1))
    expected_contract = {
        "mode_key": "research_mode",
        "default_mode": "general",
        "general": {
            "required_inputs": ["issue_body", "working_dir", "summary_dir"],
            "output_filename": general_filename,
        },
        "planning": {
            "required_inputs": required_planning_inputs,
            "source_input": "spec_path",
            "issue_body_required": False,
            "output_key": key,
            "output_filename": planning_filename,
            "output_path_semantics": "exact_requested_path",
            "validation_shim": "planning_research_output.py",
            "require_absolute": True,
            "require_run_confined": True,
            "prewrite_validation": "canonical_parent_plus_exact_basename",
        },
    }
    if contract != expected_contract:
        raise SystemExit(f"{role}: mode contract mismatch: {contract!r}")
    if by_role.get(role) != {"key": key, "role": role, "filename": planning_filename}:
        raise SystemExit(f"{role}: orchestrator/agent contract drift")
    generated = run_dir / contract["planning"]["output_filename"]
    requested = run_dir / planning_filename
    if generated != requested:
        raise SystemExit(f"{role}: planning exact output drift: {generated}")
    for marker in (
        "### General mode (default)",
        "### Planning mode",
        "status: BLOCKED",
        "--operation allocate",
        "--operation abort",
        "--operation publish",
        "--allocation-token",
        "staging_path",
        "allocation_token",
    ):
        if marker not in text:
            raise SystemExit(f"{role}: missing operative marker {marker!r}")
    if not re.search(r"(?s)status: BLOCKED.*?artifact_path: \"\".*?artifact_sha: \"\"", text):
        raise SystemExit(f"{role}: BLOCKED no-artifact contract missing")

security_text = Path(sys.argv[5]).read_text(encoding="utf-8")
security_marked = re.search(
    r"<!-- BEGIN research-mode-contract-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END research-mode-contract-v1 -->",
    security_text,
    re.S,
)
if not security_marked:
    raise SystemExit("research-security: planning mode contract missing")
security_contract = json.loads(security_marked.group(1))
expected_security = {
    "mode_key": "research_mode",
    "default_mode": "general",
    "general": {
        "required_inputs": ["issue_body", "working_dir", "summary_dir"],
        "output_filename": "security.md",
    },
    "planning": {
        "required_inputs": [
            "research_mode",
            "spec_path",
            "working_dir",
            "summary_dir",
            "output_path",
            "validation_shim",
            "risk_signals",
        ],
        "source_input": "spec_path",
        "issue_body_required": False,
        "risk_signals_source": "validated_risk_signals",
        "output_filename": "planning-security.md",
        "output_path_semantics": "exact_requested_path",
        "validation_shim": "planning_research_output.py",
        "require_absolute": True,
        "require_run_confined": True,
        "blocked_policy": "advisory",
    },
}
if security_contract != expected_security:
    raise SystemExit(f"research-security: mode contract mismatch: {security_contract!r}")

phase4 = re.search(r"(?ms)^### Phase 4: plan-writer$(.*?)(?=^### Phase 4\.5:)", orchestrator_text)
if not phase4:
    raise SystemExit("orchestrator Phase 4 missing")
for marker in (
    "summary_path",
    "validation_path",
    "output_path",
    "planning-security.md",
):
    if marker not in phase4.group(1):
        raise SystemExit(f"orchestrator planning dispatch missing {marker!r}")
for marker in (
    "--operation allocate",
    "--operation abort",
    "--operation publish",
    "--allocation-token",
    "staging_path",
    "allocation_token",
):
    if marker not in security_text:
        raise SystemExit(f"research-security atomic publication missing {marker!r}")
for marker in (
    "validate`, `allocate`, `abort`, and `publish",
    "allocation_token",
    "content-generation or publish failure",
):
    if marker not in phase4.group(1):
        raise SystemExit(f"orchestrator lifecycle contract missing {marker!r}")
plan_writer_text = Path(sys.argv[6]).read_text(encoding="utf-8")
if "Allocation cleanup is N/A" not in plan_writer_text:
    raise SystemExit("plan-writer must explicitly reject staging ownership")
PY
then
  printf '%s\n' '  PASS F2e three real roles accept exact planning inputs/paths and preserve general mode'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F2e base-role planning mode contracts are missing or incompatible'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F2f constraints role scans actual RFC/ADR conventions =='
if python3 - "$ROOT" "$RESEARCH_CONSTRAINTS" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
text = Path(sys.argv[2]).read_text(encoding="utf-8")
for marker in (
    "<working_dir>/docs/rfc/*.md",
    "<working_dir>/docs/adr/*.md",
    "relevance filtering",
):
    if marker not in text:
        raise SystemExit(f"constraints contract missing: {marker}")
for stale in ("docs/rfc/RFC-*.md", "docs/adr/ADR-*.md"):
    if stale in text:
        raise SystemExit(f"stale glob remains: {stale}")
matches = {path.name for path in (root / "docs/rfc").glob("*.md")}
if "0013-gpt-5-6-adaptive-execution.md" not in matches:
    raise SystemExit("numeric RFC 0013 is not found by docs/rfc/*.md")
PY
then
  printf '%s\n' '  PASS F2f numeric RFC 0013 is discoverable with the real RFC/ADR glob contract'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F2f constraints role still uses stale RFC-/ADR- filename globs'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F3 artifact labels are never agent names =='
new_role_hits=$(printf '%s\n' "$phase4_body" | grep -nE \
  'Task[[:space:]]*\([[:space:]]*(dependency-map|test-map|implementation-risk)|subagent_type[=:].*(dependency-map|test-map|implementation-risk)' || true)
if [[ -n "$new_role_hits" ]]; then
  printf '%s\n' '  FAIL F3f artifact labels were used as agent names:'
  printf '%s\n' "$new_role_hits"
  FAIL=$((FAIL + 1))
else
  printf '%s\n' '  PASS F3f artifact labels are not agent names'
  PASS=$((PASS + 1))
fi

printf '%s\n' '== F4 exact three-path planning input =='
if python3 - "$ORCHESTRATOR" "$PLAN_WRITER" <<'PY'
import re
import sys
from pathlib import Path

orchestrator=Path(sys.argv[1]).read_text()
writer=Path(sys.argv[2]).read_text()
expected=["dependency-map.md","test-map.md","implementation-risk.md"]
match=re.search(r"planning_paths:\s*\n((?:  - .*\n?){3})",writer)
if not match: raise SystemExit("plan-writer missing planning_paths list")
paths=re.findall(r"(?m)^  - (\S+)",match.group(1))
if [path.rsplit('/',1)[-1] for path in paths] != expected:
    raise SystemExit("plan-writer planning_paths order drift")
if '"planning_paths":json.loads' not in orchestrator or '"validation_path":' not in orchestrator:
    raise SystemExit("orchestrator plan-writer payload missing canonical fields")
PY
then
  printf '%s\n' '  PASS F4b plan-writer receives the exact ordered three-path manifest input'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F4b planning_research mappings must have exactly three canonical keys'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F5 canonical path validation at both trust boundaries =='
validation_body=$(awk '
  /^### Step 1: Validate planning research paths$/ { in_step = 1 }
  /^### Step 2:/ { in_step = 0 }
  in_step
' "$PLAN_WRITER")
for body_name in phase4_body validation_body; do
  if [[ "$body_name" == "phase4_body" ]]; then body="$phase4_body"; else body="$validation_body"; fi
  for marker in 'planning_research_output.py' '--operation validate' '--mode postwrite' '--summary-dir' '--output-path' '--expected-basename'; do
    n=$(printf '%s\n' "$body" | grep -cF -- "$marker" || true)
    assert_ge "F5 ${body_name} invokes production shim with: $marker" 1 "$n"
  done
done

legacy_helper_hits=$(grep -nE 'planning-research-preflight-v1|uberdev_canonical_path|uberdev_validate_planning_output' \
  "$ORCHESTRATOR" "$PLAN_WRITER" "$RESEARCH_CODEBASE" "$RESEARCH_TEST_COVERAGE" "$RESEARCH_CONSTRAINTS" || true)
if [[ -n "$legacy_helper_hits" ]]; then
  printf '%s\n' '  FAIL F5 Markdown helper/function dependency remains:'
  printf '%s\n' "$legacy_helper_hits"
  FAIL=$((FAIL + 1))
else
  printf '%s\n' '  PASS F5 no Markdown helper/function dependency remains'
  PASS=$((PASS + 1))
fi


printf '%s\n' '== F5b executable planning-research path fixtures =='
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uberdev-plan-flatten.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
validate_prewrite() {
  "$PLANNING_OUTPUT_SHIM" --operation validate --mode prewrite \
    --summary-dir "$1" --output-path "$2" --expected-basename "$3"
}

validate_postwrite() {
  "$PLANNING_OUTPUT_SHIM" --operation validate --mode postwrite \
    --summary-dir "$1" --output-path "$2" --expected-basename "$3" --key "$4"
}

allocate_staging() {
  "$PLANNING_OUTPUT_SHIM" --operation allocate \
    --summary-dir "$1" --expected-basename "$2" --key "$3"
}

publish_staging() {
  "$PLANNING_OUTPUT_SHIM" --operation publish \
    --summary-dir "$1" --output-path "$2" --expected-basename "$3" \
    --staging-path "$4" --allocation-token "$5" --key "$6"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])[sys.argv[2]]
if not isinstance(value, str):
    raise SystemExit(2)
print(value)
PY
}

json_valid_exact() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

raw, expected_path = sys.argv[1:]
if "\n" in raw or "\r" in raw:
    raise SystemExit("result is not one compact JSON line")
payload = json.loads(raw)
expected = {"output_path": expected_path, "status": "valid"}
if payload != expected:
    raise SystemExit(f"payload mismatch: {payload!r}")
PY
}

assert_json_valid() {
  local name="$1" actual="$2" expected_path="$3"
  if json_valid_exact "$actual" "$expected_path"; then
    printf '  PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (actual=%s)\n' "$name" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_invalid() {
  local name="$1" actual="$2" expected_key="$3" expected_reason="$4"
  if python3 - "$actual" "$expected_key" "$expected_reason" <<'PY'
import json
import sys

raw, expected_key, expected_reason = sys.argv[1:]
if "\n" in raw or "\r" in raw:
    raise SystemExit("result is not one compact JSON line")
payload = json.loads(raw)
expected = {
    "key": expected_key,
    "output_path": "",
    "reason": expected_reason,
    "status": "invalid",
}
if payload != expected:
    raise SystemExit(f"payload mismatch: {payload!r}")
PY
  then
    printf '  PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (actual=%s)\n' "$name" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

validate_three_postwrite() {
  local summary_dir="$1"
  local output
  output=$(validate_postwrite "$summary_dir" "$2" dependency-map.md dependency_map_path) || {
    printf '%s\n' "$output"
    return 1
  }
  json_valid_exact "$output" "$2" || return 1
  output=$(validate_postwrite "$summary_dir" "$3" test-map.md test_map_path) || {
    printf '%s\n' "$output"
    return 1
  }
  json_valid_exact "$output" "$3" || return 1
  output=$(validate_postwrite "$summary_dir" "$4" implementation-risk.md implementation_risk_path) || {
    printf '%s\n' "$output"
    return 1
  }
  json_valid_exact "$output" "$4" || return 1
  printf 'status: valid\n'
}

if [[ -x "$PLANNING_OUTPUT_SHIM" ]]; then
  printf '%s\n' '  PASS F5b0 production planning-output shim exists and is executable'
  PASS=$((PASS + 1))

  for mapping in \
    'research-codebase|dependency-map.md' \
    'research-test-coverage|test-map.md' \
    'research-constraints|implementation-risk.md'; do
    role=${mapping%%|*}
    filename=${mapping#*|}
    ROLE_RUN="$TMP_ROOT/prewrite $role"
    mkdir -p "$ROLE_RUN"
    valid_output="$ROLE_RUN/$filename"
    if output=$(validate_prewrite "$ROLE_RUN" "$valid_output" "$filename"); then
      assert_json_valid "F5b0d $role accepts its exact absent output path" "$output" "$valid_output"
    else
      printf '  FAIL F5b0d %s rejected valid output: %s\n' "$role" "$output"
      FAIL=$((FAIL + 1))
    fi

    if output=$(validate_prewrite "$ROLE_RUN" "$ROLE_RUN/wrong-name.md" "$filename"); then
      printf '  FAIL F5b0e %s accepted wrong basename\n' "$role"
      FAIL=$((FAIL + 1))
    else
      assert_json_invalid "F5b0e $role rejects wrong basename" "$output" output_path wrong_basename
    fi

    if output=$(validate_prewrite "$ROLE_RUN" "$filename" "$filename"); then
      printf '  FAIL F5b0f %s accepted relative output\n' "$role"
      FAIL=$((FAIL + 1))
    else
      assert_json_invalid "F5b0f $role rejects relative output" "$output" output_path absolute
    fi

    if output=$(validate_prewrite "$ROLE_RUN" "$ROLE_RUN/missing-parent/$filename" "$filename"); then
      printf '  FAIL F5b0g %s accepted missing output parent\n' "$role"
      FAIL=$((FAIL + 1))
    else
      assert_json_invalid "F5b0g $role rejects missing output parent" "$output" output_path canonicalize
    fi

    printf 'outside\n' > "$TMP_ROOT/outside-$role.md"
    ln -s "$TMP_ROOT/outside-$role.md" "$valid_output"
    if output=$(validate_prewrite "$ROLE_RUN" "$valid_output" "$filename"); then
      printf '  FAIL F5b0h %s accepted escaping output symlink\n' "$role"
      FAIL=$((FAIL + 1))
    else
      assert_json_invalid "F5b0h $role rejects escaping output symlink" "$output" output_path run_dir_confinement
    fi
  done

  if python3 - "$PLANNING_OUTPUT_SHIM" <<'PY'
import ast
import sys
from pathlib import Path

tree = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(alias.name.split(".", 1)[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        imports.add(node.module.split(".", 1)[0])
allowed = set(sys.stdlib_module_names) | {"__future__"}
if not imports <= allowed:
    raise SystemExit(f"non-stdlib or unexpected imports: {sorted(imports - allowed)!r}")
PY
  then
    printf '%s\n' '  PASS F5b0i production shim is stdlib-only'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0i production shim has a non-stdlib dependency'
    FAIL=$((FAIL + 1))
  fi

  if python3 - "$PLANNING_OUTPUT_SHIM" "$TMP_ROOT" <<'PY'
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

shim, raw_root = sys.argv[1:]
summary = Path(raw_root) / "restrictive umask"
summary.mkdir()
output = summary / "dependency-map.md"

def restrictive_umask() -> None:
    os.umask(0o777)

allocated = subprocess.run(
    [shim, "--operation", "allocate", "--summary-dir", str(summary),
     "--expected-basename", output.name, "--key", "dependency_map_path"],
    check=False,
    capture_output=True,
    text=True,
    preexec_fn=restrictive_umask,
)
if allocated.returncode != 0 or allocated.stderr:
    raise SystemExit(f"allocate failed: {allocated!r}")
staging = Path(json.loads(allocated.stdout)["staging_path"])
allocation_token = json.loads(allocated.stdout)["allocation_token"]
if stat.S_IMODE(staging.stat().st_mode) != 0o600:
    raise SystemExit("allocated staging file is not private mode 0600")
staging.write_text("private publication\n", encoding="utf-8")

published = subprocess.run(
    [shim, "--operation", "publish", "--summary-dir", str(summary),
     "--output-path", str(output), "--expected-basename", output.name,
     "--staging-path", str(staging), "--allocation-token", allocation_token,
     "--key", "dependency_map_path"],
    check=False,
    capture_output=True,
    text=True,
    preexec_fn=restrictive_umask,
)
if published.returncode != 0 or published.stderr:
    raise SystemExit(f"publish failed: {published!r}")
if json.loads(published.stdout) != {
    "output_path": str(output), "staging_path": "", "status": "published"
}:
    raise SystemExit(f"unexpected publish payload: {published.stdout!r}")
if stat.S_IMODE(output.stat().st_mode) != 0o600:
    raise SystemExit("published target is not private mode 0600")
PY
  then
    printf '%s\n' '  PASS F5b0i2 staging and publication remain private under restrictive umask'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0i2 private temp mode depends on caller umask'
    FAIL=$((FAIL + 1))
  fi

  if python3 - "$PLANNING_OUTPUT_SHIM" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

shim, raw_root = sys.argv[1:]
root = Path(raw_root) / "allocation lifecycle"
root.mkdir()

def invoke(*arguments: str) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
    result = subprocess.run(
        [shim, *arguments], check=False, capture_output=True, text=True
    )
    if result.stderr or len(result.stdout.splitlines()) != 1:
        raise AssertionError(f"non-JSON CLI channel: {result!r}")
    return result, json.loads(result.stdout)

def allocate(summary: Path, basename: str) -> tuple[Path, str]:
    result, payload = invoke(
        "--operation", "allocate",
        "--summary-dir", str(summary),
        "--expected-basename", basename,
        "--key", "dependency_map_path",
    )
    if result.returncode != 0 or payload.get("status") != "allocated":
        raise AssertionError(f"allocation failed: {result!r} {payload!r}")
    if set(payload) != {"allocation_token", "staging_path", "status"}:
        raise AssertionError(f"allocation capability missing: {payload!r}")
    staging = Path(str(payload["staging_path"]))
    token = payload["allocation_token"]
    if not isinstance(token, str) or not token.startswith("v1:"):
        raise AssertionError(f"invalid allocation capability: {token!r}")
    return staging, token

def publish(
    summary: Path, basename: str, staging: Path, token: str
) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
    return invoke(
        "--operation", "publish",
        "--summary-dir", str(summary),
        "--output-path", str(summary / basename),
        "--expected-basename", basename,
        "--staging-path", str(staging),
        "--allocation-token", token,
        "--key", "dependency_map_path",
    )

def abort(
    summary: Path, basename: str, staging: Path, token: str
) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
    return invoke(
        "--operation", "abort",
        "--summary-dir", str(summary),
        "--expected-basename", basename,
        "--staging-path", str(staging),
        "--allocation-token", token,
        "--key", "dependency_map_path",
    )

def expect_failure(
    result: subprocess.CompletedProcess[str], payload: dict[str, object], reason: str
) -> None:
    expected = {
        "key": "dependency_map_path",
        "output_path": "",
        "reason": reason,
        "status": "invalid",
    }
    if result.returncode == 0 or payload != expected:
        raise AssertionError(f"expected {reason}: rc={result.returncode} payload={payload!r}")

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

# A validation failure on the original owned inode must remove its staging name.
mode_dir = root / "mode failure"
mode_dir.mkdir()
staging, token = allocate(mode_dir, "dependency-map.md")
staging.write_text("mode failure\n", encoding="utf-8")
staging.chmod(0o644)
result, payload = publish(mode_dir, "dependency-map.md", staging, token)
expect_failure(result, payload, "staging_mode")
if os.path.lexists(staging):
    raise AssertionError("staging_mode failure leaked owned staging")

# A hard-link alias of the owned inode is rejected, but cleanup removes only
# the staging name and leaves the alias content/inode available and unchanged.
link_dir = root / "hardlink failure"
link_dir.mkdir()
staging, token = allocate(link_dir, "dependency-map.md")
staging.write_text("hardlink sentinel\n", encoding="utf-8")
alias = link_dir / "owned-alias.md"
os.link(staging, alias)
before = digest(alias)
result, payload = publish(link_dir, "dependency-map.md", staging, token)
expect_failure(result, payload, "hardlink_alias")
if os.path.lexists(staging) or digest(alias) != before:
    raise AssertionError("hardlink failure cleanup mutated/leaked owned entry")

# A symlink swapped into the capability path is not shim-owned and must survive.
symlink_dir = root / "symlink replacement"
symlink_dir.mkdir()
staging, token = allocate(symlink_dir, "dependency-map.md")
staging.unlink()
sentinel = symlink_dir / "sentinel.md"
sentinel.write_text("symlink sentinel\n", encoding="utf-8")
before = digest(sentinel)
staging.symlink_to(sentinel)
result, payload = publish(symlink_dir, "dependency-map.md", staging, token)
expect_failure(result, payload, "allocation_mismatch")
if not staging.is_symlink() or digest(sentinel) != before:
    raise AssertionError("publish removed an attacker-swapped symlink")

# A regular hard-link replacement models a between-boundary race. Its inode is
# outside the allocation capability and must not be unlinked or modified.
race_dir = root / "race replacement"
race_dir.mkdir()
sentinel = race_dir / "race-sentinel.md"
sentinel.write_text("race sentinel\n", encoding="utf-8")
before = digest(sentinel)
staging, token = allocate(race_dir, "dependency-map.md")
staging.unlink()
os.link(sentinel, staging)
result, payload = publish(race_dir, "dependency-map.md", staging, token)
expect_failure(result, payload, "allocation_mismatch")
if not staging.exists() or digest(staging) != before or digest(sentinel) != before:
    raise AssertionError("publish removed or mutated a race replacement")

# Explicit abort cleans an abandoned allocation and is idempotent.
abort_dir = root / "abandoned allocation"
abort_dir.mkdir()
staging, token = allocate(abort_dir, "dependency-map.md")
staging.write_text("abandoned\n", encoding="utf-8")
for attempt in (1, 2):
    result, payload = abort(abort_dir, "dependency-map.md", staging, token)
    if result.returncode != 0 or payload != {"staging_path": "", "status": "aborted"}:
        raise AssertionError(f"abort attempt {attempt} failed: {result!r} {payload!r}")
    if os.path.lexists(staging):
        raise AssertionError(f"abort attempt {attempt} left staging")

# Abort also fails closed when the name was replaced, preserving the replacement.
abort_swap_dir = root / "abort replacement"
abort_swap_dir.mkdir()
staging, token = allocate(abort_swap_dir, "dependency-map.md")
staging.unlink()
sentinel = abort_swap_dir / "abort-sentinel.md"
sentinel.write_text("abort sentinel\n", encoding="utf-8")
before = digest(sentinel)
staging.symlink_to(sentinel)
result, payload = abort(abort_swap_dir, "dependency-map.md", staging, token)
expect_failure(result, payload, "allocation_mismatch")
if not staging.is_symlink() or digest(sentinel) != before:
    raise AssertionError("abort deleted attacker replacement")
PY
  then
    printf '%s\n' '  PASS F5b0i3 capability cleanup covers publish failures and idempotent abort'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0i3 publish/abort leaked staging or mutated a replacement sentinel'
    FAIL=$((FAIL + 1))
  fi

  if python3 - "$PLANNING_OUTPUT_SHIM" "$TMP_ROOT" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

shim, raw_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("planning_research_output", shim)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load production shim")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if not hasattr(module, "_atomic_rename_noreplace"):
    raise SystemExit("missing atomic no-overwrite quarantine rename")

root = Path(raw_root) / "quarantine boundary"
root.mkdir()

def owned_fixture(case: str) -> tuple[Path, int, str, tuple[int, int]]:
    summary = root / case
    summary.mkdir()
    dir_fd = os.open(summary, os.O_RDONLY | os.O_DIRECTORY)
    name, staging_fd = module._create_private(dir_fd, "dependency-map.md", "stage")
    os.write(staging_fd, b"owned staging\n")
    staging_stat = os.fstat(staging_fd)
    os.close(staging_fd)
    return summary, dir_fd, name, (staging_stat.st_dev, staging_stat.st_ino)

def inject_at_atomic_boundary(case: str, symlink: bool) -> None:
    summary, dir_fd, name, allocation_inode = owned_fixture(case)
    public = summary / name
    sentinel = summary / "sentinel.md"
    sentinel.write_text(f"{case} sentinel\n", encoding="utf-8")
    original_rename = module._atomic_rename_noreplace
    injected = False

    def swap_then_rename(fd: int, source: str, destination: str) -> None:
        nonlocal injected
        if not injected and source == name:
            injected = True
            os.unlink(source, dir_fd=fd)
            if symlink:
                os.symlink(str(sentinel), source, dir_fd=fd)
            else:
                os.link(str(sentinel), source, dst_dir_fd=fd)
        original_rename(fd, source, destination)

    module._atomic_rename_noreplace = swap_then_rename
    try:
        state = module._unlink_owned_staging(
            dir_fd, name, allocation_inode, "dependency-map.md"
        )
    finally:
        module._atomic_rename_noreplace = original_rename
        os.close(dir_fd)
    if state != "mismatch" or not injected:
        raise AssertionError(f"{case}: replacement boundary not detected: {state}")
    if symlink:
        if not public.is_symlink() or os.readlink(public) != str(sentinel):
            raise AssertionError(f"{case}: symlink replacement was not restored exactly")
    elif not public.exists() or public.read_bytes() != sentinel.read_bytes():
        raise AssertionError(f"{case}: regular replacement was not preserved")
    if sentinel.read_text(encoding="utf-8") != f"{case} sentinel\n":
        raise AssertionError(f"{case}: unrelated sentinel was mutated")

inject_at_atomic_boundary("regular swap", symlink=False)
inject_at_atomic_boundary("symlink swap", symlink=True)

# A pre-existing private quarantine collision must not be overwritten; retry
# uses a fresh secret name and disposes only the owned staging inode.
summary, dir_fd, name, allocation_inode = owned_fixture("collision")
collision_name = ".dependency-map.md.quarantine-" + ("a" * 32)
collision = summary / collision_name
collision.write_text("collision sentinel\n", encoding="utf-8")
tokens = iter(["a" * 32, "b" * 32])
original_token_hex = module.secrets.token_hex
module.secrets.token_hex = lambda _size: next(tokens)
try:
    state = module._unlink_owned_staging(
        dir_fd, name, allocation_inode, "dependency-map.md"
    )
finally:
    module.secrets.token_hex = original_token_hex
    os.close(dir_fd)
if state != "removed" or collision.read_text(encoding="utf-8") != "collision sentinel\n":
    raise AssertionError("quarantine collision overwrote unrelated data")
if (summary / name).exists() or (summary / (".dependency-map.md.quarantine-" + "b" * 32)).exists():
    raise AssertionError("owned or quarantine entry leaked after collision retry")
PY
  then
    printf '%s\n' '  PASS F5b0i4 atomic quarantine preserves boundary swaps and collision sentinels'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0i4 cleanup has a public-name assessment/unlink TOCTOU'
    FAIL=$((FAIL + 1))
  fi

  SECURITY_PREWRITE_DIR="$TMP_ROOT/security planning prewrite"
  mkdir -p "$SECURITY_PREWRITE_DIR"
  security_output="$SECURITY_PREWRITE_DIR/planning-security.md"
  if output=$(validate_prewrite "$SECURITY_PREWRITE_DIR" "$security_output" planning-security.md); then
    assert_json_valid 'F5b0j planning-security accepts its exact absent output path' "$output" "$security_output"
  else
    printf '  FAIL F5b0j planning-security rejected valid output: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi

  EXISTING_PREWRITE_DIR="$TMP_ROOT/existing prewrite"
  mkdir -p "$EXISTING_PREWRITE_DIR"
  printf 'existing\n' > "$EXISTING_PREWRITE_DIR/dependency-map.md"
  if output=$(validate_prewrite "$EXISTING_PREWRITE_DIR" "$EXISTING_PREWRITE_DIR/dependency-map.md" dependency-map.md); then
    assert_json_valid 'F5b0k prewrite accepts a safe existing regular target' "$output" "$EXISTING_PREWRITE_DIR/dependency-map.md"
  else
    printf '  FAIL F5b0k prewrite rejected safe existing target: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi

  INRUN_LINK_DIR="$TMP_ROOT/in-run symlink"
  mkdir -p "$INRUN_LINK_DIR"
  printf 'target\n' > "$INRUN_LINK_DIR/actual.md"
  ln -s "$INRUN_LINK_DIR/actual.md" "$INRUN_LINK_DIR/dependency-map.md"
  if output=$(validate_prewrite "$INRUN_LINK_DIR" "$INRUN_LINK_DIR/dependency-map.md" dependency-map.md); then
    printf '%s\n' '  FAIL F5b0l prewrite accepted an in-run output symlink'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b0l prewrite rejects output symlinks even when their target is in-run' "$output" output_path run_dir_confinement
  fi

  HARDLINK_PREFLIGHT_DIR="$TMP_ROOT/hard-link preflight"
  mkdir -p "$HARDLINK_PREFLIGHT_DIR"
  printf 'external-sentinel\n' > "$TMP_ROOT/hard-link-external.md"
  ln "$TMP_ROOT/hard-link-external.md" "$HARDLINK_PREFLIGHT_DIR/dependency-map.md"
  if output=$(validate_prewrite "$HARDLINK_PREFLIGHT_DIR" "$HARDLINK_PREFLIGHT_DIR/dependency-map.md" dependency-map.md); then
    printf '%s\n' '  FAIL F5b0l1 prewrite accepted a hard-link alias'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b0l1 prewrite rejects hard-link aliases' "$output" output_path hardlink_alias
  fi

  HARDLINK_DIR="$TMP_ROOT/hard-link swap sentinel"
  mkdir -p "$HARDLINK_DIR"
  hardlink_target="$HARDLINK_DIR/planning-security.md"
  if ! validate_prewrite "$HARDLINK_DIR" "$hardlink_target" planning-security.md >/dev/null; then
    printf '%s\n' '  FAIL F5b0l2 absent target failed preflight before swap fixture'
    FAIL=$((FAIL + 1))
  elif ! allocation=$(allocate_staging "$HARDLINK_DIR" planning-security.md planning_security_path); then
    printf '%s\n' '  FAIL F5b0l2 shim failed to allocate private staging file'
    FAIL=$((FAIL + 1))
  elif ! staging_path=$(json_value "$allocation" staging_path); then
    printf '%s\n' '  FAIL F5b0l2 allocation did not return strict JSON staging_path'
    FAIL=$((FAIL + 1))
  elif ! allocation_token=$(json_value "$allocation" allocation_token); then
    printf '%s\n' '  FAIL F5b0l2 allocation did not return allocation capability'
    FAIL=$((FAIL + 1))
  else
    printf 'new-planning-security\n' > "$staging_path"
    printf 'phase-one-security-sentinel\n' > "$HARDLINK_DIR/security.md"
    ln "$HARDLINK_DIR/security.md" "$hardlink_target"
    if output=$(publish_staging "$HARDLINK_DIR" "$hardlink_target" planning-security.md "$staging_path" "$allocation_token" planning_security_path); then
      status=$(json_value "$output" status 2>/dev/null || true)
      assert_eq 'F5b0l2 publish atomically replaces a hard-link swap target' published "$status"
    else
      printf '  FAIL F5b0l2 publish rejected safe atomic replacement: %s\n' "$output"
      FAIL=$((FAIL + 1))
    fi
    sentinel=$(<"$HARDLINK_DIR/security.md")
    assert_eq 'F5b0l3 between-preflight hard-link swap leaves external inode unchanged' \
      'phase-one-security-sentinel' "$sentinel"
    target_content=$(<"$hardlink_target")
    assert_eq 'F5b0l4 atomically replaced target contains staged content' \
      'new-planning-security' "$target_content"
    if python3 - "$HARDLINK_DIR/security.md" "$hardlink_target" "$staging_path" <<'PY'
import os
import sys

external, target, staging = sys.argv[1:]
if os.path.exists(staging):
    raise SystemExit("staging file was not removed")
if os.stat(external).st_ino == os.stat(target).st_ino:
    raise SystemExit("target still aliases external inode")
if os.stat(target).st_nlink != 1:
    raise SystemExit("published target is not single-link")
PY
    then
      printf '%s\n' '  PASS F5b0l5 publish removes staging and leaves a private target inode'
      PASS=$((PASS + 1))
    else
      printf '%s\n' '  FAIL F5b0l5 publish cleanup/private-inode invariant failed'
      FAIL=$((FAIL + 1))
    fi
  fi

  if output=$(validate_prewrite relative-summary "$EXISTING_PREWRITE_DIR/dependency-map.md" dependency-map.md); then
    printf '%s\n' '  FAIL F5b0m prewrite accepted a relative summary dir'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b0m prewrite rejects a relative summary dir' "$output" output_path absolute
  fi

  if output=$(validate_prewrite "$TMP_ROOT/missing-summary" "$TMP_ROOT/missing-summary/dependency-map.md" dependency-map.md); then
    printf '%s\n' '  FAIL F5b0n prewrite accepted a missing summary dir'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b0n prewrite rejects a missing summary dir' "$output" output_path canonicalize
  fi

  DIRECTORY_PREWRITE_DIR="$TMP_ROOT/directory prewrite"
  mkdir -p "$DIRECTORY_PREWRITE_DIR/dependency-map.md"
  if output=$(validate_prewrite "$DIRECTORY_PREWRITE_DIR" "$DIRECTORY_PREWRITE_DIR/dependency-map.md" dependency-map.md); then
    printf '%s\n' '  FAIL F5b0o prewrite accepted a directory output target'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b0o prewrite rejects an existing non-file target' "$output" output_path output_type
  fi

  output=$(validate_postwrite "$EXISTING_PREWRITE_DIR" dependency-map.md dependency-map.md probe_key 2>/dev/null || true)
  assert_json_invalid 'F5b0p invalid output uses the complete stable machine contract' "$output" probe_key absolute

  if python3 - "$PLANNING_OUTPUT_SHIM" "$TMP_ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

shim, raw_root = sys.argv[1:]
summary = Path(raw_root) / "json path with space # colon:\nand newline"
summary.mkdir()
output = summary / "dependency-map.md"
result = subprocess.run(
    [
        shim,
        "--operation", "validate",
        "--mode", "prewrite",
        "--summary-dir", str(summary),
        "--output-path", str(output),
        "--expected-basename", "dependency-map.md",
    ],
    check=False,
    capture_output=True,
    text=True,
)
if result.returncode != 0 or result.stderr:
    raise SystemExit(f"validate failed: rc={result.returncode} stderr={result.stderr!r}")
if len(result.stdout.splitlines()) != 1:
    raise SystemExit(f"machine result is not compact single-line JSON: {result.stdout!r}")
payload = json.loads(result.stdout)
if payload != {"status": "valid", "output_path": str(output)}:
    raise SystemExit(f"path did not roundtrip exactly: {payload!r}")

allocated = subprocess.run(
    [
        shim,
        "--operation", "allocate",
        "--summary-dir", str(summary),
        "--expected-basename", output.name,
        "--key", "dependency_map_path",
    ],
    check=False,
    capture_output=True,
    text=True,
)
if allocated.returncode != 0 or allocated.stderr or len(allocated.stdout.splitlines()) != 1:
    raise SystemExit(f"allocate failed strict JSON contract: {allocated!r}")
allocation = json.loads(allocated.stdout)
staging = Path(allocation["staging_path"])
allocation_token = allocation["allocation_token"]
if allocation.get("status") != "allocated" or staging.parent.resolve() != summary.resolve():
    raise SystemExit(f"allocation path did not roundtrip in-run: {allocation!r}")
staging.write_text("dynamic path publication\n", encoding="utf-8")

published = subprocess.run(
    [
        shim,
        "--operation", "publish",
        "--summary-dir", str(summary),
        "--output-path", str(output),
        "--expected-basename", output.name,
        "--staging-path", str(staging),
        "--allocation-token", allocation_token,
        "--key", "dependency_map_path",
    ],
    check=False,
    capture_output=True,
    text=True,
)
if published.returncode != 0 or published.stderr or len(published.stdout.splitlines()) != 1:
    raise SystemExit(f"publish failed strict JSON contract: {published!r}")
if json.loads(published.stdout) != {
    "output_path": str(output), "staging_path": "", "status": "published"
}:
    raise SystemExit(f"publish path did not roundtrip exactly: {published.stdout!r}")
if output.read_text(encoding="utf-8") != "dynamic path publication\n" or staging.exists():
    raise SystemExit("dynamic path publication content/cleanup mismatch")
PY
  then
    printf '%s\n' '  PASS F5b0r compact JSON roundtrips space/#/colon/newline paths exactly'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0r dynamic output path is not strict compact JSON'
    FAIL=$((FAIL + 1))
  fi

  if python3 - "$PLANNING_OUTPUT_SHIM" <<'PY'
import json
import subprocess
import sys

result = subprocess.run(
    [sys.argv[1], "--operation", "validate"],
    check=False,
    capture_output=True,
    text=True,
)
payload = json.loads(result.stdout)
if result.returncode == 0 or result.stderr:
    raise SystemExit("invalid CLI invocation did not fail cleanly on stdout")
if payload.get("status") != "invalid" or payload.get("reason") != "arguments":
    raise SystemExit(f"unexpected argument error payload: {payload!r}")
PY
  then
    printf '%s\n' '  PASS F5b0s CLI argument errors are strict compact JSON'
    PASS=$((PASS + 1))
  else
    printf '%s\n' '  FAIL F5b0s CLI argument errors are not strict compact JSON'
    FAIL=$((FAIL + 1))
  fi

  printf 'security planning\n' > "$security_output"
  if output=$(validate_postwrite "$SECURITY_PREWRITE_DIR" "$security_output" planning-security.md planning_security_path); then
    assert_json_valid 'F5b0q postwrite accepts the distinct planning-security artifact' "$output" "$security_output"
  else
    printf '  FAIL F5b0q postwrite rejected valid planning-security artifact: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi

  VALID_DIR="$TMP_ROOT/valid run with spaces"
  mkdir -p "$VALID_DIR"
  for filename in dependency-map.md test-map.md implementation-risk.md; do
    printf 'fixture: %s\n' "$filename" > "$VALID_DIR/$filename"
  done
  if output=$(validate_three_postwrite \
      "$VALID_DIR" \
      "$VALID_DIR/dependency-map.md" \
      "$VALID_DIR/test-map.md" \
      "$VALID_DIR/implementation-risk.md"); then
    n=$(printf '%s\n' "$output" | grep -cF 'status: valid' || true)
    assert_eq 'F5b1 valid exact in-run files pass' 1 "$n"
  else
    printf '  FAIL F5b1 valid exact in-run files rejected: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi

  PORTABLE_PATH_BIN="$TMP_ROOT/portable-path"
  mkdir -p "$PORTABLE_PATH_BIN"
  PYTHON3_BIN=$(command -v python3)
  ln -s "$PYTHON3_BIN" "$PORTABLE_PATH_BIN/python3"
  if output=$(PATH="$PORTABLE_PATH_BIN" validate_three_postwrite \
      "$VALID_DIR" \
      "$VALID_DIR/dependency-map.md" \
      "$VALID_DIR/test-map.md" \
      "$VALID_DIR/implementation-risk.md"); then
    n=$(printf '%s\n' "$output" | grep -cF 'status: valid' || true)
    assert_eq 'F5b1b stdlib shim works with PATH containing only python3' 1 "$n"
  else
    printf '  FAIL F5b1b stdlib shim failed under portable PATH: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi

  if output=$(validate_three_postwrite \
      "$VALID_DIR" \
      'dependency-map.md' \
      "$VALID_DIR/test-map.md" \
      "$VALID_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b2 relative artifact path accepted'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b2 relative artifact path rejected for exact key' "$output" dependency_map_path absolute
  fi

  MISSING_DIR="$TMP_ROOT/missing"
  mkdir -p "$MISSING_DIR"
  printf 'fixture\n' > "$MISSING_DIR/test-map.md"
  printf 'fixture\n' > "$MISSING_DIR/implementation-risk.md"
  if output=$(validate_three_postwrite \
      "$MISSING_DIR" \
      "$MISSING_DIR/dependency-map.md" \
      "$MISSING_DIR/test-map.md" \
      "$MISSING_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b3 missing artifact path accepted'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b3 missing artifact is rejected' "$output" dependency_map_path missing
  fi

  DIRECTORY_DIR="$TMP_ROOT/directory"
  mkdir -p "$DIRECTORY_DIR/dependency-map.md"
  printf 'fixture\n' > "$DIRECTORY_DIR/test-map.md"
  printf 'fixture\n' > "$DIRECTORY_DIR/implementation-risk.md"
  if output=$(validate_three_postwrite \
      "$DIRECTORY_DIR" \
      "$DIRECTORY_DIR/dependency-map.md" \
      "$DIRECTORY_DIR/test-map.md" \
      "$DIRECTORY_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b4 directory artifact accepted as a file'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b4 directory artifact rejected' "$output" dependency_map_path output_type
  fi

  BROKEN_DIR="$TMP_ROOT/broken"
  mkdir -p "$BROKEN_DIR"
  ln -s "$BROKEN_DIR/does-not-exist" "$BROKEN_DIR/dependency-map.md"
  printf 'fixture\n' > "$BROKEN_DIR/test-map.md"
  printf 'fixture\n' > "$BROKEN_DIR/implementation-risk.md"
  if output=$(validate_three_postwrite \
      "$BROKEN_DIR" \
      "$BROKEN_DIR/dependency-map.md" \
      "$BROKEN_DIR/test-map.md" \
      "$BROKEN_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b5 broken symlink canonicalization failure accepted'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b5 broken symlink rejected' "$output" dependency_map_path run_dir_confinement
  fi

  ESCAPE_DIR="$TMP_ROOT/escape"
  mkdir -p "$ESCAPE_DIR"
  printf 'outside\n' > "$TMP_ROOT/outside-dependency-map.md"
  ln -s "$TMP_ROOT/outside-dependency-map.md" "$ESCAPE_DIR/dependency-map.md"
  printf 'fixture\n' > "$ESCAPE_DIR/test-map.md"
  printf 'fixture\n' > "$ESCAPE_DIR/implementation-risk.md"
  if output=$(validate_three_postwrite \
      "$ESCAPE_DIR" \
      "$ESCAPE_DIR/dependency-map.md" \
      "$ESCAPE_DIR/test-map.md" \
      "$ESCAPE_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b6 escaping symlink accepted'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b6 escaping symlink rejected' "$output" dependency_map_path run_dir_confinement
  fi

  UNREADABLE_DIR="$TMP_ROOT/unreadable"
  mkdir -p "$UNREADABLE_DIR"
  printf 'fixture\n' > "$UNREADABLE_DIR/dependency-map.md"
  printf 'fixture\n' > "$UNREADABLE_DIR/test-map.md"
  printf 'fixture\n' > "$UNREADABLE_DIR/implementation-risk.md"
  chmod 000 "$UNREADABLE_DIR/dependency-map.md"
  if output=$(validate_three_postwrite \
      "$UNREADABLE_DIR" \
      "$UNREADABLE_DIR/dependency-map.md" \
      "$UNREADABLE_DIR/test-map.md" \
      "$UNREADABLE_DIR/implementation-risk.md"); then
    printf '%s\n' '  FAIL F5b7 unreadable regular file accepted'
    FAIL=$((FAIL + 1))
  else
    assert_json_invalid 'F5b7 unreadable regular file rejected independent of root/admin access' "$output" dependency_map_path unreadable
  fi
  chmod 600 "$UNREADABLE_DIR/dependency-map.md"
else
  printf '%s\n' '  FAIL F5b0 production planning-output shim missing or not executable'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== F6 invalid research blocks without delegation =='
n=$(printf '%s\n' "$validation_body" | grep -ciE 'missing.*unreadable.*outside|missing, unreadable, not a regular file, or outside' || true)
assert_ge 'F6a missing/unreadable/out-of-run-dir inputs share the blocking path' 1 "$n"
n=$(printf '%s\n' "$validation_body" | grep -cE '^[[:space:]]*status: BLOCKED[[:space:]]*$' || true)
assert_ge 'F6b invalid input emits structured status: BLOCKED' 1 "$n"
n=$(printf '%s\n' "$validation_body" | grep -ciE 'do not write (a|the) plan|without writing (a|the) plan' || true)
assert_ge 'F6c invalid input stops before plan generation' 1 "$n"

n=$(printf '%s\n' "$phase4_body" | grep -ciE 're-dispatch only.*canonical.*once|exactly one targeted retry' || true)
assert_ge 'F6d only the failed canonical role retries once' 1 "$n"
n=$(printf '%s\n' "$phase4_body" | grep -ciE 'BLOCKED.*do not dispatch `plan-writer`|do not dispatch `plan-writer`.*terminal' || true)
assert_ge 'F6e failed required planning evidence blocks plan-writer dispatch' 1 "$n"
n=$(printf '%s\n' "$phase45_body" | grep -ciE 'unchanged three-path `planning_research`|no planning-research child is re-run' || true)
assert_ge 'F6f revision reuses three artifacts without research rerun' 1 "$n"

contradiction_hits=$(printf '%s\n%s\n' "$phase4_body" "$phase45_body" | grep -niE \
  'plan-writer (internally )?(dispatches|spawns)|retry (all|every) planning|re-?run (the )?planning-research (children|fanout)|infer risk from issue' \
  | grep -viE 'do not (reclassify or )?infer risk from issue' || true)
if [[ -n "$contradiction_hits" ]]; then
  printf '%s\n' '  FAIL F6m contradictory delegation/retry/revision prose remains:'
  printf '%s\n' "$contradiction_hits"
  FAIL=$((FAIL + 1))
else
  printf '%s\n' '  PASS F6m no contradictory delegation/retry/revision prose'
  PASS=$((PASS + 1))
fi

printf '%s\n' '== F7 preserved surrounding contracts =='
n=$(grep -cF 'FANOUT_RESEARCH_CAP' "$ORCHESTRATOR" || true)
assert_ge 'F7a existing Phase 1 fanout cap remains' 1 "$n"
n=$(grep -cF '### Phase 4.5: plan-reviewer' "$ORCHESTRATOR" || true)
assert_eq 'F7b Phase 4.5 plan-review gate remains' 1 "$n"
n=$(grep -cF 'docs/uberdev/plans/YYYY-MM-DD-<topic_slug>.md' "$PLAN_WRITER" || true)
assert_ge 'F7c plan artifact generation path remains' 1 "$n"
n=$(grep -cF 'artifact_path: <working_dir>/docs/uberdev/plans/YYYY-MM-DD-<topic_slug>.md' "$PLAN_WRITER" || true)
assert_eq 'F7d plan-writer returns the absolute artifact path required by Phase 4' 1 "$n"

printf '%s\n' '== F8 quoted artifact verification and tier-table consistency =='
if python3 - "$ORCHESTRATOR" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    '[ -f "$artifact_path" ]',
    'wc -c < "$artifact_path"',
    'grep -E -- "^## (Goal|Architecture|Components)" "$artifact_path"',
    'grep -E -- "^## Execution Waves" "$artifact_path"',
)
for marker in required:
    if marker not in text:
        raise SystemExit(f"missing quoted verification: {marker}")
for lineno, line in enumerate(text.splitlines(), 1):
    if "$artifact_path" in line and re.search(r'(?<!")\$artifact_path|\$artifact_path(?!")', line):
        raise SystemExit(f"line {lineno}: unquoted artifact_path: {line}")
PY
then
  printf '%s\n' '  PASS F8 all required artifact verification is quoted and uses grep --'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F8 artifact verification quoting/grep contract failed'
  FAIL=$((FAIL + 1))
fi
n=$(grep -cE '^\| small \|.*\| N/A \(orchestrator bypassed\) \|' "$ORCHESTRATOR" || true)
assert_eq 'F8 small-tier planning research is N/A because small bypasses orchestrator' 1 "$n"

printf '%s\n' '== F9 routed helper, retry identity, cleanup, and lineage contracts =='
if python3 - "$ORCHESTRATOR" "$BRAINSTORM" "$WRITE_PLAN" "$PLAN_WRITER" "$RUN_TREE" <<'PY'
import json
import re
import sys
from pathlib import Path

orchestrator, brainstorm, write_plan, plan_writer = (
    Path(path).read_text(encoding="utf-8") for path in sys.argv[1:5]
)
manifest=json.loads(Path(sys.argv[5]).read_text(encoding="utf-8"))

for name, text in (("orchestrator", orchestrator), ("brainstorm", brainstorm)):
    if 'uberdev_create_child_handoff "$edge" "$instance" "$inputs_json" "$risks_json"' not in text:
        raise SystemExit(f"{name}: missing runtime handoff helper")
    if 'if uberdev_create_child_handoff "$edge" "$instance" "$inputs_json" "$risks_json"; then' not in text:
        raise SystemExit(f"{name}: helper failure bypasses partial-fanout unwind")
    if 'UBERDEV_CHILD_HANDOFF' not in text or 'UBERDEV_CHILD_RESULT' not in text or 'UBERDEV_CHILD_STATUS' not in text:
        raise SystemExit(f"{name}: missing exported runtime paths")
    if 'uberdev_preflight_child_batch' not in text:
        raise SystemExit(f"{name}: batch preflight missing")
    if 'children/$instance/status.json' in text or 'children/$instance/result.md' in text:
        raise SystemExit(f"{name}: wait path is caller-computed instead of receipt-derived")
    if 'DISPATCH_RECEIPTS' not in text or 'uberdev_unwind_child_receipts' not in text:
        raise SystemExit(f"{name}: missing partial-fanout receipt unwind")
    # `child_status`, NOT `status`. The property being pinned is the BOUNDED
    # timeout — the third argument is a `"$`-prefixed variable, never a literal
    # 0 — and the variable's name is incidental to it. But the `status` spelling
    # is not merely a style choice: under /bin/zsh, which is how the harness runs
    # a command/skill `bash` fence on macOS, `status` is the read-only alias for
    # `$?`, so a local of that name kills the whole fence at its first
    # assignment. Accepting both spellings here would let the fatal one back in
    # behind a green test, so only the renamed form is pinned — matching
    # post-impl-review.test.sh and the tied-parameter scan in
    # tests/crossplatform-shell-wrappers.test.sh, which now rejects it
    # structurally.
    if 'uberdev_unwind_child "$child_status" "$result" "$' not in text:
        raise SystemExit(f"{name}: bounded production unwind missing")
    if 'uberdev_wait_child "$child_status" "$result" 0' in text:
        raise SystemExit(f"{name}: infinite wait remains in unwind")
    if 'os.open(path' in text or 'handoff_dir="$run_dir/handoffs"' in text:
        raise SystemExit(f"{name}: caller-owned raw handoff writer remains")

required_instances = (
    "orchestrator-spec-write-a2",
    "orchestrator-spec-review-a2",
    "orchestrator-spec-revise-r1-a1",
    "orchestrator-spec-revise-r1-a2",
    "orchestrator-spec-review-r1-a1",
    "orchestrator-spec-review-r1-a2",
    "orchestrator-spec-revise-r2-a1",
    "orchestrator-spec-revise-r2-a2",
    "orchestrator-spec-review-r2-a1",
    "orchestrator-spec-review-r2-a2",
    "orchestrator-plan-write-a2",
    "orchestrator-plan-write-a3",
    "orchestrator-plan-review-a2",
    "orchestrator-plan-write-r1-a1",
    "orchestrator-plan-write-r1-a2",
    "orchestrator-plan-write-r1-a3",
    "orchestrator-plan-review-r1-a1",
    "orchestrator-plan-review-r1-a2",
)
for instance in required_instances:
    if instance not in orchestrator:
        raise SystemExit(f"orchestrator: missing fresh bounded retry instance {instance}")

if 'orchestrator-plan-write-a4' in orchestrator or 'orchestrator-plan-write-r1-a4' in orchestrator:
    raise SystemExit("plan verification exceeds intended two retries")

if 'brainstorm.research.prior_art brainstorm-research-prior-art-a1 research-patterns' not in brainstorm:
    raise SystemExit("brainstorm prior_art edge role mismatch")
if 'brainstorm.research.library brainstorm-research-library-a1 research-prior-art' not in brainstorm:
    raise SystemExit("brainstorm library edge role mismatch")

contracts={}
for name,text in (("orchestrator",orchestrator),("brainstorm",brainstorm)):
    match=re.search(r'<!-- BEGIN child-callsite-contracts-v1 -->\s*```json\s*(.*?)\s*```\s*<!-- END child-callsite-contracts-v1 -->',text,re.S)
    if not match: raise SystemExit(f"{name}: missing executable callsite contract fixture")
    contracts.update(json.loads(match.group(1)))
for edge,row in contracts.items():
    declared=manifest["edges"].get(edge)
    required_inputs=list(declared.get("required_inputs", {})) if declared else []
    if not declared or row["inputs"] != required_inputs or row["risk_scope"] != declared["risk_scope"]:
        raise SystemExit(f"{edge}: callsite contract diverges from manifest")
    expected_risk = None if declared["risk_scope"] == "run" else ([] if declared["risk_scope"] == "none" else "subtask")
    if row["risk_argument"] != expected_risk:
        raise SystemExit(f"{edge}: risk argument mismatch")
for forbidden in ('{"issue_body_path":','"qa_answers_path":','"summary_dir":','"validation_shim":','"topic_slug":'):
    if forbidden in orchestrator or forbidden in brainstorm:
        raise SystemExit(f"legacy payload key remains: {forbidden}")
if re.search(r'uberdev_design_dispatch .*\brun\b (?![\'\"]null[\'\"])',orchestrator):
    raise SystemExit("run-scope callsite does not pass literal null")

for name, text in (("canonical plan-writer", plan_writer),):
    for forbidden in ("Task tool", "Use the **Task**", "spawn_agent", "internal research subagents", "Internally dispatches"):
        if forbidden in text:
            raise SystemExit(f"{name}: delegation prose remains: {forbidden}")
    if "**Do not delegate.**" not in text:
        raise SystemExit(f"{name}: leaf prohibition missing")

markers = {
    "brainstorm.write_plan": brainstorm,
    "write_plan.sdd": write_plan,
    "orchestrator.brainstorm.qa": orchestrator,
    "orchestrator.sdd": orchestrator,
}
for edge, text in markers.items():
    marker = f"edge_id: {edge}\nmodel_invocation: false"
    if marker not in text:
        raise SystemExit(f"missing lineage marker: {edge}")
PY
then
  printf '%s\n' '  PASS F9 routed retries/fanout cleanup/role mappings/leaf/lineage are explicit'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F9 routed retry and transition contracts are incomplete'
  FAIL=$((FAIL + 1))
fi

# F9b IS RETIRED with the Codex orchestrator SKILL.md it scanned: it asserted the
# ported copy carried no Claude-only or bare-root path. Issue #381 deleted that
# copy, so there is no ported file left to be porter-unsafe.

if python3 - "$ORCHESTRATOR" "$BRAINSTORM" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

cases = (
    (Path(sys.argv[1]), "UBERDEV_DESIGN_DISPATCH_RECEIPTS"),
    (Path(sys.argv[2]), "UBERDEV_BRAINSTORM_DISPATCH_RECEIPTS"),
)
for path, ledger in cases:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"uberdev_unwind_child_receipts\(\) \{.*?\n\}", text, re.S)
    if not match:
        raise SystemExit(f"{path}: unwind function missing")
    reset = "uberdev_design_reset_batch" if "DESIGN" in ledger else "uberdev_brainstorm_reset_batch"
    statuses = ledger.replace("DISPATCH_RECEIPTS", "RECEIPT_STATUSES")
    results = ledger.replace("DISPATCH_RECEIPTS", "RECEIPT_RESULTS")
    script = f'''set -u
calls=()
uberdev_unwind_child() {{ calls+=("$1|$2|$3"); [ "${{#calls[@]}}" -ne 1 ]; }}
UBERDEV_DESIGN_UNWIND_TIMEOUT=600
UBERDEV_BRAINSTORM_UNWIND_TIMEOUT=300
{ledger}=(one two)
{statuses}=(/tmp/status-1 /tmp/status-2)
{results}=(/tmp/result-1 /tmp/result-2)
{reset}() {{ {ledger}=(); {statuses}=(); {results}=(); }}
{match.group(0)}
rc=0
uberdev_unwind_child_receipts || rc=$?
[ "$rc" -eq 1 ]
[ "${{#calls[@]}}" -eq 2 ]
[ "${{calls[0]}}" != "/tmp/status-1|/tmp/result-1|0" ]
[ "${{calls[1]}}" != "/tmp/status-2|/tmp/result-2|0" ]
[ "${{#{ledger}[@]}}" -eq 0 ]
[ "${{#{statuses}[@]}}" -eq 0 ]
[ "${{#{results}[@]}}" -eq 0 ]
'''
    completed = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
    if completed.returncode:
        raise SystemExit(f"{path}: partial fanout unwind failed: {completed.stderr}")
PY
then
  printf '%s\n' '  PASS F9c partial-fanout unwind drains every recorded receipt after an earlier wait error'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F9c partial-fanout unwind abandoned a recorded child'
  FAIL=$((FAIL + 1))
fi

if python3 - "$ORCHESTRATOR" "$BRAINSTORM" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

cases = (
    (
        Path(sys.argv[1]),
        "uberdev_design",
        "UBERDEV_DESIGN",
    ),
    (
        Path(sys.argv[2]),
        "uberdev_brainstorm",
        "UBERDEV_BRAINSTORM",
    ),
)

def function(text: str, name: str) -> str:
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{.*?^\}}$", text)
    if not match:
        raise SystemExit(f"missing production function: {name}")
    return match.group(0)

for path, prefix, ledger in cases:
    text = path.read_text(encoding="utf-8")
    # Name-agnostic on the status component, unlike the positive anchors above.
    # This one is a NEGATIVE assertion, so pinning a single spelling silently
    # retires it: once both files renamed the fatal `status` local to
    # `child_status`, the literal `"$instance|$status|$result"` became
    # unmatchable and a reintroduced delimiter-packed receipt spelled with
    # `$child_status` would have sailed past a green test. The property is the
    # PACKING, not the variable's name, so match either spelling.
    if re.search(r'"\$instance\|\$(?:child_)?status\|\$result"', text):
        raise SystemExit(f"{path}: delimiter-packed receipt remains")
    reset = function(text, f"{prefix}_reset_batch")
    drain = function(text, f"{prefix}_drain_after_wait_failure")
    wait = function(text, f"{prefix}_wait")
    script = f'''set -eu
wait_calls=()
unwind_calls=()
uberdev_wait_child() {{
  wait_calls+=("$1::$2::$3")
  [ "$1" != "/tmp/run|root/status|failed" ] || return 7
}}
uberdev_unwind_child() {{
  unwind_calls+=("$1::$2::$3")
  [ "$1" != "/tmp/run|root/status|cleanup-error" ] || return 9
}}
{ledger}_UNWIND_TIMEOUT=19
{ledger}_PREPARED_EDGES=(edge-one edge-two edge-three edge-four)
{ledger}_PREPARED_INSTANCES=(one two three four)
{ledger}_PREPARED_HANDOFFS=(h1 h2 h3 h4)
{ledger}_PREPARED_RESULTS=(r1 r2 r3 r4)
{ledger}_PREPARED_STATUSES=(s1 s2 s3 s4)
{ledger}_DISPATCH_RECEIPTS=(one two three four)
{ledger}_RECEIPT_STATUSES=("/tmp/run|root/status|ok" "/tmp/run|root/status|failed" "/tmp/run|root/status|cleanup-error" "/tmp/run|root/status|live")
{ledger}_RECEIPT_RESULTS=("/tmp/run|root/result|ok" "/tmp/run|root/result|failed" "/tmp/run|root/result|cleanup-error" "/tmp/run|root/result|live")
{ledger}_WAITED_INSTANCES=()
{ledger}_WAITED=0
{ledger}_BATCH_LAUNCHED=1
{reset}
{drain}
{wait}
{prefix}_wait one 23
rc=0
{prefix}_wait two 23 || rc=$?
[ "$rc" -eq 7 ]
[ "${{#wait_calls[@]}}" -eq 2 ]
[ "${{wait_calls[0]}}" = "/tmp/run|root/status|ok::/tmp/run|root/result|ok::23" ]
[ "${{wait_calls[1]}}" = "/tmp/run|root/status|failed::/tmp/run|root/result|failed::23" ]
[ "${{#unwind_calls[@]}}" -eq 3 ]
[ "${{unwind_calls[0]}}" = "/tmp/run|root/status|failed::/tmp/run|root/result|failed::19" ]
[ "${{unwind_calls[1]}}" = "/tmp/run|root/status|cleanup-error::/tmp/run|root/result|cleanup-error::19" ]
[ "${{unwind_calls[2]}}" = "/tmp/run|root/status|live::/tmp/run|root/result|live::19" ]
[ "${{#{ledger}_DISPATCH_RECEIPTS[@]}}" -eq 0 ]
[ "${{#{ledger}_RECEIPT_STATUSES[@]}}" -eq 0 ]
[ "${{#{ledger}_RECEIPT_RESULTS[@]}}" -eq 0 ]
[ "${{#{ledger}_WAITED_INSTANCES[@]}}" -eq 0 ]

# A caller-side identity miss after launch is also terminal for the batch. One
# receipt has already completed successfully; it must remain skipped while all
# other receipts are boundedly unwound and the original lookup rc=2 survives a
# cleanup error.
wait_calls=()
unwind_calls=()
{ledger}_PREPARED_EDGES=(edge-one edge-two edge-three)
{ledger}_PREPARED_INSTANCES=(one two three)
{ledger}_PREPARED_HANDOFFS=(h1 h2 h3)
{ledger}_PREPARED_RESULTS=(r1 r2 r3)
{ledger}_PREPARED_STATUSES=(s1 s2 s3)
{ledger}_DISPATCH_RECEIPTS=(one two three)
{ledger}_RECEIPT_STATUSES=("/tmp/run|root/status|ok" "/tmp/run|root/status|cleanup-error" "/tmp/run|root/status|live")
{ledger}_RECEIPT_RESULTS=("/tmp/run|root/result|ok" "/tmp/run|root/result|cleanup-error" "/tmp/run|root/result|live")
{ledger}_WAITED_INSTANCES=()
{ledger}_WAITED=0
{ledger}_BATCH_LAUNCHED=1
{prefix}_wait one 23
missing_rc=0
{prefix}_wait absent-from-receipts 23 || missing_rc=$?
[ "$missing_rc" -eq 2 ]
[ "${{#wait_calls[@]}}" -eq 1 ]
[ "${{#unwind_calls[@]}}" -eq 2 ]
[ "${{unwind_calls[0]}}" = "/tmp/run|root/status|cleanup-error::/tmp/run|root/result|cleanup-error::19" ]
[ "${{unwind_calls[1]}}" = "/tmp/run|root/status|live::/tmp/run|root/result|live::19" ]
[ "${{#{ledger}_DISPATCH_RECEIPTS[@]}}" -eq 0 ]
[ "${{#{ledger}_RECEIPT_STATUSES[@]}}" -eq 0 ]
[ "${{#{ledger}_RECEIPT_RESULTS[@]}}" -eq 0 ]
[ "${{#{ledger}_WAITED_INSTANCES[@]}}" -eq 0 ]
'''
    completed = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
    if completed.returncode:
        raise SystemExit(f"{path}: wait-failure drain contract failed: {completed.stderr}")
PY
then
  printf '%s\n' '  PASS F9d wait failure drains current and live sibling receipts, preserves paths, and resets state'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F9d wait failure abandoned siblings or corrupted structured receipts'
  FAIL=$((FAIL + 1))
fi

if python3 - "$BRAINSTORM" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

text=Path(sys.argv[1]).read_text(encoding="utf-8")
def function(name: str) -> str:
    match=re.search(rf"(?ms)^{re.escape(name)}\(\) \{{.*?^\}}$",text)
    if not match: raise SystemExit(f"missing production function: {name}")
    return match.group(0)
barrier_match=re.search(r"```bash uberdev-executable barrier=brainstorm\.research\n(.*?)```",text,re.S)
if not barrier_match: raise SystemExit("missing brainstorm research barrier")
barrier=barrier_match.group(1)
script=f'''set -eu
wait_calls=()
unwind_calls=()
uberdev_wait_child() {{ wait_calls+=("$1::$2::$3"); return 0; }}
uberdev_unwind_child() {{ unwind_calls+=("$1::$2::$3"); return 0; }}
UBERDEV_BRAINSTORM_UNWIND_TIMEOUT=19
UBERDEV_BRAINSTORM_PREPARED_EDGES=(edge-codebase edge-prior)
UBERDEV_BRAINSTORM_PREPARED_INSTANCES=(brainstorm-research-codebase-a1 brainstorm-research-prior-art-a1)
UBERDEV_BRAINSTORM_PREPARED_HANDOFFS=(h1 h2)
UBERDEV_BRAINSTORM_PREPARED_RESULTS=(r1 r2)
UBERDEV_BRAINSTORM_PREPARED_STATUSES=(s1 s2)
UBERDEV_BRAINSTORM_DISPATCH_RECEIPTS=(brainstorm-research-codebase-a1 brainstorm-research-prior-art-a1)
UBERDEV_BRAINSTORM_RECEIPT_STATUSES=(status-codebase status-prior)
UBERDEV_BRAINSTORM_RECEIPT_RESULTS=(result-codebase result-prior)
UBERDEV_BRAINSTORM_WAITED_INSTANCES=()
UBERDEV_BRAINSTORM_WAITED=0
UBERDEV_BRAINSTORM_BATCH_LAUNCHED=1
{function("uberdev_brainstorm_reset_batch")}
{function("uberdev_brainstorm_drain_after_wait_failure")}
{function("uberdev_brainstorm_wait")}
{barrier}
[ "${{#wait_calls[@]}}" -eq 2 ]
[ "${{#unwind_calls[@]}}" -eq 0 ]
[ "${{#UBERDEV_BRAINSTORM_DISPATCH_RECEIPTS[@]}}" -eq 0 ]
'''
completed=subprocess.run(["bash","-c",script],text=True,capture_output=True)
if completed.returncode:
    raise SystemExit(f"selected-subset brainstorm barrier failed: {completed.stderr}")
PY
then
  printf '%s\n' '  PASS F9e missing lookup drains safely and brainstorm waits only for selected receipts'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL F9e missing receipt lookup or selected-subset brainstorm barrier leaks a batch'
  FAIL=$((FAIL + 1))
fi

printf '%s\n' '== P-A the wave ownership label is ONE vocabulary across its consumers =='
# #509. SDD dispatches a wave's implementers in parallel into one shared
# worktree; what makes that safe is a strictly disjoint per-task file partition.
# The partition has a real producer — plan-writer's per-task ownership field —
# and a real reviewer (plan-reviewer Check 2). But `subagent-driven-dev` cited it
# under a DIFFERENT name, `Worktree-safe:`, which NO planner in this repo has
# ever emitted: the safety precondition was attributed to a declaration that does
# not exist. This row reconciles the producer's label against its consumers by
# EXTRACTING it, so the case is data agreement rather than a wording pin, and
# separately proves the dead citation is gone.
if python3 - "$PLAN_WRITER" \
  "$ROOT/plugins/uberdev/skills/subagent-driven-dev" \
  "$ROOT/plugins/uberdev/agents" <<'PY'
import re
import sys
from pathlib import Path

writer, sdd_dir, agents_dir = (Path(a) for a in sys.argv[1:4])

labels = sorted(set(re.findall(
    r"^\*\*(Owns \([^)\n]*\)):\*\*",
    writer.read_text(encoding="utf-8"), re.MULTILINE)))
if len(labels) != 1:
    raise SystemExit(
        "plan-writer.md emits %d ownership label(s), expected exactly 1: %r"
        % (len(labels), labels))
label = labels[0]

for consumer in (sdd_dir / "SKILL.md", sdd_dir / "spec-reviewer-prompt.md"):
    if not consumer.is_file():
        raise SystemExit("missing SDD consumer: %s" % consumer)
    if label not in consumer.read_text(encoding="utf-8"):
        raise SystemExit("%s does not name the producer's label %r"
                         % (consumer.name, label))

dangling = []
for root in (sdd_dir, agents_dir):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if "Worktree-safe" in text:
            dangling.append(str(path))
if dangling:
    raise SystemExit("`Worktree-safe` has no producer but is still cited by: %s"
                     % dangling)
PY
then
  printf '%s\n' '  PASS P-A plan-writer, subagent-driven-dev and spec-reviewer-prompt name one ownership label, and no producerless Worktree-safe citation survives'
  PASS=$((PASS + 1))
else
  printf '%s\n' '  FAIL P-A the wave ownership contract is spelled inconsistently, or a producerless Worktree-safe citation survives'
  FAIL=$((FAIL + 1))
fi

printf '\n[orchestrator-plan-flatten] PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
