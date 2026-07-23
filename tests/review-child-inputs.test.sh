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
write("review-scope.sh", containing(review, 'review_refresh_phase1_scope "$BASE_SHA"'))

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

write("review-phase1.sh", containing(review, 'PHASE1_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase1'))
write("review-simplify.sh", containing(review, 'SIMPLIFY_RECORDS="$RESEARCH_DIR_ABS/simplify.records"'))
write("review-phase2.sh", containing(review, 'PHASE2_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase2'))
write("review-defer.sh", containing(review, 'DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.defer.findings'))
write("review-classify.sh", containing(review, 'CI_CLASSIFY_INPUTS="$(uberdev_child_inputs_build review_pr.ci.classify'))
write("review-defer-refusal.sh", containing(review, 'CI_DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.ci.defer_refusal'))
write("review-conflict.sh", containing(review, 'CONFLICT_RECORDS="$RESEARCH_DIR_ABS/conflicts.records"'))

route = containing(review, 'CI_FIX_INPUTS="$(uberdev_child_inputs_build review_pr.ci.fix_code')

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
        selected.append(line.strip())
        if line.rstrip().endswith(')"'):
            break
    else:
        raise SystemExit(f"{variable} constructor terminator missing")
    return "\n".join(selected)

fix_dispatch = re.search(
    r"^\s*code_bug \| env_drift\)\s*(review_child_single review_pr\.ci\.fix_code .*?)\s*;;$",
    route,
    re.MULTILINE,
)
rebase_dispatch = re.search(
    r"^\s*stale_base\)\s*(review_child_single review_pr\.ci\.rebase .*?)\s*;;$",
    route,
    re.MULTILINE,
)
if fix_dispatch is None or rebase_dispatch is None:
    raise SystemExit("review CI route dispatch arms drifted")
write(
    "review-ci-builders.sh",
    assignment(route, "CI_FIX_INPUTS") + "\n" + assignment(route, "CI_REBASE_INPUTS"),
)
write("review-ci-fix-dispatch.sh", fix_dispatch.group(1))
write("review-ci-rebase-dispatch.sh", rebase_dispatch.group(1))
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
    "backend": "codex",
    "workflow": "review-pr",
    "phase": "lead",
    "role": "lead",
    "task_tier": "medium",
    "risk_signals": ["security"],
    "issue_or_pr": 73,
    "issue_num": 73,
    "capacity": 20,
    "timeout_s": 20,
    "routing_mode": "adaptive",
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
    "backend": "codex",
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
export CI_RUN_ID=$'run "quoted" \\id *?[x]\t'
export FOCUS=$'focus "quoted" \\glob*?[x]\t'

. "$TMP/review-setup.sh"
. "$TMP/review-builder.sh"
REVIEW_WORKSPACE_JSON="$UBERDEV_COMMAND_WORKSPACE_JSON"

# Keep every production layer through child-dispatch. Only the immediate final
# provider seam is replaced, and it refuses to run before its correlated
# dispatch receipt is durable.
HANDOFFS="$CARRIER_RUN/handoffs"
STATE_DIR="$CARRIER_RUN/.agent-state-$(id -u)"
LIFECYCLE="$STATE_DIR/agent-lifecycle.jsonl"
SEMAPHORE_ROOT="$STATE_DIR/semaphore-v1"

review_provider_args_validate() {
  [ "$#" -eq 7 ] || return 1
  local backend="$1" issue="$2" tier="$3" prompt="$4" result="$5" status="$6" decision="$7"
  local instance
  instance="$(basename "$(dirname "$status")")"
  [ "$backend" = codex ] || return 1
  [ "$issue" = 73 ] || return 1
  [ "$tier" = medium ] || return 1
  [ "$prompt" = "$CARRIER_RUN/children/$instance/prompt.txt" ] || return 1
  [ "$result" = "$CARRIER_RUN/children/$instance/result.md" ] || return 1
  [ "$status" = "$CARRIER_RUN/children/$instance/status.json" ] || return 1
  [ -n "${UBERDEV_AGENT_DECISION_JSON:-}" ] || return 1
  [ "$decision" = "$UBERDEV_AGENT_DECISION_JSON" ] || return 1
}

_uberdev_agent_dispatch_backend() {
  local backend="$1" prompt="$4" result="$5" status="$6"
  local instance edge
  review_provider_args_validate "$@" || {
    echo 'review-child-inputs: invalid provider arguments' >&2
    return 2
  }
  instance="$(basename "$(dirname "$status")")"
  edge="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["edge_id"],end="")' "$HANDOFFS/$instance.json")"
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
  printf 'fixture result for %s\n' "$instance" >"$result"
  chmod 600 "$result"
  DISPATCH_ID="fixture-$instance"
  printf '{"backend":"codex","state":"running","exit_code":null,"pid":"fixture-%s"}\n' "$instance" >"$status"
  chmod 600 "$status"
  python3 -I -B - "$status" <<'PY' &
import json
import os
import tempfile
import time
import sys

path = sys.argv[1]
for _attempt in range(500):
    try:
        value = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        value = {}
    if value.get("state") == "running" and value.get("lease_generation"):
        break
    time.sleep(0.01)
else:
    raise SystemExit("adapter did not publish lease generation")
value["state"] = "completed"
value["exit_code"] = 0
descriptor, temporary = tempfile.mkstemp(prefix=".fixture-complete.", dir=os.path.dirname(path))
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
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
SCOPE_BIN="$TMP/scope-bin"
mkdir -p "$SCOPE_BIN"
cat >"$SCOPE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '{"baseRefOid":"%s","baseRefName":"main"}\n' "$SCOPE_EXPECTED_BASE"
SH
chmod +x "$SCOPE_BIN/gh"
export SCOPE_EXPECTED_BASE
printf 'initial change\n' >>"$SCOPE_REPO/base.txt"
git -C "$SCOPE_REPO" add base.txt
git -C "$SCOPE_REPO" commit -qm 'test: create initial review change'
(
  PATH="$SCOPE_BIN:$PATH"
  WORKTREE_ROOT="$SCOPE_REPO"
  DIFF_ARTIFACT_PATH="$TMP/scope-diff.md"
  COMMIT_RANGE_PATH="$TMP/scope-range.txt"
  PR_NUMBER=73
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
CI_LOG_ARTIFACT_PATH="$HOSTILE_DIR"$'/ci "log" \\path*.txt'
CI_REFUSED_AGGREGATE_PATH="$HOSTILE_DIR"$'/refused "aggregate" \\path*.md'
CONFLICT_PATH="$HOSTILE_DIR"$'/conflict "quoted" \\path*.ts'

for fixture in \
  "$DIFF_PATH" "$CRITERIA_FIXTURE" "$FORMAT_EXAMPLE" \
  "$POST_FINAL" "$SIMPLIFY_FINAL" "$COMMIT_RANGE_FIXTURE" \
  "$PHASE1_DISPOSITION_FIXTURE" "$PHASE2_DISPOSITION_FIXTURE" \
  "$CLASSIFICATION_PATH" "$CI_LOG_ARTIFACT_PATH" "$CI_REFUSED_AGGREGATE_PATH" \
  "$CONFLICT_PATH"; do
  printf 'private hostile review fixture: %s\n' "${fixture##*/}" >"$fixture"
  chmod 600 "$fixture"
done

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
FAILED_REVIEW_EDGE=review_pr.review.types
FAILED_REVIEW_INDEX=3
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
findings_path="$POST_FINAL"
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
(. "$TMP/review-classify.sh") & wave+=("$!")
review_wait_jobs "${wave[@]}"

CI_CLASSIFICATION_PATH="$RESEARCH_DIR_ABS/ci-classification-${CI_FIX_LOOP_ITER:-1}.yaml"
printf 'fixture classifier output\n' >"$CI_CLASSIFICATION_PATH"
chmod 600 "$CI_CLASSIFICATION_PATH"
CLASSIFICATION_PATH="$CI_CLASSIFICATION_PATH"

CI_HEAD_SHA=$'head "quoted" \\sha*?[x]\t'
CI_BASE_SHA=$'base "quoted" \\sha*?[x]\t'
. "$TMP/review-ci-builders.sh"

conflicted_files=("$CONFLICT_PATH")
REPO_ROOT="$MUTATION_WORKTREE"
pr_head_branch=$'feature/"quoted"\\branch*?[x]\t'
base_branch=$'main-"quoted"\\branch*?[x]\t'
BASE_SHA=$'conflict-base-"quoted"\\sha*?[x]\t'

wave=()
(
  REVIEW_ITERATION=8
  FOCUS=
  . "$TMP/review-simplify.sh"
) & wave+=("$!")
(. "$TMP/review-ci-fix-dispatch.sh") & wave+=("$!")
(. "$TMP/review-ci-rebase-dispatch.sh") & wave+=("$!")
(. "$TMP/review-defer-refusal.sh") & wave+=("$!")
(. "$TMP/review-conflict.sh") & wave+=("$!")
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
    ("review_pr.simplify.reuse", f"review-pr-{run_id}-simplify-reuse-iter7-attempt01"),
    ("review_pr.simplify.quality", f"review-pr-{run_id}-simplify-quality-iter7-attempt01"),
    ("review_pr.simplify.efficiency", f"review-pr-{run_id}-simplify-efficiency-iter7-attempt01"),
    ("review_pr.simplify.reuse", f"review-pr-{run_id}-simplify-reuse-iter8-attempt01"),
    ("review_pr.simplify.quality", f"review-pr-{run_id}-simplify-quality-iter8-attempt01"),
    ("review_pr.simplify.efficiency", f"review-pr-{run_id}-simplify-efficiency-iter8-attempt01"),
    ("review_pr.fix.phase2", f"review-pr-{run_id}-fix-phase2-iter7-attempt01"),
    ("review_pr.defer.findings", f"review-pr-{run_id}-defer-findings-iter7-attempt01"),
    ("review_pr.ci.classify", f"review-pr-{run_id}-ci-classify-iter3-attempt01"),
    ("review_pr.ci.fix_code", f"review-pr-{run_id}-ci-fix-iter3-attempt01"),
    ("review_pr.ci.rebase", f"review-pr-{run_id}-ci-rebase-iter3-attempt01"),
    ("review_pr.ci.defer_refusal", f"review-pr-{run_id}-ci-defer-refusal-iter3-attempt01"),
    ("review_pr.ci.resolve_conflict", f"review-pr-{run_id}-conflict-1-iter3-attempt01"),
)
for edge, instance in review_cases:
    expect(review_source, edge, instance)

expected_pairs = set(expected.values())
if len(expected_pairs) != 17 or len(expected) != 21:
    raise SystemExit("invalid receipt expectation fixture")

handoff_root = Path(handoff_dir)
actual_files = {path.stem: path for path in handoff_root.glob("*.json")}
if set(actual_files) != set(expected):
    raise SystemExit(
        f"handoff identity mismatch: expected={sorted(expected)!r} actual={sorted(actual_files)!r}"
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
            "codex",
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
        assert isinstance(decision, dict) and decision.get("backend") == "codex", (
            f"invalid provider decision: {row!r}"
        )
        actual[(source, edge, instance)] += 1
    expected_calls = Counter(
        (source, edge, instance)
        for instance, (source, edge) in expected.items()
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
        assert row.get("backend") == "codex" and row.get("workflow") == "review-pr", (
            f"lifecycle routing mismatch: {row!r}"
        )
        assert row.get("phase") == handoff_value["phase"], f"lifecycle phase mismatch: {row!r}"
        assert row.get("role") == handoff_value["role"], f"lifecycle role mismatch: {row!r}"
        assert row.get("risk_signals") == handoff_value["risk_signals"], (
            f"lifecycle risk mismatch: {row!r}"
        )
        events[instance].append(row.get("event"))
    for instance, sequence in events.items():
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
export PHASE1_DISPOSITION_FIXTURE PHASE2_DISPOSITION_FIXTURE
export CLASSIFICATION_PATH CI_LOG_ARTIFACT_PATH CI_REFUSED_AGGREGATE_PATH CONFLICT_PATH
export CI_RUN_ID FOCUS CI_HEAD_SHA CI_BASE_SHA pr_head_branch base_branch BASE_SHA

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
    "commit_range_path": env["COMMIT_RANGE_FIXTURE"],
    "working_dir": env["MUTATION_WORKTREE"],
    "pr_number": 73,
    "disposition_path": env["PHASE1_DISPOSITION_FIXTURE"],
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
        "disposition_path": env["PHASE2_DISPOSITION_FIXTURE"],
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
exact(
    f"review-pr-{run_id}-ci-classify-iter3-attempt01",
    {
        "pr_number": 73,
        "run_id": env["CI_RUN_ID"],
        "log_path": env["CI_LOG_ARTIFACT_PATH"],
    },
)
exact(
    f"review-pr-{run_id}-ci-fix-iter3-attempt01",
    {
        "classification_path": env["CLASSIFICATION_PATH"],
        "log_path": env["CI_LOG_ARTIFACT_PATH"],
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
    },
)
exact(
    f"review-pr-{run_id}-ci-rebase-iter3-attempt01",
    {
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
        "head_sha": env["CI_HEAD_SHA"],
        "base_sha": env["CI_BASE_SHA"],
    },
)
exact(
    f"review-pr-{run_id}-ci-defer-refusal-iter3-attempt01",
    {
        "phase1_path": str(Path(env["POST_FINAL"]).parent / "ci-refused-synthetic-3.md"),
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_number": 73,
    },
)
exact(
    f"review-pr-{run_id}-conflict-1-iter3-attempt01",
    {
        "file_path": env["CONFLICT_PATH"],
        "working_dir": env["MUTATION_WORKTREE"],
        "pr_branch": env["pr_head_branch"],
        "integration_branch": env["base_branch"],
        "base_sha": env["BASE_SHA"],
    },
)

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

printf 'review-child-inputs: PASS (17 unique source/edge pairs; 21 complete chains, dual simplify focus, lifecycle closed)\n'
