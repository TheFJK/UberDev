# review-fences.sh -- the cross-fence helpers of commands/review-pr.md.
#
# WHY THIS FILE EXISTS (#427, the FUNCTION half). Every ```bash block in
# commands/review-pr.md is a FRESH shell, and nine of the steps between them are
# mandated `Workflow({scriptPath...})` relays, which force a new process even
# when two blocks look adjacent. Rehydration closed the VARIABLE half of that --
# a scalar minted in the setup fence and read nine relays later expanded empty.
# It did nothing for functions, and a shell function is exactly as absent across
# a process boundary as a shell variable.
#
# Twenty `review_*` helpers were defined inside markdown fence bodies. Sixteen
# were called from OTHER fences, where every call was `command not found` in a
# real run; the other four (review_ci_authority_digest, review_ci_json_member)
# were same-fence but carried FOUR copies each, which is the same contract
# stored four times with nothing comparing them.
#
# The cross-fence half is worse than a crash at three of them, because the call
# sits in front of a `||` arm written for a DIFFERENT failure: a missing
# review_assert_selected_pr_head printed "PR head changed after review;
# suppressing trust emission" and a missing review_promote_validated_fixer_outcome
# printed "HEAD changed outside the validated review fixers" -- the run did not
# just fail, it accused the repository of something that never happened.
#
# The predecessor of this file was a loader that awk-carved the definitions back
# out of the markdown and `eval`ed them. That kept ONE definition, but it also
# meant the shipped helpers could not be syntax-checked, shellcheck'd or read as
# code, and it re-read a 7,000-line markdown file on every fence. They are code;
# they live in a file that is code. commands/review-pr.md keeps NO copy --
# tests/review-pr.test.sh R47.4 refuses one, because two copies of one contract
# is the #370 "one contract, N uncompared copies" class this move exists to end.
#
# HOW FENCES GET THESE. Not by sourcing this file directly. Every executed fence
# opens with the two-line prologue
#
#     . "${UBERDEV_REVIEW_PLUGIN_ROOT:-...}/lib/review-fleet-args.sh" || return 2
#     review_fleet_rehydrate || return 2
#
# and review_fleet_rehydrate calls review_fleet_load_fence_library, with
# gap-filling semantics (a definition the process already holds wins, so a
# harness that installed a stub keeps it). Adding a helper here needs no
# call-site edit anywhere.
#
# The loader does NOT source this file (#471). It reads the roster off these
# bytes, asks `typeset -f` which of those names this shell is already missing,
# CARVES just those definitions out of this file with awk, and evals the carved
# bytes. It used to source the whole file over the caller and put the caller's
# definitions back from `typeset -f` output; that output is a re-print of the
# shell's parse tree rather than the bytes a function was defined from, and two
# helpers below re-emit unparseably (review_fixer_child_bound on bash 3.2,
# review_child_fanout on bash 5.0-5.2), so the second prologue in one process
# aborted. Carved source bytes re-parse by construction; nothing is overwritten,
# so nothing needs restoring.
#
# These helpers read the same carriers lib/review-fleet-args.sh names --
# UBERDEV_REVIEW_PLUGIN_ROOT, WORKTREE_ROOT, RESEARCH_DIR_ABS, REVIEW_ITERATION,
# CODE_FIXER_CONTRACT. Binding those is the other half of what the prologue
# does, so a caller that ran the prologue owes them nothing further.
#
# THE INDENTATION HERE IS LOAD-BEARING IN ONE DIRECTION ONLY. Shell lines are at
# their natural depth, but every `python3 -I -B - <<'PY'` body and every
# multi-line `python3 -I -B -c '...'` payload is literal text at the column its
# author left it. Re-indenting those lines re-indents Python. When these were
# lifted out of the markdown the dedent was proven by comparing `typeset -f` for
# all twenty helpers, in bash AND zsh, before and after -- do the same for any
# reflow. (Comparing typeset -f output against ITSELF on one shell is sound and
# is not the #471 defect: what broke there was feeding that output back to
# `eval`. Same command, different contract.)
#
# THE STRUCTURE HERE IS LOAD-BEARING TOO, and this half is newer (#471). Because
# the loader carves rather than sources, anything it cannot carve does not fail
# -- it silently stops existing. So:
#
#   1. NOTHING OUTSIDE A FUNCTION BLOCK. A top-level statement here would run on
#      the old source-the-file loader and simply never run under the carve.
#   2. Every definition opens as `name() {` ALONE on its line -- no `f() { :; }`
#      one-liner, no trailing code after the brace.
#   3. Every definition closes on a `}` at the DEFINITION's own indent, and no
#      interior line may put a `}` at that column. A JSON/dict heredoc or a
#      python payload whose closing brace lands at column 0 truncates the helper
#      there and spills the remainder as uncarved (i.e. dropped) text.
#
# tests/review-pr.test.sh R47.8 enforces all three by applying the loader's own
# carve rule to this file, so the failure arrives in CI rather than as a
# command-not-found forty fences into a live review.
review_json_string() {
  [ "$#" -ge 1 ] || return 2
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "${@:1:1}"
}
review_child_record() {
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" record_path="${@:5:1}"
  [ "$#" -ge 5 ] || return 2
  if command -v uberdev_child_inputs_validate >/dev/null 2>&1; then
    inputs="$(uberdev_child_inputs_validate "$edge" "$inputs")" || return 2
  fi
  python3 -I -B - "$edge" "$instance" "$inputs" "$risks" "$record_path" <<'PY'
import json,sys
edge,instance,inputs,risks,path=sys.argv[1:]
with open(path,'a') as f: f.write(json.dumps({'edge':edge,'instance':instance,'inputs':json.loads(inputs),'risks':json.loads(risks)},sort_keys=True,separators=(',',':'))+'\n')
PY
}
review_child_fanout() {
  local records="${@:1:1}" descriptors="${@:2:1}" launched="${@:3:1}" timeout_s="${@:4:1}" row edge instance inputs risks handoff handoff_sha256 result child_status receipt dispatch_rc ledger_rc cleanup_rc index
  [ "$#" -ge 4 ] || return 2
  local preflight_refs=()
  local launch_edges=() launch_instances=() launch_handoffs=()
  local launch_handoff_sha256s=() launch_results=() launch_statuses=()
  : >"$descriptors"; : >"$launched"
  while IFS= read -r row; do
    edge="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["edge"])' "$row")"
    instance="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["instance"])' "$row")"
    inputs="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["inputs"],separators=(",",":")))' "$row")"
    risks="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["risks"],separators=(",",":")))' "$row")"
    uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks" >/dev/null || return $?
    python3 -I -B - "$edge" "$instance" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" "$descriptors" <<'PY'
import json,sys
edge,instance,handoff,handoff_sha256,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'instance':instance,'handoff':handoff,'handoff_sha256':handoff_sha256,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    preflight_refs+=("$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256")
    launch_edges+=("$edge"); launch_instances+=("$instance")
    launch_handoffs+=("$UBERDEV_CHILD_HANDOFF")
    launch_handoff_sha256s+=("$UBERDEV_CHILD_HANDOFF_SHA256")
    launch_results+=("$UBERDEV_CHILD_RESULT"); launch_statuses+=("$UBERDEV_CHILD_STATUS")
  done <"$records"
  uberdev_preflight_child_batch "${preflight_refs[@]}" || return $?
  for ((index=0; index<${#launch_handoffs[@]}; index++)); do
    edge="${launch_edges[$index]}"; instance="${launch_instances[$index]}"
    handoff="${launch_handoffs[$index]}"
    handoff_sha256="${launch_handoff_sha256s[$index]}"
    result="${launch_results[$index]}"; child_status="${launch_statuses[$index]}"
    if uberdev_dispatch_child_capture "$edge" "$handoff" "$handoff_sha256" "$result" "$child_status"; then
      receipt="$UBERDEV_CHILD_DISPATCH_RECEIPT"
    else
      dispatch_rc=$?; cleanup_rc=0
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: prior child cleanup failed after dispatch edge=$edge" >&2
      return "$dispatch_rc"
    fi
    if python3 -I -B - "$edge" "$instance" "$receipt" "$result" "$child_status" "$launched" <<'PY'
import json,sys
edge,instance,receipt,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'instance':instance,'receipt':receipt,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    then
      :
    else
      ledger_rc=$?; cleanup_rc=0
      uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: current child cleanup failed after receipt ledger write edge=$edge" >&2
      return "$ledger_rc"
    fi
  done
}
review_child_wait_all() {
  local launched="${@:1:1}" timeout_s="${@:2:1}" row result child_status wait_rc first_rc=0 cleanup_rc=0
  [ "$#" -ge 2 ] || return 2
  while IFS= read -r row; do
    result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
    child_status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
    if uberdev_wait_child "$child_status" "$result" "$timeout_s"; then
      continue
    else
      wait_rc=$?
    fi
    [ "$first_rc" -ne 0 ] || first_rc="$wait_rc"
    uberdev_unwind_child "$child_status" "$result" "$timeout_s" || cleanup_rc=1
  done <"$launched"
  if [ "$first_rc" -ne 0 ]; then
    [ "$cleanup_rc" -eq 0 ] || echo "error: cleanup failed after child wait" >&2
    return "$first_rc"
  fi
  return 0
}
review_child_result_path() {
  local launched="${@:1:1}" edge="${@:2:1}"
  [ "$#" -ge 2 ] || return 2
  python3 -I -B - "$launched" "$edge" "$UBERDEV_REVIEW_PLUGIN_ROOT" "$UBERDEV_CARRIER_RUN_DIR" \
    "$_UBERDEV_DISPATCH_BACKEND_ENUM" "$UBERDEV_CARRIER_BACKEND" <<'PY'
import hashlib,importlib.util,json,os,stat,sys
ledger,edge,plugin_root,carrier_run_dir,backend_policy,expected_backend=sys.argv[1:]
def fail(reason):
    print(reason,end='')
    raise SystemExit(2)
policy_backends=backend_policy.split('|')
if (not policy_backends or any(not item for item in policy_backends)
        or len(policy_backends)!=len(set(policy_backends)) or 'auto' not in policy_backends):
    fail('classification_carrier_mismatch')
allowed_backends=set(policy_backends); allowed_backends.remove('auto')
if expected_backend not in allowed_backends:
    fail('classification_carrier_mismatch')
spec=importlib.util.spec_from_file_location('uberdev_review_artifacts',os.path.join(plugin_root,'lib','run_manifest.py'))
if spec is None or spec.loader is None: fail('classification_ledger_unreadable')
artifacts=importlib.util.module_from_spec(spec); sys.modules[spec.name]=artifacts
try: spec.loader.exec_module(artifacts)
except Exception: fail('classification_ledger_unreadable')
if not os.path.lexists(ledger): fail('classification_ledger_missing')
try:
    ledger_bytes,_=artifacts.secure_capture_regular(ledger,1,1048576)
    rows=[json.loads(line) for line in ledger_bytes.decode('utf-8').splitlines() if line.strip()]
except Exception:
    fail('classification_ledger_malformed')
if any(not isinstance(row,dict) for row in rows):
    fail('classification_ledger_malformed')
matches=[row for row in rows if row.get('edge')==edge]
if not matches:
    fail('classification_ledger_edge_missing')
if len(matches)>1:
    fail('classification_ledger_duplicate')
row=matches[0]
if set(row)!={'edge','instance','receipt','result','status'}:
    fail('classification_ledger_malformed')
path=row.get('result'); status=row.get('status'); instance=row.get('instance')
expected_child=os.path.join(os.path.realpath(carrier_run_dir),'children',instance) if isinstance(instance,str) else ''
if (not os.path.isabs(carrier_run_dir) or os.path.realpath(carrier_run_dir)!=carrier_run_dir
        or not isinstance(path,str) or not os.path.isabs(path)
        or os.path.basename(path)!='result.md'
        or not isinstance(instance,str) or os.path.basename(os.path.dirname(path))!=instance
        or os.path.dirname(path)!=expected_child):
    fail('classification_result_path_invalid')
if (not isinstance(status,str) or not os.path.isabs(status)
        or os.path.basename(status)!='status.json'
        or os.path.dirname(status)!=os.path.dirname(path)):
    fail('classification_status_path_invalid')
try:
    receipt=json.loads(row['receipt'])
except (TypeError,json.JSONDecodeError):
    fail('classification_receipt_malformed')
receipt_keys={'schema_version','edge_id','instance_id','backend','handle','state','result_file','status_file'}
if (not isinstance(receipt,dict) or set(receipt)!=receipt_keys or receipt.get('schema_version')!=1
        or receipt.get('edge_id')!=edge or receipt.get('instance_id')!=instance
        or receipt.get('result_file')!=path or receipt.get('status_file')!=status
        or receipt.get('backend')!=expected_backend
        or not isinstance(receipt.get('handle'),str) or not receipt['handle']
        or receipt.get('state') not in {'running','completed'}):
    fail('classification_receipt_mismatch')
try:
    status_bytes,_=artifacts.secure_capture_regular(status,1,65536)
    status_value=json.loads(status_bytes.decode('utf-8'))
except Exception:
    fail('classification_status_unreadable')
if (not isinstance(status_value,dict) or status_value.get('state')!='completed'
        or type(status_value.get('exit_code')) is not int or status_value['exit_code']!=0
        or status_value.get('backend')!=receipt['backend']):
    fail('classification_child_not_completed_zero')
status_handle=status_value.get('pid')
if (status_handle is None or receipt['handle'] not in {str(status_handle),'pane:'+str(status_handle)}):
    fail('classification_receipt_mismatch')
if not os.path.lexists(path): fail('classification_artifact_missing')
try:
    payload,_=artifacts.secure_capture_regular(path,1,16777216)
except artifacts.ManifestRejected:
    fail('classification_artifact_unsafe')
except Exception:
    fail('classification_artifact_unreadable')
digest=hashlib.sha256(payload).hexdigest()
instance_digest=hashlib.sha256(instance.encode()).hexdigest()[:16]
snapshot=os.path.join(os.path.dirname(os.path.abspath(ledger)),f'ci-classification-{instance_digest}-{digest}.trusted.md')
try:
    parent=os.lstat(os.path.dirname(snapshot))
    uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
    if (stat.S_ISLNK(parent.st_mode) or not stat.S_ISDIR(parent.st_mode)
            or (uid is not None and parent.st_uid!=uid)):
        fail('classification_snapshot_failed')
    published,_,published_digest=artifacts.secure_publish_captured(snapshot,payload)
    captured,_=artifacts.secure_capture_published(published,published_digest,1,16777216)
    if captured!=payload or published_digest!=digest:
        fail('classification_snapshot_failed')
except SystemExit:
    raise
except Exception:
    fail('classification_snapshot_failed')
print(published,end='')
PY
}
review_child_single() {
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" prefix="${@:5:1}" timeout_s="${@:6:1}"
  [ "$#" -ge 6 ] || return 2
  : >"$prefix.records"
  review_child_record "$edge" "$instance" "$inputs" "$risks" "$prefix.records"
  review_child_fanout "$prefix.records" "$prefix.descriptors" "$prefix.launched" "$timeout_s" || return $?
  review_child_wait_all "$prefix.launched" "$timeout_s"
}
# BEGIN review-fixer-child-bound-v2
# BEGIN review-failed-return-guard-v1
review_guard_failed_fixer_return() {
  [ "$#" -eq 2 ] || return 2
  local head_before="${@:1:1}" original_rc="${@:2:1}" guard_receipt
  case "$original_rc" in ''|*[!0-9]*|0) return 2 ;; esac
  guard_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-failed-return \
    --working-dir "$WORKTREE_ROOT" \
    --evidence-dir "$RESEARCH_DIR_ABS" \
    --head-before "$head_before")" || {
    echo "error: MUTATED_BLOCKED — fixer failure left unvalidated repository mutation" >&2
    return 79
  }
  [ "$guard_receipt" = '{"status":"clean"}' ] || {
    echo "error: MUTATED_BLOCKED — fixer failure residue receipt is malformed" >&2
    return 79
  }
  return "$original_rc"
}
# END review-failed-return-guard-v1
review_fixer_child_bound() {
  [ "$#" -eq 10 ] || return 2
  local edge="${@:1:1}" instance="${@:2:1}" inputs="${@:3:1}" risks="${@:4:1}" prefix="${@:5:1}" timeout_s="${@:6:1}"
  local authority_path="${@:7:1}" authority_sha256="${@:8:1}" disposition_path="${@:9:1}" applied_content_path="${@:10:1}"
  local receipt wait_rc
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks" >/dev/null || return $?
  uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" || return $?
  REVIEW_FIXER_RESULT_PATH="$UBERDEV_CHILD_RESULT"
  REVIEW_FIXER_STATUS_PATH="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child_capture "$edge" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" "$REVIEW_FIXER_RESULT_PATH" "$REVIEW_FIXER_STATUS_PATH" || return $?
  receipt="$UBERDEV_CHILD_DISPATCH_RECEIPT"
  REVIEW_FIXER_LAUNCH_BINDING="$(printf '%s' "$receipt" | python3 -I -B "$CODE_FIXER_CONTRACT" bind-fixer-launch-receipt \
    --edge-id "$edge" --instance-id "$instance" \
    --result-path "$REVIEW_FIXER_RESULT_PATH" \
    --status-path "$REVIEW_FIXER_STATUS_PATH" \
    --working-dir "$WORKTREE_ROOT" \
    --authority-path "$authority_path" \
    --authority-sha256 "$authority_sha256")" || {
    wait_rc=$?
    uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
    return "$wait_rc"
  }
  # Diagnostics only; authorization retains the exact in-memory binding above.
  python3 -I -B - "$edge" "$instance" "$REVIEW_FIXER_LAUNCH_BINDING" "$prefix.launched" <<'PY' || {
import json,sys
edge,instance,binding,path=sys.argv[1:]
value=json.loads(binding)
with open(path,"w",encoding="utf-8") as stream:
    json.dump({"edge":edge,"instance":instance,"receipt_sha256":value["receipt_sha256"]},stream,sort_keys=True,separators=(",",":"))
    stream.write("\n")
PY
    wait_rc=$?
    uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
    return "$wait_rc"
  }
  if uberdev_wait_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s"; then
    REVIEW_FIXER_TERMINAL="$(python3 -I -B "$CODE_FIXER_CONTRACT" capture-review-terminal \
      --launch-binding-json "$REVIEW_FIXER_LAUNCH_BINDING" \
      --disposition-path "$disposition_path" \
      --applied-content-path "$applied_content_path")" || return 74
    return 0
  fi
  wait_rc=$?
  uberdev_unwind_child "$REVIEW_FIXER_STATUS_PATH" "$REVIEW_FIXER_RESULT_PATH" "$timeout_s" || return 74
  return "$wait_rc"
}
# END review-fixer-child-bound-v2
review_assert_selected_pr_head() {
  local repo_slug="${@:1:1}" pr_number="${@:2:1}" expected_head="${@:3:1}" worktree_root="${@:4:1}"
  local live_head local_head
  [ "$#" -ge 4 ] || return 2
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || return 2
  live_head="$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq .headRefOid 2>/dev/null)" || return 2
  local_head="$(git -C "$worktree_root" rev-parse HEAD 2>/dev/null)" || return 2
  [ "$live_head" = "$expected_head" ] && [ "$local_head" = "$expected_head" ]
}

review_publish_same_repo_pr_head() {
  [ "$#" -eq 7 ] || return 2
  local repo_slug="${@:1:1}" pr_number="${@:2:1}" expected_remote_head_sha="${@:3:1}" publish_sha="${@:4:1}"
  local worktree_root="${@:5:1}" contract_helper="${@:6:1}" evidence_dir="${@:7:1}"
  local live_identity live_head live_branch live_cross_repository live_head_repo extra
  local remote_identity remote_head remote_ref remote_extra observed_head residue_receipt
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$expected_remote_head_sha" =~ ^[0-9a-f]{40}$ && "$publish_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  [[ "$worktree_root" = /* && "$contract_helper" = /* && "$evidence_dir" = /* ]] || return 2
  # The head-repository identity is `headRepositoryOwner.login` +
  # `headRepository.name`, NEVER `headRepository.nameWithOwner` (#429).
  # gh DECLARES that last field and never populates it -- gh 2.83.1:
  #
  #     gh pr view 422 --repo TheFJK/UberDev --json headRepository
  #     {"headRepository":{"id":"R_kgDOSOF5tw","name":"UberDev","nameWithOwner":""}}
  #
  # A gate keyed on the empty string can never pass, which turned "refuse
  # forks" into "refuse everything": every /review-pr run exited 2 here and
  # at the trust-trail anchor push below, so no PR could ever obtain a trail
  # and /merge gated all of them out. The owner/name composite is populated
  # for every PR, fork and same-repo alike. Same resolution as
  # `lib/review-push-target.sh`, which had this fix from the start and was
  # wired into ONE call site only -- keep the two in step.
  #
  # One field per LINE, not one tab-separated line. Tab is IFS whitespace, so
  # a tab-joined projection with an empty field COLLAPSES under `read`: the
  # fields shift left and a malformed identity parses as a well-formed
  # DIFFERENT one. Line-per-field cannot shift -- git refuses a ref name
  # containing a newline, so a stray newline can only make the projection
  # over-long, which the trailing read refuses.
  live_identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
       --json headRefOid,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
       --jq '.headRefOid, .headRefName, (.isCrossRepository | tostring),
             ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
       2>/dev/null)" || return 79
  {
    IFS= read -r live_head || return 79
    IFS= read -r live_branch || return 79
    IFS= read -r live_cross_repository || return 79
    IFS= read -r live_head_repo || return 79
    if IFS= read -r extra; then return 79; fi
  } <<<"$live_identity"
  [ "$live_head" = "$expected_remote_head_sha" ] || return 79
  # No `[ -z "$extra" ]` here, and its absence is not an oversight: with
  # line-per-field, over-length is refused INSIDE the read block above, which
  # returns 79 the moment a fifth line exists. A trailing emptiness test on
  # `extra` is therefore unreachable-false -- it can only ever be reached
  # when `extra` is already empty. The tab-joined form it replaced DID need
  # it, because there a fifth field arrived on the same single line and the
  # read could not refuse it.
  [ -n "$live_branch" ] && [ "$live_cross_repository" = false ] && [ "$live_head_repo" = "$repo_slug" ] || return 79
  git -C "$worktree_root" check-ref-format --branch "$live_branch" >/dev/null 2>&1 || return 79
  observed_head="$(git -C "$worktree_root" rev-parse HEAD)" || return 79
  [ "$observed_head" = "$publish_sha" ] || return 79
  # BRACES ARE LOAD-BEARING. These fences run under /bin/zsh, where an
  # unbraced `$publish_sha:refs/...` parses `:r` as the remove-extension
  # MODIFIER: the refspec silently becomes `<sha>efs/heads/<branch>` and the
  # push dies with "src refspec ... does not match any". Proven with
  # `zsh -c 'V=abc; print "$V:refs/x"'` -> `abcefs/x`.
  git -C "$worktree_root" push origin "${publish_sha}:refs/heads/${live_branch}" || return 79
  remote_identity="$(git -C "$worktree_root" ls-remote --exit-code --heads origin "refs/heads/$live_branch")" || return 79
  [[ "$remote_identity" != *$'\n'* ]] || return 79
  IFS=$'\t' read -r remote_head remote_ref remote_extra <<<"$remote_identity" || return 79
  [ "$remote_head" = "$publish_sha" ] && [ "$remote_ref" = "refs/heads/$live_branch" ] && [ -z "$remote_extra" ] || return 79
  # Post-push re-projection. Same owner/name composite and same
  # line-per-field read as the pre-push probe above (#429) -- the two must
  # never drift, since this one is what proves the ref we just wrote is still
  # the PR's head in the repository we think it is.
  live_identity="$(gh pr view "$pr_number" --repo "$repo_slug" \
       --json headRefOid,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
       --jq '.headRefOid, .headRefName, (.isCrossRepository | tostring),
             ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' \
       2>/dev/null)" || return 79
  {
    IFS= read -r live_head || return 79
    IFS= read -r live_branch || return 79
    IFS= read -r live_cross_repository || return 79
    IFS= read -r live_head_repo || return 79
    if IFS= read -r extra; then return 79; fi
  } <<<"$live_identity"
  [ "$live_head" = "$publish_sha" ] || return 79
  # See the pre-push probe: `extra` is intentionally unassigned on success.
  [ "$remote_ref" = "refs/heads/$live_branch" ] && [ "$live_cross_repository" = false ] && [ "$live_head_repo" = "$repo_slug" ] || return 79
  observed_head="$(git -C "$worktree_root" rev-parse HEAD)" || return 79
  [ "$observed_head" = "$publish_sha" ] || return 79
  residue_receipt="$(python3 -I -B "$contract_helper" validate-residue --working-dir "$worktree_root" --evidence-dir "$evidence_dir")" || return 79
  [ "$residue_receipt" = '{"status":"clean"}' ] || return 79
}
review_resolve_phase1_base() {
  [ "$#" -ge 3 ] || return 2
  python3 -I -B - "${@:1:1}" "${@:2:1}" "${@:3:1}" <<'PY'
import json,re,subprocess,sys
pr,root,repo=sys.argv[1:]
if re.fullmatch(r'[1-9][0-9]*',pr) is None: raise SystemExit(2)
metadata=json.loads(subprocess.check_output(
    ['gh','pr','view',pr,'--repo',repo,'--json','baseRefOid,baseRefName'],text=True))
base_oid=metadata.get('baseRefOid'); base_name=metadata.get('baseRefName')
if re.fullmatch(r'[0-9a-f]{40}',base_oid or '') is None or not isinstance(base_name,str) or not base_name:
    raise SystemExit(2)
try:
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    subprocess.run(['git','-C',root,'fetch','--no-tags','origin',base_name],check=True)
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
base=subprocess.check_output(['git','-C',root,'merge-base',head,base_oid],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
print(base,end='')
PY
}
review_refresh_phase1_scope() {
  local base="${@:1:1}"
  [ "$#" -ge 1 ] || return 2
  CHANGED_PATHS_JSON="$(python3 -I -B - "$WORKTREE_ROOT" "$base" "$DIFF_ARTIFACT_PATH" "$COMMIT_RANGE_PATH" <<'PY'
import json,os,re,stat,subprocess,sys,tempfile
root,base,diff_path,range_path=sys.argv[1:]
MAX_DIFF_LINES=2000
MAX_DIFF_BYTES=8*1024*1024
MAX_WRAPPED_DIFF_BYTES=16*1024*1024
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',head) is None: raise SystemExit(2)
subprocess.run(['git','-C',root,'merge-base','--is-ancestor',base,head],check=True)
raw_paths=subprocess.check_output(['git','-C',root,'diff','--name-only','-z',f'{base}..{head}'])
paths=[item.decode('utf-8','strict') for item in raw_paths.split(b'\0') if item]
if not paths: raise SystemExit(2)
for path in paths:
    parts=path.split('/')
    if (path.startswith('/') or '\\' in path or any(part in ('','.','..') for part in parts)
            or any(ord(char)<32 or ord(char)==127 for char in path)):
        raise SystemExit(2)
def escape_untrusted_diff_payload(payload):
    return payload.replace(b'&',b'&amp;').replace(b'<',b'&lt;')
def wrap_untrusted_diff(payload):
    escaped=escape_untrusted_diff_payload(payload)
    opening=b'<external-untrusted-input source="pr-diff">'
    closing=b'</external-untrusted-input>'
    wrapped=opening+b'\n'+escaped+closing+b'\n'
    if wrapped.count(opening)!=1 or wrapped.count(closing)!=1: raise ValueError()
    return wrapped
def build_diff_summary():
    summary=['[diff summarized: full binary diff exceeded the 2000-line, 8-MiB raw, or 16-MiB wrapped review artifact limit]']
    summary_bytes=len((summary[0]+'\n').encode())
    summary_wrapped_bytes=len(wrap_untrusted_diff((summary[0]+'\n').encode()))
    omission_reserve=128
    stats=subprocess.Popen(['git','-C',root,'diff','--numstat','--no-renames',f'{base}..{head}'],
                           stdout=subprocess.PIPE,text=True,encoding='utf-8',errors='strict')
    omitted=0
    for line in stats.stdout:
        fields=line.rstrip('\n').split('\t',2)
        if len(fields)!=3: raise SystemExit(2)
        added,deleted,path=fields
        detail='binary change' if added==deleted=='-' else f'{added} additions, {deleted} deletions'
        row=f'{path} — {detail}'
        encoded=(row+'\n').encode()
        escaped_size=len(escape_untrusted_diff_payload(encoded))
        if (summary_bytes+len(encoded)>MAX_DIFF_BYTES
                or summary_wrapped_bytes+escaped_size+omission_reserve>MAX_WRAPPED_DIFF_BYTES):
            omitted+=1
            continue
        summary.append(row)
        summary_bytes+=len(encoded)
        summary_wrapped_bytes+=escaped_size
    if stats.wait()!=0: raise SystemExit(2)
    if omitted: summary.append(f'[{omitted} additional file summaries omitted to preserve the artifact limit]')
    return ('\n'.join(summary)+'\n').encode()
def select_bounded_wrapped_diff(payload, summary_factory):
    wrapped=wrap_untrusted_diff(payload)
    if len(wrapped)<=MAX_WRAPPED_DIFF_BYTES: return wrapped
    wrapped=wrap_untrusted_diff(summary_factory())
    if len(wrapped)>MAX_WRAPPED_DIFF_BYTES: raise ValueError()
    return wrapped
process=subprocess.Popen(['git','-C',root,'diff','--binary','--no-ext-diff',f'{base}..{head}'],stdout=subprocess.PIPE)
diff_buffer=bytearray(); diff_lines=0; summarized=False
while True:
    chunk=process.stdout.read(65536)
    if not chunk: break
    diff_buffer.extend(chunk); diff_lines+=chunk.count(b'\n')
    if len(diff_buffer)>MAX_DIFF_BYTES or diff_lines>MAX_DIFF_LINES:
        summarized=True; process.kill(); break
process.stdout.close(); process.wait()
if not summarized and process.returncode!=0: raise SystemExit(2)
diff=build_diff_summary() if summarized else bytes(diff_buffer)
wrapped_diff=select_bounded_wrapped_diff(diff,(lambda: diff) if summarized else build_diff_summary)
def replace_private(path,payload):
    parent=os.path.dirname(path) or '.'
    fd,tmp=tempfile.mkstemp(prefix='.review-scope.',dir=parent)
    try:
        if os.name!='nt': os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp,path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
replace_private(diff_path,wrapped_diff)
expected_range=f'{base}..{head}\n'.encode()
replace_private(range_path,expected_range)
if open(range_path,'rb').read()!=expected_range: raise SystemExit(2)
print(json.dumps(paths,separators=(',',':')),end='')
PY
)" || return 2
}
review_track_validated_fixer_head() {
  local child_status="${@:1:1}" before="${@:2:1}" after="${@:3:1}" declared_tip="${@:4:1}" commit_count residue_receipt
  [ "$#" -ge 3 ] || return 2
  residue_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-residue --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS")" || { echo "error: MUTATED_BLOCKED — fixer returned residual repository state" >&2; return 79; }
  [ "$residue_receipt" = '{"status":"clean"}' ] || { echo "error: MUTATED_BLOCKED — fixer residue receipt is malformed" >&2; return 79; }
  [[ "$before" =~ ^[0-9a-f]{40}$ && "$after" =~ ^[0-9a-f]{40}$ ]] || return 2
  # ABSENT and CHANGED are the same rc and must not be the same sentence. Both
  # are refusals -- a fixer whose starting point this process cannot vouch for is
  # never promoted -- but one is a repository that moved under the review and the
  # other is a record that never travelled, and the second spent a live run
  # looking like the first (#479). The seed is written by the Phase 1 scope
  # fence; if it is missing, that fence is where to look, not the history.
  if [ -z "${VALIDATED_FIXER_HEAD_SHA:-}" ]; then
    echo "error: MUTATED_BLOCKED — no reviewed-head record reached this fence (${RESEARCH_DIR_ABS:-<no research dir>}/reviewed-head.txt); the Phase 1 scope fence must seed it before any fixer is dispatched" >&2
    return 76
  fi
  [ "$before" = "$VALIDATED_FIXER_HEAD_SHA" ] || {
    echo "error: MUTATED_BLOCKED — fixer started from $before but the review stands on $VALIDATED_FIXER_HEAD_SHA" >&2
    return 76
  }
  case "$child_status" in
    APPLIED)
      [ "$before" != "$after" ] || return 77
      [ "$declared_tip" = "$after" ] || return 77
      git -C "$WORKTREE_ROOT" merge-base --is-ancestor "$before" "$after" || return 78
      commit_count="$(git -C "$WORKTREE_ROOT" rev-list --count "$before..$after")" || return 78
      [ "$commit_count" = 1 ] || return 77
      VALIDATED_FIXER_HEAD_SHA="$after"
      # Persisted at the ONE point it legitimately advances. The trust fences
      # and the post-fixer publication gate are separate processes and read this
      # back; without the record they saw the empty string and reported "HEAD
      # changed outside the validated review fixers" at a run whose head had not
      # moved. Recording it is not optional -- a fixer commit this file cannot
      # prove it authorised is exactly what the gate downstream must refuse.
      review_fleet_write_reviewed_head \
        "$RESEARCH_DIR_ABS/reviewed-head.txt" "$after" || return 74
      ;;
    NO_FIXES_NEEDED|REFUSED)
      [ -z "$declared_tip" ] && [ "$before" = "$after" ] || return 75
      ;;
    *) return 2 ;;
  esac
}
review_promote_validated_fixer_outcome() {
  [ "$#" -eq 3 ] || return 2
  local outcome="${@:1:1}" before="${@:2:1}" after="${@:3:1}" parsed child_status declared_tip extra
  parsed="$(python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
base={"status","declared_tip","status_sha256","result_sha256","disposition_sha256","applied_content_sha256","commit"}
if not isinstance(value,dict): raise SystemExit(74)
# EXACTLY ONE launch-identity key, chosen by the backend, never by the child:
# a detached outcome is tied to its dispatch receipt, a workflow outcome to the
# nonce the controller minted before the call (code_fixer_contract.py
# _launch_identity). Accepting both is not a relaxation -- the set equality is
# still exact for each shape, both keys are still required 64-hex below, and a
# document carrying BOTH, NEITHER, or any extra key is still refused.
launch=set(value)-base
if launch not in ({"receipt_sha256"},{"run_nonce"}) or set(value)-launch!=base: raise SystemExit(74)
status=value["status"]; tip=value["declared_tip"]
if status not in {"APPLIED","NO_FIXES_NEEDED","REFUSED"} or not isinstance(tip,str): raise SystemExit(74)
if any(not isinstance(value[key],str) or re.fullmatch(r"[0-9a-f]{64}",value[key]) is None for key in (*launch,"status_sha256","result_sha256","disposition_sha256","applied_content_sha256")): raise SystemExit(74)
if (status=="APPLIED") != (re.fullmatch(r"[0-9a-f]{40}",tip) is not None) or (status=="APPLIED") != isinstance(value["commit"],dict): raise SystemExit(74)
print(status+"\t"+tip,end="")' "$outcome")" || return 74
  IFS=$'\t' read -r child_status declared_tip extra <<<"$parsed"
  [ -z "${extra:-}" ] || return 74
  review_track_validated_fixer_head "$child_status" "$before" "$after" "$declared_tip"
}
review_clear_ci_run_selection() {
  CI_RUN_ID=
  CI_RUN_EVENT=
  CI_RUN_CHECK_LINK=
  CI_RUN_CHECK_NAME=
  unset CI_CLASSIFICATION_HEAD_SHA CI_ROUTE_HEAD_SHA
}
review_select_failed_ci_run() {
  local probe_json="${@:1:1}" repo_slug="${@:2:1}"
  python3 -I -B - "$repo_slug" 3<<<"$probe_json" <<'PY'
import json,os,re,sys
from urllib.parse import urlsplit

repo_slug=sys.argv[1]
try:
    rows=json.load(os.fdopen(3))
except (json.JSONDecodeError,UnicodeDecodeError):
    raise SystemExit(2)
if not isinstance(rows,list) or not rows or not re.fullmatch(r'[^/\s]+/[^/\s]+',repo_slug):
    raise SystemExit(2)
known_buckets={'pass','skipping','pending','fail','cancel'}
groups={}
for row in rows:
    if not isinstance(row,dict):
        raise SystemExit(2)
    name=row.get('name')
    bucket=row.get('bucket')
    if not isinstance(name,str) or not name or not isinstance(bucket,str) or bucket not in known_buckets:
        raise SystemExit(2)
    groups.setdefault(name,[]).append(row)
kept=[]
for group in groups.values():
    kept.extend(
        [row for row in group if row['bucket']!='cancel']
        if any(row['bucket']!='cancel' for row in group)
        else group
    )
failed=[row for row in kept if row['bucket'] in {'fail','cancel'}]
if not failed:
    raise SystemExit(2)
candidates=[]
link_pattern=re.compile(r'^/([^/]+)/([^/]+)/actions/runs/([1-9][0-9]*)(?:/job/[1-9][0-9]*)?/?$')
for row in failed:
    event=row.get('event')
    link=row.get('link')
    workflow=row.get('workflow')
    if event not in {'pull_request','push'} or not isinstance(link,str) or not link:
        raise SystemExit(2)
    # `name` joins the control-character test because it LEAVES this function
    # now (#418): it is the fourth output column and then a single-line run-dir
    # carrier, so a TAB in it would split the column and a newline would
    # truncate the record -- both spelled as success.
    if not isinstance(workflow,str) or any(ord(char)<32 or ord(char)==127 for char in event+link+workflow+row['name']):
        raise SystemExit(2)
    parsed=urlsplit(link)
    match=link_pattern.fullmatch(parsed.path)
    if parsed.scheme!='https' or parsed.netloc.lower()!='github.com' or match is None:
        raise SystemExit(2)
    linked_slug=f'{match.group(1)}/{match.group(2)}'
    if linked_slug.lower()!=repo_slug.lower():
        raise SystemExit(2)
    run_id=match.group(3)
    candidates.append((0 if event=='pull_request' else 1,workflow,row['name'],int(run_id),event,link))
if not candidates:
    raise SystemExit(2)
# FOUR columns. The selected row's NAME is the only producer of `check_name`
# anywhere in this file: the REFUSED arm files it into a CRITICAL issue so a
# human can see WHICH check refused, and it consumed `${check_name:-unknown}`
# against a name nothing had ever bound (#418). It is already this function's
# tie-break key, so emitting it invents no second answer about which check
# failed.
_,_,check_name,run_id,event,link=min(candidates)
print(f'{run_id}\t{event}\t{link}\t{check_name}')
PY
}
review_capture_ci_classification_head() {
  local expected_head="${@:1:1}" local_head live_identity live_head live_branch
  local target_head run_json run_failure
  local_head="$(git -C "$WORKTREE_ROOT" rev-parse HEAD 2>/dev/null)" || {
    printf 'classification_local_head_query_failed'
    return 1
  }
  live_identity="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" \
        --json headRefOid,headRefName \
        --jq '"\(.headRefOid)\t\(.headRefName)"' 2>/dev/null)" || {
    printf 'classification_live_head_query_failed'
    return 1
  }
  IFS=$'\t' read -r live_head live_branch <<<"$live_identity"
  if [[ ! "$local_head" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'classification_local_head_malformed'
    return 1
  fi
  if [[ ! "$live_head" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'classification_live_head_malformed'
    return 1
  fi
  if [ -z "$live_branch" ]; then
    printf 'classification_live_branch_malformed'
    return 1
  fi
  if [[ ! "$CI_RUN_ID" =~ ^[1-9][0-9]*$ ]]; then
    printf 'classification_run_id_malformed'
    return 1
  fi
  if [[ ! "$CI_RUN_EVENT" =~ ^(pull_request|push)$ ]]; then
    printf 'classification_run_event_malformed'
    return 1
  fi
  if [ -n "$expected_head" ]; then
    if [[ ! "$expected_head" =~ ^[0-9a-f]{40}$ ]]; then
      printf 'classification_expected_head_malformed'
      return 1
    fi
    if [ "$local_head" != "$expected_head" ]; then
      printf 'classification_local_head_moved'
      return 1
    fi
    if [ "$live_head" != "$expected_head" ]; then
      printf 'classification_live_head_moved'
      return 1
    fi
    target_head="$expected_head"
  else
    if [ "$live_head" != "$local_head" ]; then
      printf 'classification_live_head_mismatch'
      return 1
    fi
    target_head="$local_head"
  fi
  run_json="$(gh api "repos/$REVIEW_REPO_SLUG/actions/runs/$CI_RUN_ID" 2>/dev/null)" || {
    printf 'classification_run_metadata_query_failed'
    return 1
  }
  if run_failure="$(
        python3 -I -B - "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$CI_RUN_ID" \
          "$CI_RUN_EVENT" "$target_head" "$live_branch" \
          "$([ -n "$expected_head" ] && printf moved || printf mismatch)" \
          3<<<"$run_json" 2>/dev/null <<'PY'
import json,os,re,sys
repo_slug,pr_number,run_id,selected_event,target_head,live_branch,phase=sys.argv[1:]
def fail(reason):
    print(reason,end='')
    raise SystemExit(2)
try:
    value=json.load(os.fdopen(3))
except (json.JSONDecodeError,UnicodeDecodeError,OSError):
    fail('classification_run_metadata_malformed')
if not isinstance(value,dict):
    fail('classification_run_metadata_malformed')
if value.get('id')!=int(run_id):
    fail('classification_run_id_mismatch')
repository=value.get('repository')
if not isinstance(repository,dict) or str(repository.get('full_name','')).lower()!=repo_slug.lower():
    fail('classification_run_repository_mismatch')
if value.get('event')!=selected_event:
    fail('classification_run_event_mismatch')
run_head=value.get('head_sha')
run_branch=value.get('head_branch')
if not isinstance(run_head,str) or re.fullmatch(r'[0-9a-f]{40}',run_head) is None:
    fail('classification_run_head_malformed')
suffix='moved' if phase=='moved' else 'mismatch'
if selected_event=='push':
    if run_branch!=live_branch or run_head!=target_head:
        fail(f'classification_run_head_{suffix}')
elif selected_event=='pull_request':
    # pull_requests must contain PR_NUMBER at the exact live branch-head.
    associations=value.get('pull_requests')
    if not isinstance(associations,list):
        fail('classification_run_metadata_malformed')
    matched=False
    for association in associations:
        if not isinstance(association,dict) or association.get('number')!=int(pr_number):
            continue
        head=association.get('head')
        if isinstance(head,dict) and head.get('sha')==target_head and head.get('ref')==live_branch:
            matched=True
            break
    if run_branch!=live_branch or not matched:
        fail(f'classification_run_pr_{suffix}')
else:
    fail('classification_run_event_mismatch')
PY
      )"; then
    :
  else
    printf '%s' "${run_failure:-classification_run_metadata_malformed}"
    return 1
  fi
  printf '%s' "$local_head"
}
review_ci_authority_digest() {
  [ "$#" -ge 3 ] || return 2
  python3 -I -B -c 'import json,re,sys
value=json.loads(sys.argv[1])
if (set(value)!={"authority_path","authority_sha256","edge_id","phase"}
        or value["authority_path"]!=sys.argv[2]
        or value["edge_id"]!=sys.argv[3]
        or re.fullmatch(r"[0-9a-f]{64}",value["authority_sha256"]) is None):
    raise SystemExit(74)
print(value["authority_sha256"],end="")' "${@:1:1}" "${@:2:1}" "${@:3:1}"
}
review_ci_json_member() {
  [ "$#" -ge 2 ] || return 2
  python3 -I -B -c 'import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,dict) or sys.argv[2] not in value: raise SystemExit(2)
member=value[sys.argv[2]]
print(member if isinstance(member,str) else json.dumps(member,separators=(",",":")),end="")' "${@:1:1}" "${@:2:1}"
}
review_validate_trust_anchor() {
  [ "$#" -eq 4 ] || return 2
  local reviewed_head_sha="${@:1:1}" parent_sha="${@:2:1}" anchor_sha="${@:3:1}" expected_message_sha256="${@:4:1}"
  local observed_head observed_parents observed_message_sha256 residue_receipt
  [[ "$reviewed_head_sha" =~ ^[0-9a-f]{40}$ && "$parent_sha" =~ ^[0-9a-f]{40}$ && "$anchor_sha" =~ ^[0-9a-f]{40}$ && "$expected_message_sha256" =~ ^[0-9a-f]{64}$ ]] || return 2
  [ "$parent_sha" = "$reviewed_head_sha" ] || return 79
  observed_head="$(git -C "$WORKTREE_ROOT" rev-parse HEAD)" || return 79
  [ "$observed_head" = "$anchor_sha" ] || return 79
  observed_parents="$(git -C "$WORKTREE_ROOT" rev-list --parents -n 1 "$anchor_sha")" || return 79
  [ "$observed_parents" = "$anchor_sha $parent_sha" ] || return 79
  git -C "$WORKTREE_ROOT" diff --quiet "$parent_sha" "$anchor_sha" -- || return 79
  observed_message_sha256="$(python3 -I -B "$CODE_FIXER_CONTRACT" commit-message-digest --working-dir "$WORKTREE_ROOT" --commit-sha "$anchor_sha")" || return 79
  [ "$observed_message_sha256" = "$expected_message_sha256" ] || return 79
  residue_receipt="$(python3 -I -B "$CODE_FIXER_CONTRACT" validate-residue --working-dir "$WORKTREE_ROOT" --evidence-dir "$RESEARCH_DIR_ABS")" || return 79
  [ "$residue_receipt" = '{"status":"clean"}' ] || return 79
}
