#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMPLIFY="$ROOT/plugins/uberdev/commands/simplify.md"
CONTRACT="$ROOT/plugins/uberdev/lib/code_fixer_contract.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

BUILDER="$TEST_ROOT/builder.sh"
CONTROLLER="$TEST_ROOT/controller.sh"
awk '/# BEGIN simplify-fixer-child-bound-v2/{active=1;next} /# END simplify-fixer-child-bound-v2/{exit} active{print}' "$SIMPLIFY" >"$BUILDER"
awk '/# BEGIN simplify-standalone-controller-v2/{active=1;next} /# END simplify-standalone-controller-v2/{exit} active{print}' "$SIMPLIFY" >"$CONTROLLER"
[ -s "$BUILDER" ] && [ -s "$CONTROLLER" ]
bash -n "$BUILDER"
bash -n "$CONTROLLER"

python3 -I -B - "$CONTRACT" "$0" "$TEST_ROOT" <<'PY'
import contextlib
import builtins
import importlib.util
import io
import json
import ntpath
import os
import pathlib
import sys

contract_path, fixture_path, test_root = sys.argv[1:]
fixture_source = pathlib.Path(fixture_path).read_text(encoding="utf-8")
status_output = os.path.join(test_root, "modeled-windows-status.json")


def load_contract(path):
    spec = importlib.util.spec_from_file_location("simplify_code_fixer_contract", path)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load code fixer contract")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fixture_python_body(marker_parts):
    marker = "".join(marker_parts)
    marker_at = fixture_source.index(marker)
    body_at = fixture_source.rfind("<<'PY'\n", 0, marker_at)
    if body_at < 0:
        raise AssertionError(f"fixture producer missing for {marker}")
    body_at += len("<<'PY'\n")
    body_end = fixture_source.index("\nPY\n", marker_at)
    return fixture_source[body_at:body_end]


def execute_fixture_python(source, arguments, execution_globals=None):
    saved_argv = sys.argv
    output = io.StringIO()
    try:
        sys.argv = ["fixture-producer", *arguments]
        with contextlib.redirect_stdout(output):
            exec(
                compile(source, "<fixture-producer>", "exec"),
                {} if execution_globals is None else dict(execution_globals),
            )
    finally:
        sys.argv = saved_argv
    return output.getvalue()


class WindowsPathModel:
    sep = "\\"
    altsep = "/"
    junction_source = "C:\\Program Files\\Git\\tmp\\prkit-simplify"
    junction_target = "D:\\fixture-junction-target\\prkit-simplify"

    @staticmethod
    def isabs(value):
        drive, tail = ntpath.splitdrive(value)
        return bool(drive and tail.startswith(("\\", "/")))

    @staticmethod
    def abspath(value):
        drive, tail = ntpath.splitdrive(ntpath.normpath(value))
        if not drive or not tail.startswith("\\"):
            raise AssertionError(f"modeled path is not drive-absolute: {value!r}")
        return drive.upper() + tail

    @staticmethod
    def realpath(value):
        absolute = WindowsPathModel.abspath(value)
        source = WindowsPathModel.junction_source
        if absolute == source or absolute.startswith(source + "\\"):
            return WindowsPathModel.junction_target + absolute[len(source):]
        return absolute


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


contract = load_contract(contract_path)
receipt_source = fixture_python_body(
    ("edge,instance,result,", "status=sys.argv[1:]")
)
status_source = fixture_python_body(
    ("path,handle,worktree,", "result=sys.argv[1:]")
)
result_source = fixture_python_body(
    ("disposition,status,commit_sha,", "path=sys.argv[1:]")
)
raw_worktree = "C:/Program Files/Git/tmp/prkit-simplify/repo"
raw_result = (
    "C:/Program Files/Git/tmp/prkit-simplify/repo/.uberdev/research/"
    "20260728-010208-abcdef0/fixer-result.md"
)
raw_status = (
    "C:/Program Files/Git/tmp/prkit-simplify/repo/.uberdev/research/"
    "20260728-010208-abcdef0/fixer-status.json"
)
canonical_worktree = WindowsPathModel.realpath(
    WindowsPathModel.abspath(raw_worktree)
)
canonical_result = WindowsPathModel.realpath(WindowsPathModel.abspath(raw_result))
canonical_status = WindowsPathModel.realpath(WindowsPathModel.abspath(raw_status))
assert WindowsPathModel.abspath(raw_worktree) != canonical_worktree
assert WindowsPathModel.abspath(raw_result) != canonical_result
assert WindowsPathModel.abspath(raw_status) != canonical_status
edge_id = "simplify.fix.phase2"
instance_id = "fixture-instance"
raw_receipt = {
    "schema_version": 1,
    "edge_id": edge_id,
    "instance_id": instance_id,
    "backend": "codex",
    "handle": "12345",
    "state": "completed",
    "result_file": raw_result,
    "status_file": raw_status,
}

result_disposition = os.path.join(test_root, "modeled-windows-disposition.json")
result_output = os.path.join(test_root, "modeled-windows-fixer-result.md")
with builtins.open(result_disposition, "w", encoding="utf-8", newline="\n") as stream:
    json.dump({"findings_disposition": []}, stream)
result_chunks = []


class WindowsTextWriter:
    def __init__(self, newline):
        self.newline = newline

    def write(self, value):
        if self.newline is None:
            translated = value.replace("\n", "\r\n")
        elif self.newline in {"", "\n"}:
            translated = value
        else:
            translated = value.replace("\n", self.newline)
        result_chunks.append(translated)
        return len(value)


def windows_open(path, mode="r", *arguments, **keywords):
    if os.fspath(path) == result_output and mode == "w":
        return WindowsTextWriter(keywords.get("newline"))
    return builtins.open(path, mode, *arguments, **keywords)


execute_fixture_python(
    result_source,
    [result_disposition, "APPLIED", "a" * 40, result_output],
    {"open": windows_open},
)
result_payload = "".join(result_chunks).encode("utf-8")
try:
    parsed_result = contract._parse_fixer_result(result_payload, "phase2", "refactor")
except contract.ContractFailure as error:
    if b"\r" not in result_payload or str(error) != "fixer_result_invalid":
        raise
    raise AssertionError(
        "fixture fixer-result producer emitted CRLF and the real parser rejected it"
    ) from error
if b"\r" in result_payload:
    raise AssertionError("fixture fixer-result producer emitted CRLF")
assert parsed_result["status"] == "APPLIED"
assert parsed_result["commits"][0]["sha"] == "a" * 40

saved_path = contract.os.path
saved_capture = contract._capture_regular
try:
    contract.os.path = WindowsPathModel
    contract._capture_regular = lambda *_arguments: (b"{}", ())
    try:
        contract.bind_launch_receipt(
            receipt=canonical_json(raw_receipt),
            edge_id=edge_id,
            instance_id=instance_id,
            result_path=canonical_result,
            status_path=canonical_status,
            working_dir=canonical_worktree,
        )
    except contract.ContractFailure as error:
        if str(error) != "launch_receipt_path_mismatch":
            raise
    else:
        raise AssertionError("raw alternate Windows receipt spelling reached authority")

    execute_fixture_python(
        status_source, [status_output, "12345", raw_worktree, raw_result]
    )
    with open(status_output, encoding="utf-8") as stream:
        produced_status = json.load(stream)
    produced_receipt = json.loads(
        execute_fixture_python(
            receipt_source, [edge_id, instance_id, raw_result, raw_status]
        )
    )
    actual_paths = {
        "receipt.result_file": produced_receipt["result_file"],
        "receipt.status_file": produced_receipt["status_file"],
        "status.worktree": produced_status["worktree"],
        "status.result": produced_status["result"],
    }
    expected_paths = {
        "receipt.result_file": canonical_result,
        "receipt.status_file": canonical_status,
        "status.worktree": canonical_worktree,
        "status.result": canonical_result,
    }
    if actual_paths != expected_paths:
        raise AssertionError(
            "fixture producer kept alternate Windows spelling: "
            + json.dumps(actual_paths, sort_keys=True)
        )

    status_payload = canonical_json(produced_status)
    contract._capture_regular = lambda *_arguments: (status_payload, ())
    binding = contract.bind_launch_receipt(
        receipt=canonical_json(produced_receipt),
        edge_id=edge_id,
        instance_id=instance_id,
        result_path=canonical_result,
        status_path=canonical_status,
        working_dir=canonical_worktree,
    )
    assert binding["result_path"] == canonical_result
    assert binding["status_path"] == canonical_status
    assert binding["worktree"] == canonical_worktree
finally:
    contract.os.path = saved_path
    contract._capture_regular = saved_capture
PY

write_aggregate() {
  local path="$1" target="${2:-}"
  python3 -I -B - "$target" <<'PY' | python3 -I -B "$CONTRACT" encode-aggregate --phase phase2 >"$path"
import json,sys
target=sys.argv[1]
findings=[] if not target else [{
    "detail":"Use the bounded behavior-preserving refinement.",
    "scope":{"line":1,"operation":"modify_existing","path":target},
    "severity":"suggestion",
    "source_edges":["review_pr.simplify.quality"],
    "summary":"Apply the bounded standalone refinement",
}]
print(json.dumps({
    "contributors":[
        {"confidence":"n/a","id":"review_pr.simplify.reuse","verdict":"COMPLETE"},
        {"confidence":"n/a","id":"review_pr.simplify.quality","verdict":"COMPLETE"},
        {"confidence":"n/a","id":"review_pr.simplify.efficiency","verdict":"COMPLETE"},
    ],
    "findings":findings,"phase":"phase2","schema_version":2,
},sort_keys=True,separators=(",",":")))
PY
}

run_case() (
  set -euo pipefail
  local mode="$1" replacement="$2" case_dir
  case_dir="$TEST_ROOT/$mode-$replacement"
  local repo="$case_dir/repo" evidence="$case_dir/repo/.uberdev/research/20260728-010208-abcdef0"
  mkdir -p "$repo" "$evidence"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  for path in apply.txt keep-staged.txt keep-unstaged.txt keep-both.txt; do
    printf '%s-H0\n' "$path" >"$repo/$path"
  done
  git -C "$repo" add -- apply.txt keep-staged.txt keep-unstaged.txt keep-both.txt
  git -C "$repo" commit -qm 'test: standalone command baseline'
  local parent
  parent="$(git -C "$repo" rev-parse HEAD)"
  printf 'apply-W0\n' >"$repo/apply.txt"
  printf 'keep-staged-I0\n' >"$repo/keep-staged.txt"
  git -C "$repo" add -- keep-staged.txt
  printf 'keep-unstaged-W0\n' >"$repo/keep-unstaged.txt"
  printf 'keep-both-I0\n' >"$repo/keep-both.txt"
  git -C "$repo" add -- keep-both.txt
  printf 'keep-both-W0\n' >"$repo/keep-both.txt"
  printf 'untracked-U0\n' >"$repo/untracked.txt"

  local preserved_path
  for preserved_path in apply.txt keep-staged.txt keep-unstaged.txt keep-both.txt; do
    git -C "$repo" ls-files --stage -- "$preserved_path" >"$case_dir/$preserved_path.index"
    cp "$repo/$preserved_path" "$case_dir/$preserved_path.worktree"
  done

  WORKTREE_ROOT="$(cd "$repo" && pwd -P)"
  RESEARCH_DIR_ABS="$(cd "$evidence" && pwd -P)"
  DIFF_ARTIFACT_PATH="$RESEARCH_DIR_ABS/pr-diff.md"
  STANDALONE_SNAPSHOT_PATH="$RESEARCH_DIR_ABS/standalone-snapshot.json"
  AGG_PATH="$RESEARCH_DIR_ABS/simplify-final.md"
  PHASE2_DISPOSITION_PATH="$RESEARCH_DIR_ABS/phase2-disposition.json"
  CODE_FIXER_CONTRACT="$CONTRACT"
  REVIEW_PR_TIMEOUT=30
  printf '<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n' >"$DIFF_ARTIFACT_PATH"
  : >"$STANDALONE_SNAPSHOT_PATH"
  : >"$PHASE2_DISPOSITION_PATH"
  local snapshot_receipt
  snapshot_receipt="$(python3 -I -B "$CONTRACT" snapshot-standalone --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS" --diff-path "$DIFF_ARTIFACT_PATH" --snapshot-path "$STANDALONE_SNAPSHOT_PATH")"
  STANDALONE_SNAPSHOT_SHA256="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["snapshot_sha256"],end="")' "$snapshot_receipt")"
  STANDALONE_ELIGIBLE_COUNT="$(python3 -I -B -c 'import json,sys;print(len(json.loads(sys.argv[1])["target_eligible_paths"]),end="")' "$snapshot_receipt")"
  if [ "$mode" = zero ]; then
    write_aggregate "$AGG_PATH"
  else
    write_aggregate "$AGG_PATH" apply.txt
  fi

  uberdev_child_inputs_build() {
    python3 -I -B - "$@" <<'PY'
import json,sys
args=sys.argv[2:]
if len(args)%2: raise SystemExit(2)
value={args[i]:json.loads(args[i+1]) for i in range(0,len(args),2)}
print(json.dumps(value,sort_keys=True,separators=(",",":")),end="")
PY
  }
  uberdev_create_child_handoff() {
    FIXTURE_EDGE="$1"; FIXTURE_INSTANCE="$2"; FIXTURE_INPUTS="$3"
    UBERDEV_CHILD_HANDOFF="$RESEARCH_DIR_ABS/fixer-handoff.json"
    UBERDEV_CHILD_RESULT="$RESEARCH_DIR_ABS/fixer-result.md"
    UBERDEV_CHILD_STATUS="$RESEARCH_DIR_ABS/fixer-status.json"
    printf '%s\n' "$FIXTURE_INPUTS" >"$UBERDEV_CHILD_HANDOFF"
    UBERDEV_CHILD_HANDOFF_SHA256="$(python3 -I -B "$CONTRACT" digest --path "$UBERDEV_CHILD_HANDOFF" --minimum 1 --maximum 1048576)"
    export UBERDEV_CHILD_HANDOFF UBERDEV_CHILD_HANDOFF_SHA256 UBERDEV_CHILD_RESULT UBERDEV_CHILD_STATUS
  }
  uberdev_preflight_child_batch() { return 0; }
  fixture_child() {
    local authority_path authority_sha disposition_candidate publish_receipt disposition_sha content_path content_sha commit_sha status_value
    authority_path="$SIMPLIFY_FIXER_AUTHORITY_PATH"
    authority_sha="$SIMPLIFY_FIXER_AUTHORITY_SHA256"
    if [ "$mode" = zero ]; then
      status_value=NO_FIXES_NEEDED
    else
      printf 'apply-FINAL\n' >"$WORKTREE_ROOT/apply.txt"
      status_value=APPLIED
    fi
    disposition_candidate="$(python3 -I -B - "$authority_path" "$status_value" <<'PY'
import json,sys
authority=json.load(open(sys.argv[1],encoding="utf-8")); status=sys.argv[2]
rows=[]
for finding in authority["finding_keys"]:
    rows.append({**finding,"disposition":"APPLIED" if status=="APPLIED" else "SKIPPED","behavior_tag":"preserve" if status=="APPLIED" else "n/a","reason":"bounded command fixture"})
print(json.dumps({"schema_version":1,"phase":"phase2","aggregate_sha256":authority["findings_sha256"],"findings_disposition":rows},sort_keys=True,separators=(",",":")),end="")
PY
)"
    publish_receipt="$(printf '%s' "$disposition_candidate" | python3 -I -B "$CONTRACT" publish-disposition --authority-path "$authority_path" --authority-sha256 "$authority_sha" --disposition-path "$PHASE2_DISPOSITION_PATH")"
    disposition_sha="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["disposition_sha256"],end="")' "$publish_receipt")"
    content_path="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["applied_content_path"],end="")' "$publish_receipt")"
    content_sha="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["applied_content_sha256"],end="")' "$publish_receipt")"
    if [ "$mode" = zero ]; then
      python3 -I -B "$CONTRACT" validate-staged --authority-path "$authority_path" --authority-sha256 "$authority_sha" --disposition-path "$PHASE2_DISPOSITION_PATH" --disposition-sha256 "$disposition_sha" --working-dir "$WORKTREE_ROOT" >/dev/null
      commit_sha=""
    else
      local commit_receipt
      commit_receipt="$(python3 -I -B "$CONTRACT" commit-standalone --authority-path "$authority_path" --authority-sha256 "$authority_sha" --disposition-path "$PHASE2_DISPOSITION_PATH" --disposition-sha256 "$disposition_sha" --applied-content-path "$content_path" --applied-content-sha256 "$content_sha" --working-dir "$WORKTREE_ROOT")"
      commit_sha="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["commit_sha"],end="")' "$commit_receipt")"
    fi
    python3 -I -B - "$PHASE2_DISPOSITION_PATH" "$status_value" "$commit_sha" "$UBERDEV_CHILD_RESULT" <<'PY'
import json,sys
disposition,status,commit_sha,path=sys.argv[1:]
rows=json.load(open(disposition,encoding="utf-8"))["findings_disposition"]
lines=["```yaml",f"status: {status}","phase: phase2"]
if status=="APPLIED": lines += ["commits:",f"  - sha: {commit_sha}","    type: refactor","    summary: bounded authenticated refactor"]
else: lines += ["commits: []"]
if rows:
    lines.append("findings_disposition:")
    for row in rows:
        lines += [f"  - finding_index: {row['finding_index']}",f"    location: {row['location']}",f"    summary_sha256: {row['summary_sha256']}",f"    disposition: {row['disposition']}",f"    behavior_tag: {row['behavior_tag']}",f"    reason: {row['reason']}"]
else: lines.append("findings_disposition: []")
lines += ["risks: []","```"]
open(path,"w",encoding="utf-8",newline="\n").write("\n".join(lines)+"\n")
PY
    local status_handle=12345
    [ "$replacement" != foreign_handle ] || status_handle=54321
    python3 -I -B - "$UBERDEV_CHILD_STATUS" "$status_handle" "$WORKTREE_ROOT" "$UBERDEV_CHILD_RESULT" <<'PY'
import json,os,sys
path,handle,worktree,result=sys.argv[1:]
worktree=os.path.realpath(os.path.abspath(worktree))
result=os.path.realpath(os.path.abspath(result))
value={
    "backend":"codex",
    "branch":"",
    "exit_code":0,
    "lease_generation":"0123456789abcdef0123456789abcdef",
    "pid":handle,
    "process_identity":"12345|12345|12345|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "result":result,
    "state":"completed",
    "workspace_mode":"caller",
    "worktree":worktree,
}
open(path,"w",encoding="utf-8").write(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n")
PY
  }
  uberdev_dispatch_child_capture() {
    fixture_child
    UBERDEV_CHILD_DISPATCH_RECEIPT="$(python3 -I -B - "$1" "$FIXTURE_INSTANCE" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" <<'PY'
import json,os,sys
edge,instance,result,status=sys.argv[1:]
result=os.path.realpath(os.path.abspath(result))
status=os.path.realpath(os.path.abspath(status))
print(json.dumps({"schema_version":1,"edge_id":edge,"instance_id":instance,"backend":"codex","handle":"12345","state":"completed","result_file":result,"status_file":status},sort_keys=True,separators=(",",":")),end="")
PY
)"
  }
  uberdev_wait_child() {
    printf '%s\n' '{"edge":"attacker.rebind","receipt":"fake","result":"/tmp/fake-result","status":"/tmp/fake-status"}' >"$RESEARCH_DIR_ABS/fixer.launched"
    if [ "$replacement" = terminal_identity ]; then
      python3 -I -B - "$UBERDEV_CHILD_STATUS" <<'PY'
import json,sys
path=sys.argv[1]; value=json.load(open(path,encoding="utf-8"))
value["process_identity"]="54321|54321|54321|abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
open(path,"w",encoding="utf-8").write(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n")
PY
    fi
    return 0
  }
  uberdev_unwind_child() { return 0; }

  . "$BUILDER"
  REAL_PYTHON="$(command -v python3)"
  python3() {
    if [ "${1:-}" = -I ] && [ "${2:-}" = -B ] && [ "${3:-}" = "$CONTRACT" ] && [ "${4:-}" = validate-standalone-outcome ]; then
      case "$replacement" in
        result) printf 'replacement\n' >>"$UBERDEV_CHILD_RESULT" ;;
        status) printf 'replacement\n' >>"$UBERDEV_CHILD_STATUS" ;;
      esac
    fi
    "$REAL_PYTHON" "$@"
  }
  run_controller() { . "$CONTROLLER"; }
  set +e
  run_controller
  local controller_rc=$?
  set -e
  if [ "$controller_rc" -eq 0 ]; then
    printf '%s\n' downstream >"$case_dir/downstream-ran"
  fi

  if [ "$replacement" != none ]; then
    [ "$controller_rc" -eq 79 ]
    [ ! -e "$case_dir/downstream-ran" ]
    [ "$(git -C "$repo" rev-parse HEAD)" != "$parent" ]
    exit 0
  fi
  [ "$controller_rc" -eq 0 ]
  grep -q 'attacker.rebind' "$RESEARCH_DIR_ABS/fixer.launched"
  if [ "$mode" = zero ]; then
    [ "$(git -C "$repo" rev-parse HEAD)" = "$parent" ]
    [ "$SIMPLIFY_FIXER_STATUS" = NO_FIXES_NEEDED ]
  else
    [ "$(git -C "$repo" rev-list --count "$parent..HEAD")" = 1 ]
    [ "$(git -C "$repo" diff --name-only "$parent..HEAD")" = apply.txt ]
    [ "$(git -C "$repo" show HEAD:apply.txt)" = apply-FINAL ]
    [ "$SIMPLIFY_FIXER_STATUS" = APPLIED ]
    [ "$SIMPLIFY_FIXER_DECLARED_TIP" = "$(git -C "$repo" rev-parse HEAD)" ]
  fi
  local preserved_paths="keep-staged.txt keep-unstaged.txt keep-both.txt"
  [ "$mode" != zero ] || preserved_paths="apply.txt $preserved_paths"
  for preserved_path in $preserved_paths; do
    cmp "$case_dir/$preserved_path.index" <(git -C "$repo" ls-files --stage -- "$preserved_path")
    cmp "$case_dir/$preserved_path.worktree" "$repo/$preserved_path"
  done
  if [ "$mode" != zero ]; then
    [ "$(git -C "$repo" show :apply.txt)" = apply-FINAL ]
    [ "$(<"$repo/apply.txt")" = apply-FINAL ]
  fi
  [ "$(<"$repo/untracked.txt")" = untracked-U0 ]
)

run_review_only_case() (
  set -euo pipefail
  local case_dir="$TEST_ROOT/review-only" repo evidence parent snapshot_receipt
  repo="$case_dir/repo"
  evidence="$repo/.uberdev/research/20260728-010209-abcdef0"
  mkdir -p "$repo" "$evidence"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'clean-H0\n' >"$repo/clean.txt"
  git -C "$repo" add -- clean.txt
  git -C "$repo" commit -qm 'test: review-only baseline'
  parent="$(git -C "$repo" rev-parse HEAD)"
  WORKTREE_ROOT="$(cd "$repo" && pwd -P)"
  RESEARCH_DIR_ABS="$(cd "$evidence" && pwd -P)"
  DIFF_ARTIFACT_PATH="$RESEARCH_DIR_ABS/pr-diff.md"
  STANDALONE_SNAPSHOT_PATH="$RESEARCH_DIR_ABS/standalone-snapshot.json"
  AGG_PATH="$RESEARCH_DIR_ABS/simplify-final.md"
  PHASE2_DISPOSITION_PATH="$RESEARCH_DIR_ABS/phase2-disposition.json"
  CODE_FIXER_CONTRACT="$CONTRACT"
  printf '<external-untrusted-input source="pr-diff">\n</external-untrusted-input>\n' >"$DIFF_ARTIFACT_PATH"
  : >"$STANDALONE_SNAPSHOT_PATH"
  : >"$PHASE2_DISPOSITION_PATH"
  snapshot_receipt="$(python3 -I -B "$CONTRACT" snapshot-standalone --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS" --diff-path "$DIFF_ARTIFACT_PATH" --snapshot-path "$STANDALONE_SNAPSHOT_PATH")"
  STANDALONE_SNAPSHOT_SHA256="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["snapshot_sha256"],end="")' "$snapshot_receipt")"
  STANDALONE_ELIGIBLE_COUNT="$(python3 -I -B -c 'import json,sys;print(len(json.loads(sys.argv[1])["target_eligible_paths"]),end="")' "$snapshot_receipt")"
  [ "$STANDALONE_ELIGIBLE_COUNT" = 0 ]
  write_aggregate "$AGG_PATH" clean.txt
  uberdev_child_inputs_build() { return 99; }
  simplify_fixer_child_bound() { return 99; }
  run_controller() { . "$CONTROLLER"; }
  run_controller
  [ "$SIMPLIFY_FIXER_STATUS" = REFUSED ]
  [ -z "$SIMPLIFY_FIXER_DECLARED_TIP" ]
  [ "$(git -C "$repo" rev-parse HEAD)" = "$parent" ]
  python3 -I -B - "$PHASE2_DISPOSITION_PATH" <<'PY'
import json,sys
value=json.load(open(sys.argv[1],encoding="utf-8"))
assert value["findings_disposition"] and all(
    row["disposition"]=="REFUSED" and row["reason"]=="no-eligible-baseline-path"
    for row in value["findings_disposition"]
)
PY
)

run_case applied none
run_case zero none
run_case applied result
run_case applied status
run_case applied foreign_handle
run_case applied terminal_identity
run_review_only_case
printf '%s\n' 'simplify-standalone-flow: applied, zero, preserved dirt, replacement refusal, and handle binding passed'
