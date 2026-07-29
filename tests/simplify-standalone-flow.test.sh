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

  git -C "$repo" diff --cached --binary -- keep-staged.txt keep-both.txt >"$case_dir/keep.cached"
  git -C "$repo" diff --binary -- keep-unstaged.txt keep-both.txt >"$case_dir/keep.worktree"

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
open(path,"w",encoding="utf-8").write("\n".join(lines)+"\n")
PY
    local status_handle=12345
    [ "$replacement" != foreign_handle ] || status_handle=54321
    python3 -I -B - "$UBERDEV_CHILD_STATUS" "$status_handle" "$WORKTREE_ROOT" "$UBERDEV_CHILD_RESULT" <<'PY'
import json,sys
path,handle,worktree,result=sys.argv[1:]
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
import json,sys
edge,instance,result,status=sys.argv[1:]
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
  cmp "$case_dir/keep.cached" <(git -C "$repo" diff --cached --binary -- keep-staged.txt keep-both.txt)
  cmp "$case_dir/keep.worktree" <(git -C "$repo" diff --binary -- keep-unstaged.txt keep-both.txt)
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
