#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
POST="${REVIEW_POST_UNDER_TEST:-$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md}"
REVIEW="${REVIEW_PR_UNDER_TEST:-$ROOT/plugins/uberdev/commands/review-pr.md}"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
CANONICAL_POST_SOURCE='plugins/uberdev/skills/post-impl-review/SKILL.md'
CANONICAL_REVIEW_SOURCE='plugins/uberdev/commands/review-pr.md'
RUN_ID=''
TMP=''

cleanup() {
  local tmp="${TMP:-}" run_id="${RUN_ID:-}"
  TMP=''
  RUN_ID=''

  if [ -n "$tmp" ]; then
    case "$tmp" in
      "$ROOT/tests/_fixtures/review-child-inputs."??????)
        rm -rf -- "$tmp"
        ;;
    esac
  fi
  if [ -n "$run_id" ] && [[ "$run_id" =~ ^20260711-000000-[0-9a-f]{12}$ ]]; then
    rm -rf -- "$ROOT/.uberdev/research/$run_id"
  fi
}

TMP="$(mktemp -d "$ROOT/tests/_fixtures/review-child-inputs.XXXXXX")"
trap cleanup EXIT
RUN_SUFFIX="$(python3 -I -B -c 'import secrets; print(secrets.token_hex(6),end="")')"
RUN_ID="20260711-000000-$RUN_SUFFIX"

review_source_label() {
  python3 -I -B - "$ROOT" "$1" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
source = os.path.realpath(sys.argv[2])
try:
    if os.path.commonpath((root, source)) != root:
        raise ValueError()
except ValueError:
    raise SystemExit("source-under-test is outside repository")
print(os.path.relpath(source, root).replace(os.sep, "/"), end="")
PY
}

review_require_canonical_source() {
  local actual="$1" expected="$2" label
  label="$(review_source_label "$actual")" || return 1
  [ "$label" = "$expected" ]
}

POST_SOURCE="$(review_source_label "$POST")"
REVIEW_SOURCE="$(review_source_label "$REVIEW")"
review_require_canonical_source "$POST" "$CANONICAL_POST_SOURCE" || {
  echo "review-child-inputs: post source-under-test is not canonical: $POST_SOURCE" >&2
  exit 1
}
review_require_canonical_source "$REVIEW" "$CANONICAL_REVIEW_SOURCE" || {
  echo "review-child-inputs: review source-under-test is not canonical: $REVIEW_SOURCE" >&2
  exit 1
}

RECEIPT_DIR="$TMP/receipts"
RECEIPTS="$RECEIPT_DIR/review.jsonl"
PROVIDER_CALLS="$TMP/provider-calls"
mkdir -p "$RECEIPT_DIR"
chmod 700 "$RECEIPT_DIR"
: >"$RECEIPTS"
: >"$PROVIDER_CALLS"
chmod 600 "$RECEIPTS" "$PROVIDER_CALLS"
export UBERDEV_CHILD_TEST_MODE=1
export UBERDEV_CHILD_TEST_SOURCE="$REVIEW_SOURCE"
export UBERDEV_CHILD_TEST_RECEIPT_FILE="$RECEIPTS"

# Extract executable production definitions and callsites. The test never
# reconstructs a child input object or calls a builder on behalf of production.
python3 -I -B - "$POST" "$REVIEW" "$TMP" <<'PY'
import re
import sys
from pathlib import Path

post_path, review_path, out_dir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
post = post_path.read_text(encoding="utf-8")
review = review_path.read_text(encoding="utf-8")
fence = re.escape(chr(96) * 3)

def bash_fences(text):
    return [
        ((match.group(1) or "").strip(), match.group(2))
        for match in re.finditer(
            rf"^[ \t]*{fence}bash(?: ([^\n]*))?\n(.*?)\n[ \t]*{fence}$",
            text,
            re.MULTILINE | re.DOTALL,
        )
    ]

def executable(text, header):
    expected = "uberdev-executable" + (f" {header}" if header else "")
    found = [body for metadata, body in bash_fences(text) if metadata == expected]
    if len(found) != 1:
        raise SystemExit(f"expected one executable fence {expected!r}, found {len(found)}")
    return found[0]

def containing(text, token):
    found = [body for _metadata, body in bash_fences(text) if token in body]
    if len(found) != 1:
        raise SystemExit(f"expected one bash fence containing {token!r}, found {len(found)}")
    return found[0]

def function_definition(text, name):
    block = containing(text, f"{name}()")
    pattern = re.compile(
        rf"^(?P<indent>[ \t]*){re.escape(name)}\(\)[ \t]*\{{[ \t]*\n"
        rf"(?:(?P=indent)(?:[ \t]+.*)?\n)*"
        rf"(?P=indent)\}}[ \t]*$",
        re.MULTILINE,
    )
    found = [match.group(0) for match in pattern.finditer(block)]
    if len(found) != 1:
        raise SystemExit(
            f"expected one executable function definition {name!r}, found {len(found)}"
        )
    return found[0]

def write(name, body):
    path = out_dir / name
    path.write_text(body.rstrip() + "\n", encoding="utf-8")

post_setup = executable(post, "setup=post-impl-review")
marker = "REVIEW_EDGES=("
if post_setup.count(marker) != 1:
    raise SystemExit("post-review executable roster split marker drifted")
prefix, roster = post_setup.split(marker, 1)
write("post-prefix.sh", prefix)
write("post-roster.sh", marker + roster)
write("post-retry.sh", executable(post, ""))
write("review-setup.sh", executable(review, "setup=review-pr"))
write(
    "review-head-assert.sh",
    function_definition(review, "review_assert_selected_pr_head"),
)
write("review-scope.sh", containing(review, "review_refresh_phase1_scope() {"))

review_instance_lines = [
    line for line in review.splitlines()
    if 'review-pr-${RUN_ID}' in line
]
if not review_instance_lines or any(
    'uberdev_child_instance_id' not in line for line in review_instance_lines
):
    raise SystemExit("every review child instance must use the shared bounded helper")
post_instance_lines = [
    line for line in post.splitlines()
    if 'post-review-${RUN_ID}' in line
]
if not post_instance_lines or any(
    'uberdev_child_instance_id' not in line for line in post_instance_lines
):
    raise SystemExit("every post-review child instance must use the shared bounded helper")

builder_region = re.search(
    r"<!-- BEGIN review-child-builder-v1 -->\s*(.*?)\s*<!-- END review-child-builder-v1 -->",
    review,
    re.DOTALL,
)
if builder_region is None:
    raise SystemExit("review child builder marker block missing")
builder_fences = bash_fences(builder_region.group(1))
if len(builder_fences) != 1:
    raise SystemExit("review child builder must contain one canonical bash fence")
write("review-builder.sh", builder_fences[0][1])

def assignment(block, variable):
    lines = block.splitlines()
    starts = [
        index for index, line in enumerate(lines)
        if line.strip().startswith(f'{variable}="$(uberdev_child_inputs_build ')
    ]
    if len(starts) != 1:
        raise SystemExit(f"{variable} constructor occurrence drifted")
    selected = []
    for line in lines[starts[0]:]:
        stripped = line.strip()
        if stripped.endswith(')"'):
            selected.append(stripped)
            break
        # #383: the builders now carry an `|| { audit ...; exit 1; }` failure arm
        # on the terminating line. Take the constructor and drop the arm -- this
        # fixture exists to prove the PAYLOAD, and the failure arm is asserted
        # where it belongs, in tests/review-pr-phase3-ci.test.sh. Anchored on the
        # arm, never on a bare `)"`, because every interior line of a builder
        # ends with `)" \` too.
        armed = re.match(r'^(.*\)")\s*\|\|\s*(?:\{.*\}|return [0-9]+|exit [0-9]+)$', stripped)
        if armed is not None:
            selected.append(armed.group(1))
            break
        selected.append(stripped)
    else:
        raise SystemExit(f"{variable} constructor terminator missing")
    return "\n".join(selected)

write("review-phase1.sh", containing(review, 'PHASE1_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase1'))
write("review-simplify.sh", containing(review, 'SIMPLIFY_RECORDS="$RESEARCH_DIR_ABS/simplify.records"'))
write("review-phase2.sh", containing(review, 'PHASE2_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase2'))
write("review-defer.sh", containing(review, 'DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.defer.findings'))
write("review-classify.sh", containing(review, 'CI_CLASSIFY_INPUTS="$(uberdev_child_inputs_build review_pr.ci.classify'))
write("review-defer-refusal.sh", containing(review, 'CI_DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.ci.defer_refusal'))
conflict_fence = containing(review, 'CONFLICT_INPUTS="$(uberdev_child_inputs_build review_pr.ci.resolve_conflict')
write("review-conflict.sh", assignment(conflict_fence, "CONFLICT_INPUTS"))

route = containing(review, 'CI_FIX_INPUTS="$(uberdev_child_inputs_build review_pr.ci.fix_code')

# RE-POINTED (#383). The ROUTE arms used to be `review_child_single
# review_pr.ci.fix_code ...` / `... .rebase ...`; Phase 3 now dispatches through
# skills/review-fleet/workflow.js, so the arms SELECT an edge and the Workflow
# stage carries it. The arms are still asserted -- a route that stopped naming
# its edge would be exactly as broken as one that stopped dispatching -- but
# against what the file now says.
fix_arm = re.search(
    r"^\s*code_bug \| env_drift\)\s*\n\s*CI_FIXER_EDGE_ID=review_pr\.ci\.fix_code$",
    route,
    re.MULTILINE,
)
rebase_arm = re.search(
    r"^\s*stale_base\)\s*\n\s*CI_FIXER_EDGE_ID=review_pr\.ci\.rebase$",
    route,
    re.MULTILINE,
)
if fix_arm is None or rebase_arm is None:
    raise SystemExit("review CI route arms drifted")
write(
    "review-ci-builders.sh",
    assignment(route, "CI_FIX_INPUTS") + "\n" + assignment(route, "CI_REBASE_INPUTS"),
)
PY

for extracted in "$TMP"/*.sh; do
  bash -n "$extracted"
done

# Build one real immutable review-pr carrier. The command setup extracted below
# then allocates its canonical workspace and the post-review child setup reuses
# that exact parent descriptor.
. "$LIB"
CARRIER_RUN="$TMP/runtime"
ROOT_REQUEST_JSON="$(python3 -I -B - "$CARRIER_RUN" "$ROOT" <<'PY'
import json
import sys

run, repository = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "run_dir": run,
    "run_id": "review-receipt-root",
    "repository_id": repository,
    "backend": "workflow",
    "workflow": "review-pr",
    "phase": "lead",
    "role": "lead",
    "task_tier": "medium",
    "risk_signals": ["security"],
    "issue_or_pr": 73,
    "issue_num": 73,
    "capacity": 20,
    "timeout_s": 20,
}, sort_keys=True, separators=(",", ":")))
PY
)"
mkdir -p "$CARRIER_RUN"
ROOT_DECISION_JSON="$(uberdev_agent_resolve_request "$ROOT_REQUEST_JSON")"
ROOT_METADATA_JSON="$(python3 -I -B - "$ROOT" <<'PY'
import json
import sys

print(json.dumps({
    "run_id": "review-receipt-root",
    "repository_id": sys.argv[1],
    "workflow": "review-pr",
    "backend": "workflow",
    "issue_num": 73,
    "task_tier": "medium",
    "risk_signals": ["security"],
}, sort_keys=True, separators=(",", ":")))
PY
)"
ROOT_CONTEXT_OUT="$(uberdev_agent_context_create "$CARRIER_RUN" "$ROOT_REQUEST_JSON" "$ROOT_DECISION_JSON" \
  '{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}' \
  "$ROOT_METADATA_JSON" '2026-07-11T00:00:00Z')"
ROOT_CONTEXT_FILE="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_file"],end="")' "$ROOT_CONTEXT_OUT")"
ROOT_CONTEXT_SHA="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["context_sha256"],end="")' "$ROOT_CONTEXT_OUT")"
UBERDEV_RUN_CARRIER_JSON="$(python3 -I -B - "$ROOT_CONTEXT_FILE" "$ROOT_CONTEXT_SHA" <<'PY'
import json
import sys

print(json.dumps({
    "schema_version": 1,
    "run_id": "review-receipt-root",
    "workflow": "review-pr",
    "issue_num": 73,
    "context_file": sys.argv[1],
    "context_sha256": sys.argv[2],
}, sort_keys=True, separators=(",", ":")))
PY
)"
export UBERDEV_RUN_CARRIER_JSON
export UBERDEV_AGENT_PREPARED_REQUEST_JSON="$ROOT_REQUEST_JSON"
export UBERDEV_AGENT_RISK_SIGNALS_JSON='["security"]'
export PLUGIN_ROOT="$ROOT/plugins/uberdev"
export PR_NUMBER=73
unset UBERDEV_COMMAND_WORKSPACE_JSON UBERDEV_CARRIER_RUN_DIR RESEARCH_DIR_ABS
unset DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH
unset PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH
export WORKTREE_ROOT="$ROOT"
export RUN_ID
export REVIEW_ITERATION=7
export REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT:-5}"
export CI_FIX_LOOP_ITER=3
export CI_RUN_ID=9001
export FOCUS=$'focus "quoted" \\glob*?[x]\t'

. "$TMP/review-setup.sh"
# #402 — the extracted setup fence runs the real uberdev_command_workspace_prepare,
# so it must leave AGG_PATH bound to the Phase 1 aggregate the command later hands
# to post_review_write_aggregate_v2. AGG_PATH is unset above, so a pass here cannot
# come from ambient state. Behavioural, not a grep: when CALLERS["review-pr"] had
# no "aggregate" artifact the prepare exported AGG_PATH="" and the Phase 1 fence
# returned 70 on every run.
[ -n "${AGG_PATH:-}" ] || { echo 'review-child-inputs: review setup left AGG_PATH unbound' >&2; exit 1; }
[ "$AGG_PATH" = "$RESEARCH_DIR_ABS/post-impl-review-final.md" ] \
  || { echo "review-child-inputs: review setup bound AGG_PATH=$AGG_PATH, expected $RESEARCH_DIR_ABS/post-impl-review-final.md" >&2; exit 1; }
. "$TMP/review-builder.sh"
REVIEW_WORKSPACE_JSON="$UBERDEV_COMMAND_WORKSPACE_JSON"
eval "$(declare -f review_fixer_child_bound | sed '1s/^review_fixer_child_bound/review_fixer_child_bound_production/')"

# This test closes the production child-input/build/handoff/dispatch graph, not
# the code-fixer repository transaction. The source worktree is intentionally
# dirty while this suite runs, so give the extracted controller callsites a
# deterministic contract fixture that publishes real authority bytes/digests.
# The production contract implementation has its own state-machine test suite.
CODE_FIXER_CONTRACT_FIXTURE="$TMP/code-fixer-contract-fixture.py"
cat >"$CODE_FIXER_CONTRACT_FIXTURE" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path


def options(values):
    if len(values) % 2:
        raise SystemExit(2)
    parsed = {}
    for index in range(0, len(values), 2):
        key, value = values[index : index + 2]
        if not key.startswith("--") or key in parsed:
            raise SystemExit(2)
        parsed[key] = value
    return parsed


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


command = sys.argv[1]
arguments = options(sys.argv[2:])
if command == "digest":
    payload = Path(arguments["--path"]).read_bytes()
    if not int(arguments["--minimum"]) <= len(payload) <= int(arguments["--maximum"]):
        raise SystemExit(74)
    print(hashlib.sha256(payload).hexdigest(), end="")
elif command == "prepare-authority":
    edge = arguments["--edge-id"]
    phase = "phase1" if edge.endswith("phase1") else "phase2"
    commit_type = "fix" if phase == "phase1" else "refactor"
    path = Path(arguments["--authority-output-path"])
    value = {
        "schema_version": 1,
        "edge_id": edge,
        "phase": phase,
        "commit_type": commit_type,
        "findings_sha256": arguments["--findings-sha256"],
        "commit_range_sha256": arguments["--commit-range-sha256"],
    }
    path.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.chmod(path, 0o600)
    print(json.dumps({
        "authority_path": str(path),
        "authority_sha256": digest(path),
        "phase": phase,
        "commit_type": commit_type,
        "target_paths": [],
    }, sort_keys=True, separators=(",", ":")), end="")
elif command == "bind-fixer-launch-receipt":
    receipt = sys.stdin.buffer.read()
    if os.environ.get("REVIEW_FIXTURE_FORCE_BIND_FAILURE") == "1":
        state_dir = Path(os.environ["REVIEW_BIND_FAILURE_STATE_DIR"])
        status_path = str(Path(arguments["--status-path"]).resolve())
        matches = []
        for lease in state_dir.rglob("*.lease"):
            values = {}
            for line in lease.read_text(encoding="utf-8").splitlines():
                key, separator, value = line.partition("=")
                if separator:
                    values[key] = value
            if values.get("status_path") == status_path:
                matches.append((lease, values))
        if len(matches) != 1:
            raise SystemExit(74)
        lease, values = matches[0]
        observation = Path(os.environ["REVIEW_BIND_FAILURE_OBSERVATION"])
        observation.write_text(json.dumps({
            "controller_pid": int(os.environ["REVIEW_BIND_FAILURE_CONTROLLER_PID"]),
            "owner_pid": int(values["owner_pid"]),
            "provider_pid": int(values["backend_handle"]),
            "receipt_sha256": hashlib.sha256(receipt).hexdigest(),
            "run_id": values["run_id"],
        }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        os.chmod(observation, 0o600)
        raise SystemExit(73)
    print(json.dumps({
        "receipt_sha256": hashlib.sha256(receipt).hexdigest(),
        "result_path": arguments["--result-path"],
        "status_path": arguments["--status-path"],
    }, sort_keys=True, separators=(",", ":")), end="")
elif command == "capture-review-terminal":
    binding = json.loads(arguments["--launch-binding-json"])
    disposition = Path(arguments["--disposition-path"])
    applied = Path(arguments["--applied-content-path"])
    for path in (disposition, applied):
        path.write_text("{}\n", encoding="utf-8")
        os.chmod(path, 0o600)
    print(json.dumps({
        "status_sha256": digest(binding["status_path"]),
        "result_sha256": digest(binding["result_path"]),
        "disposition_sha256": digest(disposition),
        "applied_content_path": str(applied),
        "applied_content_sha256": digest(applied),
    }, sort_keys=True, separators=(",", ":")), end="")
elif command == "validate-review-outcome":
    print('{"status":"NO_FIXES_NEEDED"}', end="")
else:
    raise SystemExit(2)
PY
chmod 600 "$CODE_FIXER_CONTRACT_FIXTURE"
CODE_FIXER_CONTRACT="$CODE_FIXER_CONTRACT_FIXTURE"

# Keep this closure test on the established record/fanout/wait seam. The bound
# fixer wrapper's receipt/status/terminal authorization is exercised by the
# dedicated code-fixer contract tests; using it here would make a payload test
# own process cancellation and repository-transaction semantics as well.
review_fixer_child_bound() {
  [ "$#" -eq 10 ] || return 2
  review_child_single "$1" "$2" "$3" "$4" "$5" "$6" || return $?
  REVIEW_FIXER_LAUNCH_BINDING='{}'
  REVIEW_FIXER_TERMINAL='{"applied_content_sha256":"0000000000000000000000000000000000000000000000000000000000000000","disposition_sha256":"0000000000000000000000000000000000000000000000000000000000000000","result_sha256":"0000000000000000000000000000000000000000000000000000000000000000","status_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}'
}

review_promote_validated_fixer_outcome() {
  [ "$#" -eq 3 ]
}

# Keep every production layer through child-dispatch. Only the immediate final
# provider seam is replaced, and it refuses to run before its correlated
# dispatch receipt is durable.
HANDOFFS="$CARRIER_RUN/handoffs"
STATE_DIR="$CARRIER_RUN/.agent-state-$(id -u)"
LIFECYCLE="$STATE_DIR/agent-lifecycle.jsonl"
SEMAPHORE_ROOT="$STATE_DIR/semaphore-v1"

review_provider_args_validate() {
  [ "$#" -eq 7 ] || return 1
  local backend="$1" issue="$2" tier="$3" prompt="$4" result="$5" child_status="$6" decision="$7"
  local instance
  instance="$(basename "$(dirname "$child_status")")"
  [ "$backend" = workflow ] || return 1
  [ "$issue" = 73 ] || return 1
  [ "$tier" = medium ] || return 1
  [ "$prompt" = "$CARRIER_RUN/children/$instance/prompt.txt" ] || return 1
  [ "$result" = "$CARRIER_RUN/children/$instance/result.md" ] || return 1
  [ "$child_status" = "$CARRIER_RUN/children/$instance/status.json" ] || return 1
  [ -n "${UBERDEV_AGENT_DECISION_JSON:-}" ] || return 1
  [ "$decision" = "$UBERDEV_AGENT_DECISION_JSON" ] || return 1
}

_uberdev_agent_dispatch_backend() {
  local backend="$1" prompt="$4" result="$5" child_status="$6"
  local instance edge
  review_provider_args_validate "$@" || {
    echo 'review-child-inputs: invalid provider arguments' >&2
    return 2
  }
  instance="$(basename "$(dirname "$child_status")")"
  edge="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["edge_id"],end="")' "$HANDOFFS/$instance.json")"
  if [ "${REVIEW_FIXTURE_FORCE_BIND_FAILURE:-0}" = 1 ]; then
    # The simulated provider leads its own session and is ALREADY TERMINAL, which
    # is what a workflow-backed child actually looks like at unwind time.
    #
    # This used to `time.sleep(60)`, modelling a detached provider still running
    # when the controller unwinds. That shape cannot occur here any more: after
    # #381 the only backend uberdev_dispatch_preflight_backend admits for
    # review_pr.fix.* is `workflow`, and a workflow child owns no process at all
    # -- lib/dispatch.sh has no workflow provider arm BY CONSTRUCTION, so
    # _uberdev_agent_dispatch_backend (which this function stubs) is never
    # reached on that path. The Workflow call has already returned by the time
    # the controller unwinds; there is nothing left to signal.
    #
    # Keeping the sleep would have asserted that unwind reaps a process
    # production never creates -- a test passing only because a fixture invented
    # the thing it then checked for. The assertions that carry the real value are
    # unchanged and still enforced below: rc=73 is not masked by 74, exactly one
    # terminal lifecycle event is recorded, and NO capacity lease is left behind.
    # Detached-backend leak reaping is covered where a detached backend can
    # actually run -- tests/dispatch-child-worktree-teardown.test.sh and
    # tests/child-dispatch.test.sh.
    python3 -I -B -c 'import os; os.setsid()' >/dev/null 2>&1 &
    DISPATCH_ID="$!"
    wait "$DISPATCH_ID" 2>/dev/null || true
    printf '%s\n' "$DISPATCH_ID" >"$REVIEW_BIND_FAILURE_PROVIDER_PID"
    chmod 600 "$REVIEW_BIND_FAILURE_PROVIDER_PID"
    return 0
  fi
  python3 -I -B - "$RECEIPTS" "$UBERDEV_CHILD_TEST_SOURCE" "$edge" "$instance" <<'PY'
import json
import sys
from pathlib import Path

receipt, source, edge, instance = sys.argv[1:]
rows = Path(receipt).read_text(encoding="utf-8").splitlines()
if not rows:
    raise SystemExit("provider seam reached before any dispatch receipt")
matches = []
for line in rows:
    row = json.loads(line)
    identity = (row.get("event"), row.get("source"), row.get("edge_id"), row.get("instance_id"))
    if identity == ("dispatch", source, edge, instance):
        matches.append(row)
if len(matches) != 1:
    raise SystemExit(f"provider seam reached without one correlated dispatch receipt: {matches!r}")
PY
  case "$edge" in
    review_pr.review.*)
      printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' \
        'confidence: high' '```' >"$result"
      ;;
    *) printf 'fixture result for %s\n' "$instance" >"$result" ;;
  esac
  chmod 600 "$result"
  DISPATCH_ID="fixture-$instance"
  python3 -I -B - "$PROVIDER_CALLS" "$UBERDEV_CHILD_TEST_SOURCE" "$edge" "$instance" \
    "$UBERDEV_AGENT_DECISION_JSON" "$@" <<'PY'
import json
import sys

path, source, edge, instance, adapter_decision, *args = sys.argv[1:]
row = {
    "source": source,
    "edge_id": edge,
    "instance_id": instance,
    "adapter_decision": adapter_decision,
    "args": args,
}
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
PY
  _uberdev_agent_publish_status "$child_status" "$backend" "$DISPATCH_ID" completed 0 create
}

# Source the production post-review setup/record/fanout definitions against the
# real parent review workspace before substituting hostile but schema-valid
# fixture values at the callsite boundary.
export UBERDEV_CHILD_TEST_SOURCE="$POST_SOURCE"
export UBERDEV_COMMAND_WORKSPACE_JSON="$REVIEW_WORKSPACE_JSON"
. "$TMP/post-prefix.sh"

LONG_REVIEW_RUN_ID="$(python3 -I -B -c 'print("review-run-"+"x"*180,end="")')"
for LONG_REVIEW_CANDIDATE in \
  "post-review-${LONG_REVIEW_RUN_ID}-r6-iter7-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-fix-phase1-iter7-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-simplify-quality-iter7-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-fix-phase2-iter7-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-defer-findings-iter7-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-ci-classify-iter3-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-ci-fix-iter3-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-ci-rebase-iter3-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-ci-defer-refusal-iter3-attempt01" \
  "review-pr-${LONG_REVIEW_RUN_ID}-conflict-99-iter3-attempt01"; do
  LONG_REVIEW_INSTANCE="$(uberdev_child_instance_id "$LONG_REVIEW_CANDIDATE")"
  LONG_REVIEW_REPEAT="$(uberdev_child_instance_id "$LONG_REVIEW_CANDIDATE")"
  if [ "$LONG_REVIEW_INSTANCE" != "$LONG_REVIEW_REPEAT" ] \
      || [ "${#LONG_REVIEW_INSTANCE}" -gt 128 ] \
      || ! [[ "$LONG_REVIEW_INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
      || ! [[ "$LONG_REVIEW_INSTANCE" =~ -[0-9a-f]{12}$ ]]; then
    echo "review-child-inputs: long review run id did not produce one stable bounded child identity" >&2
    exit 1
  fi
done

# Phase 1 re-entry materializes names and diff bytes from one fixed local
# base-to-HEAD snapshot. A file introduced by a fixer must join the next review
# handoff instead of inheriting the stale PR-server path list.
SCOPE_REPO="$TMP/scope-repo"
mkdir -p "$SCOPE_REPO"
git -C "$SCOPE_REPO" init -q
git -C "$SCOPE_REPO" config user.email test@example.com
git -C "$SCOPE_REPO" config user.name Test
printf 'base\n' >"$SCOPE_REPO/base.txt"
git -C "$SCOPE_REPO" add base.txt
git -C "$SCOPE_REPO" commit -qm 'test: create scope base'
BASE_SHA="$(git -C "$SCOPE_REPO" rev-parse HEAD)"
SCOPE_EXPECTED_BASE="$BASE_SHA"
SCOPE_EXPECTED_REPO_SLUG=test-owner/test-repo
SCOPE_BIN="$TMP/scope-bin"
mkdir -p "$SCOPE_BIN"
cat >"$SCOPE_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -ge 7 ] \
  && [ "$1" = pr ] \
  && [ "$2" = view ] \
  && [ "$3" = 73 ] \
  && [ "$4" = --repo ] \
  && [ "$5" = "$SCOPE_EXPECTED_REPO_SLUG" ] \
  && [ "$6" = --json ] || exit 2
case "$7" in
  baseRefOid,baseRefName)
    [ "$#" -eq 7 ] || exit 2
    printf '{"baseRefOid":"%s","baseRefName":"main"}\n' "$SCOPE_EXPECTED_BASE"
    ;;
  headRefOid)
    [ "$#" -eq 9 ] && [ "$8" = --jq ] && [ "$9" = .headRefOid ] || exit 2
    git -C "$SCOPE_REPO" rev-parse HEAD
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$SCOPE_BIN/gh"
export SCOPE_EXPECTED_BASE SCOPE_EXPECTED_REPO_SLUG SCOPE_REPO
printf 'initial change\n' >>"$SCOPE_REPO/base.txt"
git -C "$SCOPE_REPO" add base.txt
git -C "$SCOPE_REPO" commit -qm 'test: create initial review change'
(
  PATH="$SCOPE_BIN:$PATH"
  WORKTREE_ROOT="$SCOPE_REPO"
  DIFF_ARTIFACT_PATH="$TMP/scope-diff.md"
  COMMIT_RANGE_PATH="$TMP/scope-range.txt"
  PR_NUMBER=73
  REVIEW_REPO_SLUG="$SCOPE_EXPECTED_REPO_SLUG"
  [[ "$REVIEW_REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
  . "$TMP/review-head-assert.sh"
  unset BASE_SHA
  . "$TMP/review-scope.sh"
  python3 -I -B - "$CHANGED_PATHS_JSON" "$DIFF_ARTIFACT_PATH" <<'PY'
import json,sys
paths=json.loads(sys.argv[1]); raw=open(sys.argv[2],encoding='utf-8').read()
assert paths==['base.txt'],paths
assert raw.startswith('<external-untrusted-input source="pr-diff">\n')
assert raw.endswith('</external-untrusted-input>\n')
PY
  printf 'fixer-created\n' >"$SCOPE_REPO/fixer-created.txt"
  git -C "$SCOPE_REPO" add fixer-created.txt
  git -C "$SCOPE_REPO" commit -qm 'fix: simulate phase 1 fixer file'
  . "$TMP/review-scope.sh"
  python3 -I -B - "$CHANGED_PATHS_JSON" "$DIFF_ARTIFACT_PATH" "$COMMIT_RANGE_PATH" "$SCOPE_EXPECTED_BASE" <<'PY'
import json,sys
paths=json.loads(sys.argv[1]); raw=open(sys.argv[2],encoding='utf-8').read()
commit_range=open(sys.argv[3],encoding='utf-8').read().strip()
assert paths==['base.txt','fixer-created.txt'],paths
assert 'fixer-created.txt' in raw
base,head=commit_range.split('..',1)
assert base==sys.argv[4] and len(head)==40 and all(ch in '0123456789abcdef' for ch in head)
PY
  python3 -I -B - "$SCOPE_REPO/substantial.bin" <<'PY'
import random,sys
open(sys.argv[1],'wb').write(random.Random(335).randbytes(7*1024*1024))
PY
  git -C "$SCOPE_REPO" add substantial.bin
  git -C "$SCOPE_REPO" commit -qm 'test: add substantial binary review fixture'
  . "$TMP/review-scope.sh"
  python3 -I -B - "$DIFF_ARTIFACT_PATH" <<'PY'
import os,sys
raw=open(sys.argv[1],encoding='utf-8').read()
assert '[diff summarized:' in raw,raw[:200]
assert 'substantial.bin' in raw
assert os.path.getsize(sys.argv[1]) < 16*1024*1024
PY
  python3 -I -B - "$SCOPE_REPO/large.txt" <<'PY'
import sys
open(sys.argv[1],'w',encoding='utf-8').writelines(f'line {index}\n' for index in range(2101))
PY
  git -C "$SCOPE_REPO" add large.txt
  git -C "$SCOPE_REPO" commit -qm 'test: add large text review fixture'
  . "$TMP/review-scope.sh"
  python3 -I -B - "$DIFF_ARTIFACT_PATH" <<'PY'
import os,sys
raw=open(sys.argv[1],encoding='utf-8').read()
assert '[diff summarized:' in raw and 'large.txt' in raw
assert os.path.getsize(sys.argv[1]) < 16*1024*1024
PY
  # Deliberately hostile fixture: point the commit-range artifact at a
  # DIRECTORY. review_refresh_phase1_scope's replace_private
  # (plugins/uberdev/commands/review-pr.md:1554) does os.replace(tmp, path),
  # which cannot clobber a directory, so the refresh must refuse rather than
  # leave the stale range in place. The refusal surfaces as a Python traceback
  # on stderr -- that IS the diagnostic, and it is expected here. Capture it so
  # a deliberate refusal does not read as a suite failure in the transcript,
  # and assert both halves: non-zero exit AND a non-empty diagnostic.
  STALE_RANGE_PATH="$COMMIT_RANGE_PATH"
  SCOPE_BLOCKED_LOG="$TMP/scope-range-blocked.log"
  mkdir "$TMP/scope-range-blocked"
  COMMIT_RANGE_PATH="$TMP/scope-range-blocked"
  if . "$TMP/review-scope.sh" 2>"$SCOPE_BLOCKED_LOG"; then
    echo 'review-child-inputs: failed Phase 1 scope refresh reused stale artifacts' >&2
    exit 1
  fi
  if ! [ -s "$SCOPE_BLOCKED_LOG" ]; then
    echo 'review-child-inputs: blocked scope refresh refused without any diagnostic' >&2
    exit 1
  fi
  COMMIT_RANGE_PATH="$STALE_RANGE_PATH"
)

HOSTILE_DIR="$RESEARCH_DIR_ABS"$'/review dir\nwith "quotes" and \\slashes *?[x]'
mkdir -p "$HOSTILE_DIR"
# These fixtures are contract-accepted repository-relative paths after
# validation. They deliberately do not exist to cover deleted paths while
# retaining hostile shell metacharacters as inert JSON data.
CHANGED_ONE='src/changed "one" path*.ts'
CHANGED_TWO='tests/changed two [x] path?.sh'
DIFF_PATH="$HOSTILE_DIR"$'/diff "quoted" \\path*?[x].md'
CRITERIA_FIXTURE="$HOSTILE_DIR"$'/criteria "quoted" \\path*?[x].md'
FORMAT_EXAMPLE="$HOSTILE_DIR"$'/format "quoted" \\path*?[x].yaml'
POST_FINAL="$RESEARCH_DIR_ABS/post-impl-review-final.md"
SIMPLIFY_FINAL="$RESEARCH_DIR_ABS/simplify-final.md"
COMMIT_RANGE_FIXTURE="$HOSTILE_DIR"$'/commit "range" \\path*.txt'
PHASE1_DISPOSITION_FIXTURE="$HOSTILE_DIR"$'/phase1 "disposition" \\path*.json'
PHASE2_DISPOSITION_FIXTURE="$HOSTILE_DIR"$'/phase2 "disposition" \\path*.json'
CLASSIFICATION_PATH="$HOSTILE_DIR"$'/classification "quoted" \\path*.yaml'
CI_LOG_SOURCE_PATH="$HOSTILE_DIR"$'/ci "log" \\source*?[x].txt'
CI_REFUSED_AGGREGATE_PATH="$HOSTILE_DIR"$'/refused "aggregate" \\path*.md'
CONFLICT_PATH="$HOSTILE_DIR"$'/conflict "quoted" \\path*.ts'

for fixture in \
  "$DIFF_PATH" "$CRITERIA_FIXTURE" "$FORMAT_EXAMPLE" \
  "$POST_FINAL" "$SIMPLIFY_FINAL" "$COMMIT_RANGE_FIXTURE" \
  "$PHASE1_DISPOSITION_FIXTURE" "$PHASE2_DISPOSITION_FIXTURE" \
  "$CLASSIFICATION_PATH" "$CI_REFUSED_AGGREGATE_PATH" \
  "$CONFLICT_PATH"; do
  printf 'private hostile review fixture: %s\n' "${fixture##*/}" >"$fixture"
  chmod 600 "$fixture"
done
POST_FINAL_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$POST_FINAL")"
SIMPLIFY_FINAL_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$SIMPLIFY_FINAL")"
COMMIT_RANGE_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$COMMIT_RANGE_FIXTURE")"
printf '%s\n' 'original & <failed assertion>' >"$CI_LOG_SOURCE_PATH"
chmod 600 "$CI_LOG_SOURCE_PATH"
CI_LOG_CONTENT=$'<external-untrusted-input source="github-actions-log-pr-73-run-9001">\noriginal &amp; &lt;failed assertion>\n</external-untrusted-input>\n'
CI_LOG_SHA256="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest(),end="")' "$CI_LOG_CONTENT")"
CI_CLASSIFICATION_HEAD_SHA="$(git rev-parse HEAD)"
REVIEW_REPO_SLUG=owner/repo
gh() {
  [ "$#" -eq 6 ] \
    && [ "$1" = run ] \
    && [ "$2" = view ] \
    && [ "$3" = "$CI_RUN_ID" ] \
    && [ "$4" = --repo ] \
    && [ "$5" = "$REVIEW_REPO_SLUG" ] \
    && [ "$6" = --log-failed ] || return 2
  cat "$CI_LOG_SOURCE_PATH"
}

CHANGED_PATHS_JSON="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' "$CHANGED_ONE" "$CHANGED_TWO")"
EMPHASIS_JSON="$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")),end="")' \
  $'tests "quoted" \\focus*?[x]\t' $'errors "quoted" \\focus*?[x]\t')"
DIFF_ARTIFACT_PATH="$DIFF_PATH"
CRITERIA_PATH="$CRITERIA_FIXTURE"

# changed_paths represents the complete name-only diff. Its acceptance is
# bounded by the handoff byte limit, not by an arbitrary file-count ceiling.
LARGE_CHANGED_PATHS_JSON="$(python3 -I -B -c 'import json; print(json.dumps([f"src/large-pr-{i:03d}.ts" for i in range(129)],separators=(",",":")),end="")')"
LARGE_REVIEW_INPUTS="$(uberdev_child_inputs_build review_pr.review.correctness \
  changed_paths "$LARGE_CHANGED_PATHS_JSON" \
  diff_path "$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1]),end="")' "$DIFF_PATH")" \
  criteria_path "$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1]),end="")' "$CRITERIA_FIXTURE")" \
  emphasis '[]')"
[ "$(python3 -I -B -c 'import json,sys; print(len(json.loads(sys.argv[1])["changed_paths"]))' "$LARGE_REVIEW_INPUTS")" -eq 129 ] || {
  echo 'review-child-inputs: complete 129-path PR diff was truncated or rejected' >&2
  exit 1
}
if uberdev_child_inputs_build review_pr.review.correctness \
    changed_paths '[]' \
    diff_path "$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1]),end="")' "$DIFF_PATH")" \
    criteria_path "$(python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1]),end="")' "$CRITERIA_FIXTURE")" \
    emphasis '[]' >/dev/null 2>&1; then
  echo 'review-child-inputs: empty changed_paths scope was accepted' >&2
  exit 1
fi
if DRIVE_RELATIVE_INPUTS="$(python3 -I -B - "$LARGE_REVIEW_INPUTS" <<'PY'
import json,sys
value=json.loads(sys.argv[1]); value['changed_paths']=['C:relative/path.ts']
print(json.dumps(value,separators=(',',':')),end='')
PY
)" && uberdev_child_inputs_validate review_pr.review.correctness "$DRIVE_RELATIVE_INPUTS" >/dev/null 2>&1; then
  echo 'review-child-inputs: Windows drive-relative path was accepted' >&2
  exit 1
fi

# Canonical six-edge roster -> post_review_record -> post_review_fanout.
. "$TMP/post-roster.sh"
BASE_REVIEW_RECORDS="$TMP/post-review-baseline.records"
python3 -I -B - "$REVIEW_RECORDS" "$BASE_REVIEW_RECORDS" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[2]).write_bytes(Path(sys.argv[1]).read_bytes())
PY
chmod 600 "$BASE_REVIEW_RECORDS"

# The remaining independent callsites run in two bounded test waves. Each
# subshell still executes the extracted production wrapper and the real
# dispatch lifecycle; overlap keeps this closure test below the CI time budget.
printf '%s\n' \
  '{"edge":"review_pr.review.types","index":3,"status":"fixture.status","result":"fixture.result"}' \
  >"$REVIEW_FAILED"
# The baseline fanout produced six valid evidence rows. Model the declared
# reviewer-format failure completely: production would not persist that
# reviewer's validated row before dispatching its format-repair attempt.
python3 -I -B - "$POST_REVIEW_VALIDATED_LEDGER" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream if line.strip()]
failed_pair = ("review_pr.review.types", 3)
kept = [
    row for row in rows
    if (row.get("edge"), row.get("index")) != failed_pair
]
if len(rows) != 6 or len(kept) != 5:
    raise SystemExit("format-failure fixture did not remove exactly one validated row")
with open(path, "w", encoding="utf-8") as stream:
    for row in kept:
        stream.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
PY
REVIEW_EXPECTED_COUNT=6
REVIEW_INITIAL_VALID_COUNT=5
REVIEW_FORMAT_FAILURE_COUNT=1
unset FAILED_REVIEW_EDGE FAILED_REVIEW_INDEX
FORMAT_EXAMPLE_PATH="$FORMAT_EXAMPLE"
export UBERDEV_CHILD_TEST_SOURCE="$REVIEW_SOURCE"
# Caller-mode mutations are bound to the canonical repository root. Keep the
# hostile fixture coverage on artifact paths, which remain untrusted inputs,
# while exercising the production workspace boundary with a valid identity.
MUTATION_WORKTREE="$ROOT"
export MUTATION_WORKTREE
WORKTREE_ROOT="$MUTATION_WORKTREE"
WORKING_DIR_ABS="$MUTATION_WORKTREE"
COMMIT_RANGE_PATH="$COMMIT_RANGE_FIXTURE"
PHASE1_DISPOSITION_PATH="$PHASE1_DISPOSITION_FIXTURE"
PHASE2_DISPOSITION_PATH="$PHASE2_DISPOSITION_FIXTURE"
unset findings_path
DIFF_ARTIFACT_PATH="$DIFF_PATH"
FOCUS_PRESENT="$FOCUS"

review_wait_jobs() {
  local first_rc=0 pid rc
  for pid in "$@"; do
    if wait "$pid"; then
      continue
    else
      rc=$?
    fi
    [ "$first_rc" -ne 0 ] || first_rc="$rc"
  done
  [ "$first_rc" -eq 0 ] || return "$first_rc"
}

# Scope refresh itself is exercised against a real repository above. The
# child-input closure waves consume those already-materialized artifacts, so
# keep their extracted Phase 2 callsite focused on build/dispatch evidence.
review_refresh_phase1_scope() {
  return 0
}

wave=()
(
  UBERDEV_CHILD_TEST_SOURCE="$POST_SOURCE"
  . "$TMP/post-retry.sh"
) & wave+=("$!")
(. "$TMP/review-phase1.sh") & wave+=("$!")
(
  REVIEW_ITERATION=7
  FOCUS="$FOCUS_PRESENT"
  . "$TMP/review-simplify.sh"
) & wave+=("$!")
(. "$TMP/review-phase2.sh") & wave+=("$!")
(. "$TMP/review-defer.sh") & wave+=("$!")
# WORKFLOW-NATIVE SURFACE (#383). The Phase 3 CI classify child no longer takes
# the ROUTED adapter -- it is dispatched by skills/review-fleet/workflow.js as
# the `ci-classify` stage -- so this fixture asserts the INPUT CLOSURE, which is
# what the routed dispatch used to prove, and nothing about a handoff production
# no longer writes. The receipt closure below independently requires that the
# edge emits a `build` receipt and NEVER a handoff, dispatch or lifecycle row.
#
# The builder is captured on the way out through an EXIT trap: the extracted
# fence runs inside a command-substitution subshell, and that trap is the only
# place CI_CLASSIFY_INPUTS is still in scope.
CLASSIFY_INPUTS_CAPTURE="$TMP/ci-classify-inputs.json"
(
  set +e
  CLASSIFY_OUTPUT="$(
    trap 'printf "%s" "${CI_CLASSIFY_INPUTS-}" >"$CLASSIFY_INPUTS_CAPTURE"' EXIT
    . "$TMP/review-classify.sh" 2>&1
  )"
  set -e
  [ -s "$CLASSIFY_INPUTS_CAPTURE" ] || { echo "review-classify: never built the CI classify input closure: $CLASSIFY_OUTPUT" >&2; exit 1; }
) & wave+=("$!")
review_wait_jobs "${wave[@]}"
PHASE1_AUTHORITY_FIXTURE="$RESEARCH_DIR_ABS/code-fixer-authority-phase1-iter7.json"
PHASE2_AUTHORITY_FIXTURE="$RESEARCH_DIR_ABS/code-fixer-authority-phase2-iter7.json"
PHASE1_AUTHORITY_SHA256_FIXTURE="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$PHASE1_AUTHORITY_FIXTURE")"
PHASE2_AUTHORITY_SHA256_FIXTURE="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$PHASE2_AUTHORITY_FIXTURE")"
PHASE1_FINDINGS_SHA256_FIXTURE="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings_sha256"],end="")' "$PHASE1_AUTHORITY_FIXTURE")"
PHASE1_COMMIT_RANGE_SHA256_FIXTURE="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit_range_sha256"],end="")' "$PHASE1_AUTHORITY_FIXTURE")"

# The production bound fixer wrapper must dispatch from its durable controller
# shell. Force the first post-launch receipt-binding step to fail, then prove
# that the controller owns the lease, survives long enough to unwind the real
# provider process group, publishes one terminal event, and releases capacity.
BIND_FAILURE_INSTANCE="$(uberdev_child_instance_id "review-pr-${RUN_ID}-bind-failure-attempt01")"
BIND_FAILURE_FINDINGS="$RESEARCH_DIR_ABS/bind-failure-findings.md"
BIND_FAILURE_RANGE="$RESEARCH_DIR_ABS/bind-failure-commit-range.txt"
BIND_FAILURE_DISPOSITION="$RESEARCH_DIR_ABS/bind-failure-disposition.json"
BIND_FAILURE_AUTHORITY="$RESEARCH_DIR_ABS/bind-failure-authority.json"
cp "$POST_FINAL" "$BIND_FAILURE_FINDINGS"
cp "$COMMIT_RANGE_FIXTURE" "$BIND_FAILURE_RANGE"
: >"$BIND_FAILURE_DISPOSITION"
chmod 600 "$BIND_FAILURE_FINDINGS" "$BIND_FAILURE_RANGE" "$BIND_FAILURE_DISPOSITION"
BIND_FAILURE_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$BIND_FAILURE_FINDINGS" --minimum 1 --maximum 16777216)"
BIND_FAILURE_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest --path "$BIND_FAILURE_RANGE" --minimum 1 --maximum 256)"
BIND_FAILURE_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
  --edge-id review_pr.fix.phase1 --policy-phase review_fix \
  --findings-path "$BIND_FAILURE_FINDINGS" --findings-sha256 "$BIND_FAILURE_FINDINGS_SHA256" \
  --commit-range-path "$BIND_FAILURE_RANGE" --commit-range-sha256 "$BIND_FAILURE_RANGE_SHA256" \
  --working-dir "$WORKTREE_ROOT" --disposition-path "$BIND_FAILURE_DISPOSITION" \
  --authority-output-path "$BIND_FAILURE_AUTHORITY")"
BIND_FAILURE_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["authority_sha256"],end="")' "$BIND_FAILURE_AUTHORITY_RECEIPT")"
BIND_FAILURE_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase1 \
  findings_path "$(review_json_string "$BIND_FAILURE_FINDINGS")" \
  findings_sha256 "$(review_json_string "$BIND_FAILURE_FINDINGS_SHA256")" \
  commit_range_path "$(review_json_string "$BIND_FAILURE_RANGE")" \
  commit_range_sha256 "$(review_json_string "$BIND_FAILURE_RANGE_SHA256")" \
  working_dir "$(review_json_string "$WORKTREE_ROOT")" \
  pr_number "$PR_NUMBER" \
  disposition_path "$(review_json_string "$BIND_FAILURE_DISPOSITION")" \
  authority_path "$(review_json_string "$BIND_FAILURE_AUTHORITY")" \
  authority_sha256 "$(review_json_string "$BIND_FAILURE_AUTHORITY_SHA256")")"
BIND_FAILURE_OBSERVATION="$TMP/bind-failure-observation.json"
BIND_FAILURE_PROVIDER_PID="$TMP/bind-failure-provider.pid"
BIND_FAILURE_SURVIVED="$TMP/bind-failure-controller-survived"
BIND_FAILURE_EXITED="$TMP/bind-failure-controller-exited"
(
  trap 'printf "%s\n" "$BASHPID" >"$BIND_FAILURE_EXITED"' EXIT
  export REVIEW_FIXTURE_FORCE_BIND_FAILURE=1
  export REVIEW_BIND_FAILURE_STATE_DIR="$STATE_DIR"
  export REVIEW_BIND_FAILURE_OBSERVATION="$BIND_FAILURE_OBSERVATION"
  export REVIEW_BIND_FAILURE_PROVIDER_PID="$BIND_FAILURE_PROVIDER_PID"
  export REVIEW_BIND_FAILURE_CONTROLLER_PID="$BASHPID"
  set +e
  review_fixer_child_bound_production review_pr.fix.phase1 "$BIND_FAILURE_INSTANCE" \
    "$BIND_FAILURE_INPUTS" null "$RESEARCH_DIR_ABS/bind-failure" 2 \
    "$BIND_FAILURE_AUTHORITY" "$BIND_FAILURE_AUTHORITY_SHA256" \
    "$BIND_FAILURE_DISPOSITION" "$RESEARCH_DIR_ABS/bind-failure-applied.json"
  bind_failure_rc=$?
  set -e
  [ "$bind_failure_rc" -eq 73 ]
  printf '%s\n' "$BASHPID" >"$BIND_FAILURE_SURVIVED"
)
[ -s "$BIND_FAILURE_SURVIVED" ] && [ -s "$BIND_FAILURE_EXITED" ]
cmp "$BIND_FAILURE_SURVIVED" "$BIND_FAILURE_EXITED"
python3 -I -B - "$BIND_FAILURE_OBSERVATION" "$BIND_FAILURE_PROVIDER_PID" \
  "$STATE_DIR/agent-lifecycle.jsonl" "$STATE_DIR/semaphore-v1" \
  "$BIND_FAILURE_INSTANCE" "$BIND_FAILURE_SURVIVED" <<'PY'
import errno,json,os,sys,time
observation_path,provider_path,lifecycle_path,semaphore_root,instance,controller_path=sys.argv[1:]
observation=json.load(open(observation_path,encoding='utf-8'))
provider_pid=int(open(provider_path,encoding='utf-8').read().strip())
controller_pid=int(open(controller_path,encoding='utf-8').read().strip())
assert observation['owner_pid']==controller_pid,observation
assert observation['controller_pid']==controller_pid,observation
assert observation['provider_pid']==provider_pid,observation
assert observation['run_id']==instance,observation
for _ in range(50):
    try:
        os.killpg(provider_pid,0)
    except ProcessLookupError:
        break
    except OSError as error:
        if error.errno==errno.ESRCH:
            break
        raise
    time.sleep(0.1)
else:
    raise AssertionError(f'provider process group {provider_pid} survived controller unwind')
rows=[json.loads(line) for line in open(lifecycle_path,encoding='utf-8') if line.strip()]
child=[row for row in rows if row.get('run_id')==instance]
terminal=[row for row in child if row.get('event') in {'completed','failed','timed_out','cancelled','abandoned'}]
assert len(terminal)==1,(child,terminal)
residual=[]
for directory,_,names in os.walk(semaphore_root):
    for name in names:
        if not name.endswith('.lease'):
            continue
        path=os.path.join(directory,name)
        if f'run_id={instance}\n' in open(path,encoding='utf-8').read():
            residual.append(path)
assert residual==[],residual
PY
[ -z "$(find "$HANDOFFS" -maxdepth 1 -name '.dispatch-receipt.*' -print -quit)" ]

if [ -n "$(find "$RESEARCH_DIR_ABS" -maxdepth 1 -name 'ci-log-run-*.raw' -print -quit)" ]; then
  echo 'review-child-inputs: controller created a mutable raw CI log staging file' >&2
  exit 1
fi

# Replacing the controller-only source after dispatch cannot change the inline
# bytes already published in the immutable classifier handoff.
printf '%s\n' 'replacement platform outage' >"$CI_LOG_SOURCE_PATH"

CI_CLASSIFICATION_PATH="$RESEARCH_DIR_ABS/ci-classification-${CI_FIX_LOOP_ITER:-1}.yaml"
printf 'validated classifier output\n' >"$CI_CLASSIFICATION_PATH"
chmod 600 "$CI_CLASSIFICATION_PATH"
CLASSIFICATION_PATH="$CI_CLASSIFICATION_PATH"
failure_class=code_bug
signal_anchor=README.md:1
# Model a replacement after the controller has captured and validated the
# classifier scalars. The fixer handoff must not carry this pathname or reopen
# its replacement.
printf 'replacement classifier says env_drift at package-lock.json:1\n' \
  >"$CI_CLASSIFICATION_PATH"

CI_BASE_SHA=$'base "quoted" \\sha*?[x]\t'
. "$TMP/review-ci-builders.sh"
CI_FIX_INPUTS_CAPTURE="$TMP/ci-fix-inputs.json"
CI_REBASE_INPUTS_CAPTURE="$TMP/ci-rebase-inputs.json"
CI_DEFER_INPUTS_CAPTURE="$TMP/ci-defer-inputs.json"
CONFLICT_INPUTS_CAPTURE="$TMP/ci-conflict-inputs.json"
export CI_FIX_INPUTS_CAPTURE CI_REBASE_INPUTS_CAPTURE CI_DEFER_INPUTS_CAPTURE CONFLICT_INPUTS_CAPTURE
printf '%s' "$CI_FIX_INPUTS" >"$CI_FIX_INPUTS_CAPTURE"
printf '%s' "$CI_REBASE_INPUTS" >"$CI_REBASE_INPUTS_CAPTURE"

conflicted_files=("$CONFLICT_PATH")
REPO_ROOT="$MUTATION_WORKTREE"
pr_head_branch=$'feature/"quoted"\\branch*?[x]\t'
base_branch=$'main-"quoted"\\branch*?[x]\t'
BASE_SHA=$'conflict-base-"quoted"\\sha*?[x]\t'
# #383: the CONFLICT arm now reads the refs the ROUTE fence bound, so the
# fixture binds the production names. The hostile values are unchanged -- the
# point of this oracle is that quoting/tabs/globs survive the projection.
CI_PR_HEAD_BRANCH="$pr_head_branch"
CI_BASE_BRANCH="$base_branch"

wave=()
(
  REVIEW_ITERATION=8
  FOCUS=
  . "$TMP/review-simplify.sh"
) & wave+=("$!")
# #383: the five review_pr.ci.* edges BUILD their input closure here and are
# dispatched by the Workflow engine, not by review_child_single. The builders
# still run -- that is the payload oracle this file exists for -- and the
# receipt closure below requires each one to emit a `build` receipt and NO
# handoff, dispatch, provider call or lifecycle row.
(
  trap 'printf "%s" "${CI_DEFER_INPUTS-}" >"$CI_DEFER_INPUTS_CAPTURE"' EXIT
  . "$TMP/review-defer-refusal.sh"
) & wave+=("$!")
(
  CONFLICT_PATH="${conflicted_files[0]}"
  trap 'printf "%s" "${CONFLICT_INPUTS-}" >"$CONFLICT_INPUTS_CAPTURE"' EXIT
  . "$TMP/review-conflict.sh"
) & wave+=("$!")
review_wait_jobs "${wave[@]}"
REVIEW_ITERATION=7
FOCUS="$FOCUS_PRESENT"

# The receipt oracle derives expected digests from immutable production
# handoffs, then requires an exact build/handoff/dispatch correlation for every
# instance. It rejects unknown sources, edges, instances, events, and shapes.
python3 -I -B - "$RECEIPTS" "$HANDOFFS" "$PROVIDER_CALLS" "$POST_SOURCE" "$REVIEW_SOURCE" \
  "$LIFECYCLE" "$SEMAPHORE_ROOT" <<'PY'
import copy
import hashlib
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

(
    receipt_path,
    handoff_dir,
    provider_path,
    post_source,
    review_source,
    lifecycle_path,
    semaphore_root,
) = sys.argv[1:]
expected = {}
run_id = os.environ["RUN_ID"]

def expect(source, edge, instance):
    if instance in expected:
        raise AssertionError(instance)
    expected[instance] = (source, edge)

post_edges = (
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
)
for index, edge in enumerate(post_edges, 1):
    expect(post_source, edge, f"post-review-{run_id}-r{index}-iter7-attempt01")
expect(post_source, "review_pr.review.types", f"post-review-{run_id}-r3-iter7-attempt02")

review_cases = (
    ("review_pr.fix.phase1", f"review-pr-{run_id}-fix-phase1-iter7-attempt01"),
    ("review_pr.fix.phase1", f"review-pr-{run_id}-bind-failure-attempt01"),
    ("review_pr.simplify.reuse", f"review-pr-{run_id}-simplify-reuse-iter7-attempt01"),
    ("review_pr.simplify.quality", f"review-pr-{run_id}-simplify-quality-iter7-attempt01"),
    ("review_pr.simplify.efficiency", f"review-pr-{run_id}-simplify-efficiency-iter7-attempt01"),
    ("review_pr.simplify.reuse", f"review-pr-{run_id}-simplify-reuse-iter8-attempt01"),
    ("review_pr.simplify.quality", f"review-pr-{run_id}-simplify-quality-iter8-attempt01"),
    ("review_pr.simplify.efficiency", f"review-pr-{run_id}-simplify-efficiency-iter8-attempt01"),
    ("review_pr.fix.phase2", f"review-pr-{run_id}-fix-phase2-iter7-attempt01"),
    ("review_pr.defer.findings", f"review-pr-{run_id}-defer-findings-iter7-attempt01"),
)
for edge, instance in review_cases:
    expect(review_source, edge, instance)

# RETIRED SURFACE (#381), INVERTED -- not dropped. review_pr.ci.classify is
# still BUILT: plugins/uberdev/commands/review-pr.md:3285 constructs
# CI_CLASSIFY_INPUTS, which emits a `build` receipt, and only then does the
# transport gate at :3305 refuse. So the edge keeps a source/edge pair the
# receipt closure below still REQUIRES to be present, while owning no instance:
# no handoff, no dispatch, no provider call, no lifecycle row. Every one of
# those absences is asserted -- `retired_edges` immediately below for the
# receipts and handoff files, and `expected.get(instance)` in validate_provider
# / validate_lifecycle, which admit only instances in `expected`.
retired_edges = {
    "review_pr.ci.classify",
    "review_pr.ci.fix_code",
    "review_pr.ci.rebase",
    "review_pr.ci.defer_refusal",
    "review_pr.ci.resolve_conflict",
}
build_only_pairs = {(review_source, edge) for edge in retired_edges}

expected_pairs = set(expected.values()) | build_only_pairs
if len(expected_pairs) != 17 or len(expected) != 17:
    raise SystemExit("invalid receipt expectation fixture")
if any(edge in retired_edges for _, edge in expected.values()):
    raise SystemExit(
        f"retired edges must own no dispatching instance: {sorted(retired_edges)}"
    )

handoff_root = Path(handoff_dir)
actual_files = {path.stem: path for path in handoff_root.glob("*.json")}
if set(actual_files) != set(expected):
    raise SystemExit(
        f"handoff identity mismatch: expected={sorted(expected)!r} actual={sorted(actual_files)!r}"
    )
retired_handoffs = sorted(
    str(path) for path in handoff_root.glob("*.json")
    if json.loads(path.read_text(encoding="utf-8")).get("edge_id") in retired_edges
)
if retired_handoffs:
    raise SystemExit(
        f"routed surface regressed: a review_pr.ci.* edge reached a routed handoff, "
        f"but Phase 3 dispatches through the Workflow engine (#383): {retired_handoffs!r}"
    )

expected_correlated = Counter()
for instance, (source, edge) in expected.items():
    value = json.loads(actual_files[instance].read_text(encoding="utf-8"))
    if value.get("instance_id") != instance or value.get("edge_id") != edge:
        raise SystemExit(f"handoff identity/edge mismatch: {instance}")
    inputs = value.get("inputs")
    if not isinstance(inputs, dict):
        raise SystemExit(f"handoff inputs missing: {instance}")
    canonical = json.dumps(
        inputs, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    expected_correlated[(source, edge, instance, digest)] += 1

rows = [
    json.loads(line)
    for line in Path(receipt_path).read_text(encoding="utf-8").splitlines()
]
def validate_receipts(candidate_rows):
    prior_builds = Counter()
    handoff = Counter()
    dispatch = Counter()
    actual_pairs = set()
    for row in candidate_rows:
        event = row.get("event")
        keys = {"schema_version", "event", "source", "edge_id", "inputs_sha256"}
        if event != "build":
            keys.add("instance_id")
        assert set(row) == keys and row.get("schema_version") == 1, (
            f"unknown receipt shape: {row!r}"
        )
        source, edge = row.get("source"), row.get("edge_id")
        actual_pairs.add((source, edge))
        assert (source, edge) in expected_pairs, f"unknown receipt source/edge: {row!r}"
        digest = row.get("inputs_sha256")
        assert isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), (
            f"invalid receipt digest: {row!r}"
        )
        correlation = (source, edge, digest)
        if event == "build":
            prior_builds[correlation] += 1
            continue
        assert event in {"handoff", "dispatch"}, f"unknown receipt event: {row!r}"
        instance = row.get("instance_id")
        assert expected.get(instance) == (source, edge), f"unknown receipt chain: {row!r}"
        assert prior_builds[correlation] >= 1, (
            f"unmatched prior build digest: {row!r}"
        )
        target = handoff if event == "handoff" else dispatch
        target[(source, edge, instance, digest)] += 1

    # Inverted expectation for every review_pr.ci.* edge (#383): each one's
    # input closure MUST still run (>=1 build receipt) and NONE of them may
    # reach a terminal receipt, because Phase 3 dispatches through the Workflow
    # engine rather than through the routed adapter.
    for retired_edge in sorted(retired_edges):
        retired_builds = [
            row for row in candidate_rows
            if row["edge_id"] == retired_edge and row["event"] == "build"
        ]
        retired_terminals = [
            row for row in candidate_rows
            if row["edge_id"] == retired_edge and row["event"] != "build"
        ]
        assert retired_builds, f"routed edge lost its input closure: {retired_edge}"
        assert not retired_terminals, (
            f"routed surface regressed: {retired_edge} emitted a terminal receipt: "
            f"{retired_terminals!r}"
        )

    assert actual_pairs == expected_pairs and len(actual_pairs) == 17, (
        f"unique source/edge closure mismatch: expected={expected_pairs!r} "
        f"actual={actual_pairs!r}"
    )
    assert handoff == expected_correlated, (
        f"incomplete handoff correlations: expected={expected_correlated!r} actual={handoff!r}"
    )
    assert dispatch == expected_correlated, (
        f"incomplete dispatch correlations: expected={expected_correlated!r} actual={dispatch!r}"
    )

try:
    validate_receipts(rows)
except AssertionError as error:
    raise SystemExit(str(error))

# Positive mutation: successful validation may emit an additional identical
# build snapshot. Cardinality is open for builds, but closed for terminals.
extra_build = copy.deepcopy(rows)
first_handoff = next(index for index, row in enumerate(extra_build) if row["event"] == "handoff")
source = extra_build[first_handoff]["source"]
edge = extra_build[first_handoff]["edge_id"]
digest = extra_build[first_handoff]["inputs_sha256"]
matching_build = next(
    row for row in extra_build[:first_handoff]
    if (row["event"], row["source"], row["edge_id"], row["inputs_sha256"])
    == ("build", source, edge, digest)
)
extra_build.insert(first_handoff, copy.deepcopy(matching_build))
validate_receipts(extra_build)

def assert_rejected(candidate_rows, needle):
    try:
        validate_receipts(candidate_rows)
    except AssertionError as error:
        assert needle in str(error), (needle, str(error))
    else:
        raise AssertionError(f"receipt mutation accepted: {needle}")

# Negative mutation: a handoff/dispatch pair may agree with each other yet is
# incomplete unless its digest appeared in a prior build snapshot.
unmatched = copy.deepcopy(rows)
used_digests = {row["inputs_sha256"] for row in unmatched}
unmatched_digest = next(char * 64 for char in "0123456789abcdef" if char * 64 not in used_digests)
first_instance = unmatched[first_handoff]["instance_id"]
for row in unmatched:
    if row.get("instance_id") == first_instance and row["event"] in {"handoff", "dispatch"}:
        row["inputs_sha256"] = unmatched_digest
assert_rejected(unmatched, "unmatched prior build digest")

# Negative mutation: open build cardinality does not admit an unknown
# source/edge pair.
unknown_extra = copy.deepcopy(rows)
unknown_build = copy.deepcopy(matching_build)
unknown_build["edge_id"] = "review_pr.review.unknown"
unknown_extra.insert(first_handoff, unknown_build)
assert_rejected(unknown_extra, "unknown receipt source/edge")

provider_rows = [
    json.loads(line)
    for line in Path(provider_path).read_text(encoding="utf-8").splitlines()
]
run_dir = str(Path(handoff_dir).parent)

def validate_provider(candidate_rows):
    actual = Counter()
    for row in candidate_rows:
        assert set(row) == {
            "source", "edge_id", "instance_id", "adapter_decision", "args"
        }, f"unknown provider record: {row!r}"
        source, edge, instance = row["source"], row["edge_id"], row["instance_id"]
        assert expected.get(instance) == (source, edge), f"unknown provider call: {row!r}"
        args = row["args"]
        assert isinstance(args, list) and len(args) == 7, f"provider argc mismatch: {row!r}"
        expected_args = [
            "workflow",
            "73",
            "medium",
            f"{run_dir}/children/{instance}/prompt.txt",
            f"{run_dir}/children/{instance}/result.md",
            f"{run_dir}/children/{instance}/status.json",
            row["adapter_decision"],
        ]
        assert args == expected_args, (
            f"provider args mismatch: expected={expected_args!r} actual={args!r}"
        )
        decision = json.loads(row["adapter_decision"])
        assert isinstance(decision, dict) and decision.get("backend") == "workflow", (
            f"invalid provider decision: {row!r}"
        )
        actual[(source, edge, instance)] += 1
    expected_calls = Counter(
        (source, edge, instance)
        for instance, (source, edge) in expected.items()
        if instance != f"review-pr-{run_id}-bind-failure-attempt01"
    )
    assert actual == expected_calls, (
        f"provider seam mismatch: expected={expected_calls!r} actual={actual!r}"
    )

validate_provider(provider_rows)
bad_args = copy.deepcopy(provider_rows)
bad_args[0]["args"][1] = "74"
try:
    validate_provider(bad_args)
except AssertionError as error:
    assert "provider args mismatch" in str(error), str(error)
else:
    raise AssertionError("bad provider arguments mutation accepted")

lifecycle_rows = [
    json.loads(line)
    for line in Path(lifecycle_path).read_text(encoding="utf-8").splitlines()
]

def validate_lifecycle(candidate_rows, residual_leases):
    events = {instance: [] for instance in expected}
    for row in candidate_rows:
        instance = row.get("run_id")
        assert instance in expected, f"unknown lifecycle instance: {row!r}"
        handoff_value = json.loads(actual_files[instance].read_text(encoding="utf-8"))
        assert row.get("agent_id") == instance, f"lifecycle agent mismatch: {row!r}"
        assert row.get("parent_run_id") == "review-receipt-root", (
            f"lifecycle parent mismatch: {row!r}"
        )
        assert row.get("backend") == "workflow" and row.get("workflow") == "review-pr", (
            f"lifecycle routing mismatch: {row!r}"
        )
        assert row.get("phase") == handoff_value["phase"], f"lifecycle phase mismatch: {row!r}"
        assert row.get("role") == handoff_value["role"], f"lifecycle role mismatch: {row!r}"
        if not (
            instance == f"review-pr-{run_id}-bind-failure-attempt01"
            and row.get("event") in {"failed", "timed_out", "cancelled", "abandoned"}
        ):
            assert row.get("risk_signals") == handoff_value["risk_signals"], (
                f"lifecycle risk mismatch: {row!r}"
            )
        events[instance].append(row.get("event"))
    for instance, sequence in events.items():
        if instance == f"review-pr-{run_id}-bind-failure-attempt01":
            assert len(sequence) == 3 and sequence[:2] == ["route_decided", "agent_started"] \
                and sequence[2] in {"failed", "timed_out", "cancelled", "abandoned"}, (
                    f"incomplete bind-failure lifecycle for {instance}: {sequence!r}"
                )
        else:
            assert sequence == ["route_decided", "agent_started", "completed"], (
                f"incomplete lifecycle for {instance}: {sequence!r}"
            )
    assert len(candidate_rows) == len(expected) * 3, (
        f"unknown lifecycle count: expected={len(expected) * 3} actual={len(candidate_rows)}"
    )
    assert residual_leases == [], f"residual capacity leases: {residual_leases!r}"

leases = sorted(str(path) for path in Path(semaphore_root).rglob("*.lease"))
validate_lifecycle(lifecycle_rows, leases)
try:
    validate_lifecycle(lifecycle_rows, ["fixture-leaked-capacity.lease"])
except AssertionError as error:
    assert "residual capacity leases" in str(error), str(error)
else:
    raise AssertionError("capacity lease mutation accepted")
PY

export HANDOFFS CHANGED_PATHS_JSON EMPHASIS_JSON DIFF_PATH CRITERIA_FIXTURE FORMAT_EXAMPLE
export HOSTILE_DIR POST_FINAL SIMPLIFY_FINAL COMMIT_RANGE_FIXTURE
export POST_FINAL_SHA256 SIMPLIFY_FINAL_SHA256 COMMIT_RANGE_SHA256
export PHASE1_DISPOSITION_FIXTURE PHASE2_DISPOSITION_FIXTURE
export PHASE1_AUTHORITY_FIXTURE PHASE2_AUTHORITY_FIXTURE
export PHASE1_AUTHORITY_SHA256_FIXTURE PHASE2_AUTHORITY_SHA256_FIXTURE
export CLASSIFICATION_PATH CI_LOG_CONTENT CI_LOG_SHA256 CI_REFUSED_AGGREGATE_PATH CONFLICT_PATH
export failure_class signal_anchor
export CI_RUN_ID FOCUS CI_CLASSIFICATION_HEAD_SHA CI_BASE_SHA pr_head_branch base_branch BASE_SHA
export CLASSIFY_INPUTS_CAPTURE

# Exact payload assertions catch wrong callsite variable mappings while retaining
# hostile quotes, whitespace, backslashes, globs, arrays, dynamic simplify
# edges, retry optionals, and manifest-typed scalar focus.
python3 -I -B - <<'PY'
import json
import os
from pathlib import Path

env = os.environ
handoff_root = Path(env["HANDOFFS"])
run_id = env["RUN_ID"]

def handoff(instance):
    path = handoff_root / f"{instance}.json"
    if not path.is_file():
        raise SystemExit(f"missing production handoff: {instance}")
    return json.loads(path.read_text(encoding="utf-8"))

def exact(instance, expected):
    actual = handoff(instance).get("inputs")
    if actual != expected:
        raise SystemExit(
            f"payload mismatch for {instance}: expected={expected!r} actual={actual!r}"
        )

changed = json.loads(env["CHANGED_PATHS_JSON"])
emphasis = json.loads(env["EMPHASIS_JSON"])
if not isinstance(changed, list) or not isinstance(emphasis, list):
    raise SystemExit("post-review changed_paths/emphasis lost array types")
review_base = {
    "changed_paths": changed,
    "diff_path": env["DIFF_PATH"],
    "criteria_path": env["CRITERIA_FIXTURE"],
    "emphasis": emphasis,
}
post_edges = (
    "correctness", "silent_failures", "types", "comments", "tests", "general"
)
for index, suffix in enumerate(post_edges, 1):
    expected = dict(review_base)
    if suffix == "general":
        expected["lens"] = "general"
    exact(f"post-review-{run_id}-r{index}-iter7-attempt01", expected)
exact(
    f"post-review-{run_id}-r3-iter7-attempt02",
    review_base | {
        "format_retry": True,
        "format_example_path": env["FORMAT_EXAMPLE"],
    },
)

phase1 = {
    "findings_path": env["POST_FINAL"],
    "findings_sha256": env["POST_FINAL_SHA256"],
    "commit_range_path": env["COMMIT_RANGE_FIXTURE"],
    "commit_range_sha256": env["COMMIT_RANGE_SHA256"],
    "working_dir": env["MUTATION_WORKTREE"],
    "pr_number": 73,
    "disposition_path": env["PHASE1_DISPOSITION_FIXTURE"],
    "authority_path": env["PHASE1_AUTHORITY_FIXTURE"],
    "authority_sha256": env["PHASE1_AUTHORITY_SHA256_FIXTURE"],
}
exact(f"review-pr-{run_id}-fix-phase1-iter7-attempt01", phase1)

for lens in ("reuse", "quality", "efficiency"):
    exact(
        f"review-pr-{run_id}-simplify-{lens}-iter7-attempt01",
        {
            "diff_path": env["DIFF_PATH"],
            "lens": lens,
            "focus": env["FOCUS"],
        },
    )
    exact(
        f"review-pr-{run_id}-simplify-{lens}-iter8-attempt01",
        {
            "diff_path": env["DIFF_PATH"],
            "lens": lens,
        },
    )

exact(
    f"review-pr-{run_id}-fix-phase2-iter7-attempt01",
    phase1 | {
        "findings_path": env["SIMPLIFY_FINAL"],
        "findings_sha256": env["SIMPLIFY_FINAL_SHA256"],
        "disposition_path": env["PHASE2_DISPOSITION_FIXTURE"],
        "authority_path": env["PHASE2_AUTHORITY_FIXTURE"],
        "authority_sha256": env["PHASE2_AUTHORITY_SHA256_FIXTURE"],
    },
)
exact(
    f"review-pr-{run_id}-defer-findings-iter7-attempt01",
    {
        "phase1_path": env["POST_FINAL"],
        "phase2_path": env["SIMPLIFY_FINAL"],
        "phase1_disposition_path": env["PHASE1_DISPOSITION_FIXTURE"],
        "phase2_disposition_path": env["PHASE2_DISPOSITION_FIXTURE"],
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
    },
)
# RETIRED SURFACE (#381), INVERTED -- not dropped. The classify child is
# refused at plugins/uberdev/commands/review-pr.md:3305 before it can reach a
# handoff, so this payload is asserted against the closure the production
# builder at :3285 actually produced (captured off the refusing subshell's EXIT
# trap), and the handoff is asserted ABSENT. The inline log bytes still have to
# be the ones captured BEFORE the controller-only source file was replaced.
classify_instance = f"review-pr-{run_id}-ci-classify-iter3-attempt01"
if (handoff_root / f"{classify_instance}.json").exists():
    raise SystemExit(
        f"retired surface regressed: {classify_instance} reached a handoff despite "
        "the #381 transport gate"
    )
classify_actual = json.loads(
    Path(env["CLASSIFY_INPUTS_CAPTURE"]).read_text(encoding="utf-8")
)
classify_expected = {
    "pr_number": 73,
    "run_id": env["CI_RUN_ID"],
    "head_sha": env["CI_CLASSIFICATION_HEAD_SHA"],
    "log_content": env["CI_LOG_CONTENT"],
    "log_sha256": env["CI_LOG_SHA256"],
}
if classify_actual != classify_expected:
    raise SystemExit(
        f"payload mismatch for review_pr.ci.classify: expected={classify_expected!r} "
        f"actual={classify_actual!r}"
    )
# The other four review_pr.ci.* edges are asserted the same way, and for the
# same reason (#383): they are dispatched by skills/review-fleet/workflow.js, so
# no ROUTED handoff exists to read. The PAYLOAD oracle is what this file is for,
# and it is unchanged -- hostile quoting, tabs, backslashes and globs still have
# to survive the projection byte-for-byte.
def exact_capture(edge, capture_key, expected):
    path = Path(env[capture_key])
    if not path.is_file() or not path.read_text(encoding="utf-8"):
        raise SystemExit(f"{edge}: builder never produced an input closure")
    actual = json.loads(path.read_text(encoding="utf-8"))
    if actual != expected:
        raise SystemExit(
            f"payload mismatch for {edge}: expected={expected!r} actual={actual!r}"
        )
    routed = handoff_root / f"review-pr-{run_id}-{edge.rsplit('.', 1)[1]}.json"
    if routed.exists():
        raise SystemExit(f"routed surface regressed: {edge} reached a routed handoff")

exact_capture(
    "review_pr.ci.fix_code", "CI_FIX_INPUTS_CAPTURE",
    {
        "failure_class": env["failure_class"],
        "signal_anchor": env["signal_anchor"],
        "run_id": env["CI_RUN_ID"],
        "head_sha": env["CI_CLASSIFICATION_HEAD_SHA"],
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
    },
)
exact_capture(
    "review_pr.ci.rebase", "CI_REBASE_INPUTS_CAPTURE",
    {
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
        "head_sha": env["CI_CLASSIFICATION_HEAD_SHA"],
        "base_sha": env["CI_BASE_SHA"],
    },
)
exact_capture(
    "review_pr.ci.defer_refusal", "CI_DEFER_INPUTS_CAPTURE",
    {
        "phase1_path": str(Path(env["POST_FINAL"]).parent / "ci-refused-synthetic-3.md"),
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
    },
)
exact_capture(
    "review_pr.ci.resolve_conflict", "CONFLICT_INPUTS_CAPTURE",
    {
        "file_path": env["CONFLICT_PATH"],
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_branch": env["pr_head_branch"],
        "integration_branch": env["base_branch"],
        "base_sha": env["CI_BASE_SHA"],
    },
)

# Edge -> risk-signal mapping. `review_pr.ci.classify` stays listed even though
# #381 retired its dispatch: this is the declared mapping, not an expectation of
# presence, and the loop below only visits handoffs that actually exist.
subtask_edges = {
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
    "review_pr.simplify.reuse",
    "review_pr.simplify.quality",
    "review_pr.simplify.efficiency",
    "review_pr.ci.classify",
}
for path in handoff_root.glob("*.json"):
    value = json.loads(path.read_text(encoding="utf-8"))
    expected_risks = [] if value["edge_id"] in subtask_edges else ["security"]
    if value.get("risk_signals") != expected_risks:
        raise SystemExit(f"risk mapping mismatch: {value['instance_id']}")
PY

# Fast source-scoped mutation proof. A byte-good alternate copy is rejected by
# physical source identity, while a corrupted copy executes only the extracted
# roster/build/record callsite and is rejected by the payload oracle. No child
# dispatches are repeated.
GOOD_COPY="$TMP/post-good-copy.md"
CORRUPTED_COPY="$TMP/post-corrupted.md"
CORRUPTED_ROSTER="$TMP/post-corrupted-roster.sh"
python3 -I -B - "$POST" "$GOOD_COPY" "$CORRUPTED_COPY" "$CORRUPTED_ROSTER" <<'PY'
import re
import sys
from pathlib import Path

source_path, good_path, corrupted_path, roster_path = map(Path, sys.argv[1:])
source = source_path.read_text(encoding="utf-8")
good_path.write_text(source, encoding="utf-8")
old = 'diff_path "$(post_review_json_string "$DIFF_ARTIFACT_PATH")"'
new = 'diff_path "$(post_review_json_string "$CRITERIA_PATH")"'
if source.count(old) != 2:
    raise SystemExit("mutation target count drifted")
corrupted = source.replace(old, new)
corrupted_path.write_text(corrupted, encoding="utf-8")

fence = re.escape(chr(96) * 3)
matches = [
    match.group(2)
    for match in re.finditer(
        rf"^[ \t]*{fence}bash(?: ([^\n]*))?\n(.*?)\n[ \t]*{fence}$",
        corrupted,
        re.MULTILINE | re.DOTALL,
    )
    if (match.group(1) or "").strip() == "uberdev-executable setup=post-impl-review"
]
if len(matches) != 1 or matches[0].count("REVIEW_EDGES=(") != 1:
    raise SystemExit("corrupted source roster extraction drifted")
_prefix, roster = matches[0].split("REVIEW_EDGES=(", 1)
roster_path.write_text("REVIEW_EDGES=(" + roster.rstrip() + "\n", encoding="utf-8")
PY
bash -n "$CORRUPTED_ROSTER"

GOOD_COPY_SOURCE="$(review_source_label "$GOOD_COPY")"
CORRUPTED_COPY_SOURCE="$(review_source_label "$CORRUPTED_COPY")"
[ "$GOOD_COPY_SOURCE" != "$CANONICAL_POST_SOURCE" ]
[ "$CORRUPTED_COPY_SOURCE" != "$CANONICAL_POST_SOURCE" ]
if review_require_canonical_source "$GOOD_COPY" "$CANONICAL_POST_SOURCE"; then
  echo 'good alternate source copy masqueraded as canonical' >&2
  exit 1
fi
if review_require_canonical_source "$CORRUPTED_COPY" "$CANONICAL_POST_SOURCE"; then
  echo 'corrupted alternate source copy masqueraded as canonical' >&2
  exit 1
fi

MUTATION_RESEARCH="$TMP/source-mutation"
mkdir -p "$MUTATION_RESEARCH"
(
  UBERDEV_CHILD_TEST_MODE=0
  RESEARCH_DIR_ABS="$MUTATION_RESEARCH"
  REVIEW_ITERATION=7
  post_review_fanout() { :; }
  post_review_wait_all() { :; }
  . "$CORRUPTED_ROSTER"
)
python3 -I -B - "$BASE_REVIEW_RECORDS" "$MUTATION_RESEARCH/post-review.records" \
  "$DIFF_PATH" "$CRITERIA_FIXTURE" <<'PY'
import json
import sys
from pathlib import Path

baseline_path, corrupted_path, expected_diff, criteria_path = sys.argv[1:]

def validate_post_records(path):
    rows = [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()]
    if len(rows) != 6:
        raise AssertionError(f"incomplete post-review roster: {len(rows)}")
    for row in rows:
        actual = row.get("inputs", {}).get("diff_path")
        if actual != expected_diff:
            raise AssertionError(
                f"payload mismatch for {row.get('instance')}: "
                f"expected={expected_diff!r} actual={actual!r}"
            )

validate_post_records(baseline_path)
try:
    validate_post_records(corrupted_path)
except AssertionError as error:
    if "payload mismatch" not in str(error):
        raise
    corrupted_rows = [
        json.loads(line)
        for line in Path(corrupted_path).read_text(encoding="utf-8").splitlines()
    ]
    if any(row.get("inputs", {}).get("diff_path") != criteria_path for row in corrupted_rows):
        raise AssertionError("corrupted callsite did not execute the wrong criteria mapping")
else:
    raise AssertionError("corrupted canonical callsite mutation accepted")
PY

# Early setup failures must not strand private fixture directories. Run these
# probes last so each child exits before production extraction or dispatch.
review_fixture_snapshot() {
  find "$ROOT/tests/_fixtures" -maxdepth 1 -type d \
    -name 'review-child-inputs.*' -print | LC_ALL=C sort
}

review_fixture_count() {
  review_fixture_snapshot | awk 'END { print NR + 0 }'
}

review_remove_probe_leaks() {
  local before="$1" after="$2" leaked
  while IFS= read -r leaked; do
    [ -n "$leaked" ] || continue
    case "$leaked" in
      "$ROOT/tests/_fixtures/review-child-inputs."??????)
        rm -rf -- "$leaked"
        ;;
      *)
        echo "refusing to remove unexpected early-failure fixture: $leaked" >&2
        return 1
        ;;
    esac
  done < <(comm -13 "$before" "$after")
}

review_assert_early_failure_clean() {
  local name="$1" expected="$2" mode="$3"
  local before="$TMP/$name.before" after="$TMP/$name.after" log="$TMP/$name.log"
  local before_count after_count rc=0 fixtures_changed=0
  review_fixture_snapshot >"$before"
  before_count="$(review_fixture_count)"

  set +e
  case "$mode" in
    noncanonical)
      REVIEW_EARLY_PROBE_CHILD=1 \
        REVIEW_POST_UNDER_TEST="$GOOD_COPY" \
        REVIEW_PR_UNDER_TEST="$REVIEW" \
        bash "$ROOT/tests/review-child-inputs.test.sh" >"$log" 2>&1
      rc=$?
      ;;
    suffix)
      REVIEW_EARLY_PROBE_CHILD=1 \
        REVIEW_POST_UNDER_TEST="$POST" \
        REVIEW_PR_UNDER_TEST="$REVIEW" \
        REVIEW_REAL_PYTHON3="$REAL_PYTHON3" \
        PATH="$SUFFIX_FAIL_BIN:$PATH" \
        bash "$ROOT/tests/review-child-inputs.test.sh" >"$log" 2>&1
      rc=$?
      ;;
    *)
      echo "unknown early-failure probe mode: $mode" >&2
      rc=2
      ;;
  esac
  set -e

  review_fixture_snapshot >"$after"
  after_count="$(review_fixture_count)"
  if [ "$before_count" -ne "$after_count" ] || ! cmp -s "$before" "$after"; then
    fixtures_changed=1
    review_remove_probe_leaks "$before" "$after"
  fi
  if [ "$rc" -eq 0 ]; then
    echo "$name unexpectedly succeeded" >&2
    return 1
  fi
  if ! grep -Fq "$expected" "$log"; then
    echo "$name failed without expected diagnostic: $expected" >&2
    sed -n '1,20p' "$log" >&2
    return 1
  fi
  if [ "$fixtures_changed" -ne 0 ]; then
    echo "$name changed fixture count: before=$before_count after=$after_count" >&2
    return 1
  fi
}

if [ "${REVIEW_EARLY_PROBE_CHILD:-0}" != 1 ]; then
  SUFFIX_FAIL_BIN="$TMP/suffix-fail-bin"
  REAL_PYTHON3="$(command -v python3)"
  mkdir -p "$SUFFIX_FAIL_BIN"
  cat >"$SUFFIX_FAIL_BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = '-I' ] && [ "${2-}" = '-B' ] && [ "${3-}" = '-c' ] && \
    [ "${4-}" = 'import secrets; print(secrets.token_hex(6),end="")' ]; then
  echo 'forced suffix generation failure' >&2
  exit 91
fi
exec "$REVIEW_REAL_PYTHON3" "$@"
SH
  chmod 700 "$SUFFIX_FAIL_BIN/python3"

  EARLY_PROBE_FAILURES=0
  review_assert_early_failure_clean \
    noncanonical-source 'post source-under-test is not canonical' noncanonical || \
    EARLY_PROBE_FAILURES=$((EARLY_PROBE_FAILURES + 1))
  review_assert_early_failure_clean \
    suffix-generation 'forced suffix generation failure' suffix || \
    EARLY_PROBE_FAILURES=$((EARLY_PROBE_FAILURES + 1))
  [ "$EARLY_PROBE_FAILURES" -eq 0 ] || exit 1
fi

printf 'review-child-inputs: PASS (17 unique source/edge pairs; 17 complete chains + 5 build-only review_pr.ci.* edges, dual simplify focus, lifecycle closed)\n'
